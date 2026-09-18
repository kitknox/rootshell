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

    var body: some View {
        SessionActivityLockScreenView(state: state)
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
            DynamicIsland {
                // Expanded presentation
                DynamicIslandExpandedRegion(.leading) {
                    Image(context.state.appIconDisplayAssetName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        if context.state.sessionCount > 0 {
                            Text(
                                context.state.sessionCount == 1
                                    ? String(localized: "1 Active Session")
                                    : String(localized: "\(context.state.sessionCount) Active Sessions")
                            )
                            .font(.headline)
                            .foregroundStyle(.white)
                        } else if context.state.agentTotalCount > 0 {
                            Text(AgentCountsText.agents(context.state.agentTotalCount))
                                .font(.headline)
                                .foregroundStyle(.white)
                        }

                        if !context.state.hostNames.isEmpty {
                            Text(context.state.hostNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        // Coding agents in expanded center
                        if context.state.agentTotalCount > 0 {
                            AgentSummaryLine(state: context.state)
                        }

                        // VPN info in expanded center
                        if context.state.vpnStatus != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "network.badge.shield.half.filled")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                if let name = context.state.vpnProfileName {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                }
                            }
                        }

                        // WiFi + Network info in expanded center
                        if context.state.wifiSSID != nil || context.state.networkASName != nil {
                            HStack(spacing: 4) {
                                if let ssid = context.state.wifiSSID {
                                    Image(systemName: "wifi")
                                        .font(.caption2)
                                        .foregroundStyle(.cyan)
                                    Text(ssid)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let apName = context.state.wifiAPName {
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
                                if let asName = context.state.networkASName {
                                    if context.state.wifiSSID != nil {
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
                        if context.state.sshCount > 0 {
                            Label("\(context.state.sshCount)", systemImage: "lock.shield")
                                .font(.caption2)
                                .foregroundStyle(.cyan)
                        }
                        if context.state.k8sCount > 0 {
                            Label("\(context.state.k8sCount)", systemImage: "server.rack")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if context.state.consoleCount > 0 {
                            Label("\(context.state.consoleCount)", systemImage: "cloud")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                        if context.state.localTaskCount > 0 {
                            Label("\(context.state.localTaskCount)", systemImage: "terminal")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        if context.state.roamCount > 0 {
                            Label("\(context.state.roamCount)", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        if context.state.agentTotalCount > 0 {
                            Label("\(context.state.agentTotalCount)", systemImage: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(context.state.agentCountsMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.mint))
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        // VPN traffic in expanded bottom
                        if let bytesIn = context.state.vpnBytesIn,
                           let bytesOut = context.state.vpnBytesOut {
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
                        if let ip = context.state.networkPublicIP, context.state.vpnBytesIn == nil {
                            Text(ip)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.blue)
                        }

                        Spacer()

                        Text(context.state.lastUpdated, style: .timer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(context.state.appIconDisplayAssetName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                HStack(spacing: 2) {
                    if context.state.agentAttentionCount > 0 {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(context.state.agentCountsMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        Text("\(context.state.agentAttentionCount)")
                            .font(.caption)
                            .foregroundStyle(context.state.agentCountsMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    if context.state.wifiSSID != nil {
                        Image(systemName: "wifi")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    if context.state.vpnStatus != nil {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if context.state.sessionCount > 0 {
                        Text("\(context.state.sessionCount)")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                }
            } minimal: {
                Image(context.state.appIconDisplayAssetName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .supplementalActivityFamilies([.small])
    }
}
