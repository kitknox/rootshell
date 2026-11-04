//
//  TmuxController.swift
//  rootshell
//
//  Decodes Ghostty's tmux control-mode reconcile op batches
//  (GHOSTTY_ACTION_TMUX_RECONCILE) and applies them to native tabs and splits.
//
//  The batch holds raw viewer pointers kept alive by the payload's refcount
//  (Zig id=viewer-snapshot-refcount); free it only after applyTmuxReconcile.
//

import Foundation
import GhosttyKit
import os

private extension SSHConfig {
    var tmuxGatewaySourceDisplayName: String {
        let userHost = "\(username)@\(host)"
        return port == 22 ? userHost : "\(userHost):\(port)"
    }
}

private extension ConnectionConfig {
    var tmuxGatewaySourceDisplayName: String {
        if let ssh = underlyingSSHConfig {
            return ssh.tmuxGatewaySourceDisplayName
        }
        return displayName
    }

    var tmuxGatewaySourceSystemImage: String {
        switch unwrappedConfig {
        case .local:
            return "terminal"
        case .ssh:
            return "server.rack"
        case .mosh:
            return "antenna.radiowaves.left.and.right"
        case .trzsz, .trzszTransfer:
            return "arrow.triangle.2.circlepath"
        case .kubernetes:
            return "shippingbox"
        case .console, .ec2Console:
            return "terminal"
        case .shellLaunchedSSH, .shellLaunchedMosh, .shellLaunchedTrzsz:
            return "server.rack"
        case .vnc:
            return "display"
        }
    }
}

/// A single tmux reconcile operation, decoded from the C op batch.
/// `nonisolated` because it is produced on the off-main action callback thread.
nonisolated enum TmuxReconcileOp: Equatable {
    case syncBegin
    /// Dimensions in cells; `index` is the tmux window index, used for tab order.
    case ensureWindow(windowId: Int, width: Int, height: Int, index: Int)
    /// The viewer pointers are passed to ghostty_surface_new_tmux_pane.
    case ensurePane(windowId: Int, paneId: Int, viewerTerminal: UnsafeMutableRawPointer?, viewerPane: UnsafeMutableRawPointer?)
    /// `zoomedPaneId` is nil when not zoomed; not a 0 sentinel since `%0` is real (id=tmux-zoom).
    case setLayout(windowId: Int, layout: TmuxLayoutNode, zoomedPaneId: Int?)
    case setFocus(windowId: Int, paneId: Int)
    /// Remove any windows/panes whose IDs are not in these sorted sets.
    case pruneAbsent(windowIds: [Int], paneIds: [Int])
    case syncEnd
    /// tmux window rename.
    case setTabTitle(windowId: Int, title: String)
    /// tmux session rename.
    case setWindowTitle(title: String)

    static func == (lhs: TmuxReconcileOp, rhs: TmuxReconcileOp) -> Bool {
        switch (lhs, rhs) {
        case (.syncBegin, .syncBegin), (.syncEnd, .syncEnd): return true
        case let (.ensureWindow(a, b, c, g), .ensureWindow(d, e, f, h)): return a == d && b == e && c == f && g == h
        case let (.ensurePane(a, b, _, _), .ensurePane(c, d, _, _)): return a == c && b == d
        case let (.setLayout(a, b, e), .setLayout(c, d, f)): return a == c && b == d && e == f
        case let (.setFocus(a, b), .setFocus(c, d)): return a == c && b == d
        case let (.pruneAbsent(a, b), .pruneAbsent(c, d)): return a == c && b == d
        case let (.setTabTitle(a, b), .setTabTitle(c, d)): return a == c && b == d
        case let (.setWindowTitle(a), .setWindowTitle(b)): return a == b
        default: return false
        }
    }
}

/// Stateless decoder for the reconcile op batch. `nonisolated` because it runs
/// synchronously on the core's off-main tick thread. Does not free the payload.
nonisolated enum TmuxReconcileDecoder {
    static func decode(_ payload: UnsafeMutableRawPointer) -> [TmuxReconcileOp] {
        let count = ghostty_tmux_reconcile_op_count(payload)
        var ops: [TmuxReconcileOp] = []
        ops.reserveCapacity(Int(count))

        var i: UInt = 0
        while i < count {
            defer { i += 1 }
            var cop = ghostty_tmux_op_s()
            guard ghostty_tmux_reconcile_op(payload, i, &cop) else { continue }

            switch cop.tag {
            case GHOSTTY_TMUX_OP_SYNC_BEGIN:
                ops.append(.syncBegin)
            case GHOSTTY_TMUX_OP_SYNC_END:
                ops.append(.syncEnd)
            case GHOSTTY_TMUX_OP_ENSURE_WINDOW:
                ops.append(.ensureWindow(
                    windowId: Int(cop.window_id),
                    width: Int(cop.width),
                    height: Int(cop.height),
                    index: Int(cop.window_index)))
            case GHOSTTY_TMUX_OP_ENSURE_PANE:
                ops.append(.ensurePane(
                    windowId: Int(cop.window_id),
                    paneId: Int(cop.pane_id),
                    viewerTerminal: cop.viewer_terminal,
                    viewerPane: cop.viewer_pane))
            case GHOSTTY_TMUX_OP_SET_LAYOUT:
                if let layout = cop.layout {
                    ops.append(.setLayout(
                        windowId: Int(cop.window_id),
                        layout: decodeLayout(layout),
                        zoomedPaneId: cop.has_zoomed_pane_id ? Int(cop.zoomed_pane_id) : nil))
                }
            case GHOSTTY_TMUX_OP_SET_FOCUS:
                ops.append(.setFocus(
                    windowId: Int(cop.window_id),
                    paneId: Int(cop.pane_id)))
            case GHOSTTY_TMUX_OP_PRUNE_ABSENT:
                ops.append(.pruneAbsent(
                    windowIds: decodeIds(cop.window_ids, cop.window_ids_len),
                    paneIds: decodeIds(cop.pane_ids, cop.pane_ids_len)))
            case GHOSTTY_TMUX_OP_SET_TAB_TITLE:
                ops.append(.setTabTitle(
                    windowId: Int(cop.window_id),
                    title: decodeString(cop.title, cop.title_len)))
            case GHOSTTY_TMUX_OP_SET_WINDOW_TITLE:
                ops.append(.setWindowTitle(
                    title: decodeString(cop.title, cop.title_len)))
            default:
                break
            }
        }
        return ops
    }

    private static func decodeLayout(_ layout: UnsafeRawPointer) -> TmuxLayoutNode {
        var info = ghostty_tmux_layout_info_s()
        ghostty_tmux_layout_info(layout, &info)
        let w = Int(info.width), h = Int(info.height), x = Int(info.x), y = Int(info.y)

        switch info.kind {
        case GHOSTTY_TMUX_LAYOUT_PANE:
            return .pane(paneId: Int(info.pane_id), width: w, height: h, x: x, y: y)
        case GHOSTTY_TMUX_LAYOUT_HORIZONTAL, GHOSTTY_TMUX_LAYOUT_VERTICAL:
            let direction: TmuxLayoutNode.Direction =
                info.kind == GHOSTTY_TMUX_LAYOUT_HORIZONTAL ? .horizontal : .vertical
            var children: [TmuxLayoutNode] = []
            children.reserveCapacity(Int(info.child_count))
            var c: UInt = 0
            while c < info.child_count {
                if let child = ghostty_tmux_layout_child(layout, c) {
                    children.append(decodeLayout(child))
                }
                c += 1
            }
            return .split(direction: direction, children: children, width: w, height: h, x: x, y: y)
        default:
            // Unknown kind: treat as an empty leaf so reconciliation can proceed.
            return .pane(paneId: Int(info.pane_id), width: w, height: h, x: x, y: y)
        }
    }

    private static func decodeIds(_ ptr: UnsafePointer<UInt>?, _ len: UInt) -> [Int] {
        guard let ptr, len > 0 else { return [] }
        return (0..<Int(len)).map { Int(ptr[$0]) }
    }

    private static func decodeString(_ ptr: UnsafePointer<CChar>?, _ len: UInt) -> String {
        guard let ptr, len > 0 else { return "" }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: Int(len)), as: UTF8.self)
        }
    }
}

import UIKit

/// Applies reconcile op batches to native tabs and splits for one control-mode
/// connection. Owned by the gateway `Ghostty.TerminalView`.
@MainActor
final class TmuxController {
    /// Identifies this live gateway generation, even if its terminal UUID is reused.
    let connectionInfoID = UUID()
    private(set) var connectionInfoSessionRevision: UInt64 = 0

    func invalidateConnectionInfoSession() {
        connectionInfoSessionRevision &+= 1
    }

    /// Guard the native surface immediately before sampling; a sheet can outlive it.
    func connectionInfoCounters() -> TmuxConnectionSnapshot.Counters? {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return nil }
        var snapshot = ghostty_tmux_debug_snapshot_s()
        guard ghostty_surface_tmux_debug_snapshot(ownerSurface, &snapshot) else { return nil }
        return .init(receivedBytes: snapshot.abi_version >= 2 ? snapshot.gw_tmux_put_bytes : nil,
                     outputEvents: snapshot.total_output_events,
                     notifications: snapshot.total_notifications)
    }

    private final class WeakController {
        weak var controller: TmuxController?
        init(_ controller: TmuxController) { self.controller = controller }
    }

    private struct PendingSplitFocus {
        let existingPaneIds: Set<Int>
    }

    private static var controllersByOwnerSurface: [Int: WeakController] = [:]

    /// Weak to break the tabsModel -> gateway view -> controller cycle. The model
    /// transitively owns this controller, so it is never nil outside `deinit`.
    private weak var weakTabsModel: TabsModel?
    private var tabsModel: TabsModel {
        guard let model = weakTabsModel else {
            preconditionFailure("TmuxController.tabsModel accessed after its TabsModel was released")
        }
        return model
    }
    private let app: ghostty_app_t
    private weak var ghosttyApp: Ghostty.App?
    /// The surface running `tmux -CC`; parent of every child pane surface.
    private let ownerSurface: ghostty_surface_t
    private var baseWindowId: String
    /// Stamped onto window tabs so restored placeholders match this gateway
    /// (the terminal UUID survives restore; the tab UUID does not).
    private let ownerTerminalUUID: UUID
    /// Per-lifetime key, not the terminal UUID, so a late deinit of an old
    /// controller can't unregister its replacement.
    private let contentEventInterestID = UUID()
    /// Balanced against the Ghostty.App content-event owner registration.
    private var holdsContentEventInterest = true

    /// tmux window id -> the tab modeling it.
    private var windowTabs: [Int: TabModel] = [:]
    /// tmux window id -> rootshell app window id hosting that projected tab.
    private var windowHostIds: [Int: String] = [:]
    /// tmux pane id -> the pane view rendering it.
    private var paneViews: [Int: Ghostty.TerminalView] = [:]
    /// Throttles all-pane title queries; tmux only publishes the active pane's #T.
    private var paneIdentityRefreshTask: Task<Void, Never>?
    /// tmux window id -> pane ids present when we requested a split, so the
    /// layout reconcile can focus the new pane without `%window-pane-changed`.
    private var pendingSplitFocus: [Int: PendingSplitFocus] = [:]
    private var pendingSplitFocusExpiry: [Int: Task<Void, Never>] = [:]
    /// ROOTSHELL-TMUX (id=tmux-focus-watchdog)
    private var focusWatchdog: Task<Void, Never>?
    /// Set once every tmux window is pruned (tmux exited or detached).
    private(set) var didEnd = false
    /// Captured in `markGatewayTab` so detach can reselect it without relying on
    /// `isTmuxGateway`, which resume can clear and multiple gateways make ambiguous.
    private var gatewayTabID: UUID?
    /// Initial attach focus may select a window only while this gateway is selected.
    private var hasProcessedInitialFocus = false

    // MARK: - Session dashboard state (see TmuxController+Sessions.swift)

    /// Set only by updateCurrentSession in TmuxController+Sessions.swift.
    var currentSessionId: Int?
    var currentSessionName: String?
    /// "user@host:port" key for the last-session-name store; nil for local shells.
    var connectionKey: String?
    private(set) var gatewaySourceDisplayName = String(localized: "Gateway")
    private(set) var gatewaySourceSystemImage = "terminal"
    /// Identifies this tmux server lifetime; combined with pane IDs for push routing.
    var pushRouteServerIdentity: String?
    var configuredResumeSocket: TmuxSocketIdentity?
    var startupResumeSocket: TmuxSocketIdentity?
    var resumeSocket: TmuxSocketIdentity? {
        pushRouteServerIdentity.flatMap(TmuxSocketIdentity.fromServerIdentity) ?? startupResumeSocket
    }
    var pushRouteServerIdentityTask: Task<Void, Never>?
    /// Tag 0 is never used.
    var nextReplyTag: UInt32 = 1
    var pendingReplies: [UInt32: CheckedContinuation<TmuxCommandReply, any Error>] = [:]
    var replyTimeouts: [UInt32: Task<Void, Never>] = [:]
    /// ROOTSHELL-TMUX (id=tmux-focus-echo-gate)
    var localFocusGate = TmuxLocalFocusGate()
    /// Last `list-sessions` result, read synchronously by context menus.
    var cachedSessions: [TmuxControlSession] = []
    /// Mirrors the attached session's `@hidden` option; reloaded on attach/switch.
    var hiddenWindowIds: Set<Int> = []
    /// Armed by a local session switch so its focus op is treated like initial
    /// attach. Expires so a failed switch can't leave it armed.
    var pendingSessionSwitch = false
    var pendingSessionSwitchExpiry: Task<Void, Never>?
    private var pendingSessionSwitchWindowSelection: Int?

    var gatewaySurfaceForCommands: ghostty_surface_t { ownerSurface }
    var ownerTerminalUUIDForNotifications: UUID { ownerTerminalUUID }

    func noteSessionSwitchRequest(selectingWindowId windowId: Int? = nil) {
        pendingSessionSwitch = true
        pendingSessionSwitchWindowSelection = windowId
        pendingSessionSwitchExpiry?.cancel()
        pendingSessionSwitchExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.pendingSessionSwitch = false
            self.pendingSessionSwitchWindowSelection = nil
            self.pendingSessionSwitchExpiry = nil
        }
    }

    private func consumePendingSessionSwitch() -> Bool {
        guard pendingSessionSwitch else { return false }
        pendingSessionSwitch = false
        pendingSessionSwitchWindowSelection = nil
        pendingSessionSwitchExpiry?.cancel()
        pendingSessionSwitchExpiry = nil
        return true
    }

    func updateGatewaySource(from config: ConnectionConfig) {
        gatewaySourceDisplayName = config.tmuxGatewaySourceDisplayName
        gatewaySourceSystemImage = config.tmuxGatewaySourceSystemImage
    }

    // MARK: - Debug heartbeat (tmux control-mode debug log)

    /// Runs only while debug logging is enabled.
    private var heartbeat: Task<Void, Never>?
    private var debugToggleObserver: NSObjectProtocol?
    private var lastReconcileAt: Date?
    private var lastCommandAt: Date?
    private var reconcileCount = 0
    /// Last applied full-topology batch, for skipping identical re-emits.
    /// ROOTSHELL-TMUX (id=tmux-reconcile-dedup)
    private var lastAppliedTopologyOps: [TmuxReconcileOp]?
    private var skippedDuplicateReconciles = 0
    private var equalizingWindows: Set<Int> = []
    private var paneZoomSelectionWindows: Set<Int> = []

    // MARK: - Recovery watchdog (always-on)

    /// Always-on: drives `ghostty_surface_tmux_recover` when the command pipeline
    /// wedges (e.g. tsshd buffer overflow while backgrounded).
    private var recoveryWatchdog: Task<Void, Never>?
    private var recoveryWedgeHits = 0
    private var recoveryCooldownUntil: Date?
    /// Past the cap we force-exit control mode instead of looping.
    private var recoveryAttempts = 0
    /// Stops the watchdog acting while the force-exit teardown is in flight.
    private var recoveryGaveUp = false
    /// Foreground-only; reset every backgrounded tick since the watchdog keeps
    /// ticking in background. ROOTSHELL-TMUX (id=tmux-blackout-escalation, id=tmux-bg-escalation-guard)
    private var recoveryBlackoutTicks = 0
    /// Holds off escalation after foregrounding so buffered replies can arrive.
    /// ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private var recoveryForegroundGraceUntil: Date?
    /// A change means we backgrounded since the last foreground tick, even if no
    /// backgrounded tick ran. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private var recoveryLastForegroundBackgroundEpoch: UInt64 = 0
    /// Forces the foreground grace when seeded while already backgrounded.
    /// ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private var recoveryArmGraceOnNextForeground = false
    /// Single shared re-probe budget; re-probing is what re-arms `probe_echo`.
    /// ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private var recoveryResyncReprobes = 0
    /// ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private var recoveryResyncLastProbeAt: Date?
    /// Bytes arrived with no protocol progress: dead shell rather than silence.
    /// ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryResyncSawUnparsedBytes = false
    /// Re-baselined on background/grace transitions. ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryLastTmuxPutBytes: UInt64?
    /// Any advance proves the remote speaks the control protocol.
    /// ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryLastProtocolEvents: UInt64?
    /// `ownerSurface` is dangling once set; guard every ghostty_surface_* call.
    /// ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
    private(set) var ownerSurfaceFreed = false

    private var windowCloseState = TmuxWindowCloseState()

    /// Whether ESC on the gateway should detach.
    var isActive: Bool { !isDetaching && !windowTabs.isEmpty }

    /// Unlike `isActive`, stays true while detaching, so a gateway close before
    /// `%exit` still prunes. ROOTSHELL-TMUX (id=tmux-gateway-close-cascade)
    var hasProjectedWindows: Bool { !windowTabs.isEmpty }

    /// Blocks new tmux commands after `detach-client`; they would land in the shell.
    private(set) var isDetaching = false

    /// Close the gateway tab instead of reselecting it on `%exit`. (id=tmux-tab-close-action)
    var closeGatewayTabAfterDetach = false

    init(
        tabsModel: TabsModel,
        app: ghostty_app_t,
        ghosttyApp: Ghostty.App,
        ownerSurface: ghostty_surface_t,
        windowId: String,
        ownerTerminalUUID: UUID
    ) {
        self.weakTabsModel = tabsModel
        self.app = app
        self.ghosttyApp = ghosttyApp
        self.ownerSurface = ownerSurface
        self.baseWindowId = windowId
        self.ownerTerminalUUID = ownerTerminalUUID

        Self.controllersByOwnerSurface[Int(bitPattern: ownerSurface)] = WeakController(self)
        ghosttyApp.setTmuxSurfaceContentEventsEnabled(
            true,
            interestID: contentEventInterestID)

        // Capture the Sendable key, not self, and resolve through the registry.
        let key = Int(bitPattern: ownerSurface)
        debugToggleObserver = NotificationCenter.default.addObserver(
            forName: TmuxDebugLogger.enabledDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.controllersByOwnerSurface[key]?.controller?.onDebugLoggingChanged()
            }
        }

        startRecoveryWatchdog()
    }

    private func hostWindowId(forWindowId windowId: Int) -> String {
        windowHostIds[windowId] ?? windowTabs[windowId]?.windowId ?? baseWindowId
    }

    private func hostTabsModel(forWindowId windowId: Int) -> TabsModel {
        let hostId = hostWindowId(forWindowId: windowId)
        return TmuxWindowRegistry.tabsModel(for: hostId)
            ?? TerminalWindowRegistry.tabsModel(for: hostId)
            ?? tabsModel
    }

    private func setHostWindowId(_ appWindowId: String, forWindowId windowId: Int) {
        windowHostIds[windowId] = appWindowId
    }

    private func modelContainingTab(id tabID: UUID) -> TabsModel? {
        if weakTabsModel?.tab(withID: tabID) != nil {
            return weakTabsModel
        }
        let hostIds = Set(windowHostIds.values + [baseWindowId])
        for hostId in hostIds {
            if let model = TmuxWindowRegistry.tabsModel(for: hostId),
               model.tab(withID: tabID) != nil {
                return model
            }
            if let model = TerminalWindowRegistry.tabsModel(for: hostId),
               model.tab(withID: tabID) != nil {
                return model
            }
        }
        return nil
    }

    func noteGatewayMoved(toAppWindowId appWindowId: String) {
        baseWindowId = appWindowId
        weakTabsModel = TmuxWindowRegistry.tabsModel(for: appWindowId)
            ?? TerminalWindowRegistry.tabsModel(for: appWindowId)
            ?? weakTabsModel
    }

    static func noteWindowTabMoved(_ tab: TabModel, tmuxWindowId: Int, toAppWindowId appWindowId: String) {
        guard let view = tab.splitTree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let binding = view.tmuxPaneBinding,
              let controller = Self.controller(forOwnerSurface: binding.parentSurface) else { return }
        controller.setHostWindowId(appWindowId, forWindowId: tmuxWindowId)
    }

    deinit {
        if let debugToggleObserver {
            NotificationCenter.default.removeObserver(debugToggleObserver)
        }
        // Timeout tasks hold weak self, so fail any leftover continuations here.
        for task in replyTimeouts.values { task.cancel() }
        pushRouteServerIdentityTask?.cancel()
        for continuation in pendingReplies.values {
            continuation.resume(throwing: TmuxCommandError.gatewayEnded)
        }
        // Idempotent safety net for when cleanup() was missed.
        let interestID = contentEventInterestID
        Task { @MainActor in
            Ghostty.App.shared?.setTmuxSurfaceContentEventsEnabled(
                false,
                interestID: interestID)
        }
    }

    static func controller(forOwnerSurface surface: ghostty_surface_t) -> TmuxController? {
        let key = Int(bitPattern: surface)
        guard let weak = controllersByOwnerSurface[key] else { return nil }
        if let controller = weak.controller { return controller }
        controllersByOwnerSurface.removeValue(forKey: key)
        return nil
    }

    func noteSplitRequest(windowId: Int) {
        let paneIds = Set(paneViews.compactMap { paneId, view in
            view.tmuxPaneBinding?.windowId == windowId ? paneId : nil
        })
        pendingSplitFocus[windowId] = PendingSplitFocus(existingPaneIds: paneIds)
        // Expire so a failed split can't make a later remote focus look local.
        pendingSplitFocusExpiry[windowId]?.cancel()
        pendingSplitFocusExpiry[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.pendingSplitFocus.removeValue(forKey: windowId)
            self.pendingSplitFocusExpiry.removeValue(forKey: windowId)
        }
    }

    private func clearPendingSplitFocus(windowId: Int) {
        pendingSplitFocus.removeValue(forKey: windowId)
        pendingSplitFocusExpiry[windowId]?.cancel()
        pendingSplitFocusExpiry.removeValue(forKey: windowId)
    }

    /// Armed by a local new-window request so the next new window tab is
    /// selected (remote focus is otherwise ignored). Expires so a failed
    /// `new-window` can't capture an unrelated remote window later.
    private var pendingSelectNewWindow = false
    private var pendingSelectNewWindowExpiry: Task<Void, Never>?

    func noteNewWindowRequest() {
        pendingSelectNewWindow = true
        pendingSelectNewWindowExpiry?.cancel()
        pendingSelectNewWindowExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.pendingSelectNewWindow = false
            self.pendingSelectNewWindowExpiry = nil
        }
    }

    private func consumePendingSelectNewWindow() -> Bool {
        guard pendingSelectNewWindow else { return false }
        pendingSelectNewWindow = false
        pendingSelectNewWindowExpiry?.cancel()
        pendingSelectNewWindowExpiry = nil
        return true
    }

    func apply(_ ops: [TmuxReconcileOp]) {
        let signpost = TmuxPipelineSignposts.begin("tmux.apply")
        defer { TmuxPipelineSignposts.end("tmux.apply", signpost) }
        // The async hop can land after the scene released the TabsModel.
        // ROOTSHELL-TMUX (id=tmux-apply-tabsmodel-guard)
        guard weakTabsModel != nil else {
            TmuxDebugLogger.shared.event("RECONCILE", "tabsModel released; skip apply ops=\(ops.count)")
            return
        }

        // ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
        let isTitleOnly = !ops.isEmpty && ops.allSatisfy { op in
            switch op {
            case .setTabTitle, .setWindowTitle: return true
            default: return false
            }
        }
        if isTitleOnly {
            lastReconcileAt = Date()
            reconcileCount += 1
            if TmuxDebugLogger.shared.isEnabled {
                TmuxDebugLogger.shared.event("RECONCILE", "apply title-only ops=\(ops.count)")
            }
            for case let .setTabTitle(windowId, title) in ops {
                windowTabs[windowId]?.applyResolvedTitle(title)
            }
            return
        }

        // Backstop for the viewer.zig caps; reject whole batches to stay consistent.
        // ROOTSHELL-TMUX (id=viewer-topology-caps)
        if Self.exceedsTopologyCaps(ops) {
            TmuxDebugLogger.shared.event("RECONCILE", "REJECTED over-cap topology ops=\(ops.count)")
            return
        }

        // Skip identical full-topology re-emits; re-applying re-pushes sizes and
        // loops via %layout-change. ROOTSHELL-TMUX (id=tmux-reconcile-dedup)
        let isFullTopology = ops.first == .syncBegin
        if isFullTopology, let last = lastAppliedTopologyOps, last == ops, topologyStateCoherent() {
            skippedDuplicateReconciles += 1
            if TmuxDebugLogger.shared.isEnabled {
                let skipped = skippedDuplicateReconciles
                TmuxDebugLogger.shared.event("RECONCILE", "skipped duplicate full-topology ops=\(ops.count) totalSkipped=\(skipped)")
            }
            return
        }

        let paneIDsBeforeApply = Set(paneViews.keys)
        AgentAttentionCenter.shared.beginTopologyBatch()
        defer { AgentAttentionCenter.shared.endTopologyBatch() }

        lastReconcileAt = Date()
        reconcileCount += 1
        let dbg = TmuxDebugLogger.shared
        let logging = dbg.isEnabled
        if logging { dbg.event("RECONCILE", "apply begin ops=\(ops.count)") }
        var batchFailed = false
        var batchFocus: (windowId: Int, paneId: Int)?
        for op in ops {
            if logging { logApplyOp(op, dbg) }
            switch op {
            case .syncBegin:
                batchFocus = nil
                break
            case .syncEnd:
                reorderTmuxTabsByIndex()
                selectPendingSessionSwitchWindowIfReady(fallbackFocus: batchFocus)
            case let .ensureWindow(windowId, width, height, index):
                storeReportedWindowCells(windowId: windowId, cols: width, rows: height)
                ensureWindow(windowId, index: index)
            case let .ensurePane(windowId, paneId, viewerTerminal, viewerPane):
                if !ensurePane(windowId: windowId, paneId: paneId, viewerTerminal: viewerTerminal, viewerPane: viewerPane) {
                    batchFailed = true
                }
            case let .setLayout(windowId, layout, zoomedPaneId):
                if !setLayout(windowId: windowId, layout: layout, zoomedPaneId: zoomedPaneId) {
                    batchFailed = true
                }
            case let .setFocus(windowId, paneId):
                batchFocus = (windowId, paneId)
                setFocus(windowId: windowId, paneId: paneId)
            case let .pruneAbsent(windowIds, paneIds):
                prune(windowIds: Set(windowIds), paneIds: Set(paneIds))
            case let .setTabTitle(windowId, title):
                windowTabs[windowId]?.applyResolvedTitle(title)
            case .setWindowTitle:
                break
            }
        }
        if logging { dbg.event("RECONCILE", "apply end ops=\(ops.count) failed=\(batchFailed)") }
        // A failed batch isn't recorded, or dedup would skip every retry.
        // ROOTSHELL-TMUX (id=tmux-reconcile-dedup, id=tmux-reconcile-dedup-failure)
        if isFullTopology, !batchFailed { lastAppliedTopologyOps = ops }
        // Occlude new panes in non-selected windows now, before any tab switch.
        if !Set(paneViews.keys).subtracting(paneIDsBeforeApply).isEmpty {
            let hostWindowIDs = Set(windowHostIds.values).union([baseWindowId])
            for hostWindowID in hostWindowIDs {
                TerminalWindowRegistry.refreshSelectionAfterMutation(
                    in: hostWindowID,
                    allowFocus: false)
            }
        }
        // Title ops never schedule this; the #T subscription covers them.
        // ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
        if isFullTopology {
            schedulePaneIdentityRefresh(after: .milliseconds(150))
        }
    }

    /// Output may retitle a non-active pane; coalesce into an all-pane query.
    func notePaneContentChanged() {
        schedulePaneIdentityRefresh(after: .seconds(2))
    }

    private func schedulePaneIdentityRefresh(after delay: Duration) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed,
              paneIdentityRefreshTask == nil else { return }

        paneIdentityRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            defer { self.paneIdentityRefreshTask = nil }
            guard !Task.isCancelled,
                  !Ghostty.isAppBackgroundedAtomic,
                  !self.didEnd, !self.isDetaching, !self.ownerSurfaceFreed else { return }

            guard let identities = try? await self.paneDisplayIdentities() else { return }
            for (paneID, identity) in identities {
                guard let view = self.paneViews[paneID] else { continue }
                if view.tmuxReportedPaneTitle != identity.title {
                    view.tmuxReportedPaneTitle = identity.title
                }
                if view.tmuxReportedCurrentCommand != identity.currentCommand {
                    view.tmuxReportedCurrentCommand = identity.currentCommand
                }
                view.setForegroundProgram(
                    ForegroundProgram(rawName: identity.currentCommand, source: .tmux), from: .tmux)
            }
        }
    }

    /// Content events are off in background, so refresh all panes on foreground.
    static func applicationBackgroundStateDidChange(_ isBackgrounded: Bool) {
        var staleKeys: [Int] = []
        for (key, weakController) in controllersByOwnerSurface {
            guard let controller = weakController.controller else {
                staleKeys.append(key)
                continue
            }
            if isBackgrounded {
                controller.paneIdentityRefreshTask?.cancel()
                controller.paneIdentityRefreshTask = nil
            } else {
                controller.schedulePaneIdentityRefresh(after: .milliseconds(150))
                controller.refreshPushRouteServerIdentity()
            }
        }
        for key in staleKeys {
            controllersByOwnerSurface.removeValue(forKey: key)
        }
    }

    /// Mirrors viewer.zig MAX_WINDOWS / MAX_TOTAL_PANES. ROOTSHELL-TMUX (id=viewer-topology-caps)
    static let maxTopologyWindows = 128
    static let maxTopologyPanes = 512

    static func exceedsTopologyCaps(_ ops: [TmuxReconcileOp]) -> Bool {
        var windows = 0
        var panes = 0
        for op in ops {
            switch op {
            case .ensureWindow:
                windows += 1
                if windows > maxTopologyWindows { return true }
            case .ensurePane:
                panes += 1
                if panes > maxTopologyPanes { return true }
            case let .setLayout(_, layout, _):
                // A malformed layout can reference panes without ensure ops.
                if paneCount(layout) > maxTopologyPanes { return true }
            default:
                break
            }
        }
        return false
    }

    /// False when a projected tab left the model, so dedup lets the healing apply
    /// through. Always true while detaching, where closes are intentional.
    /// ROOTSHELL-TMUX (id=tmux-reconcile-dedup, id=tmux-window-tab-close-server)
    private func topologyStateCoherent() -> Bool {
        guard !windowTabs.isEmpty, !isDetaching, !didEnd else { return true }
        let coherent = windowTabs.allSatisfy { windowId, tab in
            windowCloseState.contains(windowId) ||
                hostTabsModel(forWindowId: windowId).tabs.contains(where: { $0.id == tab.id })
        }
        if !coherent {
            TmuxDebugLogger.shared.event("RECONCILE", "dedup bypass: stale window tab; applying")
        }
        return coherent
    }

    /// Logs ids and counts only; titles are redacted.
    private func logApplyOp(_ op: TmuxReconcileOp, _ dbg: TmuxDebugLogger) {
        switch op {
        case .syncBegin: dbg.op("syncBegin")
        case .syncEnd: dbg.op("syncEnd")
        case let .ensureWindow(w, width, height, index):
            dbg.op("ensureWindow", [("win", w), ("cols", width), ("rows", height), ("idx", index)])
        case let .ensurePane(w, p, vt, vp):
            dbg.op("ensurePane", [("win", w), ("pane", p), ("vt", vt != nil), ("vp", vp != nil)])
        case let .setLayout(w, layout, zoom):
            dbg.op("setLayout", [("win", w), ("panes", Self.paneCount(layout)), ("depth", Self.layoutDepth(layout)), ("zoom", zoom.map { "%\($0)" } ?? "none")])
        case let .setFocus(w, p):
            dbg.op("setFocus", [("win", w), ("pane", p)])
        case let .pruneAbsent(windowIds, paneIds):
            dbg.op("pruneAbsent", [("winKeep", windowIds.count), ("paneKeep", paneIds.count)])
        case let .setTabTitle(w, title):
            dbg.op("setTabTitle", [("win", w), ("title", TmuxDebugLogger.redact(title))])
        case let .setWindowTitle(title):
            dbg.op("setWindowTitle", [("title", TmuxDebugLogger.redact(title))])
        }
    }

    private static func paneCount(_ node: TmuxLayoutNode) -> Int {
        switch node {
        case .pane: return 1
        case let .split(_, children, _, _, _, _): return children.reduce(0) { $0 + paneCount($1) }
        }
    }

    private static func layoutDepth(_ node: TmuxLayoutNode) -> Int {
        switch node {
        case .pane: return 1
        case let .split(_, children, _, _, _, _): return 1 + (children.map(layoutDepth).max() ?? 0)
        }
    }

    private func ensureWindow(_ windowId: Int, index: Int) {
        let hostModel = hostTabsModel(forWindowId: windowId)

        // Keep the retained projection out of the UI until confirmation or rollback.
        if windowCloseState.contains(windowId) {
            windowTabs[windowId]?.tmuxWindowIndex = index
            return
        }

        // (id=tmux-window-order)
        if let existing = windowTabs[windowId] {
            if hostModel.tabs.contains(where: { $0 === existing }) || isDetaching || didEnd {
                // While detaching a missing tab is an intentional close; keep the
                // entry so the %exit prune still runs. ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
                existing.tmuxWindowIndex = index
                return
            }
            // The tab left the model behind our back: drop its stale panes and
            // recreate it. ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
            TmuxDebugLogger.shared.event("RESTORE", "self-heal: stale tab for win=\(windowId); recreating")
            windowTabs.removeValue(forKey: windowId)
            let stalePanes = paneViews.filter { $0.value.tmuxPaneBinding?.windowId == windowId }
            for (paneId, view) in stalePanes {
                // Same disarm sequence as prune's teardown.
                // ROOTSHELL-TMUX (id=tmux-focus-watchdog, id=tmux-pane-retired-no-size)
                view.isLogicallyFocused = false
                view.shouldBecomeFirstResponderWhenReady = false
                view.tmuxPaneRetired = true
                view.cleanup(reason: .userClose)
                paneViews.removeValue(forKey: paneId)
            }
            windowFontSize.removeValue(forKey: windowId)
            lastPushedWindowSize.removeValue(forKey: windowId)
            lastLayoutPaneCount.removeValue(forKey: windowId)
            lastAppliedLayout.removeValue(forKey: windowId)
            reportedWindowCellsByWindow.removeValue(forKey: windowId)
            clearForeignConstraint(windowId: windowId)
            clearPendingSplitFocus(windowId: windowId)
        }

        // Adopt a restored placeholder so the tab keeps its saved position.
        if let placeholder = hostModel.tabs.first(where: { t in
            t.awaitingTmuxReconcile &&
            t.pendingTmuxWindowId == windowId &&
            t.owningGatewayTerminalUUID == ownerTerminalUUID
        }) {
            placeholder.awaitingTmuxReconcile = false
            placeholder.pendingTmuxWindowId = nil
            placeholder.tmuxWindowId = windowId
            placeholder.tmuxWindowIndex = index
            placeholder.isTmuxWindow = true
            // (id=tmux-hidden-windows)
            placeholder.isHiddenTmuxWindow = hiddenWindowIds.contains(windowId)
            windowTabs[windowId] = placeholder
            setHostWindowId(placeholder.windowId, forWindowId: windowId)
            if let fontSize = placeholder.tmuxFontSizeOverride {
                windowFontSize[windowId] = fontSize
            }
            TmuxDebugLogger.shared.event("RESTORE", "adopted placeholder win=\(windowId) owner=\(ownerTerminalUUID.uuidString.prefix(8))")
            return
        }

        let tab = TabModel(windowId: baseWindowId)
        tab.title = "tmux \(windowId)"
        tab.isTmuxWindow = true
        tab.tmuxWindowId = windowId
        tab.tmuxWindowIndex = index
        tab.owningGatewayTerminalUUID = ownerTerminalUUID
        // Hidden windows never take selection. (id=tmux-hidden-windows)
        tab.isHiddenTmuxWindow = hiddenWindowIds.contains(windowId)
        windowTabs[windowId] = tab
        setHostWindowId(baseWindowId, forWindowId: windowId)
        hostModel.tabs.append(tab)
        TmuxDebugLogger.shared.event("RESTORE", "new window tab win=\(windowId) hidden=\(tab.isHiddenTmuxWindow)")
        if !tab.isHiddenTmuxWindow {
            if consumePendingSelectNewWindow() {
                hostModel.selectedTabID = tab.id
                hostModel.pendingScrollToTabID = tab.id
            } else if hostModel.selectedTabID == nil {
                hostModel.selectedTabID = tab.id
            }
        }
    }

    /// Permutes this gateway's tmux tabs within their existing slots by window index.
    /// ROOTSHELL-TMUX (id=tmux-window-order)
    private func reorderTmuxTabsByIndex() {
        let windowsByHost = Dictionary(grouping: windowTabs.keys) { hostWindowId(forWindowId: $0) }
        for (_, windowIds) in windowsByHost {
            let hostModel = windowIds.first.map { hostTabsModel(forWindowId: $0) } ?? tabsModel
            let myTabIDs = Set(windowIds.compactMap { windowTabs[$0]?.id })
            let slots = hostModel.tabs.indices.filter { myTabIDs.contains(hostModel.tabs[$0].id) }
            guard slots.count > 1 else { continue }
            let current = slots.map { hostModel.tabs[$0] }
            let sorted = current.sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }
            if current.elementsEqual(sorted, by: { $0 === $1 }) { continue }
            // One assignment: each write to `tabs` runs its whole didSet.
            var reordered = hostModel.tabs
            for (slot, tab) in zip(slots, sorted) {
                reordered[slot] = tab
            }
            hostModel.tabs = reordered
        }
    }

    /// Returns false when the pane view could not be created (the batch must
    /// not be recorded as applied, see id=tmux-reconcile-dedup-failure).
    private func ensurePane(
        windowId: Int,
        paneId: Int,
        viewerTerminal: UnsafeMutableRawPointer?,
        viewerPane: UnsafeMutableRawPointer?
    ) -> Bool {
        if let existing = paneViews[paneId] {
            // move-pane / break-pane keep the pane id but change its window; rebind
            // or size pushes ping-pong. ROOTSHELL-TMUX (id=tmux-move-pane-rebind)
            if existing.tmuxPaneBinding?.windowId != windowId {
                let previousWindowId = existing.tmuxPaneBinding?.windowId
                existing.tmuxPaneBinding = .init(
                    parentSurface: ownerSurface,
                    parentUUID: ownerTerminalUUID,
                    windowId: windowId,
                    paneId: paneId,
                    viewerTerminal: viewerTerminal,
                    viewerPane: viewerPane)
                let newTab = windowTabs[windowId]
                if let newTab { existing.containingTabID = newTab.id }
                TmuxDebugLogger.shared.event("PANE", "re-bound pane=\(paneId) -> win=\(windowId)")
                // Prune it from the old tab now: a view in two split trees is a
                // SwiftUI "repeated view" fatal error.
                if let previousWindowId,
                   let previousTab = windowTabs[previousWindowId],
                   previousTab !== newTab,
                   let previousRoot = previousTab.splitTree.root,
                   let leafNode = previousRoot.node(view: existing) {
                    let hadFocus = previousTab.focusedPane === existing
                    let nextFocus = previousRoot.findNeighbor(of: leafNode)?.leftmostLeaf()
                    previousTab.splitTree = previousTab.splitTree.remove(leafNode)
                    // Disarm unconditionally: a stale ready flag would grab the
                    // keyboard on reparent. (id=tmux-focus-stale-flag)
                    existing.isLogicallyFocused = false
                    existing.shouldBecomeFirstResponderWhenReady = false
                    existing.clearStaleGhosttyFocus()

                    let hostModel = modelContainingTab(id: previousTab.id) ?? tabsModel
                    let sourceIsSelected = hostModel.selectedTabID == previousTab.id
                    if hadFocus, sourceIsSelected, let nextTerminal = nextFocus?.asTerminal {
                        focusPane(nextTerminal, in: previousTab)
                    } else {
                        if hadFocus {
                            // Not focusPane: it would disturb the visible tab's focus.
                            previousTab.focusedPane = nextFocus
                            if let nextTerminal = nextFocus?.asTerminal {
                                nextTerminal.isLogicallyFocused = false
                                nextTerminal.shouldBecomeFirstResponderWhenReady = false
                            }
                        }
                        if existing.isFirstResponder { existing.resignFirstResponder() }
                    }
                    TmuxDebugLogger.shared.event(
                        "PANE", "pruned pane=\(paneId) from win=\(previousWindowId)")
                }
            }
            return true
        }
        guard let ghosttyApp else {
            TmuxDebugLogger.shared.event("PANE", "ensurePane SKIPPED (app released) win=\(windowId) pane=\(paneId)")
            return false
        }
        let hostModel = hostTabsModel(forWindowId: windowId)
        let hostWindowId = hostWindowId(forWindowId: windowId)
        let view = Ghostty.TerminalView(
            app,
            ghosttyApp: ghosttyApp,
            connectionConfig: .local(),
            windowId: hostWindowId)
        // Seed before attach so a pane born under an overlay can't steal the keyboard.
        view.setOverlayOwnsKeyboard(hostModel.overlayOwnsKeyboard)
        view.tmuxPaneBinding = .init(
            parentSurface: ownerSurface,
            parentUUID: ownerTerminalUUID,
            windowId: windowId,
            paneId: paneId,
            viewerTerminal: viewerTerminal,
            viewerPane: viewerPane)
        if let tab = windowTabs[windowId] {
            view.containingTabID = tab.id
            view.setOcclusion(hostModel.selectedTabID == tab.id)
        } else {
            view.setOcclusion(false)
        }
        NotificationCenter.default.post(name: .tmuxPaneBindingsChanged, object: nil)
        paneViews[paneId] = view
        return true
    }

    /// Apply equalization on the server; the resulting reconcile owns local geometry.
    func requestEqualizeSplits(_ tab: TabModel) {
        guard isActive, !tab.paneMove.isPending, let windowID = tab.tmuxWindowId,
              windowTabs[windowID] === tab, !equalizingWindows.contains(windowID),
              let layout = appliedLayout(for: windowID), layout.paneIDs.count > 1 else { return }
        equalizingWindows.insert(windowID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.equalizingWindows.remove(windowID) }
            do {
                try await TmuxSplitEqualizer.run(windowID: windowID, layout: layout) { command in
                    guard self.isActive, !tab.paneMove.isPending,
                          self.windowTabs[windowID] === tab,
                          self.appliedLayout(for: windowID)?.hasSameTopology(as: layout) == true else {
                        throw TmuxSplitEqualizer.Failure.layoutChanged
                    }
                    return try await self.sendCommandWithReply(command)
                }
            } catch {
                TmuxDebugLogger.shared.event("LAYOUT", "equalize failed: \(error)")
            }
        }
    }

    /// Commit a picker selection, using stable pane IDs from its frozen layout.
    func requestZoomPane(windowID: Int, paneID: Int, expectedPaneIDs: Set<Int>) {
        requestPaneSelection(windowID: windowID, paneID: paneID, sourcePaneID: nil, expectedPaneIDs: expectedPaneIDs)
    }

    func requestSwapPane(windowID: Int, sourcePaneID: Int, targetPaneID: Int, expectedPaneIDs: Set<Int>) {
        guard sourcePaneID != targetPaneID else { return }
        requestPaneSelection(windowID: windowID, paneID: targetPaneID, sourcePaneID: sourcePaneID,
                             expectedPaneIDs: expectedPaneIDs)
    }

    private func requestPaneSelection(windowID: Int, paneID: Int, sourcePaneID: Int?, expectedPaneIDs: Set<Int>) {
        guard isActive, !paneZoomSelectionWindows.contains(windowID),
              let tab = windowTabs[windowID], !tab.paneMove.isPending,
              let layout = appliedLayout(for: windowID),
              Set(layout.paneIDs) == expectedPaneIDs, expectedPaneIDs.contains(paneID),
              expectedPaneIDs.contains(sourcePaneID ?? paneID),
              paneViews[paneID]?.tmuxPaneBinding?.windowId == windowID,
              let pane = paneViews[sourcePaneID ?? paneID], pane.tmuxPaneBinding?.windowId == windowID,
              sourcePaneID == nil || tab.focusedTerminal === pane
        else { return }
        paneZoomSelectionWindows.insert(windowID)
        Task { @MainActor [weak self, weak tab, weak pane] in
            guard let self else { return }
            defer { self.paneZoomSelectionWindows.remove(windowID) }
            guard let tab, let pane,
                  self.isActive, self.windowTabs[windowID] === tab,
                  !tab.paneMove.isPending,
                  self.appliedLayout(for: windowID)?.hasSameTopology(as: layout) == true,
                  (self.modelContainingTab(id: tab.id) ?? self.tabsModel).selectedTabID == tab.id
            else { return }
            do {
                @MainActor func send(_ command: String) async throws -> String {
                    guard self.isActive, self.windowTabs[windowID] === tab,
                          !tab.paneMove.isPending,
                          self.appliedLayout(for: windowID)?.hasSameTopology(as: layout) == true,
                          pane.tmuxPaneBinding?.windowId == windowID,
                          self.paneViews[paneID]?.tmuxPaneBinding?.windowId == windowID,
                          sourcePaneID == nil || tab.focusedTerminal === pane,
                          (self.modelContainingTab(id: tab.id) ?? self.tabsModel).selectedTabID == tab.id
                    else { throw TmuxPaneZoomCommand.Failure.layoutChanged }
                    return try await self.sendCommandWithReply(command)
                }
                if let sourcePaneID {
                    let command = try TmuxPaneZoomCommand.swapCommand(windowID: windowID,
                                                                     sourcePaneID: sourcePaneID,
                                                                     targetPaneID: paneID)
                    _ = try await send(command)
                } else {
                    try await TmuxPaneZoomCommand.zoom(windowID: windowID, paneID: paneID, send: send)
                }
                guard self.isActive, self.windowTabs[windowID] === tab,
                      pane.tmuxPaneBinding?.windowId == windowID,
                      sourcePaneID == nil || tab.focusedTerminal === pane,
                      (self.modelContainingTab(id: tab.id) ?? self.tabsModel).selectedTabID == tab.id
                else { return }
                self.focusPane(pane, in: tab)
            } catch {
                TmuxDebugLogger.shared.event("LAYOUT", "pane selection failed: \(error)")
            }
        }
    }

    /// Resolves against server topology; if the boundary vanished mid-gesture,
    /// restore the applied layout.
    func requestResizeDivider(windowID: Int, horizontal: Bool,
                              leftPaneIDs: [Int], rightPaneIDs: [Int], delta: Int) {
        guard isActive, let tab = windowTabs[windowID], !tab.paneMove.isPending,
              let layout = appliedLayout(for: windowID) else { return }
        guard let target = TmuxDividerResize.target(in: layout, horizontal: horizontal,
                                                   leftPaneIDs: leftPaneIDs, rightPaneIDs: rightPaneIDs,
                                                   delta: delta),
              let pane = paneViews[target.paneID], pane.tmuxPaneBinding?.windowId == windowID else {
            _ = setLayout(windowId: windowID, layout: layout, zoomedPaneId: nil)
            return
        }
        pane.requestTmuxResizePane(horizontal: horizontal, cells: target.size)
    }

    /// Rebuilds a window's split ratios from its applied layout, e.g. after a
    /// pane's top inset changed without changing the window's cell size.
    func reapplyLayout(windowID: Int) {
        guard isActive, let tab = windowTabs[windowID], !tab.paneMove.isPending,
              let ops = lastAppliedTopologyOps else { return }
        for case let .setLayout(id, layout, zoomedPaneId) in ops where id == windowID {
            _ = setLayout(windowId: windowID, layout: layout, zoomedPaneId: zoomedPaneId)
            return
        }
    }

    private func appliedLayout(for windowID: Int) -> TmuxLayoutNode? {
        guard let ops = lastAppliedTopologyOps else { return nil }
        for case let .setLayout(id, layout, _) in ops where id == windowID {
            return layout
        }
        return nil
    }

    /// Returns false on a missing tab or pane view; the batch must not be recorded.
    /// ROOTSHELL-TMUX (id=tmux-reconcile-dedup-failure)
    private func setLayout(windowId: Int, layout: TmuxLayoutNode, zoomedPaneId: Int?) -> Bool {
        guard let tab = windowTabs[windowId] else {
            TmuxDebugLogger.shared.event("LAYOUT", "setLayout FAILED (no tab) win=\(windowId)")
            return false
        }
        guard let root = buildNode(layout, metrics: paneMetrics(for: layout)) else {
            TmuxDebugLogger.shared.event("LAYOUT", "setLayout FAILED (missing pane view) win=\(windowId) panes=\(Self.paneCount(layout))")
            return false
        }
        // %layout-change is when a foreign client resizes the window.
        let rootSize = Self.layoutSize(layout)
        storeReportedWindowCells(windowId: windowId, cols: rootSize.cols, rows: rootSize.rows)
        // Pane count changed: the size driver hands over, so re-arm the size dedup.
        // ROOTSHELL-TMUX (id=tmux-size-floor)
        let paneCount = Self.paneCount(layout)
        if let previous = lastLayoutPaneCount[windowId], previous != paneCount {
            lastPushedWindowSize.removeValue(forKey: windowId)
            if isActiveWindow(windowId: windowId) { lastPushedGlobalSize = nil }
            TmuxDebugLogger.shared.event("LAYOUT", "pane count \(previous)->\(paneCount) win=\(windowId), size dedup re-armed")
        }
        lastLayoutPaneCount[windowId] = paneCount
        // Focus before assigning the tree so didMoveToWindow makes it first responder.
        if tab.focusedPane == nil, let first = firstPaneView(layout) {
            focusPane(first, in: tab)
        }
        // Zoomed node matches the root leaf by view identity. ROOTSHELL-TMUX (id=tmux-zoom)
        let zoomedNode: SplitTree<SplitPaneView>.Node?
        if let zoomedPaneId, let view = paneViews[zoomedPaneId] {
            zoomedNode = .leaf(view: view)
        } else {
            zoomedNode = nil
        }
        // Every full reconcile re-sends every window; an unchanged tree must
        // not invalidate SwiftUI or resize panes tmux did not reflow.
        let treeChanged = tab.splitTree.root != root || tab.splitTree.zoomed != zoomedNode
        if treeChanged {
            tab.splitTree = SplitTree(root: root, zoomed: zoomedNode)
        }
        fulfillPendingSplitFocus(windowId: windowId, layout: layout, tab: tab)
        let layoutChanged = lastAppliedLayout[windowId] != layout
        lastAppliedLayout[windowId] = layout
        guard treeChanged || layoutChanged else { return true }

        // Re-run reveal gating for a placeholder that was shown before its panes existed.
        tabsModel.syncDisplayedTab()

        // tmux reflowed these panes; force a size sync after layout, since a tiny
        // frame change would otherwise skip set_size and leave a stale frame.
        let views = panes(in: layout)
        DispatchQueue.main.async {
            for view in views {
                view.invalidateCachedSize()
                view.sizeDidChange(view.bounds.size)
            }
        }
        return true
    }

    private func fulfillPendingSplitFocus(windowId: Int, layout: TmuxLayoutNode, tab: TabModel) {
        guard let pending = pendingSplitFocus[windowId],
              let paneId = firstPaneId(in: layout, notIn: pending.existingPaneIds),
              let view = paneViews[paneId]
        else { return }

        clearPendingSplitFocus(windowId: windowId)
        TmuxDebugLogger.shared.event("FOCUS", "split fulfilled win=\(windowId) pane=\(paneId)")
        let hostModel = hostTabsModel(forWindowId: windowId)
        hostModel.selectedTabID = tab.id
        hostModel.pendingScrollToTabID = tab.id
        focusPane(view, in: tab)
    }

    private func firstPaneId(in node: TmuxLayoutNode, notIn existingPaneIds: Set<Int>) -> Int? {
        switch node {
        case let .pane(paneId, _, _, _, _):
            return existingPaneIds.contains(paneId) ? nil : paneId
        case let .split(_, children, _, _, _, _):
            for child in children {
                if let paneId = firstPaneId(in: child, notIn: existingPaneIds) {
                    return paneId
                }
            }
            return nil
        }
    }

    private func panes(in node: TmuxLayoutNode) -> [Ghostty.TerminalView] {
        switch node {
        case let .pane(paneId, _, _, _, _):
            return paneViews[paneId].map { [$0] } ?? []
        case let .split(_, children, _, _, _, _):
            return children.flatMap { panes(in: $0) }
        }
    }

    private func focusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        // Background tabs only record focus; don't disturb the visible tab.
        let hostModel = modelContainingTab(id: tab.id) ?? tabsModel
        guard hostModel.selectedTabID == tab.id else {
            recordRemoteFocusPane(view, in: tab)
            return
        }
        let previous = tab.focusedTerminal
        for other in paneViews.values where other !== view {
            other.isLogicallyFocused = false
            // A stale flag grabs focus on reparent and echoes select-pane back to
            // tmux. ROOTSHELL-TMUX (id=tmux-focus-stale-flag)
            other.shouldBecomeFirstResponderWhenReady = false
            // ROOTSHELL-TMUX (id=tmux-focus-cursor-sweep)
            other.clearStaleGhosttyFocus()
        }
        view.isLogicallyFocused = true
        view.shouldBecomeFirstResponderWhenReady = true
        tab.focusedTerminal = view

        // Mirrors MainView.setFocusedTerminal. ROOTSHELL-TMUX (id=tmux-focus-active)
        var acquired = false
        // Unattached new panes are covered by didMoveToWindow and the watchdog.
        if view.window != nil {
            acquired = view.focusDidChange(true)
            if acquired { view.shouldBecomeFirstResponderWhenReady = false }
        }

        if let previous, previous !== view {
            if previous.surface != nil {
                previous.focusDidChange(false, skipResign: acquired)
            } else if previous.isFirstResponder {
                previous.resignFirstResponder()
            }
        }
        armFocusWatchdog(for: view, tab: tab)
    }

    /// Retries first responder onto the focused pane; a split's hosting-view rebuild
    /// can defeat the per-view retries. ROOTSHELL-TMUX (id=tmux-focus-watchdog)
    private func armFocusWatchdog(for view: Ghostty.TerminalView, tab: TabModel) {
        focusWatchdog?.cancel()
        let paneId = view.tmuxPaneBinding?.paneId ?? -1
        let tabID = tab.id
        focusWatchdog = Task { @MainActor [weak self, weak view] in
            for (attempt, delay) in [100, 250, 450].enumerated() {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let view else { return }
                if view.isFirstResponder {
                    if attempt > 0 {
                        TmuxDebugLogger.shared.event("FOCUS", "watchdog converged pane=\(paneId) attempt=\(attempt)")
                    }
                    return
                }
                // Async task: the `tabsModel` non-nil invariant doesn't hold here.
                guard let model = self.weakTabsModel else { return }
                // A pruned view may linger in UIKit; don't revive it.
                guard self.paneViews[paneId] === view,
                      view.isLogicallyFocused, model.selectedTabID == tabID else {
                    TmuxDebugLogger.shared.event("FOCUS", "watchdog superseded pane=\(paneId) attempt=\(attempt)")
                    return
                }
                let ok = view.reassertFirstResponderIfFocused()
                TmuxDebugLogger.shared.event("FOCUS", "watchdog reassert pane=\(paneId) attempt=\(attempt) ok=\(ok)")
                if ok { return }
            }
            if let view, !view.isFirstResponder {
                let hasWindow = view.window != nil
                TmuxDebugLogger.shared.event("FOCUS", "watchdog gave up pane=\(paneId) window=\(hasWindow)")
            }
        }
    }

    /// Records focus for a hidden tab without letting it take first responder.
    private func recordRemoteFocusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        view.isLogicallyFocused = false
        view.shouldBecomeFirstResponderWhenReady = false
        tab.focusedTerminal = view
    }

    /// Converts layout cells to points including padding and dividers.
    /// ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
    private struct PaneMetrics {
        let cellW: CGFloat
        let cellH: CGFloat
        let padX: CGFloat
        let padY: CGFloat
        let divider: CGFloat
        /// Top inset shared by every pane on the window's top row.
        let topInset: CGFloat
    }

    private func paneMetrics(for layout: TmuxLayoutNode) -> PaneMetrics? {
        guard let view = firstPaneView(layout),
              let size = view.surfaceSize,
              size.cell_width_px > 0, size.cell_height_px > 0
        else { return nil }
        let scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : view.traitCollection.displayScale
        guard scale > 0 else { return nil }
        return PaneMetrics(
            cellW: CGFloat(size.cell_width_px) / scale,
            cellH: CGFloat(size.cell_height_px) / scale,
            padX: CGFloat(PaddingManager.shared.effectivePaddingX),
            padY: CGFloat(PaddingManager.shared.effectivePaddingY),
            divider: SplitTreeHostingView.dividerVisibleThickness,
            topInset: layoutTopInset(layout))
    }

    /// Panes may not be in their new positions yet, so take the largest inset
    /// any of them reports; only panes touching the top report one.
    private func layoutTopInset(_ node: TmuxLayoutNode) -> CGFloat {
        switch node {
        case let .pane(paneId, _, _, _, _):
            return paneViews[paneId]?.topInsetPoints ?? 0
        case let .split(_, children, _, _, _, _):
            return children.map(layoutTopInset).max() ?? 0
        }
    }

    /// ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
    private func neededPoints(_ node: TmuxLayoutNode, horizontal: Bool, metrics: PaneMetrics) -> CGFloat {
        let cell = horizontal ? metrics.cellW : metrics.cellH
        let pad = horizontal ? metrics.padX : metrics.padY
        switch node {
        case let .pane(_, width, height, _, y):
            // A pane on the window's top row also clears the top inset.
            let inset = !horizontal && y == 0 ? metrics.topInset : 0
            return CGFloat(horizontal ? width : height) * cell + pad * 2 + inset
        case let .split(direction, children, _, _, _, _):
            let along = children.map { neededPoints($0, horizontal: horizontal, metrics: metrics) }
            if (direction == .horizontal) == horizontal {
                return along.reduce(0, +) + CGFloat(max(children.count - 1, 0)) * metrics.divider
            }
            return along.max() ?? pad * 2
        }
    }

    /// Right-folds N-ary tmux splits into binary ones. Ratios use needed points,
    /// not raw cells, or the first child's last row clips.
    /// ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
    private func buildNode(_ node: TmuxLayoutNode, metrics: PaneMetrics?) -> SplitTree<SplitPaneView>.Node? {
        switch node {
        case let .pane(paneId, _, _, _, _):
            guard let view = paneViews[paneId] else { return nil }
            return .leaf(view: view)
        case let .split(direction, children, width, height, _, _):
            let horizontal = direction == .horizontal
            let dir: SplitTree<SplitPaneView>.Direction = horizontal ? .horizontal : .vertical
            return foldChildren(
                children,
                dir: dir,
                horizontal: horizontal,
                container: horizontal ? width : height,
                metrics: metrics)
        }
    }

    private func foldChildren(
        _ children: [TmuxLayoutNode],
        dir: SplitTree<SplitPaneView>.Direction,
        horizontal: Bool,
        container: Int,
        metrics: PaneMetrics?
    ) -> SplitTree<SplitPaneView>.Node? {
        guard let first = children.first else { return nil }
        guard children.count > 1 else { return buildNode(first, metrics: metrics) }

        let rest = Array(children.dropFirst())
        guard let leftNode = buildNode(first, metrics: metrics) else {
            // First child unbuildable (missing pane view); fold the rest.
            return foldChildren(rest, dir: dir, horizontal: horizontal, container: container, metrics: metrics)
        }
        let firstSize = horizontal ? first.width : first.height
        let restContainer = max(1, container - firstSize - 1)
        guard let rightNode = foldChildren(rest, dir: dir, horizontal: horizontal, container: restContainer, metrics: metrics) else {
            return leftNode
        }
        let ratio: Double
        if let metrics {
            let neededFirst = neededPoints(first, horizontal: horizontal, metrics: metrics)
            let neededRest = rest.map { neededPoints($0, horizontal: horizontal, metrics: metrics) }.reduce(0, +)
                + CGFloat(max(rest.count - 1, 0)) * metrics.divider
            let total = neededFirst + neededRest
            ratio = total > 0 ? Double(neededFirst / total) : 0.5
        } else {
            ratio = container > 0 ? Double(firstSize) / Double(container) : 0.5
        }
        return .split(.init(direction: dir, ratio: min(max(ratio, 0.05), 0.95), left: leftNode, right: rightNode))
    }

    private func firstPaneView(_ node: TmuxLayoutNode) -> Ghostty.TerminalView? {
        switch node {
        case let .pane(paneId, _, _, _, _):
            return paneViews[paneId]
        case let .split(_, children, _, _, _, _):
            for child in children {
                if let view = firstPaneView(child) { return view }
            }
            return nil
        }
    }

    static let autoHideGatewayOnAttachDefaultsKey = "tmuxAutoHideGatewayOnAttach"

    /// Once per attachment, so a manual "Show Gateway Tab" isn't re-hidden.
    private var didAutoHideGatewayOnAttach = false

    /// Marks the tab control mode was launched from. Idempotent.
    func markGatewayTab(ownerView: Ghostty.TerminalView) {
        // (id=tmux-apply-tabsmodel-guard)
        guard weakTabsModel != nil else { return }
        guard let gatewayTab = tabsModel.tabs.first(where: { tab in
            tab.splitTree.contains { $0 === ownerView }
        }) else { return }
        // Guarded writes: this runs every reconcile and each write notifies Observation.
        if !gatewayTab.isTmuxGateway {
            gatewayTab.isTmuxGateway = true
        }
        gatewayTabID = gatewayTab.id
        // The session can be known before the tab is marked. (id=tmux-session-info-stash)
        if let currentSessionName, gatewayTab.tmuxSessionName != currentSessionName {
            gatewayTab.tmuxSessionName = currentSessionName
        }
        // Deferred until window tabs exist so hideGatewayTab sees real data. Both
        // branches consume the one-shot even if the hide is skipped. (id=tmux-hidden-gateway)
        if gatewayTab.pendingHiddenTmuxGatewayRestore, !windowTabs.isEmpty {
            gatewayTab.pendingHiddenTmuxGatewayRestore = false
            didAutoHideGatewayOnAttach = true
            hideGatewayTab()
        } else if !didAutoHideGatewayOnAttach,
                  SettingsStore.shared.get(Settings.Multiplexer.tmuxAutoHideGatewayOnAttach),
                  !windowTabs.isEmpty {
            didAutoHideGatewayOnAttach = true
            hideGatewayTab()
        }
    }

    /// Resolved by ownership rather than the `isTmuxGateway` flag.
    private func ownGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return model?.tabs.first { tab in
            tab.splitTree.contains { $0.asTerminal?.tmuxController === self }
        }
    }

    /// By cached id, then ownership, then the global flag as a last resort.
    func resolvedGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return gatewayTabID.flatMap { id in model?.tabs.first { $0.id == id } }
            ?? ownGatewayTab()
            ?? model?.tabs.first(where: { $0.isTmuxGateway })
    }

    /// Like `resolvedGatewayTab` without the global-flag fallback, for writes that
    /// must never land on another gateway's tab.
    func ownedGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return gatewayTabID.flatMap { id in model?.tabs.first { $0.id == id } }
            ?? ownGatewayTab()
    }

    /// Selecting a hidden gateway also shows it. (id=tmux-hidden-gateway)
    func selectGatewayTab() -> Bool {
        guard let gatewayTab = resolvedGatewayTab() else { return false }
        if gatewayTab.isHiddenTmuxWindow {
            gatewayTab.isHiddenTmuxWindow = false
            postHiddenWindowsDidChange()
        }
        selectTab(gatewayTab.id)
        return true
    }

    @discardableResult
    func selectWindowTab(windowId: Int) -> Bool {
        guard let tab = windowTabs[windowId] else {
            return false
        }
        // Selecting a hidden window also shows it. (id=tmux-hidden-windows)
        if tab.isHiddenTmuxWindow {
            showWindow(windowId: windowId, andSelect: false)
        }
        selectTab(tab.id)
        return true
    }

    private func selectPendingSessionSwitchWindowIfReady(
        fallbackFocus: (windowId: Int, paneId: Int)?
    ) {
        guard let windowId = pendingSessionSwitchWindowSelection else {
            return
        }
        guard selectWindowTab(windowId: windowId) else {
            TmuxDebugLogger.shared.event("SESSION", "requested window @\(windowId) missing; falling back to session focus")
            pendingSessionSwitchWindowSelection = nil
            if let fallbackFocus {
                setFocus(windowId: fallbackFocus.windowId, paneId: fallbackFocus.paneId)
            }
            return
        }
        TmuxDebugLogger.shared.event("SESSION", "selected requested window @\(windowId)")
        pendingSessionSwitch = false
        pendingSessionSwitchWindowSelection = nil
        pendingSessionSwitchExpiry?.cancel()
        pendingSessionSwitchExpiry = nil
    }

    private func setFocus(windowId: Int, paneId: Int) {
        guard !windowCloseState.contains(windowId), let tab = windowTabs[windowId] else { return }
        // tmux broadcasts the current window to every client, so only locally
        // originated focus may change the selected tab.
        let isLocalSplitFocus: Bool = {
            guard let pending = pendingSplitFocus[windowId] else { return false }
            return !pending.existingPaneIds.contains(paneId)
        }()
        // Before the flag-consuming checks below. ROOTSHELL-TMUX (id=tmux-focus-echo-gate)
        if !isLocalSplitFocus, localFocusGate.suppresses(windowId: windowId, paneId: paneId) {
            TmuxDebugLogger.shared.event("FOCUS", "ignored stale local echo win=\(windowId) pane=\(paneId)")
            return
        }
        let hostModel = hostTabsModel(forWindowId: windowId)
        // ROOTSHELL-TMUX (id=tmux-session-switch-focus)
        let isSessionSwitchFocus = pendingSessionSwitchWindowSelection == nil
            ? consumePendingSessionSwitch()
            : false
        // gatewayTabID isn't stamped until after the first reconcile.
        let isInitialFocus = !hasProcessedInitialFocus && hostModel.maySelectInitialMultiplexerTab(
            gatewayTabID: gatewayTabID ?? ownGatewayTab()?.id
        )
        hasProcessedInitialFocus = true

        // Hidden windows never take selection, even on attach. (id=tmux-hidden-windows)
        if tab.isHiddenTmuxWindow {
            if let view = paneViews[paneId] {
                recordRemoteFocusPane(view, in: tab)
            }
            TmuxDebugLogger.shared.event("FOCUS", "ignored focus for hidden win=\(windowId)")
            if hostModel.selectedTabID == nil { hostModel.repairSelectionIfNeeded() }
            return
        }

        let targetIsSelected = hostModel.selectedTabID == tab.id
        let mayChangeSelection = isInitialFocus || isSessionSwitchFocus || targetIsSelected || isLocalSplitFocus

        if !mayChangeSelection {
            if let view = paneViews[paneId] {
                recordRemoteFocusPane(view, in: tab)
            }
            Ghostty.logger.info("tmux reconcile: keeping local tab selection; ignored remote focus for window \(windowId)")
            TmuxDebugLogger.shared.event("FOCUS", "ignored remote focus win=\(windowId) pane=\(paneId)")
            return
        }

        TmuxDebugLogger.shared.event("FOCUS", "follow win=\(windowId) pane=\(paneId) initial=\(isInitialFocus) localSplit=\(isLocalSplitFocus)")
        hostModel.selectedTabID = tab.id
        hostModel.pendingScrollToTabID = tab.id
        if let view = paneViews[paneId] {
            focusPane(view, in: tab)
            if let pending = pendingSplitFocus[windowId],
               !pending.existingPaneIds.contains(paneId) {
                clearPendingSplitFocus(windowId: windowId)
            }
        }
    }

    /// Both commands go out in one task turn to keep their FIFO order. The release
    /// rides the reconcile serializer so echoes that arrived before the reply
    /// still hit the gate. ROOTSHELL-TMUX (id=tmux-focus-echo-gate)
    func requestLocalSelectPane(windowId: Int, paneId: Int) {
        let token = localFocusGate.noteSent(windowId: windowId, paneId: paneId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.didEnd, !self.isDetaching, !self.ownerSurfaceFreed {
                let data = Data("select-window -t @\(windowId)\n".utf8)
                TmuxDebugLogger.shared.command(kind: "select-window", bytes: data.count)
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    ghostty_surface_tmux_command(
                        self.ownerSurface,
                        base.assumingMemoryBound(to: CChar.self),
                        UInt(data.count))
                }
            }
            _ = try? await self.sendCommandWithReply("select-pane -t %\(paneId)", timeout: .seconds(3))
            TmuxReconcileSerializer.shared.enqueue { [weak self] in
                self?.localFocusGate.noteCompleted(token)
            }
        }
    }

    private func prune(windowIds: Set<Int>, paneIds: Set<Int>) {
        let hadWindows = !windowTabs.isEmpty
        let priorPaneCount = paneViews.count
        let priorWindowCount = windowTabs.count
        let hostIdsBeforePrune = Set(windowHostIds.values + [baseWindowId])

        windowCloseState.prune(keeping: windowIds)

        // Snapshot order and selection so a closed selected tab lands on its
        // neighbor. ROOTSHELL-TMUX (id=grouped-close-neighbor)
        let hostSnapshots: [String: (order: [UUID], selectedID: UUID?, groupedNeighborID: UUID?)] =
            Dictionary(uniqueKeysWithValues: hostIdsBeforePrune.compactMap { hostId in
                guard let model = TerminalWindowRegistry.tabsModel(for: hostId)
                    ?? TmuxWindowRegistry.tabsModel(for: hostId) else {
                    return nil
                }
                let selectedID = model.selectedTabID
                let groupedNeighborID = selectedID.flatMap { model.groupedCloseNeighbor(for: $0) }
                return (hostId, (model.tabs.map(\.id), selectedID, groupedNeighborID))
            })

        // cleanup() unregisters the surface; a bare removal would leave it dangling.
        let panesToRemove = paneViews.filter { !paneIds.contains($0.key) }
        for (paneId, view) in panesToRemove {
            // The view may linger in UIKit; disarm focus and sizing first.
            // ROOTSHELL-TMUX (id=tmux-focus-watchdog, id=tmux-pane-retired-no-size)
            view.isLogicallyFocused = false
            view.shouldBecomeFirstResponderWhenReady = false
            view.tmuxPaneRetired = true
            view.cleanup(reason: .userClose)
            paneViews.removeValue(forKey: paneId)
        }
        let windowsToRemove = windowTabs.filter { !windowIds.contains($0.key) }
        for (windowId, tab) in windowsToRemove {
            let hostModel = hostTabsModel(forWindowId: windowId)
            hostModel.tabs.removeAll { $0.id == tab.id }
            windowTabs.removeValue(forKey: windowId)
            windowHostIds.removeValue(forKey: windowId)
            windowFontSize.removeValue(forKey: windowId)
            lastPushedWindowSize.removeValue(forKey: windowId)
            lastLayoutPaneCount.removeValue(forKey: windowId)
            lastAppliedLayout.removeValue(forKey: windowId)
            reportedWindowCellsByWindow.removeValue(forKey: windowId)
            clearForeignConstraint(windowId: windowId)
            // ROOTSHELL-TMUX (id=tmux-session-switch-focus)
            clearPendingSplitFocus(windowId: windowId)
            localFocusGate.remove(windowId: windowId)
        }

        // Teardown (empty windowIds) clears in memory only; the server keeps
        // `@hidden` for the next attach. (id=tmux-hidden-windows)
        let prunedHidden = hiddenWindowIds.subtracting(windowIds)
        if !prunedHidden.isEmpty {
            hiddenWindowIds.subtract(prunedHidden)
            if !windowIds.isEmpty && !didEnd && !isDetaching {
                persistHiddenWindowsToServer()
                saveHiddenMirror()
            }
            postHiddenWindowsDidChange()
        }

        // A hidden gateway must always have a visible window tab. (id=tmux-hidden-gateway)
        enforceGatewayVisibleWhenGroupHidden()

        // Placeholders still awaiting here are orphans; ensureWindow ran first.
        let placeholderHostIds = hostIdsBeforePrune.union(windowHostIds.values)
        for hostId in placeholderHostIds {
            let model = TerminalWindowRegistry.tabsModel(for: hostId)
                ?? TmuxWindowRegistry.tabsModel(for: hostId)
            model?.tabs.removeAll { t in
                t.awaitingTmuxReconcile &&
                t.owningGatewayTerminalUUID == ownerTerminalUUID &&
                !(t.pendingTmuxWindowId.map { windowIds.contains($0) } ?? false)
            }
        }

        // All windows gone after having some: control mode ended (`%exit`).
        TmuxDebugLogger.shared.event("PRUNE", "removedPanes=\(priorPaneCount - paneViews.count) removedWindows=\(priorWindowCount - windowTabs.count) windowsRemaining=\(windowTabs.count)")
        if hadWindows && windowTabs.isEmpty && !didEnd {
            didEnd = true
            releaseContentEventInterest()
            paneIdentityRefreshTask?.cancel()
            paneIdentityRefreshTask = nil
            stopHeartbeat()
            stopRecoveryWatchdog()
            failAllPendingReplies(.gatewayEnded)
            // ROOTSHELL-TMUX (id=tmux-focus-watchdog)
            focusWatchdog?.cancel()
            focusWatchdog = nil
            TmuxDebugLogger.shared.marker("CONTROL MODE END (prune emptied all windows)")
            // Reselect our own gateway so the user lands on its shell with the
            // keyboard. ROOTSHELL-TMUX (id=tmux-detach-reselect-own-gateway)
            if let gatewayTab = resolvedGatewayTab() {
                gatewayTab.isTmuxGateway = false
                gatewayTab.tmuxSessionName = nil
                // Hidden gateway state never outlives the attachment. (id=tmux-hidden-gateway)
                if gatewayTab.isHiddenTmuxWindow {
                    gatewayTab.isHiddenTmuxWindow = false
                    postHiddenWindowsDidChange()
                }
                gatewayTab.pendingHiddenTmuxGatewayRestore = false
                if closeGatewayTabAfterDetach {
                    closeGatewayTabAfterDetach = false
                    // Async so it lands after this reconcile finishes mutating tabs.
                    // (id=tmux-tab-close-action)
                    if let gatewayView = gatewayTab.splitTree.first(where: { $0.asTerminal?.tmuxController === self })
                        ?? gatewayTab.splitTree.first {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .closeSplit, object: gatewayView)
                        }
                    }
                } else {
                    selectTab(gatewayTab.id)
                    // The tmux group dissolved; rescope to the gateway's new group.
                    // (id=tmux-detach-regroup)
                    modelContainingTab(id: gatewayTab.id)?.revalidateGroupingSelection()
                }
            }
            NotificationCenter.default.post(
                name: .tmuxControlModeDidEnd,
                object: ownerTerminalUUIDForNotifications)
        } else {
            for (hostId, snapshot) in hostSnapshots {
                guard let selectedID = snapshot.selectedID,
                      let model = TerminalWindowRegistry.tabsModel(for: hostId)
                        ?? TmuxWindowRegistry.tabsModel(for: hostId),
                      !model.tabs.contains(where: { $0.id == selectedID }),
                      let neighborID = survivingGroupedOrNearestNeighbor(
                        in: model,
                        groupedCandidateID: snapshot.groupedNeighborID,
                        priorOrder: snapshot.order,
                        removedID: selectedID
                      ) else {
                    continue
                }
                model.selectedTabID = neighborID
                model.pendingScrollToTabID = neighborID
                TerminalWindowRegistry.refreshSelectionAfterMutation(in: hostId, allowFocus: true)
            }
        }

        // Safety net for a selection still pointing at a removed tab.
        let repairHostIds = hostIdsBeforePrune.union(windowHostIds.values)
        for hostId in repairHostIds {
            guard let model = TerminalWindowRegistry.tabsModel(for: hostId)
                ?? TmuxWindowRegistry.tabsModel(for: hostId) else { continue }
            let before = model.selectedTabID
            model.repairSelectionIfNeeded()
            if model.selectedTabID != before {
                TerminalWindowRegistry.refreshSelectionAfterMutation(in: hostId, allowFocus: true)
            }
        }
    }

    private func survivingGroupedOrNearestNeighbor(
        in model: TabsModel,
        groupedCandidateID: UUID?,
        priorOrder: [UUID],
        removedID: UUID
    ) -> UUID? {
        if let groupedCandidateID,
           model.tabs.contains(where: { $0.id == groupedCandidateID && !$0.isHiddenTmuxWindow }) {
            return groupedCandidateID
        }
        return nearestSurvivingTabID(in: model, priorOrder: priorOrder, removedID: removedID)
    }

    /// Right neighbor first, then left; same rule as MainView.closeTab.
    private func nearestSurvivingTabID(in model: TabsModel, priorOrder: [UUID], removedID: UUID) -> UUID? {
        guard let idx = priorOrder.firstIndex(of: removedID) else { return nil }
        let surviving = Set(model.tabs.map(\.id))
        for i in (idx + 1)..<priorOrder.count where surviving.contains(priorOrder[i]) {
            return priorOrder[i]
        }
        for i in stride(from: idx - 1, through: 0, by: -1) where surviving.contains(priorOrder[i]) {
            return priorOrder[i]
        }
        return nil
    }

    /// Mirrors MainView.closeTab's handoff: onChange(of: selectedTabIndex) won't
    /// fire when the target slides into the same slot, so set focus explicitly.
    func selectTab(_ tabID: UUID) {
        guard let model = modelContainingTab(id: tabID),
              let tab = model.tab(withID: tabID) else { return }
        model.selectedTabID = tabID
        model.pendingScrollToTabID = tabID
        for terminal in tab.splitTree { terminal.setOcclusion(true) }
        if let target = tab.focusedPane ?? tab.splitTree.first {
            tab.focusedPane = target
            target.isLogicallyFocused = true
            target.asTerminal?.shouldBecomeFirstResponderWhenReady = true
            _ = target.becomeFirstResponder()
            // The core no longer echoes select-pane on focus gain.
            // ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
            if let terminal = target.asTerminal, terminal.isTmuxPane {
                terminal.requestTmuxSelectPane()
            }
            ghosttyApp?.appTick()
        }
    }

    private func selectNeighborTab(_ tabID: UUID) { selectTab(tabID) }

    /// Tears down locally when the gateway tab closes, since no `%exit` will arrive.
    func forceQuit() {
        // No detach write: closing the transport detaches server-side, and a raw
        // write would interleave with queued commands.
        TmuxDebugLogger.shared.event("END", "forceQuit (gateway tab closed)")
        prune(windowIds: [], paneIds: [])
    }

    private func ownGatewayView() -> Ghostty.TerminalView? {
        guard weakTabsModel != nil else { return nil }
        return ownGatewayTab()?.splitTree.terminalLeaves.first { $0.tmuxController === self }
    }

    /// Includes tssh embedded in a LocalShellSession, which a bare cast misses.
    /// ROOTSHELL-TMUX (id=tmux-gateway-trzsz-resolve)
    static func gatewayTrzszSession(for session: TerminalSession?) -> TrzszSession? {
        if let trzsz = session as? TrzszSession { return trzsz }
        #if !targetEnvironment(macCatalyst)
        if let local = session as? LocalShellSession,
           let embedded = local.embeddedTrzszSession {
            return embedded
        }
        #endif
        return nil
    }

    /// Whether the transport itself claims a live link: a known drop is worth
    /// waiting on, a "healthy" silent link is not. False when unknown.
    /// ROOTSHELL-TMUX (id=tmux-blackout-escalation)
    private func gatewayTransportClaimsConnected() -> Bool {
        guard let session = ownGatewayView()?.session else { return false }
        // tssh stays `.running` across drops; ask its health monitor instead.
        if let trzsz = Self.gatewayTrzszSession(for: session) {
            return trzsz.transportBelievesHealthy
        }
        return session.isRunning
    }

    /// Raw `detach-client` for the wedged force-exit path only, where the command
    /// queue can't flush; healthy paths use `sendTmuxDetach()`.
    /// ROOTSHELL-TMUX (id=tmux-best-effort-detach)
    private func sendBestEffortDetach() {
        guard let session = ownGatewayView()?.session else { return }
        TmuxDebugLogger.shared.event("END", "best-effort detach-client gw=\(uuidPrefix)")
        session.sendInput(Data("detach-client\n".utf8))
    }

    // MARK: - Per-window font size

    /// Absolute override per window, not a delta: the core keeps manual sizes
    /// across config reloads, so a delta would drift when the base changes.
    private var windowFontSize: [Int: Double] = [:]

    func changeFontSize(windowId: Int, delta: Int) {
        guard delta != 0, let ghosttyApp else { return }
        let base = windowFontSize[windowId] ?? FontManager.shared.currentFontSize
        let next = min(max(base + Double(delta), 1), 255)
        let effectiveDelta = Int((next - base).rounded())
        guard effectiveDelta != 0 else { return }
        windowFontSize[windowId] = next
        windowTabs[windowId]?.tmuxFontSizeOverride = next
        for view in paneViews.values
        where view.tmuxPaneBinding?.windowId == windowId {
            if let surface = view.surface {
                ghosttyApp.changeFontSize(surface: surface, delta: effectiveDelta)
            }
        }
    }

    /// Not `reset_font_size`: that restores each pane's own creation size.
    func resetFontSize(windowId: Int) {
        guard let ghosttyApp, let current = windowFontSize[windowId] else { return }
        windowFontSize[windowId] = nil
        windowTabs[windowId]?.tmuxFontSizeOverride = nil
        let delta = Int((FontManager.shared.currentFontSize - current).rounded())
        guard delta != 0 else { return }
        for view in paneViews.values
        where view.tmuxPaneBinding?.windowId == windowId {
            if let surface = view.surface {
                ghosttyApp.changeFontSize(surface: surface, delta: delta)
            }
        }
    }

    func overrideFontSize(forWindowId windowId: Int) -> Double? {
        windowFontSize[windowId]
    }

    func requestGracefulDetach(source: String) {
        // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        isDetaching = true
        ownGatewayView()?.tmuxDetachInProgressAtomic = true
        for view in paneViews.values {
            view.tmuxDetachInProgressAtomic = true
        }
        let uuidPrefix = ownerTerminalUUID.uuidString.prefix(8)
        TmuxDebugLogger.shared.event("DETACH", "requested \(source) gw=\(uuidPrefix)")

        // Context-menu / dashboard / ESC / tab-close all enter here without
        // going through MuxSessionDetach.detach — post the reconnect banner
        // from this choke point so tmux -CC matches zmx.
        let bannerTerminal = ownGatewayView()
            ?? windowTabs.values.lazy.compactMap { $0.splitTree.terminalLeaves.first }.first
        MuxSessionDetach.notifyControlModeDetached(
            sessionName: currentSessionName,
            windowId: baseWindowId,
            terminal: bannerTerminal,
            tmuxSocket: resumeSocket,
            tmuxSocketSelector: configuredResumeSocket
        )

        // Recheck after the async hops; the surface can be freed in between.
        // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        Ghostty.TerminalView.ghosttyAPIQueue.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ownerSurfaceFreed else { return }
                    ghostty_surface_tmux_detach(self.ownerSurface)
                }
            }
        }
    }

    /// Only the visible window drives the global client size.
    func isActiveWindow(windowId: Int) -> Bool {
        guard let tab = windowTabs[windowId] else { return false }
        return hostTabsModel(forWindowId: windowId).selectedTabID == tab.id
    }

    // MARK: - Per-window size push

    /// Dedups both push paths (split container and sole pane's `updatePTYSize`).
    private var lastPushedWindowSize: [Int: (cols: UInt16, rows: UInt16)] = [:]

    /// ROOTSHELL-TMUX (id=tmux-size-floor)
    private var lastLayoutPaneCount: [Int: Int] = [:]

    /// Layout each window last applied; an unchanged one skips the resize pass.
    private var lastAppliedLayout: [Int: TmuxLayoutNode] = [:]

    /// What tmux reports, which a smaller foreign client can hold below what we requested.
    private var reportedWindowCellsByWindow: [Int: (cols: UInt16, rows: UInt16)] = [:]

    /// Nudges layout on constraint-relevant changes, since an ensure-window-only
    /// batch doesn't relayout. ROOTSHELL-TMUX (id=tmux-foreign-constraint-nudge)
    private func storeReportedWindowCells(windowId: Int, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let c = UInt16(min(max(cols, 0), Int(UInt16.max)))
        let r = UInt16(min(max(rows, 0), Int(UInt16.max)))
        let old = reportedWindowCellsByWindow[windowId]
        guard old?.cols != c || old?.rows != r else { return }
        reportedWindowCellsByWindow[windowId] = (cols: c, rows: r)
        reevaluateForeignConstraint(windowId: windowId)
        // The overlay's contentRect moved even without a latch transition.
        if foreignConstrainedWindows.contains(windowId) {
            Self.nudgeLayoutInvalidation()
        }
        // Growth means a foreign client left; tmux only regrows the focused window,
        // so reclaim the rest. ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        let grew: Bool = {
            guard let old else { return false }
            return c > old.cols || r > old.rows
        }()
        if grew {
            if reclaimInFlightWindows.contains(windowId) {
                clearReclaimInFlight(windowId: windowId)
                Self.nudgeLayoutInvalidation()
            }
            scheduleReclaimAllWindowSizes()
        }
    }

    func reportedWindowCells(windowId: Int) -> (cols: UInt16, rows: UInt16)? {
        reportedWindowCellsByWindow[windowId]
    }

    /// Reported smaller than requested. Transiently true after every growing push,
    /// so UI must use the debounced `isWindowForeignConstrained`.
    /// ROOTSHELL-TMUX (id=tmux-foreign-constraint-latch)
    private func rawWindowForeignConstrained(windowId: Int, tol: UInt16 = 2) -> Bool {
        guard let reported = reportedWindowCellsByWindow[windowId],
              let requested = lastPushedWindowSize[windowId] else { return false }
        // Int math: UInt16 + tol can overflow.
        let t = Int(tol)
        return Int(reported.cols) + t < Int(requested.cols) ||
               Int(reported.rows) + t < Int(requested.rows)
    }

    /// Latches on after `foreignConstraintGrace`, clears immediately.
    /// ROOTSHELL-TMUX (id=tmux-foreign-constraint-latch)
    func isWindowForeignConstrained(windowId: Int) -> Bool {
        // Suppressed while a reclaim is in flight. ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        foreignConstrainedWindows.contains(windowId)
            && !reclaimInFlightWindows.contains(windowId)
    }

    private var foreignConstrainedWindows: Set<Int> = []
    private var foreignConstraintTimers: [Int: Task<Void, Never>] = [:]
    /// Covers a `refresh-client -C` -> `%layout-change` round-trip on a slow link.
    private static let foreignConstraintGrace: Duration = .milliseconds(800)

    /// (id=tmux-foreign-constraint-latch)
    private func reevaluateForeignConstraint(windowId: Int) {
        if rawWindowForeignConstrained(windowId: windowId) {
            guard !foreignConstrainedWindows.contains(windowId),
                  foreignConstraintTimers[windowId] == nil else { return }
            foreignConstraintTimers[windowId] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.foreignConstraintGrace)
                guard let self, !Task.isCancelled else { return }
                self.foreignConstraintTimers[windowId] = nil
                guard self.rawWindowForeignConstrained(windowId: windowId),
                      !self.didEnd else { return }
                self.foreignConstrainedWindows.insert(windowId)
                Self.nudgeLayoutInvalidation()
            }
        } else {
            foreignConstraintTimers.removeValue(forKey: windowId)?.cancel()
            if foreignConstrainedWindows.remove(windowId) != nil {
                Self.nudgeLayoutInvalidation()
            }
        }
    }

    private func clearForeignConstraint(windowId: Int) {
        foreignConstraintTimers.removeValue(forKey: windowId)?.cancel()
        foreignConstrainedWindows.remove(windowId)
        clearReclaimInFlight(windowId: windowId)
    }

    // MARK: - Reclaim sweep (auto-grow back after a foreign client detaches)

    /// Blocks re-entrant sweeps from the `pushWindowSize` calls a sweep makes.
    private var sweeping = false
    private var reclaimSweepScheduled = false
    /// Re-pushed windows awaiting growth; their overlay is suppressed meanwhile.
    private var reclaimInFlightWindows: Set<Int> = []
    private var reclaimInFlightTimers: [Int: Task<Void, Never>] = [:]
    private static let reclaimInFlightGrace: Duration = .milliseconds(1200)

    /// Re-pushes every raw-constrained window, bypassing dedup (like iTerm2's
    /// `fitLayoutToVariableSizeWindows`). Loop-safe: no growth, no `%layout-change`.
    /// ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
    func reclaimAllWindowSizes() {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed, !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        for windowId in Array(windowTabs.keys) {
            guard !hiddenWindowIds.contains(windowId),
                  !reclaimInFlightWindows.contains(windowId),
                  rawWindowForeignConstrained(windowId: windowId),
                  let size = lastPushedWindowSize[windowId] else { continue }
            lastPushedWindowSize.removeValue(forKey: windowId)   // bypass dedup -> re-send
            // Suppress only off-screen windows; the visible one would blink.
            // ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
            if !isActiveWindow(windowId: windowId) {
                markReclaimInFlight(windowId: windowId)
            }
            pushWindowSize(windowId: windowId, cols: size.cols, rows: size.rows)
        }
    }

    /// ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
    private func scheduleReclaimAllWindowSizes() {
        guard !reclaimSweepScheduled, !didEnd else { return }
        reclaimSweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reclaimSweepScheduled = false
            self.reclaimAllWindowSizes()
        }
    }

    /// Restores the overlay if tmux doesn't grow the window within the grace.
    /// ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
    private func markReclaimInFlight(windowId: Int) {
        reclaimInFlightWindows.insert(windowId)
        reclaimInFlightTimers[windowId]?.cancel()
        reclaimInFlightTimers[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reclaimInFlightGrace)
            guard let self, !Task.isCancelled else { return }
            self.reclaimInFlightTimers[windowId] = nil
            if self.reclaimInFlightWindows.remove(windowId) != nil {
                Self.nudgeLayoutInvalidation()   // reclaim didn't land -> restore overlay
            }
        }
    }

    private func clearReclaimInFlight(windowId: Int) {
        reclaimInFlightTimers.removeValue(forKey: windowId)?.cancel()
        reclaimInFlightWindows.remove(windowId)
    }

    /// Deferred since we're often mid-layout.
    private static func nudgeLayoutInvalidation() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }

    private static func layoutSize(_ node: TmuxLayoutNode) -> (cols: Int, rows: Int) {
        switch node {
        case let .pane(_, width, height, _, _):
            return (width, height)
        case let .split(_, _, width, height, _, _):
            return (width, height)
        }
    }

    /// A sole pane drives the window size itself; the split container skips it.
    func isSolePane(windowId: Int) -> Bool {
        var count = 0
        for view in paneViews.values where view.tmuxPaneBinding?.windowId == windowId {
            count += 1
            if count > 1 { return false }
        }
        return count == 1
    }

    func paneCount(inWindow windowId: Int) -> Int {
        paneViews.values.count { $0.tmuxPaneBinding?.windowId == windowId }
    }

    /// Sorted by tmux window index, for synchronous menu pickers.
    func windowSummaries() -> [(windowId: Int, index: Int, title: String)] {
        windowTabs
            .map { (windowId: $0.key, index: $0.value.tmuxWindowIndex, title: $0.value.title) }
            .sorted { $0.index < $1.index }
    }

    /// Visual order, falling back to dictionary order mid-reconcile.
    func paneSummaries(inWindow windowId: Int) -> [(paneId: Int, title: String)] {
        if let tab = windowTabs[windowId] {
            var out: [(paneId: Int, title: String)] = []
            for view in tab.splitTree.terminalLeaves {
                if let binding = view.tmuxPaneBinding, binding.windowId == windowId {
                    out.append((paneId: binding.paneId, title: view.presentation.title))
                }
            }
            if !out.isEmpty { return out }
        }
        return paneViews
            .compactMap { paneId, view in
                view.tmuxPaneBinding?.windowId == windowId
                    ? (paneId: paneId, title: view.presentation.title) : nil
            }
            .sorted { $0.paneId < $1.paneId }
    }

    /// (id=tmux-zoom)
    func isWindowZoomed(windowId: Int) -> Bool {
        windowTabs[windowId]?.splitTree.zoomed != nil
    }

    /// Resolve the controller projecting a tmux window TAB. Prefer a live pane
    /// binding whose parent surface still maps to an active controller; when the
    /// tree is empty or bindings are stale (common for background windows right
    /// after detach → reattach), fall back to `owningGatewayTerminalUUID`, then
    /// to whichever active controller still projects this tab.
    static func controller(forWindowTab tab: TabModel) -> TmuxController? {
        for view in tab.splitTree.terminalLeaves {
            if let binding = view.tmuxPaneBinding,
               let controller = controller(forOwnerSurface: binding.parentSurface),
               controller.isActive, !controller.ownerSurfaceFreed,
               TmuxWindowCloseState.matchesGateway(
                   owner: controller.ownerTerminalUUID, bindingParent: binding.parentUUID,
                   tabOwner: tab.owningGatewayTerminalUUID) {
                return controller
            }
        }
        if let owner = tab.owningGatewayTerminalUUID {
            for (_, weak) in controllersByOwnerSurface {
                guard let controller = weak.controller,
                      controller.ownerTerminalUUIDForNotifications == owner,
                      controller.isActive, !controller.ownerSurfaceFreed else { continue }
                return controller
            }
        }
        // Last resort: identity in windowTabs (UUID may be missing after a
        // reconnect race, but the controller still owns the projection).
        if let windowId = tab.tmuxWindowId {
            for (_, weak) in controllersByOwnerSurface {
                guard let controller = weak.controller, controller.isActive,
                      !controller.ownerSurfaceFreed else { continue }
                if controller.windowTabs[windowId] === tab {
                    return controller
                }
            }
        }
        return nil
    }

    /// Gateway views have no `tmuxPaneBinding`, so read the controller directly.
    /// (id=tmux-hidden-gateway)
    static func controller(forGatewayTab tab: TabModel) -> TmuxController? {
        tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController
    }

    // MARK: - Hidden-window bridges (state is private; the logic lives in
    // TmuxController+HiddenWindows.swift) (id=tmux-hidden-windows)

    /// Remove the tab immediately, retaining its projection until server prune.
    /// A failed command or missing confirmation restores it without a reconcile.
    @discardableResult
    func requestKillWindow(windowId: Int) -> Bool {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed,
              ghosttyApp?.surfaceView(for: ownerSurface)?.uuid == ownerTerminalUUID,
              let tab = windowTabs[windowId] else { return false }
        if windowCloseState.contains(windowId) { return true }
        let hostModel = hostTabsModel(forWindowId: windowId)
        guard let index = hostModel.tabs.firstIndex(where: { $0 === tab }),
              let request = windowCloseState.begin(windowID: windowId, tabIndex: index) else { return false }

        let hostId = hostWindowId(forWindowId: windowId)
        let priorOrder = hostModel.tabs.map(\.id)
        let selectedID = hostModel.selectedTabID
        let groupedNeighborID = selectedID.flatMap { hostModel.groupedCloseNeighbor(for: $0) }
        clearPendingSplitFocus(windowId: windowId)
        for view in tab.splitTree.terminalLeaves {
            view.isLogicallyFocused = false
            view.shouldBecomeFirstResponderWhenReady = false
            view.setOcclusion(false)
        }
        hostModel.tabs.removeAll { $0.id == tab.id }
        // Keep windowTabs/paneViews and their host mapping until prune, including
        // the last window: prune must still run the control-mode end teardown.
        enforceGatewayVisibleWhenGroupHidden()
        if let selectedID, selectedID == tab.id,
           let neighborID = survivingGroupedOrNearestNeighbor(
                in: hostModel, groupedCandidateID: groupedNeighborID,
                priorOrder: priorOrder, removedID: tab.id) {
            hostModel.selectedTabID = neighborID
            hostModel.pendingScrollToTabID = neighborID
        } else {
            hostModel.repairSelectionIfNeeded()
        }
        TerminalWindowRegistry.refreshSelectionAfterMutation(in: hostId, allowFocus: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.didEnd, !self.isDetaching, !self.ownerSurfaceFreed,
                  self.ghosttyApp?.surfaceView(for: self.ownerSurface)?.uuid == self.ownerTerminalUUID else {
                self.restorePendingWindowClose(windowId: windowId, request: request)
                return
            }
            do {
                self.lastCommandAt = Date()
                _ = try await self.sendCommandWithReply("kill-window -t @\(windowId)", timeout: .seconds(2))
                // A successful reply normally follows a confirming prune. Allow
                // delayed delivery, then restore if the window is still known.
                try await Task.sleep(for: .seconds(2))
            } catch {
                TmuxDebugLogger.shared.event("CLOSE", "kill-window @\(windowId) failed: \(error)")
            }
            self.restorePendingWindowClose(windowId: windowId, request: request)
        }
        return true
    }

    private func restorePendingWindowClose(windowId: Int, request: TmuxWindowCloseState.Request) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed, weakTabsModel != nil,
              let index = windowCloseState.restore(windowID: windowId, request: request),
              let tab = windowTabs[windowId] else { return }
        let hostModel = hostTabsModel(forWindowId: windowId)
        if !hostModel.tabs.contains(where: { $0 === tab }) {
            hostModel.tabs.insert(tab, at: min(index, hostModel.tabs.count))
        }
        reArmWindowSize(windowId: windowId)
        reorderTmuxTabsByIndex()
        hostModel.repairSelectionIfNeeded()
        TerminalWindowRegistry.refreshSelectionAfterMutation(
            in: hostWindowId(forWindowId: windowId), allowFocus: false)
    }

    /// The tab projecting a tmux window, if any.
    func windowTab(forWindowId windowId: Int) -> TabModel? {
        windowTabs[windowId]
    }

    /// Gates hiding the gateway tab. (id=tmux-hidden-gateway)
    var hasVisibleWindowTabs: Bool {
        windowTabs.contains { !windowCloseState.contains($0.key) && !$0.value.isHiddenTmuxWindow }
    }

    /// Re-flags tabs created before the `@hidden` reply landed.
    func applyHiddenFlagsToWindowTabs() {
        for (windowId, tab) in windowTabs {
            let hidden = hiddenWindowIds.contains(windowId)
            if tab.isHiddenTmuxWindow != hidden {
                tab.isHiddenTmuxWindow = hidden
            }
        }
    }

    /// Used on unhide, since pushes were suppressed while hidden.
    func reArmWindowSize(windowId: Int) {
        lastPushedWindowSize.removeValue(forKey: windowId)
        if isActiveWindow(windowId: windowId) { lastPushedGlobalSize = nil }
    }

    func resyncPaneSizes(windowId: Int) {
        let views = paneViews.values.filter { $0.tmuxPaneBinding?.windowId == windowId }
        DispatchQueue.main.async {
            for view in views {
                view.invalidateCachedSize()
                view.sizeDidChange(view.bounds.size)
            }
        }
    }

    /// Moves selection to the nearest visible tab, else the gateway tab.
    func moveSelectionOffTab(_ tabID: UUID) {
        guard let model = modelContainingTab(id: tabID),
              model.selectedTabID == tabID else { return }
        let order = model.tabs.map(\.id)
        let visible = Set(
            model.tabs.filter { !$0.isHiddenTmuxWindow && $0.id != tabID }.map(\.id))
        var neighbor: UUID?
        if let idx = order.firstIndex(of: tabID) {
            for i in (idx + 1)..<order.count where visible.contains(order[i]) {
                neighbor = order[i]
                break
            }
            if neighbor == nil {
                for i in stride(from: idx - 1, through: 0, by: -1) where visible.contains(order[i]) {
                    neighbor = order[i]
                    break
                }
            }
        }
        if let neighbor {
            selectTab(neighbor)
        } else if !selectGatewayTab() {
            model.repairSelectionIfNeeded()
        }
    }

    func ensureSelectionVisible() {
        let hostIds = Set(windowHostIds.values + [baseWindowId])
        for hostId in hostIds {
            (TerminalWindowRegistry.tabsModel(for: hostId) ?? TmuxWindowRegistry.tabsModel(for: hostId))?
                .repairSelectionIfNeeded()
        }
    }

    private var lastPushedGlobalSize: (cols: UInt16, rows: UInt16)?

    /// A client size is a hard downward clamp for every attached client, so a
    /// transient tiny push would shrink the window session-wide. Mirrored in the
    /// core's setClientSize. ROOTSHELL-TMUX (id=tmux-size-floor)
    static let minPushCols: UInt16 = 10
    static let minPushRows: UInt16 = 3

    /// Fallback size for windows without a per-window entry (new or unvisited
    /// after reattach). Only base-font windows may set it.
    func pushGlobalClientSize(cols: UInt16, rows: UInt16) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        guard cols >= Self.minPushCols, rows >= Self.minPushRows else {
            // Transient; don't latch the dedup.
            TmuxDebugLogger.shared.event("CMD-REJECT", "global size below floor cols=\(cols) rows=\(rows)")
            return
        }
        if let last = lastPushedGlobalSize, last == (cols, rows) { return }
        lastPushedGlobalSize = (cols, rows)
        lastCommandAt = Date()
        TmuxDebugLogger.shared.command(kind: "refresh-client -C", target: "global", bytes: 0, [("cols", cols), ("rows", rows)])
        ghostty_surface_tmux_set_client_size(ownerSurface, cols, rows)
    }

    /// `refresh-client -C @win:WxH`, pinning each window independently.
    func pushWindowSize(windowId: Int, cols: UInt16, rows: UInt16) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed,
              !windowCloseState.contains(windowId) else { return }
        guard cols >= Self.minPushCols, rows >= Self.minPushRows else {
            // Transient; don't latch the dedup.
            TmuxDebugLogger.shared.event("CMD-REJECT", "window size below floor win=\(windowId) cols=\(cols) rows=\(rows)")
            return
        }
        // Hidden windows must not clamp other clients. (id=tmux-hidden-windows)
        if hiddenWindowIds.contains(windowId) {
            TmuxDebugLogger.shared.event("CMD-REJECT", "window size for hidden win=\(windowId)")
            return
        }
        if let last = lastPushedWindowSize[windowId], last == (cols, rows) { return }
        lastPushedWindowSize[windowId] = (cols, rows)
        let cmd = "refresh-client -C @\(windowId):\(cols)x\(rows)\n"
        let data = Data(cmd.utf8)
        lastCommandAt = Date()
        TmuxDebugLogger.shared.command(kind: "refresh-client -C", target: "@\(windowId)", bytes: data.count, [("cols", cols), ("rows", rows)])
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_tmux_command(
                ownerSurface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(data.count))
        }
        // tmux may send no %layout-change if already constrained; the latch timer
        // covers that. ROOTSHELL-TMUX (id=tmux-foreign-constraint-latch)
        reevaluateForeignConstraint(windowId: windowId)
        // Active-window pushes also reclaim other constrained windows, excluding
        // this one. ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        if !sweeping, isActiveWindow(windowId: windowId),
           windowTabs.keys.contains(where: { $0 != windowId && rawWindowForeignConstrained(windowId: $0) }) {
            scheduleReclaimAllWindowSizes()
        }
    }

    // MARK: - Debug heartbeat / live-state capture

    func startHeartbeat() {
        guard TmuxDebugLogger.shared.isEnabled else { return }
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.emitHeartbeat(manual: false)
            }
        }
    }

    func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func onDebugLoggingChanged() {
        if TmuxDebugLogger.shared.isEnabled {
            if heartbeat == nil { startHeartbeat() }
        } else {
            stopHeartbeat()
        }
    }

    // MARK: - Recovery watchdog

    private var uuidPrefix: String { String(ownerTerminalUUID.uuidString.prefix(8)) }

    /// In-flight command with no block for this long is a candidate stall.
    private static let recoveryStallMs: UInt64 = 8000
    /// Output or notifications within this window mean the link is alive, so a
    /// block stall is a real desync, not a network wait. Must be < recoveryStallMs.
    private static let recoveryLiveWindowMs: UInt64 = 5000
    private static let recoveryResyncStuckMs: UInt64 = 15000
    /// Only a probe block ends a resync, so block silence (not `%output`) is the
    /// staleness signal. ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private static let recoveryResyncBlockQuietMs: UInt64 = 3000
    /// Pacing only; reprobe is a no-op without a viewer (unlike tmux_resume).
    /// ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private static let recoveryResyncProbeSpacing: TimeInterval = 3.5
    /// Quiet time after the last re-probe before force-exit may fire.
    private static let recoveryResyncPostProbeMs: UInt64 = 4000
    /// Force-exits regardless of re-probe budget.
    private static let recoveryResyncCeilingMs: UInt64 = 60000
    private static let recoveryResyncMaxReprobes = 4
    private static let recoveryMaxAttempts = 2
    /// ~60s of total foreground blackout before force-exit.
    /// ROOTSHELL-TMUX (id=tmux-blackout-escalation, id=tmux-bg-escalation-guard)
    private static let recoveryBlackoutTickLimit = 30
    /// Stall ages keep growing while suspended, so hold off escalation after
    /// foregrounding. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private static let recoveryForegroundGraceSeconds: TimeInterval = 5

    /// Keeps ticking in background on a live socket; `evaluateRecovery` guards that.
    /// ROOTSHELL-TMUX (id=tmux-recovery-watchdog, id=tmux-bg-escalation-guard)
    private func startRecoveryWatchdog() {
        recoveryWatchdog?.cancel()
        // Seeded in background: no epoch transition will arm the grace, so force it.
        // ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
        recoveryLastForegroundBackgroundEpoch = LifecycleEpoch.shared.background
        recoveryArmGraceOnNextForeground = Ghostty.isTransportFrozenByBackground
        // ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
        recoveryResyncReprobes = 0
        recoveryResyncLastProbeAt = nil
        recoveryWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.evaluateRecovery()
            }
        }
    }

    private func stopRecoveryWatchdog() {
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
    }

    /// Stops everything that dereferences `ownerSurface`. Not the didEnd teardown.
    /// ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
    func gatewaySurfaceWillBeFreed() {
        guard !ownerSurfaceFreed else { return }
        ownerSurfaceFreed = true
        releaseContentEventInterest()
        paneIdentityRefreshTask?.cancel()
        paneIdentityRefreshTask = nil
        stopRecoveryWatchdog()
        stopHeartbeat()
        focusWatchdog?.cancel()
        focusWatchdog = nil
        failAllPendingReplies(.gatewayEnded)
        // This path never sets didEnd, which normally unregisters the gauges.
        // ROOTSHELL-TMUX (id=tmux-gw-gauges, id=tmux-gateway-surface-freed)
        TmuxDebugLogger.shared.unregisterGatewayGauges(owner: Int(bitPattern: ownerSurface))
        Self.controllersByOwnerSurface.removeValue(forKey: Int(bitPattern: ownerSurface))
    }

    private func releaseContentEventInterest() {
        guard holdsContentEventInterest else { return }
        holdsContentEventInterest = false
        ghosttyApp?.setTmuxSurfaceContentEventsEnabled(
            false,
            interestID: contentEventInterestID)
    }

    /// Exits through the core, not `forceQuit()`, which would leave the core in
    /// control mode. ROOTSHELL-TMUX (id=tmux-recovery-watchdog)
    private func forceExitControlMode() {
        recoveryGaveUp = true
        // ROOTSHELL-TMUX (id=tmux-best-effort-detach)
        sendBestEffortDetach()
        ghostty_surface_tmux_force_exit(ownerSurface)
    }

    /// Catches lost replies that stall the pipeline without tripping the parser.
    /// ROOTSHELL-TMUX (id=tmux-recovery-watchdog)
    private func evaluateRecovery() {
        // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        guard !didEnd, !ownerSurfaceFreed else { stopRecoveryWatchdog(); return }
        // Awaiting the force-exit teardown reconcile.
        guard !recoveryGaveUp else { return }

        // Must run for all users, so it lives here rather than in the debug heartbeat.
        // ROOTSHELL-TMUX (id=tmux-flush-deferred-always-on)
        ghostty_surface_tmux_flush_deferred(ownerSurface)

        var snap = ghostty_tmux_debug_snapshot_s()
        guard ghostty_surface_tmux_debug_snapshot(ownerSurface, &snap) else {
            recoveryWedgeHits = 0
            // ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
            recoveryResyncReprobes = 0
            recoveryResyncLastProbeAt = nil
            return
        }

        // A desync still receives output/notifications; a dead link goes fully
        // quiet and tssh will redeliver. `total_* > 0` is required since
        // `ms_since_*` is 0 for events that never happened.
        let outputAlive = snap.total_output_events > 0
            && snap.ms_since_last_output < Self.recoveryLiveWindowMs
        let notifAlive = snap.total_notifications > 0
            && snap.ms_since_last_notification < Self.recoveryLiveWindowMs
        let transportAlive = outputAlive || notifAlive

        // Read thread blocked >5s at a site (1 gateway lock, 2 parsing, 3 pane lock,
        // 4/5 mailbox). ROOTSHELL-TMUX (id=tmux-debug-read-progress)
        if snap.read_thread_site != 0,
           snap.gw_read_enter_bytes > snap.gw_read_done_bytes,
           snap.ms_since_read_enter >= 5000 {
            TmuxDebugLogger.shared.event(
                "RECOVER",
                "READ THREAD STALLED site=\(snap.read_thread_site) pane=\(snap.read_site_pane_id) "
                + "for \(snap.ms_since_read_enter)ms (rdIn=\(snap.gw_read_enter_bytes) "
                + "rdDone=\(snap.gw_read_done_bytes) rdPut=\(snap.gw_tmux_put_bytes)) gw=\(uuidPrefix)")
        }

        // Backgrounded, the read thread is frozen and looks wedged but will thaw:
        // reset counters and never escalate.
        // ROOTSHELL-TMUX (id=tmux-bg-escalation-guard, id=tmux-blackout-escalation)
        if Ghostty.isTransportFrozenByBackground {
            if snap.command_in_flight == 1, snap.ms_since_last_block >= Self.recoveryStallMs {
                TmuxDebugLogger.shared.event(
                    "RECOVER",
                    "escalation suppressed (backgrounded) sinceBlockMs=\(snap.ms_since_last_block) "
                    + "cmdKind=\(snap.in_flight_cmd_kind) rdSite=\(snap.read_thread_site) gw=\(uuidPrefix)")
            }
            recoveryBlackoutTicks = 0
            recoveryWedgeHits = 0
            recoveryResyncReprobes = 0
            recoveryResyncLastProbeAt = nil
            recoveryResyncSawUnparsedBytes = false
            // Re-baseline so bytes replayed at thaw don't count.
            // ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
            recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
            recoveryLastProtocolEvents = snap.total_blocks &+ snap.total_notifications &+ snap.total_output_events
            return
        }
        // First foreground tick after a background (even one no tick observed):
        // reset budgets and arm the grace. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
        let bgEpoch = LifecycleEpoch.shared.background
        if bgEpoch != recoveryLastForegroundBackgroundEpoch || recoveryArmGraceOnNextForeground {
            recoveryArmGraceOnNextForeground = false
            recoveryLastForegroundBackgroundEpoch = bgEpoch
            recoveryBlackoutTicks = 0
            recoveryWedgeHits = 0
            recoveryAttempts = 0
            recoveryCooldownUntil = nil
            recoveryResyncReprobes = 0
            recoveryResyncLastProbeAt = nil
            recoveryResyncSawUnparsedBytes = false
            // ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
            recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
            recoveryLastProtocolEvents = snap.total_blocks &+ snap.total_notifications &+ snap.total_output_events
            recoveryForegroundGraceUntil = Date().addingTimeInterval(Self.recoveryForegroundGraceSeconds)
            TmuxDebugLogger.shared.event(
                "RECOVER",
                "foreground grace armed \(Self.recoveryForegroundGraceSeconds)s epoch=\(bgEpoch) gw=\(uuidPrefix)")
        }
        if let grace = recoveryForegroundGraceUntil {
            guard Date() >= grace else { return }
            recoveryForegroundGraceUntil = nil
        }

        // Re-probe a resync with no block reply. tsshd's input discard after a
        // reconnect can swallow the probe; a re-probe carries the discard marker.
        // Not gated on transportAlive. (id=tmux-resync-live-reprobe)
        if snap.viewer_state != 2 {
            recoveryResyncReprobes = 0
            recoveryResyncLastProbeAt = nil
        } else if !isDetaching,
                  snap.parser_state != 3,          // not mid-block: one IS arriving
                  snap.total_blocks > 0,           // an unset stamp reads 0 (see above)
                  snap.ms_since_last_block >= Self.recoveryResyncBlockQuietMs,
                  recoveryResyncReprobes < Self.recoveryResyncMaxReprobes,
                  Date().timeIntervalSince(recoveryResyncLastProbeAt ?? .distantPast)
                      >= Self.recoveryResyncProbeSpacing {
            recoveryResyncReprobes += 1
            recoveryResyncLastProbeAt = Date()
            TmuxDebugLogger.shared.event(
                "RECOVER",
                "resync probe unanswered (sinceBlockMs=\(snap.ms_since_last_block) "
                + "resyncAgeMs=\(snap.resync_age_ms) alive=\(transportAlive)); "
                + "re-send attempt=\(recoveryResyncReprobes) gw=\(uuidPrefix)")
            // Not tmux_resume: without a viewer it would resurrect control mode.
            // ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
            ghostty_surface_tmux_reprobe(ownerSurface)
        }

        // Live link, resync (state 2) never completes: force-exit only once every
        // re-probe went unanswered, or at the ceiling.
        // ROOTSHELL-TMUX (id=tmux-resync-progress-gate)
        if transportAlive, snap.viewer_state == 2, !recoveryGaveUp {
            // Also require block silence, or a late block would still force-exit.
            let probeQuiet = recoveryResyncLastProbeAt.map {
                Date().timeIntervalSince($0) * 1000 >= Double(Self.recoveryResyncPostProbeMs)
            } ?? false
            let blockSilent = snap.ms_since_last_block >= Self.recoveryResyncBlockQuietMs
            let probesSpent = recoveryResyncReprobes >= Self.recoveryResyncMaxReprobes
                && probeQuiet && blockSilent
            let ceilingHit = snap.resync_age_ms >= Self.recoveryResyncCeilingMs
            if ceilingHit || (snap.resync_age_ms >= Self.recoveryResyncStuckMs && probesSpent) {
                let why = ceilingHit
                    ? "ceiling \(Self.recoveryResyncCeilingMs)ms reached"
                    : "unanswered after \(recoveryResyncReprobes) re-probes"
                TmuxDebugLogger.shared.event(
                    "RECOVER",
                    "resync stuck \(snap.resync_age_ms)ms, \(why) (link alive, "
                    + "sinceBlockMs=\(snap.ms_since_last_block)); force-exit gw=\(uuidPrefix)")
                forceExitControlMode()
                return
            }
        }

        // Dead shell: tmux exited and `%exit` was lost, so bytes flow but never
        // parse. Pure silence is left to the slow blackout tier below.
        // ROOTSHELL-TMUX (id=tmux-resync-dead-shell, id=probe-echo-detach)
        let protocolEvents = snap.total_blocks &+ snap.total_notifications &+ snap.total_output_events
        // Clear outside the branch below, which skips ticks where transportAlive is true.
        let protocolAdvanced = recoveryLastProtocolEvents.map { protocolEvents != $0 } ?? false
        if protocolAdvanced {
            recoveryResyncSawUnparsedBytes = false
        }
        if snap.viewer_state == 2, !transportAlive, gatewayTransportClaimsConnected() {
            // Only idle-parser bytes count; states 2/3 may be a long block streaming.
            if !protocolAdvanced,
               snap.parser_state == 1,
               let baseline = recoveryLastTmuxPutBytes, snap.gw_tmux_put_bytes &- baseline > 0 {
                recoveryResyncSawUnparsedBytes = true
            }
            if recoveryResyncSawUnparsedBytes, snap.resync_age_ms >= Self.recoveryResyncStuckMs {
                TmuxDebugLogger.shared.event(
                    "RECOVER",
                    "resync stuck \(snap.resync_age_ms)ms, bytes without protocol (claims connected); "
                    + "force-exit gw=\(uuidPrefix)")
                recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
                forceExitControlMode()
                return
            }
        } else if snap.viewer_state != 2 {
            recoveryResyncSawUnparsedBytes = false
        }
        recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
        recoveryLastProtocolEvents = protocolEvents

        // ~60s total blackout while the transport claims connected means no
        // redelivery is coming; a self-reported drop is a recoverable wait.
        // ROOTSHELL-TMUX (id=tmux-blackout-escalation, id=tmux-resync-dead-shell)
        let blackoutStall = (snap.viewer_state == 3
                && snap.command_in_flight == 1
                && snap.ms_since_last_block >= Self.recoveryStallMs)
            || (snap.viewer_state == 2
                && snap.resync_age_ms >= Self.recoveryStallMs)
        let blackoutShape = snap.tmux_active == 1
            && snap.total_blocks > 0
            && !transportAlive
            && blackoutStall
        let blackout = blackoutShape && gatewayTransportClaimsConnected()
        if blackout {
            recoveryBlackoutTicks += 1
            if recoveryBlackoutTicks >= Self.recoveryBlackoutTickLimit {
                TmuxDebugLogger.shared.event(
                    "RECOVER",
                    "total blackout for \(recoveryBlackoutTicks) ticks "
                    + "(sinceBlockMs=\(snap.ms_since_last_block) sinceOutMs=\(snap.ms_since_last_output) "
                    + "sinceNotifMs=\(snap.ms_since_last_notification) rdSite=\(snap.read_thread_site) "
                    + "rdPane=\(snap.read_site_pane_id) rdEnterAgeMs=\(snap.ms_since_read_enter)); "
                    + "force-exit gw=\(uuidPrefix)")
                forceExitControlMode()
                return
            }
        } else {
            recoveryBlackoutTicks = 0
        }

        // Progress resets the attempt budget.
        if snap.viewer_state == 3, snap.command_in_flight == 0 {
            recoveryAttempts = 0
        }

        // Stuck command behind a queue, no block, not mid-block, link alive.
        let wedged = snap.tmux_active == 1
            && snap.viewer_state == 3            // command_queue (steady state)
            && snap.command_in_flight == 1
            && snap.command_queue_depth > 0
            && snap.parser_state != 3            // not inside an arriving block
            && snap.ms_since_last_block >= Self.recoveryStallMs
            && transportAlive

        guard wedged else {
            recoveryWedgeHits = 0
            return
        }

        recoveryWedgeHits += 1
        guard recoveryWedgeHits >= 2 else { return }

        if let until = recoveryCooldownUntil, Date() < until { return }

        if recoveryAttempts >= Self.recoveryMaxAttempts {
            TmuxDebugLogger.shared.event("RECOVER", "wedge persists after \(recoveryAttempts) recover attempts; force-exit gw=\(uuidPrefix)")
            forceExitControlMode()
            return
        }

        recoveryAttempts += 1
        recoveryWedgeHits = 0
        recoveryCooldownUntil = Date().addingTimeInterval(8)
        TmuxDebugLogger.shared.event(
            "RECOVER",
            "wedge cmdKind=\(snap.in_flight_cmd_kind) qDepth=\(snap.command_queue_depth) "
            + "sinceBlockMs=\(snap.ms_since_last_block) attempt=\(recoveryAttempts); forcing recover gw=\(uuidPrefix)")
        ghostty_surface_tmux_recover(ownerSurface)
    }

    /// tsshd dropped output while the link was down, so reset and recapture every
    /// pane. Not debounced: the core coalesces resets.
    func resetForDiscard(outputLines: Int, outputBytes: Int) {
        guard !ownerSurfaceFreed else { return }
        let selectedWindowIds = windowTabs.keys.filter { isActiveWindow(windowId: $0) }
        // Prefer the key window's focused tab; if ambiguous, let tmux pick.
        let focusedWindowIds = selectedWindowIds.filter { windowId in
            guard let focusedPane = windowTabs[windowId]?.focusedPane else { return false }
            return focusedPane.isFirstResponder
                || (focusedPane.window?.isKeyWindow == true && focusedPane.isLogicallyFocused)
        }
        let preferredWindowId = focusedWindowIds.count == 1
            ? focusedWindowIds[0]
            : (selectedWindowIds.count == 1 ? selectedWindowIds[0] : nil)
        TmuxDebugLogger.shared.event(
            "RESET",
            "discard-triggered reset outLines=\(outputLines) outBytes=\(outputBytes) "
            + "preferredWindow=\(preferredWindowId.map(String.init) ?? "server-active") gw=\(uuidPrefix)")
        ResumeDebugLogger.shared.log(
            "[\(uuidPrefix)] tmux -CC output discard (lines=\(outputLines) bytes=\(outputBytes)) "
            + "→ active-first surface reset preferredWindow=\(preferredWindowId.map(String.init) ?? "server-active")")
        // Panes inherit the gateway's suppression via parentUUID.
        TerminalBellSuppressor.suppress(
            ownerTerminalUUID, for: TerminalBellSuppressor.forcedRedraw)
        // Pane views are reused, so agent monitors would read the recapture as new input.
        TerminalBellSuppressor.suppressRebuild(ownerTerminalUUID)
        if let preferredWindowId, preferredWindowId >= 0 {
            ghostty_surface_tmux_reset_prioritized(ownerSurface, UInt(preferredWindowId))
        } else {
            ghostty_surface_tmux_reset(ownerSurface)
        }
    }

    /// Emits a STATE line (Swift counters) and a ZIG line (core snapshot).
    func emitHeartbeat(manual: Bool) {
        let dbg = TmuxDebugLogger.shared
        guard dbg.isEnabled else { return }
        let now = Date()
        let b = dbg.snapshotGatewayBytes(owner: Int(bitPattern: ownerSurface))
        let inb = dbg.snapshotGatewayInbound(owner: Int(bitPattern: ownerSurface))
        let gauges = dbg.snapshotGatewayGauges(owner: Int(bitPattern: ownerSurface))
        func ms(_ d: Date?) -> String {
            d.map { String(format: "%.0f", now.timeIntervalSince($0) * 1000) } ?? "-"
        }
        let gaugeText: String
        if let g = gauges {
            gaugeText = " pipeBuf=\(g.pipeBuffered) pipeWrote=\(g.pipeWritten) pipeDropped=\(g.pipeDropped) "
                + "gateOn=\(g.gateEnabled) gateBuf=\(g.gateBuffered)"
        } else {
            gaugeText = ""
        }
        dbg.event("STATE",
            "manual=\(manual) windows=\(windowTabs.count) panes=\(paneViews.count) "
            + "sinceReconcileMs=\(ms(lastReconcileAt)) sinceCmdMs=\(ms(lastCommandAt)) "
            + "reconciles=\(reconcileCount) didEnd=\(didEnd) "
            + "gwRaw=\(b.raw) gwFiltered=\(b.filtered) gwChunks=\(b.chunks) "
            + "gwIdleMs=\(b.msSinceLast.map { String(format: "%.0f", $0) } ?? "-") "
            + "gwIn=\(inb.bytes) gwInChunks=\(inb.chunks) "
            + "gwInIdleMs=\(inb.msSinceLast.map { String(format: "%.0f", $0) } ?? "-")"
            + gaugeText)
        if let zig = zigSnapshotLine() { dbg.event("ZIG", zig) }
    }

    /// Numeric fields only.
    private func zigSnapshotLine() -> String? {
        // ROOTSHELL-TMUX (id=tmux-snapshot-after-didend, id=tmux-gateway-surface-freed)
        guard !didEnd, !ownerSurfaceFreed else { return nil }
        var snap = ghostty_tmux_debug_snapshot_s()
        guard ghostty_surface_tmux_debug_snapshot(ownerSurface, &snap) else { return nil }
        return "viewer=\(snap.viewer_state) parser=\(snap.parser_state) tolerant=\(snap.parser_tolerant) "
            + "active=\(snap.tmux_active) forceUnhook=\(snap.force_unhook_pending) resume=\(snap.resume_pending) "
            + "inFlight=\(snap.command_in_flight) cmdKind=\(snap.in_flight_cmd_kind) "
            + "qDepth=\(snap.command_queue_depth) qHigh=\(snap.command_queue_highwater) "
            + "fifo=\(snap.sent_fifo_depth) fifoHigh=\(snap.sent_fifo_highwater) "
            + "parseErr=\(snap.parser_last_error) viewErr=\(snap.viewer_last_error) "
            + "sid=\(snap.session_id) wins=\(snap.window_count) panes=\(snap.pane_count) "
            + "retired=\(snap.retired_pane_count) paused=\(snap.paused_pane_count) "
            + "uninit=\(snap.uninitialized_pane_count) pendResp=\(snap.pending_pane_responses) "
            + "buf=\(snap.parser_buffer_bytes) bufHigh=\(snap.parser_buffer_highwater) "
            + "sinceOutMs=\(snap.ms_since_last_output) sinceBlockMs=\(snap.ms_since_last_block) "
            + "sinceCmdMs=\(snap.ms_since_last_command_sent) sinceNotifMs=\(snap.ms_since_last_notification) "
            + "viewerAgeMs=\(snap.ms_since_viewer_created) resyncMs=\(snap.resync_age_ms) "
            + "totNotif=\(snap.total_notifications) totBlocks=\(snap.total_blocks) "
            + "totOut=\(snap.total_output_events) totCmd=\(snap.total_commands_sent) "
            // ABI v2 read-thread progress. ROOTSHELL-TMUX (id=tmux-debug-read-progress)
            + "rdIn=\(snap.gw_read_enter_bytes) rdDone=\(snap.gw_read_done_bytes) "
            + "rdPut=\(snap.gw_tmux_put_bytes) rdSite=\(snap.read_thread_site) "
            + "rdPane=\(snap.read_site_pane_id) rdEnterAgeMs=\(snap.ms_since_read_enter) "
            + "rdDoneAgeMs=\(snap.ms_since_read_done) paneLockTO=\(snap.pane_lock_timeouts)"
    }

    static func captureAllState() {
        TmuxDebugLogger.shared.marker("MANUAL STATE CAPTURE")
        for (_, weak) in controllersByOwnerSurface {
            weak.controller?.emitHeartbeat(manual: true)
        }
    }
}

/// Window id -> weak `TabsModel`, for reconcile callbacks that only know the surface.
@MainActor
enum TmuxWindowRegistry {
    private final class WeakModel {
        weak var model: TabsModel?
        init(_ model: TabsModel) { self.model = model }
    }
    private static var models: [String: WeakModel] = [:]

    static func register(_ tabsModel: TabsModel, windowId: String) {
        models[windowId] = WeakModel(tabsModel)
        AgentAttentionCenter.shared.topologyDidChange()
    }
    static func unregister(windowId: String) {
        models.removeValue(forKey: windowId)
        AgentAttentionCenter.shared.topologyDidChange()
    }
    static func tabsModel(for windowId: String) -> TabsModel? {
        models[windowId]?.model
    }

    static func allTabsModels() -> [TabsModel] {
        liveModels().map(\.model)
    }

    static func allWindows() -> [(windowId: String, model: TabsModel)] {
        liveModels()
    }

    /// Every terminal leaf with its window and tab.
    static func terminalPanes() -> [(windowId: String, tab: TabModel, view: Ghostty.TerminalView)] {
        var panes: [(windowId: String, tab: TabModel, view: Ghostty.TerminalView)] = []
        for (windowId, model) in liveModels() {
            for tab in model.tabs {
                for view in tab.splitTree.terminalLeaves {
                    panes.append((windowId, tab, view))
                }
            }
        }
        return panes
    }

    /// The key window, else the one last key, else the first with a focused terminal.
    static func frontmostTabsModel() -> TabsModel? {
        let windows = liveModels()
        if let sceneID = WindowFocusRegistry.shared.mostRecentKeySceneSessionId(),
           let window = windows.first(where: {
               TerminalWindowRegistry.sceneSessionId(for: $0.windowId) == sceneID
           }) {
            return window.model
        }
        return windows.lazy.map(\.model).first(where: {
            $0.selectedTab?.focusedTerminal != nil
        }) ?? windows.first?.model
    }

    /// Sorted by window id so callers see a stable order, not hash order.
    private static func liveModels() -> [(windowId: String, model: TabsModel)] {
        var stale: [String] = []
        var live: [(windowId: String, model: TabsModel)] = []
        for (windowId, weakModel) in models {
            if let model = weakModel.model {
                live.append((windowId, model))
            } else {
                stale.append(windowId)
            }
        }
        for windowId in stale {
            models.removeValue(forKey: windowId)
        }
        live.sort { $0.windowId < $1.windowId }
        return live
    }

    static func gatewayView(ownerTerminalUUID owner: UUID) -> Ghostty.TerminalView? {
        terminalPanes().first(where: { $0.view.uuid == owner })?.view
    }

    static func gatewayTab(ownerTerminalUUID owner: UUID) -> (windowId: String, model: TabsModel, tab: TabModel)? {
        for (windowId, model) in liveModels() {
            if let tab = model.tabs.first(where: { candidate in
                candidate.splitTree.contains { $0.uuid == owner }
            }) {
                return (windowId, model, tab)
            }
        }
        return nil
    }

    /// The selected restored placeholder for a cold viewer; nil if ambiguous across scenes.
    static func selectedAwaitingWindow(ownerTerminalUUID owner: UUID) -> Int? {
        let candidates = liveModels().compactMap { _, model -> Int? in
            guard let selectedID = model.selectedTabID,
                  let tab = model.tabs.first(where: { $0.id == selectedID }),
                  tab.awaitingTmuxReconcile,
                  tab.owningGatewayTerminalUUID == owner else { return nil }
            return tab.pendingTmuxWindowId
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    @discardableResult
    static func selectGateway(ownerTerminalUUID owner: UUID, allowFocus: Bool) -> Bool {
        guard let located = gatewayTab(ownerTerminalUUID: owner) else { return false }
        located.tab.isHiddenTmuxWindow = false
        located.tab.pendingHiddenTmuxGatewayRestore = false
        located.model.selectedTabID = located.tab.id
        located.model.displayedTabID = located.tab.id
        located.model.pendingScrollToTabID = located.tab.id
        if let group = located.model.effectiveGroupID(for: located.tab) {
            located.model.activeGroupID = group
        }
        TerminalWindowRegistry.refreshSelectionAfterMutation(in: located.windowId, allowFocus: allowFocus)
        return true
    }

    @discardableResult
    static func removeAwaitingPlaceholders(ownerTerminalUUID owner: UUID) -> Int {
        var removed = 0
        for (windowId, model) in liveModels() {
            let before = model.tabs.count
            model.tabs.removeAll { tab in
                tab.awaitingTmuxReconcile && tab.owningGatewayTerminalUUID == owner
            }
            let delta = before - model.tabs.count
            guard delta > 0 else { continue }
            removed += delta
            model.repairSelectionIfNeeded()
            TerminalWindowRegistry.refreshSelectionAfterMutation(in: windowId, allowFocus: false)
        }
        return removed
    }
}

extension Ghostty.TerminalView {
    /// Called on the gateway view; lazily creates its `TmuxController`.
    @MainActor
    func applyTmuxReconcile(_ ops: [TmuxReconcileOp]) {
        let signposter = TmuxPipelineSignposts.signposter
        let signpost = signposter.beginInterval("tmux.reconcile", "ops=\(ops.count)")
        defer { signposter.endInterval("tmux.reconcile", signpost) }
        // A windowless controller would never set `didEnd` and would linger.
        if tmuxController == nil {
            let hasWindow = ops.contains { op in
                if case .ensureWindow = op { return true }
                return false
            }
            guard hasWindow else {
                TmuxDebugLogger.shared.event("RECONCILE", "ignored prune-only batch (no controller/window op) ops=\(ops.count)")
                return
            }
        }

        let controller: TmuxController
        let createdController: Bool
        if let existing = tmuxController {
            controller = existing
            createdController = false
        } else {
            guard let tabsModel = TmuxWindowRegistry.tabsModel(for: windowId),
                  let ghosttyApp = self.ghosttyApp,
                  let app = ghosttyApp.app,
                  let ownerSurface = self.surface
            else {
                Ghostty.logger.warning("tmux reconcile: missing deps for controller (window=\(self.windowId))")
                TmuxDebugLogger.shared.event("RECONCILE", "missing deps for controller gw=\(uuid.uuidString.prefix(8))")
                return
            }
            controller = TmuxController(
                tabsModel: tabsModel,
                app: app,
                ghosttyApp: ghosttyApp,
                ownerSurface: ownerSurface,
                windowId: windowId,
                ownerTerminalUUID: uuid)
            tmuxController = controller
            // Flush session info that arrived before the controller existed.
            // ROOTSHELL-TMUX (id=tmux-session-info-stash)
            if let ssh = connectionConfig.underlyingSSHConfig {
                controller.startupResumeSocket = ssh.tmuxSocketForResume
                controller.configuredResumeSocket = ssh.muxResumeTarget?.configuredTmuxSocket ?? ssh.tmuxSocketForResume
                controller.connectionKey = TmuxGatewaySessionStore.connectionKey(
                    host: ssh.host, port: ssh.port, username: ssh.username)
            }
            if let pending = pendingTmuxSessionInfo {
                pendingTmuxSessionInfo = nil
                controller.updateCurrentSession(id: pending.id, name: pending.name)
            }
            // Flush pipe-writer loss reported before the controller existed.
            // ROOTSHELL-TMUX (id=tmux-overflow-stash)
            if pendingTmuxOverflowBytes > 0 {
                let dropped = pendingTmuxOverflowBytes
                pendingTmuxOverflowBytes = 0
                controller.resetForDiscard(outputLines: 0, outputBytes: dropped)
            }
            sessionController.resetGatewayReportFilter()
            // The control stream is latency-sensitive.
            outputPipeline.setOutputCoalescingEnabled(false)
            // Off-main keystroke fast path for local tmux only; network RTT dominates remote.
            let gatewayOwnerKey = Int(bitPattern: ownerSurface)
            #if targetEnvironment(macCatalyst)
            if let catalyst = session as? CatalystLocalShellSession {
                let fastWrite = catalyst.makeNonisolatedInputSink()
                sessionController.configureGatewayFastPath(
                    fastWrite: fastWrite,
                    ownerKey: gatewayOwnerKey
                )
            } else {
                sessionController.clearGatewayFastPath()
            }
            #else
            sessionController.clearGatewayFastPath()
            #endif
            tmuxGatewayOwnerKey = gatewayOwnerKey
            // ROOTSHELL-TMUX (id=tmux-detach-size-resync)
            tmuxDetachInProgressAtomic = false
            TmuxDebugLogger.shared.marker("TMUX GATEWAY ESTABLISHED gw=\(uuid.uuidString.prefix(8))")
            TmuxDebugLogger.shared.resetGatewayBytes(owner: Int(bitPattern: ownerSurface))
            // Captured objects are nonisolated and thread-safe. ROOTSHELL-TMUX (id=tmux-gw-gauges)
            let gaugeWriter = bufferedWriter
            let gaugeGate = scrollbackRestoreOutputGate
            TmuxDebugLogger.shared.registerGatewayGauges(owner: Int(bitPattern: ownerSurface)) {
                let pipe = gaugeWriter.debugCounters
                let gate = gaugeGate.debugState
                return .init(
                    pipeBuffered: pipe.pending,
                    pipeWritten: pipe.totalWritten,
                    pipeDropped: pipe.totalDropped,
                    gateEnabled: gate.enabled,
                    gateBuffered: gate.bufferedBytes
                )
            }
            controller.startHeartbeat()
            createdController = true
        }

        let isTitleOnly = !ops.isEmpty && ops.allSatisfy { op in
            switch op {
            case .setTabTitle, .setWindowTitle:
                return true
            default:
                return false
            }
        }
        // Once the session is rebound, title-only batches need only the apply.
        // ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
        if !createdController, isTitleOnly,
           let session, tmuxReboundSession === session {
            // connectionConfig can change under the same session object.
            controller.updateGatewaySource(from: connectionConfig)
            controller.apply(ops)
            return
        }
        // Control mode is live; a pending resume succeeded.
        tmuxResumeWatchdog?.cancel()
        tmuxResumeWatchdog = nil
        restoredWasTmuxGateway = false
        tmuxResumeRequested = false
        tmuxResumeCancelRequested = false

        // Rewired every reconcile so a replaced session isn't left unwired.
        // ROOTSHELL-TMUX (id=tmux-gateway-trzsz-resolve)
        if let trzsz = TmuxController.gatewayTrzszSession(for: session) {
            trzsz.onOutputDiscarded = { [weak controller] lines, bytes in
                controller?.resetForDiscard(outputLines: lines, outputBytes: bytes)
            }
        }

        controller.updateGatewaySource(from: connectionConfig)
        controller.apply(ops)
        if !controller.didEnd {
            controller.refreshPushRouteServerIdentity()
        }

        // After apply() so an ending batch takes one branch. Keeping input stops a
        // discarded probe stranding the resync; re-asserted every reconcile.
        // ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
        if let trzsz = TmuxController.gatewayTrzszSession(for: session) {
            if controller.didEnd {
                // The plain shell honours the user's own setting again.
                trzsz.disableControlModeKeepPendingInput()
            } else {
                trzsz.enableControlModeKeepPendingInput()
            }
        }

        // Title ops can't end the controller, so skip the rest once rebound.
        tmuxReboundSession = session
        if !createdController, isTitleOnly {
            return
        }

        // ROOTSHELL-TMUX (id=tmux-skip-markgateway-on-didend)
        if !controller.didEnd {
            controller.markGatewayTab(ownerView: self)
        }

        // The local `controller` keeps it alive until this method returns.
        if controller.didEnd {
            controller.stopHeartbeat()
            sessionController.clearGatewayFastPath()
            TmuxDebugLogger.shared.unregisterGatewayGauges(owner: tmuxGatewayOwnerKey) // ROOTSHELL-TMUX (id=tmux-gw-gauges)
            tmuxGatewayOwnerKey = 0
            sessionController.resetGatewayReportFilter()
            tmuxController = nil
            restoredWasTmuxGateway = false
            tmuxResumeRequested = false
            tmuxResumeCancelRequested = false
            // Unfreeze the detach-time size flow and force a resync past the dedups.
            // ROOTSHELL-TMUX (id=tmux-detach-size-resync)
            tmuxDetachInProgressAtomic = false
            invalidateCachedSize()
            sizeDidChange(bounds.size)
            TmuxDebugLogger.shared.marker("CONTROL MODE END gw=\(uuid.uuidString.prefix(8))")
        }

        #if targetEnvironment(macCatalyst)
        if createdController || controller.didEnd {
            if controller.didEnd { localMultiplexerAttachment = nil }
            LocalMultiplexerTracker.shared.refresh()
        }
        #endif

        // A fresh controller only has the stale gateway-grid size; relayout so the
        // active window pushes the real one. ROOTSHELL-TMUX (id=tmux-resume-global-size-kick)
        if createdController, tmuxController != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
            }
        }
    }

    /// Finish a restored gateway's output gate only after saved ANSI restoration
    /// has drained and the Ghostty IO thread has entered tmux control mode.
    @MainActor
    func releaseRestoredTmuxOutputGateWhenViewerIsArmed() {
        guard restoredWasTmuxGateway else {
            outputPipeline.finishScrollbackRestoreGate()
            TerminalBellSuppressor.suppress(uuid, untilDrained: outputPipeline)
            didQueueScrollbackRestoreReplay()
            return
        }
        guard !tmuxResumeGateReleaseScheduled else { return }
        tmuxResumeGateReleaseScheduled = true

        // Arm, wait for the IO thread's active flag, then release tssh bytes.
        tmuxResumeGateReleaseTask?.cancel()
        tmuxResumeGateReleaseTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }

            self.maybeResumeTmuxControlMode()
            // Generous bound so a wedged mailbox can't poll forever.
            let maxArmPolls = 12_000
            var armPolls = 0
            while !Task.isCancelled {
                guard let surface = self.surface else {
                    self.tmuxResumeGateReleaseScheduled = false
                    self.tmuxResumeGateReleaseTask = nil
                    return
                }
                if !self.tmuxResumeRequested {
                    // User cancelled; never replay held control bytes into the shell.
                    self.outputPipeline.cancelScrollbackRestoreGate()
                    self.tmuxResumeGateReleaseScheduled = false
                    self.tmuxResumeGateReleaseTask = nil
                    return
                }
                if ghostty_surface_tmux_active(surface) {
                    TmuxDebugLogger.shared.event(
                        "RESUME",
                        "viewer armed; releasing gated tssh output gw=\(self.uuid.uuidString.prefix(8))")
                    self.outputPipeline.finishScrollbackRestoreGate()
                    TerminalBellSuppressor.suppress(self.uuid, untilDrained: self.outputPipeline)
                    self.didQueueScrollbackRestoreReplay()
                    self.scrollbackWrittenAwaitingTrailer = false
                    self.tmuxResumeGateReleaseScheduled = false
                    self.tmuxResumeGateReleaseTask = nil
                    return
                }
                armPolls += 1
                if armPolls >= maxArmPolls {
                    let shortID = self.uuid.uuidString.prefix(8)
                    Ghostty.logger.warning("tmux viewer arming poll timed out; reverting gateway \(shortID) to a plain shell")
                    TmuxDebugLogger.shared.event(
                        "RESUME",
                        "ARM TIMEOUT; sending resume_abort gw=\(shortID)")
                    ghostty_surface_tmux_resume_abort(surface)
                    self.tmuxResumeWatchdog?.cancel()
                    self.tmuxResumeWatchdog = nil
                    self.removeAwaitingTmuxPlaceholders()
                    self.outputPipeline.cancelScrollbackRestoreGate()
                    self.tmuxResumeGateReleaseScheduled = false
                    self.tmuxResumeGateReleaseTask = nil
                    return
                }
                try? await Task.sleep(
                    for: Ghostty.isTransportFrozenByBackground
                        ? .milliseconds(100)
                        : .milliseconds(5)
                )
            }
        }
    }

    /// A restored surface never saw the `ESC P 1000 p` preamble, so synthesize it.
    /// The first probe can be lost, so it is re-sent until a reconcile or timeout.
    @MainActor
    func maybeResumeTmuxControlMode() {
        guard restoredWasTmuxGateway, !tmuxResumeRequested, let surface else { return }
        tmuxResumeRequested = true
        if tmuxResumeCancelRequested {
            TmuxDebugLogger.shared.event("RESUME", "deferred cancel executing gw=\(uuid.uuidString.prefix(8))")
            ghostty_surface_tmux_resume(surface)
            ghostty_surface_tmux_resume_abort(surface)
            tmuxResumeWatchdog?.cancel()
            tmuxResumeWatchdog = nil
            tmuxResumeCancelRequested = false
            removeAwaitingTmuxPlaceholders()
            return
        }

        TmuxDebugLogger.shared.marker("RESUME START gw=\(uuid.uuidString.prefix(8))")
        let preferredWindow = TmuxWindowRegistry.selectedAwaitingWindow(
            ownerTerminalUUID: uuid)
        TmuxDebugLogger.shared.event(
            "RESUME",
            "initial probe sent preferredWindow=\(preferredWindow.map(String.init) ?? "server-active")")
        if let preferredWindow, preferredWindow >= 0 {
            ghostty_surface_tmux_resume_prioritized(surface, UInt(preferredWindow))
        } else {
            ghostty_surface_tmux_resume(surface)
        }

        tmuxResumeWatchdog?.cancel()
        tmuxResumeWatchdog = Task { @MainActor [weak self] in
            // Only foreground attempts count; a backgrounded reply is delayed, not lost.
            // ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
            var attempt = 0
            while attempt < 8 {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                if self.tmuxController != nil {
                    TmuxDebugLogger.shared.event("RESUME", "reconcile arrived attempt=\(attempt); cancel watchdog")
                    return
                }
                guard let surface = self.surface else { return }
                if Ghostty.isTransportFrozenByBackground { continue }
                attempt += 1
                TmuxDebugLogger.shared.event("PROBE", "attempt=\(attempt) controller=nil; re-send probe")
                ghostty_surface_tmux_resume(surface)  // re-send probe
            }
            guard let self, !Task.isCancelled, self.tmuxController == nil, let surface = self.surface else { return }
            let shortID = self.uuid.uuidString.prefix(8)
            Ghostty.logger.warning("tmux resume timed out; reverting gateway \(shortID) to a plain shell")
            TmuxDebugLogger.shared.event("RESUME", "TIMEOUT ~12s; sending resume_abort gw=\(shortID)")
            ghostty_surface_tmux_resume_abort(surface)
            self.removeAwaitingTmuxPlaceholders()
            TmuxDebugLogger.shared.marker("RESUME ABORT gw=\(shortID)")
            self.restoredWasTmuxGateway = false
            self.tmuxResumeRequested = false
            self.tmuxResumeCancelRequested = false
            self.tmuxResumeWatchdog = nil
        }
    }

    @MainActor
    func removeAwaitingTmuxPlaceholders(clearGatewayRestoreState: Bool = true) {
        let myUUID = uuid
        TmuxWindowRegistry.removeAwaitingPlaceholders(ownerTerminalUUID: myUUID)
        // Don't leave stale hidden state for a later manual `tmux -CC`. (id=tmux-hidden-gateway)
        if let located = TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: myUUID) {
            located.tab.pendingHiddenTmuxGatewayRestore = false
        }
        if clearGatewayRestoreState {
            restoredWasTmuxGateway = false
            tmuxResumeRequested = false
            tmuxResumeCancelRequested = false
            // ROOTSHELL-TMUX (id=tmux-overflow-stash)
            pendingTmuxOverflowBytes = 0
        }
        TmuxDebugLogger.shared.event("RESTORE", "removed awaiting placeholders gw=\(myUUID.uuidString.prefix(8))")
    }

    /// Abandons the whole pending recovery, not just one placeholder.
    @MainActor
    func cancelTmuxRestoreRecovery() {
        #if targetEnvironment(macCatalyst)
        if isRestoringLocalTmux {
            cancelLocalMultiplexerRecovery()
            return
        }
        #endif
        tmuxResumeCancelRequested = true
        if tmuxResumeRequested, let surface {
            TmuxDebugLogger.shared.event("RESUME", "cancelled by user gw=\(uuid.uuidString.prefix(8))")
            ghostty_surface_tmux_resume_abort(surface)
            tmuxResumeCancelRequested = false
            removeAwaitingTmuxPlaceholders()
        } else {
            if surface == nil {
                tmuxResumeRequested = false
            }
            removeAwaitingTmuxPlaceholders(clearGatewayRestoreState: false)
        }
        tmuxResumeWatchdog?.cancel()
        tmuxResumeWatchdog = nil
    }

    /// Queues `detach-client` through the core's FIFO; a raw write would interleave
    /// with viewer commands and leave `tmux -CC` lingering.
    @MainActor
    func sendTmuxDetach() {
        if let controller = tmuxController {
            controller.requestGracefulDetach(source: "gateway")
            return
        }
        guard let surface else { return }
        TmuxDebugLogger.shared.event("DETACH", "requested fallback gw=\(uuid.uuidString.prefix(8)) active=\(isTmuxGatewaySurfaceActive)")
        ghostty_surface_tmux_detach(surface)
    }

    /// ESC escape hatch that works even without a `TmuxController`. False for panes.
    @MainActor
    var isTmuxGatewaySurfaceActive: Bool {
        guard let surface else { return false }
        return ghostty_surface_tmux_active(surface)
    }

    /// Sends `split-window`; a local split would be overwritten by the next reconcile.
    @MainActor
    func requestTmuxSplit(_ direction: SplitTree<SplitPaneView>.NewDirection, startDirectory: String? = nil) {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        controller.noteSplitRequest(windowId: binding.windowId)
        // -h side-by-side, -v stacked, -b before the target.
        let flags: String
        switch direction {
        case .right: flags = "-h"
        case .left:  flags = "-h -b"
        case .down:  flags = "-v"
        case .up:    flags = "-v -b"
        }
        sendTmuxCommand("split-window \(flags)\(Self.tmuxStartDirectoryFlag(startDirectory)) -t %\(binding.paneId)\n",
                        to: binding.parentSurface)
    }

    /// ` -c '<dir>'` for split-window / new-window, or nothing.
    nonisolated static func tmuxStartDirectoryFlag(_ directory: String?) -> String {
        guard let directory, InitialDirectoryCommand.isSupportedDirectory(directory) else { return "" }
        return " -c " + TmuxCommandQuoting.quotedFormatLiteral(directory)
    }

    /// User-initiated focus only; echoing programmatic focus makes multiple clients
    /// oscillate. ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
    @MainActor
    func requestTmuxSelectPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        controller.requestLocalSelectPane(windowId: binding.windowId, paneId: binding.paneId)
    }

    /// Local teardown is driven entirely by the resulting reconcile.
    @MainActor
    func requestTmuxKillPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        sendTmuxCommand("kill-pane -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// When true, the caller must not close the tab locally; the prune does.
    /// ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
    @MainActor
    @discardableResult
    func requestTmuxKillWindow() -> Bool {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return false }
        TmuxDebugLogger.shared.event("CLOSE", "kill-window requested win=\(binding.windowId)")
        sendTmuxCommand("kill-window -t @\(binding.windowId)\n", to: binding.parentSurface)
        return true
    }

    /// ROOTSHELL-TMUX (id=tmux-window-reorder-server)
    @MainActor
    func requestTmuxMoveWindow(afterWindowId targetWindowId: Int) {
        sendTmuxMoveWindow(flag: "-a", targetWindowId: targetWindowId)
    }

    /// `-b` needs tmux >= 3.2; older servers reject it and the next reconcile heals.
    @MainActor
    func requestTmuxMoveWindow(beforeWindowId targetWindowId: Int) {
        sendTmuxMoveWindow(flag: "-b", targetWindowId: targetWindowId)
    }

    @MainActor
    private func sendTmuxMoveWindow(flag: String, targetWindowId: Int) {
        guard let binding = tmuxPaneBinding,
              binding.windowId != targetWindowId,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        TmuxDebugLogger.shared.event(
            "REORDER",
            "move-window \(flag) win=\(binding.windowId) target=\(targetWindowId)"
        )
        sendTmuxCommand(
            "move-window \(flag) -s @\(binding.windowId) -t @\(targetWindowId)\n",
            to: binding.parentSurface
        )
    }

    /// Targets this view's window explicitly, since tmux's current window can
    /// diverge from the selected tab.
    @MainActor
    func requestTmuxNewWindow(startDirectory: String? = nil) {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        controller.noteNewWindowRequest()
        sendTmuxCommand("new-window -a\(Self.tmuxStartDirectoryFlag(startDirectory)) -t @\(binding.windowId)\n",
                        to: binding.parentSurface)
    }

    /// Returns false when this view isn't a live gateway.
    @MainActor
    @discardableResult
    func requestTmuxNewWindowFromGateway(startDirectory: String? = nil) -> Bool {
        guard let surface, let controller = tmuxController, controller.isActive
        else { return false }
        controller.noteNewWindowRequest()
        sendTmuxCommand("new-window -a\(Self.tmuxStartDirectoryFlag(startDirectory))\n", to: surface)
        return true
    }

    /// Single-axis form, which the viewer forwards (it drops the two-axis echo).
    /// Send once on drag release.
    @MainActor
    func requestTmuxResizePane(horizontal: Bool, cells: Int) {
        guard let binding = tmuxPaneBinding, cells > 0 else { return }
        guard let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        let flag = horizontal ? "-x" : "-y"
        sendTmuxCommand("resize-pane -t @\(binding.windowId).%\(binding.paneId) \(flag) \(cells)\n", to: binding.parentSurface)
    }

    /// (id=tmux-zoom)
    @MainActor
    func requestTmuxToggleZoom() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("resize-pane -Z -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// `-d` keeps the active mark still, avoiding churn on other clients.
    @MainActor
    func requestTmuxSwapPane(withPaneId targetPaneId: Int) {
        guard let binding = tmuxPaneBinding,
              binding.paneId != targetPaneId,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("swap-pane -d -s %\(binding.paneId) -t %\(targetPaneId)\n", to: binding.parentSurface)
    }

    /// Needs 2+ panes, or the armed select flag could capture an unrelated window.
    @MainActor
    func requestTmuxBreakPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive,
              controller.paneCount(inWindow: binding.windowId) >= 2 else { return }
        controller.noteNewWindowRequest()
        sendTmuxCommand("break-pane -s %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// "@N" resolves to that window's active pane.
    @MainActor
    func requestTmuxMovePane(toWindowId targetWindowId: Int) {
        guard let binding = tmuxPaneBinding,
              binding.windowId != targetWindowId,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("move-pane -s %\(binding.paneId) -t @\(targetWindowId)\n", to: binding.parentSurface)
    }

    /// An empty title restores tmux's automatic title.
    @MainActor
    func requestTmuxRenamePane(title: String) {
        // Reject control characters rather than let quote() alter the name.
        // ROOTSHELL-TMUX (id=tmux-quote-c0)
        guard TmuxControlModeParser.isValidTmuxName(title) else { return }
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand(
            "select-pane -t %\(binding.paneId) -T \(TmuxControlModeParser.quote(title))\n",
            to: binding.parentSurface)
    }

    @MainActor
    func requestTmuxClearHistory() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("clear-history -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Non-tmux surfaces only; records the absolute size for restoration.
    @MainActor
    func changeLocalFontSize(delta: Int) {
        guard delta != 0, let surface, let ghosttyApp else { return }
        let base = fontSizeOverride ?? FontManager.shared.currentFontSize
        let next = min(max(base + Double(delta), 1), 255)
        let effectiveDelta = Int((next - base).rounded())
        guard effectiveDelta != 0 else { return }
        fontSizeOverride = next
        ghosttyApp.changeFontSize(surface: surface, delta: effectiveDelta)
    }

    @MainActor
    func resetLocalFontSize() {
        guard let surface, let ghosttyApp else { return }
        fontSizeOverride = nil
        ghosttyApp.resetFontSize(surface: surface)
    }

    /// New surfaces start at the global size, so step by `override - currentGlobal`.
    @MainActor
    func applyRestoredFontSizeOverrideIfNeeded() {
        guard let target = fontSizeOverride else { return }
        let delta = Int((target - FontManager.shared.currentFontSize).rounded())
        guard delta != 0, let surface, let ghosttyApp else { return }
        ghosttyApp.changeFontSize(surface: surface, delta: delta)
    }

    /// Changes every pane of this tmux window together. False for non-tmux views.
    @MainActor
    func applyTmuxWindowFontSize(delta: Int) -> Bool {
        guard isTmuxPane, let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return false }
        controller.changeFontSize(windowId: binding.windowId, delta: delta)
        return true
    }

    @MainActor
    func resetTmuxWindowFontSize() -> Bool {
        guard isTmuxPane, let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return false }
        controller.resetFontSize(windowId: binding.windowId)
        return true
    }

    /// Queues a newline-terminated command on the gateway's FIFO; the core copies it.
    @MainActor
    private func sendTmuxCommand(_ cmd: String, to surface: ghostty_surface_t) {
        let data = Data(cmd.utf8)
        guard !data.isEmpty else { return }
        // `surface` may be dangling: require a live controller, then confirm the
        // registry's view has the expected uuid in case the address was reused.
        // `?? uuid` covers the gateway sending on its own surface.
        // ROOTSHELL-TMUX (id=tmux-send-stale-surface, id=tmux-stale-parent-surface)
        let expectedGatewayUUID = tmuxPaneBinding?.parentUUID ?? uuid
        guard let controller = TmuxController.controller(forOwnerSurface: surface),
              controller.isActive,
              let gateway = ghosttyApp?.surfaceView(for: surface),
              gateway.uuid == expectedGatewayUUID else { return }
        // Log only the verb; command text may carry titles or keys.
        let verb = cmd.split(separator: " ").first.map(String.init) ?? "?"
        TmuxDebugLogger.shared.command(kind: verb, bytes: data.count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_tmux_command(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(data.count))
        }
    }

    /// Keyed off the selected tab, not first responder, which may still be a
    /// background pane. Nil otherwise, so ESC reaches the pane's app.
    @MainActor
    func selectedTmuxGatewayView() -> Ghostty.TerminalView? {
        guard let tabsModel = TmuxWindowRegistry.tabsModel(for: windowId),
              let selectedID = tabsModel.selectedTabID,
              let tab = tabsModel.tabs.first(where: { $0.id == selectedID }),
              tab.isTmuxGateway else { return nil }
        for view in tab.splitTree.terminalLeaves where view.tmuxController?.isActive == true || view.isTmuxGatewaySurfaceActive {
            return view
        }
        return nil
    }
}

/// Carries a reconcile batch to the main actor. `owner` is strong so the gateway
/// view survives the hop; free `payload` only after apply, since its refcounts
/// keep the viewer pointers alive (Zig id=viewer-snapshot-refcount).
nonisolated struct TmuxReconcileDelivery: @unchecked Sendable {
    let owner: Ghostty.TerminalView
    let ops: [TmuxReconcileOp]
    let payload: UnsafeMutableRawPointer
}

/// Applies batches in arrival order; separate Tasks have no ordering guarantee,
/// so a stale snapshot could land last. ROOTSHELL-TMUX (id=tmux-reconcile-serialize)
final class TmuxReconcileSerializer: @unchecked Sendable {
    static let shared = TmuxReconcileSerializer()
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @Sendable @MainActor () -> Void) {
        lock.lock()
        let prev = tail
        tail = Task { @MainActor in
            if let prev { await prev.value }
            work()
        }
        lock.unlock()
    }
}

// MARK: - User-Initiated Window Reorder

extension TmuxController {
    /// User reorder gestures only, never reconcile paths. No-ops once sibling
    /// order matches the server, so the confirming reconcile can't echo.
    /// ROOTSHELL-TMUX (id=tmux-window-reorder-server)
    @MainActor
    static func syncWindowOrderAfterUserMove(of tab: TabModel, in tabs: [TabModel]) {
        guard tab.isTmuxWindow, tab.tmuxWindowId != nil,
              let owner = tab.owningGatewayTerminalUUID else { return }

        // Placeholders have no server window yet.
        let siblings = tabs.filter {
            $0.isTmuxWindow &&
            $0.owningGatewayTerminalUUID == owner &&
            $0.tmuxWindowId != nil &&
            !$0.awaitingTmuxReconcile
        }
        guard siblings.count > 1,
              let position = siblings.firstIndex(where: { $0.id == tab.id }) else { return }

        let serverOrder = siblings.sorted { $0.tmuxWindowIndex < $1.tmuxWindowIndex }
        guard serverOrder.map(\.id) != siblings.map(\.id) else { return }

        guard let paneView = tab.splitTree.terminalLeaves.first(where: { $0.isTmuxPane }) else { return }
        if position > 0, let target = siblings[position - 1].tmuxWindowId {
            paneView.requestTmuxMoveWindow(afterWindowId: target)
        } else if let target = siblings[position + 1].tmuxWindowId {
            paneView.requestTmuxMoveWindow(beforeWindowId: target)
        }
    }
}
