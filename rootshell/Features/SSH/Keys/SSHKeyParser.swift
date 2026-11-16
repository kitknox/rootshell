import Foundation
import Crypto
import Citadel
import NIOSSH
import NIOCore
import NIOFoundationCompat

// Import BoringSSL for RSA BIGNUM support
import CCryptoBoringSSL

/// Parser for SSH private keys in various formats.
///
/// All entry points are pure functions over `Data`/`String`: no shared
/// mutable state, no UI access. Kept `nonisolated` so callers can run
/// the heavy KDF + AES-CTR work off the main thread via
/// `Task.detached`; previously `@MainActor`, which forced encrypted-key
/// decryption onto the UI thread for every SSH connection setup.
///
/// The explicit `nonisolated` matters because the build sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — without it the type
/// re-acquires MainActor isolation by default.
nonisolated final class SSHKeyParser {

    enum ParserError: LocalizedError {
        case invalidFormat
        case unsupportedKeyType(String)
        case encryptedKeyNeedsPassphrase
        case unsupportedEncryptedPEM
        case incorrectPassphrase
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Invalid key format. Please provide a valid OpenSSH or PKCS#8 PEM key."
            case .unsupportedKeyType(let type):
                return "Unsupported key type: \(type). Supported types: RSA, Ed25519, ECDSA (P-256, P-384, P-521)."
            case .encryptedKeyNeedsPassphrase:
                return "This key is encrypted. Please provide the passphrase to decrypt it."
            case .unsupportedEncryptedPEM:
                return "Encrypted PEM keys in this format aren't supported. Convert the key to the OpenSSH format first with: ssh-keygen -p -o -f <keyfile>"
            case .incorrectPassphrase:
                return "Incorrect passphrase or corrupted key data."
            case .parseError(let message):
                return "Failed to parse key: \(message)"
            }
        }
    }

    /// RSA CRT (Chinese Remainder Theorem) parameters for YubiKey import
    /// YubiKey PIV requires all CRT parameters for RSA key import
    struct RSACRTParameters: Sendable {
        let n: Data       // Modulus
        let e: Data       // Public exponent
        let d: Data       // Private exponent
        let p: Data       // Prime factor 1
        let q: Data       // Prime factor 2
        let dP: Data      // d mod (p-1)
        let dQ: Data      // d mod (q-1)
        let qInv: Data    // q^-1 mod p (coefficient)
    }

    /// `@unchecked Sendable` is correct for transit across executors
    /// even though `NIOSSHPrivateKey` / `RSAPrivateKey` don't carry an
    /// explicit conformance. The struct is fully `let`-bound and the
    /// underlying key material is immutable opaque crypto state once
    /// parsed: there's nothing mutable to race on, so handing the
    /// value from the detached parse `Task` back to the MainActor
    /// caller is safe. Without this, the off-main parse path can't
    /// type-check under Swift 6 strict concurrency.
    struct ParsedKey: @unchecked Sendable {
        let nioSSHKey: NIOSSHPrivateKey?  // nil for RSA keys
        let rsaKey: RSAPrivateKey?         // Only for RSA keys
        let keyType: SSHKey.KeyType
        let fingerprint: String
        let isEncrypted: Bool
        let rsaCRTParams: RSACRTParameters?  // CRT parameters for YubiKey import (RSA only)
        /// The CryptoKit P-256 key when this is an ecdsaP256 software key.
        /// OpenPubkey needs it to produce ES256 JWS signatures, which
        /// NIOSSHPrivateKey doesn't expose.
        let underlyingP256Key: P256.Signing.PrivateKey?
        /// The Curve25519 key when this is an ed25519 software key. OpenPubkey
        /// needs it to produce EdDSA JWS signatures, which NIOSSHPrivateKey
        /// doesn't expose.
        let underlyingEd25519Key: Curve25519.Signing.PrivateKey?
        /// The 32-byte FIPS 204 seed of a pure ML-DSA key, for YubiKey PIV import.
        let mldsaSeed: Data?

        init(
            nioSSHKey: NIOSSHPrivateKey?,
            rsaKey: RSAPrivateKey?,
            keyType: SSHKey.KeyType,
            fingerprint: String,
            isEncrypted: Bool,
            rsaCRTParams: RSACRTParameters?,
            underlyingP256Key: P256.Signing.PrivateKey? = nil,
            underlyingEd25519Key: Curve25519.Signing.PrivateKey? = nil,
            mldsaSeed: Data? = nil
        ) {
            self.nioSSHKey = nioSSHKey
            self.rsaKey = rsaKey
            self.keyType = keyType
            self.fingerprint = fingerprint
            self.isEncrypted = isEncrypted
            self.rsaCRTParams = rsaCRTParams
            self.underlyingP256Key = underlyingP256Key
            self.underlyingEd25519Key = underlyingEd25519Key
            self.mldsaSeed = mldsaSeed
        }
    }

    /// Quick check if a key string appears to be encrypted
    /// This does minimal parsing to detect encryption without fully parsing the key
    /// - Parameter keyString: The key content as a string
    /// - Returns: true if the key is encrypted and needs a passphrase
    static func isEncrypted(keyString: String) -> Bool {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for PEM encrypted markers (legacy format)
        if trimmed.contains("ENCRYPTED") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            return true
        }

        // For OpenSSH format, we need to parse the binary header to check the cipher
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            // Extract base64 content
            let lines = trimmed.components(separatedBy: .newlines)
            let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            let base64String = base64Lines.joined()

            guard let keyData = Data(base64Encoded: base64String) else {
                return false
            }

            // Parse OpenSSH binary format to check cipher
            var buffer = ByteBuffer(data: keyData)

            // Magic string "openssh-key-v1\0" (15 bytes)
            guard buffer.readString(length: "openssh-key-v1".count) == "openssh-key-v1",
                  buffer.readInteger(as: UInt8.self) == 0x00 else {
                return false
            }

            // Read cipher name
            guard let cipherName = buffer.readSSHString() else {
                return false
            }

            // If cipher is not "none", the key is encrypted
            return cipherName != "none"
        }

        return false
    }

    /// Parses an SSH private key from string data
    /// - Parameters:
    ///   - keyString: The key content as a string (PEM or OpenSSH format)
    ///   - passphrase: Optional passphrase for encrypted keys
    /// - Returns: ParsedKey containing the NIOSSHPrivateKey and metadata
    /// - Throws: ParserError if parsing fails
    static func parse(keyString: String, passphrase: String? = nil) throws -> ParsedKey {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as OpenSSH format first (more common for modern keys)
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHFormat(keyString: trimmed, passphrase: passphrase)
        }

        // Encrypted non-OpenSSH PEM (PKCS#8 "BEGIN ENCRYPTED PRIVATE KEY" or
        // legacy PKCS#1 with Proc-Type/DEK-Info headers) can't be decrypted
        // here — fail with an actionable message instead of silently ignoring
        // the passphrase and reporting a generic format error.
        if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") ||
           trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            throw ParserError.unsupportedEncryptedPEM
        }

        // Fall back to PEM format
        if trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----") ||
           trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            return try parsePKCS8PEM(keyString: trimmed)
        }

        throw ParserError.invalidFormat
    }

    // MARK: - PKCS#8 PEM Parsing

    private static func parsePKCS8PEM(keyString: String) throws -> ParsedKey {
        // Extract base64 content
        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()

        guard let derData = Data(base64Encoded: base64String) else {
            throw ParserError.parseError("Invalid base64 encoding")
        }

        // Check if this is PKCS#1 RSA format (-----BEGIN RSA PRIVATE KEY-----)
        if keyString.contains("BEGIN RSA PRIVATE KEY") {
            return try parseRSAPKCS1(derData: derData)
        }

        // Try Ed25519
        if let result = try? parseEd25519PKCS8(derData: derData) {
            return result
        }

        // Try ECDSA P-256
        if let result = try? parseECDSAP256PKCS8(derData: derData) {
            return result
        }

        // Try ECDSA P-384
        if let result = try? parseECDSAP384PKCS8(derData: derData) {
            return result
        }

        // Try ECDSA P-521
        if let result = try? parseECDSAP521PKCS8(derData: derData) {
            return result
        }

        throw ParserError.invalidFormat
    }

    private static func parseRSAPKCS1(derData: Data) throws -> ParsedKey {
        // PKCS#1 RSAPrivateKey ASN.1 structure:
        // RSAPrivateKey ::= SEQUENCE {
        //   version           Version,
        //   modulus           INTEGER,  -- n
        //   publicExponent    INTEGER,  -- e
        //   privateExponent   INTEGER,  -- d
        //   prime1            INTEGER,  -- p
        //   prime2            INTEGER,  -- q
        //   exponent1         INTEGER,  -- d mod (p-1)
        //   exponent2         INTEGER,  -- d mod (q-1)
        //   coefficient       INTEGER,  -- (inverse of q) mod p
        // }

        var offset = 0

        // Parse SEQUENCE tag and length
        guard offset < derData.count, derData[offset] == 0x30 else {
            throw ParserError.parseError("Invalid PKCS#1 RSA: missing SEQUENCE tag")
        }
        offset += 1

        // Parse length (can be short or long form)
        let (_, lengthEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = lengthEnd

        // Parse version (INTEGER, should be 0) - skip it
        let (_, versionEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = versionEnd

        // Parse modulus (n)
        let (n, nEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = nEnd

        // Parse publicExponent (e)
        let (e, eEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = eEnd

        // Parse privateExponent (d)
        let (d, dEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = dEnd

        // Parse prime1 (p)
        let (p, pEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = pEnd

        // Parse prime2 (q)
        let (q, qEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = qEnd

        // Parse exponent1 (dP = d mod (p-1))
        let (dP, dPEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = dPEnd

        // Parse exponent2 (dQ = d mod (q-1))
        let (dQ, dQEnd) = try parseASN1Integer(derData: derData, offset: offset)
        offset = dQEnd

        // Parse coefficient (qInv = q^-1 mod p)
        let (qInv, _) = try parseASN1Integer(derData: derData, offset: offset)

        // Avoid logging key material in production.

        // Create RSA private key
        let rsaPrivateKey = try RSAPrivateKey(n: n, e: e, d: d)

        // Generate fingerprint from public key (e + n)
        let fingerprint = generateFingerprint(publicKeyData: rsaPrivateKey.publicKeyData())

        // Normalize CRT parameters: pass file's dP/dQ so they're used if no prime swap is needed
        // PKCS#1 files contain correct dP/dQ values that should be trusted when p > q
        let crtParams = try computeRSACRTParameters(
            n: n, e: e, d: d, p: p, q: q, qInv: qInv,
            fileDp: dP, fileDq: dQ
        )

        return ParsedKey(
            nioSSHKey: nil,
            rsaKey: rsaPrivateKey,
            keyType: .rsa,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: crtParams
        )
    }

    // MARK: - ASN.1 Parsing Helpers

    private static func parseASN1Length(derData: Data, offset: Int) throws -> (Int, Int) {
        guard offset < derData.count else {
            throw ParserError.parseError("Truncated ASN.1 length")
        }

        let firstByte = derData[offset]

        if firstByte & 0x80 == 0 {
            // Short form: length is in the first byte
            return (Int(firstByte), offset + 1)
        } else {
            // Long form: first byte tells us how many bytes encode the length
            let numLengthBytes = Int(firstByte & 0x7F)
            guard offset + 1 + numLengthBytes <= derData.count else {
                throw ParserError.parseError("Truncated ASN.1 long length")
            }

            var length = 0
            for i in 0..<numLengthBytes {
                length = (length << 8) | Int(derData[offset + 1 + i])
            }

            return (length, offset + 1 + numLengthBytes)
        }
    }

    private static func parseASN1Integer(derData: Data, offset: Int) throws -> (Data, Int) {
        guard offset < derData.count, derData[offset] == 0x02 else {
            throw ParserError.parseError("Invalid ASN.1 INTEGER tag")
        }

        let (length, contentOffset) = try parseASN1Length(derData: derData, offset: offset + 1)

        guard contentOffset + length <= derData.count else {
            throw ParserError.parseError("Truncated ASN.1 INTEGER")
        }

        // Extract integer bytes
        var integerData = derData.subdata(in: contentOffset..<(contentOffset + length))

        // Remove leading zero byte if present (used for positive integers in ASN.1)
        if integerData.count > 1 && integerData[0] == 0x00 {
            integerData = integerData.dropFirst()
        }

        return (integerData, contentOffset + length)
    }

    private static func parseEd25519PKCS8(derData: Data) throws -> ParsedKey {
        // PKCS#8 Ed25519 structure:
        // SEQUENCE {
        //   INTEGER version (0)
        //   SEQUENCE { OID 1.3.101.112 (Ed25519) }
        //   OCTET STRING {
        //     OCTET STRING (32 bytes - the actual key)
        //   }
        // }
        guard derData.count >= 48 else {
            throw ParserError.parseError("DER data too short for Ed25519 PKCS#8")
        }

        var offset = 0

        // Parse outer SEQUENCE
        guard offset < derData.count, derData[offset] == 0x30 else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: missing outer SEQUENCE")
        }
        offset += 1
        let (_, seqLenEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = seqLenEnd

        // Skip version INTEGER (typically 0x02 0x01 0x00)
        guard offset < derData.count, derData[offset] == 0x02 else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: missing version INTEGER")
        }
        offset += 1
        let (versionLen, versionContentEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = versionContentEnd + versionLen

        // Skip algorithm identifier SEQUENCE (contains OID 1.3.101.112)
        guard offset < derData.count, derData[offset] == 0x30 else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: missing algorithm SEQUENCE")
        }
        offset += 1
        let (algoLen, algoContentEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = algoContentEnd + algoLen

        // Parse outer OCTET STRING (wraps the key)
        guard offset < derData.count, derData[offset] == 0x04 else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: missing outer OCTET STRING")
        }
        offset += 1
        let (_, outerOctetContentEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = outerOctetContentEnd

        // Parse inner OCTET STRING (contains the 32-byte key)
        guard offset < derData.count, derData[offset] == 0x04 else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: missing inner OCTET STRING")
        }
        offset += 1
        let (innerOctetLen, innerOctetContentEnd) = try parseASN1Length(derData: derData, offset: offset)
        offset = innerOctetContentEnd

        // Extract the 32-byte Ed25519 seed
        guard innerOctetLen == 32, offset + 32 <= derData.count else {
            throw ParserError.parseError("Invalid Ed25519 PKCS#8: key must be 32 bytes, got \(innerOctetLen)")
        }
        let keyBytes = derData.subdata(in: offset..<(offset + 32))

        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: privateKey.publicKey.rawRepresentation)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ed25519,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil,
            underlyingEd25519Key: privateKey
        )
    }

    private static func parseECDSAP256PKCS8(derData: Data) throws -> ParsedKey {
        // Try to extract P-256 key from DER
        // For P-256, we need the private scalar (32 bytes)
        let privateKey = try P256.Signing.PrivateKey(derRepresentation: derData)
        let nioKey = NIOSSHPrivateKey(p256Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: privateKey.publicKey.x963Representation)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ecdsaP256,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil,
            underlyingP256Key: privateKey
        )
    }

    private static func parseECDSAP384PKCS8(derData: Data) throws -> ParsedKey {
        let privateKey = try P384.Signing.PrivateKey(derRepresentation: derData)
        let nioKey = NIOSSHPrivateKey(p384Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: privateKey.publicKey.x963Representation)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ecdsaP384,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil
        )
    }

    private static func parseECDSAP521PKCS8(derData: Data) throws -> ParsedKey {
        let privateKey = try P521.Signing.PrivateKey(derRepresentation: derData)
        let nioKey = NIOSSHPrivateKey(p521Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: privateKey.publicKey.x963Representation)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ecdsaP521,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil
        )
    }

    // MARK: - OpenSSH Format Parsing

    private static func parseOpenSSHFormat(keyString: String, passphrase: String?) throws -> ParsedKey {
        // Extract base64 content
        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()

        guard let keyData = Data(base64Encoded: base64String) else {
            throw ParserError.parseError("Invalid base64 encoding")
        }

        // Parse OpenSSH binary format using NIOCore ByteBuffer
        var buffer = ByteBuffer(data: keyData)

        // Magic string "openssh-key-v1\0"
        guard buffer.readString(length: "openssh-key-v1".count) == "openssh-key-v1",
              buffer.readInteger(as: UInt8.self) == 0x00 else {
            throw ParserError.parseError("Invalid OpenSSH magic string")
        }

        // Read cipher and KDF
        let cipher = try OpenSSH.Cipher(consuming: &buffer)
        let kdf = try OpenSSH.KDF(consuming: &buffer)

        // Check if encrypted
        let isEncrypted = cipher != .none
        if isEncrypted && passphrase == nil {
            throw ParserError.encryptedKeyNeedsPassphrase
        }

        // Read number of keys
        guard let numKeys = buffer.readInteger(as: UInt32.self), numKeys == 1 else {
            throw ParserError.parseError("Invalid or multiple keys not supported")
        }

        // Skip public key blob
        guard buffer.readSSHBuffer() != nil else {
            throw ParserError.parseError("Missing public key")
        }

        // Read and decrypt private key blob
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw ParserError.parseError("Missing private key")
        }

        // Decrypt if needed
        if isEncrypted {
            guard let passphraseData = passphrase?.data(using: .utf8) else {
                throw ParserError.encryptedKeyNeedsPassphrase
            }
            do {
                try kdf.withKeyAndIV(
                    cipher: cipher,
                    basedOnDecryptionKey: passphraseData
                ) { key, iv in
                    try cipher.decryptBuffer(&privateKeyBuffer, key: key, iv: iv)
                }
            } catch OpenSSH.KeyError.invalidCheck {
                throw ParserError.incorrectPassphrase
            } catch {
                throw ParserError.parseError("Decryption failed: \(error.localizedDescription)")
            }
        }

        return try parseOpenSSHPrivateBlob(buffer: privateKeyBuffer, wasEncrypted: isEncrypted)
    }

    private static func parseOpenSSHPrivateBlob(buffer: ByteBuffer, wasEncrypted: Bool) throws -> ParsedKey {
        var buffer = buffer

        // Verify check bytes match (8 bytes total: 2x UInt32)
        guard let check1 = buffer.readInteger(as: UInt32.self),
              let check2 = buffer.readInteger(as: UInt32.self),
              check1 == check2 else {
            throw ParserError.incorrectPassphrase
        }

        // Read key type
        guard let keyType = buffer.readSSHString() else {
            throw ParserError.parseError("Missing key type")
        }

        // Parse based on key type
        if keyType == "ssh-rsa" {
            return try parseOpenSSHRSA(buffer: &buffer, wasEncrypted: wasEncrypted)
        } else if keyType == "ssh-ed25519" {
            return try parseOpenSSHEd25519Buffer(buffer: &buffer, wasEncrypted: wasEncrypted)
        } else if keyType == MLDSA44Ed25519SSH.algorithmName || keyType == LegacyMLDSA44Ed25519SSH.algorithmName {
            return try parseOpenSSHMLDSA44Ed25519Buffer(buffer: &buffer, keyType: keyType, wasEncrypted: wasEncrypted)
        } else if keyType == "ssh-mldsa44" || keyType == "ssh-mldsa65" || keyType == "ssh-mldsa87" {
            return try parseOpenSSHPureMLDSABuffer(buffer: &buffer, keyType: keyType, wasEncrypted: wasEncrypted)
        } else if keyType.hasPrefix("ecdsa-sha2-") {
            return try parseOpenSSHECDSABuffer(buffer: &buffer, keyType: keyType, wasEncrypted: wasEncrypted)
        } else {
            throw ParserError.unsupportedKeyType(keyType)
        }
    }

    private static func parseOpenSSHEd25519(data: Data, offset: Int) throws -> ParsedKey {
        var currentOffset = offset

        // Read public key
        let (publicKeyData, pubOffset) = try readSSHData(from: data, offset: currentOffset)
        currentOffset = pubOffset

        // Read private key (64 bytes: 32 byte seed + 32 byte public key)
        let (privateKeyData, _) = try readSSHData(from: data, offset: currentOffset)

        guard privateKeyData.count >= 32 else {
            throw ParserError.parseError("Invalid Ed25519 private key length")
        }

        let seed = privateKeyData.prefix(32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: publicKeyData)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ed25519,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil,
            underlyingEd25519Key: privateKey
        )
    }

    private static func parseOpenSSHECDSA(data: Data, offset: Int, keyType: String) throws -> ParsedKey {
        var currentOffset = offset

        // Read curve name
        let (curveName, curveOffset) = try readSSHString(from: data, offset: currentOffset)
        currentOffset = curveOffset

        // Read public key point
        let (publicPoint, pubOffset) = try readSSHData(from: data, offset: currentOffset)
        currentOffset = pubOffset

        // Read private key scalar
        let (privateScalarData, _) = try readSSHData(from: data, offset: currentOffset)

        // Determine key type from curve name
        let sshKeyType: SSHKey.KeyType
        let nioKey: NIOSSHPrivateKey
        var p256Key: P256.Signing.PrivateKey?

        switch curveName {
        case "nistp256":
            sshKeyType = .ecdsaP256
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 32)
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p256Key: privateKey)
            p256Key = privateKey
        case "nistp384":
            sshKeyType = .ecdsaP384
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 48)
            let privateKey = try P384.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p384Key: privateKey)
        case "nistp521":
            sshKeyType = .ecdsaP521
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 66)
            let privateKey = try P521.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p521Key: privateKey)
        default:
            throw ParserError.unsupportedKeyType(curveName)
        }

        let fingerprint = generateFingerprint(publicKeyData: publicPoint)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: sshKeyType,
            fingerprint: fingerprint,
            isEncrypted: false,
            rsaCRTParams: nil,
            underlyingP256Key: p256Key
        )
    }

    /// OpenSSH writes the ECDSA private scalar as an SSH mpint, which adds
    /// a leading 0x00 sign byte whenever the high bit of the scalar is set
    /// and strips actual leading zeros from the value. CryptoKit's
    /// `rawRepresentation` accepts only the canonical fixed-length scalar
    /// (32 bytes for P-256, 48 for P-384, 66 for P-521), so we strip the
    /// sign byte and left-pad short values back to the curve's scalar size.
    fileprivate static func normalizeECDSAScalar(_ data: Data, expectedLength: Int) -> Data {
        var bytes = Array(data)
        while bytes.count > expectedLength && bytes.first == 0 {
            bytes.removeFirst()
        }
        if bytes.count < expectedLength {
            bytes = Array(repeating: 0, count: expectedLength - bytes.count) + bytes
        }
        return Data(bytes)
    }

    // MARK: - ByteBuffer-based Parsers

    private static func parseOpenSSHRSA(buffer: inout ByteBuffer, wasEncrypted: Bool) throws -> ParsedKey {
        // OpenSSH RSA format: n, e, d, iqmp (qInv), p, q
        // Note: OpenSSH stores iqmp (q^-1 mod p), NOT coefficient in PKCS order
        // We need to compute dP = d mod (p-1) and dQ = d mod (q-1) ourselves

        // Read n (modulus)
        guard let nLength = buffer.readInteger(as: UInt32.self),
              let nBytes = buffer.readBytes(length: Int(nLength)) else {
            throw ParserError.parseError("Failed to read RSA modulus")
        }

        // Read e (public exponent)
        guard let eLength = buffer.readInteger(as: UInt32.self),
              let eBytes = buffer.readBytes(length: Int(eLength)) else {
            throw ParserError.parseError("Failed to read RSA public exponent")
        }

        // Read d (private exponent)
        guard let dLength = buffer.readInteger(as: UInt32.self),
              let dBytes = buffer.readBytes(length: Int(dLength)) else {
            throw ParserError.parseError("Failed to read RSA private exponent")
        }

        // Read iqmp (q^-1 mod p) - this is qInv in PKCS#1 terms
        guard let iqmpBuffer = buffer.readSSHBuffer(),
              let iqmpData = iqmpBuffer.getData(at: iqmpBuffer.readerIndex, length: iqmpBuffer.readableBytes) else {
            throw ParserError.parseError("Failed to read RSA iqmp")
        }

        // Read p (first prime)
        guard let pBuffer = buffer.readSSHBuffer(),
              let pData = pBuffer.getData(at: pBuffer.readerIndex, length: pBuffer.readableBytes) else {
            throw ParserError.parseError("Failed to read RSA prime p")
        }

        // Read q (second prime)
        guard let qBuffer = buffer.readSSHBuffer(),
              let qData = qBuffer.getData(at: qBuffer.readerIndex, length: qBuffer.readableBytes) else {
            throw ParserError.parseError("Failed to read RSA prime q")
        }

        let n = Data(nBytes)
        let e = Data(eBytes)
        let d = Data(dBytes)

        // Create RSA private key from raw bytes (n, e, d)
        let rsaPrivateKey = try RSAPrivateKey(n: n, e: e, d: d)

        let fingerprint = generateFingerprint(publicKeyData: Data(eBytes + nBytes))

        // Compute CRT parameters dP and dQ using BoringSSL BIGNUM
        // dP = d mod (p-1), dQ = d mod (q-1)
        let crtParams = try computeRSACRTParameters(
            n: n, e: e, d: d,
            p: pData, q: qData, qInv: iqmpData
        )

        return ParsedKey(
            nioSSHKey: nil,  // RSA not supported by Apple's NIOSSH
            rsaKey: rsaPrivateKey,
            keyType: .rsa,
            fingerprint: fingerprint,
            isEncrypted: wasEncrypted,
            rsaCRTParams: crtParams
        )
    }

    /// Compute RSA CRT parameters dP, dQ, and qInv from d, p, and q using BoringSSL
    /// Also ensures proper prime ordering: if p < q, swaps them and recomputes all CRT params
    /// dP = d mod (p-1)
    /// dQ = d mod (q-1)
    /// qInv = q^-1 mod p
    ///
    /// - Parameters:
    ///   - fileDp: Optional dP value from PKCS#1 file (used when primes don't need swapping)
    ///   - fileDq: Optional dQ value from PKCS#1 file (used when primes don't need swapping)
    private static func computeRSACRTParameters(
        n: Data, e: Data, d: Data,
        p: Data, q: Data, qInv: Data,
        fileDp: Data? = nil, fileDq: Data? = nil
    ) throws -> RSACRTParameters {
        // Convert Data to BoringSSL BIGNUMs
        guard let d_bn = CCryptoBoringSSL_BN_bin2bn(Array(d), d.count, nil),
              let p_bn = CCryptoBoringSSL_BN_bin2bn(Array(p), p.count, nil),
              let q_bn = CCryptoBoringSSL_BN_bin2bn(Array(q), q.count, nil) else {
            throw ParserError.parseError("Failed to create BIGNUMs for CRT computation")
        }
        defer {
            CCryptoBoringSSL_BN_free(d_bn)
            CCryptoBoringSSL_BN_free(p_bn)
            CCryptoBoringSSL_BN_free(q_bn)
        }

        // Check if we need to swap p and q (PKCS#1 convention requires p > q)
        let cmpResult = CCryptoBoringSSL_BN_cmp(p_bn, q_bn)
        let needsSwap = cmpResult < 0  // p < q, need to swap

        // Use the larger value as prime_p and smaller as prime_q
        let (prime_p, prime_q): (UnsafeMutablePointer<BIGNUM>, UnsafeMutablePointer<BIGNUM>)
        if needsSwap {
            prime_p = q_bn  // Use OpenSSH's q (larger) as our p
            prime_q = p_bn  // Use OpenSSH's p (smaller) as our q
        } else {
            prime_p = p_bn
            prime_q = q_bn
        }

        // Create BIGNUMs for results and intermediate values
        guard let dP_bn = CCryptoBoringSSL_BN_new(),
              let dQ_bn = CCryptoBoringSSL_BN_new(),
              let qInv_bn = CCryptoBoringSSL_BN_new(),
              let pMinus1 = CCryptoBoringSSL_BN_new(),
              let qMinus1 = CCryptoBoringSSL_BN_new(),
              let one = CCryptoBoringSSL_BN_new(),
              let ctx = CCryptoBoringSSL_BN_CTX_new() else {
            throw ParserError.parseError("Failed to allocate BIGNUMs for CRT computation")
        }
        defer {
            CCryptoBoringSSL_BN_free(dP_bn)
            CCryptoBoringSSL_BN_free(dQ_bn)
            CCryptoBoringSSL_BN_free(qInv_bn)
            CCryptoBoringSSL_BN_free(pMinus1)
            CCryptoBoringSSL_BN_free(qMinus1)
            CCryptoBoringSSL_BN_free(one)
            CCryptoBoringSSL_BN_CTX_free(ctx)
        }

        // Set one = 1
        CCryptoBoringSSL_BN_set_word(one, 1)

        // Compute p - 1
        guard CCryptoBoringSSL_BN_sub(pMinus1, prime_p, one) == 1 else {
            throw ParserError.parseError("Failed to compute p-1")
        }

        // Compute q - 1
        guard CCryptoBoringSSL_BN_sub(qMinus1, prime_q, one) == 1 else {
            throw ParserError.parseError("Failed to compute q-1")
        }

        // Always compute CRT parameters from d, p, q to ensure consistency.
        // Some key exports include incorrect or swapped CRT values; recomputing avoids
        // importing a key that fails signature validation on hardware.
        guard CCryptoBoringSSL_BN_div(nil, dP_bn, d_bn, pMinus1, ctx) == 1 else {
            throw ParserError.parseError("Failed to compute dP")
        }

        guard CCryptoBoringSSL_BN_div(nil, dQ_bn, d_bn, qMinus1, ctx) == 1 else {
            throw ParserError.parseError("Failed to compute dQ")
        }

        // Recompute qInv = q^-1 mod p to match potentially swapped primes
        guard CCryptoBoringSSL_BN_mod_inverse(qInv_bn, prime_q, prime_p, ctx) != nil else {
            throw ParserError.parseError("Failed to compute qInv (modular inverse)")
        }

        let dP = Self.bignumToData(dP_bn)
        let dQ = Self.bignumToData(dQ_bn)
        let computedQInv = Self.bignumToData(qInv_bn)

        // Convert results back to Data
        let finalP = Self.bignumToData(prime_p)
        let finalQ = Self.bignumToData(prime_q)

        // Avoid logging CRT parameter bytes.

        return RSACRTParameters(n: n, e: e, d: d, p: finalP, q: finalQ, dP: dP, dQ: dQ, qInv: computedQInv)
    }

    /// Convert BoringSSL BIGNUM to Data
    private static func bignumToData(_ bn: UnsafeMutablePointer<BIGNUM>?) -> Data {
        guard let bn = bn else { return Data() }
        let numBytes = (CCryptoBoringSSL_BN_num_bits(bn) + 7) / 8
        var bytes = [UInt8](repeating: 0, count: Int(numBytes))
        CCryptoBoringSSL_BN_bn2bin(bn, &bytes)
        return Data(bytes)
    }

    private static func parseOpenSSHEd25519Buffer(buffer: inout ByteBuffer, wasEncrypted: Bool) throws -> ParsedKey {
        // Read public key buffer and validate it's exactly 32 bytes for Ed25519
        guard let publicKeyBuffer = buffer.readSSHBuffer() else {
            throw ParserError.parseError("Missing Ed25519 public key")
        }
        guard publicKeyBuffer.readableBytes == 32 else {
            throw ParserError.parseError("Invalid Ed25519 public key: expected 32 bytes, got \(publicKeyBuffer.readableBytes)")
        }
        guard let publicKeyData = publicKeyBuffer.getData(at: publicKeyBuffer.readerIndex, length: 32) else {
            throw ParserError.parseError("Failed to read Ed25519 public key data")
        }

        // Read private key (64 bytes: 32 byte seed + 32 byte public key)
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw ParserError.parseError("Missing Ed25519 private key")
        }
        guard privateKeyBuffer.readableBytes >= 32 else {
            throw ParserError.parseError("Invalid Ed25519 private key: expected at least 32 bytes, got \(privateKeyBuffer.readableBytes)")
        }
        guard let seed = privateKeyBuffer.readBytes(length: 32) else {
            throw ParserError.parseError("Failed to read Ed25519 private key seed")
        }

        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        let fingerprint = generateFingerprint(publicKeyData: publicKeyData)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .ed25519,
            fingerprint: fingerprint,
            isEncrypted: wasEncrypted,
            rsaCRTParams: nil,
            underlyingEd25519Key: privateKey
        )
    }

    /// Canonical and legacy OpenSSH ML-DSA-44 + Ed25519 hybrid: the private
    /// section carries `string pk(1344)` then `string sk(64)`, where sk is the
    /// two 32-byte seeds — never expanded key material.
    private static func parseOpenSSHMLDSA44Ed25519Buffer(buffer: inout ByteBuffer, keyType: String, wasEncrypted: Bool) throws -> ParsedKey {
        guard let publicKeyBuffer = buffer.readSSHBuffer(),
              let publicKeyData = publicKeyBuffer.getData(at: 0, length: publicKeyBuffer.readableBytes) else {
            throw ParserError.parseError("Missing ML-DSA-44+Ed25519 public key")
        }
        guard publicKeyData.count == 1344 else {
            throw ParserError.parseError("Invalid ML-DSA-44+Ed25519 public key: expected 1344 bytes, got \(publicKeyData.count)")
        }

        guard let privateKeyBuffer = buffer.readSSHBuffer(),
              let seedData = privateKeyBuffer.getData(at: 0, length: privateKeyBuffer.readableBytes) else {
            throw ParserError.parseError("Missing ML-DSA-44+Ed25519 private key")
        }
        guard seedData.count == 64 else {
            throw ParserError.parseError("Invalid ML-DSA-44+Ed25519 private key: expected 64 seed bytes, got \(seedData.count)")
        }

        let privateKey: MLDSA44Ed25519SSH.PrivateKey
        do {
            privateKey = try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: seedData)
        } catch {
            throw ParserError.parseError("Failed to derive ML-DSA-44+Ed25519 key from seeds")
        }
        // The stored public key must match the one the seeds derive —
        // a mismatch means a corrupted or tampered key file.
        guard privateKey.compositePublicKey.rawRepresentation == publicKeyData else {
            throw ParserError.parseError("ML-DSA-44+Ed25519 public key does not match private key seeds")
        }

        // Preserve the encoded identity: changing its name changes the public
        // blob, host fingerprint, and certificate authentication identity.
        let nioKey: NIOSSHPrivateKey
        if keyType == LegacyMLDSA44Ed25519SSH.algorithmName {
            nioKey = NIOSSHPrivateKey(custom: try LegacyMLDSA44Ed25519SSH.PrivateKey(seedRepresentation: seedData))
        } else {
            nioKey = NIOSSHPrivateKey(custom: privateKey)
        }
        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: .mldsa44Ed25519,
            fingerprint: generateFingerprint(publicKeyData: publicKeyData),
            isEncrypted: wasEncrypted,
            rsaCRTParams: nil
        )
    }

    /// Pure ML-DSA (ssh-mldsa44/65/87): `string pk || string sk` where sk is
    /// the 32-byte FIPS 204 seed. Expanded-key encodings (OQS ssh-keygen
    /// stores the multi-KB expanded secret) are rejected — the seed cannot be
    /// recovered from them.
    private static func parseOpenSSHPureMLDSABuffer(buffer: inout ByteBuffer, keyType: String, wasEncrypted: Bool) throws -> ParsedKey {
        let expectedPKLength: Int
        let sshKeyType: SSHKey.KeyType
        switch keyType {
        case "ssh-mldsa44": expectedPKLength = 1312; sshKeyType = .mldsa44
        case "ssh-mldsa65": expectedPKLength = 1952; sshKeyType = .mldsa65
        case "ssh-mldsa87": expectedPKLength = 2592; sshKeyType = .mldsa87
        default: throw ParserError.unsupportedKeyType(keyType)
        }

        guard let publicKeyBuffer = buffer.readSSHBuffer(),
              let publicKeyData = publicKeyBuffer.getData(at: 0, length: publicKeyBuffer.readableBytes) else {
            throw ParserError.parseError("Missing \(keyType) public key")
        }
        guard publicKeyData.count == expectedPKLength else {
            throw ParserError.parseError("Invalid \(keyType) public key: expected \(expectedPKLength) bytes, got \(publicKeyData.count)")
        }

        guard let privateKeyBuffer = buffer.readSSHBuffer(),
              let seedData = privateKeyBuffer.getData(at: 0, length: privateKeyBuffer.readableBytes) else {
            throw ParserError.parseError("Missing \(keyType) private key")
        }
        guard seedData.count == 32 else {
            throw ParserError.parseError("Unsupported \(keyType) private key encoding: expected a 32-byte seed, got \(seedData.count) bytes (expanded ML-DSA secret keys cannot be imported)")
        }

        let nioKey: NIOSSHPrivateKey
        let derivedPK: Data
        do {
            switch sshKeyType {
            case .mldsa44:
                let key = try MLDSA44SSH.PrivateKey(seedRepresentation: seedData)
                derivedPK = key.mldsaPublicKey.rawRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            case .mldsa65:
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw ParserError.unsupportedKeyType("\(keyType) (requires iOS 26 or later)")
                }
                let key = try MLDSA65SSH.PrivateKey(seedRepresentation: seedData)
                derivedPK = key.mldsaPublicKey.rawRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            case .mldsa87:
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw ParserError.unsupportedKeyType("\(keyType) (requires iOS 26 or later)")
                }
                let key = try MLDSA87SSH.PrivateKey(seedRepresentation: seedData)
                derivedPK = key.mldsaPublicKey.rawRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            default:
                throw ParserError.unsupportedKeyType(keyType)
            }
        } catch let error as ParserError {
            throw error
        } catch {
            throw ParserError.parseError("Failed to derive \(keyType) key from seed")
        }

        guard derivedPK == publicKeyData else {
            throw ParserError.parseError("\(keyType) public key does not match private key seed")
        }

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: sshKeyType,
            fingerprint: generateFingerprint(publicKeyData: publicKeyData),
            isEncrypted: wasEncrypted,
            rsaCRTParams: nil,
            mldsaSeed: seedData
        )
    }

    private static func parseOpenSSHECDSABuffer(buffer: inout ByteBuffer, keyType: String, wasEncrypted: Bool) throws -> ParsedKey {
        // Read curve name
        guard let curveName = buffer.readSSHString() else {
            throw ParserError.parseError("Missing ECDSA curve name")
        }

        // Read public key point
        guard let publicPointBuffer = buffer.readSSHBuffer(),
              let publicPoint = publicPointBuffer.getData(at: 0, length: publicPointBuffer.readableBytes) else {
            throw ParserError.parseError("Invalid ECDSA public key")
        }

        // Read private key scalar
        guard let privateScalarBuffer = buffer.readSSHBuffer(),
              let privateScalarData = privateScalarBuffer.getData(at: 0, length: privateScalarBuffer.readableBytes) else {
            throw ParserError.parseError("Invalid ECDSA private key")
        }

        // Determine key type from curve name
        let sshKeyType: SSHKey.KeyType
        let nioKey: NIOSSHPrivateKey
        var p256Key: P256.Signing.PrivateKey?

        switch curveName {
        case "nistp256":
            sshKeyType = .ecdsaP256
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 32)
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p256Key: privateKey)
            p256Key = privateKey
        case "nistp384":
            sshKeyType = .ecdsaP384
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 48)
            let privateKey = try P384.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p384Key: privateKey)
        case "nistp521":
            sshKeyType = .ecdsaP521
            let scalar = Self.normalizeECDSAScalar(privateScalarData, expectedLength: 66)
            let privateKey = try P521.Signing.PrivateKey(rawRepresentation: scalar)
            nioKey = NIOSSHPrivateKey(p521Key: privateKey)
        default:
            throw ParserError.unsupportedKeyType(curveName)
        }

        let fingerprint = generateFingerprint(publicKeyData: publicPoint)

        return ParsedKey(
            nioSSHKey: nioKey,
            rsaKey: nil,
            keyType: sshKeyType,
            fingerprint: fingerprint,
            isEncrypted: wasEncrypted,
            rsaCRTParams: nil,
            underlyingP256Key: p256Key
        )
    }

    // MARK: - Helper Functions

    /// Reads an SSH string (4-byte length + data) from binary data
    private static func readSSHString(from data: Data, offset: Int) throws -> (String, Int) {
        let (stringData, newOffset) = try readSSHData(from: data, offset: offset)
        let string = String(data: stringData, encoding: .utf8) ?? ""
        return (string, newOffset)
    }

    /// Reads SSH data (4-byte length + bytes) from binary data
    private static func readSSHData(from data: Data, offset: Int) throws -> (Data, Int) {
        guard data.count >= offset + 4 else {
            throw ParserError.parseError("Truncated SSH data")
        }

        // Read length safely without alignment issues
        // Use relative indexing from data's startIndex
        let lengthStart = data.startIndex.advanced(by: offset)
        let lengthEnd = lengthStart.advanced(by: 4)
        let length = data[lengthStart..<lengthEnd].withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        }
        let newOffset = offset + 4

        guard data.count >= newOffset + Int(length) else {
            throw ParserError.parseError("Truncated SSH data content")
        }

        let dataStart = data.startIndex.advanced(by: newOffset)
        let dataEnd = dataStart.advanced(by: Int(length))
        let dataContent = data[dataStart..<dataEnd]
        return (dataContent, newOffset + Int(length))
    }

    /// Generates SHA256 fingerprint from public key data
    private static func generateFingerprint(publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
