//
//  VPNStatusRow.swift
//  rootshell
//
//  Active VPN hero status card and compact disconnected status indicator.
//

import SwiftUI
import NetworkExtension

struct VPNStatusRow: View {
    #if !CHINA_BUILD
    var tailnetStatus: TailnetStatus? = nil
    #endif
    var onRequestDisconnect: (() -> Void)? = nil

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if !CHINA_BUILD
    @Environment(\.openHTTPCapture) private var openHTTPCapture
    #endif
    @State private var vpnManager = VPNManager.shared
    #if !CHINA_BUILD
    @State private var engine = TailnetInAppEngine.shared
    #endif
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var pulseActive = false

    var body: some View {
        if showsHeroCard {
            heroCard
        } else {
            compactStatusRow
        }
    }

    // MARK: - Hero Card (Active / Disconnecting)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                heroIconTile

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(heroTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        statusPill
                    }

                    if let subtitle = heroSubtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if hasMetadataChips {
                        metadataStrip
                            .padding(.top, 2)
                    }
                }
            }
            .hostAddressCopyMenu(
                name: copyMenuName,
                hostname: copyMenuHostname,
                ipAddress: copyMenuIPAddress
            )

            heroActions
        }
        .padding(.vertical, 6)
        .onAppear {
            if !reduceMotion {
                pulseActive = true
            }
        }
        .onChange(of: isConnected) { _, connected in
            if connected && !reduceMotion {
                pulseActive = true
            }
        }
    }

    private var heroIconTile: some View {
        ZStack {
            #if !CHINA_BUILD
            if isTailnet || showsInAppTailnet {
                Image("TailscaleLogo")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: heroSymbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tileTint)
            }
            #else
            Image(systemName: heroSymbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tileTint)
            #endif
        }
        .frame(width: 44, height: 44)
        .background(tileTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            statusBadgeDot
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var statusBadgeDot: some View {
        let strokeColor = sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)
        return ZStack {
            if isConnected && !reduceMotion {
                Circle()
                    .fill(dotColor.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulseActive ? 1.55 : 0.95)
                    .opacity(pulseActive ? 0.0 : 0.7)
                    .animation(.easeOut(duration: 2.0).repeatForever(autoreverses: false), value: pulseActive)
            }
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(strokeColor, lineWidth: 2))
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if isBusy {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.caption2.weight(.semibold))
                    .symbolEffect(.rotate, isActive: true)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(statusPillLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(dotColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(dotColor.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var metadataStrip: some View {
        HStack(spacing: 6) {
            if let since = activeConnectedSince {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(since, style: .timer)
                        .monospacedDigit()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if let badge = transportChipText {
                if activeConnectedSince != nil {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            #if !CHINA_BUILD
            if let ip = tailnetSelfIP {
                if activeConnectedSince != nil || transportChipText != nil {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            #endif
        }
    }

    @ViewBuilder
    private var heroActions: some View {
        if let onRequestDisconnect {
            HStack(spacing: 10) {
                #if !CHINA_BUILD
                if isLocalCapture, let openHTTPCapture {
                    Button {
                        openHTTPCapture()
                    } label: {
                        Label(
                            String(localized: "Open Capture", comment: "VPN active card quick action for Local Capture"),
                            systemImage: "waveform.path.ecg"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                #endif

                Button(role: .destructive, action: onRequestDisconnect) {
                    HStack(spacing: 6) {
                        if vpnManager.status == .disconnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "power")
                        }
                        Text(vpnManager.status == .disconnecting
                             ? String(localized: "Disconnecting…", comment: "VPN hero button while disconnecting")
                             : String(localized: "Disconnect", comment: "VPN hero disconnect button"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.regular)
                .disabled(vpnManager.status == .disconnecting)
            }
        }
    }

    // MARK: - Compact Status Row (Disconnected / Waiting)

    private var compactStatusRow: some View {
        HStack(spacing: 12) {
            #if !CHINA_BUILD
            if showsInAppTailnet {
                heroIconTile
            } else {
                statusDot
            }
            #else
            statusDot
            #endif

            VStack(alignment: .leading, spacing: 2) {
                Text(compactTitle)
                    .font(.headline)
                if let subtitle = compactSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isBusy {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .symbolEffect(.rotate, isActive: true)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 12, height: 12)
    }

    // MARK: - State & Metadata Resolution

    private var showsHeroCard: Bool {
        if vpnManager.status.isActive || vpnManager.status == .disconnecting {
            return true
        }
        #if !CHINA_BUILD
        if showsInAppTailnet && engine.isRunning {
            return true
        }
        #endif
        return false
    }

    private var isConnected: Bool {
        if vpnManager.status.isActive {
            return vpnManager.status == .connected
        }
        #if !CHINA_BUILD
        if showsInAppTailnet {
            return engine.isRunning
        }
        #endif
        return false
    }

    private var activeProfile: ConnectionProfile? {
        guard let id = vpnManager.activeProfileID else { return nil }
        return profileManager.profile(for: id)
    }

    private var isLocalCapture: Bool {
        vpnManager.activeProfileID == VPNDirectProfile.id
    }

    private var activeConnectedSince: Date? {
        if vpnManager.status.isActive {
            return vpnManager.connectedSince
        }
        #if !CHINA_BUILD
        if showsInAppTailnet && engine.isRunning {
            return engine.connectedSince
        }
        #endif
        return nil
    }

    private var heroTitle: String {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            return String(localized: "Tailscale", comment: "VPN hero title for in-app Tailscale")
        }
        if isTailnet {
            return String(localized: "Tailscale", comment: "VPN hero title for whole-device Tailscale")
        }
        #endif
        if let name = vpnManager.activeProfileName, !name.isEmpty {
            return name
        }
        return vpnManager.status.displayString
    }

    private var heroSubtitle: String? {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            if let subtitle = tailnetPeerSubtitle(for: engine.status) {
                return subtitle
            }
            return String(localized: "Tailscale inside rootshell, no VPN", comment: "VPN status subtitle when Tailscale runs in-app")
        }
        if isTailnet {
            if let subtitle = tailnetPeerSubtitle(for: tailnetStatus) {
                return subtitle
            }
            return VPNTailnetProfile.summary()
        }
        #endif
        if isLocalCapture {
            return String(localized: "Local HTTP capture · No remote server", comment: "VPN hero subtitle for Local Capture")
        }
        if let profile = activeProfile {
            return profile.displayString
        }
        if let id = vpnManager.activeProfileID,
           let snapshot = VPNSharedProfileStore.profile(id: id),
           !snapshot.pickerSubtitle.isEmpty {
            return snapshot.pickerSubtitle
        }
        return nil
    }

    #if !CHINA_BUILD
    private func tailnetPeerSubtitle(for status: TailnetStatus?) -> String? {
        guard let status, let tailnet = status.tailnet, !tailnet.isEmpty else { return nil }
        let peers = status.peers ?? []
        let totalCount = status.peersTotal ?? peers.count
        guard totalCount > 0 else { return tailnet }
        // Only show an exact online count when the returned peer list isn't truncated.
        if let total = status.peersTotal, total > peers.count {
            return String(localized: "\(tailnet) · \(total) devices", comment: "Tailscale subtitle when peer list is truncated")
        }
        let onlineCount = peers.filter(\.online).count
        return String(localized: "\(tailnet) · \(onlineCount)/\(peers.count) online", comment: "Tailscale subtitle with tailnet and exact online peers")
    }
    #endif

    private var transportChipText: String? {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            return nil
        }
        if isTailnet {
            return String(localized: "Whole Device", comment: "VPN transport badge for whole-device Tailscale")
        }
        #endif
        if let label = vpnManager.statistics?.displayTransportLabel {
            return label
        }
        if let profile = activeProfile {
            return profile.vpnTransportName
        }
        return nil
    }

    private var hasMetadataChips: Bool {
        if activeConnectedSince != nil || transportChipText != nil { return true }
        #if !CHINA_BUILD
        if tailnetSelfIP != nil { return true }
        #endif
        return false
    }

    #if !CHINA_BUILD
    private var effectiveTailnetStatus: TailnetStatus? {
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            return engine.status
        }
        if isTailnet {
            return tailnetStatus
        }
        return nil
    }

    private var tailnetSelfIP: String? {
        effectiveTailnetStatus?.selfNode?.ips?.first
    }
    #endif

    private var copyMenuName: String? {
        #if !CHINA_BUILD
        if let node = effectiveTailnetStatus?.selfNode {
            return node.displayName
        }
        #endif
        return activeProfile?.name
    }

    private var copyMenuHostname: String? {
        #if !CHINA_BUILD
        if let dns = effectiveTailnetStatus?.selfNode?.dnsName, !dns.isEmpty {
            return dns
        }
        #endif
        return activeProfile?.sshConfig.host
    }

    private var copyMenuIPAddress: String? {
        #if !CHINA_BUILD
        if let ip = tailnetSelfIP, !ip.isEmpty {
            return ip
        }
        #endif
        return nil
    }

    private var statusPillLabel: String {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            return String(localized: "rootshell Only", comment: "VPN hero badge when Tailscale runs in-app")
        }
        #endif
        return vpnManager.status.displayString
    }

    private var heroSymbolName: String {
        if isLocalCapture {
            return "waveform.path.ecg"
        }
        if let profile = activeProfile {
            return profile.connectionProtocol.iconName
        }
        return "lock.shield.fill"
    }

    private var tileTint: Color {
        switch vpnManager.status {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .orange
        case .disconnecting:
            return .yellow
        default:
            #if !CHINA_BUILD
            if showsInAppTailnet && engine.isRunning {
                return .green
            }
            #endif
            return Color.accentColor
        }
    }

    private var compactTitle: String {
        #if !CHINA_BUILD
        if showsInAppTailnet { return inAppTitle }
        #endif
        return vpnManager.status.displayString
    }

    private var compactSubtitle: String? {
        #if !CHINA_BUILD
        if showsInAppTailnet {
            return String(localized: "Tailscale inside rootshell, no VPN", comment: "VPN status subtitle when Tailscale runs in-app")
        }
        #endif
        guard vpnManager.status.isActive else { return nil }
        return vpnManager.activeProfileName
    }

    private var isBusy: Bool {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            return engine.isStarted && engine.status?.isRunning != true && engine.status?.needsLogin != true
        }
        #endif
        return vpnManager.status == .connecting || vpnManager.status == .reasserting
    }

    #if !CHINA_BUILD
    private var isTailnet: Bool {
        (vpnManager.status.isActive || vpnManager.status == .disconnecting)
            && vpnManager.activeProfileID == VPNTailnetProfile.id
    }

    /// No VPN is up, but Tailscale runs inside rootshell; show that instead of
    /// a bare "Disconnected".
    private var showsInAppTailnet: Bool {
        guard !vpnManager.status.isActive && vpnManager.status != .disconnecting else { return false }
        let mode = TailnetModeSettings.load()
        return mode.effectiveMode == .rootshellOnly && (mode.inAppEnabled || engine.isStarted)
    }

    private var inAppTitle: String {
        guard engine.isStarted else {
            return String(localized: "Tailscale on, starts when needed", comment: "VPN status: in-app Tailscale waiting for first use")
        }
        switch engine.status?.state {
        case "Running": return String(localized: "Tailscale connected", comment: "VPN status: in-app Tailscale running")
        case "NeedsLogin": return String(localized: "Tailscale needs sign-in", comment: "VPN status: in-app Tailscale needs login")
        case "NeedsMachineAuth": return String(localized: "Tailscale waiting for approval", comment: "VPN status: in-app Tailscale awaiting admin")
        default: return String(localized: "Tailscale connecting…", comment: "VPN status: in-app Tailscale starting")
        }
    }
    #endif

    private var dotColor: Color {
        #if !CHINA_BUILD
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting && showsInAppTailnet {
            guard engine.isStarted else { return .gray }
            if engine.status?.isRunning == true { return .green }
            return .orange
        }
        #endif
        return statusColor
    }

    private var statusColor: Color {
        switch vpnManager.status {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .orange
        case .disconnecting:
            return .yellow
        case .disconnected, .invalid:
            return .gray
        @unknown default:
            return .gray
        }
    }
}
