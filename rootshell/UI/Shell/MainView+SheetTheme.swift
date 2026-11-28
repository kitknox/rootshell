//
//  MainView+SheetTheme.swift
//  rootshell
//
//  Sheet theme environment key and MainView's sheet-theme resolution
//  helpers, extracted for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sheet Theme Colors Environment Key

/// Theme colors for sheet content. When set, views should clear their scroll content
/// background and use these colors instead. Only set in the fullScreenCover path (iPad/Catalyst).
struct SheetThemeColors: Equatable {
    /// Background for the gaps between list sections (replaces systemGroupedBackground)
    let background: Color
    /// Background for list row cells (replaces secondarySystemGroupedBackground)
    let rowBackground: Color
    /// Accent color derived from the terminal theme (cursor/palette), propagated to sub-sheets
    let accentColor: Color?
    /// The terminal theme these colours came from, for content that follows its palette.
    var terminal: ThemeManager.ThemeInfo.ThemeColors? = nil
}

private struct SheetThemeColorsKey: EnvironmentKey {
    static let defaultValue: SheetThemeColors? = nil
}

extension EnvironmentValues {
    var sheetThemeColors: SheetThemeColors? {
        get { self[SheetThemeColorsKey.self] }
        set { self[SheetThemeColorsKey.self] = newValue }
    }
}

// MARK: - Sheet Theme Helpers

extension MainView {

    var sheetAccentColor: Color? {
        guard themedUIEnabled,
              let themeColors = effectiveThemeColors,
              let derived = ThemeUIColorDerivation.derive(from: themeColors) else {
            return nil
        }
        let overrides = effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty
        return overrides.sheetAccent.flatMap { Color(hex: $0) } ?? derived.sheetAccent
    }

    var sheetColorSchemeForSheets: ColorScheme? {
        guard themedUIEnabled, let themeColors = effectiveThemeColors else { return nil }
        guard let surface = EffectiveSurface.resolve(backgroundHex: themeColors.background) else { return nil }
        return surface.isLight ? .light : .dark
    }

    /// Resolve all three sheet-styling properties once per body evaluation.
    /// `applySheetModifiers` previously read sheet theme + accent + color
    /// scheme independently for every `.themedSheet(...)` and modifier —
    /// 8+ attachments × 3 properties = 30+ `effectiveThemeColors` calls per
    /// body, each walking the themeOverride + themeManager chain. Single
    /// resolution, threaded through the modifier chain via
    /// `ResolvedSheetTheme`.
    func resolvedSheetTheme() -> ResolvedSheetTheme {
        guard themedUIEnabled,
              let themeColors = effectiveThemeColors,
              let derived = ThemeUIColorDerivation.derive(from: themeColors) else {
            return .none
        }
        let overrides = effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty
        let bg = overrides.sheetBackground.flatMap { Color(hex: $0) } ?? derived.sheetBackground
        let rowBase = overrides.sheetRowBackground.flatMap { Color(hex: $0) } ?? derived.sheetRowBackground
        let row = rowBase.opacity(0.92)
        let accent = overrides.sheetAccent.flatMap { Color(hex: $0) } ?? derived.sheetAccent
        let surface = EffectiveSurface.resolve(backgroundHex: themeColors.background)
        return ResolvedSheetTheme(
            themeColors: SheetThemeColors(background: bg, rowBackground: row, accentColor: accent, terminal: themeColors),
            accentColor: accent,
            colorScheme: derived.isLight ? .light : .dark,
            translucentBackground: surface?.translucentFill(showing: bg)
        )
    }
}
