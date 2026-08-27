//
//  UserPreferences.swift
//  rootshell
//
//  User-configurable display name and clock format preferences
//

import Foundation

/// Visual treatment for the horizontal tab bar. Pills preserves the existing
/// Rootshell appearance; Integrated connects the selected tab to the terminal
/// and uses browser-style sizing and controls.
enum TopTabStyle: String, CaseIterable, Identifiable {
    case pills
    case integrated

    static let storageKey = "topTabStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pills: return String(localized: "Pills")
        case .integrated: return String(localized: "Integrated")
        }
    }

    static func resolve(_ rawValue: String) -> TopTabStyle {
        TopTabStyle(rawValue: rawValue) ?? .pills
    }
}

/// User-facing combinations of top-tab appearance and spacing. Persistence
/// remains split between `TopTabStyle` and the compact-pills boolean so the
/// rendering code can vary layout without changing the pill appearance.
enum TopTabLayout: String, CaseIterable, Identifiable {
    case pills
    case compactPills
    case integrated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pills: return String(localized: "Pills")
        case .compactPills: return String(localized: "Compact Pills")
        case .integrated: return String(localized: "Integrated")
        }
    }

    var style: TopTabStyle {
        switch self {
        case .pills, .compactPills: return .pills
        case .integrated: return .integrated
        }
    }

    var usesCompactPillSpacing: Bool { self == .compactPills }

    static func resolve(style: TopTabStyle, compactPills: Bool) -> TopTabLayout {
        switch style {
        case .integrated: return .integrated
        case .pills: return compactPills ? .compactPills : .pills
        }
    }
}

/// Namespace for user preferences that affect prompts and SSH defaults
nonisolated enum UserPreferences {

    // MARK: - Tab Bar

    static let showTabScopeMenuKey = "showTabScopeMenu"
    static let compactPillTabSpacingKey = "compactPillTabSpacing"

    // MARK: - Text Selection

    static let useNativeSelectionLoupeKey = "useNativeSelectionLoupe"

    /// Custom is the default; the system loupe is an explicit iOS/iPadOS opt-in.
    static var useNativeSelectionLoupe: Bool {
        get { UserDefaults.standard.bool(forKey: useNativeSelectionLoupeKey) }
        set { UserDefaults.standard.set(newValue, forKey: useNativeSelectionLoupeKey) }
    }

    // MARK: - Background Keepalive

    static let backgroundSessionKeepaliveEnabledKey = "backgroundSessionKeepaliveEnabled"

    /// Whether eligible TCP SSH sessions, active local tasks and live Screen
    /// Sharing panes should request a short UIKit background grace task when
    /// the app backgrounds.
    static var backgroundSessionKeepaliveEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: backgroundSessionKeepaliveEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: backgroundSessionKeepaliveEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: backgroundSessionKeepaliveEnabledKey)
        }
    }

    // MARK: - Username

    private static let customUsernameKey = "customUsername"

    /// Returns the custom username if set, otherwise falls back to NSUserName()
    static var effectiveUsername: String {
        if let custom = UserDefaults.standard.string(forKey: customUsernameKey),
           !custom.isEmpty {
            return custom
        }
        return NSUserName()
    }

    // MARK: - Clock Format

    /// Clock display format for prompt themes
    enum ClockFormat: String, CaseIterable {
        case system = "system"
        case twelveHour = "twelveHour"
        case twentyFourHour = "twentyFourHour"

        var displayName: String {
            switch self {
            case .system: return String(localized: "System Default", comment: "Clock format: system default")
            case .twelveHour: return String(localized: "12-Hour", comment: "Clock format: 12-hour")
            case .twentyFourHour: return String(localized: "24-Hour", comment: "Clock format: 24-hour")
            }
        }
    }

    private static let clockFormatKey = "clockFormat"

    /// Current clock format preference
    static var clockFormat: ClockFormat {
        get {
            guard let raw = UserDefaults.standard.string(forKey: clockFormatKey),
                  let format = ClockFormat(rawValue: raw) else {
                return .system
            }
            return format
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: clockFormatKey)
        }
    }

    /// Formats current time according to the user's clock format preference
    static func formattedTime() -> String {
        let formatter = DateFormatter()
        switch clockFormat {
        case .system:
            formatter.timeStyle = .short
        case .twelveHour:
            formatter.dateFormat = "h:mm a"
        case .twentyFourHour:
            formatter.dateFormat = "HH:mm"
        }
        return formatter.string(from: Date())
    }
}
