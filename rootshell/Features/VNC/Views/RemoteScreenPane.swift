//
//  RemoteScreenPane.swift
//  rootshell
//
//  What MainView, the full-screen takeover, the keyboard toolbar and the
//  brightness HUD need from a remote-screen pane, so Screen Sharing and
//  KVM panes share them.
//

import Combine
import SwiftUI
import UIKit
import rootshellVNC

@MainActor
protocol RemoteScreenPane: SplitPaneView {
    var windowId: String { get }
    var sourceProfileID: UUID? { get }
    var userOverrideTitle: String? { get set }
    /// Fallback title and overlay subtitle.
    var paneDisplayName: String { get }
    var connectionConfig: ConnectionConfig { get }
    var connectionInfo: ConnectionInfo? { get }
    /// Emits the current title, then every change.
    var displayTitlePublisher: AnyPublisher<String, Never> { get }

    /// The full-screen takeover's failure card text, or nil when the pane
    /// shows its own recovery prompt. Observable through `withObservationTracking`.
    var fullScreenFailureMessage: String? { get }
    /// A failure before the session started, which the session state never shows.
    var launchErrorMessage: String? { get }
    var wantsBackgroundKeepaliveGrace: Bool { get }
    func resumePresentationAfterForeground()
    func nudgeRetryAfterForeground()
    func retryLaunch()
    func retryRemoteConnection()
    func cancelFailedConnection()

    var keyboardCapture: VNCKeyboardCapture { get }
    var keyboardCoordinator: VNCKeyboardAccessoryCoordinator? { get }
    var effectiveKeyboardToolbarPreference: VNCConnectionConfig.KeyboardToolbarPreference { get }
    var usesAppleModifierConvention: Bool { get }
    func captureKeyboard()
    func sendKeyboardToolbarKeysym(down: Bool, keysym: UInt32)
    func pasteFromKeyboardToolbar()
    @discardableResult
    func routeReservedKeyboardShortcutToVNC(_ shortcut: VNCReservedKeyboardShortcut) -> Bool

    var fullScreenController: PaneFullScreenController? { get set }
    func fullScreenDidEnter()
    func fullScreenDidSuspendForTabChange()
    func rehostHostingController(under parent: UIViewController)
    func rehostHostingControllerToCurrentAncestor()

    var brightnessHUDHost: UIHostingController<BrightnessBoostHUDView>? { get set }
    var brightnessHUDHideTask: Task<Void, Never>? { get set }
}

extension RemoteScreenPane {
    /// Chord for a rootshell-reserved shortcut sent to the remote computer.
    static func reservedShortcutChord(
        _ shortcut: VNCReservedKeyboardShortcut
    ) -> (key: Character, modifiers: VNCKeyboardModifiers) {
        switch shortcut {
        case .toggleTabSwitcher: ("\\", [.command, .shift])
        case .openSettings: (",", [.command])
        case .previousTab: ("[", [.command, .shift])
        case .nextTab: ("]", [.command, .shift])
        }
    }
}
