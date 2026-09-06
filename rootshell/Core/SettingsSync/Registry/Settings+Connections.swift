//
//  Settings+Connections.swift
//  rootshell
//
//  SSH, multiplexer, agent, host trust, roam, screen sharing, and transfer keys.
//

import Foundation

extension ProfileSortOrder: SettingValue {}
extension KeyAuthRequirement: SettingValue {}
extension KeyStorageLevel: SettingValue {}
extension TmuxAutoMode: SettingValue {}
extension TmuxTabCloseAction: SettingValue {}
extension SessionDiscoverySortOrder: SettingValue {}
extension MoshConfig.PredictionMode: SettingValue {}
extension TrzszConfig.TransportMode: SettingValue {}
extension ScreenSharingClipboardSyncDefault: SettingValue {}
extension ScreenSharingPanningDefault: SettingValue {}

nonisolated extension Settings {
    enum Connections {
        static let hideNonPQKexWarning = SettingKey(
            "hideNonPQKexWarning", default: false, group: .connections, configKey: "hide-non-pq-kex-warning",
            title: String(localized: "Post-Quantum Warning", comment: "Setting title"))
        static let forceIPv4 = SettingKey(
            "sshForceIPv4Enabled", default: false, group: .connections, configKey: "ssh-force-ipv4-enabled",
            title: String(localized: "Force IPv4", comment: "Setting title"))
        static let healthMonitoring = SettingKey(
            "sshHealthMonitoringEnabled", default: true, group: .connections, configKey: "ssh-health-monitoring-enabled",
            title: String(localized: "Connection Health Monitoring", comment: "Setting title"))
        static let healthProbeInterval = SettingKey(
            "sshHealthProbeInterval", default: 15, group: .connections, configKey: "ssh-health-probe-interval",
            title: String(localized: "Probe Interval", comment: "Setting title"))
        static let publicKeyAuthProbe = SettingKey(
            "sshPublicKeyAuthProbeEnabled", default: false, group: .connections, configKey: "ssh-public-key-auth-probe-enabled",
            title: String(localized: "OpenSSH Public Key Compatibility", comment: "Setting title"))
        static let backgroundKeepalive = SettingKey(
            "backgroundSessionKeepaliveEnabled", default: true, group: .connections, configKey: "background-session-keepalive-enabled",
            title: String(localized: "Keep SSH Alive in Background", comment: "Setting title"))
        static let autoReconnectEnabled = SettingKey(
            "autoReconnectEnabled", default: true, group: .connections, configKey: "auto-reconnect-enabled",
            title: String(localized: "Auto Reconnect", comment: "Setting title"))
        static let autoReconnectMaxAttempts = SettingKey(
            "autoReconnectMaxAttempts", default: 5, group: .connections, configKey: "auto-reconnect-max-attempts",
            title: String(localized: "Reconnect Attempts", comment: "Setting title"))
        static let profilesSortOrder = SettingKey(
            "profilesSortOrder", default: ProfileSortOrder.name, group: .connections, configKey: "profiles-sort-order",
            title: String(localized: "Sort Profiles By", comment: "Setting title"))
        static let passwordDefaultAuthRequirement = SettingKey(
            "sshPasswordDefaultAuthRequirement", default: KeyAuthRequirement.none, group: .connections,
            configKey: "ssh-password-default-auth-requirement",
            title: String(localized: "Saved Password Authentication", comment: "Setting title"))
        static let passwordDefaultStorageLevel = SettingKey(
            "sshPasswordDefaultStorageLevel", default: KeyStorageLevel.backupOnly, group: .connections,
            configKey: "ssh-password-default-storage-level",
            title: String(localized: "Saved Password Storage", comment: "Setting title"))
        static let backgroundTunnelEnabledProfiles = SettingKey<Data?>(
            "backgroundTunnelEnabledProfiles", default: nil, group: .connections, policy: .localByDefault,
            title: String(localized: "Background Tunnels", comment: "Setting title"))
        static let hasSeenPortForwardBackgroundPrompt = SettingKey(
            "hasSeenPortForwardBackgroundPrompt", default: false, group: .connections, policy: .deviceOnly,
            title: String(localized: "Port Forward Prompt Seen", comment: "Setting title"))
        static let lastConnectionType = SettingKey<String?>(
            "lastConnectionType", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Last Connection Type", comment: "Setting title"))
        static let passwordLastUsedDates = SettingKey<Data?>(
            "sshPasswordLastUsedDates", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Password Last Used", comment: "Setting title"))
        static let cloudAccountsMetadata = SettingKey<Data?>(
            "cloudAccountsMetadata", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Cloud Accounts", comment: "Setting title"))
        static let wifiAPAccountsMetadata = SettingKey<Data?>(
            "wifiAPAccountsMetadata", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "WiFi AP Accounts", comment: "Setting title"))
        static let kubernetesClustersMetadata = SettingKey<Data?>(
            "kubernetes_clusters_metadata", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Kubernetes Clusters", comment: "Setting title"))
        static let k8sNodeShellDeviceID = SettingKey<String?>(
            "k8sNodeShellDeviceID", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Kubernetes Node Shell Device ID", comment: "Setting title"))
        static let hssConfigBookmark = SettingKey<Data?>(
            "hss_config_bookmark", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "HSS Config Bookmark", comment: "Setting title"))
        static let hssConfigFilename = SettingKey<String?>(
            "hss_config_filename", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "HSS Config Filename", comment: "Setting title"))
        static let hssConfigFilepath = SettingKey<String?>(
            "hss_config_filepath", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "HSS Config Path", comment: "Setting title"))
        static let sshKeysMetadataLegacy = SettingKey<Data?>(
            "sshKeysMetadata", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "SSH Key Metadata (legacy)", comment: "Setting title"))
        static let sshKeysMetadataMigrated = SettingKey(
            "sshKeysMetadataMigratedToKeychain", default: false, group: .connections, policy: .deviceOnly,
            title: String(localized: "SSH Key Metadata Migrated", comment: "Setting title"))
        static let connectionHistoryLegacy = SettingKey<Data?>(
            "ssh_connection_history", default: nil, group: .connections, policy: .deviceOnly,
            title: String(localized: "Connection History (legacy)", comment: "Setting title"))
        static let gpgKeygripInvalidationDone = SettingKey(
            "rootshell.gpgKeygripV3InvalidationDone", default: false, group: .connections, policy: .deviceOnly,
            title: String(localized: "GPG Keygrip Migration", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            hideNonPQKexWarning.erased, forceIPv4.erased, healthMonitoring.erased, healthProbeInterval.erased,
            publicKeyAuthProbe.erased, backgroundKeepalive.erased, autoReconnectEnabled.erased,
            autoReconnectMaxAttempts.erased, profilesSortOrder.erased, passwordDefaultAuthRequirement.erased,
            passwordDefaultStorageLevel.erased, backgroundTunnelEnabledProfiles.erased,
            hasSeenPortForwardBackgroundPrompt.erased, lastConnectionType.erased, passwordLastUsedDates.erased,
            cloudAccountsMetadata.erased, wifiAPAccountsMetadata.erased, kubernetesClustersMetadata.erased,
            k8sNodeShellDeviceID.erased, hssConfigBookmark.erased, hssConfigFilename.erased, hssConfigFilepath.erased,
            sshKeysMetadataLegacy.erased, sshKeysMetadataMigrated.erased, connectionHistoryLegacy.erased,
            gpgKeygripInvalidationDone.erased,
        ]
    }

    enum Multiplexer {
        static let tmuxSessionName = SettingKey(
            "tmuxSessionName", default: "", group: .multiplexer, configKey: "tmux-session-name",
            title: String(localized: "tmux Session Name", comment: "Setting title"))
        static let tmuxCustomCommand = SettingKey(
            "tmuxCustomCommand", default: "", group: .multiplexer, configKey: "tmux-custom-command",
            title: String(localized: "tmux Auto-Start Command", comment: "Setting title"))
        static let tmuxSessionDiscovery = SettingKey(
            "tmuxSessionDiscoveryEnabled", default: true, group: .multiplexer, configKey: "tmux-session-discovery-enabled",
            title: String(localized: "Discover tmux Sessions", comment: "Setting title"))
        static let tmuxAutoHideGatewayOnAttach = SettingKey(
            "tmuxAutoHideGatewayOnAttach", default: false, group: .multiplexer, configKey: "tmux-auto-hide-gateway-on-attach",
            title: String(localized: "Auto-hide Gateway on Attach", comment: "Setting title"))
        static let tmuxDiscoveryAttachMode = SettingKey(
            "tmuxDiscoveryAttachMode", default: TmuxAutoMode.regular, group: .multiplexer, configKey: "tmux-discovery-attach-mode",
            title: String(localized: "tmux Attach Mode", comment: "Setting title"))
        static let tmuxTabCloseAction = SettingKey(
            "tmuxTabCloseAction", default: TmuxTabCloseAction.closeWindow, group: .multiplexer, configKey: "tmux-tab-close-action",
            title: String(localized: "tmux Close Tab Action", comment: "Setting title"))
        static let zellijSessionDiscovery = SettingKey(
            "zellijSessionDiscoveryEnabled", default: true, group: .multiplexer, configKey: "zellij-session-discovery-enabled",
            title: String(localized: "Discover zellij Sessions", comment: "Setting title"))
        static let herdrSessionName = SettingKey(
            "herdrSessionName", default: "", group: .multiplexer, configKey: "herdr-session-name",
            title: String(localized: "herdr Session Name", comment: "Setting title"))
        static let herdrCustomCommand = SettingKey(
            "herdrCustomCommand", default: "", group: .multiplexer, configKey: "herdr-custom-command",
            title: String(localized: "herdr Auto-Start Command", comment: "Setting title"))
        static let herdrSessionDiscovery = SettingKey(
            "herdrSessionDiscoveryEnabled", default: true, group: .multiplexer, configKey: "herdr-session-discovery-enabled",
            title: String(localized: "Discover herdr Sessions", comment: "Setting title"))
        static let zmxSessionName = SettingKey(
            "zmxSessionName", default: "", group: .multiplexer, configKey: "zmx-session-name",
            title: String(localized: "zmx Session Name", comment: "Setting title"))
        static let zmxCustomCommand = SettingKey(
            "zmxCustomCommand", default: "", group: .multiplexer, configKey: "zmx-custom-command",
            title: String(localized: "zmx Auto-Start Command", comment: "Setting title"))
        static let zmxSessionDiscovery = SettingKey(
            "zmxSessionDiscoveryEnabled", default: true, group: .multiplexer, configKey: "zmx-session-discovery-enabled",
            title: String(localized: "Discover zmx Sessions", comment: "Setting title"))
        static let localSessionDiscovery = SettingKey(
            "localSessionDiscoveryEnabled", default: true, group: .multiplexer, configKey: "local-session-discovery-enabled",
            title: String(localized: "Discover Local Sessions", comment: "Setting title"))
        static let sessionDiscoverySortOrder = SettingKey(
            "sessionDiscoverySortOrder", default: SessionDiscoverySortOrder.attachedFirst, group: .multiplexer,
            configKey: "session-discovery-sort-order",
            title: String(localized: "Session Sort Order", comment: "Setting title"))
        static let tabExposeMultiplexer = SettingKey(
            "tabExposeMultiplexerEnabled", default: true, group: .multiplexer, configKey: "tab-expose-multiplexer-enabled",
            title: String(localized: "Show Multiplexer Tabs in Exposé", comment: "Setting title"))
        static let tmuxHiddenWindowsBySession = AnySettingDefinition.opaque(
            "tmuxHiddenWindowsBySession", group: .multiplexer,
            title: String(localized: "tmux Hidden Windows", comment: "Setting title"))
        static let tmuxLastSessionByConnection = AnySettingDefinition.opaque(
            "tmuxLastSessionByConnection", group: .multiplexer,
            title: String(localized: "tmux Last Session", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            tmuxSessionName.erased, tmuxCustomCommand.erased, tmuxSessionDiscovery.erased,
            tmuxAutoHideGatewayOnAttach.erased, tmuxDiscoveryAttachMode.erased,
            tmuxTabCloseAction.erased, zellijSessionDiscovery.erased, herdrSessionName.erased,
            herdrCustomCommand.erased, herdrSessionDiscovery.erased,
            zmxSessionName.erased, zmxCustomCommand.erased, zmxSessionDiscovery.erased, localSessionDiscovery.erased,
            sessionDiscoverySortOrder.erased, tabExposeMultiplexer.erased,
            tmuxHiddenWindowsBySession, tmuxLastSessionByConnection,
        ]
    }

    enum SSHAgent {
        static let defaultKeyIDs = SettingKey<Data?>(
            "defaultSSHKeyIDs", default: nil, group: .sshAgent, policy: .deviceOnly,
            title: String(localized: "Default SSH Keys", comment: "Setting title"))
        static let defaultKeyIDLegacy = SettingKey<String?>(
            "defaultSSHKeyID", default: nil, group: .sshAgent, policy: .deviceOnly,
            title: String(localized: "Default SSH Key (legacy)", comment: "Setting title"))
        static let externalAgents = SettingKey<Data?>(
            "externalSSHAgents", default: nil, group: .sshAgent, policy: .deviceOnly,
            title: String(localized: "External SSH Agents", comment: "Setting title"))
        static let localAgentConfig = SettingKey<Data?>(
            "localAgent.config", default: nil, group: .sshAgent, policy: .deviceOnly,
            title: String(localized: "Local SSH Agent", comment: "Setting title"))
        static let localAgentClientRules = SettingKey<Data?>(
            "localAgent.clientRules", default: nil, group: .sshAgent, policy: .deviceOnly,
            title: String(localized: "Local SSH Agent Client Rules", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            defaultKeyIDs.erased, defaultKeyIDLegacy.erased, externalAgents.erased,
            localAgentConfig.erased, localAgentClientRules.erased,
        ]
    }

    enum HostTrust {
        /// Dictionary-valued TOFU store; a sync candidate once it moves to a record type.
        static let trustedVNCCertificateFingerprints = AnySettingDefinition.opaque(
            "trustedVNCCertificateFingerprints", group: .hostTrust,
            title: String(localized: "Trusted Screen Sharing Certificates", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [trustedVNCCertificateFingerprints]
    }

    enum Roam {
        static let predictionMode = SettingKey(
            "roamDefaultPredictionMode", default: MoshConfig.PredictionMode.adaptive, group: .roam,
            configKey: "roam-default-prediction-mode",
            title: String(localized: "Default Prediction Mode", comment: "Setting title"))
        static let predictOverwrite = SettingKey(
            "roamDefaultPredictOverwrite", default: false, group: .roam, configKey: "roam-default-predict-overwrite",
            title: String(localized: "Overwrite Predictions", comment: "Setting title"))
        static let holePunch = SettingKey(
            "roamHolePunchEnabled", default: false, group: .roam, configKey: "roam-hole-punch-enabled",
            title: String(localized: "Enable Hole-Punch", comment: "Setting title"))
        static let moshAltScreen = SettingKey(
            "roamMoshAltScreenEnabled", default: true, group: .roam, configKey: "roam-mosh-alt-screen-enabled",
            title: String(localized: "Use Alternate Screen", comment: "Setting title"))
        static let multipathTCP = SettingKey(
            "roamMultipathTCPEnabled", default: false, group: .roam, configKey: "roam-multipath-tcp-enabled",
            title: String(localized: "Multipath TCP", comment: "Setting title"))
        static let trzszTransportMode = SettingKey(
            "trzszDefaultTransportMode", default: TrzszConfig.TransportMode.kcp, group: .roam,
            configKey: "trzsz-default-transport-mode",
            title: String(localized: "Default Transport", comment: "Setting title"))
        static let trzszUDPPortMin = SettingKey(
            "trzszDefaultUDPPortMin", default: 61000, group: .roam, configKey: "trzsz-default-udp-port-min",
            title: String(localized: "UDP Port Range Min", comment: "Setting title"))
        static let trzszUDPPortMax = SettingKey(
            "trzszDefaultUDPPortMax", default: 61999, group: .roam, configKey: "trzsz-default-udp-port-max",
            title: String(localized: "UDP Port Range Max", comment: "Setting title"))
        static let trzszKeepPendingInput = SettingKey(
            "trzszKeepPendingInput", default: false, group: .roam, configKey: "trzsz-keep-pending-input",
            title: String(localized: "Keep Input While Offline", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            predictionMode.erased, predictOverwrite.erased, holePunch.erased, moshAltScreen.erased, multipathTCP.erased,
            trzszTransportMode.erased, trzszUDPPortMin.erased, trzszUDPPortMax.erased, trzszKeepPendingInput.erased,
        ]
    }

    enum ScreenSharing {
        static let clipboardSyncDefault = SettingKey(
            "screenSharingClipboardSyncDefault", default: ScreenSharingClipboardSyncDefault.automatic, group: .screenSharing,
            configKey: "screen-sharing-clipboard-sync-default",
            title: String(localized: "Default Clipboard Sync", comment: "Setting title"))
        static let panningDefault = SettingKey(
            "screenSharingPanningDefault", default: ScreenSharingPanningDefault.edge, group: .screenSharing,
            configKey: "screen-sharing-panning-default",
            title: String(localized: "Default Panning Mode", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [clipboardSyncDefault.erased, panningDefault.erased]
    }

    enum Transfer {
        static let crocMachineID = SettingKey<String?>(
            "crocMachineID", default: nil, group: .transfer, policy: .deviceOnly,
            title: String(localized: "Croc Machine ID", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [crocMachineID.erased]
    }
}
