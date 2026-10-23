//
//  Settings+Notifications.swift
//  rootshell
//
//  Notifications, coding agents, sounds, live activity, privacy, and clipboard keys.
//

import Foundation

extension AgentNotificationPolicy: SettingValue {}
extension TaskNotificationPolicy: SettingValue {}
extension BellSoundPreset: SettingValue {}
extension NotificationSoundPreset: SettingValue {}
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
extension LiveActivitySessionFilter: SettingValue {}
#endif
extension AgentInboxIslandLayout: SettingValue {}
extension GeoProviderType: SettingValue {}
extension ClipboardHistoryManager.Retention: SettingValue {}

nonisolated extension Settings {
    enum Notifications {
        static let sshReminders = SettingKey(
            "ssh_notification_enabled", default: false, group: .notifications, configKey: "ssh-notification-enabled",
            title: String(localized: "SSH Session Reminders", comment: "Setting title"))
        static let terminalNotifications = SettingKey(
            "terminal_notification_enabled", default: false, group: .notifications, configKey: "terminal-notification-enabled",
            title: String(localized: "Terminal Notifications", comment: "Setting title"))
        static let agentPolicy = SettingKey(
            "agentNotificationPolicy", default: AgentNotificationPolicy.blockedOnly, group: .notifications,
            configKey: "agent-notification-policy",
            title: String(localized: "Agent Notifications", comment: "Setting title"))
        static let agentIncludePrompt = SettingKey(
            "agentNotificationIncludePrompt", default: true, group: .notifications, configKey: "agent-notification-include-prompt",
            title: String(localized: "Include the Question", comment: "Setting title"))
        static let taskDetection = SettingKey(
            "taskDetectionEnabled", default: false, group: .notifications, configKey: "task-detection-enabled",
            title: String(localized: "Detect Long-Running Commands", comment: "Setting title"))
        static let taskPolicy = SettingKey(
            "taskNotificationPolicy", default: TaskNotificationPolicy.blockedOnly, group: .notifications,
            configKey: "task-notification-policy",
            title: String(localized: "Task Notifications", comment: "Setting title"))
        static let taskDetectPrompts = SettingKey(
            "taskDetectPrompts", default: true, group: .notifications, configKey: "task-detect-prompts",
            title: String(localized: "Detect Prompts", comment: "Setting title"))
        static let taskDetectTests = SettingKey(
            "taskDetectTests", default: true, group: .notifications, configKey: "task-detect-tests",
            title: String(localized: "Detect Tests", comment: "Setting title"))
        static let taskDetectBuilds = SettingKey(
            "taskDetectBuilds", default: true, group: .notifications, configKey: "task-detect-builds",
            title: String(localized: "Detect Builds", comment: "Setting title"))
        static let taskDetectInfra = SettingKey(
            "taskDetectInfra", default: true, group: .notifications, configKey: "task-detect-infra",
            title: String(localized: "Detect Infrastructure Commands", comment: "Setting title"))
        static let taskDetectTransfers = SettingKey(
            "taskDetectTransfers", default: true, group: .notifications, configKey: "task-detect-transfers",
            title: String(localized: "Detect Transfers", comment: "Setting title"))
        static let pushAgentBackgroundOnly = SettingKey(
            "pushAgentBackgroundOnly", default: false, group: .notifications, configKey: "push-agent-background-only",
            title: String(localized: "Push Only When in Background", comment: "Setting title"))
        static let pushAgentLogos = SettingKey(
            "pushAgentLogosEnabled", default: true, group: .notifications, configKey: "push-agent-logos-enabled",
            title: String(localized: "Show Agent Logos", comment: "Setting title"))
        static let pushEnabled = SettingKey(
            "pushNotificationsEnabled", default: false, group: .notifications, policy: .deviceOnly,
            title: String(localized: "Push Notifications", comment: "Setting title"))
        static let pushPairedSenders = SettingKey<Data?>(
            "pushPairedSenders", default: nil, group: .notifications, policy: .deviceOnly,
            title: String(localized: "Paired Push Senders", comment: "Setting title"))
        static let pushRevokedSenders = SettingKey(
            "pushRevokedSenders", default: [String](), group: .notifications, policy: .deviceOnly,
            title: String(localized: "Revoked Push Senders", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            sshReminders.erased, terminalNotifications.erased, agentPolicy.erased, agentIncludePrompt.erased,
            taskDetection.erased, taskPolicy.erased, taskDetectPrompts.erased, taskDetectTests.erased,
            taskDetectBuilds.erased, taskDetectInfra.erased, taskDetectTransfers.erased,
            pushAgentBackgroundOnly.erased, pushAgentLogos.erased,
            pushEnabled.erased, pushPairedSenders.erased, pushRevokedSenders.erased,
        ]
    }

    enum CodingAgents {
        static let detectionEnabled = SettingKey(
            "agentDetectionEnabled", default: true, group: .codingAgents, configKey: "agent-detection-enabled",
            title: String(localized: "Detect Coding Agents", comment: "Setting title"))
        static let attentionBadges = SettingKey(
            "agentAttentionBadgesEnabled", default: true, group: .codingAgents, configKey: "agent-attention-badges-enabled",
            title: String(localized: "Show Attention Badges", comment: "Setting title"))
        static let projectProbes = SettingKey(
            "agentProjectProbes", default: true, group: .codingAgents, configKey: "agent-project-probes",
            title: String(localized: "Look Up Project Details", comment: "Setting title"))
        static let usageTracking = SettingKey(
            "agentUsageTrackingEnabled", default: true, group: .codingAgents, configKey: "agent-usage-tracking-enabled",
            title: String(localized: "Show Subscription Usage", comment: "Setting title"))
        static let inboxSort = SettingKey(
            "agentInboxSort", default: "static", group: .codingAgents, policy: .localByDefault, configKey: "agent-inbox-sort",
            title: String(localized: "Agent Sort", comment: "Setting title"))
        static let usageAccountStates = SettingKey<Data?>(
            "agentUsageAccountStates", default: nil, group: .codingAgents, policy: .deviceOnly,
            title: String(localized: "Subscription Usage Cache", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            detectionEnabled.erased, attentionBadges.erased, projectProbes.erased, usageTracking.erased,
            inboxSort.erased, usageAccountStates.erased,
        ]
    }

    enum Sounds {
        static let bellPreset = SettingKey(
            "bellSoundPreset", default: BellSoundPreset.hapticOnly, group: .sounds, configKey: "bell-sound-preset",
            title: String(localized: "Bell Sound", comment: "Setting title"))
        static let bellVolume = SettingKey(
            "bellSoundVolume", default: Float(0.7), group: .sounds, configKey: "bell-sound-volume",
            title: String(localized: "Bell Volume", comment: "Setting title"))
        static let notificationPreset = SettingKey(
            "notificationSoundPreset", default: NotificationSoundPreset.systemDefault, group: .sounds,
            configKey: "notification-sound-preset",
            title: String(localized: "Notification Sound", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [bellPreset.erased, bellVolume.erased, notificationPreset.erased]
    }

    enum LiveActivity {
        static let enabled = SettingKey(
            "live_activity_enabled", default: false, group: .liveActivity, configKey: "live-activity-enabled",
            title: String(localized: "Live Activity", comment: "Setting title"))
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        static let sessionFilter = SettingKey(
            "live_activity_session_filter", default: LiveActivitySessionFilter.diary, group: .liveActivity,
            configKey: "live-activity-session-filter",
            title: String(localized: "Live Activity Session Filter", comment: "Setting title"))
        #else
        static let sessionFilter = SettingKey(
            "live_activity_session_filter", default: "diary", group: .liveActivity,
            configKey: "live-activity-session-filter",
            title: String(localized: "Live Activity Session Filter", comment: "Setting title"))
        #endif
        static let networkInfo = SettingKey(
            "live_activity_network_info_enabled", default: false, group: .liveActivity,
            configKey: "live-activity-network-info-enabled",
            title: String(localized: "Live Activity Network Info", comment: "Setting title"))
        static let wifiInfo = SettingKey(
            "live_activity_wifi_info_enabled", default: false, group: .liveActivity,
            configKey: "live-activity-wifi-info-enabled",
            title: String(localized: "Live Activity WiFi Info", comment: "Setting title"))
        static let agents = SettingKey(
            "live_activity_agents_enabled", default: false, group: .liveActivity,
            configKey: "live-activity-agents-enabled",
            title: String(localized: "Live Activity Coding Agents", comment: "Setting title"))
        static let agentMessages = SettingKey(
            "live_activity_agent_messages", default: AgentInboxIslandLayout.off, group: .liveActivity,
            configKey: "live-activity-agent-messages",
            title: String(localized: "Live Activity Agent Messages", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            enabled.erased, sessionFilter.erased, networkInfo.erased, wifiInfo.erased, agents.erased,
            agentMessages.erased,
        ]
    }

    enum AgentInbox {
        static let presentation = SettingKey(
            "agentInbox.presentation", default: PanelPresentation.sidebar, group: .notifications,
            configKey: "agent-inbox-presentation",
            title: String(localized: "Agent Inbox Presentation", comment: "Setting title"))
        static let sidebarWidth = SettingKey(
            "agentInbox.sidebar.width", default: 400.0, group: .notifications, policy: .deviceOnly,
            title: String(localized: "Agent Inbox Sidebar Width", comment: "Setting title"))
        static let hudWidth = SettingKey(
            "agentInbox.hud.width", default: 520.0, group: .notifications, policy: .deviceOnly,
            title: String(localized: "Agent Inbox Overlay Width", comment: "Setting title"))
        static let hudHeight = SettingKey(
            "agentInbox.hud.height", default: 640.0, group: .notifications, policy: .deviceOnly,
            title: String(localized: "Agent Inbox Overlay Height", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            presentation.erased, sidebarWidth.erased, hudWidth.erased, hudHeight.erased,
        ]
    }

    enum Privacy {
        // Mirrors GeoProviderType.defaultProvider without touching the MainActor enum.
        static let geoProviderType = SettingKey(
            "geoProviderType", default: IPInfoLiteClient.isConfigured ? GeoProviderType.ipinfo : .dns,
            group: .privacy, configKey: "geo-provider-type",
            title: String(localized: "IP Geolocation", comment: "Setting title"))
        static let locationDiaryAutoMode = SettingKey(
            "location_diary_auto_mode", default: false, group: .privacy, configKey: "location-diary-auto-mode",
            title: String(localized: "Location Diary Mode", comment: "Setting title"))
        static let autoRedact = SettingKey(
            "autoRedactEnabled", default: false, group: .privacy, configKey: "auto-redact-enabled",
            title: String(localized: "Redact Sensitive Text", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            geoProviderType.erased, locationDiaryAutoMode.erased, autoRedact.erased,
        ]
    }

    enum Clipboard {
        static let managerEnabled = SettingKey(
            "clipboardManagerEnabled", default: false, group: .clipboard, configKey: "clipboard-manager-enabled",
            title: String(localized: "Clipboard Manager", comment: "Setting title"))
        static let requireBiometric = SettingKey(
            "clipboardManagerRequireBiometric", default: false, group: .clipboard,
            configKey: "clipboard-manager-require-biometric",
            title: String(localized: "Require Biometrics to Open Clipboard", comment: "Setting title"))
        static let retention = SettingKey(
            "clipboardManagerRetention", default: ClipboardHistoryManager.Retention.week, group: .clipboard,
            configKey: "clipboard-manager-retention",
            title: String(localized: "Keep Clipboard History", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [managerEnabled.erased, requireBiometric.erased, retention.erased]
    }
}
