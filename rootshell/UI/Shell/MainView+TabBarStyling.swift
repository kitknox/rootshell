//
//  MainView+TabBarStyling.swift
//  rootshell
//
//  Tab bar color and styling computations for MainView.
//  Extracted for build parallelization.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Resolved Tab Bar Theme Bundle

/// Pre-resolved theme values for a single `MainView.body` evaluation.
///
/// Crash logs caught the main thread inside `MainView.effectiveThemeColors.getter`
/// repeatedly during scene-update transactions: every styling computed property
/// (`tabBarBackgroundColor`, `selectedTabBackgroundColor`, `tabTextColor`, etc.)
/// independently re-resolves the override theme and re-extracts UIColor RGB
/// components for `isLight`/blend factors. Computing once per body and passing
/// the bundle through is byte-identical to the per-call path.
struct ResolvedTabBarTheme {
    let themeColors: ThemeManager.ThemeInfo.ThemeColors?
    let baseColor: Color?
    /// Theme background composited the same way as the terminal surface at
    /// the user's current background opacity. Integrated tabs use this rather
    /// than the opaque theme swatch so their active edge actually connects to
    /// the visible terminal.
    let terminalSurfaceBackground: Color?
    /// Catalyst can composite the terminal over the window backdrop. The
    /// existing theme-derived strip already has strong contrast in that case;
    /// opaque Catalyst and iOS need a larger deliberate separation.
    let terminalSurfaceIsTransparent: Bool
    let isLight: Bool
    let adaptivePrimaryBlend: CGFloat
    let adaptiveSecondaryBlend: CGFloat
    // Per-theme UI overrides (nil = use derived value). Applied as the final
    // step in each computed property below so the picker-set hex wins over
    // the algorithmic derivation. Built-in defaults (e.g. systemBackground
    // when no theme is available) are not overridable — overrides only
    // apply once we have a base color to derive from.
    let overrideTabBarBackground: Color?
    let overrideSelectedBackground: Color?
    let overrideUnselectedBackground: Color?
    let overrideTabText: Color?
    let overrideTabSecondaryText: Color?

    static let fallback = ResolvedTabBarTheme(
        themeColors: nil,
        baseColor: nil,
        terminalSurfaceBackground: nil,
        terminalSurfaceIsTransparent: false,
        isLight: false,
        adaptivePrimaryBlend: 0,
        adaptiveSecondaryBlend: 0,
        overrideTabBarBackground: nil,
        overrideSelectedBackground: nil,
        overrideUnselectedBackground: nil,
        overrideTabText: nil,
        overrideTabSecondaryText: nil
    )

    /// Resolved sheet styling for one `MainView.body` evaluation. The crash
    /// IPS files repeatedly catch main inside `MainView.effectiveThemeColors`
    /// during scene-update transactions because `applySheetModifiers` reads
    /// sheet theme + accent + color scheme once per attached `.themedSheet(...)`
    /// and per modifier; the chain has 8+ such attachments × 3 properties =
    /// 30+ effectiveThemeColors calls per body. Each call walks
    /// themeOverrideManager + themeManager. Computing once and threading the
    /// bundle through collapses that to a single resolution.

    var tabBarBackground: Color {
        if let override = overrideTabBarBackground { return override }
        return baseColor ?? Color(uiColor: .systemBackground)
    }

    /// Integrated tabs need a distinct frame behind transparent inactive tabs.
    /// Honor an explicit tab-bar override. Translucent Catalyst keeps the
    /// theme-derived frame that already contrasts with the composited terminal;
    /// opaque Catalyst and iOS use a stronger separation because both surfaces
    /// otherwise resolve to nearly the same color.
    var integratedStripBackground: Color {
        if let override = overrideTabBarBackground { return override }
        guard let baseColor else { return Color(uiColor: .systemBackground) }
        if terminalSurfaceIsTransparent {
            return isLight
                ? baseColor.blendedWithBlack(0.08)
                : baseColor.darkenedPreservingHue(0.12)
        }

        let terminalColor = terminalSurfaceBackground ?? baseColor
        if isLight {
            return terminalColor.blendedWithBlack(0.12)
        }
        return terminalColor.blendedWithWhite(0.12)
    }

    var selectedBackground: Color {
        if let override = overrideSelectedBackground { return override }
        guard let baseColor else { return Color(uiColor: .secondarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.20)
        }
        return baseColor.lightenedPreservingHue(adaptivePrimaryBlend)
    }

    var unselectedBackground: Color {
        if let override = overrideUnselectedBackground { return override }
        guard let baseColor else { return Color(uiColor: .tertiarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.08)
        }
        return baseColor.lightenedPreservingHue(adaptiveSecondaryBlend)
    }

    /// Hovering an inactive tab needs to remain visible even when the theme's
    /// derived unselected color nearly matches the surface behind it (for
    /// example, Tango Dark over the integrated tab strip). Derive the default
    /// from the surface that is actually under the tab so the fill always
    /// moves a consistent distance darker or lighter. An explicit theme UI
    /// override remains authoritative.
    func inactiveHoverBackground(for style: TopTabStyle) -> Color {
        if let override = overrideUnselectedBackground { return override }
        guard baseColor != nil else { return unselectedBackground }
        let surface = style == .integrated ? integratedStripBackground : tabBarBackground
        return isLight
            ? surface.blendedWithBlack(0.16)
            : surface.blendedWithWhite(0.16)
    }

    var tabText: Color {
        if let override = overrideTabText { return override }
        guard baseColor != nil else { return .primary }
        return isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    var tabSecondaryText: Color {
        if let override = overrideTabSecondaryText { return override }
        guard baseColor != nil else { return .secondary }
        return isLight ? Color(white: 0.4) : Color(white: 0.6)
    }
}

/// Pre-resolved sheet styling for one `MainView.body` evaluation. See
/// `ResolvedTabBarTheme` doc for context — same memoization pattern,
/// applied to the sheet/modifier chain.
struct ResolvedSheetTheme {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    static let none = ResolvedSheetTheme(themeColors: nil, accentColor: nil, colorScheme: nil)
}

// MARK: - Tab Bar Styling

extension MainView {

    /// Background color for selected tab - needs to stand out from the tab bar
    var selectedTabBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.selectedTabBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.20)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptivePrimaryBlend)
            }
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    /// Background color for the tab bar itself
    var tabBarBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.tabBarBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor
        }
        return Color(uiColor: .systemBackground)
    }

    /// Primary text color for tabs - adapts to theme background
    var tabTextColor: Color {
        if let override = effectiveThemeUIOverrides.tabText.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
        }
        return .primary
    }

    /// Secondary text color for tabs - adapts to theme background
    var tabSecondaryTextColor: Color {
        if let override = effectiveThemeUIOverrides.tabSecondaryText.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.4) : Color(white: 0.6)
        }
        return .secondary
    }

    /// Background color for unselected tabs - subtle but visible
    var unselectedTabBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.unselectedTabBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.08)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptiveSecondaryBlend)
            }
        }
        return Color(uiColor: .tertiarySystemBackground)
    }

    /// Compute all derived tab bar styling values once for the current body
    /// evaluation. Replaces the previous pattern of calling 5+ independent
    /// computed properties (`tabBarBackgroundColor`, `tabTextColor`, etc.) that
    /// each re-resolved the override theme and re-extracted UIColor RGB
    /// components. Per body run this collapses ~7 dictionary lookups + ~8
    /// UIColor conversions into 1 of each.
    func resolvedTabBarTheme() -> ResolvedTabBarTheme {
        let themeColors = effectiveThemeColors
        let baseColor = themeColors.flatMap { Color(hex: $0.background) }
        let overrides: ThemeUIOverrides = baseColor != nil
            ? (effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty)
            : .empty
        guard let baseColor else {
            return ResolvedTabBarTheme(
                themeColors: themeColors,
                baseColor: nil,
                terminalSurfaceBackground: nil,
                terminalSurfaceIsTransparent: false,
                isLight: false,
                adaptivePrimaryBlend: 0,
                adaptiveSecondaryBlend: 0,
                overrideTabBarBackground: nil,
                overrideSelectedBackground: nil,
                overrideUnselectedBackground: nil,
                overrideTabText: nil,
                overrideTabSecondaryText: nil
            )
        }
        #if targetEnvironment(macCatalyst)
        let terminalSurfaceIsTransparent = transparencyManager.backgroundOpacity < 0.999
        let terminalSurfaceBackground = baseColor.blendedWithWhite(
            1 - CGFloat(transparencyManager.backgroundOpacity)
        )
        #else
        // The iOS/visionOS terminal is composited over the same theme-colored
        // root fill, so opacity does not change its visible base color.
        let terminalSurfaceIsTransparent = false
        let terminalSurfaceBackground = baseColor
        #endif
        return ResolvedTabBarTheme(
            themeColors: themeColors,
            baseColor: baseColor,
            terminalSurfaceBackground: terminalSurfaceBackground,
            terminalSurfaceIsTransparent: terminalSurfaceIsTransparent,
            isLight: baseColor.isLight,
            adaptivePrimaryBlend: baseColor.adaptivePrimaryBlend,
            adaptiveSecondaryBlend: baseColor.adaptiveSecondaryBlend,
            overrideTabBarBackground: overrides.tabBarBackground.flatMap { Color(hex: $0) },
            overrideSelectedBackground: overrides.selectedTabBackground.flatMap { Color(hex: $0) },
            overrideUnselectedBackground: overrides.unselectedTabBackground.flatMap { Color(hex: $0) },
            overrideTabText: overrides.tabText.flatMap { Color(hex: $0) },
            overrideTabSecondaryText: overrides.tabSecondaryText.flatMap { Color(hex: $0) }
        )
    }

    /// Per-theme overrides for the currently effective theme (or `.empty` if
    /// no theme name is resolved). Used by the legacy individual color
    /// computed properties so a single override change reflects in every
    /// styling code path.
    private var effectiveThemeUIOverrides: ThemeUIOverrides {
        effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty
    }

    /// Get the effective theme colors for the currently selected tab
    /// Uses override resolution: Tab > Window > Global
    var effectiveThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        guard terminals.indices.contains(selectedTabIndex) else {
            return themeManager.currentThemeInfo?.colors
        }

        let tabId = terminals[selectedTabIndex].id
        let (themeName, _) = themeOverrideManager.resolveTheme(
            tabId: tabId,
            windowId: windowId
        )

        // If it's the global theme, use cached info
        if themeName == themeManager.currentTheme {
            return themeManager.currentThemeInfo?.colors
        }

        // Otherwise, load the override theme's colors
        return themeManager.themeInfo(for: themeName)?.colors
    }

    /// Name of the currently-effective theme for the selected tab (after tab
    /// and window theme overrides). Used by the per-theme UI color override
    /// lookup so chrome reflects the theme that's actually showing.
    var effectiveThemeName: String? {
        guard terminals.indices.contains(selectedTabIndex) else {
            return themeManager.currentTheme
        }
        let tabId = terminals[selectedTabIndex].id
        let (themeName, _) = themeOverrideManager.resolveTheme(
            tabId: tabId,
            windowId: windowId
        )
        return themeName
    }

    /// Whether the current theme is light (for glassmorphism fallback styling)
    var isLightTheme: Bool {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight
        }
        return false
    }

    /// Whether the device is an iPhone (for AI Agent presentation mode)
    var isPhone: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// Whether tabs are displayed in the titlebar (Catalyst only)
    var usesTitlebarTabs: Bool {
        #if targetEnvironment(macCatalyst)
        return tabsInTitlebarEnabled
        #else
        return false
        #endif
    }

    /// Whether the horizontal row physically occupies the window's top edge.
    /// Hidden-titlebar mode is top-attached even when the separate
    /// "Tabs in Title Bar" preference is off.
    var topTabBarAttachedToWindow: Bool {
        #if targetEnvironment(macCatalyst)
        return usesTitlebarTabs || hideWindowTitleBar
        #else
        return false
        #endif
    }

    func tabBarChromeBackground(_ theme: ResolvedTabBarTheme) -> Color {
        topTabStyle == .integrated
            ? theme.integratedStripBackground
            : theme.tabBarBackground
    }

    /// Leading padding for tab bar content (accounts for window controls on Catalyst)
    var tabBarLeadingPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        let basePadding: CGFloat = 8
        let controlClearance: CGFloat
        if usesTitlebarTabs && !hideWindowTitleBar {
            // The measured value arrives after AppKit creates the buttons.
            // Keep enough launch-time clearance for the larger Catalyst
            // traffic-light geometry seen on current macOS releases.
            let titlebarMinimum: CGFloat = 100
            let measuredInset = titlebarLayoutManager.leadingInset
            controlClearance = max(titlebarMinimum, measuredInset)
        } else {
            controlClearance = basePadding
        }
        let dragClearance = topTabBarAttachedToWindow ? Self.catalystWindowDragWidth : 0
        return controlClearance + dragClearance
        #else
        return 0
        #endif
    }
}
