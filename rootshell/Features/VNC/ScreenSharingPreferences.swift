//
//  ScreenSharingPreferences.swift
//  rootshell
//
//  Global defaults for newly created Screen Sharing panes.
//

import Foundation

enum ScreenSharingClipboardSyncDefault: String, CaseIterable, Sendable {
    case automatic
    case off
    case alwaysOn

    static let storageKey = "screenSharingClipboardSyncDefault"
    static let defaultValue = Self.automatic

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.clipboardSyncDefault)
    }

    var displayName: String {
        switch self {
        case .automatic:
            return String(localized: "Auto", comment: "Screen Sharing clipboard sync default")
        case .off:
            return String(localized: "Off", comment: "Screen Sharing clipboard sync default")
        case .alwaysOn:
            return String(localized: "Always On", comment: "Screen Sharing clipboard sync default")
        }
    }
}

enum ScreenSharingPanningDefault: String, CaseIterable, Sendable {
    case edge
    case continuous

    static let storageKey = "screenSharingPanningDefault"
    static let defaultValue = Self.edge

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.panningDefault)
    }

    var displayName: String {
        switch self {
        case .edge:
            return String(
                localized: "When Pointer Reaches Edge",
                comment: "Screen Sharing panning default"
            )
        case .continuous:
            return String(
                localized: "Continuously with Pointer",
                comment: "Screen Sharing panning default"
            )
        }
    }
}

enum ScreenSharingCursorSizeDefault: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    static let storageKey = "screenSharingCursorSizeDefault"
    static let defaultValue = Self.medium

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.cursorSizeDefault)
    }

    /// Visible height of the drawn arrow, in view points. Medium is the
    /// macOS pointer's own 1x height, rounded from 17.2, so the default
    /// matches what the remote screen shows rather than approximating it.
    var points: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 17
        case .large: return 23
        }
    }

    var displayName: String {
        switch self {
        case .small:
            return String(
                localized: "Small",
                comment: "Screen Sharing cursor size default"
            )
        case .medium:
            return String(
                localized: "Medium (macOS)",
                comment: "Screen Sharing cursor size default"
            )
        case .large:
            return String(
                localized: "Large",
                comment: "Screen Sharing cursor size default"
            )
        }
    }
}

enum ScreenSharingCursorRenderingDefault: String, CaseIterable, Sendable {
    case local
    case remote

    static let storageKey = "screenSharingCursorRenderingDefault"
    static let defaultValue = Self.local

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.cursorRenderingDefault)
    }

    var displayName: String {
        switch self {
        case .local:
            return String(
                localized: "Local",
                comment: "Screen Sharing cursor rendering default"
            )
        case .remote:
            return String(
                localized: "Remote",
                comment: "Screen Sharing cursor rendering default"
            )
        }
    }
}

enum ScreenSharingPointerModeDefault: String, CaseIterable, Sendable {
    case direct
    case trackpad

    static let storageKey = "screenSharingPointerModeDefault"
    static let defaultValue = Self.direct

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.pointerModeDefault)
    }

    var displayName: String {
        switch self {
        case .direct:
            return String(
                localized: "Touch",
                comment: "Screen Sharing pointer mode default"
            )
        case .trackpad:
            return String(
                localized: "Trackpad",
                comment: "Screen Sharing pointer mode default"
            )
        }
    }
}

enum ScreenSharingExternalDisplayMode: String, CaseIterable, Sendable {
    case mirror
    case remoteDesktop

    static let storageKey = "screenSharingExternalDisplayMode"
    static let defaultValue = Self.remoteDesktop

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.externalDisplayMode)
    }

    var displayName: String {
        switch self {
        case .mirror:
            return String(
                localized: "Mirror This Device",
                comment: "Screen Sharing external display mode")
        case .remoteDesktop:
            return String(
                localized: "Remote Desktop",
                comment: "Screen Sharing external display mode")
        }
    }
}

/// How large the remote desktop looks on an external display. Larger steps
/// ask the Mac for a smaller virtual display: bigger text and pointer, and
/// fewer pixels to encode and send.
enum ScreenSharingExternalDisplayScale: String, CaseIterable, Sendable {
    case standard
    case larger
    case largest

    static let storageKey = "screenSharingExternalDisplayScale"
    static let defaultValue = Self.standard

    static var current: Self {
        SettingsStore.shared.value(Settings.ScreenSharing.externalDisplayScale)
    }

    var factor: CGFloat {
        switch self {
        case .standard: return 1
        case .larger: return 1.25
        case .largest: return 1.5
        }
    }

    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "Default", comment: "Screen Sharing external display scale")
        case .larger:
            return String(localized: "Larger", comment: "Screen Sharing external display scale")
        case .largest:
            return String(localized: "Largest", comment: "Screen Sharing external display scale")
        }
    }
}
