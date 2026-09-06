//
//  MainView+Persistence.swift
//  rootshell
//
//  State persistence and session restoration for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os

#if targetEnvironment(macCatalyst)
/// Tracks the first window to restore geometry this process launch. The first
/// (primary) window is created by the system, renders fine, and must not be
/// nudged; every *later* window hits the Catalyst "renders blank until resized"
/// bug and needs the layout-forcing geometry change. A deterministic flag (vs.
/// counting connected scenes, which races window respawn) is what makes this
/// reliable — a window that lost the race would otherwise stay blank, re-save
/// its size, and stay blank on every subsequent launch.
@MainActor
private enum WindowGeometryRestoreState {
    private static var claimedFirst = false

    /// True exactly once — for the first window to reach geometry restore.
    static func claimFirstWindow() -> Bool {
        defer { claimedFirst = true }
        return !claimedFirst
    }
}
#endif

// MARK: - State Persistence

extension MainView {

    private func resumableTmuxGatewayUUIDs() -> Set<UUID> {
        Set(
            terminals.flatMap { $0.splitTree.terminalLeaves }
                .filter { view in
                    view.connectionConfig.isTrzsz
                    && (
                        view.tmuxController != nil
                        || view.restoredWasTmuxGateway
                        || view.tmuxResumeRequested
                        || view.tmuxResumeCancelRequested
                    )
                }
                .map(\.uuid)
        )
    }

    /// Serialize current window state for persistence
    func serializeWindowState() -> SerializableWindow? {
        guard !terminals.isEmpty else { return nil }

        // Build the ordered list of persisted tabs. Ordinary tabs (including the
        // tmux gateway tab, which is a real tssh session) serialize fully. A
        // projected tmux -CC WINDOW tab serializes as a lightweight PLACEHOLDER
        // (tmux window id + title + owning gateway terminal UUID, empty split
        // tree): its panes are bound to the live viewer, not real sessions, so
        // they are never serialized — instead the tab is restored at its saved
        // position and re-adopted when the gateway resumes control mode. A tmux
        // window tab that is missing its ids (should not happen once
        // `ensureWindow` stamps them) is excluded rather than restored as a bogus
        // local shell.
        //
        // Gateways whose tmux -CC session survives an app restart: only trzsz/tssh
        // keeps the remote pty (and the live tmux -CC process) alive across a
        // reconnect. A local-shell or plain-SSH gateway's tmux -CC dies with the
        // app, so its projected window tabs must NOT be persisted — they could never
        // be re-adopted and would linger as empty, un-closable tabs. Keyed on
        // live OR pending tmux-gateway state so an autosave during the resume
        // window keeps placeholders only for the gateway that can adopt them.
        let resumableGatewayUUIDs = resumableTmuxGatewayUUIDs()

        var persisted: [(tab: TabModel, serialized: SerializableTab)] = []
        persisted.reserveCapacity(terminals.count)
        for tab in terminals {
            let hasLivePane = tab.splitTree.contains { $0.asTerminal?.tmuxPaneBinding != nil }
            if tab.isTmuxWindow || hasLivePane {
                // `tmuxWindowId` is set once adopted; a restored-but-not-yet-
                // adopted placeholder only has `pendingTmuxWindowId`. Fall back to
                // it so an autosave during the reconnect window doesn't silently
                // drop the placeholder (which would lose its tab position). Only
                // persist placeholders owned by a resumable (trzsz) gateway.
                guard let tmuxWindowId = tab.tmuxWindowId ?? tab.pendingTmuxWindowId,
                      let owner = tab.owningGatewayTerminalUUID,
                      resumableGatewayUUIDs.contains(owner) else { continue }
                persisted.append((tab, SerializableTab(
                    id: tab.id,
                    title: tab.title,
                    splitTree: SerializableSplitTree(),  // live panes are not serialized
                    focusedTerminalId: nil,
                    windowId: windowId,
                    tmuxWindowId: tmuxWindowId,
                    owningGatewayTerminalUUID: owner,
                    tmuxFontSizeOverride: tab.tmuxFontSizeOverride,
                    isHiddenTmuxWindow: tab.isHiddenTmuxWindow ? true : nil
                )))
            } else {
                persisted.append((tab, SerializableTab(
                    id: tab.id,
                    title: tab.title,
                    splitTree: tab.splitTree.serialize(),
                    focusedTerminalId: tab.focusedPane?.uuid,
                    windowId: windowId,
                    // A hidden GATEWAY tab persists its flag so the hide
                    // survives an app restart — but only when the gateway can
                    // actually resume (trzsz, mirroring wasTmuxGateway at
                    // SerializableSplitTree); otherwise the restored pending
                    // flag could never be consumed. The pending-restore bit
                    // counts too: during the reconnect window (restored, not
                    // yet resumed) the live flags are still false, and an
                    // autosave must not drop the preference — the same
                    // live-OR-restored treatment wasTmuxGateway gets.
                    // (id=tmux-hidden-gateway)
                    isHiddenTmuxWindow: (((tab.isTmuxGateway && tab.isHiddenTmuxWindow)
                        || tab.pendingHiddenTmuxGatewayRestore)
                        && tab.splitTree.contains { resumableGatewayUUIDs.contains($0.uuid) })
                        ? true : nil
                )))
            }
        }
        guard !persisted.isEmpty else { return nil }

        let serializedTabs = persisted.map { $0.serialized }

        // Collect theme overrides (only for tabs we actually persist).
        let windowTheme = themeOverrideManager.getWindowTheme(windowId: windowId)
        var tabThemes: [UUID: String] = [:]
        var groupOverrides: [UUID: TabGroupID] = [:]
        let persistedIDs = Set(persisted.map { $0.tab.id })
        let persistedGroupTabOrders = tabsModel.sidebarGroupTabOrders.reduce(into: [String: [UUID]]()) {
            result, entry in
            let ids = entry.value.filter { persistedIDs.contains($0) }
            if !ids.isEmpty { result[entry.key] = ids }
        }
        let persistedProjectTabOrders = tabsModel.projectTabOrders.reduce(
            into: [ProjectGroupID: [UUID]]()
        ) { result, entry in
            let ids = entry.value.filter { persistedIDs.contains($0) }
            if !ids.isEmpty { result[entry.key] = ids }
        }
        for entry in persisted {
            if let theme = themeOverrideManager.getTabTheme(tabId: entry.tab.id) {
                tabThemes[entry.tab.id] = theme
            }
            if let override = tabsModel.tabGroupOverrides[entry.tab.id] {
                groupOverrides[entry.tab.id] = override
            }
        }

        // Remap the selected index into the persisted tab list (an excluded tab
        // would otherwise leave the selection pointing at the wrong tab).
        let selectedId = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : nil
        let remappedSelectedIndex = selectedId
            .flatMap { id in persisted.firstIndex(where: { $0.tab.id == id }) } ?? 0

        // Capture the live window frame so each window restores to its own
        // size/position. Stored in WindowState (keyed to this window via its
        // tabs) rather than by scene id, which is not stable across the
        // quit→relaunch session teardown.
        #if targetEnvironment(macCatalyst)
        // Prefer a fresh live read, falling back to the frame tracked continuously
        // during the session (`lastKnownWindowFrame`). The live lookup returns nil
        // at terminate on macOS 27 (scenes are torn down before the save runs), so
        // the continuous capture is what makes per-window geometry reliable.
        let savedFrame = Self.windowScene(forWindowId: windowId)?.effectiveGeometry.systemFrame
            ?? lastKnownWindowFrame
        #else
        let savedFrame: CGRect? = nil
        #endif

        return SerializableWindow(
            id: windowId,
            tabs: serializedTabs,
            selectedTabIndex: remappedSelectedIndex,
            themeOverride: windowTheme,
            tabThemeOverrides: tabThemes,
            tabGroupingEnabled: tabsModel.isGroupedModeEnabled ? true : nil,
            activeTabGroupID: tabsModel.activeGroupID,
            tabGroupOverrides: groupOverrides.filter { persistedIDs.contains($0.key) }.isEmpty
                ? nil
                : groupOverrides.filter { persistedIDs.contains($0.key) },
            tabGroupOrder: tabsModel.sidebarGroupOrder.isEmpty ? nil : tabsModel.sidebarGroupOrder,
            tabGroupTabOrders: persistedGroupTabOrders.isEmpty ? nil : persistedGroupTabOrders,
            projectGroupOrder: tabsModel.projectGroupOrder.isEmpty ? nil : tabsModel.projectGroupOrder,
            projectTabOrders: persistedProjectTabOrders.isEmpty ? nil : persistedProjectTabOrders,
            frameOriginX: savedFrame.map { Double($0.origin.x) },
            frameOriginY: savedFrame.map { Double($0.origin.y) },
            frameWidth: savedFrame.map { Double($0.size.width) },
            frameHeight: savedFrame.map { Double($0.size.height) }
        )
    }

    /// Restore window state from saved data
    func restoreWindowState(_ state: SerializableWindow) {
        // Restore theme overrides first
        if let windowTheme = state.themeOverride {
            themeOverrideManager.setWindowTheme(windowId: windowId, themeName: windowTheme)
        }
        for (tabId, themeName) in state.tabThemeOverrides {
            themeOverrideManager.setTabTheme(tabId: tabId, themeName: themeName)
        }

        // Restore tabs. The restoration initializer wires up title observation
        // with preserveExistingTitle: true, so no follow-up setupTitleObservation
        // call is needed here.
        var restoredTabIDsBySavedID: [UUID: UUID] = [:]
        for savedTab in state.tabs {
            if let tab = restoreTab(savedTab) {
                terminals.append(tab)
                restoredTabIDsBySavedID[savedTab.id] = tab.id
            }
        }

        if let savedOverrides = state.tabGroupOverrides {
            tabsModel.tabGroupOverrides = Dictionary(uniqueKeysWithValues: savedOverrides.compactMap { savedID, groupID in
                guard let restoredID = restoredTabIDsBySavedID[savedID] else { return nil }
                return (restoredID, groupID)
            })
        } else {
            tabsModel.tabGroupOverrides = [:]
        }
        tabsModel.activeGroupID = state.activeTabGroupID
        tabsModel.isGroupedModeEnabled = state.tabGroupingEnabled ?? false
        tabsModel.sidebarGroupOrder = state.tabGroupOrder ?? []
        tabsModel.sidebarGroupTabOrders = remapOrderBuckets(
            state.tabGroupTabOrders ?? [:],
            restoredIDsBySavedID: restoredTabIDsBySavedID
        )
        tabsModel.projectGroupOrder = state.projectGroupOrder ?? []
        tabsModel.projectTabOrders = remapProjectOrderBuckets(
            state.projectTabOrders ?? [:],
            restoredIDsBySavedID: restoredTabIDsBySavedID
        )
        tabsModel.clearStaleGroupOverrides()

        // Safety net for state saved by older builds: drop restored tmux window
        // placeholders whose owning gateway is NOT a resumable (trzsz/tssh) session.
        // A local-shell or plain-SSH `tmux -CC` gateway is gone after the app quits,
        // so its projected window tabs can never be re-adopted and would otherwise
        // linger as empty, never-reconciled tabs the user must close by hand. Current
        // serialization already omits them, so this fires at most once per upgraded
        // install. Runs before the selected-index restore below so its bounds check
        // (and fallback to the gateway / tab 0) absorbs the removals.
        let resumableOwnerUUIDs = resumableTmuxGatewayUUIDs()
        terminals.removeAll { tab in
            tab.awaitingTmuxReconcile &&
            !(tab.owningGatewayTerminalUUID.map { resumableOwnerUUIDs.contains($0) } ?? false)
        }
        tabsModel.clearStaleGroupOverrides()

        // Restore selected tab index. Assignment is outside any
        // `withAnimation`, so the restored index snaps in without animating
        // from tab 0.
        if state.selectedTabIndex >= 0 && state.selectedTabIndex < terminals.count {
            selectedTabIndex = state.selectedTabIndex
        }

        // The placeholder filtering above may have invalidated the saved
        // index, leaving `selectedTabID` nil even though tabs exist. Repair
        // so the displayed-tab reveal has a valid selection to follow
        // (a nil selection would keep every tab at opacity 0).
        tabsModel.repairSelectionIfNeeded()

        // Restored pane views default to visible before their Ghostty surfaces
        // exist. Seed the final tab visibility now so hidden tabs create their
        // renderers occluded and immediately release their per-surface GPU
        // resources. The selection observer is not guaranteed to run when the
        // restored selection remains at its initial tab.
        if let selectedID = tabsModel.selectedTabID {
            for tab in terminals {
                let isSelected = tab.id == selectedID
                for pane in tab.splitTree {
                    pane.setOcclusion(isSelected)
                }
            }
        }

        // Explicitly mark the focused terminal so didMoveToWindow() will grant focus.
        // This is needed because onChange(of: selectedTabIndex) may not fire if the
        // restored index equals the initial value (0), and even when it does fire,
        // the views aren't in the window yet for becomeFirstResponder() to succeed.
        if terminals.indices.contains(selectedTabIndex),
           let focusedPane = terminals[selectedTabIndex].focusedPane {
            focusedPane.isLogicallyFocused = true
            Ghostty.logger.info("Set isLogicallyFocused=true on restored terminal \(focusedPane.uuid.uuidString.prefix(8))")
        }

        // NOTE: Don't call TerminalRestorationReconnector.initiateReconnection() here -
        // the views aren't in the window yet. Auto-reconnection for key-based sessions
        // happens in TerminalView.setupPTYAndShell() when the surface is ready.
        // Password-required sessions show the overlay.

        Ghostty.logger.info("Restored \(terminals.count) tabs with \(terminals.flatMap { $0.splitTree }.count) terminals")

        // Tell WindowStateManager that this launch now has live populated
        // state, so a subsequent `unregisterWindow` / BG-gather that sees an
        // empty state knows the user closed it (clear the file) rather than
        // restoration never having run (preserve the file). Gated on
        // `terminals.count > 0` so a 0-tab restoration (every `restoreTab`
        // returned nil) leaves the file alone for next launch's retry.
        if !terminals.isEmpty {
            WindowStateManager.shared.markPopulatedStateMaterialized()
        }

        #if targetEnvironment(macCatalyst)
        if windowId != "visor" {
            Self.schedulePendingRegularWindowRestoration()
        }
        #endif

        // Mark restoration completed synchronously so a force-quit between
        // here and the next runloop tick is not misread as a restoration
        // failure by RestorationHealthTracker on the next launch. Repeated
        // misreads accumulate failure / skip counts and eventually
        // quarantine the saved state — apparent state loss on rapid
        // back-to-back kills. The flag is just three UserDefaults writes
        // and does not depend on views being in the window hierarchy.
        // notifySessionCountChanged stays deferred — it does.
        RestorationHealthTracker.shared.markRestorationCompleted()
        DispatchQueue.main.async {
            self.notifySessionCountChanged()
        }
    }

    private func remapOrderBuckets(
        _ buckets: [String: [UUID]],
        restoredIDsBySavedID: [UUID: UUID]
    ) -> [String: [UUID]] {
        buckets.reduce(into: [:]) { result, entry in
            let ids = entry.value.compactMap { restoredIDsBySavedID[$0] }
            if !ids.isEmpty { result[entry.key] = ids }
        }
    }

    private func remapProjectOrderBuckets(
        _ buckets: [ProjectGroupID: [UUID]],
        restoredIDsBySavedID: [UUID: UUID]
    ) -> [ProjectGroupID: [UUID]] {
        buckets.reduce(into: [:]) { result, entry in
            let ids = entry.value.compactMap { restoredIDsBySavedID[$0] }
            if !ids.isEmpty { result[entry.key] = ids }
        }
    }

    /// Create a tab from serialized state
    private func restoreTab(_ savedTab: SerializableTab) -> TerminalTab? {
        // tmux -CC window placeholder: there are no live panes to rebuild (they
        // are reprojected by the reconcile once the gateway resumes). Restore an
        // empty tab at its saved position, marked awaiting reconcile and showing
        // its last title. The gateway's controller adopts it (matching tmux
        // window id + owning gateway terminal UUID); the resume watchdog removes
        // it if the tmux window is gone / the session expired.
        if let tmuxWindowId = savedTab.tmuxWindowId {
            let tab = TabModel(windowId: windowId)
            tab.title = savedTab.title
            tab.isTmuxWindow = true
            tab.awaitingTmuxReconcile = true
            tab.pendingTmuxWindowId = tmuxWindowId
            tab.owningGatewayTerminalUUID = savedTab.owningGatewayTerminalUUID
            tab.tmuxFontSizeOverride = savedTab.tmuxFontSizeOverride
            // A window hidden at save time restores hidden, so it never
            // flashes in the strip while the gateway resumes; adoption
            // re-derives the flag from the live set. (id=tmux-hidden-windows)
            tab.isHiddenTmuxWindow = savedTab.isHiddenTmuxWindow ?? false
            // Re-apply any per-tab theme override under the new tab id (the tab
            // keeps this id through adoption, so the theme survives). Mirrors the
            // remap in the normal path below, which this early return skips.
            if let themeName = themeOverrideManager.getTabTheme(tabId: savedTab.id) {
                themeOverrideManager.clearTabOverride(tabId: savedTab.id)
                themeOverrideManager.setTabTheme(tabId: tab.id, themeName: themeName)
            }
            let redactedTitle = TmuxDebugLogger.redact(savedTab.title)
            Ghostty.logger.info("Restored tmux window placeholder @\(tmuxWindowId) title=\(redactedTitle)")
            TmuxDebugLogger.shared.event("RESTORE", "placeholder win=\(tmuxWindowId) owner=\(savedTab.owningGatewayTerminalUUID?.uuidString.prefix(8) ?? "nil") title=\(redactedTitle)")
            return tab
        }

        guard let rootNode = savedTab.splitTree.root else {
            Ghostty.logger.warning("Skipping empty tab during restoration")
            return nil
        }

        // Build the split tree with pending-connection panes
        var allPanes: [SplitPaneView] = []
        guard let liveRoot = buildNode(from: rootNode, paneViews: &allPanes) else {
            Ghostty.logger.warning("Failed to build split tree for tab \(savedTab.id)")
            return nil
        }

        let splitTree = SplitTree<SplitPaneView>(root: liveRoot, zoomed: nil)

        let focused: SplitPaneView?
        if let focusedId = savedTab.focusedTerminalId {
            focused = allPanes.first { $0.uuid == focusedId } ?? allPanes.first
        } else {
            focused = allPanes.first
        }

        // Use the restoration initializer so the saved title survives:
        // the initializer calls startObserving(preserveExistingTitle: true)
        // which dropFirst()'s the focused view's pre-connect "ghostty"
        // emission.
        let tab = TerminalTab(
            restoringTitle: savedTab.title,
            splitTree: splitTree,
            focusedPane: focused,
            windowId: windowId
        )

        for pane in allPanes {
            pane.containingTabID = tab.id
        }

        // A saved hidden flag reaching the NORMAL path is necessarily a hidden
        // GATEWAY tab (window tabs take the placeholder early-return above).
        // Never apply it directly — a hidden tab whose tmux resume fails would
        // be unreachable; stash it for markGatewayTab to consume after the
        // first successful reconcile. (id=tmux-hidden-gateway)
        if savedTab.isHiddenTmuxWindow == true {
            tab.pendingHiddenTmuxGatewayRestore = true
        }

        // Re-apply tab theme override with new tab ID if there was one for the old ID
        if let themeName = themeOverrideManager.getTabTheme(tabId: savedTab.id) {
            themeOverrideManager.clearTabOverride(tabId: savedTab.id)
            themeOverrideManager.setTabTheme(tabId: tab.id, themeName: themeName)
        }

        return tab
    }

    /// Build a live SplitTree node from serialized data
    private func buildNode(
        from node: SerializableSplitTree.SerializableNode,
        paneViews: inout [SplitPaneView]
    ) -> SplitTree<SplitPaneView>.Node? {
        switch node {
        case .leaf(let leafData):
            // Convert connection config
            var connectionConfig = leafData.connectionConfig.toConnectionConfig()

            // Screen Sharing pane: no Ghostty surface. The shared factory
            // wires host-key prompts; `didMoveToWindow` → `connectIfNeeded()`
            // reconnects (Keychain password, or the in-pane prompt on a miss).
            if case .vnc(let vncConfig) = connectionConfig {
                ResumeDebugLogger.shared.log("buildNode leaf: uuid=\(leafData.terminalId.uuidString.prefix(8)), config=vnc")
                let pane = makeVNCPane(
                    config: vncConfig,
                    sourceProfileID: leafData.sourceProfileID,
                    password: nil,
                    uuid: leafData.terminalId,
                    logicallyFocused: false
                )
                pane.userOverrideTitle = leafData.userOverrideTitle
                pane.restorationState = .pendingReconnect
                paneViews.append(pane)
                return .leaf(view: pane)
            }

            // For local shells, apply the saved working directory
            if case .local = connectionConfig,
               let cwd = leafData.lastKnownWorkingDirectory {
                connectionConfig = .local(workingDirectory: cwd)
            }

            // Create terminal view in "pending reconnection" state
            let configType: String = switch connectionConfig {
            case .trzsz: "trzsz"
            case .mosh: "mosh"
            case .ssh: "ssh"
            case .local: "local"
            case .shellLaunchedTrzsz: "shellLaunchedTrzsz"
            case .shellLaunchedMosh: "shellLaunchedMosh"
            case .shellLaunchedSSH: "shellLaunchedSSH"
            case .kubernetes: "kubernetes"
            case .console: "console"
            case .ec2Console: "ec2Console"
            case .trzszTransfer: "trzszTransfer"
            case .vnc: "vnc"
            }
            ResumeDebugLogger.shared.log("buildNode leaf: uuid=\(leafData.terminalId.uuidString.prefix(8)), config=\(configType)")

            guard let appPtr = ghosttyApp.app else {
                Ghostty.logger.error("Cannot create restored terminal: Ghostty app not initialized")
                return nil
            }
            let terminalView = Ghostty.TerminalView(
                appPtr,
                ghosttyApp: ghosttyApp,
                uuid: leafData.terminalId,
                connectionConfig: connectionConfig,
                windowId: windowId
            )
            terminalView.sourceProfileID = leafData.sourceProfileID
            terminalView.fontSizeOverride = leafData.fontSizeOverride
            terminalView.setWindowActive(isWindowFocused)
            terminalView.userOverrideTitle = leafData.userOverrideTitle
            terminalView.restoredTrzszLastConnectedAt = leafData.trzszLastConnectedAt
            // Remember if this leaf was a live tmux -CC gateway so the session
            // resume path can re-enter control mode (maybeResumeTmuxControlMode).
            terminalView.restoredWasTmuxGateway = leafData.wasTmuxGateway ?? false
            terminalView.tmuxResumeCancelRequested = leafData.tmuxResumeCancelRequested ?? false
            terminalView.restorationState = Ghostty.TerminalView.RestorationState.pendingReconnection
            terminalView.onAgentApprovalRequired = { @MainActor @Sendable request in
                self.handleAgentApprovalRequest(request)
            }
            self.wireGPGApprovalCallbacks(on: terminalView)
            if connectionConfig.requiresSSHCallbacks {
                let restoredTerminal = terminalView
                terminalView.onAuthenticationRequired = { @MainActor @Sendable [weak restoredTerminal] config in
                    if let restoredTerminal {
                        self.handleAuthenticationRequired(for: restoredTerminal, config: config)
                    }
                }
                terminalView.onHostKeyValidationRequired = { @MainActor @Sendable request, validatedTerminal in
                    await self.handleHostKeyValidation(request: request, terminalView: validatedTerminal)
                }
            }

            paneViews.append(terminalView)
            return .leaf(view: terminalView)

        case .split(let splitData):
            guard let leftNode = buildNode(from: splitData.left, paneViews: &paneViews),
                  let rightNode = buildNode(from: splitData.right, paneViews: &paneViews) else {
                return nil
            }

            let direction: SplitTree<SplitPaneView>.Direction =
                splitData.direction == .horizontal ? .horizontal : .vertical

            return .split(.init(
                direction: direction,
                ratio: splitData.ratio,
                left: leftNode,
                right: rightNode
            ))
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Materialize any saved regular windows that Catalyst did not recreate
    /// itself. Delayed slightly so OS-restored scenes get a chance to claim
    /// their exact saved IDs before we ask for fresh fallback scenes — kept short
    /// (the actual wrong-window safety is `getPendingState`'s fallback ID-matching,
    /// not this timer) so secondary windows appear quickly.
    static func schedulePendingRegularWindowRestoration(after delay: Duration = .milliseconds(100)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let count = WindowStateManager.shared.claimPendingRegularWindowActivationCount()
            guard count > 0 else { return }

            Ghostty.logger.info("Requesting \(count) additional window(s) for state restoration")
            for _ in 0..<count {
                UIApplication.shared.requestSceneSessionActivation(
                    nil,
                    userActivity: nil,
                    options: nil,
                    errorHandler: { error in
                        Task { @MainActor in
                            if WindowStateManager.shared.releasePendingRegularWindowActivationReservationAfterFailure() {
                                Self.schedulePendingRegularWindowRestoration(after: .seconds(1))
                            }
                        }
                        Ghostty.logger.error("Failed to create restoration window: \(error.localizedDescription)")
                    }
                )
            }
        }
    }

    /// This window's live `UIWindowScene`, found via the windowId→sceneSessionId
    /// registry. Returns nil before the scene reporter has linked them, or if the
    /// window is no longer connected.
    static func windowScene(forWindowId windowId: String) -> UIWindowScene? {
        guard let sessionId = TerminalWindowRegistry.sceneSessionId(for: windowId) else { return nil }
        return UIApplication.shared.connectedScenes.first {
            ($0 as? UIWindowScene)?.session.persistentIdentifier == sessionId
        } as? UIWindowScene
    }

    /// The saved Catalyst frame for a window, or nil if geometry wasn't captured.
    static func savedFrame(from state: SerializableWindow) -> CGRect? {
        guard let x = state.frameOriginX, let y = state.frameOriginY,
              let w = state.frameWidth, let h = state.frameHeight,
              w >= 1, h >= 1 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Stash this window's saved size/position so it can be applied exactly once
    /// the window's scene link is live. Claims first-window status *synchronously*
    /// here so call order (the primary window appears before any respawn) decides
    /// it — not the deferred execution order. `savedFrame` is nil for a brand-new
    /// (non-restored) window. Then attempts an immediate apply in case the scene
    /// link is already up (the `WindowSceneReporter` callback may have fired first).
    func stashPendingGeometryRestore(savedFrame: CGRect?) {
        guard windowId != "visor" else { return }
        pendingRestoreFrame = savedFrame
        isFirstRestoredWindow = WindowGeometryRestoreState.claimFirstWindow()
        geometryRestoreApplied = false
        geometryRestorePending = true
        tryApplyPendingGeometry()
    }

    /// Apply the stashed per-window geometry once — to (a) restore its saved size
    /// + position and (b) work around the long-standing Catalyst bug where a
    /// *secondary* window's SwiftUI content renders blank until the user manually
    /// resizes it.
    ///
    /// This is event-driven: it is called both from the `WindowSceneReporter`
    /// callback (the moment the windowId→scene link is published) and from
    /// `stashPendingGeometryRestore` (in case the link was already up). It no-ops
    /// until a restore is pending, not yet applied, and the scene resolves —
    /// finding the scene means the window has laid out, so the geometry change can
    /// act as the layout trigger. A single next-runloop fallback covers the narrow
    /// window where onAppear stashes after the only reporter publish.
    ///
    /// Reliability matters: a blank window saves its (un-restored) size, so a fix
    /// conditional on a size delta can fail for that window on *every* subsequent
    /// launch. So `applyGeometry` is deterministic — first window restores-if-
    /// different (no flash), every later window gets a guaranteed two-step change.
    func tryApplyPendingGeometry(allowRetry: Bool = true) {
        guard geometryRestorePending, !geometryRestoreApplied,
              windowId != "visor" else { return }
        let capturedWindowId = windowId
        guard let scene = Self.windowScene(forWindowId: capturedWindowId) else {
            // Link not yet published. The reporter callback is the primary
            // trigger; this single retry only covers stash-before-publish races.
            if allowRetry {
                DispatchQueue.main.async { self.tryApplyPendingGeometry(allowRetry: false) }
            }
            return
        }
        geometryRestoreApplied = true
        geometryRestorePending = false
        let savedFrame = pendingRestoreFrame
        let isFirst = isFirstRestoredWindow
        // Small settle margin so the stale initial layout is in place before we
        // drive the change that re-triggers layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.applyGeometry(
                to: scene, savedFrame: savedFrame,
                isFirstWindow: isFirst, windowId: capturedWindowId)
        }
    }

    private static func applyGeometry(
        to scene: UIWindowScene, savedFrame: CGRect?, isFirstWindow: Bool, windowId: String
    ) {
        let current = scene.effectiveGeometry.systemFrame

        // Resolve the target frame: the saved frame if it's mostly on a visible
        // screen, else its size at the current origin (a saved position on a
        // now-disconnected display); or the current frame if nothing was saved.
        let target: CGRect
        if let savedFrame {
            let screen = scene.screen.bounds
            let overlap = savedFrame.intersection(screen)
            let savedArea = savedFrame.width * savedFrame.height
            let mostlyVisible = savedArea > 0 &&
                (overlap.width * overlap.height) / savedArea >= 0.5
            target = mostlyVisible
                ? savedFrame
                : CGRect(origin: current.origin, size: savedFrame.size)
        } else if isFirstWindow {
            // Old save (pre per-window frame) on the first restored window: fall
            // back to the last-focused size so it doesn't open at the OS default.
            // First-window-only, so this can't collapse every window to one size;
            // it self-heals once the next autosave writes per-window frames.
            target = CGRect(origin: current.origin, size: WindowSizeManager.shared.frameForNewWindow().size)
        } else {
            target = current
        }

        if isFirstWindow {
            // Primary window renders fine and is already pre-sized at connect;
            // restore size only if it differs (no nudge, no flash).
            guard !target.equalTo(current) else { return }
            Ghostty.logger.info("Restored window geometry: \(Int(target.width))x\(Int(target.height))")
            requestWindowGeometry(scene, target)
            return
        }

        // Secondary window: guaranteed two-step ending at the target — restores
        // size AND reliably triggers the skipped layout pass.
        //
        // Prime by nudging the height 1pt *away from the minimum*: shrink only
        // when there's room below the target, otherwise grow. A naive `height-1`
        // would drop below Catalyst's minimum (CatalystSceneDelegate.minWindowSize)
        // for a window already at the minimum height — that request is rejected,
        // the window never moves, and the final request equals the current frame,
        // so no layout-triggering change occurs and the blank window stays blank.
        let minHeight = CatalystSceneDelegate.minWindowSize.height
        let primedHeight = target.height - 1 >= minHeight ? target.height - 1 : target.height + 1
        let primed = CGRect(
            x: target.origin.x, y: target.origin.y,
            width: target.width, height: primedHeight
        )
        Ghostty.logger.info("Restored window geometry: \(Int(target.width))x\(Int(target.height))")
        requestWindowGeometry(scene, primed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            requestWindowGeometry(scene, target)
        }
    }

    private static func requestWindowGeometry(_ scene: UIWindowScene, _ frame: CGRect) {
        let prefs = UIWindowScene.GeometryPreferences.Mac(systemFrame: frame)
        scene.requestGeometryUpdate(prefs) { error in
            Ghostty.logger.warning("Window geometry update failed: \(error.localizedDescription)")
        }
    }
    #endif

}
