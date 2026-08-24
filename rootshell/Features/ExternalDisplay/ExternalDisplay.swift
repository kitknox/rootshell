//
//  ExternalDisplay.swift
//  rootshell
//
//  Shared declarations for external (non-interactive) display support.
//  Compiled on every platform: keybind actions and window/scene enumerators
//  reference these even where the feature itself is absent (Catalyst).
//

import Foundation
import UIKit

enum ExternalDisplay {
    /// Synthetic windowId of the MainView hosted on the external display.
    static let windowId = "external"
}

extension Notification.Name {
    static let externalDisplayDidConnect = Notification.Name("com.rootshell.externalDisplayDidConnect")
    static let externalDisplayDidDisconnect = Notification.Name("com.rootshell.externalDisplayDidDisconnect")
    static let externalDisplayFocusChanged = Notification.Name("com.rootshell.externalDisplayFocusChanged")
    static let toggleExternalDisplayFocus = Notification.Name("com.rootshell.toggleExternalDisplayFocus")
    static let moveTabToExternalDisplay = Notification.Name("com.rootshell.moveTabToExternalDisplay")
}

extension UIScene {
    var isExternalDisplayScene: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return session.role == .windowExternalDisplayNonInteractive
        #endif
    }
}

extension Notification {
    /// True when `object` is the external display's scene.
    var isFromExternalDisplayScene: Bool {
        (object as? UIScene)?.isExternalDisplayScene ?? false
    }
}

@MainActor
extension UIApplication {
    /// Connected scenes hosting regular device UI (excludes the external
    /// non-interactive scene). Every "count the windows" / "find the visible
    /// window" heuristic must use this instead of `connectedScenes`.
    var deviceWindowScenes: [UIWindowScene] {
        connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
    }

    var externalDisplayScene: UIWindowScene? {
        connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.isExternalDisplayScene }
    }

    /// First foregroundActive device scene, else foregroundInactive, else any.
    var deviceForegroundWindowScene: UIWindowScene? {
        let scenes = deviceWindowScenes
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    /// Key window among device scenes, else the foreground device scene's
    /// first non-external-presentation window.
    var deviceKeyWindow: UIWindow? {
        let scenes = deviceWindowScenes
        if let key = scenes.lazy.flatMap(\.windows).first(where: { $0.isKeyWindow && !$0.isExternalDisplayPresentation }) {
            return key
        }
        return deviceForegroundWindowScene?.windows.first { !$0.isExternalDisplayPresentation }
    }
}

extension UIWindow {
    /// Windows that host or present external-display content (the external
    /// window and the control-mode surface). Invisible to device-side focus
    /// and keyboard-geometry heuristics.
    var isExternalDisplayPresentation: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return self is ExternalWindow || self is ControlSurfaceWindow
        #endif
    }

    /// Host view for window-level overlays (tab sidebar, side panels). For
    /// external-presentation windows this is the zoomed content view so the
    /// overlay scales with the workspace; otherwise the window itself.
    var overlayInstallHostView: UIView {
        #if targetEnvironment(macCatalyst)
        return self
        #else
        if isExternalDisplayPresentation,
           let content = (rootViewController as? ExternalZoomContainerController)?.contentView {
            return content
        }
        return self
        #endif
    }
}

extension MainView {
    var isExternalDisplayWindow: Bool { windowId == ExternalDisplay.windowId }
}

extension Ghostty.TerminalView {
    /// Content flag: true for terminals belonging to the external MainView
    /// regardless of which window currently hosts them (parked or control mode).
    var isExternalDisplayTerminal: Bool { windowId == ExternalDisplay.windowId }
}
