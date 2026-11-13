//
//  KeyboardToolbarOrnament.swift
//  rootshell
//
//  visionOS window ornament wrapping KeyboardToolbarView for on-screen key input.
//

#if os(visionOS)
import SwiftUI
import UIKit

// MARK: - Notification

extension Notification.Name {
    static let toggleKeyboardToolbar = Notification.Name("com.rootshell.toggleKeyboardToolbar")
}

// MARK: - Ornament View

struct KeyboardToolbarOrnament: View {
    let focusedTerminal: Ghostty.TerminalView?
    /// Any pane kind, including Screen Sharing; routes window-scoped pane actions.
    let focusedPane: SplitPaneView?
    @Binding var isVisible: Bool
    @State private var toolbarHeight: CGFloat = KeyboardSizes.iPad.toolbar.height

    var body: some View {
        KeyboardToolbarRepresentable(
            focusedTerminal: focusedTerminal,
            focusedPane: focusedPane,
            onDismiss: { isVisible = false },
            onHeightChanged: { newHeight in
                withAnimation(.easeInOut(duration: 0.25)) {
                    toolbarHeight = newHeight
                }
            }
        )
        .frame(width: 720, height: toolbarHeight)
        .glassBackgroundEffect()
    }
}

// MARK: - UIViewRepresentable

struct KeyboardToolbarRepresentable: UIViewRepresentable {
    let focusedTerminal: Ghostty.TerminalView?
    let focusedPane: SplitPaneView?
    let onDismiss: () -> Void
    let onHeightChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> KeyboardToolbarView {
        let toolbar = KeyboardToolbarView(sizes: .iPad)
        let coordinator = context.coordinator
        toolbar.delegate = coordinator

        // Disable the toolbar's built-in blur — the ornament's glassBackgroundEffect handles it
        toolbar.backgroundColor = .clear
        toolbar.layer.cornerRadius = 0
        toolbar.clipsToBounds = false

        // Wire action callbacks via notifications (same pattern as TerminalView.setupKeyboard)
        toolbar.onDismissRequested = { [onDismiss] in
            onDismiss()
        }

        toolbar.onTabSwitcherRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .showTabSwitcher, object: toolbar)
        }

        toolbar.onToolbarSettingsRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .showToolbarSettings, object: toolbar)
        }

        toolbar.onPasteRequested = { [weak coordinator] in
            coordinator?.focusedTerminal?.paste(nil)
        }

        toolbar.onToggleFullScreenRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleFullScreen, object: toolbar)
        }

        toolbar.onToggleTabBarRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleTabBar, object: toolbar)
        }

        toolbar.onChoosePaneToZoomRequested = { [weak coordinator] in
            // The pane, not the toolbar, identifies the window with several open.
            guard let pane = coordinator?.focusedPane else { return }
            NotificationCenter.default.post(name: .choosePaneToZoom, object: pane)
        }

        toolbar.onTogglePaneZoomRequested = { [weak coordinator] in
            guard let pane = coordinator?.focusedPane else { return }
            NotificationCenter.default.post(name: .togglePaneZoom, object: pane)
        }

        toolbar.onNewConnectionRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .newTab, object: toolbar)
        }

        toolbar.onAppSettingsRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .openSettings, object: toolbar)
        }

        toolbar.onComposeRequested = { [weak coordinator] in
            guard let terminal = coordinator?.focusedTerminal else { return }
            if terminal.showComposeOverlay {
                terminal.becomeFirstResponder()
            }
            terminal.showComposeOverlay.toggle()
            NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: terminal)
        }

        toolbar.onToggleMouseCaptureRequested = { [weak coordinator] in
            coordinator?.focusedTerminal?.toggleMouseReporting()
        }

        toolbar.onAIAgentRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleAIAgent, object: toolbar)
        }

        toolbar.onClipboardManagerRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleClipboardManager, object: toolbar)
        }

        toolbar.onFileManagerRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleFileManager, object: toolbar)
        }

        toolbar.onHTTPCaptureRequested = { [weak toolbar] in
            NotificationCenter.default.post(name: .toggleHTTPCapture, object: toolbar)
        }

        toolbar.onModifiersChanged = { [weak coordinator] modifiers in
            coordinator?.focusedTerminal?.activeKeyboardModifiers = modifiers
        }

        toolbar.onDrawerStateChanged = { [weak toolbar, onHeightChanged] in
            guard let toolbar else { return }
            let newHeight = toolbar.intrinsicContentSize.height
            DispatchQueue.main.async {
                onHeightChanged(newHeight)
            }
        }

        // Store toolbar reference in coordinator and start observing layout changes
        coordinator.toolbar = toolbar
        coordinator.onHeightChanged = onHeightChanged
        coordinator.observeLayoutChanges()

        return toolbar
    }

    func updateUIView(_ toolbar: KeyboardToolbarView, context: Context) {
        let coordinator = context.coordinator
        let terminal = focusedTerminal

        // Update delegate target when focused terminal changes
        coordinator.focusedTerminal = terminal
        coordinator.focusedPane = focusedPane

        // Give the terminal a back-reference for clearOneShotModifiers
        terminal?.externalToolbar = toolbar
    }

    // MARK: - Coordinator

    class Coordinator: KeyboardButtonDelegate {
        weak var focusedTerminal: Ghostty.TerminalView?
        weak var focusedPane: SplitPaneView?
        weak var toolbar: KeyboardToolbarView?
        var onHeightChanged: ((CGFloat) -> Void)?
        private var layoutChangeObserver: NSObjectProtocol?

        func observeLayoutChanges() {
            layoutChangeObserver = NotificationCenter.default.addObserver(
                forName: KeyboardToolbarManager.layoutDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let toolbar = self.toolbar else { return }
                toolbar.rebuildForCurrentWidth()
                let newHeight = toolbar.intrinsicContentSize.height
                self.onHeightChanged?(newHeight)
            }
        }

        deinit {
            if let observer = layoutChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func keyPressed(_ key: String, modifiers: KeyModifiers) {
            focusedTerminal?.keyPressed(key, modifiers: modifiers)
        }

        func cancelScrollTouches() {
            focusedTerminal?.cancelScrollTouches()
        }

        func sendRawData(_ data: Data) {
            focusedTerminal?.sendRawData(data)
        }

        func sendKeyCombo(_ combo: SequenceStep.KeyCombo) -> Bool {
            focusedTerminal?.sendKeyCombo(combo) ?? false
        }

        func sendSequenceData(_ data: Data) {
            focusedTerminal?.sendSequenceData(data)
        }
    }
}
#endif
