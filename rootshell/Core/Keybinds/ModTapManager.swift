//
//  ModTapManager.swift
//  rootshell
//
//  Data models and persistence for mod-tap key behavior.
//  Mod-tap: a key does one thing on tap, another on hold.
//  Common use case: Caps Lock = Escape on tap, Control on hold.
//

import Foundation
import UIKit
import Observation
import os

// MARK: - Data Models

/// The modifier activated when a mod-tap key is held
enum ModTapModifier: String, Codable, CaseIterable, Sendable {
    case control
    case alt
    case shift
    case command

    var displayName: String {
        switch self {
        case .control: return String(localized: "Control", comment: "Mod-tap modifier: control key")
        case .alt: return String(localized: "Option", comment: "Mod-tap modifier: option key")
        case .shift: return String(localized: "Shift", comment: "Mod-tap modifier: shift key")
        case .command: return String(localized: "Command", comment: "Mod-tap modifier: command key")
        }
    }

    var uiKeyModifierFlag: UIKeyModifierFlags {
        switch self {
        case .control: return .control
        case .alt: return .alternate
        case .shift: return .shift
        case .command: return .command
        }
    }
}

/// Predefined key actions for mod-tap tap behavior
enum ModTapKeyAction: String, Codable, CaseIterable, Hashable, Sendable {
    // Special keys
    case escape
    case backspace
    case enter
    case tab
    case space
    case deleteForward

    // Navigation keys
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown

    enum Category: String, CaseIterable, Sendable {
        case special
        case navigation

        var displayName: String {
            switch self {
            case .special: return String(localized: "Special Keys", comment: "Mod-tap key category: special keys")
            case .navigation: return String(localized: "Navigation", comment: "Mod-tap key category: navigation keys")
            }
        }
    }

    var category: Category {
        switch self {
        case .escape, .backspace, .enter, .tab, .space, .deleteForward:
            return .special
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .home, .end, .pageUp, .pageDown:
            return .navigation
        }
    }

    var displayName: String {
        switch self {
        case .escape: return String(localized: "Escape", comment: "Mod-tap key action: escape")
        case .backspace: return String(localized: "Backspace", comment: "Mod-tap key action: backspace")
        case .enter: return String(localized: "Return", comment: "Mod-tap key action: return")
        case .tab: return String(localized: "Tab", comment: "Mod-tap key action: tab")
        case .space: return String(localized: "Space", comment: "Mod-tap key action: space")
        case .deleteForward: return String(localized: "Delete Forward", comment: "Mod-tap key action: delete forward")
        case .arrowUp: return String(localized: "Arrow Up", comment: "Mod-tap key action: arrow up")
        case .arrowDown: return String(localized: "Arrow Down", comment: "Mod-tap key action: arrow down")
        case .arrowLeft: return String(localized: "Arrow Left", comment: "Mod-tap key action: arrow left")
        case .arrowRight: return String(localized: "Arrow Right", comment: "Mod-tap key action: arrow right")
        case .home: return String(localized: "Home", comment: "Mod-tap key action: home")
        case .end: return String(localized: "End", comment: "Mod-tap key action: end")
        case .pageUp: return String(localized: "Page Up", comment: "Mod-tap key action: page up")
        case .pageDown: return String(localized: "Page Down", comment: "Mod-tap key action: page down")
        }
    }

    var symbolName: String {
        switch self {
        case .escape: return "escape"
        case .backspace: return "delete.backward"
        case .enter: return "return"
        case .tab: return "arrow.right.to.line"
        case .space: return "space"
        case .deleteForward: return "delete.forward"
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .home: return "arrow.up.to.line"
        case .end: return "arrow.down.to.line"
        case .pageUp: return "arrow.up.doc"
        case .pageDown: return "arrow.down.doc"
        }
    }

    var data: Data {
        switch self {
        case .escape: return Data([0x1B])
        case .backspace: return Data([0x7F])
        case .enter: return Data([0x0D])
        case .tab: return Data([0x09])
        case .space: return Data([0x20])
        case .deleteForward: return Data([0x1B, 0x5B, 0x33, 0x7E]) // ESC[3~
        case .arrowUp: return Data([0x1B, 0x5B, 0x41])    // ESC[A
        case .arrowDown: return Data([0x1B, 0x5B, 0x42])   // ESC[B
        case .arrowRight: return Data([0x1B, 0x5B, 0x43])  // ESC[C
        case .arrowLeft: return Data([0x1B, 0x5B, 0x44])   // ESC[D
        case .home: return Data([0x1B, 0x5B, 0x48])        // ESC[H
        case .end: return Data([0x1B, 0x5B, 0x46])         // ESC[F
        case .pageUp: return Data([0x1B, 0x5B, 0x35, 0x7E])   // ESC[5~
        case .pageDown: return Data([0x1B, 0x5B, 0x36, 0x7E]) // ESC[6~
        }
    }

    static func cases(in category: Category) -> [ModTapKeyAction] {
        allCases.filter { $0.category == category }
    }
}

/// Action performed on tap (quick press and release)
enum ModTapAction: Codable, Hashable, Sendable {
    case sendKey(ModTapKeyAction)
    case sendSequence(String)
    case switchInputSource(primaryLanguage: String)
    case none

    var displayName: String {
        switch self {
        case .sendKey(let key): return key.displayName
        case .sendSequence(let seq): return "Send \"\(seq)\""
        case .switchInputSource(let lang):
            let friendly = Locale.current.localizedString(forIdentifier: lang) ?? lang
            return String(localized: "Switch to \(friendly)", comment: "Mod-tap action: switch hardware input source")
        case .none: return "None"
        }
    }

    var data: Data? {
        switch self {
        case .sendKey(let key): return key.data
        case .sendSequence(let seq): return seq.data(using: .utf8)
        case .switchInputSource, .none: return nil
        }
    }
}

/// Source key that triggers mod-tap behavior
enum ModTapSourceKey: String, Codable, CaseIterable, Sendable {
    // Modifiers & Special
    case capsLock
    case escape
    case tab
    case leftControl
    case rightControl
    case leftShift
    case rightShift
    case leftAlt
    case rightAlt
    case leftCommand
    case rightCommand

    // Letters
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits
    case digit0, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9

    // Symbols
    case section, grave, minus, equal
    case leftBracket, rightBracket, backslash
    case semicolon, quote, comma, period, slash

    enum Category: String, CaseIterable, Sendable {
        case modifier
        case letter
        case digit
        case symbol

        var displayName: String {
            switch self {
            case .modifier: return "Modifiers & Special"
            case .letter: return "Letters"
            case .digit: return "Digits"
            case .symbol: return "Symbols"
            }
        }
    }

    var category: Category {
        switch self {
        case .capsLock, .escape, .tab, .leftControl, .rightControl,
             .leftShift, .rightShift, .leftAlt, .rightAlt,
             .leftCommand, .rightCommand:
            return .modifier
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z:
            return .letter
        case .digit0, .digit1, .digit2, .digit3, .digit4,
             .digit5, .digit6, .digit7, .digit8, .digit9:
            return .digit
        case .section, .grave, .minus, .equal, .leftBracket, .rightBracket,
             .backslash, .semicolon, .quote, .comma, .period, .slash:
            return .symbol
        }
    }

    var displayName: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .leftAlt: return "Left Option"
        case .rightAlt: return "Right Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
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
        case .section: return "§ (Section)"
        case .grave: return "` (Grave)"
        case .minus: return "- (Minus)"
        case .equal: return "= (Equal)"
        case .leftBracket: return "[ (Left Bracket)"
        case .rightBracket: return "] (Right Bracket)"
        case .backslash: return "\\ (Backslash)"
        case .semicolon: return "; (Semicolon)"
        case .quote: return "' (Quote)"
        case .comma: return ", (Comma)"
        case .period: return ". (Period)"
        case .slash: return "/ (Slash)"
        }
    }

    var hidUsage: UIKeyboardHIDUsage {
        switch self {
        case .capsLock: return .keyboardCapsLock
        case .escape: return .keyboardEscape
        case .tab: return .keyboardTab
        case .leftControl: return .keyboardLeftControl
        case .rightControl: return .keyboardRightControl
        case .leftShift: return .keyboardLeftShift
        case .rightShift: return .keyboardRightShift
        case .leftAlt: return .keyboardLeftAlt
        case .rightAlt: return .keyboardRightAlt
        case .leftCommand: return .keyboardLeftGUI
        case .rightCommand: return .keyboardRightGUI
        case .a: return .keyboardA
        case .b: return .keyboardB
        case .c: return .keyboardC
        case .d: return .keyboardD
        case .e: return .keyboardE
        case .f: return .keyboardF
        case .g: return .keyboardG
        case .h: return .keyboardH
        case .i: return .keyboardI
        case .j: return .keyboardJ
        case .k: return .keyboardK
        case .l: return .keyboardL
        case .m: return .keyboardM
        case .n: return .keyboardN
        case .o: return .keyboardO
        case .p: return .keyboardP
        case .q: return .keyboardQ
        case .r: return .keyboardR
        case .s: return .keyboardS
        case .t: return .keyboardT
        case .u: return .keyboardU
        case .v: return .keyboardV
        case .w: return .keyboardW
        case .x: return .keyboardX
        case .y: return .keyboardY
        case .z: return .keyboardZ
        case .digit0: return .keyboard0
        case .digit1: return .keyboard1
        case .digit2: return .keyboard2
        case .digit3: return .keyboard3
        case .digit4: return .keyboard4
        case .digit5: return .keyboard5
        case .digit6: return .keyboard6
        case .digit7: return .keyboard7
        case .digit8: return .keyboard8
        case .digit9: return .keyboard9
        // Registration key only: presses match by resolving to KeyCode.section.
        case .section: return .keyboardNonUSBackslash
        case .grave: return .keyboardGraveAccentAndTilde
        case .minus: return .keyboardHyphen
        case .equal: return .keyboardEqualSign
        case .leftBracket: return .keyboardOpenBracket
        case .rightBracket: return .keyboardCloseBracket
        case .backslash: return .keyboardBackslash
        case .semicolon: return .keyboardSemicolon
        case .quote: return .keyboardQuote
        case .comma: return .keyboardComma
        case .period: return .keyboardPeriod
        case .slash: return .keyboardSlash
        }
    }

    /// Default tap action for this source key
    var defaultTapAction: ModTapAction {
        switch self {
        case .capsLock, .escape, .leftControl, .rightControl,
             .leftShift, .rightShift, .leftAlt, .rightAlt, .section:
            return .sendKey(.escape)
        case .leftCommand, .rightCommand:
            return .none
        case .tab:
            return .sendKey(.tab)
        case .a: return .sendSequence("a")
        case .b: return .sendSequence("b")
        case .c: return .sendSequence("c")
        case .d: return .sendSequence("d")
        case .e: return .sendSequence("e")
        case .f: return .sendSequence("f")
        case .g: return .sendSequence("g")
        case .h: return .sendSequence("h")
        case .i: return .sendSequence("i")
        case .j: return .sendSequence("j")
        case .k: return .sendSequence("k")
        case .l: return .sendSequence("l")
        case .m: return .sendSequence("m")
        case .n: return .sendSequence("n")
        case .o: return .sendSequence("o")
        case .p: return .sendSequence("p")
        case .q: return .sendSequence("q")
        case .r: return .sendSequence("r")
        case .s: return .sendSequence("s")
        case .t: return .sendSequence("t")
        case .u: return .sendSequence("u")
        case .v: return .sendSequence("v")
        case .w: return .sendSequence("w")
        case .x: return .sendSequence("x")
        case .y: return .sendSequence("y")
        case .z: return .sendSequence("z")
        case .digit0: return .sendSequence("0")
        case .digit1: return .sendSequence("1")
        case .digit2: return .sendSequence("2")
        case .digit3: return .sendSequence("3")
        case .digit4: return .sendSequence("4")
        case .digit5: return .sendSequence("5")
        case .digit6: return .sendSequence("6")
        case .digit7: return .sendSequence("7")
        case .digit8: return .sendSequence("8")
        case .digit9: return .sendSequence("9")
        case .grave: return .sendSequence("`")
        case .minus: return .sendSequence("-")
        case .equal: return .sendSequence("=")
        case .leftBracket: return .sendSequence("[")
        case .rightBracket: return .sendSequence("]")
        case .backslash: return .sendSequence("\\")
        case .semicolon: return .sendSequence(";")
        case .quote: return .sendSequence("'")
        case .comma: return .sendSequence(",")
        case .period: return .sendSequence(".")
        case .slash: return .sendSequence("/")
        }
    }

    /// The key a source's UIKeyCommand input names. § has no US HID identity,
    /// and its HID usage prints other symbols on non-UK layouts.
    var keyCode: KeyCode? {
        self == .section ? .section : KeyCode(hidUsage: hidUsage)
    }

    /// Look up source key from HID usage code
    static func from(hidUsage: UIKeyboardHIDUsage) -> ModTapSourceKey? {
        allCases.first { $0.hidUsage == hidUsage }
    }

    static func cases(in category: Category) -> [ModTapSourceKey] {
        allCases.filter { $0.category == category }
    }
}

/// A single mod-tap rule mapping a source key to tap/hold actions
struct ModTapRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceKey: ModTapSourceKey
    var tapAction: ModTapAction
    var holdAction: ModTapModifier
    var holdThresholdMs: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        sourceKey: ModTapSourceKey,
        tapAction: ModTapAction,
        holdAction: ModTapModifier,
        holdThresholdMs: Int = 200,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.tapAction = tapAction
        self.holdAction = holdAction
        self.holdThresholdMs = holdThresholdMs
        self.isEnabled = isEnabled
    }

    // MARK: - Presets

    /// Caps Lock → Escape on tap, Control on hold
    static let capsLockEscCtrl = ModTapRule(
        sourceKey: .capsLock,
        tapAction: .sendKey(.escape),
        holdAction: .control
    )

    /// Escape → Escape on tap, Control on hold
    /// For users who remapped Caps Lock → Escape at the OS level
    static let escapeEscCtrl = ModTapRule(
        sourceKey: .escape,
        tapAction: .sendKey(.escape),
        holdAction: .control
    )

    var summaryText: String {
        "\(sourceKey.displayName) → \(tapAction.displayName) / \(holdAction.displayName)"
    }
}

// MARK: - Manager

@MainActor
@Observable
class ModTapManager {
    static let shared = ModTapManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ModTapManager")
    /// True while `reload(keys:)` re-assigns `rules` from the store.
    @ObservationIgnored private var isReloading = false

    var rules: [ModTapRule] {
        didSet { if !isReloading { save() } }
    }

    /// O(1) lookup of active rules by HID usage code
    var activeRulesByKey: [UIKeyboardHIDUsage: ModTapRule] {
        var result: [UIKeyboardHIDUsage: ModTapRule] = [:]
        for rule in rules where rule.isEnabled {
            result[rule.sourceKey.hidUsage] = rule
        }
        return result
    }

    /// Whether any rules are currently active
    var hasActiveRules: Bool {
        rules.contains { $0.isEnabled }
    }

    /// Count of effective active rules (deduplicated by source key)
    var activeRuleCount: Int {
        activeRulesByKey.count
    }

    /// Whether a source key already has a rule (enabled or not)
    func hasRule(for sourceKey: ModTapSourceKey) -> Bool {
        rules.contains { $0.sourceKey == sourceKey }
    }

    private init() {
        rules = Self.load()
        SettingsRefreshHub.shared.register(keys: [Settings.Keybinds.modTapRules.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        guard keys.contains(Settings.Keybinds.modTapRules.name) else { return }
        isReloading = true
        defer { isReloading = false }
        rules = Self.load()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(rules)
            SettingsStore.shared.set(Settings.Keybinds.modTapRules, data)
        } catch {
            Self.logger.error("Failed to save mod-tap rules: \(error.localizedDescription)")
        }
    }

    private static func load() -> [ModTapRule] {
        guard let data = SettingsStore.shared.get(Settings.Keybinds.modTapRules) else { return [] }
        do {
            return try JSONDecoder().decode([ModTapRule].self, from: data)
        } catch {
            logger.error("Failed to load mod-tap rules: \(error.localizedDescription)")
            return []
        }
    }
}
