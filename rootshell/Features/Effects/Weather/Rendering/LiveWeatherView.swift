// LiveWeatherView.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI
import UIKit
import MediaAccessibility
import os

struct LiveWeatherView: View {
    @ObservedObject var effect: LiveWeatherEffect
    var showcase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.terminalEffectBottomInset) private var bottomInset
    @State private var dimFlashingLights = MADimFlashingLightsEnabled()
    @State private var unavailable = false

    private struct HoldKey: Hashable {
        var selection: WeatherLocationSelection
        var provider: WeatherProviderChoice
        var fetching: Bool
    }

    var body: some View {
        let store = WeatherStore.shared
        let configuration = presentationConfiguration
        let selection = configuration.selection
        let input = WeatherSceneInput(
            coordinate: store.coordinate(for: selection), snapshot: store.snapshot(for: selection),
            configuration: configuration, previewCondition: effect.previewCondition, previewTime: effect.previewTime,
            isLight: effect.isLightBackground, reduceMotion: reduceMotion, dimFlashingLights: dimFlashingLights,
            powerScale: PowerManager.shared.effectIntervalScale, bottomInset: bottomInset)
        let fetching = scenePhase != .background && !configuration.demo
        ZStack {
            if unavailable {
                // A static sky if Metal can't start.
                LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.52), Color(red: 0.55, green: 0.66, blue: 0.78)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(configuration.intensity * 0.5)
            } else {
                WeatherMetalView(input: input) { unavailable = true }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: HoldKey(selection: selection, provider: configuration.providerChoice, fetching: fetching)) {
            guard fetching else { return }
            await store.hold(selection, provider: configuration.providerChoice)
        }
        .onChange(of: configuration.showInSidebar, initial: true) { _, show in
            if store.showsInSidebar != show { store.showsInSidebar = show }
        }
        .task {
            let name = Notification.Name(kMADimFlashingLightsChangedNotification as String)
            for await _ in NotificationCenter.default.notifications(named: name) {
                dimFlashingLights = MADimFlashingLightsEnabled()
            }
        }
    }

    private var presentationConfiguration: LiveWeatherConfiguration {
        var configuration = effect.configuration
        if showcase {
            configuration.intensity = 0.9
            configuration.readingProtection = 0
        }
        return configuration
    }
}

private struct WeatherMetalView: UIViewRepresentable {
    let input: WeatherSceneInput
    let onUnavailable: () -> Void

    func makeUIView(context: Context) -> WeatherSurfaceView {
        let gpu: WeatherGPUContext?
        do {
            gpu = try WeatherGPUContext.shared()
        } catch {
            Logger(subsystem: "com.rootshell.weather", category: "Renderer")
                .error("Live Weather unavailable: \(String(describing: error), privacy: .public)")
            // Report after this update transaction.
            let report = onUnavailable
            Task { @MainActor in report() }
            gpu = nil
        }
        let view = WeatherSurfaceView(context: gpu)
        view.update(input)
        return view
    }

    func updateUIView(_ view: WeatherSurfaceView, context: Context) {
        view.update(input)
    }

    static func dismantleUIView(_ view: WeatherSurfaceView, coordinator: ()) {
        view.tearDown()
    }
}
#endif
