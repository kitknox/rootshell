//
//  ConnectionInfoSheet.swift
//  rootshell
//
//  Displays detailed connection information for a terminal session
//

import SwiftUI
import rootshellVNC
import RFBProtocol
import RFBTransport

struct ConnectionInfoSheet: View {
    let info: ConnectionInfo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var geoInfo: GeoInfo?
    /// Cached network-device this session connects to (matched by host/IP), if any.
    @State private var device: CloudInstance?

    var body: some View {
        NavigationStack {
            List {
                if case .tmux(let request, _) = info {
                    TmuxConnectionInfoSections(request: request)
                }
                if case .herdr(let request, _) = info {
                    HerdrConnectionInfoSections(request: request)
                }
                if let transport = info.transportInfo {
                    switch transport {
                    case .ssh(let sshInfo):
                        sshContent(sshInfo)
                    case .mosh(let sshInfo):
                        moshContent(sshInfo)
                    case .trzsz(let sshInfo, let transportMode, let transportRef):
                        trzszContent(sshInfo, transportMode: transportMode, transportRef: transportRef)
                    case .local(let shell, let workingDirectory, _):
                        localContent(shell: shell, workingDirectory: workingDirectory)
                    case .kubernetes(let cluster, let node, _):
                        kubernetesContent(cluster: cluster, node: node)
                    case .console(let provider, let instance, _):
                        consoleContent(provider: provider, instance: instance)
                    case .vnc(let vncInfo):
                        vncContent(vncInfo)
                    case .tmux, .herdr:
                        EmptyView() // transportInfo unwraps all multiplexer layers.
                    }
                }
            }
            .themedList()
            .navigationTitle("Connection Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                resolveDevice()
                await resolveGeo()
            }
        }
        .presentationDetents([.medium, .large], selection: .constant(.large))
    }

    /// Extract the IP from the connection info and resolve geo via configured provider.
    private func resolveGeo() async {
        let sshInfo: SSHConnectionInfo? = switch info.transportInfo {
        case .ssh(let i), .mosh(let i), .trzsz(let i, _, _): i
        default: nil
        }
        guard let sshInfo else { return }

        // Try resolvedIP, then host-as-IP, then DNS-resolve the hostname
        let ip: String?
        if let resolved = sshInfo.resolvedIP {
            ip = resolved
        } else if Self.isIPAddress(sshInfo.host) {
            ip = sshInfo.host
        } else {
            ip = await Self.resolveHostname(sshInfo.host)
        }

        guard let ip else { return }
        geoInfo = await GeoResolver.shared.resolve(ip: ip)
    }

    /// Match the live session's host/IP against cached cloud instances so we can
    /// show device metadata (OS, mesh path, routes) for Tailscale/NetBird hosts.
    private func resolveDevice() {
        let sshInfo: SSHConnectionInfo? = switch info.transportInfo {
        case .ssh(let i), .mosh(let i), .trzsz(let i, _, _): i
        default: nil
        }
        guard let sshInfo else { return }

        let host = sshInfo.host.lowercased()
        let resolvedIP = sshInfo.resolvedIP
        device = CloudCacheManager.shared.allInstances.first { instance in
            guard instance.isNetworkDevice else { return false }
            if let hostname = instance.hostname?.lowercased(), hostname == host { return true }
            if let v4 = instance.ipv4Address, v4 == host || v4 == resolvedIP { return true }
            if let v6 = instance.ipv6Address?.lowercased(), v6 == host { return true }
            return false
        }
    }

    /// Check if a string is a valid IPv4 or IPv6 address.
    private static func isIPAddress(_ string: String) -> Bool {
        var addr4 = in_addr()
        var addr6 = in6_addr()
        return inet_pton(AF_INET, string, &addr4) == 1 ||
               inet_pton(AF_INET6, string, &addr6) == 1
    }

    /// Resolve a hostname to an IP address via getaddrinfo.
    private static func resolveHostname(_ hostname: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(hostname, nil, &hints, &result) == 0, let info = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }

                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(
                    info.pointee.ai_addr, info.pointee.ai_addrlen,
                    &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST
                )
                continuation.resume(returning: rc == 0 ? String(cString: buf) : nil)
            }
        }
    }

    // MARK: - SSH Content

    @ViewBuilder
    private func sshContent(_ info: SSHConnectionInfo) -> some View {
        securityStatusSection(info)
        connectionSection(info)
        networkSection()
        deviceSection()
        cryptographySection(info)
        if info.agentForwardingEnabled || info.jumpHost != nil {
            featuresSection(info)
        }
    }

    @ViewBuilder
    private func moshContent(_ info: SSHConnectionInfo) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mosh (Mobile Shell)")
                        .font(.headline)
                    Text("UDP-based roaming session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
            }
            .themedRow()
        }
        if info.keyExchangeAlgorithm != nil || info.cipherAlgorithm != nil {
            securityStatusSection(info)
        }
        connectionSection(info)
        networkSection()
        deviceSection()
        if info.keyExchangeAlgorithm != nil || info.cipherAlgorithm != nil {
            bootstrapCryptographySection(info)
        }
    }

    @ViewBuilder
    private func trzszContent(_ info: SSHConnectionInfo, transportMode: String?, transportRef: TSSHTransportRef?) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("tssh")
                        .font(.headline)
                    Text("\(transportMode ?? "QUIC/KCP") roaming session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "bolt.horizontal")
                    .foregroundStyle(.blue)
            }
            .themedRow()
            if let mode = transportMode {
                infoRow("Transport", value: mode)
            }
        }
        if info.keyExchangeAlgorithm != nil || info.cipherAlgorithm != nil {
            securityStatusSection(info)
        }
        if let transportRef {
            TrzszPerformanceSection(transportRef: transportRef)
        }
        connectionSection(info)
        networkSection()
        deviceSection()
        if info.keyExchangeAlgorithm != nil || info.cipherAlgorithm != nil {
            bootstrapCryptographySection(info)
        }
    }

    // MARK: - Security Status

    @ViewBuilder
    private func securityStatusSection(_ info: SSHConnectionInfo) -> some View {
        Section {
            if info.isPostQuantumKeyExchange {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Post-Quantum Secure")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("This connection uses hybrid post-quantum key exchange, protecting against future quantum computer attacks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shield.checkered")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
                .themedRow()
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Classically Secure")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("This connection uses classical cryptography. Secure against current threats.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .themedRow()
            }
        }
    }

    // MARK: - Network Info

    @ViewBuilder
    private func networkSection() -> some View {
        if let geoInfo {
            Section {
                infoRow("ASN", value: geoInfo.asNumber)
                if let asName = geoInfo.asName, !asName.isEmpty {
                    infoRow("AS Name", value: asName)
                }
                if let asDomain = geoInfo.asDomain, !asDomain.isEmpty {
                    faviconInfoRow("AS Domain", domain: asDomain)
                }
                if !geoInfo.network.isEmpty {
                    infoRow("Network", value: geoInfo.network)
                }
                if !geoInfo.countryCode.isEmpty {
                    infoRow("Country", value: geoInfo.countryWithFlag)
                }
                if let continent = geoInfo.continentName, !continent.isEmpty {
                    infoRow("Continent", value: continent)
                }
            } header: {
                Text("Network")
            }
        }
    }

    // MARK: - Device (Tailscale / NetBird)

    /// Provider-aware section title for the matched mesh device.
    private var deviceSectionTitle: String {
        switch device?.providerID {
        case "tailscale": return "Tailscale Device"
        case "netbird": return "NetBird Peer"
        default: return "Device"
        }
    }

    @ViewBuilder
    private func deviceSection() -> some View {
        if let device {
            Section {
                if let osName = OSDisplay.name(for: device.image) {
                    HStack {
                        Text("Operating System")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(osName, systemImage: OSDisplay.icon(for: device.image))
                            .labelStyle(.titleAndIcon)
                    }
                    .themedRow()
                }

                if let owner = device.owner, !owner.isEmpty {
                    infoRow("Owner", value: owner)
                }

                if let version = device.clientVersion, !version.isEmpty {
                    let suffix = device.updateAvailable == true ? "  (update available)" : ""
                    infoRow("Client", value: version + suffix)
                }

                if let path = meshPathDescription(device.connectionQuality) {
                    infoRow("Mesh Path", value: path)
                }

                if device.isExitNode {
                    Label("Exit Node", systemImage: "arrow.up.forward.app")
                        .themedRow()
                }

                let subnets = device.subnetRoutes
                if !subnets.isEmpty {
                    infoRow("Subnet Routes", value: subnets.joined(separator: ", "))
                }

                if let expiry = device.keyExpiry {
                    infoRow("Key Expires", value: Self.formatRelativeExpiry(expiry))
                }

                if device.isExternal == true {
                    Label("Shared into your network", systemImage: "person.2")
                        .themedRow()
                }
            } header: {
                Text(deviceSectionTitle)
            } footer: {
                if device.connectionQuality != nil {
                    Text("Mesh path is reported by the device, not measured from this client.")
                }
            }
        }
    }

    /// Compose a "direct vs relayed" mesh-path description from the device's report.
    private func meshPathDescription(_ quality: CloudConnectionQuality?) -> String? {
        guard let quality else { return nil }
        let region = quality.preferredDERPRegion
        let latency = quality.preferredDERPLatencyMs.map { String(format: " (%.0f ms)", $0) } ?? ""
        if quality.hasDirectEndpoints == true {
            if let region { return "Direct · relay \(region)\(latency)" }
            return "Direct"
        }
        if let region { return "Relayed via \(region)\(latency)" }
        return nil
    }

    /// Human-friendly relative expiry (e.g. "in 12 days", "today", "expired").
    static func formatRelativeExpiry(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 0 { return "expired" }
        if days == 0 { return "today" }
        if days == 1 { return "in 1 day" }
        return "in \(days) days"
    }

    // MARK: - Connection Details

    @ViewBuilder
    private func connectionSection(_ info: SSHConnectionInfo) -> some View {
        Section("Connection") {
            infoRow("Host", value: info.host)
            infoRow("Port", value: "\(info.port)")
            infoRow("User", value: info.username)
            if let ip = info.resolvedIP, ip != info.host {
                infoRow("IP Address", value: ip)
            }
            liveDurationRow(since: info.connectedAt)
            if let jumpHost = info.jumpHost {
                let jumpPort = info.jumpPort.map { ":\($0)" } ?? ""
                infoRow("Jump Host", value: "\(jumpHost)\(jumpPort)")
            }
        }
    }

    // MARK: - Cryptography

    @ViewBuilder
    private func cryptographySection(_ info: SSHConnectionInfo) -> some View {
        Section("Cryptography") {
            algorithmRow("Key Exchange", value: info.keyExchangeAlgorithm, isPostQuantum: info.isPostQuantumKeyExchange)
            algorithmRow("Host Key", value: info.hostKeyAlgorithm, isPostQuantum: info.isPostQuantumHostKey)
            algorithmRow("Cipher", value: info.cipherAlgorithm)
            algorithmRow("MAC", value: info.macAlgorithm)
        }
    }

    // MARK: - Bootstrap Cryptography

    @ViewBuilder
    private func bootstrapCryptographySection(_ info: SSHConnectionInfo) -> some View {
        Section {
            algorithmRow("Key Exchange", value: info.keyExchangeAlgorithm, isPostQuantum: info.isPostQuantumKeyExchange)
            algorithmRow("Host Key", value: info.hostKeyAlgorithm, isPostQuantum: info.isPostQuantumHostKey)
            algorithmRow("Cipher", value: info.cipherAlgorithm)
            algorithmRow("MAC", value: info.macAlgorithm)
        } header: {
            Text("Bootstrap SSH")
        } footer: {
            Text("Negotiated during the SSH session used to start the server.")
        }
    }

    // MARK: - Features

    @ViewBuilder
    private func featuresSection(_ info: SSHConnectionInfo) -> some View {
        Section("Features") {
            if info.agentForwardingEnabled {
                Label("Agent Forwarding", systemImage: "key.fill")
                    .themedRow()
            }
            if info.jumpHost != nil {
                Label("Proxy Jump", systemImage: "arrow.triangle.branch")
                    .themedRow()
            }
        }
    }

    // MARK: - Simple Session Content

    @ViewBuilder
    private func localContent(shell: String, workingDirectory: String?) -> some View {
        Section {
            Label {
                Text("Local Shell")
                    .font(.headline)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(.green)
            }
            .themedRow()
        }
        Section("Details") {
            infoRow("Shell", value: shell)
            if let cwd = workingDirectory {
                infoRow("Directory", value: cwd)
            }
            liveDurationRow(since: info.connectedAt)
        }
    }

    @ViewBuilder
    private func kubernetesContent(cluster: String, node: String) -> some View {
        Section {
            Label {
                Text("Kubernetes Node Shell")
                    .font(.headline)
            } icon: {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
            }
            .themedRow()
        }
        Section("Details") {
            infoRow("Cluster", value: cluster)
            infoRow("Node", value: node)
            liveDurationRow(since: info.connectedAt)
        }
    }

    @ViewBuilder
    private func consoleContent(provider: String, instance: String) -> some View {
        Section {
            Label {
                Text("Cloud Console")
                    .font(.headline)
            } icon: {
                Image(systemName: "cloud")
                    .foregroundStyle(.blue)
            }
            .themedRow()
        }
        Section("Details") {
            infoRow("Provider", value: provider)
            infoRow("Instance", value: instance)
            liveDurationRow(since: info.connectedAt)
        }
    }

    // MARK: - VNC Content

    @ViewBuilder
    private func vncContent(_ info: VNCConnectionInfo) -> some View {
        let session = info.session
        let diagnostics = session.getDiagnostics()

        vncSecurityStatusSection(info, diagnostics: diagnostics)

        Section("Connection") {
            infoRow("Host", value: info.host)
            infoRow("Port", value: "\(info.port)")
            if let username = info.username, !username.isEmpty {
                infoRow("User", value: username)
            }
            if !session.serverName.isEmpty {
                infoRow("Server Name", value: session.serverName)
            }
            infoRow("Transport", value: info.transportDescription)
            infoRow("Mode", value: Self.vncModeName(session))
            liveDurationRow(since: info.connectedAt)
        }

        Section("Security") {
            if let selected = diagnostics.selectedSecurityType {
                infoRow("Authentication", value: Self.vncSecurityTypeName(selected))
            }
            infoRow("Encryption", value: Self.vncEncryptionDescription(
                diagnostics.contentEncryption, isTunneled: info.isTunneled))
            if let client = diagnostics.clientVersion {
                let server = diagnostics.serverVersion
                let value = (server != nil && server != client)
                    ? "\(client) (server: \(server!))"
                    : "\(client)"
                infoRow("Protocol", value: value)
            }
        }

        Section("Display") {
            infoRow("Resolution", value: "\(session.framebufferWidth) × \(session.framebufferHeight)")
            if session.isHighPerformanceMode {
                infoRow("Displays", value: "\(session.activeVideoDisplayCount)")
                infoRow("Pixel Format", value: "HEVC video")
            } else if let pixelFormat = diagnostics.serverInit?.pixelFormat {
                infoRow("Pixel Format", value: "\(pixelFormat.bitsPerPixel)-bit, depth \(pixelFormat.depth)")
            }
        }

        VNCPerformanceSection(session: session)

        vncCapabilitiesSection(info)
    }

    @ViewBuilder
    private func vncSecurityStatusSection(
        _ info: VNCConnectionInfo,
        diagnostics: ConnectionDiagnostics
    ) -> some View {
        Section {
            // Explicit optional patterns: the enum's own `.none` case would
            // otherwise be shadowed by Optional.none.
            switch diagnostics.contentEncryption {
            case .tlsX509?, .appleComCryption?:
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypted")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("Screen contents are encrypted by the VNC protocol layer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
                .themedRow()
            case VNCContentEncryption.none?, nil:
                if info.isTunneled {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Encrypted via SSH Tunnel")
                                .font(.headline)
                                .foregroundStyle(.blue)
                            Text("The VNC stream itself is unencrypted, but every byte travels inside the SSH tunnel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .themedRow()
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not Encrypted")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("Screen contents travel unencrypted. Use an SSH tunnel or an encrypting server on untrusted networks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.open")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }
                    .themedRow()
                }
            }
        }
    }

    @ViewBuilder
    private func vncCapabilitiesSection(_ info: VNCConnectionInfo) -> some View {
        let session = info.session
        Section("Capabilities") {
            if session.supportsRemoteClipboardRequest || session.supportsRemoteSharedClipboardControl {
                infoRow("Remote Clipboard", value: "Yes")
            }
            if session.isHighPerformanceMode {
                infoRow("Remote Audio", value: session.configuration.enableRemoteAudio ? "On" : "Off")
            }
            if session.supportsCurtainMode {
                infoRow("Curtain Mode", value: session.isCurtained ? "On" : "Off")
            }
            if let capabilities = session.serverCapabilities {
                infoRow(
                    "Precise Scrolling",
                    value: capabilities.supportsServerCommand(
                        AppleServerCapabilities.preciseScrollCommand) ? "Yes" : "No")
                infoRow(
                    "Display Configuration",
                    value: capabilities.supportsServerCommand(
                        AppleServerCapabilities.displayConfigurationCommand) ? "Yes" : "No")
            }
            if !session.isHighPerformanceMode {
                let advertised = session.configuration.effectiveEncodings
                    .filter { !$0.isPseudo }
                    .map(\.displayName)
                    .joined(separator: ", ")
                if !advertised.isEmpty {
                    infoRow("Advertised Encodings", value: advertised)
                }
            }
        }
    }

    private static func vncModeName(_ session: VNCSession) -> String {
        if session.isHighPerformanceMode { return "High Performance" }
        if session.configuration.videoQualityMode == .fullQuality {
            return "Standard (Full Quality)"
        }
        return "Standard"
    }

    private static func vncSecurityTypeName(_ type: SecurityType) -> String {
        switch type {
        case .none: return "None"
        case .vncAuthentication: return "VNC Password"
        case .tight: return "Tight"
        case .vencrypt: return "VeNCrypt (X.509)"
        case .apple30: return "Apple (Diffie-Hellman)"
        case .macAuthentication: return "Apple (Diffie-Hellman)"
        case .srp: return "SRP"
        case .kerberos: return "Kerberos"
        case .unknown(let value): return "Type \(value)"
        }
    }

    private static func vncEncryptionDescription(
        _ encryption: VNCContentEncryption?,
        isTunneled: Bool
    ) -> String {
        switch encryption {
        case .tlsX509?:
            return "TLS (X.509)"
        case .appleComCryption(_, let keyLength, let mediaSRTP)?:
            var value = keyLength.map { "AES-\($0) ComCryption" } ?? "AES ComCryption"
            if mediaSRTP { value += " + SRTP media" }
            return value
        case VNCContentEncryption.none?, nil:
            return isTunneled ? "None (SSH tunnel encrypted)" : "Not encrypted"
        }
    }

    // MARK: - Helper Views

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .themedRow()
    }

    private func faviconInfoRow(_ label: String, domain: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            FaviconImage(domain: domain, size: 16)
            Text(domain)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .themedRow()
    }

    /// Duration row that live-updates every second using TimelineView
    private func liveDurationRow(since date: Date) -> some View {
        HStack {
            Text("Duration")
                .foregroundStyle(.secondary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatDuration(from: date, to: context.date))
                    .font(.system(.body, design: .monospaced))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
        }
        .themedRow()
    }

    /// Format elapsed time between two dates
    static func formatDuration(from start: Date, to now: Date) -> String {
        let elapsed = now.timeIntervalSince(start)
        let totalSeconds = max(0, Int(elapsed))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    @ViewBuilder
    private func algorithmRow(_ label: String, value: String?, isPostQuantum: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if isPostQuantum {
                        Image(systemName: "shield.checkered")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .themedRow()
    }
}

// MARK: - VNC Performance Section

/// Live traffic statistics for a VNC session, polled at 1 Hz while visible.
/// Each poll advances the package's recent-rate window, so the recent bitrate
/// and loss figures describe roughly the last second.
private struct VNCPerformanceSection: View {
    let session: VNCSession
    @State private var stats: VNCSessionStatistics?

    var body: some View {
        Section("Performance") {
            if let stats {
                if stats.transport.isHighPerformanceMode {
                    highPerformanceRows(stats)
                } else {
                    standardRows(stats)
                }
            } else {
                row("Bitrate", value: nil)
            }
        }
        .task {
            while !Task.isCancelled {
                stats = await session.currentStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func highPerformanceRows(_ stats: VNCSessionStatistics) -> some View {
        let transport = stats.transport
        row("Bitrate", value: (transport.recentBitrateKbps ?? transport.throughputKbps)
            .map(PerfFormat.bitrate))
        row("Bandwidth Estimate", value: transport.bandwidthEstimateKbps
            .map(PerfFormat.bitrate))
        row("Packet Loss", value: Self.formatLoss(
            recent: transport.recentPacketLossPercent,
            lost: transport.packetsLostCumulative,
            received: transport.mediaPacketsReceived))
        row("Received", value: PerfFormat.bytes(transport.mediaBytesReceived)
            + " · \(transport.mediaPacketsReceived.formatted()) packets")
        row("Queue Delay", value: transport.queueDelayMilliseconds
            .map { String(format: "%.0f ms peak", $0) })
        row("One-Way Delay", value: transport.oneWayRelativeDelayMilliseconds
            .map { String(format: "%.0f ms", $0) })
        row("Frames", value: "\(stats.framesDecoded.formatted()) decoded"
            + (stats.framesDroppedWhileGated > 0
                ? " · \(stats.framesDroppedWhileGated) dropped" : ""))
        if stats.lossGapsDetected > 0 {
            row("Stream Gaps", value: "\(stats.lossGapsDetected)")
        }
    }

    @ViewBuilder
    private func standardRows(_ stats: VNCSessionStatistics) -> some View {
        let transport = stats.transport
        row("Throughput", value: transport.recentBitrateKbps.map(PerfFormat.bitrate))
        row("Received", value: PerfFormat.bytes(transport.framebufferBytesReceived)
            + " · \(transport.framebufferUpdateCount.formatted()) updates")
        if !transport.encodingUsage.isEmpty {
            row("Encodings In Use", value: Self.formatEncodingUsage(transport.encodingUsage))
        }
    }

    private func row(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .themedRow()
    }

    private static func formatLoss(recent: Double?, lost: UInt64, received: UInt64) -> String {
        let expected = lost &+ received
        let cumulative = expected > 0 ? Double(lost) / Double(expected) * 100 : 0
        if let recent {
            return String(format: "%.2f%% · %.2f%% total", recent, cumulative)
        }
        return String(format: "%.2f%% total", cumulative)
    }

    /// "Tight 84% · CopyRect 16%" from the byte share of content encodings.
    private static func formatEncodingUsage(_ usage: [EncodingUsage]) -> String {
        let totalBytes = usage.reduce(UInt64(0)) { $0 + $1.bytes }
        guard totalBytes > 0 else { return usage.map(\.encoding.displayName).joined(separator: " · ") }
        return usage.prefix(4).map { entry in
            let share = Double(entry.bytes) / Double(totalBytes) * 100
            return "\(entry.encoding.displayName) \(Int(share.rounded()))%"
        }.joined(separator: " · ")
    }
}

// MARK: - Shared performance formatters

// nonisolated so the formatters can be passed as function values to
// `Optional.map` from the row builders.
nonisolated enum PerfFormat {
    static func bitrate(_ kbps: Double) -> String {
        if kbps >= 1_000 {
            return String(format: "%.1f Mbps", kbps / 1_000)
        }
        return String(format: "%.0f kbps", kbps)
    }

    static func bytes(_ count: some BinaryInteger) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }
}

// MARK: - Trzsz Performance Section

/// Live transport statistics for a tssh (tsshd) session, polled at 1 Hz
/// while visible. Cumulative counters come from the Go transport; recent
/// bitrate and loss are derived here from deltas between polls.
private struct TrzszPerformanceSection: View {
    let transportRef: TSSHTransportRef

    @State private var stats: TSSHTransportStatsSnapshot?
    @State private var previous: (stats: TSSHTransportStatsSnapshot, at: ContinuousClock.Instant)?
    @State private var recentDownKbps: Double?
    @State private var recentUpKbps: Double?
    @State private var recentLossPercent: Double?

    var body: some View {
        Section {
            if let stats {
                statsRows(stats)
            } else {
                row("RTT", value: nil)
                row("Bitrate", value: nil)
            }
        } header: {
            Text("Performance")
        } footer: {
            if stats?.hasRto == true {
                Text("KCP byte counts are measured at the UDP wire level. Retransmits are shared across all KCP sessions in the app.")
            }
        }
        .task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func statsRows(_ stats: TSSHTransportStatsSnapshot) -> some View {
        row("RTT", value: stats.srttMs > 0
            ? "\(stats.srttMs) ms ± \(stats.rttVarMs)" : nil)
        if stats.hasMinRtt {
            row("Min RTT", value: stats.minRttMs > 0 ? "\(stats.minRttMs) ms" : nil)
        }
        if stats.hasRto {
            row("RTO", value: stats.rtoMs > 0 ? "\(stats.rtoMs) ms" : nil)
        }
        row("Bitrate", value: bitrateValue)
        if stats.hasLoss {
            row("Packet Loss", value: lossValue(stats))
        }
        row("Received", value: PerfFormat.bytes(stats.bytesReceived)
            + " · \(stats.packetsReceived.formatted()) packets")
        row("Sent", value: PerfFormat.bytes(stats.bytesSent)
            + " · \(stats.packetsSent.formatted()) packets")
        if stats.hasRto && stats.retransSegs > 0 {
            row("Retransmits", value: stats.retransSegs.formatted())
        }
    }

    private var bitrateValue: String? {
        guard let down = recentDownKbps, let up = recentUpKbps else { return nil }
        return "↓ \(PerfFormat.bitrate(down)) · ↑ \(PerfFormat.bitrate(up))"
    }

    /// "0.12% · 0.34% total" — recent loss from deltas, cumulative from the
    /// counters. QUIC loss counts are packets we sent that were declared lost.
    private func lossValue(_ stats: TSSHTransportStatsSnapshot) -> String? {
        guard stats.packetsSent > 0 else { return nil }
        let cumulative = Double(stats.packetsLost) / Double(stats.packetsSent) * 100
        if let recentLossPercent {
            return String(format: "%.2f%% · %.2f%% total", recentLossPercent, cumulative)
        }
        return String(format: "%.2f%% total", cumulative)
    }

    private func poll() async {
        let new = await TSSHCallGate.shared.transportStats(transportRef)
        guard let new else {
            // Transport gone (disconnected or replaced by a reconnect):
            // drop the rate window so rates restart cleanly if it returns.
            stats = nil
            previous = nil
            recentDownKbps = nil
            recentUpKbps = nil
            recentLossPercent = nil
            return
        }
        let now = ContinuousClock.now
        if let previous {
            let seconds = Double(previous.at.duration(to: now).components.seconds)
                + Double(previous.at.duration(to: now).components.attoseconds) / 1e18
            if seconds > 0.2 {
                // Clamp deltas at 0: QUIC loss counters are non-monotonic,
                // and counters restart when a transport is replaced.
                let downBytes = max(0, new.bytesReceived - previous.stats.bytesReceived)
                let upBytes = max(0, new.bytesSent - previous.stats.bytesSent)
                recentDownKbps = Double(downBytes) * 8 / 1_000 / seconds
                recentUpKbps = Double(upBytes) * 8 / 1_000 / seconds
                let sentDelta = max(0, new.packetsSent - previous.stats.packetsSent)
                let lostDelta = max(0, new.packetsLost - previous.stats.packetsLost)
                recentLossPercent = sentDelta > 0
                    ? Double(lostDelta) / Double(sentDelta) * 100 : nil
            }
        }
        previous = (new, now)
        stats = new
    }

    private func row(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .themedRow()
    }
}
