//
//  KVMInputTranslator.swift
//  rootshell
//
//  Turns the remote-screen input layer's events (HID usages, X11 keysyms,
//  RFB button masks) into kvmd HID frames, or into text the device types
//  with its own keymap when the remote layout isn't US.
//

import Foundation

nonisolated enum KVMInputOutput: Equatable, Sendable {
    case frame(Data)
    /// Typed by the device through `/api/hid/print` with the host keymap.
    case text(String)
}

nonisolated struct KVMInputTranslator {
    static let usLayout = "en-us"

    /// kvmd keymap name for the remote computer's keyboard layout.
    var hostLayout = Self.usLayout
    var mouseAbsolute = true
    /// Flips both wheel axes for a Mac, which applies its own natural
    /// scrolling to the KVM's USB mouse on top of the local direction.
    var reverseScrolling = false
    var frameWidth = 0
    var frameHeight = 0

    private struct KeysymPress {
        let code: String?
        let synthesizedShift: Bool
    }

    private var codeRefs: [String: Int] = [:]
    private var physicalCodes: [UInt32: String] = [:]
    private var keysymPresses: [UInt32: KeysymPress] = [:]
    /// Shift held by the user rather than added around a shifted character.
    private var userShiftRefs = 0
    private var buttonMask: UInt8 = 0
    private var lastPoint: (x: Int, y: Int)?

    init() {}

    var typesTextOnDevice: Bool { hostLayout != Self.usLayout }

    // MARK: Keys

    /// A hardware key by physical position. Repeated downs are dropped: the
    /// remote computer auto-repeats a held USB key itself.
    mutating func physicalKey(down: Bool, usage: UInt32) -> [KVMInputOutput] {
        if down {
            guard physicalCodes[usage] == nil, let code = KVMKeyMap.code(forHIDUsage: usage) else { return [] }
            physicalCodes[usage] = code
            if KVMKeyMap.shiftCodes.contains(code) { userShiftRefs += 1 }
            return press(code)
        }
        guard let code = physicalCodes.removeValue(forKey: usage) else { return [] }
        if KVMKeyMap.shiftCodes.contains(code) { userShiftRefs -= 1 }
        return release(code)
    }

    mutating func keysym(down: Bool, keysym: UInt32) -> [KVMInputOutput] {
        guard down else { return releaseKeysym(keysym) }
        guard keysymPresses[keysym] == nil else { return [] }

        let printable = Self.character(forKeysym: keysym)
        if let character = printable, typesTextOnDevice || KVMKeyMap.key(forKeysym: keysym) == nil {
            keysymPresses[keysym] = KeysymPress(code: nil, synthesizedShift: false)
            return [.text(String(character))]
        }
        guard let key = KVMKeyMap.key(forKeysym: keysym) else { return [] }

        var output: [KVMInputOutput] = []
        let synthesizeShift = key.shifted && userShiftRefs == 0
        if synthesizeShift {
            output += press("ShiftLeft")
        }
        if KVMKeyMap.shiftCodes.contains(key.code) { userShiftRefs += 1 }
        output += press(key.code)
        keysymPresses[keysym] = KeysymPress(code: key.code, synthesizedShift: synthesizeShift)
        return output
    }

    private mutating func releaseKeysym(_ keysym: UInt32) -> [KVMInputOutput] {
        guard let pressed = keysymPresses.removeValue(forKey: keysym),
              let code = pressed.code else { return [] }
        if KVMKeyMap.shiftCodes.contains(code) { userShiftRefs -= 1 }
        var output = release(code)
        if pressed.synthesizedShift {
            output += release("ShiftLeft")
        }
        return output
    }

    private mutating func press(_ code: String) -> [KVMInputOutput] {
        let count = codeRefs[code, default: 0]
        codeRefs[code] = count + 1
        return count == 0 ? [.frame(KVMHIDFrame.key(code, down: true))] : []
    }

    private mutating func release(_ code: String) -> [KVMInputOutput] {
        guard let count = codeRefs[code] else { return [] }
        if count <= 1 {
            codeRefs.removeValue(forKey: code)
            return [.frame(KVMHIDFrame.key(code, down: false))]
        }
        codeRefs[code] = count - 1
        return []
    }

    static func character(forKeysym keysym: UInt32) -> Character? {
        let scalarValue: UInt32
        switch keysym {
        case 0x20...0x7E, 0xA0...0xFF:
            scalarValue = keysym
        case 0x0100_0100...0x0110_FFFF:
            scalarValue = keysym & 0x00FF_FFFF
        default:
            return nil
        }
        return UnicodeScalar(scalarValue).map(Character.init)
    }

    // MARK: Pointer

    /// RFB button mask: bit 0 left, 1 middle, 2 right, 3/4 wheel up/down,
    /// 5/6 wheel left/right.
    mutating func pointer(buttonMask mask: UInt8, x: Int, y: Int) -> [KVMInputOutput] {
        var output = move(x: x, y: y)

        let buttons: [(UInt8, KVMHIDFrame.MouseButton)] = [(0x01, .left), (0x02, .middle), (0x04, .right)]
        for (bit, button) in buttons where (buttonMask & bit) != (mask & bit) {
            output.append(.frame(KVMHIDFrame.button(button, down: mask & bit != 0)))
        }

        let pressed = mask & ~buttonMask
        let tick: Int8 = reverseScrolling ? -1 : 1
        if pressed & 0x08 != 0 { output.append(.frame(KVMHIDFrame.wheel(dx: 0, dy: tick))) }
        if pressed & 0x10 != 0 { output.append(.frame(KVMHIDFrame.wheel(dx: 0, dy: -tick))) }
        if pressed & 0x20 != 0 { output.append(.frame(KVMHIDFrame.wheel(dx: -tick, dy: 0))) }
        if pressed & 0x40 != 0 { output.append(.frame(KVMHIDFrame.wheel(dx: tick, dy: 0))) }
        buttonMask = mask
        return output
    }

    /// Whole wheel units; positive `wheelY` scrolls up, positive `wheelX` right.
    mutating func scroll(x: Int, y: Int, wheelX: Int, wheelY: Int) -> [KVMInputOutput] {
        let sign = reverseScrolling ? -1 : 1
        return move(x: x, y: y) + KVMHIDFrame.splitDelta(dx: wheelX * sign, dy: wheelY * sign).map {
            .frame(KVMHIDFrame.wheel(dx: $0.dx, dy: $0.dy))
        }
    }

    private mutating func move(x: Int, y: Int) -> [KVMInputOutput] {
        if let lastPoint, lastPoint.x == x, lastPoint.y == y { return [] }
        defer { lastPoint = (x, y) }
        if mouseAbsolute {
            return [.frame(KVMHIDFrame.absoluteMove(
                x: KVMHIDFrame.absoluteCoordinate(x, extent: frameWidth),
                y: KVMHIDFrame.absoluteCoordinate(y, extent: frameHeight)))]
        }
        guard let lastPoint else { return [] }
        let steps = KVMHIDFrame.splitDelta(dx: x - lastPoint.x, dy: y - lastPoint.y)
        return steps.isEmpty ? [] : [.frame(KVMHIDFrame.relativeMove(steps))]
    }

    // MARK: Reset

    /// Releases every held key and button, e.g. on focus loss.
    mutating func releaseAll() -> [KVMInputOutput] {
        var output = codeRefs.keys.sorted().map { KVMInputOutput.frame(KVMHIDFrame.key($0, down: false)) }
        let buttons: [(UInt8, KVMHIDFrame.MouseButton)] = [(0x01, .left), (0x02, .middle), (0x04, .right)]
        for (bit, button) in buttons where buttonMask & bit != 0 {
            output.append(.frame(KVMHIDFrame.button(button, down: false)))
        }
        codeRefs.removeAll()
        physicalCodes.removeAll()
        keysymPresses.removeAll()
        userShiftRefs = 0
        buttonMask = 0
        return output
    }

    /// Forget held state without sending releases; the device already
    /// dropped it (a new control socket releases every key).
    mutating func forgetHeldState() {
        _ = releaseAll()
        lastPoint = nil
    }
}
