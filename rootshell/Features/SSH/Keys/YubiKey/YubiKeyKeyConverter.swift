//
//  YubiKeyKeyConverter.swift
//  rootshell
//
//  Converts parsed SSH keys to YubiKit native types for PIV import
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import CryptoTokenKit
import Foundation
import os.log
import YubiKit
import Crypto
import NIOSSH

/// Converts parsed SSH private keys to YubiKit native types for PIV import
@MainActor
final class YubiKeyKeyConverter {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyKeyConverter"
    )

    // MARK: - Conversion Result

    /// Result of converting a key for YubiKey import
    enum ConvertedKey: Sendable {
        case ed25519(Ed25519.PrivateKey)
        case ec(EC.PrivateKey)
        case rsa(RSA.PrivateKey)
        case mldsa(YubiKit.MLDSA.PrivateKey)
    }

    // MARK: - Ed25519 Conversion

    /// Convert Ed25519 key from seed bytes to YubiKit Ed25519.PrivateKey
    /// - Parameter seed: 32-byte Ed25519 private key seed
    /// - Returns: YubiKit Ed25519.PrivateKey
    static func convertEd25519(seed: Data) throws -> Ed25519.PrivateKey {
        Self.logger.info("Converting Ed25519 key from \(seed.count)-byte seed")

        guard seed.count == 32 else {
            throw YubiKeyError.keyConversionFailed("Ed25519 seed must be 32 bytes, got \(seed.count)")
        }

        guard let yubiKitKey = Ed25519.PrivateKey(seed: seed) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit Ed25519 private key from seed")
        }

        Self.logger.info("Ed25519 conversion successful")
        return yubiKitKey
    }

    // MARK: - ECDSA Conversion

    /// Convert ECDSA key from scalar and public point to YubiKit EC.PrivateKey
    /// - Parameters:
    ///   - scalar: Private scalar (k) bytes
    ///   - publicPoint: Uncompressed public point (0x04 || x || y) - optional, can derive from scalar
    ///   - curve: Elliptic curve type
    /// - Returns: YubiKit EC.PrivateKey
    static func convertECDSA(
        scalar: Data,
        publicPoint: Data?,
        curve: SSHKey.KeyType
    ) throws -> EC.PrivateKey {
        Self.logger.info("Converting ECDSA key: scalar=\(scalar.count) bytes, curve=\(curve.rawValue)")

        let ecCurve: EC.Curve
        let expectedScalarSize: Int

        switch curve {
        case .ecdsaP256:
            ecCurve = .secp256r1
            expectedScalarSize = 32
        case .ecdsaP384:
            ecCurve = .secp384r1
            expectedScalarSize = 48
        default:
            throw YubiKeyError.unsupportedKeyTypeForImport(curve.rawValue)
        }

        // Handle scalar that may have leading zero padding or be missing leading zeros
        var scalarData = scalar
        while scalarData.count > expectedScalarSize && scalarData.first == 0x00 {
            scalarData = scalarData.dropFirst()
        }
        while scalarData.count < expectedScalarSize {
            scalarData = Data([0x00]) + scalarData
        }

        guard scalarData.count == expectedScalarSize else {
            throw YubiKeyError.keyConversionFailed("ECDSA scalar must be \(expectedScalarSize) bytes, got \(scalarData.count)")
        }

        // Derive public key using CryptoKit, then create YubiKit key
        let yubiKitKey: EC.PrivateKey

        switch ecCurve {
        case .secp256r1:
            // Use CryptoKit to derive the public key from the scalar
            let cryptoKitKey = try P256.Signing.PrivateKey(rawRepresentation: scalarData)
            let publicKeyData = cryptoKitKey.publicKey.x963Representation

            // Parse uncompressed point to get x, y
            guard let parsedKey = EC.PrivateKey(x963: publicKeyData + scalarData, curve: .secp256r1) else {
                throw YubiKeyError.keyConversionFailed("Failed to create YubiKit EC private key for P-256")
            }
            yubiKitKey = parsedKey

        case .secp384r1:
            // Use CryptoKit to derive the public key from the scalar
            let cryptoKitKey = try P384.Signing.PrivateKey(rawRepresentation: scalarData)
            let publicKeyData = cryptoKitKey.publicKey.x963Representation

            // Parse uncompressed point to get x, y
            guard let parsedKey = EC.PrivateKey(x963: publicKeyData + scalarData, curve: .secp384r1) else {
                throw YubiKeyError.keyConversionFailed("Failed to create YubiKit EC private key for P-384")
            }
            yubiKitKey = parsedKey
        }

        let curveDesc = ecCurve == .secp256r1 ? "P-256" : "P-384"
        Self.logger.info("ECDSA conversion successful for \(curveDesc)")
        return yubiKitKey
    }

    // MARK: - RSA Conversion

    /// Convert RSA key from CRT parameters to YubiKit RSA.PrivateKey
    /// - Parameter crtParams: RSA CRT parameters (n, e, d, p, q, dP, dQ, qInv)
    /// - Returns: YubiKit RSA.PrivateKey
    static func convertRSA(crtParams: SSHKeyParser.RSACRTParameters) throws -> RSA.PrivateKey {
        Self.logger.info("Converting RSA key: n=\(crtParams.n.count) bytes")

        // YubiKit RSA.PrivateKey requires all CRT parameters
        guard let yubiKitKey = RSA.PrivateKey(
            n: crtParams.n,
            e: crtParams.e,
            d: crtParams.d,
            p: crtParams.p,
            q: crtParams.q,
            dP: crtParams.dP,
            dQ: crtParams.dQ,
            qInv: crtParams.qInv
        ) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit RSA private key from CRT parameters")
        }

        Self.logger.info("RSA conversion successful, key size: \(yubiKitKey.size.rawValue) bits")
        return yubiKitKey
    }

    // MARK: - Auto-Detection Conversion

    /// Convert a parsed SSH key to the appropriate YubiKit key type
    /// - Parameters:
    ///   - parsedKey: The parsed SSH key from SSHKeyParser
    ///   - keyType: The SSH key type
    /// - Returns: ConvertedKey containing the YubiKit key
    static func convert(parsedKey: SSHKeyParser.ParsedKey) throws -> ConvertedKey {
        switch parsedKey.keyType {
        case .ed25519:
            // For Ed25519, we need to extract the seed from the NIO key
            guard let nioKey = parsedKey.nioSSHKey else {
                throw YubiKeyError.keyConversionFailed("Missing NIO SSH key for Ed25519")
            }
            let seed = try extractEd25519Seed(from: nioKey)
            let yubiKitKey = try convertEd25519(seed: seed)
            return .ed25519(yubiKitKey)

        case .ecdsaP256, .ecdsaP384:
            guard let nioKey = parsedKey.nioSSHKey else {
                throw YubiKeyError.keyConversionFailed("Missing NIO SSH key for ECDSA")
            }
            let scalar = try extractECDSAScalar(from: nioKey, keyType: parsedKey.keyType)
            let yubiKitKey = try convertECDSA(scalar: scalar, publicPoint: nil, curve: parsedKey.keyType)
            return .ec(yubiKitKey)

        case .rsa:
            guard let crtParams = parsedKey.rsaCRTParams else {
                throw YubiKeyError.missingCRTParameters
            }
            let yubiKitKey = try convertRSA(crtParams: crtParams)
            return .rsa(yubiKitKey)

        case .ecdsaP521:
            throw YubiKeyError.unsupportedKeyTypeForImport("ECDSA P-521 (not supported by YubiKey PIV)")

        case .mldsa44, .mldsa65, .mldsa87:
            guard let seed = parsedKey.mldsaSeed,
                  let parameterSet = mldsaParameterSet(for: parsedKey.keyType),
                  let key = YubiKit.MLDSA.PrivateKey(seed: seed, parameterSet: parameterSet) else {
                throw YubiKeyError.keyConversionFailed("Missing ML-DSA seed")
            }
            return .mldsa(key)

        case .mldsa44Ed25519:
            throw YubiKeyError.unsupportedKeyTypeForImport("ML-DSA-44 + Ed25519 (a PIV slot holds one key)")

        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            throw YubiKeyError.keyAlreadyOnHardware

        case .externalAgent:
            throw YubiKeyError.unsupportedKeyTypeForImport("external SSH agent key (no private material)")
        }
    }

    // MARK: - ML-DSA

    nonisolated static func mldsaParameterSet(for keyType: SSHKey.KeyType) -> YubiKit.MLDSA.ParameterSet? {
        switch keyType {
        case .mldsa44: return .mlDSA44
        case .mldsa65: return .mlDSA65
        case .mldsa87: return .mlDSA87
        default: return nil
        }
    }

    nonisolated static func algorithm(for parameterSet: YubiKit.MLDSA.ParameterSet) -> YubiKeyAlgorithm {
        switch parameterSet {
        case .mlDSA44: return .mldsa44
        case .mlDSA65: return .mldsa65
        case .mlDSA87: return .mldsa87
        }
    }

    /// SSH wire blob for a PIV ML-DSA key: `string "ssh-mldsaNN" || string pk`,
    /// the same encoding as the app's software `ssh-mldsa*` keys.
    nonisolated static func sshPublicKeyBlob(for key: YubiKit.MLDSA.PublicKey) -> Data {
        var blob = Data()
        appendSSHString(&blob, Data(algorithm(for: key.parameterSet).sshKeyTypeString.utf8))
        appendSSHString(&blob, key.keyData)
        return blob
    }

    /// X.509 AlgorithmIdentifier OID TLV for an ML-DSA parameter set (RFC 9881).
    nonisolated static func mldsaOID(_ parameterSet: YubiKit.MLDSA.ParameterSet) -> Data {
        let suffix: UInt8
        switch parameterSet {
        case .mlDSA44: suffix = 0x11
        case .mlDSA65: suffix = 0x12
        case .mlDSA87: suffix = 0x13
        }
        return Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, suffix])
    }

    /// Minimal self-signed X.509 shell for an ML-DSA slot. Like the app's other
    /// slot certificates the signature is empty: discovery only reads the key
    /// back out of it.
    nonisolated static func mldsaSlotCertificate(for key: YubiKit.MLDSA.PublicKey, commonName: String) -> Data {
        func tlv(_ tag: UInt8, _ value: Data) -> Data { TKBERTLVRecord(tag: TKTLVTag(tag), value: value).data }
        func utcTime(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }

        var serial = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        serial[0] = (serial[0] & 0x7F) | 0x01  // positive, no leading zero byte
        let signatureAlgorithm = tlv(0x30, mldsaOID(key.parameterSet))
        let name = tlv(0x30, tlv(0x31, tlv(0x30, Data([0x06, 0x03, 0x55, 0x04, 0x03]) + tlv(0x0C, Data(commonName.utf8)))))
        let now = Date()
        let validity = tlv(0x30, utcTime(now) + utcTime(now.addingTimeInterval(365 * 24 * 60 * 60)))

        let tbs = tlv(0x30,
            tlv(0xA0, Data([0x02, 0x01, 0x02]))
            + tlv(0x02, serial)
            + signatureAlgorithm
            + name
            + validity
            + name
            + key.spki
        )
        return tlv(0x30, tbs + signatureAlgorithm + Data([0x03, 0x01, 0x00]))
    }

    private nonisolated static func appendSSHString(_ buffer: inout Data, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        buffer.append(data)
    }

    // MARK: - RSA Public Key Parsing

    /// Splits a PKCS#1 RSAPublicKey (SEQUENCE { modulus INTEGER, publicExponent INTEGER }),
    /// as returned by SecKeyCopyExternalRepresentation, into its two integers.
    /// Every read is bounds-checked so a truncated or malformed cert throws instead of trapping.
    nonisolated static func rsaPublicKeyComponents(fromPKCS1 derData: Data) throws -> (exponent: Data, modulus: Data) {
        let bytes = [UInt8](derData)
        var index = 0

        func readLength() throws -> Int {
            guard index < bytes.count else {
                throw YubiKeyError.keyConversionFailed("Truncated RSA key")
            }
            let first = Int(bytes[index])
            index += 1
            guard first & 0x80 != 0 else { return first }
            let count = first & 0x7F
            guard count > 0, count <= 4, count <= bytes.count - index else {
                throw YubiKeyError.keyConversionFailed("Invalid RSA key length encoding")
            }
            var length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
            return length
        }

        /// Consumes a tag and its length; returns the content length, guaranteed to fit the buffer.
        func readHeader(tag: UInt8, _ expected: String) throws -> Int {
            guard index < bytes.count, bytes[index] == tag else {
                throw YubiKeyError.keyConversionFailed("Expected \(expected)")
            }
            index += 1
            let length = try readLength()
            guard length <= bytes.count - index else {
                throw YubiKeyError.keyConversionFailed("Truncated RSA key")
            }
            return length
        }

        _ = try readHeader(tag: 0x30, "SEQUENCE for RSA key")

        let modulusLen = try readHeader(tag: 0x02, "INTEGER for modulus")
        let modulus = Data(bytes[index..<index + modulusLen])
        index += modulusLen

        let exponentLen = try readHeader(tag: 0x02, "INTEGER for exponent")
        let exponent = Data(bytes[index..<index + exponentLen])

        return (exponent, modulus)
    }

    // MARK: - Private Helpers

    /// Extract Ed25519 seed from NIOSSHPrivateKey
    private static func extractEd25519Seed(from nioKey: NIOSSHPrivateKey) throws -> Data {
        // NIOSSHPrivateKey wraps Curve25519.Signing.PrivateKey
        // We need to access the raw representation (seed)
        // Unfortunately NIOSSHPrivateKey doesn't expose this directly,
        // so we need to use reflection or re-parse the key

        // The cleanest approach is to use the key's signing capability to derive the seed
        // However, NIOSSHPrivateKey doesn't expose rawRepresentation

        // Alternative: When we parse the key, we have access to the seed in the parse functions
        // For now, throw an error - the importer should use the raw seed from parsing
        throw YubiKeyError.keyConversionFailed(
            "Ed25519 seed extraction requires raw key data. Use the seed from key parsing directly."
        )
    }

    /// Extract ECDSA scalar from NIOSSHPrivateKey
    private static func extractECDSAScalar(from nioKey: NIOSSHPrivateKey, keyType: SSHKey.KeyType) throws -> Data {
        // Similar to Ed25519, NIOSSHPrivateKey doesn't expose the raw scalar
        throw YubiKeyError.keyConversionFailed(
            "ECDSA scalar extraction requires raw key data. Use the scalar from key parsing directly."
        )
    }
}

// MARK: - Extended ParsedKey Conversion

extension SSHKeyParser.ParsedKey {
    /// Check if this key type can be imported to YubiKey PIV
    var canImportToYubiKey: Bool {
        switch keyType {
        case .ed25519, .ecdsaP256, .ecdsaP384, .rsa, .mldsa44, .mldsa65, .mldsa87:
            return true
        case .ecdsaP521, .mldsa44Ed25519:
            // Not supported by YubiKey PIV
            return false
        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            // Already on hardware / hardware-protected
            return false
        case .externalAgent:
            // No private material in the app to move to hardware
            return false
        }
    }

    /// Reason why this key cannot be imported, or nil if it can be imported
    var importBlockReason: String? {
        switch keyType {
        case .ecdsaP521:
            return "ECDSA P-521 is not supported by YubiKey PIV"
        case .mldsa44Ed25519:
            return "ML-DSA-44 + Ed25519 keys cannot be stored in a single PIV slot"
        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            return "Key is already stored on hardware"
        default:
            return nil
        }
    }
}
