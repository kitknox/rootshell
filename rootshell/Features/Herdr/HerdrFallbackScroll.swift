import Foundation

/// The attach client's alternate screen has no local scrollback. Accumulate
/// precise deltas independently of mouse capture, then ask herdr to scroll.
nonisolated struct HerdrFallbackScroll {
    private var remainder = 0.0

    mutating func consume(delta: Double, cellHeight: Double) -> Int {
        guard delta.isFinite, cellHeight.isFinite, cellHeight > 0 else { return 0 }
        if remainder * delta < 0 { remainder = 0 }
        // One stock attach wheel event scrolls three rows. Match the physical
        // distance and bound bursts (including momentum after a long pause).
        remainder = min(32, max(-32, remainder + delta / (cellHeight * 3)))
        let steps = Int(remainder)
        remainder -= Double(steps)
        return steps
    }

    static func wheel(steps: Int, column: Int, row: Int) -> Data {
        let count = min(32, max(-32, steps))
        let event = "\u{1b}[<\(count > 0 ? 64 : 65);\(max(1, column));\(max(1, row))M"
        return Data(String(repeating: event, count: abs(count)).utf8)
    }
}
