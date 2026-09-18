//
//  AgentCountsViews.swift
//  SessionActivityWidget
//
//  Coding-agent counters for the session Live Activity: localized phrases
//  and the summary line shared by the Dynamic Island and the watch tile.
//

import SwiftUI
import WidgetKit

/// Complete localized phrases for agent counts. Each is a whole phrase, not
/// a number glued to a status word, so translators can reorder or inflect.
enum AgentCountsText {
    static func agents(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 Agent")
            : String(localized: "\(count) Agents")
    }

    static func needAttention(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 needs attention")
            : String(localized: "\(count) need attention")
    }

    static func working(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 working")
            : String(localized: "\(count) working")
    }

    static func idle(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 idle")
            : String(localized: "\(count) idle")
    }

    static var updatesPaused: String {
        String(localized: "Updates paused")
    }

    /// Time of the last agent hook push applied while detection was paused.
    static func updatedAt(_ date: Date) -> String {
        String(localized: "Updated \(date.formatted(date: .omitted, time: .shortened))")
    }
}

/// "1 needs attention · 2 working · 1 idle", most urgent first, zero buckets
/// omitted, with a dot colored by the worst bucket. Muted, with "Updates
/// paused" appended, while the counts are a background snapshot.
struct AgentSummaryLine: View {
    let state: SessionActivityAttributes.ContentState
    var font: Font = .caption
    /// Muted tone for frozen text; `.secondary` washes out on tinted glass,
    /// so the Lock Screen passes its own.
    var mutedStyle: AnyShapeStyle = AnyShapeStyle(.secondary)

    private var segments: [String] {
        var parts: [String] = []
        if state.agentAttentionCount > 0 {
            parts.append(AgentCountsText.needAttention(state.agentAttentionCount))
        }
        if state.agentWorkingCount > 0 {
            parts.append(AgentCountsText.working(state.agentWorkingCount))
        }
        if state.agentIdleCount > 0 {
            parts.append(AgentCountsText.idle(state.agentIdleCount))
        }
        if let pushedAt = state.agentPushUpdatedAt, state.agentCountsFrozen {
            parts.append(AgentCountsText.updatedAt(pushedAt))
        } else if state.agentCountsFrozen {
            parts.append(AgentCountsText.updatesPaused)
        }
        return parts
    }

    private var dotStyle: AnyShapeStyle {
        if state.agentCountsMuted { return mutedStyle }
        if state.agentAttentionCount > 0 { return AnyShapeStyle(.orange) }
        if state.agentWorkingCount > 0 { return AnyShapeStyle(.green) }
        return mutedStyle
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotStyle)
                .frame(width: 6, height: 6)
            Text(segments.joined(separator: " \u{00B7} "))
                .font(font)
                .foregroundStyle(state.agentCountsMuted ? mutedStyle : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
        }
    }
}
