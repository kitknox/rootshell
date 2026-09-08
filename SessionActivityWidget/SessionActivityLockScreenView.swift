//
//  SessionActivityLockScreenView.swift
//  SessionActivityWidget
//
//  Lock Screen / StandBy presentation for the session Live Activity.
//

import SwiftUI
import WidgetKit

struct SessionActivityLockScreenView: View {
    let state: SessionActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.activityFamily) private var activityFamily

    /// In tinted Liquid Glass the system switches to light color scheme.
    private var isTinted: Bool { colorScheme == .light }

    /// Secondary text — `.secondary` washes out on tinted glass.
    private var subtitleStyle: some ShapeStyle {
        isTinted ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.secondary)
    }

    /// VPN accent — `.green` is unreadable on tinted glass.
    private var vpnAccentStyle: some ShapeStyle {
        isTinted ? AnyShapeStyle(.primary) : AnyShapeStyle(.green)
    }

    /// WiFi accent — `.cyan` is unreadable on tinted glass.
    private var wifiAccentStyle: some ShapeStyle {
        isTinted ? AnyShapeStyle(.primary) : AnyShapeStyle(.cyan)
    }

    /// Network accent — `.blue` is unreadable on tinted glass.
    private var networkAccentStyle: some ShapeStyle {
        isTinted ? AnyShapeStyle(.primary) : AnyShapeStyle(.blue)
    }

    /// Agent accent — `.mint` is unreadable on tinted glass.
    private var agentAccentStyle: AnyShapeStyle {
        isTinted ? AnyShapeStyle(.primary) : AnyShapeStyle(.mint)
    }

    /// Frozen agent counts render muted; same tone as the subtitle.
    private var mutedAgentStyle: AnyShapeStyle {
        AnyShapeStyle(subtitleStyle)
    }

    private var hasVPN: Bool {
        state.vpnStatus != nil
    }

    private var hasSessions: Bool {
        state.sessionCount > 0
    }

    private var hasAgents: Bool {
        state.agentTotalCount > 0
    }

    private var hasWiFiInfo: Bool {
        state.wifiSSID != nil
    }

    private var hasNetworkInfo: Bool {
        state.networkPublicIP != nil || state.networkASName != nil
    }

    // MARK: - Body

    var body: some View {
        if activityFamily == .small {
            watchCompactLayout
        } else {
            ViewThatFits(in: .vertical) {
                fullLayout
                compactLayout
            }
            .padding()
        }
    }

    // MARK: - Shared Sub-views

    @ViewBuilder
    private var titleText: some View {
        if hasSessions {
            Text(
                state.sessionCount == 1
                    ? String(localized: "1 Active Session")
                    : String(localized: "\(state.sessionCount) Active Sessions")
            )
            .font(.headline)
            .foregroundStyle(.primary)
        } else if hasAgents {
            Text(AgentCountsText.agents(state.agentTotalCount))
                .font(.headline)
                .foregroundStyle(.primary)
        } else if hasVPN {
            Text("VPN Connected")
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func sessionBadges(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if state.sshCount > 0 {
                Label("\(state.sshCount) SSH", systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
            if state.k8sCount > 0 {
                Label("\(state.k8sCount) K8s", systemImage: "server.rack")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            if state.consoleCount > 0 {
                Label("\(state.consoleCount) Console", systemImage: "cloud")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            if state.localTaskCount > 0 {
                Label(
                    state.localTaskCount == 1
                        ? String(localized: "1 Task")
                        : String(localized: "\(state.localTaskCount) Tasks"),
                    systemImage: "terminal"
                )
                .font(.caption2)
                .foregroundStyle(.yellow)
            }
            if state.roamCount > 0 {
                Label("\(state.roamCount) Roam", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(vpnAccentStyle)
            }
            if hasAgents {
                Label(AgentCountsText.agents(state.agentTotalCount), systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(state.agentCountsMuted ? mutedAgentStyle : agentAccentStyle)
            }

            Spacer()

            Text(state.lastUpdated, style: .timer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(subtitleStyle)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var vpnTrafficRow: some View {
        HStack(spacing: 10) {
            if let bytesIn = state.vpnBytesIn {
                Label(formatBytes(bytesIn), systemImage: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
            if let bytesOut = state.vpnBytesOut {
                Label(formatBytes(bytesOut), systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let since = state.vpnConnectedSince {
                Text(since, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(vpnAccentStyle)
                    .multilineTextAlignment(.trailing)
            }

            if let conns = state.vpnActiveConnections, conns > 0 {
                Label("\(conns)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(subtitleStyle)
            }
        }
    }

    // MARK: - Full Layout (spacious, used when content fits)

    @ViewBuilder
    private var fullLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: icon + title (ZStack so text centers over full width)
            ZStack {
                HStack {
                    Image(state.appIconDisplayAssetName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }

                titleText
            }

            // Hostnames below the title row
            if !state.hostNames.isEmpty {
                Text(state.hostNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(subtitleStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Session type badges + timer
            if hasSessions || hasAgents {
                sessionBadges(spacing: 8)
            }

            // Agent detail gets the full width. Keeping the attention and
            // frozen-state phrases out of the badge row prevents them from
            // wrapping into several narrow columns beside the timer.
            if hasAgents {
                AgentSummaryLine(state: state, mutedStyle: mutedAgentStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // VPN section — full width below
            if hasVPN {
                if hasSessions || hasAgents {
                    Divider()
                        .background(.primary.opacity(0.3))
                }

                // VPN header: icon+name
                HStack(spacing: 4) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.caption2)
                        .foregroundStyle(vpnAccentStyle)

                    if let name = state.vpnProfileName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }

                if let host = state.vpnHost {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                vpnTrafficRow
            }

            // WiFi & Network section
            if hasWiFiInfo || hasNetworkInfo {
                if hasSessions || hasAgents || hasVPN {
                    Divider()
                        .background(.primary.opacity(0.3))
                }

                // WiFi row: favicon + wifi icon + SSID + optional AP/vendor
                if let ssid = state.wifiSSID {
                    HStack(spacing: 4) {
                        if let wifiFavicon = Self.loadFavicon(.wifiFavicon) {
                            Image(uiImage: wifiFavicon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Image(systemName: "wifi")
                            .font(.caption2)
                            .foregroundStyle(wifiAccentStyle)
                        Text(ssid)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let apName = state.wifiAPName {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                            Text(apName)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                        if let band = state.wifiBand {
                            Text(band)
                                .font(.caption2)
                                .foregroundStyle(wifiAccentStyle)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                // Network row: IP + ISP + country flag
                if hasNetworkInfo {
                    HStack(spacing: 6) {
                        if let ispFavicon = Self.loadFavicon(.ispFavicon) {
                            Image(uiImage: ispFavicon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Image(systemName: "globe")
                                .font(.caption2)
                                .foregroundStyle(networkAccentStyle)
                        }
                        if let ip = state.networkPublicIP {
                            Text(ip)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let asName = state.networkASName {
                            Text(asName)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        if let flag = state.networkCountryFlag {
                            Text(flag)
                                .font(.caption2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Watch Layout (Smart Stack tile on Apple Watch)

    /// Compact layout for the `.small` ActivityFamily used when iOS mirrors
    /// the Live Activity to an Apple Watch Smart Stack tile. Without opting
    /// into this family watchOS renders a default system view that pulls the
    /// primary AppIcon, which fails for the Icon Composer `.solidimagestack`
    /// format and shows a gray box where the icon should be.
    @ViewBuilder
    private var watchCompactLayout: some View {
        HStack(spacing: 8) {
            Image(state.appIconDisplayAssetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .lineLimit(1)

                if !state.hostNames.isEmpty {
                    Text(state.hostNames.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let name = state.vpnProfileName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                } else if let ssid = state.wifiSSID {
                    Text(ssid)
                        .font(.caption2)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                }

                // One agent line, only when the tile has room for it.
                if hasAgents {
                    ViewThatFits(in: .vertical) {
                        AgentSummaryLine(state: state, font: .caption2, mutedStyle: mutedAgentStyle)
                        EmptyView()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Compact Layout (condensed, used when full layout overflows)

    @ViewBuilder
    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Compact header: smaller icon + title with inline hostnames
            ZStack {
                HStack {
                    Image(state.appIconDisplayAssetName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }

                VStack(spacing: 0) {
                    titleText

                    if !state.hostNames.isEmpty {
                        Text(state.hostNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(subtitleStyle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            // Session type badges + timer (tighter spacing)
            if hasSessions || hasAgents {
                sessionBadges(spacing: 6)
            }

            if hasAgents {
                AgentSummaryLine(state: state, font: .caption2, mutedStyle: mutedAgentStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // VPN section — condensed to 2 rows (header+host merged, traffic row)
            if hasVPN {
                if hasSessions || hasAgents {
                    Divider()
                        .background(.primary.opacity(0.3))
                }

                // Merged row: icon + name + host
                HStack(spacing: 4) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.caption2)
                        .foregroundStyle(vpnAccentStyle)

                    if let name = state.vpnProfileName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if let host = state.vpnHost {
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(subtitleStyle)
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(subtitleStyle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                vpnTrafficRow
            }

            // WiFi + Network section
            if hasWiFiInfo || hasNetworkInfo {
                if hasSessions || hasAgents || hasVPN {
                    Divider()
                        .background(.primary.opacity(0.3))
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let ssid = state.wifiSSID {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.caption2)
                                .foregroundStyle(wifiAccentStyle)

                            Text(ssid)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let apName = state.wifiAPName {
                                Text("\u{00B7}")
                                    .font(.caption2)
                                    .foregroundStyle(subtitleStyle)

                                Text(apName)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                            }

                            if let band = state.wifiBand {
                                Text(band)
                                    .font(.caption2)
                                    .foregroundStyle(wifiAccentStyle)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Spacer(minLength: 0)
                        }
                    }

                    if hasNetworkInfo {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.caption2)
                                .foregroundStyle(networkAccentStyle)

                            if let ip = state.networkPublicIP {
                                Text(ip)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            if let asName = state.networkASName {
                                Text("\u{00B7}")
                                    .font(.caption2)
                                    .foregroundStyle(subtitleStyle)

                                Text(asName)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                            }

                            Spacer(minLength: 0)

                            if let flag = state.networkCountryFlag {
                                Text(flag)
                                    .font(.caption2)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    /// Load a favicon from the shared app group container.
    private static func loadFavicon(_ slot: LiveActivityFaviconStore.Slot) -> UIImage? {
        guard let data = LiveActivityFaviconStore.read(slot: slot) else { return nil }
        return UIImage(data: data)
    }
}
