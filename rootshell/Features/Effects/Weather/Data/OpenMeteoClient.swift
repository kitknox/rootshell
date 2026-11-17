// OpenMeteoClient.swift
// rootshell
// api.open-meteo.com forecast: global, with cloud layers and visibility. Free
// for non-commercial apps without ads or subscriptions; data CC BY 4.0,
// credited with a link in settings.

#if !CHINA_BUILD
import Foundation

nonisolated struct OpenMeteoClient {
    private static let endpoint = URL(string: "https://api.open-meteo.com/v1/forecast")!
    private static let currentFields = "temperature_2m,dew_point_2m,cape,weather_code,"
        + "cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,"
        + "precipitation,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
    private static let hourlyFields = currentFields + ",precipitation_probability"

    func fetch(_ coordinate: WeatherCoordinate, now: Date) async throws -> WeatherSnapshot {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinate.queryLatitude),
            URLQueryItem(name: "longitude", value: coordinate.queryLongitude),
            URLQueryItem(name: "current", value: Self.currentFields),
            URLQueryItem(name: "hourly", value: Self.hourlyFields),
            URLQueryItem(name: "forecast_hours", value: "25"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        guard let url = components.url else { throw WeatherFetchError.unusable }
        switch try await WeatherHTTP.get(url, accept: "application/json") {
        case .body(let data, _, _): return try Self.snapshot(from: data, coordinate: coordinate, now: now)
        case .notModified: throw WeatherFetchError.unusable // no validator is ever sent
        }
    }

    static func snapshot(from data: Data, coordinate: WeatherCoordinate, now: Date) throws -> WeatherSnapshot {
        let decoded: Forecast
        do { decoded = try JSONDecoder().decode(Forecast.self, from: data) } catch { throw WeatherFetchError.decoding }
        let hourly = decoded.hourly.map(hourlySamples) ?? []
        guard let current = decoded.current.flatMap(currentSample) ?? hourly.last(where: { $0.date <= now }) else {
            throw WeatherFetchError.unusable
        }
        // Hourly rows start at the top of the current hour.
        let upcoming = hourly.filter { $0.date > current.date }.prefix(24)
        return WeatherSnapshot(coordinate: coordinate, source: .openMeteo, current: current, hourly: Array(upcoming),
                               fetchedAt: now, expiresAt: nil, placeName: nil)
    }

    /// One time step's fields, from the `current` block or an hourly column.
    private struct Values {
        var code: Double?
        var cover, low, mid, high: Double?
        var precipitation, chance, visibility: Double?
        var wind, gust, from, temperature, dewPoint, cape: Double?
    }

    private static func currentSample(_ c: Forecast.Current) -> WeatherSample? {
        let values = Values(code: c.weather_code, cover: c.cloud_cover, low: c.cloud_cover_low, mid: c.cloud_cover_mid,
                            high: c.cloud_cover_high, precipitation: c.precipitation, chance: nil, visibility: c.visibility,
                            wind: c.wind_speed_10m, gust: c.wind_gusts_10m, from: c.wind_direction_10m, temperature: c.temperature_2m,
                            dewPoint: c.dew_point_2m, cape: c.cape)
        // Current precipitation is the sum over the preceding interval, usually 15 minutes.
        return sample(at: Date(timeIntervalSince1970: c.time), values, hours: max(c.interval ?? 900, 60) / 3600)
    }

    private static func hourlySamples(_ h: Forecast.Hourly) -> [WeatherSample] {
        h.time.indices.compactMap { i in
            func at(_ column: [Double?]?) -> Double? { column.flatMap { i < $0.count ? $0[i] : nil } }
            let values = Values(code: at(h.weather_code), cover: at(h.cloud_cover), low: at(h.cloud_cover_low),
                                mid: at(h.cloud_cover_mid), high: at(h.cloud_cover_high), precipitation: at(h.precipitation),
                                chance: at(h.precipitation_probability), visibility: at(h.visibility), wind: at(h.wind_speed_10m),
                                gust: at(h.wind_gusts_10m), from: at(h.wind_direction_10m), temperature: at(h.temperature_2m),
                                dewPoint: at(h.dew_point_2m), cape: at(h.cape))
            return sample(at: Date(timeIntervalSince1970: h.time[i]), values, hours: 1)
        }
    }

    private static func sample(at date: Date, _ v: Values, hours: Double) -> WeatherSample? {
        // Int(_:) traps on out-of-range values such as 1e20.
        let reading = v.code.flatMap { Int(exactly: $0) }.flatMap { OpenMeteoConditionMapping.reading(weatherCode: $0) }
        guard var sample = WeatherSample(date: date, reading: reading, cloudCover: v.cover.map { $0 / 100 },
                                         measuredRate: v.precipitation.map { $0 / hours }) else { return nil }
        sample.cloudLow = v.low.map { $0 / 100 }
        sample.cloudMid = v.mid.map { $0 / 100 }
        sample.cloudHigh = v.high.map { $0 / 100 }
        sample.precipitationChance = v.chance.map { $0 / 100 }
        sample.windSpeed = v.wind
        sample.windGust = v.gust
        sample.windFrom = v.from
        sample.visibility = v.visibility
        sample.temperature = v.temperature
        sample.dewPoint = v.dewPoint
        sample.cape = v.cape
        return sample
    }

    // MARK: Wire format

    private struct Forecast: Decodable {
        struct Current: Decodable {
            var time: TimeInterval
            var interval: Double?
            var temperature_2m: Double?
            var dew_point_2m: Double?
            var cape: Double?
            var weather_code: Double?
            var cloud_cover: Double?
            var cloud_cover_low: Double?
            var cloud_cover_mid: Double?
            var cloud_cover_high: Double?
            var precipitation: Double?
            var visibility: Double?
            var wind_speed_10m: Double?
            var wind_direction_10m: Double?
            var wind_gusts_10m: Double?
        }
        struct Hourly: Decodable {
            var time: [TimeInterval]
            var temperature_2m: [Double?]?
            var dew_point_2m: [Double?]?
            var cape: [Double?]?
            var weather_code: [Double?]?
            var cloud_cover: [Double?]?
            var cloud_cover_low: [Double?]?
            var cloud_cover_mid: [Double?]?
            var cloud_cover_high: [Double?]?
            var precipitation: [Double?]?
            var precipitation_probability: [Double?]?
            var visibility: [Double?]?
            var wind_speed_10m: [Double?]?
            var wind_direction_10m: [Double?]?
            var wind_gusts_10m: [Double?]?
        }
        var current: Current?
        var hourly: Hourly?
    }
}
#endif
