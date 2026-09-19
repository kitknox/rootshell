//
//  TerminalView+Keyboard.swift
//  rootshell
//
//  Keyboard input handling, key commands, and key handlers
//  Extracted from TerminalView.swift for build parallelization
//

import UIKit
import GameController
import os
import GhosttyKit

// MARK: - Key Repeat Manager

extension Ghostty {

    /// Manages keyboard key repeat behavior with initial delay and repeat interval.
    /// Encapsulates timer state that was previously spread across multiple instance variables.
    /// Uses class (not struct) because Timer closures need to capture self.
    class KeyRepeatManager {
        private var repeatTimer: Timer?
        private var delayTimer: Timer?
        private var activeKey: UIKey?

        /// Whether a key is currently repeating or pending repeat
        var isActive: Bool { repeatTimer != nil || delayTimer != nil }

        /// The key currently being repeated, if any
        var currentKeyCode: UIKeyboardHIDUsage? { activeKey?.keyCode }

        /// Starts key repeat for the given key and sequence.
        /// - Parameters:
        ///   - key: The UIKey being repeated
        ///   - sequence: The escape sequence or characters to send
        ///   - onRepeat: Callback invoked on each repeat with the sequence data
        func start(for key: UIKey, sequence: String, onRepeat: @escaping (Data) -> Void) {
            stop()
            activeKey = key

            // macOS fastest: 225ms delay, 30ms repeat interval
            delayTimer = Timer.scheduledTimer(withTimeInterval: 0.225, repeats: false) { [weak self, sequence] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                    if let data = sequence.data(using: .utf8) {
                        onRepeat(data)
                    }
                }
            }
        }

        /// Starts key repeat for the given key using a custom action closure.
        /// Used for keys that trigger actions rather than sending text sequences.
        /// - Parameters:
        ///   - key: The UIKey being repeated
        ///   - action: Closure invoked on each repeat
        func start(for key: UIKey, action: @escaping () -> Void) {
            stop()
            activeKey = key

            // macOS fastest: 225ms delay, 30ms repeat interval
            delayTimer = Timer.scheduledTimer(withTimeInterval: 0.225, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                    action()
                }
            }
        }

        /// Stops any active key repeat
        func stop() {
            delayTimer?.invalidate()
            delayTimer = nil
            repeatTimer?.invalidate()
            repeatTimer = nil
            activeKey = nil
        }

        /// Stops repeat if the given key matches the active key
        func stopIfMatches(_ keyCode: UIKeyboardHIDUsage) {
            if keyCode == activeKey?.keyCode {
                stop()
            }
        }
    }
}

// MARK: - Mod-Tap Interceptor

extension Ghostty {

    /// Tracks a source press without replaying the other key: the caller keeps
    /// ownership of dispatch and can still forward unhandled presses to UIKit.
    class ModTapInterceptor {
        private(set) var state: ModTapState?
        private(set) var rule: ModTapRule?
        private var thresholdWorkItem: DispatchWorkItem?
        private var generation = 0

        var onTapAction: ((ModTapAction) -> Void)?
        var onModifierChanged: ((ModTapModifier?) -> Void)?
        /// Fires once per source press; Bool is true for hold, false for tap.
        var onSourceKeyResolved: ((ModTapRule, Bool) -> Void)?

        /// Returns true only for the source key. Other keys resolve the hold,
        /// then proceed through the caller's ordinary dispatch exactly once.
        func handlePressBegan(_ press: UIPress, rules: [UIKeyboardHIDUsage: ModTapRule]) -> Bool {
            guard let key = press.key else { return false }
            if let state {
                if key.keyCode == state.sourceKey {
                    advanceThreshold()
                    return true
                }
                noteChordUse()
                return false
            }
            guard let rule = rules[key.keyCode] else { return false }
            startPending(for: rule)
            return true
        }

        func handlePressEnded(_ press: UIPress) -> Bool {
            guard let key = press.key else { return false }
            return handleKeyReleased(keyCode: key.keyCode)
        }

        var activeModifier: ModTapModifier? {
            state?.phase == .held ? rule?.holdAction : nil
        }

        func noteChordUse() {
            if state?.useInChord() == true { didResolveHold() }
        }

        func startPending(for rule: ModTapRule) {
            if state?.sourceKey == rule.sourceKey.hidUsage {
                advanceThreshold()
                return
            }
            reset()
            self.rule = rule
            state = ModTapState(
                sourceKey: rule.sourceKey.hidUsage,
                holdModifier: rule.holdAction.uiKeyModifierFlag,
                startedAt: ProcessInfo.processInfo.systemUptime,
                threshold: Double(rule.holdThresholdMs) / 1000
            )
            let currentGeneration = generation
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.noteChordUse()
            }
            thresholdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(rule.holdThresholdMs) / 1000, execute: workItem)
        }

        @discardableResult
        func handleKeyReleased(keyCode: UIKeyboardHIDUsage) -> Bool {
            guard let resolution = state?.resolution(onRelease: keyCode), let rule else { return false }
            reset()
            if resolution == .tap {
                onSourceKeyResolved?(rule, false)
                onTapAction?(rule.tapAction)
            }
            return true
        }

        func reset() {
            cancelTimer()
            let wasHeld = state?.phase == .held
            state = nil
            rule = nil
            if wasHeld { onModifierChanged?(nil) }
        }

        private func advanceThreshold() {
            if state?.advance(to: ProcessInfo.processInfo.systemUptime) == true { didResolveHold() }
        }

        private func didResolveHold() {
            cancelTimer()
            guard let rule else { return }
            onSourceKeyResolved?(rule, true)
            onModifierChanged?(rule.holdAction)
        }

        private func cancelTimer() {
            generation += 1
            thresholdWorkItem?.cancel()
            thresholdWorkItem = nil
        }
    }
}

// MARK: - Key Commands

extension Ghostty.TerminalView {

    // Helper to create UIKeyCommand with visionOS compatibility
    func makeKeyCommand(
        input: String,
        modifierFlags: UIKeyModifierFlags = [],
        action: Selector,
        discoverabilityTitle: String? = nil,
        wantsPriority: Bool = false
    ) -> UIKeyCommand {
#if os(visionOS)
        let command = UIKeyCommand(input: input, modifierFlags: modifierFlags, action: action)
#else
        let command = UIKeyCommand(input: input, modifierFlags: modifierFlags, action: action)
        if let title = discoverabilityTitle {
            command.discoverabilityTitle = title
        }
#endif
        if wantsPriority {
            command.wantsPriorityOverSystemBehavior = true
        }
        return command
    }

    // Register key commands for dynamic keybindings
    // Uses cached array to avoid 26+ allocations per keystroke
    override var keyCommands: [UIKeyCommand]? {
        guard !shouldYieldHardwareInputToEmojiUI else { return nil }
        #if targetEnvironment(macCatalyst)
        let shouldSuppressControlShortcuts = false
        #else
        let shouldSuppressControlShortcuts = isPhysicalControlDownForSystemShortcutArbitration
        #endif
        return inputController.keyCommands(
            hasMarkedText: markedTextString != nil || hasActiveKoreanComposition,
            isPhysicalControlDownForSystemShortcutArbitration: shouldSuppressControlShortcuts
        )
    }

    /// Invalidate the cached key commands, forcing rebuild on next access
    func invalidateKeyCommands() {
        inputController.invalidateKeyCommandCache()
    }

}

// MARK: - Hardware Keyboard Input (pressesBegan/pressesEnded)

extension Ghostty.TerminalView {

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        lastHardwareTextInputTime = ProcessInfo.processInfo.systemUptime
        endDictationSession()
        invalidateWritingAssistance()
        // Hardware keys reach the responder chain, not the window-level touch
        // observer, so typing has to restart the always-on-display window here.
        noteAlwaysOnDisplayInteraction()

        if shouldYieldHardwareInputToEmojiUI {
            resetKeyboardInteractionState(sendSyntheticKeyReleases: true)
            super.pressesBegan(presses, with: event)
            return
        }

        var handled = false
        var forwardedPresses = Set<UIPress>()

        syncHeldModifierSides(from: event)

        #if !targetEnvironment(macCatalyst)
        if presses.contains(where: { shouldPassHardwareCtrlSpaceToSystem($0) }) {
            modTapInterceptor.noteChordUse()
            yieldInputLanguageOverrideForSystemCycle()
            keyboardAccessory?.toolbarView.clearOneShotModifiers()
            super.pressesBegan(presses, with: event)
            return
        }
        #endif

        var remainingPresses = presses
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // A configured Visor chord owns its physical key before Escape's
        // mod-tap, tmux-detach, or overlay-dismiss paths can consume it.
        for press in presses {
            if let trigger = KeyTrigger(press: press), consumeVisorShortcut(trigger) {
                remainingPresses.remove(press)
                handled = true
            }
        }
        #endif

        // A Set has no key order. Start any source before resolving the other
        // keys in the same delivery, then process each non-source exactly once.
        let modTapRules = ModTapManager.shared.activeRulesByKey
        let orderedPresses = remainingPresses.sorted {
            let lhs = $0.key.map { modTapRules[$0.keyCode] != nil } ?? false
            let rhs = $1.key.map { modTapRules[$0.keyCode] != nil } ?? false
            if lhs != rhs { return lhs }
            return ($0.key?.keyCode.rawValue ?? 0) < ($1.key?.keyCode.rawValue ?? 0)
        }
        for press in orderedPresses {
            if modTapInterceptor.handlePressBegan(press, rules: modTapRules) {
                if let key = press.key, ModTapState.modifierFlag(for: key.keyCode) != nil {
                    // UIKit needs the modifier-down edge for its own shortcuts.
                    forwardedPresses.insert(press)
                } else {
                    handled = true
                }
                continue
            }
            let result = processKeyPress(press, virtualModifier: virtualModTapModifier)
            if result.handled { handled = true }
            if !result.handled && !result.skipSuper { forwardedPresses.insert(press) }
        }

        if handled { keyboardAccessory?.toolbarView.clearOneShotModifiers() }
        if !forwardedPresses.isEmpty {
            super.pressesBegan(forwardedPresses, with: event)
        }
    }

    /// Process a single key press with optional virtual modifier from mod-tap.
    /// Returns whether the press was handled and whether super should be skipped.
    @discardableResult
    func processKeyPress(_ press: UIPress, virtualModifier: ModTapModifier?) -> (handled: Bool, skipSuper: Bool) {
        guard !shouldYieldHardwareInputToEmojiUI else { return (false, false) }
        lastHardwareTextInputTime = ProcessInfo.processInfo.systemUptime
        endDictationSession()
        invalidateWritingAssistance()
        // iOS 13.4+ - use UIPress.key for better key information
        guard let key = press.key else { return (false, false) }

        // Track which physical modifier sides are currently held.
        if key.keyCode == .keyboardLeftControl {
            heldControlSide = heldControlSide == .right ? .both : .left
        } else if key.keyCode == .keyboardRightControl {
            heldControlSide = heldControlSide == .left ? .both : .right
        }

        // Track which OPTION key is held for insertText handling and left/right Alt resolution.
        if key.keyCode == .keyboardLeftAlt {
            heldOptionSide = heldOptionSide == .right ? .both : .left
        } else if key.keyCode == .keyboardRightAlt {
            heldOptionSide = heldOptionSide == .left ? .both : .right
        }

        let hardwareModifiers = normalizedHardwareModifierFlags(key.modifierFlags)
        if !hardwareModifiers.isEmpty { isGCKeyboardModifierStateTrusted = true }
        // Recover the original chord before substituting mod-tap. Recovering
        // afterward would reintroduce the Command bit we just consumed.
        let recoveredModifiers = mergeHardwareCommandChordFromGCKeyboard(
            into: hardwareModifiers, hardwareModifiers: hardwareModifiers
        )
        let originalTrigger = KeyCode(uiKey: key, modifiers: recoveredModifiers).map {
            normalizedBindingTrigger(KeyTrigger(key: $0, modifiers: KeybindModifiers(uiModifierFlags: recoveredModifiers)))
        }
        let originalShortcutIsBound = modTapInterceptor.state != nil
            && originalTrigger.map(keybindClaimsTrigger) == true
        // The rest of the input path must also know whether this particular
        // key uses the virtual modifier (Option/AltGr and Control fast paths).
        let virtualModifier = originalShortcutIsBound ? nil : virtualModifier
        var effectiveModifiers: UIKeyModifierFlags
        if let state = modTapInterceptor.state {
            effectiveModifiers = state.modifiers(
                hardware: recoveredModifiers,
                originalShortcutIsBound: originalShortcutIsBound,
                heldKeys: inputController.heldModifierKeys
            )
        } else {
            effectiveModifiers = recoveredModifiers
            if let virtualModifier { effectiveModifiers.insert(virtualModifier.uiKeyModifierFlag) }
        }
        effectiveModifiers = normalizedHardwareModifierFlags(effectiveModifiers, virtualModifier: virtualModifier)

        let didSubstituteModifiers = modTapInterceptor.state != nil && effectiveModifiers != recoveredModifiers
        let consumedOption = didSubstituteModifiers && hardwareModifiers.contains(.alternate)
            && !effectiveModifiers.contains(.alternate)
        // UIKit translated characters using the physical chord. Both fallback
        // encoding and printable/repeat output must use the substituted chord.
        let needsTextTranslation = didSubstituteModifiers
            || key.modifierFlags.contains(.alphaShift) != effectiveModifiers.contains(.alphaShift)
        lazy var effectiveCharacters = needsTextTranslation
            ? retranslatedHardwareText(for: key, modifiers: effectiveModifiers)
            : key.characters

        // Track hardware modifier state for mouse events (Cmd+click link detection)
        heldHardwareModifiers = ghosttyInputMods(from: effectiveModifiers, virtualModifier: virtualModifier)

        let hasOption = effectiveModifiers.contains(.alternate)
        lazy var logicalKey = KeyCode(uiKey: key, modifiers: effectiveModifiers)

        // The reserved Cmd+Period system-cancel chord can arrive translated as
        // plain Escape. Give a cmd+period binding first refusal; a twin of a
        // chord delivery already handled on another rail is swallowed. Unbound
        // falls through to normal Escape handling, which is exactly the
        // chord's default behavior. This never fires for a real Escape press
        // because the Escape key itself is physically down then.
        if key.keyCode == .keyboardEscape, key.modifierFlags.isEmpty,
           KeyboardTracker.isSystemCancelChordPhysicallyDown() {
            guard inputController.consumeSystemCancelChordDelivery() else {
                return (true, true)
            }
            if dispatchKeybindTrigger(.commandPeriod) {
                return (true, true)
            }
        }

        // The chord also reaches pressesBegan as a non-Escape key (usually
        // Period) whose characters are the Escape sentinel — UIKit's own proof
        // that it translated the chord, so this resolves even when the merge
        // above could not restore Command from a distrusted GCKeyboard snapshot.
        let isTranslatedCancelChord = key.keyCode != .keyboardEscape
            && KeyCode.sentinelKey(for: key.characters) == .escape
        if isTranslatedCancelChord
            || (KeybindModifiers(uiModifierFlags: effectiveModifiers) == .command
                && logicalKey == .period) {
            // Translation only happens with Command physically down, so the
            // snapshot is live again.
            if isTranslatedCancelChord {
                isGCKeyboardModifierStateTrusted = true
            }
            guard inputController.consumeSystemCancelChordDelivery() else {
                return (true, true)
            }
            handleSystemCancelChordDelivery()
            return (true, true)
        }

        #if !targetEnvironment(macCatalyst)
        // This catches virtual/mod-tap Control after effective modifiers are
        // merged; the earlier pressesBegan check only sees the hardware event.
        if shouldPassHardwareCtrlSpaceToSystem(key: key, modifiers: effectiveModifiers) {
            yieldInputLanguageOverrideForSystemCycle()
            return (false, false)
        }
        #endif

        if key.keyCode == .keyboardEscape, enclosingSplitHost?.cancelPaneDrag() == true {
            return (true, true)
        }

        // A presented overlay (tab exposé) owns navigation keys while up; it
        // must see Escape before the tmux-detach and AI-agent handlers below.
        if let overlayHandler = presentedOverlayKeyHandler, overlayHandler(OverlayKeyEvent(key)) {
            return (true, true)
        }

        // The discovery picker is the visible terminal overlay, so Escape must
        // dismiss it before reaching other Escape actions such as AI or tmux.
        if key.keyCode == .keyboardEscape, dismissSessionDiscoveryIfPresented() {
            return (true, true)
        }

        // Handle Escape overlays early so key is marked handled when routed via pressesBegan
        // (not UIKeyCommand), such as on Mac Catalyst with mod-tap source-key support.
        if key.keyCode == .keyboardEscape && aiAgentOverlayActive {
            NotificationCenter.default.post(name: .toggleAIAgent, object: self)
            return (true, true)
        }

        // tmux control-mode gateway: ESC gracefully detaches (matches the in-TUI
        // menu the core prints). Fires if `self` is the gateway view OR the
        // selected tab is the gateway; ESC inside a tmux pane still reaches the
        // app there (pane views have no controller and aren't the gateway tab).
        if key.keyCode == .keyboardEscape,
           let target = selectedTmuxGatewayView() ?? ((tmuxController?.isActive == true || isTmuxGatewaySurfaceActive) ? self : nil) {
            target.sendTmuxDetach()
            return (true, true)
        }

        // herdr gateway: same ESC-detaches contract as the tmux gateway.
        if key.keyCode == .keyboardEscape, detachHerdrGatewayIfCovered() {
            return (true, true)
        }

        // Intercept keys when session discovery overlay is visible. A searching or
        // empty card has nothing to select, so it must not eat Return/arrows.
        if hasDiscoveredSessionRows {
            if key.keyCode == .keyboardReturnOrEnter {
                selectHighlightedSession()
                return (true, true)
            }
            if key.keyCode == .keyboardUpArrow {
                moveSessionSelection(by: -1)
                return (true, true)
            }
            if key.keyCode == .keyboardDownArrow {
                moveSessionSelection(by: 1)
                return (true, true)
            }
            // Digit keys: select session whose name matches the digit.
            // Set didHandleSessionPickerKey flag to prevent double-processing in insertText().
            let chars = key.characters
            if chars.count == 1,
               let digit = chars.first?.wholeNumberValue,
               selectSessionByDigit(digit) {
                didHandleSessionPickerKey = true
                return (true, true)
            }
            // All other text keys: dismiss overlay and let them pass through
            dismissSessionDiscovery()
        } else if discoveredSessions != nil, !key.characters.isEmpty, !isModifierOnlyKey(key.keyCode) {
            // Searching or empty card: typing still dismisses it, but every key
            // reaches the terminal because there is nothing to select.
            dismissSessionDiscovery()
        }
        // Modifier-only key presses should update state but never emit terminal input.
        // Some platforms/layouts can report non-empty `characters` for modifier keys,
        // which would otherwise fall through to special-key handling (e.g., Alt -> DEL).
        if isModifierOnlyKey(key.keyCode) {
            // Keep our modifier bookkeeping, but still let UIKit see the
            // physical modifier press. System shortcuts such as iPadOS
            // Control+Space depend on a clean modifier key sequence.
            return (false, false)
        }

        // If UIKit owns marked text, defer key handling to the text input system
        // so the IME can handle backspace, space, arrows, etc. For our local
        // Korean preedit model, non-editing special keys must not be swallowed:
        // commit the preedit and let normal terminal key handling continue.
        let shouldDeferForKoreanPreedit = hasActiveKoreanComposition
            && markedTextString == nil
            && (key.keyCode == .keyboardDeleteOrBackspace || !Self.specialKeycodes.contains(key.keyCode))
        let shouldDeferForIME = markedTextString != nil || shouldDeferForKoreanPreedit
        if shouldDeferForIME
            && !effectiveModifiers.contains(.command)
            && !effectiveModifiers.contains(.control) {
            #if !targetEnvironment(macCatalyst)
            beginKoreanCompositionInputKey()
            #endif
            return (false, false)
        }

        commitKoreanCompositionIfNeeded(external: true)

        let hardwareTrigger = logicalKey.map {
            KeyTrigger(key: $0, modifiers: KeybindModifiers(uiModifierFlags: effectiveModifiers))
        }
        let bindingTrigger = originalShortcutIsBound ? originalTrigger : hardwareTrigger.map {
            normalizedBindingTrigger($0)
        }

        // Early custom binding check: if the user has a non-default binding for this
        // key combo (from external config or in-app override), execute it immediately.
        // This takes priority over all hardcoded special-case handlers below (Cmd+arrow,
        // modified Return, Cmd+backspace, etc.) so that custom keybindings always win.
        // Preserving a default mod-tap chord only preserves its trigger: it must
        // still reach the existing Control/scroll/backspace repeat handlers.
        if let trigger = bindingTrigger {
            // Let KeySequenceTracker claim the press first so the second key of a
            // pending sequence (which may itself be an unmodified letter that
            // would otherwise reach the terminal) gets captured.
            let (trackerHandled, trackerKeybind) = KeySequenceTracker.shared.consume(
                owner: self,
                trigger: trigger
            )
            if let trackerKeybind {
                executeKeybindAction(trackerKeybind.action, parameter: trackerKeybind.actionParameter)
                return (true, true)
            }
            if trackerHandled {
                return (true, true)
            }

            // Tab changes move first responder, so a per-terminal repeat timer
            // cannot own this chord. Before shifted-symbol normalization these
            // presses reached UIKit's repeating menu/UIKeyCommand path. Keep
            // that ownership when the physical chord matches, including when
            // an original shortcut wins over mod-tap. Synthetic/recovered
            // chords still need local dispatch because UIKit never saw them.
            if let keybind = KeybindManager.shared.keybind(for: trigger),
               keybind.action == .previous_tab || keybind.action == .next_tab,
               trigger.matchesHardwareChord(key) {
                return (false, false)
            }

            // Preserve UIKit's paste intent for an original bound shortcut,
            // including custom Cmd+Shift+V, when it reaches the raw press path.
            // The source modifier was forwarded, so UIKit can match the chord.
            if (originalShortcutIsBound || (trigger.key == .v && trigger.modifiers == .command)),
               let keybind = KeybindManager.shared.keybind(for: trigger),
               keybind.action == .paste_from_clipboard,
               !KeybindManager.shared.isSequencePrefix(trigger) {
                return (false, false)
            }

            if let keybind = KeybindManager.shared.keybind(for: trigger),
               keybind.source != .default && !keybind.action.isControlCharacter {
                if effectiveModifiers.contains(.alternate) || consumedOption { didHandleOptionKey = true }
                executeKeybindAction(keybind.action, parameter: keybind.actionParameter)
                return (true, true)
            }
        }

        if key.keyCode == .keyboardReturnOrEnter,
           !effectiveModifiers.isEmpty,
           !effectiveModifiers.contains(.command),
           sendEnterKeyViaGhostty(modifiers: effectiveModifiers) {
            NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
            notifyInputDelegateOfExternalChange {
                mutateInputDocument(.reset)
            }
            specialKeyPressModifiers[key.keyCode] = effectiveModifiers
            let repeatModifiers = effectiveModifiers
            keyRepeatManager.start(for: key) { [weak self] in
                self?.sendKeyViaGhostty(
                    keyCode: .keyboardReturnOrEnter,
                    action: .repeat,
                    modifiers: repeatModifiers
                )
            }
            return (true, true)
        }

        // Handle CMD+Alt+arrow keys for split navigation (upstream Ghostty default)
        // UIKeyCommand doesn't work for arrow keys with Command modifier on iOS
        if effectiveModifiers.contains(.command) && effectiveModifiers.contains(.alternate) &&
            (key.keyCode == .keyboardUpArrow || key.keyCode == .keyboardDownArrow ||
             key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow) {
            // Handle split navigation directly
            let direction: String
            switch key.keyCode {
            case .keyboardUpArrow:
                direction = "up"
            case .keyboardDownArrow:
                direction = "down"
            case .keyboardLeftArrow:
                direction = "left"
            case .keyboardRightArrow:
                direction = "right"
            default:
                return (false, false)
            }

            // Post navigation notification
            NotificationCenter.default.post(
                name: .navigateSplit,
                object: self,
                userInfo: ["direction": direction]
            )

            return (true, true)
        }

        // Skip CTRL+arrow - handled by GCKeyboard in KeyboardTracker
        // On iOS hardware keyboards, these can come through pressesBegan AND GCKeyboard,
        // causing duplicate/wrong input.
        #if !os(visionOS)
        if (virtualModifier != .control || hardwareModifiers.contains(.control)),
           effectiveModifiers.contains(.control) && !effectiveModifiers.contains(.command) &&
            (key.keyCode == .keyboardUpArrow || key.keyCode == .keyboardDownArrow ||
             key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow) {
            return (true, true)
        }
        #endif

        // Handle plain CMD+arrow keys (upstream Ghostty default)
        // CMD+Left/Right: beginning/end of line (Ctrl-A / Ctrl-E)
        // CMD+Up/Down: scroll page up/down
        if effectiveModifiers.contains(.command) && !effectiveModifiers.contains(.alternate) &&
            (key.keyCode == .keyboardUpArrow || key.keyCode == .keyboardDownArrow ||
             key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow) {
            switch key.keyCode {
            case .keyboardLeftArrow:
                sendUserInput(Data([0x01]))
            case .keyboardRightArrow:
                sendUserInput(Data([0x05]))
            case .keyboardUpArrow, .keyboardDownArrow:
                let triggerKey: KeyCode = key.keyCode == .keyboardUpArrow ? .up : .down
                let trigger = KeyTrigger(key: triggerKey, modifiers: .command)
                if let keybind = KeybindManager.shared.keybind(for: trigger),
                   let actionStr = keybind.action.ghosttyActionString {
                    performActionAsync(actionStr)
                    keyRepeatManager.start(for: key) { [weak self] in
                        self?.performActionAsync(actionStr)
                    }
                }
            default:
                return (false, false)
            }

            return (true, true)
        }

        // Plain OPT+Left/Right: word jump (ESC+b / ESC+f) — matches macOS Ghostty default.
        // Gated on shouldOptionActAsAlt so users who want Option-as-literal-char get that.
        if effectiveModifiers.contains(.alternate)
            && !effectiveModifiers.contains(.command)
            && !effectiveModifiers.contains(.control)
            && shouldOptionActAsAlt(virtualModifier: virtualModifier)
            && (key.keyCode == .keyboardLeftArrow || key.keyCode == .keyboardRightArrow) {
            switch key.keyCode {
            case .keyboardLeftArrow:
                sendUserInput(Data([0x1b, 0x62]))
                startKeyRepeat(for: key, sequence: "\u{1b}b")
            case .keyboardRightArrow:
                sendUserInput(Data([0x1b, 0x66]))
                startKeyRepeat(for: key, sequence: "\u{1b}f")
            default:
                break
            }
            return (true, true)
        }

        // Handle modified backspace (macOS text editing conventions)
        // These work across all session types (local shell, SSH, cloud console, K8s)
        if key.keyCode == .keyboardDeleteOrBackspace {
            if effectiveModifiers.contains(.command) && !effectiveModifiers.contains(.alternate) {
                // CMD+Delete: kill to beginning of line (Ctrl+U = 0x15)
                let data = Data([0x15])
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                sendUserInput(data)
                startKeyRepeat(for: key, sequence: "\u{15}")
                return (true, true)
            }
            if effectiveModifiers.contains(.alternate) && !effectiveModifiers.contains(.command) {
                // OPT+Delete: delete word backward (ESC+DEL = 0x1B 0x7F)
                let data = Data([0x1b, 0x7f])
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                sendUserInput(data)
                startKeyRepeat(for: key, sequence: "\u{1b}\u{7f}")
                return (true, true)
            }
        }

        // Ctrl+key fast path: send raw control bytes for legacy terminal mode.
        // When Shift or Alt is also held, skip this path and let the Ghostty
        // encoder handle it (for correct CSI u / Kitty protocol encoding).
        if effectiveModifiers.contains(.control) && !effectiveModifiers.contains(.command)
            && !effectiveModifiers.contains(.alternate) && !effectiveModifiers.contains(.shift) {
            #if targetEnvironment(macCatalyst)
            // Catalyst handles physical Ctrl+A-Z via UIKeyCommand for reliable routing.
            // Only synthesize control bytes here when Control is coming from mod-tap.
            let physicalHasControl = key.modifierFlags.contains(.control)
            if physicalHasControl && virtualModifier != .control {
                return (false, false)
            }
            #endif

            if let controlByte = logicalKey?.controlCharacterByte {
                if consumedOption { didHandleOptionKey = true }
                let controlData = Data([controlByte])

                // Handle Ctrl-C for local shell interrupt (non-Catalyst only)
                var localHandled = false
                #if !targetEnvironment(macCatalyst)
                if controlByte == 3,
                   let localSession = session as? LocalShellSession,
                   !localSession.hasActiveEmbeddedSession {
                    localSession.interrupt()
                    localHandled = true
                }
                #endif
                if !localHandled {
                    sendUserInput(controlData)
                }

                // Start key repeat
                let controlString = String(UnicodeScalar(controlByte))
                #if !targetEnvironment(macCatalyst)
                if controlByte == 3,
                   let localSession = session as? LocalShellSession,
                   !localSession.hasActiveEmbeddedSession {
                    keyRepeatManager.start(for: key) { [weak self] in
                        guard let self = self else { return }
                        if let localSession = self.session as? LocalShellSession,
                           !localSession.hasActiveEmbeddedSession {
                            localSession.interrupt()
                        } else {
                            self.sendUserInput(controlData)
                        }
                    }
                } else {
                    startKeyRepeat(for: key, sequence: controlString)
                }
                #else
                startKeyRepeat(for: key, sequence: controlString)
                #endif

                return (true, true)
            }
        }

        // Handle other key combinations via KeybindManager
        // Ctrl+A-Z use the fast path above or UIKeyCommand on Catalyst.
        if let trigger = bindingTrigger,
           let keybind = KeybindManager.shared.keybind(for: trigger) {

            // Skip control characters - handled by the fast path or Catalyst UIKeyCommands.
            if keybind.action.isControlCharacter {
                return (false, false)
            }

            // Suppress the composed-character insertText that follows an Option chord.
            if effectiveModifiers.contains(.alternate) || consumedOption { didHandleOptionKey = true }
            // Execute the action through the keybind system (with parameter if present)
            executeKeybindAction(keybind.action, parameter: keybind.actionParameter)

            return (true, true)
        }

        // Route keys through Ghostty's encoder when a modifier shortcut is active
        // (Ctrl/Alt/Cmd). For Alt, prefer physical-key-derived text when the
        // iPad right Option key behaves like AltGr so the composed OS character
        // doesn't leak into terminal encoding. For regular typing and Shift-only,
        // fall through to the text handling path below.
        // Also always route non-printable special keys (F-keys, arrows, nav keys)
        // through Ghostty regardless of modifiers.
        do {
            var ghosttyMods = effectiveModifiers
            if ghosttyMods.contains(.alternate) && !shouldOptionActAsAlt(virtualModifier: virtualModifier) {
                ghosttyMods.remove(.alternate)
            }
            // Special keys (F-keys, arrows, nav): always route through Ghostty encoder.
            // Printable keys: only route through Ghostty when Alt is active (ESC encoding).
            // Plain Ctrl+key is handled by the fast path above.
            // Ctrl+Shift routes here for correct Ghostty encoding.
            let isSpecialKey = Self.specialKeycodes.contains(key.keyCode)
            let hasAlt = ghosttyMods.contains(.alternate)
            let hasCtrlShift = ghosttyMods.contains(.control) && ghosttyMods.contains(.shift)
            let rightOptionActsAsAlt = hasAlt && (heldOptionSide == .right || heldOptionSide == .both)

            if isSpecialKey || hasAlt || hasCtrlShift {
                let mods = ghosttyInputMods(from: ghosttyMods, virtualModifier: virtualModifier)

                // For printable keys, provide the SHIFTED character as text.
                // For special keys (arrows, F-keys), text=nil is correct.
                var keyText: String? = nil
                var consumed = Ghostty.Input.Mods.none
                if !isSpecialKey {
                    let shifted = effectiveModifiers.contains(.shift)
                    if rightOptionActsAsAlt {
                        keyText = printableTextForGhostty(hidUsage: key.keyCode, modifiers: effectiveModifiers)
                        if shifted {
                            consumed.insert(.shift)
                        }
                    } else if shifted || effectiveModifiers.contains(.alphaShift)
                        || key.modifierFlags.contains(.alphaShift) {
                        // Use the same effective Caps Lock state for encoder
                        // text as for modifier flags, including a repurposed
                        // Caps Lock key whose OS toggle is still latched.
                        #if targetEnvironment(macCatalyst)
                        keyText = printableTextForGhostty(hidUsage: key.keyCode, modifiers: effectiveModifiers)
                        #else
                        let charsIM = key.charactersIgnoringModifiers
                        let isAscii = !charsIM.isEmpty && charsIM.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F })
                        keyText = HardwareKeyboardText.printableText(
                            modifiers: effectiveModifiers,
                            fallbackCharacter: isAscii ? charsIM.first : KeyCode(hidUsage: key.keyCode)?.literalKeyInput?.first,
                            translate: { _ in nil }
                        )
                        #endif
                        if shifted { consumed.insert(.shift) }
                    } else {
                        // No Shift: prefer layout-aware charsIM, KeyCode fallback
                        let charsIM = key.charactersIgnoringModifiers
                        if !charsIM.isEmpty && charsIM.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
                            keyText = charsIM
                        } else if let kc = KeyCode(hidUsage: key.keyCode) {
                            // literalKeyInput: a sentinel is never key text.
                            keyText = kc.literalKeyInput
                        }
                    }
                }

                // unshifted_codepoint: the character with NO modifiers applied.
                // Matches macOS Ghostty's characters(byApplyingModifiers: []).
                let unshiftedCP = rightOptionActsAsAlt
                    ? unshiftedCodepoint(for: key.keyCode)
                    : unshiftedCodepoint(for: key.keyCode, key: key)

                if sendKeyViaGhostty(
                    keyCode: key.keyCode, action: .press, mods: mods,
                    consumedMods: consumed, text: keyText,
                    unshiftedCodepoint: unshiftedCP
                ) {
                    specialKeyPressModifiers[key.keyCode] = ghosttyMods
                    NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                    if hasOption || consumedOption { didHandleOptionKey = true }
                    let keyCode = key.keyCode
                    keyRepeatManager.start(for: key) { [weak self] in
                        self?.sendKeyViaGhostty(
                            keyCode: keyCode, action: .repeat, mods: mods,
                            consumedMods: consumed, text: keyText,
                            unshiftedCodepoint: unshiftedCP
                        )
                    }
                    return (true, true)
                }
            }
        }

        // Try to handle as a special key (arrows, etc.)
        // Note: Tab is handled via UIKeyCommand, not here
        if let sequence = handleSpecialKey(key, characters: effectiveCharacters, modifiers: effectiveModifiers) {
            // Apply OPTION modifier (Meta key - prefix with ESC).
            // Keys reaching this path are single-byte sequences (Tab, Backspace, control chars)
            // since CSI/SS3 keys (arrows, Home, End, etc.) are handled by sendKeyViaGhostty.
            var finalSequence = sequence
            if hasOption && shouldOptionActAsAlt(virtualModifier: virtualModifier) {
                finalSequence = "\u{1B}" + sequence
            }

            // Check for Ctrl-C (ASCII 3) and interrupt local shell if applicable
            // Note: Catalyst sessions handle CTRL-C via normal input path (like SSH)
            // Note: OPTION+Ctrl-C sends ESC+Ctrl-C, doesn't interrupt
            // Note: If embedded SSH session is active, forward Ctrl-C to SSH instead
            var localHandled = false
            if sequence == "\u{03}" && !hasOption {
                #if !targetEnvironment(macCatalyst)
                if let localSession = session as? LocalShellSession,
                   !localSession.hasActiveEmbeddedSession {
                    NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                    localSession.interrupt()
                    localHandled = true
                }
                #endif
            }

            if !localHandled, let data = finalSequence.data(using: .utf8) {
                if consumedOption { didHandleOptionKey = true }
                // Send the result to session (SSH or other control sequences)
                // Notify that input was received (for scroll-to-bottom behavior)
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)

                notifyInputDelegateOfExternalChange {
                    sendUserInput(data, documentMutation: sequence == "\u{7F}" ? .backspace(eligible: false) : .invalidate)
                }

                // Start key repeat for special keys
                startKeyRepeat(for: key, sequence: finalSequence)
            }
            return (true, true)
        } else if let sentinel = KeyCode.sentinelKey(for: effectiveCharacters),
                  !effectiveModifiers.contains(.command) {
            // Sentinel characters on an unrecognized key: never text. Swallow
            // so super cannot re-offer it to the text input system.
            Ghostty.logger.debug("processKeyPress: dropped UIKit sentinel \(sentinel.rawValue)")
            return (true, true)
        } else if !effectiveCharacters.isEmpty && !effectiveModifiers.contains(.command) {
            // When a CJK input method is active, defer character keys to the text
            // input system so IME composition can begin. This handles the FIRST
            // keystroke before any marked text exists.
            if isCJKInputMethodActive && !effectiveModifiers.contains(.control) {
                #if !targetEnvironment(macCatalyst)
                beginKoreanCompositionInputKey(allowNoActiveDelete: true)
                #endif
                return (false, false)
            }
            // Handle regular printable characters directly to bypass iOS text transformations
            // (autocapitalization, autocorrect, etc.) that occur in super.pressesBegan()
            // Skip if Command modifier is present (let UIKeyCommand handle shortcuts)
            let characters = effectiveCharacters

            // Apply OPTION modifier handling
            // When Option acts as Alt, the Ghostty encoder path above handles it.
            // This path only runs when Option produces characters (not Alt mode).
            if hasOption || consumedOption { didHandleOptionKey = true }

            if let data = characters.data(using: .utf8) {
                // Notify that input was received (for scroll-to-bottom behavior)
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)

                notifyInputDelegateOfExternalChange {
                    sendUserInput(data, documentMutation: .text(characters, eligible: false))
                }

                // Start key repeat for regular characters
                startKeyRepeat(for: key, sequence: characters)
            }
            return (true, true)
        }

        return (false, false)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldYieldHardwareInputToEmojiUI {
            resetKeyboardInteractionState(sendSyntheticKeyReleases: true)
            super.pressesEnded(presses, with: event)
            return
        }
        // A non-source release may belong to a key pressed before mod-tap.
        // Only key-down or an actual command dispatch proves chord use.
        // Reset OPTION key flag on key release
        didHandleOptionKey = false

        // Stop key repeat when any key is released
        for press in presses {
            // Check mod-tap interceptor first
            if modTapInterceptor.handlePressEnded(press) {
                continue
            }

            guard let key = press.key else { continue }
            inputController.controlCharacterPresses.removeValue(forKey: key.keyCode)
            // A translated Cmd+Period press can be tracked as Escape by the
            // overlay handlers but released at the layout's Period position.
            if keysConsumedByOverlayAction.contains(.keyboardEscape),
               KeyCode(uiKey: key, modifiers: .command) == .period {
                keysConsumedByOverlayAction.remove(.keyboardEscape)
            }
            keyRepeatManager.stopIfMatches(key.keyCode)
            keysConsumedByOverlayAction.remove(key.keyCode)
            // Send release event for special keys routed through Ghostty,
            // using the same modifiers that were sent with the press event.
            if let pressMods = specialKeyPressModifiers.removeValue(forKey: key.keyCode) {
                sendKeyViaGhostty(keyCode: key.keyCode, action: .release, modifiers: pressMods)
            }
            // Track OPTION key release
            if key.keyCode == .keyboardLeftControl {
                heldControlSide = heldControlSide == .both ? .right : .none
            } else if key.keyCode == .keyboardRightControl {
                heldControlSide = heldControlSide == .both ? .left : .none
            } else if key.keyCode == .keyboardLeftAlt {
                heldOptionSide = heldOptionSide == .both ? .right : .none
            } else if key.keyCode == .keyboardRightAlt {
                heldOptionSide = heldOptionSide == .both ? .left : .none
            }
        }

        syncHeldModifierSides(from: event)

        // Recalculate held hardware modifiers from remaining pressed keys
        var hwMods = Ghostty.Input.Mods.none
        if let allPresses = event?.allPresses {
            for p in allPresses where p.phase == .began || p.phase == .changed || p.phase == .stationary {
                guard let k = p.key else { continue }
                hwMods.formUnion(ghosttyInputMods(from: normalizedHardwareModifierFlags(k.modifierFlags)))
            }
        }
        heldHardwareModifiers = hwMods

        // Ensure the responder chain processes key release events properly
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        resetKeyboardInteractionState(sendSyntheticKeyReleases: true)
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Key Repeat

extension Ghostty.TerminalView {

    /// Reset all per-view keyboard interaction state. UIKit/GameController can
    /// miss release events when the app/window deactivates or cancels a key
    /// sequence, so we clear our local state and optionally synthesize key
    /// releases to Ghostty for any special keys it still considers pressed.
    func resetKeyboardInteractionState(sendSyntheticKeyReleases: Bool) {
        didHandleOptionKey = false
        keyRepeatManager.stop()
        modTapInterceptor.reset()
        keysConsumedByOverlayAction.removeAll()
        virtualModTapModifier = nil
        heldControlSide = .none
        heldOptionSide = .none
        inputController.heldModifierKeys.removeAll()
        inputController.controlCharacterPresses.removeAll()
        heldHardwareModifiers = .none
        isGCKeyboardModifierStateTrusted = false

        if sendSyntheticKeyReleases {
            for (keyCode, modifiers) in specialKeyPressModifiers {
                sendKeyViaGhostty(keyCode: keyCode, action: .release, modifiers: modifiers)
            }
        }
        specialKeyPressModifiers.removeAll()
    }

    func startKeyRepeat(for key: UIKey, sequence: String) {
        let isBackspace = (sequence == "\u{7F}")
        keyRepeatManager.start(for: key, sequence: sequence) { [weak self] data in
            guard let self else { return }
            self.notifyInputDelegateOfExternalChange {
                if isBackspace {
                    self.sendUserInput(data, documentMutation: .backspace(eligible: false))
                } else if !sequence.hasPrefix("\u{1B}") {
                    self.sendUserInput(data, documentMutation: .text(sequence, eligible: false))
                } else {
                    self.sendUserInput(data)
                }
            }
        }
    }

    func stopKeyRepeat() {
        keyRepeatManager.stop()
    }
}

// MARK: - Key Constants

extension Ghostty.TerminalView {

    /// Keycodes for non-printable special keys that should always route through
    /// Ghostty's encoder (regardless of modifier state). Printable keys only
    /// route through Ghostty when Alt is active.
    static let specialKeycodes: Set<UIKeyboardHIDUsage> = [
        .keyboardReturnOrEnter, .keyboardEscape, .keyboardTab,
        .keyboardDeleteOrBackspace, .keyboardDeleteForward,
        .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
        .keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
        .keyboardInsert,
        .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4,
        .keyboardF5, .keyboardF6, .keyboardF7, .keyboardF8,
        .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
        .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
        .keyboardF17, .keyboardF18, .keyboardF19,
    ]

    /// Reverse map from UIKeyCommand input character to HID usage.
    /// Used in handleControlKey to route Ctrl+Shift through Ghostty encoder.
    static let charToHIDUsage: [Character: UIKeyboardHIDUsage] = [
        "a": .keyboardA, "b": .keyboardB, "c": .keyboardC, "d": .keyboardD,
        "e": .keyboardE, "f": .keyboardF, "g": .keyboardG, "h": .keyboardH,
        "i": .keyboardI, "j": .keyboardJ, "k": .keyboardK, "l": .keyboardL,
        "m": .keyboardM, "n": .keyboardN, "o": .keyboardO, "p": .keyboardP,
        "q": .keyboardQ, "r": .keyboardR, "s": .keyboardS, "t": .keyboardT,
        "u": .keyboardU, "v": .keyboardV, "w": .keyboardW, "x": .keyboardX,
        "y": .keyboardY, "z": .keyboardZ,
        "0": .keyboard0, "1": .keyboard1, "2": .keyboard2, "3": .keyboard3,
        "4": .keyboard4, "5": .keyboard5, "6": .keyboard6, "7": .keyboard7,
        "8": .keyboard8, "9": .keyboard9,
        "-": .keyboardHyphen, "=": .keyboardEqualSign,
        "[": .keyboardOpenBracket, "]": .keyboardCloseBracket,
        "\\": .keyboardBackslash, ";": .keyboardSemicolon, "'": .keyboardQuote,
        ",": .keyboardComma, ".": .keyboardPeriod, "/": .keyboardSlash,
        "`": .keyboardGraveAccentAndTilde, " ": .keyboardSpacebar,
    ]

    #if targetEnvironment(macCatalyst)
    /// Printable HID usages we can probe from GCKeyboard to recover the physical key
    /// for UIKeyCommand-based Catalyst shortcuts.
    static let catalystPrintableHIDUsages: [UIKeyboardHIDUsage] = {
        var usages = Set(charToHIDUsage.values)
        usages.insert(.keyboardNonUSPound)
        usages.insert(.keyboardNonUSBackslash)
        return usages.sorted { $0.rawValue < $1.rawValue }
    }()
    #endif

}

// MARK: - Key Helpers

extension Ghostty.TerminalView {

    #if !targetEnvironment(macCatalyst)
    private var isPhysicalControlDownForSystemShortcutArbitration: Bool {
        if heldControlSide != .none {
            return true
        }

        #if os(visionOS)
        return false
        #else
        guard isGCKeyboardModifierStateTrusted else {
            return false
        }
        let modifiers = currentModifierFlagsFromGCKeyboard(input: GCKeyboard.coalesced?.keyboardInput)
        return modifiers.contains(.control)
        #endif
    }

    private func shouldPassHardwareCtrlSpaceToSystem(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        return shouldPassHardwareCtrlSpaceToSystem(
            key: key,
            modifiers: key.modifierFlags
        )
    }

    private func shouldPassHardwareCtrlSpaceToSystem(
        key: UIKey,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        guard hasHardwareInputSourceSwitchAvailable else { return false }
        guard key.keyCode == .keyboardSpacebar else { return false }
        var modifiers = normalizedHardwareModifierFlags(modifiers)
        if heldControlSide != .none {
            modifiers.insert(.control)
        }

        guard modifiers.contains(.control),
              !modifiers.contains(.command),
              !modifiers.contains(.alternate),
              !modifiers.contains(.shift) else {
            return false
        }

        // Respect explicit user/external bindings. Built-in terminal handling
        // still yields to iPadOS because Ctrl+Space is its hardware input-source
        // shortcut and delaying it makes the system HUD feel broken.
        let trigger = KeyTrigger(key: .space, modifiers: .control)
        let manager = KeybindManager.shared
        if let keybind = manager.keybind(for: trigger), keybind.source != .default {
            return false
        }
        return !manager.bindingsStartingWith(trigger: trigger)
            .contains { $0.sequence.isSequence && $0.source != .default }
    }
    #endif

    /// Whether a CJK input method is currently active on this view.
    private var isCJKInputMethodActive: Bool {
        #if targetEnvironment(macCatalyst)
        return InputSourceCatalog.catalystCurrentInputSourceHasLanguagePrefix(["zh", "ja", "ko"])
        #else
        guard let lang = textInputMode?.primaryLanguage else { return false }
        return lang.hasPrefix("zh") || lang.hasPrefix("ja") || lang.hasPrefix("ko")
        #endif
    }

    /// True for hardware modifier keys that should never be translated to terminal bytes.
    private func isModifierOnlyKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        switch keyCode {
        case .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
             .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    /// Sync tracked left/right modifier state from the current press set.
    func syncHeldModifierSides(from event: UIPressesEvent?) {
        guard let allPresses = event?.allPresses else { return }

        inputController.heldModifierKeys = Set(allPresses.compactMap { press in
            guard press.phase == .began || press.phase == .changed || press.phase == .stationary,
                  let key = press.key, ModTapState.modifierFlag(for: key.keyCode) != nil else { return nil }
            return key.keyCode
        })

        var leftAlt = false
        var rightAlt = false
        var leftControl = false
        var rightControl = false

        for press in allPresses where press.phase == .began || press.phase == .changed || press.phase == .stationary {
            guard let keyCode = press.key?.keyCode else { continue }
            switch keyCode {
            case .keyboardLeftAlt:
                leftAlt = true
            case .keyboardRightAlt:
                rightAlt = true
            case .keyboardLeftControl:
                leftControl = true
            case .keyboardRightControl:
                rightControl = true
            default:
                break
            }
        }

        heldOptionSide = leftAlt ? (rightAlt ? .both : .left) : (rightAlt ? .right : .none)
        heldControlSide = leftControl ? (rightControl ? .both : .left) : (rightControl ? .right : .none)
    }

    /// Convert UIKit modifier flags to Ghostty modifier bits, preserving right-side
    /// modifier information when we can infer it.
    func ghosttyInputMods(
        from modifiers: UIKeyModifierFlags,
        virtualModifier: ModTapModifier? = nil
    ) -> Ghostty.Input.Mods {
        let normalized = normalizedHardwareModifierFlags(modifiers, virtualModifier: virtualModifier)

        var mods = Ghostty.Input.Mods.none
        if normalized.contains(.command) { mods.insert(.cmd) }
        if normalized.contains(.control) {
            mods.insert(.ctrl)
            if heldControlSide == .right {
                mods.insert(.ctrlRight)
            }
        }
        if normalized.contains(.shift) { mods.insert(.shift) }
        if normalized.contains(.alphaShift) { mods.insert(.caps) }
        if normalized.contains(.alternate) {
            mods.insert(.alt)
            if heldOptionSide == .right {
                mods.insert(.altRight)
            }
        }

        return mods
    }

    /// Some iPad keyboard layouts expose right Option as an AltGr-style Ctrl+Option chord.
    /// Strip the synthetic Control bit unless a real Control key is currently down.
    func normalizedHardwareModifierFlags(
        _ modifiers: UIKeyModifierFlags,
        virtualModifier: ModTapModifier? = nil
    ) -> UIKeyModifierFlags {
        var normalized = modifiers

        let rightOptionHeld = heldOptionSide == .right || heldOptionSide == .both
        if normalized.contains(.control),
           rightOptionHeld,
           heldControlSide == .none,
           virtualModifier != .control {
            normalized.remove(.control)
        }

        return effectiveCapsLockModifiers(normalized)
    }

    /// Caps Lock used as a mod-tap source still toggles at the OS level. All
    /// text, Ghostty events and held mouse flags must use the intended state.
    func effectiveCapsLockModifiers(_ modifiers: UIKeyModifierFlags) -> UIKeyModifierFlags {
        let desiredCapsLock = ModTapManager.shared.activeRulesByKey[.keyboardCapsLock].map {
            $0.tapAction == .none ? userWantsCapsLock : false
        }
        return HardwareKeyboardModifiers.applyingCapsLock(desiredCapsLock, to: modifiers)
    }

    /// iPadOS can strip the Command modifier from certain reserved shortcuts
    /// (for example Cmd+. "cancel") before the key reaches pressesBegan.
    /// Recover the whole Command chord when current GC state agrees with live
    /// modifier transitions; otherwise retain the existing Command-only fallback
    /// when the per-view GameController snapshot is trustworthy. On Mac Catalyst, do not use
    /// GCKeyboard for modifier recovery: its state can remain latched after
    /// system shortcuts like Cmd+H, causing false Command-modified input.
    ///
    /// After focus loss, distrust GCKeyboard-only modifier recovery until we see
    /// a fresh key event whose UIKit modifiers overlap with the GCKeyboard state.
    /// That overlap tells us the snapshot is live again rather than a stale
    /// latched modifier from before deactivation.
    func mergeHardwareCommandChordFromGCKeyboard(
        into modifiers: UIKeyModifierFlags,
        hardwareModifiers: UIKeyModifierFlags
    ) -> UIKeyModifierFlags {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return modifiers
        #else
        if window?.windowScene?.activationState == .foregroundActive {
            // Both a down callback in this activation and a current physical
            // snapshot must agree. A tab switch resets per-view trust, but does
            // not invalidate these app-level transitions. Never use this on
            // Catalyst, where system shortcuts can leave GC state latched.
            let liveModifiers = KeyboardTracker.shared.shortcutRecoveryModifierFlags
                .intersection(currentModifierFlagsFromGCKeyboard(input: GCKeyboard.coalesced?.keyboardInput))
            if liveModifiers.contains(.command) {
                return normalizedHardwareModifierFlags(
                    modifiers.union(liveModifiers), virtualModifier: virtualModTapModifier
                )
            }
        }

        guard !modifiers.contains(.command),
              let input = GCKeyboard.coalesced?.keyboardInput else {
            return modifiers
        }

        let commandHeld =
            (input.button(forKeyCode: .leftGUI)?.isPressed ?? false) ||
            (input.button(forKeyCode: .rightGUI)?.isPressed ?? false)
        guard commandHeld else {
            return modifiers
        }

        let gcKeyboardModifiers = currentModifierFlagsFromGCKeyboard(input: input)
        if !isGCKeyboardModifierStateTrusted {
            let overlappingModifiers = hardwareModifiers.intersection(gcKeyboardModifiers)
            guard !overlappingModifiers.isEmpty else {
                return modifiers
            }
            isGCKeyboardModifierStateTrusted = true
        }

        var merged = modifiers
        merged.insert(.command)
        return merged
        #endif
    }

    #if !os(visionOS)
    func currentModifierFlagsFromGCKeyboard(input: GCKeyboardInput?) -> UIKeyModifierFlags {
        guard let input else { return [] }

        var modifiers: UIKeyModifierFlags = []
        if input.button(forKeyCode: .leftGUI)?.isPressed == true ||
            input.button(forKeyCode: .rightGUI)?.isPressed == true {
            modifiers.insert(.command)
        }
        if input.button(forKeyCode: .leftShift)?.isPressed == true ||
            input.button(forKeyCode: .rightShift)?.isPressed == true {
            modifiers.insert(.shift)
        }
        if input.button(forKeyCode: .leftControl)?.isPressed == true ||
            input.button(forKeyCode: .rightControl)?.isPressed == true {
            modifiers.insert(.control)
        }
        if input.button(forKeyCode: .leftAlt)?.isPressed == true ||
            input.button(forKeyCode: .rightAlt)?.isPressed == true {
            modifiers.insert(.alternate)
        }
        return modifiers
    }
    #endif

    /// Determines whether the Option/Alt modifier should act as terminal Alt/Meta.
    ///
    /// When the Alt modifier comes from a virtual mod-tap key, it always acts as terminal Alt
    /// regardless of the `optionKeyAsAlt` setting (mod-tap Alt is explicitly configured by the user).
    /// For physical Option keys, behavior depends on the setting and which side is held.
    ///
    /// For `.left`/`.right` modes, this relies on `heldOptionSide` being set by `pressesBegan`
    /// before UIKeyCommand handlers fire (normal key event order). If `heldOptionSide` is `.none`
    /// after a state reset, we conservatively return `false` rather than guessing the wrong side.
    /// - Parameter optionInEvent: Whether the triggering key event's modifier
    ///   flags already report Option held. In Left/Right mode the physical side
    ///   is tracked from GameController/`pressesBegan`, which never observe
    ///   synthetic input (e.g. Screen Sharing injecting Option+Arrow into this
    ///   Mac). When the event carries Option but no physical side is known,
    ///   honor the event so injected/remote Option chords act as Alt, matching
    ///   what every AppKit app does by reading the event modifiers directly.
    func shouldOptionActAsAlt(
        virtualModifier: ModTapModifier? = nil,
        optionInEvent: Bool = false
    ) -> Bool {
        // Virtual mod-tap Alt always acts as terminal Meta
        if virtualModifier == .alt {
            return true
        }

        let setting = SettingsStore.shared.value(Settings.Keyboard.optionKeyAsAlt)

        switch setting {
        case .off:
            return false
        case .on:
            return true
        case .left:
            if heldOptionSide == .left || heldOptionSide == .both { return true }
            return optionInEvent && heldOptionSide == .none
        case .right:
            if heldOptionSide == .right || heldOptionSide == .both { return true }
            return optionInEvent && heldOptionSide == .none
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Returns the currently pressed printable HID usage on Catalyst, if one is active.
    func currentCatalystPressedPrintableHIDUsage() -> UIKeyboardHIDUsage? {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return nil }

        for hidUsage in Self.catalystPrintableHIDUsages {
            let gcKeyCode = GCKeyCode(rawValue: Int(hidUsage.rawValue))
            if keyboardInput.button(forKeyCode: gcKeyCode)?.isPressed == true {
                return hidUsage
            }
        }

        return nil
    }
    #endif

    /// Re-translate a physical key after mod-tap changes its modifiers. UIKit
    /// exposes only the base text on iPad; Catalyst can query the active layout.
    private func retranslatedHardwareText(for key: UIKey, modifiers: UIKeyModifierFlags) -> String {
        var layoutText: String?
        #if targetEnvironment(macCatalyst)
        if !Self.specialKeycodes.contains(key.keyCode), let code = cgKeyCode(for: key.keyCode) {
            layoutText = CatalystKeyboardLayout.shared.translateKey(
                cgKeyCode: UInt16(code), shift: modifiers.contains(.shift),
                command: modifiers.contains(.command), option: modifiers.contains(.alternate),
                capsLock: modifiers.contains(.alphaShift)
            )
        }
        #endif
        return HardwareKeyboardText.text(for: key, modifiers: modifiers, layoutText: layoutText)
    }

    /// Derive the printable text Ghostty should use for a physical key.
    /// On Catalyst, prefer the active keyboard layout via UCKeyTranslate.
    func printableTextForGhostty(hidUsage: UIKeyboardHIDUsage, shift: Bool, command: Bool = false) -> String? {
        var modifiers: UIKeyModifierFlags = []
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        return printableTextForGhostty(hidUsage: hidUsage, modifiers: modifiers)
    }

    private func printableTextForGhostty(
        hidUsage: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        fallbackCharacter: Character? = nil
    ) -> String? {
        HardwareKeyboardText.printableText(
            modifiers: modifiers,
            fallbackCharacter: KeyCode(hidUsage: hidUsage)?.literalKeyInput?.first ?? fallbackCharacter
        ) { layoutModifiers in
        #if targetEnvironment(macCatalyst)
            if let cgKeyCode = cgKeyCode(for: hidUsage) {
                return CatalystKeyboardLayout.shared.translateKey(
                    cgKeyCode: UInt16(cgKeyCode), shift: layoutModifiers.contains(.shift),
                    command: layoutModifiers.contains(.command), capsLock: layoutModifiers.contains(.alphaShift)
                )
            }
        #endif
            return nil
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Option-printable presses bypass pressesBegan on Catalyst. Resolve the
    /// same mod-tap/binding policy before GCKeyboard encodes or repeats them.
    func catalystModifierPrintableChord(
        hidUsage: UIKeyboardHIDUsage,
        hardwareModifiers: UIKeyModifierFlags,
        heldModifierKeys: Set<UIKeyboardHIDUsage>
    ) -> ModifierPrintableChord? {
        modTapInterceptor.noteChordUse()
        let hardware = normalizedHardwareModifierFlags(hardwareModifiers)
        func trigger(for modifiers: UIKeyModifierFlags) -> KeyTrigger? {
            let text = printableTextForGhostty(
                hidUsage: hidUsage, shift: false, command: modifiers.contains(.command)
            )
            guard let key = text.flatMap({ KeyCode(uiKeyInput: $0.lowercased()) })
                    ?? KeyCode(hidUsage: hidUsage) else { return nil }
            return normalizedBindingTrigger(KeyTrigger(key: key, modifiers: KeybindModifiers(uiModifierFlags: modifiers)))
        }
        let originalTrigger = trigger(for: hardware)
        let originalIsBound = originalTrigger.map(keybindClaimsTrigger) == true
        let manager = KeybindManager.shared
        let originalControlCharacter = originalTrigger.flatMap { manager.keybind(for: $0)?.action.controlCharacterByte }
        // Direct control actions have no UIKeyCommand, but a sequence sharing
        // this prefix can generate one. That command owns both deliveries of
        // the physical chord; GC must not also advance the sequence, even if
        // UIKit has already processed its delivery and changed pending state.
        if let originalTrigger, originalControlCharacter != nil {
            if originalTrigger.hasKeyCommand(
                in: keyCommands ?? [], action: #selector(handleKeybindCommand(_:))
            ) {
                return nil
            }
            // Prefixes without a registered command remain owned by GC.
            let (handled, keybind) = KeySequenceTracker.shared.consume(owner: self, trigger: originalTrigger)
            if let keybind {
                didHandleOptionKey = true
                executeKeybindAction(keybind.action, parameter: keybind.actionParameter)
                return nil
            }
            if handled {
                didHandleOptionKey = true
                return nil
            }
        }
        guard let chord = ModifierPrintableChord(
            hardware: hardware,
            state: modTapInterceptor.state,
            originalShortcutIsBound: originalIsBound,
            heldKeys: inputController.heldModifierKeys.union(heldModifierKeys),
            optionActsAsAlt: shouldOptionActAsAlt(virtualModifier: virtualModTapModifier, optionInEvent: true),
            originalControlCharacter: originalControlCharacter,
            effectiveControlCharacter: { modifiers in
                trigger(for: modifiers).flatMap { manager.keybind(for: $0)?.action.controlCharacterByte }
            }
        ) else { return nil }

        // UIKit cannot match a shortcut introduced by substitution. Dispatch
        // those here; direct control characters keep the byte/repeat path.
        if chord.modifiers != hardware, let effectiveTrigger = trigger(for: chord.modifiers),
           keybindClaimsTrigger(effectiveTrigger) {
            let isControlCharacter = manager.keybind(for: effectiveTrigger)?.action.isControlCharacter == true
            if !isControlCharacter || manager.isSequencePrefix(effectiveTrigger)
                || KeySequenceTracker.shared.isAwaitingSecondKey {
                didHandleOptionKey = true
                dispatchKeybindTrigger(effectiveTrigger)
                return nil
            }
        }
        return chord
    }

    @discardableResult
    func sendCatalystModifierPrintableChord(
        _ chord: ModifierPrintableChord, hidUsage: UIKeyboardHIDUsage, action: Ghostty.Input.Action
    ) -> Bool {
        if let byte = chord.controlCharacter {
            if action != .release {
                didHandleOptionKey = true
                sendUserInput(Data([byte]))
            }
            return true
        }
        let sent = sendCatalystPrintableKeyViaGhostty(hidUsage: hidUsage, action: action, modifiers: chord.modifiers)
        if sent && action != .release { didHandleOptionKey = true }
        return sent
    }

    /// Whether the current printable Catalyst key can be encoded through Ghostty.
    func canEncodeCatalystPrintableKey(_ hidUsage: UIKeyboardHIDUsage) -> Bool {
        guard surface != nil else { return false }
        guard cgKeyCode(for: hidUsage) != nil else { return false }
        return printableTextForGhostty(hidUsage: hidUsage, shift: false) != nil
            || printableTextForGhostty(hidUsage: hidUsage, shift: true) != nil
    }

    /// Route a printable Catalyst key through Ghostty with physical HID usage.
    @discardableResult
    func sendCatalystPrintableKeyViaGhostty(
        hidUsage: UIKeyboardHIDUsage,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags,
        fallbackCharacter: Character? = nil
    ) -> Bool {
        let modifiers = effectiveCapsLockModifiers(modifiers)
        var mods = Ghostty.Input.Mods.none
        if modifiers.contains(.control) { mods.insert(.ctrl) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.alternate) { mods.insert(.alt) }
        if modifiers.contains(.command) { mods.insert(.cmd) }
        if modifiers.contains(.alphaShift) { mods.insert(.caps) }

        var consumed = Ghostty.Input.Mods.none
        if modifiers.contains(.shift) { consumed.insert(.shift) }

        let keyText = printableTextForGhostty(
            hidUsage: hidUsage, modifiers: modifiers, fallbackCharacter: fallbackCharacter
        )
        guard let keyText else { return false }

        return sendKeyViaGhostty(
            keyCode: hidUsage,
            action: action,
            mods: mods,
            consumedMods: consumed,
            text: keyText,
            unshiftedCodepoint: unshiftedCodepoint(for: hidUsage)
        )
    }
    #endif

    /// Best-effort layout-correct unshifted codepoint for CSI u / Kitty encoding.
    func unshiftedCodepoint(for hidUsage: UIKeyboardHIDUsage, key: UIKey? = nil) -> UInt32 {
        #if targetEnvironment(macCatalyst)
        if let translated = printableTextForGhostty(hidUsage: hidUsage, shift: false),
           let scalar = translated.unicodeScalars.first {
            return scalar.value
        }
        #endif

        if let key {
            let unmodifiedText = key.charactersIgnoringModifiers.precomposedStringWithCanonicalMapping
            if unmodifiedText.count == 1,
               let scalar = unmodifiedText.unicodeScalars.first {
                return scalar.value
            }
        }

        // Sentinel-backed keys have no unshifted codepoint; 0 is correct.
        if let kc = KeyCode(hidUsage: hidUsage),
           let scalar = kc.literalKeyInput?.unicodeScalars.first {
            return scalar.value
        }

        return 0
    }
}

// MARK: - Key Handlers

extension Ghostty.TerminalView {

    /// Handle Ctrl+A-Z key commands (Mac Catalyst only - iOS uses pressesBegan path)
    #if targetEnvironment(macCatalyst)
    @objc func handleControlKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        guard let input = command.input, let char = input.first else { return }

        // UIKeyCommand carries its declared chord, not the live toggle state.
        let modifiers = effectiveCapsLockModifiers(HardwareKeyboardModifiers.applyingCapsLock(
            KeyboardTracker.isCapsLockActive, to: command.modifierFlags
        ))

        // When Shift is also held, route through Ghostty's encoder for correct
        // CSI u / Kitty protocol encoding (Ctrl+Shift is distinct from Ctrl).
        if modifiers.contains(.shift) {
            let hidUsage = currentCatalystPressedPrintableHIDUsage() ?? Self.charToHIDUsage[char]
            if let hidUsage {
                let keyModifiers: UIKeyModifierFlags = modifiers.intersection([.control, .shift, .alphaShift])
                let action: Ghostty.Input.Action = specialKeyPressModifiers[hidUsage] != nil ? .repeat : .press
                if sendCatalystPrintableKeyViaGhostty(
                    hidUsage: hidUsage,
                    action: action,
                    modifiers: keyModifiers,
                    fallbackCharacter: char
                ) {
                    if action == .press {
                        specialKeyPressModifiers[hidUsage] = keyModifiers
                    }
                    return
                }
            }
        }

        let controlByte: UInt8
        if let asciiValue = char.lowercased().first?.asciiValue,
           asciiValue >= 97, asciiValue <= 122 {
            // Ctrl+A through Ctrl+Z map to ASCII 1-26
            controlByte = asciiValue - 96
        } else if let ctrlCode = Self.controlCharacterMap[char] {
            controlByte = ctrlCode
        } else {
            return
        }

        sendUserInput(Data([controlByte]))
    }
    #endif

    /// Dedicated UIKeyCommand handlers fire before `pressesBegan`, so a
    /// presented overlay (tab exposé) must get first refusal here too.
    /// Return/Escape repeats are swallowed until release so a held key can't
    /// leak into the session the overlay just revealed.
    private func overlayConsumedKeyCommand(_ command: UIKeyCommand) -> Bool {
        guard let handler = presentedOverlayKeyHandler,
              let event = OverlayKeyEvent(keyCommand: command) else { return false }
        if keysConsumedByOverlayAction.contains(event.keyCode) { return true }
        guard handler(event) else { return false }
        if event.keyCode == .keyboardReturnOrEnter || event.keyCode == .keyboardEscape {
            keysConsumedByOverlayAction.insert(event.keyCode)
        }
        return true
    }

    @objc func handleArrowKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        guard let input = command.input else { return }
        if overlayConsumedKeyCommand(command) { return }

        if hasDiscoveredSessionRows {
            switch input {
            case UIKeyCommand.inputUpArrow: moveSessionSelection(by: -1)
            case UIKeyCommand.inputDownArrow: moveSessionSelection(by: 1)
            default: break
            }
            return
        }

        // Map UIKeyCommand input to HID usage for Ghostty's key encoder
        let hidUsage: UIKeyboardHIDUsage
        switch input {
        case UIKeyCommand.inputUpArrow:    hidUsage = .keyboardUpArrow
        case UIKeyCommand.inputDownArrow:  hidUsage = .keyboardDownArrow
        case UIKeyCommand.inputRightArrow: hidUsage = .keyboardRightArrow
        case UIKeyCommand.inputLeftArrow:  hidUsage = .keyboardLeftArrow
        default: return
        }

        // Respect optionKeyAsAlt setting. Pass the event's Option so injected/
        // remote arrows (Screen Sharing) act as Alt even though no physical
        // Option side was tracked via GameController.
        var modifiers = normalizedHardwareModifierFlags(command.modifierFlags)
        if modifiers.contains(.alternate) && !shouldOptionActAsAlt(optionInEvent: true) {
            modifiers.remove(.alternate)
        }

        // UIKeyCommand fires repeatedly for key repeat. Use specialKeyPressModifiers
        // to distinguish first press from repeat.
        let action: Ghostty.Input.Action
        if specialKeyPressModifiers[hidUsage] != nil {
            action = .repeat
        } else {
            action = .press
            specialKeyPressModifiers[hidUsage] = modifiers
        }

        sendKeyViaGhostty(keyCode: hidUsage, action: action, modifiers: modifiers)
    }

    @objc func handleReturnKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        if overlayConsumedKeyCommand(command) { return }
        // A one-shot action consumed this press; swallow repeats until release
        // so the held key doesn't leak input into the newly focused session.
        if keysConsumedByOverlayAction.contains(.keyboardReturnOrEnter) { return }
        if hasDiscoveredSessionRows {
            keysConsumedByOverlayAction.insert(.keyboardReturnOrEnter)
            selectHighlightedSession()
            return
        }
        // Check if we need to trigger manual reconnection
        if case .manualReconnectRequired = reconnectionManager?.state {
            keysConsumedByOverlayAction.insert(.keyboardReturnOrEnter)
            manualReconnect()
            return
        }

        // Reset documentBuffer — TUI clears input on submission
        notifyInputDelegateOfExternalChange {
            mutateInputDocument(.reset)
        }

        // Send \r (CR, 0x0D) to session
        if let data = "\r".data(using: .utf8) {
            sendUserInput(data)
        }
    }

    @objc func handleOptionReturnKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        handleModifiedReturnKey(command)
    }

    @objc func handleShiftReturnKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        handleModifiedReturnKey(command)
    }

    @objc func handleModifiedReturnKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        if overlayConsumedKeyCommand(command) { return }
        if keysConsumedByOverlayAction.contains(.keyboardReturnOrEnter) { return }
        if hasDiscoveredSessionRows {
            keysConsumedByOverlayAction.insert(.keyboardReturnOrEnter)
            selectHighlightedSession()
            return
        }
        if case .manualReconnectRequired = reconnectionManager?.state {
            keysConsumedByOverlayAction.insert(.keyboardReturnOrEnter)
            manualReconnect()
            return
        }

        notifyInputDelegateOfExternalChange {
            mutateInputDocument(.reset)
        }

        // UIKeyCommand fires repeatedly while the key is held. Use
        // specialKeyPressModifiers to distinguish first press from repeat,
        // matching handleArrowKey; pressesEnded sends the release.
        let action: Ghostty.Input.Action
        if specialKeyPressModifiers[.keyboardReturnOrEnter] != nil {
            action = .repeat
        } else {
            action = .press
            specialKeyPressModifiers[.keyboardReturnOrEnter] = command.modifierFlags
        }
        sendKeyViaGhostty(
            keyCode: .keyboardReturnOrEnter,
            action: action,
            modifiers: command.modifierFlags
        )
    }

    @objc func handleEscapeKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // UIKit can route modified Escape through its plain-Escape command.
        // Recover the held modifiers before treating it as terminal Escape.
        if !KeyboardTracker.isSystemCancelChordPhysicallyDown() {
            let modifiers = command.modifierFlags.union(KeyboardTracker.shared.shortcutRecoveryModifierFlags)
            if consumeVisorShortcut(KeyTrigger(key: .escape,
                modifiers: KeybindModifiers(uiModifierFlags: modifiers))) { return }
        }
        #endif
        if enclosingSplitHost?.cancelPaneDrag() == true {
            keysConsumedByOverlayAction.insert(.keyboardEscape)
            return
        }
        // The reserved Cmd+Period system-cancel chord can arrive as a
        // translated plain Escape. Give a cmd+period binding first refusal; a
        // twin of a chord delivery already handled on another rail is
        // swallowed. Unbound falls through to normal Escape behavior below,
        // which is exactly the chord's default. This never fires for a real
        // Escape press because the Escape key itself is physically down then.
        if command.modifierFlags.isEmpty,
           KeyboardTracker.isSystemCancelChordPhysicallyDown() {
            guard inputController.consumeSystemCancelChordDelivery() else { return }
            if dispatchKeybindTrigger(.commandPeriod) { return }
        }

        commitKoreanCompositionIfNeeded(external: true)
        if overlayConsumedKeyCommand(command) { return }
        if keysConsumedByOverlayAction.contains(.keyboardEscape) { return }
        if dismissSessionDiscoveryIfPresented() {
            keysConsumedByOverlayAction.insert(.keyboardEscape)
            return
        }
        if aiAgentOverlayActive {
            // If AI Agent is active, Escape should close it
            keysConsumedByOverlayAction.insert(.keyboardEscape)
            NotificationCenter.default.post(name: .toggleAIAgent, object: self)
            return
        }
        // tmux control-mode gateway: ESC gracefully detaches (matches the in-TUI
        // menu the core prints). Hardware ESC arrives here via UIKeyCommand on
        // Catalyst. Fires if `self` is the gateway view OR the selected tab is the
        // gateway.
        if let target = selectedTmuxGatewayView() ?? ((tmuxController?.isActive == true || isTmuxGatewaySurfaceActive) ? self : nil) {
            keysConsumedByOverlayAction.insert(.keyboardEscape)
            target.sendTmuxDetach()
            return
        }
        if detachHerdrGatewayIfCovered() {
            keysConsumedByOverlayAction.insert(.keyboardEscape)
            return
        }

        // If Escape is a mod-tap source key, defer to the interceptor.
        // The UIKeyCommand fires before pressesBegan, so we need to manually
        // route through the interceptor for mod-tap to work.
        if !command.modifierFlags.contains(.alternate),
           let rule = ModTapManager.shared.activeRulesByKey[.keyboardEscape] {
            modTapInterceptor.startPending(for: rule)
            return
        }

        // Send ESC (0x1B) to session, or ESC+ESC for Option+Escape (only if Alt mode)
        var sequence = "\u{1B}"
        if command.modifierFlags.contains(.alternate) && shouldOptionActAsAlt(optionInEvent: true) {
            sequence = "\u{1B}" + sequence
        }
        if let data = sequence.data(using: .utf8) {
            sendUserInput(data)
        }
    }

    /// Fallback for Apple's reserved Cmd+Period system-cancel chord when no
    /// keybind claims cmd+period (KeybindCommandGenerator only registers this
    /// command then).
    @objc func handleSystemCancelCommand(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard inputController.consumeSystemCancelChordDelivery() else { return }
        handleSystemCancelChordDelivery()
    }

    /// Catalyst menu rail for the reserved chord: macOS delivers Cmd+Period to
    /// no responder UIKeyCommand or press event at all, so a menu key
    /// equivalent (the same mechanism as Xcode's ⌘. Stop item) is the one rail
    /// that both receives and consumes it — consuming also suppresses the
    /// system beep. ShortcutCaptureUIView implements this selector too and
    /// wins while it is first responder, so recording works.
    @objc func menuSystemCancel(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        guard inputController.consumeSystemCancelChordDelivery() else { return }
        handleSystemCancelChordDelivery()
    }

    /// One normalized chord press: binding dispatch first, then overlay cancel
    /// semantics, then a single one-shot ESC byte. A plain byte (not the
    /// enhanced-protocol press/release pair) is correct for a synthesized
    /// chord. Deliberately one-shot: no rail auto-repeats a reserved chord,
    /// and self-driven repeat is not attempted.
    private func handleSystemCancelChordDelivery() {
        commitKoreanCompositionIfNeeded(external: true)
        if dispatchKeybindTrigger(.commandPeriod) { return }
        let cancelEvent = OverlayKeyEvent(
            keyCode: .keyboardEscape,
            modifiers: [],
            characters: UIKeyCommand.inputEscape
        )
        if presentedOverlayKeyHandler?(cancelEvent) == true { return }
        if dismissSessionDiscoveryIfPresented() { return }
        if aiAgentOverlayActive {
            NotificationCenter.default.post(name: .toggleAIAgent, object: self)
            return
        }
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        sendUserInput(Data([0x1B]))
    }

    #if targetEnvironment(macCatalyst)
    /// Handle dynamically registered mod-tap source key commands on Catalyst.
    /// These keys are routed through UIKeyCommand so mod-tap can track tap/hold.
    @objc func handleModTapSourceKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard command.modifierFlags.isEmpty, let input = command.input else { return }

        // Match command input back to an active mod-tap rule source key.
        if let rule = inputController.modTapRule(forCommandInput: input) {
            modTapInterceptor.startPending(for: rule)
        }
    }
    #endif

    @objc func handleTabKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        if overlayConsumedKeyCommand(command) { return }
        if command.modifierFlags.isEmpty,
           let rule = ModTapManager.shared.activeRulesByKey[.keyboardTab] {
            modTapInterceptor.startPending(for: rule)
            return
        }

        // Send \t to session, or ESC+\t for Option+Tab (only if Alt mode)
        var sequence = "\t"
        if command.modifierFlags.contains(.alternate) && shouldOptionActAsAlt(optionInEvent: true) {
            sequence = "\u{1B}" + sequence
        }
        if let data = sequence.data(using: .utf8) {
            sendUserInput(data)
        }
    }

    @objc func handleShiftTabKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        if overlayConsumedKeyCommand(command) { return }
        // Send backtab escape sequence \e[Z to session
        if let data = "\u{1B}[Z".data(using: .utf8) {
            sendUserInput(data)
        }
    }

    /// Handle function key UIKeyCommands (F1-F12 with optional modifiers).
    /// This is intentionally a no-op. The UIKeyCommand registration with
    /// `wantsPriorityOverSystemBehavior = true` claims F-keys from macOS
    /// (preventing brightness, Mission Control, etc.). Actual key processing
    /// happens in the `pressesBegan` → `processKeyPress` → `sendKeyViaGhostty`
    /// path. Processing here too would cause double key events on Mac Catalyst.
    @objc func handleFunctionKey(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        // No-op: see comment above.
    }

    @objc func increaseFontSize(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard surface != nil, ghosttyApp != nil else { return }
        Ghostty.logger.info("Increasing font size for this tab")
        // tmux: change the whole window uniformly; re-sync via handleCellSizeChange.
        if applyTmuxWindowFontSize(delta: 1) { return }
        changeLocalFontSize(delta: 1)

        // Update PTY size after Ghostty recalculates grid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            self.updatePTYSize()
        }
    }

    @objc func decreaseFontSize(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard surface != nil, ghosttyApp != nil else { return }
        Ghostty.logger.info("Decreasing font size for this tab")
        if applyTmuxWindowFontSize(delta: -1) { return }
        changeLocalFontSize(delta: -1)

        // Update PTY size after Ghostty recalculates grid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            self.updatePTYSize()
        }
    }

    @objc func resetFontSizeToDefault(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard surface != nil, ghosttyApp != nil else { return }
        Ghostty.logger.info("Resetting font size to default for this tab")
        if resetTmuxWindowFontSize() { return }
        resetLocalFontSize()

        // Update PTY size after Ghostty recalculates grid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            self.updatePTYSize()
        }
    }
}

// MARK: - Split Management Handlers

extension Ghostty.TerminalView {

    @objc func splitRight(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .createSplit,
            object: self,
            userInfo: ["direction": "right"]
        )
    }

    @objc func splitDown(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .createSplit,
            object: self,
            userInfo: ["direction": "down"]
        )
    }

    @objc func navigateSplitLeft(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .navigateSplit,
            object: self,
            userInfo: ["direction": "left"]
        )
    }

    @objc func navigateSplitRight(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .navigateSplit,
            object: self,
            userInfo: ["direction": "right"]
        )
    }

    @objc func navigateSplitUp(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .navigateSplit,
            object: self,
            userInfo: ["direction": "up"]
        )
    }

    @objc func navigateSplitDown(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .navigateSplit,
            object: self,
            userInfo: ["direction": "down"]
        )
    }

    @objc func closeSplit(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        Ghostty.logger.info("TerminalView.closeSplit called on terminal \(self.uuid.uuidString.prefix(8))")
        NotificationCenter.default.post(
            name: .closeSplit,
            object: self,
            userInfo: ["windowId": windowId]
        )
    }

    @objc func toggleSplitZoom(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .toggleSplitZoom,
            object: self
        )
    }

    @objc func equalizeSplits(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .equalizeSplits,
            object: self
        )
    }
}

// MARK: - Tab Management Handlers

extension Ghostty.TerminalView {

    @objc func newTab(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .newTab,
            object: self,
            userInfo: ["windowId": windowId]
        )
    }

    @objc func newWindow(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .newWindow,
            object: self,
            userInfo: ["windowId": windowId]
        )
    }

    @objc func duplicateTabWithSSH(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .duplicateTabWithSSH,
            object: self
        )
    }

    @objc func previousTab(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .previousTab,
            object: self
        )
    }

    @objc func nextTab(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .nextTab,
            object: self
        )
    }

    @objc func selectTab(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        guard let input = command.input, let tabIndex = Int(input) else { return }
        NotificationCenter.default.post(
            name: .selectTab,
            object: self,
            userInfo: ["tabIndex": tabIndex]
        )
    }

    @objc func openSettings(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .openSettings,
            object: self
        )
    }

    @objc func createLocalShell(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .createLocalShell,
            object: self
        )
    }

    @objc func browseHosts(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        NotificationCenter.default.post(
            name: .browseHosts,
            object: self
        )
    }

    @objc func toggleAIAgent(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        Ghostty.logger.info("toggleAIAgent UIKeyCommand triggered")
        NotificationCenter.default.post(
            name: .toggleAIAgent,
            object: self
        )
    }

    @objc func findInTerminal(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        performActionAsync("start_search")
    }

    // MARK: - Menu Action Methods (for sendAction via responder chain)
    // These methods are called via UIApplication.shared.sendAction() from SwiftUI Commands.
    // They post notifications with `self` as the object so MainView can route to the correct window.

    @objc func menuNewTab(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .newTab, object: self)
    }

    @objc func menuNewWindow(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .newWindow, object: self)
    }

    @objc func menuCreateLocalShell(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .createLocalShell, object: self)
    }

    @objc func menuDuplicateTabWithSSH(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .duplicateTabWithSSH, object: self)
    }

    @objc func menuPreviousTab(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .previousTab, object: self)
    }

    @objc func menuNextTab(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .nextTab, object: self)
    }

    @objc func menuSelectTab1(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 1])
    }

    @objc func menuSelectTab2(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 2])
    }

    @objc func menuSelectTab3(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 3])
    }

    @objc func menuSelectTab4(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 4])
    }

    @objc func menuSelectTab5(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 5])
    }

    @objc func menuSelectTab6(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 6])
    }

    @objc func menuSelectTab7(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 7])
    }

    @objc func menuSelectTab8(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 8])
    }

    @objc func menuSelectTab9(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .selectTab, object: self, userInfo: ["tabIndex": 9])
    }

    @objc func menuSplitRight(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .createSplit, object: self, userInfo: ["direction": "right"])
    }

    @objc func menuSplitLeft(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .createSplit, object: self, userInfo: ["direction": "left"])
    }

    @objc func menuSplitDown(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .createSplit, object: self, userInfo: ["direction": "down"])
    }

    @objc func menuSplitUp(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .createSplit, object: self, userInfo: ["direction": "up"])
    }

    @objc func menuNavigateSplitLeft(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .navigateSplit, object: self, userInfo: ["direction": "left"])
    }

    @objc func menuNavigateSplitRight(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .navigateSplit, object: self, userInfo: ["direction": "right"])
    }

    @objc func menuNavigateSplitUp(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .navigateSplit, object: self, userInfo: ["direction": "up"])
    }

    @objc func menuNavigateSplitDown(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .navigateSplit, object: self, userInfo: ["direction": "down"])
    }

    @objc func menuCloseSplit(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .closeSplit, object: self)
    }

    @objc func menuToggleSplitZoom(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleSplitZoom, object: self)
    }

    @objc func menuEqualizeSplits(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .equalizeSplits, object: self)
    }

    @objc func menuOpenSettings(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .openSettings, object: self)
    }

    @objc func menuBrowseHosts(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .browseHosts, object: self)
    }

    @objc func menuBrowseProfiles(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .browseProfiles, object: self)
    }

    @objc func menuToggleAIAgent(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        Ghostty.logger.info("menuToggleAIAgent triggered")
        NotificationCenter.default.post(name: .toggleAIAgent, object: self)
    }

    @objc func menuToggleVoiceAgent(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleVoiceAgent, object: self)
    }

    @objc func menuToggleTabBar(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleTabBar, object: self)
    }

    @objc func menuToggleGroupMode(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleGroupMode, object: self)
    }

    @objc func menuToggleTabSwitcher(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .showTabSwitcher, object: self)
    }

    @objc func menuToggleTabExpose(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleTabExpose, object: self)
    }

    @objc func menuPreviousGroup(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .previousGroup, object: self)
    }

    @objc func menuNextGroup(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .nextGroup, object: self)
    }

    @objc func menuShowTmuxSessions(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .showTmuxSessions, object: self)
    }

    @objc func menuDiscoverSessions(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .discoverSessions, object: self)
    }

    @objc func menuDetachSession(_ sender: Any?) {
        NotificationCenter.default.post(name: .detachSession, object: self)
    }

    @objc func menuDetachOtherClients(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .detachOtherClients, object: self)
    }

    @objc func menuToggleTransparency(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleTransparency, object: self)
    }

    @objc func menuToggleTitleBar(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleTitleBar, object: self)
    }

    @objc func menuToggleAutoRedact(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleAutoRedact, object: self)
    }

    @objc func menuToggleBackgroundEffect(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleBackgroundEffect, object: self)
    }

    @objc func menuToggleFullScreen(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleFullScreen, object: self)
    }

    @objc func menuBrightnessBoost(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        // The menu sends this up the responder chain, so it lands on the
        // focused terminal — toggle that surface's brightness HUD directly.
        toggleBrightnessHUD()
    }

    // Terminal actions - use ghostty_surface_binding_action
    // Note: Copy/Paste/Select All are handled by system Edit menu routing to responder chain
    @objc func menuClearScreen(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        performActionAsync("clear_screen")
    }

    @objc func menuScrollPageUp(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        performActionAsync("scroll_page_up")
    }

    @objc func menuScrollPageDown(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        performActionAsync("scroll_page_down")
    }

    @objc func menuScrollToTop(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        performActionAsync("scroll_to_top")
    }

    @objc func menuScrollToBottom(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        performActionAsync("scroll_to_bottom")
    }

    @objc func menuToggleQuickSettings(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleQuickSettings, object: self)
    }

    @objc func menuOpenInFolder(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .openInFolder, object: self)
    }

    @objc func menuToggleThemePicker(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleThemePicker, object: self)
    }

    @objc func menuToggleClipboardManager(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        NotificationCenter.default.post(name: .toggleClipboardManager, object: self)
    }

    @objc func menuToggleCompose(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        if showComposeOverlay {
            becomeFirstResponder()
        }
        showComposeOverlay.toggle()
        NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: self)
    }

    @objc func menuToggleMouseCapture(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        toggleMouseReporting()
    }

    @objc func menuCycleInputSource(_ sender: Any?) {
        noteModTapCommand(sender as? UIKeyCommand)
        cycleInputSource()
    }
}

// MARK: - Keybind System Integration

extension Ghostty.TerminalView {

    /// UIKit can dispatch an action without a raw key-down. Mark the chord
    /// before the action can move focus or its source can be released.
    func noteModTapCommand(_ command: UIKeyCommand? = nil) {
        guard let source = modTapInterceptor.state?.sourceKey else { return }
        if let command {
            // Escape/Tab/printable source commands also arrive on key repeat.
            if command.modifierFlags.isEmpty, KeyCode(hidUsage: source)?.uiKeyInput == command.input { return }
        } else if ModTapState.modifierFlag(for: source) == nil {
            // Menu/edit actions without a key identity only prove chord use
            // for modifier sources, not for a pending printable source key.
            return
        }
        modTapInterceptor.noteChordUse()
    }

    private func keybindClaimsTrigger(_ trigger: KeyTrigger) -> Bool {
        let manager = KeybindManager.shared
        let sequence = KeySequenceTracker.shared
        return manager.keybind(for: trigger) != nil || manager.isSequencePrefix(trigger)
            || (sequence.isAwaitingSecondKey && sequence.possibleBindings.contains { $0.sequence.triggers.last == trigger })
    }

    private func normalizedBindingTrigger(_ trigger: KeyTrigger) -> KeyTrigger {
        @MainActor
        func isClaimed(_ candidate: KeyTrigger) -> Bool {
            let sequence = KeySequenceTracker.shared
            if sequence.isAwaitingSecondKey {
                return sequence.possibleBindings.contains { $0.sequence.triggers.last == candidate }
            }
            return keybindClaimsTrigger(candidate)
        }
        return trigger.resolvingShiftedSymbol(isClaimed: isClaimed)
    }

    /// Handler for dynamically bound keyboard shortcuts from KeybindCommandGenerator
    @objc func handleKeybindCommand(_ command: UIKeyCommand) {
        noteModTapCommand(command)
        commitKoreanCompositionIfNeeded(external: true)
        // An Option chord (⌘⌥[) still reaches the text input system as its
        // composed character ("“"); insertText would turn that into ESC+[.
        if command.modifierFlags.contains(.alternate) { didHandleOptionKey = true }
        guard let commandTrigger = KeyTrigger(uiKeyCommand: command) else {
            Ghostty.logger.warning("handleKeybindCommand: Failed to parse trigger from command")
            return
        }

        if consumeVisorShortcut(commandTrigger) { return }

        // A custom plain-Escape binding may own the command that a translated
        // Cmd+Period delivery lands on. Give the physical chord first refusal
        // at a cmd+period binding before dispatching Escape.
        if commandTrigger.key == .escape,
           commandTrigger.modifiers.isEmpty,
           KeyboardTracker.isSystemCancelChordPhysicallyDown() {
            guard inputController.consumeSystemCancelChordDelivery() else { return }
            if dispatchKeybindTrigger(.commandPeriod) { return }
        } else if commandTrigger == .commandPeriod {
            // Reject a twin of a chord delivery already handled on another rail.
            guard inputController.consumeSystemCancelChordDelivery() else { return }
        }

        // A user-bound navigation key (arrow/Return/Tab/Escape/digit) still
        // belongs to a presented overlay before the keybind runs. Do this after
        // normalizing Cmd+Period above because UIKit can translate that chord
        // into plain Escape, which must not cancel the overlay when it is bound.
        if overlayConsumedKeyCommand(command) { return }

        guard dispatchKeybindTrigger(commandTrigger) else {
            let trigFormat = commandTrigger.ghosttyFormat
            Ghostty.logger.debug("handleKeybindCommand: No action for trigger \(trigFormat)")
            return
        }
    }

    /// Claim only the user's active Visor binding. Plain Escape and previous
    /// bindings remain terminal input after a remap or when Visor is disabled.
    @discardableResult
    private func consumeVisorShortcut(_ trigger: KeyTrigger) -> Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let binding = KeybindManager.shared.keybind(for: trigger),
              binding.action == .toggle_visor else { return false }
        if trigger.key == .escape {
            guard !keysConsumedByOverlayAction.contains(.keyboardEscape) else { return true }
            keysConsumedByOverlayAction.insert(.keyboardEscape)
        }
        commitKoreanCompositionIfNeeded(external: true)
        NotificationCenter.default.post(name: .toggleVisorOverlay, object: self)
        return true
        #else
        return false
        #endif
    }

    /// Route a normalized trigger through sequence handling and then the active
    /// keybind table. Returns false only when no binding or sequence claims it.
    @discardableResult
    func dispatchKeybindTrigger(_ trigger: KeyTrigger) -> Bool {
        // Route through KeySequenceTracker so sequence prefixes (Ctrl+A→N) and
        // ambiguous prefix+direct bindings are handled correctly. The tracker
        // short-circuits for triggers that are neither awaiting nor prefixes.
        let (handled, trackerKeybind) = KeySequenceTracker.shared.consume(
            owner: self,
            trigger: trigger
        )
        if let trackerKeybind {
            let actionName = trackerKeybind.action.rawValue
            Ghostty.logger.debug("Executing keybind action (via tracker): \(actionName)")
            executeKeybindAction(trackerKeybind.action, parameter: trackerKeybind.actionParameter)
            return true
        }
        if handled {
            // Prefix swallowed; pending-direct-action (if any) will fire on timeout.
            return true
        }

        // Look up keybind in KeybindManager (includes action parameter)
        guard let keybind = KeybindManager.shared.keybind(for: trigger) else {
            return false
        }

        let actionName = keybind.action.rawValue
        Ghostty.logger.debug("Executing keybind action: \(actionName)")
        executeKeybindAction(keybind.action, parameter: keybind.actionParameter)
        return true
    }

    /// Install the tracker's timeout callback. The callback dispatches the
    /// pending direct action (the single-key binding that the prefix
    /// temporarily shadowed) when the user presses and holds the prefix past
    /// the 1s window. Called from `didMoveToWindow` once per lifecycle; the
    /// tracker snapshots the callback at arm-time so a later reinstall from a
    /// different view can't redirect an already-armed fallback.
    func installSequenceTrackerTimeoutHandler() {
        KeySequenceTracker.shared.onTimeoutDirectAction = { [weak self] keybind in
            guard let self else { return }
            self.executeKeybindAction(keybind.action, parameter: keybind.actionParameter)
        }
    }

    /// Execute a keybind action with optional parameter
    func executeKeybindAction(_ action: KeybindAction, parameter: String? = nil) {
        // Handle terminal actions (sent to libghostty)
        if action.isTerminalAction {
            // Send data actions (text:/esc:/csi: from ghostty config).
            if action == .send_text, let param = parameter {
                let decoded = Keybind.decodeEscapeSequence(param)
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                sendUserInput(decoded)
                return
            }
            if action == .send_esc, let param = parameter {
                var data = Data([0x1B])
                data.append(Data(param.utf8))
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                sendUserInput(data)
                return
            }
            if action == .send_csi, let param = parameter {
                var data = Data([0x1B, 0x5B])
                data.append(Data(param.utf8))
                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                sendUserInput(data)
                return
            }

            if let controlByte = action.controlCharacterByte {
                // Control character (Ctrl+A-Z)
                let controlString = String(UnicodeScalar(controlByte))

                // Handle Ctrl-C for local shell interrupt
                #if !targetEnvironment(macCatalyst)
                if controlByte == 3, let localSession = session as? LocalShellSession {
                    if !localSession.hasActiveEmbeddedSession {
                        localSession.interrupt()
                        return
                    }
                }
                #endif

                if let data = controlString.data(using: .utf8) {
                    sendUserInput(data)
                }
                return
            }

            // Handle copy/paste specially - use responder chain methods which work correctly
            // (ghostty_surface_binding_action for paste requires pendingClipboardPasteSurface to be set)
            if action == .copy_to_clipboard {
                copy(nil)
                return
            }
            if action == .paste_from_clipboard {
                paste(nil)
                return
            }

            // Other terminal actions via ghostty_surface_binding_action
            if let actionString = action.ghosttyActionString {
                performActionAsync(actionString)
            }
            return
        }

        // Handle app actions (via notifications)
        var userInfo: [String: Any] = [:]

        // Add context info based on action type
        switch action {
        case .split_right:
            userInfo["direction"] = "right"
        case .split_down:
            userInfo["direction"] = "down"
        case .navigate_split_left:
            userInfo["direction"] = "left"
        case .navigate_split_right:
            userInfo["direction"] = "right"
        case .navigate_split_up:
            userInfo["direction"] = "up"
        case .navigate_split_down:
            userInfo["direction"] = "down"
        case .select_tab_1:
            userInfo["tabIndex"] = 1
        case .select_tab_2:
            userInfo["tabIndex"] = 2
        case .select_tab_3:
            userInfo["tabIndex"] = 3
        case .select_tab_4:
            userInfo["tabIndex"] = 4
        case .select_tab_5:
            userInfo["tabIndex"] = 5
        case .select_tab_6:
            userInfo["tabIndex"] = 6
        case .select_tab_7:
            userInfo["tabIndex"] = 7
        case .select_tab_8:
            userInfo["tabIndex"] = 8
        case .select_tab_9:
            userInfo["tabIndex"] = 9
        case .new_tab, .new_window, .close_tab:
            userInfo["windowId"] = windowId
        case .open_profile:
            if let parameter {
                userInfo["profileID"] = parameter
            }
        default:
            break
        }

        // Font size actions need special handling
        switch action {
        case .increase_font_size:
            guard surface != nil, ghosttyApp != nil else { return }
            // Use parameter if provided (e.g., "increase_font_size:2"), default to 1
            let delta = Int(parameter ?? "") ?? 1
            if applyTmuxWindowFontSize(delta: delta) { return }
            changeLocalFontSize(delta: delta)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.updatePTYSize()
            }
            return

        case .decrease_font_size:
            guard surface != nil, ghosttyApp != nil else { return }
            // Use parameter if provided (e.g., "decrease_font_size:2"), default to 1
            let delta = Int(parameter ?? "") ?? 1
            if applyTmuxWindowFontSize(delta: -delta) { return }
            changeLocalFontSize(delta: -delta)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.updatePTYSize()
            }
            return

        case .reset_font_size:
            guard surface != nil, ghosttyApp != nil else { return }
            if resetTmuxWindowFontSize() { return }
            resetLocalFontSize()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.updatePTYSize()
            }
            return

        case .start_search:
            performActionAsync("start_search")
            return

        case .toggle_compose:
            if showComposeOverlay {
                becomeFirstResponder()
            }
            showComposeOverlay.toggle()
            NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: self)
            return

        case .toggle_mouse_capture:
            toggleMouseReporting()
            return

        case .brightness_boost:
            toggleBrightnessHUD()
            return

        case .cycle_input_source:
            cycleInputSource()
            return

        default:
            break
        }

        // Post notification for app actions
        if let notificationName = action.notificationName {
            if userInfo.isEmpty {
                NotificationCenter.default.post(name: notificationName, object: self)
            } else {
                NotificationCenter.default.post(name: notificationName, object: self, userInfo: userInfo)
            }
        }
    }
}
