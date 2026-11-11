//
//  SwipeGestureBinding.swift
//  rootshell
//
//  Models the user-customizable binding attached to a horizontal terminal swipe.
//  A binding is either a built-in preset (next/previous tab, tmux window switching),
//  an inline sequence built from the same SequenceStep model the keyboard toolbar
//  uses for custom keys, or a reference to an existing toolbar custom key.
//

import Foundation

enum SwipeDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
}

enum SwipeGestureBinding: Codable, Hashable, Sendable {
    case preset(SwipeGesturePreset)
    case sequence([SequenceStep])
    case customKeyRef(UUID)

    /// Short label shown in the settings row.
    @MainActor
    var displaySummary: String {
        switch self {
        case .preset(let preset):
            return preset.displayName
        case .sequence(let steps):
            if steps.isEmpty {
                return String(localized: "Empty Sequence", comment: "Swipe gesture binding: empty custom sequence")
            }
            return steps.map(\.displayText).joined(separator: " \u{2192} ")
        case .customKeyRef(let id):
            if let key = KeyboardToolbarManager.shared.customKey(for: id) {
                return key.label
            }
            return String(localized: "Missing Custom Key", comment: "Swipe gesture binding: referenced custom key was deleted")
        }
    }

    /// True when this binding will not perform any action when triggered.
    /// Treats a `customKeyRef` whose target has been deleted as disabled, so
    /// the recognizer can be turned off and the gesture isn't silently consumed.
    @MainActor
    var isDisabled: Bool {
        switch self {
        case .preset(.none):
            return true
        case .sequence(let steps):
            return steps.isEmpty
        case .customKeyRef(let id):
            return KeyboardToolbarManager.shared.customKey(for: id) == nil
        case .preset:
            return false
        }
    }

    /// The app-level tab navigation preset, when this binding switches
    /// rootshell tabs instead of sending bytes to the terminal.
    var appTabPreset: SwipeGesturePreset? {
        guard case .preset(let preset) = self, preset.isAppTabNavigation else {
            return nil
        }
        return preset
    }

    var isAppTabNavigation: Bool {
        appTabPreset != nil
    }

    var isPaneCycle: Bool {
        guard case .preset(let preset) = self else { return false }
        return preset.isPaneCycle
    }

    /// Pane presets drive the tab slide on single-pane tabs.
    var drivesAppTabSwipe: Bool {
        isAppTabNavigation || isPaneCycle
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case preset, sequence, customKeyRef
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let preset):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(preset, forKey: .value)
        case .sequence(let steps):
            try container.encode(Kind.sequence, forKey: .kind)
            try container.encode(steps, forKey: .value)
        case .customKeyRef(let id):
            try container.encode(Kind.customKeyRef, forKey: .kind)
            try container.encode(id, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .preset:
            // An unknown preset from a newer build must not fail the whole decode.
            let raw = try container.decode(String.self, forKey: .value)
            self = .preset(SwipeGesturePreset(rawValue: raw) ?? .none)
        case .sequence:
            self = .sequence(try container.decode([SequenceStep].self, forKey: .value))
        case .customKeyRef:
            self = .customKeyRef(try container.decode(UUID.self, forKey: .value))
        }
    }
}

/// Built-in swipe presets. App-action presets (next/previous tab) post a
/// notification; multiplexer presets expand into a [SequenceStep] for the
/// shared sender to write to the terminal.
enum SwipeGesturePreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case nextTab
    case previousTab
    case nextPane
    case previousPane
    case tmuxNextWindow
    case tmuxPreviousWindow
    case tmuxNextSession
    case tmuxPreviousSession
    case zellijNextTab
    case zellijPreviousTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return String(localized: "Disabled", comment: "Swipe preset: do nothing")
        case .nextTab:
            return String(localized: "Next Tab", comment: "Swipe preset: switch to next app tab")
        case .previousTab:
            return String(localized: "Previous Tab", comment: "Swipe preset: switch to previous app tab")
        case .nextPane:
            return String(localized: "Next Pane", comment: "Swipe preset: zoom the next split pane, then return to all panes")
        case .previousPane:
            return String(localized: "Previous Pane", comment: "Swipe preset: zoom the previous split pane, then return to all panes")
        case .tmuxNextWindow:
            return String(localized: "Tmux: Next Window", comment: "Swipe preset: send tmux next-window prefix sequence")
        case .tmuxPreviousWindow:
            return String(localized: "Tmux: Previous Window", comment: "Swipe preset: send tmux previous-window prefix sequence")
        case .tmuxNextSession:
            return String(localized: "Tmux: Next Session", comment: "Swipe preset: send tmux switch-client next sequence")
        case .tmuxPreviousSession:
            return String(localized: "Tmux: Previous Session", comment: "Swipe preset: send tmux switch-client previous sequence")
        case .zellijNextTab:
            return String(localized: "Zellij: Next Tab", comment: "Swipe preset: enter zellij tab mode and move to next tab")
        case .zellijPreviousTab:
            return String(localized: "Zellij: Previous Tab", comment: "Swipe preset: enter zellij tab mode and move to previous tab")
        }
    }

    var isAppTabNavigation: Bool {
        self == .nextTab || self == .previousTab
    }

    var isPaneCycle: Bool {
        self == .nextPane || self == .previousPane
    }

    /// The tab preset a pane preset becomes on a tab with one pane.
    var tabFallback: SwipeGesturePreset? {
        switch self {
        case .nextPane: return .nextTab
        case .previousPane: return .previousTab
        default: return nil
        }
    }

    /// For app-action presets, the notification name to post. Nil for terminal sequences.
    var notificationName: Notification.Name? {
        switch self {
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        case .nextPane: return .nextPaneZoom
        case .previousPane: return .previousPaneZoom
        default: return nil
        }
    }

    /// For sequence presets, the built-in fallback steps to send to the terminal.
    /// Terminal-specific discovery may override these at send time.
    var fallbackSequence: [SequenceStep]? {
        switch self {
        case .tmuxNextWindow:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("n"),
            ]
        case .tmuxPreviousWindow:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("p"),
            ]
        case .tmuxNextSession:
            // Ctrl+B then ')' switches to the next attached session via switch-client
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text(")"),
            ]
        case .tmuxPreviousSession:
            // Ctrl+B then '(' switches to the previous session
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("("),
            ]
        case .zellijNextTab:
            // Enter Tab mode (Ctrl+T), move right, then Esc to return to Normal mode
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("t"))),
                .text("l"),
                .keyCombo(SequenceStep.KeyCombo(modifiers: [], key: .special(.escape))),
            ]
        case .zellijPreviousTab:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("t"))),
                .text("h"),
                .keyCombo(SequenceStep.KeyCombo(modifiers: [], key: .special(.escape))),
            ]
        default:
            return nil
        }
    }

    func resolvedSequence(using bindings: MultiplexerSwipeBindings?) -> [SequenceStep]? {
        bindings?.sequence(for: self) ?? fallbackSequence
    }
}
