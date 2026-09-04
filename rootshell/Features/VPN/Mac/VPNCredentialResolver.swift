//
//  VPNCredentialResolver.swift
//  rootshell (Catalyst, Standalone)
//
//  Resolves the non-secret profile snapshot + the real SSH secret (private key
//  or password) into a `VPNResolvedConfig` that the host forwards to the root
//  system extension. Runs in the Catalyst app (user context), which owns the
//  keychain items — the sysext (root) cannot read them. Keychain services /
//  access group must match `VPNSSHConnector` on the extension side.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import os.log

enum VPNCredentialResolverError: LocalizedError {
    case profileNotStartable
    case keyMissing
    case passwordMissing
    case agentKeyBlobMissing

    var errorDescription: String? {
        switch self {
        case .profileNotStartable: return "This VPN profile needs a saved password or SSH key before it can start."
        case .keyMissing: return "The SSH key for this VPN profile could not be found in the keychain."
        case .passwordMissing: return "The saved password for this VPN profile could not be found."
        case .agentKeyBlobMissing: return "The agent-backed SSH key for this VPN profile has no cached public key."
        }
    }
}

enum VPNCredentialResolver {
    private static let logger = Logger(subsystem: "com.rootshell", category: "VPNCredentialResolver")

    private static let accessGroup = AppIdentifiers.keychainAccessGroup
    private static let privateKeyService = "com.ghostty.ssh.privatekey"
    private static let passphraseService = "com.ghostty.ssh.passphrase"
    private static let passwordService = "com.ghostty.ssh.password"

    /// Build the full resolved config (snapshot + secrets) for a profile.
    static func resolve(snapshot: VPNSharedProfileSnapshot) throws -> VPNResolvedConfig {
        guard snapshot.isBackgroundStartable else { throw VPNCredentialResolverError.profileNotStartable }

        let credential = try resolveCredential(
            auth: snapshot.auth,
            host: snapshot.host,
            port: snapshot.port,
            username: snapshot.username
        )

        var jumpCredential: VPNResolvedCredential?
        if let jump = snapshot.jumpHost {
            jumpCredential = try resolveCredential(
                auth: jump.auth,
                host: jump.host,
                port: jump.port,
                username: jump.username
            )
        }

        return VPNResolvedConfig(snapshot: snapshot, credential: credential, jumpCredential: jumpCredential)
    }

    /// Encode a resolved config for delivery via the control socket (matches the
    /// extension's `.iso8601` decoder).
    static func encode(_ config: VPNResolvedConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(config)
    }

    private static func resolveCredential(
        auth: VPNSharedProfileAuth,
        host: String,
        port: Int,
        username: String
    ) throws -> VPNResolvedCredential? {
        switch auth.method {
        case .none:
            return nil
        case .savedPassword:
            let connectionKey = "\(host.lowercased()):\(port):\(username.lowercased())"
            guard let password = loadString(service: passwordService, account: connectionKey), !password.isEmpty else {
                throw VPNCredentialResolverError.passwordMissing
            }
            return .password(password)
        case .key:
            guard let keyID = auth.keyID else {
                throw VPNCredentialResolverError.keyMissing
            }
            // Agent-backed keys have no keychain secret: the sysext gets the
            // public blob and requests signatures through the host broker.
            if let savedKey = SSHKeyManager.shared.findKey(id: keyID),
               let agentInfo = savedKey.externalAgentInfo {
                guard let publicKeyBlob = savedKey.publicKeyBlob else {
                    throw VPNCredentialResolverError.agentKeyBlobMissing
                }
                let socketPath = ExternalSSHAgentRegistry.shared.socketPath(forAgentID: agentInfo.agentID)
                    ?? agentInfo.socketPath
                return .agentKey(
                    publicKeyBlob: publicKeyBlob,
                    algorithm: agentInfo.algorithm,
                    socketPath: socketPath
                )
            }
            guard let keyString = loadString(service: privateKeyService, account: keyID.uuidString) else {
                throw VPNCredentialResolverError.keyMissing
            }
            let passphrase = loadString(service: passphraseService, account: keyID.uuidString)
            return .key(privateKey: keyString, passphrase: passphrase)
        case .passwordRequired:
            throw VPNCredentialResolverError.profileNotStartable
        }
    }

    private static func loadString(service: String, account: String) -> String? {
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#endif
