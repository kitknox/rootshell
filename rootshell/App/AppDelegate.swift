//
//  AppDelegate.swift
//  rootshell
//
//  Base AppDelegate for handling remote notifications (CloudKit push)
//  and app lifecycle events. CatalystAppDelegate inherits from this.
//

import AppIntents
import AVFoundation
import UIKit
import os.log
import rootshellVNC

class AppDelegate: UIResponder, UIApplicationDelegate {
    private static let logger = Logger(subsystem: "com.rootshell", category: "AppDelegate")
    private let protectedDataNotificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.rootshell.appDelegate.protectedData"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Capture any wedge tombstone from the previous run BEFORE any
        // checkpoints from this session can grow the file past the rotation
        // size. The scanner only reads ~4KB so it's safe to call here.
        let priorTombstone = LifecycleDebugLogger.shared.scanPreviousSessionTermination()
        WedgeBreadcrumbLogger.shared.critical("APP.launch", [
            ("protectedData", UIApplication.shared.isProtectedDataAvailable),
            ("appState", String(describing: UIApplication.shared.applicationState)),
            ("backgroundLaunch", UIApplication.shared.applicationState == .background),
        ])
        ForegroundWedgeWatchdog.shared.noteMainActorServiced("AppDelegate.launch")
        LifecycleDebugLogger.shared.logMarker("APP LAUNCH")
        TmuxDebugLogger.shared.marker("APP LAUNCH")
        LifecycleDebugLogger.shared.checkpoint("APP.launch", ms: nil, [
            ("protectedData", UIApplication.shared.isProtectedDataAvailable),
            ("backgroundLaunch", UIApplication.shared.applicationState == .background),
        ])
        if let tombstone = priorTombstone {
            LifecycleDebugLogger.shared.log("[!] PREVIOUS SESSION TERMINATED AFTER: \(tombstone)")
        }

        // Capture the main thread's mach port before installing lifecycle
        // observers — the foreground transition watchdog drives the sampler
        // and must have a valid port the first time it arms.
        MainThreadStackSampler.installOnMainThread()

        // Register volatile UserDefaults defaults BEFORE any scene/view construction.
        // This is safe before unlock — `register(defaults:)` only writes to the volatile
        // registration domain and never touches disk. The persistent migration below
        // stays inside the protected-data gate where it belongs.
        UserDefaultsMigration.registerVolatileDefaults()

        installLifecycleObservers()

        // Register the keyboard-window visibility observer before the first
        // keyboard appearance so toolbar keys can read the system Shift state.
        SystemShiftReader.shared.activate()

        // Wire NIOSSH internals + swift-log (Citadel) into SSHDebugLogger.
        // Bootstraps run once per process; handlers consult the toggle at
        // write time, so flipping the toggle takes effect immediately.
        SSHDebugLogger.shared.installLibraryBridgesIfNeeded()

        // Mirror the rootshellVNC package's log stream into
        // .ghostty/vnc_debug.log. Same contract: installed once, the sink
        // checks the toggle per record.
        VNCDebugLogger.shared.installPackageBridgeIfNeeded()
        VNCDebugLogger.shared.logMarker("APP LAUNCH")

        // Delivery-time backstop for VNC frame presentation: the package
        // checks this before committing decoded frames to its display layer,
        // covering panes created while the device is locked and any pause
        // sweep miss (secure-mode snapshot protection).
        VNCPresentationPolicy.isPresentationProhibited = {
            Ghostty.isSecureDrawProhibitedAtomic
        }

        // Configure audio session to not interrupt other apps' audio.
        // Use .playback category with .mixWithOthers option - this is the pattern used by
        // Twitter/X for video previews and is more reliable than .ambient for video playback.
        // This must be configured BEFORE any AVPlayer is created.
        // (No UserDefaults dependency — safe to run before unlock.)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.logger.warning("Failed to configure audio session: \(error.localizedDescription)")
        }

        SettingsRegistry.shared.assertInvariants()

        // All UserDefaults-dependent initialization must wait until the device is unlocked.
        // Background launches (VPN reconnect, Live Activities, CloudKit push) can start
        // the app process before protected data is available, causing UserDefaults to return
        // empty values and permanently overwrite real settings.
        ProtectedDataGuard.whenAvailable {
            UserDefaultsBackup.detectAndRecover()
            UserDefaultsMigration.migrateIfNeeded()
            SettingsStore.shared.bootstrap()
            SettingsSyncCoordinator.shared.start()
            ConfigOverlayManager.shared.start()
            // Interim until every manager registers its own reload(keys:).
            SettingsRefreshHub.shared.register(
                groups: [.theme, .font, .cursor, .transparency, .selection, .sounds, .notifications]
            ) { _ in BackupImporter.refreshAllManagers() }
            RootshellShortcuts.updateAppShortcutParameters()
            application.registerForRemoteNotifications()
            // Instantiate eagerly so the battery / Low Power Mode / thermal /
            // activation observers are live from launch rather than from
            // whenever the first surface reads the frame-rate range. Inside
            // the gate because init reads the persisted refresh settings.
            _ = PowerManager.shared
            Task { @MainActor in
                await CloudKitSyncManager.shared.logDiagnostics()
                await CloudKitSyncManager.shared.revalidateSubscriptionsIfNeeded()
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Encrypted hook push. The extension normally decrypts before display;
        // this is the fallback for a raw payload reaching the app undecorated.
        if userInfo["rs"] != nil {
            Task { @MainActor in
                await PushNotificationRouter.handleRemote(userInfo: userInfo)
                completionHandler(.noData)
            }
            return
        }

        // Best-effort deferral: if the process survives until unlock, the observer
        // fires and we sync immediately. If iOS kills the process first, the observer
        // is lost — but RootShellApp.onChange(scenePhase: .active) calls syncNow()
        // whenever the user next foregrounds the app, so changes are still picked up.
        guard ProtectedDataGuard.isAvailable else {
            Self.logger.warning("CloudKit push received while locked — deferring sync until unlock")
            ProtectedDataGuard.whenAvailable {
                Self.logger.info("Processing deferred CloudKit push after unlock")
                Task { @MainActor in
                    await CloudKitSyncManager.shared.handleRemoteNotification()
                }
            }
            completionHandler(.noData)
            return
        }

        Self.logger.info("Received remote notification for CloudKit sync")

        Task { @MainActor in
            await CloudKitSyncManager.shared.handleRemoteNotification()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.logger.info("Registered for remote notifications")
        PushRegistrationManager.shared.didReceiveAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.logger.warning("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    /// Subscribe to OS notifications that may correlate with watchdog wedges:
    /// Keychain availability transitions, memory warnings, and termination.
    /// Each observer logs a single checkpoint to the lifecycle log so the
    /// post-mortem trace shows whether one of these events landed inside a
    /// scene-update transaction.
    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { _ in
            ForegroundActivationGate.shared.markWillEnterForeground(
                appState: String(describing: UIApplication.shared.applicationState)
            )
            WedgeBreadcrumbLogger.shared.critical("UIKit.willEnterForeground.begin")
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundTransitionWatchdog.shared.arm(appState: appState)
            ForegroundWedgeWatchdog.shared.noteForegroundNotification("willEnterForeground", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.willEnterForeground.afterWatchdogArm", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.willEnterForeground", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.willEnterForeground.beforeLifecycleDebug", [
                ("appState", appState),
            ])
            LifecycleDebugLogger.shared.checkpoint("UIKit.willEnterForeground", ms: nil, [
                ("appState", appState),
            ])
            VNCDebugLogger.shared.lifecycle("willEnterForeground", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.willEnterForeground.end", [
                ("appState", appState),
            ])
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            WedgeBreadcrumbLogger.shared.critical("UIKit.didBecomeActive.begin")
            Ghostty.isSecureDrawProhibitedAtomic = false
            PreviewRenderingLifecycle.scheduleResumeAfterActivation()
            LifecycleDebugLogger.shared.checkpoint("SECURE.latch.clear")
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundActivationGate.shared.markDidBecomeActive(appState: appState)
            ForegroundTransitionWatchdog.shared.disarm(reason: "didBecomeActive", appState: appState)
            ForegroundWedgeWatchdog.shared.noteForegroundNotification("didBecomeActive", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.didBecomeActive.afterWatchdogArm", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.didBecomeActive", [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.didBecomeActive.beforeLifecycleDebug", [
                ("appState", appState),
            ])
            LifecycleDebugLogger.shared.checkpoint("UIKit.didBecomeActive", ms: nil, [
                ("appState", appState),
            ])
            WedgeBreadcrumbLogger.shared.critical("UIKit.didBecomeActive.end", [
                ("appState", appState),
            ])
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification,
                       object: nil, queue: .main) { _ in
            Ghostty.isSecureDrawProhibitedAtomic = true
            PreviewRenderingLifecycle.suspend()
            LifecycleDebugLogger.shared.checkpoint("SECURE.latch.arm", ms: nil, [
                ("trigger", "willResignActive"),
            ])
            let appState = String(describing: UIApplication.shared.applicationState)
            WedgeBreadcrumbLogger.shared.critical("UIKit.willResignActive", [
                ("appState", appState),
            ])
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { _ in
            Ghostty.isSecureDrawProhibitedAtomic = true
            PreviewRenderingLifecycle.didEnterBackground()
            LifecycleDebugLogger.shared.checkpoint("SECURE.latch.arm", ms: nil, [
                ("trigger", "didEnterBackground"),
            ])
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundActivationGate.shared.markDidEnterBackground(appState: appState)
            ForegroundTransitionWatchdog.shared.disarm(reason: "didEnterBackground", appState: appState)
            WedgeBreadcrumbLogger.shared.critical("UIKit.didEnterBackground", [
                ("appState", appState),
            ])
            VNCDebugLogger.shared.lifecycle("didEnterBackground", [
                ("appState", appState),
                ("bgTimeRemaining", String(
                    format: "%.0fs", UIApplication.shared.backgroundTimeRemaining)),
            ])
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                       object: nil, queue: .main) { _ in
            // A lock that reaches us here rather than via willResignActive must
            // still close the secure-draw gate.
            Ghostty.isSecureDrawProhibitedAtomic = true
            PreviewRenderingLifecycle.suspend()
            LifecycleDebugLogger.shared.checkpoint("SECURE.latch.arm", ms: nil, [
                ("trigger", "protectedDataWillBecomeUnavailable"),
            ])
            LifecycleDebugLogger.shared.checkpoint("OS.protectedData.willBecomeUnavailable")
            VNCDebugLogger.shared.lifecycle("protectedDataWillBecomeUnavailable")
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                       object: nil, queue: protectedDataNotificationQueue) { _ in
            Task { @MainActor in
                LifecycleDebugLogger.shared.checkpoint("OS.protectedData.didBecomeAvailable", ms: nil, [
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
            }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                       object: nil, queue: .main) { _ in
            LifecycleDebugLogger.shared.checkpoint("OS.memoryWarning", ms: nil, [
                ("appState", String(describing: UIApplication.shared.applicationState)),
            ])
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification,
                       object: nil, queue: .main) { _ in
            LifecycleDebugLogger.shared.checkpoint("APP.terminate")
            LifecycleDebugLogger.shared.logMarker("APP TERMINATE")
        }
    }
}

final class ForegroundActivationGate: Sendable {
    nonisolated static let shared = ForegroundActivationGate()

    enum TimeoutPolicy: Sendable, Equatable {
        case drop
        case fireIfNotBackgrounded
    }

    private struct State: Sendable {
        var nextToken: UInt64 = 0
        var activeToken: UInt64 = 0
        var settlingUntil: TimeInterval = 0
        var lastEvent: String = "initial"
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private nonisolated static let defaultSettlingDelay: TimeInterval = 0
    private nonisolated static let retryDelay: TimeInterval = 0.02
    private nonisolated static let maxRetryAttempts = 800

    private init() {}

    nonisolated var isUnsafeForSceneMutation: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return state.withLock { state in
            state.activeToken != 0 || now < state.settlingUntil
        }
    }

    nonisolated func diagnosticFields() -> [(String, Any)] {
        let now = Date().timeIntervalSinceReferenceDate
        return state.withLock { state in
            [
                ("activationGateUnsafe", state.activeToken != 0 || now < state.settlingUntil),
                ("activationToken", state.activeToken),
                ("activationLastEvent", state.lastEvent),
                ("activationSettlingMs", max(0, (state.settlingUntil - now) * 1000)),
            ]
        }
    }

    nonisolated func markWillEnterForeground(appState: String) {
        // This observer is installed early, but NotificationCenter ordering is
        // still registration-order. Callers should not rely on this being armed
        // for synchronous work inside their own willEnterForeground observer;
        // hop/defer through runWhenSafe before mutating scene/UI state.
        let token = state.withLock { state -> UInt64 in
            state.nextToken &+= 1
            state.activeToken = state.nextToken
            state.settlingUntil = .greatestFiniteMagnitude
            state.lastEvent = "willEnterForeground"
            return state.activeToken
        }

        LifecycleDebugLogger.shared.checkpoint("FG.activationGate.armed", ms: nil, [
            ("token", token),
            ("appState", appState),
        ])
        WedgeBreadcrumbLogger.shared.critical("FG.activationGate.armed", [
            ("token", token),
            ("appState", appState),
        ])
    }

    nonisolated func markDidBecomeActive(
        appState: String,
        settlingDelay: TimeInterval = defaultSettlingDelay
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        let token = state.withLock { state -> UInt64 in
            if state.activeToken == 0 {
                state.nextToken &+= 1
                state.activeToken = state.nextToken
            }
            state.settlingUntil = now + settlingDelay
            state.lastEvent = "didBecomeActive.settling"
            return state.activeToken
        }

        LifecycleDebugLogger.shared.checkpoint("FG.activationGate.settling", ms: nil, [
            ("token", token),
            ("delayMs", String(format: "%.0f", settlingDelay * 1000)),
            ("appState", appState),
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + settlingDelay) { [self] in
            clearIfSettled(token: token, appState: String(describing: UIApplication.shared.applicationState))
        }
    }

    nonisolated func markDidEnterBackground(appState: String) {
        let token = state.withLock { state -> UInt64 in
            let token = state.activeToken
            state.activeToken = 0
            state.settlingUntil = 0
            state.lastEvent = "didEnterBackground"
            return token
        }

        LifecycleDebugLogger.shared.checkpoint("FG.activationGate.reset", ms: nil, [
            ("token", token),
            ("appState", appState),
        ])
    }

    @MainActor
    func runWhenSafe(
        reason: String,
        delay: TimeInterval = retryDelay,
        timeoutPolicy: TimeoutPolicy = .drop,
        _ block: @MainActor @escaping () -> Void
    ) {
        runWhenSafe(reason: reason, delay: delay, timeoutPolicy: timeoutPolicy, attempt: 0, block)
    }

    @MainActor
    private func runWhenSafe(
        reason: String,
        delay: TimeInterval,
        timeoutPolicy: TimeoutPolicy,
        attempt: Int,
        _ block: @MainActor @escaping () -> Void
    ) {
        guard isUnsafeForSceneMutation || UIApplication.shared.applicationState != .active else {
            if attempt > 0 {
                LifecycleDebugLogger.shared.checkpoint("FG.activationGate.deferredFire", ms: nil, [
                    ("reason", reason),
                    ("attempt", attempt),
                ])
            }
            block()
            return
        }

        if attempt == 0 {
            LifecycleDebugLogger.shared.checkpoint("FG.activationGate.deferred", ms: nil, [
                ("reason", reason),
                ("appState", String(describing: UIApplication.shared.applicationState)),
            ])
        }

        guard attempt < Self.maxRetryAttempts else {
            LifecycleDebugLogger.shared.checkpoint("FG.activationGate.deferredGaveUp", ms: nil, [
                ("reason", reason),
                ("appState", String(describing: UIApplication.shared.applicationState)),
                ("timeoutPolicy", String(describing: timeoutPolicy)),
            ])
            WedgeBreadcrumbLogger.shared.critical("FG.activationGate.deferredGaveUp", [
                ("reason", reason),
                ("appState", String(describing: UIApplication.shared.applicationState)),
                ("timeoutPolicy", String(describing: timeoutPolicy)),
            ])
            if timeoutPolicy == .fireIfNotBackgrounded,
               UIApplication.shared.applicationState != .background,
               !Ghostty.isAppBackgroundedAtomic {
                LifecycleDebugLogger.shared.checkpoint("FG.activationGate.deferredFireAfterTimeout", ms: nil, [
                    ("reason", reason),
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
                block()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.runWhenSafe(
                    reason: reason,
                    delay: delay,
                    timeoutPolicy: timeoutPolicy,
                    attempt: attempt + 1,
                    block
                )
            }
        }
    }

    private nonisolated func clearIfSettled(token: UInt64, appState: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let didClear = state.withLock { state -> Bool in
            guard state.activeToken == token else { return false }
            guard now >= state.settlingUntil else { return false }
            state.activeToken = 0
            state.settlingUntil = 0
            state.lastEvent = "clear"
            return true
        }

        guard didClear else { return }
        LifecycleDebugLogger.shared.checkpoint("FG.activationGate.cleared", ms: nil, [
            ("token", token),
            ("appState", appState),
        ])
    }
}

private final class ForegroundTransitionWatchdog: Sendable {
    nonisolated static let shared = ForegroundTransitionWatchdog()

    private struct State: Sendable {
        var token: UInt64 = 0
        var activeToken: UInt64 = 0
        var armedAt: Date?
        var firedToken: UInt64 = 0
        var firedAt: Date?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let queue = DispatchQueue(label: "com.rootshell.foregroundTransitionWatchdog", qos: .utility)

    private init() {}

    nonisolated func arm(appState: String) {
        let token = state.withLock { state -> UInt64 in
            state.token &+= 1
            state.activeToken = state.token
            state.armedAt = Date()
            state.firedToken = 0
            state.firedAt = nil
            return state.token
        }

        WedgeBreadcrumbLogger.shared.critical("FG.transitionWatchdog.armed", [
            ("token", token),
            ("appState", appState),
        ])
        LifecycleDebugLogger.shared.checkpoint("FG.transitionWatchdog.armed", ms: nil, [
            ("token", token),
            ("appState", appState),
        ])

        MainThreadStackSampler.shared.start(token: token)

        scheduleHeartbeat(token: token, ordinal: 1)
        queue.asyncAfter(deadline: .now() + 8.0) { [self] in
            fireIfStillArmed(token: token)
        }
    }

    nonisolated func disarm(reason: String, appState: String) {
        let snapshot = state.withLock { state -> (token: UInt64, elapsedMs: Double, fired: Bool, firedElapsedMs: Double) in
            let token = state.activeToken != 0 ? state.activeToken : state.firedToken
            let now = Date()
            let elapsedMs = state.armedAt.map { now.timeIntervalSince($0) * 1000 } ?? -1
            let fired = state.activeToken == 0 && state.firedToken != 0
            let firedElapsedMs = state.firedAt.map { now.timeIntervalSince($0) * 1000 } ?? -1
            state.activeToken = 0
            state.armedAt = nil
            state.firedToken = 0
            state.firedAt = nil
            return (token, elapsedMs, fired, firedElapsedMs)
        }
        guard snapshot.token != 0 else { return }

        MainThreadStackSampler.shared.stop(reason: reason)

        let eventName = snapshot.fired
            ? "FG.transitionWatchdog.firedThenRecovered"
            : "FG.transitionWatchdog.disarmed"

        WedgeBreadcrumbLogger.shared.critical(eventName, [
            ("token", snapshot.token),
            ("reason", reason),
            ("elapsedMs", String(format: "%.2f", snapshot.elapsedMs)),
            ("firedElapsedMs", String(format: "%.2f", snapshot.firedElapsedMs)),
            ("appState", appState),
        ])
        LifecycleDebugLogger.shared.checkpoint(eventName, ms: snapshot.elapsedMs, [
            ("token", snapshot.token),
            ("reason", reason),
            ("firedElapsedMs", String(format: "%.2f", snapshot.firedElapsedMs)),
            ("appState", appState),
        ])
    }

    private nonisolated func scheduleHeartbeat(token: UInt64, ordinal: Int) {
        queue.asyncAfter(deadline: .now() + 1.0) { [self] in
            let snapshot = state.withLock { state -> (active: Bool, elapsedMs: Double) in
                guard state.activeToken == token, let armedAt = state.armedAt else {
                    return (false, -1)
                }
                return (true, Date().timeIntervalSince(armedAt) * 1000)
            }
            guard snapshot.active else { return }

            WedgeBreadcrumbLogger.shared.critical("FG.transitionHeartbeat.timer", [
                ("token", token),
                ("ordinal", ordinal),
                ("elapsedMs", String(format: "%.2f", snapshot.elapsedMs)),
            ])
            LifecycleDebugLogger.shared.checkpoint("FG.transitionHeartbeat.timer", ms: snapshot.elapsedMs, [
                ("token", token),
                ("ordinal", ordinal),
            ])

            Task { @MainActor in
                let appState = String(describing: UIApplication.shared.applicationState)
                WedgeBreadcrumbLogger.shared.critical("FG.transitionHeartbeat.main", [
                    ("token", token),
                    ("ordinal", ordinal),
                    ("elapsedMs", String(format: "%.2f", snapshot.elapsedMs)),
                    ("appState", appState),
                ])
                LifecycleDebugLogger.shared.checkpoint("FG.transitionHeartbeat.main", ms: snapshot.elapsedMs, [
                    ("token", token),
                    ("ordinal", ordinal),
                    ("appState", appState),
                ])
            }

            if ordinal < 8 {
                scheduleHeartbeat(token: token, ordinal: ordinal + 1)
            }
        }
    }

    private nonisolated func fireIfStillArmed(token: UInt64) {
        let snapshot = state.withLock { state -> (active: Bool, elapsedMs: Double) in
            guard state.activeToken == token, let armedAt = state.armedAt else {
                return (false, -1)
            }
            state.activeToken = 0
            state.firedToken = token
            state.firedAt = Date()
            return (true, Date().timeIntervalSince(armedAt) * 1000)
        }
        guard snapshot.active else { return }

        // Keep sampling for one more interval after the fire to capture the
        // last main-thread state, then stop. We rely on the cap (40 samples =
        // 10 s) and the disarm path to bound total samples.
        MainThreadStackSampler.shared.stop(reason: "watchdogFired")

        WedgeBreadcrumbLogger.shared.critical("FG.transitionWatchdog.fired", [
            ("token", token),
            ("elapsedMs", String(format: "%.2f", snapshot.elapsedMs)),
        ])
        LifecycleDebugLogger.shared.criticalCheckpoint("FG.transitionWatchdog.fired", ms: snapshot.elapsedMs, [
            ("token", token),
        ])

        Task { @MainActor in
            let appState = String(describing: UIApplication.shared.applicationState)
            let sceneCount = UIApplication.shared.connectedScenes.count
            let windowCount = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .count
            var diagnostics: [(String, Any)] = [
                ("token", token),
                ("appState", appState),
                ("sceneCount", sceneCount),
                ("windowCount", windowCount),
                ("protectedData", UIApplication.shared.isProtectedDataAvailable),
            ]
            diagnostics.append(contentsOf: ForegroundActivationGate.shared.diagnosticFields())
            LifecycleDebugLogger.shared.criticalCheckpoint("FG.transitionWatchdog.diagnostics", ms: nil, diagnostics)
            WedgeBreadcrumbLogger.shared.critical("FG.transitionWatchdog.diagnostics", [
                ("token", token),
                ("appState", appState),
                ("sceneCount", sceneCount),
                ("windowCount", windowCount),
            ])
        }
    }
}
