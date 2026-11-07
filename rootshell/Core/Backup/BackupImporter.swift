import Foundation
import os.log

enum BackupImporter {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BackupImporter")

    // MARK: - Restore All

    @MainActor
    static func restoreAll(
        payload: BackupPayload,
        categories: Set<BackupCategory>
    ) async -> RestoreSummary {
        var summary = RestoreSummary()

        if categories.contains(.sshKeys), let backup = payload.categories.sshKeys {
            summary.results[.sshKeys] = restoreSSHKeys(backup)
        }

        if categories.contains(.sshPasswords), let backup = payload.categories.sshPasswords {
            summary.results[.sshPasswords] = restoreSSHPasswords(backup)
        }

        if categories.contains(.connectionHistory), let entries = payload.categories.connectionHistory {
            summary.results[.connectionHistory] = restoreConnectionHistory(entries)
        }

        if categories.contains(.knownHosts), let hosts = payload.categories.knownHosts {
            summary.results[.knownHosts] = restoreKnownHosts(hosts)
        }

        if categories.contains(.connectionProfiles), let profiles = payload.categories.connectionProfiles {
            summary.results[.connectionProfiles] = restoreConnectionProfiles(profiles)
        }

        if categories.contains(.customThemes), let backup = payload.categories.customThemes {
            summary.results[.customThemes] = restoreCustomThemes(backup)
        }

        if categories.contains(.customFonts), let backup = payload.categories.customFonts {
            summary.results[.customFonts] = restoreCustomFonts(backup)
        }

        if categories.contains(.keybindOverrides), let data = payload.categories.keybindOverrides {
            summary.results[.keybindOverrides] = restoreKeybindOverrides(data)
        }

        if categories.contains(.keybindOverrides),
           let config = payload.categories.importedKeybindConfig {
            restoreImportedKeybindConfig(config)
        }

        if categories.contains(.hssConfig), let backup = payload.categories.hssConfig {
            summary.results[.hssConfig] = restoreHSSConfig(backup)
        }

        if categories.contains(.cloudAccounts), let backup = payload.categories.cloudAccounts {
            summary.results[.cloudAccounts] = restoreCloudAccounts(backup)
        }

        #if !CHINA_BUILD
        if categories.contains(.aiSettings), let backup = payload.categories.aiSettings {
            summary.results[.aiSettings] = await restoreAISettings(backup)
        }
        #endif

        if categories.contains(.appPreferences), let prefs = payload.categories.appSettings {
            summary.results[.appPreferences] = restoreAppPreferences(prefs)
        }

        if categories.contains(.wifiAPManualEntries), let backup = payload.categories.wifiAPManualEntries {
            summary.results[.wifiAPManualEntries] = restoreWiFiAPManualEntries(backup)
        }

        // Refresh all singleton managers that cache UserDefaults in memory
        refreshAllManagers()

        return summary
    }

    // MARK: - SSH Keys

    @MainActor
    static func restoreSSHKeys(_ backup: SSHKeysBackup) -> RestoreSummary.CategoryResult {
        let keyManager = SSHKeyManager.shared
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        let existingFingerprints = Set(keyManager.savedKeys.map(\.fingerprint))

        // Track old UUID → fingerprint → new UUID for default key restoration
        var oldIDToFingerprint: [UUID: String] = [:]
        for entry in backup.entries {
            oldIDToFingerprint[entry.metadata.id] = entry.metadata.fingerprint
        }

        for entry in backup.entries {
            if existingFingerprints.contains(entry.metadata.fingerprint) {
                skipped += 1
                continue
            }

            guard let keyData = entry.privateKeyData else {
                skipped += 1
                errors.append("No private key data for '\(entry.metadata.name)'")
                continue
            }

            guard let keyString = String(data: keyData, encoding: .utf8) else {
                errors.append("Invalid key data for '\(entry.metadata.name)'")
                continue
            }

            do {
                _ = try keyManager.importKey(
                    name: entry.metadata.name,
                    keyString: keyString,
                    passphrase: entry.passphrase,
                    storageLevel: entry.metadata.storageLevel,
                    authRequirement: entry.metadata.authRequirement
                )
                restored += 1
            } catch {
                errors.append("Failed to import '\(entry.metadata.name)': \(error.localizedDescription)")
            }
        }

        // Restore default key ordering if no defaults are currently set
        if let backupDefaults = backup.defaultKeyIDs, !backupDefaults.isEmpty,
           keyManager.defaultKeyIDs.isEmpty {
            // Build fingerprint → new UUID lookup from current state
            // Fingerprints can repeat (e.g. a software key kept beside its YubiKey copy).
            let fingerprintToNewID: [String: UUID] = Dictionary(
                keyManager.savedKeys.map { ($0.fingerprint, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )

            // Map old default UUIDs → fingerprints → new UUIDs, preserving order
            for oldID in backupDefaults {
                if let fingerprint = oldIDToFingerprint[oldID],
                   let newID = fingerprintToNewID[fingerprint] {
                    keyManager.addToDefaults(id: newID)
                }
            }
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - SSH Passwords

    @MainActor
    static func restoreSSHPasswords(_ backup: SSHPasswordsBackup) -> RestoreSummary.CategoryResult {
        let passwordManager = SSHPasswordManager.shared
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        let existingKeys = Set(passwordManager.savedPasswords.map(\.connectionKey))

        for entry in backup.entries {
            if existingKeys.contains(entry.metadata.connectionKey) {
                skipped += 1
                continue
            }

            do {
                try passwordManager.savePassword(
                    entry.password,
                    host: entry.metadata.host,
                    port: entry.metadata.port,
                    username: entry.metadata.username,
                    storageLevel: entry.metadata.storageLevel,
                    authRequirement: entry.metadata.authRequirement,
                    refreshVPNProfiles: false
                )
                restored += 1
            } catch {
                errors.append("Failed to restore password for \(entry.metadata.displayName): \(error.localizedDescription)")
            }
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - Connection History

    @MainActor
    static func restoreConnectionHistory(_ entries: [SSHConnectionHistoryEntry]) -> RestoreSummary.CategoryResult {
        let historyManager = SSHConnectionHistoryManager.shared

        // applyRemoteChangesWithFailures handles UUID matching, identity-based dedup, and last-write-wins.
        // Returns count of records actually written (new inserts + updates where backup was newer)
        // plus any persistence failures so we can surface them to the user.
        let (applied, failures) = historyManager.applyRemoteChangesWithFailures(entries)
        let skipped = entries.count - applied - failures.count
        let errors = failures.map { id, error in
            "History \(id.uuidString.prefix(8)): \(error.localizedDescription)"
        }

        return RestoreSummary.CategoryResult(restored: applied, skipped: skipped, errors: errors)
    }

    // MARK: - Known Hosts

    @MainActor
    static func restoreKnownHosts(_ hosts: [KnownHost]) -> RestoreSummary.CategoryResult {
        let manager = KnownHostsManager.shared

        let (applied, failures) = manager.applyRemoteChangesWithFailures(hosts)
        let skipped = hosts.count - applied - failures.count
        let errors = failures.map { id, error in
            "Known host \(id.uuidString.prefix(8)): \(error.localizedDescription)"
        }

        return RestoreSummary.CategoryResult(restored: applied, skipped: skipped, errors: errors)
    }

    // MARK: - Connection Profiles

    @MainActor
    static func restoreConnectionProfiles(_ profiles: [ConnectionProfile]) -> RestoreSummary.CategoryResult {
        let manager = ConnectionProfileManager.shared

        let (applied, failures) = manager.applyRemoteChangesWithFailures(profiles)
        let skipped = profiles.count - applied - failures.count
        let errors = failures.map { id, error in
            "Profile \(id.uuidString.prefix(8)): \(error.localizedDescription)"
        }

        return RestoreSummary.CategoryResult(restored: applied, skipped: skipped, errors: errors)
    }

    // MARK: - Custom Themes

    @MainActor
    static func restoreCustomThemes(_ backup: CustomThemesBackup) -> RestoreSummary.CategoryResult {
        let themeManager = CustomThemeManager.shared
        let existingNames = Set(themeManager.customThemes.map { $0.name.lowercased() })
        var restored = 0
        var skipped = 0
        let errors: [String] = []

        for entry in backup.themes {
            if existingNames.contains(entry.theme.name.lowercased()) {
                skipped += 1
                continue
            }

            themeManager.saveTheme(entry.theme)
            restored += 1
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - Custom Fonts

    @MainActor
    static func restoreCustomFonts(_ backup: CustomFontsBackup) -> RestoreSummary.CategoryResult {
        let fontManager = FontManager.shared
        let existingConfigNames = Set(fontManager.customFontFamilies.map(\.configName))
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fontsDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // Accumulate all new families, then write once at the end
        var newFamilies: [FontManager.CustomFontFamily] = []

        for entry in backup.families {
            if existingConfigNames.contains(entry.family.configName) {
                skipped += 1
                continue
            }

            // Write font files to disk
            var allFilesWritten = true
            for fontFile in entry.fontFiles {
                let destURL = fontsDir.appendingPathComponent(fontFile.filename)
                do {
                    try fontFile.data.write(to: destURL)
                } catch {
                    allFilesWritten = false
                    errors.append("Failed to write font file '\(fontFile.originalName)': \(error.localizedDescription)")
                }
            }

            if allFilesWritten {
                newFamilies.append(entry.family)
                restored += 1
            }
        }

        if !newFamilies.isEmpty {
            // Write all new families to UserDefaults in one batch
            var allFamilies = fontManager.customFontFamilies
            allFamilies.append(contentsOf: newFamilies)
            if let data = try? JSONEncoder().encode(allFamilies) {
                UserDefaults.standard.set(data, forKey: "customFontFamilies")
            }

            // Restore bundled-font replacement markers so CoreText resolves correctly
            if let replacedFromBackup = backup.replacedBundledFamilies, !replacedFromBackup.isEmpty {
                let existingReplaced = Set(UserDefaults.standard.stringArray(forKey: "replacedBundledFamilies") ?? [])
                let newConfigNames = Set(newFamilies.map(\.configName))
                // Only add replacements for families we actually restored
                let toAdd = Set(replacedFromBackup).intersection(newConfigNames).subtracting(existingReplaced)
                if !toAdd.isEmpty {
                    let merged = Array(existingReplaced.union(toAdd))
                    UserDefaults.standard.set(merged, forKey: "replacedBundledFamilies")
                }
            }

            fontManager.reloadCustomFonts()
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - Keybind Overrides

    @MainActor
    static func restoreKeybindOverrides(_ data: Data) -> RestoreSummary.CategoryResult {
        let existingData = UserDefaults.standard.data(forKey: "keybindOverrides")

        if let existingData, !existingData.isEmpty {
            // Merge using raw JSON arrays to preserve the full Keybind schema.
            // We only inspect the "action" field for dedup, and keep all other fields intact.
            do {
                let existingArray = try JSONSerialization.jsonObject(with: existingData) as? [[String: Any]] ?? []
                let backupArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

                let existingActions = Set(existingArray.compactMap { $0["action"] as? String })
                var merged = existingArray

                var added = 0
                for entry in backupArray {
                    guard let action = entry["action"] as? String else { continue }
                    if !existingActions.contains(action) {
                        merged.append(entry)
                        added += 1
                    }
                }

                if added > 0 {
                    let mergedData = try JSONSerialization.data(withJSONObject: merged)
                    UserDefaults.standard.set(mergedData, forKey: "keybindOverrides")
                    KeybindManager.shared.reloadOverrides()
                }

                return RestoreSummary.CategoryResult(
                    restored: added,
                    skipped: backupArray.count - added,
                    errors: []
                )
            } catch {
                logger.warning("Failed to merge keybind overrides: \(error.localizedDescription)")
            }
        }

        // No existing data or merge failed — set directly
        UserDefaults.standard.set(data, forKey: "keybindOverrides")
        KeybindManager.shared.reloadOverrides()
        return RestoreSummary.CategoryResult(restored: 1, skipped: 0, errors: [])
    }

    // MARK: - Imported Keybind Config

    @MainActor
    static func restoreImportedKeybindConfig(_ backup: ImportedKeybindConfigBackup) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        let configPath = ghosttyDir.appendingPathComponent("imported_keybinds.conf")

        // Only restore if no imported config currently exists
        guard !FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
            try backup.configContent.write(to: configPath, atomically: true, encoding: .utf8)

            if let filename = backup.originalFilename {
                UserDefaults.standard.set(filename, forKey: "externalGhosttyConfigPath_originalFilename")
            }

            // Setting externalConfigPath triggers didSet which saves + loads + reloads
            KeybindManager.shared.externalConfigPath = configPath
        } catch {
            logger.warning("Failed to restore imported keybind config: \(error.localizedDescription)")
        }
    }

    // MARK: - HSS Config

    @MainActor
    static func restoreHSSConfig(_ backup: HSSConfigBackup) -> RestoreSummary.CategoryResult {
        // Only replace if no config currently loaded
        let manager = HSSConfigManager.shared
        if manager.status.isLoaded {
            return RestoreSummary.CategoryResult(restored: 0, skipped: 1, errors: [])
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let hssFolder = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        let hssPath = hssFolder.appendingPathComponent("hss_config.yml")

        do {
            try FileManager.default.createDirectory(at: hssFolder, withIntermediateDirectories: true)
            try backup.yamlContent.write(to: hssPath, atomically: true, encoding: .utf8)

            #if targetEnvironment(macCatalyst)
            // Catalyst: create a security-scoped bookmark from the file we just wrote
            let bookmarkData = try hssPath.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "hss_config_bookmark")
            #else
            UserDefaults.standard.set(hssPath.path, forKey: "hss_config_filepath")
            #endif

            if let filename = backup.filename {
                UserDefaults.standard.set(filename, forKey: "hss_config_filename")
            }

            Task {
                await manager.reload()
            }

            return RestoreSummary.CategoryResult(restored: 1, skipped: 0, errors: [])
        } catch {
            return RestoreSummary.CategoryResult(
                restored: 0, skipped: 0,
                errors: ["Failed to write HSS config: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Cloud Accounts

    @MainActor
    static func restoreCloudAccounts(_ backup: CloudAccountsBackup) -> RestoreSummary.CategoryResult {
        let accountManager = CloudAccountManager.shared
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        // Build identity set: providerID + label + region (region distinguishes
        // e.g. two AWS accounts with the same name targeting different regions)
        func accountIdentity(_ account: CloudAccount) -> String {
            "\(account.providerID):\(account.label.lowercased()):\(account.awsRegion ?? "")"
        }

        let existingIdentities = Set(accountManager.accounts.map { accountIdentity($0) })

        for entry in backup.entries {
            let identity = accountIdentity(entry.account)
            if existingIdentities.contains(identity) {
                skipped += 1
                continue
            }

            // Decode credentials — addAccount handles Keychain storage internally
            guard let credData = entry.credentialsData,
                  let credentials = try? JSONDecoder().decode(CloudCredentials.self, from: credData) else {
                skipped += 1
                errors.append("No valid credentials for '\(entry.account.label)'")
                continue
            }

            do {
                try accountManager.addAccount(
                    providerID: entry.account.providerID,
                    label: entry.account.label,
                    authMethod: entry.account.authMethod,
                    credentials: credentials,
                    awsRegion: entry.account.awsRegion
                )
                restored += 1
            } catch {
                errors.append("Failed to add account '\(entry.account.label)': \(error.localizedDescription)")
            }
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - AI Settings

    #if !CHINA_BUILD
    @MainActor
    static func restoreAISettings(_ backup: AISettingsBackup) async -> RestoreSummary.CategoryResult {
        let credManager = AICredentialsManager.shared
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        for entry in backup.apiKeys {
            // Minted under the Codex CLI client; no longer usable.
            if entry.accountName == ChatGPTCredentialStore.legacyKeychainAccount {
                skipped += 1
                continue
            }
            if credManager.hasAPIKey(for: entry.accountName) {
                skipped += 1
                continue
            }

            do {
                try credManager.saveAPIKey(entry.apiKey, for: entry.accountName, syncToiCloud: false)
                restored += 1
            } catch {
                errors.append("Failed to restore API key for '\(entry.accountName)': \(error.localizedDescription)")
            }
        }

        // Restore AI settings (fill-only)
        for (key, value) in backup.settings {
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value.anyValue, forKey: key)
                restored += 1
            } else {
                skipped += 1
            }
        }

        // Refresh in-memory state to reflect restored keys and settings
        credManager.reloadFromDefaults()

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }
    #endif

    // MARK: - App Preferences

    @MainActor
    static func restoreAppPreferences(_ prefs: [String: CodableValue]) -> RestoreSummary.CategoryResult {
        var restored = 0
        var skipped = 0

        for (key, value) in prefs {
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value.anyValue, forKey: key)
                restored += 1
            } else {
                skipped += 1
            }
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: [])
    }

    // MARK: - WiFi AP Manual Entries

    @MainActor
    static func restoreWiFiAPManualEntries(_ backup: WiFiAPManualEntriesBackup) -> RestoreSummary.CategoryResult {
        let manager = ManualAPManager.shared
        var existingMACs = Set(manager.manualAPs.map(\.mac))
        var restored = 0
        var skipped = 0
        var errors: [String] = []

        for ap in backup.accessPoints {
            let domain = backup.vendorDomains[ap.mac]

            if existingMACs.contains(ap.mac) {
                // Update existing entry if the backup has newer data
                let backupDate = ap.lastUpdated ?? .distantPast
                let existingAP = manager.manualAPs.first { $0.mac == ap.mac }
                let existingDate = existingAP?.lastUpdated ?? .distantPast

                if backupDate > existingDate {
                    manager.updateManualAP(
                        mac: ap.mac,
                        name: ap.name,
                        vendorName: ap.productLine,
                        vendorDomain: domain,
                        model: ap.model,
                        siteName: ap.siteName
                    )
                    restored += 1
                } else {
                    skipped += 1
                }
                continue
            }

            let result = manager.addManualAP(
                bssid: ap.mac,
                name: ap.name,
                vendorName: ap.productLine,
                vendorDomain: domain,
                model: ap.model,
                siteName: ap.siteName
            )

            if result != nil {
                restored += 1
                existingMACs.insert(ap.mac)
            } else {
                errors.append("Failed to restore manual AP '\(ap.name)' (\(ap.mac))")
            }
        }

        return RestoreSummary.CategoryResult(restored: restored, skipped: skipped, errors: errors)
    }

    // MARK: - Post-Restore Manager Refresh

    /// Re-reads UserDefaults into all singleton managers that cache state in memory.
    /// Must be called after restore writes new values, otherwise the running app
    /// will show stale settings until restart.
    @MainActor
    static func refreshAllManagers() {
        // Theme
        if let theme = UserDefaults.standard.string(forKey: "selectedTheme") {
            ThemeManager.shared.currentTheme = theme
        }

        // Appearance
        let appearance = AppearanceManager.shared
        if let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") {
            appearance.currentAppearanceMode = AppearanceManager.AppearanceMode(rawValue: modeRaw) ?? .automatic
        }
        if UserDefaults.standard.object(forKey: "themedUI") != nil {
            appearance.themedUIEnabled = UserDefaults.standard.bool(forKey: "themedUI")
        }

        // Per-theme UI color overrides — JSON blob persisted by
        // ThemeUIOverridesManager. The singleton cached the pre-restore
        // dictionary in memory, so force a re-read after the import.
        ThemeUIOverridesManager.shared.reloadFromDefaults()

        // Day/Night themes
        let dayNight = DayNightThemeManager.shared
        if UserDefaults.standard.object(forKey: "dayNightThemeEnabled") != nil {
            dayNight.enabled = UserDefaults.standard.bool(forKey: "dayNightThemeEnabled")
        }
        if let day = UserDefaults.standard.string(forKey: "dayNightThemeDayTheme") {
            dayNight.dayTheme = day
        }
        if let night = UserDefaults.standard.string(forKey: "dayNightThemeNightTheme") {
            dayNight.nightTheme = night
        }

        // Font
        let font = FontManager.shared
        let savedSize = UserDefaults.standard.double(forKey: "fontSize")
        if savedSize > 0 { font.currentFontSize = savedSize }
        if let family = UserDefaults.standard.string(forKey: "fontFamily") {
            font.currentFontFamily = family
        }
        if UserDefaults.standard.object(forKey: "ligaturesEnabled") != nil {
            font.ligaturesEnabled = UserDefaults.standard.bool(forKey: "ligaturesEnabled")
        }

        // Cursor
        let cursor = CursorManager.shared
        if let styleRaw = UserDefaults.standard.string(forKey: "cursorStyle") {
            cursor.cursorStyle = CursorStyle(rawValue: styleRaw) ?? .block
        }
        if UserDefaults.standard.object(forKey: "cursorBlinkEnabled") != nil {
            cursor.cursorBlinkEnabled = UserDefaults.standard.bool(forKey: "cursorBlinkEnabled")
        }
        if let effectRaw = UserDefaults.standard.string(forKey: "cursorEffect") {
            cursor.cursorEffect = CursorEffect(rawValue: effectRaw) ?? .none
        }
        if let color = UserDefaults.standard.string(forKey: "cursorColor") {
            cursor.cursorColor = color
        }
        if let textColor = UserDefaults.standard.string(forKey: "cursorTextColor") {
            cursor.cursorTextColor = textColor
        }
        if UserDefaults.standard.object(forKey: "cursorOpacity") != nil {
            cursor.cursorOpacity = UserDefaults.standard.double(forKey: "cursorOpacity")
        }
        if UserDefaults.standard.object(forKey: "cursorThickness") != nil {
            cursor.cursorThickness = UserDefaults.standard.integer(forKey: "cursorThickness")
        }
        if UserDefaults.standard.object(forKey: "cursorHeight") != nil {
            cursor.cursorHeight = UserDefaults.standard.integer(forKey: "cursorHeight")
        }

        // Transparency
        let transparency = TransparencyManager.shared
        if UserDefaults.standard.object(forKey: "backgroundOpacity") != nil {
            transparency.backgroundOpacity = UserDefaults.standard.double(forKey: "backgroundOpacity")
        }
        if UserDefaults.standard.object(forKey: "backgroundBlurRadius") != nil {
            transparency.backgroundBlurRadius = UserDefaults.standard.double(forKey: "backgroundBlurRadius")
        }
        if UserDefaults.standard.object(forKey: "blurEnabled") != nil {
            transparency.blurEnabled = UserDefaults.standard.bool(forKey: "blurEnabled")
        }
        if let styleRaw = UserDefaults.standard.string(forKey: "blurStyle"),
           let style = TransparencyManager.BlurStyle(rawValue: styleRaw) {
            transparency.blurStyle = style
        }
        if UserDefaults.standard.object(forKey: "pinnedSidebarTransparencyEnabled") != nil {
            transparency.pinnedSidebarTransparencyEnabled = UserDefaults.standard.bool(
                forKey: "pinnedSidebarTransparencyEnabled"
            )
        }

        // Selection
        let selection = SelectionManager.shared
        if let modeRaw = UserDefaults.standard.string(forKey: "selectionAppearanceMode") {
            selection.selectionMode = SelectionAppearanceMode(rawValue: modeRaw) ?? .rootshell
        }
        if let fg = UserDefaults.standard.string(forKey: "selectionForegroundHex") {
            selection.customForegroundHex = fg
        }
        if let bg = UserDefaults.standard.string(forKey: "selectionBackgroundHex") {
            selection.customBackgroundHex = bg
        }

        // Sound
        let sound = SoundManager.shared
        if let presetRaw = UserDefaults.standard.string(forKey: "bellSoundPreset") {
            sound.bellPreset = BellSoundPreset(rawValue: presetRaw) ?? .hapticOnly
        }
        if UserDefaults.standard.object(forKey: "bellSoundVolume") != nil {
            sound.bellVolume = UserDefaults.standard.float(forKey: "bellSoundVolume")
        }
        if let notifRaw = UserDefaults.standard.string(forKey: "notificationSoundPreset") {
            sound.notificationPreset = NotificationSoundPreset(rawValue: notifRaw) ?? .systemDefault
        }

        // Manual WiFi APs
        ManualAPManager.shared.reload()

        // Notifications
        let notifications = NotificationManager.shared
        if UserDefaults.standard.object(forKey: "ssh_notification_enabled") != nil {
            notifications.isEnabled = UserDefaults.standard.bool(forKey: "ssh_notification_enabled")
        }
        if UserDefaults.standard.object(forKey: "terminal_notification_enabled") != nil {
            notifications.terminalNotificationsEnabled = UserDefaults.standard.bool(forKey: "terminal_notification_enabled")
        }
    }
}
