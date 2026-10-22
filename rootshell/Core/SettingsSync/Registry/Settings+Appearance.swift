//
//  Settings+Appearance.swift
//  rootshell
//
//  Theme, font, cursor, selection, transparency, palette, and effect keys.
//

import Foundation

extension AppearanceManager.AppearanceMode: SettingValue {}
extension AppIconManager.AppIconVariant: SettingValue {}
extension CursorStyle: SettingValue {}
extension CursorBlinkMode: SettingValue {}
extension CursorEffect: SettingValue {}
extension SelectionAppearanceMode: SettingValue {}
extension TransparencyManager.BlurStyle: SettingValue {}
extension ShaderManager.AnimationMode: SettingValue {}
extension TerminalTouchKeyboardModel.BackgroundEffectPlacement: SettingValue {}
extension ScrollEdgeEffectMode: SettingValue {}

nonisolated extension Settings {
    enum Theme {
        static let selected = SettingKey(
            "selectedTheme", default: "Catppuccin Mocha", group: .theme, configKey: "theme",
            title: String(localized: "Theme", comment: "Setting title"))
        static let appearanceMode = SettingKey(
            "appearanceMode", default: AppearanceManager.AppearanceMode.automatic, group: .theme,
            configKey: "appearance-mode",
            title: String(localized: "Appearance", comment: "Setting title"))
        static let themedUI = SettingKey(
            "themedUI", default: true, group: .theme, configKey: "themed-ui",
            title: String(localized: "Theme-Aware UI", comment: "Setting title"))
        static let imNoFun = SettingKey(
            "imNoFun", default: false, group: .theme, configKey: "im-no-fun",
            title: String(localized: "I'm no fun", comment: "Setting title"))
        static let hostTint = SettingKey(
            "hostTint", default: false, group: .theme, configKey: "host-tint",
            title: String(localized: "Tint by Host", comment: "Setting title"))
        static let scrollEdgeEffect = SettingKey(
            "scrollEdgeEffect", default: ScrollEdgeEffectMode.hard, group: .theme, configKey: "scroll-edge-effect",
            title: String(localized: "Scroll Edge Effect", comment: "Setting title"))
        static let scrollEdgeOpacity = SettingKey(
            "scrollEdgeOpacity", default: 1.0, group: .theme, configKey: "scroll-edge-opacity", range: 0...1,
            title: String(localized: "Edge Opacity", comment: "Setting title"))
        static let uiOverrides = SettingKey<Data?>(
            "themeUIOverrides.v1", default: nil, group: .theme,
            title: String(localized: "Theme UI Color Overrides", comment: "Setting title"))
        static let favoriteIds = SettingKey(
            "favoriteThemeIds", default: [String](), group: .theme, configKey: "favorite-theme-ids",
            title: String(localized: "Favorite Themes", comment: "Setting title"))
        static let dayNightEnabled = SettingKey(
            "dayNightThemeEnabled", default: false, group: .theme, configKey: "day-night-theme-enabled",
            title: String(localized: "Match System Theme", comment: "Setting title"))
        static let dayNightDay = SettingKey(
            "dayNightThemeDayTheme", default: "Solarized Light", group: .theme, configKey: "day-night-theme-day-theme",
            title: String(localized: "Day Theme", comment: "Setting title"))
        static let dayNightNight = SettingKey(
            "dayNightThemeNightTheme", default: "Catppuccin Mocha", group: .theme, configKey: "day-night-theme-night-theme",
            title: String(localized: "Night Theme", comment: "Setting title"))
        static let dayNightDefault = SettingKey<String?>(
            "dayNightThemeDefaultTheme", default: nil, group: .theme, policy: .deviceOnly,
            title: String(localized: "Theme to Restore", comment: "Setting title"))
        static let appIconVariant = SettingKey(
            "selectedAppIconVariant", default: AppIconManager.AppIconVariant.defaultIcon, group: .theme,
            configKey: "selected-app-icon-variant",
            title: String(localized: "App Icon", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            selected.erased, appearanceMode.erased, themedUI.erased, uiOverrides.erased, favoriteIds.erased,
            dayNightEnabled.erased, dayNightDay.erased, dayNightNight.erased, dayNightDefault.erased,
            appIconVariant.erased, imNoFun.erased, hostTint.erased,
            scrollEdgeEffect.erased, scrollEdgeOpacity.erased,
        ]
    }

    enum Font {
        static let size = SettingKey(
            "fontSize", default: 13.0, group: .font, configKey: "font-size", range: 1...255,
            title: String(localized: "Font Size", comment: "Setting title"))
        static let family = SettingKey<String?>(
            "fontFamily", default: nil, group: .font, configKey: "font-family",
            title: String(localized: "Font", comment: "Setting title"))
        static let ligatures = SettingKey(
            "ligaturesEnabled", default: true, group: .font, configKey: "ligatures-enabled",
            title: String(localized: "Enable Ligatures", comment: "Setting title"))
        static let featurePrefs = SettingKey<Data?>(
            "fontFeaturePrefs", default: nil, group: .font,
            title: String(localized: "Font Features", comment: "Setting title"))
        static let cellAdjustmentPrefs = SettingKey<Data?>(
            "cellAdjustmentPrefs", default: nil, group: .font,
            title: String(localized: "Cell Width & Height", comment: "Setting title"))
        static let customFamilies = SettingKey<Data?>(
            "customFontFamilies", default: nil, group: .font, policy: .deviceOnly,
            title: String(localized: "Custom Fonts", comment: "Setting title"))
        static let replacedBundledFamilies = SettingKey(
            "replacedBundledFamilies", default: [String](), group: .font, policy: .deviceOnly,
            title: String(localized: "Replaced Bundled Fonts", comment: "Setting title"))
        static let nerdFontMigrationDone = SettingKey(
            "nerdFontFamilyMigrationDone", default: false, group: .font, policy: .deviceOnly,
            title: String(localized: "Nerd Font Migration", comment: "Setting title"))
        static let featureMigrationV1Done = SettingKey(
            "fontFeatureMigrationV1Done", default: false, group: .font, policy: .deviceOnly,
            title: String(localized: "Font Feature Migration", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            size.erased, family.erased, ligatures.erased, featurePrefs.erased, cellAdjustmentPrefs.erased,
            customFamilies.erased, replacedBundledFamilies.erased, nerdFontMigrationDone.erased,
            featureMigrationV1Done.erased,
        ]
    }

    enum Cursor {
        static let style = SettingKey(
            "cursorStyle", default: CursorStyle.block, group: .cursor, configKey: "cursor-style",
            title: String(localized: "Cursor Style", comment: "Setting title"))
        static let blinkEnabled = SettingKey(
            "cursorBlinkEnabled", default: false, group: .cursor, configKey: "cursor-style-blink",
            title: String(localized: "Cursor Blinking", comment: "Setting title"))
        static let blinkMode = SettingKey(
            "cursorBlinkMode", default: CursorBlinkMode.normal, group: .cursor, configKey: "cursor-blink-mode",
            title: String(localized: "Blink Style", comment: "Setting title"))
        static let effect = SettingKey(
            "cursorEffect", default: CursorEffect.none, group: .cursor, configKey: "cursor-effect",
            title: String(localized: "Cursor Effect", comment: "Setting title"))
        static let color = SettingKey<String?>(
            "cursorColor", default: nil, group: .cursor, configKey: "cursor-color",
            title: String(localized: "Cursor Color", comment: "Setting title"))
        static let textColor = SettingKey<String?>(
            "cursorTextColor", default: nil, group: .cursor, configKey: "cursor-text",
            title: String(localized: "Text Under Cursor", comment: "Setting title"))
        static let opacity = SettingKey(
            "cursorOpacity", default: 0.8, group: .cursor, configKey: "cursor-opacity", range: 0...1,
            title: String(localized: "Cursor Opacity", comment: "Setting title"))
        static let thickness = SettingKey(
            "cursorThickness", default: 0, group: .cursor, configKey: "cursor-thickness", range: -100...100,
            title: String(localized: "Cursor Thickness", comment: "Setting title"))
        static let height = SettingKey(
            "cursorHeight", default: 0, group: .cursor, configKey: "cursor-height", range: -100...100,
            title: String(localized: "Cursor Height", comment: "Setting title"))
        static let enabledBuiltInShadersLegacy = AnySettingDefinition.opaque(
            "enabledBuiltInShaders", group: .cursor,
            title: String(localized: "Enabled Built-in Shaders (legacy)", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            style.erased, blinkEnabled.erased, blinkMode.erased, effect.erased, color.erased, textColor.erased,
            opacity.erased, thickness.erased, height.erased, enabledBuiltInShadersLegacy,
        ]
    }

    enum Selection {
        static let appearanceMode = SettingKey(
            "selectionAppearanceMode", default: SelectionAppearanceMode.rootshell, group: .selection,
            configKey: "selection-appearance-mode",
            title: String(localized: "Selection Style", comment: "Setting title"))
        static let foregroundHex = SettingKey(
            "selectionForegroundHex", default: "1e1e2e", group: .selection, configKey: "selection-foreground",
            title: String(localized: "Selection Foreground", comment: "Setting title"))
        static let backgroundHex = SettingKey(
            "selectionBackgroundHex", default: "f5e0dc", group: .selection, configKey: "selection-background",
            title: String(localized: "Selection Background", comment: "Setting title"))
        static let copyOnSelect = SettingKey(
            "copyOnSelect", default: true, group: .selection, configKey: "copy-on-select",
            title: String(localized: "Copy on Select", comment: "Setting title"))
        static let useNativeLoupe = SettingKey(
            "useNativeSelectionLoupe", default: false, group: .selection, configKey: "use-native-selection-loupe",
            title: String(localized: "Use Native Selection Loupe", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            appearanceMode.erased, foregroundHex.erased, backgroundHex.erased, copyOnSelect.erased, useNativeLoupe.erased,
        ]
    }

    enum Transparency {
        static let backgroundOpacity = SettingKey(
            "backgroundOpacity", default: 0.92, group: .transparency, policy: .localByDefault,
            configKey: "background-opacity", range: 0...1,
            title: String(localized: "Background Opacity", comment: "Setting title"))
        static let backgroundBlurRadius = SettingKey(
            "backgroundBlurRadius", default: 30.0, group: .transparency, policy: .localByDefault,
            configKey: "background-blur", range: 0...255,
            title: String(localized: "Blur Radius", comment: "Setting title"))
        static let blurEnabled = SettingKey(
            "blurEnabled", default: true, group: .transparency, policy: .localByDefault,
            configKey: "blur-enabled",
            title: String(localized: "Background Blur", comment: "Setting title"))
        static let blurStyle = SettingKey(
            "blurStyle", default: TransparencyManager.BlurStyle.standard, group: .transparency, policy: .localByDefault,
            configKey: "blur-style",
            title: String(localized: "Blur Style", comment: "Setting title"))
        static let pinnedSidebarTransparency = SettingKey(
            "pinnedSidebarTransparencyEnabled", default: false, group: .transparency, policy: .localByDefault,
            configKey: "pinned-sidebar-transparency-enabled",
            title: String(localized: "Transparent Pinned Sidebar", comment: "Setting title"))
        static let backdropTransparency = SettingKey(
            "backdropTransparencyEnabled", default: true, group: .transparency, policy: .localByDefault,
            configKey: "backdrop-transparency-enabled",
            title: String(localized: "Transparent Backdrop", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            backgroundOpacity.erased, backgroundBlurRadius.erased, blurEnabled.erased, blurStyle.erased,
            pinnedSidebarTransparency.erased, backdropTransparency.erased,
        ]
    }

    enum Palette {
        static let generate = SettingKey(
            "paletteGenerate", default: false, group: .palette, configKey: "palette-generate",
            title: String(localized: "Generate Palette", comment: "Setting title"))
        static let harmonious = SettingKey(
            "paletteHarmonious", default: false, group: .palette, configKey: "palette-harmonious",
            title: String(localized: "Harmonious Palette", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [generate.erased, harmonious.erased]
    }

    enum Shaders {
        static let animationMode = SettingKey(
            "shaderAnimationMode", default: ShaderManager.AnimationMode.whenFocused, group: .shaders,
            configKey: "custom-shader-animation",
            title: String(localized: "Shader Animation", comment: "Setting title"))
        static let activeEffectId = SettingKey<String?>(
            "activeEffectId", default: nil, group: .shaders, configKey: "active-effect-id",
            title: String(localized: "Background Effect", comment: "Setting title"))
        static let effectConfigurations = SettingKey<Data?>(
            "effectConfigurations", default: nil, group: .shaders,
            title: String(localized: "Effect Settings", comment: "Setting title"))
        static let customShadersList = SettingKey<Data?>(
            "customShadersList", default: nil, group: .shaders, policy: .deviceOnly,
            title: String(localized: "Custom Shaders", comment: "Setting title"))
        static let enabledCustomShaders = SettingKey(
            "enabledCustomShaders", default: [String](), group: .shaders, policy: .deviceOnly,
            title: String(localized: "Enabled Custom Shaders", comment: "Setting title"))
        static let pendingVideoActivation = SettingKey<String?>(
            "pendingVideoActivation", default: nil, group: .shaders, policy: .deviceOnly,
            title: String(localized: "Pending Video Background", comment: "Setting title"))
        static let solarCachedLocation = SettingKey<Data?>(
            "solarGraph.cachedLocation", default: nil, group: .shaders, policy: .deviceOnly,
            title: String(localized: "Cached Solar Location", comment: "Setting title"))
        static let videoPausedDownloads = AnySettingDefinition.opaque(
            "videoBackgroundPausedDownloads", group: .shaders,
            title: String(localized: "Paused Video Downloads", comment: "Setting title"))
        static let effectIncludesPinnedSidebar = SettingKey(
            "backgroundEffectIncludesPinnedSidebar", default: true, group: .shaders,
            configKey: "background-effect-includes-pinned-sidebar",
            title: String(localized: "Extend Effect Under Pinned Sidebar", comment: "Setting title"))
        static let keyboardBackgroundEffect = SettingKey(
            "keyboardBackgroundEffect", default: TerminalTouchKeyboardModel.BackgroundEffectPlacement.off,
            group: .shaders, policy: .localByDefault,
            configKey: "keyboard-background-effect",
            title: String(localized: "Custom Keyboard Background", comment: "Setting title"))
        static let keyboardEffectId = SettingKey(
            "keyboardEffectId", default: BackgroundEffectSelection.followTerminalID,
            group: .shaders, policy: .localByDefault, configKey: "keyboard-effect-id",
            title: String(localized: "Keyboard Effect", comment: "Setting title"))
        static let sidebarEffectId = SettingKey(
            "sidebarEffectId", default: BackgroundEffectSelection.followTerminalID,
            group: .shaders, policy: .localByDefault, configKey: "sidebar-effect-id",
            title: String(localized: "Sidebar Effect", comment: "Setting title"))
        static let themeGradientBackdrop = SettingKey(
            "themeGradientBackdrop", default: false, group: .shaders,
            configKey: "theme-gradient-backdrop",
            title: String(localized: "Theme Gradient Backdrop", comment: "Setting title"))
        static let textAboveEffect = SettingKey(
            "backgroundEffectTextAbove", default: true, group: .shaders,
            configKey: "background-effect-text-above",
            title: String(localized: "Text Above Effect", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            animationMode.erased, activeEffectId.erased, effectConfigurations.erased, customShadersList.erased,
            enabledCustomShaders.erased, pendingVideoActivation.erased, solarCachedLocation.erased,
            videoPausedDownloads, effectIncludesPinnedSidebar.erased, keyboardBackgroundEffect.erased,
            keyboardEffectId.erased, sidebarEffectId.erased, themeGradientBackdrop.erased, textAboveEffect.erased,
        ]
    }
}
