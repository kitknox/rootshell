//
//  SSHKeyGenerator.swift
//  rootshell
//
//  Generates SSH key pairs in-app (Ed25519, ML-DSA-44+Ed25519 hybrid,
//  ECDSA P-256/P-384/P-521, RSA 2048/3072/4096). Keys are emitted as
//  unencrypted OpenSSH PEM so they flow through the existing
//  SSHKeyParser → SSHKeyManager import path with no algorithm-specific
//  branching downstream.
//

import Foundation
import Crypto
import Citadel
import NIOSSH
import NIOCore
import NIOFoundationCompat
import CCryptoBoringSSL

/// Errors thrown by the on-device key generator. Only the BoringSSL-backed
/// paths (RSA, ML-DSA-44) can fail; Ed25519 and ECDSA use infallible
/// CryptoKit constructors.
enum SSHKeyGenerationError: LocalizedError {
    case rsaAllocationFailed
    case rsaGenerationFailed(bits: Int)
    case mldsaGenerationFailed(keyTypeName: String)

    var errorDescription: String? {
        switch self {
        case .rsaAllocationFailed:
            return String(localized: "Failed to allocate RSA key context. Please try again.", comment: "SSH key generation error: allocation failure")
        case .rsaGenerationFailed(let bits):
            return String(localized: "Failed to generate a \(bits)-bit RSA key. Please try again.", comment: "SSH key generation error: keygen failure")
        case .mldsaGenerationFailed(let keyTypeName):
            return String(localized: "Failed to generate an \(keyTypeName) key. Please try again.", comment: "SSH key generation error: ML-DSA keygen failure")
        }
    }
}

/// Result of SSH key generation
struct GeneratedSSHKey: Sendable {
    /// Private key in OpenSSH PEM format (for storage)
    let privateKeyPEM: String

    /// Public key in OpenSSH format (for display/copy)
    let publicKeyOpenSSH: String

    /// SHA256 fingerprint (hex string)
    let fingerprint: String

    /// The NIO SSH private key (for immediate use). nil for RSA — NIOSSH
    /// has no RSA private-key wrapper; callers that need an in-memory
    /// key should re-parse `privateKeyPEM` via SSHKeyParser.
    let nioSSHPrivateKey: NIOSSHPrivateKey?
}

/// User-selectable key types for on-device generation.
///
/// Nonisolated so the generator can read `rsaBits` from a detached task
/// without hopping back to MainActor (the project default isolation).
nonisolated enum GenerateKeyType: String, CaseIterable, Hashable, Sendable {
    case ed25519
    case mldsa44Ed25519
    case mldsa44
    case mldsa65
    case mldsa87
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa2048
    case rsa3072
    case rsa4096

    /// Pure ML-DSA types interop only with experimental servers (OQS builds) —
    /// standard OpenSSH rejects them. Drives the separate picker section and
    /// warning badge. The hybrid is NOT experimental: it's in stock OpenSSH 10.4+.
    var isExperimental: Bool {
        switch self {
        case .mldsa44, .mldsa65, .mldsa87: return true
        default: return false
        }
    }

    /// Whether this type can be generated on the current OS. Pure ML-DSA-65/87
    /// are CryptoKit-backed (iOS 26+); everything else works everywhere.
    var isAvailable: Bool {
        switch self {
        case .mldsa65, .mldsa87:
            if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) { return true }
            return false
        default:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .ed25519:   return String(localized: "Ed25519 (recommended)", comment: "SSH key generation: type Ed25519 with recommended tag")
        case .mldsa44Ed25519: return String(localized: "ML-DSA-44 + Ed25519 (post-quantum)", comment: "SSH key generation: type hybrid ML-DSA-44 + Ed25519")
        case .mldsa44:   return String(localized: "ML-DSA-44 (post-quantum)", comment: "SSH key generation: type pure ML-DSA-44")
        case .mldsa65:   return String(localized: "ML-DSA-65 (post-quantum)", comment: "SSH key generation: type pure ML-DSA-65")
        case .mldsa87:   return String(localized: "ML-DSA-87 (post-quantum)", comment: "SSH key generation: type pure ML-DSA-87")
        case .ecdsaP256: return String(localized: "ECDSA P-256", comment: "SSH key generation: type ECDSA P-256")
        case .ecdsaP384: return String(localized: "ECDSA P-384", comment: "SSH key generation: type ECDSA P-384")
        case .ecdsaP521: return String(localized: "ECDSA P-521", comment: "SSH key generation: type ECDSA P-521")
        case .rsa2048:   return String(localized: "RSA 2048", comment: "SSH key generation: type RSA 2048-bit")
        case .rsa3072:   return String(localized: "RSA 3072", comment: "SSH key generation: type RSA 3072-bit")
        case .rsa4096:   return String(localized: "RSA 4096", comment: "SSH key generation: type RSA 4096-bit")
        }
    }

    /// Compact label used on the picker trigger row where horizontal space is tight.
    /// Drops the "(recommended)" tag; the pushed selection list uses the full `displayName`.
    var shortDisplayName: String {
        switch self {
        case .ed25519:   return String(localized: "Ed25519", comment: "SSH key generation: short label for Ed25519")
        case .mldsa44Ed25519: return String(localized: "ML-DSA-44 + Ed25519", comment: "SSH key generation: short label for hybrid ML-DSA-44 + Ed25519")
        case .mldsa44:   return String(localized: "ML-DSA-44", comment: "SSH key generation: short label for pure ML-DSA-44")
        case .mldsa65:   return String(localized: "ML-DSA-65", comment: "SSH key generation: short label for pure ML-DSA-65")
        case .mldsa87:   return String(localized: "ML-DSA-87", comment: "SSH key generation: short label for pure ML-DSA-87")
        case .ecdsaP256: return String(localized: "ECDSA P-256", comment: "SSH key generation: short label for ECDSA P-256")
        case .ecdsaP384: return String(localized: "ECDSA P-384", comment: "SSH key generation: short label for ECDSA P-384")
        case .ecdsaP521: return String(localized: "ECDSA P-521", comment: "SSH key generation: short label for ECDSA P-521")
        case .rsa2048:   return String(localized: "RSA 2048", comment: "SSH key generation: short label for RSA 2048")
        case .rsa3072:   return String(localized: "RSA 3072", comment: "SSH key generation: short label for RSA 3072")
        case .rsa4096:   return String(localized: "RSA 4096", comment: "SSH key generation: short label for RSA 4096")
        }
    }

    var sshKeyType: SSHKey.KeyType {
        switch self {
        case .ed25519:   return .ed25519
        case .mldsa44Ed25519: return .mldsa44Ed25519
        case .mldsa44:   return .mldsa44
        case .mldsa65:   return .mldsa65
        case .mldsa87:   return .mldsa87
        case .ecdsaP256: return .ecdsaP256
        case .ecdsaP384: return .ecdsaP384
        case .ecdsaP521: return .ecdsaP521
        case .rsa2048, .rsa3072, .rsa4096: return .rsa
        }
    }

    var footerDescription: String {
        switch self {
        case .ed25519:
            return String(localized: "Modern elliptic-curve key. Fast, compact, and supported by OpenSSH 6.5+ (2014) and every current SSH server.", comment: "SSH key generation: Ed25519 footer")
        case .mldsa44Ed25519:
            return String(localized: "Hybrid post-quantum key combining ML-DSA-44 with Ed25519 — secure as long as either algorithm holds. Requires OpenSSH 10.4+ on the server.", comment: "SSH key generation: hybrid ML-DSA-44 + Ed25519 footer")
        case .mldsa44, .mldsa65, .mldsa87:
            return String(localized: "Pure post-quantum ML-DSA key (FIPS 204). Experimental: standard OpenSSH servers do not accept these — only servers with ML-DSA support (e.g. OQS builds). For OpenSSH interop, use ML-DSA-44 + Ed25519 instead.", comment: "SSH key generation: pure ML-DSA footer")
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            return String(localized: "NIST elliptic-curve key. Required by some compliance regimes (e.g. FIPS); widely supported by modern SSH servers.", comment: "SSH key generation: ECDSA footer")
        case .rsa2048, .rsa3072, .rsa4096:
            return String(localized: "Classic RSA key. Slowest to generate (especially at 4096 bits) but works with the broadest range of servers, including very old ones.", comment: "SSH key generation: RSA footer")
        }
    }

    /// RSA modulus size in bits. Nil for non-RSA types.
    fileprivate var rsaBits: Int? {
        switch self {
        case .rsa2048: return 2048
        case .rsa3072: return 3072
        case .rsa4096: return 4096
        default: return nil
        }
    }
}

/// Generates SSH key pairs in-app.
///
/// `nonisolated` so callers can hand off generation to a background task
/// (RSA-3072/4096 takes multiple seconds — running on the MainActor would
/// freeze the UI even when invoked from `Task.detached`, because the
/// project-wide default isolation would otherwise hop the static call
/// back to MainActor).
nonisolated enum SSHKeyGenerator {

    // MARK: - Key Generation

    /// Generate a new SSH key pair of the requested type.
    /// - Parameters:
    ///   - type: Algorithm + size to generate.
    ///   - comment: Optional comment embedded in the OpenSSH key blob (typically the key's user-facing name).
    /// - Throws: `SSHKeyGenerationError` only when BoringSSL fails to
    ///   allocate or generate an RSA key — the Ed25519 and ECDSA paths
    ///   never throw.
    static func generate(type: GenerateKeyType, comment: String = "") throws -> GeneratedSSHKey {
        switch type {
        case .ed25519:
            return generateEd25519(comment: comment)
        case .mldsa44Ed25519:
            return try generateMLDSA44Ed25519(comment: comment)
        case .mldsa44, .mldsa65, .mldsa87:
            return try generatePureMLDSA(type: type, comment: comment)
        case .ecdsaP256:
            return generateECDSAP256(comment: comment)
        case .ecdsaP384:
            return generateECDSAP384(comment: comment)
        case .ecdsaP521:
            return generateECDSAP521(comment: comment)
        case .rsa2048, .rsa3072, .rsa4096:
            return try generateRSA(bits: type.rsaBits!, comment: comment)
        }
    }

    /// Generate a new Ed25519 SSH key pair
    /// - Parameter comment: Optional comment to include in the key (typically key name)
    /// - Returns: GeneratedSSHKey containing private key PEM, public key, and fingerprint
    static func generateEd25519(comment: String = "") -> GeneratedSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)

        let publicKeyOpenSSH = formatPublicKeyOpenSSH(privateKey.publicKey, comment: comment)
        let privateKeyPEM = formatPrivateKeyOpenSSH(privateKey, comment: comment)
        let fingerprint = generateFingerprint(publicKey: privateKey.publicKey)

        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fingerprint,
            nioSSHPrivateKey: nioKey
        )
    }

    // MARK: - ML-DSA-44 + Ed25519 hybrid generation

    /// Generate an ssh-mldsa44-ed25519 composite key (OpenSSH
    /// 10.4+). Private material is the two 32-byte seeds; the public key is
    /// mldsaPK(1312) || ed25519PK(32) in a single SSH string.
    static func generateMLDSA44Ed25519(comment: String = "") throws -> GeneratedSSHKey {
        let privateKey: MLDSA44Ed25519SSH.PrivateKey
        do {
            privateKey = try MLDSA44Ed25519SSH.PrivateKey()
        } catch {
            throw SSHKeyGenerationError.mldsaGenerationFailed(keyTypeName: GenerateKeyType.mldsa44Ed25519.shortDisplayName)
        }
        let keyTypeString = MLDSA44Ed25519SSH.algorithmName
        let compositePK = privateKey.compositePublicKey.rawRepresentation

        var publicKeyBlob = ByteBuffer()
        publicKeyBlob.writeSSHString(keyTypeString)
        publicKeyBlob.writeSSHBuffer(ByteBuffer(data: compositePK))

        let publicKeyOpenSSH = formatOpenSSHPublicKeyLine(
            keyTypeString: keyTypeString,
            blob: publicKeyBlob,
            comment: comment
        )

        var privateSection = ByteBuffer()
        let checkBytes = UInt32.random(in: 0...UInt32.max)
        privateSection.writeInteger(checkBytes)
        privateSection.writeInteger(checkBytes)
        privateSection.writeSSHString(keyTypeString)
        privateSection.writeSSHBuffer(ByteBuffer(data: compositePK))
        // sk = mldsaSeed(32) || ed25519Seed(32) — seeds only, per OpenSSH
        privateSection.writeSSHBuffer(ByteBuffer(data: privateKey.seedRepresentation))
        privateSection.writeSSHString(comment)

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        // SSHKeyParser fingerprints this type over the 1344-byte composite
        // public key — match it so pre- and post-import fingerprints agree.
        let fingerprint = sha256Hex(of: compositePK)

        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fingerprint,
            nioSSHPrivateKey: NIOSSHPrivateKey(custom: privateKey)
        )
    }

    // MARK: - Pure ML-DSA generation

    /// Generate a pure ML-DSA key (ssh-mldsa44/65/87, OQS-style; experimental).
    /// Private material is the 32-byte FIPS 204 seed; the public key is the
    /// raw FIPS 204 key bytes in a single SSH string.
    static func generatePureMLDSA(type: GenerateKeyType, comment: String = "") throws -> GeneratedSSHKey {
        let keyTypeString: String
        let publicKeyRaw: Data
        let seed: Data
        let nioKey: NIOSSHPrivateKey
        do {
            switch type {
            case .mldsa44:
                let key = try MLDSA44SSH.PrivateKey()
                keyTypeString = MLDSA44SSH.algorithmName
                publicKeyRaw = key.mldsaPublicKey.rawRepresentation
                seed = key.seedRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            case .mldsa65:
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw SSHKeyGenerationError.mldsaGenerationFailed(keyTypeName: type.shortDisplayName)
                }
                let key = try MLDSA65SSH.PrivateKey()
                keyTypeString = "ssh-mldsa65"
                publicKeyRaw = key.mldsaPublicKey.rawRepresentation
                seed = key.seedRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            case .mldsa87:
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw SSHKeyGenerationError.mldsaGenerationFailed(keyTypeName: type.shortDisplayName)
                }
                let key = try MLDSA87SSH.PrivateKey()
                keyTypeString = "ssh-mldsa87"
                publicKeyRaw = key.mldsaPublicKey.rawRepresentation
                seed = key.seedRepresentation
                nioKey = NIOSSHPrivateKey(custom: key)
            default:
                throw SSHKeyGenerationError.mldsaGenerationFailed(keyTypeName: type.shortDisplayName)
            }
        } catch let error as SSHKeyGenerationError {
            throw error
        } catch {
            throw SSHKeyGenerationError.mldsaGenerationFailed(keyTypeName: type.shortDisplayName)
        }

        var publicKeyBlob = ByteBuffer()
        publicKeyBlob.writeSSHString(keyTypeString)
        publicKeyBlob.writeSSHBuffer(ByteBuffer(data: publicKeyRaw))

        let publicKeyOpenSSH = formatOpenSSHPublicKeyLine(
            keyTypeString: keyTypeString,
            blob: publicKeyBlob,
            comment: comment
        )

        var privateSection = ByteBuffer()
        let checkBytes = UInt32.random(in: 0...UInt32.max)
        privateSection.writeInteger(checkBytes)
        privateSection.writeInteger(checkBytes)
        privateSection.writeSSHString(keyTypeString)
        privateSection.writeSSHBuffer(ByteBuffer(data: publicKeyRaw))
        // sk = 32-byte FIPS 204 seed (same convention as the hybrid type)
        privateSection.writeSSHBuffer(ByteBuffer(data: seed))
        privateSection.writeSSHString(comment)

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        // SSHKeyParser fingerprints pure ML-DSA over the raw public key bytes.
        let fingerprint = sha256Hex(of: publicKeyRaw)

        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fingerprint,
            nioSSHPrivateKey: nioKey
        )
    }

    // MARK: - ECDSA generation

    static func generateECDSAP256(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P256.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(p256Key: privateKey)
        return formatECDSA(
            curveName: "nistp256",
            keyTypeString: "ecdsa-sha2-nistp256",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment,
            nioKey: nioKey
        )
    }

    static func generateECDSAP384(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P384.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(p384Key: privateKey)
        return formatECDSA(
            curveName: "nistp384",
            keyTypeString: "ecdsa-sha2-nistp384",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment,
            nioKey: nioKey
        )
    }

    static func generateECDSAP521(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P521.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(p521Key: privateKey)
        return formatECDSA(
            curveName: "nistp521",
            keyTypeString: "ecdsa-sha2-nistp521",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment,
            nioKey: nioKey
        )
    }

    private static func formatECDSA(
        curveName: String,
        keyTypeString: String,
        publicPoint: Data,
        privateScalar: Data,
        comment: String,
        nioKey: NIOSSHPrivateKey
    ) -> GeneratedSSHKey {
        let publicKeyBlob = buildECDSAPublicKeyBlob(
            keyTypeString: keyTypeString,
            curveName: curveName,
            publicPoint: publicPoint
        )

        let publicKeyOpenSSH = formatOpenSSHPublicKeyLine(
            keyTypeString: keyTypeString,
            blob: publicKeyBlob,
            comment: comment
        )

        let privateSection = buildECDSAPrivateSection(
            keyTypeString: keyTypeString,
            curveName: curveName,
            publicPoint: publicPoint,
            privateScalar: privateScalar,
            comment: comment
        )

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        // SSHKeyParser fingerprints ECDSA keys over the raw x963 point,
        // so we do the same here — otherwise the pre-import and
        // post-import fingerprints wouldn't match.
        let fingerprint = sha256Hex(of: publicPoint)

        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fingerprint,
            nioSSHPrivateKey: nioKey
        )
    }

    // MARK: - RSA generation

    static func generateRSA(bits: Int, comment: String = "") throws -> GeneratedSSHKey {
        let (n, e, d, p, q, iqmp) = try generateRSAKeyMaterial(bits: bits)

        let publicKeyBlob = buildRSAPublicKeyBlob(n: n, e: e)

        let publicKeyOpenSSH = formatOpenSSHPublicKeyLine(
            keyTypeString: "ssh-rsa",
            blob: publicKeyBlob,
            comment: comment
        )

        let privateSection = buildRSAPrivateSection(
            n: n, e: e, d: d, p: p, q: q, iqmp: iqmp,
            comment: comment
        )

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        // `SSHKeyParser.parseOpenSSHRSA` fingerprints RSA keys over the
        // concatenated wire-form mpint payloads of e and n (with leading
        // 0x00 sign byte when the high bit is set). Match that exactly so
        // pre-import and post-import fingerprints agree.
        let fingerprint = sha256Hex(of: mpIntPayload(e) + mpIntPayload(n))

        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fingerprint,
            nioSSHPrivateKey: nil
        )
    }

    /// Returns the SSH mpint payload bytes (no length prefix) for a
    /// big-endian unsigned integer: a leading 0x00 is prepended when the
    /// high bit of the most-significant byte is set, and actual leading
    /// zero bytes are stripped (per RFC 4251). Matches what
    /// `ByteBuffer.writeSSHMPInt` writes after its 4-byte length prefix.
    private static func mpIntPayload(_ data: Data) -> Data {
        var bytes = Array(data)
        while bytes.count > 1 && bytes[0] == 0 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }
        if !bytes.isEmpty && (bytes[0] & 0x80) != 0 {
            bytes.insert(0, at: 0)
        }
        return Data(bytes)
    }

    /// Generate RSA key material directly with BoringSSL. Citadel's
    /// `Insecure.RSA.PrivateKey(bits:)` runs `g^x mod p` over the DH-14
    /// group, which is not a real RSA keypair — we bypass it.
    /// - Returns: (n, e, d, p, q, iqmp = q^-1 mod p) as big-endian byte data.
    /// - Throws: `SSHKeyGenerationError` if BoringSSL can't allocate or
    ///   generate the key — surfaced through the Generate Key UI rather
    ///   than crashing the app.
    private static func generateRSAKeyMaterial(bits: Int) throws -> (Data, Data, Data, Data, Data, Data) {
        guard let rsa = CCryptoBoringSSL_RSA_new() else {
            throw SSHKeyGenerationError.rsaAllocationFailed
        }
        defer { CCryptoBoringSSL_RSA_free(rsa) }

        guard let eBN = CCryptoBoringSSL_BN_new() else {
            throw SSHKeyGenerationError.rsaAllocationFailed
        }
        defer { CCryptoBoringSSL_BN_free(eBN) }
        CCryptoBoringSSL_BN_set_word(eBN, 65537)

        let ok = CCryptoBoringSSL_RSA_generate_key_ex(rsa, Int32(bits), eBN, nil)
        guard ok == 1 else {
            throw SSHKeyGenerationError.rsaGenerationFailed(bits: bits)
        }

        var nPtr: UnsafePointer<BIGNUM>?
        var ePtr: UnsafePointer<BIGNUM>?
        var dPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_key(rsa, &nPtr, &ePtr, &dPtr)

        var pPtr: UnsafePointer<BIGNUM>?
        var qPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_factors(rsa, &pPtr, &qPtr)

        var dmp1Ptr: UnsafePointer<BIGNUM>?
        var dmq1Ptr: UnsafePointer<BIGNUM>?
        var iqmpPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_crt_params(rsa, &dmp1Ptr, &dmq1Ptr, &iqmpPtr)

        return (
            bignumToData(nPtr),
            bignumToData(ePtr),
            bignumToData(dPtr),
            bignumToData(pPtr),
            bignumToData(qPtr),
            bignumToData(iqmpPtr)
        )
    }

    private static func bignumToData(_ bn: UnsafePointer<BIGNUM>?) -> Data {
        guard let bn = bn else { return Data() }
        let numBytes = (Int(CCryptoBoringSSL_BN_num_bits(bn)) + 7) / 8
        guard numBytes > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: numBytes)
        _ = CCryptoBoringSSL_BN_bn2bin(bn, &bytes)
        return Data(bytes)
    }

    // MARK: - Public Key Formatting

    /// Format Ed25519 public key in OpenSSH format
    /// Format: "ssh-ed25519 BASE64(type-string-length + type-string + key-length + key) [comment]"
    static func formatPublicKeyOpenSSH(_ publicKey: Curve25519.Signing.PublicKey, comment: String = "") -> String {
        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!
        let rawKeyData = publicKey.rawRepresentation

        // Build SSH wire format: string(keyType) + string(publicKey)
        var wireFormat = Data()

        // Write key type as SSH string (4-byte big-endian length + UTF-8 bytes)
        var keyTypeLength = UInt32(keyTypeData.count).bigEndian
        wireFormat.append(Data(bytes: &keyTypeLength, count: 4))
        wireFormat.append(keyTypeData)

        // Write public key as SSH string (4-byte big-endian length + key bytes)
        var keyLength = UInt32(rawKeyData.count).bigEndian
        wireFormat.append(Data(bytes: &keyLength, count: 4))
        wireFormat.append(rawKeyData)

        // Base64 encode the wire format
        let base64 = wireFormat.base64EncodedString()

        if comment.isEmpty {
            return "\(keyType) \(base64)"
        } else {
            return "\(keyType) \(base64) \(comment)"
        }
    }

    /// Format public key from an existing stored key variant
    /// Works with Ed25519, RSA, and ECDSA keys
    static func formatPublicKey(from keyVariant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType, comment: String = "") -> String {
        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            // Extract public key and format based on type. (Secure Enclave
            // keys normally export via the cached publicKeyBlob in
            // SSHPublicKeyFormatter; this is the rarely-hit fallback.)
            return formatNIOSSHPublicKey(nioKey, keyType: keyType, comment: comment)

        case .rsa(let rsaKey):
            // RSA public key format: "ssh-rsa BASE64(e + n)"
            return formatRSAPublicKey(rsaKey, comment: comment)

        case .yubiKey(let reference):
            // YubiKey: format the cached public key blob
            let base64 = reference.publicKeyBlob.base64EncodedString()
            let algorithmName: String
            switch reference.algorithm {
            case .ecdsaP256: algorithmName = "ecdsa-sha2-nistp256"
            case .ecdsaP384: algorithmName = "ecdsa-sha2-nistp384"
            case .rsa2048, .rsa4096: algorithmName = "ssh-rsa"
            case .ed25519: algorithmName = "ssh-ed25519"
            case .mldsa44, .mldsa65, .mldsa87: algorithmName = reference.algorithm.sshKeyTypeString
            }
            if comment.isEmpty {
                return "\(algorithmName) \(base64)"
            } else {
                return "\(algorithmName) \(base64) \(comment)"
            }

        case .appleFIDO2(let reference):
            // Apple FIDO2: format the cached public key blob (sk-ecdsa-sha2-nistp256)
            let base64 = reference.publicKeyBlob.base64EncodedString()
            let algorithmName = "sk-ecdsa-sha2-nistp256@openssh.com"
            if comment.isEmpty {
                return "\(algorithmName) \(base64)"
            } else {
                return "\(algorithmName) \(base64) \(comment)"
            }
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent(let reference):
            // External agent: format the agent-provided public key blob
            let base64 = reference.publicKeyBlob.base64EncodedString()
            if comment.isEmpty {
                return "\(reference.algorithm) \(base64)"
            } else {
                return "\(reference.algorithm) \(base64) \(comment)"
            }
        #endif
        }
    }

    // MARK: - Private Key Formatting (OpenSSH Format)

    /// Format Ed25519 private key in OpenSSH format (unencrypted)
    /// This produces the same format as `ssh-keygen -t ed25519`
    private static func formatPrivateKeyOpenSSH(_ privateKey: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let publicKeyBlob = buildEd25519PublicKeyBlob(privateKey.publicKey)
        let privateSection = buildEd25519PrivateSection(privateKey, comment: comment)
        return wrapOpenSSHPrivateKey(publicKeyBlob: publicKeyBlob, privateSection: privateSection)
    }

    /// Wrap an SSH public-key blob + private section in the `openssh-key-v1`
    /// container and PEM armor. Shared with encrypted-key normalization via
    /// `OpenSSHContainer` so both paths emit byte-identical layout.
    private static func wrapOpenSSHPrivateKey(publicKeyBlob: ByteBuffer, privateSection: ByteBuffer) -> String {
        OpenSSHContainer.wrapUnencryptedPrivateKey(publicKeyBlob: publicKeyBlob, privateSection: privateSection)
    }

    /// Format a single-line OpenSSH authorized_keys entry:
    /// "<type> <base64-blob> <comment>" (comment omitted when empty).
    private static func formatOpenSSHPublicKeyLine(keyTypeString: String, blob: ByteBuffer, comment: String) -> String {
        let blobBytes = blob.getBytes(at: blob.readerIndex, length: blob.readableBytes) ?? []
        let base64 = Data(blobBytes).base64EncodedString()
        if comment.isEmpty {
            return "\(keyTypeString) \(base64)"
        }
        return "\(keyTypeString) \(base64) \(comment)"
    }

    /// SHA-256 (hex) of the supplied bytes. The per-key-type call sites
    /// hash exactly the material `SSHKeyParser.generateFingerprint` would
    /// hash post-import, so a generated key round-tripped through the
    /// parser yields the same fingerprint and dedup works.
    private static func sha256Hex(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ed25519 blob/section builders

    private static func buildEd25519PublicKeyBlob(_ publicKey: Curve25519.Signing.PublicKey) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString("ssh-ed25519")

        var pubKeyData = ByteBuffer()
        pubKeyData.writeBytes(publicKey.rawRepresentation)
        blob.writeSSHBuffer(pubKeyData)

        return blob
    }

    private static func buildEd25519PrivateSection(_ privateKey: Curve25519.Signing.PrivateKey, comment: String) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString("ssh-ed25519")

        var pubKeyBuffer = ByteBuffer()
        pubKeyBuffer.writeBytes(privateKey.publicKey.rawRepresentation)
        section.writeSSHBuffer(pubKeyBuffer)

        // Ed25519 "expanded" private key: 32-byte seed || 32-byte pubkey
        var privKeyBuffer = ByteBuffer()
        privKeyBuffer.writeBytes(privateKey.rawRepresentation)
        privKeyBuffer.writeBytes(privateKey.publicKey.rawRepresentation)
        section.writeSSHBuffer(privKeyBuffer)

        section.writeSSHString(comment)
        return section
    }

    // MARK: - ECDSA blob/section builders

    private static func buildECDSAPublicKeyBlob(keyTypeString: String, curveName: String, publicPoint: Data) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString(keyTypeString)
        blob.writeSSHString(curveName)

        var pointBuffer = ByteBuffer()
        pointBuffer.writeBytes(publicPoint)
        blob.writeSSHBuffer(pointBuffer)
        return blob
    }

    private static func buildECDSAPrivateSection(
        keyTypeString: String,
        curveName: String,
        publicPoint: Data,
        privateScalar: Data,
        comment: String
    ) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString(keyTypeString)
        section.writeSSHString(curveName)

        var pointBuffer = ByteBuffer()
        pointBuffer.writeBytes(publicPoint)
        section.writeSSHBuffer(pointBuffer)

        // OpenSSH encodes the scalar as an mpint (signed-magnitude with
        // leading 0x00 when the high bit is set). Anything else gets
        // rejected by `ssh-keygen` and other OpenSSH-compliant parsers.
        section.writeSSHMPInt(privateScalar)

        section.writeSSHString(comment)
        return section
    }

    // MARK: - RSA blob/section builders

    private static func buildRSAPublicKeyBlob(n: Data, e: Data) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString("ssh-rsa")
        blob.writeSSHMPInt(e)
        blob.writeSSHMPInt(n)
        return blob
    }

    private static func buildRSAPrivateSection(
        n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data,
        comment: String
    ) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString("ssh-rsa")
        // OpenSSH private-section field order for RSA: n, e, d, iqmp, p, q
        section.writeSSHMPInt(n)
        section.writeSSHMPInt(e)
        section.writeSSHMPInt(d)
        section.writeSSHMPInt(iqmp)
        section.writeSSHMPInt(p)
        section.writeSSHMPInt(q)

        section.writeSSHString(comment)
        return section
    }

    // MARK: - Fingerprint Generation

    /// SHA-256 (hex) of the raw 32-byte Ed25519 public key — matches
    /// `SSHKeyParser.parseOpenSSHEd25519Buffer` which fingerprints over
    /// `privateKey.publicKey.rawRepresentation`.
    private static func generateFingerprint(publicKey: Curve25519.Signing.PublicKey) -> String {
        return sha256Hex(of: publicKey.rawRepresentation)
    }

    // MARK: - NIOSSH Public Key Formatting

    private static func formatNIOSSHPublicKey(_ nioKey: NIOSSHPrivateKey, keyType: SSHKey.KeyType, comment: String) -> String {
        // NIOSSHPrivateKey doesn't expose the raw public key directly
        // This is a fallback path - prefer using cached publicKeyBlob from SSHKey
        // Return a message indicating the key should use cached blob
        return "# Public key not available. Try reloading the key details."
    }

    private static func formatRSAPublicKey(_ rsaKey: Insecure.RSA.PrivateKey, comment: String) -> String {
        // Insecure.RSA.PrivateKey from Citadel doesn't expose public key directly
        // This is a fallback path - prefer using cached publicKeyBlob from SSHKey
        return "# RSA public key not available. Try reloading the key details."
    }
}
