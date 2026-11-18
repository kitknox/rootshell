//
//  SSHAgentSigner.swift
//  rootshell
//
//  Handles SSH agent signing operations for agent forwarding
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Crypto
import Citadel
import os.log

/// Handles SSH agent signing operations
/// Matches public key blobs to stored keys and performs signing operations
@MainActor
class SSHAgentSigner {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHAgentSigner")

    private let keyManager: SSHKeyManager

    init(keyManager: SSHKeyManager? = nil) {
        self.keyManager = keyManager ?? .shared
    }

    /// Find a key by its public key blob (sync version, no authentication)
    /// - Parameter publicKeyBlob: SSH wire-format public key blob
    /// - Returns: Tuple of (SSHKey metadata, loaded private key variant) if found
    func findKey(publicKeyBlob: ByteBuffer) -> (SSHKey, SSHPrivateKeyVariant)? {
        // Parse the key type from the blob to help with matching
        var blob = publicKeyBlob
        guard let keyTypeString = readSSHString(&blob) else {
            Self.logger.error("Failed to parse key type from public key blob")
            return nil
        }

        Self.logger.info("Looking for key with type: \(keyTypeString)")

        // Try to match against each saved key
        for savedKey in keyManager.savedKeys {
            // A certificate identity blob matches via the stored cert (metadata, no Keychain)
            if certificateBlobMatches(publicKeyBlob, key: savedKey) {
                do {
                    let keyVariant = try keyManager.loadPrivateKey(id: savedKey.id)
                    Self.logger.info("Found matching key via certificate blob: \(savedKey.name)")
                    return (savedKey, keyVariant)
                } catch {
                    Self.logger.warning("Failed to load key \(savedKey.name): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                let keyVariant = try keyManager.loadPrivateKey(id: savedKey.id)

                // Generate public key blob for this key and compare
                let generatedBlob = generatePublicKeyBlob(from: keyVariant, keyType: savedKey.keyType)

                if comparePublicKeyBlobs(publicKeyBlob, generatedBlob) {
                    Self.logger.info("Found matching key: \(savedKey.name)")
                    return (savedKey, keyVariant)
                }
            } catch {
                Self.logger.warning("Failed to load key \(savedKey.name): \(error.localizedDescription)")
                continue
            }
        }

        Self.logger.warning("No matching key found for blob")
        return nil
    }

    /// Whether the incoming agent blob is the key's stored user certificate.
    /// Cert identities are listed alongside plain keys (see SSHAgentManager); when a
    /// remote `ssh` selects the cert identity, the sign request carries the cert blob.
    /// Signing is unchanged — the signature uses the plain key algorithm per
    /// PROTOCOL.certkeys; only the matching differs.
    private func certificateBlobMatches(_ incoming: ByteBuffer, key: SSHKey) -> Bool {
        guard let certBlob = key.userCertificate?.certificateBlob else { return false }
        return comparePublicKeyBlobs(incoming, ByteBuffer(data: certBlob))
    }

    /// Find key metadata by its public key blob WITHOUT loading the key
    /// - Parameter publicKeyBlob: SSH wire-format public key blob
    /// - Returns: SSHKey metadata if found, nil otherwise
    ///
    /// This method only uses cached public key blobs for matching - it never
    /// accesses the Keychain, so it will never trigger biometric prompts.
    /// Used by SSHAgentManager to identify the key before deciding on approval.
    func findKeyMetadata(publicKeyBlob: ByteBuffer) -> SSHKey? {
        // Parse the key type from the blob to help with matching
        var blob = publicKeyBlob
        guard let keyTypeString = readSSHString(&blob) else {
            Self.logger.error("Failed to parse key type from public key blob")
            return nil
        }

        Self.logger.info("Looking for key metadata with type: \(keyTypeString)")

        // Try to match using cached public key blobs (no Keychain access)
        for savedKey in keyManager.savedKeys {
            if certificateBlobMatches(publicKeyBlob, key: savedKey) {
                Self.logger.info("Found matching key via certificate blob: \(savedKey.name)")
                return savedKey
            }
            if let cachedBlob = savedKey.publicKeyBlob {
                let cachedBuffer = ByteBuffer(data: cachedBlob)
                if comparePublicKeyBlobs(publicKeyBlob, cachedBuffer) {
                    Self.logger.info("Found matching key via cached blob: \(savedKey.name)")
                    return savedKey
                }
            }
        }

        // Fallback for keys without cached blobs that don't require auth
        for savedKey in keyManager.savedKeys {
            guard savedKey.publicKeyBlob == nil else { continue }
            guard savedKey.authRequirement == .none else { continue }

            do {
                let keyVariant = try keyManager.loadPrivateKey(id: savedKey.id)
                let generatedBlob = generatePublicKeyBlob(from: keyVariant, keyType: savedKey.keyType)

                if comparePublicKeyBlobs(publicKeyBlob, generatedBlob) {
                    Self.logger.info("Found matching key via loading: \(savedKey.name)")
                    return savedKey
                }
            } catch {
                Self.logger.warning("Failed to load key \(savedKey.name) for matching: \(error.localizedDescription)")
                continue
            }
        }

        Self.logger.warning("No matching key found for blob")
        return nil
    }

    /// Find a key by its public key blob with authentication support
    /// - Parameter publicKeyBlob: SSH wire-format public key blob
    /// - Returns: Tuple of (SSHKey metadata, loaded private key variant) if found
    /// - Throws: Error if authentication fails or is cancelled
    ///
    /// This method first tries to match using cached public key blobs (no Keychain access needed),
    /// then only loads the private key with authentication for the matched key - ensuring only
    /// one biometric prompt per signing request.
    func findKeyWithAuth(publicKeyBlob: ByteBuffer) async throws -> (SSHKey, SSHPrivateKeyVariant)? {
        // Parse the key type from the blob to help with matching
        var blob = publicKeyBlob
        guard let keyTypeString = readSSHString(&blob) else {
            Self.logger.error("Failed to parse key type from public key blob")
            return nil
        }

        Self.logger.info("Looking for key with type: \(keyTypeString) (with auth)")

        // First, try to match using cached public key blobs (no Keychain access = no biometric prompt)
        var matchingKey: SSHKey?

        for savedKey in keyManager.savedKeys {
            if certificateBlobMatches(publicKeyBlob, key: savedKey) {
                Self.logger.info("Found matching key via certificate blob: \(savedKey.name)")
                matchingKey = savedKey
                break
            }
            // Use cached public key blob if available
            if let cachedBlob = savedKey.publicKeyBlob {
                let cachedBuffer = ByteBuffer(data: cachedBlob)
                if comparePublicKeyBlobs(publicKeyBlob, cachedBuffer) {
                    Self.logger.info("Found matching key via cached blob: \(savedKey.name)")
                    matchingKey = savedKey
                    break
                }
            }
        }

        // If no cached blob match, fall back to loading keys without auth (for old keys without cached blobs)
        // This path may trigger biometric if the key has auth requirement
        if matchingKey == nil {
            Self.logger.info("No cached blob match, falling back to key loading for comparison")
            for savedKey in keyManager.savedKeys {
                // Skip keys that already have cached blobs (we already checked them)
                guard savedKey.publicKeyBlob == nil else { continue }

                do {
                    let keyVariant = try await keyManager.loadPrivateKey(id: savedKey.id)
                    let generatedBlob = generatePublicKeyBlob(from: keyVariant, keyType: savedKey.keyType)

                    if comparePublicKeyBlobs(publicKeyBlob, generatedBlob) {
                        Self.logger.info("Found matching key via loading: \(savedKey.name)")
                        // If no auth required, return immediately with the already-loaded key
                        if savedKey.authRequirement == .none {
                            return (savedKey, keyVariant)
                        }
                        matchingKey = savedKey
                        break
                    }
                } catch {
                    Self.logger.warning("Failed to load key \(savedKey.name) for matching: \(error.localizedDescription)")
                    continue
                }
            }
        }

        // If we found a matching key, load it (with auth if required)
        if let key = matchingKey {
            // If no auth required, use the simple load path
            if key.authRequirement == .none {
                Self.logger.info("Loading matched key (no auth required): \(key.name)")
                let keyVariant = try await keyManager.loadPrivateKey(id: key.id)
                return (key, keyVariant)
            }

            // Auth required - this is the ONLY biometric prompt for this signing request
            Self.logger.info("Loading matched key with auth: \(key.name)")
            let keyVariant = try await keyManager.loadPrivateKeyWithAuth(id: key.id)
            return (key, keyVariant)
        }

        Self.logger.warning("No matching key found for blob")
        return nil
    }

    /// Sign data using the provided key variant (synchronous - not for YubiKey)
    /// - Parameters:
    ///   - keyVariant: The private key to use for signing
    ///   - keyType: The type of key (for algorithm selection)
    ///   - data: The data to sign
    ///   - flags: Signature flags (used for RSA algorithm selection)
    /// - Returns: The signature in SSH wire format
    /// - Note: For YubiKey keys, use signAsync() instead
    func sign(
        keyVariant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        data: ByteBuffer,
        flags: UInt32
    ) throws -> ByteBuffer {
        let dataBytes = Data(buffer: data)

        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            return try signWithNIOSSH(key: nioKey, keyType: keyType, data: dataBytes, flags: flags)
        case .rsa(let rsaKey):
            return try signWithRSA(key: rsaKey, data: dataBytes, flags: flags)
        case .yubiKey:
            // YubiKey requires async signing - caller should use signAsync()
            fatalError("Use signAsync() for YubiKey signing operations")
        case .appleFIDO2:
            // Apple FIDO2 requires async signing - caller should use signAsync()
            fatalError("Use signAsync() for Apple FIDO2 signing operations")
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent:
            // Agent round-trip can wait out an approval dialog - never on MainActor
            fatalError("Use signAsync() for external agent signing operations")
        #endif
        }
    }

    /// Sign data using the provided key variant (async - supports YubiKey)
    /// - Parameters:
    ///   - keyVariant: The private key to use for signing
    ///   - keyType: The type of key (for algorithm selection)
    ///   - data: The data to sign
    ///   - flags: Signature flags (used for RSA algorithm selection)
    /// - Returns: The signature in SSH wire format
    func signAsync(
        keyVariant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        data: ByteBuffer,
        flags: UInt32
    ) async throws -> ByteBuffer {
        let dataBytes = Data(buffer: data)

        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            return try signWithNIOSSH(key: nioKey, keyType: keyType, data: dataBytes, flags: flags)
        case .rsa(let rsaKey):
            return try signWithRSA(key: rsaKey, data: dataBytes, flags: flags)
        case .yubiKey(let reference):
            return try await signWithYubiKey(reference: reference, data: dataBytes, flags: flags)
        case .appleFIDO2(let reference):
            return try await signWithAppleFIDO2(reference: reference, data: dataBytes, flags: flags)
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent(let reference):
            return try await signWithExternalAgent(reference: reference, data: dataBytes, flags: flags)
        #endif
        }
    }

    #if targetEnvironment(macCatalyst) && STANDALONE
    // MARK: - External Agent Signing

    /// Round-trips the sign request to the external agent. Flags are
    /// forwarded verbatim (a forwarded remote client may ask for
    /// rsa-sha2-512), and the agent's response blob is already the exact
    /// SSH wire signature (string algorithm + string signature), so it is
    /// returned untouched.
    private func signWithExternalAgent(
        reference: ExternalAgentKeyReference,
        data: Data,
        flags: UInt32
    ) async throws -> ByteBuffer {
        Self.logger.info("Signing via external agent (\(reference.algorithm))")
        let blob = try await Task.detached(priority: .userInitiated) {
            try ExternalSSHAgentClient(socketPath: reference.socketPath).sign(
                keyBlob: reference.publicKeyBlob,
                data: data,
                flags: flags
            )
        }.value
        return ByteBuffer(data: blob)
    }
    #endif

    // MARK: - Apple FIDO2 Signing

    private func signWithAppleFIDO2(
        reference: AppleFIDO2Reference,
        data: Data,
        flags: UInt32
    ) async throws -> ByteBuffer {
        Self.logger.info("Signing with Apple FIDO2 credential")

        // Create signer and perform signing
        let signer = AppleFIDO2Signer()
        let result = try await signer.signSSHData(
            credentialID: reference.credentialID,
            backing: reference.backing,
            sessionData: data
        )

        let signature = AppleFIDO2ECDSASKP256Signature(
            flags: result.flags,
            counter: result.counter,
            signatureData: result.sshSignatureData,
            origin: result.origin,
            clientDataJSON: result.clientDataJSON
        )

        // SSH agents return the signature algorithm followed by the encoded
        // signature body. Use the same WebAuthn representation as direct
        // NIOSSH authentication.
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        writeSSHString(&buffer, AppleFIDO2ECDSASKP256Signature.signaturePrefix)

        var signatureBuffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = signature.write(to: &signatureBuffer)
        writeSSHBuffer(&buffer, signatureBuffer)

        Self.logger.info("Apple FIDO2 signature: \(buffer.readableBytes) bytes")
        return buffer
    }

    // MARK: - YubiKey Signing

    private func signWithYubiKey(
        reference: YubiKeyReference,
        data: Data,
        flags: UInt32
    ) async throws -> ByteBuffer {
        // The shared signer: its queue and PIN prompt serialise agent requests
        // with direct SSH signing.
        let signer = YubiKeySigner.shared

        // YubiKey PIV signing only - FIDO2 is handled via Apple AuthenticationServices
        guard let slot = reference.pivSlot else {
            throw YubiKeyError.keyNotFound(slot: .authentication)
        }

        Self.logger.info("Signing with YubiKey PIV slot \(slot.rawValue)")
        return try await signer.signWithPIV(
            serialNumber: reference.serialNumber,
            slot: slot,
            algorithm: reference.algorithm,
            data: data,
            flags: flags
        )
    }

    // MARK: - Private Signing Methods

    private func signWithNIOSSH(
        key: NIOSSHPrivateKey,
        keyType: SSHKey.KeyType,
        data: Data,
        flags: UInt32
    ) throws -> ByteBuffer {
        // Get the signature using NIOSSHPrivateKey's signature method
        let signature = try key.signature(for: data)

        // Write the signature in SSH wire format
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        buffer.writeSSHSignature(signature)

        let algorithmName = getSignatureAlgorithmName(keyType: keyType, flags: flags)
        Self.logger.info("Signed with \(algorithmName), signature: \(buffer.readableBytes) bytes")
        return buffer
    }

    private func signWithRSA(key: Insecure.RSA.PrivateKey, data: Data, flags: UInt32) throws -> ByteBuffer {
        // Determine algorithm based on flags
        // SSH_AGENT_RSA_SHA2_512 = 4, SSH_AGENT_RSA_SHA2_256 = 2
        let algorithmName: String
        let hashAlgorithm: Insecure.RSA.PrivateKey.HashAlgorithm

        if flags & 4 != 0 {
            algorithmName = "rsa-sha2-512"
            hashAlgorithm = .sha512
        } else {
            algorithmName = "rsa-sha2-256"
            hashAlgorithm = .sha256
        }

        // Sign using the appropriate hash algorithm
        let signatureResult = try key.signature(for: data, hashAlgorithm: hashAlgorithm)

        // Wrap in SSH signature format
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        writeSSHString(&buffer, algorithmName)
        writeSSHBuffer(&buffer, ByteBuffer(data: signatureResult.rawRepresentation))

        Self.logger.info("Signed with \(algorithmName), signature: \(buffer.readableBytes) bytes")
        return buffer
    }

    // MARK: - Public Key Blob Generation

    /// Generates a public key blob in SSH wire format
    /// This is used both for agent identity listing and for caching in key metadata
    func generatePublicKeyBlob(from keyVariant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)

        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            // Preserve the actual wire type, including legacy hybrid keys.
            if keyType == .mldsa44Ed25519 {
                let exported = String(openSSHPublicKey: nioKey.publicKey)
                if let encoded = exported.split(separator: " ").dropFirst().first,
                   let bytes = Data(base64Encoded: String(encoded)) {
                    buffer.writeBytes(bytes)
                }
                return buffer
            }
            // Use NIOSSHPublicKey's write method
            let publicKey = nioKey.publicKey

            // Get the key type prefix
            let keyTypeString = getKeyTypeString(keyType: keyType)
            writeSSHString(&buffer, keyTypeString)

            // Write public key data based on type
            switch keyType {
            case .ed25519:
                // Ed25519: just the raw 32-byte public key
                if let publicData = extractEd25519PublicKey(publicKey) {
                    writeSSHBuffer(&buffer, ByteBuffer(data: publicData))
                }
            case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
                // ML-DSA blobs are one SSH string of raw key bytes. The
                // extractor is format-agnostic (skips the name, returns the
                // next SSH string), which is exactly this layout.
                if let publicData = extractEd25519PublicKey(publicKey) {
                    writeSSHBuffer(&buffer, ByteBuffer(data: publicData))
                }
            case .ecdsaP256, .ecdsaP384, .ecdsaP521, .secureEnclaveP256:
                // ECDSA (incl. Secure Enclave P-256): curve identifier + point
                let curveId = getECDSACurveIdentifier(keyType: keyType)
                writeSSHString(&buffer, curveId)
                if let publicData = extractECDSAPublicKey(publicKey) {
                    writeSSHBuffer(&buffer, ByteBuffer(data: publicData))
                }
            case .rsa:
                break  // Should not happen for nioSSH keys
            case .yubiKeyPIV, .yubiKeyFIDO2:
                break  // Should not happen for nioSSH keys
            case .appleFIDO2:
                break  // Should not happen for nioSSH keys
            case .applePasskey:
                break  // Should not happen for nioSSH keys
            case .externalAgent:
                break  // Should not happen for nioSSH keys
            }

        case .rsa(let rsaKey):
            // RSA: "ssh-rsa" + e (mpint) + n (mpint)
            writeSSHString(&buffer, "ssh-rsa")
            // Use the public key's write method to get e and n in SSH format
            _ = rsaKey.publicKey.write(to: &buffer)

        case .yubiKey(let reference):
            // YubiKey: use the cached public key blob directly
            buffer.writeBytes(reference.publicKeyBlob)

        case .appleFIDO2(let reference):
            // Apple FIDO2: use the cached public key blob directly
            buffer.writeBytes(reference.publicKeyBlob)
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent(let reference):
            // External agent: use the agent-provided public key blob directly
            buffer.writeBytes(reference.publicKeyBlob)
        #endif
        }

        return buffer
    }

    private func comparePublicKeyBlobs(_ blob1: ByteBuffer, _ blob2: ByteBuffer) -> Bool {
        guard blob1.readableBytes == blob2.readableBytes else {
            return false
        }

        let data1 = blob1.getData(at: blob1.readerIndex, length: blob1.readableBytes) ?? Data()
        let data2 = blob2.getData(at: blob2.readerIndex, length: blob2.readableBytes) ?? Data()

        return data1 == data2
    }

    // MARK: - SSH Wire Format Helpers

    private func getKeyTypeString(keyType: SSHKey.KeyType) -> String {
        switch keyType {
        case .rsa: return "ssh-rsa"
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        case .yubiKeyPIV: return "ssh-rsa"  // PIV uses standard algorithms
        case .yubiKeyFIDO2: return "sk-ssh-ed25519@openssh.com"  // FIDO2 SK format
        case .appleFIDO2: return "sk-ecdsa-sha2-nistp256@openssh.com"  // Apple FIDO2 SK format
        case .applePasskey: return "sk-ecdsa-sha2-nistp256@openssh.com"
        case .secureEnclaveP256: return "ecdsa-sha2-nistp256"  // Standard ECDSA P-256 from the Secure Enclave
        case .externalAgent: return "ssh-ed25519"  // Placeholder; agent keys always use their cached blob
        case .mldsa44Ed25519: return MLDSA44Ed25519SSH.algorithmName
        case .mldsa44: return "ssh-mldsa44"
        case .mldsa65: return "ssh-mldsa65"
        case .mldsa87: return "ssh-mldsa87"
        }
    }

    private func getSignatureAlgorithmName(keyType: SSHKey.KeyType, flags: UInt32) -> String {
        switch keyType {
        case .rsa, .yubiKeyPIV:
            if flags & 4 != 0 { return "rsa-sha2-512" }
            if flags & 2 != 0 { return "rsa-sha2-256" }
            return "rsa-sha2-256"
        case .ed25519:
            return "ssh-ed25519"
        case .ecdsaP256:
            return "ecdsa-sha2-nistp256"
        case .ecdsaP384:
            return "ecdsa-sha2-nistp384"
        case .ecdsaP521:
            return "ecdsa-sha2-nistp521"
        case .yubiKeyFIDO2:
            return "sk-ssh-ed25519@openssh.com"
        case .appleFIDO2, .applePasskey:
            return "sk-ecdsa-sha2-nistp256@openssh.com"
        case .secureEnclaveP256:
            return "ecdsa-sha2-nistp256"
        case .externalAgent:
            return "ssh-agent"  // Logging only; the agent's blob carries the real algorithm
        case .mldsa44Ed25519:
            return MLDSA44Ed25519SSH.algorithmName
        case .mldsa44:
            return "ssh-mldsa44"
        case .mldsa65:
            return "ssh-mldsa65"
        case .mldsa87:
            return "ssh-mldsa87"
        }
    }

    private func getECDSACurveIdentifier(keyType: SSHKey.KeyType) -> String {
        switch keyType {
        case .ecdsaP256, .secureEnclaveP256: return "nistp256"
        case .ecdsaP384: return "nistp384"
        case .ecdsaP521: return "nistp521"
        default: return ""
        }
    }

    private func extractEd25519PublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        // NIOSSHPublicKey doesn't expose the raw bytes directly
        // We need to use the OpenSSH string format and extract the key
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            return nil
        }

        // Parse the SSH blob to extract just the public key bytes
        var buffer = ByteBuffer(data: keyData)
        _ = readSSHString(&buffer)  // Skip key type
        guard let pubKeyBuffer = readSSHBuffer(&buffer) else {
            return nil
        }
        return pubKeyBuffer.getData(at: pubKeyBuffer.readerIndex, length: pubKeyBuffer.readableBytes)
    }

    private func extractECDSAPublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            return nil
        }

        var buffer = ByteBuffer(data: keyData)
        _ = readSSHString(&buffer)  // Skip key type
        _ = readSSHString(&buffer)  // Skip curve identifier
        guard let pubKeyBuffer = readSSHBuffer(&buffer) else {
            return nil
        }
        return pubKeyBuffer.getData(at: pubKeyBuffer.readerIndex, length: pubKeyBuffer.readableBytes)
    }

    // MARK: - SSH String/Buffer Read/Write

    private func readSSHString(_ buffer: inout ByteBuffer) -> String? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readBytes(length: Int(length)),
              let string = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func readSSHBuffer(_ buffer: inout ByteBuffer) -> ByteBuffer? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let slice = buffer.readSlice(length: Int(length)) else {
            return nil
        }
        return slice
    }

    private func writeSSHString(_ buffer: inout ByteBuffer, _ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
    }

    private func writeSSHBuffer(_ buffer: inout ByteBuffer, _ data: ByteBuffer) {
        var dataCopy = data
        buffer.writeInteger(UInt32(dataCopy.readableBytes))
        buffer.writeBuffer(&dataCopy)
    }
}
