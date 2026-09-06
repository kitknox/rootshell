import Foundation

/// The narrow set of view-side capabilities that the session domain needs.
///
/// This is the boundary between `TerminalSessionController` (which owns the
/// `TerminalSession` and wires its callbacks) and `Ghostty.TerminalView`
/// (which owns the surface, the I/O plumbing, and all UI state). The
/// controller talks to the view *only* through this protocol — it never
/// reaches into the view's stored properties.
///
/// This is the reference template for peeling responsibilities off the
/// oversized `TerminalView`: an owned `@MainActor` controller plus a host
/// protocol that names exactly what it needs from the view. Future
/// extractions (surface management, input processing, …) should follow the
/// same shape. See `TerminalSessionController`.
@MainActor
protocol TerminalSessionHost: AnyObject {
    /// Builds the off-main output sink for a freshly-adopted session.
    ///
    /// The returned closure is `@Sendable` and is invoked on the session's
    /// background queue. It captures the view-owned I/O plumbing
    /// (`TerminalOutputCoalescer` / `TerminalScrollbackRestoreOutputGate` /
    /// `TerminalBufferedPipeWriter`)
    /// and the activity-notify coalescer. That plumbing stays view-owned for
    /// now, so the host (not the controller) constructs the sink.
    func makeSessionOutputSink() -> @Sendable (Data) -> Void

    /// The session reported a new title (OSC sequence). Called on the main actor.
    func sessionDidChangeTitle(_ title: String)

    /// The session reported a new working directory. Called on the main actor.
    func sessionDidChangeWorkingDirectory(_ pwd: String)

    /// The session requested a bell/beep. Called on the main actor.
    func sessionDidRingBell()

    /// The session ended (shell exited / connection closed) and is the live
    /// session (the controller has already filtered out stale callbacks).
    /// The host decides whether to close the tab based on reconnection state.
    /// Called on the main actor.
    func sessionDidEnd()

    /// The session finished async initialization and is ready for input.
    /// Called on the main actor.
    func sessionDidBecomeReady()
}

@MainActor
protocol TerminalSessionControllerHost: TerminalSessionHost, TerminalResponsePipelineHost {
    func terminalSessionWillChange()
    var terminalUUID: UUID { get }
    var terminalContainingTabID: UUID? { get }
    var terminalWindowID: String { get }
    var terminalConnectionConfig: ConnectionConfig { get set }
    var terminalRestorationState: Ghostty.TerminalView.RestorationState { get set }
    var terminalRestoredTrzszLastConnectedAt: Date? { get }
    var terminalRestoredWasTmuxGateway: Bool { get }
    var terminalHasTmuxController: Bool { get }
    var terminalSurfaceAvailable: Bool { get }
    var terminalSurfaceGridSize: (rows: UInt16, cols: UInt16)? { get }
    var terminalIsLiveDisconnectionOverlay: Bool { get set }
    var terminalOutputPipeline: TerminalOutputPipeline { get }
    var terminalReconnectionWidth: Int { get }
    var terminalHasPendingScrollbackRestore: Bool { get }
    /// One-shot shared-file path to open in the editor at local-shell start.
    var terminalPendingFileToOpen: String? { get set }
    /// One-shot command typed into the local shell after it starts.
    var terminalPendingStartupCommand: String? { get set }

    func terminalSetError(_ error: Error)
    func terminalNotifySessionDidChange()
    func terminalNotifyConnectionConfigChanged()
    func terminalNotifyRestorationStateChanged()
    func terminalHandleSessionError(_ error: Error, prefix: String?)
    func terminalClearProgressAndSpinner()
    func terminalRequestAuthentication(_ config: SSHConfig)
    func terminalValidateHostKey(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult
    func terminalHandleKeyboardInteractive(_ challenge: KeyboardInteractiveChallenge) async -> [String]?
    func terminalWireAgentForwardingApprovals(on session: any SSHAgentForwardingCallbacks)
    func terminalRequestAgentApproval(_ request: SSHAgentApprovalRequest)
    func terminalApplyConnectionHealth(_ health: ConnectionHealth?)
    func terminalProgressUpdate(
        message: String,
        style: SpinnerAnimator.ColorStyle,
        jokeCategory: ConnectionJokeCategory?
    )
    func terminalProgressFinish(_ mode: ConnectionProgressPresenter.FinishMode)
    func terminalProgressReset()
    func terminalRestoreScrollbackAfterAnimation()
    func terminalWriteToGhostty(_ string: String)
    func terminalApplyResumeTrailer(for session: TrzszSession)
    func terminalHandleEmbeddedTrzszFailedBeforeRunning()
    func terminalRemoveAwaitingTmuxPlaceholders()
    func terminalUpdatePTYSize()
    func terminalPerformResetAction()
    func terminalSetLocalTaskActive(_ isActive: Bool)
    func terminalDismissSessionDiscovery()
    func terminalResetLaunchCommandGate()
    func terminalResetUserTypingForReconnect()
}
