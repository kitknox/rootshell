//
//  EmptyStateResponder.swift
//  rootshell
//
//  A view displayed when all tabs are closed that can become first responder
//  to handle keyboard shortcuts for creating new tabs.
//

import SwiftUI
import UIKit

/// SwiftUI wrapper for the empty state responder view
struct EmptyStateResponder: UIViewRepresentable {
    let onNewTab: () -> Void
    let onNewLocalShell: () -> Void

    func makeUIView(context: Context) -> EmptyStateView {
        let view = EmptyStateView()
        view.onNewTab = onNewTab
        view.onNewLocalShell = onNewLocalShell
        return view
    }

    func updateUIView(_ uiView: EmptyStateView, context: Context) {
        uiView.onNewTab = onNewTab
        uiView.onNewLocalShell = onNewLocalShell
    }
}

/// UIView that can become first responder and handle keyboard shortcuts
/// when there are no terminal tabs open
final class EmptyStateView: UIView {
    var onNewTab: (() -> Void)?
    var onNewLocalShell: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // Automatically become first responder when added to window; skipped
        // while backgrounded, where the claim is pointless work. NOT a
        // secure-draw guard: this view has no inputView and cannot present a
        // keyboard, so it has no path into the lock snapshot. The latch is also
        // armed at launch and would block cold-start focus with no retry.
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState != .background else { return }
            self?.becomeFirstResponder()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, UIApplication.shared.applicationState != .background {
            becomeFirstResponder()
        }
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        // Built from the user's live bindings so remaps are honored (defaults:
        // Cmd+T New Tab, Cmd+S Open Connections, Cmd+N New Window).
        let manager = KeybindManager.shared
        return [
            manager.keyCommand(for: .new_local_shell, selector: #selector(handleNewLocalShell),
                               title: "New Tab", wantsPriority: true),
            manager.keyCommand(for: .new_tab, selector: #selector(handleNewTab), title: "Open Connections"),
            manager.keyCommand(for: .new_window, selector: #selector(handleNewWindow), title: "New Window"),
        ].compactMap { $0 }
    }

    @objc private func handleNewLocalShell() {
        onNewLocalShell?()
    }

    @objc private func handleNewTab() {
        onNewTab?()
    }

    @objc private func handleNewWindow() {
        NotificationCenter.default.post(name: .newWindow, object: nil)
    }

    // MARK: - Menu Action Forwarding

    // Forward menu actions to the notification system so they work from menu bar
    @objc func menuCreateLocalShell(_ sender: Any?) {
        onNewLocalShell?()
    }

    @objc func menuNewTab(_ sender: Any?) {
        onNewTab?()
    }

    @objc func menuNewWindow(_ sender: Any?) {
        NotificationCenter.default.post(name: .newWindow, object: nil)
    }
}
