//
//  VerticalTabSidebar.swift
//  rootshell
//
//  Vertical tab list in the left sidebar. tmux -CC gateways render as
//  collapsible groups with their window tabs indented beneath them.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Collapse State Persistence

/// Keyed by the gateway's owner terminal UUID, which is stable across restore.
@MainActor
enum TabSidebarCollapseStore {
    static func load() -> Set<UUID> {
        let strings = SettingsStore.shared.get(Settings.Sidebar.collapsedGateways)
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    /// Prunes unknown gateways so the list can't grow without bound.
    static func save(_ collapsed: Set<UUID>, knownGateways: Set<UUID>) {
        let pruned = collapsed.intersection(knownGateways)
        SettingsStore.shared.set(Settings.Sidebar.collapsedGateways, pruned.map(\.uuidString).sorted())
    }
}

enum TabSidebarGroupCollapseStore {
    static func load() -> Set<String> {
        Set(SettingsStore.shared.get(Settings.Sidebar.collapsedGroups))
    }

    static func save(_ collapsed: Set<String>, knownGroups: Set<String>) {
        let pruned = collapsed.intersection(knownGroups)
        SettingsStore.shared.set(Settings.Sidebar.collapsedGroups, pruned.sorted())
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
        case .local, .remoteNetwork, .tmux, .herdr, .other:
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

/// All sidebar sizes. Equatable so a density change defeats the rows' `==`
/// short-circuit and repaints them.
struct SidebarMetrics: Equatable {
    /// Uniform across rows; section headers ignore it.
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

    /// Base height plus a line-height per extra title line.
    var tabRowHeight: CGFloat {
        rowHeight + CGFloat(titleLineLimit - 1) * ceil(UIFont.systemFont(ofSize: titleSize).lineHeight)
    }

    /// Clamped so a stray UserDefaults value can't blow up the layout.
    func withTitleLines(_ lines: Int) -> SidebarMetrics {
        var copy = self
        copy.titleLineLimit = min(max(lines, 1), 3)
        return copy
    }

    /// Tab row plus a status line above and a context line below.
    var agentCardRowHeight: CGFloat {
        tabRowHeight + 2 * (ceil(UIFont.systemFont(ofSize: subtitleSize).lineHeight) + 2)
    }

    /// Shared trailing rail so every accessory centers on one line.
    var trailingAccessoryWidth: CGFloat { headerButtonTarget }
}

// MARK: - Vertical Tab Sidebar

struct VerticalTabSidebar: View {
    #if !os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var panelHeight: CGFloat = 0
    let tabsModel: TabsModel
    let windowId: String
    @Binding var collapsedGateways: Set<UUID>
    /// Synchronous so a tap that will dismiss the panel skips re-focusing search.
    let staysOpenOnSelect: Bool
    /// Docked columns never auto-focus search; the terminal keeps the keyboard.
    let isDocked: Bool
    /// Docked only: clearance for the keyboard or toolbar, since the sidebar
    /// ignores the keyboard safe area (see MainView.dockedSidebarBottomClearance).
    var dockedBottomClearance: CGFloat = 0
    /// iPad/Catalyst only.
    let canPin: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onSelectTab: (UUID) -> Void
    /// Selects the containing tab and focuses one exact split pane.
    let onSelectPane: (UUID, UUID) -> Void
    let onCloseTab: (UUID) -> Void
    /// Live reorder of tmux/herdr siblings within their slots; local-only until
    /// `onReorderEnded` commits to the server.
    let onReorderClass: ([UUID], UUID) -> Void
    /// Raw array move for regular tabs, which may cross gateway groups.
    let onMoveTab: (Int, Int) -> Void
    let onReorderEnded: (UUID) -> Void
    let onNewTab: () -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onNewTmuxWindow: (TabModel) -> Void
    let tmuxController: (TabModel) -> TmuxController?
    let onShowConnectionInfo: (TabModel) -> Void
    let canTransferToNearby: (TabModel) -> Bool
    let onTransferToNearby: (TabModel) -> Void
    let tabHasThemeOverride: (UUID) -> Bool
    let onClearThemeOverride: (UUID) -> Void
    let onMoveTabToNewWindow: (TabModel) -> Void
    let onMoveTabsToNewWindow: ([UUID]) -> Void

    // Sheets presented from here don't get MainView's themedSheet treatment.
    let sheetThemeColors: SheetThemeColors?
    let sheetAccentColor: Color?
    let sheetColorScheme: ColorScheme?
    var onExposeRequested: () -> Void = {}
    var onOpenAgentInbox: () -> Void = {}
    var onTabHover: ((UUID, Bool) -> Void)? = nil
    /// Nil disables hover previews.
    var previewAnchors: TabHoverPreviewAnchorRegistry? = nil

    @Setting(Settings.Tabs.showShortcutIndicators) private var showTabShortcutIndicators
    @Setting(Settings.Tabs.barHidden) private var tabBarHidden

    /// The terminal resigned first responder, so the toggle shortcut's second
    /// press must be caught locally.
    @ObservedObject private var menuShortcuts = MenuShortcutState.shared

    @State private var searchText = ""
    @State private var dashboardRequest: TmuxDashboardRequest?

    /// Session-scoped; not persisted.
    @State private var expandedHiddenGroups: Set<UUID> = []
    @State private var collapsedGroups: Set<String> = TabSidebarGroupCollapseStore.load()

    @State private var tmuxDialogs = TmuxTabDialogCoordinator()
    @State private var herdrDialogs = HerdrTabDialogCoordinator()

    // Keys route through the UIKit-backed `SidebarSearchField`, not `.onKeyPress`.
    @State private var highlightedRowID: String?

    /// The keyboard highlight only renders while the sidebar owns the keyboard.
    @State private var searchFieldFocused = false

    /// Bumped by `requestSearchFocus()`; the field claims first responder once it has a window.
    @State private var searchFocusRequestID = 0

    /// The view stays mounted off-screen after dismissal, so gate re-focus on this.
    @State private var isPanelVisible = true

    /// `.repeat` key phases don't arrive from iPad hardware keyboards.
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()


    // System drag and drop; a custom drag gesture blocked scrolling.
    @State private var draggingRowID: UUID? = nil
    @State private var draggingSectionID: String? = nil
    @State private var dragAssignedGroup = false
    @State private var dragStateGeneration = 0
    @State private var dragStateExpirationTask: Task<Void, Never>?
    @State private var dragPreviewWidth = TabSidebarLayout.defaultWidth - 24

    @Setting(Settings.Sidebar.largeControls) private var largeControls

    @Setting(Settings.Sidebar.rowLines) private var titleLines

    /// Duplicates the top bar's actions only when it is hidden or obscured (iPhone).
    private var showsHeaderActionButtons: Bool {
        tabBarHidden || usesCompactLayout
    }

    /// Rendering only; detection has its own toggle. (id=agent-attention)
    @Setting(Settings.CodingAgents.attentionBadges) private var attentionBadgesEnabled
    @Setting(Settings.Tabs.programIcons) private var programIconsEnabled

    /// "static", "priority", or "project". Visual-only; the tabs array never moves.
    @Setting(Settings.CodingAgents.inboxSort) private var agentSortRaw

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

    /// Replaces the group/gateway hierarchy rather than requiring grouping off.
    /// (id=agent-project)
    private var projectGroupingActive: Bool {
        agentSortRaw == "project" && hasAnyProject
    }

    private var hasAnyProject: Bool {
        tabsModel.hasAnyProject
    }

    @State private var collapsedProjects: Set<String> = []

    private var metrics: SidebarMetrics {
        let base: SidebarMetrics = largeControls ? .large : .compact
        return base.withTitleLines(titleLines)
    }

    /// Explicit because `.tint` doesn't reach `Color.accentColor` in this
    /// UIHostingController; it would fall back to system blue.
    private var accentTint: Color {
        sheetAccentColor ?? .accentColor
    }

    private var canReorderSections: Bool {
        tabsModel.isGroupedModeEnabled
            && searchText.isEmpty
            && tabsModel.availableGroups.count > 1
    }

    // MARK: Row Model

    private enum RowKind: Equatable {
        case groupHeader(groupID: TabGroupID, title: String, count: Int, isActive: Bool, collapsed: Bool)
        case flat
        case gatewayHeader(collapsed: Bool, windowCount: Int, ownerID: UUID)
        case windowRow
        /// A pane-scoped agent card nested beneath a multi-pane tab.
        case agentPane(paneID: UUID)
        /// `tab` is the gateway tab, so the row id is kind-disambiguated.
        /// (id=tmux-hidden-windows)
        case hiddenHeader(ownerID: UUID, count: Int, expanded: Bool)
        case hiddenWindowRow
        /// Only when the session has several workspaces; `tab` is the first one's.
        case herdrWorkspaceHeader(ownerID: UUID, workspaceId: String, title: String, count: Int, collapsed: Bool)
        /// `rollup` is the worst attention state, shown while collapsed.
        /// (id=agent-project)
        case projectHeader(
            key: String,
            title: String,
            count: Int,
            collapsed: Bool,
            rollup: AgentAttentionStatus?)
    }

    /// `.local` tabs move anywhere; `.window` rows only among their gateway's
    /// siblings; `.none` rows aren't draggable but accept `.local` drops.
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

        /// Kind-prefixed, since several row kinds reuse the same tab.
        var id: String {
            if case .groupHeader(let groupID, _, _, _, _) = kind { return "group-\(groupID.rawValue)" }
            if case .hiddenHeader = kind { return "hidden-\(tab.id.uuidString)" }
            if case .projectHeader(let key, _, _, _, _) = kind { return "project-\(key)" }
            if case .herdrWorkspaceHeader(let ownerID, let workspaceId, _, _, _) = kind {
                return "herdr-ws-\(ownerID.uuidString)-\(workspaceId)"
            }
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
            case .gatewayHeader, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader,
                    .herdrWorkspaceHeader:
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
                return tab.isHerdrGateway ? .herdr(ownerID: ownerID) : .tmux(ownerID: ownerID)
            case .flat, .windowRow, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader,
                    .herdrWorkspaceHeader:
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
        // Once per render; per-row resolution is O(n^2) and observes every split tree.
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

                // Self-hiding when off or empty.
                SidebarAgentUsageFooter(
                    metrics: metrics,
                    accentTint: accentTint,
                    isDocked: isDocked
                )
            }
            .padding(.bottom, dockedBottomClearance)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            // Projects resolve asynchronously, so sync on value change, not events.
            .onChange(of: projectGroupingActive, initial: true) { _, active in
                tabsModel.projectScopedInboxEnabled = active
            }
            .onAppear {
                loadGroupOrder()
                // @State survives presentations; onAppear fires on each open.
                isPanelVisible = true
                highlightedRowID = tabsModel.selectedTabID?.uuidString
                if let selectedID = tabsModel.selectedTabID {
                    proxy.scrollTo(selectedID.uuidString, anchor: .center)
                }
                if !isDocked {
                    requestSearchFocus()
                }
                // Context-menu pickers read the cache synchronously.
                for tab in tabsModel.tabs where tab.isTmuxGateway {
                    tmuxController(tab)?.refreshSessionsCache()
                }
            }
            .onDisappear {
                arrowKeyRepeatManager.stop()
                clearLocalDragState()
            }
            // Docked: tapping empty space focuses search for arrow-key navigation.
            .contentShape(Rectangle())
            .onTapGesture {
                if isDocked { requestSearchFocus() }
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(sidebarShortcutCatchers)
        .tmuxTabDialogs(coordinator: tmuxDialogs, controller: tmuxController)
        .herdrTabDialogs(coordinator: herdrDialogs)
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
                if tab.isTmuxGateway || tab.isTmuxWindow {
                    return TmuxTabBadgeResolver.ownerID(for: tab)
                }
                return TmuxTabBadgeResolver.herdrOwnerID(for: tab)
            })
            TabSidebarCollapseStore.save(newValue, knownGateways: known)
        }
        .onChange(of: collapsedGroups) { _, newValue in
            // herdr workspace headers have their own keys.
            var known = Set(tabsModel.availableGroups.map { $0.id.rawValue })
            for tab in tabsModel.tabs where tab.isHerdrWindow {
                guard let ownerID = tab.owningGatewayTerminalUUID, let workspaceId = tab.herdrWorkspaceId else { continue }
                known.insert(Self.herdrWorkspaceCollapseKey(ownerID: ownerID, workspaceId: workspaceId))
            }
            TabSidebarGroupCollapseStore.save(newValue, knownGroups: known)
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
        // The dashboard sheet took first responder; reclaim it on dismiss.
        .onChange(of: dashboardRequest != nil) { wasPresented, isPresented in
            guard wasPresented, !isPresented, isPanelVisible else { return }
            requestSearchFocus()
        }
    }

    /// Menu items already fire with the sidebar focused where a menu bar exists.
    private var needsShortcutCatchers: Bool {
        !MenuShortcutState.menuRailOwnsShortcuts
    }

    /// Single-chord only: sequences collapse to their first trigger here, so
    /// `ctrl+a > t` would fire on a bare `ctrl+a`.
    @ViewBuilder
    private var sidebarShortcutCatchers: some View {
        ZStack {
            if needsShortcutCatchers,
               isPanelVisible,
               hasSingleChordBinding(for: .toggle_tab_switcher),
               let shortcut = menuShortcuts.shortcuts[.toggle_tab_switcher] {
                Button("") { onDismiss() }
                    .keyboardShortcut(shortcut)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            if needsShortcutCatchers,
               isPanelVisible,
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

    private var usesCompactLayout: Bool {
        #if os(visionOS)
        return false
        #else
        return horizontalSizeClass != .regular
        #endif
    }

    /// `.onDrag` has no reliable end callback; only Catalyst drops always complete.
    private var usesHiddenSourceDragPreview: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// See `TabSidebarPresentation.swift`.
    private func postDismissDragChanged(_ value: DragGesture.Value) {
        NotificationCenter.default.post(
            name: .tabSidebarDismissDragChanged,
            object: nil,
            userInfo: ["offset": max(0, value.translation.height)]
        )
    }

    /// Commits past a third of the screen or on a flick, like a native sheet.
    private func commitOrCancelDismissDrag(_ value: DragGesture.Value) {
        let dismissDistance = max(120, panelHeight * 0.3)
        if value.translation.height > dismissDistance || value.velocity.height > 1000 {
            onDismiss()
        } else {
            NotificationCenter.default.post(name: .tabSidebarDismissDragCancelled, object: nil)
        }
    }

    /// Global space, since local tracking of a moving view jitters. The overlay
    /// controller moves the hosting view so the chrome moves too.
    private func dismissDragGesture(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { postDismissDragChanged($0) }
            .onEnded { commitOrCancelDismissDrag($0) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            headerRow
        }
        .contentShape(Rectangle())
        // 10pt so the header's buttons still work. Compact drawers slide
        // sideways, so a downward drag must not move them. `.subviews`
        // disables the drag when docked too.
        .gesture(dismissDragGesture(minimumDistance: 10), including: (isDocked || usesCompactLayout) ? .subviews : .all)
    }

    private func headerButton(
        _ systemImage: String,
        help: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.headerIconSize, weight: .medium))
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
        .padding(.leading, 16)
        // List inset + row inset, to share the rows' trailing rail.
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Agent Summary

    /// Shown for project shells even with badges off, and while the agent
    /// inbox has unread messages. (id=agent-attention)
    private var agentSummaryBar: some View {
        SidebarAgentSummaryBar(
            metrics: metrics,
            accentTint: accentTint,
            hasProjects: hasAnyProject,
            showsAttention: attentionBadgesEnabled,
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
                    agentSortRaw = attentionBadgesEnabled ? "priority" : "project"
                }
            },
            onOpenInbox: onOpenAgentInbox
        )
    }

    // MARK: Search

    private func searchField(rows: [SidebarRow], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.searchFontSize - 1))
                .foregroundColor(.secondary)

            // Escape clears the filter first, then dismisses.
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
                    // Async: this can fire inside `updateUIView`. FIFO keeps ordering.
                    DispatchQueue.main.async {
                        searchFieldFocused = focused
                        if focused {
                            highlightedRowID = tabsModel.selectedTabID?.uuidString
                        }
                    }
                }
            )
            // Fixed height so focus can't reflow the rows below.
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
            .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
            .help("Group tabs")
        }
        // Small trailing inset keeps the last accessory on the shared rail.
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: metrics.searchBarHeight)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
    }

    // MARK: Row List

    private func rowList(_ rows: [SidebarRow], gatewayOwnerIDs: [UUID]) -> some View {
        let list = ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: metrics.rowSpacing) {
                ForEach(rows) { row in
                    rowView(row: row, rows: rows, gatewayOwnerIDs: gatewayOwnerIDs)
                        .id(row.id)
                }
            }
            // Drag preview width, since the docked column is resizable. Measured on
            // the stack; a per-row reader re-rendered the sidebar mid-gesture.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                guard width > 0, dragPreviewWidth != width else { return }
                dragPreviewWidth = width
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        // A floating keyboard gives the docked column a bottom safe area, and
        // the scroll view extends into it, drawing rows over the usage footer.
        return Group {
            if isDocked { list.clipped() } else { list }
        }
        // Catches drops between rows.
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

    /// Falls back to the first row, e.g. the top filter match.
    @discardableResult
    private func selectHighlighted(rows: [SidebarRow]) -> Bool {
        let validHighlight = highlightedRowID.flatMap { id in
            rows.contains(where: { $0.id == id }) ? id : nil
        }
        guard let id = validHighlight ?? rows.first?.id,
              let row = rows.first(where: { $0.id == id }) else { return false }
        highlightedRowID = id
        activateHighlightedRow(row)
        // The search field keeps first responder while the sidebar stays open.
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
        case .herdrWorkspaceHeader(let ownerID, let workspaceId, _, _, _):
            toggleHerdrWorkspaceCollapse(ownerID: ownerID, workspaceId: workspaceId)
        default:
            activateRow(row)
        }
    }

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
        case .herdrWorkspaceHeader(let ownerID, let workspaceId, _, _, _):
            toggleHerdrWorkspaceCollapse(ownerID: ownerID, workspaceId: workspaceId)
        case .gatewayHeader:
            // (id=tmux-hidden-gateway)
            if row.tab.isHiddenTmuxWindow {
                showHiddenGateway(row.tab)
            } else {
                onSelectTab(row.tab.id)
            }
        case .projectHeader(let key, _, _, let collapsed, _):
            // Keyboard only; the header handles its own taps.
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

    private static func herdrWorkspaceCollapseKey(ownerID: UUID, workspaceId: String) -> String {
        "herdr-ws:\(ownerID.uuidString.lowercased())/\(workspaceId)"
    }

    private func toggleHerdrWorkspaceCollapse(ownerID: UUID, workspaceId: String) {
        let key = Self.herdrWorkspaceCollapseKey(ownerID: ownerID, workspaceId: workspaceId)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if collapsedGroups.contains(key) {
                collapsedGroups.remove(key)
            } else {
                collapsedGroups.insert(key)
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

    private func showHiddenWindow(_ tab: TabModel) {
        guard let windowId = tab.tmuxWindowId,
              let controller = tmuxController(tab) else { return }
        controller.showWindow(windowId: windowId, andSelect: true)
    }

    /// Via the controller, since onSelectTab never unhides; without one, clear
    /// the flag so the tab can't become unreachable. (id=tmux-hidden-gateway)
    private func showHiddenGateway(_ tab: TabModel) {
        if let controller = tmuxController(tab) {
            controller.showGatewayTab(andSelect: true)
        } else if tab.isHerdrGateway, let controller = HerdrController.controller(forAnyTab: tab) {
            controller.showGatewayTab()
        } else {
            tab.isHiddenTmuxWindow = false
            onSelectTab(tab.id)
        }
    }

    /// Keeps arrow-key navigation alive. No-op without a hardware keyboard,
    /// where it would pop the software keyboard.
    private func requestSearchFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return }
        searchFocusRequestID += 1
    }

    /// Parent-supplied inputs only; children read live state. Omits flatIndex
    /// because row actions address tabs by identity.
    private struct SidebarMenuRowIdentity<Presentation: Equatable>: Equatable {
        let tab: ObjectIdentifier
        let kind: RowKind
        let tabsModel: ObjectIdentifier
        let windowId: String
        let isDocked: Bool
        let staysOpenOnSelect: Bool
        let tmuxDialogs: ObjectIdentifier
        let herdrDialogs: ObjectIdentifier
        let presentation: Presentation
    }

    private func menuRowIdentity<Presentation: Equatable>(
        for row: SidebarRow,
        presentation: Presentation
    ) -> SidebarMenuRowIdentity<Presentation> {
        SidebarMenuRowIdentity(
            tab: ObjectIdentifier(row.tab),
            kind: row.kind,
            tabsModel: ObjectIdentifier(tabsModel),
            windowId: windowId,
            isDocked: isDocked,
            staysOpenOnSelect: staysOpenOnSelect,
            tmuxDialogs: ObjectIdentifier(tmuxDialogs),
            herdrDialogs: ObjectIdentifier(herdrDialogs),
            presentation: presentation
        )
    }

    /// Header inputs not already carried by RowKind.
    private struct SidebarHeaderMenuPresentation: Equatable {
        let indentLevel: Int
        let isHighlighted: Bool
        let metrics: SidebarMetrics
        let accentTint: Color
    }

    @ViewBuilder
    private func rowView(row: SidebarRow, rows: [SidebarRow], gatewayOwnerIDs: [UUID]) -> some View {
        let isDraggingTab = draggingRowID == row.tab.id && row.isDraggable
        let isDraggingSection = draggingSectionID != nil && row.sectionID?.rawValue == draggingSectionID
        let isDragging = isDraggingTab || isDraggingSection
        let hidesSourceDuringDrag = usesHiddenSourceDragPreview
        let isSelected = tabsModel.selectedTabID == row.tab.id && !row.isHiddenKind
        // Only while the sidebar owns the keyboard, or docked shows two highlights.
        let isHighlighted = highlightedRowID == row.id
            && KeyboardTracker.shared.isHardwareKeyboard
            && searchFieldFocused

        Group {
            switch row.kind {
            case .groupHeader(let groupID, let title, let count, let isActive, let collapsed):
                SidebarContextMenuRow(
                    identity: menuRowIdentity(for: row, presentation: SidebarHeaderMenuPresentation(
                        indentLevel: row.visualIndentLevel,
                        isHighlighted: isHighlighted,
                        metrics: metrics,
                        accentTint: accentTint
                    ))
                ) {
                    groupHeaderRow(
                        row: row,
                        groupID: groupID,
                        title: title,
                        count: count,
                        isActive: isActive,
                        collapsed: collapsed,
                        isHighlighted: isHighlighted
                    )
                } menu: {
                    moveGroupToWindowItems(for: groupID, isGateway: false)
                }
                .equatable()
            case .gatewayHeader(let collapsed, let windowCount, let ownerID):
                let header = gatewayHeaderRow(
                    row: row,
                    isSelected: isSelected,
                    isHighlighted: isHighlighted,
                    collapsed: collapsed,
                    windowCount: windowCount,
                    ownerID: ownerID,
                    gatewayOwnerIDs: gatewayOwnerIDs
                )
                SidebarContextMenuRow(identity: menuRowIdentity(for: row, presentation: header)) {
                    header
                } menu: {
                    if row.tab.isHerdrGateway {
                        herdrGatewayHeaderMenu(for: row.tab)
                    } else {
                        gatewayHeaderMenu(for: row.tab, ownerID: ownerID)
                    }
                }
                .equatable()
            case .herdrWorkspaceHeader(let ownerID, let workspaceID, let title, let count, let collapsed):
                SidebarContextMenuRow(
                    identity: menuRowIdentity(for: row, presentation: SidebarHeaderMenuPresentation(
                        indentLevel: row.visualIndentLevel,
                        isHighlighted: isHighlighted,
                        metrics: metrics,
                        accentTint: accentTint
                    ))
                ) {
                    herdrWorkspaceHeaderRow(
                        row: row,
                        title: title,
                        count: count,
                        collapsed: collapsed,
                        isHighlighted: isHighlighted
                    )
                } menu: {
                    if let controller = HerdrController.controller(forGateway: ownerID) {
                        HerdrWorkspaceMenuItems(controller: controller, workspaceID: workspaceID, onAction: { herdrDialogs.showWorkspaces(controller, action: $0) })
                    }
                }
                .equatable()
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
                    programIconsEnabled: programIconsEnabled,
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
                let item = SidebarTabRowItem(
                    tab: row.tab,
                    tmuxBadge: TmuxTabBadgeResolver.badge(for: row.tab, gatewayOwnerIDs: gatewayOwnerIDs),
                    attentionBadgesEnabled: attentionBadgesEnabled,
                    programIconsEnabled: programIconsEnabled,
                    isSelected: isSelected,
                    isHighlighted: isHighlighted,
                    indentLevel: row.visualIndentLevel,
                    shortcutHint: shortcutHint(for: row),
                    metrics: metrics,
                    accentTint: accentTint,
                    onClose: { onCloseTab(row.tab.id) },
                    onHoverChange: onTabHover.map { hover in { hover(row.tab.id, $0) } },
                    previewAnchors: previewAnchors
                )
                SidebarContextMenuRow(identity: menuRowIdentity(for: row, presentation: item)) {
                    item
                } menu: {
                    switch row.kind {
                    case .windowRow:
                        windowRowMenu(for: row.tab)
                    case .hiddenWindowRow:
                        hiddenWindowRowMenu(for: row.tab)
                    default:
                        flatRowMenu(for: row.tab)
                    }
                }
                .equatable()
                .opacity(row.isHiddenKind ? 0.55 : 1)
                .onTapGesture {
                    highlightedRowID = row.id
                    activateRow(row)
                    // Not when the tap dismisses the panel, nor docked, where the
                    // terminal should get focus.
                    if staysOpenOnSelect && !isDocked {
                        requestSearchFocus()
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
        // No reliable cancel callback, so expire with TabTransferCoordinator's
        // lifetime. Not refreshed on movement; a stationary drag is valid.
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
    /// Same `SidebarTabRowItem` as the live row; no `.equatable()` for a one-off render.
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
                    programIconsEnabled: programIconsEnabled,
                    isSelected: isSelected,
                    isHighlighted: false,
                    indentLevel: row.visualIndentLevel,
                    shortcutHint: shortcutHint(for: row),
                    metrics: metrics,
                    accentTint: accentTint,
                    onClose: {}
                )
            case .agentPane, .hiddenHeader, .projectHeader, .herdrWorkspaceHeader:
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
        // Sorted rows are out of model order, so only section headers drag.
        if projectGroupingActive {
            switch row.kind {
            case .projectHeader, .flat, .windowRow:
                return true
            case .groupHeader, .gatewayHeader, .agentPane, .hiddenHeader,
                    .hiddenWindowRow, .herdrWorkspaceHeader:
                return false
            }
        }
        if attentionSortActive && attentionBadgesEnabled {
            return draggableSectionID(for: row) != nil
        }
        return row.isDraggable || draggableSectionID(for: row) != nil
    }

    // MARK: Context Menus

    @ViewBuilder
    private func connectionInfoItem(for tab: TabModel) -> some View {
        Button {
            onShowConnectionInfo(tab)
        } label: {
            Label("Connection Info", systemImage: "info.circle")
        }
        .disabled(tab.connectionInfo == nil)
    }

    @ViewBuilder
    private func connectionAddressCopyItems(for tab: TabModel) -> some View {
        if let info = tab.connectionInfo,
           HostAddressCopyActions.hasActions(
               hostname: info.copyableHostname,
               ipAddress: info.copyableIPAddress
           ) {
            HostAddressCopyActions(
                hostname: info.copyableHostname,
                ipAddress: info.copyableIPAddress
            )
            Divider()
        }
    }

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

    @ViewBuilder
    private func moveToWindowItems(for tab: TabModel) -> some View {
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
                if !targets.isEmpty {
                    Divider()
                }
                Button {
                    onMoveTabToNewWindow(tab)
                } label: {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
            } label: {
                Label("Move to Window", systemImage: "arrowshape.turn.up.right")
            }
        }
    }

    @ViewBuilder
    private func moveGroupToWindowItems(for groupID: TabGroupID, isGateway: Bool) -> some View {
        // Gateways move their whole tmux family, including hidden and regrouped
        // tabs, so adoption stays coherent; groups use effective membership.
        let tabIDs: [UUID] = {
            if isGateway, let ownerID = groupID.tmuxOwnerID {
                return tabsModel.tmuxFamilyTabIDs(ownerID: ownerID)
            }
            return tabsModel.availableGroups.first(where: { $0.id == groupID })?.tabIDs ?? []
        }()
        let members = tabIDs.compactMap { tabsModel.tab(withID: $0) }
        // All-or-nothing; single-tab groups already have the per-tab item.
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

    /// Presents from a sidebar-local sheet, since this is an embedded hosting controller.
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
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
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
        case .herdr: return MultiplexerType.herdr.iconName
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

    @ViewBuilder
    private func flatRowMenu(for tab: TabModel) -> some View {
        connectionAddressCopyItems(for: tab)
        connectionInfoItem(for: tab)
        HerdrTabMenuItems(tab: tab, dialogs: herdrDialogs)
        transferAndThemeItems(for: tab)
        moveToWindowItems(for: tab)
        groupOverrideMenuItem(for: tab)
        Divider()
        HerdrGatewayDetachMenuItem(tab: tab, dialogs: herdrDialogs)
        MultiplexerDetachMenuItem(tab: tab) { tab in
            _ = MuxSessionDetach.detach(tab: tab, tmuxController: tmuxController)
        }
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    @ViewBuilder
    private func windowRowMenu(for tab: TabModel) -> some View {
        connectionAddressCopyItems(for: tab)
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

    @ViewBuilder
    private func hiddenWindowRowMenu(for tab: TabModel) -> some View {
        connectionAddressCopyItems(for: tab)
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

    @ViewBuilder
    private func gatewayHeaderMenu(for tab: TabModel, ownerID: UUID) -> some View {
        connectionAddressCopyItems(for: tab)
        connectionInfoItem(for: tab)
        TmuxTabMenuItems(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs,
            onNewTmuxWindow: onNewTmuxWindow,
            onShowTmuxSessions: { showTmuxSessionsLocally($0) }
        )
        transferAndThemeItems(for: tab)
        // The whole family, or the controller's baseWindowId splits from its windows.
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

    @ViewBuilder
    private func herdrGatewayHeaderMenu(for tab: TabModel) -> some View {
        connectionAddressCopyItems(for: tab)
        connectionInfoItem(for: tab)
        HerdrTabMenuItems(tab: tab, dialogs: herdrDialogs)
        transferAndThemeItems(for: tab)
        groupOverrideMenuItem(for: tab)
        Divider()
        HerdrGatewayDetachMenuItem(tab: tab, dialogs: herdrDialogs)
        Button(role: .destructive) {
            onCloseTab(tab.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    private func herdrWorkspaceHeaderRow(
        row: SidebarRow,
        title: String,
        count: Int,
        collapsed: Bool,
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: metrics.rowIconSize - 2, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)

            Image(systemName: "square.grid.2x2")
                .font(.system(size: metrics.rowIconSize - 1))
                .foregroundColor(.secondary)

            Text(title)
                .font(.system(size: metrics.subtitleSize + 1, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if collapsed {
                Text("(\(count))")
                    .font(.system(size: metrics.subtitleSize, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(row.visualIndentLevel) * 20)
        .frame(height: max(32, metrics.rowHeight - 12))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? accentTint.opacity(0.22) : .clear)
        )
        .onTapGesture {
            highlightedRowID = row.id
            activateRow(row)
        }
    }

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

    /// Collapsed, the chevron becomes the worst attention state. Colour is state
    /// only, never project identity. (id=agent-project)
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
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
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

    /// Live, local-only reorder while hovering; the server commit happens at drop.
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
                    .hiddenWindowRow, .projectHeader, .herdrWorkspaceHeader:
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
            guard target.dragClass == source.dragClass else { return }
            var orderedIDs = rows.filter { $0.dragClass == source.dragClass }.map(\.tab.id)
            guard let from = orderedIDs.firstIndex(of: draggingID),
                  let to = orderedIDs.firstIndex(of: target.tab.id),
                  from != to else { return }
            let moved = orderedIDs.remove(at: from)
            orderedIDs.insert(moved, at: to)
            onReorderClass(orderedIDs, draggingID)

        case .local:
            // Nested herdr tabs reorder only among workspace siblings; a move
            // across workspaces would show nowhere.
            if isNestedUnderHerdrGateway(source.tab) {
                let sourceGroup = tabsModel.effectiveGroupID(for: source.tab)
                // Only siblings in the source's displayed group.
                let siblingIDs = rows.filter { row in
                    row.dragClass == .local
                        && Self.isHerdrWorkspaceSibling(source.tab, row.tab)
                        && (!tabsModel.isGroupedModeEnabled || tabsModel.effectiveGroupID(for: row.tab) == sourceGroup)
                }.map(\.tab.id)
                guard Self.isHerdrWorkspaceSibling(source.tab, target.tab),
                      let moved = TabOrderRules.moving(
                        draggingID, to: target.tab.id, in: siblingIDs
                      ) else { return }
                onReorderClass(moved, draggingID)
                return
            }
            if tabsModel.isGroupedModeEnabled {
                switch target.kind {
                case .flat, .gatewayHeader, .windowRow:
                    moveDraggedTab(draggingID, near: target.tab.id)
                case .groupHeader, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader,
                        .herdrWorkspaceHeader:
                    return
                }
                return
            }

            // Only top-level rows: nested rows' raw indices don't match their position.
            switch target.kind {
            case .flat, .gatewayHeader:
                break
            case .groupHeader, .windowRow, .agentPane, .hiddenHeader, .hiddenWindowRow, .projectHeader,
                    .herdrWorkspaceHeader:
                return
            }
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
        if groupID.kind == .tmux || groupID.kind == .herdr,
           let gatewayID = group.tabIDs.first(where: { id in
               guard id != draggingID, let tab = tabsModel.tab(withID: id) else { return false }
               return tab.isTmuxGateway || tab.isHerdrGateway
           }) {
            return gatewayID
        }
        return group.tabIDs.first { $0 != draggingID }
    }

    /// Mirrors the row builders' nesting rules.
    private func isNestedUnderHerdrGateway(_ tab: TabModel) -> Bool {
        guard tab.isHerdrWindow, let owner = tab.owningGatewayTerminalUUID else { return false }
        if tabsModel.isGroupedModeEnabled {
            return tabsModel.effectiveGroupID(for: tab) == .herdr(ownerID: owner)
        }
        return tabsModel.tabs.contains { $0.isHerdrGateway && TmuxTabBadgeResolver.herdrOwnerID(for: $0) == owner }
    }

    private static func isHerdrWorkspaceSibling(_ source: TabModel, _ target: TabModel) -> Bool {
        target.isHerdrWindow
            && target.owningGatewayTerminalUUID == source.owningGatewayTerminalUUID
            && target.herdrWorkspaceId == source.herdrWorkspaceId
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
        let shouldCommitRemoteOrder = !dragAssignedGroup && !projectGroupingActive
        dragAssignedGroup = false
        if shouldCommitRemoteOrder {
            onReorderEnded(draggingID)
        }
        TabTransferCoordinator.shared.clearDrag()
        return true
    }

    private func shortcutHint(for flatIndex: Int) -> String? {
        guard showTabShortcutIndicators, flatIndex >= 0, flatIndex < 9 else { return nil }
        return "\u{2318}\(flatIndex + 1)"
    }

    /// In grouped mode ⌘1–9 only address the active group, so others get no hint.
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
        // A tab's own group always holds it, so a grouped tab never falls back.
        guard tabsModel.isGroupedModeEnabled, tabsModel.effectiveGroupID(for: tab) != nil else {
            return tabsModel.visibleIndex(of: tab.id)
        }
        return tabsModel.groupPosition(of: tab.id)
    }

    // MARK: Gateway Header Row

    /// Concrete type so the live row can apply `.equatable()`.
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
        let isHerdr = row.tab.isHerdrGateway
        let familyID: TabGroupID = isHerdr ? .herdr(ownerID: ownerID) : .tmux(ownerID: ownerID)
        let isActive = tabsModel.effectiveGroupID(for: tabsModel.selectedTab) == familyID
        let host: String? = isHerdr
            ? tabsModel.groupHostLabel(for: row.tab)
            // Not observable, so safe to resolve here and compare in `==`.
            : controller?.connectionKey ?? controller?.gatewaySourceDisplayName
        return SidebarGatewayHeaderItem(
            tab: row.tab,
            tmuxBadge: TmuxTabBadgeResolver.badge(for: row.tab, gatewayOwnerIDs: gatewayOwnerIDs),
            host: host,
            collapsed: collapsed,
            windowCount: windowCount,
            isSelected: isSelected,
            isActive: isActive,
            isHighlighted: isHighlighted,
            indentLevel: row.indentLevel,
            metrics: metrics,
            accentTint: accentTint,
            showsDashboard: !isHerdr,
            isDocked: isDocked,
            staysOpenOnSelect: staysOpenOnSelect,
            onToggleCollapse: { toggleGatewayCollapse(ownerID) },
            onNewWindow: {
                if isHerdr {
                    HerdrController.controller(forGateway: ownerID)?.requestNewTab(inWorkspaceOf: nil)
                } else {
                    onNewTmuxWindow(row.tab)
                }
            },
            onShowDashboard: {
                showTmuxSessionsLocally(row.tab)
            },
            onClose: { onCloseTab(row.tab.id) },
            onTap: {
                highlightedRowID = row.id
                // (id=tmux-hidden-gateway)
                if row.tab.isHiddenTmuxWindow {
                    showHiddenGateway(row.tab)
                } else {
                    onSelectTab(row.tab.id)
                }
                // Same rule as the tab row's tap.
                if staysOpenOnSelect && !isDocked {
                    requestSearchFocus()
                }
            },
            onHoverChange: onTabHover.map { hover in { hover(row.tab.id, $0) } },
            previewAnchors: previewAnchors
        )
    }

    // MARK: Grouping

    private func buildRows() -> [SidebarRow] {
        // Project mode uses the flat list; grouped mode would hide other groups' agents.
        let baseRows = tabsModel.isGroupedModeEnabled && !projectGroupingActive
            ? buildGroupedRows()
            : buildRows(from: tabsModel.tabs)
        let projectSearchActive = projectGroupingActive && !normalizedSearchFilter.isEmpty
        let rows = projectGroupingActive && !projectSearchActive
            ? baseRows
            : addingPaneChildren(
                to: baseRows,
                omitNonmatchingParents: projectSearchActive)
        // Duplicate ids crash SwiftUI; two gateways sharing an owner re-emit its windows.
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

    /// Same projection as the top bar. Each tab has one primary project; extra
    /// panes may appear under other projects without duplicating the tab.
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
                // Window rows already add a level, so both kinds end up level.
                let parent = SidebarRow(tab: tab, kind: kind, flatIndex: flatIndex,
                                        indentLevel: tab.isTmuxWindow ? 0 : 1)
                if seenRows.insert(parent.id).inserted {
                    sectionRows.append(parent)
                }
            }

            for tab in tabsModel.visibleTabs where tab.splitTree.count > 1 {
                let flatIndex = tabsModel.index(of: tab.id) ?? 0
                for paneID in paneIDsForRows(in: tab) where
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

    /// Sorts tab blocks within each section, keeping pane cards with their tab.
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

    /// Filtering and row generation must share this source.
    private func paneIDsForRows(in tab: TabModel) -> [UUID] {
        guard projectGroupingActive else { return tab.agentPaneIDs }
        return tab.splitTree.map(\.uuid)
    }

    private func addingPaneChildren(
        to rows: [SidebarRow],
        omitNonmatchingParents: Bool = false
    ) -> [SidebarRow] {
        guard attentionBadgesEnabled || projectGroupingActive else { return rows }

        var result: [SidebarRow] = []
        result.reserveCapacity(rows.count + tabsModel.tabs.reduce(0) { $0 + $1.splitTree.count })

        for row in rows {
            switch row.kind {
            case .flat, .windowRow:
                guard row.tab.splitTree.count > 1 else {
                    result.append(row)
                    continue
                }
                let parentMatches = searchFilterMatchesTabTitle(row.tab)
                let paneIDs = paneIDsForRows(in: row.tab).filter { paneID in
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
            if let ownerID = group.id.herdrOwnerID {
                rows.append(contentsOf: buildHerdrGatewayGroupRows(from: groupTabs, ownerID: ownerID))
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
        let project = presentation.projectForGrouping ?? tab.herdrWorkspaceProject
        let values = [
            presentation.title,
            row?.agentDisplayName,
            row?.agentID,
            project?.label,
            project?.branch,
            project == nil ? tab.herdrWorkspaceLabel : nil,
        ]
        return values.compactMap { $0 }.contains { $0.lowercased().contains(filter) }
    }

    private func searchFilterMatches(_ tab: TabModel) -> Bool {
        searchFilterMatchesTabTitle(tab)
            || paneIDsForRows(in: tab).contains { searchFilterMatchesPane(tab, paneID: $0) }
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

    /// Workspace headers appear only with several workspaces. (id=herdr-gateway-family)
    private func buildHerdrGatewayGroupRows(from tabs: [TabModel], ownerID: UUID) -> [SidebarRow] {
        let isFiltering = !normalizedSearchFilter.isEmpty

        func matches(_ tab: TabModel) -> Bool {
            !isFiltering || searchFilterMatches(tab)
        }

        guard let gateway = tabs.first(where: {
                  $0.isHerdrGateway && TmuxTabBadgeResolver.herdrOwnerID(for: $0) == ownerID
              }),
              let gatewayFlatIndex = tabsModel.index(of: gateway.id) else {
            return buildRows(from: tabs)
        }

        let children = tabs.filter { $0.id != gateway.id && !$0.isHiddenTmuxWindow }
        let matchingChildren = children.filter(matches)
        let headerMatches = matches(gateway)
        if isFiltering && !headerMatches && matchingChildren.isEmpty {
            return []
        }

        let collapsed = !isFiltering && collapsedGateways.contains(ownerID)
        var rows = [
            SidebarRow(
                tab: gateway,
                kind: .gatewayHeader(collapsed: collapsed, windowCount: children.filter(\.isHerdrWindow).count, ownerID: ownerID),
                flatIndex: gatewayFlatIndex
            )
        ]
        guard !collapsed else { return rows }

        let shown = isFiltering ? (headerMatches ? children : matchingChildren) : children
        var workspaceOrder: [String] = []
        var byWorkspace: [String: [TabModel]] = [:]
        var others: [TabModel] = []
        for child in shown {
            if child.isHerdrWindow, let workspaceId = child.herdrWorkspaceId {
                if byWorkspace[workspaceId] == nil { workspaceOrder.append(workspaceId) }
                byWorkspace[workspaceId, default: []].append(child)
            } else {
                others.append(child)
            }
        }

        let controller = HerdrController.controller(forGateway: ownerID)
        let groups = HerdrWorkspaceRules.groups(controller?.management.workspaces ?? [])
        let groupedOrder = groups.flatMap { $0.map(\.workspace_id) }.filter { byWorkspace[$0] != nil }
        workspaceOrder = groupedOrder + workspaceOrder.filter { !groupedOrder.contains($0) }
        let showsWorkspaces = workspaceOrder.count > 1
        for workspaceId in workspaceOrder {
            let members = byWorkspace[workspaceId] ?? []
            let parent = groups.first { $0.contains { $0.workspace_id == workspaceId } }?.first
            let isLinkedChild = parent.map { $0.workspace_id != workspaceId && byWorkspace[$0.workspace_id] != nil } ?? false
            if isLinkedChild, let parent, !isFiltering,
               collapsedGroups.contains(Self.herdrWorkspaceCollapseKey(ownerID: ownerID, workspaceId: parent.workspace_id)) {
                continue
            }
            let workspaceIndent = isLinkedChild ? 2 : 1
            var indent = 1
            if showsWorkspaces, let first = members.first {
                let key = Self.herdrWorkspaceCollapseKey(ownerID: ownerID, workspaceId: workspaceId)
                let workspaceCollapsed = !isFiltering && collapsedGroups.contains(key)
                let title = members.lazy.compactMap(\.herdrWorkspaceLabel).first(where: { !$0.isEmpty }) ?? workspaceId
                rows.append(SidebarRow(
                    tab: first,
                    kind: .herdrWorkspaceHeader(
                        ownerID: ownerID,
                        workspaceId: workspaceId,
                        title: title,
                        count: members.count,
                        collapsed: workspaceCollapsed
                    ),
                    flatIndex: tabsModel.index(of: first.id) ?? gatewayFlatIndex,
                    indentLevel: workspaceIndent
                ))
                if workspaceCollapsed { continue }
                indent = workspaceIndent + 1
            }
            for member in members {
                guard let flatIndex = tabsModel.index(of: member.id) else { continue }
                rows.append(SidebarRow(tab: member, kind: .flat, flatIndex: flatIndex, indentLevel: indent))
            }
        }
        for other in others {
            guard let flatIndex = tabsModel.index(of: other.id) else { continue }
            rows.append(SidebarRow(tab: other, kind: .flat, flatIndex: flatIndex, indentLevel: 1))
        }
        return rows
    }

    private func buildRows(from tabs: [TabModel]) -> [SidebarRow] {
        let filter = normalizedSearchFilter
        let isFiltering = !filter.isEmpty

        var gatewayByOwner: [UUID: TabModel] = [:]
        for tab in tabs where tab.isTmuxGateway {
            if let ownerID = TmuxTabBadgeResolver.ownerID(for: tab) {
                gatewayByOwner[ownerID] = tab
            }
        }
        var herdrGatewayByOwner: [UUID: TabModel] = [:]
        for tab in tabs where tab.isHerdrGateway {
            if let ownerID = TmuxTabBadgeResolver.herdrOwnerID(for: tab) {
                herdrGatewayByOwner[ownerID] = tab
            }
        }

        // Windows aren't contiguous after their gateway, so bucket by owner.
        // Orphans render flat.
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
            if tab.isHerdrWindow,
               let owner = tab.owningGatewayTerminalUUID,
               herdrGatewayByOwner[owner] != nil {
                continue
            }

            guard let flatIndex = tabsModel.index(of: tab.id) else { continue }

            if tab.isHerdrGateway, let ownerID = TmuxTabBadgeResolver.herdrOwnerID(for: tab) {
                let family = [tab] + tabs.filter { $0.isHerdrWindow && $0.owningGatewayTerminalUUID == ownerID }
                rows.append(contentsOf: buildHerdrGatewayGroupRows(from: family, ownerID: ownerID))
                continue
            }

            if tab.isTmuxGateway, let ownerID = TmuxTabBadgeResolver.ownerID(for: tab) {
                let allWindows = windowsByOwner[ownerID] ?? []
                // (id=tmux-hidden-windows)
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
                    // A gateway match reveals the whole group.
                    let shownWindows = isFiltering ? (headerMatches ? windows : matchingWindows) : windows
                    for window in shownWindows {
                        guard let windowFlatIndex = tabsModel.index(of: window.id) else { continue }
                        rows.append(SidebarRow(tab: window, kind: .windowRow, flatIndex: windowFlatIndex))
                    }

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
                // Hide orphaned hidden placeholders, but always show a hidden
                // gateway: this is its only recovery path. (id=tmux-hidden-gateway)
                guard matches(tab), !tab.isHiddenTmuxWindow || tab.isTmuxGateway else { continue }
                rows.append(SidebarRow(tab: tab, kind: .flat, flatIndex: flatIndex))
            }
        }
        return rows
    }

}

// MARK: - Drag & Drop Reorder

/// System drag and drop needs a press-and-hold, so pans still scroll.
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
                        // `preview` runs during body; deferring keeps every
                        // render from building a second copy of the row.
                        SidebarDeferredDragPreview(build: dragPreview)
                    }
                    .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
            } else {
                content
                    .onDrag { onDragStarted() }
                    .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
            }
        } else {
            // Still accept drops so releasing here commits the arrangement.
            content
                .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: dropDelegate)
        }
    }
}

/// Builds its content only when SwiftUI evaluates this view's body.
private struct SidebarDeferredDragPreview<Content: View>: View {
    let build: () -> Content

    var body: some View { build() }
}

private struct SidebarRowDropDelegate: DropDelegate {
    /// `SidebarRow.id`, not the tab id, which several rows share.
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

// MARK: - Sidebar Context Menu Isolation

/// Equatable owner for `.contextMenu`, so neither live label updates nor parent
/// renders rebuild the menu. `content` still observes in its own scope.
private struct SidebarContextMenuRow<Identity: Equatable, RowContent: View, MenuContent: View>: View, Equatable {
    let identity: Identity
    let content: RowContent
    let menu: () -> MenuContent

    init(
        identity: Identity,
        @ViewBuilder content: () -> RowContent,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.identity = identity
        self.content = content()
        self.menu = menu
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
    }

    var body: some View {
        content.contextMenu {
            SidebarContextMenuContents(build: menu)
        }
    }
}

/// Non-equatable and lazily built, so each presentation reads current state.
private struct SidebarContextMenuContents<Content: View>: View {
    @ViewBuilder let build: () -> Content

    var body: some View {
        build()
    }
}

// MARK: - Sidebar Tab Row

/// Per-tab observed reads happen here, scoping invalidation to this row.
/// `.contextMenu` stays outside, or spinner updates would rebuild the menu.
private struct SidebarTabRowItem: View, Equatable {
    let tab: TabModel
    /// Precomputed by the parent so `==` catches recolors and rows don't each
    /// walk every split tree.
    let tmuxBadge: TmuxTabBadge?
    let attentionBadgesEnabled: Bool
    let programIconsEnabled: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let shortcutHint: String?
    let metrics: SidebarMetrics
    let accentTint: Color
    let onClose: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil
    var previewAnchors: TabHoverPreviewAnchorRegistry? = nil

    // Parent inputs only; observed reads in `body` still update live. Unlike
    // TabBarItem, no index (onClose captures tab.id) and no badge color (the
    // theme is observed in `body`).
    static func == (lhs: SidebarTabRowItem, rhs: SidebarTabRowItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.tmuxBadge == rhs.tmuxBadge
            && lhs.attentionBadgesEnabled == rhs.attentionBadgesEnabled
            && lhs.programIconsEnabled == rhs.programIconsEnabled
            && lhs.isSelected == rhs.isSelected
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.indentLevel == rhs.indentLevel
            && lhs.shortcutHint == rhs.shortcutHint
            && lhs.metrics == rhs.metrics
            && lhs.accentTint == rhs.accentTint
            && lhs.previewAnchors === rhs.previewAnchors
            && (lhs.onHoverChange != nil) == (rhs.onHoverChange != nil)
    }

    var body: some View {
        // Split tabs become a rollup row with pane cards below.
        let solePane = tab.splitTree.count == 1 ? tab.splitTree.first : nil
        let agentRow: AgentRowState? = attentionBadgesEnabled ? solePane?.presentation.agentRow : nil
        SidebarTabRow(
            title: tab.title,
            roamProtocol: tab.activeRoamProtocol,
            tmuxBadge: tmuxBadge,
            tmuxBadgePalette: .currentTheme,
            agentRow: agentRow,
            // Same pane the top tab's logo follows.
            programMark: programIconsEnabled
                ? (tab.focusedPane ?? tab.splitTree.first)?.presentation.foregroundProgram?.mark : nil,
            attentionBadge: attentionBadgesEnabled ? tab.attentionBadge : nil,
            // The agent's own pane's project, not the focused pane's. (id=agent-project)
            contextLine: agentRow?.project,
            isSelected: isSelected,
            isHighlighted: isHighlighted,
            indentLevel: indentLevel,
            shortcutHint: shortcutHint,
            metrics: metrics,
            accentTint: accentTint,
            showsCloseButton: true,
            onClose: onClose,
            onHoverChange: onHoverChange,
            previewAnchorTabID: previewAnchors == nil ? nil : tab.id,
            previewAnchors: previewAnchors
        )
    }
}

/// Observed reads live here so updates invalidate only this card.
private struct SidebarPaneRowItem: View, Equatable {
    let tab: TabModel
    let paneID: UUID
    let attentionBadgesEnabled: Bool
    let programIconsEnabled: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let metrics: SidebarMetrics
    let accentTint: Color

    static func == (lhs: SidebarPaneRowItem, rhs: SidebarPaneRowItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.paneID == rhs.paneID
            && lhs.attentionBadgesEnabled == rhs.attentionBadgesEnabled
            && lhs.programIconsEnabled == rhs.programIconsEnabled
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
                programMark: programIconsEnabled ? presentation.foregroundProgram?.mark : nil,
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

/// Separate view to scope the `AgentAttentionCenter.revision` read. (id=agent-attention)
private struct SidebarAgentSummaryBar: View {
    let metrics: SidebarMetrics
    let accentTint: Color
    let hasProjects: Bool
    let showsAttention: Bool
    let sortIconName: String
    let sortHelp: String
    let sortIsActive: Bool
    let onCycleSort: () -> Void
    let onOpenInbox: () -> Void

    var body: some View {
        // Registers the Observation dependency; the value itself is meaningless.
        let _ = AgentAttentionCenter.shared.revision
        let hasAgents = showsAttention && !AgentAttentionCenter.shared.globalAgentCounts().isEmpty
        let unread = AgentInboxStore.shared.unreadActions.count
        if hasAgents || hasProjects || unread > 0 {
            HStack(spacing: 6) {
                if hasAgents {
                    Button(action: onOpenInbox) {
                        AttentionRollupSummary(fontSize: metrics.subtitleSize + 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Agent Inbox")
                } else if hasProjects {
                    Text("Projects")
                        .font(.system(size: metrics.subtitleSize + 1))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if unread > 0 {
                    Button(action: onOpenInbox) {
                        HStack(spacing: 3) {
                            Image(systemName: "tray.full")
                            Text("\(unread)").monospacedDigit()
                        }
                        .font(.system(size: metrics.subtitleSize + 1, weight: .medium))
                        .foregroundColor(accentTint)
                        .frame(height: metrics.headerButtonTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Agent Inbox")
                    .accessibilityLabel(Text("Agent Inbox, \(unread) unread"))
                }
                if hasAgents || hasProjects {
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}

// MARK: - Sidebar Gateway Header Row

/// Same isolation contract as `SidebarTabRowItem`.
private struct SidebarGatewayHeaderItem: View, Equatable {
    let tab: TabModel
    let tmuxBadge: TmuxTabBadge?
    let host: String?
    let collapsed: Bool
    let windowCount: Int
    let isSelected: Bool
    /// The selected tab is in this family, possibly a child window.
    let isActive: Bool
    let isHighlighted: Bool
    let indentLevel: Int
    let metrics: SidebarMetrics
    let accentTint: Color
    /// False for herdr, which has no sessions dashboard.
    var showsDashboard: Bool = true
    /// Compared because `onTap`'s focus routing captures them.
    let isDocked: Bool
    let staysOpenOnSelect: Bool
    let onToggleCollapse: () -> Void
    let onNewWindow: () -> Void
    let onShowDashboard: () -> Void
    let onClose: () -> Void
    let onTap: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil
    var previewAnchors: TabHoverPreviewAnchorRegistry? = nil

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            && lhs.showsDashboard == rhs.showsDashboard
            && lhs.isDocked == rhs.isDocked
            && lhs.staysOpenOnSelect == rhs.staysOpenOnSelect
            && lhs.previewAnchors === rhs.previewAnchors
            && (lhs.onHoverChange != nil) == (rhs.onHoverChange != nil)
    }

    var body: some View {
        // The tab's observable mirror; TmuxController isn't observable.
        let subtitle = Self.subtitle(
            sessionName: tab.tmuxSessionName ?? tab.herdrSessionName,
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

            HStack(spacing: 4) {
                Button(action: onNewWindow) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: metrics.rowIconSize, weight: .medium))
                        .foregroundColor(accentTint)
                        .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
                .help(showsDashboard ? "New tmux window" : "New herdr tab")

                if showsDashboard {
                    Button(action: onShowDashboard) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: metrics.rowIconSize, weight: .medium))
                            .foregroundColor(accentTint)
                            .frame(width: metrics.rowButtonTarget, height: metrics.rowButtonTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
                    .help("tmux sessions")
                }

                SidebarRowCloseButton(
                    isCloseHovered: $isCloseHovered,
                    iconSize: metrics.closeIconSize,
                    target: metrics.rowButtonTarget,
                    action: onClose
                )
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
            }
        }
        .opacity(isHidden ? 0.55 : 1)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .frame(height: metrics.tabRowHeight)
        .contentShape(Rectangle())
        .background(
            SidebarRowHoverBackground(
                fill: backgroundFill,
                isHovered: isHovered && !isActive && !isHighlighted,
                reduceMotion: reduceMotion
            )
        )
        .background(
            Group {
                if let previewAnchors {
                    TabHoverPreviewAnchor(tabID: tab.id, source: .sidebar, registry: previewAnchors)
                }
            }
        )
        .onHover { hovering in
            isHovered = hovering
            if !hovering { isCloseHovered = false }
            onHoverChange?(hovering)
        }
        .onTapGesture(perform: onTap)
    }

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
    /// Non-nil makes a three-line card. (id=agent-attention)
    var agentRow: AgentRowState? = nil
    /// Shell or program logo, shown only on plain rows; cards carry their own.
    var programMark: BrandMark? = nil
    /// Dot shown only on plain rows; cards show status on line 1.
    var attentionBadge: AgentAttentionStatus? = nil
    var contextLine: AgentProjectIdentity? = nil
    let isSelected: Bool
    var isHighlighted: Bool = false
    var indentLevel: Int = 0
    let shortcutHint: String?
    let metrics: SidebarMetrics
    /// See `VerticalTabSidebar.accentTint`.
    let accentTint: Color
    var showsCloseButton: Bool = true
    let onClose: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil
    /// Nil for pane rows, which have no hover preview.
    var previewAnchorTabID: UUID? = nil
    var previewAnchors: TabHoverPreviewAnchorRegistry? = nil

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(indentLevel) * 20)
        .frame(height: agentRow != nil ? metrics.agentCardRowHeight : metrics.tabRowHeight)
        .contentShape(Rectangle())
        .background(
            SidebarRowHoverBackground(
                fill: backgroundFill,
                isHovered: isHovered && !isSelected && !isHighlighted,
                reduceMotion: reduceMotion
            )
        )
        .background(
            Group {
                if let previewAnchors, let previewAnchorTabID {
                    TabHoverPreviewAnchor(tabID: previewAnchorTabID, source: .sidebar, registry: previewAnchors)
                }
            }
        )
        .onHover { hovering in
            isHovered = hovering
            if !hovering { isCloseHovered = false }
            onHoverChange?(hovering)
        }
    }

    // MARK: Card lines

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

    /// The branch truncates before the project; no project leaves a blank line.
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
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
        }
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isSelected ? accentTint : Color.primary.opacity(0.25))
                .frame(width: 6, height: 6)
                .opacity(recedingOpacity)

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

            if agentRow == nil, let programMark {
                AgentBrandMark(mark: programMark, size: metrics.subtitleSize + 1)
            }

            // Titles never recede; only agent metadata does.
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
                SidebarRowCloseButton(
                    isCloseHovered: $isCloseHovered,
                    iconSize: metrics.closeIconSize,
                    target: metrics.rowButtonTarget,
                    action: onClose
                )
                .opacity(recedingOpacity)
                .frame(width: metrics.trailingAccessoryWidth, alignment: .center)
            } else {
                trailingAccessoryPlaceholder
            }
        }
    }

    /// Holds the accessory rail's width on rows without a close button.
    private var trailingAccessoryPlaceholder: some View {
        Color.clear
            .frame(width: metrics.trailingAccessoryWidth, height: 1)
            .accessibilityHidden(true)
    }

    /// Unread work reads bolder even when unselected (t3code).
    private var titleWeight: Font.Weight {
        if isSelected { return .semibold }
        if agentRow?.unread == true { return .semibold }
        return .regular
    }

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

    private var backgroundFill: Color {
        if isHighlighted { return accentTint.opacity(0.22) }
        if isSelected { return accentTint.opacity(0.12) }
        return .clear
    }
}

/// Only the hover layer animates.
private struct SidebarRowHoverBackground: View {
    let fill: Color
    let isHovered: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .opacity(isHovered ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

/// Close glyph with the integrated tab's hover disc behind it.
private struct SidebarRowCloseButton: View {
    @Binding var isCloseHovered: Bool
    let iconSize: CGFloat
    let target: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .light ? 0.10 : 0.14))
                    .frame(width: 20, height: 20)
                    .opacity(isCloseHovered ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isCloseHovered)

                Image(systemName: "xmark")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(isCloseHovered ? .primary : .secondary.opacity(0.7))
            }
            .frame(width: target, height: target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
    }
}
