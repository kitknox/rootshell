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
        workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspace_id, $0) })
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
            applyLayout(layout)
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
        if let focusedPane = snapshot.focused_pane_id {
            focusedPaneId = focusedPane
            if !hasProcessedInitialFocus {
                hasProcessedInitialFocus = true
                selectTab(containingPane: focusedPane, focusPane: true)
            }
        }
        // Re-attach every pane whose surface already runs, focused tab first.
        queueAttaches(priorityTab: tabsModel.selectedTabID)
        pushGeometryForVisibleTabs()
        autoHideGatewayIfWanted()
        publishProjectPaths()
    }

    /// herdr knows each pane's directory; hand it to agent attention so the
    /// sidebar shows the project without probing the host.
    func publishProjectPaths() {
        for pane in paneInfos.values {
            guard let view = paneViews[pane.terminal_id],
                  let path = pane.foreground_cwd ?? pane.cwd, path.hasPrefix("/") else { continue }
            AgentAttentionCenter.shared.applyHerdrProjectPath(terminal: view, path: path)
        }
    }

    // MARK: - Tabs

    func ensureTab(_ info: HerdrControl.TabInfo) {
        tabInfos[info.tab_id] = info
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
        tab.title = info.label
        tabs[info.tab_id] = tab
        tabsModel.tabs.append(tab)
        refreshTitle(of: tab)
        // A tab the user just asked for lands in front, like a native new
        // tab; tabs other clients create stay where they are.
        if let until = pendingNewTabSelectionUntil, until > Date() {
            pendingNewTabSelectionUntil = nil
            tabsModel.selectedTabID = tab.id
            tabsModel.pendingScrollToTabID = tab.id
        } else if tabsModel.selectedTabID == nil {
            tabsModel.selectedTabID = tab.id
        }
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

    /// Tab title precedence: the focused pane's reported title, else herdr's
    /// tab label.
    func refreshTitle(of tab: TabModel) {
        guard let tabId = tab.herdrTabId, let info = tabInfos[tabId] else { return }
        let focusedTitle = paneInfos.values
            .first { $0.tab_id == tabId && $0.focused }
            .flatMap { pane -> String? in
                let title = pane.title ?? pane.terminal_title
                return title?.isEmpty == false ? title : nil
            }
        let title = focusedTitle ?? info.label
        if tab.title != title {
            tab.title = title
        }
    }

    /// Orders this gateway's projected tabs by workspace then tab number,
    /// permuting only the slots they already occupy.
    func reorderTabs() {
        let mine = Set(tabs.values.map(\.id))
        let slots = tabsModel.tabs.indices.filter { mine.contains(tabsModel.tabs[$0].id) }
        guard slots.count > 1 else { return }
        func key(_ tab: TabModel) -> (Int, Int) {
            guard let tabId = tab.herdrTabId, let info = tabInfos[tabId] else { return (Int.max, Int.max) }
            let workspaceNumber = workspaces[info.workspace_id]?.number ?? Int.max
            return (workspaceNumber, info.number)
        }
        let current = slots.map { tabsModel.tabs[$0] }
        let sorted = current.sorted { key($0) < key($1) }
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
    }

    func paneDidUpdate(_ pane: HerdrControl.PaneInfo) {
        let previous = paneInfos[pane.pane_id]
        paneInfos[pane.pane_id] = pane
        if let tab = tabs[pane.tab_id] {
            refreshTitle(of: tab)
        }
        let path = pane.foreground_cwd ?? pane.cwd
        if let path, path.hasPrefix("/"), path != (previous?.foreground_cwd ?? previous?.cwd),
           let view = paneViews[pane.terminal_id] {
            AgentAttentionCenter.shared.applyHerdrProjectPath(terminal: view, path: path)
        }
        if let view = paneViews[pane.terminal_id], view.userOverrideTitle == nil,
           let title = pane.title ?? pane.terminal_title, !title.isEmpty, view.title != title {
            view.title = title
        }
    }

    func paneDidClose(paneId: String) {
        guard let info = paneInfos.removeValue(forKey: paneId) else { return }
        prune(
            tabIds: Set(tabInfos.keys),
            paneIds: Set(paneInfos.keys),
            terminalIds: Set(paneInfos.values.map(\.terminal_id))
        )
        _ = info
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
            if existing.herdrPaneBinding != binding {
                existing.herdrPaneBinding = binding
            }
            if let tab = tabs[pane.tab_id], existing.containingTabID != tab.id {
                existing.containingTabID = tab.id
            }
            return
        }
        guard let ghosttyApp else {
            Self.logger.error("herdr control: no app for pane \(pane.pane_id)")
            return
        }
        let view = Ghostty.TerminalView(app, ghosttyApp: ghosttyApp, connectionConfig: .local(), windowId: hostWindowId)
        view.setOverlayOwnsKeyboard(tabsModel.overlayOwnsKeyboard)
        view.herdrPaneBinding = binding
        if let title = pane.title ?? pane.terminal_title, !title.isEmpty {
            view.title = title
        }
        if let tab = tabs[pane.tab_id] {
            view.containingTabID = tab.id
            view.setOcclusion(tabsModel.selectedTabID == tab.id)
        } else {
            view.setOcclusion(false)
        }
        paneViews[pane.terminal_id] = view
        NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
    }

    /// Tears down views and tabs herdr no longer has.
    func prune(tabIds: Set<String>, paneIds: Set<String>, terminalIds: Set<String>) {
        for (paneId, _) in paneInfos where !paneIds.contains(paneId) {
            paneInfos.removeValue(forKey: paneId)
        }
        let staleViews = paneViews.filter { !terminalIds.contains($0.key) }
        for (terminalId, view) in staleViews {
            retirePane(view: view, terminalId: terminalId)
        }
        let staleTabs = tabs.filter { !tabIds.contains($0.key) }
        for (tabId, tab) in staleTabs {
            let wasSelected = tabsModel.selectedTabID == tab.id
            let neighbor = wasSelected ? tabsModel.groupedCloseNeighbor(for: tab.id) : nil
            tabsModel.tabs.removeAll { $0.id == tab.id }
            tabs.removeValue(forKey: tabId)
            tabInfos.removeValue(forKey: tabId)
            lastLayouts.removeValue(forKey: tabId)
            pushedGeometry.removeValue(forKey: tabId)
            if wasSelected {
                tabsModel.selectedTabID = neighbor ?? tabsModel.tabs.first?.id
            }
        }
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
        view.isLogicallyFocused = false
        view.shouldBecomeFirstResponderWhenReady = false
        view.herdrTargetGrid = nil
        if let attachId = attachIds.removeValue(forKey: terminalId) {
            terminalByAttach.removeValue(forKey: attachId)
            router.unregister(attachId: attachId)
        }
        legacyStreams.removeValue(forKey: terminalId)?.close()
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
                    if let terminal = next?.asTerminal, tabsModel.selectedTabID == tab.id {
                        focusPane(terminal, in: tab)
                    }
                }
            }
        }
        view.cleanup(reason: .userClose)
    }

    // MARK: - Layout

    func applyLayout(_ layout: HerdrControl.LayoutSnapshot, barrier: UInt64? = nil) {
        guard let tab = tabs[layout.tab_id] else { return }
        lastLayouts[layout.tab_id] = layout
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
            view.herdrTargetGrid = mode == .raw ? (cols: pane.rect.width, rows: pane.rect.height) : nil
        }
        var zoomed: SplitTree<SplitPaneView>.Node?
        if layout.zoomed, let terminalId = paneInfos[layout.focused_pane_id]?.terminal_id,
           let view = paneViews[terminalId] {
            zoomed = .leaf(view: view)
        }
        tab.splitTree = SplitTree(root: root, zoomed: zoomed)
        if let barrier {
            armLayoutRelease(for: layout, barrier: barrier)
        }
        if tab.focusedPane == nil, let firstId = node.firstPaneId,
           let terminalId = paneInfos[firstId]?.terminal_id, let first = paneViews[terminalId] {
            focusPane(first, in: tab)
        }
        if let terminalId = paneInfos[layout.focused_pane_id]?.terminal_id,
           let view = paneViews[terminalId], tab.focusedPane !== view {
            focusPane(view, in: tab)
        }
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
        case .pane(_, let rect):
            return CGFloat(horizontal ? rect.width : rect.height) * cell + pad * 2
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
            padX: CGFloat(PaddingManager.shared.effectivePaddingX),
            padY: CGFloat(PaddingManager.shared.effectivePaddingY),
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

    /// Makes `view` the focused pane of `tab` (logical focus plus first
    /// responder when the tab is visible). Mirrors TmuxController.focusPane.
    func focusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        for other in paneViews.values where other !== view {
            other.isLogicallyFocused = false
            other.shouldBecomeFirstResponderWhenReady = false
            other.clearStaleGhosttyFocus()
        }
        view.isLogicallyFocused = true
        view.shouldBecomeFirstResponderWhenReady = true
        tab.focusedTerminal = view
        guard tabsModel.selectedTabID == tab.id else { return }
        if view.window != nil, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
        armFocusWatchdog(for: view)
    }

    private func armFocusWatchdog(for view: Ghostty.TerminalView) {
        focusWatchdog?.cancel()
        focusWatchdog = Task { @MainActor [weak self, weak view] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let view, !Task.isCancelled else { return }
                guard view.isLogicallyFocused, view.window != nil else { return }
                guard let tabID = view.containingTabID, self.tabsModel.selectedTabID == tabID else { return }
                if view.isFirstResponder { return }
                _ = view.becomeFirstResponder()
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
        if tab.focusedPane !== view {
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
