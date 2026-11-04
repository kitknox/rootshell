//
//  TerminalComposeOverlay.swift
//  rootshell
//
//  Floating compose overlay for composing text before sending to terminal
//

import SwiftUI
import UIKit

struct TerminalComposeOverlay: View {
    let initialText: String
    let onSend: (String) -> Void
    let onClose: () -> Void
    /// Called whenever the text changes, so the terminal always has the latest for toolbar toggle-off
    let onTextChanged: (String) -> Void
    /// The keyboard accessory from the terminal, shared so the toolbar persists during focus transfer
    let keyboardAccessory: UIView?
    /// Called when the backing UITextView is created/destroyed, so toolbar keys can be routed to it
    let onTextViewCreated: ((UITextView?) -> Void)?

    @State private var text: String = ""
    @Setting(Settings.Keyboard.composeAutocorrect) private var autocorrectEnabled

    #if !os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var usesCompactLayout: Bool {
        #if os(visionOS)
        return false
        #else
        return horizontalSizeClass != .regular
        #endif
    }

    private var isCompactHeight: Bool {
        #if os(visionOS)
        return false
        #else
        return verticalSizeClass == .compact
        #endif
    }

    // Dismiss shortcut read live from KeybindManager (default Cmd-Shift-K) so a
    // remapped toggle_compose is honored instead of a hardcoded chord.
    private var composeToggleKeys: Set<KeyEquivalent> {
        guard let key = KeybindManager.shared.keybind(for: .toggle_compose)?.sequence.first?.swiftUIKeyEquivalent
        else { return [] }
        return [key]
    }
    private var composeToggleModifiers: EventModifiers {
        KeybindManager.shared.keybind(for: .toggle_compose)?.sequence.first?.swiftUIEventModifiers ?? [.command, .shift]
    }

    private var overlayWidth: CGFloat {
        if isCompactHeight { return 500 }
        return usesCompactLayout ? 320 : 400
    }

    /// Available height above the software keyboard within the given container geometry.
    private func availableHeight(in geometry: GeometryProxy) -> CGFloat {
        #if os(visionOS)
        return geometry.size.height
        #else
        let containerFrame = geometry.frame(in: .global)
        guard KeyboardTracker.shared.isSoftwareKeyboardVisible else {
            return containerFrame.height
        }
        let kbOriginY = KeyboardTracker.shared.keyboardFrame.origin.y
        // Available = from container top to keyboard top (or container bottom if keyboard is below)
        let visibleBottom = min(containerFrame.maxY, kbOriginY)
        return max(0, visibleBottom - containerFrame.minY)
        #endif
    }

    /// Maximum card height, constrained to fit above the keyboard.
    private func cardMaxHeight(in geometry: GeometryProxy) -> CGFloat {
        let available = availableHeight(in: geometry)
        let topPad: CGFloat = isCompactHeight ? 8 : 20
        if isCompactHeight {
            // HStack layout: only card padding overhead, no button row below
            return max(80, available - topPad - 8)
        }
        // VStack layout: ~28pt overhead (padding + spacing + button row)
        let fromAvailable = available - topPad - 28
        return min(300, max(100, fromAvailable))
    }

    // MARK: - Text Editor Area

    @ViewBuilder
    private var textEditorArea: some View {
        ComposeTextView(
            text: $text,
            autocorrectEnabled: autocorrectEnabled,
            keyboardAccessory: keyboardAccessory,
            onTextViewCreated: onTextViewCreated
        )
        .padding(4)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let available = availableHeight(in: geometry)
            let maxHeight = cardMaxHeight(in: geometry)

            Group {
                if isCompactHeight {
                    // Landscape: text left, buttons in a horizontal row to the right
                    HStack(spacing: 12) {
                        textEditorArea

                        HStack(spacing: 8) {
                            Button("Cancel", role: .cancel) {
                                onClose()
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Button {
                                autocorrectEnabled.toggle()
                            } label: {
                                Image(systemName: autocorrectEnabled ? "textformat.abc" : "textformat.abc.dottedunderline")
                                    .font(.system(size: 14))
                                    .foregroundStyle(autocorrectEnabled ? .primary : .secondary)
                            }
                            .buttonStyle(.bordered)
                            .tint(autocorrectEnabled ? .blue : .secondary)

                            Button("Send") {
                                let textToSend = text
                                text = ""
                                onSend(textToSend)
                                onClose()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.isEmpty)
                        }
                        .fixedSize()
                    }
                } else {
                    // Portrait: text above, buttons in a row below
                    VStack(spacing: 12) {
                        textEditorArea
                            .frame(maxHeight: maxHeight - 60)

                        HStack {
                            Button("Cancel", role: .cancel) {
                                onClose()
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Spacer()

                            Button {
                                autocorrectEnabled.toggle()
                            } label: {
                                Image(systemName: autocorrectEnabled ? "textformat.abc" : "textformat.abc.dottedunderline")
                                    .font(.system(size: 14))
                                    .foregroundStyle(autocorrectEnabled ? .primary : .secondary)
                            }
                            .buttonStyle(.bordered)
                            .tint(autocorrectEnabled ? .blue : .secondary)

                            Spacer()

                            Button("Send") {
                                let textToSend = text
                                text = ""
                                onSend(textToSend)
                                onClose()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.isEmpty)
                        }
                    }
                }
            }
            .padding(isCompactHeight ? 12 : 16)
            .frame(maxHeight: maxHeight)
            .frame(width: overlayWidth)
            .composeOverlayBackground()
            .onAppear {
                text = initialText
            }
            .onChange(of: text) { _, newValue in
                onTextChanged(newValue)
            }
            #if os(iOS)
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
            .onKeyPress(keys: composeToggleKeys, phases: .down) { keyPress in
                if keyPress.modifiers == composeToggleModifiers {
                    onClose()
                    return .handled
                }
                return .ignored
            }
            #endif
            .frame(maxWidth: .infinity, maxHeight: available, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - UITextView Wrapper

/// UITextView wrapped for SwiftUI that shares the terminal's inputAccessoryView,
/// enabling seamless keyboard focus transfer without toolbar bounce.
private struct ComposeTextView: UIViewRepresentable {
    @Binding var text: String
    let autocorrectEnabled: Bool
    let keyboardAccessory: UIView?
    let onTextViewCreated: ((UITextView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextViewCreated: onTextViewCreated)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        #if !os(visionOS)
        textView.inputAccessoryView = keyboardAccessory
        #endif
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        TextFieldTouchKeyboard.exclude(textView)
        #endif
        applyAutocorrectSettings(textView)
        textView.text = text

        // Auto-focus after a brief delay to let the view settle into the hierarchy.
        // Skipped while the secure-draw latch is armed: presenting the keyboard
        // under lock is a FrontBoard 0x2BAD45EC kill. The overlay is dismissed
        // with the app inactive anyway, so there is nothing to restore.
        DispatchQueue.main.async {
            guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
            textView.becomeFirstResponder()
        }

        onTextViewCreated?(textView)
        return textView
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.onTextViewCreated?(nil)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        // Update autocorrect settings when toggled
        let currentAutocorrect = textView.autocorrectionType == .yes
        if currentAutocorrect != autocorrectEnabled {
            applyAutocorrectSettings(textView)
            // Reload input views to apply the change immediately. Never while the
            // secure-draw latch is armed — the placement move draws under lock.
            if !Ghostty.isSecureDrawProhibitedAtomic {
                textView.reloadInputViews()
            }
        }
    }

    private func applyAutocorrectSettings(_ textView: UITextView) {
        if autocorrectEnabled {
            textView.autocorrectionType = .yes
            textView.spellCheckingType = .yes
            if #available(iOS 17.0, *) {
                textView.inlinePredictionType = .yes
            }
        } else {
            textView.autocorrectionType = .no
            textView.spellCheckingType = .no
            if #available(iOS 17.0, *) {
                textView.inlinePredictionType = .no
            }
        }
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        let onTextViewCreated: ((UITextView?) -> Void)?

        init(text: Binding<String>, onTextViewCreated: ((UITextView?) -> Void)?) {
            _text = text
            self.onTextViewCreated = onTextViewCreated
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

// MARK: - Glass Background Modifier

private extension View {
    @ViewBuilder
    func composeOverlayBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
        }
        #endif
    }
}
