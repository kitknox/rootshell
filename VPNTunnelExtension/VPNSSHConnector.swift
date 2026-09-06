//
//  VPNSSHConnector.swift
//  VPNTunnelExtension
//
//  Establishes SSH connections for the VPN extension.
//  Self-contained: loads keys from shared Keychain, connects via Citadel.
//

import Foundation
import os.log
@preconcurrency import Citadel
import NIOSSH
import NIOCore
import NIOPosix
import Crypto

/// Establishes SSH connections for the VPN extension process.
/// Loads credentials from the shared Keychain access group and connects via Citadel.
nonisolated enum VPNSSHConnector {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "SSHConnector")

    // Keychain service names must match the main app's KeychainManager
    private static let accessGroup = AppIdentifiers.keychainAccessGroup
    private static let privateKeyService = "com.ghostty.ssh.privatekey"
    private static let passphraseService = "com.ghostty.ssh.passphrase"
    private static let passwordService = "com.ghostty.ssh.password"

    struct ConnectionResult {
        let client: SSHClient
        let jumpClient: SSHClient?
    }

    // DO NOT set .maximumPacketSize in protocol options. NIO SSH uses the same
    // value for BOTH the transport-layer parser limit AND the channel-level
    // max_packet_size advertised in CHANNEL_OPEN. A ChannelData carrying N bytes
    // of payload has a transport packet of N + ~32 bytes (framing, padding, MAC).
    // Setting maximumPacketSize = 32768 means the parser rejects its own max-size
    // ChannelData (32800 >= 32768 → invalidEncryptedPacketLength). Worse,
    // decryptFirstBlock already modified the buffer in-place before the check,
    // so the parser is permanently corrupted: every subsequent channelRead fails
    // with parsed=0, causing the connection to stall silently.
    // Default (128KB) is safe: OpenSSH caps DirectTCPIP data at 32KB regardless
    // of what we advertise, so transport packets never approach 128KB.

    // Steady-state per-channel window size (the WindowManager target).
    // Must be much larger than the server's typical ChannelData size (~32KB for
    // OpenSSH DirectTCPIP) to prevent window exhaustion. With 256KB target, a
    // channel needs 8 back-to-back full-size packets before exhaustion — NIO
    // sends WindowAdjust eagerly on delivery, so credit replenishes in time.
    // Memory: 64 channels × 256KB = 16MB peak NIO buffers (acceptable for VPN).
    // OpenSSH uses 2MB per channel; 256KB is a conservative middle ground.
    private static let vpnInitialChannelWindowSize = 256 * 1024
    // Window size advertised in SSH_MSG_CHANNEL_OPEN. Smaller than target to
    // limit burst when many channels open simultaneously, but still large
    // enough (4× typical 32KB ChannelData) to avoid immediate exhaustion.
    // 128KB × 64 channels = 8MB initial credit.
    private static let vpnChannelOpenWindowSize = 128 * 1024
    // Aggregate window budget: disabled (0 = unlimited).
    // With 256KB per-channel target, 100 channels = 25MB outstanding credit.
    // A finite budget causes idle-channel credit hogging: persistent connections
    // hold WindowAdjust credit the server never consumes, starving new channels.
    private static let vpnAggregateWindowBudget = 0
    private static let vpnProtocolOptions: Set<SSHProtocolOption> = [
        .initialChannelWindowSize(vpnInitialChannelWindowSize),
        .channelOpenWindowSize(vpnChannelOpenWindowSize),
        .maximumAggregateWindowSize(vpnAggregateWindowBudget),
    ]

    /// Connect to SSH server using VPN tunnel config credentials.
    /// - Parameters:
    ///   - config: VPN tunnel config with SSH credentials
    ///   - resolvedHost: Pre-resolved IP address to connect to (overrides config.sshHost for connection)
    ///   - group: Shared event loop group for SSH and SOCKS5 channels
    ///   - loginTimeout: Per-attempt login timeout (TCP+SSH handshake budget). Defaults to 30s
    ///     for back-compat callers. Wrapped in `InitialConnectRetry.run`, the caller passes
    ///     a smaller value on early attempts and a larger value on later ones.
    static func connect(
        config: VPNTunnelConfig,
        resolvedHost: String? = nil,
        group: MultiThreadedEventLoopGroup = .singleton,
        loginTimeout: TimeAmount = .seconds(30)
    ) async throws -> ConnectionResult {
        let debugLog = VPNConnectionDebugLogger.shared
        let host = resolvedHost ?? config.sshHost
        let port = config.sshPort
        let username = config.sshUsername

        guard !host.isEmpty else {
            throw VPNSSHError.invalidConfig("SSH host is empty")
        }

        let auth = try buildAuthMethod(
            username: username,
            host: config.sshHost,
            port: config.sshPort,
            auth: config.sshAuth,
            resolved: config.resolvedCredential
        )

        // Pin is keyed by the configured hostname even when a resolved IP is
        // dialed — same identity the terminal validated against. Build all
        // validators before any TCP dial so a missing pin never opens a socket.
        let targetValidator = try pinnedValidator(
            host: config.sshHost,
            port: config.sshPort,
            pinned: config.pinnedHostKey,
            trustedCAKeys: config.trustedCAKeys
        )
        // Servers only present a host certificate when the client advertises
        // certificate host-key algorithms, so opt in whenever a CA applies.
        let targetProtocolOptions = protocolOptions(
            advertisingHostCertificates: !(config.trustedCAKeys ?? []).isEmpty
        )

        if let jump = config.jumpHostConfig {
            logger.info("Connecting via jump host: \(jump.host)")

            let jumpValidator = try pinnedValidator(
                host: jump.host,
                port: jump.port,
                pinned: jump.pinnedHostKey,
                trustedCAKeys: jump.trustedCAKeys
            )
            let jumpProtocolOptions = protocolOptions(
                advertisingHostCertificates: !(jump.trustedCAKeys ?? []).isEmpty
            )

            let jumpAuth = try buildAuthMethod(
                username: jump.username,
                host: jump.host,
                port: jump.port,
                auth: jump.auth,
                resolved: config.jumpResolvedCredential
            )

            let loginTimeoutSec = Double(loginTimeout.nanoseconds) / 1_000_000_000
            debugLog.beginPhase("sshJumpHost", "Connecting to jump host \(jump.host):\(jump.port) user=\(jump.username) auth=\(jump.auth.method.rawValue) loginTimeout=\(loginTimeoutSec)s...")
            let jumpClient: SSHClient
            do {
                jumpClient = try await SSHClient.connect(
                    host: jump.host,
                    port: jump.port,
                    authenticationMethod: jumpAuth,
                    hostKeyValidator: jumpValidator,
                    reconnect: .never,
                    algorithms: .all,
                    protocolOptions: jumpProtocolOptions,
                    group: group,
                    loginTimeout: loginTimeout
                )
            } catch {
                debugLog.endPhase("sshJumpHost", "FAILED: \(error.localizedDescription)")
                throw error
            }
            debugLog.endPhase("sshJumpHost", "OK")

            var targetSettings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: { auth },
                hostKeyValidator: targetValidator
            )
            targetSettings.protocolOptions = targetProtocolOptions
            targetSettings.group = group
            targetSettings.loginTimeout = loginTimeout

            debugLog.beginPhase("sshTarget", "Jumping to target \(host):\(port)...")
            let finalClient: SSHClient
            do {
                finalClient = try await jumpClient.jump(to: targetSettings)
            } catch {
                debugLog.endPhase("sshTarget", "FAILED: \(error.localizedDescription)")
                // Close the jump client so the next retry attempt doesn't leak it
                try? await jumpClient.close()
                throw error
            }
            debugLog.endPhase("sshTarget", "OK")
            logger.info("SSH connected via jump host to \(host):\(port)")
            return ConnectionResult(client: finalClient, jumpClient: jumpClient)
        } else {
            logger.info("Connecting directly to \(host):\(port)")

            let loginTimeoutSec = Double(loginTimeout.nanoseconds) / 1_000_000_000
            debugLog.beginPhase("sshDirect", "TCP+SSH handshake to \(host):\(port) loginTimeout=\(loginTimeoutSec)s...")
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: targetValidator,
                reconnect: .never,
                algorithms: .all,
                protocolOptions: targetProtocolOptions,
                group: group,
                loginTimeout: loginTimeout
            )
            debugLog.endPhase("sshDirect", "OK")

            logger.info("SSH connected to \(host):\(port)")
            return ConnectionResult(client: client, jumpClient: nil)
        }
    }

    // MARK: - Host Key Pinning

    /// Strict validator for a host: requires a pinned key from the main app's
    /// known-hosts store and/or trusted host-CA keys covering the host; the
    /// VPN path never prompts.
    private static func pinnedValidator(
        host: String,
        port: Int,
        pinned: VPNPinnedHostKey?,
        trustedCAKeys: [String]?
    ) throws -> SSHHostKeyValidator {
        let parsedCAs: [NIOSSHPublicKey] = (trustedCAKeys ?? []).compactMap { raw in
            guard let key = try? NIOSSHPublicKey(openSSHPublicKey: raw) else {
                logger.warning("Ignoring unparseable trusted host CA key for \(host)")
                return nil
            }
            return key
        }
        guard pinned != nil || !parsedCAs.isEmpty else {
            throw VPNSSHError.hostKeyNotPinned(host: host, port: port)
        }
        return .custom(VPNPinnedHostKeyValidator(
            host: host,
            port: port,
            pinned: pinned,
            trustedCAKeys: parsedCAs
        ))
    }

    private static func protocolOptions(advertisingHostCertificates: Bool) -> Set<SSHProtocolOption> {
        guard advertisingHostCertificates else { return vpnProtocolOptions }
        var options = vpnProtocolOptions
        options.insert(.advertiseHostCertificateAlgorithms)
        return options
    }

    // MARK: - Auth Method Building

    private static func buildAuthMethod(
        username: String,
        host: String,
        port: Int,
        auth: VPNSharedProfileAuth,
        resolved: VPNResolvedCredential? = nil
    ) throws -> SSHAuthenticationMethod {
        switch auth.method {
        case .none:
            return .custom(VPNNoneAuthDelegate(username: username))
        case .savedPassword:
            // macOS: the host resolves the password and pushes it (the root
            // sysext can't read the shared keychain). Fall back to keychain on iOS.
            if case .password(let provided)? = resolved, !provided.isEmpty {
                return .passwordBased(username: username, password: provided)
            }
            let connectionKey = "\(host.lowercased()):\(port):\(username.lowercased())"
            if let password = loadKeychainString(service: passwordService, account: connectionKey),
               !password.isEmpty {
                return .passwordBased(username: username, password: password)
            }
            throw VPNSSHError.invalidConfig("Saved password missing for \(username)@\(host):\(port)")
        case .passwordRequired:
            throw VPNSSHError.invalidConfig("Profile requires a saved password or SSH key before VPN can start")
        case .key:
            // Agent-backed key (macOS only): no private key exists anywhere in
            // the tunnel — offer the public blob and broker each signature
            // through the host's agent poll loop.
            if case .agentKey(let publicKeyBlob, let algorithm, let socketPath)? = resolved {
                #if os(macOS)
                let agentKey = try createVPNAgentKey(
                    publicKeyBlob: publicKeyBlob,
                    algorithm: algorithm,
                    socketPath: socketPath
                )
                return .custom(VPNKeyAuthDelegate(username: username, privateKey: NIOSSHPrivateKey(custom: agentKey)))
                #else
                throw VPNSSHError.invalidConfig("Agent-backed SSH keys are only supported on macOS")
                #endif
            }

            // macOS: use the host-provided key material; iOS reads the keychain.
            let keyString: String
            let passphrase: String?
            if case .key(let providedKey, let providedPassphrase)? = resolved {
                keyString = providedKey
                passphrase = providedPassphrase
            } else {
                guard let keyID = auth.keyID else {
                    throw VPNSSHError.invalidConfig("SSH key authentication is missing a key identifier")
                }
                let keyData = try loadKeyData(keyID: keyID)
                guard let loaded = String(data: keyData, encoding: .utf8) else {
                    throw VPNSSHError.invalidKeyData
                }
                keyString = loaded
                passphrase = loadKeychainString(service: passphraseService, account: keyID.uuidString)
            }
            let parsed = try VPNKeyParser.parse(keyString: keyString, passphrase: passphrase)

            switch parsed {
            case .ed25519(let key):
                let nioKey = NIOSSHPrivateKey(ed25519Key: key)
                return .custom(VPNKeyAuthDelegate(username: username, privateKey: nioKey))
            case .ecdsaP256(let key):
                let nioKey = NIOSSHPrivateKey(p256Key: key)
                return .custom(VPNKeyAuthDelegate(username: username, privateKey: nioKey))
            case .ecdsaP384(let key):
                let nioKey = NIOSSHPrivateKey(p384Key: key)
                return .custom(VPNKeyAuthDelegate(username: username, privateKey: nioKey))
            case .ecdsaP521(let key):
                let nioKey = NIOSSHPrivateKey(p521Key: key)
                return .custom(VPNKeyAuthDelegate(username: username, privateKey: nioKey))
            case .rsa(let rsaKey):
                return .rsa(username: username, privateKey: rsaKey)
            }
        }
    }

    /// Load key data from shared keychain.
    private static func loadKeyData(keyID: UUID) throws -> Data {
        if let data = loadKeychainData(service: privateKeyService, account: keyID.uuidString) {
            logger.info("Loaded key for key \(keyID.uuidString.prefix(8))")
            return data
        }

        throw VPNSSHError.keyNotFound(keyID)
    }

    // MARK: - Keychain Access

    private static func loadKeychainData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func loadKeychainString(service: String, account: String) -> String? {
        guard let data = loadKeychainData(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - NIO Auth Delegates

/// Public key authentication delegate for VPN extension.
/// Must be nonisolated — NIO calls from event loop threads, not the main actor.
nonisolated final class VPNKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var tried = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !tried, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

/// "None" authentication delegate for VPN extension.
/// Must be nonisolated — NIO calls from event loop threads, not the main actor.
nonisolated final class VPNNoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var tried = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !tried else {
            nextChallengePromise.succeed(nil)
            return
        }
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .none
        ))
    }
}

// MARK: - Host Key Validation

/// Strict host-key validator for the VPN path. No prompts: the server either
/// presents a host certificate signed by a trusted CA, or its (base) key
/// matches the pin captured from the main app's known-hosts store — otherwise
/// the connect fails. Must be nonisolated — NIO calls from event loop threads.
nonisolated final class VPNPinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "HostKeyValidator")

    private let host: String
    private let port: Int
    private let pinned: VPNPinnedHostKey?
    private let trustedCAKeys: [NIOSSHPublicKey]

    init(host: String, port: Int, pinned: VPNPinnedHostKey?, trustedCAKeys: [NIOSSHPublicKey]) {
        self.host = host
        self.port = port
        self.pinned = pinned
        self.trustedCAKeys = trustedCAKeys
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // CA-signed host certificate first, mirroring the app's delegate; on
        // failure fall back to comparing the certificate's base key to the pin.
        if let cert = NIOSSHCertifiedPublicKey(hostKey), validateCertificate(cert) {
            validationCompletePromise.succeed(())
            return
        }

        let baseKey = NIOSSHCertifiedPublicKey(hostKey)?.key ?? hostKey
        do {
            let presented = SSHHostKeyFormatter.fingerprint(for: baseKey)
            guard let pinned else {
                validationCompletePromise.fail(VPNSSHError.hostKeyUnverified(
                    host: host, port: port, presented: presented))
                return
            }
            let blob = try SSHHostKeyFormatter.base64Blob(for: baseKey)
            // Blob OR fingerprint match — same tolerance for legacy stored
            // formats as the app's known-hosts comparison.
            if blob == pinned.publicKeyBase64 || presented == pinned.fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(VPNSSHError.hostKeyMismatch(
                    host: host,
                    port: port,
                    expected: pinned.fingerprint,
                    presented: presented
                ))
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    /// Validate a presented host certificate against the trusted CAs. Same
    /// semantics as the app's CitadelHostKeyValidatorDelegate: a configured CA
    /// must sign the cert, the cert must be a host cert within its validity
    /// window, and the hostname must match its principals (wildcards allowed;
    /// empty principals = any host, constrained by the CA's host patterns
    /// applied when the keys were mirrored).
    private func validateCertificate(_ cert: NIOSSHCertifiedPublicKey) -> Bool {
        guard !trustedCAKeys.isEmpty else { return false }

        // NIOSSH's `validate(principal:)` is exact-membership only; pre-match
        // wildcard principals ourselves and hand it a concrete list member.
        let principal: String
        if cert.validPrincipals.isEmpty {
            principal = host
        } else if cert.validPrincipals.contains(host) {
            principal = host
        } else if let matched = cert.validPrincipals.first(where: {
            SSHHostPatternMatcher.matchGlob(host.lowercased(), pattern: $0.lowercased())
        }) {
            principal = matched
        } else {
            let principals = cert.validPrincipals.joined(separator: ", ")
            Self.logger.info("Host cert principals [\(principals)] do not match \(self.host)")
            return false
        }

        do {
            _ = try cert.validate(
                principal: principal,
                type: .host,
                allowedAuthoritySigningKeys: trustedCAKeys,
                acceptableCriticalOptions: []
            )
            return true
        } catch {
            let desc = error.localizedDescription
            Self.logger.info("Host certificate validation failed for \(self.host): \(desc)")
            return false
        }
    }
}

// MARK: - Error Types

enum VPNSSHError: LocalizedError {
    case invalidConfig(String)
    case invalidKeyData
    case keyNotFound(UUID)
    case connectionFailed(String)
    case hostKeyNotPinned(host: String, port: Int)
    case hostKeyMismatch(host: String, port: Int, expected: String, presented: String)
    case hostKeyUnverified(host: String, port: Int, presented: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let detail): return "Invalid VPN SSH config: \(detail)"
        case .invalidKeyData: return "SSH key data is not valid UTF-8"
        case .keyNotFound(let id): return "SSH key not found: \(id.uuidString.prefix(8))"
        case .connectionFailed(let detail): return "SSH connection failed: \(detail)"
        case .hostKeyNotPinned(let host, let port):
            return "No trusted SSH host key for \(host):\(port). Connect to this server in a regular SSH terminal session first to verify and save its host key (or add its host certificate authority in Settings), then start the VPN."
        case .hostKeyMismatch(let host, let port, let expected, let presented):
            return "SSH host key mismatch for \(host):\(port). Expected \(expected) but the server presented \(presented). This could indicate a man-in-the-middle attack; the VPN was stopped. If the server's key legitimately changed, connect in a regular SSH terminal session to review and accept the new key."
        case .hostKeyUnverified(let host, let port, let presented):
            return "Could not verify the SSH host key for \(host):\(port). The server presented \(presented), which is not signed by a trusted host certificate authority, and no saved host key is available to compare against. This could indicate a man-in-the-middle attack; the VPN was stopped."
        }
    }
}
