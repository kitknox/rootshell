//
//  ExternalDisplaySettingsView.swift
//  rootshell
//
//  Preferences for external display (USB-C / AirPlay) terminal support.
//

#if !targetEnvironment(macCatalyst)
import SwiftUI

struct ExternalDisplaySettingsView: View {
    @AppStorage(ExternalDisplaySettings.enabledKey)
    private var isEnabled = true

    @AppStorage(ExternalDisplaySettings.fontSizeKey)
    private var fontSize = 0.0

    @AppStorage(ExternalDisplaySettings.zoomKey)
    private var zoom = 0.0

    private func zoomLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))\u{00D7}" : String(format: "%.2f\u{00D7}", value)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $isEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "tv")
                        Text("Terminals on External Display")
                    }
                }
                .themedRow()
                .onChange(of: isEnabled) { _, newValue in
                    if !newValue {
                        ExternalDisplayManager.shared.disableWhileActive()
                    }
                }
            } footer: {
                Text("When a display is connected over USB-C or AirPlay, show a separate terminal workspace on it instead of mirroring this device. Move tabs to it from the tab context menu, and switch typing focus with \u{2318}O or the keyboard toolbar button.")
            }

            Section {
                DescribedToggle(
                    title: "Automatic Zoom",
                    description: "Pick a comfortable size from the display's resolution.",
                    isOn: Binding(
                        get: { zoom == 0 },
                        set: { zoom = $0 ? 0 : ExternalDisplaySettings.allowedZoomSteps[2] }
                    )
                )
                .themedRow()

                if zoom > 0 {
                    Picker(selection: $zoom) {
                        ForEach(ExternalDisplaySettings.allowedZoomSteps, id: \.self) { step in
                            Text(zoomLabel(step)).tag(step)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "plus.magnifyingglass")
                            Text("Zoom Level")
                        }
                    }
                    .themedRow()

                    Button {
                        zoom = 0
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "arrow.counterclockwise")
                            Text("Reset to Automatic")
                        }
                    }
                    .themedRow()
                }
            } header: {
                Text("Display Zoom")
            } footer: {
                Text("Scales the whole external workspace, including tabs, sidebars, and terminals, so it stays readable on large screens. Terminal text stays pixel-sharp at every zoom level.")
            }

            Section {
                DescribedToggle(
                    title: "Custom Font Size",
                    description: "Override terminal text size while shown on the external display.",
                    isOn: Binding(
                        get: { fontSize > 0 },
                        set: { fontSize = $0 ? 16 : 0 }
                    )
                )
                .themedRow()

                if fontSize > 0 {
                    Stepper(value: $fontSize, in: 8...48, step: 1) {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "textformat.size")
                            Text("Size")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundColor(.secondary)
                        }
                    }
                    .themedRow()
                }
            } header: {
                Text("Terminal Font Size")
            } footer: {
                Text("Independent of Display Zoom. Applies to tmux windows too.")
            }
        }
        .themedList()
        .onChange(of: fontSize) { oldValue, newValue in
            ExternalDisplayManager.shared.handleFontPreferenceChange(from: oldValue, to: newValue)
        }
        .onChange(of: zoom) { _, _ in
            ExternalDisplayManager.shared.handleZoomPreferenceChange()
        }
        .navigationTitle(Text("External Display"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
