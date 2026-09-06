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
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var showDisconnectConfirmation = false

    var body: some View {
        List {
            statusSection
            disconnectSection
            vpnProfilesSection
            eventHistorySection
            debugSection
        }
        .themedList()
        .navigationTitle("VPN")
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Status") {
            VPNStatusRow()
                .themedRow()

            if vpnManager.extensionApprovalPending {
                Label(
                    "Approve the VPN system extension in System Settings → Login Items & Extensions to finish connecting.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .themedRow()
            }

            if vpnManager.status.isActive {
                if let since = vpnManager.connectedSince {
                    LabeledContent("Uptime") {
                        Text(since, style: .timer)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
                if let stats = vpnManager.statistics {
                    VPNStatsGrid(stats: stats)
                        .themedRow()
                }

                if vpnManager.trafficHistory.count >= 2 {
                    VPNTrafficChart(snapshots: vpnManager.trafficHistory)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Disconnect Section

    @ViewBuilder
    private var disconnectSection: some View {
        if vpnManager.status.isActive {
            Section {
                Button("Disconnect VPN", role: .destructive) {
                    showDisconnectConfirmation = true
                }
                .confirmationDialog(
                    "Disconnect VPN?",
                    isPresented: $showDisconnectConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) {
                        Task {
                            try? await vpnManager.stopVPN()
                        }
                    }
                } message: {
                    let name = vpnManager.activeProfileName ?? "the active profile"
                    Text("This will end your connection to \(name).")
                }
                .themedRow()
            }
        }
    }

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

// MARK: - VPN Stats Grid (compact single-row layout)

private struct VPNStatsGrid: View {
    let stats: VPNStatistics

    var body: some View {
        VStack(spacing: 6) {
            if let mode = stats.tsshMode {
                statRow("Transport", mode)
                if let mtu = stats.tsshMTU, mtu > 0 {
                    statRow("TSSH MTU", "\(mtu)")
                }
                if let tunMTU = stats.tunMTU, tunMTU > 0 {
                    statRow("TUN MTU", "\(tunMTU)")
                }
                if let port = stats.tsshPort {
                    statRow("Port", "\(port)")
                }
            }
            statRow("Downloaded", stats.formattedBytesIn)
            statRow("Uploaded", stats.formattedBytesOut)
            statRow("Active Flows", "\(stats.activeConnections)")
            if stats.activeTCPConnections > 0 || stats.activeUDPConnections > 0 {
                statRow("TCP / UDP", "\(stats.activeTCPConnections) / \(stats.activeUDPConnections)")
            }
            if stats.tcpCapacityDrops + stats.udpCapacityDrops > 0 {
                statRow("Flow Drops", "TCP \(stats.tcpCapacityDrops), UDP \(stats.udpCapacityDrops)", valueColor: .orange)
            }
            if stats.extensionPhysFootprintBytes > 0 {
                statRow("Ext Memory", stats.formattedExtensionMemory)
            }
            if stats.extensionMemoryBudgetBytes > 0 {
                let usagePercent = stats.effectiveMemoryUsagePercent
                let color: Color = usagePercent >= 90 ? .red : (usagePercent >= 75 ? .orange : .secondary)
                statRow("Mem Budget", stats.formattedMemoryBudgetUsage, valueColor: color)
            }
            if stats.goHeapAllocBytes > 0 {
                statRow("Go Heap", stats.formattedGoHeapAlloc)
            }
        }
        .padding(.vertical, 2)
    }

    private func statRow(_ label: String, _ value: String, valueColor: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
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
