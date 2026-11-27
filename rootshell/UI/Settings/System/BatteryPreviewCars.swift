//
//  BatteryPreviewCars.swift
//  rootshell
//
//  Side-view vector cars for the Battery preview, painted in the theme's
//  ANSI colors. Drawn in design units: x from the tail, y down, ground at 0.
//

import SwiftUI

// MARK: - Spec

nonisolated struct BatteryCarSpec: Sendable {
    let length: Double
    let height: Double
    let wheels: [Double]
    let tire: Double
    let rim: Double
    let arch: Double
    let sill: Double
    let bobAmplitude: Double
    let bobFrequency: Double

    static func of(_ car: BatteryPreviewCar) -> BatteryCarSpec {
        switch car {
        case .sport:
            BatteryCarSpec(length: 203, height: 51, wheels: [42, 160], tire: 17, rim: 12.5, arch: 21, sill: -7,
                           bobAmplitude: 0.25, bobFrequency: 14)
        case .sedan:
            BatteryCarSpec(length: 190, height: 66, wheels: [40, 150], tire: 15.5, rim: 10, arch: 19, sill: -8,
                           bobAmplitude: 0.5, bobFrequency: 9)
        case .eco:
            BatteryCarSpec(length: 131, height: 80, wheels: [26, 104], tire: 12, rim: 7.5, arch: 15, sill: -8,
                           bobAmplitude: 0.9, bobFrequency: 6)
        }
    }
}

// MARK: - Painter

nonisolated struct BatteryCarPainter {
    let car: BatteryPreviewCar
    let kit: PreviewKit
    /// Design units to points.
    let unit: Double
    let adaptive: Double

    var spec: BatteryCarSpec { .of(car) }

    private var p: WindowPreviewPalette { kit.palette }

    var paint: PreviewRGB {
        switch car {
        case .sport: p.red
        case .sedan: p.blue
        case .eco: p.green
        }
    }

    /// Draws the car with its rear wheel's ground contact at `origin`.
    /// `bob` lifts the body only, in design units; `rolled` is the distance
    /// the wheels have turned through, in points.
    func draw(_ context: inout GraphicsContext, origin: CGPoint, bob: Double, rolled: Double, moving: Double) {
        var c = context
        c.translateBy(x: origin.x, y: origin.y)
        c.scaleBy(x: unit, y: unit)
        let spec = spec

        drawGroundShadow(&c, spec)
        drawBeam(&c)
        if car == .sport { drawFlame(&c, moving: moving) }

        var body = c
        body.translateBy(x: 0, y: -bob)
        drawArchLiners(&body, spec)
        let shell = bodyPath()
        drawPaint(&body, shell, spec)
        drawDetails(&body, shell)
        drawGlass(&body)
        drawLights(&body)
        drawBadge(&body, spec)

        for x in spec.wheels {
            drawWheel(&c, center: CGPoint(x: x, y: -spec.tire), spec: spec, rolled: rolled)
        }
    }

    // MARK: Shared finishes

    private func drawGroundShadow(_ c: inout GraphicsContext, _ spec: BatteryCarSpec) {
        let strength = p.isLight ? 0.3 : 0.5
        let center = CGPoint(x: spec.length / 2, y: 0)
        let reach = spec.length * 0.6
        c.fill(Path(ellipseIn: CGRect(x: center.x - reach, y: -4, width: reach * 2, height: 8)),
               with: .radialGradient(Gradient(colors: [.black.opacity(strength), .black.opacity(strength * 0.4), .clear]),
                                     center: center, startRadius: 0, endRadius: reach))
        for x in spec.wheels {
            c.fill(Path(ellipseIn: CGRect(x: x - spec.tire * 1.1, y: -1.6, width: spec.tire * 2.2, height: 3.2)),
                   with: .color(.black.opacity(strength)))
        }
    }

    private func drawArchLiners(_ c: inout GraphicsContext, _ spec: BatteryCarSpec) {
        var liner = c
        liner.clip(to: Path(CGRect(x: 0, y: -200, width: spec.length, height: 200 + spec.sill)))
        for x in spec.wheels {
            liner.fill(circle(CGPoint(x: x, y: -spec.tire), spec.arch - 0.4), with: .color(PreviewRGB(0.05, 0.05, 0.06).color()))
        }
    }

    /// Clearcoat: a lit top, the paint through the middle, a shadowed sill,
    /// a sharp shoulder reflection, and the road bouncing up underneath.
    private func drawPaint(_ c: inout GraphicsContext, _ shell: Path, _ spec: BatteryCarSpec) {
        let top = -spec.height
        c.fill(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: paint.mix(.white, 0.42).color(), location: 0),
                .init(color: paint.mix(.white, 0.12).color(), location: 0.3),
                .init(color: paint.color(), location: 0.55),
                .init(color: paint.mix(.black, 0.22).color(), location: 0.8),
                .init(color: paint.mix(.black, 0.45).color(), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: 0)))

        c.drawLayer { layer in
            layer.clip(to: shell)
            let shoulder = shoulderLine()
            layer.stroke(shoulder, with: .color(.white.opacity(0.14)), lineWidth: 4)
            layer.stroke(shoulder, with: .color(.white.opacity(0.4)), lineWidth: 1)
            layer.stroke(shoulder.offsetBy(dx: 0, dy: 2.2), with: .color(.black.opacity(0.16)), lineWidth: 1.2)
            // A soft sky reflection sweeping across the upper flank.
            layer.fill(Path(CGRect(x: 0, y: top, width: spec.length, height: spec.height)),
                       with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.12), .clear]),
                                             startPoint: CGPoint(x: spec.length * 0.25, y: top),
                                             endPoint: CGPoint(x: spec.length * 0.6, y: -spec.height * 0.3)))
        }
        c.stroke(shell, with: .color(paint.mix(.black, 0.55).color(0.75)), lineWidth: 0.7)
    }

    private func drawGlass(_ c: inout GraphicsContext) {
        let glass = glassPath()
        let base = p.background.mix(PreviewRGB(0.08, 0.1, 0.15), p.isLight ? 0.8 : 0.45)
        let box = glass.boundingRect
        c.fill(glass, with: .linearGradient(Gradient(colors: [base.mix(PreviewRGB(0.55, 0.65, 0.8), 0.32).color(), base.color()]),
                                            startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.minX, y: box.maxY)))
        c.drawLayer { layer in
            layer.clip(to: glass)
            for (offset, width, alpha) in [(0.18, 0.12, 0.22), (0.36, 0.05, 0.16)] {
                let x = box.minX + box.width * offset
                var streak = Path()
                streak.move(to: CGPoint(x: x, y: box.maxY))
                streak.addLine(to: CGPoint(x: x + box.height * 0.7, y: box.minY))
                streak.addLine(to: CGPoint(x: x + box.height * 0.7 + box.width * width, y: box.minY))
                streak.addLine(to: CGPoint(x: x + box.width * width, y: box.maxY))
                streak.closeSubpath()
                layer.fill(streak, with: .color(.white.opacity(alpha)))
            }
        }
        c.stroke(glass, with: .color(PreviewRGB(0.06, 0.06, 0.08).color(0.85)), lineWidth: 1.3)
        drawPillars(&c)
    }

    private func drawBadge(_ c: inout GraphicsContext, _ spec: BatteryCarSpec) {
        let center: CGPoint = switch car {
        case .sport: CGPoint(x: 118, y: -24)
        case .sedan: CGPoint(x: 112, y: -26)
        case .eco: CGPoint(x: 44, y: -28)
        }
        let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
        kit.symbol(&c, "bolt.fill", in: rect, color: p.yellow.mix(.white, 0.35), opacity: 0.95 * adaptive)
        if car == .eco {
            kit.symbol(&c, "leaf.fill", in: rect, color: .white, opacity: 0.85 * (1 - adaptive))
        }
    }

    private func drawBeam(_ c: inout GraphicsContext) {
        let lamp = headlightPoint
        var beam = Path()
        beam.move(to: lamp)
        beam.addLine(to: CGPoint(x: lamp.x + 80, y: lamp.y - 8))
        beam.addLine(to: CGPoint(x: lamp.x + 80, y: 0))
        beam.closeSubpath()
        let glow = p.yellow.mix(.white, 0.6)
        c.fill(beam, with: .linearGradient(Gradient(colors: [glow.color(p.stageIsLight ? 0.3 : 0.4), .clear]),
                                           startPoint: lamp, endPoint: CGPoint(x: lamp.x + 80, y: lamp.y)))
    }

    private func drawFlame(_ c: inout GraphicsContext, moving: Double) {
        guard moving > 0.01, !kit.reduceMotion else { return }
        let pipe = CGPoint(x: 4, y: -10)
        let flicker = 0.75 + 0.25 * sin(kit.time * 31) * sin(kit.time * 17)
        let length = 14 * flicker
        c.fill(Path(ellipseIn: CGRect(x: pipe.x - length, y: pipe.y - 2.6, width: length + 2, height: 5.2)),
               with: .linearGradient(Gradient(colors: [.clear, p.red.color(0.6 * moving), p.yellow.mix(.white, 0.5).color(moving)]),
                                     startPoint: CGPoint(x: pipe.x - length, y: pipe.y), endPoint: pipe))
    }

    private func glow(_ c: inout GraphicsContext, at point: CGPoint, color: PreviewRGB, radius: Double, alpha: Double) {
        c.fill(circle(point, radius), with: .radialGradient(Gradient(colors: [color.color(alpha), .clear]),
                                                            center: point, startRadius: 0, endRadius: radius))
    }

    // MARK: Wheels

    private func drawWheel(_ c: inout GraphicsContext, center: CGPoint, spec: BatteryCarSpec, rolled: Double) {
        let tire = spec.tire, rim = spec.rim
        c.fill(circle(center, tire), with: .radialGradient(
            Gradient(colors: [PreviewRGB(0.2, 0.2, 0.22).color(), PreviewRGB(0.11, 0.11, 0.12).color(), PreviewRGB(0.06, 0.06, 0.07).color()]),
            center: center, startRadius: rim, endRadius: tire))
        c.stroke(circle(center, tire - 0.8), with: .color(.white.opacity(0.07)), lineWidth: 0.8)

        let metal: PreviewRGB
        let face: PreviewRGB
        switch car {
        case .sport:
            metal = PreviewRGB(0.62, 0.64, 0.68); face = PreviewRGB(0.1, 0.1, 0.12)
        case .sedan:
            metal = PreviewRGB(0.84, 0.86, 0.89); face = PreviewRGB(0.16, 0.17, 0.19)
        case .eco:
            metal = PreviewRGB(0.95, 0.95, 0.94); face = PreviewRGB(0.78, 0.8, 0.82)
        }
        c.fill(circle(center, rim), with: .color(face.color()))

        // A caliper behind the sports car's open spokes; it doesn't turn.
        if car == .sport {
            var caliper = Path()
            let arc = stride(from: -150.0, through: -100.0, by: 5).map { $0 * .pi / 180 }
            caliper.addLines(arc.map { point(center, rim * 0.84, $0) } + arc.reversed().map { point(center, rim * 0.52, $0) })
            caliper.closeSubpath()
            c.fill(caliper, with: .color(p.yellow.color()))
        }

        let angle = rolled / max(tire * unit, 1)
        switch car {
        case .sport:
            var spokes = Path()
            for index in 0..<10 {
                let a = angle + Double(index) * .pi / 5
                spokes.move(to: point(center, rim * 0.24, a))
                spokes.addLine(to: point(center, rim * 0.96, a + 0.06))
            }
            c.stroke(spokes, with: .color(metal.color()), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case .sedan:
            for index in 0..<5 {
                let a = angle + Double(index) * 2 * .pi / 5
                var spoke = Path()
                spoke.move(to: point(center, rim * 0.25, a - 0.32))
                spoke.addLine(to: point(center, rim * 0.95, a - 0.2))
                spoke.addLine(to: point(center, rim * 0.95, a + 0.2))
                spoke.addLine(to: point(center, rim * 0.25, a + 0.32))
                spoke.closeSubpath()
                c.fill(spoke, with: .color(metal.color()))
            }
        case .eco:
            for index in 0..<4 {
                let a = angle + Double(index) * .pi / 2
                c.fill(circle(point(center, rim * 0.6, a), rim * 0.16), with: .color(PreviewRGB(0.6, 0.62, 0.65).color()))
            }
        }

        if car == .eco {
            c.fill(circle(center, rim * 0.92), with: .radialGradient(
                Gradient(colors: [metal.color(0), metal.mix(.black, 0.1).color(0.5)]),
                center: center, startRadius: rim * 0.4, endRadius: rim * 0.92))
        }
        c.stroke(circle(center, rim), with: .color(metal.mix(.white, 0.3).color()), lineWidth: car == .sport ? 1 : 1.3)
        c.fill(circle(center, rim * 0.2), with: .color(metal.mix(.black, 0.25).color()))
        c.fill(circle(center, rim * 0.08), with: .color(paint.color()))
    }

    // MARK: Per-car geometry

    var headlightPoint: CGPoint {
        switch car {
        case .sport: CGPoint(x: 192, y: -24)
        case .sedan: CGPoint(x: 186, y: -31)
        case .eco: CGPoint(x: 124, y: -31)
        }
    }

    private func bodyPath() -> Path {
        let spec = spec
        var path = Path()
        switch car {
        case .sport:
            path.move(to: pt(8, -7))
            path.addLine(to: pt(3, -13))
            path.addCurve(to: pt(2, -27), control1: pt(1, -17), control2: pt(1, -24))
            path.addLine(to: pt(6, -31))
            path.addCurve(to: pt(60, -38), control1: pt(24, -33), control2: pt(44, -35))
            path.addCurve(to: pt(104, -51), control1: pt(74, -44), control2: pt(88, -50))
            path.addCurve(to: pt(120, -49), control1: pt(112, -51.5), control2: pt(117, -50.5))
            path.addCurve(to: pt(148, -35), control1: pt(130, -44), control2: pt(140, -38))
            path.addCurve(to: pt(186, -27), control1: pt(162, -32), control2: pt(176, -30))
            path.addCurve(to: pt(200, -16), control1: pt(194, -25), control2: pt(199, -21))
            path.addLine(to: pt(199, -9))
            path.addLine(to: pt(203, -5.5))
            path.addLine(to: pt(182, -7))
        case .sedan:
            path.move(to: pt(8, -9))
            path.addCurve(to: pt(3, -30), control1: pt(2, -16), control2: pt(2, -26))
            path.addCurve(to: pt(34, -40), control1: pt(8, -36), control2: pt(20, -39))
            path.addCurve(to: pt(62, -62), control1: pt(44, -46), control2: pt(52, -58))
            path.addCurve(to: pt(118, -63), control1: pt(78, -66.5), control2: pt(102, -66.5))
            path.addCurve(to: pt(146, -43), control1: pt(128, -58), control2: pt(138, -48))
            path.addCurve(to: pt(182, -36), control1: pt(160, -40), control2: pt(174, -39))
            path.addCurve(to: pt(190, -22), control1: pt(188, -33), control2: pt(190, -28))
            path.addCurve(to: pt(186, -8), control1: pt(190, -14), control2: pt(189, -9))
        case .eco:
            path.move(to: pt(6, -9))
            path.addCurve(to: pt(3, -40), control1: pt(2, -18), control2: pt(1, -32))
            path.addCurve(to: pt(18, -72), control1: pt(5, -56), control2: pt(10, -66))
            path.addCurve(to: pt(74, -76), control1: pt(32, -80), control2: pt(56, -80))
            path.addCurve(to: pt(104, -46), control1: pt(90, -70), control2: pt(98, -56))
            path.addCurve(to: pt(126, -36), control1: pt(112, -40), control2: pt(120, -39))
            path.addCurve(to: pt(130, -16), control1: pt(130, -32), control2: pt(131, -22))
            path.addCurve(to: pt(126, -8), control1: pt(129, -11), control2: pt(128, -8))
        }
        for x in spec.wheels.reversed() {
            arch(&path, center: CGPoint(x: x, y: -spec.tire), radius: spec.arch, sill: spec.sill)
        }
        path.addLine(to: car == .sport ? pt(8, -7) : pt(car == .sedan ? 8 : 6, spec.sill))
        path.closeSubpath()
        return path
    }

    private func shoulderLine() -> Path {
        var path = Path()
        switch car {
        case .sport:
            path.move(to: pt(4, -28))
            path.addCurve(to: pt(196, -21), control1: pt(60, -36), control2: pt(150, -32))
        case .sedan:
            path.move(to: pt(3, -31))
            path.addCurve(to: pt(189, -31), control1: pt(60, -36), control2: pt(140, -36))
        case .eco:
            path.move(to: pt(3, -37))
            path.addCurve(to: pt(129, -30), control1: pt(40, -42), control2: pt(100, -38))
        }
        return path
    }

    private func glassPath() -> Path {
        var path = Path()
        switch car {
        case .sport:
            path.move(to: pt(72, -38))
            path.addCurve(to: pt(102, -48.5), control1: pt(84, -42.5), control2: pt(93, -48))
            path.addCurve(to: pt(117, -48), control1: pt(108, -49.5), control2: pt(113, -49.5))
            path.addCurve(to: pt(140, -37), control1: pt(126, -44), control2: pt(134, -40))
            path.addCurve(to: pt(72, -38), control1: pt(118, -36), control2: pt(90, -36.5))
        case .sedan:
            path.move(to: pt(42, -41.5))
            path.addCurve(to: pt(64, -59), control1: pt(50, -48), control2: pt(57, -56))
            path.addCurve(to: pt(115, -60), control1: pt(80, -61.5), control2: pt(102, -61.5))
            path.addCurve(to: pt(139, -43.5), control1: pt(125, -54), control2: pt(133, -47.5))
            path.addLine(to: pt(42, -41.5))
        case .eco:
            path.move(to: pt(10, -45))
            path.addCurve(to: pt(21, -68), control1: pt(11, -56), control2: pt(14, -65))
            path.addCurve(to: pt(72, -71), control1: pt(36, -74), control2: pt(58, -74))
            path.addCurve(to: pt(98, -47), control1: pt(84, -65), control2: pt(93, -55))
            path.addLine(to: pt(10, -45))
        }
        path.closeSubpath()
        return path
    }

    private func drawPillars(_ c: inout GraphicsContext) {
        let trim = PreviewRGB(0.07, 0.07, 0.09)
        switch car {
        case .sport:
            var pillar = Path()
            pillar.move(to: pt(90, -37)); pillar.addLine(to: pt(97, -47.5))
            pillar.addLine(to: pt(100.5, -48)); pillar.addLine(to: pt(94, -37))
            pillar.closeSubpath()
            c.fill(pillar, with: .color(paint.mix(.white, 0.15).color()))
        case .sedan:
            c.fill(Path(CGRect(x: 92, y: -61.5, width: 5, height: 20)), with: .color(trim.color()))
            var cPillar = Path()
            cPillar.move(to: pt(54, -42)); cPillar.addLine(to: pt(62, -58.5))
            cPillar.addLine(to: pt(67, -59.5)); cPillar.addLine(to: pt(60, -42))
            cPillar.closeSubpath()
            c.fill(cPillar, with: .color(paint.mix(.white, 0.1).color()))
            var belt = Path()
            belt.move(to: pt(42, -41.5)); belt.addLine(to: pt(139, -43.5))
            c.stroke(belt, with: .color(PreviewRGB(0.85, 0.87, 0.9).color(0.9)), lineWidth: 1)
        case .eco:
            c.fill(Path(CGRect(x: 56, y: -73, width: 5, height: 28)), with: .color(trim.color()))
        }
    }

    private func drawDetails(_ c: inout GraphicsContext, _ shell: Path) {
        let seam = Color.black.opacity(0.32)
        let dark = PreviewRGB(0.06, 0.06, 0.07)
        var inner = c
        inner.clip(to: shell)
        switch car {
        case .sport:
            // Side intake ahead of the rear wheel.
            var intake = Path()
            intake.move(to: pt(68, -27))
            intake.addCurve(to: pt(96, -31), control1: pt(77, -30), control2: pt(87, -31.5))
            intake.addLine(to: pt(92, -15))
            intake.addCurve(to: pt(72, -13), control1: pt(85, -14), control2: pt(78, -13))
            intake.closeSubpath()
            inner.fill(intake, with: .linearGradient(Gradient(colors: [dark.color(0.95), paint.mix(.black, 0.6).color()]),
                                                     startPoint: pt(80, -31), endPoint: pt(80, -13)))
            var lip = Path()
            lip.move(to: pt(68, -27)); lip.addCurve(to: pt(96, -31), control1: pt(77, -30), control2: pt(87, -31.5))
            inner.stroke(lip, with: .color(.white.opacity(0.3)), lineWidth: 0.7)
            for index in 0..<3 {
                let y = -26 + Double(index) * 4
                var fin = Path()
                fin.move(to: pt(76 + Double(index), y)); fin.addLine(to: pt(91 - Double(index) * 0.5, y - 1))
                inner.stroke(fin, with: .color(.white.opacity(0.12)), lineWidth: 0.6)
            }
            stroke(&inner, seam, (100, -36), (104, -12), c1: (98, -28), c2: (100, -16))
            // Engine-cover louvers.
            for index in 0..<4 {
                let x = 22 + Double(index) * 8
                stroke(&inner, Color.black.opacity(0.25), (x, -33.5 - Double(index) * 0.4), (x + 5, -34.5 - Double(index) * 0.4))
            }
            // Carbon skirt, splitter, and diffuser.
            inner.fill(Path(roundedRect: CGRect(x: 62, y: -11, width: 80, height: 4.5), cornerRadius: 1.5), with: .color(dark.color(0.85)))
            var splitter = Path()
            splitter.move(to: pt(178, -12)); splitter.addLine(to: pt(199, -11)); splitter.addLine(to: pt(203, -5.5)); splitter.addLine(to: pt(180, -7))
            splitter.closeSubpath()
            inner.fill(splitter, with: .color(dark.color(0.85)))
            inner.fill(Path(CGRect(x: 2, y: -14, width: 20, height: 7)), with: .color(dark.color(0.85)))
            for index in 0..<3 {
                stroke(&inner, Color.white.opacity(0.15), (6 + Double(index) * 5, -14), (6 + Double(index) * 5, -8))
            }
            // Wing.
            c.fill(Path(roundedRect: CGRect(x: 13.5, y: -41, width: 3, height: 10.5), cornerRadius: 0.8), with: .color(dark.color()))
            var wing = Path()
            wing.move(to: pt(0, -44.5))
            wing.addCurve(to: pt(31, -42.5), control1: pt(12, -46.5), control2: pt(24, -45.5))
            wing.addLine(to: pt(31, -40))
            wing.addCurve(to: pt(1, -41.5), control1: pt(20, -41.5), control2: pt(10, -41.5))
            wing.closeSubpath()
            c.fill(wing, with: .linearGradient(Gradient(colors: [PreviewRGB(0.3, 0.3, 0.33).color(), dark.color()]),
                                               startPoint: pt(0, -46), endPoint: pt(0, -40)))
            c.fill(Path(roundedRect: CGRect(x: -0.5, y: -47, width: 3, height: 8), cornerRadius: 0.8), with: .color(paint.mix(.black, 0.2).color()))
            mirror(&c, CGRect(x: 132, y: -44.5, width: 9, height: 4.5))
        case .sedan:
            stroke(&inner, seam, (96, -42), (97, -10))
            stroke(&inner, seam, (139.5, -43.5), (137, -10), c1: (140, -30), c2: (139, -18))
            stroke(&inner, seam, (58, -41.5), (59, -12), c1: (60, -30), c2: (61, -18))
            stroke(&inner, seam, (8, -37.5), (34, -40.5))
            for x in [79.0, 124.0] {
                inner.fill(Path(roundedRect: CGRect(x: x, y: -37.5, width: 8, height: 2), cornerRadius: 1),
                           with: .color(PreviewRGB(0.85, 0.87, 0.9).color(0.9)))
            }
            inner.fill(Path(CGRect(x: 168, y: -15, width: 24, height: 8)), with: .color(dark.color(0.7)))
            inner.fill(Path(CGRect(x: 0, y: -15, width: 24, height: 7)), with: .color(dark.color(0.7)))
            inner.fill(Path(roundedRect: CGRect(x: 60, y: -12, width: 72, height: 3.5), cornerRadius: 1.2), with: .color(dark.color(0.45)))
            mirror(&c, CGRect(x: 137, y: -47, width: 9, height: 5))
        case .eco:
            // White two-tone roof cap.
            var cap = Path()
            cap.move(to: pt(8, -60))
            cap.addCurve(to: pt(92, -60), control1: pt(30, -76), control2: pt(70, -76))
            cap.addLine(to: pt(92, -90)); cap.addLine(to: pt(8, -90))
            cap.closeSubpath()
            inner.clip(to: cap.subtracting(glassPath()))
            inner.fill(Path(CGRect(x: 0, y: -90, width: 131, height: 30)),
                       with: .linearGradient(Gradient(colors: [PreviewRGB(0.99, 0.99, 0.97).color(), PreviewRGB(0.85, 0.86, 0.86).color()]),
                                             startPoint: pt(0, -80), endPoint: pt(0, -66)))
            var body = c
            body.clip(to: shell)
            stroke(&body, seam, (63, -46), (64, -10), c1: (64.5, -30), c2: (64.5, -18))
            body.fill(Path(roundedRect: CGRect(x: 67, y: -41, width: 7, height: 2), cornerRadius: 1),
                      with: .color(PreviewRGB(0.85, 0.87, 0.9).color(0.9)))
            body.fill(Path(CGRect(x: 0, y: -15, width: 14, height: 7)), with: .color(dark.color(0.6)))
            body.fill(Path(CGRect(x: 117, y: -15, width: 14, height: 7)), with: .color(dark.color(0.6)))
            mirror(&c, CGRect(x: 97, y: -51, width: 7, height: 4.5))
        }
    }

    private func drawLights(_ c: inout GraphicsContext) {
        let lamp = p.yellow.mix(.white, 0.75)
        let red = p.red.mix(PreviewRGB(1, 0.1, 0.1), 0.35)
        switch car {
        case .sport:
            var head = Path()
            head.move(to: pt(176, -27.5))
            head.addCurve(to: pt(196, -22), control1: pt(184, -28.5), control2: pt(192, -26))
            head.addLine(to: pt(195, -20))
            head.addCurve(to: pt(178, -25), control1: pt(188, -22), control2: pt(182, -24))
            head.closeSubpath()
            c.fill(head, with: .color(lamp.color()))
            glow(&c, at: headlightPoint, color: lamp, radius: 9, alpha: 0.5)
            c.fill(Path(roundedRect: CGRect(x: 1.5, y: -28.5, width: 9, height: 3), cornerRadius: 1.2), with: .color(red.color()))
            glow(&c, at: CGPoint(x: 3, y: -27), color: red, radius: 7, alpha: 0.5)
        case .sedan:
            var head = Path()
            head.move(to: pt(175, -36.5))
            head.addCurve(to: pt(189.5, -32), control1: pt(181, -37.5), control2: pt(187, -35))
            head.addLine(to: pt(189.5, -28.5))
            head.addLine(to: pt(176, -31.5))
            head.closeSubpath()
            c.fill(head, with: .color(lamp.color()))
            glow(&c, at: headlightPoint, color: lamp, radius: 9, alpha: 0.45)
            c.fill(Path(roundedRect: CGRect(x: 2.5, y: -35, width: 9, height: 6), cornerRadius: 1.5), with: .color(red.color()))
            glow(&c, at: CGPoint(x: 4, y: -32), color: red, radius: 7, alpha: 0.45)
        case .eco:
            let center = CGPoint(x: 122, y: -31)
            c.fill(circle(center, 5.5), with: .color(PreviewRGB(0.85, 0.87, 0.9).color()))
            c.fill(circle(center, 4.2), with: .color(lamp.color()))
            glow(&c, at: center, color: lamp, radius: 10, alpha: 0.45)
            c.fill(Path(roundedRect: CGRect(x: 2, y: -41, width: 4.5, height: 11), cornerRadius: 2), with: .color(red.color()))
            glow(&c, at: CGPoint(x: 3, y: -35), color: red, radius: 7, alpha: 0.45)
        }
    }

    private func mirror(_ c: inout GraphicsContext, _ rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        c.fill(shape, with: .linearGradient(Gradient(colors: [paint.mix(.white, 0.3).color(), paint.mix(.black, 0.25).color()]),
                                            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        c.fill(Path(CGRect(x: rect.minX + 1, y: rect.maxY - 0.5, width: 2, height: 2.5)), with: .color(.black.opacity(0.6)))
    }

    // MARK: Helpers

    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func point(_ center: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func stroke(_ c: inout GraphicsContext, _ color: Color, _ a: (Double, Double), _ b: (Double, Double),
                        c1: (Double, Double)? = nil, c2: (Double, Double)? = nil) {
        var path = Path()
        path.move(to: pt(a.0, a.1))
        if let c1, let c2 {
            path.addCurve(to: pt(b.0, b.1), control1: pt(c1.0, c1.1), control2: pt(c2.0, c2.1))
        } else {
            path.addLine(to: pt(b.0, b.1))
        }
        c.stroke(path, with: .color(color), lineWidth: 0.7)
    }

    /// Wheel arch cut from front to rear, over the top of the wheel.
    private func arch(_ path: inout Path, center: CGPoint, radius: Double, sill: Double) {
        let dy = sill - center.y
        let dx = sqrt(max(0, radius * radius - dy * dy))
        let start = atan2(dy, dx)
        let end = atan2(dy, -dx) - 2 * .pi
        let steps = 20
        for index in 0...steps {
            let angle = start + (end - start) * Double(index) / Double(steps)
            path.addLine(to: point(center, radius, angle))
        }
    }
}
