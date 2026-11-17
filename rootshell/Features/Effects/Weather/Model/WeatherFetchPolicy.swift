// WeatherFetchPolicy.swift
// rootshell

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherTuning {
    static let baseInterval: TimeInterval = 45 * 60
    static let stableInterval: TimeInterval = 90 * 60
    /// MET Norway asks clients not to fetch on the hour; spread requests out.
    static let jitterWindow: TimeInterval = 6 * 60
    static let manualFloor: TimeInterval = 10 * 60
    static let manualRetryFloor: TimeInterval = 30
    static let backoffBase: TimeInterval = 2 * 60
    static let backoffMax: TimeInterval = 2 * 3600
    static let rateLimitFallback: TimeInterval = 15 * 60
    static let dailyCap = 40
}

/// Rate limits per provider (by raw value) that has a fallback, so the
/// fallback can keep refreshing while that provider's deadline stands.
nonisolated struct WeatherProviderBackoff: Codable, Equatable, Sendable {
    private(set) var until: [String: Date] = [:]

    /// The provider's deadline while it is still ahead.
    func waiting(_ provider: String, now: Date) -> Date? {
        until[provider].flatMap { $0 > now ? $0 : nil }
    }

    /// A 429 (or AccuWeather's 503) sets a deadline; anything else leaves it.
    mutating func record(_ error: Error, from provider: String, now: Date) {
        guard case WeatherFetchError.rateLimited(let seconds) = error else { return }
        let delay = seconds.flatMap { $0 > 0 ? $0 : nil } ?? WeatherTuning.rateLimitFallback
        until[provider] = now.addingTimeInterval(delay)
    }

    /// A new key brings its own allowance.
    mutating func clear(_ provider: String) {
        until[provider] = nil
    }

    mutating func prune(now: Date) {
        until = until.filter { $0.value > now }
    }
}

/// When the next request may go out. Codable so a relaunch keeps honouring
/// server expiry, rate limits, and backoff instead of fetching immediately.
nonisolated struct WeatherFetchPolicy: Codable, Equatable, Sendable {
    enum RetryCause: String, Codable, Sendable {
        case rateLimit, failure
    }

    private(set) var lastFetchStartedAt: Date?
    private(set) var lastSuccessAt: Date?
    private(set) var nextDueAt: Date?
    /// The source's `Expires`; never fetched before, even manually.
    private(set) var earliestAllowedAt: Date?
    private(set) var retryAfter: Date?
    private(set) var retryCause: RetryCause?
    private(set) var consecutiveFailures = 0
    private(set) var unchangedStreak = 0
    private(set) var dayStamp = 0
    private(set) var fetchesToday = 0

    mutating func recordStarted(now: Date) {
        lastFetchStartedAt = now
        let day = Self.day(now)
        if day != dayStamp { dayStamp = day; fetchesToday = 0 }
        fetchesToday += 1
    }

    /// `jitter` is a unit random value, injected so tests are deterministic.
    mutating func recordSuccess(now: Date, expiresAt: Date?, changed: Bool, jitter: Double) {
        lastSuccessAt = now
        consecutiveFailures = 0
        retryAfter = nil
        retryCause = nil
        unchangedStreak = changed ? 0 : unchangedStreak + 1
        earliestAllowedAt = expiresAt.flatMap { $0 > now ? $0 : nil }
        let interval = unchangedStreak >= 2 ? WeatherTuning.stableInterval : WeatherTuning.baseInterval
        let base = max(now.addingTimeInterval(interval), earliestAllowedAt ?? now)
        nextDueAt = base.addingTimeInterval(min(max(jitter, 0), 1) * WeatherTuning.jitterWindow)
    }

    /// 429. A missing or non-positive `Retry-After` uses a conservative fallback.
    mutating func recordRateLimited(retryAfterSeconds: Double?, now: Date) {
        consecutiveFailures += 1
        let delay = retryAfterSeconds.flatMap { $0 > 0 ? $0 : nil } ?? WeatherTuning.rateLimitFallback
        retryAfter = now.addingTimeInterval(delay)
        retryCause = .rateLimit
    }

    mutating func recordFailure(now: Date) {
        consecutiveFailures += 1
        let exponent = Double(min(consecutiveFailures - 1, 10))
        let delay = min(WeatherTuning.backoffBase * pow(2, exponent), WeatherTuning.backoffMax)
        retryAfter = now.addingTimeInterval(delay)
        retryCause = .failure
    }

    /// A new location makes the old schedule and expiry meaningless, but a
    /// server rate limit still stands.
    mutating func invalidateLocation() {
        nextDueAt = nil
        earliestAllowedAt = nil
        unchangedStreak = 0
        if retryCause == .failure { retryAfter = nil; retryCause = nil; consecutiveFailures = 0 }
    }

    func nextDue(now: Date) -> Date {
        var due = nextDueAt ?? now
        if let retryAfter { due = max(due, retryAfter) }
        if let earliestAllowedAt { due = max(due, earliestAllowedAt) }
        if Self.day(now) == dayStamp && fetchesToday >= WeatherTuning.dailyCap {
            due = max(due, Self.startOfNextDay(now))
        }
        return due
    }

    /// When a person may ask for a refresh. A real 429 is never overridden.
    func manualAvailableAt(now: Date) -> Date {
        var available = now
        if retryCause == .rateLimit, let retryAfter { available = max(available, retryAfter) }
        if let earliestAllowedAt { available = max(available, earliestAllowedAt) }
        if let lastSuccessAt { available = max(available, lastSuccessAt.addingTimeInterval(WeatherTuning.manualFloor)) }
        if let lastFetchStartedAt { available = max(available, lastFetchStartedAt.addingTimeInterval(WeatherTuning.manualRetryFloor)) }
        if Self.day(now) == dayStamp && fetchesToday >= WeatherTuning.dailyCap {
            available = max(available, Self.startOfNextDay(now))
        }
        return available
    }

    mutating func requestManualRefresh(now: Date) -> Bool {
        guard manualAvailableAt(now: now) <= now else { return false }
        nextDueAt = now
        if retryCause == .failure { retryAfter = nil; retryCause = nil }
        return true
    }

    private static func day(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
    private static func startOfNextDay(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(day(date) + 1) * 86_400)
    }
}
#endif
