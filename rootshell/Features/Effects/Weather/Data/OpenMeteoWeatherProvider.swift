// OpenMeteoWeatherProvider.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import os

/// The free default. Open-Meteo for the forecast everywhere. In the US, the
/// nearest NWS station corrects "now", and the NWS forecast stands in when
/// Open-Meteo fails; MET Norway is the last resort. All within one refresh.
nonisolated struct OpenMeteoWeatherProvider: WeatherProvider {
    var id: WeatherProviderID { .openMeteo }

    func fetch(_ coordinate: WeatherCoordinate, previous: WeatherSnapshot?, state: inout WeatherSourceState,
               now: Date) async throws -> WeatherFetchOutcome {
        let point = await nwsPoint(coordinate, state: &state, now: now)
        var snapshot: WeatherSnapshot?
        do {
            snapshot = try await OpenMeteoClient().fetch(coordinate, now: now)
        } catch {
            try Task.checkCancellation()
            Ghostty.logger.info("Live Weather: Open-Meteo unavailable (\(String(describing: error), privacy: .public))")
        }
        if snapshot == nil, let point {
            do {
                // Its "now" is already the station's report.
                snapshot = try await NWSClient().fetch(coordinate, point: point, now: now)
                state.observationCheckedAt = now
            } catch {
                if case WeatherFetchError.notCovered = error {
                    // A stale grid can also 404; drop it and remember the miss.
                    state.nwsPoints[coordinate.key] = nil
                    state.nwsUncovered[coordinate.key] = now
                }
                try Task.checkCancellation()
                Ghostty.logger.info("Live Weather: NWS unavailable (\(String(describing: error), privacy: .public))")
            }
        }
        if let snapshot {
            return .updated(await observed(snapshot, point: point, state: &state, now: now))
        }

        Ghostty.logger.info("Live Weather: using MET Norway")
        let validator = state.metCoordinate == coordinate && previous?.source == .metNorway
            && previous?.coordinate == coordinate ? state.metValidator : nil
        switch try await METNorwayClient().fetch(coordinate, validator: validator, now: now) {
        case .updated(let snapshot, let next):
            state.metCoordinate = coordinate
            state.metValidator = next
            return .updated(await observed(snapshot, point: point, state: &state, now: now))
        case .notModified(let next):
            state.metValidator = next
            return .notModified(expiresAt: next.expires)
        }
    }

    /// The station's latest report, outside the US never.
    func observationDue(for snapshot: WeatherSnapshot, state: WeatherSourceState) -> Date? {
        let coordinate = snapshot.coordinate
        guard NWSCoverage.contains(coordinate), state.nwsUncovered[coordinate.key] == nil else { return nil }
        return (state.observationCheckedAt ?? .distantPast).addingTimeInterval(WeatherSourceRouter.observationInterval)
    }

    func observe(_ snapshot: WeatherSnapshot, state: inout WeatherSourceState, now: Date) async throws -> WeatherNowUpdate? {
        state.observationCheckedAt = now
        guard let point = await nwsPoint(snapshot.coordinate, state: &state, now: now), let station = point.stationId,
              let sample = await NWSClient().observation(station: station, now: now) else { return nil }
        return WeatherNowUpdate(observation: sample, observationStation: station)
    }

    private func observed(_ snapshot: WeatherSnapshot, point: NWSPointInfo?, state: inout WeatherSourceState,
                          now: Date) async -> WeatherSnapshot {
        guard snapshot.source != .nws, let station = point?.stationId else { return snapshot }
        var snapshot = snapshot
        state.observationCheckedAt = now
        snapshot.observation = await NWSClient().observation(station: station, now: now)
        snapshot.observationStation = snapshot.observation == nil ? nil : station
        return snapshot
    }

    /// The NWS grid for a US coordinate, cached for a week; nil elsewhere or
    /// while NWS is unreachable.
    private func nwsPoint(_ coordinate: WeatherCoordinate, state: inout WeatherSourceState,
                          now: Date) async -> NWSPointInfo? {
        let key = coordinate.key
        guard NWSCoverage.contains(coordinate), state.nwsUncovered[key] == nil else { return nil }
        if let cached = state.nwsPoints[key] { return cached }
        do {
            let point = try await NWSClient().point(for: coordinate, now: now)
            state.nwsPoints[key] = point
            return point
        } catch {
            if case WeatherFetchError.notCovered = error { state.nwsUncovered[key] = now }
            return nil
        }
    }
}
#endif
