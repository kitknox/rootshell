//
//  VPNManager.swift
//  rootshell
//
//  @MainActor @Observable singleton for VPN lifecycle management.
//  Follows the BackgroundTunnelManager pattern.
//

import Foundation
@preconcurrency import NetworkExtension
import os.log
import WidgetKit

/// Manages VPN tunnel lifecycle via NEPacketTunnelProvider.
@MainActor @Observable
final class VPNManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VPNManager")

    static let shared = VPNManager()

    // MARK: - Published State

    private(set) var status: NEVPNStatus = .disconnected
    private(set) var activeProfileID: UUID?
    private(set) var activeProfileName: String?
    private(set) var connectedSince: Date?
    private(set) var statistics: VPNStatistics?
    private(set) var latestStatusJSON: String?
    private(set) var trafficHistory: [VPNTrafficSnapshot] = []
    private(set) var eventHistory: [VPNEvent] = []
    private(set) var lastExtensionError: String?
    /// True while the macOS system extension is waiting on user approval in
    /// System Settings, so the UI can prompt the user. (macOS Standalone only.)
    private(set) var extensionApprovalPending = false

    // MARK: - Private State

    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statsTimer: Timer?
    private let maxEventHistory = 100
    /// Tracks previous status to only reload widget timelines on state transitions
    private var previousStatus: NEVPNStatus = .disconnected
    private var initializationTask: Task<Void, Never>?
    private var pendingStatusManager: NETunnelProviderManager?
    private var pendingStatusFlushScheduled = false
    private var pendingObservedConnectedDuringDeferral = false

    // MARK: - Init

    private init() {
        initializationTask = Task {
            await self.loadExistingManagerBody()
        }
#if STANDALONE && targetEnvironment(macCatalyst)
        MacVPNController.shared.onApprovalRequired = { [weak self] in self?.extensionApprovalPending = true }
        MacVPNController.shared.onApprovalResolved = { [weak self] in self?.extensionApprovalPending = false }
#endif
    }

    // MARK: - Public API

    /// Start VPN for a given connection profile.
    func startVPN(for profile: ConnectionProfile) async throws {
        Self.logger.info("Starting VPN for profile: \(profile.name)")
        // Re-mirror snapshots so the pinned host key reflects the latest
        // known-hosts state at the moment of an app-initiated start.
        ConnectionProfileManager.shared.refreshVPNSharedProfiles()
#if STANDALONE && targetEnvironment(macCatalyst)
        // Catalyst can't host a packet tunnel; drive the native host agent,
        // which forwards the resolved config to its system extension.
        try await MacVPNController.shared.activateExtension()
        try await MacVPNController.shared.start(profileID: profile.id)
#else
        _ = try await VPNStartController.start(profileID: profile.id)
#endif
        await refreshStatusFromSystem()

        activeProfileID = profile.id
        activeProfileName = profile.name
        if status == .disconnected || status == .invalid {
            status = .connecting
        }
        previousStatus = status

        addEvent(.connected(profileID: profile.id, message: profile.sshConfig.host))
#if STANDALONE && targetEnvironment(macCatalyst)
        // No NEVPNStatusDidChange in the Catalyst app (the manager lives in the
        // host), so poll the host for status transitions.
        startStatsPolling()
#endif
    }

    /// Stop the active VPN tunnel.
    func stopVPN() async throws {
#if STANDALONE && targetEnvironment(macCatalyst)
        try await MacVPNController.shared.stop()
        extensionApprovalPending = false
        status = .disconnecting
        previousStatus = status
        addEvent(.disconnected(profileID: activeProfileID ?? UUID(), reason: "User requested"))
        connectedSince = nil
        statistics = nil
        latestStatusJSON = nil
        trafficHistory = []
        // Keep polling: the host reports "disconnecting" until the provider
        // finishes tearing down, and only a poll observing "disconnected" moves
        // the UI off the Disconnecting state (applyMacStatus stops the timer
        // when it lands there).
        startStatsPolling()
#else
        guard let manager = tunnelManager else {
            return
        }

        let disconnectingProfileID = activeProfileID
        let disconnectingProfileName = activeProfileName
        let disconnectingHost = currentWidgetHost

        manager.connection.stopVPNTunnel()
        let connectionStatus = manager.connection.status
        if connectionStatus == .connected || connectionStatus == .connecting || connectionStatus == .reasserting {
            status = .disconnecting
        } else {
            status = connectionStatus
        }
        previousStatus = status

        let profileID = activeProfileID ?? UUID()
        addEvent(.disconnected(profileID: profileID, reason: "User requested"))

        connectedSince = nil
        statistics = nil
        latestStatusJSON = nil
        trafficHistory = []

        writeWidgetState(
            statusOverride: "disconnecting",
            profileIDOverride: disconnectingProfileID,
            profileNameOverride: disconnectingProfileName,
            hostOverride: disconnectingHost
        )
        reloadWidgetTimelines()
#endif
    }

    /// Check if VPN is active for a specific profile.
    func isVPNActive(for profileID: UUID) -> Bool {
        activeProfileID == profileID && (status == .connected || status == .connecting || status == .reasserting)
    }

#if STANDALONE && targetEnvironment(macCatalyst)
    /// Map the host's status string (from the control socket) to NEVPNStatus.
    private func applyMacStatus(_ statusString: String) {
        let mapped: NEVPNStatus
        switch statusString {
        case "connected": mapped = .connected
        case "connecting": mapped = .connecting
        case "reasserting": mapped = .reasserting
        case "disconnecting": mapped = .disconnecting
        case "invalid": mapped = .invalid
        default: mapped = .disconnected
        }
        if status != mapped {
            status = mapped
            previousStatus = mapped
        }
        if mapped == .connected, connectedSince == nil {
            connectedSince = Date()
        } else if mapped == .disconnected || mapped == .invalid {
            connectedSince = nil
            extensionApprovalPending = false
            stopStatsPolling()
        }
    }

    /// Cold-start restore for the macOS host-agent path: query the host for a
    /// live tunnel and rebuild the session state (profile, stats polling) so a
    /// relaunched app can see and stop it. No-op when the host isn't running
    /// (the socket connect fails fast) — a dead host can't have a session.
    private func restoreMacVPNState() async {
        guard await MacVPNController.shared.isHostResponsive() else { return }
        guard let response = await MacVPNController.shared.status() else { return }
        applyMacStatus(response.status)
        guard status == .connected || status == .connecting || status == .reasserting else { return }

        if let profileID = response.profileID {
            activeProfileID = profileID
            activeProfileName =
                ConnectionProfileManager.shared.profile(for: profileID)?.name ??
                VPNSharedProfileStore.profile(id: profileID)?.name
        }
        if let json = response.statusJSON {
            applyStatusJSON(json)
        }
        startStatsPolling()
        Self.logger.info("Restored active macOS VPN session from host")
    }
#endif

    /// Request latest stats from extension via IPC.
    func requestStatusUpdate() async {
#if STANDALONE && targetEnvironment(macCatalyst)
        if let response = await MacVPNController.shared.status() {
            applyMacStatus(response.status)
            if let json = response.statusJSON {
                applyStatusJSON(json)
            }
        }
#else
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isInResumeQuietWindowAtomic,
              !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
            LifecycleDebugLogger.shared.checkpoint("VPN.stats.skipped", ms: nil, [
                ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                ("activationGateUnsafe", ForegroundActivationGate.shared.isUnsafeForSceneMutation),
            ])
            return
        }

        guard let manager = tunnelManager else {
            Self.logger.debug("requestStatusUpdate: no tunnelManager")
            return
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            Self.logger.debug("requestStatusUpdate: connection is not NETunnelProviderSession")
            return
        }

        // Bridge sendProviderMessage's completion handler into async/await
        // so statistics is set directly in this async context.
        let responseData: Data? = await withCheckedContinuation { continuation in
            do {
                let request = Data("getStatus".utf8)
                try session.sendProviderMessage(request) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                let errorMsg = error.localizedDescription
                Self.logger.error("sendProviderMessage failed: \(errorMsg)")
                continuation.resume(returning: nil)
            }
        }

        guard let data = responseData else {
            Self.logger.debug("requestStatusUpdate: nil response data")
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            Self.logger.debug("requestStatusUpdate: response not valid UTF-8")
            return
        }
        applyStatusJSON(json)
#endif
    }

    /// Parse the provider's `getStatus` JSON into stats / traffic / connectedSince.
    /// Shared by the iOS path (direct `sendProviderMessage`) and the macOS path
    /// (relayed from the host over the control socket).
    private func applyStatusJSON(_ json: String) {
        if latestStatusJSON != json {
            self.latestStatusJSON = json
        }
        guard let stats = VPNStatistics.fromGoStatus(json) else {
            Self.logger.debug("applyStatusJSON: failed to parse GoStatus from: \(json)")
            return
        }
        if statistics != stats {
            self.statistics = stats
        }
        if let extensionStartDate = stats.connectedSince,
           connectedSince != extensionStartDate {
            self.connectedSince = extensionStartDate
        }

        // Parse traffic history from the raw JSON (not part of VPNStatistics).
        // Always assign to ensure @Observable fires on every poll.
        if let rawData = json.data(using: .utf8),
           let rawObj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
           let history = rawObj["trafficHistory"] as? [[Any]] {
            let snapshots = VPNTrafficSnapshot.fromJSONArray(history)
            if trafficHistory != snapshots {
                self.trafficHistory = snapshots
            }
        } else {
            if !trafficHistory.isEmpty {
                self.trafficHistory = []
            }
        }

        // Feed Live Activity with real-time VPN stats
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let profileName = activeProfileName ?? "VPN"
        let host = activeProfileHost
        LiveActivityManager.shared.updateVPNState(
            profileName: profileName,
            host: host,
            status: "connected",
            bytesIn: stats.bytesIn,
            bytesOut: stats.bytesOut,
            activeConnections: stats.activeConnections,
            connectedSince: connectedSince
        )
        #endif

        // Write widget state after the resume quiet window only. The poll is
        // already skipped during the window, so this does not amplify scene
        // activation.
        writeWidgetState()
    }

    /// Reconcile in-memory VPN state with NetworkExtension state.
    /// Useful after foreground transitions where status notifications may be missed.
    ///
    /// `shouldApply` is an optional pre-mutation guard called once per await
    /// resume (after `initializationTask` and after `loadAllFromPreferences`).
    /// Lifecycle callers pass a `LifecycleEpoch` check so a backgrounding that
    /// arrives while the NetworkExtension XPC is in flight aborts the
    /// `tunnelManager` / `status` / `activeProfileID` / etc. mutations
    /// instead of publishing them onto a backgrounded scene.
    func refreshStatusFromSystem(shouldApply: (@MainActor () -> Bool)? = nil) async {
        await initializationTask?.value

        if let shouldApply, !shouldApply() {
            LifecycleDebugLogger.shared.checkpoint("VPN.refresh.applySkipped", ms: nil, [
                ("reason", "guardFalseAfterInit"),
            ])
            return
        }

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()

            if let shouldApply, !shouldApply() {
                LifecycleDebugLogger.shared.checkpoint("VPN.refresh.applySkipped", ms: nil, [
                    ("reason", "guardFalseAfterLoad"),
                ])
                return
            }

            guard let manager = managers.first else {
                tunnelManager = nil
                stopStatsPolling()
                status = .disconnected
                previousStatus = .disconnected
                activeProfileID = nil
                activeProfileName = nil
                connectedSince = nil
                statistics = nil
                latestStatusJSON = nil
                trafficHistory = []
                writeWidgetState()
                reloadWidgetTimelines()
                return
            }

            tunnelManager = manager
            observeStatus(manager)

            let systemStatus = manager.connection.status
            status = systemStatus
            previousStatus = systemStatus

            switch systemStatus {
            case .connected:
                restoreActiveProfile(from: manager)
                if connectedSince == nil {
                    connectedSince = manager.connection.connectedDate
                }
                startStatsPolling()
            case .connecting, .reasserting:
                restoreActiveProfile(from: manager)
            case .disconnecting:
                break
            case .disconnected, .invalid:
                stopStatsPolling()
                activeProfileID = nil
                activeProfileName = nil
                connectedSince = nil
                statistics = nil
                latestStatusJSON = nil
                trafficHistory = []
            @unknown default:
                break
            }

            writeWidgetState()
            reloadWidgetTimelines()
        } catch {
            let errorMsg = error.localizedDescription
            Self.logger.error("refreshStatusFromSystem failed: \(errorMsg)")
        }
    }

    // MARK: - Private Helpers

    private func loadExistingManagerBody() async {
#if STANDALONE && targetEnvironment(macCatalyst)
        // The NE configuration lives in the host agent, not this app, so
        // loadAllFromPreferences() finds nothing here. Ask the host instead;
        // a live tunnel must survive an app relaunch (visible + stoppable).
        await restoreMacVPNState()
#else
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let manager = managers.first {
                tunnelManager = manager
                status = manager.connection.status
                observeStatus(manager)

                // Cold-start: restore active profile info from saved NE configuration
                if manager.connection.status == .connected || manager.connection.status == .connecting {
                    restoreActiveProfile(from: manager)
                    // Use NEVPNConnection.connectedDate for immediate display
                    // before the first stats poll returns the extension's timestamp.
                    connectedSince = manager.connection.connectedDate
                }

                // Cold-start: if VPN is already connected when app launches,
                // observeStatus won't fire a .connected transition, so start
                // polling immediately.
                if manager.connection.status == .connected {
                    startStatsPolling()
                }
            }
            // Always write widget state so the profile picker is populated
            // even when no VPN tunnel is active.
            writeWidgetState()
            reloadWidgetTimelines()
        } catch {
            let errorMsg = error.localizedDescription
            Self.logger.error("Failed to load VPN manager: \(errorMsg)")
        }
#endif
    }

    /// Restore activeProfileID and activeProfileName from the saved NE protocol configuration.
    private func restoreActiveProfile(from manager: NETunnelProviderManager) {
        if let widgetState = VPNWidgetState.read(),
           let profileID = widgetState.profileID,
           manager.connection.status == .connecting || manager.connection.status == .connected || manager.connection.status == .reasserting {
            activeProfileID = profileID
            activeProfileName =
                widgetState.profileName ??
                ConnectionProfileManager.shared.profile(for: profileID)?.name ??
                VPNSharedProfileStore.profile(id: profileID)?.name
            return
        }

        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let configDict = proto.providerConfiguration,
              let profileIDString = configDict["profileID"] as? String,
              let profileID = UUID(uuidString: profileIDString) else {
            return
        }

        activeProfileID = profileID
        activeProfileName =
            ConnectionProfileManager.shared.profile(for: profileID)?.name ??
            VPNSharedProfileStore.profile(id: profileID)?.name
    }

    private func observeStatus(_ manager: NETunnelProviderManager) {
        // Remove old observer
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            let observedStatus = manager.connection.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleObservedStatusChange(from: manager, observedStatus: observedStatus)
            }
        }
    }

    private func handleObservedStatusChange(from manager: NETunnelProviderManager, observedStatus: NEVPNStatus) {
        LifecycleDebugLogger.shared.checkpoint("VPN.status.received", ms: nil, [
            ("status", observedStatus.displayString),
            ("backgrounded", Ghostty.isAppBackgroundedAtomic),
            ("quiet", Ghostty.isInResumeQuietWindowAtomic),
            ("activationGateUnsafe", ForegroundActivationGate.shared.isUnsafeForSceneMutation),
        ])

        if Ghostty.isAppBackgroundedAtomic ||
            Ghostty.isInResumeQuietWindowAtomic ||
            ForegroundActivationGate.shared.isUnsafeForSceneMutation {
            pendingStatusManager = manager
            if observedStatus == .connected {
                pendingObservedConnectedDuringDeferral = true
            }
            scheduleDeferredStatusFlush()
            LifecycleDebugLogger.shared.checkpoint("VPN.status.deferred", ms: nil, [
                ("status", observedStatus.displayString),
            ])
            return
        }

        applyObservedStatus(from: manager)
    }

    private func scheduleDeferredStatusFlush() {
        guard pendingStatusManager != nil else { return }
        guard !pendingStatusFlushScheduled else { return }
        pendingStatusFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.pendingStatusFlushScheduled = false
            guard self.pendingStatusManager != nil else { return }
            guard !Ghostty.isAppBackgroundedAtomic,
                  !Ghostty.isInResumeQuietWindowAtomic,
                  !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
                self.scheduleDeferredStatusFlush()
                return
            }
            guard let manager = self.pendingStatusManager else { return }
            self.pendingStatusManager = nil
            self.applyObservedStatus(from: manager)
        }
    }

    private func applyObservedStatus(from manager: NETunnelProviderManager) {
        let newStatus = manager.connection.status
        let oldProfileID = activeProfileID
        let oldProfileName = activeProfileName
        let observedConnectedDuringDeferral = pendingObservedConnectedDuringDeferral
        pendingObservedConnectedDuringDeferral = false

        if status != newStatus {
            status = newStatus
        }

        let statusChanged = newStatus != previousStatus
        previousStatus = newStatus

        LifecycleDebugLogger.shared.checkpoint("VPN.status.applied", ms: nil, [
            ("status", newStatus.displayString),
            ("changed", statusChanged),
            ("sawConnected", observedConnectedDuringDeferral),
        ])

        switch newStatus {
        case .connected:
            restoreActiveProfile(from: manager)
            if let connectedDate = manager.connection.connectedDate,
               connectedSince == nil {
                connectedSince = connectedDate
            }
            if statusChanged || statsTimer == nil {
                startStatsPolling()
            }
            if statusChanged || activeProfileID != oldProfileID || activeProfileName != oldProfileName {
                writeWidgetState()
                reloadWidgetTimelines()
                #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
                LiveActivityManager.shared.syncVPNStateFromWidgetState(reason: "status connected")
                if NetworkInfoLiveActivityBridge.shared.isRunning {
                    NetworkInfoLiveActivityBridge.shared.resolveAfterForegroundQuietWindow()
                }
                #endif
            }
        case .disconnecting:
            if statusChanged {
                writeWidgetState()
                reloadWidgetTimelines()
                #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
                LiveActivityManager.shared.syncVPNStateFromWidgetState(reason: "status disconnecting")
                #endif
            }
        case .disconnected, .invalid:
            if connectedSince != nil { connectedSince = nil }
            if statistics != nil { statistics = nil }
            if !trafficHistory.isEmpty { trafficHistory = [] }
            stopStatsPolling()
            if let extError = Self.readExtensionError() {
                lastExtensionError = extError
                Self.logger.error("Extension error: \(extError)")
            }
            if let profileID = activeProfileID {
                let reason = lastExtensionError ?? "Extension stopped"
                activeProfileID = nil
                activeProfileName = nil
                addEvent(.disconnected(profileID: profileID, reason: reason))
            }
            #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
            if statusChanged || oldProfileID != nil {
                LiveActivityManager.shared.clearVPNState()
                if NetworkInfoLiveActivityBridge.shared.isRunning {
                    NetworkInfoLiveActivityBridge.shared.resolveAfterForegroundQuietWindow()
                }
            }
            #endif
            if statusChanged || oldProfileID != nil || oldProfileName != nil {
                writeWidgetState()
                reloadWidgetTimelines()
            }
        case .connecting, .reasserting:
            if observedConnectedDuringDeferral {
                restoreActiveProfile(from: manager)
                if connectedSince == nil {
                    connectedSince = manager.connection.connectedDate ?? VPNWidgetState.read()?.connectedSince
                }
                if statsTimer == nil {
                    startStatsPolling()
                }
            }
            if statusChanged || observedConnectedDuringDeferral {
                writeWidgetState()
                reloadWidgetTimelines()
                #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
                // syncVPNStateFromWidgetState reads the app-group file we
                // just wrote; keep this ordering so deferred
                // connecting/reasserting states are reflected exactly.
                LiveActivityManager.shared.syncVPNStateFromWidgetState(reason: "status \(newStatus.logDescription)")
                if NetworkInfoLiveActivityBridge.shared.isRunning {
                    NetworkInfoLiveActivityBridge.shared.resolveAfterForegroundQuietWindow()
                }
                #endif
            }
        default:
            break
        }
    }

    private func startStatsPolling() {
        stopStatsPolling()
        // Fire first poll immediately so stats appear without waiting for the timer interval.
        Task { await requestStatusUpdate() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.requestStatusUpdate()
            }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - Shared Status Helpers

    /// The host of the active profile, read from the NE protocol configuration.
    private var activeProfileHost: String? {
        guard let proto = tunnelManager?.protocolConfiguration as? NETunnelProviderProtocol else {
            return nil
        }
        return proto.serverAddress
    }

    private var currentWidgetHost: String? {
        let host = activeProfileHost
        if host == nil || host == "rootshell VPN" {
            return VPNWidgetState.read()?.host
        }
        return host
    }

    private func writeWidgetState(
        statusOverride: String? = nil,
        profileIDOverride: UUID? = nil,
        profileNameOverride: String? = nil,
        hostOverride: String? = nil
    ) {
        let vpnStatus: String
        if let override = statusOverride {
            vpnStatus = override
        } else {
            switch status {
            case .connected: vpnStatus = "connected"
            case .connecting: vpnStatus = "connecting"
            case .reasserting: vpnStatus = "reconnecting"
            case .disconnecting: vpnStatus = "disconnecting"
            default: vpnStatus = "disconnected"
            }
        }

        let existingState = VPNWidgetState.read()
        let resolvedProfileID = profileIDOverride ?? activeProfileID ?? existingState?.profileID
        let resolvedProfileName = profileNameOverride ?? activeProfileName ?? existingState?.profileName
        let resolvedHost = hostOverride ?? currentWidgetHost ?? existingState?.host
        let resolvedConnectedSince: Date? =
            vpnStatus == "connected"
            ? (connectedSince ?? existingState?.connectedSince)
            : nil
        let resolvedStatus: String
        if let existingState,
           existingState.profileID == resolvedProfileID,
           existingState.status == "connected",
           (vpnStatus == "connecting" || vpnStatus == "reconnecting") {
            resolvedStatus = "connected"
        } else {
            resolvedStatus = vpnStatus
        }

        let state = VPNWidgetState(
            status: resolvedStatus,
            profileID: resolvedProfileID,
            profileName: resolvedProfileName,
            host: resolvedHost,
            connectedSince: resolvedConnectedSince,
            lastUpdated: Date()
        )
        VPNWidgetState.write(state)
    }

    private func reloadWidgetTimelines() {
        LifecycleDebugLogger.shared.checkpoint("Widget.reload", ms: nil, [
            ("kind", "VPNControlWidget"),
        ])
        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif
    }

    // MARK: - Widget Connect Request

    /// Called from onOpenURL when the widget opens the app via rootshell://vpn/connect/<profileID>
    /// Returns true when the request is already active or a new tunnel start is issued.
    func handleWidgetConnectRequest(profileID: UUID) async -> Bool {
        await initializationTask?.value
        await refreshStatusFromSystem()
        do {
            _ = try await VPNStartController.start(profileID: profileID)
            await refreshStatusFromSystem()
            return isVPNActive(for: profileID) || (activeProfileID == profileID && status == .connecting)
        } catch {
            Self.logger.error("Widget connect request failed: \(error.localizedDescription)")
            await refreshStatusFromSystem()
            return false
        }
    }

    private func addEvent(_ event: VPNEvent) {
        eventHistory.append(event)
        if eventHistory.count > maxEventHistory {
            eventHistory.removeFirst(eventHistory.count - maxEventHistory)
        }
    }

    /// Read the last error written by the VPN extension via app group.
    private static func readExtensionError() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.defaultAppGroupID
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent("vpn_last_error.txt")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Clean up after reading
        try? FileManager.default.removeItem(at: fileURL)
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - NEVPNStatus Extension

extension NEVPNStatus {
    var logDescription: String {
        switch self {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    var displayString: String {
        switch self {
        case .invalid: return String(localized: "Invalid", comment: "VPN status: invalid configuration")
        case .disconnected: return String(localized: "Disconnected", comment: "VPN status: not connected")
        case .connecting: return String(localized: "Connecting", comment: "VPN status: establishing connection")
        case .connected: return String(localized: "Connected", comment: "VPN status: active connection")
        case .reasserting: return String(localized: "Reconnecting", comment: "VPN status: re-establishing connection")
        case .disconnecting: return String(localized: "Disconnecting", comment: "VPN status: tearing down connection")
        @unknown default: return String(localized: "Unknown", comment: "VPN status: unknown state")
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting:
            return true
        default:
            return false
        }
    }
}
