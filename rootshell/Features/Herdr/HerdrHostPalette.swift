// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Mirrors Ghostty's CIELAB palette generation (terminal/color.zig). Its config
/// C API exposes the input palette, while Termio derives indices 16...255 later.
/// Keep this client-side so vanilla herdr receives the colors Ghostty displays.
nonisolated enum HerdrHostPalette {
    static func explicitIndices(in theme: String) -> Set<Int> {
        Set(theme.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, parts[0] == "palette", let index = paletteIndex(parts[1]),
                  (0..<256).contains(index) else { return nil }
            return index
        })
    }

    private static func paletteIndex(_ value: String) -> Int? {
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where value.lowercased().hasPrefix(prefix) {
            return Int(value.dropFirst(2), radix: radix)
        }
        return Int(value)
    }

    static func generate(_ theme: HerdrHostTheme, explicit: Set<Int>, harmonious: Bool) -> [HerdrHostTheme.RGB] {
        guard !explicit.isEmpty else { return theme.palette }
        var corners = [Lab(theme.background)] + theme.palette[1...6].map(Lab.init) + [Lab(theme.foreground)]
        if !harmonious, corners[7].l < corners[0].l { corners.swapAt(0, 7) }
        var result = theme.palette
        var index = 16
        for r in 0..<6 {
            let t = Float(r) / 5
            let c0 = corners[0].mix(corners[1], t), c1 = corners[2].mix(corners[3], t)
            let c2 = corners[4].mix(corners[5], t), c3 = corners[6].mix(corners[7], t)
            for g in 0..<6 {
                let c4 = c0.mix(c1, Float(g) / 5), c5 = c2.mix(c3, Float(g) / 5)
                for b in 0..<6 {
                    if !explicit.contains(index) { result[index] = c4.mix(c5, Float(b) / 5).rgb }
                    index += 1
                }
            }
        }
        for step in 1...24 where !explicit.contains(231 + step) {
            result[231 + step] = corners[0].mix(corners[7], Float(step) / 25).rgb
        }
        return result
    }

    private struct Lab {
        var l: Float, a: Float, b: Float
        init(l: Float, a: Float, b: Float) { self.l = l; self.a = a; self.b = b }
        init(_ color: HerdrHostTheme.RGB) {
            func linear(_ byte: UInt8) -> Float {
                let v = Float(byte) / 255
                return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
            }
            func f(_ v: Float) -> Float { v > 0.008856 ? cbrt(v) : 7.787 * v + 16 / 116 }
            let r = linear(color.r), g = linear(color.g), b = linear(color.b)
            let x = f((r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047)
            let y = f(r * 0.2126729 + g * 0.7151522 + b * 0.0721750)
            let z = f((r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883)
            self.init(l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z))
        }
        func mix(_ other: Lab, _ t: Float) -> Lab {
            .init(l: l + t * (other.l - l), a: a + t * (other.a - a), b: b + t * (other.b - b))
        }
        var rgb: HerdrHostTheme.RGB {
            func inverse(_ v: Float) -> Float {
                let cube = v * v * v
                return cube > 0.008856 ? cube : (v - 16 / 116) / 7.787
            }
            func byte(_ v: Float) -> UInt8 {
                let srgb: Float = v > 0.0031308 ? 1.055 * pow(v, 1 / 2.4) - 0.055 : 12.92 * v
                return UInt8(min(1, max(0, srgb)) * 255 + 0.5)
            }
            let y = (l + 16) / 116
            let xf = inverse(a / 500 + y) * 0.95047, yf = inverse(y), zf = inverse(y - b / 200) * 1.08883
            return .init(r: byte(xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314),
                         g: byte(-xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560),
                         b: byte(xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252))
        }
    }
}
