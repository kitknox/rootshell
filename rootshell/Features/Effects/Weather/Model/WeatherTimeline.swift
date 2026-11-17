// WeatherTimeline.swift
// rootshell

#if !CHINA_BUILD
import Foundation

/// Evolves the scene between fetches: current conditions first, then the
/// hourly forecast, interpolated so nothing jumps on the hour. A recent
/// station report corrects what the forecast says about now, and a radar
/// nowcast what is falling over the next two hours.
nonisolated enum WeatherTimeline {
    static let currentHold: TimeInterval = 30 * 60
    static let handoff: TimeInterval = 30 * 60
    static let observationMaxAge: TimeInterval = 75 * 60

    static func target(at date: Date, snapshot: WeatherSnapshot) -> WeatherVisualState {
        let observed = observedTarget(at: date, snapshot: snapshot)
        guard let segment = snapshot.nowcast?.segment(at: date) else { return observed }
        let sample = observedSample(at: date, snapshot: snapshot)
        let corrected = applying(segment, to: sample)
        return corrected == sample ? observed : .target(for: corrected)
    }

    /// The conditions to name at `date`.
    static func sample(at date: Date, snapshot: WeatherSnapshot) -> WeatherSample {
        let sample = observedSample(at: date, snapshot: snapshot)
        guard let segment = snapshot.nowcast?.segment(at: date) else { return sample }
        return applying(segment, to: sample)
    }

    /// Radar beats the forecast and the last report on what is falling.
    static func applying(_ segment: WeatherNowcast.Segment, to sample: WeatherSample) -> WeatherSample {
        var s = sample
        guard let kind = segment.kind else {
            guard sample.kind.isPrecipitation else { return sample }
            s.kind = .forCover(sample.cloudCover)
            s.precipitationRate = nil
            s.precipitationChance = nil
            s.thunderChance = nil
            return s
        }
        // Radar can't see lightning; keep a storm the forecast or a report gave.
        s.kind = sample.kind == .thunderstorm && (kind == .rain || kind == .heavyRain) ? .thunderstorm : kind
        s.precipitationRate = segment.precipitationRate ?? (sample.kind.isPrecipitation ? sample.precipitationRate : nil)
        s.precipitationChance = nil
        s.cloudCover = max(sample.cloudCover, 0.8)
        if let low = sample.cloudLow { s.cloudLow = max(low, 0.7) }
        s.fogFraction = nil
        return s
    }

    private static func observedTarget(at date: Date, snapshot: WeatherSnapshot) -> WeatherVisualState {
        var model = modelTarget(at: date, snapshot: snapshot)
        guard let observation = freshObservation(at: date, snapshot: snapshot) else { return model }
        let base = modelSample(at: date, snapshot: snapshot)
        let corrected = merged(base, with: observation)
        // Only take over when the station changes the picture; what it measured
        // still refines the forecast, which otherwise keeps its interpolation.
        guard corrected.kind != base.kind || abs(corrected.cloudCover - base.cloudCover) >= 0.25 else {
            let measured = WeatherVisualState.target(for: corrected)
            if observation.cloudBase != nil || (observation.temperature != nil && observation.dewPoint != nil) {
                model.cloudBase = measured.cloudBase
            }
            if observation.convectiveCloud != nil {
                model.cumuliform = max(model.cumuliform, measured.cumuliform)
                model.towering = max(model.towering, measured.towering)
            }
            return model
        }
        return .target(for: corrected)
    }

    private static func observedSample(at date: Date, snapshot: WeatherSnapshot) -> WeatherSample {
        let base = modelSample(at: date, snapshot: snapshot)
        guard let observation = freshObservation(at: date, snapshot: snapshot) else { return base }
        return merged(base, with: observation)
    }

    /// A station report over a forecast. The station is believed about what is
    /// falling, fog and smoke, and cloud cover far from the forecast's; its
    /// measured temperature, wind, visibility, and cloud base replace the forecast's.
    static func merged(_ model: WeatherSample, with observed: WeatherSample) -> WeatherSample {
        var sample = model
        sample.temperature = observed.temperature ?? model.temperature
        sample.dewPoint = observed.dewPoint ?? model.dewPoint
        sample.windSpeed = observed.windSpeed ?? model.windSpeed
        sample.windGust = observed.windGust ?? model.windGust
        sample.windFrom = observed.windFrom ?? model.windFrom
        sample.visibility = observed.visibility ?? model.visibility
        sample.cloudBase = observed.cloudBase ?? model.cloudBase
        sample.convectiveCloud = observed.convectiveCloud ?? model.convectiveCloud
        let coverDiffers = abs(observed.cloudCover - model.cloudCover) >= 0.5
        if coverDiffers {
            sample.cloudCover = observed.cloudCover
            takeLayers(from: observed, into: &sample)
        }
        if observed.kind.isWeather {
            sample.kind = observed.kind
            sample.cloudCover = max(sample.cloudCover, observed.cloudCover)
            sample.precipitationRate = observed.precipitationRate
            sample.thunderChance = observed.thunderChance
            sample.fogFraction = nil
            if !coverDiffers { takeLayers(from: observed, into: &sample) }
        } else if model.kind.isWeather || coverDiffers {
            // The station sees nothing falling: keep the forecast's sky, not its rain.
            sample.kind = observed.kind == .windy ? .windy : .forCover(sample.cloudCover)
            sample.precipitationRate = nil
            sample.thunderChance = nil
            sample.fogFraction = nil
        }
        return sample
    }

    /// The station's layers. Most stations can't see high cloud, so the
    /// forecast's stays unless an observer reported a high layer.
    private static func takeLayers(from observed: WeatherSample, into sample: inout WeatherSample) {
        guard let low = observed.cloudLow else {
            sample.cloudLow = nil; sample.cloudMid = nil; sample.cloudHigh = nil
            return
        }
        sample.cloudLow = low
        sample.cloudMid = observed.cloudMid
        sample.cloudHigh = observed.cloudHigh ?? sample.cloudHigh
    }

    // MARK: Forecast

    private static func modelTarget(at date: Date, snapshot: WeatherSnapshot) -> WeatherVisualState {
        let current = WeatherVisualState.target(for: snapshot.current)
        let elapsed = date.timeIntervalSince(snapshot.fetchedAt)
        guard elapsed > currentHold, let forecast = forecast(at: date, hourly: snapshot.hourly) else { return current }
        let t = smoothstep(min(max((elapsed - currentHold) / handoff, 0), 1))
        return .lerp(current, forecast, t)
    }

    /// The reported conditions, then the forecast hour, handing over midway
    /// through the sky's own transition.
    private static func modelSample(at date: Date, snapshot: WeatherSnapshot) -> WeatherSample {
        guard date.timeIntervalSince(snapshot.fetchedAt) > currentHold + handoff / 2 else { return snapshot.current }
        return snapshot.hourly.last(where: { $0.date <= date }) ?? snapshot.hourly.first ?? snapshot.current
    }

    private static func freshObservation(at date: Date, snapshot: WeatherSnapshot) -> WeatherSample? {
        fresh(snapshot.observation, at: date)
    }

    /// An observation still recent enough to describe `date`.
    static func fresh(_ observation: WeatherSample?, at date: Date) -> WeatherSample? {
        guard let observation, date.timeIntervalSince(observation.date) < observationMaxAge else { return nil }
        return observation
    }

    /// Hourly samples are interpolated across each hour they describe.
    static func forecast(at date: Date, hourly: [WeatherSample]) -> WeatherVisualState? {
        guard let first = hourly.first else { return nil }
        if date <= first.date { return .target(for: first) }
        for (a, b) in zip(hourly, hourly.dropFirst()) where date >= a.date && date < b.date {
            let span = b.date.timeIntervalSince(a.date)
            let t = span > 0 ? date.timeIntervalSince(a.date) / span : 0
            return .lerp(.target(for: a), .target(for: b), smoothstep(t))
        }
        return hourly.last.map { .target(for: $0) }
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
#endif
