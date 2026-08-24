//
//  MainView+TabExpose.swift
//  rootshell
//
//  Hosts the tab exposé over the terminal content area and wires its
//  controller to this window's tabs: occlusion while presented, the real
//  tab switch on select, key routing from the focused terminal.
//

import SwiftUI
import UIKit

extension MainView {

    /// Top layer of `terminalContentZStack`; always mounted, inert while hidden.
    @ViewBuilder
    func tabExposeHost(geometry: GeometryProxy, width: CGFloat) -> some View {
        TabExposeSafeAreaHost(
            controller: tabExpose,
            configuration: tabExposeConfiguration(),
            appearance: tabExposeAppearance(),
            width: width
        )
        // Above every sibling in the content ZStack (SwiftUI-drawn fills and
        // re-inserted platform views alike), independent of insertion order.
        .zIndex(1)
        .onAppear { installTabExposeHooks() }
    }

    private func tabExposeConfiguration() -> TabExposeView.Configuration {
        var config = TabExposeView.Configuration()
        config.gestureEnabled = { TabExposeSettings.gestureEnabled() }
        config.canBeginReveal = { !isAnySheetPresented && appTabSwipeState == nil }
        // Nothing above the terminal: let the pull start in its top strip.
        config.fallbackBandHeight = { tabBarHidden ? 28 : 0 }
        #if !targetEnvironment(macCatalyst)
        // Touch: one finger from the tab bar strip itself.
        config.oneFingerBandHeight = { tabBarHidden ? 0 : TabMetrics.tabBarHeight }
        #endif
        return config
    }

    private func tabExposeAppearance() -> TabExposeView.Appearance {
        var appearance = TabExposeView.Appearance()
        let theme = resolvedTabBarTheme()
        if let hex = effectiveThemeColors?.background, let color = UIColor(hex: hex) {
            appearance.backgroundColor = color
        } else {
            appearance.backgroundColor = UIColor(theme.tabBarBackground)
        }
        #if targetEnvironment(macCatalyst)
        // Keep the window's transparency through the reveal.
        appearance.backgroundOpacity = transparencyManager.backgroundOpacity
        #endif
        appearance.textColor = UIColor(theme.tabText)
        if let accent = sheetAccentColor {
            appearance.accentColor = UIColor(accent)
        }
        appearance.showsCaptions = TabExposeSettings.showsCaptions()
        let palette = TmuxTabBadgePalette(theme: theme)
        let textColor = theme.tabText
        let compact = UIDevice.current.userInterfaceIdiom == .phone
        let attentionDots = UserDefaults.standard.object(forKey: AgentAttentionSettings.badgesEnabledKey) as? Bool ?? true
        appearance.captionProvider = { tab, index in
            AnyView(
                TabTitleLine(
                    tab: tab,
                    allTabs: terminals,
                    tmuxBadgePalette: palette,
                    keyboardShortcut: compact ? nil : keyboardShortcut(for: index),
                    titleFont: .system(size: compact ? 12 : 13, weight: .semibold),
                    shortcutFont: .system(size: compact ? 11 : 12, weight: .medium),
                    textColor: textColor.opacity(0.85),
                    showsBadges: !compact,
                    showsAttentionDot: attentionDots
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 4)
            )
        }
        return appearance
    }

    /// One-time wiring; the closures read live state through the property wrappers.
    func installTabExposeHooks() {
        tabExpose.tabsModel = tabsModel
        tabExpose.reduceMotion = {
            UserDefaults.standard.bool(forKey: "tabBarAnimationsDisabled") || UIAccessibility.isReduceMotionEnabled
        }
        tabExpose.onWillPresent = { ids in
            // Wake every scope tab's renderer so the mirrors are live. The
            // secure-draw latch may drop these; the foreground reconcile
            // re-asserts them (it treats exposé tabs as visible).
            for id in ids { setTabOcclusion(tabID: id, visible: true) }
            installTabExposeKeyHandler()
        }
        tabExpose.onDidDismiss = {
            removeTabExposeKeyHandler()
            reconcileSurfaceOcclusion(reason: "tabExpose")
            reassertSelectedTabVisibility(reason: "tabExpose")
        }
        tabExpose.onNavigateScope = { delta in navigateScope(by: delta) }
        tabExpose.onScopePreviewChanged = { ids in
            // A group swipe drags the neighbor's live mirrors in: wake them;
            // the reconcile re-occludes a preview that was replaced or ended.
            for id in ids { setTabOcclusion(tabID: id, visible: true) }
            reconcileSurfaceOcclusion(reason: "tabExposePreview")
        }
        tabExpose.onScopeDidChange = { ids in
            // Newcomers must render live; the reconcile re-occludes leavers
            // (it treats the controller's current scope as visible).
            for id in ids { setTabOcclusion(tabID: id, visible: true) }
            reconcileSurfaceOcclusion(reason: "tabExposeScope")
            // A scope switch selects a tab in the new scope: the key hook must
            // move to that terminal or navigation keys leak into it.
            removeTabExposeKeyHandler()
            installTabExposeKeyHandler()
        }
        tabExpose.onSelect = { id in
            if tabBarHidden && id != tabsModel.selectedTabID {
                tabIndicator.suppressNextHiddenIndicator = true
            }
            selectTab(id: id)
        }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        tabExpose.onCommitHaptic = {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    /// Switch the active group / project by `delta` (wraps). Lands on the
    /// scope's remembered (else first navigable) tab; no-op in flat mode or
    /// with one scope. While the exposé is up it stays up and pages over.
    func navigateScope(by delta: Int) {
        guard let id = tabsModel.firstTabIDInNeighborScope(offset: delta) else { return }
        if tabExpose.isActive { tabExpose.pendingScopeTransition = delta }
        if tabBarHidden && id != tabsModel.selectedTabID {
            tabIndicator.suppressNextHiddenIndicator = tabExpose.isActive
        }
        selectTab(id: id)
    }

    func toggleTabExpose() {
        #if !targetEnvironment(macCatalyst)
        // Parked external content is not interactive; only control mode.
        guard !isExternalDisplayWindow || ExternalDisplayManager.shared.isControlSurfaceActive else { return }
        #endif
        guard !isAnySheetPresented || tabExpose.isActive else { return }
        if !tabExpose.isActive, showingTabSwitcher, !tabSidebarIsDocked {
            showingTabSwitcher = false
        }
        tabExpose.toggle()
    }

    // MARK: - Keys (the terminal stays first responder)

    private func installTabExposeKeyHandler() {
        let tab = tabsModel.selectedTab
        let focused = tab?.focusedPane
        // Hook the focused terminal; with no focus yet, any terminal in the tab.
        // A focused non-terminal pane (VNC) owns the keys, so never hook an
        // unfocused sibling terminal in its place.
        let terminal: Ghostty.TerminalView? = focused.map { $0.asTerminal } ?? tab?.splitTree.terminalLeaves.first
        guard let terminal else {
            // Non-terminal focus (VNC): the exposé view takes first responder
            // itself and the pane yields keyboard capture meanwhile.
            tabExpose.wantsFirstResponderFallback = true
            focused?.setOverlayOwnsKeyboard(true)
            return
        }
        tabExpose.wantsFirstResponderFallback = false
        let controller = tabExpose
        terminal.presentedOverlayKeyHandler = { key in
            guard controller.isActive else { return false }
            if key.isModifierOnly { return false }
            if controller.handleKey(key) { return true }
            // App shortcuts (⌘-chords such as group navigation) run without
            // closing the exposé; any other key dismisses it and passes through.
            if key.modifiers.contains(.command) { return false }
            controller.cancel()
            return false
        }
        tabExpose.keyHandlerTerminal = terminal
    }

    private func removeTabExposeKeyHandler() {
        tabExpose.keyHandlerTerminal?.presentedOverlayKeyHandler = nil
        tabExpose.keyHandlerTerminal = nil
        if tabExpose.wantsFirstResponderFallback {
            tabExpose.wantsFirstResponderFallback = false
            if let focused = tabsModel.selectedTab?.focusedPane {
                focused.setOverlayOwnsKeyboard(isAnySheetPresented)
                _ = focused.focusDidChange(true)
            }
        }
    }
}

/// Keeps the safe-area modifier behind a nominal view boundary. Inlining this
/// extra generic layer into terminalContentZStack's already-large ViewBuilder
/// can produce invalid AttributeGraph metadata on iOS during the first render.
private struct TabExposeSafeAreaHost: View {
    let controller: TabExposeController
    let configuration: TabExposeView.Configuration
    let appearance: TabExposeView.Appearance
    let width: CGFloat

    var body: some View {
        TabExposeHost(
            controller: controller,
            configuration: configuration,
            appearance: appearance
        )
        .frame(width: width)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Match terminalTabsView's container escape so the opaque exposé
        // surface owns every pixel the terminal can draw in the bottom safe
        // area. The wrapper remains inside the terminal column, leaving
        // adjacent sidebars and the tab bar untouched.
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}
