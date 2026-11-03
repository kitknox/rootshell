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
struct ResolvedTabBarTheme: Equatable {
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
    let overrideSheetAccent: Color?
    /// Tabs sit on the Theme Gradient backdrop rather than flat chrome.
    var onBackdrop = false
    /// What is visible behind the terminal and the tab strip.
    var surface: EffectiveSurface?

    /// Tab fills derive from the color actually behind them: the gradient's
    /// top band on the backdrop, otherwise the theme background.
    var tabBase: Color? {
        onBackdrop ? surface?.chrome ?? baseColor : baseColor
    }

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
        overrideTabSecondaryText: nil,
        overrideSheetAccent: nil
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

    /// Integrated tabs need a restrained frame behind transparent inactive
    /// tabs. Honor an explicit tab-bar override. Translucent Catalyst already
    /// gets some separation from the composited terminal, while opaque
    /// Catalyst and iOS need a slightly larger shift because both surfaces
    /// otherwise resolve to nearly the same color.
    var integratedStripBackground: Color {
        if let override = overrideTabBarBackground { return override }
        guard let baseColor else { return Color(uiColor: .systemBackground) }
        if terminalSurfaceIsTransparent {
            return isLight
                ? baseColor.blendedWithBlack(0.04)
                : baseColor.darkenedPreservingHue(0.06)
        }

        let terminalColor = terminalSurfaceBackground ?? baseColor
        if isLight {
            return terminalColor.blendedWithBlack(0.06)
        }
        return terminalColor.blendedWithWhite(0.06)
    }

    /// Optical edge colors come from the selected terminal surface rather
    /// than a theme accent. This keeps the rim native-looking while preserving
    /// chromatic backgrounds instead of washing them toward gray.
    var integratedEdgePalette: IntegratedTabEdgePalette {
        IntegratedTabEdgePalette(
            // A translucent surface derives the edge from the opaque swatch
            surfaceColor: terminalSurfaceIsTransparent ? baseColor : (terminalSurfaceBackground ?? baseColor),
            isLightTheme: isLight
        )
    }

    var selectedBackground: Color {
        if let override = overrideSelectedBackground { return override }
        guard let tabBase else { return Color(uiColor: .secondarySystemBackground) }
        if isLight {
            return tabBase.blendedWithBlack(0.20)
        }
        return tabBase.lightenedPreservingHue(adaptivePrimaryBlend)
    }

    var unselectedBackground: Color {
        if let override = overrideUnselectedBackground { return override }
        guard let tabBase else { return Color(uiColor: .tertiarySystemBackground) }
        if isLight {
            return tabBase.blendedWithBlack(0.08)
        }
        return tabBase.lightenedPreservingHue(adaptiveSecondaryBlend)
    }

    /// Hovering an inactive tab needs to remain visible even when the theme's
    /// derived unselected color nearly matches the surface behind it (for
    /// example, Tango Dark over the integrated tab strip). Derive the default
    /// from the surface that is actually under the tab so the fill always
    /// moves a consistent distance darker or lighter. An explicit theme UI
    /// override remains authoritative.
    func inactiveHoverBackground(for style: TopTabStyle) -> Color {
        if let override = overrideUnselectedBackground { return override }
        guard let tabBase else { return unselectedBackground }
        // The strip is clear on the backdrop
        let surface = onBackdrop ? tabBase : style == .integrated ? integratedStripBackground : tabBarBackground
        return isLight
            ? surface.blendedWithBlack(0.16)
            : surface.blendedWithWhite(0.16)
    }

    var tabText: Color {
        if let override = overrideTabText { return override }
        guard baseColor != nil else { return .primary }
        return isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    /// The selected Integrated tab sits on its terminal's surface, which can
    /// differ from the strip (a light tab theme over a dark backdrop), so its
    /// title contrasts with that surface instead.
    var integratedSelectedText: Color {
        if let override = overrideTabText { return override }
        guard let baseColor else { return .primary }
        let light = onBackdrop ? (surface?.isLight ?? baseColor.isLight) : baseColor.isLight
        return light ? Color(white: 0.1) : Color(white: 0.95)
    }

    var tabSecondaryText: Color {
        if let override = overrideTabSecondaryText { return override }
        guard baseColor != nil else { return .secondary }
        // The gradient is busier and brighter than chrome, so inactive titles need more contrast
        if onBackdrop { return isLight ? Color(white: 0.2) : Color(white: 0.85) }
        return isLight ? Color(white: 0.4) : Color(white: 0.6)
    }

    /// Ledger's selection bar is the only selection cue, so it takes the theme
    /// accent (same source as sheets and the sidebar) rather than the text
    /// color, which would read as a second keyline.
    var ledgerIndicator: Color {
        if let override = overrideSheetAccent { return override }
        guard baseColor != nil else { return .accentColor }
        if let accent = themeColors?.vibrantAccentColor {
            return accent.adjustedSheetTint(on: tabBarBackground)
        }
        return tabText
    }
}

/// Pre-resolved sheet styling for one `MainView.body` evaluation. See
/// `ResolvedTabBarTheme` doc for context — same memoization pattern,
/// applied to the sheet/modifier chain.
struct ResolvedSheetTheme {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    /// Fill that shows the sheet background once drawn at the terminal's
    /// opacity over the backdrop.
    var translucentBackground: Color?

    static let none = ResolvedSheetTheme(themeColors: nil, accentColor: nil, colorScheme: nil)
}

// MARK: - Tab Bar Styling

extension MainView {

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
                overrideTabSecondaryText: nil,
                overrideSheetAccent: nil
            )
        }
        let surfaceStyle = integratedSurfaceStyle()
        #if targetEnvironment(macCatalyst)
        var terminalSurfaceIsTransparent = transparencyManager.backgroundOpacity < 0.999
        #else
        // The iOS/visionOS terminal is composited over the same theme-colored
        // root fill, so opacity does not change its visible base color.
        var terminalSurfaceIsTransparent = false
        #endif
        let terminalSurfaceBackground = surfaceStyle.color(for: baseColor)
        let surface = EffectiveSurface.resolve(background: baseColor)
        let tabBase = surface.onBackdrop ? surface.chrome : baseColor
        if surface.onBackdrop {
            // The terminal draws its background at this opacity over the backdrop;
            // the active tab does the same so the gradient shows through both alike.
            terminalSurfaceIsTransparent = surfaceStyle.isTranslucent
        }
        var resolved = ResolvedTabBarTheme(
            themeColors: themeColors,
            baseColor: baseColor,
            terminalSurfaceBackground: terminalSurfaceBackground,
            terminalSurfaceIsTransparent: terminalSurfaceIsTransparent,
            isLight: tabBase.isLight,
            adaptivePrimaryBlend: tabBase.adaptivePrimaryBlend,
            adaptiveSecondaryBlend: tabBase.adaptiveSecondaryBlend,
            overrideTabBarBackground: overrides.tabBarBackground.flatMap { Color(hex: $0) },
            overrideSelectedBackground: overrides.selectedTabBackground.flatMap { Color(hex: $0) },
            overrideUnselectedBackground: overrides.unselectedTabBackground.flatMap { Color(hex: $0) },
            overrideTabText: overrides.tabText.flatMap { Color(hex: $0) },
            overrideTabSecondaryText: overrides.tabSecondaryText.flatMap { Color(hex: $0) },
            overrideSheetAccent: overrides.sheetAccent.flatMap { Color(hex: $0) }
        )
        resolved.onBackdrop = surface.onBackdrop
        resolved.surface = surface
        return resolved
    }

    /// How a pane background reads behind the selected Integrated tab.
    func integratedSurfaceStyle() -> IntegratedSurfaceStyle {
        let opacity = transparencyManager.effectiveBackgroundOpacity
        // Over the backdrop the strip is already clear; only the Mac window's
        // own translucency needs the opaque strip erased.
        return IntegratedSurfaceStyle(opacity: opacity, erasesBeneath: opacity < 0.999 && !effectManager.isBackdropEnabled)
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

    /// Whether the device is an iPhone (for AI Agent presentation mode)
    var isPhone: Bool {
        #if os(visionOS)
        return false
        #else
        return workspaceSizeClass != .regular
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
        return (usesTitlebarTabs || hideWindowTitleBar) && tabBarPosition == .top
        #else
        return false
        #endif
    }

    func tabBarChromeBackground(_ theme: ResolvedTabBarTheme) -> Color {
        // Rounded panes sit on the strip color so cards stand out from it.
        topTabStyle == .integrated || roundedPanes
            ? theme.integratedStripBackground
            : theme.tabBarBackground
    }

    /// Leading padding for tab bar content (accounts for window controls on Catalyst)
    var tabBarLeadingPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        let basePadding: CGFloat = 8
        let controlClearance: CGFloat
        if usesTitlebarTabs && !hideWindowTitleBar && tabBarPosition == .top {
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
