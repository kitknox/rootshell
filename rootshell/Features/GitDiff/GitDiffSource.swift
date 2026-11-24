//
//  GitDiffSource.swift
//  rootshell
//
//  Answers a diff request for a pane over whatever that pane already has:
//  libgit2 for an iOS local shell, the helper for a Mac local shell, and an
//  exec channel on the live connection for ssh, tssh and mosh. It never
//  opens a connection of its own and never types into the pane.
//

import Foundation

@MainActor
enum GitDiffSource {

    enum SourceError: Error, Equatable {
        /// This kind of pane has no way to run git (a console, a remote screen).
        case unsupportedPane
        /// The pane's connection is not up yet, or just went away.
        case notConnected
        /// A Mac local shell, and the helper that runs its commands is not available.
        case helperUnavailable
    }

    /// Whether `terminal` could answer a diff request at all.
    static func supports(_ terminal: Ghostty.TerminalView) -> Bool {
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else { return false }
        switch owner.connectionConfig {
        case .local, .ssh, .mosh, .trzsz, .shellLaunchedSSH, .shellLaunchedMosh, .shellLaunchedTrzsz: return true
        default: return false
        }
    }

    static func load(
        _ request: GitDiffProbeRequest,
        for terminal: Ghostty.TerminalView
    ) async throws -> GitDiffProbeResponse {
        // A tmux -CC or herdr pane rides its gateway's connection.
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else { throw SourceError.notConnected }
        guard supports(terminal) else { throw SourceError.unsupportedPane }
        var request = request
        request.directory = directory(of: terminal, owner: owner)

        let isLocal = owner.connectionConfig.underlyingSSHConfig == nil
        #if !targetEnvironment(macCatalyst)
        if isLocal {
            let local = request
            return await Task.detached(priority: .utility) { GitDiffLibgit2Source.load(local) }.value
        }
        #endif
        guard RemoteExecProbe.canProbe(owner) else { throw SourceError.notConnected }

        // Only a pane that owns a remote connection can be found by its
        // token; a multiplexer pane reports its own directory instead.
        let paneScript = !isLocal && !terminal.isMultiplexerPane
            ? ProjectProbeCommand.paneDirectoryScript(paneToken: terminal.uuid.uuidString)
            : nil
        let (command, nonce) = GitDiffProbeCommand.command(
            request, paneDirectoryScript: paneScript, pathPrefix: SSHConfig.remoteExecPathPrefix)
        let output: String
        do {
            output = try await RemoteExecProbe.run(
                command, on: owner,
                timeout: request.includePatch ? 20 : 10,
                maxResponseBytes: GitDiffProbeCommand.responseByteLimit(for: request))
        } catch RemoteExecProbe.ProbeError.notConnected where isLocal {
            throw SourceError.helperUnavailable
        }
        let parsed = request
        return await Task.detached(priority: .utility) {
            GitDiffProbeCommand.parse(output, nonce: nonce, request: parsed)
        }.value
    }

    /// The directory the pane's shell is in, on the host that runs it.
    private static func directory(of terminal: Ghostty.TerminalView, owner: Ghostty.TerminalView) -> String? {
        if let pwd = terminal.pwd, pwd.hasPrefix("/") { return pwd }
        #if !targetEnvironment(macCatalyst)
        if let local = owner.session as? LocalShellSession, owner.connectionConfig.underlyingSSHConfig == nil {
            return local.sessionCurrentDirectory
        }
        #endif
        if case .local(let start) = owner.connectionConfig, owner === terminal { return start }
        return nil
    }
}
