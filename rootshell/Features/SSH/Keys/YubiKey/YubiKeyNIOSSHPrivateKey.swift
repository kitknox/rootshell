//
//  YubiKeyNIOSSHPrivateKey.swift
//  rootshell
//
//  NIOSSH wrapper for YubiKey-based SSH authentication
//  Bridges async YubiKey signing operations to NIOSSH's synchronous interface
//
//  NIOSSH requires static algorithm prefixes, so we need separate types for each
//  algorithm family: RSA, ECDSA P-256, and ECDSA P-384.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOSSH
import NIOCore
import Crypto
import os.log

// MARK: - Shared Logger

nonisolated private let yubiKeyNIOSSHLogger = Logger(
    subsystem: "com.rootshell",
    category: "YubiKeyNIOSSH"
)

/// Outer bound for a whole YubiKey signing op (connect + PIN + sign) bridged to
/// NIOSSH's synchronous interface. Deliberately generous: the user may need to
/// find and insert/touch their key, and the hardware-key overlay's Cancel is
/// the real gate (wait-until-cancel UX) — this only backstops a wedged op so a
/// detached signing task can't hang forever. Kept above
/// `YubiKeyConnectionManager.wiredConnectTimeout` (600s) so the friendlier
/// `.noDeviceDetected` error wins over a generic semaphore timeout.
private let yubiKeyNIOSSHSigningTimeout: TimeInterval = 660.0

// MARK: - Common Helpers

/// Extract key data portion from full SSH public key blob
/// SSH public key blob format: string(algorithm) + key-specific-data
private func extractKeyData(from blob: Data, algorithm: YubiKeyAlgorithm) -> Data {
    var offset = 0
    let bytes = [UInt8](blob)

    guard bytes.count > 4 else { return blob }

    // Read algorithm string length
    let algorithmLength = Int(UInt32(bigEndian: bytes[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }))
    offset += 4 + algorithmLength

    // Return the rest as key data
    guard offset < bytes.count else { return Data() }
    return Data(bytes[offset...])
}

/// Write ECDSA key data to buffer
private func writeECDSAKeyData(to buffer: inout ByteBuffer, keyData: Data, curveId: String) -> Int {
    var offset = 0
    let bytes = [UInt8](keyData)
    var written = 0

    // Read curve identifier string from key data
    if bytes.count > 4 {
        let curveLength = Int(UInt32(bigEndian: bytes[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4

        if offset + curveLength <= bytes.count {
            // Write curve identifier
            written += writeYubiKeySSHStringBytes(&buffer, curveId)
            offset += curveLength

            // Read and write the EC point
            if offset + 4 <= bytes.count {
                let pointLength = Int(UInt32(bigEndian: bytes[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }))
                offset += 4

                if offset + pointLength <= bytes.count {
                    let pointData = Data(bytes[offset..<offset+pointLength])
                    written += writeYubiKeySSHData(&buffer, pointData)
                }
            }
        }
    }

    // Fallback: just write the raw key data if parsing failed
    if written == 0 {
        buffer.writeBytes(keyData)
        return keyData.count
    }

    return written
}

// MARK: - RSA Public Key

/// RSA public key wrapper for YubiKey PIV RSA keys
struct YubiKeyRSAPublicKey: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { "ssh-rsa" }
    static var authAlgorithmName: String { "rsa-sha2-256" }

    let algorithm: YubiKeyAlgorithm
    private let keyData: Data
    let publicKeyBlob: Data

    var rawRepresentation: Data { keyData }

    init(reference: YubiKeyReference) {
        self.algorithm = reference.algorithm
        self.publicKeyBlob = reference.publicKeyBlob
        self.keyData = extractKeyData(from: reference.publicKeyBlob, algorithm: reference.algorithm)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false  // Server verifies signatures
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        // RSA: mpint(e) + mpint(n) - key data already contains this
        buffer.writeBytes(keyData)
        return keyData.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyRSAPublicKey {
        throw YubiKeyError.unsupportedFeature("Cannot read YubiKey public key from wire format")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(publicKeyBlob)
    }

    public static func == (lhs: YubiKeyRSAPublicKey, rhs: YubiKeyRSAPublicKey) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

// MARK: - RSA Signature

struct YubiKeyRSASignature: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { "rsa-sha2-256" }

    let algorithm: YubiKeyAlgorithm
    private let signatureData: Data

    var rawRepresentation: Data { signatureData }

    init(algorithm: YubiKeyAlgorithm, signatureData: Data) {
        self.algorithm = algorithm
        self.signatureData = signatureData
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeYubiKeySSHData(&buffer, signatureData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyRSASignature {
        guard let sigData = readYubiKeySSHString(&buffer) else {
            throw YubiKeyError.signingFailed("Failed to read signature data")
        }
        return YubiKeyRSASignature(algorithm: .rsa2048, signatureData: Data(sigData.readableBytesView))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(signatureData)
    }

    static func == (lhs: YubiKeyRSASignature, rhs: YubiKeyRSASignature) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.signatureData == rhs.signatureData
    }
}

// MARK: - ECDSA P-256 Public Key

/// ECDSA P-256 public key wrapper for YubiKey PIV keys
struct YubiKeyECDSAP256PublicKey: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp256" }

    let algorithm: YubiKeyAlgorithm
    private let keyData: Data
    let publicKeyBlob: Data

    var rawRepresentation: Data { keyData }

    init(reference: YubiKeyReference) {
        self.algorithm = reference.algorithm
        self.publicKeyBlob = reference.publicKeyBlob
        self.keyData = extractKeyData(from: reference.publicKeyBlob, algorithm: reference.algorithm)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeECDSAKeyData(to: &buffer, keyData: keyData, curveId: "nistp256")
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyECDSAP256PublicKey {
        throw YubiKeyError.unsupportedFeature("Cannot read YubiKey public key from wire format")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(publicKeyBlob)
    }

    public static func == (lhs: YubiKeyECDSAP256PublicKey, rhs: YubiKeyECDSAP256PublicKey) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

// MARK: - ECDSA P-256 Signature

struct YubiKeyECDSAP256Signature: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { "ecdsa-sha2-nistp256" }

    let algorithm: YubiKeyAlgorithm
    private let signatureData: Data

    var rawRepresentation: Data { signatureData }

    init(algorithm: YubiKeyAlgorithm, signatureData: Data) {
        self.algorithm = algorithm
        self.signatureData = signatureData
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeYubiKeySSHData(&buffer, signatureData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyECDSAP256Signature {
        guard let sigData = readYubiKeySSHString(&buffer) else {
            throw YubiKeyError.signingFailed("Failed to read signature data")
        }
        return YubiKeyECDSAP256Signature(algorithm: .ecdsaP256, signatureData: Data(sigData.readableBytesView))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(signatureData)
    }

    static func == (lhs: YubiKeyECDSAP256Signature, rhs: YubiKeyECDSAP256Signature) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.signatureData == rhs.signatureData
    }
}

// MARK: - ECDSA P-384 Public Key

/// ECDSA P-384 public key wrapper for YubiKey PIV keys
struct YubiKeyECDSAP384PublicKey: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp384" }

    let algorithm: YubiKeyAlgorithm
    private let keyData: Data
    let publicKeyBlob: Data

    var rawRepresentation: Data { keyData }

    init(reference: YubiKeyReference) {
        self.algorithm = reference.algorithm
        self.publicKeyBlob = reference.publicKeyBlob
        self.keyData = extractKeyData(from: reference.publicKeyBlob, algorithm: reference.algorithm)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeECDSAKeyData(to: &buffer, keyData: keyData, curveId: "nistp384")
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyECDSAP384PublicKey {
        throw YubiKeyError.unsupportedFeature("Cannot read YubiKey public key from wire format")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(publicKeyBlob)
    }

    public static func == (lhs: YubiKeyECDSAP384PublicKey, rhs: YubiKeyECDSAP384PublicKey) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

// MARK: - ECDSA P-384 Signature

struct YubiKeyECDSAP384Signature: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { "ecdsa-sha2-nistp384" }

    let algorithm: YubiKeyAlgorithm
    private let signatureData: Data

    var rawRepresentation: Data { signatureData }

    init(algorithm: YubiKeyAlgorithm, signatureData: Data) {
        self.algorithm = algorithm
        self.signatureData = signatureData
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeYubiKeySSHData(&buffer, signatureData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyECDSAP384Signature {
        guard let sigData = readYubiKeySSHString(&buffer) else {
            throw YubiKeyError.signingFailed("Failed to read signature data")
        }
        return YubiKeyECDSAP384Signature(algorithm: .ecdsaP384, signatureData: Data(sigData.readableBytesView))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(signatureData)
    }

    static func == (lhs: YubiKeyECDSAP384Signature, rhs: YubiKeyECDSAP384Signature) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.signatureData == rhs.signatureData
    }
}

// MARK: - Ed25519 Public Key

/// Ed25519 public key wrapper for YubiKey PIV keys (YubiKey 5.7+)
struct YubiKeyEd25519PublicKey: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { "ssh-ed25519" }

    let algorithm: YubiKeyAlgorithm
    private let keyData: Data
    let publicKeyBlob: Data

    var rawRepresentation: Data { keyData }

    init(reference: YubiKeyReference) {
        self.algorithm = reference.algorithm
        self.publicKeyBlob = reference.publicKeyBlob
        self.keyData = extractKeyData(from: reference.publicKeyBlob, algorithm: reference.algorithm)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false  // Server verifies signatures
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        // Ed25519: just the raw 32-byte public key
        buffer.writeBytes(keyData)
        return keyData.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyEd25519PublicKey {
        throw YubiKeyError.unsupportedFeature("Cannot read YubiKey public key from wire format")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(publicKeyBlob)
    }

    public static func == (lhs: YubiKeyEd25519PublicKey, rhs: YubiKeyEd25519PublicKey) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

// MARK: - Ed25519 Signature

struct YubiKeyEd25519Signature: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { "ssh-ed25519" }

    let algorithm: YubiKeyAlgorithm
    private let signatureData: Data

    var rawRepresentation: Data { signatureData }

    init(algorithm: YubiKeyAlgorithm, signatureData: Data) {
        self.algorithm = algorithm
        self.signatureData = signatureData
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeYubiKeySSHData(&buffer, signatureData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyEd25519Signature {
        guard let sigData = readYubiKeySSHString(&buffer) else {
            throw YubiKeyError.signingFailed("Failed to read signature data")
        }
        return YubiKeyEd25519Signature(algorithm: .ed25519, signatureData: Data(sigData.readableBytesView))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(signatureData)
    }

    static func == (lhs: YubiKeyEd25519Signature, rhs: YubiKeyEd25519Signature) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.signatureData == rhs.signatureData
    }
}

// MARK: - Legacy Aliases (for backwards compatibility)

/// Legacy alias - use algorithm-specific types instead
typealias YubiKeyPublicKey = YubiKeyECDSAP256PublicKey
typealias YubiKeySignature = YubiKeyECDSAP256Signature

// MARK: - RSA Private Key

/// RSA private key wrapper for YubiKey PIV RSA keys
final class YubiKeyRSAPrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "ssh-rsa" }
    static var authAlgorithmName: String { "rsa-sha2-256" }

    private let reference: YubiKeyReference
    private let cachedPublicKey: YubiKeyRSAPublicKey
    private static let signingTimeout: TimeInterval = yubiKeyNIOSSHSigningTimeout

    init(reference: YubiKeyReference) {
        self.reference = reference
        self.cachedPublicKey = YubiKeyRSAPublicKey(reference: reference)
        yubiKeyNIOSSHLogger.info("Created YubiKeyRSAPrivateKey for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        yubiKeyNIOSSHLogger.info("RSA signature requested for key \(self.reference.keyID)")

        let sigBlob = try performSigning(data: data, reference: reference, timeout: Self.signingTimeout)
        return YubiKeyRSASignature(algorithm: reference.algorithm, signatureData: sigBlob)
    }
}

// MARK: - ECDSA P-256 Private Key

/// ECDSA P-256 private key wrapper for YubiKey PIV keys
final class YubiKeyECDSAP256PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "ecdsa-sha2-nistp256" }

    private let reference: YubiKeyReference
    private let cachedPublicKey: YubiKeyECDSAP256PublicKey
    private static let signingTimeout: TimeInterval = yubiKeyNIOSSHSigningTimeout

    init(reference: YubiKeyReference) {
        self.reference = reference
        self.cachedPublicKey = YubiKeyECDSAP256PublicKey(reference: reference)
        yubiKeyNIOSSHLogger.info("Created YubiKeyECDSAP256PrivateKey for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        yubiKeyNIOSSHLogger.info("ECDSA P-256 signature requested for key \(self.reference.keyID)")

        let sigBlob = try performSigning(data: data, reference: reference, timeout: Self.signingTimeout)
        return YubiKeyECDSAP256Signature(algorithm: reference.algorithm, signatureData: sigBlob)
    }
}

// MARK: - ECDSA P-384 Private Key

/// ECDSA P-384 private key wrapper for YubiKey PIV keys
final class YubiKeyECDSAP384PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "ecdsa-sha2-nistp384" }

    private let reference: YubiKeyReference
    private let cachedPublicKey: YubiKeyECDSAP384PublicKey
    private static let signingTimeout: TimeInterval = yubiKeyNIOSSHSigningTimeout

    init(reference: YubiKeyReference) {
        self.reference = reference
        self.cachedPublicKey = YubiKeyECDSAP384PublicKey(reference: reference)
        yubiKeyNIOSSHLogger.info("Created YubiKeyECDSAP384PrivateKey for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        yubiKeyNIOSSHLogger.info("ECDSA P-384 signature requested for key \(self.reference.keyID)")

        let sigBlob = try performSigning(data: data, reference: reference, timeout: Self.signingTimeout)
        return YubiKeyECDSAP384Signature(algorithm: reference.algorithm, signatureData: sigBlob)
    }
}

// MARK: - Ed25519 Private Key

/// Ed25519 private key wrapper for YubiKey PIV keys (YubiKey 5.7+)
final class YubiKeyEd25519PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "ssh-ed25519" }

    private let reference: YubiKeyReference
    private let cachedPublicKey: YubiKeyEd25519PublicKey
    private static let signingTimeout: TimeInterval = yubiKeyNIOSSHSigningTimeout

    init(reference: YubiKeyReference) {
        self.reference = reference
        self.cachedPublicKey = YubiKeyEd25519PublicKey(reference: reference)
        yubiKeyNIOSSHLogger.info("Created YubiKeyEd25519PrivateKey for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        yubiKeyNIOSSHLogger.info("Ed25519 signature requested for key \(self.reference.keyID)")

        let sigBlob = try performSigning(data: data, reference: reference, timeout: Self.signingTimeout)
        return YubiKeyEd25519Signature(algorithm: reference.algorithm, signatureData: sigBlob)
    }
}

// MARK: - ML-DSA (YubiKey firmware 6.0+)

/// Parameter-set marker; NIOSSH needs a static prefix per key type.
nonisolated protocol YubiKeyMLDSAVariant: Sendable {
    static var algorithm: YubiKeyAlgorithm { get }
}

nonisolated enum YubiKeyMLDSA44: YubiKeyMLDSAVariant { static var algorithm: YubiKeyAlgorithm { .mldsa44 } }
nonisolated enum YubiKeyMLDSA65: YubiKeyMLDSAVariant { static var algorithm: YubiKeyAlgorithm { .mldsa65 } }
nonisolated enum YubiKeyMLDSA87: YubiKeyMLDSAVariant { static var algorithm: YubiKeyAlgorithm { .mldsa87 } }

/// Same wire format as the app's software `ssh-mldsa*` keys: `string pk`.
struct YubiKeyMLDSAPublicKey<Variant: YubiKeyMLDSAVariant>: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { Variant.algorithm.sshKeyTypeString }

    /// `string pk`, as it follows the algorithm name in the blob.
    private let keyData: Data
    let publicKeyBlob: Data

    var rawRepresentation: Data { keyData }

    init(reference: YubiKeyReference) {
        self.publicKeyBlob = reference.publicKeyBlob
        self.keyData = extractKeyData(from: reference.publicKeyBlob, algorithm: reference.algorithm)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false  // Server verifies signatures
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(keyData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyMLDSAPublicKey<Variant> {
        throw YubiKeyError.unsupportedFeature("Cannot read YubiKey public key from wire format")
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKeyBlob)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

struct YubiKeyMLDSASignature<Variant: YubiKeyMLDSAVariant>: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { Variant.algorithm.sshKeyTypeString }

    private let signatureData: Data

    var rawRepresentation: Data { signatureData }

    init(signatureData: Data) {
        self.signatureData = signatureData
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        return writeYubiKeySSHData(&buffer, signatureData)
    }

    static func read(from buffer: inout ByteBuffer) throws -> YubiKeyMLDSASignature<Variant> {
        guard let sigData = readYubiKeySSHString(&buffer) else {
            throw YubiKeyError.signingFailed("Failed to read signature data")
        }
        return YubiKeyMLDSASignature(signatureData: Data(sigData.readableBytesView))
    }
}

final class YubiKeyMLDSAPrivateKey<Variant: YubiKeyMLDSAVariant>: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { Variant.algorithm.sshKeyTypeString }

    private let reference: YubiKeyReference
    private let cachedPublicKey: YubiKeyMLDSAPublicKey<Variant>
    private static var signingTimeout: TimeInterval { yubiKeyNIOSSHSigningTimeout }

    init(reference: YubiKeyReference) {
        self.reference = reference
        self.cachedPublicKey = YubiKeyMLDSAPublicKey(reference: reference)
        yubiKeyNIOSSHLogger.info("Created YubiKey \(Variant.algorithm.rawValue) private key for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        yubiKeyNIOSSHLogger.info("\(Variant.algorithm.rawValue) signature requested for key \(self.reference.keyID)")

        let sigBlob = try performSigning(data: data, reference: reference, timeout: Self.signingTimeout)
        return YubiKeyMLDSASignature<Variant>(signatureData: sigBlob)
    }
}

// MARK: - Legacy Private Key Wrapper

/// Legacy wrapper that creates the appropriate algorithm-specific private key
/// Use `createYubiKeyPrivateKey(reference:)` for new code
final class YubiKeyNIOSSHPrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "ecdsa-sha2-nistp256" }

    private let reference: YubiKeyReference
    private let innerKey: any NIOSSHPrivateKeyProtocol
    private static let signingTimeout: TimeInterval = yubiKeyNIOSSHSigningTimeout

    init(reference: YubiKeyReference) {
        self.reference = reference

        // Create the appropriate algorithm-specific key
        switch reference.algorithm {
        case .rsa2048, .rsa4096:
            self.innerKey = YubiKeyRSAPrivateKey(reference: reference)
        case .ecdsaP256:
            self.innerKey = YubiKeyECDSAP256PrivateKey(reference: reference)
        case .ecdsaP384:
            self.innerKey = YubiKeyECDSAP384PrivateKey(reference: reference)
        case .ed25519:
            // Ed25519 is now supported on YubiKey 5.7+
            self.innerKey = YubiKeyEd25519PrivateKey(reference: reference)
        case .mldsa44:
            self.innerKey = YubiKeyMLDSAPrivateKey<YubiKeyMLDSA44>(reference: reference)
        case .mldsa65:
            self.innerKey = YubiKeyMLDSAPrivateKey<YubiKeyMLDSA65>(reference: reference)
        case .mldsa87:
            self.innerKey = YubiKeyMLDSAPrivateKey<YubiKeyMLDSA87>(reference: reference)
        }

        yubiKeyNIOSSHLogger.info("Created YubiKeyNIOSSHPrivateKey (legacy wrapper) for key: \(reference.keyID), algorithm: \(reference.algorithm.rawValue)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { innerKey.publicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        // All PIV algorithms are now supported including Ed25519 on YubiKey 5.7+
        return try innerKey.signature(for: data)
    }
}

// MARK: - Factory Function

/// Creates the appropriate NIOSSHPrivateKeyProtocol implementation based on the key's algorithm
/// - Parameter reference: The YubiKey reference containing key metadata
/// - Returns: An algorithm-specific private key wrapper
func createYubiKeyPrivateKey(reference: YubiKeyReference) -> any NIOSSHPrivateKeyProtocol {
    // PIV keys - supports RSA, ECDSA, and Ed25519 (YubiKey 5.7+)
    // FIDO2 is handled via Apple AuthenticationServices
    switch reference.algorithm {
    case .rsa2048, .rsa4096:
        return YubiKeyRSAPrivateKey(reference: reference)
    case .ecdsaP256:
        return YubiKeyECDSAP256PrivateKey(reference: reference)
    case .ecdsaP384:
        return YubiKeyECDSAP384PrivateKey(reference: reference)
    case .ed25519:
        return YubiKeyEd25519PrivateKey(reference: reference)
    case .mldsa44:
        return YubiKeyMLDSAPrivateKey<YubiKeyMLDSA44>(reference: reference)
    case .mldsa65:
        return YubiKeyMLDSAPrivateKey<YubiKeyMLDSA65>(reference: reference)
    case .mldsa87:
        return YubiKeyMLDSAPrivateKey<YubiKeyMLDSA87>(reference: reference)
    }
}

// MARK: - Shared Signing Logic

/// Performs the actual YubiKey signing operation
/// Bridges async YubiKey signing to synchronous NIOSSH interface using semaphore
private func performSigning<D: DataProtocol>(
    data: D,
    reference: YubiKeyReference,
    timeout: TimeInterval
) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var signatureResult: Result<ByteBuffer, Error>?

    let task = Task.detached(priority: .high) {
        do {
            let signer = await YubiKeySigner.shared
            let dataArray = Array(data)

            guard let pivSlot = reference.pivSlot else {
                signatureResult = .failure(YubiKeyError.keyNotFound(slot: nil))
                semaphore.signal()
                return
            }

            yubiKeyNIOSSHLogger.info("Signing with PIV slot: \(pivSlot.rawValue), algorithm: \(reference.algorithm.rawValue)")
            let signature = try await signer.signWithPIV(
                serialNumber: reference.serialNumber,
                slot: pivSlot,
                algorithm: reference.algorithm,
                data: Data(dataArray),
                flags: 0
            )

            signatureResult = .success(signature)
        } catch {
            yubiKeyNIOSSHLogger.error("YubiKey signing failed: \(error)")
            signatureResult = .failure(error)
        }
        semaphore.signal()
    }

    let timeoutResult = semaphore.wait(timeout: .now() + timeout)

    guard timeoutResult == .success else {
        yubiKeyNIOSSHLogger.error("YubiKey signing timed out after \(timeout) seconds")
        // SSH reports failure now. Cancel the request so it doesn't prompt for
        // a PIN or sign later, when its turn for the key comes.
        task.cancel()
        throw YubiKeyError.signingFailed("Signing operation timed out")
    }

    guard let result = signatureResult else {
        throw YubiKeyError.signingFailed("No result from signing operation")
    }

    switch result {
    case .success(var signatureBuffer):
        return extractSignatureBlob(from: &signatureBuffer)
    case .failure(let error):
        throw error
    }
}

/// Extract the signature blob from SSH wire format signature
/// Input format: string(algorithm_name) + string(signature_blob)
private func extractSignatureBlob(from buffer: inout ByteBuffer) -> Data {
    // Skip algorithm string
    guard let algorithmLength = buffer.readInteger(as: UInt32.self) else {
        return Data(buffer.readableBytesView)
    }
    guard buffer.readBytes(length: Int(algorithmLength)) != nil else {
        return Data(buffer.readableBytesView)
    }

    // Read signature blob
    guard let sigLength = buffer.readInteger(as: UInt32.self) else {
        return Data(buffer.readableBytesView)
    }
    guard let sigBytes = buffer.readBytes(length: Int(sigLength)) else {
        return Data(buffer.readableBytesView)
    }

    return Data(sigBytes)
}

// MARK: - SSH String Helpers

private func readYubiKeySSHString(_ buffer: inout ByteBuffer) -> ByteBuffer? {
    guard let length = buffer.readInteger(as: UInt32.self) else {
        return nil
    }
    return buffer.readSlice(length: Int(length))
}

@discardableResult
private func writeYubiKeySSHStringBytes(_ buffer: inout ByteBuffer, _ string: String) -> Int {
    let data = string.data(using: .utf8) ?? Data()
    var written = buffer.writeInteger(UInt32(data.count))
    written += buffer.writeBytes(data)
    return written
}

@discardableResult
private func writeYubiKeySSHData(_ buffer: inout ByteBuffer, _ data: Data) -> Int {
    var written = buffer.writeInteger(UInt32(data.count))
    written += buffer.writeBytes(data)
    return written
}
