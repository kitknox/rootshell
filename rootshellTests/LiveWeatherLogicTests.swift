import XCTest

final class LiveWeatherLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Condition mapping

    func testNWSIconURLYieldsCodesAndChances() {
        let codes = NWSConditionMapping.iconCodes(from: "https://api.weather.gov/icons/land/night/tsra_hi,40/rain,60?size=medium")
        XCTAssertEqual(codes.map(\.code), ["tsra_hi", "rain"])
        XCTAssertEqual(codes.map(\.chance), [0.4, 0.6])
        XCTAssertEqual(NWSConditionMapping.iconCodes(from: "https://api.weather.gov/icons/land/day/ovc?size=small").map(\.code), ["ovc"])
        XCTAssertTrue(NWSConditionMapping.iconCodes(from: "not a url").isEmpty)
    }

    func testNWSIconCodes() {
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "skc")?.kind, .clear)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "ovc")?.cloudCover, 1)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "wind_bkn")?.kind, .windy)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "tsra")?.thunder, true)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "rain_fzra")?.kind, .freezingRain)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "blizzard")?.kind, .heavySnow)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "smoke")?.kind, .smoke)
        XCTAssertNil(NWSConditionMapping.reading(iconCode: "nonsense"))
    }

    func testMETARPhenomenaPickTheMostSignificant() {
        func kind(_ phenomena: [(String, String?, String?)]) -> WeatherConditionKind? {
            NWSConditionMapping.reading(phenomena: phenomena.map { (weather: $0.0, intensity: $0.1, modifier: $0.2) })?.kind
        }
        XCTAssertEqual(kind([("rain", "light", nil), ("thunderstorms", nil, nil)]), .thunderstorm)
        XCTAssertEqual(kind([("snow", nil, nil), ("rain", nil, nil)]), .sleet)
        XCTAssertEqual(kind([("drizzle", "light", "freezing")]), .freezingRain)
        XCTAssertEqual(kind([("rain", "heavy", nil)]), .heavyRain)
        XCTAssertEqual(kind([("snow", nil, "blowing")]), .heavySnow)
        XCTAssertEqual(kind([("fog_mist", nil, nil)]), .fog)
        XCTAssertEqual(kind([("haze", nil, nil)]), .haze)
        XCTAssertNil(kind([]))
    }

    func testCloudLayersUseTheDensestLayer() {
        XCTAssertEqual(NWSConditionMapping.cloudCover(layerAmounts: ["FEW", "BKN", "SCT"]), 0.75)
        XCTAssertEqual(NWSConditionMapping.cloudCover(layerAmounts: ["CLR"]), 0)
        XCTAssertNil(NWSConditionMapping.cloudCover(layerAmounts: []))
    }

    func testWindTextAndCompass() {
        XCTAssertEqual(NWSConditionMapping.windSpeed(text: "5 to 15 mph")!, 15 * 0.44704, accuracy: 0.001)
        XCTAssertEqual(NWSConditionMapping.windSpeed(text: "18 km/h")!, 5, accuracy: 0.001)
        XCTAssertEqual(NWSConditionMapping.degrees(compass: "SW"), 225)
        XCTAssertEqual(NWSConditionMapping.degrees(compass: "nnw"), 337.5)
        XCTAssertNil(NWSConditionMapping.degrees(compass: "VRB"))
        XCTAssertEqual(NWSConditionMapping.metresPerSecond(36, unitCode: "wmoUnit:km_h-1"), 10, accuracy: 0.001)
    }

    func testMETNorwaySymbols() {
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "heavyrainshowersandthunder_day")?.kind, .thunderstorm)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightssleetshowersandthunder_night")?.kind, .thunderstorm)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightsnow")?.kind, .snow)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightsnow")?.precipitationRate, 0.4)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "heavysnow")?.kind, .heavySnow)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "sleetshowers_day")?.kind, .sleet)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "clearsky_polartwilight")?.kind, .clear)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "fog")?.kind, .fog)
        XCTAssertNil(METNorwayConditionMapping.reading(symbolCode: "mystery"))
    }

    func testOpenMeteoWeatherCodes() {
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 0)?.kind, .clear)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 2)?.kind, .partlyCloudy)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 48)?.kind, .fog)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 57)?.kind, .freezingRain)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 65)?.kind, .heavyRain)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 77)?.kind, .snow)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 86)?.kind, .heavySnow)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 97)?.thunder, true)
        XCTAssertNil(OpenMeteoConditionMapping.reading(weatherCode: 42))
    }

    func testNWSCoverage() {
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 40.71, longitude: -74.01)))   // New York
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 21.31, longitude: -157.86)))  // Honolulu
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 61.22, longitude: -149.90)))  // Anchorage
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 18.47, longitude: -66.11)))   // San Juan
        XCTAssertFalse(NWSCoverage.contains(WeatherCoordinate(latitude: 48.86, longitude: 2.35)))    // Paris
        XCTAssertFalse(NWSCoverage.contains(WeatherCoordinate(latitude: -33.87, longitude: 151.21))) // Sydney
    }

    func testCoordinateRoundingAndKey() {
        let c = WeatherCoordinate(latitude: 37.33412, longitude: -122.00911)
        XCTAssertEqual(c.latitude, 37.33)
        XCTAssertEqual(c.longitude, -122.01)
        XCTAssertEqual(c.key, "37.33,-122.01")
        XCTAssertEqual(WeatherCoordinate(latitude: 95, longitude: 190).latitude, 90)
        XCTAssertEqual(WeatherCoordinate(latitude: 0, longitude: 190).longitude, -170)
    }

    // MARK: Parsers

    func testMETNorwayForecastParsing() throws {
        let json = """
        {"type":"Feature","properties":{"timeseries":[
          {"time":"2025-10-09T08:00:00Z","data":{"instant":{"details":{"air_temperature":9.5,"cloud_area_fraction":100,
             "cloud_area_fraction_low":80,"cloud_area_fraction_medium":20,"cloud_area_fraction_high":10,"fog_area_fraction":0,
             "wind_speed":6.0,"wind_speed_of_gust":11.0,"wind_from_direction":250}},
           "next_1_hours":{"summary":{"symbol_code":"rain"},"details":{"precipitation_amount":1.4,"probability_of_precipitation":90,"probability_of_thunder":2}}}},
          {"time":"2025-10-09T09:00:00Z","data":{"instant":{"details":{"cloud_area_fraction":40,"wind_speed":4.0,"wind_from_direction":270}},
           "next_1_hours":{"summary":{"symbol_code":"partlycloudy_day"},"details":{"precipitation_amount":0}}}},
          {"time":"2025-10-09T12:00:00Z","data":{"instant":{"details":{"cloud_area_fraction":95}},
           "next_6_hours":{"summary":{"symbol_code":"heavyrain"},"details":{"precipitation_amount":30}}}}
        ]}}
        """
        let now = WeatherHTTP.isoDate("2025-10-09T08:20:00Z")!
        let coordinate = WeatherCoordinate(latitude: 59.91, longitude: 10.75)
        let snapshot = try METNorwayClient.snapshot(from: Data(json.utf8), coordinate: coordinate, now: now, expires: nil)
        XCTAssertEqual(snapshot.source, .metNorway)
        XCTAssertEqual(snapshot.current.kind, .rain)
        XCTAssertEqual(snapshot.current.cloudLow, 0.8)
        XCTAssertEqual(snapshot.current.precipitationRate, 1.4)
        XCTAssertEqual(snapshot.current.precipitationChance, 0.9)
        XCTAssertEqual(snapshot.current.windGust, 11)
        XCTAssertEqual(snapshot.hourly.map(\.kind), [.partlyCloudy, .heavyRain])
        // Six-hour totals become an hourly rate.
        XCTAssertEqual(snapshot.hourly.last?.precipitationRate, 5)
    }

    func testOpenMeteoForecastParsing() throws {
        let json = """
        {"latitude":48.85,"longitude":2.36,
         "current":{"time":1791808200,"interval":900,"temperature_2m":12.5,"dew_point_2m":9.5,"cape":120,"weather_code":63,"cloud_cover":100,
           "cloud_cover_low":90,"cloud_cover_mid":40,"cloud_cover_high":null,"precipitation":0.5,"visibility":9000,
           "wind_speed_10m":5.5,"wind_direction_10m":220,"wind_gusts_10m":9.8},
         "hourly":{"time":[1791806400,1791810000,1791813600],"weather_code":[63,2,95],"cloud_cover":[100,45,90],
           "precipitation":[1.2,0.0,6.0],"precipitation_probability":[90,10,70],"visibility":[8000,null,20000]}}
        """
        let now = Date(timeIntervalSince1970: 1_791_808_300)
        let coordinate = WeatherCoordinate(latitude: 48.86, longitude: 2.35)
        let snapshot = try OpenMeteoClient.snapshot(from: Data(json.utf8), coordinate: coordinate, now: now)
        XCTAssertEqual(snapshot.source, .openMeteo)
        XCTAssertEqual(snapshot.current.kind, .rain)
        // 0.5 mm in the last 15 minutes.
        XCTAssertEqual(snapshot.current.precipitationRate, 2)
        XCTAssertEqual(snapshot.current.cloudLow, 0.9)
        XCTAssertNil(snapshot.current.cloudHigh)
        XCTAssertEqual(snapshot.current.cloudMid, 0.4)
        XCTAssertEqual(snapshot.current.dewPoint, 9.5)
        XCTAssertEqual(snapshot.current.cape, 120)
        XCTAssertEqual(snapshot.current.windGust, 9.8)
        // The 12:00 row is behind the 12:30 current conditions.
        XCTAssertEqual(snapshot.hourly.map(\.kind), [.partlyCloudy, .thunderstorm])
        XCTAssertEqual(snapshot.hourly.first?.precipitationChance, 0.1)
        XCTAssertNil(snapshot.hourly.first?.visibility)
        XCTAssertEqual(snapshot.hourly.last?.thunderChance, 0.8)
        XCTAssertEqual(snapshot.hourly.last?.precipitationRate, 6)

        // Without a current block, the latest hourly row stands in.
        let hourlyOnly = """
        {"hourly":{"time":[1791806400,1791810000],"weather_code":[3,61],"cloud_cover":[95,100]}}
        """
        let fallback = try OpenMeteoClient.snapshot(from: Data(hourlyOnly.utf8), coordinate: coordinate, now: now)
        XCTAssertEqual(fallback.current.kind, .cloudy)
        XCTAssertEqual(fallback.hourly.map(\.kind), [.rain])
    }

    func testNWSObservationParsing() throws {
        let json = """
        {"properties":{"timestamp":"2025-10-09T15:53:00+00:00","icon":"https://api.weather.gov/icons/land/day/rain?size=medium",
          "presentWeather":[{"intensity":"light","modifier":null,"weather":"rain","rawString":"-RA"}],
          "cloudLayers":[{"base":{"value":900},"amount":"OVC"}],
          "temperature":{"unitCode":"wmoUnit:degC","value":12.2},
          "windDirection":{"value":200},"windSpeed":{"unitCode":"wmoUnit:km_h-1","value":18},
          "windGust":{"value":null},"visibility":{"value":8000},"precipitationLastHour":{"unitCode":"wmoUnit:mm","value":null}}}
        """
        let data = Data(json.utf8)
        let now = WeatherHTTP.isoDate("2025-10-09T16:10:00Z")!
        let sample = try XCTUnwrap(NWSClient.observation(from: data, now: now))
        XCTAssertEqual(sample.kind, .rain)
        XCTAssertEqual(sample.cloudCover, 1)
        XCTAssertEqual(sample.windSpeed!, 5, accuracy: 0.001)
        XCTAssertEqual(sample.windFrom, 200)
        XCTAssertEqual(sample.temperature, 12.2)
        XCTAssertEqual(sample.precipitationRate, 0.8)
        XCTAssertEqual(sample.cloudLow, 1)
        XCTAssertEqual(sample.cloudMid, 0)
        XCTAssertEqual(sample.cloudBase, 900)
        XCTAssertNil(sample.convectiveCloud)
        // A stale report doesn't describe now.
        XCTAssertNil(NWSClient.observation(from: data, now: now.addingTimeInterval(3 * 3600)))
    }

    func testNWSHourlyParsing() throws {
        let json = """
        {"properties":{"periods":[
          {"startTime":"2025-10-09T09:00:00-07:00","isDaytime":true,"temperature":11,"temperatureUnit":"C",
           "probabilityOfPrecipitation":{"value":60},"windSpeed":"10 to 20 km/h","windDirection":"SW",
           "icon":"https://api.weather.gov/icons/land/day/rain_showers,60?size=small","shortForecast":"Heavy Rain"},
          {"startTime":"2025-10-09T10:00:00-07:00","isDaytime":true,"temperature":{"unitCode":"wmoUnit:degF","value":59},
           "probabilityOfPrecipitation":{"value":0},"windSpeed":"5 km/h","windDirection":"W",
           "icon":"https://api.weather.gov/icons/land/day/sct?size=small","shortForecast":"Partly Sunny"}
        ]}}
        """
        let now = WeatherHTTP.isoDate("2025-10-09T15:30:00Z")!
        let samples = try NWSClient.hourly(from: Data(json.utf8), now: now)
        XCTAssertEqual(samples.map(\.kind), [.heavyRain, .partlyCloudy])
        XCTAssertEqual(samples[0].precipitationChance, 0.6)
        XCTAssertEqual(samples[0].windSpeed!, 20 / 3.6, accuracy: 0.001)
        XCTAssertEqual(samples[0].windFrom, 225)
        XCTAssertEqual(samples[1].temperature!, 15, accuracy: 0.001)
        XCTAssertNil(samples[1].precipitationChance)
    }

    // MARK: Fetch policy

    func testPolicySchedulesWithinTheJitterWindow() {
        var policy = WeatherFetchPolicy()
        XCTAssertEqual(policy.nextDue(now: t0), t0)
        policy.recordStarted(now: t0)
        policy.recordSuccess(now: t0, expiresAt: nil, changed: true, jitter: 0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.baseInterval))
        policy.recordSuccess(now: t0, expiresAt: nil, changed: true, jitter: 1)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.baseInterval + WeatherTuning.jitterWindow))
    }

    func testPolicyNeverFetchesBeforeExpires() {
        var policy = WeatherFetchPolicy()
        let expires = t0.addingTimeInterval(2 * 3600)
        policy.recordStarted(now: t0)
        policy.recordSuccess(now: t0, expiresAt: expires, changed: true, jitter: 0)
        XCTAssertGreaterThanOrEqual(policy.nextDue(now: t0), expires)
        XCTAssertGreaterThanOrEqual(policy.manualAvailableAt(now: t0.addingTimeInterval(3600)), expires)
        XCTAssertFalse(policy.requestManualRefresh(now: t0.addingTimeInterval(3600)))
    }

    func testPolicyStretchesWhenNothingChanges() {
        var policy = WeatherFetchPolicy()
        policy.recordSuccess(now: t0, expiresAt: nil, changed: false, jitter: 0)
        policy.recordSuccess(now: t0, expiresAt: nil, changed: false, jitter: 0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.stableInterval))
    }

    func testPolicyBacksOffExponentiallyWithACap() {
        var policy = WeatherFetchPolicy()
        policy.recordFailure(now: t0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(120))
        policy.recordFailure(now: t0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(240))
        for _ in 0..<10 { policy.recordFailure(now: t0) }
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.backoffMax))
    }

    func testRateLimitSurvivesManualRefreshButFailuresDoNot() {
        var policy = WeatherFetchPolicy()
        policy.recordStarted(now: t0)
        policy.recordRateLimited(retryAfterSeconds: 600, now: t0)
        XCTAssertFalse(policy.requestManualRefresh(now: t0.addingTimeInterval(300)))
        XCTAssertTrue(policy.requestManualRefresh(now: t0.addingTimeInterval(601)))

        var failing = WeatherFetchPolicy()
        failing.recordStarted(now: t0)
        failing.recordFailure(now: t0)
        XCTAssertFalse(failing.requestManualRefresh(now: t0.addingTimeInterval(10)))
        XCTAssertTrue(failing.requestManualRefresh(now: t0.addingTimeInterval(31)))
        XCTAssertEqual(failing.nextDue(now: t0.addingTimeInterval(31)), t0.addingTimeInterval(31))
    }

    func testLocationChangeKeepsARealRateLimit() {
        var policy = WeatherFetchPolicy()
        policy.recordRateLimited(retryAfterSeconds: 900, now: t0)
        policy.invalidateLocation()
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(900))
        var failing = WeatherFetchPolicy()
        failing.recordFailure(now: t0)
        failing.invalidateLocation()
        XCTAssertEqual(failing.nextDue(now: t0), t0)
    }

    func testDailyCapWaitsForTheNextDay() {
        var policy = WeatherFetchPolicy()
        for _ in 0..<WeatherTuning.dailyCap { policy.recordStarted(now: t0) }
        let due = policy.nextDue(now: t0)
        XCTAssertGreaterThan(due, t0)
        XCTAssertEqual(due.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400), 0)
    }

    // MARK: Timeline and animation

    private func sample(_ kind: WeatherConditionKind, at offset: TimeInterval, cover: Double) -> WeatherSample {
        WeatherSample(date: t0.addingTimeInterval(offset), kind: kind, cloudCover: cover, windSpeed: 4, windFrom: 250)
    }

    func testTimelineHoldsCurrentThenFollowsTheForecast() {
        let snapshot = WeatherSnapshot(
            coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .metNorway,
            current: sample(.clear, at: 0, cover: 0),
            hourly: [sample(.rain, at: 3600, cover: 1), sample(.rain, at: 7200, cover: 1)],
            fetchedAt: t0, expiresAt: nil, placeName: nil)
        let current = WeatherVisualState.target(for: snapshot.current)
        let rain = WeatherVisualState.target(for: snapshot.hourly[1])
        XCTAssertEqual(WeatherTimeline.target(at: t0.addingTimeInterval(600), snapshot: snapshot), current)
        XCTAssertEqual(WeatherTimeline.target(at: t0.addingTimeInterval(3 * 3600), snapshot: snapshot), rain)
        let a = WeatherTimeline.target(at: t0.addingTimeInterval(2_400), snapshot: snapshot).cloudLow
        let b = WeatherTimeline.target(at: t0.addingTimeInterval(3_000), snapshot: snapshot).cloudLow
        XCTAssertGreaterThan(b, a)
    }

    func testStationReportOverridesWhatIsFalling() {
        var model = sample(.cloudy, at: 0, cover: 0.9)
        model.cloudLow = 0.9
        var observed = sample(.rain, at: 0, cover: 1)
        observed.precipitationRate = 2
        observed.temperature = 15
        let merged = WeatherTimeline.merged(model, with: observed)
        XCTAssertEqual(merged.kind, .rain)
        XCTAssertEqual(merged.precipitationRate, 2)
        XCTAssertEqual(merged.temperature, 15)
        XCTAssertNil(merged.cloudLow)
    }

    func testDryStationStopsForecastRain() {
        var model = sample(.rain, at: 0, cover: 0.9)
        model.precipitationRate = 2.5
        let merged = WeatherTimeline.merged(model, with: sample(.cloudy, at: 0, cover: 1))
        XCTAssertEqual(merged.kind, .cloudy)
        XCTAssertNil(merged.precipitationRate)
    }

    func testStationCloudCoverCorrectsTheForecastOnlyWhenFarApart() {
        var clear = sample(.clear, at: 0, cover: 0.05)
        clear.cloudLow = 0
        let overcast = WeatherTimeline.merged(clear, with: sample(.cloudy, at: 0, cover: 1))
        XCTAssertEqual(overcast.kind, .cloudy)
        XCTAssertEqual(overcast.cloudCover, 1)
        XCTAssertNil(overcast.cloudLow)

        var partly = sample(.partlyCloudy, at: 0, cover: 0.5)
        partly.cloudLow = 0.4
        let agreed = WeatherTimeline.merged(partly, with: sample(.partlyCloudy, at: 0, cover: 0.45))
        XCTAssertEqual(agreed.kind, .partlyCloudy)
        XCTAssertEqual(agreed.cloudLow, 0.4)
    }

    func testStationLayersReplaceTheForecastsButCirrusOnlyWhenReported() {
        var model = sample(.partlyCloudy, at: 0, cover: 0.3)
        model.cloudLow = 0.1; model.cloudMid = 0.2; model.cloudHigh = 0.6
        var observed = sample(.cloudy, at: 0, cover: 1)
        observed.cloudLow = 0.45; observed.cloudMid = 1; observed.cloudBase = 1_200
        let merged = WeatherTimeline.merged(model, with: observed)
        XCTAssertEqual(merged.cloudLow, 0.45)
        XCTAssertEqual(merged.cloudMid, 1)
        XCTAssertEqual(merged.cloudHigh, 0.6)
        XCTAssertEqual(merged.cloudBase, 1_200)

        observed.cloudHigh = 0.2
        XCTAssertEqual(WeatherTimeline.merged(model, with: observed).cloudHigh, 0.2)
    }

    func testStationWithoutMeasurementsKeepsTheInterpolatedForecast() {
        func forecast(_ offset: TimeInterval, dewPoint: Double) -> WeatherSample {
            var s = sample(.partlyCloudy, at: offset, cover: 0.5)
            s.temperature = 20; s.dewPoint = dewPoint
            return s
        }
        var snapshot = WeatherSnapshot(
            coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .openMeteo,
            current: forecast(0, dewPoint: 10), hourly: [forecast(3600, dewPoint: 12), forecast(7200, dewPoint: 14)],
            fetchedAt: t0, expiresAt: nil, placeName: nil)
        let date = t0.addingTimeInterval(5_400)
        let interpolated = WeatherTimeline.target(at: date, snapshot: snapshot)
        snapshot.observation = sample(.partlyCloudy, at: 5_000, cover: 0.5)
        XCTAssertEqual(WeatherTimeline.target(at: date, snapshot: snapshot).cloudBase, interpolated.cloudBase)

        // A measured base still replaces the forecast's.
        snapshot.observation?.cloudBase = 2_000
        XCTAssertEqual(WeatherTimeline.target(at: date, snapshot: snapshot).cloudBase, 2.0, accuracy: 1e-9)
    }

    func testStationLayerSplitAndConvectiveCloud() {
        let split = NWSConditionMapping.cloudLayers([
            (amount: "SCT", base: 1_980), (amount: "BKN", base: 2_900), (amount: "FEW", base: 800)
        ])
        XCTAssertEqual(split?.low, 0.45)
        XCTAssertEqual(split?.mid, 0.75)
        XCTAssertEqual(split?.base, 800)
        XCTAssertNil(split?.high)
        // An observer's high layer is cirrus, not a mid deck.
        let high = NWSConditionMapping.cloudLayers([(amount: "FEW", base: 1_200), (amount: "BKN", base: 7_620)])
        XCTAssertEqual(high?.mid, 0)
        XCTAssertEqual(high?.high, 0.75)
        // Clear below the ceilometer's reach: no cloud, and no base.
        let clear = NWSConditionMapping.cloudLayers([(amount: "CLR", base: 3_810)])
        XCTAssertEqual(clear?.low, 0)
        XCTAssertNil(clear?.base)
        XCTAssertNil(NWSConditionMapping.cloudLayers([]))

        XCTAssertEqual(NWSConditionMapping.convectiveCloud(metar: "KMIA 131853Z 09010KT 10SM SCT030CB BKN250 31/22 A3001"), 1)
        XCTAssertEqual(NWSConditionMapping.convectiveCloud(metar: "KMIA 131853Z 09010KT 10SM FEW035TCU 31/22 A3001"), 0.6)
        XCTAssertNil(NWSConditionMapping.convectiveCloud(metar: "KMIA 131353Z 03008KT 10SM FEW027 28/21 A3003 RMK AO2 CB DSNT W"))
        XCTAssertNil(NWSConditionMapping.convectiveCloud(metar: ""))
    }

    func testCloudLayersAndFormFollowTheData() {
        var layered = sample(.partlyCloudy, at: 0, cover: 0.7)
        layered.cloudLow = 0.2; layered.cloudMid = 0.6; layered.cloudHigh = 0.1
        let altocumulus = WeatherVisualState.target(for: layered)
        // Mid cloud is its own layer, not folded into the low one.
        XCTAssertEqual(altocumulus.cloudLow, 0.2)
        XCTAssertEqual(altocumulus.cloudMid, 0.6)
        XCTAssertEqual(altocumulus.cloudBase, WeatherSkyGeometry.cloudBase)
        XCTAssertEqual(altocumulus.cumuliform, 0.5)
        // Rain from a deck the model files as mid cloud still falls from a low base.
        var rain = layered
        rain.kind = .rain
        XCTAssertEqual(WeatherVisualState.target(for: rain).cloudLow, 0.48, accuracy: 1e-9)

        // Base from the dew-point spread, clamped to what the sky can show.
        var humid = layered
        humid.temperature = 24; humid.dewPoint = 16
        XCTAssertEqual(WeatherVisualState.target(for: humid).cloudBase, 1.0, accuracy: 1e-9)
        humid.dewPoint = 24
        XCTAssertEqual(WeatherVisualState.target(for: humid).cloudBase, 0.5)
        humid.cloudBase = 1_800
        XCTAssertEqual(WeatherVisualState.target(for: humid).cloudBase, 1.8, accuracy: 1e-9)

        var stable = layered
        stable.cape = 0
        var unstable = layered
        unstable.cape = 2_500
        XCTAssertEqual(WeatherVisualState.target(for: stable).cumuliform, 0.25)
        XCTAssertGreaterThan(WeatherVisualState.target(for: unstable).cumuliform, 0.95)
        XCTAssertGreaterThan(WeatherVisualState.target(for: unstable).towering, 0.3)
        var reported = layered
        reported.convectiveCloud = 1
        XCTAssertEqual(WeatherVisualState.target(for: reported).towering, 0.75)
    }

    func testTimelineFollowsAFreshStationReport() {
        var snapshot = WeatherSnapshot(
            coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .openMeteo,
            current: sample(.clear, at: 0, cover: 0), hourly: [], fetchedAt: t0, expiresAt: nil, placeName: nil)
        snapshot.observation = sample(.rain, at: 300, cover: 1)
        let soon = t0.addingTimeInterval(600)
        XCTAssertEqual(WeatherTimeline.sample(at: soon, snapshot: snapshot).kind, .rain)
        XCTAssertGreaterThan(WeatherTimeline.target(at: soon, snapshot: snapshot).rain, 0.1)
        // A report older than the limit no longer counts.
        let later = t0.addingTimeInterval(300 + WeatherTimeline.observationMaxAge + 60)
        XCTAssertEqual(WeatherTimeline.sample(at: later, snapshot: snapshot).kind, .clear)
        XCTAssertEqual(WeatherTimeline.target(at: later, snapshot: snapshot).rain, 0)
    }

    func testVisualDistanceTellsAJumpFromADrift() {
        let clear = WeatherVisualState.target(for: sample(.clear, at: 0, cover: 0))
        let rain = WeatherVisualState.target(for: sample(.rain, at: 0, cover: 1))
        XCTAssertEqual(clear.distance(to: clear), 0)
        XCTAssertGreaterThan(clear.distance(to: rain), 0.5)
        XCTAssertLessThan(clear.distance(to: .lerp(clear, rain, 0.001)), 0.02)
    }

    func testAnimatorRetargetsWithoutAJump() {
        let clear = WeatherVisualState.target(for: sample(.clear, at: 0, cover: 0))
        let storm = WeatherVisualState.target(for: sample(.thunderstorm, at: 0, cover: 1))
        var animator = WeatherVisualAnimator()
        animator.begin(from: clear, at: 0, duration: 10)
        XCTAssertEqual(animator.apply(storm, at: 0), clear)
        XCTAssertEqual(animator.apply(storm, at: 10), storm)
        let midway = animator.apply(storm, at: 5)
        animator.begin(from: midway, at: 5, duration: 10)
        XCTAssertEqual(animator.apply(clear, at: 5), midway)
        XCTAssertFalse(animator.isActive(at: 15))
    }

    func testVisualTargetsReflectConditions() {
        let fog = WeatherVisualState.target(for: WeatherVisualState.demoSample(.fog, date: t0))
        XCTAssertGreaterThan(fog.fog, 0.8)
        let storm = WeatherVisualState.target(for: WeatherVisualState.demoSample(.thunderstorm, date: t0))
        XCTAssertGreaterThan(storm.lightning, 0.5)
        XCTAssertGreaterThan(storm.rain, 0.5)
        let snow = WeatherVisualState.target(for: WeatherVisualState.demoSample(.heavySnow, date: t0))
        XCTAssertGreaterThan(snow.snow, 0.8)
        XCTAssertEqual(snow.rain, 0)
        // A westerly drifts toward the east.
        XCTAssertGreaterThan(WeatherVisualState.target(for: sample(.clear, at: 0, cover: 0)).windEast, 0)
    }

    // MARK: Lightning

    func testLightningStrikesAreSpacedAndBounded() {
        var last: Double?
        for slot in Int64(0)..<5_000 {
            guard let strike = LightningSchedule.strike(inSlot: slot, rate: 1) else { continue }
            if let last { XCTAssertGreaterThanOrEqual(strike.time - last, 6) }
            last = strike.time
            var peak = 0.0
            for step in 0..<120 { peak = max(peak, LightningSchedule.flash(at: strike.time + Double(step) * 0.01, strike: strike)) }
            XCTAssertLessThanOrEqual(peak, 1)
            XCTAssertGreaterThan(peak, 0.5)
            XCTAssertEqual(LightningSchedule.flash(at: strike.time + LightningSchedule.flashDuration - 0.001, strike: strike), 0, accuracy: 0.001)
            XCTAssertEqual(LightningSchedule.flash(at: strike.time + LightningSchedule.flashDuration + 0.001, strike: strike), 0)
        }
        XCTAssertNotNil(last)
        XCTAssertNil(LightningSchedule.strike(inSlot: 3, rate: 0))
    }

    func testBoltStaysBetweenCloudAndGround() {
        var segments: [LightningSegment] = []
        LightningSchedule.buildBolt(seed: 42, top: SIMD2(0.5, 0.3), bottomY: 1.04, into: &segments)
        XCTAssertGreaterThanOrEqual(segments.count, 32)
        XCTAssertLessThanOrEqual(segments.count, 96)
        XCTAssertEqual(segments[0].ends.y, 0.3, accuracy: 0.0001)
        for segment in segments {
            XCTAssertGreaterThan(segment.ends.y, 0.15)
            XCTAssertLessThan(segment.ends.w, 1.3)
        }
    }

    // MARK: Sky geometry

    func testZenithStarMapsStraightUp() {
        let latitude = 40.0, longitude = -105.0
        let lst = WeatherSkyGeometry.greenwichSiderealDegrees(t0) + longitude
        let rows = WeatherSkyGeometry.equatorialRows(date: t0, latitude: latitude, longitude: longitude)
        let star = WeatherSkyGeometry.equatorialVector(rightAscension: lst, declination: latitude)
        let world = WeatherSkyGeometry.apply(rows, star)
        XCTAssertEqual(world.y, 1, accuracy: 0.0001)
        let pole = WeatherSkyGeometry.apply(rows, SIMD3(0, 0, 1))
        XCTAssertEqual(pole.y, Float(sin(latitude * .pi / 180)), accuracy: 0.0001)
        XCTAssertLessThan(pole.z, 0) // north is -z
    }

    func testCameraProjectionRoundTrips() {
        let camera = WeatherCamera(aspect: 16 / 10, azimuth: 180)
        for uv in [SIMD2<Float>(0.5, 0.5), SIMD2(0.1, 0.9), SIMD2(0.8, 0.2)] {
            let projected = camera.project(camera.ray(uv: uv))!
            XCTAssertEqual(projected.x, uv.x, accuracy: 0.0005)
            XCTAssertEqual(projected.y, uv.y, accuracy: 0.0005)
        }
        // The horizon sits just above the bottom edge.
        XCTAssertLessThan(camera.ray(uv: SIMD2(0.5, 1)).y, 0)
        XCTAssertGreaterThan(camera.ray(uv: SIMD2(0.5, 0.92)).y, 0)
    }

    func testSunTransmittanceReddensTowardTheHorizon() {
        let high = WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: 60), height: 0)
        let low = WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: 2), height: 0)
        XCTAssertGreaterThan(high.z, 0.7)
        XCTAssertGreaterThan(low.x, low.z)
        XCTAssertEqual(WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: -10), height: 0), .zero)
    }

    // MARK: Providers

    func testSampleBuilderPrefersMeasuredValues() {
        let rain = WeatherConditionReading(kind: .rain, cloudCover: 0.9, precipitationRate: 2.5)
        let measured = WeatherSample(date: t0, reading: rain, cloudCover: 0.6, measuredRate: 4)
        XCTAssertEqual(measured?.precipitationRate, 4)
        XCTAssertEqual(measured?.cloudCover, 0.6)
        let typical = WeatherSample(date: t0, reading: rain, cloudCover: nil, measuredRate: 0)
        XCTAssertEqual(typical?.precipitationRate, 2.5)
        XCTAssertEqual(typical?.cloudCover, 0.9)
        XCTAssertEqual(WeatherSample(date: t0, reading: nil, cloudCover: 0.5, measuredRate: nil)?.kind, .partlyCloudy)
        XCTAssertNil(WeatherSample(date: t0, reading: nil, cloudCover: nil, measuredRate: 1))
        let storm = WeatherConditionReading(kind: .thunderstorm, cloudCover: 1, thunder: true)
        XCTAssertEqual(WeatherSample(date: t0, reading: storm, cloudCover: nil, measuredRate: nil)?.thunderChance, 0.8)
        XCTAssertEqual(WeatherSample(date: t0, reading: storm, cloudCover: nil, measuredRate: nil, thunderChance: 0.3)?.thunderChance, 0.3)
    }

    func testCustomUserAgentIsPrintableASCII() {
        XCTAssertEqual(WeatherHTTP.sanitizedUserAgent("  Example Client/1.0\r\nX-Injected: 1 "), "Example Client/1.0X-Injected: 1")
        XCTAssertEqual(WeatherHTTP.sanitizedUserAgent("Example/2 ☁️"), "Example/2")
        XCTAssertNil(WeatherHTTP.sanitizedUserAgent(" \n "))
        XCTAssertNil(WeatherHTTP.sanitizedUserAgent(nil))
        XCTAssertEqual(WeatherHTTP.sanitizedUserAgent(String(repeating: "a", count: 400))?.count, 256)
    }

    func testAccuWeatherIcons() {
        XCTAssertEqual(AccuWeatherConditionMapping.reading(icon: 33)?.kind, .clear)
        XCTAssertEqual(AccuWeatherConditionMapping.reading(icon: 6)?.kind, .cloudy)
        XCTAssertEqual(AccuWeatherConditionMapping.reading(icon: 16)?.thunder, true)
        XCTAssertEqual(AccuWeatherConditionMapping.reading(icon: 29)?.kind, .sleet)
        XCTAssertNil(AccuWeatherConditionMapping.reading(icon: 9))
        XCTAssertEqual(AccuWeatherConditionMapping.convectiveCloud(icon: 15), 1)
        XCTAssertEqual(AccuWeatherConditionMapping.convectiveCloud(icon: 40), 0.6)
        XCTAssertNil(AccuWeatherConditionMapping.convectiveCloud(icon: 7))

        func reading(_ icon: Int, _ phrase: String, falling: Bool = false, type: String? = nil, intensity: String? = nil) -> WeatherConditionReading? {
            AccuWeatherConditionMapping.reading(icon: icon, phrase: phrase, hasPrecipitation: falling, type: type, intensity: intensity)
        }
        // Light rain under a cloudy icon.
        let light = reading(7, "Light rain", falling: true, type: "Rain", intensity: "Light")
        XCTAssertEqual(light?.kind, .rain)
        XCTAssertEqual(light?.precipitationRate ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(reading(12, "Heavy showers", falling: true, type: "Rain", intensity: "Heavy")?.kind, .heavyRain)
        XCTAssertEqual(reading(18, "Drizzle", falling: true, type: "Rain")?.kind, .drizzle)
        XCTAssertEqual(reading(24, "Freezing rain", falling: true, type: "Ice")?.kind, .freezingRain)
        XCTAssertEqual(reading(7, "Snow", falling: true, type: "Snow")?.kind, .snow)
        XCTAssertEqual(reading(5, "Smoke")?.kind, .smoke)
        XCTAssertEqual(reading(5, "Hazy sunshine")?.kind, .haze)
        XCTAssertEqual(reading(3, "Partly sunny")?.kind, .partlyCloudy)
    }

    func testAccuWeatherCurrentConditionsParsing() throws {
        let json = """
        [{"LocalObservationDateTime":"2026-11-16T21:57:00-06:00","EpochTime":1794887820,"WeatherText":"Light rain","WeatherIcon":12,
          "HasPrecipitation":true,"PrecipitationType":"Rain","IsDayTime":false,
          "Temperature":{"Metric":{"Value":12.5,"Unit":"C","UnitType":17},"Imperial":{"Value":54.0,"Unit":"F","UnitType":18}},
          "DewPoint":{"Metric":{"Value":11.0,"Unit":"C","UnitType":17}},
          "Wind":{"Direction":{"Degrees":225,"Localized":"SW","English":"SW"},"Speed":{"Metric":{"Value":18.0,"Unit":"km/h","UnitType":7}}},
          "WindGust":{"Speed":{"Metric":{"Value":36.0,"Unit":"km/h","UnitType":7}}},
          "Visibility":{"Metric":{"Value":8.0,"Unit":"km","UnitType":6}},"ObstructionsToVisibility":"",
          "CloudCover":100,"Ceiling":{"Metric":{"Value":900.0,"Unit":"m","UnitType":5}},
          "Precip1hr":{"Metric":{"Value":1.5,"Unit":"mm","UnitType":3}},
          "MobileLink":"http://www.accuweather.com/en/us/columbia-tn/38401/current-weather/331083?lang=en-us"}]
        """
        let conditions = try AccuWeatherClient.currentConditions(from: Data(json.utf8))
        let s = conditions.sample
        XCTAssertEqual(s.date, Date(timeIntervalSince1970: 1_794_887_820))
        XCTAssertEqual(s.kind, .rain)
        // Measured beats the "light" typical rate.
        XCTAssertEqual(s.precipitationRate, 1.5)
        XCTAssertEqual(s.cloudCover, 1)
        XCTAssertEqual(s.windSpeed ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(s.windGust ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(s.windFrom, 225)
        XCTAssertEqual(s.visibility, 8_000)
        XCTAssertEqual(s.temperature, 12.5)
        XCTAssertEqual(s.dewPoint, 11)
        XCTAssertEqual(s.cloudBase, 900)
        XCTAssertEqual(s.convectiveCloud, 0.6)
        XCTAssertNil(s.thunderChance)
        XCTAssertEqual(conditions.link?.scheme, "https")
        XCTAssertEqual(conditions.link?.host, "www.accuweather.com")

        // A clear night reports a ceiling of about 10 km, which is no cloud base.
        let clear = """
        [{"EpochTime":1794887820,"WeatherText":"Clear","WeatherIcon":33,"HasPrecipitation":false,"PrecipitationType":null,
          "Temperature":{"Metric":{"Value":2.5,"Unit":"C","UnitType":17}},"CloudCover":0,
          "Ceiling":{"Metric":{"Value":10180.0,"Unit":"m","UnitType":5}},"Precip1hr":{"Metric":{"Value":0.0,"Unit":"mm","UnitType":3}}}]
        """
        let night = try AccuWeatherClient.currentConditions(from: Data(clear.utf8)).sample
        XCTAssertEqual(night.kind, .clear)
        XCTAssertNil(night.cloudBase)
        XCTAssertNil(night.precipitationRate)
        XCTAssertThrowsError(try AccuWeatherClient.currentConditions(from: Data("[]".utf8)))
    }

    func testAccuWeatherHourlyParsing() throws {
        let json = """
        [{"DateTime":"2026-11-16T23:00:00-06:00","EpochDateTime":1794891600,"WeatherIcon":33,"IconPhrase":"Clear","HasPrecipitation":false,
          "IsDaylight":false,"Temperature":{"Value":1.5,"Unit":"C","UnitType":17},"DewPoint":{"Value":0.6,"Unit":"C","UnitType":17},
          "Wind":{"Speed":{"Value":3.6,"Unit":"km/h","UnitType":7},"Direction":{"Degrees":77,"Localized":"ENE","English":"ENE"}},
          "WindGust":{"Speed":{"Value":7.2,"Unit":"km/h","UnitType":7}},"Visibility":{"Value":16.1,"Unit":"km","UnitType":6},
          "Ceiling":{"Value":9144.0,"Unit":"m","UnitType":5},"PrecipitationProbability":0,"ThunderstormProbability":0,
          "TotalLiquid":{"Value":0.0,"Unit":"mm","UnitType":3},"CloudCover":0},
         {"EpochDateTime":1794895200,"WeatherIcon":15,"IconPhrase":"Thunderstorms","HasPrecipitation":true,"PrecipitationType":"Rain",
          "PrecipitationIntensity":"Heavy","Temperature":{"Value":57.2,"Unit":"F"},"Ceiling":{"Value":1200.0,"Unit":"m"},
          "PrecipitationProbability":80,"ThunderstormProbability":60,"TotalLiquid":{"Value":9.0,"Unit":"mm"},"CloudCover":100}]
        """
        let hours = try AccuWeatherClient.hourly(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_794_888_000))
        XCTAssertEqual(hours.map(\.kind), [.clear, .thunderstorm])
        XCTAssertEqual(hours[0].windSpeed ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(hours[0].windGust ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(hours[0].windFrom, 77)
        XCTAssertEqual(hours[0].visibility ?? 0, 16_100, accuracy: 1e-6)
        XCTAssertEqual(hours[0].thunderChance, 0)
        XCTAssertNil(hours[0].cloudBase)
        XCTAssertNil(hours[0].precipitationRate)
        XCTAssertEqual(hours[1].precipitationRate, 9)
        XCTAssertEqual(hours[1].precipitationChance, 0.8)
        XCTAssertEqual(hours[1].thunderChance, 0.6)
        XCTAssertEqual(hours[1].cloudBase, 1_200)
        XCTAssertEqual(hours[1].convectiveCloud, 1)
        XCTAssertEqual(hours[1].temperature ?? 0, 14, accuracy: 1e-9)
    }

    func testAccuWeatherLocationKeysAndLinks() throws {
        XCTAssertEqual(try AccuWeatherClient.locationKey(from: Data(#"{"Key":"38431_PC","LocalizedName":"La Jolla"}"#.utf8)), "38431_PC")
        XCTAssertThrowsError(try AccuWeatherClient.locationKey(from: Data(#"{"Key":"../331083"}"#.utf8)))
        XCTAssertThrowsError(try AccuWeatherClient.locationKey(from: Data(#"{"Code":"Unauthorized"}"#.utf8)))
        XCTAssertEqual(AccuWeatherClient.link("http://m.accuweather.com/en/us/x")?.absoluteString, "https://m.accuweather.com/en/us/x")
        XCTAssertNil(AccuWeatherClient.link("http://example.com/accuweather.com"))
    }

    func testAccuWeatherNowcastFromSummaries() throws {
        let now = Date(timeIntervalSince1970: 1_794_888_030)
        let base = Date(timeIntervalSince1970: 1_794_888_000)
        let dry = """
        {"Summary":{"Phrase":"No precipitation for at least 120 min","Type":null,"TypeId":0},
         "Summaries":[{"StartMinute":0,"EndMinute":119,"CountMinute":120,"MinuteText":"No precipitation for at least %MINUTE_VALUE min","Type":null,"TypeId":0}]}
        """
        let still = try AccuWeatherClient.nowcast(from: Data(dry.utf8), now: now)
        XCTAssertEqual(still.segments, [.init(start: base, end: base.addingTimeInterval(7_200), kind: nil)])
        XCTAssertNil(still.outlook(at: now))

        let showers = """
        {"Summaries":[{"StartMinute":0,"EndMinute":14,"MinuteText":"No precipitation for %MINUTE_VALUE min","Type":null,"TypeId":0},
          {"StartMinute":15,"EndMinute":59,"MinuteText":"Light rain for %MINUTE_VALUE min","Type":"RAIN","TypeId":1},
          {"StartMinute":60,"EndMinute":119,"MinuteText":"No precipitation for %MINUTE_VALUE min","Type":null,"TypeId":0}]}
        """
        let nowcast = try AccuWeatherClient.nowcast(from: Data(showers.utf8), now: now)
        XCTAssertEqual(nowcast.segments.map(\.kind), [nil, .rain, nil])
        XCTAssertEqual(nowcast.segments[1].precipitationRate ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(nowcast.outlook(at: now), .starting(.rain, at: base.addingTimeInterval(900)))
        XCTAssertEqual(nowcast.outlook(at: base.addingTimeInterval(1_200)), .ending(.rain, at: base.addingTimeInterval(3_600)))
        XCTAssertNil(nowcast.outlook(at: base.addingTimeInterval(4_000)))
    }

    func testAccuWeatherNowcastFromRadarIntervals() throws {
        let base = Date(timeIntervalSince1970: 1_794_888_000)
        let json = """
        {"Summaries":[{"StartMinute":0,"EndMinute":119,"Type":"RAIN","TypeId":1}],
         "Intervals":[{"StartEpochDateTime":1794888000,"Minute":0,"Dbz":0.0,"PrecipitationType":"Rain"},
          {"StartEpochDateTime":1794888060,"Minute":1,"Dbz":40.0,"PrecipitationType":"Rain"},
          {"StartEpochDateTime":1794888120,"Minute":2,"Dbz":40.0,"PrecipitationType":"Rain"},
          {"StartEpochDateTime":1794888180,"Minute":3,"Dbz":25.0,"PrecipitationType":"Snow"}]}
        """
        let nowcast = try AccuWeatherClient.nowcast(from: Data(json.utf8), now: base)
        XCTAssertEqual(nowcast.segments.map(\.kind), [nil, .heavyRain, .snow])
        XCTAssertEqual(nowcast.segments[1].end, base.addingTimeInterval(180))
        // 40 dBZ is about 11.5 mm/h of rain.
        XCTAssertEqual(nowcast.segments[1].precipitationRate ?? 0, 11.53, accuracy: 0.01)
        XCTAssertEqual(nowcast.segments[2].end, base.addingTimeInterval(240))
        XCTAssertEqual(nowcast.outlook(at: base), .starting(.heavyRain, at: base.addingTimeInterval(60)))
        XCTAssertEqual(nowcast.outlook(at: base.addingTimeInterval(90)), .continuing(.heavyRain, through: base.addingTimeInterval(240)))
    }

    func testNowcastCorrectsTheTimeline() {
        var rain = sample(.rain, at: 0, cover: 0.95)
        rain.precipitationRate = 2
        var snapshot = WeatherSnapshot(coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .accuWeather,
                                       current: rain, hourly: [], fetchedAt: t0, expiresAt: nil, placeName: nil)
        snapshot.nowcast = WeatherNowcast(segments: [
            .init(start: t0, end: t0.addingTimeInterval(600), kind: nil),
            .init(start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(1_800), kind: .heavyRain, precipitationRate: 9)
        ])
        // Radar sees nothing falling yet, whatever the report said.
        let pause = WeatherTimeline.sample(at: t0.addingTimeInterval(60), snapshot: snapshot)
        XCTAssertEqual(pause.kind, .cloudy)
        XCTAssertNil(pause.precipitationRate)
        let heavy = WeatherTimeline.sample(at: t0.addingTimeInterval(900), snapshot: snapshot)
        XCTAssertEqual(heavy.kind, .heavyRain)
        XCTAssertEqual(heavy.precipitationRate, 9)
        XCTAssertEqual(WeatherTimeline.target(at: t0.addingTimeInterval(900), snapshot: snapshot), .target(for: heavy))
        // Past the nowcast, the report and forecast are back.
        XCTAssertEqual(WeatherTimeline.sample(at: t0.addingTimeInterval(1_900), snapshot: snapshot), rain)

        var storm = rain
        storm.kind = .thunderstorm
        let radarRain = WeatherNowcast.Segment(start: t0, end: t0.addingTimeInterval(60), kind: .rain, precipitationRate: 3)
        XCTAssertEqual(WeatherTimeline.applying(radarRain, to: storm).kind, .thunderstorm)
        let fog = sample(.fog, at: 0, cover: 0.9)
        XCTAssertEqual(WeatherTimeline.applying(.init(start: t0, end: t0.addingTimeInterval(60), kind: nil), to: fog), fog)
    }

    func testStaleObservationsAreNotNow() {
        let report = sample(.rain, at: 0, cover: 1)
        XCTAssertEqual(WeatherTimeline.fresh(report, at: t0.addingTimeInterval(60 * 60)), report)
        XCTAssertNil(WeatherTimeline.fresh(report, at: t0.addingTimeInterval(WeatherTimeline.observationMaxAge)))
        XCTAssertNil(WeatherTimeline.fresh(nil, at: t0))
    }

    func testProviderBackoffHoldsUntilItsDeadline() {
        var backoff = WeatherProviderBackoff()
        backoff.record(WeatherFetchError.unauthorized, from: "accuWeather", now: t0)
        XCTAssertNil(backoff.waiting("accuWeather", now: t0))

        backoff.record(WeatherFetchError.rateLimited(600), from: "accuWeather", now: t0)
        XCTAssertEqual(backoff.waiting("accuWeather", now: t0.addingTimeInterval(599)), t0.addingTimeInterval(600))
        XCTAssertNil(backoff.waiting("accuWeather", now: t0.addingTimeInterval(600)))
        XCTAssertNil(backoff.waiting("openMeteo", now: t0))

        // No Retry-After (AccuWeather's 503) waits the fallback interval.
        backoff.record(WeatherFetchError.rateLimited(nil), from: "accuWeather", now: t0)
        XCTAssertEqual(backoff.waiting("accuWeather", now: t0), t0.addingTimeInterval(WeatherTuning.rateLimitFallback))

        backoff.prune(now: t0.addingTimeInterval(WeatherTuning.rateLimitFallback + 1))
        XCTAssertEqual(backoff, WeatherProviderBackoff())
        backoff.record(WeatherFetchError.rateLimited(60), from: "accuWeather", now: t0)
        backoff.clear("accuWeather")
        XCTAssertNil(backoff.waiting("accuWeather", now: t0))
    }

    func testNowcastIsFetchedOnlyWhenPrecipitationIsAbout() {
        var snapshot = WeatherSnapshot(coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .accuWeather,
                                       current: sample(.clear, at: 0, cover: 0), hourly: [sample(.partlyCloudy, at: 3600, cover: 0.4)],
                                       fetchedAt: t0, expiresAt: nil, placeName: nil)
        XCTAssertFalse(WeatherNowcast.isWorthFetching(for: snapshot, now: t0))
        var unlikely = sample(.rain, at: 7200, cover: 0.8)
        unlikely.precipitationChance = 0.1
        snapshot.hourly.append(unlikely)
        XCTAssertFalse(WeatherNowcast.isWorthFetching(for: snapshot, now: t0))
        snapshot.hourly[1].precipitationChance = 0.4
        XCTAssertTrue(WeatherNowcast.isWorthFetching(for: snapshot, now: t0))
        // Rain beyond three hours doesn't count.
        XCTAssertFalse(WeatherNowcast.isWorthFetching(for: snapshot, now: t0.addingTimeInterval(-4 * 3600)))
        snapshot.hourly.removeLast()
        snapshot.observation = sample(.drizzle, at: 0, cover: 1)
        XCTAssertTrue(WeatherNowcast.isWorthFetching(for: snapshot, now: t0))
    }

    func testPreviewTimesFindNoonAndSunset() {
        // A synthetic day: altitude peaks at t0 + 3 h.
        let altitude: (Date) -> Double = { 50 * cos(($0.timeIntervalSince(self.t0) - 3 * 3600) / 86_400 * 2 * .pi) }
        let noon = WeatherSkyGeometry.previewDate(.noon, around: t0, altitude: altitude)
        XCTAssertEqual(noon.timeIntervalSince(t0), 3 * 3600, accuracy: 600)
        let sunset = WeatherSkyGeometry.previewDate(.sunset, around: t0, altitude: altitude)
        XCTAssertGreaterThan(sunset, noon)
        XCTAssertLessThan(altitude(sunset.addingTimeInterval(600)), 3)
    }
}
