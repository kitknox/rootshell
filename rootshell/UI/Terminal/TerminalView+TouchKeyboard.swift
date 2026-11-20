#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

extension Ghostty.TerminalView: TerminalTouchKeyboardHost {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        let (name, _) = ThemeOverrideManager.shared.resolveTheme(tabId: containingTabID, windowId: windowId)
        return ThemeManager.shared.themeInfo(for: name)?.colors
    }

    var touchKeyboardCanSend: Bool {
        isFirstResponder && window != nil && !aiAgentOverlayActive && !showComposeOverlay
    }

    var touchKeyboardHeldModifiers: KeyModifiers { keyboardAccessoryController?.glassBarHeldModifiers ?? [] }

    func prepareTouchKeyboardSwitch() {
        // Resolve the current input method before replacing its input view.
        commitKoreanCompositionIfNeeded(external: true)
        if markedTextString != nil { unmarkText() }
        endDictationSession()
        invalidateWritingAssistance(resetDocument: true)
        resetDoubleSpaceTracking()
    }

    func touchKeyboardInsert(_ text: String) {
        guard touchKeyboardCanSend else { return }
        touchKeyboardInputDepth += 1
        defer { touchKeyboardInputDepth -= 1 }
        insertText(text)
    }

    func touchKeyboardConsumeShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard touchKeyboardCanSend, KeySequenceTracker.shared.isAwaitingSecondKey else { return false }
        resetDoubleSpaceTracking()
        return handleSoftwareKeyShortcut(key, modifiers: modifiers)
    }

    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers, shifted: Character?) {
        guard touchKeyboardCanSend else { return }
        let held = touchKeyboardHeldModifiers
        let modifiers = modifiers.union(held)
        defer { if !held.isEmpty { keyboardAccessoryController?.consumeGlassBarModifiers() } }
        // Special keys bypass insertText, but still interrupt consecutive spaces.
        resetDoubleSpaceTracking()
        // A shortcut wins before the named keys below reach the encoder.
        if handleSoftwareKeyShortcut(key, modifiers: modifiers) { return }
        if key == "\u{7f}", modifiers.isEmpty {
            touchKeyboardInputDepth += 1
            defer { touchKeyboardInputDepth -= 1 }
            deleteBackward()
            return
        }
        invalidateWritingAssistance()
        let functionNumber = Self.softwareFunctionKeyNumber(key)
        if let usage = Self.softwareKeyHIDUsageMap[key] ?? functionNumber.flatMap({ Self.softwareFunctionKeyUsage($0) }) {
            let flags = modifiers.uiKeyModifierFlags
            NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
            if sendKeyViaGhostty(keyCode: usage, action: .press, modifiers: flags) {
                _ = sendKeyViaGhostty(keyCode: usage, action: .release, modifiers: flags)
                if key == "\r" { invalidateWritingAssistance(resetDocument: true) }
                return
            }
        }
        if let index = functionNumber {
            let fallback = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~",
                            "\u{1b}[18~", "\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]
            keyPressed(fallback[index - 1], modifiers: modifiers)
        } else {
            // This path also preserves local-shell Ctrl-C and Escape overlays.
            keyPressed(key, modifiers: modifiers, shifted: shifted)
        }
    }

    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? {
        guard keyboardAccessoryController?.usesTouchKeyboard == true,
              refreshWritingAssistanceTraits(), activeKeyboardModifiers.isEmpty else { return nil }
        return TerminalTouchKeyboardModel.SuggestionContext(
            document: correctionContext.document, eligibleCount: correctionContext.eligibleUTF16Count,
            generation: correctionContext.generation, documentGeneration: correctionContext.documentGeneration)
    }

    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? {
        guard touchKeyboardCanSend, keyboardAccessoryController?.usesTouchKeyboard == true,
              markedTextString == nil, !koreanCompositionModel.hasActiveComposition,
              correctionContext.dictation == nil, activeKeyboardModifiers.isEmpty,
              virtualModTapModifier == nil, heldHardwareModifiers == .none else { return nil }
        return touchPredictionContext.snapshot
    }

    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {
        guard touchKeyboardCanSend, touchKeyboardSuggestionContext == context else { return }
        _ = applyWritingAssistanceReplacement(context.range, text: text + " ", generation: context.generation)
    }

    func touchKeyboardInvalidateSuggestions() { invalidateWritingAssistance() }
}

// TerminalKeyboardAccessoryHost
extension Ghostty.TerminalView {
    var keyboardTouchKeyboardHost: TerminalTouchKeyboardHost? { self }
    var keyboardTabID: UUID? { containingTabID }
    var keyboardLostFocusOutsideWindow: Bool { lostFocusOutsideWindow }
    func keyboardPrepareTouchKeyboardSwitch() { prepareTouchKeyboardSwitch() }
}

#endif
