//
//  BrowseSearchBar.swift
//  rootshell
//
//  Reusable search bar for browse sheets (profiles, SSH hosts, etc.)
//

import SwiftUI
import UIKit
import os

/// Search bar with magnifying glass, text field, clear button, and optional trailing filter button.
/// Used by ProfilesBrowseSheet and SSHHostBrowseSheet.
struct BrowseSearchBar<FilterButton: View>: View {
    @Binding var searchQuery: String
    var placeholder: String = "Search..."
    var focusedBinding: Binding<Bool>
    var focusRequestID: Int = 0
    var onEscape: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onStopMoveUp: (() -> Void)? = nil
    var onStopMoveDown: (() -> Void)? = nil
    var onSubmit: (() -> Void)?
    @ViewBuilder var filterButton: () -> FilterButton

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            FocusableSearchTextField(
                text: $searchQuery,
                placeholder: placeholder,
                isFocused: focusedBinding,
                focusRequestID: focusRequestID,
                onEscape: onEscape,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onStopMoveUp: onStopMoveUp,
                onStopMoveDown: onStopMoveDown,
                onSubmit: onSubmit
            )
            .frame(maxWidth: .infinity, minHeight: 24)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            filterButton()
        }
    }
}

extension BrowseSearchBar where FilterButton == EmptyView {
    init(
        searchQuery: Binding<String>,
        placeholder: String = "Search...",
        focusedBinding: Binding<Bool>,
        focusRequestID: Int = 0,
        onEscape: (() -> Void)? = nil,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil,
        onStopMoveUp: (() -> Void)? = nil,
        onStopMoveDown: (() -> Void)? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self._searchQuery = searchQuery
        self.placeholder = placeholder
        self.focusedBinding = focusedBinding
        self.focusRequestID = focusRequestID
        self.onEscape = onEscape
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onStopMoveUp = onStopMoveUp
        self.onStopMoveDown = onStopMoveDown
        self.onSubmit = onSubmit
        self.filterButton = { EmptyView() }
    }
}

private final class EscapeAwareTextField: UITextField {
    var onEscape: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onStopMoveUp: (() -> Void)?
    var onStopMoveDown: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        if onEscape != nil {
            commands.append(
                UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: [],
                    action: #selector(handleEscapeKey)
                )
            )
        }

        return commands.isEmpty ? nil : commands
    }

    @objc private func handleEscapeKey() {
        onEscape?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyDown($0) }
        if !unhandled.isEmpty {
            super.pressesBegan(Set(unhandled), with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyUp($0) }
        if !unhandled.isEmpty {
            super.pressesEnded(Set(unhandled), with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyUp($0) }
        if !unhandled.isEmpty {
            super.pressesCancelled(Set(unhandled), with: event)
        }
    }

    /// Only plain arrows drive list navigation; modified combinations fall
    /// through so system text/navigation shortcuts keep their normal behavior.
    private func isPlain(_ key: UIKey) -> Bool {
        key.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty
    }

    private func handleKeyDown(_ press: UIPress) -> Bool {
        guard let key = press.key, isPlain(key) else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            guard let onMoveUp else { return false }
            onMoveUp()
            return true
        case .keyboardDownArrow:
            guard let onMoveDown else { return false }
            onMoveDown()
            return true
        default:
            return false
        }
    }

    private func handleKeyUp(_ press: UIPress) -> Bool {
        guard let key = press.key, isPlain(key) else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            onStopMoveUp?()
            return onMoveUp != nil || onStopMoveUp != nil
        case .keyboardDownArrow:
            onStopMoveDown?()
            return onMoveDown != nil || onStopMoveDown != nil
        default:
            return false
        }
    }
}

private struct FocusableSearchTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    var focusRequestID: Int
    var onEscape: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onStopMoveUp: (() -> Void)?
    var onStopMoveDown: (() -> Void)?
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EscapeAwareTextField {
        let textField = EscapeAwareTextField()
        textField.delegate = context.coordinator
        textField.onEscape = onEscape
        textField.onMoveUp = onMoveUp
        textField.onMoveDown = onMoveDown
        textField.onStopMoveUp = onStopMoveUp
        textField.onStopMoveDown = onStopMoveDown
        textField.placeholder = placeholder
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.keyboardType = .default
        textField.returnKeyType = .search
        textField.clearButtonMode = .never
        textField.text = text
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.addTarget(context.coordinator, action: #selector(Coordinator.editingDidBegin), for: .editingDidBegin)
        textField.addTarget(context.coordinator, action: #selector(Coordinator.editingDidEnd), for: .editingDidEnd)
        return textField
    }

    func updateUIView(_ uiView: EscapeAwareTextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
        uiView.onEscape = onEscape
        uiView.onMoveUp = onMoveUp
        uiView.onMoveDown = onMoveDown
        uiView.onStopMoveUp = onStopMoveUp
        uiView.onStopMoveDown = onStopMoveDown
        context.coordinator.parent = self
        // First-responder changes ask SwiftUI to update its responder graph.
        // Apply them after this representable update has left that graph.
        DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
            guard let uiView, let coordinator else { return }
            coordinator.applyFocus(to: uiView)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FocusableSearchTextField
        var lastAppliedFocusRequestID: Int = -1

        init(_ parent: FocusableSearchTextField) {
            self.parent = parent
        }

        func applyFocus(to field: UITextField) {
            guard field.window != nil else { return }
            if parent.isFocused && parent.focusRequestID > 0 && lastAppliedFocusRequestID != parent.focusRequestID {
                if field.isFirstResponder || field.becomeFirstResponder() {
                    lastAppliedFocusRequestID = parent.focusRequestID
                    Ghostty.logger.info("Browse search applied focus request=\(self.lastAppliedFocusRequestID)")
                }
            } else if !parent.isFocused && field.isFirstResponder {
                field.resignFirstResponder()
            }
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        @objc func editingDidBegin() {
            parent.isFocused = true
        }

        @objc func editingDidEnd() {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit?()
            return false
        }
    }
}
