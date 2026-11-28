//
//  GitDiffPaletteDerivation.swift
//  rootshell
//
//  The diff's colours, taken from the terminal theme's ANSI palette and made
//  readable on the panel surface. A theme colour that is not the hue its role
//  needs (a grey "green", a red equal to its green) gives way to the standard
//  colour, so additions always read green and deletions red. Pure sRGB maths.
//

import Foundation

/// An opaque sRGB colour, components 0...1.
nonisolated struct GitDiffRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var text = Substring(hex.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    static let white = GitDiffRGB(red: 1, green: 1, blue: 1)
    static let black = GitDiffRGB(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: GitDiffRGB) -> Double {
        let a = luminance + 0.05, b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    func mixed(with other: GitDiffRGB, _ amount: Double) -> GitDiffRGB {
        let t = min(max(amount, 0), 1)
        return GitDiffRGB(red: red + (other.red - red) * t,
                          green: green + (other.green - green) * t,
                          blue: blue + (other.blue - blue) * t)
    }

    /// This colour drawn at `alpha` over `backdrop`.
    func composited(over backdrop: GitDiffRGB, alpha: Double) -> GitDiffRGB {
        backdrop.mixed(with: self, alpha)
    }

    /// HSV hue in degrees, saturation and value.
    var hsv: (hue: Double, saturation: Double, value: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
        guard maxC > 0, delta > 0 else { return (0, 0, maxC) }
        var hue: Double
        if maxC == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, delta / maxC, maxC)
    }
}

/// Opacities of the change tints over the panel surface.
nonisolated enum GitDiffTint {
    static func row(isDark: Bool) -> Double { isDark ? 0.15 : 0.12 }
    /// A step stronger than the row, so numbers stay a column.
    static func gutter(isDark: Bool) -> Double { isDark ? 0.24 : 0.20 }
    /// The changed span inside a line.
    static func emphasis(isDark: Bool) -> Double { isDark ? 0.40 : 0.32 }
    static func hunk(isDark: Bool) -> Double { isDark ? 0.10 : 0.08 }
}

/// Every colour the diff draws, before any opacity.
nonisolated struct GitDiffColors: Hashable, Sendable {
    /// Code text; nil keeps the system's primary label colour.
    var text: GitDiffRGB?
    // Foregrounds: markers, counts and status badges.
    var addition: GitDiffRGB
    var deletion: GitDiffRGB
    var modified: GitDiffRGB
    var renamed: GitDiffRGB
    var conflicted: GitDiffRGB
    // The hues the rows and hunk headers are tinted with.
    var additionTint: GitDiffRGB
    var deletionTint: GitDiffRGB
    var modifiedTint: GitDiffRGB
    // Syntax.
    var keyword: GitDiffRGB
    var string: GitDiffRGB
    var comment: GitDiffRGB
    var number: GitDiffRGB

    /// Tuned for the system's light and dark backgrounds.
    static func standard(isDark: Bool) -> GitDiffColors {
        func rgb(_ dark: (Double, Double, Double), _ light: (Double, Double, Double)) -> GitDiffRGB {
            let c = isDark ? dark : light
            return GitDiffRGB(red: c.0, green: c.1, blue: c.2)
        }
        let addition = rgb((0.25, 0.73, 0.31), (0.10, 0.50, 0.22))
        let deletion = rgb((0.97, 0.32, 0.29), (0.81, 0.13, 0.18))
        let modified = rgb((0.47, 0.66, 0.95), (0.04, 0.41, 0.85))
        return GitDiffColors(
            text: nil,
            addition: addition,
            deletion: deletion,
            modified: modified,
            renamed: rgb((0.74, 0.55, 0.95), (0.51, 0.31, 0.87)),
            conflicted: rgb((0.89, 0.70, 0.26), (0.60, 0.40, 0.0)),
            additionTint: addition,
            deletionTint: deletion,
            modifiedTint: modified,
            keyword: rgb((0.86, 0.55, 0.80), (0.61, 0.14, 0.58)),
            string: rgb((0.93, 0.70, 0.47), (0.72, 0.31, 0.05)),
            comment: rgb((0.56, 0.56, 0.56), (0.45, 0.45, 0.45)),
            number: rgb((0.50, 0.78, 0.93), (0.05, 0.42, 0.66)))
    }
}

nonisolated enum GitDiffPaletteDerivation {
    static let textContrast = 4.5
    /// Over the strongest tints: the changed span and the number gutter.
    static let tintedContrast = 3.0

    /// The ANSI slot pair and hue window a role draws from.
    private struct Role {
        let normal: Int
        let bright: Int
        let hue: Double
        let spread: Double

        static let red = Role(normal: 1, bright: 9, hue: 0, spread: 32)
        // Olive through teal: classic themes ship both as their green.
        static let green = Role(normal: 2, bright: 10, hue: 125, spread: 70)
        static let yellow = Role(normal: 3, bright: 11, hue: 48, spread: 26)
        static let blue = Role(normal: 4, bright: 12, hue: 218, spread: 52)
        static let magenta = Role(normal: 5, bright: 13, hue: 300, spread: 48)
        static let cyan = Role(normal: 6, bright: 14, hue: 185, spread: 45)

        func accepts(_ color: GitDiffRGB) -> Bool {
            let hsv = color.hsv
            guard hsv.saturation >= 0.18, hsv.value >= 0.25 else { return false }
            return GitDiffPaletteDerivation.hueDistance(hsv.hue, hue) <= spread
        }
    }

    /// `ansi` is the theme's 16 colours in slot order; anything shorter is
    /// ignored, since a gap would shift every slot after it.
    static func colors(surface: GitDiffRGB, isDark: Bool, foreground: GitDiffRGB?, ansi: [GitDiffRGB]) -> GitDiffColors {
        let standard = GitDiffColors.standard(isDark: isDark)
        guard ansi.count >= 16 else { return standard }

        /// Tints follow the theme's usual slot, the normal one.
        func tint(_ role: Role) -> GitDiffRGB? {
            [ansi[role.normal], ansi[role.bright]].first(where: role.accepts)
        }
        /// Of the two slots that fit, the one that stands further off the surface.
        func pick(_ role: Role) -> GitDiffRGB? {
            [ansi[role.normal], ansi[role.bright]].filter(role.accepts)
                .max { $0.contrast(with: surface) < $1.contrast(with: surface) }
        }

        var additionTint = tint(.green)
        var deletionTint = tint(.red)
        var additionPick = pick(.green)
        var deletionPick = pick(.red)
        // The pair must tell apart at a glance; if not, both go standard.
        if let add = additionTint, let del = deletionTint, hueDistance(add.hsv.hue, del.hsv.hue) < 45 {
            additionTint = nil; deletionTint = nil; additionPick = nil; deletionPick = nil
        }

        let additionBase = additionTint ?? standard.additionTint
        let deletionBase = deletionTint ?? standard.deletionTint
        let modifiedBase = tint(.blue) ?? standard.modifiedTint

        let row = GitDiffTint.row(isDark: isDark)
        let gutter = GitDiffTint.gutter(isDark: isDark)
        let emphasis = GitDiffTint.emphasis(isDark: isDark)
        let addRow = additionBase.composited(over: surface, alpha: row)
        let delRow = deletionBase.composited(over: surface, alpha: row)
        // The span and the gutter draw over the row tint, not the bare surface.
        let addEmphasis = additionBase.composited(over: addRow, alpha: emphasis)
        let delEmphasis = deletionBase.composited(over: delRow, alpha: emphasis)

        let toward = isDark ? GitDiffRGB.white : .black
        /// Code sits on plain, added and removed rows, and on the changed span.
        func code(_ color: GitDiffRGB) -> GitDiffRGB {
            readable(color, toward: toward, targets: [
                (surface, textContrast), (addRow, textContrast), (delRow, textContrast),
                (addEmphasis, tintedContrast), (delEmphasis, tintedContrast),
            ])
        }
        /// A marker, count or badge in its own hue, over its own tint at most.
        func accent(_ color: GitDiffRGB, tint: GitDiffRGB) -> GitDiffRGB {
            readable(color, toward: toward, targets: [
                (surface, textContrast), (tint.composited(over: tint.composited(over: surface, alpha: row), alpha: gutter), tintedContrast),
            ])
        }
        func role(_ role: Role, standard fallback: GitDiffRGB) -> GitDiffRGB {
            let color = pick(role) ?? fallback
            return accent(color, tint: color)
        }
        /// Syntax keeps the theme's hue whatever it is; only contrast is fixed.
        func syntax(_ role: Role) -> GitDiffRGB {
            let slots = [ansi[role.normal], ansi[role.bright]]
            return code(slots.max { $0.contrast(with: surface) < $1.contrast(with: surface) } ?? slots[0])
        }

        // Bright black is most themes' comment grey; a near-invisible one is lifted.
        let commentBase = ansi[8].contrast(with: surface) >= 2 ? ansi[8] : (foreground ?? toward).mixed(with: surface, 0.45)

        return GitDiffColors(
            text: foreground.map(code),
            addition: accent(additionPick ?? standard.addition, tint: additionBase),
            deletion: accent(deletionPick ?? standard.deletion, tint: deletionBase),
            modified: role(.blue, standard: standard.modified),
            renamed: role(.magenta, standard: standard.renamed),
            conflicted: role(.yellow, standard: standard.conflicted),
            additionTint: additionBase,
            deletionTint: deletionBase,
            modifiedTint: modifiedBase,
            keyword: syntax(.magenta),
            string: syntax(.yellow),
            comment: code(commentBase),
            number: syntax(.cyan))
    }

    /// Moves `color` toward `target` in small steps until every background
    /// clears its minimum, then the other way: a mid-grey page can need the
    /// opposite extreme. The closest step wins when none clears.
    static func readable(_ color: GitDiffRGB, toward target: GitDiffRGB,
                         targets: [(GitDiffRGB, Double)]) -> GitDiffRGB {
        func shortfall(_ c: GitDiffRGB) -> Double {
            targets.reduce(0) { max($0, $1.1 - c.contrast(with: $1.0)) }
        }
        var best = color
        var bestShortfall = shortfall(color)
        guard bestShortfall > 0 else { return color }
        let opposite: GitDiffRGB = target == .white ? .black : .white
        for extreme in [target, opposite] {
            for step in 1...12 {
                let candidate = color.mixed(with: extreme, Double(step) / 12)
                let gap = shortfall(candidate)
                if gap <= 0 { return candidate }
                if gap < bestShortfall { best = candidate; bestShortfall = gap }
            }
        }
        return best
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
