//
//  TailnetInAppEngine.swift
//  rootshell
//
//  Tailscale running inside rootshell ("rootshell Only"): no VPN, only the
//  app's own connections reach the tailnet. Shares the VPN's node identity,
//  so only one of the two modes runs at a time.
//

#if !CHINA_BUILD

import Foundation
import os
import UIKit

@MainActor
@Observable
final class TailnetInAppEngine {
    static let shared = TailnetInAppEngine()

    /// Posted on the main actor when the in-app Tailscale engine transitions to
    /// `Running`, so sessions sleeping in reconnect backoff can retry right away.
    static let didBecomeRunningNotification = Notification.Name("TailnetInAppEngineDidBecomeRunning")

    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetInApp")

    private(set) var status: TailnetStatus?
    /// The Go engine is up (in any login state).
    private(set) var isStarted = false
    private(set) var lastError: String?
    /// Traffic while running, shaped like the VPN's for the same views.
    private(set) var statistics: VPNStatistics?
    private(set) var trafficHistory: [VPNTrafficSnapshot] = []
    private(set) var connectedSince: Date?
    private var startTask: Task<Void, Error>?
    private var trafficTask: Task<Void, Never>?
    /// Continuations awaiting `Running` (or early exit on `needsLogin`/`stop`).
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Monotonically incremented each time the engine transitions to `Running`,
    /// so callers can detect transitions that occurred while an error crossed actors.
    private(set) var runningGeneration: UInt64 = 0
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var feedsLiveActivity = false
    #endif
    #if !targetEnvironment(macCatalyst)
    private var backgroundedAt: ContinuousClock.Instant?
    private var resetTask: Task<Void, Never>?
    #endif
    /// Bumped by every stop(), so a pending recovery can tell it was overruled.
    private var stopCount = 0

    var isRunning: Bool { status?.isRunning == true }

    /// Writes to the VPN connection debug log when it's turned on.
    nonisolated static func debugLog(_ message: String) {
        VPNConnectionDebugLogger.shared.log("rootshell-only", message)
    }

    private init() {
        #if !targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let engine = TailnetInAppEngine.shared
                engine.backgroundedAt = .now
                if engine.isStarted { Self.debugLog("entered background") }
            }
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TailnetInAppEngine.shared.returnedToForeground() }
        }
    }

    private func returnedToForeground() {
        #if !targetEnvironment(macCatalyst)
        let away = backgroundedAt.map { ContinuousClock.now - $0 }
        backgroundedAt = nil
        if away != nil { refreshShellProxy() }
        #endif
        guard isStarted else { return }
        #if targetEnvironment(macCatalyst)
        // A suspended app misses network changes; let Tailscale re-check.
        TailnetPathMonitor.shared.refresh()
        #else
        Self.debugLog("entered foreground after \(away.map { String(describing: $0) } ?? "unknown")")
        // iOS reclaims a suspended app's UDP sockets, which strands every
        // peer on DERP. Catalyst keeps running in the background.
        guard let away, away >= .seconds(5) else {
            TailnetPathMonitor.shared.refresh()
            return
        }
        guard resetTask == nil else {
            Self.debugLog("socket reset already running")
            return
        }
        resetTask = Task {
            let resetSucceeded = await resetSockets()
            // After the reset, so a netmon rebind doesn't race BindClose/BindUpdate.
            // When ResetSockets succeeded it already rebound and re-STUNned, so only
            // push an event if the physical interface changed; on failure force a check.
            if isStarted {
                TailnetPathMonitor.shared.refresh(forceImmediate: !resetSucceeded)
            }
            resetTask = nil
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Returns true if sockets were rebound cleanly (or the engine was
    /// restarted cleanly after a stuck reset); false on a bind/restart failure
    /// so the caller forces a fallback network refresh.
    private func resetSockets() async -> Bool {
        let started = ContinuousClock.now
        let stops = stopCount
        Self.debugLog("socket reset started")
        do {
            try await TailnetGo.resetSockets()
            Self.debugLog("socket reset finished in \(ContinuousClock.now - started)")
            return true
        } catch let error as TailnetGo.GoError where error.isResetStuck {
            // The engine is wedged; a fresh one replaces the force quit this
            // used to take. Sessions re-dial through it.
            // A Disconnect, mode switch or Whole Device VPN start while this
            // waited also called stop(); recovering would undo it.
            guard stopCount == stops else {
                Self.debugLog("socket reset stuck; engine already stopped elsewhere")
                return false
            }
            Self.logger.error("Tailscale socket reset stuck; restarting the engine")
            Self.debugLog("socket reset stuck; restarting the engine")
            await stop()
            let mode = TailnetModeSettings.load()
            guard stopCount == stops + 1, mode.effectiveMode == .rootshellOnly, mode.inAppEnabled else {
                Self.debugLog("engine stopped elsewhere; not restarting")
                return false
            }
            do {
                try await start()
                return true
            } catch is CancellationError {
                Self.debugLog("restart overruled by a stop")
                return false
            } catch {
                lastError = error.localizedDescription
                Self.debugLog("restart failed: \(error.localizedDescription)")
                return false
            }
        } catch {
            Self.logger.error("Tailscale socket reset failed: \(error.localizedDescription, privacy: .public)")
            Self.debugLog("socket reset failed: \(error.localizedDescription)")
            return false
        }
    }
    #endif

    // MARK: - Lifecycle

    /// Applies saved settings at launch; starts the engine immediately when
    /// always-on is selected or any restored tab targets a tailnet host.
    func appDidLaunch() {
        syncRouting()
        let mode = TailnetModeSettings.load()
        guard mode.effectiveMode == .rootshellOnly, mode.inAppEnabled else { return }
        Task { await updateShellProxy() }
        prewarmIfNeeded(for: WindowStateManager.shared.pendingRestoration)
    }

    /// Starts the in-app engine ahead of session restoration when always-on is
    /// configured or any restored tab targets a tailnet host, overlapping
    /// control-plane login with window and PTY initialization.
    func prewarmIfNeeded(for state: AppWindowState?) {
        syncRouting()
        guard !isStarted, startTask == nil else { return }
        let mode = TailnetModeSettings.load()
        guard mode.effectiveMode == .rootshellOnly, mode.inAppEnabled else { return }
        let hosts = state?.restorableHosts ?? []
        guard !mode.connectOnDemand || TailnetRouting.shared.shouldPrewarm(forHosts: hosts) else { return }
        Self.debugLog(mode.connectOnDemand ? "prewarming for restored tailnet tabs" : "starting on launch")
        Task { try? await start() }
    }

    /// Turns rootshell Only on and starts the engine, showing the login page
    /// if it needs one.
    func turnOn() async throws {
        var mode = TailnetModeSettings.load()
        mode.inAppEnabled = true
        TailnetModeSettings.store(mode)
        syncRouting()
        do {
            try await start()
        } catch is CancellationError {
            return // Turned off again before it finished starting.
        }
        await updateShellProxy()
        TailnetLoginCoordinator.shared.watch()
    }

    func turnOff() async {
        var mode = TailnetModeSettings.load()
        mode.inAppEnabled = false
        TailnetModeSettings.store(mode)
        syncRouting()
        await stop()
        await updateShellProxy()
    }

    func start() async throws {
        if isStarted { return }
        if let startTask { return try await startTask.value }
        // Captured before the task runs, so a stop() before it begins counts.
        let stops = stopCount
        let task = Task { try await performStart(since: stops) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// stop() returns early while this is still starting; it bumps stopCount
    /// past `stops`, and this start then undoes itself.
    private func performStart(since stops: Int) async throws {
        guard stopCount == stops else { throw CancellationError() }
        guard TailnetGo.isSupported else {
            throw TailnetGo.GoError(message: String(localized: "Tailscale isn't available in this build.", comment: "In-app Tailscale unsupported error"))
        }
        guard let controlURL = VPNTailnetProfile.settings().normalizedControlURL else { throw VPNError.invalidControlURL }
        // One node key can't run in two processes.
        if TailnetPlatform.supportsWholeDevice {
            await VPNManager.shared.stopTailnetVPNAndWait()
        }
        guard stopCount == stops else { throw CancellationError() }

        let settings = VPNTailnetProfile.settings()
        let mode = TailnetModeSettings.load()
        let stateDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailscale-inapp", isDirectory: true).path ?? ""
        let config: [String: Any] = [
            "hostname": settings.hostname.isEmpty ? Self.defaultHostname : settings.hostname,
            "acceptRoutes": settings.acceptRoutes,
            "exitNodeID": mode.exitNodeID ?? "",
            "exitNodeAllowLAN": mode.exitNodeAllowLAN,
            "controlURL": controlURL,
            "authKey": TailnetAuthKey.read() ?? "",
            "stateDir": stateDir,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let callback = TailnetGoCallback { status in
            Task { @MainActor in TailnetInAppEngine.shared.apply(status) }
        }
        Self.logger.info("Starting in-app Tailscale")
        TailnetGo.setLogger(VPNConnectionDebugLogger.shared.isEnabled ? TailnetGoLogger() : nil)
        Self.debugLog("starting")
        await TailnetPathMonitor.shared.start()
        guard stopCount == stops else {
            TailnetPathMonitor.shared.stop()
            throw CancellationError()
        }
        do {
            try await TailnetGo.start(configJSON: json, store: TailnetGoStateStore(), callback: callback)
        } catch {
            TailnetPathMonitor.shared.stop()
            Self.debugLog("start failed: \(error.localizedDescription)")
            throw error
        }
        guard stopCount == stops else {
            await TailnetGo.stop()
            TailnetPathMonitor.shared.stop()
            Self.debugLog("stopped while starting")
            throw CancellationError()
        }
        Self.debugLog("started")
        isStarted = true
        lastError = nil
        TailnetStateHandoff.engineDidStart()
        apply(await TailnetGo.status())
    }

    func stop() async {
        stopCount += 1
        startTask?.cancel()
        resolveReadyWaiters(running: false)
        guard isStarted else { return }
        Self.logger.info("Stopping in-app Tailscale")
        let started = ContinuousClock.now
        Self.debugLog("stopping")
        await TailnetGo.stop()
        Self.debugLog("stopped in \(ContinuousClock.now - started)")
        isStarted = false
        TailnetPathMonitor.shared.stop()
        status = nil
        stopTrafficSampling()
        TailnetRouting.shared.update { $0.routedHosts = [] }
        resolveReadyWaiters(running: false)
    }

    /// The Whole Device VPN is about to start with the same node key.
    func stopForVPN() async {
        await stop()
    }

    /// Starts the engine if needed and waits for it to come online. False
    /// when it needs a sign-in (the login page is offered) or times out.
    func ensureRunning(timeout: Duration = .seconds(10)) async -> Bool {
        guard !Task.isCancelled else { return false }
        if TailnetGo.isRunning { return true }
        do {
            try await start()
        } catch is CancellationError {
            return false
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("In-app Tailscale failed to start: \(error.localizedDescription, privacy: .public)")
            Self.debugLog("ensureRunning start failed: \(error.localizedDescription)")
            return false
        }
        guard !Task.isCancelled else { return false }
        if TailnetGo.isRunning { return true }
        if status?.needsLogin == true {
            Self.logger.info("In-app Tailscale needs sign-in")
            TailnetLoginCoordinator.shared.watch()
            return false
        }

        let waiterID = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishReadyWaiter(id: waiterID, result: TailnetGo.isRunning)
        }
        defer { timeoutTask.cancel() }

        let running = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if TailnetGo.isRunning {
                    continuation.resume(returning: true)
                    return
                }
                if status?.needsLogin == true {
                    Self.logger.info("In-app Tailscale needs sign-in")
                    TailnetLoginCoordinator.shared.watch()
                    continuation.resume(returning: false)
                    return
                }
                readyWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishReadyWaiter(id: waiterID, result: false)
            }
        }

        guard !Task.isCancelled else { return false }
        let finalRunning = running || TailnetGo.isRunning
        if !finalRunning {
            if status?.needsLogin == true {
                Self.logger.info("In-app Tailscale needs sign-in")
                TailnetLoginCoordinator.shared.watch()
            } else {
                Self.logger.error("In-app Tailscale not running after \(String(describing: timeout), privacy: .public) (state \(self.status?.state ?? "none", privacy: .public))")
                Self.debugLog("not running after \(timeout) (state \(status?.state ?? "none"))")
            }
        }
        return finalRunning
    }

    private func finishReadyWaiter(id: UUID, result: Bool) {
        guard let continuation = readyWaiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: result)
    }

    private func resolveReadyWaiters(running: Bool) {
        guard !readyWaiters.isEmpty else { return }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(returning: running)
        }
    }

    // MARK: - Commands

    func login() async -> String? {
        do {
            try await start()
            try await TailnetGo.login()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() async -> String? {
        guard isStarted else {
            return String(localized: "Tailscale isn't running.", comment: "In-app Tailscale sign-out error")
        }
        do {
            try await TailnetGo.logout()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard isStarted else { return }
        apply(await TailnetGo.status())
    }

    /// Pushes changed device and exit-node settings into the running engine.
    func applyPrefs() async {
        syncRouting()
        TailnetRouting.shared.update { $0.routedHosts = [] }
        guard isStarted else { return }
        let settings = VPNTailnetProfile.settings()
        let mode = TailnetModeSettings.load()
        let prefs: [String: Any] = [
            "hostname": settings.hostname.isEmpty ? Self.defaultHostname : settings.hostname,
            "acceptRoutes": settings.acceptRoutes,
            "exitNodeID": mode.exitNodeID ?? "",
            "exitNodeAllowLAN": mode.exitNodeAllowLAN,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: prefs) else { return }
        do {
            try await TailnetGo.setPrefs(json: String(decoding: data, as: UTF8.self))
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - State

    private func apply(_ newStatus: TailnetStatus?) {
        guard isStarted else { return }
        if newStatus?.state != status?.state {
            Self.debugLog("state \(newStatus?.state ?? "none")")
        }
        let wasRegistered = status?.registered == true
        let wasRunning = status?.isRunning == true
        status = newStatus
        updateTrafficSampling()
        guard let newStatus else { return }
        // Registered: the auth key is spent or unneeded.
        if newStatus.registered == true, !wasRegistered { TailnetAuthKey.clear() }
        VPNTailnetProfile.recordBackendState(newStatus.state)
        if newStatus.isRunning {
            cachePeers(newStatus)
            resolveReadyWaiters(running: true)
            if !wasRunning {
                runningGeneration &+= 1
                NotificationCenter.default.post(name: Self.didBecomeRunningNotification, object: nil)
            }
        } else if newStatus.needsLogin {
            // Only wake active `ensureRunning()` callers (which will start the
            // login watcher themselves). Passive status polls from Settings must
            // not reopen a dismissed sign-in sheet or restart after sign-out.
            resolveReadyWaiters(running: false)
        }
    }

    // MARK: - Traffic

    /// Samples every 2 s while running, like the VPN's stats poll.
    private func updateTrafficSampling() {
        guard isRunning else { return stopTrafficSampling() }
        guard trafficTask == nil else { return }
        connectedSince = .now
        trafficTask = Task {
            while !Task.isCancelled {
                sampleTraffic()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopTrafficSampling() {
        guard let trafficTask else { return }
        trafficTask.cancel()
        self.trafficTask = nil
        statistics = nil
        trafficHistory = []
        connectedSince = nil
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if feedsLiveActivity {
            feedsLiveActivity = false
            LiveActivityManager.shared.clearVPNState()
        }
        #endif
    }

    private func sampleTraffic() {
        guard let traffic = TailnetGo.traffic() else { return }
        let now = Date()
        trafficHistory.append(VPNTrafficSnapshot(timestamp: now, bytesIn: traffic.bytesIn, bytesOut: traffic.bytesOut))
        trafficHistory.removeAll { now.timeIntervalSince($0.timestamp) > 300 }
        let active = traffic.activeTCPConnections + traffic.activeUDPConnections
        statistics = VPNStatistics(
            bytesIn: traffic.bytesIn,
            bytesOut: traffic.bytesOut,
            activeConnections: active,
            activeTCPConnections: traffic.activeTCPConnections,
            activeUDPConnections: traffic.activeUDPConnections,
            totalConnections: traffic.totalConnections,
            connectedSince: connectedSince
        )
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        // A VPN that is up owns the Live Activity's VPN row.
        guard !VPNManager.shared.status.isActive else {
            feedsLiveActivity = false
            return
        }
        feedsLiveActivity = true
        LiveActivityManager.shared.updateVPNState(
            profileName: "Tailscale",
            host: status?.tailnet,
            status: "connected",
            bytesIn: traffic.bytesIn,
            bytesOut: traffic.bytesOut,
            activeConnections: active,
            connectedSince: connectedSince,
            fromInAppTailnet: true
        )
        #endif
    }

    /// Mirrors settings into the thread-safe routing snapshot.
    func syncRouting() {
        let mode = TailnetModeSettings.load()
        TailnetRouting.shared.update { TailnetRouting.apply(mode, to: &$0) }
    }

    /// Starts the loopback proxy local-shell tools use, or stops it.
    func updateShellProxy() async {
        let mode = TailnetModeSettings.load()
        let wanted = mode.effectiveMode == .rootshellOnly && mode.inAppEnabled && mode.useInLocalShell
        guard wanted, TailnetGo.isSupported else {
            await TailnetGo.stopProxy()
            TailnetRouting.shared.update { $0.shellProxyEnvironment = nil }
            return
        }
        do {
            let info = try await TailnetGo.startProxy()
            let env = [
                "ALL_PROXY": "socks5h://\(info.user):\(info.pass)@127.0.0.1:\(info.port)",
                "NO_PROXY": "localhost,127.0.0.1,::1",
            ]
            TailnetRouting.shared.update { $0.shellProxyEnvironment = env }
        } catch {
            Self.logger.error("Tailscale shell proxy failed: \(error.localizedDescription, privacy: .public)")
            TailnetRouting.shared.update { $0.shellProxyEnvironment = nil }
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// iOS may reclaim the proxy's listener while suspended; Go then rebinds on
    /// a new port, which the shell picks up from the refreshed environment.
    private func refreshShellProxy() {
        guard TailnetRouting.shared.state.shellProxyEnvironment != nil else { return }
        Task { await updateShellProxy() }
    }
    #endif

    // MARK: - Peer cache

    private func cachePeers(_ status: TailnetStatus) {
        var names = Set<String>()
        for peer in status.peers ?? [] {
            names.insert(peer.displayName.lowercased())
            if let dns = peer.dnsName, !dns.isEmpty { names.insert(dns.lowercased()) }
        }
        TailnetRouting.shared.storePeers(suffix: status.magicDNSSuffix?.lowercased(), names: names)
    }

    static var defaultHostname: String {
        #if targetEnvironment(macCatalyst)
        "rootshell-mac"
        #else
        "rootshell-" + UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "-")
        #endif
    }
}

#endif
