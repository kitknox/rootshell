//
//  PanePresentationState.swift
//  rootshell
//
//  Pane-scoped display identity and coding-agent state shared by the split
//  chrome and the vertical tab sidebar.
//

import Foundation
import Observation

/// Lightweight global revision counter bumped whenever any pane's project
/// grouping inputs (`projectForGrouping` or `agentRow != nil`) change.
/// Lets `TabsModel.navigationSnapshot()` validate its cache in O(1) instead of
/// rebuilding a `[String]` across all visible tabs on every read, while still
/// keeping SwiftUI Observation tracking intact.
@MainActor
@Observable
final class ProjectGroupingClock {
    static let shared = ProjectGroupingClock()
    private(set) var revision: UInt64 = 0

    func bump() {
        revision &+= 1
    }
}

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
    var detectedAgentRow: AgentRowState? {
        didSet {
            if oldValue?.project != detectedAgentRow?.project || (oldValue != nil) != (detectedAgentRow != nil) {
                ProjectGroupingClock.shared.bump()
            }
        }
    }
    /// Herdr owns a reported agent's status; ordinary commands retain OSC activity.
    var usesHerdrStatus = false

    /// Free multiplexer metadata is useful even for an ordinary shell, or
    /// when coding-agent detection is disabled. It does not create an agent row.
    var reportedProject: AgentProjectIdentity? {
        didSet {
            if oldValue != reportedProject {
                ProjectGroupingClock.shared.bump()
            }
        }
    }

    /// The pane's shell at a prompt, or the program in the foreground.
    var foregroundProgram: ForegroundProgram? {
        didSet {
            if oldValue?.showsRunningCard != foregroundProgram?.showsRunningCard {
                ProjectGroupingClock.shared.bump()
            }
        }
    }

    /// When the current non-shell program took the foreground, set only once
    /// it has stayed long enough for a Running card.
    var foregroundProgramCardSince: Date? {
        didSet {
            if (oldValue != nil) != (foregroundProgramCardSince != nil) {
                ProjectGroupingClock.shared.bump()
            }
        }
    }

    var projectForGrouping: AgentProjectIdentity? {
        AgentProjectIdentity.forGrouping(reported: reportedProject, detected: detectedAgentRow?.project)
    }

    /// Latest live OSC 9;4 activity. Percentage-only mutations stay scoped to
    /// this pane's row; semantic edges are separately rolled up by the center.
    private(set) var oscProgressActivity: OSCProgressActivity? {
        didSet {
            if (oldValue != nil) != (oscProgressActivity != nil) {
                ProjectGroupingClock.shared.bump()
            }
        }
    }

    /// Pane-local attention rollup, including plain command completions and
    /// generic OSC progress. Live OSC state is authoritative until cleared,
    /// except over a detected blocker.
    var attentionStatus: AgentAttentionStatus? {
        if usesHerdrStatus { return detectedAgentRow?.status ?? detectedAttentionStatus }
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
        if usesHerdrStatus { return detectedAgentRow }
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

        guard let activity = oscProgressActivity else { return foregroundProgramRow }
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

    /// `.unknown` keeps the card out of the attention ladder: it never wins a
    /// rollup or a sort, and `attentionStatus` stays nil, so no tab dot.
    private var foregroundProgramRow: AgentRowState? {
        guard let since = foregroundProgramCardSince,
              let program = foregroundProgram, program.showsRunningCard else { return nil }
        return AgentRowState(
            status: .unknown,
            isForegroundProgram: true,
            agentID: program.entry?.id ?? program.name,
            agentDisplayName: program.displayName,
            workingSince: since,
            project: reportedProject
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
