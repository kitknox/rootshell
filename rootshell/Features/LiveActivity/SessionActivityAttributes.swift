//
//  SessionActivityAttributes.swift
//  rootshell
//
//  ActivityAttributes model for the Live Activity showing active non-resilient sessions.
//  Shared between the main app and the SessionActivityWidget extension.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

// Plain data shared by the app, the widget and the notification service
// extension, which reads and updates it off the main actor.
nonisolated struct SessionActivityAttributes: ActivityAttributes {
    /// Static context — empty since all data is dynamic
    nonisolated struct ContentState: Codable, Hashable {
        /// Total non-resilient session count
        var sessionCount: Int

        /// Per-type breakdown
        var sshCount: Int
        var k8sCount: Int
        var consoleCount: Int

        /// Host names for display (up to 3)
        var hostNames: [String]

        /// Local shells with active long-running tasks (vim, helix, sftp, etc.)
        var localTaskCount: Int = 0

        /// Roam sessions (Mosh, trzsz) — resilient UDP connections
        var roamCount: Int = 0

        /// Host names for roam sessions (up to 3)
        var roamHostNames: [String] = []

        /// Timestamp for elapsed timer display
        var lastUpdated: Date

        // MARK: - VPN State (nil = no VPN active)

        var vpnProfileName: String?
        var vpnHost: String?
        var vpnBytesIn: Int64?
        var vpnBytesOut: Int64?
        var vpnActiveConnections: Int?
        var vpnConnectedSince: Date?
        var vpnStatus: String?  // "connected", "connecting", "reconnecting"

        // MARK: - WiFi State (nil = disabled or unavailable)

        var wifiSSID: String?
        var wifiAPName: String?         // matched AP name or vendor name
        var wifiAPDetail: String?       // AP model shortname or site name
        var wifiBand: String?           // "6 GHz", "5 GHz", "2.4 GHz"

        // MARK: - Network/ISP State (nil = disabled or unavailable)

        var networkPublicIP: String?    // primary public IPv4
        var networkASName: String?      // ISP/AS org name (e.g. "Comcast Cable")
        var networkCountryFlag: String? // "US 🇺🇸"
        var networkType: String?        // "WiFi", "Cellular", etc.

        // MARK: - Coding Agents (0 = disabled or none detected)

        /// Detected coding-agent sessions still running.
        var agentWorkingCount: Int = 0

        /// Detected coding-agent sessions that need the user: blocked on a
        /// prompt, failed, or finished and not yet looked at.
        var agentAttentionCount: Int = 0

        /// Detected coding-agent sessions sitting idle or paused.
        var agentIdleCount: Int = 0

        /// True once the app has left the foreground. Agent detection stops
        /// there, so the counts above are a snapshot until the next
        /// foreground publish clears this. Widget-side updaters copy the
        /// state and must leave it untouched.
        var agentCountsFrozen: Bool = false

        /// Set by the notification service extension when an agent hook push
        /// moved a pane to "needs attention" while the counts were frozen.
        /// Nil once the app publishes from live detection again.
        var agentPushUpdatedAt: Date? = nil

        /// Total detected coding-agent sessions.
        var agentTotalCount: Int { agentWorkingCount + agentAttentionCount + agentIdleCount }

        /// Frozen counts nobody has refreshed render muted; counts a push has
        /// touched are current for what matters and keep their colors.
        var agentCountsMuted: Bool { agentCountsFrozen && agentPushUpdatedAt == nil }

        // MARK: - App Icon

        /// User-selected app icon variant (raw value of `AppIconVariant`).
        /// Empty string = primary icon. Default preserves source compatibility
        /// with existing call sites that don't set this field.
        var appIconVariant: String = ""

        /// Asset name for the widget's composed display PNG matching
        /// `appIconVariant`. Mirrors `AppIconManager.AppIconVariant.previewAssetName`.
        /// The widget's asset catalog carries copies of these imagesets so
        /// the widget doesn't depend on the main-app bundle.
        var appIconDisplayAssetName: String {
            switch appIconVariant {
            case "AppIconBlack":         return "AppIconBlackPreview"
            case "AppIconCRT":           return "AppIconCRTPreview"
            case "AppIconNoBorder":      return "AppIconNoBorderPreview"
            case "AppIconUnderscore":    return "AppIconUnderscorePreview"
            case "AppIconSixColors":     return "AppIconSixColorsPreview"
            case "AppIconSixColorsDark": return "AppIconSixColorsDarkPreview"
            case "AppIconOrig":          return "AppIconOrigPreview"
            case "AppIconRadicalSolarizedDark",
                 "AppIconRadicalSolarizedLight",
                 "AppIconRadicalDracula",
                 "AppIconRadicalNord",
                 "AppIconRadicalGruvboxDark",
                 "AppIconRadicalTokyoNight",
                 "AppIconRadicalCatppuccin",
                 "AppIconRadicalBases",
                 "AppIconRadicalMonoLight",
                 "AppIconRadicalMonokai",
                 "AppIconRadicalMonoDark",
                 "AppIconRadicalRosePine":
                return appIconVariant
            default:                     return "AppIconPreview"
            }
        }
    }
}

extension SessionActivityAttributes.ContentState {
    /// Tolerant decoding for states written by an older app version.
    ///
    /// The manager adopts an orphaned activity from the previous launch and
    /// reads its `content.state` back; synthesized `Codable` would throw on a
    /// key the previous version never wrote, even for a property declared
    /// with a default. Every field added after the first release is decoded
    /// with `decodeIfPresent` here. Lives in an extension so the memberwise
    /// initializer stays available; encoding stays synthesized.
    ///
    /// When adding a field: give it a default in the struct AND decode it
    /// here with `decodeIfPresent`.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        sshCount = try c.decode(Int.self, forKey: .sshCount)
        k8sCount = try c.decode(Int.self, forKey: .k8sCount)
        consoleCount = try c.decode(Int.self, forKey: .consoleCount)
        hostNames = try c.decode([String].self, forKey: .hostNames)
        localTaskCount = try c.decodeIfPresent(Int.self, forKey: .localTaskCount) ?? 0
        roamCount = try c.decodeIfPresent(Int.self, forKey: .roamCount) ?? 0
        roamHostNames = try c.decodeIfPresent([String].self, forKey: .roamHostNames) ?? []
        lastUpdated = try c.decode(Date.self, forKey: .lastUpdated)
        vpnProfileName = try c.decodeIfPresent(String.self, forKey: .vpnProfileName)
        vpnHost = try c.decodeIfPresent(String.self, forKey: .vpnHost)
        vpnBytesIn = try c.decodeIfPresent(Int64.self, forKey: .vpnBytesIn)
        vpnBytesOut = try c.decodeIfPresent(Int64.self, forKey: .vpnBytesOut)
        vpnActiveConnections = try c.decodeIfPresent(Int.self, forKey: .vpnActiveConnections)
        vpnConnectedSince = try c.decodeIfPresent(Date.self, forKey: .vpnConnectedSince)
        vpnStatus = try c.decodeIfPresent(String.self, forKey: .vpnStatus)
        wifiSSID = try c.decodeIfPresent(String.self, forKey: .wifiSSID)
        wifiAPName = try c.decodeIfPresent(String.self, forKey: .wifiAPName)
        wifiAPDetail = try c.decodeIfPresent(String.self, forKey: .wifiAPDetail)
        wifiBand = try c.decodeIfPresent(String.self, forKey: .wifiBand)
        networkPublicIP = try c.decodeIfPresent(String.self, forKey: .networkPublicIP)
        networkASName = try c.decodeIfPresent(String.self, forKey: .networkASName)
        networkCountryFlag = try c.decodeIfPresent(String.self, forKey: .networkCountryFlag)
        networkType = try c.decodeIfPresent(String.self, forKey: .networkType)
        agentWorkingCount = try c.decodeIfPresent(Int.self, forKey: .agentWorkingCount) ?? 0
        agentAttentionCount = try c.decodeIfPresent(Int.self, forKey: .agentAttentionCount) ?? 0
        agentIdleCount = try c.decodeIfPresent(Int.self, forKey: .agentIdleCount) ?? 0
        agentCountsFrozen = try c.decodeIfPresent(Bool.self, forKey: .agentCountsFrozen) ?? false
        agentPushUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .agentPushUpdatedAt)
        appIconVariant = try c.decodeIfPresent(String.self, forKey: .appIconVariant) ?? ""
    }
}
#endif
