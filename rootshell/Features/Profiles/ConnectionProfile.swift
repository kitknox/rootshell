//
//  ConnectionProfile.swift
//  rootshell
//
//  User-saved connection profiles with tagging and folder organization
//

import Foundation

/// Color tag options for visual profile organization
enum ProfileColorTag: String, Codable, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray
}

/// Connection protocol options for profiles
enum ConnectionProtocol: String, Codable, CaseIterable, Sendable {
    /// Standard SSH connection
    case ssh
    /// Mosh (mobile shell) connection - survives network changes and high latency
    case mosh
    /// Trzsz (tsshd) connection - QUIC-based mobile shell
    case trzsz
    /// Screen Sharing / VNC remote desktop connection
    case vnc

    var displayName: String {
        switch self {
        case .ssh: return String(localized: "SSH", comment: "Connection protocol: SSH")
        case .mosh: return String(localized: "Roam - mosh compatible", comment: "Connection protocol: mosh")
        case .trzsz: return String(localized: "Roam - tssh", comment: "Connection protocol: trzsz")
        case .vnc: return String(localized: "Screen Sharing", comment: "Connection protocol: VNC")
        }
    }

    var description: String {
        switch self {
        case .ssh: return String(localized: "Standard secure shell connection", comment: "Connection protocol description: SSH")
        case .mosh: return String(localized: "Mobile shell - better for unreliable networks", comment: "Connection protocol description: mosh")
        case .trzsz: return String(localized: "QUIC-based mobile shell - modern roaming protocol", comment: "Connection protocol description: trzsz")
        case .vnc: return String(localized: "Remote desktop via VNC / Apple Screen Sharing", comment: "Connection protocol description: VNC")
        }
    }

    var iconName: String {
        switch self {
        case .ssh: return "terminal"
        case .mosh: return "antenna.radiowaves.left.and.right"
        case .trzsz: return "antenna.radiowaves.left.and.right"
        case .vnc: return "display"
        }
    }
}

/// Transport mode override for TSSH profiles
enum ProfileTransportMode: String, Codable, CaseIterable, Sendable {
    /// Inherit from Settings > Roam
    case `default`
    /// QUIC transport
    case quic
    /// KCP transport
    case kcp

    var displayName: String {
        switch self {
        case .default: return String(localized: "Default", comment: "Profile transport mode: default")
        case .quic: return String(localized: "QUIC", comment: "Profile transport mode: QUIC")
        case .kcp: return String(localized: "KCP", comment: "Profile transport mode: KCP")
        }
    }

    /// Resolve to concrete TrzszConfig.TransportMode
    var resolved: TrzszConfig.TransportMode {
        switch self {
        case .default: return .preferred
        case .quic: return .quic
        case .kcp: return .kcp
        }
    }
}

/// A user-saved connection profile with metadata and organization
struct ConnectionProfile: Codable, Identifiable, Hashable, SyncableRecord {
    let id: UUID

    // MARK: - Core Metadata

    /// User-assigned display name
    var name: String

    /// Optional description/notes
    var notes: String?

    /// SF Symbol name for visual distinction
    var iconName: String?

    /// Optional color indicator
    var colorTag: ProfileColorTag?

    // MARK: - Organization

    /// Hierarchical folder path (e.g., "Work/Production" or "" for root)
    var folderPath: String {
        didSet {
            folderPath = Self.normalizeFolderPath(folderPath)
        }
    }

    /// Empty path components cannot be reached by the folder browser.
    /// A path containing only separators represents the root folder.
    static func normalizeFolderPath(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }

    /// Multi-tag support for flexible categorization
    var tags: Set<String>

    // MARK: - Connection Configuration

    /// Connection protocol (SSH or Mosh)
    var connectionProtocol: ConnectionProtocol

    /// Transport mode for TSSH connections (default inherits from Settings > Roam)
    var trzszTransportMode: ProfileTransportMode

    /// TSSH packet MTU override (nil = use default 1400). Both client and server must match.
    var trzszMTU: Int?

    /// TSSH UDP port range minimum override (nil = use global setting from Settings > Roam)
    var trzszPortMin: Int?

    /// TSSH UDP port range maximum override (nil = use global setting from Settings > Roam)
    var trzszPortMax: Int?

    /// Full path to the tsshd executable on the remote host, including the binary name
    /// (e.g. "/usr/local/bin/tsshd"). nil = invoke "tsshd" via PATH.
    var trzszServerPath: String?

    /// SSH connection configuration.
    ///
    /// Non-optional for backward compatibility, so VNC profiles carry a
    /// PLACEHOLDER SSHConfig (host/port/username mirrored from `vncConfig`,
    /// auth `.none`). It must never be used to open an SSH connection; the
    /// real VNC settings live in `extensionPayload.vncConfig`. Note the
    /// CloudKit record for a VNC profile deliberately OMITS this field so
    /// old builds skip the record instead of materializing a corrupt SSH
    /// profile.
    var sshConfig: SSHConfig

    /// Versioned envelope for extension fields (VNC config now, future
    /// additions later). nil / empty envelopes are omitted from JSON so SSH
    /// profile files are byte-identical to before this field existed.
    var extensionPayload: ProfileExtensionPayload?

    // MARK: - VPN Configuration

    /// Whether VPN mode is enabled for this profile
    var vpnEnabled: Bool

    /// DNS servers for VPN tunnel (empty = system default)
    var vpnDNSServers: [String]

    /// CIDR routes excluded from VPN tunnel
    var vpnExcludedRoutes: [String]

    /// Reject QUIC (UDP 443) in the VPN tunnel so browsers fall back to HTTP/2
    var vpnBlockQUIC: Bool

    // MARK: - SyncableRecord Conformance

    /// Timestamp of the last modification (for conflict resolution)
    var modifiedAt: Date

    /// Soft delete flag - deleted records are kept for sync tombstones
    var isDeleted: Bool

    // MARK: - Additional Metadata

    /// When this profile was created
    var createdAt: Date

    /// When this profile was last used for a connection
    var lastUsedAt: Date?

    /// Number of times this profile has been used
    var useCount: Int

    // MARK: - Initialization

    /// Create a new connection profile
    init(
        name: String,
        sshConfig: SSHConfig,
        connectionProtocol: ConnectionProtocol = .ssh,
        trzszTransportMode: ProfileTransportMode = .default,
        trzszMTU: Int? = nil,
        trzszPortMin: Int? = nil,
        trzszPortMax: Int? = nil,
        trzszServerPath: String? = nil,
        notes: String? = nil,
        iconName: String? = nil,
        colorTag: ProfileColorTag? = nil,
        folderPath: String = "",
        tags: Set<String> = [],
        vpnEnabled: Bool = false,
        vpnDNSServers: [String] = [],
        vpnExcludedRoutes: [String] = [],
        vpnBlockQUIC: Bool = false,
        extensionPayload: ProfileExtensionPayload? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.sshConfig = sshConfig
        self.connectionProtocol = connectionProtocol
        self.trzszTransportMode = trzszTransportMode
        self.trzszMTU = trzszMTU
        self.trzszPortMin = trzszPortMin
        self.trzszPortMax = trzszPortMax
        self.trzszServerPath = trzszServerPath
        self.notes = notes
        self.iconName = iconName
        self.colorTag = colorTag
        self.folderPath = Self.normalizeFolderPath(folderPath)
        self.tags = tags
        self.vpnEnabled = vpnEnabled
        self.vpnDNSServers = vpnDNSServers
        self.vpnExcludedRoutes = vpnExcludedRoutes
        self.vpnBlockQUIC = vpnBlockQUIC
        self.extensionPayload = extensionPayload
        self.modifiedAt = Date()
        self.isDeleted = false
        self.createdAt = Date()
        self.lastUsedAt = nil
        self.useCount = 0
    }

    /// Create a profile with explicit ID (for migration and sync)
    init(
        id: UUID,
        name: String,
        sshConfig: SSHConfig,
        connectionProtocol: ConnectionProtocol = .ssh,
        trzszTransportMode: ProfileTransportMode = .default,
        trzszMTU: Int? = nil,
        trzszPortMin: Int? = nil,
        trzszPortMax: Int? = nil,
        trzszServerPath: String? = nil,
        notes: String? = nil,
        iconName: String? = nil,
        colorTag: ProfileColorTag? = nil,
        folderPath: String = "",
        tags: Set<String> = [],
        vpnEnabled: Bool = false,
        vpnDNSServers: [String] = [],
        vpnExcludedRoutes: [String] = [],
        vpnBlockQUIC: Bool = false,
        modifiedAt: Date? = nil,
        isDeleted: Bool = false,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        extensionPayload: ProfileExtensionPayload? = nil
    ) {
        self.id = id
        self.name = name
        self.sshConfig = sshConfig
        self.connectionProtocol = connectionProtocol
        self.trzszTransportMode = trzszTransportMode
        self.trzszMTU = trzszMTU
        self.trzszPortMin = trzszPortMin
        self.trzszPortMax = trzszPortMax
        self.trzszServerPath = trzszServerPath
        self.notes = notes
        self.iconName = iconName
        self.colorTag = colorTag
        self.folderPath = Self.normalizeFolderPath(folderPath)
        self.tags = tags
        self.vpnEnabled = vpnEnabled
        self.vpnDNSServers = vpnDNSServers
        self.vpnExcludedRoutes = vpnExcludedRoutes
        self.vpnBlockQUIC = vpnBlockQUIC
        self.extensionPayload = extensionPayload
        self.modifiedAt = modifiedAt ?? Date()
        self.isDeleted = isDeleted
        self.createdAt = createdAt ?? Date()
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, name, notes, iconName, colorTag
        case folderPath, tags, sshConfig, connectionProtocol, trzszTransportMode
        case trzszMTU, trzszPortMin, trzszPortMax, trzszServerPath
        case vpnEnabled, vpnDNSServers, vpnExcludedRoutes, vpnBlockQUIC
        case modifiedAt, isDeleted, createdAt, lastUsedAt, useCount
        case extensionPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // ID: use existing or generate new (for legacy entries)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        colorTag = try container.decodeIfPresent(ProfileColorTag.self, forKey: .colorTag)

        folderPath = Self.normalizeFolderPath(
            try container.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        )
        tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []

        sshConfig = try container.decode(SSHConfig.self, forKey: .sshConfig)

        // Connection protocol: default to SSH for backward compatibility with existing profiles
        connectionProtocol = try container.decodeIfPresent(ConnectionProtocol.self, forKey: .connectionProtocol) ?? .ssh

        // Transport mode: default to .default for backward compatibility
        trzszTransportMode = try container.decodeIfPresent(ProfileTransportMode.self, forKey: .trzszTransportMode) ?? .default

        // TSSH advanced settings: nil = inherit from global settings
        trzszMTU = try container.decodeIfPresent(Int.self, forKey: .trzszMTU)
        trzszPortMin = try container.decodeIfPresent(Int.self, forKey: .trzszPortMin)
        trzszPortMax = try container.decodeIfPresent(Int.self, forKey: .trzszPortMax)
        trzszServerPath = try container.decodeIfPresent(String.self, forKey: .trzszServerPath)

        // VPN fields: default to disabled for existing profiles
        vpnEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnEnabled) ?? false
        vpnDNSServers = try container.decodeIfPresent([String].self, forKey: .vpnDNSServers) ?? []
        vpnExcludedRoutes = try container.decodeIfPresent([String].self, forKey: .vpnExcludedRoutes) ?? []
        vpnBlockQUIC = try container.decodeIfPresent(Bool.self, forKey: .vpnBlockQUIC) ?? false

        // Extension envelope: a bad envelope must not sink the profile.
        extensionPayload = (try? container.decodeIfPresent(ProfileExtensionPayload.self, forKey: .extensionPayload)) ?? nil

        // Sync fields: use defaults for legacy entries
        let now = Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? now
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encodeIfPresent(colorTag, forKey: .colorTag)

        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(tags, forKey: .tags)
        try container.encode(sshConfig, forKey: .sshConfig)
        try container.encode(connectionProtocol, forKey: .connectionProtocol)
        try container.encode(trzszTransportMode, forKey: .trzszTransportMode)
        try container.encodeIfPresent(trzszMTU, forKey: .trzszMTU)
        try container.encodeIfPresent(trzszPortMin, forKey: .trzszPortMin)
        try container.encodeIfPresent(trzszPortMax, forKey: .trzszPortMax)
        try container.encodeIfPresent(trzszServerPath, forKey: .trzszServerPath)

        try container.encode(vpnEnabled, forKey: .vpnEnabled)
        try container.encode(vpnDNSServers, forKey: .vpnDNSServers)
        try container.encode(vpnExcludedRoutes, forKey: .vpnExcludedRoutes)
        try container.encode(vpnBlockQUIC, forKey: .vpnBlockQUIC)

        // Omit empty envelopes so SSH profile JSON is unchanged.
        if let extensionPayload, !extensionPayload.isEmpty {
            try container.encode(extensionPayload, forKey: .extensionPayload)
        }

        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(useCount, forKey: .useCount)
    }

    // MARK: - Computed Properties

    /// Convenience accessor for the VNC config in the extension envelope.
    /// Setting a value creates the envelope; clearing the last field drops it
    /// so SSH profiles never carry an empty envelope.
    var vncConfig: VNCConnectionConfig? {
        get {
            if let config = extensionPayload?.vncConfig {
                return config
            }
            // VNC profiles mirror their endpoint into the mandatory legacy
            // SSH field. If an older/newer extension envelope cannot decode,
            // recover a usable automatic configuration instead of presenting
            // an empty editor and refusing to connect.
            guard connectionProtocol == .vnc, !sshConfig.host.isEmpty else {
                return nil
            }
            return VNCConnectionConfig(
                host: sshConfig.host,
                port: sshConfig.port,
                username: sshConfig.username.isEmpty ? nil : sshConfig.username)
        }
        set {
            if let newValue {
                var payload = extensionPayload ?? ProfileExtensionPayload()
                payload.vncConfig = newValue
                extensionPayload = payload
            } else {
                extensionPayload?.vncConfig = nil
                if extensionPayload?.isEmpty == true {
                    extensionPayload = nil
                }
            }
        }
    }

    /// Placeholder SSHConfig for VNC profiles (sshConfig is non-optional).
    /// Mirrors host/port/username for display fallbacks; never connectable.
    static func vncPlaceholderSSHConfig(for config: VNCConnectionConfig?) -> SSHConfig {
        var ssh = SSHConfig(
            host: config?.host ?? "",
            port: config?.port ?? 5900,
            username: config?.username ?? "",
            password: ""
        )
        ssh.authMethod = .none
        return ssh
    }

    /// Whether this profile can be used as a VPN connection.
    var isVPNCapable: Bool {
        !isDeleted && vpnEnabled && (connectionProtocol == .ssh || connectionProtocol == .trzsz)
    }

    /// Display string for autocomplete/suggestions (shows host info)
    var displayString: String {
        if connectionProtocol == .vnc, let vncConfig {
            return vncConfig.displayName
        }
        let hostPart: String
        if sshConfig.port == 22 {
            hostPart = "\(sshConfig.username)@\(sshConfig.host)"
        } else {
            hostPart = "\(sshConfig.username)@\(sshConfig.host):\(sshConfig.port)"
        }
        return hostPart
    }

    /// Display string with protocol prefix (e.g., "mosh user@host")
    var displayStringWithProtocol: String {
        switch connectionProtocol {
        case .ssh:
            return displayString
        case .mosh:
            return "mosh \(displayString)"
        case .trzsz:
            return "trzsz \(displayString)"
        case .vnc:
            return "vnc \(displayString)"
        }
    }

    /// Full display with folder context
    var displayStringWithFolder: String {
        if folderPath.isEmpty {
            return name
        }
        return "\(folderPath)/\(name)"
    }

    /// Whether this profile is in the root folder
    var isInRoot: Bool {
        folderPath.isEmpty
    }

    /// Parent folder path (empty string if in root or one level deep)
    var parentFolderPath: String {
        guard let lastSlash = folderPath.lastIndex(of: "/") else {
            return ""
        }
        return String(folderPath[..<lastSlash])
    }

    /// Folder name (last component of folder path)
    var folderName: String {
        guard let lastSlash = folderPath.lastIndex(of: "/") else {
            return folderPath
        }
        return String(folderPath[folderPath.index(after: lastSlash)...])
    }

    /// Whether this profile has port forwards configured
    var hasPortForwards: Bool {
        sshConfig.portForwardConfig.hasActiveForwards
    }

    // MARK: - Matching

    /// Matches this profile against a search string
    func matches(_ searchText: String) -> Bool {
        let lowercaseSearch = searchText.lowercased()

        // Check name
        if name.lowercased().contains(lowercaseSearch) { return true }

        // Check host
        if sshConfig.host.lowercased().contains(lowercaseSearch) { return true }

        // Check username
        if sshConfig.username.lowercased().contains(lowercaseSearch) { return true }

        // Check folder path
        if folderPath.lowercased().contains(lowercaseSearch) { return true }

        // Check tags
        for tag in tags {
            if tag.lowercased().contains(lowercaseSearch) { return true }
        }

        // Check notes
        if let notes = notes, notes.lowercased().contains(lowercaseSearch) { return true }

        return false
    }
}

// MARK: - ProfileFolder

/// Represents a folder in the profile hierarchy (computed from profile paths)
struct ProfileFolder: Identifiable, Hashable, Sendable {
    /// Full path as ID
    var id: String { path }

    /// Full folder path
    var path: String

    /// Folder name (last component)
    var name: String {
        guard let lastSlash = path.lastIndex(of: "/") else {
            return path
        }
        return String(path[path.index(after: lastSlash)...])
    }

    /// Nesting level (0 for top-level folders)
    var depth: Int {
        path.isEmpty ? 0 : path.filter { $0 == "/" }.count + 1
    }

    /// Number of profiles directly in this folder
    var profileCount: Int

    /// Number of profiles in this folder and all subfolders
    var totalProfileCount: Int

    init(path: String, profileCount: Int = 0, totalProfileCount: Int = 0) {
        self.path = path
        self.profileCount = profileCount
        self.totalProfileCount = totalProfileCount
    }

    /// Parent folder path (empty if top-level)
    var parentPath: String {
        guard let lastSlash = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[..<lastSlash])
    }
}

// MARK: - ProfileTag

/// Represents a tag used by profiles (computed from profile tags)
struct ProfileTag: Identifiable, Hashable, Sendable {
    /// Tag name as ID
    var id: String { name }

    /// Tag name
    var name: String

    /// Number of profiles using this tag
    var usageCount: Int

    init(name: String, usageCount: Int = 0) {
        self.name = name
        self.usageCount = usageCount
    }
}
