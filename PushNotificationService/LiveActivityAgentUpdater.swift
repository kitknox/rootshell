//
//  LiveActivityAgentUpdater.swift
//  PushNotificationService
//
//  Applies an agent hook push (rootshell-notify: blocked / done / failed) to
//  the session Live Activity while the app is backgrounded. The app leaves
//  its per-pane agent census in the app group on the background edge
//  (`AgentActivityLedger`); a matching push moves that pane to "needs
//  attention" and the counts are republished from here. No ledger means the
//  app is in the foreground, which clears the file, or never showed agents.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import RootshellPushKit
import os

// The extension's default isolation is the main actor; this runs on the
// system queue and on a detached task, so opt out like NotificationService.
nonisolated enum LiveActivityAgentUpdater {
    private static let logger = Logger(subsystem: "com.rootshell", category: "PushNSE.liveActivity")

    /// Whether `apply` would do anything for this header, cheap enough to
    /// decide before paying for the wait in the delivery path.
    static func handles(_ header: PushHeader) -> Bool {
        header.kind == "agent" && AgentActivityLedger.bucket(forPushStatus: header.status) != nil
    }

    static func apply(header: PushHeader, eid: String) async {
        guard handles(header) else { return }
        let store = AgentActivityLedgerStore()

        // One locked read-modify-write; a repeat of an already-applied push
        // still republishes, so a redelivery repairs an update the first
        // delivery did not get to finish.
        var matched = false
        guard let ledger = store.modify({ ledger in
            guard ledger.matchIndex(for: header.route) != nil else { return false }
            matched = true
            return ledger.apply(status: header.status, route: header.route)
        }), matched else {
            logger.info("push not in ledger eid=\(eid, privacy: .public)")
            return
        }

        // Only the activity the snapshot was taken for, and only while it is
        // still frozen: an unfrozen state means the app is publishing from
        // live detection and this snapshot is stale.
        guard let activity = Activity<SessionActivityAttributes>.activities.first(where: { $0.id == ledger.activityID }) else {
            logger.info("ledger activity gone eid=\(eid, privacy: .public); clearing ledger")
            store.clear()
            return
        }
        var state = activity.content.state
        guard state.agentCountsFrozen else {
            logger.info("activity not frozen eid=\(eid, privacy: .public); app owns the counts")
            return
        }
        state.agentWorkingCount = ledger.workingCount
        state.agentAttentionCount = ledger.attentionCount
        state.agentIdleCount = ledger.idleCount
        state.agentPushUpdatedAt = ledger.pushUpdatedAt ?? state.agentPushUpdatedAt
        await activity.update(
            ActivityContent(state: state, staleDate: nil),
            alertConfiguration: nil,
            timestamp: Date())
        logger.info("live activity updated eid=\(eid, privacy: .public): attention=\(ledger.attentionCount) working=\(ledger.workingCount) idle=\(ledger.idleCount)")
    }
}
#endif
