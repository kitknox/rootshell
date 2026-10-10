//
//  TerminalView+Herdr.swift
//  rootshell
//
//  herdr control mode entry points on the terminal view: starting a
//  controller on a gateway and echoing user intent from a projected pane.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import SwiftUI
import UIKit
import GhosttyKit

extension Ghostty.TerminalView {

    func cancelHerdrReturnToLive() {
        guard let binding = herdrPaneBinding else { return }
        HerdrController.controller(forGateway: binding.gatewayUUID)?
            .cancelReturnToLive(terminalID: binding.terminalId)
    }

    /// An activation is still waiting to put this pane back at live output.
    var hasPendingHerdrReturnToLive: Bool {
        guard let binding = herdrPaneBinding,
              let controller = HerdrController.controller(forGateway: binding.gatewayUUID) else { return false }
        return controller.isReturningToLive(terminalID: binding.terminalId)
    }

    /// Touch state, handles, and the stale highlight are device concerns; a
    /// Mac keeps its selection, which the user may still be about to copy.
    func prepareHerdrReturnToLive() {
        #if !targetEnvironment(macCatalyst)
        clearTouchState()
        selectionMouseDragActive = false
        selectionWasTouchInitiated = false
        hideSelectionHandles(animated: false)
        hideSelectionMagnifier(animated: false)
        // A local selection click clears the old highlight. Never synthesize
        // a mouse event into an application that has enabled mouse reporting.
        if let surface, hasTerminalTextSelection, !isMouseCaptured {
            ghostty_surface_mouse_pos(surface, 0, 0, Ghostty.Input.Mods.none.cMods)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Ghostty.Input.Mods.none.cMods)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Ghostty.Input.Mods.none.cMods)
        }
        #endif
        _ = cancelMomentumScrolling()
        enclosingTerminalScrollView?.prepareHerdrReturnToLive()
    }

    func finishHerdrReturnToLive() {
        _ = cancelMomentumScrolling()
        enclosingTerminalScrollView?.prepareHerdrReturnToLive()
        // Let the next core scrollbar sample synchronize UIKit. Sending a
        // scroll_to_row based on a pre-replay sample would undo this jump.
        _ = performAction("scroll_to_bottom")
    }


    /// The card is a plain hosted subview: the gateway terminal keeps first
    /// responder, its keyboard, and its gestures. Installed lazily so a
    /// gateway restored into a hidden tab never lays out until it is shown,
    /// and never before the initial attach has chosen its tab.
    func updateHerdrGatewayOverlay() {
        guard let controller = herdrController, controller.showsGatewayStatus else {
            herdrGatewayHost?.willMove(toParent: nil)
            herdrGatewayHost?.view.removeFromSuperview()
            herdrGatewayHost?.removeFromParent()
            herdrGatewayHost = nil
            rendererLayer?.isHidden = false
            return
        }
        if herdrGatewayHost == nil {
            // Occlusion trails selection by a SwiftUI pass; the selected-tab
            // check keeps the card off a gateway that was just left.
            guard isTabVisible, window != nil, !bounds.isEmpty,
                  !controller.holdsGatewayCardForInitialReveal,
                  controller.tabsModel.selectedTabID == containingTabID else { return }
        }
        #if targetEnvironment(macCatalyst)
        // Installing the overlay need not produce a hover exit. Release any
        // terminal cursor immediately, including while the mouse is stationary.
        clearCursorRegistration()
        #endif
        let content = HerdrGatewayView(
            tabID: containingTabID,
            windowID: windowId,
            sessionName: controller.sessionName ?? "default",
            hasSnapshot: controller.hasProcessedInitialSnapshot,
            hasTabs: !controller.tabs.isEmpty,
            isActive: controller.isActive,
            isCreating: controller.emptySessionCreationID != nil,
            errorMessage: controller.newTabError ?? controller.connectionError,
            upgrade: controller.upgradePrompt,
            isFallbackForced: controller.mode == .legacy && controller.legacyFallbackForced,
            otherClients: controller.otherConnections.map(\.displayLabel),
            workspaces: { [weak controller] in controller?.showWorkspaceOverview() },
            newTab: { [weak controller] in controller?.requestNewTab(workspaceID: nil) },
            retryConnection: { [weak controller] in controller?.applicationDidBecomeActive() },
            detach: { [weak controller] in controller?.detach(closeGateway: false) },
            typeIntoShell: { [weak self, weak controller] command in
                // The shell must be visible to see what was typed; nothing is
                // sent until the user presses Return.
                controller?.detach(closeGateway: false)
                self?.sendUserInput(Data(command.utf8))
            }
        )
        // Split-host and tab-switch animations may be in flight; the card
        // must snap into place, never slide or grow.
        // The card is translucent like the terminal; the shell must not show through.
        rendererLayer?.isHidden = true
        UIView.performWithoutAnimation {
            if let host = herdrGatewayHost {
                host.rootView = content
                return
            }
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            var responder: UIResponder? = next
            while responder != nil, !(responder is UIViewController) { responder = responder?.next }
            let parent = responder as? UIViewController
            parent?.addChild(host)
            addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.view.topAnchor.constraint(equalTo: topAnchor),
                host.view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            host.didMove(toParent: parent)
            host.view.layoutIfNeeded()
            herdrGatewayHost = host
        }
    }

    /// A pane another client holds keeps its last screen under a dimmed card
    /// with Take Control. Installed and removed by the controller as the
    /// pane's control state changes.
    func updateHerdrPaneControlOverlay() {
        guard let binding = herdrPaneBinding,
              let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
              let state = controller.paneControlStates[binding.terminalId] else {
            herdrPaneControlHost?.willMove(toParent: nil)
            herdrPaneControlHost?.view.removeFromSuperview()
            herdrPaneControlHost?.removeFromParent()
            herdrPaneControlHost = nil
            return
        }
        let tabId = binding.tabId
        let content = HerdrPaneControlOverlay(
            state: state,
            offersUpgrade: !controller.capabilities.supportsSharedViewing,
            takeControl: { [weak controller] in controller?.requestTakeControl(tabId: tabId) },
            showUpgrade: { [weak controller] in controller?.presentUpgradeAlert(.sharedViewingNeedsUpgrade) }
        )
        UIView.performWithoutAnimation {
            if let host = herdrPaneControlHost {
                host.rootView = content
                return
            }
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            var responder: UIResponder? = next
            while responder != nil, !(responder is UIViewController) { responder = responder?.next }
            let parent = responder as? UIViewController
            parent?.addChild(host)
            addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.view.topAnchor.constraint(equalTo: topAnchor),
                host.view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            host.didMove(toParent: parent)
            herdrPaneControlHost = host
        }
    }

    var supportsHerdrPaneGeometry: Bool {
        herdrPaneController?.mode == .raw && herdrPaneController?.capabilities.supports(.paneGeometry) == true
    }

    /// Cells the tab really has when another client sized it; the split host
    /// lays the tree out in that rectangle instead of our container.
    var herdrForeignAreaCells: (cols: Int, rows: Int)? {
        herdrPaneController?.foreignAreaCells(for: self)
    }

    /// Pin the raw v2 renderer and split positions to the committed server
    /// grid while the host independently negotiates its new viewport size.
    var herdrCommittedAreaCells: (cols: Int, rows: Int)? {
        guard let controller = herdrPaneController, controller.mode == .raw,
              controller.capabilities.supportsSharedViewing, herdrTargetGrid != nil,
              let tabID = herdrPaneBinding?.tabId,
              let layout = controller.controlLayouts[tabID] else { return nil }
        return (cols: layout.area.width, rows: layout.area.height)
    }

    /// Bare ESC on the covered gateway leaves control mode, like the tmux
    /// gateway. Panes and unrelated splits have no controller and are unaffected.
    @discardableResult
    func detachHerdrGatewayIfCovered() -> Bool {
        guard let controller = herdrController, controller.showsGatewayStatus else { return false }
        controller.detach(closeGateway: false)
        return true
    }

    /// Gestures that navigate tabs or the app stay live over the card; the
    /// rest would click, select, or scroll a shell the user cannot see.
    func herdrGatewayAllowsGesture(_ gesture: UIGestureRecognizer) -> Bool {
        if isTrackpadTabSwipeGesture(gesture) { return true }
        #if !targetEnvironment(macCatalyst)
        return gesture === appTabSwipePanGesture
            || gesture === tabSwipeLeftGesture
            || gesture === tabSwipeRightGesture
            || gesture === twoFingerTapGesture
            || gesture === twoFingerLongPressGesture
            || gesture === pinchZoomGesture
        #else
        return false
        #endif
    }

    /// Fixed space outside the grid. TerminalScrollView pins the terminal to
    /// its full viewport on both platforms, so it adds no wrapper inset.
    /// Fractional space left after fitting cells belongs to the viewport,
    /// never to this padding budget.
    var herdrLayoutChrome: CGSize {
        let scale = contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale
        return HerdrGeometry.chrome(
            paddingX: PaddingManager.shared.effectivePaddingX,
            paddingY: PaddingManager.shared.effectivePaddingY,
            scale: scale,
            bottomInsetPixels: currentBottomInsetPixels()
        )
    }

    /// Scroll the server viewport when the child has not requested the mouse.
    /// Captured applications use Ghostty's usual protocol encoding instead.
    func sendHerdrFallbackScroll(deltaY: CGFloat, at point: CGPoint) {
        guard let pane = session as? HerdrPaneSession,
              let stream = pane.controller?.legacyStreams[pane.terminalId],
              let size = surfaceSize,
              size.columns > 0, size.rows > 0,
              size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        let scale = Double(contentScaleFactor)
        let cellWidth = Double(size.cell_width_px) / scale
        let cellHeight = Double(size.cell_height_px) / scale
        let steps = herdrFallbackScroll.consume(delta: Double(deltaY), cellHeight: cellHeight)
        guard steps != 0 else { return }
        let padding = PaddingManager.shared.configPadding()
        stream.sendScroll(
            steps: steps,
            column: min(Int(size.columns), Int(max(0, Double(point.x) - Double(padding.x)) / cellWidth) + 1),
            row: min(Int(size.rows), Int(max(0, Double(point.y) - Double(padding.y)) / cellHeight) + 1)
        )
    }

    /// Whether this terminal can carry a herdr control stream: the same raw
    /// byte transports that allow tmux -CC.
    var allowsHerdrControlDiscoveryAttach: Bool { allowsTmuxControlDiscoveryAttach }

    /// Turns this view into a herdr control-mode gateway for `sessionName`
    /// (nil attaches to herdr's default session). Idempotent.
    func startHerdrControlMode(sessionName: String?) {
        guard allowsHerdrControlDiscoveryAttach,
              let tabsModel = TmuxWindowRegistry.tabsModel(for: windowId) else { return }
        herdrAutoAttachSuppressed = false
        HerdrController.start(on: self, tabsModel: tabsModel, sessionName: sessionName)
    }

    /// Auto-start hook: a connection configured for herdr control mode gets
    /// its controller once the session is ready. The pty runs the user's
    /// shell; the control channel is separate, so a resumed tssh session
    /// starts it too.
    func startHerdrControlModeIfConfigured() {
        guard herdrController == nil, !herdrAutoAttachSuppressed,
              let sshConfig = connectionConfig.sshConfigForHistory,
              sshConfig.herdrControlModeEnabled else { return }
        if let remoteCommand = sshConfig.remoteCommand, !remoteCommand.isEmpty { return }
        startHerdrControlMode(sessionName: sshConfig.herdrSessionNameForConnection)
    }

    private var herdrPaneController: HerdrController? {
        guard let binding = herdrPaneBinding else { return nil }
        return HerdrController.controller(forGateway: binding.gatewayUUID)
    }

    /// User focus landed on this pane: make it herdr's focused pane too.
    /// Programmatic focus paths never call this (they would oscillate focus
    /// between two attached clients).
    func requestHerdrSelectPane() {
        herdrPaneController?.requestSelectPane(self)
    }

    /// herdr only splits right/down; left/up land on the same axis.
    func requestHerdrSplit(_ direction: SplitTree<SplitPaneView>.NewDirection, cwd: String? = nil) {
        let horizontal: Bool
        switch direction {
        case .left, .right: horizontal = true
        case .up, .down: horizontal = false
        }
        herdrPaneController?.requestSplit(self, horizontal: horizontal, cwd: cwd)
    }

    /// Move the divider on this pane's `direction` edge outward by `cells`.
    /// The split host picks the pane that borders the dragged divider so
    /// herdr moves that divider and no other.
    func requestHerdrResizeEdge(direction: String, cells: Int) {
        herdrPaneController?.noteDividerDrag(in: self)
        herdrPaneController?.requestResize(self, direction: direction, cells: cells)
    }

    func requestHerdrFitToWindow() {
        guard let tabID = containingTabID, let tab = herdrPaneController?.tabsModel.tab(withID: tabID) else { return }
        herdrPaneController?.requestFitToWindow(tab)
    }

    /// The split host laid out; the controller re-derives the tab's cell
    /// budget from the host's bounds.
    func noteHerdrHostLayout() {
        herdrPaneController?.hostLayoutDidChange(for: self)
    }

    func refreshHerdrLayoutForSurfaceMetrics() {
        herdrPaneController?.refreshLayoutForSurfaceMetrics(from: self)
    }

    func requestHerdrToggleZoom() {
        herdrPaneController?.requestToggleZoom(self)
    }

    func requestHerdrClosePane() {
        herdrPaneController?.requestClosePane(self)
    }

    /// New tab from a pane or the gateway; lands in the pane's workspace.
    func requestHerdrNewTab() -> Bool {
        let controller = herdrPaneController ?? herdrController
        guard let controller, controller.isActive else { return false }
        let tab = containingTabID.flatMap { controller.tabsModel.tab(withID: $0) }
        return controller.requestNewTab(inWorkspaceOf: tab?.isHerdrWindow == true ? tab : nil)
    }
}
