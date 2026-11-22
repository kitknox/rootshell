//
//  AgentUsageRefreshState.swift
//  rootshell
//
//  Pure cache and admission policy for subscription usage. Two keyspaces on
//  purpose: credentials are a property of the HOST (hostKey, provider),
//  usage is a property of the ACCOUNT (accountKey) — so one account signed
//  in on two hosts polls its rate-limited endpoint once, not twice.
//
//  Host probe admission reuses AgentRepositoryHostProbeHealth unchanged.
//  Kept free of UIKit and connection types for tests/agent-usage/run.sh.
//

import Foundation

/// One provider's credential slot on one machine.
nonisolated struct AgentUsageHostCredentialKey: Hashable, Sendable {
    let hostKey: String
    let provider: AgentUsageProvider
}

/// What the last credential probe of a host said, minus the token itself —
/// tokens stay in AgentUsageCenter memory, never in policy state.
nonisolated enum AgentUsageCredentialState: Equatable, Sendable {
    case unknown
    /// Stable negative: no credentials on this host. Re-checked after `until`.
    case absent(until: Date)
    /// Credentials exist but could not be read (most often a Mac refusing
    /// its keychain to a detached SSH/tsshd session). A COMPLETE answer,
    /// not a transport failure: the command ran fine, so the host must not
    /// be backed off — that would also delay the other provider on the same
    /// host. Re-checked on its own interval instead.
    case unreadable(keychainLocked: Bool, checkedAt: Date)
    /// A token was read and parsed; `readAt` drives the periodic re-read.
    case held(accountKey: String, readAt: Date)
    /// The account is known but the token is unusable right now: expired on
    /// disk (an IDLE agent makes no API calls, so its CLI never refreshes),
    /// or rejected with a 401. Keeping the account mapping is what keeps
    /// the last snapshot on screen — display must never require a live
    /// token, only a known account. Re-probed every `staleCredentialRetry`
    /// until the CLI writes a fresh token.
    case staleCredentials(accountKey: String, readAt: Date)

    /// The account this host slot maps to, however the token is doing.
    var accountKey: String? {
        switch self {
        case .held(let accountKey, _), .staleCredentials(let accountKey, _):
            return accountKey
        case .unknown, .absent, .unreadable:
            return nil
        }
    }
}

/// Per-account fetch policy: the thing that protects the rate-limited usage
/// endpoints. Stale-while-revalidate — the snapshot is never discarded, only
/// superseded. Codable so last-known usage and, critically, the rate-limit
/// clock survive relaunch.
nonisolated struct AgentUsageAccountState: Equatable, Sendable, Codable {
    /// Why `retryAfter` is set. Only `.rateLimit` is the provider telling us
    /// to back off; the others are our own caution, and a person asking for
    /// a retry should be allowed to override those.
    enum RetryCause: String, Equatable, Sendable, Codable {
        case rateLimit
        case unauthorized
        case failure
    }

    var snapshot: AgentUsageSnapshot?
    private(set) var lastFetchStartedAt: Date?
    private(set) var retryAfter: Date?
    private(set) var retryCause: RetryCause?
    private(set) var consecutiveFailures = 0

    mutating func recordFetchStarted(now: Date) {
        lastFetchStartedAt = now
    }

    mutating func recordSuccess(_ snapshot: AgentUsageSnapshot) {
        self.snapshot = snapshot
        consecutiveFailures = 0
        retryAfter = nil
        retryCause = nil
    }

    /// 401/403: the token went stale under us. The snapshot stays (numbers a
    /// few minutes old beat a blank), and a short backoff covers the gap
    /// until the host re-probe delivers a fresh token.
    mutating func recordUnauthorized(now: Date) {
        consecutiveFailures += 1
        retryAfter = now.addingTimeInterval(AgentUsageTuning.unauthorizedRetryDelay)
        retryCause = .unauthorized
    }

    /// 429. `retryAfterSeconds` ≤ 0 is rejected deliberately: the Claude
    /// endpoint has been observed sending `Retry-After: 0` while continuing
    /// to 429, and honoring it re-hammers a throttled backend.
    mutating func recordRateLimited(retryAfterSeconds: Double?, now: Date) {
        consecutiveFailures += 1
        let delay: TimeInterval
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            delay = retryAfterSeconds
        } else {
            delay = AgentUsageTuning.rateLimitFallback
        }
        retryAfter = now.addingTimeInterval(delay)
        retryCause = .rateLimit
    }

    /// Network or parse failure: exponential backoff, capped.
    mutating func recordFailure(now: Date) {
        consecutiveFailures += 1
        let exponent = min(consecutiveFailures - 1, 8)
        let delay = min(
            AgentUsageTuning.fetchBackoffBase * pow(2, Double(exponent)),
            AgentUsageTuning.fetchBackoffMax)
        retryAfter = now.addingTimeInterval(delay)
        retryCause = .failure
    }

    /// Drops the pacing floor, deliberately KEEPING `retryAfter`: skipping
    /// our own cadence is fine, hammering an endpoint that just answered
    /// 429 is how an hour-long lockout gets earned.
    mutating func clearFetchFloor() {
        lastFetchStartedAt = nil
    }

    /// A person pressed Refresh. Drops our pacing floor, and also drops a
    /// backoff we imposed ourselves (a network blip, a rejected token) since
    /// retrying those is exactly what they asked for and costs the provider
    /// one request. A real 429 still stands: only the server can lift that.
    mutating func prepareForManualRefresh() {
        lastFetchStartedAt = nil
        if retryCause != .rateLimit {
            retryAfter = nil
            retryCause = nil
        }
    }

    func canFetch(now: Date, floor: TimeInterval) -> Bool {
        if let lastFetchStartedAt, now.timeIntervalSince(lastFetchStartedAt) < floor {
            return false
        }
        if let retryAfter, now < retryAfter { return false }
        return true
    }

    /// When this account next becomes fetchable — the scheduler's deadline.
    /// nil means "immediately".
    func nextEligibleAt(floor: TimeInterval) -> Date? {
        var candidates: [Date] = []
        if let lastFetchStartedAt { candidates.append(lastFetchStartedAt.addingTimeInterval(floor)) }
        if let retryAfter { candidates.append(retryAfter) }
        return candidates.max()
    }

    /// Old enough for the subtle staleness cue: past two fetch cycles.
    func isStale(now: Date, floor: TimeInterval) -> Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.fetchedAt) >= 2 * floor
    }

    /// Component-wise conservative merge of two histories for the same
    /// underlying account: the later clock wins, the fresher snapshot wins.
    mutating func adoptConservativeClock(from other: AgentUsageAccountState) {
        lastFetchStartedAt = laterOf(lastFetchStartedAt, other.lastFetchStartedAt)
        // Deadline and cause move TOGETHER. Taking the later deadline while
        // keeping whatever cause was already here mislabelled the result
        // both ways: a 429 window wearing a `.failure` label could be swept
        // aside by a manual refresh, and an ordinary failure wearing
        // `.rateLimit` blocked one that should have been allowed.
        if let theirs = other.retryAfter, theirs > (retryAfter ?? .distantPast) {
            retryAfter = theirs
            retryCause = other.retryCause
        }
        consecutiveFailures = max(consecutiveFailures, other.consecutiveFailures)
        if let theirs = other.snapshot {
            if let ours = snapshot, ours.fetchedAt >= theirs.fetchedAt { } else {
                snapshot = theirs
            }
        }
    }

    private func laterOf(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }
}

/// Carries the rate-limit clock across a token rotation. The CLI refreshes
/// its own credentials, which changes a hash-fallback account key; without
/// this, every rotation would reset the fetch floor and 429 window.
nonisolated enum AgentUsageAccountMigration {
    static func migrate(
        states: inout [String: AgentUsageAccountState],
        from oldKey: String,
        to newKey: String,
        oldKeyStillHeldElsewhere: Bool
    ) {
        guard oldKey != newKey, !oldKeyStillHeldElsewhere,
              let old = states.removeValue(forKey: oldKey) else { return }
        if var merged = states[newKey] {
            merged.adoptConservativeClock(from: old)
            states[newKey] = merged
        } else {
            states[newKey] = old
        }
    }
}

nonisolated enum AgentUsageTuning {
    /// Claude's oauth/usage endpoint hands out hour-long 429 windows to
    /// chatty clients; 15 minutes matches its observed tolerance.
    static let claudeFetchFloor: TimeInterval = 15 * 60
    static let codexFetchFloor: TimeInterval = 5 * 60
    /// Standard GitHub API limits are generous; matches codex.
    static let copilotFetchFloor: TimeInterval = 5 * 60
    /// Applied when a 429 carries no usable Retry-After.
    static let rateLimitFallback: TimeInterval = 5 * 60
    static let unauthorizedRetryDelay: TimeInterval = 60
    static let fetchBackoffBase: TimeInterval = 30
    static let fetchBackoffMax: TimeInterval = 15 * 60
    /// How long a held token is trusted before the host is re-read.
    static let credentialTTL: TimeInterval = 30 * 60
    /// Re-probe cadence while a host's credentials are expired or 401'd.
    /// One cheap exec per interval; the token only recovers when the user
    /// resumes the agent and its CLI refreshes itself.
    static let staleCredentialRetry: TimeInterval = 5 * 60
    /// Re-check cadence for credentials that exist but cannot be read. A
    /// locked keychain usually stays locked for the life of the connection,
    /// so this is deliberately lazy.
    static let unreadableRetry: TimeInterval = 10 * 60
    /// How long "no credentials on this host" is believed.
    static let absentCredentialTTL: TimeInterval = 30 * 60
    static let probeBackoffBase: TimeInterval = 30
    static let probeBackoffMax: TimeInterval = 15 * 60
    /// Lets a freshly-connected session settle before the first probe.
    static let presenceDebounce: TimeInterval = 2.0
    /// How often to look again at a live host whose session cannot carry a
    /// probe yet. Slow on purpose: reconnects are event-driven, and this is
    /// only the backstop that keeps an unreachable host from either
    /// spinning the scheduler or being forgotten until something else moves.
    static let reconnectRecheckInterval: TimeInterval = 30

    /// oh-my-pi answers from its own five-minute cache (USAGE_REPORT_TTL_MS),
    /// so polling faster than that only re-reads the same numbers; polling
    /// slower would leave ours staler than the CLI's own display.
    static let ompFetchFloor: TimeInterval = 5 * 60

    /// Antigravity's quota is asked on the host each probe, so the probe
    /// cadence is the fetch cadence.
    static let antigravityFetchFloor: TimeInterval = 5 * 60
    /// Between background `agy models` renewals on one host. It is slow, and
    /// a renewed sign-in lasts about an hour.
    static let antigravityRenewalCooldown: TimeInterval = 30 * 60
    /// Re-probe after a renewal was started, to pick up the new token.
    static let antigravityRenewalRecheck: TimeInterval = 90
    /// Antigravity probes run on their own: the desktop scan stops calling
    /// after 10 s, then a keychain read, plus slack for reads and the link.
    static let antigravityProbeTimeout: TimeInterval = 40
    static let antigravityProbeMaxBytes = 1024 * 1024
    /// After the desktop app answered with nothing usable, how long the probe
    /// asks Google directly before trying the app again.
    static let antigravitySkipLocalDuration: TimeInterval = 30 * 60
    /// How long a Google sign-in read from the host is reused in the app
    /// before the host is asked again, so an account switch there shows.
    static let antigravityTokenReuse: TimeInterval = 10 * 60
    /// Wait before retrying a probe that found tssh's probe slot occupied.
    static let probeBusyRetry: TimeInterval = 10
    /// The same wait while a manual Refresh is pending.
    static let probeBusyRetryManual: TimeInterval = 2

    static func fetchFloor(_ provider: AgentUsageProvider) -> TimeInterval {
        switch provider {
        case .claude: return claudeFetchFloor
        case .codex: return codexFetchFloor
        case .copilot: return copilotFetchFloor
        case .omp: return ompFetchFloor
        case .antigravity: return antigravityFetchFloor
        }
    }
}

/// Pure deadline arithmetic for the refresh scheduler.
///
/// Extracted from `AgentUsageCenter.rescheduleTimer` because that file
/// imports UIKit and so cannot be reached by the test harness. Every bug
/// this scheduler has produced has been the same shape -- a deadline that is
/// already in the past for work that cannot currently dispatch, which the
/// timer's one-second floor turns into a 1 Hz main-actor loop -- and it kept
/// recurring because no test could see it. The decision now lives here and
/// is asserted exhaustively over the lane states.
nonisolated enum AgentUsageSchedule {

    /// Everything about one (host, provider) lane the deadline depends on.
    struct Lane: Sendable {
        var provider: AgentUsageProvider
        /// A live session on this host can currently carry a probe.
        var canProbe: Bool
        /// A probe for this HOST is already running. Probes batch every due
        /// provider, and neither a probe nor a fetch dispatches for a host
        /// with one in flight.
        var probeInFlight: Bool
        var credential: AgentUsageCredentialState?
        var hostRetryAfter: Date?
        /// Report lanes only: when the host last answered, and how long that
        /// answer stands before the next probe.
        var reportCheckedAt: Date?
        var reportInterval: TimeInterval = AgentUsageTuning.ompFetchFloor
        /// A fetch needs a token, not a probe-capable session.
        var holdsToken: Bool = false
        var fetchEligibleAt: Date?

        init(provider: AgentUsageProvider, canProbe: Bool, probeInFlight: Bool = false,
             credential: AgentUsageCredentialState? = nil, hostRetryAfter: Date? = nil,
             reportCheckedAt: Date? = nil,
             reportInterval: TimeInterval = AgentUsageTuning.ompFetchFloor,
             holdsToken: Bool = false, fetchEligibleAt: Date? = nil) {
            self.provider = provider
            self.canProbe = canProbe
            self.probeInFlight = probeInFlight
            self.credential = credential
            self.hostRetryAfter = hostRetryAfter
            self.reportCheckedAt = reportCheckedAt
            self.reportInterval = reportInterval
            self.holdsToken = holdsToken
            self.fetchEligibleAt = fetchEligibleAt
        }
    }

    struct Outcome: Equatable, Sendable {
        var deadlines: [Date] = []
        /// A host that lost probe capability and has due work. Gets one slow
        /// recheck rather than a deadline it cannot act on.
        var needsReconnectRecheck = false
    }

    static func outcome(for lanes: [Lane], now: Date) -> Outcome {
        var result = Outcome()
        for lane in lanes {
            // Host-wide, above everything: work cannot dispatch for this host
            // and none of the state feeding the deadlines below moves until
            // the probe completes, so any deadline computed here is both
            // unactionable and permanently due. Completion calls refresh().
            if lane.probeInFlight { continue }

            if lane.provider.yieldsUsageReport {
                guard let checkedAt = lane.reportCheckedAt else {
                    if lane.canProbe, let retry = lane.hostRetryAfter {
                        result.deadlines.append(retry)
                    }
                    continue
                }
                let due = checkedAt.addingTimeInterval(lane.reportInterval)
                if lane.canProbe {
                    // Whichever boundary is later: a failed probe keeps the
                    // old checkedAt, so `due` is already past and only the
                    // host backoff describes when a retry may actually run.
                    result.deadlines.append(max(due, lane.hostRetryAfter ?? due))
                } else if now >= due {
                    result.needsReconnectRecheck = true
                }
                continue
            }

            if !lane.canProbe, lane.credential != nil,
               needsProbe(lane.credential, now: now) {
                result.needsReconnectRecheck = true
            }

            // Every PROBE deadline is clamped to the host's retry boundary.
            // A failed probe leaves the credential timestamp untouched, so
            // its deadline is already past while `refresh()` refuses to
            // dispatch -- and rescheduleTimer turns a past deadline into its
            // one-second minimum. Only the report lane and the no-state
            // branch accounted for this; the four known credential states
            // did not, so an ordinary failed native probe looped until the
            // backoff expired.
            //
            // FETCH eligibility is deliberately NOT clamped: dispatchDueFetches
            // gates on probes in flight, never on probe backoff, so a held
            // token can still service a usage fetch while probing is backed
            // off.
            func probeDeadline(_ due: Date) -> Date {
                max(due, lane.hostRetryAfter ?? due)
            }

            switch lane.credential {
            case .none, .unknown:
                if lane.canProbe, let retry = lane.hostRetryAfter {
                    result.deadlines.append(retry)
                }
            case .unreadable(_, let checkedAt):
                if lane.canProbe {
                    result.deadlines.append(probeDeadline(
                        checkedAt.addingTimeInterval(AgentUsageTuning.unreadableRetry)))
                }
            case .absent(let until):
                if lane.canProbe { result.deadlines.append(probeDeadline(until)) }
            case .staleCredentials(_, let readAt):
                if lane.canProbe {
                    result.deadlines.append(probeDeadline(
                        readAt.addingTimeInterval(AgentUsageTuning.staleCredentialRetry)))
                }
            case .held(_, let readAt):
                if lane.canProbe {
                    result.deadlines.append(probeDeadline(
                        readAt.addingTimeInterval(AgentUsageTuning.credentialTTL)))
                }
                // Only while a token is genuinely held: a manual refresh
                // drops the token while leaving the slot `.held`, and an
                // immediately-eligible fetch nothing can dispatch was one of
                // the earlier 1 Hz loops.
                if lane.holdsToken, let eligible = lane.fetchEligibleAt {
                    result.deadlines.append(eligible)
                }
            }
        }
        return result
    }

    private static func needsProbe(_ state: AgentUsageCredentialState?, now: Date) -> Bool {
        switch state {
        case .none, .unknown: return true
        case .unreadable(_, let checkedAt):
            return now.timeIntervalSince(checkedAt) >= AgentUsageTuning.unreadableRetry
        case .absent(let until): return now >= until
        case .held(_, let readAt):
            return now.timeIntervalSince(readAt) >= AgentUsageTuning.credentialTTL
        case .staleCredentials(_, let readAt):
            return now.timeIntervalSince(readAt) >= AgentUsageTuning.staleCredentialRetry
        }
    }
}
