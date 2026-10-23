//
//  SessionActivityWidget.swift
//  SessionActivityWidget
//
//  Live Activity widget showing active non-resilient sessions on the
//  Lock Screen and Dynamic Island.
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Wrapper that applies the light background tint only in clear (dark) mode.
/// In tinted Liquid Glass the system provides its own glass material, so we
/// pass nil to let colorScheme correctly reflect the light appearance.
private struct AdaptiveLockScreenWrapper: View {
    let state: SessionActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.activityFamily) private var activityFamily

    /// While the inbox has rows, the banner leads with them — but only at the
    /// phone's size. The Apple Watch tile keeps its existing single-glance
    /// layout: five rows do not fit in `.small`.
    private var showsInbox: Bool {
        state.usesInboxLayout && activityFamily != .small
    }

    var body: some View {
        Group {
            if showsInbox {
                AgentInboxLockScreenView(state: state)
            } else {
                SessionActivityLockScreenView(state: state)
            }
        }
        // Only the inbox layout changes where a tap lands.
        .widgetURL(state.usesInboxLayout ? AgentInboxLinks.inbox : nil)
        .activityBackgroundTint(colorScheme == .dark ? .black.opacity(0.2) : nil)
        .activitySystemActionForegroundColor(colorScheme == .dark ? .white : nil)
    }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // Lock Screen / StandBy banner (also used for watchOS Smart Stack
            // via the `.small` activity family — the view branches inside).
            AdaptiveLockScreenWrapper(state: context.state)
        } dynamicIsland: { context in
            // `DynamicIslandExpandedContentBuilder` cannot branch, so the two
            // compositions are separate `DynamicIsland` values.
            context.state.usesInboxLayout
                ? Self.agentInboxIsland(context.state)
                : Self.sessionIsland(context.state)
        }
        .supplementalActivityFamilies([.small])
    }

    // MARK: - Session island (unchanged composition)

    private static func sessionIsland(
        _ state: SessionActivityAttributes.ContentState
    ) -> DynamicIsland {
        DynamicIsland {
            // Expanded presentation
            DynamicIslandExpandedRegion(.leading) {
                Image(state.appIconDisplayAssetName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            DynamicIslandExpandedRegion(.center) {
                VStack(spacing: 2) {
                    if state.sessionCount > 0 {
                        Text(
                            state.sessionCount == 1
                                ? String(localized: "1 Active Session")
                                : String(localized: "\(state.sessionCount) Active Sessions")
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                    } else if state.agentTotalCount > 0 {
                        Text(AgentCountsText.agents(state.agentTotalCount))
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                    if !state.hostNames.isEmpty {
                        Text(state.hostNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Coding agents in expanded center
                    if state.agentTotalCount > 0 {
                        AgentSummaryLine(state: state)
                    }

                    if state.showsInboxBadge {
                        AgentInboxBadgeLine(state: state)
                    }

                    // VPN info in expanded center
                    if state.vpnStatus != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "network.badge.shield.half.filled")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            if let name = state.vpnProfileName {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .lineLimit(1)
                            }
                        }
                    }

                    // WiFi + Network info in expanded center
                    if state.wifiSSID != nil || state.networkASName != nil {
                        HStack(spacing: 4) {
                            if let ssid = state.wifiSSID {
                                Image(systemName: "wifi")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                                Text(ssid)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let apName = state.wifiAPName {
                                    Text("\u{00B7}")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(apName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                            }
                            if let asName = state.networkASName {
                                if state.wifiSSID != nil {
                                    Text("\u{00B7}")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "globe")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Text(asName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            DynamicIslandExpandedRegion(.trailing) {
                VStack(spacing: 2) {
                    if state.sshCount > 0 {
                        Label("\(state.sshCount)", systemImage: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    if state.k8sCount > 0 {
                        Label("\(state.k8sCount)", systemImage: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if state.consoleCount > 0 {
                        Label("\(state.consoleCount)", systemImage: "cloud")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    if state.localTaskCount > 0 {
                        Label("\(state.localTaskCount)", systemImage: "terminal")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if state.roamCount > 0 {
                        Label("\(state.roamCount)", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if state.agentTotalCount > 0 {
                        Label("\(state.agentTotalCount)", systemImage: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(state.agentCountsFrozen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.mint))
                    }
                }
            }

            DynamicIslandExpandedRegion(.bottom) {
                HStack {
                    // VPN traffic in expanded bottom
                    if let bytesIn = state.vpnBytesIn,
                       let bytesOut = state.vpnBytesOut {
                        HStack(spacing: 8) {
                            Label(
                                ByteCountFormatter.string(fromByteCount: bytesIn, countStyle: .binary),
                                systemImage: "arrow.down"
                            )
                            .font(.caption2)
                            .foregroundStyle(.cyan)

                            Label(
                                ByteCountFormatter.string(fromByteCount: bytesOut, countStyle: .binary),
                                systemImage: "arrow.up"
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }

                    // Public IP when no VPN traffic shown
                    if let ip = state.networkPublicIP, state.vpnBytesIn == nil {
                        Text(ip)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.blue)
                    }

                    Spacer()

                    Text(state.lastUpdated, style: .timer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } compactLeading: {
            Image(state.appIconDisplayAssetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } compactTrailing: {
            HStack(spacing: 2) {
                if state.showsInboxBadge {
                    AgentInboxCompactBadge(state: state)
                }
                if state.agentAttentionCount > 0 {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.caption2)
                        .foregroundStyle(state.agentCountsFrozen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    Text("\(state.agentAttentionCount)")
                        .font(.caption)
                        .foregroundStyle(state.agentCountsFrozen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                if state.wifiSSID != nil {
                    Image(systemName: "wifi")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
                if state.vpnStatus != nil {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if state.sessionCount > 0 {
                    Text("\(state.sessionCount)")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
        } minimal: {
            Image(state.appIconDisplayAssetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Agent inbox island

    /// One island for every agent: three rows newest-first, a
    /// folded "N more" line, and the bulk action. The island cannot scroll,
    /// so the fourth event never gets its own row.
    private static func agentInboxIsland(
        _ state: SessionActivityAttributes.ContentState
    ) -> DynamicIsland {
        let newest = state.agentInboxMostRecent?.agent ?? ""

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: AgentInboxMark.symbol(for: newest))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentInboxMark.tint(for: newest))
            }

            DynamicIslandExpandedRegion(.center) {
                AgentInboxExpandedHeader(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DynamicIslandExpandedRegion(.trailing) {
                // Sessions and VPN keep a word in while the inbox owns the
                // list; these share the header row and cost no height.
                AgentInboxExpandedTrailing(state: state)
            }

            DynamicIslandExpandedRegion(.bottom) {
                AgentInboxExpandedList(state: state)
                    .widgetURL(AgentInboxLinks.inbox)
            }
        } compactLeading: {
            // The agent behind the newest event, in its brand tint.
            AgentInboxCompactLeading(state: state)
        } compactTrailing: {
            // Three status counts only. Session/WiFi/VPN still travel in the
            // expanded trailing region; the compact pill is too narrow to hold
            // both and the counts are the reason the island is up.
            AgentInboxCompactTrailing(state: state)
        } minimal: {
            // Squeezed to a circle by another app's activity: mark plus a
            // corner count, no text.
            AgentInboxMinimal(state: state)
        }
        // The expanded island's default side margins clipped the agent name and
        // the relative time on 6.1" phones. 8pt still keeps the content clear of
        // the rounded corners while giving the rows the width the system allows.
        .contentMargins(.horizontal, 8, for: .expanded)
        // A tap anywhere that is not a row goes to the inbox, including the
        // header and the session/VPN hints; rows keep their own pane links.
        .widgetURL(AgentInboxLinks.inbox)
    }
}
