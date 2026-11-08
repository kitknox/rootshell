// KeyTrigger's iOS implementation is compiled into the logic-test target.
// Its Catalyst layout translation depends on the app's Carbon/Ghostty bridge.
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest

final class ModTapShortcutTests: XCTestCase {
    private final class HardwareKey: UIKey {
        let usage: UIKeyboardHIDUsage
        let unmodified: String
        let modified: String
        let flags: UIKeyModifierFlags

        init(_ usage: UIKeyboardHIDUsage, base: String, text: String, modifiers: UIKeyModifierFlags) {
            self.usage = usage
            unmodified = base
            modified = text
            flags = modifiers
            super.init()
        }

        required init?(coder: NSCoder) { fatalError("Not used by keyboard tests") }
        override var keyCode: UIKeyboardHIDUsage { usage }
        override var charactersIgnoringModifiers: String { unmodified }
        override var characters: String { modified }
        override var modifierFlags: UIKeyModifierFlags { flags }
    }

    /// Exercise the production key interpretation, binding alias lookup, and
    /// mod-tap policy together, using the original (unrecovered) UIKit flags.
    private func route(_ key: UIKey, bindings: [KeyTrigger: String], timedHold: Bool = false,
                       source: UIKeyboardHIDUsage = .keyboardLeftGUI, hold: UIKeyModifierFlags = .control) throws
        -> (action: String?, modifiers: UIKeyModifierFlags, text: String) {
        var state = ModTapState(sourceKey: source, holdModifier: hold, startedAt: 10, threshold: 0.2)
        if timedHold { state.advance(to: 11) } else { state.useInChord() }
        let code = try XCTUnwrap(KeyCode(uiKey: key, modifiers: key.modifierFlags))
        let original = KeyTrigger(key: code, modifiers: KeybindModifiers(uiModifierFlags: key.modifierFlags))
        let resolved = original.resolvingShiftedSymbol { bindings[$0] != nil }
        let action = bindings[resolved]
        let modifiers = state.modifiers(hardware: key.modifierFlags, originalShortcutIsBound: action != nil,
            heldKeys: [source])
        XCTAssertEqual(state.resolution(onRelease: source), .hold)
        return (action, modifiers, HardwareKeyboardText.text(for: key, modifiers: modifiers))
    }

    func testShiftBracketChordsFindDefaultTabBindingsBeforeModTap() throws {
        let bindings: [KeyTrigger: String] = [
            KeyTrigger(key: .leftBrace, modifiers: .command): "previous_tab",
            KeyTrigger(key: .rightBrace, modifiers: .command): "next_tab"
        ]
        for timedHold in [false, true] {
            for (usage, base, text, action): (UIKeyboardHIDUsage, String, String, String) in [
                (.keyboardOpenBracket, "[", "{", "previous_tab"),
                (.keyboardCloseBracket, "]", "}", "next_tab")
            ] {
                let result = try route(HardwareKey(usage, base: base, text: text, modifiers: [.command, .shift]),
                    bindings: bindings, timedHold: timedHold)
                XCTAssertEqual(result.action, action)
                XCTAssertEqual(result.modifiers, [.command, .shift])
            }
        }
    }

    func testTabSymbolBindingsRetainNativeRepeatOwnership() throws {
        for extra: UIKeyModifierFlags in [[], .control, .alternate, [.control, .alternate]] {
            for (usage, base, symbol, code): (UIKeyboardHIDUsage, String, String, KeyCode) in [
                (.keyboardOpenBracket, "[", "{", .leftBrace),
                (.keyboardCloseBracket, "]", "}", .rightBrace)
            ] {
                let flags = extra.union([.command, .shift])
                let key = HardwareKey(usage, base: base, text: symbol, modifiers: flags)
                let binding = KeyTrigger(key: code, modifiers: KeybindModifiers(uiModifierFlags: flags.subtracting(.shift)))
                for timedHold in [false, true] {
                    let result = try route(key, bindings: [binding: "switch_tab"], timedHold: timedHold)
                    XCTAssertEqual(result.action, "switch_tab")
                    XCTAssertEqual(result.modifiers, flags)
                    // Production uses this gate to forward the press to UIKit
                    // instead of executing a one-shot tab action locally.
                    XCTAssertTrue(binding.matchesHardwareChord(key))
                }
            }
        }
    }

    func testSyntheticTabChordCannotBeHandedToUIKit() {
        let binding = KeyTrigger(key: .rightBrace, modifiers: .command)
        for flags: UIKeyModifierFlags in [[], .shift, [.control, .shift], [.command, .shift, .control]] {
            let key = HardwareKey(.keyboardCloseBracket, base: "]", text: "}", modifiers: flags)
            XCTAssertFalse(binding.matchesHardwareChord(key))
        }
    }

    func testExplicitTabChordAlsoRetainsNativeRepeatOwnership() {
        let key = HardwareKey(.keyboardCloseBracket, base: "]", text: "}", modifiers: [.command, .shift])
        let binding = KeyTrigger(key: .rightBracket, modifiers: [.command, .shift])
        XCTAssertTrue(binding.matchesHardwareChord(key))
    }

    func testRepurposedCapsLockCorrectsBothTextAndModifiers() {
        for extra: UIKeyModifierFlags in [[], .shift, .control, [.control, .shift], .alternate] {
            let physical = extra.union(.alphaShift)
            let effective = HardwareKeyboardModifiers.applyingCapsLock(false, to: physical)
            XCTAssertEqual(effective, extra)
            let key = HardwareKey(.keyboardA, base: "a", text: "A", modifiers: physical)
            let expected = extra.contains(.shift) ? "A" : "a"
            XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: effective), expected)
            XCTAssertEqual(HardwareKeyboardText.printableText(
                modifiers: effective, fallbackCharacter: "a", translate: {
                    XCTAssertFalse($0.contains(.alphaShift))
                    return nil
                }
            ), expected)
        }
    }

    func testIntentionalCapsLockToggleOverridesEitherOSState() {
        for osCapsLock in [false, true] {
            for desiredCapsLock in [false, true] {
                for shift in [false, true] {
                    var physical: UIKeyModifierFlags = shift ? .shift : []
                    if osCapsLock { physical.insert(.alphaShift) }
                    let effective = HardwareKeyboardModifiers.applyingCapsLock(desiredCapsLock, to: physical)
                    XCTAssertEqual(effective.contains(.alphaShift), desiredCapsLock)
                    XCTAssertEqual(effective.contains(.shift), shift)
                    let key = HardwareKey(.keyboardA, base: "a", text: osCapsLock != shift ? "A" : "a", modifiers: physical)
                    XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: effective), desiredCapsLock != shift ? "A" : "a")
                }
            }
        }
        let physical: UIKeyModifierFlags = [.command, .shift, .alphaShift]
        XCTAssertEqual(HardwareKeyboardModifiers.applyingCapsLock(nil, to: physical), physical)
    }

    func testControlShiftCommandUsesLiveCapsStateThenModTapOverride() {
        let command = UIKeyCommand(input: "a", modifierFlags: [.control, .shift], action: NSSelectorFromString("handleControlKey:"))
        XCTAssertFalse(command.modifierFlags.contains(.alphaShift))
        let live = HardwareKeyboardModifiers.applyingCapsLock(true, to: command.modifierFlags)
        XCTAssertEqual(live, [.control, .shift, .alphaShift])
        for (override, expected): (Bool?, String) in [(nil, "a"), (false, "A"), (true, "a")] {
            let effective = HardwareKeyboardModifiers.applyingCapsLock(override, to: live)
            XCTAssertEqual(HardwareKeyboardText.printableText(
                modifiers: effective, fallbackCharacter: "a", translate: { _ in nil }
            ), expected)
        }
    }

    func testCapsOnlyCompensationPreservesLayoutSymbolsWithoutOption() {
        for osCapsLock in [false, true] {
            for (usage, base, composed, shift): (UIKeyboardHIDUsage, String, String, Bool) in [
                (.keyboard3, "3", "§", true),
                (.keyboard2, "2", "\"", true),
                (.keyboard1, "&", "1", true),
                (.keyboard1, "&", "&", false),
                (.keyboardEqualSign, "^", "", false)
            ] {
                var physical: UIKeyModifierFlags = shift ? .shift : []
                if osCapsLock { physical.insert(.alphaShift) }
                let effective = HardwareKeyboardModifiers.applyingCapsLock(!osCapsLock, to: physical)
                let key = HardwareKey(usage, base: base, text: composed, modifiers: physical)
                XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: effective), composed)
            }
        }
    }

    func testCapsOnlyCompensationPreservesControlBytesAndSentinels() {
        for text in ["\u{01}", "UIKeyInputEscape"] {
            let key = HardwareKey(.keyboardA, base: "a", text: text, modifiers: [.control, .alphaShift])
            XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: .control), text)
        }
    }

    func testCapsOnlyCompensationPreservesOptionSymbolsAndDeadKeys() {
        for osCapsLock in [false, true] {
            for (usage, base, composed, shift): (UIKeyboardHIDUsage, String, String, Bool) in [
                (.keyboard1, "1", "¡", false),
                (.keyboard1, "1", "⁄", true),
                (.keyboardEqualSign, "=", "±", true),
                (.keyboard2, "2", "™", false),
                (.keyboardU, "u", "", false)
            ] {
                var physical: UIKeyModifierFlags = .alternate
                if shift { physical.insert(.shift) }
                if osCapsLock { physical.insert(.alphaShift) }
                let effective = HardwareKeyboardModifiers.applyingCapsLock(!osCapsLock, to: physical)
                let key = HardwareKey(usage, base: base, text: composed, modifiers: physical)
                XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: effective), composed)
            }
        }
        let letter = HardwareKey(.keyboardA, base: "a", text: "Å", modifiers: [.alternate, .alphaShift])
        XCTAssertEqual(HardwareKeyboardText.text(for: letter, modifiers: .alternate), "å")
    }

    func testConsumedOptionStillRetranslatesSymbolFromBase() {
        let key = HardwareKey(.keyboard1, base: "1", text: "¡", modifiers: [.alternate, .alphaShift])
        XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: .shift), "!")
    }

    func testSharedControlSequencePrefixHasNativeDispatchOwner() {
        let prefix = KeyTrigger(key: .a, modifiers: .option)
        let handler = NSSelectorFromString("handleKeybindCommand:")
        // Generated for Option+A -> Option+A even though the direct ctrl_a
        // action alone would not generate a command.
        let commands = [UIKeyCommand(input: "a", modifierFlags: .alternate, action: handler)]
        XCTAssertTrue(prefix.hasKeyCommand(in: commands, action: handler))
        XCTAssertFalse(prefix.hasKeyCommand(in: commands, action: NSSelectorFromString("handleControlKey:")))
        XCTAssertFalse(KeyTrigger(key: .a, modifiers: [.option, .shift]).hasKeyCommand(in: commands, action: handler))
    }

    func testControlPrefixWithoutRegisteredKeybindCommandRemainsLocal() throws {
        let prefix = KeyTrigger(key: .a, modifiers: .option)
        let handler = NSSelectorFromString("handleKeybindCommand:")
        let commands = [
            UIKeyCommand(input: "a", modifierFlags: .control, action: NSSelectorFromString("handleControlKey:")),
            UIKeyCommand(input: "b", modifierFlags: .alternate, action: handler)
        ]
        XCTAssertFalse(prefix.hasKeyCommand(in: commands, action: handler))
        XCTAssertFalse(prefix.hasKeyCommand(in: [], action: handler))
        let chord = try XCTUnwrap(ModifierPrintableChord(
            hardware: .alternate, state: nil, originalShortcutIsBound: true,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true, originalControlCharacter: 1
        ))
        XCTAssertEqual(chord.controlCharacter, 1)
    }

    func testEveryAdditionalModifierCombinationPreservesLetterBinding() throws {
        for extra: UIKeyModifierFlags in [
            .shift, .alternate, .control, [.shift, .alternate],
            [.shift, .control], [.alternate, .control], [.shift, .alternate, .control]
        ] {
            let modifiers = extra.union(.command)
            // Option may compose a printable character; Control may yield a
            // control byte. Neither changes the logical shortcut key.
            let text = extra.contains(.control) ? "\u{16}" : (extra.contains(.alternate) ? "√" : "V")
            let trigger = KeyTrigger(key: .v, modifiers: KeybindModifiers(uiModifierFlags: modifiers))
            let result = try route(HardwareKey(.keyboardV, base: "v", text: text, modifiers: modifiers),
                bindings: [trigger: "paste"])
            XCTAssertEqual(result.action, "paste", "Modifiers: \(modifiers)")
            XCTAssertEqual(result.modifiers, modifiers)
        }
    }

    func testCommandOptionBracketsFindGroupBindingsWithoutShiftAlias() throws {
        for (usage, base, text, code): (UIKeyboardHIDUsage, String, String, KeyCode) in [
            (.keyboardOpenBracket, "[", "“", .leftBracket),
            (.keyboardCloseBracket, "]", "‘", .rightBracket)
        ] {
            let trigger = KeyTrigger(key: code, modifiers: [.command, .option])
            let result = try route(HardwareKey(usage, base: base, text: text, modifiers: [.command, .alternate]),
                bindings: [trigger: "switch_group"])
            XCTAssertEqual(result.action, "switch_group")
            XCTAssertEqual(result.modifiers, [.command, .alternate])
        }
    }

    func testShiftedSymbolAliasesRetainOptionAndControl() throws {
        for extra: UIKeyModifierFlags in [.alternate, .control, [.alternate, .control]] {
            let modifiers = extra.union([.command, .shift])
            for (usage, base, symbol, code): (UIKeyboardHIDUsage, String, String, KeyCode) in [
                (.keyboardOpenBracket, "[", "{", .leftBrace),
                (.keyboardCloseBracket, "]", "}", .rightBrace),
                (.keyboardEqualSign, "=", "+", .plus)
            ] {
                let trigger = KeyTrigger(key: code, modifiers: KeybindModifiers(uiModifierFlags: modifiers.subtracting(.shift)))
                let result = try route(HardwareKey(usage, base: base, text: symbol, modifiers: modifiers),
                    bindings: [trigger: "custom_action"])
                XCTAssertEqual(result.action, "custom_action")
                XCTAssertEqual(result.modifiers, modifiers)
            }
        }
    }

    func testExplicitBaseBindingWinsOverSymbolAlias() throws {
        let result = try route(HardwareKey(.keyboardOpenBracket, base: "[", text: "{", modifiers: [.command, .shift]),
            bindings: [
                KeyTrigger(key: .leftBracket, modifiers: [.command, .shift]): "custom_action",
                KeyTrigger(key: .leftBrace, modifiers: .command): "previous_tab"
            ])
        XCTAssertEqual(result.action, "custom_action")
        XCTAssertEqual(result.modifiers, [.command, .shift])
    }

    func testLessModifiedShortcutCannotClaimCombinedChord() throws {
        for extra: UIKeyModifierFlags in [.alternate, .control, [.alternate, .control]] {
            let modifiers = extra.union([.command, .shift])
            let result = try route(HardwareKey(.keyboardOpenBracket, base: "[", text: "{", modifiers: modifiers),
                bindings: [KeyTrigger(key: .leftBrace, modifiers: .command): "previous_tab"])
            XCTAssertNil(result.action)
            XCTAssertEqual(result.modifiers, modifiers.subtracting(.command).union(.control))
        }
    }

    func testUnboundCombinedChordStillUsesHoldModifier() throws {
        let result = try route(HardwareKey(.keyboardCloseBracket, base: "]", text: "}", modifiers: [.command, .shift]),
            bindings: [:])
        XCTAssertNil(result.action)
        XCTAssertEqual(result.modifiers, [.control, .shift])
    }

    func testOptionToShiftRebuildsLettersSymbolsAndDeadKeys() throws {
        for (usage, base, composed, expected): (UIKeyboardHIDUsage, String, String, String) in [
            (.keyboardA, "a", "å", "A"),
            (.keyboard1, "1", "¡", "!"),
            (.keyboardOpenBracket, "[", "“", "{"),
            (.keyboardE, "e", "", "E")
        ] {
            let result = try route(HardwareKey(usage, base: base, text: composed, modifiers: .alternate),
                bindings: [:], source: .keyboardLeftAlt, hold: .shift)
            XCTAssertNil(result.action)
            XCTAssertEqual(result.modifiers, .shift)
            XCTAssertEqual(result.text, expected)
        }
    }

    func testConsumedControlDoesNotLeakOriginalControlByte() throws {
        let result = try route(HardwareKey(.keyboardA, base: "a", text: "\u{01}", modifiers: .control),
            bindings: [:], source: .keyboardLeftControl, hold: .shift)
        XCTAssertEqual(result.modifiers, .shift)
        XCTAssertEqual(result.text, "A")
    }

    func testSyntheticShiftUsesLayoutBaseRatherThanPhysicalUSKey() throws {
        // A layout where physical Q types a; synthetic Shift must send A.
        let result = try route(HardwareKey(.keyboardQ, base: "a", text: "å", modifiers: .alternate),
            bindings: [:], source: .keyboardLeftAlt, hold: .shift)
        XCTAssertEqual(result.text, "A")
        let nonASCII = try route(HardwareKey(.keyboardQuote, base: "ä", text: "æ", modifiers: .alternate),
            bindings: [:], source: .keyboardLeftAlt, hold: .shift)
        XCTAssertEqual(nonASCII.text, "Ä")
    }

    func testSyntheticShiftAndCapsLockUseEffectiveCase() throws {
        let result = try route(HardwareKey(.keyboardA, base: "a", text: "Å", modifiers: [.alternate, .alphaShift]),
            bindings: [:], source: .keyboardLeftAlt, hold: .shift)
        XCTAssertEqual(result.modifiers, [.shift, .alphaShift])
        XCTAssertEqual(result.text, "a")
    }

    func testUnchangedOptionChordKeepsComposedText() throws {
        let key = HardwareKey(.keyboardA, base: "a", text: "å", modifiers: .alternate)
        XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: .alternate), "å")
        let result = try route(key, bindings: [KeyTrigger(key: .a, modifiers: .option): "custom_action"],
            source: .keyboardLeftAlt, hold: .shift)
        XCTAssertEqual(result.action, "custom_action")
        XCTAssertEqual(result.modifiers, .alternate)
        XCTAssertEqual(result.text, "å")
    }

    func testNativeLayoutTranslationWinsOverUSShiftFallback() {
        let key = HardwareKey(.keyboard1, base: "1", text: "¡", modifiers: .alternate)
        XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: .shift, layoutText: "&"), "&")
    }

    func testOptionHeldIndependentlyKeepsItsComposedLetter() {
        let key = HardwareKey(.keyboardA, base: "a", text: "å", modifiers: .alternate)
        XCTAssertEqual(HardwareKeyboardText.text(for: key, modifiers: [.alternate, .shift]), "Å")
    }

    func testControlOnlyTerminalChordDoesNotUseCommandSymbolAliases() {
        let trigger = KeyTrigger(key: .leftBracket, modifiers: [.control, .shift])
        let alias = KeyTrigger(key: .leftBrace, modifiers: .control)
        XCTAssertEqual(trigger.resolvingShiftedSymbol { $0 == alias }, trigger)
    }

    func testSectionKeyParsesFromConfigAndKeyCommand() {
        let plain = KeyTrigger(key: .section)
        XCTAssertEqual(KeyTrigger(ghosttyFormat: "§"), plain)
        XCTAssertEqual(KeyTrigger(ghosttyFormat: "shift+§"), KeyTrigger(key: .section, modifiers: .shift))
        XCTAssertEqual(plain.ghosttyFormat, "§")
        let command = UIKeyCommand(input: plain.uiKeyInput, modifierFlags: [], action: NSSelectorFromString("handleKeybindCommand:"))
        XCTAssertEqual(KeyTrigger(uiKeyCommand: command), plain)
    }

    func testSectionKeyResolvesAtISOPositionOnly() {
        for (usage, base, text, modifiers, expected): (UIKeyboardHIDUsage, String, String, UIKeyModifierFlags, KeyCode) in [
            (.keyboardNonUSBackslash, "§", "§", [], .section),
            (.keyboardNonUSBackslash, "§", "±", .shift, .section),
            (.keyboardNonUSBackslash, "±", "±", .shift, .section),
            (.keyboardNonUSBackslash, "§", "§", .command, .section),
            (.keyboardGraveAccentAndTilde, "§", "§", [], .section),
            (.keyboardGraveAccentAndTilde, "`", "`", [], .grave),
            (.keyboardNonUSBackslash, "<", "<", [], .lessThan),
            // AZERTY's unshifted § on 6 and German Shift+3 stay digits.
            (.keyboard6, "§", "§", [], .digit6),
            (.keyboard6, "§", "§", .command, .digit6),
            (.keyboard3, "3", "§", .shift, .digit3)
        ] {
            let key = HardwareKey(usage, base: base, text: text, modifiers: modifiers)
            XCTAssertEqual(KeyCode(uiKey: key), expected, "\(usage.rawValue) \(base) \(modifiers)")
        }
    }

    func testSectionLayoutTextKeepsDigitFallbackOffISOPosition() {
        for (text, usage, expected): (String?, UIKeyboardHIDUsage, KeyCode) in [
            ("§", .keyboardNonUSBackslash, .section),
            ("§", .keyboardGraveAccentAndTilde, .section),
            // Catalyst's Option-chord resolver: AZERTY Option+6 stays alt+6.
            ("§", .keyboard6, .digit6),
            (nil, .keyboard6, .digit6),
            ("é", .keyboard2, .digit2),
            ("A", .keyboardQ, .a),
            ("<", .keyboardNonUSBackslash, .lessThan)
        ] {
            XCTAssertEqual(KeyCode(layoutText: text, hidUsage: usage), expected, "\(String(describing: text)) \(usage.rawValue)")
        }
        XCTAssertNil(KeyCode(layoutText: "é", hidUsage: .keyboardNonUSPound))
    }
}
#endif
