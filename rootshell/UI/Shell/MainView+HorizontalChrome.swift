import SwiftUI

extension MainView {
    func horizontalTabHeader(geometry: GeometryProxy, resolvedTheme: ResolvedTabBarTheme) -> some View {
        let rowWidth = terminalRowViewportWidth > 0 ? terminalRowViewportWidth : geometry.size.width
        let columns = terminalRowColumns(width: rowWidth)
        let cardGap = roundedPanes ? PaneCardStyle.gap : 0
        let followsTerminalColumn = usesPinnedWideEdgeSidebarLayout
        let headerWidth = followsTerminalColumn ? columns.terminal : geometry.size.width
        let terminalLeadingInset = followsTerminalColumn ? cardGap + leadingWidth(in: columns) : 0
        return GeometryReader { terminalHeaderGeometry in
            let cardInset = integratedCardLeadingInset(windowWidth: terminalHeaderGeometry.size.width)
            let surfaceFill = integratedTabSurfaceFill(theme: resolvedTheme)
            HStack(spacing: 0) {
            tabBarLeadingSpacer(geometry: terminalHeaderGeometry, theme: resolvedTheme)

            if edgeSidebarButtonsEnabled, !edgeSidebarAssignment.pages(on: .leading).isEmpty {
                tabBarEdgeSidebarButton(side: .leading, theme: resolvedTheme)
            }

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
            tabBarTrack(in: terminalHeaderGeometry, theme: resolvedTheme)
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
                .blockWindowDrag(when: usesTitlebarTabs)
#endif

            if usesCompactTabSpacing {
                integratedTabBarDragRegion()
                    .layoutPriority(-1)
                if showsTabBarActions {
                    tabBarAddButton(theme: resolvedTheme)
                    tabBarSettingsButton(theme: resolvedTheme)
                }
                if edgeSidebarButtonsEnabled, !edgeSidebarAssignment.pages(on: .trailing).isEmpty {
                    tabBarEdgeSidebarButton(side: .trailing, theme: resolvedTheme)
                }
            } else {
                TabStyleContextMenuRegion(
                    selectedStyleRawValue: topTabStyleRawValueBinding
                )
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
                tabBarActionButtons(theme: resolvedTheme)
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
        .frame(width: headerWidth, height: TabMetrics.tabBarHeight, alignment: .leading)
        // Keep the actions over the terminal column when a sidebar is pinned.
        .padding(.leading, terminalLeadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
