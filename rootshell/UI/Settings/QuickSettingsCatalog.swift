import SwiftUI

/// Deliberate opt-in: being a scalar registry value does not make a setting safe
/// to edit without its full workflow. Setters mirror the owning Settings screen.
@MainActor
struct QuickSetting: Identifiable {
    struct Choice: Identifiable {
        let id: String
        let title: String
        let value: CodableValue?
    }

    enum Editor {
        case toggle
        case choices(() -> [Choice])
        case number(range: ClosedRange<Double>, step: Double, integral: Bool)
        case text
        case color
    }

    let definition: AnySettingDefinition
    let editor: Editor
    var keywords: String = ""
    var note: String = ""
    var unavailableReason: () -> String? = { nil }
    let read: () -> CodableValue?
    let write: (CodableValue?) -> Void
    var id: String { definition.name }
    var title: String { definition.title }

    var disabledReason: String? {
        if !ProtectedDataGuard.isAvailable { return String(localized: "Unlock your device to edit settings.") }
        if SettingFileLock.isReadOnly(id) { return String(localized: "Managed by your config file. Enable write-back in Settings to edit.") }
        return unavailableReason()
    }

    var valueLabel: String {
        let value = read()
        if case .choices(let choices) = editor,
           let choice = choices().first(where: { $0.value == value }) { return choice.title }
        return value?.displayString ?? String(localized: "Default")
    }

    func commit(_ value: CodableValue?) -> String? {
        if let disabledReason { return disabledReason }
        if let value {
            guard definition.validate(value) else { return String(localized: "Invalid setting value.") }
        } else if !definition.isOptional {
            return String(localized: "A value is required.")
        }
        switch editor {
        case .choices(let choices):
            guard choices().contains(where: { $0.value == value }) else { return String(localized: "Choose an available value.") }
        case .number(let range, _, let integral):
            let number: Double
            switch value {
            case .int(let n): number = Double(n)
            case .double(let n): number = n
            default: return String(localized: "Enter a number.")
            }
            guard QuickSettingsInput.validNumber(number, range: range, integral: integral) else {
                return String(localized: "Enter a value from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
            }
        case .color:
            if case .string(let hex) = value, !QuickSettingsInput.isHexColor(hex) {
                return String(localized: "Enter a six-digit hex color, such as #AABBCC.")
            }
        case .text:
            if case .string(let text) = value, text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return String(localized: "Enter a single line of text.")
            }
        case .toggle: break
        }
        write(value)
        return nil
    }

    func requiring(_ reason: @escaping () -> String?) -> Self {
        var copy = self
        copy.unavailableReason = reason
        return copy
    }

    func annotated(_ text: String) -> Self {
        var copy = self
        copy.note = text
        return copy
    }
}

@MainActor
enum QuickSettingsCatalog {
    private static func entry<V: SettingValue>(
        _ key: SettingKey<V>, _ editor: QuickSetting.Editor,
        keywords: String = "", set: ((V) -> Void)? = nil
    ) -> QuickSetting {
        QuickSetting(definition: key.erased, editor: editor, keywords: keywords,
            read: { SettingsStore.shared.box(for: key.name).value ?? key.defaultValue.codableValue },
            write: { value in
                let decoded = value.flatMap(V.init(codableValue:)) ?? key.defaultValue
                if let set { set(decoded) } else { SettingsStore.shared.set(key, decoded) }
            })
    }

    private static func toggle(_ key: SettingKey<Bool>, inverted: Bool = false, set: ((Bool) -> Void)? = nil) -> QuickSetting {
        var result = entry(key, .toggle, set: set)
        if inverted {
            result = QuickSetting(definition: key.erased, editor: .toggle,
                read: {
                    let value = SettingsStore.shared.box(for: key.name).value.flatMap(Bool.init(codableValue:)) ?? key.defaultValue
                    return .bool(!value)
                },
                write: { if case .bool(let value) = $0 { SettingsStore.shared.set(key, !value) } })
        }
        return result
    }

    private static func choices<V: SettingValue & CaseIterable>(
        _ key: SettingKey<V>, label: @escaping (V) -> String, set: ((V) -> Void)? = nil
    ) -> QuickSetting {
        entry(key, .choices {
            V.allCases.enumerated().map { .init(id: String($0.offset), title: label($0.element), value: $0.element.codableValue) }
        }, set: set)
    }

    private static func number(_ key: SettingKey<Double>, _ range: ClosedRange<Double>, step: Double = 1, set: ((Double) -> Void)? = nil) -> QuickSetting {
        entry(key, .number(range: range, step: step, integral: false), set: set)
    }

    private static func integer(_ key: SettingKey<Int>, _ range: ClosedRange<Int>, set: ((Int) -> Void)? = nil) -> QuickSetting {
        entry(key, .number(range: Double(range.lowerBound)...Double(range.upperBound), step: 1, integral: true), set: set)
    }

    static func makeEntries() -> [QuickSetting] {
        var entries: [QuickSetting] = [
            choices(Settings.Theme.appearanceMode, label: { $0.displayName }, set: { AppearanceManager.shared.currentAppearanceMode = $0 }),
            toggle(Settings.Theme.themedUI, set: { AppearanceManager.shared.themedUIEnabled = $0 }),
            toggle(Settings.Theme.imNoFun),
            toggle(Settings.Theme.hostTint),
            choices(Settings.Theme.scrollEdgeEffect, label: { $0.displayName }),
            number(Settings.Theme.scrollEdgeOpacity, 0...1, step: 0.05),
            entry(Settings.Theme.selected, .choices {
                ThemeManager.shared.availableThemes.map { .init(id: $0.name, title: $0.name, value: .string($0.name)) }
            }, keywords: "appearance colors colour scheme", set: { ThemeManager.shared.currentTheme = $0 })
                .requiring { SettingsStore.shared.get(Settings.Theme.dayNightEnabled) ? String(localized: "Match System Theme is enabled. Change Day Theme or Night Theme instead.") : nil },
            toggle(Settings.Theme.dayNightEnabled, set: { DayNightThemeManager.shared.enabled = $0 }),
            entry(Settings.Theme.dayNightDay, .choices {
                ThemeManager.shared.availableThemes.map { .init(id: $0.name, title: $0.name, value: .string($0.name)) }
            }, set: { DayNightThemeManager.shared.dayTheme = $0 })
                .requiring { SettingsStore.shared.get(Settings.Theme.dayNightEnabled) ? nil : String(localized: "Enable Match System Theme first.") },
            entry(Settings.Theme.dayNightNight, .choices {
                ThemeManager.shared.availableThemes.map { .init(id: $0.name, title: $0.name, value: .string($0.name)) }
            }, set: { DayNightThemeManager.shared.nightTheme = $0 })
                .requiring { SettingsStore.shared.get(Settings.Theme.dayNightEnabled) ? nil : String(localized: "Enable Match System Theme first.") },
        ]
        entries += [
            number(Settings.Font.size, 4...24, set: { FontManager.shared.currentFontSize = $0 }),
            toggle(Settings.Font.ligatures, set: { FontManager.shared.ligaturesEnabled = $0 }),
            entry(Settings.Font.family, .choices {
                let manager = FontManager.shared
                let families = (manager.availableFamilies + manager.systemFontFamilies).map { ($0.configName, $0.displayName) }
                    + manager.customFontFamilies.map { ($0.configName, $0.displayName) }
                var seen: Set<String> = []
                return [.init(id: "default", title: String(localized: "Default"), value: nil)] + families.filter { seen.insert($0.0).inserted }.map {
                    .init(id: $0.0, title: $0.1, value: .string($0.0))
                }
            }, keywords: "typeface typography", set: { FontManager.shared.currentFontFamily = $0 }),
        ]
        entries += [
            choices(Settings.Cursor.style, label: { $0.displayName }, set: { CursorManager.shared.cursorStyle = $0 }),
            toggle(Settings.Cursor.blinkEnabled, set: { CursorManager.shared.cursorBlinkEnabled = $0 }),
            choices(Settings.Cursor.blinkMode, label: { $0.displayName }, set: { CursorManager.shared.cursorBlinkMode = $0 })
                .requiring { CursorManager.shared.cursorBlinkEnabled ? nil : String(localized: "Enable Cursor Blinking first.") },
            choices(Settings.Cursor.effect, label: { $0.displayName }, set: { CursorManager.shared.cursorEffect = $0 }),
            number(Settings.Cursor.opacity, 0...1, step: 0.05, set: { CursorManager.shared.cursorOpacity = $0 }),
            integer(Settings.Cursor.thickness, -4...10, set: { CursorManager.shared.cursorThickness = $0 }),
            integer(Settings.Cursor.height, -4...10, set: { CursorManager.shared.cursorHeight = $0 }),
            entry(Settings.Cursor.color, .color, set: { CursorManager.shared.cursorColor = $0 }),
            entry(Settings.Cursor.textColor, .color, set: { CursorManager.shared.cursorTextColor = $0 }),
        ]
        entries += [
            toggle(Settings.Palette.generate, set: { PaletteManager.shared.paletteGenerateEnabled = $0 }),
            toggle(Settings.Palette.harmonious, set: { PaletteManager.shared.paletteHarmoniousEnabled = $0 })
                .requiring { PaletteManager.shared.paletteGenerateEnabled ? nil : String(localized: "Enable Generate Palette first.") },
            choices(Settings.Selection.appearanceMode, label: { $0.displayName }, set: { SelectionManager.shared.selectionMode = $0 }),
            entry(Settings.Selection.foregroundHex, .color, set: { SelectionManager.shared.customForegroundHex = $0 })
                .requiring { SelectionManager.shared.selectionMode == .custom ? nil : String(localized: "Choose Custom Selection Style first.") },
            entry(Settings.Selection.backgroundHex, .color, set: { SelectionManager.shared.customBackgroundHex = $0 })
                .requiring { SelectionManager.shared.selectionMode == .custom ? nil : String(localized: "Choose Custom Selection Style first.") },
            choices(Settings.Shaders.animationMode, label: { $0.displayName }, set: { ShaderManager.shared.animationMode = $0 }),
            toggle(Settings.Shaders.themeGradientBackdrop, set: { EffectManager.shared.isBackdropEnabled = $0 }),
            toggle(Settings.Shaders.textAboveEffect, set: { EffectManager.shared.isTextAboveEffectEnabled = $0 }),
            number(Settings.Transparency.backgroundOpacity, 0...1, step: 0.01, set: { TransparencyManager.shared.backgroundOpacity = $0 }),
            toggle(Settings.Transparency.pinnedSidebarTransparency, set: { TransparencyManager.shared.pinnedSidebarTransparencyEnabled = $0 }),
            toggle(Settings.Selection.copyOnSelect, set: {
                SettingsStore.shared.set(Settings.Selection.copyOnSelect, $0)
                // Local writes do not dispatch SettingsRefreshHub. Push the
                // regenerated config so existing terminals see the change.
                Ghostty.App.shared?.reloadGlobalConfig()
            }),
        ]
        entries += [
            choices(Settings.Keyboard.optionKeyAsAlt, label: { $0.displayName }),
            toggle(Settings.Keyboard.composeAutocorrect),
            choices(Settings.Window.splitFocusBorderStyle, label: { $0.displayName }),
            choices(Settings.Window.splitFocusBorderColor, label: { $0.displayName }),
            entry(Settings.Window.splitFocusBorderCustomColor, .color).requiring {
                SettingsStore.shared.get(Settings.Window.splitFocusBorderColor) == .custom ? nil : String(localized: "Choose Custom Split Border Color first.")
            },
            toggle(Settings.Window.roundedPanes),
            toggle(Settings.Window.confirmBeforeClosingPane),
            toggle(Settings.Window.confirmBeforeClosingTab),
        ]
        entries += [
            choices(Settings.Tabs.newTabAction, label: { $0.displayName }),
            toggle(Settings.Tabs.barHidden, inverted: true),
            toggle(Settings.Tabs.barAnimationsDisabled),
            choices(Settings.Tabs.topTabStyle, label: { $0.displayName }),
            toggle(Settings.Tabs.compactPillSpacing),
            toggle(Settings.Tabs.showScopeMenu),
            toggle(Settings.Tabs.showShortcutIndicators),
            toggle(Settings.Tabs.exposeShowsCaptions),
            toggle(Settings.Tabs.programIcons),
            toggle(Settings.Sidebar.autoHideOnSelect),
            toggle(Settings.Sidebar.largeControls),
            integer(Settings.Sidebar.rowLines, 1...3),
        ]
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            entries += [
                choices(Settings.Tabs.duoFrontDisplayMode, label: { $0.displayName })
                    .annotated(String(localized: "Applies to Duo's front display when closed.")),
                toggle(Settings.Tabs.duoBehindCameraShowsTabs)
                    .requiring {
                        SettingsStore.shared.get(Settings.Tabs.duoFrontDisplayMode) == .behindCamera
                            ? nil : String(localized: "Choose Behind Camera first.")
                    }
                    .annotated(String(localized: "Text behind the camera will be hidden.")),
            ]
        }
        #endif
        entries += [
            choices(Settings.Power.maxRefreshRate, label: { $0.displayName }, set: { PowerManager.shared.maxRefreshRate = $0 }),
            choices(Settings.Power.batteryRefreshRate, label: { $0.displayName }, set: { PowerManager.shared.batteryRefreshRate = $0 })
                .requiring { PowerManager.shared.maxRefreshRate == .adaptive ? nil : String(localized: "Choose Adaptive Maximum Refresh Rate first.") },
            toggle(Settings.Power.autoSaver, set: { PowerManager.shared.autoSaverEnabled = $0 }),
            toggle(Settings.SessionRestore.sessionPersistence),
            entry(Settings.Terminal.terminalTypeLocal, .text, keywords: "TERM shell")
                .annotated(String(localized: "Applies to new local sessions.")),
            entry(Settings.Terminal.terminalTypeRemote, .text, keywords: "TERM ssh mosh tssh")
                .annotated(String(localized: "Applies to new remote sessions.")),
        ]
        entries += [
            choices(Settings.Locale.clockFormat, label: { $0.displayName }),
            entry(Settings.Locale.mode, .choices {
                [
                    .init(id: "auto", title: String(localized: "Automatic"), value: .string("auto")),
                    .init(id: "none", title: String(localized: "Don't Send"), value: .string("none")),
                    .init(id: "custom", title: String(localized: "Custom"), value: .string("custom")),
                ]
            }),
            entry(Settings.Locale.custom, .text).requiring {
                SettingsStore.shared.get(Settings.Locale.mode) == .custom ? nil : String(localized: "Choose Custom Locale first.")
            },
            choices(Settings.Sounds.bellPreset, label: { $0.displayName }, set: { SoundManager.shared.bellPreset = $0 }),
            choices(Settings.Sounds.notificationPreset, label: { $0.displayName }, set: { SoundManager.shared.notificationPreset = $0 }),
            entry(Settings.Sounds.bellVolume, .number(range: 0...1, step: 0.05, integral: false), set: { SoundManager.shared.bellVolume = $0 }),
        ]
        entries += [
            toggle(Settings.Connections.forceIPv4),
            toggle(Settings.Connections.publicKeyAuthProbe),
            toggle(Settings.Connections.hideNonPQKexWarning, inverted: true),
            toggle(Settings.Connections.healthMonitoring, set: {
                SettingsStore.shared.set(Settings.Connections.healthMonitoring, $0)
                NotificationCenter.default.post(name: .sshHealthMonitoringToggled, object: nil, userInfo: ["enabled": $0])
            }),
            entry(Settings.Connections.healthProbeInterval, .choices {
                [1, 5, 10, 15, 30, 60].map { .init(id: String($0), title: String(localized: "\($0) seconds"), value: .int($0)) }
            }, set: {
                SettingsStore.shared.set(Settings.Connections.healthProbeInterval, $0)
                NotificationCenter.default.post(name: .sshHealthProbeIntervalChanged, object: nil, userInfo: ["interval": $0])
            }).requiring { SettingsStore.shared.get(Settings.Connections.healthMonitoring) ? nil : String(localized: "Enable Connection Health Monitoring first.") },
        ]
        entries += [
            toggle(Settings.Multiplexer.tmuxSessionDiscovery),
            toggle(Settings.Multiplexer.zellijSessionDiscovery),
            toggle(Settings.Multiplexer.herdrSessionDiscovery),
            toggle(Settings.Multiplexer.zmxSessionDiscovery),
            toggle(Settings.Multiplexer.remoteSessionDiscovery),
            choices(Settings.Multiplexer.sessionDiscoverySortOrder, label: { $0.displayName }),
            choices(Settings.Multiplexer.tabCloseAction, label: { $0.displayName }),
            toggle(Settings.Multiplexer.tabExposeMultiplexer),
            toggle(Settings.Multiplexer.detachBanner),
        ]
        entries += [
            toggle(Settings.Roam.holePunch),
            toggle(Settings.Roam.predictOverwrite),
            toggle(Settings.Roam.moshAltScreen),
            choices(Settings.Roam.predictionMode, label: { $0.displayName }),
            choices(Settings.Roam.trzszTransportMode, label: { $0.displayName }),
            toggle(Settings.ScreenSharing.controlOptionAsCommandDefault),
            toggle(Settings.ScreenSharing.routeReservedShortcutsToVNCDefault),
            choices(Settings.ScreenSharing.clipboardSyncDefault, label: { $0.displayName }),
            choices(Settings.ScreenSharing.panningDefault, label: { $0.displayName }),
            toggle(Settings.Transfer.attachmentUploadConfirm),
            choices(Settings.Transfer.attachmentUploadFormat, label: { $0.displayName }),
        ]
        entries += [
            toggle(Settings.CodingAgents.detectionEnabled, set: {
                SettingsStore.shared.set(Settings.CodingAgents.detectionEnabled, $0)
                AgentAttentionCenter.shared.setDetectionEnabled($0)
            }),
            toggle(Settings.CodingAgents.attentionBadges),
            toggle(Settings.Notifications.taskDetection, set: {
                SettingsStore.shared.set(Settings.Notifications.taskDetection, $0)
                AgentAttentionCenter.shared.setTaskDetectionEnabled($0)
            }),
            toggle(Settings.Notifications.agentIncludePrompt),
            toggle(Settings.Notifications.pushAgentBackgroundOnly),
            toggle(Settings.Notifications.pushAgentLogos),
            toggle(Settings.Privacy.autoRedact, set: { RedactionManager.shared.isEnabled = $0 }),
        ]
        for key in [Settings.Notifications.taskDetectPrompts, Settings.Notifications.taskDetectTests,
                    Settings.Notifications.taskDetectBuilds, Settings.Notifications.taskDetectInfra,
                    Settings.Notifications.taskDetectTransfers] {
            entries.append(toggle(key, set: {
                SettingsStore.shared.set(key, $0)
                AgentAttentionCenter.shared.taskFamiliesChanged()
            }).requiring {
                SettingsStore.shared.get(Settings.Notifications.taskDetection) ? nil : String(localized: "Enable Detect Long-Running Commands first.")
            })
        }
        #if STANDALONE && targetEnvironment(macCatalyst)
        entries += [
            choices(Settings.Visor.position, label: { $0.displayName }, set: { VisorSettings.shared.position = $0 }),
            choices(Settings.Visor.screen, label: { $0.displayName }, set: { VisorSettings.shared.screen = $0 }),
            choices(Settings.Visor.spaceBehavior, label: { $0.displayName }, set: { VisorSettings.shared.spaceBehavior = $0 }),
            toggle(Settings.Visor.autohide, set: { VisorSettings.shared.autohide = $0 }),
            entry(Settings.Visor.animationDurationMs, .number(range: 50...500, step: 10, integral: true), set: { VisorSettings.shared.animationDurationMs = $0 }),
        ]
        #endif
        #if !CHINA_BUILD
        entries.append(number(Settings.AI.textSize, AIAgentFontManager.shared.textSizeRange, set: { AIAgentFontManager.shared.textSize = $0 }))
        #endif
        #if !targetEnvironment(macCatalyst)
        entries += [
            toggle(Settings.Keyboard.forceASCIIKeyboard, set: {
                SettingsStore.shared.set(Settings.Keyboard.forceASCIIKeyboard, $0)
                NotificationCenter.default.post(name: .forceASCIIKeyboardChanged, object: nil)
            }),
            choices(Settings.Keyboard.writingAssistance, label: { $0.title }),
            toggle(Settings.Keyboard.doubleSpaceForPeriod),
            toggle(Settings.KeyboardToolbar.persistent),
            toggle(Settings.Prompt.useStarship),
            toggle(Settings.Prompt.showGit),
            toggle(Settings.Prompt.useRightPrompt),
            toggle(Settings.Prompt.useTransientPrompt),
            toggle(Settings.Prompt.addNewline),
            entry(Settings.Prompt.customUsername, .text),
            toggle(Settings.Selection.useNativeLoupe),
            toggle(Settings.Gestures.tabExposeGesture),
        ]
        for key in [Settings.Gestures.scrollMode, Settings.Gestures.lineScrollback, Settings.Gestures.rubberBandScrollback] {
            entries.append(toggle(key, set: {
                SettingsStore.shared.set(key, $0)
                NotificationCenter.default.post(name: .touchModeChanged, object: nil)
            }))
        }
        #if !os(visionOS)
        entries += [
            toggle(Settings.Connections.backgroundKeepalive),
            toggle(Settings.KeyboardToolbar.showWithHardwareKeyboard, set: {
                SettingsStore.shared.set(Settings.KeyboardToolbar.showWithHardwareKeyboard, $0)
                NotificationCenter.default.post(name: .keyboardToolbarHardwareSettingChanged, object: nil)
            }),
        ]
        #endif
        #else
        entries += [
            toggle(Settings.Multiplexer.localSessionDiscovery),
            toggle(Settings.Transparency.backdropTransparency, set: { TransparencyManager.shared.backdropTransparencyEnabled = $0 })
                .requiring { EffectManager.shared.isBackdropEnabled ? nil : String(localized: "Turn on the Theme Gradient backdrop first.") },
        ]
        if TransparencyManager.useSandboxBlur {
            entries.append(toggle(Settings.Transparency.blurEnabled, set: { TransparencyManager.shared.blurEnabled = $0 })
                .requiring { TransparencyManager.shared.usesGlass ? String(localized: "Choose Standard Blur Style first.") : nil })
        } else {
            entries.append(number(Settings.Transparency.backgroundBlurRadius, 0...80, set: { TransparencyManager.shared.backgroundBlurRadius = $0 })
                .requiring { TransparencyManager.shared.usesGlass ? String(localized: "Choose Standard Blur Style first.") : nil })
        }
        #endif
        if TransparencyManager.isGlassAvailable {
            entries.append(choices(Settings.Transparency.blurStyle, label: { $0.title }, set: { TransparencyManager.shared.blurStyle = $0 }))
        }
        if UIDevice.current.userInterfaceIdiom != .phone {
            entries += [
                toggle(Settings.Tabs.hoverPreviews),
                choices(Settings.Tabs.hoverPreviewActivation, label: { $0.displayName }),
            ]
        }
        #if DEBUG
        assert(Set(entries.map(\.id)).count == entries.count, "Duplicate Quick Settings entries")
        assert(entries.allSatisfy { SettingsRegistry.shared.definition(for: $0.id) != nil }, "Unregistered Quick Setting")
        #endif
        for index in entries.indices {
            let metadata = SettingsSearchEntry.all.filter { $0.title == entries[index].title }.flatMap(\.keywords)
            entries[index].keywords += " " + metadata.joined(separator: " ")
        }
        return entries.sorted {
            let lhs = ($0.definition.group.title, $0.title, $0.id)
            let rhs = ($1.definition.group.title, $1.title, $1.id)
            return lhs < rhs
        }
    }
}
