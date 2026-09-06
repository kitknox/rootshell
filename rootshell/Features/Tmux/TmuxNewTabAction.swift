// Global New Tab preference. The file retains its historical location to
// preserve project source membership.
import Foundation

nonisolated enum NewTabAction: String, CaseIterable, Codable, Sendable {
    case localShell
    // The synced key is shared with older apps, which only understand tmuxTab.
    case duplicateFocused = "tmuxTab"
    case ask

    // Also accept the transitional spelling written by early global-setting
    // versions; rawValue/Codable/SettingValue always encode the legacy spelling.
    init?(rawValue: String) {
        switch rawValue {
        case "localShell": self = .localShell
        case "duplicateFocused", "tmuxTab": self = .duplicateFocused
        case "ask": self = .ask
        default: return nil
        }
    }

    static var current: NewTabAction {
        SettingsStore.shared.value(Settings.Tabs.newTabAction)
    }

    var displayName: String {
        switch self {
        case .localShell: return String(localized: "Local Shell")
        case .duplicateFocused: return String(localized: "Duplicate Focused")
        case .ask: return String(localized: "Ask Each Time")
        }
    }

    var detail: String {
        switch self {
        case .localShell:
            return String(localized: "Open a new local shell tab.")
        case .duplicateFocused:
            return String(localized: "Open another session matching the focused pane, or a new window in its tmux control-mode session.")
        case .ask:
            return String(localized: "Choose a local shell, duplicate the focused session, or open Connections each time.")
        }
    }

    var iconName: String {
        switch self {
        case .localShell: return "terminal"
        case .duplicateFocused: return "plus.rectangle.on.rectangle"
        case .ask: return "questionmark.circle"
        }
    }
}
