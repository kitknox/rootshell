//
//  LaunchReadiness.swift
//  rootshell
//
//  A launch that starts before first unlock reads empty defaults. Nothing
//  that caches settings (the terminal runtime, its managers, scene content)
//  is built until the unlock work in AppDelegate has primed them.
//

import SwiftUI
import os

@MainActor @Observable
final class LaunchReadiness {
    static let shared = LaunchReadiness()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LaunchReadiness")

    /// The process started while protected data was unavailable.
    let launchedLocked: Bool
    /// Shared terminal runtime; every `LaunchGate` opens once it exists.
    private(set) var ghosttyApp: Ghostty.App?
    @ObservationIgnored private var readyActions: [@MainActor () -> Void] = []
    @ObservationIgnored private var isOpening = false

    var isReady: Bool { ghosttyApp != nil }

    private init() {
        launchedLocked = !ProtectedDataGuard.isAvailable
        if launchedLocked {
            Self.logger.warning("Launched before protected data was available; holding scene content")
        } else {
            open()
        }
    }

    func whenReady(_ action: @escaping @MainActor () -> Void) {
        if isReady {
            action()
        } else {
            readyActions.append(action)
        }
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            whenReady { continuation.resume() }
        }
    }

    /// Called by the locked launch's unlock work once settings are primed.
    func markReady() {
        guard !isReady, !isOpening else { return }
        isOpening = true
        Task { @MainActor in
            // Don't swap scene content inside a foreground transition.
            var attempts = 0
            while ForegroundActivationGate.shared.isUnsafeForSceneMutation, attempts < 50 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Catches any manager something touched before unlock.
            BackupImporter.refreshAllManagers()
            open()
            Self.logger.info("Launch ready after unlock")
        }
    }

    private func open() {
        guard ghosttyApp == nil else { return }
        // Register the selected font before Ghostty surfaces use it (catalog loads on a worker).
        _ = FontManager.shared
        // Its notification observer must exist before any MainView posts.
        _ = RemoteSessionTracker.shared
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        _ = LiveActivityManager.shared
        #endif
        // Applies the correct theme on launch and starts observing appearance.
        _ = DayNightThemeManager.shared
        ghosttyApp = Ghostty.App()
        let actions = readyActions
        readyActions = []
        for action in actions {
            action()
        }
    }
}

/// Shows scene content only once the launch is ready.
struct LaunchGate<Content: View>: View {
    @ViewBuilder let content: (Ghostty.App) -> Content

    var body: some View {
        if let app = LaunchReadiness.shared.ghosttyApp {
            content(app)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Keeps `AppearanceManager` from being created before the launch is ready.
struct AppearanceColorSchemeModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceManager.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}
