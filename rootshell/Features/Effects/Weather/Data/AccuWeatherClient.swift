// AccuWeatherClient.swift
// rootshell
// AccuWeather's enterprise API with the person's own key. It only takes the
// key as the `apikey` query item, so WeatherHTTP keeps URLs out of errors.

#if !CHINA_BUILD
import Foundation

nonisolated struct AccuWeatherClient {
    private static let host = URL(string: "https://api.accuweather.com")!

    let apiKey: String
    /// Nil sends an empty header; leaving it unset would let CFNetwork name the app.
    let userAgent: String?

    struct Conditions: Equatable, Sendable {
        var sample: WeatherSample
        /// The place's page on accuweather.com, for attribution.
        var link: URL?
    }

    func locationKey(for coordinate: WeatherCoordinate) async throws -> String {
        let query = "\(coordinate.queryLatitude),\(coordinate.queryLongitude)"
        return try Self.locationKey(from: try await get("locations/v1/cities/geoposition/search.json", ["q": query]))
    }

    func currentConditions(locationKey: String) async throws -> Conditions {
        try Self.currentConditions(from: try await get("currentconditions/v1/\(locationKey).json", ["details": "true"]))
    }

    func hourly(locationKey: String, now: Date) async throws -> [WeatherSample] {
        let data = try await get("forecasts/v1/hourly/24hour/\(locationKey).json", ["details": "true", "metric": "true"])
        return try Self.hourly(from: data, now: now)
    }

    func nowcast(_ coordinate: WeatherCoordinate, now: Date) async throws -> WeatherNowcast {
        let query = "\(coordinate.queryLatitude),\(coordinate.queryLongitude)"
        return try Self.nowcast(from: try await get("forecasts/v1/minute.json", ["q": query]), now: now)
    }

    private func get(_ path: String, _ query: KeyValuePairs<String, String>) async throws -> Data {
        var components = URLComponents(url: Self.host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        // English text, because the condition mapping reads it.
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "language", value: "en-us")]
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw WeatherFetchError.unusable }
        do {
            switch try await WeatherHTTP.get(url, accept: "application/json", userAgent: userAgent ?? "") {
            case .body(let data, _, _): return data
            case .notModified: throw WeatherFetchError.unusable
            }
        } catch WeatherFetchError.http(503) {
            // AccuWeather's answer once a key's request allowance is spent.
            throw WeatherFetchError.rateLimited(nil)
        }
    }

    // MARK: Parsing

    /// Keys look like `331083` or `38431_PC`; anything else never reaches a path.
    static func locationKey(from data: Data) throws -> String {
        struct Location: Decodable { var Key: String? }
        let location: Location
        do { location = try JSONDecoder().decode(Location.self, from: data) } catch { throw WeatherFetchError.decoding }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard let key = location.Key, !key.isEmpty, key.count <= 64,
              key.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { throw WeatherFetchError.unusable }
        return key
    }

    static func currentConditions(from data: Data) throws -> Conditions {
        let list: [Current]
        do { list = try JSONDecoder().decode([Current].self, from: data) } catch { throw WeatherFetchError.decoding }
        guard let c = list.first, let epoch = c.EpochTime else { throw WeatherFetchError.unusable }
        let reading = AccuWeatherConditionMapping.reading(icon: c.WeatherIcon, phrase: c.WeatherText,
                                                          hasPrecipitation: c.HasPrecipitation, type: c.PrecipitationType,
                                                          intensity: nil)
        guard var sample = WeatherSample(
            date: Date(timeIntervalSince1970: epoch), reading: reading, cloudCover: c.CloudCover.map { $0 / 100 },
            measuredRate: c.HasPrecipitation == true ? millimetres(c.Precip1hr?.Metric) : nil,
            thunderChance: reading?.thunder == true ? 1 : nil) else { throw WeatherFetchError.unusable }
        sample.windSpeed = metresPerSecond(c.Wind?.Speed?.Metric)
        sample.windGust = metresPerSecond(c.WindGust?.Speed?.Metric)
        sample.windFrom = c.Wind?.Direction?.Degrees
        sample.visibility = metres(c.Visibility?.Metric)
        sample.temperature = celsius(c.Temperature?.Metric)
        sample.dewPoint = celsius(c.DewPoint?.Metric)
        sample.cloudBase = cloudBase(ceiling: metres(c.Ceiling?.Metric), cover: sample.cloudCover)
        sample.convectiveCloud = AccuWeatherConditionMapping.convectiveCloud(icon: c.WeatherIcon)
        return Conditions(sample: sample, link: link(c.MobileLink ?? c.Link))
    }

    /// Rows start at the next hour; `metric=true` gives °C, km/h, km, m, and mm.
    static func hourly(from data: Data, now: Date) throws -> [WeatherSample] {
        let rows: [Hour]
        do { rows = try JSONDecoder().decode([Hour].self, from: data) } catch { throw WeatherFetchError.decoding }
        let samples = rows.compactMap(sample).filter { $0.date > now.addingTimeInterval(-3600) }.sorted { $0.date < $1.date }
        guard !samples.isEmpty else { throw WeatherFetchError.unusable }
        return samples
    }

    private static func sample(_ h: Hour) -> WeatherSample? {
        guard let epoch = h.EpochDateTime else { return nil }
        let reading = AccuWeatherConditionMapping.reading(icon: h.WeatherIcon, phrase: h.IconPhrase,
                                                          hasPrecipitation: h.HasPrecipitation, type: h.PrecipitationType,
                                                          intensity: h.PrecipitationIntensity)
        guard var sample = WeatherSample(
            date: Date(timeIntervalSince1970: epoch), reading: reading, cloudCover: h.CloudCover.map { $0 / 100 },
            measuredRate: h.HasPrecipitation == true ? millimetres(h.TotalLiquid) : nil,
            thunderChance: h.ThunderstormProbability.map { $0 / 100 }) else { return nil }
        sample.precipitationChance = h.PrecipitationProbability.map { $0 / 100 }
        sample.windSpeed = metresPerSecond(h.Wind?.Speed)
        sample.windGust = metresPerSecond(h.WindGust?.Speed)
        sample.windFrom = h.Wind?.Direction?.Degrees
        sample.visibility = metres(h.Visibility)
        sample.temperature = celsius(h.Temperature)
        sample.dewPoint = celsius(h.DewPoint)
        sample.cloudBase = cloudBase(ceiling: metres(h.Ceiling), cover: sample.cloudCover)
        sample.convectiveCloud = AccuWeatherConditionMapping.convectiveCloud(icon: h.WeatherIcon)
        return sample
    }

    /// Minute intervals when the response has them (only while something is
    /// falling), else the summary's runs of minutes.
    static func nowcast(from data: Data, now: Date) throws -> WeatherNowcast {
        let response: Minute
        do { response = try JSONDecoder().decode(Minute.self, from: data) } catch { throw WeatherFetchError.decoding }
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var segments: [WeatherNowcast.Segment] = []
        let intervals = (response.Intervals ?? []).contains { $0.Dbz != nil } ? response.Intervals ?? [] : []
        let starts = intervals.map { interval in
            interval.StartEpochDateTime.map { Date(timeIntervalSince1970: $0) }
                ?? interval.Minute.map { base.addingTimeInterval(Double($0) * 60) }
        }
        for (index, interval) in intervals.enumerated() {
            guard let start = starts[index] else { continue }
            let next = starts.dropFirst(index + 1).lazy.compactMap { $0 }.first
            let end = next ?? start.addingTimeInterval(segments.last.map { $0.end.timeIntervalSince($0.start) } ?? 60)
            guard end > start else { continue }
            let frozen = AccuWeatherConditionMapping.isFrozen(type: interval.PrecipitationType)
            let rate = interval.Dbz.flatMap { AccuWeatherConditionMapping.precipitationRate(dbz: $0, frozen: frozen) }
            let reading = rate.flatMap {
                AccuWeatherConditionMapping.nowcastReading(type: interval.PrecipitationType ?? "rain", typeID: nil, rate: $0)
            }
            segments.append(.init(start: start, end: end, kind: reading?.kind, precipitationRate: reading?.precipitationRate))
        }
        if segments.isEmpty {
            for summary in response.Summaries ?? [] {
                guard let first = summary.StartMinute, let last = summary.EndMinute, last >= first else { continue }
                let reading = AccuWeatherConditionMapping.nowcastReading(type: summary.type, typeID: summary.TypeId, rate: nil)?
                    .refined(byPhrase: summary.MinuteText)
                segments.append(.init(start: base.addingTimeInterval(Double(first) * 60),
                                      end: base.addingTimeInterval(Double(last + 1) * 60),
                                      kind: reading?.kind, precipitationRate: reading?.precipitationRate))
            }
        }
        segments.sort { $0.start < $1.start }
        guard !segments.isEmpty else { throw WeatherFetchError.unusable }
        return WeatherNowcast(segments: WeatherNowcast.coalesced(segments))
    }

    /// The ceiling (lowest broken or overcast layer) is the low base when there
    /// is one; clear skies report about 10 km.
    static func cloudBase(ceiling: Double?, cover: Double) -> Double? {
        guard let ceiling, ceiling > 0, ceiling < 3_000, cover >= 0.5 else { return nil }
        return ceiling
    }

    /// AccuWeather's links are plain http; only its own pages are kept.
    static func link(_ text: String?) -> URL? {
        guard let text, var components = URLComponents(string: text), let host = components.host?.lowercased(),
              host == "accuweather.com" || host.hasSuffix(".accuweather.com") else { return nil }
        components.scheme = "https"
        return components.url
    }

    // MARK: Units

    private static func converted(_ m: Measure?, _ factors: [String: Double]) -> Double? {
        guard let value = m?.Value, value.isFinite else { return nil }
        return value * (m?.Unit.flatMap { factors[$0.lowercased()] } ?? 1)
    }

    private static func celsius(_ m: Measure?) -> Double? {
        guard let value = m?.Value, value.isFinite else { return nil }
        return m?.Unit?.uppercased() == "F" ? (value - 32) * 5 / 9 : value
    }

    private static func metresPerSecond(_ m: Measure?) -> Double? {
        converted(m, ["km/h": 1 / 3.6, "mi/h": 0.44704, "kt": 0.514444])
    }

    private static func metres(_ m: Measure?) -> Double? {
        converted(m, ["km": 1_000, "mi": 1_609.344, "ft": 0.3048])
    }

    private static func millimetres(_ m: Measure?) -> Double? {
        converted(m, ["cm": 10, "in": 25.4])
    }

    // MARK: Wire format

    private struct Measure: Decodable { var Value: Double?; var Unit: String? }
    private struct Bearing: Decodable { var Degrees: Double? }

    private struct Current: Decodable {
        struct Both: Decodable { var Metric: Measure? }
        struct WindInfo: Decodable { var Direction: Bearing?; var Speed: Both? }
        struct GustInfo: Decodable { var Speed: Both? }
        var EpochTime: TimeInterval?
        var WeatherText: String?
        var WeatherIcon: Int?
        var HasPrecipitation: Bool?
        var PrecipitationType: String?
        var Temperature: Both?
        var DewPoint: Both?
        var Wind: WindInfo?
        var WindGust: GustInfo?
        var Visibility: Both?
        var CloudCover: Double?
        var Ceiling: Both?
        var Precip1hr: Both?
        var MobileLink: String?
        var Link: String?
    }

    private struct Hour: Decodable {
        struct WindInfo: Decodable { var Direction: Bearing?; var Speed: Measure? }
        struct GustInfo: Decodable { var Speed: Measure? }
        var EpochDateTime: TimeInterval?
        var WeatherIcon: Int?
        var IconPhrase: String?
        var HasPrecipitation: Bool?
        var PrecipitationType: String?
        var PrecipitationIntensity: String?
        var Temperature: Measure?
        var DewPoint: Measure?
        var Wind: WindInfo?
        var WindGust: GustInfo?
        var Visibility: Measure?
        var Ceiling: Measure?
        var CloudCover: Double?
        var PrecipitationProbability: Double?
        var ThunderstormProbability: Double?
        var TotalLiquid: Measure?
    }

    private struct Minute: Decodable {
        struct Interval: Decodable {
            var StartEpochDateTime: TimeInterval?
            var Minute: Int?
            var Dbz: Double?
            var PrecipitationType: String?
        }
        struct Summary: Decodable {
            var StartMinute: Int?
            var EndMinute: Int?
            var MinuteText: String?
            var type: String?
            var TypeId: Int?
            enum CodingKeys: String, CodingKey {
                case StartMinute, EndMinute, MinuteText, TypeId
                case type = "Type"
            }
        }
        var Intervals: [Interval]?
        var Summaries: [Summary]?
    }
}
#endif
