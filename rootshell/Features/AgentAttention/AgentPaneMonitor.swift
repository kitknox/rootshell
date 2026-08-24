//
//  AgentPaneMonitor.swift
//  rootshell
//
//  Per-pane agent state machine. Owns identity (which agent runs in the
//  pane), the stable screen state with herdr's anti-flicker rules, the
//  seen/unseen edges, and the timing fields the UI derives elapsed labels
//  from. Monitors are created and torn down by AgentAttentionCenter's
//  reconcile pass; they never outlive their pane in the UI tree.
//
//  Anti-flicker (adapted from herdr for event-driven scans):
//  - visible state changes need two consistent observations; weak/fallback
//    changes need three.
//  - the first strong classification may commit immediately because initial
//    discovery is never a notification transition.
//  - skipStateUpdate (transcript viewers, menus) freezes the stable state.
//  - identity changes get a 3s startup grace before classification so
//    splash screens can't produce garbage states.
//

import Foundation
import UIKit

@MainActor
final class AgentPaneMonitor {

    // MARK: - Identity

    let paneUUID: UUID
    private(set) weak var terminal: Ghostty.TerminalView?
    private(set) weak var tab: TabModel?
    private(set) weak var tabsModel: TabsModel?

    /// Detected agent, sticky until cleared by command-finished, an agent
    /// change, or repeated no-signal scans. nil = plain pane.
    private(set) var agent: AgentDetectionManifest.Agent?

    enum IdentitySource: String {
        case title
        case screen
        case command
    }
    private(set) var identitySource: IdentitySource?

    /// This pane is showing a multiplexer the app does not drive, so its
    /// screen is ONE window of several and the visible window can change
    /// without the agent doing anything.
    ///
    /// Detection still runs — the screen genuinely shows the active window's
    /// agent, which is what the user is looking at, and reporting it is the
    /// behaviour people rely on. What this disables is every inference that
    /// depends on the screen belonging to one process for the whole session:
    /// an agent leaving the screen is a window switch as often as a finish,
    /// and we cannot tell which. (id=agent-attention-raw-mux)
    ///
    /// The binding is set by construction from a configured launch command
    /// or auto-connect, which cannot see a multiplexer the user simply
    /// TYPED. `sawMultiplexerChrome` closes that: peeling a pane frame or a
    /// status bar off the snapshot is direct evidence, from the read itself.
    /// Field repro of the gap: a hand-typed `zellij` kept `altHeld` for the whole
    /// attach, because the alt screen belongs to zellij and never lapses, so
    /// the first agent identified in it was pinned forever and a later codex
    /// still showed as claude.
    var isInsideRawMultiplexer: Bool { terminal?.rawMultiplexer != nil || sawMultiplexerChrome }

    /// Whether multiplexer chrome (a pane frame, a status bar) was seen
    /// while the current alt screen has been held. Latched rather than
    /// per-frame: a full-screen overlay can cover the border for a frame or
    /// two, and this only ever DISABLES optimistic inferences, so erring
    /// towards "still in a multiplexer" is the safe direction. Cleared with
    /// alt ownership, which is when the multiplexer itself has gone.
    private(set) var sawMultiplexerChrome = false

    /// Last time a project resolution was attempted for this pane. A request
    /// fired at identification can fail for reasons that clear on their own
    /// (a tmux gateway still attaching, a link still coming up), and the
    /// agent is identified only once — so without a retry floor a single
    /// early failure would leave the pane without a project forever.
    /// (id=agent-project)
    var lastProjectRequestAt: Date?

    /// What this pane's agent is working on. Sticky like the agent identity:
    /// a pass that produces no evidence keeps the last value rather than
    /// blanking the card. (id=agent-project)
    private(set) var project: AgentProjectIdentity?

    /// Records a resolved project, refusing evidence weaker than what we
    /// already hold for the same directory.
    ///
    /// A directory CHANGE always wins whatever reported it — the agent really
    /// did move — but for the same directory a shell report must not drop the
    /// branch a probe resolved. Returns true when the stored value changed, so
    /// the caller can decide whether a publish is warranted.
    /// - Parameter authoritative: the caller resolved repository facts for
    ///   this exact directory, so a nil branch is a real answer (detached HEAD,
    ///   or no longer a repository) and MUST be able to clear a stale one.
    ///   Directory refreshes are not authoritative: they carry no branch at all.
    @discardableResult
    func noteProject(_ candidate: AgentProjectIdentity, authoritative: Bool = false) -> Bool {
        // Inside a multiplexer the app does not drive, we cannot know where
        // the agent is. tmux CONSUMES the shell's OSC 7 (input.c, case 7 ->
        // screen_set_path) and never forwards it, and zellij and herdr's TUI
        // are the same: the only directory that ever reaches this surface is
        // the OUTER shell's, from wherever the multiplexer was started. The
        // branch probe then runs against that directory and answers
        // confidently about the wrong repository.
        //
        // Showing nothing is the honest outcome. A card that says the wrong
        // project is worse than a card that says none, and unlike the state
        // machine there is no partial signal to salvage: the paths are simply
        // not observable from here. tmux CONTROL MODE is unaffected, because
        // its gateway reports each pane's own directory out of band.
        // (id=agent-project)
        guard !isInsideRawMultiplexer else { return false }
        var candidate = candidate

        if let current = project, !authoritative, candidate.repositoryRoot == nil {
            if current.path == candidate.path {
                // Directory sources periodically re-report the same cwd but
                // know nothing about Git. Keep the authoritative root.
                candidate.repositoryRoot = current.repositoryRoot
                if let root = current.repositoryRoot {
                    candidate.label = AgentProjectPath.label(
                        forPath: candidate.path,
                        repoRoot: root
                    ) ?? current.label
                }
            } else if let root = current.repositoryRoot,
                      AgentProjectPath.isInsideRepository(candidate.path, root: root) {
                // A cwd change inside the already-probed worktree remains the
                // same project while the new exact-path probe catches up.
                candidate.repositoryRoot = root
                candidate.label = AgentProjectPath.label(
                    forPath: candidate.path,
                    repoRoot: root
                ) ?? current.label
                if candidate.branch == nil {
                    candidate.branch = current.branch
                }
            }
        }

        if let current = project, current.path == candidate.path, !authoritative {
            // A refresh of the SAME directory must never LOSE what we know.
            // The directory source (tmux, OSC 7) re-reports every few seconds
            // and carries no branch, so overwriting wholesale wiped the branch
            // a probe had resolved and left the card blank until something
            // restored it.
            if candidate.branch == nil { candidate.branch = current.branch }

            guard candidate.source >= current.source else {
                // Same directory, weaker source: keep what we have, but let it
                // fill a gap it could not have known about.
                if current.branch == nil, candidate.branch != nil {
                    project?.branch = candidate.branch
                    return true
                }
                return false
            }
        }
        guard project != candidate else { return false }
        project = candidate
        return true
    }

    /// Drops the project when the pane's agent goes away, so a later agent in
    /// the same pane cannot inherit the previous one's directory.
    func clearProject() {
        project = nil
    }

    // MARK: - State machine

    private(set) var stableState: AgentScreenState = .unknown
    private(set) var lastClassification: AgentClassification?

    private var stateStabilizer = AgentScreenStateStabilizer()
    private(set) var startupGraceUntil: Date?

    /// Consecutive full scans with no rule match and no identity signature
    /// while the alt screen is off; drives identity clearing.
    private var noSignalScanStreak = 0

    // MARK: - Timing / inbox fields

    private(set) var workingSince: Date?
    private(set) var finishedAt: Date?
    private(set) var exitCode: Int?
    private(set) var lastDuration: TimeInterval?

    private(set) var doneUnseen = false
    private(set) var failedUnseen = false
    private var eventState = AgentAttentionEventState()

    /// The question this pane is blocked on, read off the screen that
    /// classified it. Only ever set while blocked, so a notification can
    /// never quote a dialog the agent has already moved past.
    private(set) var promptSummary: String?

    /// Identity of the agent whose run just ended, retained so the
    /// completion (card, counts, notification) still names it after
    /// `clearAgent`. Cleared when the result is seen or a new agent is
    /// adopted.
    private(set) var finishedAgentID: String?
    private(set) var finishedAgentDisplayName: String?

    /// Task-detection state machine for this pane (long-running commands
    /// and input prompts). Always reset while an agent holds the pane:
    /// agent identity wins, and the two never show at once.
    private(set) var taskTracker = TaskAttentionTracker()

    /// Last real output time from Ghostty's exact per-surface content edge.
    /// nil until the pane actually produces output.
    private(set) var lastActivityAt: Date?

    /// Creation time; grants the initial identity-scan window (a pane
    /// that was already quiet at engine start, e.g. an agent sitting
    /// blocked, still gets scanned).
    let createdAt = Date()

    /// Until when output bursts are untrustworthy as work evidence.
    private(set) lazy var settleUntil = createdAt.addingTimeInterval(Tuning.baseSettle)

    private func extendSettle(_ interval: TimeInterval, now: Date) {
        settleUntil = max(settleUntil, now.addingTimeInterval(interval))
    }

    /// A repaint is in flight (resize, replay, restore). Mid-repaint the
    /// agent's chrome is legitimately absent for a frame or two, so a scan
    /// that finds nothing is not evidence the agent exited — on iPhone the
    /// keyboard bouncing in and out as the tab sidebar opens resizes every
    /// terminal, and three such frames would otherwise clear identity.
    var isSettling: Bool { Date() < settleUntil }

    /// The grid was resized: every app repaints (SIGWINCH), none of it
    /// is work.
    func noteGridResize(now: Date = Date()) {
        extendSettle(Tuning.resizeSettle, now: now)
    }

    // MARK: - Forced rebuilds

    /// The window in which a repaint we ordered ourselves is rebuilding this
    /// pane's screen, or nil when none is in flight. A tmux -CC pane inherits
    /// its gateway's window: the session driving the recapture has no
    /// reference to the pane surfaces it replays into, which is why
    /// `ringBell` resolves through `parentUUID` too.
    var rebuildWindow: (start: Date, end: Date)? {
        if let window = TerminalBellSuppressor.rebuildWindow(paneUUID) { return window }
        guard let parentUUID = terminal?.tmuxPaneBinding?.parentUUID else { return nil }
        return TerminalBellSuppressor.rebuildWindow(parentUUID)
    }

    var rebuildDeadline: Date? { rebuildWindow?.end }

    /// A discard recapture or reconnect replay is rebuilding this pane's
    /// screen from scratch. The frames it walks through (blank, replayed
    /// transcript, half-drawn chrome) are our own doing, not the agent's.
    var isRebuilding: Bool { rebuildWindow != nil }

    /// The rebuild is not over while its bytes are still arriving. Holds
    /// whichever id carries the window open a little longer; a pane with no
    /// window open is untouched.
    func refreshRebuild(now: Date = Date()) {
        TerminalBellSuppressor.extendRebuild(paneUUID, now: now)
        if let parentUUID = terminal?.tmuxPaneBinding?.parentUUID {
            TerminalBellSuppressor.extendRebuild(parentUUID, now: now)
        }
    }

    /// Set when a publish pass SAW this pane rebuilding, so the first pass
    /// afterwards reconciles and compares by STATUS instead of event
    /// identity (the rebuilt screen mints fresh event ids for states the
    /// user was already told about).
    ///
    /// Keyed on observing the rebuild, never on observing an event
    /// change. Several of the rebuild's side effects deliberately cancel
    /// each other out at the display level — a working→idle commit arms a
    /// pending completion, which still reads as working — so the event can
    /// be unchanged while the state machine underneath has moved. Arming on
    /// the event would skip reconciliation in exactly those cases.
    private var pendingRebuildRebaseline = false

    /// The transition sequence as it stood when the rebuild began. Transient
    /// commits bump it, and under attention sort that reorders the sidebar
    /// even when the pane ends up exactly where it started.
    private var preRebuildStateChangeSeq: UInt64?

    func noteRebuildObserved() {
        if !pendingRebuildRebaseline {
            preRebuildStateChangeSeq = stateChangeSeq
        }
        pendingRebuildRebaseline = true
    }

    func consumeRebuildRebaseline() -> Bool {
        defer { pendingRebuildRebaseline = false }
        return pendingRebuildRebaseline
    }

    /// Run once at the first publish after a rebuild window closes.
    ///
    /// The replay's intermediate frames were absorbed and several of their
    /// side effects deliberately deferred, so the state machine can now hold
    /// a conclusion the settled screen contradicts, or be missing one it
    /// implies. Neither self-corrects: nothing commits again once the pane is
    /// already sitting in its final state. So reconcile against that final
    /// state here, applying the rules `commit` would have applied had the
    /// transition happened in one step.
    func reconcileAfterRebuild(previousStatus: AgentAttentionStatus?, now: Date) {
        guard agent != nil else { return }

        switch stableState {
        case .working, .blocked:
            // The pane is demanding attention again, so an unread result
            // from before the outage is stale. `commit`'s own rule, applied
            // to the settled state instead of to a transient replay frame.
            doneUnseen = false
            failedUnseen = false
            eventState.clearCompletion()
            pendingDoneSince = nil
        case .idle:
            // It was busy when the link dropped and is idle now, so it
            // really did finish. Its mid-replay candidate was cancelled
            // because that settle timer would have been measuring the
            // replay, not the agent; arm a fresh one from here and let it
            // settle normally.
            let wasBusy = previousStatus == .working || previousStatus == .blocked
            if wasBusy, pendingDoneSince == nil, !doneUnseen, !failedUnseen {
                pendingDoneSince = now
            }
        case .unknown:
            break
        case .done, .failed:
            // Task-only states; an agent's stable state can never hold them
            // (manifest compile drops agent rules claiming either).
            break
        }

        refreshScreenEvent(now: now)

        // Transient commits bumped the transition sequence. If the pane
        // ended up exactly where it started, the sidebar must not reorder as
        // though something happened.
        if displayStatus(now: now) == previousStatus, let seq = preRebuildStateChangeSeq {
            stateChangeSeq = seq
        }
        preRebuildStateChangeSeq = nil
    }

    /// Background-agent (fleet) rows from the last scan, grouped by agent
    /// name, plus how long a tick keeps this pane working. The main agent
    /// can sit idle at its prompt while its fleet runs, and a finished row
    /// probably keeps its final duration on screen — so the evidence is a
    /// row's timer ADVANCING between scans, never the list's presence.
    private var lastFleetRows: [String: [AgentFleetRows.RowMemory]] = [:]
    private(set) var fleetWorkingUntil: Date?
    private(set) var fleetAgentCount = 0
    private(set) var fleetMaxElapsed: TimeInterval?
    /// Set while the fleet held this pane working, so the falling edge can
    /// arm a completion the same way a working→idle screen edge does.
    private var fleetWasWorking = false

    func isFleetWorking(now: Date = Date()) -> Bool {
        guard let until = fleetWorkingUntil else { return false }
        return now < until
    }

    /// Identity changed: the previous agent's fleet is not this one's.
    private func resetFleet() {
        lastFleetRows = [:]
        fleetWorkingUntil = nil
        fleetAgentCount = 0
        fleetMaxElapsed = nil
        fleetWasWorking = false
    }

    /// Fold one scan's fleet list in. Returns true when a row advanced.
    @discardableResult
    func noteFleet(rows: [AgentFleetRows.Row], waitingCount: Int?, now: Date) -> Bool {
        let delta = AgentFleetRows.delta(
            from: lastFleetRows,
            to: rows,
            now: now,
            liveWindow: Tuning.fleetWorkingGrace
        )
        // A scan with no rows at all is usually the list being covered (a
        // slash-command menu, an exit dialog) rather than the fleet
        // ending, so it must not erase what we know about each row.
        if !rows.isEmpty { lastFleetRows = delta.snapshot }
        fleetMaxElapsed = rows.map(\.elapsed).max()
        // Claude's own count is authoritative and survives the list being
        // truncated or scrolled out of the snapshot. Otherwise count the
        // rows themselves, except on a scan that saw none while the fleet
        // is still known to be running.
        if let waitingCount {
            fleetAgentCount = waitingCount
        } else if !rows.isEmpty || !isFleetWorking(now: now) {
            fleetAgentCount = delta.liveCount
        }
        if delta.advanced {
            fleetWorkingUntil = now.addingTimeInterval(Tuning.fleetWorkingGrace)
            pendingDoneSince = nil
            refreshScreenEvent(now: now)
        }
        return delta.advanced
    }

    /// A completion candidate: working ended (screen or quiet edge) but
    /// Done is withheld until it survives the settle window — claude's
    /// spinner line vanishes transiently between tool steps and must not
    /// flash Done mid-task. While pending, the row keeps showing working.
    private(set) var pendingDoneSince: Date?
    var isPendingDone: Bool { pendingDoneSince != nil }
    var completionDeadline: Date? {
        pendingDoneSince?.addingTimeInterval(Tuning.doneSettle)
    }

    /// Global transition sequence from the center; sort tiebreak.
    private(set) var stateChangeSeq: UInt64 = 0

    // MARK: - Scheduler bookkeeping (owned by the center)

    var lastAltActive = false
    var lastSeenTitle = ""
    var lastScanAt = Date.distantPast
    /// Last semantic event the center published (transition edges and
    /// same-status new completions).
    var lastPublishedEvent: AgentAttentionEvent?
    /// Edge detector for the rule-id diagnostic; only read when snapshot
    /// recording is on.
    var lastMatchedRuleID: String?

    // MARK: - Constants

    private enum Tuning {
        /// Activity hint at most this old keeps an unclassified agent pane
        /// rendering as working between scans.
        static let workingWindow: TimeInterval = 4
        /// Skip classification this long after identity changes.
        static let startupGrace: TimeInterval = 3
        /// Identity clears after this many consecutive no-signal scans.
        static let noSignalClearStreak = 3
        /// A completion must stay quiet this long before Done is real.
        /// Must exceed the center's active-class scan staleness so at
        /// least one re-scan happens inside the window.
        static let doneSettle: TimeInterval = 8
        /// Settle windows: spans in which output bursts are untrustworthy
        /// as work evidence (screen-classified states are always exempt —
        /// chrome on the screen is current truth). Base covers a fresh
        /// pane's banner spew without swallowing a quick first command;
        /// resize covers repaints from geometry changes (dock/undock,
        /// rotation, keyboard).
        static let baseSettle: TimeInterval = 1.5
        static let resizeSettle: TimeInterval = 4
        /// How long one fleet-row tick keeps the pane working. Must span
        /// several scans at the slowest power tier so a single skipped
        /// read doesn't drop the card out of working.
        static let fleetWorkingGrace: TimeInterval = 15
    }

    init(paneUUID: UUID, terminal: Ghostty.TerminalView?, tab: TabModel?, tabsModel: TabsModel?) {
        self.paneUUID = paneUUID
        self.terminal = terminal
        self.tab = tab
        self.tabsModel = tabsModel
    }

    /// Topology reconciliation refreshes ownership when panes move between tabs.
    func updateOwners(tab: TabModel?, tabsModel: TabsModel?) {
        self.tab = tab
        self.tabsModel = tabsModel
    }

    // MARK: - Derived status

    var inStartupGrace: Bool {
        if let until = startupGraceUntil { return Date() < until }
        return false
    }

    var wantsStateConfirmationScan: Bool {
        stateStabilizer.needsConfirmation || taskTracker.needsConfirmation
    }

    private func activityFresh(now: Date) -> Bool {
        guard let activity = lastActivityAt else { return false }
        return now.timeIntervalSince(activity) < Tuning.workingWindow
    }

    /// Working is purely screen/title-classified (herdr's model). Byte
    /// activity NEVER makes a pane "working": replay, restore, resize
    /// repaints, statusline clocks, and typing echo all produce bytes,
    /// and three rounds of heuristics could not tell them from work. A
    /// pending completion still displays as working so transient spinner
    /// gaps don't read as idle/done mid-task.
    private func isLiveWorking(now: Date) -> Bool {
        if stableState == .blocked { return false }
        if stableState == .working { return true }
        // A background agent's own timer advancing on screen is screen
        // evidence, the same class as a spinner — not the byte activity
        // ROUND 9 removed. A replayed or restored frame holds a frozen
        // timer, so it can never read as work here.
        if isFleetWorking(now: now) { return true }
        return pendingDoneSince != nil
    }

    private func screenDisplayStatus(now: Date) -> AgentAttentionStatus {
        if stableState == .blocked { return .blocked }
        if isLiveWorking(now: now) { return .working }
        return .idle
    }

    private func refreshScreenEvent(now: Date) {
        guard agent != nil else {
            eventState.updateScreenStatus(nil)
            return
        }
        eventState.updateScreenStatus(screenDisplayStatus(now: now))
    }

    /// Deadline-driven completion bookkeeping: resumed work (screen-confirmed
    /// or fresh real output) cancels the pending completion; one that
    /// survives the settle window promotes to Done (finishedAt +
    /// doneUnseen when the tab isn't viewed).
    @discardableResult
    func updateLivenessEdges(now: Date) -> Bool {
        guard agent != nil else {
            pendingDoneSince = nil
            return false
        }

        // Never promote a completion mid-rebuild: the settle timer would be
        // measuring the replay rather than the agent.
        //
        // A candidate BORN inside the window is dropped, because the replay
        // walks the pane through frames with no working chrome and promoting
        // one would announce "finished" mid-task. That is not a lost
        // completion: if the pane really is idle once the screen settles,
        // `reconcileAfterRebuild` arms a fresh candidate from the close.
        // A candidate already ticking when the link dropped is a real edge
        // and is held as-is, so it promotes on its original schedule.
        if let rebuild = rebuildWindow {
            if let pending = pendingDoneSince, pending >= rebuild.start {
                pendingDoneSince = nil
                // The pending candidate was what made this pane read as
                // working; dropping it without refreshing would leave the
                // screen event stuck on Working with nothing left to
                // correct it (no further commit fires from a pane that is
                // already sitting in its final state).
                refreshScreenEvent(now: now)
            }
            return false
        }

        // Fleet falling edge: the background agents stopped advancing.
        // Treat it like a working→idle screen edge so the finish still
        // surfaces as Done instead of the card quietly going idle.
        let fleetWorking = isFleetWorking(now: now)
        if fleetWasWorking, !fleetWorking {
            fleetAgentCount = 0
            if stableState != .working, stableState != .blocked, pendingDoneSince == nil,
               !isInsideRawMultiplexer {
                pendingDoneSince = now
            }
        }
        fleetWasWorking = fleetWorking

        if pendingDoneSince != nil,
           stableState == .working || fleetWorking || activityFresh(now: now) {
            pendingDoneSince = nil
            refreshScreenEvent(now: now)
            return false
        }

        if let pending = pendingDoneSince,
           now.timeIntervalSince(pending) >= Tuning.doneSettle {
            pendingDoneSince = nil
            finishedAt = pending
            workingSince = nil
            refreshScreenEvent(now: now)
            if !isViewedNow() {
                doneUnseen = true
                eventState.recordCompletion(.done)
            }
            return true
        }
        return false
    }

    func displayEvent(now: Date = Date()) -> AgentAttentionEvent? {
        if agent != nil {
            if stableState == .blocked { return eventState.screenEvent }
            if failedUnseen || doneUnseen { return eventState.completionEvent }
            return eventState.screenEvent
        }
        if let taskEvent = taskTracker.displayEvent() { return taskEvent }
        if failedUnseen || doneUnseen { return eventState.completionEvent }
        return nil
    }

    /// The ladder position this pane contributes to its tab's rollup.
    /// nil = nothing to show (plain quiet pane).
    func displayStatus(now: Date = Date()) -> AgentAttentionStatus? {
        displayEvent(now: now)?.status
    }

    /// Card row state for the sidebar; nil when the pane has no agent and
    /// no unseen command result. A finished agent keeps its name on the
    /// card until seen.
    func rowState(now: Date = Date()) -> AgentRowState? {
        guard let event = displayEvent(now: now) else { return nil }
        if event.category == .task {
            guard let fragment = taskTracker.rowFragment() else { return nil }
            return AgentRowState(
                status: fragment.status,
                category: .task,
                agentID: fragment.taskID,
                agentDisplayName: fragment.displayName,
                taskProgress: fragment.progress,
                workingSince: fragment.workingSince,
                finishedAt: fragment.finishedAt,
                exitCode: fragment.exitCode,
                lastDuration: fragment.lastDuration,
                unread: fragment.unread,
                backgroundAgentCount: 0,
                project: project,
                stateChangeSeq: stateChangeSeq
            )
        }
        let status = event.status
        return AgentRowState(
            status: status,
            agentID: agent?.id ?? finishedAgentID,
            agentDisplayName: agent?.displayName ?? finishedAgentDisplayName,
            workingSince: status == .working ? workingSince : nil,
            finishedAt: finishedAt,
            exitCode: exitCode,
            lastDuration: lastDuration,
            unread: doneUnseen || failedUnseen,
            backgroundAgentCount: status == .working ? fleetAgentCount : 0,
            project: project,
            stateChangeSeq: stateChangeSeq
        )
    }

    // MARK: - Identity transitions

    /// True while a full-screen agent has held the alternate screen
    /// continuously since it was identified.
    ///
    /// A TUI agent owns the alt screen for its whole lifetime and gives it
    /// back on exit, so ownership is a far better liveness signal than its
    /// banner text — the banner scrolls away within seconds ("copilot is
    /// fine when I open it, then drops"; opencode, whose only signature is
    /// its name, stopped being detectable at all once that name scrolled
    /// off).  Continuity is what stops a later `vim` inheriting the
    /// identity: any primary-screen frame revokes the grant for good, and
    /// only a fresh identification can restore it.
    private(set) var altOwnedSinceIdentity = false

    /// Feed every scan's alt-screen reading in. Ownership can only be
    /// broken here, never re-granted — so a repaint we ordered must not
    /// break it. A recapture erases and replays on the primary screen and
    /// only restores terminal modes in its trailing pane state, so a
    /// primary-screen frame inside the rebuild window is our own doing, not
    /// the TUI exiting. Revoking there would drop a full-screen agent whose
    /// banner has long scrolled away, three scans after the window closed.
    func noteAltScreen(_ active: Bool) {
        lastAltActive = active
        if !active, !isRebuilding {
            altOwnedSinceIdentity = false
            sawMultiplexerChrome = false
        }
    }

    /// Feed every scan's multiplexer-chrome reading in. Only ever latches
    /// on: see `sawMultiplexerChrome`.
    func noteMultiplexerChrome(_ present: Bool) {
        if present { sawMultiplexerChrome = true }
    }

    /// Record what this pane is asking. The caller only extracts one while
    /// the classification is a live blocker; nil clears a stale question the
    /// moment the pane stops blocking.
    func notePromptSummary(_ summary: String?) {
        promptSummary = summary
    }

    /// Adopt (or switch) identity. Returns true when identity changed.
    @discardableResult
    func adoptAgent(_ newAgent: AgentDetectionManifest.Agent, source: IdentitySource, now: Date) -> Bool {
        if let current = agent, current.id == newAgent.id {
            identitySource = source
            return false
        }
        // Agent identity always wins the pane; whatever task state was
        // tracked belongs to output the agent has now covered.
        taskTracker.reset()
        altOwnedSinceIdentity = lastAltActive
        // Splash-screen grace only applies when a DIFFERENT agent was
        // here before (title-driven switches). First identification came
        // from real rendered UI — classifying it immediately is exactly
        // right, and startup latency matters (inbox populates in one
        // pass, not after a silent 3s).
        let isSwitch = agent != nil
        agent = newAgent
        finishedAgentID = nil
        finishedAgentDisplayName = nil
        identitySource = source
        stableState = .unknown
        lastClassification = nil
        stateStabilizer.reset()
        noSignalScanStreak = 0
        workingSince = nil
        finishedAt = nil
        exitCode = nil
        lastDuration = nil
        doneUnseen = false
        failedUnseen = false
        promptSummary = nil
        eventState.updateScreenStatus(nil)
        eventState.clearCompletion()
        resetFleet()
        startupGraceUntil = isSwitch ? now.addingTimeInterval(Tuning.startupGrace) : nil
        refreshScreenEvent(now: now)
        return true
    }

    func clearAgent() {
        if let agent {
            finishedAgentID = agent.id
            finishedAgentDisplayName = agent.displayName
        }
        agent = nil
        identitySource = nil
        altOwnedSinceIdentity = false
        stableState = .unknown
        lastClassification = nil
        stateStabilizer.reset()
        noSignalScanStreak = 0
        workingSince = nil
        promptSummary = nil
        resetFleet()
        startupGraceUntil = nil
        refreshScreenEvent(now: Date())
    }

    // MARK: - Signal intake

    func noteActivity(now: Date = Date()) {
        // Bursts inside a settle window trigger re-scans but are never
        // recorded as work, and a rebuild is nothing but such a burst.
        guard now >= settleUntil, !isRebuilding else { return }
        lastActivityAt = now
    }

    /// A full-scan pass found neither a rule match nor an applicable
    /// identity signature. Enough of these in a row and the agent is gone
    /// (a running agent's chrome would match something; alt-screen-only
    /// signatures stop counting the moment the TUI released the alt
    /// screen).
    func noteNoSignalScan() -> Bool {
        guard agent != nil else { return false }
        noSignalScanStreak += 1
        if noSignalScanStreak >= Tuning.noSignalClearStreak {
            clearAgent()
            return true
        }
        return false
    }

    /// Streak in progress: the scheduler scans these at the active
    /// cadence so a gone agent clears in seconds, not staleness cycles.
    var hasNoSignalStreak: Bool { noSignalScanStreak > 0 }

    func resetNoSignalStreak() {
        noSignalScanStreak = 0
    }

    /// OSC 133 command finished. For an identified pane this is the agent
    /// process exiting back to the prompt; for a plain pane it is the
    /// plain-command inbox signal.
    @discardableResult
    func commandFinished(
        exitCode: Int?,
        duration: TimeInterval,
        viewedNow: Bool,
        now: Date = Date()
    ) -> Bool {
        // Replayed OSC 133 from attach/restore is history, not news; a
        // real quick command in a genuinely fresh pane clears the short
        // base settle and is recorded normally.
        //
        // A replay we ordered can arrive long after that birth window, so it
        // needs a guard of its own.
        //
        // Do NOT try to tell a replayed mark from a live one by its
        // CONTENT. The core computes duration locally, from the wall clock
        // between parsing the OSC 133 start and stop marks (`Surface.zig`,
        // `stop_command`: `end.since(start)` over `std.time.Instant.now()`),
        // so a replay reports how long the REPLAY took, not the command. A
        // five-minute command replayed from scrollback arrives as a
        // sub-millisecond one with its exit code unchanged, which is exactly
        // why an (exitCode, duration) fingerprint cannot work.
        //
        // The same fact is why rejecting the window costs little: a command
        // that really finished during the outage has BOTH its marks in the
        // replayed bytes, so it too arrives timing the replay. Admitting it
        // would report a fabricated duration, and for a plain pane
        // `plainDoneMinDuration` would discard it anyway. Reporting outage
        // completions accurately needs provenance from whoever performs the
        // replay, not a heuristic here.
        guard now >= settleUntil, !isRebuilding else { return false }

        // A held task ends with the shell's own verdict: the exit code is
        // authoritative and instant, ahead of any screen summary rule.
        if taskTracker.isActive {
            return taskTracker.finalize(
                exitCode: exitCode, duration: duration, viewedNow: viewedNow, now: now)
        }

        let agentWasActive = agent != nil
        let replacementStatus = AgentCommandCompletionAdmission.unseenStatus(
            agentWasActive: agentWasActive,
            exitCode: exitCode,
            duration: duration,
            viewedNow: viewedNow
        )

        if agentWasActive {
            clearAgent()
        }

        guard let replacementStatus else {
            // Keep the full payload of an earlier unread completion. If
            // there isn't one, retain the latest command metadata as before.
            if !doneUnseen, !failedUnseen {
                finishedAt = now
                self.exitCode = exitCode
                lastDuration = duration
                if !agentWasActive {
                    finishedAgentID = nil
                    finishedAgentDisplayName = nil
                }
            }
            return true
        }

        if !agentWasActive {
            // A plain command's result must not wear an earlier agent's
            // name ("Claude Code failed" for a later shell error).
            finishedAgentID = nil
            finishedAgentDisplayName = nil
        }
        finishedAt = now
        self.exitCode = exitCode
        lastDuration = duration
        doneUnseen = replacementStatus == .done
        failedUnseen = replacementStatus == .failed
        eventState.recordCompletion(replacementStatus)
        return true
    }

    /// Align our elapsed clock with the agent's own on-screen timer
    /// ("(2m 49s · …" in claude/codex status lines). The screen is the
    /// authority: the task may predate identification, and the TUI's
    /// timer pauses during approvals while our stint clock doesn't.
    /// Tolerance covers whole-second quantization + scan latency only —
    /// anything looser reads as "the timers disagree".
    /// Returns the applied correction in seconds, 0 when in tolerance.
    @discardableResult
    func syncWorkingClock(screenElapsed: TimeInterval, now: Date = Date()) -> TimeInterval {
        let target = now.addingTimeInterval(-screenElapsed)
        if let current = workingSince {
            let drift = current.timeIntervalSince(target)
            if abs(drift) <= 1.5 { return 0 }
            workingSince = target
            return drift
        }
        workingSince = target
        return 0
    }

    /// The user is looking at this pane's tab right now.
    func markSeen() {
        doneUnseen = false
        failedUnseen = false
        eventState.clearCompletion()
        finishedAgentID = nil
        finishedAgentDisplayName = nil
        taskTracker.markSeen()
    }

    // MARK: - Task intake

    var isTaskActive: Bool { taskTracker.isActive }

    func adoptTask(_ task: AgentDetectionManifest.Agent, now: Date) {
        guard agent == nil, let family = task.family else { return }
        taskTracker.adopt(id: task.id, displayName: task.displayName, family: family, now: now)
    }

    /// Fold one scan's task classification in. Returns true when the
    /// display state changed (the center bumps seq and publishes).
    func applyTaskObservation(
        _ classification: AgentClassification,
        promptLine: String?,
        progress: String?,
        now: Date,
        seq: () -> UInt64
    ) -> Bool {
        lastScanAt = now
        let changed = taskTracker.observe(
            classification,
            promptLine: promptLine,
            progress: progress,
            viewedNow: isViewedNow(),
            now: now
        )
        if changed { stateChangeSeq = seq() }
        return changed
    }

    /// A scan matched none of the held task's rules. Returns true when
    /// the identity cleared (display change).
    func noteTaskNoMatch() -> Bool {
        taskTracker.noteNoMatch()
    }

    /// Clear all task state for this pane (feature or family toggled off).
    func resetTaskTracker() {
        taskTracker.reset()
    }

    /// Feature-level clear for the agent category: drop identity AND any
    /// unseen agent/plain-command completion, leaving task state alone.
    /// (`clearAgent` deliberately retains the finished identity so a
    /// completion can still name its agent; a settings-off must not.)
    func resetAgentCategory() {
        clearAgent()
        doneUnseen = false
        failedUnseen = false
        eventState.clearCompletion()
        finishedAgentID = nil
        finishedAgentDisplayName = nil
        clearProject()
    }

    // MARK: - Classification intake

    /// Apply a classification pass. Returns true when the stable state
    /// changed (the center bumps the transition seq and notifies).
    func applyClassification(_ classification: AgentClassification, now: Date, seq: () -> UInt64) -> Bool {
        lastScanAt = now
        lastClassification = classification
        guard agent != nil else { return false }

        switch stateStabilizer.observe(current: stableState, classification: classification) {
        case .hold:
            return false
        case .commit(let state):
            return commit(state, now: now, seq: seq)
        }
    }

    private func commit(_ newState: AgentScreenState, now: Date, seq: () -> UInt64) -> Bool {
        guard newState != stableState else { return false }
        let oldState = stableState
        stableState = newState
        stateChangeSeq = seq()

        switch newState {
        case .working:
            if workingSince == nil { workingSince = now }
            finishedAt = nil
        case .blocked:
            finishedAt = nil
        case .idle:
            // Completion edge: (working|blocked) → idle. Arms the settle
            // window; updateLivenessEdges promotes it to Done only if no
            // work resumes (claude's spinner line vanishes transiently
            // between tool steps).
            if oldState == .working || oldState == .blocked, !isInsideRawMultiplexer {
                if pendingDoneSince == nil { pendingDoneSince = now }
            }
        case .unknown:
            workingSince = nil
        case .done, .failed:
            // Task-only states; manifest compile drops agent rules that
            // claim them, so the stabilizer can never feed them here.
            break
        }

        // Any non-idle transition means the pane is demanding attention
        // again; stale unread completion flags would lie. A transition the
        // rebuild itself produced proves nothing either way, so the
        // decision is DEFERRED to `reconcileAfterRebuild`, which applies
        // this same rule to the settled state. Clearing here instead would
        // destroy a genuine unread result that the replay merely painted
        // over, and nothing could restore it.
        if newState != .idle, !isRebuilding {
            doneUnseen = false
            failedUnseen = false
            eventState.clearCompletion()
            pendingDoneSince = nil
        }
        refreshScreenEvent(now: now)
        return true
    }

    /// Whether the user is looking at this exact pane right now: app active,
    /// containing tab selected, this pane focused, and the pane's window key.
    /// A visible sibling split does not consume another pane's unread result.
    func isViewedNow() -> Bool {
        var isKeyWindow = terminal?.window?.isKeyWindow ?? false
        #if !targetEnvironment(macCatalyst)
        // External-display terminals are never in a key window while parked;
        // the big screen being presented counts as viewed.
        if terminal?.windowId == ExternalDisplay.windowId {
            isKeyWindow = ExternalDisplayManager.shared.isExternalWindowViewed
        }
        #endif
        return AgentPaneVisibility.isViewed(
            appBackgrounded: Ghostty.isAppBackgrounded,
            selectedTabID: tabsModel?.selectedTabID,
            containingTabID: tab?.id,
            focusedPaneID: tab?.focusedPane?.uuid,
            paneID: paneUUID,
            isKeyWindow: isKeyWindow
        )
    }
}
