//
//  Settings+System.swift
//  rootshell
//
//  Device-only system keys (sync state, debug flags, migrations), prefix
//  rules, and the area list the registry is assembled from.
//

import Foundation

nonisolated extension Settings {
    enum System {
        static let cloudKitSyncEnabled = SettingKey(
            "cloudKitSyncEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Enable iCloud Sync", comment: "Setting title"))
        static let cloudKitSyncHistory = SettingKey(
            "cloudKitSyncHistory", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync SSH History", comment: "Setting title"))
        static let cloudKitSyncKnownHosts = SettingKey(
            "cloudKitSyncKnownHosts", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Known Hosts", comment: "Setting title"))
        static let cloudKitSyncProfiles = SettingKey(
            "cloudKitSyncProfiles", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Connection Profiles", comment: "Setting title"))
        static let cloudKitSyncAppSettings = SettingKey(
            "cloudKitSyncAppSettings", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Settings", comment: "Setting title"))
        static let cloudKitDeviceID = SettingKey<String?>(
            "cloudKitDeviceID", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Device ID", comment: "Setting title"))
        static let cloudKitMigratedToCustomZone = SettingKey(
            "cloudKitMigratedToCustomZone", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Zone Migration", comment: "Setting title"))
        static let cloudKitZoneChangeToken = SettingKey<Data?>(
            "cloudKitZoneChangeToken", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Change Token", comment: "Setting title"))
        static let cloudKitLastSyncDate = AnySettingDefinition.opaque(
            "cloudKitLastSyncDate", title: String(localized: "Last Sync", comment: "Setting title"))
        static let resumeDebugLogging = SettingKey(
            "resumeDebugLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Resume Debug Logging", comment: "Setting title"))
        static let lifecycleDebugLogging = SettingKey(
            "lifecycleDebugLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Lifecycle Debug Logging", comment: "Setting title"))
        static let lifecycleSyncRendererDrain = SettingKey(
            "lifecycleSyncRendererDrainEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Synchronous Renderer Drain", comment: "Setting title"))
        static let lifecycleVerboseWiFiPollLogging = SettingKey(
            "lifecycleVerboseWiFiPollLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Verbose WiFi Poll Logging", comment: "Setting title"))
        static let sshDebugLogging = SettingKey(
            "sshDebugLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "SSH Debug Logging", comment: "Setting title"))
        static let vncDebugLogging = SettingKey(
            "vncDebugLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Screen Sharing Debug Logging", comment: "Setting title"))
        static let tmuxDebugLogging = SettingKey(
            "tmuxDebugLoggingEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "tmux Debug Logging", comment: "Setting title"))
        static let herdrForceFallback = SettingKey(
            "herdrForceFallbackEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Force herdr Fallback Mode", comment: "Setting title"))
        static let agentDetectionCapture = SettingKey(
            "agentDetectionCaptureEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Record Detection Snapshots", comment: "Setting title"))
        static let ghosttyBookmarkNames = AnySettingDefinition.opaque(
            "ghosttyBookmarkNames", title: String(localized: "Bookmark Name Map", comment: "Setting title"))
        static let applePressAndHold = SettingKey(
            "ApplePressAndHoldEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Press and Hold (system)", comment: "Setting title"))
        static let sparkleAutomaticChecks = SettingKey(
            "SUEnableAutomaticChecks", default: true, group: .system, policy: .deviceOnly,
            title: String(localized: "Automatically Check for Updates", comment: "Setting title"))
        static let sparkleCheckInterval = SettingKey(
            "SUScheduledCheckInterval", default: 86400.0, group: .system, policy: .deviceOnly,
            title: String(localized: "Update Check Interval", comment: "Setting title"))
        static let configOverlayBookmark = SettingKey<Data?>(
            "configOverlay.bookmark", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Config File Bookmark", comment: "Setting title"))
        static let configOverlayExternalPath = SettingKey<String?>(
            "configOverlay.externalPath", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Config File Path", comment: "Setting title"))
        static let configOverlayWriteBack = SettingKey(
            "configOverlay.writeBackEnabled", default: true, group: .system, policy: .deviceOnly,
            title: String(localized: "Allow Settings to Edit Config File", comment: "Setting title"))

        /// Key families whose full names are composed at runtime.
        static let prefixRules: [SettingsRegistry.PrefixRule] = [
            .init(prefix: "paste.destination.", valueType: .string, policy: .deviceOnly, group: .transfer,
                  title: String(localized: "Upload Destination (per host)", comment: "Setting title")),
            .init(prefix: "tabSidebarGroupOrder.", valueType: .stringArray, policy: .deviceOnly, group: .sidebar,
                  title: String(localized: "Tab Group Order (per window)", comment: "Setting title")),
            .init(prefix: "cloudKitEmptyRecoveryAttempted.", valueType: .bool, policy: .deviceOnly, group: .system,
                  title: String(localized: "Sync Empty-Store Recovery", comment: "Setting title")),
        ] + Settings.AI.prefixRules

        static let all: [AnySettingDefinition] = [
            cloudKitSyncEnabled.erased, cloudKitSyncHistory.erased, cloudKitSyncKnownHosts.erased,
            cloudKitSyncProfiles.erased, cloudKitSyncAppSettings.erased, cloudKitDeviceID.erased,
            cloudKitMigratedToCustomZone.erased, cloudKitZoneChangeToken.erased, cloudKitLastSyncDate,
            resumeDebugLogging.erased, lifecycleDebugLogging.erased, lifecycleSyncRendererDrain.erased,
            lifecycleVerboseWiFiPollLogging.erased, sshDebugLogging.erased, vncDebugLogging.erased,
            tmuxDebugLogging.erased, herdrForceFallback.erased, agentDetectionCapture.erased,
            ghosttyBookmarkNames, applePressAndHold.erased,
            sparkleAutomaticChecks.erased, sparkleCheckInterval.erased,
            configOverlayBookmark.erased, configOverlayExternalPath.erased, configOverlayWriteBack.erased,
        ]
    }

    /// Every area the registry assembles. Add new areas here.
    static let allAreas: [[AnySettingDefinition]] = [
        Theme.all, Font.all, Cursor.all, Selection.all, Transparency.all, Palette.all, Shaders.all,
        Tabs.all, Sidebar.all, Window.all, Power.all, Visor.all,
        Terminal.all, Gestures.all, Prompt.all, Locale.all, SessionRestore.all,
        Keyboard.all, KeyboardToolbar.all, Keybinds.all,
        Connections.all, Multiplexer.all, SSHAgent.all, HostTrust.all, Roam.all, ScreenSharing.all, Transfer.all,
        AI.all,
        Notifications.all, CodingAgents.all, Sounds.all, LiveActivity.all, Privacy.all, Clipboard.all,
        System.all, Legacy.all,
    ]
}
