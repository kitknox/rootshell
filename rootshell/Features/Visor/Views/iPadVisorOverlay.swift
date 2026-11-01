import SwiftUI
import UIKit
import Observation

extension View {
    @ViewBuilder
    func iPadVisor(ghosttyApp: Ghostty.App, windowID: String, modalPresented: Bool) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .pad {
            modifier(iPadVisorModifier(ghosttyApp: ghosttyApp, windowID: windowID,
                                       modalPresented: modalPresented))
        } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
@Observable
final class iPadVisorController {
    private static let owners = NSMapTable<UIWindow, iPadVisorController>.weakToWeakObjects()
    private(set) var visible = false
    private(set) var terminal: Ghostty.TerminalView?
    private(set) var scrollView: Ghostty.TerminalScrollView?
    weak var window: UIWindow?
    weak var previousResponder: UIView?
    var modalPresented = false
    var terminalID = UUID()
    var owningWindowID: String?

    /// Only window-level commands may escape the standalone terminal. Keep
    /// close/search/compose/font and split commands local to their source.
    /// Nil means the sender is not a Visor terminal and normal tab routing applies.
    static func routeWindowAction(_ notification: Notification, to windowID: String) -> Bool? {
        guard let source = notification.object as? Ghostty.TerminalView,
              let owner = (owners.objectEnumerator()?.allObjects as? [iPadVisorController])?
                .first(where: { $0.terminal === source }) else { return nil }
        guard owner.owningWindowID == windowID, owner.visible else { return false }
        switch notification.name {
        case .openSettings, .toggleQuickSettings, .openInFolder, .newTab, .createLocalShell, .newWindow,
             .previousTab, .nextTab, .selectTab, .previousGroup, .nextGroup,
             .showTabSwitcher, .toggleTabExpose, .toggleTabBar, .toggleGroupMode,
             .browseHosts, .browseProfiles, .toggleAIAgent, .toggleVoiceAgent, .toggleDictation,
             .toggleThemePicker, .toggleClipboardManager, .toggleIPLookup, .toggleHTTPCapture, .toggleAgentInbox, .toggleFullScreen,
             .toggleBackgroundEffect, .toggleTitleBar, .toggleTransparency, .toggleAutoRedact:
            owner.hide()
            return true
        default:
            return false
        }
    }

    static func permitsFocus(_ terminal: Ghostty.TerminalView) -> Bool {
        guard let window = terminal.window, let owner = owners.object(forKey: window) else { return true }
        if terminal === owner.terminal { return owner.visible }
        return !owner.visible
    }

    func attach(to window: UIWindow?) {
        if let previous = self.window, previous !== window {
            Self.owners.removeObject(forKey: previous)
        }
        self.window = window
        if let window { Self.owners.setObject(self, forKey: window) }
    }

    func install(_ terminal: Ghostty.TerminalView) -> Ghostty.TerminalScrollView {
        self.terminal = terminal
        let scrollView = Ghostty.TerminalScrollView(terminalView: terminal)
        self.scrollView = scrollView
        return scrollView
    }

    func toggle() {
        guard iPadVisorSettings.shared.enabled, let window,
              window.windowScene?.activationState == .foregroundActive,
              !modalPresented, !Self.hasPresentation(window.rootViewController) else { return }
        if visible { hide() } else {
            previousResponder = Self.firstResponder(in: window)
            if let terminal = previousResponder as? Ghostty.TerminalView {
                terminal.focusDidChange(false)
            } else { previousResponder?.resignFirstResponder() }
            visible = true
            terminal?.isLogicallyFocused = true
            terminal?.setOcclusion(true)
            terminal?.setWindowActive(true)
            terminal?.focusDidChange(true)
        }
    }

    func hide(restoreFocus: Bool = true) {
        guard visible else { return }
        if terminal?.searchState != nil { terminal?.closeSearch() }
        // Keep the compose draft, but dismiss its editor with the panel.
        terminal?.showComposeOverlay = false
        terminal?.focusDidChange(false)
        terminal?.isLogicallyFocused = false
        terminal?.setWindowActive(false)
        terminal?.setOcclusion(false)
        visible = false
        if restoreFocus, window?.windowScene?.activationState == .foregroundActive {
            if let terminal = previousResponder as? Ghostty.TerminalView {
                terminal.isLogicallyFocused = true
                terminal.focusDidChange(true)
            } else { previousResponder?.becomeFirstResponder() }
        }
        previousResponder = nil
    }

    func sessionEnded() {
        hide()
        terminal?.cleanup(reason: .userClose)
        terminal = nil
        scrollView = nil
        terminalID = UUID()
    }

    func dispose() {
        hide(restoreFocus: false)
        terminal?.cleanup(reason: .userClose)
        terminal = nil
        scrollView = nil
        if let window { Self.owners.removeObject(forKey: window) }
    }

    private static func hasPresentation(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        if controller.presentedViewController != nil { return true }
        return controller.children.contains { hasPresentation($0) }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }
}

private struct iPadVisorModifier: ViewModifier {
    let ghosttyApp: Ghostty.App
    let windowID: String
    let modalPresented: Bool
    @State private var controller = iPadVisorController()
    @State private var settings = iPadVisorSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("ipad.visor.heightFraction") private var heightFraction = 0.3
    @GestureState private var resizeTranslation: CGFloat = 0
    @State private var keyboardOverlap: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                iPadVisorWindowProbe(controller: controller, windowID: windowID)
                    .frame(width: 0, height: 0)
                iPadVisorShortcut(controller: controller, modalPresented: modalPresented)
            }
            .overlay {
                GeometryReader { geometry in
                    let available = max(1, geometry.size.height - keyboardOverlap)
                    let baseHeight = min(available, max(min(160, available), available * heightFraction))
                    let height = min(available, max(min(160, available),
                        min(available * 0.85, baseHeight + resizeTranslation)))
                    ZStack(alignment: .top) {
                        if controller.visible {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { controller.hide() }
                                .accessibilityLabel("Dismiss Visor")
                                .accessibilityAddTraits(.isButton)
                        }
                        if controller.visible {
                            Group {
                                if ghosttyApp.readiness == .ready, ghosttyApp.app != nil {
                                    iPadVisorTerminal(controller: controller, app: ghosttyApp,
                                                      windowID: "ipad-visor-" + windowID)
                                        .id(controller.terminalID)
                                } else if ghosttyApp.readiness == .error {
                                    Text("Failed to initialize terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .frame(height: height)
                            .overlay {
                                if let terminal = controller.terminal {
                                    iPadVisorTerminalOverlays(terminal: terminal)
                                        .id(terminal.uuid)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Capsule()
                                    .fill(.secondary.opacity(0.65))
                                    .frame(width: 36, height: 4)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 24, alignment: .bottom)
                                    .contentShape(Rectangle())
                                    // The bottom edge moves during resizing. A local
                                    // translation feeds that movement back into the
                                    // gesture and makes the height oscillate.
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .updating($resizeTranslation) { value, translation, transaction in
                                            transaction.disablesAnimations = true
                                            translation = value.translation.height
                                        }
                                        .onEnded { value in
                                            heightFraction = min(0.85, max(min(160 / available, 0.85),
                                                (baseHeight + value.translation.height) / available))
                                        })
                                    .accessibilityLabel("Visor height")
                                    .accessibilityValue("\(Int(heightFraction * 100)) percent")
                                    .accessibilityAdjustableAction { direction in
                                        heightFraction = min(0.85, max(min(160 / available, 0.85),
                                            heightFraction + (direction == .increment ? 0.05 : -0.05)))
                                    }
                            }
                            .accessibilityAction(named: "Dismiss Visor") { controller.hide() }
                            .modifier(iPadVisorGlass())
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .padding(.horizontal, 12)
                            .allowsHitTesting(controller.visible)
                            .accessibilityHidden(!controller.visible)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .clipped()
            }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.visible)
        .onAppear { controller.modalPresented = modalPresented }
        .onChange(of: modalPresented) { _, presented in
            controller.modalPresented = presented
            if presented { controller.hide(restoreFocus: false) }
        }
        .onChange(of: settings.enabled) { _, enabled in
            if !enabled { controller.hide() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.hide(restoreFocus: false) }
            if phase == .background { controller.terminal?.session?.pauseForBackground() }
            if phase == .active { controller.terminal?.session?.resumeForForeground() }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .toggleVisorOverlay) {
                guard let source = notification.object as? UIView, source.window === controller.window else { continue }
                controller.toggle()
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .closeSplit) {
                guard let source = notification.object as? Ghostty.TerminalView,
                      source === controller.terminal else { continue }
                controller.sessionEnded()
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: UIResponder.keyboardWillChangeFrameNotification) {
                guard let window = controller.window, window.isKeyWindow,
                      let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { continue }
                let frame = window.convert(value.cgRectValue, from: window.screen.coordinateSpace)
                let intersection = window.bounds.intersection(frame)
                keyboardOverlap = !intersection.isNull && intersection.maxY >= window.bounds.maxY - 1
                    ? intersection.height : 0
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
                keyboardOverlap = 0
            }
        }
    }
}

private struct iPadVisorGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .systemBackground))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

/// These controls belong to the Visor surface, never the selected main tab.
private struct iPadVisorTerminalOverlays: View {
    let terminal: Ghostty.TerminalView
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ZStack {
            if let searchState = terminal.searchState {
                DraggableHUDContainer(
                    dismissShortcuts: [.escape],
                    forwardsFindToggle: true,
                    onDismiss: { terminal.closeSearch() }
                ) {
                    TerminalSearchOverlay(
                        searchState: searchState,
                        onSearch: { terminal.performSearch($0) },
                        onNavigate: { terminal.navigateSearch(direction: $0) },
                        onClose: { terminal.closeSearch() }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if terminal.showComposeOverlay {
                TerminalComposeOverlay(
                    initialText: terminal.composeText,
                    onSend: { text in
                        terminal.sendComposedText(text)
                        terminal.composeText = ""
                    },
                    onClose: {
                        terminal.becomeFirstResponder()
                        terminal.showComposeOverlay = false
                        NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: terminal)
                    },
                    onTextChanged: { terminal.composeText = $0 },
                    keyboardAccessory: terminal.shouldShowKeyboardToolbar ? terminal.keyboardAccessory : nil,
                    onTextViewCreated: { terminal.activeComposeTextView = $0 }
                )
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .ghosttySearchStateChanged) {
                guard notification.object as? Ghostty.TerminalView === terminal else { continue }
                revision &+= 1
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .ghosttyComposeStateChanged) {
                guard notification.object as? Ghostty.TerminalView === terminal else { continue }
                revision &+= 1
            }
        }
    }
}

private struct iPadVisorTerminal: UIViewRepresentable {
    let controller: iPadVisorController
    let app: Ghostty.App
    let windowID: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    final class Coordinator {
        var reduceTransparency: Bool?
        var visible: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Ghostty.TerminalScrollView {
        // The panel leaves the view tree when hidden. Retain the UIKit terminal
        // independently so reopening preserves its shell, scrollback, and size.
        if let scrollView = controller.scrollView { return scrollView }
        let terminal = Ghostty.TerminalView(app.app!, ghosttyApp: app, uuid: controller.terminalID,
                                           connectionConfig: .local(), windowId: windowID)
        let scrollView = controller.install(terminal)
        terminal.isLogicallyFocused = controller.visible
        terminal.setOcclusion(controller.visible)
        terminal.setWindowActive(controller.visible)
        terminal.focusDidChange(controller.visible)
        return scrollView
    }
    func updateUIView(_ view: Ghostty.TerminalScrollView, context: Context) {
        if context.coordinator.reduceTransparency != reduceTransparency,
           let surface = view.terminalView.surface {
            context.coordinator.reduceTransparency = reduceTransparency
            app.refreshSurfaceTheme(surface, tabId: nil, windowId: windowID)
        }
        if context.coordinator.visible != controller.visible {
            context.coordinator.visible = controller.visible
            view.terminalView.isLogicallyFocused = controller.visible
            view.terminalView.setOcclusion(controller.visible)
            view.terminalView.setWindowActive(controller.visible)
            view.terminalView.focusDidChange(controller.visible)
        }
    }
}

/// Register the shortcut in the existing SwiftUI window hierarchy, without
/// rehosting its content or adding any visible controls or layout space.
private struct iPadVisorShortcut: View {
    let controller: iPadVisorController
    let modalPresented: Bool
    @State private var settings = iPadVisorSettings.shared
    @ObservedObject private var keybinds = KeybindManager.shared

    var body: some View {
        if settings.enabled, !modalPresented,
           let sequence = keybinds.keybind(for: .toggle_visor)?.sequence,
           !sequence.isSequence, let trigger = sequence.first,
           let key = trigger.swiftUIKeyEquivalent {
            Button("Toggle Visor") { controller.toggle() }
                .keyboardShortcut(key, modifiers: trigger.swiftUIEventModifiers)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .clipped()
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Read the original window without inserting another hosting controller or
/// changing safe-area/keyboard layout. Its lifetime also owns terminal cleanup.
private struct iPadVisorWindowProbe: UIViewRepresentable {
    let controller: iPadVisorController
    let windowID: String

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        controller.owningWindowID = windowID
        view.visor = controller
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        controller.owningWindowID = windowID
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.visor?.dispose()
    }

    final class Probe: UIView {
        weak var visor: iPadVisorController?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            visor?.attach(to: window)
        }
    }
}
#endif
