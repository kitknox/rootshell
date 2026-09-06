//
//  KeyTrigger.swift
//  rootshell
//
//  Key trigger representation with modifiers and key codes
//

import UIKit
import SwiftUI

// MARK: - Keybind Modifiers

/// Modifier flags for keybind shortcuts (distinct from Keyboard/KeyModifiers)
struct KeybindModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let shift = KeybindModifiers(rawValue: 1 << 0)
    static let control = KeybindModifiers(rawValue: 1 << 1)
    static let option = KeybindModifiers(rawValue: 1 << 2)  // alt on ghostty
    static let command = KeybindModifiers(rawValue: 1 << 3)  // super on ghostty

    /// Convert to UIKeyModifierFlags
    var uiModifierFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Initialize from UIKeyModifierFlags
    init(uiModifierFlags: UIKeyModifierFlags) {
        var raw: UInt8 = 0
        if uiModifierFlags.contains(.shift) { raw |= KeybindModifiers.shift.rawValue }
        if uiModifierFlags.contains(.control) { raw |= KeybindModifiers.control.rawValue }
        if uiModifierFlags.contains(.alternate) { raw |= KeybindModifiers.option.rawValue }
        if uiModifierFlags.contains(.command) { raw |= KeybindModifiers.command.rawValue }
        self.rawValue = raw
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Parse from ghostty config format: "cmd+shift" or "ctrl+alt"
    init?(ghosttyFormat: String) {
        var raw: UInt8 = 0
        let parts = ghosttyFormat.lowercased().components(separatedBy: "+")
        for part in parts {
            switch part {
            case "shift":
                raw |= KeybindModifiers.shift.rawValue
            case "ctrl", "control":
                raw |= KeybindModifiers.control.rawValue
            case "alt", "opt", "option":
                raw |= KeybindModifiers.option.rawValue
            case "cmd", "command", "super":
                raw |= KeybindModifiers.command.rawValue
            default:
                // Unknown modifier or it's the key itself - skip
                continue
            }
        }
        self.rawValue = raw
    }

    /// Convert to ghostty config format (sorted for consistency)
    var ghosttyFormat: String {
        var parts: [String] = []
        if contains(.control) { parts.append("ctrl") }
        if contains(.option) { parts.append("alt") }
        if contains(.shift) { parts.append("shift") }
        if contains(.command) { parts.append("cmd") }
        return parts.joined(separator: "+")
    }

    /// Human-readable display format
    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("Ctrl") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Cmd") }
        return parts.joined(separator: "+")
    }

    /// Mac-style symbol format (⌘⇧⌥⌃)
    var symbolString: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }
}

// MARK: - Key Code

/// Key codes matching ghostty's W3C-based key codes
enum KeyCode: String, Codable, CaseIterable, Hashable, Sendable {
    // Letters
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Numbers
    case digit0 = "0"
    case digit1 = "1"
    case digit2 = "2"
    case digit3 = "3"
    case digit4 = "4"
    case digit5 = "5"
    case digit6 = "6"
    case digit7 = "7"
    case digit8 = "8"
    case digit9 = "9"

    // Symbols (US keyboard layout)
    case minus = "-"
    case equal = "="
    case leftBracket = "["
    case rightBracket = "]"
    case backslash = "\\"
    case semicolon = ";"
    case quote = "'"
    case comma = ","
    case period = "."
    case slash = "/"
    case grave = "`"

    // Special keys
    case tab
    case escape
    case enter
    case space
    case backspace
    case delete

    // Navigation
    case up = "arrow_up"
    case down = "arrow_down"
    case left = "arrow_left"
    case right = "arrow_right"
    case home
    case end
    case pageUp = "page_up"
    case pageDown = "page_down"

    // Function keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    // Additional symbols that need shift on US keyboard
    case plus = "+"
    case underscore = "_"
    case leftBrace = "{"
    case rightBrace = "}"
    case pipe = "|"
    case colon = ":"
    case doubleQuote = "\""
    case lessThan = "<"
    case greaterThan = ">"
    case questionMark = "?"
    case tilde = "~"

    /// Map to UIKeyCommand input string
    var uiKeyInput: String {
        switch self {
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        case .e: return "e"
        case .f: return "f"
        case .g: return "g"
        case .h: return "h"
        case .i: return "i"
        case .j: return "j"
        case .k: return "k"
        case .l: return "l"
        case .m: return "m"
        case .n: return "n"
        case .o: return "o"
        case .p: return "p"
        case .q: return "q"
        case .r: return "r"
        case .s: return "s"
        case .t: return "t"
        case .u: return "u"
        case .v: return "v"
        case .w: return "w"
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"

        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"

        case .minus: return "-"
        case .equal: return "="
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .backslash: return "\\"
        case .semicolon: return ";"
        case .quote: return "'"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .grave: return "`"

        case .plus: return "+"
        case .underscore: return "_"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .pipe: return "|"
        case .colon: return ":"
        case .doubleQuote: return "\""
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .questionMark: return "?"
        case .tilde: return "~"

        case .tab: return "\t"
        case .escape: return UIKeyCommand.inputEscape
        case .enter: return "\r"
        case .space: return " "
        case .backspace: return "\u{08}"
        case .delete: return UIKeyCommand.inputDelete

        case .up: return UIKeyCommand.inputUpArrow
        case .down: return UIKeyCommand.inputDownArrow
        case .left: return UIKeyCommand.inputLeftArrow
        case .right: return UIKeyCommand.inputRightArrow
        case .home: return UIKeyCommand.inputHome
        case .end: return UIKeyCommand.inputEnd
        case .pageUp: return UIKeyCommand.inputPageUp
        case .pageDown: return UIKeyCommand.inputPageDown

        case .f1: return UIKeyCommand.f1
        case .f2: return UIKeyCommand.f2
        case .f3: return UIKeyCommand.f3
        case .f4: return UIKeyCommand.f4
        case .f5: return UIKeyCommand.f5
        case .f6: return UIKeyCommand.f6
        case .f7: return UIKeyCommand.f7
        case .f8: return UIKeyCommand.f8
        case .f9: return UIKeyCommand.f9
        case .f10: return UIKeyCommand.f10
        case .f11: return UIKeyCommand.f11
        case .f12: return UIKeyCommand.f12
        }
    }

    /// UIKit's "UIKeyInput*" sentinels. They can arrive in `UIKey.characters`
    /// for a translated chord and must never reach a terminal as literal text.
    /// Derived from `uiKeyInput` so the two cannot drift apart.
    static let uiKeyInputSentinels: [String: KeyCode] = Dictionary(
        allCases
            .filter { $0.uiKeyInput.hasPrefix("UIKeyInput") }
            .map { ($0.uiKeyInput, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The key a UIKit sentinel denotes, or nil when `text` is real text.
    /// Matched exactly, never by prefix: `insertText` also receives pasted text.
    static func sentinelKey(for text: String) -> KeyCode? {
        uiKeyInputSentinels[text]
    }

    static func isUIKeyInputSentinel(_ text: String) -> Bool {
        uiKeyInputSentinels[text] != nil
    }

    /// `uiKeyInput` when it is real text; nil for sentinels.
    var literalKeyInput: String? {
        KeyCode.isUIKeyInputSentinel(uiKeyInput) ? nil : uiKeyInput
    }

    /// Initialize from UIKeyboardHIDUsage
    init?(hidUsage: UIKeyboardHIDUsage) {
        switch hidUsage {
        case .keyboardA: self = .a
        case .keyboardB: self = .b
        case .keyboardC: self = .c
        case .keyboardD: self = .d
        case .keyboardE: self = .e
        case .keyboardF: self = .f
        case .keyboardG: self = .g
        case .keyboardH: self = .h
        case .keyboardI: self = .i
        case .keyboardJ: self = .j
        case .keyboardK: self = .k
        case .keyboardL: self = .l
        case .keyboardM: self = .m
        case .keyboardN: self = .n
        case .keyboardO: self = .o
        case .keyboardP: self = .p
        case .keyboardQ: self = .q
        case .keyboardR: self = .r
        case .keyboardS: self = .s
        case .keyboardT: self = .t
        case .keyboardU: self = .u
        case .keyboardV: self = .v
        case .keyboardW: self = .w
        case .keyboardX: self = .x
        case .keyboardY: self = .y
        case .keyboardZ: self = .z

        case .keyboard0: self = .digit0
        case .keyboard1: self = .digit1
        case .keyboard2: self = .digit2
        case .keyboard3: self = .digit3
        case .keyboard4: self = .digit4
        case .keyboard5: self = .digit5
        case .keyboard6: self = .digit6
        case .keyboard7: self = .digit7
        case .keyboard8: self = .digit8
        case .keyboard9: self = .digit9

        case .keyboardHyphen: self = .minus
        case .keyboardEqualSign: self = .equal
        case .keyboardOpenBracket: self = .leftBracket
        case .keyboardCloseBracket: self = .rightBracket
        case .keyboardBackslash: self = .backslash
        case .keyboardSemicolon: self = .semicolon
        case .keyboardQuote: self = .quote
        case .keyboardComma: self = .comma
        case .keyboardPeriod: self = .period
        case .keyboardSlash: self = .slash
        case .keyboardGraveAccentAndTilde: self = .grave

        case .keyboardTab: self = .tab
        case .keyboardEscape: self = .escape
        case .keyboardReturnOrEnter: self = .enter
        case .keyboardSpacebar: self = .space
        case .keyboardDeleteOrBackspace: self = .backspace
        case .keyboardDeleteForward: self = .delete

        case .keyboardUpArrow: self = .up
        case .keyboardDownArrow: self = .down
        case .keyboardLeftArrow: self = .left
        case .keyboardRightArrow: self = .right
        case .keyboardHome: self = .home
        case .keyboardEnd: self = .end
        case .keyboardPageUp: self = .pageUp
        case .keyboardPageDown: self = .pageDown

        case .keyboardF1: self = .f1
        case .keyboardF2: self = .f2
        case .keyboardF3: self = .f3
        case .keyboardF4: self = .f4
        case .keyboardF5: self = .f5
        case .keyboardF6: self = .f6
        case .keyboardF7: self = .f7
        case .keyboardF8: self = .f8
        case .keyboardF9: self = .f9
        case .keyboardF10: self = .f10
        case .keyboardF11: self = .f11
        case .keyboardF12: self = .f12

        default:
            return nil
        }
    }

    /// Initialize from UIKeyCommand input string
    init?(uiKeyInput: String) {
        switch uiKeyInput.lowercased() {
        case "a": self = .a
        case "b": self = .b
        case "c": self = .c
        case "d": self = .d
        case "e": self = .e
        case "f": self = .f
        case "g": self = .g
        case "h": self = .h
        case "i": self = .i
        case "j": self = .j
        case "k": self = .k
        case "l": self = .l
        case "m": self = .m
        case "n": self = .n
        case "o": self = .o
        case "p": self = .p
        case "q": self = .q
        case "r": self = .r
        case "s": self = .s
        case "t": self = .t
        case "u": self = .u
        case "v": self = .v
        case "w": self = .w
        case "x": self = .x
        case "y": self = .y
        case "z": self = .z

        case "0": self = .digit0
        case "1": self = .digit1
        case "2": self = .digit2
        case "3": self = .digit3
        case "4": self = .digit4
        case "5": self = .digit5
        case "6": self = .digit6
        case "7": self = .digit7
        case "8": self = .digit8
        case "9": self = .digit9

        case "-": self = .minus
        case "=": self = .equal
        case "[": self = .leftBracket
        case "]": self = .rightBracket
        case "\\": self = .backslash
        case ";": self = .semicolon
        case "'": self = .quote
        case ",": self = .comma
        case ".": self = .period
        case "/": self = .slash
        case "`": self = .grave

        case "+": self = .plus
        case "_": self = .underscore
        case "{": self = .leftBrace
        case "}": self = .rightBrace
        case "|": self = .pipe
        case ":": self = .colon
        case "\"": self = .doubleQuote
        case "<": self = .lessThan
        case ">": self = .greaterThan
        case "?": self = .questionMark
        case "~": self = .tilde

        case "\t": self = .tab
        case "\r": self = .enter
        case " ": self = .space
        case "\u{08}": self = .backspace

        default:
            // UIKeyCommand constants ("UIKeyInputEscape" and friends). The
            // derived table also covers Delete and F1-F12, which the old
            // hand-rolled chain missed.
            guard let key = KeyCode.sentinelKey(for: uiKeyInput) else { return nil }
            self = key
        }
    }

    /// Parse from ghostty config format
    init?(ghosttyFormat: String) {
        let lower = ghosttyFormat.lowercased()

        // Check explicit key names first
        switch lower {
        // Special keys
        case "tab": self = .tab
        case "escape", "esc": self = .escape
        case "enter", "return": self = .enter
        case "space": self = .space
        case "backspace": self = .backspace
        case "delete": self = .delete

        // Navigation
        case "arrow_up", "up": self = .up
        case "arrow_down", "down": self = .down
        case "arrow_left", "left": self = .left
        case "arrow_right", "right": self = .right
        case "home": self = .home
        case "end": self = .end
        case "page_up", "pageup": self = .pageUp
        case "page_down", "pagedown": self = .pageDown

        // Symbol key names (Ghostty canonical + legacy 1.1.x aliases)
        case "semicolon": self = .semicolon
        case "quote", "apostrophe": self = .quote
        case "comma": self = .comma
        case "period": self = .period
        case "slash": self = .slash
        case "minus": self = .minus
        case "equal": self = .equal
        case "plus": self = .plus
        case "bracket_left", "left_bracket": self = .leftBracket
        case "bracket_right", "right_bracket": self = .rightBracket
        case "backslash": self = .backslash
        case "backquote", "grave_accent": self = .grave

        // Function keys
        case "f1": self = .f1
        case "f2": self = .f2
        case "f3": self = .f3
        case "f4": self = .f4
        case "f5": self = .f5
        case "f6": self = .f6
        case "f7": self = .f7
        case "f8": self = .f8
        case "f9": self = .f9
        case "f10": self = .f10
        case "f11": self = .f11
        case "f12": self = .f12

        default:
            // Try single character
            if lower.count == 1, let char = lower.first {
                if let keyCode = KeyCode(uiKeyInput: String(char)) {
                    self = keyCode
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
    }

    /// Convert to ghostty config format
    var ghosttyFormat: String {
        switch self {
        case .tab: return "tab"
        case .escape: return "escape"
        case .enter: return "enter"
        case .space: return "space"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .up: return "arrow_up"
        case .down: return "arrow_down"
        case .left: return "arrow_left"
        case .right: return "arrow_right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "page_up"
        case .pageDown: return "page_down"
        case .f1: return "f1"
        case .f2: return "f2"
        case .f3: return "f3"
        case .f4: return "f4"
        case .f5: return "f5"
        case .f6: return "f6"
        case .f7: return "f7"
        case .f8: return "f8"
        case .f9: return "f9"
        case .f10: return "f10"
        case .f11: return "f11"
        case .f12: return "f12"

        // Symbol keys: emit canonical Ghostty names so libghostty's parser
        // (Binding.zig) maps them to physical key codes instead of falling back
        // to single-character Unicode bindings.
        case .period: return "period"
        case .comma: return "comma"
        case .semicolon: return "semicolon"
        case .slash: return "slash"
        case .minus: return "minus"
        case .equal: return "equal"
        case .leftBracket: return "bracket_left"
        case .rightBracket: return "bracket_right"
        case .backslash: return "backslash"
        case .quote: return "quote"
        case .grave: return "backquote"

        default:
            return rawValue
        }
    }

    /// Human-readable display string
    var displayString: String {
        switch self {
        case .tab: return "Tab"
        case .escape: return "Esc"
        case .enter: return "Return"
        case .space: return "Space"
        case .backspace: return "Backspace"
        case .delete: return "Delete"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return rawValue.uppercased()
        default:
            return rawValue.uppercased()
        }
    }
}

// MARK: - Key Trigger

/// Represents a single keyboard shortcut trigger (modifiers + key)
struct KeyTrigger: Codable, Hashable, CustomStringConvertible, Sendable {
    let key: KeyCode
    let modifiers: KeybindModifiers

    /// The chord Apple platforms reserve as the system Cancel/Escape shortcut.
    static let commandPeriod = KeyTrigger(key: .period, modifiers: .command)

    init(key: KeyCode, modifiers: KeybindModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Symbol spelling of a shifted physical trigger. The keybind system uses
    /// US physical key identities; menu bindings can instead spell Shift+[ as
    /// "{". Do not use the IME-produced characters to resolve these shortcuts.
    var shiftedSymbolEquivalent: KeyTrigger? {
        guard modifiers.contains(.shift) else { return nil }
        let symbol: KeyCode
        switch key {
        case .equal: symbol = .plus
        case .minus: symbol = .underscore
        case .leftBracket: symbol = .leftBrace
        case .rightBracket: symbol = .rightBrace
        case .backslash: symbol = .pipe
        case .semicolon: symbol = .colon
        case .quote: symbol = .doubleQuote
        case .comma: symbol = .lessThan
        case .period: symbol = .greaterThan
        case .slash: symbol = .questionMark
        case .grave: symbol = .tilde
        default: return nil
        }
        return KeyTrigger(key: symbol, modifiers: modifiers.subtracting(.shift))
    }

    /// Parse from ghostty config format: "cmd+shift+d" or "ctrl+a"
    init?(ghosttyFormat: String) {
        let parts = ghosttyFormat.lowercased().components(separatedBy: "+")
        guard !parts.isEmpty else { return nil }

        // Last part is the key (usually)
        // But we need to handle cases like "cmd++" where + is the key
        var keyPart: String?
        var modParts: [String] = []

        for part in parts {
            if KeyCode(ghosttyFormat: part) != nil && keyPart == nil {
                // Could be key or modifier
                if ["shift", "ctrl", "control", "alt", "opt", "option", "cmd", "command", "super"].contains(part) {
                    modParts.append(part)
                } else {
                    keyPart = part
                }
            } else if ["shift", "ctrl", "control", "alt", "opt", "option", "cmd", "command", "super"].contains(part) {
                modParts.append(part)
            } else if keyPart == nil {
                keyPart = part
            }
        }

        // If no key found, the last part is the key
        if keyPart == nil && !parts.isEmpty {
            keyPart = parts.last
        }

        guard let kp = keyPart, let key = KeyCode(ghosttyFormat: kp) else {
            return nil
        }

        self.key = key
        self.modifiers = KeybindModifiers(ghosttyFormat: modParts.joined(separator: "+")) ?? []
    }

    /// Convert to ghostty config format
    var ghosttyFormat: String {
        if modifiers.isEmpty {
            return key.ghosttyFormat
        }
        return "\(modifiers.ghosttyFormat)+\(key.ghosttyFormat)"
    }

    /// Convert to UIKeyModifierFlags
    var uiModifierFlags: UIKeyModifierFlags {
        modifiers.uiModifierFlags
    }

    /// Convert to UIKeyCommand input string
    var uiKeyInput: String {
        key.uiKeyInput
    }

    /// Human-readable display: "Cmd+Shift+D"
    var description: String {
        if modifiers.isEmpty {
            return key.displayString
        }
        return "\(modifiers.displayString)+\(key.displayString)"
    }

    /// Mac-style symbol format: "⌘⇧D"
    var symbolDescription: String {
        "\(modifiers.symbolString)\(key.displayString)"
    }

    /// Create from UIKeyCommand
    init?(uiKeyCommand: UIKeyCommand) {
        guard let input = uiKeyCommand.input,
              let key = KeyCode(uiKeyInput: input) else {
            return nil
        }
        self.key = key
        self.modifiers = KeybindModifiers(uiModifierFlags: uiKeyCommand.modifierFlags)
    }

    /// Create from UIPress
    init?(press: UIPress) {
        guard let uiKey = press.key,
              let key = KeyCode(hidUsage: uiKey.keyCode) else {
            return nil
        }
        self.key = key
        self.modifiers = KeybindModifiers(uiModifierFlags: uiKey.modifierFlags)
    }

    /// Convert to SwiftUI KeyEquivalent for menu keyboard shortcuts
    var swiftUIKeyEquivalent: KeyEquivalent? {
        switch key {
        // Arrow keys
        case .up: return .upArrow
        case .down: return .downArrow
        case .left: return .leftArrow
        case .right: return .rightArrow

        // Special keys
        case .tab: return .tab
        case .escape: return .escape
        case .enter: return .return
        case .space: return .space
        case .delete: return .delete
        case .backspace: return .delete
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown

        // Regular characters - use the uiKeyInput string
        default:
            guard let char = uiKeyInput.first else { return nil }
            return KeyEquivalent(char)
        }
    }

    /// Convert to SwiftUI EventModifiers for keyboard shortcuts
    var swiftUIEventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}
