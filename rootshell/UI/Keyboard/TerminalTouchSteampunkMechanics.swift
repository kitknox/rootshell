import Foundation
import CoreGraphics

/// Pure, bounded visual state. Never receives a character, command, or input callback.
/// One tooth phase drives each bank's meshing gears and stitched transmission belt.
nonisolated enum TerminalTouchSteampunkMechanics {
    static let phasePeriod = 48.0 // LCM of the 12-, 16-, 24-, and 48-tooth wheels.

    struct Bank: Sendable, Equatable {
        private(set) var phase = 0.0
        private(set) var speed = 0.0
        private(set) var pressure = 0.0

        var isMoving: Bool { speed > 0 || pressure > 0 }

        mutating func strike(_ strength: Double) {
            guard strength.isFinite, strength > 0 else { return }
            let strength = min(1.6, strength)
            speed = min(34, speed + 10 * strength)
            pressure = min(1, pressure + 0.34 * strength)
        }

        mutating func advance(seconds: Double, held: Double) {
            guard seconds.isFinite, seconds > 0 else { return }
            // A stalled frame must not fling the mechanism forward on resumption.
            let dt = min(seconds, 1.0 / 15.0)
            let load = held.isFinite ? min(2, max(0, held)) : 0
            let target = min(16, load * 9)
            let decay = exp(-4.8 * dt)
            // Analytic integration: the same motion at 30, 60, and 120 Hz.
            let distance = target * dt + (speed - target) * (1 - decay) / 4.8
            phase = (phase + max(0, distance)).truncatingRemainder(dividingBy: TerminalTouchSteampunkMechanics.phasePeriod)
            speed = target + (speed - target) * decay
            let pressureTarget = min(0.68, load * 0.32)
            pressure = pressureTarget + (pressure - pressureTarget) * exp(-6.5 * dt)
            if load == 0 {
                if speed < 0.025 { speed = 0 }
                if pressure < 0.003 { pressure = 0 }
            }
        }

        mutating func stop() { speed = 0; pressure = 0 }

        func angle(teeth: Int, reversed: Bool = false) -> Double {
            guard teeth > 0 else { return 0 }
            return phase * 2 * .pi / Double(teeth) * (reversed ? -1 : 1)
        }
    }

    struct Drive: Sendable {
        /// Normalized x of each mechanism: belt banks, then clearing clusters.
        private(set) var centers: [Double] = [0.17, 0.5, 0.83]
        private(set) var banks = Array(repeating: Bank(), count: 3)
        private(set) var lastTime: Double?
        var isMoving: Bool { banks.contains { $0.isMoving } }

        /// Surviving banks keep their phase, so a relayout never snaps the gears.
        mutating func place(centers: [Double]) {
            banks = centers.indices.map { banks.indices.contains($0) ? banks[$0] : Bank() }
            self.centers = centers
        }

        func weights(at position: Double) -> [Double] {
            let x = position.isFinite ? min(1, max(0, position)) : 0.5
            // A neighbouring bank receives a small transmitted impulse, not a
            // full-screen flash. The closest bank always receives the strongest.
            let reach = 1.38 / Double(max(3, centers.count))
            return centers.map { center in
                max(0.08, 1 - abs(center - x) / reach)
            }
        }

        mutating func strike(at position: Double, strength: Double = 1) {
            for (index, weight) in weights(at: position).enumerated() {
                banks[index].strike(strength * weight)
            }
        }

        mutating func advance(to time: Double, held: [Double]) {
            guard time.isFinite else { stop(); return }
            guard let previous = lastTime else { lastTime = time; return }
            lastTime = time
            guard time >= previous, time - previous < 0.5 else { stop(); return }
            for index in banks.indices {
                banks[index].advance(seconds: time - previous, held: held.indices.contains(index) ? held[index] : 0)
            }
        }

        mutating func rebaseClock() { lastTime = nil }
        mutating func stop() {
            for index in banks.indices { banks[index].stop() }
            lastTime = nil
        }
    }

    /// Open space beside the keys: `columns` run through every typing row (a
    /// split's gap, side safe areas); `pockets` are one row tall (staggered ends).
    struct Clearings: Equatable {
        var columns: [CGRect] = []
        var pockets: [CGRect] = []
    }

    private static func gaps(_ cells: [CGRect], width: CGFloat) -> [Range<CGFloat>] {
        var gaps: [Range<CGFloat>] = []
        var x: CGFloat = 0
        for cell in cells.sorted(by: { $0.minX < $1.minX }) where cell.width > 0 {
            if cell.minX > x { gaps.append(x..<min(width, cell.minX)) }
            x = max(x, cell.maxX)
        }
        if x < width { gaps.append(x..<width) }
        return gaps
    }

    private static func intersect(_ a: [Range<CGFloat>], _ b: [Range<CGFloat>]) -> [Range<CGFloat>] {
        a.flatMap { r in
            b.compactMap { s in
                let lower = max(r.lowerBound, s.lowerBound), upper = min(r.upperBound, s.upperBound)
                return lower < upper ? lower..<upper : nil
            }
        }
    }

    /// `rows` are typing-row cell frames, top to bottom; the last row reaches `bottom`.
    static func clearings(rows: [[CGRect]], width: CGFloat, bottom: CGFloat) -> Clearings {
        let rows = rows.filter { !$0.isEmpty }
        guard let first = rows.first, width > 0 else { return Clearings() }
        let top = first.map(\.minY).min() ?? 0
        let open = rows.map { gaps($0, width: width) }
        let shared = open.dropFirst().reduce(open[0], intersect).filter { $0.upperBound - $0.lowerBound >= 30 }
        var result = Clearings()
        result.columns = shared.map {
            CGRect(x: $0.lowerBound, y: top, width: $0.upperBound - $0.lowerBound, height: max(0, bottom - top))
        }
        let solid = gaps(result.columns, width: width)
        for (index, row) in rows.enumerated() {
            let minY = row.map(\.minY).min() ?? 0
            let maxY = index == rows.count - 1 ? bottom : row.map(\.maxY).max() ?? minY
            for gap in intersect(open[index], solid) where gap.upperBound - gap.lowerBound >= 40 {
                result.pockets.append(CGRect(x: gap.lowerBound, y: minY, width: gap.upperBound - gap.lowerBound,
                                             height: maxY - minY))
            }
        }
        return result
    }

    /// Belt banks spread through the keyed spans at roughly phone density;
    /// an unsplit keyboard keeps at least the original three.
    static func bankCenters(width: CGFloat, columns: [CGRect]) -> [CGFloat] {
        guard width > 0 else { return [] }
        let spans = columns.isEmpty ? [0..<width] : gaps(columns, width: width).filter { $0.upperBound - $0.lowerBound >= 60 }
        return spans.flatMap { span -> [CGFloat] in
            let length = span.upperBound - span.lowerBound
            let count = max(columns.isEmpty ? 3 : 1, Int((length / 180).rounded()))
            return (0..<count).map { span.lowerBound + length * (CGFloat($0) + 0.5) / CGFloat(count) }
        }
    }

    struct Gear: Equatable, Sendable {
        let center: CGPoint
        let teeth: Int
        let reversed: Bool
        let offset: Double
    }

    struct Cluster: Equatable, Sendable {
        var gears: [Gear] = []
        var gauge: CGRect?
    }

    static func pitchRadius(teeth: Int, module: CGFloat) -> CGFloat { CGFloat(teeth) / 2 * module }
    static func outerRadius(teeth: Int, module: CGFloat) -> CGFloat { (CGFloat(teeth) / 2 + 0.8) * module }

    /// A gear meshing with `parent` at `center`: opposite rotation, and a tooth
    /// phase that seats the parent's tip in its root along the line of centers.
    static func meshed(with parent: Gear, teeth: Int, at center: CGPoint) -> Gear {
        let theta = Double(atan2(center.y - parent.center.y, center.x - parent.center.x))
        let tooth = 2 * Double.pi / Double(teeth)
        let parentTeeth = (theta - parent.offset) * Double(parent.teeth) / (2 * .pi)
        let offset = (theta + .pi - tooth * (0.5 - parentTeeth)).truncatingRemainder(dividingBy: tooth)
        return Gear(center: center, teeth: teeth, reversed: !parent.reversed, offset: offset)
    }

    /// Deterministic packing: a hero wheel, a gauge, then meshing gears grown
    /// toward the emptiest point. Parts may tuck partly under adjacent keys,
    /// but never past `limits` (the keyboard's own edges).
    static func cluster(in rect: CGRect, module: CGFloat, limits: CGRect, limit: Int = 14) -> Cluster {
        func outer(_ teeth: Int) -> CGFloat { outerRadius(teeth: teeth, module: module) }
        guard module > 0, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              let hero = [48, 24, 16, 12].first(where: { outer($0) * 2 <= min(rect.width, rect.height) * 1.05 })
        else { return Cluster() }
        // Only the hero may be a 48-tooth wheel; small pinions only in small clusters.
        let sizes = [24, 16, 12].filter { $0 <= hero && ($0 > 12 || hero <= 16) }
        var result = Cluster()
        let step = max(4, module * 2.5)
        let grid = stride(from: rect.minY + step / 2, to: rect.maxY, by: step).flatMap { y in
            stride(from: rect.minX + step / 2, to: rect.maxX, by: step).map { CGPoint(x: $0, y: y) }
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        // Free radius around each grid point, narrowed as parts are placed.
        // Sides that meet keys allow a little overhang; the keyboard's edges don't.
        func slack(_ side: CGFloat, _ edge: CGFloat) -> CGFloat { abs(side - edge) < 0.5 ? 0 : 4 }
        var rooms = grid.map { p in
            min(p.x - rect.minX + slack(rect.minX, limits.minX), rect.maxX - p.x + slack(rect.maxX, limits.maxX),
                p.y - rect.minY + 4, rect.maxY - p.y + slack(rect.maxY, limits.maxY))
        }
        var blocked = [Bool](repeating: false, count: grid.count)
        func occupy(_ center: CGPoint, radius: CGFloat) {
            for index in grid.indices { rooms[index] = min(rooms[index], distance(grid[index], center) - radius) }
        }
        // Ties go to the point nearest the clearing's center.
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        func emptiest(skippingBlocked: Bool) -> (point: CGPoint, room: CGFloat)? {
            var best: (index: Int, room: CGFloat, offset: CGFloat)?
            for index in grid.indices where !(skippingBlocked && blocked[index]) {
                let offset = distance(grid[index], middle)
                if best.map({ rooms[index] > $0.room || (rooms[index] == $0.room && offset < $0.offset) }) ?? true {
                    best = (index, rooms[index], offset)
                }
            }
            return best.map { (grid[$0.index], $0.room) }
        }
        func clear(_ center: CGPoint, radius: CGFloat, except parent: Int) -> Bool {
            guard rect.insetBy(dx: radius * 0.55, dy: radius * 0.55).contains(center),
                  limits.insetBy(dx: radius, dy: 0).contains(center), center.y + radius <= limits.maxY else { return false }
            if let gauge = result.gauge, distance(center, CGPoint(x: gauge.midX, y: gauge.midY)) < radius + gauge.width / 2 + 1.5 {
                return false
            }
            return result.gears.indices.allSatisfy { index in
                index == parent || distance(center, result.gears[index].center) >= radius + outer(result.gears[index].teeth) + 1.5
            }
        }
        func add(_ gear: Gear) {
            result.gears.append(gear)
            occupy(gear.center, radius: outer(gear.teeth))
        }
        func placeGauge() {
            guard result.gauge == nil, let spot = emptiest(skippingBlocked: false), spot.room >= 9 else { return }
            let diameter = min(36, (spot.room * 2 - 2).rounded(.down))
            result.gauge = CGRect(x: spot.point.x - diameter / 2, y: spot.point.y - diameter / 2, width: diameter, height: diameter)
            occupy(spot.point, radius: diameter / 2)
        }
        guard let start = emptiest(skippingBlocked: false) else { return result }
        add(Gear(center: start.point, teeth: hero, reversed: false, offset: 0))
        if min(rect.width, rect.height) >= 70 { placeGauge() }
        // A far target is approached one meshing wheel at a time, as a chain.
        for _ in 0..<(limit * 2) where result.gears.count < limit {
            guard let target = emptiest(skippingBlocked: true), target.room >= outer(16) * 0.8 else { break }
            var best: (gear: Gear, cost: CGFloat)?
            for parent in result.gears.indices {
                let gear = result.gears[parent]
                for teeth in sizes where outer(teeth) <= target.room * 1.6 {
                    let reach = pitchRadius(teeth: gear.teeth, module: module) + pitchRadius(teeth: teeth, module: module)
                    for turn in 0..<36 {
                        let angle = CGFloat(turn) * .pi / 18
                        let center = CGPoint(x: gear.center.x + cos(angle) * reach, y: gear.center.y + sin(angle) * reach)
                        guard clear(center, radius: outer(teeth), except: parent) else { continue }
                        let cost = distance(center, target.point) - outer(teeth) * 0.75
                        if best.map({ cost < $0.cost }) ?? true {
                            best = (meshed(with: gear, teeth: teeth, at: center), cost)
                        }
                    }
                }
            }
            if let best {
                add(best.gear)
            } else {
                for index in grid.indices where distance(grid[index], target.point) < step * 3 { blocked[index] = true }
            }
        }
        placeGauge()
        return result
    }

    /// The porcelain/enamel face is deliberately separate from its brass rim.
    /// All illumination under a live UIKit legend preserves the contrast floor.
    struct RGB: Hashable, Sendable {
        let r: Double
        let g: Double
        let b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            func clean(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
            self.r = clean(r); self.g = clean(g); self.b = clean(b)
        }
        static let black = Self(0, 0, 0)
        static let white = Self(1, 1, 1)
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(_ other: Self) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
        func mix(_ other: Self, _ fraction: Double) -> Self {
            let t = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return Self(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }
        func ink(preferred: Self, minimum: Double) -> Self {
            if contrast(preferred) >= minimum { return preferred }
            return contrast(.black) >= contrast(.white) ? .black : .white
        }
        func lit(toward light: Self, amount: Double, ink: Self, minimum: Double) -> Self {
            let amount = amount.isFinite ? min(1, max(0, amount)) : 0
            let side = luminance >= ink.luminance
            func valid(_ c: Self) -> Bool { c.contrast(ink) >= minimum && (c.luminance >= ink.luminance) == side }
            if valid(mix(light, amount)) { return mix(light, amount) }
            var low = 0.0, high = amount
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if valid(mix(light, mid)) { low = mid } else { high = mid }
            }
            return mix(light, low)
        }
        var cacheKey: String { [r, g, b].map { String($0.bitPattern, radix: 16) }.joined(separator: ":") }
    }
}
