// NWSClient.swift
// rootshell
// api.weather.gov: /points once per location, then the nearest station's
// latest observation for "now" and the hourly forecast for what comes next.

#if !CHINA_BUILD
import Foundation

/// The grid lookup for a coordinate. NWS asks clients to cache it.
nonisolated struct NWSPointInfo: Codable, Equatable, Sendable {
    var forecastHourly: String
    var stationId: String?
    var placeName: String?
    var resolvedAt: Date

    static let lifetime: TimeInterval = 7 * 86_400
}

nonisolated struct NWSClient {
    private static let base = URL(string: "https://api.weather.gov")!
    private static let accept = "application/geo+json"
    private static let observationMaxAge: TimeInterval = 2 * 3600

    func point(for coordinate: WeatherCoordinate, now: Date) async throws -> NWSPointInfo {
        let url = Self.base.appendingPathComponent("points/\(coordinate.queryLatitude),\(coordinate.queryLongitude)")
        let point: PointResponse = try await decode(url)
        guard let hourly = point.properties.forecastHourly else { throw WeatherFetchError.unusable }
        var station: String?
        if let stations = point.properties.observationStations.flatMap(URL.init(string:)),
           let list: StationsResponse = try? await decode(stations) {
            station = list.features.first?.properties.stationIdentifier
        }
        return NWSPointInfo(forecastHourly: hourly, stationId: station,
                            placeName: point.properties.relativeLocation?.properties.city, resolvedAt: now)
    }

    func fetch(_ coordinate: WeatherCoordinate, point: NWSPointInfo, now: Date) async throws -> WeatherSnapshot {
        async let observed = observation(station: point.stationId, now: now)
        async let forecast = hourly(point.forecastHourly, now: now)
        let current = await observed
        let hours = (try? await forecast) ?? []
        guard let now0 = current ?? hours.first else { throw WeatherFetchError.unusable }
        return WeatherSnapshot(coordinate: coordinate, source: .nws, current: now0,
                               hourly: Array(hours.prefix(24)), fetchedAt: now, expiresAt: nil,
                               placeName: point.placeName)
    }

    // MARK: Observation

    func observation(station: String?, now: Date) async -> WeatherSample? {
        guard let station else { return nil }
        let url = Self.base.appendingPathComponent("stations/\(station)/observations/latest")
        guard let data = try? await body(url) else { return nil }
        return Self.observation(from: data, now: now)
    }

    /// The latest station report, when recent and complete enough to describe now.
    static func observation(from data: Data, now: Date) -> WeatherSample? {
        guard let response = try? JSONDecoder().decode(ObservationResponse.self, from: data) else { return nil }
        let p = response.properties
        guard let date = p.timestamp.flatMap(WeatherHTTP.isoDate), now.timeIntervalSince(date) < Self.observationMaxAge else { return nil }
        let phenomena = (p.presentWeather ?? []).compactMap { entry in
            entry.weather.map { (weather: $0, intensity: entry.intensity, modifier: entry.modifier) }
        }
        let weather = NWSConditionMapping.reading(phenomena: phenomena)
        let reported = (p.cloudLayers ?? []).compactMap { layer in layer.amount.map { (amount: $0, base: layer.base?.value) } }
        let layers = NWSConditionMapping.cloudCover(layerAmounts: reported.map(\.amount))
        let split = NWSConditionMapping.cloudLayers(reported)
        let icon = p.icon.flatMap(NWSConditionMapping.reading(iconURL:))?.reading
        let kind: WeatherConditionKind
        if let weather {
            kind = weather.kind
        } else if let icon {
            kind = icon.kind
        } else if let layers {
            kind = layers < 0.3 ? .clear : (layers < 0.65 ? .partlyCloudy : .cloudy)
        } else {
            return nil
        }
        let cover = max(layers ?? icon?.cloudCover ?? kind.typicalCloudCover, weather?.cloudCover ?? 0)
        var precipitation = weather?.precipitationRate
        if let last = p.precipitationLastHour?.value, last > 0 {
            precipitation = (p.precipitationLastHour?.unitCode?.hasSuffix(":m") == true) ? last * 1_000 : last
        }
        return WeatherSample(
            date: date, kind: kind, cloudCover: cover, cloudLow: split?.low, cloudMid: split?.mid, cloudHigh: split?.high,
            precipitationRate: precipitation, thunderChance: weather?.thunder == true ? 1 : nil,
            windSpeed: p.windSpeed?.value.map { NWSConditionMapping.metresPerSecond($0, unitCode: p.windSpeed?.unitCode) },
            windGust: p.windGust?.value.map { NWSConditionMapping.metresPerSecond($0, unitCode: p.windGust?.unitCode) },
            windFrom: p.windDirection?.value, visibility: p.visibility?.value,
            temperature: p.temperature?.value.map { Self.celsius($0, unit: p.temperature?.unitCode) },
            dewPoint: p.dewpoint?.value.map { Self.celsius($0, unit: p.dewpoint?.unitCode) },
            cloudBase: split?.base,
            convectiveCloud: p.rawMessage.flatMap(NWSConditionMapping.convectiveCloud(metar:)))
    }

    // MARK: Hourly forecast

    private func hourly(_ link: String, now: Date) async throws -> [WeatherSample] {
        guard var components = URLComponents(string: link) else { throw WeatherFetchError.unusable }
        components.queryItems = [URLQueryItem(name: "units", value: "si")]
        guard let url = components.url else { throw WeatherFetchError.unusable }
        return try Self.hourly(from: try await body(url), now: now)
    }

    static func hourly(from data: Data, now: Date) throws -> [WeatherSample] {
        let response: HourlyResponse
        do { response = try JSONDecoder().decode(HourlyResponse.self, from: data) } catch { throw WeatherFetchError.decoding }
        return response.properties.periods.compactMap { period -> WeatherSample? in
            guard let date = WeatherHTTP.isoDate(period.startTime), date > now.addingTimeInterval(-3600),
                  let icon = period.icon.flatMap(NWSConditionMapping.reading(iconURL:)) else { return nil }
            let reading = icon.reading.refined(byPhrase: period.shortForecast)
            let chance = period.probabilityOfPrecipitation?.value.map { $0 / 100 } ?? icon.chance
            let temperatureUnit = period.temperature?.unitCode ?? (period.temperatureUnit == "F" ? "degF" : "degC")
            let temperature = period.temperature?.value.map { Self.celsius($0, unit: temperatureUnit) }
            return WeatherSample(
                date: date, kind: reading.kind, cloudCover: reading.cloudCover,
                precipitationRate: reading.precipitationRate, precipitationChance: reading.precipitationRate == nil ? nil : chance,
                thunderChance: reading.thunder ? (chance ?? 0.6) : nil,
                windSpeed: period.windSpeed?.metresPerSecond,
                windFrom: period.windDirection.flatMap(NWSConditionMapping.degrees(compass:)),
                temperature: temperature)
        }
    }

    private static func celsius(_ value: Double, unit: String?) -> Double {
        unit?.lowercased().hasSuffix("degf") == true ? (value - 32) * 5 / 9 : value
    }

    private func decode<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await body(url)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw WeatherFetchError.decoding }
    }

    private func body(_ url: URL) async throws -> Data {
        switch try await WeatherHTTP.get(url, accept: Self.accept) {
        case .body(let data, _, _): return data
        case .notModified: throw WeatherFetchError.unusable
        }
    }

    // MARK: Wire format

    private struct Quantity: Decodable { var value: Double?; var unitCode: String? }

    private struct PointResponse: Decodable {
        struct Properties: Decodable {
            var forecastHourly: String?
            var observationStations: String?
            var relativeLocation: RelativeLocation?
        }
        struct RelativeLocation: Decodable {
            struct Place: Decodable { var city: String? }
            var properties: Place
        }
        var properties: Properties
    }

    private struct StationsResponse: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable { var stationIdentifier: String? }
            var properties: Properties
        }
        var features: [Feature]
    }

    private struct ObservationResponse: Decodable {
        struct Phenomenon: Decodable { var intensity: String?; var modifier: String?; var weather: String? }
        struct Layer: Decodable { var amount: String?; var base: Quantity? }
        struct Properties: Decodable {
            var timestamp: String?
            var rawMessage: String?
            var icon: String?
            var presentWeather: [Phenomenon]?
            var cloudLayers: [Layer]?
            var temperature: Quantity?
            var dewpoint: Quantity?
            var windDirection: Quantity?
            var windSpeed: Quantity?
            var windGust: Quantity?
            var visibility: Quantity?
            var precipitationLastHour: Quantity?
        }
        var properties: Properties
    }

    /// A bare number, or a quantitative value object behind an NWS feature flag.
    private struct FlexibleNumber: Decodable {
        var value: Double?
        var unitCode: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let quantity = try? container.decode(Quantity.self) {
                value = quantity.value; unitCode = quantity.unitCode
            }
        }
    }

    /// "15 km/h", or a quantitative value object behind an NWS feature flag.
    private struct FlexibleSpeed: Decodable {
        var metresPerSecond: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                metresPerSecond = NWSConditionMapping.windSpeed(text: text)
            } else if let quantity = try? container.decode(Quantity.self), let value = quantity.value {
                metresPerSecond = NWSConditionMapping.metresPerSecond(value, unitCode: quantity.unitCode)
            }
        }
    }

    private struct HourlyResponse: Decodable {
        struct Period: Decodable {
            var startTime: String
            var temperature: FlexibleNumber?
            var temperatureUnit: String?
            var probabilityOfPrecipitation: Quantity?
            var windSpeed: FlexibleSpeed?
            var windDirection: String?
            var icon: String?
            var shortForecast: String?
        }
        struct Properties: Decodable { var periods: [Period] }
        var properties: Properties
    }
}
#endif
