//
//  VNCPreDisconnectAction.swift
//  rootshell
//
//  What a Screen Sharing connection does on the remote computer just before
//  the user closes it. Saved per connection in VNCConnectionConfig.
//

import Foundation

/// A key chord sent to the remote computer.
nonisolated struct VNCPreDisconnectShortcut: Codable, Hashable, Sendable {

    /// Keys without a printable character. Raw values are persisted and are
    /// all longer than one character, so they never collide with a typed key.
    nonisolated enum SpecialKey: String, CaseIterable, Sendable {
        case escape, delete, forwardDelete, `return`, tab, space
        case upArrow, downArrow, leftArrow, rightArrow
        case home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

        var displayName: String {
            switch self {
            case .escape: return String(localized: "Escape", comment: "Keyboard key name")
            case .delete: return String(localized: "Delete", comment: "Keyboard key name")
            case .forwardDelete: return String(localized: "Forward Delete", comment: "Keyboard key name")
            case .return: return String(localized: "Return", comment: "Keyboard key name")
            case .tab: return String(localized: "Tab", comment: "Keyboard key name")
            case .space: return String(localized: "Space", comment: "Keyboard key name")
            case .upArrow: return String(localized: "Up Arrow", comment: "Keyboard key name")
            case .downArrow: return String(localized: "Down Arrow", comment: "Keyboard key name")
            case .leftArrow: return String(localized: "Left Arrow", comment: "Keyboard key name")
            case .rightArrow: return String(localized: "Right Arrow", comment: "Keyboard key name")
            case .home: return String(localized: "Home", comment: "Keyboard key name")
            case .end: return String(localized: "End", comment: "Keyboard key name")
            case .pageUp: return String(localized: "Page Up", comment: "Keyboard key name")
            case .pageDown: return String(localized: "Page Down", comment: "Keyboard key name")
            default: return rawValue.uppercased()
            }
        }
    }

    var control = false
    var option = false
    var shift = false
    var command = false

    /// One typed character, or a `SpecialKey` raw value.
    var key = ""

    var specialKey: SpecialKey? { SpecialKey(rawValue: key) }

    /// The typed character, when the key is not a special key.
    var character: Character? {
        guard specialKey == nil, key.count == 1 else { return nil }
        return key.first
    }

    var isValid: Bool { specialKey != nil || character != nil }

    /// "⌃⌥⇧⌘Q" style label.
    var displayName: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        if let specialKey {
            text += specialKey.displayName
        } else {
            text += key.uppercased()
        }
        return text
    }

    private enum CodingKeys: String, CodingKey {
        case control, option, shift, command, key
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false
        }
        control = flag(.control)
        option = flag(.option)
        shift = flag(.shift)
        command = flag(.command)
        key = ((try? container.decodeIfPresent(String.self, forKey: .key)) ?? nil) ?? ""
    }
}

/// The action a Screen Sharing connection runs before an intentional
/// disconnect. Fields that the selected `kind` does not use stay at their
/// defaults.
nonisolated struct VNCPreDisconnectAction: Codable, Hashable, Sendable {

    /// Raw values are persisted.
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case none
        case lockScreen
        case logOut
        case controlAltDelete
        case shortcut
        case command

        var displayName: String {
            switch self {
            case .none:
                return String(localized: "None", comment: "Screen Sharing pre-disconnect action")
            case .lockScreen:
                return String(localized: "Lock Screen", comment: "Screen Sharing pre-disconnect action")
            case .logOut:
                return String(localized: "Log Out Remote User", comment: "Screen Sharing pre-disconnect action")
            case .controlAltDelete:
                return String(localized: "Send Ctrl-Alt-Del", comment: "Screen Sharing pre-disconnect action")
            case .shortcut:
                return String(localized: "Keyboard Shortcut", comment: "Screen Sharing pre-disconnect action")
            case .command:
                return String(localized: "Run Command", comment: "Screen Sharing pre-disconnect action")
            }
        }
    }

    var kind: Kind = .none

    /// Chord for `.shortcut`.
    var shortcut = VNCPreDisconnectShortcut()

    /// Shell command for `.command`, run in the remote user's login shell.
    var command = ""

    /// SSH profile `.command` runs through.
    var sshProfileID: UUID?

    var isEnabled: Bool { kind != .none }

    private enum CodingKeys: String, CodingKey {
        case kind, shortcut, command, sshProfileID
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind written by a newer build degrades to no action.
        let kindRaw = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = kindRaw.flatMap(Kind.init(rawValue:)) ?? .none
        shortcut = ((try? container.decodeIfPresent(
            VNCPreDisconnectShortcut.self, forKey: .shortcut)) ?? nil) ?? VNCPreDisconnectShortcut()
        command = ((try? container.decodeIfPresent(String.self, forKey: .command)) ?? nil) ?? ""
        sshProfileID = (try? container.decodeIfPresent(UUID.self, forKey: .sshProfileID)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch kind {
        case .shortcut:
            try container.encode(shortcut, forKey: .shortcut)
        case .command:
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(sshProfileID, forKey: .sshProfileID)
        case .none, .lockScreen, .logOut, .controlAltDelete:
            break
        }
    }

    /// The action with only the fields its kind uses, so equal choices
    /// compare and encode equal.
    var normalized: VNCPreDisconnectAction {
        var result = VNCPreDisconnectAction()
        result.kind = kind
        switch kind {
        case .shortcut:
            result.shortcut = shortcut
        case .command:
            result.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            result.sshProfileID = sshProfileID
        case .none, .lockScreen, .logOut, .controlAltDelete:
            break
        }
        return result
    }
}
