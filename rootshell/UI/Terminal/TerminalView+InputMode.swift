//
//  TerminalView+InputMode.swift
//  rootshell
//
//  Overrides `textInputMode` so a preferred primary language nudges the
//  hardware-keyboard input source. The switch is realized by briefly
//  handing first-responder to a parked text field and then taking it back,
//  which is the standard iOS pattern for refreshing the active input mode
//  without dismissing the keyboard window.
//

import UIKit

extension Ghostty.TerminalView {

    override var textInputMode: UITextInputMode? {
        guard let target = preferredInputLanguage else { return super.textInputMode }

        if let exact = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == target }) {
            return exact
        }
        if let prefix = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage?.hasPrefix(target) == true }) {
            return prefix
        }
        return super.textInputMode
    }

    /// Switch the hardware-keyboard input source for this terminal.
    ///
    /// iPad / visionOS: set `preferredInputLanguage` and refresh the responder
    /// via a parked text field so the keyboard accessory bar and candidate
    /// strip aren't torn down by a bare `resignFirstResponder()`.
    /// Mac Catalyst: dispatch via Carbon TIS — the UIKit textInputMode override
    /// is not honored by AppKit's input-source machinery on Catalyst.
    func applyInputLanguageSwitch(toPrimaryLanguage target: String) {
        invalidateWritingAssistance()
        #if targetEnvironment(macCatalyst)
        // Catalyst's TIS call triggers the native macOS input-source HUD,
        // so no in-app overlay is needed here.
        InputSourceCatalog.catalystSwitch(toPrimaryLanguage: target)
        #else
        // This preference (and our textInputMode override) reflects a request,
        // not the source UIKit selected through Globe or its language picker.
        // Reapply explicit requests even when the stored preference matches.
        preferredInputLanguage = target
        showInputModeOverlay(displayName(forPrimaryLanguage: target))

        // If we're not currently first responder, the override applies next time
        // we become first responder — nothing else to do.
        guard isFirstResponder else { return }

        let parking = ensureSwapParkingField()
        // Order: park grabs first responder, then we take it back on the next
        // runloop turn so UIKit has actually surfaced the override.
        _ = parking.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.becomeFirstResponder()
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Resolve a friendly name for the overlay. Prefer the active input mode's
    /// localized identifier (so a system-installed mode picks up its full name)
    /// and fall back to a plain locale-string lookup on the language code.
    private func displayName(forPrimaryLanguage lang: String) -> String {
        if let mode = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == lang }),
           let primary = mode.primaryLanguage,
           let localized = Locale.current.localizedString(forIdentifier: primary) {
            return localized
        }
        return Locale.current.localizedString(forIdentifier: lang) ?? lang
    }
    #endif

    /// Advance the hardware-keyboard input source to the next installed one,
    /// wrapping around — the in-app analogue of the system Ctrl+Space input
    /// cycle. The live input-source set and the current source are both re-read
    /// on every call (no cross-invocation state), so a keyboard added/removed
    /// while the app is running is reflected on the very next press.
    func cycleInputSource() {
        let sources = InputSourceCatalog.available()
        guard sources.count > 1 else {
            // 0 or 1 installed source: nothing to cycle.
            #if !targetEnvironment(macCatalyst)
            if let only = sources.first {
                showInputModeOverlay(only.displayName)
            }
            #endif
            return
        }

        let currentID = currentInputSourceIdentifier()
        let currentIndex = currentID.flatMap { id in
            sources.firstIndex { $0.primaryLanguage == id }
        } ?? -1
        // -1 (not found) -> 0; last index -> 0 (wrap).
        let nextIndex = (currentIndex + 1) % sources.count
        applyInputLanguageSwitch(toPrimaryLanguage: sources[nextIndex].primaryLanguage)
    }

    /// The currently-effective input source identifier, in the same namespace as
    /// `InputSourceCatalog.available()` (UITextInputMode primaryLanguage on
    /// iPad/visionOS, raw TIS source ID on Mac Catalyst).
    private func currentInputSourceIdentifier() -> String? {
        #if targetEnvironment(macCatalyst)
        return InputSourceCatalog.currentSourceID()
        #else
        // textInputMode reflects our preferredInputLanguage override when set,
        // else the system's active mode — both are the correct "current" to
        // advance from.
        return textInputMode?.primaryLanguage
        #endif
    }

    /// Drop the preferred-language override so a subsequent system input-source
    /// cycle (e.g. user-pressed Ctrl+Space) is not snapped back by our override.
    /// Called from the existing Ctrl+Space pass-through paths in pressesBegan
    /// / processKeyPress so the system HUD behaves normally.
    func yieldInputLanguageOverrideForSystemCycle() {
        preferredInputLanguage = nil
    }

    private func ensureSwapParkingField() -> UITextField {
        if let existing = inputLanguageSwapParkingField {
            return existing
        }
        let field = UITextField(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        field.isHidden = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        // Adding to self keeps the field in the responder chain even if our
        // superview changes (split panes, tab swaps).
        addSubview(field)
        inputLanguageSwapParkingField = field
        return field
    }
}
