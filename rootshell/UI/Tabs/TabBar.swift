//
//  TabBar.swift
//  rootshell
//
//  Tab bar view extracted from MainView. Per-tab reads
//  (`tab.title`, `tab.connectionHealth`, `tab.activeRoamProtocol`)
//  happen inside `TabBarItem.body`, a real `View` struct rendered for
//  each tab. SwiftUI establishes a per-instance Observation scope on
//  each `TabBarItem`, so a title or health change on tab N invalidates
//  only that one item's body — not `TabBar.body`, not `MainView.body`,
//  and not its sibling tabs. This is what keeps drag/open/close/select
//  animations smooth: the bar's animation transaction isn't disrupted
//  mid-flight by an OSC 0/2 title burst on a different tab.
//
//  An earlier design rendered each tab through a `@ViewBuilder` method
//  (`tabButton(for:index:...)`) invoked from `ForEach`. SwiftUI does
//  NOT establish per-child Observation scopes for `@ViewBuilder` method
//  call sites, so per-tab reads registered against the parent body. The
//  workaround was an aggregator read at TabBar.body scope, which fixed
//  inactive-tab title staleness by invalidating the entire ForEach on
//  every per-tab change. Real `TabBarItem` View structs scope cleanly
//  and do not need that workaround.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Content-aware tab sizing

@MainActor
enum TabBarSizingPolicy {
    struct Item: Equatable {
        let hasTmuxBadge: Bool
        let hasAttentionBadge: Bool
        let hasThemeOverride: Bool
        let shortcut: String?
    }

    struct Decision: Equatable {
        let mode: MainView.TabBarDisplayMode
        let equalTabWidth: CGFloat
        let singleTabWidth: CGFloat
        let scrollingTabWidth: CGFloat
    }

    static func decision(
        availableWidth: CGFloat,
        items: [Item],
        style: TopTabStyle = .pills,
        usesCompactSpacing: Bool = false
    ) -> Decision {
        guard let first = items.first else {
            return Decision(mode: .singleTab, equalTabWidth: 0, singleTabWidth: 0, scrollingTabWidth: 0)
        }

        if style == .integrated || usesCompactSpacing {
            let tabCount = CGFloat(items.count)
            let equalWidth = availableWidth / max(tabCount, 1)
            let resolvedWidth = min(integratedMaximumWidth, equalWidth)
            let requiredWidth = min(
                integratedMaximumWidth,
                max(
                    integratedMinimumFloorWidth,
                    items.map(integratedReadableMinimumWidth(for:)).max()
                        ?? integratedMinimumFloorWidth
                )
            )

            if items.count == 1 {
                return Decision(
                    mode: .singleTab,
                    equalTabWidth: resolvedWidth,
                    singleTabWidth: resolvedWidth,
                    scrollingTabWidth: min(
                        integratedMaximumWidth,
                        max(requiredWidth, resolvedWidth)
                    )
                )
            }

            if equalWidth >= requiredWidth {
                return Decision(
                    mode: .equalWidth,
                    equalTabWidth: resolvedWidth,
                    singleTabWidth: 0,
                    scrollingTabWidth: resolvedWidth
                )
            }

            return Decision(
                mode: .scrolling,
                equalTabWidth: 0,
                singleTabWidth: 0,
                scrollingTabWidth: requiredWidth
            )
        }

        if items.count == 1 {
            let defaultWidth = availableWidth * 0.8
            let minimumWidth = readableMinimumWidth(for: first)
            let width = min(availableWidth, max(defaultWidth, minimumWidth))
            return Decision(
                mode: .singleTab,
                equalTabWidth: width,
                singleTabWidth: width,
                scrollingTabWidth: min(width, scrollingMaximumWidth)
            )
        }

        let equalTabSpacing: CGFloat = 4
        let equalAvailableWidth = max(0, availableWidth - (CGFloat(items.count - 1) * equalTabSpacing))
        let equalWidth = equalAvailableWidth / CGFloat(max(items.count, 1))
        let requiredWidth = max(minimumFloorWidth, items.map(readableMinimumWidth(for:)).max() ?? minimumFloorWidth)
        let mode: MainView.TabBarDisplayMode = equalWidth >= requiredWidth ? .equalWidth : .scrolling
        let scrollWidth = min(scrollingMaximumWidth, max(requiredWidth, minimumFloorWidth))

        return Decision(
            mode: mode,
            equalTabWidth: equalWidth,
            singleTabWidth: 0,
            scrollingTabWidth: scrollWidth
        )
    }

    static func singleTabWidth(
        availableWidth: CGFloat,
        item: Item,
        title: String,
        showHealthIndicator: Bool,
        healthRTTMilliseconds: Double?
    ) -> CGFloat {
        let defaultWidth = availableWidth * 0.8
        let minimumWidth = ceil(
            chromeWidth
                + metadataWidth(for: item)
                + titleWidth(title)
                + singleTabHealthWidth(
                    showHealthIndicator: showHealthIndicator,
                    rttMilliseconds: healthRTTMilliseconds
                )
        )
        return min(availableWidth, max(defaultWidth, minimumWidth))
    }

    private static var minimumFloorWidth: CGFloat {
        #if os(visionOS)
        return 180
        #elseif targetEnvironment(macCatalyst)
        return 120
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? 160 : 120
        #endif
    }

    private static var integratedMinimumFloorWidth: CGFloat {
        #if os(visionOS)
        return 180
        #elseif targetEnvironment(macCatalyst)
        return 120
        #else
        return 160
        #endif
    }

    private static let integratedMaximumWidth: CGFloat = 240

    private static var readableTitleBudget: CGFloat {
        #if os(visionOS)
        return 96
        #elseif targetEnvironment(macCatalyst)
        return 72
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? 84 : 72
        #endif
    }

    private static var scrollingMaximumWidth: CGFloat {
        #if os(visionOS)
        return 280
        #elseif targetEnvironment(macCatalyst)
        return 240
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? 220 : 240
        #endif
    }

    private static func readableMinimumWidth(for item: Item) -> CGFloat {
        ceil(chromeWidth + metadataWidth(for: item) + readableTitleBudget)
    }

    private static func integratedReadableMinimumWidth(for item: Item) -> CGFloat {
        ceil(integratedChromeWidth + metadataWidth(for: item) + readableTitleBudget)
    }

    /// Fixed integrated-tab layout outside the title itself: leading inset,
    /// title/close spacing, the 44pt close target, and trailing inset.
    private static var integratedChromeWidth: CGFloat {
        (TabMetrics.horizontalPadding + 8) + 4 + 44 + 4
    }

    private static var chromeWidth: CGFloat {
        #if os(visionOS)
        return (TabMetrics.horizontalPadding * 2) + TabMetrics.closeButtonSize + 8
        #else
        return (TabMetrics.titleInnerPadding * 2) + (TabMetrics.horizontalPadding * 2)
        #endif
    }

    private static func metadataWidth(for item: Item) -> CGFloat {
        var widths: [CGFloat] = []

        if item.hasTmuxBadge {
            widths.append(18)
        }
        if item.hasAttentionBadge {
            widths.append(8)
        }
        if item.hasThemeOverride {
            widths.append(12)
        }
        if let shortcut = item.shortcut {
            widths.append(shortcutWidth(shortcut))
        }

        let titleElementCount = 1
        let spacing = CGFloat(max(0, widths.count + titleElementCount - 1)) * 6
        return widths.reduce(0, +) + spacing
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: TabMetrics.titleFontSize, weight: .medium)
        return (title as NSString).size(withAttributes: [.font: font]).width
        #else
        return CGFloat(title.count) * TabMetrics.titleFontSize * 0.6
        #endif
    }

    private static func singleTabHealthWidth(
        showHealthIndicator: Bool,
        rttMilliseconds: Double?
    ) -> CGFloat {
        guard showHealthIndicator else { return 0 }

        var width: CGFloat = 6 // status dot
        if let rttMilliseconds {
            #if canImport(UIKit)
            let font = UIFont.monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
            let text = "\(Int(rttMilliseconds))ms"
            width += 4 + (text as NSString).size(withAttributes: [.font: font]).width
            #else
            width += 4 + CGFloat("\(Int(rttMilliseconds))ms".count) * 7
            #endif
        }

        return width + 6 // spacing between title/metadata and indicator
    }

    private static func shortcutWidth(_ shortcut: String) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: 11, weight: .regular)
        return (shortcut as NSString).size(withAttributes: [.font: font]).width
        #else
        return CGFloat(shortcut.count) * 7
        #endif
    }

}

struct TabBar: View {

    // MARK: - Pre-resolved per-body inputs from MainView

    let theme: ResolvedTabBarTheme
    let availableWidth: CGFloat
    let style: TopTabStyle
    let usesCompactSpacing: Bool

    // MARK: - Structural / references

    /// `tabsModel.tabs` is read inside this view's body — that is the
    /// whole point of the extraction. With the read happening here,
    /// per-tab Observation registers on `TabBar.body`, not on
    /// `MainView.body`.
    let tabsModel: TabsModel
    @Binding var selectedTabIndex: Int
    let windowId: String
    let usesTitlebarTabs: Bool
    let sshHealthMonitoringEnabled: Bool
    let tabNamespace: Namespace.ID
    let canAcceptWindowTransferDrop: Bool
    let suppressSelectionAnimation: Bool

    // MARK: - State propagated up

    @Binding var wigglingTabIds: Set<UUID>
    @Binding var tabFrames: [UUID: CGRect]

    // MARK: - Actions / lookups

    /// Closures bound to MainView state. Captured at construction and
    /// invoked from button taps, context menus, and drag completions.
    let onCloseTab: (Int) -> Void
    let onMoveTab: (Int, Int) -> Void
    let onSelectTab: (Int) -> Void
    let keyboardShortcut: (Int) -> String?
    let onTabHover: (UUID, Bool) -> Void
    let tabHasThemeOverride: (UUID) -> Bool
    let onClearThemeOverride: (UUID) -> Void
    let onShowConnectionInfo: (TabModel) -> Void
    /// Predicate: should the "Transfer to Nearby Device…" item appear in this
    /// tab's context menu? Evaluated lazily when the menu is presented, so the
    /// per-tab roam/session walk does not run during normal ForEach rendering.
    let canTransferToNearby: (TabModel) -> Bool
    let onTransferToNearby: (TabModel) -> Void
    let onMoveTabToNewWindow: (TabModel) -> Void
    let onMoveTabsToNewWindow: ([UUID]) -> Void
    /// Create a new tmux window in this tab's gateway/session. Only shown on
    /// tmux control-mode window tabs (`tab.isTmuxWindow`), never the gateway.
    let onNewTmuxWindow: (TabModel) -> Void
    /// Open the tmux session dashboard for this tab's gateway. Shown on the
    /// gateway tab and on tmux window tabs.
    let onShowTmuxSessions: (TabModel) -> Void
    /// Resolve the tmux controller backing a tab (MainView's
    /// `tmuxControllerForTab`). Used by the shared tmux menu items
    /// (rename, move-to-session, hide, detach).
    let tmuxController: (TabModel) -> TmuxController?

    // MARK: - User preferences

    @AppStorage("tabBarAnimationsDisabled") private var tabBarAnimationsDisabled: Bool = false
    @AppStorage(UserPreferences.showTabScopeMenuKey) private var showTabScopeMenu: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Dialog state

    /// Rename/detach dialog state for the shared tmux menu items
    /// (TmuxTabMenu.swift). TabBar is a stable child of MainView, so this
    /// @State persists across menu presentations.
    @State private var tmuxDialogs = TmuxTabDialogCoordinator()

    /// Gates the attention dot on tabs. (id=agent-attention)
    @AppStorage(AgentAttentionSettings.badgesEnabledKey) private var attentionBadgesEnabled = true

    // MARK: - Body

    var body: some View {
        let decision = sizingDecision()
        Group {
            switch decision.mode {
            case .singleTab:
                singleTabView(width: decision.singleTabWidth)
            case .equalWidth:
                equalWidthView(tabWidth: decision.equalTabWidth)
            case .scrolling:
                scrollingView(tabWidth: decision.scrollingTabWidth)
            }
        }
        // GeometryReader places an intrinsic-height child at its top edge.
        // Fill the 44pt track and use `.leading` (vertically centered) so a
        // 32pt pill aligns with the full-height add/settings controls.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .tmuxTabDialogs(coordinator: tmuxDialogs, controller: tmuxController)
        .overlay {
            if canAcceptWindowTransferDrop {
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [TabTransferCoordinator.dragUTType],
                        delegate: WindowTabTransferDropDelegate(
                            windowId: windowId,
                            insertionIndex: {
                                tabsModel.selectedTabID
                                    .flatMap { tabsModel.index(of: $0) }
                                    .map { $0 + 1 }
                            },
                            groupOverride: {
                                tabsModel.isGroupedModeEnabled ? tabsModel.activeGroupID : nil
                            },
                            isWindowFocused: {
                                true
                            }
                        )
                    )
            }
        }
        // Warm each gateway's session cache so the "Move to Session"
        // context-menu picker (a synchronous ViewBuilder) has data — the
        // same warm-up the vertical sidebar does on appear.
        .onAppear { warmTmuxSessionCaches() }
        .onChange(of: tabsModel.tabs.count) { _, _ in warmTmuxSessionCaches() }
    }

    private func warmTmuxSessionCaches() {
        for tab in tabsModel.tabs where tab.isTmuxGateway {
            tmuxController(tab)?.refreshSessionsCache()
        }
    }

    private func sizingDecision() -> TabBarSizingPolicy.Decision {
        let tabs = tabsModel.tabs
        let navigationTabs = tabsModel.navigationTabs
        let gatewayOwnerIDs = TmuxTabBadgeResolver.activeGatewayOwnerIDs(in: tabs)
        let items = navigationTabs.map { tab in
            let index = tabsModel.index(of: tab.id) ?? 0
            return sizingItem(for: tab, index: index, gatewayOwnerIDs: gatewayOwnerIDs)
        }
        return TabBarSizingPolicy.decision(
            availableWidth: max(0, availableWidth - activeScopeMenuWidth),
            items: items,
            style: style,
            usesCompactSpacing: usesCompactSpacing
        )
    }

    private var activeScopeMenuWidth: CGFloat {
        guard showTabScopeMenu,
              tabsModel.orderProjection.mode != .flat,
              let title = tabsModel.orderProjection.activeScopeTitle else { return 0 }
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        return min(170, max(66, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 46))
        #else
        return min(170, max(66, CGFloat(title.count * 7) + 46))
        #endif
    }

    private func sizingItem(
        for tab: TabModel,
        index: Int,
        gatewayOwnerIDs: [UUID]
    ) -> TabBarSizingPolicy.Item {
        let navigationIndex = tabsModel.navigationIndex(of: tab.id) ?? index
        return TabBarSizingPolicy.Item(
            hasTmuxBadge: TmuxTabBadgeResolver.badge(for: tab, gatewayOwnerIDs: gatewayOwnerIDs) != nil,
            hasAttentionBadge: attentionBadgesEnabled && tab.attentionBadge != nil,
            hasThemeOverride: tabHasThemeOverride(tab.id),
            shortcut: keyboardShortcut(navigationIndex)
        )
    }

    // MARK: - Per-tab building blocks (used by all three modes)

    /// Build a `TabBarItem` for the given tab. Per-tab Observation reads
    /// (`title`, `connectionHealth`, `activeRoamProtocol`) live inside
    /// `TabBarItem.body`, not here.
    private func tabItem(
        for tab: TabModel,
        index: Int,
        isOnly: Bool,
        gatewayOwnerIDs: [UUID],
        tabWidth: CGFloat
    ) -> TabBarItem {
        let tmuxBadge = TmuxTabBadgeResolver.badge(for: tab, gatewayOwnerIDs: gatewayOwnerIDs)
        return TabBarItem(
            tab: tab,
            index: index,
            tmuxBadge: tmuxBadge,
            // Precomputed badge tint. The rendered color comes from the theme
            // palette (`themeColors.palette` / accent / `baseColor` / isLight via
            // `TmuxTabBadgePalette`), which the other compared theme fields do
            // NOT cover — a palette-only custom-theme edit reloads the theme and
            // changes this without touching selected/unselected/text colors.
            // Stored so `==` compares the actual color and can't skip a stale
            // badge. (Body still renders from the live palette → identical color.)
            tmuxBadgeColor: tmuxBadge?.color(in: TmuxTabBadgePalette(theme: theme)),
            // Attention dot input. Stored (not derived in the item's body) so
            // `==` compares it — a rollup change must re-render even when
            // every other parent-side input is unchanged. (id=agent-attention)
            attentionBadge: attentionBadgesEnabled ? tab.attentionBadge : nil,
            isSelected: index == selectedTabIndex,
            isOnly: isOnly,
            theme: theme,
            tabNamespace: tabNamespace,
            isWiggling: wigglingTabIds.contains(tab.id),
            sshHealthMonitoringEnabled: sshHealthMonitoringEnabled,
            // Shortcut hints use the navigable position: grouped mode scopes
            // Cmd+N to the active group, and hidden tmux windows are skipped.
            keyboardShortcut: keyboardShortcut(tabsModel.navigationIndex(of: tab.id) ?? index),
            usesTitlebarTabs: usesTitlebarTabs,
            style: style,
            tabWidth: tabWidth,
            hasThemeOverride: tabHasThemeOverride(tab.id),
            onTap: {
                if !isOnly { onSelectTab(index) }
            },
            onClose: { onCloseTab(index) },
            onHover: { isHovered in
                onTabHover(tab.id, isHovered)
            }
        )
    }

    /// Context menu for a tab in `equalWidth` or `scrolling` mode. Singletab
    /// mode uses its own minimal menu inline.
    @ViewBuilder
    private func tabContextMenu(
        for tab: TabModel,
        index: Int,
        moveLeftTarget: Int?,
        moveRightTarget: Int?,
        includeThemeOverrideClear: Bool
    ) -> some View {
        Button {
            onShowConnectionInfo(tab)
        } label: {
            Label("Connection Info", systemImage: "info.circle")
        }
        .disabled(tab.connectionInfo == nil)
        TmuxTabMenuItems(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs,
            onNewTmuxWindow: onNewTmuxWindow,
            onShowTmuxSessions: onShowTmuxSessions
        )
        if canTransferToNearby(tab) {
            Button {
                onTransferToNearby(tab)
            } label: {
                Label("Transfer to Nearby Device", systemImage: "ipad.and.arrow.forward")
            }
        }
        // The gateway tab offers the whole-gateway move (gateway + windows);
        // ordinary and individual window tabs keep the single-tab move.
        if !tab.isTmuxGateway {
            moveToWindowItems(for: tab)
        }
        moveGroupToWindowItems(for: tab)
        if tabsModel.isGroupedModeEnabled,
           tabsModel.tabGroupOverrides[tab.id] != nil {
            Button {
                tabsModel.clearGroupOverride(for: tab.id)
            } label: {
                Label("Move to Automatic Group", systemImage: "arrow.uturn.left")
            }
        }
        Divider()
        // Move targets are rendered-tab neighbors translated back to raw
        // indices, so grouped mode reorders within the active navigation set
        // and hidden tmux windows are skipped. (id=tmux-hidden-windows)
        if let moveLeftTarget {
            Button {
                onMoveTab(index, moveLeftTarget)
            } label: {
                Label("Move Left", systemImage: "arrow.left")
            }
        }
        if let moveRightTarget {
            Button {
                onMoveTab(index, moveRightTarget)
            } label: {
                Label("Move Right", systemImage: "arrow.right")
            }
        }
        if includeThemeOverrideClear, tabHasThemeOverride(tab.id) {
            Divider()
            Button {
                onClearThemeOverride(tab.id)
            } label: {
                Label("Clear Theme Override", systemImage: "paintbrush")
            }
        }
        Divider()
        TmuxGatewayDetachMenuItem(
            tab: tab,
            controller: tmuxController(tab),
            dialogs: tmuxDialogs
        )
        Button(role: .destructive) {
            onCloseTab(index)
        } label: {
            Label("Close Tab", systemImage: "xmark")
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

    /// Whole-gateway "Move to Window" for the gateway tab in the top bar: moves
    /// the gateway tab plus all its window tabs as one unit. Members come from
    /// `availableGroups`, so children overridden into a different group are
    /// excluded automatically.
    @ViewBuilder
    private func moveGroupToWindowItems(for tab: TabModel) -> some View {
        if tab.isTmuxGateway,
           TabTransferCoordinator.canOfferWindowTransfers,
           let ownerID = TmuxTabBadgeResolver.ownerID(for: tab) ?? tab.owningGatewayTerminalUUID {
            // Whole tmux family by owner id (not availableGroups, which drops
            // children overridden into another group) so the gateway + all its
            // windows travel together and adoption stays coherent once the
            // controller's baseWindowId moves.
            let tabIDs = tabsModel.tmuxFamilyTabIDs(ownerID: ownerID)
            if TabTransferCoordinator.shared.canTransferEntireBatch(tabIDs, in: windowId) {
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
                    Label("Move Gateway to Window", systemImage: "arrowshape.turn.up.right")
                }
            }
        }
    }

    /// Drag modifier reused by `equalWidth` and `scrolling` cases.
    private func dragModifier(for tab: TabModel, index: Int) -> TabDragModifier {
        TabDragModifier(
            tab: tab,
            index: index,
            windowId: windowId,
            tabsModel: tabsModel,
            tabFrames: tabFrames,
            usesTitlebarTabs: usesTitlebarTabs
        )
    }

    private func moveTargetRawIndex(for tab: TabModel, delta: Int) -> Int? {
        let orderedTabs = tabsModel.navigationTabs
        guard let visibleIndex = orderedTabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let targetVisibleIndex = visibleIndex + delta
        guard orderedTabs.indices.contains(targetVisibleIndex) else { return nil }
        return tabsModel.index(of: orderedTabs[targetVisibleIndex].id)
    }

    @ViewBuilder
    private var activeScopeMenu: some View {
        if showTabScopeMenu {
            switch tabsModel.orderProjection.mode {
            case .flat:
                EmptyView()

            case .userGrouped:
                if let title = tabsModel.orderProjection.activeScopeTitle {
                    Menu {
                        ForEach(tabsModel.orderedGroups) { group in
                            Button {
                                guard let targetID = tabsModel.preferredTabID(inGroup: group),
                                      let rawIndex = tabsModel.index(of: targetID) else { return }
                                onSelectTab(rawIndex)
                            } label: {
                                if tabsModel.activeGroupID == group.id {
                                    Label(group.title, systemImage: "checkmark")
                                } else {
                                    Text(group.title)
                                }
                            }
                        }
                    } label: {
                        scopeMenuLabel(title: title, systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 170)
                    .help("Active tab group")
                    .accessibilityLabel("Active tab group: \(title)")
                }

            case .projectGrouped:
                if let title = tabsModel.orderProjection.activeScopeTitle {
                    Menu {
                        ForEach(tabsModel.projectSections.filter { !$0.tabIDs.isEmpty }) { section in
                            Button {
                                guard let targetID = tabsModel.preferredTabID(inProjectSection: section),
                                      let rawIndex = tabsModel.index(of: targetID) else { return }
                                onSelectTab(rawIndex)
                            } label: {
                                if tabsModel.orderProjection.activeProjectID == section.id {
                                    Label(section.title, systemImage: "checkmark")
                                } else {
                                    Text(section.title)
                                }
                            }
                        }
                    } label: {
                        scopeMenuLabel(title: title, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 170)
                    .help("Active project")
                    .accessibilityLabel("Active project: \(title)")
                }
            }
        }
    }

    private func scopeMenuLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))

            Text(title)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.65)
        }
        .font(.system(size: 11, weight: .medium))
        // Keep this adaptive to the terminal theme, but visually secondary to
        // the selected tab. The rounded rectangle also distinguishes this as
        // a scope selector instead of another tab.
        .foregroundStyle(theme.tabSecondaryText)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            theme.unselectedBackground.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.tabText.opacity(0.08), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Single tab

    @ViewBuilder
    private func singleTabView(width fallbackWidth: CGFloat) -> some View {
        // First VISIBLE tab: with hidden tmux windows present, tabs.first may
        // be hidden while only one tab is user-visible. Raw index preserved
        // for the close callback. (id=tmux-hidden-windows)
        if let tab = tabsModel.navigationTabs.first {
            let rawIndex = tabsModel.index(of: tab.id) ?? 0
            let gatewayOwnerIDs = TmuxTabBadgeResolver.activeGatewayOwnerIDs(in: tabsModel.tabs)
            let tabWidth = usesCompactSpacing ? fallbackWidth : TabBarSizingPolicy.singleTabWidth(
                availableWidth: max(0, availableWidth - activeScopeMenuWidth),
                item: sizingItem(for: tab, index: rawIndex, gatewayOwnerIDs: gatewayOwnerIDs),
                title: tab.title,
                showHealthIndicator: sshHealthMonitoringEnabled && tab.connectionHealth?.quality == .poor,
                healthRTTMilliseconds: tab.connectionHealth?.rttMilliseconds
            )
            let resolvedWidth = tabWidth > 0 ? tabWidth : fallbackWidth
            HStack(spacing: 0) {
                if !usesCompactSpacing {
                    singleTabFlexibleMargin()
                }

                HStack(spacing: usesCompactSpacing ? 0 : 4) {
                    activeScopeMenu
                    compactScopeMenuSpacer
                    tabItem(
                        for: tab,
                        index: rawIndex,
                        isOnly: true,
                        gatewayOwnerIDs: gatewayOwnerIDs,
                        tabWidth: resolvedWidth
                    )
                        .frame(width: resolvedWidth)
                        .contextMenu {
                            // Full shared menu — a lone visible tab can still be a
                            // tmux gateway/window. No move targets with one tab.
                            tabContextMenu(
                                for: tab,
                                index: rawIndex,
                                moveLeftTarget: nil,
                                moveRightTarget: nil,
                                includeThemeOverrideClear: true
                            )
                        }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                if !usesCompactSpacing {
                    singleTabFlexibleMargin()
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: usesCompactSpacing ? .leading : .center
            )
        }
    }

    /// A single Pills tab is intentionally narrower than the available row
    /// and centered. On Catalyst those otherwise-empty centering margins are
    /// useful titlebar real estate, so make them native drag targets instead
    /// of inert SwiftUI space.
    @ViewBuilder
    private func singleTabFlexibleMargin() -> some View {
        #if targetEnvironment(macCatalyst)
        if usesTitlebarTabs {
            CatalystWindowDragRegion()
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: TabMetrics.tabBarHeight)
                .layoutPriority(-1)
                .catalystCursorRegion(.openHand, priority: .titlebar)
                .accessibilityHidden(true)
        } else {
            Spacer(minLength: 0)
        }
        #else
        Spacer(minLength: 0)
        #endif
    }

    // MARK: - Equal-width tabs

    @ViewBuilder
    private func equalWidthView(tabWidth: CGFloat) -> some View {
        // `activeRoamProtocol` walks `splitTree` and runtime-casts each
        // session — historically expensive enough per ForEach child to blow
        // the iPhone scene-update watchdog under burst conditions. With the
        // read now scoped inside `TabBarItem.body`, only invalidated items
        // recompute it. No parent-level roamMap is needed.
        let tabs = tabsModel.tabs
        let navigationTabs = tabsModel.navigationTabs
        // Gateway ordering for tmux badge colors — computed once per render and
        // reused for every tab (O(n)), and baked into each item so equality can
        // compare the resolved badge.
        let gatewayOwnerIDs = TmuxTabBadgeResolver.activeGatewayOwnerIDs(in: tabs)
        HStack(spacing: usesCompactSpacing ? 0 : 4) {
            activeScopeMenu
            compactScopeMenuSpacer
            ForEach(navigationTabs) { tab in
                let index = tabsModel.index(of: tab.id) ?? 0
                let moveLeftTarget = moveTargetRawIndex(for: tab, delta: -1)
                let moveRightTarget = moveTargetRawIndex(for: tab, delta: 1)
                equalWidthTabFrame(width: tabWidth) {
                    tabItem(
                        for: tab,
                        index: index,
                        isOnly: false,
                        gatewayOwnerIDs: gatewayOwnerIDs,
                        tabWidth: tabWidth
                    )
                        .equatable()
                }
                    .contentShape(Rectangle())
                    .id(tab.id)
                    .modifier(dragModifier(for: tab, index: index))
                    .contextMenu {
                        tabContextMenu(
                            for: tab,
                            index: index,
                            moveLeftTarget: moveLeftTarget,
                            moveRightTarget: moveRightTarget,
                            includeThemeOverrideClear: false
                        )
                    }
            }
        }
        .contentShape(Rectangle())
        .modifier(GlassEffectContainerModifier())
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TabMetrics.tabBarHeight)
        // Scoped animation for the selection slide (Liquid Glass / matched
        // geometry). Confined to the tab-bar subtree so the transaction does
        // not leak into the terminal-content `ForEach`'s opacity flip in
        // `MainViewTerminalContent`, which must be instant.
        .animation(
            tabBarAnimationsDisabled || suppressSelectionAnimation || reduceMotion
                ? nil
                : .spring(response: 0.3, dampingFraction: 0.7),
            value: tabsModel.selectedTabID
        )
    }

    // MARK: - Scrolling tabs

    @ViewBuilder
    private func scrollingView(tabWidth: CGFloat) -> some View {
        let tabs = tabsModel.tabs
        let renderedTabIDs = renderedTabIDs(in: tabs)
        ScrollViewReader { scrollViewProxy in
            scrollingScrollView(tabs: tabs, tabWidth: tabWidth)
                .modifier(ScrollingTabBarHandlersModifier(
                    proxy: scrollViewProxy,
                    tabs: tabs,
                    selectedTabIndex: selectedTabIndex,
                    renderedTabIDs: renderedTabIDs,
                    tabWidth: tabWidth,
                    tabsModel: tabsModel
                ))
        }
    }

    private func renderedTabIDs(in tabs: [TabModel]) -> [UUID] {
        _ = tabs
        return tabsModel.navigationTabs.map(\.id)
    }

    @ViewBuilder
    private func scrollingScrollView(tabs: [TabModel], tabWidth: CGFloat) -> some View {
        let navigationTabs = tabsModel.navigationTabs
        // Gateway ordering for tmux badge colors — computed once per render; see
        // equalWidthView.
        let gatewayOwnerIDs = TmuxTabBadgeResolver.activeGatewayOwnerIDs(in: tabs)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: usesCompactSpacing ? 0 : 8) {
                activeScopeMenu
                compactScopeMenuSpacer
                ForEach(navigationTabs) { tab in
                    let index = tabsModel.index(of: tab.id) ?? 0
                    let moveLeftTarget = moveTargetRawIndex(for: tab, delta: -1)
                    let moveRightTarget = moveTargetRawIndex(for: tab, delta: 1)
                    tabItem(
                        for: tab,
                        index: index,
                        isOnly: false,
                        gatewayOwnerIDs: gatewayOwnerIDs,
                        tabWidth: tabWidth
                    )
                        .equatable()
                        .frame(width: tabWidth)
                        .contentShape(Rectangle())
                        .id(tab.id)
                        .modifier(dragModifier(for: tab, index: index))
                        .contextMenu {
                            tabContextMenu(
                                for: tab,
                                index: index,
                                moveLeftTarget: moveLeftTarget,
                                moveRightTarget: moveRightTarget,
                                includeThemeOverrideClear: true
                            )
                        }
                }
            }
            .padding(.horizontal, usesCompactSpacing ? 0 : 8)
            .contentShape(Rectangle())
            .modifier(GlassEffectContainerModifier())
            // Scoped animation for the selection slide. See equalWidthView.
            .animation(
                tabBarAnimationsDisabled || suppressSelectionAnimation || reduceMotion
                    ? nil
                    : .spring(response: 0.3, dampingFraction: 0.7),
                value: tabsModel.selectedTabID
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact pills intentionally abut one another, but the scope menu is a
    /// separate control and should retain the small visual break used by the
    /// regular pill layout.
    @ViewBuilder
    private var compactScopeMenuSpacer: some View {
        if usesCompactSpacing,
           style == .pills,
           activeScopeMenuWidth > 0 {
            Color.clear.frame(width: 4)
        }
    }

    private var shouldPinEqualWidthTabs: Bool {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    @ViewBuilder
    private func equalWidthTabFrame<Content: View>(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesCompactSpacing || shouldPinEqualWidthTabs {
            content()
                .frame(width: width)
                .frame(maxHeight: .infinity)
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Scrolling-mode handlers (extracted to keep TabBar.body type-checkable)

/// Bundles the `onAppear` + `onChange` + `task` chain for the scrolling
/// tab bar. Held in a separate `ViewModifier` to keep `TabBar.scrollingView`
/// inside the Swift compiler's expression-typing budget — combining the
/// ScrollView contents with all six handlers inline tripped a
/// "compiler is unable to type-check this expression in reasonable time"
/// error.
private struct ScrollingTabBarHandlersModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let tabs: [TabModel]
    let selectedTabIndex: Int
    let renderedTabIDs: [UUID]
    let tabWidth: CGFloat
    /// Held as a reference (not snapshotted at construction) so the retry
    /// loop in `assertScrollToPendingTabID` reads live `pendingScrollToTabID`
    /// and `selectedTabID` values on each iteration. Snapshotting them broke
    /// the abort path: a user opening a tab and quickly switching elsewhere
    /// would still scroll back to the original pending tab because the
    /// captured `selectedTabID` was stale.
    let tabsModel: TabsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear {
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        recenterIfPossible()
                    }
                }
            }
            .onChange(of: selectedTabIndex) { _, newValue in
                guard tabs.indices.contains(newValue),
                      renderedTabIDs.contains(tabs[newValue].id) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(tabs[newValue].id, anchor: .center)
                }
            }
            .onChange(of: tabs.count) { _, _ in
                recenterIfPossible()
            }
            .onChange(of: renderedTabIDs) { _, _ in
                recenterIfPossible(animated: false)
            }
            .onChange(of: tabWidth) { _, _ in
                recenterIfPossible(animated: false)
            }
            // Explicit scroll-target signal. Tab-creation code sets
            // `tabsModel.pendingScrollToTabID = newTab.id` so newly added
            // tabs are reliably scrolled into view even when they're
            // appended at the rightmost (offscreen) position.
            //
            // `.task(id:)` cancels the prior task and re-runs whenever the
            // id changes, so rapid tab creations don't race or stack.
            .task(id: tabsModel.pendingScrollToTabID) {
                await assertScrollToPendingTabID()
            }
    }

    private func recenterIfPossible(animated: Bool = true) {
        let fallbackID = tabs.indices.contains(selectedTabIndex) ? tabs[selectedTabIndex].id : nil
        let targetID = tabsModel.selectedTabID ?? fallbackID
        guard let targetID, renderedTabIDs.contains(targetID) else { return }
        DispatchQueue.main.async {
            guard animated else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                return
            }

            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    private func assertScrollToPendingTabID() async {
        guard let targetID = tabsModel.pendingScrollToTabID else { return }
        // Re-assert the scroll across several runloop ticks. Holding
        // `pendingScrollToTabID` non-nil through the whole window means
        // any `onChange(of: tabs.count)` re-center fired by the deferred
        // foreground-resume replay (`scheduleDeferredForegroundReplay`) is
        // overwritten by the next iteration here. Six attempts × ~16ms ≈
        // ~100ms — long enough to outlast a typical restored-session replay
        // queue, short enough to feel instant.
        for attempt in 0..<6 {
            await Task.yield()
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(16))
            }
            // Re-read live values each iteration; if the user opened a
            // different tab or selected away from the pending one between
            // schedule and execution, abort cleanly.
            guard tabsModel.pendingScrollToTabID == targetID else { return }
            guard tabsModel.selectedTabID == targetID else {
                if tabsModel.pendingScrollToTabID == targetID {
                    tabsModel.pendingScrollToTabID = nil
                }
                return
            }
            if attempt == 5 {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
        if tabsModel.pendingScrollToTabID == targetID {
            tabsModel.pendingScrollToTabID = nil
        }
    }
}

// MARK: - Per-tab item view
//
// One `TabBarItem` is rendered per tab inside `TabBar`'s `ForEach`. Per-tab
// reads on the `@Observable TabModel` (`title`, `connectionHealth`,
// `activeRoamProtocol`) happen here, so SwiftUI scopes their Observation to
// this single instance. A title or health update on tab N invalidates only
// `TabBarItem(tab: N).body` — its siblings stay stable, which is what keeps
// drag/open/close/select animations smooth when the network sends an OSC
// 0/2 burst or a keepalive ping result mid-animation.
struct TabBarItem: View, Equatable {
    let tab: TabModel
    /// Raw array index, threaded through so the selection/close callbacks
    /// (which capture `index`) stay correct. Also part of `==`: a reorder /
    /// insert / remove shifts a tab's index, which must force a re-render so
    /// the captured `index` in `onTap`/`onClose` isn't stale on a skipped
    /// (equatable-short-circuited) item.
    let index: Int
    /// Resolved tmux gateway/window badge, precomputed at parent scope from the
    /// live gateway ordering (`TmuxTabBadgeResolver.badge(for:gatewayOwnerIDs:)`).
    /// Stored — rather than derived in `body` from an `allTabs` array — so `==`
    /// can compare it directly: a reorder that changes gateway order recolors the
    /// badge (its `groupIndex`) without changing this tab's own `index`, and that
    /// order-derived color must not go stale behind the equality short-circuit.
    let tmuxBadge: TmuxTabBadge?
    /// Precomputed resolved badge tint (nil for non-tmux tabs). Compared in `==`
    /// so a theme **palette** change recolors the badge even when the selected/
    /// unselected/text colors are unchanged. Equality-only — `body` re-renders
    /// the badge from the live palette, producing the same color.
    let tmuxBadgeColor: Color?
    /// Attention rollup for the tab (nil when badges are disabled or there
    /// is nothing to show). Stored and compared in `==` — a stale value
    /// here means a stale dot. (id=agent-attention)
    let attentionBadge: AgentAttentionStatus?
    let isSelected: Bool
    let isOnly: Bool
    let theme: ResolvedTabBarTheme
    let tabNamespace: Namespace.ID
    let isWiggling: Bool
    let sshHealthMonitoringEnabled: Bool
    let keyboardShortcut: String?
    let usesTitlebarTabs: Bool
    let style: TopTabStyle
    let tabWidth: CGFloat
    let hasThemeOverride: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    // Equality gates *parent-driven* re-evaluation only (a selection change
    // re-runs the whole ForEach and reconstructs every TabBarItem with fresh
    // closures). With `.equatable()`, a switch re-renders only the outgoing +
    // incoming tabs instead of all N. It does NOT suppress @Observable-driven
    // invalidation: the body reads `tab.title` / `tab.connectionHealth` /
    // `tab.activeRoamProtocol` and those still update live per tab. So `==`
    // deliberately ignores both the closures and those observed properties —
    // comparing only the inputs that change a tab's rendered appearance from
    // the parent's side. The precomputed `tmuxBadge` is compared directly so a
    // reorder that recolors a gateway/window badge (its order-derived
    // `groupIndex`) forces a re-render even when this tab's own `index` is
    // unchanged.
    static func == (lhs: TabBarItem, rhs: TabBarItem) -> Bool {
        lhs.tab === rhs.tab
            && lhs.index == rhs.index
            && lhs.tmuxBadge == rhs.tmuxBadge
            && lhs.tmuxBadgeColor == rhs.tmuxBadgeColor
            && lhs.attentionBadge == rhs.attentionBadge
            && lhs.isSelected == rhs.isSelected
            && lhs.isOnly == rhs.isOnly
            && lhs.isWiggling == rhs.isWiggling
            && lhs.hasThemeOverride == rhs.hasThemeOverride
            && lhs.keyboardShortcut == rhs.keyboardShortcut
            && lhs.sshHealthMonitoringEnabled == rhs.sshHealthMonitoringEnabled
            && lhs.usesTitlebarTabs == rhs.usesTitlebarTabs
            && lhs.style == rhs.style
            && lhs.tabWidth == rhs.tabWidth
            && lhs.theme.isLight == rhs.theme.isLight
            && lhs.theme.baseColor == rhs.theme.baseColor
            && lhs.theme.terminalSurfaceBackground == rhs.theme.terminalSurfaceBackground
            && lhs.theme.terminalSurfaceIsTransparent == rhs.theme.terminalSurfaceIsTransparent
            && lhs.theme.tabBarBackground == rhs.theme.tabBarBackground
            && lhs.theme.selectedBackground == rhs.theme.selectedBackground
            && lhs.theme.unselectedBackground == rhs.theme.unselectedBackground
            && lhs.theme.tabText == rhs.theme.tabText
            && lhs.theme.tabSecondaryText == rhs.theme.tabSecondaryText
    }

    var body: some View {
        TabButton(
            id: tab.id,
            title: tab.title,
            isSelected: isOnly || isSelected,
            selectedBackgroundColor: style == .integrated
                ? (theme.terminalSurfaceBackground ?? theme.selectedBackground)
                : theme.selectedBackground,
            unselectedBackgroundColor: theme.inactiveHoverBackground(for: style),
            textColor: theme.tabText,
            secondaryTextColor: theme.tabSecondaryText,
            isLightTheme: theme.isLight,
            namespace: tabNamespace,
            onTap: onTap,
            onClose: onClose,
            isWiggling: isWiggling,
            connectionHealth: tab.connectionHealth,
            showHealthIndicator: sshHealthMonitoringEnabled
                && tab.connectionHealth?.quality == .poor,
            keyboardShortcut: keyboardShortcut,
            onHoverChange: onHover,
            trackFrame: usesTitlebarTabs,
            hasThemeOverride: hasThemeOverride,
            roamProtocol: tab.activeRoamProtocol,
            tmuxBadge: tmuxBadge,
            tmuxBadgePalette: TmuxTabBadgePalette(theme: theme),
            attentionBadge: attentionBadge,
            style: style,
            tabWidth: tabWidth,
            usesTitlebarTabs: usesTitlebarTabs
        )
    }
}
