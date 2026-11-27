//
//  SSHKeysHeaderView.swift
//  rootshell
//
//  Animated header for Settings → SSH Keys: a pufferfish swims back and forth,
//  trailing lines from the ciphers SSH uses that dissolve into bubbles.
//

import SwiftUI

struct SSHKeysHeaderView: View {
    let keyCount: Int
    /// Bumped by the owner (key added, refresh finished) to make the fish puff up.
    let puffTrigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var puffDate: Date?
    @State private var isVisible = false
    @State private var width: CGFloat = 0
    @State private var labelWidth: CGFloat = 0

    /// Grows with the row's width, stays slim where vertical space is scarce
    /// (landscape phone). Larger text can still push it taller.
    private var bannerHeight: CGFloat {
        if verticalSizeClass == .compact { return 72 }
        guard width > 0 else { return 92 }
        return min(max(width * 0.22, 84), 116)
    }

    /// Water tinted from the surface the banner sits on (the themed row color, or
    /// the system grouped row color) toward the accent, so it reads as part of
    /// the screen under any theme, light or dark.
    private var palette: CipherStreamPalette {
        let surface = sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)
        let accent = sheetThemeColors?.accentColor ?? Color.accentColor
        return CipherStreamPalette(
            surface: surface.resolve(in: environment),
            accent: accent.resolve(in: environment),
            isLight: colorScheme == .light
        )
    }

    var body: some View {
        let scale = min(max(bannerHeight / 100, 0.72), 1.16)
        let palette = palette
        label
            .frame(maxWidth: width > 0 ? max(width * 0.48, 150) : 200, alignment: .trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
            .padding(.vertical, 12)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: bannerHeight, alignment: .trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
                    let now = timeline.date
                    let time = reduceMotion ? 1.6 : now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                    let puffAge = puffDate.map { now.timeIntervalSince($0) } ?? .infinity
                    let labelWidth = labelWidth
                    Canvas { context, size in
                        CipherStreamRenderer(
                            size: size,
                            swimWidth: max(size.width - labelWidth - 28, size.width * 0.4),
                            time: time,
                            puffAge: puffAge,
                            reduceMotion: reduceMotion,
                            scale: scale,
                            palette: palette
                        ).draw(in: &context)
                    }
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { puff() }
        .onChange(of: puffTrigger) { _, _ in puff() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if keyCount == 0 {
                    Text("No keys yet", comment: "SSH keys header, empty state title")
                } else {
                    // Inflected so English agrees with no catalog work; translations
                    // carry their own plural variations under this key.
                    Text("^[\(keyCount) key](inflect: true)", comment: "SSH keys header: number of saved SSH keys")
                }
            }
            .font(.headline)
            .foregroundStyle(.primary)
            Text(keyCount == 0
                 ? String(localized: "Tap + to generate or import one", comment: "SSH keys header, empty state")
                 : String(localized: "Stored in the Keychain", comment: "SSH keys header subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.trailing)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        // Still scales, but stops before the banner outgrows a header; the key
        // rows below carry the same information at full size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func puff() {
        guard !reduceMotion else { return }
        puffDate = .now
    }
}

// MARK: - Palette

/// Everything in the scene except the fish takes its color from here. The fish
/// stays its own yellow on every theme; the water around it gets a little
/// deeper than the surface so the fish and trail keep their contrast.
private nonisolated struct CipherStreamPalette: Sendable {
    let waterTop: Color
    let waterBottom: Color
    let shaft: Color
    let glyph: Color
    let bubble: Color
    let bubbleGlint: Color

    init(surface: Color.Resolved, accent: Color.Resolved, isLight: Bool) {
        let surface = surface.opaque
        if isLight {
            waterTop = Color(surface.mixed(with: accent, 0.06))
            waterBottom = Color(surface.mixed(with: accent, 0.14).mixed(with: .black, 0.07))
            shaft = .white.opacity(0.18)
            glyph = Color(accent.mixed(with: .black, 0.45))
            bubble = Color(accent.mixed(with: .black, 0.35))
            bubbleGlint = .white
        } else {
            waterTop = Color(surface.mixed(with: accent, 0.14).mixed(with: .white, 0.015))
            waterBottom = Color(surface.mixed(with: .black, 0.4))
            shaft = .white.opacity(0.035)
            glyph = Color(accent.mixed(with: .white, 0.4))
            bubble = Color(accent.mixed(with: .white, 0.65))
            bubbleGlint = .white
        }
    }
}

nonisolated private extension Color.Resolved {
    static let black = Color.Resolved(red: 0, green: 0, blue: 0)
    static let white = Color.Resolved(red: 1, green: 1, blue: 1)

    var opaque: Color.Resolved { Color.Resolved(red: red, green: green, blue: blue) }

    func mixed(with other: Color.Resolved, _ amount: Float) -> Color.Resolved {
        Color.Resolved(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

// MARK: - Renderer

/// Pure function of time, so the trail needs no particle state: each glyph's
/// birth time and position are recomputed from the fish's path every frame.
private nonisolated struct CipherStreamRenderer {
    let size: CGSize
    let swimWidth: Double
    let time: Double
    let puffAge: Double
    let reduceMotion: Bool
    /// Fish and trail size relative to the 100 pt design.
    let scale: Double
    let palette: CipherStreamPalette

    private var w: Double { size.width }
    private var h: Double { size.height }

    /// Real lines from the algorithms SSH negotiates, each group under its
    /// OpenSSH name. ChaCha20's quarter round is written as in RFC 8439.
    private static let formulas: [[Character]] = [
        "// chacha20-poly1305",
        "a += b; d ^= a; d <<<= 16",
        "c += d; b ^= c; b <<<= 12",
        "a += b; d ^= a; d <<<= 8",
        "c += d; b ^= c; b <<<= 7",
        "acc = (acc+m)·r mod 2¹³⁰−5",
        "// aes256-gcm",
        "S(b) = A·b⁻¹ ⊕ 0x63",
        "Cᵢ = Pᵢ ⊕ AES(K, ctrᵢ)",
        "X = (X ⊕ Cᵢ)·H in GF(2¹²⁸)",
        "// curve25519-sha256",
        "y² = x³ + 486662x² + x",
        "p = 2²⁵⁵ − 19",
        "Σ₀ = a⋙2 ⊕ a⋙13 ⊕ a⋙22",
        "// ssh-ed25519",
        "−x² + y² = 1 + d·x²y²",
        "S = r + H(R,A,M)·a mod ℓ",
        "// rsa-sha2-512",
        "s = mᵈ mod n",
        "m = sᵉ mod n",
    ].map(Array.init)

    private static let longestFormula = formulas.map(\.count).max() ?? 1
    /// How long a finished line stays whole before it starts to dissolve.
    private static let readTime = 2.6
    private static let liftTime = 0.7
    private static let bubbleLife = 1.3

    func draw(in context: inout GraphicsContext) {
        guard w > 1, h > 1 else { return }
        drawWater(&context)
        drawTrail(&context)
        let pose = pose(at: time)
        let puff = puffAmount
        PufferfishModel(
            center: pose.center,
            yaw: pose.yaw,
            pitch: reduceMotion ? 0 : 0.12 * cos(time * 1.7) * cos(pose.yaw),
            radius: 16 * scale * (1 + 0.3 * puff),
            spikeLength: 16 * scale * (0.16 + 0.6 * puff),
            puff: puff,
            time: time,
            animate: !reduceMotion
        ).draw(in: &context)
    }

    // MARK: Motion

    private struct Pose {
        var center: CGPoint
        /// Rotation about the vertical axis: 0 faces right, pi faces left, and
        /// each turn swings the face toward the viewer at pi/2.
        var yaw: Double
        /// 0 while turning, 1 at full cruising speed.
        var speed: Double
    }

    private func pose(at t: Double) -> Pose {
        // Room for a fully puffed fish, spikes and tail, at either end.
        let margin = 48 * scale
        let phase = t / swimPeriod * 2 * .pi
        let x = margin + swimDistance * (0.5 - 0.5 * cos(phase))
        let y = h * 0.5 + sin(t * 1.7) * h * 0.07
        let heading = min(max(sin(phase) * 4, -1), 1)
        let yaw = (1 - sin(heading * .pi / 2)) / 2 * .pi
        return Pose(center: CGPoint(x: x, y: y), yaw: yaw, speed: abs(sin(phase)))
    }

    private var swimDistance: Double { max(swimWidth - 48 * scale * 2, 0) }

    // Same cruising speed on every width, instead of racing across a wide display.
    private var swimPeriod: Double { min(max(2 * swimDistance / (42 * scale), 8), 28) }

    private var puffAmount: Double {
        guard puffAge >= 0, puffAge < 1.8 else { return 0 }
        let inflate = smoothstep(0, 0.25, puffAge)
        let deflate = 1 - smoothstep(1.1, 1.8, puffAge)
        return inflate * deflate
    }

    // MARK: Water

    private func drawWater(_ context: inout GraphicsContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [palette.waterTop, palette.waterBottom]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
            )
        )
        // Light shafts from the surface.
        for index in 0..<3 {
            let base = w * (0.12 + 0.28 * Double(index)) + sin(time * 0.4 + Double(index)) * 12
            var shaft = Path()
            shaft.move(to: CGPoint(x: base, y: 0))
            shaft.addLine(to: CGPoint(x: base + 26, y: 0))
            shaft.addLine(to: CGPoint(x: base - 10, y: h))
            shaft.addLine(to: CGPoint(x: base - 36, y: h))
            shaft.closeSubpath()
            context.fill(shaft, with: .color(palette.shaft))
        }
        // Keeps the label legible when the trail drifts under it.
        let fadeStart = swimWidth - 10
        context.fill(
            Path(CGRect(x: fadeStart, y: 0, width: w - fadeStart, height: h)),
            with: .linearGradient(
                Gradient(colors: [palette.waterBottom.opacity(0), palette.waterBottom.opacity(0.85)]),
                startPoint: CGPoint(x: fadeStart, y: 0), endPoint: CGPoint(x: fadeStart + 50, y: 0)
            )
        )
    }

    // MARK: Trail

    /// On each rightward crossing the fish breathes out one line, a character as
    /// its mouth passes that spot. Each rises clear of the fish's path, stays
    /// whole long enough to read on the way back, then dissolves into bubbles
    /// in the order it was written, so it is gone before the next one begins.
    private func drawTrail(_ context: inout GraphicsContext) {
        let last = Int(floor(time / swimPeriod))
        let count = Self.formulas.count
        for pass in (reduceMotion ? last : last - 1)...last {
            drawLine(Self.formulas[(pass % count + count) % count], pass: pass, in: &context)
        }
    }

    private func drawLine(_ line: [Character], pass: Int, in context: inout GraphicsContext) {
        let inset = 6.0
        // One size for every line: as large as the longest fits in the open
        // water left of the label fade.
        let right = swimWidth - 20 - inset
        let fontSize = min(max((right - inset) / (Double(Self.longestFormula) * 0.6), 7), 11 * scale)
        // A fixed monospaced grid, so symbols that fall back to another font
        // still sit in their slot.
        let advance = fontSize * 0.6
        let width = Double(line.count) * advance
        let start = max(inset + (right - inset - width) / 2, inset)

        // Characters leave the mouth at a steady pace while the fish cruises, then
        // glide up into their slot, so the line assembles in reading order.
        let mouth = 16 * scale * 0.9
        let passStart = Double(pass) * swimPeriod
        func revealTime(_ index: Int) -> Double {
            passStart + swimPeriod / 2 * (0.1 + 0.8 * (Double(index) + 0.5) / Double(line.count))
        }
        let life = revealTime(line.count - 1) - revealTime(0) + Self.readTime

        // Just above the fish at the top of its bob, spikes included.
        let fishTop = h * 0.43 - 16 * scale * 1.16
        let lane = max(fishTop - fontSize * 0.6 - 1, fontSize * 0.6 + 2)
        let isComment = line.starts(with: ["/", "/"])
        let ink = isComment ? palette.glyph.opacity(0.6) : palette.glyph

        for (index, character) in line.enumerated() where character != " " {
            let revealed = revealTime(index)
            let age = reduceMotion ? Self.liftTime : time - revealed
            let pop = life + (hash(index, line.count) - 0.5) * 0.5
            guard age >= 0, age < pop + Self.bubbleLife else { continue }

            let lips = pose(at: revealed).center
            let glide = easeOut(age / Self.liftTime)
            let slot = start + (Double(index) + 0.5) * advance
            let x = lips.x + mouth + (slot - lips.x - mouth) * glide
            let y = lips.y + mouth * 0.15 + (lane - lips.y - mouth * 0.15) * glide + sin(time * 1.4 + Double(index) * 0.4) * 0.6 * scale
            let glyphAlpha = smoothstep(0, 0.15, age) * (1 - smoothstep(pop, pop + 0.25, age))
            if glyphAlpha > 0.01 {
                let text = Text(String(character))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(glyphAlpha))
                context.draw(text, at: CGPoint(x: x, y: y))
            }

            // About half the characters become bubbles, so a line doesn't fizz.
            let bubbleAge = age - pop
            guard bubbleAge > 0, hash(index * 7 + 3, line.count) < 0.55 else { continue }
            let bubbleAlpha = smoothstep(0, 0.2, bubbleAge) * (1 - smoothstep(Self.bubbleLife - 0.5, Self.bubbleLife, bubbleAge))
            let bx = x + sin(bubbleAge * 3 + Double(index)) * 1.5 * scale
            let by = y - bubbleAge * 14 * scale
            let radius = (1.4 + smoothstep(0, 1, bubbleAge) * 1.4) * scale
            let bubble = Path(ellipseIn: CGRect(x: bx - radius, y: by - radius, width: radius * 2, height: radius * 2))
            context.stroke(bubble, with: .color(palette.bubble.opacity(0.75 * bubbleAlpha)), lineWidth: 1)
            context.fill(
                Path(ellipseIn: CGRect(x: bx - radius * 0.45, y: by - radius * 0.55, width: radius * 0.5, height: radius * 0.5)),
                with: .color(palette.bubbleGlint.opacity(0.6 * bubbleAlpha))
            )
        }
    }

    /// Stable 0..<1 per character, so each one pops at the same moment every frame.
    private func hash(_ a: Int, _ b: Int) -> Double {
        let value = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return value - floor(value)
    }

    private func easeOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    // MARK: Helpers

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Pufferfish

private nonisolated struct Vec3 {
    var x: Double, y: Double, z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    static func * (v: Vec3, s: Double) -> Vec3 { Vec3(v.x * s, v.y * s, v.z * s) }

    var normalized: Vec3 {
        let length = max((x * x + y * y + z * z).squareRoot(), .ulpOfOne)
        return Vec3(x / length, y / length, z / length)
    }
}

/// Fish space: +x is the nose, +y is down, +z is the fish's left side. Parts
/// sit on or around a sphere, the fish yaws about its vertical axis, and each
/// part is projected and drawn back to front, so a turn reads as the fish
/// swinging round rather than a flat sprite flipping.
private nonisolated struct PufferfishModel {
    let center: CGPoint
    let yaw: Double
    /// Nose tilt in the screen plane, following the vertical bob.
    let pitch: Double
    let radius: Double
    let spikeLength: Double
    let puff: Double
    let time: Double
    let animate: Bool

    private static let body = Color(red: 0.96, green: 0.77, blue: 0.26)
    private static let highlight = Color(red: 1.0, green: 0.93, blue: 0.62)
    private static let rim = Color(red: 0.84, green: 0.57, blue: 0.12)
    private static let shade = Color(red: 0.79, green: 0.59, blue: 0.10)
    private static let backShade = Color(red: 0.62, green: 0.45, blue: 0.08)
    private static let fin = Color(red: 0.99, green: 0.84, blue: 0.4)
    private static let belly = Color(red: 0.99, green: 0.92, blue: 0.68)
    private static let ink = Color(red: 0.17, green: 0.16, blue: 0.16)

    /// Evenly spread over the sphere (Fibonacci lattice), skipping the face so
    /// spikes never sit on the eyes or mouth.
    private static let spikeDirections: [Vec3] = {
        let count = 46
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).compactMap { index in
            let y = 1 - (Double(index) + 0.5) / Double(count) * 2
            let ring = (1 - y * y).squareRoot()
            let theta = golden * Double(index)
            let direction = Vec3(cos(theta) * ring, y, sin(theta) * ring)
            let onFace = direction.x > 0.55 && direction.y < 0.45
            return onFace ? nil : direction
        }
    }()

    private enum Part {
        case spike(Vec3)
        case fin(side: Double)
        case tail
    }

    func draw(in context: inout GraphicsContext) {
        var parts: [(depth: Double, part: Part)] = Self.spikeDirections.map { (world($0).z, .spike($0)) }
        parts.append((world(Vec3(0, 0.1 * radius, 1.1 * radius)).z, .fin(side: 1)))
        parts.append((world(Vec3(0, 0.1 * radius, -1.1 * radius)).z, .fin(side: -1)))
        parts.append((world(Vec3(-1.1 * radius, 0, 0)).z, .tail))
        parts.sort { $0.depth < $1.depth }

        for entry in parts where entry.depth < 0 {
            drawPart(entry.part, front: false, in: &context)
        }
        drawBody(&context)
        for entry in parts where entry.depth >= 0 {
            drawPart(entry.part, front: true, in: &context)
        }
        drawFace(&context)
    }

    // MARK: Projection

    private func world(_ p: Vec3) -> Vec3 {
        let cy = cos(yaw), sy = sin(yaw)
        let x1 = p.x * cy - p.z * sy
        let z1 = p.x * sy + p.z * cy
        let cp = cos(pitch), sp = sin(pitch)
        return Vec3(x1 * cp - p.y * sp, x1 * sp + p.y * cp, z1)
    }

    /// Mild perspective so near parts read slightly larger than far ones.
    private func project(_ w: Vec3) -> CGPoint {
        let k = 1 / (1 - w.z / (radius * 8))
        return CGPoint(x: center.x + w.x * k, y: center.y + w.y * k)
    }

    private func point(_ p: Vec3) -> CGPoint { project(world(p)) }

    // MARK: Parts

    private func drawPart(_ part: Part, front: Bool, in context: inout GraphicsContext) {
        switch part {
        case .spike(let direction):
            drawSpike(direction, front: front, in: &context)
        case .fin(let side):
            drawFin(side: side, front: front, in: &context)
        case .tail:
            drawTail(front: front, in: &context)
        }
    }

    private func drawSpike(_ direction: Vec3, front: Bool, in context: inout GraphicsContext) {
        // Base sits just inside the surface so silhouette spikes have no gap.
        let base = point(direction * (radius * 0.94))
        let tip = point(direction * (radius + spikeLength))
        let dx = tip.x - base.x, dy = tip.y - base.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Spikes facing the viewer lie flat until the fish puffs, so the body reads
        // as textured rather than studded.
        let halfWidth = radius * (front ? 0.07 : 0.1)
        // A spike pointing at the viewer collapses to its base: a small dimple.
        let (px, py) = length > 0.5 ? (-dy / length, dx / length) : (1.0, 0.0)
        var path = Path()
        path.move(to: CGPoint(x: base.x + px * halfWidth, y: base.y + py * halfWidth))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x - px * halfWidth, y: base.y - py * halfWidth))
        path.closeSubpath()
        let facing = max(world(direction).z, 0)
        let opacity = front ? (0.35 + 0.65 * puff) * (1 - 0.5 * facing) + 0.15 : 1
        context.fill(path, with: .color((front ? Self.shade : Self.backShade).opacity(opacity)))
    }

    private func drawFin(side: Double, front: Bool, in context: inout GraphicsContext) {
        let r = radius
        let flap = animate ? sin(time * 8 + side) * 0.12 * r : 0
        var path = Path()
        // A small translucent fin just behind the eye, rooted on the side.
        path.move(to: point(Vec3(0.18 * r, 0.02 * r, side * 0.95 * r)))
        path.addLine(to: point(Vec3(-0.22 * r, -0.04 * r + flap, side * 1.22 * r)))
        path.addLine(to: point(Vec3(-0.16 * r, 0.24 * r + flap, side * 1.18 * r)))
        path.addLine(to: point(Vec3(0.14 * r, 0.22 * r, side * 0.95 * r)))
        path.closeSubpath()
        context.fill(path, with: .color(Self.fin.opacity(front ? 0.8 : 0.6)))
        context.stroke(path, with: .color(Self.shade.opacity(0.7)), lineWidth: 0.8)
    }

    private func drawTail(front: Bool, in context: inout GraphicsContext) {
        let r = radius
        // The tail sweeps side to side about its root: a real waggle in 3D.
        let sweep = animate ? sin(time * 9) * 0.35 : 0
        let pivot = -0.82 * r
        func tailPoint(_ dx: Double, _ y: Double) -> CGPoint {
            point(Vec3(pivot + dx * cos(sweep), y, dx * sin(sweep)))
        }
        var path = Path()
        path.move(to: tailPoint(0, -0.12 * r))
        path.addLine(to: tailPoint(-0.7 * r, -0.52 * r))
        path.addLine(to: tailPoint(-0.52 * r, 0))
        path.addLine(to: tailPoint(-0.7 * r, 0.52 * r))
        path.addLine(to: tailPoint(0, 0.12 * r))
        path.closeSubpath()
        context.fill(path, with: .color(front ? Self.shade : Self.backShade))
    }

    // MARK: Body

    private func drawBody(_ context: inout GraphicsContext) {
        let r = radius
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        // Lit from the upper left in screen space, so shading stays put while
        // the fish turns underneath it.
        let light = CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.42)
        context.fill(disc, with: .radialGradient(
            Gradient(colors: [Self.highlight, Self.body, Self.rim]),
            center: light, startRadius: 0, endRadius: r * 1.55
        ))

        var belly = context
        belly.clip(to: disc)
        let bellyCenter = point(Vec3(0.12 * r, 0.52 * r, 0))
        belly.fill(
            Path(ellipseIn: CGRect(x: bellyCenter.x - r * 0.68, y: bellyCenter.y - r * 0.36, width: r * 1.36, height: r * 0.8)),
            with: .color(Self.belly.opacity(0.92))
        )
        // Limb darkening sells the sphere.
        belly.fill(disc, with: .radialGradient(
            Gradient(colors: [.black.opacity(0), .black.opacity(0.18)]),
            center: center, startRadius: r * 0.7, endRadius: r
        ))
    }

    // MARK: Face

    private func drawFace(_ context: inout GraphicsContext) {
        let r = radius
        let blinking = animate && time.truncatingRemainder(dividingBy: 4.3) < 0.12
        for side in [1.0, -1.0] {
            let eye = Vec3(0.62, -0.36, side * 0.7).normalized
            if blinking {
                closedEye(eye, size: 0.26 * r, in: &context)
            } else {
                decal(eye, size: 0.26 * r, color: .white, in: &context)
                decal(Vec3(0.74, -0.33, side * 0.58).normalized, size: 0.12 * r, color: Self.ink, in: &context)
                decal(Vec3(0.7, -0.43, side * 0.56).normalized, size: 0.045 * r, color: .white, in: &context)
            }
        }

        let nose = world(Vec3(1, 0.14, 0).normalized)
        guard nose.z > -0.35 else { return }
        let mouth = project(nose * (r * 0.9))
        if puff > 0.3 {
            let o = 0.09 * r
            context.stroke(Path(ellipseIn: CGRect(x: mouth.x - o, y: mouth.y - o, width: o * 2, height: o * 2)),
                           with: .color(Self.ink), lineWidth: 1.3)
        } else {
            var smile = Path()
            smile.addArc(center: CGPoint(x: mouth.x, y: mouth.y - 0.06 * r), radius: 0.11 * r,
                         startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
            context.stroke(smile, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
    }

    /// A flat mark on the sphere, foreshortened by how far it faces away and
    /// hidden once it rounds the far side.
    private func decal(_ normal: Vec3, size: Double, color: Color, in context: inout GraphicsContext) {
        let n = world(normal)
        guard n.z > 0.02 else { return }
        let position = project(n * radius)
        var mark = context
        mark.translateBy(x: position.x, y: position.y)
        mark.rotate(by: .radians(atan2(n.y, n.x)))
        let along = size * n.z
        mark.fill(Path(ellipseIn: CGRect(x: -along, y: -size, width: along * 2, height: size * 2)),
                  with: .color(color.opacity(min(n.z / 0.25, 1))))
    }

    private func closedEye(_ normal: Vec3, size: Double, in context: inout GraphicsContext) {
        let n = world(normal)
        guard n.z > 0.02 else { return }
        let position = project(n * radius)
        var lid = Path()
        lid.move(to: CGPoint(x: position.x - size * max(n.z, 0.35), y: position.y))
        lid.addLine(to: CGPoint(x: position.x + size * max(n.z, 0.35), y: position.y))
        context.stroke(lid, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }
}
