//
//  HerdrController+Commands.swift
//  rootshell
//
//  User intent flows back to herdr as socket API requests; the resulting
//  events and layout records reshape the local tabs. Creation responses
//  also project the returned tab and pane so focus follows the exact request.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

extension HerdrController {

    /// Called only by completed user moves. Project/custom group orders are
    /// presentation preferences; native workspace order belongs to herdr.
    static func syncTabOrderAfterUserMove(of tab: TabModel, in model: TabsModel) {
        guard let controller = controller(forTab: tab),
              controller.isActive, !controller.didEnd,
              let tabID = tab.herdrTabId, let workspaceID = tab.herdrWorkspaceId,
              controller.tabs[tabID] === tab,
              let orderedIDs = model.herdrReorderTabIDs(for: tab) else { return }
        let siblings = Set(orderedIDs)
        let currentOrder = controller.projectedTabOrder().filter { siblings.contains($0) }
        guard orderedIDs != currentOrder,
              let move = HerdrTabOrder.Move(tabID: tabID, workspaceID: workspaceID, orderedIDs: orderedIDs)
        else { return }
        controller.enqueueTabReorder(move)
    }

    private func enqueueTabReorder(_ move: HerdrTabOrder.Move) {
        guard isActive, !didEnd, mode == .legacy || channel != nil else { return }
        let channel = self.channel
        pendingTabReorders.append(move)
        guard tabReorderTask == nil else { return }
        let generation = streamGeneration
        tabReorderTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.streamGeneration == generation { self.tabReorderTask = nil }
            }
            while self.reorderIsCurrent(generation), let move = self.pendingTabReorders.first {
                do {
                    // Public tab numbers survive moves. Only the fresh list
                    // gives the pre-removal boundary that tab.move accepts.
                    let listed: HerdrControl.TabListResult
                    if let channel {
                        listed = try await channel.request(
                            "tab.list", HerdrControl.TabListParams(workspace_id: move.workspaceID),
                            as: HerdrControl.TabListResult.self
                        )
                    } else {
                        listed = try await self.legacyRequest(
                            args: "tab list --workspace \(LoginShellCommand.singleQuoted(move.workspaceID))",
                            as: HerdrControl.TabListResult.self
                        )
                    }
                    guard self.reorderIsCurrent(generation) else { return }
                    let confirmed: HerdrControl.TabListResult
                    if let params = move.params(in: listed.tabs) {
                        if let channel {
                            confirmed = try await channel.request("tab.move", params, as: HerdrControl.TabListResult.self)
                        } else {
                            confirmed = try await self.legacyMoveTab(params)
                        }
                        guard self.reorderIsCurrent(generation) else { return }
                    } else {
                        confirmed = listed
                        if !listed.tabs.contains(where: { $0.tab_id == move.tabID })
                            || !listed.tabs.contains(where: { $0.tab_id == move.placement.anchorID }) {
                            self.refreshTopology()
                        }
                    }
                    self.finishTabReorder()
                    self.applyTabOrder(confirmed.tabs, workspaceID: move.workspaceID)
                } catch {
                    guard self.reorderIsCurrent(generation) else { return }
                    self.finishTabReorder()
                    Self.logger.warning("herdr tab reorder failed: \(error.localizedDescription)")
                    self.management.error = error.localizedDescription
                    self.presentTabErrorIfNeeded(title: String(localized: "Couldn’t Reorder herdr Tabs"), message: error.localizedDescription)
                    if self.mode == .legacy { self.legacyNotice("tab reorder failed: \(error.localizedDescription)") }
                    self.reorderTabs()
                    // A timeout may already have moved the tab. Read back
                    // server state instead of retrying an ambiguous command.
                    self.refreshTopology()
                }
            }
        }
    }

    private func reorderIsCurrent(_ generation: UUID) -> Bool {
        !Task.isCancelled && !didEnd && streamGeneration == generation
    }

    private func finishTabReorder() {
        pendingTabReorders.removeFirst()
        tabReorderRevision &+= 1
        if mode == .legacy { legacySnapshotFingerprint = nil }
    }

    private func send<P: Encodable>(_ method: String, _ params: P) {
        guard let channel else { return }
        Task {
            do {
                try await channel.request(method, params)
            } catch {
                Self.logger.warning("herdr \(method) failed: \(error.localizedDescription)")
            }
        }
    }

    /// The user focused a pane: keep herdr's active pane in sync. Remote
    /// follows and watchdog re-asserts never call this. Vanilla endpoint
    /// focus belongs to our client, independently of the CLI's focus.
    func requestSelectPane(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding, isActive else { return }
        if mode == .legacy {
            if let endpoint, endpointActive, endpoint.boot != nil, endpoint.methods.contains("pane.focus") {
                // The binding is updated by pane.moved before the next frame.
                // A retained endpoint pane can still carry its old pane ID.
                endpoint.command("pane.focus", ["pane_id": binding.paneId], coalescingKey: "focus-pane")
            } else {
                legacyCommand("pane focus \(LoginShellCommand.singleQuoted(binding.paneId))")
            }
            return
        }
        send("pane.focus", HerdrControl.PaneTarget(pane_id: binding.paneId))
    }

    func requestSplit(_ view: Ghostty.TerminalView, horizontal: Bool) {
        guard let binding = view.herdrPaneBinding else { return }
        let direction = horizontal ? "right" : "down"
        if mode == .legacy {
            legacyCommand("pane split \(binding.paneId) --direction \(direction) --focus")
            return
        }
        send("pane.split", HerdrControl.PaneSplitParams(
            target_pane_id: binding.paneId,
            direction: direction
        ))
    }

    func requestClosePane(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding else { return }
        if mode == .legacy {
            legacyCommand("pane close \(binding.paneId)")
            return
        }
        send("pane.close", HerdrControl.PaneTarget(pane_id: binding.paneId))
    }

    @discardableResult
    func requestNewTab(inWorkspaceOf tab: TabModel?) -> Bool {
        let target = newTabTarget(inWorkspaceOf: tab)
        return requestNewTab(workspaceID: target.workspaceID, afterTabID: target.afterTabID)
    }

    /// Capture stable tab/workspace IDs before a chooser can change focus.
    /// Gateway actions use the resolved workspace's active tab as their anchor.
    func newTabTarget(inWorkspaceOf tab: TabModel?) -> (workspaceID: String?, afterTabID: String?) {
        let workspaceID = newTabWorkspace(preferred: tab?.herdrWorkspaceId)
        return (workspaceID, tab?.herdrTabId ?? workspaceID.flatMap { workspaces[$0]?.active_tab_id })
    }

    /// Empty-session creation is shared by attach and every New Tab entry
    /// point; repeated clicks cannot bootstrap extra workspaces.
    @discardableResult
    func requestNewTab(
        workspaceID preferredWorkspaceID: String?,
        afterTabID: String? = nil,
        isAutomatic: Bool = false
    ) -> Bool {
        guard !didEnd, isActive, hasProcessedInitialSnapshot else { return false }
        guard emptySessionCreationID == nil else { return true }
        let channel = self.channel
        guard mode == .legacy || channel != nil else { return false }
        let workspaceID = newTabWorkspace(preferred: preferredWorkspaceID)
        let anchorID = afterTabID ?? workspaceID.flatMap { workspaces[$0]?.active_tab_id }
        let generation = streamGeneration
        let requestID = UUID()
        if tabs.isEmpty { emptySessionCreationID = requestID }
        newTabError = nil
        newTabTasks[requestID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.newTabTasks.removeValue(forKey: requestID)
                if self.emptySessionCreationID == requestID { self.emptySessionCreationID = nil }
                if self.streamGeneration == generation, !self.didEnd { self.publishSessionState() }
            }
            guard self.creationIsCurrent(generation) else { return }
            do {
                // A close event can precede workspace.closed or a legacy poll.
                // Only a definitive rejection is safe to retry; a timeout may
                // already have created a shell on the host.
                let created: HerdrControl.TabCreatedResult
                do {
                    created = try await self.createTab(
                        workspaceID: self.newTabWorkspace(preferred: preferredWorkspaceID), channel: channel
                    )
                } catch HerdrChannelError.remote(let code, _) where code == "workspace_not_found" {
                    let snapshot = try await self.creationSnapshot(channel: channel)
                    guard self.creationIsCurrent(generation) else { return }
                    self.applySnapshot(snapshot)
                    created = try await self.createTab(
                        workspaceID: self.newTabWorkspace(preferred: preferredWorkspaceID), channel: channel
                    )
                }
                guard self.creationIsCurrent(generation) else { return }
                if let workspace = created.workspace { self.workspaces[workspace.workspace_id] = workspace }
                self.ensureTab(created.tab)
                self.paneDidAppear(created.root_pane)
                // Creation already tells us the initial pane. Mount it now
                // so its host can negotiate geometry while tab placement and
                // topology refresh round-trip, instead of leaving an empty
                // selected tab waiting for those unrelated requests.
                if self.mode == .raw, let tab = self.tabs[created.tab.tab_id],
                   tab.splitTree.isEmpty,
                   let view = self.paneViews[created.root_pane.terminal_id],
                   view.herdrPaneBinding?.tabId == created.tab.tab_id {
                    tab.splitTree = SplitTree(root: .leaf(view: view), zoomed: nil)
                }
                self.reorderTabs()
                self.refreshWorkspaceGroups()
                // Empty-session bootstrap can finish behind a restored tmux
                // tab (or after the user switches away). Only explicit New Tab
                // requests may override that selection.
                if !isAutomatic || self.tabsModel.maySelectInitialMultiplexerTab(gatewayTabID: self.gatewayTabID) {
                    self.selectTab(containingPane: created.root_pane.pane_id, focusPane: true)
                }
                self.autoHideGatewayIfWanted()
                if let channel, let anchorID {
                    do {
                        try await self.positionNewTab(created.tab, after: anchorID, channel: channel, generation: generation)
                    } catch {
                        guard self.creationIsCurrent(generation) else { return }
                        // Creation already succeeded. A rejected/timed-out move
                        // must never retry creation or claim the shell was lost.
                        Self.logger.warning("herdr new tab placement failed: \(error.localizedDescription)")
                        self.presentTabErrorIfNeeded(
                            title: String(localized: "Couldn’t Position herdr Tab"),
                            message: String(localized: "The tab was created, but couldn’t be placed beside the original tab.")
                                + "\n\n" + error.localizedDescription
                        )
                    }
                }
                guard self.creationIsCurrent(generation) else { return }
                self.refreshTopology()
            } catch {
                guard self.creationIsCurrent(generation) else { return }
                Self.logger.warning("herdr tab creation failed: \(error.localizedDescription)")
                self.newTabError = error.localizedDescription
                self.presentNewTabErrorIfNeeded()
                self.refreshTopology()
            }
        }
        publishSessionState()
        return true
    }

    private func creationIsCurrent(_ generation: UUID) -> Bool {
        !Task.isCancelled && !didEnd && streamGeneration == generation
    }

    private func positionNewTab(
        _ tab: HerdrControl.TabInfo,
        after anchorID: String,
        channel: HerdrControlChannel,
        generation: UUID
    ) async throws {
        // Read after creation: another client may have closed or moved the
        // anchor, and stable public tab numbers are not insertion positions.
        let listed = try await channel.request(
            "tab.list", HerdrControl.TabListParams(workspace_id: tab.workspace_id),
            as: HerdrControl.TabListResult.self
        )
        guard creationIsCurrent(generation) else { return }
        applyTabOrder(listed.tabs, workspaceID: tab.workspace_id)
        guard let params = HerdrTabOrder.moveParams(for: tab.tab_id, after: anchorID, in: listed.tabs) else { return }
        let moved = try await channel.request("tab.move", params, as: HerdrControl.TabListResult.self)
        guard creationIsCurrent(generation) else { return }
        applyTabOrder(moved.tabs, workspaceID: tab.workspace_id)
    }

    private func newTabWorkspace(preferred: String?) -> String? {
        if let preferred, workspaces[preferred] != nil { return preferred }
        return workspaces.values.first(where: \.focused)?.workspace_id
            ?? workspaces.values.min(by: { ($0.number, $0.workspace_id) < ($1.number, $1.workspace_id) })?.workspace_id
    }

    private func createTab(workspaceID: String?, channel: HerdrControlChannel?) async throws -> HerdrControl.TabCreatedResult {
        if let channel {
            if let workspaceID {
                return try await channel.request(
                    "tab.create", HerdrControl.TabCreateParams(workspace_id: workspaceID),
                    as: HerdrControl.TabCreatedResult.self
                )
            }
            return try await channel.request(
                "workspace.create", HerdrControl.WorkspaceCreateParams(), as: HerdrControl.TabCreatedResult.self
            )
        }
        let args = workspaceID.map { "tab create --workspace \(LoginShellCommand.singleQuoted($0)) --focus" }
            ?? "workspace create --focus"
        return try await legacyRequest(args: args, as: HerdrControl.TabCreatedResult.self)
    }

    private func creationSnapshot(channel: HerdrControlChannel?) async throws -> HerdrControl.SessionSnapshot {
        if let channel {
            return try await channel.request(
                "session.snapshot", HerdrControl.EmptyParams(), as: HerdrControl.SessionSnapshotResult.self
            ).snapshot
        }
        return try await legacyRequest(args: "api snapshot", as: HerdrControl.SessionSnapshotResult.self).snapshot
    }

    func requestCloseTab(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        if mode == .legacy {
            legacyCommand("tab close \(tabId)")
            return
        }
        send("tab.close", HerdrControl.TabTarget(tab_id: tabId))
    }

    func requestRenameTab(_ tab: TabModel, label: String) {
        guard let tabId = tab.herdrTabId else { return }
        runManagement { [self] in try await renameManagedTab(tabId, label: label) }
    }

    func requestToggleZoom(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding else { return }
        if mode == .legacy {
            legacyCommand("pane zoom \(binding.paneId)")
            return
        }
        send("pane.zoom", HerdrControl.PaneZoomParams(pane_id: binding.paneId, mode: "toggle"))
    }

    /// Divider drag: move the divider on the pane's `direction` edge by
    /// `cells`. herdr adds the amount to the ratio of the server split
    /// that owns the divider, so the cells are scaled by that split's
    /// extent from the last layout, not the native split's.
    func requestResize(_ view: Ghostty.TerminalView, direction: String, cells: Int) {
        guard let binding = view.herdrPaneBinding, cells > 0 else { return }
        let amount = serverSplitFraction(paneId: binding.paneId, tabId: binding.tabId, direction: direction, cells: cells)
        guard amount > 0.001 else { return }
        if mode == .legacy {
            legacyCommand("pane resize --pane \(binding.paneId) --direction \(direction) --amount \(String(format: "%.3f", amount))")
            return
        }
        send("pane.resize", HerdrControl.PaneResizeParams(pane_id: binding.paneId, direction: direction, amount: amount))
    }

    /// `cells` as a fraction of the server split whose divider lies on the
    /// pane's `direction` edge; falls back to the tab area when the split
    /// cannot be found.
    private func serverSplitFraction(paneId: String, tabId: String, direction: String, cells: Int) -> Double {
        guard let layout = lastLayouts[tabId] else { return 0 }
        let horizontal = direction == "left" || direction == "right"
        let areaExtent = Double(horizontal ? layout.area.width : layout.area.height)
        guard let pane = layout.panes.first(where: { $0.pane_id == paneId }) else {
            return areaExtent > 0 ? Double(cells) / areaExtent : 0
        }
        let edge: Int
        switch direction {
        case "right": edge = pane.rect.x + pane.rect.width
        case "left": edge = pane.rect.x
        case "down": edge = pane.rect.y + pane.rect.height
        default: edge = pane.rect.y
        }
        let split = layout.splits.first { split in
            guard (split.direction == "right") == horizontal else { return false }
            let extent = Double(horizontal ? split.rect.width : split.rect.height)
            let origin = horizontal ? split.rect.x : split.rect.y
            let divider = origin + Int((extent * split.ratio).rounded())
            guard abs(divider - edge) <= 1 else { return false }
            // The split must span the pane on the other axis.
            if horizontal {
                return pane.rect.y >= split.rect.y && pane.rect.y < split.rect.y + split.rect.height
            }
            return pane.rect.x >= split.rect.x && pane.rect.x < split.rect.x + split.rect.width
        }
        let extent = split.map { Double(horizontal ? $0.rect.width : $0.rect.height) } ?? areaExtent
        return extent > 0 ? Double(cells) / extent : 0
    }

    func requestFocusTab(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        if mode == .legacy, !endpointUnsupported { reconcileEndpoint(); return }
        send("tab.focus", HerdrControl.TabTarget(tab_id: tabId))
    }
}
