//
//  ExternalDisplayCoordinator.swift
//  rootshell
//
//  Presents a Screen Sharing session on a connected external display, sized
//  to that display, while the device stays the trackpad and keyboard.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import os
import rootshellVNC

/// What a connected monitor is doing, from one pane's point of view.
enum ExternalDisplayStatus: Equatable {
    case notConnected
    /// Full-screen apps mode with the setting on Mirror.
    case mirroring
    case showingThisSession
    case showingOtherSession
    /// iPadOS windowed apps / Stage Manager: the monitor is an extended
    /// desktop, so no dedicated external-display scene is offered.
    case extendedDesktop
    /// Extended desktop, and this pane's window is on the monitor; Match
    /// Client already sizes the remote display to that window.
    case windowOnExternalDisplay
}

@MainActor
@Observable
final class ExternalDisplayCoordinator {
    static let shared = ExternalDisplayCoordinator()
    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.rootshell", category: "ExternalDisplay")

    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var window: UIWindow?
    /// The pane to present: the scene accessory's pane on iOS 27, else the
    /// pane the user last focused, which keeps the display while the user
    /// works in another tab until another Screen Sharing pane takes focus.
    @ObservationIgnored private weak var candidatePane: VNCPaneView?
    /// The pane whose session currently carries the external display size.
    @ObservationIgnored private weak var presentedPane: VNCPaneView?
    /// Bumped whenever anything `status(for:)` reads changes, so SwiftUI
    /// re-evaluates it without observing the weak references themselves.
    private var revision = 0

    private struct WeakPane { weak var pane: VNCPaneView? }
    /// Panes that registered an external-display scene accessory, by uuid,
    /// so a connecting accessory scene can name the pane it belongs to.
    @ObservationIgnored private var accessoryPanes: [UUID: WeakPane] = [:]
    /// `UISceneAccessoryRegistration`s (iOS 27+), type-erased so the stored
    /// property needs no availability annotation.
    @ObservationIgnored private var accessoryRegistrations: [UUID: AnyObject] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?["keys"] as? [String] ?? []
            guard keys.contains(Settings.ScreenSharing.externalDisplayMode.name)
                    || keys.contains(Settings.ScreenSharing.externalDisplayScale.name) else { return }
            MainActor.assumeIsolated {
                self?.updateAccessoryEnablement()
                self?.reconcile()
            }
        }
        // The scene delegate is not the only way in: an external scene whose
        // session was configured elsewhere (for example before this app's
        // delegate existed) still reports through these notifications.
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { self?.adoptIfExternal(scene) }
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { self?.sceneDidDisconnect(scene) }
        }
        // Extended-desktop monitors never produce an external-display scene;
        // screen notifications are the only signal for the status menu.
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision &+= 1 }
            }
        }
    }

    // MARK: - Status

    func status(for pane: VNCPaneView) -> ExternalDisplayStatus {
        _ = revision
        if scene != nil {
            if ScreenSharingExternalDisplayMode.current == .mirror { return .mirroring }
            return presentedPane === pane ? .showingThisSession : .showingOtherSession
        }
        guard UIScreen.screens.count > 1 else { return .notConnected }
        if let screen = pane.window?.windowScene?.screen, screen !== UIScreen.main {
            return .windowOnExternalDisplay
        }
        return .extendedDesktop
    }

    /// Moves the external display to this pane's session.
    func show(_ pane: VNCPaneView) {
        candidatePane = pane
        reconcile()
    }

    /// Picks up an external display connected before launch. Call at launch.
    func start() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            adoptIfExternal(scene)
        }
    }

    private func adoptIfExternal(_ scene: UIWindowScene) {
        guard scene.session.role == .windowExternalDisplayNonInteractive else { return }
        sceneDidConnect(scene)
    }

    // MARK: - Scene accessories (iOS 27 SDK)

    /// Built with the iOS 27 SDK, the system no longer offers
    /// `windowExternalDisplayNonInteractive` scenes on its own; a view
    /// controller has to register a scene accessory. Each Screen Sharing pane
    /// registers one, and the system presents the most relevant registration
    /// (by view controller depth and presentation state), so the visible
    /// pane wins. Its uuid travels as the accessory's userInfo.
    func registerAccessory(for pane: VNCPaneView, on controller: UIViewController) {
        guard #available(iOS 27.0, *) else { return }
        guard accessoryRegistrations[pane.uuid] == nil else { return }
        let configuration = UISceneConfiguration(
            name: "External Display",
            sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        let registration = controller.registerSceneAccessory(
            .externalNonInteractive(
                sceneConfiguration: configuration,
                userInfo: pane.uuid.uuidString))
        registration.isEnabled = ScreenSharingExternalDisplayMode.current == .remoteDesktop
        accessoryRegistrations[pane.uuid] = registration
        accessoryPanes[pane.uuid] = WeakPane(pane: pane)
    }

    func unregisterAccessory(for pane: VNCPaneView, on controller: UIViewController?) {
        defer { accessoryPanes[pane.uuid] = nil }
        guard #available(iOS 27.0, *),
              let registration = accessoryRegistrations.removeValue(forKey: pane.uuid)
                as? UISceneAccessoryRegistration else { return }
        controller?.unregisterSceneAccessory(registration)
    }

    private func updateAccessoryEnablement() {
        guard #available(iOS 27.0, *) else { return }
        let enabled = ScreenSharingExternalDisplayMode.current == .remoteDesktop
        for case let registration as UISceneAccessoryRegistration in accessoryRegistrations.values {
            registration.isEnabled = enabled
        }
    }

    // MARK: - Scene lifecycle

    /// Called by the scene delegate with the accessory's userInfo, which may
    /// arrive after the willConnect notification already adopted the scene.
    func sceneDidConnect(_ scene: UIWindowScene, accessoryPaneID: UUID?) {
        if let accessoryPaneID, let pane = accessoryPanes[accessoryPaneID]?.pane {
            candidatePane = pane
        }
        sceneDidConnect(scene)
        if scene === self.scene { reconcile() }
    }

    func sceneDidConnect(_ scene: UIWindowScene) {
        guard scene !== self.scene else { return }
        Self.logger.notice("scene connected screen=\(String(describing: scene.screen.bounds.size), privacy: .public) scale=\(scene.screen.scale, privacy: .public)")
        self.scene = scene
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black
        // Hidden until a session claims it: an external scene with no visible
        // window lets the system keep mirroring the device.
        window.isHidden = true
        self.window = window
        reconcile()
    }

    func sceneDidDisconnect(_ scene: UIWindowScene) {
        guard scene === self.scene else { return }
        Self.logger.notice("scene disconnected")
        self.scene = nil
        window?.isHidden = true
        window = nil
        reconcile()
    }

    /// Screen mode or orientation changes resize the remote display.
    func sceneGeometryDidChange(_ scene: UIWindowScene) {
        guard scene === self.scene else { return }
        reconcile()
    }

    // MARK: - Pane lifecycle

    func paneDidFocus(_ pane: VNCPaneView) {
        guard candidatePane !== pane else { return }
        candidatePane = pane
        reconcile()
    }

    func paneDidClose(_ pane: VNCPaneView) {
        if candidatePane === pane { candidatePane = nil }
        if presentedPane === pane {
            pane.session.externalDisplayViewSize = nil
            presentedPane = nil
        }
        reconcile()
    }

    // MARK: - Reconcile

    private func reconcile() {
        defer { revision &+= 1 }
        let target: VNCPaneView? = {
            guard scene != nil,
                  ScreenSharingExternalDisplayMode.current == .remoteDesktop else { return nil }
            return candidatePane
        }()

        if let previous = presentedPane, previous !== target {
            previous.session.externalDisplayViewSize = nil
            presentedPane = nil
        }

        Self.logger.debug("reconcile scene=\(self.scene != nil, privacy: .public) mode=\(ScreenSharingExternalDisplayMode.current.rawValue, privacy: .public) candidate=\(self.candidatePane != nil, privacy: .public) target=\(target != nil, privacy: .public)")
        guard let target, let scene, let window else {
            window?.rootViewController = nil
            window?.isHidden = true
            return
        }

        let size = ExternalDisplaySizing.requestedSize(
            for: scene.screen.bounds.size,
            scaleFactor: ScreenSharingExternalDisplayScale.current.factor)
        if target.session.externalDisplayViewSize != size {
            target.session.externalDisplayViewSize = size
        }
        if presentedPane !== target {
            presentedPane = target
            window.rootViewController = UIHostingController(
                rootView: ExternalDisplayRootView(pane: target))
        }
        window.isHidden = false
    }
}

/// External screen content: the session's desktop with the user's brightness
/// boost and cursor size, matching the device pane.
private struct ExternalDisplayRootView: View {
    @ObservedObject var pane: VNCPaneView
    @Bindable private var brightnessManager = BrightnessManager.shared
    @Setting(Settings.ScreenSharing.cursorSizeDefault) private var cursorSizeDefault

    var body: some View {
        ExternalDisplayDesktopView(
            session: pane.session,
            brightnessGain: brightnessManager.effectiveGain,
            cursorHeight: cursorSizeDefault.points)
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)
    }
}

/// Named for Info.plist's UISceneConfigurations, which iOS reads before it
/// decides to offer an external display scene instead of mirroring.
@objc(RootshellExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        var paneID: UUID?
        if #available(iOS 27.0, *) {
            paneID = (connectionOptions.sceneAccessoryUserInfo as? String).flatMap(UUID.init(uuidString:))
        }
        ExternalDisplayCoordinator.shared.sceneDidConnect(windowScene, accessoryPaneID: paneID)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayCoordinator.shared.sceneDidDisconnect(windowScene)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: any UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        ExternalDisplayCoordinator.shared.sceneGeometryDidChange(windowScene)
    }
}
#endif
