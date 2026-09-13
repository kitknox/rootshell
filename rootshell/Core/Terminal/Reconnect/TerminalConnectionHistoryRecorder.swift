import Foundation
import os

/// Records SSH-backed connections after they stay up long enough to count as
/// successful.
@MainActor
final class TerminalConnectionHistoryRecorder {
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(
        connectionConfig: ConnectionConfig,
        currentSession: @escaping @MainActor @Sendable () -> TerminalSession?
    ) {
        guard let sshConfig = connectionConfig.sshConfigForHistory else {
            return
        }

        let historyProtocol: ConnectionProtocol? = connectionConfig.isTrzsz
            ? .trzsz
            : (connectionConfig.isMosh ? .mosh : .ssh)

        Ghostty.logger.info("Starting connection success timer (2s) for \(sshConfig.displayName)")

        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            guard !Task.isCancelled else {
                Ghostty.logger.info("Connection success timer cancelled")
                return
            }

            let authType: SSHAuthType
            switch sshConfig.authMethod {
            case .password:
                authType = sshConfig.usedSavedPassword ? .savedPassword : .password
            case .savedPassword:
                authType = .savedPassword
            case .key(let keyID):
                let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
                authType = .key(keyID, fingerprint: fingerprint)
            case .keyboardInteractive:
                authType = .keyboardInteractive
            case .none:
                authType = .none
            case .unknown(let rawType):
                authType = .unknown(rawType: rawType)
            }

            let jumpAuthType: SSHAuthType?
            if let jumpConfig = sshConfig.jumpHost {
                switch jumpConfig.authMethod {
                case .password:
                    jumpAuthType = sshConfig.usedSavedJumpPassword ? .savedPassword : .password
                case .savedPassword:
                    jumpAuthType = .savedPassword
                case .key(let keyID):
                    let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
                    jumpAuthType = .key(keyID, fingerprint: fingerprint)
                case .keyboardInteractive:
                    jumpAuthType = .keyboardInteractive
                case .none:
                    jumpAuthType = SSHAuthType.none
                case .unknown(let rawType):
                    jumpAuthType = .unknown(rawType: rawType)
                }
            } else {
                jumpAuthType = nil
            }

            let session = currentSession()
            let resolvedIP = (session as? CitadelSSHSession)?.resolvedIPAddress
                ?? (session as? SSHSession)?.resolvedIPAddress

            let hints = KeyResolutionHint.hints(for: sshConfig)

            SSHConnectionHistoryManager.shared.recordConnection(
                username: sshConfig.username,
                host: sshConfig.host,
                port: sshConfig.port,
                authType: authType,
                connectionProtocol: historyProtocol,
                jumpHost: sshConfig.jumpHost?.host,
                jumpPort: sshConfig.jumpHost?.port,
                jumpUsername: sshConfig.jumpHost?.username,
                jumpAuthType: jumpAuthType,
                tsshRelay: sshConfig.jumpHost?.tsshRelay,
                resolvedIP: resolvedIP,
                hssShorthand: sshConfig.hssShorthand,
                agentConfig: sshConfig.agentConfig,
                gpgAgentConfig: sshConfig.gpgAgentConfig,
                portForwardConfig: sshConfig.portForwardConfig,
                tmuxAutoEnable: sshConfig.tmuxAutoEnable,
                tmuxAutoMode: sshConfig.tmuxAutoMode,
                herdrAutoEnable: sshConfig.herdrAutoEnable,
                herdrAutoMode: sshConfig.herdrAutoMode,
                zmxAutoEnable: sshConfig.zmxAutoEnable,
                launchCommand: sshConfig.launchCommand,
                launchCommandMode: sshConfig.launchCommandMode,
                terminalType: sshConfig.terminalType,
                multiplexerSessionName: sshConfig.multiplexerSessionName,
                keyResolutionHints: hints
            )

            if let ip = resolvedIP, sshConfig.host.hasSuffix(".local") {
                Ghostty.logger.info("Connection to \(sshConfig.displayName) recorded in history with cached IP \(ip)")
            } else {
                Ghostty.logger.info("Connection to \(sshConfig.displayName) recorded in history")
            }
            self?.task = nil
        }
    }
}
