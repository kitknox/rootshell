//
//  TerminalView+Session.swift
//  rootshell
//
//  Session setup, callbacks, and monitoring for SSH, Kubernetes, Console, EC2, and Local sessions
//  Extracted from TerminalView.swift for build parallelization
//

import UIKit
import os
import GhosttyKit

private extension String {
    /// Escapes characters that remain active inside shell double quotes.
    var shellEscapedForDoubleQuotes: String {
        let quoted = LoginShellCommand.doubleQuoted(self)
        return String(quoted.dropFirst().dropLast())
    }
}

private extension Ghostty.TerminalView {
    func removeReceivedTransferTab() {
        guard let tabId = containingTabID else { return }
        NotificationCenter.default.post(
            name: .trzszTransferLeafShouldRemove,
            object: nil,
            userInfo: ["tabId": tabId, "leafId": uuid]
        )
    }
}

// MARK: - Session Setup

extension Ghostty.TerminalView {

    func setupPTYAndShell() {
        guard !sessionController.startSession() else { return }

        guard surface != nil else {
            Ghostty.logger.error("Cannot setup transfer session: surface is nil")
            return
        }
        switch connectionConfig {
        case .trzszTransfer(let ticketID, _, _):
            // The receive coordinator deposited the payload into the inbox
            // when the user accepted the offer. Pull it out, build a session
            // configured from the payload's SSHConfig, and kick off attach
            // in the trailing async Task. Until attach succeeds the surface
            // shows the spinner like any other resume.
            guard let payload = TrzszTransferInbox.shared.consumePayload(ticketID) else {
                Ghostty.logger.error("Trzsz transfer ticket \(ticketID.uuidString.prefix(8)) missing from inbox")
                writeToGhostty(string: "\r\n❌ Transfer payload missing — the offer may have expired.\r\n")
                removeReceivedTransferTab()
                return
            }

            let pty = TerminalPTY()
            self.pty = pty
            self.activeTransferTicketID = ticketID
            let trzszConfig = TrzszConfig(
                sshConfig: payload.sshConfig,
                transportMode: payload.transportMode
            )
            let trzszSession = TrzszSession(config: trzszConfig, pty: pty, terminalId: self.uuid)

            wireStandardSessionError(on: trzszSession, prefix: "Roam Error")
            wireAgentForwardingApprovals(on: trzszSession)
            trzszSession.onStateChange = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .running = state {
                        self.connectionProgress.reset()
                    }
                }
            }

            // Replay the originator's scrollback BEFORE session output starts
            // so the user sees recent history as soon as the tab appears. If
            // a TUI was active, switch to the alternate screen first and
            // replay that snapshot to avoid flicker on attach.
            if let alt = payload.alternateScreen, !alt.isEmpty {
                writeToGhostty(string: "\u{1b}[?1049h")
                if let altText = String(data: alt, encoding: .utf8) {
                    writeToGhostty(string: altText)
                }
            } else if !payload.primaryScrollback.isEmpty {
                if let primaryText = String(data: payload.primaryScrollback, encoding: .utf8) {
                    writeToGhostty(string: primaryText)
                }
            }

            self.session = trzszSession
            NotificationCenter.default.post(name: .ghosttySessionDidChange, object: self)
            sessionController.adopt(trzszSession, pty: pty)

            // Switch the connectionConfig to a normal .trzsz(config) once
            // attach succeeds so subsequent splits, history, and tab-menu
            // predicates treat this like any other roam session.
            let resolvedConfig: ConnectionConfig = .trzsz(trzszConfig)

            var attachTask: Task<Void, Never>?
            let didRegisterCancel = TrzszTransferInbox.shared.registerCancelHandler(ticketID) { [weak self, trzszSession] in
                guard !trzszSession.isRunning else { return false }
                attachTask?.cancel()
                trzszSession.cancelTransferAttach()
                self?.activeTransferTicketID = nil
                self?.transferAttachTask = nil
                self?.removeReceivedTransferTab()
                return true
            }
            guard didRegisterCancel else {
                trzszSession.cancelTransferAttach()
                removeReceivedTransferTab()
                return
            }

            attachTask = Task { @MainActor [weak self] in
                guard let self else {
                    TrzszTransferInbox.shared.complete(ticketID, result: .failure(TrzszTransferError.cancelled))
                    return
                }
                defer {
                    self.transferAttachTask = nil
                }
                do {
                    try await trzszSession.attachFromTransferPayload(payload)
                    self.activeTransferTicketID = nil
                    self.connectionConfig = resolvedConfig
                    NotificationCenter.default.post(name: .terminalConnectionConfigChanged, object: self)
                    self.sessionController.startTerminalResponseMonitoring(for: trzszSession)
                    self.sessionController.startConnectionSuccessTimer(connectionConfig: self.connectionConfig)
                    TrzszTransferInbox.shared.complete(ticketID, result: .success(()))
                    Ghostty.logger.info("Trzsz transfer attach succeeded for ticket \(ticketID.uuidString.prefix(8))")
                } catch is CancellationError {
                    Ghostty.logger.info("Trzsz transfer attach cancelled for ticket \(ticketID.uuidString.prefix(8))")
                    self.activeTransferTicketID = nil
                    trzszSession.cancelTransferAttach()
                    TrzszTransferInbox.shared.complete(ticketID, result: .failure(TrzszTransferError.cancelled))
                    self.removeReceivedTransferTab()
                } catch {
                    let msg = error.trzszTransferDisplayDescription
                    Ghostty.logger.error("Trzsz transfer attach failed: \(msg)")
                    self.writeToGhostty(string: "\r\n❌ Transfer attach failed: \(msg)\r\n")
                    self.error = error
                    self.activeTransferTicketID = nil
                    trzszSession.cancelTransferAttach()
                    TrzszTransferInbox.shared.complete(ticketID, result: .failure(error))
                }
            }
            self.transferAttachTask = attachTask
            return
        default:
            assertionFailure("Unhandled session config after TerminalSessionController declined startup")
            return
        }
    }

    /// Start a restored session after the terminal was loaded from persistence
    /// This is called when the user initiates reconnection for a restored terminal
    func startRestoredSession(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(sessionController.startRestoredSession())
    }
}

// MARK: - Deferred Scrollback Restore

extension Ghostty.TerminalView {

    /// Restores deferred scrollback after connection animation completes.
    /// Called from `.running` state handlers. Idempotent — safe to call multiple times.
    ///
    /// - Parameter trailer: Optional bytes to write **immediately after** the saved
    ///   scrollback content and **before** the gate releases buffered live output.
    ///   Used to atomically restore terminal modes (mouse capture, alt screen,
    ///   etc.) that the resumed remote TUI expects to be active. The trailer is
    ///   processed by ghostty in-order with the scrollback, so no live data can
    ///   race ahead of it.
    ///
    /// When no scrollback restore is pending (e.g. same-terminal trzsz reconnect
    /// where `wasResumed` is true but the surface was never persisted, or the
    /// layout-deferred restore already ran), the trailer is still written
    /// directly to the buffered writer so resumed sessions don't silently lose
    /// their mode-restore sequences. The post-drain render+mouse-capture sync
    /// is also scheduled in that fallback path.
    func restoreScrollbackAfterAnimation(trailer: Data? = nil) {
        if restoredWasTmuxGateway {
            // The gateway is hidden while its projected panes are rebuilt from
            // authoritative tmux captures. Do not replay its saved ANSI or mode
            // trailer: pipe drain does not acknowledge parser consumption, so
            // those bytes could cross the asynchronous control-mode boundary.
            pendingScrollbackRestore = false
            releaseRestoredTmuxOutputGateWhenViewerIsArmed()
            return
        }
        if pendingScrollbackRestore {
            pendingScrollbackRestore = false
            ScrollbackPersistenceManager.shared.restoreScrollback(
                for: self,
                trailer: trailer
            )
            return
        }
        if let trailer, !trailer.isEmpty {
            outputPipeline.writeDirect(trailer)
            didQueueScrollbackRestoreReplay()
        }
    }

    /// Release the scrollback-restore gate when an embedded trzsz session
    /// fails before reaching `.running`. The trailer we were holding the gate
    /// open for will never arrive, so flush whatever is buffered (so the
    /// session's failure UI / password prompt actually reaches Ghostty) and
    /// mark `.running` as observed so any later layout-deferred restore
    /// doesn't re-open the gate.
    func handleEmbeddedTrzszFailedBeforeRunning() {
        embeddedTrzszReachedRunning = true
        if scrollbackWrittenAwaitingTrailer {
            scrollbackWrittenAwaitingTrailer = false
            outputPipeline.finishScrollbackRestoreGate()
            TerminalBellSuppressor.suppress(uuid, untilDrained: outputPipeline)
            didQueueScrollbackRestoreReplay()
        }
    }

    /// Run the layout-deferred scrollback restore for this terminal, with the
    /// shellLaunchedTrzsz join handling baked in. Called from `sizeDidChange`
    /// and the timeout fallback.
    ///
    /// For shellLaunchedTrzsz restorations the gate may need to stay open past
    /// scrollback write (until `applyResumeTrailer` deposits its trailer and
    /// finishes the gate) so the byte stream remains
    ///     saved-scrollback → trailer → buffered-server-output → live
    /// even when layout fires before the embedded trzsz session reaches
    /// `.running`. Other restoration paths flush the gate as before.
    func runLayoutDeferredScrollbackRestore() {
        let isShellLaunchedTrzszRestore: Bool = {
            if case .shellLaunchedTrzsz = connectionConfig { return true }
            return false
        }()
        let trailer = pendingResumeTrailer
        pendingResumeTrailer = nil

        if restoredWasTmuxGateway {
            // Projected panes own the useful persisted content. Keep remote
            // control records gated, skip the hidden gateway's ANSI replay,
            // and arm only once the embedded tssh session is running.
            if embeddedTrzszReachedRunning {
                releaseRestoredTmuxOutputGateWhenViewerIsArmed()
            } else {
                scrollbackWrittenAwaitingTrailer = true
            }
            return
        }

        // Keep the gate open only when we expect a trailer to arrive later
        // (shellLaunchedTrzsz restoration, embedded trzsz hasn't reached
        // `.running` yet). If `.running` already fired, the trailer is in
        // `pendingResumeTrailer` (or nil for fresh embedded sessions) and we
        // can finalize the gate atomically with the scrollback write.
        let keepGateOpen = isShellLaunchedTrzszRestore && !embeddedTrzszReachedRunning
        if keepGateOpen {
            scrollbackWrittenAwaitingTrailer = true
        }

        ScrollbackPersistenceManager.shared.restoreScrollback(
            for: self,
            trailer: trailer,
            keepGateOpen: keepGateOpen
        )
    }

    /// Build the mode-restoration trailer for a resumed trzsz session and inject
    /// it via `restoreScrollbackAfterAnimation(trailer:)`.
    ///
    /// The trailer carries the DECSETs the resumed remote TUI expects to be
    /// active (alt screen, mouse capture, cursor key mode, focus reporting,
    /// bracketed paste, cursor shape reset). Appended atomically to the saved
    /// scrollback inside the restore gate, the byte stream becomes:
    ///
    ///     saved-scrollback → trailer → buffered-live → live
    ///
    /// No live data can race ahead of the mode-set bytes, so by the time the
    /// server's redraw is parsed, ghostty's modes are already correct.
    ///
    /// Focus is never injected directly: DECSET 1004 makes ghostty report the
    /// surface's real focus state to the remote, so a `tail -f` shell (mode
    /// off) receives nothing. A tmux gateway skips the trailer entirely; tmux
    /// owns pane focus and raw bytes would corrupt its control channel.
    ///
    /// Used by both the top-level `.trzsz` `.running` handler and the embedded
    /// `.shellLaunchedTrzsz` path (via `LocalShellSession.onEmbeddedTrzszReady`).
    /// When transport resume falls back to a fresh spawn, abandons any restored
    /// tmux projection and rejoins the ordinary saved-scrollback flow. Layout-
    /// deferred restores remain deferred until the correctly sized callback.
    /// A fresh shell must never be armed as a synthetic tmux control stream.
    func applyResumeTrailer(for trzszSession: TrzszSession) {
        // A restored tmux projection is valid only when tssh actually resumed
        // the old PTY. On fresh-spawn fallback the bytes already waiting in the
        // restore gate are a normal shell banner/prompt, not tmux control
        // records. Clear the gateway identity first so the ordinary restore
        // path replays saved ANSI and then releases those live shell bytes.
        // ROOTSHELL-TMUX (id=tmux-fresh-transport-fallback)
        if restoredWasTmuxGateway && !trzszSession.wasResumed {
            embeddedTrzszReachedRunning = true
            tmuxResumeGateReleaseTask?.cancel()
            tmuxResumeGateReleaseTask = nil
            tmuxResumeGateReleaseScheduled = false
            tmuxResumeWatchdog?.cancel()
            tmuxResumeWatchdog = nil
            removeAwaitingTmuxPlaceholders()
            pendingResumeTrailer = nil
            TmuxDebugLogger.shared.event(
                "RESUME",
                "transport fell back to fresh spawn; restoring as plain shell gw=\(uuid.uuidString.prefix(8))")

            // The layout token remains true until a size callback claims it on
            // the main actor. If `.running` wins that race, leave the gate and
            // scrollback untouched; the sized callback will now take the normal
            // (non-tmux) path exactly once. ROOTSHELL-TMUX
            // (id=tmux-fresh-transport-fallback)
            if pendingScrollbackRestoreForLayout {
                scrollbackWrittenAwaitingTrailer = false
                return
            }

            if scrollbackWrittenAwaitingTrailer {
                // Layout already ran while the terminal still looked like a
                // restored gateway, so it intentionally skipped hidden-gateway
                // ANSI. We now know this is a fresh shell and can restore at
                // the established dimensions before releasing its live bytes.
                scrollbackWrittenAwaitingTrailer = false
                ScrollbackPersistenceManager.shared.restoreScrollback(for: self)
            } else {
                // Top-level `.trzsz` restoration uses the non-layout pending
                // flag; its ordinary helper atomically clears and finishes it.
                restoreScrollbackAfterAnimation()
            }
            return
        }

        var trailer: Data? = nil
        if trzszSession.wasResumed {
            var bytes = Data()
            let wasAltScreen = ScrollbackPersistenceManager.shared.wasAlternateScreenActive(for: self.uuid)
            if wasAltScreen {
                bytes.append(Data("\u{1b}[?1049h".utf8))
            }
            if ScrollbackPersistenceManager.shared.wasMouseCaptureActive(for: self.uuid) {
                bytes.append(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
            }
            if ScrollbackPersistenceManager.shared.wasCursorKeyModeActive(for: self.uuid) {
                bytes.append(Data("\u{1b}[?1h".utf8))
            }
            // The live surface covers same-process reconnects whose flag was
            // never persisted. Parsing 1004h makes ghostty emit focus-in/out.
            let focusReporting = ScrollbackPersistenceManager.shared.wasFocusEventModeActive(for: self.uuid)
                || (surface.map { ghostty_surface_focus_event_mode($0) } ?? false)
            if focusReporting {
                bytes.append(Data("\u{1b}[?1004h".utf8))
            }
            // Virtually all TUI apps that use alternate screen also enable bracketed paste.
            if wasAltScreen {
                bytes.append(Data("\u{1b}[?2004h".utf8))
            }
            // Reset local cursor to default (block) since the server's PTY buffer
            // may contain stale DECSCUSR from the remote app's unfocused rendering
            // (e.g., Helix sends underline on focus-out).
            bytes.append(Data("\u{1b}[0 q".utf8))
            trailer = bytes.isEmpty ? nil : bytes
        }

        // Mark that `.running` has been observed so the layout-deferred restore
        // (if it fires after this point) can flush the gate atomically.
        embeddedTrzszReachedRunning = true

        if pendingScrollbackRestoreForLayout {
            // Path A: layout-deferred restore hasn't run yet (zero-sized view
            // race, or embedded trzsz raced ahead of layout). Stow the trailer
            // so the eventual layout-deferred restore appends it atomically
            // after the saved scrollback (inside `gate.finish`'s defer), not
            // directly to bufferedWriter ahead of it.
            pendingResumeTrailer = trailer
        } else if scrollbackWrittenAwaitingTrailer {
            // Path B (the common ordering for shellLaunchedTrzsz cold restart):
            // layout-deferred restore already wrote the saved scrollback but
            // kept the gate open because we hadn't reached `.running` yet.
            // Spinner frames, the embedded session's attach response, and the
            // resize-jiggle redraw have all been buffering in the gate since
            // then. Now we can write the trailer behind the scrollback and
            // finish the gate, producing the desired stream:
            //     saved-scrollback → trailer → buffered-server-output → live
            if !restoredWasTmuxGateway, let trailer, !trailer.isEmpty {
                outputPipeline.writeDirect(trailer)
            }
            scrollbackWrittenAwaitingTrailer = false
            if restoredWasTmuxGateway {
                // The buffered server bytes are tmux control records. The core
                // viewer must be armed before these records leave the gate.
                releaseRestoredTmuxOutputGateWhenViewerIsArmed()
            } else {
                outputPipeline.finishScrollbackRestoreGate()
                // Everything the gate buffered while we waited for `.running`
                // lands now — hold the mute until it has actually drained.
                TerminalBellSuppressor.suppress(uuid, untilDrained: outputPipeline)
                didQueueScrollbackRestoreReplay()
            }
        } else {
            // Top-level `.trzsz` (pendingScrollbackRestore-driven) or any
            // other path where the gate has already been flushed normally.
            restoreScrollbackAfterAnimation(trailer: trailer)
        }
        // A restored tmux gateway is armed by the scrollback-gate release path
        // above, after its saved ANSI bytes drain and before buffered live
        // control records are allowed into Ghostty.
    }

    /// Ensures the restore replay's final cursor positioning is rendered after
    /// the saved bytes and any gated live output have reached Ghostty.
    func didQueueScrollbackRestoreReplay() {
        outputPipeline.notifyWhenOutputDrained { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushPostScrollbackRestoreRender()
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.flushPostScrollbackRestoreRender()
            }
        }
    }

    private func flushPostScrollbackRestoreRender() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }
        ghosttyApp?.appTick()
        if let surface {
            ghostty_surface_draw(surface)
        }
        // Sync the cached `@Published isMouseCaptured` mirror against ghostty's
        // C state once the scrollback replay (and any restore-time trailer
        // bytes such as DECSET 1000h for mouse mode) have been parsed. The
        // trailer is appended atomically to the saved scrollback inside the
        // restore gate, so by the time this fires the byte stream
        // saved-scrollback → trailer → buffered-live-output has all reached
        // ghostty in order, with no live data interleaved.
        updateMouseCaptureState()
    }
}

// MARK: - Session Error Handling

extension Ghostty.TerminalView {

    /// Handles session errors with consistent spinner cleanup and error display.
    /// For connection errors, plays a whimsical ASCII animation before showing the error.
    /// - Parameters:
    ///   - error: The error to store and display
    ///   - prefix: Optional prefix for the error message (e.g., "SSH Error", "Kubernetes Error")
    ///   - animated: Whether to show animated failure (default: true for connection errors)
    func handleSessionError(_ error: Error, prefix: String? = nil, animated: Bool = true) {
        self.error = error
        outputPipeline.cancelScrollbackRestoreGate()

        // If we were connecting from restore, show failure overlay
        if restorationState == .connectingFromRestore {
            restorationState = .failed(error.localizedDescription)
        }

        // Stop any running spinner animation and grab its cleanup sequence
        // (for multi-line spinner support), then clear the spinner first.
        let spinnerCleanup = connectionProgress.takeCleanupSequence()
        writeToGhostty(string: spinnerCleanup)

        if animated {
            // Play failure animation with quip for all errors
            failureAnimator = FailureAnimator()
            failureAnimator?.play(
                for: error,
                terminalWidth: Int(surfaceSize?.columns ?? 80),
                onFrame: { [weak self] output in
                    self?.writeToGhostty(string: output)
                },
                onComplete: { [weak self] in
                    guard let self = self else { return }
                    self.showFinalError(error, prefix: prefix)
                }
            )
        } else {
            showFinalError(error, prefix: prefix)
        }
    }

    /// Shows the final error message after animation completes
    private func showFinalError(_ error: Error, prefix: String?) {
        // Don't clear the animation - keep it visible with the quip
        failureAnimator = nil

        // Build error message (without prefix for cleaner look)
        let errorMessage = error.localizedDescription

        // Center the error message like the animation and quip
        let terminalWidth = Int(surfaceSize?.columns ?? 80)
        let padding = max(0, (terminalWidth - errorMessage.count) / 2)
        let centeredError = String(repeating: " ", count: padding) + errorMessage

        // Show error below the quip in the same dimmed style (no emoji, seamless with animation)
        let dimColor = "\u{1B}[2m"  // ANSI dim
        let reset = "\u{1B}[0m"

        writeToGhostty(string:
            "\r\n" +
            dimColor + centeredError + reset + "\r\n\r\n" +
            TerminalSequence.progressClear
        )
    }

    /// Clears the progress indicator and status line without displaying an error.
    /// Used when handling auth errors that trigger re-authentication flow.
    func clearProgressAndSpinner() {
        connectionProgress.clear()
    }
}

// MARK: - Post-Ready Session Behavior

extension Ghostty.TerminalView {
    /// Records a multiplexer this connection is configured to start, so agent
    /// detection can stand down on a surface that will hold many logical
    /// windows. Deliberately separate from `sendLaunchCommandIfConfigured`,
    /// which bails early for resumed and exec sessions — a resumed session's
    /// multiplexer is still running, so the binding must survive those paths.
    /// (id=agent-attention-raw-mux)
    func applyConfiguredMultiplexerBinding() {
        guard let sshConfig = connectionConfig.sshConfigForHistory else { return }

        // Keep zmx's transparent identity separate from raw multiplexer
        // bindings, since raw bindings also suppress agent attention.
        if sshConfig.zmxAutoEnable, let name = sshConfig.zmxSessionNameForConnection {
            bindPassthroughMultiplexer(.zmx, sessionName: name, canDetachSwitch: false)
        }

        guard rawMultiplexer == nil else { return }

        // Auto-connect. Control mode gets its own surface per pane, so only
        // the plain mode collapses a whole session onto this one.
        if sshConfig.tmuxAutoEnable, sshConfig.tmuxAutoMode == .regular {
            bindRawMultiplexer(.tmux, sessionName: sshConfig.tmuxSessionNameForConnection)
            return
        }

        if sshConfig.herdrAutoEnable {
            bindRawMultiplexer(.herdr, sessionName: sshConfig.herdrSessionNameForConnection)
            return
        }

        // A configured launch/remote command that is itself a multiplexer.
        let configured = [sshConfig.launchCommand, sshConfig.remoteCommand]
            .compactMap { $0 }
        for command in configured {
            if let type = Self.rawMultiplexerType(launching: command) {
                bindRawMultiplexer(type, sessionName: nil)
                return
            }
        }
    }

    /// Sets the binding and re-runs monitor reconcile, so a pane that already
    /// published an agent card before the multiplexer was known drops it.
    ///
    /// Binds only multiplexers that own the alternate screen; raw bindings
    /// suppress agent attention until ownership is released.
    func bindRawMultiplexer(_ type: MultiplexerType, sessionName: String?) {
        guard type.ownsAlternateScreen else { return }
        guard rawMultiplexer == nil else { return }
        rawMultiplexer = .init(type: type, sessionName: sessionName)
        AgentAttentionCenter.shared.topologyDidChange()
    }

    /// Records a transparent multiplexer identity without affecting agent
    /// attention. The session name is required because it cannot be inferred
    /// safely from a host with multiple sessions.
    func bindPassthroughMultiplexer(_ type: MultiplexerType, sessionName: String, canDetachSwitch: Bool) {
        guard !type.ownsAlternateScreen else { return }
        guard passthroughMultiplexer == nil else { return }
        passthroughMultiplexer = .init(type: type, sessionName: sessionName, canDetachSwitch: canDetachSwitch)
    }

    /// Maps a configured command to the multiplexer it starts, or nil when it
    /// starts none. Matches the command word only — an explicit table, never a
    /// substring search, so an unrelated command mentioning "tmux" is not a
    /// multiplexer. `tmux -CC` is excluded: control mode is app-driven.
    static func rawMultiplexerType(launching command: String) -> MultiplexerType? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = words.first(where: { !$0.contains("=") }) else { return nil }
        let name = (executable as NSString).lastPathComponent

        switch name {
        case "tmux":
            return words.contains("-CC") ? nil : .tmux
        case "zellij":
            return .zellij
        case "herdr":
            return .herdr
        case "byobu", "byobu-tmux":
            // byobu is a front-end over tmux (it takes no -CC of its own).
            // `byobu` can also be screen-backed, so the type is a best
            // guess: it is sound for suppression, which is all it drives
            // today, but the out-of-band classification tier must verify the
            // backend rather than assume tmux commands will work.
            return .tmux
        default:
            return nil
        }
    }

    /// Sends tmux auto-connect and/or the configured launch command as terminal input after session ready.
    /// Re-fires on reconnect (flag is reset by TerminalSessionController).
    func sendLaunchCommandIfConfigured() {
        guard !hasSentLaunchCommand else { return }
        hasSentLaunchCommand = true

        let sshConfig = connectionConfig.sshConfigForHistory
        let multiplexerAutoEnabled = (sshConfig?.tmuxAutoEnable ?? false) || (sshConfig?.herdrAutoEnable ?? false)
            || (sshConfig?.zmxAutoEnable ?? false)
        let launchCommand = sshConfig?.launchCommand

        // Skip for resumed sessions - the remote shell already has tmux/commands running
        if let trzszSession = session as? TrzszSession, trzszSession.wasResumed { return }
        if let moshSession = session as? MoshSession, moshSession.wasResumed { return }

        // Skip for exec sessions — remote command runs via exec request, no interactive shell
        if let remoteCommand = sshConfig?.remoteCommand, !remoteCommand.isEmpty { return }
        if sshConfig?.launchCommandMode == .initialCommandWithPTY { return }

        // Launch command (all session types)
        // Note: tmux/herdr auto-connect is handled via SSH exec request for all session types
        // (SSHSession, CitadelSSHSession, TrzszSession) — no terminal input needed.
        if let launchCommand, !launchCommand.isEmpty {
            let commandWithNewline = launchCommand + "\n"
            if let data = commandWithNewline.data(using: .utf8) {
                let charCount = launchCommand.count
                if multiplexerAutoEnabled {
                    // Delay to let the multiplexer start before sending launch command
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        Ghostty.logger.info("Sending launch command (\(charCount) chars) after multiplexer delay")
                        self?.invalidateWritingAssistance()
                        self?.session?.sendInput(data)
                    }
                } else {
                    Ghostty.logger.info("Sending launch command (\(charCount) chars)")
                    invalidateWritingAssistance()
                    session?.sendInput(data)
                }
            }
        }
    }
}

// MARK: - Multiplexer Session Discovery (tmux + zellij + herdr)

extension Ghostty.TerminalView {

    private func startSessionDiscoveryTask(
        allowSessionPickerOverlay: Bool,
        operation: @escaping @MainActor () async throws -> SessionDiscoveryResult
    ) {
        sessionDiscoveryTask?.cancel()

        sessionDiscoveryTask = Task { @MainActor [weak self] in
            // Brief delay to let shell prompt render
            try? await Task.sleep(for: .milliseconds(300))

            guard let self = self else { return }
            guard !Task.isCancelled else { return }

            do {
                let result = try await operation()
                self.discoveredMultiplexerSwipeBindings = result.swipeBindings

                guard !Task.isCancelled else { return }
                guard allowSessionPickerOverlay else { return }
                guard !self.hasUserTyped else { return }
                guard !result.sessions.isEmpty else { return }

                self.discoveredSessions = result.sessions
                self.discoveredSessionTypes = result.types
                self.sessionSelectionIndex = 0
                self.tmuxDiscoveryAttachMode = self.preferredTmuxDiscoveryAttachMode
                NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: self)
            } catch {
                Ghostty.logger.debug("Session discovery skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Discovers multiplexer sessions (tmux, zellij, herdr, zmx) on the active host or local shell.
    /// Called after the session reports it is ready for input.
    func discoverSessionsIfConfigured() {
        // Check which discoveries are enabled (default to true for all)
        let store = SettingsStore.shared
        let tmuxEnabled = store.value(Settings.Multiplexer.tmuxSessionDiscovery)
        let zellijEnabled = store.value(Settings.Multiplexer.zellijSessionDiscovery)
        let herdrEnabled = store.value(Settings.Multiplexer.herdrSessionDiscovery)
        let zmxEnabled = store.value(Settings.Multiplexer.zmxSessionDiscovery)

        guard tmuxEnabled || zellijEnabled || herdrEnabled || zmxEnabled else { return }

        #if STANDALONE && targetEnvironment(macCatalyst)
        if session is CatalystLocalShellSession, case .local = connectionConfig {
            let localEnabled = store.value(Settings.Multiplexer.localSessionDiscovery)
            guard localEnabled else { return }

            let allowSessionPickerOverlay = true
            let skipTmuxSessions = !tmuxEnabled
            let skipZellijSessions = !zellijEnabled
            let skipHerdrSessions = !herdrEnabled
            let skipZmxSessions = !zmxEnabled
            let discoverTmuxBindings = tmuxEnabled
            let discoverZellijBindings = zellijEnabled
            let workingDirectory = connectionConfig.workingDirectory

            startSessionDiscoveryTask(allowSessionPickerOverlay: allowSessionPickerOverlay) {
                try await SessionDiscoveryRunner.discoverLocally(
                    workingDirectory: workingDirectory,
                    skipTmuxSessions: skipTmuxSessions,
                    skipZellijSessions: skipZellijSessions,
                    skipHerdrSessions: skipHerdrSessions,
                    skipZmxSessions: skipZmxSessions,
                    discoverTmuxBindings: discoverTmuxBindings,
                    discoverZellijBindings: discoverZellijBindings
                )
            }
            return
        }
        #endif

        guard let sshConfig = connectionConfig.sshConfigForHistory else { return }
        let hasLaunchCommand = !(sshConfig.launchCommand?.isEmpty ?? true)
        let hasRemoteCommand = !(sshConfig.remoteCommand?.isEmpty ?? true)
        let wasResumed = (session as? TrzszSession)?.wasResumed == true || (session as? MoshSession)?.wasResumed == true

        // Keep background binding discovery on even when the session picker overlay
        // is suppressed by explicit post-connect behavior, resumed sessions, or
        // multiplexer auto-start. Auto-start suppresses the picker for ALL
        // multiplexer types: the connection is already committed to a
        // multiplexer, so sessions of another type must not pop the picker
        // over its freshly started UI.
        let multiplexerAutoStart = sshConfig.tmuxAutoEnable || sshConfig.herdrAutoEnable || sshConfig.zmxAutoEnable
        let allowSessionPickerOverlay = !hasLaunchCommand && !hasRemoteCommand && !wasResumed
            && !multiplexerAutoStart
        let skipTmuxSessions = !tmuxEnabled || !allowSessionPickerOverlay
        let skipZellijSessions = !zellijEnabled || !allowSessionPickerOverlay
        let skipHerdrSessions = !herdrEnabled || !allowSessionPickerOverlay
        let skipZmxSessions = !zmxEnabled || !allowSessionPickerOverlay
        let discoverTmuxBindings = tmuxEnabled
        let discoverZellijBindings = zellijEnabled

        guard discoverTmuxBindings || discoverZellijBindings || !skipTmuxSessions
            || !skipZellijSessions || !skipHerdrSessions || !skipZmxSessions else {
            return
        }

        // Determine discovery strategy:
        // - CitadelSSHSession: reuse existing client (fast, no extra connection)
        // - Trzsz/Mosh/other SSH sessions: create temporary connection using SSHConfig
        let citadelSession = session as? CitadelSSHSession
        let needsTemporaryConnection = citadelSession == nil

        // Only support SSH-based sessions
        guard citadelSession != nil || session is TrzszSession || session is MoshSession else { return }

        // Route a keyboard-interactive challenge during a temporary discovery
        // connection (Mosh/Trzsz) to the shared prompt sheet, so a PAM/OTP/2FA
        // host can re-authenticate for discovery instead of failing. Captured
        // weakly so the escaping discovery task doesn't retain the terminal view.
        let discoveryKeyboardInteractive: (KeyboardInteractiveChallenge) async -> [String]? = { [weak self] challenge in
            guard let self else { return nil }
            if let callback = self.onKeyboardInteractiveChallengeRequired {
                return await callback(challenge, self)
            }
            return nil
        }

        startSessionDiscoveryTask(allowSessionPickerOverlay: allowSessionPickerOverlay) {
            if let citadelSession, !needsTemporaryConnection {
                return try await SessionDiscoveryRunner.discover(
                    using: citadelSession,
                    skipTmuxSessions: skipTmuxSessions,
                    skipZellijSessions: skipZellijSessions,
                    skipHerdrSessions: skipHerdrSessions,
                    skipZmxSessions: skipZmxSessions,
                    discoverTmuxBindings: discoverTmuxBindings,
                    discoverZellijBindings: discoverZellijBindings
                )
            }

            // Resolve saved passwords/keys before creating temporary connection
            let resolvedConfig = try await sshConfig.resolvedConfig()
            return try await SessionDiscoveryRunner.discover(
                using: resolvedConfig,
                skipTmuxSessions: skipTmuxSessions,
                skipZellijSessions: skipZellijSessions,
                skipHerdrSessions: skipHerdrSessions,
                skipZmxSessions: skipZmxSessions,
                discoverTmuxBindings: discoverTmuxBindings,
                discoverZellijBindings: discoverZellijBindings,
                onKeyboardInteractiveChallenge: discoveryKeyboardInteractive
            )
        }
    }

    /// Dismisses the session discovery overlay.
    func dismissSessionDiscovery() {
        discoveredSessions = nil
        discoveredSessionTypes = []
        tmuxDiscoveryAttachMode = .regular
        sessionDiscoveryTask?.cancel()
        sessionDiscoveryTask = nil
        NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: self)
    }

    /// Dismisses the session discovery overlay when it is currently presented.
    /// Returns true when the caller should consume the Escape that triggered it.
    @discardableResult
    func dismissSessionDiscoveryIfPresented() -> Bool {
        guard discoveredSessions != nil else { return false }
        dismissSessionDiscovery()
        return true
    }

    /// Whether this terminal can start a tmux control-mode client from discovery.
    var allowsTmuxControlDiscoveryAttach: Bool {
        switch connectionConfig {
        case .ssh, .shellLaunchedSSH, .trzsz, .shellLaunchedTrzsz:
            return true
        case .local:
            // The macOS local shell runs a real pty, so it can carry a -CC
            // control stream just like SSH. The ios_system shell cannot.
            #if targetEnvironment(macCatalyst)
            return session is CatalystLocalShellSession
            #else
            return false
            #endif
        default:
            return false
        }
    }

    private var preferredTmuxDiscoveryAttachMode: TmuxAutoMode {
        allowsTmuxControlDiscoveryAttach ? TmuxAutoMode.persistedDiscoveryAttachMode : .regular
    }

    /// Moves session selection by delta, wrapping around.
    func moveSessionSelection(by delta: Int) {
        guard let sessions = discoveredSessions, !sessions.isEmpty else { return }
        sessionSelectionIndex = (sessionSelectionIndex + delta + sessions.count) % sessions.count
        NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: self)
    }

    /// Attaches to the currently highlighted session.
    func selectHighlightedSession() {
        guard let sessions = discoveredSessions,
              sessions.indices.contains(sessionSelectionIndex) else { return }
        attachToSession(sessions[sessionSelectionIndex])
    }

    /// Selects a session by matching the digit to the session name.
    /// Returns true if a matching session was found.
    @discardableResult
    func selectSessionByDigit(_ digit: Int) -> Bool {
        guard let sessions = discoveredSessions else { return false }
        let digitStr = String(digit)
        guard let index = sessions.firstIndex(where: { $0.name == digitStr }) else { return false }
        if hasUserTyped {
            sessionSelectionIndex = index
            NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: self)
        } else {
            attachToSession(sessions[index])
        }
        return true
    }

    /// Sends the appropriate attach command and dismisses the overlay.
    func attachToSession(_ session: MultiplexerSession) {
        let escapedName = session.name.shellEscapedForDoubleQuotes
        // Wrap in sh -c for portability across all login shells (bash, zsh, fish, csh).
        // $PATH expands inside sh, not the outer shell.
        let attachCommand: String
        switch session.type {
        case .tmux:
            let controlMode = tmuxDiscoveryAttachMode == .control && allowsTmuxControlDiscoveryAttach
            let cc = controlMode ? "-CC " : ""
            attachCommand = "tmux \(cc)attach -t \"\(escapedName)\""
            // Control mode projects each pane onto its own surface, so only a
            // plain attach turns this one surface into a multi-window view.
            if !controlMode {
                bindRawMultiplexer(.tmux, sessionName: session.name)
            }
        case .zellij:
            attachCommand = "zellij attach \"\(escapedName)\""
            bindRawMultiplexer(.zellij, sessionName: session.name)
        case .herdr:
            // Attach-or-create: resurrects a stopped session by spawning its
            // server. "default" is the literal name of the default session.
            attachCommand = "herdr session attach \"\(escapedName)\""
            bindRawMultiplexer(.herdr, sessionName: session.name)
        case .zmx:
            // zmx is transparent, so preserve its identity without suppressing
            // the inner program's agent state. Clear the prefix because the
            // discovered name is already the fully resolved socket name.
            attachCommand = "ZMX_SESSION_PREFIX= zmx attach \"\(escapedName)\""
            bindPassthroughMultiplexer(.zmx, sessionName: session.name, canDetachSwitch: true)

            // Use the reported directory until OSC 7 provides a fresher value.
            if let cwd = session.workingDirectory, cwd.hasPrefix("/") {
                handlePwdChange(cwd)
            }
        }
        let command = multiplexerAttachInputLine(attachCommand)
        if session.type == .zmx, userOverrideTitle == nil {
            // Preserve the session name until a real OSC 2 title arrives;
            // suppress the shell's one-shot command echo.
            title = session.name
            pendingCommandEcho = (
                command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                until: Date().addingTimeInterval(Self.commandEchoTitleWindow)
            )
        }
        if let data = command.data(using: .utf8) {
            sendUserInput(data)
        }
        dismissSessionDiscovery()
    }

    /// Builds the zmx attach line used when focus reattaches through the shell.
    func zmxAttachInputLine(sessionName: String) -> String {
        let escapedName = sessionName.shellEscapedForDoubleQuotes
        return multiplexerAttachInputLine("ZMX_SESSION_PREFIX= zmx attach \"\(escapedName)\"")
    }

    private func multiplexerAttachInputLine(_ attachCommand: String) -> String {
        let script = "\(SSHConfig.remoteExecPathPrefix)\(attachCommand)"
        return LoginShellCommand.runInPOSIXShell(script) + "\n"
    }
}

// MARK: - Session Monitoring

extension Ghostty.TerminalView {

    func manualReconnect() {
        sessionController.manualReconnect()
    }

    func cancelReconnection() {
        sessionController.cancelReconnection()
    }

    /// Whether size report filtering should be active right now for this session.
    /// Currently scoped to trzsz (tssh) sessions only, where the issue is observed.
    /// Checks dynamically so it tracks LocalShellSession mode changes (e.g., user
    /// typed `tssh` at a local prompt, or returned to local shell after embedded session).
    func shouldFilterSizeReportsNow(session: TerminalSession) -> Bool {
        switch connectionConfig {
        case .trzsz, .trzszTransfer:
            return true
        case .shellLaunchedTrzsz:
            #if !targetEnvironment(macCatalyst)
            if let localSession = session as? LocalShellSession {
                return localSession.sessionMode.isTrzsz
            }
            #endif
            return true
        case .local:
            #if !targetEnvironment(macCatalyst)
            if let localSession = session as? LocalShellSession {
                return localSession.sessionMode.isTrzsz
            }
            #endif
            return false
        default:
            return false
        }
    }

    /// Monitors Ghostty's response pipe for terminal responses (e.g., cursor position queries)
    /// and forwards them back to the session for bidirectional terminal communication.
    /// Works with both SSH and Catalyst local shell sessions.
    ///
    /// Uses event-driven DispatchSource instead of polling for better performance.
    /// This helps drain the termio mailbox faster during heavy I/O from apps like zellij,
    /// reducing the chance of queue saturation that can cause main thread deadlocks.
    func startTerminalResponseMonitoring(for session: TerminalSession) {
        sessionController.startTerminalResponseMonitoring(for: session)
    }

    /// Starts a 2-second timer to track sustained SSH/Mosh connections for history
    func startConnectionSuccessTimer() {
        sessionController.startConnectionSuccessTimer(connectionConfig: connectionConfig)
    }
}
