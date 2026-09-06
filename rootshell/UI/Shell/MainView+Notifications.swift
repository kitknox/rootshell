//
//  MainView+Notifications.swift
//  rootshell
//
//  Notification observers for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Observer Token Bag

/// Holds the opaque tokens returned by NotificationCenter's block-based
/// `addObserver(forName:object:queue:using:)` API so they can be removed on
/// view teardown. Previous code dropped those tokens and called
/// `NotificationCenter.default.removeObserver(self)` from `handleOnDisappear`,
/// which only matches the legacy selector-based API path — block-based
/// observers leaked. iPhone backgrounding evicts the scene UI aggressively;
/// each `onAppear`/`onDisappear` cycle stacked another full set of 32
/// observers without removing the previous set, so notifications fired N
/// times against captured-but-disconnected `MainView` state. Symptom: after
/// a few background bounces, taps and other commands appeared to do nothing
/// (they were running on torn-down `@State` storage).
final class MainViewObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func track(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let toRemove = tokens
        tokens.removeAll()
        lock.unlock()
        let center = NotificationCenter.default
        for token in toRemove {
            center.removeObserver(token)
        }
    }

    deinit {
        // Safety net: NotificationCenter retains the closure (and thus any
        // captured state) until the token is removed. Always remove on dealloc
        // even if `removeAll()` was already called (idempotent).
        lock.lock()
        let toRemove = tokens
        tokens.removeAll()
        lock.unlock()
        let center = NotificationCenter.default
        for token in toRemove {
            center.removeObserver(token)
        }
    }

    /// Convenience wrapper around `NotificationCenter.default.addObserver(forName:...)`
    /// that records the returned token for later removal. The bag always
    /// removes from `.default` on cleanup, so we don't accept an alternate
    /// center — that would silently leak.
    func observe(
        _ name: Notification.Name,
        queue: OperationQueue? = .main,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        track(NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue, using: block))
    }

    func observeOnMainActor(
        _ name: Notification.Name,
        using block: @escaping @MainActor @Sendable (Notification) -> Void
    ) {
        observe(name, queue: .main) { notification in
            MainActor.assumeIsolated {
                block(notification)
            }
        }
    }
}

// MARK: - Notification Observers

extension MainView {
    /// Open Settings. The companion close is just `showSettings = false`; both
    /// drive the binding-based `SidePanelOverlay` directly, so there is no gate
    /// and no deferred flip — the toggle is instant, like the tab sidebar.
    func requestSettingsPresentation(destination: SettingsDestination? = nil) {
        if showConnectionSidebar {
            showConnectionSidebar = false
        }

        guard !showSettings else { return }
        if let destination {
            settingsDestination = destination
        }

        // The FLOATING tab sidebar is an overlay that can't coexist with the
        // settings overlay; hide it. The DOCKED sidebar is inline layout (a
        // left column) and sits fine beside it — keep it.
        if showingTabSwitcher && !tabSidebarIsDocked {
            showingTabSwitcher = false
        }
        showSettings = true
    }

    func setupNotificationObservers() {
        // Idempotent: SwiftUI does not guarantee `onAppear` fires only once
        // per live view identity (e.g., back-to-back transitions can re-fire
        // it without an intervening `onDisappear`). Drain the bag before
        // re-registering so a second call doesn't double up handlers.
        observerBag.removeAll()

        #if !targetEnvironment(macCatalyst)
        observerBag.observeOnMainActor(UIScene.didDisconnectNotification) { [self] notification in
            self.handleSceneDisconnectNotification(notification)
        }
        #endif

        observerBag.observeOnMainActor(.createSplit) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            let splitDirection: SplitTree<SplitPaneView>.NewDirection
            switch direction {
            case "left": splitDirection = .left
            case "right": splitDirection = .right
            case "up": splitDirection = .up
            case "down": splitDirection = .down
            default: return
            }
            self.createSplit(direction: splitDirection)
        }

        observerBag.observeOnMainActor(.navigateSplit) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            let focusDirection: SplitTree<SplitPaneView>.FocusDirection
            switch direction {
            case "left": focusDirection = .spatial(.left)
            case "right": focusDirection = .spatial(.right)
            case "up": focusDirection = .spatial(.up)
            case "down": focusDirection = .spatial(.down)
            default: return
            }
            self.navigateSplit(direction: focusDirection)
        }

        observerBag.observeOnMainActor(.closeSplit) { [self] notification in
            Ghostty.logger.info("closeSplit notification received by window \(self.windowId)")
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else {
                Ghostty.logger.info("closeSplit: notification doesn't belong to this window")
                return
            }

            // Route by the posted pane when present so async session-end
            // events close the dying tab, not whichever tab the user has since
            // switched to. nil object → fall back to the focused split.
            let target = notification.object as? SplitPaneView
            self.closeSplit(targeting: target)
        }

        observerBag.observeOnMainActor(.vncToggleFullScreen) { [self] notification in
            guard let pane = notification.object as? VNCPaneView else { return }
            guard self.shouldHandleNotification(notification) else { return }
            self.toggleVNCFullScreen(for: pane)
        }

        observerBag.observeOnMainActor(.vncEnterFullScreen) { [self] notification in
            guard let pane = notification.object as? VNCPaneView else { return }
            guard self.shouldHandleNotification(notification) else { return }
            self.automaticallyEnterVNCFullScreen(for: pane)
        }

        observerBag.observeOnMainActor(.vncShowConnectionInfo) { [self] notification in
            guard let pane = notification.object as? VNCPaneView else { return }
            guard self.shouldHandleNotification(notification) else { return }
            if let info = pane.connectionInfo {
                self.connectionInfoToShow = info
            }
        }

        observerBag.observeOnMainActor(.toggleSplitZoom) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.toggleSplitZoom()
        }

        observerBag.observeOnMainActor(.equalizeSplits) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.equalizeSplits()
        }

        observerBag.observeOnMainActor(.focusSplit) { [self] notification in
            guard let paneView = notification.object as? SplitPaneView else { return }
            guard terminals.indices.contains(selectedTabIndex) else { return }

            // Update focused pane if it belongs to current tab
            if terminals[selectedTabIndex].splitTree.contains(paneView) {
                // Pointer intent: a tap on the terminal while the clipboard HUD
                // is in keyboard mode returns it to passthrough, so the
                // overlay-owns-keyboard gate drops and the terminal can reclaim
                // the keyboard (mirrors the row-tap → detail-view drop in
                // ClipboardManagerOverlay).
                if clipboardManagerKeyboardMode {
                    clipboardManagerKeyboardMode = false
                }
                setFocusedPane(paneView, inTab: selectedTabIndex)
            }
        }

        // Tab management observers
        observerBag.observeOnMainActor(.newTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }

            self.addNewTab()
        }

        observerBag.observeOnMainActor(.newWindow) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }

            Ghostty.logger.info("newWindow: opening new window from window \(self.windowId)")
            #if targetEnvironment(macCatalyst)
            // Use requestSceneSessionActivation to ensure our scene delegate is used
            // This allows us to set the initial window size properly
            UIApplication.shared.requestSceneSessionActivation(
                nil,
                userActivity: nil,
                options: nil,
                errorHandler: { error in
                    Ghostty.logger.error("Failed to create new window: \(error.localizedDescription)")
                }
            )
            #else
            self.openWindow(id: "main-terminal")
            #endif
        }

        observerBag.observeOnMainActor(.previousTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.routeReservedVNCKeyboardShortcut(from: notification) { return }
            self.previousTab()
        }

        observerBag.observeOnMainActor(.nextTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.routeReservedVNCKeyboardShortcut(from: notification) { return }
            self.nextTab()
        }

        observerBag.observe(.appTabSwipeBegan, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else {
                    if let accept = notification.userInfo?["accept"] as? (Bool) -> Void {
                        accept(false)
                    }
                    return
                }
                self.handleAppTabSwipeBegan(notification)
            }
        }

        observerBag.observe(.appTabSwipeChanged, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else { return }
                self.handleAppTabSwipeChanged(notification)
            }
        }

        observerBag.observe(.appTabSwipeEnded, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else { return }
                self.handleAppTabSwipeEnded(notification)
            }
        }

        observerBag.observeOnMainActor(.selectTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let tabIndex = notification.userInfo?["tabIndex"] as? Int else { return }
            self.selectTab(at: tabIndex)
        }

        observerBag.observeOnMainActor(.showTmuxSessions) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.showTmuxSessionsForSelectedTab()
        }

        observerBag.observeOnMainActor(.detachOtherClients) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.detachOtherClientsForSelectedTab()
        }

        observerBag.observeOnMainActor(.increaseFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Increasing font size for focused terminal")
            if focusedTerminal.applyTmuxWindowFontSize(delta: 1) { return }
            focusedTerminal.changeLocalFontSize(delta: 1)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.decreaseFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Decreasing font size for focused terminal")
            if focusedTerminal.applyTmuxWindowFontSize(delta: -1) { return }
            focusedTerminal.changeLocalFontSize(delta: -1)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.resetFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Resetting font size for focused terminal")
            if focusedTerminal.resetTmuxWindowFontSize() { return }
            focusedTerminal.resetLocalFontSize()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.startSearch) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal
            else { return }
            focusedTerminal.performActionAsync("start_search")
        }

        observerBag.observeOnMainActor(.openSettings) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.routeReservedVNCKeyboardShortcut(from: notification) { return }
            // Immediate toggle (open AND close), mirroring the tab sidebar's
            // CMD-shift-\: the binding-driven SidePanelOverlay animates either
            // way, so flip it directly.
            if self.showSettings {
                self.showSettings = false
            } else {
                self.requestSettingsPresentation()
            }
        }

        observerBag.observeOnMainActor(.duplicateTabWithSSH) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.duplicateCurrentTabWithSSH()
        }

        observerBag.observeOnMainActor(.createLocalShell) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            // The legacy notification now dispatches the global New Tab action.
            self.handleNewTabCommand()
        }

        observerBag.observeOnMainActor(.browseHosts) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.showSettings { self.showSettings = false }
            // Keep the docked sidebar (left column); only the floating overlay
            // conflicts with the connection sidebar (right overlay).
            if self.showingTabSwitcher && !self.tabSidebarIsDocked { self.showingTabSwitcher = false }
            self.connectionSidebarInitialTab = .browse
            self.showConnectionSidebar = true
        }

        observerBag.observeOnMainActor(.browseProfiles) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.showSettings { self.showSettings = false }
            // Keep the docked sidebar (left column); only the floating overlay
            // conflicts with the connection sidebar (right overlay).
            if self.showingTabSwitcher && !self.tabSidebarIsDocked { self.showingTabSwitcher = false }
            self.connectionSidebarInitialTab = .profiles
            self.showConnectionSidebar = true
        }

        #if !CHINA_BUILD
        observerBag.observeOnMainActor(.toggleAIAgent) { [self] notification in
            Ghostty.logger.info("toggleAIAgent notification received, object: \(String(describing: notification.object))")
            guard self.shouldHandleNotification(notification) else {
                Ghostty.logger.warning("shouldHandleNotification returned false")
                return
            }
            self.toggleAIAgent()
        }

        observerBag.observeOnMainActor(.toggleVoiceAgent) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.toggleVoiceAgent()
        }
        #endif

        observerBag.observeOnMainActor(.toggleThemePicker) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.showThemePickerOverlay.toggle()
        }

        observerBag.observeOnMainActor(.toggleClipboardManager) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            // On iPhone the manager is a sheet: dismiss the terminal keyboard
            // (and its input-accessory toolbar) first so it doesn't cover the
            // sheet, and keep the plain 2-state toggle.
            if UIDevice.current.userInterfaceIdiom == .phone {
                if !self.showClipboardManager {
                    self.resignFirstResponderForSheetPresentation()
                }
                self.showClipboardManager.toggle()
                return
            }
            self.advanceClipboardManagerCycle()
        }

        observerBag.observeOnMainActor(.ghosttySearchStateChanged) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            // Increment version to force SwiftUI re-render
            self.searchStateVersion += 1
        }

        observerBag.observeOnMainActor(.ghosttyComposeStateChanged) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.composeStateVersion += 1
        }

        observerBag.observeOnMainActor(.bellTriggered) { [self] notification in
            guard let terminalView = notification.object as? Ghostty.TerminalView else { return }

            // Find which tab contains this terminal and trigger wiggle
            for tab in self.terminals {
                if tab.splitTree.contains(terminalView) {
                    self.triggerWiggle(forTabId: tab.id)
                    break
                }
            }
        }

        // Handle notification clicks to navigate to specific terminal
        observerBag.observeOnMainActor(.navigateToTerminal) { [self] notification in
            guard let userInfo = notification.userInfo,
                  let tabID = userInfo["tabID"] as? UUID,
                  let surfaceID = userInfo["surfaceID"] as? UUID else { return }

            self.navigateToTerminal(tabID: tabID, surfaceID: surfaceID)
        }

        observerBag.observeOnMainActor(.tmuxPaneBindingsChanged) { _ in
            PushNotificationRouter.retryPending()
        }
        PushNotificationRouter.retryPending()

        observerBag.observeOnMainActor(.showTabSwitcher) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            if self.routeReservedVNCKeyboardShortcut(from: notification) { return }
            if self.showingTabSwitcher {
                self.dismissTabSidebar()
            } else {
                // The sidebar is a plain overlay (not a cover), so this
                // cannot race the settings teardown; just close settings so
                // the sidebar isn't hidden underneath it.
                if self.showSettings { self.showSettings = false }
                self.showingTabSwitcher = true
            }
        }

        observerBag.observeOnMainActor(.toggleTabExpose) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.toggleTabExpose()
        }

        observerBag.observeOnMainActor(.previousGroup) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.navigateScope(by: -1)
        }

        observerBag.observeOnMainActor(.nextGroup) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.navigateScope(by: 1)
        }

        observerBag.observeOnMainActor(.toggleBrightnessBoostHUD) { [self] notification in
            guard self.shouldHandleNotification(notification),
                  self.terminals.indices.contains(self.selectedTabIndex),
                  let pane = self.terminals[self.selectedTabIndex].focusedPane
            else { return }

            if let vncPane = pane as? VNCPaneView {
                vncPane.toggleBrightnessHUD()
            } else if let terminalView = pane as? Ghostty.TerminalView {
                terminalView.toggleBrightnessHUD()
            }
        }

        observerBag.observeOnMainActor(.showToolbarSettings) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.showToolbarSettings = true
        }

        // Handle SSH health monitoring toggle changes
        observerBag.observeOnMainActor(.sshHealthMonitoringToggled) { [self] notification in
            guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }

            // Iterate through all terminals in this window
            for (tabIndex, tab) in self.terminals.enumerated() {
                for terminalView in tab.splitTree.terminalLeaves {
                    // Check if this is a CitadelSSHSession (the only type with health monitoring)
                    if let citadelSession = terminalView.session as? CitadelSSHSession {
                        if enabled {
                            // Start monitoring on this active session
                            citadelSession.startHealthMonitoringIfEnabled()
                        } else {
                            // Stop monitoring
                            citadelSession.stopHealthMonitoring()
                            // Clear health state on the tab (equality-guard:
                            // every write to @State terminals invalidates all
                            // of MainView until the Phase 3 TabsModel refactor).
                            if self.terminals[tabIndex].connectionHealth != nil {
                                self.terminals[tabIndex].connectionHealth = nil
                            }
                        }
                    }
                }
            }
        }

        // Handle SSH health probe interval changes
        observerBag.observeOnMainActor(.sshHealthProbeIntervalChanged) { [self] notification in
            guard let interval = notification.userInfo?["interval"] as? Int else { return }

            // Update interval on all active CitadelSSHSession monitors
            for tab in self.terminals {
                for terminalView in tab.splitTree.terminalLeaves {
                    if let citadelSession = terminalView.session as? CitadelSSHSession {
                        citadelSession.updateHealthProbeInterval(TimeInterval(interval))
                    }
                }
            }
        }

        // Handle embedded session connection config changes (shell-launched SSH/Mosh/Trzsz)
        // This triggers a session count recount so LocationDiaryManager sees the new session
        observerBag.observeOnMainActor(.terminalConnectionConfigChanged) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            if let terminalView = notification.object as? Ghostty.TerminalView,
               let tabID = self.tabID(for: terminalView) {
                self.tabsModel.markGroupingInputsChanged(for: tabID)
            }
            self.notifySessionCountChanged()

            #if !CHINA_BUILD
            // If the terminal's shell context has actually changed (e.g. ssh from
            // local shell, or exiting back to local), tear down any AI Agent session
            // bound to the old context so it doesn't keep executing on the wrong shell.
            // Only act when the event comes from the same split that originally
            // spawned the agent — a sibling split in the same tab should not be
            // able to tear down an agent attached to a different split. The
            // notification also fires for local task active/inactive changes, so
            // compare connection types before invalidating.
            if let terminalView = notification.object as? Ghostty.TerminalView,
               let tabID = self.tabID(for: terminalView),
               let existing = self.aiAgentSessions[tabID],
               let ownerID = self.aiAgentSessionOwnerIDs[tabID],
               ObjectIdentifier(terminalView) == ownerID,
               let newType = self.aiAgentConnectionType(for: terminalView),
               existing.connectionType != newType {
                Ghostty.logger.info("Terminal connection context changed, invalidating AI Agent session")
                self.invalidateAIAgentSession(for: tabID)
            }
            #endif
        }
    }

    #if !targetEnvironment(macCatalyst)
    private func handleSceneDisconnectNotification(_ notification: Notification) {
        let disconnectedID = (notification.object as? UIScene)?.session.persistentIdentifier
        if let windowSceneSessionID {
            guard disconnectedID == windowSceneSessionID else { return }
        } else {
            // UIKit may report the disconnect before or after removing the
            // scene from connectedScenes; <= 1 covers both single-window
            // timings while avoiding cross-window cleanup.
            let connectedSceneCount = UIApplication.shared.connectedScenes.count
            guard connectedSceneCount <= 1 else { return }
        }

        performWindowCleanup(reason: "sceneDisconnect")
    }
    #endif
}

// MARK: - Window Filtering and Title Observation

extension MainView {

    // MARK: - Window Filtering Helper
    
    /// Check if a TerminalView belongs to this window
    private func belongsToThisWindow(_ pane: SplitPaneView?) -> Bool {
        guard let pane = pane else { return false }

        // Check if the pane exists in any of this window's tabs
        for terminal in terminals {
            if terminal.splitTree.contains(where: { $0 === pane }) {
                return true
            }
        }
        return false
    }
    
    /// Check if notification should be handled by this window
    /// Notifications may include a terminal object or a window scene identifier
    func shouldHandleNotification(_ notification: Notification) -> Bool {
        guard let pane = notification.object as? SplitPaneView else {
            // No terminal view in notification - check for scene ID targeting
            if let targetSceneID = notification.userInfo?[GhosttyCommandRouting.windowSceneSessionIDKey] as? String,
               let windowSceneSessionID,
               targetSceneID == windowSceneSessionID {
                return true
            }

            // On iPad/iPhone (single-window), accept notifications without explicit targeting
            // This handles the case when all tabs are closed and menu/keyboard shortcuts are used
            let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if connectedScenes.count <= 1 {
                return true
            }

            return false
        }
        return belongsToThisWindow(pane)
    }
    
    // MARK: - Title Observation
    //
    // Title and connection-health observation moved into `TabModel.startObserving()`
    // (see `Views/TabsModel.swift`). Each tab subscribes to its own focused
    // `Ghostty.TerminalView`'s `$title` and `$connectionHealth` and writes the
    // resolved values into its own `@Observable` properties — invalidation is
    // scoped per-tab instead of triggering a full `MainView` body recompute.
    //
    // The thin wrapper below keeps the existing call sites in
    // `MainViewTabManagement` and `MainViewPersistence` working: it just
    // forwards to the corresponding `TabModel.startObserving(...)` call.

    /// Set up title observation for the focused terminal in a tab.
    /// Forwards to `TabModel.startObserving()` so the per-tab subscription is
    /// owned by the tab model itself.
    func setupTitleObservation(at tabIndex: Int, preserveExistingTitle: Bool = false) {
        guard tabIndex < terminals.count else { return }
        terminals[tabIndex].startObserving(preserveExistingTitle: preserveExistingTitle)
    }
}
