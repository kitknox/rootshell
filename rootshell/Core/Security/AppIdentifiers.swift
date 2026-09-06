//
//  AppIdentifiers.swift
//  rootshell
//
//  Identifiers that must track a contributor's own Apple Developer team and
//  org identifier (see Configuration/Identity.xcconfig). Each value is signed
//  into the bundle via an Info.plist key, so it stays in lockstep with the
//  entitlements the process actually holds.
//
//  Compiled into every target that needs it, including the extensions -- see
//  the membershipExceptions in project.pbxproj. The one target it can't reach
//  is rootshell-helper, whose source tree is separate; it carries its own
//  equivalent lookup.
//

import Foundation

nonisolated enum AppIdentifiers {
    /// The app group shared with the VPN extension, the widget, and the
    /// helper. Not region-specific: those targets sign against this group even
    /// in a China build, where the app and the push service use the
    /// `.cn`-suffixed `RootshellAppGroup` instead.
    static let defaultAppGroupID: String = plist("RootshellDefaultAppGroup") ?? "group.com.kk2.ghostty"

    static let keychainAccessGroup: String = plist("RootshellKeychainAccessGroup") ?? "D97ZME3ET2.com.kk2.ghostty-ios"

    static let iCloudContainerID: String = plist("RootshellICloudContainer") ?? "iCloud.rootshell"

    private static func plist(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
