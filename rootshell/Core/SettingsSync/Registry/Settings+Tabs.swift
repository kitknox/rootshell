//
//  Settings+Tabs.swift
//  rootshell
//
//  Tab bar, tab sidebar, window chrome, and power keys.
//

import Foundation

enum TabHoverPreviewActivation: String, CaseIterable, Sendable {
    case always
    case shift
    case command
    case option
    case control

    var displayName: String {
        switch self {
        case .always: return String(localized: "Always", comment: "Tab hover preview activation")
        case .shift: return String(localized: "Shift", comment: "Tab hover preview activation")
        case .command: return String(localized: "Command", comment: "Tab hover preview activation")
        case .option: return String(localized: "Option", comment: "Tab hover preview activation")
        case .control: return String(localized: "Control", comment: "Tab hover preview activation")
        }
    }
}

extension NewTabAction: SettingValue {}
extension TabHoverPreviewActivation: SettingValue {}
extension TopTabStyle: SettingValue {}
extension SplitFocusBorderStyle: SettingValue {}
extension SplitFocusBorderColor: SettingValue {}
extension PowerManager.RefreshRateSetting: SettingValue {}
extension PowerManager.BatteryRefreshRate: SettingValue {}

nonisolated extension Settings {
    enum Tabs {
        // Keep the persisted identity so sync records, per-key pins, and old
        // preferences survive the move out of Multiplexers without migration.
        static let newTabAction = SettingKey(
            "tmuxNewTabAction", default: NewTabAction.localShell, group: .tabs, configKey: "new-tab-action",
            title: String(localized: "New Tab Action", comment: "Setting title"))
        static let barHidden = SettingKey(
            "tabBarHidden", default: false, group: .tabs, configKey: "tab-bar-hidden",
            title: String(localized: "Show Top Tab Bar", comment: "Setting title"))
        static let barAnimationsDisabled = SettingKey(
            "tabBarAnimationsDisabled", default: false, group: .tabs, configKey: "tab-bar-animations-disabled",
            title: String(localized: "Disable Tab Animations", comment: "Setting title"))
        static let topTabStyle = SettingKey(
            "topTabStyle", default: TopTabStyle.pills, group: .tabs, configKey: "top-tab-style",
            title: String(localized: "Tab Style", comment: "Setting title"))
        static let compactPillSpacing = SettingKey(
            "compactPillTabSpacing", default: false, group: .tabs, configKey: "compact-pill-tab-spacing",
            title: String(localized: "Compact Tab Spacing", comment: "Setting title"))
        static let showScopeMenu = SettingKey(
            "showTabScopeMenu", default: true, group: .tabs, configKey: "show-tab-scope-menu",
            title: String(localized: "Show Group Menu", comment: "Setting title"))
        static let showShortcutIndicators = SettingKey(
            "showTabShortcutIndicators", default: false, group: .tabs, configKey: "show-tab-shortcut-indicators",
            title: String(localized: "Show Tab Shortcuts", comment: "Setting title"))
        static let exposeShowsCaptions = SettingKey(
            "tabExposeShowsCaptions", default: true, group: .tabs, configKey: "tab-expose-shows-captions",
            title: String(localized: "Tab Exposé Captions", comment: "Setting title"))
        /// Preview thumbnail scale set by pinching in the exposé; 1 = auto-fit.
        static let exposeZoom = SettingKey(
            "tabExposeZoom", default: 1.0, group: .tabs, policy: .localByDefault, configKey: "tab-expose-zoom",
            title: String(localized: "Tab Exposé Preview Size", comment: "Setting title"))
        /// Live thumbnail while the pointer rests on a tab (top bar or sidebar).
        static let hoverPreviews = SettingKey(
            "tabHoverPreviewsEnabled", default: true, group: .tabs, configKey: "tab-hover-previews",
            title: String(localized: "Tab Hover Previews", comment: "Setting title"))
        /// Whether hover alone is enough, or a hardware modifier must also be held.
        static let hoverPreviewActivation = SettingKey(
            "tabHoverPreviewActivation", default: TabHoverPreviewActivation.shift, group: .tabs,
            configKey: "tab-hover-preview-activation",
            title: String(localized: "Tab Hover Preview Activation", comment: "Setting title"))
        /// Pinch-set hover preview scale; 1 = the default size.
        static let hoverPreviewZoom = SettingKey(
            "tabHoverPreviewZoom", default: 1.0, group: .tabs, policy: .localByDefault,
            configKey: "tab-hover-preview-zoom",
            title: String(localized: "Tab Hover Preview Size", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            newTabAction.erased, barHidden.erased, barAnimationsDisabled.erased, topTabStyle.erased, compactPillSpacing.erased,
            showScopeMenu.erased, showShortcutIndicators.erased, exposeShowsCaptions.erased, exposeZoom.erased,
            hoverPreviews.erased, hoverPreviewActivation.erased, hoverPreviewZoom.erased,
        ]
    }

    enum Sidebar {
        static let autoHideOnSelect = SettingKey(
            "tabSidebarAutoHideOnSelect", default: false, group: .sidebar, configKey: "tab-sidebar-auto-hide-on-select",
            title: String(localized: "Auto-Hide Sidebar After Selection", comment: "Setting title"))
        static let rowLines = SettingKey(
            "tabSidebarRowLines", default: 1, group: .sidebar, configKey: "tab-sidebar-row-lines",
            title: String(localized: "Sidebar Title Lines", comment: "Setting title"))
        static let largeControls = SettingKey(
            "tabSidebarLargeControls", default: SettingsPlatform.isPhone, group: .sidebar, policy: .localByDefault,
            configKey: "tab-sidebar-large-controls",
            title: String(localized: "Large Sidebar Controls", comment: "Setting title"))
        static let pinned = SettingKey(
            "tabSidebarPinned", default: false, group: .sidebar, policy: .localByDefault,
            configKey: "tab-sidebar-pinned",
            title: String(localized: "Pin Tab Sidebar", comment: "Setting title"))
        static let translucent = SettingKey(
            "tabSidebarTranslucent", default: true, group: .transparency, policy: .localByDefault,
            configKey: "tab-sidebar-translucent",
            title: String(localized: "Translucent Tab Sidebar", comment: "Setting title"))
        static let dockedWidth = SettingKey(
            "tabSidebar.docked.width", default: 420.0, group: .sidebar, policy: .deviceOnly,
            title: String(localized: "Docked Sidebar Width", comment: "Setting title"))
        static let collapsedGateways = SettingKey(
            "tabSidebarCollapsedGateways", default: [String](), group: .sidebar, policy: .deviceOnly,
            title: String(localized: "Collapsed Gateway Groups", comment: "Setting title"))
        static let collapsedGroups = SettingKey(
            "tabSidebarCollapsedGroups", default: [String](), group: .sidebar, policy: .deviceOnly,
            title: String(localized: "Collapsed Tab Groups", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            autoHideOnSelect.erased, rowLines.erased, largeControls.erased, pinned.erased, translucent.erased,
            dockedWidth.erased, collapsedGateways.erased, collapsedGroups.erased,
        ]
    }

    enum Window {
        static let hideTitleBar = SettingKey(
            "hideWindowTitleBar", default: false, group: .window, policy: .localByDefault,
            configKey: "hide-window-title-bar",
            title: String(localized: "Hide Title Bar", comment: "Setting title"))
        static let tabsInTitlebar = SettingKey(
            "tabsInTitlebarEnabled", default: true, group: .window, policy: .localByDefault,
            configKey: "tabs-in-titlebar-enabled",
            title: String(localized: "Tabs in Title Bar", comment: "Setting title"))
        static let fullScreenMode = SettingKey(
            "fullScreenModeEnabled", default: false, group: .window, policy: .localByDefault,
            configKey: "full-screen-mode-enabled",
            title: String(localized: "Full Screen Mode", comment: "Setting title"))
        static let extendUnderHomeIndicator = SettingKey(
            "extendUnderHomeIndicator", default: false, group: .window, policy: .localByDefault,
            configKey: "extend-under-home-indicator",
            title: String(localized: "Extend Under Home Indicator", comment: "Setting title"))
        static let splitFocusBorderStyle = SettingKey(
            "splitFocusBorderStyle", default: SplitFocusBorderStyle.standard, group: .window,
            configKey: "split-focus-border-style",
            title: String(localized: "Split Focus Border", comment: "Setting title"))
        static let splitFocusBorderColor = SettingKey(
            "splitFocusBorderColor", default: SplitFocusBorderColor.accent, group: .window,
            configKey: "split-focus-border-color",
            title: String(localized: "Split Border Color", comment: "Setting title"))
        static let splitFocusBorderCustomColor = SettingKey(
            "splitFocusBorderCustomColor", default: "007AFF", group: .window,
            configKey: "split-focus-border-custom-color",
            title: String(localized: "Split Border Custom Color", comment: "Setting title"))
        static let lastWidth = SettingKey(
            "lastWindowWidth", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Width", comment: "Setting title"))
        static let lastHeight = SettingKey(
            "lastWindowHeight", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Height", comment: "Setting title"))
        static let lastOriginX = SettingKey(
            "lastWindowOriginX", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Origin X", comment: "Setting title"))
        static let lastOriginY = SettingKey(
            "lastWindowOriginY", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Origin Y", comment: "Setting title"))
        static let lastHasOrigin = SettingKey(
            "lastWindowHasOrigin", default: false, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Has Origin", comment: "Setting title"))
        static let titlebarLeadingInset = SettingKey(
            "titlebarLeadingInset", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Titlebar Leading Inset", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            hideTitleBar.erased, tabsInTitlebar.erased, fullScreenMode.erased, extendUnderHomeIndicator.erased,
            splitFocusBorderStyle.erased, splitFocusBorderColor.erased, splitFocusBorderCustomColor.erased,
            lastWidth.erased, lastHeight.erased, lastOriginX.erased, lastOriginY.erased, lastHasOrigin.erased,
            titlebarLeadingInset.erased,
        ]
    }

    enum Power {
        static let autoSaver = SettingKey(
            "powerAutoSaver", default: true, group: .power, policy: .localByDefault,
            configKey: "power-auto-saver",
            title: String(localized: "Automatic Battery Saver", comment: "Setting title"))
        static let maxRefreshRate = SettingKey(
            "powerMaxRefreshRate", default: PowerManager.RefreshRateSetting.auto, group: .power, policy: .localByDefault,
            configKey: "power-max-refresh-rate",
            title: String(localized: "Maximum Refresh Rate", comment: "Setting title"))
        static let batteryRefreshRate = SettingKey(
            "powerBatteryRefreshRate", default: PowerManager.BatteryRefreshRate.sixty, group: .power, policy: .localByDefault,
            configKey: "power-battery-refresh-rate",
            title: String(localized: "Refresh Rate on Battery", comment: "Setting title"))
        static let alwaysOnDisplayMinutes = SettingKey(
            "alwaysOnDisplayMinutes", default: 0, group: .power, policy: .localByDefault,
            configKey: "always-on-display-minutes",
            title: String(localized: "Always On Display", comment: "Setting title"))
        static let alwaysOnDisplayEnabledLegacy = SettingKey(
            "alwaysOnDisplayEnabled", default: false, group: .power, policy: .deviceOnly,
            title: String(localized: "Always On Display (legacy)", comment: "Setting title"))
        static let brightnessGain = SettingKey(
            "brightnessGain", default: 1.0, group: .power, policy: .localByDefault,
            configKey: "brightness-gain",
            title: String(localized: "Brightness Boost", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            autoSaver.erased, maxRefreshRate.erased, batteryRefreshRate.erased,
            alwaysOnDisplayMinutes.erased, alwaysOnDisplayEnabledLegacy.erased, brightnessGain.erased,
        ]
    }
}
