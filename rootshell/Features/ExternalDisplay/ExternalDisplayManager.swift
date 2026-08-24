//
//  ExternalDisplayManager.swift
//  rootshell
//
//  Owns the external-display session: the ExternalWindow in the external
//  scene, the typing-focus target (device vs external), control mode (the
//  external workspace raised interactive on the device with a live mirror on
//  the external screen), tab transfers, and the merge-back on disconnect.
//
//  Deliberately NOT observable from the App scene list; UI reacts to the
//  posted notifications instead (scene-list invalidation caused 0x8BADF00D
//  watchdog kills in the past).
//

#if !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import os.log
import rootshellVNC

@MainActor
final class ExternalDisplayManager {
    static let shared = ExternalDisplayManager()
    static let externalWindowId = ExternalDisplay.windowId

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ExternalDisplay")

    enum Phase {
        case idle
        /// External scene connected before Ghostty.App existed (cold launch
        /// with the display attached); attach completes from a device MainView.
        case pendingApp
        case active
        case tearingDown
    }

    enum FocusTarget {
        case device
        case external
    }

    private(set) var phase: Phase = .idle
    private(set) var externalWindow: ExternalWindow?
    private(set) var externalScene: UIWindowScene?
    private(set) var focusTarget: FocusTarget = .device

    /// Destination for the disconnect merge-back.
    private(set) var lastFocusedDeviceWindowId: String?

    /// iOS 27+ scene accessory registration (nil on earlier SDKs).
    private let accessoryRegistrar = ExternalSceneAccessoryFactory.make()
    private weak var accessoryHostViewController: UIViewController?
    private var observerTokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // Keybind / toolbar / menu entry points, handled once globally so a
        // toggle can never double-fire across MainViews.
        observerTokens.append(center.addObserver(
            forName: .toggleExternalDisplayFocus, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ExternalDisplayManager.shared.toggleFocus()
            }
        })
        observerTokens.append(center.addObserver(
            forName: .moveTabToExternalDisplay, object: nil, queue: .main
        ) { notification in
            let sourceWindowId = notification.userInfo?["windowId"] as? String
            MainActor.assumeIsolated {
                ExternalDisplayManager.shared.handleMoveTabRequest(sourceWindowId: sourceWindowId)
            }
        })
        // A TV/receiver switching resolution changes the auto-zoom answer.
        observerTokens.append(center.addObserver(
            forName: UIScreen.modeDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ExternalDisplayManager.shared.handleZoomPreferenceChange()
            }
        })
        // Fallback that does not depend on configurationForConnecting being
        // consulted. Both handlers are phase-guarded, so double delivery via
        // the scene delegate is a no-op.
        observerTokens.append(center.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { notification in
            let scene = notification.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard let scene, scene.isExternalDisplayScene else { return }
                Self.logger.info("External scene willConnect (notification path)")
                guard ExternalDisplaySettings.isEnabled else { return }
                ExternalDisplayManager.shared.handleExternalSceneConnected(scene)
            }
        })
        observerTokens.append(center.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { notification in
            let scene = notification.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard let scene, scene.isExternalDisplayScene else { return }
                Self.logger.info("External scene didDisconnect (notification path)")
                ExternalDisplayManager.shared.handleExternalSceneDisconnected()
            }
        })
    }

    var isExternalSessionActive: Bool { phase == .active }

    var externalScreenScale: CGFloat {
        externalScene?.screen.scale ?? UIScreen.main.scale
    }

    /// Whether external tabs count as "viewed" (agent attention): the panel
    /// is always visible, and in control mode they are on the device too.
    var isExternalWindowViewed: Bool { phase == .active }

    // MARK: - Zoom

    /// Display-zoom factor for the external window's UI (1.0 = native).
    private(set) var zoomFactor: CGFloat = 1.0
    private var zoomContainer: ExternalZoomContainerController?

    private func resolvedZoomFactor(for screen: UIScreen) -> CGFloat {
        let manual = ExternalDisplaySettings.zoom
        if manual > 0 { return CGFloat(manual) }
        return ExternalDisplaySettings.autoZoomFactor(for: screen)
    }

    /// Live re-apply for a zoom preference change or a display mode change.
    /// Arms every external terminal's scale sync first so the layout pass
    /// delivering the new reduced bounds issues one paired scale+size push.
    func handleZoomPreferenceChange() {
        guard isExternalSessionActive,
              let zoomContainer, let externalScene else { return }
        zoomContainer.externalNativeSize = externalScene.screen.bounds.size
        let newZoom = resolvedZoomFactor(for: externalScene.screen)
        guard newZoom != zoomFactor else { return }
        zoomFactor = newZoom
        if let model = TerminalWindowRegistry.tabsModel(for: Self.externalWindowId) {
            for tab in model.tabs {
                for terminal in tab.splitTree.terminalLeaves {
                    terminal.noteEffectiveScaleChanged()
                }
            }
        }
        zoomContainer.zoomFactor = newZoom
        if let controlContainer {
            controlContainer.externalNativeSize = zoomContainer.externalNativeSize
            controlContainer.zoomFactor = newZoom
        }
        mirror.noteZoomFactorChanged(newZoom)
    }

    /// Single source of truth for a terminal's content scale. External
    /// content compensates for display zoom so the Metal framebuffer keeps
    /// the external panel's native pixel footprint (the same IOSurfaces feed
    /// the mirror in control mode).
    func effectiveScale(isExternalContent: Bool, window: UIWindow?) -> CGFloat {
        if isExternalContent, phase == .active {
            return externalScreenScale * zoomFactor
        }
        return window?.screen.scale ?? UIScreen.main.scale
    }

    // MARK: - Scene lifecycle

    func handleExternalSceneConnected(_ scene: UIWindowScene) {
        guard phase == .idle else {
            Self.logger.warning("External scene connected while phase != idle; ignoring")
            return
        }
        externalScene = scene
        guard Ghostty.App.shared != nil else {
            Self.logger.info("External scene connected before Ghostty app; deferring attach")
            phase = .pendingApp
            return
        }
        attachWindow()
    }

    /// Called from device MainViews whenever they have a live scene.
    /// Completes a deferred attach and gives the iOS 27 registrar a visible
    /// view controller to register on.
    func handleDeviceSceneReady(windowScene: UIWindowScene) {
        if let registrar = accessoryRegistrar,
           let rootVC = windowScene.windows.first(where: { !$0.isExternalDisplayPresentation })?.rootViewController,
           rootVC !== accessoryHostViewController {
            accessoryHostViewController = rootVC
            registrar.ensureRegistered(on: rootVC)
        }

        guard phase == .pendingApp, Ghostty.App.shared != nil else { return }
        guard externalScene != nil else {
            phase = .idle
            return
        }
        Self.logger.info("Device scene ready; completing deferred external attach")
        attachWindow()
    }

    private func attachWindow() {
        guard let externalScene, let ghosttyApp = Ghostty.App.shared else { return }

        zoomFactor = resolvedZoomFactor(for: externalScene.screen)
        let host = ExternalDisplayRootController(
            rootView: ExternalDisplayRootView(ghosttyApp: ghosttyApp)
        )
        let container = ExternalZoomContainerController(
            hostingController: host,
            zoomFactor: zoomFactor,
            externalNativeSize: externalScene.screen.bounds.size
        )
        zoomContainer = container

        let window = ExternalWindow(windowScene: externalScene)
        window.frame = externalScene.screen.bounds
        window.rootViewController = container
        window.isHidden = false
        externalWindow = window

        phase = .active
        focusTarget = .device

        let width = Int(window.frame.width)
        let height = Int(window.frame.height)
        let scale = Double(externalScene.screen.scale)
        Self.logger.info("External display attached: \(width)x\(height) @\(scale)x zoom=\(Double(self.zoomFactor))")
        NotificationCenter.default.post(name: .externalDisplayDidConnect, object: nil)
    }

    private func activeDeviceScene() -> UIWindowScene? {
        if let last = lastFocusedDeviceWindowId,
           let sceneId = TerminalWindowRegistry.sceneSessionId(for: last),
           let scene = UIApplication.shared.deviceWindowScenes.first(where: { $0.session.persistentIdentifier == sceneId }),
           scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            return scene
        }
        return UIApplication.shared.deviceForegroundWindowScene
    }

    func handleExternalSceneDisconnected() {
        guard phase == .active || phase == .pendingApp else { return }
        if phase == .pendingApp {
            phase = .idle
            externalScene = nil
            return
        }
        // Must run while phase is still .active and the external tabs are
        // still registered: clears the external cursor, restores device first
        // responder, posts the focus notification.
        setFocus(.device)
        phase = .tearingDown

        // Pure model mutations, safe at any lifecycle moment; deferring them
        // risks losing sessions if the app dies before the gate opens.
        moveAllExternalTabsBackToDevice()

        // Window teardown can land mid foreground transition (display
        // unplugged while backgrounded); defer that part until safe.
        ForegroundActivationGate.shared.runWhenSafe(
            reason: "externalDisplayDisconnect",
            timeoutPolicy: .fireIfNotBackgrounded
        ) { [self] in
            completeTeardown()
        }
    }

    private func completeTeardown() {
        exitControlSurface()
        moveAllExternalTabsBackToDevice()

        externalWindow?.isHidden = true
        externalWindow?.rootViewController = nil
        externalWindow = nil
        externalScene = nil
        zoomContainer = nil
        zoomFactor = 1.0
        externallyFontSizedTmuxWindows.removeAll()

        // SwiftUI's onDisappear for the hosted MainView is not guaranteed to
        // run; clear its window registrations explicitly (all idempotent).
        WindowStateManager.shared.unregisterWindow(windowId: Self.externalWindowId)
        TerminalWindowRegistry.unregister(windowId: Self.externalWindowId)
        TmuxWindowRegistry.unregister(windowId: Self.externalWindowId)
        TextAvoidanceFocus.uninstall(windowId: Self.externalWindowId)

        phase = .idle
        Self.logger.info("External display detached; content merged back to device")
        NotificationCenter.default.post(name: .externalDisplayDidDisconnect, object: nil)
        NotificationCenter.default.post(name: .externalDisplayFocusChanged, object: nil)
    }

    /// Tear down as if the display were unplugged (Settings toggle turned
    /// off). The scene stays connected and shows the system mirror.
    func disableWhileActive() {
        handleExternalSceneDisconnected()
    }

    // MARK: - Focus

    func toggleFocus() {
        setFocus(focusTarget == .device ? .external : .device)
    }

    /// `.external` raises the control surface on the device; `.device`
    /// parks the workspace back on the external screen and restores the
    /// device terminal's first responder.
    func setFocus(_ target: FocusTarget) {
        guard phase == .active else {
            focusTarget = .device
            return
        }
        guard target != focusTarget else { return }
        focusTarget = target
        if target == .external {
            enterControlSurface()
        } else {
            exitControlSurface()
            externalFocusedTerminal()?.setRemoteInputFocus(false)
            restoreDeviceFirstResponder()
        }
        NotificationCenter.default.post(name: .externalDisplayFocusChanged, object: nil)
    }

    /// The terminal that device-side input is forwarded to, or nil.
    func redirectTarget() -> Ghostty.TerminalView? {
        guard phase == .active, focusTarget == .external else { return nil }
        return externalFocusedTerminal()
    }

    /// The focused external pane regardless of type (the input proxy
    /// branches on terminal vs VNC).
    func redirectPane() -> SplitPaneView? {
        guard phase == .active, focusTarget == .external else { return nil }
        return TerminalWindowRegistry.tabsModel(for: Self.externalWindowId)?
            .selectedTab?.focusedPane
    }

    /// Input funnel for the residual forwarding paths (VNC keyboard).
    let inputProxy = ExternalInputProxy()

    /// Live pixel mirror on the external screen during control mode.
    private let mirror = ExternalMirrorController()

    /// True while the external content is presented interactive on the
    /// device: its terminals may hold first responder.
    private(set) var isControlSurfaceActive = false

    private var controlWindow: ControlSurfaceWindow?
    private var controlContainer: ExternalZoomContainerController?
    private weak var keyWindowBeforeControl: UIWindow?

    private func enterControlSurface() {
        guard phase == .active, !isControlSurfaceActive,
              let externalWindow, let externalScene,
              let zoomContainer,
              let deviceScene = activeDeviceScene() else { return }

        // Freeze Match Client sizing BEFORE any re-parenting: the transition
        // fires measured size updates that would otherwise renegotiate the
        // remote to transient device dimensions.
        setVNCDisplaySizeFreeze(true)
        // A sheet cannot ride a cross-scene re-parent.
        zoomContainer.hostingController?.presentedViewController?.dismiss(animated: false)

        isControlSurfaceActive = true
        guard let hosted = zoomContainer.detachHostedContent() else {
            isControlSurfaceActive = false
            setVNCDisplaySizeFreeze(false)
            return
        }

        let container = ExternalZoomContainerController(
            hostingController: nil,
            zoomFactor: zoomFactor,
            externalNativeSize: zoomContainer.externalNativeSize
        )
        container.fitMode = .deviceFit

        let window = ControlSurfaceWindow(windowScene: deviceScene)
        window.frame = deviceScene.screen.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = container
        keyWindowBeforeControl = deviceScene.windows.first { $0.isKeyWindow && !$0.isExternalDisplayPresentation }
        // Key status is required: UIKit routes hardware presses through the
        // key window's responder chain.
        window.makeKeyAndVisible()
        container.attachHostedContent(hosted)
        controlWindow = window
        controlContainer = container

        mirror.start(
            externalWindow: externalWindow,
            contentRoot: hosted.view,
            zoomFactor: zoomFactor,
            screen: externalScene.screen
        )

        if let terminal = externalFocusedTerminal() {
            terminal.isLogicallyFocused = true
            // The fresh window's activeAppearance trait lags a runloop turn;
            // the override makes the keyboard come up on the first enter.
            terminal.setWindowActive(true)
            _ = terminal.focusDidChange(true)
        } else if let vncPane = redirectPane() as? VNCPaneView {
            _ = vncPane.focusDidChange(true)
        }
    }

    private func exitControlSurface() {
        guard isControlSurfaceActive else { return }
        isControlSurfaceActive = false
        mirror.stop()
        if let terminal = externalFocusedTerminal(), terminal.isFirstResponder {
            _ = terminal.resignFirstResponder()
        }
        controlContainer?.hostingController?.presentedViewController?.dismiss(animated: false)
        if let controlContainer, let zoomContainer,
           let hosted = controlContainer.detachHostedContent() {
            zoomContainer.attachHostedContent(hosted)
        }
        let deviceScene = controlWindow?.windowScene
        controlWindow?.isHidden = true
        controlWindow?.windowScene = nil
        controlWindow = nil
        controlContainer = nil
        if let previous = keyWindowBeforeControl {
            previous.makeKey()
        } else if let device = deviceScene?.windows.first(where: { !$0.isExternalDisplayPresentation }) {
            device.makeKey()
        }
        keyWindowBeforeControl = nil
        // Content is parked again; the latest settled measurement applies once.
        setVNCDisplaySizeFreeze(false)
    }

    /// Freeze/unfreeze Match Client sizing for every external VNC pane.
    /// Leaving control mode also drops keyboard capture: parked panes must
    /// never hold the responder in the non-interactive window.
    private func setVNCDisplaySizeFreeze(_ frozen: Bool) {
        guard let model = TerminalWindowRegistry.tabsModel(for: Self.externalWindowId) else { return }
        for tab in model.tabs {
            for pane in tab.splitTree {
                guard let vncPane = pane as? VNCPaneView else { continue }
                vncPane.session.hostFreezesRemoteDisplaySizeUpdates = frozen
                if !frozen, !isControlSurfaceActive {
                    vncPane.keyboardCapture.release()
                }
            }
        }
    }

    /// Whether the forwarding cursor should render as focused on this
    /// terminal. The single oracle every external terminal's cursor state
    /// derives from.
    func remoteFocusApplies(to terminal: Ghostty.TerminalView) -> Bool {
        phase == .active && focusTarget == .external
            && externalFocusedTerminal() === terminal
    }

    private func restoreDeviceFirstResponder() {
        guard let deviceWindowId = deviceDestinationWindowId(),
              let terminal = TerminalWindowRegistry.tabsModel(for: deviceWindowId)?
                  .selectedTab?.focusedTerminal else { return }
        terminal.restoreDeviceFocusAfterExternalForwarding()
    }

    /// Tapping a device terminal while forwarding means "type locally again".
    func noteDeviceTerminalTapped(windowId: String) {
        guard windowId != Self.externalWindowId,
              phase == .active, focusTarget == .external else { return }
        setFocus(.device)
    }

    /// Called from device MainViews when their window reports key status.
    func noteDeviceWindowFocused(windowId: String, isKey: Bool) {
        guard windowId != Self.externalWindowId, isKey else { return }
        lastFocusedDeviceWindowId = windowId
    }

    private func externalFocusedTerminal() -> Ghostty.TerminalView? {
        TerminalWindowRegistry.tabsModel(for: Self.externalWindowId)?
            .selectedTab?.focusedTerminal
    }

    // MARK: - Transfers

    /// Keybind entry point: from a device window the selected tab goes to
    /// the external display; from the external window it comes back.
    func handleMoveTabRequest(sourceWindowId: String?) {
        guard isExternalSessionActive else { return }
        let source: String
        if let sourceWindowId {
            source = sourceWindowId
        } else if focusTarget == .external {
            source = Self.externalWindowId
        } else if let device = deviceDestinationWindowId() {
            source = device
        } else {
            return
        }

        guard let model = TerminalWindowRegistry.tabsModel(for: source),
              let tabID = model.selectedTabID else { return }
        if source == Self.externalWindowId {
            moveTabToDevice(tabID: tabID)
        } else {
            moveTabToExternal(tabID: tabID, from: source)
        }
    }

    func moveTabToExternal(tabID: UUID, from sourceWindowId: String) {
        guard isExternalSessionActive else { return }
        let moved = TabTransferCoordinator.shared.move(
            tabID: tabID,
            from: sourceWindowId,
            to: Self.externalWindowId,
            // Destination-focused semantics would drive the moved terminal to
            // becomeFirstResponder in the non-interactive window.
            isDestinationWindowFocused: false
        )
        guard moved else { return }
        if focusTarget == .external {
            // Target unchanged but the focused external terminal did change.
            if isControlSurfaceActive, let terminal = externalFocusedTerminal() {
                terminal.isLogicallyFocused = true
                _ = terminal.focusDidChange(true)
            } else {
                externalFocusedTerminal()?.setRemoteInputFocus(true)
            }
            NotificationCenter.default.post(name: .externalDisplayFocusChanged, object: nil)
        } else {
            setFocus(.external)
        }
    }

    func moveTabToDevice(tabID: UUID) {
        guard isExternalSessionActive,
              let destination = deviceDestinationWindowId() else { return }
        let moved = TabTransferCoordinator.shared.move(
            tabID: tabID,
            from: Self.externalWindowId,
            to: destination,
            isDestinationWindowFocused: true
        )
        guard moved else { return }
        setFocus(.device)
    }

    // MARK: - External font size

    /// tmux windows the external font preference sized (a user per-window
    /// zoom always wins). Keyed per controller so two concurrent sessions can
    /// reuse window ids.
    private struct TmuxWindowKey: Hashable {
        let controller: ObjectIdentifier
        let windowId: Int
    }
    private var externallyFontSizedTmuxWindows: Set<TmuxWindowKey> = []

    /// Called from TerminalView's window-transition sync whenever a terminal
    /// lands on the external display.
    func applyExternalFontSizeIfNeeded(to terminal: Ghostty.TerminalView) {
        let size = ExternalDisplaySettings.fontSize
        guard size > 0 else { return }

        if let binding = terminal.tmuxPaneBinding {
            guard let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                  controller.isActive else { return }
            let key = TmuxWindowKey(controller: ObjectIdentifier(controller), windowId: binding.windowId)
            guard !externallyFontSizedTmuxWindows.contains(key),
                  controller.overrideFontSize(forWindowId: binding.windowId) == nil else { return }
            let delta = Int((size - FontManager.shared.currentFontSize).rounded())
            guard delta != 0 else { return }
            controller.changeFontSize(windowId: binding.windowId, delta: delta)
            externallyFontSizedTmuxWindows.insert(key)
            return
        }

        guard terminal.fontSizeOverride == nil else { return }
        let delta = Int((size - FontManager.shared.currentFontSize).rounded())
        guard delta != 0 else { return }
        terminal.changeLocalFontSize(delta: delta)
    }

    /// Undo the preference when a terminal lands back on the device, only
    /// while the override still equals the preference value.
    func clearExternalFontSizeIfNeeded(from terminal: Ghostty.TerminalView) {
        let size = ExternalDisplaySettings.fontSize
        guard size > 0 else { return }

        if let binding = terminal.tmuxPaneBinding {
            guard let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                  controller.isActive else { return }
            let key = TmuxWindowKey(controller: ObjectIdentifier(controller), windowId: binding.windowId)
            guard externallyFontSizedTmuxWindows.contains(key),
                  controller.overrideFontSize(forWindowId: binding.windowId) == size else { return }
            controller.resetFontSize(windowId: binding.windowId)
            externallyFontSizedTmuxWindows.remove(key)
            return
        }

        guard terminal.fontSizeOverride == size else { return }
        terminal.resetLocalFontSize()
    }

    /// Live re-apply when the preference changes during a session.
    func handleFontPreferenceChange(from oldSize: Double, to newSize: Double) {
        guard isExternalSessionActive,
              let externalModel = TerminalWindowRegistry.tabsModel(for: Self.externalWindowId) else { return }
        for tab in externalModel.tabs {
            for terminal in tab.splitTree.terminalLeaves {
                if let binding = terminal.tmuxPaneBinding {
                    guard let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                          controller.isActive else { continue }
                    let key = TmuxWindowKey(controller: ObjectIdentifier(controller), windowId: binding.windowId)
                    if externallyFontSizedTmuxWindows.contains(key),
                       controller.overrideFontSize(forWindowId: binding.windowId) == oldSize, oldSize > 0 {
                        if newSize > 0 {
                            let delta = Int((newSize - oldSize).rounded())
                            guard delta != 0 else { continue }
                            controller.changeFontSize(windowId: binding.windowId, delta: delta)
                        } else {
                            controller.resetFontSize(windowId: binding.windowId)
                            externallyFontSizedTmuxWindows.remove(key)
                        }
                    } else if newSize > 0,
                              !externallyFontSizedTmuxWindows.contains(key),
                              controller.overrideFontSize(forWindowId: binding.windowId) == nil {
                        let delta = Int((newSize - FontManager.shared.currentFontSize).rounded())
                        guard delta != 0 else { continue }
                        controller.changeFontSize(windowId: binding.windowId, delta: delta)
                        externallyFontSizedTmuxWindows.insert(key)
                    }
                    continue
                }
                if newSize > 0, terminal.fontSizeOverride == nil {
                    let delta = Int((newSize - FontManager.shared.currentFontSize).rounded())
                    guard delta != 0 else { continue }
                    terminal.changeLocalFontSize(delta: delta)
                } else if terminal.fontSizeOverride == oldSize, oldSize > 0 {
                    if newSize > 0 {
                        let delta = Int((newSize - oldSize).rounded())
                        guard delta != 0 else { continue }
                        terminal.changeLocalFontSize(delta: delta)
                    } else {
                        terminal.resetLocalFontSize()
                    }
                }
            }
        }
    }

    /// Disconnect merge-back: every external tab returns to the device.
    func moveAllExternalTabsBackToDevice() {
        guard let externalModel = TerminalWindowRegistry.tabsModel(for: Self.externalWindowId),
              !externalModel.tabs.isEmpty,
              let destination = deviceDestinationWindowId() else { return }

        let tabIDs = externalModel.tabs.map(\.id)
        let moved = TabTransferCoordinator.shared.moveTabs(
            tabIDs,
            from: Self.externalWindowId,
            to: destination,
            isDestinationWindowFocused: true
        )
        if !moved {
            // The batch path is all-or-nothing; nothing may be stranded.
            Self.logger.error("Batch merge-back rejected; retrying per tab")
            for tabID in tabIDs {
                let ok = TabTransferCoordinator.shared.move(
                    tabID: tabID,
                    from: Self.externalWindowId,
                    to: destination,
                    isDestinationWindowFocused: true
                )
                if !ok {
                    Self.logger.error("Tab \(tabID.uuidString) could not be merged back")
                }
            }
        }
    }

    /// The last-focused device window if it still exists, else any
    /// registered device window.
    func deviceDestinationWindowId() -> String? {
        if let last = lastFocusedDeviceWindowId,
           TerminalWindowRegistry.tabsModel(for: last) != nil {
            return last
        }
        return TerminalWindowRegistry.targets(excluding: Self.externalWindowId)
            .first(where: { $0.id != "visor" })?.id
    }
}
#endif
