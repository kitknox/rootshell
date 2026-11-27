//
//  ThemeRoomScene.swift
//  rootshell
//
//  The room at the top of Settings → Theme, painted in a theme's colors and
//  furnished from its name. Changing themes runs a paint roller across the
//  wall; old pieces drop out ahead of it and new ones pop in behind.
//

import SwiftUI

// MARK: - Palette

nonisolated struct ThemeRoomPalette: Equatable, Sendable {
    let background: PreviewRGB
    let foreground: PreviewRGB
    let cursor: PreviewRGB
    let ansi: [PreviewRGB]
    let isLight: Bool

    init(background: String, foreground: String, cursor: String, palette: [String]) {
        let bg = PreviewRGB(hex: background) ?? PreviewRGB(0.12, 0.12, 0.18)
        let fg = PreviewRGB(hex: foreground) ?? PreviewRGB(0.8, 0.84, 0.96)
        let fallback = [PreviewRGB(0.2, 0.2, 0.24), PreviewRGB(0.95, 0.45, 0.5), PreviewRGB(0.55, 0.85, 0.55),
                        PreviewRGB(0.98, 0.82, 0.5), PreviewRGB(0.5, 0.65, 0.98), PreviewRGB(0.85, 0.55, 0.95),
                        PreviewRGB(0.5, 0.85, 0.85), PreviewRGB(0.85, 0.85, 0.85)]
        self.background = bg
        self.foreground = fg
        self.cursor = PreviewRGB(hex: cursor) ?? fg
        self.ansi = (0..<8).map { index in
            index < palette.count ? (PreviewRGB(hex: palette[index]) ?? fallback[index]) : fallback[index]
        }
        self.isLight = bg.luminance > 0.5
    }

    var red: PreviewRGB { ansi[1] }
    var green: PreviewRGB { ansi[2] }
    var yellow: PreviewRGB { ansi[3] }
    var blue: PreviewRGB { ansi[4] }
    var magenta: PreviewRGB { ansi[5] }
    var cyan: PreviewRGB { ansi[6] }

    /// A step away from the wall, for trim and frames.
    var trim: PreviewRGB { isLight ? background.mix(.black, 0.12) : background.mix(foreground, 0.16) }
    var wood: PreviewRGB {
        yellow.mix(red, 0.35).mix(PreviewRGB(0.45, 0.3, 0.2), 0.5).mix(.black, isLight ? 0.05 : 0.3)
    }
}

/// One theme's room: its colors and its furnishings.
nonisolated struct ThemeRoomState: Equatable, Sendable {
    let palette: ThemeRoomPalette
    let room: ThemeRoom
}

// MARK: - Scene

nonisolated enum ThemeRoomScene {
    static let designWidth = 360.0
    static let designHeight = 150.0
    static let floorY = 113.0

    /// The wall art hanging above the sofa.
    static let artFrame = CGRect(x: 70, y: 24, width: 52, height: 40)
    /// The header's theme name chip covers this much of the top-leading corner.
    static let chipClearance = CGSize(width: 180, height: 44)
    /// The art's top edge, picture frame included.
    private static let artTop = artFrame.minY - 3

    /// Design units to points: fills the height, trimming at most 15% off the sides.
    /// Shrinks further when that would hang the wall art under the name chip.
    static func scale(for size: CGSize) -> Double {
        let k = min(size.width / designWidth * 1.15, size.height / designHeight)
        let extra = (size.width / k - designWidth) / 2
        let artX = (artFrame.minX + extra) * k
        let artY = size.height - (designHeight - artTop) * k
        guard artX < chipClearance.width, artY < chipClearance.height else { return k }
        return max(0.1, min(k, (size.height - chipClearance.height) / (designHeight - artTop)))
    }

    /// The height at which a room `width` wide clears the name chip at full scale.
    static func heightClearingChip(width: Double) -> Double {
        width / designWidth * 1.15 * (designHeight - artTop) + chipClearance.height
    }

    /// How far to shift a frame of `size` up so a band of `band` points shows
    /// the middle of the room: the window, the art, and the top of the sofa.
    static func bandOffset(size: CGSize, band: Double) -> Double {
        guard size.width > 1, size.height > 1 else { return 0 }
        let k = scale(for: size)
        let focus = size.height - (designHeight - 62) * k
        return min(max(focus - band / 2, 0), size.height - band)
    }

    /// Draws `to`, with `from` still showing ahead of the roller while
    /// `progress` runs from 0 to 1.
    static func draw(_ context: inout GraphicsContext, size: CGSize, from: ThemeRoomState?, to: ThemeRoomState,
                     progress: Double, time: Double, reduceMotion: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        // Tall frames trim a little off the sides and raise the ceiling; the
        // headroom above the original wall gets its own decor.
        let k = scale(for: size)
        let extra = (size.width / k - designWidth) / 2
        let ceiling = -(size.height / k - designHeight)
        var c = context
        c.translateBy(x: extra * k, y: size.height - designHeight * k)
        c.scaleBy(x: k, y: k)
        let span = (-extra - 2)...(designWidth + extra + 2)

        let painting = from != nil && progress < 1
        // The roller travels a little past both edges so it enters and leaves.
        let roller = span.lowerBound - 30 + (span.upperBound - span.lowerBound + 60) * progress

        if painting, let from {
            let old = ThemeRoomPainter(state: from, time: time, reduceMotion: reduceMotion, span: span, ceiling: ceiling) { x in
                PreviewKit.ease((x - roller) / 30)
            }
            let new = ThemeRoomPainter(state: to, time: time, reduceMotion: reduceMotion, span: span, ceiling: ceiling) { x in
                let t = min(max((roller - x) / 34, 0), 1)
                // A pop with a little overshoot.
                return t <= 0 ? 0 : 1 - pow(1 - t, 3) + 0.22 * sin(.pi * t)
            }
            // Walls and floor split at the roller; furniture swaps whole.
            var oldShell = c
            oldShell.clip(to: Path(CGRect(x: roller, y: ceiling - 10, width: 2000, height: 400 - ceiling)))
            old.drawShell(&oldShell)
            var newShell = c
            newShell.clip(to: Path(CGRect(x: -2000, y: ceiling - 10, width: roller + 2000, height: 400 - ceiling)))
            new.drawShell(&newShell)
            old.drawPieces(&c)
            new.drawPieces(&c)

            drawRoller(&c, x: roller, color: to.palette.background, span: span)
        } else {
            ThemeRoomPainter(state: to, time: time, reduceMotion: reduceMotion, span: span, ceiling: ceiling) { _ in 1 }.draw(&c)
        }
    }

    private static func drawRoller(_ c: inout GraphicsContext, x: Double, color: PreviewRGB, span: ClosedRange<Double>) {
        // Fresh paint just behind the roller, a touch glossier than dry.
        c.fill(Path(CGRect(x: x - 16, y: 0, width: 16, height: floorY)),
               with: .linearGradient(Gradient(colors: [.clear, color.mix(.white, 0.12).color(0.6)]),
                                     startPoint: CGPoint(x: x - 16, y: 0), endPoint: CGPoint(x: x, y: 0)))
        for (offset, length) in [(18.0, 10.0), (46.0, 16.0), (77.0, 7.0)] {
            let drip = CGRect(x: x - 9 - offset.truncatingRemainder(dividingBy: 7), y: offset, width: 2.2, height: length)
            c.fill(Path(roundedRect: drip, cornerRadius: 1.1), with: .color(color.mix(.white, 0.08).color()))
        }
        let sleeve = CGRect(x: x - 4, y: 6, width: 11, height: 100)
        c.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 3, x: 2, y: 1))
            layer.fill(Path(roundedRect: sleeve, cornerRadius: 5), with: .linearGradient(
                Gradient(colors: [color.mix(.white, 0.3).color(), color.color(), color.mix(.black, 0.25).color()]),
                startPoint: CGPoint(x: sleeve.minX, y: 0), endPoint: CGPoint(x: sleeve.maxX, y: 0)))
        }
        var frame = Path()
        frame.move(to: CGPoint(x: x + 7, y: 12))
        frame.addLine(to: CGPoint(x: x + 13, y: 12))
        frame.addLine(to: CGPoint(x: x + 13, y: 100))
        frame.addLine(to: CGPoint(x: x + 7, y: 100))
        frame.move(to: CGPoint(x: x + 13, y: 56))
        frame.addCurve(to: CGPoint(x: x + 30, y: 150), control1: CGPoint(x: x + 24, y: 70), control2: CGPoint(x: x + 22, y: 120))
        c.stroke(frame, with: .color(PreviewRGB(0.75, 0.77, 0.8).color()), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        var grip = Path()
        grip.move(to: CGPoint(x: x + 25, y: 118))
        grip.addLine(to: CGPoint(x: x + 31, y: 150))
        c.stroke(grip, with: .color(PreviewRGB(0.85, 0.3, 0.25).color()), style: StrokeStyle(lineWidth: 6, lineCap: .round))
    }
}

// MARK: - Painter

/// Draws one room in design units. `presence` gives each piece's pop, 0...1+,
/// from the x of its center.
private nonisolated struct ThemeRoomPainter {
    let state: ThemeRoomState
    let time: Double
    let reduceMotion: Bool
    let span: ClosedRange<Double>
    /// The top of the room in design units; below 0 when the frame is taller than the design.
    let ceiling: Double
    let presence: (Double) -> Double

    private var p: ThemeRoomPalette { state.palette }
    private var room: ThemeRoom { state.room }
    private var floorY: Double { ThemeRoomScene.floorY }
    private var night: Bool { !p.isLight }

    func draw(_ c: inout GraphicsContext) {
        drawShell(&c)
        drawPieces(&c)
    }

    func drawPieces(_ c: inout GraphicsContext) {
        piece(&c, x: 248, anchor: CGPoint(x: 248, y: 50)) { drawWindow(&$0) }
        piece(&c, x: 96, anchor: CGPoint(x: 96, y: 45)) { drawArt(&$0) }
        piece(&c, x: 164, anchor: CGPoint(x: 164, y: 0)) { drawPendant(&$0) }
        piece(&c, x: 178, anchor: CGPoint(x: 178, y: 134)) { drawRug(&$0) }
        piece(&c, x: 34, anchor: CGPoint(x: 34, y: 120)) { drawCorner(&$0) }
        piece(&c, x: 180, anchor: CGPoint(x: 180, y: 120)) { drawCenter(&$0) }
        piece(&c, x: 320, anchor: CGPoint(x: 320, y: 122)) { drawSideTable(&$0) }
        piece(&c, x: 270, anchor: CGPoint(x: 270, y: 122)) { drawCompanion(&$0) }
    }

    private func piece(_ c: inout GraphicsContext, x: Double, anchor: CGPoint, _ body: (inout GraphicsContext) -> Void) {
        let amount = presence(x)
        guard amount > 0.01 else { return }
        var layer = c
        if abs(amount - 1) > 0.001 {
            layer.opacity = min(1, amount * 1.6)
            layer.translateBy(x: anchor.x, y: anchor.y)
            layer.scaleBy(x: amount, y: amount)
            layer.translateBy(x: -anchor.x, y: -anchor.y)
        }
        body(&layer)
    }

    // MARK: Shell

    func drawShell(_ c: inout GraphicsContext) {
        defer { drawAmbient(&c) }
        let left = span.lowerBound, width = span.upperBound - span.lowerBound
        let wall = CGRect(x: left, y: ceiling - 2, width: width, height: floorY - ceiling + 2)
        c.fill(Path(wall), with: .linearGradient(
            Gradient(colors: [p.background.mix(p.foreground, 0.03).color(), p.background.mix(.black, night ? 0.18 : 0.06).color()]),
            startPoint: CGPoint(x: 0, y: ceiling), endPoint: CGPoint(x: 0, y: floorY)))
        // Wallpaper stripes.
        var stripes = Path()
        var x = (left / 14).rounded(.down) * 14
        while x < span.upperBound {
            stripes.addRect(CGRect(x: x, y: ceiling, width: 6, height: floorY - ceiling))
            x += 14
        }
        c.fill(stripes, with: .color(p.foreground.color(p.isLight ? 0.035 : 0.025)))
        if ceiling < -4 {
            // Crown molding where the raised wall meets the ceiling.
            c.fill(Path(CGRect(x: left, y: ceiling, width: width, height: 4)), with: .linearGradient(
                Gradient(colors: [p.trim.mix(.black, 0.15).color(), p.trim.mix(.white, 0.08).color()]),
                startPoint: CGPoint(x: 0, y: ceiling), endPoint: CGPoint(x: 0, y: ceiling + 4)))
            c.fill(Path(CGRect(x: left, y: ceiling + 4, width: width, height: 6)), with: .linearGradient(
                Gradient(colors: [.black.opacity(0.18), .clear]),
                startPoint: CGPoint(x: 0, y: ceiling + 4), endPoint: CGPoint(x: 0, y: ceiling + 10)))
        }
        // Picture rail and baseboard.
        c.fill(Path(CGRect(x: left, y: 8, width: width, height: 1.5)), with: .color(p.trim.color(0.7)))
        c.fill(Path(CGRect(x: left, y: floorY - 6, width: width, height: 6)), with: .linearGradient(
            Gradient(colors: [p.trim.mix(.white, 0.1).color(), p.trim.color()]),
            startPoint: CGPoint(x: 0, y: floorY - 6), endPoint: CGPoint(x: 0, y: floorY)))

        // Floorboards.
        let floor = CGRect(x: left, y: floorY, width: width, height: 40)
        c.fill(Path(floor), with: .linearGradient(
            Gradient(colors: [p.wood.mix(.black, 0.2).color(), p.wood.color()]),
            startPoint: CGPoint(x: 0, y: floorY), endPoint: CGPoint(x: 0, y: 150)))
        var seams = Path()
        var y = floorY, gap = 6.0, row = 0
        while y < 150 {
            seams.addRect(CGRect(x: left, y: y, width: width, height: 0.6))
            var seam = left + Double((row * 37) % 50)
            while seam < span.upperBound {
                seams.addRect(CGRect(x: seam, y: y, width: 0.6, height: gap))
                seam += 52
            }
            y += gap
            gap *= 1.35
            row += 1
        }
        c.fill(seams, with: .color(.black.opacity(0.22)))
        // Contact shadow along the wall.
        c.fill(Path(CGRect(x: left, y: floorY, width: width, height: 5)),
               with: .linearGradient(Gradient(colors: [.black.opacity(0.25), .clear]),
                                     startPoint: CGPoint(x: 0, y: floorY), endPoint: CGPoint(x: 0, y: floorY + 5)))
    }

    /// Warm light pooling under the lamps at night.
    private func drawAmbient(_ c: inout GraphicsContext) {
        guard night else { return }
        let glow = p.yellow.mix(.white, 0.5)
        c.fill(Path(ellipseIn: CGRect(x: 104, y: 20, width: 120, height: 120)), with: .radialGradient(
            Gradient(colors: [glow.color(0.12), .clear]), center: CGPoint(x: 164, y: 60), startRadius: 0, endRadius: 70))
    }

    // MARK: Window

    private func drawWindow(_ c: inout GraphicsContext) {
        let frame = CGRect(x: 204, y: 16, width: 88, height: 70)
        let glass = frame.insetBy(dx: 4, dy: 4)
        // Curtain rod and curtains behind the frame edges.
        c.fill(Path(roundedRect: CGRect(x: 190, y: 11, width: 116, height: 2.4), cornerRadius: 1.2), with: .color(p.trim.mix(.black, 0.2).color()))
        let frameColor = p.isLight ? PreviewRGB.white.mix(p.background, 0.15) : p.background.mix(p.foreground, 0.28)
        c.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 2, y: 1))
            layer.fill(Path(roundedRect: frame, cornerRadius: 2.5), with: .color(frameColor.color()))
        }
        var view = c
        view.clip(to: Path(glass))
        drawView(&view, glass)
        // Glass sheen and mullions.
        view.fill(Path(glass), with: .linearGradient(Gradient(colors: [.white.opacity(0.12), .clear, .white.opacity(0.05)]),
                                                     startPoint: CGPoint(x: glass.minX, y: glass.minY), endPoint: CGPoint(x: glass.maxX, y: glass.maxY)))
        c.fill(Path(CGRect(x: glass.midX - 1.2, y: glass.minY, width: 2.4, height: glass.height)), with: .color(frameColor.color()))
        c.fill(Path(CGRect(x: glass.minX, y: glass.midY - 1.2, width: glass.width, height: 2.4)), with: .color(frameColor.color()))
        c.fill(Path(roundedRect: CGRect(x: frame.minX - 5, y: frame.maxY - 1, width: frame.width + 10, height: 4), cornerRadius: 1.2),
               with: .color(frameColor.mix(.black, 0.08).color()))
        drawCurtain(&c, x: 192, flip: false)
        drawCurtain(&c, x: 304, flip: true)
    }

    private func drawCurtain(_ c: inout GraphicsContext, x: Double, flip: Bool) {
        let fabric = p.magenta.mix(p.background, 0.35)
        let sway = reduceMotion ? 0 : sin(time * 0.9 + (flip ? 1 : 0)) * 0.8
        var path = Path()
        let dir = flip ? -1.0 : 1.0
        path.move(to: CGPoint(x: x - 4 * dir, y: 12))
        path.addLine(to: CGPoint(x: x + 14 * dir, y: 12))
        path.addCurve(to: CGPoint(x: x + 7 * dir + sway, y: 92), control1: CGPoint(x: x + 10 * dir, y: 40), control2: CGPoint(x: x + 4 * dir, y: 70))
        path.addLine(to: CGPoint(x: x - 6 * dir + sway, y: 96))
        path.closeSubpath()
        c.fill(path, with: .linearGradient(Gradient(colors: [fabric.mix(.black, 0.15).color(), fabric.mix(.white, 0.12).color(),
                                                             fabric.color(), fabric.mix(.black, 0.2).color()]),
                                           startPoint: CGPoint(x: x - 6 * dir, y: 0), endPoint: CGPoint(x: x + 14 * dir, y: 0)))
        // Tie-back.
        c.fill(Path(roundedRect: CGRect(x: min(x, x + 10 * dir) - 1, y: 58, width: 11, height: 2.5), cornerRadius: 1),
               with: .color(p.yellow.mix(p.background, 0.3).color()))
    }

    private func drawView(_ c: inout GraphicsContext, _ g: CGRect) {
        let skyTop: PreviewRGB, skyBottom: PreviewRGB
        switch (room.view, night) {
        case (.desert, false): skyTop = PreviewRGB(0.98, 0.7, 0.45); skyBottom = PreviewRGB(1, 0.88, 0.65)
        case (.desert, true): skyTop = PreviewRGB(0.2, 0.12, 0.3); skyBottom = PreviewRGB(0.85, 0.45, 0.35)
        case (.rain, _): skyTop = night ? PreviewRGB(0.08, 0.1, 0.14) : PreviewRGB(0.5, 0.56, 0.64)
            skyBottom = night ? PreviewRGB(0.16, 0.19, 0.25) : PreviewRGB(0.68, 0.73, 0.8)
        case (_, false): skyTop = PreviewRGB(0.45, 0.72, 0.96).mix(p.blue, 0.2); skyBottom = PreviewRGB(0.82, 0.92, 1)
        case (_, true): skyTop = PreviewRGB(0.03, 0.05, 0.14).mix(p.blue, 0.1); skyBottom = PreviewRGB(0.12, 0.16, 0.32).mix(p.blue, 0.15)
        }
        c.fill(Path(g), with: .linearGradient(Gradient(colors: [skyTop.color(), skyBottom.color()]),
                                              startPoint: CGPoint(x: 0, y: g.minY), endPoint: CGPoint(x: 0, y: g.maxY)))

        if night && room.view != .rain {
            for index in 0..<14 {
                let sx = g.minX + fract(Double(index) * 0.618 + 0.13) * g.width
                let sy = g.minY + fract(Double(index) * 0.377 + 0.31) * g.height * 0.6
                let twinkle = reduceMotion ? 0.8 : 0.5 + 0.5 * sin(time * (1.5 + Double(index % 4)) + Double(index))
                c.fill(circle(CGPoint(x: sx, y: sy), 0.6), with: .color(.white.opacity(0.85 * twinkle)))
            }
            if room.view != .space {
                let moon = CGPoint(x: g.maxX - 14, y: g.minY + 12)
                c.fill(circle(moon, 5), with: .color(PreviewRGB(0.98, 0.96, 0.86).color()))
                c.fill(circle(moon, 11), with: .radialGradient(Gradient(colors: [.white.opacity(0.18), .clear]),
                                                               center: moon, startRadius: 3, endRadius: 11))
            }
        } else if !night && room.view != .rain && room.view != .desert {
            for index in 0..<2 {
                let drift = reduceMotion ? 0 : time * 2.2
                let cx = g.minX + fract((Double(index) * 0.5 + 0.2) + drift / g.width) * (g.width + 30) - 15
                cloud(&c, CGPoint(x: cx, y: g.minY + 12 + Double(index) * 12), 1 - Double(index) * 0.25)
            }
        }

        let ground = g.maxY
        switch room.view {
        case .sky:
            hills(&c, g, color: night ? PreviewRGB(0.1, 0.16, 0.22) : PreviewRGB(0.55, 0.76, 0.5).mix(p.green, 0.3), height: 12)
        case .city:
            var seed: UInt64 = 0xC17E
            var x = g.minX - 2
            while x < g.maxX {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let width = 7 + Double(seed >> 60), height = 14 + Double((seed >> 50) % 22)
                let tower = CGRect(x: x, y: ground - height, width: width, height: height)
                c.fill(Path(tower), with: .color((night ? PreviewRGB(0.07, 0.08, 0.14) : PreviewRGB(0.55, 0.62, 0.74)).color()))
                if night {
                    var lit = Path()
                    var wy = tower.minY + 2
                    while wy < ground - 2 {
                        var wx = tower.minX + 1.5
                        while wx < tower.maxX - 1.5 {
                            seed = seed &* 6364136223846793005 &+ 1442695040888963407
                            if seed >> 62 != 0 { lit.addRect(CGRect(x: wx, y: wy, width: 1.2, height: 1.2)) }
                            wx += 2.6
                        }
                        wy += 3
                    }
                    c.fill(lit, with: .color(p.yellow.mix(.white, 0.4).color(0.85)))
                }
                x += width + 1
            }
        case .snow:
            var peaks = Path()
            peaks.move(to: CGPoint(x: g.minX, y: ground))
            for (px, py) in [(0.0, 0.62), (0.22, 0.3), (0.42, 0.58), (0.66, 0.22), (0.9, 0.55), (1.05, 0.4)] {
                peaks.addLine(to: CGPoint(x: g.minX + px * g.width, y: g.minY + py * g.height))
            }
            peaks.addLine(to: CGPoint(x: g.maxX, y: ground))
            peaks.closeSubpath()
            c.fill(peaks, with: .linearGradient(Gradient(colors: [PreviewRGB.white.color(), PreviewRGB(0.7, 0.78, 0.9).color()]),
                                                startPoint: CGPoint(x: 0, y: g.minY + 10), endPoint: CGPoint(x: 0, y: ground)))
            for index in 0..<22 where !reduceMotion || index < 12 {
                let fall = reduceMotion ? 0.4 : fract(time * (0.08 + Double(index % 5) * 0.015) + Double(index) * 0.137)
                let sx = g.minX + fract(Double(index) * 0.41 + sin(time * 0.6 + Double(index)) * 0.03) * g.width
                c.fill(circle(CGPoint(x: sx, y: g.minY + fall * g.height), 0.9), with: .color(.white.opacity(0.9)))
            }
        case .forest:
            hills(&c, g, color: (night ? PreviewRGB(0.08, 0.15, 0.12) : PreviewRGB(0.45, 0.68, 0.42)).mix(p.green, 0.25), height: 14)
            for index in 0..<9 {
                let tx = g.minX + Double(index) * g.width / 8 + (index.isMultiple(of: 2) ? 2 : -2)
                let th = 16 + Double((index * 7) % 9)
                var tree = Path()
                tree.move(to: CGPoint(x: tx, y: ground - th))
                tree.addLine(to: CGPoint(x: tx + 5, y: ground - 2))
                tree.addLine(to: CGPoint(x: tx - 5, y: ground - 2))
                tree.closeSubpath()
                c.fill(tree, with: .color((night ? PreviewRGB(0.04, 0.1, 0.08) : PreviewRGB(0.2, 0.42, 0.28)).mix(p.green, 0.2).color()))
            }
        case .ocean:
            let horizon = g.minY + g.height * 0.55
            c.fill(Path(CGRect(x: g.minX, y: horizon, width: g.width, height: ground - horizon)), with: .linearGradient(
                Gradient(colors: [(night ? PreviewRGB(0.06, 0.12, 0.25) : PreviewRGB(0.2, 0.5, 0.78)).mix(p.blue, 0.25).color(),
                                  (night ? PreviewRGB(0.02, 0.05, 0.12) : PreviewRGB(0.1, 0.32, 0.6)).color()]),
                startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: ground)))
            for line in 0..<4 {
                let ly = horizon + 4 + Double(line) * 6
                var wave = Path()
                let shift = reduceMotion ? 0 : time * (6 + Double(line) * 3)
                var wx = g.minX - 12 + (shift.truncatingRemainder(dividingBy: 12))
                wave.move(to: CGPoint(x: wx, y: ly))
                while wx < g.maxX + 12 {
                    wave.addQuadCurve(to: CGPoint(x: wx + 6, y: ly), control: CGPoint(x: wx + 3, y: ly - 1.6))
                    wx += 6
                }
                c.stroke(wave, with: .color(.white.opacity(0.35 - Double(line) * 0.06)), lineWidth: 0.7)
            }
        case .desert:
            let sun = CGPoint(x: g.midX + 8, y: g.minY + g.height * 0.52)
            c.fill(circle(sun, 22), with: .radialGradient(Gradient(colors: [PreviewRGB(1, 0.85, 0.5).color(0.6), .clear]),
                                                          center: sun, startRadius: 6, endRadius: 22))
            c.fill(circle(sun, 9), with: .color(PreviewRGB(1, 0.78, 0.35).mix(p.yellow, 0.3).color()))
            var dune = Path()
            dune.move(to: CGPoint(x: g.minX, y: ground))
            dune.addLine(to: CGPoint(x: g.minX, y: ground - 12))
            dune.addQuadCurve(to: CGPoint(x: g.midX, y: ground - 8), control: CGPoint(x: g.minX + 20, y: ground - 22))
            dune.addQuadCurve(to: CGPoint(x: g.maxX, y: ground - 14), control: CGPoint(x: g.maxX - 18, y: ground - 2))
            dune.addLine(to: CGPoint(x: g.maxX, y: ground))
            dune.closeSubpath()
            c.fill(dune, with: .color((night ? PreviewRGB(0.35, 0.2, 0.22) : PreviewRGB(0.92, 0.66, 0.4)).mix(p.yellow, 0.2).color()))
        case .space:
            let planet = CGPoint(x: g.minX + g.width * 0.7, y: g.minY + g.height * 0.38)
            c.fill(circle(planet, 9), with: .linearGradient(Gradient(colors: [p.magenta.mix(.white, 0.3).color(), p.blue.mix(.black, 0.3).color()]),
                                                            startPoint: CGPoint(x: planet.x - 9, y: planet.y - 9), endPoint: CGPoint(x: planet.x + 9, y: planet.y + 9)))
            c.stroke(Path(ellipseIn: CGRect(x: planet.x - 16, y: planet.y - 3.5, width: 32, height: 7)),
                     with: .color(p.yellow.mix(.white, 0.4).color(0.8)), lineWidth: 1.2)
            // Aurora ribbon.
            var ribbon = Path()
            let shift = reduceMotion ? 0 : sin(time * 0.5) * 4
            ribbon.move(to: CGPoint(x: g.minX, y: g.minY + 30 + shift))
            ribbon.addCurve(to: CGPoint(x: g.maxX, y: g.minY + 22 - shift), control1: CGPoint(x: g.minX + 25, y: g.minY + 12),
                            control2: CGPoint(x: g.maxX - 30, y: g.minY + 44))
            c.stroke(ribbon, with: .linearGradient(Gradient(colors: [p.green.color(0.0), p.green.mix(.white, 0.2).color(0.5), p.cyan.color(0.0)]),
                                                   startPoint: CGPoint(x: g.minX, y: 0), endPoint: CGPoint(x: g.maxX, y: 0)), lineWidth: 6)
            hills(&c, g, color: PreviewRGB(0.05, 0.06, 0.1), height: 8)
        case .rain:
            hills(&c, g, color: night ? PreviewRGB(0.06, 0.08, 0.1) : PreviewRGB(0.38, 0.45, 0.42), height: 10)
            var drops = Path()
            for index in 0..<26 {
                let fall = reduceMotion ? fract(Double(index) * 0.29) : fract(time * 1.6 + Double(index) * 0.29)
                let dx = g.minX + fract(Double(index) * 0.53) * (g.width + 10)
                let dy = g.minY + fall * (g.height + 10) - 10
                drops.move(to: CGPoint(x: dx, y: dy))
                drops.addLine(to: CGPoint(x: dx - 1.5, y: dy + 5))
            }
            c.stroke(drops, with: .color(PreviewRGB(0.75, 0.85, 1).color(0.6)), lineWidth: 0.6)
        }
    }

    private func hills(_ c: inout GraphicsContext, _ g: CGRect, color: PreviewRGB, height: Double) {
        var path = Path()
        path.move(to: CGPoint(x: g.minX, y: g.maxY))
        path.addLine(to: CGPoint(x: g.minX, y: g.maxY - height * 0.6))
        path.addQuadCurve(to: CGPoint(x: g.midX, y: g.maxY - height * 0.7), control: CGPoint(x: g.minX + g.width * 0.25, y: g.maxY - height * 1.4))
        path.addQuadCurve(to: CGPoint(x: g.maxX, y: g.maxY - height * 0.8), control: CGPoint(x: g.maxX - g.width * 0.2, y: g.maxY - height * 0.1))
        path.addLine(to: CGPoint(x: g.maxX, y: g.maxY))
        path.closeSubpath()
        c.fill(path, with: .color(color.color()))
    }

    private func cloud(_ c: inout GraphicsContext, _ center: CGPoint, _ scale: Double) {
        var path = Path()
        let s = 7 * scale
        path.addEllipse(in: CGRect(x: center.x - s * 1.6, y: center.y - s * 0.2, width: s * 3.2, height: s * 1.1))
        path.addEllipse(in: CGRect(x: center.x - s * 0.9, y: center.y - s * 0.9, width: s * 1.4, height: s * 1.4))
        path.addEllipse(in: CGRect(x: center.x - s * 0.1, y: center.y - s * 1.2, width: s * 1.6, height: s * 1.6))
        c.fill(path, with: .color(.white.opacity(0.92)))
    }

    // MARK: Wall art

    private func drawArt(_ c: inout GraphicsContext) {
        let frame = ThemeRoomScene.artFrame
        if room.art == .neon {
            drawNeon(&c, frame)
            return
        }
        if room.art == .binaryClock {
            drawBinaryClock(&c, frame: frame)
            return
        }
        if room.art == .hashNeon {
            drawHashNeon(&c, center: CGPoint(x: frame.midX, y: frame.midY))
            return
        }
        let frameColor: PreviewRGB = room.art == .chalkboard ? p.wood : (night ? p.yellow.mix(p.wood, 0.6) : p.wood.mix(.black, 0.2))
        c.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 2, y: 1.5))
            layer.fill(Path(CGRect(x: frame.minX - 3, y: frame.minY - 3, width: frame.width + 6, height: frame.height + 6)),
                       with: .color(frameColor.color()))
        }
        var art = c
        art.clip(to: Path(frame))
        switch room.art {
        case .abstract:
            art.fill(Path(frame), with: .color(PreviewRGB(0.95, 0.93, 0.88).mix(p.background, 0.1).color()))
            art.fill(circle(CGPoint(x: frame.minX + 18, y: frame.midY + 2), 11), with: .color(p.red.mix(p.yellow, 0.3).color()))
            art.fill(Path(CGRect(x: frame.midX, y: frame.minY + 6, width: 16, height: 26)), with: .color(p.blue.color()))
            var arc = Path()
            arc.addArc(center: CGPoint(x: frame.maxX - 8, y: frame.maxY), radius: 12, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            art.fill(arc, with: .color(p.yellow.color()))
            art.fill(Path(CGRect(x: frame.minX + 6, y: frame.maxY - 8, width: 30, height: 2)), with: .color(PreviewRGB(0.15, 0.15, 0.18).color()))
        case .wave:
            art.fill(Path(frame), with: .color(PreviewRGB(0.93, 0.88, 0.76).color()))
            var swell = Path()
            swell.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            swell.addLine(to: CGPoint(x: frame.minX, y: frame.maxY - 10))
            swell.addCurve(to: CGPoint(x: frame.minX + 30, y: frame.minY + 8), control1: CGPoint(x: frame.minX + 8, y: frame.minY + 14),
                           control2: CGPoint(x: frame.minX + 18, y: frame.minY + 2))
            swell.addCurve(to: CGPoint(x: frame.minX + 26, y: frame.minY + 20), control1: CGPoint(x: frame.minX + 40, y: frame.minY + 12),
                           control2: CGPoint(x: frame.minX + 34, y: frame.minY + 22))
            swell.addCurve(to: CGPoint(x: frame.maxX, y: frame.maxY - 6), control1: CGPoint(x: frame.minX + 30, y: frame.maxY - 4),
                           control2: CGPoint(x: frame.maxX - 10, y: frame.maxY - 12))
            swell.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            swell.closeSubpath()
            art.fill(swell, with: .color(PreviewRGB(0.12, 0.22, 0.42).mix(p.blue, 0.2).color()))
            for index in 0..<5 {
                art.fill(circle(CGPoint(x: frame.minX + 22 + Double(index) * 3.2, y: frame.minY + 8 + Double(index % 2) * 2), 1.4), with: .color(.white))
            }
            var peak = Path()
            peak.move(to: CGPoint(x: frame.maxX - 18, y: frame.maxY - 8))
            peak.addLine(to: CGPoint(x: frame.maxX - 12, y: frame.maxY - 16))
            peak.addLine(to: CGPoint(x: frame.maxX - 6, y: frame.maxY - 8))
            peak.closeSubpath()
            art.fill(peak, with: .color(PreviewRGB(0.35, 0.4, 0.5).color()))
        case .code:
            art.fill(Path(frame), with: .color(p.background.mix(.black, p.isLight ? 0.75 : 0.35).color()))
            label(&art, "</>", at: CGPoint(x: frame.midX, y: frame.minY + 15), size: 14, weight: .heavy, color: p.cyan, design: .monospaced)
            for (index, color) in [p.green, p.magenta, p.yellow].enumerated() {
                art.fill(Path(roundedRect: CGRect(x: frame.minX + 8, y: frame.minY + 25 + Double(index) * 4.5, width: [30, 22, 34][index], height: 2),
                              cornerRadius: 1), with: .color(color.color()))
            }
        case .moon:
            art.fill(Path(frame), with: .color(PreviewRGB(0.1, 0.08, 0.16).mix(p.magenta, 0.1).color()))
            let moon = CGPoint(x: frame.midX + 6, y: frame.midY - 3)
            art.fill(circle(moon, 11), with: .color(PreviewRGB(0.98, 0.94, 0.8).color()))
            for (index, spot) in [CGPoint(x: frame.minX + 12, y: frame.minY + 12), CGPoint(x: frame.minX + 18, y: frame.maxY - 12),
                                   CGPoint(x: frame.maxX - 10, y: frame.maxY - 8)].enumerated() {
                bat(&art, spot, 3.2 - Double(index) * 0.5)
            }
        case .flower:
            art.fill(Path(frame), with: .color(PreviewRGB(0.97, 0.94, 0.9).color()))
            for (index, x) in [frame.minX + 16, frame.midX, frame.maxX - 14].enumerated() {
                let top = CGPoint(x: x, y: frame.minY + 12 + Double(index % 2) * 5)
                var stem = Path()
                stem.move(to: CGPoint(x: frame.midX, y: frame.maxY - 6))
                stem.addQuadCurve(to: top, control: CGPoint(x: x, y: frame.maxY - 14))
                art.stroke(stem, with: .color(p.green.mix(.black, 0.2).color()), lineWidth: 1)
                for petal in 0..<5 {
                    let a = Double(petal) * 2 * .pi / 5 + Double(index)
                    art.fill(circle(CGPoint(x: top.x + cos(a) * 3, y: top.y + sin(a) * 3), 2.6),
                             with: .color([p.magenta, p.red, p.yellow][index].mix(.white, 0.1).color()))
                }
                art.fill(circle(top, 1.6), with: .color(p.yellow.mix(.white, 0.4).color()))
            }
            art.fill(Path(roundedRect: CGRect(x: frame.midX - 6, y: frame.maxY - 9, width: 12, height: 9), cornerRadius: 2), with: .color(p.blue.color()))
        case .chalkboard:
            art.fill(Path(frame), with: .color(PreviewRGB(0.14, 0.24, 0.2).color()))
            label(&art, "λx.x", at: CGPoint(x: frame.midX, y: frame.minY + 12), size: 9, weight: .regular, color: PreviewRGB(0.92, 0.92, 0.88), design: .serif)
            var scribble = Path()
            scribble.move(to: CGPoint(x: frame.minX + 6, y: frame.maxY - 12))
            for step in 0..<8 {
                let x = frame.minX + 6 + Double(step + 1) * 5
                scribble.addQuadCurve(to: CGPoint(x: x, y: frame.maxY - 12), control: CGPoint(x: x - 2.5, y: frame.maxY - (step.isMultiple(of: 2) ? 18 : 7)))
            }
            art.stroke(scribble, with: .color(.white.opacity(0.75)), lineWidth: 0.7)
            art.fill(Path(CGRect(x: frame.minX, y: frame.maxY - 3, width: frame.width, height: 3)), with: .color(p.wood.mix(.white, 0.1).color()))
        case .rainbow:
            art.fill(Path(frame), with: .color(PreviewRGB(0.98, 0.97, 0.94).color()))
            for (index, color) in [p.red, p.yellow, p.green, p.cyan, p.blue, p.magenta].enumerated() {
                var band = Path()
                band.addArc(center: CGPoint(x: frame.midX, y: frame.maxY - 4), radius: 20 - Double(index) * 3,
                            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                art.stroke(band, with: .color(color.color()), lineWidth: 3)
            }
        case .prompt:
            // A framed root shell: `#` is root's prompt.
            art.fill(Path(frame), with: .color(p.background.mix(.black, p.isLight ? 0.82 : 0.4).color()))
            art.fill(Path(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 6)), with: .color(PreviewRGB(0.22, 0.22, 0.25).color()))
            for (index, color) in [PreviewRGB(1, 0.37, 0.34), PreviewRGB(1, 0.74, 0.18), PreviewRGB(0.16, 0.78, 0.25)].enumerated() {
                art.fill(circle(CGPoint(x: frame.minX + 4 + Double(index) * 4, y: frame.minY + 3), 1.2), with: .color(color.color()))
            }
            let text = p.isLight ? PreviewRGB(0.85, 0.88, 0.9) : p.foreground
            let lines: [(String, PreviewRGB)] = [("~ # whoami", text), ("root", p.green), ("~ #", text)]
            for (index, line) in lines.enumerated() {
                label(&art, line.0, at: CGPoint(x: frame.minX + 4, y: frame.minY + 13 + Double(index) * 8.5),
                      size: 6.2, weight: .semibold, color: line.1, design: .monospaced, anchor: .leading)
            }
            let blink = reduceMotion || fract(time / 1.1) < 0.55
            if blink {
                art.fill(Path(CGRect(x: frame.minX + 18.5, y: frame.minY + 26.5, width: 3.4, height: 6)), with: .color(p.cursor.color()))
            }
        case .neon, .hashNeon, .binaryClock:
            break
        }
    }

    private func drawNeon(_ c: inout GraphicsContext, _ frame: CGRect) {
        let flicker = reduceMotion ? 1 : (fract(time / 4.7) < 0.03 ? 0.4 : 1)
        var tube = Path()
        // A lightning bolt beside a sine squiggle.
        tube.move(to: CGPoint(x: frame.minX + 14, y: frame.minY + 2))
        tube.addLine(to: CGPoint(x: frame.minX + 6, y: frame.midY + 2))
        tube.addLine(to: CGPoint(x: frame.minX + 14, y: frame.midY + 2))
        tube.addLine(to: CGPoint(x: frame.minX + 8, y: frame.maxY))
        var squiggle = Path()
        squiggle.move(to: CGPoint(x: frame.minX + 22, y: frame.midY))
        for step in 0..<4 {
            let x = frame.minX + 22 + Double(step + 1) * 7
            squiggle.addQuadCurve(to: CGPoint(x: x, y: frame.midY), control: CGPoint(x: x - 3.5, y: frame.midY + (step.isMultiple(of: 2) ? -9 : 9)))
        }
        for (path, color) in [(tube, p.yellow), (squiggle, p.magenta)] {
            c.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.stroke(path, with: .color(color.color(0.8 * flicker)), lineWidth: 4)
            }
            c.stroke(path, with: .color(color.mix(.white, 0.55).color(flicker)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        c.fill(Path(ellipseIn: frame.insetBy(dx: -14, dy: -10)), with: .radialGradient(
            Gradient(colors: [p.magenta.color(0.18 * flicker), .clear]), center: CGPoint(x: frame.midX, y: frame.midY), startRadius: 0, endRadius: 40))
    }

    /// A BCD binary clock reading the local time: columns for the tens and ones
    /// of hours, minutes, and seconds, least significant bit at the bottom.
    private func drawBinaryClock(_ c: inout GraphicsContext, frame: CGRect) {
        let panel = frame.insetBy(dx: -2, dy: 0)
        c.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, y: 1.5))
            layer.fill(Path(roundedRect: panel, cornerRadius: 3), with: .color(PreviewRGB(0.09, 0.09, 0.11).color()))
        }
        c.stroke(Path(roundedRect: panel.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 2.6), with: .color(p.trim.mix(.white, 0.15).color(0.6)), lineWidth: 0.8)

        let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let hour = now.hour ?? 0, minute = now.minute ?? 0, second = reduceMotion ? 0 : (now.second ?? 0)
        let digits = [hour / 10, hour % 10, minute / 10, minute % 10, second / 10, second % 10]
        let rows = [2, 4, 3, 4, 3, 4]
        // The cursor color, unless it is too gray or dark to read as a lit LED.
        let cursor = p.cursor
        let chroma = max(cursor.r, cursor.g, cursor.b) - min(cursor.r, cursor.g, cursor.b)
        let led = chroma > 0.2 && cursor.luminance > 0.25 ? cursor : p.green
        let pitch = 6.6, radius = 2.1
        let groupGap = 2.4
        let width = pitch * 5 + groupGap * 2
        let left = panel.midX - width / 2
        let bottom = panel.maxY - 9
        var lit = Path(), dark = Path()
        for (column, digit) in digits.enumerated() {
            let x = left + Double(column) * pitch + Double(column / 2) * groupGap
            for bit in 0..<rows[column] {
                let dot = circle(CGPoint(x: x, y: bottom - Double(bit) * pitch), radius)
                if digit >> bit & 1 == 1 { lit.addPath(dot) } else { dark.addPath(dot) }
            }
        }
        c.fill(dark, with: .color(led.mix(.black, 0.78).color()))
        c.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            layer.fill(lit, with: .color(led.color(0.8)))
        }
        c.fill(lit, with: .color(led.mix(.white, 0.35).color()))
        for (index, unit) in ["H", "M", "S"].enumerated() {
            let x = left + pitch * (Double(index) * 2 + 0.5) + Double(index) * groupGap
            label(&c, unit, at: CGPoint(x: x, y: panel.maxY - 3.6), size: 3.6, weight: .bold,
                  color: PreviewRGB(0.6, 0.62, 0.66), design: .monospaced)
        }
    }

    /// The rootshell mark as a neon tube on the wall.
    private func drawHashNeon(_ c: inout GraphicsContext, center: CGPoint) {
        let tube = p.cursor.mix(p.cyan, 0.3)
        let flicker = reduceMotion ? 1 : (fract(time / 6.3) < 0.025 ? 0.35 : 0.92 + 0.08 * sin(time * 9))
        let mark = hashPath(center: center, size: 30)
        c.fill(Path(roundedRect: CGRect(x: center.x - 21, y: center.y - 19, width: 42, height: 38), cornerRadius: 4),
               with: .color(PreviewRGB.black.color(p.isLight ? 0.08 : 0.25)))
        c.fill(Path(ellipseIn: CGRect(x: center.x - 36, y: center.y - 32, width: 72, height: 64)), with: .radialGradient(
            Gradient(colors: [tube.color(0.22 * flicker), .clear]), center: center, startRadius: 0, endRadius: 36))
        c.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(mark, with: .color(tube.color(0.85 * flicker)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        c.stroke(mark, with: .color(tube.mix(.white, 0.6).color(flicker)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// A slanted `#`, two rails and two rungs.
    private func hashPath(center: CGPoint, size: Double) -> Path {
        let h = size / 2, slant = size * 0.12
        var path = Path()
        for dx in [-0.2, 0.2] {
            path.move(to: CGPoint(x: center.x + dx * size + slant, y: center.y - h))
            path.addLine(to: CGPoint(x: center.x + dx * size - slant, y: center.y + h))
        }
        for dy in [-0.2, 0.2] {
            path.move(to: CGPoint(x: center.x - h, y: center.y + dy * size))
            path.addLine(to: CGPoint(x: center.x + h, y: center.y + dy * size))
        }
        return path
    }

    private func bat(_ c: inout GraphicsContext, _ center: CGPoint, _ size: Double) {
        let flap = reduceMotion ? 0 : sin(time * 9 + center.x) * 0.35
        var wing = Path()
        wing.move(to: center)
        wing.addQuadCurve(to: CGPoint(x: center.x - size * 2, y: center.y - size * (0.6 + flap)), control: CGPoint(x: center.x - size, y: center.y - size))
        wing.addQuadCurve(to: CGPoint(x: center.x - size * 0.8, y: center.y + size * 0.2), control: CGPoint(x: center.x - size * 1.5, y: center.y + size * 0.3))
        wing.addLine(to: center)
        wing.addQuadCurve(to: CGPoint(x: center.x + size * 2, y: center.y - size * (0.6 + flap)), control: CGPoint(x: center.x + size, y: center.y - size))
        wing.addQuadCurve(to: CGPoint(x: center.x + size * 0.8, y: center.y + size * 0.2), control: CGPoint(x: center.x + size * 1.5, y: center.y + size * 0.3))
        wing.closeSubpath()
        c.fill(wing, with: .color(PreviewRGB(0.05, 0.04, 0.08).color()))
    }

    // MARK: Lighting

    private func drawPendant(_ c: inout GraphicsContext) {
        let x = 164.0
        c.fill(Path(CGRect(x: x - 0.4, y: ceiling, width: 0.8, height: 20 - ceiling)), with: .color(p.foreground.mix(p.background, 0.5).color()))
        var shade = Path()
        shade.move(to: CGPoint(x: x - 5, y: 19))
        shade.addLine(to: CGPoint(x: x + 5, y: 19))
        shade.addLine(to: CGPoint(x: x + 13, y: 30))
        shade.addLine(to: CGPoint(x: x - 13, y: 30))
        shade.closeSubpath()
        let shadeColor = p.cyan.mix(p.background, 0.25)
        c.fill(shade, with: .linearGradient(Gradient(colors: [shadeColor.mix(.white, 0.2).color(), shadeColor.mix(.black, 0.2).color()]),
                                            startPoint: CGPoint(x: x - 13, y: 0), endPoint: CGPoint(x: x + 13, y: 0)))
        let bulb = CGPoint(x: x, y: 31)
        c.fill(Path(ellipseIn: CGRect(x: x - 5, y: 29, width: 10, height: 4)), with: .color(p.yellow.mix(.white, 0.7).color()))
        if night {
            var cone = Path()
            cone.move(to: CGPoint(x: x - 12, y: 30))
            cone.addLine(to: CGPoint(x: x + 12, y: 30))
            cone.addLine(to: CGPoint(x: x + 45, y: 100))
            cone.addLine(to: CGPoint(x: x - 45, y: 100))
            cone.closeSubpath()
            var light = c
            light.blendMode = .plusLighter
            light.fill(cone, with: .linearGradient(Gradient(colors: [p.yellow.mix(.white, 0.3).color(0.16), .clear]),
                                                   startPoint: bulb, endPoint: CGPoint(x: x, y: 100)))
        }
    }

    // MARK: Rug and corner

    private func drawRug(_ c: inout GraphicsContext) {
        let rug = CGRect(x: 92, y: 124, width: 172, height: 20)
        c.fill(Path(ellipseIn: rug), with: .color(p.magenta.mix(p.background, 0.45).color()))
        c.stroke(Path(ellipseIn: rug.insetBy(dx: 7, dy: 3)), with: .color(p.yellow.mix(p.background, 0.3).color(0.8)), lineWidth: 1)
        c.stroke(Path(ellipseIn: rug.insetBy(dx: 18, dy: 6)), with: .color(p.cyan.mix(p.background, 0.3).color(0.6)), lineWidth: 0.8)
        if room.hashMark {
            // Squashed to lie flat on the floor.
            var stitch = c
            stitch.translateBy(x: rug.midX, y: rug.midY)
            stitch.scaleBy(x: 1.2, y: 0.5)
            stitch.stroke(hashPath(center: .zero, size: 18), with: .color(p.yellow.mix(p.background, 0.25).color(0.75)),
                          style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }

    private func drawCorner(_ c: inout GraphicsContext) {
        switch room.corner {
        case .lamp:
            c.fill(Path(ellipseIn: CGRect(x: 25, y: 116, width: 18, height: 5)), with: .color(PreviewRGB(0.15, 0.15, 0.17).color()))
            c.fill(Path(CGRect(x: 33, y: 46, width: 1.6, height: 72)), with: .color(PreviewRGB(0.2, 0.2, 0.22).color()))
            var shade = Path()
            shade.move(to: CGPoint(x: 26, y: 30))
            shade.addLine(to: CGPoint(x: 42, y: 30))
            shade.addLine(to: CGPoint(x: 48, y: 48))
            shade.addLine(to: CGPoint(x: 20, y: 48))
            shade.closeSubpath()
            let fabric = PreviewRGB(0.96, 0.92, 0.82).mix(p.yellow, 0.2)
            c.fill(shade, with: .linearGradient(Gradient(colors: [fabric.color(), fabric.mix(.black, 0.15).color()]),
                                                startPoint: CGPoint(x: 20, y: 0), endPoint: CGPoint(x: 48, y: 0)))
            if night {
                c.fill(circle(CGPoint(x: 34, y: 44), 30), with: .radialGradient(Gradient(colors: [p.yellow.mix(.white, 0.5).color(0.3), .clear]),
                                                                                center: CGPoint(x: 34, y: 44), startRadius: 0, endRadius: 30))
            }
        case .plant:
            drawPot(&c, CGRect(x: 22, y: 98, width: 24, height: 20))
            let sway = reduceMotion ? 0 : sin(time * 0.8) * 2
            for (index, leaf) in [(-40.0, 34.0), (-10.0, 40.0), (25.0, 36.0), (-70.0, 26.0), (55.0, 28.0), (5.0, 26.0)].enumerated() {
                let angle = (leaf.0 + sway * (index.isMultiple(of: 2) ? 1 : -1)) * .pi / 180
                let base = CGPoint(x: 34, y: 98)
                let tip = CGPoint(x: base.x + sin(angle) * leaf.1, y: base.y - cos(angle) * leaf.1)
                var stem = Path()
                stem.move(to: base)
                stem.addLine(to: CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2))
                c.stroke(stem, with: .color(p.green.mix(.black, 0.4).color()), lineWidth: 0.9)
                var layer = c
                layer.translateBy(x: tip.x, y: tip.y)
                layer.rotate(by: .radians(angle))
                let shape = Path(ellipseIn: CGRect(x: -8, y: -4, width: 16, height: 20))
                let green = p.green.mix(PreviewRGB(0.2, 0.55, 0.3), 0.4).mix(.black, Double(index % 3) * 0.12)
                layer.fill(shape, with: .linearGradient(Gradient(colors: [green.mix(.white, 0.15).color(), green.mix(.black, 0.2).color()]),
                                                        startPoint: CGPoint(x: -8, y: 0), endPoint: CGPoint(x: 8, y: 0)))
                layer.fill(Path(CGRect(x: -0.4, y: -3, width: 0.8, height: 17)), with: .color(green.mix(.black, 0.35).color()))
                // Monstera splits.
                for side in [-1.0, 1.0] {
                    layer.fill(Path(CGRect(x: side > 0 ? 3 : -8, y: 6, width: 5, height: 0.9)), with: .color(p.background.color()))
                }
            }
        case .bonsai:
            c.fill(Path(roundedRect: CGRect(x: 14, y: 96, width: 40, height: 4), cornerRadius: 1), with: .color(p.wood.color()))
            c.fill(Path(CGRect(x: 18, y: 100, width: 3, height: 18)), with: .color(p.wood.mix(.black, 0.2).color()))
            c.fill(Path(CGRect(x: 47, y: 100, width: 3, height: 18)), with: .color(p.wood.mix(.black, 0.2).color()))
            c.fill(Path(roundedRect: CGRect(x: 20, y: 89, width: 28, height: 7), cornerRadius: 2), with: .color(p.blue.mix(p.background, 0.2).color()))
            var trunk = Path()
            trunk.move(to: CGPoint(x: 33, y: 90))
            trunk.addCurve(to: CGPoint(x: 40, y: 66), control1: CGPoint(x: 26, y: 82), control2: CGPoint(x: 44, y: 76))
            trunk.move(to: CGPoint(x: 36, y: 78))
            trunk.addQuadCurve(to: CGPoint(x: 22, y: 72), control: CGPoint(x: 28, y: 78))
            c.stroke(trunk, with: .color(PreviewRGB(0.35, 0.25, 0.2).color()), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            for pad in [CGPoint(x: 40, y: 64), CGPoint(x: 22, y: 70), CGPoint(x: 31, y: 60)] {
                let green = p.green.mix(PreviewRGB(0.25, 0.45, 0.3), 0.5)
                var cloud = Path()
                cloud.addEllipse(in: CGRect(x: pad.x - 9, y: pad.y - 3, width: 18, height: 7))
                cloud.addEllipse(in: CGRect(x: pad.x - 5, y: pad.y - 6, width: 10, height: 7))
                c.fill(cloud, with: .linearGradient(Gradient(colors: [green.mix(.white, 0.15).color(), green.mix(.black, 0.2).color()]),
                                                    startPoint: CGPoint(x: 0, y: pad.y - 6), endPoint: CGPoint(x: 0, y: pad.y + 4)))
            }
        case .bookshelf:
            let shelf = CGRect(x: 8, y: 34, width: 50, height: 84)
            c.fill(Path(shelf), with: .color(p.wood.mix(.black, 0.15).color()))
            c.fill(Path(shelf.insetBy(dx: 3, dy: 3)), with: .color(p.wood.mix(.black, 0.45).color()))
            let colors = [p.red, p.blue, p.yellow, p.green, p.magenta, p.cyan, p.foreground.mix(p.background, 0.3)]
            var seed: UInt64 = 0xB00C
            for row in 0..<3 {
                let base = shelf.minY + 3 + Double(row + 1) * 26
                c.fill(Path(CGRect(x: shelf.minX, y: base, width: shelf.width, height: 2.5)), with: .color(p.wood.color()))
                var x = shelf.minX + 4
                while x < shelf.maxX - 7 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let width = 3 + Double(seed >> 62), height = 14 + Double((seed >> 56) % 7)
                    let color = colors[Int((seed >> 40) % UInt64(colors.count))].mix(p.background, 0.15)
                    c.fill(Path(roundedRect: CGRect(x: x, y: base - height, width: width, height: height), cornerRadius: 0.6), with: .color(color.color()))
                    c.fill(Path(CGRect(x: x, y: base - height + 3, width: width, height: 0.7)), with: .color(.white.opacity(0.35)))
                    x += width + 0.6
                }
            }
        case .arcade:
            var cabinet = Path()
            cabinet.move(to: CGPoint(x: 14, y: 118))
            cabinet.addLine(to: CGPoint(x: 14, y: 36))
            cabinet.addLine(to: CGPoint(x: 54, y: 36))
            cabinet.addLine(to: CGPoint(x: 54, y: 118))
            cabinet.closeSubpath()
            c.fill(cabinet, with: .linearGradient(Gradient(colors: [p.magenta.mix(.black, 0.35).color(), p.blue.mix(.black, 0.5).color()]),
                                                  startPoint: CGPoint(x: 0, y: 36), endPoint: CGPoint(x: 0, y: 118)))
            c.fill(Path(CGRect(x: 14, y: 36, width: 40, height: 9)), with: .color(p.yellow.mix(.white, 0.2).color()))
            label(&c, "PLAY", at: CGPoint(x: 34, y: 40.5), size: 5.5, weight: .heavy, color: p.magenta.mix(.black, 0.3), design: .rounded)
            let screen = CGRect(x: 18, y: 49, width: 32, height: 24)
            c.fill(Path(roundedRect: screen, cornerRadius: 2), with: .color(PreviewRGB(0.03, 0.04, 0.08).color()))
            let blink = reduceMotion ? 0 : Int(time * 3) % 6
            for index in 0..<6 {
                let px = screen.minX + 4 + Double(index) * 4.5, py = screen.minY + 5 + Double(index % 2) * 4
                c.fill(Path(CGRect(x: px, y: py, width: 2.4, height: 2.4)), with: .color((index == blink ? p.yellow : p.green).color()))
            }
            c.fill(Path(CGRect(x: screen.midX - 1.5, y: screen.maxY - 6, width: 3, height: 3)), with: .color(p.cyan.color()))
            c.fill(Path(CGRect(x: 12, y: 76, width: 44, height: 10)), with: .color(PreviewRGB(0.14, 0.14, 0.18).color()))
            c.fill(Path(CGRect(x: 21, y: 72, width: 1.4, height: 6)), with: .color(PreviewRGB(0.7, 0.7, 0.75).color()))
            c.fill(circle(CGPoint(x: 21.7, y: 72), 2), with: .color(p.red.color()))
            for (index, color) in [p.yellow, p.cyan, p.magenta].enumerated() {
                c.fill(circle(CGPoint(x: 34 + Double(index) * 6, y: 81), 1.8), with: .color(color.color()))
            }
        case .server:
            let rack = CGRect(x: 12, y: 40, width: 42, height: 78)
            c.fill(Path(roundedRect: rack, cornerRadius: 2), with: .color(PreviewRGB(0.1, 0.1, 0.12).color()))
            for unit in 0..<6 {
                let row = CGRect(x: rack.minX + 3, y: rack.minY + 4 + Double(unit) * 12, width: rack.width - 6, height: 9)
                c.fill(Path(roundedRect: row, cornerRadius: 1), with: .color(PreviewRGB(0.18, 0.19, 0.22).color()))
                for vent in 0..<5 {
                    c.fill(Path(CGRect(x: row.minX + 3 + Double(vent) * 3, y: row.minY + 2, width: 1.4, height: 5)), with: .color(.black.opacity(0.5)))
                }
                for led in 0..<3 {
                    let on = reduceMotion ? led != 2 : fract(time * (0.7 + Double(unit) * 0.13 + Double(led) * 0.31) + Double(unit) * 0.2) < 0.6
                    let color = led == 2 ? p.yellow : p.green
                    c.fill(circle(CGPoint(x: row.maxX - 4 - Double(led) * 3.5, y: row.midY), 0.9), with: .color(color.color(on ? 1 : 0.2)))
                }
            }
        }
    }

    private func drawPot(_ c: inout GraphicsContext, _ rect: CGRect) {
        var pot = Path()
        pot.move(to: CGPoint(x: rect.minX, y: rect.minY))
        pot.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        pot.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY))
        pot.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
        pot.closeSubpath()
        let clay = p.red.mix(p.yellow, 0.4).mix(PreviewRGB(0.75, 0.42, 0.3), 0.5)
        c.fill(pot, with: .linearGradient(Gradient(colors: [clay.mix(.white, 0.12).color(), clay.mix(.black, 0.25).color()]),
                                          startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        c.fill(Path(CGRect(x: rect.minX - 1, y: rect.minY, width: rect.width + 2, height: 3)), with: .color(clay.mix(.black, 0.1).color()))
    }

    // MARK: Center

    private func drawCenter(_ c: inout GraphicsContext) {
        switch room.center {
        case .sofa: drawSofa(&c)
        case .desk: drawDesk(&c, retro: false)
        case .retroDesk: drawDesk(&c, retro: true)
        }
    }

    private func drawSofa(_ c: inout GraphicsContext) {
        let fabric = p.blue.mix(p.background, 0.2)
        c.fill(Path(ellipseIn: CGRect(x: 118, y: 117, width: 124, height: 7)), with: .color(.black.opacity(0.28)))
        let back = CGRect(x: 126, y: 76, width: 108, height: 28)
        c.fill(Path(roundedRect: back, cornerRadius: 7), with: .linearGradient(
            Gradient(colors: [fabric.mix(.white, 0.15).color(), fabric.mix(.black, 0.1).color()]),
            startPoint: CGPoint(x: 0, y: back.minY), endPoint: CGPoint(x: 0, y: back.maxY)))
        // Back cushion seams.
        for x in [back.minX + 36, back.minX + 72] {
            c.fill(Path(CGRect(x: x, y: back.minY + 4, width: 0.8, height: back.height - 6)), with: .color(.black.opacity(0.18)))
        }
        let seat = CGRect(x: 124, y: 100, width: 112, height: 13)
        c.fill(Path(roundedRect: seat, cornerRadius: 4), with: .linearGradient(
            Gradient(colors: [fabric.mix(.white, 0.22).color(), fabric.mix(.black, 0.15).color()]),
            startPoint: CGPoint(x: 0, y: seat.minY), endPoint: CGPoint(x: 0, y: seat.maxY)))
        c.fill(Path(CGRect(x: seat.midX - 0.4, y: seat.minY + 2, width: 0.8, height: 9)), with: .color(.black.opacity(0.15)))
        for x in [116.0, 232.0] {
            let arm = CGRect(x: x, y: 88, width: 14, height: 27)
            c.fill(Path(roundedRect: arm, cornerRadius: 6), with: .linearGradient(
                Gradient(colors: [fabric.mix(.white, 0.1).color(), fabric.mix(.black, 0.25).color()]),
                startPoint: CGPoint(x: 0, y: arm.minY), endPoint: CGPoint(x: 0, y: arm.maxY)))
        }
        for x in [122.0, 236.0] {
            c.fill(Path(CGRect(x: x, y: 114, width: 2.5, height: 6)), with: .color(p.wood.mix(.black, 0.3).color()))
        }
        // Throw pillows.
        for (index, x) in [138.0, 204.0].enumerated() {
            var pillow = Path()
            pillow.addRoundedRect(in: CGRect(x: x, y: 86, width: 18, height: 16), cornerSize: CGSize(width: 5, height: 5))
            let color = (index == 0 ? p.yellow : p.red).mix(p.background, 0.15)
            var layer = c
            layer.translateBy(x: x + 9, y: 94)
            layer.rotate(by: .degrees(index == 0 ? -8 : 7))
            layer.translateBy(x: -(x + 9), y: -94)
            layer.fill(pillow, with: .linearGradient(Gradient(colors: [color.mix(.white, 0.2).color(), color.mix(.black, 0.15).color()]),
                                                     startPoint: CGPoint(x: 0, y: 86), endPoint: CGPoint(x: 0, y: 102)))
        }
    }

    private func drawDesk(_ c: inout GraphicsContext, retro: Bool) {
        c.fill(Path(ellipseIn: CGRect(x: 126, y: 117, width: 108, height: 6)), with: .color(.black.opacity(0.25)))
        let top = CGRect(x: 128, y: 92, width: 104, height: 5)
        c.fill(Path(roundedRect: top, cornerRadius: 1.5), with: .color(p.wood.mix(.white, 0.08).color()))
        for x in [132.0, 225.0] {
            c.fill(Path(CGRect(x: x, y: 97, width: 3, height: 22)), with: .color(p.wood.mix(.black, 0.3).color()))
        }
        c.fill(Path(CGRect(x: 196, y: 97, width: 28, height: 12)), with: .color(p.wood.mix(.black, 0.15).color()))
        c.fill(Path(roundedRect: CGRect(x: 207, y: 102, width: 7, height: 1.5), cornerRadius: 0.75), with: .color(PreviewRGB(0.8, 0.8, 0.82).color()))

        // The monitor shows the theme itself.
        let screen: CGRect
        if retro {
            let body = CGRect(x: 152, y: 50, width: 50, height: 40)
            c.fill(Path(roundedRect: body, cornerRadius: 4), with: .linearGradient(
                Gradient(colors: [PreviewRGB(0.88, 0.85, 0.76).color(), PreviewRGB(0.72, 0.69, 0.6).color()]),
                startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
            screen = CGRect(x: 157, y: 54, width: 40, height: 28)
            c.fill(Path(roundedRect: screen.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(PreviewRGB(0.3, 0.29, 0.26).color()))
            c.fill(Path(roundedRect: CGRect(x: 160, y: 85, width: 34, height: 7), cornerRadius: 1), with: .color(PreviewRGB(0.8, 0.77, 0.68).color()))
        } else {
            let body = CGRect(x: 146, y: 48, width: 64, height: 40)
            c.fill(Path(roundedRect: body, cornerRadius: 3), with: .color(PreviewRGB(0.14, 0.14, 0.16).color()))
            screen = body.insetBy(dx: 2.5, dy: 2.5)
            c.fill(Path(CGRect(x: 175, y: 88, width: 6, height: 4)), with: .color(PreviewRGB(0.6, 0.62, 0.66).color()))
            c.fill(Path(roundedRect: CGRect(x: 168, y: 90.5, width: 20, height: 2), cornerRadius: 1), with: .color(PreviewRGB(0.6, 0.62, 0.66).color()))
        }
        var display = c
        display.clip(to: Path(roundedRect: screen, cornerRadius: retro ? 3 : 1))
        display.fill(Path(screen), with: .color((retro ? PreviewRGB(0.02, 0.05, 0.02) : p.background).color()))
        let lines: [(PreviewRGB, Double)] = [(p.green, 0.3), (p.foreground, 0.55), (p.blue, 0.4), (p.magenta, 0.25), (p.yellow, 0.5), (p.foreground, 0.35)]
        for (index, line) in lines.enumerated() {
            let y = screen.minY + 3 + Double(index) * 4
            guard y < screen.maxY - 3 else { break }
            display.fill(Path(roundedRect: CGRect(x: screen.minX + 3, y: y, width: (screen.width - 6) * line.1, height: 1.6), cornerRadius: 0.8),
                         with: .color((retro ? p.green : line.0).color(0.9)))
        }
        let blink = reduceMotion || sin(time * 5) > -0.2
        if blink {
            display.fill(Path(CGRect(x: screen.minX + 3, y: screen.minY + 3 + 6 * 4, width: 2, height: 2.4)), with: .color((retro ? p.green : p.cursor).color()))
        }
        if retro {
            for y in stride(from: screen.minY, to: screen.maxY, by: 1.4) {
                display.fill(Path(CGRect(x: screen.minX, y: y, width: screen.width, height: 0.5)), with: .color(.black.opacity(0.25)))
            }
        }
        display.fill(Path(screen), with: .linearGradient(Gradient(colors: [.white.opacity(0.1), .clear]),
                                                          startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.midX, y: screen.midY)))
        // Keyboard.
        c.fill(Path(roundedRect: CGRect(x: 158, y: 89, width: 38, height: 3), cornerRadius: 1), with: .color(PreviewRGB(0.22, 0.22, 0.25).color()))
        // Office chair seen from behind.
        let chair = CGRect(x: 164, y: 96, width: 28, height: 16)
        c.fill(Path(roundedRect: chair, cornerRadius: 6), with: .color(p.background.mix(.black, 0.5).mix(p.blue, 0.15).color()))
        c.fill(Path(CGRect(x: 177, y: 112, width: 2.4, height: 5)), with: .color(PreviewRGB(0.3, 0.3, 0.32).color()))
        c.fill(Path(roundedRect: CGRect(x: 168, y: 116.5, width: 20, height: 2), cornerRadius: 1), with: .color(PreviewRGB(0.3, 0.3, 0.32).color()))
    }

    // MARK: Side table

    private func drawSideTable(_ c: inout GraphicsContext) {
        let x = 320.0
        c.fill(Path(ellipseIn: CGRect(x: x - 14, y: 118, width: 28, height: 4)), with: .color(.black.opacity(0.25)))
        c.fill(Path(CGRect(x: x - 1.2, y: 98, width: 2.4, height: 20)), with: .color(p.wood.mix(.black, 0.3).color()))
        c.fill(Path(ellipseIn: CGRect(x: x - 9, y: 117, width: 18, height: 3)), with: .color(p.wood.mix(.black, 0.35).color()))
        c.fill(Path(roundedRect: CGRect(x: x - 16, y: 94, width: 32, height: 4), cornerRadius: 2), with: .color(p.wood.mix(.white, 0.1).color()))
        let base = CGPoint(x: x, y: 94)
        switch room.table {
        case .succulent:
            drawPot(&c, CGRect(x: x - 6, y: 85, width: 12, height: 9))
            for angle in stride(from: -60.0, through: 60.0, by: 30) {
                var leaf = c
                leaf.translateBy(x: x, y: 86)
                leaf.rotate(by: .degrees(angle))
                leaf.fill(Path(ellipseIn: CGRect(x: -2, y: -9, width: 4, height: 9)), with: .color(p.green.mix(p.cyan, 0.3).color()))
            }
        case .mug:
            let mug = CGRect(x: x - 6, y: 83, width: 11, height: 11)
            c.stroke(Path(ellipseIn: CGRect(x: mug.maxX - 2, y: mug.minY + 2.5, width: 6, height: 6)), with: .color(p.red.mix(p.background, 0.1).color()), lineWidth: 1.6)
            c.fill(Path(roundedRect: mug, cornerRadius: 2), with: .linearGradient(
                Gradient(colors: [p.red.mix(.white, 0.15).color(), p.red.mix(.black, 0.2).color()]),
                startPoint: CGPoint(x: mug.minX, y: 0), endPoint: CGPoint(x: mug.maxX, y: 0)))
            c.fill(Path(ellipseIn: CGRect(x: mug.minX + 1, y: mug.minY - 0.5, width: mug.width - 2, height: 2)), with: .color(PreviewRGB(0.35, 0.2, 0.12).color()))
            if room.hashMark {
                label(&c, "#", at: CGPoint(x: mug.midX - 0.5, y: mug.midY + 0.5), size: 7, weight: .heavy, color: PreviewRGB.white.mix(p.red, 0.15), design: .rounded)
            }
            steam(&c, from: CGPoint(x: mug.midX, y: mug.minY - 1))
        case .candle:
            c.fill(Path(roundedRect: CGRect(x: x - 7, y: 92, width: 14, height: 2), cornerRadius: 1), with: .color(PreviewRGB(0.75, 0.65, 0.4).color()))
            c.fill(Path(roundedRect: CGRect(x: x - 2.5, y: 76, width: 5, height: 16), cornerRadius: 1), with: .color(PreviewRGB(0.96, 0.94, 0.88).color()))
            let flicker = reduceMotion ? 0 : sin(time * 13) * 0.6 + sin(time * 7.3) * 0.4
            var flame = Path()
            flame.move(to: CGPoint(x: x + flicker * 0.6, y: 68))
            flame.addQuadCurve(to: CGPoint(x: x, y: 76), control: CGPoint(x: x + 3.2, y: 74))
            flame.addQuadCurve(to: CGPoint(x: x + flicker * 0.6, y: 68), control: CGPoint(x: x - 3.2, y: 74))
            c.fill(flame, with: .linearGradient(Gradient(colors: [p.yellow.mix(.white, 0.6).color(), PreviewRGB(1, 0.55, 0.2).color()]),
                                                startPoint: CGPoint(x: x, y: 68), endPoint: CGPoint(x: x, y: 76)))
            c.fill(circle(CGPoint(x: x, y: 72), 14), with: .radialGradient(Gradient(colors: [p.yellow.color(0.3 + 0.05 * flicker), .clear]),
                                                                            center: CGPoint(x: x, y: 72), startRadius: 0, endRadius: 14))
        case .duck:
            let bob = reduceMotion ? 0 : sin(time * 2) * 0.4
            let duck = p.yellow.mix(PreviewRGB(1, 0.85, 0.2), 0.5)
            c.fill(Path(ellipseIn: CGRect(x: x - 7, y: 86 + bob, width: 14, height: 8)), with: .color(duck.color()))
            c.fill(circle(CGPoint(x: x + 3, y: 83 + bob), 4), with: .color(duck.color()))
            c.fill(Path(ellipseIn: CGRect(x: x + 6, y: 83 + bob, width: 4, height: 2)), with: .color(PreviewRGB(1, 0.5, 0.15).color()))
            c.fill(circle(CGPoint(x: x + 4, y: 82 + bob), 0.7), with: .color(.black))
        case .teapot:
            let pot = CGRect(x: x - 8, y: 82, width: 13, height: 12)
            let glaze = p.cyan.mix(p.background, 0.2)
            c.stroke(Path(ellipseIn: CGRect(x: pot.minX - 4, y: pot.minY + 3, width: 6, height: 6)), with: .color(glaze.color()), lineWidth: 1.4)
            var spout = Path()
            spout.move(to: CGPoint(x: pot.maxX - 1, y: pot.midY + 2))
            spout.addQuadCurve(to: CGPoint(x: pot.maxX + 5, y: pot.minY + 2), control: CGPoint(x: pot.maxX + 4, y: pot.midY + 2))
            c.stroke(spout, with: .color(glaze.color()), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            c.fill(Path(ellipseIn: pot), with: .linearGradient(Gradient(colors: [glaze.mix(.white, 0.2).color(), glaze.mix(.black, 0.2).color()]),
                                                              startPoint: CGPoint(x: pot.minX, y: 0), endPoint: CGPoint(x: pot.maxX, y: 0)))
            c.fill(circle(CGPoint(x: pot.midX, y: pot.minY), 1.4), with: .color(glaze.mix(.black, 0.2).color()))
            c.fill(Path(roundedRect: CGRect(x: x + 7, y: 89, width: 6, height: 5), cornerRadius: 1.5), with: .color(PreviewRGB(0.95, 0.94, 0.9).color()))
            steam(&c, from: CGPoint(x: pot.maxX + 5, y: pot.minY))
        case .fruit:
            c.fill(Path(ellipseIn: CGRect(x: x - 11, y: 88, width: 22, height: 7)), with: .color(p.foreground.mix(p.background, 0.4).color()))
            for (index, fruit) in [(-5.0, 87.0, p.red), (2.0, 86.0, p.green), (6.0, 88.5, p.yellow), (-1.0, 83.0, p.magenta)].enumerated() {
                c.fill(circle(CGPoint(x: x + fruit.0, y: fruit.1), index == 3 ? 3 : 3.6), with: .color(fruit.2.mix(.black, 0.05).color()))
                c.fill(circle(CGPoint(x: x + fruit.0 - 1, y: fruit.1 - 1.2), 0.9), with: .color(.white.opacity(0.45)))
            }
        case .books:
            for (index, color) in [p.blue, p.red, p.yellow].enumerated() {
                let width = 20 - Double(index) * 3
                c.fill(Path(roundedRect: CGRect(x: x - width / 2 + Double(index), y: base.y - 3.5 * Double(index + 1), width: width, height: 3.3), cornerRadius: 0.6),
                       with: .color(color.mix(p.background, 0.15).color()))
            }
        case .keycap:
            // An oversized esc key, the one every vim user wears out.
            var base = Path()
            base.move(to: CGPoint(x: x - 10, y: 94))
            base.addLine(to: CGPoint(x: x + 10, y: 94))
            base.addLine(to: CGPoint(x: x + 8, y: 82))
            base.addLine(to: CGPoint(x: x - 8, y: 82))
            base.closeSubpath()
            let plastic = p.isLight ? PreviewRGB(0.32, 0.33, 0.37) : PreviewRGB(0.9, 0.9, 0.88)
            c.fill(base, with: .color(plastic.mix(.black, 0.25).color()))
            let top = CGRect(x: x - 7, y: 80, width: 14, height: 10)
            c.fill(Path(roundedRect: top, cornerRadius: 2.2), with: .linearGradient(
                Gradient(colors: [plastic.mix(.white, 0.15).color(), plastic.color()]),
                startPoint: CGPoint(x: 0, y: top.minY), endPoint: CGPoint(x: 0, y: top.maxY)))
            label(&c, "esc", at: CGPoint(x: x, y: top.midY), size: 4.6, weight: .bold, color: p.red.mix(plastic, 0.1), design: .rounded)
        case .floppy:
            var layer = c
            layer.translateBy(x: x, y: 88)
            layer.rotate(by: .degrees(-8))
            let disk = CGRect(x: -8, y: -7, width: 16, height: 14)
            layer.fill(Path(roundedRect: disk, cornerRadius: 1), with: .color(p.blue.mix(.black, 0.35).color()))
            layer.fill(Path(CGRect(x: -4.5, y: -7, width: 9, height: 5)), with: .color(PreviewRGB(0.78, 0.8, 0.84).color()))
            layer.fill(Path(CGRect(x: 0.8, y: -6.2, width: 2, height: 3.4)), with: .color(p.blue.mix(.black, 0.35).color()))
            layer.fill(Path(roundedRect: CGRect(x: -6, y: -0.5, width: 12, height: 6.5), cornerRadius: 0.6), with: .color(PreviewRGB(0.97, 0.96, 0.92).color()))
            for line in 0..<2 {
                layer.fill(Path(CGRect(x: -4.5, y: 1.5 + Double(line) * 2, width: line == 0 ? 9 : 6, height: 0.5)), with: .color(p.red.color(0.7)))
            }
        case .alarmClock:
            drawAlarmClock(&c, base: CGPoint(x: x, y: base.y))
        }
    }

    /// A twin-bell alarm clock: a sweeping second hand, and a little rattle
    /// of the bells once a minute.
    private func drawAlarmClock(_ c: inout GraphicsContext, base: CGPoint) {
        let center = CGPoint(x: base.x, y: base.y - 10)
        let radius = 7.5
        let body = p.red.mix(p.background, 0.1)
        let ring = PreviewRGB(0.82, 0.84, 0.87)
        let rattle = reduceMotion ? 0 : (time.truncatingRemainder(dividingBy: 60) < 1.2 ? sin(time * 70) * 0.6 : 0)
        var clock = c
        clock.translateBy(x: rattle, y: 0)

        // Legs, then the bells and their hammer behind the case.
        for side in [-1.0, 1.0] {
            var leg = Path()
            leg.move(to: CGPoint(x: center.x + side * 4, y: center.y + 5.5))
            leg.addLine(to: CGPoint(x: center.x + side * 6, y: base.y))
            clock.stroke(leg, with: .color(ring.mix(.black, 0.3).color()), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            let bell = CGPoint(x: center.x + side * 5.2, y: center.y - 6.6)
            var dome = Path()
            dome.addArc(center: bell, radius: 3.4, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            dome.closeSubpath()
            var bellLayer = clock
            bellLayer.translateBy(x: bell.x, y: bell.y)
            bellLayer.rotate(by: .degrees(side * 28))
            bellLayer.translateBy(x: -bell.x, y: -bell.y)
            bellLayer.fill(dome, with: .linearGradient(Gradient(colors: [ring.mix(.white, 0.4).color(), ring.mix(.black, 0.2).color()]),
                                                       startPoint: CGPoint(x: bell.x - 3, y: bell.y - 3), endPoint: CGPoint(x: bell.x + 3, y: bell.y)))
        }
        clock.fill(Path(CGRect(x: center.x - 0.5, y: center.y - 10.5, width: 1, height: 3)), with: .color(ring.mix(.black, 0.3).color()))

        // Case and face.
        clock.fill(circle(center, radius), with: .linearGradient(Gradient(colors: [body.mix(.white, 0.2).color(), body.mix(.black, 0.25).color()]),
                                                                startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                                                                endPoint: CGPoint(x: center.x + radius, y: center.y + radius)))
        clock.fill(circle(center, radius - 1.5), with: .color(PreviewRGB(0.98, 0.97, 0.93).color()))
        for tick in 0..<12 where tick.isMultiple(of: 3) {
            let a = Double(tick) * .pi / 6
            clock.fill(circle(CGPoint(x: center.x + cos(a) * (radius - 3), y: center.y + sin(a) * (radius - 3)), 0.45),
                       with: .color(PreviewRGB(0.2, 0.2, 0.22).color()))
        }
        let seconds = reduceMotion ? 12 : time.truncatingRemainder(dividingBy: 60)
        let minutes = (time / 60).truncatingRemainder(dividingBy: 60)
        func hand(_ fraction: Double, _ length: Double, _ width: Double, _ color: PreviewRGB) {
            let a = fraction * 2 * .pi - .pi / 2
            var path = Path()
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(a) * length, y: center.y + sin(a) * length))
            clock.stroke(path, with: .color(color.color()), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        hand((7 + minutes / 60) / 12, 2.8, 1, PreviewRGB(0.15, 0.15, 0.17))
        hand(minutes / 60, 4.4, 0.8, PreviewRGB(0.15, 0.15, 0.17))
        hand(seconds / 60, 4.8, 0.4, p.red)
        clock.fill(circle(center, 0.7), with: .color(p.red.color()))
        // Glass glint.
        clock.fill(Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 5, width: 3.2, height: 2)), with: .color(.white.opacity(0.4)))
    }

    private func steam(_ c: inout GraphicsContext, from point: CGPoint) {
        guard !reduceMotion else { return }
        for index in 0..<2 {
            let rise = fract(time / 2.4 + Double(index) * 0.5)
            var wisp = Path()
            let x = point.x + Double(index) * 2 - 1
            wisp.move(to: CGPoint(x: x, y: point.y - rise * 4))
            wisp.addCurve(to: CGPoint(x: x + 1, y: point.y - 10 - rise * 4),
                          control1: CGPoint(x: x - 3, y: point.y - 4 - rise * 4), control2: CGPoint(x: x + 4, y: point.y - 7 - rise * 4))
            c.stroke(wisp, with: .color(p.foreground.color(0.35 * sin(rise * .pi))), lineWidth: 0.9)
        }
    }

    // MARK: Companions

    private func drawCompanion(_ c: inout GraphicsContext) {
        let x = 270.0, ground = 120.0
        let blink = !reduceMotion && fract(time / 3.7) < 0.04
        switch room.companion {
        case .none:
            return
        case .cat:
            let fur = (p.isLight ? p.foreground.mix(p.background, 0.15) : PreviewRGB(0.95, 0.65, 0.35).mix(p.yellow, 0.3))
            let wag = reduceMotion ? 0 : sin(time * 1.6) * 5
            var tail = Path()
            tail.move(to: CGPoint(x: x + 6, y: ground - 2))
            tail.addCurve(to: CGPoint(x: x + 14 + wag * 0.3, y: ground - 20), control1: CGPoint(x: x + 16, y: ground), control2: CGPoint(x: x + 12 + wag, y: ground - 10))
            c.stroke(tail, with: .color(fur.mix(.black, 0.1).color()), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            c.fill(Path(ellipseIn: CGRect(x: x - 8, y: ground - 17, width: 16, height: 18)), with: .linearGradient(
                Gradient(colors: [fur.color(), fur.mix(.black, 0.2).color()]), startPoint: CGPoint(x: x, y: ground - 17), endPoint: CGPoint(x: x, y: ground)))
            let head = CGPoint(x: x, y: ground - 22)
            for side in [-1.0, 1.0] {
                var ear = Path()
                ear.move(to: CGPoint(x: x + side * 2, y: head.y - 4))
                ear.addLine(to: CGPoint(x: x + side * 6.5, y: head.y - 9.5))
                ear.addLine(to: CGPoint(x: x + side * 7, y: head.y - 1))
                ear.closeSubpath()
                c.fill(ear, with: .color(fur.color()))
            }
            c.fill(Path(ellipseIn: CGRect(x: head.x - 7.5, y: head.y - 6, width: 15, height: 12)), with: .color(fur.color()))
            eyes(&c, head: head, spacing: 2.8, size: 1.3, color: p.green, blink: blink)
            c.fill(circle(CGPoint(x: head.x, y: head.y + 2.2), 0.7), with: .color(PreviewRGB(1, 0.6, 0.65).color()))
        case .owl:
            c.fill(Path(CGRect(x: x - 0.8, y: ground - 24, width: 1.6, height: 24)), with: .color(p.wood.mix(.black, 0.3).color()))
            c.fill(Path(roundedRect: CGRect(x: x - 10, y: ground - 26, width: 20, height: 2.4), cornerRadius: 1.2), with: .color(p.wood.color()))
            c.fill(Path(ellipseIn: CGRect(x: x - 6, y: ground - 1.5, width: 12, height: 3)), with: .color(p.wood.mix(.black, 0.4).color()))
            let feathers = PreviewRGB(0.55, 0.42, 0.3).mix(p.yellow, 0.2)
            let body = CGRect(x: x - 7, y: ground - 44, width: 14, height: 19)
            c.fill(Path(ellipseIn: body), with: .color(feathers.color()))
            c.fill(Path(ellipseIn: body.insetBy(dx: 3, dy: 5).offsetBy(dx: 0, dy: 3)), with: .color(feathers.mix(.white, 0.35).color()))
            for side in [-1.0, 1.0] {
                var tuft = Path()
                tuft.move(to: CGPoint(x: x + side * 3, y: body.minY + 2))
                tuft.addLine(to: CGPoint(x: x + side * 6, y: body.minY - 3))
                tuft.addLine(to: CGPoint(x: x + side * 6.5, y: body.minY + 4))
                tuft.closeSubpath()
                c.fill(tuft, with: .color(feathers.mix(.black, 0.15).color()))
                c.fill(circle(CGPoint(x: x + side * 3, y: body.minY + 6), 3), with: .color(PreviewRGB.white.color()))
            }
            eyes(&c, head: CGPoint(x: x, y: body.minY + 6), spacing: 3, size: 1.7, color: PreviewRGB(0.95, 0.65, 0.1), blink: blink)
            var beak = Path()
            beak.move(to: CGPoint(x: x - 1, y: body.minY + 9))
            beak.addLine(to: CGPoint(x: x + 1, y: body.minY + 9))
            beak.addLine(to: CGPoint(x: x, y: body.minY + 11.5))
            beak.closeSubpath()
            c.fill(beak, with: .color(PreviewRGB(0.9, 0.6, 0.2).color()))
        case .fishbowl:
            c.fill(Path(CGRect(x: x - 8, y: ground - 20, width: 16, height: 20)), with: .color(p.wood.mix(.black, 0.2).color()))
            let bowl = CGRect(x: x - 11, y: ground - 41, width: 22, height: 21)
            var water = c
            water.clip(to: Path(ellipseIn: bowl))
            water.fill(Path(CGRect(x: bowl.minX, y: bowl.minY + 5, width: bowl.width, height: bowl.height)), with: .color(p.cyan.mix(p.blue, 0.4).color(0.55)))
            let swim = reduceMotion ? 0 : sin(time * 0.9) * 5
            let facing: Double = reduceMotion ? 1 : (cos(time * 0.9) > 0 ? 1 : -1)
            let fish = CGPoint(x: x + swim, y: bowl.midY + 2)
            water.fill(Path(ellipseIn: CGRect(x: fish.x - 3.5, y: fish.y - 2, width: 7, height: 4)), with: .color(PreviewRGB(1, 0.55, 0.2).color()))
            var fin = Path()
            fin.move(to: CGPoint(x: fish.x - 3 * facing, y: fish.y))
            fin.addLine(to: CGPoint(x: fish.x - 6.5 * facing, y: fish.y - 2.5))
            fin.addLine(to: CGPoint(x: fish.x - 6.5 * facing, y: fish.y + 2.5))
            fin.closeSubpath()
            water.fill(fin, with: .color(PreviewRGB(1, 0.45, 0.15).color()))
            for index in 0..<3 where !reduceMotion {
                let rise = fract(time / 2 + Double(index) / 3)
                water.stroke(circle(CGPoint(x: x - 4 + Double(index) * 3, y: bowl.maxY - 4 - rise * 14), 0.8), with: .color(.white.opacity(0.7)), lineWidth: 0.5)
            }
            c.stroke(Path(ellipseIn: bowl), with: .color(.white.opacity(0.45)), lineWidth: 0.9)
            c.fill(Path(ellipseIn: CGRect(x: bowl.minX + 4, y: bowl.minY + 4, width: 4, height: 7)), with: .color(.white.opacity(0.25)))
        case .dog:
            drawGoldenRetriever(&c, x: x, ground: ground, blink: blink)
        case .fox:
            let coat = PreviewRGB(0.92, 0.48, 0.2).mix(p.red, 0.15)
            let wag = reduceMotion ? 0 : sin(time * 1.3) * 3
            var tail = Path()
            tail.move(to: CGPoint(x: x + 5, y: ground - 2))
            tail.addQuadCurve(to: CGPoint(x: x + 16 + wag, y: ground - 14), control: CGPoint(x: x + 20, y: ground))
            tail.addQuadCurve(to: CGPoint(x: x + 5, y: ground - 6), control: CGPoint(x: x + 12, y: ground - 6))
            tail.closeSubpath()
            c.fill(tail, with: .color(coat.color()))
            c.fill(circle(CGPoint(x: x + 16 + wag, y: ground - 14), 2.6), with: .color(PreviewRGB.white.color()))
            c.fill(Path(ellipseIn: CGRect(x: x - 7, y: ground - 16, width: 14, height: 17)), with: .color(coat.color()))
            c.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: ground - 13, width: 7, height: 11)), with: .color(PreviewRGB(0.98, 0.95, 0.9).color()))
            let head = CGPoint(x: x, y: ground - 21)
            for side in [-1.0, 1.0] {
                var ear = Path()
                ear.move(to: CGPoint(x: x + side * 1.5, y: head.y - 4))
                ear.addLine(to: CGPoint(x: x + side * 7, y: head.y - 11))
                ear.addLine(to: CGPoint(x: x + side * 7, y: head.y - 1))
                ear.closeSubpath()
                c.fill(ear, with: .color(coat.mix(.black, 0.1).color()))
            }
            var face = Path()
            face.move(to: CGPoint(x: head.x - 7.5, y: head.y - 3))
            face.addQuadCurve(to: CGPoint(x: head.x + 7.5, y: head.y - 3), control: CGPoint(x: head.x, y: head.y - 9))
            face.addLine(to: CGPoint(x: head.x, y: head.y + 6))
            face.closeSubpath()
            c.fill(face, with: .color(coat.color()))
            var cheeks = Path()
            cheeks.move(to: CGPoint(x: head.x - 7.5, y: head.y - 2))
            cheeks.addLine(to: CGPoint(x: head.x, y: head.y + 6))
            cheeks.addLine(to: CGPoint(x: head.x + 7.5, y: head.y - 2))
            cheeks.addQuadCurve(to: CGPoint(x: head.x - 7.5, y: head.y - 2), control: CGPoint(x: head.x, y: head.y + 1))
            c.fill(cheeks, with: .color(PreviewRGB(0.98, 0.95, 0.9).color()))
            c.fill(circle(CGPoint(x: head.x, y: head.y + 5), 1), with: .color(.black))
            eyes(&c, head: CGPoint(x: head.x, y: head.y - 2), spacing: 3, size: 1, color: PreviewRGB(0.15, 0.1, 0.05), blink: blink)
        }
    }

    /// A golden retriever sitting up: drop ears, feathered chest and tail,
    /// and a panting smile.
    private func drawGoldenRetriever(_ c: inout GraphicsContext, x: Double, ground: Double, blink: Bool) {
        // A size up from the other pets; retrievers are big dogs.
        var dog = c
        dog.translateBy(x: x, y: ground)
        dog.scaleBy(x: 1.15, y: 1.15)
        dog.translateBy(x: -x, y: -ground)
        let gold = PreviewRGB(0.88, 0.63, 0.3).mix(p.yellow, 0.08)
        let cream = PreviewRGB(0.97, 0.84, 0.58)
        let shade = PreviewRGB(0.72, 0.47, 0.2)
        let wag = reduceMotion ? 0 : sin(time * 7)

        // Plumed tail sweeping behind the haunch.
        var tail = Path()
        let tip = CGPoint(x: x + 17 + wag * 2.5, y: ground - 14 - wag * 2)
        tail.move(to: CGPoint(x: x + 7, y: ground - 3))
        tail.addQuadCurve(to: tip, control: CGPoint(x: x + 18, y: ground - 2))
        tail.addQuadCurve(to: CGPoint(x: x + 8, y: ground - 9), control: CGPoint(x: x + 11 + wag, y: ground - 13))
        tail.closeSubpath()
        dog.fill(tail, with: .linearGradient(Gradient(colors: [gold.color(), cream.color()]),
                                             startPoint: CGPoint(x: x + 7, y: ground), endPoint: tip))
        // Feathering strands off the underside of the plume.
        var strands = Path()
        for step in 1...3 {
            let t = Double(step) / 4
            let base = CGPoint(x: x + 8 + (tip.x - x - 8) * t, y: ground - 3 + (tip.y - ground + 3) * t)
            strands.move(to: base)
            strands.addLine(to: CGPoint(x: base.x + 2.4, y: base.y + 1.6))
        }
        dog.stroke(strands, with: .color(cream.color()), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Haunch, body, and the cream feathering down the chest.
        dog.fill(Path(ellipseIn: CGRect(x: x + 1, y: ground - 13, width: 13, height: 13)), with: .color(shade.mix(gold, 0.5).color()))
        let body = CGRect(x: x - 9, y: ground - 24, width: 18, height: 24)
        dog.fill(Path(ellipseIn: body), with: .linearGradient(Gradient(colors: [gold.color(), shade.mix(gold, 0.4).color()]),
                                                           startPoint: CGPoint(x: body.minX, y: 0), endPoint: CGPoint(x: body.maxX, y: 0)))
        var bib = Path()
        bib.move(to: CGPoint(x: x - 5, y: ground - 20))
        bib.addQuadCurve(to: CGPoint(x: x + 5, y: ground - 20), control: CGPoint(x: x, y: ground - 23))
        for step in 0..<4 {
            let fx = x + 5 - Double(step + 1) * 2.5
            bib.addQuadCurve(to: CGPoint(x: fx, y: ground - 8 - Double(step % 2)), control: CGPoint(x: fx + 1.6, y: ground - 5))
        }
        bib.closeSubpath()
        dog.fill(bib, with: .color(cream.color()))
        // Wavy fur down the chest.
        var fur = Path()
        for (index, fy) in [ground - 18, ground - 14.5, ground - 11].enumerated() {
            let fx = x - 2.5 + Double(index % 2)
            fur.move(to: CGPoint(x: fx, y: fy))
            fur.addQuadCurve(to: CGPoint(x: fx + 2.5, y: fy + 0.4), control: CGPoint(x: fx + 1.2, y: fy + 1.6))
        }
        dog.stroke(fur, with: .color(gold.mix(cream, 0.4).color()), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))

        // Front legs and paws.
        for lx in [x - 5.5, x + 1] {
            dog.fill(Path(roundedRect: CGRect(x: lx, y: ground - 11, width: 4.5, height: 11), cornerRadius: 2), with: .color(gold.color()))
            dog.fill(Path(ellipseIn: CGRect(x: lx - 0.6, y: ground - 2.6, width: 5.7, height: 3)), with: .color(cream.color()))
        }

        // Head, a touch tilted.
        var head = dog
        let center = CGPoint(x: x, y: ground - 29)
        head.translateBy(x: center.x, y: center.y)
        head.rotate(by: .degrees(reduceMotion ? -6 : -6 + sin(time * 0.8) * 3))
        head.fill(Path(ellipseIn: CGRect(x: -7.5, y: -7, width: 15, height: 13.5)), with: .color(gold.color()))
        for side in [-1.0, 1.0] {
            var ear = Path()
            // Long drop ears that hang past the jaw, with a wavy feathered edge.
            ear.move(to: CGPoint(x: side * 4.5, y: -6))
            ear.addQuadCurve(to: CGPoint(x: side * 10, y: 4), control: CGPoint(x: side * 11.5, y: -4))
            ear.addQuadCurve(to: CGPoint(x: side * 8.5, y: 9.5), control: CGPoint(x: side * 11, y: 8))
            ear.addQuadCurve(to: CGPoint(x: side * 6.5, y: 8.5), control: CGPoint(x: side * 7.6, y: 10.5))
            ear.addQuadCurve(to: CGPoint(x: side * 5, y: 2), control: CGPoint(x: side * 5.2, y: 6))
            ear.closeSubpath()
            head.fill(ear, with: .linearGradient(Gradient(colors: [shade.color(), shade.mix(gold, 0.5).color()]),
                                                 startPoint: CGPoint(x: 0, y: -6), endPoint: CGPoint(x: 0, y: 10)))
        }
        // The long retriever muzzle, a shade lighter than the head.
        head.fill(Path(roundedRect: CGRect(x: -4.2, y: -0.5, width: 8.4, height: 7.8), cornerRadius: 3.8), with: .color(cream.mix(gold, 0.25).color()))
        let pant = reduceMotion ? 0 : (sin(time * 9) + 1) * 0.4
        head.fill(Path(roundedRect: CGRect(x: -1.4, y: 4.6, width: 2.8, height: 3 + pant), cornerRadius: 1.4),
                  with: .color(PreviewRGB(0.95, 0.45, 0.5).color()))
        var smile = Path()
        smile.move(to: CGPoint(x: -2.6, y: 4))
        smile.addQuadCurve(to: CGPoint(x: 2.6, y: 4), control: CGPoint(x: 0, y: 5.8))
        head.stroke(smile, with: .color(PreviewRGB(0.3, 0.18, 0.1).color()), lineWidth: 0.6)
        head.fill(Path(ellipseIn: CGRect(x: -1.6, y: 1.4, width: 3.2, height: 2.2)), with: .color(PreviewRGB(0.12, 0.08, 0.06).color()))
        eyes(&head, head: CGPoint(x: 0, y: -1.8), spacing: 3, size: 1.1, color: PreviewRGB(0.25, 0.14, 0.06), blink: blink)
    }

    private func eyes(_ c: inout GraphicsContext, head: CGPoint, spacing: Double, size: Double, color: PreviewRGB, blink: Bool) {
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: head.x + side * spacing, y: head.y)
            if blink {
                c.fill(Path(CGRect(x: eye.x - size, y: eye.y - 0.3, width: size * 2, height: 0.6)), with: .color(.black.opacity(0.8)))
            } else {
                c.fill(circle(eye, size), with: .color(color.color()))
                c.fill(circle(eye, size * 0.5), with: .color(.black))
            }
        }
    }

    // MARK: Helpers

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    private func label(_ c: inout GraphicsContext, _ text: String, at point: CGPoint, size: Double, weight: Font.Weight,
                       color: PreviewRGB, design: Font.Design, anchor: UnitPoint = .center) {
        let resolved = c.resolve(Text(verbatim: text).font(.system(size: size, weight: weight, design: design)).foregroundColor(color.color()))
        c.draw(resolved, at: point, anchor: anchor)
    }
}
