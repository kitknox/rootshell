//
//  SSHConnectionHistory.swift
//  rootshell
//
//  Manages history of successful SSH connections for auto-completion
//

import Foundation
import Combine
import os.log

/// Simplified auth type for history (doesn't store passwords)
enum SSHAuthType: Codable, Hashable {
    case password      // Password auth (password prompted each time)
    case savedPassword // Password stored in Keychain
    case key(UUID, fingerprint: String?)  // Key ID with optional fingerprint for cross-device resolution
    case none  // Tailscale/WireGuard pre-authenticated (no password needed)
    case keyboardInteractive  // Keyboard-interactive (RFC 4256): server-driven prompts
    /// An auth type written by a newer app version. Preserved verbatim so a
    /// synced history entry is neither dropped nor lossily rewritten.
    case unknown(rawType: String)

    /// Extracts the key ID if this is a key auth type
    var keyID: UUID? {
        if case .key(let id, _) = self { return id }
        return nil
    }

    /// Extracts the fingerprint if this is a key auth type
    var keyFingerprint: String? {
        if case .key(_, let fp) = self { return fp }
        return nil
    }

    /// Whether this is a key-based auth type
    var isKey: Bool {
        if case .key = self { return true }
        return false
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case type, keyID, fingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "password":
            self = .password
        case "savedPassword":
            self = .savedPassword
        case "key":
            let keyID = try container.decode(UUID.self, forKey: .keyID)
            let fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
            self = .key(keyID, fingerprint: fingerprint)
        case "none":
            self = .none
        case "keyboardInteractive":
            self = .keyboardInteractive
        default:
            // Preserve unknown future types instead of throwing — a thrown error
            // would drop the synced history entry on this (older) build.
            self = .unknown(rawType: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .password:
            try container.encode("password", forKey: .type)
        case .savedPassword:
            try container.encode("savedPassword", forKey: .type)
        case .key(let keyID, let fingerprint):
            try container.encode("key", forKey: .type)
            try container.encode(keyID, forKey: .keyID)
            try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        case .none:
            try container.encode("none", forKey: .type)
        case .keyboardInteractive:
            try container.encode("keyboardInteractive", forKey: .type)
        case .unknown(let rawType):
            try container.encode(rawType, forKey: .type)
        }
    }
}

/// Matching mode for autocomplete suggestions
enum MatchingMode {
    case prefix      // Match from beginning (default)
    case substring   // Match anywhere in the string (double-tab)
}

/// A single entry in SSH connection history
struct SSHConnectionHistoryEntry: Codable, Identifiable, Hashable, SyncableRecord {
    let id: UUID
    let username: String
    let host: String
    let port: Int
    var authType: SSHAuthType
    var lastUsed: Date
    var cachedIP: String?  // Resolved IP for .local hostnames (VPN fallback)

    // Jump host info (optional)
    var jumpHost: String?
    var jumpPort: Int?
    var jumpUsername: String?
    var jumpAuthType: SSHAuthType?
    var tsshRelay: TSSHRelaySettings? = nil

    // HSS shorthand (optional) - the original !alias used
    var hssShorthand: String?

    // SSH agent forwarding config (optional for backward compatibility)
    var agentConfig: SSHAgentConfig?

    // GPG agent forwarding config (optional for backward compatibility —
    // pre-GPG-feature entries decode as nil and the apply path treats
    // that the same as `.disabled`).
    var gpgAgentConfig: GPGAgentConfig?

    // SSH port forwarding config (optional for backward compatibility)
    var portForwardConfig: PortForwardConfig?

    // tmux auto-enable (optional for backward compatibility)
    var tmuxAutoEnable: Bool?

    // tmux launch mode (regular vs control/-CC). Optional for backward
    // compatibility — nil decodes as regular when applied to a config.
    var tmuxAutoMode: TmuxAutoMode?

    // herdr auto-enable (optional for backward compatibility)
    var herdrAutoEnable: Bool?

    // herdr launch mode (regular vs control). nil decodes as regular.
    var herdrAutoMode: HerdrAutoMode?

    // zmx auto-enable (optional for backward compatibility)
    var zmxAutoEnable: Bool?

    // Launch command to run when the session is ready/started (optional for backward compatibility)
    var launchCommand: String?

    // How launchCommand should be applied. nil defaults to afterConnect for old entries.
    var launchCommandMode: SSHConfig.LaunchCommandMode?

    // Per-connection TERM override. nil inherits the global remote default.
    // Rides the CloudKit `extensionData` envelope, not a schema field.
    var terminalType: String?

    // Per-profile multiplexer session name. nil uses the global default for
    // whichever multiplexer auto-start selects. Rides the CloudKit
    // `extensionData` envelope, not a schema field.
    var multiplexerSessionName: String?

    /// True when this entry was decoded from a CloudKit record that carried an
    /// extension envelope, i.e. the writing device knew about the envelope at
    /// all. Lets the merge tell "explicitly cleared" from "written by a build
    /// that predates the envelope". Sync-only: never persisted, never sent, and
    /// meaningless on entries that didn't come from CloudKit.
    var syncCarriedExtensions: Bool = false

    /// Envelope version the writing device stamped, nil when it wrote none.
    /// Presence of an envelope only proves the writer knew the members of *its*
    /// version, so members added later must gate on this rather than on
    /// `syncCarriedExtensions` — otherwise an older build that round-trips the
    /// envelope without them reads as an explicit clear. Sync-only, like the
    /// flag above.
    var syncEnvelopeVersion: Int?

    // Connection protocol (SSH or Mosh) - nil defaults to SSH for backward compatibility
    var connectionProtocol: ConnectionProtocol?

    // Key resolution hints for cross-device key matching (keyed by UUID string)
    // Covers both target and jump host key UUIDs in the same dict
    var keyResolutionHints: [String: KeyResolutionHint]?

    // Sync support fields
    var modifiedAt: Date
    var isDeleted: Bool

    init(username: String, host: String, port: Int = 22, authType: SSHAuthType,
         connectionProtocol: ConnectionProtocol? = nil,
         jumpHost: String? = nil, jumpPort: Int? = nil, jumpUsername: String? = nil, jumpAuthType: SSHAuthType? = nil,
         lastUsed: Date = Date(), cachedIP: String? = nil, hssShorthand: String? = nil, agentConfig: SSHAgentConfig? = nil, gpgAgentConfig: GPGAgentConfig? = nil, portForwardConfig: PortForwardConfig? = nil, tmuxAutoEnable: Bool? = nil, tmuxAutoMode: TmuxAutoMode? = nil, herdrAutoEnable: Bool? = nil, herdrAutoMode: HerdrAutoMode? = nil, zmxAutoEnable: Bool? = nil, launchCommand: String? = nil, launchCommandMode: SSHConfig.LaunchCommandMode? = nil,
         terminalType: String? = nil,
         multiplexerSessionName: String? = nil,
         keyResolutionHints: [String: KeyResolutionHint]? = nil) {
        self.id = UUID()
        self.username = username
        self.host = host
        self.port = port
        self.authType = authType
        self.connectionProtocol = connectionProtocol
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.jumpAuthType = jumpAuthType
        self.lastUsed = lastUsed
        self.cachedIP = cachedIP
        self.hssShorthand = hssShorthand
        self.agentConfig = agentConfig
        self.gpgAgentConfig = gpgAgentConfig
        self.portForwardConfig = portForwardConfig
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
        self.herdrAutoEnable = herdrAutoEnable
        self.herdrAutoMode = herdrAutoMode
        self.zmxAutoEnable = zmxAutoEnable
        self.launchCommand = launchCommand
        self.launchCommandMode = launchCommandMode
        self.terminalType = terminalType
        self.multiplexerSessionName = multiplexerSessionName
        self.keyResolutionHints = keyResolutionHints
        self.modifiedAt = Date()
        self.isDeleted = false
    }

    /// Initialize with explicit ID (for migration and sync)
    init(id: UUID, username: String, host: String, port: Int = 22, authType: SSHAuthType,
         connectionProtocol: ConnectionProtocol? = nil,
         jumpHost: String? = nil, jumpPort: Int? = nil, jumpUsername: String? = nil, jumpAuthType: SSHAuthType? = nil,
         lastUsed: Date = Date(), cachedIP: String? = nil, hssShorthand: String? = nil,
         agentConfig: SSHAgentConfig? = nil, gpgAgentConfig: GPGAgentConfig? = nil, portForwardConfig: PortForwardConfig? = nil, tmuxAutoEnable: Bool? = nil, tmuxAutoMode: TmuxAutoMode? = nil, herdrAutoEnable: Bool? = nil, herdrAutoMode: HerdrAutoMode? = nil, zmxAutoEnable: Bool? = nil,
         launchCommand: String? = nil, launchCommandMode: SSHConfig.LaunchCommandMode? = nil, terminalType: String? = nil, multiplexerSessionName: String? = nil, keyResolutionHints: [String: KeyResolutionHint]? = nil,
         modifiedAt: Date? = nil, isDeleted: Bool = false) {
        self.id = id
        self.username = username
        self.host = host
        self.port = port
        self.authType = authType
        self.connectionProtocol = connectionProtocol
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.jumpAuthType = jumpAuthType
        self.lastUsed = lastUsed
        self.cachedIP = cachedIP
        self.hssShorthand = hssShorthand
        self.agentConfig = agentConfig
        self.gpgAgentConfig = gpgAgentConfig
        self.portForwardConfig = portForwardConfig
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
        self.herdrAutoEnable = herdrAutoEnable
        self.herdrAutoMode = herdrAutoMode
        self.zmxAutoEnable = zmxAutoEnable
        self.launchCommand = launchCommand
        self.launchCommandMode = launchCommandMode
        self.terminalType = terminalType
        self.multiplexerSessionName = multiplexerSessionName
        self.keyResolutionHints = keyResolutionHints
        self.modifiedAt = modifiedAt ?? Date()
        self.isDeleted = isDeleted
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, username, host, port, authType, lastUsed, cachedIP
        case jumpHost, jumpPort, jumpUsername, jumpAuthType, tsshRelay
        case hssShorthand, agentConfig, gpgAgentConfig, portForwardConfig, tmuxAutoEnable, tmuxAutoMode, herdrAutoEnable, herdrAutoMode, zmxAutoEnable, launchCommand, launchCommandMode
        case connectionProtocol, keyResolutionHints
        case terminalType, multiplexerSessionName
        case modifiedAt, isDeleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // ID: use existing or generate new (for legacy entries)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        username = try container.decode(String.self, forKey: .username)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        authType = try container.decode(SSHAuthType.self, forKey: .authType)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        cachedIP = try container.decodeIfPresent(String.self, forKey: .cachedIP)

        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost)
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort)
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername)
        jumpAuthType = try container.decodeIfPresent(SSHAuthType.self, forKey: .jumpAuthType)
        tsshRelay = try container.decodeIfPresent(TSSHRelaySettings.self, forKey: .tsshRelay)

        hssShorthand = try container.decodeIfPresent(String.self, forKey: .hssShorthand)
        agentConfig = try container.decodeIfPresent(SSHAgentConfig.self, forKey: .agentConfig)
        gpgAgentConfig = try container.decodeIfPresent(GPGAgentConfig.self, forKey: .gpgAgentConfig)
        portForwardConfig = try container.decodeIfPresent(PortForwardConfig.self, forKey: .portForwardConfig)
        tmuxAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .tmuxAutoEnable)
        tmuxAutoMode = try container.decodeIfPresent(TmuxAutoMode.self, forKey: .tmuxAutoMode)
        herdrAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .herdrAutoEnable)
        herdrAutoMode = try container.decodeIfPresent(HerdrAutoMode.self, forKey: .herdrAutoMode)
        zmxAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .zmxAutoEnable)
        launchCommand = try container.decodeIfPresent(String.self, forKey: .launchCommand)
        launchCommandMode = try container.decodeIfPresent(SSHConfig.LaunchCommandMode.self, forKey: .launchCommandMode)
        terminalType = try container.decodeIfPresent(String.self, forKey: .terminalType)
        multiplexerSessionName = try container.decodeIfPresent(String.self, forKey: .multiplexerSessionName)

        // Connection protocol: nil defaults to SSH for backward compatibility
        connectionProtocol = try container.decodeIfPresent(ConnectionProtocol.self, forKey: .connectionProtocol)

        // Key resolution hints: nil for legacy entries
        keyResolutionHints = try container.decodeIfPresent([String: KeyResolutionHint].self, forKey: .keyResolutionHints)

        // Sync fields: use defaults for legacy entries
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? lastUsed
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }

    /// Whether this entry has a jump host
    var hasJumpHost: Bool {
        jumpHost != nil && !jumpHost!.isEmpty
    }

    /// Display format: !shorthand (if HSS), or user@host, with optional jump host
    var displayString: String {
        // If this was an HSS connection, show the shorthand
        if let shorthand = hssShorthand, !shorthand.isEmpty {
            return "!\(shorthand)"
        }

        var result: String
        if port == 22 {
            result = "\(username)@\(host)"
        } else {
            result = "\(username)@\(host):\(port)"
        }

        // Add jump host if present
        if let jHost = jumpHost, let jUser = jumpUsername, !jHost.isEmpty {
            let jumpPart: String
            if jumpPort == 22 || jumpPort == nil {
                jumpPart = "\(jUser)@\(jHost)"
            } else {
                jumpPart = "\(jUser)@\(jHost):\(jumpPort!)"
            }
            result += " via \(jumpPart)"
        }

        return result
    }

    /// Unique logical identity for deduplication (ignores UUID)
    /// Format: "protocol:username@host:port" or "protocol:username@host:port via jumpuser@jumphost:jumpport"
    /// Protocol prefix differentiates SSH and Mosh connections to the same host
    var connectionIdentity: String {
        let protocolPrefix = (connectionProtocol == .mosh) ? "mosh:" : "ssh:"
        var identity = "\(protocolPrefix)\(username)@\(host):\(port)"

        if let jumpHost = jumpHost, let jumpUsername = jumpUsername, !jumpHost.isEmpty {
            let jumpPort = self.jumpPort ?? 22
            identity += " via \(jumpUsername)@\(jumpHost):\(jumpPort)"
        }

        return identity
    }

    /// Matches this entry against a prefix string
    func matches(prefix: String) -> Bool {
        displayString.lowercased().hasPrefix(prefix.lowercased())
    }

    /// Matches this entry against a substring (anywhere in the string)
    func matches(substring: String) -> Bool {
        let lowercaseSubstring = substring.lowercased()
        let display = displayString.lowercased()

        // Check main display string
        if display.contains(lowercaseSubstring) { return true }

        // Also check jump host fields directly
        if let jHost = jumpHost?.lowercased(), jHost.contains(lowercaseSubstring) { return true }
        if let jUser = jumpUsername?.lowercased(), jUser.contains(lowercaseSubstring) { return true }

        return false
    }

    /// Matches this entry based on the specified matching mode
    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        switch mode {
        case .prefix:
            return matches(prefix: searchText)
        case .substring:
            return matches(substring: searchText)
        }
    }
}

/// Manages persistent storage of SSH connection history
@MainActor
class SSHConnectionHistoryManager: ObservableObject {
    static let shared = SSHConnectionHistoryManager()
    private static let logger = Logger(subsystem: "com.rootshell", category: "SSHHistory")

    /// File store for sync-ready per-record storage
    private var store: SyncableFileStore<SSHConnectionHistoryEntry>

    /// Lookup table from connection identity to UUID (for deduplication)
    private var identityToUUID: [String: UUID] = [:]

    /// Sorted entries (most recently used first), excluding deleted
    @Published private(set) var entries: [SSHConnectionHistoryEntry] = []

    /// All records including tombstones (for CloudKit sync)
    var allRecordsForSync: [SSHConnectionHistoryEntry] {
        store.allRecords
    }

    /// Whether the last disk load failed to list the store directory
    var lastDiskLoadFailed: Bool {
        store.lastLoadFailed
    }

    /// Callback for CloudKit sync integration
    var onLocalChange: ((SSHConnectionHistoryEntry, SyncOperation) -> Void)? {
        didSet {
            store.onLocalChange = onLocalChange
        }
    }

    private init() {
        // Run migration before initializing store
        SyncMigrationManager.migrateIfNeeded()

        self.store = SyncableFileStore<SSHConnectionHistoryEntry>(storeName: "ssh_history")
        rebuildIdentityLookup()
        updateEntriesFromStore()
    }

    /// Rebuild the connection identity to UUID lookup table
    private func rebuildIdentityLookup() {
        identityToUUID = [:]
        for entry in store.activeRecords {
            identityToUUID[entry.connectionIdentity] = entry.id
        }
    }

    /// Update the entries array from the store
    private func updateEntriesFromStore() {
        entries = store.activeRecords
            .map { TSSHRelayStore.shared.applying(to: $0) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Reload all records from disk (use after force migration)
    func reloadFromStore() {
        store.reload()
        rebuildIdentityLookup()
        updateEntriesFromStore()
    }

    /// Get an entry by ID
    func entry(for id: UUID) -> SSHConnectionHistoryEntry? {
        store.record(for: id).map { TSSHRelayStore.shared.applying(to: $0) }
    }

    func refreshRelaySettings() { updateEntriesFromStore() }

    /// Add or update a connection in history
    func recordConnection(
        username: String,
        host: String,
        port: Int,
        authType: SSHAuthType,
        connectionProtocol: ConnectionProtocol? = nil,
        jumpHost: String? = nil,
        jumpPort: Int? = nil,
        jumpUsername: String? = nil,
        jumpAuthType: SSHAuthType? = nil,
        tsshRelay: TSSHRelaySettings? = nil,
        resolvedIP: String? = nil,
        hssShorthand: String? = nil,
        agentConfig: SSHAgentConfig? = nil,
        gpgAgentConfig: GPGAgentConfig? = nil,
        portForwardConfig: PortForwardConfig? = nil,
        tmuxAutoEnable: Bool? = nil,
        tmuxAutoMode: TmuxAutoMode? = nil,
        herdrAutoEnable: Bool? = nil,
        herdrAutoMode: HerdrAutoMode? = nil,
        zmxAutoEnable: Bool? = nil,
        launchCommand: String? = nil,
        launchCommandMode: SSHConfig.LaunchCommandMode? = nil,
        terminalType: String? = nil,
        multiplexerSessionName: String? = nil,
        keyResolutionHints: [String: KeyResolutionHint]? = nil
    ) {
        // Only cache IP for .local hostnames
        let ipToCache = host.hasSuffix(".local") ? resolvedIP : nil

        // For HSS connections, also check by shorthand and protocol
        // If same shorthand was used before with the same protocol, update that entry
        if let shorthand = hssShorthand,
           let existing = entries.first(where: { $0.hssShorthand == shorthand && $0.connectionProtocol == connectionProtocol }) {
            var updated = existing
            updated.lastUsed = Date()
            updated.authType = authType
            if let jumpAuthType = jumpAuthType {
                updated.jumpAuthType = jumpAuthType
            }
            if let ipToCache = ipToCache {
                updated.cachedIP = ipToCache
            }
            if let agentConfig = agentConfig {
                updated.agentConfig = agentConfig
            }
            // Always write — passing nil here means "user explicitly
            // disabled GPG forwarding", which must clear the stored
            // value or a previously-enabled history entry would
            // silently re-enable forwarding on next reconnect.
            updated.gpgAgentConfig = gpgAgentConfig
            if let portForwardConfig = portForwardConfig {
                updated.portForwardConfig = portForwardConfig
            }
            if let tmuxAutoEnable = tmuxAutoEnable {
                updated.tmuxAutoEnable = tmuxAutoEnable
            }
            if let tmuxAutoMode = tmuxAutoMode {
                updated.tmuxAutoMode = tmuxAutoMode
            }
            if let herdrAutoEnable = herdrAutoEnable {
                updated.herdrAutoEnable = herdrAutoEnable
            }
            if let herdrAutoMode = herdrAutoMode {
                updated.herdrAutoMode = herdrAutoMode
            }
            if let zmxAutoEnable = zmxAutoEnable {
                updated.zmxAutoEnable = zmxAutoEnable
            }
            updated.launchCommand = launchCommand
            updated.launchCommandMode = launchCommandMode
            // Always write, like launchCommand: nil means the user cleared the
            // override and the entry must stop pinning a TERM or a session.
            updated.terminalType = terminalType
            updated.multiplexerSessionName = multiplexerSessionName
            if let keyResolutionHints = keyResolutionHints {
                updated.keyResolutionHints = keyResolutionHints
            }
            updated.tsshRelay = tsshRelay
            try? TSSHRelayStore.shared.update(owner: .history, key: updated.connectionIdentity, settings: tsshRelay)
            try? store.save(updated)
            updateEntriesFromStore()
            return
        }

        // Check if this exact connection already exists (including jump host and protocol)
        if let existing = entries.first(where: {
            $0.username == username && $0.host == host && $0.port == port &&
            $0.jumpHost == jumpHost && $0.jumpUsername == jumpUsername && $0.jumpPort == jumpPort &&
            $0.connectionProtocol == connectionProtocol
        }) {
            // Update existing entry's lastUsed, authType, and cachedIP
            var updated = existing
            updated.lastUsed = Date()
            updated.authType = authType
            if let jumpAuthType = jumpAuthType {
                updated.jumpAuthType = jumpAuthType
            }
            if let ipToCache = ipToCache {
                updated.cachedIP = ipToCache
            }
            // Update HSS shorthand if this connection is now being accessed via HSS
            if let shorthand = hssShorthand {
                updated.hssShorthand = shorthand
            }
            if let agentConfig = agentConfig {
                updated.agentConfig = agentConfig
            }
            // Always write — passing nil here means "user explicitly
            // disabled GPG forwarding", which must clear the stored
            // value or a previously-enabled history entry would
            // silently re-enable forwarding on next reconnect.
            updated.gpgAgentConfig = gpgAgentConfig
            if let portForwardConfig = portForwardConfig {
                updated.portForwardConfig = portForwardConfig
            }
            if let tmuxAutoEnable = tmuxAutoEnable {
                updated.tmuxAutoEnable = tmuxAutoEnable
            }
            if let tmuxAutoMode = tmuxAutoMode {
                updated.tmuxAutoMode = tmuxAutoMode
            }
            if let herdrAutoEnable = herdrAutoEnable {
                updated.herdrAutoEnable = herdrAutoEnable
            }
            if let herdrAutoMode = herdrAutoMode {
                updated.herdrAutoMode = herdrAutoMode
            }
            if let zmxAutoEnable = zmxAutoEnable {
                updated.zmxAutoEnable = zmxAutoEnable
            }
            updated.launchCommand = launchCommand
            updated.launchCommandMode = launchCommandMode
            // Always write, like launchCommand: nil means the user cleared the
            // override and the entry must stop pinning a TERM or a session.
            updated.terminalType = terminalType
            updated.multiplexerSessionName = multiplexerSessionName
            if let keyResolutionHints = keyResolutionHints {
                updated.keyResolutionHints = keyResolutionHints
            }
            updated.tsshRelay = tsshRelay
            try? TSSHRelayStore.shared.update(owner: .history, key: updated.connectionIdentity, settings: tsshRelay)
            try? store.save(updated)
        } else {
            // Add new entry
            var newEntry = SSHConnectionHistoryEntry(
                username: username,
                host: host,
                port: port,
                authType: authType,
                connectionProtocol: connectionProtocol,
                jumpHost: jumpHost,
                jumpPort: jumpPort,
                jumpUsername: jumpUsername,
                jumpAuthType: jumpAuthType,
                cachedIP: ipToCache,
                hssShorthand: hssShorthand,
                agentConfig: agentConfig,
                gpgAgentConfig: gpgAgentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode,
                herdrAutoEnable: herdrAutoEnable,
                herdrAutoMode: herdrAutoMode,
                zmxAutoEnable: zmxAutoEnable,
                launchCommand: launchCommand,
                launchCommandMode: launchCommandMode,
                terminalType: terminalType,
                multiplexerSessionName: multiplexerSessionName,
                keyResolutionHints: keyResolutionHints
            )
            newEntry.tsshRelay = tsshRelay
            try? TSSHRelayStore.shared.update(owner: .history, key: newEntry.connectionIdentity, settings: tsshRelay)
            try? store.save(newEntry)
            identityToUUID[newEntry.connectionIdentity] = newEntry.id
        }

        updateEntriesFromStore()
    }

    /// Get suggestions matching a search text, sorted by most recently used first
    func getSuggestions(matching searchText: String, mode: MatchingMode = .prefix) -> [SSHConnectionHistoryEntry] {
        guard !searchText.isEmpty else {
            return Array(entries.prefix(10)) // Return 10 most recent if no search text
        }

        let lowercaseSearch = searchText.lowercased()

        return entries
            .filter { $0.matches(searchText, mode: mode) }
            .sorted { entry1, entry2 in
                let str1 = entry1.displayString.lowercased()
                let str2 = entry2.displayString.lowercased()

                // 1. Exact match gets highest priority
                if str1 == lowercaseSearch && str2 != lowercaseSearch { return true }
                if str2 == lowercaseSearch && str1 != lowercaseSearch { return false }

                // 2. For prefix mode, prefer entries that start with the search text
                //    (in substring mode, all matches are equal priority)
                if mode == .substring {
                    let str1HasPrefix = str1.hasPrefix(lowercaseSearch)
                    let str2HasPrefix = str2.hasPrefix(lowercaseSearch)
                    if str1HasPrefix && !str2HasPrefix { return true }
                    if str2HasPrefix && !str1HasPrefix { return false }
                }

                // 3. Most recently used (primary sort criterion)
                return entry1.lastUsed > entry2.lastUsed
            }
            .prefix(10)
            .map { $0 }
    }

    /// Delete a specific entry
    func deleteEntry(id: UUID) {
        if let entry = store.record(for: id) {
            identityToUUID.removeValue(forKey: entry.connectionIdentity)
        }
        try? store.softDelete(id: id)
        updateEntriesFromStore()
    }

    /// Clear all history
    func clearHistory() {
        for entry in entries {
            try? store.softDelete(id: entry.id)
        }
        identityToUUID.removeAll()
        updateEntriesFromStore()
    }

    // MARK: - Sync Support

    /// Apply changes from remote sync
    /// Uses logical identity (connection string) to prevent duplicates
    @discardableResult
    func applyRemoteChanges(_ remoteEntries: [SSHConnectionHistoryEntry]) -> Int {
        applyRemoteChangesWithFailures(remoteEntries).applied
    }

    /// Apply changes from remote sync, returning both successful applies and any persistence failures.
    /// Used by the backup restore path so the UI can surface real errors instead of silent loss.
    func applyRemoteChangesWithFailures(
        _ remoteEntries: [SSHConnectionHistoryEntry]
    ) -> (applied: Int, failures: [(id: UUID, error: Error)]) {
        Self.logger.info("applyRemoteChanges called with \(remoteEntries.count) entries")
        var applied = 0
        var failures: [(id: UUID, error: Error)] = []

        for remote in remoteEntries {
            do {
                try TSSHRelayStore.shared.seed(owner: .history, key: remote.connectionIdentity,
                    settings: remote.tsshRelay, modifiedAt: remote.modifiedAt)
            } catch {
                failures.append((id: remote.id, error: error))
                continue
            }
            // Check by logical identity (connection string), not just UUID
            if let existingUUID = identityToUUID[remote.connectionIdentity],
               let existing = store.record(for: existingUUID) {
                // Same logical connection exists - use last-write-wins
                guard remote.modifiedAt > existing.modifiedAt else {
                    continue  // Local is newer, keep local
                }
                // Remote is newer - update existing record (keep local UUID)
                //
                // The envelope-gated fields are resolved into locals first. They
                // are not just for readability: inlining both ternaries into the
                // initialiser below pushes it past the type-checker's budget
                // ("unable to type-check this expression in reasonable time").
                let envelopeVersion = remote.syncEnvelopeVersion ?? 0
                // Gated on the envelope version, not on its presence: a build
                // that predates this field still writes a valid (older)
                // envelope, and its silence is a gap rather than a clear.
                // Without this, reconnecting once on an older device during a
                // mixed-version rollout erases the override.
                let mergedMultiplexerSessionName: String? =
                    envelopeVersion >= HistoryExtensionPayload.multiplexerSessionNameVersion
                        ? remote.multiplexerSessionName
                        : (remote.multiplexerSessionName ?? existing.multiplexerSessionName)
                // Same rule, different introducing version. Note this is NOT the
                // plain-optional fallback `herdrAutoEnable` uses below: that
                // field has its own CloudKit record column, so its absence is
                // unambiguous, whereas an envelope member is absent both when
                // the user cleared it and when the writer predates it.
                let mergedZmxAutoEnable: Bool? =
                    envelopeVersion >= HistoryExtensionPayload.zmxAutoEnableVersion
                        ? remote.zmxAutoEnable
                        : (remote.zmxAutoEnable ?? existing.zmxAutoEnable)
                let mergedHerdrAutoMode: HerdrAutoMode? =
                    envelopeVersion >= HistoryExtensionPayload.herdrAutoModeVersion
                        ? remote.herdrAutoMode
                        : (remote.herdrAutoMode ?? existing.herdrAutoMode)
                let updated = SSHConnectionHistoryEntry(
                    id: existingUUID,  // Keep local UUID for consistency
                    username: remote.username,
                    host: remote.host,
                    port: remote.port,
                    authType: remote.authType,
                    connectionProtocol: remote.connectionProtocol ?? existing.connectionProtocol,
                    jumpHost: remote.jumpHost,
                    jumpPort: remote.jumpPort,
                    jumpUsername: remote.jumpUsername,
                    jumpAuthType: remote.jumpAuthType,
                    lastUsed: max(existing.lastUsed, remote.lastUsed),
                    cachedIP: remote.cachedIP ?? existing.cachedIP,
                    hssShorthand: remote.hssShorthand ?? existing.hssShorthand,
                    agentConfig: remote.agentConfig ?? existing.agentConfig,
                    gpgAgentConfig: remote.gpgAgentConfig ?? existing.gpgAgentConfig,
                    portForwardConfig: remote.portForwardConfig ?? existing.portForwardConfig,
                    tmuxAutoEnable: remote.tmuxAutoEnable ?? existing.tmuxAutoEnable,
                    tmuxAutoMode: remote.tmuxAutoMode ?? existing.tmuxAutoMode,
                    herdrAutoEnable: remote.herdrAutoEnable ?? existing.herdrAutoEnable,
                    herdrAutoMode: mergedHerdrAutoMode,
                    zmxAutoEnable: mergedZmxAutoEnable,
                    launchCommand: remote.launchCommand ?? existing.launchCommand,
                    launchCommandMode: remote.launchCommandMode ?? existing.launchCommandMode,
                    // Remote is strictly newer here, so when it carried an
                    // extension envelope its value wins verbatim — including
                    // nil, which is how clearing an override propagates. Only
                    // fall back for records from builds that predate the
                    // envelope and would otherwise look like a clear.
                    terminalType: remote.syncCarriedExtensions
                        ? remote.terminalType
                        : (remote.terminalType ?? existing.terminalType),
                    multiplexerSessionName: mergedMultiplexerSessionName,
                    keyResolutionHints: remote.keyResolutionHints ?? existing.keyResolutionHints,
                    modifiedAt: remote.modifiedAt,
                    isDeleted: remote.isDeleted
                )
                do {
                    try store.save(updated, updateTimestamp: false, notifySync: false)
                    applied += 1
                } catch {
                    failures.append((id: existingUUID, error: error))
                    let idString = existingUUID.uuidString
                    let host = updated.host
                    let desc = error.localizedDescription
                    Self.logger.error("Failed to persist remote history \(idString) (\(host)): \(desc)")
                }
            } else if store.record(for: remote.id) != nil {
                // Same UUID exists but different logical identity (shouldn't happen)
                // Skip to avoid confusion
            } else {
                // Truly new entry - add it
                Self.logger.info("Adding new entry: \(remote.host)")
                do {
                    try store.save(remote, updateTimestamp: false, notifySync: false)
                    identityToUUID[remote.connectionIdentity] = remote.id
                    applied += 1
                } catch {
                    failures.append((id: remote.id, error: error))
                    let idString = remote.id.uuidString
                    let host = remote.host
                    let desc = error.localizedDescription
                    Self.logger.error("Failed to persist remote history \(idString) (\(host)): \(desc)")
                }
            }
        }

        let failureCount = failures.count
        Self.logger.info("Applied \(applied) changes, updating UI (entries count before: \(self.entries.count), failures: \(failureCount))")
        updateEntriesFromStore()
        Self.logger.info("UI updated (entries count after: \(self.entries.count))")
        return (applied, failures)
    }

    /// Apply remote deletions from CloudKit change sets
    func applyRemoteDeletions(recordNames: Set<String>) {
        guard !recordNames.isEmpty else { return }

        var deletedCount = 0

        for entry in entries {
            let recordName = CloudKitRecordName.make(
                recordType: SSHConnectionHistoryEntry.recordType,
                identity: entry.connectionIdentity
            )
            if recordNames.contains(recordName) {
                var deleted = entry
                deleted.isDeleted = true
                deleted.modifiedAt = Date()
                try? store.save(deleted, updateTimestamp: false, notifySync: false)
                identityToUUID.removeValue(forKey: entry.connectionIdentity)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Applied \(deletedCount) remote deletions to SSH history")
            updateEntriesFromStore()
        }
    }

    /// Get entries modified after a given date (for sync)
    func entriesModifiedAfter(_ date: Date) -> [SSHConnectionHistoryEntry] {
        store.recordsModifiedAfter(date)
    }

    /// Reload entries from disk
    func reload() {
        store.reload()
        rebuildIdentityLookup()
        updateEntriesFromStore()
    }
}
