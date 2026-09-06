//
//  ConnectionProfileManager.swift
//  rootshell
//
//  Manages user-saved connection profiles with folder and tag organization
//

import Foundation
import Observation
import os.log

/// Manages persistent storage and organization of connection profiles
@MainActor
@Observable
final class ConnectionProfileManager {
    static let shared = ConnectionProfileManager()
    private static let logger = Logger(subsystem: "com.rootshell", category: "ConnectionProfiles")

    /// File store for sync-ready per-record storage
    private var store: SyncableFileStore<ConnectionProfile>
    private var themeStore: SyncableFileStore<ProfileThemeRecord>

    /// Sorted profiles (by name), excluding deleted
    private(set) var profiles: [ConnectionProfile] = []

    /// All records including tombstones (for CloudKit sync)
    var allRecordsForSync: [ConnectionProfile] {
        store.allRecords.map(profileWithTheme)
    }

    /// Whether the last disk load failed to list the store directory
    var lastDiskLoadFailed: Bool {
        store.lastLoadFailed
    }

    /// Reload all profiles from disk (recovery path when the initial load failed)
    func reloadFromDisk() {
        themeStore.reload()
        store.reload()
        restoreProfileThemesFromDisk()
        updateProfilesFromStore()
    }

    /// Callback for CloudKit sync integration
    var onLocalChange: ((ConnectionProfile, SyncOperation) -> Void)? {
        didSet {
            store.onLocalChange = onLocalChange
        }
    }

    private init() {
        self.store = SyncableFileStore<ConnectionProfile>(storeName: "connection_profiles")
        self.themeStore = SyncableFileStore<ProfileThemeRecord>(storeName: "profile_themes")
        sanitizePersistedProfiles()
        restoreProfileThemesFromDisk()
        updateProfilesFromStore()
    }

    // MARK: - Computed Organization

    /// All unique folders extracted from profile paths
    var allFolders: [ProfileFolder] {
        var folderCounts: [String: (direct: Int, total: Int)] = [:]

        for profile in profiles {
            guard !profile.folderPath.isEmpty else { continue }

            // Count direct profiles in this folder
            folderCounts[profile.folderPath, default: (0, 0)].direct += 1

            // Also count in all parent folders for total count
            var path = profile.folderPath
            while !path.isEmpty {
                folderCounts[path, default: (0, 0)].total += 1
                if let lastSlash = path.lastIndex(of: "/") {
                    path = String(path[..<lastSlash])
                } else {
                    break
                }
            }
        }

        // Build folder objects
        var folders: [ProfileFolder] = []
        for (path, counts) in folderCounts {
            folders.append(ProfileFolder(
                path: path,
                profileCount: counts.direct,
                totalProfileCount: counts.total
            ))
        }

        return folders.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// All unique tags with usage counts (including other platforms for editors).
    var allTags: [ProfileTag] {
        tags(showAllPlatforms: true)
    }

    /// Browse filters and counts must use the same platform scope as results.
    func tags(showAllPlatforms: Bool) -> [ProfileTag] {
        let visibleProfiles = showAllPlatforms ? profiles : availableProfiles
        var tagCounts: [String: Int] = [:]

        for profile in visibleProfiles {
            for tag in profile.tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        return tagCounts.map { ProfileTag(name: $0.key, usageCount: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Profiles in the root folder (no folder path)
    var rootProfiles: [ConnectionProfile] {
        profiles.filter { $0.folderPath.isEmpty }
    }

    /// Top-level folders (no parent)
    var topLevelFolders: [ProfileFolder] {
        allFolders.filter { !$0.path.contains("/") }
    }

    // MARK: - CRUD Operations

    /// Create a new profile
    @discardableResult
    func createProfile(
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
    ) throws -> ConnectionProfile {
        let profile = ConnectionProfile(
            name: name,
            sshConfig: sshConfig,
            connectionProtocol: connectionProtocol,
            trzszTransportMode: trzszTransportMode,
            trzszMTU: trzszMTU,
            trzszPortMin: trzszPortMin,
            trzszPortMax: trzszPortMax,
            trzszServerPath: trzszServerPath,
            notes: notes,
            iconName: iconName,
            colorTag: colorTag,
            folderPath: folderPath,
            tags: tags,
            vpnEnabled: vpnEnabled,
            vpnDNSServers: vpnDNSServers,
            vpnExcludedRoutes: vpnExcludedRoutes,
            vpnBlockQUIC: vpnBlockQUIC,
            extensionPayload: extensionPayload
        )

        try persistProfile(profile)
        updateProfilesFromStore()

        Self.logger.info("Created profile '\(name)' in folder '\(folderPath)' with protocol \(connectionProtocol.rawValue)")
        return store.record(for: profile.id) ?? sanitizeProfileForPersistence(profile)
    }

    /// Create a profile from an SSH connection history entry
    @discardableResult
    func createProfile(
        from historyEntry: SSHConnectionHistoryEntry,
        name: String? = nil,
        folderPath: String = "",
        tags: Set<String> = []
    ) throws -> ConnectionProfile {
        // Build SSHConfig from history entry
        let authMethod: SSHConfig.AuthMethod
        switch historyEntry.authType {
        case .password:
            authMethod = .password("")  // Don't store password from history
        case .savedPassword:
            authMethod = .savedPassword  // Reference the saved password
        case .key(let keyID, _):
            authMethod = .key(keyID)
        case .keyboardInteractive:
            authMethod = .keyboardInteractive
        case .none:
            authMethod = .none  // Tailscale/WireGuard pre-authenticated
        case .unknown(let rawType):
            authMethod = .unknown(rawType: rawType)  // Preserve a newer app's auth type
        }

        var jumpHostConfig: SSHConfig.JumpHostConfig?
        if let jumpHost = historyEntry.jumpHost,
           let jumpUsername = historyEntry.jumpUsername,
           !jumpHost.isEmpty {
            let jumpAuthMethod: SSHConfig.AuthMethod
            switch historyEntry.jumpAuthType {
            case .some(.password):
                jumpAuthMethod = .password("")
            case .some(.savedPassword):
                jumpAuthMethod = .savedPassword  // Reference the saved password
            case .some(.key(let keyID, _)):
                jumpAuthMethod = .key(keyID)
            case .some(.none):
                jumpAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
            case .some(.keyboardInteractive):
                jumpAuthMethod = .keyboardInteractive
            case .some(.unknown(let rawType)):
                jumpAuthMethod = .unknown(rawType: rawType)  // Preserve a newer app's auth type
            case nil:
                jumpAuthMethod = .password("")  // Default to password if not specified
            }

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if case .key(let keyID) = jumpAuthMethod {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            jumpHostConfig = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: historyEntry.jumpPort ?? 22,
                username: jumpUsername,
                authMethod: jumpAuthMethod,
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )
        }

        var sshConfig = SSHConfig(
            host: historyEntry.host,
            port: historyEntry.port,
            username: historyEntry.username,
            authMethod: authMethod,
            cachedIP: historyEntry.cachedIP,
            jumpHost: jumpHostConfig,
            hssShorthand: historyEntry.hssShorthand,
            agentConfig: historyEntry.agentConfig ?? .disabled,
            portForwardConfig: historyEntry.portForwardConfig ?? .none
        )
        sshConfig.tmuxAutoEnable = historyEntry.tmuxAutoEnable ?? false
        sshConfig.tmuxAutoMode = historyEntry.tmuxAutoMode ?? .regular
        sshConfig.herdrAutoEnable = historyEntry.herdrAutoEnable ?? false
        sshConfig.zmxAutoEnable = historyEntry.zmxAutoEnable ?? false
        sshConfig.launchCommand = historyEntry.launchCommand
        sshConfig.launchCommandMode = historyEntry.launchCommandMode ?? .afterConnect
        sshConfig.terminalType = historyEntry.terminalType
        sshConfig.multiplexerSessionName = historyEntry.multiplexerSessionName
        // GPG forwarding isn't part of any SSHConfig convenience
        // initializer (kept out to avoid bloating the call sites that
        // don't use it). Apply directly so profile creation preserves
        // the history entry's GPG setup.
        sshConfig.gpgAgentConfig = historyEntry.gpgAgentConfig ?? .disabled

        // Use history display string as default name if not provided
        let profileName = name ?? historyEntry.displayString

        return try createProfile(
            name: profileName,
            sshConfig: sshConfig,
            connectionProtocol: historyEntry.connectionProtocol ?? .ssh,
            folderPath: folderPath,
            tags: tags
        )
    }

    /// Update an existing profile
    func updateProfile(_ profile: ConnectionProfile) throws {
        guard store.record(for: profile.id) != nil else {
            Self.logger.warning("Attempted to update non-existent profile \(profile.id.uuidString)")
            return
        }

        try persistProfile(profile)
        updateProfilesFromStore()

        Self.logger.info("Updated profile '\(profile.name)'")
    }

    /// Delete a profile (soft delete for sync)
    func deleteProfile(id: UUID) throws {
        try store.softDelete(id: id)
        updateProfilesFromStore()

        Self.logger.info("Deleted profile \(id.uuidString)")
    }

    /// Move a profile to a different folder
    func moveProfile(id: UUID, toFolder newPath: String) throws {
        guard var profile = store.record(for: id) else {
            Self.logger.warning("Attempted to move non-existent profile \(id.uuidString)")
            return
        }

        profile.folderPath = newPath
        try persistProfile(profile)
        updateProfilesFromStore()

        Self.logger.info("Moved profile '\(profile.name)' to folder '\(newPath)'")
    }

    /// Duplicate a profile
    @discardableResult
    func duplicateProfile(id: UUID, newName: String? = nil) throws -> ConnectionProfile? {
        guard let original = store.record(for: id), !original.isDeleted else {
            Self.logger.warning("Attempted to duplicate non-existent profile \(id.uuidString)")
            return nil
        }

        let duplicateName = newName ?? "\(original.name) (Copy)"

        let duplicate = ConnectionProfile(
            name: duplicateName,
            sshConfig: original.sshConfig,
            connectionProtocol: original.connectionProtocol,
            trzszTransportMode: original.trzszTransportMode,
            trzszMTU: original.trzszMTU,
            trzszPortMin: original.trzszPortMin,
            trzszPortMax: original.trzszPortMax,
            trzszServerPath: original.trzszServerPath,
            notes: original.notes,
            iconName: original.iconName,
            colorTag: original.colorTag,
            folderPath: original.folderPath,
            tags: original.tags,
            vpnEnabled: original.vpnEnabled,
            vpnDNSServers: original.vpnDNSServers,
            vpnExcludedRoutes: original.vpnExcludedRoutes,
            vpnBlockQUIC: original.vpnBlockQUIC,
            extensionPayload: original.extensionPayload
        )

        try persistProfile(duplicate)
        updateProfilesFromStore()

        Self.logger.info("Duplicated profile '\(original.name)' as '\(duplicateName)'")
        return store.record(for: duplicate.id) ?? sanitizeProfileForPersistence(duplicate)
    }

    /// Record that a profile was used
    func recordUsage(id: UUID) {
        guard var profile = store.record(for: id) else { return }

        profile.lastUsedAt = Date()
        profile.useCount += 1
        try? persistProfile(profile, updateTimestamp: false, notifySync: false)
        updateProfilesFromStore()
    }

    // MARK: - Tag Operations

    /// Add a tag to a profile
    func addTag(_ tag: String, to profileID: UUID) throws {
        guard var profile = store.record(for: profileID) else {
            Self.logger.warning("Attempted to add tag to non-existent profile \(profileID.uuidString)")
            return
        }

        profile.tags.insert(tag)
        try persistProfile(profile)
        updateProfilesFromStore()
    }

    /// Remove a tag from a profile
    func removeTag(_ tag: String, from profileID: UUID) throws {
        guard var profile = store.record(for: profileID) else {
            Self.logger.warning("Attempted to remove tag from non-existent profile \(profileID.uuidString)")
            return
        }

        profile.tags.remove(tag)
        try persistProfile(profile)
        updateProfilesFromStore()
    }

    /// Rename a tag across all profiles
    func renameTag(from oldName: String, to newName: String) throws {
        var updatedCount = 0

        for var profile in profiles where profile.tags.contains(oldName) {
            profile.tags.remove(oldName)
            profile.tags.insert(newName)
            try persistProfile(profile)
            updatedCount += 1
        }

        if updatedCount > 0 {
            updateProfilesFromStore()
            Self.logger.info("Renamed tag '\(oldName)' to '\(newName)' in \(updatedCount) profiles")
        }
    }

    /// Delete a tag from all profiles
    func deleteTag(_ tag: String) throws {
        var updatedCount = 0

        for var profile in profiles where profile.tags.contains(tag) {
            profile.tags.remove(tag)
            try persistProfile(profile)
            updatedCount += 1
        }

        if updatedCount > 0 {
            updateProfilesFromStore()
            Self.logger.info("Removed tag '\(tag)' from \(updatedCount) profiles")
        }
    }

    // MARK: - Folder Operations

    /// Rename a folder (updates all profiles in that folder and subfolders)
    func renameFolder(from oldPath: String, to newPath: String) throws {
        var updatedCount = 0

        for var profile in profiles {
            if profile.folderPath == oldPath {
                // Direct match - rename to new path
                profile.folderPath = newPath
                try persistProfile(profile)
                updatedCount += 1
            } else if profile.folderPath.hasPrefix(oldPath + "/") {
                // Subfolder - replace prefix
                profile.folderPath = newPath + profile.folderPath.dropFirst(oldPath.count)
                try persistProfile(profile)
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            updateProfilesFromStore()
            Self.logger.info("Renamed folder '\(oldPath)' to '\(newPath)', updated \(updatedCount) profiles")
        }
    }

    /// Delete a folder (moves profiles to parent or root)
    func deleteFolder(_ path: String, moveToParent: Bool = true) throws {
        let parentPath = path.contains("/")
            ? String(path[..<path.lastIndex(of: "/")!])
            : ""

        var updatedCount = 0

        for var profile in profiles {
            if profile.folderPath == path || profile.folderPath.hasPrefix(path + "/") {
                if moveToParent {
                    // Move to parent folder
                    if profile.folderPath == path {
                        profile.folderPath = parentPath
                    } else {
                        // Subfolder - move up one level
                        let relativePath = String(profile.folderPath.dropFirst(path.count + 1))
                        profile.folderPath = parentPath.isEmpty ? relativePath : "\(parentPath)/\(relativePath)"
                    }
                } else {
                    // Move to root
                    profile.folderPath = ""
                }
                try persistProfile(profile)
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            updateProfilesFromStore()
            Self.logger.info("Deleted folder '\(path)', moved \(updatedCount) profiles")
        }
    }

    // MARK: - Query Operations

    var availableProfiles: [ConnectionProfile] {
        profiles.filter { $0.isAvailableOnCurrentPlatform }
    }

    var hasUnavailableProfiles: Bool {
        profiles.contains { !$0.isAvailableOnCurrentPlatform }
    }

    /// Folder counts must reflect the same platform filter as their rows.
    func subfolders(of parentPath: String, showAllPlatforms: Bool) -> [ProfileFolder] {
        let visible = showAllPlatforms ? profiles : availableProfiles
        return subfolders(of: parentPath).compactMap { folder in
            let descendants = visible.filter {
                $0.folderPath == folder.path || $0.folderPath.hasPrefix(folder.path + "/")
            }
            guard !descendants.isEmpty else { return nil }
            return ProfileFolder(path: folder.path,
                                 profileCount: descendants.filter { $0.folderPath == folder.path }.count,
                                 totalProfileCount: descendants.count)
        }
    }

    /// Get a profile by ID
    func profile(for id: UUID) -> ConnectionProfile? {
        store.record(for: id).map(profileWithTheme)
    }

    /// Get profiles in a specific folder (direct children only)
    func profiles(inFolder path: String) -> [ConnectionProfile] {
        profiles.filter { $0.folderPath == path }
    }

    /// Get profiles with a specific tag
    func profiles(withTag tag: String) -> [ConnectionProfile] {
        profiles.filter { $0.tags.contains(tag) }
    }

    /// Get profiles matching a search string
    func profiles(matching searchText: String) -> [ConnectionProfile] {
        guard !searchText.isEmpty else { return profiles }
        return profiles.filter { $0.matches(searchText) }
    }

    /// Get subfolders of a folder
    func subfolders(of parentPath: String) -> [ProfileFolder] {
        let prefix = parentPath.isEmpty ? "" : parentPath + "/"

        return allFolders.filter { folder in
            guard folder.path.hasPrefix(prefix) else { return false }
            let remainder = String(folder.path.dropFirst(prefix.count))
            return !remainder.contains("/")  // Direct children only
        }
    }

    /// Get suggestions for autocomplete (most recently used first)
    func getSuggestions(matching searchText: String, limit: Int = 10) -> [ConnectionProfile] {
        let filtered: [ConnectionProfile]

        if searchText.isEmpty {
            filtered = profiles
        } else {
            filtered = profiles.filter { $0.matches(searchText) }
        }

        return filtered
            .filter { $0.isAvailableOnCurrentPlatform }
            .sorted { p1, p2 in
                // Sort by last used (most recent first), then by use count
                if let d1 = p1.lastUsedAt, let d2 = p2.lastUsedAt {
                    return d1 > d2
                }
                if p1.lastUsedAt != nil { return true }
                if p2.lastUsedAt != nil { return false }
                return p1.useCount > p2.useCount
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Sync Support

    var pendingThemesForSync: [ProfileThemeRecord] {
        themeStore.allRecords.filter { $0.needsUpload }
    }

    /// A delayed upload must not acknowledge a newer local edit.
    func markThemeSynced(_ theme: ProfileThemeRecord) throws {
        guard var current = themeStore.record(for: theme.id),
              current.modifiedAt == theme.modifiedAt,
              current.themeName == theme.themeName,
              current.isDeleted == theme.isDeleted,
              current.needsUpload else { return }
        current.syncedRevision = theme.modifiedAt
        try themeStore.save(current, updateTimestamp: false, notifySync: false)
    }

    /// A theme may arrive before its profile or after an old client's edit.
    /// Persist it independently, then join it to whichever profile is present.
    func applyRemoteTheme(_ theme: ProfileThemeRecord) throws {
        let newest: ProfileThemeRecord
        if let existing = themeStore.record(for: theme.id), existing.modifiedAt >= theme.modifiedAt {
            if !theme.needsUpload {
                try markThemeSynced(theme)
            }
            newest = themeStore.record(for: theme.id) ?? existing
        } else {
            try themeStore.save(theme, updateTimestamp: false, notifySync: false)
            newest = theme
        }
        if let profile = store.record(for: theme.id) {
            try store.save(newest.applying(to: profile), updateTimestamp: false, notifySync: false)
            updateProfilesFromStore()
        }
    }

    /// Apply changes from remote sync
    @discardableResult
    func applyRemoteChanges(_ remoteProfiles: [ConnectionProfile]) -> Int {
        applyRemoteChangesWithFailures(remoteProfiles).applied
    }

    /// Apply changes from remote sync, returning both successful applies and any persistence failures.
    /// Used by the backup restore path so the UI can surface real errors instead of silent loss.
    func applyRemoteChangesWithFailures(
        _ remoteProfiles: [ConnectionProfile]
    ) -> (applied: Int, failures: [(id: UUID, error: Error)]) {
        Self.logger.info("applyRemoteChanges called with \(remoteProfiles.count) profiles")
        var applied = 0
        var failures: [(id: UUID, error: Error)] = []

        for remote in remoteProfiles {
            if let theme = ProfileThemeRecord(profile: remote) {
                do {
                    try applyRemoteTheme(theme)
                } catch {
                    failures.append((id: remote.id, error: error))
                    continue
                }
            }
            let needsPersist: Bool
            if let existing = store.record(for: remote.id) {
                needsPersist = remote.modifiedAt > existing.modifiedAt
            } else {
                needsPersist = true
            }
            guard needsPersist else { continue }

            do {
                try persistProfile(remote, updateTimestamp: false, notifySync: false)
                applied += 1
            } catch {
                failures.append((id: remote.id, error: error))
                let idString = remote.id.uuidString
                let name = remote.name
                let desc = error.localizedDescription
                Self.logger.error("Failed to persist remote profile \(idString) '\(name)': \(desc)")
            }
        }

        let failureCount = failures.count
        Self.logger.info("Applied \(applied) remote changes to profiles (\(failureCount) failures)")
        updateProfilesFromStore()
        return (applied, failures)
    }

    /// Apply remote deletions from CloudKit change sets
    func applyRemoteDeletions(recordNames: Set<String>) {
        guard !recordNames.isEmpty else { return }

        var deletedCount = 0

        for profile in profiles {
            let recordName = CloudKitRecordName.make(
                recordType: ConnectionProfile.recordType,
                identity: profile.id.uuidString
            )
            if recordNames.contains(recordName) {
                var deleted = profile
                deleted.isDeleted = true
                deleted.modifiedAt = Date()
                try? persistProfile(deleted, updateTimestamp: false, notifySync: false)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Applied \(deletedCount) remote deletions to profiles")
            updateProfilesFromStore()
        }
    }

    /// Get profiles modified after a given date (for sync)
    func profilesModifiedAfter(_ date: Date) -> [ConnectionProfile] {
        store.recordsModifiedAfter(date)
    }

    /// Reload all records from disk
    func reload() {
        themeStore.reload()
        store.reload()
        restoreProfileThemesFromDisk()
        updateProfilesFromStore()
    }

    func refreshVPNSharedProfiles() {
        syncVPNSharedProfiles()
    }

    /// Removes any inline `.password(secret)` a profile still holds for the
    /// given connection (`host:port:username`), in both the main config and a
    /// jump host. Called by `SSHPasswordManager.deletePassword` so that profile
    /// sanitization can't later re-migrate the secret into the Keychain and
    /// resurrect the password the user just deleted. Saved directly (bypassing
    /// `sanitizeProfileForPersistence`, which would re-create the entry), and
    /// the cleared profile is propagated to sync so peers drop the secret too.
    func stripInlinePassword(forConnectionKey connectionKey: String) {
        var changed = 0

        for profile in store.allRecords {
            var updated = profile
            var didChange = false

            if Self.inlinePasswordMatches(
                updated.sshConfig.authMethod,
                host: updated.sshConfig.host,
                port: updated.sshConfig.port,
                username: updated.sshConfig.username,
                connectionKey: connectionKey
            ) {
                updated.sshConfig.authMethod = .password("")
                didChange = true
            }

            if var jumpHost = updated.sshConfig.jumpHost,
               Self.inlinePasswordMatches(
                jumpHost.authMethod,
                host: jumpHost.host,
                port: jumpHost.port,
                username: jumpHost.username,
                connectionKey: connectionKey
               ) {
                jumpHost.authMethod = .password("")
                updated.sshConfig.jumpHost = jumpHost
                didChange = true
            }

            guard didChange else { continue }

            do {
                try store.save(updated, updateTimestamp: true, notifySync: true)
                changed += 1
            } catch {
                let profileID = profile.id.uuidString
                Self.logger.error("Failed to strip inline password from profile \(profileID): \(error.localizedDescription)")
            }
        }

        if changed > 0 {
            updateProfilesFromStore()
            Self.logger.info("Stripped inline password from \(changed) profile(s) for deleted connection")
        }
    }

    private static func inlinePasswordMatches(
        _ authMethod: SSHConfig.AuthMethod,
        host: String,
        port: Int,
        username: String,
        connectionKey: String
    ) -> Bool {
        guard case .password(let secret) = authMethod, !secret.isEmpty else {
            return false
        }
        return SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username) == connectionKey
    }

    // MARK: - Private Helpers

    private func profileWithTheme(_ profile: ConnectionProfile) -> ConnectionProfile {
        guard let theme = themeStore.record(for: profile.id) else { return profile }
        return theme.applying(to: profile)
    }

    /// Seed the companion cache from local JSON/backups made before companion
    /// records existed. This also repairs a partial write after a disk failure.
    private func restoreProfileThemesFromDisk() {
        for profile in store.allRecords {
            guard let theme = ProfileThemeRecord(profile: profile),
                  themeStore.record(for: profile.id).map({ $0.modifiedAt < theme.modifiedAt }) ?? true else { continue }
            do {
                try themeStore.save(theme, updateTimestamp: false, notifySync: false)
            } catch {
                Self.logger.error("Failed to restore profile theme: \(error.localizedDescription)")
            }
        }
    }

    /// Update the profiles array from the store
    private func updateProfilesFromStore() {
        profiles = store.activeRecords
            .map(profileWithTheme)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        syncVPNSharedProfiles()
    }

    private func persistProfile(
        _ profile: ConnectionProfile,
        updateTimestamp: Bool = true,
        notifySync: Bool = true
    ) throws {
        var sanitized = sanitizeProfileForPersistence(profile)
        if notifySync {
            let existing = store.record(for: profile.id).map(profileWithTheme)
            if sanitized.themeName != existing?.themeName {
                var payload = sanitized.extensionPayload ?? ProfileExtensionPayload()
                payload.themeModifiedAt = Date()
                sanitized.extensionPayload = payload
            } else if let previousRevision = existing?.extensionPayload?.themeModifiedAt {
                // Editing connection settings must not advance the theme revision.
                var payload = sanitized.extensionPayload ?? ProfileExtensionPayload()
                payload.themeModifiedAt = previousRevision
                sanitized.extensionPayload = payload
            }
        }
        if let incomingTheme = ProfileThemeRecord(profile: sanitized),
           themeStore.record(for: sanitized.id).map({ $0.modifiedAt < incomingTheme.modifiedAt }) ?? true {
            try themeStore.save(incomingTheme, updateTimestamp: false, notifySync: false)
        }
        if let theme = themeStore.record(for: sanitized.id) {
            sanitized = theme.applying(to: sanitized)
        }
        try store.save(sanitized, updateTimestamp: updateTimestamp, notifySync: notifySync)
    }

    private func sanitizePersistedProfiles() {
        var rewrittenProfiles = 0

        for profile in store.allRecords {
            let sanitized = sanitizeProfileForPersistence(profile)
            guard sanitized != profile else { continue }

            do {
                try store.save(sanitized, updateTimestamp: false, notifySync: false)
                rewrittenProfiles += 1
            } catch {
                let profileID = profile.id.uuidString
                Self.logger.error("Failed to sanitize persisted profile \(profileID): \(error.localizedDescription)")
            }
        }

        if rewrittenProfiles > 0 {
            Self.logger.info("Sanitized \(rewrittenProfiles) persisted profile records to remove JSON passwords")
        }
    }

    private func sanitizeProfileForPersistence(_ profile: ConnectionProfile) -> ConnectionProfile {
        var sanitized = profile
        sanitized.sshConfig = sanitizeSSHConfigForPersistence(profile.sshConfig)
        return sanitized
    }

    private func sanitizeSSHConfigForPersistence(_ config: SSHConfig) -> SSHConfig {
        var sanitized = config
        sanitized.authMethod = sanitizeAuthMethod(
            sanitized.authMethod,
            host: sanitized.host,
            port: sanitized.port,
            username: sanitized.username
        )

        if var jumpHost = sanitized.jumpHost {
            jumpHost.authMethod = sanitizeAuthMethod(
                jumpHost.authMethod,
                host: jumpHost.host,
                port: jumpHost.port,
                username: jumpHost.username
            )
            sanitized.jumpHost = jumpHost
        }

        return sanitized
    }

    private func sanitizeAuthMethod(
        _ authMethod: SSHConfig.AuthMethod,
        host: String,
        port: Int,
        username: String
    ) -> SSHConfig.AuthMethod {
        guard case .password(let password) = authMethod else {
            return authMethod
        }

        guard !password.isEmpty else {
            return .password("")
        }

        let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)

        // If a saved password already exists, just reference it — don't re-save
        // the inline secret. A re-save re-touches the synchronizable Keychain
        // item and can resurrect a password deleted on another device.
        if SSHPasswordManager.shared.hasPassword(connectionKey: connectionKey) {
            return .savedPassword
        }

        do {
            try SSHPasswordManager.shared.savePassword(
                password,
                host: host,
                port: port,
                username: username,
                refreshVPNProfiles: false
            )
            return .savedPassword
        } catch {
            Self.logger.error("Failed to migrate inline password for \(connectionKey): \(error.localizedDescription)")
            return .password("")
        }
    }

    private func syncVPNSharedProfiles() {
        #if !CHINA_BUILD
        let sharedProfiles = profiles
            .filter(\.isVPNCapable)
            .map(makeVPNSharedProfileSnapshot)
        VPNSharedProfileStore.write(sharedProfiles)
        #endif
    }

    #if !CHINA_BUILD
    private func makeVPNSharedProfileSnapshot(_ profile: ConnectionProfile) -> VPNSharedProfileSnapshot {
        let auth = makeVPNSharedAuth(
            from: profile.sshConfig.authMethod,
            host: profile.sshConfig.host,
            port: profile.sshConfig.port,
            username: profile.sshConfig.username
        )

        let jumpHost = profile.sshConfig.jumpHost.map { jumpHost in
            VPNSharedJumpHostSnapshot(
                host: jumpHost.host,
                port: jumpHost.port,
                username: jumpHost.username,
                auth: makeVPNSharedAuth(
                    from: jumpHost.authMethod,
                    host: jumpHost.host,
                    port: jumpHost.port,
                    username: jumpHost.username
                ),
                hostKey: pinnedHostKey(host: jumpHost.host, port: jumpHost.port),
                trustedCAKeys: trustedCAKeys(host: jumpHost.host)
            )
        }

        let jumpStartable = jumpHost?.auth.isBackgroundStartable ?? true

        return VPNSharedProfileSnapshot(
            id: profile.id,
            modifiedAt: profile.modifiedAt,
            name: profile.name,
            host: profile.sshConfig.host,
            port: profile.sshConfig.port,
            username: profile.sshConfig.username,
            transportType: profile.connectionProtocol == .trzsz ? .tssh : .ssh,
            auth: auth,
            jumpHost: jumpHost,
            trzszMode: profile.connectionProtocol == .trzsz ? profile.trzszTransportMode.resolved.displayName : nil,
            trzszUDPPortMin: profile.connectionProtocol == .trzsz ? (profile.trzszPortMin ?? TrzszConfig.preferredUDPPortMin) : nil,
            trzszUDPPortMax: profile.connectionProtocol == .trzsz ? (profile.trzszPortMax ?? TrzszConfig.preferredUDPPortMax) : nil,
            trzszMTU: profile.connectionProtocol == .trzsz ? profile.trzszMTU : nil,
            trzszServerPath: profile.connectionProtocol == .trzsz ? profile.trzszServerPath : nil,
            dnsServers: profile.vpnDNSServers,
            excludedRoutes: profile.vpnExcludedRoutes,
            blockQUIC: profile.vpnBlockQUIC ? true : nil,
            isBackgroundStartable: auth.isBackgroundStartable && jumpStartable,
            hostKey: pinnedHostKey(host: profile.sshConfig.host, port: profile.sshConfig.port),
            trustedCAKeys: trustedCAKeys(host: profile.sshConfig.host)
        )
    }

    /// Host key the user already accepted in a terminal session, if any. The
    /// VPN refuses to start without one and the extension pins it on connect.
    private func pinnedHostKey(host: String, port: Int) -> VPNPinnedHostKey? {
        KnownHostsManager.shared.getHost(hostname: host, port: port)
            .map(VPNPinnedHostKey.init)
    }

    /// Trusted host-CA keys applying to `host`, so CA-signed host certificates
    /// validate in the VPN extension without a pinned plain key.
    private func trustedCAKeys(host: String) -> [String]? {
        let keys = HostCAManager.shared.trustedCAOpenSSHKeys(forHost: host)
        return keys.isEmpty ? nil : keys
    }

    private func makeVPNSharedAuth(
        from authMethod: SSHConfig.AuthMethod,
        host: String,
        port: Int,
        username: String
    ) -> VPNSharedProfileAuth {
        switch authMethod {
        case .none:
            return VPNSharedProfileAuth(method: .none, keyID: nil)
        case .savedPassword:
            // Mirror exactly what the background VPN extension can do: read the
            // password Keychain item without user interaction. This is immune to
            // the in-memory `savedPasswords` metadata list being empty or stale
            // (e.g. the snapshot rebuilt before passwords load, or at a locked /
            // background launch), and correctly rejects biometric-gated items the
            // extension could never read. The secret stays in the Keychain.
            let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)
            let usable = KeychainManager.shared.sshPasswordIsBackgroundReadable(connectionKey: connectionKey)
            Self.logger.info("VPN auth probe \(connectionKey): savedPassword backgroundReadable=\(usable)")
            return VPNSharedProfileAuth(method: usable ? .savedPassword : .passwordRequired, keyID: nil)
        case .key(let keyID):
            // The extension cannot enforce rootshell's device-local authentication
            // gate for synchronizable keys, even though their Keychain items are
            // technically readable without interaction. Metadata and secret items
            // sync independently, so missing metadata must also fail closed until
            // SSHKeyManager has discovered it.
            guard let key = SSHKeyManager.shared.savedKeys.first(where: { $0.id == keyID }),
                  key.authRequirement == .none else {
                return VPNSharedProfileAuth(method: .passwordRequired, keyID: nil)
            }

            // A locally biometric-gated key passes a naive existence check but
            // fails silently in the extension's interaction-free Keychain read.
            // Metadata is authoritative above; this probe additionally catches
            // legacy/local items whose Keychain ACL requires interaction.
            if KeychainManager.shared.sshPrivateKeyRequiresInteraction(keyID: keyID) {
                return VPNSharedProfileAuth(method: .passwordRequired, keyID: nil)
            }

            // Legacy-encrypted blob without its local passphrase (synced from
            // another device) can't be decrypted in the extension. Check the
            // blob header, not metadata — the two sync independently.
            if let blob = try? KeychainManager.shared.loadPrivateKey(identifier: keyID.uuidString),
               let keyString = String(data: blob, encoding: .utf8),
               SSHKeyParser.isEncrypted(keyString: keyString),
               KeychainManager.shared.loadPassphrase(forKey: keyID.uuidString) == nil {
                return VPNSharedProfileAuth(method: .passwordRequired, keyID: nil)
            }
            return VPNSharedProfileAuth(method: .key, keyID: keyID)
        case .password:
            return VPNSharedProfileAuth(method: .passwordRequired, keyID: nil)
        case .keyboardInteractive, .unknown:
            // Both need user interaction at connect time, so they aren't
            // background-startable from the VPN extension.
            return VPNSharedProfileAuth(method: .passwordRequired, keyID: nil)
        }
    }
    #endif
}

#if !CHINA_BUILD
extension VPNPinnedHostKey {
    /// Main-app-side bridge; `KnownHost` isn't compiled into the extensions.
    init(_ known: KnownHost) {
        self.init(
            keyType: known.keyType,
            publicKeyBase64: known.publicKeyData,
            fingerprint: known.fingerprint
        )
    }
}
#endif
