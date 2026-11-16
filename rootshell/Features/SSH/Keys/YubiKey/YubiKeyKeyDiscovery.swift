//
//  YubiKeyKeyDiscovery.swift
//  rootshell
//
//  Discovers SSH keys on YubiKey PIV slots
//  Migrated to yubikit-swift SDK with async/await APIs
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit
import Crypto

/// Handles discovery and import of keys from YubiKey devices
@MainActor
final class YubiKeyKeyDiscovery {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyDiscovery"
    )

    private let connectionManager: YubiKeyConnectionManager

    init(connectionManager: YubiKeyConnectionManager) {
        self.connectionManager = connectionManager
    }

    @MainActor
    convenience init() {
        self.init(connectionManager: .shared)
    }

    // MARK: - PIV Key Discovery

    /// Discover all PIV keys on the connected YubiKey
    func discoverPIVKeys(yubiKeySerial: UInt32) async throws -> [DiscoveredYubiKeyKey] {
        let session = try await connectionManager.getPIVSession()
        var discoveredKeys: [DiscoveredYubiKeyKey] = []

        // Check each PIV slot
        for slot in PIVSlot.allCases {
            do {
                let pivSlot = slot.toYubiKitSlot

                // Try to read the certificate from this slot using new SDK
                let certificate = try await session.getCertificate(in: pivSlot)

                // First check for Ed25519 via certificate OID (SecKey doesn't support Ed25519)
                let algorithm: YubiKeyAlgorithm
                let sshPublicKeyData: Data

                if case .mlDSA(let mldsaKey)? = certificate.publicKey {
                    algorithm = YubiKeyKeyConverter.algorithm(for: mldsaKey.parameterSet)
                    sshPublicKeyData = YubiKeyKeyConverter.sshPublicKeyBlob(for: mldsaKey)
                } else if let ed25519Algorithm = detectAlgorithmFromCertificate(certificate), ed25519Algorithm == .ed25519 {
                    // Ed25519: extract raw key from certificate DER
                    algorithm = .ed25519
                    let rawKey = try extractEd25519PublicKey(from: certificate)
                    sshPublicKeyData = convertEd25519ToSSHPublicKey(rawKey)
                } else {
                    // RSA/ECDSA: use SecKey path
                    let publicKey = try extractPublicKey(from: certificate)
                    algorithm = detectAlgorithm(from: publicKey)
                    sshPublicKeyData = try convertToSSHPublicKey(publicKey, algorithm: algorithm)
                }

                let fingerprint = generateFingerprint(sshPublicKeyData)

                let discovered = DiscoveredYubiKeyKey(
                    yubiKeySerial: yubiKeySerial,
                    slot: slot,
                    algorithm: algorithm,
                    publicKeyData: sshPublicKeyData,
                    fingerprint: fingerprint,
                    requiresPIN: slot.requiresPIN
                )
                discoveredKeys.append(discovered)

                Self.logger.info("Found PIV key in slot \(slot.rawValue): \(algorithm.rawValue)")

            } catch let error as PIVSessionError {
                // Check if it's a "no certificate" error (slot is empty)
                Self.logger.debug("No key in slot \(slot.rawValue): \(String(describing: error))")
            } catch {
                Self.logger.debug("No key in slot \(slot.rawValue): \(error.localizedDescription)")
            }
        }

        return discoveredKeys
    }

    // MARK: - Import to SSHKeyManager

    /// Import a discovered key into SSHKeyManager
    func importKey(
        _ discovered: DiscoveredYubiKeyKey,
        name: String,
        yubiKeySerial: UInt32
    ) throws -> SSHKey {
        let keyManager = SSHKeyManager.shared

        // Check for duplicate by fingerprint
        if let existing = keyManager.findKey(byFingerprint: discovered.fingerprint) {
            Self.logger.info("YubiKey key already imported as '\(existing.name)' - returning existing key")
            return existing
        }

        let keyType: SSHKey.KeyType = .yubiKeyPIV

        let yubiKeyInfo = YubiKeyInfo(
            serialNumber: yubiKeySerial,
            pivSlot: discovered.slot,
            algorithm: discovered.algorithm,
            lastConnectionMethod: nil,
            deviceName: nil
        )

        var sshKey = SSHKey(
            name: name,
            keyType: keyType,
            fingerprint: discovered.fingerprint,
            hasPassphrase: false,
            storageLevel: .iCloudSync,
            authRequirement: .perUse
        )
        sshKey.yubiKeyInfo = yubiKeyInfo
        sshKey.publicKeyBlob = discovered.publicKeyData

        try keyManager.saveYubiKeyReference(sshKey)

        return sshKey
    }

    // MARK: - Private Helpers

    /// Extract public key from X509Cert
    private func extractPublicKey(from certificate: X509Cert) throws -> SecKey {
        // Create a SecCertificate from the DER data
        guard let secCertificate = SecCertificateCreateWithData(nil, certificate.der as CFData) else {
            throw YubiKeyError.certificateReadFailed("Failed to create SecCertificate from DER data")
        }

        guard let publicKey = SecCertificateCopyKey(secCertificate) else {
            throw YubiKeyError.certificateReadFailed("Failed to extract public key from certificate")
        }

        return publicKey
    }

    private func detectAlgorithm(from publicKey: SecKey) -> YubiKeyAlgorithm {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] else {
            return .ecdsaP256
        }

        let keyType = attributes[kSecAttrKeyType as String] as? String
        let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int ?? 256

        if keyType == kSecAttrKeyTypeRSA as String {
            return keySize >= 4096 ? .rsa4096 : .rsa2048
        } else if keyType == kSecAttrKeyTypeEC as String || keyType == kSecAttrKeyTypeECSECPrimeRandom as String {
            switch keySize {
            case 384: return .ecdsaP384
            case 256: return .ecdsaP256
            default: return .ecdsaP256
            }
        }

        return .ecdsaP256
    }

    /// Detect algorithm from certificate's SubjectPublicKeyInfo OID
    /// This is needed because SecKey doesn't support Ed25519
    private func detectAlgorithmFromCertificate(_ certificate: X509Cert) -> YubiKeyAlgorithm? {
        let der = certificate.der

        // Look for Ed25519 OID (1.3.101.112) = 06 03 2B 65 70
        let ed25519OID: [UInt8] = [0x06, 0x03, 0x2B, 0x65, 0x70]
        if dataContainsSequence(der, ed25519OID) {
            return .ed25519
        }

        return nil
    }

    /// Check if Data contains a byte sequence
    private func dataContainsSequence(_ data: Data, _ sequence: [UInt8]) -> Bool {
        let dataBytes = [UInt8](data)
        guard dataBytes.count >= sequence.count else { return false }

        for i in 0...(dataBytes.count - sequence.count) {
            if Array(dataBytes[i..<i+sequence.count]) == sequence {
                return true
            }
        }
        return false
    }

    /// Extract Ed25519 public key (32 bytes) from certificate DER
    /// Ed25519 SubjectPublicKeyInfo structure:
    /// SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING { 00 + 32-byte key } }
    private func extractEd25519PublicKey(from certificate: X509Cert) throws -> Data {
        let der = [UInt8](certificate.der)

        // Find Ed25519 OID (1.3.101.112) = 06 03 2B 65 70
        let ed25519OID: [UInt8] = [0x06, 0x03, 0x2B, 0x65, 0x70]

        // Search for the OID in the DER data
        var oidIndex: Int?
        for i in 0..<(der.count - ed25519OID.count) {
            if Array(der[i..<i+ed25519OID.count]) == ed25519OID {
                oidIndex = i
                break
            }
        }

        guard let oidStart = oidIndex else {
            throw YubiKeyError.certificateReadFailed("Ed25519 OID not found in certificate")
        }

        // After the OID, we need to find the BIT STRING containing the public key
        // The structure is: SEQUENCE { OID } followed by BIT STRING { 00 + key }
        // Search forward for BIT STRING tag (0x03) followed by length 0x21 (33 = 1 + 32)
        var searchIndex = oidStart + ed25519OID.count

        while searchIndex < der.count - 34 {
            if der[searchIndex] == 0x03 {  // BIT STRING
                let length = der[searchIndex + 1]
                if length == 0x21 && der[searchIndex + 2] == 0x00 {  // 33 bytes, 0 unused bits
                    // Found it - extract 32-byte key
                    let keyStart = searchIndex + 3
                    let keyData = Data(der[keyStart..<keyStart + 32])
                    return keyData
                }
            }
            searchIndex += 1
        }

        throw YubiKeyError.certificateReadFailed("Failed to extract Ed25519 public key from certificate")
    }

    /// Convert Ed25519 raw public key to SSH wire format
    private func convertEd25519ToSSHPublicKey(_ rawKey: Data) -> Data {
        var buffer = Data()
        writeSSHString(&buffer, "ssh-ed25519")
        writeSSHBuffer(&buffer, rawKey)
        return buffer
    }

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

        // Remove leading zeros
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
