import Foundation
import NIOSSH
import NIOCore
import NIOFoundationCompat
import Crypto
import os.log

/// Validation scenario for host key verification
enum HostKeyValidationScenario: Equatable {
    case newHost
    case keyChanged(oldFingerprint: String)
}

/// Request for user validation of a host key
struct HostKeyValidationRequest: Sendable {
    let hostname: String
    let port: Int
    let keyType: String
    let fingerprint: String
    let publicKeyData: String
    /// The saved fingerprint this request was classified against; nil for a
    /// new host.
    let previouslyTrusted: String?
    /// Prefixes the message (the connection hop's label).
    var label: String? = nil
    /// Appended to the message (the SSHFP verdict).
    var note: String? = nil

    var isKeyChanged: Bool { previouslyTrusted != nil }

    var message: String {
        let prefix = label.map { "\($0)\n" } ?? ""
        let suffix = note.map { "\n\n\($0)" } ?? ""
        let body: String
        if let previouslyTrusted {
            body = "The host key for \(hostname):\(port) has changed. " +
                "This could indicate a man-in-the-middle attack!\n\n" +
                "Previously Trusted:\n\(previouslyTrusted)\n\n" +
                "New Key Received:\n\(fingerprint)"
        } else {
            body = "Do you want to trust this host?\n\n" +
                "Host: \(hostname):\(port)\n" +
                "Key Type: \(keyType)\n\n" +
                "Fingerprint:\n\(fingerprint)"
        }
        return prefix + body + suffix
    }

    enum Recheck {
        /// Saved, or approved with Connect Once, since the request was made.
        case trusted
        /// Still classified as it was.
        case current
        /// The saved key changed (or was removed) since the request was made.
        case reclassified(HostKeyValidationRequest)
    }

    /// For a prompt that waited behind another: that prompt may have saved
    /// this key, or a different one for the same host. `honoringConnectOnce`
    /// is false for a prompt re-asked after the user chose to save, which
    /// must still offer the replacement.
    @MainActor
    func recheck(honoringConnectOnce: Bool = true) -> Recheck {
        let known = KnownHostsManager.shared.getHost(hostname: hostname, port: port)
        if let known, known.fingerprint == fingerprint || known.publicKeyData == publicKeyData {
            return .trusted
        }
        if honoringConnectOnce,
           SessionApprovedHostKeys.shared.matches(hostname: hostname, port: port, publicKeyData: publicKeyData) {
            return .trusted
        }
        return savedKeyChange().map { .reclassified($0) } ?? .current
    }

    /// Saved trust only, ignoring Connect Once approvals: the request updated
    /// to warn against the currently saved key when that is no longer the one
    /// the prompt showed, or nil when the prompt is still accurate.
    @MainActor
    func savedKeyChange() -> HostKeyValidationRequest? {
        let known = KnownHostsManager.shared.getHost(hostname: hostname, port: port)
        if let known, known.fingerprint == fingerprint || known.publicKeyData == publicKeyData {
            return nil
        }
        guard known?.fingerprint != previouslyTrusted else { return nil }
        return HostKeyValidationRequest(
            hostname: hostname,
            port: port,
            keyType: keyType,
            fingerprint: fingerprint,
            publicKeyData: publicKeyData,
            previouslyTrusted: known?.fingerprint,
            label: label,
            note: note)
    }
}

/// User's response to host key validation
enum HostKeyValidationResult {
    case accept          // Accept and save to known hosts
    case acceptOnce      // Accept for this session only (don't save)
    case reject          // Reject the connection
    /// Accept with nothing left to record: the prompt already recorded the
    /// decision, or the key was already trusted.
    case accepted
}

extension HostKeyValidationRequest {
    /// Saves the key for `.accept`; remembers it for this run for `.acceptOnce`.
    @MainActor
    func record(_ result: HostKeyValidationResult, in manager: KnownHostsManager = .shared) {
        switch result {
        case .accept:
            manager.addHost(KnownHost(
                hostname: hostname,
                port: port,
                publicKeyData: publicKeyData,
                keyType: keyType,
                fingerprint: fingerprint))
        case .acceptOnce:
            SessionApprovedHostKeys.shared.remember(hostname: hostname, port: port, publicKeyData: publicKeyData)
        case .reject, .accepted:
            break
        }
    }
}

/// Custom SSH server authentication delegate that validates host keys against known hosts
/// Marked nonisolated and @unchecked Sendable because NIO requires access from any thread.
/// All MainActor interactions are handled internally via Task { @MainActor in ... }.
nonisolated final class SSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostname: String
    private let port: Int
    private let manager: KnownHostsManager
    private nonisolated(unsafe) let onValidationRequired: (HostKeyValidationRequest) async -> HostKeyValidationResult
    private let logger = Logger(subsystem: "com.rootshell", category: "SSHHostKey")
    private let timeoutCoordinator: SSHTimeoutCoordinator?

    init(
        hostname: String,
        port: Int,
        manager: KnownHostsManager,
        timeoutCoordinator: SSHTimeoutCoordinator? = nil,
        onValidationRequired: @escaping (HostKeyValidationRequest) async -> HostKeyValidationResult
    ) {
        self.hostname = hostname
        self.port = port
        self.manager = manager
        self.timeoutCoordinator = timeoutCoordinator
        self.onValidationRequired = onValidationRequired
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        Task { @MainActor in
            do {
                let result = try await performValidation(hostKey: hostKey)
                if result {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(HostKeyRejectedError())
                }
            } catch {
                logger.error("Host key validation failed: \(error.localizedDescription)")
                validationCompletePromise.fail(error)
            }
        }
    }

    /// Request user validation with timeout pause/resume
    @MainActor
    private func requestUserValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        // Pause the handshake timeout while waiting for user
        timeoutCoordinator?.pauseTimeout(remainingTime: SSHTimeoutConfig.handshakeTimeout)

        let result = await onValidationRequired(request)

        // Resume the timeout after user responds
        timeoutCoordinator?.resumeTimeout()

        return result
    }

    @MainActor
    private func performValidation(hostKey: NIOSSHPublicKey) async throws -> Bool {
        // Generate fingerprint and key info
        // Force proper String copies to avoid memory corruption
        let fingerprint = String(generateFingerprint(for: hostKey))
        let keyType = String(getKeyType(from: hostKey))
        let publicKeyData = try serializePublicKey(hostKey)
        let hostnameCopy = String(hostname)
        let portCopy = port

        logger.info("Validating host key for \(hostnameCopy):\(portCopy) - Type: \(keyType), Fingerprint: \(fingerprint)")
        SSHDebugLogger.shared.event(
            "HOSTKEY",
            "validating host=\(hostnameCopy):\(portCopy) type=\(keyType) fingerprint=\(fingerprint)"
        )

        // Check if we have a known host entry
        if let knownHost = manager.getHost(hostname: hostname, port: port) {
            // Compare fingerprints for robustness (survives serialization format changes)
            // Also compare publicKeyData as a fallback for older entries
            let fingerprintsMatch = knownHost.fingerprint == fingerprint
            let publicKeyDataMatches = knownHost.publicKeyData == publicKeyData

            if fingerprintsMatch || publicKeyDataMatches {
                // Key matches - update last seen and accept
                logger.info("Host key matches known host (fingerprint: \(fingerprintsMatch), publicKey: \(publicKeyDataMatches)), accepting")
                SSHDebugLogger.shared.event(
                    "HOSTKEY",
                    "matched known host fingerprintMatch=\(fingerprintsMatch) publicKeyMatch=\(publicKeyDataMatches) decision=accept"
                )

                // If fingerprints match but publicKeyData differs, update the stored key format
                if fingerprintsMatch && !publicKeyDataMatches {
                    logger.info("Updating stored publicKeyData format for \(hostnameCopy):\(portCopy)")
                    let updatedHost = KnownHost(
                        hostname: hostnameCopy,
                        port: portCopy,
                        publicKeyData: publicKeyData,
                        keyType: keyType,
                        fingerprint: fingerprint,
                        firstSeen: knownHost.firstSeen,
                        lastSeen: Date()
                    )
                    manager.addHost(updatedHost)
                } else {
                    manager.updateLastSeen(hostname: hostname, port: port)
                }
                return true
            } else {
                // Key changed - potential MITM attack!
                logger.warning("Host key changed for \(self.hostname):\(self.port)! Old fingerprint: \(knownHost.fingerprint), New fingerprint: \(fingerprint)")
                SSHDebugLogger.shared.event(
                    "HOSTKEY",
                    "CHANGED host=\(hostnameCopy):\(portCopy) old=\(knownHost.fingerprint) new=\(fingerprint)"
                )

                // The exact key the user already approved with "Connect Once"
                // this run passes without re-prompting (still not persisted).
                if SessionApprovedHostKeys.shared.matches(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData) {
                    logger.info("Key matches session-approved (Connect Once) key, accepting")
                    return true
                }

                let request = HostKeyValidationRequest(
                    hostname: hostnameCopy,
                    port: portCopy,
                    keyType: keyType,
                    fingerprint: fingerprint,
                    publicKeyData: publicKeyData,
                    previouslyTrusted: String(knownHost.fingerprint)
                )

                let result = await requestUserValidation(request)
                request.record(result, in: manager)

                switch result {
                case .accept:
                    logger.info("User accepted new host key, updated known hosts")
                    SSHDebugLogger.shared.event("HOSTKEY", "user decision=accept(stored)")
                    return true

                case .acceptOnce:
                    // Not persisted; remembered in-memory for ancillary
                    // connections in the same flow.
                    logger.info("User accepted new host key for this session only")
                    SSHDebugLogger.shared.event("HOSTKEY", "user decision=acceptOnce(not stored)")
                    return true

                case .accepted:
                    logger.info("Host key accepted, decision already recorded")
                    SSHDebugLogger.shared.event("HOSTKEY", "user decision=accepted(recorded by prompt)")
                    return true

                case .reject:
                    logger.info("User rejected new host key")
                    SSHDebugLogger.shared.event("HOSTKEY", "user decision=reject")
                    return false
                }
            }
        } else {
            // New host - prompt user
            logger.info("New host \(self.hostname):\(self.port), requesting user validation")
            SSHDebugLogger.shared.event("HOSTKEY", "new host=\(hostnameCopy):\(portCopy), prompting user")

            if SessionApprovedHostKeys.shared.matches(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData) {
                logger.info("Key matches session-approved (Connect Once) key, accepting")
                return true
            }

            let request = HostKeyValidationRequest(
                hostname: hostnameCopy,
                port: portCopy,
                keyType: keyType,
                fingerprint: fingerprint,
                publicKeyData: publicKeyData,
                previouslyTrusted: nil
            )

            let result = await requestUserValidation(request)
            request.record(result, in: manager)

            switch result {
            case .accept:
                logger.info("User accepted new host, added to known hosts")
                SSHDebugLogger.shared.event("HOSTKEY", "user decision=accept(stored)")
                return true

            case .acceptOnce:
                // Not persisted; remembered in-memory for ancillary
                // connections in the same flow.
                logger.info("User accepted host for this session only")
                SSHDebugLogger.shared.event("HOSTKEY", "user decision=acceptOnce(not stored)")
                return true

            case .accepted:
                logger.info("Host accepted, decision already recorded")
                SSHDebugLogger.shared.event("HOSTKEY", "user decision=accepted(recorded by prompt)")
                return true

            case .reject:
                logger.info("User rejected new host")
                SSHDebugLogger.shared.event("HOSTKEY", "user decision=reject")
                return false
            }
        }
    }

    /// Generate SHA256 fingerprint in colon-separated hex format
    private func generateFingerprint(for hostKey: NIOSSHPublicKey) -> String {
        // Use the public OpenSSH string format
        // Format: "algorithm-id base64-encoded-key"
        let openSSHString = String(openSSHPublicKey: hostKey)

        // Extract just the base64 part (skip algorithm-id)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2, let keyData = Data(base64Encoded: String(components[1])) else {
            // Fallback: hash the entire string
            let fallbackData = openSSHString.data(using: .utf8) ?? Data()
            let hash = SHA256.hash(data: fallbackData)
            let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined(separator: ":")
            return "SHA256:\(fingerprint)"
        }

        // Compute SHA256 hash of the key data
        let hash = SHA256.hash(data: keyData)

        // Convert to colon-separated hex
        let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined(separator: ":")

        return "SHA256:\(fingerprint)"
    }

    /// Get the key type as a string
    private func getKeyType(from hostKey: NIOSSHPublicKey) -> String {
        // Extract from OpenSSH format
        let openSSHString = String(openSSHPublicKey: hostKey)
        let components = openSSHString.split(separator: " ")
        return components.first.map(String.init) ?? "unknown"
    }

    /// Serialize public key to base64 string for storage
    private func serializePublicKey(_ hostKey: NIOSSHPublicKey) throws -> String {
        // Use the OpenSSH public string format and extract the base64 part
        let openSSHString = String(openSSHPublicKey: hostKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2 else {
            throw HostKeySerializationError()
        }
        return String(components[1])
    }
}

/// Error thrown when host key is rejected
struct HostKeyRejectedError: Error, LocalizedError {
    var errorDescription: String? {
        "Host key was rejected by user"
    }
}
