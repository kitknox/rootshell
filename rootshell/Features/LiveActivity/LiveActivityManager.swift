//
//  LiveActivityManager.swift
//  rootshell
//
//  Manages a Live Activity on the Lock Screen / Dynamic Island showing active
//  non-resilient sessions (SSH, Kubernetes, Console). Starts automatically when
//  non-resilient sessions are present and the user has enabled the feature.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import Observation
import RootshellPushKit
import os.log
import UIKit

/// Controls which sessions appear in the Live Activity
enum LiveActivitySessionFilter: String, CaseIterable, Sendable {
    /// All sessions including Roam and local active tasks
    case all
    /// Non-roam sessions that trigger location diary + local active tasks
    case diary
    /// Only VPN data, no session info
    case vpnOnly
    /// Always-on info mode: keeps the activity alive on WiFi/Network info alone,
    /// while still showing sessions and VPN when present.
    case infoOnly

    var displayName: String {
        switch self {
        case .all:
            return String(localized: "All Sessions", comment: "Live Activity filter: show all session types")
        case .diary:
            return String(localized: "Diary Sessions", comment: "Live Activity filter: show non-roam sessions")
        case .vpnOnly:
            return String(localized: "VPN Only", comment: "Live Activity filter: show only VPN data")
        case .infoOnly:
            return String(localized: "Info Only", comment: "Live Activity filter: keep activity alive for WiFi/Network info, no sessions required")
        }
    }
}

@MainActor
@Observable
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LiveActivityManager")

    private static let enabledKey = "live_activity_enabled"
    private static let filterKey = "live_activity_session_filter"
    private static let wifiInfoKey = "live_activity_wifi_info_enabled"
    private static let networkInfoKey = "live_activity_network_info_enabled"

    /// Whether the user has enabled Live Activity
    var isEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.enabled, isEnabled)
            }
            if !isEnabled {
                endActivity()
            } else {
                if isAgentInfoEnabled {
                    refreshAgentCountsCache()
                }
                reconcileActivityLifecycle(reason: "feature enabled")
            }
        }
    }

    /// Which sessions to show in the Live Activity
    var sessionFilter: LiveActivitySessionFilter {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.sessionFilter, sessionFilter)
            }
            handleFilterChanged()
        }
    }

    /// Whether to show WiFi info (SSID, AP) on the Live Activity
    var isWiFiInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.wifiInfo, isWiFiInfoEnabled)
            }
            handleWiFiToggleChanged()
        }
    }

    /// Whether to show network/ISP info (public IP, ISP, country) on the Live Activity
    var isNetworkInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.networkInfo, isNetworkInfoEnabled)
            }
            handleNetworkToggleChanged()
        }
    }

    /// Whether to show detected coding agents (working / need attention / idle)
    var isAgentInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.agents, isAgentInfoEnabled)
            }
            handleAgentToggleChanged()
        }
    }

    @ObservationIgnored
    private var isReloading = false

    /// Whether a Live Activity is currently running
    private(set) var isActivityActive: Bool = false

    /// The current activity instance
    @ObservationIgnored
    private var currentActivity: Activity<SessionActivityAttributes>?

    /// Timestamp when the activity was first started (for elapsed timer)
    @ObservationIgnored
    private var activityStartDate: Date?

    /// Task observing activity state updates
    @ObservationIgnored
    private var stateObserverTask: Task<Void, Never>?

    /// Whether the user explicitly dismissed the Live Activity (swipe-to-dismiss).
    /// Suppresses auto-restart until a meaningful state change occurs.
    @ObservationIgnored
    private var userDismissed: Bool = false

    /// Tracks the ID of an activity being ended asynchronously, so startActivity()
    /// doesn't redundantly try to end it again.
    @ObservationIgnored
    private var endingActivityId: String?

    /// Bounded retry for Activity.request failures during cold-start restore.
    @ObservationIgnored
    private var startRetryTask: Task<Void, Never>?
    @ObservationIgnored
    private var startRetryAttempt: Int = 0

    private static let maxStartRetryAttempts = 3
    private static let startRetryDelay: Duration = .seconds(1)

    /// Last known non-resilient session count (for auto-restart after timeout)
    @ObservationIgnored
    private var lastSessionCount: Int = 0
    @ObservationIgnored
    private var lastSSHCount: Int = 0
    @ObservationIgnored
    private var lastK8sCount: Int = 0
    @ObservationIgnored
    private var lastConsoleCount: Int = 0
    @ObservationIgnored
    private var lastHostNames: [String] = []
    @ObservationIgnored
    private var lastLocalTaskCount: Int = 0
    @ObservationIgnored
    private var lastRoamCount: Int = 0
    @ObservationIgnored
    private var lastRoamHostNames: [String] = []

    // MARK: - Coding Agent Cached State

    @ObservationIgnored
    private var lastAgentWorkingCount: Int = 0
    @ObservationIgnored
    private var lastAgentAttentionCount: Int = 0
    @ObservationIgnored
    private var lastAgentIdleCount: Int = 0
    /// Per-pane census with push-route keys, written to the app group on the
    /// background edge for the notification service extension.
    @ObservationIgnored
    private var lastAgentEntries: [CodingAgentEntry] = []
    @ObservationIgnored
    private let agentLedgerStore = AgentActivityLedgerStore()
    /// Serial, so a background-edge save and a foreground clear land in the
    /// order they were issued even across a quick app switch.
    @ObservationIgnored
    private let agentLedgerQueue = DispatchQueue(label: "com.rootshell.liveActivity.agentLedger", qos: .utility)

    /// Coalesces bursts of census changes into one publish.
    @ObservationIgnored
    private var agentPublishTask: Task<Void, Never>?

    /// The content most recently handed to ActivityKit, so the background
    /// edge can republish it with `agentCountsFrozen` set without rebuilding
    /// state (see `handleAppBackgrounded`).
    @ObservationIgnored
    private var lastPublishedState: SessionActivityAttributes.ContentState?

    /// Serializes every ActivityKit publish so an older update cannot land
    /// after a newer one.
    @ObservationIgnored
    private var publishChain: Task<Void, Never>?

    private static let agentPublishCoalesceDelay: Duration = .seconds(1)

    // MARK: - VPN Cached State

    @ObservationIgnored
    private var lastVPNProfileName: String?
    @ObservationIgnored
    private var lastVPNHost: String?
    @ObservationIgnored
    private var lastVPNBytesIn: Int64?
    @ObservationIgnored
    private var lastVPNBytesOut: Int64?
    @ObservationIgnored
    private var lastVPNActiveConnections: Int?
    @ObservationIgnored
    private var lastVPNConnectedSince: Date?
    @ObservationIgnored
    private var lastVPNStatus: String?

    // MARK: - WiFi Cached State

    @ObservationIgnored
    private var lastWiFiSSID: String?
    @ObservationIgnored
    private var lastWiFiAPName: String?
    @ObservationIgnored
    private var lastWiFiAPDetail: String?
    @ObservationIgnored
    private var lastWiFiBand: String?

    // MARK: - Network/ISP Cached State

    @ObservationIgnored
    private var lastNetworkPublicIP: String?
    @ObservationIgnored
    private var lastNetworkASName: String?
    @ObservationIgnored
    private var lastNetworkCountryFlag: String?
    @ObservationIgnored
    private var lastNetworkType: String?

    // MARK: - Public Read-Only Accessors (for prompt modules)

    var cachedWiFiSSID: String? { lastWiFiSSID }
    var cachedWiFiAPName: String? { lastWiFiAPName }
    var cachedWiFiAPDetail: String? { lastWiFiAPDetail }
    var cachedWiFiBand: String? { lastWiFiBand }
    var cachedPublicIP: String? { lastNetworkPublicIP }
    var cachedASName: String? { lastNetworkASName }
    var cachedCountryFlag: String? { lastNetworkCountryFlag }
    var cachedNetworkType: String? { lastNetworkType }

    // MARK: - WiFi Polling

    @ObservationIgnored
    private var wifiPollTask: Task<Void, Never>?
    @ObservationIgnored
    private var wifiPollInFlight = false
    @ObservationIgnored
    private var wifiPollFollowUpPending = false
    @ObservationIgnored
    private var wifiPollRequestScheduled = false

    private var wifiPollLifecycleDeferralPending = false
    private var wifiPollLifecycleDeferralAttempt = 0
    private static let wifiPollLifecycleDeferralMaxAttempts = 64
    private static let wifiPollLifecycleDeferralDelay: TimeInterval = 0.25
    @ObservationIgnored
    private var lastWiFiPollStartedAt: Date?

    private static let wifiPollCooldownSeconds: TimeInterval = 1.0
    private static let wifiPeriodicPollInterval: Duration = .seconds(30)
    private static let wifiSlowPollLogThresholdMs: Double = 100
    private nonisolated static let verboseWiFiPollLoggingKey = "lifecycleVerboseWiFiPollLoggingEnabled"

    private nonisolated static var isVerboseWiFiPollLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.verboseWiFiPollLoggingKey)
    }

    private init() {
        let store = SettingsStore.shared
        self.isEnabled = store.get(Settings.LiveActivity.enabled)
        self.sessionFilter = store.get(Settings.LiveActivity.sessionFilter)
        self.isWiFiInfoEnabled = store.get(Settings.LiveActivity.wifiInfo)
        self.isNetworkInfoEnabled = store.get(Settings.LiveActivity.networkInfo)
        self.isAgentInfoEnabled = store.get(Settings.LiveActivity.agents)
        SettingsRefreshHub.shared.register(keys: [
            Settings.LiveActivity.enabled.name, Settings.LiveActivity.sessionFilter.name,
            Settings.LiveActivity.wifiInfo.name, Settings.LiveActivity.networkInfo.name,
            Settings.LiveActivity.agents.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }

        // Reclaim any orphaned Live Activity from a previous app launch.
        //
        // The activity is still alive on the lock screen / Dynamic Island
        // (the user can see it). Ending it just to issue a fresh
        // Activity.request races iOS's per-app activity slot: the async
        // orphan-end Task hasn't completed when the first updateSessionDetails
        // → startActivity → Activity.request fires, and iOS rejects the new
        // request. The visible symptom is "Live Activity doesn't restore
        // after launch until I open a new tab" (the next session-count
        // change fires another startActivity by which time the orphan is
        // actually gone).
        //
        // Adopting the orphan instead avoids that race entirely:
        // updateSessionDetails sees `currentActivity != nil` after restore
        // populates per-type counts and routes through updateActivity()
        // (a non-racing in-place update) rather than startActivity().
        let orphans = Activity<SessionActivityAttributes>.activities
        if !isEnabled {
            // Feature was disabled between launches — clean up everything.
            for orphan in orphans {
                Task {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        } else if let primary = orphans.first(where: { Self.isAdoptableActivityState($0.activityState) }) {
            Self.logger.info("Adopting orphaned Live Activity \(primary.id) from previous launch")
            currentActivity = primary
            lastPublishedState = primary.content.state
            isActivityActive = true
            // activityStartDate isn't recoverable from ActivityKit; leave it
            // nil so the next updateActivity / startActivity uses Date(). The
            // elapsed-timer base resets but the activity itself stays visible
            // and gets fresh content on the first updateSessionDetails call.
            observeActivityState()
            startInfoPollingDeferred()
            // End any extra orphans (shouldn't happen in practice — we only
            // ever request one — but defensive).
            for extra in orphans where extra.id != primary.id {
                Task {
                    await extra.end(nil, dismissalPolicy: .immediate)
                }
            }
        } else {
            for orphan in orphans {
                Task {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.LiveActivity.enabled.name) {
            isEnabled = store.get(Settings.LiveActivity.enabled)
        }
        if keys.contains(Settings.LiveActivity.sessionFilter.name) {
            sessionFilter = store.get(Settings.LiveActivity.sessionFilter)
        }
        if keys.contains(Settings.LiveActivity.wifiInfo.name) {
            isWiFiInfoEnabled = store.get(Settings.LiveActivity.wifiInfo)
        }
        if keys.contains(Settings.LiveActivity.networkInfo.name) {
            isNetworkInfoEnabled = store.get(Settings.LiveActivity.networkInfo)
        }
        if keys.contains(Settings.LiveActivity.agents.name) {
            isAgentInfoEnabled = store.get(Settings.LiveActivity.agents)
        }
    }

    // MARK: - Public API

    /// Called by SessionTracker when the non-resilient session count changes.
    ///
    /// Owns neither the start nor the end path — both are owned by
    /// `updateSessionDetails`, which now receives aggregated per-type counts
    /// across all windows from `SessionTracker.handleCountChanged` and
    /// `SessionTracker.removeWindow`. Routing lifecycle through the
    /// per-type aggregates avoids the stale-cache trap where this method's
    /// scalar `count` argument doesn't tell us whether roam sessions or
    /// local tasks under the current filter would still keep the activity
    /// alive.
    ///
    /// What's left here: tracking the non-resilient count for retry/dismiss
    /// bookkeeping. A real change in the count is treated as user-meaningful
    /// activity, so we clear `userDismissed` (the user closed something or
    /// opened something; they are no longer suppressing the widget) and
    /// reset the start-retry counter.
    func updateNonResilientSessionCount(_ count: Int) {
        guard isEnabled else { return }

        if count != lastSessionCount {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastSessionCount = count
    }

    /// Called with detailed per-type session data
    func updateSessionDetails(sshCount: Int, k8sCount: Int, consoleCount: Int, hostNames: [String], localTaskCount: Int = 0, roamCount: Int = 0, roamHostNames: [String] = []) {
        guard isEnabled else { return }

        // Reset dismiss suppression when session composition changes
        let cappedHostNames = Array(hostNames.prefix(3))
        let cappedRoamHostNames = Array(roamHostNames.prefix(3))
        let compositionChanged = sshCount != lastSSHCount
            || k8sCount != lastK8sCount
            || consoleCount != lastConsoleCount
            || cappedHostNames != lastHostNames
            || localTaskCount != lastLocalTaskCount
            || roamCount != lastRoamCount
            || cappedRoamHostNames != lastRoamHostNames

        if compositionChanged {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastSSHCount = sshCount
        lastK8sCount = k8sCount
        lastConsoleCount = consoleCount
        lastHostNames = cappedHostNames
        lastLocalTaskCount = localTaskCount
        lastRoamCount = roamCount
        lastRoamHostNames = cappedRoamHostNames
        lastSessionCount = filteredSessionCount

        reconcileActivityLifecycle(reason: "session details updated")
    }

    /// The total session count visible under the current filter
    var displayedSessionCount: Int {
        filteredSessionCount
    }

    /// Re-drive lifecycle from cached session/VPN details after app or scene activation.
    /// Cold-start restore can deliver session counts before ActivityKit is ready to
    /// accept a new request; activation gives those cached details another chance
    /// without requiring a later tab mutation.
    func reconcileAfterActivation() {
        let start = CFAbsoluteTimeGetCurrent()
        LifecycleDebugLogger.shared.checkpoint("LiveActivity.reconcile.enter")
        // Live detection owns the counts again; anything the extension
        // applied from pushes is superseded by the publish below.
        clearAgentLedger()
        if isAgentInfoEnabled {
            refreshAgentCountsCache()
        }
        syncVPNStateFromWidgetState(reason: "activation")
        reconcileActivityLifecycle(reason: "app activation")
        LifecycleDebugLogger.shared.checkpoint("LiveActivity.reconcile.exit",
            ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // MARK: - VPN API

    /// Whether a VPN connection is actively tracked
    private var hasActiveVPN: Bool {
        lastVPNStatus != nil
    }

    /// Called by VPNManager when VPN stats are updated (every 2s poll)
    func updateVPNState(
        profileName: String,
        host: String?,
        status: String,
        bytesIn: Int64,
        bytesOut: Int64,
        activeConnections: Int,
        connectedSince: Date?
    ) {
        guard isEnabled else { return }

        // Reset dismiss suppression when VPN connects (status transitions to non-nil)
        if lastVPNStatus == nil {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastVPNProfileName = profileName
        lastVPNHost = host
        lastVPNStatus = status
        lastVPNBytesIn = bytesIn
        lastVPNBytesOut = bytesOut
        lastVPNActiveConnections = activeConnections
        lastVPNConnectedSince = connectedSince

        reconcileActivityLifecycle(reason: "VPN state updated")
    }

    /// Called by VPNManager when VPN disconnects
    func clearVPNState() {
        // Reset dismiss suppression on VPN disconnect
        userDismissed = false

        lastVPNProfileName = nil
        lastVPNHost = nil
        lastVPNStatus = nil
        lastVPNBytesIn = nil
        lastVPNBytesOut = nil
        lastVPNActiveConnections = nil
        lastVPNConnectedSince = nil

        reconcileActivityLifecycle(reason: "VPN state cleared")
    }

    /// Reconcile cached VPN fields from the app-group state written by the
    /// main app, widget/control intents, and packet-tunnel extension.
    func syncVPNStateFromWidgetState(reason: String) {
        #if !CHINA_BUILD
        guard isEnabled else { return }
        guard let state = VPNWidgetState.read() else {
            if lastVPNStatus != nil {
                clearVPNState()
            }
            return
        }

        switch state.status {
        case "connected", "connecting", "reconnecting", "disconnecting":
            if lastVPNStatus == nil {
                userDismissed = false
                cancelStartRetry(resetAttempts: true)
            }

            let sameConnection =
                lastVPNProfileName == state.profileName &&
                lastVPNHost == state.host
            lastVPNProfileName = state.profileName ?? "VPN"
            lastVPNHost = state.host
            lastVPNStatus = state.status
            lastVPNConnectedSince = state.status == "connected" ? state.connectedSince : nil

            if !sameConnection || state.status != "connected" {
                lastVPNBytesIn = nil
                lastVPNBytesOut = nil
                lastVPNActiveConnections = nil
            }

            reconcileActivityLifecycle(reason: "VPN widget state synced: \(reason)")
        default:
            Self.logger.warning("Unknown VPN widget status: \(state.status, privacy: .public)")
            if lastVPNStatus != nil {
                clearVPNState()
            }
        }
        #endif
    }

    // MARK: - WiFi Info

    private var shouldSkipInfoPollingForLifecycle: Bool {
        Ghostty.isAppBackgroundedAtomic ||
        Ghostty.isInResumeQuietWindowAtomic ||
        ForegroundActivationGate.shared.isUnsafeForSceneMutation ||
        UIApplication.shared.applicationState != .active
    }

    /// Called by NetworkInfoLiveActivityBridge (or background hook) to refresh WiFi data
    func pollWiFiInfo() async {
        guard currentActivity != nil, isWiFiInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            return
        }
        if wifiPollInFlight {
            wifiPollFollowUpPending = true
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", "inFlight"),
            ])
            return
        }

        wifiPollInFlight = true
        lastWiFiPollStartedAt = Date()
        let start = CFAbsoluteTimeGetCurrent()
        let verbosePollLogging = Self.isVerboseWiFiPollLoggingEnabled
        if verbosePollLogging {
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.start", ms: nil, [
                ("appState", UIApplication.shared.applicationState),
            ])
        }
        defer {
            wifiPollInFlight = false
            if wifiPollFollowUpPending {
                wifiPollFollowUpPending = false
                requestWiFiInfoPoll(reason: "followUp")
            }
        }

        let wifi = WiFiInfoService.shared
        await wifi.pollForChanges()
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            return
        }

        let ssid = wifi.ssid
        let apName = wifi.matchedAP?.name ?? wifi.vendorName
        let apDetail = wifi.matchedAP.flatMap { $0.shortname ?? $0.model }
        let vendorWebsite = wifi.vendorWebsite
        let band = wifi.currentBand?.rawValue

        let changed = ssid != lastWiFiSSID || apName != lastWiFiAPName || apDetail != lastWiFiAPDetail || band != lastWiFiBand
        lastWiFiSSID = ssid
        lastWiFiAPName = apName
        lastWiFiAPDetail = apDetail
        lastWiFiBand = band

        // Fetch WiFi vendor favicon on change
        if changed, let website = vendorWebsite,
           let domain = FaviconFetcher.extractDomain(from: website) {
            if let pngData = await FaviconManager.shared.favicon(for: domain) {
                LiveActivityFaviconStore.write(slot: .wifiFavicon, pngData: pngData)
            } else {
                LiveActivityFaviconStore.remove(slot: .wifiFavicon)
            }
        } else if changed && vendorWebsite == nil {
            LiveActivityFaviconStore.remove(slot: .wifiFavicon)
        }

        if changed, currentActivity != nil { updateActivity() }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if verbosePollLogging || changed || elapsedMs >= Self.wifiSlowPollLogThresholdMs {
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.end", ms: elapsedMs, [
                ("changed", changed),
                ("hasSSID", ssid != nil),
                ("slow", elapsedMs >= Self.wifiSlowPollLogThresholdMs),
            ])
        }
    }

    func requestWiFiInfoPoll(reason: String) {
        guard currentActivity != nil, isWiFiInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            guard !wifiPollLifecycleDeferralPending else { return }
            guard wifiPollLifecycleDeferralAttempt < Self.wifiPollLifecycleDeferralMaxAttempts else {
                wifiPollLifecycleDeferralAttempt = 0
                LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.deferredDropped", ms: nil, [
                    ("reason", reason),
                    ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                    ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
                return
            }
            wifiPollLifecycleDeferralPending = true
            wifiPollLifecycleDeferralAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wifiPollLifecycleDeferralDelay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wifiPollLifecycleDeferralPending = false
                    self.requestWiFiInfoPoll(reason: reason)
                }
            }
            return
        }
        wifiPollLifecycleDeferralAttempt = 0

        if wifiPollInFlight {
            wifiPollFollowUpPending = true
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", reason),
            ])
            return
        }

        guard !wifiPollRequestScheduled else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", reason),
            ])
            return
        }

        let cooldownDelay = lastWiFiPollStartedAt.map {
            max(0, Self.wifiPollCooldownSeconds - Date().timeIntervalSince($0))
        } ?? 0
        wifiPollRequestScheduled = true
        LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.scheduled", ms: nil, [
            ("reason", reason),
            ("delayMs", String(format: "%.0f", cooldownDelay * 1000)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownDelay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wifiPollRequestScheduled = false
                await self.pollWiFiInfo()
            }
        }
    }

    private func startWiFiPolling() {
        guard wifiPollTask == nil else { return }
        wifiPollTask = Task { [weak self] in
            // Minimum deferral inside the task itself: belt-and-suspenders
            // against any caller that runs during a scene-update / foreground
            // transition (e.g. handleWiFiToggleChanged firing during a UI
            // burst). The caller-side 0.5s in startInfoPollingDeferred is the
            // primary protection for the foreground-transition paths; this
            // 250ms keeps the polling task itself safe in isolation.
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled {
                guard let self else { break }
                guard !self.shouldSkipInfoPollingForLifecycle else {
                    LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
                    try? await Task.sleep(for: Self.wifiPeriodicPollInterval)
                    continue
                }
                self.requestWiFiInfoPoll(reason: "periodic")
                try? await Task.sleep(for: Self.wifiPeriodicPollInterval)
            }
        }
    }

    /// Defer the WiFi-poll task and network bridge start by 0.5s past the
    /// current frame so they don't pile onto a scene-update transaction
    /// (same rationale as in startActivity). The currentActivity guard
    /// drops the work if the activity is torn down inside the window.
    ///
    /// Called from every path that produces a non-nil currentActivity:
    /// startActivity (fresh request), init() (orphan adoption from previous
    /// launch), and adoptExistingActivityIfAvailable (mid-session adoption).
    /// Without this on the adoption paths, lastWiFiSSID stays nil forever and
    /// the lock-screen WiFi block never appears even when the toggle is on.
    private func startInfoPollingDeferred() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.currentActivity != nil else { return }
            ForegroundActivationGate.shared.runWhenSafe(reason: "liveActivity.infoPollingStart") {
                guard self.currentActivity != nil else { return }
                if self.isWiFiInfoEnabled { self.startWiFiPolling() }
                if self.isWiFiInfoEnabled || self.isNetworkInfoEnabled {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
        }
    }

    private func stopWiFiPolling() {
        wifiPollTask?.cancel()
        wifiPollTask = nil
    }

    private func handleWiFiToggleChanged() {
        if isWiFiInfoEnabled {
            // Enabling an info source is a meaningful user action — clear
            // dismiss suppression and start-retry so .infoOnly mode can
            // (re)spin up the activity.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            if currentActivity != nil {
                startWiFiPolling()
                // Start bridge for background hooks if not already running
                if !NetworkInfoLiveActivityBridge.shared.isRunning {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
            // .infoOnly relies on WiFi/Network being enabled — re-evaluate
            // lifecycle in case this toggle just made the activity eligible.
            reconcileActivityLifecycle(reason: "WiFi info enabled")
        } else {
            stopWiFiPolling()
            lastWiFiSSID = nil
            lastWiFiAPName = nil
            lastWiFiAPDetail = nil
            lastWiFiBand = nil
            LiveActivityFaviconStore.remove(slot: .wifiFavicon)
            if currentActivity != nil { updateActivity() }
            // Stop bridge only if network is also disabled
            if !isNetworkInfoEnabled {
                NetworkInfoLiveActivityBridge.shared.stop()
            }
            // .infoOnly may now have no eligible content; reconcile so we end
            // the activity if both info toggles are off and there are no
            // sessions / VPN.
            if sessionFilter == .infoOnly {
                reconcileActivityLifecycle(reason: "WiFi info disabled")
            }
        }
    }

    // MARK: - Network/ISP Info

    /// Called by NetworkInfoLiveActivityBridge when STUN+Geo resolution completes
    func updateNetworkInfo(publicIP: String?, asName: String?, countryFlag: String?, connectionType: String?) {
        guard publicIP != lastNetworkPublicIP || asName != lastNetworkASName
                || countryFlag != lastNetworkCountryFlag || connectionType != lastNetworkType else { return }
        lastNetworkPublicIP = publicIP
        lastNetworkASName = asName
        lastNetworkCountryFlag = countryFlag
        lastNetworkType = connectionType
        if currentActivity != nil { updateActivity() }
    }

    /// Called by NetworkInfoLiveActivityBridge when stopping
    func clearNetworkInfo() {
        lastNetworkPublicIP = nil
        lastNetworkASName = nil
        lastNetworkCountryFlag = nil
        lastNetworkType = nil
        if currentActivity != nil { updateActivity() }
    }

    private func handleNetworkToggleChanged() {
        if isNetworkInfoEnabled {
            // Enabling an info source is a meaningful user action — clear
            // dismiss suppression and start-retry so .infoOnly mode can
            // (re)spin up the activity.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            if currentActivity != nil {
                if NetworkInfoLiveActivityBridge.shared.isRunning {
                    // Bridge already running (WiFi started it) — start the
                    // interface poller and trigger an immediate resolve.
                    NetworkInfoLiveActivityBridge.shared.setInterfaceMonitoring(enabled: true)
                    NetworkInfoLiveActivityBridge.shared.resolveNow()
                } else {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
            // .infoOnly relies on WiFi/Network being enabled — re-evaluate
            // lifecycle in case this toggle just made the activity eligible.
            reconcileActivityLifecycle(reason: "Network info enabled")
        } else {
            clearNetworkInfo()
            LiveActivityFaviconStore.remove(slot: .ispFavicon)
            // Stop the interface poller — no longer needed without network info.
            NetworkInfoLiveActivityBridge.shared.setInterfaceMonitoring(enabled: false)
            // Stop bridge only if WiFi is also disabled
            if !isWiFiInfoEnabled || currentActivity == nil {
                NetworkInfoLiveActivityBridge.shared.stop()
            }
            // .infoOnly may now have no eligible content; reconcile so we end
            // the activity if both info toggles are off and there are no
            // sessions / VPN.
            if sessionFilter == .infoOnly {
                reconcileActivityLifecycle(reason: "Network info disabled")
            }
        }
    }

    // MARK: - Coding Agents

    /// Called by `AgentAttentionCenter` after a publish pass changed the
    /// aggregate. Re-reads the census and, if a bucket moved, schedules one
    /// coalesced lifecycle reconcile. Scans run sub-second on the selected
    /// pane and a permission prompt produces several passes in a row; each
    /// publish is an XPC to liveactivitiesd and counts against the paired
    /// Watch's sync budget, so bursts are folded into one update.
    func agentCountsMayHaveChanged() {
        guard isEnabled, isAgentInfoEnabled else { return }
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        guard refreshAgentCountsCache() else { return }
        scheduleAgentPublish()
    }

    /// Detected coding agents shown under the current filter.
    var displayedAgentCount: Int {
        guard isAgentInfoEnabled, sessionFilter != .vpnOnly else { return 0 }
        return lastAgentWorkingCount + lastAgentAttentionCount + lastAgentIdleCount
    }

    private var shownAgentWorkingCount: Int { isAgentInfoEnabled ? lastAgentWorkingCount : 0 }
    private var shownAgentAttentionCount: Int { isAgentInfoEnabled ? lastAgentAttentionCount : 0 }
    private var shownAgentIdleCount: Int { isAgentInfoEnabled ? lastAgentIdleCount : 0 }

    /// Snapshot the census into the cache. Returns true when a bucket changed.
    @discardableResult
    private func refreshAgentCountsCache() -> Bool {
        let census = AgentAttentionCenter.shared.codingAgentCensus()
        // Entries refresh even when no bucket moved: a tmux server identity
        // can resolve later without changing any count.
        lastAgentEntries = census.entries
        let counts = census.counts
        guard counts.working != lastAgentWorkingCount
            || counts.attention != lastAgentAttentionCount
            || counts.idle != lastAgentIdleCount
        else { return false }
        lastAgentWorkingCount = counts.working
        lastAgentAttentionCount = counts.attention
        lastAgentIdleCount = counts.idle
        return true
    }

    private func clearAgentCountsCache() {
        lastAgentWorkingCount = 0
        lastAgentAttentionCount = 0
        lastAgentIdleCount = 0
        lastAgentEntries = []
    }

    // MARK: - Agent ledger (notification service extension hand-off)

    /// Leaves the per-pane census in the app group when detection stops. An
    /// agent hook push (blocked / done / failed) arriving while the app is
    /// backgrounded lets the notification service extension move that pane
    /// to "needs attention" and republish the counts; see
    /// `AgentActivityLedger`. Cached entries only, no registry walk, and the
    /// write happens off the main thread so the scene transaction is not
    /// held. With nothing to hand off the file is removed so a stale
    /// snapshot can never match a later push.
    private func writeAgentLedgerForBackground() {
        let store = agentLedgerStore
        guard isEnabled, isAgentInfoEnabled, let activity = currentActivity, !lastAgentEntries.isEmpty else {
            agentLedgerQueue.async { store.clear() }
            return
        }
        let ledger = AgentActivityLedger(activityID: activity.id, entries: lastAgentEntries.map(\.ledgerEntry))
        agentLedgerQueue.async { store.save(ledger) }
    }

    /// Every path that stops treating `currentActivity` as live must clear:
    /// the extension only ever updates the activity id in the file, but a
    /// stale file still costs a load and a lock per push.
    private func clearAgentLedger() {
        let store = agentLedgerStore
        agentLedgerQueue.async { store.clear() }
    }

    private func scheduleAgentPublish() {
        guard agentPublishTask == nil else { return }
        agentPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.agentPublishCoalesceDelay)
            guard let self, !Task.isCancelled else { return }
            self.agentPublishTask = nil
            self.publishAgentCountsNow()
        }
    }

    private func cancelAgentPublish() {
        agentPublishTask?.cancel()
        agentPublishTask = nil
    }

    /// Fire-time half of the debounce. The entry guard in
    /// `agentCountsMayHaveChanged` is not enough: a task scheduled in the
    /// foreground can fire after the background edge, and
    /// `reconcileActivityLifecycle` has no gate of its own.
    private func publishAgentCountsNow() {
        guard isEnabled, isAgentInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            // The cache is current; the foreground reconcile republishes it.
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_agents")
            return
        }
        // A pending start retry publishes the newest cache when it lands;
        // requesting again here would burn retry attempts on count churn.
        if startRetryTask != nil, hasEligibleActivityContent { return }
        reconcileActivityLifecycle(reason: "agent counts changed")
    }

    private func handleAgentToggleChanged() {
        guard isEnabled else { return }
        cancelAgentPublish()
        if isAgentInfoEnabled {
            // Enabling is a meaningful user action, like a filter change:
            // clear dismiss suppression and start-retry, snapshot the census
            // now, and reconcile so an agent-only activity can spin up
            // without waiting for the next status change.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            refreshAgentCountsCache()
            reconcileActivityLifecycle(reason: "agent info enabled")
        } else {
            clearAgentCountsCache()
            clearAgentLedger()
            // Ends an agent-only activity; a mixed one republishes without
            // the agent fields.
            reconcileActivityLifecycle(reason: "agent info disabled")
        }
    }

    // MARK: - Filter Logic

    /// Computed filtered session count based on current filter
    private var filteredSessionCount: Int {
        switch sessionFilter {
        case .vpnOnly:
            return 0
        case .diary:
            return lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount
        case .all, .infoOnly:
            return lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount + lastRoamCount
        }
    }

    /// Build a ContentState based on the current filter
    private func filteredContentState(at date: Date) -> SessionActivityAttributes.ContentState {
        switch sessionFilter {
        case .vpnOnly:
            return SessionActivityAttributes.ContentState(
                sessionCount: 0,
                sshCount: 0,
                k8sCount: 0,
                consoleCount: 0,
                hostNames: [],
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                appIconVariant: AppIconManager.shared.selectedVariant.rawValue
            )

        case .diary:
            let totalCount = lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount
            return SessionActivityAttributes.ContentState(
                sessionCount: totalCount,
                sshCount: lastSSHCount,
                k8sCount: lastK8sCount,
                consoleCount: lastConsoleCount,
                hostNames: lastHostNames,
                localTaskCount: lastLocalTaskCount,
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                agentWorkingCount: shownAgentWorkingCount,
                agentAttentionCount: shownAgentAttentionCount,
                agentIdleCount: shownAgentIdleCount,
                appIconVariant: AppIconManager.shared.selectedVariant.rawValue
            )

        case .all, .infoOnly:
            let totalCount = lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount + lastRoamCount
            var mergedHostNames = lastHostNames
            for host in lastRoamHostNames where !mergedHostNames.contains(host) {
                mergedHostNames.append(host)
            }
            return SessionActivityAttributes.ContentState(
                sessionCount: totalCount,
                sshCount: lastSSHCount,
                k8sCount: lastK8sCount,
                consoleCount: lastConsoleCount,
                hostNames: Array(mergedHostNames.prefix(3)),
                localTaskCount: lastLocalTaskCount,
                roamCount: lastRoamCount,
                roamHostNames: lastRoamHostNames,
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                agentWorkingCount: shownAgentWorkingCount,
                agentAttentionCount: shownAgentAttentionCount,
                agentIdleCount: shownAgentIdleCount,
                appIconVariant: AppIconManager.shared.selectedVariant.rawValue
            )
        }
    }

    /// Called by `AppIconManager` when the user picks a new icon. Rebuilds the
    /// current state so the widget re-renders with the matching display image.
    func refreshIconVariant() {
        guard currentActivity != nil else { return }
        updateActivity()
    }

    /// Re-evaluate activity state after filter changes
    private func handleFilterChanged() {
        guard isEnabled else { return }
        // Filter change is a meaningful user action — clear dismiss suppression
        // so swipe-dismissed activities can come back when the user picks a
        // mode that should be running (e.g. switching into .infoOnly).
        userDismissed = false
        cancelStartRetry(resetAttempts: true)
        reconcileActivityLifecycle(reason: "filter changed")
    }

    private var hasEligibleActivityContent: Bool {
        guard isEnabled else { return false }
        if filteredSessionCount > 0 || hasActiveVPN { return true }
        // Coding agents keep the activity alive on their own (a tssh-only
        // user has no diary sessions to do it), except in VPN Only mode.
        if displayedAgentCount > 0 { return true }
        // Info Only: keep activity alive on WiFi/Network info alone.
        // Require at least one info source enabled to avoid an empty widget.
        if sessionFilter == .infoOnly && (isWiFiInfoEnabled || isNetworkInfoEnabled) {
            return true
        }
        return false
    }

    private func reconcileActivityLifecycle(reason: String) {
        dropInactiveCurrentActivityIfNeeded()

        guard hasEligibleActivityContent else {
            cancelStartRetry(resetAttempts: true)
            endActivity()
            return
        }

        if currentActivity == nil {
            adoptExistingActivityIfAvailable()
        }

        if currentActivity == nil {
            startActivity(reason: reason)
        } else {
            cancelStartRetry(resetAttempts: true)
            updateActivity()
        }
    }

    private func adoptExistingActivityIfAvailable() {
        let activities = Activity<SessionActivityAttributes>.activities
        guard let primary = activities.first(where: { Self.isAdoptableActivityState($0.activityState) }) else {
            for activity in activities {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }

        Self.logger.info("Adopting existing Live Activity \(primary.id) during lifecycle reconciliation")
        currentActivity = primary
        lastPublishedState = primary.content.state
        isActivityActive = true
        observeActivityState()
        startInfoPollingDeferred()

        for extra in activities where extra.id != primary.id {
            Task {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func isAdoptableActivityState(_ state: ActivityState) -> Bool {
        switch state {
        case .pending, .active, .stale:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }

    private func dropInactiveCurrentActivityIfNeeded() {
        guard let activity = currentActivity,
              !Self.isAdoptableActivityState(activity.activityState) else {
            return
        }

        let stateDescription = String(describing: activity.activityState)
        Self.logger.info("Dropping inactive Live Activity \(activity.id), state: \(stateDescription)")
        stateObserverTask?.cancel()
        stateObserverTask = nil
        currentActivity = nil
        activityStartDate = nil
        isActivityActive = false
        lastPublishedState = nil
        clearAgentLedger()
    }

    // MARK: - Activity Lifecycle

    private func startActivity(reason: String = "state changed") {
        guard !userDismissed else {
            Self.logger.debug("Live Activity suppressed (user dismissed)")
            return
        }

        guard hasEligibleActivityContent else {
            cancelStartRetry(resetAttempts: true)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.warning("Live Activities not authorized by user")
            cancelStartRetry(resetAttempts: true)
            return
        }

        // Belt-and-suspenders: end any activities we don't own. This catches
        // edge cases where init cleanup hasn't completed or an async end is
        // still in flight.
        let existingActivities = Activity<SessionActivityAttributes>.activities
        for existing in existingActivities {
            let existingId = existing.id
            if existingId != currentActivity?.id && existingId != endingActivityId {
                Self.logger.info("Ending untracked Live Activity \(existingId) before starting new one")
                Task {
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
            }
        }

        // Preserve start date across system timeout restarts
        let startDate = activityStartDate ?? Date()
        activityStartDate = startDate

        let state = filteredContentState(at: startDate)
        let attributes = SessionActivityAttributes()
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastPublishedState = state
            isActivityActive = true
            let count = filteredSessionCount
            cancelStartRetry(resetAttempts: true)
            Self.logger.info("Live Activity started with \(count) session(s), reason: \(reason)")
            observeActivityState()

            startInfoPollingDeferred()
        } catch {
            let errorDesc = error.localizedDescription
            Self.logger.error("Failed to start Live Activity: \(errorDesc)")
            scheduleStartRetry(reason: reason)
        }
    }

    private func updateActivity() {
        guard let activity = currentActivity else { return }

        let state = filteredContentState(at: activityStartDate ?? Date())
        publish(state, to: activity, reason: "update")
    }

    /// Hands one content state to ActivityKit behind every publish before it,
    /// so a slow earlier update cannot overwrite a newer one; the timestamp
    /// lets the system drop anything that still arrives out of order.
    private func publish(
        _ state: SessionActivityAttributes.ContentState,
        to activity: Activity<SessionActivityAttributes>,
        reason: String
    ) {
        lastPublishedState = state
        let content = ActivityContent(state: state, staleDate: nil)
        let stamp = Date()
        let previous = publishChain
        publishChain = Task {
            await previous?.value
            await activity.update(content, alertConfiguration: nil, timestamp: stamp)
            Self.logger.debug(
                "Live Activity updated (\(reason, privacy: .public)): \(state.sessionCount) session(s), \(state.agentTotalCount) agent(s)")
        }
    }

    /// Called on the background edge, after the grace task is registered.
    /// Agent detection stops the moment the app leaves the foreground, so the
    /// counts on the widget become a snapshot: republish the last content
    /// with `agentCountsFrozen` set so the widget can say so. Cached state
    /// only: no `Activity.activities` lookup and no state rebuild, both of
    /// which can stall inside the scene transaction (see the deferral notes
    /// in `MainView+Lifecycle`). The foreground reconcile clears the flag.
    func handleAppBackgrounded() {
        cancelAgentPublish()
        // A retry has no activity to freeze yet. Let foreground activation
        // re-drive the request instead of creating an unfrozen activity after
        // the one background-edge callback has already passed.
        cancelStartRetry(resetAttempts: true)
        writeAgentLedgerForBackground()
        guard let activity = currentActivity,
              var state = lastPublishedState,
              state.agentTotalCount > 0,
              !state.agentCountsFrozen
        else { return }
        state.agentCountsFrozen = true
        publish(state, to: activity, reason: "background edge")
    }

    private func endActivity() {
        cancelStartRetry(resetAttempts: true)
        clearAgentLedger()

        guard let activity = currentActivity else { return }

        stateObserverTask?.cancel()
        stateObserverTask = nil

        // Nil out currentActivity FIRST to prevent reentrancy:
        // stop() → clearNetworkInfo() → updateActivity() would see non-nil
        // currentActivity and try to update during teardown.
        currentActivity = nil
        activityStartDate = nil
        isActivityActive = false
        cancelAgentPublish()
        lastPublishedState = nil

        // Stop WiFi polling and network bridge, clean up shared favicons
        stopWiFiPolling()
        NetworkInfoLiveActivityBridge.shared.stop()
        LiveActivityFaviconStore.removeAll()

        let finalState = SessionActivityAttributes.ContentState(
            sessionCount: 0,
            sshCount: 0,
            k8sCount: 0,
            consoleCount: 0,
            hostNames: [],
            lastUpdated: Date(),
            vpnProfileName: nil,
            vpnHost: nil,
            vpnBytesIn: nil,
            vpnBytesOut: nil,
            vpnActiveConnections: nil,
            vpnConnectedSince: nil,
            vpnStatus: nil,
            wifiSSID: nil,
            wifiAPName: nil,
            wifiAPDetail: nil,
            wifiBand: nil,
            networkPublicIP: nil,
            networkASName: nil,
            networkCountryFlag: nil,
            networkType: nil
        )
        let content = ActivityContent(state: finalState, staleDate: nil)

        // Track the activity being ended so startActivity() doesn't
        // redundantly try to end it again while the async end is in flight.
        let activityId = activity.id
        endingActivityId = activityId

        Task {
            await activity.end(content, dismissalPolicy: .immediate)
            Self.logger.info("Live Activity ended")
            self.endingActivityId = nil
        }
    }

    // MARK: - State Observation

    /// Observe activity state to handle system-imposed 8-hour timeout and user dismiss
    private func observeActivityState() {
        stateObserverTask?.cancel()

        guard let activity = currentActivity else { return }

        stateObserverTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }

                if state == .dismissed {
                    // User swiped to dismiss — suppress restart until meaningful change
                    Self.logger.info("Live Activity dismissed by user")
                    await MainActor.run {
                        guard let self else { return }
                        self.currentActivity = nil
                        self.activityStartDate = nil
                        self.isActivityActive = false
                        self.stateObserverTask = nil
                        self.userDismissed = true
                        self.cancelAgentPublish()
                        self.lastPublishedState = nil
                        self.clearAgentLedger()

                        // Tear down WiFi/network machinery started alongside the activity
                        self.stopWiFiPolling()
                        NetworkInfoLiveActivityBridge.shared.stop()
                        LiveActivityFaviconStore.removeAll()
                    }
                    return
                }

                if state == .ended {
                    // System 8-hour timeout — auto-restart (preserving start date)
                    Self.logger.info("Live Activity ended by system timeout")
                    await MainActor.run {
                        guard let self else { return }
                        self.currentActivity = nil
                        self.isActivityActive = false
                        self.stateObserverTask = nil

                        if self.hasEligibleActivityContent {
                            Self.logger.info("Auto-restarting Live Activity (eligible content still present)")
                            self.startActivity(reason: "system timeout")
                        }
                    }
                    return
                }
            }
        }
    }

    private func scheduleStartRetry(reason: String) {
        guard startRetryAttempt < Self.maxStartRetryAttempts else {
            Self.logger.error("Live Activity start retry limit reached")
            return
        }

        startRetryAttempt += 1
        let attempt = startRetryAttempt
        let delay = Self.startRetryDelay
        startRetryTask?.cancel()

        startRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.startRetryTask = nil

                // Cancellation can race with this MainActor hop. Re-check the
                // lifecycle at fire time so a retry can never start from the
                // background; activation will reconcile cached state again.
                guard !self.shouldSkipInfoPollingForLifecycle else {
                    LifecycleDebugLogger.shared.bumpSuppression("liveActivity_startRetry")
                    return
                }

                guard self.currentActivity == nil,
                      self.hasEligibleActivityContent,
                      !self.userDismissed else {
                    self.cancelStartRetry(resetAttempts: true)
                    return
                }

                Self.logger.info("Retrying Live Activity start attempt \(attempt), reason: \(reason)")
                self.startActivity(reason: "retry after \(reason)")
            }
        }
    }

    private func cancelStartRetry(resetAttempts: Bool = false) {
        startRetryTask?.cancel()
        startRetryTask = nil
        if resetAttempts {
            startRetryAttempt = 0
        }
    }
}

private extension CodingAgentEntry {
    var ledgerEntry: AgentActivityLedgerEntry {
        AgentActivityLedgerEntry(
            paneID: paneID.uuidString,
            bucket: bucket.ledgerBucket,
            routePane: routePane?.uuidString,
            gatewayPane: gatewayPane?.uuidString,
            tmuxServer: tmuxServer,
            tmuxPaneID: tmuxPaneID)
    }
}

private extension CodingAgentBucket {
    var ledgerBucket: AgentActivityLedgerEntry.Bucket {
        switch self {
        case .working: return .working
        case .attention: return .attention
        case .idle: return .idle
        }
    }
}
#endif
