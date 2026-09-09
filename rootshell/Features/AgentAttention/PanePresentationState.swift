//
//  PanePresentationState.swift
//  rootshell
//
//  Pane-scoped display identity and coding-agent state shared by the split
//  chrome and the vertical tab sidebar.
//

import Foundation
import Observation

/// Live presentation state for one split leaf.
///
/// A tab can contain multiple panes, so title and agent identity cannot be
/// faithfully represented by a single value on `TabModel`. Each
/// `SplitPaneView` owns one stable instance; consumers observe only the pane
/// they render, keeping animated terminal titles and agent transitions local.
@MainActor
@Observable
final class PanePresentationState {
    let paneID: UUID

    /// Resolved user-facing pane title. Never intentionally empty.
    var title: String

    /// Detector-owned state. OSC progress is layered over this rather than
    /// replacing it, so clearing progress restores the exact prior card.
    var detectedAttentionStatus: AgentAttentionStatus?
    var detectedAgentRow: AgentRowState?

    /// Latest live OSC 9;4 activity. Percentage-only mutations stay scoped to
    /// this pane's row; semantic edges are separately rolled up by the center.
    private(set) var oscProgressActivity: OSCProgressActivity?

    /// Pane-local attention rollup, including plain command completions and
    /// generic OSC progress. Live OSC state is authoritative until cleared,
    /// except over a detected blocker.
    var attentionStatus: AgentAttentionStatus? {
        if isDetectedBlocked { return .blocked }
        if let oscProgressActivity {
            return oscProgressActivity.phase.status
        }
        if let detectedAgentRow {
            return detectedAgentRow.status
        }
        return detectedAttentionStatus
    }

    /// A pane the detector says cannot move without the user. Agents leave
    /// their OSC 9;4 progress report up for the whole turn, approval waits
    /// included — copilot's URL-approval dialog is on screen in device
    /// capture 26B37CC3 (2026-07-31T15:02:23Z) with progress still reporting
    /// `4;3` (indeterminate) — so letting progress win would repaint a
    /// correctly detected "Needs input" as Working in the card, the tab badge
    /// and the rollup, while the notification said otherwise.
    ///
    /// Only blocked is protected. A progress report arriving after a
    /// completion legitimately means new work started, and an OSC-reported
    /// failure is agent-authored evidence that outranks a screen guess.
    private var isDetectedBlocked: Bool {
        detectedAgentRow?.status == .blocked || detectedAttentionStatus == .blocked
    }

    /// Full sidebar card state. OSC progress enriches detected rows, or
    /// supplies a generic Activity row when no detector owns the pane.
    var agentRow: AgentRowState? {
        if var row = detectedAgentRow {
            if let activity = oscProgressActivity, row.status != .blocked {
                row.status = activity.phase.status
                row.stateChangeSeq = activity.stateChangeSeq
                if let progressText = activity.progressText {
                    row.taskProgress = progressText
                }
                if row.workingSince == nil {
                    row.workingSince = activity.startedAt
                }
            }
            return row
        }

        guard let activity = oscProgressActivity else { return nil }
        return AgentRowState(
            status: activity.phase.status,
            isOSCProgressActivity: true,
            agentID: "osc-progress",
            agentDisplayName: String(localized: "Activity"),
            taskProgress: activity.progressText,
            workingSince: activity.phase == .failed ? nil : activity.startedAt,
            stateChangeSeq: activity.stateChangeSeq
        )
    }

    init(paneID: UUID, title: String = "Terminal") {
        self.paneID = paneID
        self.title = title
    }

    /// Apply a normalized OSC progress state. The caller supplies the global
    /// transition sequence only for semantic changes, keeping percentage ticks
    /// out of attention-sort churn.
    func applyOSCProgress(
        phase: OSCProgressActivity.Phase?,
        progress: UInt8?,
        now: Date,
        nextSequence: () -> UInt64
    ) -> OSCProgressActivityChange {
        guard let phase else {
            guard oscProgressActivity != nil else { return .none }
            oscProgressActivity = nil
            return .semantic
        }

        let clampedProgress = progress.map { min($0, 100) }
        guard var current = oscProgressActivity else {
            oscProgressActivity = OSCProgressActivity(
                phase: phase,
                progress: clampedProgress,
                startedAt: now,
                stateChangeSeq: nextSequence()
            )
            return .semantic
        }

        if current.phase != phase {
            current.phase = phase
            current.progress = clampedProgress
            current.stateChangeSeq = nextSequence()
            oscProgressActivity = current
            return .semantic
        }

        guard current.progress != clampedProgress else { return .none }
        current.progress = clampedProgress
        oscProgressActivity = current
        return .content
    }
}
