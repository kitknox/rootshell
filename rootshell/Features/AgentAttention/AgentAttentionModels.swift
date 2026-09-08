//
//  AgentAttentionModels.swift
//  rootshell
//
//  Attention vocabulary for coding-agent and task detection on terminal
//  tabs: the display ladder, the raw screen classification, the per-tab
//  badge value, and the per-tab card row state.
//
//  The ladder follows herdr's model: `done` means "finished and not yet
//  looked at" and OUTRANKS `working`; "seen" flips only when the tab is
//  actually selected while the app is active and key — never from
//  previews or engine reads. For agents, `failed` comes from OSC 133 exit
//  codes, not from screen classification; task entries may additionally
//  classify done/failed from machine-stable summary lines.
//

import Foundation

// MARK: - Display status

/// Display-ladder status for a tab running a coding agent (or a finished
/// plain command). `done` and `failed` are derived (raw state + seen /
/// exit code); screen classification never produces them directly.
nonisolated enum AgentAttentionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case working
    case paused
    case blocked
    case done
    case failed
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentAttentionStatus(rawValue: raw) ?? .unknown
    }

    /// Attention ladder: blocked 6 > failed 5 > done 4 > paused 3 >
    /// working 2 > idle 1 > unknown 0. The single source of truth for every rollup
    /// and sort (herdr shipped four copies and one disagreed; don't).
    var attentionPriority: Int {
        switch self {
        case .blocked: return 6
        case .failed: return 5
        case .done: return 4
        case .paused: return 3
        case .working: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    static func worst(of statuses: some Sequence<AgentAttentionStatus>) -> AgentAttentionStatus {
        statuses.max(by: { $0.attentionPriority < $1.attentionPriority }) ?? .unknown
    }
}

/// Live Activity census of detected coding agents, bucketed by what the
/// widget can say about them. `attention` folds blocked, failed and unseen
/// done together: each one needs the user to look. Task rows and OSC-only
/// Activity rows are never counted.
nonisolated struct CodingAgentCounts: Equatable, Sendable {
    var working = 0
    var attention = 0
    var idle = 0

    var total: Int { working + attention + idle }

    mutating func add(_ bucket: CodingAgentBucket) {
        switch bucket {
        case .working: working += 1
        case .attention: attention += 1
        case .idle: idle += 1
        }
    }

    mutating func add(_ status: AgentAttentionStatus) {
        if let bucket = CodingAgentBucket(status) { add(bucket) }
    }
}

/// The three Live Activity buckets. `unknown` maps to none and is not counted.
nonisolated enum CodingAgentBucket: String, Equatable, Sendable {
    case working
    case attention
    case idle

    init?(_ status: AgentAttentionStatus) {
        switch status {
        case .working: self = .working
        case .blocked, .failed, .done: self = .attention
        case .idle, .paused: self = .idle
        case .unknown: return nil
        }
    }
}

/// One counted agent with the push-route keys that identify its pane, so the
/// notification service extension can apply a hook push to it while the app
/// is backgrounded. Keys mirror `PushNotificationRouter.resolve`.
nonisolated struct CodingAgentEntry: Equatable, Sendable {
    /// The pane's own `TerminalView.uuid`.
    let paneID: UUID
    let bucket: CodingAgentBucket
    /// Ordinary pane: what the hook sends as `pane` (the same UUID).
    var routePane: UUID? = nil
    /// tmux control-mode pane: the gateway terminal's UUID.
    var gatewayPane: UUID? = nil
    /// tmux control-mode pane: canonical server identity, nil until resolved.
    var tmuxServer: String? = nil
    /// tmux control-mode pane: server-global numeric pane id.
    var tmuxPaneID: Int? = nil
}

nonisolated struct CodingAgentCensus: Equatable, Sendable {
    var counts = CodingAgentCounts()
    var entries: [CodingAgentEntry] = []
}

// MARK: - Notification event identity

/// Stable identity for one semantic attention event. Repeated scans,
/// publishes, and scheduling attempts keep the same value; a confirmed
/// state transition or a new command completion gets a new value.
nonisolated struct AgentAttentionEventID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct AgentAttentionEvent: Equatable, Sendable {
    var status: AgentAttentionStatus
    var id: AgentAttentionEventID
    var category: AttentionCategory = .agent
}

// MARK: - Detection categories

/// Which detection surface produced an event or row: a coding agent
/// (manifest `kind: "agent"`) or a long-running command / prompt
/// (`kind: "task"`). Each category has its own enable setting,
/// notification policy, and notification slot per pane.
nonisolated enum AttentionCategory: String, Codable, Sendable {
    case agent
    case task
}

/// Task-entry grouping for the per-family settings toggles. A task
/// manifest entry without a recognized family is dropped at compile —
/// otherwise it could never be switched off.
nonisolated enum TaskFamily: String, Codable, Sendable, CaseIterable {
    case prompts
    case tests
    case builds
    case infra
    case transfers
}

/// Owns the stable IDs behind a pane's screen state and latest completion.
/// Keeping this pure makes the once-per-event contract independently
/// testable without UIKit or a live terminal surface.
nonisolated struct AgentAttentionEventState {
    private(set) var screenEvent: AgentAttentionEvent?
    private(set) var completionEvent: AgentAttentionEvent?

    @discardableResult
    mutating func updateScreenStatus(
        _ status: AgentAttentionStatus?,
        category: AttentionCategory = .agent
    ) -> AgentAttentionEvent? {
        guard let status else {
            screenEvent = nil
            return nil
        }
        if screenEvent?.status != status {
            screenEvent = AgentAttentionEvent(status: status, id: AgentAttentionEventID(), category: category)
        }
        return screenEvent
    }

    @discardableResult
    mutating func recordCompletion(
        _ status: AgentAttentionStatus,
        category: AttentionCategory = .agent
    ) -> AgentAttentionEvent {
        precondition(status == .done || status == .failed)
        let event = AgentAttentionEvent(status: status, id: AgentAttentionEventID(), category: category)
        completionEvent = event
        return event
    }

    mutating func clearCompletion() {
        completionEvent = nil
    }
}

/// Small bounded insertion-ordered set used by the notification router.
/// `insertIfNew` is the idempotency gate: false means this exact semantic
/// event has already been handled.
nonisolated struct AgentAttentionEventHistory: Sendable {
    private var ids: [AgentAttentionEventID] = []
    private let capacity: Int

    init(capacity: Int = 32) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func insertIfNew(_ id: AgentAttentionEventID) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > capacity {
            ids.removeFirst(ids.count - capacity)
        }
        return true
    }

    var count: Int { ids.count }
}

/// Elapsed-time wording, shared by the sidebar card and the notification
/// body so the two never disagree about how long something has taken.
/// Deliberately matches the agents' own TUI format rather than a locale
/// formatter: the card sits beside the terminal that printed it.
nonisolated enum AgentElapsedFormat {

    /// "17s", "2m 49s", "1h 5m".
    static func elapsed(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return String(
                localized: "\(total)s",
                comment: "Compact agent elapsed time in seconds")
        }
        let minutes = total / 60
        if minutes < 60 {
            return String(
                localized: "\(minutes)m \(total % 60)s",
                comment: "Compact agent elapsed time in minutes and seconds")
        }
        return String(
            localized: "\(minutes / 60)h \(minutes % 60)m",
            comment: "Compact agent elapsed time in hours and minutes")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        elapsed(seconds: now.timeIntervalSince(start))
    }

    /// "just now", "12m ago", "3h ago", "2d ago".
    static func relative(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 {
            return String(localized: "just now", comment: "Agent status relative time")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(
                localized: "\(minutes)m ago",
                comment: "Agent status relative time in minutes")
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(
                localized: "\(hours)h ago",
                comment: "Agent status relative time in hours")
        }
        return String(
            localized: "\(hours / 24)d ago",
            comment: "Agent status relative time in days")
    }
}

/// Decides whether a command completion should replace the current unread
/// completion. An ineligible result returns nil so callers preserve the
/// existing event and its metadata.
nonisolated enum AgentCommandCompletionAdmission {
    static let plainDoneMinDuration: TimeInterval = 10

    static func unseenStatus(
        agentWasActive: Bool,
        exitCode: Int?,
        duration: TimeInterval,
        viewedNow: Bool
    ) -> AgentAttentionStatus? {
        guard !viewedNow else { return nil }
        if (exitCode ?? 0) != 0 { return .failed }
        if agentWasActive || duration >= plainDoneMinDuration { return .done }
        return nil
    }
}

/// Pure visibility gate for seen/unseen semantics. A split sibling being
/// visible is insufficient: only the exact focused pane consumes its event.
nonisolated enum AgentPaneVisibility {
    static func isViewed(
        appBackgrounded: Bool,
        selectedTabID: UUID?,
        containingTabID: UUID?,
        focusedPaneID: UUID?,
        paneID: UUID,
        isKeyWindow: Bool
    ) -> Bool {
        !appBackgrounded
            && selectedTabID == containingTabID
            && focusedPaneID == paneID
            && isKeyWindow
    }
}

// MARK: - Raw screen state

/// What screen/title classification can actually observe. For AGENT
/// entries, `done` and `failed` deliberately do not exist: done is
/// idle-and-unseen, failed is an exit code, and manifest compile drops
/// agent rules claiming either. TASK entries (pytest, cargo, rsync…) may
/// classify them from machine-stable summary lines — their programs
/// print a verdict and exit instead of returning to a prompt box.
nonisolated enum AgentScreenState: String, Sendable, Equatable {
    case idle
    case working
    case blocked
    case done
    case failed
    case unknown
}

/// One classification pass result: the raw state plus the rule flags
/// that drive anti-flicker (visible chrome bypasses holds) and state
/// freezing (transcript viewers).
nonisolated struct AgentClassification: Sendable, Equatable {
    var state: AgentScreenState = .unknown

    /// Live idle chrome (a real prompt box) is on screen: a working→idle
    /// edge may publish immediately instead of waiting out confirmation.
    var visibleIdle = false

    /// Live blocking UI is on screen; refreshes the blocked re-assert
    /// window.
    var visibleBlocker = false

    /// Live working chrome (spinner/status footer) is on screen.
    var visibleWorking = false

    /// An agent-owned transcript viewer / menu is on screen; freeze the
    /// previous stable state instead of trusting this pass.
    var skipStateUpdate = false

    /// Manifest rule id that matched (diagnostics); nil for the
    /// known-agent idle fallback.
    var matchedRuleID: String?

    /// Region of the matched rule. OSC-region matches (osc_title,
    /// osc_progress) are weaker evidence than screen chrome: titles
    /// outlive processes and spinners keep animating through approval
    /// waits.
    var matchedRuleRegion: String?

    var hasVisibleStateEvidence: Bool {
        switch state {
        case .blocked: return visibleBlocker
        case .working: return visibleWorking
        case .idle: return visibleIdle
        // Terminal task states never count as visible evidence: they
        // always take the slower 3-observation stabilizer path (OSC 133
        // covers the instant local case).
        case .done, .failed: return false
        case .unknown: return false
        }
    }
}

/// Confirmation gate for screen-state changes. Strong visible chrome needs
/// two consistent observations; fallback or weak rules need three. The
/// initial strong classification may commit immediately because discovery
/// itself never emits a notification.
nonisolated struct AgentScreenStateStabilizer: Sendable {
    nonisolated enum Decision: Equatable, Sendable {
        case hold
        case commit(AgentScreenState)
    }

    private var candidateState: AgentScreenState?
    private var candidateCount = 0

    var needsConfirmation: Bool { candidateState != nil }

    mutating func observe(
        current: AgentScreenState,
        classification: AgentClassification
    ) -> Decision {
        if classification.skipStateUpdate || classification.state == current {
            reset()
            return .hold
        }

        let target = classification.state
        if current == .unknown, classification.hasVisibleStateEvidence {
            reset()
            return .commit(target)
        }

        if candidateState == target {
            candidateCount += 1
        } else {
            candidateState = target
            candidateCount = 1
        }

        let requiredCount = classification.hasVisibleStateEvidence ? 2 : 3
        guard candidateCount >= requiredCount else { return .hold }
        reset()
        return .commit(target)
    }

    mutating func reset() {
        candidateState = nil
        candidateCount = 0
    }
}

// MARK: - OSC progress activity

/// Live pane activity pushed by OSC 9;4. This is deliberately separate from
/// screen-based agent/task detection: progress is authoritative while present,
/// has no identity of its own, and must disappear without disturbing the
/// detector state underneath it.
nonisolated struct OSCProgressActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case working
        case paused
        case failed

        var status: AgentAttentionStatus {
            switch self {
            case .working: return .working
            case .paused: return .paused
            case .failed: return .failed
            }
        }
    }

    var phase: Phase
    var progress: UInt8?
    let startedAt: Date
    var stateChangeSeq: UInt64

    var progressText: String? {
        progress.map { "\(min($0, 100))%" }
    }
}

/// Percentage ticks are row-local. Semantic changes also need tab rollups and
/// split-pane child structure to be recomputed.
nonisolated enum OSCProgressActivityChange: Equatable, Sendable {
    case none
    case content
    case semantic
}

// MARK: - Card row state

/// Everything the sidebar agent card needs, published on `TabModel` by
/// the attention center. Changes only on state transitions — never per
/// second; the elapsed label derives in-view from `workingSince`.
nonisolated struct AgentRowState: Equatable, Sendable {
    var status: AgentAttentionStatus

    /// Which detection surface drives this row. Task rows reuse the same
    /// card rendering, sorting, and rollup as agent rows.
    var category: AttentionCategory = .agent

    /// OSC-only fallback rows are presentation state, not a notification
    /// category. Keeping that distinction explicit prevents generic progress
    /// from inheriting agent/task notification policy.
    var isOSCProgressActivity = false

    /// Manifest entry id ("claude", or "pytest" for a task row) when a
    /// known entry drives this row; nil for plain-command rows
    /// (failed/done via OSC 133).
    var agentID: String?
    var agentDisplayName: String?

    /// Quantized progress label for a task row ("40%", "[120/456]"),
    /// bucketed so it changes at most ~10 times per run — the row state
    /// must publish on transitions only, never per output line.
    var taskProgress: String?

    /// Start of the current working stint; preserved across spinner
    /// flicker. Drives the live elapsed label.
    var workingSince: Date?

    /// When the last stint finished; done/failed rows show relative time.
    var finishedAt: Date?

    /// Exit code of the last finished command (OSC 133), when known.
    var exitCode: Int?

    /// Duration of the last finished command (OSC 133), when known.
    var lastDuration: TimeInterval?

    /// Unseen completion/failure/bell: bolder title, full-bright row.
    var unread: Bool = false

    /// Background agents (claude's fleet) still running for this pane.
    /// 0 when none or when the pane isn't working. Changes only when an
    /// agent starts or finishes, so it doesn't break the transition-only
    /// publish rule.
    var backgroundAgentCount: Int = 0

    /// What this agent is working on. Resolved per PANE, so a split shows the
    /// agent's own directory rather than the focused pane's. nil until an
    /// authoritative source reports one — the card collapses the line rather
    /// than guessing. (id=agent-project)
    var project: AgentProjectIdentity?

    /// Global transition sequence at the last state change; the
    /// attention-sort tiebreak (most recently changed first).
    var stateChangeSeq: UInt64 = 0
}
