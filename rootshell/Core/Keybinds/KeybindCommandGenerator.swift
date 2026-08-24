//
//  KeybindCommandGenerator.swift
//  rootshell
//
//  Generates UIKeyCommands from KeybindManager bindings
//

import UIKit
import Combine
import os

/// Generates UIKeyCommands from the active keybindings
@MainActor
final class KeybindCommandGenerator: ObservableObject {
    private static let logger = Logger(subsystem: "com.rootshell", category: "KeybindCommandGenerator")

    private let keybindManager: KeybindManager
    private var cancellables = Set<AnyCancellable>()

    /// Generated UIKeyCommands (cached, regenerated on keybind changes)
    @Published private(set) var keyCommands: [UIKeyCommand] = []

    /// Cached filtered commands for iOS 26+ (regenerated on keybind changes)
    private var _commandsForIOS26Plus: [UIKeyCommand]?

    /// Publisher for command updates
    let commandsDidUpdate = PassthroughSubject<[UIKeyCommand], Never>()

    // MARK: - Initialization

    init(keybindManager: KeybindManager) {
        self.keybindManager = keybindManager

        // Listen for keybind changes
        keybindManager.keybindsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.regenerateCommands()
            }
            .store(in: &cancellables)

        // Initial generation
        regenerateCommands()
    }

    convenience init() {
        self.init(keybindManager: KeybindManager.shared)
    }

    // MARK: - Command Generation

    /// Regenerate all UIKeyCommands from current bindings
    private func regenerateCommands() {
        // Clear filtered cache - will be rebuilt on next access
        _commandsForIOS26Plus = nil

        var commands: [UIKeyCommand] = []
        // Dedupe by first trigger. If the same first key is both a single-key
        // binding and a sequence prefix (e.g., Ctrl+A bound directly AND as the
        // prefix of Ctrl+A→N), iOS only dispatches one UIKeyCommand for a given
        // (input, modifierFlags) pair anyway. Emit one; `handleKeybindCommand`
        // routes it through `KeySequenceTracker`, which picks the right action.
        //
        // Pick the binding that most needs priority as the representative so the
        // UIKeyCommand's `wantsPriorityOverSystemBehavior` isn't accidentally
        // dropped by the alphabetical ordering of `activeBindings`.
        var chosenByFirstTrigger: [KeyTrigger: Keybind] = [:]

        for binding in keybindManager.activeBindings {
            // Skip control character actions - these are handled specially in pressesBegan
            guard !binding.action.isControlCharacter else { continue }

            // Skip terminal-only actions that don't need UIKeyCommands
            // (handled directly via ghostty_surface_binding_action)
            guard shouldGenerateCommand(for: binding) else { continue }

            // Only generate commands for the first trigger of sequences
            // Sequences are handled by KeySequenceTracker
            guard let firstTrigger = binding.sequence.first else { continue }

            if let existing = chosenByFirstTrigger[firstTrigger] {
                if priorityScore(of: binding) > priorityScore(of: existing) {
                    chosenByFirstTrigger[firstTrigger] = binding
                }
            } else {
                chosenByFirstTrigger[firstTrigger] = binding
            }
        }

        for (firstTrigger, binding) in chosenByFirstTrigger {
            let command = createKeyCommand(
                trigger: firstTrigger,
                binding: binding,
                isSequencePrefix: binding.sequence.isSequence
            )
            commands.append(command)
        }

        // Add special key commands that are always present
        commands.append(contentsOf: generateSpecialKeyCommands())

        keyCommands = commands
        commandsDidUpdate.send(commands)

        Self.logger.info("Generated \(commands.count) UIKeyCommands")
    }

    /// Determine if a binding should have a UIKeyCommand generated
    private func shouldGenerateCommand(for binding: Keybind) -> Bool {
        switch binding.action {
        // App actions need UIKeyCommands to trigger
        case .new_local_shell, .new_tab, .new_window, .close_tab, .duplicate_ssh_tab,
             .previous_tab, .next_tab, .select_tab_1, .select_tab_2, .select_tab_3,
             .select_tab_4, .select_tab_5, .select_tab_6, .select_tab_7, .select_tab_8,
             .select_tab_9, .split_right, .split_down, .navigate_split_left,
             .navigate_split_right, .navigate_split_up, .navigate_split_down,
             .toggle_split_zoom, .equalize_splits, .open_settings, .browse_hosts,
             .browse_profiles, .toggle_ai_agent, .toggle_voice_agent, .toggle_tab_bar, .toggle_group_mode, .toggle_tab_switcher,
             .toggle_tab_expose, .previous_group, .next_group, .show_tmux_sessions, .detach_other_clients,
             .toggle_transparency, .toggle_titlebar, .toggle_auto_redact, .toggle_background_effect, .toggle_compose,
             .toggle_full_screen, .toggle_mouse_capture, .cycle_input_source,
             .increase_font_size, .decrease_font_size,
             .reset_font_size, .start_search, .select_all, .toggle_theme_picker,
             .toggle_clipboard_manager, .brightness_boost,
             .focus_external_display, .move_tab_to_external_display:
            return true

        // Terminal actions are handled via ghostty_surface_binding_action
        // but some still need UIKeyCommands for menu display
        case .copy_to_clipboard, .paste_from_clipboard, .scroll_page_up, .scroll_page_down,
             .scroll_to_top, .scroll_to_bottom, .clear_screen, .reset_terminal:
            return true

        // Send data actions need UIKeyCommands to intercept before system
        case .send_text, .send_esc, .send_csi:
            return true

        // Control characters don't need UIKeyCommands
        case .ctrl_a, .ctrl_b, .ctrl_c, .ctrl_d, .ctrl_e, .ctrl_f, .ctrl_g,
             .ctrl_h, .ctrl_i, .ctrl_j, .ctrl_k, .ctrl_l, .ctrl_m, .ctrl_n,
             .ctrl_o, .ctrl_p, .ctrl_q, .ctrl_r, .ctrl_s, .ctrl_t, .ctrl_u,
             .ctrl_v, .ctrl_w, .ctrl_x, .ctrl_y, .ctrl_z:
            return false

        case .unbind:
            return false
        }
    }

    /// True when a direct keybind already exists for this trigger OR the
    /// trigger is the first key of a sequence. In either case the
    /// per-special-key fallback UIKeyCommand must NOT be emitted — the
    /// `handleKeybindCommand` command generated by `regenerateCommands` will
    /// route this trigger through `KeySequenceTracker` instead, and emitting
    /// the special-key selector would shadow that routing.
    private func isClaimedByKeybind(_ trigger: KeyTrigger) -> Bool {
        keybindManager.keybind(for: trigger) != nil
            || keybindManager.isSequencePrefix(trigger)
    }

    /// Ranking used when deduplicating bindings that share a first trigger.
    /// Higher score wins — so the representative UIKeyCommand inherits
    /// discoverabilityTitle and `wantsPriorityOverSystemBehavior` from the
    /// binding that most needs to override SwiftUI Commands / system shortcuts.
    private func priorityScore(of binding: Keybind) -> Int {
        var score = 0
        if binding.isUserOverride { score += 4 }
        if binding.source == .externalConfig { score += 2 }
        if binding.action.needsSystemPriority { score += 1 }
        return score
    }

    /// Create a UIKeyCommand for a binding
    private func createKeyCommand(
        trigger: KeyTrigger,
        binding: Keybind,
        isSequencePrefix: Bool
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: trigger.uiKeyInput,
            modifierFlags: trigger.uiModifierFlags,
            action: #selector(Ghostty.TerminalView.handleKeybindCommand(_:))
        )

        // Set discoverability title for iPad keyboard shortcuts overlay
        #if !os(visionOS)
        command.discoverabilityTitle = binding.action.displayName
        #endif

        // User overrides and external config bindings need priority to override
        // SwiftUI Commands. Some shortcuts also need priority over system behavior.
        if binding.isUserOverride || binding.source == .externalConfig
            || binding.action.needsSystemPriority {
            command.wantsPriorityOverSystemBehavior = true
        }

        return command
    }

    /// Generate special key commands that are always needed
    private func generateSpecialKeyCommands() -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []

        // Map UIKeyCommand arrow input strings back to KeyCode so we can ask
        // KeybindManager whether a binding has claimed the combo. Skipping
        // claimed combos prevents the default handleArrowKey command from
        // shadowing a handleKeybindCommand emitted by regenerateCommands for
        // the same (input, modifiers) pair.
        let arrowKeyCodes: [(String, KeyCode)] = [
            (UIKeyCommand.inputUpArrow, .up),
            (UIKeyCommand.inputDownArrow, .down),
            (UIKeyCommand.inputLeftArrow, .left),
            (UIKeyCommand.inputRightArrow, .right),
        ]
        let arrowModifierVariants: [UIKeyModifierFlags] = [
            [], .alternate, .shift, [.alternate, .shift],
        ]

        for (arrowInput, arrowKeyCode) in arrowKeyCodes {
            for modFlags in arrowModifierVariants {
                let trigger = KeyTrigger(
                    key: arrowKeyCode,
                    modifiers: KeybindModifiers(uiModifierFlags: modFlags)
                )
                if isClaimedByKeybind(trigger) {
                    continue
                }
                let cmd = UIKeyCommand(
                    input: arrowInput,
                    modifierFlags: modFlags,
                    action: #selector(Ghostty.TerminalView.handleArrowKey(_:))
                )
                cmd.wantsPriorityOverSystemBehavior = true
                cmd.allowKeyRepeat()
                commands.append(cmd)
            }
            // Note: Control+Arrow is handled by GCKeyboard in KeyboardTracker
            // to bypass system interception on Mac Catalyst.
        }

        // Return/Enter key — skip each combo if a keybind or sequence prefix
        // claimed it, so handleReturnKey doesn't shadow the tracker-routed
        // handleKeybindCommand for bindings like Return→X.
        let plainReturnTrigger = KeyTrigger(key: .enter, modifiers: [])
        if !isClaimedByKeybind(plainReturnTrigger) {
            let returnCommand = UIKeyCommand(
                input: "\r",
                modifierFlags: [],
                action: #selector(Ghostty.TerminalView.handleReturnKey(_:))
            )
            returnCommand.allowKeyRepeat()
            commands.append(returnCommand)
        }
        let modifiedReturnFlags: [UIKeyModifierFlags] = [
            .alternate,
            .shift,
            .control,
            [.alternate, .shift],
            [.control, .shift],
            [.control, .alternate],
            [.control, .alternate, .shift],
        ]
        for flags in modifiedReturnFlags {
            let trigger = KeyTrigger(
                key: .enter,
                modifiers: KeybindModifiers(uiModifierFlags: flags)
            )
            if isClaimedByKeybind(trigger) { continue }
            let command = UIKeyCommand(
                input: "\r",
                modifierFlags: flags,
                action: #selector(Ghostty.TerminalView.handleModifiedReturnKey(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            // .automatic resolves to non-repeatable for modifier combos like
            // Shift+Return, so holding the key would deliver a single press.
            command.allowKeyRepeat()
            commands.append(command)
        }

        // Escape key
        // On Mac Catalyst, ESC needs UIKeyCommand for wantsPriorityOverSystemBehavior
        // and mod-tap source key support. On iOS/visionOS, ESC is handled via
        // pressesBegan → processKeyPress, which correctly intercepts ESC when
        // overlays (session picker, AI agent) are visible. Registering a UIKeyCommand
        // for ESC on iPad prevents pressesBegan from firing, bypassing overlay checks.
        #if targetEnvironment(macCatalyst)
        let plainEscapeTrigger = KeyTrigger(key: .escape, modifiers: [])
        if !isClaimedByKeybind(plainEscapeTrigger) {
            let escapeCommand = UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(Ghostty.TerminalView.handleEscapeKey(_:))
            )
            // Prevent system Cancel behavior from stealing focus on Mac Catalyst.
            escapeCommand.wantsPriorityOverSystemBehavior = true
            escapeCommand.allowKeyRepeat()
            commands.append(escapeCommand)
        }
        let optionEscapeTrigger = KeyTrigger(
            key: .escape,
            modifiers: KeybindModifiers(uiModifierFlags: .alternate)
        )
        if !isClaimedByKeybind(optionEscapeTrigger) {
            let optionEscapeCommand = UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: .alternate,
                action: #selector(Ghostty.TerminalView.handleEscapeKey(_:))
            )
            optionEscapeCommand.wantsPriorityOverSystemBehavior = true
            optionEscapeCommand.allowKeyRepeat()
            commands.append(optionEscapeCommand)
        }
        #endif

        // System Cancel chord (Cmd+Period). Apple reserves it as an Escape
        // equivalent, so it defaults to a one-shot ESC. When a keybind claims
        // cmd+period, the generic handleKeybindCommand command is emitted
        // instead (same pattern as arrows/Tab/F-keys). No allowKeyRepeat():
        // the chord is deliberately one-shot, matching system Cancel semantics.
        #if !os(visionOS)
        if !isClaimedByKeybind(.commandPeriod) {
            let cancelCommand = UIKeyCommand(
                input: ".",
                modifierFlags: .command,
                action: #selector(Ghostty.TerminalView.handleSystemCancelCommand(_:))
            )
            cancelCommand.wantsPriorityOverSystemBehavior = true
            commands.append(cancelCommand)
        }
        #endif

        // Tab key — each combo skipped if claimed by a binding or sequence prefix.
        let tabVariants: [(UIKeyModifierFlags, Selector)] = [
            ([], #selector(Ghostty.TerminalView.handleTabKey(_:))),
            (.shift, #selector(Ghostty.TerminalView.handleShiftTabKey(_:))),
            (.alternate, #selector(Ghostty.TerminalView.handleTabKey(_:))),
        ]
        for (flags, selector) in tabVariants {
            let trigger = KeyTrigger(
                key: .tab,
                modifiers: KeybindModifiers(uiModifierFlags: flags)
            )
            if isClaimedByKeybind(trigger) { continue }
            let cmd = UIKeyCommand(
                input: "\t",
                modifierFlags: flags,
                action: selector
            )
            cmd.wantsPriorityOverSystemBehavior = true
            cmd.allowKeyRepeat()
            commands.append(cmd)
        }

        // Function keys F1-F12 (plain, Option, and Shift variants)
        // On Mac Catalyst, macOS intercepts these for system features (e.g., Mission Control,
        // brightness, volume). wantsPriorityOverSystemBehavior claims them for the terminal.
        // Skip combos that already have a keybind — those get their own UIKeyCommand
        // with handleKeybindCommand as the action selector.
        let functionKeyPairs: [(String, KeyCode)] = [
            (UIKeyCommand.f1, .f1), (UIKeyCommand.f2, .f2), (UIKeyCommand.f3, .f3),
            (UIKeyCommand.f4, .f4), (UIKeyCommand.f5, .f5), (UIKeyCommand.f6, .f6),
            (UIKeyCommand.f7, .f7), (UIKeyCommand.f8, .f8), (UIKeyCommand.f9, .f9),
            (UIKeyCommand.f10, .f10), (UIKeyCommand.f11, .f11), (UIKeyCommand.f12, .f12),
        ]

        for (fKeyInput, keyCode) in functionKeyPairs {
            for modFlags: UIKeyModifierFlags in [[], .alternate, .shift] {
                let trigger = KeyTrigger(
                    key: keyCode,
                    modifiers: KeybindModifiers(uiModifierFlags: modFlags)
                )
                if isClaimedByKeybind(trigger) {
                    continue
                }
                let cmd = UIKeyCommand(
                    input: fKeyInput,
                    modifierFlags: modFlags,
                    action: #selector(Ghostty.TerminalView.handleFunctionKey(_:))
                )
                cmd.wantsPriorityOverSystemBehavior = true
                cmd.allowKeyRepeat()
                commands.append(cmd)
            }
        }

        return commands
    }

    // MARK: - Filtered Commands

    /// Commands suitable for iOS 26+ where SwiftUI Commands handle menu shortcuts
    /// Returns only special key commands and actions not handled by SwiftUI Commands,
    /// UNLESS the shortcut has been customized (then we need UIKeyCommand to take priority)
    /// Cached to avoid re-filtering on every keystroke.
    var commandsForIOS26Plus: [UIKeyCommand] {
        if let cached = _commandsForIOS26Plus {
            return cached
        }

        let filtered = keyCommands.filter { command in
            // Special key commands (arrows, tab, return, escape) are needed for terminal input
            // BUT only when they don't have Command modifier - Command+key combos are menu shortcuts
            let specialKeyInputs: Set<String> = [
                UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                UIKeyCommand.inputEscape, "\r", "\t",
                UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4,
                UIKeyCommand.f5, UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8,
                UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12,
            ]
            let isSpecialKeyInput = specialKeyInputs.contains(command.input ?? "")
            let hasCommandModifier = command.modifierFlags.contains(.command)

            // Include special keys only if they don't have Command modifier
            // (plain arrows, Option+arrows for terminal, but NOT Cmd+Option+Arrow for split nav)
            if isSpecialKeyInput && !hasCommandModifier {
                return true
            }

            // Find bindings matching this command's first trigger. Multiple
            // bindings can share a first trigger when a direct shortcut and a
            // sequence prefix coexist (e.g., Cmd+K single + Cmd+K→E sequence).
            // Evaluate them together so a customized sequence prefix doesn't
            // get filtered out just because a default direct binding sorts
            // first alphabetically in `activeBindings`.
            guard let trigger = KeyTrigger(uiKeyCommand: command) else {
                return true
            }
            let matching = keybindManager.activeBindings.filter { $0.sequence.first == trigger }
            guard !matching.isEmpty else {
                return true
            }

            // On iOS 26+, SwiftUI Commands handle menu shortcuts
            // Only include UIKeyCommands if:
            // 1. Any matching binding is a user override / external config
            //    (customized shortcut needs UIKeyCommand to take priority)
            // 2. Any matching binding is NOT handled by SwiftUI Commands
            //    (e.g., scroll actions)
            // Note: Don't include based on needsSystemPriority alone - that would conflict
            // with SwiftUI Commands and prevent shortcut glyphs from displaying
            if matching.contains(where: { $0.isUserOverride || $0.source == .externalConfig }) {
                return true
            }

            return matching.contains { !$0.action.isHandledBySwiftUICommands }
        }

        _commandsForIOS26Plus = filtered
        return filtered
    }

    /// Commands for iOS < 26 (all commands including menu shortcuts)
    var commandsForLegacyIOS: [UIKeyCommand] {
        keyCommands
    }

    // MARK: - Menu Shortcut Lookup

    /// Get the keyboard shortcut string for an action (for menu display)
    func shortcutString(for action: KeybindAction) -> String? {
        guard let sequence = keybindManager.sequence(for: action) else {
            return nil
        }
        return sequence.symbolDescription
    }

    /// Get the UIKeyboardShortcut for an action (for SwiftUI Commands)
    func keyboardShortcut(for action: KeybindAction) -> (String, UIKeyModifierFlags)? {
        guard let sequence = keybindManager.sequence(for: action),
              let firstTrigger = sequence.first else {
            return nil
        }

        // Only return for single-key shortcuts (sequences don't work in menus)
        guard !sequence.isSequence else { return nil }

        return (firstTrigger.uiKeyInput, firstTrigger.uiModifierFlags)
    }
}

// MARK: - Shared Instance

extension KeybindCommandGenerator {
    /// Shared command generator instance
    static let shared = KeybindCommandGenerator()
}
