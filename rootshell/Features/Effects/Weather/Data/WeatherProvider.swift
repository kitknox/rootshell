// WeatherProvider.swift
// rootshell
// To add a provider: a WeatherProviderID case and WeatherSource, a client that
// parses into WeatherSample, a conformance, and a case in
// WeatherSourceRouter.provider(_:request:). Settings and credits follow the ID.

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherProviderID: String, CaseIterable, Codable, Sendable {
    /// Open-Meteo, with NWS stations in the US and MET Norway as a backup. Free, no key.
    case openMeteo
    case accuWeather

    static let `default` = Self.openMeteo

    /// Needs the person's own key, kept in the keychain.
    var requiresAPIKey: Bool { self == .accuWeather }

    /// Sends a User-Agent the person chose. Never for the free services,
    /// whose terms ask for an identifying one.
    var allowsCustomUserAgent: Bool { self == .accuWeather }

    /// Everything this choice can show, fallbacks included, for attribution.
    var sources: [WeatherSource] {
        switch self {
        case .openMeteo: return [.nws, .openMeteo, .metNorway]
        case .accuWeather: return [.accuWeather] + Self.default.sources
        }
    }
}

nonisolated extension WeatherSource {
    /// The provider whose snapshots carry this source.
    var provider: WeatherProviderID {
        switch self {
        case .nws, .openMeteo, .metNorway: return .openMeteo
        case .accuWeather: return .accuWeather
        }
    }
}

/// What a person chose in settings. The key is not here; it stays in the keychain.
nonisolated struct WeatherProviderChoice: Hashable, Sendable {
    var provider: WeatherProviderID = .default
    var userAgent: String?
}

/// A choice with its key, for one round of requests.
nonisolated struct WeatherProviderRequest: Sendable {
    var choice = WeatherProviderChoice()
    var apiKey: String?
}

/// Why the chosen provider isn't the one supplying the weather.
nonisolated enum WeatherProviderIssue: String, Codable, Sendable {
    case missingKey, rejectedKey, limitReached, unavailable

    init(_ error: Error) {
        switch error as? WeatherFetchError {
        case .unauthorized?: self = .rejectedKey
        case .rateLimited?: self = .limitReached
        default: self = .unavailable
        }
    }
}

/// Fresh "now" between forecasts. Nil fields leave the snapshot's as they are.
nonisolated struct WeatherNowUpdate: Sendable {
    var observation: WeatherSample?
    var observationStation: String?
    var nowcast: WeatherNowcast?
}

nonisolated protocol WeatherProvider: Sendable {
    var id: WeatherProviderID { get }

    func fetch(_ coordinate: WeatherCoordinate, previous: WeatherSnapshot?, state: inout WeatherSourceState,
               now: Date) async throws -> WeatherFetchOutcome

    /// When "now" next needs refreshing for a snapshot this provider made; nil
    /// when it has nothing finer than its forecast there.
    func observationDue(for snapshot: WeatherSnapshot, state: WeatherSourceState) -> Date?

    /// Throws only what the router should act on, such as a rate limit.
    func observe(_ snapshot: WeatherSnapshot, state: inout WeatherSourceState, now: Date) async throws -> WeatherNowUpdate?
}

nonisolated extension WeatherSnapshot {
    mutating func apply(_ update: WeatherNowUpdate) {
        if let observation = update.observation {
            self.observation = observation
            observationStation = update.observationStation
        }
        if let nowcast = update.nowcast { self.nowcast = nowcast }
    }
}
#endif
