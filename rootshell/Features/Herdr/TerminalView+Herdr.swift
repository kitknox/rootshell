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
import UIKit

extension Ghostty.TerminalView {

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
        HerdrController.start(on: self, tabsModel: tabsModel, sessionName: sessionName)
    }

    /// Auto-start hook: a connection configured for herdr control mode gets
    /// its controller once the session is ready. The pty runs the user's
    /// shell; the control channel is separate, so a resumed tssh session
    /// starts it too.
    func startHerdrControlModeIfConfigured() {
        guard herdrController == nil,
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

    func requestHerdrSplit(_ direction: SplitTree<SplitPaneView>.NewDirection) {
        let horizontal: Bool
        switch direction {
        case .left, .right: horizontal = true
        case .up, .down: horizontal = false
        }
        herdrPaneController?.requestSplit(self, horizontal: horizontal)
    }

    /// Move the divider on this pane's `direction` edge outward by `cells`.
    /// The split host picks the pane that borders the dragged divider so
    /// herdr moves that divider and no other.
    func requestHerdrResizeEdge(direction: String, cells: Int) {
        herdrPaneController?.requestResize(self, direction: direction, cells: cells)
    }

    /// The split host laid out; the controller re-derives the tab's cell
    /// budget from the host's bounds.
    func noteHerdrHostLayout() {
        herdrPaneController?.hostLayoutDidChange(for: self)
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
        controller.requestNewTab(inWorkspaceOf: tab?.isHerdrWindow == true ? tab : nil)
        return true
    }
}
