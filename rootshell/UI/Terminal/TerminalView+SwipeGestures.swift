//
//  TerminalView+SwipeGestures.swift
//  rootshell
//
//  Single source of truth for resolving and dispatching a horizontal swipe
//  on the terminal. The iOS direct-touch handlers in TerminalViewGestures.swift
//  and the Mac Catalyst trackpad pan handler in TerminalViewScroll.swift both
//  funnel through `performSwipeBinding(_:)`, so any user customization in
//  SwipeGestureManager applies identically across platforms.
//

import Foundation
import UIKit

extension Ghostty.TerminalView {
    /// Resolve the user's binding for the given direction and execute it.
    /// App-action presets post a notification (preserving the legacy tab-switch
    /// behavior); sequence presets and custom sequences write to the terminal
    /// via the shared `sendSequenceSteps` helper.
    func performSwipeBinding(_ direction: SwipeDirection, area: TerminalSwipeArea? = nil) {
        let binding = SwipeGestureManager.shared.binding(for: direction, area: area)
        switch binding {
        case .preset(let preset):
            performPreset(preset)
        case .sequence(let steps):
            guard !steps.isEmpty else { return }
            triggerHapticFeedback()
            sendSequenceSteps(steps)
        case .customKeyRef(let id):
            guard let key = KeyboardToolbarManager.shared.customKey(for: id) else { return }
            triggerHapticFeedback()
            sendSequenceSteps(key.sequence)
        }
    }

    private func performPreset(_ preset: SwipeGesturePreset) {
        if preset == .none { return }
        // App-action presets post a notification; sequence presets write to the terminal.
        if let name = preset.notificationName {
            triggerHapticFeedback()
            NotificationCenter.default.post(name: name, object: self)
            return
        }
        if let steps = preset.resolvedSequence(using: discoveredMultiplexerSwipeBindings), !steps.isEmpty {
            triggerHapticFeedback()
            sendSequenceSteps(steps)
        }
    }
}
