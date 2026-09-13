//
//  WindowState.swift
//  rootshell
//
//  Codable state models for window/tab persistence.
//  Used for state restoration on app relaunch.
//

import Foundation

/// Serializable state for a single terminal tab
nonisolated struct SerializableTab: Codable, Identifiable, Equatable, Sendable {
    /// Tab UUID (preserved for theme override matching)
    let id: UUID

    /// Tab display title
    var title: String

    /// Split tree structure with connection configs
    var splitTree: SerializableSplitTree

    /// UUID of the focused terminal within the split tree
    var focusedTerminalId: UUID?

    /// Window ID this tab belongs to
    let windowId: String

    /// For a projected tmux -CC control-mode WINDOW tab: the tmux window id this
    /// tab models. Non-nil marks this `SerializableTab` as a tmux-window
    /// placeholder — its `splitTree` is empty (the panes are live-only, bound to
    /// the viewer) and it is restored as an `awaitingTmuxReconcile` placeholder
    /// at its saved position. When the owning gateway resumes, the controller
    /// adopts it by matching this id. Nil for ordinary tabs (incl. the gateway).
    let tmuxWindowId: Int?

    /// For a tmux-window placeholder: the UUID of the gateway terminal (the one
    /// running `tmux -CC`) that owns this window. The terminal UUID is stable
    /// across restore (unlike the tab UUID), so the controller matches
    /// placeholders to its gateway by this id. Nil for ordinary tabs.
    let owningGatewayTerminalUUID: UUID?

    /// Absolute per-window font size override for projected tmux window tabs.
    /// Nil means the tmux window follows the global font.
    let tmuxFontSizeOverride: Double?

    /// For a tmux-window placeholder: whether the window was HIDDEN when the
    /// state was saved, so the restored placeholder never flashes visible.
    /// Optional so saves from older versions decode as nil (= visible).
    /// (id=tmux-hidden-windows)
    let isHiddenTmuxWindow: Bool?

    /// Creates a new serializable tab
    init(
        id: UUID,
        title: String,
        splitTree: SerializableSplitTree,
        focusedTerminalId: UUID?,
        windowId: String,
        tmuxWindowId: Int? = nil,
        owningGatewayTerminalUUID: UUID? = nil,
        tmuxFontSizeOverride: Double? = nil,
        isHiddenTmuxWindow: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.splitTree = splitTree
        self.focusedTerminalId = focusedTerminalId
        self.windowId = windowId
        self.tmuxWindowId = tmuxWindowId
        self.owningGatewayTerminalUUID = owningGatewayTerminalUUID
        self.tmuxFontSizeOverride = tmuxFontSizeOverride
        self.isHiddenTmuxWindow = isHiddenTmuxWindow
    }

    /// Number of terminals in this tab
    var terminalCount: Int {
        splitTree.allTerminalIds.count
    }
}

/// Projected herdr tabs are rebuilt on attach. Their server tab ID and the
/// gateway terminal UUID survive that rebuild; the native tab UUID does not.
nonisolated struct SerializableHerdrSelection: Codable, Equatable, Sendable {
    let gatewayTerminalUUID: UUID
    let tabID: String
}

/// Serializable state for a window
nonisolated struct SerializableWindow: Codable, Identifiable, Equatable, Sendable {
    /// Window ID (from @SceneStorage)
    let id: String

    /// All tabs in this window
    var tabs: [SerializableTab]

    /// Index of the currently selected tab
    var selectedTabIndex: Int

    /// The selected herdr tab, with selectedTabIndex pointing at its gateway
    /// until that tab is projected again. Optional for older saved state.
    var herdrSelection: SerializableHerdrSelection?

    /// Window-level theme override (if any)
    var themeOverride: String?

    /// Tab-level theme overrides (keyed by tab UUID)
    var tabThemeOverrides: [UUID: String]

    /// Whether vertical-sidebar grouped mode was enabled for this window.
    var tabGroupingEnabled: Bool?

    /// Active group for top-tab-bar/navigation filtering.
    var activeTabGroupID: TabGroupID?

    /// User-forced group assignments keyed by tab UUID.
    var tabGroupOverrides: [UUID: TabGroupID]?

    /// User-defined vertical sidebar section order, stored as group raw values.
    var tabGroupOrder: [String]?

    /// Independent tab order inside each user group.
    var tabGroupTabOrders: [String: [UUID]]?

    /// Stable Coding Agent project-section and per-project tab orders.
    var projectGroupOrder: [ProjectGroupID]?
    var projectTabOrders: [ProjectGroupID: [UUID]]?

    /// Saved window frame in Mac Catalyst system coordinates (points). Stored as
    /// individual fields (not a CGRect) so this model stays Foundation-only.
    /// Optional so saves from versions without geometry decode as nil. Applied on
    /// restore by `MainView.applyRestoredWindowFrame`; keyed implicitly to this
    /// window because it travels with the window's tabs.
    var frameOriginX: Double?
    var frameOriginY: Double?
    var frameWidth: Double?
    var frameHeight: Double?

    /// Creates a new serializable window
    init(
        id: String,
        tabs: [SerializableTab],
        selectedTabIndex: Int,
        herdrSelection: SerializableHerdrSelection? = nil,
        themeOverride: String? = nil,
        tabThemeOverrides: [UUID: String] = [:],
        tabGroupingEnabled: Bool? = nil,
        activeTabGroupID: TabGroupID? = nil,
        tabGroupOverrides: [UUID: TabGroupID]? = nil,
        tabGroupOrder: [String]? = nil,
        tabGroupTabOrders: [String: [UUID]]? = nil,
        projectGroupOrder: [ProjectGroupID]? = nil,
        projectTabOrders: [ProjectGroupID: [UUID]]? = nil,
        frameOriginX: Double? = nil,
        frameOriginY: Double? = nil,
        frameWidth: Double? = nil,
        frameHeight: Double? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.herdrSelection = herdrSelection
        self.themeOverride = themeOverride
        self.tabThemeOverrides = tabThemeOverrides
        self.tabGroupingEnabled = tabGroupingEnabled
        self.activeTabGroupID = activeTabGroupID
        self.tabGroupOverrides = tabGroupOverrides
        self.tabGroupOrder = tabGroupOrder
        self.tabGroupTabOrders = tabGroupTabOrders
        self.projectGroupOrder = projectGroupOrder
        self.projectTabOrders = projectTabOrders
        self.frameOriginX = frameOriginX
        self.frameOriginY = frameOriginY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    /// Total number of terminals across all tabs
    var totalTerminalCount: Int {
        tabs.reduce(0) { $0 + $1.terminalCount }
    }

    /// Number of tabs that need password entry
    var tabsNeedingPassword: Int {
        tabs.filter { tab in
            tab.splitTree.allLeaves.contains { $0.connectionConfig.needsUserInput }
        }.count
    }
}

/// Root state containing all windows
nonisolated struct AppWindowState: Codable, Equatable, Sendable {
    /// Current version of the state format (for migration support)
    static let currentVersion = 1

    /// Version of this state (for backwards compatibility)
    let version: Int

    /// When this state was saved
    let savedAt: Date

    /// All window states
    var windows: [SerializableWindow]

    /// Creates a new app window state
    init(windows: [SerializableWindow]) {
        self.version = Self.currentVersion
        self.savedAt = Date()
        self.windows = windows
    }

    /// Total number of tabs across all windows
    var totalTabCount: Int {
        windows.reduce(0) { $0 + $1.tabs.count }
    }

    /// Total number of terminals across all windows
    var totalTerminalCount: Int {
        windows.reduce(0) { $0 + $1.totalTerminalCount }
    }

    /// Number of tabs needing password across all windows
    var totalTabsNeedingPassword: Int {
        windows.reduce(0) { $0 + $1.tabsNeedingPassword }
    }

    /// Summary description for logging
    var summary: String {
        "\(windows.count) windows, \(totalTabCount) tabs, \(totalTerminalCount) terminals"
    }

    /// All terminal UUIDs across all windows and tabs
    var allTerminalIds: Set<UUID> {
        var ids = Set<UUID>()
        for window in windows {
            for tab in window.tabs {
                for terminalId in tab.splitTree.allTerminalIds {
                    ids.insert(terminalId)
                }
            }
        }
        return ids
    }
}

// MARK: - Restoration Errors

/// Errors that can occur during state restoration
enum StateRestorationError: LocalizedError, Equatable {
    /// State file is corrupt or unreadable
    case corruptState(String)

    /// State version is incompatible
    case versionMismatch(found: Int, expected: Int)

    /// State is too old
    case stateExpired(daysOld: Int)

    /// SSH key referenced in config no longer exists
    case sshKeyNotFound(UUID)

    /// Kubernetes cluster no longer exists
    case clusterNotFound(UUID)

    /// Cloud account no longer exists
    case cloudAccountNotFound(UUID)

    /// Connection failed during restoration
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .corruptState(let detail):
            return "Saved state is corrupt: \(detail)"
        case .versionMismatch(let found, let expected):
            return "State version \(found) is not compatible with version \(expected)"
        case .stateExpired(let days):
            return "Saved state is \(days) days old and has expired"
        case .sshKeyNotFound(let id):
            return "SSH key \(id.uuidString.prefix(8)) no longer exists"
        case .clusterNotFound(let id):
            return "Kubernetes cluster \(id.uuidString.prefix(8)) not found"
        case .cloudAccountNotFound(let id):
            return "Cloud account \(id.uuidString.prefix(8)) not found"
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .corruptState:
            return "Starting fresh. Your previous session could not be restored."
        case .versionMismatch:
            return "The app has been updated. Starting fresh."
        case .stateExpired:
            return "Sessions older than 7 days are not restored. Starting fresh."
        case .sshKeyNotFound:
            return "Import the SSH key again in Settings, or select a different key."
        case .clusterNotFound:
            return "Import the cluster kubeconfig in Settings > Kubernetes."
        case .cloudAccountNotFound:
            return "Re-authenticate with your cloud provider in Settings."
        case .connectionFailed:
            return "Check your network connection and try reconnecting."
        }
    }
}
