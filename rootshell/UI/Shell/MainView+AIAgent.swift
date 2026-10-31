//
//  MainView+AIAgent.swift
//  rootshell
//
//  AI Agent integration and theme picker for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os

#if !CHINA_BUILD
// MARK: - AI Agent Mode Switching

extension MainView {

    /// Handle request to switch AI Agent presentation mode (sidebar <-> window)
    func handleAIAgentModeSwitch(_ request: AIAgentSwitchModeRequest) {
        // Update the global presentation mode setting
        AICredentialsManager.shared.aiAgentPresentationMode = request.targetMode

        switch request.targetMode {
        case .sidebar:
            adoptEdgeSidebarPage(.aiAgent)
            // Switching from window to sidebar - move ALL sessions
            // Get all tab IDs first, then move each to sidebar
            let windowTabIDs = Array(aiAgentWindowState.windowSessions.keys)
            for tabID in windowTabIDs {
                aiAgentSidebarVisibleTabs.insert(tabID)
                aiAgentWindowState.removeSession(tabID: tabID)
            }

            // Close the window
            dismissWindow(id: "ai-agent")

        case .window:
            // Switching from sidebar to window - move the requesting tab
            let tabID = request.tabID
            guard let session = aiAgentSessions[tabID] else { return }

            // 1. Close sidebar
            aiAgentSidebarVisibleTabs.remove(tabID)

            // 2. Add to window state
            aiAgentWindowState.addSession(tabID: tabID, session: session)
            aiAgentWindowState.selectedSessionTabID = tabID

            // 3. Open window
            if !aiAgentWindowState.isWindowOpen {
                openWindow(id: "ai-agent")
            }
        }
    }
}
#endif

// MARK: - Theme Picker

extension MainView {

    func handleThemePickerSelection(_ themeName: String, scope: ThemePickerOverlay.ThemePickerScope) {
        switch scope {
        case .tab:
            if terminals.indices.contains(selectedTabIndex) {
                let tabId = terminals[selectedTabIndex].id
                ThemeOverrideManager.shared.setTabTheme(tabId: tabId, themeName: themeName)
            }
        case .window:
            ThemeOverrideManager.shared.setWindowTheme(windowId: windowId, themeName: themeName)
        case .global:
            ThemeManager.shared.currentTheme = themeName
        }
    }
}

// MARK: - Tab Helpers (non-AI)

extension MainView {

    /// Find the tab ID that owns a given terminal view, or nil if not in any tab.
    func tabID(for terminalView: Ghostty.TerminalView) -> UUID? {
        for tab in terminals {
            if tab.splitTree.contains(where: { $0 === terminalView }) {
                return tab.id
            }
        }
        return nil
    }
}

// MARK: - AI Agent

#if !CHINA_BUILD
extension MainView {

    /// Derive the AI Agent connection type from a terminal's current connection config.
    /// Returns nil for connection types the AI Agent doesn't support (console, kubernetes, etc.).
    func aiAgentConnectionType(for terminal: Ghostty.TerminalView) -> AIAgentConnectionType? {
        switch terminal.connectionConfig.unwrappedConfig {
        case .ssh(let config): return .ssh(config)
        case .mosh(let config): return .ssh(config.sshConfig)
        case .trzsz(let config): return .ssh(config.sshConfig)
        case .local: return .local
        default: return nil
        }
    }

    /// Tear down the AI Agent session for a tab across all presentation modes.
    /// Used on tab close, and when the terminal's connection context changes
    /// (e.g. user SSHes from a local shell) so the next Cmd+I spawns a fresh
    /// session wired to the current shell context.
    func invalidateAIAgentSession(for tabID: UUID) {
        let existing = aiAgentSessions.removeValue(forKey: tabID)
        aiAgentSessionOwnerIDs.removeValue(forKey: tabID)
        aiAgentSidebarVisibleTabs.remove(tabID)
        aiAgentWindowState.removeSession(tabID: tabID)

        // If the sheet is currently showing this tab, dismiss it.
        if usesPinnedWideEdgeSidebarLayout || isPhone,
           showAIAgentOverlay,
           terminals.indices.contains(selectedTabIndex),
           terminals[selectedTabIndex].id == tabID {
            showAIAgentOverlay = false
        }

        if let existing {
            Task { await existing.disconnect() }
        }
    }

    func toggleAIAgent() {
        Ghostty.logger.info("toggleAIAgent called")

        guard terminals.indices.contains(selectedTabIndex) else {
            Ghostty.logger.warning("No valid tab selected")
            return
        }
        guard let focusedTerminal = terminals[selectedTabIndex].focusedTerminal else {
            Ghostty.logger.warning("No focused terminal")
            return
        }

        // Determine the AI Agent connection type and a user-facing label. The
        // type collapses Mosh/Trzsz to .ssh (the executor dials SSH regardless
        // of the terminal's transport), but the label preserves the outer
        // transport's displayName so logs and UI reflect what the user sees.
        let aiConnectionType: AIAgentConnectionType
        let displayName: String
        var localShellCWD: String?

        switch focusedTerminal.connectionConfig.unwrappedConfig {
        case .ssh(let config):
            aiConnectionType = .ssh(config)
            displayName = config.displayName
        case .mosh(let config):
            aiConnectionType = .ssh(config.sshConfig)
            displayName = config.displayName
        case .trzsz(let config):
            aiConnectionType = .ssh(config.sshConfig)
            displayName = config.displayName
        case .local:
            aiConnectionType = .local
            displayName = "Local Shell"
            #if !targetEnvironment(macCatalyst)
            if let localSession = focusedTerminal.session as? LocalShellSession {
                localShellCWD = localSession.sessionCurrentDirectory
            }
            #endif
        default:
            Ghostty.logger.warning("AI Agent only works with SSH or local connections")
            alerts.showAIAgentSSHRequiredAlert = true
            return
        }

        // Get or create session for this terminal
        let terminalId = terminals[selectedTabIndex].id
        let currentOwnerID = ObjectIdentifier(focusedTerminal)

        if let existing = aiAgentSessions[terminalId] {
            // Drop the session if the terminal's shell context has changed
            // (e.g. user SSHed from local shell), so the next create spawns a
            // fresh agent wired to the current shell.
            let typeMismatch = existing.connectionType != aiConnectionType
            // For .local sessions, the executor is rooted in the spawning split's
            // CWD at connect time and doesn't track split focus afterwards. So if
            // the user activates the agent from a different local split than the
            // one that created it, the executor is in the wrong directory — treat
            // that like a context change and recreate. SSH sessions reuse safely
            // across splits because the executor is an independent connection to
            // the remote, unrelated to the terminal's PTY.
            let localSplitChanged: Bool
            if case .local = aiConnectionType,
               let previousOwnerID = aiAgentSessionOwnerIDs[terminalId],
               previousOwnerID != currentOwnerID {
                localSplitChanged = true
            } else {
                localSplitChanged = false
            }

            if typeMismatch || localSplitChanged {
                Ghostty.logger.info("AI Agent context changed, recreating session")
                invalidateAIAgentSession(for: terminalId)
            }
        }

        if aiAgentSessions[terminalId] == nil {
            let session = AIAgentSession(connectionType: aiConnectionType)
            session.initialWorkingDirectory = localShellCWD
            aiAgentSessions[terminalId] = session
        }

        guard let session = aiAgentSessions[terminalId] else { return }

        // Rebind the session to whichever split the user just activated it from,
        // on every toggle — including when reusing an existing session. Without
        // this, an agent created in split A would remain pinned to split A even
        // after the user focuses split B and presses Cmd+I, making invalidation
        // read from the wrong split. For .local the mismatch check above will
        // have already recreated the session; this just keeps the pointer fresh
        // for SSH reuse across splits.
        aiAgentSessionOwnerIDs[terminalId] = currentOwnerID
        session.displayNameOverride = displayName

        #if !targetEnvironment(macCatalyst)
        if case .local = aiConnectionType {
            let terminal = focusedTerminal
            session.workingDirectoryProvider = { [weak terminal] in
                (terminal?.session as? LocalShellSession)?.sessionCurrentDirectory
            }
        } else {
            session.workingDirectoryProvider = nil
        }
        #endif

        if (usesPinnedWideEdgeSidebarLayout || isPhone || AICredentialsManager.shared.aiAgentPresentationMode == .sidebar),
           !edgeSidebarPageIsOpen(.aiAgent) { adoptEdgeSidebarPage(.aiAgent) }

        // Different behavior based on device type
        if usesPinnedWideEdgeSidebarLayout || isPhone {
            // iPhone: use global sheet presentation
            Ghostty.logger.info("Opening AI Agent sheet: \(displayName)")
            showAIAgentOverlay = true
        } else {
            // iPad/Catalyst/visionOS: check presentation mode
            let mode = AICredentialsManager.shared.aiAgentPresentationMode

            switch mode {
            case .sidebar:
                // Sidebar mode: toggle per-tab sidebar visibility
                if aiAgentSidebarVisibleTabs.contains(terminalId) {
                    Ghostty.logger.info("Closing AI Agent sidebar: \(displayName)")
                    aiAgentSidebarVisibleTabs.remove(terminalId)
                    session.cancel()
                } else {
                    Ghostty.logger.info("Opening AI Agent sidebar: \(displayName)")
                    aiAgentSidebarVisibleTabs.insert(terminalId)
                    // Resign focus from terminal so it doesn't swallow keys while sidebar is open
                    focusedTerminal.resignFirstResponder()
                }

            case .window:
                // Window mode: Cmd-I should *not* toggle visibility.
                // It should switch the AI Agent window to the current tab's session,
                // opening the window (and adding the session) if needed.
                if aiAgentWindowState.containsSession(tabID: terminalId) {
                    Ghostty.logger.info("Selecting AI Agent session in window: \(displayName)")
                    aiAgentWindowState.selectedSessionTabID = terminalId
                } else {
                    Ghostty.logger.info("Adding AI Agent session to window: \(displayName)")
                    aiAgentWindowState.addSession(tabID: terminalId, session: session)
                    aiAgentWindowState.selectedSessionTabID = terminalId
                }

                // Open the window if not already open
                if !aiAgentWindowState.isWindowOpen {
                    openWindow(id: "ai-agent")
                }
            }
        }
    }

    func currentAIAgentSession() -> AIAgentSession? {
        guard terminals.indices.contains(selectedTabIndex) else { return nil }
        let terminalId = terminals[selectedTabIndex].id
        return aiAgentSessions[terminalId]
    }
}

// MARK: - Voice Agent

extension MainView {

    func toggleVoiceAgent() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        guard let focusedTerminal = terminals[selectedTabIndex].focusedTerminal else { return }

        let terminalId = terminals[selectedTabIndex].id

        // If already active on this tab, stop it
        if let existing = voiceAgentSessions[terminalId], existing.state.isActive {
            existing.stop()
            voiceAgentSessions.removeValue(forKey: terminalId)
            return
        }

        // Stop any voice agent running on other tabs (hardware VPIO is a singleton)
        let otherKeys = voiceAgentSessions.keys.filter { $0 != terminalId }
        for key in otherKeys {
            voiceAgentSessions[key]?.stop()
            voiceAgentSessions.removeValue(forKey: key)
        }

        // Check for Google API key before creating a session
        let apiKey = AICredentialsManager.shared.loadGoogleAPIKey() ?? ""
        if apiKey.isEmpty {
            alerts.showVoiceAgentAPIKeyAlert = true
            return
        }

        // Determine SSH config and fingerprint if available
        var sshConfig: SSHConfig?
        var fingerprint: HostFingerprint?

        switch focusedTerminal.connectionConfig.unwrappedConfig {
        case .ssh(let config):
            sshConfig = config
        case .mosh(let config):
            sshConfig = config.sshConfig
        case .trzsz(let config):
            sshConfig = config.sshConfig
        default:
            break
        }

        // Check for existing AI agent session to reuse fingerprint
        if let aiSession = aiAgentSessions[terminalId] {
            fingerprint = aiSession.fingerprint
        }

        // Create voice session
        let session = VoiceAgentSession(sshConfig: sshConfig, fingerprint: fingerprint)
        session.terminalView = focusedTerminal

        // Load consultation mode from settings
        session.consultationMode = SettingsStore.shared.get(Settings.AI.voiceConsultationMode)
        session.voiceName = SettingsStore.shared.get(Settings.AI.voice)

        voiceAgentSessions[terminalId] = session

        // Start the session
        Task {
            await session.start()
        }
    }

    func currentVoiceAgentSession() -> VoiceAgentSession? {
        guard terminals.indices.contains(selectedTabIndex) else { return nil }
        let terminalId = terminals[selectedTabIndex].id
        return voiceAgentSessions[terminalId]
    }
}
#endif
