//
//  MainView+TabBar.swift
//  rootshell
//
//  Tab bar width calculation logic for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import os

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tab Bar Display Mode

extension MainView {

    /// Display mode for the tab bar, determining layout strategy
    enum TabBarDisplayMode: Equatable {
        case singleTab      // Centered title only
        case equalWidth     // Equal-width tabs filling space
        case scrolling      // Scrollable tabs when overflow occurs
    }

    /// Width reserved for action buttons (plus + settings)
    static let actionButtonsWidth: CGFloat = TabMetrics.tabBarHeight * 2

    static let integratedMaximumTabWidth: CGFloat = 240
    static let catalystWindowDragWidth: CGFloat = 42

    /// Usable width for tab items after fixed leading chrome and trailing
    /// action buttons are reserved. Per-tab display mode decisions live in
    /// `TabBar`, where reading title/badge/health metadata does not invalidate
    /// `MainView.body`.
    func availableTabBarWidth(in geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - Self.actionButtonsWidth - edgeSidebarHeaderButtonWidth - tabBarLeadingPadding)
    }

    /// Width of the compact tab viewport. Capped tabs leave real flexible
    /// space after the new-tab button instead of stretching across the window.
    func integratedTabTrackWidth(in geometry: GeometryProxy) -> CGFloat {
        let tabCount = tabsModel.navigationTabs.count
        guard tabCount > 0 else { return 0 }

        // The scope menu may sit inside the card inset, over the pinned sidebar.
        let scopeWidth = integratedScopeMenuWidth > 0 ? integratedScopeMenuWidth + integratedScopeMenuLeadingInset : 0
        let leadingWidth = max(scopeWidth, integratedCardLeadingInset(windowWidth: geometry.size.width))
        let preferred = CGFloat(tabCount) * Self.integratedMaximumTabWidth + leadingWidth
        var capacity = max(
            0,
            geometry.size.width
                - tabBarLeadingPadding
                - Self.actionButtonsWidth
                - edgeSidebarHeaderButtonWidth
                - integratedMinimumDragWidth
        )
        if topTabStyle == .integrated {
            // End the track at the terminal so trailing columns (AI agent,
            // file manager) scroll the selected tab back over the surface it
            // joins.
            let columns = terminalRowColumns(width: geometry.size.width)
            let cardGap: CGFloat = roundedPanes ? PaneCardStyle.gap : 0
            let corner: CGFloat = roundedPanes ? PaneCardStyle.cornerRadius : 0
            let cardMaxX = cardGap + self.leadingWidth(in: columns) + columns.terminal
            capacity = min(capacity, max(0, cardMaxX - corner - tabBarLeadingPadding))
        }
        return min(preferred, capacity)
    }

    /// Rounded Panes splits the surface into cards, so the selected Integrated
    /// tab must join the one below it rather than bridge a gap.
    var integratedTabsJoinCards: Bool {
        roundedPanes && topTabStyle == .integrated
    }

    /// Extra lead that starts Integrated tabs over the terminal, past the
    /// pinned sidebar and, under Rounded Panes, the card's corner.
    func integratedCardLeadingInset(windowWidth: CGFloat) -> CGFloat {
        guard topTabStyle == .integrated else { return 0 }
        let cardMinX = (roundedPanes ? PaneCardStyle.gap : 0) + leadingChromeWidth(windowWidth: windowWidth)
        guard cardMinX > 0 else { return 0 }
        let corner: CGFloat = roundedPanes ? PaneCardStyle.cornerRadius : 0
        return max(0, cardMinX + corner - tabBarLeadingPadding)
    }

    /// The selected Integrated tab windows the terminal's background effect.
    var integratedTabWindowsEffect: Bool {
        topTabStyle == .integrated && showsHorizontalTabHeader
            && effectManager.activeEffect != nil && visibleContentAllowsTerminalEffects
    }

    /// What the selected Integrated tab paints: the panes on screen beneath
    /// it, or the full-size panel or exposé backdrop covering them.
    func integratedTabSurfaceFill(theme: ResolvedTabBarTheme) -> IntegratedTabSurfaceFill? {
        guard topTabStyle == .integrated else { return nil }
        let style = integratedSurfaceStyle()
        var override: Color?
        if tabExpose.isActive {
            override = style.color(for: effectiveThemeColors.flatMap { Color(hex: $0.background) } ?? theme.tabBarBackground)
        } else if integratedTabCoversFullPanel {
            override = resolvedSheetTheme().panelFill
        }
        // The terminal on screen lags the selection until its first frame.
        let tabIDs: [UUID] = appTabSwipeState.map { [$0.sourceTabID, $0.targetTabID] }
            ?? (tabsModel.displayedTabID ?? tabsModel.selectedTabID).map { [$0] } ?? []
        return IntegratedTabSurfaceFill(
            surface: integratedTabSurface,
            tabIDs: tabIDs,
            style: style,
            override: override)
    }

    private var integratedTabCoversFullPanel: Bool {
        #if !CHINA_BUILD
        if httpCaptureShowsOverlay && httpCapturePresentation == .full { return true }
        #endif
        return fileManagerShowsOverlay && fileManagerPresentation == .full
    }

    /// Rounded Panes: OSC progress runs along the terminal card's straight
    /// top edge, in header coordinates.
    func integratedProgressSpan(rowWidth: CGFloat) -> ClosedRange<CGFloat>? {
        guard integratedTabsJoinCards else { return nil }
        let columns = terminalRowColumns(width: rowWidth)
        let cardMinX = PaneCardStyle.gap + columns.docked
        let minX = cardMinX + PaneCardStyle.cornerRadius
        let maxX = cardMinX + columns.terminal - PaneCardStyle.cornerRadius
        return minX < maxX ? minX...maxX : nil
    }

    /// Starts the scope menu at the cards' leading edge, in line with the
    /// pinned sidebar card.
    var integratedScopeMenuLeadingInset: CGFloat {
        integratedTabsJoinCards ? max(0, PaneCardStyle.gap - tabBarLeadingPadding) : 0
    }

    private var integratedScopeMenuWidth: CGFloat {
        guard showTabScopeMenu,
              tabsModel.orderProjection.mode != .flat,
              let title = tabsModel.orderProjection.activeScopeTitle else { return 0 }
        return tabScopeMenuSize.labelWidth(for: title)
    }

    var integratedMinimumDragWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        return (usesTitlebarTabs || hideWindowTitleBar)
            ? Self.catalystWindowDragWidth
            : 0
        #else
        return 0
        #endif
    }
}

// MARK: - Tab Bar Content and Tab Helpers

extension MainView {

    // MARK: - Tab Theme Override Helper

    /// Check if a tab has a theme override applied
    func tabHasThemeOverride(_ tabId: UUID) -> Bool {
        themeOverrideManager.hasTabOverride(tabId: tabId)
    }

    // MARK: - Tab Keyboard Shortcut Helper

    /// Returns keyboard shortcut string for a tab at the given index
    /// Only returns shortcuts for tabs 1-9 when the setting is enabled
    func keyboardShortcut(for index: Int) -> String? {
        guard showTabShortcutIndicators, index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    // MARK: - Tab Bar Content

    /// Build tab bar content based on display mode.
    ///
    /// All per-tab Observation reads (`tab.title`, `tab.connectionHealth`,
    /// `tab.activeRoamProtocol`) live inside `TabBar.body`, NOT here, so
    /// network-driven mutations (OSC 0/2 title sequences during reconnect,
    /// keepalive ping health updates, embedded mosh/trzsz session-change
    /// notifications) only invalidate `TabBar.body` and do not propagate
    /// up to MainView. The whole crash family in this project's IPS files
    /// (varying frames; common root: scene-update transactions blow the
    /// 10s/30s FrontBoard budget when MainView re-evaluates) hinges on
    /// this decoupling.
    /// The compact track caps at the space left after fixed controls. A cap,
    /// not a fixed width: outer modifiers inset the row below what the proxy
    /// reports, and a rigid frame pushed the buttons off-window.
    @ViewBuilder
    func tabBarTrack(in geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        if usesCompactTabSpacing {
            let preferredWidth = integratedTabTrackWidth(in: geometry)
            let tabsLeadingInset = integratedCardLeadingInset(windowWidth: geometry.size.width)
            GeometryReader { trackGeometry in
                tabBarContent(
                    availableWidth: trackGeometry.size.width,
                    tabsLeadingInset: tabsLeadingInset,
                    scopeMenuLeadingInset: integratedScopeMenuLeadingInset,
                    theme: theme
                )
            }
            .frame(maxWidth: preferredWidth, alignment: .leading)
            .frame(height: TabMetrics.tabBarHeight)
        } else {
            tabBarContent(
                availableWidth: availableTabBarWidth(in: geometry),
                theme: theme
            )
        }
    }

    @ViewBuilder
    private func tabBarContent(
        availableWidth: CGFloat,
        tabsLeadingInset: CGFloat = 0,
        scopeMenuLeadingInset: CGFloat = 0,
        theme: ResolvedTabBarTheme
    ) -> some View {
        TabBar(
            theme: theme,
            availableWidth: availableWidth,
            style: topTabStyle,
            usesCompactSpacing: usesCompactTabSpacing,
            selectedStyleRawValue: topTabStyleRawValueBinding,
            tabsModel: tabsModel,
            selectedTabIndex: Binding(
                get: { selectedTabIndex },
                set: { newIndex in
                    selectedTabIndex = newIndex
                }
            ),
            windowId: windowId,
            usesTitlebarTabs: topTabBarAttachedToWindow,
            sshHealthMonitoringEnabled: sshHealthMonitoringEnabled,
            tabNamespace: tabNamespace,
            canAcceptWindowTransferDrop: tabTransferDropOverlayVisible,
            suppressSelectionAnimation: tabIndicator.suppressNextSelectionAnimation,
            tabsLeadingInset: tabsLeadingInset,
            scopeMenuLeadingInset: scopeMenuLeadingInset,
            wigglingTabIds: $wigglingTabIds,
            tabFrames: $tabFrames,
            onCloseTab: { index in requestUserCloseTab(at: index) },
            onMoveTab: { from, to in moveTab(from: from, to: to) },
            onSelectTab: { index in
                guard index != selectedTabIndex else { return }
                if tabBarAnimationsDisabled || UIAccessibility.isReduceMotionEnabled {
                    selectedTabIndex = index
                } else {
                    withAnimation(TabBar.selectionAnimation) {
                        selectedTabIndex = index
                    }
                }
            },
            keyboardShortcut: { index in keyboardShortcut(for: index) },
            onTabHover: { id, isHovered in
                tabHover.handleHover(tabId: id, isHovered: isHovered)
                tabHoverPreview.handleHover(tabID: id, source: .topBar, isHovered: isHovered)
            },
            previewAnchors: tabHoverPreview.anchors,
            tabHasThemeOverride: { id in tabHasThemeOverride(id) },
            onClearThemeOverride: { id in themeOverrideManager.clearTabOverride(tabId: id) },
            onShowConnectionInfo: { tab in showConnectionInfo(for: tab) },
            canTransferToNearby: { tab in canTransferTabToNearby(tab) },
            onTransferToNearby: { tab in transferTabToNearby(tab) },
            onMoveTabToNewWindow: { tab in moveTabToNewWindow(tab) },
            onMoveTabsToNewWindow: { ids in moveTabsToNewWindow(ids) },
            onNewTmuxWindow: { tab in requestTmuxNewWindow(for: tab) },
            onShowTmuxSessions: { tab in showTmuxSessions(for: tab) },
            tmuxController: { tab in tmuxControllerForTab(tab) }
        )
    }

    // MARK: - Shared tab context-menu helpers (top bar + vertical sidebar)

    func showConnectionInfo(for tab: TabModel) {
        connectionInfoToShow = tab.connectionInfo
    }

    /// Should the "Transfer to Nearby Device" item appear for this tab?
    func canTransferTabToNearby(_ tab: TabModel) -> Bool {
        guard tab.activeRoamProtocol == .trzsz,
              let leaf = tab.focusedTerminal,
              let trzsz = leaf.session as? TrzszSession,
              trzsz.transferableSessionID != nil else { return false }
        return true
    }

    func transferTabToNearby(_ tab: TabModel) {
        guard let leaf = tab.focusedTerminal else { return }
        startTrzszTransfer(tabId: tab.id, leaf: leaf)
    }

    func moveTabToNewWindow(_ tab: TabModel) {
        guard TabTransferCoordinator.shared.canTransfer(tab) else { return }
        moveTabsToNewWindow([tab.id])
    }

    /// Stage a group / gateway (one or more tabs) and open a fresh window that
    /// claims them on appear. Generalizes `moveTabToNewWindow`.
    func moveTabsToNewWindow(_ tabIDs: [UUID]) {
        guard TabTransferCoordinator.canOfferWindowTransfers, !tabIDs.isEmpty else { return }
        TabTransferCoordinator.shared.prepareMoveTabsToNewWindow(tabIDs, from: windowId)
        #if targetEnvironment(macCatalyst)
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                TabTransferCoordinator.shared.cancelPendingMoveTabsToNewWindow(tabIDs, from: windowId)
                Ghostty.logger.error("Failed to create transfer window: \(error.localizedDescription)")
            }
        )
        #else
        openWindow(id: "main-terminal")
        #endif
    }

    /// Create a new tmux window for either tab kind: gateway tabs route
    /// through the gateway surface, window tabs through their focused pane.
    func requestTmuxNewWindow(for tab: TabModel) {
        if tab.isTmuxGateway {
            tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?
                .requestTmuxNewWindowFromGateway()
        } else {
            tab.focusedTerminal?.requestTmuxNewWindow()
        }
    }

    func showTmuxSessions(for tab: TabModel) {
        if let controller = tmuxControllerForTab(tab) {
            tmuxDashboardRequest = TmuxDashboardRequest(controller: controller)
        }
    }

}
