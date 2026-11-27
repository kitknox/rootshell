// EffectShowcaseView.swift
// rootshell

import SwiftUI

/// Presented by the settings page, independently of the lifetime of its rows.
struct EffectShowcaseView: View {
    @ObservedObject var effect: AnyTerminalEffect
    @Environment(\.dismiss) private var dismiss

    /// Live Weather has its own showcase below; other effects show as in the terminal.
    private var isLiveWeather: Bool {
        #if CHINA_BUILD
        return false
        #else
        return effect.asEffect(LiveWeatherEffect.self) != nil
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                (Color(hex: effect.themeColors.background) ?? .black)
                if let aquarium = effect.asEffect(AquariumEffect.self) {
                    AquariumView(effect: aquarium, showcase: true)
                        .blendMode(aquarium.aquariumPalette.isLight ? .multiply : .plusLighter)
                    Text("Showcase preview · terminal intensity is unchanged")
                        .font(.caption)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                } else if let jellyfish = effect.asEffect(JellyfishEffect.self) {
                    JellyfishView(effect: jellyfish, previewMode: true, showcase: true)
                        .blendMode(jellyfish.isLightBackground ? .multiply : .plusLighter)
                } else if !isLiveWeather {
                    EffectPreviewSurface(effect: effect)
                }
                #if !CHINA_BUILD
                if let weather = effect.asEffect(LiveWeatherEffect.self) {
                    LiveWeatherView(effect: weather, showcase: true)
                        .blendMode(weather.isLightBackground ? .multiply : .plusLighter)
                }
                #endif
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(effect.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
