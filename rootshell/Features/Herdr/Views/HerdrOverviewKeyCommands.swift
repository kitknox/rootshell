// Copyright (c) 2026 Kit Knox / Rootshell LLC
import SwiftUI
import UIKit

/// Same responder ownership as the tmux dashboard. Search fields and action
/// sheets disable this host before it can request the keyboard.
struct HerdrOverviewKeyCommands: UIViewControllerRepresentable {
    let isActive: Bool
    let move: (Int) -> Void
    let select: () -> Void
    let expand: () -> Void
    let close: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.owner = self
        controller.updateFocus()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.owner = nil
        controller.resignFirstResponder()
    }

    final class Controller: UIViewController {
        var owner: HerdrOverviewKeyCommands?
        override var canBecomeFirstResponder: Bool { owner?.isActive == true }
        override func loadView() { view = UIView(frame: .zero) }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateFocus()
        }
        func updateFocus() {
            guard owner?.isActive == true else { resignFirstResponder(); return }
            guard isViewLoaded, view.window?.isKeyWindow == true, !isFirstResponder else { return }
            becomeFirstResponder()
        }
        override var keyCommands: [UIKeyCommand]? {
            guard owner?.isActive == true else { return nil }
            return [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(selectItem)),
                UIKeyCommand(input: " ", modifierFlags: [], action: #selector(expandItem)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeView))
            ]
        }
        @objc private func up() { owner?.move(-1) }
        @objc private func down() { owner?.move(1) }
        @objc private func selectItem() { owner?.select() }
        @objc private func expandItem() { owner?.expand() }
        @objc private func closeView() { owner?.close() }
    }
}
