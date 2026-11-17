// WeatherSourceRouter.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import os

/// Per-source bookkeeping that survives relaunch: NWS grid lookups (and
/// points NWS does not cover), MET Norway's conditional-request headers,
/// AccuWeather location keys, and when "now" was last refreshed.
nonisolated struct WeatherSourceState: Codable, Equatable, Sendable {
    var nwsPoints: [String: NWSPointInfo] = [:]
    var nwsUncovered: [String: Date] = [:]
    var metCoordinate: WeatherCoordinate?
    var metValidator: WeatherHTTPValidator?
    var observationCheckedAt: Date?
    /// They name places, not accounts, so a new key keeps them.
    var accuWeatherLocations: [String: AccuWeatherLocation] = [:]
    var nowcastUncovered: [String: Date] = [:]
    /// Why the chosen provider failed on the last forecast fetch.
    var issue: WeatherProviderIssue?
    var backoff = WeatherProviderBackoff()

    static let nowcastRetry: TimeInterval = 86_400

    init() {}

    /// Missing fields keep their defaults, so adding one keeps the cache.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nwsPoints = try c.decodeIfPresent([String: NWSPointInfo].self, forKey: .nwsPoints) ?? [:]
        nwsUncovered = try c.decodeIfPresent([String: Date].self, forKey: .nwsUncovered) ?? [:]
        metCoordinate = try c.decodeIfPresent(WeatherCoordinate.self, forKey: .metCoordinate)
        metValidator = try c.decodeIfPresent(WeatherHTTPValidator.self, forKey: .metValidator)
        observationCheckedAt = try c.decodeIfPresent(Date.self, forKey: .observationCheckedAt)
        accuWeatherLocations = try c.decodeIfPresent([String: AccuWeatherLocation].self, forKey: .accuWeatherLocations) ?? [:]
        nowcastUncovered = try c.decodeIfPresent([String: Date].self, forKey: .nowcastUncovered) ?? [:]
        issue = try? c.decodeIfPresent(WeatherProviderIssue.self, forKey: .issue)
        backoff = (try? c.decodeIfPresent(WeatherProviderBackoff.self, forKey: .backoff)) ?? WeatherProviderBackoff()
    }

    mutating func prune(now: Date) {
        nwsPoints = nwsPoints.filter { now.timeIntervalSince($0.value.resolvedAt) < NWSPointInfo.lifetime }
        nwsUncovered = nwsUncovered.filter { now.timeIntervalSince($0.value) < NWSPointInfo.lifetime }
        accuWeatherLocations = accuWeatherLocations.filter { now.timeIntervalSince($0.value.resolvedAt) < AccuWeatherLocation.lifetime }
        nowcastUncovered = nowcastUncovered.filter { now.timeIntervalSince($0.value) < Self.nowcastRetry }
        backoff.prune(now: now)
    }
}

nonisolated enum WeatherFetchOutcome: Sendable {
    case updated(WeatherSnapshot)
    case notModified(expiresAt: Date?)
}

/// The chosen provider first, then the free default if it fails or has no
/// key, so a bad key or an outage never freezes the sky.
nonisolated enum WeatherSourceRouter {
    static let observationInterval: TimeInterval = 15 * 60

    /// Nil while a provider that needs a key has none. Only the chosen
    /// provider gets the person's key and User-Agent.
    static func provider(_ id: WeatherProviderID, request: WeatherProviderRequest) -> (any WeatherProvider)? {
        let chosen = id == request.choice.provider
        switch id {
        case .openMeteo:
            return OpenMeteoWeatherProvider()
        case .accuWeather:
            guard chosen, let key = request.apiKey else { return nil }
            return AccuWeatherProvider(apiKey: key, userAgent: request.choice.userAgent)
        }
    }

    static func fetch(_ coordinate: WeatherCoordinate, request: WeatherProviderRequest, previous: WeatherSnapshot?,
                      state: inout WeatherSourceState, now: Date) async throws -> WeatherFetchOutcome {
        state.prune(now: now)
        let chosen = request.choice.provider
        var chain: [any WeatherProvider] = []
        state.issue = nil
        if state.backoff.waiting(chosen.rawValue, now: now) != nil {
            state.issue = .limitReached
        } else if let provider = provider(chosen, request: request) {
            chain.append(provider)
        } else {
            state.issue = .missingKey
        }
        if chosen != .default, let fallback = provider(.default, request: request) { chain.append(fallback) }
        var failure: Error = WeatherFetchError.unusable
        for provider in chain {
            do {
                let outcome = try await provider.fetch(coordinate, previous: previous, state: &state, now: now)
                // An optional request in the round can still have hit a rate limit.
                if provider.id == chosen, state.backoff.waiting(chosen.rawValue, now: now) != nil { state.issue = .limitReached }
                return outcome
            } catch {
                try Task.checkCancellation()
                Ghostty.logger.info("Live Weather: \(provider.id.rawValue, privacy: .public) failed (\(String(describing: error), privacy: .public))")
                if provider.id == chosen {
                    state.issue = WeatherProviderIssue(error)
                    if chosen != .default { state.backoff.record(error, from: chosen.rawValue, now: now) }
                }
                failure = error
            }
        }
        // The default's own rate limit reaches the store's fetch policy instead.
        throw failure
    }

    /// When the snapshot's own provider next refreshes "now", never before its rate limit ends.
    static func observationDue(_ snapshot: WeatherSnapshot, request: WeatherProviderRequest,
                               state: WeatherSourceState, now: Date) -> Date? {
        let id = snapshot.source.provider
        guard let due = provider(id, request: request)?.observationDue(for: snapshot, state: state) else { return nil }
        return max(due, state.backoff.waiting(id.rawValue, now: now) ?? due)
    }

    static func observe(_ snapshot: WeatherSnapshot, request: WeatherProviderRequest, state: inout WeatherSourceState,
                        now: Date) async -> WeatherNowUpdate? {
        let id = snapshot.source.provider
        guard state.backoff.waiting(id.rawValue, now: now) == nil, let provider = provider(id, request: request) else { return nil }
        do {
            return try await provider.observe(snapshot, state: &state, now: now)
        } catch {
            if id != .default { state.backoff.record(error, from: id.rawValue, now: now) }
            return nil
        }
    }
}
#endif
