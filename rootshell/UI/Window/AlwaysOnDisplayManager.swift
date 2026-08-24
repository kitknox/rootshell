//
//  AlwaysOnDisplayManager.swift
//  rootshell
//
//  Global "Always On Display" toggle: while enabled, the system idle timer is
//  disabled so the screen never auto-locks or dims during long-running
//  terminal work (builds, SSH sessions, `tail -f`, monitoring).
//
//  iOS/iPadOS only:
//  - `UIApplication.isIdleTimerDisabled` is the correct API on native iOS/iPad.
//  - Mac Catalyst exposes the property but it is a no-op for Mac display sleep
//    (governed by power assertions, not the idle timer).
//  - visionOS has no traditional auto-lock idle timer (the headset sleeps when
//    removed), so the concept is not meaningful.
//  The whole file is gated to native iOS/iPad; the `#else` provides a no-op
//  modifier so the App body compiles unchanged on every platform.
//
//  Mirrors `PaddingManager` (@Observable singleton persisting to UserDefaults
//  with a synchronous `didSet`, bound into settings via @Bindable) and
//  `ImmersiveChromeManager` (single launch-time install + lifecycle re-apply).
//

import SwiftUI
import UIKit

#if !targetEnvironment(macCatalyst) && !os(visionOS)

@MainActor
@Observable
final class AlwaysOnDisplayManager {
    static let shared = AlwaysOnDisplayManager()

    private nonisolated static let storageKey = "alwaysOnDisplayEnabled"

    /// While true the system idle timer is disabled (screen stays awake).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
            apply() // synchronous -> instant effect
        }
    }

    private var isInstalled = false

    private init() {
        // didSet does NOT fire during init, so this does not apply early.
        // This is only an optimistic seed: on a locked/background launch where
        // protected data is unavailable, the read returns false. `install()`
        // re-reads the real value once protected data is available, so a
        // persisted "on" is never masked for the process lifetime.
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    /// Idempotent. Loads and applies the persisted state once protected data is
    /// available, then re-applies whenever the app becomes active.
    ///
    /// The persisted value is always re-read from `UserDefaults` (not the
    /// possibly-stale in-memory seed): a locked/background launch can make
    /// `UserDefaults` read as false, which would otherwise mask a persisted
    /// "on" for the whole process. `isIdleTimerDisabled` also resets to false on
    /// a fresh launch, so re-applying on `didBecomeActive` keeps state robust.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        ProtectedDataGuard.whenAvailable {
            AlwaysOnDisplayManager.shared.reloadAndApply()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AlwaysOnDisplayManager.shared.reloadAndApply()
            }
        }
        // Auto-lock tears down the external presentation, so an active
        // external session holds the idle timer too.
        for name in [Notification.Name.externalDisplayDidConnect, .externalDisplayDidDisconnect] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AlwaysOnDisplayManager.shared.apply()
                }
            }
        }
    }

    /// Re-read the persisted setting (protected data assumed available here) and
    /// apply it to the system idle timer.
    private func reloadAndApply() {
        let persisted = UserDefaults.standard.bool(forKey: Self.storageKey)
        if persisted != isEnabled {
            isEnabled = persisted // didSet persists (no-op, same value) + applies
        } else {
            apply()
        }
    }

    private func apply() {
        UIApplication.shared.isIdleTimerDisabled =
            isEnabled || ExternalDisplayManager.shared.isExternalSessionActive
    }
}

// MARK: - Install hook

private struct AlwaysOnDisplayInstallModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            AlwaysOnDisplayManager.shared.install()
        }
    }
}

extension View {
    /// Installs the always-on-display manager on the first appearance.
    /// Idempotent. No-op on Mac Catalyst / visionOS.
    func alwaysOnDisplay() -> some View {
        modifier(AlwaysOnDisplayInstallModifier())
    }
}

#else

// Mac Catalyst / visionOS: no meaningful idle timer to control.
extension View {
    func alwaysOnDisplay() -> some View {
        self
    }
}

#endif
