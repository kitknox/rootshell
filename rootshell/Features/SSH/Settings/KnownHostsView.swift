import SwiftUI

/// View for managing known SSH hosts
struct KnownHostsView: View {
    @StateObject private var manager = KnownHostsManager.shared
    @Setting(Settings.HostTrust.verifyHostKeyDNS) private var verifyHostKeyDNS
    @Setting(Settings.HostTrust.verifyHostKeyDNSResolver) private var dnsResolver
    @State private var showingClearAllAlert = false
    @State private var searchText = ""

    private var dnsFooterText: String {
        let provider = dnsResolver.displayName
        return String(localized: "Looks up the host's SSHFP records through \(provider) over HTTPS and shows in the trust prompt whether its key matches. Trust DNSSEC Matches also connects without a prompt when a DNSSEC-signed record matches. When on, \(provider) sees the hostnames you connect to.", comment: "SSHFP host key verification setting footer")
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Section {
                    Picker(selection: $verifyHostKeyDNS) {
                        ForEach(HostKeyDNSVerification.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        Text("Verify Host Keys via DNS")
                            .settingRow(Settings.HostTrust.verifyHostKeyDNS)
                    }
                    .pickerStyle(.menu)
                    .disabled(SettingFileLock.isReadOnly(Settings.HostTrust.verifyHostKeyDNS.name))
                    .themedRow()

                    if verifyHostKeyDNS != .off {
                        Picker(selection: $dnsResolver) {
                            ForEach(SSHFPDoHProvider.allCases, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        } label: {
                            Text("DNS Resolver")
                                .settingRow(Settings.HostTrust.verifyHostKeyDNSResolver)
                        }
                        .pickerStyle(.menu)
                        .disabled(SettingFileLock.isReadOnly(Settings.HostTrust.verifyHostKeyDNSResolver.name))
                        .themedRow()
                    }
                } header: {
                    SettingGroupHeader("DNS (SSHFP)", group: .hostTrust)
                } footer: {
                    Text(dnsFooterText)
                }
            }

            if filteredHosts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        if searchText.isEmpty {
                            Text("No Known Hosts")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("SSH host keys will appear here after you connect and trust them")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else {
                            Text("No matching hosts")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .themedRow()
                }
            } else {
                ForEach(filteredHosts) { host in
                    NavigationLink(destination: KnownHostDetailView(host: host)) {
                        KnownHostRow(host: host)
                    }
                    .hostAddressCopyMenu(hostname: host.hostname)
                }
                .onDelete(perform: deleteHosts)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Known Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search hosts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !manager.allHosts.isEmpty {
                    Button(role: .destructive) {
                        showingClearAllAlert = true
                    } label: {
                        Text("Clear All")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .alert("Clear All Known Hosts?", isPresented: $showingClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                manager.removeAll()
            }
        } message: {
            Text("This will remove all trusted SSH host keys. You will need to verify and trust hosts again on your next connection.")
        }
    }

    private var filteredHosts: [KnownHost] {
        if searchText.isEmpty {
            return manager.allHosts
        } else {
            return manager.allHosts.filter { host in
                host.hostname.localizedCaseInsensitiveContains(searchText) ||
                host.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func deleteHosts(at offsets: IndexSet) {
        let hostsToDelete = offsets.map { filteredHosts[$0] }
        for host in hostsToDelete {
            manager.removeHost(hostname: host.hostname, port: host.port)
        }
    }
}

/// Row view for a known host entry
struct KnownHostRow: View {
    let host: KnownHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(host.displayName)
                    .font(.headline)

                Spacer()

                // Key type badge
                Text(host.keyType.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(keyTypeColor(for: host.keyType))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(keyTypeColor(for: host.keyType).opacity(0.18))
                    .cornerRadius(4)
            }

            Text(host.shortFingerprint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)

            Text("Last verified: \(host.lastSeen, formatter: relativeDateFormatter)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func keyTypeColor(for keyType: String) -> Color {
        switch keyType.lowercased() {
        case let type where type.contains("ed25519"):
            return .green
        case let type where type.contains("ecdsa"):
            return .blue
        case let type where type.contains("rsa"):
            return .orange
        default:
            return .secondary
        }
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }
}

#Preview {
    NavigationView {
        KnownHostsView()
    }
}
