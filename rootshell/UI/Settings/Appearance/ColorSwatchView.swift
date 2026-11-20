//
//  ColorSwatchView.swift
//  rootshell
//
//  Color swatch preview for themes
//

import SwiftUI
import os

/// Displays a horizontal row of color swatches representing a theme
struct ColorSwatchView: View {
    let colors: ThemeManager.ThemeInfo.ThemeColors

    private let swatchSize: CGFloat = 16
    private let swatchSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: swatchSpacing) {
            // Background color
            colorCircle(hex: colors.background)

            // Foreground color
            colorCircle(hex: colors.foreground)

            // Palette colors (first 6)
            ForEach(Array(colors.palette.prefix(6)), id: \.self) { colorHex in
                colorCircle(hex: colorHex)
            }
        }
    }

    private func colorCircle(hex: String) -> some View {
        Circle()
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: swatchSize, height: swatchSize)
    }
}

// MARK: - Color Extension for Hex Parsing

/// Cached parsed result for `Color(hex:)`.
///
/// The crash logs caught `MainView.body` re-entering `CFCharacterSetIsCharacterMember`
/// inside `NSScanner.scanHexLongLong:` — every body re-evaluation runs the styling
/// computed properties (`tabBarBackgroundColor`, `selectedTabBackgroundColor`, etc.),
/// which independently invoke `Color(hex: themeColors.background)` for the same handful
/// of theme strings. Memoizing the parse on the hex string is byte-identical to the
/// caller (same RGB → same Color components) and removes the Scanner+CharacterSet
/// hot path from the body.
private enum HexParseResult: Sendable {
    case parsed(r: Double, g: Double, b: Double)
    case invalid
}

private nonisolated let _hexParseCache = OSAllocatedUnfairLock<[String: HexParseResult]>(
    initialState: [:]
)

extension ColorScheme {
    /// The appearance whose artwork and semantic colors suit a surface.
    init(lightSurface: Bool) {
        self = lightSurface ? .light : .dark
    }
}

extension Color {
    /// Initialize a Color from a hex string (e.g., "#1e1e2e" or "1e1e2e")
    nonisolated init?(hex: String) {
        if let cached = _hexParseCache.withLock({ $0[hex] }) {
            switch cached {
            case .parsed(let r, let g, let b):
                self.init(red: r, green: g, blue: b)
                return
            case .invalid:
                return nil
            }
        }

        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            _hexParseCache.withLock { $0[hex] = .invalid }
            return nil
        }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        _hexParseCache.withLock { $0[hex] = .parsed(r: r, g: g, b: b) }
        self.init(red: r, green: g, blue: b)
    }

    /// Convert Color to hex string (e.g., "#1e1e2e")
    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let toByte: (CGFloat) -> Int = { component in
            Int((max(0, min(component, 1)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", toByte(r), toByte(g), toByte(b))
    }

    /// Blend this color with white by a given amount (0.0 = no change, 1.0 = pure white)
    func blendedWithWhite(_ amount: CGFloat) -> Color {
        // Convert to UIColor to access components
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        // Blend toward white
        let newR = r + (1.0 - r) * amount
        let newG = g + (1.0 - g) * amount
        let newB = b + (1.0 - b) * amount

        return Color(red: newR, green: newG, blue: newB).opacity(a)
    }

    /// Blend this color with black by a given amount (0.0 = no change, 1.0 = pure black)
    func blendedWithBlack(_ amount: CGFloat) -> Color {
        // Convert to UIColor to access components
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        // Blend toward black
        let newR = r * (1.0 - amount)
        let newG = g * (1.0 - amount)
        let newB = b * (1.0 - amount)

        return Color(red: newR, green: newG, blue: newB).opacity(a)
    }

    /// Blend this color toward another color by a given amount.
    func blended(toward other: Color, amount: CGFloat) -> Color {
        let fromColor = UIColor(self)
        let toColor = UIColor(other)

        var fromR: CGFloat = 0, fromG: CGFloat = 0, fromB: CGFloat = 0, fromA: CGFloat = 0
        var toR: CGFloat = 0, toG: CGFloat = 0, toB: CGFloat = 0, toA: CGFloat = 0

        fromColor.getRed(&fromR, green: &fromG, blue: &fromB, alpha: &fromA)
        toColor.getRed(&toR, green: &toG, blue: &toB, alpha: &toA)

        let t = max(0, min(amount, 1))
        let r = fromR + (toR - fromR) * t
        let g = fromG + (toG - fromG) * t
        let b = fromB + (toB - fromB) * t
        let a = fromA + (toA - fromA) * t

        return Color(red: r, green: g, blue: b).opacity(a)
    }

    /// Derive a less aggressive accent for themed sheet UI while preserving hue.
    func adjustedSheetTint(on background: Color) -> Color {
        let contrast = contrastRatio(against: background)
        guard contrast < 2.6 else {
            return self
        }

        let softened = blended(toward: background, amount: background.isLight ? 0.12 : 0.22)
        let softenedUIColor = UIColor(softened)

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard softenedUIColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return background.isLight
                ? softened.blendedWithBlack(0.12)
                : softened.blendedWithWhite(0.06)
        }

        let adjustedSaturation = min(saturation, background.isLight ? 0.68 : 0.52)
        let adjustedBrightness = background.isLight
            ? min(max(brightness, 0.28), 0.62)
            : min(max(brightness, 0.58), 0.82)

        return Color(
            hue: Double(hue),
            saturation: Double(adjustedSaturation),
            brightness: Double(adjustedBrightness),
            opacity: Double(alpha)
        )
    }

    /// Calculate relative luminance (0.0 = dark, 1.0 = light)
    /// Uses the formula from WCAG 2.0
    /// `nonisolated`: pure color math, called off the main thread by ThemeManager's
    /// background theme parse.
    nonisolated var luminance: CGFloat {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        // Apply gamma correction and weight by human perception
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Returns true if this color is considered "light" (luminance > 0.5)
    var isLight: Bool {
        luminance > 0.5
    }

    /// The color seen where this draws at its own alpha over `backdrop`.
    /// For measuring a surface: only the result's RGB is meaningful.
    func composited(over backdrop: Color) -> Color {
        backdrop.blended(toward: self, amount: UIColor(self).cgColor.alpha)
    }

    /// HSV saturation (0.0 = gray/white, 1.0 = fully saturated)
    var saturation: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }

    /// HSV hue (0.0–1.0, wrapping; 0 = red, 0.33 = green, 0.67 = blue)
    var hue: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    /// Shortest angular distance between two hues on the 0–1 color wheel.
    /// Returns a value in 0...0.5 (0 = identical, 0.5 = opposite).
    func hueDifference(from otherHue: CGFloat) -> CGFloat {
        let diff = abs(hue - otherHue)
        return min(diff, 1.0 - diff)
    }

    /// WCAG contrast ratio against another color.
    func contrastRatio(against other: Color) -> CGFloat {
        let l1 = luminance
        let l2 = other.luminance
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - Adaptive Blend Factors

    /// Blend factor for selected/primary tab backgrounds, scaled by luminance.
    /// Near-black (< 0.08): 0.18 (original fixed value).
    /// Medium-dark (0.08–0.32): scales up to ~0.30 for better differentiation.
    var adaptivePrimaryBlend: CGFloat {
        let lum = luminance
        if lum < 0.08 { return 0.18 }
        if lum > 0.32 { return 0.18 }
        // Linear ramp: 0.18 at 0.08 → 0.30 at 0.20, then back to 0.18 at 0.32
        let peak: CGFloat = 0.20
        let maxBlend: CGFloat = 0.30
        let minBlend: CGFloat = 0.18
        if lum <= peak {
            let t = (lum - 0.08) / (peak - 0.08)
            return minBlend + (maxBlend - minBlend) * t
        } else {
            let t = (lum - peak) / (0.32 - peak)
            return maxBlend - (maxBlend - minBlend) * t
        }
    }

    /// Blend factor for unselected/secondary tab backgrounds, scaled by luminance.
    /// Near-black (< 0.08): 0.08 (original fixed value).
    /// Medium-dark (0.08–0.32): scales up to ~0.14 for better differentiation.
    var adaptiveSecondaryBlend: CGFloat {
        let lum = luminance
        if lum < 0.08 { return 0.08 }
        if lum > 0.32 { return 0.08 }
        let peak: CGFloat = 0.20
        let maxBlend: CGFloat = 0.14
        let minBlend: CGFloat = 0.08
        if lum <= peak {
            let t = (lum - 0.08) / (peak - 0.08)
            return minBlend + (maxBlend - minBlend) * t
        } else {
            let t = (lum - peak) / (0.32 - peak)
            return maxBlend - (maxBlend - minBlend) * t
        }
    }

    // MARK: - Hue-Preserving Adjustments

    /// Darken this color by reducing brightness in HSB space, preserving hue and saturation.
    /// Falls back to `blendedWithBlack` for grayscale colors.
    func darkenedPreservingHue(_ amount: CGFloat) -> Color {
        let uiColor = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.02 else {
            return blendedWithBlack(amount)
        }
        let newBrightness = max(b * (1.0 - amount), 0)
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(newBrightness), opacity: Double(a))
    }

    /// Lighten this color by increasing brightness in HSB space, with slight desaturation.
    /// Falls back to `blendedWithWhite` for grayscale colors.
    func lightenedPreservingHue(_ amount: CGFloat) -> Color {
        let uiColor = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.02 else {
            return blendedWithWhite(amount)
        }
        let newBrightness = min(b + (1.0 - b) * amount, 1.0)
        let newSaturation = s * (1.0 - amount * 0.3) // slight desaturation
        return Color(hue: Double(h), saturation: Double(newSaturation), brightness: Double(newBrightness), opacity: Double(a))
    }

    // MARK: - Ghostty Keyword Color Resolution

    /// Resolve Ghostty keyword color values (e.g. `cell-foreground`) to concrete hex strings.
    /// Returns the input unchanged if it's already a hex color.
    ///
    /// Note: In Ghostty's runtime, `cell-foreground`/`cell-background` refer to the current cell's
    /// colors which can vary per-cell. Outside the terminal surface (swatches, accent derivation,
    /// sheet tints) we approximate with the theme's global foreground/background — the best
    /// available stand-in for UI preview purposes.
    /// `nonisolated`: pure string mapping, called off the main thread by
    /// ThemeManager's background theme parse.
    nonisolated static func resolveKeywordColor(_ value: String, foreground: String, background: String) -> String {
        switch value.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cell-foreground": return foreground
        case "cell-background": return background
        default: return value
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        // Catppuccin Mocha colors
        ColorSwatchView(colors: ThemeManager.ThemeInfo.ThemeColors(
            background: "#1e1e2e",
            foreground: "#cdd6f4",
            cursor: "#f5e0dc",
            palette: [
                "#45475a",
                "#f38ba8",
                "#a6e3a1",
                "#f9e2af",
                "#89b4fa",
                "#f5c2e7"
            ]
        ))

        // Dracula-style colors
        ColorSwatchView(colors: ThemeManager.ThemeInfo.ThemeColors(
            background: "#282a36",
            foreground: "#f8f8f2",
            cursor: "#f8f8f2",
            palette: [
                "#21222c",
                "#ff5555",
                "#50fa7b",
                "#f1fa8c",
                "#bd93f9",
                "#ff79c6"
            ]
        ))
    }
    .padding()
}
