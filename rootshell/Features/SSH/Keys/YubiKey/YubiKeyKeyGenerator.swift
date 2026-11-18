//
//  YubiKeyKeyGenerator.swift
//  rootshell
//
//  Generates new SSH keys on YubiKey PIV slots
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit
import Crypto

/// Handles key generation on YubiKey PIV slots
@MainActor
final class YubiKeyKeyGenerator {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyKeyGenerator"
    )

    private let connectionManager: YubiKeyConnectionManager

    /// Default PIV management key (factory default) - Triple-DES (24 bytes)
    /// Used on older YubiKeys and YubiKey 5 series before firmware 5.4.2
    private static let defaultManagementKeyTripleDES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    /// Default PIV management key (factory default) - AES-192 (24 bytes)
    /// Used on YubiKey 5 series firmware 5.4.2 and later
    private static let defaultManagementKeyAES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    init(connectionManager: YubiKeyConnectionManager) {
        self.connectionManager = connectionManager
    }

    @MainActor
    convenience init() {
        self.init(connectionManager: .shared)
    }

    // MARK: - Key Generation

    /// Generate a new key pair on the YubiKey
    /// - Parameters:
    ///   - target: YubiKey and slot the user confirmed; any other key is
    ///     refused before the slot is touched
    ///   - algorithm: Algorithm for the key (ECDSA P-256/P-384, RSA 2048/4096, Ed25519 on 5.7+)
    ///   - name: User-specified name for the key (appears in public key comment)
    ///   - managementKey: PIV management key (uses default if nil)
    ///   - pin: PIN for slots that require it
    /// - Returns: Generated key info including public key in SSH format
    func generateKey(
        on target: YubiKeyWriteTarget,
        algorithm: YubiKeyAlgorithm,
        name: String,
        managementKey: Data? = nil,
        pin: String? = nil
    ) async throws -> GeneratedYubiKeyKey {
        let slot = target.slot
        Self.logger.info("Generating \(algorithm.rawValue) key in slot \(slot.rawValue)")

        // A re-tap or re-plug can bring up another YubiKey than the one confirmed.
        // The session is tied to the connection that was checked.
        let (session, method, _) = try await connectionManager.verifiedPIVSession(serial: target.serial)
        let pivSlot = slot.toYubiKitSlot

        // Check Ed25519 support (requires YubiKey 5.7+)
        if algorithm == .ed25519 {
            guard await session.supports(.ed25519) else {
                throw YubiKeyError.unsupportedFeature("Ed25519 requires YubiKey 5.7 or later")
            }
        }
        if algorithm.isPostQuantum {
            guard await session.supports(.mlDSA) else {
                throw YubiKeyError.unsupportedFeature("ML-DSA requires YubiKey firmware 6.0 or later")
            }
        }
        // On NFC power the key never answers an RSA-4096 generate; the session
        // ends in a tag response error instead.
        if algorithm == .rsa4096, method == .nfc {
            throw YubiKeyError.unsupportedFeature("RSA-4096 keys can't be generated over NFC. Connect the YubiKey with USB-C instead.")
        }

        // Authenticate with management key (SDK auto-detects key type)
        try await authenticateManagement(session: session, customKey: managementKey)

        // Verify PIN if required for this slot
        if slot.requiresPIN, let pin = pin {
            try await verifyPIN(session: session, pin: pin)
        }

        // Generate the key pair on the YubiKey using new SDK
        // Returns PublicKey enum (not PIV.PublicKey)
        let generatedKey: PublicKey
        do {
            generatedKey = try await session.generateKey(
                in: pivSlot,
                type: algorithm.toYubiKitKeyType,
                pinPolicy: .defaultPolicy,
                touchPolicy: .defaultPolicy
            )
        } catch {
            // SDK uses typed throws(PIVSessionError)
            throw YubiKeyError.keyGenerationFailed(String(describing: error))
        }

        Self.logger.info("Key generated successfully, creating self-signed certificate")

        // Handle Ed25519 separately since SecKey doesn't support it
        let sshPublicKeyData: Data
        let fingerprint: String

        if case .mlDSA(let mldsaKey) = generatedKey {
            sshPublicKeyData = YubiKeyKeyConverter.sshPublicKeyBlob(for: mldsaKey)
            fingerprint = generateFingerprint(sshPublicKeyData)
            try await storeCertificate(
                YubiKeyKeyConverter.mldsaSlotCertificate(for: mldsaKey, commonName: "YubiKey SSH Key (\(algorithm.displayName))"),
                session: session,
                slot: pivSlot
            )
        } else if algorithm == .ed25519 {
            // Ed25519: extract raw key and convert directly to SSH format
            let rawKey = try extractEd25519RawKey(from: generatedKey)
            sshPublicKeyData = convertEd25519ToSSHPublicKey(rawKey)
            fingerprint = generateFingerprint(sshPublicKeyData)

            // Create and store Ed25519 certificate
            try await createAndStoreEd25519Certificate(session: session, slot: pivSlot, publicKey: rawKey)
        } else {
            // RSA/ECDSA: use SecKey path
            let publicKey = try extractSecKey(from: generatedKey, algorithm: algorithm)

            // Create and store a self-signed certificate (PIV requires a cert in the slot)
            try await createAndStoreCertificate(session: session, slot: pivSlot, publicKey: publicKey, algorithm: algorithm)

            // Convert public key to SSH format
            sshPublicKeyData = try convertToSSHPublicKey(publicKey, algorithm: algorithm)
            fingerprint = generateFingerprint(sshPublicKeyData)
        }

        Self.logger.info("Key generation complete. Fingerprint: \(fingerprint.prefix(16))...")

        return GeneratedYubiKeyKey(
            slot: slot,
            algorithm: algorithm,
            publicKeyData: sshPublicKeyData,
            fingerprint: fingerprint,
            sshPublicKeyString: formatSSHPublicKeyString(sshPublicKeyData, algorithm: algorithm, name: name)
        )
    }

    // MARK: - Management Key Authentication

    private func authenticateManagement(session: PIVSession, customKey: Data?) async throws {
        // New SDK auto-detects key type, so we just need to try with the key
        let keyToUse = customKey ?? Self.defaultManagementKeyAES

        do {
            // New SDK authenticate() auto-detects AES vs Triple-DES
            try await session.authenticate(with: keyToUse)
            Self.logger.info("Authenticated with management key")
        } catch {
            // If custom key failed, that's an error
            if customKey != nil {
                throw YubiKeyError.authenticationFailed("Management key authentication failed. The key may be incorrect.")
            }

            // Try Triple-DES default as fallback (older YubiKeys)
            do {
                try await session.authenticate(with: Self.defaultManagementKeyTripleDES)
                Self.logger.info("Authenticated with default Triple-DES management key")
            } catch {
                throw YubiKeyError.authenticationFailed(
                    "Management key authentication failed. Your YubiKey may have a non-default management key configured. " +
                    "Use YubiKey Manager to reset PIV or provide the correct management key."
                )
            }
        }
    }

    private func verifyPIN(session: PIVSession, pin: String) async throws {
        do {
            let result = try await session.verifyPin(pin)
            switch result {
            case .success:
                return
            case .fail(let retries):
                throw YubiKeyError.pinIncorrect(attemptsRemaining: retries)
            case .pinLocked:
                throw YubiKeyError.pinBlocked
            }
        } catch let error as PIVSessionError {
            throw YubiKeyError.from(error)
        }
    }

    // MARK: - Key Extraction

    /// Extract SecKey from the generated public key for certificate creation
    /// For Ed25519, returns nil since SecKey doesn't support Ed25519 - use extractEd25519RawKey instead
    private func extractSecKey(from publicKey: PublicKey, algorithm: YubiKeyAlgorithm) throws -> SecKey {
        let keyData: Data
        let keyType: CFString
        let keySize: Int

        switch publicKey {
        case .rsa(let rsaKey):
            keyData = rsaKey.pkcs1
            keyType = kSecAttrKeyTypeRSA
            keySize = rsaKey.size.rawValue
        case .ec(let ecKey):
            keyData = ecKey.x963
            keyType = kSecAttrKeyTypeECSECPrimeRandom
            keySize = ecKey.curve == .secp384r1 ? 384 : 256
        case .ed25519:
            // Ed25519 isn't supported by SecKey - this path shouldn't be reached
            // for Ed25519 keys since we handle them specially
            throw YubiKeyError.keyGenerationFailed("Ed25519 keys should use extractEd25519RawKey")
        case .x25519:
            throw YubiKeyError.keyGenerationFailed("X25519 keys are not supported for SSH")
        case .mlDSA, .mlKEM:
            throw YubiKeyError.keyGenerationFailed("Post-quantum keys have no SecKey form")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: keySize
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw YubiKeyError.keyGenerationFailed("Failed to create SecKey: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }

        return secKey
    }

    /// Extract raw Ed25519 public key data
    private func extractEd25519RawKey(from publicKey: PublicKey) throws -> Data {
        guard case .ed25519(let ed25519Key) = publicKey else {
            throw YubiKeyError.keyGenerationFailed("Expected Ed25519 key")
        }
        return ed25519Key.keyData
    }

    // MARK: - Certificate Creation

    private func createAndStoreCertificate(
        session: PIVSession,
        slot: PIV.Slot,
        publicKey: SecKey,
        algorithm: YubiKeyAlgorithm
    ) async throws {
        // Create a self-signed certificate
        // This is required because PIV slots store certificates, not raw keys
        let certificateData = try createSelfSignedCertificateDER(publicKey: publicKey, algorithm: algorithm)

        // Store the certificate in the slot using new SDK (X509Cert from DER)
        let x509Cert = X509Cert(der: certificateData)
        do {
            try await session.putCertificate(x509Cert, in: slot, compressed: false)
        } catch {
            // SDK uses typed throws(PIVSessionError)
            throw YubiKeyError.keyGenerationFailed("Failed to store certificate: \(String(describing: error))")
        }
    }

    private func createSelfSignedCertificateDER(publicKey: SecKey, algorithm: YubiKeyAlgorithm) throws -> Data {
        let serialNumber = UInt64.random(in: 1...UInt64.max)

        // Build a minimal DER-encoded self-signed certificate
        // PIV requires a certificate in the slot, even for SSH-only use
        return try buildMinimalCertificate(
            publicKey: publicKey,
            subject: "CN=YubiKey SSH Key",
            serialNumber: serialNumber,
            algorithm: algorithm
        )
    }

    private func storeCertificate(_ der: Data, session: PIVSession, slot: PIV.Slot) async throws {
        do {
            try await session.putCertificate(X509Cert(der: der), in: slot, compressed: false)
        } catch {
            throw YubiKeyError.keyGenerationFailed("Failed to store certificate: \(String(describing: error))")
        }
    }

    /// Create and store a certificate for Ed25519 keys
    /// Ed25519 requires special handling since SecKey doesn't support it
    private func createAndStoreEd25519Certificate(
        session: PIVSession,
        slot: PIV.Slot,
        publicKey: Data
    ) async throws {
        let serialNumber = UInt64.random(in: 1...UInt64.max)

        // Build Ed25519 certificate DER data
        let certificateData = buildEd25519Certificate(
            publicKey: publicKey,
            subject: "CN=YubiKey SSH Key (Ed25519)",
            serialNumber: serialNumber
        )

        // Store the certificate using X509Cert wrapper
        let x509Cert = X509Cert(der: certificateData)
        do {
            try await session.putCertificate(x509Cert, in: slot, compressed: false)
        } catch {
            // SDK uses typed throws(PIVSessionError)
            throw YubiKeyError.keyGenerationFailed("Failed to store Ed25519 certificate: \(String(describing: error))")
        }
    }

    /// Build a minimal X.509 certificate for Ed25519 keys
    private func buildEd25519Certificate(
        publicKey: Data,
        subject: String,
        serialNumber: UInt64
    ) -> Data {
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

        // Signature algorithm - Ed25519 (OID 1.3.101.112)
        tbsCert.append(contentsOf: wrapSequence(ed25519OID))

        // Issuer (same as subject for self-signed)
        let subjectDN = buildDistinguishedName(subject)
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Validity (1 year from now)
        let validity = buildValidity()
        tbsCert.append(contentsOf: wrapSequence(validity))

        // Subject
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Subject Public Key Info for Ed25519
        let spki = buildEd25519SubjectPublicKeyInfo(publicKey: publicKey)
        tbsCert.append(contentsOf: wrapSequence(spki))

        // Wrap TBSCertificate
        let tbsCertSeq = wrapSequence(tbsCert)

        // Signature algorithm
        let signatureAlgSeq = wrapSequence(ed25519OID)

        // Dummy signature (PIV will accept this for storage)
        let dummySignature: [UInt8] = [0x03, 0x01, 0x00] // BIT STRING, empty

        cert.append(contentsOf: tbsCertSeq)
        cert.append(contentsOf: signatureAlgSeq)
        cert.append(contentsOf: dummySignature)

        return Data(wrapSequence(cert))
    }

    /// Ed25519 algorithm OID (1.3.101.112)
    private var ed25519OID: Data {
        Data([0x06, 0x03, 0x2B, 0x65, 0x70])
    }

    /// Build SubjectPublicKeyInfo for Ed25519
    private func buildEd25519SubjectPublicKeyInfo(publicKey: Data) -> Data {
        var spki = Data()

        // Ed25519 algorithm identifier (no parameters)
        spki.append(contentsOf: wrapSequence(ed25519OID))

        // Public key as BIT STRING
        var bitString = Data([0x00]) // no unused bits
        bitString.append(publicKey)
        spki.append(0x03) // BIT STRING
        spki.append(contentsOf: encodeLength(bitString.count))
        spki.append(bitString)

        return spki
    }

    /// Convert Ed25519 raw public key to SSH wire format
    private func convertEd25519ToSSHPublicKey(_ rawKey: Data) -> Data {
        var buffer = Data()
        writeSSHString(&buffer, "ssh-ed25519")
        writeSSHBuffer(&buffer, rawKey)
        return buffer
    }

    /// Build a minimal self-signed X.509 certificate
    private func buildMinimalCertificate(
        publicKey: SecKey,
        subject: String,
        serialNumber: UInt64,
        algorithm: YubiKeyAlgorithm
    ) throws -> Data {
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw YubiKeyError.keyGenerationFailed("Failed to export public key")
        }

        var cert = Data()

        // Build TBSCertificate
        var tbsCert = Data()

        // Version (v1 = 0, but we use v3 = 2 for extensions support)
        tbsCert.append(contentsOf: [0xA0, 0x03, 0x02, 0x01, 0x02]) // [0] EXPLICIT Version

        // Serial number
        let serialData = withUnsafeBytes(of: serialNumber.bigEndian) { Data($0) }
        tbsCert.append(0x02) // INTEGER
        tbsCert.append(UInt8(serialData.count))
        tbsCert.append(serialData)

        // Signature algorithm (will sign with same key for self-signed)
        let signatureAlgOID = algorithm.isRSA ? rsaSHA256OID : ecdsaSHA256OID
        tbsCert.append(contentsOf: wrapSequence(signatureAlgOID))

        // Issuer (same as subject for self-signed)
        let subjectDN = buildDistinguishedName(subject)
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Validity (1 year from now)
        let validity = buildValidity()
        tbsCert.append(contentsOf: wrapSequence(validity))

        // Subject
        tbsCert.append(contentsOf: wrapSequence(subjectDN))

        // Subject Public Key Info
        let spki = try buildSubjectPublicKeyInfo(publicKeyData: publicKeyData, algorithm: algorithm)
        tbsCert.append(contentsOf: wrapSequence(spki))

        // Wrap TBSCertificate in SEQUENCE
        let tbsCertSeq = wrapSequence(tbsCert)

        // For a self-signed cert stored on YubiKey, we need a valid signature
        // However, since we can't sign with the private key (it's on the YubiKey),
        // we'll create a placeholder signature that will be replaced by the YubiKey
        // Actually, for PIV putCertificate, we need a complete valid certificate

        // Let's use a dummy signature - the YubiKey will accept this for storage
        // In practice, you'd want to sign this properly
        let signatureAlgSeq = wrapSequence(signatureAlgOID)
        let dummySignature: [UInt8] = [0x03, 0x01, 0x00] // BIT STRING, empty

        cert.append(contentsOf: tbsCertSeq)
        cert.append(contentsOf: signatureAlgSeq)
        cert.append(contentsOf: dummySignature)

        return Data(wrapSequence(cert))
    }

    private var rsaSHA256OID: Data {
        // OID 1.2.840.113549.1.1.11 (sha256WithRSAEncryption) + NULL params
        Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
    }

    private var ecdsaSHA256OID: Data {
        // OID 1.2.840.10045.4.3.2 (ecdsa-with-SHA256)
        Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    }

    private func buildDistinguishedName(_ cn: String) -> Data {
        // CN OID: 2.5.4.3
        let cnOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let cnValue = cn.replacingOccurrences(of: "CN=", with: "")
        let cnString: [UInt8] = [0x0C] + [UInt8(cnValue.utf8.count)] + Array(cnValue.utf8) // UTF8String

        var atv = Data(cnOID)
        atv.append(contentsOf: cnString)
        let atvSeq = wrapSequence(atv)

        let rdnSet = wrapSet(Data(atvSeq))
        return rdnSet
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
        validity.append(0x17) // UTCTime
        validity.append(UInt8(notBefore.count))
        validity.append(contentsOf: notBefore.utf8)

        validity.append(0x17) // UTCTime
        validity.append(UInt8(notAfter.count))
        validity.append(contentsOf: notAfter.utf8)

        return validity
    }

    private func buildSubjectPublicKeyInfo(publicKeyData: Data, algorithm: YubiKeyAlgorithm) throws -> Data {
        var spki = Data()

        if algorithm.isRSA {
            // RSA algorithm identifier
            let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
            spki.append(contentsOf: wrapSequence(Data(rsaOID)))

            // RSA public key as BIT STRING
            var bitString = Data([0x00]) // no unused bits
            bitString.append(publicKeyData)
            spki.append(0x03) // BIT STRING
            spki.append(contentsOf: encodeLength(bitString.count))
            spki.append(bitString)
        } else {
            // ECDSA algorithm identifier with curve OID
            let ecOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] // ecPublicKey
            let curveOID: [UInt8] = algorithm == .ecdsaP256 ?
                [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] : // P-256
                [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22] // P-384

            var algId = Data(ecOID)
            algId.append(contentsOf: curveOID)
            spki.append(contentsOf: wrapSequence(algId))

            // EC point as BIT STRING
            var bitString = Data([0x00]) // no unused bits
            bitString.append(publicKeyData)
            spki.append(0x03) // BIT STRING
            spki.append(contentsOf: encodeLength(bitString.count))
            spki.append(bitString)
        }

        return spki
    }

    private func wrapSequence(_ data: Data) -> [UInt8] {
        var result: [UInt8] = [0x30] // SEQUENCE
        result.append(contentsOf: encodeLength(data.count))
        result.append(contentsOf: data)
        return result
    }

    private func wrapSet(_ data: Data) -> Data {
        var result = Data([0x31]) // SET
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

    // MARK: - SSH Key Conversion

    private func convertToSSHPublicKey(_ secKey: SecKey, algorithm: YubiKeyAlgorithm) throws -> Data {
        guard let publicKeyData = SecKeyCopyExternalRepresentation(secKey, nil) as Data? else {
            throw YubiKeyError.keyConversionFailed("Failed to get key external representation")
        }

        var buffer = Data()

        switch algorithm {
        case .rsa2048, .rsa4096:
            let (exponent, modulus) = try YubiKeyKeyConverter.rsaPublicKeyComponents(fromPKCS1: publicKeyData)
            writeSSHString(&buffer, "ssh-rsa")
            writeSSHMPInt(&buffer, exponent)
            writeSSHMPInt(&buffer, modulus)

        case .ecdsaP256:
            writeSSHString(&buffer, "ecdsa-sha2-nistp256")
            writeSSHString(&buffer, "nistp256")
            writeSSHBuffer(&buffer, publicKeyData)

        case .ecdsaP384:
            writeSSHString(&buffer, "ecdsa-sha2-nistp384")
            writeSSHString(&buffer, "nistp384")
            writeSSHBuffer(&buffer, publicKeyData)

        case .ed25519:
            writeSSHString(&buffer, "ssh-ed25519")
            writeSSHBuffer(&buffer, publicKeyData)

        case .mldsa44, .mldsa65, .mldsa87:
            throw YubiKeyError.keyConversionFailed("ML-DSA keys have no SecKey form")
        }

        return buffer
    }

    private func generateFingerprint(_ publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func formatSSHPublicKeyString(_ publicKeyData: Data, algorithm: YubiKeyAlgorithm, name: String) -> String {
        let base64 = publicKeyData.base64EncodedString()
        return "\(algorithm.sshKeyTypeString) \(base64) \(name)"
    }

    // MARK: - Wire Format Helpers

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

        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit is set (MPInt must be positive)
        if (bytes.first ?? 0) & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }

        writeSSHBuffer(&buffer, Data(bytes))
    }
}

// MARK: - Generated Key Model

/// Result of generating a new key on YubiKey
struct GeneratedYubiKeyKey: Sendable {
    /// PIV slot where the key was generated
    let slot: PIVSlot

    /// Algorithm used
    let algorithm: YubiKeyAlgorithm

    /// Public key in SSH wire format
    let publicKeyData: Data

    /// SHA256 fingerprint (hex string)
    let fingerprint: String

    /// Public key in authorized_keys format
    let sshPublicKeyString: String
}

// MARK: - Algorithm Extensions

extension YubiKeyAlgorithm {
    var isRSA: Bool {
        switch self {
        case .rsa2048, .rsa4096: return true
        default: return false
        }
    }
}
