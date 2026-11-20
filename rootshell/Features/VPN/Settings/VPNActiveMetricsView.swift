//
//  VPNActiveMetricsView.swift
//  rootshell
//
//  Visual health metrics (flows, memory budget gauge, capacity alerts) and
//  collapsible technical tunnel details for an active VPN connection.
//

import SwiftUI

// MARK: - Live Connection Health Summary

struct VPNConnectionHealthView: View {
    let stats: VPNStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            flowsSummary

            if stats.extensionMemoryBudgetBytes > 0 {
                Divider()
                memoryGauge
            }

            if stats.tcpCapacityDrops + stats.udpCapacityDrops > 0 {
                dropsWarning
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Active Flows

    private var flowsSummary: some View {
        let tcp = stats.activeTCPConnections
        let udp = stats.activeUDPConnections
        let splitTotal = tcp + udp

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Active Flows", comment: "VPN active flows label"))
                }
                .font(.subheadline.weight(.medium))

                Spacer()

                Text("\(stats.activeConnections)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }

            if splitTotal > 0 {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let tcpRatio = CGFloat(tcp) / CGFloat(splitTotal)
                    HStack(spacing: 2) {
                        if tcp > 0 {
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: max(6, width * tcpRatio - (udp > 0 ? 1 : 0)))
                        }
                        if udp > 0 {
                            Capsule()
                                .fill(Color.teal)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 5)
            }

            if splitTotal > 0 || stats.activeConnections == 0 || stats.totalConnections > 0 {
                HStack(spacing: 12) {
                    if splitTotal > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue).frame(width: 6, height: 6)
                            Text("TCP \(tcp)")
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.teal).frame(width: 6, height: 6)
                            Text("UDP \(udp)")
                        }
                    } else if stats.activeConnections == 0 {
                        Text(String(localized: "Idle", comment: "VPN active flows when none are open"))
                    }

                    Spacer()

                    if stats.totalConnections > 0 {
                        Text(String(localized: "\(stats.totalConnections) total", comment: "VPN total connections in current session"))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Extension Memory Gauge

    private var memoryGauge: some View {
        let percent = stats.effectiveMemoryUsagePercent
        let clampedFraction = min(max(percent / 100.0, 0), 1)
        let barColor: Color = percent >= 90 ? .red : (percent >= 75 ? .orange : .green)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Extension Memory", comment: "VPN extension memory budget label"))
                }
                .font(.subheadline.weight(.medium))

                Spacer()

                Text(stats.formattedMemoryBudgetUsage)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(percent >= 75 ? barColor : .primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, proxy.size.width * clampedFraction))
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(stats.formattedExtensionMemory) / \(stats.formattedMemoryBudget)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if percent >= 90 {
                    Text(String(localized: "High pressure", comment: "VPN memory pressure critical warning"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                } else if percent >= 75 {
                    Text(String(localized: "Elevated", comment: "VPN memory pressure elevated warning"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Capacity Drops Banner

    private var dropsWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(String(
                localized: "Flow capacity drops: TCP \(stats.tcpCapacityDrops), UDP \(stats.udpCapacityDrops)",
                comment: "VPN warning when TCP or UDP flows were dropped"
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Collapsible Technical Tunnel Details

struct VPNTunnelDetailsDisclosure: View {
    let stats: VPNStatistics?
    let profile: ConnectionProfile?
    let isLocalCapture: Bool
    #if !CHINA_BUILD
    let isTailnet: Bool
    let isInAppTailnet: Bool
    let tailnetStatus: TailnetStatus?
    #endif

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(
            String(localized: "Tunnel Details", comment: "VPN settings collapsible technical details"),
            isExpanded: $isExpanded
        ) {
            VStack(spacing: 8) {
                transportRows
                #if !CHINA_BUILD
                tailnetRows
                #endif
                runtimeRows
                profileRows
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
        .font(.subheadline)
    }

    // MARK: - Transport Rows

    @ViewBuilder
    private var transportRows: some View {
        if let transport = resolvedTransport {
            detailRow(String(localized: "Transport", comment: "VPN detail row"), transport)
        }
        if let port = stats?.tsshPort {
            detailRow(String(localized: "UDP Port", comment: "VPN detail row"), "\(port)")
        }
        if let tsshMTU = stats?.tsshMTU, tsshMTU > 0 {
            detailRow(String(localized: "TSSH MTU", comment: "VPN detail row"), "\(tsshMTU)")
        }
        if let tunMTU = stats?.tunMTU, tunMTU > 0 {
            detailRow(String(localized: "TUN MTU", comment: "VPN detail row"), "\(tunMTU)")
        }
    }

    // MARK: - Tailscale Live Rows

    #if !CHINA_BUILD
    @ViewBuilder
    private var tailnetRows: some View {
        if isTailnet || isInAppTailnet {
            detailRow(
                String(localized: "Mode", comment: "VPN Tailscale detail row"),
                isInAppTailnet
                    ? String(localized: "rootshell Only", comment: "Tailscale in-app mode")
                    : String(localized: "Whole Device", comment: "Tailscale whole-device mode")
            )
            if let tailnet = tailnetStatus?.tailnet, !tailnet.isEmpty {
                detailRow(String(localized: "Tailnet", comment: "VPN Tailscale detail row"), tailnet)
            }
            if let selfNode = tailnetStatus?.selfNode, let ip = selfNode.ips?.first {
                detailRow(String(localized: "Device IP", comment: "VPN Tailscale detail row"), ip, monospaced: true)
                    .hostAddressCopyMenu(name: selfNode.displayName, hostname: selfNode.dnsName, ipAddress: ip)
            }
            let peers = tailnetStatus?.peers ?? []
            if let total = tailnetStatus?.peersTotal, total > peers.count {
                detailRow(
                    String(localized: "Devices", comment: "VPN Tailscale detail row when peer list is truncated"),
                    "\(total)"
                )
            } else if !peers.isEmpty {
                let online = peers.filter(\.online).count
                detailRow(
                    String(localized: "Peers Online", comment: "VPN Tailscale detail row"),
                    "\(online) / \(peers.count)"
                )
            }
            if isTailnet, let egress = tailnetStatus?.egress, !egress.isOff {
                let stateText = egress.localizedStateText
                let egressLabel = if let host = egress.host, !host.isEmpty, egress.state != "failed" {
                    "\(stateText) (\(host))"
                } else {
                    stateText
                }
                detailRow(
                    String(localized: "SSH Egress", comment: "VPN Tailscale detail row"),
                    egressLabel,
                    valueColor: egress.state == "failed" ? .orange : .secondary
                )
            }
        }
    }
    #endif

    // MARK: - Saved Profile Rows

    @ViewBuilder
    private var profileRows: some View {
        if let profile {
            Divider()
                .padding(.vertical, 2)

            HStack {
                Text(String(localized: "Saved Profile (applied on connect)", comment: "VPN tunnel details caption for profile settings"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            let endpoint = profile.sshConfig.port == 22
                ? profile.sshConfig.host
                : "\(profile.sshConfig.host):\(profile.sshConfig.port)"
            detailRow(String(localized: "Server", comment: "VPN detail row"), endpoint, monospaced: true)
                .hostAddressCopyMenu(name: profile.name, hostname: profile.sshConfig.host)

            let jumps = profile.sshConfig.jumpChain
            if !jumps.isEmpty {
                let summary = jumps.map(\.host).joined(separator: " → ")
                detailRow(
                    jumps.count == 1
                        ? String(localized: "Jump Host", comment: "VPN detail row")
                        : String(localized: "Jump Hosts", comment: "VPN detail row"),
                    summary,
                    monospaced: true
                )
            }

            if !profile.vpnDNSServers.isEmpty {
                detailRow(
                    String(localized: "DNS Servers", comment: "VPN detail row"),
                    profile.vpnDNSServers.joined(separator: ", "),
                    monospaced: true
                )
            }

            if !profile.vpnExcludedRoutes.isEmpty {
                detailRow(
                    String(localized: "Excluded Routes", comment: "VPN detail row"),
                    "\(profile.vpnExcludedRoutes.count)"
                )
            }
        }
    }

    // MARK: - Runtime & Diagnostic Rows

    @ViewBuilder
    private var runtimeRows: some View {
        if let stats {
            if stats.totalConnections > 0 {
                detailRow(String(localized: "Total Connections", comment: "VPN detail row"), "\(stats.totalConnections)")
            }
            if stats.extensionPhysFootprintBytes > 0 && stats.extensionMemoryBudgetBytes == 0 {
                detailRow(String(localized: "Ext Memory", comment: "VPN detail row"), stats.formattedExtensionMemory)
            }
            if stats.goHeapAllocBytes > 0 {
                detailRow(String(localized: "Go Heap", comment: "VPN detail row"), stats.formattedGoHeapAlloc)
            }
            if stats.goGoroutines > 0 {
                detailRow(String(localized: "Goroutines", comment: "VPN detail row"), "\(stats.goGoroutines)")
            }
        }
    }

    // MARK: - Helpers

    private var resolvedTransport: String? {
        if let label = stats?.displayTransportLabel {
            return label
        }
        #if !CHINA_BUILD
        if isTailnet || isInAppTailnet {
            return "Tailscale"
        }
        #endif
        if isLocalCapture {
            return String(localized: "Direct (Local Capture)", comment: "VPN transport label for local capture")
        }
        return profile?.vpnTransportName
    }

    private func detailRow(
        _ label: String,
        _ value: String,
        valueColor: Color = .secondary,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption.monospacedDigit())
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
