import UIKit

/// Same normalized triangular edge regions as Ghostty's macOS split drops.
enum PaneDropZone: CaseIterable, Equatable {
    case left, right, top, bottom

    static func calculate(at point: CGPoint, in bounds: CGRect) -> Self? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        let distance = min(x, 1 - x, y, 1 - y)
        if distance == x { return .left }
        if distance == 1 - x { return .right }
        if distance == y { return .top }
        return .bottom
    }

    var direction: SplitTree<SplitPaneView>.NewDirection {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .up
        case .bottom: .down
        }
    }

    func previewFrame(in bounds: CGRect) -> CGRect {
        switch self {
        case .left: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right: CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .top: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case .bottom: CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        }
    }

    /// Only integer pane IDs enter the control channel; never pane titles or text.
    func tmuxMoveCommand(source: Int, destination: Int) -> String? {
        guard source >= 0, destination >= 0, source != destination else { return nil }
        let flags: String
        switch self {
        case .left: flags = "-h -b"
        case .right: flags = "-h"
        case .top: flags = "-v -b"
        case .bottom: flags = "-v"
        }
        return "move-pane -d \(flags) -s %\(source) -t %\(destination)"
    }

    func tmuxMoveCommand(source: TmuxPaneMoveIdentity, destination: TmuxPaneMoveIdentity) -> String? {
        guard source.canMove(to: destination) else { return nil }
        return tmuxMoveCommand(source: source.paneID, destination: destination.paneID)
    }
}

struct TmuxPaneMoveIdentity {
    let ownerID: UUID
    let windowID: Int
    let paneID: Int

    func canMove(to destination: Self) -> Bool {
        ownerID == destination.ownerID && windowID == destination.windowID
            && windowID >= 0 && paneID >= 0 && destination.paneID >= 0 && paneID != destination.paneID
    }
}

/// herdr refuses a cross-tab swap, and a reconcile can rebind a pane's tab
/// while the drag is live, so the tab is part of the identity.
struct HerdrPaneMoveIdentity {
    let gatewayUUID: UUID
    let tabID: String
    let paneID: String

    func canSwap(with destination: Self) -> Bool {
        gatewayUUID == destination.gatewayUUID && tabID == destination.tabID
            && !paneID.isEmpty && !destination.paneID.isEmpty && paneID != destination.paneID
    }
}

/// How a drop commits. tmux and native trees insert the source at the dropped
/// edge; herdr has no same-tab insert primitive, so a herdr drop exchanges the
/// two panes and the zone is only a hit test.
enum PaneMoveKind: Equatable {
    case insert
    case swap
}

/// Shared by drag previews and the commit path. Never move a native leaf into a
/// server-owned tree, or a tmux pane between gateways/windows via a local edit.
@MainActor
enum PaneMoveEligibility {
    static func allows(_ source: SplitPaneView, _ destination: SplitPaneView) -> Bool {
        kind(source, destination) != nil
    }

    /// nil when the pair cannot be rearranged at all. herdr is resolved first:
    /// a herdr pane has no tmux binding, so it would otherwise pass as native
    /// and the drop would silently no-op against a server-owned tree.
    static func kind(_ source: SplitPaneView, _ destination: SplitPaneView) -> PaneMoveKind? {
        guard source !== destination,
              !source.isDetachedForFullScreen, !destination.isDetachedForFullScreen else { return nil }
        let sourceTerminal = source.asTerminal
        let destinationTerminal = destination.asTerminal
        switch (sourceTerminal?.herdrPaneBinding, destinationTerminal?.herdrPaneBinding) {
        case let (from?, to?):
            return allowsHerdrSwap(from, to) ? .swap : nil
        case (nil, nil):
            break
        // A herdr pane and a native or tmux pane never share a tree edit.
        default:
            return nil
        }
        switch (sourceTerminal?.tmuxPaneBinding, destinationTerminal?.tmuxPaneBinding) {
        case (nil, nil): return .insert
        case let (from?, to?): return allowsTmuxMove(from, to) ? .insert : nil
        default: return nil
        }
    }

    private static func allowsTmuxMove(
        _ source: Ghostty.TerminalView.TmuxPaneBinding,
        _ destination: Ghostty.TerminalView.TmuxPaneBinding
    ) -> Bool {
        let sourceID = TmuxPaneMoveIdentity(ownerID: source.parentUUID, windowID: source.windowId, paneID: source.paneId)
        let destinationID = TmuxPaneMoveIdentity(ownerID: destination.parentUUID, windowID: destination.windowId, paneID: destination.paneId)
        guard sourceID.canMove(to: destinationID),
              source.parentSurface == destination.parentSurface,
              let controller = TmuxController.controller(forOwnerSurface: source.parentSurface),
              controller.ownerTerminalUUIDForNotifications == source.parentUUID,
              controller.isActive else { return false }
        return true
    }

    private static func allowsHerdrSwap(
        _ source: Ghostty.TerminalView.HerdrPaneBinding,
        _ destination: Ghostty.TerminalView.HerdrPaneBinding
    ) -> Bool {
        let sourceID = HerdrPaneMoveIdentity(gatewayUUID: source.gatewayUUID, tabID: source.tabId, paneID: source.paneId)
        let destinationID = HerdrPaneMoveIdentity(gatewayUUID: destination.gatewayUUID, tabID: destination.tabId, paneID: destination.paneId)
        guard sourceID.canSwap(with: destinationID),
              let controller = HerdrController.controller(forGateway: source.gatewayUUID),
              controller.isActive, !controller.didEnd else { return false }
        return true
    }
}
