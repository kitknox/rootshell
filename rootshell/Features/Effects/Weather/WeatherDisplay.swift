// WeatherDisplay.swift
// rootshell
// Names, symbols, and units shared by Live Weather settings and the sidebar.

#if !CHINA_BUILD
import Foundation

extension WeatherConditionKind {
    var localizedName: String {
        switch self {
        case .clear: return String(localized: "Clear", comment: "Weather condition")
        case .partlyCloudy: return String(localized: "Partly Cloudy", comment: "Weather condition")
        case .cloudy: return String(localized: "Cloudy", comment: "Weather condition")
        case .fog: return String(localized: "Fog", comment: "Weather condition")
        case .haze: return String(localized: "Haze", comment: "Weather condition")
        case .smoke: return String(localized: "Smoke", comment: "Weather condition")
        case .dust: return String(localized: "Dust", comment: "Weather condition")
        case .drizzle: return String(localized: "Drizzle", comment: "Weather condition")
        case .rain: return String(localized: "Rain", comment: "Weather condition")
        case .heavyRain: return String(localized: "Heavy Rain", comment: "Weather condition")
        case .snow: return String(localized: "Snow", comment: "Weather condition")
        case .heavySnow: return String(localized: "Heavy Snow", comment: "Weather condition")
        case .sleet: return String(localized: "Sleet", comment: "Weather condition")
        case .freezingRain: return String(localized: "Freezing Rain", comment: "Weather condition")
        case .thunderstorm: return String(localized: "Thunderstorms", comment: "Weather condition")
        case .windy: return String(localized: "Windy", comment: "Weather condition")
        }
    }

    func symbolName(night: Bool) -> String {
        switch self {
        case .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .haze: return night ? "moon.haze.fill" : "sun.haze.fill"
        case .smoke: return "smoke.fill"
        case .dust: return night ? "moon.dust.fill" : "sun.dust.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow, .heavySnow: return "cloud.snow.fill"
        case .sleet, .freezingRain: return "cloud.sleet.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .windy: return "wind"
        }
    }
}

extension WeatherSource {
    var displayName: String {
        switch self {
        case .nws: return String(localized: "National Weather Service", comment: "Weather data source")
        case .openMeteo: return String(localized: "Open-Meteo", comment: "Weather data source")
        case .metNorway: return String(localized: "MET Norway", comment: "Weather data source")
        case .accuWeather: return String(localized: "AccuWeather", comment: "Weather data source")
        }
    }

    /// Credit shown next to the data, linking to `website`.
    var attribution: String {
        switch self {
        case .nws: return String(localized: "National Weather Service", comment: "Weather data credit")
        case .openMeteo: return String(localized: "Weather data by Open-Meteo.com", comment: "Weather data credit required by Open-Meteo")
        case .metNorway: return String(localized: "Data from MET Norway", comment: "Weather data credit")
        case .accuWeather: return String(localized: "Weather data by AccuWeather", comment: "Weather data credit")
        }
    }

    /// The row in settings' Weather Data section.
    var creditTitle: String {
        switch self {
        case .nws: return String(localized: "NOAA National Weather Service", comment: "Weather data credit")
        case .openMeteo: return String(localized: "Weather data by Open-Meteo.com", comment: "Weather data credit required by Open-Meteo")
        case .metNorway: return String(localized: "MET Norway", comment: "Weather data credit")
        case .accuWeather: return String(localized: "AccuWeather", comment: "Weather data credit")
        }
    }

    var website: URL {
        switch self {
        case .nws: return URL(string: "https://www.weather.gov")!
        case .openMeteo: return URL(string: "https://open-meteo.com/")!
        case .metNorway: return URL(string: "https://api.met.no")!
        case .accuWeather: return URL(string: "https://www.accuweather.com")!
        }
    }
}

extension WeatherProviderID {
    var displayName: String {
        switch self {
        case .openMeteo: return String(localized: "Open-Meteo", comment: "Weather provider")
        case .accuWeather: return String(localized: "AccuWeather", comment: "Weather provider")
        }
    }

    /// What choosing it means, for the provider section's footer.
    var summary: String {
        switch self {
        case .openMeteo:
            return String(localized: "Free, with no account or key.", comment: "Live Weather provider description")
        case .accuWeather:
            return String(localized: "Uses your own AccuWeather enterprise API key, kept in iCloud Keychain. Adds observed conditions everywhere and minute-by-minute precipitation for the next two hours. If AccuWeather can't be reached, Open-Meteo fills in.", comment: "Live Weather provider description")
        }
    }

    /// The Weather Data section's footer.
    var dataNote: String {
        switch self {
        case .openMeteo:
            return String(localized: "Forecasts come from Open-Meteo, with MET Norway as a backup. In the US, the nearest National Weather Service station corrects the current conditions every 15 minutes, and the Weather Service forecast stands in when Open-Meteo can't be reached. Open-Meteo and MET Norway data are licensed under CC BY 4.0, adapted and visualised by rootshell.", comment: "Live Weather data sources")
        case .accuWeather:
            return String(localized: "Forecasts, current conditions, and minute-by-minute precipitation come from AccuWeather with your key. When AccuWeather can't be reached, Open-Meteo, MET Norway, and the National Weather Service fill in. Open-Meteo and MET Norway data are licensed under CC BY 4.0, adapted and visualised by rootshell.", comment: "Live Weather data sources")
        }
    }

    /// Where to get a key.
    var keyURL: URL? {
        switch self {
        case .openMeteo: return nil
        case .accuWeather: return URL(string: "https://developer.accuweather.com")!
        }
    }
}

extension WeatherProviderIssue {
    func message(for provider: WeatherProviderID) -> String {
        let name = provider.displayName
        let fallback = WeatherProviderID.default.displayName
        switch self {
        case .missingKey:
            return String(localized: "Add an API key to use \(name). Until then, weather comes from \(fallback).",
                          comment: "Live Weather: provider name, fallback provider name")
        case .rejectedKey:
            return String(localized: "\(name) didn't accept the API key, so weather comes from \(fallback). Check the key and that it's enabled for this API.",
                          comment: "Live Weather: provider name, fallback provider name")
        case .limitReached:
            return String(localized: "The \(name) key has used up its requests for now, so weather comes from \(fallback).",
                          comment: "Live Weather: provider name, fallback provider name")
        case .unavailable:
            return String(localized: "\(name) couldn't be reached, so weather comes from \(fallback) for now.",
                          comment: "Live Weather: provider name, fallback provider name")
        }
    }
}


extension WeatherSnapshot {
    /// The conditions to name at `date`, as the sky draws them.
    func displaySample(at date: Date) -> WeatherSample {
        WeatherTimeline.sample(at: date, snapshot: self)
    }

    func isNight(at date: Date) -> Bool {
        SolarCalculator.calculatePosition(date: date, latitude: coordinate.latitude, longitude: coordinate.longitude).altitude < -3
    }
}

enum WeatherFormat {
    /// "64°" in the user's preferred unit.
    static func temperature(_ celsius: Double, width: Measurement<UnitTemperature>.FormatStyle.UnitWidth = .narrow) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: width, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func windSpeed(_ metresPerSecond: Double) -> String {
        Measurement(value: metresPerSecond, unit: UnitSpeed.metersPerSecond)
            .formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// "Rain starting in 12 minutes".
    static func nowcast(_ outlook: WeatherNowcast.Outlook, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        switch outlook {
        case .starting(let kind, let date):
            let when = formatter.localizedString(for: max(date, now), relativeTo: now)
            return String(localized: "\(kind.localizedName) starting \(when)",
                          comment: "Live Weather nowcast: condition, relative time such as 'in 12 minutes'")
        case .ending(let kind, let date):
            let when = formatter.localizedString(for: max(date, now), relativeTo: now)
            return String(localized: "\(kind.localizedName) ending \(when)",
                          comment: "Live Weather nowcast: condition, relative time such as 'in 12 minutes'")
        case .continuing(let kind, let date):
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "\(kind.localizedName) until at least \(time)",
                          comment: "Live Weather nowcast: condition, clock time")
        }
    }
}
#endif
