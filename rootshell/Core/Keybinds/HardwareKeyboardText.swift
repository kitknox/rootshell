import UIKit

enum HardwareKeyboardModifiers {
    /// nil keeps the OS state; a mod-tap Caps Lock rule supplies the user's
    /// intended toggle state instead of the Caps Lock bit latched by the OS.
    static func applyingCapsLock(_ capsLock: Bool?, to modifiers: UIKeyModifierFlags) -> UIKeyModifierFlags {
        guard let capsLock else { return modifiers }
        var result = modifiers
        if capsLock { result.insert(.alphaShift) } else { result.remove(.alphaShift) }
        return result
    }

    /// UIKit keeps reporting Shift after a Shift key-up that a system overlay
    /// consumed. Drop it when a physical snapshot taken for this same press
    /// shows no Shift key down. nil means no live snapshot, so UIKit's flags stand.
    static func droppingStaleShift(
        from modifiers: UIKeyModifierFlags, physicalModifiers: UIKeyModifierFlags?
    ) -> UIKeyModifierFlags {
        guard let physicalModifiers, modifiers.contains(.shift),
              !physicalModifiers.contains(.shift) else { return modifiers }
        return modifiers.subtracting(.shift)
    }
}

/// Reconstructs text when a hardware chord's modifiers have been substituted.
/// Use UIKit's layout-resolved base text rather than the physical US key code.
enum HardwareKeyboardText {
    private static let textModifiers: UIKeyModifierFlags = [.command, .control, .alternate, .shift, .alphaShift]

    /// Text supplied to Ghostty for a printable physical key. Control and Alt
    /// belong to the encoder, while Shift, Caps Lock and Command select text
    /// from the keyboard layout. Used for both GCKeyboard presses and repeats.
    static func printableText(
        modifiers: UIKeyModifierFlags,
        fallbackCharacter: Character?,
        translate: (UIKeyModifierFlags) -> String?
    ) -> String? {
        let layoutModifiers = modifiers.intersection([.shift, .alphaShift, .command])
        if let text = translate(layoutModifiers), !text.isEmpty {
            return text.precomposedStringWithCanonicalMapping
        }
        guard let character = fallbackCharacter else { return nil }
        let shift = modifiers.contains(.shift)
        if character.isLetter {
            return shift != modifiers.contains(.alphaShift)
                ? String(character).uppercased() : String(character).lowercased()
        }
        return String(shift ? shiftedCharacter(character) : character)
    }

    static func text(for key: UIKey, modifiers: UIKeyModifierFlags, layoutText: String? = nil) -> String {
        guard key.modifierFlags.intersection(textModifiers) != modifiers.intersection(textModifiers) else {
            return key.characters
        }
        if let layoutText, !layoutText.isEmpty { return layoutText }

        let base = key.charactersIgnoringModifiers
        // Special keys retain their sentinels/control bytes. The key encoder
        // handles those using the effective modifiers, not a text translation.
        guard !base.isEmpty, !base.hasPrefix("UIKeyInput"),
              base.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return key.characters
        }

        let changed = modifiers.symmetricDifference(key.modifierFlags).intersection(textModifiers)
        if changed == .alphaShift {
            // Caps-only compensation changes letter case, not the layout's
            // symbol selection. Keep UIKit's translated symbols (e.g. German
            // Shift+3 is §), including Option compositions and dead keys.
            guard !key.characters.hasPrefix("UIKeyInput") else { return key.characters }
            let uppercase = modifiers.contains(.shift) != modifiers.contains(.alphaShift)
            return key.characters.map { character in
                guard character.isLetter else { return String(character) }
                return uppercase ? String(character).uppercased() : String(character).lowercased()
            }.joined()
        }

        var text = base
        // If Option still belongs to the chord, preserve its layout-specific
        // character when available. Consumed Option must start from the base
        // (e.g. å -> a -> A), never from the original composed character.
        if modifiers.contains(.alternate), key.modifierFlags.contains(.alternate),
           !key.modifierFlags.contains(.control) {
            let caseModifiers: UIKeyModifierFlags = [.shift, .alphaShift]
            if !key.characters.isEmpty,
               modifiers.intersection(caseModifiers) == key.modifierFlags.intersection(caseModifiers) {
                return key.characters
            }
            if !key.characters.isEmpty, key.characters.allSatisfy(\.isLetter) { text = key.characters.lowercased() }
        }

        let shift = modifiers.contains(.shift)
        let uppercase = shift != modifiers.contains(.alphaShift)
        return text.map { character in
            if character.isLetter {
                return uppercase ? String(character).uppercased() : String(character).lowercased()
            }
            return String(shift ? shiftedCharacter(character) : character)
        }.joined()
    }

    /// Fallback when UIKit cannot translate a key with synthetic modifiers.
    /// Catalyst supplies the active layout's translation instead.
    static func shiftedCharacter(_ character: Character) -> Character {
        if character.isLetter { return character.uppercased().first ?? character }
        return usShiftMap[character] ?? character
    }

    /// The US-layout key a shifted symbol sits on (`{` → `[`), or nil.
    static func unshiftedCharacter(_ character: Character) -> Character? {
        usUnshiftMap[character]
    }

    private static let usUnshiftMap = Dictionary(uniqueKeysWithValues: usShiftMap.map { ($1, $0) })

    private static let usShiftMap: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"
    ]
}
