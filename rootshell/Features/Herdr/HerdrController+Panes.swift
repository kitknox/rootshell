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
        resizeRecoveries.removeValue(forKey: session.terminalId)
        clientDetourMinimums.removeValue(forKey: session.terminalId)
        legacyPaneDidStop(session)
        attachQueue.removeAll { $0 == session.terminalId }
        if let attachId = attachIds.removeValue(forKey: session.terminalId) {
            snapshotRequestsInFlight.removeValue(forKey: attachId)
            snapshotRetryWanted.remove(attachId)
            terminalByAttach.removeValue(forKey: attachId)
            attachAnswersQueries.removeValue(forKey: attachId)
            router.unregister(attachId: attachId)
            if let channel {
                Task { try? await channel.request("terminal.detach", HerdrControl.AttachTarget(attach_id: attachId)) }
            }
        }
    }

    func sendInput(from session: HerdrPaneSession, _ data: Data, automaticReply: Bool = false) {
        if mode == .legacy {
            legacyInput(session, data)
            return
        }
        guard let attachId = session.attachId, let channel else { return }
        // Typing is fresh intent: a pane the user scrolled away from earlier
        // may follow the handoff this keystroke earns.
        if !automaticReply { activation.renewAfterInput(session.terminalId) }
        // The session gates replies at the parser's authority boundary.
        // Still mark them automatic: the server's grace window admits an
        // outstanding reply from before the handoff without claiming input.
        let auto: Bool? = automaticReply && capabilities.supports(.autoInput) ? true : nil
        Task { await channel.sendInput(attachId: attachId, bytes: data, auto: auto) }
    }

    // MARK: - Attach queue

    func isVisible(terminalId: String) -> Bool {
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

    func enqueueAttach(_ terminalId: String, front: Bool) {
        guard attachesInFlight[terminalId] == nil, !attachQueue.contains(terminalId) else { return }
        if front {
            attachQueue.insert(terminalId, at: 0)
        } else {
            attachQueue.append(terminalId)
        }
        pumpAttachQueue()
    }

    func pumpAttachQueue() {
        guard let channel, isActive, mode == .raw, !Ghostty.isAppBackgroundedAtomic else { return }
        // Panes another client holds wait for Take Control, not for a retry.
        attachQueue.removeAll { paneSessions[$0] == nil || attachIds[$0] != nil || paneControlStates[$0] != nil }
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
    func paneGeometryIsReady(_ terminalId: String, requireConfirmed: Bool = true) -> Bool {
        guard let view = paneViews[terminalId], let binding = view.herdrPaneBinding,
              let target = view.herdrTargetGrid, let size = view.surfaceSize,
              let parsed = paneSessions[terminalId]?.parserGrid else { return false }
        let surfaceMatches = Int(size.columns) == target.cols && Int(size.rows) == target.rows
            && parsed.cols == target.cols && parsed.rows == target.rows
        guard let geometry = tabGeometryStates[binding.tabId], let layout = controlLayouts[binding.tabId] else { return false }
        if geometry.isOwnedElsewhere {
            // Another client sized the tab: our surfaces follow its layout,
            // whatever our container measures.
            return surfaceMatches && layout.panes.contains { $0.pane_id == view.herdrPaneBinding?.paneId
                && $0.terminalCols == target.cols && $0.terminalRows == target.rows }
        }
        guard geometry.isConfirmed || !requireConfirmed,
              let measured = tabGeometry(from: view), geometry.desired == measured,
              layout.area.width == measured.cols, layout.area.height == measured.rows,
              measured.panes.allSatisfy({ id, size in layout.panes.contains { $0.pane_id == id && $0.terminal_size == size } }) else { return false }
        return surfaceMatches
    }

    /// A live pane already at the server's layout can show its cached screen
    /// while a re-selection claim is still in flight, as a tmux pane does.
    func paneCanRevealCachedFrame(_ terminalId: String) -> Bool {
        if paneGeometryIsReady(terminalId) { return true }
        return attachIds[terminalId] != nil
            && !panesNeedingSnapshot.contains(terminalId)
            && !layoutReleases.values.contains { $0.expected[terminalId] != nil }
            && paneGeometryIsReady(terminalId, requireConfirmed: false)
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
        // Never evict another client on our own; only a user's Take Control does.
        let tabId = view.herdrPaneBinding?.tabId
        let params = HerdrControl.AttachParams(
            target: terminalId,
            history_limit_bytes: SettingsStore.shared.value(Settings.Multiplexer.herdrControlHistoryLimitBytes),
            takeover: tabId.map { takeoverRequested.contains($0) } ?? false
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
            paneDidAttach(terminalId: terminalId, tabId: tabId)
            reconcileReturnToLive()
        } catch {
            guard self.channel === channel, paneSessions[terminalId] === session else { return }
            Self.logger.error("herdr attach \(terminalId) failed: \(error.localizedDescription)")
            if case HerdrChannelError.remote(let code, _) = error, code == "terminal_attached" {
                paneHeldByOther(terminalId: terminalId, tabId: tabId)
                return
            }
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
        let requestID = snapshotRequestsInFlight.removeValue(forKey: record.attach_id)
        let retry = snapshotRetryWanted.remove(record.attach_id) != nil
        if let terminalID = terminalByAttach[record.attach_id],
           let recovery = resizeRecoveries[terminalID] {
            let grid = TerminalGridReports.Grid(cols: record.snapshot.state.cols, rows: record.snapshot.state.rows)
            guard recovery.acceptsSnapshot(requestID: requestID, grid: grid),
                  paneGeometryIsReady(terminalID), resizeRecoveryIsReady(terminalID) else {
                // An older request can have the same dimensions after A -> B
                // -> A. It must drain before a replacement request is issued.
                invalidateResizeOutput(terminalID: terminalID, cols: recovery.grid.cols, rows: recovery.grid.rows)
                requestSnapshotsForReadyPanes()
                return
            }
            resizeRecoveries.removeValue(forKey: terminalID)
            Self.logger.debug("herdr resize snapshot accepted \(terminalID) grid=\(grid.cols)x\(grid.rows)")
        }
        // Admission and replay share the main actor. The channel awaits this
        // callback before routing subsequent output. Initial snapshots can
        // precede terminalByAttach registration and still queue in the router.
        router.applySnapshot(record)
        guard let terminalId = terminalByAttach[record.attach_id], let view = paneViews[terminalId] else { return }
        if retry || router.isWaitingForGrid(attachId: record.attach_id) {
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

    /// Do not request a repair until the committed layout has crossed the
    /// parser. The renderer can already report the new size before that.
    private func resizeRecoveryIsReady(_ terminalID: String) -> Bool {
        guard let recovery = resizeRecoveries[terminalID] else { return true }
        guard let view = paneViews[terminalID], let target = view.herdrTargetGrid,
              target.cols == recovery.grid.cols, target.rows == recovery.grid.rows,
              !view.suppressPTYSizeUpdates, !Ghostty.isAppBackgroundedAtomic,
              let tabID = view.herdrPaneBinding?.tabId,
              !layoutReleases.values.contains(where: { $0.tabId == tabID }) else { return false }
        return true
    }

    /// Asks for a fresh snapshot after the server reported dropped output.
    func requestSnapshot(attachId: String) {
        guard let channel, let terminalId = terminalByAttach[attachId] else { return }
        guard paneGeometryIsReady(terminalId), resizeRecoveryIsReady(terminalId) else {
            panesNeedingSnapshot.insert(terminalId)
            return
        }
        // A request while one is in flight is not lost: it re-runs when the
        // current snapshot lands (or fails), so a snapshot that arrived
        // already stale still gets its replacement.
        guard snapshotRequestsInFlight[attachId] == nil else {
            snapshotRetryWanted.insert(attachId)
            return
        }
        let requestID = UUID()
        snapshotRequestsInFlight[attachId] = requestID
        resizeRecoveries[terminalId]?.requestedSnapshot(requestID)
        if resizeRecoveries[terminalId] != nil {
            Self.logger.info("herdr resize repair snapshot \(terminalId) request=\(requestID.uuidString)")
        }
        if let view = paneViews[terminalId] {
            TerminalBellSuppressor.suppressRebuild(view.uuid)
        }
        Task { [weak self] in
            guard let self, self.channel === channel,
                  self.snapshotRequestsInFlight[attachId] == requestID else { return }
            do {
                try await channel.request("terminal.snapshot", HerdrControl.AttachTarget(attach_id: attachId))
                // The RPC acknowledgement alone does not rebuild the pane.
                // Arm every request, even if recovery has not started yet:
                // a later resize repair must not wait forever on it.
                if try await HerdrSnapshotRecordDeadline.waitForExpiry(
                    requestID: requestID,
                    pendingRequest: {
                        self.channel === channel ? self.snapshotRequestsInFlight[attachId] : nil
                    }
                ) {
                    // A late pushed record has no request ID. Retire the
                    // stream so it cannot satisfy a replacement request.
                    await self.streamDidFail(channel, error: HerdrChannelError.timedOut(method: "terminal.snapshot record"))
                }
            } catch {
                guard self.channel === channel,
                      self.snapshotRequestsInFlight[attachId] == requestID else { return }
                self.snapshotRequestsInFlight.removeValue(forKey: attachId)
                let timedOut: Bool
                if case HerdrChannelError.timedOut = error { timedOut = true }
                else { timedOut = false }
                if timedOut || self.resizeRecoveries[terminalId] != nil {
                    // A timed-out request may still produce a pushed snapshot
                    // without a request ID. Reconnect instead of mistaking it
                    // for a later repair, or leaving this pane gated forever.
                    await self.streamDidFail(channel, error: error)
                } else if self.snapshotRetryWanted.remove(attachId) != nil {
                    self.requestSnapshot(attachId: attachId)
                }
            }
        }
    }

    func attachDidDetach(_ detached: HerdrControl.DetachedRecord) {
        guard !didEnd else { return }
        guard let terminalId = terminalByAttach.removeValue(forKey: detached.attach_id) else { return }
        attachIds.removeValue(forKey: terminalId)
        attachAnswersQueries.removeValue(forKey: detached.attach_id)
        router.unregister(attachId: detached.attach_id)
        paneViews[terminalId]?.endHerdrTitleAttachment()
        paneSessions[terminalId]?.attachId = nil
        snapshotRequestsInFlight.removeValue(forKey: detached.attach_id)
        resizeRecoveries.removeValue(forKey: terminalId)
        snapshotRetryWanted.remove(detached.attach_id)
        switch detached.reason {
        case "closed":
            if let paneId = paneInfos.values.first(where: { $0.terminal_id == terminalId })?.pane_id {
                paneDidClose(paneId: paneId)
            } else {
                refreshTopology()
            }
        case "takeover":
            // Per pane: the surface keeps its last screen and waits for the
            // user. No re-attach, or two clients would evict each other forever.
            paneTakenOver(terminalId: terminalId)
        default:
            refreshTopology()
        }
    }

    // MARK: - Geometry

    /// An unacknowledged resize can overtake output in Ghostty's input pipe.
    /// Discard subsequent increments and rebuild from the server after its
    /// new grid is parser-confirmed; SIGWINCH does not guarantee a full redraw.
    func invalidateResizeOutput(terminalID: String, cols: Int, rows: Int) {
        guard mode == .raw, capabilities.supportsSharedViewing,
              let attachID = attachIds[terminalID] else { return }
        resizeRecoveries[terminalID] = HerdrResizeRecovery(grid: .init(cols: cols, rows: rows))
        paneSessions[terminalID]?.readFence = nil
        router.invalidate(attachId: attachID)
        panesNeedingSnapshot.insert(terminalID)
        Self.logger.debug("herdr resize repair pending \(terminalID) grid=\(cols)x\(rows)")
    }

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
        if let target = paneViews[session.terminalId]?.herdrTargetGrid,
           cols != target.cols || rows != target.rows {
            if capabilities.supportsSharedViewing {
                invalidateResizeOutput(terminalID: session.terminalId, cols: target.cols, rows: target.rows)
            } else {
                let low = clientDetourMinimums[session.terminalId] ?? target
                clientDetourMinimums[session.terminalId] = (min(low.cols, cols), min(low.rows, rows))
            }
        }
        // Raw v2 output cannot run on a client-only grid. Recovery above
        // keeps it gated until a fresh snapshot agrees with the parser.
        let awaitingLayout = layoutReleases.values.contains { $0.expected[session.terminalId] != nil }
        if !awaitingLayout, session.parserGrid != TerminalGridReports.Grid(cols: cols, rows: rows) {
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
        if let target = paneViews[session.terminalId]?.herdrTargetGrid, target.cols == cols, target.rows == rows {
            settleClientDetour(terminalId: session.terminalId, cols: cols, rows: rows)
        }
        updateRouterGrid(terminalId: session.terminalId)
        noteGridForLayoutRelease(terminalId: session.terminalId, cols: cols, rows: rows)
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
    }

    /// The surface settled on the server's grid. Rows it discarded below
    /// that grid on the way were never lost server-side, and a program
    /// showing static content will not redraw them: rebuild from herdr.
    private func settleClientDetour(terminalId: String, cols: Int, rows: Int) {
        guard let low = clientDetourMinimums.removeValue(forKey: terminalId) else { return }
        guard low.cols < cols || low.rows < rows else { return }
        panesNeedingSnapshot.insert(terminalId)
    }

    /// The split host laid out (window resize, sidebar, font change): the
    /// tab's cell budget may have changed even though every pane is still
    /// clamped to the last server grid.
    func hostLayoutDidChange(for view: Ghostty.TerminalView) {
        if mode == .legacy, !endpointUnsupported { reconcileEndpoint(); return }
        guard mode == .raw else { return }
        reconcileActivation()
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

    func geometryView(in tab: TabModel) -> Ghostty.TerminalView? {
        tab.splitTree.terminalLeaves.first {
            $0.enclosingSplitHost?.hasLaidOutHerdrPane($0) == true
        }
    }

    /// Whether this tab may be sized from here right now. A device sizes only
    /// the tab it is showing, so it never fights the owner over the rest; a Mac
    /// measures them all, except on a server with no stored size, where every
    /// push would take the tab. `claiming` is the user naming this tab
    /// explicitly (Take Control), which reaches tabs shown here or not.
    func maySizeTab(_ tab: TabModel, claiming: Bool = false) -> Bool {
        #if targetEnvironment(macCatalyst)
        if capabilities.supportsSharedViewing { return true }
        #endif
        return hasProcessedInitialFocus && windowIsActive
            && (claiming || tab.id == tabsModel.selectedTabID)
    }

    func scheduleGeometryPush(from view: Ghostty.TerminalView) {
        reconcileActivation()
        guard let binding = view.herdrPaneBinding, let tab = tabs[binding.tabId],
              let channel, let size = tabGeometry(from: view) else { return }
        let tabId = binding.tabId
        guard maySizeTab(tab, claiming: tabGeometryStates[tabId]?.hasPendingClaim == true) else { return }
        tabGeometryStates[tabId, default: .init()].update(size)
        // The first size after a keyboard change is that change's final size
        // and skips the settle tick. Any other size in the window (a live
        // drag) keeps the debounce.
        let keyboardGeneration = KeyboardTracker.shared.keyboardGeometryGeneration
        if KeyboardTracker.shared.keyboardGeometryChangedRecently,
           keyboardSettledGenerations[tabId] != keyboardGeneration {
            keyboardSettledGenerations[tabId] = keyboardGeneration
            keyboardSettledGeometry[tabId] = size
        } else if keyboardSettledGeometry[tabId] != size {
            keyboardSettledGeometry[tabId] = nil
        }
        guard geometryTasks[tabId] == nil else { return }
        // No push follows: the marker must not outlive the size it describes.
        guard tabGeometryStates[tabId]?.isConfirmed == false || claimGeneration(for: tabId) != nil else {
            keyboardSettledGeometry[tabId] = nil
            return
        }
        // A protocol 1 server always claims; only send its size when we may.
        guard capabilities.supportsSharedViewing || tabGeometryStates[tabId]?.mayClaim != false else {
            keyboardSettledGeometry[tabId] = nil
            return
        }
        let generation = streamGeneration
        geometryTasks[tabId] = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if self.streamGeneration == generation, self.tabs[tabId] === tab {
                    self.geometryTasks.removeValue(forKey: tabId)
                }
                self.keyboardSettledGeometry[tabId] = nil
            }
            var failures = 0
            var movingSince: ContinuousClock.Instant?
            while !Task.isCancelled, self.streamGeneration == generation,
                  self.channel === channel, self.tabs[tabId] === tab {
                // The first real host layout can start immediately. Later
                // changes wait for the size to hold still for one tick, but
                // a live drag still sends every 200 ms so the pane never lags
                // far behind the window; each round trip resizes the server
                // model under every pane's lock. A selection's claim skips
                // the settle: it rarely changes the size.
                let desired = self.tabGeometryStates[tabId]?.desired
                var overdue = false
                let settled = desired != nil && self.keyboardSettledGeometry[tabId] == desired
                self.keyboardSettledGeometry[tabId] = nil
                if !settled, self.tabGeometryStates[tabId]?.hasRequested == true,
                   self.claimGeneration(for: tabId) == nil {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    if self.tabGeometryStates[tabId]?.desired != desired {
                        let since = movingSince ?? .now
                        movingSince = since
                        overdue = since.duration(to: .now) >= .milliseconds(200)
                        if !overdue { continue }
                    }
                }
                movingSince = nil
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.channel === channel, self.tabs[tabId] === tab,
                      let view = self.geometryView(in: tab),
                      let current = self.tabGeometry(from: view) else { return }
                self.tabGeometryStates[tabId]?.update(current)
                if current != desired, !overdue { continue }
                // The window may have gone quiet while this waited for the
                // size to settle; the request must still be ours to make.
                // Re-read the claim: another push may have consumed it while
                // this awaited, and only a live claim reaches an unshown tab.
                guard self.maySizeTab(
                    tab, claiming: self.tabGeometryStates[tabId]?.hasPendingClaim == true
                ) else { return }
                let claim = self.claimGeneration(for: tabId)
                guard let request = self.tabGeometryStates[tabId]?.beginRequest(claim: claim != nil) else { return }
                let size = request.size
                // While another client owns the tab this only stores our size,
                // so the server can apply it the moment we interact.
                let claims = request.claim
                // Consume intent when sent. Retrying after an ambiguous
                // response must not take the tab back from a newer owner.
                if let claim { self.activation.claimed(generation: claim) }
                var params = HerdrControl.TabGeometryParams(
                    tab_id: tabId, cols: size.cols, rows: size.rows,
                    cell_width_px: size.cellWidth, cell_height_px: size.cellHeight
                )
                if self.capabilities.supportsSharedViewing { params.claim = claims }
                Self.logger.info("herdr tab.set_geometry \(tabId) \(size.cols)x\(size.rows) claim=\(claims)")
                do {
                    if self.capabilities.supports(.paneGeometry), !size.panes.isEmpty {
                        try await channel.request("tab.set_pane_geometry",
                            HerdrControl.TabPaneGeometryParams(geometry: params, panes: size.panes))
                    } else {
                        try await channel.request("tab.set_geometry", params)
                    }
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
              !KeyboardTracker.shared.isHoldingResizesForKeyboard,
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
                if size.map({ $0.cols != pane.terminalCols || $0.rows != pane.terminalRows }) ?? true {
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
            guard let terminalId = paneInfos[pane.pane_id]?.terminal_id else { continue }
            let wanted = (cols: pane.terminalCols, rows: pane.terminalRows)
            // A zoomed-away or detached pane cannot acknowledge a native
            // resize. Recover it when hosted again without holding up the
            // other panes' redraw for the entire deadline.
            guard let view = paneViews[terminalId], view.window != nil,
                  !view.suppressPTYSizeUpdates,
                  !layout.zoomed || pane.pane_id == layout.focused_pane_id else {
                clientDetourMinimums.removeValue(forKey: terminalId)
                if let attachId = attachIds[terminalId] {
                    router.invalidate(attachId: attachId)
                    panesNeedingSnapshot.insert(terminalId)
                }
                continue
            }
            // Initial attach itself waits for parser confirmation. Include
            // mounted panes before they have an attach ID, or cold restore
            // waits for an attach that can never become ready.
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

    /// Called after this layout's forced surface-size updates have crossed
    /// the Ghostty API queue. An older layout's completion cannot release a
    /// replacement layout, including A -> B -> A with identical dimensions.
    func confirmLayoutParserGrids(barrier: UInt64) {
        guard let release = layoutReleases[barrier] else { return }
        for (terminalId, wanted) in release.expected {
            paneSessions[terminalId]?.confirmParserGrid(cols: wanted.cols, rows: wanted.rows)
        }
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
            if let wanted = release.expected[terminalId] {
                paneSessions[terminalId]?.confirmParserGrid(cols: wanted.cols, rows: wanted.rows)
            }
        }
        router.release(barrier: barrier)
        // Panes whose earlier redraw was discarded rebuild at this grid; the
        // snapshot arrives behind the barrier just released.
        for attachId in release.snapshotOnComplete {
            requestSnapshot(attachId: attachId)
        }
        requestSnapshotsForReadyPanes()
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

    func requestSnapshotsForReadyPanes() {
        defer { reconcileReturnToLive() }
        for terminalId in panesNeedingSnapshot where paneGeometryIsReady(terminalId) {
            guard let attachId = attachIds[terminalId],
                  snapshotRequestsInFlight[attachId] == nil,
                  resizeRecoveryIsReady(terminalId) else { continue }
            panesNeedingSnapshot.remove(terminalId)
            requestSnapshot(attachId: attachId)
        }
    }

    /// The selected tab changed: size it and make sure its panes are attached.
    func selectedTabDidChange() {
        reconcileActivation()
        if let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }) {
            showPanesIfSelected(in: tab)
        }
        pushGeometryForHostedTabs()
        queueAttaches(priorityTab: tabsModel.selectedTabID)
        requestSnapshotsForReadyPanes()
    }
}
