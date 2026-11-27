//
//  AppearanceModePickerCard.swift
//  rootshell
//
//  Illustrated Light / Dark / Automatic picker for Settings → Appearance Mode.
//

import SwiftUI
import UIKit

private typealias AppearanceMode = AppearanceManager.AppearanceMode

// MARK: - Card

/// Animated day/night landscape above a segmented mode control and a caption.
struct AppearanceModePickerCard: View {
    @ObservedObject private var appearanceManager = AppearanceManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemIsDark = SystemAppearanceProbe.currentSceneIsDark()

    private var mode: AppearanceMode { appearanceManager.currentAppearanceMode }

    private var showsNight: Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .automatic: systemIsDark
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            AppearanceSceneView(night: showsNight ? 1 : 0, reduceMotion: reduceMotion)
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .animation(
                    reduceMotion ? .easeInOut(duration: 0.4) : .smooth(duration: 1.1),
                    value: showsNight
                )
                .background { SystemAppearanceProbe(isDark: $systemIsDark) }
                .accessibilityHidden(true)
                .settingContextMenu(Settings.Theme.appearanceMode)

            AppearanceModeSegmentedControl(selection: mode) { newMode in
                appearanceManager.currentAppearanceMode = newMode
            }

            // Every caption is laid out so the row height never changes between
            // modes; a resizing list row shifts the whole card mid-animation.
            ZStack {
                ForEach(AppearanceMode.allCases, id: \.self) { candidate in
                    Text(candidate.pickerCaption)
                        .opacity(candidate == mode ? 1 : 0)
                        .accessibilityHidden(candidate != mode)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: mode)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Segmented control

private struct AppearanceModeSegmentedControl: View {
    let selection: AppearanceMode
    let onSelect: (AppearanceMode) -> Void

    @Namespace private var pillNamespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var bounceCounts: [AppearanceMode: Int] = [:]

    private static let order: [AppearanceMode] = [.light, .dark, .automatic]

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))

        layout {
            ForEach(Self.order, id: \.self) { mode in
                segment(mode)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker("Appearance Mode", selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(Self.order, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ mode: AppearanceMode) -> some View {
        let isSelected = mode == selection
        let accent = mode.pickerAccent

        return Button {
            guard mode != selection else { return }
            bounceCounts[mode, default: 0] += 1
            withAnimation(.smooth(duration: 0.35)) { onSelect(mode) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.pickerSymbol)
                    .foregroundStyle(isSelected ? accent : Color.secondary)
                    .symbolEffect(.bounce, value: bounceCounts[mode, default: 0])
                Text(mode.displayName)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                        }
                        .shadow(color: accent.opacity(0.25), radius: 6)
                        .matchedGeometryEffect(id: "pill", in: pillNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension AppearanceMode {
    var pickerSymbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .automatic: "circle.lefthalf.filled"
        }
    }

    var pickerAccent: Color {
        switch self {
        case .light: Color(red: 0.96, green: 0.66, blue: 0.12)
        case .dark: Color(red: 0.42, green: 0.45, blue: 1.0)
        case .automatic: Color(red: 0.62, green: 0.42, blue: 0.95)
        }
    }

    var pickerCaption: String {
        switch self {
        case .light:
            String(localized: "Light appearance stays on, day and night.", comment: "Appearance mode picker caption")
        case .dark:
            String(localized: "Dark appearance stays on, day and night.", comment: "Appearance mode picker caption")
        case .automatic:
            String(localized: "Follows the system appearance as it switches between light and dark.", comment: "Appearance mode picker caption")
        }
    }
}

// MARK: - System appearance probe

/// Reports the window scene's interface style, which ignores the per-window
/// override the app applies and the themed sheet's forced color scheme.
private struct SystemAppearanceProbe: UIViewRepresentable {
    @Binding var isDark: Bool

    static func currentSceneIsDark() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .traitCollection.userInterfaceStyle == .dark
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        let binding = $isDark
        view.onChange = { dark in
            if binding.wrappedValue != dark { binding.wrappedValue = dark }
        }
    }

    final class ProbeView: UIView {
        var onChange: ((Bool) -> Void)?
        private weak var observedScene: UIWindowScene?
        private var registration: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            guard scene !== observedScene else { return }
            if let registration, let observedScene {
                observedScene.unregisterForTraitChanges(registration)
            }
            registration = nil
            observedScene = scene
            guard let scene else { return }
            registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                [weak self] (scene: UIWindowScene, _: UITraitCollection) in
                self?.report(scene)
            }
            report(scene)
        }

        private func report(_ scene: UIWindowScene) {
            let style = scene.traitCollection.userInterfaceStyle
            guard style != .unspecified else { return }
            // Deferred: didMoveToWindow can run inside a SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(style == .dark)
            }
        }
    }
}

// MARK: - Scene

/// Day/night landscape. `night` runs 0...1 and is interpolated by SwiftUI, so
/// a mid-flight mode change retargets smoothly from wherever the sky is.
private struct AppearanceSceneView: View, Animatable {
    var night: Double
    let reduceMotion: Bool

    @Environment(\.scenePhase) private var scenePhase

    var animatableData: Double {
        get { night }
        set { night = newValue }
    }

    var body: some View {
        let night = night
        let reduceMotion = reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                AppearanceSceneRenderer(size: size, night: night, time: time, reduceMotion: reduceMotion)
                    .draw(in: &context)
            }
        }
    }
}

private nonisolated struct RGB: Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

private nonisolated struct Hill: Sendable {
    let base: Double, amplitude: Double, frequency: Double, phase: Double
    let day: RGB, night: RGB

    func y(atX x: Double, size: CGSize) -> Double {
        let w = max(size.width, 1)
        return base * size.height + amplitude * size.height * sin(2 * .pi * frequency * x / w + phase)
    }
}

private nonisolated struct Star: Sendable {
    let x: Double, y: Double, radius: Double, phase: Double, speed: Double, sparkle: Bool
}

private nonisolated struct AppearanceSceneRenderer {
    let size: CGSize
    let night: Double
    let time: Double
    let reduceMotion: Bool

    private var w: Double { size.width }
    private var h: Double { size.height }
    private var day: Double { 1 - night }

    static let hills: [Hill] = [
        Hill(base: 0.68, amplitude: 0.06, frequency: 0.8, phase: 0.4,
             day: RGB(0.72, 0.87, 0.66), night: RGB(0.21, 0.28, 0.60)),
        Hill(base: 0.77, amplitude: 0.05, frequency: 1.1, phase: 2.2,
             day: RGB(0.55, 0.78, 0.52), night: RGB(0.16, 0.22, 0.51)),
        Hill(base: 0.89, amplitude: 0.04, frequency: 0.7, phase: 4.1,
             day: RGB(0.33, 0.64, 0.40), night: RGB(0.11, 0.16, 0.41)),
    ]

    static let stars: [Star] = {
        var seed: UInt64 = 0x5EED_CAFE
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<34).map { index in
            Star(x: next(), y: next() * 0.6, radius: 0.6 + next() * 0.9,
                 phase: next() * 2 * .pi, speed: 1.2 + next() * 2.2, sparkle: index % 9 == 0)
        }
    }()

    func draw(in context: inout GraphicsContext) {
        guard w > 1, h > 1 else { return }
        drawSky(&context)
        drawStars(&context)
        drawShootingStar(&context)
        drawMoon(&context)
        drawSun(&context)
        drawClouds(&context)
        drawHill(Self.hills[0], &context)
        drawHill(Self.hills[1], &context)
        drawHouse(&context)
        drawHill(Self.hills[2], &context)
        drawFireflies(&context)
    }

    // MARK: Sky

    private func drawSky(_ context: inout GraphicsContext) {
        let top = RGB(0.36, 0.68, 0.95).mix(RGB(0.04, 0.06, 0.21), night)
        let bottom = RGB(0.80, 0.92, 0.99).mix(RGB(0.16, 0.22, 0.52), night)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(Gradient(colors: [top.color(), bottom.color()]),
                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: h))
        )

        // Warm dusk wash that peaks halfway through the transition.
        let dusk = sin(night * .pi) * 0.55
        guard dusk > 0.01 else { return }
        let center = CGPoint(x: w * 0.82, y: h * 0.72)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [RGB(1.0, 0.55, 0.35).color(dusk), RGB(0.95, 0.45, 0.55).color(dusk * 0.4), .clear]),
                center: center, startRadius: 0, endRadius: max(w, h) * 0.75
            )
        )
    }

    private func starVisibility() -> Double {
        smoothstep(0.35, 1.0, night)
    }

    private func drawStars(_ context: inout GraphicsContext) {
        let visibility = starVisibility()
        guard visibility > 0.01 else { return }
        for star in Self.stars {
            let twinkle = reduceMotion ? 0.85 : 0.55 + 0.45 * sin(time * star.speed + star.phase)
            let alpha = visibility * twinkle
            let center = CGPoint(x: star.x * w, y: star.y * h)
            let radius = star.radius * (star.sparkle ? 1.3 : 1)
            context.fill(circle(center, radius), with: .color(.white.opacity(alpha)))
            if star.sparkle {
                var cross = Path()
                let arm = radius * 3.2 * (0.7 + 0.3 * twinkle)
                cross.move(to: CGPoint(x: center.x - arm, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - arm))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                context.stroke(cross, with: .color(.white.opacity(alpha * 0.6)), lineWidth: 0.7)
            }
        }
    }

    private func drawShootingStar(_ context: inout GraphicsContext) {
        guard !reduceMotion else { return }
        let visibility = starVisibility()
        guard visibility > 0.01 else { return }
        let period = 6.5, flight = 0.9
        let cycle = floor(time / period)
        let phase = time - cycle * period
        guard phase < flight else { return }

        let progress = phase / flight
        let jitterX = fract(sin(cycle * 12.9898) * 43758.5453)
        let jitterY = fract(sin(cycle * 78.233) * 12345.6789)
        let start = CGPoint(x: w * (0.05 + jitterX * 0.45), y: h * (0.04 + jitterY * 0.22))
        let direction = CGVector(dx: 0.94, dy: 0.34)
        let travel = w * 0.3
        let head = CGPoint(x: start.x + direction.dx * travel * progress,
                           y: start.y + direction.dy * travel * progress)
        let length = w * 0.12 * min(progress * 3, 1)
        let tail = CGPoint(x: head.x - direction.dx * length, y: head.y - direction.dy * length)
        let alpha = sin(progress * .pi) * visibility

        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        context.stroke(
            streak,
            with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(alpha)]),
                                  startPoint: tail, endPoint: head),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
    }

    // MARK: Sun and moon

    private var celestialRadius: Double { min(w * 0.065, h * 0.11) }

    private func drawSun(_ context: inout GraphicsContext) {
        let radius = celestialRadius
        let travel = reduceMotion ? 0 : night
        let center = CGPoint(x: w * (0.82 + 0.05 * travel), y: h * (0.27 + 0.75 * travel))
        let alpha = reduceMotion ? day : 1 - smoothstep(0.75, 1.0, night)
        guard alpha > 0.01 else { return }
        let core = RGB(1.0, 0.82, 0.16).mix(RGB(1.0, 0.52, 0.22), smoothstep(0.1, 0.7, night))

        context.fill(
            circle(center, radius * 2.4),
            with: .radialGradient(Gradient(colors: [core.color(0.38 * alpha), .clear]),
                                  center: center, startRadius: radius * 0.8, endRadius: radius * 2.4)
        )

        let rayCount = 12
        let spin = time * 0.25
        let pulse = 1 + 0.06 * sin(time * 2.1)
        var rays = Path()
        for index in 0..<rayCount {
            let angle = spin + Double(index) * 2 * .pi / Double(rayCount)
            let inner = radius * 1.38, outer = radius * (index.isMultiple(of: 2) ? 1.85 : 1.65) * pulse
            rays.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            rays.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        context.stroke(rays, with: .color(core.color(0.85 * alpha)),
                       style: StrokeStyle(lineWidth: max(1.5, radius * 0.12), lineCap: .round))
        context.fill(circle(center, radius), with: .color(core.color(alpha)))
    }

    private func drawMoon(_ context: inout GraphicsContext) {
        let radius = celestialRadius * 1.05
        let rise = reduceMotion ? 0 : 1 - night
        let bob = reduceMotion ? 0 : sin(time * 0.7) * 1.5
        let center = CGPoint(x: w * 0.8, y: h * 0.27 - rise * h * 0.7 + bob)
        let alpha = reduceMotion ? night : smoothstep(0.15, 0.6, night)
        guard alpha > 0.01 else { return }

        context.fill(
            circle(center, radius * 2.6),
            with: .radialGradient(Gradient(colors: [Color.white.opacity(0.22 * alpha), .clear]),
                                  center: center, startRadius: radius * 0.6, endRadius: radius * 2.6)
        )
        context.drawLayer { layer in
            layer.opacity = alpha
            layer.fill(circle(center, radius), with: .color(RGB(0.99, 0.97, 0.88).color()))
            layer.blendMode = .destinationOut
            layer.fill(circle(CGPoint(x: center.x + radius * 0.5, y: center.y - radius * 0.28), radius * 0.86),
                       with: .color(.black))
        }
    }

    // MARK: Clouds

    private func drawClouds(_ context: inout GraphicsContext) {
        let alpha = 1 - smoothstep(0.1, 0.6, night)
        guard alpha > 0.01 else { return }
        // Bands never overlap vertically, so clouds can't stack while drifting
        // at different speeds; the lowest stays small to clear the chimney.
        let clouds: [(x: Double, y: Double, scale: Double, speed: Double)] = [
            (0.12, 0.2, 1.0, 4.2), (0.55, 0.42, 1.1, 4.8), (0.88, 0.57, 0.7, 5.4),
        ]
        for cloud in clouds {
            let width = min(w * 0.16, h * 0.42) * cloud.scale
            let span = w + width * 2
            let drift = cloud.x * w + cloud.speed * time + width
            let x = drift.truncatingRemainder(dividingBy: span) - width
            let path = cloudPath(center: CGPoint(x: x, y: cloud.y * h), width: width)
            context.fill(path.offsetBy(dx: 0, dy: width * 0.05),
                         with: .color(RGB(0.70, 0.82, 0.94).color(0.45 * alpha)))
            context.fill(path, with: .color(.white.opacity(0.97 * alpha)))
        }
    }

    private func cloudPath(center: CGPoint, width: Double) -> Path {
        let u = width
        var path = Path()
        path.addRoundedRect(in: CGRect(x: center.x - u * 0.5, y: center.y - u * 0.02, width: u, height: u * 0.24),
                            cornerSize: CGSize(width: u * 0.12, height: u * 0.12))
        path.addPath(circle(CGPoint(x: center.x - u * 0.22, y: center.y + u * 0.02), u * 0.2))
        path.addPath(circle(CGPoint(x: center.x + 0.04 * u, y: center.y - u * 0.06), u * 0.27))
        path.addPath(circle(CGPoint(x: center.x + u * 0.28, y: center.y + u * 0.05), u * 0.17))
        return path
    }

    // MARK: Ground

    private func drawHill(_ hill: Hill, _ context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        let step = max(w / 60, 2)
        var x = 0.0
        while x <= w + step {
            path.addLine(to: CGPoint(x: x, y: hill.y(atX: x, size: size)))
            x += step
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()

        let color = hill.day.mix(hill.night, night)
        let crest = (hill.base - hill.amplitude) * h
        context.fill(path, with: .linearGradient(
            Gradient(colors: [color.mix(RGB(1, 1, 1), 0.12).color(), color.color()]),
            startPoint: CGPoint(x: 0, y: crest), endPoint: CGPoint(x: 0, y: h)
        ))
    }

    private func drawHouse(_ context: inout GraphicsContext) {
        let width = min(w * 0.07, h * 0.17)
        let x = w * 0.17
        let ground = Self.hills[1].y(atX: x, size: size) + width * 0.08
        let bodyHeight = width * 0.56
        let body = CGRect(x: x - width / 2, y: ground - bodyHeight, width: width, height: bodyHeight + width * 0.3)

        let glow = night * (reduceMotion ? 1 : 0.9 + 0.1 * sin(time * 3.3))
        if glow > 0.01 {
            let center = CGPoint(x: x, y: ground - bodyHeight * 0.5)
            context.fill(
                circle(center, width * 1.6),
                with: .radialGradient(Gradient(colors: [RGB(1.0, 0.8, 0.35).color(0.45 * glow), .clear]),
                                      center: center, startRadius: 0, endRadius: width * 1.6)
            )
        }

        drawSmoke(&context, chimney: CGPoint(x: x + width * 0.27, y: ground - bodyHeight - width * 0.42), width: width)

        let wall = RGB(0.47, 0.52, 0.60).mix(RGB(0.19, 0.21, 0.34), night)
        let roof = RGB(0.31, 0.34, 0.42).mix(RGB(0.10, 0.12, 0.23), night)
        context.fill(Path(CGRect(x: x + width * 0.18, y: ground - bodyHeight - width * 0.42,
                                 width: width * 0.14, height: width * 0.3)),
                     with: .color(roof.color()))
        context.fill(Path(roundedRect: body, cornerRadius: width * 0.04), with: .color(wall.color()))

        var roofPath = Path()
        roofPath.move(to: CGPoint(x: x - width * 0.64, y: ground - bodyHeight + width * 0.02))
        roofPath.addLine(to: CGPoint(x: x, y: ground - bodyHeight - width * 0.46))
        roofPath.addLine(to: CGPoint(x: x + width * 0.64, y: ground - bodyHeight + width * 0.02))
        roofPath.closeSubpath()
        context.fill(roofPath, with: .color(roof.color()))

        let window = RGB(0.82, 0.90, 0.97).mix(RGB(1.0, 0.83, 0.36), night)
        let pane = width * 0.19
        for offset in [-0.24, 0.24] {
            let rect = CGRect(x: x + width * offset - pane / 2, y: ground - bodyHeight * 0.72, width: pane, height: pane)
            context.fill(Path(roundedRect: rect, cornerRadius: pane * 0.15), with: .color(window.color()))
        }
    }

    private func drawSmoke(_ context: inout GraphicsContext, chimney: CGPoint, width: Double) {
        guard !reduceMotion else { return }
        let color = RGB(0.95, 0.96, 0.98).mix(RGB(0.6, 0.65, 0.85), night)
        for index in 0..<3 {
            let progress = fract(time / 3.6 + Double(index) / 3)
            let center = CGPoint(x: chimney.x + width * 0.08 + sin(progress * 5 + Double(index)) * width * 0.1,
                                 y: chimney.y - progress * width * 1.1)
            let alpha = sin(progress * .pi) * 0.55
            context.fill(circle(center, width * (0.06 + progress * 0.12)), with: .color(color.color(alpha)))
        }
    }

    private func drawFireflies(_ context: inout GraphicsContext) {
        guard !reduceMotion else { return }
        let visibility = smoothstep(0.6, 1.0, night)
        guard visibility > 0.01 else { return }
        for index in 0..<6 {
            let seed = Double(index) * 1.7
            let x = w * (0.3 + 0.12 * Double(index)) + sin(time * 0.45 + seed) * w * 0.04
            let y = h * 0.86 + cos(time * 0.6 + seed * 1.3) * h * 0.05
            let blink = max(0, sin(time * 1.4 + seed * 2.1))
            let alpha = visibility * blink
            guard alpha > 0.02 else { continue }
            let center = CGPoint(x: x, y: y)
            context.fill(circle(center, 5),
                         with: .radialGradient(Gradient(colors: [RGB(1.0, 0.92, 0.45).color(0.5 * alpha), .clear]),
                                               center: center, startRadius: 0, endRadius: 5))
            context.fill(circle(center, 1.2), with: .color(RGB(1.0, 0.95, 0.6).color(alpha)))
        }
    }

    // MARK: Helpers

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}
