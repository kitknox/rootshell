//
//  ThemeGradientPalette.swift
//  rootshell
//
//  Theme Gradient colors: a style picks the shader's three colors from the
//  terminal theme, then the look's vibrance and brightness apply.
//

import Foundation

/// How the gradient draws its colors from the theme. Custom uses the look's own colors.
enum ThemeGradientStyle: String, CaseIterable, Identifiable {
    case theme, glow, contrast, spectrum, tonal, warm, cool, mist, custom

    var id: String { rawValue }

    static var presets: [ThemeGradientStyle] { allCases.filter { $0 != .custom } }
}

/// Everything besides the theme that shapes the gradient colors.
struct ThemeGradientLook: Equatable {
    var style: ThemeGradientStyle = .theme
    /// Primary, accent and mid in sRGB; set once the user customizes.
    var customColors: [SIMD3<Double>]?
    var vibrance: Double = 1
    var brightness: Double = 1

    static let vibranceRange = 0.0...1.6
    static let brightnessRange = 0.5...1.5

    var hasAdjustments: Bool { vibrance != 1 || brightness != 1 }

    init() {}

    init(configuration data: [String: Any]) {
        if let raw = data["style"] as? String, let style = ThemeGradientStyle(rawValue: raw) {
            self.style = style
        }
        if let hexes = data["customColors"] as? [String] {
            let colors = hexes.compactMap { ThemeGradientPalette.rgb(hex: $0) }
            if colors.count == 3 { customColors = colors }
        }
        if let vibrance = data["vibrance"] as? Double {
            self.vibrance = min(max(vibrance, Self.vibranceRange.lowerBound), Self.vibranceRange.upperBound)
        }
        if let brightness = data["brightness"] as? Double {
            self.brightness = min(max(brightness, Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
        }
    }

    func encode(into data: inout [String: Any]) {
        data["style"] = style.rawValue
        if let customColors { data["customColors"] = customColors.map { ThemeGradientPalette.hex($0) } }
        data["vibrance"] = vibrance
        data["brightness"] = brightness
    }
}

/// Shader colors derived once per theme and look: the primary base, an
/// accent glow, and a mid tone that bridges them.
struct ThemeGradientPalette: Equatable {
    var primary: SIMD3<Double>
    var accent: SIMD3<Double>
    var mid: SIMD3<Double>
    var isLight: Bool

    var colors: [SIMD3<Double>] { [primary, accent, mid] }

    private struct HSB {
        var h: Double
        var s: Double
        var b: Double
    }

    private struct Candidate {
        var hsb: HSB
        var order: Int
        var score: Double = 0
    }

    init(themeColors: EffectThemeColors, look: ThemeGradientLook = ThemeGradientLook()) {
        let background = Self.rgb(hex: themeColors.background) ?? SIMD3(0.1, 0.1, 0.15)
        isLight = Self.isLight(background)
        var colors: [SIMD3<Double>]
        if look.style == .custom, let custom = look.customColors, custom.count == 3 {
            colors = custom
        } else {
            colors = Self.styleColors(themeColors: themeColors, style: look.style)
        }
        if look.hasAdjustments {
            colors = colors.map {
                var hsb = Self.hsb($0)
                hsb.s = min(1, hsb.s * look.vibrance)
                hsb.b = min(1, hsb.b * look.brightness)
                return Self.rgb(hsb)
            }
        }
        primary = colors[0]
        accent = colors[1]
        mid = colors[2]
    }

    /// A style's colors before the look's adjustments; custom starts from the theme style.
    static func styleColors(themeColors: EffectThemeColors, style: ThemeGradientStyle) -> [SIMD3<Double>] {
        let background = Self.rgb(hex: themeColors.background) ?? SIMD3(0.1, 0.1, 0.15)
        let foreground = Self.rgb(hex: themeColors.foreground) ?? SIMD3(0.8, 0.8, 0.85)
        let isLight = Self.isLight(background)
        let style = style == .custom ? ThemeGradientStyle.theme : style

        // ANSI 0, 7, 8 and 15 are the theme's grays
        let indices = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
        var hexes = indices.filter { $0 < themeColors.palette.count }.map { themeColors.palette[$0] }
        hexes.append(themeColors.cursor)
        var candidates = hexes.enumerated().compactMap { order, hex -> Candidate? in
            guard let rgb = Self.rgb(hex: hex) else { return nil }
            let hsb = Self.hsb(rgb)
            guard hsb.s >= 0.15, hsb.b >= 0.15 else { return nil }
            return Candidate(hsb: hsb, order: order)
        }

        if candidates.isEmpty {
            if style == .theme || style == .tonal || style == .mist {
                // Monochrome theme: a dim wash of the foreground with a lighter glow
                let wash = foreground + (background - foreground) * 0.7
                let faint = foreground + (background - foreground) * 0.45
                return [wash, faint, (wash + faint) / 2]
            }
            // Other styles still need hues to work with
            candidates = [0.62, 0.75, 0.5, 0.95, 0.08, 0.32].enumerated().map {
                Candidate(hsb: HSB(h: $1, s: 0.5, b: 0.7), order: $0)
            }
        }

        // Hue prevalence stands in for the pixel share used on artwork
        for i in candidates.indices {
            let hsb = candidates[i].hsb
            let neighbors = candidates.filter { Self.hueDistance($0.hsb.h, hsb.h) <= 0.08 }.count
            let prevalence = Double(neighbors) / Double(candidates.count)
            let brightness = 1 - abs(hsb.b - 0.5) * 2
            candidates[i].score = hsb.s * 0.4 + brightness * 0.3 + prevalence * 0.3
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        let ranked = candidates.map(\.hsb)

        let tones: (HSB, HSB, HSB)
        switch style {
        case .theme, .custom: tones = themeTones(ranked, isLight: isLight)
        case .glow: tones = glowTones(ranked, background: Self.hsb(background), isLight: isLight)
        case .contrast: tones = contrastTones(ranked, isLight: isLight)
        case .spectrum: tones = spectrumTones(ranked, isLight: isLight)
        case .tonal: tones = tonalTones(ranked, isLight: isLight)
        case .warm: tones = temperatureTones(ranked, peak: 0.03, fallback: (0.97, 0.07), isLight: isLight)
        case .cool: tones = temperatureTones(ranked, peak: 0.6, fallback: (0.62, 0.5), isLight: isLight)
        case .mist: tones = mistTones(ranked, background: Self.hsb(background), isLight: isLight)
        }
        return [Self.rgb(tones.0), Self.rgb(tones.1), Self.rgb(tones.2)]
    }

    // MARK: Styles

    /// Ranked theme colors: a primary and the next distinct hue.
    private static func themeTones(_ ranked: [HSB], isLight: Bool) -> (HSB, HSB, HSB) {
        let primary = tonePrimary(ranked[0], isLight: isLight)
        var accent: HSB
        if let match = ranked.dropFirst().first(where: { hueDistance($0.h, primary.h) > 0.15 }) {
            accent = match
        } else {
            let b = primary.b < 0.3 ? primary.b * 1.5 : primary.b * 0.8
            accent = HSB(h: wrap(primary.h + 0.15), s: min(1, primary.s * 1.2), b: min(max(b, 0.4), 0.8))
        }
        accent = toneAccent(accent, isLight: isLight)
        return (primary, accent, blend(primary, accent))
    }

    /// A deep base near the background under a bright theme glow.
    private static func glowTones(_ ranked: [HSB], background: HSB, isLight: Bool) -> (HSB, HSB, HSB) {
        let lead = ranked[0]
        let second = ranked.dropFirst().first { (0.04...0.2).contains(hueDistance($0.h, lead.h)) }
            ?? HSB(h: wrap(lead.h + 0.08), s: lead.s, b: lead.b)
        if isLight {
            let primary = HSB(h: lead.h, s: 0.1, b: 0.95)
            let accent = HSB(h: lead.h, s: min(1, lead.s * 1.1), b: min(lead.b, 0.85))
            return (primary, accent, HSB(h: second.h, s: second.s * 0.7, b: 0.9))
        }
        let primary = HSB(h: lead.h, s: min(lead.s, 0.6), b: min(max(background.b * 1.3, 0.12), 0.22))
        let accent = HSB(h: lead.h, s: min(1, lead.s * 1.05), b: 0.75)
        let mid = HSB(h: second.h, s: second.s * 0.85, b: 0.45)
        return (primary, accent, mid)
    }

    /// The primary against the theme's most opposite hue.
    private static func contrastTones(_ ranked: [HSB], isLight: Bool) -> (HSB, HSB, HSB) {
        var primary = tonePrimary(ranked[0], isLight: isLight)
        if !isLight { primary.b *= 0.8 }
        let far = ranked.dropFirst().filter { $0.s >= 0.25 }
            .max { hueDistance($0.h, primary.h) < hueDistance($1.h, primary.h) }
        var accent: HSB
        if let far, hueDistance(far.h, primary.h) >= 0.3 {
            accent = far
        } else {
            accent = HSB(h: wrap(primary.h + 0.5), s: max(primary.s, 0.5), b: 0.65)
        }
        accent = toneAccent(accent, isLight: isLight)
        // A muted primary bridges the poles; a hue mean would land on an unrelated color
        let mid = HSB(h: primary.h, s: primary.s * 0.55, b: primary.b * 0.8)
        return (primary, accent, mid)
    }

    /// Three distinct theme hues, based on the theme's second color.
    private static func spectrumTones(_ ranked: [HSB], isLight: Bool) -> (HSB, HSB, HSB) {
        let lead = ranked[0]
        let second = ranked.dropFirst().first { hueDistance($0.h, lead.h) > 0.18 }
            ?? HSB(h: wrap(lead.h + 1.0 / 3), s: lead.s, b: 0.65)
        let primary = tonePrimary(second, isLight: isLight)
        let accent = toneAccent(lead, isLight: isLight)
        var mid = ranked.dropFirst().first {
            hueDistance($0.h, lead.h) > 0.18 && hueDistance($0.h, second.h) > 0.18
        } ?? HSB(h: wrap(lead.h + 2.0 / 3), s: lead.s, b: 0.6)
        if !isLight { mid.b = min(mid.b, 0.6) }
        return (primary, accent, mid)
    }

    /// One hue at several depths.
    private static func tonalTones(_ ranked: [HSB], isLight: Bool) -> (HSB, HSB, HSB) {
        let primary = tonePrimary(ranked[0], isLight: isLight)
        let accent = toneAccent(HSB(h: primary.h, s: primary.s * 0.7, b: min(1, primary.b * 1.5 + 0.1)), isLight: isLight)
        let mid = HSB(h: wrap(primary.h + 0.02), s: min(1, primary.s * 1.1), b: primary.b * 0.7)
        return (primary, accent, mid)
    }

    /// The theme colors nearest a hue `peak`, or the fallback hues when the theme has none.
    private static func temperatureTones(_ ranked: [HSB], peak: Double, fallback: (Double, Double),
                                         isLight: Bool) -> (HSB, HSB, HSB) {
        func closeness(_ h: Double) -> Double { cos(2 * .pi * (h - peak)) }
        let near = ranked.filter { closeness($0.h) >= 0.7 }
            .sorted { closeness($0.h) + $0.s > closeness($1.h) + $1.s }
        let typical = ranked.map(\.s).reduce(0, +) / Double(ranked.count)
        var primary = near.first ?? HSB(h: fallback.0, s: max(typical, 0.55), b: 0.6)
        var accent: HSB
        if let other = near.dropFirst().max(by: { hueDistance($0.h, primary.h) < hueDistance($1.h, primary.h) }),
           hueDistance(other.h, primary.h) >= 0.04 {
            accent = other
        } else if near.isEmpty {
            accent = HSB(h: fallback.1, s: primary.s, b: 0.65)
        } else {
            // Step toward the peak from whichever side the primary sits
            let toward = signedHueDelta(from: primary.h, to: peak)
            let step = abs(toward) < 0.02 ? 0.07 : 0.07 * (toward < 0 ? -1 : 1)
            accent = HSB(h: wrap(primary.h + step), s: primary.s, b: primary.b)
        }
        // Saturated reds and blues turn loud as a full-window base
        primary = tonePrimary(primary, isLight: isLight)
        primary.s = min(primary.s, 0.7)
        accent = toneAccent(accent, isLight: isLight)
        accent.s = min(accent.s, 0.8)
        return (primary, accent, blend(primary, accent))
    }

    /// Close to the background, with a faint theme accent.
    private static func mistTones(_ ranked: [HSB], background: HSB, isLight: Bool) -> (HSB, HSB, HSB) {
        let lead = ranked[0]
        let hue = background.s > 0.1 ? background.h : lead.h
        let primary: HSB
        let accent: HSB
        if isLight {
            primary = HSB(h: hue, s: 0.16, b: 0.92)
            accent = HSB(h: lead.h, s: min(lead.s * 0.35, 0.3), b: 0.88)
        } else {
            primary = HSB(h: hue, s: min(max(background.s, 0.2), 0.45), b: min(max(background.b * 1.4, background.b + 0.06), 0.3))
            accent = HSB(h: lead.h, s: lead.s * 0.4, b: min(lead.b, 0.42))
        }
        return (primary, accent, blend(primary, accent))
    }

    // MARK: Tone

    private static func tonePrimary(_ color: HSB, isLight: Bool) -> HSB {
        var c = color
        if c.b > 0.7 {
            c.b *= 0.7
            c.s = min(1, c.s * 1.1)
        } else if c.b > 0.5 {
            c.b *= 0.85
        }
        // Theme colors run brighter than artwork; keep dark themes rich, not pastel
        if !isLight { c.b = min(c.b, 0.5) }
        return c
    }

    private static func toneAccent(_ color: HSB, isLight: Bool) -> HSB {
        var c = color
        if !isLight { c.b = min(c.b, 0.7) }
        return c
    }

    /// Circular hue mean so red/magenta pairs don't average to green.
    private static func blend(_ a: HSB, _ b: HSB) -> HSB {
        let angleA = a.h * 2 * .pi
        let angleB = b.h * 2 * .pi
        let h = wrap(atan2(sin(angleA) + sin(angleB), cos(angleA) + cos(angleB)) / (2 * .pi))
        return HSB(h: h, s: max(a.s, b.s) * 0.8, b: (a.b + b.b) / 2)
    }

    // MARK: Backdrop sample

    /// Area-averaged backdrop shading, in sRGB like the backdrop drawable.
    struct Sample: Equatable {
        var average: SIMD3<Double>
        /// The strip under the status bar and top tabs.
        var topBand: SIMD3<Double>
        /// Each row's average, top to bottom, for chrome elsewhere in the window.
        var rows: [SIMD3<Double>]
    }

    private static var cachedSample: (palette: ThemeGradientPalette, sample: Sample)?

    /// Undrifted backdrop averaged over a nominal 16:10 window.
    var backdropSample: Sample {
        if let cached = Self.cachedSample, cached.palette == self { return cached.sample }
        let size = SIMD2<Double>(1280, 800)
        let columns = 32, rows = 20, topRows = 2
        var total = SIMD3<Double>.zero, top = SIMD3<Double>.zero
        var rowTotals = [SIMD3<Double>](repeating: .zero, count: rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Double = (Double(column) + 0.5) / Double(columns) * size.x
                let y: Double = (Double(row) + 0.5) / Double(rows) * size.y
                let position = SIMD2<Double>(x, y)
                let rgb = backdropShade(at: position, size: size)
                total += rgb
                rowTotals[row] += rgb
                if row < topRows { top += rgb }
            }
        }
        let sample = Sample(average: total / Double(columns * rows), topBand: top / Double(columns * topRows),
                            rows: rowTotals.map { $0 / Double(columns) })
        Self.cachedSample = (self, sample)
        return sample
    }

    /// CPU copy of themeGradientShade's backdrop path in ThemeGradient.metal; keep in sync.
    private func backdropShade(at position: SIMD2<Double>, size: SIMD2<Double>) -> SIMD3<Double> {
        func stop(_ c: SIMD3<Double>, _ a: Double) -> SIMD4<Double> { SIMD4(c.x * a, c.y * a, c.z * a, a) }
        func mix(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ t: Double) -> SIMD4<Double> { a + (b - a) * t }
        func ramp(_ t: Double, _ c0: SIMD4<Double>, _ l1: Double, _ c1: SIMD4<Double>, _ l2: Double, _ c2: SIMD4<Double>) -> SIMD4<Double> {
            let t = min(max(t, 0), 1)
            if t < l1 { return mix(c0, c1, t / l1) }
            if t < l2 { return mix(c1, c2, (t - l1) / (l2 - l1)) }
            return mix(c2, .zero, (t - l2) / (1 - l2))
        }
        func over(_ dst: SIMD4<Double>, _ src: SIMD4<Double>) -> SIMD4<Double> { src + dst * (1 - src.w) }
        func distance(to anchor: SIMD2<Double>) -> Double {
            let d = position - anchor * size
            return (d.x * d.x + d.y * d.y).squareRoot()
        }

        let s = min(size.x, size.y), h = size.y
        var col = SIMD4(primary.x, primary.y, primary.z, 1)
        col = over(col, ramp(distance(to: SIMD2(0.10, 0.10)) / (0.9 * s),
                             stop(accent, 0.6), 0.3, stop(accent, 0.3), 0.7, stop(mid, 0.15)))
        col = over(col, ramp((distance(to: SIMD2(0.70, 1.10)) - 0.2 * h) / (0.6 * h),
                             stop(primary, 0.4), 0.3, stop(primary, 0.2), 0.6, stop(mid, 0.1)))
        col = over(col, ramp(distance(to: SIMD2(1.00, 0.60)) / (0.5 * s),
                             stop(mid, 0.2), 0.5, stop(accent, 0.1), 0.75, stop(accent, 0.05)))
        col = over(col, ramp(distance(to: SIMD2(0.35, 0.45)) / (0.35 * s),
                             stop(accent, 0.25), 0.4, stop(mid, 0.15), 0.7, stop(mid, 0.075)))

        let y = position.y / size.y
        let shade: Double = y < 0.3 ? 0.1 * (y / 0.3)
            : y < 0.7 ? 0.1 + 0.2 * ((y - 0.3) / 0.4)
            : 0.3 + 0.2 * ((y - 0.7) / 0.3)
        var rgb = SIMD3(col.x, col.y, col.z) * (1 - shade)
        if isLight { rgb = 1 - (1 - rgb) * 0.45 }
        return rgb
    }

    // MARK: Color math

    private static func isLight(_ rgb: SIMD3<Double>) -> Bool {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z > 0.5
    }

    private static func wrap(_ h: Double) -> Double {
        h - floor(h)
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    /// Shortest hue step from `a` to `b`, in -0.5...0.5.
    private static func signedHueDelta(from a: Double, to b: Double) -> Double {
        wrap(b - a + 0.5) - 0.5
    }

    static func rgb(hex: String) -> SIMD3<Double>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD3(Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)) / 255
    }

    static func hex(_ rgb: SIMD3<Double>) -> String {
        let bytes = [rgb.x, rgb.y, rgb.z].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
    }

    private static func hsb(_ c: SIMD3<Double>) -> HSB {
        let maxC = c.max(), minC = c.min()
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.x {
                h = ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == c.y {
                h = (c.z - c.x) / delta + 2
            } else {
                h = (c.x - c.y) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return HSB(h: h, s: maxC > 0 ? delta / maxC : 0, b: maxC)
    }

    private static func rgb(_ hsb: HSB) -> SIMD3<Double> {
        let h = (hsb.h - floor(hsb.h)) * 6
        let c = hsb.b * hsb.s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = hsb.b - c
        let base: SIMD3<Double>
        switch Int(h) {
        case 0: base = SIMD3(c, x, 0)
        case 1: base = SIMD3(x, c, 0)
        case 2: base = SIMD3(0, c, x)
        case 3: base = SIMD3(0, x, c)
        case 4: base = SIMD3(x, 0, c)
        default: base = SIMD3(c, 0, x)
        }
        return base + m
    }
}
