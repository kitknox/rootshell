//
//  VPNSettingsView.swift
//  rootshell
//
//  Main VPN management screen in Settings.
//  Mirrors TunnelSettingsView pattern.
//

import SwiftUI
import NetworkExtension
import UIKit

struct VPNSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared
    #if !CHINA_BUILD
    @State private var tailnetEngine = TailnetInAppEngine.shared
    @State private var wholeDeviceTailnetStatus: TailnetStatus?
    @State private var wholeDeviceTailnetStatusGeneration: Int?
    @State private var wholeDeviceTailnetStatusConnectedSince: Date?
    #endif
    private enum DisconnectTarget: Equatable {
        case vpn(generation: Int, profileID: UUID?, profileName: String?)
        #if !CHINA_BUILD
        case inAppTailnet
        #endif
    }

    @State private var profileManager = ConnectionProfileManager.shared
    @State private var vpnConnectionGeneration = 0
    @State private var pendingDisconnect: DisconnectTarget?
    @Environment(\.openHTTPCapture) private var openHTTPCapture

    var body: some View {
        List {
            #if targetEnvironment(macCatalyst) && !STANDALONE
            // No VPN in this build; Tailscale runs inside rootshell.
            tailscaleSection
            #else
            #if !CHINA_BUILD
            quickConnectSection
            #endif
            statusSection
            vpnProfilesSection
            #if !CHINA_BUILD
            tailscaleSection
            autoRecoverySection
            httpCaptureSection
            #endif
            eventHistorySection
            debugSection
            #endif
        }
        .themedList()
        .navigationTitle("VPN")
        #if !CHINA_BUILD
        .onAppear { vpnManager.reloadLastVPN() }
        .task(id: tailnetStatusTaskKey) {
            await pollTailnetStatusIfNeeded()
        }
        #endif
        #if STANDALONE && targetEnvironment(macCatalyst)
        // The launch-time check misses a host that was still rebinding its socket.
        .task { await vpnManager.refreshStatusFromSystem() }
        #endif
        .onChange(of: vpnManager.status) { oldStatus, newStatus in
            if oldStatus.isActive && !newStatus.isActive {
                vpnConnectionGeneration += 1
                if case .vpn = pendingDisconnect {
                    pendingDisconnect = nil
                }
                #if !CHINA_BUILD
                clearWholeDeviceTailnetStatus()
                #endif
            }
            #if !CHINA_BUILD
            if (newStatus.isActive || newStatus == .disconnecting),
               case .inAppTailnet = pendingDisconnect {
                pendingDisconnect = nil
            }
            #endif
        }
        .onChange(of: vpnManager.activeProfileID) { oldID, newID in
            guard oldID != newID else { return }
            vpnConnectionGeneration += 1
            if case .vpn = pendingDisconnect {
                pendingDisconnect = nil
            }
            #if !CHINA_BUILD
            clearWholeDeviceTailnetStatus()
            #endif
        }
        #if !CHINA_BUILD
        .onChange(of: tailnetEngine.isRunning) { _, isRunning in
            if !isRunning, case .inAppTailnet = pendingDisconnect {
                pendingDisconnect = nil
            }
        }
        #endif
        .confirmationDialog(
            disconnectDialogTitle,
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let target = pendingDisconnect {
                    pendingDisconnect = nil
                    disconnect(target)
                }
            }
        } message: {
            Text(disconnectDialogMessage)
        }
    }

    #if !CHINA_BUILD
    // MARK: - Quick Connect

    /// One-tap reconnect to the last VPN, while nothing is connected.
    @ViewBuilder
    private var quickConnectSection: some View {
        if !vpnManager.status.isActive && vpnManager.status != .disconnecting,
           let target = VPNQuickConnectCard.lastTarget() {
            Section {
                VPNQuickConnectCard(target: target)
                    .themedRow()
            }
        }
    }
    #endif

    #if !CHINA_BUILD
    // MARK: - Tailscale Section

    private var tailscaleSection: some View {
        Section {
            NavigationLink {
                TailnetSettingsView()
            } label: {
                HStack {
                    Label {
                        Text(String(localized: "Tailscale", comment: "VPN settings row"))
                    } icon: {
                        Image("TailscaleLogo")
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    }
                    Spacer(minLength: 8)
                    if let state = tailscaleRowState {
                        Text(state).foregroundStyle(.secondary)
                    }
                }
            }
            .themedRow()
        } footer: {
            if TailnetPlatform.supportsWholeDevice {
                Text("Reach your tailnet as a VPN for the whole device, or only inside rootshell so another VPN can stay on.")
            } else {
                Text("Reach your tailnet from rootshell's connections. Tailscale runs inside the app, so other apps aren't affected.")
            }
        }
    }

    /// "On · Whole Device" or "On · rootshell Only"; nil while off.
    private var tailscaleRowState: String? {
        let mode = TailnetModeSettings.load()
        switch mode.effectiveMode {
        case .wholeDevice:
            guard vpnManager.isVPNActive(for: VPNTailnetProfile.id) else { return nil }
            return String(localized: "On · Whole Device", comment: "Tailscale row: VPN mode is on")
        case .rootshellOnly:
            guard mode.inAppEnabled || TailnetInAppEngine.shared.isStarted else { return nil }
            return TailnetPlatform.supportsWholeDevice
                ? String(localized: "On · rootshell Only", comment: "Tailscale row: in-app mode is on")
                : String(localized: "On", comment: "Tailscale VPN is active")
        }
    }
    #endif

    #if !CHINA_BUILD
    // MARK: - Auto Recovery Section

    private var autoRecoverySection: some View {
        Section {
            SettingToggle(Settings.VPN.autoRecovery, title: "Auto Recovery")
                .themedRow()
        } footer: {
            Text("When rootshell opens, reconnect the VPN or Tailscale that was on when it last ran, such as after a restart or an app update. Skipped if another VPN app is connected.")
        }
    }

    // MARK: - HTTP Capture Section

    private var httpCaptureSection: some View {
        Section {
            if let openHTTPCapture {
                Button(String(localized: "Open HTTP Capture", comment: "VPN settings action: close Settings and show the capture panel")) {
                    openHTTPCapture()
                }
                .themedRow()
            }
            NavigationLink {
                CaptureSettingsView()
            } label: {
                HStack {
                    Text(String(localized: "Capture Settings", comment: "VPN settings row"))
                    Spacer(minLength: 8)
                    if CaptureController.shared.isRecording {
                        CaptureStatusText(
                            text: String(localized: "Recording", comment: "HTTP capture session state"),
                            systemImage: "record.circle", color: .red)
                    } else if CaptureCAManager.shared.hasCA {
                        CATrustBadge(state: CaptureCAManager.shared.trust)
                    }
                }
            }
            .themedRow()
            if vpnManager.status != .connected {
                Button(String(localized: "Connect Local Capture VPN", comment: "VPN settings action")) {
                    Task {
                        try? await vpnManager.startDirectVPN(
                            dnsServers: SettingsStore.shared.value(Settings.HTTPCapture.directDNSServers))
                    }
                }
                .themedRow()
            }
        } header: {
            Text("HTTP Capture")
        } footer: {
            Text("Inspect HTTP and HTTPS traffic through the VPN. Open the capture panel here, from the File menu, the keyboard toolbar, or with its keyboard shortcut. Local Capture is a VPN without a server, for capturing only.")
        }
    }
    #endif

    // MARK: - Status Section

    private var statusSection: some View {
        Section(statusSectionHeader) {
            #if !CHINA_BUILD
            VPNStatusRow(
                tailnetStatus: wholeDeviceTailnetStatus,
                onRequestDisconnect: canDisconnectActiveConnection ? { requestDisconnectCurrentConnection() } : nil
            )
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .themedRow()
            #else
            VPNStatusRow(
                onRequestDisconnect: canDisconnectActiveConnection ? { requestDisconnectCurrentConnection() } : nil
            )
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .themedRow()
            #endif

            if vpnManager.extensionApprovalPending {
                Label(
                    "Approve the VPN system extension in System Settings → Login Items & Extensions to finish connecting.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .themedRow()
            }

            if vpnManager.status.isActive {
                activeVisualizationRows(
                    stats: vpnManager.statistics,
                    snapshots: vpnManager.trafficHistory,
                    isInAppTailnet: false
                )
            }
            #if !CHINA_BUILD
            if !vpnManager.status.isActive && vpnManager.status != .disconnecting && tailnetEngine.isRunning {
                activeVisualizationRows(
                    stats: tailnetEngine.statistics,
                    snapshots: tailnetEngine.trafficHistory,
                    isInAppTailnet: true
                )
            }
            #endif
        }
    }

    @ViewBuilder
    private func activeVisualizationRows(
        stats: VPNStatistics?,
        snapshots: [VPNTrafficSnapshot],
        isInAppTailnet: Bool
    ) -> some View {
        VPNTrafficChart(
            snapshots: snapshots,
            totalBytesIn: stats?.bytesIn,
            totalBytesOut: stats?.bytesOut
        )
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .themedRow()

        if let stats {
            VPNConnectionHealthView(stats: stats)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .themedRow()
        }

        let activeProfile = !isInAppTailnet ? vpnManager.activeProfileID.flatMap { profileManager.profile(for: $0) } : nil
        let isLocalCapture = !isInAppTailnet && vpnManager.activeProfileID == VPNDirectProfile.id

        #if !CHINA_BUILD
        let isWholeDeviceTailnet = !isInAppTailnet && vpnManager.activeProfileID == VPNTailnetProfile.id
        VPNTunnelDetailsDisclosure(
            stats: stats,
            profile: activeProfile,
            isLocalCapture: isLocalCapture,
            isTailnet: isWholeDeviceTailnet,
            isInAppTailnet: isInAppTailnet,
            tailnetStatus: isInAppTailnet ? tailnetEngine.status : wholeDeviceTailnetStatus
        )
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .themedRow()
        #else
        VPNTunnelDetailsDisclosure(
            stats: stats,
            profile: activeProfile,
            isLocalCapture: isLocalCapture
        )
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .themedRow()
        #endif
    }

    private var statusSectionHeader: String {
        if vpnManager.status.isActive || vpnManager.status == .disconnecting {
            return String(localized: "Active Connection", comment: "VPN settings section header when connected")
        }
        #if !CHINA_BUILD
        if tailnetEngine.isRunning {
            return String(localized: "Active Connection", comment: "VPN settings section header when in-app Tailscale is running")
        }
        #endif
        return String(localized: "Status", comment: "VPN settings section header when disconnected")
    }

    private var canDisconnectActiveConnection: Bool {
        if vpnManager.status.isActive || vpnManager.status == .disconnecting {
            return true
        }
        #if !CHINA_BUILD
        if tailnetEngine.isRunning {
            return true
        }
        #endif
        return false
    }

    private var disconnectDialogTitle: String {
        switch pendingDisconnect {
        #if !CHINA_BUILD
        case .inAppTailnet:
            return String(localized: "Disconnect Tailscale?", comment: "Disconnect confirmation title for in-app Tailscale")
        #endif
        case .vpn, .none:
            return String(localized: "Disconnect VPN?", comment: "Disconnect confirmation title for active VPN")
        }
    }

    private var disconnectDialogMessage: String {
        switch pendingDisconnect {
        #if !CHINA_BUILD
        case .inAppTailnet:
            return String(localized: "This will disconnect Tailscale inside rootshell.", comment: "Disconnect confirmation message for in-app Tailscale")
        #endif
        case .vpn(_, _, let profileName):
            let name = profileName ?? String(localized: "the active profile", comment: "Fallback active VPN profile name")
            return String(localized: "This will end your connection to \(name).", comment: "Disconnect confirmation message for active VPN")
        case .none:
            return ""
        }
    }

    private func requestDisconnectCurrentConnection() {
        if vpnManager.status.isActive {
            pendingDisconnect = .vpn(
                generation: vpnConnectionGeneration,
                profileID: vpnManager.activeProfileID,
                profileName: vpnManager.activeProfileName
            )
        } else if vpnManager.status != .disconnecting {
            #if !CHINA_BUILD
            if tailnetEngine.isRunning {
                pendingDisconnect = .inAppTailnet
            }
            #endif
        }
    }

    private func disconnect(_ target: DisconnectTarget) {
        Task {
            switch target {
            case .vpn(let generation, let profileID, _):
                guard vpnConnectionGeneration == generation,
                      vpnManager.status.isActive,
                      vpnManager.activeProfileID == profileID else { return }
                try? await vpnManager.stopVPN()
            #if !CHINA_BUILD
            case .inAppTailnet:
                guard !vpnManager.status.isActive,
                      vpnManager.status != .disconnecting,
                      tailnetEngine.isRunning else { return }
                await tailnetEngine.turnOff()
            #endif
            }
        }
    }

    #if !CHINA_BUILD
    private var tailnetStatusTaskKey: String {
        let isTailnet = vpnManager.isTunnelUp && vpnManager.activeProfileID == VPNTailnetProfile.id
        let since = vpnManager.connectedSince?.timeIntervalSinceReferenceDate ?? -1
        return "\(isTailnet)-\(vpnConnectionGeneration)-\(vpnManager.activeProfileID?.uuidString ?? "none")-\(since)"
    }

    private func clearWholeDeviceTailnetStatus() {
        wholeDeviceTailnetStatus = nil
        wholeDeviceTailnetStatusGeneration = nil
        wholeDeviceTailnetStatusConnectedSince = nil
    }

    private func pollTailnetStatusIfNeeded() async {
        guard vpnManager.isTunnelUp,
              vpnManager.activeProfileID == VPNTailnetProfile.id else {
            clearWholeDeviceTailnetStatus()
            return
        }
        let expectedGeneration = vpnConnectionGeneration
        let expectedConnectedSince = vpnManager.connectedSince
        if wholeDeviceTailnetStatusGeneration != expectedGeneration
            || wholeDeviceTailnetStatusConnectedSince != expectedConnectedSince {
            clearWholeDeviceTailnetStatus()
        }
        while !Task.isCancelled {
            let fetched = await vpnManager.tailnetStatus()
            guard !Task.isCancelled,
                  vpnConnectionGeneration == expectedGeneration,
                  vpnManager.isTunnelUp,
                  vpnManager.activeProfileID == VPNTailnetProfile.id,
                  vpnManager.connectedSince == expectedConnectedSince else {
                return
            }
            if let fetched {
                wholeDeviceTailnetStatus = fetched
                wholeDeviceTailnetStatusGeneration = expectedGeneration
                wholeDeviceTailnetStatusConnectedSince = expectedConnectedSince
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
    #endif

    // MARK: - VPN Profiles Section

    private var vpnProfilesSection: some View {
        Section("VPN Profiles") {
            let profiles = vpnCapableProfiles
            if profiles.isEmpty {
                ContentUnavailableView(
                    "No VPN Profiles",
                    systemImage: "network.slash",
                    description: Text("Enable VPN in a connection profile's settings")
                )
                .themedRow()
            } else {
                ForEach(profiles) { profile in
                    VPNProfileRow(profile: profile)
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Event History Section

    @ViewBuilder
    private var eventHistorySection: some View {
        if !vpnManager.eventHistory.isEmpty {
            Section("Recent Events") {
                ForEach(vpnManager.eventHistory.suffix(20).reversed()) { event in
                    VPNEventRow(event: event)
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Debug Link

    private var debugSection: some View {
        Section {
            NavigationLink("Debug") {
                VPNDebugView()
            }
            .themedRow()
        }
    }

    // MARK: - Helpers

    private var vpnCapableProfiles: [ConnectionProfile] {
        profileManager.profiles.filter(\.isVPNCapable)
    }
}

// MARK: - VPN Debug View

struct VPNDebugView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared

    var body: some View {
        List {
            if let statusJSON = vpnManager.latestStatusJSON, !statusJSON.isEmpty {
                Section("Status JSON") {
                    Button("Copy Status JSON") {
                        UIPasteboard.general.string = statusJSON
                    }
                    .themedRow()

                    ScrollView(.vertical) {
                        Text(statusJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 400)
                    .themedRow()
                }
            }

            Section("Time-Series Log") {
                Button("Copy Time-Series Log") {
                    if let log = readTimeSeriesLog() {
                        UIPasteboard.general.string = log
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("VPN Debug")
    }

    private func readTimeSeriesLog() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.defaultAppGroupID
        ) else { return nil }
        let fileURL = containerURL.appendingPathComponent("vpn_ssh_timeseries.log")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}
