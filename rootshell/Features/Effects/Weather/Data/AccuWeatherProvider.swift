// AccuWeatherProvider.swift
// rootshell

#if !CHINA_BUILD
import Foundation

/// AccuWeather's key for a place, looked up once from its coordinate.
nonisolated struct AccuWeatherLocation: Codable, Equatable, Sendable {
    var key: String
    var resolvedAt: Date

    static let lifetime: TimeInterval = 30 * 86_400
}

/// AccuWeather with the person's key. Its current conditions are observed
/// everywhere, not only near US stations, so they are both the snapshot's
/// "now" and its observation, refreshed every 15 minutes. MinuteCast adds
/// minute-by-minute precipitation while there is any about.
nonisolated struct AccuWeatherProvider: WeatherProvider {
    private let client: AccuWeatherClient

    init(apiKey: String, userAgent: String?) {
        client = AccuWeatherClient(apiKey: apiKey, userAgent: userAgent)
    }

    var id: WeatherProviderID { .accuWeather }

    func fetch(_ coordinate: WeatherCoordinate, previous: WeatherSnapshot?, state: inout WeatherSourceState,
               now: Date) async throws -> WeatherFetchOutcome {
        let location = try await locationKey(coordinate, state: &state, now: now)
        async let observed = Self.attempt { try await client.currentConditions(locationKey: location) }
        let forecast = await Self.attempt { try await client.hourly(locationKey: location, now: now) }
        // Settled before the forecast can throw, so its rate limit is kept either way.
        let conditions = settle(await observed, state: &state, now: now)
        let hourly = try forecast.get()
        // A stale report would otherwise rule the first half hour, since fetchedAt is now.
        let report = WeatherTimeline.fresh(conditions?.sample, at: now)
        let forecastNow: WeatherSample? = hourly.last { $0.date <= now } ?? hourly.first
        guard let current = report ?? forecastNow else { throw WeatherFetchError.unusable }
        var snapshot = WeatherSnapshot(
            coordinate: coordinate, source: .accuWeather, current: current,
            hourly: Array(hourly.filter { $0.date > current.date }.prefix(24)), fetchedAt: now, expiresAt: nil,
            placeName: nil, observation: report, link: conditions?.link)
        state.observationCheckedAt = now
        // Decided on the new forecast, so a dry day costs no MinuteCast request.
        snapshot.nowcast = await nowcast(for: snapshot, state: &state, now: now)
        return .updated(snapshot)
    }

    func observationDue(for snapshot: WeatherSnapshot, state: WeatherSourceState) -> Date? {
        (state.observationCheckedAt ?? .distantPast).addingTimeInterval(WeatherSourceRouter.observationInterval)
    }

    func observe(_ snapshot: WeatherSnapshot, state: inout WeatherSourceState, now: Date) async throws -> WeatherNowUpdate? {
        state.observationCheckedAt = now
        guard let location = state.accuWeatherLocations[snapshot.coordinate.key]?.key else { return nil }
        let conditions = settle(await Self.attempt { try await client.currentConditions(locationKey: location) },
                                state: &state, now: now)
        let report = WeatherTimeline.fresh(conditions?.sample, at: now)
        var latest = snapshot
        if let report { latest.observation = report }
        let minutes = await nowcast(for: latest, state: &state, now: now)
        guard report != nil || minutes != nil else { return nil }
        return WeatherNowUpdate(observation: report, nowcast: minutes)
    }

    private func locationKey(_ coordinate: WeatherCoordinate, state: inout WeatherSourceState, now: Date) async throws -> String {
        if let cached = state.accuWeatherLocations[coordinate.key] { return cached.key }
        let key = try await client.locationKey(for: coordinate)
        state.accuWeatherLocations[coordinate.key] = AccuWeatherLocation(key: key, resolvedAt: now)
        return key
    }

    /// Nil when it isn't worth a request or MinuteCast has nothing; places it
    /// doesn't cover are skipped for a day.
    private func nowcast(for snapshot: WeatherSnapshot, state: inout WeatherSourceState, now: Date) async -> WeatherNowcast? {
        let key = snapshot.coordinate.key
        guard state.nowcastUncovered[key] == nil, state.backoff.waiting(id.rawValue, now: now) == nil,
              WeatherNowcast.isWorthFetching(for: snapshot, now: now) else { return nil }
        do {
            return try await client.nowcast(snapshot.coordinate, now: now)
        } catch WeatherFetchError.notCovered, WeatherFetchError.http(400) {
            state.nowcastUncovered[key] = now
        } catch {
            state.backoff.record(error, from: id.rawValue, now: now)
        }
        return nil
    }

    /// An optional request's value. Its failure doesn't end the round, but a
    /// rate limit holds every request on this key until its deadline.
    private func settle<T>(_ result: Result<T, Error>, state: inout WeatherSourceState, now: Date) -> T? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            state.backoff.record(error, from: id.rawValue, now: now)
            return nil
        }
    }

    private static func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
#endif
