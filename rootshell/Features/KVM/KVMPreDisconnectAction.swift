//
//  KVMPreDisconnectAction.swift
//  rootshell
//
//  What a KVM connection presses on the remote computer just before the user
//  closes it. Saved per connection in KVMConnectionConfig.
//

import Foundation

/// A key chord a KVM connection sends before an intentional disconnect. The
/// device can't tell the remote OS, so OS-specific kinds say which in their
/// name. Fields the selected `kind` does not use stay at their defaults.
nonisolated struct KVMPreDisconnectAction: Codable, Hashable, Sendable {

    /// Raw values are persisted.
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case none
        case sleepDisplayMac
        case lockScreenMac
        case lockScreenPC
        case logOutMac
        case controlAltDelete
        case shortcut

        var displayName: String {
            switch self {
            case .none:
                return String(localized: "None", comment: "KVM pre-disconnect action")
            case .sleepDisplayMac:
                return String(localized: "Sleep Display (Mac)", comment: "KVM pre-disconnect action")
            case .lockScreenMac:
                return String(localized: "Lock Screen (Mac)", comment: "KVM pre-disconnect action")
            case .lockScreenPC:
                return String(localized: "Lock Screen (Windows, Linux)", comment: "KVM pre-disconnect action")
            case .logOutMac:
                return String(localized: "Log Out (Mac)", comment: "KVM pre-disconnect action")
            case .controlAltDelete:
                return String(localized: "Send Ctrl-Alt-Del", comment: "KVM pre-disconnect action")
            case .shortcut:
                return String(localized: "Keyboard Shortcut", comment: "KVM pre-disconnect action")
            }
        }
    }

    nonisolated enum Failure: LocalizedError {
        case notConnected
        case inputBusy
        case invalidShortcut

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return String(localized: "The KVM connection is not active, so the keys could not be sent.")
            case .inputBusy:
                return String(localized: "The KVM was still sending earlier input, so the keys were not sent.")
            case .invalidShortcut:
                return String(localized: "The saved keyboard shortcut can't be typed with the computer's keyboard layout.")
            }
        }
    }

    var kind: Kind = .none

    /// Chord for `.shortcut`.
    var shortcut = VNCPreDisconnectShortcut()

    var isEnabled: Bool { kind != .none }

    private enum CodingKeys: String, CodingKey {
        case kind, shortcut
    }

    init(kind: Kind = .none, shortcut: VNCPreDisconnectShortcut = VNCPreDisconnectShortcut()) {
        self.kind = kind
        self.shortcut = shortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind written by a newer build degrades to no action.
        let kindRaw = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = kindRaw.flatMap(Kind.init(rawValue:)) ?? .none
        shortcut = ((try? container.decodeIfPresent(
            VNCPreDisconnectShortcut.self, forKey: .shortcut)) ?? nil) ?? VNCPreDisconnectShortcut()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        if kind == .shortcut {
            try container.encode(shortcut, forKey: .shortcut)
        }
    }

    /// The action with only the fields its kind uses.
    var normalized: KVMPreDisconnectAction {
        KVMPreDisconnectAction(kind: kind, shortcut: kind == .shortcut ? shortcut : VNCPreDisconnectShortcut())
    }

    /// kvmd key names in press order; released in reverse. Letters are
    /// placed for the host's kvmd `layout`, since the device sends positions.
    func keyCodes(layout: String) throws -> [String] {
        func letter(_ character: Character) throws -> String {
            guard let code = Self.letterCode(character, layout: layout) else { throw Failure.invalidShortcut }
            return code
        }
        switch kind {
        case .none: return []
        // macOS sleeps the displays on Control-Shift-Power.
        case .sleepDisplayMac: return ["ControlLeft", "ShiftLeft", "Power"]
        case .lockScreenMac: return ["ControlLeft", "MetaLeft", try letter("q")]
        case .lockScreenPC: return ["MetaLeft", try letter("l")]
        // With Option the Mac logs out without its confirmation dialog.
        case .logOutMac: return ["ShiftLeft", "AltLeft", "MetaLeft", try letter("q")]
        case .controlAltDelete: return ["ControlLeft", "AltLeft", "Delete"]
        case .shortcut: return try Self.keyCodes(for: shortcut, layout: layout)
        }
    }

    static func keyCodes(for shortcut: VNCPreDisconnectShortcut, layout: String) throws -> [String] {
        let key: KVMKeyMap.Key
        if let special = shortcut.specialKey {
            key = KVMKeyMap.Key(code: code(for: special), shifted: false)
        } else if let character = shortcut.character?.lowercased().first,
                  let code = letterCode(character, layout: layout) ?? digitCode(character, layout: layout) {
            key = KVMKeyMap.Key(code: code, shifted: false)
        } else if usPunctuationLayouts.contains(layout),
                  let scalar = shortcut.character?.unicodeScalars.first, scalar.value <= 0x7E,
                  let mapped = KVMKeyMap.key(forKeysym: scalar.value) {
            key = mapped
        } else {
            throw Failure.invalidShortcut
        }
        var codes: [String] = []
        if shortcut.control { codes.append("ControlLeft") }
        if shortcut.option { codes.append("AltLeft") }
        if shortcut.shift || key.shifted { codes.append("ShiftLeft") }
        if shortcut.command { codes.append("MetaLeft") }
        codes.append(key.code)
        return codes
    }

    /// Physical key for a lowercase ASCII letter on a kvmd layout. Layouts
    /// without Latin letters (ar, mk, ru, th) keep US positions: shortcuts
    /// there resolve through QWERTY.
    static func letterCode(_ letter: Character, layout: String) -> String? {
        guard let ascii = letter.asciiValue, (0x61...0x7A).contains(ascii) else { return nil }
        return movedKeys[layout]?[letter] ?? "Key" + letter.uppercased()
    }

    /// Physical key for an unshifted digit, or nil where the layout needs Shift.
    static func digitCode(_ digit: Character, layout: String) -> String? {
        guard let ascii = digit.asciiValue, (0x30...0x39).contains(ascii),
              !shiftedDigitLayouts.contains(layout) else { return nil }
        return movedKeys[layout]?[digit] ?? "Digit" + String(digit)
    }

    // Unshifted letters and digits off their US key, from kvmd's
    // contrib/keymaps. kvmd's "bepo" is xkb's French Dvorak.
    private static let movedKeys: [String: [Character: String]] = {
        let azerty: [Character: String] = ["a": "KeyQ", "q": "KeyA", "z": "KeyW", "w": "KeyZ", "m": "Semicolon"]
        let qwertz: [Character: String] = ["y": "KeyZ", "z": "KeyY"]
        return [
            "fr": azerty, "fr-be": azerty,
            "de": qwertz, "de-ch": qwertz, "fr-ch": qwertz, "cz": qwertz, "hr": qwertz,
            "hu": qwertz.merging(["0": "Backquote"]) { $1 },
            "tr": ["i": "Quote"],
            "bepo": [
                "a": "KeyS", "b": "KeyG", "c": "KeyI", "d": "Semicolon", "e": "KeyF", "f": "KeyH",
                "g": "KeyR", "h": "KeyY", "i": "KeyV", "j": "Slash", "k": "KeyP", "l": "Comma",
                "m": "KeyO", "n": "KeyL", "o": "KeyA", "p": "Period", "q": "KeyX", "r": "KeyM",
                "s": "KeyJ", "t": "KeyK", "u": "KeyD", "v": "KeyU", "w": "Quote", "x": "KeyN",
                "y": "KeyB", "z": "BracketLeft",
            ],
        ]
    }()

    private static let shiftedDigitLayouts: Set<String> = ["bepo", "cz", "fr", "fr-be", "lt", "th"]

    /// Layouts whose punctuation matches `KVMKeyMap`'s US table.
    private static let usPunctuationLayouts: Set<String> = [KVMInputTranslator.usLayout, "en-us-altgr-intl"]

    private static func code(for key: VNCPreDisconnectShortcut.SpecialKey) -> String {
        switch key {
        case .escape: return "Escape"
        case .delete: return "Backspace"
        case .forwardDelete: return "Delete"
        case .return: return "Enter"
        case .tab: return "Tab"
        case .space: return "Space"
        case .upArrow: return "ArrowUp"
        case .downArrow: return "ArrowDown"
        case .leftArrow: return "ArrowLeft"
        case .rightArrow: return "ArrowRight"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return key.rawValue.uppercased()
        }
    }
}
