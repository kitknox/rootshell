//
//  SidebarWeatherRow.swift
//  rootshell
//
//  Live Weather's line in the sidebar footer: current conditions in the
//  usage rows' small type, tap for a detail popover the size of theirs.
//  Renders nothing unless a live (not demo) Live Weather view is on screen
//  and its Show in Tab Sidebar setting is on.
//

#if !CHINA_BUILD
import SwiftUI

struct SidebarWeatherRow: View {
    let metrics: SidebarMetrics

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var showsDetail = false

    var body: some View {
        if let snapshot = WeatherStore.shared.sidebarSnapshot {
            // The named conditions follow the forecast hour by hour.
            TimelineView(.everyMinute) { context in
                Button {
                    showsDetail = true
                } label: {
                    WeatherCompactRow(snapshot: snapshot, now: context.date, metrics: metrics)
                }
                .buttonStyle(.plain)
            }
            .background(AnchoredUsagePopover(isPresented: $showsDetail) {
                WeatherDetailPopover()
                    .themedSubSheet(sheetThemeColors)
            })
        }
    }
}

// MARK: - Compact row

private struct WeatherCompactRow: View {
    let snapshot: WeatherSnapshot
    let now: Date
    let metrics: SidebarMetrics

    var body: some View {
        let sample = snapshot.displaySample(at: now)
        HStack(spacing: 8) {
            Image(systemName: sample.kind.symbolName(night: snapshot.isNight(at: now)))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: metrics.subtitleSize))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            Text(verbatim: sample.kind.localizedName)
                .font(.system(size: metrics.subtitleSize))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)

            Spacer(minLength: 6)

            if let temperature = sample.temperature {
                Text(verbatim: WeatherFormat.temperature(temperature))
                    .font(.system(size: metrics.subtitleSize, weight: .regular).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Dimmed like a stale usage row once the data is hours old.
        .opacity(now.timeIntervalSince(snapshot.fetchedAt) > 3 * 3600 ? 0.55 : 1.0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel(sample)))
    }

    private func accessibilityLabel(_ sample: WeatherSample) -> String {
        guard let temperature = sample.temperature else {
            return String(localized: "Weather, \(sample.kind.localizedName)",
                          comment: "Accessibility: current weather condition in the sidebar")
        }
        return String(localized: "Weather, \(sample.kind.localizedName), \(WeatherFormat.temperature(temperature, width: .wide))",
                      comment: "Accessibility: current weather condition and temperature in the sidebar")
    }
}

// MARK: - Detail popover

private struct WeatherDetailPopover: View {
    var body: some View {
        // The store is @Observable, so a refresh lands while this is open.
        TimelineView(.everyMinute) { context in
            if let snapshot = WeatherStore.shared.sidebarSnapshot {
                content(snapshot, now: context.date)
            } else {
                Text("Live Weather isn't on screen.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func content(_ snapshot: WeatherSnapshot, now: Date) -> some View {
        let sample = snapshot.displaySample(at: now)
        let upcoming = Array(snapshot.hourly.filter { $0.date > now }.prefix(6))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: sample.kind.symbolName(night: snapshot.isNight(at: now)))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 14))
                Text(verbatim: sample.kind.localizedName)
                    .font(.system(size: 13, weight: .semibold))
                if let place = WeatherStore.shared.activePlaceName {
                    Text(verbatim: place)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Text(verbatim: AgentUsageFormat.updatedAgo(fetchedAt: snapshot.fetchedAt, now: now))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                if let temperature = sample.temperature {
                    Text(verbatim: WeatherFormat.temperature(temperature))
                        .font(.system(size: 28, weight: .light).monospacedDigit())
                }
                Spacer()
                if let range = temperatureRange(sample, upcoming: snapshot.hourly) {
                    Text(verbatim: range)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if let outlook = snapshot.nowcast?.outlook(at: now) {
                Label {
                    Text(verbatim: WeatherFormat.nowcast(outlook, now: now))
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                detailRow(String(localized: "Cloud Cover", comment: "Weather detail label"),
                          sample.cloudCover.formatted(.percent.precision(.fractionLength(0))))
                if let chance = sample.precipitationChance ?? upcoming.first?.precipitationChance {
                    detailRow(String(localized: "Precipitation", comment: "Weather detail label: chance of rain or snow"),
                              chance.formatted(.percent.precision(.fractionLength(0))))
                }
                if let wind = sample.windSpeed {
                    windRow(speed: wind, gust: sample.windGust, from: sample.windFrom)
                }
                if let visibility = sample.visibility {
                    detailRow(String(localized: "Visibility", comment: "Weather detail label"), WeatherFormat.distance(visibility))
                }
            }

            if !upcoming.isEmpty {
                HStack(spacing: 0) {
                    ForEach(upcoming, id: \.date) { hour in
                        VStack(spacing: 4) {
                            Text(hour.date, format: .dateTime.hour())
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Image(systemName: hour.kind.symbolName(night: snapshot.isNight(at: hour.date)))
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 12))
                                .frame(height: 16)
                            Text(verbatim: hour.temperature.map { WeatherFormat.temperature($0) } ?? "–")
                                .font(.system(size: 11).monospacedDigit())
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                RefreshButton(now: now)
                Spacer()
                // Open-Meteo's licence asks for a link wherever its data is shown.
                Link(destination: snapshot.link ?? snapshot.source.website) {
                    HStack(spacing: 3) {
                        Text(verbatim: snapshot.source.attribution)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }

    private func windRow(speed: Double, gust: Double?, from: Double?) -> some View {
        HStack(spacing: 4) {
            Text("Wind")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            if let from {
                // Points where the wind is going.
                Image(systemName: "location.north.fill")
                    .font(.system(size: 8))
                    .rotationEffect(.degrees(from + 180))
                    .foregroundColor(.secondary)
            }
            Text(verbatim: gust.map { gust in
                String(localized: "\(WeatherFormat.windSpeed(speed)), gusts \(WeatherFormat.windSpeed(gust))",
                       comment: "Weather detail: wind speed and gust speed")
            } ?? WeatherFormat.windSpeed(speed))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }

    /// "H:68° L:59°" over the coming day.
    private func temperatureRange(_ sample: WeatherSample, upcoming: [WeatherSample]) -> String? {
        let values = ([sample] + upcoming.prefix(24)).compactMap(\.temperature)
        guard let low = values.min(), let high = values.max(), high - low >= 1 else { return nil }
        return String(localized: "H:\(WeatherFormat.temperature(high)) L:\(WeatherFormat.temperature(low))",
                      comment: "Weather: high and low temperature over the next 24 hours")
    }
}

/// Manual refresh, held to the same floor as the button in settings.
private struct RefreshButton: View {
    let now: Date

    var body: some View {
        let store = WeatherStore.shared
        let fetching = store.status == .fetching
        Button {
            store.refreshNow()
        } label: {
            HStack(spacing: 5) {
                if fetching {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(verbatim: fetching
                     ? String(localized: "Checking", comment: "Live Weather refresh in progress")
                     : String(localized: "Refresh", comment: "Refresh Live Weather"))
                    .font(.system(size: 11, weight: .medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(fetching || store.manualRefreshAt > now)
    }
}
#endif
