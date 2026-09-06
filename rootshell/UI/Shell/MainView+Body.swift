//
//  MainView+Body.swift
//  rootshell
//
//  Body content views for MainView, extracted for compiler type-checking.
//

import SwiftUI
import GhosttyKit

// MARK: - Body Content Views

extension MainView {

    // MARK: - Integrated OSC Progress Edge

    /// Renders the selected focused terminal's OSC 9;4 foreground over the
    /// palette-aware integrated keyline. The host view owns observation of the
    /// terminal publisher so progress updates do not invalidate `MainView`.
    @ViewBuilder
    func integratedOSCProgressEdge(activeTabBounds: Anchor<CGRect>?) -> some View {
        if topTabStyle == .integrated,
           let activeTabBounds,
           terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal {
            let selectedTabID = terminals[selectedTabIndex].id
            GeometryReader { proxy in
                IntegratedOSCProgressEdgeHost(
                    terminalView: focusedTerminal,
                    activeTabRect: proxy[activeTabBounds],
                    rowSize: proxy.size,
                    selectedTabID: selectedTabID,
                    animateSelectionChanges: !tabBarAnimationsDisabled
                        && !tabIndicator.suppressNextSelectionAnimation
                        && !UIAccessibility.isReduceMotionEnabled
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Full-Bleed Backgrounds

    /// The full-bleed background layer.
    ///
    /// Takes the pre-resolved tab bar theme so each fill uses the same
    /// memoized color rather than re-resolving via the `tabBarBackgroundColor`
    /// computed property (which walks `effectiveThemeColors` →
    /// `themeOverrideManager.resolveTheme` → `themeManager` on every read).
    @ViewBuilder
    func fullBleedBackground(geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        let chromeBackground = tabBarChromeBackground(theme)
        #if targetEnvironment(macCatalyst)
        VStack(spacing: 0) {
            chromeBackground
                .frame(height: (hideWindowTitleBar && tabBarHidden) ? 0 : max(44, geometry.safeAreaInsets.top))
            Spacer()
        }
        .ignoresSafeArea()
        #else
        ZStack {
            theme.tabBarBackground
            VStack(spacing: 0) {
                chromeBackground
                    .frame(height: windowSafeAreaInsets.top + (tabBarHidden ? 0 : TabMetrics.tabBarHeight))
                Spacer()
                if !visibleContentAllowsTerminalEffects
                    || effectManager.terminalBottomInsetFraction == 0 {
                    theme.tabBarBackground
                        .frame(height: windowSafeAreaInsets.bottom)
                }
            }
        }
        .ignoresSafeArea()
        #endif
    }

    // MARK: - Loading/Error States

    /// Loading state view.
    @ViewBuilder
    var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading Ghostty...")
                .foregroundColor(.secondary)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Error state view.
    @ViewBuilder
    var errorView: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Failed to initialize Ghostty")
                .foregroundColor(.secondary)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab Bar Header Spacer

    /// Spacer for window controls when tab bar is hidden (Catalyst only).
    @ViewBuilder
    func catalystTabBarSpacer(geometry: GeometryProxy) -> some View {
        #if targetEnvironment(macCatalyst)
        if tabBarHidden && usesTitlebarTabs && !hideWindowTitleBar {
            Color.clear
                .frame(height: max(44, geometry.safeAreaInsets.top))
                .catalystCursorRegion()
        }
        #endif
    }

    // MARK: - Hidden-Titlebar Drag Strip Shield

    /// Shields the hidden-titlebar drag strip (Catalyst only). The AppKit
    /// TitlebarDragHandle above the UIKit layer moves the window, but Catalyst
    /// delivers the same pointer drag to the terminal view underneath, which
    /// scrolls/selects while the window moves. A real UIView absorbs those
    /// events; matches the handle's 12pt topInset in WindowAccessor.
    @ViewBuilder
    func catalystDragStripShield() -> some View {
        #if targetEnvironment(macCatalyst)
        if hideWindowTitleBar && tabBarHidden {
            DragStripEventShield()
                .frame(maxWidth: .infinity)
                .frame(height: 12)
        }
        #endif
    }

    // MARK: - Tab Bar Action Buttons

    /// The add and settings buttons for the legacy pill tab bar.
    @ViewBuilder
    func tabBarActionButtons(theme: ResolvedTabBarTheme) -> some View {
        tabBarAddButton(theme: theme)
        tabBarSettingsButton(theme: theme)
    }

    @ViewBuilder
    func tabBarAddButton(theme: ResolvedTabBarTheme) -> some View {
        ZStack {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(theme.tabText)
                .frame(width: TabMetrics.tabBarHeight, height: TabMetrics.tabBarHeight)
                .accessibilityHidden(true)

            TabStyleContextMenuRegion(
                selectedStyleRawValue: topTabStyleRawValueBinding,
                primaryAction: addNewTab,
                accessibilityLabel: String(localized: "Open Connections")
            )
        }
        .overlay(alignment: .leading) {
            if topTabStyle.usesStripLayout {
                Rectangle()
                    .fill(theme.tabText.opacity(theme.isLight ? 0.16 : 0.22))
                    .frame(width: 0.5, height: 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: TabMetrics.tabBarHeight, height: TabMetrics.tabBarHeight)
        .fixedSize()
        .layoutPriority(1)
    }

    @ViewBuilder
    func tabBarSettingsButton(theme: ResolvedTabBarTheme) -> some View {
        ZStack {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(theme.tabText)
                .frame(width: TabMetrics.tabBarHeight, height: TabMetrics.tabBarHeight)
                .accessibilityHidden(true)

            TabStyleContextMenuRegion(
                selectedStyleRawValue: topTabStyleRawValueBinding,
                primaryAction: { requestSettingsPresentation() },
                accessibilityLabel: String(localized: "Settings")
            )
        }
        .frame(width: TabMetrics.tabBarHeight, height: TabMetrics.tabBarHeight)
        .fixedSize()
        .layoutPriority(1)
    }

    @ViewBuilder
    func integratedTabBarDragRegion() -> some View {
        #if targetEnvironment(macCatalyst)
        if usesTitlebarTabs || hideWindowTitleBar {
            CatalystWindowDragRegion(tabStyleSelection: topTabStyleRawValueBinding)
                .frame(minWidth: Self.catalystWindowDragWidth, maxWidth: .infinity)
                .frame(height: TabMetrics.tabBarHeight)
                .catalystCursorRegion(.openHand, priority: .titlebar)
                .accessibilityHidden(true)
        } else {
            TabStyleContextMenuRegion(selectedStyleRawValue: topTabStyleRawValueBinding)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: TabMetrics.tabBarHeight)
        }
        #else
        TabStyleContextMenuRegion(selectedStyleRawValue: topTabStyleRawValueBinding)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: TabMetrics.tabBarHeight)
        #endif
    }

    // MARK: - Tab Bar Leading Spacer

    /// Leading spacer for Mac Catalyst tab bar.
    @ViewBuilder
    func tabBarLeadingSpacer(geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        #if targetEnvironment(macCatalyst)
        let dragWidth = topTabBarAttachedToWindow ? Self.catalystWindowDragWidth : 0
        // This fill sits above the row's background, so without the inset it
        // clips the integrated edge across the traffic-light clearance. Outer
        // frame is unchanged, leaving drag-region geometry alone.
        tabBarChromeBackground(theme)
            .padding(.bottom, topTabStyle.usesStripLayout ? IntegratedTabEdgeMetrics.reservedThickness : 0)
            .frame(width: tabBarLeadingPadding, height: 44)
            .overlay {
                TabStyleContextMenuRegion(selectedStyleRawValue: topTabStyleRawValueBinding)
            }
            .overlay(alignment: .trailing) {
                if dragWidth > 0 {
                    CatalystWindowDragRegion(tabStyleSelection: topTabStyleRawValueBinding)
                        .frame(width: dragWidth, height: TabMetrics.tabBarHeight)
                        .catalystCursorRegion(.openHand, priority: .titlebar)
                        .accessibilityHidden(true)
                }
            }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// A bare interactive UIView that terminates UIKit hit-testing over the
/// hidden-titlebar drag strip. A SwiftUI-only overlay can't reliably block
/// events from reaching a UIViewRepresentable terminal underneath.
/// It also feeds WindowDragObserver: a press here is the start-of-drag
/// signal that arms scroll suppression before the window even moves.
private struct DragStripEventShield: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = DragStripShieldView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class DragStripShieldView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        WindowDragObserver.shared.dragStripTouchBegan()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        WindowDragObserver.shared.dragStripTouchEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        WindowDragObserver.shared.dragStripTouchEnded()
    }
}
#endif
