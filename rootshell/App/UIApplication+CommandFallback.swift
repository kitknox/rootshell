//
//  UIApplication+CommandFallback.swift
//  rootshell
//
//  Fallback command routing when TerminalView is not in the responder chain
//  (e.g., when all tabs are closed on iPad or Mac Catalyst)
//

import UIKit

/// App shortcuts whose destination can switch while a VNC pane is focused.
/// A notification marker lets MainView route the chord exclusively to VNC;
/// otherwise rootshell performs its normal action.
enum VNCReservedKeyboardShortcut: String, Sendable {
    case toggleTabSwitcher
    case openSettings
    case previousTab
    case nextTab

    static let notificationUserInfoKey = "vncReservedKeyboardShortcut"

    /// Only the four physical default chords can be routed to VNC. If the user
    /// remaps one of these app actions, the custom shortcut remains app-only.
    var notificationSender: Any? {
        guard KeybindManager.shared.sequence(for: action) == expectedSequence else { return nil }
        return self
    }

    private var action: KeybindAction {
        switch self {
        case .toggleTabSwitcher: .toggle_tab_switcher
        case .openSettings: .open_settings
        case .previousTab: .previous_tab
        case .nextTab: .next_tab
        }
    }

    private var expectedSequence: KeySequence {
        switch self {
        case .toggleTabSwitcher:
            KeySequence(key: .backslash, modifiers: [.command, .shift])
        case .openSettings:
            KeySequence(key: .comma, modifiers: [.command])
        case .previousTab:
            KeySequence(key: .leftBrace, modifiers: [.command])
        case .nextTab:
            KeySequence(key: .rightBrace, modifiers: [.command])
        }
    }
}

extension UIApplication {

    @MainActor
    private func ghostty_postNotification(_ name: Notification.Name, userInfo: [String: Any] = [:]) {
        var info = userInfo
        if let sceneID = ghostty_activeWindowSceneSessionID() {
            info[GhosttyCommandRouting.windowSceneSessionIDKey] = sceneID
        }
        #if !targetEnvironment(macCatalyst)
        // Untargeted commands follow typing focus to the external MainView,
        // which shares the device scene session.
        if ExternalDisplayManager.shared.isExternalSessionActive,
           ExternalDisplayManager.shared.focusTarget == .external {
            info[GhosttyCommandRouting.windowIdKey] = ExternalDisplay.windowId
        }
        #endif
        NotificationCenter.default.post(name: name, object: nil, userInfo: info.isEmpty ? nil : info)
    }

    @MainActor
    private func ghostty_activeWindowSceneSessionID() -> String? {
        let scenes = deviceWindowScenes
        if let activeSceneId = WindowFocusRegistry.shared.activeSceneSessionId() {
            if scenes.contains(where: { $0.session.persistentIdentifier == activeSceneId }) {
                return activeSceneId
            } else {
                WindowFocusRegistry.shared.remove(sceneSessionId: activeSceneId)
            }
        }
        if let keyScene = scenes.first(where: { scene in
            scene.windows.contains { $0.isKeyWindow }
        }) {
            return keyScene.session.persistentIdentifier
        }
        return scenes.first { scene in
            scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }?.session.persistentIdentifier
    }

    // MARK: - Menu Actions (SwiftUI Commands)

    @objc func menuCreateLocalShell(_ sender: Any?) {
        ghostty_postNotification(.createLocalShell)
    }

    @objc func menuNewTab(_ sender: Any?) {
        ghostty_postNotification(.newTab)
    }

    @objc func menuNewWindow(_ sender: Any?) {
        ghostty_postNotification(.newWindow)
    }

    @objc func menuDuplicateTabWithSSH(_ sender: Any?) {
        ghostty_postNotification(.duplicateTabWithSSH)
    }

    @objc func menuSplitRight(_ sender: Any?) {
        ghostty_postNotification(.createSplit, userInfo: ["direction": "right"])
    }

    @objc func menuSplitDown(_ sender: Any?) {
        ghostty_postNotification(.createSplit, userInfo: ["direction": "down"])
    }

    @objc func menuNavigateSplitLeft(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "left"])
    }

    @objc func menuNavigateSplitRight(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "right"])
    }

    @objc func menuNavigateSplitUp(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "up"])
    }

    @objc func menuNavigateSplitDown(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "down"])
    }

    @objc func menuCloseSplit(_ sender: Any?) {
        ghostty_postNotification(.closeSplit)
    }

    @objc func menuToggleSplitZoom(_ sender: Any?) {
        ghostty_postNotification(.toggleSplitZoom)
    }

    @objc func menuEqualizeSplits(_ sender: Any?) {
        ghostty_postNotification(.equalizeSplits)
    }

    @objc func menuOpenSettings(_ sender: Any?) {
        ghostty_postNotification(
            .openSettings,
            userInfo: reservedVNCShortcutUserInfo(from: sender)
        )
    }

    @objc func menuBrowseHosts(_ sender: Any?) {
        ghostty_postNotification(.browseHosts)
    }

    @objc func menuBrowseProfiles(_ sender: Any?) {
        ghostty_postNotification(.browseProfiles)
    }

    @objc func menuToggleAIAgent(_ sender: Any?) {
        ghostty_postNotification(.toggleAIAgent)
    }

    @objc func menuToggleVoiceAgent(_ sender: Any?) {
        ghostty_postNotification(.toggleVoiceAgent)
    }

    @objc func menuToggleTabBar(_ sender: Any?) {
        ghostty_postNotification(.toggleTabBar)
    }

    @objc func menuToggleGroupMode(_ sender: Any?) {
        ghostty_postNotification(.toggleGroupMode)
    }

    @objc func menuToggleTabExpose(_ sender: Any?) {
        ghostty_postNotification(.toggleTabExpose)
    }

    @objc func menuPreviousGroup(_ sender: Any?) {
        ghostty_postNotification(.previousGroup)
    }

    @objc func menuNextGroup(_ sender: Any?) {
        ghostty_postNotification(.nextGroup)
    }

    @objc func menuToggleTabSwitcher(_ sender: Any?) {
        // Critical for the tab sidebar's toggle-to-dismiss: presenting the
        // sidebar resigns the terminal's first responder, so the terminal's
        // own UIKeyCommand/menu handler is out of the responder chain for
        // the second press; sendAction(to: nil) lands here instead.
        ghostty_postNotification(
            .showTabSwitcher,
            userInfo: reservedVNCShortcutUserInfo(from: sender)
        )
    }

    @objc func menuToggleTransparency(_ sender: Any?) {
        ghostty_postNotification(.toggleTransparency)
    }

    @objc func menuToggleTitleBar(_ sender: Any?) {
        ghostty_postNotification(.toggleTitleBar)
    }

    @objc func menuToggleAutoRedact(_ sender: Any?) {
        ghostty_postNotification(.toggleAutoRedact)
    }

    @objc func menuToggleClipboardManager(_ sender: Any?) {
        ghostty_postNotification(.toggleClipboardManager)
    }

    @objc func menuToggleBackgroundEffect(_ sender: Any?) {
        ghostty_postNotification(.toggleBackgroundEffect)
    }

    /// Responder-chain fallback for the Brightness Boost command. A focused
    /// terminal consumes the same selector itself; VNC's SwiftUI-hosted input
    /// responder falls through here so MainView can target its focused pane.
    @objc func menuBrightnessBoost(_ sender: Any?) {
        ghostty_postNotification(.toggleBrightnessBoostHUD)
    }

    @objc func menuPreviousTab(_ sender: Any?) {
        ghostty_postNotification(
            .previousTab,
            userInfo: reservedVNCShortcutUserInfo(from: sender)
        )
    }

    @objc func menuNextTab(_ sender: Any?) {
        ghostty_postNotification(
            .nextTab,
            userInfo: reservedVNCShortcutUserInfo(from: sender)
        )
    }

    private func reservedVNCShortcutUserInfo(from sender: Any?) -> [String: Any] {
        guard let shortcut = sender as? VNCReservedKeyboardShortcut else { return [:] }
        return [VNCReservedKeyboardShortcut.notificationUserInfoKey: shortcut.rawValue]
    }

    @objc func menuShowTmuxSessions(_ sender: Any?) {
        ghostty_postNotification(.showTmuxSessions)
    }

    @objc func menuDetachOtherClients(_ sender: Any?) {
        ghostty_postNotification(.detachOtherClients)
    }

    @objc func menuSelectTab1(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 1])
    }

    @objc func menuSelectTab2(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 2])
    }

    @objc func menuSelectTab3(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 3])
    }

    @objc func menuSelectTab4(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 4])
    }

    @objc func menuSelectTab5(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 5])
    }

    @objc func menuSelectTab6(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 6])
    }

    @objc func menuSelectTab7(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 7])
    }

    @objc func menuSelectTab8(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 8])
    }

    @objc func menuSelectTab9(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 9])
    }

    // MARK: - Non-Menu Commands

    @objc func increaseFontSize(_ sender: Any?) {
        ghostty_postNotification(.increaseFontSize)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        ghostty_postNotification(.decreaseFontSize)
    }

    @objc func resetFontSizeToDefault(_ sender: Any?) {
        ghostty_postNotification(.resetFontSize)
    }

    @objc func findInTerminal(_ sender: Any?) {
        ghostty_postNotification(.startSearch)
    }
}
