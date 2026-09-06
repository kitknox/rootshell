//
//  MainView+Splits.swift
//  rootshell
//
//  Split management for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os

// MARK: - Split Management

extension MainView {

    func handlePaneMove(tabID: UUID, source: SplitPaneView, destination: SplitPaneView, zone: PaneDropZone) {
        guard let index = terminals.firstIndex(where: { $0.id == tabID }),
              index == selectedTabIndex, !isAnySheetPresented, appTabSwipeState == nil,
              !tabExpose.isActive, tabsModel.fullScreenPaneID == nil else { return }
        let tab = terminals[index]
        guard !tab.paneMove.isPending, tab.splitTree.zoomed == nil,
              tab.splitTree.contains(source), tab.splitTree.contains(destination),
              !tab.splitTree.contains(where: { $0.isDetachedForFullScreen }),
              PaneMoveEligibility.allows(source, destination) else { return }

        if let binding = source.asTerminal?.tmuxPaneBinding {
            guard let targetBinding = destination.asTerminal?.tmuxPaneBinding,
                  let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                  let command = zone.tmuxMoveCommand(
                    source: .init(ownerID: binding.parentUUID, windowID: binding.windowId, paneID: binding.paneId),
                    destination: .init(ownerID: targetBinding.parentUUID, windowID: targetBinding.windowId, paneID: targetBinding.paneId)
                  ),
                  let requestID = tab.paneMove.begin() else { return }
            let focusRevision = tab.paneFocusRevision
            let selectionRevision = tabsModel.selectionRevision
            Task { @MainActor in
                do {
                    _ = try await controller.sendCommandWithReply(command)
                    tab.paneMove.finish(requestID)
                    // tmux owns the tree; %layout-change will move the existing
                    // surfaces. This is only the user's one-shot focus request.
                    guard tabsModel.selectionRevision == selectionRevision,
                          tab.paneFocusRevision == focusRevision,
                          let currentIndex = terminals.firstIndex(where: { $0 === tab }),
                          currentIndex == selectedTabIndex,
                          !isAnySheetPresented, isWindowFocused,
                          tab.splitTree.contains(source),
                          source.asTerminal?.tmuxPaneBinding?.parentUUID == binding.parentUUID,
                          source.asTerminal?.tmuxPaneBinding?.windowId == binding.windowId else { return }
                    setFocusedPane(source, inTab: currentIndex)
                } catch {
                    tab.paneMove.finish(requestID, error: String(localized: "Couldn’t move pane: \(error.localizedDescription)"))
                    Ghostty.logger.error("Pane move failed: \(error.localizedDescription)")
                }
            }
            return
        }

        // A native tree may include terminals and nonterminal panes, but never
        // edit a server-owned window or a mixed tree with bound tmux leaves.
        guard !tab.isTmuxWindow, !tab.splitTree.terminalLeaves.contains(where: { $0.isTmuxPane }) else { return }
        do {
            tab.splitTree = try tab.splitTree.moving(view: source, to: destination, direction: zone.direction)
            setFocusedPane(source, inTab: index)
        } catch {
            Ghostty.logger.error("Invalid native pane move: \(error.localizedDescription)")
        }
    }

    func handleSplitResize(tabIndex: Int, node: SplitTree<SplitPaneView>.Node, ratio: Double) {
        guard tabIndex < terminals.count else { return }

        // Update the split ratio in the tree
        do {
            if case .split(let split) = node {
                let newSplit = SplitTree<SplitPaneView>.Node.Split(
                    direction: split.direction,
                    ratio: ratio,
                    left: split.left,
                    right: split.right
                )
                terminals[tabIndex].splitTree = try terminals[tabIndex].splitTree.replace(
                    node: node,
                    with: .split(newSplit)
                )

                // Post layout invalidation to ensure terminals receive resize notification
                NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
            }
        } catch {
            Ghostty.logger.error("Failed to resize split: \(error)")
        }
    }

    func createSplit(direction: SplitTree<SplitPaneView>.NewDirection) {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        if let vnc = terminals[selectedTabIndex].focusedPane as? VNCPaneView {
            createVNCSplit(with: vnc.config, direction: direction, sourceProfileID: vnc.sourceProfileID)
            return
        }
        guard let focusedTerminal = terminals[selectedTabIndex].focusedTerminal else { return }

        // tmux control mode: the tmux server owns this window's topology. Ask it
        // to split; the resulting %layout-change drives the reconcile that builds
        // the real, bound pane surface and the native split. Splitting locally
        // here would flash a pane that the next reconcile discards (tmux's layout
        // has no such pane). The gateway tab itself has no tmuxPaneBinding, so it
        // still splits locally.
        if focusedTerminal.isTmuxPane {
            focusedTerminal.requestTmuxSplit(direction)
            return
        }

        guard let app = ghosttyApp.app else { return }

        // Get connection config from FOCUSED terminal (not tab level)
        // Use forNewSplit() to create fresh session IDs for K8s, etc.
        let connectionConfig = focusedTerminal.connectionConfig.forNewSplit()

        // Create a new terminal view for the split with inherited connection config
        let newTerminalView = Ghostty.TerminalView(
            app,
            ghosttyApp: ghosttyApp,
            connectionConfig: connectionConfig,
            windowId: windowId
        )
        // An independent split belongs to the same originating profile.
        // A not-yet-consumed transfer falls back to local and has no provenance.
        if case .trzszTransfer = focusedTerminal.connectionConfig {
            newTerminalView.sourceProfileID = nil
        } else {
            newTerminalView.sourceProfileID = focusedTerminal.sourceProfileID
        }
        newTerminalView.setWindowActive(isWindowFocused)
        newTerminalView.onAgentApprovalRequired = { @MainActor @Sendable request in
            handleAgentApprovalRequest(request)
        }
        wireGPGApprovalCallbacks(on: newTerminalView)

        // Set up host key validation callback if this is an SSH session
        if connectionConfig.requiresSSHCallbacks {
            let sshSplitTerminal = newTerminalView
            newTerminalView.onAuthenticationRequired = { @MainActor @Sendable [weak sshSplitTerminal] config in
                if let sshSplitTerminal {
                    handleAuthenticationRequired(for: sshSplitTerminal, config: config)
                }
            }
            newTerminalView.onHostKeyValidationRequired = { @MainActor @Sendable request, validatedTerminal in
                await handleHostKeyValidation(request: request, terminalView: validatedTerminal)
            }
        }

        // Set containing tab ID before inserting
        newTerminalView.containingTabID = terminals[selectedTabIndex].id

        // Insert the new split
        do {
            terminals[selectedTabIndex].splitTree = try terminals[selectedTabIndex].splitTree.insert(
                view: newTerminalView,
                at: focusedTerminal,
                direction: direction
            )
            setFocusedTerminal(newTerminalView, inTab: selectedTabIndex)

            // Post layout invalidation to ensure all terminals receive resize notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
            }
        } catch {
            Ghostty.logger.error("Failed to create split: \(error)")
        }
    }

    func navigateSplit(direction: SplitTree<SplitPaneView>.FocusDirection) {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        guard let focusedPane = terminals[selectedTabIndex].focusedPane else { return }
        guard let currentNode = terminals[selectedTabIndex].splitTree.root?.node(view: focusedPane) else { return }

        if let targetView = terminals[selectedTabIndex].splitTree.focusTarget(for: direction, from: currentNode) {
            setFocusedPane(targetView, inTab: selectedTabIndex)
        }
    }

    /// Navigate to a specific terminal from a notification click
    func navigateToTerminal(tabID: UUID, surfaceID: UUID) {
        // Find the tab index
        guard let tabIndex = terminals.firstIndex(where: { $0.id == tabID }) else {
            Ghostty.logger.warning("Cannot navigate to terminal: tab \(tabID) not found")
            return
        }

        // Switch to the tab
        selectedTabIndex = tabIndex

        // Find the pane view by surface ID
        for paneView in terminals[tabIndex].splitTree {
            if paneView.uuid == surfaceID {
                setFocusedPane(paneView, inTab: tabIndex)
                Ghostty.logger.info("Navigated to terminal \(surfaceID.uuidString.prefix(8)) in tab \(tabIndex)")
                return
            }
        }

        // If specific surface not found, just focus the first pane in the tab
        if let firstPane = terminals[tabIndex].splitTree.first {
            setFocusedPane(firstPane, inTab: tabIndex)
            Ghostty.logger.info("Surface not found, focused first terminal in tab \(tabIndex)")
        }
    }

    func equalizeSplits() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        terminals[selectedTabIndex].splitTree = terminals[selectedTabIndex].splitTree.equalize()
    }

    func toggleSplitZoom() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        guard let focusedPane = terminals[selectedTabIndex].focusedPane else { return }

        // tmux control mode: zoom is server state. Send resize-pane -Z and let
        // the %layout-change reconcile project the zoom into SplitTree.zoomed
        // (id=tmux-zoom). Zooming locally instead desyncs: the next reconcile
        // rebuilds the split tree from tmux's layout and wipes the local zoom.
        // The gateway tab has no tmuxPaneBinding, so it keeps the local path.
        if let terminal = focusedPane.asTerminal, terminal.isTmuxPane {
            terminal.requestTmuxToggleZoom()
            return
        }

        guard let currentNode = terminals[selectedTabIndex].splitTree.root?.node(view: focusedPane) else { return }

        terminals[selectedTabIndex].splitTree = terminals[selectedTabIndex].splitTree.toggleZoom(for: currentNode)
    }

    func closeSplit(targeting targetPane: SplitPaneView? = nil) {
        Ghostty.logger.info("closeSplit() called (target=\(targetPane?.uuid.uuidString.prefix(8).description ?? "nil"))")

        // Resolve which tab + pane to close.
        // When a specific pane is provided (e.g. from `.closeSplit` posted by an
        // async session-end), route to that pane's actual tab regardless of which
        // tab the user has since switched to. Otherwise fall back to the focused
        // pane in the selected tab (SwiftUI-Commands menu / no-object posts).
        var tabIndex: Int
        let paneToClose: SplitPaneView
        if let target = targetPane,
           let resolvedIndex = terminals.firstIndex(where: { $0.splitTree.contains(where: { $0 === target }) }) {
            tabIndex = resolvedIndex
            paneToClose = target
        } else {
            guard terminals.indices.contains(selectedTabIndex) else {
                Ghostty.logger.warning("closeSplit: selectedTabIndex (\(selectedTabIndex)) >= terminals.count (\(terminals.count))")
                return
            }
            guard let focused = terminals[selectedTabIndex].focusedPane else {
                Ghostty.logger.warning("closeSplit: no focused pane in tab \(selectedTabIndex)")
                return
            }
            tabIndex = selectedTabIndex
            paneToClose = focused
        }

        // tmux control mode: route a tmux PANE close to the tmux server. tmux
        // tears the pane down and emits a topology change; the reconcile's prune
        // removes the pane view (and the tab/window when it was the last pane).
        // Closing it locally would desync — the next reconcile would re-add it.
        // The gateway view has no tmuxPaneBinding, so it uses the normal path.
        if let terminalToClose = paneToClose.asTerminal, terminalToClose.isTmuxPane {
            // Whole-tab close: when this is the tmux window's ONLY pane, ⌘W is
            // closing the whole tab, so honor the user-configured close action
            // (kill-window / detach / hide / ask). A multi-pane window keeps the
            // per-pane kill-pane below. (id=tmux-tab-close-action)
            if let tab = terminals.first(where: { $0.splitTree.contains(where: { $0 === terminalToClose }) }),
               tab.isTmuxWindow,
               tab.splitTree.terminalLeaves.filter({ $0.isTmuxPane }).count == 1,
               handleTmuxWindowTabClose(tab) {
                return
            }
            terminalToClose.requestTmuxKillPane()
            return
        }

        // tmux -CC gateway: tear down the window tabs/panes it projected BEFORE this
        // gateway split's own teardown. forceQuit() prunes them while the controller +
        // surface are still live; if cleanup() (below) runs first it frees the surface
        // and nils tmuxController, and the surface-freed guard then suppresses the
        // in-band %exit reconcile that used to drive the prune — orphaning the window
        // tabs (the build-112 regression from 18e46b10). prune() mutates the tab array,
        // so re-resolve this gateway's tab index; all the index/count-derived state
        // below is computed after this point. Mirrors closeTab's gateway cascade.
        // Gated on hasProjectedWindows (not isActive) so a gateway closed mid
        // graceful-detach — when isActive is already false but window tabs still
        // exist — is pruned too. ROOTSHELL-TMUX (id=tmux-gateway-close-cascade)
        if let controller = paneToClose.asTerminal?.tmuxController, controller.hasProjectedWindows {
            controller.forceQuit()
            guard let reindexed = terminals.firstIndex(where: {
                $0.splitTree.contains(where: { $0 === paneToClose })
            }) else { return }
            tabIndex = reindexed
        }

        guard let root = terminals[tabIndex].splitTree.root else {
            Ghostty.logger.warning("closeSplit: no root in splitTree (tab \(tabIndex))")
            return
        }
        guard let currentNode = root.node(view: paneToClose) else {
            Ghostty.logger.warning("closeSplit: target pane not found in tree (tab \(tabIndex))")
            return
        }

        // Check if we're about to close the last split in the last tab
        let isLastSplitInTab = terminals[tabIndex].splitTree.count == 1
        let isLastTab = terminals.count == 1

        // Capture window scene BEFORE cleanup (cleanup may nil out references)
        let windowSceneToClose = isLastSplitInTab && isLastTab ? paneToClose.window?.windowScene : nil
        Ghostty.logger.info("closeSplit: tabIndex=\(tabIndex), isLastSplitInTab=\(isLastSplitInTab), isLastTab=\(isLastTab), capturedWindowScene=\(windowSceneToClose != nil)")

        // Find a logical neighbor to focus before removing the node
        // This ensures we focus the "other side" of the split that is disappearing
        var nextFocusTarget: SplitPaneView?

        if let neighbor = root.findNeighbor(of: currentNode) {
            // If we have a neighbor, focus its most relevant leaf (e.g. leftmost)
            // We could be smarter here based on direction, but leftmost is a reasonable default
            nextFocusTarget = neighbor.leftmostLeaf()
            Ghostty.logger.info("Found neighbor for closed split: \(String(describing: neighbor)), target view: \(nextFocusTarget?.uuid.uuidString ?? "nil")")
        } else {
            Ghostty.logger.warning("No neighbor found for closed split")
        }

        // Resign first responder before cleanup (cleanup sets surface to nil,
        // which causes focusDidChange(false) to bail early without resigning)
        if paneToClose.isFirstResponder {
            paneToClose.resignFirstResponder()
        }
        paneToClose.isLogicallyFocused = false

        // Cleanup the pane being closed BEFORE removing from tree. Terminals
        // keep their user-close semantics (plus withdrawing any pending
        // keyboard-interactive prompt so its auth future doesn't park until
        // the login timeout); other panes take the generic close funnel.
        if let terminalToClose = paneToClose.asTerminal {
            withdrawKeyboardInteractive(for: terminalToClose)
            terminalToClose.cleanup(reason: .userClose)
        } else {
            paneToClose.prepareForClose()
        }

        let newTree = terminals[tabIndex].splitTree.remove(currentNode)

        // Cascading close logic: split → tab → window
        if newTree.isEmpty {
            // Tree is empty after removing the split
            if isLastSplitInTab && isLastTab {
                #if targetEnvironment(macCatalyst)
                #if STANDALONE
                if windowId == "visor" {
                    // The visor is a persistent panel. When its last shell
                    // exits, replace it with a fresh local shell instead of
                    // dismissing the scene or leaving an empty transparent
                    // panel.
                    Ghostty.logger.info("Closing last split in visor - creating replacement shell")
                    closeTab(at: tabIndex)
                    Task { @MainActor in
                        _ = await ensureVisorHasTerminal()
                    }
                } else {
                    // Mac Catalyst: closing last window is standard macOS behavior
                    // (app stays in Dock, user reopens from menu bar)
                    Ghostty.logger.info("Closing last split in last tab - closing window (Mac Catalyst)")
                    closeCurrentWindow(windowScene: windowSceneToClose)
                }
                #else
                // Mac Catalyst: closing last window is standard macOS behavior
                // (app stays in Dock, user reopens from menu bar)
                Ghostty.logger.info("Closing last split in last tab - closing window (Mac Catalyst)")
                closeCurrentWindow(windowScene: windowSceneToClose)
                #endif
                #else
                // iOS/iPadOS/visionOS: check if this is the only window scene.
                // Destroying the sole scene leaves no visible UI and no recovery path.
                let windowSceneCount = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .count
                if windowSceneCount > 1 {
                    Ghostty.logger.info("Closing last split in last tab - closing window (\(windowSceneCount) scenes)")
                    closeCurrentWindow(windowScene: windowSceneToClose)
                } else {
                    Ghostty.logger.info("Closing last split in last tab - showing connection sheet (single scene)")
                    closeTab(at: tabIndex)
                }
                #endif
            } else {
                // Multiple tabs exist - just close this tab
                // Note: closeTab() handles focus restoration internally via setFocusedTerminal
                closeTab(at: tabIndex)
            }
        } else {
            terminals[tabIndex].splitTree = newTree

            // Determine the new focused split for this tab.
            //
            // If the dying split was NOT the tab's focused split and the
            // currently focused split still exists in the new tree, preserve
            // it. Only fall back to neighbor / first-leaf when the focused
            // split is the one being closed (or was nil to begin with).
            // Otherwise an async close on a non-focused split would yank
            // focus to the dying split's neighbor — wrong in the active tab
            // (steals the user's focus) and wrong in a background tab
            // (overwrites the remembered focus the user will return to).
            let currentFocused = terminals[tabIndex].focusedPane
            let newFocus: SplitPaneView?
            if let currentFocused, currentFocused !== paneToClose, newTree.contains(currentFocused) {
                newFocus = currentFocused
            } else if let target = nextFocusTarget, newTree.contains(target) {
                newFocus = target
            } else if let firstView = newTree.first {
                Ghostty.logger.info("Neighbor target not found in new tree, falling back to first view: \(firstView.uuid.uuidString)")
                newFocus = firstView
            } else {
                Ghostty.logger.warning("New tree is not empty but has no first view? Tree size: \(newTree.count)")
                newFocus = nil
            }

            if tabIndex == selectedTabIndex {
                // Active tab: drive the full focus transfer (UIKit responder,
                // Ghostty focus, focusGeneration bump, async retry).
                // setFocusedPane short-circuits when newFocus === current
                // focused pane, so the no-change case is a true no-op.
                Ghostty.logger.info("Focusing target in active tab: \(newFocus?.uuid.uuidString ?? "nil")")
                setFocusedPane(newFocus, inTab: tabIndex)
            } else if newFocus !== currentFocused {
                // Background tab, and the focused-split pointer actually
                // changed (the dying split was the remembered focus): update
                // the pointer and re-target title observation only. Do NOT
                // touch isLogicallyFocused, first responder, or focusGeneration
                // — inactive tabs must keep isLogicallyFocused = false (the
                // invariant maintained by handleSelectedTabChange), and
                // stealing first responder would disrupt the visible tab.
                // When the user later switches to this tab,
                // handleSelectedTabChange reads the focused pane and performs
                // the full focus transfer.
                Ghostty.logger.info("Updating focused-split pointer in background tab \(tabIndex): \(newFocus?.uuid.uuidString ?? "nil")")
                terminals[tabIndex].focusedPane = newFocus
                setupTitleObservation(at: tabIndex)
            }
        }
    }

    /// Closes the current window/scene properly
    /// Pass the windowScene if available (capture before cleanup), otherwise falls back to active scene
    func closeCurrentWindow(windowScene: UIWindowScene? = nil) {
        Ghostty.logger.info("closeCurrentWindow called, passed windowScene: \(windowScene != nil)")

        let sceneToClose: UIWindowScene?

        if let scene = windowScene {
            sceneToClose = scene
            Ghostty.logger.info("Using passed windowScene")
        } else {
            // Fall back to finding the active foreground scene
            let allScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            Ghostty.logger.info("No windowScene passed, found \(allScenes.count) connected scenes")
            sceneToClose = allScenes.first { scene in
                scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
            }
        }

        guard let scene = sceneToClose else {
            Ghostty.logger.warning("Could not find window scene to close")
            return
        }

        Ghostty.logger.info("Requesting destruction of scene: \(scene.session.persistentIdentifier)")
        let options = UIWindowSceneDestructionRequestOptions()
        options.windowDismissalAnimation = .standard
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: options
        )
    }
}
