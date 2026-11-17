//
//  Settings+Keyboard.swift
//  rootshell
//
//  Keyboard behavior, toolbar keys, and keybind keys.
//

import Foundation

extension Ghostty.OptionKeyAsAlt: SettingValue {}
extension DrawerToggleMode: SettingValue {}
extension KeyboardToolbarStyle: SettingValue {}
extension KeyboardToolbarGlyphColoring: SettingValue {}
extension KeyboardToolbarSize: SettingValue {}
extension TerminalWritingAssistanceMode: SettingValue {}
extension KeyboardArrowJoystickButton.Mode: SettingValue {}
extension TerminalTouchKeyboardModel.FloatingGlassStyle: SettingValue {}
extension TerminalTouchKeyboardModel.Height: SettingValue {}
extension TerminalTouchKeyboardModel.Style: SettingValue {}
extension TerminalTouchKeyboardModel.Layout: SettingValue {}
extension TerminalTouchKeyboardModel.PhosphorColor: SettingValue {}

nonisolated extension Settings {
    enum Keyboard {
        static let touchEnabled = SettingKey(
            "terminalTouchKeyboardEnabled", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard", title: String(localized: "Terminal Keyboard"))
        static let touchInTextFields = SettingKey(
            "terminalTouchKeyboardInTextFields", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-text-fields", title: String(localized: "Use in Text Fields"))
        static let touchLayout = SettingKey(
            "terminalTouchKeyboardLayout", default: TerminalTouchKeyboardModel.Layout.us,
            group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-layout", title: String(localized: "Keyboard Layout"))
        static let touchStatePerTab = SettingKey(
            "terminalTouchKeyboardStatePerTab", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-state-per-tab", title: String(localized: "Separate Keyboard State per Tab"))
        static let touchSuggestions = SettingKey(
            "terminalTouchKeyboardSuggestions", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-suggestions", title: String(localized: "Terminal Keyboard Suggestions"))
        static let touchLetterPrediction = SettingKey(
            "terminalTouchKeyboardLetterPrediction", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-letter-prediction", title: String(localized: "Letter Prediction"))
        static let touchHaptics = SettingKey(
            "terminalTouchKeyboardHaptics", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-haptics", title: String(localized: "Terminal Keyboard Haptics"))
        static let touchCharacterPreview = SettingKey(
            "terminalTouchKeyboardCharacterPreview", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-character-preview", title: String(localized: "Character Preview"))
        static let touchHeight = SettingKey(
            "terminalTouchKeyboardHeight", default: TerminalTouchKeyboardModel.Height.large,
            group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-height", title: String(localized: "Keyboard Height"))
        /// iPhone Duo's closed front display; nil follows `touchHeight`.
        static let touchHeightDuoFront = SettingKey<TerminalTouchKeyboardModel.Height?>(
            "terminalTouchKeyboardHeightDuoFront", default: nil, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-height-duo-front", title: String(localized: "Front Display Keyboard Height"))
        /// Splits the docked keys on iPad and on iPhone Duo's flat inner display, as a bent fold does.
        static let touchSplit = SettingKey(
            "terminalTouchKeyboardSplit", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-split", title: String(localized: "Split Keyboard"))
        static let touchGlyphs = SettingKey(
            "terminalTouchKeyboardGlyphs", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-glyphs", title: String(localized: "Keyboard Key Glyphs"))
        static let touchStyle = SettingKey(
            "terminalTouchKeyboardStyle", default: TerminalTouchKeyboardModel.Style.flat,
            group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-style", title: String(localized: "Keyboard Style"))
        static let touchThemeAware = SettingKey(
            "terminalTouchKeyboardThemeAware", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-theme-aware", title: String(localized: "Follow Terminal Theme"))
        static let touchSteampunkThemeAwareKeycaps = SettingKey(
            "terminalTouchKeyboardSteampunkThemeAwareKeycaps", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-steampunk-theme-aware-keycaps", title: String(localized: "Theme-Aware Keycaps"))
        static let touchPhosphorColor = SettingKey(
            "terminalTouchKeyboardPhosphorColor", default: TerminalTouchKeyboardModel.PhosphorColor.green,
            group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-phosphor-color", title: String(localized: "Phosphor Color"))
        static let touchClickSound = SettingKey(
            "terminalTouchKeyboardClickSound", default: false, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-click-sound", title: String(localized: "Key Click Sounds"))
        static let touchSystemFloating = SettingKey(
            "terminalTouchKeyboardSystemFloating", default: true, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-system-floating", title: String(localized: "Use System Detached Keyboard"))
        static let touchFloatingGlassStyle = SettingKey(
            "terminalTouchKeyboardFloatingGlassStyle", default: TerminalTouchKeyboardModel.FloatingGlassStyle.regular,
            group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-floating-glass-style", title: String(localized: "Detached Keyboard Glass Style"))
        static let touchFloatingGlassTintOpacity = SettingKey(
            "terminalTouchKeyboardFloatingGlassTintOpacity", default: 0.25, group: .keyboard, policy: .localByDefault,
            configKey: "terminal-touch-keyboard-floating-glass-tint-opacity", range: 0...1, title: String(localized: "Detached Keyboard Tint Strength"))
        static let touchChooserPresented = SettingKey(
            "terminalTouchKeyboardChooserPresented", default: false, group: .keyboard, policy: .deviceOnly,
            title: String(localized: "Keyboard Chooser Presented"))

        static let writingAssistance = SettingKey(
            "terminalWritingAssistanceMode", default: TerminalWritingAssistanceMode.off, group: .keyboard,
            configKey: "terminal-writing-assistance",
            title: String(localized: "Writing Assistance", comment: "Direct terminal typing setting"))
        static let optionKeyAsAlt = SettingKey(
            "optionKeyAsAlt", default: Ghostty.OptionKeyAsAlt.off, group: .keyboard,
            configKey: "macos-option-as-alt",
            title: String(localized: "Option Key as Alt", comment: "Setting title"))
        static let forceASCIIKeyboard = SettingKey(
            "forceASCIIKeyboard", default: false, group: .keyboard, configKey: "force-ascii-keyboard",
            title: String(localized: "Force ASCII Keyboard", comment: "Setting title"))
        static let doubleSpaceForPeriod = SettingKey(
            "doubleSpaceForPeriod", default: false, group: .keyboard, configKey: "double-space-for-period",
            title: String(localized: "Double-Space Period Shortcut", comment: "Setting title"))
        static let composeAutocorrect = SettingKey(
            "composeAutocorrectEnabled", default: false, group: .keyboard, configKey: "compose-autocorrect-enabled",
            title: String(localized: "Compose Autocorrect", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            optionKeyAsAlt.erased, forceASCIIKeyboard.erased, doubleSpaceForPeriod.erased, composeAutocorrect.erased,
            writingAssistance.erased, touchEnabled.erased, touchInTextFields.erased, touchLayout.erased, touchSuggestions.erased, touchHaptics.erased, touchCharacterPreview.erased,
            touchHeight.erased, touchHeightDuoFront.erased, touchSplit.erased, touchGlyphs.erased, touchStyle.erased, touchThemeAware.erased, touchLetterPrediction.erased,
            touchSteampunkThemeAwareKeycaps.erased, touchPhosphorColor.erased, touchClickSound.erased,
            touchStatePerTab.erased, touchSystemFloating.erased, touchFloatingGlassStyle.erased, touchFloatingGlassTintOpacity.erased,
            touchChooserPresented.erased,
        ]
    }

    enum KeyboardToolbar {
        static let config = SettingKey<Data?>(
            "keyboardToolbarConfig", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Toolbar Layout", comment: "Setting title"))
        /// nil while Screen Sharing uses the terminal's layout.
        static let screenSharingConfig = SettingKey<Data?>(
            "keyboardToolbarConfigScreenSharing", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Screen Sharing Toolbar Layout", comment: "Setting title"))
        /// nil while KVM uses the terminal's layout.
        static let kvmConfig = SettingKey<Data?>(
            "keyboardToolbarConfigKVM", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "KVM Toolbar Layout", comment: "Setting title"))
        static let customKeys = SettingKey<Data?>(
            "keyboardToolbarCustomKeys", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Custom Toolbar Keys", comment: "Setting title"))
        /// Named copies of toolbar layouts, kept through a reset.
        static let savedLayouts = SettingKey<Data?>(
            "keyboardToolbarSavedLayouts", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Saved Toolbar Layouts", comment: "Setting title"))
        static let style = SettingKey(
            "keyboardToolbarStyle", default: KeyboardToolbarStyle.flat, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-style",
            title: String(localized: "Toolbar Style", comment: "Setting title"))
        static let deviceIdiom = SettingKey<String?>(
            "keyboardToolbarDeviceIdiom", default: nil, group: .keyboardToolbar, policy: .deviceOnly,
            title: String(localized: "Toolbar Layout Device", comment: "Setting title"))
        static let drawerOpenByDefault = SettingKey(
            "keyboardToolbarDrawerOpenByDefault", default: false, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-drawer-open-by-default",
            title: String(localized: "Open Drawer by Default", comment: "Setting title"))
        static let sizePhone = SettingKey(
            "keyboardToolbarSizePhone", default: KeyboardToolbarSize.automatic, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-size-iphone",
            title: String(localized: "Toolbar Size on iPhone", comment: "Setting title"))
        static let sizePad = SettingKey(
            "keyboardToolbarSizePad", default: KeyboardToolbarSize.automatic, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-size-ipad",
            title: String(localized: "Toolbar Size on iPad", comment: "Setting title"))
        static let sizeDuoInner = SettingKey(
            "keyboardToolbarSizeDuoInner", default: KeyboardToolbarSize.automatic, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-size-duo-inner",
            title: String(localized: "Toolbar Size on the Inner Display", comment: "Setting title"))
        static let sizeDuoFront = SettingKey(
            "keyboardToolbarSizeDuoFront", default: KeyboardToolbarSize.automatic, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-size-duo-front",
            title: String(localized: "Toolbar Size on the Front Display", comment: "Setting title"))
        // Points; 0 leaves the narrowest key to the toolbar.
        static let minKeyWidthPhone = SettingKey(
            "keyboardToolbarMinKeyWidthPhone", default: 0.0, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-min-key-width-iphone",
            title: String(localized: "Minimum Toolbar Key Width on iPhone", comment: "Setting title"))
        static let minKeyWidthPad = SettingKey(
            "keyboardToolbarMinKeyWidthPad", default: 0.0, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-min-key-width-ipad",
            title: String(localized: "Minimum Toolbar Key Width on iPad", comment: "Setting title"))
        static let minKeyWidthDuoInner = SettingKey(
            "keyboardToolbarMinKeyWidthDuoInner", default: 0.0, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-min-key-width-duo-inner",
            title: String(localized: "Minimum Toolbar Key Width on the Inner Display", comment: "Setting title"))
        static let minKeyWidthDuoFront = SettingKey(
            "keyboardToolbarMinKeyWidthDuoFront", default: 0.0, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-min-key-width-duo-front",
            title: String(localized: "Minimum Toolbar Key Width on the Front Display", comment: "Setting title"))
        static let keycaps = SettingKey(
            "keyboardToolbarKeycaps", default: false, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-keycaps",
            title: String(localized: "Toolbar Keycaps", comment: "Setting title"))
        static let glyphColoring = SettingKey(
            "keyboardToolbarGlyphColoring", default: KeyboardToolbarGlyphColoring.standard, group: .keyboardToolbar,
            policy: .localByDefault, configKey: "keyboard-toolbar-key-colors",
            title: String(localized: "Toolbar Key Colors", comment: "Setting title"))
        // Hex RGB, as the other color settings store it.
        static let glyphColor = SettingKey(
            "keyboardToolbarGlyphColor", default: "0A84FF", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color",
            title: String(localized: "Toolbar Key Color", comment: "Setting title"))
        static let glyphColorModifiers = SettingKey(
            "keyboardToolbarGlyphColorModifiers", default: "0A84FF", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color-modifiers",
            title: String(localized: "Toolbar Modifier Key Color", comment: "Setting title"))
        static let glyphColorNavigation = SettingKey(
            "keyboardToolbarGlyphColorNavigation", default: "30B0C7", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color-navigation",
            title: String(localized: "Toolbar Tab and Arrow Key Color", comment: "Setting title"))
        static let glyphColorSymbols = SettingKey(
            "keyboardToolbarGlyphColorSymbols", default: "FF9500", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color-symbols",
            title: String(localized: "Toolbar Symbol Key Color", comment: "Setting title"))
        static let glyphColorActions = SettingKey(
            "keyboardToolbarGlyphColorActions", default: "AF52DE", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color-actions",
            title: String(localized: "Toolbar Action Key Color", comment: "Setting title"))
        static let glyphColorCustomKeys = SettingKey(
            "keyboardToolbarGlyphColorCustomKeys", default: "34C759", group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-key-color-custom",
            title: String(localized: "Toolbar Custom Key Color", comment: "Setting title"))
        /// Colors set on single built-in keys, as JSON.
        static let keyColors = SettingKey<Data?>(
            "keyboardToolbarKeyColors", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Individual Toolbar Key Colors", comment: "Setting title"))
        static let drawerToggleMode = SettingKey(
            "keyboardToolbarDrawerToggleMode", default: DrawerToggleMode.stack, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-drawer-toggle-mode",
            title: String(localized: "More Button Behavior", comment: "Setting title"))
        static let persistent = SettingKey(
            "persistentToolbar", default: false, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "persistent-toolbar",
            title: String(localized: "Persistent Toolbar", comment: "Setting title"))
        static let showWithHardwareKeyboard = SettingKey(
            "showToolbarWithHardwareKeyboard", default: false, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "show-toolbar-with-hardware-keyboard",
            title: String(localized: "Show Toolbar with Hardware Keyboard", comment: "Setting title"))
        static let arrowJoystickMode = SettingKey(
            "arrowJoystickMode", default: KeyboardArrowJoystickButton.Mode.joystick, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "arrow-joystick-mode",
            title: String(localized: "Arrow Key Mode", comment: "Setting title"))
        static let remoteScreenStripExpanded = SettingKey(
            "remoteScreenToolbarStripExpanded", default: true, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Show Toolbar Keys in Remote Screen Controls", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            config.erased, screenSharingConfig.erased, kvmConfig.erased, customKeys.erased, savedLayouts.erased,
            deviceIdiom.erased,
            drawerOpenByDefault.erased, drawerToggleMode.erased, keycaps.erased, style.erased,
            glyphColoring.erased, glyphColor.erased, glyphColorModifiers.erased, glyphColorNavigation.erased,
            glyphColorSymbols.erased, glyphColorActions.erased, glyphColorCustomKeys.erased, keyColors.erased,
            sizePhone.erased, sizePad.erased, sizeDuoInner.erased, sizeDuoFront.erased,
            minKeyWidthPhone.erased, minKeyWidthPad.erased, minKeyWidthDuoInner.erased, minKeyWidthDuoFront.erased,
            persistent.erased, showWithHardwareKeyboard.erased, arrowJoystickMode.erased,
            remoteScreenStripExpanded.erased,
        ]

        /// The key holding a context's layout.
        static func layoutKey(for context: ToolbarContext) -> SettingKey<Data?> {
            switch context {
            case .terminal: config
            case .screenSharing: screenSharingConfig
            case .kvm: kvmConfig
            }
        }
    }

    enum Keybinds {
        static let overrides = SettingKey<Data?>(
            "keybindOverrides", default: nil, group: .keybinds,
            title: String(localized: "Keyboard Shortcuts", comment: "Setting title"))
        static let modTapRules = SettingKey<Data?>(
            "modTapRules", default: nil, group: .keybinds,
            title: String(localized: "Mod-Tap Rules", comment: "Setting title"))
        static let externalConfigPath = SettingKey<String?>(
            "externalGhosttyConfigPath", default: nil, group: .keybinds, policy: .deviceOnly,
            title: String(localized: "Imported Config Path", comment: "Setting title"))
        static let externalConfigOriginalFilename = SettingKey<String?>(
            "externalGhosttyConfigPath_originalFilename", default: nil, group: .keybinds, policy: .deviceOnly,
            title: String(localized: "Imported Config Filename", comment: "Setting title"))
        static let externalConfigBookmark = SettingKey<Data?>(
            "externalGhosttyConfigPath_bookmark", default: nil, group: .keybinds, policy: .deviceOnly,
            title: String(localized: "Imported Config Bookmark", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            overrides.erased, modTapRules.erased, externalConfigPath.erased,
            externalConfigOriginalFilename.erased, externalConfigBookmark.erased,
        ]
    }
}
