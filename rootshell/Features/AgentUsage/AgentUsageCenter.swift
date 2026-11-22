//
//  AgentUsageCenter.swift
//  rootshell
//
//  Orchestrates subscription-usage tracking for live coding agents:
//  presence (from AgentAttentionCenter) -> credential probes on the hosts'
//  own connections -> usage fetches against the providers' APIs -> the
//  sidebar footer. Modelled on AgentAttentionCenter's conventions.
//
//  Tokens read off hosts are held in memory here and NOWHERE else: never
//  persisted, never logged, dropped the moment the feature is disabled.
//  What IS persisted (UserDefaults) are percentages, dates and plan labels,
//  plus the per-account fetch clock — so a relaunch shows last-known usage
//  instantly and cannot be used to sidestep the rate-limit floor.
//

import Foundation
import UIKit
import os.log

nonisolated enum AgentUsageSettings {
    static let enabledKey = "agentUsageTrackingEnabled"

    nonisolated static var enabled: Bool {
        SettingsStore.shared.value(Settings.CodingAgents.usageTracking)
    }
}

@MainActor
@Observable
final class AgentUsageCenter {
    static let shared = AgentUsageCenter()

    /// Failures only, and never a token, URL, host name or response body —
    /// provider and status class are the whole story a log line may tell.
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell", category: "AgentUsage")

    /// Bumped once per pass that changed displayable state. The footer reads
    /// this to register its Observation dependency; the value is meaningless.
    private(set) var revision: UInt64 = 0

    /// A token held in memory for one (host, provider) slot.
    private enum HeldToken: Sendable {
        case claude(ClaudeCredentials)
        case codex(CodexCredentials)
        case copilot(CopilotCredentials)

        var accessToken: String {
            switch self {
            case .claude(let credentials): return credentials.accessToken
            case .codex(let credentials): return credentials.accessToken
            case .copilot(let credentials): return credentials.token
            }
        }
    }

    @ObservationIgnored private var credentialStates:
        [AgentUsageHostCredentialKey: AgentUsageCredentialState] = [:]
    @ObservationIgnored private var heldTokens: [AgentUsageHostCredentialKey: HeldToken] = [:]
    @ObservationIgnored private var accountStates: [String: AgentUsageAccountState] = [:]
    @ObservationIgnored private var hostProbeHealth: [String: AgentRepositoryHostProbeHealth] = [:]
    @ObservationIgnored private var probesInFlight: Set<String> = []
    @ObservationIgnored private var probesRerunPending: Set<String> = []
    @ObservationIgnored private var fetchesInFlight: Set<String> = []
    /// Fingerprints of every token the provider has rejected for a slot, so
    /// a re-probe that returns one of the SAME tokens does not march
    /// straight back into another 401 every retry interval. A SET, not the
    /// latest one: copilot slots offer several candidates, and forgetting
    /// rejection A the moment candidate B was adopted meant the next
    /// re-read picked A again (it ranks first), so two dead candidates
    /// ping-ponged forever and a good third was never tried. Entries drop
    /// with the slot, or wholesale on manual refresh.
    @ObservationIgnored private var rejectedTokenDigests:
        [AgentUsageHostCredentialKey: Set<String>] = [:]
    /// Invalidates probe and fetch results dispatched before a toggle flip.
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var foregroundActive = true

    private init() {}

    /// Short, non-reversible stand-in for `user@host:port` so a log line can
    /// correlate a host across the probe/fetch trail without ever naming it.
    private nonisolated static func tag(_ hostKey: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in hostKey.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%04x", hash & 0xFFFF)
    }

    // MARK: - Lifecycle

    /// Idempotent; called from window-scene connect alongside
    /// AgentAttentionCenter.ensureStarted().
    func ensureStarted() {
        guard !started else { return }
        started = true
        loadPersistedAccounts()

        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentUsageCenter.shared.applicationDidBecomeActive()
            }
        }
        let background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentUsageCenter.shared.applicationDidEnterBackground()
            }
        }
        observers = [foreground, background]
        foregroundActive = !Ghostty.isAppBackgrounded
        if AgentUsageSettings.enabled { refresh() }
    }

    /// Immediate toggle application, called by the settings switch.
    /// Disabling drops every held token; nothing sensitive survives off.
    func setEnabled(_ enabled: Bool) {
        guard started else { return }
        guard enabled else {
            epoch &+= 1
            schedulerTask?.cancel()
            schedulerTask = nil
            debounceTask?.cancel()
            debounceTask = nil
            heldTokens.removeAll()
            credentialStates.removeAll()
            probesRerunPending.removeAll()
            antigravityStates.removeAll()
            antigravityTokens.removeAll()
            antigravityRefusedDigests.removeAll()
            antigravityNeedsRenewal.removeAll()
            // Nothing will land to settle these, so they cannot be left
            // spinning behind a closed feature.
            refreshingProviders.removeAll()
            revision &+= 1
            return
        }
        refresh()
    }

    /// Providers with a user-initiated refresh outstanding, so the popover
    /// can show progress. Observable: the button state is the whole point.
    private(set) var refreshingProviders: Set<AgentUsageProvider> = []

    /// User tapped Refresh. Re-reads credentials on that provider's live
    /// hosts and drops the pacing floor, but never the 429 window.
    func refreshNow(provider: AgentUsageProvider) {
        guard canWork else { return }
        let now = Date()
        let presence = livePresence()

        // The report lane is paced by its own clock, not by credential
        // state, so a deliberate refresh has to clear that instead.
        if provider == .antigravity {
            for key in presence.hostProviders where key.provider == provider {
                // A fresh read, and a backoff forgiven. The renewal clock stays:
                // repeated clicks must not start another slow `agy models`.
                antigravityStates.removeValue(forKey: key.hostKey)
                antigravityProbeHealth[key.hostKey]?.recordSuccess()
                antigravitySkipLocalUntil.removeValue(forKey: key.hostKey)
                // A refused token gets one more chance, as on the other lanes.
                antigravityRefusedDigests.removeValue(forKey: key.hostKey)
            }
        } else if provider.yieldsUsageReport {
            for key in presence.hostProviders where key.provider == provider {
                ompProbeStates.removeValue(forKey: key.hostKey)
            }
        }

        for key in presence.hostProviders where key.provider == provider {
            // A busy-slot wait from an earlier pass must not hold this one back.
            probeDeferredUntil.removeValue(forKey: key.hostKey)
            // Re-read the host: the usual reason a person reaches for this
            // is that they just signed in, unlocked something, or resumed an
            // agent, and all three are invisible to us until we look again.
            switch credentialStates[key] {
            case .held(let accountKey, _):
                credentialStates[key] = .held(accountKey: accountKey, readAt: .distantPast)
            case .staleCredentials(let accountKey, _):
                credentialStates[key] = .staleCredentials(
                    accountKey: accountKey, readAt: .distantPast)
            case .unreadable(let keychainLocked, _):
                credentialStates[key] = .unreadable(
                    keychainLocked: keychainLocked, checkedAt: .distantPast)
            case .absent:
                credentialStates[key] = .unknown
            case .none, .unknown:
                break
            }
            // Drop the token itself, not just its age. Leaving it in place
            // let this same pass dispatch a fetch with the OLD credential
            // while the re-read was still in flight: after an account
            // switch that answer overwrote the snapshot under the new
            // account's key and then blocked the correct fetch behind the
            // pacing floor. No token means no fetch until the probe lands.
            heldTokens.removeValue(forKey: key)
            // An explicit request also forgives a host that had been backed
            // off after failing probes, and gives a refused token one more
            // chance in case the user just signed in again.
            hostProbeHealth[key.hostKey]?.recordSuccess()
            rejectedTokenDigests.removeValue(forKey: key)

            if let accountKey = credentialStates[key]?.accountKey {
                accountStates[accountKey]?.prepareForManualRefresh()
            }
        }

        refreshingProviders.insert(provider)
        revision &+= 1
        refresh(now: now)
    }

    /// When this provider's live accounts come off an actual HTTP 429.
    ///
    /// Strictly a server-imposed window: our own backoffs (a rejected token,
    /// a network blip) also set `retryAfter`, and reporting those here made
    /// the popover claim "Rate limited" and withdraw the Refresh button for
    /// ordinary failures — exactly when a manual retry is what helps.
    func rateLimitedUntil(provider: AgentUsageProvider, now: Date = Date()) -> Date? {
        var latest: Date?
        for (key, state) in credentialStates {
            guard key.provider == provider,
                  let accountKey = state.accountKey,
                  let account = accountStates[accountKey],
                  account.retryCause == .rateLimit,
                  let until = account.retryAfter,
                  until > now
            else { continue }
            latest = max(latest ?? until, until)
        }
        return latest
    }

    /// Clears the progress flag once a provider has no work outstanding.
    private func settleRefreshing(presence: Presence) {
        guard !refreshingProviders.isEmpty else { return }
        for provider in refreshingProviders {
            let liveHosts = presence.hostProviders
                .filter { $0.provider == provider }
            // A probe waiting out a busy slot is still pending: settling here
            // would end the spinner and drop the retry back to the slow wait.
            let probing = liveHosts.contains {
                probesInFlight.contains($0.hostKey) || antigravityProbesInFlight.contains($0.hostKey)
                    || (probeDeferredUntil[$0.hostKey].map { $0 > Date() } ?? false)
            }
            let fetching = liveHosts.contains { key in
                guard let accountKey = credentialStates[key]?.accountKey else { return false }
                return fetchesInFlight.contains(accountKey)
            }
            if !probing && !fetching {
                refreshingProviders.remove(provider)
                revision &+= 1
            }
        }
    }

    /// Nudge from AgentAttentionCenter when agent identity or topology moved.
    /// Debounced: a freshly-identified agent's connection is often still
    /// settling, and identity edges arrive in bursts.
    func presenceMayHaveChanged() {
        guard canWork, debounceTask == nil else { return }
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AgentUsageTuning.presenceDebounce))
            self?.debounceTask = nil
            self?.refresh()
        }
    }

    private func applicationDidEnterBackground() {
        foregroundActive = false
        schedulerTask?.cancel()
        schedulerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        // A refresh pass cannot complete while backgrounded, and `refresh`
        // returns early there, so settle these now rather than coming back
        // to a popover spinning forever.
        if !refreshingProviders.isEmpty {
            refreshingProviders.removeAll()
            revision &+= 1
        }
    }

    private func applicationDidBecomeActive() {
        foregroundActive = true
        refresh()
    }

    private var canWork: Bool {
        started && foregroundActive && !Ghostty.isAppBackgrounded
            && AgentUsageSettings.enabled
            && AgentAttentionSettings.detectionEnabled
    }

    // MARK: - View API

    struct Row: Equatable {
        enum Content: Equatable {
            case usage(AgentUsageSnapshot)
            /// Running provider, nothing readable. Shown as a muted line so
            /// the silence is explained rather than looking broken.
            case unavailable(AgentUsageUnavailableReason)
        }

        var provider: AgentUsageProvider
        /// Whose quota this is, which is only the same thing as `provider`
        /// for the three native lanes. One oh-my-pi probe yields rows for
        /// several brands, so the footer keys its label and logo off this.
        var brand: AgentUsageBrand
        var content: Content
        var isStale: Bool
        /// Other live accounts of the same provider; > 0 sends the popover
        /// into its per-account breakdown.
        var otherAccountCount: Int

        /// Stable, unique row identity. `provider` alone stopped being unique
        /// once one lane could produce several rows.
        var id: String { "\(provider.rawValue)|\(brand.dedupeID)" }

        var displayName: String {
            provider.yieldsUsageReport ? brand.displayName : provider.displayName
        }

        var snapshot: AgentUsageSnapshot? {
            if case .usage(let snapshot) = content { return snapshot }
            return nil
        }

        /// The account this row names, when its source knows one. Only the
        /// report lane populates it; a native lane's key is host-derived.
        var accountLabel: String? { snapshot?.accountLabel }
    }

    /// One row per provider that has a live, probe-capable agent AND a
    /// snapshot to show. The most-constrained account fronts the row; the
    /// rest are popover detail. Empty means the footer renders nothing.
    func rows(now: Date = Date()) -> [Row] {
        guard canWork else { return [] }
        let presence = livePresence()
        var rows = nativeRows(presence: presence, now: now)
        // Supersession by BRAND was wrong in both directions. The first
        // version dropped the omp row whenever a native row existed; the
        // second dropped the native row whenever any labelled omp row
        // existed, which is global across hosts and accounts -- a labelled
        // Anthropic login reported by omp on host B deleted the native
        // Claude row for a different account on host A, taking every native
        // account behind it.
        //
        // A native snapshot never carries an account label, so there is no
        // way to establish that the two rows describe the same
        // subscription. `ompRows` already drops the omp row for the cases we
        // CAN establish (labels equal, or omp unlabelled with nothing to
        // tell them apart). Everything left is genuinely unresolvable, and
        // showing one subscription twice is a smaller error than silently
        // hiding an account the user is paying for.
        rows.append(contentsOf: ompRows(presence: presence, existing: rows, now: now))
        return rows
    }

    // MARK: - oh-my-pi rows

    /// Snapshots reported by `omp usage --json`, keyed by host. Deliberately
    /// separate from `accountStates`: these arrive already fetched, so none
    /// of the credential, token, floor or 401 bookkeeping applies to them.
    @ObservationIgnored private var ompSnapshots: [String: [AgentUsageSnapshot]] = [:]

    /// Per-host probe clock for the report lane. It has no credential state
    /// to pace it, so without this `credentialsNeedProbe` says yes on every
    /// pass and the probe runs continuously.
    private struct OMPProbeState {
        var checkedAt: Date
        /// The host has no omp, or nothing signed into it. A stable fact,
        /// so it is rechecked on the long absence TTL rather than the
        /// five-minute usage cadence.
        var absent: Bool
    }
    @ObservationIgnored private var ompProbeStates: [String: OMPProbeState] = [:]

    // MARK: - Antigravity rows

    /// Antigravity's last answer per host. A report lane like omp: the host
    /// makes the quota calls, so no credential is held here.
    @ObservationIgnored private var antigravitySnapshots: [String: AgentUsageSnapshot] = [:]

    private struct AntigravityProbeState {
        enum Status: Equatable {
            case ok
            /// No Antigravity sign-in on the host.
            case absent
            /// The host could not reach either source; keeps the last numbers.
            case failed
            case keychainLocked
            /// Google refused the token; `renewing` when the probe started a
            /// background `agy models`, so the next look comes sooner.
            case signInExpired(renewing: Bool)
        }
        var checkedAt: Date
        var status: Status

        var interval: TimeInterval {
            switch status {
            case .ok: return AgentUsageTuning.antigravityFetchFloor
            case .absent: return AgentUsageTuning.absentCredentialTTL
            case .failed: return AgentUsageTuning.staleCredentialRetry
            case .keychainLocked: return AgentUsageTuning.unreadableRetry
            case .signInExpired(let renewing):
                return renewing
                    ? AgentUsageTuning.antigravityRenewalRecheck
                    : AgentUsageTuning.staleCredentialRetry
            }
        }

        var unavailableReason: AgentUsageUnavailableReason? {
            switch status {
            case .keychainLocked: return .keychainLocked
            case .signInExpired: return .signInExpired
            case .ok, .absent, .failed: return nil
            }
        }
    }
    @ObservationIgnored private var antigravityStates: [String: AntigravityProbeState] = [:]
    /// When each host last started a background `agy models`.
    @ObservationIgnored private var antigravityRenewals: [String: Date] = [:]
    /// In flight per host: a probe, or an in-app Google fetch.
    @ObservationIgnored private var antigravityProbesInFlight: Set<String> = []
    /// The host's Google sign-in while it keeps working, so a pass asks Google
    /// straight from the app with no exec channel. Memory only, never logged;
    /// dropped on any failed fetch, host departure, or disable, and re-read
    /// from the host after `antigravityTokenReuse` so an account switch shows.
    @ObservationIgnored private var antigravityTokens:
        [String: (token: AgentUsageAntigravityToken, readAt: Date)] = [:]
    /// Digests of tokens Google refused, so the same token is not asked again.
    @ObservationIgnored private var antigravityRefusedDigests: [String: Set<String>] = [:]
    /// Hosts whose token Google refused: the next probe starts `agy models`.
    @ObservationIgnored private var antigravityNeedsRenewal: Set<String> = []
    @ObservationIgnored private var antigravityProbeHealth: [String: AgentRepositoryHostProbeHealth] = [:]
    /// Hosts whose desktop app answered with nothing usable: until then, the
    /// probe skips it and hands back the sign-in for Google.
    @ObservationIgnored private var antigravitySkipLocalUntil: [String: Date] = [:]
    /// Hosts whose probe found the transport busy, and when to try again.
    @ObservationIgnored private var probeDeferredUntil: [String: Date] = [:]

    private func liveAntigravityHosts(_ presence: Presence) -> [String] {
        presence.hostProviders.filter { $0.provider == .antigravity }.map(\.hostKey).sorted()
    }

    /// One snapshot per account across live hosts, freshest first on ties.
    private func antigravityAccounts(presence: Presence) -> [AgentUsageSnapshot] {
        var best: [String: AgentUsageSnapshot] = [:]
        for hostKey in liveAntigravityHosts(presence) {
            guard let snapshot = antigravitySnapshots[hostKey] else { continue }
            if let current = best[snapshot.accountKey], current.fetchedAt >= snapshot.fetchedAt {
                continue
            }
            best[snapshot.accountKey] = snapshot
        }
        return best.keys.sorted().compactMap { best[$0] }
    }

    private func antigravityRow(_ snapshot: AgentUsageSnapshot, now: Date, others: Int) -> Row {
        Row(
            provider: .antigravity,
            brand: .antigravity,
            content: .usage(snapshot),
            isStale: now.timeIntervalSince(snapshot.fetchedAt)
                > AgentUsageTuning.antigravityFetchFloor * 2,
            otherAccountCount: others)
    }

    private func antigravityRows(presence: Presence, now: Date) -> [Row] {
        let accounts = antigravityAccounts(presence: presence)
        if let lead = accounts.max(by: {
            ($0.mostConstrained?.usedPercent ?? 0) < ($1.mostConstrained?.usedPercent ?? 0)
        }) {
            return [antigravityRow(lead, now: now, others: accounts.count - 1)]
        }
        let reasons = liveAntigravityHosts(presence)
            .compactMap { antigravityStates[$0]?.unavailableReason }
        let reason: AgentUsageUnavailableReason? =
            reasons.contains(.keychainLocked) ? .keychainLocked : reasons.first
        guard let reason else { return [] }
        return [Row(
            provider: .antigravity,
            brand: .antigravity,
            content: .unavailable(reason),
            isStale: false,
            otherAccountCount: 0)]
    }

    private func antigravityRenewalAllowed(hostKey: String, now: Date) -> Bool {
        guard let last = antigravityRenewals[hostKey] else { return true }
        return now.timeIntervalSince(last) >= AgentUsageTuning.antigravityRenewalCooldown
    }

    private func applyAntigravityReadout(
        _ readout: AgentUsageCredentialReadout?,
        renewed: Bool,
        skippedLocal: Bool,
        hostKey: String,
        now: Date
    ) -> Bool {
        let status: AntigravityProbeState.Status
        switch readout {
        case .payload(let payload):
            switch AgentUsageAntigravityReport.parse(payload, hostKey: hostKey, now: now) {
            case .snapshot(let snapshot):
                antigravitySnapshots[hostKey] = snapshot
                status = .ok
            case .localUnusable:
                // The desktop answered but nothing in it parsed. Ask Google
                // next, now: no state stamped, so the next pass probes again.
                antigravitySkipLocalUntil[hostKey] = now.addingTimeInterval(
                    AgentUsageTuning.antigravitySkipLocalDuration)
                antigravityStates.removeValue(forKey: hostKey)
                revision &+= 1
                return true
            case .malformed:
                status = .failed
            }
        case .absent:
            antigravitySnapshots.removeValue(forKey: hostKey)
            status = .absent
        case .unreadable(keychainLocked: true):
            status = .keychainLocked
        case .unreadable(keychainLocked: false):
            status = .failed
        case .signInExpired:
            status = .signInExpired(renewing: renewed)
        case .none:
            // Truncated section: the host's probe health owns the retry.
            return false
        }
        antigravityStates[hostKey] = AntigravityProbeState(checkedAt: now, status: status)
        if status == .ok { antigravityNeedsRenewal.remove(hostKey) }
        // Google had nothing either: the desktop is the only source left, so
        // it is asked again next time rather than skipped for half an hour.
        if skippedLocal, status != .ok {
            antigravitySkipLocalUntil.removeValue(forKey: hostKey)
        }
        Self.logger.debug(
            """
            antigravity host=\(Self.tag(hostKey), privacy: .public) \
            status=\(String(describing: status), privacy: .public) \
            renewed=\(renewed, privacy: .public)
            """)
        revision &+= 1
        return true
    }

    private func adoptOMPSnapshots(
        _ snapshots: [AgentUsageSnapshot],
        hostKey: String,
        now: Date
    ) {
        ompSnapshots[hostKey] = snapshots
        let brands = snapshots.map(\.brand.dedupeID).sorted().joined(separator: ",")
        Self.logger.debug(
            """
            omp usage host=\(Self.tag(hostKey), privacy: .public) \
            accounts=\(snapshots.count, privacy: .public) \
            brands=\(brands, privacy: .public)
            """)
        revision &+= 1
    }

    private func dropOMPSnapshots(hostKey: String) {
        guard ompSnapshots.removeValue(forKey: hostKey) != nil else { return }
        revision &+= 1
    }

    /// One row per (brand, account) oh-my-pi reports on a live host.
    ///
    /// Merging: an omp-reported Anthropic account and a native `claude` probe
    /// on the same machine are usually the same subscription, and showing it
    /// twice is worse than showing it once. omp's row is the one that
    /// survives, because it carries a real account label while the native
    /// Claude key is host-derived on macOS and identifies nothing.
    ///
    /// Merge only when the two agree, or when neither side claims an
    /// identity. Two genuinely different logins for one brand must stay two
    /// rows — silently folding them would report one account's headroom under
    /// the other's name.
    /// Every oh-my-pi account visible right now, collapsed to ONE snapshot
    /// per account key.
    ///
    /// The same account reported by two hosts shares an account key, and the
    /// footer and the popover used to reduce that independently: the footer
    /// took the most constrained snapshot, the popover took whichever the
    /// unordered dictionary yielded first. Tapping a row showing 90% could
    /// open a detail view showing 20% from the other host. Both now read
    /// this.
    ///
    /// Freshest wins, with the host key breaking ties so the choice is
    /// stable across passes rather than dictionary-order dependent.
    private func ompAccounts(presence: Presence) -> [AgentUsageSnapshot] {
        let liveHosts = Set(
            presence.hostProviders.filter { $0.provider == .omp }.map(\.hostKey))
        guard !liveHosts.isEmpty else { return [] }

        var best: [String: (snapshot: AgentUsageSnapshot, hostKey: String)] = [:]
        for hostKey in ompSnapshots.keys.sorted() where liveHosts.contains(hostKey) {
            for snapshot in ompSnapshots[hostKey] ?? [] {
                if let current = best[snapshot.accountKey] {
                    let fresher = snapshot.fetchedAt > current.snapshot.fetchedAt
                    let tie = snapshot.fetchedAt == current.snapshot.fetchedAt
                        && hostKey < current.hostKey
                    guard fresher || tie else { continue }
                }
                best[snapshot.accountKey] = (snapshot, hostKey)
            }
        }
        return best.keys.sorted().compactMap { best[$0]?.snapshot }
    }

    /// True when a native row is plausibly describing the SAME subscription
    /// as this oh-my-pi snapshot.
    ///
    /// Both labelled and different: genuinely two accounts, keep both. Both
    /// labelled and equal, or omp unlabelled (nothing to tell them apart,
    /// and a second row for one subscription is the worse error): the omp
    /// snapshot is redundant.
    private func nativeRowCovers(
        _ snapshot: AgentUsageSnapshot,
        in rows: [Row],
        presence: Presence
    ) -> Bool {
        func covers(_ native: AgentUsageSnapshot) -> Bool {
            guard let ompLabel = snapshot.accountLabel else { return true }
            guard let nativeLabel = native.accountLabel else { return false }
            return nativeLabel.caseInsensitiveCompare(ompLabel) == .orderedSame
        }
        // Antigravity's footer row carries only its lead account, so every
        // live one is checked, not just the row.
        if snapshot.brand.dedupeID == AgentUsageBrand.antigravity.dedupeID,
           antigravityAccounts(presence: presence).contains(where: covers) {
            return true
        }
        return rows.contains { row in
            guard row.provider != .omp,
                  row.brand.dedupeID == snapshot.brand.dedupeID,
                  let native = row.snapshot else { return false }
            return covers(native)
        }
    }

    /// One row per native lane with a live agent and something to show.
    /// Extracted so the popover's dedup can be computed against exactly the
    /// same rows the footer built from.
    private func nativeRows(presence: Presence, now: Date) -> [Row] {
        var rows: [Row] = []
        for provider in AgentUsageProvider.allCases where !provider.yieldsUsageReport {
            let accounts = liveAccountRows(provider: provider, presence: presence, now: now)
            if let lead = accounts.max(by: {
                ($0.snapshot?.mostConstrained?.usedPercent ?? 0)
                    < ($1.snapshot?.mostConstrained?.usedPercent ?? 0)
            }) {
                rows.append(Row(
                    provider: provider,
                    brand: AgentUsageSnapshot.defaultBrand(for: provider),
                    content: lead.content,
                    isStale: lead.isStale,
                    otherAccountCount: accounts.count - 1))
            } else if let reason = unavailableReason(provider: provider, presence: presence) {
                rows.append(Row(
                    provider: provider,
                    brand: AgentUsageSnapshot.defaultBrand(for: provider),
                    content: .unavailable(reason),
                    isStale: false,
                    otherAccountCount: 0))
            }
        }
        // Antigravity counts as native for dedupe: an omp-reported Antigravity
        // account defers to the lane that asked the host itself.
        rows.append(contentsOf: antigravityRows(presence: presence, now: now))
        return rows
    }

    /// The oh-my-pi accounts that survive native-row dedup. Both the footer
    /// and the popover must consume THIS, not the raw account list: the
    /// footer used to filter here while the popover read `ompAccounts`
    /// directly, so opening a row re-introduced the very account the footer
    /// had deliberately suppressed and showed a section for it.
    private func visibleOMPAccounts(presence: Presence, now: Date) -> [AgentUsageSnapshot] {
        let native = nativeRows(presence: presence, now: now)
        return ompAccounts(presence: presence)
            .filter { !nativeRowCovers($0, in: native, presence: presence) }
    }

    private func ompRows(
        presence: Presence,
        existing: [Row],
        now: Date
    ) -> [Row] {
        // Dedup runs PER ACCOUNT, before the brand lead is chosen. Choosing
        // the lead first and testing only that one meant an unlabelled
        // account that happened to be the most constrained discarded the
        // whole brand row -- including labelled accounts alongside it that
        // were demonstrably distinct from the native row.
        var byBrand: [String: [AgentUsageSnapshot]] = [:]
        for snapshot in ompAccounts(presence: presence)
        where !nativeRowCovers(snapshot, in: existing, presence: presence) {
            byBrand[snapshot.brand.dedupeID, default: []].append(snapshot)
        }

        return byBrand.values.compactMap { snapshots -> Row? in
            guard let lead = snapshots.max(by: {
                ($0.mostConstrained?.usedPercent ?? 0) < ($1.mostConstrained?.usedPercent ?? 0)
            }) else { return nil }
            return Row(
                provider: .omp,
                brand: lead.brand,
                content: .usage(lead),
                isStale: now.timeIntervalSince(lead.fetchedAt)
                    > AgentUsageTuning.ompFetchFloor * 2,
                otherAccountCount: snapshots.count - 1)
        }.sorted { $0.brand.dedupeID < $1.brand.dedupeID }
    }

    /// The most informative problem across a provider's live hosts, or nil
    /// when there is genuinely nothing to say (no credentials on the host,
    /// or a first probe still in flight — neither deserves a row).
    private func unavailableReason(
        provider: AgentUsageProvider,
        presence: Presence
    ) -> AgentUsageUnavailableReason? {
        var reason: AgentUsageUnavailableReason?
        for key in presence.hostProviders where key.provider == provider {
            switch credentialStates[key] {
            case .unreadable(keychainLocked: true, _):
                // Most informative and most actionable; nothing outranks it.
                return .keychainLocked
            case .unreadable(keychainLocked: false, _):
                reason = .credentialsUnreadable
            case .staleCredentials:
                if reason == nil { reason = .signInExpired }
            case .none, .unknown, .absent, .held:
                continue
            }
        }
        return reason
    }

    /// Every live account of one provider, most constrained first.
    ///
    /// `brand` narrows an oh-my-pi lane to the one the popover was opened
    /// from; the native lanes each have exactly one brand, so it is a no-op
    /// for them.
    func accountRows(
        provider: AgentUsageProvider,
        brand: AgentUsageBrand? = nil,
        now: Date = Date()
    ) -> [Row] {
        let presence = livePresence()
        let rows: [Row]
        if provider == .antigravity {
            rows = antigravityAccounts(presence: presence)
                .map { antigravityRow($0, now: now, others: 0) }
        } else if provider.yieldsUsageReport {
            rows = ompAccountRows(presence: presence, now: now)
        } else {
            rows = liveAccountRows(provider: provider, presence: presence, now: now)
        }
        return rows
            .filter { brand == nil || $0.brand == brand }
            .sorted {
                ($0.snapshot?.mostConstrained?.usedPercent ?? 0)
                    > ($1.snapshot?.mostConstrained?.usedPercent ?? 0)
            }
    }

    /// Every account oh-my-pi reports across live hosts, one row each. The
    /// footer shows only the most constrained per brand; this is the full
    /// list behind it.
    private func ompAccountRows(presence: Presence, now: Date) -> [Row] {
        visibleOMPAccounts(presence: presence, now: now).map { snapshot in
            Row(
                provider: .omp,
                brand: snapshot.brand,
                content: .usage(snapshot),
                isStale: now.timeIntervalSince(snapshot.fetchedAt)
                    > AgentUsageTuning.ompFetchFloor * 2,
                otherAccountCount: 0)
        }
    }

    /// Hosts whose credentials sit behind a locked keychain, named so the
    /// popover can point at the machine that needs attention.
    func keychainLockedHosts(provider: AgentUsageProvider) -> [String] {
        if provider == .antigravity {
            return antigravityStates.compactMap { hostKey, state in
                state.status == .keychainLocked ? hostKey : nil
            }.sorted()
        }
        return credentialStates.compactMap { key, state in
            guard key.provider == provider,
                  case .unreadable(keychainLocked: true, _) = state else { return nil }
            return key.hostKey
        }.sorted()
    }

    private func liveAccountRows(
        provider: AgentUsageProvider,
        presence: Presence,
        now: Date
    ) -> [Row] {
        let liveKeys = presence.hostProviders
        var seen: Set<String> = []
        var rows: [Row] = []
        for (key, state) in credentialStates {
            // `accountKey` covers .held AND .staleCredentials: a lapsed or
            // 401'd token must not unmap the row — the last snapshot keeps
            // rendering (dimmed once stale) while the slot recovers.
            guard key.provider == provider, liveKeys.contains(key),
                  let accountKey = state.accountKey,
                  !seen.contains(accountKey),
                  let account = accountStates[accountKey],
                  let snapshot = account.snapshot
            else { continue }
            seen.insert(accountKey)
            rows.append(Row(
                provider: provider,
                brand: AgentUsageSnapshot.defaultBrand(for: provider),
                content: .usage(snapshot),
                isStale: account.isStale(now: now, floor: AgentUsageTuning.fetchFloor(provider)),
                otherAccountCount: 0))
        }
        return rows
    }

    // MARK: - Presence

    private struct Presence {
        /// Every live (host, provider), whether or not it can be probed
        /// RIGHT NOW — display keys off this, so a session that is briefly
        /// mid-reconnect does not blink its row away.
        var hostProviders: Set<AgentUsageHostCredentialKey> = []
        /// One probe-capable owner terminal per host. Hosts absent here
        /// (mosh, the iOS local shell, a reconnecting session) are display-
        /// only: no probe is ever dispatched, so they gain a row only when
        /// some probe-capable host maps the same account.
        var owners: [String: Ghostty.TerminalView] = [:]
    }

    private func livePresence() -> Presence {
        var presence = Presence()
        for (provider, owner) in AgentAttentionCenter.shared.usagePresence() {
            let hostKey = AgentAttentionCenter.hostKey(for: owner)
            presence.hostProviders.insert(
                AgentUsageHostCredentialKey(hostKey: hostKey, provider: provider))
            if presence.owners[hostKey] == nil, RemoteExecProbe.canProbe(owner) {
                presence.owners[hostKey] = owner
            }
        }
        return presence
    }

    // MARK: - Refresh pass

    /// One full pass: probe hosts whose credentials are due, fetch accounts
    /// past their floor, publish, park the timer on the next deadline.
    private func refresh(now: Date = Date()) {
        guard canWork else { return }
        let presence = livePresence()
        pruneDepartedHosts(presence: presence)

        var probeTargets: [String: [AgentUsageProvider]] = [:]
        for key in presence.hostProviders where credentialsNeedProbe(key, now: now) {
            probeTargets[key.hostKey, default: []].append(key.provider)
        }
        for (hostKey, providers) in probeTargets {
            guard let owner = presence.owners[hostKey] else { continue }
            let deferred = probeDeferred(hostKey: hostKey, now: now)
            // Antigravity probes alone: its section makes slow network calls,
            // and a timeout must not cost the batch its answers. The two
            // never overlap on a host, since tssh allows one probe per session.
            let batch = providers.filter { $0 != .antigravity }
            if !deferred, !batch.isEmpty, !antigravityProbesInFlight.contains(hostKey),
               hostProbeHealth[hostKey]?.canStart(now: now) != false {
                dispatchProbe(hostKey: hostKey, providers: batch.sorted { $0.rawValue < $1.rawValue },
                              owner: owner, now: now)
            }
            if providers.contains(.antigravity),
               antigravityProbeHealth[hostKey]?.canStart(now: now) != false {
                // A held sign-in needs no exec channel, so no probe slot.
                if let held = antigravityTokens[hostKey],
                   now.timeIntervalSince(held.readAt) < AgentUsageTuning.antigravityTokenReuse {
                    dispatchAntigravityFetch(hostKey: hostKey, token: held.token, now: now)
                } else if !deferred, !probesInFlight.contains(hostKey) {
                    antigravityTokens.removeValue(forKey: hostKey)
                    dispatchAntigravityProbe(hostKey: hostKey, owner: owner, now: now)
                }
            }
        }

        dispatchDueFetches(presence: presence, now: now)
        settleRefreshing(presence: presence)
        rescheduleTimer(presence: presence, now: now)
    }

    /// Forgets credential state for hosts no longer running this provider.
    ///
    /// Two reasons, and the first is the important one: a borrowed OAuth
    /// token must not outlive the connection it was read from. The second is
    /// correctness — holding state for a departed host meant that if the
    /// same `user@host:port` came back inside the credential TTL after the
    /// user signed in as somebody else, the PREVIOUS account's token and
    /// numbers were reused with no probe. Snapshots are kept (they are only
    /// percentages, and they make a returning host render instantly).
    private func pruneDepartedHosts(presence: Presence) {
        let departed = credentialStates.keys.filter { !presence.hostProviders.contains($0) }
        // Keyed on live OMP presence specifically, not on "any agent is
        // still on this host": an omp pane can close while claude keeps the
        // host alive, and using the host-wide set kept a stale account list
        // and a stale probe clock across that.
        let liveOMPHosts = Set(
            presence.hostProviders.filter { $0.provider == .omp }.map(\.hostKey))
        let departedOMP = Set(ompSnapshots.keys.filter { !liveOMPHosts.contains($0) })
            // A host that answered "no omp here" has a probe state and NO
            // snapshot, so keying the guard on snapshots alone returned
            // early and stranded that clock for its full 30-minute TTL.
            .union(ompProbeStates.keys.filter { !liveOMPHosts.contains($0) })
        let liveAntigravity = Set(liveAntigravityHosts(presence))
        let departedAntigravity = Set(antigravitySnapshots.keys)
            .union(antigravityStates.keys)
            .union(antigravityTokens.keys)
            .union(antigravityRefusedDigests.keys)
            .filter { !liveAntigravity.contains($0) }
        guard !departed.isEmpty || !departedOMP.isEmpty || !departedAntigravity.isEmpty
        else { return }
        for key in departed {
            credentialStates.removeValue(forKey: key)
            heldTokens.removeValue(forKey: key)
            rejectedTokenDigests.removeValue(forKey: key)
        }
        // The omp lane holds no credentials, so it is not in the loop above,
        // but its reports must not outlive the host either: a returning
        // user@host:port would otherwise inherit the previous login's
        // account list.
        for hostKey in departedOMP {
            ompSnapshots.removeValue(forKey: hostKey)
            ompProbeStates.removeValue(forKey: hostKey)
        }
        // Same for Antigravity. Renewal times are kept, so a pane reopened
        // inside the cooldown cannot start another `agy models`.
        for hostKey in departedAntigravity {
            antigravitySnapshots.removeValue(forKey: hostKey)
            antigravityStates.removeValue(forKey: hostKey)
            antigravityTokens.removeValue(forKey: hostKey)
            antigravityRefusedDigests.removeValue(forKey: hostKey)
            antigravityNeedsRenewal.remove(hostKey)
        }
        revision &+= 1
    }

    private func credentialsNeedProbe(_ key: AgentUsageHostCredentialKey, now: Date) -> Bool {
        // A report lane keeps no credential state, so it can never answer
        // this from `credentialStates` and would report "needs a probe"
        // forever. `refresh()` runs unconditionally after every probe
        // completion, so that is not a slow poll but a continuous loop: one
        // remote exec channel per host, back to back, for as long as an
        // oh-my-pi session is open. Its own clock gates it instead.
        if key.provider == .antigravity {
            guard let state = antigravityStates[key.hostKey] else { return true }
            return now.timeIntervalSince(state.checkedAt) >= state.interval
        }
        if key.provider.yieldsUsageReport {
            guard let state = ompProbeStates[key.hostKey] else { return true }
            let interval = state.absent
                // "no omp installed here" is a stable fact and deserves the
                // same long TTL a missing credential store gets.
                ? AgentUsageTuning.absentCredentialTTL
                // Anything faster than omp's own five-minute cache re-reads
                // numbers it will not have refreshed.
                : AgentUsageTuning.ompFetchFloor
            return now.timeIntervalSince(state.checkedAt) >= interval
        }
        switch credentialStates[key] {
        case .none, .unknown:
            return true
        case .unreadable(_, let checkedAt):
            return now.timeIntervalSince(checkedAt) >= AgentUsageTuning.unreadableRetry
        case .absent(let until):
            return now >= until
        case .held(_, let readAt):
            return now.timeIntervalSince(readAt) >= AgentUsageTuning.credentialTTL
        case .staleCredentials(_, let readAt):
            // The token on disk recovers only when the user resumes the
            // agent and its CLI refreshes itself; check in gently.
            return now.timeIntervalSince(readAt) >= AgentUsageTuning.staleCredentialRetry
        }
    }

    // MARK: - Credential probes

    private func dispatchProbe(
        hostKey: String,
        providers: [AgentUsageProvider],
        owner: Ghostty.TerminalView,
        now: Date
    ) {
        guard probesInFlight.insert(hostKey).inserted else {
            // A probe for this host is mid-flight with its provider list
            // already fixed; run one more pass when it completes.
            probesRerunPending.insert(hostKey)
            return
        }

        var health = hostProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordStarted(now: now)
        hostProbeHealth[hostKey] = health

        let (command, nonce) = AgentUsageProbeCommand.command(
            providers: providers, pathPrefix: SSHConfig.remoteExecPathPrefix)
        let dispatchedEpoch = epoch
        let hostTag = Self.tag(hostKey)
        let providerList = providers.map(\.rawValue).joined(separator: ",")
        Self.logger.debug(
            """
            probe dispatch host=\(hostTag, privacy: .public) \
            providers=\(providerList, privacy: .public)
            """)

        Task { @MainActor [weak self] in
            var result: AgentUsageProbeResult?
            var busy = false
            do {
                let output = try await RemoteExecProbe.run(command, on: owner)
                result = AgentUsageProbeCommand.parse(output: output, nonce: nonce)
            } catch RemoteExecProbe.ProbeError.busy {
                busy = true
            } catch {
                Self.logger.error(
                    """
                    probe failed host=\(hostTag, privacy: .public) \
                    providers=\(providerList, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            guard let self else { return }
            self.probesInFlight.remove(hostKey)
            self.probesRerunPending.remove(hostKey)
            guard self.epoch == dispatchedEpoch, self.canWork else {
                // The epoch guard exists to stop a stale ANSWER being
                // applied, not to stop the next pass. Returning outright
                // stranded the tracker: a toggle flipped during a probe
                // left this host in-flight, so the re-enable's probe was
                // refused as a duplicate and queued as a rerun, and then
                // this completion consumed that rerun and exited. Nothing
                // remained to schedule and the footer stayed blank.
                if self.canWork { self.refresh() }
                return
            }
            if busy {
                self.deferProbes(hostKey: hostKey)
                return
            }
            self.applyProbeResult(result, hostKey: hostKey, providers: providers, now: Date())
            // A full pass covers both the fetches this probe unlocked and
            // any host that gained work mid-flight; failed hosts are held
            // back by their probe health, so this cannot loop.
            self.refresh()
        }
    }

    /// tssh's single probe slot was still held, usually by an Antigravity call
    /// that outlived its caller's deadline. Not a host failure: nothing ran.
    /// Both probes wait a short beat and try again, with no backoff.
    private func deferProbes(hostKey: String) {
        // Someone is watching a Refresh spinner, so retry sooner.
        let retry = refreshingProviders.isEmpty
            ? AgentUsageTuning.probeBusyRetry : AgentUsageTuning.probeBusyRetryManual
        probeDeferredUntil[hostKey] = Date().addingTimeInterval(retry)
        refresh()
    }

    private func probeDeferred(hostKey: String, now: Date) -> Bool {
        guard let until = probeDeferredUntil[hostKey] else { return false }
        if until <= now { probeDeferredUntil.removeValue(forKey: hostKey) }
        return until > now
    }

    /// Antigravity's own probe: its own deadline, output cap and backoff, so a
    /// slow host or Google outage never touches the other providers' probes.
    private func dispatchAntigravityProbe(
        hostKey: String,
        owner: Ghostty.TerminalView,
        now: Date
    ) {
        guard antigravityProbesInFlight.insert(hostKey).inserted else { return }
        var health = antigravityProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordStarted(now: now)
        antigravityProbeHealth[hostKey] = health

        let skipLocal = antigravitySkipLocalUntil[hostKey].map { $0 > now } ?? false
        let (command, nonce) = AgentUsageProbeCommand.command(
            providers: [.antigravity], pathPrefix: SSHConfig.remoteExecPathPrefix,
            antigravityRenewal: antigravityNeedsRenewal.contains(hostKey)
                && antigravityRenewalAllowed(hostKey: hostKey, now: now),
            antigravitySkipLocal: skipLocal)
        let dispatchedEpoch = epoch
        let hostTag = Self.tag(hostKey)

        Task { @MainActor [weak self] in
            var result: AgentUsageProbeResult?
            var busy = false
            do {
                let output = try await RemoteExecProbe.run(
                    command, on: owner,
                    timeout: AgentUsageTuning.antigravityProbeTimeout,
                    maxResponseBytes: AgentUsageTuning.antigravityProbeMaxBytes)
                result = AgentUsageProbeCommand.parse(output: output, nonce: nonce)
            } catch RemoteExecProbe.ProbeError.busy {
                busy = true
            } catch {
                Self.logger.error(
                    """
                    antigravity probe failed host=\(hostTag, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            guard let self else { return }
            self.antigravityProbesInFlight.remove(hostKey)
            // A launched `agy models` happened whatever becomes of this answer,
            // so its cooldown is recorded ahead of the publish guard.
            if result?.antigravityRenewed == true {
                self.antigravityRenewals[hostKey] = Date()
            }
            guard self.epoch == dispatchedEpoch, self.canWork else {
                if self.canWork { self.refresh() }
                return
            }
            if busy {
                self.deferProbes(hostKey: hostKey)
                return
            }
            let now = Date()
            let complete: Bool
            if let token = result?.antigravityToken {
                let digest = AgentUsageTokenDigest.of(token.accessToken)
                if self.antigravityRefusedDigests[hostKey]?.contains(digest) == true {
                    // Re-armed here: a desktop answer in between clears it.
                    self.antigravityNeedsRenewal.insert(hostKey)
                    complete = self.applyAntigravityReadout(
                        .signInExpired,
                        renewed: result?.antigravityRenewed ?? false,
                        skippedLocal: skipLocal,
                        hostKey: hostKey, now: now)
                } else {
                    // The pass below asks Google with it straight away.
                    self.antigravityTokens[hostKey] = (token, now)
                    self.antigravityStates.removeValue(forKey: hostKey)
                    complete = true
                }
            } else {
                complete = self.applyAntigravityReadout(
                    result?.readouts[.antigravity],
                    renewed: result?.antigravityRenewed ?? false,
                    skippedLocal: skipLocal,
                    hostKey: hostKey, now: now)
            }
            var health = self.antigravityProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
            if complete {
                health.recordSuccess()
            } else {
                health.recordFailure(
                    now: now,
                    baseDelay: AgentUsageTuning.probeBackoffBase,
                    maximumDelay: AgentUsageTuning.probeBackoffMax)
            }
            self.antigravityProbeHealth[hostKey] = health
            self.refresh()
        }
    }

    /// Asks Google from the app with the host's held sign-in. Anything short
    /// of fresh numbers drops the token, so the next pass probes the host
    /// again (desktop app first, then a re-read sign-in).
    private func dispatchAntigravityFetch(
        hostKey: String,
        token: AgentUsageAntigravityToken,
        now: Date
    ) {
        guard antigravityProbesInFlight.insert(hostKey).inserted else { return }
        var health = antigravityProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordStarted(now: now)
        antigravityProbeHealth[hostKey] = health
        let dispatchedEpoch = epoch
        let hostTag = Self.tag(hostKey)

        Task { @MainActor [weak self] in
            var payload: String?
            var refused = false
            do {
                payload = try await AgentUsageAPIClient.fetchAntigravityPayload(token)
            } catch AgentUsageAPIError.unauthorized {
                refused = true
            } catch {
                Self.logger.error("antigravity fetch failed host=\(hostTag, privacy: .public)")
            }
            guard let self else { return }
            self.antigravityProbesInFlight.remove(hostKey)
            guard self.epoch == dispatchedEpoch, self.canWork else {
                if self.canWork { self.refresh() }
                return
            }
            let now = Date()
            if refused {
                self.antigravityTokens.removeValue(forKey: hostKey)
                self.antigravityRefusedDigests[hostKey, default: []]
                    .insert(AgentUsageTokenDigest.of(token.accessToken))
                self.antigravityNeedsRenewal.insert(hostKey)
                // Probe now: it starts the renewal and reads the sign-in back.
                self.antigravityStates.removeValue(forKey: hostKey)
            } else {
                let skipping = self.antigravitySkipLocalUntil[hostKey].map { $0 > now } ?? false
                _ = self.applyAntigravityReadout(
                    payload.map { .payload($0) } ?? .unreadable(keychainLocked: false),
                    renewed: false, skippedLocal: skipping,
                    hostKey: hostKey, now: now)
                if self.antigravityStates[hostKey]?.status != .ok {
                    self.antigravityTokens.removeValue(forKey: hostKey)
                }
            }
            var health = self.antigravityProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
            health.recordSuccess()
            self.antigravityProbeHealth[hostKey] = health
            self.refresh()
        }
    }

    private func applyProbeResult(
        _ result: AgentUsageProbeResult?,
        hostKey: String,
        providers: [AgentUsageProvider],
        now: Date
    ) {
        var health = hostProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        // A missing section is a transport failure for that provider even
        // when the transport call "succeeded": truncation must back off,
        // not cache.
        var transportComplete = true

        for provider in providers {
            let key = AgentUsageHostCredentialKey(hostKey: hostKey, provider: provider)
            // Reads as: which of the script's terminal answers came back for
            // this provider. `missing` means the section was truncated.
            let readoutName: String = {
                switch result?.readouts[provider] {
                case .payload: return "payload"
                case .absent: return "absent"
                case .unreadable(keychainLocked: true): return "keychain-locked"
                case .unreadable(keychainLocked: false): return "unreadable"
                case .signInExpired: return "sign-in-expired"
                case .none: return "missing"
                }
            }()
            Self.logger.debug(
                """
                probe readout host=\(Self.tag(hostKey), privacy: .public) \
                provider=\(provider.rawValue, privacy: .public) \
                readout=\(readoutName, privacy: .public)
                """)

            // The oh-my-pi lane returns a finished usage report, not a
            // credential, so it short-circuits the whole credential path:
            // nothing to hold, nothing to digest, no 401 to handle, no fetch
            // to schedule. Keeping it out of `credentialStates` is what stops
            // the token machinery from ever seeing a lane that has no token.
            if provider.yieldsUsageReport {
                if case .payload(let json)? = result?.readouts[provider] {
                    switch AgentUsageOMPReport.parse(json, now: now) {
                    case .accounts(let snapshots) where !snapshots.isEmpty:
                        adoptOMPSnapshots(snapshots, hostKey: hostKey, now: now)
                        ompProbeStates[hostKey] = OMPProbeState(checkedAt: now, absent: false)
                    case .accounts:
                        // A VALID report with no accounts. `omp usage --json`
                        // writes this and exits 0 when nothing is signed in,
                        // so it is a real answer: drop the rows and take the
                        // stable-absence clock. Treating it as a failure kept
                        // the quota rows of accounts the user had logged out
                        // of, forever, and cycled the host through backoff.
                        dropOMPSnapshots(hostKey: hostKey)
                        ompProbeStates[hostKey] = OMPProbeState(checkedAt: now, absent: true)
                    case .malformed:
                        // Not JSON, or a shape we could not read. Keep the
                        // last good snapshot and let probe health retry.
                        transportComplete = false
                    }
                } else if case .none = result?.readouts[provider] {
                    // Section truncated. Deliberately does NOT stamp the
                    // clock: the host's probe health owns the backoff, and
                    // recording it as answered would delay the retry by a
                    // full interval.
                    transportComplete = false
                } else if case .absent? = result?.readouts[provider] {
                    // No omp on this host, or nothing signed into it. A
                    // stable fact: drop the rows and take the long TTL.
                    dropOMPSnapshots(hostKey: hostKey)
                    ompProbeStates[hostKey] = OMPProbeState(checkedAt: now, absent: true)
                } else {
                    // Unreadable: omp ran but stdout was not a report -- a
                    // wrapper script, a login banner, a partial write. That
                    // is not evidence the host has no accounts, so the last
                    // good snapshot stands and the host's probe health owns
                    // the retry. Grouping it with absence dropped live rows
                    // and then suppressed the retry for thirty minutes.
                    transportComplete = false
                }
                continue
            }

            switch result?.readouts[provider] {
            case .payload(let json):
                let adoption = adoptCredentials(json: json, for: key, now: now)
                Self.logger.debug(
                    """
                    creds host=\(Self.tag(hostKey), privacy: .public) \
                    provider=\(provider.rawValue, privacy: .public) \
                    -> \(String(describing: adoption), privacy: .public)
                    """)
                switch adoption {
                case .usable, .tokenUnusable:
                    // Both are complete answers. An expired token is NOT a
                    // transport failure: the account mapping was refreshed
                    // and the slot sits in .staleCredentials until the CLI
                    // writes a fresh token.
                    break
                case .unparseable:
                    // Malformed payload: retry with the host backoff rather
                    // than believing "absent". The account mapping is kept
                    // if one existed, so the row does not blink away.
                    transportComplete = false
                    heldTokens[key] = nil
                    if let accountKey = credentialStates[key]?.accountKey {
                        credentialStates[key] = .staleCredentials(
                            accountKey: accountKey, readAt: now)
                    } else {
                        credentialStates[key] = .unknown
                    }
                }
            case .absent:
                credentialStates[key] = .absent(
                    until: now.addingTimeInterval(AgentUsageTuning.absentCredentialTTL))
                heldTokens[key] = nil
            case .unreadable(let keychainLocked):
                // A complete answer: the command ran, the secret store said
                // no. Backing the HOST off here also delayed the other
                // provider's probe on the same machine, which has nothing
                // to do with this failure.
                credentialStates[key] = .unreadable(
                    keychainLocked: keychainLocked, checkedAt: now)
                heldTokens[key] = nil
            case .signInExpired:
                // Only the Antigravity section emits this, and it never
                // reaches here; treated as a failed read if it ever does.
                credentialStates[key] = .unreadable(keychainLocked: false, checkedAt: now)
                heldTokens[key] = nil
            case .none:
                transportComplete = false
            }
        }

        if transportComplete {
            health.recordSuccess()
        } else {
            health.recordFailure(
                now: now,
                baseDelay: AgentUsageTuning.probeBackoffBase,
                maximumDelay: AgentUsageTuning.probeBackoffMax)
        }
        hostProbeHealth[hostKey] = health
        revision &+= 1
    }

    private enum CredentialAdoption {
        case usable
        /// Parsed, account identified, but the token cannot back a fetch
        /// right now (expired on disk). The account mapping is recorded so
        /// the row keeps rendering its last snapshot.
        case tokenUnusable
        case unparseable
    }

    private func adoptCredentials(
        json: String,
        for key: AgentUsageHostCredentialKey,
        now: Date
    ) -> CredentialAdoption {
        let previousAccountKey = credentialStates[key]?.accountKey

        let accountKey: String
        var usable: Bool
        let token: HeldToken
        switch key.provider {
        case .claude:
            guard let credentials = ClaudeCredentials.parse(json: json) else {
                return .unparseable
            }
            // An expired token still names its account (the JWT does not
            // change identity), so the mapping is kept even when the token
            // itself is useless — an IDLE agent's CLI lets it lapse and
            // only refreshes once the user resumes.
            accountKey = AgentUsageAccountKey.claude(credentials, hostKey: key.hostKey)
            usable = !credentials.isExpired(now: now)
            token = .claude(credentials)
        case .codex:
            guard let credentials = CodexCredentials.parse(json: json) else {
                return .unparseable
            }
            accountKey = AgentUsageAccountKey.codex(credentials, hostKey: key.hostKey)
            usable = true
            token = .codex(credentials)
        case .copilot:
            // The payload carries every source on the host; pick the first
            // candidate the provider has not refused, so a revoked token
            // sitting in apps.json cannot shadow a good gh/keychain/env
            // one forever (the probe re-offers the same file every time).
            guard let credentials = CopilotCredentials.select(
                from: CopilotCredentials.parseAll(json: json),
                rejectedDigests: rejectedTokenDigests[key] ?? []) else {
                return .unparseable
            }
            // GitHub tokens carry no expiry metadata; a dead one surfaces
            // as a 401/404 and the digest blacklist below retires it.
            accountKey = AgentUsageAccountKey.copilot(credentials, hostKey: key.hostKey)
            usable = true
            token = .copilot(credentials)
        case .omp, .antigravity:
            // Unreachable by construction: applyProbeResult routes any lane
            // whose section returns a usage report to adoptOMPSnapshots
            // before reaching here, and that lane has no credential to adopt.
            // Reported as unparseable so a caller that ever loses the split
            // retries instead of caching a wrong answer.
            return .unparseable
        }

        // A token the provider already refused stays unusable until the host
        // hands us a DIFFERENT one; otherwise the re-probe that a 401
        // triggers would immediately re-arm the same failing request.
        // Rejections are never cleared just because a different token was
        // adopted — stale digests compare harmlessly, and clearing them is
        // what made rejected candidates come back (see the field comment).
        let digest = AgentUsageTokenDigest.of(token.accessToken)
        if rejectedTokenDigests[key]?.contains(digest) == true {
            usable = false
        }
        heldTokens[key] = usable ? token : nil
        credentialStates[key] = usable
            ? .held(accountKey: accountKey, readAt: now)
            : .staleCredentials(accountKey: accountKey, readAt: now)

        // First sight of this host slot (new, or returning after a prune):
        // re-verify rather than trust a retained snapshot. The account key
        // for a provider with no stable account id is derived from the HOST,
        // so a different login on the same machine lands on the same key and
        // would otherwise show the previous account's numbers until the
        // pacing floor expired. Keeps any 429 window intact.
        if previousAccountKey == nil {
            accountStates[accountKey]?.clearFetchFloor()
        }

        // The CLI rotated its token under us: carry the fetch clock so the
        // rotation cannot reset the rate-limit floor.
        if let previousAccountKey, previousAccountKey != accountKey {
            let stillHeldElsewhere = credentialStates.contains { otherKey, state in
                otherKey != key && state.accountKey == previousAccountKey
            }
            AgentUsageAccountMigration.migrate(
                states: &accountStates,
                from: previousAccountKey,
                to: accountKey,
                oldKeyStillHeldElsewhere: stillHeldElsewhere)
            persistAccounts()
        }
        return usable ? .usable : .tokenUnusable
    }

    // MARK: - Usage fetches

    private func dispatchDueFetches(presence: Presence, now: Date) {
        // One token per account: the most recently read among live hosts.
        // `sourceKey` rides along because a rejection belongs to the token
        // that was actually sent, not to the account as a whole.
        var tokens: [String: (
            token: HeldToken,
            provider: AgentUsageProvider,
            readAt: Date,
            sourceKey: AgentUsageHostCredentialKey
        )] = [:]
        for (key, state) in credentialStates {
            guard presence.hostProviders.contains(key),
                  case .held(let accountKey, let readAt) = state,
                  let held = heldTokens[key],
                  // A probe for this host is mid-flight and may be about to
                  // replace this very token, so anything sent now races it:
                  // the answer would come back describing a credential we no
                  // longer hold. Waiting one pass costs nothing, since the
                  // probe's completion runs another.
                  !probesInFlight.contains(key.hostKey)
            else { continue }
            if let existing = tokens[accountKey], existing.readAt >= readAt { continue }
            tokens[accountKey] = (held, key.provider, readAt, key)
        }

        for (accountKey, entry) in tokens {
            let floor = AgentUsageTuning.fetchFloor(entry.provider)
            var state = accountStates[accountKey] ?? AgentUsageAccountState()
            guard state.canFetch(now: now, floor: floor),
                  !fetchesInFlight.contains(accountKey) else { continue }

            state.recordFetchStarted(now: now)
            accountStates[accountKey] = state
            fetchesInFlight.insert(accountKey)
            persistAccounts()

            let dispatchedEpoch = epoch
            let sentDigest = AgentUsageTokenDigest.of(entry.token.accessToken)
            Task { @MainActor [weak self] in
                let outcome = await Self.fetch(entry.token, accountKey: accountKey)
                guard let self else { return }
                self.fetchesInFlight.remove(accountKey)
                guard self.epoch == dispatchedEpoch else { return }
                self.applyFetchOutcome(outcome, accountKey: accountKey,
                                       provider: entry.provider,
                                       sourceKey: entry.sourceKey,
                                       sentDigest: sentDigest, now: Date())
            }
        }
    }

    private enum FetchOutcome: Sendable {
        case snapshot(AgentUsageSnapshot)
        case unauthorized
        case rateLimited(retryAfterSeconds: Double?)
        case failed
    }

    private nonisolated static func fetch(
        _ token: HeldToken,
        accountKey: String
    ) async -> FetchOutcome {
        do {
            switch token {
            case .claude(let credentials):
                let windows = try await AgentUsageAPIClient.fetchClaudeUsage(
                    accessToken: credentials.accessToken)
                return .snapshot(AgentUsageSnapshot(
                    provider: .claude,
                    accountKey: accountKey,
                    planLabel: credentials.planLabel,
                    windows: windows,
                    creditsBalance: nil,
                    fetchedAt: Date()))
            case .codex(let credentials):
                let parsed = try await AgentUsageAPIClient.fetchCodexUsage(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID)
                let plan = parsed.planType.map {
                    $0.prefix(1).uppercased() + $0.dropFirst()
                } ?? credentials.planLabel
                return .snapshot(AgentUsageSnapshot(
                    provider: .codex,
                    accountKey: accountKey,
                    planLabel: plan,
                    windows: parsed.windows,
                    creditsBalance: parsed.creditsBalance,
                    fetchedAt: Date()))
            case .copilot(let credentials):
                let parsed = try await AgentUsageAPIClient.fetchCopilotUsage(
                    token: credentials.token)
                return .snapshot(AgentUsageSnapshot(
                    provider: .copilot,
                    accountKey: accountKey,
                    planLabel: parsed.planLabel,
                    windows: parsed.windows,
                    creditsBalance: nil,
                    fetchedAt: Date()))
            }
        } catch let error as AgentUsageAPIError {
            switch error {
            case .unauthorized: return .unauthorized
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .badResponse, .transport: return .failed
            }
        } catch {
            return .failed
        }
    }

    private func applyFetchOutcome(
        _ outcome: FetchOutcome,
        accountKey: String,
        provider: AgentUsageProvider,
        sourceKey: AgentUsageHostCredentialKey,
        sentDigest: String,
        now: Date
    ) {
        var state = accountStates[accountKey] ?? AgentUsageAccountState()
        // Whether the credential this answer describes is still the one we
        // hold. A rotation (or a prune, or a manual refresh) landing while
        // the request was out makes the answer describe something else:
        // crediting a 401 to the freshly installed token would blacklist a
        // good credential, and accepting a success could publish the old
        // account's numbers under a host-derived key after a sign-in change.
        let currentDigest = heldTokens[sourceKey].map {
            AgentUsageTokenDigest.of($0.accessToken)
        }
        let describesHeldToken = currentDigest == sentDigest

        switch outcome {
        case .snapshot(let snapshot):
            guard describesHeldToken else {
                // Nothing recorded, and the floor is dropped so the token we
                // now hold can answer for itself immediately.
                state.clearFetchFloor()
                accountStates[accountKey] = state
                Self.logger.debug(
                    """
                    discarded stale fetch provider=\(provider.rawValue, privacy: .public) \
                    reason=credential-changed
                    """)
                refresh(now: now)
                return
            }
            state.recordSuccess(snapshot)
        case .unauthorized:
            // The token went stale under us. Keep the snapshot AND the
            // host-to-account mapping — dropping the mapping unmapped the
            // row and blanked perfectly good numbers. A 401 from a RUNNING
            // claude/codex agent usually means its CLI already rotated the
            // token, so the slots go stale with an immediate re-probe
            // (distantPast skips the idle-retry interval); the account's own
            // 60s backoff is what prevents a fetch loop if the fresh token
            // 401s too. GitHub tokens never rotate on their own, so a
            // copilot slot re-probes once, finds the same rejected token
            // (kept unusable by its digest below), and settles into the
            // stale cadence showing "Sign-in expired" until the user
            // re-authenticates — the right behavior with no special case.
            // ONLY the credential that was actually sent. Invalidating every
            // host mapped to this account condemned tokens that were never
            // tried: a second machine holding a good token for the same
            // account was blacklisted alongside the bad one, killing the
            // fallback that would otherwise have answered on the next pass.
            //
            // Remember WHICH token was refused, too. Re-probing usually
            // finds the CLI has already rotated it, but when the host still
            // holds the same one, adopting it as usable let the 60s
            // unauthorized delay fire another doomed request every minute
            // instead of waiting out the stale cadence.
            state.recordUnauthorized(now: now)
            // Only when the refused credential is still the one on file. If
            // it was rotated out mid-request, the replacement is innocent
            // and must not inherit the rejection.
            if describesHeldToken {
                rejectedTokenDigests[sourceKey, default: []].insert(sentDigest)
                credentialStates[sourceKey] = .staleCredentials(
                    accountKey: accountKey, readAt: .distantPast)
                heldTokens[sourceKey] = nil
            }
            Self.logger.error(
                "usage fetch unauthorized provider=\(provider.rawValue, privacy: .public)")
        case .rateLimited(let retryAfterSeconds):
            state.recordRateLimited(retryAfterSeconds: retryAfterSeconds, now: now)
            Self.logger.error(
                "usage fetch rate-limited provider=\(provider.rawValue, privacy: .public)")
        case .failed:
            state.recordFailure(now: now)
            Self.logger.error(
                "usage fetch failed provider=\(provider.rawValue, privacy: .public)")
        }
        accountStates[accountKey] = state
        persistAccounts()
        revision &+= 1

        if case .unauthorized = outcome {
            // The slots for this account were just invalidated, so drive the
            // re-read directly. Leaving it to the scheduler meant a healthy
            // host (no probe-health retryAfter) contributed no deadline, and
            // usage could sit stalled until some unrelated lifecycle event.
            // The account's own 60s backoff is what stops a fetch loop here.
            refresh(now: now)
            return
        }

        let presence = livePresence()
        settleRefreshing(presence: presence)
        rescheduleTimer(presence: presence, now: now)
    }

    // MARK: - Scheduling

    /// Parks a single sleep on the earliest deadline: an account coming off
    /// its floor or 429 window, a credential TTL expiring, a stable-negative
    /// re-check. No deadlines, no timer, no idle wakeups.
    private func rescheduleTimer(presence: Presence, now: Date) {
        schedulerTask?.cancel()
        schedulerTask = nil
        guard canWork else { return }

        // The decision itself lives in AgentUsageSchedule, which is pure and
        // reachable by tests. Every scheduler bug this feature has had was
        // the same shape -- a past deadline for work that cannot currently
        // dispatch, which the 1s floor turns into a 1 Hz main-actor loop --
        // and it recurred because nothing could assert on it from here.
        let lanes = presence.hostProviders.map { key -> AgentUsageSchedule.Lane in
            let state = credentialStates[key]
            var fetchEligibleAt: Date?
            if case .held(let accountKey, _) = state, let account = accountStates[accountKey] {
                fetchEligibleAt = account.nextEligibleAt(
                    floor: AgentUsageTuning.fetchFloor(key.provider)) ?? now
            }
            var reportCheckedAt: Date?
            var reportInterval = AgentUsageTuning.ompFetchFloor
            if key.provider == .antigravity, let agy = antigravityStates[key.hostKey] {
                reportCheckedAt = agy.checkedAt
                reportInterval = agy.interval
            } else if key.provider == .omp, let omp = ompProbeStates[key.hostKey] {
                reportCheckedAt = omp.checkedAt
                reportInterval = omp.absent
                    ? AgentUsageTuning.absentCredentialTTL : AgentUsageTuning.ompFetchFloor
            }
            return AgentUsageSchedule.Lane(
                provider: key.provider,
                canProbe: presence.owners[key.hostKey] != nil,
                // Either probe holds the host: neither dispatches while the other runs.
                probeInFlight: probesInFlight.contains(key.hostKey)
                    || antigravityProbesInFlight.contains(key.hostKey),
                credential: state,
                hostRetryAfter: [
                    key.provider == .antigravity
                        ? antigravityProbeHealth[key.hostKey]?.retryAfter
                        : hostProbeHealth[key.hostKey]?.retryAfter,
                    probeDeferredUntil[key.hostKey],
                ].compactMap { $0 }.max(),
                reportCheckedAt: reportCheckedAt,
                reportInterval: reportInterval,
                holdsToken: heldTokens[key] != nil,
                fetchEligibleAt: fetchEligibleAt)
        }

        var outcome = AgentUsageSchedule.outcome(for: lanes, now: now)
        if outcome.needsReconnectRecheck {
            outcome.deadlines.append(
                now.addingTimeInterval(AgentUsageTuning.reconnectRecheckInterval))
        }

        guard let next = outcome.deadlines.min() else { return }
        let delay = max(next.timeIntervalSince(now), 1) * powerScale()
        schedulerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.schedulerTask = nil
            self?.refresh()
        }
    }

    /// Battery pressure stretches the wake cadence; it never shortens a
    /// floor (those are enforced per account regardless of when we wake).
    private func powerScale() -> Double {
        switch PowerManager.shared.tier {
        case .full: return 1.0
        case .reduced: return 1.5
        case .saver: return 3.0
        }
    }

    // MARK: - Persistence

    private static let accountStatesKey = "agentUsageAccountStates"

    private func loadPersistedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountStatesKey),
              let decoded = try? JSONDecoder().decode(
                [String: AgentUsageAccountState].self, from: data)
        else { return }
        accountStates = decoded
    }

    private func persistAccounts() {
        // Bounded: keep the most recently touched handful of accounts.
        if accountStates.count > 16 {
            let keep = accountStates
                .sorted {
                    ($0.value.snapshot?.fetchedAt ?? .distantPast)
                        > ($1.value.snapshot?.fetchedAt ?? .distantPast)
                }
                .prefix(16)
            accountStates = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        guard let data = try? JSONEncoder().encode(accountStates) else { return }
        UserDefaults.standard.set(data, forKey: Self.accountStatesKey)
    }
}
