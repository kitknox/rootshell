//
//  MainView+TSSHTransfer.swift
//  rootshell
//
//  MainView helpers for the "Transfer to Nearby Device" feature on tssh
//  tabs. Originator and receiver coordinators do all the protocol work;
//  these helpers just orchestrate tab/leaf state on the host MainView.
//

import GhosttyKit
import os.log
import SwiftUI
import UIKit

extension MainView {

    /// Builds an origin-side transfer request for the given tab + focused
    /// leaf. Snapshots the live surface synchronously so the user sees a
    /// stable scrollback on the receiving device, then publishes the
    /// NSUserActivity offer via the request's originator.
    func startTrzszTransfer(tabId: UUID, leaf: Ghostty.TerminalView) {
        guard let session = leaf.session as? TrzszSession else {
            Ghostty.logger.warning("startTrzszTransfer called on non-trzsz session")
            return
        }
        guard session.transferableSessionID != nil else {
            Ghostty.logger.warning("startTrzszTransfer: session has no resumable sessionID yet")
            return
        }

        let surface = leaf.surface
        let primaryRaw = dumpPrimaryScrollback(surface: surface)
        let altActive = surface.map { ghostty_surface_is_alternate_active($0) } ?? false
        let altDump: Data? = altActive ? dumpAlternateScreen(surface: surface) : nil

        let geometry = leaf.currentGridSize()
        let snapshot = TrzszTransferSnapshot(
            primaryScrollback: primaryRaw,
            alternateScreen: altDump,
            cols: UInt16(min(Int(UInt16.max), max(1, geometry.cols))),
            rows: UInt16(min(Int(UInt16.max), max(1, geometry.rows))),
            liveTitle: leaf.title
        )

        guard let payload = TrzszTransferOriginator.buildPayload(from: session, snapshot: snapshot) else {
            Ghostty.logger.warning("Failed to build trzsz transfer payload")
            return
        }

        let leafId = leaf.uuid
        let originator = TrzszTransferOriginator(
            payload: payload,
            session: session,
            onTransferConfirmed: {
                NotificationCenter.default.post(
                    name: .trzszTransferLeafShouldRemove,
                    object: nil,
                    userInfo: ["tabId": tabId, "leafId": leafId]
                )
            }
        )

        let request = TrzszTransferOriginRequest(
            originator: originator,
            displayName: payload.displayName,
            tabId: tabId,
            leafId: leaf.uuid
        )
        self.trzszTransferOriginRequest = request
    }

    /// Receiver flow: after the user accepts an incoming Handoff offer and
    /// the receiver coordinator has decoded the payload + deposited it
    /// into the inbox, this opens a new tab whose TerminalView consumes
    /// the inbox slot and attaches.
    func createTrzszTransferReceivedTab(
        ticketID: UUID,
        displayName: String,
        host: String
    ) {
        guard let app = ghosttyApp.app else {
            Ghostty.logger.error("Cannot create transfer tab: Ghostty app not initialized")
            TrzszTransferInbox.shared.complete(
                ticketID,
                result: .failure(TrzszTransferError.attachFailed("Ghostty app not initialized"))
            )
            return
        }

        let terminalView = Ghostty.TerminalView(
            app,
            ghosttyApp: ghosttyApp,
            connectionConfig: .trzszTransfer(
                transferTicketID: ticketID,
                displayName: displayName,
                host: host
            ),
            windowId: windowId
        )
        terminalView.setWindowActive(isWindowFocused)
        terminalView.isLogicallyFocused = true

        let newTab = TerminalTab(
            terminalView: terminalView,
            title: displayName,
            windowId: windowId,
            isMosh: true  // trzsz is roaming, same UI affordances apply
        )
        terminalView.containingTabID = newTab.id
        newTab.focusedTerminal = terminalView

        let insertionIndex = min(selectedTabIndex + 1, terminals.count)
        terminals.insert(newTab, at: insertionIndex)
        tabsModel.pendingScrollToTabID = newTab.id
        let newTabIndex = insertionIndex

        setupTitleObservation(at: newTabIndex)

        selectedTabIndex = newTabIndex
        setFocusedTerminal(terminalView, inTab: newTabIndex)

        // Keep the receive sheet up while the new TerminalView attaches.
        // It owns the receiver coordinator and its Cancel button now
        // cancels the inbox ticket, which ack's failure to the originator
        // immediately instead of leaving the sender waiting for timeout.

        // Mac Catalyst-specific: the sheet-dismissal animation runs ~300 ms,
        // and while the sheet is still on-screen UIKit refuses to give the
        // newly-inserted terminal first-responder status (every keystroke
        // beeps). `setFocusedTerminal` retries at 50 ms which is too early;
        // schedule a second, longer retry that fires after the sheet is
        // definitely gone so the user can type without having to click the
        // tab first.
        let pendingFocus = terminalView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak pendingFocus] in
            guard let pendingFocus,
                  pendingFocus.window != nil,
                  pendingFocus.isLogicallyFocused,
                  !pendingFocus.isFirstResponder else { return }
            _ = pendingFocus.becomeFirstResponder()
        }
    }

    // MARK: - Surface helpers

    private func dumpPrimaryScrollback(surface: ghostty_surface_t?) -> Data {
        guard let surface else { return Data() }
        var len: UInt = 0
        guard let ptr = ghostty_surface_dump_primary_screen(surface, &len) else {
            return Data()
        }
        let data = Data(bytes: ptr, count: Int(len))
        ghostty_surface_free_dump(ptr, len)
        return data
    }

    private func dumpAlternateScreen(surface: ghostty_surface_t?) -> Data? {
        guard let surface else { return nil }
        var len: UInt = 0
        guard let ptr = ghostty_surface_dump_alternate_screen(surface, &len) else {
            return nil
        }
        let data = Data(bytes: ptr, count: Int(len))
        ghostty_surface_free_dump(ptr, len)
        return data
    }

    // MARK: - Closeout

    /// Handler for the `.trzszTransferLeafShouldRemove` notification posted
    /// by the originator after the peer ack'd. Cleans up the focused leaf
    /// via `.transferOut` and removes the tab if it was the only leaf.
    func handleTrzszTransferLeafRemoval(tabId: UUID, leafId: UUID) {
        guard let tabIndex = terminals.firstIndex(where: { $0.id == tabId }) else { return }
        guard let leaf = terminals[tabIndex].splitTree.terminalLeaves.first(where: { $0.uuid == leafId }) else { return }

        if leaf.isFirstResponder {
            leaf.resignFirstResponder()
        }
        leaf.isLogicallyFocused = false
        withdrawPendingPrompts(for: leaf)
        leaf.cleanup(reason: .transferOut)

        // Single leaf in the tab → close the tab. closeTab re-runs cleanup
        // with .userClose on every leaf, but our leaf has already had its
        // session released, so the second cleanup pass is a no-op (session
        // is nil, didEndSession guards the trzsz teardown internally).
        if terminals[tabIndex].splitTree.count <= 1 {
            closeTab(at: tabIndex)
            return
        }

        // Multi-leaf tab: drop just this leaf. Mirrors the structural side
        // of MainViewSplits.closeSplit, but without firing terminate() on
        // the session — that already happened via .transferOut cleanup.
        guard let root = terminals[tabIndex].splitTree.root,
              let leafNode = root.node(view: leaf) else {
            return
        }

        var nextFocus: SplitPaneView?
        if let neighbor = root.findNeighbor(of: leafNode) {
            nextFocus = neighbor.leftmostLeaf()
        }

        terminals[tabIndex].splitTree = terminals[tabIndex].splitTree.remove(leafNode)
        if let nextFocus {
            terminals[tabIndex].focusedPane = nextFocus
            setFocusedPane(nextFocus, inTab: tabIndex)
        }
    }
}

extension Notification.Name {
    /// Posted by `closeLeafAfterTransfer` to ask MainView to remove a leaf
    /// (and possibly the containing tab) without re-entering the user-close
    /// path. Receiver in MainViewSplits/MainViewTabManagement.
    static let trzszTransferLeafShouldRemove = Notification.Name("trzszTransferLeafShouldRemove")
}

// MARK: - Geometry helper

extension Ghostty.TerminalView {
    /// Returns the surface's current cols/rows, falling back to 80x24 if
    /// the surface hasn't been created yet.
    func currentGridSize() -> (cols: Int, rows: Int) {
        if let surface = self.surface {
            let s = ghostty_surface_size(surface)
            return (Int(s.columns), Int(s.rows))
        }
        return (80, 24)
    }
}
