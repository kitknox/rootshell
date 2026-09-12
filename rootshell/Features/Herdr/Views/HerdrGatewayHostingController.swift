// Copyright (c) 2026 Kit Knox / Rootshell LLC
import SwiftUI
import UIKit

/// Owns app shortcuts without making the covered gateway shell a text-input
/// responder. Pointer events still go directly to the hosted SwiftUI controls.
@MainActor
final class HerdrGatewayHostingController: UIHostingController<HerdrGatewayView> {
    private weak var gateway: Ghostty.TerminalView?
    private let sequences = KeySequenceTracker()
    var presentsInstallInstructions = false
    private var lastDelivery: (trigger: KeyTrigger, time: TimeInterval)?

    init(gateway: Ghostty.TerminalView, rootView: HerdrGatewayView) {
        self.gateway = gateway
        super.init(rootView: rootView)
        sequences.onTimeoutDirectAction = { [weak self] binding in self?.execute(binding) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var canHandleShortcuts: Bool {
        gateway?.herdrGatewayCanOwnKeyboard == true && !presentsInstallInstructions
            && presentedViewController == nil
    }

    override var canBecomeFirstResponder: Bool { canHandleShortcuts }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reconcileFocus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        relinquishFocus()
        super.viewWillDisappear(animated)
    }

    /// Called by the terminal's existing pane/window/modal focus lifecycle.
    @discardableResult
    func reconcileFocus() -> Bool {
        guard canHandleShortcuts, isViewLoaded, view.window != nil else {
            relinquishFocus()
            return false
        }
        // Preserve selectable gateway text and SwiftUI keyboard focus. Polling
        // updates must not repeatedly take first responder from a control.
        if isFirstResponder || containsFirstResponder(view) { return true }
        return becomeFirstResponder()
    }

    func relinquishFocus() {
        sequences.reset()
        lastDelivery = nil
        if isFirstResponder { _ = resignFirstResponder() }
    }

    override func resignFirstResponder() -> Bool {
        sequences.reset()
        lastDelivery = nil
        return super.resignFirstResponder()
    }

    private func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard canHandleShortcuts else { return nil }
        var commands: [UIKeyCommand] = []
        var seen = Set<KeyTrigger>()
        for binding in KeybindManager.shared.activeBindings where Self.supports(binding.action) {
            var triggers = Array(binding.sequence.triggers.prefix(1))
            if sequences.isAwaitingSecondKey,
               binding.sequence.first == sequences.pendingTrigger {
                triggers += binding.sequence.triggers.dropFirst()
            }
            for trigger in triggers where seen.insert(trigger).inserted {
                let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                           action: #selector(handleShortcut(_:)))
                command.wantsPriorityOverSystemBehavior = true
                #if !os(visionOS)
                command.discoverabilityTitle = binding.action.displayName
                #endif
                commands.append(command)
            }
        }
        if seen.insert(Self.detachTrigger).inserted {
            let detach = UIKeyCommand(input: Self.detachTrigger.uiKeyInput, modifierFlags: [],
                                      action: #selector(handleShortcut(_:)))
            detach.wantsPriorityOverSystemBehavior = true
            #if !os(visionOS)
            detach.discoverabilityTitle = String(localized: "Detach from herdr")
            #endif
            commands.append(detach)
        }
        return commands
    }

    @objc private func handleShortcut(_ command: UIKeyCommand) {
        guard let trigger = KeyTrigger(uiKeyCommand: command) else { return }
        _ = dispatch(trigger)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            if let trigger = KeyTrigger(press: press), dispatch(trigger) {
                remaining.remove(press)
            }
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    private func dispatch(_ trigger: KeyTrigger) -> Bool {
        guard canHandleShortcuts else { return false }
        // UIKit can deliver the same chord via UIKeyCommand and pressesBegan.
        let now = ProcessInfo.processInfo.systemUptime
        if let lastDelivery, lastDelivery.trigger == trigger, now - lastDelivery.time < 0.05 { return true }
        let result = sequences.consume(owner: self, trigger: trigger)
        let binding = result.keybind ?? (result.handled ? nil : KeybindManager.shared.keybind(for: trigger))
        let supported = binding.map { Self.supports($0.action) } == true
        let detaches = !result.handled && !supported && trigger == Self.detachTrigger
        guard result.handled || supported || detaches else { return false }
        lastDelivery = (trigger, now)
        noteAlwaysOnDisplayInteraction()
        if detaches {
            rootView.detach()
        } else if let binding {
            execute(binding)
        }
        return true
    }

    /// ESC leaves control mode the way the tmux gateway's ESC does. A keybind
    /// that claims bare Escape still wins.
    private static let detachTrigger = KeyTrigger(key: .escape, modifiers: [])

    private static func supports(_ action: KeybindAction) -> Bool {
        !action.isTerminalAction && action.isAvailableForVisorDispatch && action != .unbind
    }

    private func execute(_ binding: Keybind) {
        guard canHandleShortcuts, Self.supports(binding.action) else { return }
        gateway?.executeKeybindAction(binding.action, parameter: binding.actionParameter)
    }
}
