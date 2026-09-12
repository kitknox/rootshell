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
        guard !didEnd else { return }
        paneSessions[session.terminalId] = session
        if mode == .legacy {
            legacyReconcileAttaches()
            return
        }
        if let size = paneViews[session.terminalId]?.surfaceSize {
            paneGridDidChange(session, rows: Int(size.rows), cols: Int(size.columns))
        }
        if let existing = attachIds[session.terminalId] {
            session.attachId = existing
            paneViews[session.terminalId]?.beginHerdrTitleAttachment()
            updateRouterGrid(terminalId: session.terminalId)
            router.register(attachId: existing, sink: session.outputSink)
            return
        }
        enqueueAttach(session.terminalId, front: isVisible(terminalId: session.terminalId))
    }

    func paneSessionDidStop(_ session: HerdrPaneSession) {
        guard paneSessions[session.terminalId] === session else { return }
        paneViews[session.terminalId]?.endHerdrTitleAttachment()
        paneSessions.removeValue(forKey: session.terminalId)
        attachRetries.removeValue(forKey: session.terminalId)?.cancel()
        attachesInFlight.removeValue(forKey: session.terminalId)
        panesNeedingSnapshot.remove(session.terminalId)
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
        for terminalId in ordered where attachIds[terminalId] == nil && attachesInFlight[terminalId] == nil && !attachQueue.contains(terminalId) {
            attachQueue.append(terminalId)
        }
        // Selection can change while background work is already queued.
        attachQueue.sort { lhs, rhs in
            let lhsVisible = paneViews[lhs]?.containingTabID == priorityTab
            let rhsVisible = paneViews[rhs]?.containingTabID == priorityTab
            if lhsVisible != rhsVisible { return lhsVisible }
            return lhs < rhs
        }
        pumpAttachQueue()
    }

    private func enqueueAttach(_ terminalId: String, front: Bool) {
        guard attachesInFlight[terminalId] == nil, !attachQueue.contains(terminalId) else { return }
        if front {
            attachQueue.insert(terminalId, at: 0)
        } else {
            attachQueue.append(terminalId)
        }
        pumpAttachQueue()
    }

    private func pumpAttachQueue() {
        guard let channel, isActive, mode == .raw, !Ghostty.isAppBackgroundedAtomic else { return }
        attachQueue.removeAll { paneSessions[$0] == nil || attachIds[$0] != nil }
        while attachesInFlight.count < Self.maxAttachesInFlight,
              let index = attachQueue.firstIndex(where: { attachesInFlight[$0] == nil && paneGeometryIsReady($0) }) {
            let terminalId = attachQueue.remove(at: index)
            let attempt = UUID()
            attachesInFlight[terminalId] = attempt
            Task { [weak self] in
                await self?.attach(terminalId: terminalId, on: channel)
                guard let self, self.attachesInFlight[terminalId] == attempt else { return }
                self.attachesInFlight.removeValue(forKey: terminalId)
                self.pumpAttachQueue()
            }
        }
    }

    /// Do not replay a snapshot at the placeholder grid or the TUI geometry
    /// from session.snapshot. The raw layout and its native surface must agree.
    func paneGeometryIsReady(_ terminalId: String) -> Bool {
        guard let view = paneViews[terminalId], let binding = view.herdrPaneBinding,
              let geometry = tabGeometryStates[binding.tabId], geometry.isConfirmed,
              let measured = tabGeometry(from: view), geometry.desired == measured,
              let layout = controlLayouts[binding.tabId],
              layout.area.width == measured.cols, layout.area.height == measured.rows,
              let target = view.herdrTargetGrid, let size = view.surfaceSize,
              let parsed = paneSessions[terminalId]?.parserGrid else { return false }
        return Int(size.columns) == target.cols && Int(size.rows) == target.rows
            && parsed.cols == target.cols && parsed.rows == target.rows
    }

    private func updateRouterGrid(terminalId: String) {
        guard let attachId = attachIds[terminalId], let size = paneViews[terminalId]?.surfaceSize else { return }
        let parsed = paneSessions[terminalId]?.parserGrid
        let matches = parsed?.cols == Int(size.columns) && parsed?.rows == Int(size.rows)
        router.updateGrid(attachId: attachId, cols: matches ? Int(size.columns) : 0, rows: matches ? Int(size.rows) : 0)
    }

    private func attach(terminalId: String, on channel: HerdrControlChannel) async {
        guard self.channel === channel,
              let session = paneSessions[terminalId], let view = paneViews[terminalId] else { return }
        // The task may start after another layout or a background transition.
        guard paneGeometryIsReady(terminalId) else {
            if !attachQueue.contains(terminalId) { attachQueue.append(terminalId) }
            return
        }
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
            view.beginHerdrTitleAttachment()
            if let paneId = paneInfos.values.first(where: { $0.terminal_id == terminalId })?.pane_id {
                router.setPane(paneId, attachId: attached.attach_id)
            }
            updateRouterGrid(terminalId: terminalId)
            router.register(attachId: attached.attach_id, sink: session.outputSink)
            // The snapshot can beat the response continuation that registers
            // this attach. Check the queued snapshot's dimensions here too.
            if router.isWaitingForGrid(attachId: attached.attach_id) {
                panesNeedingSnapshot.insert(terminalId)
                requestSnapshotsForReadyPanes()
            }
        } catch {
            guard self.channel === channel, paneSessions[terminalId] === session else { return }
            Self.logger.error("herdr attach \(terminalId) failed: \(error.localizedDescription)")
            refreshTopology()
            attachRetries[terminalId]?.cancel()
            attachRetries[terminalId] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.channel === channel,
                      self.paneSessions[terminalId] === session else { return }
                self.attachRetries.removeValue(forKey: terminalId)
                self.enqueueAttach(terminalId, front: self.isVisible(terminalId: terminalId))
            }
        }
    }

    // MARK: - Records

    func snapshotDidArrive(_ record: HerdrControl.SnapshotRecord) {
        snapshotRequestDidFinish(attachId: record.attach_id)
        guard let terminalId = terminalByAttach[record.attach_id], let view = paneViews[terminalId] else { return }
        if router.isWaitingForGrid(attachId: record.attach_id) {
            panesNeedingSnapshot.insert(terminalId)
        } else {
            panesNeedingSnapshot.remove(terminalId)
        }
        let state = record.snapshot.state
        view.seedHerdrTitle(state.title)
        if let cwd = state.cwd, cwd.hasPrefix("/") {
            view.handlePwdChange(cwd)
        }
        requestSnapshotsForReadyPanes()
    }

    /// Asks for a fresh snapshot after the server reported dropped output.
    func requestSnapshot(attachId: String) {
        guard let channel, let terminalId = terminalByAttach[attachId] else { return }
        guard paneGeometryIsReady(terminalId) else {
            panesNeedingSnapshot.insert(terminalId)
            return
        }
        // A request while one is in flight is not lost: it re-runs when the
        // current snapshot lands (or fails), so a snapshot that arrived
        // already stale still gets its replacement.
        guard !snapshotRequestsInFlight.contains(attachId) else {
            snapshotRetryWanted.insert(attachId)
            return
        }
        snapshotRequestsInFlight.insert(attachId)
        if let terminalId = terminalByAttach[attachId], let view = paneViews[terminalId] {
            TerminalBellSuppressor.suppressRebuild(view.uuid)
        }
        Task { [weak self] in
            do {
                try await channel.request("terminal.snapshot", HerdrControl.AttachTarget(attach_id: attachId))
            } catch {
                guard let self, self.channel === channel else { return }
                self.snapshotRequestDidFinish(attachId: attachId)
            }
        }
    }

    private func snapshotRequestDidFinish(attachId: String) {
        snapshotRequestsInFlight.remove(attachId)
        if snapshotRetryWanted.remove(attachId) != nil, terminalByAttach[attachId] != nil {
            requestSnapshot(attachId: attachId)
        }
    }

    func attachDidDetach(_ detached: HerdrControl.DetachedRecord) {
        guard !didEnd else { return }
        // The response continuation may not have registered this attach yet.
        // Ownership loss ends this whole raw stream, regardless of pane lookup.
        if mode == .raw, detached.reason == "takeover" {
            detachAfterTakeover()
            return
        }
        guard let terminalId = terminalByAttach.removeValue(forKey: detached.attach_id) else { return }
        attachIds.removeValue(forKey: terminalId)
        router.unregister(attachId: detached.attach_id)
        paneViews[terminalId]?.endHerdrTitleAttachment()
        paneSessions[terminalId]?.attachId = nil
        snapshotRequestsInFlight.remove(detached.attach_id)
        snapshotRetryWanted.remove(detached.attach_id)
        switch detached.reason {
        case "closed":
            if let paneId = paneInfos.values.first(where: { $0.terminal_id == terminalId })?.pane_id {
                paneDidClose(paneId: paneId)
            } else {
                refreshTopology()
            }
        default:
            refreshTopology()
        }
    }

    // MARK: - Geometry

    /// A pane surface reported its grid. The tab's geometry is derived from
    /// the container the panes share, so herdr lays the tab out to the space
    /// rootshell actually shows.
    func paneGridDidChange(_ session: HerdrPaneSession, rows: Int, cols: Int) {
        if mode == .legacy {
            // The stock endpoint negotiates the selected tab's surface; old
            // attach-only servers still resize each pane independently.
            legacyGridDidChange(session, rows: rows, cols: cols)
            return
        }
        if session.parserGrid != TerminalGridReports.Grid(cols: cols, rows: rows) {
            if let attachId = attachIds[session.terminalId] {
                router.invalidate(attachId: attachId)
                panesNeedingSnapshot.insert(session.terminalId)
            }
            session.confirmParserGrid(cols: cols, rows: rows)
        }
        updateRouterGrid(terminalId: session.terminalId)
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
        guard let view = paneViews[session.terminalId] else { return }
        scheduleGeometryPush(from: view)
    }

    /// A surface-size callback is intent. This reply proves the parser has
    /// applied the resize, and is the only path that releases resized output.
    func paneParserGridDidChange(_ session: HerdrPaneSession, cols: Int, rows: Int) {
        if mode == .legacy, !endpointUnsupported {
            paneViews[session.terminalId]?.herdrEndpointPane?.commitPendingFrame()
            return
        }
        guard mode == .raw, paneSessions[session.terminalId] === session,
              let size = paneViews[session.terminalId]?.surfaceSize,
              Int(size.columns) == cols, Int(size.rows) == rows else { return }
        updateRouterGrid(terminalId: session.terminalId)
        noteGridForLayoutRelease(terminalId: session.terminalId, cols: cols, rows: rows)
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
    }

    /// The split host laid out (window resize, sidebar, font change): the
    /// tab's cell budget may have changed even though every pane is still
    /// clamped to the last server grid.
    func hostLayoutDidChange(for view: Ghostty.TerminalView) {
        if mode == .legacy, !endpointUnsupported { reconcileEndpoint(); return }
        guard mode == .raw else { return }
        scheduleGeometryPush(from: view)
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
    }

    func pushGeometryForHostedTabs() {
        if mode == .legacy, !endpointUnsupported { reconcileEndpoint(); return }
        for tab in tabs.values {
            guard let view = geometryView(in: tab) else { continue }
            scheduleGeometryPush(from: view)
        }
    }

    private func geometryView(in tab: TabModel) -> Ghostty.TerminalView? {
        tab.splitTree.terminalLeaves.first {
            $0.enclosingSplitHost?.hasLaidOutHerdrPane($0) == true
        }
    }

    private func scheduleGeometryPush(from view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding, let tab = tabs[binding.tabId],
              let channel, let size = tabGeometry(from: view) else { return }
        let tabId = binding.tabId
        tabGeometryStates[tabId, default: .init()].update(size)
        guard geometryTasks[tabId] == nil, tabGeometryStates[tabId]?.isConfirmed == false else { return }
        let generation = streamGeneration
        geometryTasks[tabId] = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if self.streamGeneration == generation, self.tabs[tabId] === tab {
                    self.geometryTasks.removeValue(forKey: tabId)
                }
            }
            var failures = 0
            while !Task.isCancelled, self.streamGeneration == generation,
                  self.channel === channel, self.tabs[tabId] === tab {
                // The first real host layout can start immediately. Later
                // changes debounce only distinct sizes, including while a
                // request is in flight; repeated layout callbacks cannot
                // postpone preparation indefinitely.
                let desired = self.tabGeometryStates[tabId]?.desired
                if self.tabGeometryStates[tabId]?.hasRequested == true {
                    do { try await Task.sleep(for: .milliseconds(60)) }
                    catch { return }
                    if self.tabGeometryStates[tabId]?.desired != desired { continue }
                }
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.channel === channel, self.tabs[tabId] === tab,
                      let view = self.geometryView(in: tab),
                      let current = self.tabGeometry(from: view) else { return }
                self.tabGeometryStates[tabId]?.update(current)
                if current != desired { continue }
                guard let request = self.tabGeometryStates[tabId]?.beginRequest() else { return }
                let size = request.size
                let params = HerdrControl.TabGeometryParams(
                    tab_id: tabId, cols: size.cols, rows: size.rows,
                    cell_width_px: size.cellWidth, cell_height_px: size.cellHeight
                )
                do {
                    try await channel.request("tab.set_geometry", params)
                    guard !Task.isCancelled, self.streamGeneration == generation,
                          self.channel === channel, self.tabs[tabId] === tab else { return }
                    self.tabGeometryStates[tabId]?.finish(request, succeeded: true)
                    failures = 0
                    self.pumpAttachQueue()
                    self.requestSnapshotsForReadyPanes()
                    if self.tabGeometryStates[tabId]?.isConfirmed == true { return }
                } catch {
                    guard !Task.isCancelled, self.streamGeneration == generation,
                          self.channel === channel, self.tabs[tabId] === tab else { return }
                    self.tabGeometryStates[tabId]?.finish(request, succeeded: false)
                    Self.logger.warning("herdr tab.set_geometry \(tabId) failed: \(error.localizedDescription)")
                    // A failed background preparation must not require a tab
                    // switch to retry, nor endlessly hammer a rejecting server.
                    failures += 1
                    guard failures < 3 else { return }
                    do { try await Task.sleep(for: .milliseconds(500)) }
                    catch { return }
                }
            }
        }
    }

    /// Cells the whole tab covers, from the split host's bounds less the
    /// padding and dividers the native layout spends (the same math the host
    /// uses to snap the split). Never from a pane's grid: panes are clamped
    /// to the last server layout, so their grids cannot report growth.
    private func tabGeometry(from view: Ghostty.TerminalView) -> HerdrTabGeometryState.Size? {
        guard mode == .raw, isActive, !didEnd,
              !view.suppressPTYSizeUpdates,
              !KeyboardTracker.shared.isKeyboardAnimating,
              !KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: view.window),
              let binding = view.herdrPaneBinding, binding.gatewayUUID == gatewayUUID,
              let tab = tabs[binding.tabId], tab.id == view.containingTabID,
              !tab.isHiddenTmuxWindow,
              let host = view.enclosingSplitHost, host.hasLaidOutHerdrPane(view),
              let geometry = host.herdrWindowGeometry(), geometry.cols >= 4, geometry.rows >= 2 else { return nil }
        #if STANDALONE && targetEnvironment(macCatalyst)
        if view.windowId == "visor", VisorController.shared.suppressesTerminalResizeForAnimation { return nil }
        #endif
        return geometry
    }

    // MARK: - Layout release

    /// Holds these panes' output until their surfaces report the layout's
    /// grid, or a short deadline passes (an unmounted pane cannot resize). Called
    /// after the split tree took the layout.
    func armLayoutRelease(for layout: HerdrControl.LayoutSnapshot, barrier: UInt64) {
        // An earlier layout for this tab still waiting was drawn for a grid
        // the panes never reach: discard its bytes and re-snapshot those
        // panes once this layout has landed.
        var snapshotOnComplete: Set<String> = []
        for (id, previous) in layoutReleases where previous.tabId == layout.tab_id {
            previous.deadline?.cancel()
            layoutReleases.removeValue(forKey: id)
            snapshotOnComplete.formUnion(previous.snapshotOnComplete)
            snapshotOnComplete.formUnion(router.discardSegment(barrier: id))
        }
        guard mode == .raw, tabs[layout.tab_id] != nil else {
            for pane in layout.panes {
                guard let terminalId = paneInfos[pane.pane_id]?.terminal_id,
                      let attachId = attachIds[terminalId] else { continue }
                let size = paneSessions[terminalId]?.parserGrid
                if size.map({ $0.cols != pane.rect.width || $0.rows != pane.rect.height }) ?? true {
                    router.invalidate(attachId: attachId)
                    panesNeedingSnapshot.insert(terminalId)
                }
            }
            router.release(barrier: barrier)
            for attachId in snapshotOnComplete { requestSnapshot(attachId: attachId) }
            return
        }
        var expected: [String: (cols: Int, rows: Int)] = [:]
        for pane in layout.panes {
            guard let terminalId = paneInfos[pane.pane_id]?.terminal_id,
                  let attachId = attachIds[terminalId] else { continue }
            let wanted = (cols: pane.rect.width, rows: pane.rect.height)
            if let size = paneSessions[terminalId]?.parserGrid,
               size.cols == wanted.cols, size.rows == wanted.rows {
                continue
            }
            // A zoomed-away or detached pane cannot acknowledge a native
            // resize. Recover it when hosted again without holding up the
            // other panes' redraw for the entire deadline.
            guard let view = paneViews[terminalId], view.window != nil,
                  !view.suppressPTYSizeUpdates,
                  !layout.zoomed || pane.pane_id == layout.focused_pane_id else {
                router.invalidate(attachId: attachId)
                panesNeedingSnapshot.insert(terminalId)
                continue
            }
            expected[terminalId] = wanted
        }
        guard !expected.isEmpty else {
            router.release(barrier: barrier)
            for attachId in snapshotOnComplete { requestSnapshot(attachId: attachId) }
            return
        }
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.completeLayoutRelease(barrier: barrier)
        }
        layoutReleases[barrier] = LayoutRelease(
            tabId: layout.tab_id,
            expected: expected,
            deadline: deadline,
            snapshotOnComplete: snapshotOnComplete
        )
    }

    private func completeLayoutRelease(barrier: UInt64) {
        guard let release = layoutReleases.removeValue(forKey: barrier) else { return }
        release.deadline?.cancel()
        // A deadline is recovery, not permission to feed a redraw to the
        // wrong grid. Unmounted or delayed surfaces re-snapshot when ready.
        for terminalId in release.expected.keys {
            if let attachId = attachIds[terminalId] {
                router.invalidate(attachId: attachId)
                panesNeedingSnapshot.insert(terminalId)
            }
        }
        router.release(barrier: barrier)
        // Panes whose earlier redraw was discarded rebuild at this grid; the
        // snapshot arrives behind the barrier just released.
        for attachId in release.snapshotOnComplete {
            requestSnapshot(attachId: attachId)
        }
    }

    private func noteGridForLayoutRelease(terminalId: String, cols: Int, rows: Int) {
        for (barrier, var release) in layoutReleases {
            guard let wanted = release.expected[terminalId] else { continue }
            guard wanted.cols == cols, wanted.rows == rows else { continue }
            release.expected.removeValue(forKey: terminalId)
            layoutReleases[barrier] = release
            if release.expected.isEmpty {
                completeLayoutRelease(barrier: barrier)
            }
        }
    }

    private func requestSnapshotsForReadyPanes() {
        for terminalId in panesNeedingSnapshot where paneGeometryIsReady(terminalId) {
            guard let attachId = attachIds[terminalId],
                  !snapshotRequestsInFlight.contains(attachId) else { continue }
            panesNeedingSnapshot.remove(terminalId)
            requestSnapshot(attachId: attachId)
        }
    }

    /// The selected tab changed: size it and make sure its panes are attached.
    func selectedTabDidChange() {
        if let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }) {
            showPanesIfSelected(in: tab)
        }
        pushGeometryForHostedTabs()
        queueAttaches(priorityTab: tabsModel.selectedTabID)
        requestSnapshotsForReadyPanes()
    }
}
