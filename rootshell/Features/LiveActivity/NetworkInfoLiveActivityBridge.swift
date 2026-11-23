//
//  NetworkInfoLiveActivityBridge.swift
//  rootshell
//
//  Bridges STUN (public IP discovery) and GeoResolver (ISP/country lookup)
//  into the Live Activity. Event-driven: resolves once per network change,
//  not polled. LocationDiaryManager callbacks are observed, but network/WiFi
//  refresh work is dropped while the app is backgrounded and retried from
//  foreground/path-change signals.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import Combine
import Foundation
import os.log
import UIKit

@MainActor
final class NetworkInfoLiveActivityBridge {
    static let shared = NetworkInfoLiveActivityBridge()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell", category: "NetworkInfoLiveActivityBridge"
    )

    private var resolveTask: Task<Void, Never>?
    private var resolveRequestScheduled = false
    /// Identifies the one live lifecycle retry; clearing it voids any queued callback.
    private var resolveLifecycleRetryToken: UInt64?
    private var resolveLifecycleRetryNextToken: UInt64 = 0
    private var resolveLifecycleDeferralAttempt = 0
    private var lastResolveStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var foregroundObserver: (any NSObjectProtocol)?
    private(set) var isRunning = false

    private static let backgroundCallbackKey = "NetworkInfoLiveActivityBridge"

    /// Minimum delay between any foreground- or path-change-triggered work
    /// and its actual execution. Keeps STUN/Geo/favicon/WiFi-poll Tasks out
    /// of the FrontBoard scene-update transaction window even if iOS posts
    /// backed-up notifications during scene activation.
    private nonisolated static let foregroundDeferralSeconds: TimeInterval = 0.5
    private nonisolated static let resolveCooldownSeconds: TimeInterval = 1.0
    private nonisolated static let resolveLifecycleDeferralMaxAttempts = 64
    private nonisolated static let resolveLifecycleDeferralDelay: TimeInterval = 0.25

    /// Minimum age of the last resolve before a location-diary freshness hint
    /// may trigger another one. The diary delivers CL fixes continuously
    /// (it deliberately runs an unfiltered update session to keep SSH
    /// sessions alive in the background), so without this gate every fix
    /// became a STUN + GeoIP round trip. Position alone almost never changes
    /// the public IP — path/interface changes have their own triggers, and
    /// every foreground entry still resolves unconditionally (which also
    /// restarts this window).
    private nonisolated static let locationHintMinResolveAgeSeconds: TimeInterval = 300

    private init() {}

    /// Defer a closure by `foregroundDeferralSeconds` so any work scheduled
    /// in response to a foreground/path-change/notification event lands well
    /// after iOS's scene-update transaction has committed.
    ///
    /// `DispatchQueue.asyncAfter` is not cancellable, so a closure scheduled
    /// while the bridge was running can still fire after `stop()` has torn
    /// down observers and cancelled the resolveTask. The trailing `isRunning`
    /// check drops post-stop work — without it, a queued resolve could
    /// re-issue STUN/Geo/favicon traffic while the user no longer has any
    /// Live Activity feature enabled.
    private nonisolated func deferAfterForeground(
        reason: String,
        _ block: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.foregroundDeferralSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                ForegroundActivationGate.shared.runWhenSafe(reason: "liveActivity.network.\(reason)") {
                    guard !Ghostty.isAppBackgroundedAtomic,
                          !Ghostty.isInResumeQuietWindowAtomic else {
                        LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
                        return
                    }
                    block()
                }
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.info("Starting network info bridge")

        // Initial resolve — defer so we don't pile STUN/Geo/favicon work
        // onto the same scene-update frame the bridge was started in
        // (e.g. inside LiveActivityManager.startActivity on app activation).
        deferAfterForeground(reason: "initial") { [weak self] in
            self?.requestResolve(reason: "initial")
        }

        // Observe network changes via Combine sink. receive(on: .main)
        // ensures the closure runs on MainActor regardless of which queue
        // NWPathMonitor fires pathUpdateHandler on. Each handler defers its
        // resolve work by 0.5s — the small lag is imperceptible for live-
        // activity refresh and removes any chance of a path-change burst
        // landing inside the scene-update transaction.
        NetworkReachabilityMonitor.shared.connectivityRestored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deferAfterForeground(reason: "connectivityRestored") { [weak self] in
                    self?.requestResolve(reason: "connectivityRestored")
                    if LiveActivityManager.shared.isWiFiInfoEnabled {
                        LiveActivityManager.shared.requestWiFiInfoPoll(reason: "connectivityRestored")
                    }
                }
            }
            .store(in: &cancellables)

        NetworkReachabilityMonitor.shared.connectionTypeChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deferAfterForeground(reason: "connectionTypeChanged") { [weak self] in
                    self?.requestResolve(reason: "connectionTypeChanged")
                    if LiveActivityManager.shared.isWiFiInfoEnabled {
                        LiveActivityManager.shared.requestWiFiInfoPoll(reason: "connectionTypeChanged")
                    }
                }
            }
            .store(in: &cancellables)

        // Observe path changes while staying connected on same interface type
        // (catches VPN connect/disconnect, route changes)
        NetworkReachabilityMonitor.shared.networkPathUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deferAfterForeground(reason: "networkPathUpdated") { [weak self] in
                    self?.requestResolve(reason: "networkPathUpdated")
                }
            }
            .store(in: &cancellables)

        // Poll local interfaces (getifaddrs) to catch VPN utun changes that
        // NWPathMonitor may miss or coalesce. Subscription is always wired up
        // (zero-cost when monitor isn't running); the monitor itself is only
        // started when network info is enabled.
        LocalInterfaceMonitor.shared.interfacesChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deferAfterForeground(reason: "interfacesChanged") { [weak self] in
                    self?.requestResolve(reason: "interfacesChanged")
                    if LiveActivityManager.shared.isWiFiInfoEnabled {
                        LiveActivityManager.shared.requestWiFiInfoPoll(reason: "interfacesChanged")
                    }
                }
            }
            .store(in: &cancellables)
        if LiveActivityManager.shared.isNetworkInfoEnabled {
            // Defer interface poller start so its initial getifaddrs Task
            // allocation doesn't land in the foreground frame.
            deferAfterForeground(reason: "interfaceMonitorStart") {
                LocalInterfaceMonitor.shared.start()
            }
        }

        // Resync when app returns to foreground — NWPathMonitor events that
        // fired while the process was suspended are not re-delivered, so an
        // unconditional re-resolve is the only reliable recovery path. The
        // resync is deferred 0.5s past the willEnterForeground notification
        // so it never lands inside the scene-update transaction.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deferAfterForeground(reason: "willEnterForeground") { [weak self] in
                self?.requestResolve(reason: "willEnterForeground")
                if LiveActivityManager.shared.isWiFiInfoEnabled {
                    LiveActivityManager.shared.requestWiFiInfoPoll(reason: "willEnterForeground")
                }
            }
        }

        // Register for location updates as a freshness hint. The deferred
        // closure below drops while the app is backgrounded or in the resume
        // quiet window, so CL bursts cannot enqueue Live Activity network/WiFi
        // work into a scene-update frame.
        LocationDiaryManager.shared.registerBackgroundUpdateCallback(
            key: Self.backgroundCallbackKey
        ) { [weak self] in
            guard let self else { return }
            // Drop hints while a recent resolve is still fresh (see
            // locationHintMinResolveAgeSeconds). Checked before the deferral
            // so continuous CL fixes don't even enqueue closures.
            if let last = self.lastResolveStartedAt,
               Date().timeIntervalSince(last) < Self.locationHintMinResolveAgeSeconds {
                return
            }
            self.deferAfterForeground(reason: "locationBackgroundUpdate") { [weak self] in
                self?.requestResolve(reason: "locationBackgroundUpdate")
                if LiveActivityManager.shared.isWiFiInfoEnabled {
                    LiveActivityManager.shared.requestWiFiInfoPoll(reason: "locationBackgroundUpdate")
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Self.logger.info("Stopping network info bridge")

        resolveTask?.cancel()
        resolveTask = nil
        resolveRequestScheduled = false
        resolveLifecycleRetryToken = nil
        resolveLifecycleDeferralAttempt = 0
        cancellables.removeAll()

        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }

        LocalInterfaceMonitor.shared.stop()

        LocationDiaryManager.shared.removeBackgroundUpdateCallback(key: Self.backgroundCallbackKey)

        // Don't clean up favicons or manager state here — callers
        // (toggle handlers, endActivity) manage cleanup themselves so
        // disabling one feature doesn't tear down the other.
    }

    /// Force an immediate network info resolve (called when network toggle turns on while bridge is already running).
    func resolveNow() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isInResumeQuietWindowAtomic,
              !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
            resolveAfterForegroundQuietWindow()
            return
        }
        requestResolve(reason: "resolveNow")
    }

    /// Resolve after the foreground scene-update and resume quiet window have
    /// settled. Use this for VPN/status/path-change callers that may fire as
    /// iOS is activating the scene.
    func resolveAfterForegroundQuietWindow() {
        LifecycleDebugLogger.shared.checkpoint("LiveNetwork.resolve.deferred")
        deferAfterForeground(reason: "explicitDeferred") { [weak self] in
            self?.requestResolve(reason: "explicitDeferred")
        }
    }

    /// Start or stop the local interface poller to match the network-info toggle.
    /// Called from LiveActivityManager when isNetworkInfoEnabled changes while
    /// the bridge is already running.
    func setInterfaceMonitoring(enabled: Bool) {
        if enabled {
            LocalInterfaceMonitor.shared.start()
        } else {
            LocalInterfaceMonitor.shared.stop()
        }
    }

    private func requestResolve(reason: String) {
        guard LiveActivityManager.shared.isNetworkInfoEnabled else { return }
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isInResumeQuietWindowAtomic,
              !ForegroundActivationGate.shared.isUnsafeForSceneMutation,
              UIApplication.shared.applicationState == .active else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
            // Always retry asynchronously: runWhenSafe runs its block inline
            // when the gate is clear and the app is active, but the
            // backgrounded flag or quiet window can still hold, which recursed
            // until the stack overflowed.
            guard resolveLifecycleRetryToken == nil else { return }
            guard resolveLifecycleDeferralAttempt < Self.resolveLifecycleDeferralMaxAttempts else {
                resolveLifecycleDeferralAttempt = 0
                LifecycleDebugLogger.shared.checkpoint("LiveNetwork.resolve.deferredDropped", ms: nil, [
                    ("reason", reason),
                    ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                    ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
                return
            }
            resolveLifecycleRetryNextToken &+= 1
            let token = resolveLifecycleRetryNextToken
            resolveLifecycleRetryToken = token
            resolveLifecycleDeferralAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveLifecycleDeferralDelay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.resolveLifecycleRetryToken == token else { return }
                    self.resolveLifecycleRetryToken = nil
                    self.requestResolve(reason: reason)
                }
            }
            return
        }
        resolveLifecycleRetryToken = nil
        resolveLifecycleDeferralAttempt = 0

        guard !resolveRequestScheduled else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network_resolve")
            LifecycleDebugLogger.shared.checkpoint("LiveNetwork.resolve.coalesced", ms: nil, [
                ("reason", reason),
            ])
            return
        }

        let cooldownDelay = lastResolveStartedAt.map {
            max(0, Self.resolveCooldownSeconds - Date().timeIntervalSince($0))
        } ?? 0
        resolveRequestScheduled = true
        LifecycleDebugLogger.shared.checkpoint("LiveNetwork.resolve.scheduled", ms: nil, [
            ("reason", reason),
            ("delayMs", String(format: "%.0f", cooldownDelay * 1000)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownDelay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.resolveRequestScheduled = false
                self.triggerResolve(reason: reason)
            }
        }
    }

    private func triggerResolve(reason: String) {
        // Skip STUN+Geo if network info is disabled — bridge may be running
        // only for WiFi background hooks.
        guard LiveActivityManager.shared.isNetworkInfoEnabled else { return }
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isInResumeQuietWindowAtomic,
              !ForegroundActivationGate.shared.isUnsafeForSceneMutation,
              UIApplication.shared.applicationState == .active else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
            return
        }
        LifecycleDebugLogger.shared.checkpoint("LiveNetwork.resolve.start", ms: nil, [
            ("backgrounded", Ghostty.isAppBackgroundedAtomic),
            ("quiet", Ghostty.isInResumeQuietWindowAtomic),
            ("reason", reason),
        ])
        lastResolveStartedAt = Date()

        resolveTask?.cancel()
        resolveTask = Task {
            // Request background execution time so iOS doesn't suspend
            // the app mid-chain (STUN 3s + GeoIP + favicon can take 5-10s).
            var bgTaskID = UIBackgroundTaskIdentifier.invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "NetworkInfoResolve") {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }

            let connectionType = NetworkReachabilityMonitor.shared.connectionType.description

            // STUN discovery for public IP (3s timeout, IPv4)
            var publicIP: String?
            do {
                let stunClient = STUNClient()
                let result = try await stunClient.discover(addressFamily: .ipv4, timeout: 3.0)
                publicIP = result.publicIP
            } catch {
                Self.logger.debug("STUN discovery failed: \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }
            guard !Ghostty.isAppBackgroundedAtomic else {
                LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
                return
            }

            // Geo resolution for ISP/country
            var asName: String?
            var countryFlag: String?
            var ispDomain: String?
            if let ip = publicIP {
                if let geo = await GeoResolver.shared.resolve(ip: ip) {
                    asName = geo.asName ?? geo.asNumber
                    countryFlag = geo.countryWithFlag
                    ispDomain = geo.asDomain
                }
            }

            guard !Task.isCancelled else { return }
            guard !Ghostty.isAppBackgroundedAtomic else {
                LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
                return
            }

            // Write ISP favicon to shared container BEFORE updating content
            // state so the file is on disk when ActivityKit triggers the
            // widget render.
            if let domain = ispDomain {
                if let pngData = await FaviconManager.shared.favicon(for: domain) {
                    LiveActivityFaviconStore.write(slot: .ispFavicon, pngData: pngData)
                } else {
                    LiveActivityFaviconStore.remove(slot: .ispFavicon)
                }
            } else {
                LiveActivityFaviconStore.remove(slot: .ispFavicon)
            }

            guard !Task.isCancelled else { return }
            guard !Ghostty.isAppBackgroundedAtomic else {
                LifecycleDebugLogger.shared.bumpSuppression("liveActivity_network")
                return
            }

            LiveActivityManager.shared.updateNetworkInfo(
                publicIP: publicIP,
                asName: asName,
                countryFlag: countryFlag,
                connectionType: connectionType
            )
        }
    }
}
#endif
