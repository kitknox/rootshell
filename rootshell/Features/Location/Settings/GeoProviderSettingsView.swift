//
//  GeoProviderSettingsView.swift
//  rootshell
//
//  Settings view for configuring the IP geolocation provider,
//  with live public IP discovery and geo info display.
//

import SwiftUI
import Combine

struct GeoProviderSettingsView: View {
    private var resolver = GeoResolver.shared
    private var mmdbManager = MMDBDatabaseManager.shared
    @ObservedObject private var networkMonitor = NetworkReachabilityMonitor.shared
    @ObservedObject private var wifiService = WiFiInfoService.shared

    @State private var discoveryTask: Task<Void, Never>?
    @State private var isDiscovering = false
    @State private var ipv4Address: String?
    @State private var ipv6Address: String?
    @State private var ipv4Error: String?
    @State private var ipv6Error: String?
    @State private var ipv4Geo: GeoInfo?
    @State private var ipv6Geo: GeoInfo?
    @State private var isResolvingGeo = false
    @State private var copied = false

    var body: some View {
        Form {
            // Provider Selection
            Section {
                ForEach(GeoProviderType.availableCases, id: \.self) { provider in
                    Button {
                        resolver.providerType = provider
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.displayName)
                                Text(provider.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if resolver.providerType == provider {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                switch resolver.providerType {
                case .ipinfo:
                    Text("Uses the IPInfo Lite API to look up ASN, organization name, country, and continent for IP addresses. IP addresses are sent to ipinfo.io over HTTPS.")
                case .internetdata:
                    Text("Uses the InternetData API to look up ASN, organization name, network, country, and continent for IP addresses. IP addresses are sent to internetdata.io over HTTPS.")
                case .mmdb:
                    Text("Uses locally imported MMDB files. No IP addresses leave the device. You can import multiple ASN/country databases and the app merges the fields it finds.")
                case .dns:
                    Text("Uses Team Cymru DNS TXT queries for ASN and country code lookups. No HTTP requests are made.")
                case .disabled:
                    Text("No geolocation lookups will be performed. IP addresses will be shown without network information.")
                }
            }

            if resolver.providerType == .mmdb || mmdbManager.hasDatabases {
                mmdbSection
            }

            if resolver.providerType != .disabled {
                // Cache Management
                Section {
                    Button(role: .destructive) {
                        resolver.clearCache()
                    } label: {
                        HStack {
                            Text("Clear Geo Cache")
                            Spacer()
                            let count = resolver.cacheEntryCount
                            Text("\(count) \(count == 1 ? "entry" : "entries")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .themedRow()
                }

                // Network Status
                Section("Network") {
                    HStack {
                        Image(systemName: connectionTypeIcon)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(networkMonitor.connectionType.description)
                        Spacer()
                        if networkMonitor.isExpensive {
                            Text("Metered")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    .themedRow()
                }

                // WiFi Info (hidden when not on WiFi)
                #if targetEnvironment(macCatalyst)
                if wifiService.hasWiFiData {
                    wifiSection
                }
                #else
                if wifiService.hasWiFiData {
                    wifiSection
                } else if wifiService.canRequestPermission {
                    wifiOptInSection
                }
                #endif

                // Public IPs
                Section {
                    ipRow(label: "IPv4", address: ipv4Address, error: ipv4Error,
                          isLoading: isDiscovering && ipv4Address == nil && ipv4Error == nil)
                        .themedRow()
                    ipRow(label: "IPv6", address: ipv6Address, error: ipv6Error,
                          isLoading: isDiscovering && ipv6Address == nil && ipv6Error == nil)
                        .themedRow()
                } header: {
                    HStack {
                        Text("Your Public IPs")
                        Spacer()
                        if isDiscovering || isResolvingGeo {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                performDiscovery()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                    }
                }

                // IPv4 Geo Details
                if let geo = ipv4Geo {
                    geoSection(title: "IPv4 Network Info", geo: geo)
                }

                // IPv6 Geo Details
                if let geo = ipv6Geo {
                    geoSection(title: "IPv6 Network Info", geo: geo)
                }

                // Copy All
                if ipv4Address != nil || ipv6Address != nil {
                    Section {
                        Button {
                            copyAll()
                        } label: {
                            HStack {
                                Spacer()
                                if copied {
                                    Label("Copied!", systemImage: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("Copy All", systemImage: "doc.on.doc")
                                }
                                Spacer()
                            }
                        }
                        .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("IP Geolocation")
        .task {
            if resolver.providerType != .disabled {
                performDiscovery()
                await wifiService.fetch()
            }
        }
        .task(id: resolver.providerType) {
            // Poll WiFi info periodically so BSSID updates as you roam between APs.
            // NWPathMonitor doesn't fire on AP roaming within the same network.
            guard resolver.providerType != .disabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await wifiService.pollForChanges()
            }
        }
        .onChange(of: resolver.providerType) { oldValue, newValue in
            if newValue == .disabled {
                discoveryTask?.cancel()
                discoveryTask = nil
                clearResults()
            } else if oldValue == .disabled {
                performDiscovery()
            } else if !isDiscovering {
                // Provider changed (enabled→enabled) — re-resolve geo only
                resolveGeoForDiscoveredIPs()
            }
            // If still discovering, geo resolve after STUN will use the new provider
        }
        .onChange(of: mmdbManager.databases) { _, _ in
            guard resolver.providerType == .mmdb, !isDiscovering else { return }
            resolveGeoForDiscoveredIPs()
        }
        .onReceive(networkMonitor.connectivityRestored) { _ in
            if resolver.providerType != .disabled {
                performDiscovery()
                Task { await wifiService.fetch() }
            }
        }
        .onReceive(networkMonitor.connectionTypeChanged) { _ in
            if resolver.providerType != .disabled {
                performDiscovery()
                Task { await wifiService.fetch() }
            }
        }
        .onDisappear {
            discoveryTask?.cancel()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var mmdbSection: some View {
        Section {
            NavigationLink {
                MMDBDatabaseSettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local MMDB Databases")
                        Text(mmdbSummaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if mmdbManager.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedRow()
        } header: {
            Text("Local MMDB Databases")
        }
    }

    private var mmdbSummaryText: String {
        if mmdbManager.isLoading {
            return "Loading databases"
        }
        if let error = mmdbManager.lastErrorMessage, !error.isEmpty {
            return String(localized: "\(mmdbManager.loadedDatabaseCount) of \(mmdbManager.databases.count) loaded with errors", comment: "GeoIP database status")
        }
        if mmdbManager.databases.isEmpty {
            return String(localized: "Import local MMDB databases", comment: "GeoIP database status")
        }
        return String(localized: "\(mmdbManager.loadedDatabaseCount) of \(mmdbManager.databases.count) loaded", comment: "GeoIP database status")
    }

    #if !targetEnvironment(macCatalyst)
    private var wifiOptInSection: some View {
        Section("WiFi") {
            Button {
                Task { await wifiService.requestPermissionAndFetch() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "location")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable WiFi Info")
                        Text("Requires location permission to read SSID and BSSID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .themedRow()
        }
    }
    #endif

    @ViewBuilder
    private var wifiSection: some View {
        Section("WiFi") {
            if wifiService.isFetching {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching WiFi info…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .themedRow()
            } else if let error = wifiService.fetchError {
                HStack {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .themedRow()
            } else {
                if let ssid = wifiService.ssid {
                    infoRow("SSID", value: ssid)
                        .themedRow()
                }
                if let bssid = wifiService.bssid {
                    HStack {
                        Text("BSSID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(bssid)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .themedRow()
                }
                if wifiService.isRandomizedMAC {
                    infoRow("Vendor", value: "(randomized MAC)")
                        .themedRow()
                } else if let vendor = wifiService.vendorName {
                    infoRow("Vendor", value: vendor)
                        .themedRow()
                }
                if let website = wifiService.vendorWebsite {
                    let domain = FaviconFetcher.extractDomain(from: website)
                    if let domain {
                        faviconInfoRow("Website", domain: domain)
                            .themedRow()
                    } else {
                        infoRow("Website", value: website)
                            .themedRow()
                    }
                }
                if let ap = wifiService.matchedAP {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("AP")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(ap.name)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Spacer()
                            Text(formatAPDetail(ap))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .themedRow()
                }
            }
        }
    }

    private func formatAPText(_ ap: WiFiAccessPoint) -> String {
        var text = ap.name
        if let model = ap.shortname ?? ap.model {
            text += " (\(model))"
        }
        if let site = ap.siteName {
            text += " @ \(site)"
        }
        return text
    }

    private func formatAPDetail(_ ap: WiFiAccessPoint) -> String {
        var parts: [String] = []
        if let model = ap.shortname ?? ap.model {
            parts.append(model)
        }
        if let site = ap.siteName {
            parts.append(site)
        }
        return parts.joined(separator: " · ")
    }

    private var connectionTypeIcon: String {
        switch networkMonitor.connectionType {
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .wired: "cable.connector"
        case .loopback: "arrow.triangle.2.circlepath"
        case .unknown: "questionmark.circle"
        }
    }

    private func ipRow(label: String, address: String?, error: String?, isLoading: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let address {
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func geoSection(title: String, geo: GeoInfo) -> some View {
        Section(title) {
            infoRow("ASN", value: geo.asNumber)
                .themedRow()
            if let name = geo.asName, !name.isEmpty {
                infoRow("Organization", value: name)
                    .themedRow()
            }
            if let domain = geo.asDomain, !domain.isEmpty {
                faviconInfoRow("Domain", domain: domain)
                    .themedRow()
            }
            if !geo.network.isEmpty {
                infoRow("Network", value: geo.network)
                    .themedRow()
            }
            if let city = geo.cityName, !city.isEmpty {
                infoRow("City", value: city)
                    .themedRow()
            }
            if !geo.countryCode.isEmpty {
                infoRow("Country", value: geo.countryWithFlag)
                    .themedRow()
            }
            if let name = geo.countryName, !name.isEmpty {
                infoRow("Country Name", value: name)
                    .themedRow()
            }
            if let continent = geo.continentName, !continent.isEmpty {
                infoRow("Continent", value: continent)
                    .themedRow()
            }
            if !geo.rir.isEmpty {
                infoRow("RIR", value: geo.rir.uppercased())
                    .themedRow()
            }
            if !geo.allocationDate.isEmpty {
                infoRow("Allocated", value: geo.allocationDate)
                    .themedRow()
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
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
    }

    // MARK: - Actions

    private func performDiscovery() {
        discoveryTask?.cancel()
        clearResults()
        isDiscovering = true

        discoveryTask = Task {
            await discoverIPs()
            guard !Task.isCancelled else { return }
            isDiscovering = false
            await resolveGeo()
        }
    }

    private func discoverIPs() async {
        // Only skip IPv6 if unavailable. IPv4 is always attempted because NAT64
        // networks (e.g. T-Mobile) report supportsIPv4=false yet still reach
        // IPv4 STUN servers via DNS64-synthesized addresses.
        let hasIPv6 = networkMonitor.supportsIPv6

        if !hasIPv6 {
            ipv6Error = "not available"
        }

        await withTaskGroup(of: (AddressFamily, String?, Error?).self) { group in
            group.addTask { @MainActor in
                let client = STUNClient()
                do {
                    let result = try await client.discover(addressFamily: .ipv4, timeout: 3.0)
                    return (.ipv4, result.publicIP, nil)
                } catch {
                    return (.ipv4, nil, error)
                }
            }
            if hasIPv6 {
                group.addTask { @MainActor in
                    let client = STUNClient()
                    do {
                        let result = try await client.discover(addressFamily: .ipv6, timeout: 3.0)
                        return (.ipv6, result.publicIP, nil)
                    } catch {
                        return (.ipv6, nil, error)
                    }
                }
            }

            for await (family, ip, error) in group {
                guard !Task.isCancelled else { return }
                switch family {
                case .ipv4:
                    ipv4Address = ip
                    if let error { ipv4Error = error.localizedDescription }
                case .ipv6:
                    ipv6Address = ip
                    if let error { ipv6Error = error.localizedDescription }
                case .auto:
                    break
                }
            }
        }
    }

    private func resolveGeoForDiscoveredIPs() {
        ipv4Geo = nil
        ipv6Geo = nil
        guard ipv4Address != nil || ipv6Address != nil else { return }

        discoveryTask?.cancel()
        discoveryTask = Task {
            await resolveGeo()
        }
    }

    private func resolveGeo() async {
        isResolvingGeo = true
        if let ip = ipv4Address {
            let geo = await GeoResolver.shared.resolve(ip: ip)
            guard !Task.isCancelled else { return }
            ipv4Geo = geo
        }
        if let ip = ipv6Address {
            let geo = await GeoResolver.shared.resolve(ip: ip)
            guard !Task.isCancelled else { return }
            ipv6Geo = geo
        }
        isResolvingGeo = false
    }

    private func clearResults() {
        isDiscovering = false
        isResolvingGeo = false
        ipv4Address = nil
        ipv6Address = nil
        ipv4Error = nil
        ipv6Error = nil
        ipv4Geo = nil
        ipv6Geo = nil
        copied = false
    }

    private func copyAll() {
        var lines: [String] = []
        if let ip = ipv4Address {
            lines.append("IPv4: \(ip)")
            if let geo = ipv4Geo {
                lines.append(formatGeoLine(geo))
            }
        }
        if let ip = ipv6Address {
            lines.append("IPv6: \(ip)")
            if let geo = ipv6Geo {
                lines.append(formatGeoLine(geo))
            }
        }
        if wifiService.hasWiFiData {
            if let ssid = wifiService.ssid { lines.append("SSID: \(ssid)") }
            if let bssid = wifiService.bssid { lines.append("BSSID: \(bssid)") }
            if wifiService.isRandomizedMAC {
                lines.append("Vendor: (randomized MAC)")
            } else if let vendor = wifiService.vendorName {
                lines.append("Vendor: \(vendor)")
            }
            if let ap = wifiService.matchedAP {
                lines.append("AP: \(formatAPText(ap))")
            }
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")

        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func formatGeoLine(_ geo: GeoInfo) -> String {
        var parts: [String] = [geo.asNumber]
        if let name = geo.asName, !name.isEmpty { parts.append(name) }
        if let domain = geo.asDomain, !domain.isEmpty { parts.append(domain) }
        if !geo.network.isEmpty { parts.append(geo.network) }
        if let city = geo.cityName, !city.isEmpty { parts.append(city) }
        if !geo.countryCode.isEmpty { parts.append(geo.countryWithFlag) }
        return "  \(parts.joined(separator: " | "))"
    }
}
