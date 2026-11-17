// METNorwayClient.swift
// rootshell
// api.met.no Locationforecast 2.0 "complete": global, with cloud layers, fog,
// and thunder probability. Data CC BY 4.0, MET Norway. The terms require an
// identifying User-Agent, at most four decimals, and honouring Expires.

#if !CHINA_BUILD
import Foundation
import os

nonisolated struct METNorwayClient {
    enum Outcome {
        case updated(WeatherSnapshot, WeatherHTTPValidator)
        case notModified(WeatherHTTPValidator)
    }

    private static let endpoint = URL(string: "https://api.met.no/weatherapi/locationforecast/2.0/complete")!
    private static let logger = Logger(subsystem: "com.rootshell.weather", category: "METNorway")

    /// Pass the previous validator only when it belongs to the same coordinate.
    func fetch(_ coordinate: WeatherCoordinate, validator: WeatherHTTPValidator?, now: Date) async throws -> Outcome {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lat", value: coordinate.queryLatitude),
                                 URLQueryItem(name: "lon", value: coordinate.queryLongitude)]
        guard let url = components.url else { throw WeatherFetchError.unusable }
        switch try await WeatherHTTP.get(url, accept: "application/json", validator: validator) {
        case .notModified(let next):
            return .notModified(next)
        case .body(let data, let next, let response):
            if response.statusCode == 203 {
                Self.logger.warning("MET Norway reports Locationforecast 2.0 as deprecated")
            }
            return .updated(try Self.snapshot(from: data, coordinate: coordinate, now: now, expires: next.expires), next)
        }
    }

    static func snapshot(from data: Data, coordinate: WeatherCoordinate, now: Date, expires: Date?) throws -> WeatherSnapshot {
        let decoded: Forecast
        do { decoded = try JSONDecoder().decode(Forecast.self, from: data) } catch { throw WeatherFetchError.decoding }
        let samples = decoded.properties.timeseries.compactMap(Self.sample)
        // The entry covering the current hour describes "now".
        guard let current = samples.last(where: { $0.date <= now }) ?? samples.first else { throw WeatherFetchError.unusable }
        let hourly = samples.filter { $0.date > current.date }.prefix(24)
        return WeatherSnapshot(coordinate: coordinate, source: .metNorway, current: current,
                               hourly: Array(hourly), fetchedAt: now, expiresAt: expires, placeName: nil)
    }

    private static func sample(_ entry: Forecast.Entry) -> WeatherSample? {
        guard let date = WeatherHTTP.isoDate(entry.time) else { return nil }
        let d = entry.data.instant.details
        // Later entries only carry six-hour summaries.
        let summary = entry.data.next_1_hours ?? entry.data.next_6_hours
        let hours: Double = entry.data.next_1_hours == nil ? 6 : 1
        let reading = summary?.summary?.symbol_code.flatMap(METNorwayConditionMapping.reading(symbolCode:))
        guard var sample = WeatherSample(
            date: date, reading: reading, cloudCover: d.cloud_area_fraction.map { $0 / 100 },
            measuredRate: summary?.details?.precipitation_amount.map { $0 / hours },
            thunderChance: summary?.details?.probability_of_thunder.map { $0 / 100 }) else { return nil }
        sample.cloudLow = d.cloud_area_fraction_low.map { $0 / 100 }
        sample.cloudMid = d.cloud_area_fraction_medium.map { $0 / 100 }
        sample.cloudHigh = d.cloud_area_fraction_high.map { $0 / 100 }
        sample.precipitationChance = summary?.details?.probability_of_precipitation.map { $0 / 100 }
        sample.windSpeed = d.wind_speed
        sample.windGust = d.wind_speed_of_gust
        sample.windFrom = d.wind_from_direction
        sample.fogFraction = d.fog_area_fraction.map { $0 / 100 }
        sample.temperature = d.air_temperature
        sample.dewPoint = d.dew_point_temperature
        return sample
    }

    // MARK: Wire format

    private struct Forecast: Decodable {
        struct Entry: Decodable {
            struct Payload: Decodable {
                struct Instant: Decodable {
                    struct Details: Decodable {
                        var air_temperature: Double?
                        var dew_point_temperature: Double?
                        var cloud_area_fraction: Double?
                        var cloud_area_fraction_low: Double?
                        var cloud_area_fraction_medium: Double?
                        var cloud_area_fraction_high: Double?
                        var fog_area_fraction: Double?
                        var wind_speed: Double?
                        var wind_speed_of_gust: Double?
                        var wind_from_direction: Double?
                    }
                    var details: Details
                }
                struct Period: Decodable {
                    struct Summary: Decodable { var symbol_code: String? }
                    struct Details: Decodable {
                        var precipitation_amount: Double?
                        var probability_of_precipitation: Double?
                        var probability_of_thunder: Double?
                    }
                    var summary: Summary?
                    var details: Details?
                }
                var instant: Instant
                var next_1_hours: Period?
                var next_6_hours: Period?
            }
            var time: String
            var data: Payload
        }
        struct Properties: Decodable { var timeseries: [Entry] }
        var properties: Properties
    }
}
#endif
