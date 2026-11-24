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

    struct LoadResult: Sendable {
        let response: GitDiffProbeResponse
        /// Local change-detection baseline (`knownDirectory`) captured after
        /// directory resolution and immediately before starting Git. Kept in
        /// the same domain as `knownDirectory(for:)` so uncached tmux lookups
        /// do not look like perpetual directory changes on idle panes, while
        /// directory changes during an in-flight Git probe are still noticed.
        let baselineDirectory: String?
    }

    static func load(
        _ request: GitDiffProbeRequest,
        for terminal: Ghostty.TerminalView
    ) async throws -> LoadResult {
        // A tmux -CC or herdr pane rides its gateway's connection.
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else { throw SourceError.notConnected }
        guard supports(terminal) else { throw SourceError.unsupportedPane }
        var request = request
        request.directory = await resolveDirectory(of: terminal, owner: owner)
        try Task.checkCancellation()
        let baselineDirectory = knownDirectory(for: terminal)

        let isLocal = owner.connectionConfig.underlyingSSHConfig == nil
        #if !targetEnvironment(macCatalyst)
        if isLocal {
            let local = request
            let response = await Task.detached(priority: .utility) { GitDiffLibgit2Source.load(local) }.value
            return LoadResult(response: response, baselineDirectory: baselineDirectory)
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
        let response = await Task.detached(priority: .utility) {
            GitDiffProbeCommand.parse(output, nonce: nonce, request: parsed)
        }.value
        return LoadResult(response: response, baselineDirectory: baselineDirectory)
    }

    /// The best locally known directory for `terminal`, without network I/O.
    /// For herdr panes, prefers herdr's `foreground_cwd`/`cwd` over `terminal.pwd`,
    /// because replayed OSC 7 or snapshot state can reflect an older outer shell.
    static func knownDirectory(for terminal: Ghostty.TerminalView) -> String? {
        if let binding = terminal.herdrPaneBinding,
           let path = HerdrController.controller(forGateway: binding.gatewayUUID)?.workingDirectory(for: binding),
           path.hasPrefix("/") {
            return path
        }
        if let pwd = terminal.pwd, pwd.hasPrefix("/") { return pwd }
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else { return nil }
        return localFallbackDirectory(of: terminal, owner: owner)
    }

    /// Resolves the live directory of `terminal` on its host, asking the
    /// multiplexer directly for herdr and tmux -CC panes so stale or missing
    /// OSC 7 never points git at an old directory.
    private static func resolveDirectory(
        of terminal: Ghostty.TerminalView,
        owner: Ghostty.TerminalView
    ) async -> String? {
        if let binding = terminal.herdrPaneBinding,
           let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
           let path = await controller.refreshWorkingDirectory(for: binding),
           path.hasPrefix("/") {
            return path
        }
        if let binding = terminal.tmuxPaneBinding,
           let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
           controller.ownerTerminalUUIDForNotifications == binding.parentUUID,
           let paths = try? await controller.paneWorkingDirectories(),
           let path = paths[binding.paneId], path.hasPrefix("/") {
            return path
        }
        if let pwd = terminal.pwd, pwd.hasPrefix("/") { return pwd }
        return localFallbackDirectory(of: terminal, owner: owner)
    }

    private static func localFallbackDirectory(
        of terminal: Ghostty.TerminalView,
        owner: Ghostty.TerminalView
    ) -> String? {
        #if !targetEnvironment(macCatalyst)
        if let local = owner.session as? LocalShellSession, owner.connectionConfig.underlyingSSHConfig == nil {
            return local.sessionCurrentDirectory
        }
        #endif
        if case .local(let start) = owner.connectionConfig, owner === terminal { return start }
        return nil
    }
}
