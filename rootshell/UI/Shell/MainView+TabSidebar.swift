//
//  MainView+TabSidebar.swift
//  rootshell
//
//  Vertical tab sidebar content and dismissal logic for MainView.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Vertical Tab Sidebar

    /// Dismisses the tab sidebar. The binding drives every presentation
    /// directly: the iOS/Catalyst UIKit overlay animates its own slide-out
    /// on the change, and the visionOS sheet animates natively.
    func dismissTabSidebar() {
        guard showingTabSwitcher else { return }
        showingTabSwitcher = false
    }

    /// Selecting a tab keeps the sidebar open on iPad/Catalyst
    /// (browser-style vertical tabs, the terminal switches behind the
    /// panel). On phone/visionOS the sheet covers the terminal entirely,
    /// so staying open would show nothing; dismiss on select there.
    var tabSidebarDismissesOnSelect: Bool {
        #if os(visionOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// Whether a tab tap keeps the floating sidebar open. Phone/visionOS always
    /// dismiss; iPad/Catalyst floating stays open unless the user enabled
    /// auto-hide. (Docked mode is handled separately and never auto-hides.)
    private var tabSidebarStaysOpenOnSelect: Bool {
        !tabSidebarDismissesOnSelect && !tabSidebarAutoHideOnSelect
    }

    func verticalTabSidebarContent(
        sheetTheme: ResolvedSheetTheme,
        isDocked: Bool,
        dockedBottomClearance: CGFloat = 0
    ) -> VerticalTabSidebar {
        VerticalTabSidebar(
            tabsModel: tabsModel,
            windowId: windowId,
            collapsedGateways: $tabSidebarCollapsedGateways,
            staysOpenOnSelect: tabSidebarStaysOpenOnSelect,
            isDocked: isDocked,
            dockedBottomClearance: dockedBottomClearance,
            canPin: canPinTabSidebar,
            isPinned: tabSidebarIsDocked,
            onTogglePin: { tabSidebarPinned.toggle() },
            onSelectTab: { id in
                // Select by identity — the sidebar already holds the tab's ID.
                // Routing through selectTab(at:) here is wrong: that takes a
                // VISIBLE index, but tabsModel.index(of:) is a FULL-array index,
                // and the two diverge once a tmux window/gateway is hidden,
                // landing selection on an off-by-N neighbor. (id=tmux-hidden-windows)
                if tabBarHidden && id != tabsModel.selectedTabID {
                    tabIndicator.suppressNextHiddenIndicator = true
                }
                selectTab(id: id)
                // Dismiss the floating sidebar on select when it shouldn't stay
                // open: phone/visionOS always, or iPad/Catalyst floating with
                // auto-hide enabled. The docked column is a persistent left
                // pane, so never auto-hide it.
                if !tabSidebarStaysOpenOnSelect && !tabSidebarIsDocked {
                    showingTabSwitcher = false
                }
                // While the sidebar stays open, handleSelectedTabChange
                // skips the terminal's becomeFirstResponder, so the panel
                // keeps the keyboard (no re-resign dance needed here).
            },
            onSelectPane: { tabID, paneID in
                if tabBarHidden && tabID != tabsModel.selectedTabID {
                    tabIndicator.suppressNextHiddenIndicator = true
                }
                navigateToTerminal(tabID: tabID, surfaceID: paneID)
                if !tabSidebarStaysOpenOnSelect && !tabSidebarIsDocked {
                    showingTabSwitcher = false
                }
            },
            onCloseTab: { id in
                guard let index = tabsModel.index(of: id) else { return }
                closeTab(at: index)
                if terminals.isEmpty {
                    // Last tab closed: get out of the way before the
                    // connection sidebar takes over.
                    showingTabSwitcher = false
                }
            },
            onReorderClass: { orderedIDs, draggedID in
                reorderTabsPreservingSlots(orderedClassIDs: orderedIDs, draggedID: draggedID)
            },
            onMoveTab: { from, to in
                moveTab(from: from, to: to)
            },
            onReorderEnded: { draggedID in
                commitTabReorderToTmux(draggedID: draggedID)
            },
            onNewTab: {
                // addNewTab opens the connection sidebar (right overlay).
                // When floating, hide this one as it takes over; when docked
                // it's a left column that coexists with the right overlay.
                if !tabSidebarIsDocked { dismissTabSidebar() }
                addNewTab()
            },
            onDismiss: {
                dismissTabSidebar()
            },
            onOpenSettings: {
                // The floating sidebar is an overlay, so hide it before the
                // settings cover presents; the docked column stays put beside it.
                if !tabSidebarIsDocked { dismissTabSidebar() }
                requestSettingsPresentation()
            },
            onNewTmuxWindow: { tab in requestTmuxNewWindow(for: tab) },
            tmuxController: { tab in
                tmuxControllerForTab(tab)
            },
            onShowConnectionInfo: { tab in showConnectionInfo(for: tab) },
            canTransferToNearby: { tab in canTransferTabToNearby(tab) },
            onTransferToNearby: { tab in transferTabToNearby(tab) },
            tabHasThemeOverride: { id in tabHasThemeOverride(id) },
            onClearThemeOverride: { id in themeOverrideManager.clearTabOverride(tabId: id) },
            onMoveTabToNewWindow: { tab in moveTabToNewWindow(tab) },
            onMoveTabsToNewWindow: { ids in moveTabsToNewWindow(ids) },
            sheetThemeColors: sheetTheme.themeColors,
            sheetAccentColor: sheetTheme.accentColor,
            sheetColorScheme: sheetTheme.colorScheme,
            onExposeRequested: {
                if !tabSidebarIsDocked { dismissTabSidebar() }
                toggleTabExpose()
            },
            onTabHover: { id, isHovered in
                tabHoverPreview.handleHover(tabID: id, source: .sidebar, isHovered: isHovered)
            },
            previewAnchors: tabHoverPreview.anchors
        )
    }

    func showTmuxSessionsForSelectedTab() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        guard tab.isTmuxWindow || tab.isTmuxGateway else { return }
        guard let controller = tmuxControllerForTab(tab) else { return }
        tmuxDashboardRequest = TmuxDashboardRequest(controller: controller)
    }

    /// Leave the multiplexer on the selected tab. Works for tmux -CC (including
    /// window tabs when the gateway is auto-hidden), raw tmux / zellij / herdr,
    /// and zmx. Sessions keep running for later reattach.
    func detachSessionForSelectedTab() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        _ = MuxSessionDetach.detach(tab: tab, tmuxController: tmuxControllerForTab)
    }

    /// Ask before detaching every multiplexer attachment in this window.
    func requestDetachAllSessions() {
        let count = detachableAttachmentCount()
        guard count > 0 else { return }
        if count == 1 {
            // A single attachment: no need for the “all” confirm — just detach.
            detachAllSessionsInWindow()
            return
        }
        confirmDetachAllSessions = true
    }

    func detachAllSessionsInWindow() {
        _ = MuxSessionDetach.detachAll(
            tabs: Array(terminals),
            tmuxController: tmuxControllerForTab
        )
    }

    func scheduleMuxDetachBannerDismiss() {
        muxDetachBannerDismissTask?.cancel()
        muxDetachBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissMuxDetachBanner()
        }
    }

    func dismissMuxDetachBanner() {
        muxDetachBannerDismissTask?.cancel()
        muxDetachBannerDismissTask = nil
        muxDetachBanner = nil
    }

    /// If a live mux auto-start attachment already matches `config`, focus it
    /// and show a short banner. Returns true when a new connection was skipped.
    @discardableResult
    func focusLiveMuxAttachmentIfPresent(for config: SSHConfig) -> Bool {
        guard let match = MuxSessionResume.findLiveAttachment(for: config) else {
            return false
        }
        _ = MuxSessionResume.focus(match, in: windowId) { id in
            selectTab(id: id)
        }
        muxDetachBanner = MuxDetachBannerState(
            message: String(
                localized: "Already attached to \(match.displayName)",
                comment: "Banner when opening a mux profile that is already live"
            ),
            offer: nil
        )
        scheduleMuxDetachBannerDismiss()
        return true
    }

    func reconnectFromMuxDetachBanner() {
        guard let offer = muxDetachBanner?.offer else { return }
        dismissMuxDetachBanner()
        if let profileID = offer.profileID,
           let profile = ConnectionProfileManager.shared.profiles.first(where: { $0.id == profileID }) {
            connectToProfile(profile, splitOption: .newTab)
            return
        }
        connectWithConfig(
            offer.sshConfig,
            connectionProtocol: offer.connectionProtocol,
            splitOption: .newTab
        )
    }

    /// How many distinct detach targets exist right now (gateways counted once).
    func detachableAttachmentCount() -> Int {
        var count = 0
        var seenGateways = Set<ObjectIdentifier>()
        for tab in terminals {
            if let controller = tmuxControllerForTab(tab), controller.isActive {
                let id = ObjectIdentifier(controller)
                if seenGateways.insert(id).inserted { count += 1 }
                continue
            }
            for view in tab.splitTree.terminalLeaves {
                if let attachment = MuxSessionDetach.attachment(on: view),
                   attachment.kind != .tmuxControlMode {
                    count += 1
                }
            }
        }
        return count
    }

    /// Evict every OTHER tmux client (`detach-client -a`) for the selected
    /// tab's gateway, keeping this client attached. Works from ANY tmux CC tab:
    /// `tmuxControllerForTab` resolves a window tab through its pane binding to
    /// the owning gateway's controller. No `otherAttachedClientCount` gate —
    /// that count reads `cachedSessions`, only warmed when a tab menu opens, so
    /// it's cold on a bare keyboard shortcut. `detach-client -a` is safe
    /// regardless: tmux skips the issuing control client, so it no-ops when no
    /// other clients are attached.
    func detachOtherClientsForSelectedTab() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        guard tab.isTmuxWindow || tab.isTmuxGateway,
              let controller = tmuxControllerForTab(tab) else { return }
        Task { @MainActor in
            do {
                try await controller.detachOtherClients()
            } catch {
                let message = error.localizedDescription
                TmuxDebugLogger.shared.event("DETACH", "others failed: \(message)")
            }
        }
    }

    /// Resolve the tmux controller backing a tab: the gateway tab holds the
    /// controller on its gateway view; a tmux window tab reaches it through
    /// any pane's binding (parent surface keys the per-gateway registry —
    /// correct even with multiple gateways open).
    func tmuxControllerForTab(_ tab: TabModel) -> TmuxController? {
        if let controller = tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController {
            return controller
        }
        for view in tab.splitTree.terminalLeaves {
            if let binding = view.tmuxPaneBinding {
                return TmuxController.controller(forOwnerSurface: binding.parentSurface)
            }
        }
        return nil
    }
}
