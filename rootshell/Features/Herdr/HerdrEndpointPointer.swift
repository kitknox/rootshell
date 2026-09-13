// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Pointer translation for vanilla endpoint generation 1, independent of UIKit.
nonisolated struct HerdrEndpointPointer {
    enum Scroll: Equatable {
        case viewport(rows: Int)
        case mouse(kind: UInt64, steps: Int)

        var kind: UInt64 {
            switch self {
            case .viewport(let rows): return rows > 0 ? 4 : 5
            case .mouse(let kind, _): return kind
            }
        }
        // Stock herdr uses `lines` only for host scrollback. Mouse reporting
        // and alternate-scroll translate each event once, regardless of lines.
        var lines: Int {
            switch self { case .viewport(let rows): return abs(rows); case .mouse: return 1 }
        }
        var repeatCount: Int {
            switch self { case .viewport: return 1; case .mouse(_, let steps): return steps }
        }
    }

    private var horizontalRemainder = 0.0
    private var verticalRemainder = 0.0

    mutating func scroll(deltaX: Double, deltaY: Double, cellWidth: Double, cellHeight: Double,
                         capturesMouse: Bool, alternateScreen: Bool, popup: Bool,
                         mouseCaptureOverride: Bool = false) -> [Scroll] {
        // Only herdr knows whether DEC alternate-scroll is enabled. Forward
        // wheels on the alternate screen so it can translate them to keys,
        // unless the user has disabled forwarding mouse input altogether.
        let semantic = !mouseCaptureOverride && (capturesMouse || alternateScreen || popup)
        let rows = Self.consume(deltaY, cell: cellHeight, remainder: &verticalRemainder)
        let columns: Int
        if semantic {
            columns = Self.consume(deltaX, cell: cellWidth, remainder: &horizontalRemainder)
        } else {
            horizontalRemainder = 0
            columns = 0
        }
        var events: [Scroll] = []
        if rows != 0 {
            events.append(semantic ? .mouse(kind: rows > 0 ? 4 : 5, steps: abs(rows)) : .viewport(rows: rows))
        }
        if columns != 0 {
            // Native deltas are positive up/right, negative down/left.
            events.append(.mouse(kind: columns > 0 ? 7 : 6, steps: abs(columns)))
        }
        return events
    }

    private static func consume(_ delta: Double, cell: Double, remainder: inout Double) -> Int {
        guard delta.isFinite, cell.isFinite, cell > 0 else { return 0 }
        // Match the old attach path's maximum burst of 32 three-row ticks.
        // A delayed momentum callback must not enqueue thousands of reports.
        let amount = max(-96, min(96, remainder + delta / cell))
        let steps = Int(amount.rounded(.towardZero))
        remainder = amount - Double(steps)
        return steps
    }

    static func pixelCoordinate(_ coordinate: Double, padding: Double, scale: Double, extent: UInt32) -> UInt32? {
        guard extent > 0, scale.isFinite, scale > 0 else { return nil }
        let physical = (coordinate - padding) * scale
        guard physical.isFinite else { return nil }
        // Cells are zero-based, but upstream validates pixels in 1...extent.
        return UInt32(max(0, min(Double(extent - 1), physical))) + 1
    }
}
