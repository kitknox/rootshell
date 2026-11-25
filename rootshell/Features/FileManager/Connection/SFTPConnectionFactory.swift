//
//  SFTPConnectionFactory.swift
//  rootshell
//
//  Opens an SFTPConnection for an endpoint. Profiles go through the same key
//  resolution and credential steps as a terminal connect, and reuse
//  SSHConnectionHelper (jump host included) or the tssh headless connector.
//  Panes lend their live Citadel client or tssh transport.
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import os.log

enum FileManagerConnectionError: LocalizedError {
    case profileUnavailable
    case storageProviderUnavailable
    case notRemote
    case cancelled
    case sftpServerMissing(host: String)
    case sudoUnavailable
    case sudoFailed(host: String, message: String)
    case sudoRequiresTTY(host: String)

    var errorDescription: String? {
        switch self {
        case .profileUnavailable:
            String(localized: "This profile is unavailable.", comment: "File manager connection error")
        case .storageProviderUnavailable:
            String(localized: "This storage provider was removed.", comment: "File manager connection error")
        case .notRemote:
            String(localized: "This connection doesn't support file transfer.", comment: "File manager connection error")
        case .cancelled:
            String(localized: "Connection cancelled.", comment: "File manager connection error")
        case .sftpServerMissing(let host):
            String(localized: "\(host) has no sftp-server installed.", comment: "File manager connection error; the argument is a host name")
        case .sudoUnavailable:
            String(localized: "This connection can't run sudo.", comment: "File manager connection error")
        case .sudoFailed(let host, let message):
            String(localized: "sudo on \(host) failed: \(message)", comment: "File manager connection error; the arguments are a host name and the reason")
        case .sudoRequiresTTY(let host):
            String(localized: "sudo on \(host) requires a terminal (requiretty), so it can't be used for file transfer.", comment: "File manager connection error; the argument is a host name")
        }
    }
}

enum SFTPConnectionFactory {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "FileManagerConnection")

    static func open(_ endpoint: FileEndpoint, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        switch endpoint {
        case .local, .storage, .sudo:
            // Sudo connections layer on their base connection in the pool.
            throw FileManagerConnectionError.notRemote
        case .profile(let id):
            return try await openProfile(id, prompts: prompts)
        case .pane(let source):
            if let connection = try await borrowPane(source) { return connection }
            if let id = source.fallbackProfileID, ConnectionProfileManager.shared.profile(for: id) != nil {
                return try await openProfile(id, prompts: prompts)
            }
            return try await openConfig(source.fallbackConfig, label: source.displayName, prompts: prompts)
        }
    }

    // MARK: - Profiles

    private static func openProfile(_ id: UUID, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        guard let profile = ConnectionProfileManager.shared.profile(for: id),
              !profile.isDeleted, profile.isAvailableOnCurrentPlatform, profile.isSSHBased
        else { throw FileManagerConnectionError.profileUnavailable }

        var config = profile.sshConfig
        switch ConnectionKeyResolver.resolve(config: config, profileID: profile.id) {
        case .resolved(let resolved):
            config = resolved
        case .unresolved(let partial, let keys):
            guard let resolved = await prompts.resolveKeys(partial, keys: keys, profileID: profile.id) else {
                throw FileManagerConnectionError.cancelled
            }
            config = resolved
        }
        config = try await prepareCredentials(config, label: profile.name, prompts: prompts)

        if profile.connectionProtocol == .trzsz {
            let trzsz = TrzszConfig(
                sshConfig: config,
                transportMode: profile.trzszTransportMode.resolved,
                udpPortMin: profile.trzszPortMin ?? TrzszConfig.preferredUDPPortMin,
                udpPortMax: profile.trzszPortMax ?? TrzszConfig.preferredUDPPortMax,
                serverPath: profile.trzszServerPath,
                mtu: profile.trzszMTU ?? 0,
                connectTimeoutSec: profile.trzszConnectTimeoutSec
            )
            return try await openTSSH(trzsz, label: profile.name, prompts: prompts)
        }
        return try await openSSH(config, label: profile.name, prompts: prompts)
    }

    private static func openConfig(_ config: ConnectionConfig, label: String, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        switch config {
        case .trzsz(let trzsz), .shellLaunchedTrzsz(let trzsz, _):
            var trzsz = trzsz
            trzsz.sshConfig = try await prepareCredentials(trzsz.sshConfig, label: label, prompts: prompts)
            return try await openTSSH(trzsz, label: label, prompts: prompts)
        default:
            guard let ssh = config.underlyingSSHConfig else { throw FileManagerConnectionError.notRemote }
            return try await openSSH(try await prepareCredentials(ssh, label: label, prompts: prompts), label: label, prompts: prompts)
        }
    }

    /// Mirrors MainView.connectToProfile: saved passwords from the Keychain,
    /// otherwise ask; a cancelled biometric unlock cancels the connect.
    private static func prepareCredentials(_ config: SSHConfig, label: String, prompts: FileManagerPrompts) async throws -> SSHConfig {
        var config = config
        if case .password(let password) = config.authMethod, password.isEmpty {
            if SSHPasswordManager.shared.hasPassword(host: config.host, port: config.port, username: config.username) {
                config.authMethod = .savedPassword
            } else {
                guard let entered = await prompts.password(label: label) else { throw FileManagerConnectionError.cancelled }
                config.authMethod = .password(entered)
            }
        }
        do {
            return try await config.resolvedConfig()
        } catch SSHPasswordManager.PasswordError.authenticationCancelled {
            throw FileManagerConnectionError.cancelled
        } catch {
            // A saved password that fails to load (deleted, stale) falls back to asking.
            guard case .savedPassword = config.authMethod else { throw error }
            guard let entered = await prompts.password(label: label) else { throw FileManagerConnectionError.cancelled }
            config.authMethod = .password(entered)
            return try await config.resolvedConfig()
        }
    }

    // MARK: - Transports

    private static func openSSH(_ config: SSHConfig, label: String, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        try await openSSH(
            config,
            label: label,
            onHostKeyValidation: prompts.hostKey.validate,
            onKeyboardInteractiveChallenge: { await prompts.keyboardInteractive($0, label: label) }
        )
    }

    /// Also used by rf, which answers the prompts in its TUI.
    static func openSSH(
        _ config: SSHConfig,
        label: String,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?
    ) async throws -> SFTPConnection {
        let (client, jumpClient) = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
        let teardown: @Sendable () async -> Void = {
            try? await withTimeout(seconds: 2) { try await client.close() }
            if let jumpClient {
                try? await withTimeout(seconds: 2) { try await jumpClient.close() }
            }
        }
        do {
            let sftp = try await client.openSFTP()
            return SFTPConnection(
                browseClient: sftp,
                label: label,
                login: config.fileEditLogin,
                openChannel: { try await client.openSFTP() },
                openExec: citadelExecOpener(client),
                teardown: teardown
            )
        } catch {
            await teardown()
            throw SFTPError.connectionFailed(host: config.host, underlying: error)
        }
    }

    private static func openTSSH(_ trzsz: TrzszConfig, label: String, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        let transport = try await TrzszHeadlessConnector.connect(
            sshConfig: trzsz.sshConfig,
            transportMode: trzsz.transportMode,
            udpPortMin: trzsz.udpPortMin,
            udpPortMax: trzsz.udpPortMax,
            mtu: trzsz.mtu,
            connectTimeoutSec: trzsz.connectTimeoutSec,
            serverPath: trzsz.serverPath,
            displayName: "sftp \(label)",
            onHostKeyValidation: prompts.hostKey.validate,
            onKeyboardInteractiveChallenge: { await prompts.keyboardInteractive($0, label: label) }
        )
        let openChannel: @Sendable () async throws -> SFTPClient = {
            try await sftpOverExec(host: trzsz.sshConfig.host) { try await transport.openExecChannel($0) }
        }
        do {
            return SFTPConnection(
                browseClient: try await openChannel(),
                label: label,
                login: trzsz.sshConfig.fileEditLogin,
                openChannel: openChannel,
                openExec: tsshExecOpener { try await transport.openExecChannel($0) },
                teardown: { await MainActor.run { transport.disconnect() } }
            )
        } catch {
            transport.disconnect()
            throw error
        }
    }

    /// Runs sftp-server on an exec channel and speaks SFTP over it.
    private nonisolated static func sftpOverExec(
        host: String,
        open: @Sendable (String) async throws -> AsyncBytePipe
    ) async throws -> SFTPClient {
        let pipe = try await open(SFTPServerLauncher.command())
        do {
            return try await sftpClient(over: pipe, host: host)
        } catch {
            if error is CancellationError { throw error }
            // The launcher exits before any version reply when no binary exists.
            throw FileManagerConnectionError.sftpServerMissing(host: host)
        }
    }

    /// Speaks SFTP over a pipe already connected to a running sftp-server.
    nonisolated static func sftpClient(over pipe: AsyncBytePipe, host: String) async throws -> SFTPClient {
        let channel = try await BytePipeChannelBridge.makeChannel(for: pipe)
        do {
            return try await withTimeout(seconds: 20) { try await SFTPClient.connect(rawChannel: channel) }
        } catch {
            try? await channel.close()
            if !(error is CancellationError) {
                logger.error("SFTP over exec failed on \(host, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    private nonisolated static func citadelExecOpener(_ client: SSHClient) -> @Sendable (String) async throws -> RemoteExecChannel {
        { command in
            let (pipe, stderr) = try await CitadelExecBytePipe.openWithStderr(client: client, command: command)
            return RemoteExecChannel(pipe: pipe, stderr: stderr)
        }
    }

    private nonisolated static func tsshExecOpener(
        _ open: @escaping @Sendable (String) async throws -> AsyncBytePipe
    ) -> @Sendable (String) async throws -> RemoteExecChannel {
        { command in
            let pipe = try await open(command)
            guard let exec = pipe as? TrzszExecPipe else {
                await pipe.close()
                throw FileManagerConnectionError.sudoUnavailable
            }
            return RemoteExecChannel(pipe: exec, stderr: exec.stderrStream())
        }
    }

    // MARK: - Panes

    /// SFTP over the pane's own connection, or nil when it has none to lend.
    private static func borrowPane(_ source: FileEndpoint.PaneSource) async throws -> SFTPConnection? {
        guard let terminal = source.terminal else { return nil }
        let label = source.displayName
        // The pane's own login: `fallbackConfig` is its live connection's config.
        guard let ssh = source.fallbackConfig.underlyingSSHConfig else { return nil }
        let host = ssh.host
        guard let openChannel = paneChannelOpener(for: terminal, host: host) else { return nil }
        return SFTPConnection(
            browseClient: try await openChannel(),
            label: label,
            login: ssh.fileEditLogin,
            openChannel: openChannel,
            openExec: paneExecOpener(for: terminal),
            teardown: {}
        )
    }

    /// Whether `open` would borrow the pane's own connection rather than fall back to its
    /// profile (a Mosh pane, say, has none to lend).
    static func canBorrowPane(_ source: FileEndpoint.PaneSource) -> Bool {
        guard let terminal = source.terminal, let ssh = source.fallbackConfig.underlyingSSHConfig else { return false }
        return paneChannelOpener(for: terminal, host: ssh.host) != nil
    }

    /// Exec channels on the same connection `paneChannelOpener` lends.
    private static func paneExecOpener(for terminal: Ghostty.TerminalView) -> (@Sendable (String) async throws -> RemoteExecChannel)? {
        if let citadel = terminal.session as? CitadelSSHSession, let client = citadel.client {
            return citadelExecOpener(client)
        }
        if let trzsz = TmuxController.gatewayTrzszSession(for: terminal.session) {
            return tsshExecOpener { try await trzsz.openExecChannel($0) }
        }
        return nil
    }

    /// Opens SFTP channels on a pane's live Citadel client or tssh transport,
    /// or nil when it has none to lend (Mosh, local shells). `terminal` must
    /// be the pane that owns the connection, not a tmux or herdr pane.
    static func paneChannelOpener(
        for terminal: Ghostty.TerminalView,
        host: String
    ) -> (@Sendable () async throws -> SFTPClient)? {
        if let citadel = terminal.session as? CitadelSSHSession, let client = citadel.client {
            return { try await client.openSFTP() }
        }
        if let trzsz = TmuxController.gatewayTrzszSession(for: terminal.session) {
            return {
                try await sftpOverExec(host: host) { command in
                    try await trzsz.openExecChannel(command)
                }
            }
        }
        return nil
    }
}
