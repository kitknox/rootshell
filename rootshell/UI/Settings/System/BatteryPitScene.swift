//
//  BatteryPitScene.swift
//  rootshell
//
//  The illustrated preview for Settings → Battery. Each refresh-rate cap is a
//  car on a track drawn in the user's theme; changing the cap pulls the car
//  into a pit garage, and the shutter rolls up on the next one.
//

import SwiftUI

// MARK: - Values

nonisolated enum BatteryPreviewCar: Int, CaseIterable, Sendable {
    case sport, sedan, eco
}

nonisolated struct BatterySceneValues: Equatable, Sendable {
    /// Sports car, sedan, microcar; one-hot at rest, blended mid-change.
    var cars: [Double] = [1, 0, 0]
    var adaptive = 0.0
    var plugged = 0.0
    /// The battery saver is holding redraws at 30 Hz whatever the car.
    var limited = 0.0
    /// The display's top rate, for the full-speed readout.
    var topRate = 120.0

    var vector: PreviewVector { PreviewVector(cars + [adaptive, plugged, limited, topRate]) }

    init(car: BatteryPreviewCar, adaptive: Bool, plugged: Bool, limited: Bool, topRate: Int) {
        cars = BatteryPreviewCar.allCases.map { $0 == car ? 1 : 0 }
        self.adaptive = adaptive ? 1 : 0
        self.plugged = plugged ? 1 : 0
        self.limited = limited ? 1 : 0
        self.topRate = Double(topRate)
    }

    init(_ v: PreviewVector) {
        cars = (0..<3).map { min(1, max(0, v[$0])) }
        adaptive = v[3]; plugged = v[4]; limited = v[5]; topRate = v[6]
    }

    /// 0 at rest, 1 through the middle of a change between cars.
    var pit: Double {
        let total = max(cars.reduce(0, +), 0.0001)
        let spread = 1 - cars.reduce(0) { $0 + ($1 / total) * ($1 / total) }
        return min(1, max(0, 2 * spread))
    }
}

/// Track distance summed frame by frame, so every scrolling layer stays
/// continuous while the speed eases between cars.
nonisolated final class BatteryOdometer {
    private var lastTime: Double?
    private var distance = 0.0

    func advance(time: Double, speed: Double) -> Double {
        // Skips the first frame, the timeline's hourly wrap, and long pauses.
        if let lastTime, time > lastTime, time - lastTime < 0.5 {
            distance += speed * (time - lastTime)
        }
        lastTime = time
        return distance
    }
}

// MARK: - Scene

nonisolated enum BatteryPitScene {
    /// Track speed in design points per second for each car.
    private static let speeds: [Double] = [300, 150, 60]
    /// Car design units per design point.
    private static let carScale = 0.82

    /// Parallax: how fast each layer scrolls relative to the road.
    private static let skylineDepth = 0.15
    private static let lampDepth = 0.5

    /// A draw function that keeps its distance in `odometer` between frames.
    static func drawer(odometer: BatteryOdometer) -> PreviewDraw {
        { context, kit, vector in draw(&context, kit, vector, odometer: odometer) }
    }

    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector, odometer: BatteryOdometer? = nil) {
        let v = BatterySceneValues(vector)
        let k = kit.k, w = kit.w, h = kit.h
        let pit = v.pit
        let roadTop = h * 0.68
        let ground = h * 0.85

        // The garage appears as the car stops, its shutter drops, the car is
        // swapped while it's shut, and it rolls back up on the new one.
        let appear = PreviewKit.ease(pit / 0.5)
        let shut = PreviewKit.ease((pit - 0.5) / 0.4)
        let moving = 1 - appear
        var speed = v.limited * speeds[2]
        for index in 0..<3 {
            speed += v.cars[index] * (1 - v.limited) * speeds[index]
        }
        speed *= moving
        // Without an odometer (a still), distance at a steady speed.
        let distance = (odometer?.advance(time: kit.time, speed: speed) ?? kit.time * speed) * k

        let garage = garageRect(kit, ground: ground)

        drawSky(&context, kit)
        drawSkyline(&context, kit, horizon: roadTop, offset: distance * skylineDepth)
        drawLamps(&context, kit, roadTop: roadTop, offset: distance * lampDepth)
        drawRoad(&context, kit, offset: distance, roadTop: roadTop, ground: ground, pit: appear)
        drawSpeedLimit(&context, kit, v: v, roadTop: roadTop)
        drawGarageBack(&context, kit, garage: garage, appear: appear)

        let leader = v.cars.indices.max { v.cars[$0] < v.cars[$1] } ?? 0
        let car = BatteryPreviewCar(rawValue: leader) ?? .sport
        let unit = carScale * k
        let painter = BatteryCarPainter(car: car, kit: kit, unit: unit, adaptive: v.adaptive)
        let spec = painter.spec
        let origin = CGPoint(x: w / 2 - spec.length * unit / 2, y: ground)
        let bob = kit.reduceMotion ? 0 : spec.bobAmplitude * sin(kit.time * spec.bobFrequency) * moving
        let top = ground - spec.height * unit

        drawTrail(&context, kit, v: v, rearX: origin.x, top: top, ground: ground, moving: moving)
        painter.draw(&context, origin: origin, bob: bob, rolled: distance * 0.3,
                     moving: v.cars[car.rawValue] * (1 - v.limited) * moving)
        drawGarageFront(&context, kit, garage: garage, ground: ground, appear: appear, shut: shut)
        drawReadout(&context, kit, v: v)
    }

    // MARK: Backdrop

    private static func stageText(_ kit: PreviewKit) -> PreviewRGB {
        kit.palette.stageIsLight ? PreviewRGB(0.12, 0.12, 0.14) : .white
    }

    private static func drawSky(_ context: inout GraphicsContext, _ kit: PreviewKit) {
        let p = kit.palette, light = p.stageIsLight
        let top = p.surface.mix(p.accent, light ? 0.06 : 0.1)
        let horizon = light ? p.surface.mix(p.accent, 0.16).mix(.white, 0.2) : p.surface.mix(p.accent, 0.22)
        context.fill(Path(CGRect(origin: .zero, size: kit.size)),
                     with: .linearGradient(Gradient(colors: [top.color(), horizon.color()]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: kit.h * 0.7)))
        context.fill(Path(CGRect(origin: .zero, size: kit.size)),
                     with: .radialGradient(Gradient(colors: [p.accent.color(light ? 0.2 : 0.3), .clear]),
                                           center: CGPoint(x: kit.w / 2, y: kit.h * 0.55), startRadius: 0, endRadius: kit.w * 0.45))
    }

    private static let skyline: [(x: Double, width: Double, height: Double, seed: UInt64)] = {
        var seed: UInt64 = 0xB47_7E21
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var result: [(x: Double, width: Double, height: Double, seed: UInt64)] = []
        var x = 0.0
        while x < 0.97 {
            let width = 0.035 + next() * 0.05
            result.append((x: x, width: width, height: 0.12 + next() * 0.26, seed: seed))
            x += width + next() * 0.014
        }
        return result
    }()

    /// Distant buildings, scrolling slower than the road. At night their
    /// windows switch on and off on their own timers and rooftop beacons
    /// blink; by day a sun glint sweeps across the glass.
    private static func drawSkyline(_ context: inout GraphicsContext, _ kit: PreviewKit, horizon: Double, offset: Double) {
        let p = kit.palette, k = kit.k, light = p.stageIsLight, time = kit.time
        let color = light ? p.surface.mix(p.accent, 0.22).mix(.black, 0.06) : p.surface.mix(.black, 0.28).mix(p.accent, 0.14)
        let span = 420 * k
        var towers = Path(), panes = Path(), lit = Path(), fading = Path(), screens = Path()
        var beacons: [CGPoint] = []

        var copy = -offset.truncatingRemainder(dividingBy: span)
        while copy < kit.w {
            for building in skyline {
                let rect = CGRect(x: copy + building.x * span, y: horizon - building.height * kit.h,
                                  width: building.width * span, height: building.height * kit.h)
                guard rect.maxX > 0, rect.minX < kit.w else { continue }
                towers.addRect(rect)
                if building.height > 0.3 {
                    beacons.append(CGPoint(x: rect.midX, y: rect.minY - 7 * k))
                    towers.addRect(CGRect(x: rect.midX - 0.5 * k, y: rect.minY - 7 * k, width: 1 * k, height: 7 * k))
                }

                var row: UInt64 = 0
                var y = rect.minY + 4 * k
                while y < horizon - 6 * k {
                    var column: UInt64 = 0
                    var x = rect.minX + 3 * k
                    while x < rect.maxX - 4 * k {
                        let pane = CGRect(x: x, y: y, width: 2 * k, height: 2.2 * k)
                        if light {
                            panes.addRect(pane)
                        } else {
                            // Each window keeps its own slow clock; a state
                            // change fades over the first moments of a cycle.
                            let id = hash(building.seed, row << 16 | column)
                            let period = 2.5 + Double(id % 5)
                            let clock = (time + Double((id >> 8) % 1000) / 1000 * period) / period
                            let cycle = UInt64(max(0, clock.rounded(.down)))
                            let on = hash(id, cycle) % 10 < 3
                            let wasOn = hash(id, cycle &- 1) % 10 < 3
                            if on != wasOn, (clock - clock.rounded(.down)) * period < 0.35 {
                                fading.addRect(pane)
                            } else if on {
                                if (id >> 40) % 9 == 0 { screens.addRect(pane) } else { lit.addRect(pane) }
                            }
                        }
                        x += 4.5 * k
                        column += 1
                    }
                    y += 5.5 * k
                    row += 1
                }
            }
            copy += span
        }

        context.fill(towers, with: .color(color.color(light ? 0.75 : 0.9)))
        if light {
            context.fill(panes, with: .color(color.mix(.black, 0.1).color(0.55)))
            // The sun catching the glass, sweeping across every few seconds.
            let sweep = (time / 9).truncatingRemainder(dividingBy: 1) * (kit.w + 160 * k) - 80 * k
            context.drawLayer { layer in
                layer.clip(to: towers)
                layer.fill(Path(CGRect(origin: .zero, size: kit.size)), with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(0.45), .clear]),
                    startPoint: CGPoint(x: sweep - 40 * k, y: 0), endPoint: CGPoint(x: sweep + 40 * k, y: kit.h * 0.2)))
            }
        } else {
            context.fill(lit, with: .color(p.yellow.color(0.6)))
            context.fill(fading, with: .color(p.yellow.color(0.28)))
            let flicker = kit.reduceMotion ? 0.6 : 0.5 + 0.3 * sin(time * 13) * sin(time * 7.3)
            context.fill(screens, with: .color(p.blue.mix(.white, 0.4).color(flicker)))
        }

        for (index, beacon) in beacons.enumerated() {
            let blink = kit.reduceMotion || (time / 1.7 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1) < 0.18
            guard blink else { continue }
            context.fill(kit.circle(beacon, 1.3 * k), with: .color(p.red.color()))
            if !light {
                context.fill(kit.circle(beacon, 6 * k), with: .radialGradient(
                    Gradient(colors: [p.red.color(0.45), .clear]), center: beacon, startRadius: 0, endRadius: 6 * k))
            }
        }
    }

    /// SplitMix64 finalizer: a stable pseudo-random value per input pair.
    private static func hash(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a &+ b &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Trackside lamp posts between the skyline and the road.
    private static func drawLamps(_ context: inout GraphicsContext, _ kit: PreviewKit, roadTop: Double, offset: Double) {
        let p = kit.palette, k = kit.k
        let pole = stageText(kit).mix(p.surface, p.stageIsLight ? 0.6 : 0.5)
        let spacing = 96 * k, height = 50 * k
        var x = -offset.truncatingRemainder(dividingBy: spacing) + spacing * 0.3
        while x < kit.w + spacing {
            let top = roadTop - height
            context.fill(Path(CGRect(x: x - 0.9 * k, y: top, width: 1.8 * k, height: height)), with: .color(pole.color(0.85)))
            var arm = Path()
            arm.move(to: CGPoint(x: x, y: top + 1 * k))
            arm.addQuadCurve(to: CGPoint(x: x + 9 * k, y: top + 2 * k), control: CGPoint(x: x + 2 * k, y: top - 3 * k))
            context.stroke(arm, with: .color(pole.color(0.85)), lineWidth: 1.5 * k)
            let head = CGPoint(x: x + 9 * k, y: top + 3 * k)
            context.fill(Path(roundedRect: CGRect(x: head.x - 3.5 * k, y: head.y - 1.2 * k, width: 7 * k, height: 2.4 * k), cornerRadius: 1.2 * k),
                         with: .color(p.yellow.mix(.white, 0.6).color()))
            if !p.stageIsLight {
                context.fill(kit.circle(head, 12 * k), with: .radialGradient(
                    Gradient(colors: [p.yellow.color(0.22), .clear]), center: head, startRadius: 0, endRadius: 12 * k))
            }
            x += spacing
        }
    }

    // MARK: Road

    private static func drawRoad(_ context: inout GraphicsContext, _ kit: PreviewKit, offset: Double,
                                 roadTop: Double, ground: Double, pit: Double) {
        let p = kit.palette, k = kit.k, w = kit.w, h = kit.h
        let kerbHeight = 4 * k
        let road = CGRect(x: 0, y: roadTop + kerbHeight, width: w, height: h - roadTop - kerbHeight)
        let asphalt = p.background
        context.fill(Path(road), with: .linearGradient(
            Gradient(colors: [asphalt.mix(.black, p.isLight ? 0.08 : 0.25).color(), asphalt.color()]),
            startPoint: CGPoint(x: 0, y: road.minY), endPoint: CGPoint(x: 0, y: road.maxY)))

        // Kerb: theme red blocks on a pale strip.
        let kerbBase = PreviewRGB.white.mix(asphalt, 0.12)
        context.fill(Path(CGRect(x: 0, y: roadTop, width: w, height: kerbHeight)), with: .color(kerbBase.color()))
        let block = 14 * k
        var x = -offset.truncatingRemainder(dividingBy: block * 2)
        while x < w {
            context.fill(Path(CGRect(x: x, y: roadTop, width: block, height: kerbHeight)), with: .color(p.red.color()))
            x += block * 2
        }

        // Center line, nearer the viewer than the car.
        let dashY = h * 0.95, dash = 22 * k
        x = -offset.truncatingRemainder(dividingBy: dash * 2)
        while x < w {
            kit.bar(&context, x: x, y: dashY, width: dash, height: 2.4, color: p.dim, opacity: 0.8)
            x += dash * 2
        }

        // Pit box painted on the road.
        guard pit > 0.01 else { return }
        let box = CGRect(x: w / 2 - 92 * k, y: ground - 7 * k, width: 184 * k, height: 13 * k)
        context.stroke(Path(roundedRect: box, cornerRadius: 2 * k), with: .color(p.yellow.color(0.85 * pit)), lineWidth: 1.3 * k)
    }

    /// The battery saver's 30 sign beside the track.
    private static func drawSpeedLimit(_ context: inout GraphicsContext, _ kit: PreviewKit, v: BatterySceneValues, roadTop: Double) {
        let alpha = v.limited
        guard alpha > 0.01 else { return }
        let k = kit.k, p = kit.palette
        let x = kit.w - 26 * k
        let rise = (1 - alpha) * 8 * k
        let center = CGPoint(x: x, y: roadTop - 26 * k + rise)
        context.fill(Path(CGRect(x: x - 0.9 * k, y: center.y, width: 1.8 * k, height: roadTop + 2 * k - center.y)),
                     with: .color(stageText(kit).mix(p.surface, 0.4).color(alpha)))
        context.fill(kit.circle(center, 10.5 * k), with: .color(PreviewRGB.white.color(alpha)))
        context.stroke(kit.circle(center, 9 * k), with: .color(p.red.color(alpha)), lineWidth: 2.6 * k)
        kit.label(&context, "30", at: center, size: 8.5, weight: .heavy, color: PreviewRGB(0.08, 0.08, 0.1), opacity: alpha)
    }

    // MARK: Pit garage

    /// The door opening, sized for the biggest car.
    private static func garageRect(_ kit: PreviewKit, ground: Double) -> CGRect {
        let k = kit.k
        let width = 186 * k, height = 74 * k
        return CGRect(x: kit.w / 2 - width / 2, y: ground - height, width: width, height: height + 3 * k)
    }

    private static func drawGarageBack(_ context: inout GraphicsContext, _ kit: PreviewKit, garage: CGRect, appear: Double) {
        guard appear > 0.01 else { return }
        let p = kit.palette
        let wall = p.chrome.mix(p.surface, p.stageIsLight ? 0.55 : 0.2).mix(.black, p.stageIsLight ? 0.05 : 0.2)
        context.fill(Path(garage), with: .linearGradient(
            Gradient(colors: [wall.mix(.black, 0.25).color(appear), wall.color(appear)]),
            startPoint: CGPoint(x: 0, y: garage.minY), endPoint: CGPoint(x: 0, y: garage.maxY)))
        // Pegboard of tools on the back wall.
        let k = kit.k
        for index in 0..<6 {
            let x = garage.minX + 14 * k + Double(index) * 9 * k
            context.fill(Path(roundedRect: CGRect(x: x, y: garage.minY + 10 * k, width: 2 * k, height: (8 + Double(index % 3) * 3) * k),
                              cornerRadius: k), with: .color(stageText(kit).mix(wall, 0.6).color(0.6 * appear)))
        }
        for index in 0..<3 {
            let rect = CGRect(x: garage.maxX - 40 * k + Double(index) * 11 * k, y: garage.maxY - 22 * k, width: 8 * k, height: 14 * k)
            context.fill(Path(roundedRect: rect, cornerRadius: 3 * k), with: .color(PreviewRGB(0.08, 0.08, 0.09).color(0.7 * appear)))
        }
    }

    private static func drawGarageFront(_ context: inout GraphicsContext, _ kit: PreviewKit, garage: CGRect,
                                        ground: Double, appear: Double, shut: Double) {
        guard appear > 0.01 else { return }
        let p = kit.palette, k = kit.k
        let drop = (1 - appear) * 14 * k
        let steel = PreviewRGB(0.16, 0.16, 0.18)

        // Work lamps light the car until the shutter covers it.
        let header = CGRect(x: garage.minX - 8 * k, y: garage.minY - 11 * k - drop, width: garage.width + 16 * k, height: 11 * k)
        for side in [-1.0, 1.0] {
            let lamp = CGPoint(x: garage.midX + side * 52 * k, y: header.maxY + 2 * k)
            var cone = Path()
            cone.move(to: CGPoint(x: lamp.x - 5 * k, y: lamp.y))
            cone.addLine(to: CGPoint(x: lamp.x + 5 * k, y: lamp.y))
            cone.addLine(to: CGPoint(x: lamp.x + 36 * k, y: ground))
            cone.addLine(to: CGPoint(x: lamp.x - 36 * k, y: ground))
            cone.closeSubpath()
            context.fill(cone, with: .linearGradient(
                Gradient(colors: [p.yellow.mix(.white, 0.6).color(0.3 * appear * (1 - shut)), .clear]),
                startPoint: lamp, endPoint: CGPoint(x: lamp.x, y: ground)))
        }

        // Roll-up shutter.
        if shut > 0.01 {
            let doorHeight = (garage.height) * shut
            let door = CGRect(x: garage.minX, y: garage.minY, width: garage.width, height: doorHeight)
            let metal = p.chrome.mix(p.surface, p.stageIsLight ? 0.7 : 0.35).mix(.white, p.stageIsLight ? 0 : 0.08)
            context.fill(Path(door), with: .linearGradient(
                Gradient(colors: [metal.mix(.white, 0.1).color(), metal.mix(.black, 0.12).color()]),
                startPoint: CGPoint(x: 0, y: door.minY), endPoint: CGPoint(x: 0, y: door.maxY)))
            let flicker = kit.reduceMotion ? 0.5 : max(0, sin(kit.time * 23) * sin(kit.time * 9.7))
            var y = door.maxY - 4.5 * k
            while y > door.minY {
                context.fill(Path(CGRect(x: door.minX, y: y, width: door.width, height: 0.9 * k)),
                             with: .color(PreviewRGB.black.color(p.stageIsLight ? 0.14 : 0.32)))
                context.fill(Path(CGRect(x: door.minX, y: y + 0.9 * k, width: door.width, height: 0.6 * k)),
                             with: .color(PreviewRGB.white.color(p.stageIsLight ? 0.35 : 0.1)))
                // Welding light leaking through the seams.
                context.fill(Path(CGRect(x: door.minX + door.width * 0.3, y: y, width: door.width * 0.4, height: 0.9 * k)),
                             with: .linearGradient(Gradient(colors: [.clear, p.accent.mix(.white, 0.5).color(0.6 * flicker * shut), .clear]),
                                                   startPoint: CGPoint(x: door.minX + door.width * 0.3, y: y),
                                                   endPoint: CGPoint(x: door.minX + door.width * 0.7, y: y)))
                y -= 4.5 * k
            }
            let bar = CGRect(x: door.minX, y: door.maxY - 3 * k, width: door.width, height: 3 * k)
            context.fill(Path(bar), with: .color(steel.color()))
            context.fill(Path(roundedRect: CGRect(x: door.midX - 7 * k, y: bar.minY - 2.5 * k, width: 14 * k, height: 2 * k), cornerRadius: k),
                         with: .color(steel.mix(.white, 0.3).color()))

            if shut > 0.9 {
                // Light spilling out under the door, and sparks with it.
                let leak = (shut - 0.9) / 0.1
                context.fill(Path(CGRect(x: door.minX, y: ground - 6 * k, width: door.width, height: 12 * k)),
                             with: .radialGradient(Gradient(colors: [p.accent.mix(.white, 0.6).color(0.45 * leak * (0.6 + 0.4 * flicker)), .clear]),
                                                   center: CGPoint(x: door.midX, y: ground + 2 * k), startRadius: 0, endRadius: door.width * 0.5))
                drawSparks(&context, kit, from: CGPoint(x: door.minX + 18 * k, y: ground - 1 * k), direction: -1, alpha: leak)
                drawSparks(&context, kit, from: CGPoint(x: door.maxX - 18 * k, y: ground - 1 * k), direction: 1, alpha: leak)
            }

            let badgeCenter = CGPoint(x: door.midX, y: door.maxY - min(door.height, garage.height) * 0.5)
            let badge = CGRect(x: badgeCenter.x - 12 * k, y: badgeCenter.y - 12 * k, width: 24 * k, height: 24 * k)
            context.drawLayer { layer in
                layer.opacity = PreviewKit.ease((shut - 0.6) / 0.4)
                kit.glass(&layer, badge)
                kit.symbol(&layer, "wrench.and.screwdriver.fill", in: badge.insetBy(dx: 6 * k, dy: 6 * k), color: stageText(kit))
            }
        }

        // Posts and the hazard-striped header, in front of everything.
        context.drawLayer { layer in
            layer.opacity = appear
            for x in [garage.minX - 8 * k, garage.maxX] {
                let post = CGRect(x: x, y: header.maxY, width: 8 * k, height: ground + 3 * k - header.maxY)
                layer.fill(Path(post), with: .linearGradient(Gradient(colors: [steel.mix(.white, 0.18).color(), steel.color()]),
                                                             startPoint: CGPoint(x: post.minX, y: 0), endPoint: CGPoint(x: post.maxX, y: 0)))
            }
            layer.fill(Path(header), with: .color(steel.color()))
            var stripes = layer
            stripes.clip(to: Path(header.insetBy(dx: 0, dy: 2 * k)))
            var x = header.minX - header.height
            while x < header.maxX {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: header.maxY))
                stripe.addLine(to: CGPoint(x: x + header.height, y: header.minY))
                stripe.addLine(to: CGPoint(x: x + header.height + 5 * k, y: header.minY))
                stripe.addLine(to: CGPoint(x: x + 5 * k, y: header.maxY))
                stripe.closeSubpath()
                stripes.fill(stripe, with: .color(p.yellow.color()))
                x += 10 * k
            }
            for side in [-1.0, 1.0] {
                let lamp = CGRect(x: garage.midX + side * 52 * k - 6 * k, y: header.maxY - 1 * k, width: 12 * k, height: 4 * k)
                layer.fill(Path(roundedRect: lamp, cornerRadius: 2 * k), with: .color(p.yellow.mix(.white, 0.7).color()))
            }
        }
    }

    private static func drawSparks(_ context: inout GraphicsContext, _ kit: PreviewKit, from source: CGPoint, direction: Double, alpha: Double) {
        guard !kit.reduceMotion else { return }
        let k = kit.k, p = kit.palette
        var seed: UInt64 = direction > 0 ? 0x5EA_5CA1 : 0x0C0F_FEE
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for index in 0..<10 {
            let angle = -0.5 - next() * 0.9
            let speed = (45 + next() * 55) * k
            let progress = (kit.time / 0.6 + Double(index) / 10).truncatingRemainder(dividingBy: 1)
            let t = progress * 0.6
            let vx = cos(angle) * speed * direction, vy = sin(angle) * speed
            let head = CGPoint(x: source.x + vx * t, y: source.y + vy * t + 180 * k * t * t)
            let tail = CGPoint(x: head.x - vx * 0.035, y: head.y - (vy + 360 * k * t) * 0.035)
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            context.stroke(streak, with: .color(p.yellow.mix(.white, 0.5).color((1 - progress) * alpha)),
                           style: StrokeStyle(lineWidth: 1.1 * k, lineCap: .round))
        }
    }

    // MARK: Car

    private static func drawTrail(_ context: inout GraphicsContext, _ kit: PreviewKit, v: BatterySceneValues,
                                  rearX: Double, top: Double, ground: Double, moving: Double) {
        guard !kit.reduceMotion else { return }
        let p = kit.palette, k = kit.k, w = kit.w

        // Sports car: speed streaks.
        let streaks = v.cars[0] * moving * (1 - v.limited)
        if streaks > 0.01 {
            for index in 0..<6 {
                let seed = Double(index)
                let y = top + (ground - top) * (0.1 + 0.15 * seed) - 4 * k
                let length = (26 + 14 * sin(seed * 2.3).magnitude) * k
                let span = w + length
                let x = w - (kit.time * (420 + 60 * seed) * k + seed * 97 * k).truncatingRemainder(dividingBy: span)
                kit.bar(&context, x: x, y: y, width: length, height: 1.2, color: stageText(kit), opacity: 0.3 * streaks)
            }
        }

        // Microcar: a few leaves tumbling off behind it.
        let leaves = v.cars[2] * moving
        if leaves > 0.01 {
            for index in 0..<3 {
                let seed = Double(index)
                let progress = (kit.time / 3.2 + seed / 3).truncatingRemainder(dividingBy: 1)
                let x = rearX - progress * 110 * k + 4 * k
                let y = top + 10 * k + progress * 26 * k + sin(kit.time * 3 + seed * 2) * 3 * k
                let alpha = leaves * sin(progress * .pi) * 0.85
                context.drawLayer { layer in
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(kit.time * 2.4 + seed * 1.7))
                    kit.symbol(&layer, "leaf.fill", in: CGRect(x: -4 * k, y: -4 * k, width: 8 * k, height: 8 * k),
                               color: p.stageIsLight ? p.green.mix(.black, 0.2) : p.green.mix(.white, 0.15), opacity: alpha)
                }
            }
        }
    }

    // MARK: Readout

    /// Top-left chip: the redraw rate, and where the power is coming from.
    private static func drawReadout(_ context: inout GraphicsContext, _ kit: PreviewKit, v: BatterySceneValues) {
        let k = kit.k, text = stageText(kit)
        let chip = CGRect(x: 10 * k, y: 10 * k, width: 66 * k, height: 20 * k)
        kit.glass(&context, chip)
        let icon = CGRect(x: chip.minX + 7 * k, y: chip.midY - 5.5 * k, width: 11 * k, height: 11 * k)
        kit.symbol(&context, "gauge.with.dots.needle.67percent", in: icon, color: text, opacity: 1 - v.adaptive)
        let bolt = kit.palette.stageIsLight ? kit.palette.yellow.mix(.black, 0.35) : kit.palette.yellow
        kit.symbol(&context, "bolt.fill", in: icon, color: bolt, opacity: v.adaptive * v.plugged)
        kit.symbol(&context, "battery.75percent", in: icon, color: text, opacity: v.adaptive * (1 - v.plugged))

        // Only the leading car's rate, hidden through the pit stop so two
        // numbers never overlap; it swaps while the pit hides it.
        let rates = [Int(v.topRate.rounded()), 60, 30]
        let leader = v.cars.indices.max { v.cars[$0] < v.cars[$1] } ?? 0
        let anchor = CGPoint(x: icon.maxX + 5 * k, y: chip.midY)
        let shown = 1 - v.pit
        let capped = rates[leader] == 30
        kit.label(&context, hertz(rates[leader]), at: anchor, size: 10, color: text,
                  opacity: shown * (capped ? 1 : 1 - v.limited), anchor: .leading)
        if v.limited > 0.01, !capped {
            kit.label(&context, hertz(30), at: anchor, size: 10, color: text, opacity: shown * v.limited, anchor: .leading)
        }
    }

    private static func hertz(_ rate: Int) -> String {
        String(localized: "\(rate) Hz", comment: "Battery settings preview: refresh rate readout, e.g. 60 Hz")
    }
}
