//
//  TSSHGoTransport.swift
//  rootshell
//
//  Go-backed KCP/QUIC transport for trzsz-ssh
//  Uses the native Go implementation via gomobile bindings.
//
//  All Swift→Go calls are routed through `TSSHCallGate.shared`. This file does
//  not import `TrzszSSH` directly; it holds opaque `TSSHTransportRef` /
//  `TSSHSessionRef` handles vended by the gate.
//

import Foundation
import os
import OSLog

/// Delegate protocol for transport events
@MainActor
protocol TrzszGoTransportDelegate: AnyObject {
    func transport(_ transport: TrzszGoTransport, didChangeState state: TrzszGoTransport.State)
    func transportDidRefreshHealth(_ transport: TrzszGoTransport)
    /// tsshd's heartbeat checker transitioned: `true` = no alive ack within
    /// the heartbeat timeout, `false` = the heartbeat recovered. Pushed from
    /// Go, so the app learns of both edges without polling.
    func transport(_ transport: TrzszGoTransport, didChangeHealthTimeout isTimeout: Bool)
    /// Coalesced "data has arrived" notification for state side-effects only
    /// (e.g. clearing a network-loss marker). Bytes themselves are delivered
    /// off-main via `TrzszGoTransport.outputSink` — this hook fires at most
    /// once per main-actor turn no matter how many chunks landed.
    func transportDidReceiveData(_ transport: TrzszGoTransport)
    func transport(_ transport: TrzszGoTransport, didEncounterError error: Error)
    /// Called when the remote session exits (e.g., user types "exit")
    /// - Parameter exitCode: 0 for success, non-zero for error
    func transport(_ transport: TrzszGoTransport, didExitWithCode exitCode: Int)
    /// The server discarded buffered terminal OUTPUT on a lossy reconnect (counts
    /// only — `lines`/`bytes` dropped). A tmux -CC gateway uses this to drive a
    /// full surface reset + recapture. Fired only for output discards.
    func transport(_ transport: TrzszGoTransport, didDiscardOutputLines lines: Int, bytes: Int)
}

extension TrzszGoTransportDelegate {
    // Default no-op so non-gateway delegates need not implement it.
    func transport(_ transport: TrzszGoTransport, didDiscardOutputLines lines: Int, bytes: Int) {}
}

/// Go-backed KCP/QUIC transport
///
/// This transport uses the native Go trzsz-ssh implementation for KCP and QUIC
/// protocols, providing better compatibility and reliability than the Swift
/// implementations.
///
/// Usage:
/// 1. Swift side spawns tsshd via SSH (Citadel) and parses the JSON output
/// 2. Create TrzszGoTransport with the server info
/// 3. Call connect() to establish the transport
/// 4. Use the delegate for async callbacks
@MainActor
final class TrzszGoTransport: NSObject {

    // MARK: - Types

    /// Transport state
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(reason: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct ActivitySnapshot: Equatable, Sendable {
        let lastActiveMs: Int64
        let observedAtMs: Int64

        var secondsSinceActivity: Int {
            guard lastActiveMs > 0 else { return 0 }
            return max(0, Int((observedAtMs - lastActiveMs) / 1000))
        }

        var isTimeout: Bool {
            guard lastActiveMs > 0 else { return false }
            return (observedAtMs - lastActiveMs) > 3000
        }

        var estimatedRTTMs: Int? {
            let delta = Int(observedAtMs - lastActiveMs)
            return delta > 0 && delta < 5000 ? delta : nil
        }
    }

    // MARK: - Properties

    /// Delegate for receiving transport events
    weak var delegate: TrzszGoTransportDelegate?

    /// Strong ref to the Go→Swift discard notifier bridge (the Go side holds it
    /// weakly via gomobile), registered after connect. Kept for the transport's
    /// lifetime so server discard events keep reaching us.
    private var discardBridge: TrzszGoDiscardBridge?

    /// Strong ref to the Go→Swift heartbeat health bridge, registered after
    /// connect. Same lifetime rationale as `discardBridge`.
    private var healthBridge: TrzszGoHealthBridge?

    /// Current state
    private(set) var state: State = .disconnected {
        didSet {
            if state != oldValue {
                delegate?.transport(self, didChangeState: state)
            }
        }
    }

    /// Transport mode (KCP or QUIC)
    let mode: TrzszServerInfo.Mode

    /// Host address
    let host: String

    /// Port number
    let port: Int

    // Activity properties read from a `nonisolated` cache. Go health refreshes
    // happen on a background queue with at most one call in flight, so Swift
    // can consume returned heartbeat data without ever blocking on it.

    /// Estimated RTT in milliseconds (if available)
    nonisolated var estimatedRTTMs: Int? {
        let lastActive = activityCache.withLock { $0 }
        guard lastActive > 0 else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = Int(now - lastActive)
        return delta > 0 && delta < 5000 ? delta : nil
    }

    /// Whether the transport is currently in a timeout state (no activity for longer than heartbeat timeout)
    nonisolated var isTimeout: Bool {
        let lastActive = activityCache.withLock { $0 }
        guard lastActive > 0 else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Heartbeat timeout is 3 seconds (3000ms)
        return (now - lastActive) > 3000
    }

    /// Seconds since last activity (for banner display)
    nonisolated var secondsSinceLastActivity: Int {
        let lastActive = activityCache.withLock { $0 }
        guard lastActive > 0 else { return 0 }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return max(0, Int((now - lastActive) / 1000))
    }

    /// Cached activity timestamp in milliseconds since epoch. Updated from
    /// Swift-observed events such as connect, output, and queued input. Zero
    /// means "no value yet".
    private nonisolated let activityCache = OSAllocatedUnfairLock<Int64>(initialState: 0)

    /// Ensures health polling into Go is async and bounded. If a Go call stalls,
    /// this stays true and future polls are skipped instead of piling up.
    private nonisolated let healthPollInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Diagnostic-only probe for Go calls that can block behind the
    /// iosbridge session mutex during network disruption.
    private nonisolated let ioProbe = TrzszIOProbe()

    /// Thread-safe forwarder for output bytes. The Go callback bridge calls
    /// `outputSink.emit(data)` synchronously on the goroutine thread —
    /// matching `CitadelSSHSession`'s NIO-event-loop pattern — so byte
    /// delivery never hops to the main actor. The session re-binds the
    /// callbacks via `outputSink.update(...)` whenever its
    /// `onOutput`/`onOutputData` properties change.
    nonisolated let outputSink = OutputSink()

    /// Coalescing latch for `transportDidReceiveData(_:)`. The bridge fires
    /// `notifyDataArrived()` once per chunk; we collapse those into at most
    /// one main-actor delegate call per run-loop turn. Without this, a
    /// burst of N chunks would queue N main-actor Tasks — the resume-flood
    /// vector that previously buried the watchdog.
    private nonisolated let dataReceivedNotifyPending = OSAllocatedUnfairLock<Bool>(initialState: false)

    enum DeferredCallbackEvent: Sendable {
        case error(String)
        case exit(Int)
        case close
    }

    private nonisolated let backgroundedOutputBuffer = BoundedDataBuffer(capacity: 1024 * 1024)
    private nonisolated let deferredCallbackEvents = OSAllocatedUnfairLock<[DeferredCallbackEvent]>(initialState: [])
    private nonisolated static let foregroundReplayChunkBytes = 64 * 1024

    /// Lifecycle observability: tracks whether the previous emit was buffered
    /// (background) so we can log a single line on the first foreground emit
    /// after the gate flips. Used only for diagnostic logging — does not
    /// affect correctness.
    private nonisolated let lifecycleEmitWasBuffered = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Output-discard counts observed while backgrounded: tsshd discard events
    /// plus bytes `backgroundedOutputBuffer` dropped on overflow. Delivered as
    /// ONE delegate notification on the foreground drain, so the tmux -CC
    /// reset+recapture fires when the core can actually receive the capture
    /// replies — a reset issued while backgrounded bursts multi-pane
    /// capture-pane output straight into the bounded background buffer,
    /// overflowing it and manufacturing a second loss event mid-recapture.
    private nonisolated let pendingDiscard =
        OSAllocatedUnfairLock<(lines: Int, bytes: Int)>(initialState: (lines: 0, bytes: 0))

    private nonisolated func accumulatePendingDiscard(lines: Int, bytes: Int) {
        pendingDiscard.withLock {
            $0.lines += lines
            $0.bytes += bytes
        }
    }

    /// Deliver any backgrounded-accumulated output discard to the delegate as a
    /// single notification. Take-and-clear, so repeat calls are free. Called at
    /// the foreground drain points (before the buffered bytes are emitted, so
    /// the tmux reset's resync drops the known-gapped bytes as pre-marker
    /// noise) and before an immediate foreground discard delivery (so counts
    /// never split across two resets).
    func deliverPendingDiscardIfAny(foldingLines extraLines: Int = 0, bytes extraBytes: Int = 0) {
        let (lines, bytes) = pendingDiscard.withLock { state -> (Int, Int) in
            let taken = (state.lines + extraLines, state.bytes + extraBytes)
            state = (lines: 0, bytes: 0)
            return taken
        }
        guard lines > 0 || bytes > 0 else { return }
        delegate?.transport(self, didDiscardOutputLines: lines, bytes: bytes)
    }

    private func clearActivityCache() {
        activityCache.withLock { $0 = 0 }
    }

    nonisolated var activitySnapshot: ActivitySnapshot? {
        let lastActive = activityCache.withLock { $0 }
        guard lastActive > 0 else { return nil }
        return ActivitySnapshot(
            lastActiveMs: lastActive,
            observedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Marks the activity cache forward to "now" because we just observed
    /// proof that the remote is alive — server output landed, or a fresh
    /// connect/attach succeeded. Local writes (typing, resize) MUST NOT
    /// call this; they don't prove the remote is reachable, and stamping
    /// the cache forward from local activity would mask a real outage and
    /// suppress the timeout banner while the user keeps typing.
    nonisolated func markRemoteActivityObserved() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        activityCache.withLock { current in
            if now > current { current = now }
        }
    }

    @discardableResult
    func requestActivityRefresh() -> Bool {
        guard !Ghostty.isAppBackgroundedAtomic else { return false }
        guard let tRef = transportRef else { return false }

        let shouldStart = healthPollInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldStart else { return false }

        let cache = activityCache
        let inFlight = healthPollInFlight

        Task { [weak self, tRef] in
            let lastActive = await TSSHCallGate.shared.lastActiveTimeMs(tRef)
            // Monotonic: never regress past a more recent Swift-observed
            // activity stamp. Go's getLastActiveTime() can lag behind
            // markRemoteActivityObserved() during backlog drain; clobbering
            // the cache backwards makes the snapshot read isTimeout=true
            // momentarily, which flashes the roam banner.
            cache.withLock { current in
                if lastActive > current { current = lastActive }
            }
            inFlight.withLock { $0 = false }

            guard !Ghostty.isAppBackgroundedAtomic else { return }
            guard let self else { return }
            self.delegate?.transportDidRefreshHealth(self)
        }
        return true
    }

    /// Go→Swift: tsshd reported a discard on a lossy reconnect. We act ONLY on
    /// OUTPUT discards — the control stream lost bytes mid-block; input is kept
    /// for -CC so an input-only discard is just logged Go-side. While
    /// backgrounded the notification is accumulated and delivered at the
    /// foreground drain instead (see `pendingDiscard`); in foreground it hops
    /// to the main actor and forwards to the delegate (session → tmux
    /// controller reset).
    nonisolated func handleDiscardFromGoCallback(inputBytes: Int, outputLines: Int, outputBytes: Int) {
        guard outputLines > 0 || outputBytes > 0 else { return }
        if Ghostty.isAppBackgroundedAtomic {
            accumulatePendingDiscard(lines: outputLines, bytes: outputBytes)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check inside the Task: the atomic can flip between the
            // pre-schedule check and Task execution (same pattern as
            // deferGoCallbackEvent). Fold any pending counts into an immediate
            // delivery so one lossy episode never splits across two resets.
            if Ghostty.isAppBackgroundedAtomic {
                self.accumulatePendingDiscard(lines: outputLines, bytes: outputBytes)
                return
            }
            self.deliverPendingDiscardIfAny(foldingLines: outputLines, bytes: outputBytes)
        }
    }

    /// Go→Swift: tsshd's heartbeat checker entered or left the timeout state.
    /// On recovery the activity cache is stamped forward — the transition is
    /// proof the remote answered. While backgrounded the event is dropped;
    /// the foreground resume path calls `requestActivityRefresh()`, which
    /// reconciles from Go's authoritative state.
    nonisolated func handleHealthTransitionFromGoCallback(isTimeout: Bool, lastActiveMs: Int64) {
        if !isTimeout, lastActiveMs > 0 {
            activityCache.withLock { current in
                if lastActiveMs > current { current = lastActiveMs }
            }
        }
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        Task { @MainActor [weak self] in
            guard let self, !Ghostty.isAppBackgroundedAtomic else { return }
            self.delegate?.transport(self, didChangeHealthTimeout: isTimeout)
        }
    }

    nonisolated func emitOutputFromGoCallback(_ data: Data) {
        markRemoteActivityObserved()

        if Ghostty.isAppBackgroundedAtomic {
            let dropped = backgroundedOutputBuffer.append(data)
            if dropped > 0 {
                Self.logger.warning("tssh output buffer dropped \(dropped) oldest bytes while backgrounded")
                // Locally-dropped output is indistinguishable from a server-side
                // discard to the consumer: a -CC control stream now has a gap
                // only a full reset+recapture heals. Accumulate here (the drain
                // side reads the same counter — do not double-count there).
                accumulatePendingDiscard(lines: 0, bytes: dropped)
            }
            // Mark that we have buffered output; the next foreground emit
            // will log a single firstAfterGate line.
            lifecycleEmitWasBuffered.withLock { $0 = true }
            return
        }

        // A backgrounded discard is still awaiting delivery (the foreground
        // gate flips before the per-session flush loop reaches this session, so
        // a Go emit can land in that window). Emitting the buffered — gapped —
        // bytes now would let tmux parse a corrupted control stream before the
        // reset lands. Keep buffering behind a main-actor hop that delivers the
        // reset FIRST, then drains. The take-and-clear in delivery makes this
        // race-safe against the session's own flush points.
        let discardPending = pendingDiscard.withLock { $0.lines > 0 || $0.bytes > 0 }
        if discardPending {
            let dropped = backgroundedOutputBuffer.append(data)
            if dropped > 0 {
                Self.logger.warning("tssh output buffer dropped \(dropped) oldest bytes awaiting discard delivery")
                accumulatePendingDiscard(lines: 0, bytes: dropped)
            }
            lifecycleEmitWasBuffered.withLock { $0 = true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deliverPendingDiscardIfAny()
                self.flushBackgroundedOutput()
            }
            return
        }

        // First emit after the gate flips back to foreground — useful
        // signal for whether Go threads were firing during the dangerous
        // scene-update window.
        let wasBuffered = lifecycleEmitWasBuffered.withLock { state -> Bool in
            let prior = state
            state = false
            return prior
        }
        if wasBuffered {
            LifecycleDebugLogger.shared.checkpoint("Trzsz.emit.firstAfterGate", ms: nil, [
                ("bytes", data.count),
            ])
        }

        flushBackgroundedOutput()
        outputSink.emit(data)
        notifyDataArrived()
    }

    nonisolated func deferGoCallbackEvent(_ event: DeferredCallbackEvent) {
        // Buffer when backgrounded; the foreground hold flushes the queue
        // after the scene-update transaction has committed.
        if Ghostty.isAppBackgroundedAtomic {
            bufferDeferredCallbackEvent(event)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check inside the Task body. The atomic can flip between the
            // pre-schedule check and Task execution; without this re-check, an
            // event scheduled just before backgrounding will mutate
            // @Observable session state mid-scene-transition. Combined with
            // the body invalidations that mutation triggers across many
            // sessions, that contributes to FrontBoard scene-update wedges
            // (0x8BADF00D) on flaky-network tssh resumes.
            if Ghostty.isAppBackgroundedAtomic {
                self.bufferDeferredCallbackEvent(event)
                return
            }
            self.handleDeferredCallbackEvent(event)
        }
    }

    private nonisolated func bufferDeferredCallbackEvent(_ event: DeferredCallbackEvent) {
        deferredCallbackEvents.withLock {
            if $0.count >= 32 {
                $0.removeFirst()
            }
            $0.append(event)
        }
    }

    @discardableResult
    nonisolated func flushBackgroundedOutput(maxBytes: Int? = nil) -> Bool {
        let drained: (data: Data, droppedDuringBackground: Int, hasMore: Bool)?
        if let maxBytes {
            drained = backgroundedOutputBuffer.drain(maxBytes: maxBytes)
        } else {
            drained = backgroundedOutputBuffer.drain().map {
                (data: $0.data, droppedDuringBackground: $0.droppedDuringBackground, hasMore: false)
            }
        }
        guard let drained else { return false }
        // THE trzsz replay chokepoint: every backlog release funnels here —
        // the lifecycle drain, the session's own flush, and the first emit
        // after the gate flips (which is the only one that fires for a
        // shell-launched embedded session). Bells in a backlog are stale.
        if !drained.data.isEmpty, let terminalUUID {
            TerminalBellSuppressor.suppress(
                terminalUUID, for: TerminalBellSuppressor.forcedRedraw)
            // The backlog rewrites the screen, so agent detection must not
            // read what it classifies mid-replay as a new transition.
            TerminalBellSuppressor.suppressRebuild(terminalUUID)
        }
        if drained.droppedDuringBackground > 0 {
            Self.logger.warning("tssh output buffer dropped \(drained.droppedDuringBackground) bytes while backgrounded")
        }
        if !drained.data.isEmpty {
            outputSink.emit(drained.data)
            notifyDataArrived()
        }
        return drained.hasMore
    }

    @discardableResult
    nonisolated func flushBackgroundedOutputForForegroundReplay() -> Bool {
        flushBackgroundedOutput(maxBytes: Self.foregroundReplayChunkBytes)
    }

    func flushBackgroundedCallbacks() {
        // Reset-first: queue the tmux reset before emitting the buffered
        // (possibly gapped) bytes, so the resync drops them as pre-marker noise.
        deliverPendingDiscardIfAny()
        flushBackgroundedOutput()

        let events = deferredCallbackEvents.withLock { events -> [DeferredCallbackEvent] in
            let captured = events
            events.removeAll()
            return captured
        }
        for event in events {
            handleDeferredCallbackEvent(event)
        }
    }

    /// Whether the transport currently holds an active Go-side handle.
    /// Used by callers that previously checked `underlyingTransport != nil`.
    var hasUnderlyingTransport: Bool { transportRef != nil }

    /// Builds a port-forward manager bound to this transport's gate handle.
    /// Returns nil if the transport is not connected.
    func makePortForwardManager(
        config: PortForwardConfig,
        recoveringRemoteForwards: Set<UUID> = []
    ) -> TrzszPortForwardManager? {
        guard let ref = transportRef else { return nil }
        return TrzszPortForwardManager(
            transportRef: ref, config: config, recoveringRemoteForwards: recoveringRemoteForwards
        )
    }

    /// Debug label for this transport (e.g., "S1 user@host")
    let debugLabel: String

    // MARK: - Private

    /// App-lifetime session counter for debug labels
    private static var nextSessionNumber: Int = 1

    private var transportRef: TSSHTransportRef?
    private var sessionRef: TSSHSessionRef?

    /// Ordered send pipeline: `send()` yields into this stream and a single
    /// writer task performs the gomobile writes sequentially. One Task per
    /// send raced: TSSHCallGate runs writes on a CONCURRENT worker queue and
    /// Go's per-transport mutex has no FIFO fairness, so two in-flight sends
    /// could reach the wire out of order (tears large tmux -CC pastes, whose
    /// send-keys chunks ride this path). The writer reads `sessionRef` per
    /// item, so the pipeline survives reconnects; items sent while the ref is
    /// nil are dropped (matches the previous guard). The stream auto-finishes
    /// when the transport deallocates.
    private var sendStreamContinuation: AsyncStream<Data>.Continuation?
    private var sendWriterTask: Task<Void, Never>?
    private var cachedSessionID: UInt64?
    private let serverInfo: TrzszServerInfo
    let mtu: Int
    private let relayTransport: TrzszGoTransport?
    private var keepPendingInput: Bool
    /// Value the SERVER last accepted, so `applyKeepPendingInput` can skip
    /// redundant pushes and, crucially, RETRY a failed one. nil = never applied.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    private var appliedKeepPendingInput: Bool?
    private let keepPendingOutput: Bool
    private var callbackBridge: TrzszGoOutputBridge?

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszGoTransport"
    )

    // MARK: - Initialization

    /// Creates a new Go-backed transport
    /// - Parameters:
    ///   - host: Server hostname or IP
    ///   - port: Server port
    ///   - serverInfo: Parsed server info from tsshd JSON output
    ///   - mtu: Packet MTU override (0 = default 1400)
    ///   - displayName: Human-readable name for debug logs (e.g., "user@host")
    /// Host terminal, so the backlog flush below can mute that terminal's
    /// bells from any thread. `let` — read off the Go callback thread.
    private let terminalUUID: UUID?

    /// TERM requested for this session. Held for the transport's lifetime so a
    /// reattach asks for the same value the session was opened with, even if the
    /// user changed the setting in between.
    private let terminalType: String

    init(
        host: String,
        port: Int,
        serverInfo: TrzszServerInfo,
        mtu: Int = 0,
        keepPendingInput: Bool = false,
        keepPendingOutput: Bool = false,
        displayName: String = "",
        terminalUUID: UUID? = nil,
        terminalType: String = TerminalTypeSettings.fallback,
        relayTransport: TrzszGoTransport? = nil
    ) throws {
        let num = Self.nextSessionNumber
        Self.nextSessionNumber += 1
        self.debugLabel = displayName.isEmpty ? "S\(num)" : "S\(num) \(displayName)"
        self.host = host
        self.port = port
        self.serverInfo = serverInfo
        self.mode = serverInfo.mode
        self.mtu = mtu
        self.relayTransport = relayTransport
        self.keepPendingInput = keepPendingInput
        self.keepPendingOutput = keepPendingOutput
        self.terminalUUID = terminalUUID
        self.terminalType = terminalType

        super.init()
    }

    func effectiveRelayMTU(requested: Int, mode: String) async throws -> Int {
        guard let ref = activeTransportRef else { throw TrzszError.connectionFailed("Jump transport is unavailable") }
        return try await TSSHCallGate.shared.effectiveRelayMTU(ref, requested: requested, mode: mode)
    }

    // MARK: - Public API

    /// Connects to the tsshd server
    func connect() async throws {
        guard transportRef == nil else {
            throw TrzszError.connectionFailed( "Transport already connected")
        }

        state = .connecting
        Self.logger.info("[\(self.debugLabel)] Connecting Go transport to \(self.host):\(self.port) mode=\(self.mode.rawValue)")
        ResumeDebugLogger.shared.log("[\(debugLabel)] connect: host=\(self.host), port=\(self.port), mode=\(self.mode.rawValue)")

        // Wire Go tsshd debug output to file-based logger when enabled.
        let logger = ResumeDebugLogger.shared.isEnabled ? TrzszGoDebugLoggerBridge() : nil
        await TSSHCallGate.shared.setDebugLogger(logger)

        // Validate KCP credentials before handing off to the gate.
        if serverInfo.mode == .kcp {
            let passHex = serverInfo.kcpPass?.hexString ?? ""
            let saltHex = serverInfo.kcpSalt?.hexString ?? ""
            if passHex.isEmpty || saltHex.isEmpty {
                Self.logger.error("KCP Pass or Salt is empty!")
            }
        }

        let params = TSSHTransportParams(
            host: host,
            port: port,
            serverVersion: serverInfo.serverVersion,
            mode: serverInfo.mode.rawValue,
            // Use bitPattern to handle UInt64 values that exceed Int64.max
            clientID: Int64(bitPattern: serverInfo.clientId),
            serverID: Int64(bitPattern: serverInfo.serverId),
            mtu: mtu,
            proxyKeyHex: serverInfo.proxyKey?.hexString,
            kcpPassHex: serverInfo.mode == .kcp ? (serverInfo.kcpPass?.hexString ?? "") : nil,
            kcpSaltHex: serverInfo.mode == .kcp ? (serverInfo.kcpSalt?.hexString ?? "") : nil,
            serverCertHex: serverInfo.mode == .quic ? (serverInfo.serverCert?.hexString ?? "") : nil,
            clientCertHex: serverInfo.mode == .quic ? (serverInfo.clientCert?.hexString ?? "") : nil,
            clientKeyHex:  serverInfo.mode == .quic ? (serverInfo.clientKey?.hexString  ?? "") : nil,
            debugLabel: debugLabel
        )

        let ref: TSSHTransportRef
        do {
            let proxyRef = relayTransport?.activeTransportRef
            if relayTransport != nil && proxyRef == nil {
                throw TrzszError.connectionFailed("Jump transport is unavailable; direct fallback is disabled.")
            }
            ref = try await TSSHCallGate.shared.connect(params, via: proxyRef)
            self.transportRef = ref
        } catch {
            ResumeDebugLogger.shared.log("[\(debugLabel)] TSSH connect FAILED: \(error.localizedDescription)")
            throw TrzszError.connectionFailed("Failed to connect: \(error.localizedDescription)")
        }

        markRemoteActivityObserved()
        ResumeDebugLogger.shared.log("[\(debugLabel)] TSSH connect SUCCESS")

        try await TSSHCallGate.shared.setKeepPendingInput(on: ref, keep: keepPendingInput)
        // Baseline for applyKeepPendingInput's dedupe/retry. ROOTSHELL-TMUX
        // (id=tmux-keep-pending-rebind)
        appliedKeepPendingInput = keepPendingInput
        try await TSSHCallGate.shared.setKeepPendingOutput(on: ref, keep: keepPendingOutput)

        // Register the server-discard notifier: a lossy reconnect that dropped
        // buffered OUTPUT drives a tmux -CC surface reset + recapture. Held
        // strongly (the Go side keeps only a weak ref via gomobile).
        let discardBridge = TrzszGoDiscardBridge(transport: self)
        self.discardBridge = discardBridge
        try await TSSHCallGate.shared.setDiscardNotifier(on: ref, notifier: discardBridge)

        // Register the heartbeat health notifier: tsshd pushes timeout /
        // recovery transitions so the session never has to poll. Held
        // strongly for the same gomobile weak-ref reason as above.
        let healthBridge = TrzszGoHealthBridge(transport: self)
        self.healthBridge = healthBridge
        try await TSSHCallGate.shared.setHealthNotifier(on: ref, notifier: healthBridge)
        let label = debugLabel
        let keepPendingInputStatus = keepPendingInput ? "enabled" : "disabled"
        let keepPendingOutputStatus = keepPendingOutput ? "enabled" : "disabled"
        Self.logger.info("[\(label)] TSSH keep-pending input=\(keepPendingInputStatus) output=\(keepPendingOutputStatus)")
        ResumeDebugLogger.shared.log("[\(label)] TSSH keep-pending input=\(keepPendingInputStatus) output=\(keepPendingOutputStatus)")

        state = .connected
        Self.logger.info("Go transport connected")
    }

    /// Set keep-pending-input to `desired` on the live transport. `desired` is the
    /// session's whole intent (user setting + live `tmux -CC` gateway + auto-start
    /// config), so this both applies the control-mode override and restores the
    /// configured behaviour once the gateway ends — one direction can never be
    /// lost behind the other. Callers serialise their pushes.
    ///
    /// `appliedKeepPendingInput` records what the SERVER last accepted and is
    /// committed only after the call succeeds: caching the desired value up front
    /// would make a failed push look applied, so every later attempt would
    /// early-return while the server stayed on the old value.
    /// ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
    /// - Returns: `true` when the server is known to be on `desired` (or the value
    ///   is safely deferred to `connect()`); `false` when the push FAILED and the
    ///   caller should retry.
    @discardableResult
    func applyKeepPendingInput(_ desired: Bool) async -> Bool {
        // Sticky intent: `connect()` applies this to any transport built later.
        keepPendingInput = desired
        guard let ref = transportRef else {
            ResumeDebugLogger.shared.log(
                "[\(debugLabel)] keep-pending-input=\(desired) deferred (no transport yet)")
            return true
        }
        guard appliedKeepPendingInput != desired else { return true }
        do {
            try await TSSHCallGate.shared.setKeepPendingInput(on: ref, keep: desired)
            appliedKeepPendingInput = desired
            let status = desired ? "enabled" : "disabled"
            Self.logger.info("[\(self.debugLabel)] TSSH keep-pending-input → \(status)")
            ResumeDebugLogger.shared.log("[\(debugLabel)] TSSH keep-pending-input → \(status)")
            return true
        } catch {
            // Leave `appliedKeepPendingInput` alone so the retry re-attempts.
            let message = error.localizedDescription
            Self.logger.error("[\(self.debugLabel)] TSSH keep-pending-input set failed: \(message)")
            ResumeDebugLogger.shared.log("[\(debugLabel)] TSSH keep-pending-input set FAILED: \(message)")
            return false
        }
    }

    /// Creates a new Go-side session for Shell/Start.
    /// Called by openSessionStream() before requesting PTY + shell.
    private func createSession() async throws {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport available")
        }
        let bridge = TrzszGoOutputBridge(transport: self)
        do {
            let sRef = try await TSSHCallGate.shared.newSession(on: tRef, output: bridge)
            self.sessionRef = sRef
            self.callbackBridge = bridge
        } catch {
            throw TrzszError.connectionFailed("Failed to create session: \(error.localizedDescription)")
        }
    }

    /// Enables SSH agent forwarding through the gate.
    func enableAgentForwardingAsync(callback: TrzszAgentBridge) async throws {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport for agent forwarding")
        }
        try await TSSHCallGate.shared.enableAgentForwarding(on: tRef, callback: callback)
        Self.logger.info("Agent forwarding enabled on transport")
    }

    /// Enables GPG-style Unix-socket forwarding through the gate.
    /// The bridge's `transportRef` must match this transport — callers
    /// build the bridge using ``activeTransportRef`` below.
    func enableStreamLocalForwardingAsync(
        remotePath: String,
        callback: TrzszStreamLocalBridge
    ) async throws {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport for streamlocal forwarding")
        }
        try await TSSHCallGate.shared.enableStreamLocalForwarding(
            on: tRef,
            remotePath: remotePath,
            callback: callback
        )
        Self.logger.info("Stream-local forwarding enabled on transport (\(remotePath))")
    }

    /// Tear down a previously enabled stream-local forward.
    func disableStreamLocalForwardingAsync(remotePath: String) async {
        guard let tRef = transportRef else { return }
        try? await TSSHCallGate.shared.disableStreamLocalForwarding(
            on: tRef,
            remotePath: remotePath
        )
    }

    /// The current transport ref, exposed so the GPG bridge can hold
    /// it for subsequent stream-local read/write/close calls. Nil if
    /// the transport hasn't connected yet (or has been torn down).
    var activeTransportRef: TSSHTransportRef? { transportRef }

    /// Run a one-shot command on the remote and return its combined
    /// stdout+stderr bytes. Thin wrapper around
    /// ``TSSHCallGate/runRemoteCommand(on:command:)`` for the
    /// GPG-forwarding probe.
    func runRemoteCommand(_ command: String) async throws -> Data {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport for runRemoteCommand")
        }
        return try await TSSHCallGate.shared.runRemoteCommand(on: tRef, command: command)
    }

    /// Start a long-lived command in an auxiliary session on this transport
    /// and return a byte pipe over its stdin/stdout. The channel survives
    /// roaming with the transport and dies with it.
    func openExecChannel(_ command: String) async throws -> AsyncBytePipe {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport for openExecChannel")
        }
        let channelRef = try await TSSHCallGate.shared.openExec(on: tRef, command: command)
        return TrzszExecPipe(channelRef: channelRef, transportRef: tRef)
    }

    /// Opens a session stream with PTY
    /// - Parameters:
    ///   - cols: Terminal columns
    ///   - rows: Terminal rows
    ///   - execCommand: If non-nil, send an exec request with this command instead of a shell request
    ///   - agentEnabled: If true, request agent forwarding before starting the shell
    func openSessionStream(cols: Int, rows: Int, execCommand: String? = nil, agentEnabled: Bool = false) async throws {
        // Create session if not already created (was previously done in connect())
        if sessionRef == nil {
            try await createSession()
        }
        guard let sRef = sessionRef else {
            throw TrzszError.connectionFailed( "No session available")
        }
        ResumeDebugLogger.shared.log("[\(debugLabel)] openSessionStream: cols=\(cols), rows=\(rows)")

        // Respect the user's locale forwarding mode, matching SSH and Mosh.
        let locale = LocaleHelper.effectiveLocale
        let preferredLanguages = LocaleHelper.effectivePreferredLanguages

        let openedSessionID: UInt64
        do {
            let id = try await TSSHCallGate.shared.openShellOrCommand(
                on: sRef,
                lang: locale,
                languages: preferredLanguages,
                agentForwarding: agentEnabled,
                term: terminalType,
                rows: rows,
                cols: cols,
                execCommand: execCommand,
                // Lets an out-of-band probe identify this pane's remote
                // process. Without it tssh forwarded no pane token at all, so
                // a tssh pane outside tmux could never resolve a directory.
                // (id=agent-project)
                paneToken: terminalUUID?.uuidString
            )
            openedSessionID = UInt64(bitPattern: id)
        } catch {
            throw TrzszError.connectionFailed("Failed to open session: \(error.localizedDescription)")
        }
        cachedSessionID = openedSessionID

        let localeDescription = locale ?? "not forwarded"
        if let execCommand {
            Self.logger.info("Session stream opened with exec command, LANG=\(localeDescription) (cmd=\(execCommand))")
        } else {
            Self.logger.info("Session stream opened with shell, LANG=\(localeDescription)")
        }
    }

    /// The session ID assigned by the server after Shell/Start.
    /// Must be saved for future Attach() calls after app restart.
    var sessionID: UInt64? {
        cachedSessionID
    }

    /// Attaches to an existing server-side session by ID.
    /// Use this to resume a session after app restart instead of openSessionStream().
    func attachToSession(sessionID: UInt64, cols: Int, rows: Int) async throws {
        guard let tRef = transportRef else {
            throw TrzszError.connectionFailed("No transport available for attach")
        }

        ResumeDebugLogger.shared.log("[\(debugLabel)] attachToSession: sessionID=\(sessionID), cols=\(cols), rows=\(rows)")

        // Capture (but don't yet release) any prior session ref — if attach
        // throws, we want disconnect() / abandon() to still find and clean
        // up the original session. We only discard it after the new attach
        // has succeeded.
        let priorSession = sessionRef

        let bridge = TrzszGoOutputBridge(transport: self)
        let result: (ref: TSSHSessionRef, sessionID: Int64)
        do {
            result = try await TSSHCallGate.shared.attachSession(
                on: tRef,
                sessionID: Int64(bitPattern: sessionID),
                term: terminalType,
                rows: rows,
                cols: cols,
                output: bridge
            )
        } catch {
            throw TrzszError.connectionFailed(
                "Failed to attach to session \(sessionID): \(error.localizedDescription)"
            )
        }

        // Attach succeeded — swap the session ref over and drop the prior
        // one (if any). discardSession does not invoke Go-side Close: the
        // server-side session is what we just reattached to, so the prior
        // Swift handle is just stale registry state.
        self.sessionRef = result.ref
        self.cachedSessionID = UInt64(bitPattern: result.sessionID)
        self.callbackBridge = bridge

        if let priorSession {
            await TSSHCallGate.shared.discardSession(priorSession)
        }

        // A successful attach is itself proof of remote liveness — the
        // server accepted our session reattach. Stamp the activity cache
        // so the first health refresh after resume doesn't compute a
        // false timeout against the older connect() timestamp (resume
        // also fires resize jiggles, but those no longer stamp activity).
        markRemoteActivityObserved()

        state = .connected
        Self.logger.info("Attached to session \(sessionID)")
    }

    /// Sends data to the remote server
    /// - Parameter data: Data to send
    /// Routes through the gate so all Go writes serialize behind the same FIFO.
    func send(_ data: Data) {
        guard sessionRef != nil else {
            Self.logger.error("Cannot send: no session")
            return
        }

        // Do not stamp the activity cache here — local sends do not prove
        // the remote received the bytes. Server output (or a Go health-poll
        // refresh) is the only signal that updates "last remote activity."

        ensureSendPipeline()
        sendStreamContinuation?.yield(data)
    }

    /// Lazily start the single ordered writer — see `sendStreamContinuation`.
    private func ensureSendPipeline() {
        guard sendWriterTask == nil else { return }

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        sendStreamContinuation = continuation
        sendWriterTask = Task { [weak self] in
            for await data in stream {
                guard let self, let sRef = self.sessionRef else { continue }
                let probe = self.ioProbe
                let byteCount = data.count
                let probeID = probe.begin(kind: "send", label: self.debugLabel, [
                    ("bytes", byteCount),
                ])
                probe.scheduleStallCheck(id: probeID, thresholdSeconds: 2.0)
                do {
                    try await TSSHCallGate.shared.write(sRef, data)
                    probe.end(id: probeID)
                } catch {
                    probe.end(id: probeID, error: error.localizedDescription)
                    Self.logger.error("Failed to send data: \(error.localizedDescription)")
                    self.delegate?.transport(self, didEncounterError: error)
                }
            }
        }
    }

    /// Resizes the terminal
    /// - Parameters:
    ///   - cols: New column count
    ///   - rows: New row count
    /// Routes through the gate so resizes serialize behind any in-flight write.
    func resize(cols: Int, rows: Int) {
        guard let sRef = sessionRef else {
            Self.logger.warning("Cannot resize: no session")
            return
        }

        // Local layout change — does not prove remote liveness, so don't
        // stamp the activity cache here.

        let probe = ioProbe
        let label = debugLabel
        Task { [sRef] in
            let probeID = probe.begin(kind: "resize", label: label, [
                ("cols", cols),
                ("rows", rows),
            ])
            probe.scheduleStallCheck(id: probeID, thresholdSeconds: 2.0)
            do {
                try await TSSHCallGate.shared.resize(sRef, rows: rows, cols: cols)
                probe.end(id: probeID)
            } catch {
                probe.end(id: probeID, error: error.localizedDescription)
                Self.logger.error("Failed to resize: \(error.localizedDescription)")
            }
        }
    }

    /// Silently abandons the transport without sending "close" to the server.
    /// Use when preserving the server session for future Attach() after app restart.
    /// Routes through the gate's emergency-teardown path so a wedged write
    /// can't prevent the abandon from reaching Go.
    func abandon() {
        Self.logger.info("Abandoning Go transport (preserving server session)")

        let priorTransport = transportRef
        let priorSession = sessionRef

        clearActivityCache()
        sessionRef = nil
        transportRef = nil
        cachedSessionID = nil
        callbackBridge = nil
        state = .disconnected

        // Drop the session ref synchronously (no Go call) and forcefully
        // abandon the transport via the emergency path. Both bypass the
        // gate's serial executor, so a wedged write/resize can't block them.
        if let priorSession {
            TSSHCallGate.shared.discardSessionImmediate(priorSession)
        }
        if let priorTransport {
            TSSHCallGate.shared.emergencyAbandon(priorTransport)
        }
    }

    /// Disconnects the transport.
    /// Attempts a graceful close through the gate, with a short emergency-
    /// abandon fallback so a wedged write/resize cannot keep the Go transport
    /// alive after the user has asked to disconnect.
    func disconnect() {
        Self.logger.info("Disconnecting Go transport")

        let priorSession = sessionRef
        let priorTransport = transportRef

        clearActivityCache()
        sessionRef = nil
        transportRef = nil
        cachedSessionID = nil
        callbackBridge = nil
        state = .disconnected

        // Graceful close path through the gate (sends "close" to server).
        // If the gate is wedged, this Task may never complete; the fallback
        // below ensures the transport still gets torn down.
        Task {
            if let priorSession {
                do {
                    try await TSSHCallGate.shared.close(priorSession)
                } catch {
                    Self.logger.error("Error closing session: \(error.localizedDescription)")
                }
            }
            if let priorTransport {
                do {
                    try await TSSHCallGate.shared.close(priorTransport)
                } catch {
                    Self.logger.error("Error closing transport: \(error.localizedDescription)")
                }
            }
        }

        // Liveness fallback: if the graceful close hasn't drained the
        // registry within 5 s, force-abandon. emergencyAbandon is idempotent;
        // if graceful close already removed the entry, this is a no-op.
        if let priorTransport {
            Task {
                try? await Task.sleep(for: .seconds(5))
                TSSHCallGate.shared.emergencyAbandon(priorTransport)
            }
        }
    }

    // MARK: - Callback Handling

    /// Called after foreground output delivery. This only schedules a
    /// coalesced main-actor delegate call so the session can react to "data
    /// arrived" without paying a per-chunk Task hop.
    nonisolated func notifyDataArrived() {
        markRemoteActivityObserved()
        guard !Ghostty.isAppBackgroundedAtomic else { return }

        let shouldSpawn = dataReceivedNotifyPending.withLock { pending -> Bool in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard shouldSpawn else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Clear *before* delegate call so a chunk arriving during the
            // delegate work re-arms the next coalesced notification.
            self.dataReceivedNotifyPending.withLock { $0 = false }
            self.delegate?.transportDidReceiveData(self)
        }
    }

    private func handleDeferredCallbackEvent(_ event: DeferredCallbackEvent) {
        switch event {
        case .error(let message):
            handleError(message)
        case .exit(let exitCode):
            handleExit(exitCode)
        case .close:
            handleClose()
        }
    }

    fileprivate func handleError(_ message: String) {
        Self.logger.error("Transport error (output loop exited): \(message)")
        // Note: This means the Go output forwarding loop has exited.
        // Even if UDP reconnects, we won't receive output anymore.
        // The session may still accept input but output is dead.
        state = .failed(reason: message)
        delegate?.transport(self, didEncounterError: TrzszError.transportDisconnected(reason: message))
    }

    fileprivate func handleExit(_ exitCode: Int) {
        if exitCode == 0 {
            Self.logger.info("Session exited gracefully")
        } else {
            Self.logger.info("Session exited with code \(exitCode)")
        }
        state = .disconnected
        delegate?.transport(self, didExitWithCode: exitCode)
    }

    fileprivate func handleClose() {
        Self.logger.info("Transport session closed")
        state = .disconnected
    }
}

// MARK: - TSSH IO Probe

private nonisolated final class TrzszIOProbe: Sendable {
    private struct Operation: Sendable {
        let kind: String
        let label: String
        let startedAt: TimeInterval
        let detail: String
    }

    private struct State: Sendable {
        var nextID: UInt64 = 0
        var inFlight: [UInt64: Operation] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func begin(kind: String, label: String, _ kv: [(String, Any)] = []) -> UInt64 {
        let detail = kv.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let snapshot = state.withLock { state -> (id: UInt64, inFlight: Int) in
            state.nextID &+= 1
            let id = state.nextID
            state.inFlight[id] = Operation(
                kind: kind,
                label: label,
                startedAt: Date().timeIntervalSinceReferenceDate,
                detail: detail
            )
            return (id, state.inFlight.count)
        }

        if snapshot.inFlight >= 4 {
            WedgeBreadcrumbLogger.shared.critical("tssh.io.inflightHigh", [
                ("kind", kind),
                ("label", label),
                ("id", snapshot.id),
                ("inFlight", snapshot.inFlight),
                ("detail", detail),
            ])
        }

        return snapshot.id
    }

    func scheduleStallCheck(id: UInt64, thresholdSeconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + thresholdSeconds) { [self] in
            guard let snapshot = state.withLock({ state -> (Operation, Int)? in
                guard let op = state.inFlight[id] else { return nil }
                return (op, state.inFlight.count)
            }) else {
                return
            }

            let elapsedMs = (Date().timeIntervalSinceReferenceDate - snapshot.0.startedAt) * 1000
            WedgeBreadcrumbLogger.shared.critical("tssh.io.stalled", [
                ("kind", snapshot.0.kind),
                ("label", snapshot.0.label),
                ("id", id),
                ("ms", String(format: "%.2f", elapsedMs)),
                ("inFlight", snapshot.1),
                ("detail", snapshot.0.detail),
            ])
        }
    }

    func end(id: UInt64, error: String? = nil) {
        let endedAt = Date().timeIntervalSinceReferenceDate
        guard let snapshot = state.withLock({ state -> (Operation, Int)? in
            guard let op = state.inFlight.removeValue(forKey: id) else { return nil }
            return (op, state.inFlight.count)
        }) else {
            return
        }

        let elapsedMs = (endedAt - snapshot.0.startedAt) * 1000
        guard elapsedMs >= 500 || error != nil else { return }

        var fields: [(String, Any)] = [
            ("kind", snapshot.0.kind),
            ("label", snapshot.0.label),
            ("id", id),
            ("ms", String(format: "%.2f", elapsedMs)),
            ("inFlight", snapshot.1),
            ("detail", snapshot.0.detail),
        ]
        if let error {
            fields.append(("error", error))
        }
        WedgeBreadcrumbLogger.shared.critical("tssh.io.complete", fields)
    }
}

// MARK: - Data Extension

private extension Data {
    /// Convert Data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
