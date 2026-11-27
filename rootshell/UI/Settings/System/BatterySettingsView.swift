//
//  BatterySettingsView.swift
//  rootshell
//
//  Settings view for the refresh-rate cap, the power-source-adaptive cap,
//  and the automatic battery saver, led by the illustrated track preview.
//

import SwiftUI
import UIKit

struct BatterySettingsView: View {
    @Bindable private var powerManager = PowerManager.shared

    var body: some View {
        List {
            Section {
                RefreshRatePreviewCard(powerManager: powerManager)
                    .themedRow()
            } footer: {
                Text("Caps how fast the terminal redraws. Lower rates use less battery during scrolling and heavy output.")
            }

            Section {
                SettingDescribedToggle(
                    Settings.Power.autoSaver,
                    isOn: $powerManager.autoSaverEnabled,
                    title: "Automatic Battery Saver",
                    description: "Drops to 30 Hz redraws and slower animations when Low Power Mode is on or the device is warm."
                )
                .themedRow()
            }

            Section("Status") {
                statusRow("gauge.with.dots.needle.67percent", "Current Mode", powerManager.tier.displayName)
                statusRow(
                    powerManager.onExternalPower ? "bolt.fill" : "battery.75percent",
                    "Power Source",
                    powerManager.onExternalPower
                        ? String(localized: "Wall Power", comment: "Device is running on external power")
                        : String(localized: "Battery", comment: "Device is running on battery power")
                )
                if powerManager.lowPowerModeActive {
                    statusRow("leaf.fill", "Low Power Mode", String(localized: "On"))
                }
                if powerManager.thermalThrottleActive {
                    statusRow("thermometer.high", "Thermal State", String(localized: "Elevated"))
                }
            }
        }
        .themedList()
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusRow(_ icon: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon)
            LabeledContent(title, value: value)
        }
        .themedRow()
    }
}

// MARK: - Preview card

/// The track scene over the refresh-rate picker, the On Battery cap, and a caption.
private struct RefreshRatePreviewCard: View {
    @Bindable var powerManager: PowerManager
    @State private var topRate = 60
    @State private var odometer = BatteryOdometer()

    private typealias Rate = PowerManager.RefreshRateSetting
    private typealias BatteryRate = PowerManager.BatteryRefreshRate

    private var isAdaptive: Bool { powerManager.maxRefreshRate == .adaptive }

    /// The car shows what is running now, so Adaptive follows the power source.
    private var car: BatteryPreviewCar {
        switch powerManager.effectiveRefreshRate {
        case .sixty: .sedan
        case .thirty: .eco
        case .auto, .adaptive: .sport
        }
    }

    /// The battery saver is holding a faster choice down to 30 Hz.
    private var limited: Bool {
        powerManager.tier == .saver && powerManager.effectiveRefreshRate != .thirty
    }

    private var sceneValues: BatterySceneValues {
        BatterySceneValues(car: car, adaptive: isAdaptive, plugged: powerManager.onExternalPower,
                           limited: limited, topRate: topRate)
    }

    var body: some View {
        VStack(spacing: 12) {
            PreviewSceneCard(values: sceneValues.vector, animation: .linear(duration: 2.4), draw: BatteryPitScene.drawer(odometer: odometer))
                .background { DisplayRateProbe(rate: $topRate) }

            // Icons beside titles when all four fit, stacked above them otherwise.
            ViewThatFits(in: .horizontal) {
                rateControl(.horizontal)
                rateControl(.vertical)
            }
            .disabled(SettingFileLock.isReadOnly(Settings.Power.maxRefreshRate.name))
            .settingContextMenu(Settings.Power.maxRefreshRate)

            onBatteryControl
                .disabled(!isAdaptive || SettingFileLock.isReadOnly(Settings.Power.batteryRefreshRate.name))
                .opacity(isAdaptive ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.25), value: isAdaptive)
                .settingContextMenu(Settings.Power.batteryRefreshRate)

            // Every caption laid out at once so the row keeps its height.
            ZStack {
                ForEach(Caption.allCases, id: \.self) { caption in
                    Text(caption.text)
                        .opacity(caption == currentCaption ? 1 : 0)
                        .accessibilityHidden(caption != currentCaption)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentCaption)
        }
        .padding(.vertical, 6)
    }

    private func rateControl(_ axis: Axis) -> some View {
        PreviewSegmentedControl<Rate>(
            title: "Maximum Refresh Rate",
            options: [
                .init(value: .auto, symbol: "flag.checkered", title: Rate.auto.displayName),
                .init(value: .sixty, symbol: "car.side.fill", title: Rate.sixty.displayName),
                .init(value: .thirty, symbol: "leaf.fill", title: Rate.thirty.displayName),
                .init(value: .adaptive, symbol: "bolt.car.fill", title: Rate.adaptive.displayName),
            ],
            selection: powerManager.maxRefreshRate,
            onSelect: { powerManager.maxRefreshRate = $0 },
            labelAxis: axis
        )
    }

    private var onBatteryControl: some View {
        // Spelled out rather than a Label, which the settings list can render icon-only.
        let label = HStack(spacing: 6) {
            Image(systemName: "battery.50percent")
            Text("On Battery")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        let control = PreviewSegmentedControl<BatteryRate>(
            title: "On Battery",
            options: [
                .init(value: .sixty, symbol: "car.side.fill", title: BatteryRate.sixty.displayName),
                .init(value: .thirty, symbol: "leaf.fill", title: BatteryRate.thirty.displayName),
            ],
            selection: powerManager.batteryRefreshRate,
            onSelect: { powerManager.batteryRefreshRate = $0 }
        )
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label.fixedSize()
                control
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                control
            }
        }
    }

    // MARK: Captions

    private enum Caption: CaseIterable {
        case auto, sixty, thirty, adaptive, limited

        var text: String {
            switch self {
            case .auto:
                String(localized: "Full speed: the terminal redraws at the display's top rate, up to 120 Hz on ProMotion.",
                       comment: "Battery preview caption: Auto refresh rate")
            case .sixty:
                String(localized: "A steady cruise: redraws cap at 60 Hz, easing battery use while scrolling.",
                       comment: "Battery preview caption: 60 Hz refresh rate")
            case .thirty:
                String(localized: "The economy run: redraws cap at 30 Hz for the longest battery life.",
                       comment: "Battery preview caption: 30 Hz refresh rate")
            case .adaptive:
                String(localized: "Full speed on wall power, then the On Battery cap once you unplug.",
                       comment: "Battery preview caption: Adaptive refresh rate")
            case .limited:
                String(localized: "The battery saver is holding redraws to 30 Hz while Low Power Mode is on or the device is warm.",
                       comment: "Battery preview caption: automatic battery saver is active")
            }
        }
    }

    private var currentCaption: Caption {
        if limited { return .limited }
        switch powerManager.maxRefreshRate {
        case .auto: return .auto
        case .sixty: return .sixty
        case .thirty: return .thirty
        case .adaptive: return .adaptive
        }
    }
}

// MARK: - Display rate probe

/// Reports the hosting screen's top frame rate, for the preview's readout.
private struct DisplayRateProbe: UIViewRepresentable {
    @Binding var rate: Int

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        let binding = $rate
        view.onChange = { rate in
            if binding.wrappedValue != rate { binding.wrappedValue = rate }
        }
    }

    final class ProbeView: UIView {
        var onChange: ((Int) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if os(visionOS)
            let rate = 90
            #else
            guard let screen = window?.windowScene?.screen else { return }
            let rate = max(60, screen.maximumFramesPerSecond)
            #endif
            // Deferred: didMoveToWindow can run inside a SwiftUI update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(rate) }
        }
    }
}
