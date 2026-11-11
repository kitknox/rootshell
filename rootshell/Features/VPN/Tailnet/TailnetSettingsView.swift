//
//  TailnetSettingsView.swift
//  rootshell
//
//  Tailscale: how it connects (device VPN or inside rootshell only),
//  sign-in, device settings, SSH egress, exit node and routing rules.
//

#if !CHINA_BUILD

import NetworkExtension
import SwiftUI
import UIKit

struct TailnetSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared
    @State private var engine = TailnetInAppEngine.shared
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var settings = VPNTailnetProfile.settings()
    @State private var authKey = TailnetAuthKey.read() ?? ""
    @State private var modeSettings = TailnetModeSettings.load()
    /// Settings the running tunnel started with (written by the extension).
    @State private var appliedSettings = VPNTailnetProfile.appliedSettings()
    @State private var status: TailnetStatus?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var login = TailnetLoginCoordinator.shared
    @State private var showSignOutConfirmation = false
    @State private var pendingMode: TailnetMode?
    @State private var handoffMessage: String?

    private var mode: TailnetMode { modeSettings.effectiveMode }
    private var isWholeDevice: Bool { mode == .wholeDevice }

    private var isVPNActive: Bool { vpnManager.isVPNActive(for: VPNTailnetProfile.id) }
    /// Turned on. In-app with Connect Automatically, that may be before the engine starts.
    private var isActive: Bool { isWholeDevice ? isVPNActive : modeSettings.inAppEnabled || engine.isStarted }
    private var isConnected: Bool { isWholeDevice ? isVPNActive && vpnManager.isTunnelUp : engine.isStarted }
    private var needsRestart: Bool {
        guard isWholeDevice, isConnected, let appliedSettings else { return false }
        return settings != appliedSettings
    }

    var body: some View {
        List {
            modeSection
            statusSection
            if !isWholeDevice {
                inAppSection
            }
            deviceSection
            if isWholeDevice {
                egressSection
            }
            if let peers = status?.peers, !peers.isEmpty {
                peersSection(peers)
            }
            serverSection
            accountSection
        }
        .themedList()
        .navigationTitle(String(localized: "Tailscale", comment: "Tailscale VPN settings title"))
        .onAppear {
            if settings.hostname.isEmpty {
                settings.hostname = TailnetInAppEngine.defaultHostname
            }
        }
        .onDisappear {
            if !isWholeDevice { Task { await engine.applyPrefs() } }
        }
        .onChange(of: settings) { old, new in
            VPNTailnetProfile.store(new)
            if old.sshEgressProfileID != new.sshEgressProfileID {
                profileManager.refreshVPNSharedProfiles()
            }
            if !isWholeDevice, old.acceptRoutes != new.acceptRoutes {
                Task { await engine.applyPrefs() }
            }
        }
        .onChange(of: modeSettings) { old, new in
            // Only the fields edited here. The mode and on/off are written by
            // switchMode and the engine; a stale copy must never undo them.
            var stored = TailnetModeSettings.load()
            stored.connectOnDemand = new.connectOnDemand
            stored.useInLocalShell = new.useInLocalShell
            stored.exitNodeID = new.exitNodeID
            stored.exitNodeAllowLAN = new.exitNodeAllowLAN
            TailnetModeSettings.store(stored)
            engine.syncRouting()
            if old.useInLocalShell != new.useInLocalShell {
                Task { await engine.updateShellProxy() }
            }
            if old.exitNodeID != new.exitNodeID || old.exitNodeAllowLAN != new.exitNodeAllowLAN {
                Task { await engine.applyPrefs() }
            }
        }
        .onChange(of: authKey) { _, new in TailnetAuthKey.store(new) }
        .onChange(of: status?.registered == true) { _, registered in
            // The key is spent or unneeded.
            if registered { authKey = "" }
        }
        .task(id: "\(isConnected)-\(mode.rawValue)") { await pollStatus() }
        .confirmationDialog(
            switchTitle,
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Switch", comment: "Tailscale: confirm switching mode")) {
                if let pendingMode { switchMode(to: pendingMode) }
                pendingMode = nil
            }
        } message: {
            Text(switchMessage)
        }
        .alert(
            String(localized: "Tailscale", comment: "Tailscale error alert title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var modeSection: some View {
        if TailnetPlatform.supportsWholeDevice {
            Section {
                modeRow(
                    .wholeDevice,
                    title: String(localized: "Whole Device (VPN)", comment: "Tailscale mode: system VPN"),
                    detail: String(localized: "Uses the device's VPN slot. Every app can reach your tailnet, and SSH routing and HTTP capture work. Turns off any other VPN.", comment: "Tailscale mode: system VPN description")
                )
                modeRow(
                    .rootshellOnly,
                    title: String(localized: "rootshell Only", comment: "Tailscale mode: in-app networking"),
                    detail: inAppModeDetail
                )
                if let handoffMessage {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(handoffMessage).foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
            } header: {
                Text("How Tailscale Connects")
            } footer: {
                if mode == .rootshellOnly {
                    Text(modeFooter)
                }
            }
        } else {
            Section {
            } footer: {
                Text("Tailscale runs inside rootshell. Other apps aren't affected, and another VPN can stay on.")
            }
        }
    }

    private var inAppModeDetail: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "No VPN. rootshell's SSH, SFTP, Mosh, TSSH and Screen Sharing connections reach your tailnet. Your other VPN stays on.", comment: "Tailscale mode: in-app description (Mac)")
        #else
        String(localized: "No VPN. rootshell's SSH, SFTP, Mosh, TSSH, Screen Sharing, curl and git reach your tailnet. Your other VPN stays on.", comment: "Tailscale mode: in-app description")
        #endif
    }

    private var modeFooter: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Other Mac apps don't see the tailnet. In the local shell, only tools that use a proxy setting, like curl, can reach it.", comment: "Tailscale rootshell Only footer (Mac)")
        #else
        String(localized: "In the local shell, ping reaches tailnet devices; mtr, traceroute and nc don't.", comment: "Tailscale rootshell Only footer")
        #endif
    }

    private func modeRow(_ rowMode: TailnetMode, title: String, detail: String) -> some View {
        Button {
            selectMode(rowMode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if mode == rowMode {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking || handoffMessage != nil)
        .accessibilityAddTraits(mode == rowMode ? .isSelected : [])
        .themedRow()
    }

    private var statusSection: some View {
        Section {
            LabeledContent(String(localized: "Status", comment: "Tailscale status row")) {
                Text(statusText).foregroundStyle(.secondary)
            }
            .themedRow()
            if status?.isRunning == false, let error = status?.error, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .themedRow()
            }

            if let node = status?.selfNode, status?.isRunning == true {
                LabeledContent(node.displayName) {
                    Text(node.ips?.first ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
                }
                .hostAddressCopyMenu(name: node.displayName, hostname: node.dnsName, ipAddress: node.ips?.first)
                .themedRow()
            }
            if let tailnet = status?.tailnet, !tailnet.isEmpty {
                LabeledContent(String(localized: "Tailnet", comment: "Tailscale tailnet name row"), value: tailnet)
                    .themedRow()
            }
            if isWholeDevice, let egress = status?.egress {
                LabeledContent(String(localized: "SSH Egress", comment: "Tailscale SSH egress status row")) {
                    Text(egressText(egress)).foregroundStyle(egress.state == "failed" ? .orange : .secondary)
                }
                .themedRow()
            }

            if isActive {
                if status?.needsLogin == true {
                    Button(String(localized: "Sign In", comment: "Tailscale sign-in button")) { signIn() }
                        .disabled(isWorking || login.isSigningIn)
                        .themedRow()
                }
                if needsRestart {
                    Button(String(localized: "Apply Changes", comment: "Tailscale: reconnect so changed settings apply")) {
                        connect(restart: true)
                    }
                    .disabled(isWorking)
                    .themedRow()
                }
                Button(String(localized: "Disconnect", comment: "Tailscale disconnect button"), role: .destructive) {
                    disconnect()
                }
                .themedRow()
            } else {
                Button(String(localized: "Connect", comment: "Tailscale connect button")) { connect(restart: false) }
                    .disabled(isWorking || handoffMessage != nil || settings.normalizedControlURL == nil)
                    .themedRow()
            }
        } header: {
            Text("Status")
        } footer: {
            if isWholeDevice {
                Text("Use this instead of the Tailscale app. Only one VPN can be on at a time, so with the Tailscale app connected, HTTP capture can't run. Connected here, capture works on tailnet and internet traffic alike. MagicDNS names and tailnet addresses work in every app.")
            } else {
                Text("MagicDNS names and tailnet addresses work in rootshell's connections. Other apps on this device don't see the tailnet.")
            }
        }
    }

    private var inAppSection: some View {
        Section {
            Toggle(String(localized: "Connect Automatically", comment: "Tailscale in-app: start on demand"), isOn: $modeSettings.connectOnDemand)
                .themedRow()
            Toggle(String(localized: "Use in Local Shell", comment: "Tailscale in-app: local shell proxy"), isOn: $modeSettings.useInLocalShell)
                .themedRow()
            Picker(String(localized: "Exit Node", comment: "Tailscale in-app exit node picker"), selection: $modeSettings.exitNodeID) {
                Text(String(localized: "None", comment: "Tailscale exit node: none")).tag(String?.none)
                ForEach(exitNodeChoices) { peer in
                    Text(peer.displayName).tag(String?.some(peer.nodeID ?? ""))
                }
            }
            .themedRow()
            if modeSettings.exitNodeID != nil {
                Toggle(String(localized: "Allow Local Network Access", comment: "Tailscale exit node LAN access toggle"), isOn: $modeSettings.exitNodeAllowLAN)
                    .themedRow()
            }
        } header: {
            Text("rootshell Only")
        } footer: {
            Text(inAppFooter)
        }
    }

    private var inAppFooter: String {
        var parts = [
            String(localized: "Connect Automatically starts Tailscale the first time you connect to a tailnet device.", comment: "Tailscale in-app footer: on demand"),
        ]
        #if targetEnvironment(macCatalyst)
        parts.append(String(localized: "Use in Local Shell sets ALL_PROXY in new local shells, so tools that honor it, like curl, reach your tailnet.", comment: "Tailscale in-app footer: local shell (Mac)"))
        #else
        parts.append(String(localized: "Use in Local Shell lets curl and git in the local shell reach your tailnet.", comment: "Tailscale in-app footer: local shell"))
        #endif
        parts.append(String(localized: "An exit node sends all of rootshell's connections through that device. Other apps aren't affected.", comment: "Tailscale in-app footer: exit node"))
        return parts.joined(separator: " ")
    }

    /// Exit-capable peers, plus the saved choice so the picker keeps a tag for it.
    private var exitNodeChoices: [TailnetStatus.Peer] {
        let peers = (status?.peers ?? []).filter { $0.exitNodeOption == true && $0.nodeID != nil }
        if let id = modeSettings.exitNodeID, !peers.contains(where: { $0.nodeID == id }) {
            return peers + [TailnetStatus.Peer(name: id, dnsName: nil, os: nil, ips: nil, online: false, nodeID: id, exitNodeOption: true)]
        }
        return peers
    }

    private var deviceSection: some View {
        Section {
            LabeledContent(String(localized: "Device Name", comment: "Tailscale hostname row")) {
                TextField(String(localized: "Device Name", comment: "Tailscale hostname row"), text: $settings.hostname)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        if !isWholeDevice { Task { await engine.applyPrefs() } }
                    }
            }
            .themedRow()
            Toggle(String(localized: "Use Subnet Routes", comment: "Tailscale accept-routes toggle"), isOn: $settings.acceptRoutes)
                .themedRow()
        } header: {
            Text("Device")
        } footer: {
            Text("Subnet routes let this device reach networks that other tailnet machines advertise.")
        }
    }

    private var egressSection: some View {
        Section {
            Picker(String(localized: "SSH Host", comment: "Tailscale SSH egress profile picker"), selection: $settings.sshEgressProfileID) {
                Text(String(localized: "None", comment: "Tailscale SSH egress: none")).tag(UUID?.none)
                ForEach(sshProfiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .themedRow()

            Toggle(String(localized: "Send Other Traffic Through SSH", comment: "Tailscale: full tunnel through the SSH host"), isOn: $settings.sendAllViaSSH)
                .disabled(settings.sshEgressProfileID == nil)
                .themedRow()

            NavigationLink {
                VPNRoutingRulesEditor(rules: $settings.rules)
            } label: {
                LabeledContent(String(localized: "Routing Rules", comment: "Tailscale routing rules row")) {
                    Text("\(settings.rules.count)").foregroundStyle(.secondary)
                }
            }
            .disabled(settings.sshEgressProfileID == nil)
            .themedRow()

            NavigationLink {
                VPNDNSSettingsView(dnsServers: $settings.dnsServers)
            } label: {
                LabeledContent(String(localized: "DNS Servers", comment: "Tailscale fallback DNS row")) {
                    Text(settings.dnsServers.isEmpty
                         ? String(localized: "Default", comment: "Tailscale fallback DNS: default")
                         : settings.dnsServers.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()
        } header: {
            Text("SSH Egress")
        } footer: {
            Text("Routing rules send matching domains or networks out through the SSH host, which can itself be on your tailnet. Names with an SSH rule are resolved on that host. Turn on Send Other Traffic Through SSH to route everything except the tailnet that way. The host's key must already be trusted from a terminal session.")
        }
    }

    private func peersSection(_ peers: [TailnetStatus.Peer]) -> some View {
        Section {
            ForEach(peers) { peer in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(peer.online ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(peer.displayName)
                            Spacer(minLength: 8)
                            if let os = peer.os, !os.isEmpty {
                                Text(os).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Group {
                            if let dnsName = peer.dnsName, !dnsName.isEmpty {
                                Text(dnsName).truncationMode(.middle)
                            }
                            if let ip = peer.ips?.first {
                                Text(ip)
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .hostAddressCopyMenu(name: peer.displayName, hostname: peer.dnsName, ipAddress: peer.ips?.first)
                .themedRow()
            }
        } header: {
            if let total = status?.peersTotal, total > peers.count {
                Text("Devices (\(peers.count) of \(total))")
            } else {
                Text("Devices")
            }
        }
    }

    /// Locked while on: the engine reads both only at start.
    private var serverSection: some View {
        Section {
            LabeledContent(String(localized: "Server", comment: "Tailscale coordination server row")) {
                TextField(String(localized: "Tailscale", comment: "Coordination server placeholder: Tailscale's own server"), text: $settings.controlURL)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .disabled(isActive)
            .themedRow()
            LabeledContent(String(localized: "Auth Key", comment: "Tailscale auth key row (signs in without the login page)")) {
                SecureField(String(localized: "Optional", comment: "Tailscale auth key placeholder"), text: $authKey)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .disabled(isActive)
            .themedRow()
        } header: {
            Text("Coordination Server")
        } footer: {
            Text(serverFooter)
        }
    }

    private var serverFooter: String {
        guard settings.normalizedControlURL != nil else {
            return String(localized: "Enter the server's HTTPS URL, like https://headscale.example.com.", comment: "Tailscale coordination server footer: invalid URL")
        }
        var parts = [
            String(localized: "Leave the server empty to use Tailscale. For Headscale or another self-hosted server, enter its URL. Switching servers signs in again as a new device.", comment: "Tailscale coordination server footer"),
            String(localized: "An auth key, like a Headscale pre-auth key, signs in a new device without the login page and is deleted once it has. Avoid ephemeral keys: the server removes the device soon after it goes offline.", comment: "Tailscale auth key footer"),
        ]
        if isActive {
            parts.append(String(localized: "Disconnect to change these.", comment: "Tailscale coordination server footer while connected"))
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if status?.isRunning == true {
                Button(String(localized: "Sign Out", comment: "Tailscale sign-out button"), role: .destructive) {
                    showSignOutConfirmation = true
                }
                .confirmationDialog(
                    String(localized: "Sign out of Tailscale?", comment: "Tailscale sign-out confirmation"),
                    isPresented: $showSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Sign Out", comment: "Tailscale sign-out button"), role: .destructive) { signOut() }
                }
                .themedRow()
            } else if !isActive && canForgetDevice {
                Button(String(localized: "Forget This Device", comment: "Tailscale: delete stored node keys"), role: .destructive) {
                    TailnetKeychain.deleteAll()
                }
                .themedRow()
            }
        } footer: {
            if !isActive && canForgetDevice {
                Text("Forgetting the device deletes its Tailscale keys here; the next connect signs in as a new device.")
            }
        }
    }

    /// On the Mac the VPN's keys live in the system extension, out of the
    /// app's reach; the in-app engine keeps them in the keychain.
    private var canForgetDevice: Bool {
        #if targetEnvironment(macCatalyst)
        !isWholeDevice
        #else
        true
        #endif
    }

    // MARK: - Helpers

    private var sshProfiles: [ConnectionProfile] {
        profileManager.profiles.filter { !$0.isDeleted && ($0.connectionProtocol == .ssh || $0.connectionProtocol == .trzsz) }
    }

    private var statusText: String {
        guard isActive else { return String(localized: "Off", comment: "Tailscale state") }
        if !isWholeDevice, !engine.isStarted {
            return String(localized: "On, starts when needed", comment: "Tailscale in-app state before first use")
        }
        guard let status else { return String(localized: "Connecting…", comment: "Tailscale state") }
        switch status.state {
        case "Running":
            return isWholeDevice
                ? String(localized: "Connected", comment: "Tailscale state")
                : String(localized: "Connected (rootshell only)", comment: "Tailscale state when running inside the app")
        case "NeedsLogin": return String(localized: "Needs Sign-In", comment: "Tailscale state")
        case "NeedsMachineAuth": return String(localized: "Waiting for Admin Approval", comment: "Tailscale state")
        case "Starting": return String(localized: "Starting…", comment: "Tailscale state")
        default: return String(localized: "Connecting…", comment: "Tailscale state")
        }
    }

    private func egressText(_ egress: TailnetStatus.Egress) -> String {
        switch egress.state {
        case "connected": return String(localized: "Connected", comment: "Tailscale SSH egress state")
        case "connecting": return String(localized: "Connecting…", comment: "Tailscale SSH egress state")
        case "waitingForTailnet": return String(localized: "Waiting for Tailscale", comment: "Tailscale SSH egress state")
        case "failed": return egress.error ?? String(localized: "Failed", comment: "Tailscale SSH egress state")
        default: return String(localized: "Off", comment: "Tailscale SSH egress state")
        }
    }

    private var switchTitle: String {
        pendingMode == .rootshellOnly
            ? String(localized: "Switch to rootshell Only?", comment: "Tailscale mode switch confirmation title")
            : String(localized: "Switch to Whole Device?", comment: "Tailscale mode switch confirmation title")
    }

    private var switchMessage: String {
        let signInNote = TailnetStateHandoff.keepsIdentity
            ? String(localized: "You won't need to sign in again.", comment: "Tailscale mode switch: same device")
            : String(localized: "You may need to sign in again.", comment: "Tailscale mode switch: new sign-in")
        if pendingMode == .rootshellOnly {
            return String(localized: "The rootshell VPN will disconnect and Tailscale will reconnect inside rootshell.", comment: "Tailscale switch to in-app message") + " " + signInNote
        }
        return String(localized: "Tailscale will stop inside rootshell and reconnect as this device's VPN, replacing any other VPN.", comment: "Tailscale switch to VPN message") + " " + signInNote
    }

    // MARK: - Actions

    private func selectMode(_ newMode: TailnetMode) {
        guard newMode != mode else { return }
        if isActive {
            pendingMode = newMode
        } else {
            switchMode(to: newMode)
        }
    }

    /// Saves the mode on the latest stored settings (never the view's copy).
    private func storeMode(_ newMode: TailnetMode) {
        var stored = TailnetModeSettings.load()
        stored.mode = newMode
        TailnetModeSettings.store(stored)
        engine.syncRouting()
    }

    /// Changes mode, moving a running Tailscale over to the other side.
    private func switchMode(to newMode: TailnetMode) {
        let wasActive = isActive
        isWorking = true
        Task {
            defer {
                isWorking = false
                handoffMessage = nil
            }
            handoffMessage = String(localized: "Moving Tailscale…", comment: "Tailscale mode switch progress")
            do {
                switch newMode {
                case .rootshellOnly:
                    try await TailnetStateHandoff.moveToApp()
                    storeMode(.rootshellOnly)
                    if wasActive { try await engine.turnOn() }
                case .wholeDevice:
                    if TailnetModeSettings.load().inAppEnabled { await engine.turnOff() }
                    storeMode(.wholeDevice)
                    if wasActive {
                        try await vpnManager.startTailnetVPN()
                        login.watch()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            modeSettings = TailnetModeSettings.load()
            status = nil
        }
    }

    private func connect(restart: Bool) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if isWholeDevice {
                    try await vpnManager.startTailnetVPN(restart: restart)
                    login.watch()
                } else {
                    try await engine.turnOn()
                    modeSettings = TailnetModeSettings.load()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        Task {
            if isWholeDevice {
                try? await vpnManager.stopVPN()
            } else {
                await engine.turnOff()
                modeSettings = TailnetModeSettings.load()
            }
        }
    }

    private func signIn() {
        isWorking = true
        Task {
            defer { isWorking = false }
            if let error = await login.signIn() {
                errorMessage = error
            }
        }
    }

    private func signOut() {
        login.cancel()
        Task {
            if let error = await TailnetController.logout() {
                errorMessage = error
            }
        }
    }

    /// Polls for display while connected; the login coordinator owns the
    /// login page.
    private func pollStatus() async {
        guard isConnected else {
            status = nil
            return
        }
        while !Task.isCancelled {
            status = await TailnetController.status()
            appliedSettings = VPNTailnetProfile.appliedSettings()
            try? await Task.sleep(for: .seconds(login.isSigningIn ? 1 : 3))
        }
    }
}

#endif
