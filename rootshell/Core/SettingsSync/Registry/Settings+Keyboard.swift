//
//  Settings+Keyboard.swift
//  rootshell
//
//  Keyboard behavior, toolbar keys, and keybind keys.
//

import Foundation

extension Ghostty.OptionKeyAsAlt: SettingValue {}
extension DrawerToggleMode: SettingValue {}
extension TerminalWritingAssistanceMode: SettingValue {}
extension KeyboardArrowJoystickButton.Mode: SettingValue {}

nonisolated extension Settings {
    enum Keyboard {
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
            writingAssistance.erased,
        ]
    }

    enum KeyboardToolbar {
        static let config = SettingKey<Data?>(
            "keyboardToolbarConfig", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Toolbar Layout", comment: "Setting title"))
        static let customKeys = SettingKey<Data?>(
            "keyboardToolbarCustomKeys", default: nil, group: .keyboardToolbar, policy: .localByDefault,
            title: String(localized: "Custom Toolbar Keys", comment: "Setting title"))
        static let deviceIdiom = SettingKey<String?>(
            "keyboardToolbarDeviceIdiom", default: nil, group: .keyboardToolbar, policy: .deviceOnly,
            title: String(localized: "Toolbar Layout Device", comment: "Setting title"))
        static let drawerOpenByDefault = SettingKey(
            "keyboardToolbarDrawerOpenByDefault", default: false, group: .keyboardToolbar, policy: .localByDefault,
            configKey: "keyboard-toolbar-drawer-open-by-default",
            title: String(localized: "Open Drawer by Default", comment: "Setting title"))
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

        static let all: [AnySettingDefinition] = [
            config.erased, customKeys.erased, deviceIdiom.erased, drawerOpenByDefault.erased, drawerToggleMode.erased,
            persistent.erased, showWithHardwareKeyboard.erased, arrowJoystickMode.erased,
        ]
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
