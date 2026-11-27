//
//  TerminalEffectView.swift
//  rootshell
//
//  Container view that displays the active terminal background effect
//

import SwiftUI
import QuartzCore

private struct TerminalEffectBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct TerminalEffectRetainsStateKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Keyboard effects keep their presentation while UIKit reparents the input
    /// hierarchy. Reappearance should resume an existing animation, not respawn it.
    var terminalEffectRetainsState: Bool {
        get { self[TerminalEffectRetainsStateKey.self] }
        set { self[TerminalEffectRetainsStateKey.self] = newValue }
    }

    /// Points at the bottom of the effect covered by the docked keyboard and
    /// toolbar. Scenes fit above it but keep drawing beneath, so no gap opens.
    var terminalEffectBottomInset: CGFloat {
        get { self[TerminalEffectBottomInsetKey.self] }
        set { self[TerminalEffectBottomInsetKey.self] = newValue }
    }
}

/// The share of a Metal effect's height its scene fills, eased so the scene
/// follows the keyboard instead of jumping.
nonisolated struct EffectSceneFraction {
    static let duration: CFTimeInterval = 0.25
    private var from = 1.0
    private(set) var target = 1.0
    private var start = -CFTimeInterval.infinity
    private var hasTarget = false

    static func visible(height: CGFloat, bottomInset: CGFloat) -> Double {
        guard height > 0, bottomInset.isFinite else { return 1 }
        return min(max(Double((height - bottomInset) / height), 0.2), 1)
    }

    mutating func retarget(_ fraction: Double, at now: CFTimeInterval, animated: Bool) {
        if hasTarget && abs(fraction - target) <= 0.001 {
            // A paused or motion-reduced scene must not keep a part-way frame.
            if !animated { from = target }
            return
        }
        from = hasTarget && animated ? value(at: now) : fraction
        target = fraction
        start = now
        hasTarget = true
    }

    func value(at now: CFTimeInterval) -> Double {
        let t = min(max((now - start) / Self.duration, 0), 1)
        return from + (target - from) * (1 - pow(1 - t, 3))
    }

    func isAnimating(at now: CFTimeInterval) -> Bool { from != target && now - start < Self.duration }
}

private struct BackgroundEffectSelectionPicker: View {
    let title: LocalizedStringKey
    @Binding var effectID: String
    private var effectManager = EffectManager.shared

    init(title: LocalizedStringKey, effectID: Binding<String>) {
        self.title = title
        self._effectID = effectID
    }

    var body: some View {
        Group {
            Picker(title, selection: $effectID) {
                Text("Same as Terminal").tag(BackgroundEffectSelection.followTerminalID)
                Text("None").tag("")
                ForEach(effectManager.availableEffects) { effect in
                    Text(effect.displayName).tag(effect.id)
                }
                if !effectID.isEmpty, effectID != BackgroundEffectSelection.followTerminalID,
                   effectManager.effect(withId: effectID) == nil {
                    Text("Unavailable Effect").tag(effectID)
                }
            }
            if let effect = effectManager.selectedEffect(id: effectID) {
                NavigationLink {
                    EffectDetailView(effect: effect)
                } label: {
                    Text("Configure Effect")
                }
            }
        }
        .onChange(of: effectID) { _, _ in
            if let solar = effectManager.selectedEffect(id: effectID)?.asEffect(SolarGraphEffect.self) {
                Task { await solar.onActivated() }
            }
            #if !CHINA_BUILD
            effectManager.selectedEffect(id: effectID)?.asEffect(LiveWeatherEffect.self)?.onActivated()
            #endif
        }
    }
}

#if !os(visionOS) && !targetEnvironment(macCatalyst)
struct KeyboardBackgroundEffectPicker: View {
    @Setting(Settings.Shaders.keyboardBackgroundEffect) private var placement
    @Setting(Settings.Shaders.keyboardEffectId) private var effectID

    var body: some View {
        Group {
            Picker("Keyboard Effect Area", selection: $placement) {
                ForEach(TerminalTouchKeyboardModel.BackgroundEffectPlacement.allCases, id: \.self) { placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            .settingContextMenu(Settings.Shaders.keyboardBackgroundEffect)
            BackgroundEffectSelectionPicker(title: "Keyboard Effect", effectID: $effectID)
                .settingContextMenu(Settings.Shaders.keyboardEffectId)
            Text("Choose a keyboard effect independently of the terminal. Set the terminal effect to None for effects only in the keyboard. Photos and downloaded videos are also available. Settings are shared when areas use the same effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

/// Container view that renders the currently active terminal effect
struct TerminalEffectView: View {
    var effectManager = EffectManager.shared

    var body: some View {
        Group {
            if let effect = effectManager.activeEffect {
                effect.createEffectView()
                    .allowsHitTesting(false)
                    // Force view recreation when effect changes
                    .id(effect.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ZStack {
        // Simulated terminal background
        Color.black

        // Effect layer
        TerminalEffectView()

        // Simulated terminal text
        VStack(alignment: .leading, spacing: 4) {
            Text("user@host ~ $")
            Text("ls -la")
            Text("total 42")
        }
        .font(.system(.body, design: .monospaced))
        .foregroundColor(.green)
        .padding()
    }
}
