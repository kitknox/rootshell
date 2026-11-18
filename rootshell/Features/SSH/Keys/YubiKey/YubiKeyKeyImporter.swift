//
//  YubiKeyKeyImporter.swift
//  rootshell
//
//  Imports existing SSH private keys from iOS Keychain to YubiKey PIV slots
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit
import Crypto
import NIOCore
import NIOFoundationCompat
import CCryptoBoringSSL

/// Imports existing SSH private keys from Keychain to YubiKey PIV slots
///
/// After import, the private key material moves from software storage to hardware,
/// where it becomes non-exportable. The public key and metadata remain accessible.
@MainActor
final class YubiKeyKeyImporter {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyKeyImporter"
    )

    private let connectionManager: YubiKeyConnectionManager
    private let keyManager: SSHKeyManager
    private let keychainManager: KeychainManager

    /// Default PIV management key (factory default) - AES-192 (24 bytes)
    private static let defaultManagementKeyAES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    /// Default PIV management key (factory default) - Triple-DES (24 bytes)
    private static let defaultManagementKeyTripleDES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    init(
        connectionManager: YubiKeyConnectionManager? = nil,
        keyManager: SSHKeyManager? = nil,
        keychainManager: KeychainManager? = nil
    ) {
        self.connectionManager = connectionManager ?? .shared
        self.keyManager = keyManager ?? .shared
        self.keychainManager = keychainManager ?? .shared
    }

    // MARK: - Import Validation

    /// Result of checking if a key can be imported
    struct ImportValidation: Sendable {
        let canImport: Bool
        let reason: String?
        let warnings: [String]
    }

    /// Check if a key can be imported to YubiKey
    /// - Parameter key: The SSH key to check
    /// - Returns: ImportValidation result with reason if cannot import
    func canImport(key: SSHKey) -> ImportValidation {
        var warnings: [String] = []

        // Check if already a hardware key
        if key.isHardwareKey {
            return ImportValidation(
                canImport: false,
                reason: "This key is already stored on a hardware security key.",
                warnings: []
            )
        }

        // Check key type compatibility
        switch key.keyType {
        case .ed25519:
            warnings.append("Ed25519 requires YubiKey firmware 5.7 or later.")
        case .ecdsaP256, .ecdsaP384:
            // Fully supported
            break
        case .rsa:
            // Supported, but may be slow to import
            warnings.append("RSA key import may take several seconds.")
        case .ecdsaP521:
            return ImportValidation(
                canImport: false,
                reason: "ECDSA P-521 keys are not supported by YubiKey PIV.",
                warnings: []
            )
        case .mldsa44, .mldsa65, .mldsa87:
            warnings.append("ML-DSA requires YubiKey firmware 6.0 or later.")
        case .mldsa44Ed25519:
            return ImportValidation(
                canImport: false,
                reason: "ML-DSA-44 + Ed25519 keys cannot be stored in a single PIV slot.",
                warnings: []
            )
        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            return ImportValidation(
                canImport: false,
                reason: "Hardware keys cannot be re-imported.",
                warnings: []
            )
        case .externalAgent:
            return ImportValidation(
                canImport: false,
                reason: "Agent-served keys have no private key material to import.",
                warnings: []
            )
        }

        return ImportValidation(canImport: true, reason: nil, warnings: warnings)
    }

    /// Get list of software keys that can be imported
    func getImportableKeys() -> [SSHKey] {
        keyManager.savedKeys.filter { canImport(key: $0).canImport }
    }

    // MARK: - Import Operation

    /// Import result containing the new YubiKey-backed SSHKey
    struct ImportResult: Sendable {
        let yubiKeySSHKey: SSHKey
        let publicKeyString: String
        let fingerprint: String
    }

    /// PIV sends an imported private key in the clear, and NFC can be overheard
    /// from nearby, so import is refused there.
    private static let nfcImportRefusal =
        "Private keys can't be imported over NFC, where the transfer isn't encrypted. Connect the YubiKey with USB-C instead."

    /// The wired transport to connect with for an import; throws if the next
    /// connection would be NFC. Connect with the returned transport so the
    /// choice isn't made again and an import never opens an NFC session.
    func requireWiredTransport() async throws -> YubiKeyConnectionMethod {
        guard let method = await connectionManager.wiredTransportForNextConnection() else {
            throw YubiKeyError.importFailed(Self.nfcImportRefusal)
        }
        return method
    }

    /// Import a software key to YubiKey PIV slot
    /// - Parameters:
    ///   - keyID: ID of the software key to import
    ///   - target: YubiKey and slot the user confirmed; any other key is
    ///     refused before private key material is read or sent
    ///   - pinPolicy: PIN policy for the imported key
    ///   - touchPolicy: Touch policy for the imported key
    ///   - managementKey: Optional custom management key (uses default if nil)
    ///   - deleteFromKeychain: Whether to delete the software key after successful import
    /// - Returns: ImportResult with the new YubiKey-backed SSHKey
    func importKey(
        keyID: UUID,
        target: YubiKeyWriteTarget,
        pinPolicy: PIV.PinPolicy = .defaultPolicy,
        touchPolicy: PIV.TouchPolicy = .defaultPolicy,
        managementKey: Data? = nil,
        deleteFromKeychain: Bool = false
    ) async throws -> ImportResult {
        let slot = target.slot
        Self.logger.info("Starting import of key \(keyID.uuidString) to slot \(slot.rawValue)")

        // 1. Validate the key can be imported
        guard let sshKey = keyManager.findKey(id: keyID) else {
            throw YubiKeyError.importFailed("Key not found")
        }

        let validation = canImport(key: sshKey)
        guard validation.canImport else {
            throw YubiKeyError.importFailed(validation.reason ?? "Key cannot be imported")
        }

        // Only the confirmed YubiKey, and only wired, before the private key
        // leaves the Keychain. The session is tied to the connection that was
        // checked, so everything below reaches that key or fails.
        let (session, _, _) = try await connectionManager.verifiedPIVSession(
            serial: target.serial,
            nfcRefusal: .importFailed(Self.nfcImportRefusal)
        )
        let serial = target.serial

        // 2. Load key data from Keychain
        let keyData = try keychainManager.loadPrivateKey(identifier: keyID.uuidString)
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw YubiKeyError.importFailed("Failed to decode key data")
        }

        // Load passphrase if the key is encrypted
        let passphrase = keychainManager.loadPassphrase(forKey: keyID.uuidString)

        // 3. Parse the key to get raw material
        let parsedKey: SSHKeyParser.ParsedKey
        do {
            parsedKey = try SSHKeyParser.parse(keyString: keyString, passphrase: passphrase)
        } catch SSHKeyParser.ParserError.encryptedKeyNeedsPassphrase,
                SSHKeyParser.ParserError.incorrectPassphrase {
            throw YubiKeyError.importFailed(
                "This key is encrypted and its passphrase isn't on this device. Unlock it once in Settings → SSH Keys, then retry."
            )
        }

        // 4. Authenticate
        try await authenticateManagement(session: session, customKey: managementKey)

        // 5. Check Ed25519 support if needed
        if sshKey.keyType == .ed25519 {
            guard await session.supports(.ed25519) else {
                throw YubiKeyError.unsupportedFeature("Ed25519 requires YubiKey 5.7 or later")
            }
        }
        if YubiKeyKeyConverter.mldsaParameterSet(for: sshKey.keyType) != nil {
            guard await session.supports(.mlDSA) else {
                throw YubiKeyError.unsupportedFeature("ML-DSA requires YubiKey firmware 6.0 or later")
            }
        }

        // 6. Import the key based on type
        let publicKeyData: Data
        let algorithm: YubiKeyAlgorithm
        var mldsaPublicKey: YubiKit.MLDSA.PublicKey?

        switch parsedKey.keyType {
        case .ed25519:
            let result = try await importEd25519(
                parsedKey: parsedKey,
                keyString: keyString,
                passphrase: passphrase,
                session: session,
                slot: slot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy
            )
            publicKeyData = result.publicKeyData
            algorithm = .ed25519

        case .ecdsaP256:
            let result = try await importECDSA(
                parsedKey: parsedKey,
                keyString: keyString,
                passphrase: passphrase,
                session: session,
                slot: slot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy,
                curve: .secp256r1
            )
            publicKeyData = result.publicKeyData
            algorithm = .ecdsaP256

        case .ecdsaP384:
            let result = try await importECDSA(
                parsedKey: parsedKey,
                keyString: keyString,
                passphrase: passphrase,
                session: session,
                slot: slot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy,
                curve: .secp384r1
            )
            publicKeyData = result.publicKeyData
            algorithm = .ecdsaP384

        case .rsa:
            let result = try await importRSA(
                parsedKey: parsedKey,
                session: session,
                slot: slot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy,
                originalPublicKeyBlob: sshKey.publicKeyBlob
            )
            publicKeyData = result.publicKeyData
            algorithm = result.keySize >= 4096 ? .rsa4096 : .rsa2048

        case .mldsa44, .mldsa65, .mldsa87:
            let key = try await importMLDSA(
                parsedKey: parsedKey,
                session: session,
                slot: slot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy
            )
            mldsaPublicKey = key
            publicKeyData = YubiKeyKeyConverter.sshPublicKeyBlob(for: key)
            algorithm = YubiKeyKeyConverter.algorithm(for: key.parameterSet)
            if let expected = sshKey.publicKeyBlob, expected != publicKeyData {
                throw YubiKeyError.importFailed("The YubiKey reports a different public key than the imported ML-DSA key")
            }

        default:
            throw YubiKeyError.unsupportedKeyTypeForImport(parsedKey.keyType.rawValue)
        }

        // 7. Generate and store certificate
        if let mldsaPublicKey {
            let der = YubiKeyKeyConverter.mldsaSlotCertificate(for: mldsaPublicKey, commonName: sshKey.name)
            try await session.putCertificate(X509Cert(der: der), in: slot.toYubiKitSlot, compressed: false)
        } else {
            try await createAndStoreCertificate(
                session: session,
                slot: slot.toYubiKitSlot,
                publicKeyData: publicKeyData,
                algorithm: algorithm,
                keyName: sshKey.name
            )
        }

        // 8. Create new SSHKey with YubiKey reference
        let fingerprint = generateFingerprint(publicKeyData)

        let yubiKeyInfo = YubiKeyInfo(
            serialNumber: serial,
            pivSlot: slot,
            algorithm: algorithm,
            lastConnectionMethod: nil,
            deviceName: nil
        )

        // Use a YubiKey-specific name to distinguish from the software key
        let yubiKeyName = "\(sshKey.name) (YubiKey)"

        var newSSHKey = SSHKey(
            name: yubiKeyName,
            keyType: .yubiKeyPIV,
            fingerprint: fingerprint,
            hasPassphrase: false,
            storageLevel: .iCloudSync,
            authRequirement: .perUse
        )
        newSSHKey.yubiKeyInfo = yubiKeyInfo
        newSSHKey.publicKeyBlob = publicKeyData
        // GPG forwarding can use this PIV key too — compute the
        // keygrip from the same public material now so the agent
        // forwarding flow doesn't have to re-derive it later.
        let yubiKeyRef = YubiKeyReference(
            keyID: newSSHKey.id,
            serialNumber: yubiKeyInfo.serialNumber,
            pivSlot: yubiKeyInfo.pivSlot,
            publicKeyBlob: publicKeyData,
            algorithm: yubiKeyInfo.algorithm
        )
        newSSHKey.gpgKeygripHex = SSHKeyGPGBridge.keygripHex(
            for: .yubiKey(yubiKeyRef),
            keyType: .yubiKeyPIV
        )

        // 9. Save the new YubiKey reference (allows duplicate fingerprint with different key type)
        try keyManager.saveYubiKeyReference(newSSHKey, allowDuplicateFingerprint: true)

        // 10. Optionally delete the original software key
        if deleteFromKeychain {
            Self.logger.info("Deleting original software key from Keychain")
            try? keyManager.deleteKey(id: keyID)
        }

        Self.logger.info("Key import completed successfully")

        let publicKeyString = formatSSHPublicKeyString(publicKeyData, algorithm: algorithm, comment: "YubiKey-imported")

        return ImportResult(
            yubiKeySSHKey: newSSHKey,
            publicKeyString: publicKeyString,
            fingerprint: fingerprint
        )
    }

    // MARK: - Private Import Helpers

    private struct KeyImportResult {
        let publicKeyData: Data
        let keySize: Int
    }

    /// Import Ed25519 key
    private func importEd25519(
        parsedKey: SSHKeyParser.ParsedKey,
        keyString: String,
        passphrase: String?,
        session: PIVSession,
        slot: PIVSlot,
        pinPolicy: PIV.PinPolicy,
        touchPolicy: PIV.TouchPolicy
    ) async throws -> KeyImportResult {
        Self.logger.info("Importing Ed25519 key")

        // Re-parse to extract raw seed (we need the 32-byte seed for YubiKit)
        let seed = try extractEd25519Seed(from: keyString, passphrase: passphrase)

        guard let yubiKitKey = Ed25519.PrivateKey(seed: seed) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit Ed25519 key")
        }

        // Import to YubiKey
        try await session.putPrivateKey(
            yubiKitKey,
            in: slot.toYubiKitSlot,
            pinPolicy: pinPolicy,
            touchPolicy: touchPolicy
        )

        // Build SSH public key data
        var publicKeyBuffer = Data()
        writeSSHString(&publicKeyBuffer, "ssh-ed25519")
        writeSSHBuffer(&publicKeyBuffer, yubiKitKey.publicKey.keyData)

        return KeyImportResult(publicKeyData: publicKeyBuffer, keySize: 256)
    }

    /// Import a pure ML-DSA seed and read the slot's public key back from the
    /// device, so the stored blob is the one the YubiKey will sign for.
    private func importMLDSA(
        parsedKey: SSHKeyParser.ParsedKey,
        session: PIVSession,
        slot: PIVSlot,
        pinPolicy: PIV.PinPolicy,
        touchPolicy: PIV.TouchPolicy
    ) async throws -> YubiKit.MLDSA.PublicKey {
        guard case .mldsa(let yubiKitKey) = try YubiKeyKeyConverter.convert(parsedKey: parsedKey) else {
            throw YubiKeyError.keyConversionFailed("Expected an ML-DSA key")
        }
        Self.logger.info("Importing ML-DSA key")

        do {
            try await session.putPrivateKey(
                yubiKitKey,
                in: slot.toYubiKitSlot,
                pinPolicy: pinPolicy,
                touchPolicy: touchPolicy
            )
            guard case .mlDSA(let publicKey) = try await session.getMetadata(in: slot.toYubiKitSlot).publicKey else {
                throw YubiKeyError.importFailed("The YubiKey did not report an ML-DSA public key")
            }
            return publicKey
        } catch let error as PIVSessionError {
            throw YubiKeyError.from(error)
        }
    }

    /// Import ECDSA key
    private func importECDSA(
        parsedKey: SSHKeyParser.ParsedKey,
        keyString: String,
        passphrase: String?,
        session: PIVSession,
        slot: PIVSlot,
        pinPolicy: PIV.PinPolicy,
        touchPolicy: PIV.TouchPolicy,
        curve: EC.Curve
    ) async throws -> KeyImportResult {
        let curveDesc = curve == .secp256r1 ? "P-256" : "P-384"
        Self.logger.info("Importing ECDSA key for curve \(curveDesc)")

        // Re-parse to extract raw scalar
        let (scalar, publicPoint) = try extractECDSAScalar(from: keyString, passphrase: passphrase, curve: curve)

        // Create YubiKit EC private key
        guard let yubiKitKey = EC.PrivateKey(
            x963: publicPoint + scalar,
            curve: curve
        ) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit EC key")
        }

        // Import to YubiKey
        try await session.putPrivateKey(
            yubiKitKey,
            in: slot.toYubiKitSlot,
            pinPolicy: pinPolicy,
            touchPolicy: touchPolicy
        )

        // Build SSH public key data
        var publicKeyBuffer = Data()
        let curveName = curve == .secp256r1 ? "nistp256" : "nistp384"
        let keyType = curve == .secp256r1 ? "ecdsa-sha2-nistp256" : "ecdsa-sha2-nistp384"
        writeSSHString(&publicKeyBuffer, keyType)
        writeSSHString(&publicKeyBuffer, curveName)
        writeSSHBuffer(&publicKeyBuffer, publicPoint)

        return KeyImportResult(publicKeyData: publicKeyBuffer, keySize: curve.keySizeInBits)
    }

    /// Import RSA key
    private func importRSA(
        parsedKey: SSHKeyParser.ParsedKey,
        session: PIVSession,
        slot: PIVSlot,
        pinPolicy: PIV.PinPolicy,
        touchPolicy: PIV.TouchPolicy,
        originalPublicKeyBlob: Data?
    ) async throws -> KeyImportResult {
        Self.logger.info("Importing RSA key")

        guard let crtParams = parsedKey.rsaCRTParams else {
            throw YubiKeyError.missingCRTParameters
        }

        // Strip leading zeros from all parameters - OpenSSH MPInt format adds a leading
        // 0x00 byte when the high bit is set, but YubiKit expects exact byte counts
        // (e.g., 512 bytes for RSA-4096 modulus, not 513)
        let n = stripLeadingZeros(crtParams.n)
        let e = stripLeadingZeros(crtParams.e)
        let d = stripLeadingZeros(crtParams.d)
        let p = stripLeadingZeros(crtParams.p)
        let q = stripLeadingZeros(crtParams.q)
        let dP = stripLeadingZeros(crtParams.dP)
        let dQ = stripLeadingZeros(crtParams.dQ)
        let qInv = stripLeadingZeros(crtParams.qInv)

        Self.logger.info("RSA key sizes after stripping: n=\(n.count), e=\(e.count), d=\(d.count), p=\(p.count), q=\(q.count), dP=\(dP.count), dQ=\(dQ.count), qInv=\(qInv.count)")

        // Ghostty only supports RSA exponent 65537 (0x010001) for YubiKey PIV import.
        // Other exponents have been observed to import but produce invalid signatures.
        let supportedExponent = Data([0x01, 0x00, 0x01])
        if e != supportedExponent {
            let eHex = e.map { String(format: "%02x", $0) }.joined()
            throw YubiKeyError.importFailed(
                "RSA public exponent must be 65537 (0x010001) for YubiKey PIV import. This key uses 0x\(eHex)."
            )
        }

        // Verify n = p * q (the YubiKey will compute this internally)
        let computedN = multiplyBigIntegers(p, q)
        if computedN != n {
            Self.logger.error("WARNING: Parsed n (\(n.count) bytes) does not match p*q (\(computedN.count) bytes)")
        } else {
            Self.logger.info("Verified: parsed n matches p*q")
        }

        // Verify p > q (PKCS#1 convention) - the parser should have already ensured this
        let pGreaterThanQ = compareBigIntegers(p, q) > 0
        if !pGreaterThanQ {
            Self.logger.warning("Prime ordering incorrect after parsing! p should be > q. This may cause signature verification failures.")
        }
        Self.logger.info("Prime ordering check: p > q = \(pGreaterThanQ)")

        // Avoid logging key material; sizes and validation results are sufficient.

        // Create YubiKit RSA private key
        guard let yubiKitKey = RSA.PrivateKey(
            n: n,
            e: e,
            d: d,
            p: p,
            q: q,
            dP: dP,
            dQ: dQ,
            qInv: qInv
        ) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit RSA key - modulus size \(n.count * 8) bits may not be supported")
        }

        // Import to YubiKey
        try await session.putPrivateKey(
            yubiKitKey,
            in: slot.toYubiKitSlot,
            pinPolicy: pinPolicy,
            touchPolicy: touchPolicy
        )

        // Verify the imported key by doing a test sign/verify
        Self.logger.info("Performing signature verification test...")
        let testMessage = "RSA import verification test".data(using: .utf8)!
        let testPassed = await verifyImportedRSAKey(
            session: session,
            slot: slot,
            n: n,
            e: e,
            keySize: n.count * 8,
            testMessage: testMessage
        )
        if testPassed {
            Self.logger.info("Signature verification test PASSED - imported key is working correctly")
        } else {
            Self.logger.error("Signature verification test FAILED - imported key may produce invalid signatures")
        }

        // Build SSH public key data (use stripped values for consistency)
        var publicKeyBuffer = Data()
        writeSSHString(&publicKeyBuffer, "ssh-rsa")
        writeSSHMPInt(&publicKeyBuffer, e)
        writeSSHMPInt(&publicKeyBuffer, n)
        let validatedPublicKey: Data
        if let originalBlob = originalPublicKeyBlob,
           !originalBlob.isEmpty,
           let parsedOriginal = parseRSAPublicKeyBlob(originalBlob),
           parsedOriginal.e == e,
           parsedOriginal.n == n {
            Self.logger.info("Using original RSA public key blob (validated)")
            validatedPublicKey = originalBlob
        } else {
            if let originalBlob = originalPublicKeyBlob, !originalBlob.isEmpty {
                Self.logger.warning("Original RSA public key blob did not match key material; using constructed blob")
            }
            validatedPublicKey = publicKeyBuffer
        }

        return KeyImportResult(publicKeyData: validatedPublicKey, keySize: n.count * 8)
    }

    /// Parse an SSH RSA public key blob and extract (e, n).
    private func parseRSAPublicKeyBlob(_ blob: Data) -> (e: Data, n: Data)? {
        var buffer = ByteBuffer(data: blob)
        guard let keyType = buffer.readSSHString(), keyType == "ssh-rsa" else {
            return nil
        }
        guard let eBuffer = buffer.readSSHBuffer(),
              let nBuffer = buffer.readSSHBuffer(),
              let eData = eBuffer.getData(at: eBuffer.readerIndex, length: eBuffer.readableBytes),
              let nData = nBuffer.getData(at: nBuffer.readerIndex, length: nBuffer.readableBytes) else {
            return nil
        }

        return (stripLeadingZeros(eData), stripLeadingZeros(nData))
    }

    /// Compare two big integers represented as big-endian Data
    /// Returns: negative if a < b, 0 if equal, positive if a > b
    private func compareBigIntegers(_ a: Data, _ b: Data) -> Int {
        // Compare lengths first (longer = bigger for positive integers)
        if a.count != b.count {
            return a.count - b.count
        }
        // Same length, compare byte by byte from most significant
        for i in 0..<a.count {
            if a[i] != b[i] {
                return Int(a[i]) - Int(b[i])
            }
        }
        return 0
    }

    /// Compute modular inverse: a^(-1) mod m using BoringSSL
    private func computeModularInverse(_ a: Data, modulo m: Data) throws -> Data {
        guard let a_bn = CCryptoBoringSSL_BN_bin2bn(Array(a), a.count, nil),
              let m_bn = CCryptoBoringSSL_BN_bin2bn(Array(m), m.count, nil),
              let result_bn = CCryptoBoringSSL_BN_new(),
              let ctx = CCryptoBoringSSL_BN_CTX_new() else {
            throw YubiKeyError.keyConversionFailed("Failed to allocate BIGNUMs for modular inverse")
        }
        defer {
            CCryptoBoringSSL_BN_free(a_bn)
            CCryptoBoringSSL_BN_free(m_bn)
            CCryptoBoringSSL_BN_free(result_bn)
            CCryptoBoringSSL_BN_CTX_free(ctx)
        }

        // Compute a^(-1) mod m
        guard CCryptoBoringSSL_BN_mod_inverse(result_bn, a_bn, m_bn, ctx) != nil else {
            throw YubiKeyError.keyConversionFailed("Failed to compute modular inverse")
        }

        // Convert result back to Data
        let numBytes = (CCryptoBoringSSL_BN_num_bits(result_bn) + 7) / 8
        var bytes = [UInt8](repeating: 0, count: Int(numBytes))
        CCryptoBoringSSL_BN_bn2bin(result_bn, &bytes)
        return Data(bytes)
    }

    /// Strip leading zero bytes from data (MPInt padding removal)
    /// Keeps at least one byte even if it's zero
    private func stripLeadingZeros(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }

    /// Multiply two big integers using BoringSSL
    private func multiplyBigIntegers(_ a: Data, _ b: Data) -> Data {
        guard let a_bn = CCryptoBoringSSL_BN_bin2bn(Array(a), a.count, nil),
              let b_bn = CCryptoBoringSSL_BN_bin2bn(Array(b), b.count, nil),
              let result_bn = CCryptoBoringSSL_BN_new(),
              let ctx = CCryptoBoringSSL_BN_CTX_new() else {
            return Data()
        }
        defer {
            CCryptoBoringSSL_BN_free(a_bn)
            CCryptoBoringSSL_BN_free(b_bn)
            CCryptoBoringSSL_BN_free(result_bn)
            CCryptoBoringSSL_BN_CTX_free(ctx)
        }

        guard CCryptoBoringSSL_BN_mul(result_bn, a_bn, b_bn, ctx) == 1 else {
            return Data()
        }

        let numBytes = (CCryptoBoringSSL_BN_num_bits(result_bn) + 7) / 8
        var bytes = [UInt8](repeating: 0, count: Int(numBytes))
        CCryptoBoringSSL_BN_bn2bin(result_bn, &bytes)
        return Data(bytes)
    }

    /// Verify an imported RSA key by signing a test message and verifying with BoringSSL
    private func verifyImportedRSAKey(
        session: PIVSession,
        slot: PIVSlot,
        n: Data,
        e: Data,
        keySize: Int,
        testMessage: Data
    ) async -> Bool {
        do {
            // Sign with YubiKey
            let keyType: PIV.RSAKey = keySize >= 4096 ? .rsa(.bits4096) : .rsa(.bits2048)
            let signature = try await session.sign(testMessage, in: slot.toYubiKitSlot, keyType: keyType, using: .pkcs1v15(.sha256))

            Self.logger.info("YubiKey produced signature: \(signature.count) bytes")

            // Verify with BoringSSL
            let verified = verifyRSASignature(message: testMessage, signature: signature, n: n, e: e)
            return verified
        } catch {
            Self.logger.error("Signature test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Verify an RSA signature using BoringSSL
    private func verifyRSASignature(message: Data, signature: Data, n: Data, e: Data) -> Bool {
        // Create RSA context
        guard let rsa = CCryptoBoringSSL_RSA_new() else {
            Self.logger.error("Failed to create RSA context")
            return false
        }
        defer { CCryptoBoringSSL_RSA_free(rsa) }

        // Set public key (n, e)
        guard let n_bn = CCryptoBoringSSL_BN_bin2bn(Array(n), n.count, nil),
              let e_bn = CCryptoBoringSSL_BN_bin2bn(Array(e), e.count, nil) else {
            Self.logger.error("Failed to create BIGNUMs for n and e")
            return false
        }

        // RSA_set0_key takes ownership of the BIGNUMs, so don't free them separately
        guard CCryptoBoringSSL_RSA_set0_key(rsa, n_bn, e_bn, nil) == 1 else {
            Self.logger.error("Failed to set RSA public key")
            CCryptoBoringSSL_BN_free(n_bn)
            CCryptoBoringSSL_BN_free(e_bn)
            return false
        }

        // Compute SHA-256 hash of message
        let hash = Array(SHA256.hash(data: message))

        // Verify signature
        let result = CCryptoBoringSSL_RSA_verify(
            NID_sha256,
            hash,
            hash.count,
            Array(signature),
            signature.count,
            rsa
        )

        if result == 1 {
            Self.logger.info("RSA signature verification: SUCCESS")
            return true
        } else {
            Self.logger.error("RSA signature verification: FAILED")
            // Get more error info
            let errorCode = CCryptoBoringSSL_ERR_get_error()
            Self.logger.error("BoringSSL error code: \(errorCode)")
            return false
        }
    }

    // MARK: - Key Extraction Helpers

    /// Extract Ed25519 seed from key string
    private func extractEd25519Seed(from keyString: String, passphrase: String?) throws -> Data {
        // Parse the OpenSSH format to get the raw seed
        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()

        guard let keyData = Data(base64Encoded: base64String) else {
            throw YubiKeyError.importFailed("Invalid base64 encoding")
        }

        var buffer = ByteBuffer(data: keyData)

        // Skip OpenSSH header
        guard buffer.readString(length: "openssh-key-v1".count) == "openssh-key-v1",
              buffer.readInteger(as: UInt8.self) == 0x00 else {
            throw YubiKeyError.importFailed("Invalid OpenSSH format")
        }

        // Read cipher and KDF
        let cipher = try OpenSSH.Cipher(consuming: &buffer)
        let kdf = try OpenSSH.KDF(consuming: &buffer)

        // Skip number of keys and public key
        _ = buffer.readInteger(as: UInt32.self)
        _ = buffer.readSSHBuffer()

        // Read private key blob
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw YubiKeyError.importFailed("Missing private key blob")
        }

        // Decrypt if needed
        if cipher != .none {
            guard let passphraseData = passphrase?.data(using: .utf8) else {
                throw YubiKeyError.importFailed("Passphrase required for encrypted key")
            }
            try kdf.withKeyAndIV(cipher: cipher, basedOnDecryptionKey: passphraseData) { key, iv in
                try cipher.decryptBuffer(&privateKeyBuffer, key: key, iv: iv)
            }
        }

        // Verify check bytes
        guard let check1 = privateKeyBuffer.readInteger(as: UInt32.self),
              let check2 = privateKeyBuffer.readInteger(as: UInt32.self),
              check1 == check2 else {
            throw YubiKeyError.importFailed("Invalid key data or wrong passphrase")
        }

        // Skip key type string
        _ = privateKeyBuffer.readSSHString()

        // Skip public key buffer
        _ = privateKeyBuffer.readSSHBuffer()

        // Read private key (64 bytes: 32 byte seed + 32 byte public key)
        guard let privateKeyData = privateKeyBuffer.readSSHBuffer(),
              privateKeyData.readableBytes >= 32,
              let seedBytes = privateKeyData.getBytes(at: privateKeyData.readerIndex, length: 32) else {
            throw YubiKeyError.importFailed("Failed to extract Ed25519 seed")
        }

        return Data(seedBytes)
    }

    /// Extract ECDSA scalar and public point from key string
    private func extractECDSAScalar(from keyString: String, passphrase: String?, curve: EC.Curve) throws -> (scalar: Data, publicPoint: Data) {
        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()

        guard let keyData = Data(base64Encoded: base64String) else {
            throw YubiKeyError.importFailed("Invalid base64 encoding")
        }

        var buffer = ByteBuffer(data: keyData)

        // Skip OpenSSH header
        guard buffer.readString(length: "openssh-key-v1".count) == "openssh-key-v1",
              buffer.readInteger(as: UInt8.self) == 0x00 else {
            throw YubiKeyError.importFailed("Invalid OpenSSH format")
        }

        // Read cipher and KDF
        let cipher = try OpenSSH.Cipher(consuming: &buffer)
        let kdf = try OpenSSH.KDF(consuming: &buffer)

        // Skip number of keys and public key
        _ = buffer.readInteger(as: UInt32.self)
        _ = buffer.readSSHBuffer()

        // Read private key blob
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw YubiKeyError.importFailed("Missing private key blob")
        }

        // Decrypt if needed
        if cipher != .none {
            guard let passphraseData = passphrase?.data(using: .utf8) else {
                throw YubiKeyError.importFailed("Passphrase required for encrypted key")
            }
            try kdf.withKeyAndIV(cipher: cipher, basedOnDecryptionKey: passphraseData) { key, iv in
                try cipher.decryptBuffer(&privateKeyBuffer, key: key, iv: iv)
            }
        }

        // Verify check bytes
        guard let check1 = privateKeyBuffer.readInteger(as: UInt32.self),
              let check2 = privateKeyBuffer.readInteger(as: UInt32.self),
              check1 == check2 else {
            throw YubiKeyError.importFailed("Invalid key data or wrong passphrase")
        }

        // Skip key type string
        _ = privateKeyBuffer.readSSHString()

        // Skip curve name
        _ = privateKeyBuffer.readSSHString()

        // Read public point
        guard let publicPointBuffer = privateKeyBuffer.readSSHBuffer(),
              let publicPoint = publicPointBuffer.getData(at: publicPointBuffer.readerIndex, length: publicPointBuffer.readableBytes) else {
            throw YubiKeyError.importFailed("Failed to extract ECDSA public point")
        }

        // Read scalar
        guard let scalarBuffer = privateKeyBuffer.readSSHBuffer(),
              let scalar = scalarBuffer.getData(at: scalarBuffer.readerIndex, length: scalarBuffer.readableBytes) else {
            throw YubiKeyError.importFailed("Failed to extract ECDSA scalar")
        }

        return (scalar, publicPoint)
    }

    // MARK: - Certificate Creation

    private func createAndStoreCertificate(
        session: PIVSession,
        slot: PIV.Slot,
        publicKeyData: Data,
        algorithm: YubiKeyAlgorithm,
        keyName: String
    ) async throws {
        let serialNumber = UInt64.random(in: 1...UInt64.max)

        let certificateData: Data
        if algorithm == .ed25519 {
            // Extract raw 32-byte key from SSH format
            var buffer = ByteBuffer(data: publicKeyData)
            _ = buffer.readSSHString() // skip "ssh-ed25519"
            guard let keyBuffer = buffer.readSSHBuffer(),
                  let rawKey = keyBuffer.getData(at: keyBuffer.readerIndex, length: keyBuffer.readableBytes) else {
                throw YubiKeyError.importFailed("Failed to extract Ed25519 public key for certificate")
            }
            certificateData = buildEd25519Certificate(publicKey: rawKey, subject: "CN=\(keyName)", serialNumber: serialNumber)
        } else {
            certificateData = try buildCertificate(
                publicKeyData: publicKeyData,
                algorithm: algorithm,
                subject: "CN=\(keyName)",
                serialNumber: serialNumber
            )
        }

        let x509Cert = X509Cert(der: certificateData)
        try await session.putCertificate(x509Cert, in: slot, compressed: false)
    }

    /// Build a minimal self-signed certificate for RSA/ECDSA
    private func buildCertificate(
        publicKeyData: Data,
        algorithm: YubiKeyAlgorithm,
        subject: String,
        serialNumber: UInt64
    ) throws -> Data {
        // For RSA/ECDSA, we need to extract the key from SSH format and build SPKI
        var cert = Data()

        // Build TBSCertificate
        var tbsCert = Data()

        // Version (v3 = 2)
        tbsCert.append(contentsOf: [0xA0, 0x03, 0x02, 0x01, 0x02])

        // Serial number
        let serialData = withUnsafeBytes(of: serialNumber.bigEndian) { Data($0) }
        tbsCert.append(0x02) // INTEGER
        tbsCert.append(UInt8(serialData.count))
        tbsCert.append(serialData)

        // Signature algorithm
        let signatureAlgOID = algorithm.isRSA ? rsaSHA256OID : ecdsaSHA256OID
        tbsCert.append(contentsOf: wrapSequence(signatureAlgOID))

        // Issuer and Subject
        let subjectDN = buildDistinguishedName(subject)
        tbsCert.append(contentsOf: wrapSequence(subjectDN))
        let validity = buildValidity()
        tbsCert.append(contentsOf: wrapSequence(validity))
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Subject Public Key Info (use a placeholder - PIV accepts dummy certs)
        let spki = try buildSubjectPublicKeyInfo(sshPublicKey: publicKeyData, algorithm: algorithm)
        tbsCert.append(contentsOf: wrapSequence(spki))

        // Wrap TBSCertificate
        let tbsCertSeq = wrapSequence(tbsCert)

        // Signature algorithm and dummy signature
        let signatureAlgSeq = wrapSequence(signatureAlgOID)
        let dummySignature: [UInt8] = [0x03, 0x01, 0x00]

        cert.append(contentsOf: tbsCertSeq)
        cert.append(contentsOf: signatureAlgSeq)
        cert.append(contentsOf: dummySignature)

        return Data(wrapSequence(cert))
    }

    /// Build Ed25519 certificate (reuse from YubiKeyKeyGenerator)
    private func buildEd25519Certificate(publicKey: Data, subject: String, serialNumber: UInt64) -> Data {
        var cert = Data()

        // Build TBSCertificate
        var tbsCert = Data()

        // Version (v3 = 2)
        tbsCert.append(contentsOf: [0xA0, 0x03, 0x02, 0x01, 0x02])

        // Serial number
        let serialData = withUnsafeBytes(of: serialNumber.bigEndian) { Data($0) }
        tbsCert.append(0x02)
        tbsCert.append(UInt8(serialData.count))
        tbsCert.append(serialData)

        // Signature algorithm - Ed25519 (OID 1.3.101.112)
        let ed25519OID = Data([0x06, 0x03, 0x2B, 0x65, 0x70])
        tbsCert.append(contentsOf: wrapSequence(ed25519OID))

        // Issuer and Subject
        let subjectDN = buildDistinguishedName(subject)
        tbsCert.append(contentsOf: wrapSequence(subjectDN))
        let validity = buildValidity()
        tbsCert.append(contentsOf: wrapSequence(validity))
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Subject Public Key Info for Ed25519
        var spki = Data()
        spki.append(contentsOf: wrapSequence(ed25519OID))
        var bitString = Data([0x00])
        bitString.append(publicKey)
        spki.append(0x03)
        spki.append(contentsOf: encodeLength(bitString.count))
        spki.append(bitString)
        tbsCert.append(contentsOf: wrapSequence(spki))

        // Wrap TBSCertificate
        let tbsCertSeq = wrapSequence(tbsCert)

        // Signature algorithm and dummy signature
        let signatureAlgSeq = wrapSequence(ed25519OID)
        let dummySignature: [UInt8] = [0x03, 0x01, 0x00]

        cert.append(contentsOf: tbsCertSeq)
        cert.append(contentsOf: signatureAlgSeq)
        cert.append(contentsOf: dummySignature)

        return Data(wrapSequence(cert))
    }

    // MARK: - ASN.1/DER Helpers

    private var rsaSHA256OID: Data {
        Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
    }

    private var ecdsaSHA256OID: Data {
        Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    }

    private func buildDistinguishedName(_ cn: String) -> Data {
        let cnOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let cnValue = cn.replacingOccurrences(of: "CN=", with: "")
        let cnString: [UInt8] = [0x0C] + [UInt8(cnValue.utf8.count)] + Array(cnValue.utf8)

        var atv = Data(cnOID)
        atv.append(contentsOf: cnString)
        let atvSeq = wrapSequence(atv)
        return wrapSet(Data(atvSeq))
    }

    private func buildValidity() -> Data {
        let now = Date()
        let oneYearLater = Calendar.current.date(byAdding: .year, value: 1, to: now)!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let notBefore = formatter.string(from: now)
        let notAfter = formatter.string(from: oneYearLater)

        var validity = Data()
        validity.append(0x17)
        validity.append(UInt8(notBefore.count))
        validity.append(contentsOf: notBefore.utf8)
        validity.append(0x17)
        validity.append(UInt8(notAfter.count))
        validity.append(contentsOf: notAfter.utf8)

        return validity
    }

    private func buildSubjectPublicKeyInfo(sshPublicKey: Data, algorithm: YubiKeyAlgorithm) throws -> Data {
        var spki = Data()

        if algorithm.isRSA {
            // RSA OID
            let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
            spki.append(contentsOf: wrapSequence(Data(rsaOID)))

            // Extract e and n from SSH format and build PKCS#1 public key
            var buffer = ByteBuffer(data: sshPublicKey)
            _ = buffer.readSSHString() // skip "ssh-rsa"
            guard let eBuffer = buffer.readSSHBuffer(),
                  let nBuffer = buffer.readSSHBuffer(),
                  let e = eBuffer.getData(at: eBuffer.readerIndex, length: eBuffer.readableBytes),
                  let n = nBuffer.getData(at: nBuffer.readerIndex, length: nBuffer.readableBytes) else {
                throw YubiKeyError.importFailed("Failed to parse RSA public key")
            }

            // Build PKCS#1 RSAPublicKey: SEQUENCE { n INTEGER, e INTEGER }
            var rsaPubKey = Data()
            rsaPubKey.append(contentsOf: encodeInteger(n))
            rsaPubKey.append(contentsOf: encodeInteger(e))
            let rsaPubKeySeq = Data(wrapSequence(rsaPubKey))

            // BIT STRING wrapper
            var bitString = Data([0x00])
            bitString.append(rsaPubKeySeq)
            spki.append(0x03)
            spki.append(contentsOf: encodeLength(bitString.count))
            spki.append(bitString)
        } else {
            // ECDSA OID
            let ecOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
            let curveOID: [UInt8] = algorithm == .ecdsaP256 ?
                [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] :
                [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]

            var algId = Data(ecOID)
            algId.append(contentsOf: curveOID)
            spki.append(contentsOf: wrapSequence(algId))

            // Extract public point from SSH format
            var buffer = ByteBuffer(data: sshPublicKey)
            _ = buffer.readSSHString() // skip key type
            _ = buffer.readSSHString() // skip curve name
            guard let pointBuffer = buffer.readSSHBuffer(),
                  let publicPoint = pointBuffer.getData(at: pointBuffer.readerIndex, length: pointBuffer.readableBytes) else {
                throw YubiKeyError.importFailed("Failed to parse ECDSA public key")
            }

            // BIT STRING wrapper
            var bitString = Data([0x00])
            bitString.append(publicPoint)
            spki.append(0x03)
            spki.append(contentsOf: encodeLength(bitString.count))
            spki.append(bitString)
        }

        return spki
    }

    private func wrapSequence(_ data: Data) -> [UInt8] {
        var result: [UInt8] = [0x30]
        result.append(contentsOf: encodeLength(data.count))
        result.append(contentsOf: data)
        return result
    }

    private func wrapSet(_ data: Data) -> Data {
        var result = Data([0x31])
        result.append(contentsOf: encodeLength(data.count))
        result.append(data)
        return result
    }

    private func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }

    private func encodeInteger(_ data: Data) -> [UInt8] {
        var bytes = Array(data)

        // Remove leading zeros (but keep one if needed for sign)
        while bytes.count > 1 && bytes[0] == 0x00 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit is set (positive integer)
        if !bytes.isEmpty && (bytes[0] & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }

        var result: [UInt8] = [0x02] // INTEGER tag
        result.append(contentsOf: encodeLength(bytes.count))
        result.append(contentsOf: bytes)
        return result
    }

    // MARK: - Management Key Authentication

    private func authenticateManagement(session: PIVSession, customKey: Data?) async throws {
        let keyToUse = customKey ?? Self.defaultManagementKeyAES

        do {
            try await session.authenticate(with: keyToUse)
            Self.logger.info("Authenticated with management key")
        } catch {
            if customKey != nil {
                throw YubiKeyError.authenticationFailed("Management key authentication failed. The key may be incorrect.")
            }

            // Try Triple-DES default as fallback
            do {
                try await session.authenticate(with: Self.defaultManagementKeyTripleDES)
                Self.logger.info("Authenticated with default Triple-DES management key")
            } catch {
                throw YubiKeyError.authenticationFailed(
                    "Management key authentication failed. Your YubiKey may have a non-default management key configured."
                )
            }
        }
    }

    // MARK: - SSH Wire Format Helpers

    private func writeSSHString(_ buffer: inout Data, _ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        var length = UInt32(data.count).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        buffer.append(data)
    }

    private func writeSSHBuffer(_ buffer: inout Data, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        buffer.append(data)
    }

    private func writeSSHMPInt(_ buffer: inout Data, _ data: Data) {
        var bytes = [UInt8](data)

        // Strip leading zeros (but keep at least one byte)
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit is set (MPInt must be positive)
        if (bytes.first ?? 0) & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }

        writeSSHBuffer(&buffer, Data(bytes))
    }

    private func generateFingerprint(_ publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func formatSSHPublicKeyString(_ publicKeyData: Data, algorithm: YubiKeyAlgorithm, comment: String) -> String {
        let base64 = publicKeyData.base64EncodedString()
        return "\(algorithm.sshKeyTypeString) \(base64) \(comment)"
    }
}
