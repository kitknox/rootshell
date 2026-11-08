//
//  KVMHIDFrame.swift
//  rootshell
//
//  Binary HID frames for kvmd's `/api/ws`. The first byte selects the
//  server handler; the rest is that handler's payload.
//

import Foundation

nonisolated enum KVMHIDFrame {
    enum MouseButton: String, CaseIterable, Sendable {
        case left, right, middle
        // kvmd names the back/forward side buttons "up"/"down".
        case back = "up"
        case forward = "down"
    }

    static let ping = Data([0x00])
    static let pong: UInt8 = 0xFF

    static func key(_ code: String, down: Bool) -> Data {
        var data = Data([0x01, down ? 0x01 : 0x00])
        data.append(contentsOf: code.utf8.prefix(32))
        return data
    }

    static func button(_ button: MouseButton, down: Bool) -> Data {
        var data = Data([0x02, down ? 0x01 : 0x00])
        data.append(contentsOf: button.rawValue.utf8)
        return data
    }

    static func absoluteMove(x: Int16, y: Int16) -> Data {
        var data = Data([0x03])
        append(x, to: &data)
        append(y, to: &data)
        return data
    }

    /// kvmd validates each delta to ±127 and accepts many pairs per frame.
    static func relativeMove(_ deltas: [(dx: Int8, dy: Int8)], squash: Bool = false) -> Data {
        deltaFrame(op: 0x04, deltas: deltas, squash: squash)
    }

    /// Positive `dy` scrolls up.
    static func wheel(dx: Int8, dy: Int8) -> Data {
        deltaFrame(op: 0x05, deltas: [(dx, dy)], squash: false)
    }

    /// Maps a framebuffer pixel to kvmd's -32768...32767 span of the frame.
    static func absoluteCoordinate(_ value: Int, extent: Int) -> Int16 {
        guard extent > 1 else { return 0 }
        let clamped = min(max(value, 0), extent - 1)
        let scaled = (Double(clamped) * 65_535 / Double(extent - 1)).rounded()
        return Int16(clamping: Int(scaled) - 32_768)
    }

    /// Splits a large motion into ±127 steps that sum to the original.
    static func splitDelta(dx: Int, dy: Int) -> [(dx: Int8, dy: Int8)] {
        var remainingX = dx
        var remainingY = dy
        var steps: [(dx: Int8, dy: Int8)] = []
        while remainingX != 0 || remainingY != 0 {
            let stepX = max(-127, min(127, remainingX))
            let stepY = max(-127, min(127, remainingY))
            steps.append((Int8(stepX), Int8(stepY)))
            remainingX -= stepX
            remainingY -= stepY
        }
        return steps
    }

    private static func deltaFrame(op: UInt8, deltas: [(dx: Int8, dy: Int8)], squash: Bool) -> Data {
        var data = Data([op, squash ? 0x01 : 0x00])
        for delta in deltas {
            data.append(UInt8(bitPattern: delta.dx))
            data.append(UInt8(bitPattern: delta.dy))
        }
        return data
    }

    private static func append(_ value: Int16, to data: inout Data) {
        let bits = UInt16(bitPattern: value)
        data.append(UInt8(bits >> 8))
        data.append(UInt8(bits & 0xFF))
    }
}
