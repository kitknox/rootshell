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
                ForEach(AppearanceManager.AppearanceMode.allCases, id: \.self) { mode in
                    Button(action: {
                        appearanceManager.currentAppearanceMode = mode
                    }) {
                        HStack {
                            Text(mode.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if appearanceManager.currentAppearanceMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Controls the appearance of the app interface. Terminal themes are configured separately.")
                    .font(.caption)
            }

            Section {
                Toggle("Theme-Aware UI", isOn: $appearanceManager.themedUIEnabled)
                    .themedRow()
            } footer: {
                Text("Apply terminal theme colors to sheets and settings.")
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Appearance Mode")
        .navigationBarTitleDisplayMode(.inline)
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

                // Show different blur controls based on sandbox mode
                if TransparencyManager.useSandboxBlur {
                    // Sandbox mode: simple toggle (NSVisualEffectView doesn't support custom radius)
                    Toggle("Background Blur", isOn: $transparencyManager.blurEnabled)
                        .padding(.vertical, 4)
                        .themedRow()
                } else {
                    // Non-sandbox mode: blur radius slider (private CGS API supports custom radius)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Blur Radius")
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

                DescribedToggle(
                    title: "Transparent Pinned Sidebar",
                    description: "Apply the same opacity to the pinned vertical tab sidebar.",
                    isOn: $transparencyManager.pinnedSidebarTransparencyEnabled
                )
                .themedRow()
            } header: {
                Text("Window Transparency")
            } footer: {
                if TransparencyManager.useSandboxBlur {
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

// MARK: - Window Settings

struct WindowSettingsView: View {
    @AppStorage("tabBarHidden") private var tabBarHidden: Bool = false
    @AppStorage("showTabShortcutIndicators") private var showTabShortcutIndicators: Bool = false
    @AppStorage(UserPreferences.showTabScopeMenuKey) private var showTabScopeMenu: Bool = true
    @AppStorage("tabBarAnimationsDisabled") private var tabBarAnimationsDisabled: Bool = false
    @AppStorage(TopTabStyle.storageKey) private var topTabStyleRawValue: String = TopTabStyle.pills.rawValue
    @AppStorage(TabExposeSettings.showsCaptionsKey) private var tabExposeShowsCaptions: Bool = true
    @AppStorage("tabSidebarTranslucent") private var tabSidebarTranslucent: Bool = true
    @AppStorage("tabSidebarAutoHideOnSelect") private var tabSidebarAutoHideOnSelect: Bool = false
    @AppStorage("tabSidebarRowLines") private var tabSidebarRowLines: Int = 1
    @AppStorage(SplitFocusBorderStyle.storageKey) private var splitFocusBorderStyle: String = SplitFocusBorderStyle.standard.rawValue
    @AppStorage(SplitFocusBorderColor.storageKey) private var splitFocusBorderColor: String = SplitFocusBorderColor.accent.rawValue
    @AppStorage(SplitFocusBorderColor.customHexKey) private var splitFocusBorderCustomHex: String = "007AFF"
    @AppStorage("copyOnSelect") private var copyOnSelect: Bool = true
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @AppStorage(UserPreferences.useNativeSelectionLoupeKey) private var useNativeSelectionLoupe: Bool = false
    #endif
    @Bindable private var selectionManager = SelectionManager.shared
    @Bindable private var paddingManager = PaddingManager.shared
    // HDR "brightness boost" — the same global gain the floating brightness HUD
    // drives, surfaced here so it can be set without summoning the overlay.
    @Bindable private var brightnessManager = BrightnessManager.shared
    #if targetEnvironment(macCatalyst)
    @AppStorage("tabsInTitlebarEnabled") private var tabsInTitlebarEnabled: Bool = true
    @AppStorage("hideWindowTitleBar") private var hideWindowTitleBar: Bool = false
    #endif

    /// The display's maximum potential EDR headroom (peak EDR white ÷ SDR white).
    /// 1.0 means no EDR (SDR panel, visionOS, or already at full brightness). We
    /// read `potentialEDRHeadroom` (stable) not `currentEDRHeadroom` (which ramps
    /// and collapses at max brightness) so the slider's range doesn't jump.
    private var potentialEDRHeadroom: CGFloat {
        #if os(visionOS)
        return 1.0
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map { $0.screen.potentialEDRHeadroom }
            .max() ?? 1.0
        #endif
    }

    /// Whether the display currently has usable EDR headroom to boost into.
    private var hasEDRHeadroom: Bool { potentialEDRHeadroom > 1.02 }

    /// Slider upper bound: clamped to the display's headroom and the manager's
    /// hard cap, but never below a sliver so the track stays draggable.
    private var brightnessSliderMax: Double {
        max(min(Double(potentialEDRHeadroom), BrightnessManager.maxGainCap), 1.05)
    }

    /// The EDR brightness-boost APIs only exist on 26+; below that the slider
    /// would do nothing, so the control is hidden (not just disabled).
    private var brightnessBoostAvailable: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    /// Whether the "Display" Section has anything to show. On Catalyst the
    /// brightness controls are its only rows, so the whole Section is hidden
    /// pre-26; on iOS the Full Screen / Always On Display toggles keep it alive.
    private var showDisplaySection: Bool {
        #if targetEnvironment(macCatalyst)
        return brightnessBoostAvailable
        #else
        return true
        #endif
    }
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @AppStorage("fullScreenModeEnabled") private var fullScreenModeEnabled: Bool = false
    @Bindable private var alwaysOnDisplayManager = AlwaysOnDisplayManager.shared

    /// Whether this device has a home indicator (a non-zero bottom safe area).
    /// False on home-button devices, where "Extend Under Home Indicator" would be
    /// meaningless — so we hide the toggle there.
    private var deviceHasHomeIndicator: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.safeAreaInsets.bottom > 0 }
    }
    #endif

    var body: some View {
        List {
            Section {
                Toggle("Show Top Tab Bar", isOn: Binding(
                    get: { !tabBarHidden },
                    set: { tabBarHidden = !$0 }
                ))
                .themedRow()

                Picker("Tab Style", selection: $topTabStyleRawValue) {
                    ForEach(TopTabStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .themedRow()

                DescribedToggle(
                    title: "Show Tab Shortcuts",
                    description: "Display ⌘1–9 indicators on tabs for quick keyboard navigation.",
                    isOn: $showTabShortcutIndicators
                )
                .themedRow()

                DescribedToggle(
                    title: "Show Group Menu",
                    description: "Show the active group or project switcher in the top tab bar while tabs are grouped.",
                    isOn: $showTabScopeMenu
                )
                .themedRow()

                Toggle("Disable Tab Animations", isOn: $tabBarAnimationsDisabled)
                    .themedRow()

                DescribedToggle(
                    title: "Tab Exposé Captions",
                    description: "Show tab titles and badges under each live preview in Tab Exposé.",
                    isOn: $tabExposeShowsCaptions
                )
                .themedRow()

                #if !os(visionOS)
                Toggle(
                    UIDevice.current.userInterfaceIdiom == .phone
                        ? String(localized: "Translucent Tab Switcher")
                        : String(localized: "Translucent Tab Sidebar"),
                    isOn: $tabSidebarTranslucent
                )
                .themedRow()

                // Pinned/non-pinned only exists on iPad/Catalyst; on phone the
                // switcher always dismisses on select, so the toggle is a no-op.
                if UIDevice.current.userInterfaceIdiom != .phone {
                    DescribedToggle(
                        title: "Auto-Hide Sidebar After Selection",
                        description: "Closes the floating (non-pinned) sidebar after you pick a tab. The pinned sidebar always stays open.",
                        isOn: $tabSidebarAutoHideOnSelect
                    )
                    .themedRow()
                }
                #endif

                // Uniform for every row so the list stays symmetric; long
                // titles wrap instead of truncating.
                Stepper(value: $tabSidebarRowLines, in: 1...3) {
                    HStack {
                        Text(UIDevice.current.userInterfaceIdiom == .phone
                            ? String(localized: "Tab Switcher Title Lines")
                            : String(localized: "Sidebar Title Lines"))
                        Spacer()
                        Text("\(tabSidebarRowLines)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                Text("Tab Bar")
            }

            #if targetEnvironment(macCatalyst)
            Section {
                Toggle("Tabs in Title Bar", isOn: $tabsInTitlebarEnabled)
                    .themedRow()

                DescribedToggle(
                    title: "Hide Title Bar",
                    description: "Removes the macOS title bar and window controls so content reaches the top edge. Close the window with ⌘W and enter full screen with the View menu.",
                    isOn: $hideWindowTitleBar
                )
                .themedRow()
            } header: {
                Text("Title Bar")
            } footer: {
                Text("Moves the tab bar into the macOS title bar area to remove the extra top row.")
                    .font(.caption)
            }
            #endif

            Section {
                Stepper(value: Binding(
                    get: { paddingManager.effectivePaddingX },
                    set: { paddingManager.setPaddingX($0) }
                ), in: 0...32) {
                    HStack {
                        Text("Horizontal")
                        Spacer()
                        Text("\(paddingManager.effectivePaddingX) pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                Stepper(value: Binding(
                    get: { paddingManager.effectivePaddingY },
                    set: { paddingManager.setPaddingY($0) }
                ), in: 0...32) {
                    HStack {
                        Text("Vertical")
                        Spacer()
                        Text("\(paddingManager.effectivePaddingY) pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                if paddingManager.isCustom {
                    Button("Reset to Defaults (\(paddingManager.defaultPaddingX) pt / \(paddingManager.defaultPaddingY) pt)") {
                        paddingManager.resetToDefaults()
                    }
                    .foregroundColor(.accentColor)
                    .themedRow()
                }
            } header: {
                Text("Window Padding")
            } footer: {
                Text(paddingManager.isCustom
                     ? "Custom padding active. Reset to restore the platform default."
                     : "Using platform default. Adjust the inset between terminal text and the window edges.")
                    .font(.caption)
            }

            Section {
                Picker("Split Focus Border", selection: $splitFocusBorderStyle) {
                    ForEach(SplitFocusBorderStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .themedRow()

                Picker("Border Color", selection: $splitFocusBorderColor) {
                    ForEach(SplitFocusBorderColor.allCases, id: \.rawValue) { color in
                        Text(color.displayName).tag(color.rawValue)
                    }
                }
                .themedRow()

                if splitFocusBorderColor == SplitFocusBorderColor.custom.rawValue {
                    ColorPicker("Custom Color", selection: Binding(
                        get: {
                            Color(hex: splitFocusBorderCustomHex) ?? .blue
                        },
                        set: { newColor in
                            splitFocusBorderCustomHex = UIColor(newColor).hexString
                        }
                    ))
                    .themedRow()
                }
            } header: {
                Text("Split Panes")
            } footer: {
                Text("Controls the border shown around the focused pane when using split terminals.")
                    .font(.caption)
            }

            // EDR is meaningless on visionOS, so the Display section (and its HDR
            // brightness boost) is excluded there. The Full Screen / Always On
            // Display / home-indicator toggles are iOS-only concepts, so they stay
            // gated to non-Catalyst; the brightness boost shows on both iOS and
            // Catalyst (HDR-capable built-in and external displays) — but only on
            // OS 26+, where the EDR APIs exist. On Catalyst the boost is the
            // section's only content, so `showDisplaySection` drops the whole
            // section pre-26.
            #if !os(visionOS)
            if showDisplaySection {
            Section {
                #if !targetEnvironment(macCatalyst)
                DescribedToggle(
                    title: "Full Screen",
                    description: "Hides the status bar and iPadOS window resize handle for a distraction-free terminal.",
                    isOn: $fullScreenModeEnabled
                )
                .themedRow()

                Toggle("Always On Display", isOn: $alwaysOnDisplayManager.isEnabled)
                    .themedRow()

                if deviceHasHomeIndicator {
                    DescribedToggle(
                        title: "Extend Under Home Indicator",
                        description: "Run the terminal and its keyboard toolbar edge-to-edge under the home indicator. Off keeps a small gap so the home-swipe gesture doesn't interfere with taps and text selection near the bottom.",
                        isOn: $paddingManager.extendUnderHomeIndicator
                    )
                    .themedRow()
                }
                #endif

                if brightnessBoostAvailable {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Brightness Boost")
                            Spacer()
                            Text(String(format: "%.2f×", brightnessManager.gain))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
                            Slider(value: $brightnessManager.gain, in: 1.0...brightnessSliderMax, step: 0.05)
                                .disabled(!hasEDRHeadroom)
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(.secondary)
                        }
                        Text(hasEDRHeadroom
                            ? String(localized: "Pushes terminal content above standard brightness using your display's HDR (EDR) headroom. Also available as a floating slider via a keybind or the keyboard toolbar.")
                            : String(localized: "No HDR headroom at the current display brightness (SDR display, or already at maximum brightness). Lower the display brightness to free up headroom."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .themedRow()

                    if brightnessManager.isBoosted {
                        Button("Reset Brightness") {
                            brightnessManager.reset()
                        }
                        .themedRow()
                    }
                }
            } header: {
                Text("Display")
            }
            }
            #endif

            Section {
                Picker("Selection Style", selection: $selectionManager.selectionMode) {
                    ForEach(SelectionAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .themedRow()

                if selectionManager.selectionMode == .custom {
                    ColorPicker("Foreground", selection: Binding(
                        get: {
                            Color(hex: selectionManager.customForegroundHex) ?? .white
                        },
                        set: { newColor in
                            selectionManager.customForegroundHex = UIColor(newColor).hexString
                        }
                    ))
                    .themedRow()

                    ColorPicker("Background", selection: Binding(
                        get: {
                            Color(hex: selectionManager.customBackgroundHex) ?? .blue
                        },
                        set: { newColor in
                            selectionManager.customBackgroundHex = UIColor(newColor).hexString
                        }
                    ))
                    .themedRow()
                }
                Toggle("Copy on Select", isOn: $copyOnSelect)
                    .padding(.vertical, 4)
                    .themedRow()

                #if os(iOS) && !targetEnvironment(macCatalyst)
                Toggle("Use Native Selection Loupe", isOn: $useNativeSelectionLoupe)
                    .padding(.vertical, 4)
                    .themedRow()
                #endif
            } header: {
                Text("Text Selection")
            } footer: {
                Text(copyOnSelect
                    ? String(localized: "Selected text is automatically copied to the clipboard.")
                    : selectionManager.selectionMode.description)
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Window")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: copyOnSelect) { _, _ in
            // Rewrite config file with updated copy-on-select and reload
            if let app = Ghostty.App.shared {
                let currentFontSize = Int(FontManager.shared.currentFontSize)
                if app.config.setFontSize(currentFontSize) {
                    app.pushGlobalConfigToApp()
                }
            }
        }
        .onChange(of: paddingManager.paddingXOverride) { _, _ in
            reloadGhosttyConfig()
        }
        .onChange(of: paddingManager.paddingYOverride) { _, _ in
            reloadGhosttyConfig()
        }
    }

    private func reloadGhosttyConfig() {
        // Rewriting the config via setFontSize regenerates the full file,
        // including the new window-padding-x/y values.
        guard let app = Ghostty.App.shared else { return }
        let currentFontSize = Int(FontManager.shared.currentFontSize)
        if app.config.setFontSize(currentFontSize) {
            app.pushGlobalConfigToApp()
        }
    }
}
