//
//  MainView+Focus.swift
//  rootshell
//
//  Focus management and tab navigation for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Focus Generation Counter

extension MainView {

    /// Global focus generation counter used to prevent stale focus operations.
    /// When a new focus request is made, we increment this counter and capture its value.
    /// Any delayed focus operations compare against this counter and bail out if stale.
    /// This is especially important during rapid tab switches or when multiple async
    /// SSH/Kubernetes connections are completing.
    @MainActor
    static var focusGeneration: UInt64 = 0

    @MainActor
    static func incrementFocusGeneration() -> UInt64 {
        focusGeneration &+= 1
        return focusGeneration
    }
}


// MARK: - Focus Management

extension MainView {

    /// Terminal-typed convenience wrapper over `setFocusedPane`; kept so the
    /// many terminal call sites stay unchanged.
    func setFocusedTerminal(_ terminal: Ghostty.TerminalView?, inTab tabIndex: Int) {
        setFocusedPane(terminal, inTab: tabIndex)
    }

    func setFocusedPane(_ pane: SplitPaneView?, inTab tabIndex: Int) {
        guard tabIndex < terminals.count else { return }
        let current = terminals[tabIndex].focusedPane
        if current == nil && pane == nil { return }
        // Initialize the keyboard-ownership gate for the target pane up
        // front — BEFORE the same-pane early return below. A new tab is
        // created with its focused pane pre-populated
        // (TabModel.init(terminalView:)), so a fresh tab makes current ===
        // pane and takes the early return; its actual first-responder grab
        // then comes from the inserted view's didMoveToWindow, which runs AFTER
        // this synchronous call. If the pane is born while an overlay (tab/
        // connection sidebar) owns the keyboard, a stale-false gate would let
        // didMoveToWindow steal first responder from the open sidebar — and the
        // pane would miss the dismiss reconcile, since the flag was never
        // raised. Seeding it here (live isAnySheetPresented) covers both, and
        // is a no-op when no overlay is up.
        pane?.setOverlayOwnsKeyboard(isAnySheetPresented)
        if let current, let pane, current === pane {
            // Same-pane re-focus (e.g. tapping the already-focused tmux pane):
            // still re-assert tmux's active window/pane. With the core's
            // automatic select-pane echo gone, this is the user's only way to
            // pull tmux focus back after another client moved it; a tmux no-op
            // when already in sync. ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
            if let terminal = pane.asTerminal, terminal.isTmuxPane {
                terminal.requestTmuxSelectPane()
            }
            return
        }

        // Focus new pane first to prevent keyboard dismiss/reshow cycle.
        // becomeFirstResponder() on the new pane causes UIKit to auto-resign
        // the old one, maintaining a continuous first-responder chain.
        // focusDidChange returns true only when becomeFirstResponder() succeeded
        // synchronously, meaning UIKit already auto-resigned the old pane.
        terminals[tabIndex].focusedPane = pane
        pane?.isLogicallyFocused = true
        let newFocusAcquired = pane?.focusDidChange(true) ?? false

        // USER-initiated focus (tap, split navigation, close-survivor,
        // notification click): keep tmux's active pane in sync explicitly.
        // The core no longer echoes select-pane on focus gain, and the
        // programmatic paths (TmuxController.focusPane: remote follows,
        // split fulfillment, watchdog) intentionally send nothing — echoing
        // those oscillates focus between two attached clients.
        // ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
        if let terminal = pane?.asTerminal, terminal.isTmuxPane {
            terminal.requestTmuxSelectPane()
        }

        // Unfocus old — only skip resignFirstResponder when the new pane
        // actually became first responder (UIKit already auto-resigned the old one)
        if let current {
            if let currentTerminal = current.asTerminal, currentTerminal.surface == nil {
                // Terminal was cleaned up; focusDidChange(false) would bail
                // early without resigning
                if currentTerminal.isFirstResponder {
                    currentTerminal.resignFirstResponder()
                }
            } else {
                current.focusDidChange(false, skipResign: newFocusAcquired)
            }
            current.isLogicallyFocused = false
        }

        // Update title observation to track the newly focused pane
        // This ensures the tab title always reflects the focused split
        setupTitleObservation(at: tabIndex)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
            ghosttyApp.appTick()
        }

        // Verify focus succeeded after async dispatch completes
        if let pane {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak pane] in
                guard let pane = pane,
                      pane.window != nil,
                      pane.isLogicallyFocused,
                      !pane.isFirstResponder else { return }
                Ghostty.logger.warning("Focus verification failed, retrying")
                _ = pane.becomeFirstResponder()
            }
        }
    }
}

// MARK: - Tab Navigation

extension MainView {

    // Tab navigation operates on `navigationTabs`: hidden tmux window tabs are
    // skipped, and grouped mode narrows navigation to the active group.
    // (id=tmux-hidden-windows)

    func previousTab() {
        let visible = tabsModel.navigationTabs
        guard !visible.isEmpty else { return }
        let current = tabsModel.selectedTabID
            .flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let target = current > 0 ? current - 1 : visible.count - 1
        applyTabSwitch(toTabID: visible[target].id)
    }

    func nextTab() {
        let visible = tabsModel.navigationTabs
        guard !visible.isEmpty else { return }
        let current = tabsModel.selectedTabID
            .flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let target = current < visible.count - 1 ? current + 1 : 0
        applyTabSwitch(toTabID: visible[target].id)
    }

    func triggerWiggle(forTabId id: UUID) {
        // Add tab to wiggling set (triggers animation)
        withAnimation(.spring(response: 0.1, dampingFraction: 0.3)) {
            _ = wigglingTabIds.insert(id)
        }

        // Remove after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeOut(duration: 0.1)) {
                _ = wigglingTabIds.remove(id)
            }
        }
    }

    func selectTab(at index: Int) {
        // Convert 1-based index (CMD+1 = tab 1) to 0-based VISIBLE index.
        let visible = tabsModel.navigationTabs
        let arrayIndex = index - 1

        // Only switch if the tab exists
        guard arrayIndex >= 0 && arrayIndex < visible.count else { return }
        applyTabSwitch(toTabID: visible[arrayIndex].id)
    }

    /// Select a tab by its stable identity. Preferred over `selectTab(at:)` for
    /// UI that already holds a tab ID (the vertical sidebar): it avoids the
    /// full-array vs visible-array index round-trip that `selectTab(at:)`'s
    /// 1-based VISIBLE indexing makes easy to get wrong once tmux windows or a
    /// gateway are hidden. (id=tmux-hidden-windows)
    func selectTab(id: UUID) {
        applyTabSwitch(toTabID: id)
    }

    func selectTabWithoutTabBarAnimation(id: UUID) {
        guard tabsModel.selectedTabID != id else { return }
        tabIndicator.suppressNextSelectionAnimation = true
        applyTabSwitch(toTabID: id)
        Task { @MainActor in
            await Task.yield()
            if self.tabsModel.selectedTabID == id {
                self.tabIndicator.suppressNextSelectionAnimation = false
            }
        }
    }

    func handleAppTabSwipeBegan(_ notification: Notification) {
        guard let direction = notification.userInfo?["direction"] as? SwipeDirection else { return }
        let width = notification.userInfo?["width"] as? CGFloat ?? 0
        let accepted = beginAppTabSwipe(direction: direction, width: width)
        if let accept = notification.userInfo?["accept"] as? (Bool) -> Void {
            accept(accepted)
        }
    }

    func handleAppTabSwipeChanged(_ notification: Notification) {
        guard let direction = notification.userInfo?["direction"] as? SwipeDirection else { return }
        let width = notification.userInfo?["width"] as? CGFloat ?? appTabSwipeState?.width ?? 0
        if appTabSwipeState == nil {
            _ = beginAppTabSwipe(direction: direction, width: width)
        }
        guard var state = appTabSwipeState,
              state.direction == direction else { return }
        state.translationX = notification.userInfo?["translationX"] as? CGFloat ?? 0
        if width > 0 { state.width = width }
        state.lastEventAt = CACurrentMediaTime()
        appTabSwipeState = state
    }

    func handleAppTabSwipeEnded(_ notification: Notification) {
        guard var state = appTabSwipeState else { return }
        let translation = notification.userInfo?["translationX"] as? CGFloat ?? state.translationX
        let velocity = notification.userInfo?["velocityX"] as? CGFloat ?? 0
        if let width = notification.userInfo?["width"] as? CGFloat, width > 0 {
            state.width = width
        }
        state.translationX = translation
        state.lastEventAt = CACurrentMediaTime()
        appTabSwipeState = state

        let distance = abs(state.clampedTranslationX)
        let threshold = max(120, min(state.width * 0.45, 260))
        let velocityCommits: Bool = switch state.direction {
        case .left: velocity < -900
        case .right: velocity > 900
        }

        let commits = distance >= threshold || velocityCommits
        LifecycleDebugLogger.shared.checkpoint("FG.appTabSwipe.end", ms: nil, [
            ("action", commits ? "commit" : "cancel"),
            ("translationX", Int(state.clampedTranslationX)),
            ("velocityX", Int(velocity)),
        ])
        if commits {
            commitAppTabSwipe(state)
        } else {
            cancelAppTabSwipe(state)
        }
    }

    private func beginAppTabSwipe(direction: SwipeDirection, width: CGFloat) -> Bool {
        guard appTabSwipeState?.isSettling != true,
              let sourceID = tabsModel.selectedTabID,
              let targetID = appTabSwipeTargetID(for: direction),
              targetID != sourceID else { return false }

        // Snapshot this before the eventual selection commit transfers first
        // responder to the target. A non-selected tab reports no toolbar
        // reservation, so reading each sliding tab live would give source and
        // target different heights while a hardware-keyboard toolbar is shown.
        let reservedBottomToolbarHeight = tabsModel.tab(withID: sourceID)?
            .focusedPane?
            .reservedKeyboardToolbarHeightAtBottom ?? 0

        tabIndicator.hideImmediately()

        if let previous = appTabSwipeState {
            // Tabs that THIS swipe will (re-)assert below; never clean them up,
            // they must stay visible/suppressed for the new slide.
            let newSwipeTabs: Set<UUID> = [sourceID, targetID]

            // Re-occlude a previous swipe's abandoned target — but not if it's
            // part of the new swipe (e.g. it became the new source), which must
            // stay visible.
            if !newSwipeTabs.contains(previous.targetTabID) {
                setTabOcclusion(tabID: previous.targetTabID, visible: false)
            }

            #if !targetEnvironment(macCatalyst)
            // Release swipe-suppression on any tab from the previous (non-settling)
            // swipe that THIS swipe won't re-suppress. Without this, if the
            // selected tab changed between swipes the previous source/target could
            // stay suppressed indefinitely and its selection handles would never
            // reappear. Tabs still in the new swipe are left suppressed (they're
            // re-asserted right after), avoiding a release→re-suppress churn.
            for staleTab in [previous.sourceTabID, previous.targetTabID]
            where !newSwipeTabs.contains(staleTab) {
                setTabSelectionUISwipeSuppressed(staleTab, false)
            }
            #endif
        }

        setTabOcclusion(tabID: targetID, visible: true)
        #if !targetEnvironment(macCatalyst)
        // Hide selection handles on both sliding tabs for the duration of the
        // swipe; they're recreated at the settled position when finish() runs.
        setTabSelectionUISwipeSuppressed(sourceID, true)
        setTabSelectionUISwipeSuppressed(targetID, true)
        #endif
        appTabSwipeState = AppTabSwipeState(
            sourceTabID: sourceID,
            targetTabID: targetID,
            direction: direction,
            reservedBottomToolbarHeight: reservedBottomToolbarHeight,
            translationX: 0,
            width: max(width, 1),
            lastEventAt: CACurrentMediaTime()
        )
        LifecycleDebugLogger.shared.checkpoint("FG.appTabSwipe.begin", ms: nil, [
            ("source", String(sourceID.uuidString.prefix(8))),
            ("target", String(targetID.uuidString.prefix(8))),
            ("direction", String(describing: direction)),
        ])
        return true
    }

    private func appTabSwipeTargetID(for direction: SwipeDirection) -> UUID? {
        guard let preset = SwipeGestureManager.shared.binding(for: direction).appTabPreset else { return nil }
        let visible = tabsModel.navigationTabs
        guard visible.count > 1 else { return nil }
        let current = tabsModel.selectedTabID
            .flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        switch preset {
        case .nextTab:
            return visible[current < visible.count - 1 ? current + 1 : 0].id
        case .previousTab:
            return visible[current > 0 ? current - 1 : visible.count - 1].id
        default:
            return nil
        }
    }

    private func commitAppTabSwipe(_ state: AppTabSwipeState) {
        var settling = state
        settling.translationX = state.direction == .left ? -max(state.width, 1) : max(state.width, 1)
        settling.isSettling = true

        let animationsDisabled = UserDefaults.standard.bool(forKey: "tabBarAnimationsDisabled")
            || UIAccessibility.isReduceMotionEnabled

        // Commit the selection the instant the swipe is committed — not when the
        // content-slide spring settles ~280ms later. Updating `selectedTabID` now
        // lets the top tab-bar indicator slide to the new tab IN PARALLEL with the
        // content sliding into place, instead of snapping over after the slide
        // ends (the old behaviour: selection was deferred into `finish`).
        //
        // Safe to do mid-slide: the terminal content keeps rendering from
        // `appTabSwipeState` (source + target sliding beside each other) until
        // `finish` clears the state, so the early selection change is invisible to
        // the slide. `displayedTabID` reconciles to the already-rendered target
        // immediately — and doing it now gives that reveal a head start before the
        // state is removed, so there's no jump when it clears.
        //
        // The indicator animation is back ON for this path (it used to be
        // suppressed because the late selection would have snapped). Under reduced
        // motion it must not spring, so suppress it there.
        if animationsDisabled {
            selectTabWithoutTabBarAnimation(id: state.targetTabID)
        } else {
            applyTabSwitch(toTabID: state.targetTabID)
        }

        // Guarded so it runs at most once: it nils the state, so a second caller
        // (the fallback timer below, or a stale completion) no-ops. `beginAppTabSwipe`
        // refuses while `isSettling`, so a never-cleared state would wedge all
        // swiping — hence both the completion handler AND the fallback.
        let finish = {
            guard let current = self.appTabSwipeState,
                  current.sourceTabID == state.sourceTabID,
                  current.targetTabID == state.targetTabID,
                  current.isSettling else { return }
            self.appTabSwipeState = nil
            LifecycleDebugLogger.shared.checkpoint("FG.appTabSwipe.finish", ms: nil, [
                ("path", "commit"),
            ])
            #if !targetEnvironment(macCatalyst)
            // Both tabs have settled at offset 0; recreate selection handles at
            // their final position. The target (now selected) re-presents any
            // touch selection's handles; the source is occluded, so its handles
            // stay hidden — this just clears its swipe-suppressed flag.
            self.setTabSelectionUISwipeSuppressed(state.sourceTabID, false)
            self.setTabSelectionUISwipeSuppressed(state.targetTabID, false)
            #endif
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            // Skip on Catalyst: a no-op on Macs without a Force Touch trackpad.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }

        if animationsDisabled {
            appTabSwipeState = settling
            finish()
            return
        }

        // Clear the swipe state on animation completion rather than on a fixed
        // timer. A timer that fires before the spring settles removes the source
        // tab while the target is still sliding the last few points into place,
        // briefly uncovering a backdrop strip at the edge — the white flash.
        // Completion fires exactly when the target has reached offset 0 (and the
        // source is fully off-screen), so the handoff is seamless.
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
            appTabSwipeState = settling
        } completion: {
            finish()
        }
        // Safety net in case the completion handler is ever dropped (e.g. the
        // animation is removed while backgrounded): well past the spring settle.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            finish()
        }
    }

    private func cancelAppTabSwipe(_ state: AppTabSwipeState) {
        var settling = state
        settling.translationX = 0
        settling.isSettling = true

        let animationsDisabled = UserDefaults.standard.bool(forKey: "tabBarAnimationsDisabled")
            || UIAccessibility.isReduceMotionEnabled
        // Guarded so it runs at most once across the completion handler and the
        // fallback timer below (see commitAppTabSwipe for why both exist).
        let finish = {
            guard let current = self.appTabSwipeState,
                  current.sourceTabID == state.sourceTabID,
                  current.targetTabID == state.targetTabID,
                  current.isSettling else { return }
            self.setTabOcclusion(tabID: state.targetTabID, visible: false)
            self.appTabSwipeState = nil
            LifecycleDebugLogger.shared.checkpoint("FG.appTabSwipe.finish", ms: nil, [
                ("path", "cancel"),
            ])
            #if !targetEnvironment(macCatalyst)
            // The source tab has slid back to offset 0 and stays selected;
            // recreate its selection handles at the settled position. The target
            // is occluded, so clearing its flag leaves its handles hidden.
            self.setTabSelectionUISwipeSuppressed(state.sourceTabID, false)
            self.setTabSelectionUISwipeSuppressed(state.targetTabID, false)
            #endif
        }

        if animationsDisabled {
            appTabSwipeState = settling
            finish()
            return
        }

        // Clear on completion, not a timer: the source slides back to center as
        // the target slides off in lockstep, so removing the target before the
        // spring settles would uncover a backdrop strip (white flash) on the
        // opposite edge for a frame. Completion fires when source is back at 0.
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9)) {
            appTabSwipeState = settling
        } completion: {
            finish()
        }
        // Safety net in case the completion handler is ever dropped.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            finish()
        }
    }

    /// Force-clear a wedged app-tab swipe state, without the settle animation.
    ///
    /// A swipe whose Ended notification is lost (recognizer died without
    /// `.cancelled`, trackpad end-timer invalidated, the posting terminal left
    /// this window's tabs mid-gesture) leaves `appTabSwipeState` set with
    /// `isSettling == false` forever — the commit/cancel completion + fallback
    /// cleanups only cover settling states. While it's stuck, every tab except
    /// the swipe's source/target renders at opacity 0 regardless of selection:
    /// the "all tabs but one stop rendering, input still lands" freeze.
    ///
    /// Mirrors the cancel-path `finish` cleanup: re-occlude the target (unless
    /// it's now the selected tab) and release both tabs' selection-handle
    /// suppression. The normal selection paths re-assert the selected tab's
    /// visibility afterwards.
    func forceClearAppTabSwipe(reason: String) {
        guard let state = appTabSwipeState else { return }
        let ageMs = (CACurrentMediaTime() - state.lastEventAt) * 1000
        appTabSwipeState = nil
        if tabsModel.selectedTabID != state.targetTabID {
            setTabOcclusion(tabID: state.targetTabID, visible: false)
        }
        #if !targetEnvironment(macCatalyst)
        setTabSelectionUISwipeSuppressed(state.sourceTabID, false)
        setTabSelectionUISwipeSuppressed(state.targetTabID, false)
        #endif
        LifecycleDebugLogger.shared.checkpoint("FG.appTabSwipe.forceClear", ms: nil, [
            ("reason", reason),
            ("source", String(state.sourceTabID.uuidString.prefix(8))),
            ("target", String(state.targetTabID.uuidString.prefix(8))),
            ("settling", state.isSettling),
            ("ageMs", Int(ageMs)),
        ])
    }

    func setTabOcclusion(tabID: UUID, visible: Bool) {
        guard let tab = tabsModel.tab(withID: tabID) else { return }
        for terminal in tab.splitTree {
            terminal.setOcclusion(visible)
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// Suppress (or restore) touch-selection handles on a tab's terminals for
    /// the duration of an app-tab swipe slide. The handles are window-anchored
    /// and can't follow the SwiftUI `.offset(x:)` slide, so presenting them
    /// mid-slide puts them in the wrong place; we hide them while the content
    /// moves and recreate them at the settled position once it lands — they
    /// appear once, correctly placed, with no wrong-place flash.
    private func setTabSelectionUISwipeSuppressed(_ tabID: UUID, _ suppressed: Bool) {
        guard let tab = tabsModel.tab(withID: tabID) else { return }
        for terminal in tab.splitTree.terminalLeaves {
            terminal.setSelectionUISwipeSuppressed(suppressed)
        }
    }
    #endif

    /// Drives a tab-bar selection change. The mutation is unanimated globally
    /// so the terminal-content opacity flip in `MainViewTerminalContent`'s
    /// `ForEach` is instant. The tab-bar's Liquid Glass selection slide is
    /// driven by a scoped `.animation(value: selectedTabID)` modifier inside
    /// `TabBar`, so the indicator still animates without leaking a transaction
    /// into the rest of the view tree.
    private func applyTabSwitch(toTabID id: UUID) {
        guard tabsModel.selectedTabID != id else { return }
        tabsModel.selectedTabID = id
    }
}

// MARK: - Sheet Presentation Focus Plumbing

extension MainView {

    /// Resign first responder when sheets are presented to prevent keyboard from appearing
    /// This fixes the issue where the virtual keyboard appears in settings sheets
    func resignFirstResponderForSheetPresentation() {
        // Per-sheet onChange handlers can run before the isAnySheetPresented
        // handler; run the full terminal gate here first (idempotent) so both
        // the keyboard-preservation latch and the per-terminal toolbar-reserve
        // snapshot happen while the terminal is still first responder — the
        // global resign below would otherwise land before either.
        if isAnySheetPresented {
            setOverlayOwnsKeyboardForAllTerminals(true)
        }
        #if !targetEnvironment(macCatalyst)
        setSelectionUIOccludedByPresentation(true)
        #endif
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    #if !targetEnvironment(macCatalyst)
    func setSelectionUIOccludedByPresentation(_ occluded: Bool) {
        for tab in terminals {
            for terminal in tab.splitTree.terminalLeaves {
                terminal.setSelectionUIExternallyOccluded(occluded)
            }
        }
    }
    #endif

    /// Push the per-window keyboard-ownership gate to every terminal in this
    /// window. While an overlay (tab sidebar, connection sidebar, any sheet)
    /// owns the keyboard, terminals refuse first responder so the overlay's own
    /// field holds it without contention — and they re-grant it deterministically
    /// when the gate drops. Scoped to this scene's `terminals`, so multi-window
    /// stays correct. Driven by the single `onChange(of: isAnySheetPresented)`.
    func setOverlayOwnsKeyboardForAllTerminals(_ owns: Bool) {
        // Freeze the reported software-keyboard layout before the resign below
        // hides the keyboard, so terminal bounds hold steady across the overlay
        // round trip (zero PTY resizes when nothing changed). Owner-scoped per
        // window (tabsModel + this window's UIWindow) so keyboard activity in
        // another window is never mistaken for ours; released with a settle
        // window on close, and the re-show refreshes geometry if it changed.
        if owns {
            let hostWindow = overlayPreservationHostWindow
            #if !targetEnvironment(macCatalyst)
            // A nil host window with every tab on the external display would
            // arm the latch unresolved (true for EVERY window). Parked external
            // content has no device keyboard to preserve either; only control
            // mode does. The general nil-window fallback stays for cold start.
            let externalActive = ExternalDisplayManager.shared.isExternalSessionActive
            let skipArming =
                (hostWindow == nil && externalActive && terminals.isEmpty) ||
                (isExternalDisplayWindow && !ExternalDisplayManager.shared.isControlSurfaceActive)
            #else
            let skipArming = false
            #endif
            if !skipArming {
                KeyboardTracker.shared.beginOverlayKeyboardPreservation(
                    owner: tabsModel,
                    window: hostWindow
                )
            }
        } else {
            KeyboardTracker.shared.endOverlayKeyboardPreservation(owner: tabsModel)
        }
        // Single source of truth for "an overlay owns the keyboard in this
        // window", kept in lockstep with the per-terminal gate. Focus paths
        // that run for terminals created WHILE an overlay is open read this to
        // initialize the new terminal's gate before its first focus attempt.
        tabsModel.overlayOwnsKeyboard = owns
        for tab in terminals {
            for terminal in tab.splitTree {
                terminal.setOverlayOwnsKeyboard(owns)
            }
        }
    }

    /// This window's UIWindow, resolved from any mounted pane. Used to scope
    /// the keyboard-preservation latch to this window without isKeyWindow
    /// scans (unreliable on iPadOS multi-window). Internal: the terminal
    /// content layout reads it to window-scope the safe-area compensation.
    var overlayPreservationHostWindow: UIWindow? {
        for tab in terminals {
            for pane in tab.splitTree {
                if let window = pane.window { return window }
            }
        }
        return nil
    }

    /// Restore first responder to the terminal after a sheet is dismissed
    func restoreFirstResponderAfterSheetDismissal(includeCatalystDismissalRetry: Bool = false) {
        restoreTerminalFirstResponderIfPossible()

        #if targetEnvironment(macCatalyst)
        if includeCatalystDismissalRetry {
            // Matches the transfer-sheet focus recovery pattern: on Catalyst,
            // sheet/key-command teardown can still own the responder chain when
            // the binding flips back to false, so retry after the dismissal
            // animation has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                restoreTerminalFirstResponderIfPossible()
            }
        }
        #endif

        resyncSelectionHandlesAfterTransientOcclusion()

        func restoreTerminalFirstResponderIfPossible() {
            guard !isAnySheetPresented,
                  terminals.indices.contains(selectedTabIndex),
                  let terminal = terminals[selectedTabIndex].focusedTerminal,
                  terminal.isLogicallyFocused,
                  !terminal.isFirstResponder else { return }

            if terminal.becomeFirstResponder() {
                terminal.reloadInputViews()
            }
        }
    }

    /// Restore first responder after a passthrough HUD is dismissed.
    ///
    /// Regular-width HUDs are intentionally excluded from `isAnySheetPresented`
    /// so they do not force the terminal to resign while open. If one of their
    /// text fields becomes first responder, closing the HUD therefore needs its
    /// own hand-off back to the focused terminal. A few short retries cover the
    /// run-loop where SwiftUI is still tearing down the focused text field.
    func restoreFirstResponderAfterHUDDismissal() {
        let delays: [TimeInterval] = [0, 0.02, 0.08, 0.18]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !isAnySheetPresented,
                      !showClipboardManager,
                      terminals.indices.contains(selectedTabIndex),
                      let terminal = terminals[selectedTabIndex].focusedTerminal,
                      terminal.isLogicallyFocused,
                      !terminal.isFirstResponder else { return }
                _ = terminal.reassertFirstResponderIfFocused()
            }
        }
    }

    func resyncSelectionHandlesAfterTransientOcclusion() {
        #if !targetEnvironment(macCatalyst)
        // Settings uses a fullScreenCover on iPad, and UIKit can keep the
        // presented controller attached past the first few run-loop turns.
        let delays: [TimeInterval] = [0, 0.1, 0.35, 0.7, 1.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !isAnySheetPresented,
                      lifecycleScenePhase == .active,
                      selectedTabIndex >= 0,
                      selectedTabIndex < terminals.count else { return }
                for terminal in terminals[selectedTabIndex].splitTree.terminalLeaves {
                    terminal.scheduleSelectionHandleSync(afterGhosttyAppTick: true)
                }
            }
        }
        #endif
    }

    func refreshSelectionAfterExternalTabMutation(allowFocus: Bool) {
        guard !terminals.isEmpty else { return }
        tabsModel.repairSelectionIfNeeded()
        guard let selectedID = tabsModel.selectedTabID,
              let selectedIndex = tabsModel.index(of: selectedID),
              terminals.indices.contains(selectedIndex) else {
            return
        }

        tabsModel.displayedTabID = selectedID
        for (index, tab) in terminals.enumerated() {
            let isSelected = index == selectedIndex
            for terminal in tab.splitTree {
                terminal.setOcclusion(isSelected)
            }
        }

        let selectedTab = terminals[selectedIndex]
        let focus = selectedTab.focusedPane ?? selectedTab.splitTree.first
        selectedTab.focusedPane = focus

        var newFocusAcquired = false
        if let focus {
            focus.isLogicallyFocused = true
            focus.asTerminal?.shouldBecomeFirstResponderWhenReady = true
            focus.setOverlayOwnsKeyboard(isAnySheetPresented)
            if allowFocus,
               !(showingTabSwitcher && !tabSidebarDismissesOnSelect && !tabSidebarIsDocked) {
                newFocusAcquired = focus.focusDidChange(true)
                if !newFocusAcquired {
                    focus.asTerminal?.shouldBecomeFirstResponderWhenReady = true
                }
            }
            if allowFocus, let terminal = focus.asTerminal, terminal.isTmuxPane {
                terminal.requestTmuxSelectPane()
            }
        }

        for (index, tab) in terminals.enumerated() where index != selectedIndex {
            if let oldFocus = tab.focusedPane {
                oldFocus.focusDidChange(false, skipResign: newFocusAcquired)
                oldFocus.isLogicallyFocused = false
            }
        }

        ghosttyApp.appTick()
    }
}
