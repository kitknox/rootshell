//
//  TerminalInputController.swift
//  rootshell
//
//  Owns per-terminal keyboard/input state on behalf of TerminalView.
//

import UIKit
import GhosttyKit

@MainActor
final class TerminalInputController {
    /// Key repeat manager for physical and command-routed keys.
    let keyRepeatManager = Ghostty.KeyRepeatManager()

    /// Mod-tap interceptor for dual-function keys (for example Caps Lock = Esc/Ctrl).
    let modTapInterceptor = Ghostty.ModTapInterceptor()

    /// Active virtual modifier supplied by a held mod-tap key.
    var virtualModTapModifier: ModTapModifier?

    /// Tracks user's intended Caps Lock state when Caps Lock is configured as a mod-tap key with tap=none.
    var userWantsCapsLock = false

    /// Cached key commands, rebuilt when keybinds or mod-tap source keys change.
    var cachedKeyCommands: [UIKeyCommand]?

    #if targetEnvironment(macCatalyst)
    /// Signature of mod-tap source keys used for the cached keyCommands array.
    var cachedModTapKeyCommandSignature: String?
    #endif

    /// Prevents duplicate Option-key text handling when UIKit also calls insertText.
    var didHandleOptionKey = false

    /// Prevents duplicate session-picker digit handling when UIKit also calls insertText.
    var didHandleSessionPickerKey = false

    /// Physical Option-key side tracking for Option-as-Alt and AltGr normalization.
    var heldOptionSide: Ghostty.HeldOptionSide = .none

    /// Physical Control-key side tracking for AltGr normalization and right-Control reporting.
    var heldControlSide: Ghostty.HeldControlSide = .none

    /// Press-time modifiers for special keys routed through Ghostty, so release events match.
    var specialKeyPressModifiers: [UIKeyboardHIDUsage: UIKeyModifierFlags] = [:]

    /// Keys whose UIKeyCommand press was consumed by a one-shot overlay action
    /// (session picker select, manual reconnect, AI agent toggle, tmux detach).
    /// Repeat invocations of the held key are swallowed until release so they
    /// don't leak into whatever gained focus after the action.
    var keysConsumedByOverlayAction: Set<UIKeyboardHIDUsage> = []

    /// Hardware modifiers currently held, tracked for mouse event modifier state.
    var heldHardwareModifiers: Ghostty.Input.Mods = .none

    /// Whether GCKeyboard modifier snapshots can currently be trusted.
    var isGCKeyboardModifierStateTrusted = true

    /// UIKit can deliver one physical press of the Cmd+Period system-cancel
    /// chord through both a UIKeyCommand and pressesBegan within milliseconds
    /// (the same twin-delivery behavior ShortcutCaptureUIView dedups).
    /// Time-based so a delivery whose release never reaches pressesEnded
    /// (UIKeyCommand-only rail) cannot wedge the latch.
    private var lastSystemCancelDeliveryTime: CFTimeInterval = 0
    private static let systemCancelDuplicateWindow: CFTimeInterval = 0.05

    /// True for the first delivery of a physical chord press; twins are rejected.
    func consumeSystemCancelChordDelivery() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastSystemCancelDeliveryTime > Self.systemCancelDuplicateWindow else { return false }
        lastSystemCancelDeliveryTime = now
        return true
    }

    func invalidateKeyCommandCache() {
        cachedKeyCommands = nil
        #if targetEnvironment(macCatalyst)
        cachedModTapKeyCommandSignature = nil
        #endif
    }

    func keyCommands(
        hasMarkedText: Bool,
        isPhysicalControlDownForSystemShortcutArbitration: Bool
    ) -> [UIKeyCommand]? {
        #if targetEnvironment(macCatalyst)
        let currentModTapSignature = ModTapManager.shared.activeRulesByKey.keys
            .map { String($0.rawValue) }
            .sorted()
            .joined(separator: ",")
        if let cached = cachedKeyCommands,
           cachedModTapKeyCommandSignature == currentModTapSignature {
            return Self.filterForIME(cached, hasMarkedText: hasMarkedText)
        }
        #else
        // iPadOS checks a focused responder's keyCommands before delivering
        // hardware key presses. While physical Control is down, keep the terminal
        // out of that shortcut-arbitration path so system Control+Space input
        // source switching is not delayed by terminal command matching.
        if isPhysicalControlDownForSystemShortcutArbitration {
            return nil
        }

        if let cached = cachedKeyCommands {
            return Self.filterForIME(cached, hasMarkedText: hasMarkedText)
        }
        #endif

        var commands: [UIKeyCommand] = []

        // On Mac Catalyst, Ctrl+A-Z must be registered as UIKeyCommands
        // because pressesBegan doesn't reliably receive these key events.
        // UIKeyCommand also properly routes through the responder chain for multi-window.
        // On iOS/visionOS, these are handled directly in pressesBegan via KeybindManager.
        #if targetEnvironment(macCatalyst)
        for char in "abcdefghijklmnopqrstuvwxyz" {
            let command = UIKeyCommand(
                input: String(char),
                modifierFlags: .control,
                action: #selector(Ghostty.TerminalView.handleControlKey(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            command.allowKeyRepeat()
            commands.append(command)
        }
        // Ctrl+symbol/digit combinations that produce standard terminal control codes.
        for char in " 2345678-/\\[]`" {
            let command = UIKeyCommand(
                input: String(char),
                modifierFlags: .control,
                action: #selector(Ghostty.TerminalView.handleControlKey(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            command.allowKeyRepeat()
            commands.append(command)
        }
        // Ctrl+Shift+key variants: register for letters and symbols so they
        // don't fall through to the system responder chain.
        for char in " abcdefghijklmnopqrstuvwxyz2345678-/\\[]`" {
            let command = UIKeyCommand(
                input: String(char),
                modifierFlags: [.control, .shift],
                action: #selector(Ghostty.TerminalView.handleControlKey(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            command.allowKeyRepeat()
            commands.append(command)
        }

        // On Mac Catalyst, add mod-tap source key commands for active rules.
        // This captures alphanumeric/symbol source keys that bypass pressesBegan.
        commands.append(contentsOf: generateModTapSourceCommands())
        #endif

        // Add dynamically generated keybind commands from KeybindCommandGenerator.
        // On iOS 26+, SwiftUI Commands handle menu shortcuts, so we only include
        // special key commands and actions not handled by menus.
        if #available(iOS 26, *) {
            commands.append(contentsOf: KeybindCommandGenerator.shared.commandsForIOS26Plus)
        } else {
            commands.append(contentsOf: KeybindCommandGenerator.shared.commandsForLegacyIOS)

            #if !targetEnvironment(macCatalyst)
            // iPadOS < 26 snapshots a responder's keyCommands for system-shortcut
            // arbitration before Control is held, so the dynamic `keyCommands -> nil`
            // short-circuit does not remove us from Ctrl+Space arbitration in time.
            // Strip Control-modified commands statically; hardware Control chords
            // are handled in pressesBegan.
            commands.removeAll { $0.modifierFlags.contains(.control) }
            #endif
        }

        cachedKeyCommands = commands
        #if targetEnvironment(macCatalyst)
        cachedModTapKeyCommandSignature = currentModTapSignature
        #endif
        return Self.filterForIME(commands, hasMarkedText: hasMarkedText)
    }

    /// During IME composition, filter out commands for keys the IME needs
    /// (Return, Escape, Tab, Space, Arrows without CMD/Ctrl modifiers).
    /// UIKeyCommands fire before the text input system, so they must be
    /// removed for the IME to see these keys.
    private static func filterForIME(_ commands: [UIKeyCommand], hasMarkedText: Bool) -> [UIKeyCommand] {
        guard hasMarkedText else { return commands }
        let imeConflictInputs: Set<String> = [
            "\r", UIKeyCommand.inputEscape, "\t", " ",
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow
        ]
        return commands.filter { command in
            guard let input = command.input, imeConflictInputs.contains(input) else { return true }
            // Keep commands with CMD or Ctrl (Cmd+Arrow for split nav, etc.).
            return !command.modifierFlags.intersection([.command, .control]).isEmpty
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Convert a mod-tap source key into UIKeyCommand input, if representable.
    /// Modifier-only source keys are handled via pressesBegan and are not emitted here.
    private func modTapSourceCommandInput(for sourceKey: ModTapSourceKey) -> String? {
        // Escape and Tab use dedicated handler paths to preserve existing behavior.
        guard sourceKey != .escape, sourceKey != .tab else { return nil }
        guard let keyCode = KeyCode(hidUsage: sourceKey.hidUsage) else { return nil }
        return keyCode.uiKeyInput
    }

    /// Generate UIKeyCommands for active mod-tap source keys.
    private func generateModTapSourceCommands() -> [UIKeyCommand] {
        let activeRules = ModTapManager.shared.activeRulesByKey.values
        guard !activeRules.isEmpty else { return [] }

        var commands: [UIKeyCommand] = []
        var seenInputs = Set<String>()

        for rule in activeRules {
            guard let input = modTapSourceCommandInput(for: rule.sourceKey) else { continue }
            guard seenInputs.insert(input).inserted else { continue }

            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(Ghostty.TerminalView.handleModTapSourceKey(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        return commands
    }

    func modTapRule(forCommandInput input: String) -> ModTapRule? {
        for rule in ModTapManager.shared.activeRulesByKey.values {
            guard let ruleInput = modTapSourceCommandInput(for: rule.sourceKey) else { continue }
            if ruleInput == input {
                return rule
            }
        }
        return nil
    }
    #endif
}

extension UIKeyCommand {
    /// Opt in to key repeat while the key is held. On iOS 26 the automatic
    /// repeat behavior resolves modifier combos like Shift+Return to
    /// non-repeatable; earlier systems always repeat, so no fallback is needed.
    func allowKeyRepeat() {
        if #available(iOS 26.0, *) {
            repeatBehavior = .repeatable
        }
    }
}
