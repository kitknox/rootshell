//
//  HerdrController+Panes.swift
//  rootshell
//
//  Per-pane plumbing: attaching raw streams, routing input and snapshots,
//  and telling herdr how big each tab is.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import UIKit

extension HerdrController {

    /// Concurrent attach requests during a resync; keeps a big session from
    /// flooding the link while the focused tab repaints first.
    private static let maxAttachesInFlight = 2

    // MARK: - Session shims

    /// Called by TerminalSessionController when a pane surface needs its
    /// session; nil when this controller does not own the binding.
    func makePaneSession(for binding: Ghostty.TerminalView.HerdrPaneBinding) -> HerdrPaneSession? {
        guard binding.gatewayUUID == gatewayUUID else { return nil }
        let session = HerdrPaneSession(controller: self, terminalId: binding.terminalId, paneId: binding.paneId)
        return session
    }

    func paneSessionDidStart(_ session: HerdrPaneSession) {
        paneSessions[session.terminalId] = session
        if mode == .legacy {
            legacyReconcileAttaches()
            return
        }
        if let existing = attachIds[session.terminalId] {
            router.register(attachId: existing, sink: session.outputSink)
            return
        }
        enqueueAttach(session.terminalId, front: isVisible(terminalId: session.terminalId))
    }

    func paneSessionDidStop(_ session: HerdrPaneSession) {
        guard paneSessions[session.terminalId] === session else { return }
        paneSessions.removeValue(forKey: session.terminalId)
        legacyPaneDidStop(session)
        attachQueue.removeAll { $0 == session.terminalId }
        if let attachId = attachIds.removeValue(forKey: session.terminalId) {
            terminalByAttach.removeValue(forKey: attachId)
            router.unregister(attachId: attachId)
            if let channel {
                Task { try? await channel.request("terminal.detach", HerdrControl.AttachTarget(attach_id: attachId)) }
            }
        }
    }

    func sendInput(from session: HerdrPaneSession, _ data: Data) {
        if mode == .legacy {
            legacyInput(session, data)
            return
        }
        guard let attachId = session.attachId, let channel else { return }
        Task { await channel.sendInput(attachId: attachId, bytes: data) }
    }

    // MARK: - Attach queue

    private func isVisible(terminalId: String) -> Bool {
        guard let view = paneViews[terminalId], let tabID = view.containingTabID else { return false }
        return tabsModel.selectedTabID == tabID
    }

    /// Queues every started pane for (re)attach, the selected tab's first.
    func queueAttaches(priorityTab: UUID?) {
        if mode == .legacy {
            legacyReconcileAttaches()
            return
        }
        guard channel != nil else { return }
        let ordered = paneSessions.keys.sorted { lhs, rhs in
            let lhsVisible = paneViews[lhs]?.containingTabID == priorityTab
            let rhsVisible = paneViews[rhs]?.containingTabID == priorityTab
            if lhsVisible != rhsVisible { return lhsVisible }
            return lhs < rhs
        }
        for terminalId in ordered where attachIds[terminalId] == nil && !attachQueue.contains(terminalId) {
            attachQueue.append(terminalId)
        }
        pumpAttachQueue()
    }

    private func enqueueAttach(_ terminalId: String, front: Bool) {
        guard !attachQueue.contains(terminalId) else { return }
        if front {
            attachQueue.insert(terminalId, at: 0)
        } else {
            attachQueue.append(terminalId)
        }
        pumpAttachQueue()
    }

    private func pumpAttachQueue() {
        guard let channel, isActive || !attachQueue.isEmpty else { return }
        while attachesInFlight < Self.maxAttachesInFlight, !attachQueue.isEmpty {
            let terminalId = attachQueue.removeFirst()
            guard paneSessions[terminalId] != nil, attachIds[terminalId] == nil else { continue }
            attachesInFlight += 1
            Task { [weak self] in
                await self?.attach(terminalId: terminalId, on: channel)
                self?.attachesInFlight -= 1
                self?.pumpAttachQueue()
            }
        }
    }

    private func attach(terminalId: String, on channel: HerdrControlChannel) async {
        guard let session = paneSessions[terminalId], let view = paneViews[terminalId] else { return }
        TerminalBellSuppressor.suppressRebuild(view.uuid)
        let params = HerdrControl.AttachParams(
            target: terminalId,
            history_limit_bytes: SettingsStore.shared.value(Settings.Multiplexer.herdrControlHistoryLimitBytes),
            takeover: true
        )
        do {
            let attached = try await channel.request(
                "terminal.attach",
                params,
                as: HerdrControl.TerminalAttached.self
            )
            guard self.channel === channel, paneSessions[terminalId] === session else {
                _ = try? await channel.request("terminal.detach", HerdrControl.AttachTarget(attach_id: attached.attach_id))
                return
            }
            attachIds[terminalId] = attached.attach_id
            terminalByAttach[attached.attach_id] = terminalId
            session.attachId = attached.attach_id
            router.register(attachId: attached.attach_id, sink: session.outputSink)
        } catch {
            Self.logger.error("herdr attach \(terminalId) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Records

    func snapshotDidArrive(_ record: HerdrControl.SnapshotRecord) {
        snapshotRequestsInFlight.remove(record.attach_id)
        guard let terminalId = terminalByAttach[record.attach_id], let view = paneViews[terminalId] else { return }
        let state = record.snapshot.state
        if view.userOverrideTitle == nil, let title = state.title, !title.isEmpty, view.title != title {
            view.title = title
        }
        if let cwd = state.cwd, cwd.hasPrefix("/") {
            view.handlePwdChange(cwd)
        }
    }

    /// Asks for a fresh snapshot after the server reported dropped output.
    func requestSnapshot(attachId: String) {
        guard let channel, !snapshotRequestsInFlight.contains(attachId) else { return }
        snapshotRequestsInFlight.insert(attachId)
        if let terminalId = terminalByAttach[attachId], let view = paneViews[terminalId] {
            TerminalBellSuppressor.suppressRebuild(view.uuid)
        }
        Task { [weak self] in
            do {
                try await channel.request("terminal.snapshot", HerdrControl.AttachTarget(attach_id: attachId))
            } catch {
                self?.snapshotRequestsInFlight.remove(attachId)
            }
        }
    }

    func attachDidDetach(_ detached: HerdrControl.DetachedRecord) {
        guard let terminalId = terminalByAttach.removeValue(forKey: detached.attach_id) else { return }
        attachIds.removeValue(forKey: terminalId)
        router.unregister(attachId: detached.attach_id)
        paneSessions[terminalId]?.attachId = nil
        switch detached.reason {
        case "takeover":
            Self.logger.info("herdr pane \(terminalId) taken over by another client")
        default:
            // The terminal closed on the server; topology events retire it.
            break
        }
    }

    // MARK: - Geometry

    /// A pane surface reported its grid. The tab's geometry is derived from
    /// the container the panes share, so herdr lays the tab out to the space
    /// rootshell actually shows.
    func paneGridDidChange(_ session: HerdrPaneSession, rows: Int, cols: Int) {
        if mode == .legacy {
            // rootshell owns pane sizes here; the server has no tab geometry.
            legacyGridDidChange(session, rows: rows, cols: cols)
            return
        }
        guard let view = paneViews[session.terminalId], let tabID = view.containingTabID,
              let tab = tabs.values.first(where: { $0.id == tabID }), let tabId = tab.herdrTabId else { return }
        scheduleGeometryPush(tabId: tabId, tab: tab, from: view, rows: rows, cols: cols)
    }

    func pushGeometryForVisibleTabs() {
        for tab in tabs.values where tabsModel.selectedTabID == tab.id {
            guard let tabId = tab.herdrTabId, let view = tab.splitTree.terminalLeaves.first,
                  let size = view.surfaceSize else { continue }
            scheduleGeometryPush(tabId: tabId, tab: tab, from: view, rows: Int(size.rows), cols: Int(size.columns))
        }
    }

    private func scheduleGeometryPush(tabId: String, tab: TabModel, from view: Ghostty.TerminalView, rows: Int, cols: Int) {
        guard tabsModel.selectedTabID == tab.id, !Ghostty.isAppBackgroundedAtomic else { return }
        geometryTasks[tabId]?.cancel()
        geometryTasks[tabId] = Task { @MainActor [weak self, weak tab, weak view] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, let tab, let view, !Task.isCancelled else { return }
            self.geometryTasks.removeValue(forKey: tabId)
            guard let size = self.tabCells(for: tab, from: view, rows: rows, cols: cols) else { return }
            self.pushTabGeometry(tabId: tabId, cols: size.cols, rows: size.rows, cell: size.cell)
        }
    }

    /// Cells the whole tab covers: the pane's own grid when it is alone,
    /// otherwise the split host's bounds divided by the pane's cell size.
    private func tabCells(
        for tab: TabModel,
        from view: Ghostty.TerminalView,
        rows: Int,
        cols: Int
    ) -> (cols: Int, rows: Int, cell: (width: Int, height: Int))? {
        guard let surface = view.surfaceSize, surface.cell_width_px > 0, surface.cell_height_px > 0 else {
            return nil
        }
        let cell = (width: Int(surface.cell_width_px), height: Int(surface.cell_height_px))
        if tab.splitTree.terminalLeaves.count <= 1 {
            guard cols >= 4, rows >= 2 else { return nil }
            return (cols, rows, cell)
        }
        guard let host = view.enclosingSplitHost else { return nil }
        let scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : 1
        let cellW = CGFloat(surface.cell_width_px) / scale
        let cellH = CGFloat(surface.cell_height_px) / scale
        guard cellW > 0, cellH > 0 else { return nil }
        let padX = CGFloat(PaddingManager.shared.effectivePaddingX) * 2
        let padY = CGFloat(PaddingManager.shared.effectivePaddingY) * 2
        let width = max(0, host.bounds.width - padX)
        let height = max(0, host.bounds.height - padY)
        let tabCols = Int(width / cellW)
        let tabRows = Int(height / cellH)
        guard tabCols >= 4, tabRows >= 2 else { return nil }
        return (tabCols, tabRows, cell)
    }

    private func pushTabGeometry(tabId: String, cols: Int, rows: Int, cell: (width: Int, height: Int)) {
        guard let channel else { return }
        if let last = pushedGeometry[tabId], last.cols == cols, last.rows == rows { return }
        pushedGeometry[tabId] = (cols, rows)
        let params = HerdrControl.TabGeometryParams(
            tab_id: tabId,
            cols: cols,
            rows: rows,
            cell_width_px: cell.width,
            cell_height_px: cell.height
        )
        Task { [weak self] in
            do {
                try await channel.request("tab.set_geometry", params)
            } catch {
                self?.pushedGeometry.removeValue(forKey: tabId)
                Self.logger.warning("herdr tab.set_geometry \(tabId) failed: \(error.localizedDescription)")
            }
        }
    }

    /// The selected tab changed: size it and make sure its panes are attached.
    func selectedTabDidChange() {
        pushGeometryForVisibleTabs()
        queueAttaches(priorityTab: tabsModel.selectedTabID)
    }
}
