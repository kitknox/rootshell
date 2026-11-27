//
//  AppearanceDetailSettingsViews.swift
//  rootshell
//
//  Appearance-related detail settings screens.
//

import SwiftUI

/// A `Toggle` row that carries an always-visible secondary description line
/// beneath its title, so per-control guidance lives with the control instead of
/// being bundled into a wall-of-text section footer. Drop-in for `Toggle` in a
/// settings `List`; apply `.themedRow()` at the call site like any other row.
struct DescribedToggle: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if !CHINA_BUILD
struct AIAgentFontSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var fontManager = AIAgentFontManager.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Text Size")
                            .settingRow(Settings.AI.textSize)
                        Spacer()
                        Text("\(Int(fontManager.textSize))pt")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }

                    Slider(
                        value: $fontManager.textSize,
                        in: fontManager.textSizeRange,
                        step: 1
                    )

                    // Preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("The quick brown fox jumps over the lazy dog. 0123456789")
                            .font(.system(size: fontManager.textSize, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.top, 8)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("AI Agent Chat")
            } footer: {
                Text("Controls the text size in AI Agent chat messages, code blocks, and tool outputs.")
            }

            Section {
                Button("Reset to Default (\(Int(fontManager.defaultTextSize))pt)") {
                    fontManager.resetToDefault()
                }
                .foregroundColor(.accentColor)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("AI Agent Text Size")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

// MARK: - Appearance Mode Settings

struct AppearanceModeSettingsView: View {
    @StateObject private var appearanceManager = AppearanceManager.shared

    var body: some View {
        List {
            Section {
                AppearanceModePickerCard()
                    .themedRow()
            } footer: {
                Text("Controls the appearance of the app interface. Terminal themes are configured separately.")
                    .font(.caption)
            }

            Section {
                SettingToggle(Settings.Theme.themedUI, isOn: $appearanceManager.themedUIEnabled, title: "Theme-Aware UI")
                    .themedRow()
            } footer: {
                Text("Apply terminal theme colors to sheets and settings.")
                    .font(.caption)
            }

            Section {
                SettingToggle(Settings.Theme.softScrollEdges, title: "Soft Scroll Edges")
                    .themedRow()
            } footer: {
                Text("Fade and blur lists as they scroll under toolbars and the title bar.")
                    .font(.caption)
            }

            Section {
                SettingToggle(Settings.Theme.imNoFun, title: "I'm no fun")
                    .themedRow()
            } footer: {
                Text("Turn off connection jokes, failure quips, and ASCII failure animations.")
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Appearance Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.theme]) }
    }
}

// MARK: - Transparency Settings

struct TransparencySettingsView: View {
    // @Bindable: TransparencyManager is @Observable; @Bindable is the
    // property wrapper that exposes `$transparencyManager.backgroundOpacity`
    // for Slider/Toggle two-way bindings.
    @Bindable var transparencyManager = TransparencyManager.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                            .settingRow(Settings.Transparency.backgroundOpacity)
                        Spacer()
                        Text(transparencyManager.backgroundOpacity, format: .wholePercent)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    Slider(value: $transparencyManager.backgroundOpacity, in: 0.0...1.0, step: 0.01)
                }
                .padding(.vertical, 4)
                .themedRow()

                if TransparencyManager.isGlassAvailable {
                    Picker(selection: $transparencyManager.blurStyle) {
                        ForEach(TransparencyManager.BlurStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        Text("Blur Style")
                            .settingRow(Settings.Transparency.blurStyle)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                }

                // Glass styles blur on their own; radius/toggle only apply to Standard.
                // Off the Mac, Standard is plain opacity over the backdrop.
                if transparencyManager.usesGlass || !SettingsPlatform.isCatalyst {
                    EmptyView()
                } else if TransparencyManager.useSandboxBlur {
                    // Sandbox mode: simple toggle (NSVisualEffectView doesn't support custom radius)
                    SettingToggle(Settings.Transparency.blurEnabled, isOn: $transparencyManager.blurEnabled, title: "Background Blur")
                        .padding(.vertical, 4)
                        .themedRow()
                } else {
                    // Non-sandbox mode: blur radius slider (private CGS API supports custom radius)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Blur Radius")
                                .settingRow(Settings.Transparency.backgroundBlurRadius)
                            Spacer()
                            Text("\(Int(transparencyManager.backgroundBlurRadius))")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        Slider(value: $transparencyManager.backgroundBlurRadius, in: 0...80, step: 1)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                }

                SettingDescribedToggle(
                    Settings.Transparency.pinnedSidebarTransparency,
                    isOn: $transparencyManager.pinnedSidebarTransparencyEnabled,
                    title: "Transparent Pinned Sidebar",
                    description: "Apply the same opacity to the pinned vertical tab sidebar."
                )
                .themedRow()
            } header: {
                SettingGroupHeader("Window Transparency", group: .transparency)
            } footer: {
                if !SettingsPlatform.isCatalyst {
                    Text("Lets the Theme Gradient backdrop show through the terminal. Applies while the backdrop is on in Background Effect.")
                        .font(.caption)
                } else if transparencyManager.usesGlass {
                    Text("Controls window transparency. Liquid Glass renders the desktop behind the window through a glass material tinted with the theme background.")
                        .font(.caption)
                } else if TransparencyManager.useSandboxBlur {
                    Text("Controls window transparency and blur. Blur uses system vibrancy effect.")
                        .font(.caption)
                } else {
                    Text("Controls the window background transparency and blur effect. Only available on macOS.")
                        .font(.caption)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    transparencyManager.resetToDefaults()
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Transparency")
        .navigationBarTitleDisplayMode(.inline)
    }
}
