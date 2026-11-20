//
//  VPNTrafficChart.swift
//  rootshell
//
//  Interactive throughput summary and overlaid area/line chart showing
//  download and upload rates over time from VPNTrafficSnapshot counters.
//

import SwiftUI
import Charts

struct VPNTrafficChart: View {
    let snapshots: [VPNTrafficSnapshot]
    var totalBytesIn: Int64? = nil
    var totalBytesOut: Int64? = nil

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var window: TimeWindow = .oneMinute
    @State private var selectedDate: Date?

    enum TimeWindow: String, CaseIterable, Identifiable {
        case oneMinute = "1m"
        case fiveMinutes = "5m"

        var id: String { rawValue }

        var duration: TimeInterval {
            switch self {
            case .oneMinute: 60
            case .fiveMinutes: 300
            }
        }

        var startAxisLabel: String {
            switch self {
            case .oneMinute: "-1m"
            case .fiveMinutes: "-5m"
            }
        }

        var midAxisLabel: String {
            switch self {
            case .oneMinute: "-30s"
            case .fiveMinutes: "-2.5m"
            }
        }
    }

    private static let staleThreshold: TimeInterval = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            chartContent(now: context.date)
        }
    }

    private func chartContent(now referenceDate: Date) -> some View {
        let allRates = Self.computeRates(from: snapshots)
        let latestTimestamp = snapshots.last?.timestamp
        let now = latestTimestamp.map { max(referenceDate, $0) } ?? referenceDate
        let sampleAge = latestTimestamp.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let isStale = latestTimestamp != nil && sampleAge >= Self.staleThreshold

        // Anchor to the latest live sample to avoid jitter between 2s polls,
        // but advance to wall-clock time once updates stall so "Now" stays honest.
        let windowEnd = isStale ? now : (latestTimestamp ?? now)
        let windowStart = windowEnd.addingTimeInterval(-window.duration)
        let windowMid = windowEnd.addingTimeInterval(-window.duration / 2)
        let visibleRates = allRates.filter { $0.date >= windowStart && $0.date <= windowEnd }
        let inspectedRate = selectedDate.flatMap { Self.nearestRate(to: $0, in: visibleRates) }
        let liveRate = isStale ? nil : (visibleRates.last ?? allRates.last)
        let displayedRate = inspectedRate ?? liveRate
        let peakDown = visibleRates.map(\.downloadMbps).max() ?? 0
        let peakUp = visibleRates.map(\.uploadMbps).max() ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            throughputCards(
                downloadMbps: displayedRate?.downloadMbps,
                uploadMbps: displayedRate?.uploadMbps,
                isInspecting: inspectedRate != nil,
                isStale: isStale && inspectedRate == nil
            )

            chartHeader(
                inspectedRate: inspectedRate,
                windowEnd: windowEnd,
                peakDown: peakDown,
                peakUp: peakUp,
                staleAge: isStale ? sampleAge : nil
            )

            if visibleRates.isEmpty {
                emptyPlaceholder(staleAge: isStale ? sampleAge : nil)
            } else {
                chart(
                    rates: visibleRates,
                    inspectedRate: inspectedRate,
                    windowStart: windowStart,
                    windowMid: windowMid,
                    windowEnd: windowEnd,
                    peakMbps: max(peakDown, peakUp),
                    showLiveEndpoint: !isStale
                )
                .frame(height: 136)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Throughput KPI Cards

    private func throughputCards(
        downloadMbps: Double?,
        uploadMbps: Double?,
        isInspecting: Bool,
        isStale: Bool
    ) -> some View {
        HStack(spacing: 10) {
            throughputTile(
                title: String(localized: "Download", comment: "VPN throughput card title"),
                systemImage: "arrow.down.circle.fill",
                rate: isStale ? "—" : Self.formatRate(downloadMbps ?? 0),
                total: totalBytesIn.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) },
                color: .blue,
                isHighlighted: isInspecting,
                isStale: isStale
            )
            throughputTile(
                title: String(localized: "Upload", comment: "VPN throughput card title"),
                systemImage: "arrow.up.circle.fill",
                rate: isStale ? "—" : Self.formatRate(uploadMbps ?? 0),
                total: totalBytesOut.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) },
                color: .orange,
                isHighlighted: isInspecting,
                isStale: isStale
            )
        }
    }

    private func throughputTile(
        title: String,
        systemImage: String,
        rate: String,
        total: String?,
        color: Color,
        isHighlighted: Bool,
        isStale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color.opacity(isStale ? 0.5 : 1.0))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(rate)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(isStale ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: rate)

            if let total {
                Text(String(localized: "\(total) total", comment: "VPN cumulative transferred bytes caption"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(isHighlighted ? 0.14 : (isStale ? 0.04 : 0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(isHighlighted ? 0.45 : 0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chart Header

    private func chartHeader(
        inspectedRate: TrafficRate?,
        windowEnd: Date,
        peakDown: Double,
        peakUp: Double,
        staleAge: TimeInterval?
    ) -> some View {
        HStack(spacing: 8) {
            if let inspectedRate {
                let ago = max(0, Int(windowEnd.timeIntervalSince(inspectedRate.date).rounded()))
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(inspectedRate.date, format: .dateTime.hour().minute().second())
                        .font(.caption.weight(.medium).monospacedDigit())
                    if ago > 0 {
                        Text("(\(Self.formatAge(TimeInterval(ago))) ago)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let staleAge {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(String(
                        localized: "Stale · \(Self.formatAge(staleAge)) ago",
                        comment: "VPN traffic chart header when sample updates have stalled"
                    ))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 6) {
                    Text(String(localized: "Peak", comment: "VPN chart peak throughput prefix"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.blue)
                        Text(Self.formatRate(peakDown))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                        Text(Self.formatRate(peakUp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            windowPicker
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 2) {
            ForEach(TimeWindow.allCases) { option in
                let isSelected = window == option
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        window = option
                        selectedDate = nil
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.caption2.weight(isSelected ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Chart

    private func chart(
        rates: [TrafficRate],
        inspectedRate: TrafficRate?,
        windowStart: Date,
        windowMid: Date,
        windowEnd: Date,
        peakMbps: Double,
        showLiveEndpoint: Bool
    ) -> some View {
        let yMax = max(peakMbps * 1.18, 0.1)
        let latestRate = rates.last
        let pointStrokeColor = sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)

        let downGradient = LinearGradient(
            colors: [Color.blue.opacity(0.28), Color.blue.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
        let upGradient = LinearGradient(
            colors: [Color.orange.opacity(0.22), Color.orange.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )

        return Chart {
            // Download area + line
            ForEach(rates) { rate in
                AreaMark(
                    x: .value("Time", rate.date),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Mbps", rate.downloadMbps),
                    series: .value("Direction", "Down")
                )
                .foregroundStyle(downGradient)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", rate.date),
                    y: .value("Mbps", rate.downloadMbps),
                    series: .value("Direction", "Down")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }

            // Upload area + line
            ForEach(rates) { rate in
                AreaMark(
                    x: .value("Time", rate.date),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Mbps", rate.uploadMbps),
                    series: .value("Direction", "Up")
                )
                .foregroundStyle(upGradient)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", rate.date),
                    y: .value("Mbps", rate.uploadMbps),
                    series: .value("Direction", "Up")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }

            // Interactive scrub cursor or live trailing marker
            if let inspectedRate {
                RuleMark(x: .value("Selected", inspectedRate.date))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("Time", inspectedRate.date),
                    y: .value("Mbps", inspectedRate.downloadMbps)
                )
                .foregroundStyle(Color.blue)
                .symbolSize(56)
                .symbol {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(pointStrokeColor, lineWidth: 2))
                }

                PointMark(
                    x: .value("Time", inspectedRate.date),
                    y: .value("Mbps", inspectedRate.uploadMbps)
                )
                .foregroundStyle(Color.orange)
                .symbolSize(56)
                .symbol {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(pointStrokeColor, lineWidth: 2))
                }
            } else if showLiveEndpoint, let latestRate {
                PointMark(
                    x: .value("Time", latestRate.date),
                    y: .value("Mbps", latestRate.downloadMbps)
                )
                .foregroundStyle(Color.blue)
                .symbol {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }

                PointMark(
                    x: .value("Time", latestRate.date),
                    y: .value("Mbps", latestRate.uploadMbps)
                )
                .foregroundStyle(Color.orange)
                .symbol {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: windowStart...windowEnd)
        .chartYScale(domain: 0...yMax)
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.formatAxisRate(v))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [windowStart, windowMid, windowEnd]) { value in
                AxisValueLabel(anchor: xAxisAnchor(for: value.index)) {
                    Text(xAxisLabel(for: value.index))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func xAxisAnchor(for index: Int) -> UnitPoint {
        switch index {
        case 0: .topLeading
        case 2: .topTrailing
        default: .top
        }
    }

    private func xAxisLabel(for index: Int) -> String {
        switch index {
        case 0: window.startAxisLabel
        case 1: window.midAxisLabel
        default: String(localized: "Now", comment: "VPN traffic chart current time axis label")
        }
    }

    // MARK: - Empty / Warming-up / Stale Placeholder

    private func emptyPlaceholder(staleAge: TimeInterval?) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 0.5)
                Spacer()
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 0.5)
                Spacer()
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }
            .padding(.bottom, 16)

            HStack(spacing: 6) {
                if let staleAge {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(String(
                        localized: "No traffic updates for \(Self.formatAge(staleAge))",
                        comment: "VPN chart placeholder when traffic samples are older than the visible window"
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(localized: "Collecting traffic data…", comment: "VPN chart placeholder while gathering first samples"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(height: 136)
    }

    // MARK: - Rate Computation

    private static func computeRates(from snapshots: [VPNTrafficSnapshot]) -> [TrafficRate] {
        guard snapshots.count >= 2 else { return [] }

        var rates: [TrafficRate] = []
        rates.reserveCapacity(snapshots.count - 1)
        for i in 1..<snapshots.count {
            let prev = snapshots[i - 1]
            let curr = snapshots[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0 else { continue }

            let downDelta = max(0, curr.bytesIn - prev.bytesIn)
            let upDelta = max(0, curr.bytesOut - prev.bytesOut)

            // Convert bytes/sec to megabits/sec (bytes * 8 / 1_000_000)
            let downMbps = (Double(downDelta) / dt) * 8.0 / 1_000_000.0
            let upMbps = (Double(upDelta) / dt) * 8.0 / 1_000_000.0

            rates.append(TrafficRate(
                date: curr.timestamp,
                downloadMbps: downMbps,
                uploadMbps: upMbps
            ))
        }
        return rates
    }

    private static func nearestRate(to date: Date, in rates: [TrafficRate]) -> TrafficRate? {
        rates.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: - Formatting

    static func formatRate(_ mbps: Double) -> String {
        if mbps < 0.001 {
            return "0 Kbps"
        } else if mbps < 1 {
            return String(format: "%.0f Kbps", mbps * 1000)
        } else if mbps < 10 {
            return String(format: "%.1f Mbps", mbps)
        } else if mbps < 1000 {
            return String(format: "%.0f Mbps", mbps)
        } else {
            return String(format: "%.2f Gbps", mbps / 1000)
        }
    }

    static func formatAxisRate(_ mbps: Double) -> String {
        if mbps < 0.001 {
            return "0"
        } else if mbps < 1 {
            return String(format: "%.0fK", mbps * 1000)
        } else if mbps < 10 {
            return String(format: "%.1fM", mbps)
        } else if mbps < 1000 {
            return String(format: "%.0fM", mbps)
        } else {
            return String(format: "%.1fG", mbps / 1000)
        }
    }
    static func formatAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        let rem = total % 60
        return rem == 0 ? "\(minutes)m" : "\(minutes)m \(rem)s"
    }
}

// MARK: - Models

private struct TrafficRate: Identifiable {
    let date: Date
    let downloadMbps: Double
    let uploadMbps: Double

    var id: Date { date }
}
