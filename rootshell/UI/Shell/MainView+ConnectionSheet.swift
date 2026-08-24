//
//  MainView+ConnectionSheet.swift
//  rootshell
//
//  Connection sheet content and per-protocol connect dispatch for MainView.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Connection Sheet Content
    
    /// iPhone variant: no onClose (shows "Cancel", uses dismiss()), initialTab for starting tab
    @ViewBuilder
    var connectionSheetContentForPhone: some View {
        SSHConnectionView(
            initialConfig: reconnectConfig,
            initialBrowseSelection: pendingBrowseSelection,
            onConnect: { (config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleSSHOrLocalConnection(config: config, splitOption: splitOption)
            },
            onMoshConnect: { (moshConfig: MoshConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleMoshConnection(config: moshConfig, splitOption: splitOption)
            },
            onTrzszConnect: { (trzszConfig: TrzszConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleTrzszConnection(config: trzszConfig, splitOption: splitOption)
            },
            onVNCConnect: { (vncConfig: VNCConnectionConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleVNCConnection(config: vncConfig, splitOption: splitOption)
            },
            onKubernetesConnect: { (k8sConfig: KubernetesNodeShellConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleKubernetesConnection(config: k8sConfig, splitOption: splitOption)
            },
            onConsoleConnect: { (consoleConfig: ConsoleConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleConsoleConnection(config: consoleConfig, splitOption: splitOption)
            },
            onEC2ConsoleConnect: { (ec2Config: EC2ConsoleConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil
                handleEC2ConsoleConnection(config: ec2Config, splitOption: splitOption)
            },
            onProfileConnect: { profile, splitOption in
                showConnectionSidebar = false
                connectToProfile(profile, splitOption: splitOption)
            },
            preventDismissal: terminals.isEmpty && tabBarHidden,
            initialTab: connectionSidebarInitialTab
        )
    }

    /// iPad/Catalyst/visionOS variant: onClose set (shows "Done"), initialTab for starting tab
    @ViewBuilder
    var connectionSheetContent: some View {
        SSHConnectionView(
            initialConfig: reconnectConfig,
            initialBrowseSelection: pendingBrowseSelection,
            onConnect: { (config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleSSHOrLocalConnection(config: config, splitOption: splitOption)
            },
            onMoshConnect: { (moshConfig: MoshConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleMoshConnection(config: moshConfig, splitOption: splitOption)
            },
            onTrzszConnect: { (trzszConfig: TrzszConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleTrzszConnection(config: trzszConfig, splitOption: splitOption)
            },
            onVNCConnect: { (vncConfig: VNCConnectionConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleVNCConnection(config: vncConfig, splitOption: splitOption)
            },
            onKubernetesConnect: { (k8sConfig: KubernetesNodeShellConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleKubernetesConnection(config: k8sConfig, splitOption: splitOption)
            },
            onConsoleConnect: { (consoleConfig: ConsoleConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleConsoleConnection(config: consoleConfig, splitOption: splitOption)
            },
            onEC2ConsoleConnect: { (ec2Config: EC2ConsoleConfig, splitOption: SSHConnectionView.SplitOption) in
                pendingBrowseSelection = nil  // Clear after use
                handleEC2ConsoleConnection(config: ec2Config, splitOption: splitOption)
            },
            onProfileConnect: { profile, splitOption in
                showConnectionSidebar = false
                connectToProfile(profile, splitOption: splitOption)
            },
            preventDismissal: terminals.isEmpty && tabBarHidden,
            onClose: { showConnectionSidebar = false },
            initialTab: connectionSidebarInitialTab
        )
    }
    
    private func handleSSHOrLocalConnection(config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) {
        if let config = config {
            // SSH connection
            if let tabIndex = reconnectingTabIndex {
                // Reconnecting existing tab
                reconnectTab(at: tabIndex, with: config)
            } else {
                // Creating new connection - check split option
                switch splitOption {
                case .newTab:
                    createSSHTab(with: config)
                case .splitRight:
                    createSSHSplit(with: config, direction: .right)
                case .splitDown:
                    createSSHSplit(with: config, direction: .down)
                }
            }
        } else {
            // Local shell
            switch splitOption {
            case .newTab:
                createLocalShellTab()
            case .splitRight:
                createLocalShellSplit(direction: .right)
            case .splitDown:
                createLocalShellSplit(direction: .down)
            }
        }
        // Clear reconnection state
        reconnectingTabIndex = nil
        reconnectConfig = nil
    }

    private func handleMoshConnection(config: MoshConfig, splitOption: SSHConnectionView.SplitOption) {
        switch splitOption {
        case .newTab:
            createMoshTab(with: config)
        case .splitRight:
            createMoshSplit(with: config, direction: .right)
        case .splitDown:
            createMoshSplit(with: config, direction: .down)
        }
    }

    private func handleTrzszConnection(config: TrzszConfig, splitOption: SSHConnectionView.SplitOption) {
        switch splitOption {
        case .newTab:
            createTrzszTab(with: config)
        case .splitRight:
            createTrzszSplit(with: config, direction: .right)
        case .splitDown:
            createTrzszSplit(with: config, direction: .down)
        }
    }

    /// Route a Screen Sharing connect to the VNC pane creators. `password`
    /// is a one-shot handoff from a profile password prompt.
    private func handleVNCConnection(
        config: VNCConnectionConfig,
        splitOption: SSHConnectionView.SplitOption,
        sourceProfileID: UUID? = nil,
        password: String? = nil
    ) {
        let network = NetworkReachabilityMonitor.shared
        let supportsHighPerformance = network.isConnected
            && (network.connectionType == .wifi || network.connectionType == .wired)

        if config.quality == .adaptive,
           !supportsHighPerformance || config.usesMeshVPNHostname {
            alerts.handleVNCHighPerformanceTransportWarning(
                MainAlertController.PendingVNCHighPerformanceConnection(
                    config: config,
                    splitOption: splitOption,
                    sourceProfileID: sourceProfileID,
                    password: password
                )
            )
            return
        }

        performVNCConnection(
            config: config,
            splitOption: splitOption,
            sourceProfileID: sourceProfileID,
            password: password
        )
    }

    /// Create a Screen Sharing pane after any user-initiated transport
    /// warning has been resolved. Window restoration deliberately calls the
    /// lower-level pane factory directly and therefore remains non-blocking.
    func performVNCConnection(
        config: VNCConnectionConfig,
        splitOption: SSHConnectionView.SplitOption,
        sourceProfileID: UUID? = nil,
        password: String? = nil
    ) {
        switch splitOption {
        case .newTab:
            createVNCTab(with: config, sourceProfileID: sourceProfileID, password: password)
        case .splitRight:
            createVNCSplit(with: config, direction: .right, sourceProfileID: sourceProfileID, password: password)
        case .splitDown:
            createVNCSplit(with: config, direction: .down, sourceProfileID: sourceProfileID, password: password)
        }
    }

    private func handleKubernetesConnection(config: KubernetesNodeShellConfig, splitOption: SSHConnectionView.SplitOption) {
        switch splitOption {
        case .newTab:
            createKubernetesNodeShellTab(with: config)
        case .splitRight:
            createKubernetesNodeShellSplit(with: config, direction: .right)
        case .splitDown:
            createKubernetesNodeShellSplit(with: config, direction: .down)
        }
    }
    
    private func handleConsoleConnection(config: ConsoleConfig, splitOption: SSHConnectionView.SplitOption) {
        switch splitOption {
        case .newTab:
            createConsoleTab(with: config)
        case .splitRight:
            createConsoleSplit(with: config, direction: .right)
        case .splitDown:
            createConsoleSplit(with: config, direction: .down)
        }
    }
    
    private func handleEC2ConsoleConnection(config: EC2ConsoleConfig, splitOption: SSHConnectionView.SplitOption) {
        switch splitOption {
        case .newTab:
            createEC2ConsoleTab(with: config)
        case .splitRight:
            createEC2ConsoleSplit(with: config, direction: .right)
        case .splitDown:
            createEC2ConsoleSplit(with: config, direction: .down)
        }
    }

    func connectToProfile(_ profile: ConnectionProfile, splitOption: SSHConnectionView.SplitOption) {
        // Record usage
        ConnectionProfileManager.shared.recordUsage(id: profile.id)

        // Screen Sharing profiles route to the VNC pane path — their
        // sshConfig is a display-only placeholder, never connectable.
        if profile.connectionProtocol == .vnc {
            connectToVNCProfile(profile, splitOption: splitOption)
            return
        }

        var config = profile.sshConfig
        let connectionProtocol = profile.connectionProtocol

        let transportMode = profile.trzszTransportMode
        let profileMTU = profile.trzszMTU
        let profilePortMin = profile.trzszPortMin
        let profilePortMax = profile.trzszPortMax
        let profileServerPath = profile.trzszServerPath

        // Pre-flight key resolution for synced profiles
        let resolution = ConnectionKeyResolver.resolve(config: config, profileID: profile.id)
        switch resolution {
        case .resolved(let resolvedConfig):
            config = resolvedConfig
        case .unresolved(let partialConfig, let unresolvedKeys):
            // Show key resolution sheet
            keyResolutionConfig = partialConfig
            keyResolutionUnresolvedKeys = unresolvedKeys
            keyResolutionProfileID = profile.id
            keyResolutionConnectionIdentity = nil
            keyResolutionProtocol = connectionProtocol
            keyResolutionTransportMode = transportMode
            keyResolutionTrzszMTU = profileMTU
            keyResolutionTrzszPortMin = profilePortMin
            keyResolutionTrzszPortMax = profilePortMax
            keyResolutionTrzszServerPath = profileServerPath
            keyResolutionSplitOption = splitOption
            showKeyResolutionSheet = true
            return
        }

        // Check auth method
        switch config.authMethod {
        case .savedPassword:
            // Has saved password - load and connect directly
            Task { @MainActor in
                do {
                    let resolvedConfig = try await config.resolvedConfig()
                    connectWithConfig(resolvedConfig, connectionProtocol: connectionProtocol, splitOption: splitOption, trzszTransportMode: transportMode, trzszMTU: profileMTU, trzszPortMin: profilePortMin, trzszPortMax: profilePortMax, trzszServerPath: profileServerPath, sourceProfileID: profile.id)
                } catch SSHPasswordManager.PasswordError.authenticationCancelled {
                    // User cancelled biometric - do nothing
                } catch {
                    // Password load failed (e.g., deleted) - show password prompt
                    passwordPromptProfile = profile
                    passwordPromptSplitOption = splitOption
                    showPasswordPromptSheet = true
                }
            }

        case .password(let pwd) where !pwd.isEmpty:
            // Has inline password - connect directly
            connectWithConfig(config, connectionProtocol: connectionProtocol, splitOption: splitOption, trzszTransportMode: transportMode, trzszMTU: profileMTU, trzszPortMin: profilePortMin, trzszPortMax: profilePortMax, trzszServerPath: profileServerPath, sourceProfileID: profile.id)

        case .password:
            // Password auth but no password yet - try saved password if available
            if SSHPasswordManager.shared.hasPassword(host: config.host, port: config.port, username: config.username) {
                Task { @MainActor in
                    var savedConfig = config
                    savedConfig.authMethod = .savedPassword
                    do {
                        let resolvedConfig = try await savedConfig.resolvedConfig()
                        connectWithConfig(resolvedConfig, connectionProtocol: connectionProtocol, splitOption: splitOption, trzszTransportMode: transportMode, trzszMTU: profileMTU, trzszPortMin: profilePortMin, trzszPortMax: profilePortMax, trzszServerPath: profileServerPath, sourceProfileID: profile.id)
                    } catch SSHPasswordManager.PasswordError.authenticationCancelled {
                        // User cancelled biometric - do nothing
                    } catch {
                        // Password load failed (e.g., deleted) - show password prompt
                        passwordPromptProfile = profile
                        passwordPromptSplitOption = splitOption
                        showPasswordPromptSheet = true
                    }
                }
            } else {
                // No saved password - show password prompt sheet
                passwordPromptProfile = profile
                passwordPromptSplitOption = splitOption
                showPasswordPromptSheet = true
            }

        case .key, .none, .keyboardInteractive, .unknown:
            // Key / no-auth / keyboard-interactive connect directly (the
            // keyboard-interactive UI handles any prompts). An `.unknown` method
            // falls through here and surfaces the "unsupported" error on connect.
            connectWithConfig(config, connectionProtocol: connectionProtocol, splitOption: splitOption, trzszTransportMode: transportMode, trzszMTU: profileMTU, trzszPortMin: profilePortMin, trzszPortMax: profilePortMax, trzszServerPath: profileServerPath, sourceProfileID: profile.id)
        }
    }

    /// Screen Sharing profile connect: Keychain hit (or no-security) connects
    /// directly; a miss routes through the shared profile password prompt,
    /// whose submit path branches for VNC in `handlePasswordSubmit`.
    func connectToVNCProfile(_ profile: ConnectionProfile, splitOption: SSHConnectionView.SplitOption) {
        guard let vncConfig = profile.vncConfig else {
            // Materialized without a decodable extension envelope (e.g.
            // synced from a newer build) — nothing to connect with.
            Ghostty.logger.warning("VNC profile has no Screen Sharing configuration - showing alert")
            alerts.showVNCProfileInvalidAlert = true
            return
        }

        if vncConfig.security == .none || VNCPasswordManager.shared.hasPassword(for: vncConfig) {
            handleVNCConnection(config: vncConfig, splitOption: splitOption, sourceProfileID: profile.id)
        } else {
            passwordPromptProfile = profile
            passwordPromptSplitOption = splitOption
            showPasswordPromptSheet = true
        }
    }

    func handleProfileIntent(_ request: ProfileIntentRequest) {
        guard var profile = ConnectionProfileManager.shared.profile(for: request.profileID) else {
            return
        }

        if showConnectionSidebar {
            showConnectionSidebar = false
        }

        if let override = request.launchCommandOverride {
            profile.sshConfig.launchCommand = override
        }

        connectToProfile(profile, splitOption: .newTab)
    }

    #if !CHINA_BUILD
    func handleVPNIntent() {
        // VPN intent notifications are global; with multiple windows only
        // the key window should open Settings > VPN. Device scenes only.
        guard !isExternalDisplayWindow else { return }
        let windowScenes = UIApplication.shared.deviceWindowScenes
        if windowScenes.count > 1 && !windowIsKeyWindow {
            return
        }
        requestSettingsPresentation(destination: .vpn)
    }
    #endif

    func connectWithConfig(_ config: SSHConfig, connectionProtocol: ConnectionProtocol = .ssh, splitOption: SSHConnectionView.SplitOption, trzszTransportMode: ProfileTransportMode = .default, trzszMTU: Int? = nil, trzszPortMin: Int? = nil, trzszPortMax: Int? = nil, trzszServerPath: String? = nil, sourceProfileID: UUID? = nil) {
        // Safety net: verify key is still resolvable before creating session
        if case .key(let keyID) = config.authMethod, SSHKeyManager.shared.findKey(id: keyID) == nil {
            let resolution = ConnectionKeyResolver.resolve(config: config)
            switch resolution {
            case .resolved(let resolvedConfig):
                // Re-enter with resolved config
                connectWithConfig(resolvedConfig, connectionProtocol: connectionProtocol, splitOption: splitOption, trzszTransportMode: trzszTransportMode, trzszMTU: trzszMTU, trzszPortMin: trzszPortMin, trzszPortMax: trzszPortMax, trzszServerPath: trzszServerPath, sourceProfileID: sourceProfileID)
                return
            case .unresolved(let partialConfig, let unresolvedKeys):
                keyResolutionConfig = partialConfig
                keyResolutionUnresolvedKeys = unresolvedKeys
                keyResolutionProfileID = nil
                keyResolutionConnectionIdentity = nil
                keyResolutionProtocol = connectionProtocol
                keyResolutionTransportMode = trzszTransportMode
                keyResolutionTrzszMTU = trzszMTU
                keyResolutionTrzszPortMin = trzszPortMin
                keyResolutionTrzszPortMax = trzszPortMax
                keyResolutionTrzszServerPath = trzszServerPath
                keyResolutionSplitOption = splitOption
                showKeyResolutionSheet = true
                return
            }
        }

        switch connectionProtocol {
        case .mosh:
            // Create Mosh connection
            let moshConfig = MoshConfig(sshConfig: config)
            switch splitOption {
            case .newTab:
                createMoshTab(with: moshConfig, sourceProfileID: sourceProfileID)
            case .splitRight:
                createMoshSplit(with: moshConfig, direction: .right, sourceProfileID: sourceProfileID)
            case .splitDown:
                createMoshSplit(with: moshConfig, direction: .down, sourceProfileID: sourceProfileID)
            }
        case .trzsz:
            // Create Trzsz connection with profile overrides
            let trzszConfig = TrzszConfig(
                sshConfig: config,
                transportMode: trzszTransportMode.resolved,
                udpPortMin: trzszPortMin ?? TrzszConfig.preferredUDPPortMin,
                udpPortMax: trzszPortMax ?? TrzszConfig.preferredUDPPortMax,
                serverPath: trzszServerPath,
                mtu: trzszMTU ?? 0
            )
            switch splitOption {
            case .newTab:
                createTrzszTab(with: trzszConfig, sourceProfileID: sourceProfileID)
            case .splitRight:
                createTrzszSplit(with: trzszConfig, direction: .right, sourceProfileID: sourceProfileID)
            case .splitDown:
                createTrzszSplit(with: trzszConfig, direction: .down, sourceProfileID: sourceProfileID)
            }
        case .ssh:
            // Create SSH connection
            switch splitOption {
            case .newTab:
                createSSHTab(with: config, sourceProfileID: sourceProfileID)
            case .splitRight:
                createSSHSplit(with: config, direction: .right, sourceProfileID: sourceProfileID)
            case .splitDown:
                createSSHSplit(with: config, direction: .down, sourceProfileID: sourceProfileID)
            }
        case .vnc:
            // VNC doesn't ride an SSHConfig; recover the profile's real
            // Screen Sharing config when a generic path lands here.
            if let sourceProfileID,
               let profile = ConnectionProfileManager.shared.profile(for: sourceProfileID) {
                connectToVNCProfile(profile, splitOption: splitOption)
            } else {
                Ghostty.logger.warning("connectWithConfig called for a VNC profile without a source profile - ignoring")
            }
        }
    }

    func handlePasswordSubmit(profile: ConnectionProfile, password: String, shouldSave: Bool) {
        showPasswordPromptSheet = false
        passwordPromptProfile = nil

        // Screen Sharing profiles: persist to the VNC Keychain slot when
        // requested and hand the typed password straight to the new pane.
        if profile.connectionProtocol == .vnc {
            guard let vncConfig = profile.vncConfig else { return }
            if shouldSave {
                try? VNCPasswordManager.shared.savePassword(password, for: vncConfig)
            }
            handleVNCConnection(
                config: vncConfig,
                splitOption: passwordPromptSplitOption,
                sourceProfileID: profile.id,
                password: password
            )
            return
        }

        var config = profile.sshConfig
        let connectionProtocol = profile.connectionProtocol

        // Optionally save password for future connections
        var savedSuccessfully = false
        if shouldSave {
            do {
                try SSHPasswordManager.shared.savePassword(
                    password,
                    host: config.host,
                    port: config.port,
                    username: config.username
                )
                savedSuccessfully = true
            } catch {
                savedSuccessfully = false
            }
        }

        // Update profile auth method to reflect saved password preference
        var updatedProfile = profile
        updatedProfile.sshConfig.authMethod = savedSuccessfully ? .savedPassword : .password("")
        try? ConnectionProfileManager.shared.updateProfile(updatedProfile)

        // Set password on config for this connection
        config.authMethod = .password(password)

        // Connect with the resolved config
        connectWithConfig(config, connectionProtocol: connectionProtocol, splitOption: passwordPromptSplitOption, trzszTransportMode: profile.trzszTransportMode, trzszMTU: profile.trzszMTU, trzszPortMin: profile.trzszPortMin, trzszPortMax: profile.trzszPortMax, trzszServerPath: profile.trzszServerPath, sourceProfileID: profile.id)
    }
}
