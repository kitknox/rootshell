//
//  AgentAttentionNotificationRouter.swift
//  rootshell
//
//  Turns agent attention transitions (blocked/done/failed/working) into
//  local notifications per the user's policy. Fed by
//  AgentAttentionCenter's publish pass. Bells are badge-only and never
//  reach this router.
//
//  Delivery discipline:
//   - Screen transitions are already confirmation-gated by
//     AgentScreenStateStabilizer before reaching this router.
//   - Exact semantic event IDs are delivered at most once; distinct real
//     transitions are never hidden by a time-based cooldown.
//   - Suppressed while the pane's tab is selected in a key window and the
//     app is active (the user is already looking at it).
//   - One live notification per pane: the request identifier is the pane's,
//     so a later event replaces the earlier banner instead of stacking, and
//     viewing the pane withdraws it.
//   - Tapping rides the existing .navigateToTerminal deep link
//     (tabID + surfaceID) into the tab + pane.
//
//  Wording lives in AgentNotificationContent, which is pure and tested.
//

import Foundation
import UIKit

/// User policy for agent-attention notifications.
nonisolated enum AgentNotificationPolicy: String, CaseIterable, Codable, Sendable {
    case off
    case blockedOnly
    case blockedAndDone
    case allTransitions

    static let storageKey = "agentNotificationPolicy"

    @MainActor static var current: AgentNotificationPolicy {
        SettingsStore.shared.get(Settings.Notifications.agentPolicy)
    }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "Off", comment: "Agent notification policy: never notify")
        case .blockedOnly:
            return String(localized: "Blocked Only",
                          comment: "Agent notification policy: only when input is needed")
        case .blockedAndDone:
            return String(localized: "Blocked & Finished",
                          comment: "Agent notification policy: input needed, finished, or failed")
        case .allTransitions:
            return String(localized: "All Changes",
                          comment: "Agent notification policy: every status change")
        }
    }

    var detail: String {
        switch self {
        case .off:
            return String(localized: "Never notify about agents.",
                          comment: "Agent notification policy detail: off")
        case .blockedOnly:
            return String(localized: "Notify when an agent needs your input.",
                          comment: "Agent notification policy detail: blocked only")
        case .blockedAndDone:
            return String(localized: "Notify when an agent needs input, finishes, or fails.",
                          comment: "Agent notification policy detail: blocked and finished")
        case .allTransitions:
            return String(localized: "Notify on every agent status change.",
                          comment: "Agent notification policy detail: all transitions")
        }
    }

    var iconName: String {
        switch self {
        case .off: return "bell.slash"
        case .blockedOnly: return "exclamationmark.bubble"
        case .blockedAndDone: return "checkmark.bubble"
        case .allTransitions: return "bell.badge"
        }
    }

    func allows(_ status: AgentAttentionStatus) -> Bool {
        switch self {
        case .off:
            return false
        case .blockedOnly:
            return status == .blocked
        case .blockedAndDone:
            return status == .blocked || status == .done || status == .failed
        case .allTransitions:
            return true
        }
    }
}

/// User policy for task-detection notifications. A separate enum from
/// `AgentNotificationPolicy` — its wording is command-shaped and the two
/// policies evolve independently.
nonisolated enum TaskNotificationPolicy: String, CaseIterable, Codable, Sendable {
    case off
    case blockedOnly
    case blockedAndDone
    case allTransitions

    static let storageKey = "taskNotificationPolicy"

    @MainActor static var current: TaskNotificationPolicy {
        SettingsStore.shared.get(Settings.Notifications.taskPolicy)
    }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "Off", comment: "Task notification policy: never notify")
        case .blockedOnly:
            return String(localized: "Waiting for Input",
                          comment: "Task notification policy: only when a command waits for input")
        case .blockedAndDone:
            return String(localized: "Input & Finished",
                          comment: "Task notification policy: input needed, finished, or failed")
        case .allTransitions:
            return String(localized: "All Changes",
                          comment: "Task notification policy: every status change")
        }
    }

    var detail: String {
        switch self {
        case .off:
            return String(localized: "Never notify about commands.",
                          comment: "Task notification policy detail: off")
        case .blockedOnly:
            return String(localized: "Notify when a command is waiting for your input.",
                          comment: "Task notification policy detail: blocked only")
        case .blockedAndDone:
            return String(localized: "Notify when a command waits for input, finishes, or fails.",
                          comment: "Task notification policy detail: blocked and finished")
        case .allTransitions:
            return String(localized: "Notify on every command status change.",
                          comment: "Task notification policy detail: all transitions")
        }
    }

    var iconName: String {
        switch self {
        case .off: return "bell.slash"
        case .blockedOnly: return "exclamationmark.bubble"
        case .blockedAndDone: return "checkmark.bubble"
        case .allTransitions: return "bell.badge"
        }
    }

    func allows(_ status: AgentAttentionStatus) -> Bool {
        switch self {
        case .off:
            return false
        case .blockedOnly:
            return status == .blocked
        case .blockedAndDone:
            return status == .blocked || status == .done || status == .failed
        case .allTransitions:
            return true
        }
    }
}

@MainActor
enum AgentAttentionNotificationRouter {
    /// One delivery slot per (pane, category): a sudo prompt must not
    /// replace an agent's banner in the pane next door, and each
    /// category's teardown withdraws only its own.
    private struct DeliveryKey: Hashable {
        let pane: UUID
        let category: AttentionCategory
    }

    /// Exact semantic events already handled for each slot. This is the
    /// sole deduplication boundary: a new ID means a real new event.
    private static var handledEvents: [DeliveryKey: AgentAttentionEventHistory] = [:]

    /// Slots with a notification currently outstanding, so withdrawal costs
    /// nothing for the overwhelming majority of panes that never had one.
    private static var delivered: Set<DeliveryKey> = []

    /// Cross-source arbitration with hook pushes: the same (pane, status)
    /// arriving from both sources within `crossSourceWindow` is one event, so
    /// whichever source delivers first wins. Nothing longer-lived, so later
    /// distinct transitions are never hidden by a cooldown.
    private struct SourceKey: Hashable {
        let pane: UUID
        let status: AgentAttentionStatus
    }
    private static var externalDelivered: [SourceKey: Date] = [:]
    private static var localDelivered: [SourceKey: Date] = [:]
    static let crossSourceWindow: TimeInterval = 90

    static func externalEventDelivered(pane: UUID, status: AgentAttentionStatus, at date: Date = Date()) {
        let key = SourceKey(pane: pane, status: status)
        externalDelivered[key] = max(externalDelivered[key] ?? .distantPast, date)
    }

    static func shouldSuppressExternal(pane: UUID, status: AgentAttentionStatus, now: Date = Date()) -> Bool {
        guard let at = localDelivered[SourceKey(pane: pane, status: status)] else { return false }
        return now.timeIntervalSince(at) < crossSourceWindow
    }

    private static func hookCovers(pane: UUID, status: AgentAttentionStatus, now: Date = Date()) -> Bool {
        guard let at = externalDelivered[SourceKey(pane: pane, status: status)] else { return false }
        return now.timeIntervalSince(at) < crossSourceWindow
    }

    // MARK: - Transitions

    static func paneTransitioned(
        old: AgentAttentionEvent?,
        new: AgentAttentionEvent?,
        monitor: AgentPaneMonitor
    ) {
        // First classification (old == nil) is discovery, not a transition;
        // new == nil is the pane going quiet.
        //
        // One exception: a task BLOCKED event. A prompt tracker publishes
        // nothing before its two-scan confirmation commits, so blocked is
        // its first event by construction — the discovery guard swallowed
        // every prompt notification (field repro: apt confirm badged but
        // never notified). The event only exists after the persistence
        // guard, and a waiting prompt is news whether or not we watched
        // it appear. Agent discovery stays guarded: reattaching to a
        // screen already showing a blocked agent must not re-notify.
        guard let new, new != old else { return }
        if old == nil, !(new.category == .task && new.status == .blocked) { return }
        let allowed = switch new.category {
        case .agent: AgentNotificationPolicy.current.allows(new.status)
        case .task: TaskNotificationPolicy.current.allows(new.status)
        }
        guard allowed else { return }

        let key = DeliveryKey(pane: monitor.paneUUID, category: new.category)
        var history = handledEvents[key] ?? AgentAttentionEventHistory()
        guard history.insertIfNew(new.id) else { return }
        handledEvents[key] = history
        if new.category == .agent, hookCovers(pane: monitor.paneUUID, status: new.status) { return }
        deliver(event: new, monitor: monitor)
    }

    static func paneRemoved(_ paneUUID: UUID) {
        for category in [AttentionCategory.agent, .task] {
            paneRemoved(paneUUID, category: category)
        }
    }

    static func paneRemoved(_ paneUUID: UUID, category: AttentionCategory) {
        let key = DeliveryKey(pane: paneUUID, category: category)
        handledEvents.removeValue(forKey: key)
        withdraw(key)
    }

    /// The user is looking at this pane now, so whatever it was asking has
    /// been answered by their attention. Called from the center's seen pass,
    /// which already runs exactly over the viewed monitors. Every way into
    /// a tab goes through it, so there is no tap handler to keep in sync.
    static func paneViewed(_ paneUUID: UUID) {
        withdraw(DeliveryKey(pane: paneUUID, category: .agent))
        withdraw(DeliveryKey(pane: paneUUID, category: .task))
        PushNotificationRouter.paneViewed(paneUUID)
    }

    static func removeAll() {
        handledEvents.removeAll()
        let outstanding = delivered
        delivered.removeAll()
        guard !outstanding.isEmpty else { return }
        NotificationManager.shared.removeNotifications(
            identifiers: outstanding.map(requestIdentifier(for:)))
    }

    /// One category's teardown (its settings switch turning off).
    static func removeAll(category: AttentionCategory) {
        for key in handledEvents.keys where key.category == category {
            handledEvents.removeValue(forKey: key)
        }
        let outstanding = delivered.filter { $0.category == category }
        delivered.subtract(outstanding)
        guard !outstanding.isEmpty else { return }
        NotificationManager.shared.removeNotifications(
            identifiers: outstanding.map(requestIdentifier(for:)))
    }

    private static func withdraw(_ key: DeliveryKey) {
        // The overwhelming majority of panes never notified, so the set
        // membership test is what keeps the per-tick seen pass free.
        guard delivered.remove(key) != nil else { return }
        NotificationManager.shared.removeNotifications(
            identifiers: [requestIdentifier(for: key)])
    }

    /// One identifier per (pane, category), so a newer event REPLACES the
    /// slot's banner rather than stacking a fifth "needs input" beside four
    /// stale ones. Agent identifiers keep their historical form.
    /// Once-per-event delivery is already guaranteed by `handledEvents`;
    /// this identifier only decides what a delivery collides with.
    private static func requestIdentifier(for key: DeliveryKey) -> String {
        switch key.category {
        case .agent: return "agent-attention-pane-\(key.pane.uuidString)"
        case .task: return "task-attention-pane-\(key.pane.uuidString)"
        }
    }

    private static func threadIdentifier(for paneUUID: UUID) -> String {
        "agent-pane-\(paneUUID.uuidString)"
    }

    /// How loudly this event should sort inside the pane's thread.
    private static func relevance(_ status: AgentAttentionStatus) -> Double {
        switch status {
        case .blocked: return 1
        case .failed: return 0.8
        case .done: return 0.5
        case .paused: return 0.3
        case .working, .idle, .unknown: return 0.2
        }
    }

    // MARK: - Delivery

    private static func deliver(event: AgentAttentionEvent, monitor: AgentPaneMonitor) {
        guard let tab = monitor.tab else { return }

        // Not when the user is already looking at it.
        if monitor.isViewedNow() { return }

        let content = AgentNotificationContent.make(context(for: event, monitor: monitor, tab: tab))
        let tabID = tab.id
        let key = DeliveryKey(pane: monitor.paneUUID, category: event.category)

        // Fresh installs: the default policy is live but authorization
        // was never requested. The first real attention event is the
        // contextual moment to ask; deliver on grant.
        if NotificationManager.shared.authorizationStatus == .notDetermined {
            Task { @MainActor in
                guard await NotificationManager.shared.requestPermissions() else { return }
                schedule(content, status: event.status, tabID: tabID, key: key)
            }
            return
        }
        schedule(content, status: event.status, tabID: tabID, key: key)
    }

    private static func schedule(
        _ content: AgentNotificationContent,
        status: AgentAttentionStatus,
        tabID: UUID,
        key: DeliveryKey
    ) {
        // Only a notification that actually reached the system needs
        // withdrawing later; a denied authorization returns nil.
        let identifier = NotificationManager.shared.scheduleAgentNotification(
            title: content.title,
            body: content.body,
            subtitle: content.subtitle,
            tabID: tabID,
            surfaceID: key.pane,
            requestIdentifier: requestIdentifier(for: key),
            threadIdentifier: threadIdentifier(for: key.pane),
            relevanceScore: relevance(status)
        )
        if identifier != nil {
            delivered.insert(key)
            localDelivered[SourceKey(pane: key.pane, status: status)] = Date()
        }
    }

    /// Everything the composer needs, read off the live monitor. All of it
    /// is already resolved for the sidebar card.
    private static func context(
        for event: AgentAttentionEvent,
        monitor: AgentPaneMonitor,
        tab: TabModel
    ) -> AgentNotificationContent.Context {
        if event.category == .task {
            let tracker = monitor.taskTracker
            return AgentNotificationContent.Context(
                status: event.status,
                category: .task,
                // A just-finished task keeps its name (identity clears
                // before the completion publishes).
                agentName: tracker.displayName
                    ?? tracker.finishedDisplayName
                    ?? String(localized: "Command",
                              comment: "Task notification: an unnamed shell command"),
                projectLabel: monitor.project?.label,
                projectBranch: monitor.project?.branch,
                tabTitle: tab.title,
                oscTitle: monitor.terminal?.sessionProvidedTitle,
                connectionInfo: monitor.terminal?.connectionConfig.displayName,
                workingSince: tracker.workingSince,
                finishedAt: tracker.finishedAt,
                lastDuration: tracker.lastDuration,
                exitCode: tracker.exitCode,
                backgroundAgentCount: 0,
                promptSummary: monitor.promptSummary
            )
        }
        return AgentNotificationContent.Context(
            status: event.status,
            // A just-finished agent keeps its name (identity clears before
            // the completion publishes).
            agentName: monitor.agent?.displayName
                ?? monitor.finishedAgentDisplayName
                ?? String(localized: "Command",
                          comment: "Agent notification: a plain shell command, not a known agent"),
            projectLabel: monitor.project?.label,
            projectBranch: monitor.project?.branch,
            tabTitle: tab.title,
            oscTitle: monitor.terminal?.sessionProvidedTitle,
            connectionInfo: monitor.terminal?.connectionConfig.displayName,
            workingSince: monitor.workingSince,
            finishedAt: monitor.finishedAt,
            lastDuration: monitor.lastDuration,
            exitCode: monitor.exitCode,
            backgroundAgentCount: monitor.fleetAgentCount,
            promptSummary: monitor.promptSummary
        )
    }
}
