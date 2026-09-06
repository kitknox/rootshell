//
//  QuickConnectSuggestionProvider.swift
//  rootshell
//
//  Aggregates suggestions from multiple sources (history, cloud instances)
//

import Foundation
import Combine
import os.log

/// Aggregates suggestions from multiple sources for quick connect
@MainActor
class QuickConnectSuggestionProvider: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SuggestionProvider")

    static let shared = QuickConnectSuggestionProvider()

    // MARK: - Dependencies

    private let profileManager: ConnectionProfileManager
    private let historyManager: SSHConnectionHistoryManager
    private let cloudCacheManager: CloudCacheManager
    private let cloudAccountManager: CloudAccountManager
    private let localNetworkManager: LocalNetworkDiscoveryManager

    // MARK: - Configuration

    /// Maximum suggestions to return
    let maxSuggestions = 15

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init(
        profileManager: ConnectionProfileManager? = nil,
        historyManager: SSHConnectionHistoryManager? = nil,
        cloudCacheManager: CloudCacheManager? = nil,
        cloudAccountManager: CloudAccountManager? = nil,
        localNetworkManager: LocalNetworkDiscoveryManager? = nil
    ) {
        self.profileManager = profileManager ?? .shared
        self.historyManager = historyManager ?? .shared
        self.cloudCacheManager = cloudCacheManager ?? .shared
        self.cloudAccountManager = cloudAccountManager ?? .shared
        self.localNetworkManager = localNetworkManager ?? .shared

        // Observe cloud cache changes to trigger UI updates
        self.cloudCacheManager.cacheDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observe local network discovery changes
        self.localNetworkManager.cacheDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    enum Context {
        case connectionLauncher
        case sshDestination
    }

    /// Get unified suggestions matching search text
    func getSuggestions(
        matching searchText: String,
        mode: MatchingMode = .prefix,
        context: Context = .connectionLauncher
    ) -> [AnyQuickConnectSuggestion] {
        var all: [AnyQuickConnectSuggestion] = []

        // Profile suggestions (highest priority)
        let profiles = profileManager.availableProfiles
            .filter { !$0.isDeleted && (context == .connectionLauncher || $0.isSSHBased) }
            .map { ProfileSuggestion(profile: $0) }
            .filter { searchText.isEmpty || $0.matches(searchText, mode: mode) }
            .map { AnyQuickConnectSuggestion($0) }
        all.append(contentsOf: profiles)

        // History suggestions
        let history = historyManager.entries
            .filter { context == .connectionLauncher || ($0.connectionProtocol != .vnc && $0.connectionProtocol != .local) }
            .map { HistorySuggestion(entry: $0) }
            .filter { searchText.isEmpty || $0.matches(searchText, mode: mode) }
            .map { AnyQuickConnectSuggestion($0) }
        all.append(contentsOf: history)

        // Local network (mDNS) suggestions
        let localNetwork = makeLocalNetworkSuggestions()
            .filter { context == .connectionLauncher || $0.host.kind == .ssh }
            .filter { searchText.isEmpty || $0.matches(searchText, mode: mode) }
            .map { AnyQuickConnectSuggestion($0) }
        all.append(contentsOf: localNetwork)

        // Cloud instance suggestions
        let cloud = makeCloudSuggestions()
            .filter { searchText.isEmpty || $0.matches(searchText, mode: mode) }
            .map { AnyQuickConnectSuggestion($0) }
        all.append(contentsOf: cloud)

        return sortAndDeduplicate(all, searchText: searchText)
    }

    // MARK: - Private

    private func makeCloudSuggestions() -> [CloudInstanceSuggestion] {
        cloudCacheManager.allInstances.compactMap { instance in
            guard let account = cloudAccountManager.account(for: instance.accountID) else { return nil }
            // Only include instances that can SSH
            guard instance.canSSH else { return nil }
            let name = providerDisplayName(for: account.providerID)
            return CloudInstanceSuggestion(instance: instance, providerDisplayName: name)
        }
    }

    private func makeLocalNetworkSuggestions() -> [LocalNetworkSuggestion] {
        localNetworkManager.discoveredHosts.map { host in
            // Try to find matching history entry by hostname. SSH history is
            // meaningless for Screen Sharing hosts, so only .ssh cross-matches.
            let matchedEntry: SSHConnectionHistoryEntry?
            if host.kind == .ssh {
                matchedEntry = historyManager.entries.first { entry in
                    let entryHost = entry.host.lowercased()
                    let discoveredHost = host.hostname.lowercased()
                    let discoveredWithoutLocal = host.hostname.lowercased()
                        .replacingOccurrences(of: ".local", with: "")

                    return entryHost == discoveredHost ||
                           entryHost == discoveredWithoutLocal
                }
            } else {
                matchedEntry = nil
            }
            return LocalNetworkSuggestion(host: host, matchedHistoryEntry: matchedEntry)
        }
    }

    private func providerDisplayName(for id: String) -> String {
        switch id {
        case "linode": return "Linode"
        case "aws": return "AWS"
        case "gcp": return "GCP"
        case "azure": return "Azure"
        case "digitalocean": return "DigitalOcean"
        case "tailscale": return "Tailscale"
        default: return id.capitalized
        }
    }

    private func sortAndDeduplicate(
        _ suggestions: [AnyQuickConnectSuggestion],
        searchText: String
    ) -> [AnyQuickConnectSuggestion] {
        let query = searchText.lowercased()

        // Priority order: profile > history > localNetwork > cloud
        let sourceTypePriority: [SuggestionSourceType: Int] = [
            .profile: -1,
            .history: 0,
            .localNetwork: 1,
            .cloudInstance: 2
        ]

        let sorted = suggestions.sorted { a, b in
            // Exact matches first
            let aExact = a.displayString.lowercased() == query ||
                         a.completionString.lowercased() == query
            let bExact = b.displayString.lowercased() == query ||
                         b.completionString.lowercased() == query
            if aExact != bExact { return aExact }

            // Sort by source type priority: history > localNetwork > cloud
            if a.sourceType != b.sourceType {
                let aPriority = sourceTypePriority[a.sourceType] ?? 99
                let bPriority = sourceTypePriority[b.sourceType] ?? 99
                return aPriority < bPriority
            }

            // By priority within type
            return a.sortPriority < b.sortPriority
        }

        // Dedupe by completionString (avoid duplicate connections)
        var seen = Set<String>()
        let deduped = sorted.filter { s in
            let key = s.completionString.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return Array(deduped.prefix(maxSuggestions))
    }
}
