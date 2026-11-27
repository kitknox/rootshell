// EffectPortrait.swift
// rootshell
//
// Flat illustrations of each background effect, drawn in the terminal theme,
// for the effect tiles and the device overview on the Background Effect page.

import SwiftUI

nonisolated enum EffectPortraitKind: Equatable, Sendable {
    case none, aquarium, jellyfish, fireflies, butterflies, aurora, solar, weather, photo, video
    /// The gradient's own palette when known; otherwise the theme's colors.
    case gradient([PreviewRGB]?)

    init(effectID: String?) {
        switch effectID {
        case "aquarium": self = .aquarium
        case "jellyfish": self = .jellyfish
        case "fireflies": self = .fireflies
        case "butterflies": self = .butterflies
        case "aurora": self = .aurora
        case "solarGraph": self = .solar
        case "liveWeather": self = .weather
        case "themeGradient", "themeGradientBackdrop": self = .gradient(nil)
        case "photoBackground": self = .photo
        case let id? where id.hasPrefix("videoBackground_"): self = .video
        default: self = .none
        }
    }
}

nonisolated enum EffectPortrait {
    /// Draws `kind` filling `rect`, clipped to it.
    static func draw(_ kind: EffectPortraitKind, in rect: CGRect, context: inout GraphicsContext,
                     palette p: WindowPreviewPalette, time t: Double) {
        var g = context
        g.clip(to: Path(rect))
        let k = max(rect.width, rect.height) / 120
        switch kind {
        case .none: none(&g, rect, p, k)
        case .aquarium: aquarium(&g, rect, p, t, k)
        case .jellyfish: jellyfish(&g, rect, p, t, k)
        case .fireflies: fireflies(&g, rect, p, t, k)
        case .butterflies: butterflies(&g, rect, p, t, k)
        case .aurora: aurora(&g, rect, p, t, k)
        case .solar: solar(&g, rect, p, t, k)
        case .weather: weather(&g, rect, p, t, k)
        case .gradient(let colors): gradient(&g, rect, p, t, colors)
        case .photo: photo(&g, rect, p, t)
        case .video: video(&g, rect, p, t, k)
        }
    }

    // MARK: Helpers

    private static func point(_ r: CGRect, _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
    }

    private static func circle(_ c: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func vertical(_ g: inout GraphicsContext, _ r: CGRect, _ top: PreviewRGB, _ bottom: PreviewRGB) {
        g.fill(Path(r), with: .linearGradient(Gradient(colors: [top.color(), bottom.color()]),
                                              startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
    }

    private static func glow(_ g: inout GraphicsContext, _ c: CGPoint, _ radius: Double, _ color: PreviewRGB, _ alpha: Double) {
        g.fill(circle(c, radius), with: .radialGradient(Gradient(colors: [color.color(alpha), color.color(0)]),
                                                         center: c, startRadius: 0, endRadius: radius))
    }

    /// Stable 0...1 noise per index.
    private static func rnd(_ i: Double) -> Double {
        let x = sin(i * 999.7) * 43758.5453
        return x - floor(x)
    }

    /// Water and sky read as day on light themes and night on dark ones.
    private static func tone(_ c: PreviewRGB, _ p: WindowPreviewPalette) -> PreviewRGB {
        p.isLight ? c.mix(.white, 0.45) : c
    }

    // MARK: Effects

    private static func none(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ k: Double) {
        g.fill(Path(r), with: .color(p.background.color()))
        let c = point(r, 0.5, 0.5), radius = min(r.width, r.height) * 0.2
        var slash = Path()
        slash.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        slash.move(to: CGPoint(x: c.x - radius * 0.7, y: c.y + radius * 0.7))
        slash.addLine(to: CGPoint(x: c.x + radius * 0.7, y: c.y - radius * 0.7))
        g.stroke(slash, with: .color(p.dim.color(0.7)), lineWidth: 2.4 * k)
    }

    private static func aquarium(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        vertical(&g, r, tone(PreviewRGB(0.05, 0.37, 0.47), p), tone(PreviewRGB(0.02, 0.16, 0.23), p))
        for i in 0..<3 {
            let x = r.minX + r.width * (0.2 + Double(i) * 0.3) + sin(t * 0.4 + Double(i)) * r.width * 0.03
            var ray = Path()
            ray.move(to: CGPoint(x: x, y: r.minY))
            ray.addLine(to: CGPoint(x: x + r.width * 0.08, y: r.minY))
            ray.addLine(to: CGPoint(x: x + r.width * 0.2, y: r.maxY))
            ray.addLine(to: CGPoint(x: x - r.width * 0.04, y: r.maxY))
            g.fill(ray, with: .color(.white.opacity(0.07)))
        }
        for i in 0..<4 {
            let base = r.minX + r.width * (0.1 + Double(i) * 0.26)
            var kelp = Path()
            kelp.move(to: CGPoint(x: base, y: r.maxY))
            var y = r.maxY
            while y > r.minY + r.height * (0.45 + rnd(Double(i)) * 0.15) {
                y -= r.height * 0.05
                kelp.addLine(to: CGPoint(x: base + sin(y / max(r.height, 1) * 9 + t * 1.2 + Double(i)) * r.width * 0.025, y: y))
            }
            g.stroke(kelp, with: .color(p.green.mix(PreviewRGB(0.18, 0.56, 0.36), 0.5).color(0.9)), lineWidth: 2 * k)
        }
        let colors = [p.red.mix(PreviewRGB(1, 0.55, 0.24), 0.6), p.yellow, p.blue.mix(.white, 0.2)]
        for i in 0..<5 {
            let fi = Double(i)
            let dir: Double = i % 2 == 0 ? 1 : -1
            let progress = (rnd(fi) + t * (0.04 + rnd(fi + 3) * 0.04) * dir).truncatingRemainder(dividingBy: 1)
            let x = r.minX + ((progress + 1).truncatingRemainder(dividingBy: 1) * 1.2 - 0.1) * r.width
            let y = r.minY + r.height * (0.2 + rnd(fi + 7) * 0.5) + sin(t + fi) * r.height * 0.02
            let size = (4 + rnd(fi + 2) * 3) * k
            let color = colors[i % colors.count].color()
            g.fill(Path(ellipseIn: CGRect(x: x - size, y: y - size * 0.55, width: size * 2, height: size * 1.1)), with: .color(color))
            var tail = Path()
            tail.move(to: CGPoint(x: x - dir * size * 0.9, y: y))
            tail.addLine(to: CGPoint(x: x - dir * size * 1.6, y: y - size * 0.5))
            tail.addLine(to: CGPoint(x: x - dir * size * 1.6, y: y + size * 0.5))
            tail.closeSubpath()
            g.fill(tail, with: .color(color))
        }
        for i in 0..<5 {
            let fi = Double(i) + 11
            let y = r.maxY - ((t * 0.12 + rnd(fi + 4)).truncatingRemainder(dividingBy: 1)) * r.height
            g.fill(circle(CGPoint(x: r.minX + rnd(fi) * r.width, y: y), 1.1 * k), with: .color(.white.opacity(0.5)))
        }
    }

    private static func jellyfish(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        vertical(&g, r, tone(PreviewRGB(0.03, 0.1, 0.23), p), tone(PreviewRGB(0.01, 0.03, 0.08), p))
        let bell = p.isLight ? p.blue.mix(.black, 0.2) : PreviewRGB(0.67, 0.92, 1)
        for j in 0..<3 {
            let fj = Double(j)
            let pulse = (sin(t * 1.6 + fj * 2) + 1) / 2
            let x = r.minX + r.width * (0.22 + fj * 0.3) + sin(t * 0.3 + fj) * r.width * 0.03
            let rise = (t * 0.04 + fj * 0.33).truncatingRemainder(dividingBy: 1)
            let y = r.minY + r.height * (0.75 - rise * 0.55)
            let radius = (8 + fj * 2) * k * (0.92 + pulse * 0.12)
            glow(&g, CGPoint(x: x, y: y), radius * 2.4, bell, p.isLight ? 0.12 : 0.3)
            var dome = Path()
            dome.addArc(center: CGPoint(x: x, y: y), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            dome.closeSubpath()
            g.fill(dome, with: .color(bell.color(0.6)))
            for strand in -2...2 {
                var line = Path()
                let sx = x + Double(strand) * radius * 0.35
                line.move(to: CGPoint(x: sx, y: y))
                var d = 0.0
                while d < radius * 2.6 {
                    d += radius * 0.25
                    line.addLine(to: CGPoint(x: sx + sin(d / max(k, 0.1) * 0.08 - t * 2 + Double(strand)) * radius * 0.15, y: y + d))
                }
                g.stroke(line, with: .color(bell.color(0.4)), lineWidth: 0.8 * k)
            }
        }
    }

    private static func fireflies(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        let ground = p.isLight ? p.background.mix(PreviewRGB(0.75, 0.85, 0.7), 0.4) : p.background.mix(PreviewRGB(0.04, 0.12, 0.07), 0.6)
        vertical(&g, r, ground, ground.mix(p.green, p.isLight ? 0.15 : 0.12))
        let light = p.isLight ? PreviewRGB(0.75, 0.55, 0.1) : PreviewRGB(1, 0.93, 0.55)
        for i in 0..<14 {
            let fi = Double(i)
            let c = point(r, rnd(fi) + sin(t * 0.3 + fi) * 0.04, rnd(fi + 30) + cos(t * 0.25 + fi * 2) * 0.05)
            let a = max(0, sin(t * 1.5 + fi * 1.7))
            glow(&g, c, 7 * k, light, 0.85 * a)
            g.fill(circle(c, 1.1 * k), with: .color(light.color(a)))
        }
    }

    private static func butterflies(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        g.fill(Path(r), with: .color(p.background.color()))
        g.fill(Path(r), with: .radialGradient(Gradient(colors: [p.magenta.color(0.14), .clear]),
                                              center: point(r, 0.7, 0.3), startRadius: 0, endRadius: r.width * 0.7))
        let colors = [p.blue, PreviewRGB(1, 0.7, 0.43), p.magenta]
        for b in 0..<3 {
            let fb = Double(b)
            let progress = (t * 0.05 + fb * 0.33).truncatingRemainder(dividingBy: 1)
            let center = CGPoint(x: r.minX + (progress * 1.2 - 0.1) * r.width,
                                 y: r.minY + r.height * (0.3 + fb * 0.2) + sin(progress * 9 + fb) * r.height * 0.07)
            let flap = abs(sin(t * 7 + fb)) * 0.75 + 0.25
            let s = 6 * k
            var wings = g
            wings.translateBy(x: center.x, y: center.y)
            wings.scaleBy(x: flap, y: 1)
            let color = colors[b].color(0.9)
            wings.fill(Path(ellipseIn: CGRect(x: -s * 1.2, y: -s * 0.75, width: s * 1.2, height: s * 0.9)), with: .color(color))
            wings.fill(Path(ellipseIn: CGRect(x: 0, y: -s * 0.75, width: s * 1.2, height: s * 0.9)), with: .color(color))
            wings.fill(Path(ellipseIn: CGRect(x: -s * 0.75, y: s * 0.05, width: s * 0.7, height: s * 0.6)), with: .color(color))
            wings.fill(Path(ellipseIn: CGRect(x: s * 0.05, y: s * 0.05, width: s * 0.7, height: s * 0.6)), with: .color(color))
        }
    }

    private static func aurora(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        vertical(&g, r, tone(PreviewRGB(0.02, 0.05, 0.12), p), tone(PreviewRGB(0.04, 0.09, 0.16), p))
        for i in 0..<18 {
            let fi = Double(i)
            g.fill(circle(point(r, rnd(fi), rnd(fi + 50) * 0.55), 0.6 * k), with: .color((p.isLight ? p.dim : .white).color(0.6)))
        }
        let bands: [(PreviewRGB, Double, Double)] = [(p.green.mix(PreviewRGB(0.3, 1, 0.65), 0.5), 0.3, 0), (p.magenta, 0.42, 2), (p.blue.mix(p.green, 0.5), 0.52, 4)]
        let step = max(1.5, r.width / 70)
        var layer = g
        layer.blendMode = p.isLight ? .multiply : .plusLighter
        for (color, base, phase) in bands {
            var x = r.minX
            while x < r.maxX {
                let u = (x - r.minX) / max(r.width, 1)
                let top = r.minY + r.height * (base - 0.18) + sin(u * 6 + t * 0.5 + phase) * r.height * 0.08 + sin(u * 17 + t * 1.3) * r.height * 0.02
                let column = CGRect(x: x, y: top, width: step + 0.5, height: r.height * 0.45)
                layer.fill(Path(column), with: .linearGradient(Gradient(stops: [
                    .init(color: color.color(0), location: 0), .init(color: color.color(0.4), location: 0.15), .init(color: color.color(0), location: 1),
                ]), startPoint: CGPoint(x: column.midX, y: column.minY), endPoint: CGPoint(x: column.midX, y: column.maxY)))
                x += step
            }
        }
    }

    private static func solar(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        let phase = (t * 0.04).truncatingRemainder(dividingBy: 1)
        let day = sin(phase * .pi)
        let horizon = r.minY + r.height * 0.62
        let sky = CGRect(x: r.minX, y: r.minY, width: r.width, height: horizon - r.minY)
        vertical(&g, sky, PreviewRGB(0.08 + 0.24 * day, 0.16 + 0.43 * day, 0.35 + 0.55 * day), PreviewRGB(0.94 - 0.16 * day, 0.55 + 0.24 * day, 0.35 + 0.47 * day))
        var arc = Path()
        for i in 0...30 {
            let u = Double(i) / 30
            let pt = CGPoint(x: r.minX + r.width * (0.1 + u * 0.8), y: horizon - sin(u * .pi) * r.height * 0.45)
            if i == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
        }
        g.stroke(arc, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 0.7 * k, dash: [1.5 * k, 2 * k]))
        let sun = CGPoint(x: r.minX + r.width * (0.1 + phase * 0.8), y: horizon - sin(phase * .pi) * r.height * 0.45)
        glow(&g, sun, 12 * k, PreviewRGB(1, 0.83, 0.42), 0.9)
        g.fill(circle(sun, 4 * k), with: .color(PreviewRGB(1, 0.97, 0.84).color()))
        let sea = CGRect(x: r.minX, y: horizon, width: r.width, height: r.maxY - horizon)
        vertical(&g, sea, PreviewRGB(0.11, 0.31, 0.45), PreviewRGB(0.04, 0.13, 0.2))
        for i in 0..<5 {
            let y = horizon + sea.height * (0.15 + Double(i) * 0.18)
            var wave = Path()
            var x = r.minX
            wave.move(to: CGPoint(x: x, y: y))
            while x < r.maxX {
                x += r.width / 24
                wave.addLine(to: CGPoint(x: x, y: y + sin((x - r.minX) / max(r.width, 1) * 12 + t * 1.5 + Double(i)) * 0.8 * k))
            }
            g.stroke(wave, with: .color(PreviewRGB(1, 0.86, 0.6).color(0.35)), lineWidth: 0.6 * k)
        }
    }

    private static func weather(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        vertical(&g, r, tone(PreviewRGB(0.29, 0.42, 0.55), p), tone(PreviewRGB(0.6, 0.7, 0.79), p))
        for c in 0..<3 {
            let fc = Double(c)
            let drift = (rnd(fc) + t * 0.02 * (fc + 1)).truncatingRemainder(dividingBy: 1.3) - 0.15
            let center = CGPoint(x: r.minX + drift * r.width, y: r.minY + r.height * (0.2 + fc * 0.13))
            let radius = (7 + fc * 1.5) * k
            for puff in 0..<4 {
                let size = radius * (puff == 1 || puff == 2 ? 1.1 : 0.8)
                g.fill(circle(CGPoint(x: center.x + Double(puff) * radius * 0.8, y: center.y + Double(puff % 2) * radius * 0.2), size),
                       with: .color(PreviewRGB(0.95, 0.96, 0.98).color(0.92)))
            }
        }
        for i in 0..<30 {
            let fi = Double(i)
            let y = r.minY + ((rnd(fi + 9) + t * 0.8).truncatingRemainder(dividingBy: 1)) * r.height
            guard y > r.minY + r.height * 0.32 else { continue }
            let x = r.minX + rnd(fi) * r.width
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y))
            drop.addLine(to: CGPoint(x: x - 1.2 * k, y: y + 6 * k))
            g.stroke(drop, with: .color(PreviewRGB(0.86, 0.92, 1).color(0.6)), lineWidth: 0.6 * k)
        }
    }

    private static func gradient(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ colors: [PreviewRGB]?) {
        let c = colors.flatMap { $0.count >= 3 ? $0 : nil } ?? [p.magenta, p.red, p.blue]
        g.fill(Path(r), with: .color(p.background.mix(c[0], 0.25).color()))
        let blobs: [(PreviewRGB, Double, Double, Double)] = [(c[0], 0.3, 0.35, 0), (c[1], 0.72, 0.55, 2), (c[2], 0.5, 0.85, 4)]
        var layer = g
        layer.blendMode = p.isLight ? .multiply : .plusLighter
        for (color, x, y, phase) in blobs {
            let c = point(r, x + sin(t * 0.25 + phase) * 0.08, y + cos(t * 0.2 + phase) * 0.08)
            layer.fill(Path(r), with: .radialGradient(Gradient(colors: [color.color(0.55), color.color(0)]),
                                                      center: c, startRadius: 0, endRadius: max(r.width, r.height) * 0.6))
        }
    }

    private static func photo(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double) {
        let zoom = 1 + (sin(t * 0.15) + 1) / 2 * 0.08
        var layer = g
        layer.translateBy(x: r.midX, y: r.midY)
        layer.scaleBy(x: zoom, y: zoom)
        layer.translateBy(x: -r.midX, y: -r.midY)
        layer.fill(Path(r), with: .linearGradient(Gradient(colors: [PreviewRGB(0.96, 0.7, 0.48).color(), PreviewRGB(0.79, 0.48, 0.56).color(), PreviewRGB(0.36, 0.29, 0.47).color()]),
                                                  startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        func ridge(_ points: [(Double, Double)], _ color: PreviewRGB) {
            var path = Path()
            path.move(to: point(r, 0, 1))
            for (x, y) in points { path.addLine(to: point(r, x, y)) }
            path.addLine(to: point(r, 1, 1))
            path.closeSubpath()
            layer.fill(path, with: .color(color.color()))
        }
        ridge([(0, 0.7), (0.25, 0.4), (0.45, 0.62), (0.7, 0.35), (1, 0.65)], PreviewRGB(0.29, 0.23, 0.39))
        ridge([(0, 0.85), (0.35, 0.68), (0.6, 0.82), (1, 0.72)], PreviewRGB(0.17, 0.14, 0.25))
    }

    private static func video(_ g: inout GraphicsContext, _ r: CGRect, _ p: WindowPreviewPalette, _ t: Double, _ k: Double) {
        g.fill(Path(r), with: .color(p.background.mix(.black, p.isLight ? 0.05 : 0.3).color()))
        let colors = [p.blue, p.green, p.magenta, p.yellow]
        for i in 0..<4 {
            var wave = Path()
            var x = r.minX
            let base = r.minY + r.height * (0.3 + Double(i) * 0.14)
            wave.move(to: CGPoint(x: x, y: base))
            while x < r.maxX {
                x += r.width / 30
                wave.addLine(to: CGPoint(x: x, y: base + sin((x - r.minX) / max(r.width, 1) * 5 + t * 1.2 + Double(i)) * r.height * 0.07))
            }
            g.stroke(wave, with: .color(colors[i].color(0.65)), lineWidth: 2 * k)
        }
        let hole = r.height * 0.07
        var x = r.minX + hole
        while x < r.maxX {
            g.fill(Path(roundedRect: CGRect(x: x, y: r.minY + hole * 0.4, width: hole, height: hole * 0.8), cornerRadius: hole * 0.2), with: .color(.white.opacity(0.14)))
            g.fill(Path(roundedRect: CGRect(x: x, y: r.maxY - hole * 1.2, width: hole, height: hole * 0.8), cornerRadius: hole * 0.2), with: .color(.white.opacity(0.14)))
            x += hole * 2.2
        }
    }
}

// MARK: - Tiles

/// One choice in the effect gallery. Only the selected tile animates.
struct EffectTile: View {
    let kind: EffectPortraitKind
    let title: String
    var badgeSymbol: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment
    @State private var isVisible = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                portrait
                    .aspectRatio(1.4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.body)
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let badgeSymbol {
                            Image(systemName: badgeSymbol)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(5)
                        }
                    }
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected) { _, new in new }
    }

    private var portrait: some View {
        let kind = kind
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        let animates = isSelected && !reduceMotion && isVisible && scenePhase == .active
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 6
            Canvas { context, size in
                EffectPortrait.draw(kind, in: CGRect(origin: .zero, size: size), context: &context, palette: palette, time: time)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
    }
}

extension EffectPortraitKind {
    /// Carries a gradient's real palette, which depends on its style.
    @MainActor
    init(effect: AnyTerminalEffect?) {
        if let gradient = effect?.asEffect(ThemeGradientEffect.self) {
            let palette = gradient.palette
            self = .gradient(palette.colors.map { PreviewRGB($0.x, $0.y, $0.z) })
        } else {
            self.init(effectID: effect?.id)
        }
    }
}
