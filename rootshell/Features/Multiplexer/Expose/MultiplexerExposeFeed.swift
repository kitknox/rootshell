//
//  MultiplexerExposeFeed.swift
//  rootshell
//

import Foundation
import GhosttyKit
import QuartzCore
import os

@MainActor
final class MultiplexerExposeFeed: MuxPreviewFrameSource {
    enum State: Equatable {
        case idle
        case detecting
        case loading
        case live
        case unsupported
        case failed
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "MuxExpose")

    private(set) var state: State = .idle
    private(set) var snapshot: MuxExposeSnapshot?
    private(set) var type: MultiplexerType?
    private(set) var sessionName: String?
    var onChange: (() -> Void)?

    private(set) weak var terminal: Ghostty.TerminalView?
    var ghosttyApp: Ghostty.App? { terminal?.ghosttyApp }

    private var adapter: (any MultiplexerExposeAdapter)?
    /// Pane the current `adapter` was built for; see `configure(_:)`.
    private var adapterPaneToken: String?
    private var frames: [String: MuxPaneFrame] = [:]
    private var loop: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var visiblePanes: Set<String> = []
    private var lastFetchAt: [String: CFTimeInterval] = [:]
    private var hints: [String: String] = [:]
    /// Negative detection is cached across short exposé lifetimes.
    private var negativeDetectAt: [ObjectIdentifier: CFTimeInterval] = [:]
    private var generation: UInt64 = 0
    private var focusGeneration: UInt64 = 0
    /// Distinguishes authoritative absence from probe failures.
    private var detectionWasConclusive = false
    /// Cached zmx bindings are revalidated before serving their cached page.
    private var validatingZmxBinding = false
    private var tickCount = 0
    private var interval: TimeInterval = baseInterval
    private var failures = 0
    private var fetchCap = Int.max
    private var cleanTicks = 0
    private var cache: (owner: ObjectIdentifier, session: String, snapshot: MuxExposeSnapshot,
                        frames: [String: MuxPaneFrame], at: CFTimeInterval)?

    private static let baseInterval: TimeInterval = 0.4
    private static let maxInterval: TimeInterval = 2.5
    private static let hiddenPaneEveryNthTick = 3
    private static let staleAfter: CFTimeInterval = 2
    private static let cacheLifetime: CFTimeInterval = 60
    private static let maxPreviewPanesPerTab = 6
    private static let responseCap = 512 * 1024
    private static let tickTimeout: TimeInterval = 5
    private static let negativeProbeCooldown: CFTimeInterval = 4
    private static let focusAttempts = 12
    private static let focusMaxResponseBytes = 32 * 1024
    private static let failuresBeforeUnavailable = 3

    // MARK: - Identity

    var sessionKey: String { "\(type?.rawValue ?? "-"):\(sessionName ?? "")" }

    var tabs: [MuxTab] { snapshot?.tabs ?? [] }

    var tabUUIDs: [UUID] { tabs.map { $0.uuid(sessionKey: sessionKey) } }

    var activeTabUUID: UUID? {
        snapshot?.activeTabID.flatMap { id in snapshot?.tab(withID: id) }?.uuid(sessionKey: sessionKey)
    }

    func tab(uuid: UUID) -> MuxTab? {
        tabs.first { $0.uuid(sessionKey: sessionKey) == uuid }
    }

    func frame(for paneID: String) -> MuxPaneFrame? { frames[paneID] }

    var isServing: Bool { state == .loading || state == .live || state == .failed }

    var title: String {
        let mux: String
        switch type {
        case .tmux: mux = "tmux"
        case .zellij: mux = "zellij"
        case .herdr: mux = "herdr"
        case .zmx: mux = "zmx"
        case nil: mux = ""
        }
        if let sessionName, !sessionName.isEmpty { return "\(mux) · \(sessionName)" }
        return mux
    }

    // MARK: - Eligibility

    /// Returns the active multiplexer binding, preferring the raw slot.
    static func binding(for terminal: Ghostty.TerminalView?) -> Ghostty.TerminalView.RawMultiplexerBinding? {
        guard let terminal, canDetect(terminal) else { return nil }
        if let binding = terminal.rawMultiplexer, adapter(for: binding.type) != nil,
           binding.hasOwnedAltScreen || isAlternateScreenActive(terminal) {
            return binding
        }
        if let binding = terminal.passthroughMultiplexer, adapter(for: binding.type) != nil {
            return binding
        }
        return nil
    }

    /// Returns the adapter for a supported multiplexer type.
    /// `paneToken` is what lets a zmx switch act on this pane's own client;
    /// callers testing only whether a type is supported can leave it out.
    static func adapter(
        for type: MultiplexerType,
        paneToken: String? = nil
    ) -> (any MultiplexerExposeAdapter)? {
        switch type {
        case .herdr: HerdrExposeAdapter()
        case .tmux: TmuxExposeAdapter()
        case .zellij: ZellijExposeAdapter()
        case .zmx: ZmxExposeAdapter(paneToken: paneToken)
        }
    }

    /// A pane can be probed even when no binding has been recorded yet.
    static func canDetect(_ terminal: Ghostty.TerminalView) -> Bool {
        // Projected panes are already native tabs. Their synthetic local
        // session has no TTY to probe, so process discovery can find our own
        // herdr bridge and incorrectly replace native selection with CLI focus.
        !terminal.isMultiplexerPane && terminal.herdrController == nil && terminal.tmuxController == nil
            && RemoteExecProbe.canProbe(terminal)
    }

    private static func isAlternateScreenActive(_ terminal: Ghostty.TerminalView) -> Bool {
        guard let surface = terminal.surface else { return false }
        var altActive = false
        guard ghostty_surface_try_is_alternate_active(surface, &altActive) else { return false }
        return altActive
    }

    private static func localTTY(_ terminal: Ghostty.TerminalView) -> String? {
        #if targetEnvironment(macCatalyst)
        guard terminal.connectionConfig.underlyingSSHConfig == nil,
              let path = terminal.session?.pty.slavePath, path.hasPrefix("/dev/") else { return nil }
        return String(path.dropFirst("/dev/".count))
        #else
        return nil
        #endif
    }

    // MARK: - Lifecycle

    /// Begin (or resume) serving `terminal`'s session. Returns false when the
    /// terminal has no usable multiplexer binding and nothing to detect.
    @discardableResult
    func start(terminal: Ghostty.TerminalView) -> Bool {
        guard Self.canDetect(terminal) else {
            Self.logger.debug("not eligible for raw multiplexer exposé")
            cancelFocus()
            stopNow()
            return false
        }
        let binding = Self.binding(for: terminal)
        Self.logger.debug("start: \(binding?.type.rawValue ?? "detect", privacy: .public)")
        stopTask?.cancel()
        stopTask = nil
        validatingZmxBinding = false
        // A zmx passthrough can be detached while the feed is in its short
        // stop grace period. Its terminal binding is intentionally retained
        // until a successful listing proves what happened, but a cached live
        // feed must not make the next reveal bypass that validation.
        let requiresZmxValidation = binding?.type == .zmx
        if loop != nil, self.terminal === terminal,
           !requiresZmxValidation,
           binding == nil || (type == binding?.type && sessionName == binding?.sessionName) {
            // Re-opened inside the stop grace: the running feed still serves
            // this session, so its tabs and frames are already current.
            Self.logger.debug("reusing live feed: \(self.tabs.count) tabs, \(self.frames.count) frames")
            return true
        }
        cancelFocus()
        teardownLoop()

        self.terminal = terminal
        resetSession()
        if let binding {
            if binding.type == .zmx {
                // A cached zmx binding must be confirmed after a detach.
                configure(binding)
                validatingZmxBinding = true
                state = .detecting
                negativeDetectAt.removeValue(forKey: ObjectIdentifier(terminal))
            } else {
                configure(binding)
            }
        } else {
            type = nil
            sessionName = nil
            adapter = nil
            adapterPaneToken = nil
            state = .detecting
        }
        onChange?()
        let generation = self.generation
        loop = Task { [weak self] in await self?.run(generation: generation) }
        return true
    }

    /// Fast end of the pacing range for the adapter in hand.
    private var floorInterval: TimeInterval {
        max(Self.baseInterval, adapter?.minInterval ?? 0)
    }

    private func resetSession() {
        frames = [:]
        snapshot = nil
        hints = [:]
        lastHints = [:]
        lastFetchAt = [:]
        visiblePanes = []
        tickCount = 0
        failures = 0
        fetchCap = Int.max
        cleanTicks = 0
        interval = Self.baseInterval
    }

    private func configure(_ binding: Ghostty.TerminalView.RawMultiplexerBinding) {
        // The adapter carries the pane's own token, which a zmx switch uses to
        // pick this pane's client out of the session's others. One feed serves
        // every pane in the window, so an adapter held across a change of pane
        // would go looking for the previous pane's processes: identity belongs
        // in the test alongside the multiplexer type.
        let paneToken = terminal?.uuid.uuidString
        let sameMultiplexer = type == binding.type && adapter != nil
            && adapterPaneToken == paneToken
        type = binding.type
        sessionName = binding.sessionName
        if !sameMultiplexer {
            adapter = Self.adapter(for: binding.type, paneToken: paneToken)
            adapterPaneToken = paneToken
        }
        interval = floorInterval
        if let terminal, let cache, cache.owner == ObjectIdentifier(terminal),
           cache.session == "\(binding.type.rawValue):\(binding.sessionName ?? "")",
           CACurrentMediaTime() - cache.at < Self.cacheLifetime {
            snapshot = cache.snapshot
            frames = cache.frames
            state = .live
        } else {
            state = .loading
        }
    }

    /// Stop after `grace` seconds unless restarted; the picture is cached.
    func stop(grace: TimeInterval) {
        guard loop != nil else { return }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.stopNow()
        }
    }

    func stopNow() {
        stopTask?.cancel()
        stopTask = nil
        if let terminal, let snapshot, let type {
            cache = (ObjectIdentifier(terminal), "\(type.rawValue):\(sessionName ?? "")", snapshot, frames, CACurrentMediaTime())
        }
        teardownLoop()
        state = .idle
        snapshot = nil
        frames = [:]
        onChange?()
    }

    private func teardownLoop() {
        // Invalidates any work already in flight for the previous run.
        generation &+= 1
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
    }

    private func cancelFocus() {
        focusTask?.cancel()
        focusTask = nil
        focusGeneration &+= 1
    }

    /// Panes on screen right now; they are fetched first and every tick.
    func setVisiblePanes(_ ids: Set<String>) {
        guard ids != visiblePanes else { return }
        let newcomers = ids.subtracting(visiblePanes)
        visiblePanes = ids
        // A cell that scrolled in with no picture yet should not wait a whole interval.
        if newcomers.contains(where: { frames[$0] == nil }) { wake() }
    }

    /// Switch the multiplexer to `tabID`. Independent of the tick loop so it
    /// still runs while the exposé is already dismissing.
    func focus(tabID: String) {
        guard let terminal, let adapter else { return }
        let session = sessionName
        cancelFocus()
        let focusRun = focusGeneration

        // Avoid resetting terminal state when the selected tab is already active.
        guard session != tabID else { return }

        // Use the pane's own PTY when a shell is known to be available below zmx.
        if type == .zmx, let sourceBinding = terminal.passthroughMultiplexer,
           sourceBinding.canDetachSwitch,
           let session, !session.isEmpty, session != tabID {
            guard let zmxAdapter = adapter as? ZmxExposeAdapter,
                  let sourceClients = zmxAdapter.clientCount(for: session),
                  let targetClients = zmxAdapter.clientCount(for: tabID)
            else {
                Self.logger.warning("detach focus has no client census; leaving the pane untouched")
                return
            }
            prepareForPassthroughSwitch(terminal)
            performZmxDetachSwitch(
                terminal: terminal,
                session: session,
                tabID: tabID,
                sourceClients: sourceClients,
                targetClients: targetClients,
                sourceBinding: sourceBinding,
                focusRun: focusRun
            )
            return
        }

        guard adapter.canFocus(session: session, tabID: tabID) else {
            Self.logger.info("focus declined by the adapter; leaving the pane where it is")
            return
        }
        let script = adapter.focusScript(session: session, tabID: tabID)
        prepareForPassthroughSwitch(terminal)
        focusTask = Task { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            for attempt in 0..<Self.focusAttempts {
                guard !Task.isCancelled, self.focusGeneration == focusRun,
                      self.terminal === terminal else { return }
                do {
                    let output = try await RemoteExecProbe.run(
                        script, on: terminal, timeout: 4, maxResponseBytes: Self.focusMaxResponseBytes
                    )
                    // Trust the binding only after the adapter confirms the switch.
                    guard adapter.parseFocusResult(output: output, session: session, tabID: tabID) else {
                        Self.logger.warning("focus did not confirm the switch landed; leaving the current session name alone")
                        return
                    }
                    guard !Task.isCancelled, self.focusGeneration == focusRun,
                          self.terminal === terminal else { return }
                    self.notePassthroughFocus(tabID: tabID)
                    self.wake()
                    return
                } catch RemoteExecProbe.ProbeError.busy {
                    try? await Task.sleep(for: .milliseconds(250))
                    if attempt == Self.focusAttempts - 1 { Self.logger.warning("focus abandoned: transport busy") }
                } catch {
                    Self.logger.warning("focus failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    /// Delay after detach so the remote pty can finish its cleanup.
    private static let zmxDetachSettleDelay: TimeInterval = 0.4
    private static let zmxDetachConfirmationDelay: TimeInterval = 0.35
    private static let zmxDetachSwitchAttempts = 3
    private static let zmxDetachCensusScript = MuxScript.wrap(
        "echo \"::SESSIONS::\"; ZMX_SESSION= zmx list 2>/dev/null",
        nonce: "detach-census"
    )

    /// Move a detachable zmx pane by typing into its own PTY.
    private func performZmxDetachSwitch(
        terminal: Ghostty.TerminalView,
        session: String,
        tabID: String,
        sourceClients: Int,
        targetClients: Int,
        sourceBinding: Ghostty.TerminalView.RawMultiplexerBinding,
        focusRun: UInt64
    ) {
        // Seed the title before typing so an echoed command cannot win the race.
        let originalTitle = terminal.title
        if terminal.userOverrideTitle == nil {
            terminal.title = tabID
        }
        let inputLine = terminal.zmxAttachInputLine(sessionName: tabID)
        focusTask = Task { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            @MainActor func isCurrentFocus() -> Bool {
                !Task.isCancelled && self.focusGeneration == focusRun
                    && self.terminal === terminal
                    && terminal.passthroughMultiplexer == sourceBinding
            }
            var confirmed = false
            defer {
                if !confirmed, self.focusGeneration == focusRun {
                    terminal.titleSuppressedUntil = nil
                    terminal.pendingCommandEcho = nil
                    if terminal.userOverrideTitle == nil, terminal.title == tabID {
                        terminal.title = originalTitle
                    }
                }
            }
            var needsDetach = true
            switchAttempts: for attempt in 0..<Self.zmxDetachSwitchAttempts {
                guard isCurrentFocus() else { return }
                if needsDetach {
                    terminal.sendUserInput(Data([0x1C]))
                    try? await Task.sleep(for: .seconds(Self.zmxDetachSettleDelay))
                    guard isCurrentFocus() else { return }
                }

                terminal.pendingCommandEcho = (
                    command: inputLine.trimmingCharacters(in: .whitespacesAndNewlines),
                    until: Date().addingTimeInterval(Ghostty.TerminalView.commandEchoTitleWindow)
                )
                terminal.titleSuppressedUntil = Date()
                    .addingTimeInterval(Self.zmxDetachSettleDelay + 1)
                if let data = inputLine.data(using: .utf8) {
                    guard isCurrentFocus() else { return }
                    terminal.sendUserInput(data)
                }
                terminal.titleSuppressedUntil = nil

                try? await Task.sleep(for: .seconds(Self.zmxDetachConfirmationDelay))
                guard isCurrentFocus() else { return }
                guard let counts = await self.fetchZmxDetachCensus(on: terminal),
                      let sourceAfter = counts[session],
                      let targetAfter = counts[tabID]
                else {
                    Self.logger.warning("detach focus could not read its confirmation census")
                    break
                }

                switch MuxZmxDetachTransfer.classify(
                    sourceBefore: sourceClients,
                    targetBefore: targetClients,
                    sourceAfter: sourceAfter,
                    targetAfter: targetAfter
                ) {
                case .confirmed:
                    guard isCurrentFocus() else { return }
                    confirmed = true
                    self.notePassthroughFocus(tabID: tabID)
                    self.wake()
                    return
                case .unchanged:
                    needsDetach = true
                case .detachedOnly:
                    needsDetach = false
                case .ambiguous:
                    Self.logger.warning("detach focus census changed ambiguously; refusing to type again")
                    break switchAttempts
                }
                if attempt < Self.zmxDetachSwitchAttempts - 1 { continue }
            }

            Self.logger.warning("detach focus did not confirm after retries; leaving the binding unchanged")
        }
    }

    private func fetchZmxDetachCensus(on terminal: Ghostty.TerminalView) async -> [String: Int]? {
        for attempt in 0..<Self.focusAttempts {
            do {
                let output = try await RemoteExecProbe.run(
                    Self.zmxDetachCensusScript,
                    on: terminal,
                    timeout: 4,
                    maxResponseBytes: Self.focusMaxResponseBytes
                )
                let sessions = ZmxDiscoveryParser.parse(output: output)
                return sessions.reduce(into: [:]) { counts, info in
                    if let clients = info.clientCount { counts[info.name] = clients }
                }
            } catch RemoteExecProbe.ProbeError.busy {
                try? await Task.sleep(for: .milliseconds(250))
                if attempt == Self.focusAttempts - 1 {
                    Self.logger.warning("detach focus confirmation abandoned: transport busy")
                }
            } catch {
                Self.logger.warning("detach focus confirmation failed: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }

    private func wake() {
        sleeper?.cancel()
    }

    /// Clears mouse tracking before a passthrough switch.
    private func prepareForPassthroughSwitch(_ terminal: Ghostty.TerminalView) {
        guard type == .zmx else { return }
        terminal.surfaceOutputPipeline.writeDirect(Self.mouseTrackingReset)
    }

    /// DECRST for every mouse tracking mode and every extended encoding, so
    /// the reset holds whichever the departing program had selected.
    private static let mouseTrackingReset =
        "\u{1B}[?1000l\u{1B}[?1001l\u{1B}[?1002l\u{1B}[?1003l"
        + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l"

    private func notePassthroughFocus(tabID: String) {
        guard let terminal, let type, !type.ownsAlternateScreen else { return }
        let canDetachSwitch = terminal.passthroughMultiplexer?.canDetachSwitch ?? false
        terminal.passthroughMultiplexer = .init(type: type, sessionName: tabID, canDetachSwitch: canDetachSwitch)

        // Seed the title because zmx may not replay one for a new session.
        guard sessionName != tabID else { return }
        if terminal.userOverrideTitle == nil {
            terminal.title = tabID
        }
    }

    // MARK: - Loop

    /// Work started by a superseded run must never touch the feed again: its
    /// answers describe a session this feed no longer serves, and its
    /// teardown would stop the run that replaced it. Every await in the loop
    /// is followed by this check before anything shared is read or written.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func clearCurrentPassthroughBinding() {
        guard type == .zmx,
              let terminal,
              terminal.passthroughMultiplexer?.type == .zmx,
              terminal.passthroughMultiplexer?.sessionName == sessionName
        else { return }
        terminal.passthroughMultiplexer = nil
    }

    private func giveUp(_ reason: String) {
        Self.logger.debug("\(reason, privacy: .public)")
        state = .unsupported
        loop = nil
        onChange?()
    }

    private enum DetectOutcome {
        case superseded
        case nothingAttached
        case configured
    }

    /// Probe the pane, adopt what it is really attached to, and write that
    /// identity back to the terminal. Shared with the cached-binding fallback.
    private func detectAndConfigure(generation: UInt64) async -> DetectOutcome {
        let detected = await detect()
        guard isCurrent(generation) else {
            Self.logger.debug("detect superseded by a newer run")
            return .superseded
        }
        guard let detected else { return .nothingAttached }
        Self.logger.debug("detected \(detected.type.rawValue, privacy: .public), session named=\(detected.sessionName != nil)")
        let identityChanged = type != detected.type || sessionName != detected.sessionName
        if identityChanged { resetSession() }
        configure(detected)
        if let terminal, !detected.type.ownsAlternateScreen, let name = detected.sessionName {
            // Process inspection cannot distinguish an interactive attach
            // from an exec takeover, but the connection configuration can.
            let canDetachSwitch = terminal.connectionConfig.sshConfigForHistory
                .map { !$0.hasExecTakeoverCommand } ?? true
            if terminal.passthroughMultiplexer?.type == detected.type {
                // Validation may discover that an in-place/session change
                // updated the socket-backed name while the old slot was
                // cached. Refresh the exact identity before serving it.
                terminal.passthroughMultiplexer = .init(
                    type: detected.type,
                    sessionName: name,
                    canDetachSwitch: canDetachSwitch
                )
            } else {
                terminal.bindPassthroughMultiplexer(detected.type, sessionName: name, canDetachSwitch: canDetachSwitch)
            }
        }
        onChange?()
        return .configured
    }

    private func run(generation: UInt64) async {
        var skippedDetectForCachedBinding = false
        if validatingZmxBinding, adapter != nil, sessionName != nil {
            // The cached name is already known, so detect()'s only job here
            // is revalidation. `tickScript` runs `zmx list` every tick and
            // `parseTick` already treats it as authoritative for liveness
            // (`boundSessionIsUnavailable`), so the first tick can prove that
            // instead, saving a round trip.
            validatingZmxBinding = false
            skippedDetectForCachedBinding = true
        } else if adapter == nil || validatingZmxBinding {
            validatingZmxBinding = false
            switch await detectAndConfigure(generation: generation) {
            case .superseded:
                return
            case .nothingAttached:
                if detectionWasConclusive { clearCurrentPassthroughBinding() }
                giveUp("detect: nothing attached on this tty")
                return
            case .configured:
                break
            }
        }
        if sessionName == nil {
            let resolved = await resolveSession()
            guard isCurrent(generation) else { return }
            guard let resolved else {
                giveUp("resolveSession: no single session")
                return
            }
            sessionName = resolved
            onChange?()
        }
        while true {
            let outcome = await tick(generation: generation)
            guard isCurrent(generation) else { return }
            switch outcome {
            case .cancelled:
                return
            case .unsupported:
                giveUp("tick: session no longer usable")
                return
            case .boundSessionGone:
                // The listing says which sessions exist, not which owns this
                // pane's tty, so a rejected name is not proof the pane is
                // empty. When this run skipped detect(), pay it now. Only on
                // the first tick: later rejections are real mid-life detaches.
                guard skippedDetectForCachedBinding, tickCount == 0 else {
                    giveUp("tick: session no longer usable")
                    return
                }
                skippedDetectForCachedBinding = false
                Self.logger.debug("cached binding rejected by first tick; falling back to detect")
                switch await detectAndConfigure(generation: generation) {
                case .superseded:
                    return
                case .nothingAttached:
                    giveUp("detect after rejected binding: nothing attached on this tty")
                    return
                case .configured:
                    continue
                }
            case .immediate:
                continue
            case .wait(let seconds):
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
                self.sleeper = sleeper
                await sleeper.value
                guard isCurrent(generation) else { return }
            }
        }
    }

    /// Which multiplexer is attached in this pane, and to which session.
    ///
    /// A pane the app did not start has no binding to read, so the host is
    /// asked. Locally the pane's own tty names the process directly. Over a
    /// connection there is no tty to name, so candidates are found by
    /// command and narrowed by ancestry: this exec channel and the pane's
    /// shell descend from the same sshd/tsshd, exactly as the project probe
    /// identifies a pane's process. (id=mux-expose-detect)
    ///
    /// Candidates are then narrowed a second way, by screen state, but only
    /// for the types it speaks to: one that OWNS the alternate screen must be
    /// found on an alternate screen, so a raw `tmux ls` typed at a bare prompt
    /// is not mistaken for an attach. A passthrough is exempt -- its pane
    /// shows whatever runs inside the session, primary or alternate -- and is
    /// tied to this pane by its session socket and by ancestry instead.
    /// (id=zmx-passthrough-detect)
    private func detect() async -> Ghostty.TerminalView.RawMultiplexerBinding? {
        guard let terminal else { return nil }
        detectionWasConclusive = false
        let altActive = Self.isAlternateScreenActive(terminal)
        if !altActive, let last = negativeDetectAt[ObjectIdentifier(terminal)],
           CACurrentMediaTime() - last < Self.negativeProbeCooldown {
            return nil
        }
        // Scoped to the alt-inactive branch only: tmux/zellij/herdr were
        // never gated by `canDetect` this way, so their probe cadence stays
        // untouched.
        func fail(conclusive: Bool = false) -> Ghostty.TerminalView.RawMultiplexerBinding? {
            if conclusive { detectionWasConclusive = true }
            if !altActive {
                let now = CACurrentMediaTime()
                negativeDetectAt = negativeDetectAt.filter { now - $0.value < Self.negativeProbeCooldown * 8 }
                negativeDetectAt[ObjectIdentifier(terminal)] = now
            }
            return nil
        }
        let tty = Self.localTTY(terminal)
        let nonce = Self.nonce()
        // Candidate multiplexer clients: on this tty locally, ours anywhere
        // otherwise. `grep` only narrows; the command name is checked here.
        let candidates = tty.map { "ps -t \(MuxScript.dq($0)) -o pid=,ppid=,tty=,args= 2>/dev/null" }
            ?? "ps -xo pid=,ppid=,tty=,args= 2>/dev/null | grep -E \"tmux|herdr|zellij|zmx\" | grep -v grep"
        let candidatePIDs = "$(\(candidates) | awk \"{print \\$1}\")"
        // Ancestor walks, so a candidate can be tied to THIS connection.
        let walk = "_q=$1; while [ -n \"$_q\" ] && [ \"$_q\" -gt 1 ] 2>/dev/null;"
            + " do echo \"$_q\"; _q=$(ps -o ppid= -p \"$_q\" 2>/dev/null | tr -d \" \"); done"

        var body = "_walk() { \(walk); }"
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce)))"
        body += "; \(candidates)"
        body += "; echo \"::MX_SELF::\"; _walk $$"
        // OpenSSH gives every channel on one transport the same connection
        // tuple. Keep it as a fallback for servers whose process tree does
        // not leave the interactive and exec channels under a shared sshd.
        body += "; echo \"::MX_CONNECTION::\"; printf \"%s\\n\" \"${SSH_CONNECTION-}\""
        body += "; echo \"::MX_CHAINS::\"; for _p in \(candidatePIDs); do echo \"::MX_PID:$_p::\"; _walk \"$_p\"; done"
        body += "; echo \"::MX_CLIENTS::\""
        body += "; tmux list-clients -F \"#{client_tty}\(TmuxExposeAdapter.separator)#{session_name}\" 2>/dev/null"
        // A name is often absent from argv: `zellij` alone joins a
        // server-named session and herdr's default is implicit. The client
        // holds its session's socket open, which names it. Two ways to read
        // that: `lsof` (macOS), and /proc — where a connected client socket
        // has no path of its own, so its inode is matched in /proc/net/unix.
        // Linux servers routinely lack lsof, and a client socket there
        // usually has no name in it even when installed.
        body += "; echo \"::MX_SOCKETS::\"; for _p in \(candidatePIDs); do echo \"::MX_PID:$_p::\";"
        body += " for _s in \"$_p\" $(ps -xo pid=,ppid= 2>/dev/null | awk -v p=\"$_p\" \"\\$2==p {print \\$1}\"); do"
        body += " lsof -a -p \"$_s\" -U -F n 2>/dev/null;"
        body += " if [ -d \"/proc/$_s/fd\" ]; then"
        body += " for _i in $(ls -l \"/proc/$_s/fd\" 2>/dev/null"
        body += " | sed -n \"s/.*socket:\\[\\([0-9][0-9]*\\)\\].*/\\1/p\"); do"
        body += " awk -v i=\"$_i\" \"\\$7==i && \\$8 ~ /^\\// {print \\$8}\" /proc/net/unix 2>/dev/null;"
        body += " done; fi; done; done"
        // Exported by the user's own shell where it was used (`HERDR_SESSION=x herdr`).
        //
        // `/proc` gives one NUL-separated variable per line. macOS has none, so
        // `ps -E` stands in: it appends the environment to the argument line,
        // flattened on spaces. A value containing a space cannot be recovered
        // from that, which is why SSH_CONNECTION is read from `/proc` alone --
        // absent, its readers fall back to other evidence, where a value
        // truncated at the first space would instead never match anything.
        // One scan is taken, narrowed to lines that carry a variable worth
        // having, and re-read per candidate from the pid each line starts
        // with, rather than spawning a `ps` for every candidate.
        let envKeys = "HERDR_SESSION|HERDR_SOCKET_PATH|ZELLIJ_SESSION_NAME|ZMX_SESSION_PREFIX"
            + "|\(TerminalIdentity.paneTokenVariable)"
        body += "; echo \"::MX_ENV::\""
        body += "; _mxenv=\"\"; [ -r /proc/self/environ ]"
        body += " || _mxenv=$(ps -xEo pid=,command= 2>/dev/null | grep -E \" (\(envKeys))=\")"
        body += "; for _p in \(candidatePIDs); do echo \"::MX_PID:$_p::\";"
        body += " if [ -r \"/proc/$_p/environ\" ]; then"
        body += " tr \"\\0\" \"\\n\" < \"/proc/$_p/environ\" 2>/dev/null"
        body += " | grep -E \"^(\(envKeys)|SSH_CONNECTION)=\";"
        body += " else"
        body += " printf \"%s\\n\" \"$_mxenv\" | awk -v p=\"$_p\" \"\\$1==p\""
        body += " | tr \" \" \"\\n\" | grep -E \"^(\(envKeys))=\";"
        body += " fi; done"
        // zellij's server runs as `zellij --server <sock dir>/<session>`.
        body += "; echo \"::MX_SERVERS::\"; ps -xo pid=,ppid=,args= 2>/dev/null | grep -- \"--server\" | grep -v grep"

        guard let output = try? await RemoteExecProbe.run(
            MuxScript.wrap(body, nonce: nonce), on: terminal,
            timeout: Self.tickTimeout, maxResponseBytes: 64 * 1024
        ) else {
            Self.logger.debug("detect: probe failed")
            return fail()
        }
        let parts = ["::MX_SELF::", "::MX_CONNECTION::", "::MX_CHAINS::", "::MX_CLIENTS::", "::MX_SOCKETS::", "::MX_ENV::", "::MX_SERVERS::"]
            .reduce([MuxScript.sections(of: output, nonce: nonce).topology]) { sections, marker in
                sections.flatMap { $0.components(separatedBy: marker) }
            }
        guard parts.count >= 8 else {
            Self.logger.debug("detect: unexpected reply, \(output.count) bytes")
            return fail()
        }
        let ownChain = Set(parts[1].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let ownSSHConnection = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let chains = Self.pidSections(parts[3]).mapValues { Set($0) }
        let clients = parts[4]
        let sockets = Self.pidSections(parts[5])
        let environments = Self.pidSections(parts[6]).mapValues { Self.environment($0) }
        let servers = parts[7]

        var found: [(binding: Ghostty.TerminalView.RawMultiplexerBinding, pid: String, tty: String)] = []
        for line in parts[0].split(separator: "\n") {
            var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 4 else { continue }
            let pid = words.removeFirst()
            words.removeFirst()                       // ppid
            let processTTY = words.removeFirst()
            guard let command = words.first?.split(separator: "/").last.map(String.init) else { continue }
            func value(after flags: [String]) -> String? {
                for (index, word) in words.enumerated() where flags.contains(word) && index + 1 < words.count {
                    return words[index + 1]
                }
                return nil
            }
            let binding: Ghostty.TerminalView.RawMultiplexerBinding
            // A multiplexer's own server process carries the same binary
            // name as its client and is a descendant of the client that
            // spawned it, so it would otherwise pass every test below and
            // double the candidates for a single session.
            if words.contains("--server") || words.dropFirst().first == "server" { continue }

            switch command {
            case "tmux":
                // Control mode is the app's own projection, not a raw attach.
                if words.contains("-CC") { continue }
                let wanted = "/dev/\(tty ?? processTTY)"
                let session = clients.split(separator: "\n").lazy
                    .map { $0.components(separatedBy: TmuxExposeAdapter.separator) }
                    .first { $0.count == 2 && ($0[0] == wanted || $0[0].hasSuffix("/\(processTTY)")) }?[1]
                binding = .init(type: .tmux, sessionName: session, hasOwnedAltScreen: true)
            case "herdr":
                let environment = environments[pid] ?? [:]
                var session = value(after: ["--session", "-s"])
                if session == nil, let index = words.firstIndex(of: "attach"), index > 0, index + 1 < words.count,
                   words[index - 1] == "session" {
                    session = words[index + 1]
                }
                session = session ?? environment["HERDR_SESSION"]
                    ?? Self.herdrSession(in: sockets[pid] ?? [])
                    ?? environment["HERDR_SOCKET_PATH"].flatMap { Self.herdrSession(in: [$0]) }
                binding = .init(type: .herdr, sessionName: session ?? "default", hasOwnedAltScreen: true)
            case "zellij":
                var session = value(after: ["--session", "-s"])
                if session == nil, let index = words.firstIndex(where: { $0 == "attach" || $0 == "a" }),
                   index + 1 < words.count, !words[index + 1].hasPrefix("-") {
                    session = words[index + 1]
                }
                session = session ?? (environments[pid] ?? [:])["ZELLIJ_SESSION_NAME"]
                    ?? Self.zellijSession(in: sockets[pid] ?? [])
                    ?? Self.zellijSession(servers: servers, clientPID: pid)
                binding = .init(type: .zellij, sessionName: session, hasOwnedAltScreen: true)
            case "zmx":
                // `zmx run` owns a detached session but is not a client
                // attached to this pane. It may share the pane's SSH
                // connection when it was launched from the same shell, so
                // exclude it before applying connection correlation below.
                if let subcommand = words.dropFirst().first,
                   subcommand == "run" || subcommand == "r" {
                    continue
                }
                // `switchSesh` (main.zig) recurses into `attach()` in the SAME
                // process without ever re-exec'ing, so argv keeps naming
                // whatever session this pane FIRST attached to, forever,
                // through any number of later switches. The session's actual
                // daemon -- forked, not exec'd, at attach and at every switch
                // -- holds the live named socket instead, so it is asked
                // first; argv is only a fallback for the moment before that
                // fork's socket shows up here, or a host with neither `lsof`
                // nor `/proc`.
                var session = Self.zmxSession(in: sockets[pid] ?? [])
                if session == nil, let argument = Self.zmxAttachArgument(in: words) {
                    // The socket is named for the session; argv is named for
                    // what the user typed. zmx resolves one to the other by
                    // prepending `ZMX_SESSION_PREFIX` (`getSeshName`,
                    // socket.zig), and the census lists resolved names, so a
                    // pane bound to the typed name matches nothing there and
                    // reads as a session that has gone away.
                    session = ((environments[pid] ?? [:])["ZMX_SESSION_PREFIX"] ?? "") + argument
                }
                // Nothing to focus or to key the exposé's tab identity by
                // without a name, and guessing one would risk moving a
                // session this pane is not actually in -- same reasoning as
                // the configured-binding decline in
                // `applyConfiguredMultiplexerBinding`.
                guard let session else { continue }
                binding = .init(type: .zmx, sessionName: session, hasOwnedAltScreen: false)
            default:
                continue
            }
            found.append((binding, pid, processTTY))
        }
        // Raw multiplexers own the alternate screen for the attach. zmx is a
        // passthrough, so its inner application alone determines screen state.
        found = found.filter {
            MuxScreenGate.admits(
                ownsAlternateScreen: $0.binding.type.ownsAlternateScreen,
                alternateScreenActive: altActive
            )
        }
        guard !found.isEmpty else { return fail(conclusive: true) }
        // On the pane's own tty there is nothing to disambiguate.
        if tty != nil { return found[0].binding }
        // Prefer the per-pane token Rootshel forwards with the interactive
        // channel. Several terminal channels may share one SSH transport, so
        // their processes also share the sshd ancestry and SSH_CONNECTION
        // tuple; neither identifies WHICH pane owns a client. Servers that do
        // not accept LC_* variables fall back to those coarser signals.
        let paneToken = terminal.uuid.uuidString
        let paneRelated = found.filter {
            environments[$0.pid]?[TerminalIdentity.paneTokenVariable] == paneToken
        }

        // Otherwise keep only what shares this connection's sshd or exact
        // SSH_CONNECTION tuple, and give up unless they all agree on a single
        // binding: showing another
        // session's tabs, or focusing one, is worse than falling back to the
        // app tabs. Plain agreement (not just a lone survivor) is the bar
        // because of zmx: unlike tmux/zellij/herdr, whose client process IS
        // the thing that ends up attached, zmx FORKS its session daemon as a
        // child of the attaching client -- at attach and at every later
        // switch -- rather than ever exec'ing into it. So one hand-typed
        // `zmx a foo1` in a pane yields TWO candidates above that both share
        // `ownChain` (the fork is a descendant of the client): the client
        // itself and its forked daemon. Both resolve the same socket via
        // `zmxSession(in:)` and so carry an identical binding -- that is
        // corroboration, not ambiguity, and collapsing agreeing candidates
        // before counting is what tells the two apart. (id=zmx-fork-collapse)
        let related = paneRelated.isEmpty ? found.filter {
            if !(chains[$0.pid] ?? []).intersection(ownChain).isEmpty { return true }
            guard !ownSSHConnection.isEmpty else { return false }
            return environments[$0.pid]?["SSH_CONNECTION"] == ownSSHConnection
        } : paneRelated
        guard !related.isEmpty else {
            // The probe completed, but no candidate belongs to this
            // connection: authoritative absence for a cached zmx binding.
            return fail(conclusive: true)
        }
        guard let winner = Self.collapseAgreeingBindings(related.map(\.binding)) else {
            Self.logger.debug("detect: \(found.count) candidates, \(related.count) on this connection; not guessing")
            return fail()
        }
        return winner
    }

    /// Reduces a list of binding candidates that share this connection down
    /// to a single agreed-upon binding, or `nil` when the list is empty or
    /// the candidates genuinely disagree. Generic over the candidate's own
    /// equality rather than named against
    /// `Ghostty.TerminalView.RawMultiplexerBinding` directly, keeping this
    /// reduction independent of the transport-specific binding type.
    /// (id=zmx-fork-collapse)
    static func collapseAgreeingBindings<Binding: Equatable>(_ candidates: [Binding]) -> Binding? {
        guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Lines grouped by the `::MX_PID:<pid>::` markers the script emits.
    /// `lsof -F` prefixes paths with `n`, which is stripped here.
    private static func pidSections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var pid: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("::MX_PID:"), line.hasSuffix("::") {
                pid = String(line.dropFirst("::MX_PID:".count).dropLast(2))
            } else if let pid {
                let value = line.hasPrefix("n") ? String(line.dropFirst()) : String(line)
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result[pid, default: []].append(trimmed) }
            }
        }
        return result
    }

    /// `NAME=value` lines into a dictionary; a value may contain `=`.
    private static func environment(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let split = line.firstIndex(of: "="), split > line.startIndex else { continue }
            let value = String(line[line.index(after: split)...])
            guard !value.isEmpty else { continue }
            result[String(line[..<split])] = value
        }
        return result
    }

    /// zellij's client socket is `<sock dir>/<session name>`.
    private static func zellijSession(in paths: [String]) -> String? {
        for path in paths where path.contains("zellij") {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, name != "web_server_bus", !name.hasPrefix("zellij") else { continue }
            return name
        }
        return nil
    }

    /// zellij's server is `zellij --server <sock dir>/<session name>`, and
    /// the client that created a session is its parent. With one server there
    /// is no ambiguity; with several, only the client's own child answers
    /// (attaching by name already carries the name in argv).
    private static func zellijSession(servers: String, clientPID: String) -> String? {
        var names: [(ppid: String, name: String)] = []
        for line in servers.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 4, words.contains("--server"),
                  let index = words.firstIndex(of: "--server"), index + 1 < words.count,
                  words[2].split(separator: "/").last.map(String.init)?.hasPrefix("zellij") == true else { continue }
            let path = words[index + 1]
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            names.append((words[1], name))
        }
        if let own = names.first(where: { $0.ppid == clientPID }) { return own.name }
        return names.count == 1 ? names[0].name : nil
    }

    /// herdr's client socket is `<config>/herdr-client.sock` for the default
    /// session and `<config>/sessions/<name>/herdr-client.sock` for a named one.
    private static func herdrSession(in paths: [String]) -> String? {
        for path in paths where (path as NSString).lastPathComponent.hasPrefix("herdr") {
            let directory = (path as NSString).deletingLastPathComponent
            let parent = ((directory as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if parent == "sessions" {
                return (directory as NSString).lastPathComponent
            }
            return "default"
        }
        return nil
    }

    /// Returns the most-referenced zmx session socket. A stable tie-break keeps
    /// the client and its forked daemon aligned for candidate correlation.
    private static func zmxSession(in paths: [String]) -> String? {
        var hits: [String: Int] = [:]
        for path in paths where path.hasPrefix("/") {
            let directory = (path as NSString).deletingLastPathComponent
            let dirName = (directory as NSString).lastPathComponent
            guard dirName == "zmx" || dirName.hasPrefix("zmx-") else { continue }
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            hits[name, default: 0] += 1
        }
        guard let highest = hits.values.max() else { return nil }
        return hits.filter { $0.value == highest }.keys.sorted().first
    }

    /// The session `zmx attach` was pointed at, as typed. Mirrors zmx's own
    /// `parseAttachArgs`: flags are recognized only ahead of the name, and
    /// everything past it is the command the session should run.
    private static func zmxAttachArgument(in words: [String]) -> String? {
        guard let start = words.firstIndex(where: { $0 == "attach" || $0 == "a" }) else { return nil }
        var index = words.index(after: start)
        while index < words.count {
            let word = words[index]
            if word == "--labels" {
                index += 2
                if Self.holdsAnotherLabel(words, at: index) { return nil }
            } else if word.hasPrefix("--labels=") {
                index += 1
                if Self.holdsAnotherLabel(words, at: index) { return nil }
            } else if word.hasPrefix("-") {
                return nil
            } else {
                return word
            }
        }
        return nil
    }

    /// Whether the word at `index` is a second label rather than the session
    /// name, which means the name cannot be recovered at all.
    ///
    /// `ps` output has already lost the shell's quoting, so the single word
    /// `--labels "project=x env=prod"` arrives split exactly like a one-word
    /// label followed by a session called `env=prod`. Nothing distinguishes
    /// them. An unknown name leaves the feed to other evidence; a wrong one
    /// binds the pane to a session that does not exist, and the feed shuts
    /// down on a pane that is still attached.
    private static func holdsAnotherLabel(_ words: [String], at index: Int) -> Bool {
        guard index < words.count else { return false }
        let word = words[index]
        guard !word.hasPrefix("-"), let equals = word.firstIndex(of: "=") else { return false }
        return equals != word.startIndex
    }

    /// The session name when the host runs exactly one; nil leaves the feed
    /// unusable rather than guessing (the caller applies the result).
    private func resolveSession() async -> String? {
        guard let terminal, let adapter else { return nil }
        let nonce = Self.nonce()
        guard let output = try? await RemoteExecProbe.run(
            adapter.resolveSessionScript(nonce: nonce), on: terminal, timeout: Self.tickTimeout, maxResponseBytes: 16 * 1024
        ) else { return nil }
        let names = MuxScript.sections(of: output, nonce: nonce).topology
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count == 1 else { return nil }
        return names[0]
    }

    private enum Outcome {
        /// This run was superseded while awaiting: touch nothing, just stop.
        case cancelled
        case unsupported
        /// The bound name is no longer attached here. Narrower than
        /// `unsupported`, and recoverable -- see `run(generation:)`.
        case boundSessionGone
        case immediate
        case wait(TimeInterval)
    }

    private func tick(generation: UInt64) async -> Outcome {
        guard let terminal, let adapter else { return .unsupported }
        let now = CACurrentMediaTime()
        let fetch = MuxZmxBootstrap.seededFetch(
            normallyComputed: fetchList(now: now), snapshot: snapshot, type: type, sessionName: sessionName
        )
        let request = MuxTickRequest(fetch: fetch, knownRevisions: frames.mapValues(\.revision))
        let nonce = Self.nonce()
        let script = adapter.tickScript(session: sessionName, request: request, nonce: nonce)
        let output: String
        do {
            output = try await RemoteExecProbe.run(script, on: terminal, timeout: Self.tickTimeout, maxResponseBytes: Self.responseCap)
        } catch RemoteExecProbe.ProbeError.busy {
            return isCurrent(generation) ? .wait(0.3) : .cancelled
        } catch {
            guard isCurrent(generation) else { return .cancelled }
            return failed("tick: \(error.localizedDescription)")
        }
        // The reply describes the session this run was started for; a newer
        // run may already own the feed's frames and snapshot.
        guard isCurrent(generation) else { return .cancelled }
        guard let result = adapter.parseTick(output: output, session: sessionName, nonce: nonce) else {
            // Only the prelude's own verdict is final. Anything else (a
            // half-written reply, a momentarily unavailable server) is a
            // transient failure worth retrying, and never throws away a
            // session that has already been serving.
            if MuxScript.sections(of: output, nonce: nonce).unsupported {
                Self.logger.debug("multiplexer reports unsupported")
                return .unsupported
            }
            if type == .zmx,
               !MuxScript.sections(of: output, nonce: nonce).truncated,
               let zmx = adapter as? ZmxExposeAdapter,
               let sessionName,
               zmx.boundSessionIsUnavailable(sessionName) {
                Self.logger.debug("zmx bound session is no longer attached")
                clearCurrentPassthroughBinding()
                return .boundSessionGone
            }
            Self.logger.debug("tick: unparseable reply, \(output.count) bytes")
            if snapshot == nil, failures >= 2 { return .unsupported }
            return failed("tick: unparseable")
        }
        tickCount += 1
        if tickCount == 1 {
            Self.logger.debug("first tick: \(result.snapshot.tabs.count) tabs, \(result.snapshot.allPanes.count) panes")
        }
        failures = 0
        hints.merge(result.changeHints) { _, new in new }
        let fetched = Set(request.fetch)

        var changed = false
        for (id, frame) in result.frames {
            // A capture of nothing at all is a failed read, not a blank
            // screen (a cleared pane still returns its rows). Keeping the
            // last picture beats painting an empty one that then sticks,
            // since an unchanged revision would never be redrawn.
            guard !frame.ansi.isEmpty else {
                Self.logger.debug("empty capture for pane \(id); keeping last frame")
                continue
            }
            if frames[id]?.revision != frame.revision { changed = true }
            frames[id] = frame
        }
        for id in fetched { lastFetchAt[id] = now }
        // Panes that vanished take their frames with them.
        let live = Set(result.snapshot.allPanes.map(\.id))
        frames = frames.filter { live.contains($0.key) }

        let topologyChanged = result.snapshot != snapshot
        snapshot = result.snapshot
        let wasLoading = state != .live
        state = .live
        if topologyChanged || wasLoading { onChange?() }

        if result.truncated {
            fetchCap = max(1, min(fetchCap, max(request.fetch.count, 2)) / 2)
            cleanTicks = 0
            Self.logger.debug("reply truncated at \(Self.responseCap) bytes; fetching \(self.fetchCap) panes per tick")
        } else {
            cleanTicks += 1
            if cleanTicks >= 5, fetchCap != Int.max {
                fetchCap = fetchCap >= (Int.max / 2) ? Int.max : fetchCap * 2
                cleanTicks = 0
            }
        }

        // First topology lands with no frames: fetch the visible set right
        // away, unless zmx's seeded first tick already covered it.
        if tickCount == 1, MuxZmxBootstrap.needsImmediateFollowUp(type: type, snapshot: result.snapshot, frames: frames) {
            return .immediate
        }
        if changed {
            interval = floorInterval
        } else {
            interval = min(interval * 1.5, Self.maxInterval)
        }
        return .wait(interval)
    }

    private func failed(_ message: String) -> Outcome {
        failures += 1
        Self.logger.debug("\(message, privacy: .public) (failure \(self.failures))")
        if failures >= Self.failuresBeforeUnavailable, state != .failed {
            state = .failed
            // The tray now says the session is unavailable: worth one line.
            Self.logger.warning("multiplexer session stopped answering after \(self.failures) attempts")
            onChange?()
        }
        return .wait(min(pow(2, Double(failures - 1)), 10))
    }

    /// Panes to capture this tick, active tab first, then visible, then the rest.
    private func fetchList(now: CFTimeInterval) -> [String] {
        guard let snapshot else { return [] }
        var ordered: [(String, Int)] = []
        for tab in snapshot.tabs {
            // Over the cap only the active pane gets a picture.
            var budget = Self.maxPreviewPanesPerTab
            for pane in tab.panes where pane.isPreviewable {
                if budget <= 0, !pane.isActive { continue }
                budget -= 1
                let visible = visiblePanes.contains(pane.id)
                let rank = tab.id == snapshot.activeTabID ? 0 : (visible ? 1 : 2)
                ordered.append((pane.id, rank))
            }
        }
        var fetch: [String] = []
        for (id, rank) in ordered.sorted(by: { $0.1 < $1.1 }) {
            guard let last = lastFetchAt[id], frames[id] != nil else {
                fetch.append(id)
                continue
            }
            let hintChanged = hints[id] != nil && hints[id] != lastHints[id]
            let stale = now - last >= Self.staleAfter
            if rank < 2 {
                if hintChanged || stale || hints[id] == nil { fetch.append(id) }
            } else if hintChanged || (stale && tickCount % Self.hiddenPaneEveryNthTick == 0) {
                fetch.append(id)
            }
        }
        for id in fetch { lastHints[id] = hints[id] }
        if fetch.count > fetchCap { fetch.removeLast(fetch.count - fetchCap) }
        return fetch
    }

    /// Hint value each pane was last fetched under.
    private var lastHints: [String: String] = [:]

    private static func nonce() -> String {
        String(UInt64.random(in: 0...UInt64.max), radix: 36)
    }
}
