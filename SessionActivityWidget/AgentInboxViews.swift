//
//  AgentInboxViews.swift
//  SessionActivityWidget
//
//  "Agent inbox" presentation for the session Live Activity: the same island
//  aggregates every agent's unread hook notifications instead of opening one
//  activity per agent or per message.
//
//  Privacy option A is enforced by the data, not by the view: `AgentInboxItem`
//  has no title and no body, so there is nothing here that could render one.
//  The island answers "which agent, what state, how long ago"; the message is
//  only readable after tapping through to its pane.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Copy

/// Complete localized phrases. A number glued to a status word cannot be
/// translated; these are whole sentences with the count interpolated.
enum AgentInboxText {
    static func unread(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 unread")
            : String(localized: "\(count) unread")
    }

    static func agents(_ count: Int) -> String {
        // Reuses the existing "%lld Agents" catalog entries rather than adding
        // a second, differently-capitalized copy of the same phrase.
        AgentCountsText.agents(count)
    }

    static func more(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 more")
            : String(localized: "\(count) more")
    }

    /// What the agent is doing, without saying what about.
    static func status(_ raw: String) -> String? {
        switch AgentInboxStatus(raw: raw) {
        case .blocked: return String(localized: "Needs your input")
        case .done: return String(localized: "Finished")
        case .failed: return String(localized: "Failed")
        case .other: return nil
        }
    }

    static var markAllRead: String { String(localized: "Mark All as Read") }

    static func displayName(for agent: String) -> String {
        let name = AgentInboxMark.displayName(for: agent)
        return name.isEmpty ? String(localized: "Agent") : name
    }
}

// MARK: - Agent identity

/// The agent's mark and colour, as the island can afford it.
///
/// The main app draws full-colour product logos from its own asset catalog;
/// that catalog is not in this extension's bundle, so the island uses a
/// monochrome symbol tinted with the agent's brand colour — which is also what
/// the 62pt compact slot wants.
enum AgentInboxMark {
    /// Manifest agent id → SF Symbol. Unknown ids fall back to a terminal,
    /// never to a blank box: the manifest can be replaced at runtime.
    static func symbol(for agent: String) -> String {
        switch agent {
        case "claude":              return "sparkles"
        case "codex":               return "chevron.left.forwardslash.chevron.right"
        case "copilot":             return "airplane.circle"
        case "cursor":              return "cursorarrow.rays"
        case "pi":                  return "function"
        case "omp":                 return "circle.hexagongrid"
        case "opencode":            return "curlybraces"
        case "agy":                 return "atom"
        case "helix":               return "waveform.path"
        case "vim":                 return "text.cursor"
        case "hermes":              return "bolt.horizontal"
        case "dsh":                 return "brain"
        default:                    return "terminal"
        }
    }

    /// Brand-ish tints, muted enough to sit next to `.secondary` text.
    static func tint(for agent: String) -> Color {
        switch agent {
        case "claude":    return Color(.sRGB, red: 0.85, green: 0.47, blue: 0.34, opacity: 1)
        case "codex":     return Color(.sRGB, red: 0.06, green: 0.64, blue: 0.50, opacity: 1)
        case "copilot":   return Color(.sRGB, red: 0.35, green: 0.78, blue: 0.98, opacity: 1)
        case "cursor":    return Color(.sRGB, red: 0.42, green: 0.60, blue: 0.96, opacity: 1)
        case "pi":        return Color(.sRGB, red: 0.63, green: 0.47, blue: 0.96, opacity: 1)
        case "omp":       return Color(.sRGB, red: 0.55, green: 0.45, blue: 0.92, opacity: 1)
        case "opencode":  return Color(.sRGB, red: 0.90, green: 0.62, blue: 0.28, opacity: 1)
        case "agy":       return Color(.sRGB, red: 0.45, green: 0.72, blue: 1.00, opacity: 1)
        case "helix":     return Color(.sRGB, red: 0.96, green: 0.45, blue: 0.62, opacity: 1)
        case "vim":       return Color(.sRGB, red: 0.34, green: 0.78, blue: 0.44, opacity: 1)
        case "hermes":    return Color(.sRGB, red: 0.96, green: 0.70, blue: 0.30, opacity: 1)
        case "dsh":       return Color(.sRGB, red: 0.30, green: 0.42, blue: 0.99, opacity: 1)
        default:          return .secondary
        }
    }

    /// Product names are proper nouns and are not localized.
    static func displayName(for agent: String) -> String {
        switch agent {
        case "claude":   return "Claude"
        case "codex":    return "Codex"
        case "copilot":  return "Copilot"
        case "cursor":   return "Cursor"
        case "pi":       return "Pi"
        case "omp":      return "oh-my-pi"
        case "opencode": return "opencode"
        case "agy":      return "Antigravity"
        case "helix":    return "Helix"
        case "vim":      return "Vim"
        case "hermes":   return "Hermes"
        case "dsh":      return "DeepSeek"
        default:         return agent.isEmpty ? "" : agent.capitalized
        }
    }

    /// The status dot: amber for act-now, red for broken, emerald for a
    /// finished-and-unread hook, mirroring the app's attention vocabulary.
    static func statusTint(_ raw: String) -> AnyShapeStyle {
        switch AgentInboxStatus(raw: raw) {
        case .blocked: return AnyShapeStyle(.orange)
        case .failed:  return AnyShapeStyle(.red)
        case .done:    return AnyShapeStyle(.green)
        case .other:   return AnyShapeStyle(.secondary)
        }
    }
}

// MARK: - Badge

enum AgentInboxBadge {
    /// The count is always visible: "!" alone told the person nothing about how
    /// much is waiting, and made "1 blocked" indistinguishable from "9 blocked".
    /// A blocked inbox adds a warning glyph next to the number instead of
    /// replacing it.
    static func text(_ state: SessionActivityAttributes.ContentState) -> String {
        let unread = state.agentUnreadCount
        return unread > 9 ? "9+" : "\(unread)"
    }

    static func tint(_ state: SessionActivityAttributes.ContentState) -> AnyShapeStyle {
        if state.agentInboxHasBlocked { return AnyShapeStyle(.orange) }
        if state.agentInboxHasFailed { return AnyShapeStyle(.red) }
        if state.agentInboxDoneUnreadCount > 0 { return AnyShapeStyle(.green) }
        return AnyShapeStyle(.white)
    }
}

/// The Unread Count layout's compact mark: a tray and the count, tinted by
/// the most urgent unread status.
struct AgentInboxCompactBadge: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "tray.full.fill")
                .font(.caption2)
            Text(AgentInboxBadge.text(state))
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(AgentInboxBadge.tint(state))
    }
}

/// The Unread Count layout's line in the expanded island and on the Lock Screen.
struct AgentInboxBadgeLine: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.full.fill")
                .font(.caption2)
                .foregroundStyle(AgentInboxBadge.tint(state))
            Text(AgentInboxText.unread(state.agentUnreadCount))
                .font(.caption)
                .lineLimit(1)
        }
    }
}

// MARK: - Rows

/// One agent event: state dot, agent, what state, how long ago, and a chevron.
/// No title, no body — that is the whole point of option A.
struct AgentInboxRow: View {
    let item: AgentInboxItem
    var height: CGFloat = 34
    var titleFont: Font = .caption.weight(.semibold)
    var detailFont: Font = .caption2
    /// `.secondary` washes out on tinted Liquid Glass, so the Lock Screen
    /// passes its own tone in.
    var secondaryStyle: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AgentInboxMark.statusTint(item.status))
                .frame(width: 6, height: 6)

            Text(AgentInboxText.displayName(for: item.agent))
                .font(titleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let status = AgentInboxText.status(item.status) {
                Text("\u{00B7}")
                    .font(detailFont)
                    .foregroundStyle(secondaryStyle)
                Text(status)
                    .font(detailFont)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(item.at, style: .relative)
                .font(detailFont.monospacedDigit())
                .foregroundStyle(secondaryStyle)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryStyle)
        }
        // Full-width so the whole row is the tap target, not just its text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dynamic Island: compact / minimal

struct AgentInboxCompactLeading: View {
    let state: SessionActivityAttributes.ContentState

    /// Follows the icon the person picked inside the app: the widget catalog
    /// carries a frameless copy per variant, so the island never drifts from
    /// the home-screen icon. Unknown variants fall back to the default art.
    static func assetName(for variant: String) -> String {
        guard !variant.isEmpty else { return "AppIconImage" }
        return UIImage(named: variant) != nil ? variant : "AppIconImage"
    }

    var assetName: String { Self.assetName(for: state.appIconVariant) }

    var body: some View {
        // The app's own icon, not an agent mark: the compact island answers
        // "which app wants you", and the agent identity belongs one level in.
        Image(assetName)
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
            )
    }
}

struct AgentInboxCompactTrailing: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 3) {
            if state.agentInboxBlockedUnreadCount > 0 {
                statusCount(state.agentInboxBlockedUnreadCount, tint: .orange)
            }
            if state.agentInboxDoneUnreadCount > 0 {
                statusCount(state.agentInboxDoneUnreadCount, tint: .green)
            }
            if state.agentInboxFailedUnreadCount > 0 {
                statusCount(state.agentInboxFailedUnreadCount, tint: .red)
            }
            if state.agentInboxBlockedUnreadCount == 0,
               state.agentInboxDoneUnreadCount == 0,
               state.agentInboxFailedUnreadCount == 0 {
                Text(AgentInboxBadge.text(state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentInboxBadge.tint(state))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusCount(_ count: Int, tint: Color) -> some View {
        HStack(spacing: 1) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

/// The 36.67pt circle: mark plus a corner count. No text, no title.
struct AgentInboxMinimal: View {
    let state: SessionActivityAttributes.ContentState

    var assetName: String { AgentInboxCompactLeading.assetName(for: state.appIconVariant) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 19, height: 19)
                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(AgentInboxBadge.text(state))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(state.agentInboxHasBlocked
                                   ? AnyShapeStyle(.orange)
                                   : state.agentInboxHasFailed
                                   ? AnyShapeStyle(.red)
                                   : state.agentInboxDoneUnreadCount > 0
                                   ? AnyShapeStyle(.green)
                                   : AnyShapeStyle(.white.opacity(0.25)))
                )
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Dynamic Island: expanded

/// Header for the expanded island: unread total, how many agents, and the
/// compact session/VPN hints the inbox layout would otherwise hide.
struct AgentInboxExpandedHeader: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AgentInboxText.unread(state.agentUnreadCount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // One chip per state the island answers: waiting, finished, broken.
            // Working rows stay in the inbox; a glance cannot act on them.
            if state.agentInboxBlockedUnreadCount > 0
                || state.agentInboxDoneUnreadCount > 0
                || state.agentInboxFailedUnreadCount > 0 {
                HStack(spacing: 6) {
                    if state.agentInboxBlockedUnreadCount > 0 {
                        statusCount(state.agentInboxBlockedUnreadCount,
                                    symbol: "exclamationmark.circle.fill",
                                    tint: .orange,
                                    label: AgentInboxText.status("blocked") ?? "")
                    }
                    if state.agentInboxDoneUnreadCount > 0 {
                        statusCount(state.agentInboxDoneUnreadCount,
                                    symbol: "checkmark.circle.fill",
                                    tint: .green,
                                    label: AgentInboxText.status("done") ?? "")
                    }
                    if state.agentInboxFailedUnreadCount > 0 {
                        statusCount(state.agentInboxFailedUnreadCount,
                                    symbol: "xmark.circle.fill",
                                    tint: .red,
                                    label: AgentInboxText.status("failed") ?? "")
                    }
                }
            } else if state.agentInboxAgentCount > 1 {
                Text(AgentInboxText.agents(state.agentInboxAgentCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func statusCount(_ count: Int, symbol: String, tint: Color, label: String) -> some View {
        Label("\(count)", systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("\(count) \(label)")
    }
}

/// Session/VPN hints kept alive while the island is in inbox mode. They cost
/// no vertical space: they share the header's row.
struct AgentInboxExpandedTrailing: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            if state.sessionCount > 0 {
                Label("\(state.sessionCount)", systemImage: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if state.vpnStatus != nil {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if state.wifiSSID != nil {
                Image(systemName: "wifi")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        }
    }
}

/// Three rows maximum, a fold row, and the bulk action.
///
/// Height: header 20 + 3 × 34 + footer 22 ≈ 144pt. The island cannot scroll,
/// so the fourth event never gets a row — it becomes one line that opens the
/// full list in the app.
struct AgentInboxExpandedList: View {
    let state: SessionActivityAttributes.ContentState

    private var foldedCount: Int { state.agentInboxFoldedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.agentInboxExpandedItems) { item in
                Link(destination: AgentInboxLinks.item(item.id)) {
                    AgentInboxRow(item: item)
                }
                .buttonStyle(.plain)
            }

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if foldedCount > 0 {
                Link(destination: AgentInboxLinks.inbox) {
                    HStack(spacing: 2) {
                        Text(AgentInboxText.more(foldedCount))
                            .font(.caption2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button(intent: AgentInboxMarkAllReadIntent()) {
                Text(AgentInboxText.markAllRead)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 22)
    }
}

/// Lock Screen: a full 160pt card, so it carries two more rows than the island
/// and can afford a one-line header.
///
/// Budget: 20pt header + up to five 18pt lines (rows, one of which becomes the
/// fold line when there is overflow) + spacing ≈ 130pt, inside the card's
/// 160pt with padding. The row limit comes from `ContentState`, so the fold
/// count and the rows drawn can never disagree.
struct AgentInboxLockScreenView: View {
    let state: SessionActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme

    /// In tinted Liquid Glass the system switches to light color scheme.
    private var isTinted: Bool { colorScheme == .light }

    private var subtitleStyle: AnyShapeStyle {
        isTinted ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.secondary)
    }

    private var rows: [AgentInboxItem] { state.agentInboxLockScreenRows }

    private var foldedCount: Int { state.agentInboxLockScreenFoldedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ForEach(rows) { item in
                Link(destination: AgentInboxLinks.item(item.id)) {
                    AgentInboxRow(item: item, height: 18,
                                  titleFont: .caption2.weight(.semibold),
                                  detailFont: .caption2,
                                  secondaryStyle: subtitleStyle)
                }
                .buttonStyle(.plain)
            }

            if foldedCount > 0 {
                Link(destination: AgentInboxLinks.inbox) {
                    HStack(spacing: 2) {
                        Text(AgentInboxText.more(foldedCount))
                            .font(.caption2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(subtitleStyle)
                    .frame(height: 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            let agent = state.agentInboxMostRecent?.agent ?? ""
            Image(systemName: AgentInboxMark.symbol(for: agent))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AgentInboxMark.tint(for: agent))

            Text(AgentInboxText.unread(state.agentUnreadCount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if state.agentInboxBlockedUnreadCount > 0 {
                Label("\(state.agentInboxBlockedUnreadCount)", systemImage: "exclamationmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(state.agentInboxBlockedUnreadCount) \(AgentInboxText.status("blocked") ?? "")")
            }
            if state.agentInboxDoneUnreadCount > 0 {
                Label("\(state.agentInboxDoneUnreadCount)", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(state.agentInboxDoneUnreadCount) \(AgentInboxText.status("done") ?? "")")
            }
            if state.agentInboxFailedUnreadCount > 0 {
                Label("\(state.agentInboxFailedUnreadCount)", systemImage: "xmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(state.agentInboxFailedUnreadCount) \(AgentInboxText.status("failed") ?? "")")
            }

            if state.agentInboxBlockedUnreadCount == 0,
               state.agentInboxDoneUnreadCount == 0,
               state.agentInboxFailedUnreadCount == 0,
               state.agentInboxAgentCount > 1 {
                Text("\u{00B7}")
                    .font(.caption2)
                    .foregroundStyle(subtitleStyle)
                Text(AgentInboxText.agents(state.agentInboxAgentCount))
                    .font(.caption2)
                    .foregroundStyle(subtitleStyle)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Sessions and VPN keep a hint: the inbox took their rows, not
            // their meaning.
            if state.sessionCount > 0 {
                Label("\(state.sessionCount)", systemImage: "terminal")
                    .font(.caption2)
                    .foregroundStyle(subtitleStyle)
            }
            if state.vpnStatus != nil {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.caption2)
                    .foregroundStyle(isTinted ? AnyShapeStyle(.primary) : AnyShapeStyle(.green))
            }

            Button(intent: AgentInboxMarkAllReadIntent()) {
                Text(AgentInboxText.markAllRead)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(subtitleStyle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

}

// MARK: - Mark all read

/// Clears the inbox without bringing the app forward.
///
/// Runs in the widget extension, so it can only update the activity and leave
/// a watermark in the app group; the inbox treats older rows as read.
struct AgentInboxMarkAllReadIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Mark All as Read" }

    /// Not a Shortcuts action; it only exists as this button.
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        AgentInboxReadMarker.markRead()

        for activity in Activity<SessionActivityAttributes>.activities {
            var state = activity.content.state
            // A session or VPN Live Activity must survive "mark all read" —
            // only an inbox-only activity is ended outright.
            let hasOtherContent = state.sessionCount > 0
                || state.vpnStatus != nil
                || state.agentTotalCount > 0
                || state.wifiSSID != nil
                || state.networkPublicIP != nil
                || state.roamCount > 0

            state.agentItems = []
            state.agentUnreadTotal = 0
            state.agentInboxBlockedCount = 0
            state.agentInboxFailedCount = 0
            state.agentInboxDoneCount = 0
            state.agentInboxLayout = ""
            let content = ActivityContent(state: state, staleDate: nil)

            if hasOtherContent {
                await activity.update(content, alertConfiguration: nil, timestamp: Date())
            } else {
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }

        return .result()
    }
}
