//
//  TerminalView+SessionHost.swift
//  rootshell
//
//  TerminalView's side of the session boundary: the view-mutating halves of
//  the session callbacks that `TerminalSessionController` relays back here.
//  These bodies were lifted verbatim from the old
//  `configureCommonSessionCallbacks(for:)` closures — the controller now owns
//  the session and its callback wiring; the view owns the I/O plumbing and the
//  UI/restoration/reconnection state these methods touch.
//

import UIKit
import os
import GhosttyKit

extension Ghostty.TerminalView: TerminalSessionControllerHost {
    func terminalSessionWillChange() {
        invalidateWritingAssistance(resetDocument: true)
    }

    var terminalContainingTabID: UUID? { containingTabID }
    var terminalWindowID: String { windowId }

    /// Builds the off-main output sink the controller installs on a freshly
    /// adopted session. Captures the view-owned I/O plumbing (coalescer / gate /
    /// buffered writer) and the persistence-notify coalescer, exactly as the old
    /// `outputHandler` did. Runs on the session's background queue — no main
    /// actor hop on the hot output path.
    func makeSessionOutputSink() -> @Sendable (Data) -> Void {
        outputPipeline.makeSessionOutputSink(
            useOutputCoalescer: shouldUseOutputCoalescer,
            terminalUUID: uuid,
            noteGatewayInboundBytes: { [weak self] byteCount in
                guard let self else { return }
                let ownerKey = self.tmuxGatewayOwnerKey
                if ownerKey != 0 {
                    TmuxDebugLogger.shared.noteGatewayInbound(owner: ownerKey, bytes: byteCount)
                }
            }
        )
    }

    func sessionDidChangeTitle(_ title: String) {
        // Save the session-provided title even while backgrounded so the
        // next foreground render picks up the latest value.
        self.sessionProvidedTitle = title
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        // Only update display title if user hasn't set a custom title
        if self.userOverrideTitle == nil {
            self.title = title
        }
    }

    func sessionDidChangeWorkingDirectory(_ pwd: String) {
        // Always cache so foreground replay has the latest value.
        self.sessionProvidedPwd = pwd
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        self.pwd = pwd
        // Keep connectionConfig in sync so CWD persists through serialization
        if case .local = self.connectionConfig {
            self.connectionConfig = .local(workingDirectory: pwd)
        }
    }

    func sessionDidRingBell() {
        self.ringBell()
    }

    func sessionDidEnd() {
        invalidateWritingAssistance(resetDocument: true)
        // Cancel connection success timer if session ends prematurely.
        self.sessionController.cancelConnectionSuccessTimer()

        // Reconnection starts outside any picker-attached passthrough session;
        // configured bindings are restored when the new session becomes ready.
        self.passthroughMultiplexer = nil

        // Check if reconnection manager is in a state that should keep tab open
        if let state = self.sessionController.reconnectionState {
            switch state {
            case .waitingToReconnect, .reconnecting, .disconnected:
                // Don't close - reconnection is in progress or about to start
                Ghostty.logger.info("Session ended but reconnection in progress, not closing")
                return
            case .manualReconnectRequired, .failed:
                // Don't close - keep tab open for manual retry
                Ghostty.logger.info("Session ended with manual reconnect required, keeping tab open")
                return
            case .idle, .connected:
                // Proceed to close
                break
            }
        }

        // Auto-close the terminal when session ends normally
        NotificationCenter.default.post(name: .closeSplit, object: self)
    }

    func sessionDidBecomeReady() {
        invalidateWritingAssistance(resetDocument: true)
        // Clear restoration state if we were reconnecting from restore
        if self.restorationState == .connectingFromRestore {
            self.restorationState = .none
            // Notify SwiftUI to update the overlay visibility
            // (TerminalView is a class, so @State doesn't observe its property changes)
            NotificationCenter.default.post(name: .terminalRestorationStateChanged, object: self)
        }
        // Mark as connected in reconnection manager
        self.sessionController.handleSessionConnectedForReconnection()

        // Force resize update after session ready (especially important for Mosh resume)
        // This ensures the server knows our terminal size even if UIKit layout didn't change
        self.invalidateCachedSize()
        self.sizeDidChange(self.bounds.size)

        // Refresh tab bar to update roam "R" indicator for Mosh/Trzsz sessions
        NotificationCenter.default.post(name: .ghosttySessionDidChange, object: self)

        // Record a configured multiplexer before anything reads the screen, so
        // agent detection never adopts an identity from a multi-window surface.
        self.applyConfiguredMultiplexerBinding()

        // Send tmux auto-connect and/or launch command if configured
        self.sendLaunchCommandIfConfigured()

        // Discover multiplexer sessions in the background (if configured)
        self.discoverSessionsIfConfigured()
    }
}

extension Ghostty.TerminalView {
    var terminalResponseFd: Int32 { responseFd }
    var terminalResponseReadQueue: DispatchQueue { readQueue }
    var terminalResponseTmuxGatewayOwnerKey: Int { tmuxGatewayOwnerKey }
    var terminalResponseHasTmuxController: Bool { tmuxController != nil }

    func terminalResponseShouldFilterSizeReports(for session: TerminalSession) -> Bool {
        shouldFilterSizeReportsNow(session: session)
    }

    var terminalUUID: UUID { uuid }
    var terminalConnectionConfig: ConnectionConfig {
        get { connectionConfig }
        set { connectionConfig = newValue }
    }
    var terminalRestorationState: RestorationState {
        get { restorationState }
        set { restorationState = newValue }
    }
    var terminalRestoredTrzszLastConnectedAt: Date? { restoredTrzszLastConnectedAt }
    var terminalRestoredWasTmuxGateway: Bool { restoredWasTmuxGateway }
    var terminalHasTmuxController: Bool { tmuxController != nil }
    var terminalSurfaceAvailable: Bool { surface != nil }
    var terminalSurfaceGridSize: (rows: UInt16, cols: UInt16)? {
        guard let surfaceSize else { return nil }
        return (rows: surfaceSize.rows, cols: surfaceSize.columns)
    }
    var terminalIsLiveDisconnectionOverlay: Bool {
        get { isLiveDisconnectionOverlay }
        set { isLiveDisconnectionOverlay = newValue }
    }
    var terminalOutputPipeline: TerminalOutputPipeline { outputPipeline }
    var terminalReconnectionWidth: Int { Int(surfaceSize?.columns ?? 80) }
    var terminalPendingFileToOpen: String? {
        get { pendingFileToOpen }
        set { pendingFileToOpen = newValue }
    }
    var terminalPendingStartupCommand: String? {
        get { pendingStartupCommand }
        set { pendingStartupCommand = newValue }
    }
    var terminalHasPendingScrollbackRestore: Bool {
        pendingScrollbackRestore || pendingScrollbackRestoreForLayout
    }

    func terminalSetError(_ error: Error) {
        self.error = error
    }

    func terminalNotifySessionDidChange() {
        NotificationCenter.default.post(name: .ghosttySessionDidChange, object: self)
    }

    func terminalNotifyConnectionConfigChanged() {
        NotificationCenter.default.post(name: .terminalConnectionConfigChanged, object: self)
    }

    func terminalNotifyRestorationStateChanged() {
        NotificationCenter.default.post(name: .terminalRestorationStateChanged, object: self)
    }

    func terminalHandleSessionError(_ error: Error, prefix: String?) {
        handleSessionError(error, prefix: prefix)
    }

    func terminalClearProgressAndSpinner() {
        clearProgressAndSpinner()
    }

    func terminalRequestAuthentication(_ config: SSHConfig) {
        onAuthenticationRequired?(config)
    }

    func terminalValidateHostKey(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        if let callback = onHostKeyValidationRequired {
            return await callback(request, self)
        }
        Ghostty.logger.warning("No host key validation callback set, rejecting connection")
        return .reject
    }

    func terminalHandleKeyboardInteractive(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        if let callback = onKeyboardInteractiveChallengeRequired {
            return await callback(challenge, self)
        }
        Ghostty.logger.warning("No keyboard-interactive callback set, cancelling challenge")
        return nil
    }

    func terminalWireAgentForwardingApprovals(on session: any SSHAgentForwardingCallbacks) {
        wireAgentForwardingApprovals(on: session)
    }

    func terminalRequestAgentApproval(_ request: SSHAgentApprovalRequest) {
        onAgentApprovalRequired?(request)
    }

    func terminalApplyConnectionHealth(_ health: ConnectionHealth?) {
        applyConnectionHealth(health)
    }

    func terminalProgressUpdate(
        message: String,
        style: SpinnerAnimator.ColorStyle,
        jokeCategory: ConnectionJokeCategory?
    ) {
        connectionProgress.update(message: message, style: style, jokeCategory: jokeCategory)
    }

    func terminalProgressFinish(_ mode: ConnectionProgressPresenter.FinishMode) {
        connectionProgress.finish(mode)
    }

    func terminalProgressReset() {
        connectionProgress.reset()
    }

    func terminalRestoreScrollbackAfterAnimation() {
        restoreScrollbackAfterAnimation()
    }

    func terminalWriteToGhostty(_ string: String) {
        writeToGhostty(string: string)
    }

    func terminalApplyResumeTrailer(for session: TrzszSession) {
        applyResumeTrailer(for: session)
    }

    func terminalHandleEmbeddedTrzszFailedBeforeRunning() {
        handleEmbeddedTrzszFailedBeforeRunning()
    }

    func terminalRemoveAwaitingTmuxPlaceholders() {
        removeAwaitingTmuxPlaceholders()
    }

    func terminalUpdatePTYSize() {
        updatePTYSize()
    }

    func terminalPerformResetAction() {
        _ = performAction("reset")
    }

    func terminalSetLocalTaskActive(_ isActive: Bool) {
        hasActiveLocalTask = isActive
        terminalNotifyConnectionConfigChanged()
    }

    func terminalDismissSessionDiscovery() {
        dismissSessionDiscovery()
    }

    func terminalResetLaunchCommandGate() {
        hasSentLaunchCommand = false
    }

    func terminalResetUserTypingForReconnect() {
        hasUserTyped = false
    }
}
