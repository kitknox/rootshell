//
//  MainView+EventHandlers.swift
//  rootshell
//
//  Appear/disappear, tab-change, and window-focus handlers for MainView.
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

    // MARK: - View Modifier Handlers

    #if !CHINA_BUILD
    func handleAIAgentOverlayChange(_ isPresented: Bool) {
        // Resign first responder when overlay opens to prevent keyboard from appearing
        if isPresented {
            resignFirstResponderForSheetPresentation()
        }

        // iPhone: Update all terminals in current tab when AI Agent sheet visibility changes
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        for terminalView in tab.splitTree.terminalLeaves {
            terminalView.setAIAgentOverlayActive(isPresented)
        }

        // Return focus to terminal when overlay is dismissed
        if !isPresented {
            if let terminal = tab.focusedTerminal {
                _ = terminal.becomeFirstResponder()
            }
            currentAIAgentSession()?.cancel()
        }
    }

    func handleAIAgentSidebarVisibilityChange(oldValue: Set<UUID>, newValue: Set<UUID>) {
        // iPad/Catalyst/visionOS: Update terminals in tabs where AI Agent sidebar visibility changed
        let changedTabs = oldValue.symmetricDifference(newValue)
        for tab in terminals where changedTabs.contains(tab.id) {
            let isActive = newValue.contains(tab.id)
            for terminalView in tab.splitTree.terminalLeaves {
                terminalView.setAIAgentOverlayActive(isActive)
            }

            // Return focus to terminal when sidebar is dismissed for the current tab
            if !isActive,
               terminals.indices.contains(selectedTabIndex),
               tab.id == terminals[selectedTabIndex].id {
                if let terminal = tab.focusedTerminal {
                    _ = terminal.becomeFirstResponder()
                }
            }
        }

        // Post layout invalidation after sidebar animation completes to ensure terminals resize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }
    #endif

    func handleThemePickerOverlayChange(_ isPresented: Bool) {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        for terminalView in tab.splitTree.terminalLeaves {
            terminalView.setThemePickerOverlayActive(isPresented)
        }

        // Return focus to terminal when theme overlay is dismissed
        if !isPresented {
            if let terminal = tab.focusedTerminal {
                _ = terminal.becomeFirstResponder()
            }
        }
    }

    func handleOnAppear() {
        // External window: key state is scene-shared noise, sidebar pin and
        // effect focus belong to device windows.
        let isExternalWindow = isExternalDisplayWindow
        if !isExternalWindow {
            updateWindowFocusState()
        }

        // Restore the docked sidebar if it was pinned: `tabSidebarPinned`
        // persists but `showingTabSwitcher` does not, so re-assert it here.
        // The docked instance does not auto-focus its search field
        // (VerticalTabSidebar.isDocked), so this never steals the keyboard.
        if !isExternalWindow && tabSidebarPinned && canPinTabSidebar && !showingTabSwitcher {
            showingTabSwitcher = true
        }
        // Register with WindowStateManager for state persistence
        WindowStateManager.shared.registerWindow(windowId: windowId) { [self] in
            self.serializeWindowState()
        }
        TerminalWindowRegistry.register(
            tabsModel,
            windowId: windowId,
            refreshSelectionAfterMutation: { [self] allowFocus in
                refreshSelectionAfterExternalTabMutation(allowFocus: allowFocus)
            },
            rebindTabCallbacks: { [self] tab in
                rebindWindowScopedCallbacks(for: tab)
            }
        )
        if !isExternalWindow {
            TerminalWindowRegistry.updateSceneSessionId(windowSceneSessionID, for: windowId)
        }

        // Register this window's tabs so tmux control mode reconcile actions
        // (routed via the viewer-owner surface) can map windows->tabs here.
        TmuxWindowRegistry.register(tabsModel, windowId: windowId)

        // Agent inbox: the attention center reconciles its per-pane
        // monitors against every registered window's tabs.
        AgentAttentionCenter.shared.ensureStarted()

        // Subscription usage rides on agent presence from the center above.
        AgentUsageCenter.shared.ensureStarted()

        // Background effects with Text Avoidance resolve the focused terminal
        // through this closure; re-installed on focus gain so the last-focused
        // window wins when several are visible.
        if !isExternalWindow {
            TextAvoidanceFocus.install(windowId: windowId) { [weak tabsModel] in
                tabsModel?.selectedTab?.focusedTerminal
            }
        }

        let tabTransferObserver = NotificationCenter.default.addObserver(
            forName: .tabTransferEmptiedWindow,
            object: nil,
            queue: .main
        ) { notification in
            guard let emptiedWindowId = notification.userInfo?["windowId"] as? String,
                  emptiedWindowId == windowId else { return }
            windowClosingAfterTabTransfer = true
            showConnectionSidebar = false
            showingTabSwitcher = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if terminals.isEmpty {
                    windowClosingAfterTabTransfer = false
                }
            }
        }
        observerBag.track(tabTransferObserver)

        let tabTransferDragObserver = NotificationCenter.default.addObserver(
            forName: .tabTransferDragStateChanged,
            object: nil,
            queue: .main
        ) { _ in
            // Delivered on .main, so MainActor access is safe here.
            MainActor.assumeIsolated {
                tabTransferDropOverlayVisible = TabTransferCoordinator.shared.canAcceptActiveDrag(in: windowId)
            }
        }
        observerBag.track(tabTransferDragObserver)

#if STANDALONE && targetEnvironment(macCatalyst)
        if windowId == "visor" {
            let hostID = visorContentHostID
            VisorController.shared.registerContentHost(
                id: hostID,
                hasTerminal: { !terminals.isEmpty },
                ensureTerminal: { await ensureVisorHasTerminal() }
            )
        }
#endif
        
        // Check for pending restoration
        if isExternalWindow {
            // External window: always a fresh local shell (no restore, no
            // connection sheet on a screen the user cannot touch).
            if terminals.isEmpty {
                createLocalShellTabInternal()
            }
        } else if terminals.isEmpty,
           TabTransferCoordinator.shared.claimPendingTransfer(
               for: windowId,
               isDestinationWindowFocused: isWindowFocused
           ) {
            notifySessionCountChanged()
        } else if terminals.isEmpty {
#if targetEnvironment(macCatalyst)
            if windowId == "visor" {
                // The visor scene can be prewarmed while hidden. Do not
                // create a terminal until VisorController asks the registered
                // content host for one during an actual summon; otherwise
                // Catalyst may materialize a shell before the underlying
                // NSWindow has been converted into the visor panel.
            } else {
            // Catalyst terminal I/O needs the helper. If it has already been
            // confirmed running (every window after the first) AND there's no
            // saved state to restore, create the local shell synchronously so
            // content isn't serialized behind a MainActor-congested await —
            // the open-latency trace showed that await costing 0.5–2s. The
            // first window, and any restore, take the safe async path that
            // awaits ensureHelperRunning() first.
            //
            // NOTE: getPendingState() has a side effect — it marks the window
            // as restored — so it must be read exactly once and the value
            // reused (a second call returns nil and would skip restore).
            let pendingState = WindowStateManager.shared.getPendingState(forWindowId: windowId)
            // Stash this window's saved size/position; it is applied exactly once
            // the scene link is live (from the WindowSceneReporter callback above,
            // or right here if the link is already up). Restoring it also triggers
            // the layout pass that fixes the Catalyst blank secondary window.
            // Covers both restore (savedFrame from state) and a new Cmd-N window
            // (nil → nudge-only if another window is open).
            stashPendingGeometryRestore(savedFrame: pendingState.flatMap { Self.savedFrame(from: $0) })
            if pendingState == nil, HelperConnection.shared.isKnownRunning {
                // createLocalShellTab() runs synchronously now: performLocalShellAction()
                // takes its fast path when the helper is already confirmed up.
                createLocalShellTab()
            } else {
                Task { @MainActor in
                    _ = await HelperConnection.shared.ensureHelperRunning()

                    if let savedState = pendingState {
                        // Mark restoration in-progress for crash detection
                        RestorationHealthTracker.shared.markRestorationStarted()
                        Ghostty.logger.info("Restoring window state: \(savedState.tabs.count) tabs")
                        self.restoreWindowState(savedState)
                    } else {
                        // Normal fresh start - helper is already running from above
                        self.checkHelperAndCreateInitialTab()
                    }
                }
            }
            }
#else
            // Non-Catalyst path (iPad/iPhone/visionOS)
            if let savedState = WindowStateManager.shared.getPendingState(forWindowId: windowId) {
                // Mark restoration in-progress for crash detection
                RestorationHealthTracker.shared.markRestorationStarted()
                Ghostty.logger.info("Restoring window state: \(savedState.tabs.count) tabs")
                restoreWindowState(savedState)
            } else {
                // iPad: directly open local iOS shell
                // iPhone/visionOS: show connection sheet
                if UIDevice.current.userInterfaceIdiom == .pad {
                    createLocalShellTabInternal()
                } else {
                    addNewTab()
                }
            }
#endif
        }
        // Setup notification observers
        setupNotificationObservers()
        
        // Notify session tracker of initial state
        notifySessionCountChanged()

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        DispatchQueue.main.async {
            LiveActivityManager.shared.reconcileAfterActivation()
        }
#endif
        
        // Window blur is applied by WindowAccessor when it claims this
        // window's NSWindow, and re-asserted on scene activation.

        // Cold-start sweeps: a file-open URL or intent request delivered at
        // launch can precede this window's onReceive subscription. Deferred
        // so they run after the restoration-claim branch above; no-ops when
        // the coordinator buffers are empty.
        if !isExternalWindow {
            Task { @MainActor in
                consumePendingFileOpens()
                consumePendingIntentRequests()
            }
        }
    }

    func handleOnDisappear() {
        #if targetEnvironment(macCatalyst)
        #if STANDALONE
        if windowId == "visor" {
            cancelVisorReadinessWaiters()
            VisorController.shared.unregisterContentHost(id: visorContentHostID)
        }
        #endif
        performWindowCleanup(reason: "disappear")
        #endif
    }

    func performWindowCleanup(reason: String) {
        guard !didCleanUpWindow else { return }
        didCleanUpWindow = true

        // Release this window's overlay keyboard-preservation claim (no-op
        // unless it owns the latch) so surviving windows don't stay frozen
        // until the next keyboard event notices the dead owner.
        KeyboardTracker.shared.endOverlayKeyboardPreservation(owner: tabsModel)

        // Clean up observers. The block-based addObserver API returns tokens
        // that the legacy `removeObserver(self)` call would NOT match — those
        // observers leaked across appear/disappear cycles, stacking 32 fresh
        // observers on every iPhone scene re-creation. Use the bag's explicit
        // removal so each disappear leaves NotificationCenter clean.
        observerBag.removeAll()

        // Unregister from WindowStateManager
        WindowStateManager.shared.unregisterWindow(windowId: windowId)
        TerminalWindowRegistry.unregister(windowId: windowId)
        TmuxWindowRegistry.unregister(windowId: windowId)
        TextAvoidanceFocus.uninstall(windowId: windowId)
        
        // Clean up all terminals for this window
        let cleanupWindowId = windowId
        let terminalCount = terminals.count
        Ghostty.logger.info("MainView for window \(cleanupWindowId) cleaning up \(terminalCount) terminals, reason: \(reason)")
        
        // Terminal surfaces have a scene-specific synchronous cleanup path.
        // Non-terminal panes may own nested view controllers (VNC does); do
        // not remove those children or tear down their SwiftUI roots from
        // inside this MainView's onDisappear/scene-disconnect stack. On
        // Catalyst that re-enters UIKit/AppKit containment while the window's
        // root hosting controller is already being dismantled and can wedge
        // the main thread. Retain those panes until the next main-queue turn,
        // after scene teardown has unwound, then run their normal close funnel.
        var deferredPaneCleanup: [SplitPaneView] = []

        // Cleanup all panes in all tabs before removing
        for tab in terminals {
            for paneView in tab.splitTree {
                if let terminalView = paneView.asTerminal {
                    withdrawKeyboardInteractive(for: terminalView)
                    terminalView.cleanup(reason: .sceneTeardown)
                } else {
                    deferredPaneCleanup.append(paneView)
                }
            }
        }
        terminals.removeAll()

        let panesToCleanUp = deferredPaneCleanup
        if !panesToCleanUp.isEmpty {
            DispatchQueue.main.async {
                for paneView in panesToCleanUp {
                    paneView.prepareForClose()
                }
            }
        }
        
        // Remove this window from session tracker
        SessionTracker.shared.removeWindow(windowId)
    }

    func handleTerminalCountChange(oldCount: Int, newCount: Int) {
        // Top-level observer for terminal count changes
        // This ensures session tracking is always updated (for location diary and quit confirmation)
        Ghostty.logger.info("Terminal count changed: \(oldCount) -> \(newCount)")
        notifySessionCountChanged()

        if newCount == 0 {
            if selectedTabIndex != 0 {
                selectedTabIndex = 0
            }
            tabsModel.syncDisplayedTab()
            return
        }

        if !terminals.indices.contains(selectedTabIndex) {
            selectedTabIndex = min(max(selectedTabIndex, 0), newCount - 1)
        }

        // A removed tab may have been the displayed one (mid-reveal) even when
        // the selection itself didn't move; re-reconcile the reveal state.
        tabsModel.syncDisplayedTab()
    }

    func handleSelectedTabChange(oldValue: Int, newValue: Int) {
        Ghostty.logger.info("onChange(selectedTabIndex): \(oldValue) -> \(newValue)")

        // Clear any stale drag state when tabs are selected
        if draggingTab != nil {
            draggingTab = nil
        }

        // A live swipe only changes the selection at commit time, and the commit
        // flips `isSettling` in the same main-thread turn as the selection write
        // (this onChange observes it on the next SwiftUI update). So a
        // NON-settling swipe state seen here is an abandoned swipe whose Ended
        // notification was lost — left alone it renders every tab except its
        // source at opacity 0 forever. Clear it so this switch lands visibly.
        if let swipe = appTabSwipeState, !swipe.isSettling {
            forceClearAppTabSwipe(reason: "tabSwitchDuringSwipe")
        }

        guard terminals.indices.contains(newValue) else { return }

        // Mark all surfaces in old tab as occluded to stop their IOSDisplayLink
        if terminals.indices.contains(oldValue) {
            for terminal in terminals[oldValue].splitTree {
                terminal.setOcclusion(false)
            }
        }

        // Mark all surfaces in new tab as visible before focusing
        for terminal in terminals[newValue].splitTree {
            terminal.setOcclusion(true)
        }

        // Set up the focused pane reference
        var paneToFocus = terminals[newValue].focusedPane

        // If no pane is focused yet, focus the first one in the split tree
        if paneToFocus == nil, let firstPane = terminals[newValue].splitTree.first {
            paneToFocus = firstPane
            terminals[newValue].focusedPane = firstPane
        }

        // FOCUS NEW TERMINAL FIRST — keyboard stays visible because
        // becomeFirstResponder() on the new terminal causes UIKit to
        // auto-resign the old one, maintaining a continuous first-responder chain.
        // focusDidChange returns true only when becomeFirstResponder() succeeded
        // synchronously, meaning UIKit already auto-resigned the old terminal.
        var newFocusAcquired = false
        if let focus = paneToFocus {
            Ghostty.logger.info("Focusing terminal at tab \(newValue)")
            focus.isLogicallyFocused = true
            // Initialize the gate before focusing, in case this tab's terminal
            // was created while an overlay is open (the connection sidebar's
            // tab-bar guard below only covers the tab sidebar). Without it the
            // new terminal's gate is stale-false and focusDidChange could steal
            // first responder from the open overlay.
            focus.setOverlayOwnsKeyboard(isAnySheetPresented)
            // While the tab sidebar is open and staying open on select, its
            // search field owns the keyboard: keep the logical focus
            // bookkeeping but skip becomeFirstResponder, which would rip
            // first responder out of the panel and kill its arrow-key
            // navigation mid-session. The terminal regains first responder
            // when the sidebar dismisses (the overlayOwnsKeyboard gate's
            // falling-edge reconcile in setOverlayOwnsKeyboard(false)). Now
            // belt-and-suspenders: the gate would refuse the
            // becomeFirstResponder anyway, but skipping it here also avoids
            // resign churn on the old terminal.
            // Only the FLOATING overlay owns the keyboard while staying open on
            // select. When docked, the sidebar sits beside the terminal, so
            // picking a tab should refocus the terminal for typing.
            if !(showingTabSwitcher && !tabSidebarDismissesOnSelect && !tabSidebarIsDocked) {
                newFocusAcquired = focus.focusDidChange(true)
            }

            // USER tab switch into a tmux window tab: sync tmux's current
            // window + active pane explicitly (the core no longer echoes
            // select-window/select-pane on focus gain — see
            // id=tmux-select-pane-user-only).
            if let terminal = focus.asTerminal, terminal.isTmuxPane {
                terminal.requestTmuxSelectPane()
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
                ghosttyApp.appTick()
            }
        }

        // Unfocus old — only skip resignFirstResponder when the new terminal
        // actually became first responder (UIKit already auto-resigned the old one)
        if terminals.indices.contains(oldValue) {
            if let oldFocus = terminals[oldValue].focusedPane {
                Ghostty.logger.info("Unfocusing old terminal at tab \(oldValue)")
                oldFocus.focusDidChange(false, skipResign: newFocusAcquired)
                oldFocus.isLogicallyFocused = false
            }
        }

        // Show tab indicator overlay when tab bar is hidden, unless the user
        // selected via the vertical tab sidebar that is already visible.
        let shouldSuppressIndicator = tabIndicator.consumeSuppressHiddenIndicator()
        if tabBarHidden && terminals.count > 1 && !shouldSuppressIndicator {
            tabIndicator.showBriefly()
        }

        // Tab-switch occlusion + focus backstop. The imperative setOcclusion(true)
        // + focusDidChange(true) above can be dropped (setOcclusion silently no-ops
        // when the destination surface is briefly nil and never retries) or refused
        // (becomeFirstResponder mid scene/keyboard event). Post the GhosttyKit merge
        // a surface stranded at flags.visible == false hard-stops its render thread
        // (a permanent freeze), and a refused first responder leaves the tab
        // unusable — with NO foreground cycle to trigger the foreground-only
        // reconcileSurfaceOcclusion. So re-assert occlusion + retry first responder
        // for the destination tab a couple of ticks later. Epoch-guarded (skip after
        // a background) and scoped to this switch (skip if a later switch already
        // won). Idempotent: a cheap core no-op when the tab is already alive.
        let destTabID = terminals[newValue].id
        LifecycleDebugLogger.shared.checkpoint("FG.tabSwitch", ms: nil, [
            ("from", oldValue),
            ("to", newValue),
            ("dest", String(destTabID.uuidString.prefix(8))),
            ("surfaces", terminals[newValue].splitTree.count),
            ("newFocusAcquired", newFocusAcquired),
            ("focusedIsFR", paneToFocus?.isFirstResponder ?? false),
        ])
        let backstopBgEpoch = LifecycleEpoch.shared.background
        for delay in [0.12, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                guard LifecycleEpoch.shared.background == backstopBgEpoch else { return }
                guard tabsModel.selectedTabID == destTabID else { return }
                reassertSelectedTabVisibility(reason: "tabSwitchBackstop+\(delay)")
            }
        }
    }

    func handleShowConnectionSheetChange(oldValue: Bool, newValue: Bool) {
        Ghostty.logger.info("onChange(showConnectionSidebar): \(oldValue) -> \(newValue)")
        #if targetEnvironment(macCatalyst)
        if newValue {
            CatalystCursorCoordinator.shared.resetAll()
        }
        #endif
        // Resign first responder when sheet opens to prevent keyboard from appearing
        if newValue {
            resignFirstResponderForSheetPresentation()
        }
        // When connection sheet dismisses, clear pending browse selection and grant UIKit focus
        // Ghostty focus was already set when the tab was created
        if oldValue == true && newValue == false {
            pendingBrowseSelection = nil  // Clear browse selection on dismissal

            // Safety net: if no terminals exist and the tab bar is hidden,
            // re-show the sheet immediately. Without this, the user lands on an
            // empty state with no way to connect (no tab bar + button to tap).
            if terminals.isEmpty && tabBarHidden && !isExternalDisplayWindow {
                Ghostty.logger.info("Sheet dismissed with no terminals (tab bar hidden) - re-showing")
                showConnectionSidebar = true
                return
            }

            guard terminals.indices.contains(selectedTabIndex) else { return }
            guard let terminal = terminals[selectedTabIndex].focusedTerminal else {
                Ghostty.logger.warning("Sheet dismissed but no focusedTerminal!")
                return
            }
            
            // Grant UIKit focus to the terminal after sheet dismissal
            if terminal.isLogicallyFocused && !terminal.isFirstResponder {
                _ = terminal.becomeFirstResponder()
                terminal.reloadInputViews()
            }
        }
    }

#if targetEnvironment(macCatalyst)
    func handleTabsInTitlebarEnabledChange() {
        // Post layout invalidation after safe area changes propagate to ensure terminals resize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }
#endif

    // MARK: - Window Focus

    func updateWindowFocusState() {
        // External terminals' focus is driven by ExternalDisplayManager; the
        // scene-shared activeAppearance would otherwise mirror the device window.
        guard !isExternalDisplayWindow else { return }
        let isFocused: Bool
#if targetEnvironment(macCatalyst)
        isFocused = windowIsKeyWindow
#else
        // iOS/iPadOS/visionOS: Use windowIsKeyWindow (derived from activeAppearance trait)
        // Guard against false positives from background snapshotting - activeAppearance can
        // flicker while the app is off-screen. Only trust it when the UIKit-backed
        // lifecycle phase is active.
        guard lifecycleScenePhase == .active else {
            let keyboardTracker = KeyboardTracker.shared
            if keyboardTracker.isPreservingSoftwareKeyboardForAppTransition {
                return
            }
            if isWindowFocused {
                isWindowFocused = false
                applyWindowFocusState(false)
            }
            return
        }
        isFocused = windowIsKeyWindow
#endif
        guard isWindowFocused != isFocused else { return }
        isWindowFocused = isFocused
        applyWindowFocusState(isFocused)
        if isFocused {
            TextAvoidanceFocus.install(windowId: windowId) { [weak tabsModel] in
                tabsModel?.selectedTab?.focusedTerminal
            }
        }
    }

    private func applyWindowFocusState(_ isFocused: Bool) {
        for tab in terminals {
            for terminalView in tab.splitTree {
                terminalView.setWindowActive(isFocused)
            }
        }
    }
}
