//
//  TSSHSession.swift
//  rootshell
//
//  trzsz-ssh terminal session implementation
//

import Citadel
import Combine
import Foundation
import NIOCore
import NIOSSH
import OSLog
import UIKit

/// trzsz-ssh terminal session
///
/// Implements the TerminalSession protocol for trzsz-ssh connections.
/// Provides:
/// - SSH-based server spawn (tsshd)
/// - QUIC transport with TLS 1.3
/// - Session persistence and resume
/// - Network roaming support
@MainActor
final class TrzszSession: TerminalSession {

    // MARK: - TerminalSession Protocol

    /// The PTY for terminal I/O
    let pty: TerminalPTY

    /// Whether the session is currently running
    private(set) var isRunning: Bool = false

    /// Prevent double-cleanup / duplicate onSessionEnd callbacks
    private var didEndSession: Bool = false

    /// Terminal output callback. Bytes are delivered off-main via
    /// `goTransport?.outputSink`; this property is kept in sync with the
    /// sink so re-binding works dynamically (matches CitadelSSHSession).
    var onOutput: (@Sendable (String) -> Void)? {
        didSet { goTransport?.outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }

    /// Raw output callback (preferred)
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet { goTransport?.outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }

    /// Title change callback
    var onTitleChange: ((String) -> Void)?

    /// Working directory change callback
    var onWorkingDirectoryChange: ((String) -> Void)?

    /// Bell callback
    var onBell: (() -> Void)?

    /// Session end callback
    var onSessionEnd: (() -> Void)?

    /// Session ready callback
    var onReady: (() -> Void)?

    /// Error callback
    var onError: ((Error) -> Void)?

    /// Disconnect callback for reconnection
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    /// tssh owns retry/resume internally. Swift must not run the generic
    /// reconnect manager because it writes status text into the terminal and
    /// can replace a Go transport that is still retrying.
    var supportsAutoReconnect: Bool { false }

    // Connection metadata
    private(set) var connectionStartTime: Date?

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        let sshConfig = config.sshConfig
        let mode = serverInfo?.mode ?? savedCredentials?.mode
        return .trzsz(SSHConnectionInfo(
            host: sshConfig.host,
            port: sshConfig.port,
            username: sshConfig.username,
            resolvedIP: nil,
            connectedAt: startTime,
            jumpHost: sshConfig.jumpHost?.host,
            jumpPort: sshConfig.jumpHost?.port,
            keyExchangeAlgorithm: bootstrapKeyExchange,
            hostKeyAlgorithm: bootstrapHostKey,
            cipherAlgorithm: bootstrapCipher,
            macAlgorithm: bootstrapMac,
            agentForwardingEnabled: config.sshConfig.agentConfig.enabled
        ), transportMode: mode?.rawValue, transportRef: goTransport?.activeTransportRef)
    }

    // MARK: - Bootstrap SSH Crypto

    /// SSH algorithms negotiated during the bootstrap SSH session (before it closes)
    private(set) var bootstrapKeyExchange: String?
    private(set) var bootstrapHostKey: String?
    private(set) var bootstrapCipher: String?
    private(set) var bootstrapMac: String?

    /// Server auth banners (`SSH_MSG_USERAUTH_BANNER`) captured during the
    /// bootstrap SSH authentication. Drained by `consumeAuthBanners()` at the
    /// `.running` emit site for inline display, like real `ssh`.
    private var authBanners: [String] = []

    /// Returns (and clears) the server auth banners captured during the bootstrap
    /// SSH authentication, in arrival order.
    func consumeAuthBanners() -> [String] {
        let banners = authBanners
        authBanners = []
        return banners
    }

    // MARK: - Trzsz-Specific

    /// Host key validation callback — MUST be set before start() for security
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// Keyboard-interactive (RFC 4256) challenge callback for the tsshd bootstrap
    /// SSH connection. Returns one response per prompt, or nil to cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    /// State change callback
    var onStateChange: ((TrzszSessionState) -> Void)?

    /// Set by a tmux -CC gateway's `TerminalView` when its `TmuxController` goes
    /// live. Invoked on the main actor when the server discarded buffered
    /// terminal OUTPUT on a lossy reconnect, so the gateway can perform a full
    /// surface reset + recapture. Arguments are the discarded (lines, bytes).
    var onOutputDiscarded: ((Int, Int) -> Void)?

    /// Agent approval callback — forwarded to UI
    var onAgentApprovalRequest: ((SSHAgentApprovalRequest) -> Void)?

    /// The trzsz configuration
    let config: TrzszConfig

    /// Terminal UUID for credential persistence
    var terminalId: UUID?

    /// Current session state
    private(set) var state: TrzszSessionState = .initial {
        didSet {
            // Clear the auth-banner card on user-initiated or clean teardown
            // (.disconnected / .serverShutdown) — but NOT on .failed:
            // Tailscale SSH sends its rejection reason as an auth banner
            // immediately before disconnecting, so on bootstrap-auth failure
            // the card is the only surface holding the explanation and must
            // outlive the failure. It outlives it on a countdown, not forever,
            // which is what a standalone (non-embedded) session relies on.
            switch state {
            case .disconnected, .serverShutdown:
                authBannerCardModel.clear()
            case .failed:
                authBannerCardModel.scheduleAutoDismiss()
            default:
                break
            }
            onStateChange?(state)
        }
    }

    /// Mirrors bootstrap SSH auth banners into the nonmodal per-pane card
    /// while tsshd spawn authentication is pending.
    let authBannerCardModel = SSHAuthBannerCardModel()

    /// Current latency in milliseconds
    var latencyMs: Int? {
        goTransport?.estimatedRTTMs
    }

    /// Published banner state for SwiftUI overlay (like Mosh)
    @Published private(set) var roamBannerState: TrzszRoamBannerState?

    /// Whether the transport is currently in a timeout state
    var isTimeout: Bool {
        goTransport?.isTimeout ?? false
    }

    /// Whether the Go transport currently believes it has live network
    /// contact. `state` is NOT this signal: it intentionally stays `.running`
    /// across transport drops because Go reconnects internally (see the
    /// `.disconnected` case in `transport(_:didChangeState:)`). This combines
    /// the real health views instead: the live Go-side timeout flag, the
    /// health-monitor loss timestamp (set on a >3s contact timeout or a
    /// `.reconnecting` transition, cleared on positive health or real inbound
    /// data), and the roam banner. Used by the tmux blackout escalation to
    /// distinguish "transport healthy yet silent" (unrecoverable stall) from
    /// "known network loss" (Go will reconnect and redeliver — keep waiting).
    /// ROOTSHELL-TMUX (id=tmux-blackout-escalation)
    var transportBelievesHealthy: Bool {
        isRunning && !isTimeout && lastNetworkLossAt == nil && roamBannerState == nil
    }

    // MARK: - Private State

    /// Go-backed transport layer (native KCP/QUIC implementation)
    private var goTransport: TrzszGoTransport?

    /// A `tmux -CC` gateway is LIVE on this session, so the tsshd server must KEEP
    /// pending input across a roam rather than discard it. Sticky across transport
    /// rebuilds while control mode lasts. ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    private var controlModeKeepPendingInput = false

    /// A `tmux -CC` gateway on this session has ENDED. Suppresses the STATIC
    /// auto-start inference (`tmuxAutoEnable && .control`) on later transport
    /// rebuilds: that config says "launch tmux on connect", but a resumed session
    /// does NOT relaunch it, so without this a rebuilt transport would re-enable
    /// keep-pending for a plain shell the user configured to discard.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    private var controlModeEnded = false

    /// The single in-flight keep-pending-input applier, or nil when none is
    /// running. At most ONE exists: it re-reads `effectiveKeepPendingInput` on
    /// every pass, so a push arriving while it runs is absorbed rather than
    /// appended. Chaining a task per push instead would build an unbounded queue
    /// of waiters whenever a Go call stalls — and reconciles are frequent.
    /// Serialisation matters because an enable and a disable can be issued close
    /// together and the Go worker queue gives no FIFO guarantee, so without it the
    /// LAST value to land on the server is nondeterministic.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    private var keepPendingInputApply: Task<Void, Never>?
    /// Bounded retries for a FAILED push. Teardown issues exactly one disable and
    /// then drops the controller, so without an internal retry a transient failure
    /// would leave the server enabled for the rest of the session.
    private static let keepPendingInputMaxAttempts = 4

    /// Keep-pending-input this session should be running with right now.
    ///
    /// The auto-start term is an INFERENCE — "this connect will launch `tmux -CC`
    /// itself, so arm the server before it does" — and it holds only while that is
    /// actually true. `wasResumed` sessions skip the launch command entirely (see
    /// its use in the resume path), and `controlModeEnded` marks a gateway that has
    /// already exited to a plain shell; in both cases the config still says
    /// "auto -CC" while no control stream exists, and honouring it would override
    /// a user who asked for pending input to be discarded. A LIVE gateway is
    /// covered by `controlModeKeepPendingInput` instead, which is set from the
    /// reconcile and so does not depend on any inference.
    private var effectiveKeepPendingInput: Bool {
        if config.keepPendingInput || controlModeKeepPendingInput { return true }
        guard !controlModeEnded, !wasResumed else { return false }
        return config.sshConfig.tmuxAutoEnable && config.sshConfig.tmuxAutoMode == .control
    }

    /// Port forward manager for TSSH transport
    private var trzszPortForwardManager: TrzszPortForwardManager?

    /// SSH agent manager for agent forwarding
    private var agentManager: SSHAgentManager?

    /// Agent bridge (strong ref to prevent dealloc while Go holds it)
    private var agentBridge: TrzszAgentBridge?

    /// GPG agent manager for Unix-socket forwarding.
    private var gpgAgentManager: GPGAgentManager?

    /// Pump task consuming GPG approval requests. PassthroughSubject
    /// never completes, so the task only exits via cancel — done on
    /// disconnect / endSession.
    private var gpgApprovalTask: Task<Void, Never>?

    /// GPG bridge (strong ref to prevent dealloc while Go holds it).
    private var gpgStreamLocalBridge: TrzszStreamLocalBridge?

    /// Remote socket path the GPG forward is bound to, kept so we can
    /// call `DisableStreamLocalForwarding` on teardown.
    private var gpgRemoteSocketPath: String?

    /// Approval-request callback for forwarded GPG `PKSIGN` operations.
    /// Set by the view layer the same way ``onAgentApprovalRequest`` is.
    var onGPGAgentApprovalRequest: ((GPGAgentApprovalRequest) -> Void)?

    /// Companion callback fired when a previously-surfaced GPG
    /// approval request is no longer wanted (the session is tearing
    /// down). MainView removes matching entries from its approval
    /// queue so a disconnected session can't leave a stale prompt up.
    var onGPGAgentApprovalWithdrawn: ((UUID) -> Void)?

    /// Disconnects the transport (sends "close" to server)
    private func disconnectTransport() {
        pendingRelay?.disconnect()
        pendingRelay = nil
        goTransport?.disconnect()
        goTransport = nil
    }

    /// Abandons the transport without sending "close" to server.
    /// Used when preserving the server session for future Attach().
    private func abandonTransport() {
        pendingRelay?.abandon()
        pendingRelay = nil
        goTransport?.abandon()
        goTransport = nil
    }

    /// Sends data through the Go transport
    private func transportSend(_ data: Data) {
        goTransport?.send(data)
    }

    /// Server info from spawn
    private var serverInfo: TrzszServerInfo?

    /// Runs one short command over THIS session's existing tsshd connection.
    ///
    /// The command is a child of the same tsshd that owns this pane's shell,
    /// which is what lets an out-of-band probe identify the pane from the
    /// process tree. Opening a separate SSH connection instead would cost an
    /// extra authentication AND land outside that tree, where nothing can
    /// identify the pane. (id=agent-project)
    func runProbeCommand(_ command: String) async throws -> Data {
        guard let goTransport else {
            throw TrzszError.connectionFailed("No transport for probe command")
        }
        return try await goTransport.runRemoteCommand(command)
    }

    /// Opens a long-lived auxiliary exec channel on this session's transport.
    /// Not subject to the one-probe slot: the channel streams for as long as
    /// the caller keeps it, and dies with the transport.
    func openExecChannel(_ command: String) async throws -> AsyncBytePipe {
        guard let goTransport else {
            throw TrzszError.connectionFailed("No transport for exec channel")
        }
        return try await goTransport.openExecChannel(command)
    }

    /// SSH client kept alive during QUIC establishment
    /// Must be closed after QUIC connection is established
    private var spawnSSHClient: SSHClient?

    /// Jump SSH client kept alive during QUIC establishment
    private var spawnJumpClient: SSHClient?

    /// Resize requested before session became running
    private var pendingResize: TerminalPTY.TerminalSize?

    /// Last resize sent to server
    private var lastSentResize: TerminalPTY.TerminalSize?

    /// Whether this session was resumed from saved credentials
    private(set) var wasResumed: Bool = false

    /// Most recent moment the transport was confirmed connected to the
    /// server. Set on successful connect/attach and refreshed by
    /// `stateUpdateTask` while running. Held in memory only — persistence
    /// piggybacks on `WindowStateManager`'s autosave (via
    /// `LeafData.trzszLastConnectedAt`) to avoid keychain churn.
    private(set) var lastConnectedAt: Date?

    /// Optional deadline reference passed in via `start(...)` when this
    /// session is being restored from a saved window state. Used as the
    /// "since last alive" anchor until a newer live heartbeat is available.
    /// When neither exists, the retry loop starts its bounded window at now.
    private var restoredLastConnectedAt: Date?

    /// Session credentials for resume
    private var savedCredentials: TrzszSessionCredentials?
    private var relayRebuildRequested = false
    private var resumeLoopActive = false
    private var relayRecoveryTask: Task<Void, Never>?
    /// Retained across failed recovery attempts until each remote bind is acknowledged.
    private var recoveringRemoteForwards: Set<UUID> = []

    var canRebuildJumpConnection: Bool {
        config.sshConfig.jumpHost?.tsshRelay != nil && savedCredentials?.relay != nil
    }

    /// Explicit action: authenticate only to the jump and keep the target PTY.
    func rebuildJumpConnection() { recoverJumpConnection(rebuild: true) }

    /// A receiver can replace the relay's active client before sending its ACK.
    /// Reclaim our saved target session when the transfer fails or is cancelled.
    func recoverAfterFailedRelayTransfer() { recoverJumpConnection(rebuild: false) }

    private func recoverJumpConnection(rebuild: Bool) {
        guard canRebuildJumpConnection, !didEndSession, !userInitiatedDisconnect else { return }
        relayRebuildRequested = relayRebuildRequested || rebuild
        guard !resumeLoopActive, relayRecoveryTask == nil, let terminalId else { return }
        goTransport?.delegate = nil
        isRunning = false
        stopPeriodicStateUpdates()
        let previousForwards = trzszPortForwardManager
        trzszPortForwardManager = nil
        relayRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.relayRecoveryTask = nil }
            if let remoteIDs = await previousForwards?.stopAllForwardsAndWait() {
                self.recoveringRemoteForwards.formUnion(remoteIDs)
            }
            guard !Task.isCancelled, !self.didEndSession, !self.userInitiatedDisconnect else { return }
            self.abandonTransport()
            switch await self.attemptResume(terminalId: terminalId, preserveCredentialsOnFailure: true) {
            case .resumed, .aborted:
                break
            case .fallback(let reason):
                guard !Task.isCancelled, !self.didEndSession, !self.userInitiatedDisconnect else { return }
                self.goTransport?.delegate = nil
                self.abandonTransport()
                self.isRunning = false
                self.state = .failed
                self.publishRoamBannerState(.connectionLost(
                    reason: "Jump recovery failed: \(reason). Saved credentials were kept; you can retry Rebuild Jump Connection."
                ))
            }
        }
    }

    private var pendingRelay: TrzszGoTransport?
    private var relayCredentials: TrzszRelayCredentials?
    private var effectiveTransportMTU: Int?

    /// Task for periodic credential state updates
    private var stateUpdateTask: Task<Void, Never>?

    /// Task for async, off-main transport health refreshes.
    private var healthMonitorTask: Task<Void, Never>?

    /// 1 Hz ticker that re-renders the visible roam banner's "seconds since
    /// contact" counter. Runs ONLY while a banner is showing; health state
    /// itself arrives via pushed Go transitions, not this ticker.
    private var bannerRefreshTask: Task<Void, Never>?

    /// Defers tssh UI-affecting state after foreground resume so SwiftUI's
    /// scene restoration can settle before disrupted transports publish.
    private var foregroundStateHoldTask: Task<Void, Never>?
    private var foregroundStateHoldUntil: Date?
    private var pendingRoamBannerStateDuringHold: TrzszRoamBannerState??
    private var isResumingFromForeground: Bool = false
    private var lastPositiveHeartbeatAt: Date?
    private var currentHeartbeatProbeStartedAt: Date?

    /// Interval for periodic state updates (30 seconds)
    private static let stateUpdateInterval: TimeInterval = 30.0

    /// Interval for the health reconciliation poll. Health transitions are
    /// pushed from Go (see `transport(_:didChangeHealthTimeout:)`); this slow
    /// poll is only a safety net for a wedged Go runtime or a transition
    /// dropped while backgrounded, so it can be far coarser than the old
    /// 1-second cadence without affecting detection latency.
    private static let healthReconcileInterval: TimeInterval = 10.0

    /// Matches the TerminalScrollView foreground banner grace.
    private static let foregroundStateHoldDuration: TimeInterval = 3.5

    /// Time to wait for an async Go heartbeat result before showing stale contact.
    private static let heartbeatResponseTimeout: TimeInterval = 5.0

    /// Initial backoff between attach retries (seconds).
    private static let resumeInitialBackoff: TimeInterval = 2.0

    /// Maximum backoff between attach retries (seconds).
    private static let resumeMaxBackoff: TimeInterval = 30.0


    /// Timestamp of most recent network loss
    private var lastNetworkLossAt: Date?

    /// Avoid repeated disconnect signals
    private var didSignalDisconnect: Bool = false

    /// Track user-initiated disconnects to avoid auto-reconnect
    private var userInitiatedDisconnect: Bool = false

    /// Suppress onSessionEnd when we're handing off to reconnection manager
    private var suppressSessionEnd: Bool = false

    /// Cancellables for network reachability observers
    private var networkChangeCancellables: Set<AnyCancellable> = []

    /// Debug label from the transport (e.g., "S1 user@host") for log tagging
    private var sessionDebugLabel: String = ""

    /// Prefix for debug log messages — uses transport label when available, falls back to display name
    private var debugPrefix: String {
        sessionDebugLabel.isEmpty ? config.displayName : sessionDebugLabel
    }

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszSession"
    )

    /// OpenSSH-style escape-character filter (~. disconnect, ~? help, etc.)
    private let escapeFilter = SSHEscapeFilter()

    // MARK: - Initialization

    /// Creates a new trzsz session
    /// - Parameters:
    ///   - config: trzsz connection configuration
    ///   - pty: Terminal PTY
    ///   - terminalId: Optional terminal UUID for credential persistence
    init(config: TrzszConfig, pty: TerminalPTY, terminalId: UUID? = nil) {
        self.config = config
        self.pty = pty
        self.terminalId = terminalId
        wireEscapeFilter()
    }

    private func wireEscapeFilter() {
        escapeFilter.onEcho = { [weak self] text in
            self?.onOutput?(text)
        }
        escapeFilter.onDisconnect = { [weak self] in
            // Defer the teardown to the next main-actor turn so sendInput unwinds
            // cleanly before stop() starts tearing down the transport.
            Task { @MainActor in
                self?.stop()
            }
        }
        escapeFilter.onShowConnectionInfo = { [weak self] in
            guard let self else { return }
            self.onOutput?(self.formatConnectionInfoForEcho())
        }
        escapeFilter.onListForwards = { [weak self] in
            guard let self else { return }
            self.onOutput?(self.formatForwardsForEcho())
        }
    }

    private func formatConnectionInfoForEcho() -> String {
        let ssh = config.sshConfig
        var lines: [String] = []
        lines.append("\(ssh.username)@\(ssh.host):\(ssh.port)")
        if let jump = ssh.jumpHost {
            lines.append("via: \(jump.username)@\(jump.host):\(jump.port)")
        }
        if let kex = bootstrapKeyExchange { lines.append("kex:    \(kex)") }
        if let cipher = bootstrapCipher { lines.append("cipher: \(cipher)") }
        if let mac = bootstrapMac { lines.append("mac:    \(mac)") }
        if let mode = serverInfo?.mode ?? savedCredentials?.mode {
            lines.append("transport: \(mode.rawValue)")
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func formatForwardsForEcho() -> String {
        let forwards = config.sshConfig.portForwardConfig.forwards.filter { $0.enabled }
        guard !forwards.isEmpty else {
            return SSHEscapeFilter.noForwardsMessage()
        }
        var lines: [String] = []
        for f in forwards {
            // Report the live runtime status from the manager so a failed bind
            // or stopped forward is surfaced rather than the configured intent.
            let status = trzszPortForwardManager?.status(for: f) ?? .pending
            lines.append("  \(f.displayString)  [\(SSHEscapeFilter.describe(forwardStatus: status))]")
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    // MARK: - TerminalSession Protocol Implementation

    /// Starts the trzsz session
    /// - Parameters:
    ///   - restoringFromTerminalId: If provided, attempts to resume from saved credentials first.
    ///   - restoredLastConnectedAt: For restored sessions, the autosaved
    ///     `lastConnectedAt` heartbeat from the previous run. Drives the
    ///     resume retry loop's 24h `AliveTimeout` deadline; defaults to
    ///     `nil`, in which case the loop uses live activity or starts at now.
    func start(restoringFromTerminalId: UUID? = nil, restoredLastConnectedAt: Date? = nil) async throws {
        guard !isRunning else {
            throw TrzszError.sessionAlreadyStarted
        }

        // Reset state for a fresh start
        userInitiatedDisconnect = false
        didSignalDisconnect = false
        suppressSessionEnd = false
        lastNetworkLossAt = nil
        escapeFilter.reset()
        self.restoredLastConnectedAt = restoredLastConnectedAt
        self.lastConnectedAt = nil

        let host = config.host
        Self.logger.info("Starting trzsz session to \(host)")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] start(): restoringFromTerminalId=\(restoringFromTerminalId?.uuidString.prefix(8) ?? "nil"), terminalId=\(terminalId?.uuidString.prefix(8) ?? "nil")")
        state = .initial
        didEndSession = false

        // If we have a terminal ID to restore from, try resuming first
        if let restoreId = restoringFromTerminalId ?? terminalId {
            ResumeDebugLogger.shared.log("[\(debugPrefix)] Attempting resume with restoreId=\(restoreId.uuidString.prefix(8))")
            switch await attemptResume(terminalId: restoreId) {
            case .resumed:
                return  // Successfully resumed
            case .aborted:
                // User closed the tab (or the task was cancelled) during the
                // retry loop. Throw so callers don't run success-side
                // effects (history recording, response monitoring, etc.) —
                // this isn't a started session. CancellationError is the
                // canonical Swift signal for "no error happened, just stop."
                ResumeDebugLogger.shared.log("[\(debugPrefix)] Resume aborted (tab closing), throwing CancellationError")
                throw CancellationError()
            case .fallback:
                ResumeDebugLogger.shared.log("[\(debugPrefix)] Resume failed, falling through to SSH spawn")
                // Fall through to normal SSH spawn
            }
        }

        // Normal SSH spawn path
        try await spawnAndConnect()
    }

    /// Outcome of `attemptResume`: restoration may spawn a fresh session;
    /// explicit jump recovery keeps credentials and surfaces an unavailable
    /// session as a retryable error instead.
    private enum ResumeOutcome {
        /// Successfully reattached to the server-side session.
        case resumed
        /// The retry loop was interrupted by the user closing the tab or
        /// the enclosing task being cancelled. Caller must NOT fall back.
        case aborted
        /// Resume isn't possible (no creds, expired creds, missing session
        /// id, server gone for >24h). Caller decides whether to spawn or retry.
        case fallback(reason: String)
    }

    /// Standard start() without restoration
    func start() async throws {
        try await start(restoringFromTerminalId: nil, restoredLastConnectedAt: nil)
    }

    // MARK: - Resume Logic

    /// Attempts to resume a session from saved credentials.
    ///
    /// Retries the attach indefinitely until one of:
    /// - the attach succeeds (`.resumed`);
    /// - the user closes the tab (`terminate()` flips `userInitiatedDisconnect`)
    ///   or the enclosing Task is cancelled (`.aborted`);
    /// - resume isn't possible — no creds, expired creds, missing session
    ///   id, or the gap since the last successful connection exceeds the
    ///   server's AliveTimeout (24h) (`.fallback`).
    private func attemptResume(terminalId: UUID, preserveCredentialsOnFailure: Bool = false) async -> ResumeOutcome {
        resumeLoopActive = true
        defer { resumeLoopActive = false }
        Self.logger.info("Attempting to resume trzsz session for terminal \(terminalId.uuidString)")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] attemptResume: keychain lookup uuid=\(terminalId.uuidString)")

        // Load credentials from keychain (one-shot — no retry on missing creds)
        var credentials: TrzszSessionCredentials
        do {
            credentials = try KeychainManager.shared.loadTrzszSessionCredentials(terminalId: terminalId)
            Self.logger.info("Found saved credentials for terminal \(terminalId.uuidString): \(credentials.displayName), age=\(credentials.age)")
        } catch {
            Self.logger.info("No saved credentials for terminal \(terminalId.uuidString): \(error.localizedDescription)")
            ResumeDebugLogger.shared.log("[\(debugPrefix)] NO CREDENTIALS FOUND: \(error.localizedDescription)")
            return .fallback(reason: "Saved session credentials could not be loaded")
        }

        relayCredentials = credentials.relay
        effectiveTransportMTU = credentials.transportMTU ?? credentials.relay?.targetMTU
        let credHost = credentials.host
        let credPort = credentials.udpPort
        let credMode = credentials.mode.rawValue
        let credAge = credentials.age
        let credHasProxyKey = credentials.proxyKey != nil
        let credClientId = credentials.clientId
        let credServerId = credentials.serverId
        ResumeDebugLogger.shared.log("[\(debugPrefix)] Credentials loaded: host=\(credHost), port=\(credPort), mode=\(credMode), age=\(credAge), hasProxyKey=\(credHasProxyKey), clientId=\(credClientId), serverId=\(credServerId)")

        // Reference time for the 24h server-side AliveTimeout window.
        // Prefer the latest confirmed heartbeat, including activity since
        // restoration. When absent (first launch after upgrade, or app was
        // killed before the first window-state autosave), treat it as
        // "unknown" and anchor on `now` so the retry loop gets a fair
        // shot at confirming the server's liveness instead of evicting a
        // long-lived session purely on `credentials.createdAt`. Falsely
        // assuming alive for at most 24h is bounded; falsely declaring
        // dead is irreversible (credentials get deleted).
        var lastAlive = TrzszResumeActivity.latestConfirmedActivity(
            restored: restoredLastConnectedAt,
            connected: lastConnectedAt,
            heartbeat: lastPositiveHeartbeatAt,
            fallback: Date()
        )

        // Up-front expiry check: if the server's AliveTimeout window is
        // already blown, the attachable server has exited — don't bother.
        if Date().timeIntervalSince(lastAlive) > TrzszSessionCredentials.maxAge {
            Self.logger.info("Resume failed: server AliveTimeout window elapsed before retry")
            ResumeDebugLogger.shared.log("[\(debugPrefix)] EXPIRED up-front: age=\(credAge), lastAlive=\(lastAlive)")
            state = .resumeFallback(reason: "Session credentials expired")
            if !preserveCredentialsOnFailure {
                try? KeychainManager.shared.deleteTrzszSessionCredentials(terminalId: terminalId)
            }
            return .fallback(reason: "Session credentials expired")
        }

        // Require saved sessionID for attach (no point retrying — it'll never appear)
        guard let savedSessionID = credentials.sessionID else {
            Self.logger.warning("Resume failed: no saved sessionID")
            ResumeDebugLogger.shared.log("[\(debugPrefix)] NO SESSION ID in credentials")
            state = .resumeFallback(reason: "No saved session ID")
            if !preserveCredentialsOnFailure {
                try? KeychainManager.shared.deleteTrzszSessionCredentials(terminalId: terminalId)
            }
            return .fallback(reason: "No saved session ID")
        }

        // Restore bootstrap SSH algorithms from credentials (once — they don't change between retries)
        self.bootstrapKeyExchange = credentials.bootstrapKeyExchange
        self.bootstrapHostKey = credentials.bootstrapHostKey
        self.bootstrapCipher = credentials.bootstrapCipher
        self.bootstrapMac = credentials.bootstrapMac

        state = .resumingSession(host: credentials.host, port: credentials.udpPort)

        var currentClientId = credentials.clientId
        var backoff = Self.resumeInitialBackoff

        while true {
            if userInitiatedDisconnect {
                ResumeDebugLogger.shared.log("[\(debugPrefix)] retry loop exited: userInitiatedDisconnect")
                return .aborted
            }
            if Task.isCancelled {
                ResumeDebugLogger.shared.log("[\(debugPrefix)] retry loop exited: task cancelled")
                return .aborted
            }

            lastAlive = TrzszResumeActivity.latestConfirmedActivity(
                restored: restoredLastConnectedAt,
                connected: lastConnectedAt,
                heartbeat: lastPositiveHeartbeatAt,
                fallback: lastAlive
            )
            if Date().timeIntervalSince(lastAlive) > TrzszSessionCredentials.maxAge {
                Self.logger.info("Resume retry loop: server AliveTimeout window elapsed, giving up")
                ResumeDebugLogger.shared.log("[\(debugPrefix)] EXPIRED during retry loop (>24h since last connection)")
                if !preserveCredentialsOnFailure {
                    try? KeychainManager.shared.deleteTrzszSessionCredentials(terminalId: terminalId)
                }
                state = .resumeFallback(reason: "Saved session expired")
                return .fallback(reason: "Saved session expired")
            }

            if relayRebuildRequested {
                relayRebuildRequested = false
                do {
                    let rebuilt = try await TrzszSpawnHelper.rebuildRelay(
                        config: config, onHostKeyValidation: onHostKeyValidation,
                        onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)
                    let requiredMTU = credentials.transportMTU ?? credentials.relay?.targetMTU ?? config.mtu
                    guard rebuilt.credentials.targetMTU >= requiredMTU else {
                        rebuilt.transport.disconnect()
                        throw TrzszError.connectionFailed("The new jump connection cannot carry this session's saved packet size.")
                    }
                    if userInitiatedDisconnect || Task.isCancelled {
                        rebuilt.transport.disconnect()
                        return .aborted
                    }
                    var relay = rebuilt.credentials
                    relay = TrzszRelayCredentials(host: relay.host, serverInfo: relay.serverInfo,
                                                  mtu: relay.mtu, targetMTU: requiredMTU)
                    pendingRelay = rebuilt.transport
                    relayCredentials = relay
                    credentials.relay = relay
                    credentials.transportMTU = requiredMTU
                    effectiveTransportMTU = requiredMTU
                } catch {
                    publishRoamBannerState(.connectionLost(reason: error.localizedDescription))
                    await sleepCancellable(seconds: backoff)
                    continue
                }
            }

            // Each new connection must use a different ClientID (per upstream guidance).
            // Skip 0 since that's the "attachable mode, generate one" sentinel.
            let nextClientId = currentClientId &+ 1
            let effectiveClientId = nextClientId == 0 ? 1 : nextClientId

            // Persist BEFORE the Go transport sees this ID. The server records it
            // on receipt and rejects any future Attach with a smaller-or-equal
            // serial. We must not let the transport see this ID unless it is
            // already durable — otherwise a process kill after send-but-before-
            // save reproduces the same "old_serial=X, new_serial=Y" rejection
            // this code is here to prevent.
            var pendingCredentials = credentials
            pendingCredentials.clientId = effectiveClientId

            var persisted = false
            var lastPersistError: Error?
            for attempt in 1...3 {
                do {
                    try KeychainManager.shared.saveTrzszSessionCredentials(
                        pendingCredentials,
                        terminalId: terminalId
                    )
                    persisted = true
                    ResumeDebugLogger.shared.log("[\(debugPrefix)] persisted clientId=\(effectiveClientId) before Attach (attempt \(attempt))")
                    break
                } catch {
                    lastPersistError = error
                    let errDesc = error.localizedDescription
                    Self.logger.warning("Keychain save attempt \(attempt)/3 failed for clientId=\(effectiveClientId): \(errDesc)")
                    ResumeDebugLogger.shared.log("[\(debugPrefix)] CLIENTID PERSIST attempt \(attempt)/3 FAILED: \(errDesc)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }

            // The retry sleep above is a cancellation/user-close window — if the
            // tab was closed or the task was cancelled during that 100ms,
            // honor it before proceeding (whether to connect or to fall back).
            // Cancellation wins over fallback so we don't spawn a fresh session
            // for a tab the user has already left.
            if userInitiatedDisconnect {
                ResumeDebugLogger.shared.log("[\(debugPrefix)] retry loop exited after persist sleep: userInitiatedDisconnect")
                return .aborted
            }
            if Task.isCancelled {
                ResumeDebugLogger.shared.log("[\(debugPrefix)] retry loop exited after persist sleep: task cancelled")
                return .aborted
            }

            if !persisted {
                let errDesc = lastPersistError?.localizedDescription ?? "unknown error"
                Self.logger.error("Refusing to send clientId=\(effectiveClientId) to server — Keychain persist failed 3x: \(errDesc)")
                ResumeDebugLogger.shared.log("[\(debugPrefix)] FALLBACK: cannot persist clientId, refusing to advance server serial")
                if !preserveCredentialsOnFailure {
                    try? KeychainManager.shared.deleteTrzszSessionCredentials(terminalId: terminalId)
                }
                state = .resumeFallback(reason: "Cannot persist session state")
                return .fallback(reason: "Cannot persist session state")
            }

            // Save committed — safe to advance the in-memory tracker and let
            // the Go transport see this ID.
            currentClientId = effectiveClientId
            savedCredentials = pendingCredentials

            var serverInfo = pendingCredentials.toServerInfo()
            serverInfo.clientId = effectiveClientId

            ResumeDebugLogger.shared.log("[\(debugPrefix)] connectGoTransport: host=\(credHost), port=\(credPort), clientId=\(effectiveClientId), sessionID=\(savedSessionID)")

            // Set wasResumed BEFORE connectGoTransport so that onReady
            // (fired inside connectGoTransport) sees it and skips the launch command.
            wasResumed = true

            do {
                try await connectGoTransport(
                    host: credentials.host,
                    serverInfo: serverInfo,
                    connectOnly: true
                )

                guard let transport = goTransport else {
                    throw TrzszError.connectionFailed("No transport after connect")
                }
                let initialSize = pendingResize ?? pty.windowSize
                let cols = Int(initialSize.cols > 0 ? initialSize.cols : 80)
                let rows = Int(initialSize.rows > 0 ? initialSize.rows : 24)
                // Both the jiggle below and tsshd's own attach-time redraw
                // make the remote repaint; a BEL in that repaint is our
                // own echo, not news, and neither is the agent state the
                // rebuilt screen classifies to. Panes inherit via
                // `parentUUID`.
                TerminalBellSuppressor.suppress(
                    terminalId, for: TerminalBellSuppressor.forcedRedraw)
                TerminalBellSuppressor.suppressRebuild(terminalId)
                try await transport.attachToSession(
                    sessionID: savedSessionID,
                    cols: cols,
                    rows: rows
                )
                try Task.checkCancellation()
                guard !userInitiatedDisconnect, !didEndSession else { return .aborted }
                pendingResize = nil

                // Force a full screen redraw by sending a resize "jiggle".
                // The server's PTY may already have this size from the previous
                // session, so attaching with the same dimensions won't trigger
                // SIGWINCH. Send a slightly different size first, then the correct
                // size — two SIGWINCHs that force the TUI app to fully redraw.
                let jiggleCols: UInt16
                let jiggleRows: UInt16
                if initialSize.cols > 1 {
                    jiggleCols = initialSize.cols - 1
                    jiggleRows = initialSize.rows
                } else if initialSize.rows > 1 {
                    jiggleCols = initialSize.cols
                    jiggleRows = initialSize.rows - 1
                } else {
                    jiggleCols = initialSize.cols + 1
                    jiggleRows = initialSize.rows
                }
                sendResize(width: jiggleCols, height: jiggleRows)
                sendResize(width: initialSize.cols, height: initialSize.rows)
                lastSentResize = initialSize
                Self.logger.info("Sent resume resize jiggle: \(jiggleCols)x\(jiggleRows) → \(initialSize.cols)x\(initialSize.rows)")

                // Post-connection setup (mirrors connectGoTransport's non-connectOnly path)
                isRunning = true
                connectionStartTime = Date()
                markHeartbeatPositive()
                state = .running(latencyMs: nil)

                var updatedCredentials = credentials
                updatedCredentials.clientId = effectiveClientId
                updatedCredentials.sessionID = transport.sessionID
                try? KeychainManager.shared.saveTrzszSessionCredentials(
                    updatedCredentials,
                    terminalId: terminalId
                )
                savedCredentials = updatedCredentials

                await startConfiguredPortForwards(on: transport)
                try Task.checkCancellation()
                guard !userInitiatedDisconnect, !didEndSession else { return .aborted }
                startPeriodicStateUpdates()
                onReady?()

                ResumeDebugLogger.shared.log("[\(debugPrefix)] RESUME SUCCESS via Attach: mode=\(credMode), sessionID=\(savedSessionID)")
                Self.logger.info("trzsz session resumed via Attach to session \(savedSessionID)")
                return .resumed

            } catch {
                wasResumed = false
                Self.logger.warning("Resume attempt failed (will retry): \(error.localizedDescription)")
                ResumeDebugLogger.shared.log("[\(debugPrefix)] RETRY after failure: \(error.localizedDescription), backoff=\(backoff)s")
                abandonTransport()
                if credentials.relay != nil {
                    publishRoamBannerState(.connectionLost(reason: "Jump relay unavailable. Retry or rebuild the jump connection."))
                }
                // Keep credentials and stay in .resumingSession — server may still be alive.

                await sleepCancellable(seconds: backoff)
                backoff = min(backoff * 2, Self.resumeMaxBackoff)
            }
        }
    }

    /// Sleeps for the given duration in 500ms slices, returning early when
    /// the user closes the tab or the enclosing task is cancelled. Used by
    /// the resume retry backoff so `terminate()` interrupts within ~500ms.
    private func sleepCancellable(seconds: TimeInterval) async {
        let sliceNs: UInt64 = 500_000_000
        var remainingNs = UInt64(max(0, seconds) * 1_000_000_000)
        while remainingNs > 0 {
            if userInitiatedDisconnect || Task.isCancelled { return }
            let chunk = min(remainingNs, sliceNs)
            try? await Task.sleep(nanoseconds: chunk)
            remainingNs -= chunk
        }
    }

    // MARK: - SSH Spawn Path

    /// Spawns tsshd via SSH and connects using QUIC
    private func spawnAndConnect() async throws {
        do {
            // Phase 1: Resolve hostname
            let connectionHost = try await TrzszSpawnHelper.connectionHost(for: config)

            Self.logger.info("Resolved address: \(connectionHost)")

            // Phase 2: Spawn tsshd via SSH (keeping connection open)
            state = .spawningServer
            let (serverInfo, sshClient, jumpClient) = try await spawnTsshd(resolvedHost: connectionHost)

            // Store SSH clients - will be closed after QUIC connects
            self.spawnSSHClient = sshClient
            self.spawnJumpClient = jumpClient
            self.serverInfo = serverInfo

            Self.logger.info("tsshd spawned on port \(serverInfo.port), mode=\(serverInfo.mode.rawValue), connecting...")

            // Phase 3: Connect via native Go transport
            let execCommand = config.sshConfig.effectiveExecCommand
            try await connectGoTransport(host: connectionHost, serverInfo: serverInfo, execCommand: execCommand)

        } catch let error as TrzszError {
            state = .failed
            await closeSpawnSSHClients()
            Self.logger.error("trzsz session failed: \(error.localizedDescription)")
            onError?(error)
            throw error
        } catch let error as OpenPubkeyError {
            // A cancelled/failed inline opkssh sign-in during the tsshd SSH
            // bootstrap. Preserve the typed error (don't flatten it into an opaque
            // sshConnectionFailed) so the retry layer classifies it as permanent.
            state = .failed
            await closeSpawnSSHClients()
            onError?(error)
            throw error
        } catch {
            state = .failed
            await closeSpawnSSHClients()
            let trzszError = TrzszError.sshConnectionFailed(reason: error.localizedDescription)
            Self.logger.error("trzsz session failed: \(error.localizedDescription)")
            onError?(trzszError)
            throw trzszError
        }
    }

    /// Spawns tsshd directly via SSH and returns server info
    /// SSH connection is kept open - caller must close after QUIC connects
    private func spawnTsshd(resolvedHost: String) async throws -> (TrzszServerInfo, SSHClient, SSHClient?) {
        let result = try await TrzszSpawnHelper.spawnTsshd(
            config: config,
            resolvedHost: resolvedHost,
            onHostKeyValidation: onHostKeyValidation,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge,
            authBannerObserver: authBannerCardModel.makeBufferObserver(
                hostLabel: config.sshConfig.host
            )
        )

        // Capture bootstrap SSH algorithms from spawn
        self.bootstrapKeyExchange = result.sshKeyExchange
        self.bootstrapHostKey = result.sshHostKey
        self.bootstrapCipher = result.sshCipher
        self.bootstrapMac = result.sshMac

        // Capture server auth banners for inline display at `.running`.
        self.authBanners = result.authBanners

        pendingRelay = result.relayTransport
        relayCredentials = result.relayCredentials
        effectiveTransportMTU = result.targetMTU
        return (result.serverInfo, result.sshClient, result.jumpClient)
    }

    /// Closes the SSH clients used for spawning
    private func closeSpawnSSHClients() async {
        pendingRelay?.disconnect()
        pendingRelay = nil
        if let client = spawnSSHClient {
            Self.logger.debug("Closing spawn SSH client")
            try? await client.close()
            spawnSSHClient = nil
        }
        if let jump = spawnJumpClient {
            Self.logger.debug("Closing spawn jump SSH client")
            try? await jump.close()
            spawnJumpClient = nil
        }
    }

    /// Tell the Go transport to KEEP pending input across a roam (not discard it).
    /// Called when this session is (or becomes) a tmux -CC gateway — the control
    /// stream needs input preserved. Covers manually-typed `tmux -CC` (auto-start
    /// already forces it at connect via `isControlMode`). OUTPUT stays in discard
    /// mode (no back pressure); a lossy output discard is recovered by a full
    /// surface reset instead. Idempotent; safe before the transport connects.
    func enableControlModeKeepPendingInput() {
        // Sticky for the SESSION, not just the current transport. Without this a
        // rebuilt transport (resume / re-attach) is constructed with
        // `keepPendingInput` false for a MANUALLY-typed `tmux -CC` — only
        // auto-start sets `isControlMode` — and the gateway silently reverts to
        // discard-input-on-reconnect. tsshd then swallows every client write
        // after a roam until its 8-byte marker appears, and since the marker only
        // rides on real input while a resyncing viewer sends nothing, the resync
        // probe is buffered forever and control mode never recovers.
        // ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
        controlModeKeepPendingInput = true
        controlModeEnded = false
        pushKeepPendingInput()
    }

    /// The `tmux -CC` gateway on this session has ended: drop the override and put
    /// the transport back on the CONFIGURED behaviour. Without this the plain
    /// shell that replaces the gateway keeps replaying input typed during an
    /// outage even when the user asked for it to be discarded, and every later
    /// transport rebuild inherits the override. Idempotent.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    func disableControlModeKeepPendingInput() {
        controlModeKeepPendingInput = false
        controlModeEnded = true
        pushKeepPendingInput()
    }

    /// Drive the live transport to `effectiveKeepPendingInput`, retrying a failed
    /// push and coalescing concurrent requests into the one running worker.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    private func pushKeepPendingInput() {
        // Coalesce: the running worker re-reads the intent, so it will pick this
        // change up itself. This is what keeps per-reconcile enables from piling
        // up behind a stalled Go call.
        guard keepPendingInputApply == nil else { return }
        keepPendingInputApply = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let transport = self.goTransport else { break }
                // Re-read every pass: a newer intent supersedes the one we were
                // started for, and `connect()` applies it to a transport built later.
                let desired = self.effectiveKeepPendingInput
                if await transport.applyKeepPendingInput(desired) {
                    failures = 0
                    // Settled, unless the intent moved while we were awaiting.
                    if self.effectiveKeepPendingInput == desired { break }
                    continue
                }
                failures += 1
                guard failures < Self.keepPendingInputMaxAttempts else {
                    ResumeDebugLogger.shared.log(
                        "[\(self.sessionDebugLabel)] keep-pending-input=\(desired) GAVE UP after \(failures) attempts")
                    break
                }
                try? await Task.sleep(for: .seconds(Double(failures)))
            }
            self?.keepPendingInputApply = nil
        }
    }

    /// Connects to tsshd via native Go transport (preferred)
    /// Uses the Go implementation for both KCP and QUIC protocols
    private func connectGoTransport(
        host: String,
        serverInfo: TrzszServerInfo,
        execCommand: String? = nil,
        connectOnly: Bool = false
    ) async throws {
        let modeStr = serverInfo.mode.rawValue
        state = serverInfo.mode == .kcp
            ? .establishingKCP(host: host, port: serverInfo.port)
            : .establishingQUIC(host: host, port: serverInfo.port)

        Self.logger.info("Connecting via Go \(modeStr) transport to \(host):\(serverInfo.port)")

        // tmux -CC over tssh: KEEP pending INPUT across a roam (input is
        // low-volume and not a back-pressure source), but let the server DISCARD
        // pending OUTPUT on reconnect. Keeping output made the server's forwarder
        // block in waitUntilReconnected() and stall the PTY (back pressure). A
        // lossy output discard is detected (DiscardNotifier) and recovered with a
        // full tmux -CC surface reset (ghostty_surface_tmux_reset) instead.
        // `effectiveKeepPendingInput` folds in all three sources: the user setting,
        // a LIVE gateway (covers a manually-typed `tmux -CC`, which the static
        // config cannot see), and the auto-start config — the last suppressed once
        // control mode has ended, since a rebuilt transport does not relaunch tmux.
        // ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
        if pendingRelay == nil, let relayCredentials {
            pendingRelay = try await TrzszSpawnHelper.resumeRelay(relayCredentials)
        }
        if config.sshConfig.jumpHost?.tsshRelay != nil && pendingRelay == nil {
            throw TrzszError.connectionFailed("Jump relay credentials are missing; direct fallback is disabled.")
        }
        let transport = try TrzszGoTransport(
            host: host,
            port: serverInfo.port,
            serverInfo: serverInfo,
            mtu: effectiveTransportMTU ?? config.mtu,
            keepPendingInput: effectiveKeepPendingInput,
            displayName: config.sshConfig.displayName,
            terminalUUID: terminalId,
            terminalType: config.sshConfig.effectiveTerminalType,
            relayTransport: pendingRelay
        )
        transport.delegate = self
        // Wire the byte path before connect() so any output from a fast
        // session start lands in the session's existing callbacks.
        transport.outputSink.update(onOutput: onOutput, onOutputData: onOutputData)
        self.goTransport = transport
        self.sessionDebugLabel = transport.debugLabel

        do {
            try await transport.connect()
            try Task.checkCancellation()
            pendingRelay = nil // gate now owns the target → relay lifetime
        } catch {
            transport.abandon()
            pendingRelay?.abandon()
            pendingRelay = nil
            throw error
        }

        // Transport connected - safe to close SSH
        Self.logger.info("Go \(modeStr) connected, closing SSH session")
        await closeSpawnSSHClients()

        // Set up agent forwarding if enabled
        let agentEnabled = config.sshConfig.agentConfig.enabled
        if agentEnabled {
            let manager = SSHAgentManager(
                config: config.sshConfig.agentConfig,
                remoteHost: config.sshConfig.host,
                sessionName: config.displayName
            )
            self.agentManager = manager

            // Forward approval requests to UI
            Task { @MainActor [weak self] in
                for await request in manager.approvalRequestPublisher.values {
                    self?.onAgentApprovalRequest?(request)
                }
            }

            let bridge = TrzszAgentBridge(agentManager: manager)
            self.agentBridge = bridge
            try await transport.enableAgentForwardingAsync(callback: bridge)
            Self.logger.info("Agent forwarding enabled for trzsz session")
        }

        // GPG agent forwarding (Unix-socket forward via TSSHD's generic
        // Listen() API — see TrzszStreamLocalBridge for the full
        // explanation). Independent of SSH agent forwarding; both can
        // be enabled simultaneously. A GPG-forwarding failure must
        // never prevent the terminal from opening — every early-exit
        // path below falls through to the shell/exec setup that
        // follows this block.
        if config.sshConfig.gpgAgentConfig.enabled {
            if let transportRef = transport.activeTransportRef {
                let gpgManager = GPGAgentManager(
                    config: config.sshConfig.gpgAgentConfig,
                    remoteHost: config.sshConfig.host,
                    sessionName: config.displayName,
                    onWithdrawal: { [weak self] requestID in
                        Task { @MainActor [weak self] in
                            self?.onGPGAgentApprovalWithdrawn?(requestID)
                        }
                    }
                )
                self.gpgAgentManager = gpgManager

                // Single-publisher pump for incoming requests.
                // Withdrawals ride the GPGAgentManager.onWithdrawal
                // closure passed at init — synchronous, survives pump
                // cancellation.
                gpgApprovalTask = Task { @MainActor [weak self] in
                    for await request in gpgManager.approvalRequestPublisher.values {
                        self?.onGPGAgentApprovalRequest?(request)
                    }
                }

                // Probe the remote for UID/HOME so `{UID}` and
                // `{HOME}` in the configured path resolve to the
                // actual remote values, not a hardcoded guess. The
                // probe goes over a fresh TSSHD session — cheap, and
                // happens once per session. Probe failure is non-
                // fatal: terminal startup continues without GPG
                // forwarding (the user can re-enable it via the
                // connection editor after fixing the cause).
                let configuredPath = config.sshConfig.gpgAgentConfig.remoteSocketPath
                let resolvedPathOpt: String?
                do {
                    let resolution = try await GPGRemotePathResolver.resolve(
                        path: configuredPath,
                        usingTrzsz: transport
                    )
                    resolvedPathOpt = resolution.path
                    if resolution.substituted {
                        Self.logger.info("GPG forward path probed: '\(configuredPath)' → '\(resolution.path)' (remote UID \(resolution.remoteUID ?? "?"))")
                    }
                } catch {
                    let host = self.config.sshConfig.host
                    Self.logger.warning("GPG forward path probe failed for \(host): \(error.localizedDescription). Continuing without GPG forwarding.")
                    self.gpgAgentManager = nil
                    resolvedPathOpt = nil
                }

                // Only proceed with the forward request if the probe
                // succeeded. `if let` here (rather than `guard ...
                // return`) so a probe failure leaves the outer
                // session-bringup flow intact — `start()` continues
                // to the shell/exec setup that follows this block.
                if let resolvedPath = resolvedPathOpt {
                let gpgBridge = TrzszStreamLocalBridge(
                    gpgAgentManager: gpgManager,
                    transportRef: transportRef
                )
                self.gpgStreamLocalBridge = gpgBridge
                self.gpgRemoteSocketPath = resolvedPath

                do {
                    try await transport.enableStreamLocalForwardingAsync(
                        remotePath: resolvedPath,
                        callback: gpgBridge
                    )
                    Self.logger.info("GPG agent forwarding enabled for trzsz session at \(resolvedPath)")
                } catch {
                    // Typical failure modes — same diagnostic shape
                    // as the Citadel path so users see one consistent
                    // message regardless of transport:
                    //   * `bind: no such file or directory` — the
                    //     directory containing the socket path
                    //     doesn't exist on the remote. macOS users
                    //     should use ~/.gnupg/S.gpg-agent.extra;
                    //     Linux users on a non-1000 UID should swap
                    //     the literal 1000 for their UID.
                    //   * `AllowStreamLocalForwarding` set to `no`/
                    //     `local` in sshd_config rejects the request
                    //     before bind is even attempted.
                    let detail = error.localizedDescription
                    let path = resolvedPath
                    Self.logger.warning("""
                    GPG agent forwarding failed to enable for \(path): \(detail)
                    Common causes: (1) `\(path)` parent directory doesn't exist on the \
                    remote — run `mkdir -p $(dirname '\(path)')` once; (2) sshd has \
                    `AllowStreamLocalForwarding no` (or `local`) in sshd_config.
                    """)
                    self.gpgAgentManager = nil
                    self.gpgStreamLocalBridge = nil
                    self.gpgRemoteSocketPath = nil
                }
                }  // end if-let resolvedPath
            } else {
                Self.logger.warning("GPG agent forwarding requested but no transport ref available; continuing without it")
            }
        }

        // When connectOnly, the caller will handle session setup (e.g. Attach)
        guard !connectOnly else { return }

        // Open session with PTY
        Self.logger.info("Opening Go transport session stream")
        let initialSize = pendingResize ?? pty.windowSize
        let cols = Int(initialSize.cols > 0 ? initialSize.cols : 80)
        let rows = Int(initialSize.rows > 0 ? initialSize.rows : 24)

        try await transport.openSessionStream(cols: cols, rows: rows, execCommand: execCommand, agentEnabled: agentEnabled)
        lastSentResize = initialSize
        pendingResize = nil

        // When using exec (e.g. tmux), the process may read the PTY size before
        // dimensions fully propagate. Send a WindowChange after a brief delay to
        // trigger SIGWINCH, forcing the process to re-read the correct size.
        if execCommand != nil {
            let resizeCols = cols
            let resizeRows = rows
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(10))
                self?.goTransport?.resize(cols: resizeCols, rows: resizeRows)
            }
        }

        isRunning = true
        connectionStartTime = Date()
        markHeartbeatPositive()
        state = .running(latencyMs: nil)

        // Save credentials for future resume
        if let terminalId = terminalId {
            Self.logger.info("Saving credentials for terminal \(terminalId.uuidString)")
            saveCredentials(serverInfo: serverInfo, host: host, terminalId: terminalId)
        } else {
            Self.logger.warning("Cannot save credentials: terminalId is nil")
        }

        Self.logger.info("trzsz session started via Go \(modeStr)")
        startPeriodicStateUpdates()
        onReady?()

        await startConfiguredPortForwards(on: transport)
    }

    /// Run after either opening a new PTY or attaching an existing one.
    private func startConfiguredPortForwards(on transport: TrzszGoTransport) async {
        guard !Task.isCancelled, !userInitiatedDisconnect, !didEndSession,
              goTransport === transport else { return }
        if config.sshConfig.portForwardConfig.hasActiveForwards,
           let pfManager = transport.makePortForwardManager(
               config: config.sshConfig.portForwardConfig,
               recoveringRemoteForwards: recoveringRemoteForwards
           ) {
            pfManager.onForwardError = { forward, error in
                Self.logger.error("Port forward \(forward.displayString) failed: \(error.localizedDescription)")
            }
            pfManager.onForwardStatusChange = { [weak self, weak pfManager] forward, status in
                guard let self, let pfManager, self.trzszPortForwardManager === pfManager else { return }
                if status == .active { self.recoveringRemoteForwards.remove(forward.id) }
            }
            self.trzszPortForwardManager = pfManager
            await pfManager.startAllForwards()
            if Task.isCancelled || userInitiatedDisconnect || didEndSession || goTransport !== transport {
                pfManager.stopAllForwards()
                if trzszPortForwardManager === pfManager { trzszPortForwardManager = nil }
            }
        }
    }

    // MARK: - Credential Persistence

    /// Saves session credentials to Keychain
    private func saveCredentials(serverInfo: TrzszServerInfo, host: String, terminalId: UUID) {
        var credentials = TrzszSessionCredentials(
            serverInfo: serverInfo,
            host: host,
            terminalId: terminalId,
            displayName: config.displayName,
            bootstrapKeyExchange: bootstrapKeyExchange,
            bootstrapHostKey: bootstrapHostKey,
            bootstrapCipher: bootstrapCipher,
            bootstrapMac: bootstrapMac
        )
        // Save the session ID for future Attach() after app restart
        credentials.sessionID = goTransport?.sessionID
        credentials.relay = relayCredentials
        credentials.transportMTU = effectiveTransportMTU ?? config.mtu
        self.savedCredentials = credentials

        ResumeDebugLogger.shared.log("[\(debugPrefix)] saveCredentials: uuid=\(terminalId.uuidString.prefix(8)), host=\(host), port=\(serverInfo.port)")
        do {
            try KeychainManager.shared.saveTrzszSessionCredentials(credentials, terminalId: terminalId)
            ResumeDebugLogger.shared.log("[\(debugPrefix)] saveCredentials SUCCESS")
            Self.logger.info("Saved trzsz credentials for terminal \(terminalId.uuidString)")
        } catch {
            ResumeDebugLogger.shared.log("[\(debugPrefix)] saveCredentials FAILED: \(error.localizedDescription)")
            Self.logger.warning("Failed to save trzsz credentials: \(error.localizedDescription)")
        }
    }

    /// Deletes session credentials from Keychain
    private func deleteCredentials() {
        guard let terminalId = terminalId else { return }

        do {
            try KeychainManager.shared.deleteTrzszSessionCredentials(terminalId: terminalId)
            Self.logger.info("Deleted trzsz credentials for terminal \(terminalId.uuidString)")
        } catch {
            Self.logger.warning("Failed to delete trzsz credentials: \(error.localizedDescription)")
        }
    }

    /// Starts periodic state updates
    private func startPeriodicStateUpdates() {
        guard terminalId != nil else { return }

        setupNetworkChangeObserver()

        // Cancel existing tasks
        stateUpdateTask?.cancel()
        healthMonitorTask?.cancel()

        // Credential state updates (less frequent). This intentionally does
        // not use idle time as proof of failure: health polling is async and
        // may be delayed or absent if Go is stalled, so lack of a fresh sample
        // is not a reliable disconnect signal for an idle but usable session.
        stateUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.stateUpdateInterval * 1_000_000_000))
                guard let strongSelf = self, strongSelf.isRunning else { break }
                guard let transport = strongSelf.goTransport,
                      transport.state.isConnected,
                      let lastPositive = strongSelf.lastPositiveHeartbeatAt,
                      Date().timeIntervalSince(lastPositive) < 60 else {
                    continue
                }
                strongSelf.lastConnectedAt = lastPositive
            }
        }

        // Reconciliation only: timeout/recovery edges are pushed from Go's
        // heartbeat checker, so this loop no longer needs to tick every
        // second — it just periodically re-syncs the cached activity stamp
        // in case a push was missed (Go wedged, or a transition landed
        // while backgrounded).
        healthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.healthReconcileInterval * 1_000_000_000))
                guard let strongSelf = self, strongSelf.isRunning else { break }
                guard !Ghostty.isAppBackgroundedAtomic else { continue }
                strongSelf.requestHealthRefresh()
                strongSelf.updateHeartbeatTimeoutBanner()
            }
        }
    }

    /// Stops all periodic update tasks
    private func stopPeriodicStateUpdates() {
        stateUpdateTask?.cancel()
        stateUpdateTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        bannerRefreshTask?.cancel()
        bannerRefreshTask = nil
        foregroundStateHoldTask?.cancel()
        foregroundStateHoldTask = nil
        foregroundStateHoldUntil = nil
        pendingRoamBannerStateDuringHold = nil
        currentHeartbeatProbeStartedAt = nil
        publishRoamBannerState(nil)
    }

    private var isForegroundStateHeld: Bool {
        guard let until = foregroundStateHoldUntil else { return false }
        return Date() < until
    }

    private func publishRoamBannerState(_ state: TrzszRoamBannerState?) {
        guard !Ghostty.isAppBackgroundedAtomic, !isForegroundStateHeld else {
            pendingRoamBannerStateDuringHold = .some(state)
            return
        }
        // BISECT GATE 1: suppress roam-banner publishes during the post-
        // foreground quiet window. Toggle via BisectFlags.gate1_publishRoamBannerState.
        // If the SwiftUI wedge stops reproducing when this is in place, the
        // @Published roamBannerState fan-out (Combine sink in
        // TerminalScrollView → MoshRoamBannerHostView) is the cause. Buffer
        // the state so the existing pendingRoamBannerStateDuringHold /
        // foregroundStateHold flush path can replay it after the window
        // closes.
        if BisectFlags.gate1_publishRoamBannerState && Ghostty.isInResumeQuietWindowAtomic {
            pendingRoamBannerStateDuringHold = .some(state)
            LifecycleDebugLogger.shared.bumpSuppression("gate1_roamBanner")
            return
        }
        // Skip republishing an unchanged value — the healthy path used to
        // write nil over nil once a second, firing objectWillChange into the
        // TerminalScrollView Combine sink each time for no visible change.
        if roamBannerState != state {
            roamBannerState = state
        }
        syncBannerRefreshTicker()
    }

    /// Keeps a 1 Hz counter-refresh task alive exactly while a roam banner is
    /// visible. The ticker re-renders "seconds since contact" locally from the
    /// wall clock — no Go calls, and zero work while the session is healthy.
    /// Health transitions themselves are pushed from Go.
    private func syncBannerRefreshTicker() {
        guard roamBannerState != nil else {
            bannerRefreshTask?.cancel()
            bannerRefreshTask = nil
            return
        }
        guard bannerRefreshTask == nil else { return }
        bannerRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning, !Task.isCancelled else { return }
                guard !Ghostty.isAppBackgroundedAtomic,
                      let banner = self.roamBannerState else { continue }
                let lastContact = self.lastPositiveHeartbeatAt
                    ?? self.lastConnectedAt
                    ?? self.connectionStartTime
                    ?? Date()
                let seconds = max(1, Int(Date().timeIntervalSince(lastContact)))
                if banner.reconnecting {
                    self.publishRoamBannerState(
                        .reconnecting(attempt: banner.reconnectAttempt, secondsSinceContact: seconds))
                } else if banner.secondsSinceContact > 0 {
                    self.publishRoamBannerState(.timeout(secondsSinceContact: seconds))
                }
            }
        }
    }

    private func startForegroundStateHold() {
        foregroundStateHoldTask?.cancel()
        foregroundStateHoldUntil = Date().addingTimeInterval(Self.foregroundStateHoldDuration)

        foregroundStateHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.foregroundStateHoldDuration))
            guard let self,
                  !Task.isCancelled,
                  self.isRunning,
                  !Ghostty.isAppBackgroundedAtomic else { return }
            self.foregroundStateHoldUntil = nil
            self.isResumingFromForeground = false
            if let pending = self.pendingRoamBannerStateDuringHold {
                self.pendingRoamBannerStateDuringHold = nil
                if self.roamBannerState != pending {
                    self.roamBannerState = pending
                }
                self.syncBannerRefreshTicker()
            }
            self.goTransport?.flushBackgroundedCallbacks()
            self.requestHealthRefresh()
            self.updateHeartbeatTimeoutBanner()
            self.startPeriodicStateUpdates()
        }
    }

    private func markHeartbeatPositive() {
        let now = Date()
        lastPositiveHeartbeatAt = now
        lastConnectedAt = now
        currentHeartbeatProbeStartedAt = nil
    }

    private func requestHealthRefresh() {
        guard goTransport != nil, !Ghostty.isAppBackgroundedAtomic else { return }
        if goTransport?.requestActivityRefresh() == true || currentHeartbeatProbeStartedAt == nil {
            currentHeartbeatProbeStartedAt = Date()
        }
    }

    private func updateHeartbeatTimeoutBanner() {
        guard isRunning,
              !Ghostty.isAppBackgroundedAtomic,
              !isResumingFromForeground,
              currentHeartbeatProbeStartedAt != nil else {
            return
        }

        let now = Date()
        guard let started = currentHeartbeatProbeStartedAt,
              now.timeIntervalSince(started) >= Self.heartbeatResponseTimeout else {
            return
        }

        let lastContact = lastPositiveHeartbeatAt ?? lastConnectedAt ?? connectionStartTime ?? started
        let seconds = max(1, Int(now.timeIntervalSince(lastContact)))
        if lastNetworkLossAt == nil {
            lastNetworkLossAt = started
            didSignalDisconnect = false
        }
        publishRoamBannerState(.timeout(secondsSinceContact: seconds))
    }

    // MARK: - Network Change Handling

    private func setupNetworkChangeObserver() {
        removeNetworkChangeObserver()

        NetworkReachabilityMonitor.shared.connectivityLost
            .sink { [weak self] in
                guard let self = self, self.isRunning else { return }
                guard !Ghostty.isAppBackgroundedAtomic, !self.isResumingFromForeground else { return }
                Self.logger.info("Network connectivity lost for Trzsz session")
                self.lastNetworkLossAt = Date()
                self.didSignalDisconnect = false
                if self.state.isConnected, !Ghostty.isAppBackgroundedAtomic, !self.isForegroundStateHeld {
                    self.state = .roaming(previousNetwork: "network lost")
                }
            }
            .store(in: &networkChangeCancellables)

        NetworkReachabilityMonitor.shared.connectivityRestored
            .sink { [weak self] in
                guard let self = self, self.isRunning else { return }
                guard !Ghostty.isAppBackgroundedAtomic, !self.isResumingFromForeground else { return }
                Self.logger.info("Network connectivity restored for Trzsz session")
                self.lastNetworkLossAt = nil
                self.didSignalDisconnect = false
                self.publishRoamBannerState(nil)
                self.requestHealthRefresh()
                // Let transport handle reconnection; no forced reconnect on idle.
            }
            .store(in: &networkChangeCancellables)

        NetworkReachabilityMonitor.shared.connectionTypeChanged
            .sink { [weak self] newType in
                guard let self = self, self.isRunning else { return }
                guard !Ghostty.isAppBackgroundedAtomic, !self.isResumingFromForeground else { return }
                Self.logger.info("Network type changed for Trzsz session: \(newType.description)")
                self.lastNetworkLossAt = Date()
                self.didSignalDisconnect = false
                if self.state.isConnected, !Ghostty.isAppBackgroundedAtomic, !self.isForegroundStateHeld {
                    self.state = .roaming(previousNetwork: "network change")
                }
                // Let transport handle reconnection; no forced reconnect on idle.
            }
            .store(in: &networkChangeCancellables)
    }

    private func removeNetworkChangeObserver() {
        networkChangeCancellables.forEach { $0.cancel() }
        networkChangeCancellables.removeAll()
    }

    // No forced recovery on connectivity events; transport handles reconnection internally.

    private func handleTransportDisconnect(reason: ReconnectionManager.DisconnectReason, error: Error) {
        guard !didSignalDisconnect, !userInitiatedDisconnect else { return }
        didSignalDisconnect = true
        suppressSessionEnd = onDisconnect != nil

        state = .disconnected
        // The banner is purely SwiftUI overlay state; skip the @Published
        // write while the resume gate is up so we don't pile on scene updates.
        // The periodic tick (after the gate drops) will recompute banner state
        // from the current transport health.
        if !Ghostty.isAppBackgroundedAtomic {
            publishRoamBannerState(.connectionLost(reason: reason.description))
        }

        if let onDisconnect = onDisconnect {
            onDisconnect(reason)
        } else {
            onError?(error)
        }
    }

    // MARK: - Input/Output

    /// Sends input data to the session
    func sendInput(_ data: Data) {
        guard isRunning else {
            Self.logger.warning("sendInput ignored: isRunning=false")
            return
        }

        // Apply OpenSSH-style escape-character filtering (~. ~? ~# ~I ~~).
        // Unknown and unsupported escapes fall through as literal bytes. Bracketed
        // paste content bypasses escape detection so pasted `~.` never disconnects.
        let filtered = escapeFilter.filter(data)
        guard !filtered.isEmpty else { return }

        guard goTransport != nil else {
            Self.logger.warning("sendInput ignored: goTransport is nil")
            return
        }

        transportSend(filtered)
    }

    /// Sets the terminal size
    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size

        guard isRunning, goTransport != nil else {
            pendingResize = size
            return
        }

        if let last = lastSentResize,
           last.rows == size.rows,
           last.cols == size.cols {
            return
        }

        sendResize(width: size.cols, height: size.rows)
        lastSentResize = size
    }

    /// Sends a resize command to the server
    private func sendResize(width: UInt16, height: UInt16) {
        // Use native resize for Go transport
        if let go = goTransport {
            go.resize(cols: Int(width), rows: Int(height))
            return
        }

        // tsshd uses a control message format for resize (Swift fallback)
        // Format: [0x02][width:2][height:2]
        var data = Data()
        data.append(0x02)  // Resize command
        data.append(UInt8(width >> 8))
        data.append(UInt8(width & 0xFF))
        data.append(UInt8(height >> 8))
        data.append(UInt8(height & 0xFF))

        transportSend(data)
    }

    // MARK: - Session Control

    /// Stops the trzsz session
    func stop() {
        Self.logger.info("Stopping trzsz session")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] stop() called — will delete credentials")

        userInitiatedDisconnect = true
        suppressSessionEnd = false
        state = .disconnected
        authBanners = []
        endSession(shouldDeleteCredentials: true, shouldCloseTransport: true, emitSessionEnd: true)
    }

    /// Terminates the session for user-initiated tab close.
    /// Sends "close" to server and deletes credentials.
    /// Does NOT emit onSessionEnd (caller handles tab removal).
    func terminate() {
        Self.logger.info("Terminating trzsz session (user-initiated close)")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] terminate() called — will delete credentials and close transport")

        userInitiatedDisconnect = true
        suppressSessionEnd = true
        state = .disconnected
        endSession(shouldDeleteCredentials: true, shouldCloseTransport: true, emitSessionEnd: false)
    }

    /// Stops the session without deleting credentials or emitting onSessionEnd.
    /// Used by scene teardown when preserving the remote session for later resume.
    func stopForReconnect() {
        Self.logger.info("Stopping trzsz session while preserving credentials")

        userInitiatedDisconnect = false
        suppressSessionEnd = true
        state = .disconnected
        endSession(shouldDeleteCredentials: false, shouldCloseTransport: false, emitSessionEnd: false)
    }

    /// Detaches the session because the user transferred it to another device
    /// via Continuity Handoff. The peer has already called Attach() and ack'd,
    /// so we must release local state without telling tsshd to close — the
    /// server-side PTY has to keep running for the peer.
    ///
    /// - Abandons the UDP transport silently (no "close" frame to tsshd).
    /// - Deletes our keychain credentials so a future launch on this device
    ///   doesn't race the peer for the same sessionID.
    /// - Suppresses onSessionEnd; the transfer coordinator drives leaf removal
    ///   directly so we don't recursively re-enter closeTab.
    func detachForTransfer() {
        Self.logger.info("Detaching trzsz session for nearby-device transfer")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] detachForTransfer() — peer attached, releasing local state")

        userInitiatedDisconnect = true
        suppressSessionEnd = true
        state = .disconnected
        endSession(shouldDeleteCredentials: true, shouldCloseTransport: false, emitSessionEnd: false)
    }

    /// Cancels a receiver-side transfer attach before it becomes the owner
    /// of the server-side session. This must not send a close frame to
    /// tsshd, because the originator may still be running the session.
    func cancelTransferAttach() {
        Self.logger.info("Cancelling trzsz transfer attach")
        ResumeDebugLogger.shared.log("[\(debugPrefix)] cancelTransferAttach() - abandoning receiver attach")

        userInitiatedDisconnect = true
        suppressSessionEnd = true
        state = .disconnected
        endSession(shouldDeleteCredentials: true, shouldCloseTransport: false, emitSessionEnd: false)
    }

    /// Common session teardown.
    ///
    /// `shouldCloseTransport` controls whether we send tsshd a "close" channel
    /// message (true → server tears the PTY down; false → server keeps it
    /// alive subject to AliveTimeout, which is what resume and transfer-out
    /// both rely on). It used to be tied to `shouldDeleteCredentials`, but
    /// transfer-out needs the (delete creds, abandon transport) combination.
    private func endSession(
        shouldDeleteCredentials: Bool,
        shouldCloseTransport: Bool,
        emitSessionEnd: Bool
    ) {
        guard !didEndSession else { return }
        didEndSession = true
        relayRecoveryTask?.cancel()
        relayRecoveryTask = nil

        stopPeriodicStateUpdates()
        removeNetworkChangeObserver()

        trzszPortForwardManager?.stopAllForwards()
        trzszPortForwardManager = nil

        agentManager = nil
        agentBridge = nil

        // Tear down GPG stream-local forward before the transport
        // closes. If the transport is already gone, the Go-side
        // forwarder gets cleaned up by closeAllStreamLocal in
        // Transport.Close — this just disables it cleanly when the
        // transport is still alive.
        if let path = gpgRemoteSocketPath, let transport = goTransport {
            let pathCopy = path
            Task { await transport.disableStreamLocalForwardingAsync(remotePath: pathCopy) }
        }
        // Drain pending approvals FIRST so onWithdrawal fires for
        // each in-flight request before we stop the pump. Withdrawals
        // are delivered via the synchronous callback path now, so
        // ordering is documentation-only — but match the Citadel
        // teardown shape so future changes can't reintroduce the
        // dropped-withdrawal bug if either side switches back to a
        // pump-only flow.
        gpgAgentManager?.cancelPendingApprovals()
        gpgApprovalTask?.cancel()
        gpgApprovalTask = nil
        gpgAgentManager = nil
        gpgStreamLocalBridge = nil
        gpgRemoteSocketPath = nil

        if shouldCloseTransport {
            disconnectTransport()
        } else {
            abandonTransport()
        }
        isRunning = false

        if shouldDeleteCredentials {
            deleteCredentials()
        }

        if emitSessionEnd && !suppressSessionEnd {
            onSessionEnd?()
        }
    }

    /// Notifies the session that its tab visibility changed
    func setTabVisible(_ visible: Bool) {
        // Could throttle updates when not visible
    }

    /// Cancel periodic tasks on background. Cancel the agent bridge in-flight
    /// Tasks too — a goroutine parked on a denied agent request is the most
    /// reliable way to wedge the Go runtime, and a wedged Go runtime must not
    /// be touched by Swift foreground-resume work.
    func pauseForBackground() {
        Self.logger.info("Trzsz pauseForBackground: cancelling periodic tasks")
        stateUpdateTask?.cancel()
        stateUpdateTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        foregroundStateHoldTask?.cancel()
        foregroundStateHoldTask = nil
        foregroundStateHoldUntil = nil
        pendingRoamBannerStateDuringHold = nil
        isResumingFromForeground = false
        currentHeartbeatProbeStartedAt = nil
        agentBridge?.cancelInFlightTasks()
    }

    /// Re-arm periodic tasks on foreground.
    func resumeForForeground() {
        guard isRunning else { return }
        Self.logger.info("Trzsz resumeForForeground: deferring tssh foreground work")
        isResumingFromForeground = true
        startForegroundStateHold()
    }

    /// Drain this session's buffered Go-thread output to the terminal NOW
    /// (controlled, called from main while the global background atomic is
    /// still true). Used by MainViewLifecycle's chunked resume to spread the
    /// per-session flushes across runloop ticks before opening the gate, so
    /// 10 sessions don't all fire `outputSink.emit` simultaneously when the
    /// atomic flips. Safe to call multiple times — drain returns nil when
    /// the buffer is empty.
    @discardableResult
    func flushBackgroundedOutputEarly() -> Bool {
        // Deliver a backgrounded output discard (server-side tsshd discard or
        // local background-buffer overflow) BEFORE the first drained chunk. The
        // core's read thread consumes the reset ahead of any bytes written
        // after the reset call returns (id=termio-tmux-reset-barrier), so the
        // gapped bytes are dropped as resync pre-marker noise, never parsed.
        goTransport?.deliverPendingDiscardIfAny()
        return goTransport?.flushBackgroundedOutputForForegroundReplay() ?? false
    }

    func flushBackgroundedOutputFully() {
        // Catches discards accumulated between this session's early-drain tick
        // and the foreground gate flip. Take-and-clear makes repeats free.
        goTransport?.deliverPendingDiscardIfAny()
        goTransport?.flushBackgroundedOutput()
    }
}

// MARK: - TrzszGoTransport.Delegate

extension TrzszSession: TrzszGoTransportDelegate {
    func transport(_ transport: TrzszGoTransport, didChangeHealthTimeout isTimeout: Bool) {
        guard let currentTransport = goTransport,
              transport === currentTransport,
              isRunning,
              !isResumingFromForeground,
              !Ghostty.isAppBackgroundedAtomic else {
            return
        }

        if isTimeout {
            currentHeartbeatProbeStartedAt = nil
            if lastNetworkLossAt == nil {
                lastNetworkLossAt = Date()
                didSignalDisconnect = false
            }
            let seconds = max(1, transport.activitySnapshot?.secondsSinceActivity ?? 3)
            publishRoamBannerState(.timeout(secondsSinceContact: seconds))
        } else {
            if lastNetworkLossAt != nil || roamBannerState != nil {
                Self.logger.info("tssh heartbeat recovered, clearing roam banner")
            }
            markHeartbeatPositive()
            lastNetworkLossAt = nil
            didSignalDisconnect = false
            publishRoamBannerState(nil)
        }
    }

    func transportDidRefreshHealth(_ transport: TrzszGoTransport) {
        guard let currentTransport = goTransport,
              transport === currentTransport,
              isRunning,
              !isResumingFromForeground,
              !Ghostty.isAppBackgroundedAtomic,
              let snapshot = transport.activitySnapshot else {
            return
        }

        if snapshot.isTimeout && snapshot.secondsSinceActivity > 3 {
            currentHeartbeatProbeStartedAt = nil
            if lastNetworkLossAt == nil {
                lastNetworkLossAt = Date()
                didSignalDisconnect = false
            }
            publishRoamBannerState(.timeout(secondsSinceContact: snapshot.secondsSinceActivity))
        } else {
            if lastNetworkLossAt != nil || roamBannerState != nil {
                Self.logger.info("tssh health refreshed, clearing roam banner")
            }
            markHeartbeatPositive()
            lastNetworkLossAt = nil
            didSignalDisconnect = false
            publishRoamBannerState(nil)
        }
    }

    func transport(_ transport: TrzszGoTransport, didChangeState transportState: TrzszGoTransport.State) {
        guard !Ghostty.isAppBackgroundedAtomic, !isResumingFromForeground else { return }

        switch transportState {
        case .connected:
            if !isRunning {
                // Initial connection
                markHeartbeatPositive()
                state = .running(latencyMs: nil)
            } else if let terminalId {
                // A roam reconnect recovered. No resize goes out, but tsshd
                // replays what it buffered while we were away — bells in
                // that backlog are stale, and so is any agent state read
                // off the replay.
                TerminalBellSuppressor.suppress(
                    terminalId, for: TerminalBellSuppressor.forcedRedraw)
                TerminalBellSuppressor.suppressRebuild(terminalId)
            }

        case .disconnected:
            // Don't end session on disconnect - Go transport handles reconnection internally
            // The banner will show timeout status via health monitoring
            if isRunning && !userInitiatedDisconnect {
                Self.logger.info("Transport disconnected, waiting for reconnection...")
                // Don't change state or end session - let Go transport reconnect
            }

        case .failed(let reason):
            // Go has given up. Surface the terminal error instead of replacing
            // the transport from Swift.
            if isRunning && !userInitiatedDisconnect {
                Self.logger.error("Transport failed: \(reason)")
                handleTransportDisconnect(reason: .error(reason), error: TrzszError.transportDisconnected(reason: reason))
            }

        case .connecting:
            break

        case .reconnecting:
            // Go transport is reconnecting - update banner
            Self.logger.info("Transport reconnecting...")
            if lastNetworkLossAt == nil {
                lastNetworkLossAt = Date()
                didSignalDisconnect = false
            }
            if !Ghostty.isAppBackgroundedAtomic {
                let seconds = goTransport?.secondsSinceLastActivity ?? 0
                publishRoamBannerState(.reconnecting(attempt: 1, secondsSinceContact: seconds))
            }
        }
    }

    /// Coalesced "data has arrived" notification. Bytes are delivered off-main
    /// via `transport.outputSink` (see `GoOutputCallbackBridge.onOutput`); this
    /// hook fires at most once per main-actor turn no matter how many chunks
    /// landed, so the per-chunk cost stays out of the resume hot path.
    func transportDidReceiveData(_ transport: TrzszGoTransport) {
        guard !Ghostty.isAppBackgroundedAtomic, !isResumingFromForeground else { return }

        // Real output is the only Swift-side proof that the session is alive.
        // Clear any stale loss/reconnect/last-contact banner immediately.
        markHeartbeatPositive()
        if lastNetworkLossAt != nil || roamBannerState != nil {
            lastNetworkLossAt = nil
            didSignalDisconnect = false
            publishRoamBannerState(nil)
        }
    }

    func transport(_ transport: TrzszGoTransport, didEncounterError error: Error) {
        guard !Ghostty.isAppBackgroundedAtomic, !isResumingFromForeground else { return }

        Self.logger.error("Go transport error (output loop likely stopped): \(error.localizedDescription)")
        // When we get a transport error, it typically means the Go output forwarding
        // loop has exited. Even if UDP reconnects, we won't receive output anymore.
        // Treat as disconnect so reconnection manager can recover
        handleTransportDisconnect(reason: .error(error.localizedDescription), error: error)
    }

    func transport(_ transport: TrzszGoTransport, didExitWithCode exitCode: Int) {
        guard !Ghostty.isAppBackgroundedAtomic, !isResumingFromForeground else { return }

        // OnExit fires only when the server successfully sends the exit code over a
        // live connection (io.EOF on stdout stream). Connection loss fires OnError
        // (non-EOF read error), not OnExit. Safe to close transport and delete
        // credentials — the session is definitively over.
        ResumeDebugLogger.shared.log("[\(debugPrefix)] didExitWithCode(\(exitCode)): shell exited, closing transport")
        if exitCode == 0 {
            Self.logger.info("Session exited gracefully")
            state = .disconnected
        } else {
            Self.logger.warning("Session exited with code \(exitCode)")
            state = .failed
        }
        endSession(shouldDeleteCredentials: true, shouldCloseTransport: true, emitSessionEnd: true)
    }

    func transport(_ transport: TrzszGoTransport, didDiscardOutputLines lines: Int, bytes: Int) {
        // A lossy server-side OUTPUT discard: forward to whoever owns this session
        // (a tmux -CC gateway TerminalView), which triggers a full surface reset +
        // recapture. Pure signal — the controller owns debounce + recovery.
        onOutputDiscarded?(lines, bytes)
    }
}

// MARK: - Convenience Factory

extension TrzszSession {
    /// Creates a trzsz session from an SSH configuration
    static func create(
        sshConfig: SSHConfig,
        pty: TerminalPTY,
        terminalId: UUID? = nil
    ) -> TrzszSession {
        let trzszConfig = TrzszConfig(sshConfig: sshConfig, transportMode: .preferred)
        return TrzszSession(config: trzszConfig, pty: pty, terminalId: terminalId)
    }
}

// MARK: - Continuity Transfer

extension TrzszSession {
    static func transferAttachClientId(after clientId: UInt64) -> UInt64 {
        let nextClientId = clientId &+ 1
        return nextClientId == 0 ? 1 : nextClientId
    }

    /// Snapshots whatever credentials the live session currently has so the
    /// originator can ship them to a nearby device. Returns nil when the
    /// session hasn't yet received a sessionID from the server (Attach is
    /// impossible without one).
    func exportCredentialsForTransfer() -> TrzszSessionCredentials? {
        guard let creds = savedCredentials, creds.sessionID != nil else {
            return nil
        }
        return creds
    }

    /// Reserves a fresh client-id base for a transfer payload. The receiver
    /// will attach with `transferAttachClientId(after: reserved.clientId)`.
    /// Persisting this before advertising prevents a failed receiver attach
    /// from poisoning future transfers from this sender tab when no failure
    /// ack is delivered.
    func reserveCredentialsForTransferPayload() -> TrzszSessionCredentials? {
        guard let originalCredentials = savedCredentials,
              originalCredentials.sessionID != nil else {
            return nil
        }

        var credentials = originalCredentials
        credentials.clientId = Self.transferAttachClientId(after: credentials.clientId)
        do {
            try KeychainManager.shared.saveTrzszSessionCredentials(
                credentials,
                terminalId: credentials.terminalId
            )
            savedCredentials = credentials
            ResumeDebugLogger.shared.log("[\(debugPrefix)] reserved transfer payload clientId=\(credentials.clientId)")
            return credentials
        } catch {
            let errDesc = error.localizedDescription
            Self.logger.warning("Failed to persist reserved transfer clientId=\(credentials.clientId): \(errDesc)")
            ResumeDebugLogger.shared.log("[\(debugPrefix)] failed to persist reserved transfer clientId=\(credentials.clientId): \(errDesc)")
            savedCredentials = originalCredentials
            return nil
        }
    }

    /// A receiver can fail after the server has already observed its bumped
    /// client id. Keep this sender tab's exported credentials moving forward
    /// so a later transfer does not reuse the same serial and get rejected.
    func advanceTransferClientIdAfterFailedAttempt(_ attemptedClientId: UInt64) {
        guard var credentials = savedCredentials else { return }
        guard attemptedClientId > credentials.clientId else { return }

        credentials.clientId = attemptedClientId
        savedCredentials = credentials
        do {
            try KeychainManager.shared.saveTrzszSessionCredentials(
                credentials,
                terminalId: credentials.terminalId
            )
            ResumeDebugLogger.shared.log("[\(debugPrefix)] advanced transfer clientId after failed attach: \(attemptedClientId)")
        } catch {
            let errDesc = error.localizedDescription
            Self.logger.warning("Failed to persist advanced transfer clientId=\(attemptedClientId): \(errDesc)")
            ResumeDebugLogger.shared.log("[\(debugPrefix)] failed to persist advanced transfer clientId=\(attemptedClientId): \(errDesc)")
        }
    }

    /// The current sessionID, exposed so callers (menu predicates, UI)
    /// can decide whether transfer is even possible.
    var transferableSessionID: UInt64? {
        savedCredentials?.sessionID
    }

    /// Constructs a TrzszSession by attaching directly to a server-side PTY
    /// using credentials handed off from another device via Continuity. No
    /// SSH spawn happens — the previous device already did that work, and
    /// this device just rejoins the existing tsshd conversation.
    ///
    /// On success returns a fully running session ready to be wired into a
    /// TerminalView. On failure throws and the caller is responsible for
    /// surfacing the error and disposing of the half-built session.
    static func startFromTransfer(
        payload: TrzszTransferPayload,
        pty: TerminalPTY,
        terminalId: UUID
    ) async throws -> TrzszSession {
        guard payload.credentials.sessionID != nil else {
            throw TrzszTransferError.noSessionID
        }

        let trzszConfig = TrzszConfig(
            sshConfig: payload.sshConfig,
            transportMode: payload.transportMode
        )
        let session = TrzszSession(config: trzszConfig, pty: pty, terminalId: terminalId)
        try await session.attachFromTransferPayload(payload)
        return session
    }

    /// Wires up a Go transport using the transferred credentials and calls
    /// `attachToSession`. Mirrors the resume retry-loop body but runs
    /// exactly once — this is a user-driven "transfer accept" and any retry
    /// is the user's job (re-tap the Handoff tile).
    ///
    /// Used by `TrzszSession.startFromTransfer` and by setupPTYAndShell
    /// when a `.trzszTransfer` connection config attaches an existing
    /// session instance.
    func attachFromTransferPayload(_ payload: TrzszTransferPayload) async throws {
        guard !isRunning else {
            throw TrzszError.sessionAlreadyStarted
        }
        try Task.checkCancellation()

        var credentials = payload.credentials
        relayCredentials = credentials.relay
        effectiveTransportMTU = credentials.transportMTU ?? credentials.relay?.targetMTU
        guard let savedSessionID = credentials.sessionID else {
            throw TrzszTransferError.noSessionID
        }

        userInitiatedDisconnect = false
        didSignalDisconnect = false
        suppressSessionEnd = false
        didEndSession = false
        wasResumed = true  // skip the "starting…" launch command in onReady

        bootstrapKeyExchange = credentials.bootstrapKeyExchange
        bootstrapHostKey = credentials.bootstrapHostKey
        bootstrapCipher = credentials.bootstrapCipher
        bootstrapMac = credentials.bootstrapMac

        state = .resumingSession(host: credentials.host, port: credentials.udpPort)

        // Persist creds in our keychain immediately so a crash between attach
        // and the first heartbeat doesn't strand the session.
        if let terminalId = terminalId {
            try? KeychainManager.shared.saveTrzszSessionCredentials(
                credentials,
                terminalId: terminalId
            )
        }

        // Bump clientId for our own attach — the originator is about to
        // detach, but bumping is safe regardless and matches the
        // "every new connection takes a different ClientID" rule that
        // tsshd's bus auth enforces.
        let effectiveClientId = Self.transferAttachClientId(after: credentials.clientId)
        credentials.clientId = effectiveClientId

        var serverInfo = credentials.toServerInfo()
        serverInfo.clientId = effectiveClientId

        try Task.checkCancellation()
        guard !userInitiatedDisconnect else { throw CancellationError() }

        try await connectGoTransport(
            host: credentials.host,
            serverInfo: serverInfo,
            connectOnly: true
        )

        try Task.checkCancellation()
        guard !userInitiatedDisconnect else { throw CancellationError() }

        guard let transport = goTransport else {
            throw TrzszError.connectionFailed("No transport after connect")
        }

        let cols = Int(payload.cols > 0 ? payload.cols : 80)
        let rows = Int(payload.rows > 0 ? payload.rows : 24)
        // tsshd redraws the screen on every attach; that repaint is ours.
        if let terminalId {
            TerminalBellSuppressor.suppress(
                terminalId, for: TerminalBellSuppressor.forcedRedraw)
            TerminalBellSuppressor.suppressRebuild(terminalId)
        }
        try await transport.attachToSession(
            sessionID: savedSessionID,
            cols: cols,
            rows: rows
        )

        try Task.checkCancellation()
        guard !userInitiatedDisconnect, !didEndSession else { throw CancellationError() }

        isRunning = true
        connectionStartTime = payload.sessionStartedAt
        markHeartbeatPositive()
        state = .running(latencyMs: nil)

        credentials.sessionID = transport.sessionID ?? savedSessionID
        savedCredentials = credentials
        if let terminalId = terminalId {
            try? KeychainManager.shared.saveTrzszSessionCredentials(
                credentials,
                terminalId: terminalId
            )
        }

        await startConfiguredPortForwards(on: transport)
        try Task.checkCancellation()
        guard !userInitiatedDisconnect, !didEndSession else { throw CancellationError() }
        startPeriodicStateUpdates()
        onReady?()
    }
}

// MARK: - Auth banner card

extension TrzszSession: SSHAuthBannerCardProviding {}
