//
//  ProfileExtensionPayload.swift
//  rootshell
//
//  Versioned local/backup envelope. Connection fields use CloudKit
//  `extensionData`; themes sync separately to protect against old writers.
//

import Foundation

/// Versioned envelope holding extension fields for `ConnectionProfile`.
///
/// Decoding is tolerant at field level: a payload written by a newer build
/// (unknown fields, undecodable members) must not sink the envelope, and an
/// undecodable envelope must not sink the profile (callers decode the whole
/// envelope with `try?`).
struct ProfileExtensionPayload: Codable, Hashable, Sendable {
    /// Envelope schema version for future migrations.
    static let currentVersion = 1

    var version: Int

    /// Screen Sharing / VNC configuration, when this profile is a VNC profile.
    var vncConfig: VNCConnectionConfig?
    var localConfig: LocalProfileConfig?
    var themeName: String?
    /// Independent revision for theme changes, including clearing an override.
    /// Kept in local JSON/backups; CloudKit sends it in a separate record.
    var themeModifiedAt: Date?

    init(
        version: Int = ProfileExtensionPayload.currentVersion,
        vncConfig: VNCConnectionConfig? = nil,
        localConfig: LocalProfileConfig? = nil,
        themeName: String? = nil,
        themeModifiedAt: Date? = nil
    ) {
        self.version = version
        self.vncConfig = vncConfig
        self.localConfig = localConfig
        self.themeName = themeName
        self.themeModifiedAt = themeModifiedAt
    }

    /// True when nothing meaningful is stored. Empty envelopes are omitted
    /// from profile JSON and never written to CKRecords.
    var isEmpty: Bool {
        vncConfig == nil && localConfig == nil && themeName == nil && themeModifiedAt == nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, vncConfig, localConfig, themeName, themeModifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? Self.currentVersion
        // Field-level tolerance: a bad vncConfig must not sink the envelope.
        vncConfig = (try? container.decodeIfPresent(VNCConnectionConfig.self, forKey: .vncConfig)) ?? nil
        localConfig = try? container.decodeIfPresent(LocalProfileConfig.self, forKey: .localConfig)
        themeName = try? container.decodeIfPresent(String.self, forKey: .themeName)
        themeModifiedAt = try? container.decodeIfPresent(Date.self, forKey: .themeModifiedAt)
        // Early development builds stored the VNC object directly before the
        // versioned envelope was introduced. Preserve those profiles too.
        if vncConfig == nil,
           let legacyConfig = try? VNCConnectionConfig(from: decoder),
           !legacyConfig.host.isEmpty {
            vncConfig = legacyConfig
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(vncConfig, forKey: .vncConfig)
        try container.encodeIfPresent(localConfig, forKey: .localConfig)
        try container.encodeIfPresent(themeName, forKey: .themeName)
        try container.encodeIfPresent(themeModifiedAt, forKey: .themeModifiedAt)
    }
}

/// Local profiles sync everywhere; availability controls where they can launch.
struct LocalProfileConfig: Codable, Hashable, Sendable {
    enum Platform: String, Codable, CaseIterable, Sendable {
        case all, macOS, iOS

        var displayName: String {
            switch self {
            case .all: return String(localized: "All Devices")
            case .macOS: return "macOS"
            case .iOS: return "iOS/iPadOS"
            }
        }

        var isAvailable: Bool {
            #if targetEnvironment(macCatalyst) || os(macOS)
            return self == .all || self == .macOS
            #else
            return self == .all || self == .iOS
            #endif
        }
    }

    var workingDirectory: String?
    var startupCommand: String?
    var platform: Platform

    init(workingDirectory: String? = nil, startupCommand: String? = nil, platform: Platform = .all) {
        self.workingDirectory = workingDirectory
        self.startupCommand = startupCommand
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectory, startupCommand, platform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        startupCommand = try container.decodeIfPresent(String.self, forKey: .startupCommand)
        platform = try container.decodeIfPresent(Platform.self, forKey: .platform) ?? .all
    }
}

/// Independently versioned appearance data. Older clients never materialize its
/// CloudKit record, so an old writer cannot clear it while editing the profile.
struct ProfileThemeRecord: SyncableRecord, Sendable {
    let id: UUID
    var themeName: String?
    var modifiedAt: Date
    var isDeleted: Bool = false
    /// Local-only acknowledgement. Missing in pre-migration cache files means
    /// this revision still needs a companion upload.
    var syncedRevision: Date?

    var needsUpload: Bool { syncedRevision != modifiedAt }

    init?(profile: ConnectionProfile) {
        guard let revision = profile.extensionPayload?.themeModifiedAt
                ?? (profile.themeName == nil ? nil : profile.modifiedAt) else { return nil }
        id = profile.id
        themeName = profile.themeName
        modifiedAt = revision
    }

    func applying(to profile: ConnectionProfile) -> ConnectionProfile {
        var result = profile
        var payload = result.extensionPayload ?? ProfileExtensionPayload()
        payload.themeName = isDeleted ? nil : themeName
        payload.themeModifiedAt = modifiedAt
        result.extensionPayload = payload
        return result
    }
}
