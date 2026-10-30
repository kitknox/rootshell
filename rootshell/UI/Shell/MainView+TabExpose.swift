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
            integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabHeader ? integratedTabJoin : nil,
            width: width
        )
        // Above ordinary siblings in the content ZStack (SwiftUI-drawn fills
        // and re-inserted platform views alike), independent of insertion
        // order. The persistent background-effect layer intentionally rises
        // one level higher while the exposé is active.
        .zIndex(1)
        .onAppear {
            installTabExposeHooks()
            installTabHoverPreviewHooks()
        }
    }

    /// Text Above Effect: where the exposé backdrop goes, beneath the
    /// background effect. Framed exactly like `tabExposeHost`.
    @ViewBuilder
    func tabExposeBackdropHost(width: CGFloat) -> some View {
        TabExposeBackdropContainer(controller: tabExpose)
            .frame(width: width)
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            .ignoresSafeArea(.container, edges: .bottom)
            #endif
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func tabExposeConfiguration() -> TabExposeView.Configuration {
        var config = TabExposeView.Configuration()
        config.gestureEnabled = { TabExposeSettings.gestureEnabled() }
        config.canBeginReveal = { !isAnySheetPresented && appTabSwipeState == nil }
        // Nothing above the terminal: let the pull start in its top strip.
        config.fallbackBandHeight = { showsHorizontalTabHeader ? 0 : 28 }
        // The top bar spans the full window even when a pinned vertical tab
        // sidebar shifts this terminal-hosted overlay to the right.
        config.topBarActivationSpansWindowWidth = { showsHorizontalTabHeader }
        #if !targetEnvironment(macCatalyst)
        // Touch: one finger from the tab bar strip itself.
        config.oneFingerBandHeight = { showsHorizontalTabHeader ? TabMetrics.tabBarHeight : 0 }
        #endif
        return config
    }

    /// Text Above Effect: mirrors paint each pane's background, and the
    /// preview's fill shows between them, in the tab's own theme.
    func glyphOnlyMirrorBackgrounds() -> [UUID: UIColor] {
        var colors: [UUID: UIColor] = [:]
        for tab in terminals {
            let themeName = ThemeOverrideManager.shared.resolveTheme(tabId: tab.id, windowId: windowId).themeName
            if let hex = ThemeManager.shared.themeInfo(for: themeName)?.colors.background,
               let color = UIColor(hex: hex) {
                colors[tab.id] = color
            }
        }
        return colors
    }

    private func tabExposeAppearance() -> TabExposeView.Appearance {
        var appearance = TabExposeView.Appearance()
        let theme = resolvedTabBarTheme()
        if let hex = effectiveThemeColors?.background, let color = UIColor(hex: hex) {
            appearance.backgroundColor = color
        } else {
            appearance.backgroundColor = UIColor(theme.tabBarBackground)
        }
        // The backdrop stands in for the terminal's card: its fill, opacity,
        // corners and rim.
        appearance.backgroundOpacity = transparencyManager.effectiveBackgroundOpacity
        if effectManager.isTextAboveEffectActive {
            appearance.glyphOnlyMirrors = true
            appearance.tabBackgroundColors = glyphOnlyMirrorBackgrounds()
        }
        appearance.cornerRadius = roundedPanes ? PaneCardStyle.cornerRadius : 0
        appearance.rimPalette = roundedPanes ? theme.integratedEdgePalette : nil
        appearance.textColor = UIColor(theme.tabText)
        if let accent = sheetAccentColor {
            appearance.accentColor = UIColor(accent)
        }
        appearance.showsCaptions = TabExposeSettings.showsCaptions()
        let palette = TmuxTabBadgePalette(theme: theme)
        let textColor = theme.tabText
        let compact = workspaceSizeClass != .regular
        let attentionDots = SettingsStore.shared.get(Settings.CodingAgents.attentionBadges)
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
                    showsAttentionDot: attentionDots,
                    logoSize: 13
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 4)
            )
        }
        appearance.muxCaptionProvider = { tab, index in
            AnyView(
                MuxTabCaption(
                    tab: tab,
                    keyboardShortcut: compact ? nil : keyboardShortcut(for: index),
                    titleFont: .system(size: compact ? 12 : 13, weight: .semibold),
                    shortcutFont: .system(size: compact ? 11 : 12, weight: .medium),
                    textColor: textColor.opacity(0.85)
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
        tabExpose.muxFeed = muxExposeFeed
        let controller = tabExpose
        muxExposeFeed.onChange = {
            controller.muxFeedDidChange()
            muxPanelRevision &+= 1
        }
        tabExpose.multiplexerTerminal = {
            let tab = tabsModel.selectedTab
            return tab?.focusedPane?.asTerminal ?? tab?.splitTree.terminalLeaves.first
        }
        tabExpose.reduceMotion = {
            SettingsStore.shared.value(Settings.Tabs.barAnimationsDisabled) || UIAccessibility.isReduceMotionEnabled
        }
        tabExpose.onWillPresent = { _ in
            // Renderers wake per on-screen cell through onLiveTabsChanged;
            // waking a whole large scope at once exhausts memory.
            installTabExposeKeyHandler()
        }
        tabExpose.onLiveTabsChanged = { woken, parked in
            // Park first so released swap chains never overlap new ones. The
            // secure-draw latch may drop the wakes; the foreground reconcile
            // re-asserts them (it treats live exposé tabs as visible).
            var keep: Set<UUID> = Set([tabsModel.selectedTabID, tabsModel.displayedTabID,
                                       tabExpose.heroTabID, tabHoverPreview.previewedTabID].compactMap { $0 })
            if let swipe = appTabSwipeState {
                keep.formUnion([swipe.sourceTabID, swipe.targetTabID])
            }
            for id in parked where !keep.contains(id) { setTabOcclusion(tabID: id, visible: false) }
            for id in woken { setTabOcclusion(tabID: id, visible: true) }
        }
        tabExpose.onDidDismiss = {
            removeTabExposeKeyHandler()
            reconcileSurfaceOcclusion(reason: "tabExpose")
            reassertSelectedTabVisibility(reason: "tabExpose")
        }
        tabExpose.onNavigateScope = { delta in navigateAppScope(by: delta) }
        tabExpose.onScopePreviewChanged = { _ in
            // The neighbor's on-screen mirrors wake through onLiveTabsChanged;
            // the reconcile re-occludes a preview that was replaced or ended.
            reconcileSurfaceOcclusion(reason: "tabExposePreview")
        }
        tabExpose.onScopeDidChange = { _ in
            // Newcomers wake as their cells come on screen; the reconcile
            // re-occludes leavers (it treats live exposé tabs as visible).
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
    /// with one scope. While the exposé is up it stays up and pages over,
    /// the multiplexer page included.
    func navigateScope(by delta: Int) {
        if tabExpose.isActive {
            tabExpose.navigateScope(by: delta)
            return
        }
        navigateAppScope(by: delta)
    }

    /// The app-scope half of `navigateScope`: select a tab in the neighbor
    /// group / project.
    private func navigateAppScope(by delta: Int) {
        guard let id = tabsModel.firstTabIDInNeighborScope(offset: delta) else { return }
        if tabBarHidden && id != tabsModel.selectedTabID {
            tabIndicator.suppressNextHiddenIndicator = tabExpose.isActive
        }
        selectTab(id: id)
    }

    func toggleTabExpose() {
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

/// Caption under a multiplexer tab cell: shortcut, title, and the tab's
/// badge (tmux flags, herdr agent status).
private struct MuxTabCaption: View {
    let tab: MuxTab
    let keyboardShortcut: String?
    let titleFont: Font
    let shortcutFont: Font
    let textColor: Color

    var body: some View {
        HStack(spacing: 5) {
            if let keyboardShortcut {
                Text(keyboardShortcut)
                    .font(shortcutFont)
                    .foregroundStyle(textColor.opacity(0.6))
            }
            Text(tab.title)
                .font(titleFont)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge = tab.badge, !badge.isEmpty {
                Text(badge)
                    .font(shortcutFont)
                    .foregroundStyle(textColor.opacity(0.6))
            }
        }
    }
}

/// Keeps the safe-area modifier behind a nominal view boundary. Inlining this
/// extra generic layer into terminalContentZStack's already-large ViewBuilder
/// can produce invalid AttributeGraph metadata on iOS during the first render.
private struct TabExposeBackdropContainer: UIViewRepresentable {
    let controller: TabExposeController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        controller.backdropHost = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if controller.backdropHost !== view { controller.backdropHost = view }
    }
}

private struct TabExposeSafeAreaHost: View {
    let controller: TabExposeController
    let configuration: TabExposeView.Configuration
    let appearance: TabExposeView.Appearance
    let integratedTabJoin: IntegratedTabJoin?
    let width: CGFloat

    var body: some View {
        TabExposeHost(
            controller: controller,
            configuration: configuration,
            appearance: appearance,
            integratedTabJoin: integratedTabJoin
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
