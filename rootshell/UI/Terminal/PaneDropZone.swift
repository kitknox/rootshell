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

/// Shared by drag previews and the commit path. Never move a native leaf into a
/// server-owned tree, or a tmux pane between gateways/windows via a local edit.
@MainActor
enum PaneMoveEligibility {
    static func allows(_ source: SplitPaneView, _ destination: SplitPaneView) -> Bool {
        guard source !== destination,
              !source.isDetachedForFullScreen, !destination.isDetachedForFullScreen else { return false }
        switch (source.asTerminal?.tmuxPaneBinding, destination.asTerminal?.tmuxPaneBinding) {
        case (nil, nil): return true
        case let (source?, destination?):
            let sourceID = TmuxPaneMoveIdentity(ownerID: source.parentUUID, windowID: source.windowId, paneID: source.paneId)
            let destinationID = TmuxPaneMoveIdentity(ownerID: destination.parentUUID, windowID: destination.windowId, paneID: destination.paneId)
            guard sourceID.canMove(to: destinationID),
                  source.parentSurface == destination.parentSurface,
                  let controller = TmuxController.controller(forOwnerSurface: source.parentSurface),
                  controller.ownerTerminalUUIDForNotifications == source.parentUUID,
                  controller.isActive else { return false }
            return true
        default: return false
        }
    }
}
