import SwiftUI
import UIKit

extension MainView {
    /// The tab row below the terminal. It rides on the docked keyboard or
    /// toolbar, and its fill runs out to the screen edges beneath it.
    func bottomTabBar(geometry: GeometryProxy, workspace: DuoWorkspaceLayout,
                      resolvedTheme: ResolvedTabBarTheme) -> some View {
        VStack(spacing: 0) {
            GeometryReader { barGeometry in
                horizontalTabHeader(geometry: barGeometry, resolvedTheme: resolvedTheme)
            }
            .frame(height: TabMetrics.tabBarHeight)
            .padding(.leading, workspace.headerInsets.leading)
            .padding(.trailing, workspace.headerInsets.trailing)
            Color.clear
                .frame(height: bottomTabBarKeyboardLift(geometry: geometry, lowerReservation: workspace.lowerReservation))
        }
        .background {
            (effectManager.isBackdropEnabled ? Color.clear : tabBarChromeBackground(resolvedTheme))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                .allowsHitTesting(false)
        }
    }

    /// How far the bottom tab bar rises to clear the keyboard and toolbar,
    /// judged over the whole workspace so the bar's own height never feeds back.
    private func bottomTabBarKeyboardLift(geometry: GeometryProxy, lowerReservation: CGFloat) -> CGFloat {
        let _ = effectManager.keyboardStateVersion
        var frame = geometry.frame(in: .global)
        frame.size.height = max(0, frame.height - lowerReservation)
        var lift = keyboardCoverage(of: frame, window: nil)
        #if os(visionOS)
        if showKeyboardToolbar { lift += KeyboardSizes.iPad.toolbar.height }
        #endif
        return lift
    }

    /// Window-space top of the docked keyboard or toolbar; nil when neither
    /// covers the window. Hover previews stay above it.
    func keyboardTop(in window: UIWindow) -> CGFloat? {
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let coverage = keyboardCoverage(of: safe, window: window)
        return coverage > 0 ? safe.maxY - coverage : nil
    }

    /// How much of `frame` (global space) the docked keyboard or toolbar covers,
    /// by the terminal's own rules.
    private func keyboardCoverage(of frame: CGRect, window: UIWindow?) -> CGFloat {
        // Web-preview tabs have no pane, but their fields still raise the keyboard.
        let pane = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].focusedPane : nil
        return terminalBottomPadding(
            containerFrame: frame,
            containerSafeAreaBottom: 0,
            keyboardFrame: effectManager.keyboardFrame,
            keyboardHeight: effectManager.keyboardHeight,
            reservedBottomToolbarHeight: pane?.reservedKeyboardToolbarHeightAtBottom ?? 0,
            accessoryFrame: pane?.keyboardAccessoryFrameInScreen,
            touchKeyboardFrame: pane?.dockedTouchKeyboardFrameInScreen,
            containerBottomSafeAreaExpansion: 0,
            terminalEffectsEnabled: false,
            hostWindow: pane == nil ? window ?? sceneHostWindow : nil)
    }

    /// This scene's window, from any mounted pane or else the scene itself.
    private var sceneHostWindow: UIWindow? {
        if let window = overlayPreservationHostWindow { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.persistentIdentifier == windowSceneSessionID }
        return scene?.keyWindow ?? scene?.windows.first
    }

    func horizontalTabHeader(geometry: GeometryProxy, resolvedTheme: ResolvedTabBarTheme) -> some View {
        let cardInset = integratedCardLeadingInset(windowWidth: geometry.size.width)
        let surfaceFill = integratedTabSurfaceFill(theme: resolvedTheme)
        return HStack(spacing: 0) {
            tabBarLeadingSpacer(geometry: geometry, theme: resolvedTheme)

            // Tab bar - switches between display modes
            //
            // The previous design carried a `tabBarVersion`
            // counter that was bumped from drop completions
            // and notification observers, with `.id(tabBarVersion)`
            // forcing a structural rebuild of the entire tab
            // bar subtree on every increment. With per-tab
            // observation via `TabModel`, the tab bar
            // re-evaluates only on the property reads it
            // actually performs, so no manual refresh signal
            // is needed.
            tabBarTrack(in: geometry, theme: resolvedTheme)
                .layoutPriority(0)
                // Toggling grouped mode changes `navigationTabs`,
                // which can flip the tab-bar display mode (e.g.
                // equalWidth→singleTab when two tabs live in
                // different groups). Animating that structural
                // swap makes the selected tab's glass capsule
                // morph for ~1s, during which the roam "R" badge
                // composites against the unsettled glass and looks
                // washed out. Snap the layout for grouped-mode
                // toggles so the badge is correct immediately;
                // ordinary tab add/remove + resize still animate
                // (this innermost transaction only fires when
                // `isGroupedModeEnabled` itself changes).
                .transaction(value: tabsModel.isGroupedModeEnabled) { $0.animation = nil }
                .animation(
                    tabBarAnimationsDisabled || UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.25),
                    value: terminals.count
                )
#if targetEnvironment(macCatalyst)
                .blockWindowDrag(when: usesTitlebarTabs && !showsBottomTabBar)
#endif

            if usesCompactTabSpacing {
                if showsTabBarActions { tabBarAddButton(theme: resolvedTheme) }
                integratedTabBarDragRegion()
                    .layoutPriority(-1)
                if showsTabBarActions { tabBarSettingsButton(theme: resolvedTheme) }
            } else {
                TabStyleContextMenuRegion(
                    selectedStyleRawValue: topTabStyleRawValueBinding
                )
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
                if showsTabBarActions { tabBarActionButtons(theme: resolvedTheme) }
            }
        }
        .frame(height: TabMetrics.tabBarHeight)
        .frame(maxWidth: .infinity)
        // Track the docked column's spring; a live drag drives it directly.
        .animation(tabSidebarIsDragging ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: cardInset)
        .backgroundPreferenceValue(IntegratedActiveTabBoundsPreferenceKey.self) { bounds in
            ZStack {
                // The window fill beneath the backdrop already has this color.
                if !effectManager.isBackdropEnabled {
                    tabBarChromeBackground(resolvedTheme)
                }

                // Background layer on purpose: the active tab
                // occludes the run beneath it, so the line
                // reads as rising around that tab.
                // Rounded Integrated tabs join cards, whose rims open under the tab.
                if topTabStyle.usesStripLayout, !integratedTabsJoinCards {
                    integratedEdgeRule(palette: resolvedTheme.integratedEdgePalette,
                                       activeTabBounds: surfaceFill?.style.isTranslucent == true ? bounds : nil)
                }
            }
            // Visual chrome must not own an interaction behind
            // every foreground tab, button, and empty-space menu.
            .allowsHitTesting(false)
        }
        .overlayPreferenceValue(IntegratedActiveTabBoundsPreferenceKey.self) { bounds in
            integratedOSCProgressEdge(activeTabBounds: bounds)
            integratedTabJoinReader(activeTabBounds: bounds)
        }
        .overlayPreferenceValue(IntegratedTabTrackBoundsPreferenceKey.self) { bounds in
            integratedTabTrackClipReader(trackBounds: bounds)
        }
        .environment(\.integratedTabJoinsCard, integratedTabsJoinCards)
        .environment(\.integratedTabSurfaceFill, surfaceFill)
        .modifier(ContainerCornerModifier())
#if targetEnvironment(macCatalyst)
        .catalystCursorRegion()
#endif
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            // Tab frame preferences are only used by Catalyst
            // titlebar dragging. Guard and defer the write so
            // selection animations don't feed layout-pass
            // preferences back into MainView every frame.
            DispatchQueue.main.async {
                if tabFrames != frames {
                    tabFrames = frames
                }
            }
        }
    }
}
