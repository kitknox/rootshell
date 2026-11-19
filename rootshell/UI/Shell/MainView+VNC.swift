//
//  MainView+VNC.swift
//  rootshell
//
//  Screen Sharing / VNC tab and split creation for MainView.
//

import SwiftUI
import os
import rootshellVNC
import RFBTransport

extension MainView {

    /// Route a menu-originated reserved shortcut to the selected VNC pane when
    /// its destination toggle is on. `true` means VNC consumed the command and
    /// the caller must skip the rootshell action.
    func routeReservedVNCKeyboardShortcut(from notification: Notification) -> Bool {
        guard let rawValue = notification.userInfo?[VNCReservedKeyboardShortcut.notificationUserInfoKey] as? String,
              let shortcut = VNCReservedKeyboardShortcut(rawValue: rawValue),
              terminals.indices.contains(selectedTabIndex),
              let pane = terminals[selectedTabIndex].focusedPane as? any RemoteScreenPane
        else { return false }
        return pane.routeReservedKeyboardShortcutToVNC(shortcut)
    }

    /// Shared construction prefix for VNC panes, mirroring
    /// `makeConnectedTerminalView`'s pre-insertion contract: window-active
    /// stamping and `isLogicallyFocused` before the pane joins the view
    /// hierarchy (`containingTabID` is stamped by the insertion cores).
    /// Window-state restore reuses it (stable `uuid`, `logicallyFocused:
    /// false` — the restore path focuses only the selected tab's saved pane)
    /// so host-key wiring stays in one place.
    func makeVNCPane(
        config: VNCConnectionConfig,
        sourceProfileID: UUID?,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil,
        uuid: UUID = UUID(),
        logicallyFocused: Bool = true
    ) -> VNCPaneView {
        let pane = VNCPaneView(config: config, windowId: windowId, uuid: uuid)
        pane.sourceProfileID = sourceProfileID
        pane.passwordHandoff = passwordHandoff
        pane.setWindowActive(isWindowFocused)
        pane.isLogicallyFocused = logicallyFocused

        // Jump-tunnel host-key and certificate prompts ride the per-window
        // alert queue of whichever window holds the pane when they arrive.
        let sessionLabel = config.displayName
        pane.onHostKeyValidation = { @Sendable [weak pane] request in
            await MainAlertController.routeHostKeyValidation(request, sessionLabel: sessionLabel, from: pane)
        }
        pane.onCertificateValidation = { @Sendable [weak pane] request in
            await MainAlertController.routeCertificateValidation(request, sessionLabel: sessionLabel, from: pane)
        }
        return pane
    }

    /// Open a Screen Sharing session in a new tab.
    func createVNCTab(
        with config: VNCConnectionConfig,
        sourceProfileID: UUID? = nil,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil
    ) {
        let pane = makeVNCPane(config: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
        insertPaneAsTab(pane, title: config.displayName, profileThemeSourceID: sourceProfileID)
    }

    /// Open a Screen Sharing session as a split of the focused pane in the
    /// selected tab, falling back to a new tab when there is none.
    func createVNCSplit(
        with config: VNCConnectionConfig,
        direction: SplitTree<SplitPaneView>.NewDirection,
        sourceProfileID: UUID? = nil,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil
    ) {
        guard terminals.indices.contains(selectedTabIndex) else {
            createVNCTab(with: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
            return
        }

        // Get the focused pane or use the first one in the current tab
        var focusedPane = terminals[selectedTabIndex].focusedPane
        if focusedPane == nil, let firstPane = terminals[selectedTabIndex].splitTree.first {
            focusedPane = firstPane
            terminals[selectedTabIndex].focusedPane = firstPane
        }

        guard let targetPane = focusedPane else {
            createVNCTab(with: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
            return
        }

        let pane = makeVNCPane(config: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
        insertPaneAsSplit(
            pane,
            at: targetPane,
            inTab: selectedTabIndex,
            direction: direction,
            logLabel: "VNC",
            profileThemeSourceID: sourceProfileID
        )
    }
}

// MARK: - Full-Screen Takeover

extension MainView {

    /// HUD "Enter/Exit Full Screen" (via `.vncToggleFullScreen`): route to
    /// the per-window PaneFullScreenController.
    func toggleVNCFullScreen(for pane: any RemoteScreenPane) {
        if pane.isDetachedForFullScreen {
            paneFullScreen.exit(animated: true)
            return
        }

        enterVNCFullScreen(for: pane, requiresSelectedTab: false)
    }

    /// Honor a profile's enter-on-connect preference without pulling a pane
    /// from a background tab over whatever the user is currently viewing.
    func automaticallyEnterVNCFullScreen(for pane: any RemoteScreenPane) {
        enterVNCFullScreen(for: pane, requiresSelectedTab: true)
    }

    private func enterVNCFullScreen(for pane: any RemoteScreenPane, requiresSelectedTab: Bool) {
        guard !pane.isDetachedForFullScreen, !paneFullScreen.isActive else { return }
        guard let index = tabsModel.tabs.firstIndex(where: { tab in
            tab.splitTree.contains(where: { $0 === pane })
        }) else { return }
        if requiresSelectedTab {
            guard tabsModel.tabs.indices.contains(selectedTabIndex),
                  index == selectedTabIndex,
                  tabsModel.tabs[index].focusedPane === pane else { return }
        }

        paneFullScreen.enter(pane, tabsModel: tabsModel) { [self] exitedPane in
            // Restore focus through the standard path when the pane is
            // still hosted by the selected tab (teardown exits clear this
            // closure and never reach here). A tab-switch exit runs after
            // handleSelectedTabChange has focused the destination tab:
            // focusing the pane in its now-background tab would re-arm VNC
            // keyboard capture, and the package reclaims first responder on
            // every decoded frame, taking the keyboard from that terminal.
            guard let index = tabsModel.tabs.firstIndex(where: { tab in
                tab.splitTree.contains(where: { $0 === exitedPane })
            }), index == selectedTabIndex else { return }
            setFocusedPane(exitedPane, inTab: index)
        }

        // `enter` can decline while UIKit has not attached the restored pane
        // to a window yet. Leave the preference pending in that case; a later
        // focus/connection transition will retry it.
        guard pane.isDetachedForFullScreen else { return }
        pane.fullScreenDidEnter()

        // Focus the pane while it owns the window so hardware keys flow to
        // the remote (a no-op when it is already the focused pane).
        setFocusedPane(pane, inTab: index)
    }

    /// Full-screen watchdogs (chained from `applyTailHandlers`): defense in
    /// depth so no tab mutation can strand a checked-out pane. The primary
    /// teardown paths are direct (prepareForClose funnel, retargetWindow);
    /// these catch tab switches and anything that removed the pane's tab
    /// without touching the pane.
    @ViewBuilder
    func applyVNCFullScreenHandlers<V: View>(_ view: V) -> some View {
        view
            .onChange(of: tabsModel.selectedTabID) { _, _ in
                paneFullScreen.exitForTabChange()
            }
            .onChange(of: tabsModel.tabs.count) { _, _ in
                paneFullScreen.exitIfPaneOrphaned()
            }
    }
}

// MARK: - Certificate Prompts for Remote Screen Panes

extension MainAlertController {

    func handleVNCCertificateValidation(
        request: VNCConfiguration.CertificateValidationRequest,
        sessionLabel: String,
        owner: UUID
    ) async -> VNCConfiguration.CertificateValidationResult {
        guard admitsPrompt(from: owner),
              let leafCertificate = request.certificateChainDER.first else {
            return .reject
        }
        let fingerprint = VNCCertificateTrustStore.fingerprint(leafCertificate)
        let endpoint = VNCCertificateTrustStore.endpointKey(
            host: request.host,
            port: request.port)
        let saved = VNCCertificateTrustStore.savedFingerprint(for: endpoint)
        if saved == fingerprint {
            return .acceptOnce
        }

        return await withCheckedContinuation { continuation in
            vncCertificateQueue.append(VNCCertificateValidationRequest(
                owner: owner,
                endpoint: endpoint,
                fingerprint: fingerprint,
                sessionLabel: sessionLabel,
                previouslyTrusted: saved,
                continuation: continuation))
            enqueue(.vncCertificate)
        }
    }
}

// MARK: - Pre-Disconnect Actions

extension MainView {

    /// Run each remote-screen pane's pre-disconnect action in turn, then
    /// `close`. Synchronous when no pane has one. A pane the user chooses to
    /// keep connected ends the chain, so `close` never runs.
    func runPreDisconnectActions(
        for panes: [SplitPaneView],
        then close: @escaping @MainActor () -> Void
    ) {
        let screenPanes = panes.compactMap { $0 as? any RemoteScreenPane }
        guard let pane = screenPanes.first else {
            close()
            return
        }
        let rest = Array(screenPanes.dropFirst())
        pane.runPreDisconnectAction { [self] in
            runPreDisconnectActions(for: rest, then: close)
        }
    }

    /// User-initiated pane close, after the pane's pre-disconnect action.
    func closeSplitAfterPreDisconnect(_ pane: SplitPaneView) {
        runPreDisconnectActions(for: [pane]) { [self] in
            // closeSplit falls back to the focused pane for a missing target.
            guard terminals.contains(where: { tab in
                tab.splitTree.contains(where: { $0 === pane })
            }) else { return }
            closeSplit(targeting: pane)
        }
    }

    /// User-initiated tab close, after its panes' pre-disconnect actions.
    func closeTabAfterPreDisconnect(id tabID: UUID, dismissSwitcherWhenEmpty: Bool = false) {
        guard let tab = terminals.first(where: { $0.id == tabID }) else { return }
        runPreDisconnectActions(for: tab.splitTree.map { $0 }) { [self] in
            guard let index = terminals.firstIndex(where: { $0.id == tabID }) else { return }
            closeTab(at: index)
            if dismissSwitcherWhenEmpty, terminals.isEmpty {
                // Last tab closed: get out of the way before the
                // connection sidebar takes over.
                showingTabSwitcher = false
            }
        }
    }

    /// A failed pre-disconnect action asks the user what to do inside its
    /// pane, so bring that pane forward.
    func revealPaneForPreDisconnectFailure(_ pane: SplitPaneView) {
        guard let tab = terminals.first(where: { tab in
            tab.splitTree.contains(where: { $0 === pane })
        }) else { return }
        // Also clears a sibling's zoom or full-screen takeover.
        navigateToTerminal(tabID: tab.id, surfaceID: pane.uuid)
    }
}
