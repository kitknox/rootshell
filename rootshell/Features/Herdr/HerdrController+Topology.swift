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

    func applySnapshot(
        _ snapshot: HerdrControl.SessionSnapshot,
        preservingAgentUpdatesAfter revision: UInt64? = nil,
        directoryToken: PaneDirectoryRequestToken? = nil
    ) {
        guard !didEnd else { return }
        AgentAttentionCenter.shared.beginTopologyBatch()
        defer { AgentAttentionCenter.shared.endTopologyBatch() }
        let isInitialSnapshot = !hasProcessedInitialSnapshot
        let isLocalRecovery = gateway?.restoredLocalMultiplexerAttachment?.isHerdrControl == true
        let maySelectInitialTab = tabsModel.maySelectInitialMultiplexerTab(gatewayTabID: gatewayTabID)
        hasProcessedInitialSnapshot = true
        if !snapshot.tabs.isEmpty { newTabError = nil }
        workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspace_id, $0) })
        tabOrder.reset(to: snapshot.tabs)
        tabNames.reconcile(snapshot.tabs)
        for tab in snapshot.tabs {
            tabInfos[tab.tab_id] = tab
            ensureTab(tab)
        }
        let livePaneIds = Set(snapshot.panes.map(\.pane_id))
        let liveTerminalIds = Set(snapshot.panes.map(\.terminal_id))
        for pane in snapshot.panes {
            let current = mode == .legacy ? endpointMetadata?.pane(matching: pane) : nil
            var resolved = current?.updatingDirectories(in: pane) ?? pane
            if let directoryToken,
               !shouldAcceptSnapshotDirectory(for: resolved.terminal_id, token: directoryToken) {
                let existing: HerdrControl.PaneInfo? =
                    if let byPaneId = paneInfos[resolved.pane_id], byPaneId.terminal_id == resolved.terminal_id {
                        byPaneId
                    } else {
                        paneInfos.values.first { $0.terminal_id == resolved.terminal_id }
                    }
                if let existing {
                    resolved.cwd = existing.cwd
                    resolved.foreground_cwd = existing.foreground_cwd
                }
            }
            ensurePane(resolved)
        }
        prune(tabIds: Set(snapshot.tabs.map(\.tab_id)), paneIds: livePaneIds, terminalIds: liveTerminalIds)
        dropOrphanLayouts()
        for layout in snapshot.layouts {
            // Generic snapshots use the server TUI's area. Preserve a raw
            // layout for the same pane set so a topology refresh cannot
            // resize an attached terminal back to that unrelated viewport.
            if mode == .legacy, let projected = endpointLayouts[layout.tab_id],
               Set(projected.panes.map(\.pane_id)).isSubset(of: Set(layout.panes.map(\.pane_id))),
               projected.zoomed == layout.zoomed {
                applyLayout(projected)
            } else if mode == .raw, let controlled = controlLayouts[layout.tab_id],
               controlled.zoomed == layout.zoomed,
               Set(controlled.panes.map(\.pane_id)) == Set(layout.panes.map(\.pane_id)) {
                applyGeometryController(layout.geometry_controller, tabId: layout.tab_id, carried: layout.carriesRealGeometry)
                applyLayout(controlled)
            } else {
                // A protocol 2 snapshot layout is the tab's real geometry.
                if mode == .raw, layout.carriesRealGeometry { retainLayout(layout, in: &controlLayouts) }
                applyGeometryController(layout.geometry_controller, tabId: layout.tab_id, carried: layout.carriesRealGeometry)
                applyLayout(layout)
            }
        }
        // The snapshot is the whole truth about agents: a pane missing from
        // it lost its agent, so it gets a clearing report.
        var reports: [String: HerdrControl.AgentStatusChangedData] = [:]
        for pane in snapshot.panes {
            reports[pane.pane_id] = .init(pane_id: pane.pane_id, workspace_id: pane.workspace_id,
                agent_status: pane.agent_status, agent: pane.agent, title: pane.title,
                display_agent: pane.display_agent, state_labels: pane.state_labels)
        }
        for agent in snapshot.agents {
            reports[agent.pane_id] = HerdrControl.AgentStatusChangedData(
                pane_id: agent.pane_id,
                workspace_id: paneInfos[agent.pane_id]?.workspace_id ?? "",
                agent_status: agent.agent_status,
                agent: agent.agent,
                title: agent.title,
                display_agent: agent.display_agent,
                state_labels: nil
            )
        }
        for pane in snapshot.panes {
            if let revision, (agentStatusRevisions[pane.pane_id] ?? 0) > revision {
                // An event received while the request awaited is newer than
                // its snapshot, including an agent-removal event.
                reports[pane.pane_id] = agentStatuses[pane.pane_id]
            }
        }
        if mode == .legacy, let metadata = endpointMetadata {
            for pane in snapshot.panes {
                if let report = metadata.report(for: pane) { reports[pane.pane_id] = report }
            }
        }
        agentStatusRevisions = agentStatusRevisions.filter { livePaneIds.contains($0.key) }
        subscribedAgentPanes.formIntersection(livePaneIds)
        let vanished = agentStatuses.keys.filter { reports[$0] == nil }
        agentStatuses = reports
        for paneId in vanished {
            guard let info = paneInfos[paneId], let view = paneViews[info.terminal_id] else { continue }
            AgentAttentionCenter.shared.applyHerdrStatus(
                terminal: view, status: "unknown", agentID: nil, displayName: nil, title: nil
            )
        }
        publishAgentStatuses()
        applyEndpointAgentMetadata()
        if mode == .raw { subscribeAgentStatus() }
        reorderTabs()
        refreshWorkspaceGroups()
        focusedPaneId = snapshot.focused_pane_id
        applyInitialSelection(serverFocusedPaneID: snapshot.focused_pane_id, maySelectTab: maySelectInitialTab)
        for tab in tabs.values { refreshTitle(of: tab) }
        // Re-attach every pane whose surface already runs, focused tab first.
        queueAttaches(priorityTab: tabsModel.selectedTabID)
        pushGeometryForHostedTabs()
        autoHideGatewayIfWanted()
        // The initial focus is processed above, so this is the first pass
        // that can activate: a reconnect re-fits the selected tab here.
        if mode == .raw, capabilities.supportsSharedViewing { selectedTabDidChange() }
        if isInitialSnapshot, snapshot.tabs.isEmpty, !isLocalRecovery,
           requestNewTab(workspaceID: nil, isAutomatic: true) {
            // The automatic tab's arrival or failure reveals the card.
        } else {
            hasProcessedInitialReveal = true
        }
        publishSessionState()
        #if targetEnvironment(macCatalyst)
        if let attachment = localControlAttachment { recordLocalControlAttachment(attachment) }
        #endif
    }

    /// Publish free directory/checkout metadata independently of agent
    /// detection, which may be disabled or have no monitor for this pane yet.
    func publishProjectPaths() {
        for pane in paneInfos.values {
            guard let view = paneViews[pane.terminal_id] else { continue }
            publishProject(for: pane, view: view)
            view.setForegroundProgram(pane.foregroundProgram, from: .herdr)
        }
    }

    func publishProject(for pane: HerdrControl.PaneInfo, view: Ghostty.TerminalView) {
        let project = HerdrProjectIdentity.project(path: pane.projectPath,
            workspace: workspaces[pane.workspace_id], hostKey: gateway.map(AgentAttentionCenter.hostKey(for:)))
        let pathChanged = view.presentation.reportedProject?.path != project?.path
        if view.presentation.reportedProject != project { view.presentation.reportedProject = project }
        if pathChanged, let path = pane.projectPath {
            AgentAttentionCenter.shared.applyHerdrProjectPath(terminal: view, path: path)
        }
    }

    struct PaneDirectoryRequestToken {
        let eventRevision: UInt64
        let requestSeq: UInt64
    }

    func beginPaneDirectorySnapshotRequest() -> PaneDirectoryRequestToken {
        paneDirectoryRequestSeq &+= 1
        return PaneDirectoryRequestToken(eventRevision: paneDirectoryRevision, requestSeq: paneDirectoryRequestSeq)
    }

    func shouldAcceptSnapshotDirectory(for terminalId: String, token: PaneDirectoryRequestToken) -> Bool {
        guard (paneDirectoryRevisions[terminalId] ?? 0) <= token.eventRevision else { return false }
        guard (paneDirectoryAppliedSeq[terminalId] ?? 0) < token.requestSeq else { return false }
        paneDirectoryAppliedSeq[terminalId] = token.requestSeq
        return true
    }

    /// Marks a pushed directory event (`pane_updated`, `pane_created`, `pane_moved`,
    /// or endpoint metadata) so an earlier snapshot request cannot overwrite it.
    func notePaneDirectoryUpdate(terminalId: String) {
        paneDirectoryRevision &+= 1
        paneDirectoryRevisions[terminalId] = paneDirectoryRevision
    }

    /// Cached server-reported directory for `binding` (`foreground_cwd` before shell `cwd`),
    /// preserving exact filesystem whitespace.
    func workingDirectory(for binding: Ghostty.TerminalView.HerdrPaneBinding) -> String? {
        paneInfo(for: binding)?.workingDirectoryPath
    }

    /// Queries the live control stream for the bound pane's current directory
    /// without disturbing layouts, focus, or other panes, and preserving any
    /// directory event or newer snapshot received while the request was in flight.
    func refreshWorkingDirectory(for binding: Ghostty.TerminalView.HerdrPaneBinding) async -> String? {
        if mode == .raw, !didEnd, isActive, let channel {
            let token = beginPaneDirectorySnapshotRequest()
            if let snapshot = try? await channel.request(
                "session.snapshot", HerdrControl.EmptyParams(),
                as: HerdrControl.SessionSnapshotResult.self,
                timeout: .seconds(3)
            ).snapshot, !Task.isCancelled, !didEnd, self.channel === channel {
                guard let pane = snapshot.panes.first(where: {
                    $0.pane_id == binding.paneId && $0.terminal_id == binding.terminalId
                }) ?? snapshot.panes.first(where: { $0.terminal_id == binding.terminalId })
                else { return workingDirectory(for: binding) }

                guard shouldAcceptSnapshotDirectory(for: pane.terminal_id, token: token) else {
                    return workingDirectory(for: binding)
                }

                if var existing = paneInfos[pane.pane_id], existing.terminal_id == pane.terminal_id {
                    if existing.cwd != pane.cwd || existing.foreground_cwd != pane.foreground_cwd {
                        existing.cwd = pane.cwd
                        existing.foreground_cwd = pane.foreground_cwd
                        paneInfos[pane.pane_id] = existing
                        if let view = paneViews[existing.terminal_id] {
                            publishProject(for: existing, view: view)
                        }
                    }
                    return existing.workingDirectoryPath
                }
                return pane.workingDirectoryPath ?? workingDirectory(for: binding)
            }
        }
        return workingDirectory(for: binding)
    }

    private func paneInfo(for binding: Ghostty.TerminalView.HerdrPaneBinding) -> HerdrControl.PaneInfo? {
        if let info = paneInfos[binding.paneId], info.terminal_id == binding.terminalId {
            return info
        }
        return paneInfos.values.first { $0.terminal_id == binding.terminalId }
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
        tabNames.renamed(tabId, label: label)
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
        publishManagementState()
    }

    /// Applies the complete ordered list returned by tab.list or tab.move.
    func applyTabOrder(_ infos: [HerdrControl.TabInfo], workspaceID: String) {
        for info in infos { tabInfos[info.tab_id] = info }
        tabOrder.update(workspaceID: workspaceID, tabs: infos)
        reorderTabs()
    }

    /// Confirmed server order with unacknowledged user moves layered on top.
    func projectedTabOrder() -> [String] {
        let orderedIDs = tabOrder.orderedIDs(
            in: tabsModel.tabs.compactMap { tab in
                guard let id = tab.herdrTabId, tabs[id] === tab else { return nil }
                return tabInfos[id]
            },
            workspaceNumbers: workspaces.mapValues(\.number)
        )
        return pendingTabReorders.reduce(orderedIDs) { $1.applying(to: $0) }
    }

    /// Orders this gateway's projected tabs by workspace then server list order,
    /// permuting only the slots they already occupy.
    func reorderTabs() {
        defer { publishManagementState() }
        tabOrderDeferredForDrag = false
        let mine = Set(tabs.values.map(\.id))
        let slots = tabsModel.tabs.indices.filter { mine.contains(tabsModel.tabs[$0].id) }
        guard slots.count > 1 else { return }
        let current = slots.map { tabsModel.tabs[$0] }
        // Hover moves are local until drop. In particular, fallback's regular
        // snapshots must not erase a drag before its final order is committed.
        if current.contains(where: { TabTransferCoordinator.shared.isActiveDrag(sourceWindowId: hostWindowId, tabID: $0.id) }) {
            tabOrderDeferredForDrag = true
            return
        }
        let sorted = projectedTabOrder().compactMap { tabs[$0] }
        guard sorted.count == current.count else { return }
        if !current.elementsEqual(sorted, by: { $0 === $1 }) {
            var reordered = tabsModel.tabs
            for (slot, tab) in zip(slots, sorted) {
                reordered[slot] = tab
            }
            tabsModel.tabs = reordered
        }
        // A remembered native group permutation must not mask a server move,
        // even when the backing array was already in the confirmed order.
        tabsModel.synchronizeHerdrGroupOrder(sorted.map(\.id), ownerID: gatewayUUID)
    }

    /// Workspace labels feed the tab group titles; bump grouping so the
    /// sidebar re-derives them.
    func refreshWorkspaceGroups() {
        let hostKey = gateway.map(AgentAttentionCenter.hostKey(for:))
        for tab in tabs.values {
            guard let workspaceId = tab.herdrWorkspaceId else { continue }
            let label = workspaces[workspaceId]?.label ?? workspaceId
            if tab.herdrWorkspaceLabel != label {
                tab.herdrWorkspaceLabel = label
            }
            tab.herdrHostKey = hostKey
            tab.herdrWorkspaceProject = HerdrProjectIdentity.project(
                path: nil, workspace: workspaces[workspaceId], hostKey: hostKey)
        }
        publishProjectPaths()
        publishManagementState()
    }

    // MARK: - Panes

    func paneDidAppear(_ pane: HerdrControl.PaneInfo) {
        let isNew = paneInfos[pane.pane_id] == nil
        notePaneDirectoryUpdate(terminalId: pane.terminal_id)
        ensurePane(pane)
        if isNew {
            subscribeAgentStatus(paneId: pane.pane_id)
        }
        if let layout = lastLayouts[pane.tab_id] { applyLayout(layout) }
    }

    func paneDidUpdate(_ pane: HerdrControl.PaneInfo) {
        paneInfos[pane.pane_id] = pane
        notePaneDirectoryUpdate(terminalId: pane.terminal_id)
        agentStatusDidChange(.init(pane_id: pane.pane_id, workspace_id: pane.workspace_id,
            agent_status: pane.agent_status, agent: pane.agent, title: pane.title,
            display_agent: pane.display_agent, state_labels: pane.state_labels))
        if let view = paneViews[pane.terminal_id] {
            view.seedHerdrTitle(pane.terminal_title ?? pane.title)
            publishProject(for: pane, view: view)
            view.setForegroundProgram(pane.foregroundProgram, from: .herdr)
        } else if let tab = tabs[pane.tab_id] {
            refreshTitle(of: tab)
        }
        publishManagementState()
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
        notePaneDirectoryUpdate(terminalId: moved.pane.terminal_id)
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
        refreshTopology()
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
            existing.seedHerdrTitle(pane.terminal_title ?? pane.title)
            publishProject(for: pane, view: existing)
            existing.setForegroundProgram(pane.foregroundProgram, from: .herdr)
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
        view.seedHerdrTitle(pane.terminal_title ?? pane.title)
        publishProject(for: pane, view: view)
        view.setForegroundProgram(pane.foregroundProgram, from: .herdr)
        NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
    }

    /// Tears down views and tabs herdr no longer has.
    func prune(tabIds: Set<String>, paneIds: Set<String>, terminalIds: Set<String>) {
        tabOrder.prune(to: tabIds)
        let staleTabs = tabs.filter { !tabIds.contains($0.key) }
        let removedIDs = Set(staleTabs.values.map(\.id))
        let selectedID = tabsModel.selectedTabID
        let followsPaneMove = paneMoveSelectionRevision == tabsModel.selectionRevision
        let removesSelection = selectedID.map { removedIDs.contains($0) } ?? false
        let neighbor = removesSelection ? selectedID.flatMap { tabsModel.groupedCloseNeighbor(for: $0) } : nil
        for (paneId, _) in paneInfos where !paneIds.contains(paneId) {
            paneInfos.removeValue(forKey: paneId)
        }
        paneDirectoryRevisions = paneDirectoryRevisions.filter { terminalIds.contains($0.key) }
        paneDirectoryAppliedSeq = paneDirectoryAppliedSeq.filter { terminalIds.contains($0.key) }
        let movingTerminals = Set(pendingPaneMoveTerminals.values)
        let staleViews = paneViews.filter { !terminalIds.contains($0.key) && !movingTerminals.contains($0.key) }
        for (terminalId, view) in staleViews {
            retirePane(view: view, terminalId: terminalId)
        }
        tabsModel.tabs.removeAll { removedIDs.contains($0.id) }
        for (tabId, _) in staleTabs {
            tabs.removeValue(forKey: tabId)
            tabInfos.removeValue(forKey: tabId)
            lastLayouts.removeValue(forKey: tabId)
            zoomedLayoutRequests.removeValue(forKey: tabId)
            controlLayouts.removeValue(forKey: tabId)
            endpointLayouts.removeValue(forKey: tabId)
            tabGeometryStates.removeValue(forKey: tabId)
            geometryTasks.removeValue(forKey: tabId)?.cancel()
            takeoverRequested.remove(tabId)
            takeControlPromptedTabs.remove(tabId)
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
            // Closing the emptied source tab is part of the move. Its
            // automatic neighbor selection must not cancel following the
            // moved pane; an intervening user selection still does.
            if followsPaneMove { paneMoveSelectionRevision = tabsModel.selectionRevision }
        }
        publishSessionState()
        if !staleViews.isEmpty {
            NotificationCenter.default.post(name: .herdrPaneBindingsChanged, object: nil)
        }
    }

    func pruneAll() {
        pendingPaneMoveTerminals.removeAll()
        prune(tabIds: [], paneIds: [], terminalIds: [])
        if let gatewayTabID, tabsModel.selectedTabID == nil || !tabsModel.tabs.contains(where: { $0.id == tabsModel.selectedTabID }) {
            tabsModel.selectedTabID = gatewayTabID
        }
    }

    private func retirePane(view: Ghostty.TerminalView, terminalId: String) {
        view.herdrEndpointPane?.disconnect()
        view.herdrEndpointPane = nil
        view.endHerdrTitleAttachment()
        if paneControlStates.removeValue(forKey: terminalId) != nil { view.updateHerdrPaneControlOverlay() }
        attachQueue.removeAll { $0 == terminalId }
        attachRetries.removeValue(forKey: terminalId)?.cancel()
        attachesInFlight.removeValue(forKey: terminalId)
        panesNeedingSnapshot.remove(terminalId)
        resizeRecoveries.removeValue(forKey: terminalId)
        view.isLogicallyFocused = false
        view.shouldBecomeFirstResponderWhenReady = false
        view.herdrTargetGrid = nil
        if let attachId = attachIds.removeValue(forKey: terminalId) {
            snapshotRequestsInFlight.removeValue(forKey: attachId)
            snapshotRetryWanted.remove(attachId)
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

    /// Initial topology can build ratios before any surface has cell metrics.
    /// Rebuild from the current raw layout once they exist; a store-only size
    /// push by a viewer will not elicit another layout from the server.
    func refreshLayoutForSurfaceMetrics(from view: Ghostty.TerminalView) {
        guard mode == .raw, isActive, !didEnd,
              let binding = view.herdrPaneBinding, binding.gatewayUUID == gatewayUUID,
              paneViews[binding.terminalId] === view,
              let tab = tabs[binding.tabId], tab.id == view.containingTabID,
              let layout = controlLayouts[binding.tabId],
              let node = HerdrLayoutTree.build(layout),
              let root = buildSplitNode(node) else { return }
        let tree = SplitTree<SplitPaneView>(root: root, zoomed: tab.splitTree.zoomed)
        // This is only a metric refresh. Preserve local focus and zoom, and
        // never restore an old pane set while a topology change is arriving.
        guard tree.structuralIdentity == tab.splitTree.structuralIdentity,
              tree.root != tab.splitTree.root else { return }
        tab.splitTree = tree
    }

    /// Layouts can precede their tab's creation. Cap how many are held for
    /// tabs that do not exist, so a peer cannot grow the caches unbounded.
    func retainLayout(_ layout: HerdrControl.LayoutSnapshot,
                      in cache: inout [String: HerdrControl.LayoutSnapshot]) {
        if tabs[layout.tab_id] == nil, cache[layout.tab_id] == nil {
            let orphans = cache.keys.filter { tabs[$0] == nil }
            if orphans.count >= Self.maxOrphanLayouts, let evicted = orphans.first {
                cache.removeValue(forKey: evicted)
            }
        }
        cache[layout.tab_id] = layout
    }

    func dropOrphanLayouts() {
        lastLayouts = lastLayouts.filter { tabs[$0.key] != nil }
        controlLayouts = controlLayouts.filter { tabs[$0.key] != nil }
    }

    func applyLayout(_ layout: HerdrControl.LayoutSnapshot, barrier: UInt64? = nil) {
        let previousLayout = lastLayouts[layout.tab_id]
        retainLayout(layout, in: &lastLayouts)
        guard let tab = tabs[layout.tab_id] else { return }
        guard let node = HerdrLayoutTree.build(layout) else { return }
        guard let builtRoot = buildSplitNode(node) else {
            // A pane view is missing (out-of-order event); the next layout
            // record for this tab retries.
            return
        }
        // Both raw control layouts and fallback frames can contain only the
        // zoomed pane. Keep the full tree for the picker and hidden surfaces.
        let root = layout.zoomed
            ? (tab.splitTree.root ?? builtRoot) : builtRoot
        // Each pane keeps exactly the grid herdr gave it, whatever slot the
        // ratio math hands it (id=herdr-chromeless).
        // Degraded mode sizes each pane from its own grid (`terminal.resize`),
        // so a clamp there would pin the pane to the last snapshot forever.
        var targetGridChanged = false
        for pane in layout.panes {
            guard let terminalId = paneInfos[pane.pane_id]?.terminal_id, let view = paneViews[terminalId] else { continue }
            view.containingTabID = tab.id
            // A generic snapshot describes the server TUI's viewport. Let
            // the initial native host use its full space until our raw layout
            // arrives; clamping to the TUI first causes a shrink/grow bounce.
            let ownedElsewhere = tabGeometryStates[layout.tab_id]?.isOwnedElsewhere == true
            let target: (cols: Int, rows: Int)? = (mode == .raw && controlLayouts[layout.tab_id] != nil
                && (tabGeometryStates[layout.tab_id]?.hasRequested == true || ownedElsewhere || layout.carriesRealGeometry))
                || endpointLayouts[layout.tab_id] == layout
                ? (cols: pane.terminalCols, rows: pane.terminalRows) : nil
            if view.herdrTargetGrid?.cols != target?.cols || view.herdrTargetGrid?.rows != target?.rows {
                targetGridChanged = true
            }
            view.herdrTargetGrid = target
        }
        var zoomed: SplitTree<SplitPaneView>.Node?
        if layout.zoomed, let terminalId = paneInfos[layout.focused_pane_id]?.terminal_id,
           let view = paneViews[terminalId] {
            zoomed = .leaf(view: view)
        }
        let tree = SplitTree<SplitPaneView>(root: root, zoomed: zoomed)
        let structureChanged = tab.splitTree.structuralIdentity != tree.structuralIdentity
        // Every snapshot re-applies every tab's layout; an unchanged tree
        // must not invalidate SwiftUI or resize panes herdr did not reflow.
        let treeChanged = tab.splitTree.root != tree.root || tab.splitTree.zoomed != tree.zoomed
        if treeChanged { tab.splitTree = tree }
        if layout.zoomed { restoreZoomedLayoutIfNeeded(in: tab, tabID: layout.tab_id) }
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
        guard treeChanged || targetGridChanged || previousLayout != layout || barrier != nil else { return }
        refreshTitle(of: tab)
        tabsModel.syncDisplayedTab()
        // Ratios changed under the panes; force each surface to re-sync its
        // grid after the layout pass (mirrors the tmux path).
        let views = node.paneIds.compactMap { paneInfos[$0]?.terminal_id }.compactMap { paneViews[$0] }
        DispatchQueue.main.async { [weak self] in
            for view in views {
                view.invalidateCachedSize()
                view.sizeDidChange(view.bounds.size)
            }
            if let barrier {
                Ghostty.TerminalView.ghosttyAPIQueue.async {
                    Task { @MainActor [weak self] in
                        self?.confirmLayoutParserGrids(barrier: barrier)
                    }
                }
            }
        }
    }

    /// On an already-zoomed attachment there is no previous split tree to
    /// preserve. Read the hidden topology without changing the server's zoom.
    private func restoreZoomedLayoutIfNeeded(in tab: TabModel, tabID: String) {
        let paneIDs = Set(paneInfos.values.filter { $0.tab_id == tabID }.map(\.pane_id))
        let projectedIDs = Set(tab.splitTree.terminalLeaves.compactMap { $0.herdrPaneBinding?.paneId })
        guard paneIDs.count > 1, projectedIDs != paneIDs,
              zoomedLayoutRequests[tabID] == nil, isActive, !didEnd else { return }
        let requestID = UUID()
        let generation = streamGeneration
        let revision = managementRevision
        zoomedLayoutRequests[tabID] = requestID
        Task { [weak self, weak tab] in
            guard let self else { return }
            defer {
                if self.zoomedLayoutRequests[tabID] == requestID {
                    self.zoomedLayoutRequests.removeValue(forKey: tabID)
                }
            }
            guard let tab, self.tabs[tabID] === tab,
                  self.streamGeneration == generation,
                  self.zoomedLayoutRequests[tabID] == requestID,
                  tab.splitTree.zoomed != nil else { return }
            // A snapshot may still have been adding panes when this read was
            // scheduled. Capture membership after that synchronous pass ends.
            let paneIDs = Set(self.paneInfos.values.filter { $0.tab_id == tabID }.map(\.pane_id))
            do {
                let layout = try await self.managementRequest(
                    "layout.export", HerdrControl.TabTarget(tab_id: tabID),
                    as: HerdrControl.LayoutDescriptionResult.self
                ).layout
                guard self.streamGeneration == generation, !self.didEnd,
                      self.zoomedLayoutRequests[tabID] == requestID,
                      self.managementRevision == revision, self.tabs[tabID] === tab,
                      tab.splitTree.zoomed != nil, layout.tab_id == tabID,
                      layout.workspace_id == tab.herdrWorkspaceId,
                      layout.root.paneIDs.count == paneIDs.count, Set(layout.root.paneIDs) == paneIDs,
                      Set(self.paneInfos.values.filter { $0.tab_id == tabID }.map(\.pane_id)) == paneIDs,
                      let root = self.buildSplitNode(layout.root),
                      Set(root.leaves().map { ObjectIdentifier($0) }).count == paneIDs.count else { return }
                tab.splitTree = SplitTree(root: root, zoomed: tab.splitTree.zoomed)
                self.tabsModel.syncDisplayedTab()
            } catch is CancellationError { } catch {
                Self.logger.debug("herdr zoomed layout export failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildSplitNode(_ node: HerdrControl.ExportedLayoutNode) -> SplitTree<SplitPaneView>.Node? {
        switch node {
        case .pane(let paneID):
            guard let info = paneInfos[paneID], let view = paneViews[info.terminal_id] else { return nil }
            return .leaf(view: view)
        case let .split(direction, ratio, first, second):
            guard let left = buildSplitNode(first), let right = buildSplitNode(second) else { return nil }
            return .split(.init(direction: direction == .right ? .horizontal : .vertical,
                                ratio: min(max(ratio, 0.05), 0.95), left: left, right: right))
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
        // The gateway tab was held off screen while its selection was pending.
        // Whatever gets selected below re-syncs; this covers staying put.
        defer { tabsModel.syncDisplayedTab() }
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
        for view in tab.splitTree.terminalLeaves {
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
        for id in Array(workspaces.keys) { workspaces[id]?.focused = id == info.workspace_id }
        workspaces[info.workspace_id]?.active_tab_id = info.tab_id
        for pane in paneInfos.values where pane.tab_id == info.tab_id {
            var updated = pane
            updated.focused = pane.pane_id == paneId
            paneInfos[pane.pane_id] = updated
        }
        // Someone else drives a tab they own; their pane focus stays theirs.
        guard tabGeometryStates[info.tab_id]?.isOwnedElsewhere != true else {
            refreshTitle(of: tab)
            return
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
        if let info = tabInfos[tabId] {
            workspaces[info.workspace_id]?.active_tab_id = tabId
        }
        publishSessionState()
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
        // Even a repeated event proves that this value is newer than any
        // snapshot request already in flight.
        agentStatusRevision &+= 1
        agentStatusRevisions[change.pane_id] = agentStatusRevision
        guard agentStatuses[change.pane_id] != change else { return }
        // Retain clearing reports so a delayed snapshot cannot revive an agent.
        agentStatuses[change.pane_id] = change
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
