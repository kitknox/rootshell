//
//  StatusBarStyleController.swift
//  rootshell
//
//  Adapts iOS status bar style based on terminal theme luminance,
//  independent of the UI appearance (light/dark mode) setting.
//

import SwiftUI
import UIKit
import Combine
import ObjectiveC

#if !targetEnvironment(macCatalyst) && !os(visionOS)

// MARK: - Status Bar Style Manager

/// Manages status bar style based on terminal theme luminance.
/// Uses method swizzling to override UIHostingController's preferredStatusBarStyle.
@MainActor
final class StatusBarStyleManager {
    static let shared = StatusBarStyleManager()

    private var themeSubscription: AnyCancellable?
    private var windowObserver: NSObjectProtocol?
    private var isInstalled = false

    /// Current status bar style based on terminal theme
    private(set) var currentStyle: UIStatusBarStyle = .default

    private init() {}

    /// Install status bar style management. Call early in app lifecycle.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Update style based on current theme
        updateCurrentStyle()

        // Subscribe to theme changes
        themeSubscription = ThemeManager.shared.themeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateCurrentStyle()
                self?.updateAllStatusBars()
            }

        // Observe window creation to swizzle hosting controllers
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? UIWindow else { return }
            Task { @MainActor in
                self.swizzleHostingControllerIfNeeded(for: window)
            }
        }

        // Swizzle any existing windows
        DispatchQueue.main.async { [weak self] in
            self?.swizzleExistingWindows()
        }
    }

    private func updateCurrentStyle() {
        let isLightTheme = ThemeManager.shared.currentThemeInfo?.isLight ?? false
        currentStyle = isLightTheme ? .darkContent : .lightContent
    }

    private func updateAllStatusBars() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isExternalDisplayPresentation {
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    private func swizzleExistingWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isExternalDisplayPresentation {
                swizzleHostingControllerIfNeeded(for: window)
            }
        }
    }

    private func swizzleHostingControllerIfNeeded(for window: UIWindow) {
        guard let rootVC = window.rootViewController else { return }
        swizzleIfHostingController(rootVC)
    }

    private func swizzleIfHostingController(_ viewController: UIViewController) {
        let className = NSStringFromClass(type(of: viewController))

        // Check if this is a UIHostingController (SwiftUI creates various subclasses)
        guard className.contains("UIHostingController") ||
              className.contains("HostingController") else {
            return
        }

        // Get the actual class of this instance
        let vcClass: AnyClass = type(of: viewController)

        // Check if already swizzled by looking for our marker
        let markerKey = UnsafeRawPointer(bitPattern: "StatusBarSwizzled".hashValue)!
        if objc_getAssociatedObject(vcClass, markerKey) != nil {
            return
        }

        // Mark as swizzled
        objc_setAssociatedObject(vcClass, markerKey, true, .OBJC_ASSOCIATION_RETAIN)

        // Swizzle preferredStatusBarStyle
        let originalSelector = #selector(getter: UIViewController.preferredStatusBarStyle)

        guard let originalMethod = class_getInstanceMethod(vcClass, originalSelector) else {
            return
        }

        // Create a new implementation that returns our managed style
        let newImplementation: @convention(block) (UIViewController) -> UIStatusBarStyle = { _ in
            return StatusBarStyleManager.shared.currentStyle
        }

        let newIMP = imp_implementationWithBlock(newImplementation)
        method_setImplementation(originalMethod, newIMP)

        // Trigger update
        viewController.setNeedsStatusBarAppearanceUpdate()
    }
}

// MARK: - View Modifier

/// View modifier that installs status bar style management
struct StatusBarStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                StatusBarStyleManager.shared.install()
            }
    }
}

extension View {
    /// Enables terminal theme-based status bar styling (iOS/iPadOS only).
    /// The status bar style follows the terminal theme's luminance,
    /// independent of the UI appearance setting.
    func statusBarStyleForTerminalTheme() -> some View {
        modifier(StatusBarStyleModifier())
    }
}

#else

// Mac Catalyst / visionOS: no-op (no status bar)
extension View {
    func statusBarStyleForTerminalTheme() -> some View {
        self
    }
}

#endif
