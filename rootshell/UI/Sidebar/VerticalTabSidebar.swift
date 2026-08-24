//
//  VerticalTabSidebar.swift
//  rootshell
//
//  Vertical tab list shown in the left-side tab sidebar (replaces the old
//  bottom TabSwitcherPanel). tmux -CC gateways render as collapsible groups
//  with their projected window tabs indented beneath them; everything else
//  renders as flat rows in tab order. Selecting a tab keeps the sidebar
//  open (browser-style vertical tabs); dismissal is via the toggle
//  button/shortcut, Escape, or the backdrop.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Collapse State Persistence

/// Persists which gateway groups are collapsed, keyed by the gateway's
/// owner terminal UUID (stable across restore: it round-trips through
/// window persistence with the tmux placeholders).
@MainActor
enum TabSidebarCollapseStore {
    private static let key = "tabSidebarCollapsedGateways"

    static func load() -> Set<UUID> {
        guard let strings = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    /// Saves the collapsed set, pruning gateways that no longer exist so the
    /// stored list cannot grow without bound. Resumable gateways survive app
    /// restarts as placeholder tabs, so they are still "known" here.
    static func save(_ collapsed: Set<UUID>, knownGateways: Set<UUID>) {
        let pruned = collapsed.intersection(knownGateways)
        UserDefaults.standard.set(pruned.map(\.uuidString).sorted(), forKey: key)
    }
}

enum TabSidebarGroupCollapseStore {
    private static let key = "tabSidebarCollapsedGroups"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ collapsed: Set<String>, knownGroups: Set<String>) {
        let pruned = collapsed.intersection(knownGroups)
        UserDefaults.standard.set(pruned.sorted(), forKey: key)
    }
}

enum TabSidebarGroupOrderStore {
    private static let keyPrefix = "tabSidebarGroupOrder."

    private static func key(for windowId: String) -> String {
        keyPrefix + windowId
    }

    static func load(windowId: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: windowId)) ?? []
    }

    static func save(_ order: [String], windowId: String) {
        UserDefaults.standard.set(order, forKey: key(for: windowId))
    }
}

private struct TabGroupHeaderIcon: View {
    let groupID: TabGroupID
    let fallbackSystemImage: String
    let size: CGFloat
    let tint: Color

    @State private var favicon: UIImage?

    var body: some View {
        Group {
            if let favicon {
                Image(uiImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: size, height: size)
        .task(id: groupID.rawValue) {
            favicon = nil
            guard let domain = faviconDomain(for: groupID) else { return }
            if let cached = FaviconManager.shared.cachedFavicon(for: domain),
               let image = UIImage(data: cached) {
                favicon = image
                return
            }
            if let data = await FaviconManager.shared.favicon(for: domain),
               let image = UIImage(data: data) {
                favicon = image
            }
        }
    }

    private func faviconDomain(for groupID: TabGroupID) -> String? {
        switch groupID.kind {
        case .remoteDomain, .remoteHost:
            return domainCandidate(groupID.value)
        case .local, .remoteNetwork, .tmux, .other:
            return nil
        }
    }

    private func domainCandidate(_ value: String) -> String? {
        let host = TabGroupID.normalizeHost(value)
        guard host.contains("."),
              !host.hasSuffix(".local"),
              !host.contains(":"),
              TabGroupID.ipNetworkGroup(for: host) == nil,
              let domain = FaviconFetcher.extractDomain(from: host),
              domain.contains(".") else { return nil }
        return domain
    }
}

// MARK: - Control Density

/// Every size in the sidebar derives from one of these two sets so the
/// density toggle flips the whole panel coherently.
///
/// Equatable so the row views can compare it in their own `==`: metrics are a
/// parent-supplied input, and a density or title-lines change must defeat the
/// equality short-circuit and repaint every row.
struct SidebarMetrics: Equatable {
    /// How many lines each tab title may wrap to (uniform across rows so the
    /// list stays symmetric). Section headers ignore this.
    var titleLineLimit: Int = 1

    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let hintSize: CGFloat
    let headerButtonTarget: CGFloat
    let headerIconSize: CGFloat
    let rowButtonTarget: CGFloat
    let rowIconSize: CGFloat
    let closeIconSize: CGFloat
    let searchBarHeight: CGFloat
    let searchFieldHeight: CGFloat
    let searchFontSize: CGFloat

    static let compact = SidebarMetrics(
        rowHeight: 44,
        rowSpacing: 2,
        titleSize: 14,
        subtitleSize: 11,
        hintSize: 12,
        headerButtonTarget: 28,
        headerIconSize: 14,
        rowButtonTarget: 24,
        rowIconSize: 12,
        closeIconSize: 10,
        searchBarHeight: 32,
        searchFieldHeight: 20,
        searchFontSize: 14
    )

    static let large = SidebarMetrics(
        rowHeight: 56,
        rowSpacing: 4,
        titleSize: 17,
        subtitleSize: 13,
        hintSize: 14,
        headerButtonTarget: 44,
        headerIconSize: 17,
        rowButtonTarget: 40,
        rowIconSize: 15,
        closeIconSize: 13,
        searchBarHeight: 44,
        searchFieldHeight: 24,
        searchFontSize: 17
    )

    /// Tab-row height: the base height plus one title line-height per extra
    /// line, so a multi-line title fits without per-row dynamic sizing.
    var tabRowHeight: CGFloat {
        rowHeight + CGFloat(titleLineLimit - 1) * ceil(UIFont.systemFont(ofSize: titleSize).lineHeight)
    }

    /// Clamped so a stray UserDefaults value can't blow up the layout.
    func withTitleLines(_ lines: Int) -> SidebarMetrics {
        var copy = self
        copy.titleLineLimit = min(max(lines, 1), 3)
        return copy
    }

    /// Agent-card row height: the tab row plus a status line above and a
    /// context line below (subtitle-sized, 2pt spacing each).
    var agentCardRowHeight: CGFloat {
        tabRowHeight + 2 * (ceil(UIFont.systemFont(ofSize: subtitleSize).lineHeight) + 2)
    }
}

// MARK: - Vertical Tab Sidebar

struct VerticalTabSidebar: View {
    let tabsModel: TabsModel
    let windowId: String
    @Binding var collapsedGateways: Set<UUID>
    /// Whether selecting a tab leaves the sidebar on screen (iPad/Catalyst,
    /// browser-style) or closes it (phone/visionOS, where the panel covers the
    /// terminal). Provided synchronously by the parent so a post-tap focus
    /// re-anchor can be skipped when the tap will dismiss the panel — otherwise
    /// `requestSearchFocus()` would re-grab the off-screen field before the
    /// dismissal notification flips `isPanelVisible`.
    let staysOpenOnSelect: Bool
    /// Rendered as a docked left column (shrinks the terminal) rather than the
    /// floating overlay. Suppresses the floating-panel affordances: no
    /// swipe-down dismiss, no phone grab handle, and — critically — no
    /// auto-focus of the search field on appear (the terminal beside the
    /// docked column must keep the keyboard).
    let isDocked: Bool
    /// Docked only: bottom inset that keeps the column's content (tab rows,
    /// agent usage footer) clear of whatever occupies the window's bottom
    /// edge — the docked software keyboard, or the keyboard toolbar when the
    /// accessory docks there (hardware keyboard, toolbar-only mode, floating
    /// keyboard). The sidebar ignores the keyboard safe area so SwiftUI's
    /// avoidance can't fight the overlay-preservation machinery; the parent
    /// supplies the exact clearance instead, mirroring the terminal's own
    /// bottom padding (see MainView.dockedSidebarBottomClearance). 0 when
    /// floating or on other platforms.
    var dockedBottomClearance: CGFloat = 0
    /// Whether to show the pin button at all (iPad/Catalyst only).
    let canPin: Bool
    /// Current pinned state, for the button's icon/label.
    let isPinned: Bool
    /// Toggle docked ⇄ floating.
    let onTogglePin: () -> Void
    let onSelectTab: (UUID) -> Void
    /// Selects the containing tab and focuses one exact split pane.
    let onSelectPane: (UUID, UUID) -> Void
    let onCloseTab: (UUID) -> Void
    /// Live drag-reorder step for tmux WINDOW tabs: the gateway's window
    /// membership in its new order, plus the dragged tab. Slot-permutation
    /// semantics — unrelated tabs keep their raw indices
    /// (reorderTabsPreservingSlots). Local-only; the server commit happens
    /// once via `onReorderEnded`.
    let onReorderClass: ([UUID], UUID) -> Void
    /// Live drag-reorder step for regular (.local) tabs: a raw array move
    /// (from, to), matching the top tab bar — lets a regular tab cross tmux
    /// gateway groups. Wired to `moveTab(from:to:)`.
    let onMoveTab: (Int, Int) -> Void
    /// Drop finished: commit the dragged tab's final order (tmux
    /// move-window for window tabs; user gesture, never reconcile-driven).
    let onReorderEnded: (UUID) -> Void
    let onNewTab: () -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onNewTmuxWindow: (TabModel) -> Void
    let tmuxController: (TabModel) -> TmuxController?
    let onShowConnectionInfo: (TabModel) -> Void
    /// Predicate: should the "Transfer to Nearby Device" item appear in this
    /// tab's context menu? Evaluated lazily when the menu is presented.
    let canTransferToNearby: (TabModel) -> Bool
    let onTransferToNearby: (TabModel) -> Void
    let tabHasThemeOverride: (UUID) -> Bool
    let onClearThemeOverride: (UUID) -> Void
    let onMoveTabToNewWindow: (TabModel) -> Void
    let onMoveTabsToNewWindow: ([UUID]) -> Void

    // Theme passthrough for the locally presented sessions-dashboard sheet
    // (a sheet presented from inside the fullScreenCover does not get the
    // themedSheet treatment MainView applies to its own sheets).
    let sheetThemeColors: SheetThemeColors?
    let sheetAccentColor: Color?
    let sheetColorScheme: ColorScheme?
    /// Open the tab exposé (shown with the header actions when the top tab bar is hidden).
    var onExposeRequested: () -> Void = {}

    @AppStorage("showTabShortcutIndicators") private var showTabShortcutIndicators: Bool = false
    @AppStorage("tabBarHidden") private var tabBarHidden: Bool = false

    /// Live keybinds, for handling the toggle shortcut INSIDE the sidebar:
    /// the terminal resigned first responder when this presented, so its
    /// UIKeyCommand for `toggle_tab_switcher` can't deliver the second
    /// (dismiss) press; a local SwiftUI shortcut catches it regardless of
    /// what the menu/responder chain does with it.
    @ObservedObject private var menuShortcuts = MenuShortcutState.shared

    @State private var searchText = ""
    @State private var dashboardRequest: TmuxDashboardRequest?

    /// Gateways whose "Hidden (N)" group is expanded. Session-scoped (not
    /// persisted): the disclosure defaults collapsed each presentation.
    @State private var expandedHiddenGroups: Set<UUID> = []
    @State private var collapsedGroups: Set<String> = TabSidebarGroupCollapseStore.load()

    // Context-menu dialog state (rename window/session, detach). Shared
    // with the top tab bar via TmuxTabMenu.swift.
    @State private var tmuxDialogs = TmuxTabDialogCoordinator()

    // Keyboard navigation: arrow keys move the highlight, Return selects,
    // typing filters. The search field is a UIKit-backed `SidebarSearchField`
    // (a real UITextField) rather than a SwiftUI TextField, so focus and key
    // handling are deterministic on iPad AND Mac Catalyst — no timers, no
    // @FocusState. Arrows/Return route through the field's own UIKit callbacks
    // (`pressesBegan` / delegate), not SwiftUI `.onKeyPress`.
    @State private var highlightedRowID: String?

    /// Whether the search field currently holds first responder, i.e. the
    /// sidebar — not the terminal beside it — owns the keyboard. The
    /// keyboard-cursor highlight (`highlightedRowID`) only renders while this is
    /// true: docked, the terminal usually owns the keyboard, so showing a second
    /// highlight disconnected from the selected tab is just confusing. Driven by
    /// `SidebarSearchField.onFocusChange`.
    @State private var searchFieldFocused = false

    /// Monotonic first-responder request handed to `SidebarSearchField`. Bumped
    /// (via `requestSearchFocus()`) on real events — panel open, row tap, sheet
    /// dismiss — and the field claims first responder on the next UIKit
    /// lifecycle event with a window. Deterministic: no `Task.sleep`, no retry.
    @State private var searchFocusRequestID = 0

    /// Whether the panel is currently presented. The overlay controller keeps
    /// this SwiftUI view MOUNTED (just transformed off-screen) after dismissal
    /// — it only swaps the hosted root on the next *open*. Used to refuse a
    /// re-focus request once the panel is dismissed (e.g. a sheet closing as
    /// the panel itself goes away).
    @State private var isPanelVisible = true

    /// Timer-driven arrow repeat, same as the profiles list: SwiftUI's
    /// `.repeat` key phase does not arrive on iPad hardware keyboards.
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()


    // System drag-and-drop reorder (the top tab bar's pattern). A custom
    // long-press+drag gesture was tried first and rejected: it eats the
    // touch on every draggable row, blocking scroll initiation there.
    @State private var draggingRowID: UUID? = nil
    @State private var draggingSectionID: String? = nil
    @State private var dragAssignedGroup = false
    @State private var dragStateGeneration = 0
    @State private var dragStateExpirationTask: Task<Void, Never>?
    @State private var dragPreviewWidth = TabSidebarLayout.defaultWidth - 24

    /// Control density: compact (dense list, small affordances) or large
    /// (body-size text, HIG-standard 44pt-class touch targets). Toggled by
    /// the textformat.size button in the header, persisted. Defaults large
    /// on iPhone (touch-first, full-screen panel) and compact on
    /// iPad/macOS/visionOS (pointer/keyboard, dense sidebar).
    @AppStorage("tabSidebarLargeControls") private var largeControls: Bool =
        UIDevice.current.userInterfaceIdiom == .phone

    /// Uniform title line count for every tab row (Settings > Appearance >
    /// Window > Tab Bar).
    @AppStorage("tabSidebarRowLines") private var titleLines: Int = 1

    /// The top tab bar already provides Settings and New Tab in its trailing
    /// corner. Keep those actions in the sidebar only when the top bar is
    /// hidden, or on iPhone where the full-width sidebar obscures it.
    private var showsHeaderActionButtons: Bool {
        tabBarHidden || UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Gates all attention rendering (dots, agent cards, rollup summary);
    /// the engine itself is gated separately by the master detection
    /// toggle. (id=agent-attention)
    @AppStorage(AgentAttentionSettings.badgesEnabledKey) private var attentionBadgesEnabled = true

    /// "static" keeps tab order (t3code rule: activity never reorders);
    /// "priority" bubbles blocked/failed/done/working rows up within
    /// their section. Visual-only — the tabs array never moves.
    @AppStorage(AgentAttentionSettings.sortKey) private var agentSortRaw = "static"

    private var attentionSortActive: Bool { agentSortRaw == "priority" }

    private var agentInboxSortIcon: String {
        if projectGroupingActive { return "folder.fill" }
        return attentionSortActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
    }

    private var agentInboxSortHelp: String {
        if projectGroupingActive { return "Grouped by project — tap to restore tab order" }
        if attentionSortActive { return "Sorted by attention — tap to group by project" }
        return "Sort tabs by attention"
    }

    /// Group the inbox into one collapsible section per project. Visual-only,
    /// like the attention sort.
    ///
    /// Deliberately NOT gated on the user's own tab groups being off. Making
    /// the two mutually exclusive left the mode unreachable for anyone with
    /// grouping enabled, with no indication why. While this is active it
    /// simply REPLACES the hierarchy: it already drops group and gateway
    /// headers, because an inbox grouped by project has no use for them.
    /// (id=agent-project)
    private var projectGroupingActive: Bool {
        agentSortRaw == "project" && attentionBadgesEnabled && hasAnyProject
    }

    /// Any tab with a resolved project, i.e. is there anything to group BY.
    ///
    /// Without this the mode could be active with nothing to show while the
    /// summary bar that hosts its toggle was hidden (the bar only appears when
    /// an agent is detected), leaving the preference stuck on with no control
    /// to turn it off. Degrading keeps the stored choice, so grouping resumes
    /// by itself once a project resolves. (id=agent-project)
    private var hasAnyProject: Bool {
        tabsModel.tabs.contains { tab in
            tab.splitTree.contains {
                $0.presentation.agentRow?.project?.label.isEmpty == false
            }
        }
    }

    /// Collapsed project sections, keyed by project label.
    @State private var collapsedProjects: Set<String> = []

    private var metrics: SidebarMetrics {
        let base: SidebarMetrics = largeControls ? .large : .compact
        return base.withTitleLines(titleLines)
    }

    /// The theme accent as an explicit color value. The sidebar is hosted in a
    /// `UIHostingController` (not a SwiftUI `.sheet`), so the panel's
    /// `.tint(...)` does not reach `Color.accentColor` here the way it does in
    /// the themed sheets — `Color.accentColor` falls back to the (empty) app
    /// accent asset, i.e. system blue. Reading the accent the parent already
    /// resolved makes the sidebar's accents match the connection / profiles
    /// views exactly (e.g. gold on the 3024 Day theme). Falls back to the
    /// system accent when no theme is active.
    private var accentTint: Color {
        sheetAccentColor ?? .accentColor
    }

    private var canReorderSections: Bool {
        tabsModel.isGroupedModeEnabled
            && searchText.isEmpty
            && tabsModel.availableGroups.count > 1
    }

    // MARK: Row Model

    private enum RowKind {
        case groupHeader(groupID: TabGroupID, title: String, count: Int, isActive: Bool, collapsed: Bool)
        case flat
        case gatewayHeader(collapsed: Bool, windowCount: Int, ownerID: UUID)
        case windowRow
        /// A pane-scoped agent card nested beneath a multi-pane tab.
        case agentPane(paneID: UUID)
        /// "Hidden (N)" disclosure under a gateway group. `tab` is the
        /// GATEWAY tab (the disclosure has no tab of its own), so the row id
        /// is kind-disambiguated below. (id=tmux-hidden-windows)
        case hiddenHeader(ownerID: UUID, count: Int, expanded: Bool)
        /// A hidden tmux window, listed under the expanded disclosure.
        case hiddenWindowRow
        /// Section header for the project-grouped inbox. `count` is the number
        /// of agent tabs inside; `rollup` is their worst attention state, shown
        /// in place of the chevron while collapsed so a folded section still
        /// reports that something needs you. (id=agent-project)
        case projectHeader(
            key: String,
            title: String,
            count: Int,
            collapsed: Bool,
            rollup: AgentAttentionStatus?)
    }

    /// Classifies how a dragged row reorders. Flat (.local) tabs move freely
    /// across the WHOLE list — including past gateway groups — exactly like
    /// the top tab bar (raw array move). tmux window rows (.window) reorder
    /// only among their own gateway's siblings (committed to the server via
    /// `move-window`). Gateway headers / hidden rows (.none) aren't draggable
    /// (whole-group drag is a follow-up), but a .local tab CAN be dropped onto
    /// a gateway header to land above/below the group.
    private enum DragClass: Equatable {
        case none
        case local
        case window(UUID)
    }

    private struct SidebarRow: Identifiable {
        let tab: TabModel
        let kind: RowKind
        let flatIndex: Int
        let indentLevel: Int

        init(tab: TabModel, kind: RowKind, flatIndex: Int, indentLevel: Int = 0) {
            self.tab = tab
            self.kind = kind
            self.flatIndex = flatIndex
            self.indentLevel = indentLevel
        }

        func indented(by levels: Int = 1) -> SidebarRow {
            SidebarRow(tab: tab, kind: kind, flatIndex: flatIndex, indentLevel: indentLevel + levels)
        }

        /// Kind-disambiguated: the hidden-disclosure row reuses the gateway
        /// TAB, so a bare tab UUID would collide with the gateway header.
        var id: String {
            if case .groupHeader(let groupID, _, _, _, _) = kind { return "group-\(groupID.rawValue)" }
            if case .hiddenHeader = kind { return "hidden-\(tab.id.uuidString)" }
            if case .projectHeader(let key, _, _, _, _) = kind { return "project-\(key)" }
            if case .agentPane(let paneID) = kind {
                return "pane-\(tab.id.uuidString)-\(paneID.uuidString)"
            }
            return tab.id.uuidString
        }

        var dragClass: DragClass {
            switch kind {
            case .groupHeader:
                return .none
            case .flat:
                return .local
            case .gatewayHeader, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader:
                return .none
            case .windowRow:
                // Placeholders have no server window to move yet.
                guard let owner = tab.owningGatewayTerminalUUID,
                      tab.tmuxWindowId != nil,
                      !tab.awaitingTmuxReconcile else { return .none }
                return .window(owner)
            }
        }

        var isDraggable: Bool { dragClass != .none }

        var sectionID: TabGroupID? {
            switch kind {
            case .groupHeader(let groupID, _, _, _, _):
                return groupID
            case .gatewayHeader(_, _, let ownerID):
                return .tmux(ownerID: ownerID)
            case .flat, .windowRow, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader:
                return nil
            }
        }

        var isHiddenKind: Bool {
            switch kind {
            case .groupHeader:
                return false
            case .hiddenHeader, .hiddenWindowRow: return true
            default: return false
            }
        }

        var visualIndentLevel: Int {
            switch kind {
            case .windowRow, .hiddenWindowRow, .hiddenHeader:
                return indentLevel + 1
            default:
                return indentLevel
            }
        }
    }

    var body: some View {
        let rows = buildRows()
        // Resolved ONCE per render and reused for every row: the per-tab
        // `badge(for:allTabs:)` walks every other tab's split tree, so calling
        // it per row was O(n^2) and gave the sidebar body an Observation
        // dependency on every tab's split tree. Same treatment the top tab bar
        // already applies. (See TmuxTabBadgeResolver.badge(for:gatewayOwnerIDs:).)
        let gatewayOwnerIDs = TmuxTabBadgeResolver.activeGatewayOwnerIDs(in: tabsModel.tabs)

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                searchField(rows: rows, proxy: proxy)
                agentSummaryBar

                Divider()
                    .padding(.top, 6)

                if rows.isEmpty && !searchText.isEmpty {
                    Spacer()
                    Text("No matching tabs")
                        .font(.system(size: metrics.titleSize))
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    rowList(rows, gatewayOwnerIDs: gatewayOwnerIDs)
                }

                // Subscription usage for live agents. Self-hiding: renders
                // nothing when the feature is off or nothing is fetched, so
                // it costs the sidebar no space at rest.
                SidebarAgentUsageFooter(
                    metrics: metrics,
                    accentTint: accentTint,
                    isDocked: isDocked
                )
            }
            // Keep the column's bottom content (usage footer, last tab row)
            // above the keyboard or its toolbar: both span the full window
            // width, and `.ignoresSafeArea(.keyboard)` below means the safe
            // area won't supply this clearance. See `dockedBottomClearance`.
            .padding(.bottom, dockedBottomClearance)
            // Synced on EVERY render, not just on mode change or appear:
            // `projectGroupingActive` also depends on badges being enabled and
            // on a project having resolved asynchronously, so an event-only
            // sync let the sidebar group by project while the tab bar stayed
            // unscoped, or kept it scoped after grouping stopped.
            // The setter is equality-guarded, so this is free at steady state.
            .onChange(of: projectGroupingActive, initial: true) { _, active in
                tabsModel.projectScopedInboxEnabled = active
            }
            .onAppear {
                loadGroupOrder()
                // The overlay reuses this view's @State across presentations
                // (it keeps the hosting view mounted off-screen), so re-assert
                // visibility on every appear — this is the authoritative "panel
                // is on screen" signal, since onAppear fires on each open.
                isPanelVisible = true
                highlightedRowID = tabsModel.selectedTabID?.uuidString
                if let selectedID = tabsModel.selectedTabID {
                    proxy.scrollTo(selectedID.uuidString, anchor: .center)
                }
                // Docked, the terminal beside the column owns the keyboard:
                // auto-grabbing the search field on appear (incl. launch
                // restore) would yank focus off the terminal. Tapping the
                // field still focuses it (user intent).
                if !isDocked {
                    requestSearchFocus()
                }
                // Warm each gateway's session cache so the "Move to Session"
                // context-menu pickers (synchronous ViewBuilders) have data.
                for tab in tabsModel.tabs where tab.isTmuxGateway {
                    tmuxController(tab)?.refreshSessionsCache()
                }
            }
            .onDisappear {
                arrowKeyRepeatManager.stop()
                clearLocalDragState()
            }
            // Docked: a tap on the panel's empty / header area anchors keyboard
            // focus in the search field so arrow keys navigate tabs — clicking
            // the small filter field is no longer the only way in. Tab rows,
            // header buttons, and the search field consume their own taps first,
            // so this only fires on otherwise-empty regions (tap ≠ drag, so it
            // does not block scrolling or row drag-reorder). Floating already
            // auto-focuses on open (see onAppear), so the isDocked gate keeps it
            // a no-op there.
            .contentShape(Rectangle())
            .onTapGesture {
                if isDocked { requestSearchFocus() }
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(sidebarShortcutCatchers)
        .tmuxTabDialogs(coordinator: tmuxDialogs, controller: tmuxController)
        .sheet(item: $dashboardRequest) { request in
            TmuxSessionDashboardView(controller: request.controller)
                .themedSheet(
                    themeColors: sheetThemeColors,
                    accentColor: sheetAccentColor,
                    colorScheme: sheetColorScheme
                )
        }
        .onChange(of: collapsedGateways) { _, newValue in
            let known = Set(tabsModel.tabs.compactMap { tab -> UUID? in
                guard tab.isTmuxGateway || tab.isTmuxWindow else { return nil }
                return TmuxTabBadgeResolver.ownerID(for: tab)
            })
            TabSidebarCollapseStore.save(newValue, knownGateways: known)
        }
        .onChange(of: collapsedGroups) { _, newValue in
            TabSidebarGroupCollapseStore.save(
                newValue,
                knownGroups: Set(tabsModel.availableGroups.map { $0.id.rawValue })
            )
        }
        .onChange(of: tabsModel.availableGroups.map { $0.id.rawValue }) { _, _ in
            if !canReorderSections {
                draggingSectionID = nil
            }
        }
        .onChange(of: searchText) { _, _ in
            if !canReorderSections {
                draggingSectionID = nil
            }
        }
        // Track presentation so a re-focus request refuses to fire once the
        // panel is dismissed. The field resigns first responder on dismiss via
        // the overlay controller's `endEditing(true)` (TabSidebarPresentation),
        // so nothing is needed here on hide.
        .onReceive(NotificationCenter.default.publisher(for: .tabSwitcherVisibilityChanged)) { note in
            guard let visible = note.userInfo?["visible"] as? Bool else { return }
            isPanelVisible = visible
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabTransferDragStateChanged)) { _ in
            guard let draggingID = draggingRowID,
                  !TabTransferCoordinator.shared.isActiveDrag(sourceWindowId: windowId, tabID: draggingID) else {
                return
            }
            clearLocalDragState()
        }
        // The tmux sessions dashboard (a real .sheet presented over the panel)
        // takes first responder while it is up. When it dismisses with the
        // panel still open, re-anchor first responder in the search field so
        // arrow-key navigation resumes. Keyed on the sheet binding (not a lagged
        // guard) → deterministic.
        .onChange(of: dashboardRequest != nil) { wasPresented, isPresented in
            guard wasPresented, !isPresented, isPanelVisible else { return }
            requestSearchFocus()
        }
    }

    /// Hidden buttons for shortcuts that must keep working while the floating
    /// sidebar owns first responder (see `menuShortcuts`).
    ///
    /// Single-chord bindings only: `MenuShortcutState` collapses multi-key
    /// sequences (e.g. `ctrl+a > t`) to their FIRST trigger, so installing one
    /// here would fire on a bare `ctrl+a`. Sequence bindings keep
    /// working through the normal KeySequenceTracker path instead — the
    /// same exclusion KeybindCommandGenerator applies to menu shortcuts.
    @ViewBuilder
    private var sidebarShortcutCatchers: some View {
        ZStack {
            if isPanelVisible,
               hasSingleChordBinding(for: .toggle_tab_switcher),
               let shortcut = menuShortcuts.shortcuts[.toggle_tab_switcher] {
                Button("") { onDismiss() }
                    .keyboardShortcut(shortcut)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            if isPanelVisible,
               hasSingleChordBinding(for: .toggle_group_mode),
               let shortcut = menuShortcuts.shortcuts[.toggle_group_mode] {
                Button("") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        tabsModel.isGroupedModeEnabled.toggle()
                    }
                }
                .keyboardShortcut(shortcut)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    private func hasSingleChordBinding(for action: KeybindAction) -> Bool {
        KeybindManager.shared.activeBindings.contains { binding in
            binding.action == action && !binding.sequence.isSequence
        }
    }

    // MARK: Header

    private var isPhone: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// SwiftUI's `.onDrag` exposes drag start but not a reliable drag-ended or
    /// drag-cancelled callback. Hiding the source row is therefore only safe on
    /// Catalyst, where row drops reliably complete through our drop delegates.
    /// On iPad/iPhone a touch or trackpad drag can end without `performDrop`,
    /// leaving local visual state stale until a watchdog fires.
    private var usesHiddenSourceDragPreview: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Live progress of a dismiss drag, posted to the overlay controller which
    /// translates the UIKit hosting view (see the swipe-down notification
    /// design notes in `TabSidebarPresentation.swift`).
    private func postDismissDragChanged(_ value: DragGesture.Value) {
        NotificationCenter.default.post(
            name: .tabSidebarDismissDragChanged,
            object: nil,
            userInfo: ["offset": max(0, value.translation.height)]
        )
    }

    /// End of a dismiss drag: commit only past about a third of the screen, or
    /// on a genuine downward flick — matching the native sheet feel. (The old
    /// bottom panel's 80pt threshold dismissed a full-screen panel from a tiny
    /// nudge.) Otherwise spring back via the cancelled notification.
    private func commitOrCancelDismissDrag(_ value: DragGesture.Value) {
        // `UIScreen.main` is unavailable on visionOS, but the dismiss drag only
        // exists on iPhone (`isPhone` is always false on visionOS), so the
        // 120pt floor is a harmless fallback there.
        #if os(visionOS)
        let dismissDistance: CGFloat = 120
        #else
        let dismissDistance = max(120, UIScreen.main.bounds.height * 0.3)
        #endif
        if value.translation.height > dismissDistance || value.velocity.height > 1000 {
            onDismiss()
        } else {
            NotificationCenter.default.post(name: .tabSidebarDismissDragCancelled, object: nil)
        }
    }

    /// Drag down to dismiss. GLOBAL coordinate space, and the movement is
    /// applied by the overlay controller to the UIKit hosting view (via the
    /// dismiss-drag notifications): tracking in local space while offsetting
    /// the view under the finger feeds the motion back into the gesture
    /// (jitter), and a SwiftUI offset here would move only the content, not
    /// the panel chrome.
    ///
    /// `minimumDistance` is a parameter so the dedicated grab handle can use a
    /// 0pt threshold (instant, native-feeling) while the broad header keeps a
    /// safe 10pt threshold to coexist with its buttons.
    private func dismissDragGesture(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { postDismissDragChanged($0) }
            .onEnded { commitOrCancelDismissDrag($0) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // The grab handle + swipe-down dismiss belong to the floating panel.
            // Docked, the sidebar is a fixed column with no slide-to-dismiss.
            if isPhone && !isDocked {
                // A dedicated, button-free grab strip so the handle drags like a
                // native sheet grabber: a 0pt drag threshold begins tracking
                // instantly (no dead-zone), and — because nothing here is
                // tappable — SwiftUI never delays the drag to disambiguate it
                // from a button press the way the broad header gesture must.
                // `highPriorityGesture` makes this strip win over the parent
                // header gesture for touches that land on the capsule.
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                    .highPriorityGesture(dismissDragGesture(minimumDistance: 0))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Drag down to dismiss")
            }
            headerRow
        }
        .contentShape(Rectangle())
        // Disable the swipe-down dismiss when docked (keep subview/button
        // gestures); `.subviews` masks this gesture off the header itself.
        // The broad header keeps a 10pt threshold so a drag and the header's
        // buttons can share the region; the capsule strip above handles the
        // instant grab.
        .gesture(dismissDragGesture(minimumDistance: 10), including: isDocked ? .subviews : .all)
    }

    /// A header icon button at the current density's target size.
    private func headerButton(
        _ systemImage: String,
        help: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.headerIconSize, weight: .medium))
                // Tinted like a standard toolbar button, matching how the
                // connection / profiles views color their leading icons. Uses
                // the explicit theme accent (see `accentTint`) rather than
                // `.accentColor`, which would render system blue here.
                .foregroundColor(accentTint)
                .frame(width: metrics.headerButtonTarget, height: metrics.headerButtonTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        return Group {
            if let help {
                button.help(help)
            } else {
                button
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            headerButton(tabBarHidden ? "eye.slash" : "eye", help: "Show or hide the top tab bar") {
                NotificationCenter.default.post(name: .toggleTabBar, object: nil)
            }

            headerButton("textformat.size", help: "Switch between compact and large controls") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    largeControls.toggle()
                }
            }

            if canPin {
                headerButton(
                    isPinned ? "pin.fill" : "pin",
                    help: isPinned ? "Unpin the sidebar" : "Pin the sidebar to the side"
                ) {
                    onTogglePin()
                }
            }

            Spacer()

            if showsHeaderActionButtons {
                headerButton("gearshape", action: onOpenSettings)

                // Vertical-tabs-only users have no tab bar band to pull down.
                headerButton("rectangle.grid.2x2", help: "Tab Exposé", action: onExposeRequested)

                headerButton("plus", action: onNewTab)
            }

            headerButton("xmark", action: onDismiss)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Agent Summary

    /// Rollup line under the search bar ("2 blocked · 1 working") plus the
    /// attention-sort toggle. Hidden when no agents are detected anywhere.
    /// (id=agent-attention)
    @ViewBuilder
    private var agentSummaryBar: some View {
        if attentionBadgesEnabled {
            SidebarAgentSummaryBar(
                metrics: metrics,
                accentTint: accentTint,
                sortIconName: agentInboxSortIcon,
                sortHelp: agentInboxSortHelp,
                sortIsActive: attentionSortActive || projectGroupingActive,
                onCycleSort: {
                    // Cycles tab order -> attention -> project.
                    switch agentSortRaw {
                    case "priority":
                        agentSortRaw = "project"
                    case "project":
                        agentSortRaw = "static"
                    default:
                        agentSortRaw = "priority"
                    }
                }
            )
        }
    }

    // MARK: Search

    private func searchField(rows: [SidebarRow], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.searchFontSize - 1))
                .foregroundColor(.secondary)

            // UIKit-backed (see SidebarSearchField): deterministic focus + key
            // handling on iPad and Mac Catalyst. Arrows drive the highlight
            // (with hold-to-repeat via ArrowKeyRepeatManager), Escape is
            // two-stage (clear filter, then dismiss), Return selects.
            SidebarSearchField(
                text: $searchText,
                placeholder: String(localized: "Filter tabs"),
                fontSize: metrics.searchFontSize,
                canFocus: isPanelVisible,
                focusRequestID: searchFocusRequestID,
                onMoveUpBegan: {
                    moveHighlight(by: -1, rows: rows, proxy: proxy)
                    arrowKeyRepeatManager.start(direction: .up) {
                        moveHighlight(by: -1, rows: rows, proxy: proxy)
                    }
                },
                onMoveUpEnded: { arrowKeyRepeatManager.stop(direction: .up) },
                onMoveDownBegan: {
                    moveHighlight(by: 1, rows: rows, proxy: proxy)
                    arrowKeyRepeatManager.start(direction: .down) {
                        moveHighlight(by: 1, rows: rows, proxy: proxy)
                    }
                },
                onMoveDownEnded: { arrowKeyRepeatManager.stop(direction: .down) },
                onEscape: {
                    arrowKeyRepeatManager.stop()
                    if !searchText.isEmpty {
                        searchText = ""
                    } else {
                        onDismiss()
                    }
                },
                onSubmit: {
                    arrowKeyRepeatManager.stop()
                    selectHighlighted(rows: rows)
                },
                onFocusChange: { focused in
                    // Defer off this runloop: the begin-editing callback can
                    // fire synchronously from `becomeFirstResponder()` inside
                    // `updateUIView`, where a direct @State write would be
                    // "modifying state during view update". Main-queue FIFO
                    // preserves begin/end ordering.
                    DispatchQueue.main.async {
                        searchFieldFocused = focused
                        // Reacquiring focus: start the cursor from the live
                        // selection so it reappears connected to the active tab,
                        // never at a stale row.
                        if focused {
                            highlightedRowID = tabsModel.selectedTabID?.uuidString
                        }
                    }
                }
            )
            // Fill the row width; pin the height so gaining focus cannot
            // reflow the rows below.
            .frame(maxWidth: .infinity)
            .frame(height: metrics.searchFieldHeight)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: metrics.searchFontSize - 1))
                        .foregroundColor(.secondary)
                        .frame(
                            width: max(22, metrics.rowButtonTarget - 8),
                            height: max(22, metrics.rowButtonTarget - 8)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    tabsModel.isGroupedModeEnabled.toggle()
                }
            } label: {
                Image(systemName: tabsModel.isGroupedModeEnabled ? "square.grid.2x2.fill" : "square.grid.2x2")
                    .font(.system(size: metrics.searchFontSize - 1, weight: .medium))
                    .foregroundColor(tabsModel.isGroupedModeEnabled ? accentTint : .secondary)
                    .frame(
                        width: max(22, metrics.rowButtonTarget - 8),
                        height: max(22, metrics.rowButtonTarget - 8)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Group tabs")
        }
        // Inset the icon/text off the pill's curved ends (matches the
        // Settings search field's horizontal padding).
        .padding(.horizontal, 14)
        // Fixed container height (not vertical padding around a variable
        // field): the search bar must never change size on focus.
        .frame(height: metrics.searchBarHeight)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
    }

    // MARK: Row List

    private func rowList(_ rows: [SidebarRow], gatewayOwnerIDs: [UUID]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: metrics.rowSpacing) {
                ForEach(rows) { row in
                    rowView(row: row, rows: rows, gatewayOwnerIDs: gatewayOwnerIDs)
                        .id(row.id)
                }
            }
            // The docked sidebar is user-resizable. Capture the rendered row
            // width so Catalyst's custom drag preview matches its source
            // instead of assuming the floating panel's default width.
            //
            // Measured on the stack, not per row: rows stretch to the stack's
            // content width so the number is identical, and a per-row reader
            // let a single row's re-layout (a drag or context-menu lift) write
            // this parent @State and re-render the whole sidebar mid-gesture.
            // Applied INSIDE the horizontal padding, matching what a row spans.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                guard width > 0, dragPreviewWidth != width else { return }
                dragPreviewWidth = width
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        // Catch-all so a drop released over the list (but not over a row)
        // still commits the arrangement and clears the drag state.
        .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: SidebarContainerDropDelegate(
            onPerform: {
                if TabTransferCoordinator.shared.canAcceptActiveDrag(in: windowId) {
                    return receiveCrossWindowDrop()
                }
                return completeDrag()
            }
        ))
    }

    private func moveHighlight(by delta: Int, rows: [SidebarRow], proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let currentIndex = highlightedRowID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
            ?? tabsModel.selectedTabID.flatMap { id in
                rows.firstIndex(where: { $0.id == id.uuidString })
            }
            ?? (delta > 0 ? -1 : rows.count)
        let next = max(0, min(rows.count - 1, currentIndex + delta))
        highlightedRowID = rows[next].id
        proxy.scrollTo(rows[next].id, anchor: nil)
    }

    /// Selects the highlighted row (or the first visible row, e.g. the top
    /// filter match) and keeps the keyboard anchored in the panel.
    @discardableResult
    private func selectHighlighted(rows: [SidebarRow]) -> Bool {
        let validHighlight = highlightedRowID.flatMap { id in
            rows.contains(where: { $0.id == id }) ? id : nil
        }
        guard let id = validHighlight ?? rows.first?.id,
              let row = rows.first(where: { $0.id == id }) else { return false }
        highlightedRowID = id
        activateHighlightedRow(row)
        // No re-grab needed: while the sidebar stays open, handleSelectedTabChange
        // skips the terminal's becomeFirstResponder and the overlayOwnsKeyboard
        // gate would refuse it anyway, so the search field keeps first responder.
        return true
    }

    /// Keyboard Return activation. Section headers toggle their disclosure
    /// state; pointer/touch activation keeps its existing selection behavior.
    private func activateHighlightedRow(_ row: SidebarRow) {
        switch row.kind {
        case .groupHeader(let groupID, _, _, _, _):
            toggleGroupCollapse(groupID)
        case .gatewayHeader(_, _, let ownerID):
            if row.tab.isHiddenTmuxWindow {
                activateRow(row)
            } else {
                toggleGatewayCollapse(ownerID)
            }
        default:
            activateRow(row)
        }
    }

    /// Row activation for pointer/touch selection and non-section keyboard
    /// activation: hidden disclosure toggles, hidden windows show-and-select,
    /// everything else selects.
    private func activateRow(_ row: SidebarRow) {
        switch row.kind {
        case .groupHeader(let groupID, _, _, _, _):
            activateGroup(groupID)
        case .hiddenHeader(let ownerID, _, _):
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if expandedHiddenGroups.contains(ownerID) {
                    expandedHiddenGroups.remove(ownerID)
                } else {
                    expandedHiddenGroups.insert(ownerID)
                }
            }
        case .hiddenWindowRow:
            showHiddenWindow(row.tab)
        case .gatewayHeader:
            // A hidden gateway keeps its header as the group's structure;
            // activating it shows + selects. (id=tmux-hidden-gateway)
            if row.tab.isHiddenTmuxWindow {
                showHiddenGateway(row.tab)
            } else {
                onSelectTab(row.tab.id)
            }
        case .projectHeader(let key, _, _, let collapsed, _):
            // Reached by keyboard navigation; the header's own tap gesture
            // handles pointer input.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if collapsed {
                    collapsedProjects.remove(key)
                } else {
                    collapsedProjects.insert(key)
                }
            }
        case .agentPane(let paneID):
            onSelectPane(row.tab.id, paneID)
        case .flat, .windowRow:
            onSelectTab(row.tab.id)
        }
    }

    private func toggleGroupCollapse(_ groupID: TabGroupID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if collapsedGroups.contains(groupID.rawValue) {
                collapsedGroups.remove(groupID.rawValue)
            } else {
                collapsedGroups.insert(groupID.rawValue)
            }
        }
    }

    private func toggleGatewayCollapse(_ ownerID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if collapsedGateways.contains(ownerID) {
                collapsedGateways.remove(ownerID)
            } else {
                collapsedGateways.insert(ownerID)
            }
        }
    }

    private func activateGroup(_ groupID: TabGroupID) {
        let targetID = firstVisibleTabID(inGroup: groupID)
        if let targetID {
            onSelectTab(targetID)
        } else {
            tabsModel.activeGroupID = groupID
        }
    }

    private func firstVisibleTabID(inGroup groupID: TabGroupID) -> UUID? {
        guard let group = tabsModel.availableGroups.first(where: { $0.id == groupID }) else { return nil }
        return group.tabIDs.first { id in
            guard let tab = tabsModel.tab(withID: id) else { return false }
            return !tab.isHiddenTmuxWindow
        }
    }

    /// Restore a hidden tmux window and select its tab.
    private func showHiddenWindow(_ tab: TabModel) {
        guard let windowId = tab.tmuxWindowId,
              let controller = tmuxController(tab) else { return }
        controller.showWindow(windowId: windowId, andSelect: true)
    }

    /// Restore a hidden GATEWAY tab and select it. Routed through the
    /// controller (NOT onSelectTab — MainView's selection closure never
    /// unhides); if the controller is somehow gone, clear the flag directly so
    /// a tab can never be left unreachable. (id=tmux-hidden-gateway)
    private func showHiddenGateway(_ tab: TabModel) {
        if let controller = tmuxController(tab) {
            controller.showGatewayTab(andSelect: true)
        } else {
            tab.isHiddenTmuxWindow = false
            onSelectTab(tab.id)
        }
    }

    /// Re-anchors first responder inside the panel. Selecting a tab makes
    /// Ask the search field to take first responder by bumping its focus
    /// request. `SidebarSearchField` claims it on the next UIKit lifecycle event
    /// that has a window — deterministically, with no timer or retry. Selecting
    /// a tab focuses that tab's terminal, but while the sidebar stays open the
    /// panel owns the keyboard (MainView's overlayOwnsKeyboard gate refuses the
    /// terminal), so re-anchoring here keeps arrow-key navigation alive. No-op
    /// without a hardware keyboard (would pop the software keyboard).
    private func requestSearchFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return }
        searchFocusRequestID += 1
    }

    @ViewBuilder
    private func rowView(row: SidebarRow, rows: [SidebarRow], gatewayOwnerIDs: [UUID]) -> some View {
        let isDraggingTab = draggingRowID == row.tab.id && row.isDraggable
        let isDraggingSection = draggingSectionID != nil && row.sectionID?.rawValue == draggingSectionID
        let isDragging = isDraggingTab || isDraggingSection
        let hidesSourceDuringDrag = usesHiddenSourceDragPreview
        let isSelected = tabsModel.selectedTabID == row.tab.id && !row.isHiddenKind
        // The keyboard-cursor highlight only renders when a hardware keyboard
        // is driving the list AND the sidebar's search field actually owns the
        // keyboard. Docked, the terminal beside the column usually holds first
        // responder, so without the focus gate the cursor highlight would linger
        // disconnected from the selected tab whenever the user switched tabs from
        // the terminal — two highlights at once. (Floating auto-focuses the
        // field on open and keeps it, so this stays true throughout normal use.)
        let isHighlighted = highlightedRowID == row.id
            && KeyboardTracker.shared.isHardwareKeyboard
            && searchFieldFocused

        Group {
            switch row.kind {
            case .groupHeader(let groupID, let title, let count, let isActive, let collapsed):
                groupHeaderRow(
                    row: row,
                    groupID: groupID,
                    title: title,
                    count: count,
                    isActive: isActive,
                    collapsed: collapsed,
                    isHighlighted: isHighlighted
                )
                .contextMenu {
                    moveGroupToWindowItems(for: groupID, isGateway: false)
                }
            case .gatewayHeader(let collapsed, let windowCount, let ownerID):
                gatewayHeaderRow(
                    row: row,
                    isSelected: isSelected,
                    isHighlighted: isHighlighted,
                    collapsed: collapsed,
                    windowCount: windowCount,
                    ownerID: ownerID,
                    gatewayOwnerIDs: gatewayOwnerIDs
                )
                .equatable()
                // Attached out here, not inside the row — see the tab row's
                // .contextMenu note.
                .contextMenu {
                    gatewayHeaderMenu(for: row.tab, ownerID: ownerID)
                }
            case .hiddenHeader(let ownerID, let count, let expanded):
                hiddenGroupHeaderRow(
                    isHighlighted: isHighlighted,
                    indentLevel: row.visualIndentLevel,
                    ownerID: ownerID,
                    count: count,
                    expanded: expanded
                )
            case .projectHeader(let key, let title, let count, let collapsed, let rollup):
                projectHeaderRow(
                    key: key,
                    title: title,
                    count: count,
                    collapsed: collapsed,
                    rollup: rollup,
                    isHighlighted: isHighlighted
                )
            case .agentPane(let paneID):
                SidebarPaneRowItem(
                    tab: row.tab,
                    paneID: paneID,
                    attentionBadgesEnabled: attentionBadgesEnabled,
                    isSelected: isSelected && row.tab.focusedPane?.uuid == paneID,
                    isHighlighted: isHighlighted,
                    indentLevel: row.visualIndentLevel,
                    metrics: metrics,
                    accentTint: accentTint
                )
                .equatable()
                .onTapGesture {
                    highlightedRowID = row.id
                    activateRow(row)
                    if staysOpenOnSelect && !isDocked {
                        requestSearchFocus()
                    }
                }
            case .flat, .windowRow, .hiddenWindowRow:
                // `.equatable()` gates parent-driven rebuilds; the row's own
                // observed reads live inside SidebarTabRowItem. The modifiers
                // below stay OUT here on purpose — see the .contextMenu note.
                SidebarTabRowItem(
                    tab: row.tab,
                    tmuxBadge: TmuxTabBadgeResolver.badge(for: row.tab, gatewayOwnerIDs: gatewayOwnerIDs),
                    attentionBadgesEnabled: attentionBadgesEnabled,
                    isSelected: isSelected,
                    isHighlighted: isHighlighted,
                    indentLevel: row.visualIndentLevel,
                    shortcutHint: shortcutHint(for: row),
                    metrics: metrics,
                    accentTint: accentTint,
                    onClose: { onCloseTab(row.tab.id) }
                )
                .equatable()
                .opacity(row.isHiddenKind ? 0.55 : 1)
                .onTapGesture {
                    highlightedRowID = row.id
                    activateRow(row)
                    // Skip when the tap dismisses the panel (phone/visionOS):
                    // re-anchoring would steal first responder back to the
                    // off-screen field. iPad/Catalyst keeps the panel open.
                    // Also skip when docked: a row tap there should focus the
                    // terminal beside the column for typing (handleSelectedTabChange
                    // grants it), not race the search field back. Tap empty
                    // sidebar space to drive arrow-key navigation instead.
                    if staysOpenOnSelect && !isDocked {
                        requestSearchFocus()
                    }
                }
                // Deliberately attached HERE, outside `.equatable()`, rather
                // than inside SidebarTabRowItem. SwiftUI rebuilds a menu's
                // content closure whenever the view it is attached to is
                // re-evaluated, and the row item is invalidated by `tab.title`
                // at agent-spinner rate — so moving the menu inside would keep
                // rebuilding it under the user's finger. Out here it is rebuilt
                // once per parent-body render, and the parent no longer
                // observes any tab's title or agent state.
                //
                // tmux-specific items self-gate on tmuxWindowId /
                // awaitingTmuxReconcile inside TmuxTabMenuItems, so a
                // reconciling window row still gets Connection Info and
                // Close. (id=tmux-hidden-windows)
                .contextMenu {
                    switch row.kind {
                    case .windowRow:
                        windowRowMenu(for: row.tab)
                    case .hiddenWindowRow:
                        hiddenWindowRowMenu(for: row.tab)
                    default:
                        flatRowMenu(for: row.tab)
                    }
                }
            }
        }
        .opacity(isDragging && hidesSourceDuringDrag ? 0 : 1)
        .overlay {
            if isDragging && hidesSourceDuringDrag {
                draggingSourcePlaceholder
            }
        }
        .accessibilityHidden(isDragging && hidesSourceDuringDrag)
        .modifier(SidebarRowDragModifier(
            isDraggable: rowIsDraggable(row),
            usesCustomPreview: hidesSourceDuringDrag,
            onDragStarted: {
                if let projectID = draggableProjectSectionID(for: row) {
                    tabsModel.draggingProjectGroupID = projectID
                    draggingSectionID = nil
                    draggingRowID = nil
                    dragAssignedGroup = false
                    scheduleDragStateExpiration(rowID: nil, sectionID: projectID.rawValue)
                    return NSItemProvider(object: projectID.rawValue as NSString)
                }
                if let sectionID = draggableSectionID(for: row) {
                    draggingSectionID = sectionID.rawValue
                    draggingRowID = nil
                    dragAssignedGroup = false
                    scheduleDragStateExpiration(rowID: nil, sectionID: sectionID.rawValue)
                    return NSItemProvider(object: sectionID.rawValue as NSString)
                }
                draggingRowID = row.tab.id
                draggingSectionID = nil
                dragAssignedGroup = false
                scheduleDragStateExpiration(rowID: row.tab.id, sectionID: nil)
                return TabTransferCoordinator.shared.beginDrag(sourceWindowId: windowId, tabID: row.tab.id)
            },
            dropDelegate: SidebarRowDropDelegate(
                // Disambiguated row id (not tab.id): the "Hidden (N)"
                // disclosure reuses the gateway tab's UUID, so a bare tab id
                // can't tell it apart from the gateway header.
                targetRowID: row.id,
                onEntered: { targetRowID in
                    handleDragEntered(targetRowID: targetRowID, rows: rows)
                },
                onPerform: {
                    if TabTransferCoordinator.shared.canAcceptActiveDrag(in: windowId) {
                        let group = tabsModel.isGroupedModeEnabled ? containingSectionID(for: row) : nil
                        return TabTransferCoordinator.shared.receiveActiveDrag(
                            in: windowId,
                            insertionIndex: row.flatIndex,
                            groupOverride: group,
                            isDestinationWindowFocused: true
                        )
                    }
                    return completeDrag()
                }
            ),
            dragPreview: {
                dragPreview(for: row, gatewayOwnerIDs: gatewayOwnerIDs)
            }
        ))
    }

    private func cancelDragStateExpiration() {
        // Invalidate an already-resumed task as well as cancelling its sleep.
        dragStateGeneration &+= 1
        dragStateExpirationTask?.cancel()
        dragStateExpirationTask = nil
    }

    private func clearLocalDragState() {
        cancelDragStateExpiration()
        draggingRowID = nil
        draggingSectionID = nil
        tabsModel.draggingProjectGroupID = nil
        dragAssignedGroup = false
    }

    private func scheduleDragStateExpiration(rowID: UUID?, sectionID: String?) {
        // SwiftUI exposes drag start and successful drops, but no dependable
        // cancellation callback. Keep one hard failsafe aligned with
        // TabTransferCoordinator's 30-second lifetime. This is deliberately
        // not refreshed from `dropUpdated`: those callbacks are movement-driven,
        // and a stationary drag remains valid.
        cancelDragStateExpiration()
        let generation = dragStateGeneration
        dragStateExpirationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: TabTransferCoordinator.activeDragExpiration)
            } catch {
                return
            }
            guard dragStateGeneration == generation else { return }
            dragStateExpirationTask = nil
            if let rowID, draggingRowID == rowID {
                draggingRowID = nil
                dragAssignedGroup = false
            }
            if let sectionID, draggingSectionID == sectionID {
                draggingSectionID = nil
                dragAssignedGroup = false
            }
            if let sectionID, tabsModel.draggingProjectGroupID?.rawValue == sectionID {
                tabsModel.draggingProjectGroupID = nil
                dragAssignedGroup = false
            }
        }
    }

    private var draggingSourcePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(draggingSourcePlaceholderFill)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(draggingSourcePlaceholderStroke, lineWidth: 1)
            }
    }

    private var draggingSourcePlaceholderFill: Color {
        if sheetThemeColors != nil {
            return accentTint.opacity(0.07)
        }
        return Color.primary.opacity(0.035)
    }

    private var draggingSourcePlaceholderStroke: Color {
        if sheetThemeColors != nil {
            return accentTint.opacity(0.18)
        }
        return Color.primary.opacity(0.08)
    }

    private var dragPreviewBackgroundFill: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground)
    }

    @ViewBuilder
    /// Built from the SAME `SidebarTabRowItem` as the live row so the two
    /// construction sites can't drift. No `.equatable()`: this renders once per
    /// drag, so the equality gate would only add work.
    private func dragPreview(for row: SidebarRow, gatewayOwnerIDs: [UUID]) -> some View {
        let isSelected = tabsModel.selectedTabID == row.tab.id && !row.isHiddenKind

        Group {
            switch row.kind {
            case .groupHeader(let groupID, let title, let count, let isActive, let collapsed):
                groupHeaderRow(
                    row: row,
                    groupID: groupID,
                    title: title,
                    count: count,
                    isActive: isActive,
                    collapsed: collapsed,
                    isHighlighted: false
                )
            case .gatewayHeader(let collapsed, let windowCount, let ownerID):
                gatewayHeaderRow(
                    row: row,
                    isSelected: isSelected,
                    isHighlighted: false,
                    collapsed: collapsed,
                    windowCount: windowCount,
                    ownerID: ownerID,
                    gatewayOwnerIDs: gatewayOwnerIDs
                )
            case .flat, .windowRow, .hiddenWindowRow:
                SidebarTabRowItem(
                    tab: row.tab,
                    tmuxBadge: TmuxTabBadgeResolver.badge(for: row.tab, gatewayOwnerIDs: gatewayOwnerIDs),
                    attentionBadgesEnabled: attentionBadgesEnabled,
                    isSelected: isSelected,
                    isHighlighted: false,
                    indentLevel: row.visualIndentLevel,
                    shortcutHint: shortcutHint(for: row),
                    metrics: metrics,
                    accentTint: accentTint,
                    onClose: {}
                )
            case .agentPane, .hiddenHeader, .projectHeader:
                EmptyView()
            }
        }
        .frame(width: dragPreviewWidth)
        .background(dragPreviewBackgroundFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .optionalColorSchemeEnvironment(sheetColorScheme)
    }

    private func receiveCrossWindowDrop() -> Bool {
        let insertionIndex: Int? = tabsModel.selectedTabID.flatMap { tabsModel.index(of: $0) }.map { $0 + 1 }
        let groupOverride = tabsModel.isGroupedModeEnabled ? tabsModel.activeGroupID : nil
        return TabTransferCoordinator.shared.receiveActiveDrag(
            in: windowId,
            insertionIndex: insertionIndex,
            groupOverride: groupOverride,
            isDestinationWindowFocused: true
        )
    }

    private func draggableSectionID(for row: SidebarRow) -> TabGroupID? {
        guard canReorderSections else { return nil }
        return row.sectionID
    }

    private func draggableProjectSectionID(for row: SidebarRow) -> ProjectGroupID? {
        guard projectGroupingActive,
              case .projectHeader(let key, _, _, _, _) = row.kind else { return nil }
        return tabsModel.projectSections.first(where: { $0.id.rawValue == key })?.id
    }

    private func rowIsDraggable(_ row: SidebarRow) -> Bool {
        guard searchText.isEmpty else { return false }
        // Attention sort shows rows out of model order; a drag-commit
        // there would permute the wrong slots. Section headers stay
        // draggable (sections never visually move).
        if projectGroupingActive {
            switch row.kind {
            case .projectHeader, .flat, .windowRow:
                return true
            case .groupHeader, .gatewayHeader, .agentPane, .hiddenHeader,
                    .hiddenWindowRow:
                return false
            }
        }
        if attentionSortActive && attentionBadgesEnabled {
            return draggableSectionID(for: row) != nil
        }
        return row.isDraggable || draggableSectionID(for: row) != nil
    }

    // MARK: Context Menus

    /// Connection Info item shared by every row menu. Mirrors the top tab
    /// bar: always present, disabled when the tab has nothing to show.
    @ViewBuilder
    private func connectionInfoItem(for tab: TabModel) -> some View {
        Button {
            onShowConnectionInfo(tab)
        } label: {
            Label("Connection Info", systemImage: "info.circle")
        }
        .disabled(tab.connectionInfo == nil)
    }

    /// Transfer + theme-override items shared by every row menu, both
    /// conditional. Mirrors the top tab bar.
    @ViewBuilder
    private func transferAndThemeItems(for tab: TabModel) -> some View {
        if canTransferToNearby(tab) {
            Button {
                onTransferToNearby(tab)
            } label: {
                Label("Transfer to Nearby Device", systemImage: "ipad.and.arrow.forward")
            }
        }
        if tabHasThemeOverride(tab.id) {
            Divider()
            Button {
                onClearThemeOverride(tab.id)
            } label: {
                Label("Clear Theme Override", systemImage: "paintbrush")
            }
        }
    }

    /// Standalone external-display entries: unlike the window-transfer menu
    /// below they are offered on iPhone too, whenever a display is attached.
    @ViewBuilder
    private func externalDisplayItems(for tab: TabModel) -> some View {
        #if !targetEnvironment(macCatalyst)
        if TabTransferCoordinator.canOfferExternalDisplayTransfers,
           TabTransferCoordinator.shared.canTransfer(tab) {
            if windowId == ExternalDisplay.windowId {
                Button {
                    ExternalDisplayManager.shared.moveTabToDevice(tabID: tab.id)
                } label: {
                    Label("Move to Device", systemImage: "iphone")
                }
            } else {
                Button {
                    ExternalDisplayManager.shared.moveTabToExternal(tabID: tab.id, from: windowId)
                } label: {
                    Label("Move to External Display", systemImage: "tv")
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func moveToWindowItems(for tab: TabModel) -> some View {
        externalDisplayItems(for: tab)
        if TabTransferCoordinator.canOfferWindowTransfers,
           TabTransferCoordinator.shared.canTransfer(tab) {
            let targets = TerminalWindowRegistry.targets(excluding: windowId)
            Menu {
                ForEach(targets) { target in
                    Button {
                        _ = TabTransferCoordinator.shared.move(
                            tabID: tab.id,
                            from: windowId,
                            to: target.id,
                            isDestinationWindowFocused: false
                        )
                    } label: {
                        Label("\(target.title) (\(target.tabCount))", systemImage: "macwindow")
                    }
                }
                // No new scene can be spawned from the external window.
                if windowId != ExternalDisplay.windowId {
                    if !targets.isEmpty {
                        Divider()
                    }
                    Button {
                        onMoveTabToNewWindow(tab)
                    } label: {
                        Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
            } label: {
                Label("Move to Window", systemImage: "arrowshape.turn.up.right")
            }
        }
    }

    /// "Move to Window" for an entire group, or a whole tmux gateway (the
    /// gateway tab plus all its window tabs). Members come from
    /// `availableGroups`, which buckets by EFFECTIVE group id — so a child the
    /// user has overridden into a different group is naturally excluded.
    @ViewBuilder
    private func moveGroupToWindowItems(for groupID: TabGroupID, isGateway: Bool) -> some View {
        // Gateways move the WHOLE tmux family by owner id (hidden windows,
        // placeholders, and children the user moved into another group) so
        // tmux adoption stays coherent after the gateway's baseWindowId moves;
        // regular groups use the visible effective-group membership.
        let tabIDs: [UUID] = {
            if isGateway, let ownerID = groupID.tmuxOwnerID {
                return tabsModel.tmuxFamilyTabIDs(ownerID: ownerID)
            }
            return tabsModel.availableGroups.first(where: { $0.id == groupID })?.tabIDs ?? []
        }()
        let members = tabIDs.compactMap { tabsModel.tab(withID: $0) }
        // A single-member regular group is redundant with the per-tab "Move to
        // Window"; only offer it for multi-tab groups. Gateways always travel
        // as a unit (even with one window). `canTransferEntireBatch` keeps the
        // offer all-or-nothing — a regular group with a stray gateway-bound
        // tmux child is not offered rather than moved partially.
        if TabTransferCoordinator.canOfferWindowTransfers,
           (isGateway || members.count >= 2),
           TabTransferCoordinator.shared.canTransferEntireBatch(tabIDs, in: windowId) {
            let targets = TerminalWindowRegistry.targets(excluding: windowId)
            Menu {
                ForEach(targets) { target in
                    Button {
                        _ = TabTransferCoordinator.shared.moveTabs(
                            tabIDs,
                            from: windowId,
                            to: target.id,
                            isDestinationWindowFocused: false
                        )
                    } label: {
                        Label("\(target.title) (\(target.tabCount))", systemImage: "macwindow")
                    }
                }
                if !targets.isEmpty {
                    Divider()
                }
                Button {
                    onMoveTabsToNewWindow(tabIDs)
                } label: {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
            } label: {
                Label(
                    isGateway ? "Move Gateway to Window" : "Move Group to Window",
                    systemImage: "arrowshape.turn.up.right"
                )
            }
        }
    }

    /// Local routing for the shared tmux items' "tmux Sessions" entry: the
    /// sidebar lives in an embedded hosting controller, so the dashboard
    /// presents from a sidebar-local sheet rather than MainView's.
    private func showTmuxSessionsLocally(_ tab: TabModel) {
        guard let controller = tmuxController(tab) else { return }
        dashboardRequest = TmuxDashboardRequest(controller: controller)
    }

    private func groupHeaderRow(
        row: SidebarRow,
        groupID: TabGroupID,
        title: String,
        count: Int,
        isActive: Bool,
        collapsed: Bool,
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleGroupCollapse(groupID)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.rowIconSize - 1, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TabGroupHeaderIcon(
                groupID: groupID,
                fallbackSystemImage: groupIcon(for: groupID),
                size: metrics.rowIconSize,
                tint: isActive ? accentTint : .secondary
            )

            Text(title)
                .font(.system(size: metrics.subtitleSize + 2, weight: .semibold))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("\(count)")
                .font(.system(size: metrics.hintSize, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .frame(height: max(34, metrics.rowHeight - 10))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? accentTint.opacity(0.22) : (isActive ? accentTint.opacity(0.10) : Color.primary.opacity(0.04)))
        )
        .onTapGesture {
            highlightedRowID = row.id
            activateGroup(groupID)
        }
    }

    private func groupIcon(for groupID: TabGroupID) -> String {
        switch groupID.kind {
        case .local: return "terminal"
        case .remoteHost, .remoteDomain, .remoteNetwork: return "network"
        case .tmux: return "rectangle.stack"
        case .other: return "square.stack.3d.up"
        }
    }

    @ViewBuilder
    private func groupOverrideMenuItem(for tab: TabModel) -> some View {
        if tabsModel.isGroupedModeEnabled,
           tabsModel.tabGroupOverrides[tab.id] != nil {
            Button {
                tabsModel.clearGroupOverride(for: tab.id)
            } label: {
                Label("Move to Automatic Group", systemImage: "arrow.uturn.left")
            }
        }
    }

    /// Context menu for a regular (non-tmux) tab row.
    @ViewBuilder
    private func flatRowMenu(for tab: TabModel) -> some View {
        connectionInfoItem(for: tab)
        transferAndThemeItems(for: tab)
        moveToWindowItems(for: tab)
        groupOverrideMenuItem(for: tab)
        Divider()
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    /// Context menu for a VISIBLE tmux window row: connection info, the
    /// shared tmux admin section (rename, move to session, new tab,
    /// sessions, hide), close (configurable tmux tab-close action).
    @ViewBuilder
    private func windowRowMenu(for tab: TabModel) -> some View {
        connectionInfoItem(for: tab)
        TmuxTabMenuItems(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs,
            onNewTmuxWindow: onNewTmuxWindow,
            onShowTmuxSessions: { showTmuxSessionsLocally($0) }
        )
        transferAndThemeItems(for: tab)
        moveToWindowItems(for: tab)
        groupOverrideMenuItem(for: tab)
        Divider()
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    /// Context menu for a HIDDEN tmux window row.
    @ViewBuilder
    private func hiddenWindowRowMenu(for tab: TabModel) -> some View {
        Button {
            showHiddenWindow(tab)
        } label: {
            Label("Show Tab", systemImage: "eye")
        }
        groupOverrideMenuItem(for: tab)
        Divider()
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    /// Context menu for a gateway header: connection info, the shared tmux
    /// admin section (new tab, sessions, rename-session), then the
    /// destructive section — graceful Detach before Close.
    @ViewBuilder
    private func gatewayHeaderMenu(for tab: TabModel, ownerID: UUID) -> some View {
        connectionInfoItem(for: tab)
        TmuxTabMenuItems(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs,
            onNewTmuxWindow: onNewTmuxWindow,
            onShowTmuxSessions: { showTmuxSessionsLocally($0) }
        )
        transferAndThemeItems(for: tab)
        // Whole gateway (gateway tab + all its window tabs), not just the
        // gateway tab — moving it alone would split the live controller's
        // baseWindowId from its windows.
        moveGroupToWindowItems(for: .tmux(ownerID: ownerID), isGateway: true)
        groupOverrideMenuItem(for: tab)
        Divider()
        TmuxGatewayDetachMenuItem(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs
        )
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    /// "Hidden (N)" disclosure row at the bottom of a gateway group.
    private func hiddenGroupHeaderRow(
        isHighlighted: Bool,
        indentLevel: Int,
        ownerID: UUID,
        count: Int,
        expanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: metrics.rowIconSize - 2, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)

            Image(systemName: "eye.slash")
                .font(.system(size: metrics.rowIconSize - 1))
                .foregroundColor(.secondary)

            Text("Hidden (\(count))")
                .font(.system(size: metrics.subtitleSize + 1, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .frame(height: max(32, metrics.rowHeight - 12))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? accentTint.opacity(0.22) : .clear)
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if expanded {
                    expandedHiddenGroups.remove(ownerID)
                } else {
                    expandedHiddenGroups.insert(ownerID)
                }
            }
        }
    }

    /// Section header for the project-grouped inbox.
    ///
    /// While COLLAPSED the chevron gives way to the section's worst attention
    /// state, so a folded project still tells you something needs you rather
    /// than hiding it. Colour is state only, never project identity: there is
    /// no per-project hue or generated icon anywhere in this UI.
    /// (id=agent-project)
    private func projectHeaderRow(
        key: String,
        title: String,
        count: Int,
        collapsed: Bool,
        rollup: AgentAttentionStatus?,
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if collapsed, let rollup, rollup != .idle {
                    AttentionStatusDotView(status: rollup, size: 8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: metrics.rowIconSize - 2, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
            }
            .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)

            Image(systemName: "folder")
                .font(.system(size: metrics.rowIconSize - 1))
                .foregroundColor(.secondary)

            Text(title)
                .font(.system(size: metrics.subtitleSize + 1, weight: .semibold))
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text("\(count)")
                .font(.system(size: metrics.subtitleSize, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .frame(height: max(32, metrics.rowHeight - 12))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? accentTint.opacity(0.22) : .clear)
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if collapsed {
                    collapsedProjects.remove(key)
                } else {
                    collapsedProjects.insert(key)
                }
            }
        }
    }

    /// Live reorder while hovering. A regular (.local) tab moves freely among
    /// the sidebar's TOP-LEVEL rows (flat tabs + gateway headers), so it can
    /// cross tmux gateway GROUPS — matching the top tab bar (raw array move;
    /// dropping onto a gateway header lands above/below the whole group by drag
    /// direction). A tmux window tab reorders only within its gateway's
    /// siblings. Local-only; the server commit happens once at drop.
    private func handleDragEntered(targetRowID: String, rows: [SidebarRow]) {
        if let movingProjectID = tabsModel.draggingProjectGroupID {
            guard let target = rows.first(where: { $0.id == targetRowID }),
                  case .projectHeader(let key, _, _, _, _) = target.kind,
                  let targetID = tabsModel.projectSections.first(where: { $0.id.rawValue == key })?.id
            else { return }
            tabsModel.moveProjectSection(movingProjectID, to: targetID)
            return
        }

        if let draggingSectionID {
            handleSectionDragEntered(
                draggingSectionID: draggingSectionID,
                targetRowID: targetRowID,
                rows: rows
            )
            return
        }

        guard let draggingID = draggingRowID,
              let source = rows.first(where: { $0.tab.id == draggingID && $0.dragClass != .none }),
              let target = rows.first(where: { $0.id == targetRowID }),
              target.tab.id != draggingID
        else { return }

        if projectGroupingActive {
            switch target.kind {
            case .flat, .windowRow:
                _ = tabsModel.moveTabInProjectOrder(
                    movingID: draggingID,
                    toTargetID: target.tab.id
                )
            case .groupHeader, .gatewayHeader, .agentPane, .hiddenHeader,
                    .hiddenWindowRow, .projectHeader:
                break
            }
            return
        }

        if tabsModel.isGroupedModeEnabled,
           case .groupHeader(let groupID, _, _, _, _) = target.kind {
            let targetID = firstMoveTarget(inGroup: groupID, excluding: draggingID)
            tabsModel.setGroupOverride(for: draggingID, to: groupID)
            dragAssignedGroup = true
            if let targetID {
                moveDraggedTab(draggingID, near: targetID)
            }
            return
        }

        if tabsModel.isGroupedModeEnabled,
           let targetGroup = tabsModel.effectiveGroupID(for: target.tab),
           tabsModel.effectiveGroupID(for: source.tab) != targetGroup {
            tabsModel.setGroupOverride(for: draggingID, to: targetGroup)
            dragAssignedGroup = true
            if source.dragClass == .local,
               let from = tabsModel.index(of: draggingID),
               let to = tabsModel.index(of: target.tab.id),
               from != to {
                onMoveTab(from, to)
            }
            return
        }

        switch source.dragClass {
        case .none:
            return

        case .window:
            // tmux window tabs reorder only within their own gateway's
            // siblings (server-routed at drop). Cross-class targets ignored.
            guard target.dragClass == source.dragClass else { return }
            var orderedIDs = rows.filter { $0.dragClass == source.dragClass }.map(\.tab.id)
            guard let from = orderedIDs.firstIndex(of: draggingID),
                  let to = orderedIDs.firstIndex(of: target.tab.id),
                  from != to else { return }
            let moved = orderedIDs.remove(at: from)
            orderedIDs.insert(moved, at: to)
            onReorderClass(orderedIDs, draggingID)

        case .local:
            if tabsModel.isGroupedModeEnabled {
                switch target.kind {
                case .flat, .gatewayHeader, .windowRow:
                    moveDraggedTab(draggingID, near: target.tab.id)
                case .groupHeader, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader:
                    return
                }
                return
            }

            // Only top-level rows are drop targets. Inside-group rows (window
            // rows, the "Hidden (N)" disclosure, hidden window rows) are
            // hoisted under their gateway in buildRows() regardless of raw
            // array order, so their raw index doesn't match their visual
            // position — using it would land the tab outside the row the user
            // targeted (and the disclosure/header share a UUID). The gateway
            // header alone reaches both sides of the group via drag direction.
            switch target.kind {
            case .flat, .gatewayHeader:
                break
            case .groupHeader, .windowRow, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader:
                return
            }
            // Live indices from the model (robust to a stale captured `rows`);
            // the drop commit's tmux sync is a no-op for a non-window tab.
            moveDraggedTab(draggingID, near: target.tab.id)
        }
    }

    private func handleSectionDragEntered(
        draggingSectionID: String,
        targetRowID: String,
        rows: [SidebarRow]
    ) {
        guard tabsModel.isGroupedModeEnabled,
              canReorderSections,
              let target = rows.first(where: { $0.id == targetRowID }),
              let targetSectionID = containingSectionID(for: target)?.rawValue,
              targetSectionID != draggingSectionID else { return }

        let knownGroups = tabsModel.orderedGroups.map { $0.id.rawValue }
        guard let from = knownGroups.firstIndex(of: draggingSectionID),
              let to = knownGroups.firstIndex(of: targetSectionID),
              from != to else { return }

        var nextOrder = knownGroups
        let moved = nextOrder.remove(at: from)
        nextOrder.insert(moved, at: to)

        withAnimation(.snappy(duration: 0.22, extraBounce: 0.0)) {
            tabsModel.sidebarGroupOrder = nextOrder
        }
        saveGroupOrder(nextOrder)
    }

    private func containingSectionID(for row: SidebarRow) -> TabGroupID? {
        if let sectionID = row.sectionID {
            return sectionID
        }
        return tabsModel.effectiveGroupID(for: row.tab)
    }

    private func firstMoveTarget(inGroup groupID: TabGroupID, excluding draggingID: UUID) -> UUID? {
        guard let group = tabsModel.availableGroups.first(where: { $0.id == groupID }) else { return nil }
        if groupID.kind == .tmux,
           let gatewayID = group.tabIDs.first(where: { id in
               guard id != draggingID, let tab = tabsModel.tab(withID: id) else { return false }
               return tab.isTmuxGateway
           }) {
            return gatewayID
        }
        return group.tabIDs.first { $0 != draggingID }
    }

    private func moveDraggedTab(_ draggingID: UUID, near targetID: UUID) {
        guard let from = tabsModel.index(of: draggingID),
              let to = tabsModel.index(of: targetID),
              from != to else { return }
        onMoveTab(from, to)
    }

    @discardableResult
    private func completeDrag() -> Bool {
        cancelDragStateExpiration()
        if tabsModel.draggingProjectGroupID != nil {
            tabsModel.draggingProjectGroupID = nil
            draggingSectionID = nil
            draggingRowID = nil
            dragAssignedGroup = false
            TabTransferCoordinator.shared.clearDrag()
            return true
        }
        if draggingSectionID != nil {
            draggingSectionID = nil
            draggingRowID = nil
            dragAssignedGroup = false
            TabTransferCoordinator.shared.clearDrag()
            return true
        }
        guard let draggingID = draggingRowID else { return false }
        draggingRowID = nil
        let shouldCommitTmuxOrder = !dragAssignedGroup
        dragAssignedGroup = false
        if shouldCommitTmuxOrder {
            onReorderEnded(draggingID)
        }
        TabTransferCoordinator.shared.clearDrag()
        return true
    }

    private func shortcutHint(for flatIndex: Int) -> String? {
        guard showTabShortcutIndicators, flatIndex >= 0, flatIndex < 9 else { return nil }
        return "\u{2318}\(flatIndex + 1)"
    }

    /// Shortcut hint for a sidebar row, or nil when none should be shown.
    /// In grouped mode the live ⌘1–9 key commands map to `navigationTabs`
    /// (the active group only), so showing per-group hints on inactive groups
    /// produces duplicate, non-functional indicators. Suppress those.
    private func shortcutHint(for row: SidebarRow) -> String? {
        guard !row.isHiddenKind else { return nil }
        if projectGroupingActive {
            guard let index = tabsModel.navigationIndex(of: row.tab.id) else { return nil }
            return shortcutHint(for: index)
        }
        if tabsModel.isGroupedModeEnabled,
           let activeGroup = tabsModel.activeGroupID,
           let groupID = tabsModel.effectiveGroupID(for: row.tab),
           groupID != activeGroup {
            return nil
        }
        return shortcutHint(for: sidebarShortcutIndex(for: row.tab) ?? row.flatIndex)
    }

    private func sidebarShortcutIndex(for tab: TabModel) -> Int? {
        if projectGroupingActive {
            return tabsModel.navigationIndex(of: tab.id)
        }
        guard tabsModel.isGroupedModeEnabled,
              let groupID = tabsModel.effectiveGroupID(for: tab),
              let group = tabsModel.availableGroups.first(where: { $0.id == groupID }) else {
            return tabsModel.visibleIndex(of: tab.id)
        }

        return group.tabIDs
            .compactMap { tabsModel.tab(withID: $0) }
            .filter { !$0.isHiddenTmuxWindow }
            .firstIndex(where: { $0.id == tab.id })
    }

    // MARK: Gateway Header Row

    /// Concrete return type (not `some View`) so the live-row call site can
    /// apply `.equatable()` while the drag preview skips it.
    private func gatewayHeaderRow(
        row: SidebarRow,
        isSelected: Bool,
        isHighlighted: Bool,
        collapsed: Bool,
        windowCount: Int,
        ownerID: UUID,
        gatewayOwnerIDs: [UUID]
    ) -> SidebarGatewayHeaderItem {
        let controller = tmuxController(row.tab)
        let isActive = tabsModel.effectiveGroupID(for: tabsModel.selectedTab) == .tmux(ownerID: ownerID)
        return SidebarGatewayHeaderItem(
            tab: row.tab,
            tmuxBadge: TmuxTabBadgeResolver.badge(for: row.tab, gatewayOwnerIDs: gatewayOwnerIDs),
            // TmuxController is not observable, so this is a plain read and is
            // safe to resolve at parent scope and compare in `==`.
            host: controller?.connectionKey ?? controller?.gatewaySourceDisplayName,
            collapsed: collapsed,
            windowCount: windowCount,
            isSelected: isSelected,
            isActive: isActive,
            isHighlighted: isHighlighted,
            indentLevel: row.indentLevel,
            metrics: metrics,
            accentTint: accentTint,
            onToggleCollapse: { toggleGatewayCollapse(ownerID) },
            onNewWindow: { onNewTmuxWindow(row.tab) },
            onShowDashboard: {
                if let controller {
                    dashboardRequest = TmuxDashboardRequest(controller: controller)
                }
            },
            onClose: { onCloseTab(row.tab.id) },
            onTap: {
                highlightedRowID = row.id
                // Tapping a hidden gateway's header shows + selects it,
                // mirroring hidden window rows. (id=tmux-hidden-gateway)
                if row.tab.isHiddenTmuxWindow {
                    showHiddenGateway(row.tab)
                } else {
                    onSelectTab(row.tab.id)
                }
                // See the tab row's tap: skip the re-anchor when selecting will
                // dismiss the panel (phone/visionOS), and when docked (the
                // terminal beside the column takes focus; empty-space tap
                // drives arrow-nav).
                if staysOpenOnSelect && !isDocked {
                    requestSearchFocus()
                }
            }
        )
    }

    // MARK: Grouping

    private func buildRows() -> [SidebarRow] {
        // Project mode always builds from the FLAT tab list: grouped mode can
        // scope the list to the active group, which would silently hide agents
        // in other groups from an inbox that claims to show them all.
        let baseRows = tabsModel.isGroupedModeEnabled && !projectGroupingActive
            ? buildGroupedRows()
            : buildRows(from: tabsModel.tabs)
        let projectSearchActive = projectGroupingActive && !normalizedSearchFilter.isEmpty
        let rows = projectGroupingActive && !projectSearchActive
            ? baseRows
            : addingAgentPaneChildren(
                to: baseRows,
                omitNonmatchingParents: projectSearchActive)
        // Rows carry .contextMenu / .onDrag, so a duplicate id in `ForEach(rows)`
        // is a display-list identity collision SwiftUI kills the app over. Two
        // gateway tabs resolving to the same ownerID each re-emit that owner's
        // whole window list, so keep the first row per id.
        var seen = Set<String>()
        var result = rows.filter { seen.insert($0.id).inserted }
        if projectGroupingActive {
            return applyProjectGrouping(result)
        }
        if attentionSortActive && attentionBadgesEnabled {
            result = Self.applyAttentionSort(result)
        }
        return result
    }

    /// Rebuilds the list from the same stable project projection used by the
    /// top bar. A tab has one primary project row; additional agent panes may
    /// appear under their own projects without duplicating the tab itself.
    private func applyProjectGrouping(_ rows: [SidebarRow]) -> [SidebarRow] {
        guard searchText.isEmpty else { return rows }
        let sections = tabsModel.projectSections
        guard sections.contains(where: { !$0.id.isOther }) else { return rows }
        var result: [SidebarRow] = []
        for project in sections {
            var sectionRows: [SidebarRow] = []
            var seenRows = Set<String>()

            for tabID in project.tabIDs {
                guard let tab = tabsModel.tab(withID: tabID),
                      !tab.isHiddenTmuxWindow else { continue }
                let flatIndex = tabsModel.index(of: tab.id) ?? 0
                let kind: RowKind = tab.isTmuxWindow ? .windowRow : .flat
                let parent = SidebarRow(tab: tab, kind: kind, flatIndex: flatIndex, indentLevel: 1)
                if seenRows.insert(parent.id).inserted {
                    sectionRows.append(parent)
                }
            }

            // Pane rows keep pane navigation available for multi-project split
            // tabs, but the action-bearing parent remains only in its primary
            // project so top/sidebar tab order stays duplicate-free.
            for tab in tabsModel.visibleTabs where tab.splitTree.count > 1 {
                let flatIndex = tabsModel.index(of: tab.id) ?? 0
                for paneID in tab.agentPaneIDs where
                    tabsModel.projectGroupID(forPane: paneID, in: tab) == project.id {
                    let paneRow = SidebarRow(
                        tab: tab,
                        kind: .agentPane(paneID: paneID),
                        flatIndex: flatIndex,
                        indentLevel: 2
                    )
                    if seenRows.insert(paneRow.id).inserted {
                        sectionRows.append(paneRow)
                    }
                }
            }

            guard let carrier = sectionRows.first else { continue }
            let key = project.id.rawValue
            let collapsed = collapsedProjects.contains(key)
            let uniqueTabCount = Set(sectionRows.map { $0.tab.id }).count
            result.append(
                SidebarRow(
                    tab: carrier.tab,
                    kind: .projectHeader(
                        key: key,
                        title: project.title,
                        count: uniqueTabCount,
                        collapsed: collapsed,
                        rollup: Self.sectionRollup(sectionRows)),
                    flatIndex: carrier.flatIndex))
            if !collapsed { result.append(contentsOf: sectionRows) }
        }
        return result
    }

    /// Worst attention state inside a section, so a collapsed one still
    /// reports that something needs the user.
    private static func sectionRollup(_ rows: [SidebarRow]) -> AgentAttentionStatus? {
        let statuses = rows.compactMap { row in
            attentionStatus(for: row)
        }
        return statuses.isEmpty ? nil : AgentAttentionStatus.worst(of: statuses)
    }

    private enum AttentionSortSection: Equatable {
        case flat(indent: Int)
        case window(ownerID: UUID?, indent: Int)
        case hiddenWindow(ownerID: UUID?, indent: Int)
    }

    private struct AttentionSortBlock {
        let section: AttentionSortSection
        let originalOffset: Int
        let parent: SidebarRow
        let children: [SidebarRow]
    }

    /// Visual-only attention sort. Sort action-bearing TAB blocks within each
    /// structural section, keeping a multi-pane tab's child cards attached to
    /// their parent. This covers the normal single-pane case as well as split
    /// tabs, grouped sections, and tmux window runs.
    private static func applyAttentionSort(_ rows: [SidebarRow]) -> [SidebarRow] {
        var result: [SidebarRow] = []
        var index = 0

        while index < rows.count {
            guard let firstSection = attentionSortSection(for: rows[index]) else {
                result.append(rows[index])
                index += 1
                continue
            }

            var blocks: [AttentionSortBlock] = []
            while index < rows.count,
                  attentionSortSection(for: rows[index]) == firstSection {
                let parent = rows[index]
                let originalOffset = blocks.count
                index += 1

                var children: [SidebarRow] = []
                while index < rows.count,
                      case .agentPane = rows[index].kind,
                      rows[index].tab.id == parent.tab.id {
                    children.append(rows[index])
                    index += 1
                }
                children = children.enumerated()
                    .sorted { lhs, rhs in
                        let left = attentionSortKey(for: lhs.element)
                        let right = attentionSortKey(for: rhs.element)
                        return left == right ? lhs.offset < rhs.offset : left > right
                    }
                    .map(\.element)
                blocks.append(AttentionSortBlock(
                    section: firstSection,
                    originalOffset: originalOffset,
                    parent: parent,
                    children: children
                ))
            }

            blocks.sort { lhs, rhs in
                let left = attentionSortKey(for: lhs.parent)
                let right = attentionSortKey(for: rhs.parent)
                return left == right
                    ? lhs.originalOffset < rhs.originalOffset
                    : left > right
            }
            for block in blocks {
                result.append(block.parent)
                result.append(contentsOf: block.children)
            }
        }

        return result
    }

    private static func attentionSortSection(for row: SidebarRow) -> AttentionSortSection? {
        switch row.kind {
        case .flat:
            return .flat(indent: row.indentLevel)
        case .windowRow:
            return .window(ownerID: row.tab.owningGatewayTerminalUUID, indent: row.indentLevel)
        case .hiddenWindowRow:
            return .hiddenWindow(ownerID: row.tab.owningGatewayTerminalUUID, indent: row.indentLevel)
        default:
            return nil
        }
    }

    private static func attentionStatus(for row: SidebarRow) -> AgentAttentionStatus? {
        switch row.kind {
        case .agentPane(let paneID):
            return row.tab.splitTree.first(where: { $0.uuid == paneID })?.presentation.attentionStatus
        case .flat, .windowRow:
            if row.tab.splitTree.count == 1 {
                return row.tab.splitTree.first?.presentation.attentionStatus
            }
            return row.tab.attentionBadge
        default:
            return nil
        }
    }

    private static func attentionSortKey(for row: SidebarRow) -> (Int, UInt64) {
        let status = attentionStatus(for: row)
        let sequence: UInt64
        if case .agentPane(let paneID) = row.kind {
            sequence = row.tab.splitTree
                .first(where: { $0.uuid == paneID })?
                .presentation.agentRow?.stateChangeSeq ?? 0
        } else {
            sequence = row.tab.agentRow?.stateChangeSeq ?? 0
        }
        return (status?.attentionPriority ?? 0, sequence)
    }

    private func addingAgentPaneChildren(
        to rows: [SidebarRow],
        omitNonmatchingParents: Bool = false
    ) -> [SidebarRow] {
        guard attentionBadgesEnabled else { return rows }

        var result: [SidebarRow] = []
        result.reserveCapacity(rows.count + tabsModel.tabs.reduce(0) { $0 + $1.agentPaneIDs.count })

        for row in rows {
            switch row.kind {
            case .flat, .windowRow:
                guard row.tab.splitTree.count > 1 else {
                    result.append(row)
                    continue
                }
                let parentMatches = searchFilterMatchesTabTitle(row.tab)
                let paneIDs = row.tab.agentPaneIDs.filter { paneID in
                    normalizedSearchFilter.isEmpty
                        || parentMatches
                        || searchFilterMatchesPane(row.tab, paneID: paneID)
                }
                if !omitNonmatchingParents || parentMatches || paneIDs.isEmpty {
                    result.append(row)
                }
                for paneID in paneIDs {
                    result.append(SidebarRow(
                        tab: row.tab,
                        kind: .agentPane(paneID: paneID),
                        flatIndex: row.flatIndex,
                        indentLevel: row.visualIndentLevel + 1
                    ))
                }
            default:
                result.append(row)
            }
        }
        return result
    }

    private func buildGroupedRows() -> [SidebarRow] {
        let tabs = tabsModel.tabs
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let groups = tabsModel.orderedGroups
        let isFiltering = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        var rows: [SidebarRow] = []

        for group in groups {
            let groupTabs = group.tabIDs.compactMap { byID[$0] }
            if group.id.kind == .tmux,
               let ownerID = UUID(uuidString: group.id.value) {
                rows.append(contentsOf: buildTmuxGatewayGroupRows(from: groupTabs, ownerID: ownerID))
                continue
            }

            let groupRows = buildRows(from: groupTabs).map { $0.indented() }
            let collapsed = !isFiltering && collapsedGroups.contains(group.id.rawValue)
            guard !groupRows.isEmpty,
                  let headerTab = groupTabs.first,
                  let flatIndex = tabsModel.index(of: headerTab.id) else { continue }

            rows.append(SidebarRow(
                tab: headerTab,
                kind: .groupHeader(
                    groupID: group.id,
                    title: group.title,
                    count: groupTabs.filter { !$0.isHiddenTmuxWindow }.count,
                    isActive: tabsModel.activeGroupID == group.id,
                    collapsed: collapsed
                ),
                flatIndex: flatIndex
            ))
            if !collapsed {
                rows.append(contentsOf: groupRows)
            }
        }

        return rows
    }

    private func saveGroupOrder(_ order: [String]? = nil) {
        let nextOrder = order ?? tabsModel.sidebarGroupOrder
        tabsModel.sidebarGroupOrder = nextOrder
        TabSidebarGroupOrderStore.save(nextOrder, windowId: windowId)
    }

    private func loadGroupOrder() {
        guard tabsModel.sidebarGroupOrder.isEmpty else { return }
        tabsModel.sidebarGroupOrder = TabSidebarGroupOrderStore.load(windowId: windowId)
    }

    private var normalizedSearchFilter: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func searchFilterMatchesTabTitle(_ tab: TabModel) -> Bool {
        let filter = normalizedSearchFilter
        return filter.isEmpty || tab.title.lowercased().contains(filter)
    }

    private func searchFilterMatchesPane(_ tab: TabModel, paneID: UUID) -> Bool {
        let filter = normalizedSearchFilter
        guard !filter.isEmpty,
              let pane = tab.splitTree.first(where: { $0.uuid == paneID })
        else { return filter.isEmpty }
        let presentation = pane.presentation
        let row = presentation.agentRow
        let values = [
            presentation.title,
            row?.agentDisplayName,
            row?.agentID,
            row?.project?.label,
            row?.project?.branch,
        ]
        return values.compactMap { $0 }.contains { $0.lowercased().contains(filter) }
    }

    private func searchFilterMatches(_ tab: TabModel) -> Bool {
        searchFilterMatchesTabTitle(tab)
            || tab.agentPaneIDs.contains { searchFilterMatchesPane(tab, paneID: $0) }
    }

    private func buildTmuxGatewayGroupRows(from tabs: [TabModel], ownerID: UUID) -> [SidebarRow] {
        let filter = normalizedSearchFilter
        let isFiltering = !filter.isEmpty

        func matches(_ tab: TabModel) -> Bool {
            !isFiltering || searchFilterMatches(tab)
        }

        guard let gateway = tabs.first(where: { $0.isTmuxGateway && TmuxTabBadgeResolver.ownerID(for: $0) == ownerID }),
              let gatewayFlatIndex = tabsModel.index(of: gateway.id) else {
            return buildRows(from: tabs)
        }

        let visibleChildren = tabs.filter { tab in
            guard tab.id != gateway.id, !tab.isHiddenTmuxWindow else { return false }
            if tab.isTmuxWindow {
                return tab.owningGatewayTerminalUUID == ownerID
            }
            return true
        }
        let hiddenWindows = tabs.filter { tab in
            tab.isTmuxWindow && tab.isHiddenTmuxWindow && tab.owningGatewayTerminalUUID == ownerID
        }
        let matchingChildren = visibleChildren.filter(matches)
        let matchingHidden = hiddenWindows.filter(matches)
        let headerMatches = matches(gateway)

        if isFiltering && !headerMatches && matchingChildren.isEmpty && matchingHidden.isEmpty {
            return []
        }

        let collapsed = !isFiltering && collapsedGateways.contains(ownerID)
        var rows = [
            SidebarRow(
                tab: gateway,
                kind: .gatewayHeader(collapsed: collapsed, windowCount: visibleChildren.filter(\.isTmuxWindow).count, ownerID: ownerID),
                flatIndex: gatewayFlatIndex
            )
        ]

        guard !collapsed else { return rows }

        let shownChildren = isFiltering ? (headerMatches ? visibleChildren : matchingChildren) : visibleChildren
        for child in shownChildren {
            guard let flatIndex = tabsModel.index(of: child.id) else { continue }
            rows.append(SidebarRow(
                tab: child,
                kind: child.isTmuxWindow ? .windowRow : .flat,
                flatIndex: flatIndex,
                indentLevel: child.isTmuxWindow ? 0 : 1
            ))
        }

        let shownHidden = isFiltering ? (headerMatches ? hiddenWindows : matchingHidden) : hiddenWindows
        if !shownHidden.isEmpty {
            let expanded = isFiltering || expandedHiddenGroups.contains(ownerID)
            rows.append(SidebarRow(
                tab: gateway,
                kind: .hiddenHeader(ownerID: ownerID, count: shownHidden.count, expanded: expanded),
                flatIndex: gatewayFlatIndex
            ))
            if expanded {
                for hidden in shownHidden {
                    guard let flatIndex = tabsModel.index(of: hidden.id) else { continue }
                    rows.append(SidebarRow(tab: hidden, kind: .hiddenWindowRow, flatIndex: flatIndex))
                }
            }
        }

        return rows
    }

    private func buildRows(from tabs: [TabModel]) -> [SidebarRow] {
        let filter = normalizedSearchFilter
        let isFiltering = !filter.isEmpty

        // Gateway owner UUID → gateway tab id, in tab order.
        var gatewayByOwner: [UUID: TabModel] = [:]
        for tab in tabs where tab.isTmuxGateway {
            if let ownerID = TmuxTabBadgeResolver.ownerID(for: tab) {
                gatewayByOwner[ownerID] = tab
            }
        }

        // Bucket window tabs under their gateway, preserving array order
        // (already index-sorted by the controller's reconcile). Window tabs
        // are NOT guaranteed contiguous after their gateway, so bucket by
        // UUID rather than walking a span. Orphans (owner not present, e.g.
        // restored placeholders whose gateway hasn't resumed) render flat.
        var windowsByOwner: [UUID: [TabModel]] = [:]
        for tab in tabs where tab.isTmuxWindow {
            if let owner = tab.owningGatewayTerminalUUID, gatewayByOwner[owner] != nil {
                windowsByOwner[owner, default: []].append(tab)
            }
        }

        func matches(_ tab: TabModel) -> Bool {
            !isFiltering || searchFilterMatches(tab)
        }

        var rows: [SidebarRow] = []
        for tab in tabs {
            if tab.isTmuxWindow,
               let owner = tab.owningGatewayTerminalUUID,
               gatewayByOwner[owner] != nil {
                // Emitted with its gateway group below.
                continue
            }

            guard let flatIndex = tabsModel.index(of: tab.id) else { continue }

            if tab.isTmuxGateway, let ownerID = TmuxTabBadgeResolver.ownerID(for: tab) {
                let allWindows = windowsByOwner[ownerID] ?? []
                // Hidden windows render in their own disclosure group, not
                // among the normal window rows. (id=tmux-hidden-windows)
                let windows = allWindows.filter { !$0.isHiddenTmuxWindow }
                let hiddenWindows = allWindows.filter { $0.isHiddenTmuxWindow }
                let matchingWindows = windows.filter(matches)
                let matchingHidden = hiddenWindows.filter(matches)
                let headerMatches = matches(tab)

                if isFiltering && !headerMatches && matchingWindows.isEmpty && matchingHidden.isEmpty { continue }

                // While filtering, groups auto-expand to show matches.
                let collapsed = !isFiltering && collapsedGateways.contains(ownerID)
                rows.append(SidebarRow(
                    tab: tab,
                    kind: .gatewayHeader(collapsed: collapsed, windowCount: windows.count, ownerID: ownerID),
                    flatIndex: flatIndex
                ))

                if !collapsed {
                    // A filter hit on the gateway itself reveals the whole
                    // group; otherwise only the matching windows.
                    let shownWindows = isFiltering ? (headerMatches ? windows : matchingWindows) : windows
                    for window in shownWindows {
                        guard let windowFlatIndex = tabsModel.index(of: window.id) else { continue }
                        rows.append(SidebarRow(tab: window, kind: .windowRow, flatIndex: windowFlatIndex))
                    }

                    // "Hidden (N)" disclosure, then the hidden rows when
                    // expanded. Filtering reveals matching hidden rows
                    // directly (the disclosure auto-expands like the groups).
                    let shownHidden = isFiltering ? (headerMatches ? hiddenWindows : matchingHidden) : hiddenWindows
                    if !shownHidden.isEmpty {
                        let expanded = isFiltering || expandedHiddenGroups.contains(ownerID)
                        rows.append(SidebarRow(
                            tab: tab,
                            kind: .hiddenHeader(ownerID: ownerID, count: shownHidden.count, expanded: expanded),
                            flatIndex: flatIndex
                        ))
                        if expanded {
                            for window in shownHidden {
                                guard let windowFlatIndex = tabsModel.index(of: window.id) else { continue }
                                rows.append(SidebarRow(tab: window, kind: .hiddenWindowRow, flatIndex: windowFlatIndex))
                            }
                        }
                    }
                }
            } else {
                // Orphaned hidden placeholders (gateway not resumed yet)
                // would otherwise fall through to a flat row; keep them out
                // of the list until their gateway adopts them. A hidden
                // GATEWAY that failed ownerID resolution must still render,
                // though — the sidebar is its only recovery affordance.
                // (id=tmux-hidden-gateway)
                guard matches(tab), !tab.isHiddenTmuxWindow || tab.isTmuxGateway else { continue }
                rows.append(SidebarRow(tab: tab, kind: .flat, flatIndex: flatIndex))
            }
        }
        return rows
    }

}

// MARK: - Drag & Drop Reorder

/// Attaches system drag-and-drop only to draggable rows. System DnD (the
/// top tab bar's mechanism) coexists with scrolling: the lift gesture needs
/// a press-and-hold, so vertical pans scroll the list normally.
private struct SidebarRowDragModifier<DragPreview: View>: ViewModifier {
    let isDraggable: Bool
    let usesCustomPreview: Bool
    let onDragStarted: () -> NSItemProvider
    let dropDelegate: SidebarRowDropDelegate
    @ViewBuilder let dragPreview: () -> DragPreview

    func body(content: Content) -> some View {
        if isDraggable {
            if usesCustomPreview {
                content
                    .onDrag {
                        onDragStarted()
                    } preview: {
                        dragPreview()
                    }
                    .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
            } else {
                content
                    .onDrag { onDragStarted() }
                    .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
            }
        } else {
            // Non-draggable rows still take drops so releasing over them
            // commits the arrangement (the delegate validates the class on
            // dropEntered, so they never become reorder targets).
            content
                .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
        }
    }
}

private struct SidebarRowDropDelegate: DropDelegate {
    /// The hovered row's DISAMBIGUATED id (SidebarRow.id), so the handler can
    /// tell the gateway header apart from its "Hidden (N)" disclosure (both
    /// reuse the gateway tab's UUID).
    let targetRowID: String
    let onEntered: @MainActor (String) -> Void
    let onPerform: @MainActor () -> Bool

    @MainActor
    func dropEntered(info: DropInfo) {
        onEntered(targetRowID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    @MainActor
    func performDrop(info: DropInfo) -> Bool {
        onPerform()
    }
}

private struct SidebarContainerDropDelegate: DropDelegate {
    let onPerform: @MainActor () -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    @MainActor
    func performDrop(info: DropInfo) -> Bool {
        onPerform()
    }
}

// MARK: - Sidebar Tab Row
//
// One `SidebarTabRowItem` is rendered per tab inside the sidebar's `ForEach`.
// Per-tab reads on the `@Observable TabModel` (`title`, `activeRoamProtocol`,
// `agentRow`, `attentionBadge`) happen HERE, so SwiftUI scopes their
// Observation to this single instance. A title or agent-state update on tab N
// invalidates only `SidebarTabRowItem(tab: N).body` — its siblings and, more
// importantly, `VerticalTabSidebar.body` itself stay stable.
//
// That parent stability is the whole point: the row's `.contextMenu` is
// attached in the parent's `rowView`, so a parent render recreates the menu's
// content closure. Agent TUIs animate a braille spinner in their OSC 0/2
// title, which used to re-evaluate the entire sidebar body several times a
// second and rebuild every menu underneath a presented one — the context menu
// visibly pulsed in step with the agent. Mirrors `TabBarItem` in TabBar.swift,
// which fixed the same problem for the top tab bar.
private struct SidebarTabRowItem: View, Equatable {
    let tab: TabModel
    /// Resolved tmux gateway/window badge, precomputed at parent scope from the
    /// live gateway ordering (`TmuxTabBadgeResolver.badge(for:gatewayOwnerIDs:)`).
    /// Stored — rather than derived in `body` from an `allTabs` array — for two
    /// reasons: `==` can compare it directly, so a reorder that recolors the
    /// badge (its order-derived `groupIndex`) can't go stale behind the
    /// equality short-circuit; and deriving it here would walk every tab's
    /// split tree per row, which is both O(n^2) and a fresh Observation
    /// dependency on every other tab.
    let tmuxBadge: TmuxTabBadge?
    /// The agent-badges preference. Passed as a value rather than redeclared as
    /// `@AppStorage` in every row instance, and compared so turning badges off
    /// collapses the cards immediately.
    let attentionBadgesEnabled: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let shortcutHint: String?
    let metrics: SidebarMetrics
    let accentTint: Color
    let onClose: () -> Void

    // Equality gates *parent-driven* re-evaluation only. It does NOT suppress
    // @Observable-driven invalidation: the body reads `tab.title` /
    // `tab.activeRoamProtocol` / `tab.agentRow` / `tab.attentionBadge` and
    // those still update this row live. So `==` deliberately ignores both the
    // closure and those observed properties — comparing only the inputs that
    // change a row's appearance from the parent's side.
    //
    // Two deliberate divergences from `TabBarItem`:
    //  - No `index` field. TabBarItem needs one because its `onTap`/`onClose`
    //    capture the raw array index; here `onClose` captures `tab.id`, which
    //    is identity-stable, and the drag/drop delegates that do care about
    //    position stay at parent scope.
    //  - No `tmuxBadgeColor` field. TabBar threads a resolved theme value, but
    //    the sidebar passes `.currentTheme`, which reads the @Observable
    //    ThemeManager inside this body — so a palette change invalidates this
    //    row on its own and needs no equality input.
    static func == (lhs: SidebarTabRowItem, rhs: SidebarTabRowItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.tmuxBadge == rhs.tmuxBadge
            && lhs.attentionBadgesEnabled == rhs.attentionBadgesEnabled
            && lhs.isSelected == rhs.isSelected
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.indentLevel == rhs.indentLevel
            && lhs.shortcutHint == rhs.shortcutHint
            && lhs.metrics == rhs.metrics
            && lhs.accentTint == rhs.accentTint
    }

    var body: some View {
        // Preserve the compact single-pane card. Once a tab is split, the
        // parent becomes a stable rollup row and each agent gets its own
        // pane-scoped child card below it.
        let solePane = tab.splitTree.count == 1 ? tab.splitTree.first : nil
        let agentRow: AgentRowState? = attentionBadgesEnabled ? solePane?.presentation.agentRow : nil
        SidebarTabRow(
            title: tab.title,
            roamProtocol: tab.activeRoamProtocol,
            tmuxBadge: tmuxBadge,
            tmuxBadgePalette: .currentTheme,
            agentRow: agentRow,
            attentionBadge: attentionBadgesEnabled ? tab.attentionBadge : nil,
            // Card footer context: the project the engine resolved for the pane
            // that actually owns the agent (the old code read the FOCUSED
            // pane's pwd, so a split could describe one pane and show another
            // pane's directory). nil collapses the footer text rather than
            // showing a placeholder. (id=agent-project)
            contextLine: agentRow?.project,
            isSelected: isSelected,
            isHighlighted: isHighlighted,
            indentLevel: indentLevel,
            shortcutHint: shortcutHint,
            metrics: metrics,
            accentTint: accentTint,
            showsCloseButton: true,
            onClose: onClose
        )
    }
}

/// Pane-scoped card for a multi-pane tab. Its observed reads live here so a
/// spinner/title update invalidates only this card, not the sidebar hierarchy.
private struct SidebarPaneRowItem: View, Equatable {
    let tab: TabModel
    let paneID: UUID
    let attentionBadgesEnabled: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let metrics: SidebarMetrics
    let accentTint: Color

    static func == (lhs: SidebarPaneRowItem, rhs: SidebarPaneRowItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.paneID == rhs.paneID
            && lhs.attentionBadgesEnabled == rhs.attentionBadgesEnabled
            && lhs.isSelected == rhs.isSelected
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.indentLevel == rhs.indentLevel
            && lhs.metrics == rhs.metrics
            && lhs.accentTint == rhs.accentTint
    }

    var body: some View {
        if let pane = tab.splitTree.first(where: { $0.uuid == paneID }) {
            let presentation = pane.presentation
            let agentRow = attentionBadgesEnabled ? presentation.agentRow : nil
        let paneNumber = tab.splitTree.enumerated()
            .first(where: { $0.element.uuid == paneID })
            .map { $0.offset + 1 }
            let title = presentation.title == "Terminal"
                ? paneNumber.map { String(localized: "Terminal \($0)") } ?? presentation.title
                : presentation.title
            SidebarTabRow(
                title: title,
                agentRow: agentRow,
                attentionBadge: attentionBadgesEnabled ? presentation.attentionStatus : nil,
                contextLine: agentRow?.project,
                isSelected: isSelected,
                isHighlighted: isHighlighted,
                indentLevel: indentLevel,
                shortcutHint: nil,
                metrics: metrics,
                accentTint: accentTint,
                showsCloseButton: false,
                onClose: {}
            )
        }
    }
}

// MARK: - Agent Summary Bar

/// Rollup line under the search bar ("2 blocked · 1 working") plus the
/// attention-sort toggle. Hidden when no agents are detected anywhere.
///
/// A separate view purely so the `AgentAttentionCenter.revision` read that
/// drives its visibility is scoped here instead of to `VerticalTabSidebar.body`.
/// `revision` only bumps on a real state transition (the center's publish pass
/// is equality-guarded), so this is hygiene rather than a fix for the row churn.
/// (id=agent-attention)
private struct SidebarAgentSummaryBar: View {
    let metrics: SidebarMetrics
    let accentTint: Color
    let sortIconName: String
    let sortHelp: String
    let sortIsActive: Bool
    let onCycleSort: () -> Void

    var body: some View {
        // Registers the Observation dependency; the value itself is meaningless.
        let _ = AgentAttentionCenter.shared.revision
        if !AgentAttentionCenter.shared.globalAgentCounts().isEmpty {
            HStack(spacing: 6) {
                AttentionRollupSummary(fontSize: metrics.subtitleSize + 1)
                Spacer(minLength: 8)
                Button(action: onCycleSort) {
                    Image(systemName: sortIconName)
                        .font(.system(size: metrics.headerIconSize, weight: .medium))
                        .foregroundColor(sortIsActive ? accentTint : .secondary)
                        .frame(width: metrics.headerButtonTarget, height: metrics.headerButtonTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sortHelp)
                .accessibilityLabel(sortHelp)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}

// MARK: - Sidebar Gateway Header Row

/// The tmux gateway group header. Same isolation contract as
/// `SidebarTabRowItem`: `tab.title`, `tab.tmuxSessionName` and
/// `tab.isHiddenTmuxWindow` are read HERE so a tmux session rename or gateway
/// title change re-renders this row alone instead of the whole sidebar (which
/// would rebuild every row's context menu, including a presented one).
private struct SidebarGatewayHeaderItem: View, Equatable {
    let tab: TabModel
    /// Precomputed from the shared per-render gateway ordering — see the note
    /// on `SidebarTabRowItem.tmuxBadge`.
    let tmuxBadge: TmuxTabBadge?
    /// Resolved at parent scope from the (non-observable) TmuxController.
    let host: String?
    let collapsed: Bool
    let windowCount: Int
    let isSelected: Bool
    /// True when the selected tab belongs to this gateway's tmux group,
    /// even when the selected tab is one of its child windows.
    let isActive: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let metrics: SidebarMetrics
    let accentTint: Color
    let onToggleCollapse: () -> Void
    let onNewWindow: () -> Void
    let onShowDashboard: () -> Void
    let onClose: () -> Void
    let onTap: () -> Void

    // Parent-supplied inputs only; the observed reads in `body` keep updating
    // live. See `SidebarTabRowItem.==` for the full rationale.
    static func == (lhs: SidebarGatewayHeaderItem, rhs: SidebarGatewayHeaderItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.tmuxBadge == rhs.tmuxBadge
            && lhs.host == rhs.host
            && lhs.collapsed == rhs.collapsed
            && lhs.windowCount == rhs.windowCount
            && lhs.isSelected == rhs.isSelected
            && lhs.isActive == rhs.isActive
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.indentLevel == rhs.indentLevel
            && lhs.metrics == rhs.metrics
            && lhs.accentTint == rhs.accentTint
    }

    var body: some View {
        // The tab's mirror, not controller.currentSessionName: TmuxController
        // isn't observable, so a rename wouldn't re-render this row.
        let subtitle = Self.subtitle(
            sessionName: tab.tmuxSessionName,
            host: host,
            collapsedWindowCount: collapsed ? windowCount : nil
        )
        let title = subtitle.isEmpty ? tab.title : subtitle
        let isHidden = tab.isHiddenTmuxWindow

        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.rowIconSize - 1, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: metrics.rowIconSize - 1))
                    .foregroundColor(.secondary)
            }

            if let tmuxBadge {
                TmuxTabBadgeView(badge: tmuxBadge, palette: .currentTheme)
            }

            Text(title)
                .font(.system(size: metrics.titleSize, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(metrics.titleLineLimit)

            Spacer(minLength: 4)

            Button(action: onNewWindow) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: metrics.rowIconSize, weight: .medium))
                    .foregroundColor(accentTint)
                    .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tmux window")

            Button(action: onShowDashboard) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: metrics.rowIconSize, weight: .medium))
                    .foregroundColor(accentTint)
                    .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("tmux sessions")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.closeIconSize, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(isHidden ? 0.55 : 1)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .frame(height: metrics.tabRowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundFill)
        )
        .onTapGesture(perform: onTap)
    }

    /// Match regular grouped headers: keyboard highlight is strongest, the
    /// active tmux group is accent-tinted, and inactive groups retain the
    /// subtle grouped-header fill.
    private var backgroundFill: Color {
        if isHighlighted { return accentTint.opacity(0.22) }
        if isActive { return accentTint.opacity(0.10) }
        return Color.primary.opacity(0.04)
    }

    static func subtitle(
        sessionName: String?,
        host: String?,
        collapsedWindowCount: Int?
    ) -> String {
        var components: [String?] = [sessionName, host]
        if let collapsedWindowCount {
            components.append(collapsedWindowCount == 1
                ? String(localized: "1 window")
                : String(localized: "\(collapsedWindowCount) windows"))
        }
        return TabOrderRules.scopeTitle(components: components, fallback: "")
    }
}

private struct SidebarTabRow: View {
    let title: String
    var roamProtocol: MainView.RoamProtocol = .none
    var tmuxBadge: TmuxTabBadge? = nil
    var tmuxBadgePalette: TmuxTabBadgePalette = .fallback
    /// Agent inbox card state: non-nil turns the row into a three-line
    /// t3code-style card (status line / title / context). (id=agent-attention)
    var agentRow: AgentRowState? = nil
    /// Attention dot for plain rows (failed command, rollup) — shown only
    /// when there is no full card.
    var attentionBadge: AgentAttentionStatus? = nil
    /// Card footer context (cwd/host), head-truncated.
    var contextLine: AgentProjectIdentity? = nil
    let isSelected: Bool
    var isHighlighted: Bool = false
    var indentLevel: Int = 0
    let shortcutHint: String?
    let metrics: SidebarMetrics
    /// Explicit theme accent (see `VerticalTabSidebar.accentTint`) — the row is
    /// hosted in a UIHostingController where `Color.accentColor` would resolve
    /// to system blue rather than the theme accent.
    let accentTint: Color
    var showsCloseButton: Bool = true
    let onClose: () -> Void

    var body: some View {
        Group {
            if let agentRow {
                VStack(alignment: .leading, spacing: 2) {
                    agentStatusLine(agentRow)
                        .opacity(recedingOpacity)
                    mainLine
                    agentContextFooter(agentRow)
                        .opacity(recedingOpacity)
                }
            } else {
                mainLine
            }
        }
        .padding(.horizontal, 10)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .frame(height: agentRow != nil ? metrics.agentCardRowHeight : metrics.tabRowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundFill)
        )
    }

    // MARK: Card lines

    /// Line 1: status dot + agent name left, status label + live elapsed
    /// right.
    private func agentStatusLine(_ row: AgentRowState) -> some View {
        HStack(spacing: 5) {
            AttentionStatusDotView(status: row.status, size: 7)
            Text(row.agentDisplayName ?? row.agentID ?? "agent")
                .font(.system(size: metrics.subtitleSize, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            AgentStatusLabel(row: row, fontSize: metrics.subtitleSize)
        }
    }

    /// Line 3: project and branch, receding, with the agent's brand mark.
    ///
    /// The project is the identity and truncates LAST; the branch is
    /// secondary and gives up room first. An unknown project collapses to a
    /// spacer — never a placeholder string — so the three-line rhythm holds.
    private func agentContextFooter(_ row: AgentRowState) -> some View {
        HStack(spacing: 5) {
            if let contextLine {
                Text(contextLine.label)
                    .font(.system(size: metrics.subtitleSize))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let branch = contextLine.branch, !branch.isEmpty {
                    Text("·")
                        .font(.system(size: metrics.subtitleSize))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(branch)
                        .font(.system(size: metrics.subtitleSize))
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // A logo needs a little more room than a glyph to stay legible.
            AgentBrandMark(agentID: row.agentID, size: metrics.subtitleSize + 1)
        }
    }

    /// The classic single-line row (line 2 of the card): pip, badges,
    /// title, shortcut, close.
    private var mainLine: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isSelected ? accentTint : Color.primary.opacity(0.25))
                .frame(width: 6, height: 6)
                .opacity(recedingOpacity)

            // Plain rows carry the attention state as a dot (failed
            // command, rollup); cards already say it on line 1.
            if agentRow == nil, let attentionBadge {
                AttentionStatusDotView(status: attentionBadge, size: 7)
                    .opacity(recedingOpacity)
            }

            RoamTabBadgeView(roamProtocol: roamProtocol)
                .opacity(recedingOpacity)

            if let tmuxBadge {
                TmuxTabBadgeView(badge: tmuxBadge, palette: tmuxBadgePalette)
                    .opacity(recedingOpacity)
            }

            // Keep agent-card titles consistent with regular inactive tabs.
            // Only the supporting agent metadata recedes.
            Text(title)
                .font(.system(size: metrics.titleSize, weight: titleWeight))
                .foregroundColor(.primary)
                .lineLimit(metrics.titleLineLimit)

            Spacer()

            if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: metrics.hintSize, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .opacity(recedingOpacity)
            }

            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: metrics.closeIconSize, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(recedingOpacity)
            }
        }
    }

    /// Unread work reads bolder even when unselected (t3code).
    private var titleWeight: Font.Weight {
        if isSelected { return .semibold }
        if agentRow?.unread == true { return .semibold }
        return .regular
    }

    /// Inbox-zero prominence: in-flight and already-seen agent metadata
    /// recedes while the tab title stays consistent with regular rows.
    private var recedingOpacity: Double {
        recedes ? 0.72 : 1
    }

    private var recedes: Bool {
        guard let agentRow, !isSelected, !isHighlighted else { return false }
        if agentRow.unread { return false }
        switch agentRow.status {
        case .working, .idle, .unknown: return true
        case .paused, .blocked, .failed, .done: return false
        }
    }

    /// Matches the profiles view's list-highlight idiom: keyboard highlight
    /// and selection are both accent-tinted fills (the selection lighter).
    private var backgroundFill: Color {
        if isHighlighted { return accentTint.opacity(0.22) }
        if isSelected { return accentTint.opacity(0.12) }
        return .clear
    }
}
