//
//  ExternalDisplaySceneDelegate.swift
//  rootshell
//
//  Scene delegate for the windowExternalDisplayNonInteractive role. Kept
//  intentionally thin: all state and window management lives in
//  ExternalDisplayManager. Declining to create a window (feature disabled)
//  leaves the system mirroring the device as before.
//

#if !targetEnvironment(macCatalyst)
import UIKit
import os.log

class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ExternalDisplay")

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene else { return }
        guard ExternalDisplaySettings.isEnabled else {
            Self.logger.info("External display connected but feature disabled; mirroring")
            return
        }
        Self.logger.info("External display scene connecting")
        ExternalDisplayManager.shared.handleExternalSceneConnected(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard scene.session.role == .windowExternalDisplayNonInteractive else { return }
        Self.logger.info("External display scene disconnected")
        ExternalDisplayManager.shared.handleExternalSceneDisconnected()
    }
}
#endif
