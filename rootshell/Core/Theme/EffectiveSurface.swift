//
//  EffectiveSurface.swift
//  rootshell
//
//  The background actually visible behind terminal text and the top tabs once
//  the Theme Gradient backdrop shows through the translucent terminal. Chrome,
//  sheets and the color ghostty reports to programs all derive from it.
//

import SwiftUI
import UIKit

struct EffectiveSurface: Equatable {
    /// Theme or host-tinted background.
    let baseRGB: SIMD3<Double>
    /// Base at the terminal's opacity over the averaged backdrop.
    let terminalRGB: SIMD3<Double>
    /// The backdrop's top band, which the tab strip sits on.
    let chromeRGB: SIMD3<Double>
    /// Averaged backdrop and the opacity the terminal draws over it.
    var backdropRGB: SIMD3<Double> = .zero
    var opacity: Double = 1
    /// The backdrop's rows, top to bottom; it shades with height.
    var backdropRowsRGB: [SIMD3<Double>] = []
    let onBackdrop: Bool

    var base: Color { Self.color(baseRGB) }
    var terminal: Color { Self.color(terminalRGB) }
    var chrome: Color { Self.color(chromeRGB) }
    var isLight: Bool { terminal.isLight }
    var terminalHex: String { Self.hex(terminalRGB) }

    static func resolve(background: Color) -> EffectiveSurface {
        let base = rgb(background)
        let effects = EffectManager.shared
        guard effects.isBackdropEnabled else {
            return EffectiveSurface(baseRGB: base, terminalRGB: base, chromeRGB: base, onBackdrop: false)
        }
        // The Mac desktop share behind a transparent backdrop is unknowable; treat it as opaque
        let sample = backdropPalette(look: effects.backdropLook).backdropSample
        let opacity = TransparencyManager.shared.effectiveBackgroundOpacity
        return EffectiveSurface(
            baseRGB: base,
            terminalRGB: base * opacity + sample.average * (1 - opacity),
            chromeRGB: sample.topBand,
            backdropRGB: sample.average,
            opacity: opacity,
            backdropRowsRGB: sample.rows,
            onBackdrop: true
        )
    }

    /// The backdrop at a height in the window, 0 at the top; nil off the backdrop.
    func backdrop(atHeight fraction: Double) -> Color? {
        guard onBackdrop, !backdropRowsRGB.isEmpty, fraction.isFinite else { return nil }
        let row = Int(min(max(fraction, 0), 1) * Double(backdropRowsRGB.count))
        return Self.color(backdropRowsRGB[min(row, backdropRowsRGB.count - 1)])
    }

    /// The fill that, drawn at the terminal's opacity over the backdrop, shows
    /// `target`: translucent surfaces then pair with opaque ones derived from `terminal`.
    func translucentFill(showing target: Color) -> Color {
        guard onBackdrop, opacity > 0.01 else { return target }
        let fill = (Self.rgb(target) - backdropRGB * (1 - opacity)) / opacity
        return Self.color(fill.clamped(lowerBound: .zero, upperBound: .one))
    }

    static func resolve(backgroundHex: String) -> EffectiveSurface? {
        Color(hex: backgroundHex).map { resolve(background: $0) }
    }

    /// Ghostty lines for a surface drawing `backgroundHex` over the backdrop:
    /// programs that ask (OSC 11) get the composited color to derive from.
    static func ghosttyConfigLines(backgroundHex: String?) -> [String] {
        guard let backgroundHex, let surface = resolve(backgroundHex: backgroundHex), surface.onBackdrop else { return [] }
        return ["osc-color-report-background = \(surface.terminalHex)"]
    }

    /// Clears `ghosttyConfigLines` in a config cloned from one that set them.
    static let resetGhosttyConfigLines = ["osc-color-report-background ="]

    private static var cachedPalette: (colors: EffectThemeColors, look: ThemeGradientLook, palette: ThemeGradientPalette)?

    /// The backdrop follows the global theme. Read from ThemeManager rather
    /// than EffectManager so a config written on themeDidChange is never stale.
    private static func backdropPalette(look: ThemeGradientLook) -> ThemeGradientPalette {
        let colors = ThemeManager.shared.currentThemeInfo.map { EffectThemeColors(from: $0.colors) } ?? .defaults
        if let cachedPalette, cachedPalette.colors == colors, cachedPalette.look == look { return cachedPalette.palette }
        let palette = ThemeGradientPalette(themeColors: colors, look: look)
        cachedPalette = (colors, look, palette)
        return palette
    }

    // MARK: Color math

    private static func rgb(_ color: Color) -> SIMD3<Double> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Double(r), Double(g), Double(b))
    }

    private static func color(_ rgb: SIMD3<Double>) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    private static func hex(_ rgb: SIMD3<Double>) -> String {
        let bytes = [rgb.x, rgb.y, rgb.z].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
    }
}
