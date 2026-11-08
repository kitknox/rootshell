import UIKit
import XCTest

final class ModTapStateTests: XCTestCase {
    private func commandControl() -> ModTapState {
        ModTapState(sourceKey: .keyboardLeftGUI, holdModifier: .control, startedAt: 10, threshold: 0.2)
    }

    func testSectionSourceIsTheHeldKeyTheLayoutPrintsSectionOn() {
        let candidates: [UIKeyboardHIDUsage] = [.keyboardNonUSBackslash, .keyboardGraveAccentAndTilde]
        let both = Set(candidates)
        let british: (UIKeyboardHIDUsage) -> Bool = { $0 == .keyboardNonUSBackslash }
        func pick(tracked: UIKeyboardHIDUsage? = nil, held: Set<UIKeyboardHIDUsage>,
                  prints: (UIKeyboardHIDUsage) -> Bool) -> UIKeyboardHIDUsage? {
            ModTapState.sectionSourceKey(tracked: tracked, candidates: candidates,
                                         isHeld: held.contains, printsSection: prints)
        }
        // AZERTY: 6 typed § while unrelated ISO keys are held.
        XCTAssertNil(pick(held: both.union([.keyboard6]), prints: { _ in false }))
        XCTAssertNil(pick(held: [.keyboard6], prints: { _ in true }))
        // Both ISO keys held: only the one printing § is the source.
        XCTAssertEqual(pick(held: both, prints: british), .keyboardNonUSBackslash)
        XCTAssertEqual(pick(held: both, prints: { $0 == .keyboardGraveAccentAndTilde }), .keyboardGraveAccentAndTilde)
        // Repeat keeps a held tracked source; a released one is re-resolved.
        XCTAssertEqual(pick(tracked: .keyboardGraveAccentAndTilde, held: both, prints: british), .keyboardGraveAccentAndTilde)
        XCTAssertEqual(pick(tracked: .keyboardGraveAccentAndTilde, held: [.keyboardNonUSBackslash], prints: british),
                       .keyboardNonUSBackslash)
    }

    func testOlderKeyReleaseDoesNotConsumePendingTap() {
        for source: UIKeyboardHIDUsage in [.keyboardCapsLock, .keyboardLeftGUI] {
            let state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 10, threshold: 0.2)
            // C was already down when the source was pressed. Only its
            // release is delivered while the mod-tap source is pending.
            XCTAssertNil(state.resolution(onRelease: .keyboardC))
            XCTAssertEqual(state.phase, .pending)
            XCTAssertEqual(state.resolution(onRelease: source), .tap)
        }
    }

    func testChordResolvesHoldOnceAndSuppressesTap() {
        var state = commandControl()
        XCTAssertTrue(state.useInChord())
        XCTAssertFalse(state.useInChord())
        XCTAssertFalse(state.advance(to: 11))
        XCTAssertEqual(state.resolution(onRelease: .keyboardLeftGUI), .hold)
    }

    func testRepeatDoesNotRestartThresholdOrResolveHoldTwice() {
        var state = commandControl()
        XCTAssertFalse(state.advance(to: 10.1))
        XCTAssertEqual(state.phase, .pending)
        XCTAssertTrue(state.advance(to: 10.21))
        XCTAssertFalse(state.advance(to: 10.3))
        XCTAssertEqual(state.resolution(onRelease: .keyboardLeftGUI), .hold)
    }

    func testOriginalBindingsWinBeforeAndAfterThreshold() {
        for useTimer in [false, true] {
            var state = commandControl()
            if useTimer { state.advance(to: 11) } else { state.useInChord() }
            // Cmd+T, Cmd+1 and Cmd+C all remain Command shortcuts; selection
            // availability never changes this decision. Cmd+Shift+V is intact.
            for hardware: UIKeyModifierFlags in [.command, [.command, .shift]] {
                XCTAssertEqual(state.modifiers(hardware: hardware, originalShortcutIsBound: true,
                    heldKeys: [.keyboardLeftGUI]), hardware)
            }
            XCTAssertEqual(state.resolution(onRelease: .keyboardLeftGUI), .hold)
        }
    }

    func testUnboundChordReplacesCommandAndPreservesShift() {
        var state = commandControl()
        state.useInChord()
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]), .control)
        XCTAssertEqual(state.modifiers(hardware: [.command, .shift], originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI, .keyboardLeftShift]), [.control, .shift])
    }

    func testMovingCopyBindingOnlyChangesWhichChordWins() {
        var state = commandControl()
        state.useInChord()
        // Test configuration only: Copy on Cmd+Shift+C, Cmd+C unbound.
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]), .control)
        XCTAssertEqual(state.modifiers(hardware: [.command, .shift], originalShortcutIsBound: true,
            heldKeys: [.keyboardLeftGUI, .keyboardLeftShift]), [.command, .shift])
    }

    func testShortcutThenUnboundKeyDuringSameHold() {
        var state = commandControl()
        state.useInChord() // A UIKeyCommand/menu action without a raw key-down.
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: true,
            heldKeys: [.keyboardLeftGUI]), .command)
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]), .control)
        XCTAssertEqual(state.resolution(onRelease: .keyboardLeftGUI), .hold)
    }

    func testIndependentOppositeSideModifierIsPreserved() {
        var state = commandControl()
        state.useInChord()
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI, .keyboardRightGUI]), [.command, .control])
        XCTAssertEqual(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]), .control)
    }

    func testAllModifierSourcesAndNonModifierSources() {
        let sources: [(UIKeyboardHIDUsage, UIKeyModifierFlags)] = [
            (.keyboardLeftGUI, .command), (.keyboardRightGUI, .command),
            (.keyboardLeftControl, .control), (.keyboardRightControl, .control),
            (.keyboardLeftAlt, .alternate), (.keyboardRightAlt, .alternate),
            (.keyboardLeftShift, .shift), (.keyboardRightShift, .shift)
        ]
        for (source, flag) in sources {
            var state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 0, threshold: 0.2)
            state.useInChord()
            XCTAssertEqual(state.modifiers(hardware: flag, originalShortcutIsBound: false,
                heldKeys: [source]), .control)
        }
        for source: UIKeyboardHIDUsage in [.keyboardCapsLock, .keyboardEscape, .keyboardTab, .keyboardA] {
            var state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 0, threshold: 0.2)
            state.useInChord()
            XCTAssertEqual(state.modifiers(hardware: .shift, originalShortcutIsBound: false,
                heldKeys: [.keyboardLeftShift]), [.control, .shift])
        }
    }

    func testPendingSourceDoesNotChangeModifiers() {
        XCTAssertEqual(commandControl().modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]), .command)
    }

    func testTrackedOptionPrintableSubstitutesEveryHoldModifierAndCombination() throws {
        for hold: UIKeyModifierFlags in [.shift, .control, .command, .alternate] {
            for extra: UIKeyModifierFlags in [[], .shift, .control, [.control, .shift]] {
                var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: hold, startedAt: 0, threshold: 0.2)
                state.useInChord()
                let chord = try XCTUnwrap(ModifierPrintableChord(
                    hardware: extra.union(.alternate), state: state, originalShortcutIsBound: false,
                    heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
                ))
                XCTAssertEqual(chord.modifiers, extra.union(hold))
                XCTAssertEqual(state.resolution(onRelease: .keyboardLeftAlt), .hold)
            }
        }
    }

    func testTrackedBoundOptionShortcutYieldsToUIKit() {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        for extra: UIKeyModifierFlags in [[], .shift, .control, [.control, .shift]] {
            XCTAssertNil(ModifierPrintableChord(
                hardware: extra.union(.alternate), state: state, originalShortcutIsBound: true,
                heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
            ))
        }
    }

    func testTrackedOptionTextPolicyUsesEffectiveModifiers() throws {
        XCTAssertNil(ModifierPrintableChord(
            hardware: .alternate, state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false
        ))
        XCTAssertEqual(ModifierPrintableChord(
            hardware: [.alternate, .control], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        )?.modifiers, [.alternate, .control])

        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        // A consumed Option must not fall back to UIKit's composed character.
        XCTAssertEqual(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false
        )?.modifiers, .shift)
        // Independently held right Option still contributes Alt.
        XCTAssertEqual(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt, .keyboardRightAlt], optionActsAsAlt: true
        )?.modifiers, [.alternate, .shift])
    }

    func testOriginalOptionControlActionIsHandledWithAndWithoutModTap() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        for activeState in [nil, state] {
            for optionActsAsAlt in [false, true] {
                for extra: UIKeyModifierFlags in [[], .control, .shift, [.control, .shift]] {
                    let hardware = extra.union(.alternate)
                    let chord = try XCTUnwrap(ModifierPrintableChord(
                        hardware: hardware, state: activeState, originalShortcutIsBound: true,
                        heldKeys: [.keyboardLeftAlt], optionActsAsAlt: optionActsAsAlt,
                        originalControlCharacter: 4,
                        effectiveControlCharacter: { _ in XCTFail("Original binding must win"); return 1 }
                    ))
                    XCTAssertEqual(chord.modifiers, hardware)
                    XCTAssertEqual(chord.controlCharacter, 4)
                }
            }
        }
    }

    func testSubstitutedControlActionUsesBoundByteRatherThanPhysicalLetter() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .control, startedAt: 0, threshold: 0.2)
        state.useInChord()
        let chord = try XCTUnwrap(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false,
            effectiveControlCharacter: {
                XCTAssertEqual($0, .control)
                return 1 // For example, Ctrl+D explicitly rebound to ctrl_a.
            }
        ))
        XCTAssertEqual(chord.controlCharacter, 1)
        XCTAssertEqual(chord.modifiers, .control)
    }

    func testUnboundOptionChordStillUsesGhosttyEncoding() throws {
        let chord = try XCTUnwrap(ModifierPrintableChord(
            hardware: [.alternate, .shift], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        XCTAssertNil(chord.controlCharacter)
        XCTAssertEqual(chord.modifiers, [.alternate, .shift])
    }

    func testGCPrintableCapsLockReachesLayoutTranslationOnPressAndRepeat() throws {
        // The GC route supplies modifier flags, not a UIKit-translated UIKey.
        // Model a US layout at the translation boundary used by the encoder.
        let letterLayout: [Int: String] = [
            0: "a", UIKeyModifierFlags.shift.rawValue: "A", UIKeyModifierFlags.alphaShift.rawValue: "A",
            UIKeyModifierFlags([.shift, .alphaShift]).rawValue: "a"
        ]
        for capsLock in [false, true] {
            for extra: UIKeyModifierFlags in [[], .control, .shift, [.control, .shift]] {
                var hardware = extra.union(.alternate)
                if capsLock { hardware.insert(.alphaShift) }
                var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
                state.useInChord()
                let chord = try XCTUnwrap(ModifierPrintableChord(
                    hardware: hardware, state: state, originalShortcutIsBound: false,
                    heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
                ))
                XCTAssertEqual(chord.modifiers, hardware.subtracting(.alternate).union(.shift))

                // Repeat retains the press's resolved modifiers even after the
                // pending mod-tap state is no longer used for translation.
                let repeatModifiers = chord.modifiers
                let expectedLayoutModifiers: UIKeyModifierFlags = capsLock ? [.shift, .alphaShift] : .shift
                var translations = 0
                for modifiers in [chord.modifiers, repeatModifiers, repeatModifiers] {
                    let text = HardwareKeyboardText.printableText(modifiers: modifiers, fallbackCharacter: "a") {
                        translations += 1
                        XCTAssertEqual($0, expectedLayoutModifiers)
                        return letterLayout[$0.rawValue]
                    }
                    XCTAssertEqual(text, capsLock ? "a" : "A")
                }
                XCTAssertEqual(translations, 3)
            }
        }
    }

    func testGCPrintableCapsLockFallbackPreservesShiftedSymbols() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        let chord = try XCTUnwrap(ModifierPrintableChord(
            hardware: [.alternate, .alphaShift], state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        for (base, expected): (Character, String) in [("a", "a"), ("1", "!"), ("[", "{")] {
            XCTAssertEqual(HardwareKeyboardText.printableText(
                modifiers: chord.modifiers, fallbackCharacter: base, translate: { _ in nil }
            ), expected)
        }
    }

    func testGCPrintableUnsubstitutedCapsLockAndCommandLayout() throws {
        let chord = try XCTUnwrap(ModifierPrintableChord(
            hardware: [.alternate, .alphaShift], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        XCTAssertEqual(HardwareKeyboardText.printableText(
            modifiers: chord.modifiers, fallbackCharacter: "a", translate: { _ in nil }
        ), "A")

        // Control/Alt are encoded by Ghostty; Command/Caps affect the layout.
        let text = HardwareKeyboardText.printableText(
            modifiers: [.command, .control, .alternate, .alphaShift], fallbackCharacter: "a"
        ) {
            XCTAssertEqual($0, [.command, .alphaShift])
            return "LAYOUT"
        }
        XCTAssertEqual(text, "LAYOUT")
    }
}
