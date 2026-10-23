//
//  SessionActivityAttributes.swift
//  rootshell
//
//  ActivityAttributes model for the Live Activity showing active non-resilient sessions.
//  Shared between the main app and the SessionActivityWidget extension.
//

import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

nonisolated struct SessionActivityAttributes: ActivityAttributes, Sendable {
    /// Static context — empty since all data is dynamic
    struct ContentState: Codable, Hashable, Sendable {
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

        /// Total detected coding-agent sessions.
        var agentTotalCount: Int { agentWorkingCount + agentAttentionCount + agentIdleCount }

        // MARK: - App Icon

        /// User-selected app icon variant (raw value of `AppIconVariant`).
        /// Empty string = primary icon. Default preserves source compatibility
        /// with existing call sites that don't set this field.
        var appIconVariant: String = ""

        // MARK: - Agent Inbox (no message text)

        /// Unread agent events, newest first, capped at the Lock Screen row
        /// limit. **The type carries no title and no body** — option A of the
        /// Live Activity privacy decision: `content-state` is plaintext and
        /// the widget extension renders it without passing through the
        /// Notification Service Extension, so message text must never enter
        /// it. `AgentInboxItem` has no field that could hold one.
        var agentItems: [AgentInboxItem] = []

        /// Total unread agent events. Can exceed `agentItems.count` (the
        /// array is capped); the expanded island folds the difference into a
        /// single "N more" row.
        var agentUnreadTotal: Int = 0

        /// Unread events by status, counted before `agentItems` is capped. The
        /// island and the inbox must agree on how many "needs you" and "failed"
        /// rows there are even when the carried array cannot hold them all.
        var agentInboxBlockedCount: Int = 0
        var agentInboxFailedCount: Int = 0
        var agentInboxDoneCount: Int = 0

        /// How the island draws the inbox: `AgentInboxIslandLayout` raw value.
        /// Empty = no inbox content at all.
        var agentInboxLayout: String = ""

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
    /// Rows the expanded Dynamic Island shows before folding.
    ///
    /// Height budget: header 20 + 3 × 34 + footer 22 ≈ 144pt, inside the
    /// 84–160pt expanded range. Never raise this without
    /// redoing that arithmetic — the island cannot scroll.
    static let expandedAgentItemLimit = 3

    /// Rows the Lock Screen banner shows. The banner is a full 160pt card, so
    /// it can afford two more than the island.
    static let lockScreenAgentItemLimit = 5

    /// Unread total, floored at what is actually carried so the badge can
    /// never disagree with the list it labels.
    var agentUnreadCount: Int { max(agentUnreadTotal, agentItems.count) }

    var hasAgentInbox: Bool { agentUnreadCount > 0 }

    /// The island is the inbox (the Inbox setting, with something unread).
    var usesInboxLayout: Bool {
        agentInboxLayout == AgentInboxIslandLayout.inbox.rawValue && hasAgentInbox
    }

    /// The session island carries an unread count (the Unread Count setting).
    var showsInboxBadge: Bool {
        agentInboxLayout == AgentInboxIslandLayout.badge.rawValue && hasAgentInbox
    }

    /// Most recently received event — drives compact leading/most recent tap.
    var agentInboxMostRecent: AgentInboxItem? { agentItems.first }

    var agentInboxExpandedItems: [AgentInboxItem] {
        Array(agentItems.prefix(Self.expandedAgentItemLimit))
    }

    /// Lock Screen rows. One line is held back for the fold row when there is
    /// overflow, so the card never grows past five lines.
    var agentInboxLockScreenRows: [AgentInboxItem] {
        let limit = agentUnreadCount > Self.lockScreenAgentItemLimit
            ? Self.lockScreenAgentItemLimit - 1
            : Self.lockScreenAgentItemLimit
        return Array(agentItems.prefix(limit))
    }

    /// Events the Lock Screen could not draw.
    var agentInboxLockScreenFoldedCount: Int {
        max(0, agentUnreadCount - agentInboxLockScreenRows.count)
    }

    /// Events that did not fit on the island — the "N more" row.
    var agentInboxFoldedCount: Int {
        max(0, agentUnreadCount - Self.expandedAgentItemLimit)
    }

    /// Distinct agents among the carried rows, for the expanded header.
    var agentInboxAgentCount: Int { Set(agentItems.map(\.agent)).count }

    /// True when any carried event is waiting on the user.
    var agentInboxHasBlocked: Bool { agentInboxBlockedUnreadCount > 0 }

    /// Exact unread blocked/failed counts. The wire fields are authoritative
    /// when present; older activities (written before the fields existed) fall
    /// back to the rows they did carry.
    var agentInboxBlockedUnreadCount: Int {
        if agentInboxBlockedCount > 0 { return agentInboxBlockedCount }
        return agentItems.lazy.filter { AgentInboxStatus(raw: $0.status) == .blocked }.count
    }

    var agentInboxFailedUnreadCount: Int {
        if agentInboxFailedCount > 0 { return agentInboxFailedCount }
        return agentItems.lazy.filter { AgentInboxStatus(raw: $0.status) == .failed }.count
    }

    var agentInboxDoneUnreadCount: Int {
        if agentInboxDoneCount > 0 { return agentInboxDoneCount }
        return agentItems.lazy.filter { AgentInboxStatus(raw: $0.status) == .done }.count
    }

    /// Failed events are a distinct section in the inbox, so the island tints
    /// for them separately from a blocked prompt.
    var agentInboxHasFailed: Bool { agentInboxFailedUnreadCount > 0 }
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
    init(from decoder: Decoder) throws {
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
        appIconVariant = try c.decodeIfPresent(String.self, forKey: .appIconVariant) ?? ""
        // A state written before the inbox existed has no rows and no total.
        // A malformed row must not take the whole activity down either: the
        // island is a glance surface, so drop what cannot be read and keep
        // the session/VPN fields that still decode.
        agentItems = (try? c.decodeIfPresent([AgentInboxItem].self, forKey: .agentItems)) ?? []
        agentUnreadTotal = try c.decodeIfPresent(Int.self, forKey: .agentUnreadTotal) ?? agentItems.count
        agentInboxBlockedCount = try c.decodeIfPresent(Int.self, forKey: .agentInboxBlockedCount) ?? 0
        agentInboxFailedCount = try c.decodeIfPresent(Int.self, forKey: .agentInboxFailedCount) ?? 0
        agentInboxDoneCount = try c.decodeIfPresent(Int.self, forKey: .agentInboxDoneCount) ?? 0
        agentInboxLayout = try c.decodeIfPresent(String.self, forKey: .agentInboxLayout) ?? ""
    }
}
#endif

// MARK: - Agent inbox types (every platform; the Catalyst inbox has no island)

/// One agent event on the island.
///
/// **Privacy option A, enforced by the type system:** there is no `title` and
/// no `body` here, and there must never be. The Live Activity `content-state`
/// is plaintext and is rendered by the widget extension directly — it does not
/// pass through the Notification Service Extension that decrypts pushes — so
/// anything in this struct is visible to anyone holding the phone and to
/// whatever produced the payload. The island answers "which agent, what state,
/// how long ago"; the message itself is only readable after tapping through.
nonisolated struct AgentInboxItem: Codable, Hashable, Sendable, Identifiable {
    /// Push event id (`eid`), used to dedupe a redelivered event.
    var id: String

    /// Manifest agent id (`claude`, `codex`, `pi`, …), not a display name.
    var agent: String

    /// Push status verbatim: `blocked` / `done` / `failed`.
    var status: String

    /// When the event arrived. Rows are ordered by this, newest first.
    var at: Date

    /// Pane to open on tap: `rootshell://pane/<surface-uuid>`.
    var deepLink: URL

    init(id: String, agent: String, status: String, at: Date, deepLink: URL) {
        self.id = id
        self.agent = agent
        self.status = status
        self.at = at
        self.deepLink = deepLink
    }
}

/// Presentation-only view of `AgentInboxItem.status`. Kept out of the wire
/// format so an unknown status from a newer relay degrades instead of failing
/// to decode.
nonisolated enum AgentInboxStatus: String, Sendable {
    case blocked
    case failed
    case done
    case other

    init(raw: String) {
        self = AgentInboxStatus(rawValue: raw) ?? .other
    }
}

/// How agent messages appear in the Live Activity. Off by default: the inbox
/// records history regardless, and the session island stays the session island.
nonisolated enum AgentInboxIslandLayout: String, CaseIterable, Codable, Sendable {
    case off
    /// The session island, plus an unread count.
    case badge
    /// The island becomes the inbox while anything is unread.
    case inbox
}

/// Hooks name agents however their CLI calls itself (`claude-code`,
/// `oh-my-pi`, `DSH`); the app's marks are keyed by manifest id.
nonisolated enum AgentInboxAgentID {
    static func manifestID(for agent: String) -> String {
        let key = agent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        if key.contains("oh-my-pi") || key == "omp" { return "omp" }
        if key.contains("claude") { return "claude" }
        if key.contains("codex") || key.contains("openai") { return "codex" }
        if key.contains("deepseek") || key == "dsh" { return "dsh" }
        if key.contains("hermes") { return "hermes" }
        if key.contains("copilot") { return "copilot" }
        if key.contains("cursor") { return "cursor" }
        if key.contains("opencode") { return "opencode" }
        if key.contains("antigravity") { return "agy" }
        if key == "pi" || key.hasPrefix("pi-") { return "pi" }
        return key
    }
}

/// Where a tap on the island, or on a row with no resolvable pane, lands.
nonisolated enum AgentInboxLinks {
    static let inbox = URL(string: "rootshell://inbox")!

    /// One event: opened through its stored push route, which survives
    /// tmux/herdr re-projecting the pane under a new surface id.
    static func item(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "rootshell"
        components.host = "inbox"
        components.queryItems = [URLQueryItem(name: "event", value: id)]
        return components.url ?? inbox
    }
}

/// App-group marker written by the island's "mark all read" intent.
///
/// The intent runs in the widget extension and cannot reach the app's inbox;
/// events at or before this time count as read.
nonisolated enum AgentInboxReadMarker {
    private static let key = "live_activity_agent_inbox_read_at"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppIdentifiers.defaultAppGroupID)
    }

    static func markRead(at date: Date = Date()) {
        defaults?.set(date.timeIntervalSince1970, forKey: key)
    }

    static func lastReadAt() -> Date? {
        guard let interval = defaults?.object(forKey: key) as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
