//
//  MoshSession.swift
//  rootshell
//
//  Mosh terminal session implementation
//

import Combine
import Foundation
import OSLog
import UIKit
import Citadel

/// Mosh terminal session
///
/// Implements the TerminalSession protocol for mosh connections.
/// Provides:
/// - SSH-based server spawn
/// - UDP transport with encryption
/// - State synchronization
/// - Network roaming support
@MainActor
final class MoshSession: TerminalSession {

    // MARK: - TerminalSession Protocol

    /// The PTY for terminal I/O
    let pty: TerminalPTY

    /// Whether the session is currently running
    private(set) var isRunning: Bool = false

    /// Prevent double-cleanup / duplicate onSessionEnd callbacks
    private var didEndSession: Bool = false

    /// Terminal output callback (called from background thread)
    var onOutput: (@Sendable (String) -> Void)?

    /// Raw output callback (preferred)
    var onOutputData: (@Sendable (Data) -> Void)?

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

    /// Mosh supports automatic reconnection
    var supportsAutoReconnect: Bool { true }

    // Connection metadata
    private(set) var connectionStartTime: Date?

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        let sshConfig = config.sshConfig
        return .mosh(SSHConnectionInfo(
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
            agentForwardingEnabled: false,
            extraJumpHops: (sshConfig.extraJumpHosts ?? []).map { "\($0.host):\($0.port)" }
        ))
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

    // MARK: - Mosh-Specific

    /// State change callback
    var onStateChange: ((MoshSessionState) -> Void)?

    /// Keyboard-interactive (RFC 4256) challenge callback for the SSH bootstrap
    /// that spawns mosh-server. Returns one response per prompt, or nil to cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    /// Host-key validation prompt for the SSH bootstrap and hole-punch
    /// connections. nil = strict (accept known/CA keys, reject new or changed).
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// The mosh configuration
    let config: MoshConfig

    /// Terminal UUID for credential persistence
    /// Used to store/retrieve session credentials in Keychain
    var terminalId: UUID?

    /// Current session state
    private(set) var state: MoshSessionState = .initial {
        didSet {
            // Clear the auth-banner card on user-initiated teardown
            // (stop/terminate set .disconnected) — but NOT on .failed:
            // Tailscale SSH sends its rejection reason as an auth banner
            // immediately before disconnecting, so on bootstrap-auth failure
            // the card is the only surface holding the explanation and must
            // outlive the failure. It outlives it on a countdown, not forever,
            // which is what a standalone (non-embedded) session relies on.
            switch state {
            case .disconnected:
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
    /// while mosh-server spawn authentication is pending.
    let authBannerCardModel = SSHAuthBannerCardModel()

    /// Current roam banner state for SwiftUI overlay
    /// nil when banner should not be visible
    @Published private(set) var roamBannerState: MoshRoamBannerState?

    /// Current latency in milliseconds
    var latencyMs: Int? {
        stateSync?.latencyMs
    }

    // MARK: - Private State

    /// Server spawner
    private var spawner: MoshServerSpawner?

    /// SSH connection kept alive after spawn for out-of-band scans and
    /// loopback forwards. Mosh itself has no exec or forwarding channel.
    private var controlConnection: MoshControlConnection?

    /// Mosh forwards through the retained SSH control connection.
    func adHocForwarding(create: Bool) -> AdHocForwarding? {
        controlConnection?.forwarding(create: create)
    }

    /// The SSH client a remote-port probe may use, when the control
    /// connection is still alive.
    var controlClient: SSHClient? {
        controlConnection?.client
    }

    /// Transport layer
    private var transport: MoshTransport?

    /// State sync coordinator
    private var stateSync: MoshStateSync?

    /// Resize requested before session became running
    private var pendingResize: TerminalPTY.TerminalSize?

    /// Last resize sent to server
    private var lastSentResize: TerminalPTY.TerminalSize?

    /// Last resize received from server (used for deterministic resume sync)
    private var lastServerResize: (cols: UInt16, rows: UInt16)?

    /// Resize ack waiter for resume jiggle (avoid fixed sleeps)
    private var pendingResizeWaiter: ResizeWaiter?

    /// Whether this session was resumed from saved credentials
    private(set) var wasResumed: Bool = false

    /// Whether we're currently in the process of auto-fallback after resume failure
    private var isAutoFallbackInProgress: Bool = false

    /// Session resumer for direct UDP reconnection
    private let resumer = MoshSessionResumer()

    /// Timeout for waiting on server resize during resume jiggle
    private static let resumeResizeAckTimeout: TimeInterval = 1.5

    /// Helper to safely manage resize wait continuations
    private final class ResizeWaiter {
        let cols: UInt16
        let rows: UInt16
        var continuation: CheckedContinuation<Bool, Never>?
        var timeoutTask: Task<Void, Never>?
        private var resumed = false

        init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }

        func resume(_ result: Bool) {
            guard !resumed else { return }
            resumed = true
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// UDP hole-puncher for firewall traversal
    private var holePuncher: UDPHolePuncher?

    /// Current spawn result for reactive hole-punch reconnection
    /// Stored so we can reconnect with hole-punch using the same session key
    private var currentSpawnResult: MoshServerSpawner.SpawnResult?

    /// STUN discovery result - stored for reactive server punch
    /// Contains public IP:port that server should punch to
    private var stunResult: UDPHolePuncher.HolePunchResult?

    /// Whether a hole-punch operation is currently in progress
    /// Prevents concurrent punch attempts (includes STUN refresh punch)
    private var serverPunchInProgress = false

    /// Whether a fresh STUN refresh is currently in progress
    private var stunRefreshInProgress = false

    /// Whether a STUN refresh was requested while a punch was in-flight
    private var pendingStunRefresh = false

    /// Task for a delayed STUN refresh retry (coalesced)
    private var stunRefreshRetryTask: Task<Void, Never>?

    /// Whether we need to receive data before allowing another server punch
    /// After a punch attempt, we set this true. Once we receive server data,
    /// we reset it to allow future punch on new connectivity issues.
    /// This prevents infinite loop when punch doesn't help.
    private var awaitingDataBeforeNextPunch = false

    /// Timestamp when STUN result was last refreshed
    /// Used to detect stale STUN results that need re-discovery
    private var stunResultTimestamp: Date?

    /// Count of consecutive punch failures with current STUN result
    /// Used to escalate to fresh STUN discovery after repeated failures
    private var consecutivePunchFailures: Int = 0

    /// Maximum punch failures before triggering fresh STUN discovery
    private static let maxPunchFailuresBeforeReSTUN = 3

    /// Maximum age of STUN result before considering it stale (2 minutes)
    private static let stunResultMaxAge: TimeInterval = 120

    /// Task for ongoing hole-punch retry loop
    private var holePunchRetryTask: Task<Void, Never>?

    /// Base interval for hole-punch retry attempts (5 seconds)
    private static let holePunchRetryBaseInterval: TimeInterval = 5.0

    /// Maximum interval for hole-punch retry backoff (60 seconds)
    private static let holePunchRetryMaxInterval: TimeInterval = 60.0

    /// Task for periodic credential state updates
    private var stateUpdateTask: Task<Void, Never>?

    /// Task for post-foreground recovery checks
    private var foregroundRecoveryTask: Task<Void, Never>?

    /// Task for network change recovery (WiFi/cellular handoff)
    private var networkChangeRecoveryTask: Task<Void, Never>?

    /// A path/connectivity event arrived while foreground-resume gates were
    /// closed. `NetworkReachabilityMonitor` may already have consumed the
    /// event by the time we resume, so force one transport recovery afterward.
    private var pendingNetworkRecoveryAfterResume = false

    /// Interval for periodic state updates (30 seconds)
    private static let stateUpdateInterval: TimeInterval = 30.0

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshSession"
    )

    // MARK: - Initialization

    /// Creates a new mosh session
    /// - Parameters:
    ///   - config: Mosh connection configuration
    ///   - pty: Terminal PTY (usually from TerminalView)
    ///   - terminalId: Optional terminal UUID for credential persistence
    init(config: MoshConfig, pty: TerminalPTY, terminalId: UUID? = nil) {
        self.config = config
        self.pty = pty
        self.terminalId = terminalId
    }

    // MARK: - TerminalSession Protocol Implementation

    /// Starts the mosh session
    /// - Parameter restoringFromTerminalId: If provided, attempts to resume from saved credentials first
    func start(restoringFromTerminalId: UUID? = nil) async throws {
        guard !isRunning else {
            throw MoshError.sessionAlreadyStarted
        }

        let host = config.host
        Self.logger.info("Starting mosh session to \(host)")
        state = .initial
        didEndSession = false

        // If we have a terminal ID to restore from, try resuming first
        if let restoreId = restoringFromTerminalId ?? terminalId {
            let resumeResult = await attemptResume(terminalId: restoreId)
            if resumeResult {
                return  // Successfully resumed
            }
            // Fall through to normal SSH spawn
        }

        // Normal SSH spawn path
        try await spawnAndConnect()
    }

    /// Standard start() without restoration
    func start() async throws {
        try await start(restoringFromTerminalId: nil)
    }

    // MARK: - Resume Logic

    /// Timeout for resume connection attempt before falling back to SSH
    private static let resumeConnectionTimeout: TimeInterval = 5.0

    /// Continuation for waiting on first server packet during resume
    /// Returns true if server responded, false if timed out
    private var resumePacketContinuation: CheckedContinuation<Bool, Never>?

    /// Flag to track if we've received first packet during resume
    private var receivedFirstPacket: Bool = false

    /// Flag to prevent double-resumption of the continuation
    private var resumeContinuationConsumed: Bool = false

    /// Attempts to resume a session from saved credentials
    /// - Parameter terminalId: The terminal UUID to resume
    /// - Returns: true if resume succeeded, false if should fall back to SSH spawn
    private func attemptResume(terminalId: UUID) async -> Bool {
        Self.logger.info("Attempting to resume session for terminal \(terminalId.uuidString)")

        // Step 1: Check if we have valid credentials
        let result = resumer.checkCredentials(terminalId: terminalId)

        switch result {
        case .success(let credentials):
            // Step 2: Try to connect directly via UDP
            return await attemptDirectConnection(credentials: credentials, terminalId: terminalId)

        case .credentialsExpired:
            Self.logger.info("Resume failed: credentials expired")
            state = .resumeFallback(reason: "Session credentials expired")
            return false

        case .noCredentials:
            Self.logger.debug("No saved credentials for resume")
            // Don't show fallback state - this is the normal case for new connections
            return false

        case .credentialsCorrupted(let reason):
            Self.logger.warning("Resume failed: credentials corrupted - \(reason)")
            state = .resumeFallback(reason: "Credentials corrupted")
            return false
        }
    }

    /// Timeout after hole-punch attempt during resume
    private static let resumePostPunchTimeout: TimeInterval = 0.5

    /// Maximum hole-punch attempts during resume
    private static let resumeMaxHolePunchAttempts = 2

    /// Attempts direct UDP connection with saved credentials
    /// - Parameters:
    ///   - credentials: The saved session credentials
    ///   - terminalId: The terminal UUID (for credential cleanup on failure)
    /// - Returns: true if connection succeeded, false if should fall back to SSH spawn
    private func attemptDirectConnection(credentials: MoshSessionCredentials, terminalId: UUID) async -> Bool {
        // Update state to show we're resuming
        state = .resumingSession(host: credentials.host, port: credentials.udpPort)

        // Reset first packet tracking
        receivedFirstPacket = false
        resumePacketContinuation = nil

        do {
            let key = try credentials.toKey()
            self.sessionKey = key  // Store for periodic state updates
            self.sessionCreatedAt = credentials.createdAt  // Preserve original creation time for TTL

            // Restore bootstrap SSH algorithms from credentials
            self.bootstrapKeyExchange = credentials.bootstrapKeyExchange
            self.bootstrapHostKey = credentials.bootstrapHostKey
            self.bootstrapCipher = credentials.bootstrapCipher
            self.bootstrapMac = credentials.bootstrapMac

            // Check if hole-punching is enabled and do STUN discovery BEFORE creating transport
            // This ensures the transport binds to the same port STUN discovered
            var resumeHolePuncher: UDPHolePuncher?
            var connectionFamily: AddressFamily = .ipv4
            var stunLocalPort: UInt16 = 0  // 0 = let transport pick

            if config.holePunchConfig.enabled && config.holePunchConfig.mode != .never {
                // Resolve host to determine address family (same as spawnAndConnect)
                let isLocal = Self.isLocalDestination(credentials.host)
                if !isLocal {
                    // Try to resolve address family from host
                    if let resolved = try? await DualStackResolver.resolve(host: credentials.host, port: 0) {
                        connectionFamily = resolved.preferredFamily
                        self.resolvedAddresses = resolved
                        Self.logger.info("Resume: resolved addresses IPv4=\(resolved.ipv4Address ?? "nil"), IPv6=\(resolved.ipv6Address ?? "nil"), using \(connectionFamily.rawValue)")
                    } else if credentials.host.contains(":") {
                        connectionFamily = .ipv6
                    }

                    resumeHolePuncher = UDPHolePuncher(
                        config: config.holePunchConfig,
                        sshConfig: config.sshConfig,
                        moshServerPort: credentials.udpPort,
                        addressFamily: connectionFamily
                    )
                    resumeHolePuncher?.delegate = self
                    resumeHolePuncher?.onHostKeyValidation = onHostKeyValidation
                    self.holePuncher = resumeHolePuncher
                    Self.logger.info("Resume: hole-puncher created for \(connectionFamily.rawValue)")

                    // Do STUN discovery NOW to get local port BEFORE creating transport
                    // This ensures transport binds to the same port STUN uses
                    do {
                        let stun = try await resumeHolePuncher!.punch()
                        self.stunResult = stun
                        self.stunResultTimestamp = Date()
                        stunLocalPort = stun.localPort
                        Self.logger.info("Resume: pre-transport STUN discovered \(stun.publicIP):\(stun.publicPort), localPort=\(stun.localPort)")
                    } catch {
                        Self.logger.warning("Resume: pre-transport STUN failed: \(error.localizedDescription) - will try direct connection")
                        // Continue without STUN - direct connection might work
                    }
                }
            }

            // Create transport with STUN local port (or 0 if no STUN)
            // This ensures we bind to the same port that STUN discovered
            let transport = MoshTransport(
                host: credentials.host,
                port: credentials.udpPort,
                localPort: stunLocalPort,
                addressFamily: connectionFamily
            )
            self.transport = transport

            // Build resume state from saved credentials
            let cryptoResumeState = MoshTransport.ResumeState(
                outgoingSequence: credentials.outgoingSequence,
                expectedIncomingSequence: credentials.lastIncomingSequence
            )
            let stateSyncResumeState = MoshStateSync.ResumeState(
                sentStateNum: credentials.sentStateNum,
                assumedReceiverStateNum: credentials.assumedReceiverStateNum,
                lastReceivedStateNum: credentials.lastReceivedStateNum
            )

            Self.logger.info("Resuming with crypto(outSeq=\(credentials.outgoingSequence), inSeq=\(credentials.lastIncomingSequence)), stateSync(sent=\(credentials.sentStateNum), recv=\(credentials.lastReceivedStateNum))")

            // Connect transport with resume state
            try await transport.connect(key: key, resumeState: cryptoResumeState)

            // Initialize state sync with resume state
            state = .synchronizing

            let stateSync = MoshStateSync(transport: transport, resumeState: stateSyncResumeState)
            stateSync.delegate = self
            stateSync.setPredictionMode(config.predictionMode)
            stateSync.setPredictOverwrite(config.predictOverwrite)
            self.stateSync = stateSync
            await stateSync.start()

            // If we have a STUN result, punch IMMEDIATELY after transport connects
            // The server is sending to our OLD address from before backgrounding,
            // so we won't get a response unless we tell it our NEW address via punch
            if let puncher = resumeHolePuncher, let stun = stunResult {
                Self.logger.info("Resume: executing immediate server punch to update server's client address")
                state = .resumeHolePunching(publicIP: stun.publicIP, publicPort: stun.publicPort)
                do {
                    try await puncher.executeServerPunch(clientIP: stun.publicIP, clientPort: stun.publicPort)
                    Self.logger.info("Resume: immediate server punch executed to \(stun.publicIP):\(stun.publicPort)")
                } catch {
                    Self.logger.warning("Resume: immediate server punch failed: \(error.localizedDescription)")
                }
            }

            // Now wait for server response
            Self.logger.info("Waiting for server response...")

            let directTimeout = resumeHolePuncher != nil ? Self.resumePostPunchTimeout : Self.resumeConnectionTimeout
            var serverResponded = await waitForServerResponse(timeout: directTimeout)

            // If still no response and we have a hole-puncher, try with fresh STUN
            if !serverResponded, let puncher = resumeHolePuncher {
                Self.logger.info("No response after initial punch - retrying with fresh STUN")

                for attempt in 1...Self.resumeMaxHolePunchAttempts {
                    Self.logger.info("Resume hole-punch retry \(attempt)/\(Self.resumeMaxHolePunchAttempts)")

                    // Do fresh STUN discovery in case our address changed
                    Self.logger.info("Refreshing STUN for retry attempt")
                    if let freshStun = try? await puncher.refreshWithNewSTUN() {
                        self.stunResult = freshStun
                        self.stunResultTimestamp = Date()
                        Self.logger.info("Resume: fresh STUN discovered \(freshStun.publicIP):\(freshStun.publicPort)")

                        state = .resumeHolePunching(publicIP: freshStun.publicIP, publicPort: freshStun.publicPort)

                        // refreshWithNewSTUN() already executed the server punch via executePunchCommand()
                        // (see UDPHolePuncher.swift:373-377), so we just wait for the response here.
                        serverResponded = await waitForServerResponse(timeout: Self.resumePostPunchTimeout)
                        if serverResponded {
                            Self.logger.info("Resume hole-punch succeeded on retry \(attempt)")
                            break
                        }
                    }

                    // Small delay before next retry
                    if attempt < Self.resumeMaxHolePunchAttempts {
                        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
                    }
                }
            }

            if !serverResponded {
                Self.logger.warning("Resume timed out - no response from server (with\(resumeHolePuncher != nil ? "" : "out") hole-punch)")
                // Clean up
                stateSync.stop()
                self.stateSync = nil
                transport.disconnect()
                self.transport = nil
                holePuncher?.stop()
                holePuncher = nil
                // Delete stale credentials since server didn't respond
                try? KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
                state = .resumeFallback(reason: "Server not responding")
                return false
            }

            // Server responded! Force a full screen redraw by sending a resize "jiggle".
            //
            // On resume, our local framebuffer is empty but the server assumes we have
            // the full terminal state. Server diffs are incremental - they only contain
            // changes, not the full content. To get a full redraw:
            // 1. Send a resize to a different size (triggers SIGWINCH, shell redraws)
            // 2. Send resize to correct size (another SIGWINCH, shell redraws at correct size)
            //
            // This ensures the shell sends complete screen content, not just diffs.
            let currentSize = pendingResize ?? pty.windowSize
            do {
                // Send resize jiggle to trigger SIGWINCH on the server.
                // Use requestRepaint: false to avoid premature repaints with garbage state.
                // The natural packet handling will repaint when server data arrives.

                // Choose a jiggle size that actually differs from current size.
                let jiggleCols: UInt16
                let jiggleRows: UInt16
                if currentSize.cols > 1 {
                    jiggleCols = currentSize.cols - 1
                    jiggleRows = currentSize.rows
                } else if currentSize.rows > 1 {
                    jiggleCols = currentSize.cols
                    jiggleRows = currentSize.rows - 1
                } else {
                    jiggleCols = currentSize.cols + 1
                    jiggleRows = currentSize.rows
                }

                try await stateSync.sendResize(
                    width: UInt32(jiggleCols),
                    height: UInt32(jiggleRows),
                    requestRepaint: false
                )
                Self.logger.info("Sent jiggle resize: \(jiggleCols)x\(jiggleRows)")

                let jiggleAcked = await waitForServerResize(
                    cols: jiggleCols,
                    rows: jiggleRows,
                    timeout: Self.resumeResizeAckTimeout
                )
                if !jiggleAcked {
                    Self.logger.warning("Resume jiggle resize ack timed out (\(jiggleCols)x\(jiggleRows))")
                }

                // Now send the correct size - this triggers another SIGWINCH
                // and the shell will redraw at the correct dimensions
                try await stateSync.sendResize(
                    width: UInt32(currentSize.cols),
                    height: UInt32(currentSize.rows),
                    requestRepaint: false
                )

                let finalAcked = await waitForServerResize(
                    cols: currentSize.cols,
                    rows: currentSize.rows,
                    timeout: Self.resumeResizeAckTimeout
                )
                if !finalAcked {
                    Self.logger.warning("Resume final resize ack timed out (\(currentSize.cols)x\(currentSize.rows))")
                }

                lastSentResize = currentSize
                self.pendingResize = nil
                Self.logger.info("Sent final resize after resume: \(currentSize.cols)x\(currentSize.rows)")

                // Now enable repainting - the resize jiggle has been sent,
                // and incoming SIGWINCH responses can trigger repaint.
                stateSync.enableRepainting()
            } catch {
                Self.logger.warning("Failed to send resize: \(error.localizedDescription)")
            }

            wasResumed = true
            isRunning = true
            connectionStartTime = Date()
            state = .running(latencyMs: nil)

            // Start network observer and retry loop if we have a hole-puncher (for mid-session recovery)
            if stunResult != nil {
                setupNetworkChangeObserver()
                startHolePunchRetryLoop()
            }

            Self.logger.info("Mosh session resumed successfully (no SSH spawn needed)")
            startPeriodicStateUpdates()
            onReady?()
            return true

        } catch {
            Self.logger.warning("Resume connection failed: \(error.localizedDescription)")
            // Clean up
            stateSync?.stop()
            self.stateSync = nil
            transport?.disconnect()
            self.transport = nil
            holePuncher?.stop()
            holePuncher = nil
            // Delete credentials if the error suggests key mismatch
            let errorDesc = error.localizedDescription.lowercased()
            if errorDesc.contains("decrypt") || errorDesc.contains("key") || errorDesc.contains("auth") {
                try? KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
            }
            state = .resumeFallback(reason: error.localizedDescription)
            return false
        }
    }

    /// Waits for the first packet from server, with timeout
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Returns: true if server responded, false if timed out
    private func waitForServerResponse(timeout: TimeInterval) async -> Bool {
        // If we already received a packet (race condition), return immediately
        if receivedFirstPacket {
            return true
        }

        // Reset continuation state
        resumeContinuationConsumed = false

        // Start timeout task before setting up continuation
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Resume with false if not already consumed
            self.resumeContinuationWithResult(false)
        }

        // Wait for either server response or timeout
        let result = await withCheckedContinuation { continuation in
            // Check again in case packet arrived between check and continuation setup
            if self.receivedFirstPacket {
                continuation.resume(returning: true)
                return
            }
            self.resumePacketContinuation = continuation
        }

        // Cancel timeout if server responded first
        timeoutTask.cancel()

        // Clean up
        resumePacketContinuation = nil

        return result
    }

    /// Waits for the server to report a specific resize (via HostMessage resize)
    /// Used during resume to avoid fixed sleeps and race conditions.
    private func waitForServerResize(cols: UInt16, rows: UInt16, timeout: TimeInterval) async -> Bool {
        if let last = lastServerResize, last.cols == cols, last.rows == rows {
            return true
        }

        // Cancel any existing waiter
        if let waiter = pendingResizeWaiter {
            waiter.timeoutTask?.cancel()
            waiter.resume(false)
            pendingResizeWaiter = nil
        }

        let waiter = ResizeWaiter(cols: cols, rows: rows)
        pendingResizeWaiter = waiter

        return await withCheckedContinuation { continuation in
            // Re-check in case resize arrived between initial check and continuation setup
            if let last = lastServerResize, last.cols == cols, last.rows == rows {
                pendingResizeWaiter = nil
                continuation.resume(returning: true)
                return
            }

            waiter.continuation = continuation
            waiter.timeoutTask = Task { @MainActor [weak self, weak waiter] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self, let waiter = waiter else { return }
                guard self.pendingResizeWaiter === waiter else { return }
                self.pendingResizeWaiter = nil
                waiter.resume(false)
            }
        }
    }

    /// Resumes the continuation with the given result (only once)
    private func resumeContinuationWithResult(_ result: Bool) {
        guard !resumeContinuationConsumed else { return }
        resumeContinuationConsumed = true

        if let continuation = resumePacketContinuation {
            resumePacketContinuation = nil
            continuation.resume(returning: result)
        }
    }

    /// Called when we receive data from the server (signals resume success)
    private func signalServerResponse() {
        guard !receivedFirstPacket else { return }
        receivedFirstPacket = true
        resumeContinuationWithResult(true)
    }

    // MARK: - SSH Spawn Path

    /// Resolved addresses for reactive hole-punching (stored for mid-session re-punch)
    private var resolvedAddresses: DualStackResolver.ResolvedAddresses?

    /// Spawns mosh-server via SSH and connects using reactive hole-punch strategy
    ///
    /// Flow:
    /// 1. Resolve hostname to both IPv4 and IPv6 (prefer IPv4)
    /// 2. Spawn mosh-server with `-s` flag (binds to SSH interface)
    /// 3. STUN discovery - get local port and create NAT mapping (same family)
    /// 4. Create transport using STUN local port (same family)
    /// 5. Start stateSync
    /// 6. If timeout (overlay) → server punch (reactive)
    ///
    /// Everything uses the same address family (IPv4 preferred) to avoid mismatches.
    private func spawnAndConnect() async throws {
        do {
            // Reset tracking for fresh connection
            receivedFirstPacket = false
            resumeContinuationConsumed = false
            resumePacketContinuation = nil
            serverPunchInProgress = false
            stunRefreshInProgress = false
            pendingStunRefresh = false
            stunRefreshRetryTask?.cancel()
            stunRefreshRetryTask = nil
            awaitingDataBeforeNextPunch = false
            stunResult = nil
            stunResultTimestamp = nil
            consecutivePunchFailures = 0

            // Phase 1: Resolve hostname FIRST to determine address family
            // This ensures server, STUN, and transport all use the same family
            let resolved = try await DualStackResolver.resolve(
                host: config.sshConfig.host,
                port: 0  // Port doesn't matter for resolution
            )
            self.resolvedAddresses = resolved

            Self.logger.info("Resolved addresses: IPv4=\(resolved.ipv4Address ?? "nil"), IPv6=\(resolved.ipv6Address ?? "nil")")

            // Determine connection parameters - prefer IPv4 for reliable STUN
            let connectionHost = resolved.preferredAddress ?? config.sshConfig.host
            let connectionFamily = resolved.preferredFamily

            Self.logger.info("Using \(connectionFamily.rawValue) for all Mosh components (server, STUN, transport)")

            // Phase 2: Spawn mosh-server via SSH using the resolved host
            // The -s flag makes mosh-server bind to the SSH connection's interface,
            // which will match the address family of connectionHost
            let spawner = MoshServerSpawner(config: config)
            spawner.delegate = self
            spawner.onKeyboardInteractiveChallenge = onKeyboardInteractiveChallenge
            spawner.onHostKeyValidation = onHostKeyValidation
            // Live card during bootstrap auth; the spawn-success drain fires
            // `.reset` and removes it once the SSH phase completes.
            spawner.setAuthBannerObserver(
                authBannerCardModel.makeBufferObserver(hostLabel: config.sshConfig.host)
            )
            self.spawner = spawner

            let spawnResult = try await spawner.spawn(resolvedHost: connectionHost)
            self.currentSpawnResult = spawnResult
            // Adopt the connection the spawner now keeps alive. It hosts the
            // remote-port scan and forwards for this mosh session. A re-spawn
            // uses a new spawner, so the previous connection is closed here.
            if let previous = self.controlConnection, previous !== spawner.controlConnection {
                Task { await previous.close() }
            }
            self.controlConnection = spawner.controlConnection

            // Capture bootstrap SSH algorithms from spawn
            self.bootstrapKeyExchange = spawnResult.sshKeyExchange
            self.bootstrapHostKey = spawnResult.sshHostKey
            self.bootstrapCipher = spawnResult.sshCipher
            self.bootstrapMac = spawnResult.sshMac

            // Capture server auth banners for inline display at `.running`.
            self.authBanners = spawnResult.authBanners

            Self.logger.info("Spawn result: host=\(spawnResult.host), port=\(spawnResult.port)")
            var connectionLocalPort: UInt16 = 0

            // Check if this is a local destination (skip STUN for local)
            let isLocal = Self.isLocalDestination(resolved.hostname)
                || resolved.ipv4Address.map { Self.isLocalDestination($0) } ?? false
                || resolved.ipv6Address.map { Self.isLocalDestination($0) } ?? false

            if !isLocal && config.holePunchConfig.enabled && config.holePunchConfig.mode != .never {
                // Phase 3a: STUN discovery - creates NAT mapping and gives us a local port
                state = .tryingDirectUDP(host: connectionHost, family: connectionFamily)

                // Pass connectionFamily to ensure STUN, transport, and server all use
                // the same address family. IPv4 is preferred for reliable NAT traversal.
                let puncher = UDPHolePuncher(
                    config: config.holePunchConfig,
                    sshConfig: config.sshConfig,
                    moshServerPort: spawnResult.port,
                    addressFamily: connectionFamily
                )
                puncher.delegate = self
                puncher.onHostKeyValidation = onHostKeyValidation
                self.holePuncher = puncher

                do {
                    let stun = try await puncher.punch()
                    self.stunResult = stun
                    self.stunResultTimestamp = Date()  // Mark when STUN was performed
                    connectionLocalPort = stun.localPort

                    Self.logger.info("STUN discovery: public=\(stun.publicIP):\(stun.publicPort), local=\(stun.localPort), reliable=\(stun.isReliable)")

                    // If alwaysPunch mode, do server punch immediately
                    if config.holePunchConfig.mode == .always ||
                       config.holePunchConfig.initialStrategy == .alwaysPunch {
                        state = .holePunching(publicIP: stun.publicIP, publicPort: stun.publicPort)
                        try await puncher.executeServerPunch(clientIP: stun.publicIP, clientPort: stun.publicPort)
                        Self.logger.info("Proactive server punch completed")
                    }
                } catch {
                    Self.logger.warning("STUN discovery failed: \(error.localizedDescription) - continuing without")
                    // Continue without STUN - direct connection might still work
                }
            } else {
                Self.logger.info("Skipping STUN: isLocal=\(isLocal), enabled=\(self.config.holePunchConfig.enabled), mode=\(self.config.holePunchConfig.mode.rawValue)")
            }

            // Phase 4: Connect UDP transport using STUN local port (or 0 if no STUN)
            state = .connectingUDP(host: connectionHost, port: spawnResult.port)

            let transport = MoshTransport(
                host: connectionHost,
                port: spawnResult.port,
                localPort: connectionLocalPort,
                addressFamily: connectionFamily
            )
            self.transport = transport

            try await transport.connect(key: spawnResult.key)

            // Phase 5: Initialize state sync
            // If direct connectivity doesn't work, mosh's overlay system will trigger
            // stateSyncNeedsHolePunch() after ~250ms of no server response
            state = .synchronizing

            let stateSync = MoshStateSync(transport: transport)
            stateSync.delegate = self
            stateSync.setPredictionMode(config.predictionMode)
            stateSync.setPredictOverwrite(config.predictOverwrite)
            self.stateSync = stateSync
            await stateSync.start()

            // Send initial resize - use pending size or current PTY size
            let initialSize = pendingResize ?? pty.windowSize
            if initialSize.cols > 0 && initialSize.rows > 0 {
                do {
                    try await stateSync.sendResize(
                        width: UInt32(initialSize.cols),
                        height: UInt32(initialSize.rows)
                    )
                    lastSentResize = initialSize
                    self.pendingResize = nil
                } catch {
                    Self.logger.warning("Failed to send initial resize: \(error.localizedDescription)")
                }
            }

            // Start network change observer and retry loop if we have STUN result
            if stunResult != nil {
                setupNetworkChangeObserver()
                startHolePunchRetryLoop()  // Start ongoing retry loop for recovery
            }

            isRunning = true
            connectionStartTime = Date()
            state = .running(latencyMs: nil)

            // Save credentials for future resume
            if let terminalId = terminalId {
                saveCredentials(
                    key: spawnResult.key,
                    port: spawnResult.port,
                    host: connectionHost,
                    terminalId: terminalId
                )
            }

            Self.logger.info("Mosh session started (stunPort=\(connectionLocalPort))")
            startPeriodicStateUpdates()
            onReady?()

        } catch let error as MoshError {
            state = .failed
            Self.logger.error("Mosh session failed: \(error.localizedDescription)")
            onError?(error)
            throw error
        } catch let error as ManagedCertificateError {
            // A cancelled/failed inline certificate sign-in during the mosh-server SSH
            // bootstrap. Preserve the typed error (don't flatten it into an opaque
            // sshConnectionFailed) so the retry layer classifies it as permanent.
            state = .failed
            onError?(error)
            throw error
        } catch {
            state = .failed
            let moshError = MoshError.sshConnectionFailed(reason: error.localizedDescription)
            Self.logger.error("Mosh session failed: \(error.localizedDescription)")
            onError?(moshError)
            throw moshError
        }
    }

    // MARK: - Credential Persistence

    /// The session key (stored for state updates)
    private var sessionKey: MoshBase64Key?

    /// The original session creation time (for TTL tracking)
    private var sessionCreatedAt: Date?

    /// Saves session credentials to Keychain for future resume
    private func saveCredentials(key: MoshBase64Key, port: Int, host: String, terminalId: UUID) {
        self.sessionKey = key
        self.sessionCreatedAt = Date()

        let credentials = MoshSessionCredentials(
            key: key,
            port: port,
            host: host,
            terminalId: terminalId,
            displayName: config.displayName,
            bootstrapKeyExchange: bootstrapKeyExchange,
            bootstrapHostKey: bootstrapHostKey,
            bootstrapCipher: bootstrapCipher,
            bootstrapMac: bootstrapMac
        )

        do {
            try KeychainManager.shared.saveMoshSessionCredentials(credentials, terminalId: terminalId)
            Self.logger.info("Saved Mosh credentials for terminal \(terminalId.uuidString)")
        } catch {
            Self.logger.warning("Failed to save Mosh credentials: \(error.localizedDescription)")
        }
    }

    /// Updates saved credentials with current state (call periodically or on app background)
    /// - Parameter pauseForConsistency: If true, pauses state sync during save to ensure consistency
    func updateCredentialState(pauseForConsistency: Bool = false) async {
        guard let terminalId = terminalId else {
            Self.logger.debug("updateCredentialState: no terminalId")
            return
        }
        guard let key = sessionKey else {
            Self.logger.debug("updateCredentialState: no sessionKey")
            return
        }
        guard let transport = transport else {
            Self.logger.debug("updateCredentialState: no transport")
            return
        }
        guard let stateSync = stateSync else {
            Self.logger.debug("updateCredentialState: no stateSync")
            return
        }
        guard isRunning else {
            Self.logger.debug("updateCredentialState: not running")
            return
        }

        // Pause state sync if requested to ensure consistent state capture
        if pauseForConsistency {
            stateSync.pause()
        }

        defer {
            // Resume state sync after saving (if we paused it)
            if pauseForConsistency {
                stateSync.resume()
            }
        }

        // Get current crypto state
        guard let cryptoState = transport.getCryptoState() else {
            Self.logger.warning("updateCredentialState: failed to get crypto state")
            return
        }

        // Get current state sync state
        let stateSyncState = stateSync.getCurrentState()

        Self.logger.info("Saving credential state: outSeq=\(cryptoState.outgoingSequence), inSeq=\(cryptoState.expectedIncoming), sentState=\(stateSyncState.sentStateNum), recvState=\(stateSyncState.lastReceivedStateNum)")

        let credentials = MoshSessionCredentials(
            key: key,
            port: transport.port,
            host: transport.host,
            terminalId: terminalId,
            displayName: config.displayName,
            outgoingSequence: cryptoState.outgoingSequence,
            lastIncomingSequence: cryptoState.expectedIncoming,
            sentStateNum: stateSyncState.sentStateNum,
            assumedReceiverStateNum: stateSyncState.assumedReceiverStateNum,
            lastReceivedStateNum: stateSyncState.lastReceivedStateNum,
            createdAt: sessionCreatedAt,  // Preserve original creation time for TTL
            bootstrapKeyExchange: bootstrapKeyExchange,
            bootstrapHostKey: bootstrapHostKey,
            bootstrapCipher: bootstrapCipher,
            bootstrapMac: bootstrapMac
        )

        do {
            try KeychainManager.shared.saveMoshSessionCredentials(credentials, terminalId: terminalId)
            Self.logger.info("Updated Mosh credentials in keychain")
        } catch {
            Self.logger.error("Failed to update Mosh credentials: \(error.localizedDescription)")
        }
    }

    /// Deletes session credentials from Keychain
    private func deleteCredentials() {
        guard let terminalId = terminalId else { return }

        do {
            try KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
            Self.logger.info("Deleted Mosh credentials for terminal \(terminalId.uuidString)")
        } catch {
            Self.logger.warning("Failed to delete Mosh credentials: \(error.localizedDescription)")
        }
    }

    /// Starts periodic state updates for resume persistence
    private func startPeriodicStateUpdates() {
        guard terminalId != nil else { return }

        stateUpdateTask?.cancel()
        stateUpdateTask = Task { @MainActor [weak self] in
            // Initial update after 2 seconds (let session stabilize)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let strongSelf = self, strongSelf.isRunning else { return }
            await strongSelf.updateCredentialState()
            Self.logger.info("Initial credential state update completed")

            // Then update every 30 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.stateUpdateInterval * 1_000_000_000))
                guard let strongSelf = self, strongSelf.isRunning else { break }
                await strongSelf.updateCredentialState()
            }
        }

        // Also register for app background notification
        setupBackgroundNotification()
    }

    /// Observer for background notification
    private var backgroundObserver: NSObjectProtocol?

    /// Observer for foreground notification
    private var foregroundObserver: NSObjectProtocol?

    /// Observer for termination notification
    private var terminationObserver: NSObjectProtocol?

    /// Sets up notification to save state when app goes to background or terminates
    private func setupBackgroundNotification() {
        // Mac Catalyst uses UIKit, so UIApplication notifications work on all platforms
        let backgroundName = UIApplication.willResignActiveNotification
        let terminateName = UIApplication.willTerminateNotification
        let foregroundName = UIApplication.didBecomeActiveNotification

        // Save on background - PAUSE first to freeze state, then save
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: backgroundName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isRunning else { return }
                self.foregroundRecoveryTask?.cancel()
                self.foregroundRecoveryTask = nil
                self.networkChangeRecoveryTask?.cancel()
                self.networkChangeRecoveryTask = nil
                // Pause immediately on main thread to stop state advancement
                self.stateSync?.pause()
                Task { @MainActor in
                    // Save with state already paused
                    await self.updateCredentialState(pauseForConsistency: false)
                    Self.logger.info("Updated credential state on app background (state sync paused)")
                    // Note: We don't resume here - state stays paused while backgrounded
                }
            }
        }

        // Resume on foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: foregroundName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumeAfterForegroundQuietWindow()
            }
        }

        // Save on termination (CMD-Q, etc.) - PAUSE and save synchronously
        terminationObserver = NotificationCenter.default.addObserver(
            forName: terminateName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isRunning else { return }
                // Pause immediately
                self.stateSync?.pause()
                // Use a semaphore to make this synchronous - termination must wait for save
                let semaphore = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await self.updateCredentialState(pauseForConsistency: false)
                    Self.logger.info("Updated credential state on app termination")
                    semaphore.signal()
                }
                // Wait for save to complete (with timeout to avoid hanging termination)
                _ = semaphore.wait(timeout: .now() + 2.0)
            }
        }
    }

    /// Removes background, foreground, and termination notification observers
    private func removeBackgroundNotification() {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
    }

    private func resumeAfterForegroundQuietWindow(attempt: Int = 0) {
        guard isRunning else { return }
        guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
            LifecycleDebugLogger.shared.checkpoint("Mosh.fg.deferred", ms: nil, [
                ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                ("attempt", attempt),
            ])
            guard attempt < 25 else {
                LifecycleDebugLogger.shared.checkpoint("Mosh.fg.deferred.gaveUp")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.resumeAfterForegroundQuietWindow(attempt: attempt + 1)
                }
            }
            return
        }

        stateSync?.resume()
        stateSync?.requestForegroundRecovery(reason: "didBecomeActive")
        LifecycleDebugLogger.shared.checkpoint("Mosh.fg.networkRefresh")
        NetworkReachabilityMonitor.shared.replayLatestPathAfterResumeQuietWindow()

        if holePuncher != nil {
            setupNetworkChangeObserver()
            startHolePunchRetryLoop()
        }
        forcePendingNetworkRecoveryIfNeeded(reason: "resume_deferred_network_change")
        scheduleForegroundBannerRecovery()
        Self.logger.info("Resumed state sync on app foreground")
    }

    private func forcePendingNetworkRecoveryIfNeeded(reason: String) {
        guard pendingNetworkRecoveryAfterResume else { return }
        pendingNetworkRecoveryAfterResume = false
        guard isRunning, let transport else { return }

        LifecycleDebugLogger.shared.checkpoint("Mosh.networkChange.replayed", ms: nil, [
            ("reason", reason),
        ])
        // A latest-path replay can synchronously schedule the normal delayed
        // recovery task. Cancel it before forcing this immediate recovery;
        // if the task somehow already passed cancellation, one extra
        // reconnect is harmless.
        networkChangeRecoveryTask?.cancel()
        awaitingDataBeforeNextPunch = false
        transport.requestImmediateReconnect(reason: reason, force: true)

        if holePuncher != nil {
            networkChangeRecoveryTask = Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                _ = await self.triggerFreshSTUNDiscovery()
            }
        }
    }

    /// Stops periodic state updates
    private func stopPeriodicStateUpdates() {
        stateUpdateTask?.cancel()
        stateUpdateTask = nil
        removeBackgroundNotification()
    }

    /// Stops the mosh session
    func stop() {
        Self.logger.info("Stopping mosh session")

        state = .disconnected
        authBanners = []
        endSession(shouldDeleteCredentials: true, emitSessionEnd: true)
    }

    /// Terminates the session for user-initiated tab close.
    /// Sends disconnect and deletes credentials.
    /// Does NOT emit onSessionEnd (caller handles tab removal).
    func terminate() {
        Self.logger.info("Terminating mosh session (user-initiated close)")

        state = .disconnected
        endSession(shouldDeleteCredentials: true, emitSessionEnd: false)
    }

    /// Stops the session without deleting credentials or emitting onSessionEnd.
    /// Used by cleanup() during scene teardown so credentials survive force-quit.
    func stopForReconnect() {
        Self.logger.info("Stopping mosh session for reconnect (preserving credentials)")

        state = .disconnected
        endSession(shouldDeleteCredentials: false, emitSessionEnd: false)
    }

    /// Notifies the session that its tab visibility changed.
    /// When not visible, reduces CPU usage by throttling tick frequency and skipping frame rendering.
    /// - Parameter visible: true if the tab is visible, false if hidden/background
    func setTabVisible(_ visible: Bool) {
        // Throttle if stateSync exists, regardless of isRunning
        // Sessions may have stateSync active even during connecting/disconnected states
        guard let stateSync = stateSync else {
            return
        }

        if visible {
            stateSync.unthrottle(predictionMode: config.predictionMode)
        } else {
            stateSync.throttle()
        }
    }

    // MARK: - Network Change Handling

    /// Cancellables for network change subscriptions
    private var networkChangeCancellables: Set<AnyCancellable> = []

    /// Sets up observer for network changes to trigger hole-punch refresh
    private func setupNetworkChangeObserver() {
        removeNetworkChangeObserver()

        // Subscribe to connection type changes (WiFi→Cellular, etc.)
        // This forces transport reconnect to bind to new interface, then refreshes STUN
        NetworkReachabilityMonitor.shared.connectionTypeChanged
            .sink { [weak self] newType in
                MainActor.assumeIsolated {
                    guard let self = self, self.isRunning else { return }
                    guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
                        self.pendingNetworkRecoveryAfterResume = true
                        LifecycleDebugLogger.shared.checkpoint("Mosh.networkChange.skipped", ms: nil, [
                            ("reason", "resumeGate"),
                            ("event", "connectionTypeChanged"),
                        ])
                        return
                    }

                    // Cancel any pending network change recovery to avoid stacking
                    self.networkChangeRecoveryTask?.cancel()

                    self.networkChangeRecoveryTask = Task { @MainActor [weak self] in
                        guard let self = self, self.isRunning else { return }
                        guard let transport = self.transport else { return }

                        Self.logger.info("Network type changed to \(newType.description) - scheduling transport reconnect")

                        // Reset the punch gate since network conditions have changed
                        self.awaitingDataBeforeNextPunch = false

                        // Wait for the new interface to be fully ready
                        // NWPathMonitor fires immediately but the interface may not be usable yet
                        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s

                        // Check if cancelled (sleep swallows CancellationError with try?)
                        guard !Task.isCancelled else { return }
                        guard self.isRunning else { return }
                        guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
                            self.pendingNetworkRecoveryAfterResume = true
                            LifecycleDebugLogger.shared.checkpoint("Mosh.networkChange.skipped", ms: nil, [
                                ("reason", "resumeGateAfterDelay"),
                                ("event", "connectionTypeChanged"),
                            ])
                            return
                        }

                        Self.logger.info("Network type changed to \(newType.description) - forcing transport reconnect")

                        // Force NWConnection recreation to bind to new interface
                        transport.requestImmediateReconnect(reason: "network_type_changed", force: true)

                        // STUN refresh for hole-punch enabled sessions
                        if self.holePuncher != nil {
                            _ = await self.triggerFreshSTUNDiscovery()
                        }
                    }
                }
            }
            .store(in: &networkChangeCancellables)

        // Subscribe to connectivity restoration (network came back after being lost)
        // This forces transport reconnect to bind to restored network, then refreshes STUN
        NetworkReachabilityMonitor.shared.connectivityRestored
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self, self.isRunning else { return }
                    guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
                        self.pendingNetworkRecoveryAfterResume = true
                        LifecycleDebugLogger.shared.checkpoint("Mosh.networkChange.skipped", ms: nil, [
                            ("reason", "resumeGate"),
                            ("event", "connectivityRestored"),
                        ])
                        return
                    }

                    // Cancel any pending network change recovery to avoid stacking
                    self.networkChangeRecoveryTask?.cancel()

                    self.networkChangeRecoveryTask = Task { @MainActor [weak self] in
                        guard let self = self, self.isRunning else { return }
                        guard let transport = self.transport else { return }

                        Self.logger.info("Connectivity restored - scheduling transport reconnect")

                        // Reset the punch gate since we're starting fresh
                        self.awaitingDataBeforeNextPunch = false

                        // Wait for the restored network to be fully ready
                        // NWPathMonitor fires immediately but the interface may not be usable yet
                        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s

                        // Check if cancelled (sleep swallows CancellationError with try?)
                        guard !Task.isCancelled else { return }
                        guard self.isRunning else { return }
                        guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
                            self.pendingNetworkRecoveryAfterResume = true
                            LifecycleDebugLogger.shared.checkpoint("Mosh.networkChange.skipped", ms: nil, [
                                ("reason", "resumeGateAfterDelay"),
                                ("event", "connectivityRestored"),
                            ])
                            return
                        }

                        Self.logger.info("Connectivity restored - forcing transport reconnect")

                        // Force NWConnection recreation to bind to restored network
                        transport.requestImmediateReconnect(reason: "connectivity_restored", force: true)

                        // STUN refresh for hole-punch enabled sessions
                        if self.holePuncher != nil {
                            _ = await self.triggerFreshSTUNDiscovery()
                        }
                    }
                }
            }
            .store(in: &networkChangeCancellables)
    }

    /// Removes network change observer
    private func removeNetworkChangeObserver() {
        networkChangeCancellables.forEach { $0.cancel() }
        networkChangeCancellables.removeAll()
    }

    /// After foregrounding, if the roam banner appears, force a reconnect and (if enabled) refresh STUN.
    private func scheduleForegroundBannerRecovery() {
        foregroundRecoveryTask?.cancel()

        foregroundRecoveryTask = Task { @MainActor [weak self] in
            guard let self = self, self.isRunning else { return }
            guard let transport = self.transport else { return }
            guard self.stateSync != nil else { return }

            // Give the transport a moment to settle after resume.
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s

            // Check if cancelled (sleep swallows CancellationError with try?)
            guard !Task.isCancelled else { return }
            guard self.isRunning else { return }
            guard self.stateSync?.isNetworkBannerVisible() == true else { return }

            // Force reconnect even if transport thinks it's connected.
            transport.requestImmediateReconnect(reason: "foreground_banner", force: true)

            if self.holePuncher != nil {
                if self.awaitingDataBeforeNextPunch {
                    Self.logger.info("Foreground recovery: clearing punch gate")
                    self.awaitingDataBeforeNextPunch = false
                }
                _ = await self.triggerFreshSTUNDiscovery()
            }
        }
    }

    // MARK: - Hole-Punch Recovery

    /// Triggers a fresh STUN discovery and updates stored result
    ///
    /// Drains any pending STUN refresh request by spawning a Task.
    /// Called after completing a STUN refresh or server punch to handle coalesced requests.
    private func drainPendingSTUNRefresh() {
        guard pendingStunRefresh else { return }
        pendingStunRefresh = false
        Task { @MainActor [weak self] in
            guard let self = self, self.isRunning else { return }
            _ = await self.triggerFreshSTUNDiscovery()
        }
    }

    /// Called when:
    /// - STUN result is stale (older than stunResultMaxAge)
    /// - Multiple consecutive punch failures
    /// - Retry loop detects unhealthy connection
    ///
    /// If STUN fails, schedules a single retry after 5 seconds.
    /// - Returns: true if a fresh STUN refresh completed (and punched), false otherwise
    @discardableResult
    private func triggerFreshSTUNDiscovery() async -> Bool {
        guard let puncher = holePuncher else {
            Self.logger.debug("triggerFreshSTUNDiscovery: no hole puncher available")
            return false
        }

        if let stateSync = stateSync, !stateSync.isNetworkBannerVisible() {
            Self.logger.debug("Roam banner not visible - skipping STUN refresh")
            return false
        }

        if stunRefreshInProgress || serverPunchInProgress {
            pendingStunRefresh = true
            Self.logger.debug("STUN refresh already in progress - coalescing request")
            return false
        }

        // Cancel any pending retry since we're actively refreshing now
        stunRefreshRetryTask?.cancel()
        stunRefreshRetryTask = nil

        stunRefreshInProgress = true
        serverPunchInProgress = true

        Self.logger.info("Triggering fresh STUN discovery")

        let result: Bool
        do {
            if let newResult = try await puncher.refreshWithNewSTUN() {
                stunResult = newResult
                stunResultTimestamp = Date()
                awaitingDataBeforeNextPunch = false
                consecutivePunchFailures = 0
                Self.logger.info("Fresh STUN complete: \(newResult.publicIP):\(newResult.publicPort)")
                result = true
            } else {
                Self.logger.warning("Fresh STUN discovery returned nil (puncher stopped)")
                result = false
            }
        } catch {
            Self.logger.warning("Fresh STUN discovery failed: \(error.localizedDescription)")
            // Schedule retry after delay
            stunRefreshRetryTask?.cancel()
            stunRefreshRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
                guard let strongSelf = self, strongSelf.isRunning else { return }
                _ = await strongSelf.triggerFreshSTUNDiscovery()
            }
            result = false
        }

        // Reset flags and drain pending requests after completing
        serverPunchInProgress = false
        stunRefreshInProgress = false
        drainPendingSTUNRefresh()

        return result
    }

    /// Starts the hole-punch retry loop
    ///
    /// This loop runs continuously while the session is active and hole-punching is enabled.
    /// It monitors connection health and triggers fresh STUN discovery when needed.
    /// Uses exponential backoff to avoid overwhelming the network.
    private func startHolePunchRetryLoop() {
        holePunchRetryTask?.cancel()

        holePunchRetryTask = Task { @MainActor [weak self] in
            var retryInterval = MoshSession.holePunchRetryBaseInterval
            var attempt = 0

            while !Task.isCancelled {
                guard let strongSelf = self, strongSelf.isRunning else { break }
                guard strongSelf.holePuncher != nil else { break }

                // Wait for retry interval
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))

                guard let strongSelf = self, strongSelf.isRunning else { break }

                // Skip hole-punch attempts while state sync is paused (app backgrounded)
                // When paused, we're saving state and shouldn't interfere with network
                if let stateSync = strongSelf.stateSync, stateSync.isPaused {
                    MoshSession.logger.debug("Retry loop: skipping while state sync is paused")
                    continue
                }

                if let stateSync = strongSelf.stateSync {
                    if !stateSync.isNetworkBannerVisible() {
                        continue
                    }
                } else {
                    continue
                }

                // Respect punch gate after a recent failed attempt
                if strongSelf.awaitingDataBeforeNextPunch {
                    MoshSession.logger.debug("Retry loop: awaiting data before next punch")
                    continue
                }

                // Check if we're receiving data (hole-punch working)
                // If healthy, no need to retry - just keep the loop alive for future issues
                if let transport = strongSelf.transport,
                   transport.isConnectionHealthy(timeoutMs: 10_000) {
                    // Connection is healthy, reset backoff
                    retryInterval = MoshSession.holePunchRetryBaseInterval
                    attempt = 0
                    continue
                }

                // Connection unhealthy - attempt fresh STUN + punch
                attempt += 1
                MoshSession.logger.info("Hole-punch retry loop: attempt \(attempt), interval \(retryInterval)s")

                let refreshed = await strongSelf.triggerFreshSTUNDiscovery()

                // If STUN refresh didn't run (or failed), fall back to punching with existing result
                if !refreshed,
                   !strongSelf.serverPunchInProgress,
                   !strongSelf.awaitingDataBeforeNextPunch,
                   let puncher = strongSelf.holePuncher,
                   let stun = strongSelf.stunResult {
                    MoshSession.logger.info("Retry loop executing fallback server punch to \(stun.publicIP):\(stun.publicPort)")
                    do {
                        try await puncher.executeServerPunch(clientIP: stun.publicIP, clientPort: stun.publicPort)
                        MoshSession.logger.info("Retry loop fallback server punch completed")
                    } catch {
                        MoshSession.logger.warning("Retry loop fallback server punch failed: \(error.localizedDescription)")
                    }
                }

                // Exponential backoff (capped)
                retryInterval = min(retryInterval * 1.5, MoshSession.holePunchRetryMaxInterval)
            }
        }
    }

    /// Stops the hole-punch retry loop
    private func stopHolePunchRetryLoop() {
        holePunchRetryTask?.cancel()
        holePunchRetryTask = nil
    }

    /// Sends input data to the session (synchronous for minimal latency)
    func sendInput(_ data: Data) {
        guard isRunning, let stateSync = stateSync else { return }
        // Call directly without Task wrapper - sendKeystroke is synchronous
        // and we need minimal latency for prediction feedback
        stateSync.sendKeystroke(data)
    }

    /// Sets the terminal size
    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size

        guard isRunning, let stateSync = stateSync else {
            pendingResize = size
            return
        }

        if let last = lastSentResize,
           last.rows == size.rows,
           last.cols == size.cols,
           last.pixelWidth == size.pixelWidth,
           last.pixelHeight == size.pixelHeight {
            return
        }

        Task {
            do {
                try await stateSync.sendResize(
                    width: UInt32(size.cols),
                    height: UInt32(size.rows)
                )
                self.lastSentResize = size
            } catch {
                Self.logger.error("Failed to send resize: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - MoshServerSpawner.Delegate

extension MoshSession: MoshServerSpawner.Delegate {
    func spawner(_ spawner: MoshServerSpawner, didChangeState state: MoshSessionState) {
        self.state = state
    }
}

// MARK: - MoshStateSync.Delegate

extension MoshSession: MoshStateSync.Delegate {
    func stateSync(_ sync: MoshStateSync, didReceiveOutput data: Data) {
        // NOTE: Don't call signalServerResponse() here - this fires for local output too
        // Use stateSyncDidReceiveServerPacket for actual network packets

        if !isRunning && (state == .disconnected || state == .failed) {
            return
        }

        if let onOutputData = onOutputData {
            onOutputData(data)
        } else if let onOutput = onOutput, let str = String(data: data, encoding: .utf8) {
            onOutput(str)
        }
    }

    func stateSync(_ sync: MoshStateSync, didReceiveResize width: UInt32, height: UInt32) {
        let cols = UInt16(min(width, UInt32(UInt16.max)))
        let rows = UInt16(min(height, UInt32(UInt16.max)))
        lastServerResize = (cols: cols, rows: rows)

        if let waiter = pendingResizeWaiter, waiter.cols == cols, waiter.rows == rows {
            pendingResizeWaiter = nil
            waiter.timeoutTask?.cancel()
            waiter.resume(true)
        }

        // Server-initiated resize - update PTY
        do {
            try pty.setWindowSize(TerminalPTY.TerminalSize(
                rows: rows,
                cols: cols
            ))
        } catch {
            Self.logger.warning("Failed to set window size: \(error.localizedDescription)")
        }
    }

    func stateSync(_ sync: MoshStateSync, didChangeState state: MoshSessionState) {
        // Handle state transitions
        switch state {
        case .serverShutdown:
            // Clean server shutdown (user typed exit) - don't reconnect
            Self.logger.info("Server shutdown - ending session without reconnection")
            self.state = state
            if roamBannerState != nil { roamBannerState = nil }  // Clear banner on shutdown
            endSession(shouldDeleteCredentials: true, emitSessionEnd: true)

        case .disconnected, .failed:
            // Mosh transport layer handles reconnection internally.
            // Just update state for UI display; don't trigger external reconnection.
            // NOTE: Don't delete credentials here - the session might recover
            if isRunning {
                self.state = state
            }

        default:
            self.state = state
        }
    }

    /// Common session teardown (idempotent)
    private func endSession(shouldDeleteCredentials: Bool, emitSessionEnd: Bool) {
        guard !didEndSession else { return }
        didEndSession = true

        if let waiter = pendingResizeWaiter {
            pendingResizeWaiter = nil
            waiter.timeoutTask?.cancel()
            waiter.resume(false)
        }

        stopPeriodicStateUpdates()
        stopHolePunchRetryLoop()
        removeNetworkChangeObserver()
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        networkChangeRecoveryTask?.cancel()
        networkChangeRecoveryTask = nil
        stunRefreshRetryTask?.cancel()
        stunRefreshRetryTask = nil
        stunRefreshInProgress = false
        pendingStunRefresh = false
        serverPunchInProgress = false
        holePuncher?.stop()
        holePuncher = nil
        stateSync?.stop()
        stateSync = nil
        transport?.disconnect()
        transport = nil
        // The retained spawn connection hosts any status-bar forwards; close
        // it with the session so no loopback listener survives.
        let control = controlConnection
        controlConnection = nil
        if let control {
            Task { await control.close() }
        }
        isRunning = false
        if roamBannerState != nil { roamBannerState = nil }  // Clear banner on session end

        if shouldDeleteCredentials {
            deleteCredentials()
        }

        if emitSessionEnd {
            onSessionEnd?()
        }
    }

    func stateSync(_ sync: MoshStateSync, didEncounterError error: MoshError) {
        Self.logger.error("State sync error: \(error.localizedDescription)")

        // Check for state desync - requires fresh SSH spawn
        if error.requiresFreshSession {
            Self.logger.warning("State desync detected - triggering SSH spawn fallback")
            handleStateDesync()
            return
        }

        // Mosh transport layer handles reconnection internally for recoverable errors.
        // Only report non-recoverable errors to trigger session termination.
        if !error.isRecoverable {
            onError?(error)
        }
        // For recoverable errors, the transport layer will attempt reconnection
        // and the notification engine displays the error to the user.
    }

    func stateSyncNeedsHolePunch(_ sync: MoshStateSync) -> Bool {
        // Defense-in-depth: MoshStateSync already gates this call on banner visibility,
        // but we check again here to guard against future refactoring that might
        // call this method from other code paths.
        guard sync.isNetworkBannerVisible() else {
            Self.logger.info("Roam banner not visible - skipping hole-punch")
            return false
        }

        // Check if server punch is already in progress
        guard !serverPunchInProgress else {
            Self.logger.info("Server punch already in progress, ignoring")
            return false
        }

        // Check if we're waiting for data after a previous punch
        guard !awaitingDataBeforeNextPunch else {
            Self.logger.info("Awaiting server data before allowing another punch")
            return false
        }

        // Check if we have a hole puncher
        guard let puncher = holePuncher else {
            return false
        }

        // Check if STUN result is stale - trigger fresh discovery if so
        if let timestamp = stunResultTimestamp,
           Date().timeIntervalSince(timestamp) > Self.stunResultMaxAge {
            Self.logger.info("STUN result is stale (\(Int(Date().timeIntervalSince(timestamp)))s old) - triggering fresh discovery")
            Task { @MainActor in
                await self.triggerFreshSTUNDiscovery()
            }
            return false  // Let fresh STUN complete first
        }

        // Check if we have STUN result to punch with
        guard let stun = stunResult else {
            Self.logger.info("No STUN result available for server punch - triggering fresh discovery")
            Task { @MainActor in
                await self.triggerFreshSTUNDiscovery()
            }
            return false
        }

        // Mark punch in progress
        serverPunchInProgress = true

        Self.logger.info("StateSync requested server punch - punching to \(stun.publicIP):\(stun.publicPort)")

        // Execute server punch asynchronously
        Task { @MainActor in
            await self.executeReactiveServerPunch(puncher: puncher, stun: stun)
        }

        return true
    }

    func stateSyncDidReceiveServerPacket(_ sync: MoshStateSync) {
        // Signal that server responded (for resume detection)
        // This is called only when actual network packets are received, not local output
        signalServerResponse()

        // Cancel any pending STUN retry once we have confirmed connectivity
        if stunRefreshRetryTask != nil {
            stunRefreshRetryTask?.cancel()
            stunRefreshRetryTask = nil
        }
        pendingStunRefresh = false

        // Reset hole-punch gate - we received data, so allow future hole-punch on timeout
        if awaitingDataBeforeNextPunch {
            awaitingDataBeforeNextPunch = false
            Self.logger.info("Received server packet - future hole-punch attempts now allowed")
        }
    }

    func stateSyncDidUpdateBannerState(_ sync: MoshStateSync, state: MoshRoamBannerState?) {
        // Update the published banner state for SwiftUI overlay
        // This is called from the send loop (~100ms cadence) so timers update smoothly.
        // Skip while the resume gate is up — the atomic stays true through the
        // deferred-resume window (after applicationState has already flipped to
        // .active), so under background QoS 10 SwiftUI updates/second won't pile
        // up and trip the scene-update watchdog (0x8BADF00D). The next tick
        // after the gate drops will push the fresh state.
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        // Equality-guard: the send loop calls this every tick whether banner
        // changed or not; an unchanged @Published assignment still fires
        // objectWillChange and invalidates every observer.
        if roamBannerState != state { roamBannerState = state }
    }

    /// Executes reactive server punch when mosh's overlay indicates connection timeout
    ///
    /// The STUN discovery was already done during connection setup - this just tells
    /// the server to send a UDP packet to our public IP:port to open the reverse NAT path.
    /// The existing transport continues running and should start receiving once punched.
    ///
    /// Tracks consecutive failures and escalates to fresh STUN discovery after
    /// `maxPunchFailuresBeforeReSTUN` failures, as repeated failures often indicate
    /// a stale STUN result (wrong public IP:port after network change).
    private func executeReactiveServerPunch(
        puncher: UDPHolePuncher,
        stun: UDPHolePuncher.HolePunchResult
    ) async {
        Self.logger.info("Executing reactive server punch to \(stun.publicIP):\(stun.publicPort)")

        state = .reactiveHolePunch(family: stun.addressFamily)

        do {
            try await puncher.executeServerPunch(clientIP: stun.publicIP, clientPort: stun.publicPort)

            Self.logger.info("Reactive server punch completed")
            serverPunchInProgress = false
            consecutivePunchFailures = 0  // Reset on success
            // Connection should now work - stateSync will naturally update state when data arrives
            drainPendingSTUNRefresh()

        } catch {
            Self.logger.error("Reactive server punch failed: \(error.localizedDescription)")
            serverPunchInProgress = false
            consecutivePunchFailures += 1

            if self.consecutivePunchFailures >= Self.maxPunchFailuresBeforeReSTUN {
                // Escalate to fresh STUN discovery
                let failureCount = self.consecutivePunchFailures
                Self.logger.warning("Multiple punch failures (\(failureCount)) - triggering fresh STUN discovery")
                self.awaitingDataBeforeNextPunch = false
                self.consecutivePunchFailures = 0
                Task { @MainActor in
                    await self.triggerFreshSTUNDiscovery()
                }
            } else {
                // Prevent immediate retry, but add timeout so we don't stay blocked forever
                awaitingDataBeforeNextPunch = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                    guard let self = self else { return }
                    if self.awaitingDataBeforeNextPunch {
                        Self.logger.info("Awaiting data timeout - allowing fresh punch attempt")
                        self.awaitingDataBeforeNextPunch = false
                    }
                }
            }
            // Don't set state to failed - existing connection is still trying
            drainPendingSTUNRefresh()
        }
    }

    /// Handles state desync by cleaning up and triggering fresh SSH spawn
    private func handleStateDesync() {
        guard !isAutoFallbackInProgress else {
            Self.logger.info("Auto-fallback already in progress, ignoring duplicate state desync")
            return
        }

        isAutoFallbackInProgress = true

        // Clean up current session
        stateSync?.stop()
        stateSync = nil
        transport?.disconnect()
        transport = nil
        isRunning = false

        // Delete stale credentials
        if let terminalId = terminalId {
            try? KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
            Self.logger.info("Deleted stale credentials for terminal \(terminalId.uuidString)")
        }

        // Update state to show we're falling back
        state = .resumeFallback(reason: "State desync - reconnecting via SSH")

        // Trigger fresh SSH spawn
        Task { @MainActor in
            Self.logger.info("Starting fresh SSH spawn after state desync")
            do {
                try await spawnAndConnect()
                isAutoFallbackInProgress = false
            } catch {
                Self.logger.error("SSH spawn fallback failed: \(error.localizedDescription)")
                isAutoFallbackInProgress = false
                state = .failed
                onError?(error)
            }
        }
    }
}

// MARK: - UDPHolePuncher.Delegate

extension MoshSession: UDPHolePuncher.Delegate {
    func holePuncher(_ puncher: UDPHolePuncher, didChangeState holePunchState: HolePunchState) {
        // Map hole-punch state to session state
        switch holePunchState {
        case .discoveringNAT:
            // Don't update session state - keep spawningServer
            Self.logger.debug("Hole-punch: discovering NAT")

        case .natDiscovered(let ip, let port, _):
            Self.logger.debug("Hole-punch: NAT discovered \(ip):\(port)")

        case .punchingHole(let attempt):
            if let ip = holePunchState.publicIP, let port = holePunchState.publicPort {
                state = .holePunching(publicIP: ip, publicPort: port)
            }
            Self.logger.debug("Hole-punch: punching (attempt \(attempt))")

        case .established:
            Self.logger.info("Hole-punch: established")

        case .refreshing:
            Self.logger.debug("Hole-punch: refreshing")

        case .failed(let reason):
            Self.logger.warning("Hole-punch: failed - \(reason)")

        case .notNeeded, .idle:
            break
        }
    }

    func holePuncherShouldRefresh(_ puncher: UDPHolePuncher) -> Bool {
        // Only refresh when the roam banner is visible (connection has issues)
        guard let stateSync = stateSync, stateSync.isNetworkBannerVisible() else {
            return false
        }
        return true
    }
}

// MARK: - Convenience Factory

extension MoshSession {
    /// Creates a mosh session from an SSH configuration
    /// - Parameters:
    ///   - sshConfig: SSH configuration (will be wrapped in MoshConfig)
    ///   - pty: Terminal PTY
    ///   - terminalId: Optional terminal UUID for credential persistence
    /// - Returns: A new mosh session
    static func create(
        sshConfig: SSHConfig,
        pty: TerminalPTY,
        terminalId: UUID? = nil
    ) -> MoshSession {
        let moshConfig = MoshConfig(sshConfig: sshConfig)
        return MoshSession(config: moshConfig, pty: pty, terminalId: terminalId)
    }
}

// MARK: - Local Destination Detection

extension MoshSession {
    /// Checks if a host is a local destination that doesn't need hole-punching
    ///
    /// Local destinations include:
    /// - localhost and loopback addresses (127.x.x.x, ::1)
    /// - .local hostnames (Bonjour/mDNS)
    /// - Private IPv4 ranges (10.x.x.x, 172.16-31.x.x, 192.168.x.x)
    /// - Link-local addresses (169.254.x.x, fe80::)
    /// - IPv6 unique local addresses (fd00::/8)
    ///
    /// - Parameter host: The hostname or IP address to check
    /// - Returns: true if the host is local and doesn't need hole-punching
    static func isLocalDestination(_ host: String) -> Bool {
        let lowercased = host.lowercased()

        #if !CHINA_BUILD
        // In-app Tailscale carries it; there is no NAT to punch.
        if TailnetRouting.shared.wasRouted(host) {
            return true
        }
        #endif

        // Check for localhost variants
        if lowercased == "localhost" || lowercased == "localhost." {
            return true
        }

        // Check for .local hostnames (Bonjour/mDNS)
        if lowercased.hasSuffix(".local") || lowercased.hasSuffix(".local.") {
            return true
        }

        // Check for IPv6 loopback
        if host == "::1" || host == "[::1]" {
            return true
        }

        // Check for IPv6 link-local (fe80::)
        if lowercased.hasPrefix("fe80:") || lowercased.hasPrefix("[fe80:") {
            return true
        }

        // Check for IPv6 unique local addresses (fd00::/8)
        if lowercased.hasPrefix("fd") && (host.contains(":") || host.hasPrefix("[fd")) {
            // Verify it's actually an IPv6 address starting with fd
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if cleanHost.hasPrefix("fd") && cleanHost.contains(":") {
                return true
            }
        }

        // Check for IPv4 addresses
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let components = cleanHost.split(separator: ".")

        if components.count == 4,
           let first = Int(components[0]),
           let second = Int(components[1]) {

            // 127.x.x.x (loopback)
            if first == 127 {
                return true
            }

            // 10.x.x.x (private)
            if first == 10 {
                return true
            }

            // 172.16.x.x - 172.31.x.x (private)
            if first == 172 && (16...31).contains(second) {
                return true
            }

            // 192.168.x.x (private)
            if first == 192 && second == 168 {
                return true
            }

            // 169.254.x.x (link-local)
            if first == 169 && second == 254 {
                return true
            }
        }

        return false
    }
}

// MARK: - Auth banner card

extension MoshSession: SSHAuthBannerCardProviding {}

// MARK: - AdHocForwardingProviding

extension MoshSession: AdHocForwardingProviding {}
