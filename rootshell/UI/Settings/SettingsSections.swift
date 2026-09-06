//
//  SettingsSections.swift
//  rootshell
//
//  Top-level Settings section views.
//

import SwiftUI

struct SettingsAppearanceSection: View {
    var themeManager = ThemeManager.shared
    @ObservedObject var fontManager = FontManager.shared
    @ObservedObject var appearanceManager = AppearanceManager.shared
    var transparencyManager = TransparencyManager.shared
    var effectManager = EffectManager.shared
    @ObservedObject var iconManager = AppIconManager.shared
    @Setting(Settings.Tabs.barHidden) private var tabBarHidden

    @ViewBuilder
    private var windowSettingsSecondaryLabel: some View {
        Text(tabBarHidden ? String(localized: "Tab Bar Hidden", comment: "Window settings: tab bar status") : String(localized: "Tab Bar Visible", comment: "Window settings: tab bar status"))
            .foregroundColor(.secondary)
            .font(.subheadline)
    }

    var body: some View {
        List {
            Section {
                if AppIconManager.isSupported {
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "app.badge")
                            Text(String(localized: "App Icon", comment: "Settings row: app icon picker"))
                            SettingPinTag(Settings.Theme.appIconVariant.erased)
                            Spacer()
                            Text(iconManager.selectedVariant.displayName)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            Image(iconManager.selectedVariant.previewAssetName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .themedRow()
                    .settingContextMenu(Settings.Theme.appIconVariant)
                }

                NavigationLink {
                    ThemeSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "paintpalette")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Theme")
                                SettingPinTag(group: .theme)
                            }
                            Text(themeManager.currentTheme)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .layoutPriority(1)
                        Spacer()
                        if let themeInfo = themeManager.currentThemeInfo {
                            TerminalSnippetView(colors: themeInfo.colors, compact: true)
                                .frame(width: 100, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.theme)

                NavigationLink {
                    PaletteSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "swatchpalette")
                        Text("Colors")
                        SettingPinTag(group: .palette)
                        Spacer()
                        Text(PaletteManager.shared.paletteGenerateEnabled
                            ? String(localized: "Harmonious", comment: "Palette status: generated palette active")
                            : String(localized: "Standard", comment: "Palette status: default palette"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.palette)

                NavigationLink {
                    FontSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "textformat")
                        Text("Font")
                        SettingPinTag(group: .font)
                        Spacer()
                        Text("\(fontManager.currentFontFamilyDisplayName) - \(Int(fontManager.currentFontSize))pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.font)

                NavigationLink {
                    CursorSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "character.cursor.ibeam")
                        Text("Cursor")
                        SettingPinTag(group: .cursor)
                        Spacer()
                        Text(CursorManager.shared.cursorStyle.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.cursor)

                NavigationLink {
                    AppearanceModeSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "circle.lefthalf.filled")
                        Text("Appearance Mode")
                        SettingPinTag(group: .theme)
                        Spacer()
                        Text(appearanceManager.currentAppearanceMode.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.theme)

                NavigationLink {
                    EffectSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "sparkles")
                        Text("Background Effect")
                        SettingPinTag(group: .shaders)
                        Spacer()
                        Text(effectManager.activeEffect?.displayName ?? String(localized: "None", comment: "Background effect: no effect active"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.shaders)

                NavigationLink {
                    ShaderSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cpu")
                        Text("Custom Shaders")
                        SettingPinTag(group: .shaders)
                        Spacer()
                        if ShaderManager.shared.enabledShaderCount == 0 {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(ShaderManager.shared.enabledShaderCount) active")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.shaders)

                #if targetEnvironment(macCatalyst)
                NavigationLink {
                    TransparencySettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "slider.horizontal.below.rectangle")
                        Text("Transparency")
                        SettingPinTag(group: .transparency)
                        Spacer()
                        Text(transparencyManager.backgroundOpacity, format: .wholePercent)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.transparency)
                #endif

                NavigationLink {
                    WindowSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "macwindow")
                        Text("Window")
                        SettingPinTag(group: .window)
                        Spacer()
                        windowSettingsSecondaryLabel
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.window)

                NavigationLink {
                    BatterySettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "battery.25percent")
                        Text("Battery")
                        SettingPinTag(group: .power)
                        Spacer()
                        Text(PowerManager.shared.tier.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.power)

                #if STANDALONE && targetEnvironment(macCatalyst)
                NavigationLink {
                    VisorSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.topthird.inset.filled")
                        Text("Visor")
                        SettingPinTag(group: .visor)
                        Spacer()
                        Text(VisorSettings.shared.enabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.visor)
                #endif
            }
        }
        .themedList()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Terminal section detail (Toolbar Keys, Keyboard Shortcuts, ModTap, Option Key, Session Restore, etc.)
struct SettingsTerminalSection: View {
    @Setting(Settings.Keyboard.writingAssistance) private var writingAssistance
    @Setting(Settings.Prompt.useStarship) private var useStarshipPrompt
    @Setting(Settings.Prompt.starshipTheme) private var starshipTheme
    @Setting(Settings.Prompt.customUsername) private var customUsername
    @Setting(Settings.Locale.mode) private var localeMode
    @Setting(Settings.Privacy.geoProviderType) private var geoProviderType
    @Setting(Settings.Locale.custom) private var customLocale
    @Setting(Settings.Terminal.terminalTypeLocal) private var localTerm
    @Setting(Settings.Terminal.terminalTypeRemote) private var remoteTerm
    @Setting(Settings.Gestures.lineScrollback) private var lineScrollbackEnabled
    @Setting(Settings.CodingAgents.detectionEnabled) private var agentDetectionEnabled
    @Setting(Settings.Notifications.taskDetection) private var taskDetectionEnabled
    #if targetEnvironment(macCatalyst)
    @Setting(Settings.Window.tabsInTitlebar) private var tabsInTitlebarEnabled
    #if STANDALONE
    // Read only to redraw the summary; the value itself comes from LocalShellSettings.
    @Setting(Settings.Terminal.localShellCommand) private var localShellCommand
    #endif
    #else
    @Setting(Settings.Gestures.scrollMode) private var scrollModeEnabled
    @Setting(Settings.Gestures.twoFingerLongPressDuration) private var twoFingerLongPressDuration
    #endif

    /// Unset falls back to `GeoProviderType.defaultProvider`, which can differ from the registry default.
    private var geoProviderRawValue: String? {
        _geoProviderType.isUserSet ? geoProviderType.rawValue : nil
    }

#if !targetEnvironment(macCatalyst)
    @ObservedObject var bookmarkedLocationsManager = BookmarkedLocationsManager.shared
#endif

    private var localeSummary: String {
        switch localeMode {
        case .auto:
            return LocaleHelper.posixLocale
        case .none:
            return String(localized: "Don't Send", comment: "Locale setting: disabled")
        case .custom:
            return customLocale.isEmpty
                ? String(localized: "Don't Send", comment: "Locale setting: disabled")
                : customLocale
        }
    }

    /// One value when both scopes agree, otherwise "<local> / <remote>".
    ///
    /// Resolves the stored strings so an invalid custom entry shows what will
    /// actually be sent rather than what was typed.
    private var terminalTypeSummary: String {
        let local = TerminalTypeSettings.resolved(localTerm, fallingBackTo: TerminalTypeSettings.localFallback)
        let remote = TerminalTypeSettings.resolved(remoteTerm)
        return local == remote ? local : "\(local) / \(remote)"
    }

    private var terminalTypeRow: some View {
        NavigationLink {
            TerminalTypeSettingsView()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "character.cursor.ibeam")
                Text("Terminal Type")
                SettingPinTag(group: .terminal)
                Spacer()
                Text(terminalTypeSummary)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .themedRow()
        .settingGroupContextMenu(.terminal)
    }

    #if STANDALONE && targetEnvironment(macCatalyst)
    /// Resolves the stored string so the summary shows what will really launch
    /// rather than what was typed.
    private var localShellSummary: String {
        LocalShellSettings.resolved(localShellCommand)
            ?? String(localized: "Login Shell",
                      comment: "Local shell setting: use the login shell from the passwd database")
    }

    private var localShellRow: some View {
        NavigationLink {
            LocalShellSettingsView()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "apple.terminal")
                Text("Local Shell")
                SettingPinTag(group: .terminal)
                Spacer()
                Text(localShellSummary)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .themedRow()
        .settingGroupContextMenu(.terminal)
    }
    #endif

    private var lineScrollingToggle: some View {
        SettingToggle(Settings.Gestures.lineScrollback, title: "Use Line Scrolling", icon: "line.3.horizontal") { _ in
            NotificationCenter.default.post(name: .touchModeChanged, object: nil)
        }
        .themedRow()
    }

    private var rubberBandScrollingToggle: some View {
        SettingToggle(Settings.Gestures.rubberBandScrollback, title: "Rubber Band Scrolling", icon: "arrow.up.arrow.down") { _ in
            NotificationCenter.default.post(name: .touchModeChanged, object: nil)
        }
        .themedRow()
    }

    var body: some View {
        List {
            // MARK: - Keyboard
            Section {
                #if !targetEnvironment(macCatalyst)
                Picker(selection: $writingAssistance) {
                    ForEach(TerminalWritingAssistanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Label("Writing Assistance", systemImage: writingAssistance.icon)
                }
                .themedRow()
                .settingContextMenu(Settings.Keyboard.writingAssistance)

                Text("Assists direct typing with Apple's on-screen keyboard. Corrections are applied only while recent input can be safely tracked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()

                NavigationLink {
                    KeyboardToolbarSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "keyboard")
                        Text("Toolbar Keys")
                        SettingPinTag(group: .keyboardToolbar)
                        Spacer()
                        if KeyboardToolbarManager.shared.isCustomized {
                            Text("Customized")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.keyboardToolbar)

                SettingToggle(Settings.Keyboard.doubleSpaceForPeriod, title: "\"\u{200B}.\u{200B}\" Shortcut", icon: "character.cursor.ibeam")
                    .themedRow()

                Text("Double-tap Space on the on-screen keyboard to insert a period followed by a space.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()

                #if !os(visionOS)
                SettingToggle(Settings.KeyboardToolbar.persistent, title: "Persistent Toolbar", icon: "arrow.up.and.down.text.horizontal")
                    .themedRow()

                Text("Keep the toolbar visible when the on-screen keyboard is dismissed. Tap the terminal to bring the keyboard back.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()

                SettingToggle(Settings.KeyboardToolbar.showWithHardwareKeyboard, title: "Show Toolbar with Hardware Keyboard", icon: "keyboard.badge.ellipsis") { _ in
                    NotificationCenter.default.post(name: .keyboardToolbarHardwareSettingChanged, object: nil)
                }
                .themedRow()

                Text("Keep the toolbar docked at the bottom of the screen while a hardware keyboard is connected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
                #endif
                #endif

                NewTabActionSettingsRow()

                NavigationLink {
                    KeyboardShortcutsSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "command")
                        Text("Keyboard Shortcuts")
                        SettingPinTag(group: .keybinds)
                        Spacer()
                        Text("\(KeybindManager.shared.userOverrides.count) custom")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.keybinds)

                NavigationLink {
                    ModTapSettingsView()
                } label: {
                    ModTapSettingsLabel()
                }
                .themedRow()
                .settingContextMenu(Settings.Keybinds.modTapRules)

                OptionKeyAsAltPicker()
                    .themedRow()
            } header: {
                Text("Keyboard")
            }

            // MARK: - Gestures
            Section {
                NavigationLink {
                    SwipeGesturesSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "hand.draw")
                        Text("Swipe Gestures")
                        SettingPinTag(Settings.Gestures.swipeBindings.erased)
                        Spacer()
                        if SwipeGestureManager.shared.isCustomized {
                            Text("Customized")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Gestures.swipeBindings)

                #if !os(visionOS)
                SettingDescribedToggle(
                    Settings.Gestures.tabExposeGesture,
                    title: "Pull Down for Tab Exposé",
                    description: UIDevice.current.userInterfaceIdiom == .phone
                        ? "Swipe down from the tab bar to show live previews of your tabs. Two fingers also work from above the terminal."
                        : "Swipe down from the tab bar (one finger, two fingers, or trackpad scroll) to show live previews of your tabs."
                )
                .themedRow()
                #endif

                #if !targetEnvironment(macCatalyst)
                Picker(selection: Binding(
                    get: { twoFingerLongPressDuration },
                    set: { newValue in
                        twoFingerLongPressDuration = newValue
                        NotificationCenter.default.post(name: .touchModeChanged, object: nil)
                    }
                )) {
                    ForEach(TwoFingerLongPressSetting.options) { option in
                        Text(option.label).tag(option.value)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "hand.point.up.left")
                        Text("Two-Finger Long Press")
                    }
                    .settingRow(Settings.Gestures.twoFingerLongPressDuration)
                }
                .pickerStyle(.menu)
                .themedRow()

                Text("Two-finger long press opens the new connection sheet. Increase the duration to avoid accidental triggers, or turn it off.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
                #endif
            } header: {
                SettingGroupHeader("Gestures", group: .gestures)
            }

            // MARK: - Session
            Section {
                SettingToggle(Settings.SessionRestore.sessionPersistence, title: "Restore Sessions on Launch", icon: "arrow.counterclockwise")
                    .themedRow()

                SettingToggle(Settings.SessionRestore.scrollbackPersistence, title: "Persist Scrollback History", icon: "clock.arrow.circlepath") { newValue in
                    if !newValue {
                        ScrollbackPersistenceManager.shared.removeAllScrollbackFiles()
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Session", group: .sessionRestore)
            }

            // MARK: - Agents & Commands
            // Detection covers every tab type, so this belongs with the
            // terminal settings rather than with the multiplexers.
            Section("Agents & Commands") {
                NavigationLink {
                    CodingAgentSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "sparkles.rectangle.stack")
                        Text("Coding Agents")
                        SettingPinTag(group: .codingAgents)
                        Spacer()
                        Text(agentDetectionEnabled
                            ? String(localized: "On", comment: "Toggle state: enabled")
                            : String(localized: "Off", comment: "Toggle state: disabled"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.codingAgents)

                NavigationLink {
                    TaskDetectionSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "clock.badge.checkmark")
                        Text("Command Detection")
                        SettingPinTag(group: .notifications)
                        Spacer()
                        Text(taskDetectionEnabled
                            ? String(localized: "On", comment: "Toggle state: enabled")
                            : String(localized: "Off", comment: "Toggle state: disabled"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.notifications)
            }

#if !targetEnvironment(macCatalyst)
            // MARK: - Shell
            Section {
                NavigationLink {
                    PromptSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "person.text.rectangle")
                        Text("Prompt & Username")
                        SettingPinTag(group: .prompt)
                        Spacer()
                        if useStarshipPrompt {
                            PromptThemePreview(theme: starshipTheme, compact: true)
                        }
                        Text(customUsername.isEmpty ? NSUserName() : customUsername)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.prompt)

                NavigationLink {
                    BookmarkedLocationsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bookmark")
                        Text("Bookmarked Locations")
                        Spacer()
                        Text(bookmarkedLocationsManager.locations.isEmpty ? String(localized: "None", comment: "Bookmarked locations: none saved") : "\(bookmarkedLocationsManager.locations.count)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    LocaleSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "globe")
                        Text("Locale")
                        SettingPinTag(group: .locale)
                        Spacer()
                        Text(localeSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.locale)

                terminalTypeRow

                NavigationLink {
                    GeoProviderSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "location")
                        Text("IP Geolocation")
                        SettingPinTag(Settings.Privacy.geoProviderType.erased)
                        Spacer()
                        Text(GeoProviderType.availableProvider(for: geoProviderRawValue).displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Privacy.geoProviderType)

                SettingToggle(Settings.Gestures.scrollMode, title: "Scroll Mode", icon: "hand.draw") { _ in
                    NotificationCenter.default.post(name: .touchModeChanged, object: nil)
                }
                .themedRow()

                lineScrollingToggle
                if !lineScrollbackEnabled {
                    rubberBandScrollingToggle
                }

                if scrollModeEnabled {
                    Text("Single finger scrolls. Long press to click or select text. Two-finger tap for menu.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    Text("Single finger selects text. Two fingers to scroll. Long press for menu.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            } header: {
                Text("Shell")
            }
#else
            // MARK: - Shell (Mac Catalyst)
            Section {
                lineScrollingToggle
                if !lineScrollbackEnabled {
                    rubberBandScrollingToggle
                }

                NavigationLink {
                    LocaleSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "globe")
                        Text("Locale")
                        SettingPinTag(group: .locale)
                        Spacer()
                        Text(localeSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.locale)

                terminalTypeRow

                #if STANDALONE
                localShellRow
                #endif

                NavigationLink {
                    GeoProviderSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "location")
                        Text("IP Geolocation")
                        SettingPinTag(Settings.Privacy.geoProviderType.erased)
                        Spacer()
                        Text(GeoProviderType.availableProvider(for: geoProviderRawValue).displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Privacy.geoProviderType)
            } header: {
                Text("Shell")
            }
#endif
        }
        .themedList()
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Connections section detail (SSH Keys, Passwords, Known Hosts, SSH Shortcuts, Cloud, K8s, etc.)
struct SettingsConnectionsSection: View {
    var navigateToVPN: Binding<Bool>? = nil

    @ObservedObject var sshKeyManager = SSHKeyManager.shared
    @ObservedObject var sshHistoryManager = SSHConnectionHistoryManager.shared
    @ObservedObject var hssConfigManager = HSSConfigManager.shared
    @ObservedObject var kubernetesManager = KubernetesClusterManager.shared
    @ObservedObject var cloudAccountManager = CloudAccountManager.shared
    @ObservedObject var wifiAPAccountManager = WiFiAPAccountManager.shared
    @Setting(Settings.Multiplexer.tmuxSessionName) private var tmuxSessionName
    @Setting(Settings.Multiplexer.tmuxCustomCommand) private var tmuxCustomCommand
    @State private var showClearHistoryAlert = false

    private var multiplexerSettingsSummary: String {
        if !tmuxCustomCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Custom"
        }
        let name = tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SSHKeyManagementView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "key")
                        Text("SSH Keys")
                        Spacer()
                        if sshKeyManager.savedKeys.isEmpty {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(sshKeyManager.savedKeys.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    GPGKeyManagementView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "lock.shield")
                        Text("GPG Keys")
                        Spacer()
                        let gpgCount = GPGKeyManager.shared.savedKeys.count
                        if gpgCount == 0 {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(gpgCount)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    SavedPasswordsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "lock")
                        Text("Saved Passwords")
                        Spacer()
                        if SSHPasswordManager.shared.savedPasswords.isEmpty {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(SSHPasswordManager.shared.savedPasswords.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    KnownHostsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "checkmark.shield")
                        Text("Known Hosts")
                        Spacer()
                        Text("\(KnownHostsManager.shared.count)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    HostCertificateAuthoritiesView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "checkmark.seal")
                        Text("Certificate Authorities")
                        Spacer()
                        Text("\(HostCAManager.shared.count)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    HSSConfigSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bolt.horizontal")
                        Text("SSH Shortcuts")
                        Spacer()
                        HSSConfigStatusBadge(status: hssConfigManager.status)
                    }
                }
                .themedRow()

                #if targetEnvironment(macCatalyst) && STANDALONE
                NavigationLink {
                    LocalSSHAgentSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "point.3.connected.trianglepath.dotted")
                        Text(String(localized: "Local SSH Agent", comment: "Settings row: local SSH agent"))
                        Spacer()
                        Text(LocalAgentPolicyStore.shared.config.enabled
                            ? String(localized: "On", comment: "Settings status: enabled")
                            : String(localized: "Off", comment: "Settings status: disabled"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    ExternalSSHAgentsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "key.radiowaves.forward")
                        Text(String(localized: "SSH Agents", comment: "Settings row: external SSH agents"))
                        Spacer()
                        let agentCount = ExternalSSHAgentRegistry.shared.agents.count
                        if agentCount == 0 {
                            Text(String(localized: "None", comment: "Settings status: none configured"))
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(agentCount)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                #endif

                NavigationLink {
                    CloudProvidersSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cloud")
                        Text("Cloud Providers")
                        Spacer()
                        if cloudAccountManager.accounts.isEmpty {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(cloudAccountManager.accounts.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    WiFiAPProvidersSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "wifi.router")
                        Text("WiFi AP Providers")
                        Spacer()
                        if wifiAPAccountManager.accounts.isEmpty {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(wifiAPAccountManager.accounts.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    KubernetesSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "helm")
                        Text("Kubernetes Clusters")
                        Spacer()
                        if kubernetesManager.clusters.isEmpty {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(kubernetesManager.clusters.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    TunnelSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.triangle.swap")
                        Text("Background Tunnels")
                        Spacer()
                        if BackgroundTunnelManager.shared.runningCount > 0 {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("\(BackgroundTunnelManager.shared.runningCount) Active")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            Text("None")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
                NavigationLink {
                    VPNSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "network.badge.shield.half.filled")
                        Text("VPN")
                        Spacer()
                        if VPNManager.shared.status.isActive {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Active")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            Text("Off")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                #endif

                NavigationLink {
                    RoamSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "antenna.radiowaves.left.and.right")
                        Text("Roam")
                        SettingPinTag(group: .roam)
                        Spacer()
                        Text(SettingsStore.shared.get(Settings.Roam.holePunch) ? String(localized: "On", comment: "Toggle state: enabled") : String(localized: "Off", comment: "Toggle state: disabled"))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.roam)

                NavigationLink {
                    ScreenSharingSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "display.2")
                        Text("Screen Sharing")
                        SettingPinTag(group: .screenSharing)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.screenSharing)

                NavigationLink {
                    SSHTransportSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "shield.lefthalf.filled")
                        Text("SSH Transport")
                        SettingPinTag(group: .connections)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.connections)

                NavigationLink {
                    MultiplexerSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.split.2x1")
                        Text("Multiplexers")
                        SettingPinTag(group: .multiplexer)
                        Spacer()
                        Text(multiplexerSettingsSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.multiplexer)

                Button(role: .destructive) {
                    showClearHistoryAlert = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "trash")
                        Text("Clear Connection History")
                        Spacer()
                        if sshHistoryManager.entries.isEmpty {
                            Text("Empty")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("\(sshHistoryManager.entries.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .disabled(sshHistoryManager.entries.isEmpty)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Connection History", isPresented: $showClearHistoryAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                sshHistoryManager.clearHistory()
            }
        } message: {
            Text("This will remove all saved SSH connection history used for auto-completion. This action cannot be undone.")
        }
        #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
        .navigationDestination(isPresented: navigateToVPN ?? .constant(false)) {
            VPNSettingsView()
        }
        #endif
    }
}

/// AI Assistant section detail
struct SettingsAISection: View {
    var body: some View {
        List {
            Section {
                #if !CHINA_BUILD
                NavigationLink {
                    AIAgentSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "gearshape")
                        Text("Configuration")
                        SettingPinTag(group: .ai)
                        Spacer()
                        if AICredentialsManager.shared.hasOpenAIProviderConfigured {
                            Text("Configured")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("Not Set")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.ai)

                NavigationLink {
                    AIAgentFontSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "textformat.size")
                        Text("Text Size")
                        SettingPinTag(Settings.AI.textSize.erased)
                        Spacer()
                        Text("\(Int(AIAgentFontManager.shared.textSize))pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.AI.textSize)

                NavigationLink {
                    VoiceAgentSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "waveform")
                        Text("Voice Agent")
                    }
                }
                .themedRow()
                #endif

                NavigationLink {
                    MCPSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "server.rack")
                        Text("MCP Server")
                        SettingPinTag(Settings.AI.mcpServerConfig.erased)
                        Spacer()
                        if MCPServer.shared.isRunning {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Running")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            Text("Stopped")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.AI.mcpServerConfig)
            } footer: {
                Text("AI providers and tool integration for external AI assistants")
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Privacy & Data section detail
struct SettingsPrivacySection: View {
    @ObservedObject var notificationManager = NotificationManager.shared
    var clipboardManager = ClipboardHistoryManager.shared
    var redactionManager = RedactionManager.shared
    @State private var configOverlay = ConfigOverlayManager.shared

    private var configFileSummary: String {
        switch configOverlay.status {
        case .notFound: String(localized: "Not set up", comment: "Config file row summary")
        case .active(let count): String(localized: "\(count) settings", comment: "Config file row summary")
        case .error: String(localized: "Error", comment: "Config file row summary")
        }
    }
#if !targetEnvironment(macCatalyst)
    @ObservedObject var locationManager = LocationDiaryManager.shared
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    var liveActivityManager = LiveActivityManager.shared
    #endif
#endif

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CloudSyncSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.triangle.2.circlepath.icloud")
                        Text("iCloud Sync")
                        Spacer()
                        if CloudKitSyncManager.shared.isSyncEnabled {
                            Text("On")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("Off")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()

                NavigationLink {
                    BackupRestoreView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "archivebox")
                        Text("Backup & Restore")
                    }
                }
                .themedRow()

                NavigationLink {
                    ConfigFileSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "doc.text")
                        Text("Config File")
                        Spacer()
                        Text(configFileSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    GhosttyConfigImportView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "square.and.arrow.down.on.square")
                        Text("Import from Ghostty Config")
                    }
                }
                .themedRow()

                NavigationLink {
                    OpenSSHImportView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "key.horizontal")
                        Text("Import from OpenSSH")
                    }
                }
                .themedRow()

#if !targetEnvironment(macCatalyst)
                SettingToggle(
                    Settings.Privacy.locationDiaryAutoMode,
                    isOn: Binding(
                        get: { locationManager.mode != .off },
                        set: { newValue in
                            if newValue {
                                locationManager.mode = .autoForRemote
                            } else {
                                locationManager.mode = .off
                            }
                        }
                    ),
                    title: "Location Diary Mode",
                    icon: "mappin.and.ellipse"
                )
                .themedRow()

                if locationManager.mode != .off {
                    Picker(selection: Binding(
                        get: { locationManager.mode },
                        set: { locationManager.mode = $0 }
                    )) {
                        Text("Session Only").tag(LocationDiaryMode.sessionOnly)
                        Text("Auto During Active Sessions").tag(LocationDiaryMode.autoForRemote)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "list.bullet")
                            Text("Mode")
                        }
                    }
                    .themedRow()

                    if locationManager.mode == .sessionOnly {
                        Text("Stays on until you turn it off or close the app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    } else if locationManager.isTrackingActive {
                        Text("Currently tracking • Will pause when all active sessions end")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    } else {
                        Text("Waiting for SSH, Kubernetes, Cloud Console, or long-running local tasks (Roam doesn't need this)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }

                    NavigationLink {
                        LocationDiaryView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "book")
                            Text("View Diary")
                            Spacer()
                            if locationManager.isEnabled {
                                Text("\(locationManager.entries.count) entries")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .themedRow()
                }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
                NavigationLink {
                    LiveActivitySettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "record.circle")
                        Text("Live Activity")
                        SettingPinTag(group: .liveActivity)
                        Spacer()
                        Text(liveActivityManager.isEnabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.liveActivity)
    #endif
#endif

                NavigationLink {
                    ClipboardManagerSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "list.clipboard")
                        Text("Clipboard Manager")
                        SettingPinTag(group: .clipboard)
                        Spacer()
                        Text(clipboardManager.isEnabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.clipboard)

                NavigationLink {
                    AutoRedactSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "eye.slash")
                        Text("Auto-Redact")
                        SettingPinTag(group: .privacy)
                        Spacer()
                        Text(redactionManager.isEnabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.privacy)
            } footer: {
#if targetEnvironment(macCatalyst)
                Text("Data synchronization settings")
                    .font(.caption)
#else
                Text("Data synchronization and location tracking")
                    .font(.caption)
#endif
            }
        }
        .themedList()
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Notifications & Sounds section detail (merged)
struct SettingsNotificationsSection: View {
    @ObservedObject var notificationManager = NotificationManager.shared
    @ObservedObject var soundManager = SoundManager.shared
    private let pushManager = PushRegistrationManager.shared
    @Setting(Settings.CodingAgents.detectionEnabled) private var agentDetectionEnabled
    @Setting(Settings.Notifications.agentPolicy) private var agentNotificationPolicy
    @Setting(Settings.Notifications.taskDetection) private var taskDetectionEnabled
    @Setting(Settings.Notifications.taskPolicy) private var taskNotificationPolicy
#if STANDALONE && targetEnvironment(macCatalyst)
    @ObservedObject var updateManager = UpdateManager.shared
#endif

    var body: some View {
        List {
            Section {
                SettingToggle(
                    Settings.Notifications.terminalNotifications,
                    isOn: Binding(
                        get: { notificationManager.terminalNotificationsEnabled },
                        set: { newValue in
                            Task {
                                if newValue {
                                    let granted = await notificationManager.requestPermissions()
                                    notificationManager.terminalNotificationsEnabled = granted
                                } else {
                                    notificationManager.terminalNotificationsEnabled = false
                                }
                            }
                        }
                    ),
                    title: "Terminal Notifications",
                    icon: "bell"
                )
                .themedRow()

                Text("Show notifications for terminal events (OSC 9/777) when the terminal is not focused")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()

#if !targetEnvironment(macCatalyst)
                SettingToggle(
                    Settings.Notifications.sshReminders,
                    isOn: Binding(
                        get: { notificationManager.isEnabled },
                        set: { newValue in
                            Task {
                                if newValue {
                                    let granted = await notificationManager.requestPermissions()
                                    if granted {
                                        notificationManager.isEnabled = true
                                    } else {
                                        notificationManager.isEnabled = false
                                    }
                                } else {
                                    notificationManager.isEnabled = false
                                }
                            }
                        }
                    ),
                    title: "SSH Session Reminders",
                    icon: "bell.badge"
                )
                .themedRow()

                Text("Reminds you to return to the app or enable Location Diary after 60 seconds in the background with active SSH sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
#endif

                NavigationLink {
                    PushNotificationSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "lock.shield")
                        Text("Push Notifications")
                        SettingPinTag(group: .notifications)
                        Spacer()
                        Text(pushManager.isEnabled ? "On" : "Off")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingGroupContextMenu(.notifications)

                // Same @AppStorage key as the Coding Agents screen, so both
                // entry points always show the same policy.
                NavigationLink {
                    AgentNotificationPolicyPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bell.and.waves.left.and.right")
                        Text("Agent Notifications")
                        SettingPinTag(Settings.Notifications.agentPolicy.erased)
                        Spacer()
                        Text(agentNotificationPolicy.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!agentDetectionEnabled)
                .themedRow()
                .settingContextMenu(Settings.Notifications.agentPolicy)

                if !agentDetectionEnabled {
                    Text("Turn on Detect Coding Agents in Terminal settings to enable agent notifications.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }

                // Same @AppStorage key as the Command Detection screen, so
                // both entry points always show the same policy.
                NavigationLink {
                    TaskNotificationPolicyPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "clock.badge.checkmark")
                        Text("Command Notifications")
                        SettingPinTag(Settings.Notifications.taskPolicy.erased)
                        Spacer()
                        Text(taskNotificationPolicy.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!taskDetectionEnabled)
                .themedRow()
                .settingContextMenu(Settings.Notifications.taskPolicy)

                if !taskDetectionEnabled {
                    Text("Turn on Detect Long-Running Commands in Terminal settings to enable command notifications.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            } header: {
                SettingGroupHeader("Notifications", group: .notifications)
            }

            Section {
                Picker(selection: $soundManager.bellPreset) {
                    ForEach(BellSoundPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "speaker.wave.2")
                        Text("Bell Sound")
                    }
                    .settingRow(Settings.Sounds.bellPreset)
                }
                .onChange(of: soundManager.bellPreset) { _, newValue in
                    soundManager.previewBellSound(newValue)
                }
                .themedRow()

                if soundManager.bellPreset.filename != nil {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "speaker.wave.3")
                        Text("Volume")
                            .settingRow(Settings.Sounds.bellVolume)
                        Slider(value: $soundManager.bellVolume, in: 0...1)
                    }
                    .themedRow()
                }

                Text("Sound played when a terminal bell (\\a) is triggered. \"Haptic Only\" preserves the default vibration-only behavior.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()

                if notificationManager.terminalNotificationsEnabled {
                    Picker(selection: $soundManager.notificationPreset) {
                        ForEach(NotificationSoundPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "music.note")
                            Text("Notification Sound")
                        }
                        .settingRow(Settings.Sounds.notificationPreset)
                    }
                    .onChange(of: soundManager.notificationPreset) { _, newValue in
                        soundManager.previewNotificationSound(newValue)
                    }
                    .themedRow()

                    Text("Sound used for OS notifications such as terminal events and SSH session reminders.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            } header: {
                SettingGroupHeader("Sounds", group: .sounds)
            }

            // Updates section (Standalone Mac Catalyst only)
            #if STANDALONE && targetEnvironment(macCatalyst)
            Section {
                Toggle(isOn: Binding(
                    get: { UpdateManager.shared.automaticallyChecksForUpdates },
                    set: { UpdateManager.shared.setAutomaticallyChecksForUpdates($0) }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.down.circle")
                        Text("Automatically Check for Updates")
                    }
                }
                .themedRow()

                if UpdateManager.shared.automaticallyChecksForUpdates {
                    Picker(selection: Binding(
                        get: { UpdateManager.shared.updateCheckInterval },
                        set: { UpdateManager.shared.setUpdateCheckInterval($0) }
                    )) {
                        ForEach(UpdateManager.UpdateCheckInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "calendar.badge.clock")
                            Text("Check Interval")
                        }
                    }
                    .themedRow()
                }

                Button {
                    UpdateManager.shared.checkForUpdates()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.clockwise.circle")
                        Text("Check for Updates Now")
                    }
                }
                .disabled(!UpdateManager.shared.canCheckForUpdates)
                .themedRow()
            } header: {
                Text("Updates")
            }
            #endif
        }
        .themedList()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Open source notice shown as the About section footer.
struct SettingsOpenSourceFooter: View {
    private static let repositoryURL = URL(string: "https://github.com/kitknox/rootshell")!

    var body: some View {
        VStack(spacing: 6) {
            Link(destination: Self.repositoryURL) {
                HStack(spacing: 6) {
                    Image("GitHubMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                    Text(verbatim: "kitknox/rootshell")
                        .fontWeight(.medium)
                }
                .font(.footnote)
            }

            Text("Open source under the MIT License")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 12)
    }
}

/// About section detail
struct SettingsAboutSection: View {
    var externalShowDebugSettings: Binding<Bool>? = nil
    @State private var _showDebugSettings = false

    private var showDebugSettings: Binding<Bool> {
        externalShowDebugSettings ?? $_showDebugSettings
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AnimatedAboutIcon(
                        onTap: {
                            if let url = URL(string: "https://www.rootshell.com") {
                                UIApplication.shared.open(url)
                            }
                        },
                        onLongPress: {
                            showDebugSettings.wrappedValue = true
                        }
                    )

                    Text("Rootshell")
                        .font(.headline)

                    Text("Written by Kit Knox")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .themedRow()

                HStack(spacing: 12) {
                    SettingsIcon(systemName: "info.circle")
                    Text("Version")
                    Spacer()
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(version) (\(build))")
                        Text(BuildInfo.date)
                    }
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .textSelection(.enabled)
                }
                .themedRow()

                NavigationLink(value: SettingsSearchDestination.acknowledgements) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "doc.text")
                        Text("Acknowledgements")
                    }
                }
                .themedRow()
            } footer: {
                SettingsOpenSourceFooter()
            }
        }
        .themedList()
        // On the List, not in it: destinations registered inside lazy list
        // content aren't reliably picked up, and the debug screen is pushed by
        // the tap-count gesture above rather than by a visible row.
        .navigationDestination(isPresented: showDebugSettings) {
            DebugSettingsView()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
