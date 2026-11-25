//
//  SSHAgentManager.swift
//  rootshell
//
//  SSH Agent manager implementing the Citadel SSHAgentDelegate protocol
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Citadel
import Combine
import os.log

/// Manages SSH agent forwarding for a specific connection
/// Implements Citadel's SSHAgentDelegate protocol
@MainActor
final class SSHAgentManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHAgentManager")

    /// Configuration for this agent
    let config: SSHAgentConfig

    /// Remote host name (for display in prompts)
    let remoteHost: String

    /// Human-readable session name (e.g., "user@host via jumphost")
    let sessionName: String

    /// Signer for handling key operations
    private let signer: SSHAgentSigner

    /// Key manager for accessing stored keys
    private let keyManager: SSHKeyManager

    /// Set of keys that have been approved for this session
    @Published private(set) var sessionApprovedKeys: Set<UUID> = []

    /// Current pending approval request (if any)
    @Published var pendingApproval: SSHAgentApprovalRequest?

    /// Counter for sign requests (for debugging)
    private var signRequestCount = 0

    /// Publisher for approval requests
    let approvalRequestPublisher = PassthroughSubject<SSHAgentApprovalRequest, Never>()

    init(
        config: SSHAgentConfig,
        remoteHost: String,
        sessionName: String,
        keyManager: SSHKeyManager? = nil
    ) {
        self.config = config
        self.remoteHost = remoteHost
        self.sessionName = sessionName
        let resolvedKeyManager = keyManager ?? .shared
        self.keyManager = resolvedKeyManager
        self.signer = SSHAgentSigner(keyManager: resolvedKeyManager)
    }

    /// Creates a Sendable delegate wrapper for use in Citadel
    func createDelegate() -> SSHAgentDelegateWrapper {
        SSHAgentDelegateWrapper(manager: self)
    }

    // MARK: - Agent Operations

    /// Lists available identities based on configuration
    ///
    /// Uses cached public key blobs when available to avoid triggering biometric
    /// prompts just for listing identities. Only falls back to loading keys
    /// for keys without cached blobs that don't require authentication.
    func listIdentities() async throws -> [SSHAgentIdentity] {
        guard config.enabled else {
            Self.logger.info("Agent forwarding disabled, returning empty list")
            return []
        }

        let availableKeys: [SSHKey]
        if config.forwardedKeyIDs.isEmpty {
            // Forward all keys
            availableKeys = keyManager.savedKeys
        } else {
            // Forward only selected keys
            availableKeys = keyManager.savedKeys.filter { config.forwardedKeyIDs.contains($0.id) }
        }

        Self.logger.info("Listing \(availableKeys.count) identities for agent forwarding")

        var identities: [SSHAgentIdentity] = []
        for var key in availableKeys {
            // Renew a managed certificate silently (never opens UI) so a long
            // forwarded session keeps a usable one, then list the fresh copy.
            if key.hasManagedCertificate {
                _ = try? await ManagedCertificateIdentities.certificateAvailableForPassiveAgentListing(forKeyID: key.id)
                key = keyManager.savedKeys.first(where: { $0.id == key.id }) ?? key
            }

            // First, try to use cached public key blob (no Keychain access needed)
            if let cachedBlob = key.publicKeyBlob {
                Self.logger.info("Using cached blob for identity: \(key.name)")
                identities.append(SSHAgentIdentity(
                    publicKeyBlob: ByteBuffer(data: cachedBlob),
                    comment: key.name
                ))
                appendCertificateIdentity(for: key, to: &identities)
                continue
            }

            // No cached blob - only load if the key doesn't require auth
            // (to avoid biometric prompts just for listing)
            guard key.authRequirement == .none else {
                Self.logger.warning("Skipping auth-protected key without cached blob: \(key.name)")
                continue
            }

            // Load the key to generate its blob
            do {
                let keyVariant = try await keyManager.loadPrivateKey(id: key.id)
                let publicKeyBlob = generatePublicKeyBlob(from: keyVariant, keyType: key.keyType)
                identities.append(SSHAgentIdentity(
                    publicKeyBlob: publicKeyBlob,
                    comment: key.name
                ))
                appendCertificateIdentity(for: key, to: &identities)
            } catch {
                Self.logger.warning("Failed to load key \(key.name) for identity listing: \(error.localizedDescription)")
            }
        }

        return identities
    }

    /// Lists the key's user certificate as an additional agent identity, matching
    /// ssh-agent behavior (a certified key appears as both the plain key and the
    /// certificate). The remote `ssh` picks whichever the server wants.
    private func appendCertificateIdentity(for key: SSHKey, to identities: inout [SSHAgentIdentity]) {
        // A stale certificate is a guaranteed server-side reject.
        guard let cert = key.userCertificate, !cert.isExpired, !cert.isNotYetValid else { return }
        Self.logger.info("Adding certificate identity for: \(key.name)")
        identities.append(SSHAgentIdentity(
            publicKeyBlob: ByteBuffer(data: cert.certificateBlob),
            comment: "\(key.name) cert"
        ))
    }

    /// Signs data with a specific key, handling approval based on configuration
    ///
    /// The flow is optimized to minimize user prompts:
    /// 1. First, match the key using cached blobs (no biometric needed)
    /// 2. If approval is needed, show the approval dialog
    /// 3. Only after approval, trigger biometric auth if required
    ///
    /// This ensures users see at most ONE prompt for a single sign action.
    func sign(
        publicKeyBlob: ByteBuffer,
        data: ByteBuffer,
        flags: UInt32
    ) async throws -> ByteBuffer? {
        signRequestCount += 1
        let requestNum = signRequestCount
        let host = remoteHost
        Self.logger.info("Sign request #\(requestNum) received for host: \(host)")

        guard config.enabled else {
            Self.logger.warning("Sign request #\(requestNum): Agent forwarding disabled, rejecting")
            return nil
        }

        // Step 1: Find matching key WITHOUT authentication (just identify which key)
        guard let keyMeta = signer.findKeyMetadata(publicKeyBlob: publicKeyBlob) else {
            Self.logger.warning("Sign request #\(requestNum): Unknown key, rejecting")
            return nil
        }

        Self.logger.info("Sign request #\(requestNum): Matched key '\(keyMeta.name)' (auth: \(keyMeta.authRequirement.rawValue))")

        // Check if key is in the forwarded set
        if !config.forwardedKeyIDs.isEmpty && !config.forwardedKeyIDs.contains(keyMeta.id) {
            Self.logger.warning("Sign request for non-forwarded key \(keyMeta.name), rejecting")
            return nil
        }

        // Step 2: Handle agent approval based on mode (BEFORE biometric)
        let needsApproval: Bool
        switch config.approvalMode {
        case .autoApprove:
            Self.logger.info("Auto-approving sign request for key: \(keyMeta.name)")
            needsApproval = false

        case .sessionApprove:
            if sessionApprovedKeys.contains(keyMeta.id) {
                Self.logger.info("Session-approved sign request for key: \(keyMeta.name)")
                needsApproval = false
            } else {
                needsApproval = true
            }

        case .perRequest:
            needsApproval = true
        }

        if needsApproval {
            let approved = await requestApproval(for: keyMeta)
            guard approved else {
                Self.logger.info("Sign request denied for key: \(keyMeta.name)")
                return nil
            }
            if config.approvalMode == .sessionApprove {
                sessionApprovedKeys.insert(keyMeta.id)
            }
        }

        // Step 3: Now load the key with authentication (biometric prompt if required)
        let keyVariant: SSHPrivateKeyVariant
        do {
            if keyMeta.yubiKeyInfo != nil {
                // YubiKey: create reference variant (auth handled by hardware)
                keyVariant = try await keyManager.loadPrivateKey(id: keyMeta.id)
            } else if keyMeta.authRequirement == .none {
                keyVariant = try await keyManager.loadPrivateKey(id: keyMeta.id)
            } else {
                keyVariant = try await keyManager.loadPrivateKeyWithAuth(id: keyMeta.id)
            }
        } catch let error as SSHKeyManager.LoadError {
            switch error {
            case .authenticationCancelled:
                Self.logger.info("Key authentication cancelled by user")
                return nil
            case .authenticationFailed:
                Self.logger.warning("Key authentication failed")
                return nil
            default:
                throw error
            }
        }

        // Step 4: Perform the signing (use async for YubiKey support)
        do {
            let signature = try await signer.signAsync(
                keyVariant: keyVariant,
                keyType: keyMeta.keyType,
                data: data,
                flags: flags
            )
            Self.logger.info("Sign request #\(requestNum): SUCCESS with key '\(keyMeta.name)'")
            return signature
        } catch {
            Self.logger.error("Sign request #\(requestNum): FAILED - \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Approval UI

    private func requestApproval(for key: SSHKey) async -> Bool {
        return await withCheckedContinuation { continuation in
            let request = SSHAgentApprovalRequest(
                keyName: key.name,
                fingerprint: key.formattedFingerprint,
                remoteHost: remoteHost,
                sessionName: sessionName,
                completion: { approved in
                    continuation.resume(returning: approved)
                }
            )

            // Dispatch to main actor for UI update
            Task { @MainActor in
                self.pendingApproval = request
                self.approvalRequestPublisher.send(request)
            }
        }
    }

    /// Called by UI when user responds to approval request
    func respondToApproval(_ approved: Bool) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        request.completion(approved)
    }

    // MARK: - Public Key Blob Generation

    private func generatePublicKeyBlob(from keyVariant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)

        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            // Use the OpenSSH format to get the public key blob
            let openSSHString = String(openSSHPublicKey: nioKey.publicKey)
            let components = openSSHString.split(separator: " ", maxSplits: 1)
            if components.count >= 2,
               let keyData = Data(base64Encoded: String(components[1])) {
                buffer.writeBytes(keyData)
            }

        case .rsa(let rsaKey):
            // RSA: "ssh-rsa" + e (mpint) + n (mpint)
            // Write key type prefix
            let keyTypeData = "ssh-rsa".data(using: .utf8)!
            buffer.writeInteger(UInt32(keyTypeData.count))
            buffer.writeBytes(keyTypeData)
            // Write public key components (e, n) using the publicKey's write method
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
}

// MARK: - Sendable Delegate Wrapper

/// A Sendable wrapper around SSHAgentManager for use in Citadel's callbacks
/// This bridges the MainActor-isolated SSHAgentManager to the SSHAgentDelegate protocol
public final class SSHAgentDelegateWrapper: SSHAgentDelegate, @unchecked Sendable {
    private let manager: SSHAgentManager

    init(manager: SSHAgentManager) {
        self.manager = manager
    }

    public func listIdentities() async throws -> [SSHAgentIdentity] {
        await MainActor.run {
            // Can't directly call async method here, need to use a detached task
        }
        // Use a task to bridge to MainActor
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let identities = try await self.manager.listIdentities()
                    continuation.resume(returning: identities)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sign(
        publicKeyBlob: ByteBuffer,
        data: ByteBuffer,
        flags: UInt32
    ) async throws -> ByteBuffer? {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let signature = try await self.manager.sign(
                        publicKeyBlob: publicKeyBlob,
                        data: data,
                        flags: flags
                    )
                    continuation.resume(returning: signature)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
