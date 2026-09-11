//
//  HerdrController+Topology.swift
//  rootshell
//
//  Mirrors herdr's workspaces, tabs, panes, and layouts onto native tabs and
//  split trees. herdr is authoritative: every change here is a reaction to a
//  snapshot or event, and user intent goes back out as requests
//  (HerdrController+Commands).
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import UIKit

extension HerdrController {

    // MARK: - Snapshot

    func applySnapshot(_ snapshot: HerdrControl.SessionSnapshot) {
        guard !didEnd else { return }
        let isInitialSnapshot = !hasProcessedInitialSnapshot
        let maySelectInitialTab = tabsModel.maySelectInitialMultiplexerTab(gatewayTabID: gatewayTabID)
        hasProcessedInitialSnapshot = true
        if !snapshot.tabs.isEmpty { newTabError = nil }
        workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspace_id, $0) })
        tabOrder.reset(to: snapshot.tabs)
        for tab in snapshot.tabs {
            tabInfos[tab.tab_id] = tab
            ensureTab(tab)
        }
        let livePaneIds = Set(snapshot.panes.map(\.pane_id))
        let liveTerminalIds = Set(snapshot.panes.map(\.terminal_id))
        for pane in snapshot.panes {
            ensurePane(pane)
        }
        prune(tabIds: Set(snapshot.tabs.map(\.tab_id)), paneIds: livePaneIds, terminalIds: liveTerminalIds)
        for layout in snapshot.layouts {
            // Generic snapshots use the server TUI's area. Preserve a raw
            // layout for the same pane set so a topology refresh cannot
            // resize an attached terminal back to that unrelated viewport.
            if mode == .raw, let controlled = controlLayouts[layout.tab_id],
               controlled.zoomed == layout.zoomed,
               Set(controlled.panes.map(\.pane_id)) == Set(layout.panes.map(\.pane_id)) {
                applyLayout(controlled)
            } else {
                applyLayout(layout)
            }
        }
        // The snapshot is the whole truth about agents: a pane missing from
        // it lost its agent, so it gets a clearing report.
        let vanished = agentStatuses.keys.filter { paneId in !snapshot.agents.contains { $0.pane_id == paneId } }
        agentStatuses.removeAll()
        for agent in snapshot.agents {
            agentStatuses[agent.pane_id] = HerdrControl.AgentStatusChangedData(
                pane_id: agent.pane_id,
                workspace_id: paneInfos[agent.pane_id]?.workspace_id ?? "",
                agent_status: agent.agent_status,
                agent: agent.agent,
                title: agent.title,
                display_agent: agent.display_agent,
                state_labels: nil
            )
        }
        for paneId in vanished {
            guard let info = paneInfos[paneId], let view = paneViews[info.terminal_id] else { continue }
            AgentAttentionCenter.shared.applyHerdrStatus(
                terminal: view, status: "unknown", agentID: nil, displayName: nil, title: nil
            )
        }
        publishAgentStatuses()
        reorderTabs()
        refreshWorkspaceGroups()
        focusedPaneId = snapshot.focused_pane_id
        applyInitialSelection(serverFocusedPaneID: snapshot.focused_pane_id, maySelectTab: maySelectInitialTab)
        for tab in tabs.values { refreshTitle(of: tab) }
        // Re-attach every pane whose surface already runs, focused tab first.
        queueAttaches(priorityTab: tabsModel.selectedTabID)
        pushGeometryForHostedTabs()
        autoHideGatewayIfWanted()
        publishProjectPaths()
        publishSessionState()
        if isInitialSnapshot, snapshot.tabs.isEmpty {
            requestNewTab(workspaceID: nil, isAutomatic: true)
        }
    }

    /// herdr knows each pane's directory; hand it to agent attention so the
    /// sidebar shows the project without probing the host.
    func publishProjectPaths() {
        for pane in paneInfos.values {
            guard let view = paneViews[pane.terminal_id],
                  let path = pane.projectPath else { continue }
            AgentAttentionCenter.shared.applyHerdrProjectPath(terminal: view, path: path)
        }
    }

    // MARK: - Tabs

    func ensureTab(_ info: HerdrControl.TabInfo) {
        tabInfos[info.tab_id] = info
        tabOrder.append(info)
        if let existing = tabs[info.tab_id] {
            if tabsModel.tabs.contains(where: { $0 === existing }) {
                refreshTitle(of: existing)
                return
            }
            // Removed locally without telling us (a local close path); drop
            // the stale entry and recreate.
            tabs.removeValue(forKey: info.tab_id)
        }
        let tab = TabModel(windowId: hostWindowId)
        tab.isHerdrWindow = true
        tab.herdrTabId = info.tab_id
        tab.herdrWorkspaceId = info.workspace_id
        tab.owningGatewayTerminalUUID = gatewayUUID
        tabs[info.tab_id] = tab
        tabsModel.tabs.append(tab)
        refreshTitle(of: tab)
        // Creation responses select their exact tab; unrelated events never
        // consume a pending New Tab action (including in legacy mode).
        if tabsModel.selectedTabID == nil {
            tabsModel.selectedTabID = tab.id
        }
        // Raw layouts can precede the polled creation events.
        if let layout = lastLayouts[info.tab_id] { applyLayout(layout) }
        publishSessionState()
    }

    func tabDidClose(tabId: String) {
        tabInfos.removeValue(forKey: tabId)
        let terminalIds = paneInfos.values.filter { $0.tab_id == tabId }.map(\.terminal_id)
        let remainingPanes = Set(paneInfos.values.filter { $0.tab_id != tabId }.map(\.pane_id))
        let remainingTerminals = Set(paneInfos.values.filter { $0.tab_id != tabId }.map(\.terminal_id))
        for terminalId in terminalIds {
            if let paneId = paneInfos.first(where: { $0.value.terminal_id == terminalId })?.key {
                paneInfos.removeValue(forKey: paneId)
            }
        }
        prune(tabIds: Set(tabInfos.keys), paneIds: remainingPanes, terminalIds: remainingTerminals)
    }

    func tabDidRename(tabId: String, label: String) {
        guard let info = tabInfos[tabId] else { return }
        tabInfos[tabId] = HerdrControl.TabInfo(
            tab_id: info.tab_id,
            workspace_id: info.workspace_id,
            number: info.number,
            label: label,
            focused: info.focused,
            pane_count: info.pane_count,
            agent_status: info.agent_status
        )
        if let tab = tabs[tabId] {
            refreshTitle(of: tab)
        }
    }

    /// Applies the complete ordered list returned by tab.list or tab.move.
    func applyTabOrder(_ infos: [HerdrControl.TabInfo], workspaceID: String) {
        for info in infos { tabInfos[info.tab_id] = info }
        tabOrder.update(workspaceID: workspaceID, tabs: infos)
        reorderTabs()
    }

    /// Orders this gateway's projected tabs by workspace then server list order,
    /// permuting only the slots they already occupy.
    func reorderTabs() {
        let mine = Set(tabs.values.map(\.id))
        let slots = tabsModel.tabs.indices.filter { mine.contains(tabsModel.tabs[$0].id) }
        guard slots.count > 1 else { return }
        let current = slots.map { tabsModel.tabs[$0] }
        let orderedIDs = tabOrder.orderedIDs(
            in: current.compactMap { tab in tab.herdrTabId.flatMap { tabInfos[$0] } },
            workspaceNumbers: workspaces.mapValues(\.number)
        )
        let sorted = orderedIDs.compactMap { tabs[$0] }
        guard sorted.count == current.count else { return }
        if current.elementsEqual(sorted, by: { $0 === $1 }) { return }
        for (slot, tab) in zip(slots, sorted) {
            tabsModel.tabs[slot] = tab
        }
    }

    /// Workspace labels feed the tab group titles; bump grouping so the
    /// sidebar re-derives them.
    func refreshWorkspaceGroups() {
        for tab in tabs.values {
            guard let workspaceId = tab.herdrWorkspaceId else { continue }
            let label = workspaces[workspaceId]?.label ?? workspaceId
            if tab.herdrWorkspaceLabel != label {
                tab.herdrWorkspaceLabel = label
            }
        }
    }

    // MARK: - Panes

    func paneDidAppear(_ pane: HerdrControl.PaneInfo) {
        let isNew = paneInfos[pane.pane_id] == nil
        ensurePane(pane)
        if isNew {
            subscribeAgentStatus(paneId: pane.pane_id)
        }
        if let layout = lastLayouts[pane.tab_id] { applyLayout(layout) }
    }

    func paneDidUpdate(_ pane: HerdrControl.PaneInfo) {
        let previous = paneInfos[pane.pane_id]
        paneInfos[pane.pane_id] = pane
        if let view = paneViews[pane.terminal_id] {
            view.seedHerdrTitle(pane.title ?? pane.terminal_title)
        } else if let tab = tabs[pane.tab_id] {
            refreshTitle(of: tab)
        }
        let path = pane.projectPath
        if let path, path != previous?.projectPath,
           let view = paneViews[pane.terminal_id] {
            AgentAttentionCenter.shared.applyHerdrProjectPath(terminal: view, path: path)
        }
    }

    func paneDidClose(paneId: String) {
        guard let info = paneInfos.removeValue(forKey: paneId) else {
            refreshTopology()
            return
        }
        if !paneInfos.values.contains(where: { $0.tab_id == info.tab_id }) {
            tabInfos.removeValue(forKey: info.tab_id)
        }
        prune(
            tabIds: Set(tabInfos.keys),
            paneIds: Set(paneInfos.keys),
            terminalIds: Set(paneInfos.values.map(\.terminal_id))
        )
        // Closing the final pane may remove its tab without a tab.closed
        // event. Let the authoritative snapshot decide what survived.
        refreshTopology()
    }

    func paneDidMove(_ moved: HerdrControl.PaneMovedData) {
        if let previous = moved.previous_pane_id {
            paneInfos.removeValue(forKey: previous)
        }
        ensurePane(moved.pane)
        paneSessions[moved.pane.terminal_id]?.updatePaneId(moved.pane.pane_id)
        if let attachId = attachIds[moved.pane.terminal_id] {
            router.setPane(moved.pane.pane_id, attachId: attachId)
        }
        if let previousTab = moved.previous_tab_id, let tab = tabs[previousTab],
           let view = paneViews[moved.pane.terminal_id],
           let root = tab.splitTree.root, let leaf = root.node(view: view) {
            tab.splitTree = tab.splitTree.remove(leaf)
        }
        // The destination tab's `tab.layout` record places the pane.
    }

    /// Creates or rebinds the surface view for a pane. New views are created
    /// with a `.local()` config only so the surface plumbing runs; the herdr
    /// binding makes the session controller hand them a HerdrPaneSession.
    func ensurePane(_ pane: HerdrControl.PaneInfo) {
        paneInfos[pane.pane_id] = pane
        let binding = Ghostty.TerminalView.HerdrPaneBinding(
            gatewayUUID: gatewayUUID,
            terminalId: pane.terminal_id,
            paneId: pane.pane_id,
            tabId: pane.tab_id
        )
        if let existing = paneViews[pane.terminal_id] {
            if existing.usesHerdrFallbackScrolling != (mode == .legacy) {
                existing.usesHerdrFallbackScrolling = mode == .legacy
            }
            if existing.herdrPaneBinding != binding {
                existing.herdrPaneBinding = binding
            }
            if let tab = tabs[pane.tab_id], existing.containingTabID != tab.id {
                existing.containingTabID = tab.id
            }
            existing.seedHerdrTitle(pane.title ?? pane.terminal_title)
            return
        }
        guard let ghosttyApp else {
            Self.logger.error("herdr control: no app for pane \(pane.pane_id)")
            return
        }
        let view = Ghostty.TerminalView(app, ghosttyApp: ghosttyApp, connectionConfig: .local(), windowId: hostWindowId)
        view.setOverlayOwnsKeyboard(tabsModel.overlayOwnsKeyboard)
        view.herdrPaneBinding = binding
        view.usesHerdrFallbackScrolling = mode == .legacy
        if let tab = tabs[pane.tab_id] {
            view.containingTabID = tab.id
            view.setOcclusion(tabsModel.selectedTabID == tab.id)
        } else {
            view.setOcclusion(false)
        }
        paneViews[pane.terminal_id] = view
        view.seedHerdrTitle(pane.title ?? pane.terminal_title)
        NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
    }

    /// Tears down views and tabs herdr no longer has.
    func prune(tabIds: Set<String>, paneIds: Set<String>, terminalIds: Set<String>) {
        tabOrder.prune(to: tabIds)
        let staleTabs = tabs.filter { !tabIds.contains($0.key) }
        let removedIDs = Set(staleTabs.values.map(\.id))
        let selectedID = tabsModel.selectedTabID
        let removesSelection = selectedID.map { removedIDs.contains($0) } ?? false
        let neighbor = removesSelection ? selectedID.flatMap { tabsModel.groupedCloseNeighbor(for: $0) } : nil
        for (paneId, _) in paneInfos where !paneIds.contains(paneId) {
            paneInfos.removeValue(forKey: paneId)
        }
        let staleViews = paneViews.filter { !terminalIds.contains($0.key) }
        for (terminalId, view) in staleViews {
            retirePane(view: view, terminalId: terminalId)
        }
        tabsModel.tabs.removeAll { removedIDs.contains($0.id) }
        for (tabId, _) in staleTabs {
            tabs.removeValue(forKey: tabId)
            tabInfos.removeValue(forKey: tabId)
            lastLayouts.removeValue(forKey: tabId)
            controlLayouts.removeValue(forKey: tabId)
            tabGeometryStates.removeValue(forKey: tabId)
            geometryTasks.removeValue(forKey: tabId)?.cancel()
        }
        if let focusedPaneId, !paneIds.contains(focusedPaneId) { self.focusedPaneId = nil }
        if tabs.isEmpty {
            focusWatchdog?.cancel()
            revealEmptyGatewayIfNeeded()
        }
        if removesSelection {
            let visible = tabsModel.tabs.filter { !$0.isHiddenTmuxWindow }
            let replacement = tabs.isEmpty ? gatewayTabID : nil
            tabsModel.selectedTabID = replacement
                ?? visible.first(where: { $0.id == neighbor })?.id
                ?? visible.first(where: { $0.owningGatewayTerminalUUID == gatewayUUID })?.id
                ?? visible.first?.id
            tabsModel.pendingScrollToTabID = tabsModel.selectedTabID
        }
        publishSessionState()
        if !staleViews.isEmpty {
            NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
        }
    }

    func pruneAll() {
        prune(tabIds: [], paneIds: [], terminalIds: [])
        if let gatewayTabID, tabsModel.selectedTabID == nil || !tabsModel.tabs.contains(where: { $0.id == tabsModel.selectedTabID }) {
            tabsModel.selectedTabID = gatewayTabID
        }
    }

    private func retirePane(view: Ghostty.TerminalView, terminalId: String) {
        view.endHerdrTitleAttachment()
        attachQueue.removeAll { $0 == terminalId }
        attachRetries.removeValue(forKey: terminalId)?.cancel()
        attachesInFlight.removeValue(forKey: terminalId)
        panesNeedingSnapshot.remove(terminalId)
        view.isLogicallyFocused = false
        view.shouldBecomeFirstResponderWhenReady = false
        view.herdrTargetGrid = nil
        if let attachId = attachIds.removeValue(forKey: terminalId) {
            terminalByAttach.removeValue(forKey: attachId)
            router.unregister(attachId: attachId)
        }
        legacyOpening[terminalId]?.task.cancel()
        legacyCloseStream(terminalId)
        legacyGrids.removeValue(forKey: terminalId)
        paneSessions.removeValue(forKey: terminalId)
        paneViews.removeValue(forKey: terminalId)
        // Remove from its split tree before the surface goes away so the
        // hosting view never keeps a dead leaf.
        for tab in tabs.values {
            if let root = tab.splitTree.root, let leaf = root.node(view: view) {
                let hadFocus = tab.focusedPane === view
                let next = root.findNeighbor(of: leaf)?.leftmostLeaf()
                tab.splitTree = tab.splitTree.remove(leaf)
                if hadFocus {
                    tab.focusedPane = next
                }
                // Removing any leaf rebuilds the hosting view, including
                // when the focused pane itself survives unchanged.
                if let terminal = tab.focusedTerminal, tabsModel.selectedTabID == tab.id {
                    focusPane(terminal, in: tab)
                }
            }
        }
        if view.isFirstResponder { view.resignFirstResponder() }
        view.cleanup(reason: .userClose)
    }

    // MARK: - Layout

    func applyLayout(_ layout: HerdrControl.LayoutSnapshot, barrier: UInt64? = nil) {
        lastLayouts[layout.tab_id] = layout
        guard let tab = tabs[layout.tab_id] else { return }
        guard let node = HerdrLayoutTree.build(layout) else { return }
        guard let root = buildSplitNode(node) else {
            // A pane view is missing (out-of-order event); the next layout
            // record for this tab retries.
            return
        }
        // Each pane keeps exactly the grid herdr gave it, whatever slot the
        // ratio math hands it (id=herdr-chromeless).
        // Degraded mode sizes each pane from its own grid (`terminal.resize`),
        // so a clamp there would pin the pane to the last snapshot forever.
        for pane in layout.panes {
            guard let terminalId = paneInfos[pane.pane_id]?.terminal_id, let view = paneViews[terminalId] else { continue }
            view.containingTabID = tab.id
            // A generic snapshot describes the server TUI's viewport. Let
            // the initial native host use its full space until our raw layout
            // arrives; clamping to the TUI first causes a shrink/grow bounce.
            view.herdrTargetGrid = mode == .raw && tabGeometryStates[layout.tab_id]?.hasRequested == true
                && controlLayouts[layout.tab_id] != nil
                ? (cols: pane.rect.width, rows: pane.rect.height) : nil
        }
        var zoomed: SplitTree<SplitPaneView>.Node?
        if layout.zoomed, let terminalId = paneInfos[layout.focused_pane_id]?.terminal_id,
           let view = paneViews[terminalId] {
            zoomed = .leaf(view: view)
        }
        let tree = SplitTree<SplitPaneView>(root: root, zoomed: zoomed)
        let structureChanged = tab.splitTree.structuralIdentity != tree.structuralIdentity
        tab.splitTree = tree
        showPanesIfSelected(in: tab)
        if let barrier {
            armLayoutRelease(for: layout, barrier: barrier)
        }
        let layoutFocus = paneInfos[layout.focused_pane_id].flatMap { paneViews[$0.terminal_id] }
        let survivingFocus = tab.focusedTerminal.flatMap { root.node(view: $0) != nil ? $0 : nil }
        if let view = layoutFocus ?? survivingFocus ?? tree.first?.asTerminal {
            // A matching focused-pane reference does not imply UIKit focus:
            // selection can precede this tree, or a rebuild can reparent it.
            if tab.focusedPane !== view || (tabsModel.selectedTabID == tab.id &&
                (structureChanged || !view.isLogicallyFocused || !view.isFirstResponder)) {
                focusPane(view, in: tab)
            }
        }
        refreshTitle(of: tab)
        tabsModel.syncDisplayedTab()
        // Ratios changed under the panes; force each surface to re-sync its
        // grid after the layout pass (mirrors the tmux path).
        let views = node.paneIds.compactMap { paneInfos[$0]?.terminal_id }.compactMap { paneViews[$0] }
        DispatchQueue.main.async {
            for view in views {
                view.invalidateCachedSize()
                view.sizeDidChange(view.bounds.size)
            }
        }
    }

    /// Points a subtree needs along one axis: its cells plus each pane's
    /// padding inset plus the native dividers between them. Ratios come
    /// from these, not raw cells, so the frame math hands every pane
    /// exactly its grid (the tmux path's chrome-ratio rule).
    private func neededPoints(_ node: HerdrLayoutTree.Node, horizontal: Bool, metrics: HerdrLayoutTree.Metrics) -> CGFloat {
        let cell = horizontal ? metrics.cellW : metrics.cellH
        let pad = horizontal ? metrics.padX : metrics.padY
        switch node {
        case .pane(let paneId, let rect):
            let chrome = paneInfos[paneId].flatMap { paneViews[$0.terminal_id] }?.herdrLayoutChrome
            let inset = chrome.map { horizontal ? $0.width : $0.height } ?? pad * 2
            return CGFloat(horizontal ? rect.width : rect.height) * cell + inset
        case .split(let splitHorizontal, let first, let second):
            let a = neededPoints(first, horizontal: horizontal, metrics: metrics)
            let b = neededPoints(second, horizontal: horizontal, metrics: metrics)
            return splitHorizontal == horizontal ? a + b + metrics.divider : max(a, b)
        }
    }

    private func layoutMetrics(for node: HerdrLayoutTree.Node) -> HerdrLayoutTree.Metrics? {
        guard let paneId = node.firstPaneId, let terminalId = paneInfos[paneId]?.terminal_id,
              let view = paneViews[terminalId], let size = view.surfaceSize,
              size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : view.traitCollection.displayScale
        guard scale > 0 else { return nil }
        return HerdrLayoutTree.Metrics(
            cellW: CGFloat(size.cell_width_px) / scale,
            cellH: CGFloat(size.cell_height_px) / scale,
            padX: HerdrGeometry.padding(PaddingManager.shared.effectivePaddingX, scale: scale),
            padY: HerdrGeometry.padding(PaddingManager.shared.effectivePaddingY, scale: scale),
            divider: SplitTreeHostingView.dividerVisibleThickness
        )
    }

    private func buildSplitNode(_ node: HerdrLayoutTree.Node) -> SplitTree<SplitPaneView>.Node? {
        buildSplitNode(node, metrics: layoutMetrics(for: node))
    }

    private func buildSplitNode(
        _ node: HerdrLayoutTree.Node,
        metrics: HerdrLayoutTree.Metrics?
    ) -> SplitTree<SplitPaneView>.Node? {
        switch node {
        case .pane(let paneId, _):
            guard let terminalId = paneInfos[paneId]?.terminal_id, let view = paneViews[terminalId] else {
                return nil
            }
            return .leaf(view: view)
        case .split(let horizontal, let first, let second):
            guard let left = buildSplitNode(first, metrics: metrics) else {
                return buildSplitNode(second, metrics: metrics)
            }
            guard let right = buildSplitNode(second, metrics: metrics) else { return left }
            let ratio: Double
            if let metrics {
                let a = neededPoints(first, horizontal: horizontal, metrics: metrics)
                let b = neededPoints(second, horizontal: horizontal, metrics: metrics)
                ratio = a + b > 0 ? Double(a / (a + b)) : 0.5
            } else {
                let a = Double(first.extent(horizontal: horizontal))
                let total = a + Double(second.extent(horizontal: horizontal))
                ratio = total > 0 ? a / total : 0.5
            }
            return .split(.init(
                direction: horizontal ? .horizontal : .vertical,
                ratio: min(max(ratio, 0.05), 0.95),
                left: left,
                right: right
            ))
        }
    }

    // MARK: - Focus

    /// Restore this window's saved herdr tab before considering the server's
    /// current tab, which another client may have changed while we were away.
    func applyInitialSelection(serverFocusedPaneID: String?, maySelectTab: Bool) {
        guard !hasProcessedInitialFocus else { return }
        hasProcessedInitialFocus = true
        let restored = tabsModel.pendingHerdrSelection.flatMap {
            $0.gatewayTerminalUUID == gatewayUUID ? $0 : nil
        }
        if restored != nil { tabsModel.pendingHerdrSelection = nil }
        guard maySelectTab else { return }
        if let restored, let tab = tabs[restored.tabID] {
            tabsModel.selectedTabID = tab.id
            tabsModel.pendingScrollToTabID = tab.id
            showPanesIfSelected(in: tab)
            if let view = tab.focusedTerminal ?? tab.splitTree.first?.asTerminal {
                focusPane(view, in: tab)
            }
        } else if let serverFocusedPaneID {
            // The saved tab may have closed on the host. Fall back to the
            // session's current pane; an empty session keeps its gateway UI.
            selectTab(containingPane: serverFocusedPaneID, focusPane: true)
        }
    }

    /// A selected tab can still be empty when MainView handles selection.
    /// Panes created before that selection carry explicit hidden visibility
    /// into surface creation. Reconcile when their tree actually arrives;
    /// first-frame and tab-switch retries deliberately do not unhide panes.
    func showPanesIfSelected(in tab: TabModel) {
        guard tabsModel.selectedTabID == tab.id, !Ghostty.isAppBackgroundedAtomic else { return }
        for view in tab.splitTree.terminalLeaves where !view.isTabVisible {
            view.setOcclusion(true)
        }
    }

    /// Makes `view` the focused pane of `tab` (logical focus plus first
    /// responder when the tab is visible). Mirrors TmuxController.focusPane.
    func focusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        let previous = tab.focusedTerminal
        tab.focusedTerminal = view
        // Background layouts and remote focus events only change the pane
        // remembered by that tab. They must not disarm the selected pane's
        // focus or give a hidden view a pending first-responder request.
        guard tabsModel.selectedTabID == tab.id else {
            // A moved pane can remain in the old tab's focusedPane until its
            // next layout. Only disarm panes that still belong to this tab.
            for pane in [previous, view].compactMap({ $0 }) where pane.containingTabID == tab.id {
                pane.isLogicallyFocused = false
                pane.shouldBecomeFirstResponderWhenReady = false
                pane.clearStaleGhosttyFocus()
            }
            return
        }
        for other in paneViews.values where other !== view {
            other.isLogicallyFocused = false
            other.shouldBecomeFirstResponderWhenReady = false
            other.clearStaleGhosttyFocus()
        }
        view.setOverlayOwnsKeyboard(tabsModel.overlayOwnsKeyboard)
        view.isLogicallyFocused = true
        view.shouldBecomeFirstResponderWhenReady = true
        let acquired = view.reassertFirstResponderIfFocused()
        if acquired { view.shouldBecomeFirstResponderWhenReady = false }
        if let previous, previous !== view {
            previous.focusDidChange(false, skipResign: acquired)
        }
        armFocusWatchdog(for: view, tab: tab)
    }

    private func armFocusWatchdog(for view: Ghostty.TerminalView, tab: TabModel) {
        focusWatchdog?.cancel()
        guard let terminalId = view.herdrPaneBinding?.terminalId else { return }
        let model = tabsModel
        let tabID = tab.id
        let selectionRevision = model.selectionRevision
        let paneFocusRevision = tab.paneFocusRevision
        let generation = streamGeneration
        let backgroundEpoch = LifecycleEpoch.shared.background
        focusWatchdog = Task { @MainActor [weak self, weak view, weak tab, weak model] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let view, let tab, let model,
                      !self.didEnd, self.streamGeneration == generation,
                      LifecycleEpoch.shared.background == backgroundEpoch,
                      model.selectedTabID == tabID, model.selectionRevision == selectionRevision,
                      model.tab(withID: tabID) === tab,
                      tab.focusedTerminal === view, tab.paneFocusRevision == paneFocusRevision,
                      self.paneViews[terminalId] === view, view.containingTabID == tabID,
                      view.isLogicallyFocused else { return }
                // window == nil is temporary during a hosting-view rebuild;
                // keep the bounded retry alive. The shared helper also honors
                // modal, overlay, and inactive-window keyboard ownership.
                if view.reassertFirstResponderIfFocused() { return }
            }
        }
    }

    func remoteFocusDidChange(paneId: String) {
        focusedPaneId = paneId
        guard let info = paneInfos[paneId], let tab = tabs[info.tab_id],
              let view = paneViews[info.terminal_id] else { return }
        for pane in paneInfos.values where pane.tab_id == info.tab_id {
            paneInfos[pane.pane_id] = HerdrControl.PaneInfo(
                pane_id: pane.pane_id, terminal_id: pane.terminal_id, workspace_id: pane.workspace_id,
                tab_id: pane.tab_id, focused: pane.pane_id == paneId, agent_status: pane.agent_status,
                agent: pane.agent, display_agent: pane.display_agent, title: pane.title,
                terminal_title: pane.terminal_title, cwd: pane.cwd, foreground_cwd: pane.foreground_cwd,
                state_labels: pane.state_labels
            )
        }
        if tab.focusedPane !== view || (tabsModel.selectedTabID == tab.id &&
            (!view.isLogicallyFocused || !view.isFirstResponder)) {
            focusPane(view, in: tab)
        }
        refreshTitle(of: tab)
    }

    func remoteTabFocusDidChange(tabId: String) {
        // Another client changed herdr's focused tab; do not yank the user's
        // selection here. Selection follows local intent, as with tmux.
        _ = tabId
    }

    func selectTab(containingPane paneId: String, focusPane focus: Bool) {
        guard let info = paneInfos[paneId], let tab = tabs[info.tab_id] else { return }
        tabsModel.selectedTabID = tab.id
        tabsModel.pendingScrollToTabID = tab.id
        showPanesIfSelected(in: tab)
        if focus, let view = paneViews[info.terminal_id] {
            focusPane(view, in: tab)
        }
    }

    // MARK: - Agent state

    func agentStatusDidChange(_ change: HerdrControl.AgentStatusChangedData) {
        // No agent left on the pane: drop it so a later snapshot does not
        // resurrect a stale entry, and hand the pane back to detection.
        if change.agent == nil, AgentAttentionStatus(rawValue: change.agent_status) ?? .unknown == .unknown {
            agentStatuses.removeValue(forKey: change.pane_id)
        } else {
            agentStatuses[change.pane_id] = change
        }
        guard let info = paneInfos[change.pane_id], let view = paneViews[info.terminal_id] else { return }
        AgentAttentionCenter.shared.applyHerdrStatus(
            terminal: view,
            status: change.agent_status,
            agentID: change.agent,
            displayName: change.display_agent,
            title: change.title
        )
    }

    /// Hands herdr's authoritative agent facts to the attention center.
    func publishAgentStatuses() {
        for (paneId, status) in agentStatuses {
            guard let info = paneInfos[paneId], let view = paneViews[info.terminal_id] else { continue }
            AgentAttentionCenter.shared.applyHerdrStatus(
                terminal: view,
                status: status.agent_status,
                agentID: status.agent,
                displayName: status.display_agent,
                title: status.title
            )
        }
    }
}
