//
//  MuxSessionDetach.swift
//  rootshell
//
//  Unified "leave the multiplexer, keep the session" detach for every
//  supported multiplexer. tmux -CC uses the existing graceful control-mode
//  detach; raw / passthrough attachments type each multiplexer’s native
//  detach chord into the pane PTY (same idea as iTerm2’s detach: leave
//  cleanly and reattach later via session discovery).
//

import Foundation
import UIKit
import os

/// Classifies and performs a session detach for a terminal pane or tmux
/// control-mode gateway.
@MainActor
enum MuxSessionDetach {
    /// Posted on `.closeSplit` so MainView tears the pane down with
    /// `.muxDetach` (leave zmx running) instead of `.userClose` (`zmx kill`).
    static let leaveMuxSessionUserInfoKey = "leaveMuxSession"

    /// How this attachment should leave the multiplexer.
    enum Kind: Equatable {
        /// Graceful `detach-client` through the tmux -CC viewer.
        case tmuxControlMode
        /// Native key chord typed into the pane (raw / passthrough).
        case keySequence(MultiplexerType)
    }

    struct Attachment: Equatable {
        let kind: Kind
        let sessionName: String?
        let displayName: String
    }

    /// Result of attempting a detach.
    enum Outcome: Equatable {
        case detached(Attachment)
        case none
    }

    /// Native detach chords. Prefix-based tools need a short settle so the
    /// multiplexer sees the follow-up key as a command, not literal input.
    private static let prefixSettleDelay: TimeInterval = 0.08

    /// After the detach chord, wait for the remote client to exit before
    /// tearing down the local tab (mirrors MultiplexerExposeFeed’s zmx timing).
    private static func postDetachSettleDelay(for type: MultiplexerType) -> TimeInterval {
        switch type {
        case .zmx:
            // zmx’s detach (Ctrl-\) is asynchronous; closing too early HUP’s the
            // still-attached client instead of a clean leave.
            return 0.45
        case .tmux, .zellij, .herdr:
            return 0.2
        }
    }

    /// Inspect a terminal for a detachable multiplexer attachment.
    static func attachment(on terminal: Ghostty.TerminalView) -> Attachment? {
        if terminal.tmuxController?.isActive == true || terminal.isTmuxGatewaySurfaceActive {
            let name = terminal.tmuxController?.currentSessionName
            return Attachment(
                kind: .tmuxControlMode,
                sessionName: name,
                displayName: displayName(for: .tmux, sessionName: name)
            )
        }
        if let binding = terminal.passthroughMultiplexer {
            return Attachment(
                kind: .keySequence(binding.type),
                sessionName: binding.sessionName,
                displayName: displayName(for: binding.type, sessionName: binding.sessionName)
            )
        }
        if let binding = terminal.rawMultiplexer {
            return Attachment(
                kind: .keySequence(binding.type),
                sessionName: binding.sessionName,
                displayName: displayName(for: binding.type, sessionName: binding.sessionName)
            )
        }
        return nil
    }

    /// Resolve a detach target for a tab: prefer the tab’s own panes, then a
    /// tmux -CC controller reachable from a window tab (so Detach works even
    /// when the gateway tab is auto-hidden).
    static func attachment(
        for tab: TabModel,
        tmuxController: (TabModel) -> TmuxController?
    ) -> Attachment? {
        for view in tab.splitTree.terminalLeaves {
            if let attachment = attachment(on: view), attachment.kind != .tmuxControlMode {
                return attachment
            }
        }
        if let controller = tmuxController(tab), controller.isActive {
            let name = controller.currentSessionName
            return Attachment(
                kind: .tmuxControlMode,
                sessionName: name,
                displayName: displayName(for: .tmux, sessionName: name)
            )
        }
        for view in tab.splitTree.terminalLeaves {
            if let attachment = attachment(on: view) {
                return attachment
            }
        }
        return nil
    }

    /// Detach the multiplexer on `terminal`. For tmux -CC this routes through
    /// the controller; otherwise the native detach chord is typed into the PTY.
    @discardableResult
    static func detach(on terminal: Ghostty.TerminalView) -> Outcome {
        guard let attachment = attachment(on: terminal) else { return .none }
        switch attachment.kind {
        case .tmuxControlMode:
            // Banner is posted inside requestGracefulDetach (via sendTmuxDetach).
            terminal.sendTmuxDetach()
            return .detached(attachment)
        case .keySequence(let type):
            performKeySequenceDetach(on: terminal, type: type)
            announce(attachment, reconnectFrom: terminal)
            return .detached(attachment)
        }
    }

    /// Detach whatever multiplexer backs `tab` (window tabs resolve to their
    /// gateway controller for tmux -CC).
    @discardableResult
    static func detach(
        tab: TabModel,
        tmuxController: (TabModel) -> TmuxController?
    ) -> Outcome {
        // Prefer an in-pane raw/passthrough binding on this tab before falling
        // through to the tmux gateway — a split that hosts zmx beside a tmux
        // pane should detach the focused attachment, not the whole gateway.
        if let focused = tab.focusedTerminal,
           let attachment = attachment(on: focused),
           attachment.kind != .tmuxControlMode {
            return detach(on: focused)
        }

        if let controller = tmuxController(tab), controller.isActive {
            let name = controller.currentSessionName
            let attachment = Attachment(
                kind: .tmuxControlMode,
                sessionName: name,
                displayName: displayName(for: .tmux, sessionName: name)
            )
            // Banner is posted inside requestGracefulDetach.
            controller.requestGracefulDetach(source: "keybind")
            return .detached(attachment)
        }

        for view in tab.splitTree.terminalLeaves {
            if attachment(on: view) != nil {
                return detach(on: view)
            }
        }
        return .none
    }

    /// Detach every distinct multiplexer attachment among `tabs`.
    /// tmux -CC gateways are detached once even when many window tabs share them.
    @discardableResult
    static func detachAll(
        tabs: [TabModel],
        tmuxController: (TabModel) -> TmuxController?
    ) -> [Attachment] {
        var detached: [Attachment] = []
        var seenGateways = Set<ObjectIdentifier>()

        for tab in tabs {
            if let controller = tmuxController(tab), controller.isActive {
                let id = ObjectIdentifier(controller)
                guard seenGateways.insert(id).inserted else { continue }
                let name = controller.currentSessionName
                let attachment = Attachment(
                    kind: .tmuxControlMode,
                    sessionName: name,
                    displayName: displayName(for: .tmux, sessionName: name)
                )
                // Banner is posted inside requestGracefulDetach.
                controller.requestGracefulDetach(source: "detach-all")
                detached.append(attachment)
                continue
            }

            for view in tab.splitTree.terminalLeaves {
                guard let attachment = attachment(on: view),
                      attachment.kind != .tmuxControlMode else { continue }
                if case .detached(let done) = detach(on: view) {
                    detached.append(done)
                }
            }
        }

        if !detached.isEmpty {
            let summary: String
            if detached.count == 1 {
                summary = String(
                    localized: "Detached from \(detached[0].displayName). Session keeps running.",
                    comment: "Accessibility announcement after detaching one multiplexer"
                )
            } else {
                summary = String(
                    localized: "Detached from \(detached.count) multiplexer sessions. They keep running.",
                    comment: "Accessibility announcement after detaching multiple multiplexers"
                )
            }
            UIAccessibility.post(notification: .announcement, argument: summary)
        }
        return detached
    }

    // MARK: - Key sequences

    /// Type the multiplexer’s native detach chord (when needed), drop local
    /// bindings, then close the pane/tab — same journey as iTerm2’s Shell →
    /// tmux → Detach (remote session keeps running; local UI goes away).
    static func performKeySequenceDetach(
        on terminal: Ghostty.TerminalView,
        type: MultiplexerType
    ) {
        let steps = keySteps(for: type)
        let settle = postDetachSettleDelay(for: type)
        Task { @MainActor [weak terminal] in
            guard let terminal else { return }

            // zmx: closing the client is the supported detach. Do not type
            // Ctrl-\ first — pairing that with an immediate SSH teardown races
            // the client exit and can destroy the session instead of leaving
            // it for `zmx attach <name>` on reconnect. Mark leaveMuxSession so
            // cleanup uses `.muxDetach` and skips `zmx kill` (Close Tab kills).
            if steps.isEmpty {
                clearLocalBinding(on: terminal)
                postCloseLeavingMuxSession(terminal)
                return
            }

            for (index, step) in steps.enumerated() {
                terminal.sendUserInput(step)
                if index < steps.count - 1 {
                    try? await Task.sleep(for: .seconds(Self.prefixSettleDelay))
                }
            }
            try? await Task.sleep(for: .seconds(settle))
            clearLocalBinding(on: terminal)
            // Close this attachment’s UI (split or whole tab). closeSplit routes
            // by the posted view, so a background-tab detach still targets the
            // right pane even if the user switched away during the settle.
            postCloseLeavingMuxSession(terminal)
        }
    }

    /// Close the local pane without destroying a zmx session.
    private static func postCloseLeavingMuxSession(_ terminal: Ghostty.TerminalView) {
        NotificationCenter.default.post(
            name: .closeSplit,
            object: terminal,
            userInfo: [leaveMuxSessionUserInfoKey: true]
        )
    }

    /// True when Close Tab / Close Split should destroy a live zmx session
    /// before tearing down the local client (closing the client alone is detach).
    static func hasZmxSessionToDestroy(on terminal: Ghostty.TerminalView) -> Bool {
        guard let binding = terminal.passthroughMultiplexer,
              binding.type == .zmx,
              let name = binding.sessionName,
              SSHConfig.zmxKillCommandLine(sessionName: name) != nil else {
            return false
        }
        return true
    }

    /// Destroy the bound zmx session, preferring an in-band probe on the live
    /// tsshd/Citadel connection (no re-auth) so Bitwarden/agent keys do not
    /// need a second approval. Falls back to a headless SSH exec.
    ///
    /// Must run **before** session teardown — probe uses the live transport,
    /// and closing the client alone is zmx’s detach path.
    static func destroyZmxSessionIfNeeded(on terminal: Ghostty.TerminalView) async {
        let binding = terminal.passthroughMultiplexer
        guard binding?.type == .zmx,
              let name = binding?.sessionName,
              let command = SSHConfig.zmxKillCommandLine(sessionName: name) else {
            return
        }

        // Snapshot the live transport before clearing bindings / any close
        // side effects — closeTab may already be removing us from the model.
        let trzsz = terminal.session as? TrzszSession
        let connectionConfig = terminal.connectionConfig

        // Drop the binding so a concurrent detach/close path cannot double-kill.
        terminal.passthroughMultiplexer = nil
        AgentAttentionCenter.shared.topologyDidChange()

        // 1) Live tsshd probe — same connection, no re-auth.
        if let trzsz {
            do {
                _ = try await trzsz.runProbeCommand(command)
                Ghostty.logger.info("zmx kill via tsshd probe succeeded for \(name, privacy: .public)")
                return
            } catch {
                let detail = error.localizedDescription
                Ghostty.logger.info("zmx kill via tsshd probe failed for \(name, privacy: .public): \(detail, privacy: .public)")
            }
        }

        // 2) Headless SSH fallback (new connection — may prompt the agent).
        if let ssh = connectionConfig.sshConfigForHistory
            ?? connectionConfig.underlyingSSHConfig {
            do {
                _ = try await HeadlessSSHExecutor.execute(
                    config: ssh,
                    command: command,
                    timeout: 8,
                    logLabel: "[zmx-kill]"
                )
                Ghostty.logger.info("zmx kill via headless SSH succeeded for \(name, privacy: .public)")
            } catch {
                let detail = error.localizedDescription
                Ghostty.logger.error("zmx kill for \(name, privacy: .public) failed: \(detail, privacy: .public)")
            }
            return
        }

        #if os(macOS) && !targetEnvironment(macCatalyst)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        #else
        Ghostty.logger.error("zmx kill skipped for local session \(name, privacy: .public) (no Catalyst Process)")
        #endif
    }

    /// Fire-and-forget wrapper for call sites that cannot await. Prefer
    /// ``destroyZmxSessionIfNeeded(on:)`` before teardown when possible.
    static func scheduleZmxSessionDestroyIfNeeded(on terminal: Ghostty.TerminalView) {
        guard hasZmxSessionToDestroy(on: terminal) else { return }
        Task { @MainActor in
            await destroyZmxSessionIfNeeded(on: terminal)
        }
    }

    /// Bytes to type, in order. Multi-step sequences are prefix then command.
    /// Empty means “close the local client only” (zmx).
    static func keySteps(for type: MultiplexerType) -> [Data] {
        switch type {
        case .tmux:
            // Default prefix Ctrl-b, then d.
            return [Data([0x02]), Data("d".utf8)]
        case .zellij:
            // Session mode Ctrl-o, then d.
            return [Data([0x0F]), Data("d".utf8)]
        case .herdr:
            // Prefix Ctrl-b, then q.
            return [Data([0x02]), Data("q".utf8)]
        case .zmx:
            // No chord: zmx treats closing the client window as detach
            // (https://zmx.sh/). Ctrl-\ remains available for manual use.
            return []
        }
    }

    private static func clearLocalBinding(on terminal: Ghostty.TerminalView) {
        var changed = false
        if terminal.rawMultiplexer != nil {
            terminal.rawMultiplexer = nil
            changed = true
        }
        if terminal.passthroughMultiplexer != nil {
            terminal.passthroughMultiplexer = nil
            changed = true
        }
        if changed {
            AgentAttentionCenter.shared.topologyDidChange()
        }
    }

    private static func displayName(for type: MultiplexerType, sessionName: String?) -> String {
        if let sessionName, !sessionName.isEmpty {
            return "\(type.rawValue) “\(sessionName)”"
        }
        return type.rawValue
    }

    /// Posted by `TmuxController.requestGracefulDetach` so every tmux -CC leave
    /// path (context-menu confirm, dashboard, ESC, keybind, tab-close) shows the
    /// same reconnect banner zmx already got via `detach(on:)`.
    static func notifyControlModeDetached(
        sessionName: String?,
        windowId: String,
        terminal: Ghostty.TerminalView?
    ) {
        let attachment = Attachment(
            kind: .tmuxControlMode,
            sessionName: sessionName,
            displayName: displayName(for: .tmux, sessionName: sessionName)
        )
        announce(attachment, reconnectFrom: terminal, windowId: windowId)
    }

    private static func announce(
        _ attachment: Attachment,
        reconnectFrom terminal: Ghostty.TerminalView? = nil,
        windowId: String? = nil
    ) {
        let message = String(
            localized: "Detached from \(attachment.displayName). Session keeps running.",
            comment: "Accessibility announcement after detaching a multiplexer"
        )
        UIAccessibility.post(notification: .announcement, argument: message)
        postReconnectOffer(attachment: attachment, terminal: terminal, windowId: windowId)
    }

    private static func postReconnectOffer(
        attachment: Attachment,
        terminal: Ghostty.TerminalView?,
        windowId: String? = nil
    ) {
        var userInfo: [AnyHashable: Any] = ["displayName": attachment.displayName]
        if let windowId = windowId ?? terminal?.windowId {
            userInfo["windowId"] = windowId
        }
        if let terminal,
           let ssh = terminal.connectionConfig.sshConfigForHistory
            ?? terminal.connectionConfig.underlyingSSHConfig {
            let proto: ConnectionProtocol
            switch terminal.connectionConfig {
            case .mosh, .shellLaunchedMosh:
                proto = .mosh
            case .trzsz, .shellLaunchedTrzsz:
                proto = .trzsz
            default:
                proto = .ssh
            }
            userInfo["offer"] = MuxSessionResume.ReconnectOffer(
                displayName: attachment.displayName,
                sshConfig: ssh,
                connectionProtocol: proto,
                profileID: terminal.sourceProfileID
            )
        }
        // object: nil — do not require the pane to still be in the tab tree.
        // tmux -CC prune tears windows down as soon as control mode ends.
        NotificationCenter.default.post(name: .muxSessionDidDetach, object: nil, userInfo: userInfo)
    }
}
