//
//  ProtectedDataGuard.swift
//  rootshell
//
//  Guards against reading/writing UserDefaults before the device is unlocked.
//  On iPadOS 26+, background launches (VPN, Live Activities, CloudKit push)
//  can start the app process before protected data is available, causing
//  UserDefaults to return empty values and overwrite real settings.
//

import UIKit
import os.log

enum ProtectedDataGuard {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ProtectedDataGuard")
    private nonisolated static let protectedDataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.rootshell.protectedDataGuard"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Deferred actions in registration order; kept until a drain finds protected data available.
    @MainActor private static var pending: [@MainActor @Sendable () -> Void] = []
    @MainActor private static var observers: [NSObjectProtocol] = []
    @MainActor private static var isDraining = false
    @MainActor private static var domainConfirmed = false

    /// Whether the device is unlocked and protected data (including UserDefaults) is readable.
    @MainActor
    static var isAvailable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }

    /// Runs `action` once protected data is available.
    ///
    /// This is intentionally not gated on foreground activation: protected-data
    /// work such as migrations, push registration, and CloudKit maintenance must
    /// still run during background launches/unlocks.
    @MainActor
    static func whenAvailable(_ action: @MainActor @escaping @Sendable () -> Void) {
        if isAvailable && pending.isEmpty {
            runWhenProtectedDataAvailable(action, reason: "available")
            return
        }
        if pending.isEmpty {
            logger.warning("Protected data NOT available — deferring initialization")
        }
        pending.append(action)
        installObserversIfNeeded()
        // Data may already be back with no trigger yet; never run inline in the caller.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { scheduleDrain(reason: "enqueue") }
        }
    }

    /// Suspends until protected data is available.
    @MainActor
    static func waitUntilAvailable() async {
        if isAvailable && pending.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            whenAvailable { continuation.resume() }
        }
    }

    /// A suspended process can miss the unlock notification, so foreground transitions drain too.
    @MainActor
    private static func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let triggers: [(Notification.Name, String)] = [
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlock"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
        ]
        for (name, reason) in triggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: protectedDataQueue) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { scheduleDrain(reason: reason) }
                }
            })
        }
    }

    @MainActor
    private static func scheduleDrain(reason: String) {
        guard !pending.isEmpty, !isDraining else { return }
        guard isAvailable else {
            if reason != "enqueue" {
                let count = pending.count
                logger.warning("\(reason, privacy: .public) fired but protected data is unavailable; keeping \(count) deferred actions")
            }
            return
        }
        if !domainConfirmed {
            // Defaults can still read empty just after unlock; deferred work must not see that.
            isDraining = true
            Task { @MainActor in
                await UserDefaultsBackup.waitForReadableDomain()
                domainConfirmed = true
                isDraining = false
                scheduleDrain(reason: reason)
            }
            return
        }
        let actions = pending
        pending = []
        logger.info("Protected data available (\(reason, privacy: .public)); running \(actions.count) deferred actions")
        LifecycleDebugLogger.shared.checkpoint("ProtectedData.run", ms: nil, [
            ("reason", reason),
            ("actions", actions.count),
            ("appState", String(describing: UIApplication.shared.applicationState)),
        ])
        for action in actions {
            action()
        }
    }

    @MainActor
    private static func runWhenProtectedDataAvailable(
        _ action: @MainActor @escaping @Sendable () -> Void,
        reason: String
    ) {
        logger.info("Protected data available")

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LifecycleDebugLogger.shared.checkpoint("ProtectedData.run", ms: nil, [
                    ("reason", reason),
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
                action()
            }
        }
    }
}
