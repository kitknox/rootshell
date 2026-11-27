//
//  WindowPreviewScene.swift
//  rootshell
//
//  Shared pieces of the illustrated previews in Settings → Window: the stage,
//  the terminal window drawn in the user's theme, and the scene host that
//  animates between setting states. The tab bar scene lives here too; the
//  other pages' scenes are in WindowSettingsScenes.swift.
//

import SwiftUI

// MARK: - Animated values

/// Any number of setting values for SwiftUI to interpolate, so each scene can
/// animate everything it shows without nesting `AnimatablePair`s.
nonisolated struct PreviewVector: VectorArithmetic, Sendable {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    subscript(_ index: Int) -> Double { index < values.count ? values[index] : 0 }

    static var zero: PreviewVector { PreviewVector([]) }

    private static func combine(_ a: PreviewVector, _ b: PreviewVector, _ op: (Double, Double) -> Double) -> PreviewVector {
        let count = max(a.values.count, b.values.count)
        return PreviewVector((0..<count).map { op(a[$0], b[$0]) })
    }

    static func + (a: PreviewVector, b: PreviewVector) -> PreviewVector { combine(a, b, +) }
    static func - (a: PreviewVector, b: PreviewVector) -> PreviewVector { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// Draws one scene from the kit and the current (possibly mid-animation) values.
typealias PreviewDraw = (inout GraphicsContext, PreviewKit, PreviewVector) -> Void

// MARK: - Scene host

/// The rounded card every Window page leads with.
struct PreviewSceneCard: View {
    let values: PreviewVector
    var height: CGFloat = 176
    let draw: PreviewDraw

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PreviewScene(values: values, draw: draw)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.9), value: values)
            .accessibilityHidden(true)
    }
}

/// SwiftUI interpolates `values`; the timeline adds the ambient life.
private struct PreviewScene: View, Animatable {
    var values: PreviewVector
    let draw: PreviewDraw

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment
    @State private var isVisible = false

    var animatableData: PreviewVector {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        let values = values
        let draw = draw
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        let reduceMotion = reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            // Reduce Motion: one representative still frame.
            let time = reduceMotion ? 3.4 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                guard size.width > 1, size.height > 1 else { return }
                draw(&context, PreviewKit(size: size, time: time, palette: palette, reduceMotion: reduceMotion), values)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

// MARK: - Palette

nonisolated struct PreviewRGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        r = Double((value >> 16) & 0xff) / 255
        g = Double((value >> 8) & 0xff) / 255
        b = Double(value & 0xff) / 255
    }

    init(_ resolved: Color.Resolved) {
        r = Double(max(0, min(1, resolved.red)))
        g = Double(max(0, min(1, resolved.green)))
        b = Double(max(0, min(1, resolved.blue)))
    }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var components: [Double] { [r, g, b] }

    func mix(_ other: PreviewRGB, _ t: Double) -> PreviewRGB {
        PreviewRGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    static let black = PreviewRGB(0, 0, 0)
    static let white = PreviewRGB(1, 1, 1)
}

/// The terminal theme for the window, and the row color and accent for the stage.
nonisolated struct WindowPreviewPalette: Equatable, Sendable {
    var background: PreviewRGB
    var foreground: PreviewRGB
    var dim: PreviewRGB
    var green: PreviewRGB
    var blue: PreviewRGB
    var yellow: PreviewRGB
    var magenta: PreviewRGB
    var red: PreviewRGB
    var cursor: PreviewRGB
    var surface: PreviewRGB
    var accent: PreviewRGB
    var isLight: Bool

    init(theme: ThemeManager.ThemeInfo.ThemeColors?, surface: Color.Resolved, accent: Color.Resolved) {
        func hex(_ value: String?, _ fallback: PreviewRGB) -> PreviewRGB {
            value.flatMap(PreviewRGB.init(hex:)) ?? fallback
        }
        func ansi(_ index: Int, _ fallback: PreviewRGB) -> PreviewRGB {
            guard let theme, index < theme.palette.count else { return fallback }
            return hex(theme.palette[index], fallback)
        }
        background = hex(theme?.background, PreviewRGB(0.12, 0.12, 0.18))
        foreground = hex(theme?.foreground, PreviewRGB(0.8, 0.84, 0.96))
        isLight = background.luminance > 0.5
        dim = foreground.mix(background, 0.5)
        green = ansi(2, PreviewRGB(0.65, 0.89, 0.63))
        blue = ansi(4, PreviewRGB(0.54, 0.71, 0.98))
        yellow = ansi(3, PreviewRGB(0.98, 0.89, 0.69))
        magenta = ansi(5, PreviewRGB(0.8, 0.65, 0.97))
        red = ansi(1, PreviewRGB(0.95, 0.55, 0.66))
        cursor = hex(theme?.cursor, foreground)
        self.surface = PreviewRGB(surface)
        self.accent = PreviewRGB(accent)
    }

    /// Window chrome: a step darker than the terminal (lighter on light themes).
    var chrome: PreviewRGB { isLight ? background.mix(.black, 0.06) : background.mix(.black, 0.32) }
    var stageIsLight: Bool { surface.luminance > 0.5 }
}

extension WindowPreviewPalette {
    /// The current terminal theme, on the row color and accent the screen uses.
    @MainActor
    static func current(sheetThemeColors: SheetThemeColors?, environment: EnvironmentValues) -> WindowPreviewPalette {
        let surface = (sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)).resolve(in: environment)
        let accent = (sheetThemeColors?.accentColor ?? Color.accentColor).resolve(in: environment)
        return WindowPreviewPalette(theme: ThemeManager.shared.currentThemeInfo?.colors, surface: surface, accent: accent)
    }
}

// MARK: - Kit

/// One colored run of terminal text, laid out in scene points.
nonisolated struct PreviewTextRun: Sendable {
    let color: PreviewRGB
    let rect: CGRect
}

/// Drawing helpers every scene shares, sized to a 360 × 176 pt design.
nonisolated struct PreviewKit {
    let size: CGSize
    let time: Double
    let palette: WindowPreviewPalette
    let reduceMotion: Bool

    var w: Double { size.width }
    var h: Double { size.height }
    var k: Double { min(w / 360, h / 176) }

    // MARK: Motion

    static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// 1 at the middle of a transition between 0 and 1.
    static func midFlight(_ value: Double) -> Double { 4 * value * (1 - value) }

    /// Where `time` sits in a repeating cycle: which repeat, and 0...1 through it.
    func cycle(_ period: Double, offset: Double = 0) -> (index: Double, phase: Double) {
        let t = (time + offset) / period
        return (floor(t), t - floor(t))
    }

    // MARK: Stage

    /// The row-colored stage: floor gradient, out-of-focus windows further
    /// back, an accent glow, and slow specks of light.
    func stage(_ context: inout GraphicsContext, lift: Double = 0) {
        let p = palette
        let light = p.stageIsLight
        let top = p.surface.mix(p.accent, light ? 0.05 : 0.08)
        let floor = light ? p.surface.mix(p.accent, 0.1).mix(.black, 0.05) : p.surface.mix(.black, 0.35)
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [top.color(), floor.color()]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        let drift = reduceMotion ? 0 : sin(time * 0.25)
        let ghosts: [(x: Double, y: Double, scale: Double, alpha: Double)] = [
            (0.1, 0.3, 0.3, 0.75), (0.9, 0.18, 0.26, 0.6),
        ]
        for (index, ghost) in ghosts.enumerated() {
            let gw = w * ghost.scale, gh = gw * 0.52
            let dx = (index == 0 ? -1.0 : 1.0) * (4 * k * lift + 3 * k * drift)
            let rect = CGRect(x: ghost.x * w - gw / 2 + dx, y: ghost.y * h + 2 * k * lift, width: gw, height: gh)
            let shape = Path(roundedRect: rect, cornerRadius: 6 * k, style: .continuous)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: (1.6 + 0.6 * Double(index)) * k))
                layer.fill(shape, with: .color(p.surface.mix(p.background, 0.55).color(ghost.alpha)))
                layer.clip(to: shape)
                layer.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.2)),
                           with: .color(p.chrome.color(ghost.alpha)))
                for line in 0..<3 {
                    let y = rect.minY + rect.height * (0.36 + 0.16 * Double(line))
                    let bar = CGRect(x: rect.minX + rect.width * 0.08, y: y, width: rect.width * [0.5, 0.34, 0.42][line], height: 2.4 * k)
                    layer.fill(Path(roundedRect: bar, cornerRadius: 1.2 * k), with: .color(p.dim.color(ghost.alpha * 0.8)))
                }
            }
        }

        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [p.accent.color(light ? 0.22 : 0.32), .clear]),
                                           center: CGPoint(x: w / 2, y: h * 0.42), startRadius: 0, endRadius: w * 0.5))

        guard !reduceMotion else { return }
        var seed: UInt64 = 0x5EED_CAFE
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<14 {
            let x0 = next(), y0 = next(), speed = 0.01 + next() * 0.02, phase = next() * 6, radius = 0.7 + next() * 0.8
            var y = (y0 - time * speed).truncatingRemainder(dividingBy: 1)
            if y < 0 { y += 1 }
            let point = CGPoint(x: (x0 + 0.02 * sin(time * 0.5 + phase)) * w, y: y * h)
            let alpha = (0.25 + 0.25 * sin(time * 1.3 + phase)) * (light ? 0.6 : 1)
            context.fill(circle(point, radius * k), with: .color(p.accent.mix(.white, 0.5).color(alpha)))
        }
    }

    // MARK: Window

    /// The main window's frame; it lifts toward the viewer mid-transition.
    func windowRect(lift: Double = 0, widthFraction: Double = 0.7, heightFraction: Double = 0.7) -> CGRect {
        let scale = 1 + 0.025 * lift
        let ww = w * widthFraction * scale, wh = h * heightFraction * scale
        return CGRect(x: (w - ww) / 2, y: h * 0.1 - 4 * k * lift, width: ww, height: wh)
    }

    /// Contact shadow, drop shadow, and the window body. Returns its shape.
    @discardableResult
    func windowShell(_ context: inout GraphicsContext, _ rect: CGRect, lift: Double = 0, radius: Double = 12,
                     fill: PreviewRGB? = nil, groundY: Double? = nil) -> Path {
        let p = palette
        let shape = Path(roundedRect: rect, cornerRadius: radius * k, style: .continuous)
        let ground = groundY ?? h * 0.92
        let spread = rect.width * (0.46 + 0.06 * lift)
        context.fill(Path(ellipseIn: CGRect(x: rect.midX - spread, y: ground - 5 * k, width: spread * 2, height: 10 * k)),
                     with: .radialGradient(Gradient(colors: [.black.opacity((p.stageIsLight ? 0.2 : 0.4) - 0.15 * lift), .clear]),
                                           center: CGPoint(x: rect.midX, y: ground), startRadius: 0, endRadius: spread))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity((p.stageIsLight ? 0.18 : 0.28) + 0.12 * lift),
                                    radius: (10 + 8 * lift) * k, x: 0, y: (5 + 5 * lift) * k))
            layer.fill(shape, with: .color((fill ?? p.background).color()))
        }
        return shape
    }

    func windowEdge(_ context: inout GraphicsContext, _ shape: Path) {
        context.stroke(shape, with: .color(.white.opacity(palette.isLight ? 0.5 : 0.12)), lineWidth: 0.75)
    }

    // MARK: Terminal

    /// Scrollback that fits `rect` after padding, ending in the prompt line.
    func terminalRuns(in rect: CGRect, padX: Double = 10, padY: Double = 12, lineHeight: Double = 10) -> [[PreviewTextRun]] {
        let p = palette
        let lines: [[(PreviewRGB, Double)]] = [
            [(p.green, 0.05), (p.foreground, 0.16), (p.dim, 0.22)],
            [(p.blue, 0.12), (p.foreground, 0.08), (p.blue, 0.1), (p.foreground, 0.14)],
            [(p.dim, 0.3), (p.yellow, 0.12)],
            [(p.green, 0.05), (p.foreground, 0.1), (p.magenta, 0.18)],
            [(p.foreground, 0.2), (p.dim, 0.1), (p.foreground, 0.16), (p.dim, 0.08)],
            [(p.yellow, 0.08), (p.foreground, 0.26)],
            [(p.dim, 0.18), (p.blue, 0.14), (p.dim, 0.1)],
            [(p.red, 0.07), (p.foreground, 0.2)],
            [(p.foreground, 0.12), (p.dim, 0.24)],
        ]
        let padX = padX * k, padY = padY * k, lineHeight = lineHeight * k, barHeight = 3.6 * k
        let reference = max(rect.width, 200 * k) - 20 * k
        let fit = max(0, Int((rect.height - padY * 2 + lineHeight - barHeight) / lineHeight))
        var y = rect.minY + padY
        var result: [[PreviewTextRun]] = []
        for line in lines.suffix(max(0, fit - 1)) {
            var x = rect.minX + padX
            var runs: [PreviewTextRun] = []
            for segment in line {
                let width = segment.1 * reference
                runs.append(PreviewTextRun(color: segment.0, rect: CGRect(x: x, y: y, width: width - 2 * k, height: barHeight)))
                x += width
            }
            result.append(runs)
            y += lineHeight
        }
        if fit > 0 {
            result.append([PreviewTextRun(color: p.green, rect: CGRect(x: rect.minX + padX, y: y, width: 0.05 * reference - 2 * k, height: barHeight))])
        }
        return result
    }

    /// Text runs, then a command typing at the prompt and a blinking cursor.
    func terminal(_ context: inout GraphicsContext, in rect: CGRect, padX: Double = 10, padY: Double = 12,
                  lineHeight: Double = 10, glow: Double = 0, typing: Bool = true) {
        let lines = terminalRuns(in: rect, padX: padX, padY: padY, lineHeight: lineHeight)
        drawRuns(&context, lines.flatMap { $0 }, glow: glow)
        guard let prompt = lines.last?.last else { return }
        let reference = max(rect.width, 200 * k) - 20 * k
        let x = prompt.rect.maxX + 2 * k
        let typed = typing ? min(1, time.truncatingRemainder(dividingBy: 5) / 2.6) : 1
        let commandWidth = 0.34 * reference * typed
        if commandWidth > 1 {
            drawRuns(&context, [PreviewTextRun(color: palette.foreground,
                                               rect: CGRect(x: x, y: prompt.rect.minY, width: commandWidth, height: prompt.rect.height))], glow: glow)
        }
        let blink: Double = reduceMotion || typed < 1 || sin(time * 5) > -0.2 ? 1 : 0
        context.fill(Path(CGRect(x: x + commandWidth + 1.5 * k, y: prompt.rect.minY - 1.6 * k, width: 3.4 * k, height: prompt.rect.height + 3.2 * k)),
                     with: .color(palette.cursor.color(0.9 * blink)))
    }

    /// Text runs as rounded bars; `glow` blooms them like HDR highlights.
    func drawRuns(_ context: inout GraphicsContext, _ runs: [PreviewTextRun], glow: Double = 0, opacity: Double = 0.85) {
        if glow > 0.01 {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: (2 + 3 * glow) * k))
                for run in runs {
                    layer.fill(Path(roundedRect: run.rect.insetBy(dx: -k, dy: -k), cornerRadius: run.rect.height),
                               with: .color(run.color.mix(.white, 0.3).color(0.9 * glow)))
                }
            }
        }
        for run in runs {
            context.fill(Path(roundedRect: run.rect, cornerRadius: run.rect.height / 2),
                         with: .color(run.color.mix(.white, 0.35 * glow).color(min(1, opacity + 0.15 * glow))))
        }
    }

    // MARK: Primitives

    func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func bar(_ context: inout GraphicsContext, x: Double, y: Double, width: Double, height: Double = 3.6, color: PreviewRGB, opacity: Double = 1) {
        let rect = CGRect(x: x, y: y - height * k / 2, width: max(0, width), height: height * k)
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(color.color(opacity)))
    }

    func symbol(_ context: inout GraphicsContext, _ name: String, in rect: CGRect, color: PreviewRGB, opacity: Double = 1) {
        var image = context.resolve(Image(systemName: name))
        image.shading = .color(color.color(opacity))
        context.draw(image, in: rect)
    }

    func label(_ context: inout GraphicsContext, _ text: String, at point: CGPoint, size: Double, weight: Font.Weight = .semibold,
               color: PreviewRGB, opacity: Double = 1, anchor: UnitPoint = .center) {
        let resolved = context.resolve(Text(text).font(.system(size: size * k, weight: weight, design: .rounded))
            .foregroundColor(color.color(opacity)))
        context.draw(resolved, at: point, anchor: anchor)
    }

    /// A Liquid Glass–like capsule: soft shadow, frosted fill, lit top edge.
    func glass(_ context: inout GraphicsContext, _ rect: CGRect, radius: Double? = nil, tint: PreviewRGB? = nil) {
        let p = palette
        let shape = Path(roundedRect: rect, cornerRadius: radius ?? rect.height / 2, style: .continuous)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(p.isLight ? 0.12 : 0.3), radius: 2 * k, y: 1 * k))
            layer.fill(shape, with: .color((tint ?? p.foreground).color(p.isLight ? 0.12 : 0.17)))
        }
        context.fill(shape, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0)]),
                                                  startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                  endPoint: CGPoint(x: rect.midX, y: rect.midY)))
        context.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.6 * k)
    }

    /// A pointer arrow with its tip at `tip`.
    func pointer(_ context: inout GraphicsContext, tip: CGPoint, opacity: Double = 1, pressed: Double = 0) {
        let s = 9 * k * (1 - 0.12 * pressed)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x, y: tip.y + s * 1.35))
        path.addLine(to: CGPoint(x: tip.x + s * 0.36, y: tip.y + s * 1.02))
        path.addLine(to: CGPoint(x: tip.x + s * 0.62, y: tip.y + s * 1.52))
        path.addLine(to: CGPoint(x: tip.x + s * 0.8, y: tip.y + s * 1.44))
        path.addLine(to: CGPoint(x: tip.x + s * 0.55, y: tip.y + s * 0.95))
        path.addLine(to: CGPoint(x: tip.x + s * 0.98, y: tip.y + s * 0.95))
        path.closeSubpath()
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35 * opacity), radius: 1.5 * k, y: 1 * k))
            layer.fill(path, with: .color(.black.opacity(opacity)))
        }
        context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: 0.9 * k)
    }

    /// A fingertip touch: a soft disc with a ring that pulses on press.
    func touch(_ context: inout GraphicsContext, at point: CGPoint, opacity: Double, pressed: Double = 0) {
        let radius = 7 * k * (1 - 0.15 * pressed)
        context.fill(circle(point, radius), with: .color(.white.opacity(0.28 * opacity)))
        context.stroke(circle(point, radius), with: .color(.white.opacity(0.7 * opacity)), lineWidth: 1 * k)
        if pressed > 0.01 {
            context.stroke(circle(point, radius * (1 + 0.9 * pressed)), with: .color(.white.opacity(0.4 * opacity * (1 - pressed))), lineWidth: 1 * k)
        }
    }
}

// MARK: - Tab bar scene

/// `TopTabLayout`, in the order the scene cross-fades through.
nonisolated enum PreviewTabStyle: Int, CaseIterable, Sendable {
    case pills, compactPills, integrated, ledger, trough

    @MainActor
    init(_ layout: TopTabLayout) {
        switch layout {
        case .pills: self = .pills
        case .compactPills: self = .compactPills
        case .integrated: self = .integrated
        case .ledger: self = .ledger
        case .trough: self = .trough
        }
    }
}

/// Everything the tab bar scene shows, packed for animation.
nonisolated struct TabBarSceneValues: Equatable, Sendable {
    var shown = 1.0
    var bottom = 0.0
    var layout = 0.0
    var shortcuts = 0.0
    var groupMenu = 0.0
    /// `TabScopeMenuSize` index, 0...3.
    var groupMenuSize = 0.0
    var programIcons = 1.0
    var animationsOff = 0.0
    var hoverPreviews = 0.0
    /// 1 while the scene is showing a pointer hovering a tab.
    var hoverMoment = 0.0
    var exposeCaptions = 1.0
    /// 1 while the scene is showing Tab Exposé.
    var exposeMoment = 0.0

    var vector: PreviewVector {
        PreviewVector([shown, bottom, layout, shortcuts, groupMenu, groupMenuSize, programIcons, animationsOff,
                       hoverPreviews, hoverMoment, exposeCaptions, exposeMoment])
    }

    init() {}

    init(_ v: PreviewVector) {
        shown = v[0]; bottom = v[1]; layout = v[2]; shortcuts = v[3]; groupMenu = v[4]; groupMenuSize = v[5]
        programIcons = v[6]; animationsOff = v[7]; hoverPreviews = v[8]; hoverMoment = v[9]
        exposeCaptions = v[10]; exposeMoment = v[11]
    }
}

nonisolated enum TabBarScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = TabBarSceneValues(vector)
        let lift = min(1, max(PreviewKit.midFlight(v.shown), PreviewKit.midFlight(v.bottom)))
        kit.stage(&context, lift: lift)

        let expose = PreviewKit.ease(v.exposeMoment)
        let home = kit.windowRect(lift: lift)
        // Exposé: the window shrinks into the middle of a row of its tabs.
        let thumb = CGRect(x: kit.w * 0.36, y: kit.h * 0.16, width: kit.w * 0.28, height: kit.h * 0.42)
        let win = CGRect(x: home.minX + (thumb.minX - home.minX) * expose,
                         y: home.minY + (thumb.minY - home.minY) * expose,
                         width: home.width + (thumb.width - home.width) * expose,
                         height: home.height + (thumb.height - home.height) * expose)

        if expose > 0.01 {
            for side in [-1.0, 1.0] {
                let rect = thumb.offsetBy(dx: side * (thumb.width + 12 * kit.k) * expose, dy: 0)
                context.drawLayer { layer in
                    layer.opacity = expose
                    let shape = kit.windowShell(&layer, rect, radius: 8, groundY: kit.h * 0.94)
                    layer.clip(to: shape)
                    kit.terminal(&layer, in: rect, padX: 6, padY: 7, lineHeight: 7, typing: false)
                }
            }
        }

        let shape = kit.windowShell(&context, win, lift: lift, radius: 12 - 4 * expose, groundY: kit.h * (0.92 + 0.02 * expose))
        let stripHeight = 27 * kit.k * (1 - expose)
        let topAmount = v.shown * (1 - v.bottom)
        let bottomAmount = v.shown * v.bottom
        let content = CGRect(x: win.minX, y: win.minY + topAmount * stripHeight,
                             width: win.width, height: win.height - (topAmount + bottomAmount) * stripHeight)
        context.drawLayer { layer in
            layer.clip(to: shape)
            kit.terminal(&layer, in: content, padX: 10 - 4 * expose, padY: 12 - 5 * expose, lineHeight: 10 - 3 * expose)
            if topAmount > 0.001 && stripHeight > 1 {
                let strip = CGRect(x: win.minX, y: win.minY - (1 - topAmount) * stripHeight, width: win.width, height: stripHeight)
                drawStrip(&layer, kit, v, strip: strip, terminalBelow: true, opacity: min(1, topAmount * 1.6))
            }
            if bottomAmount > 0.001 && stripHeight > 1 {
                let strip = CGRect(x: win.minX, y: win.maxY - bottomAmount * stripHeight, width: win.width, height: stripHeight)
                drawStrip(&layer, kit, v, strip: strip, terminalBelow: false, opacity: min(1, bottomAmount * 1.6))
            }
        }
        kit.windowEdge(&context, shape)

        if expose > 0.01 {
            drawExposeCaptions(&context, kit, v, thumb: thumb, expose: expose)
        }
        if v.hoverMoment > 0.01 && v.shown > 0.5 {
            drawHover(&context, kit, v, window: win)
        }
    }

    /// The selected tab as a continuous index, gliding to the next every few
    /// seconds, or jumping when tab animations are off.
    static func selection(_ kit: PreviewKit, animationsOff: Double) -> Double {
        let period = 2.8
        let (index, phase) = kit.cycle(period)
        let progress = min(1, phase * period / 0.55)
        let glide = 1 - pow(1 - progress, 3)
        let eased = glide + (1 - glide) * animationsOff
        let from = (index - 1).truncatingRemainder(dividingBy: 3)
        let to = index.truncatingRemainder(dividingBy: 3)
        return from + (to - from) * eased
    }

    private static func drawStrip(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabBarSceneValues,
                                  strip: CGRect, terminalBelow: Bool, opacity: Double) {
        let layouts = PreviewTabStyle.allCases
        let lower = max(0, min(layouts.count - 1, Int(floor(v.layout))))
        let upper = min(lower + 1, layouts.count - 1)
        let blend = v.layout - Double(lower)
        let painter = TabStripPainter(kit: kit, k: kit.k, selection: selection(kit, animationsOff: v.animationsOff),
                                      shortcuts: v.shortcuts, programIcons: v.programIcons,
                                      groupMenu: v.groupMenu, groupMenuSize: v.groupMenuSize)
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.fill(Path(strip), with: .color(kit.palette.chrome.color()))
            if blend < 0.999 {
                layer.drawLayer { styled in
                    styled.opacity = 1 - blend
                    painter.paint(&styled, layout: layouts[lower], strip: strip, terminalBelow: terminalBelow)
                }
            }
            if blend > 0.001 {
                layer.drawLayer { styled in
                    styled.opacity = blend
                    painter.paint(&styled, layout: layouts[upper], strip: strip, terminalBelow: terminalBelow)
                }
            }
        }
    }

    /// The pointer drifts onto a background tab; with hover previews on, a
    /// live preview of that tab pops out beneath it.
    private static func drawHover(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabBarSceneValues, window: CGRect) {
        let k = kit.k
        let moment = PreviewKit.ease(v.hoverMoment)
        let (_, phase) = kit.cycle(4)
        let arrive = PreviewKit.ease(phase / 0.3)
        let leave = PreviewKit.ease((phase - 0.85) / 0.15)
        let stripHeight = 27 * k
        let onBottom = v.bottom > 0.5
        let stripY = onBottom ? window.maxY - stripHeight / 2 : window.minY + stripHeight / 2
        let target = CGPoint(x: window.minX + window.width * 0.78, y: stripY)
        let start = CGPoint(x: window.midX, y: window.midY + 20 * k)
        let tip = CGPoint(x: start.x + (target.x - start.x) * arrive + 20 * k * leave,
                          y: start.y + (target.y - start.y) * arrive + 16 * k * leave * (onBottom ? -1 : 1))

        let show = v.hoverPreviews * moment * PreviewKit.ease((phase - 0.32) / 0.12) * (1 - leave)
        if show > 0.01 {
            let cardW = window.width * 0.46, cardH = cardW * 0.56
            let card = CGRect(x: target.x - cardW / 2 - 8 * k,
                              y: onBottom ? stripY - stripHeight / 2 - cardH - 6 * k : stripY + stripHeight / 2 + 6 * k,
                              width: cardW, height: cardH)
            let scale = 0.85 + 0.15 * show
            let scaled = CGRect(x: card.midX - card.width * scale / 2, y: card.midY - card.height * scale / 2,
                                width: card.width * scale, height: card.height * scale)
            context.drawLayer { layer in
                layer.opacity = show
                let shape = kit.windowShell(&layer, scaled, radius: 8, groundY: -100)
                layer.clip(to: shape)
                kit.terminal(&layer, in: scaled, padX: 6, padY: 7, lineHeight: 7, typing: false)
            }
            context.stroke(Path(roundedRect: scaled, cornerRadius: 8 * k, style: .continuous),
                           with: .color(kit.palette.accent.color(0.6 * show)), lineWidth: 1 * k)
        }
        kit.pointer(&context, tip: tip, opacity: moment)
    }

    /// Exposé captions: each tab's icon and title under its preview.
    private static func drawExposeCaptions(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabBarSceneValues,
                                           thumb: CGRect, expose: Double) {
        let k = kit.k, p = kit.palette
        let alpha = expose * v.exposeCaptions
        guard alpha > 0.01 else { return }
        let colors = [p.green, p.blue, p.magenta]
        for (index, side) in [-1.0, 0, 1.0].enumerated() {
            let rect = thumb.offsetBy(dx: side * (thumb.width + 12 * k) * expose, dy: 0)
            let y = rect.maxY + 10 * k
            let icon = CGRect(x: rect.midX - 22 * k, y: y - 4 * k, width: 8 * k, height: 8 * k)
            context.fill(Path(roundedRect: icon, cornerRadius: 2 * k), with: .color(colors[index].color(alpha)))
            kit.bar(&context, x: icon.maxX + 4 * k, y: y, width: [26.0, 32, 22][index] * k, color: p.foreground, opacity: 0.85 * alpha)
            if index == 2 {
                context.fill(kit.circle(CGPoint(x: rect.maxX - 6 * k, y: rect.minY + 6 * k), 3.5 * k), with: .color(p.accent.color(alpha)))
            }
        }
    }
}

// MARK: - Tab strip painter

/// One tab-strip style, shared by the scene and the style tiles so a tile is
/// exactly a piece of what the scene shows.
nonisolated struct TabStripPainter {
    let palette: WindowPreviewPalette
    let k: Double
    let selection: Double
    let time: Double
    var shortcuts = 0.0
    var programIcons = 1.0
    var groupMenu = 0.0
    var groupMenuSize = 0.0

    init(kit: PreviewKit, k: Double, selection: Double, shortcuts: Double = 0, programIcons: Double = 1,
         groupMenu: Double = 0, groupMenuSize: Double = 0) {
        palette = kit.palette
        self.k = k
        self.selection = selection
        time = kit.time
        self.shortcuts = shortcuts
        self.programIcons = programIcons
        self.groupMenu = groupMenu
        self.groupMenuSize = groupMenuSize
    }

    init(palette: WindowPreviewPalette, k: Double, selection: Double, time: Double) {
        self.palette = palette
        self.k = k
        self.selection = selection
        self.time = time
    }

    private static let titleWidths: [Double] = [0.5, 0.72, 0.42]
    private static let programSymbols = ["terminal.fill", "server.rack", "chart.bar.fill"]

    func paint(_ context: inout GraphicsContext, layout: PreviewTabStyle, strip: CGRect, terminalBelow: Bool) {
        let p = palette
        let plusWidth = 18 * k
        let lead = 6 * k
        // The group menu sits before the tabs and grows with its size setting.
        let menuWidth = (34 + 9 * groupMenuSize) * k * groupMenu
        if groupMenu > 0.01 {
            let menu = CGRect(x: strip.minX + lead, y: strip.midY - strip.height * 0.3, width: max(0, menuWidth - 4 * k), height: strip.height * 0.6)
            context.drawLayer { layer in
                layer.opacity = groupMenu
                layer.fill(Path(roundedRect: menu, cornerRadius: menu.height / 2), with: .color(p.accent.color(0.18)))
                layer.stroke(Path(roundedRect: menu, cornerRadius: menu.height / 2), with: .color(p.accent.color(0.45)), lineWidth: 0.6 * k)
                let glyph = CGRect(x: menu.minX + 5 * k, y: menu.midY - 3.5 * k, width: 8 * k, height: 7 * k)
                var image = layer.resolve(Image(systemName: "folder.fill"))
                image.shading = .color(p.accent.color())
                layer.draw(image, in: glyph)
                let title = CGRect(x: glyph.maxX + 3 * k, y: menu.midY - 1.7 * k, width: max(0, menu.maxX - glyph.maxX - 9 * k), height: 3.4 * k)
                layer.fill(Path(roundedRect: title, cornerRadius: 1.7 * k), with: .color(p.accent.color(0.85)))
            }
        }

        let area = CGRect(x: strip.minX + lead + menuWidth, y: strip.minY,
                          width: strip.width - lead * 2 - plusWidth - menuWidth, height: strip.height)
        let gap = layout == .pills ? 5 * k : 0
        let tabWidth = (area.width - gap * 2) / 3
        func tab(_ index: Double) -> CGRect {
            CGRect(x: area.minX + index * (tabWidth + gap), y: area.minY, width: tabWidth, height: area.height)
        }
        func centered(_ rect: CGRect, height: Double) -> CGRect {
            CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        let selected = tab(selection)
        let tabHeight = strip.height * (layout == .compactPills ? 0.62 : 0.74)

        switch layout {
        case .pills, .compactPills:
            for index in 0..<3 {
                let rect = centered(tab(Double(index)), height: tabHeight).insetBy(dx: layout == .compactPills ? 0.25 * k : 0, dy: 0)
                context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(p.foreground.color(p.isLight ? 0.06 : 0.07)))
            }
            glassKnob(&context, centered(selected, height: tabHeight))
        case .integrated:
            for index in 1..<3 {
                let x = tab(Double(index)).minX
                context.fill(Path(CGRect(x: x - 0.25 * k, y: strip.midY - strip.height * 0.22, width: 0.5 * k, height: strip.height * 0.44)),
                             with: .color(p.foreground.color(0.14)))
            }
            context.fill(integratedTab(selected, strip: strip, terminalBelow: terminalBelow), with: .color(p.background.color()))
        case .ledger:
            let keylineY = terminalBelow ? strip.maxY - 0.5 * k : strip.minY
            context.fill(Path(CGRect(x: strip.minX, y: keylineY, width: strip.width, height: 0.5 * k)), with: .color(p.foreground.color(0.16)))
            let barY = terminalBelow ? strip.maxY - 2 * k : strip.minY
            context.fill(Path(CGRect(x: selected.minX + 2 * k, y: barY, width: selected.width - 4 * k, height: 2 * k)), with: .color(p.accent.color()))
        case .trough:
            let well = centered(CGRect(x: area.minX, y: area.minY, width: tabWidth * 3, height: area.height), height: tabHeight)
            let wellShape = Path(roundedRect: well, cornerRadius: well.height / 2)
            context.fill(wellShape, with: .color(p.foreground.color(p.isLight ? 0.05 : 0.06)))
            context.stroke(wellShape, with: .color(p.foreground.color(0.14)), lineWidth: 0.5 * k)
            for index in 1..<3 {
                let x = tab(Double(index)).minX
                // Dividers drop out beside the knob, as in the app.
                let touchesKnob = abs(Double(index) - selection) < 0.75 || abs(Double(index) - (selection + 1)) < 0.75
                context.fill(Path(CGRect(x: x - 0.25 * k, y: well.midY - well.height * 0.25, width: 0.5 * k, height: well.height * 0.5)),
                             with: .color(p.foreground.color(touchesKnob ? 0 : 0.16)))
            }
            glassKnob(&context, centered(selected, height: tabHeight).insetBy(dx: 2 * k, dy: 2 * k))
        }

        let iconColors = [p.green, p.blue, p.magenta]
        for index in 0..<3 {
            let rect = tab(Double(index))
            let weight = max(0, 1 - abs(Double(index) - selection))
            let iconSize = 8 * k
            let x = rect.minX + (layout == .integrated ? 9 * k : 8 * k)
            let y = rect.midY + (layout == .integrated ? (terminalBelow ? 0.8 : -0.8) * k : 0)
            // Program icons: the running program's logo; off, a plain dot.
            let tile = CGRect(x: x, y: y - iconSize / 2, width: iconSize, height: iconSize)
            context.fill(Path(roundedRect: tile, cornerRadius: 1.8 * k),
                         with: .color(iconColors[index].color((0.55 + 0.45 * weight) * programIcons)))
            if programIcons > 0.01 {
                var image = context.resolve(Image(systemName: Self.programSymbols[index]))
                image.shading = .color(p.background.color(programIcons))
                context.draw(image, in: tile.insetBy(dx: 1.6 * k, dy: 1.6 * k))
            }
            let dotSize = 3.2 * k
            context.fill(Path(ellipseIn: CGRect(x: x + (iconSize - dotSize) / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)),
                         with: .color(p.dim.mix(p.foreground, weight).color(1 - programIcons)))

            let badgeWidth = 15 * k * shortcuts
            let titleWidth = max(0, (rect.width - 26 * k - badgeWidth) * Self.titleWidths[index])
            context.fill(Path(roundedRect: CGRect(x: x + iconSize + 4 * k, y: y - 1.9 * k, width: titleWidth, height: 3.8 * k), cornerRadius: 1.9 * k),
                         with: .color(p.dim.mix(p.foreground, weight).color(0.95)))
            if shortcuts > 0.01 {
                let badge = CGRect(x: rect.maxX - 18 * k, y: y - 4 * k, width: 13 * k, height: 8 * k)
                context.drawLayer { layer in
                    layer.opacity = shortcuts
                    layer.fill(Path(roundedRect: badge, cornerRadius: 2.5 * k), with: .color(p.foreground.color(0.1)))
                    let text = layer.resolve(Text("⌘\(index + 1)").font(.system(size: 5.6 * k, weight: .semibold, design: .rounded))
                        .foregroundColor(p.dim.mix(p.foreground, weight).color()))
                    layer.draw(text, at: CGPoint(x: badge.midX, y: badge.midY))
                }
            }
            // A background tab with new output.
            if index == 1 && weight < 0.5 && shortcuts < 0.5 {
                let pulse = 0.5 + 0.5 * sin(time * 3)
                context.fill(Path(ellipseIn: CGRect(x: rect.maxX - 9 * k, y: y - 1.6 * k, width: 3.2 * k, height: 3.2 * k)),
                             with: .color(p.accent.color((0.4 + 0.6 * pulse) * (1 - shortcuts))))
            }
        }

        let center = CGPoint(x: strip.maxX - lead - plusWidth / 2, y: strip.midY)
        var plus = Path()
        plus.move(to: CGPoint(x: center.x - 3.2 * k, y: center.y))
        plus.addLine(to: CGPoint(x: center.x + 3.2 * k, y: center.y))
        plus.move(to: CGPoint(x: center.x, y: center.y - 3.2 * k))
        plus.addLine(to: CGPoint(x: center.x, y: center.y + 3.2 * k))
        context.stroke(plus, with: .color(p.dim.color()), style: StrokeStyle(lineWidth: 1.1 * k, lineCap: .round))
    }

    private func glassKnob(_ context: inout GraphicsContext, _ rect: CGRect) {
        let p = palette
        let shape = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(p.isLight ? 0.12 : 0.3), radius: 2 * k, y: 1 * k))
            layer.fill(shape, with: .color(p.foreground.color(p.isLight ? 0.12 : 0.17)))
        }
        context.fill(shape, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0)]),
                                                  startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                  endPoint: CGPoint(x: rect.midX, y: rect.midY)))
        context.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.6 * k)
    }

    /// Rounded on the far side and flaring into the terminal with concave
    /// shoulders, so the selected tab and the terminal read as one surface.
    private func integratedTab(_ rect: CGRect, strip: CGRect, terminalBelow: Bool) -> Path {
        let shoulder = 5 * k, corner = 6 * k
        let direction: Double = terminalBelow ? 1 : -1
        let base = terminalBelow ? strip.maxY + 0.5 : strip.minY - 0.5
        let top = terminalBelow ? strip.minY + 3 * k : strip.maxY - 3 * k
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - shoulder, y: base))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: base - shoulder * direction), control: CGPoint(x: rect.minX, y: base))
        path.addLine(to: CGPoint(x: rect.minX, y: top + corner * direction))
        path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: top), control: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + corner * direction), control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: base - shoulder * direction))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + shoulder, y: base), control: CGPoint(x: rect.maxX, y: base))
        path.closeSubpath()
        return path
    }
}
