// WeatherConditionMapping.swift
// rootshell
// Maps NWS icon codes, METAR phenomena, MET Norway symbol codes, WMO codes, and
// AccuWeather icons onto WeatherConditionKind. Pure, so the tables are unit
// tested without a network.

#if !CHINA_BUILD
import Foundation

nonisolated struct WeatherConditionReading: Equatable, Sendable {
    var kind: WeatherConditionKind
    var cloudCover: Double
    /// Typical rate for the reported intensity, when the source gives none.
    var precipitationRate: Double?
    var thunder: Bool = false

    /// Forecast wording sharpens a condition: "Heavy Rain", "Light Snow", "Drizzle".
    func refined(byPhrase phrase: String?) -> Self {
        guard let text = phrase?.lowercased(), !text.isEmpty else { return self }
        var reading = self
        if text.contains("heavy") {
            if reading.kind == .rain { reading.kind = .heavyRain }
            if reading.kind == .snow { reading.kind = .heavySnow }
            reading.precipitationRate = reading.precipitationRate.map { $0 * 2.5 }
        } else if text.contains("light") || text.contains("drizzle") {
            if reading.kind == .rain && text.contains("drizzle") { reading.kind = .drizzle }
            reading.precipitationRate = reading.precipitationRate.map { $0 * 0.4 }
        }
        return reading
    }
}

// MARK: - National Weather Service

nonisolated enum NWSConditionMapping {
    /// `https://api.weather.gov/icons/land/day/tsra_hi,40/rain,60?size=medium`
    /// yields `[("tsra_hi", 0.4), ("rain", 0.6)]`.
    static func iconCodes(from url: String) -> [(code: String, chance: Double?)] {
        guard let path = URLComponents(string: url)?.path else { return [] }
        let parts = path.split(separator: "/").map(String.init)
        guard let start = parts.firstIndex(where: { $0 == "day" || $0 == "night" }) else { return [] }
        return parts[(start + 1)...].compactMap { part in
            let fields = part.split(separator: ",", maxSplits: 1).map(String.init)
            guard let code = fields.first, !code.isEmpty else { return nil }
            let chance = fields.count > 1 ? Double(fields[1]).map { min(max($0 / 100, 0), 1) } : nil
            return (code, chance)
        }
    }

    static func reading(iconCode code: String) -> WeatherConditionReading? {
        switch code {
        case "skc", "hot", "cold": return .init(kind: .clear, cloudCover: 0)
        case "few": return .init(kind: .clear, cloudCover: 0.2)
        case "sct": return .init(kind: .partlyCloudy, cloudCover: 0.45)
        case "bkn": return .init(kind: .cloudy, cloudCover: 0.75)
        case "ovc": return .init(kind: .cloudy, cloudCover: 1)
        case "wind_skc": return .init(kind: .windy, cloudCover: 0)
        case "wind_few": return .init(kind: .windy, cloudCover: 0.2)
        case "wind_sct": return .init(kind: .windy, cloudCover: 0.45)
        case "wind_bkn": return .init(kind: .windy, cloudCover: 0.75)
        case "wind_ovc": return .init(kind: .windy, cloudCover: 1)
        case "snow": return .init(kind: .snow, cloudCover: 0.95, precipitationRate: 1.2)
        case "blizzard": return .init(kind: .heavySnow, cloudCover: 1, precipitationRate: 4)
        case "rain_snow", "rain_sleet", "snow_sleet", "sleet":
            return .init(kind: .sleet, cloudCover: 0.95, precipitationRate: 1.5)
        case "fzra", "rain_fzra", "snow_fzra": return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 1.5)
        case "rain": return .init(kind: .rain, cloudCover: 0.95, precipitationRate: 2.5)
        case "rain_showers": return .init(kind: .rain, cloudCover: 0.8, precipitationRate: 2.5)
        case "rain_showers_hi": return .init(kind: .rain, cloudCover: 0.5, precipitationRate: 1.5)
        case "tsra": return .init(kind: .thunderstorm, cloudCover: 0.95, precipitationRate: 6, thunder: true)
        case "tsra_sct": return .init(kind: .thunderstorm, cloudCover: 0.7, precipitationRate: 4, thunder: true)
        case "tsra_hi": return .init(kind: .thunderstorm, cloudCover: 0.5, precipitationRate: 3, thunder: true)
        case "tornado": return .init(kind: .thunderstorm, cloudCover: 1, precipitationRate: 8, thunder: true)
        case "hurricane", "tropical_storm": return .init(kind: .heavyRain, cloudCover: 1, precipitationRate: 12)
        case "dust": return .init(kind: .dust, cloudCover: 0.1)
        case "smoke": return .init(kind: .smoke, cloudCover: 0.2)
        case "haze": return .init(kind: .haze, cloudCover: 0.2)
        case "fog": return .init(kind: .fog, cloudCover: 0.9)
        default: return nil
        }
    }

    /// The first recognised code of an icon URL, weighted by its precipitation chance.
    static func reading(iconURL: String) -> (reading: WeatherConditionReading, chance: Double?)? {
        for entry in iconCodes(from: iconURL) {
            if let reading = reading(iconCode: entry.code) { return (reading, entry.chance) }
        }
        return nil
    }

    /// METAR `presentWeather` entries; the most significant phenomenon wins.
    static func reading(phenomena: [(weather: String, intensity: String?, modifier: String?)]) -> WeatherConditionReading? {
        guard !phenomena.isEmpty else { return nil }
        func scale(_ intensity: String?, light: Double, moderate: Double, heavy: Double) -> Double {
            switch intensity { case "light": return light; case "heavy": return heavy; default: return moderate }
        }
        let names = Set(phenomena.map(\.weather))
        if let storm = phenomena.first(where: { $0.weather == "thunderstorms" }) {
            return .init(kind: .thunderstorm, cloudCover: 1,
                         precipitationRate: scale(storm.intensity, light: 2, moderate: 5, heavy: 12), thunder: true)
        }
        if let freezing = phenomena.first(where: { $0.modifier == "freezing" && ($0.weather == "rain" || $0.weather == "drizzle") }) {
            return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: scale(freezing.intensity, light: 0.5, moderate: 1.5, heavy: 4))
        }
        let frozen = ["snow", "snow_grains", "snow_pellets", "ice_crystals"]
        if let snow = phenomena.first(where: { frozen.contains($0.weather) }) {
            if names.contains("rain") || names.contains("drizzle") || names.contains("ice_pellets") {
                return .init(kind: .sleet, cloudCover: 1, precipitationRate: scale(snow.intensity, light: 0.6, moderate: 1.5, heavy: 3.5))
            }
            let heavy = snow.intensity == "heavy" || snow.modifier == "blowing"
            return .init(kind: heavy ? .heavySnow : .snow, cloudCover: 1,
                         precipitationRate: scale(snow.intensity, light: 0.5, moderate: 1.5, heavy: 4))
        }
        if let ice = phenomena.first(where: { ["ice_pellets", "hail", "small_hail"].contains($0.weather) }) {
            return .init(kind: .sleet, cloudCover: 1, precipitationRate: scale(ice.intensity, light: 0.6, moderate: 1.5, heavy: 4))
        }
        if let rain = phenomena.first(where: { $0.weather == "rain" }) {
            return .init(kind: rain.intensity == "heavy" ? .heavyRain : .rain, cloudCover: 0.95,
                         precipitationRate: scale(rain.intensity, light: 0.8, moderate: 3, heavy: 10))
        }
        if let drizzle = phenomena.first(where: { $0.weather == "drizzle" }) {
            return .init(kind: .drizzle, cloudCover: 0.95, precipitationRate: scale(drizzle.intensity, light: 0.15, moderate: 0.3, heavy: 0.6))
        }
        if names.contains("fog") || names.contains("fog_mist") { return .init(kind: .fog, cloudCover: 0.9) }
        if names.contains("smoke") || names.contains("volcanic_ash") { return .init(kind: .smoke, cloudCover: 0.2) }
        if !names.isDisjoint(with: ["dust", "sand", "dust_storm", "sand_storm", "dust_whirls"]) {
            return .init(kind: .dust, cloudCover: 0.1)
        }
        if names.contains("haze") || names.contains("spray") { return .init(kind: .haze, cloudCover: 0.2) }
        if names.contains("squalls") || names.contains("funnel_cloud") { return .init(kind: .thunderstorm, cloudCover: 1, precipitationRate: 4) }
        return nil
    }

    /// METAR cloud layer amounts; the densest layer sets the cover.
    static func cloudCover(layerAmounts: [String]) -> Double? {
        layerAmounts.compactMap(layerFraction).max()
    }

    static func layerFraction(_ amount: String) -> Double? {
        switch amount.uppercased() {
        case "CLR", "SKC", "NCD", "NSC": return 0
        case "FEW": return 0.2
        case "SCT": return 0.45
        case "BKN": return 0.75
        case "OVC", "VV": return 1
        default: return nil
        }
    }

    /// Station layers in the US bands (low under 6,500 ft, high over 20,000 ft),
    /// with the low layer's base in metres. Ceilometers stop at 12,000 ft, so
    /// high cover is nil unless an observer reported a high layer.
    static func cloudLayers(_ layers: [(amount: String, base: Double?)])
        -> (low: Double, mid: Double, high: Double?, base: Double?)? {
        var low = 0.0, mid = 0.0, high: Double?, base: Double?, reported = false
        for layer in layers {
            guard let fraction = layerFraction(layer.amount) else { continue }
            reported = true
            guard fraction > 0 else { continue }
            guard let height = layer.base else { low = max(low, fraction); continue }
            if height >= 6_096 {
                high = max(high ?? 0, fraction)
            } else if height >= 1_981 {
                mid = max(mid, fraction)
            } else {
                low = max(low, fraction)
                base = min(base ?? height, height)
            }
        }
        return reported ? (low, mid, high, base) : nil
    }

    /// Towering cumulus (0.6) or cumulonimbus (1) in a METAR's sky groups, such as "SCT030CB".
    static func convectiveCloud(metar: String) -> Double? {
        let body = metar.components(separatedBy: " RMK")[0]
        let groups = body.split(separator: " ").filter { $0.count > 6 && ["FEW", "SCT", "BKN", "OVC"].contains($0.prefix(3)) }
        if groups.contains(where: { $0.hasSuffix("CB") }) { return 1 }
        if groups.contains(where: { $0.hasSuffix("TCU") }) { return 0.6 }
        return nil
    }

    /// "SW", "NNE" ... as meteorological degrees.
    static func degrees(compass: String) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard let index = points.firstIndex(of: compass.uppercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        return Double(index) * 22.5
    }

    /// "10 km/h", "5 to 15 mph" or "10 kt" as m/s, using the upper bound of a range.
    static func windSpeed(text: String) -> Double? {
        let lower = text.lowercased()
        let numbers = lower.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard let value = numbers.max() else { return nil }
        if lower.contains("km/h") { return value / 3.6 }
        if lower.contains("mph") { return value * 0.44704 }
        if lower.contains("kt") || lower.contains("knot") { return value * 0.514444 }
        if lower.contains("m/s") { return value }
        return value * 0.44704
    }

    /// NWS quantitative values carry a WMO unit code such as `wmoUnit:km_h-1`.
    static func metresPerSecond(_ value: Double, unitCode: String?) -> Double {
        let unit = unitCode?.lowercased() ?? ""
        if unit.contains("km_h") { return value / 3.6 }
        if unit.contains("kt") || unit.contains("knot") { return value * 0.514444 }
        if unit.contains("mi_h") || unit.contains("mph") { return value * 0.44704 }
        return value
    }
}

// MARK: - MET Norway

nonisolated enum METNorwayConditionMapping {
    /// `heavyrainshowersandthunder_day` and friends. The API also spells some
    /// light variants `lights...`; the prefix test covers those too.
    static func reading(symbolCode: String) -> WeatherConditionReading? {
        var code = symbolCode.lowercased()
        for suffix in ["_day", "_night", "_polartwilight"] where code.hasSuffix(suffix) {
            code.removeLast(suffix.count)
        }
        switch code {
        case "clearsky": return .init(kind: .clear, cloudCover: 0)
        case "fair": return .init(kind: .clear, cloudCover: 0.2)
        case "partlycloudy": return .init(kind: .partlyCloudy, cloudCover: 0.5)
        case "cloudy": return .init(kind: .cloudy, cloudCover: 0.95)
        case "fog": return .init(kind: .fog, cloudCover: 0.9)
        default: break
        }
        let thunder = code.contains("thunder")
        let light = code.hasPrefix("light")
        let heavy = code.hasPrefix("heavy")
        let showers = code.contains("showers")
        let cover: Double = showers ? 0.75 : 1
        func rate(light l: Double, moderate m: Double, heavy h: Double) -> Double { light ? l : (heavy ? h : m) }
        let reading: WeatherConditionReading
        if code.contains("sleet") {
            reading = .init(kind: .sleet, cloudCover: cover, precipitationRate: rate(light: 0.5, moderate: 1.5, heavy: 4))
        } else if code.contains("snow") {
            reading = .init(kind: heavy ? .heavySnow : .snow, cloudCover: cover, precipitationRate: rate(light: 0.4, moderate: 1.2, heavy: 3.5))
        } else if code.contains("rain") {
            reading = .init(kind: heavy ? .heavyRain : .rain, cloudCover: cover,
                            precipitationRate: rate(light: 0.5, moderate: 2.5, heavy: 8))
        } else {
            return nil
        }
        guard thunder else { return reading }
        return .init(kind: .thunderstorm, cloudCover: cover, precipitationRate: reading.precipitationRate, thunder: true)
    }
}

// MARK: - Open-Meteo

nonisolated enum OpenMeteoConditionMapping {
    /// The WMO weather codes Open-Meteo reports.
    static func reading(weatherCode code: Int) -> WeatherConditionReading? {
        switch code {
        case 0: return .init(kind: .clear, cloudCover: 0)
        case 1: return .init(kind: .clear, cloudCover: 0.2)
        case 2: return .init(kind: .partlyCloudy, cloudCover: 0.5)
        case 3: return .init(kind: .cloudy, cloudCover: 1)
        case 45, 48: return .init(kind: .fog, cloudCover: 0.9)
        case 51: return .init(kind: .drizzle, cloudCover: 0.95, precipitationRate: 0.15)
        case 53: return .init(kind: .drizzle, cloudCover: 0.95, precipitationRate: 0.3)
        case 55: return .init(kind: .drizzle, cloudCover: 0.95, precipitationRate: 0.6)
        case 56: return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 0.3)
        case 57: return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 0.8)
        case 61: return .init(kind: .rain, cloudCover: 0.95, precipitationRate: 0.8)
        case 63: return .init(kind: .rain, cloudCover: 0.95, precipitationRate: 3)
        case 65: return .init(kind: .heavyRain, cloudCover: 1, precipitationRate: 10)
        case 66: return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 1)
        case 67: return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 4)
        case 71: return .init(kind: .snow, cloudCover: 0.95, precipitationRate: 0.5)
        case 73: return .init(kind: .snow, cloudCover: 1, precipitationRate: 1.5)
        case 75: return .init(kind: .heavySnow, cloudCover: 1, precipitationRate: 4)
        case 77: return .init(kind: .snow, cloudCover: 0.95, precipitationRate: 0.3)
        case 80: return .init(kind: .rain, cloudCover: 0.75, precipitationRate: 1)
        case 81: return .init(kind: .rain, cloudCover: 0.8, precipitationRate: 3)
        case 82: return .init(kind: .heavyRain, cloudCover: 0.85, precipitationRate: 10)
        case 85: return .init(kind: .snow, cloudCover: 0.8, precipitationRate: 0.8)
        case 86: return .init(kind: .heavySnow, cloudCover: 0.85, precipitationRate: 3)
        case 95: return .init(kind: .thunderstorm, cloudCover: 0.9, precipitationRate: 5, thunder: true)
        case 96, 99: return .init(kind: .thunderstorm, cloudCover: 0.95, precipitationRate: 8, thunder: true)
        case 97: return .init(kind: .thunderstorm, cloudCover: 1, precipitationRate: 10, thunder: true)
        default: return nil
        }
    }
}

// MARK: - AccuWeather

nonisolated enum AccuWeatherConditionMapping {
    /// AccuWeather's numbered icons, 1-44; 9, 10, 27, and 28 are unused.
    static func reading(icon: Int) -> WeatherConditionReading? {
        switch icon {
        case 1, 30, 31, 33: return .init(kind: .clear, cloudCover: 0)
        case 2, 34: return .init(kind: .clear, cloudCover: 0.2)
        case 3, 35: return .init(kind: .partlyCloudy, cloudCover: 0.4)
        case 4, 36: return .init(kind: .partlyCloudy, cloudCover: 0.55)
        case 5, 37: return .init(kind: .haze, cloudCover: 0.2)
        case 6, 38: return .init(kind: .cloudy, cloudCover: 0.75)
        case 7: return .init(kind: .cloudy, cloudCover: 0.95)
        case 8: return .init(kind: .cloudy, cloudCover: 1)
        case 11: return .init(kind: .fog, cloudCover: 0.9)
        case 12: return .init(kind: .rain, cloudCover: 0.85, precipitationRate: 2.5)
        case 13, 40: return .init(kind: .rain, cloudCover: 0.75, precipitationRate: 1.5)
        case 14, 39: return .init(kind: .rain, cloudCover: 0.55, precipitationRate: 1.2)
        case 15: return .init(kind: .thunderstorm, cloudCover: 0.95, precipitationRate: 6, thunder: true)
        case 16, 42: return .init(kind: .thunderstorm, cloudCover: 0.8, precipitationRate: 4, thunder: true)
        case 17, 41: return .init(kind: .thunderstorm, cloudCover: 0.6, precipitationRate: 3, thunder: true)
        case 18: return .init(kind: .rain, cloudCover: 1, precipitationRate: 2.5)
        case 19: return .init(kind: .snow, cloudCover: 0.9, precipitationRate: 0.3)
        case 20, 43: return .init(kind: .snow, cloudCover: 0.8, precipitationRate: 0.3)
        case 21: return .init(kind: .snow, cloudCover: 0.6, precipitationRate: 0.2)
        case 22: return .init(kind: .snow, cloudCover: 1, precipitationRate: 1.2)
        case 23, 44: return .init(kind: .snow, cloudCover: 0.85, precipitationRate: 1)
        case 24, 25, 29: return .init(kind: .sleet, cloudCover: 1, precipitationRate: 1.5)
        case 26: return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 1.5)
        case 32: return .init(kind: .windy, cloudCover: 0.3)
        default: return nil
        }
    }

    /// An icon refined by what comes with it: English text (the client asks
    /// for en-us), `HasPrecipitation`, its type (Rain, Snow, Ice, Mixed), and
    /// intensity (Light, Moderate, Heavy).
    static func reading(icon: Int?, phrase: String?, hasPrecipitation: Bool?, type: String?,
                        intensity: String?) -> WeatherConditionReading? {
        var reading = icon.flatMap { reading(icon: $0) }
        let text = phrase?.lowercased() ?? ""
        if hasPrecipitation == true, reading?.kind.isPrecipitation != true,
           let falling = precipitation(type: type, freezing: text.contains("freezing")) {
            // Light rain under a cloudy icon, for instance.
            reading = .init(kind: falling.kind, cloudCover: max(falling.cloudCover, reading?.cloudCover ?? 0),
                            precipitationRate: falling.precipitationRate)
        } else if reading?.kind.isPrecipitation != true, let obscured = obscuration(text) {
            reading = obscured
        }
        if var freezing = reading, text.contains("freezing"),
           freezing.kind == .rain || freezing.kind == .drizzle || freezing.kind == .sleet {
            freezing.kind = .freezingRain
            reading = freezing
        }
        return reading?.refined(byPhrase: [intensity, phrase].compactMap { $0 }.joined(separator: " "))
    }

    /// Showers come from heaped cloud, thunderstorms from cumulonimbus.
    static func convectiveCloud(icon: Int?) -> Double? {
        switch icon {
        case 15, 16, 17, 41, 42: return 1
        case 12, 13, 14, 39, 40: return 0.6
        default: return nil
        }
    }

    /// MinuteCast's type, as a name (Rain, Snow, Ice, Mix) or its numeric id,
    /// at a radar-derived rate when there is one.
    static func nowcastReading(type: String?, typeID: Int?, rate: Double?) -> WeatherConditionReading? {
        // A null type with id 0 is a dry stretch.
        guard let name = type ?? typeID.flatMap({ [1: "rain", 2: "snow", 3: "ice", 4: "mix"][$0] }),
              var reading = precipitation(type: name, freezing: false) else { return nil }
        if let rate {
            reading.precipitationRate = rate
            if reading.kind == .rain && rate >= 8 { reading.kind = .heavyRain }
            if reading.kind == .snow && rate >= 2.5 { reading.kind = .heavySnow }
        }
        return reading
    }

    /// Radar reflectivity as a liquid-equivalent rate: Marshall-Palmer
    /// (Z = 200 R^1.6) for rain, Z = 2000 R^2 for snow and ice.
    static func precipitationRate(dbz: Double, frozen: Bool) -> Double? {
        guard dbz.isFinite, dbz > 5 else { return nil }
        let z = pow(10, dbz / 10)
        return frozen ? (z / 2_000).squareRoot() : pow(z / 200, 1 / 1.6)
    }

    static func isFrozen(type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        return type.contains("snow") || type.contains("ice") || type.contains("mix")
    }

    private static func precipitation(type: String?, freezing: Bool) -> WeatherConditionReading? {
        switch type?.lowercased() ?? "rain" {
        case "rain": return .init(kind: .rain, cloudCover: 0.95, precipitationRate: 2.5)
        case "snow": return .init(kind: .snow, cloudCover: 0.95, precipitationRate: 1.2)
        case "ice": return .init(kind: freezing ? .freezingRain : .sleet, cloudCover: 1, precipitationRate: 1.5)
        case "mix", "mixed": return .init(kind: .sleet, cloudCover: 1, precipitationRate: 1.5)
        default: return nil
        }
    }

    private static func obscuration(_ text: String) -> WeatherConditionReading? {
        if text.contains("smoke") { return .init(kind: .smoke, cloudCover: 0.2) }
        if text.contains("dust") || text.contains("sand") { return .init(kind: .dust, cloudCover: 0.1) }
        if text.contains("fog") { return .init(kind: .fog, cloudCover: 0.9) }
        if text.contains("haze") || text.contains("hazy") { return .init(kind: .haze, cloudCover: 0.2) }
        return nil
    }
}

// MARK: - Coverage

/// Rough boxes around the areas api.weather.gov serves. A miss only costs a
/// Open-Meteo request; a false hit falls back on the NWS 404.
nonisolated enum NWSCoverage {
    private static let regions: [(lat: ClosedRange<Double>, lon: ClosedRange<Double>)] = [
        (24.3...49.5, -125.0...(-66.8)),    // contiguous states
        (51.0...71.6, -180.0...(-129.9)),   // Alaska
        (51.0...56.0, 172.0...180.0),       // western Aleutians
        (18.8...22.4, -160.4...(-154.7)),   // Hawaii
        (17.6...18.6, -67.4...(-64.5)),     // Puerto Rico and US Virgin Islands
        (13.1...20.7, 144.5...146.2),       // Guam and the Northern Marianas
        (-14.7...(-14.0), -171.2...(-168.0)) // American Samoa
    ]

    static func contains(_ coordinate: WeatherCoordinate) -> Bool {
        regions.contains { $0.lat.contains(coordinate.latitude) && $0.lon.contains(coordinate.longitude) }
    }
}
#endif
