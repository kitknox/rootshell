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
              let pane = terminals[selectedTabIndex].focusedPane as? VNCPaneView
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
        password: String?,
        uuid: UUID = UUID(),
        logicallyFocused: Bool = true
    ) -> VNCPaneView {
        let pane = VNCPaneView(config: config, windowId: windowId, uuid: uuid)
        pane.sourceProfileID = sourceProfileID
        pane.pendingPassword = password
        pane.setWindowActive(isWindowFocused)
        pane.isLogicallyFocused = logicallyFocused

        // Jump-tunnel host-key prompts ride the same per-window alert
        // mechanism as SSH tabs. Captures the alert controller, not the
        // view, so the closure survives MainView body re-evaluation.
        let alerts = self.alerts
        let sessionLabel = config.displayName
        pane.onHostKeyValidation = { @Sendable request in
            await alerts.handleHostKeyValidation(request: request, sessionLabel: sessionLabel)
        }
        pane.onCertificateValidation = { @Sendable request in
            await alerts.handleVNCCertificateValidation(
                request: request,
                sessionLabel: sessionLabel)
        }
        return pane
    }

    /// Open a Screen Sharing session in a new tab. `password` is a one-shot
    /// handoff from a profile password prompt (not saved to the Keychain).
    func createVNCTab(with config: VNCConnectionConfig, sourceProfileID: UUID? = nil, password: String? = nil) {
        let pane = makeVNCPane(config: config, sourceProfileID: sourceProfileID, password: password)
        insertPaneAsTab(pane, title: config.displayName, profileThemeSourceID: sourceProfileID)
    }

    /// Open a Screen Sharing session as a split of the focused pane in the
    /// selected tab, falling back to a new tab when there is none.
    func createVNCSplit(
        with config: VNCConnectionConfig,
        direction: SplitTree<SplitPaneView>.NewDirection,
        sourceProfileID: UUID? = nil,
        password: String? = nil
    ) {
        guard terminals.indices.contains(selectedTabIndex) else {
            createVNCTab(with: config, sourceProfileID: sourceProfileID, password: password)
            return
        }

        // Get the focused pane or use the first one in the current tab
        var focusedPane = terminals[selectedTabIndex].focusedPane
        if focusedPane == nil, let firstPane = terminals[selectedTabIndex].splitTree.first {
            focusedPane = firstPane
            terminals[selectedTabIndex].focusedPane = firstPane
        }

        guard let targetPane = focusedPane else {
            createVNCTab(with: config, sourceProfileID: sourceProfileID, password: password)
            return
        }

        let pane = makeVNCPane(config: config, sourceProfileID: sourceProfileID, password: password)
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
    func toggleVNCFullScreen(for pane: VNCPaneView) {
        if pane.isDetachedForFullScreen {
            paneFullScreen.exit(animated: true)
            return
        }

        enterVNCFullScreen(for: pane, requiresSelectedTab: false)
    }

    /// Honor a profile's enter-on-connect preference without pulling a pane
    /// from a background tab over whatever the user is currently viewing.
    func automaticallyEnterVNCFullScreen(for pane: VNCPaneView) {
        enterVNCFullScreen(for: pane, requiresSelectedTab: true)
    }

    private func enterVNCFullScreen(for pane: VNCPaneView, requiresSelectedTab: Bool) {
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
            // still hosted by one of this window's tabs (teardown exits
            // clear this closure and never reach here).
            guard let index = tabsModel.tabs.firstIndex(where: { tab in
                tab.splitTree.contains(where: { $0 === exitedPane })
            }) else { return }
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

// MARK: - Host-Key Prompts for Non-Terminal Panes

extension MainAlertController {

    func handleVNCCertificateValidation(
        request: VNCConfiguration.CertificateValidationRequest,
        sessionLabel: String
    ) async -> VNCConfiguration.CertificateValidationResult {
        guard let leafCertificate = request.certificateChainDER.first else {
            return .reject
        }
        let fingerprint = VNCCertificateTrustStore.fingerprint(leafCertificate)
        let endpoint = VNCCertificateTrustStore.endpointKey(
            host: request.host,
            port: request.port)
        if VNCCertificateTrustStore.savedFingerprint(for: endpoint) == fingerprint {
            return .acceptOnce
        }

        return await withCheckedContinuation { continuation in
            vncCertificateValidationData = VNCCertificateValidationData(
                endpoint: endpoint,
                fingerprint: fingerprint,
                sessionLabel: sessionLabel,
                isChanged: VNCCertificateTrustStore.savedFingerprint(for: endpoint) != nil)
            vncCertificateValidationContinuation = continuation
            showVNCCertificateAlert = true
            enqueue(.vncCertificate)
        }
    }

    /// Host-key validation for connections without a terminal view
    /// (Screen Sharing jump tunnels). Mirrors
    /// `handleHostKeyValidation(request:terminalView:)` with a
    /// caller-supplied session label, reusing the same alert flags,
    /// continuation slot, and queue mechanics.
    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        sessionLabel: String
    ) async -> HostKeyValidationResult {
        await withCheckedContinuation { continuation in
            let alertContext = "(\(sessionLabel))"

            validationData = MainView.ValidationData(
                alertTitle: request.isKeyChanged
                    ? "⚠️ WARNING: Host Key Changed \(alertContext)"
                    : "New SSH Host \(alertContext)",
                message: request.message,
                isKeyChanged: request.isKeyChanged
            )

            hostKeyValidationContinuation = continuation

            if request.isKeyChanged {
                showKeyChangedAlert = true
            } else {
                showNewHostAlert = true
            }
        }
    }
}
