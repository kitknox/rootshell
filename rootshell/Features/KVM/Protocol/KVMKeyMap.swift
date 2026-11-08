//
//  KVMKeyMap.swift
//  rootshell
//
//  Key names kvmd accepts (web `KeyboardEvent.code`), from HID usages for
//  hardware keys and from X11 keysyms for everything else. The remote
//  computer receives physical key positions, so a printable keysym only
//  maps here for a US host layout; other layouts type text on the device.
//

import Foundation

nonisolated enum KVMKeyMap {
    struct Key: Equatable, Sendable {
        let code: String
        /// The character needs Shift on a US keyboard.
        let shifted: Bool
    }

    static let shiftCodes: Set<String> = ["ShiftLeft", "ShiftRight"]

    static func key(forKeysym keysym: UInt32) -> Key? {
        if let code = special[keysym] {
            return Key(code: code, shifted: false)
        }
        switch keysym {
        case 0x61...0x7A:
            return Key(code: "Key" + String(UnicodeScalar(UInt8(keysym - 0x20))), shifted: false)
        case 0x41...0x5A:
            return Key(code: "Key" + String(UnicodeScalar(UInt8(keysym))), shifted: true)
        case 0x30...0x39:
            return Key(code: "Digit" + String(UnicodeScalar(UInt8(keysym))), shifted: false)
        default:
            break
        }
        return punctuation[keysym]
    }

    static func isModifier(_ code: String) -> Bool {
        modifierCodes.contains(code)
    }

    /// USB HID keyboard usage (page 0x07) to its physical key name.
    static func code(forHIDUsage usage: UInt32) -> String? {
        switch usage {
        case 0x04...0x1D:
            return "Key" + String(UnicodeScalar(UInt8(0x41 + usage - 0x04)))
        case 0x1E...0x26:
            return "Digit\(usage - 0x1D)"
        case 0x27:
            return "Digit0"
        case 0x3A...0x45:
            return "F\(usage - 0x39)"
        case 0x59...0x61:
            return "Numpad\(usage - 0x58)"
        default:
            return hidUsageCodes[usage]
        }
    }

    private static let hidUsageCodes: [UInt32: String] = [
        0x28: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "Minus", 0x2E: "Equal", 0x2F: "BracketLeft", 0x30: "BracketRight",
        // ISO #~ shares the Backslash position code on every major host OS.
        0x31: "Backslash", 0x32: "Backslash",
        0x33: "Semicolon", 0x34: "Quote", 0x35: "Backquote", 0x36: "Comma",
        0x37: "Period", 0x38: "Slash", 0x39: "CapsLock",
        0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert",
        0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
        0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown", 0x52: "ArrowUp",
        0x53: "NumLock", 0x54: "NumpadDivide", 0x55: "NumpadMultiply",
        0x56: "NumpadSubtract", 0x57: "NumpadAdd", 0x58: "NumpadEnter",
        0x62: "Numpad0", 0x63: "NumpadDecimal", 0x64: "IntlBackslash",
        0x65: "ContextMenu", 0x66: "Power", 0x6F: "F20",
        0x7F: "AudioVolumeMute", 0x80: "AudioVolumeUp", 0x81: "AudioVolumeDown",
        0x87: "IntlRo", 0x88: "KanaMode", 0x89: "IntlYen", 0x8A: "Convert", 0x8B: "NonConvert",
        0xE0: "ControlLeft", 0xE1: "ShiftLeft", 0xE2: "AltLeft", 0xE3: "MetaLeft",
        0xE4: "ControlRight", 0xE5: "ShiftRight", 0xE6: "AltRight", 0xE7: "MetaRight",
    ]

    private static let modifierCodes: Set<String> = [
        "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
        "AltLeft", "AltRight", "MetaLeft", "MetaRight",
    ]

    private static let punctuation: [UInt32: Key] = [
        0x20: Key(code: "Space", shifted: false),
        0x21: Key(code: "Digit1", shifted: true),
        0x22: Key(code: "Quote", shifted: true),
        0x23: Key(code: "Digit3", shifted: true),
        0x24: Key(code: "Digit4", shifted: true),
        0x25: Key(code: "Digit5", shifted: true),
        0x26: Key(code: "Digit7", shifted: true),
        0x27: Key(code: "Quote", shifted: false),
        0x28: Key(code: "Digit9", shifted: true),
        0x29: Key(code: "Digit0", shifted: true),
        0x2A: Key(code: "Digit8", shifted: true),
        0x2B: Key(code: "Equal", shifted: true),
        0x2C: Key(code: "Comma", shifted: false),
        0x2D: Key(code: "Minus", shifted: false),
        0x2E: Key(code: "Period", shifted: false),
        0x2F: Key(code: "Slash", shifted: false),
        0x3A: Key(code: "Semicolon", shifted: true),
        0x3B: Key(code: "Semicolon", shifted: false),
        0x3C: Key(code: "Comma", shifted: true),
        0x3D: Key(code: "Equal", shifted: false),
        0x3E: Key(code: "Period", shifted: true),
        0x3F: Key(code: "Slash", shifted: true),
        0x40: Key(code: "Digit2", shifted: true),
        0x5B: Key(code: "BracketLeft", shifted: false),
        0x5C: Key(code: "Backslash", shifted: false),
        0x5D: Key(code: "BracketRight", shifted: false),
        0x5E: Key(code: "Digit6", shifted: true),
        0x5F: Key(code: "Minus", shifted: true),
        0x60: Key(code: "Backquote", shifted: false),
        0x7B: Key(code: "BracketLeft", shifted: true),
        0x7C: Key(code: "Backslash", shifted: true),
        0x7D: Key(code: "BracketRight", shifted: true),
        0x7E: Key(code: "Backquote", shifted: true),
        // ISO section key (left of 1 on Mac ISO layouts).
        0xA7: Key(code: "IntlBackslash", shifted: false),
        0xB1: Key(code: "IntlBackslash", shifted: true),
    ]

    private static let special: [UInt32: String] = {
        var map: [UInt32: String] = [
            0xFF08: "Backspace",
            0xFF09: "Tab",
            0xFE20: "Tab", // ISO_Left_Tab (Shift-Tab)
            0xFF0D: "Enter",
            0xFF13: "Pause",
            0xFF14: "ScrollLock",
            0xFF1B: "Escape",
            0xFF50: "Home",
            0xFF51: "ArrowLeft",
            0xFF52: "ArrowUp",
            0xFF53: "ArrowRight",
            0xFF54: "ArrowDown",
            0xFF55: "PageUp",
            0xFF56: "PageDown",
            0xFF57: "End",
            0xFF61: "PrintScreen",
            0xFF63: "Insert",
            0xFF67: "ContextMenu",
            0xFF7F: "NumLock",
            0xFFFF: "Delete",
            0xFFE5: "CapsLock",
            0xFFE1: "ShiftLeft",
            0xFFE2: "ShiftRight",
            0xFFE3: "ControlLeft",
            0xFFE4: "ControlRight",
            // Meta is Alt on X11 systems; Super is the GUI (Command/Windows) key.
            0xFFE7: "AltLeft",
            0xFFE8: "AltRight",
            0xFFE9: "AltLeft",
            0xFFEA: "AltRight",
            0xFFEB: "MetaLeft",
            0xFFEC: "MetaRight",
            0xFE03: "AltRight", // ISO_Level3_Shift (AltGr)
            // Keypad
            0xFF8D: "NumpadEnter",
            0xFFAA: "NumpadMultiply",
            0xFFAB: "NumpadAdd",
            0xFFAD: "NumpadSubtract",
            0xFFAE: "NumpadDecimal",
            0xFFAF: "NumpadDivide",
            0xFF95: "Numpad7",
            0xFF96: "Numpad4",
            0xFF97: "Numpad8",
            0xFF98: "Numpad6",
            0xFF99: "Numpad2",
            0xFF9A: "Numpad9",
            0xFF9B: "Numpad3",
            0xFF9C: "Numpad1",
            0xFF9D: "Numpad5",
            0xFF9E: "Numpad0",
            0xFF9F: "NumpadDecimal",
            // XF86 media and power keys
            0x1008FF12: "AudioVolumeMute",
            0x1008FF11: "AudioVolumeDown",
            0x1008FF13: "AudioVolumeUp",
            0x1008FF2A: "Power",
        ]
        for index in 0..<10 {
            map[0xFFB0 + UInt32(index)] = "Numpad\(index)"
        }
        for index in 0..<12 {
            map[0xFFBE + UInt32(index)] = "F\(index + 1)"
        }
        map[0xFFD1] = "F20"
        return map
    }()
}
