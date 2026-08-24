//
//  DayNightThemeManager.swift
//  rootshell
//
//  Manages automatic theme switching based on system light/dark mode.
//

import Combine
import Foundation
import os
import UIKit

/// Manages automatic day/night theme switching based on system appearance
@MainActor
final class DayNightThemeManager: ObservableObject {
    static let shared = DayNightThemeManager()

    // MARK: - UserDefaults Keys

    private static let enabledKey = "dayNightThemeEnabled"
    private static let dayThemeKey = "dayNightThemeDayTheme"
    private static let nightThemeKey = "dayNightThemeNightTheme"
    private static let defaultThemeKey = "dayNightThemeDefaultTheme"

    // MARK: - Published Properties

    /// Whether day/night theme switching is enabled
    @Published var enabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            handleEnabledChange(wasEnabled: oldValue)
        }
    }

    /// Theme to use during light mode
    @Published var dayTheme: String {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(dayTheme, forKey: Self.dayThemeKey)
            if enabled {
                applyCurrentTheme()
            }
        }
    }

    /// Theme to use during dark mode
    @Published var nightTheme: String {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(nightTheme, forKey: Self.nightThemeKey)
            if enabled {
                applyCurrentTheme()
            }
        }
    }

    /// Whether the system is currently in light mode
    @Published private(set) var isCurrentlyLight: Bool = true

    // MARK: - Private Properties

    /// Theme to revert to when feature is disabled
    private var defaultTheme: String

    /// Hidden UIView used to observe trait changes
    private var traitObserverView: TraitObserverView?

    /// Notification observer for scene activation (retry attaching observer)
    private var sceneActivationObserver: NSObjectProtocol?

    /// Notification observer for window becoming key (reliable window availability)
    private var windowBecameKeyObserver: NSObjectProtocol?

    /// Whether the initial theme has been applied with a real window
    private var hasAppliedInitialTheme = false

    private static let logger = Logger(subsystem: "com.rootshell", category: "DayNightTheme")

    // MARK: - Initialization

    private init() {
        // Load saved settings
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.dayTheme = UserDefaults.standard.string(forKey: Self.dayThemeKey) ?? "Solarized Light"
        self.nightTheme = UserDefaults.standard.string(forKey: Self.nightThemeKey) ?? "Catppuccin Mocha"
        self.defaultTheme = UserDefaults.standard.string(forKey: Self.defaultThemeKey)
            ?? ThemeManager.shared.currentTheme

        // Try to read current system appearance — may be unreliable before windows exist
        isCurrentlyLight = Self.currentInterfaceStyleIsLight()

        setupNotifications()

        if enabled {
            setupTraitObserver()
            applyCurrentTheme()
        }
    }

    // MARK: - Static Helpers

    /// Reads the current interface style, trying multiple sources for reliability.
    /// At app launch time, key window may not exist yet, so we also try the
    /// window scene's traitCollection directly.
    static func currentInterfaceStyleIsLight() -> Bool {
        // Try key window first (most reliable when available)
        if let windowScene = UIApplication.shared.deviceForegroundWindowScene {
            // Try key window
            if let keyWindow = windowScene.keyWindow {
                return keyWindow.traitCollection.userInterfaceStyle != .dark
            }
            // Try any window in the scene
            if let anyWindow = windowScene.windows.first {
                return anyWindow.traitCollection.userInterfaceStyle != .dark
            }
            // Try the scene's own trait collection
            let sceneStyle = windowScene.traitCollection.userInterfaceStyle
            if sceneStyle != .unspecified {
                return sceneStyle != .dark
            }
        }
        // Treat .unspecified as light (no window/scene available yet)
        return true
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        // Handle app returning to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.handleForegroundReturn()
            }
        }
    }

    private func handleEnabledChange(wasEnabled: Bool) {
        if enabled && !wasEnabled {
            // Feature was just enabled — capture current theme for reversion
            defaultTheme = ThemeManager.shared.currentTheme
            UserDefaults.standard.set(defaultTheme, forKey: Self.defaultThemeKey)

            isCurrentlyLight = Self.currentInterfaceStyleIsLight()
            setupTraitObserver()
            applyCurrentTheme()
        } else if !enabled && wasEnabled {
            // Feature was just disabled
            teardownTraitObserver()

            // Revert to default theme
            Self.logger.info("Reverting to default theme: \(self.defaultTheme)")
            ThemeManager.shared.currentTheme = defaultTheme
        }
    }

    /// Re-check the system appearance and apply the correct theme if needed.
    /// Call this once the UI is fully loaded and the window exists, to fix
    /// any stale state from init() where no window was available.
    func recheckAppearance() {
        guard enabled else { return }

        let nowLight = Self.currentInterfaceStyleIsLight()
        if nowLight != isCurrentlyLight {
            Self.logger.info("recheckAppearance: correcting to \(nowLight ? "light" : "dark")")
            isCurrentlyLight = nowLight
        }
        // Force-apply even if isCurrentlyLight didn't change, because the
        // initial apply during init() may have fired before Ghostty.App
        // subscribed to themeDidChange.
        let theme = isCurrentlyLight ? dayTheme : nightTheme
        if ThemeManager.shared.currentTheme != theme {
            Self.logger.info("recheckAppearance: applying \(theme)")
            ThemeManager.shared.currentTheme = theme
        }
    }

    private func applyCurrentTheme() {
        guard enabled else { return }

        let theme = isCurrentlyLight ? dayTheme : nightTheme

        if ThemeManager.shared.currentTheme != theme {
            let mode = isCurrentlyLight ? "light" : "dark"
            Self.logger.info("Applying \(mode) theme: \(theme)")
            ThemeManager.shared.currentTheme = theme
        }
    }

    private func handleForegroundReturn() {
        guard enabled else { return }

        Self.logger.info("App returned to foreground, verifying theme state")

        let nowLight = Self.currentInterfaceStyleIsLight()
        if nowLight != isCurrentlyLight {
            Self.logger.info("System appearance changed while backgrounded, correcting")
            isCurrentlyLight = nowLight
            applyCurrentTheme()
        }
    }

    // MARK: - Trait Observer

    private func setupTraitObserver() {
        guard traitObserverView == nil else { return }

        if let window = Self.keyWindow() {
            attachTraitObserver(to: window)
        } else {
            // Window not ready yet — listen for both scene activation and window
            // becoming key. UIScene.didActivateNotification may fire before keyWindow
            // is set; UIWindow.didBecomeKeyNotification guarantees a usable window.
            sceneActivationObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let strongSelf = self else { return }
                Task { @MainActor in
                    strongSelf.retryTraitObserverAttachment()
                }
            }

            windowBecameKeyObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let strongSelf = self else { return }
                // Delivered on .main; the hop below just re-enters MainActor.
                nonisolated(unsafe) let notification = notification
                Task { @MainActor in
                    strongSelf.handleWindowBecameKey(notification)
                }
            }
        }
    }

    private func handleWindowBecameKey(_ notification: Notification) {
        guard traitObserverView == nil, enabled else { return }

        // Use the window from the notification directly — guaranteed to be available
        if let window = notification.object as? UIWindow {
            attachTraitObserver(to: window)
            cleanupPendingObservers()
        }
    }

    private func retryTraitObserverAttachment() {
        guard traitObserverView == nil, enabled else { return }

        if let window = Self.keyWindow() {
            attachTraitObserver(to: window)
            cleanupPendingObservers()
        }
    }

    /// Remove one-shot observers used to wait for window availability
    private func cleanupPendingObservers() {
        if let observer = sceneActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            sceneActivationObserver = nil
        }
        if let observer = windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowBecameKeyObserver = nil
        }
    }

    private func attachTraitObserver(to window: UIWindow) {
        let observer = TraitObserverView { [weak self] isLight in
            guard let self else { return }
            guard self.isCurrentlyLight != isLight else { return }
            Self.logger.info("System appearance changed to \(isLight ? "light" : "dark")")
            self.isCurrentlyLight = isLight
            self.applyCurrentTheme()
        }
        observer.isHidden = true
        observer.frame = .zero
        window.addSubview(observer)
        traitObserverView = observer

        // Now that we have a real window, re-check the actual interface style.
        // During init(), the window may not have existed yet, causing
        // isCurrentlyLight to default to true (light). Correct it now.
        let actuallyLight = window.traitCollection.userInterfaceStyle != .dark
        if actuallyLight != isCurrentlyLight {
            Self.logger.info("Correcting initial appearance to \(actuallyLight ? "light" : "dark")")
            isCurrentlyLight = actuallyLight
        }
        // Always apply on first window attachment to ensure Ghostty surfaces
        // (which may have been created with a stale theme) get updated.
        // ThemeManager.currentTheme setter is idempotent if theme matches.
        if !hasAppliedInitialTheme {
            hasAppliedInitialTheme = true
            let theme = isCurrentlyLight ? dayTheme : nightTheme
            let mode = isCurrentlyLight ? "light" : "dark"
            Self.logger.info("Initial window theme apply: \(mode) → \(theme)")
            // Force-set even if ThemeManager already has this theme name,
            // because Ghostty.App may not have been subscribed when it was
            // first set during init().
            ThemeManager.shared.currentTheme = theme
            ThemeManager.shared.themeDidChange.send(theme)
        }
    }

    private func teardownTraitObserver() {
        traitObserverView?.removeFromSuperview()
        traitObserverView = nil
        cleanupPendingObservers()
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.deviceKeyWindow
    }
}

// MARK: - TraitObserverView

/// Hidden UIView that observes system interface style changes via `registerForTraitChanges`.
private final class TraitObserverView: UIView {
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TraitObserverView, _: UITraitCollection) in
            let isLight = self.traitCollection.userInterfaceStyle != .dark
            self.onChange(isLight)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
