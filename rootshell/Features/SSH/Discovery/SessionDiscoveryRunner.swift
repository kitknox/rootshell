//
//  SessionDiscoveryRunner.swift
//  rootshell
//
//  Combined orchestrator that discovers tmux, zellij, herdr, and zmx sessions via a single SSH exec channel.
//

import Foundation
import Citadel
import NIO
import NIOFoundationCompat
import os

// MARK: - Discovery Result

struct SessionDiscoveryResult: Sendable {
    let sessions: [MultiplexerSession]
    let types: Set<MultiplexerType>
    let swipeBindings: MultiplexerSwipeBindings

    var isEmpty: Bool { sessions.isEmpty && !swipeBindings.hasResolvedBindings }
}

// MARK: - Combined Discovery Command

enum SessionDiscoveryCommand {
    /// Builds a single shell command that discovers tmux, zellij, herdr, and zmx sessions.
    /// Each section is wrapped in nonce-tagged markers so captured terminal content
    /// (which may contain marker strings if this source code is visible) cannot collide.
    /// Uses a single SSH exec channel for efficiency.
    static func command(
        skipTmuxSessions: Bool,
        skipZellijSessions: Bool,
        skipHerdrSessions: Bool,
        skipZmxSessions: Bool,
        discoverTmuxBindings: Bool,
        discoverZellijBindings: Bool,
        skipCaptures: Bool = false
    ) -> (command: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))
        let d = TmuxDiscoveryCommand.delimiter
        var parts: [String] = []

        if discoverTmuxBindings || !skipTmuxSessions {
            var tmuxParts: [String] = []
            if discoverTmuxBindings {
                tmuxParts.append(
                    "echo \"\(MultiplexerDiscoveryMarkers.bindingsStart(nonce))\";"
                    + " echo \"\(MultiplexerDiscoveryMarkers.tmuxPrefix(nonce))\";"
                    + " tmux show-options -gqv prefix 2>/dev/null;"
                    + " echo \"\(MultiplexerDiscoveryMarkers.tmuxPrefix2(nonce))\";"
                    + " tmux show-options -gqv prefix2 2>/dev/null;"
                    + " echo \"\(MultiplexerDiscoveryMarkers.tmuxRootKeys(nonce))\";"
                    + " tmux list-keys -T root 2>/dev/null;"
                    + " echo \"\(MultiplexerDiscoveryMarkers.tmuxPrefixKeys(nonce))\";"
                    + " tmux list-keys -T prefix 2>/dev/null;"
                    + " echo \"\(MultiplexerDiscoveryMarkers.bindingsEnd(nonce))\";"
                )
            }

            if !skipTmuxSessions {
                var section = "echo \"::SESSIONS::\";"
                    + " tmux list-sessions -F \"#{session_name}\(d)#{?session_attached,attached,detached}\(d)#{session_windows}\(d)#{t:session_last_attached}\" 2>/dev/null;"
                    + " echo \"::PANES::\";"
                    + " tmux list-panes -a -F \"#{session_name}\(d)#{window_name}\(d)#{window_active}\(d)#{pane_active}\(d)#{pane_current_command}\(d)#{pane_current_path}\" 2>/dev/null;"
                if !skipCaptures {
                    section += " echo \"::CAPTURES::\";"
                        + " for s in $(tmux list-sessions -F \"#{session_name}\" 2>/dev/null); do printf \"::CAPTURE:%s::\\n\" \"$s\"; tmux capture-pane -t \"$s:\" -p -e 2>/dev/null; done;"
                }
                tmuxParts.append(section)
            }

            parts.append(
                "echo \"::TMUX_START_\(nonce)::\";"
                + " if command -v tmux >/dev/null 2>&1; then"
                + " \(tmuxParts.joined(separator: " "))"
                + " fi;"
                + " echo \"::TMUX_END_\(nonce)::\""
            )
        }

        if discoverZellijBindings || !skipZellijSessions {
            var zellijParts: [String] = []
            if discoverZellijBindings {
                zellijParts.append(
                    "echo \"\(MultiplexerDiscoveryMarkers.bindingsStart(nonce))\";"
                    + " _zcf=\"\";"
                    + " for _candidate in \"${ZELLIJ_CONFIG_FILE:-}\" \"${ZELLIJ_CONFIG_DIR:+$ZELLIJ_CONFIG_DIR/config.kdl}\" \"$HOME/.config/zellij/config.kdl\" \"$HOME/Library/Application Support/org.Zellij-Contributors.Zellij/config.kdl\" \"/etc/zellij/config.kdl\"; do"
                    + " [ -n \"$_candidate\" ] || continue;"
                    + " if [ -f \"$_candidate\" ] && [ -r \"$_candidate\" ]; then _zcf=\"$_candidate\"; break; fi;"
                    + " done;"
                    + " if [ -n \"$_zcf\" ]; then printf \"\(MultiplexerDiscoveryMarkers.zellijConfigPathPrefix(nonce))%s::\\n\" \"$_zcf\"; head -c 131072 \"$_zcf\" 2>/dev/null; fi;"
                    + " echo \"\(MultiplexerDiscoveryMarkers.bindingsEnd(nonce))\";"
                )
            }

            if !skipZellijSessions {
                var section = "echo \"::SESSIONS::\";"
                    + " zellij list-sessions --no-formatting 2>/dev/null;"
                if !skipCaptures {
                    section += " _zv=$(zellij --version 2>/dev/null | grep -oE \"[0-9]+\\.[0-9]+\" | head -1);"
                        + " _zmaj=${_zv%%.*}; _zmin=${_zv#*.};"
                        + " if [ \"${_zmaj:-0}\" -gt 0 ] 2>/dev/null || [ \"${_zmin:-0}\" -ge 44 ] 2>/dev/null; then"
                        + " echo \"::CAPTURES::\";"
                        + " \(ZellijDiscoveryCommand.captureLoop)"
                        + " fi;"
                }
                zellijParts.append(section)
            }

            // Session listing works on any zellij version. Previews need
            // >= 0.44.0 (stdout dumps, --ansi, --pane-id, list-panes --json).
            parts.append(
                "echo \"::ZELLIJ_START_\(nonce)::\";"
                + " if command -v zellij >/dev/null 2>&1; then"
                + " \(zellijParts.joined(separator: " "))"
                + " fi;"
                + " echo \"::ZELLIJ_END_\(nonce)::\""
            )
        }

        if !skipHerdrSessions {
            // `herdr session list --json` is a tiny single line and works with
            // no server running. Agent enrichment (one `herdr agent list` per
            // running session) and focused-pane previews (`pane current` +
            // `pane read --raw`, herdr's capture-pane analogue) ride the
            // skipCaptures flag so the minimal overflow retry keeps session
            // enumeration only. The sed extracts names of running sessions
            // from the compact JSON; names are ASCII [A-Za-z0-9._-] so no
            // further quoting is needed.
            // Control-stream support shows in the subcommand's own help; a
            // herdr without it prints the general usage there instead.
            var section = "_hj=$(herdr session list --json 2>/dev/null);"
                + " echo \"::SESSIONS::\";"
                + " printf \"%s\\n\" \"$_hj\";"
                + " if herdr control --help 2>/dev/null | grep -q \"control stream\"; then echo \"::CONTROL:1::\"; else echo \"::CONTROL:0::\"; fi;"
            if !skipCaptures {
                let runningNames = "$(printf \"%s\\n\" \"$_hj\" | tr \"{}\" \"\\n\\n\" | sed -n \"/\\\"running\\\":true/s/.*\\\"name\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\")"
                section += " echo \"::AGENTS::\";"
                    + " for s in \(runningNames); do"
                    + " printf \"::AGENT:%s::\\n\" \"$s\";"
                    + " HERDR_SESSION=\"$s\" herdr agent list 2>/dev/null || true;"
                    + " done;"
                    + " echo \"::CAPTURES::\";"
                    + " for s in \(runningNames); do"
                    + " _hp=$(HERDR_SESSION=\"$s\" herdr pane current 2>/dev/null | sed -n \"s/.*\\\"pane_id\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\");"
                    + " if [ -n \"$_hp\" ]; then"
                    + " printf \"::CAPTURE:%s::\\n\" \"$s\";"
                    + " HERDR_SESSION=\"$s\" herdr pane read \"$_hp\" --source visible --raw 2>/dev/null || true;"
                    + " printf \"\\n\";"
                    + " fi;"
                    + " done;"
            }
            parts.append(
                "echo \"::HERDR_START_\(nonce)::\";"
                + " if command -v herdr >/dev/null 2>&1; then"
                + " \(section)"
                + " fi;"
                + " echo \"::HERDR_END_\(nonce)::\""
            )
        }

        if !skipZmxSessions {
            // `zmx list` probes every session socket serially, so one wedged
            // daemon costs a second of the budget this command shares with
            // tmux, zellij and herdr. Three choices bound that:
            //
            //  1. ONE `zmx list`. The capture loop derives its names from that
            //     same output rather than a second `--short` call, which would
            //     pay for every wedged daemon twice. `grep -F` on a tab before
            //     `pid=` keeps only real rows; `cut -f1` yields the bare name.
            //  2. NO tight `timeout` on the list. It emits nothing until every
            //     probe finishes, so a timeout that fires costs the full wall
            //     clock AND returns nothing -- indistinguishable to the user
            //     from zmx not being installed. The 5 s backstop only catches a
            //     genuine hang.
            //  3. `timeout 2` on each `zmx history`, where truncation costs one
            //     preview rather than the whole result.
            //
            // Session names may contain spaces, `*`, `?` and quotes, so the loop
            // reads them with `IFS= read -r` rather than `for s in $(...)`,
            // which would split and glob them. herdr can use that idiom because
            // its names are constrained; zmx's are not.
            //
            // `ZMX_SESSION_PREFIX=` on every call: `zmx list` reports real
            // socket names but every other subcommand prepends the variable, so
            // an exported prefix would silently point `history` at a different
            // session. The same neutralisation is applied in
            // `TerminalView+Session.attachToSession` and
            // `SSHConfig.zmxExecCommandLine`.
            var section = "_zt=\"\"; command -v timeout >/dev/null 2>&1 && _zt=\"timeout 2\";"
                + " _zl=$(ZMX_SESSION_PREFIX= ${_zt:+timeout 5} zmx list 2>/dev/null);"
                + " echo \"::SESSIONS::\";"
                + " printf \"%s\\n\" \"$_zl\";"
            if !skipCaptures {
                // NOTE: the "\t" below is a REAL tab in the emitted shell, which
                // is what makes it match a field boundary rather than the letter
                // t. Do not "tidy" it into an escape sequence.
                section += " echo \"::CAPTURES::\";"
                    + " printf \"%s\\n\" \"$_zl\" | grep -F \"\tpid=\""
                    + " | sed \"s/^[^=]*=//\" | cut -f1 | head -n 8 |"
                    + " while IFS= read -r s; do"
                    + " printf \"::CAPTURE:%s::\\n\" \"$s\";"
                    + " ZMX_SESSION_PREFIX= $_zt zmx history \"$s\" --vt 2>/dev/null | tail -n 200 || true;"
                    + " printf \"\\n\";"
                    + " done;"
            }
            parts.append(
                "echo \"::ZMX_START_\(nonce)::\";"
                + " if command -v zmx >/dev/null 2>&1; then"
                + " \(section)"
                + " fi;"
                + " echo \"::ZMX_END_\(nonce)::\""
            )
        }

        let body = parts.joined(separator: " ; ")
        return ("sh -lc '\(SSHConfig.remoteExecPathPrefix)\(body)'", nonce)
    }
}

#if STANDALONE && targetEnvironment(macCatalyst)
// MARK: - Local Helper Runner

extension SessionDiscoveryRunner {

    /// Discover sessions by executing the combined command locally via rootshell-helper.
    static func discoverLocally(
        workingDirectory: String?,
        skipTmuxSessions: Bool = false,
        skipZellijSessions: Bool = false,
        skipHerdrSessions: Bool = false,
        skipZmxSessions: Bool = false,
        discoverTmuxBindings: Bool = true,
        discoverZellijBindings: Bool = true
    ) async throws -> SessionDiscoveryResult {
        logger.info("Running local session discovery via helper")

        guard await HelperConnection.shared.ensureHelperRunning() else {
            throw TmuxDiscoveryError.notConnected
        }

        let (command, nonce) = SessionDiscoveryCommand.command(
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings
        )

        let result = try await HelperConnection.shared.executeCommand(
            command: command,
            workingDirectory: workingDirectory,
            timeout: 7,
            // The same bound the SSH path applies; a local host's captures are
            // no smaller, and the parser tolerates a truncated reply.
            maxOutputBytes: Self.maxDiscoveryResponseBytes
        )

        if result.timedOut {
            throw TmuxDiscoveryError.timeout
        }

        let output = result.output
        return SessionDiscoveryParser.parse(
            output: output,
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings,
            nonce: nonce
        )
    }
}
#endif

// MARK: - Combined Parser

enum SessionDiscoveryParser {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "SessionDiscoveryParser"
    )

    /// Parse combined output, extracting tmux, zellij, herdr, and zmx sections independently.
    /// Nonce-tagged markers ensure captured terminal content cannot cause false matches.
    static func parse(
        output: String,
        skipTmuxSessions: Bool,
        skipZellijSessions: Bool,
        skipHerdrSessions: Bool,
        skipZmxSessions: Bool,
        discoverTmuxBindings: Bool,
        discoverZellijBindings: Bool,
        nonce: String
    ) -> SessionDiscoveryResult {
        var tmuxSessions: [TmuxSessionInfo] = []
        var zellijSessions: [ZellijSessionInfo] = []
        var herdrSessions: [HerdrSessionInfo] = []
        var zmxSessions: [ZmxSessionInfo] = []
        var swipeBindings = MultiplexerSwipeBindings()

        // Extract and parse tmux section
        if (!skipTmuxSessions || discoverTmuxBindings),
           let tmuxStart = output.range(of: "::TMUX_START_\(nonce)::"),
           let tmuxEnd = output.range(of: "::TMUX_END_\(nonce)::") {
            let tmuxOutput = String(output[tmuxStart.upperBound..<tmuxEnd.lowerBound])
            if !skipTmuxSessions {
                tmuxSessions = TmuxDiscoveryParser.parse(output: tmuxOutput)
            }
            if discoverTmuxBindings {
                swipeBindings = swipeBindings.merging(TmuxSwipeBindingParser.parse(output: tmuxOutput, nonce: nonce))
            }
        }

        // Extract and parse zellij section
        if (!skipZellijSessions || discoverZellijBindings),
           let zellijStart = output.range(of: "::ZELLIJ_START_\(nonce)::"),
           let zellijEnd = output.range(of: "::ZELLIJ_END_\(nonce)::") {
            let zellijOutput = String(output[zellijStart.upperBound..<zellijEnd.lowerBound])
            if !skipZellijSessions {
                zellijSessions = ZellijDiscoveryParser.parse(output: zellijOutput)
            }
            if discoverZellijBindings {
                swipeBindings = swipeBindings.merging(ZellijSwipeBindingParser.parse(output: zellijOutput, nonce: nonce))
            }
        }

        // Extract and parse herdr section
        if !skipHerdrSessions,
           let herdrStart = output.range(of: "::HERDR_START_\(nonce)::"),
           let herdrEnd = output.range(of: "::HERDR_END_\(nonce)::") {
            let herdrOutput = String(output[herdrStart.upperBound..<herdrEnd.lowerBound])
            herdrSessions = HerdrDiscoveryParser.parse(output: herdrOutput)
        }

        // Extract and parse zmx section
        if !skipZmxSessions,
           let zmxStart = output.range(of: "::ZMX_START_\(nonce)::"),
           let zmxEnd = output.range(of: "::ZMX_END_\(nonce)::") {
            let zmxOutput = String(output[zmxStart.upperBound..<zmxEnd.lowerBound])
            zmxSessions = ZmxDiscoveryParser.parse(output: zmxOutput)
        }

        return merge(
            tmux: tmuxSessions,
            zellij: zellijSessions,
            herdr: herdrSessions,
            zmx: zmxSessions,
            swipeBindings: swipeBindings
        )
    }

    private static func merge(
        tmux: [TmuxSessionInfo],
        zellij: [ZellijSessionInfo],
        herdr: [HerdrSessionInfo],
        zmx: [ZmxSessionInfo],
        swipeBindings: MultiplexerSwipeBindings
    ) -> SessionDiscoveryResult {
        var types = Set<MultiplexerType>()
        var sessions: [MultiplexerSession] = []

        if !tmux.isEmpty {
            types.insert(.tmux)
            sessions.append(contentsOf: tmux.map { MultiplexerSession.from(tmux: $0) })
        }

        if !zellij.isEmpty {
            types.insert(.zellij)
            sessions.append(contentsOf: zellij.map { MultiplexerSession.from(zellij: $0) })
        }

        if !herdr.isEmpty {
            types.insert(.herdr)
            sessions.append(contentsOf: herdr.map { MultiplexerSession.from(herdr: $0) })
        }

        if !zmx.isEmpty {
            types.insert(.zmx)
            sessions.append(contentsOf: zmx.map { MultiplexerSession.from(zmx: $0) })
        }

        let order = SettingsStore.shared.value(Settings.Multiplexer.sessionDiscoverySortOrder)
        sessions.sort(by: order.compare)

        let count = sessions.count
        let typeNames = types.map(\.rawValue).sorted().joined(separator: ", ")
        let bindingCount = [
            swipeBindings.tmuxNextWindow,
            swipeBindings.tmuxPreviousWindow,
            swipeBindings.tmuxNextSession,
            swipeBindings.tmuxPreviousSession,
            swipeBindings.zellijNextTab,
            swipeBindings.zellijPreviousTab,
        ].compactMap { $0 }.count
        logger.info("Session discovery complete: \(count) sessions (\(typeNames)), \(bindingCount) resolved bindings")

        return SessionDiscoveryResult(sessions: sessions, types: types, swipeBindings: swipeBindings)
    }
}

// MARK: - Combined Runner

@MainActor
enum SessionDiscoveryRunner {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "SessionDiscovery"
    )

    /// Discover sessions using an existing CitadelSSHSession's client.
    static func discover(
        using session: CitadelSSHSession,
        skipTmuxSessions: Bool = false,
        skipZellijSessions: Bool = false,
        skipHerdrSessions: Bool = false,
        skipZmxSessions: Bool = false,
        discoverTmuxBindings: Bool = true,
        discoverZellijBindings: Bool = true
    ) async throws -> SessionDiscoveryResult {
        guard let client = session.client else {
            throw TmuxDiscoveryError.notConnected
        }
        return try await execute(
            on: client,
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings
        )
    }

    /// Discover sessions by creating a temporary SSH connection.
    ///
    /// `onKeyboardInteractiveChallenge` is threaded into the temporary connection
    /// so a PAM/OTP/explicit-keyboard-interactive host can prompt (via the shared
    /// sheet) just like the main bootstrap, rather than silently failing.
    static func discover(
        using config: SSHConfig,
        skipTmuxSessions: Bool = false,
        skipZellijSessions: Bool = false,
        skipHerdrSessions: Bool = false,
        skipZmxSessions: Bool = false,
        discoverTmuxBindings: Bool = true,
        discoverZellijBindings: Bool = true,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> SessionDiscoveryResult {
        logger.info("Creating temporary SSH connection for session discovery")

        // Strict: the main session already validated this host, so its saved
        // key passes silently; unknown or changed keys reject.
        let (client, jumpClient) = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: nil,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )

        defer {
            Task { try? await client.close() }
            if let jumpClient {
                Task { try? await jumpClient.close() }
            }
        }

        return try await execute(
            on: client,
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings
        )
    }

    /// Defense-in-depth cap on total exec response. Sized to comfortably hold
    /// the 128 KiB zellij config head-cap plus tmux list-keys/list-sessions/
    /// list-panes/capture-pane output and discovery markers. If a remote
    /// bypasses the shell-side bound, Citadel aborts the exec early with
    /// `CitadelError.commandOutputTooLarge` and discovery retries with a
    /// minimal command shape.
    private static let maxDiscoveryResponseBytes = 256 * 1024

    /// Execute a combined discovery command, retrying with a minimal shape if
    /// the response exceeds `maxDiscoveryResponseBytes`. Session enumeration is
    /// preserved across retries; only the heavy parts (capture-pane/dump-screen
    /// loops and binding discovery) are dropped on overflow.
    private static func execute(
        on client: SSHClient,
        skipTmuxSessions: Bool,
        skipZellijSessions: Bool,
        skipHerdrSessions: Bool,
        skipZmxSessions: Bool,
        discoverTmuxBindings: Bool,
        discoverZellijBindings: Bool
    ) async throws -> SessionDiscoveryResult {
        do {
            return try await runDiscovery(
                on: client,
                skipTmuxSessions: skipTmuxSessions,
                skipZellijSessions: skipZellijSessions,
                skipHerdrSessions: skipHerdrSessions,
                skipZmxSessions: skipZmxSessions,
                discoverTmuxBindings: discoverTmuxBindings,
                discoverZellijBindings: discoverZellijBindings,
                skipCaptures: false
            )
        } catch CitadelError.commandOutputTooLarge {
            let cap = maxDiscoveryResponseBytes
            logger.notice("Discovery output exceeded \(cap) bytes; retrying without captures or bindings")
        }

        // Minimal retry: list sessions only. Drops capture-pane/dump-screen
        // loops, herdr agent probes, and binding discovery so session
        // enumeration still reaches the UI even when the full command would
        // overflow.
        do {
            return try await runDiscovery(
                on: client,
                skipTmuxSessions: skipTmuxSessions,
                skipZellijSessions: skipZellijSessions,
                skipHerdrSessions: skipHerdrSessions,
                skipZmxSessions: skipZmxSessions,
                discoverTmuxBindings: false,
                discoverZellijBindings: false,
                skipCaptures: true
            )
        } catch CitadelError.commandOutputTooLarge {
            logger.notice("Minimal discovery still exceeded cap; giving up")
            return SessionDiscoveryResult(
                sessions: [],
                types: [],
                swipeBindings: MultiplexerSwipeBindings()
            )
        }
    }

    /// Execute a single combined discovery command with timeout.
    private static func runDiscovery(
        on client: SSHClient,
        skipTmuxSessions: Bool,
        skipZellijSessions: Bool,
        skipHerdrSessions: Bool,
        skipZmxSessions: Bool,
        discoverTmuxBindings: Bool,
        discoverZellijBindings: Bool,
        skipCaptures: Bool
    ) async throws -> SessionDiscoveryResult {
        let (command, nonce) = SessionDiscoveryCommand.command(
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings,
            skipCaptures: skipCaptures
        )

        let cap = maxDiscoveryResponseBytes
        let output: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @Sendable in
                let buf = try await client.executeCommand(command, maxResponseSize: cap)
                // Tolerant UTF-8 decode: replaces any invalid sequences (e.g.
                // from a mid-scalar truncation by `head -c`) with U+FFFD so a
                // partial response still parses instead of collapsing to "".
                let data = Data(buffer: buf)
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask { @Sendable in
                try await Task.sleep(for: .seconds(7))
                throw TmuxDiscoveryError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        return SessionDiscoveryParser.parse(
            output: output,
            skipTmuxSessions: skipTmuxSessions,
            skipZellijSessions: skipZellijSessions,
            skipHerdrSessions: skipHerdrSessions,
            skipZmxSessions: skipZmxSessions,
            discoverTmuxBindings: discoverTmuxBindings,
            discoverZellijBindings: discoverZellijBindings,
            nonce: nonce
        )
    }
}
