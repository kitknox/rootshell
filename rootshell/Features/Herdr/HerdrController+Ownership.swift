//
//  HerdrController+Ownership.swift
//  rootshell
//
//  Several clients on one session. Protocol 2 servers share terminals and
//  track one geometry owner per tab; older forks hold one owner per pane,
//  which surfaces here as paused panes with a Take Control action. Nothing
//  in this file evicts another client without the user asking.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import UIKit

extension Notification.Name {
    /// userInfo: "request" (MainAlertController.HerdrTakeControlRequest), "windowId" (String).
    static let herdrTakeControlRequested = Notification.Name("herdrTakeControlRequested")
}

/// Why a pane has no live attach of ours.
enum HerdrPaneControlState: Equatable {
    /// `terminal.attach` was refused: a single-owner server, someone else attached.
    case heldByOther
    /// Our attach was evicted by another client's takeover.
    case takenOver
}

extension HerdrController {

    // MARK: - Activation

    /// This controller's tab is the focused one in the focused window. On
    /// Catalyst the app is rarely `.background`, so the scene's activation
    /// state and key window are what separate "frontmost" from "just open".
    var windowIsActive: Bool {
        guard !Ghostty.isAppBackgroundedAtomic,
              let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }),
              let window = tab.focusedTerminal?.window ?? tab.splitTree.terminalLeaves.first?.window else { return false }
        return window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
    }

    func suspendActivation() {
        activation.suspend()
        for session in paneSessions.values { session.readFence = nil }
    }

    /// Called from selection and layout readiness, but only selection or a
    /// foreground/reconnect edge creates intent. Remote layouts cannot renew it.
    func reconcileActivation() {
        guard !didEnd, mode == .raw, isActive, hasProcessedInitialFocus, capabilities.supportsSharedViewing else { return }
        guard let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }) else {
            activation.select(nil, panes: [])
            return
        }
        guard windowIsActive, let tabID = tab.herdrTabId else { return }
        activationScene = (tab.focusedTerminal?.window ?? tab.splitTree.terminalLeaves.first?.window)?.windowScene
        let visibleTree = SplitTree<SplitPaneView>(root: tab.splitTree.zoomed ?? tab.splitTree.root, zoomed: nil)
        let visiblePanes = visibleTree.terminalLeaves.filter { $0.isHerdrPane }
        let terminalIDs = Set(visiblePanes.compactMap { $0.herdrPaneBinding?.terminalId })
        guard !terminalIDs.isEmpty else { return }
        guard activation.select(tabID, panes: terminalIDs) else { return }
        for session in paneSessions.values { session.readFence = nil }
        // Even a previously confirmed size must carry this new claim.
        tabGeometryStates[tabID, default: .init()].invalidate()
        for view in visiblePanes {
            view.prepareHerdrReturnToLive()
        }
    }

    /// The tab is ours again, so the resize and replay that follow should end
    /// at the live bottom. Claims nothing: we already have the tab.
    func expectReturnToLive(tabId: String) {
        guard !didEnd, mode == .raw, isActive, capabilities.supportsSharedViewing, windowIsActive,
              let tab = tabs[tabId], tab.id == tabsModel.selectedTabID else { return }
        let visibleTree = SplitTree<SplitPaneView>(root: tab.splitTree.zoomed ?? tab.splitTree.root, zoomed: nil)
        let visiblePanes = visibleTree.terminalLeaves.filter { $0.isHerdrPane }
        let terminalIDs = Set(visiblePanes.compactMap { $0.herdrPaneBinding?.terminalId })
        guard !terminalIDs.isEmpty else { return }
        activation.expectReturnToLive(tabID: tabId, panes: terminalIDs)
        for view in visiblePanes where !view.isActivelySelecting {
            guard let terminalID = view.herdrPaneBinding?.terminalId,
                  activation.pendingPanes.contains(terminalID) else { continue }
            view.prepareHerdrReturnToLive()
        }
    }

    func claimGeneration(for tabID: String) -> UUID? {
        guard windowIsActive, activation.tabID == tabID, activation.needsClaim else { return nil }
        return activation.generation
    }

    func cancelReturnToLive(terminalID: String) {
        activation.cancelPane(terminalID)
        paneSessions[terminalID]?.readFence = nil
    }

    /// This pane owes the activation a jump back to live output.
    func isReturningToLive(terminalID: String) -> Bool {
        activation.pendingPanes.contains(terminalID)
    }

    /// Queue the acknowledgement after replay and all output already received.
    /// A snapshot replacement changes the revision and invalidates old replies.
    func reconcileReturnToLive() {
        guard !didEnd, isActive, capabilities.supportsSharedViewing, windowIsActive,
              !activation.needsClaim, let tabID = activation.tabID,
              tabs[tabID]?.id == tabsModel.selectedTabID,
              !layoutReleases.values.contains(where: { $0.tabId == tabID }) else { return }
        for terminalID in activation.pendingPanes {
            guard let session = paneSessions[terminalID], let attachID = session.attachId,
                  paneGeometryIsReady(terminalID), !panesNeedingSnapshot.contains(terminalID),
                  snapshotRequestsInFlight[attachID] == nil,
                  let revision = router.snapshotRevision(attachId: attachID) else { continue }
            if session.readFence?.snapshot == revision { continue }
            session.requestReadFence(generation: activation.generation, snapshot: revision)
        }
    }

    func parserDidDrain(_ session: HerdrPaneSession, fence: HerdrPaneSession.ReadFence) {
        guard !didEnd, windowIsActive, !activation.needsClaim,
              paneSessions[session.terminalId] === session,
              activation.generation == fence.generation,
              activation.pendingPanes.contains(session.terminalId),
              isVisible(terminalId: session.terminalId), let attachID = session.attachId,
              router.snapshotRevision(attachId: attachID) == fence.snapshot,
              paneGeometryIsReady(session.terminalId),
              !panesNeedingSnapshot.contains(session.terminalId),
              snapshotRequestsInFlight[attachID] == nil,
              !layoutReleases.values.contains(where: { $0.tabId == activation.tabID }),
              let view = paneViews[session.terminalId],
              let tabID = activation.tabID, let tab = tabs[tabID],
              (tab.splitTree.zoomed ?? tab.splitTree.root)?.node(view: view) != nil else { return }
        activation.finishPane(session.terminalId)
        guard !view.isActivelySelecting else { return }
        view.finishHerdrReturnToLive()
    }

    // MARK: - Geometry ownership (protocol 2)

    func ownership(of tabId: String) -> HerdrTabGeometryState.Ownership {
        tabGeometryStates[tabId]?.ownership ?? .unknown
    }

    func tabIsControlledElsewhere(_ tab: TabModel) -> Bool {
        guard let tabId = tab.herdrTabId else { return false }
        if tabGeometryStates[tabId]?.isOwnedElsewhere == true { return true }
        return paneInfos.values.contains { $0.tab_id == tabId && paneControlStates[$0.terminal_id] != nil }
    }

    /// Records who sizes `tabId` from a layout or event. `carried` is false
    /// for layouts without the field (protocol 1), which say nothing.
    func applyGeometryController(_ controller: HerdrControl.GeometryController?, tabId: String, carried: Bool) {
        guard carried, mode == .raw, tabs[tabId] != nil else { return }
        let ownership: HerdrTabGeometryState.Ownership
        switch controller?.kind {
        case nil, "none":
            ownership = .none
        case "control" where controller?.connection_id == controlOpened?.connection_id:
            ownership = .mine
        default:
            ownership = .other(connectionId: controller?.connection_id, kind: controller?.kind)
        }
        guard tabGeometryStates[tabId, default: .init()].setOwnership(ownership) else { return }
        Self.logger.info("herdr tab \(tabId) geometry owner -> \(String(describing: ownership))")
        if ownership == .mine { expectReturnToLive(tabId: tabId) }
        // A hand-off to us applied our stored size already; do not re-send it.
        if ownership == .mine, let layout = controlLayouts[tabId],
           let desired = tabGeometryStates[tabId]?.desired,
           layout.area.width == desired.cols, layout.area.height == desired.rows,
           desired.panes.allSatisfy({ id, size in layout.panes.contains { $0.pane_id == id && $0.terminal_size == size } }) {
            tabGeometryStates[tabId]?.noteServerApplied(desired)
            if let claim = claimGeneration(for: tabId) {
                activation.claimed(generation: claim)
            }
        }
        syncControlledElsewhereBadge(tabId: tabId)
        for view in paneViews.values where view.herdrPaneBinding?.tabId == tabId {
            view.enclosingSplitHost?.setNeedsLayout()
        }
        if let tab = tabs[tabId], let view = tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
            scheduleGeometryPush(from: view)
        }
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
        publishSessionState()
    }

    func geometryControllerDidChange(_ change: HerdrControl.TabGeometryChangedData) {
        applyGeometryController(change.geometry_controller, tabId: change.tab_id, carried: true)
        refreshOtherConnections()
    }

    /// Cells the tab really has when another client sized it smaller or
    /// larger than our container; nil when we own it or nothing is known.
    func foreignAreaCells(for view: Ghostty.TerminalView) -> (cols: Int, rows: Int)? {
        guard let tabId = view.herdrPaneBinding?.tabId else { return nil }
        if mode == .legacy {
            // The endpoint frame's grid is the surface we asked for unless
            // another client resized it; then the tree's extent is the tab.
            guard tabId == endpointTabID, let layout = endpointLayouts[tabId], let asked = endpointSize,
                  layout.area.width != asked.cols || layout.area.height != asked.rows,
                  let tree = HerdrLayoutTree.build(layout) else { return nil }
            return (tree.extent(horizontal: true), tree.extent(horizontal: false))
        }
        guard tabGeometryStates[tabId]?.isOwnedElsewhere == true, let layout = controlLayouts[tabId] else { return nil }
        return (layout.area.width, layout.area.height)
    }

    /// "This client", the other client's label, or "None".
    func geometryOwnerDescription(_ tabId: String) -> String? {
        switch ownership(of: tabId) {
        case .unknown: return nil
        case .none: return String(localized: "None")
        case .mine: return String(localized: "This client")
        case .other(let id, let kind):
            if let id, let other = otherConnections.first(where: { $0.connection_id == id }) {
                return other.displayLabel
            }
            if kind == "client" { return String(localized: "herdr client") }
            return id.map { String(localized: "Connection #\($0)") } ?? String(localized: "Another client")
        }
    }

    // MARK: - Claims

    /// Explicit user intent to size the tab to this window: divider drag,
    /// Fit to This Window, or Take Control on a sharing server.
    func claimGeometry(tabId: String) {
        guard mode == .raw, channel != nil, capabilities.supportsSharedViewing, tabs[tabId] != nil else { return }
        // Send the measured size and the user's claim together, once. A
        // separate claim RPC plus a claiming resize can undo another client's
        // intervening handoff. Ownership changes only on the server's event.
        tabGeometryStates[tabId, default: .init()].requestClaim()
        Self.logger.info("herdr claim geometry \(tabId)")
        // Only a hosted leaf can be measured: in a zoomed tab the first herdr
        // leaf may not be the one the split host has attached.
        if let tab = tabs[tabId],
           let view = geometryView(in: tab)
            ?? tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
            scheduleGeometryPush(from: view)
        }
    }

    func requestFitToWindow(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        claimGeometry(tabId: tabId)
    }

    /// The user dragged a divider in a tab someone else sizes: they want it
    /// laid out here, so take the tab before the resize lands.
    func noteDividerDrag(in view: Ghostty.TerminalView) {
        guard let tabId = view.herdrPaneBinding?.tabId,
              tabGeometryStates[tabId]?.isOwnedElsewhere == true else { return }
        claimGeometry(tabId: tabId)
    }

    // MARK: - Single-owner servers

    func paneHeldByOther(terminalId: String, tabId: String?) {
        guard !didEnd else { return }
        paneControlStates[terminalId] = .heldByOther
        paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        guard let tabId else { return }
        syncControlledElsewhereBadge(tabId: tabId)
        presentTakeControlPrompt(tabId: tabId)
    }

    func paneTakenOver(terminalId: String) {
        guard !didEnd else { return }
        paneControlStates[terminalId] = .takenOver
        paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        if let tabId = paneViews[terminalId]?.herdrPaneBinding?.tabId {
            takeoverRequested.remove(tabId)
            syncControlledElsewhereBadge(tabId: tabId)
        }
        refreshOtherConnections()
        publishSessionState()
    }

    func paneDidAttach(terminalId: String, tabId: String?) {
        if paneControlStates.removeValue(forKey: terminalId) != nil {
            paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        }
        guard let tabId else { return }
        let stillWaiting = paneInfos.values.contains {
            $0.tab_id == tabId && attachIds[$0.terminal_id] == nil && paneSessions[$0.terminal_id] != nil
        }
        if !stillWaiting { takeoverRequested.remove(tabId) }
        syncControlledElsewhereBadge(tabId: tabId)
    }

    func clearPaneControlStates() {
        let affected = paneControlStates.keys
        paneControlStates.removeAll()
        for terminalId in affected { paneViews[terminalId]?.updateHerdrPaneControlOverlay() }
        for tab in tabs.values where tab.herdrIsControlledElsewhere { tab.herdrIsControlledElsewhere = false }
    }

    private func presentTakeControlPrompt(tabId: String) {
        guard !takeControlPromptedTabs.contains(tabId), let tab = tabs[tabId] else { return }
        takeControlPromptedTabs.insert(tabId)
        let request = MainAlertController.HerdrTakeControlRequest(
            gatewayUUID: gatewayUUID, tabId: tabId, tabTitle: tab.title,
            evictsOtherClient: !capabilities.supportsSharedViewing
        )
        NotificationCenter.default.post(
            name: .herdrTakeControlRequested, object: gatewayUUID,
            userInfo: ["request": request, "windowId": hostWindowId]
        )
    }

    /// User asked for the tab. Sharing servers just need our geometry; older
    /// ones need the attaches re-issued with takeover.
    func requestTakeControl(tabId: String) {
        guard !didEnd, mode == .raw, tabs[tabId] != nil else { return }
        Self.logger.info("herdr take control \(tabId) shared=\(self.capabilities.supportsSharedViewing)")
        if capabilities.supportsSharedViewing {
            claimGeometry(tabId: tabId)
        } else {
            // The other client resized the tab under us; our old confirmation
            // would otherwise keep every attach waiting for a matching layout.
            tabGeometryStates[tabId]?.invalidate()
            geometryTasks.removeValue(forKey: tabId)?.cancel()
            if let tab = tabs[tabId], let view = tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
                scheduleGeometryPush(from: view)
            }
        }
        let waiting = paneInfos.values.filter { $0.tab_id == tabId && paneControlStates[$0.terminal_id] != nil }
        guard !waiting.isEmpty else { return }
        takeoverRequested.insert(tabId)
        takeControlPromptedTabs.remove(tabId)
        for pane in waiting {
            paneControlStates.removeValue(forKey: pane.terminal_id)
            paneViews[pane.terminal_id]?.updateHerdrPaneControlOverlay()
            enqueueAttach(pane.terminal_id, front: isVisible(terminalId: pane.terminal_id))
        }
        pumpAttachQueue()
    }

    /// What tmux's `detach-client -a` maps to here: herdr cannot close
    /// another client's connection, so take every tab's geometry and every
    /// pane another client holds, including the tabs this window is not
    /// showing. The tab in front goes first so it lands before the rest.
    @discardableResult
    func takeControlOfSession() -> Bool {
        guard !didEnd, mode == .raw, channel != nil, !tabs.isEmpty else { return false }
        Self.logger.info("herdr take control of session: \(self.tabs.count) tabs")
        let selectedTabId = tabs.first { $0.value.id == tabsModel.selectedTabID }?.key
        let ordered = (selectedTabId.map { [$0] } ?? []) + tabs.keys.filter { $0 != selectedTabId }
        for tabId in ordered {
            requestTakeControl(tabId: tabId)
        }
        return true
    }

    private func syncControlledElsewhereBadge(tabId: String) {
        guard let tab = tabs[tabId] else { return }
        let flag = tabIsControlledElsewhere(tab)
        if tab.herdrIsControlledElsewhere != flag { tab.herdrIsControlledElsewhere = flag }
    }
}
