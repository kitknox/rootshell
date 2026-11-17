// WeatherModels.swift
// rootshell
// Pure value types shared by the weather clients, store, and renderer.

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherConditionKind: String, Codable, CaseIterable, Sendable {
    case clear, partlyCloudy, cloudy, fog, haze, smoke, dust, drizzle, rain, heavyRain
    case snow, heavySnow, sleet, freezingRain, thunderstorm, windy

    /// Cover implied by the condition when a source reports no numeric cloud cover.
    var typicalCloudCover: Double {
        switch self {
        case .clear: return 0.05
        case .partlyCloudy, .windy: return 0.45
        case .cloudy: return 0.9
        case .fog: return 0.85
        case .haze, .smoke, .dust: return 0.05
        case .drizzle, .snow, .sleet: return 0.95
        case .rain, .heavyRain, .heavySnow, .freezingRain, .thunderstorm: return 1
        }
    }

    /// Something falling or hanging in the air, rather than only cloud.
    var isWeather: Bool {
        switch self {
        case .clear, .partlyCloudy, .cloudy, .windy: return false
        default: return true
        }
    }

    var isPrecipitation: Bool {
        switch self {
        case .drizzle, .rain, .heavyRain, .snow, .heavySnow, .sleet, .freezingRain, .thunderstorm: return true
        default: return false
        }
    }

    static func forCover(_ cover: Double) -> Self {
        cover < 0.3 ? .clear : (cover < 0.7 ? .partlyCloudy : .cloudy)
    }
}

/// The service a snapshot's data came from.
nonisolated enum WeatherSource: String, Codable, Sendable {
    case nws, openMeteo, metNorway, accuWeather
}

/// Rounded to 0.01° (about 1 km): the cache key, and all that leaves the device.
nonisolated struct WeatherCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        let lat = latitude.isFinite ? min(max(latitude, -90), 90) : 0
        var lon = (longitude.isFinite ? longitude : 0) + 180
        lon = lon.truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        self.latitude = (lat * 100).rounded() / 100
        self.longitude = ((lon - 180) * 100).rounded() / 100
    }

    var key: String { String(format: "%.2f,%.2f", latitude, longitude) }
    var queryLatitude: String { String(format: "%.2f", latitude) }
    var queryLongitude: String { String(format: "%.2f", longitude) }
}

/// One moment of weather, normalised across sources to SI units.
nonisolated struct WeatherSample: Codable, Equatable, Sendable {
    var date: Date
    var kind: WeatherConditionKind
    var cloudCover: Double                  // 0...1
    var cloudLow: Double? = nil
    var cloudMid: Double? = nil
    var cloudHigh: Double? = nil
    var precipitationRate: Double? = nil    // mm/h
    var precipitationChance: Double? = nil  // 0...1
    var thunderChance: Double? = nil        // 0...1
    var windSpeed: Double? = nil            // m/s
    var windGust: Double? = nil             // m/s
    var windFrom: Double? = nil             // degrees, meteorological
    var visibility: Double? = nil           // metres
    var fogFraction: Double? = nil          // 0...1
    var temperature: Double? = nil          // °C
    var dewPoint: Double? = nil             // °C
    var cloudBase: Double? = nil            // metres above ground, lowest measured layer
    var cape: Double? = nil                 // J/kg
    var convectiveCloud: Double? = nil      // reported towering cumulus 0.6, cumulonimbus 1
}

nonisolated extension WeatherSample {
    /// A source's condition refined by its numbers: measured cover and rate
    /// beat the condition's typical ones. Nil when neither was reported.
    init?(date: Date, reading: WeatherConditionReading?, cloudCover cover: Double?, measuredRate: Double?,
          thunderChance: Double? = nil) {
        guard let kind = reading?.kind ?? cover.map(WeatherConditionKind.forCover) else { return nil }
        self.init(date: date, kind: kind, cloudCover: cover ?? reading?.cloudCover ?? kind.typicalCloudCover,
                  precipitationRate: measuredRate.flatMap { $0 > 0 ? $0 : nil } ?? reading?.precipitationRate,
                  thunderChance: thunderChance ?? (reading?.thunder == true ? 0.8 : nil))
    }
}

/// Minute-scale precipitation for the next hour or two, from radar.
nonisolated struct WeatherNowcast: Codable, Equatable, Sendable {
    nonisolated struct Segment: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
        var kind: WeatherConditionKind?         // nil while dry
        var precipitationRate: Double? = nil    // mm/h
    }

    nonisolated enum Outlook: Equatable, Sendable {
        case starting(WeatherConditionKind, at: Date)
        case ending(WeatherConditionKind, at: Date)
        case continuing(WeatherConditionKind, through: Date)
    }

    /// Ascending and contiguous.
    var segments: [Segment]

    func segment(at date: Date) -> Segment? {
        segments.first { $0.start <= date && date < $0.end }
    }

    /// What changes next; nil when it stays dry or `date` is outside the nowcast.
    func outlook(at date: Date) -> Outlook? {
        guard let current = segment(at: date) else { return nil }
        let later = segments.filter { $0.start >= current.end }
        if let kind = current.kind {
            if let dry = later.first(where: { $0.kind == nil }) { return .ending(kind, at: dry.start) }
            return .continuing(kind, through: segments.last?.end ?? current.end)
        }
        guard let wet = later.first(where: { $0.kind != nil }), let kind = wet.kind else { return nil }
        return .starting(kind, at: wet.start)
    }

    /// Adjacent segments with the same weather become one.
    static func coalesced(_ segments: [Segment]) -> [Segment] {
        segments.reduce(into: []) { result, segment in
            if var last = result.last, last.end == segment.start, last.kind == segment.kind,
               abs((last.precipitationRate ?? 0) - (segment.precipitationRate ?? 0)) < 0.1 {
                last.end = segment.end
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
    }

    /// Spends a request only while something is falling, was in the last
    /// nowcast, or the next few hours give it a real chance.
    static func isWorthFetching(for snapshot: WeatherSnapshot, now: Date) -> Bool {
        if snapshot.current.kind.isPrecipitation || snapshot.observation?.kind.isPrecipitation == true { return true }
        if snapshot.nowcast?.segments.contains(where: { $0.kind != nil && $0.end > now }) == true { return true }
        return snapshot.hourly.contains { hour in
            hour.date > now.addingTimeInterval(-3600) && hour.date < now.addingTimeInterval(3 * 3600)
                && (hour.precipitationChance.map { $0 >= 0.2 } ?? hour.kind.isPrecipitation)
        }
    }
}

nonisolated struct WeatherSnapshot: Codable, Equatable, Sendable {
    var coordinate: WeatherCoordinate
    var source: WeatherSource
    var current: WeatherSample
    var hourly: [WeatherSample]
    var fetchedAt: Date
    /// The source's earliest refetch time (met.no `Expires`).
    var expiresAt: Date?
    var placeName: String?
    /// The latest observed conditions, refreshed between forecasts: the nearest
    /// NWS station in the US, or the provider's own observation.
    var observation: WeatherSample? = nil
    var observationStation: String? = nil
    var nowcast: WeatherNowcast? = nil
    /// The source's page for this place, when it gives one.
    var link: URL? = nil
}

nonisolated struct WeatherCity: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

nonisolated enum WeatherLocationSelection: Hashable, Sendable {
    case device
    case city(WeatherCity)
}
#endif
