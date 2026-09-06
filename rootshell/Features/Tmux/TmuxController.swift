//
//  TmuxController.swift
//  rootshell
//
//  Swift consumer of Ghostty's native tmux control mode reconcile action
//  (GHOSTTY_ACTION_TMUX_RECONCILE). The Zig core (terminal.tmux.Viewer) does
//  all protocol parsing, owns the authoritative per-pane terminals, parses
//  layouts, and emits an ordered batch of topology ops. This file decodes
//  that op batch into Swift values and (Phase 2+) applies it to native tabs
//  and splits, creating per-pane TerminalViews bound to the viewer's pane
//  terminals via ghostty_surface_new_tmux_pane.
//
//  IMPORTANT: the op batch carries raw viewer_terminal/viewer_pane pointers into
//  the Zig viewer. Their lifetime is held by the payload's per-pane refcount
//  (Zig id=viewer-snapshot-refcount): the viewer will not free a pane while a
//  payload references it. So the payload must be freed with
//  ghostty_tmux_reconcile_free only AFTER applyTmuxReconcile has consumed the
//  pointers (see TmuxReconcileDelivery / the GHOSTTY_ACTION_TMUX_RECONCILE
//  handler), which releases those holds.
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

/// A node in a tmux window's layout tree, decoded from the opaque
/// `ghostty_tmux_layout_*` accessors. Geometry is in terminal cells.
///
/// `nonisolated`: built by `TmuxReconcileDecoder.decode` on the off-main action
/// callback thread (see that type), so it must NOT pick up the project's default
/// `@MainActor` isolation. A pure value type — safe to construct/read anywhere.
nonisolated indirect enum TmuxLayoutNode: Equatable {
    case pane(paneId: Int, width: Int, height: Int, x: Int, y: Int)
    case split(direction: Direction, children: [TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)

    enum Direction: Equatable { case horizontal, vertical }

    var width: Int {
        switch self {
        case let .pane(_, w, _, _, _): return w
        case let .split(_, _, w, _, _, _): return w
        }
    }

    var height: Int {
        switch self {
        case let .pane(_, _, h, _, _): return h
        case let .split(_, _, _, h, _, _): return h
        }
    }
}

/// A single tmux reconcile operation, decoded from the C op batch.
///
/// `nonisolated`: produced by `TmuxReconcileDecoder.decode` on the off-main
/// action callback thread, so it must not inherit the default `@MainActor`
/// isolation. A pure value type, freely usable from any context.
nonisolated enum TmuxReconcileOp: Equatable {
    /// Begin an atomic reconcile transaction; defer visual updates until end.
    case syncBegin
    /// Ensure a tab exists for the tmux window (dimensions in cells). `index`
    /// is the tmux window display index, used to order the tmux tabs.
    case ensureWindow(windowId: Int, width: Int, height: Int, index: Int)
    /// Ensure a pane leaf surface exists. `viewerTerminal`/`viewerPane` are
    /// opaque pointers into the viewer; pass them to
    /// ghostty_surface_new_tmux_pane to create the bound child surface.
    case ensurePane(windowId: Int, paneId: Int, viewerTerminal: UnsafeMutableRawPointer?, viewerPane: UnsafeMutableRawPointer?)
    /// Update a window's split tree to match this layout. `zoomedPaneId` is the
    /// pane shown fullscreen when the window is zoomed, nil when not zoomed.
    /// Optional, not a 0 sentinel: `%0` is a real pane (id=tmux-zoom).
    case setLayout(windowId: Int, layout: TmuxLayoutNode, zoomedPaneId: Int?)
    /// Move focus to a window + pane.
    case setFocus(windowId: Int, paneId: Int)
    /// Remove any windows/panes whose IDs are not in these sorted sets.
    case pruneAbsent(windowIds: [Int], paneIds: [Int])
    /// Commit deferred visual updates and restore stable focus.
    case syncEnd
    /// Set a tab title (tmux window rename).
    case setTabTitle(windowId: Int, title: String)
    /// Set the window title (tmux session rename).
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

/// Pure decoder for the reconcile op batch. Stateless and `nonisolated`: it runs
/// SYNCHRONOUSLY inside the action callback (`App.action`), which the core
/// invokes on its off-main tick thread — NOT the main actor (the result is then
/// hopped to `@MainActor` via `TmuxReconcileDelivery`). It only calls the
/// `ghostty_tmux_*` C accessors and builds value types, touching no actor state,
/// so opting out of the project's default `@MainActor` isolation is both correct
/// and necessary (an implicit-`@MainActor` decode would be a fiction unenforced
/// across the C bridge). Does NOT free the payload (the caller owns it).
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

/// Applies a decoded tmux reconcile op batch to native tabs and splits for a
/// single control-mode connection (one viewer-owner surface). Owned by the
/// viewer-owner `Ghostty.TerminalView`. All mutation happens on the main actor;
/// `apply(_:)` must be called synchronously from the reconcile action callback
/// because the op batch carries live viewer pointers.
@MainActor
final class TmuxController {
    private final class WeakController {
        weak var controller: TmuxController?
        init(_ controller: TmuxController) { self.controller = controller }
    }

    private struct PendingSplitFocus {
        let existingPaneIds: Set<Int>
    }

    private static var controllersByOwnerSurface: [Int: WeakController] = [:]

    /// Weak to break a retain cycle: `tabsModel -> tabs -> splitTree -> gateway
    /// TerminalView -> tmuxController (this) -> tabsModel`, which would otherwise
    /// keep the whole tab tree alive once the scene released `tabsModel`. The
    /// controller is transitively owned by `tabsModel` (the gateway view holds it
    /// strongly and lives in `tabsModel`'s tab tree), so this is never nil while
    /// any controller method runs — `deinit` is the only thing reached after it
    /// clears, and it does not touch the model. Accessed through the `tabsModel`
    /// computed property below so the call sites stay unchanged.
    private weak var weakTabsModel: TabsModel?
    private var tabsModel: TabsModel {
        guard let model = weakTabsModel else {
            preconditionFailure("TmuxController.tabsModel accessed after its TabsModel was released")
        }
        return model
    }
    private let app: ghostty_app_t
    private weak var ghosttyApp: Ghostty.App?
    /// The viewer-owner surface (the one running `tmux -CC`). Passed as the
    /// parent to ghostty_surface_new_tmux_pane for every child pane.
    private let ownerSurface: ghostty_surface_t
    private var baseWindowId: String
    /// UUID of the gateway terminal that owns this controller. Stamped onto each
    /// window tab and persisted, so restored placeholders can be matched back to
    /// THIS gateway on resume (the terminal UUID is stable across restore; the
    /// tab UUID is not). See `ensureWindow` adoption.
    private let ownerTerminalUUID: UUID
    /// Unique registration key for this controller lifetime. Do not use the
    /// terminal UUID: a delayed deinit from an old controller could otherwise
    /// unregister its replacement.
    private let contentEventInterestID = UUID()
    /// Balanced against the Ghostty.App content-event owner registration.
    private var holdsContentEventInterest = true

    /// tmux window id -> the tab modeling it.
    private var windowTabs: [Int: TabModel] = [:]
    /// tmux window id -> rootshell app window id hosting that projected tab.
    private var windowHostIds: [Int: String] = [:]
    /// tmux pane id -> the pane view rendering it.
    private var paneViews: [Int: Ghostty.TerminalView] = [:]
    /// Throttles pane-title queries triggered by terminal output. tmux only
    /// publishes the active pane's #T through the existing window-title
    /// subscription, so split siblings need an explicit all-pane query.
    private var paneIdentityRefreshTask: Task<Void, Never>?
    /// tmux window id -> pane ids that existed when Swift requested a native
    /// tmux split. tmux normally follows `split-window` with
    /// `%window-pane-changed`, but some versions/paths only deliver the layout
    /// change promptly. This lets the layout reconcile focus the newly-created
    /// pane without guessing from tmux target aliases.
    private var pendingSplitFocus: [Int: PendingSplitFocus] = [:]
    /// Per-window expiry watchdogs for `pendingSplitFocus`, keyed by tmux window
    /// id (mirrors `pendingSelectNewWindowExpiry`). See `noteSplitRequest`.
    private var pendingSplitFocusExpiry: [Int: Task<Void, Never>] = [:]
    /// Bounded retry loop converging UIKit first responder onto the pane the
    /// latest `focusPane` marked. See `armFocusWatchdog`.
    /// ROOTSHELL-TMUX (id=tmux-focus-watchdog)
    private var focusWatchdog: Task<Void, Never>?
    /// Set once all tmux windows have been pruned (tmux exited or the client
    /// detached). `applyTmuxReconcile` observes this to drop the controller and
    /// restore the gateway surface to normal (non-control-mode) behavior.
    private(set) var didEnd = false
    /// The tab hosting THIS controller's gateway surface, captured while the
    /// controller is live (in `markGatewayTab`) so detach can re-select it
    /// deterministically — without relying on the global `isTmuxGateway` flag,
    /// which a teardown/resume cycle can clear, and which is ambiguous when more
    /// than one `tmux -CC` gateway is open in the same window.
    private var gatewayTabID: UUID?
    /// The first tmux focus op is part of initial attach and must still select
    /// the tmux window, even if the app happened to activate at the same time.
    private var hasProcessedInitialFocus = false

    // MARK: - Session dashboard state (see TmuxController+Sessions.swift)

    /// The session this gateway's control client is attached to, from
    /// GHOSTTY_ACTION_TMUX_SESSION_CHANGED (startup / switch / rename). Drives
    /// the dashboard's "current" marker and the per-connection reconnect name.
    /// Set ONLY by updateCurrentSession (TmuxController+Sessions.swift; an
    /// extension can't reach a private(set) setter cross-file).
    var currentSessionId: Int?
    var currentSessionName: String?
    /// Connection identity ("user@host:port") of the gateway's SSH connection,
    /// stamped at construction. Keys the per-connection last-session-name store
    /// so a from-scratch reconnect reattaches to the session the user was on.
    /// Nil for connections without a stable identity (e.g. local shell).
    var connectionKey: String?
    /// User-facing source of the gateway terminal that owns this controller.
    /// The dashboard shows this so multiple tmux gateways can be distinguished.
    private(set) var gatewaySourceDisplayName = String(localized: "Gateway")
    private(set) var gatewaySourceSystemImage = "terminal"
    /// Opaque `(host, socket, server pid, server start time)` identity shared
    /// by every control client connected to this exact tmux server lifetime.
    /// Combined with the server-global pane ID for device-independent push
    /// notification routing.
    var pushRouteServerIdentity: String?
    /// Prevents reconcile and foreground retry triggers from launching
    /// overlapping server-identity queries.
    var pushRouteServerIdentityTask: Task<Void, Never>?
    /// Correlation tags for in-flight `sendCommandWithReply` requests
    /// (ghostty_surface_tmux_command_with_reply). Tag 0 is never used.
    var nextReplyTag: UInt32 = 1
    var pendingReplies: [UInt32: CheckedContinuation<TmuxCommandReply, any Error>] = [:]
    var replyTimeouts: [UInt32: Task<Void, Never>] = [:]
    /// Last successful `list-sessions` result. Context menus are built by
    /// synchronous ViewBuilders, so the "Move to Session" pickers read this
    /// cache instead of awaiting a round trip; refreshed by every
    /// listSessions() call (set in TmuxController+Sessions.swift — an
    /// extension can't reach a private(set) setter cross-file).
    var cachedSessions: [TmuxControlSession] = []
    /// Window ids hidden in the ATTACHED session (windows that exist on the
    /// server but project no visible tab). Mirrors the session's `@hidden`
    /// user option; mutated ONLY by TmuxController+HiddenWindows.swift and
    /// the prune path. Per-session: reloaded on attach/switch.
    var hiddenWindowIds: Set<Int> = []
    /// Armed when THIS device asked tmux to switch sessions (dashboard). The
    /// switch reconcile replaces every window in one batch; while armed, its
    /// focus op is treated like initial attach so the new session's current
    /// window gets selected (remote-focus suppression would otherwise strand
    /// the user on whichever surviving tab the prune lands on). Expires like
    /// `pendingSelectNewWindow` so a failed switch can't leave it armed.
    var pendingSessionSwitch = false
    var pendingSessionSwitchExpiry: Task<Void, Never>?
    private var pendingSessionSwitchWindowSelection: Int?

    /// The gateway surface, exposed for the session-ops extension
    /// (TmuxController+Sessions.swift) to issue query commands on.
    var gatewaySurfaceForCommands: ghostty_surface_t { ownerSurface }
    /// The owning gateway terminal UUID, exposed for the session-ops
    /// extension's NotificationCenter posts (dashboard scoping).
    var ownerTerminalUUIDForNotifications: UUID { ownerTerminalUUID }

    /// Arm `pendingSessionSwitch` with a ~10s expiry (must outlive one
    /// switch round-trip on a slow link; mirrors `noteNewWindowRequest`).
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

    /// Consume a pending session-switch request. Returns true if armed.
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

    /// Live-state heartbeat task. Runs only while a gateway is established AND
    /// tmux debug logging is enabled, so there is no timer when logging is off.
    /// Lifetime is bounded by the controller (stopped on prune/forceQuit/deinit).
    private var heartbeat: Task<Void, Never>?
    /// Observer for the debug-logging toggle so the heartbeat can start/stop
    /// mid-session without polling.
    private var debugToggleObserver: NSObjectProtocol?
    /// Wall-clock of the last applied reconcile / last command sent, surfaced in
    /// the heartbeat so a hung log shows when activity stopped.
    private var lastReconcileAt: Date?
    private var lastCommandAt: Date?
    private var reconcileCount = 0
    /// The most recently APPLIED full-topology op batch (one that starts with
    /// `.syncBegin`), used to skip redundant identical reconciles. tmux re-emits
    /// the whole topology on every notification, and a backlog (a foregrounding
    /// burst, or the setLayout -> pushWindowSize -> %layout-change loop) delivers
    /// the SAME snapshot many times back to back. See `apply`. ROOTSHELL-TMUX
    /// (id=tmux-reconcile-dedup)
    private var lastAppliedTopologyOps: [TmuxReconcileOp]?
    private var skippedDuplicateReconciles = 0

    // MARK: - Recovery watchdog (always-on)

    /// Always-on watchdog that polls the core viewer snapshot and drives a live
    /// re-resync (`ghostty_surface_tmux_recover`) when the command/response
    /// pipeline wedges — a command stuck in-flight behind a growing queue with no
    /// inbound blocks. This is the backstop for desyncs the core can't self-heal
    /// in-band (a "clean" mid-stream data loss that shifts the block stream
    /// without tripping the parser): the tsshd buffer overflowing while the app
    /// is backgrounded is the motivating case. Runs regardless of the debug-log
    /// toggle (unlike `heartbeat`); bounded by the controller lifetime.
    private var recoveryWatchdog: Task<Void, Never>?
    /// Consecutive watchdog ticks the wedge predicate has held (debounce).
    private var recoveryWedgeHits = 0
    /// Suppress re-firing while a triggered recovery is still settling.
    private var recoveryCooldownUntil: Date?
    /// Recoveries fired without the pipeline returning to healthy progress; after
    /// the cap we give up and force-exit control mode rather than loop.
    private var recoveryAttempts = 0
    /// Set once we have given up and asked the core to force-exit control mode, so
    /// the watchdog stops acting while the teardown reconcile is in flight (it
    /// arrives async and sets `didEnd`, which stops the watchdog).
    private var recoveryGaveUp = false
    /// Consecutive FOREGROUND watchdog ticks the total-blackout predicate has
    /// held (a command stuck in flight while ALL inbound traffic is silent —
    /// blocks, output, and notifications). Reset to 0 every backgrounded tick by
    /// the explicit background-escalation guard in `evaluateRecovery` — do NOT
    /// rely on `Task.sleep` suspending while backgrounded; an active tssh/KCP
    /// socket keeps this watchdog ticking for 60+s of background execution (a
    /// confirmed false-positive force-exit started here). ROOTSHELL-TMUX
    /// (id=tmux-blackout-escalation, id=tmux-bg-escalation-guard)
    private var recoveryBlackoutTicks = 0
    /// Deadline until which ALL recovery escalation is held off after a
    /// background→foreground transition, so the frozen transport read thread can
    /// thaw and redeliver buffered replies before we judge the pipeline wedged.
    /// nil = no grace active. See `recoveryForegroundGraceSeconds`. ROOTSHELL-TMUX
    /// (id=tmux-bg-escalation-guard)
    private var recoveryForegroundGraceUntil: Date?
    /// `LifecycleEpoch.shared.background` as of our last FOREGROUND tick. A change
    /// means a background transition happened since — detectable even if
    /// `Task.sleep` suspended through the whole blip and no backgrounded tick ran
    /// (the epoch bumps synchronously at background entry). Only ever written on
    /// the foreground path. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private var recoveryLastForegroundBackgroundEpoch: UInt64 = 0
    /// Set when the watchdog is seeded while the app is ALREADY backgrounded (a
    /// tmux reconcile/resume that lands and creates the controller during
    /// background — reconciles still process backgrounded). Such a controller
    /// accrues stale wall-clock ages (`resync_age_ms` / block ages) during the
    /// suspend WITHOUT an epoch transition of its own, so the epoch-delta check
    /// alone would not arm the first-foreground grace and the first foreground
    /// tick could force-exit on those stale ages. This forces that grace once on
    /// the first foreground tick. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
    private var recoveryArmGraceOnNextForeground = false
    /// Probe re-sends during the current stuck resync; bounded by
    /// `recoveryResyncMaxReprobes`. ONE budget shared by the single re-probe site
    /// (id=tmux-resync-live-reprobe) — the dead-shell tier no longer re-probes on
    /// its own, so a live-link stall can no longer exhaust the budget that keeps
    /// the dead-shell echo matcher armed (`control.zig` nulls `probe_echo` on any
    /// completed block, so re-probing is the only thing that re-arms it).
    private var recoveryResyncReprobes = 0
    /// When the last resync probe was re-sent, for `recoveryResyncProbeSpacing`
    /// and the force-exit tier's post-probe grace. nil = none this resync.
    /// ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private var recoveryResyncLastProbeAt: Date?
    /// The current stuck resync has received bytes that produced ZERO protocol
    /// progress (no blocks/notifications) — the "link delivers unparseable
    /// bytes" discriminator vs pure silence (a network-redelivery wait).
    /// ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryResyncSawUnparsedBytes = false
    /// `gw_tmux_put_bytes` (bytes reaching the hooked control parser) as of the
    /// last evaluated foreground tick; nil until first observed. Re-baselined on
    /// background/grace transitions so suspend-era bytes are never counted.
    /// ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryLastTmuxPutBytes: UInt64?
    /// Parsed protocol events (blocks + notifications + %output) as of the last
    /// evaluated foreground tick; any advance proves the remote speaks the
    /// control protocol and clears `recoveryResyncSawUnparsedBytes` — even
    /// pre-marker blocks that resync DROPS still PARSE and count here.
    /// ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
    private var recoveryLastProtocolEvents: UInt64?
    /// Set when the owning gateway TerminalView's surface is being torn down
    /// (cleanup/teardownSurface). `ownerSurface` is a raw pointer captured at
    /// init; after this it is dangling, so every ghostty_surface_* ABI call on
    /// it must stop. `private(set)` so cross-file extensions
    /// (TmuxController+Sessions / +HiddenWindows) and the dashboard view can
    /// read it in their own surface-deref guards. ROOTSHELL-TMUX
    /// (id=tmux-gateway-surface-freed)
    private(set) var ownerSurfaceFreed = false

    /// True while control mode has live windows. The gateway view reads this to
    /// decide whether ESC should detach (only on the gateway, and only while a
    /// tmux session is actually attached) versus passing through to a pane app.
    var isActive: Bool { !isDetaching && !windowTabs.isEmpty }

    /// True while this controller still has projected tmux window tabs that would
    /// be orphaned if the gateway were closed without a live `%exit` reconcile to
    /// prune them. Unlike `isActive`, this stays true during a pending graceful
    /// detach (`isDetaching`): the window tabs are still on screen between
    /// `detach-client` and `%exit`, so a gateway-split close in that gap must
    /// still force a local prune. `windowTabs` empties only via the prune that
    /// sets `didEnd`, so this is implicitly false once control mode has ended.
    /// ROOTSHELL-TMUX (id=tmux-gateway-close-cascade)
    var hasProjectedWindows: Bool { !windowTabs.isEmpty }

    /// Set as soon as the user requests a graceful detach. Between
    /// `detach-client` being queued and `%exit` tearing down control mode, SwiftUI
    /// layout can still fire size/focus callbacks. Those must not enqueue more
    /// tmux commands, because they can land after tmux has already returned to
    /// the shell and show up as plain bash input.
    private(set) var isDetaching = false

    /// Set by the "Detach Session & Close Gateway" tab-close action just before
    /// the graceful detach. When `%exit` empties all windows and the gateway tab
    /// reverts to a plain shell, the teardown closes that tab instead of
    /// reselecting it. (id=tmux-tab-close-action)
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

        // Start/stop the heartbeat when the debug toggle flips mid-session.
        // Capture only the Sendable surface key (not self) so the @Sendable
        // observer block is concurrency-clean; resolve back through the registry
        // on the main actor.
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

        // The recovery watchdog is ALWAYS on (not gated on debug logging): it is
        // the backstop that un-wedges a desynced/data-lost gateway. Started here
        // so it covers the controller's whole lifetime; bounded by it (stopped on
        // control-mode end; the task holds weak self so it dies with the object).
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
        // Drain any still-pending dashboard replies. The normal end paths
        // (prune's didEnd branch, forceQuit) already fail them, but a release
        // OUTSIDE those paths (scene teardown mid-query) must not leak a
        // checked continuation: the per-request timeout tasks hold weak self,
        // so after this point they can no longer resume it. Stored-property
        // access and resuming a Sendable continuation are both legal from a
        // nonisolated deinit.
        for task in replyTimeouts.values { task.cancel() }
        pushRouteServerIdentityTask?.cancel()
        for continuation in pendingReplies.values {
            continuation.resume(throwing: TmuxCommandError.gatewayEnded)
        }
        // TerminalView.deinit deliberately handles the safety-net path where
        // cleanup() was missed. Normal prune/surface teardown releases this
        // registration synchronously; this idempotent, lifetime-unique release
        // covers that final path without assuming which actor ran deinit.
        let interestID = contentEventInterestID
        Task { @MainActor in
            Ghostty.App.shared?.setTmuxSurfaceContentEventsEnabled(
                false,
                interestID: interestID)
        }
        // The heartbeat and recovery-watchdog tasks hold a weak self, so they
        // self-terminate after this; nothing else to do off the main actor here.
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
        // Expiry watchdog, mirroring `pendingSelectNewWindow`: a rejected or
        // never-fulfilled split must not leave an entry armed that later makes a
        // genuinely-remote focus on this window evaluate as local (see
        // `isLocalSplitFocus`) and steal the visible tab. The local split
        // round-trips well inside the deadline, so it is normally consumed first.
        pendingSplitFocusExpiry[windowId]?.cancel()
        pendingSplitFocusExpiry[windowId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.pendingSplitFocus.removeValue(forKey: windowId)
            self.pendingSplitFocusExpiry.removeValue(forKey: windowId)
        }
    }

    /// Clear a pending split-focus entry and cancel its expiry watchdog.
    private func clearPendingSplitFocus(windowId: Int) {
        pendingSplitFocus.removeValue(forKey: windowId)
        pendingSplitFocusExpiry[windowId]?.cancel()
        pendingSplitFocusExpiry.removeValue(forKey: windowId)
    }

    /// Set when THIS device asked tmux to create a new window (via the tab
    /// menu). The next genuinely-new window tab created by `ensureWindow`
    /// (not an adopted placeholder) while this is armed takes selection +
    /// scroll, so the new tab opens AND becomes visible. tmux's remote focus
    /// is otherwise ignored (see `setFocus`), so without this the window is
    /// added but not switched to.
    ///
    /// Armed with a short expiry watchdog (`pendingSelectNewWindowExpiry`) so a
    /// failed/no-op `new-window`, or one whose window never arrives, cannot
    /// leave the request armed to later capture an unrelated window — e.g. one
    /// a remote client attached to the same session creates. The local
    /// window-add round-trips well inside the deadline, so in practice our own
    /// window consumes it first; the deadline only bounds the failure case.
    /// (Perfectly distinguishing our window from a concurrent remote one would
    /// need the `new-window` reply's window id, which the control-mode viewer
    /// does not surface to Swift.) Cleared on consumption or expiry.
    private var pendingSelectNewWindow = false
    private var pendingSelectNewWindowExpiry: Task<Void, Never>?

    /// Arm `pendingSelectNewWindow` and (re)start its expiry watchdog.
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

    /// Consume a pending local new-window request: clear the flag and cancel
    /// its expiry watchdog. Returns true if a request was armed.
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
        // The reconcile owner is retained across an async hop (the GhosttyApp
        // action callback Task), so this can run just after the scene released
        // the TabsModel. That ref is weak; applying topology into a released
        // model is pointless and would trip the `tabsModel` precondition. Bail
        // cleanly instead of crashing. ROOTSHELL-TMUX (id=tmux-apply-tabsmodel-guard)
        guard weakTabsModel != nil else {
            TmuxDebugLogger.shared.event("RECONCILE", "tabsModel released; skip apply ops=\(ops.count)")
            return
        }

        // Title-only batches arrive once per OSC title frame and need none of
        // the topology bookkeeping below. ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
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

        // Topology cap backstop: the core viewer enforces the same caps
        // (viewer.zig MAX_WINDOWS / MAX_TOTAL_PANES + the layout parser's
        // node cap), so a batch this size never arrives from a healthy
        // build. If one does (core regression, hostile server reaching a
        // path the Zig caps miss), refuse it wholesale BEFORE allocating a
        // TabModel / Metal-backed TerminalView per entry on the main actor
        // — an unbounded batch is a one-shot OOM + watchdog kill. Rejecting
        // the whole batch (rather than truncating) keeps window/pane/layout
        // state internally consistent; tmux re-emits and each re-emit is
        // rejected by this same cheap O(ops) scan. ROOTSHELL-TMUX
        // (id=viewer-topology-caps)
        if Self.exceedsTopologyCaps(ops) {
            TmuxDebugLogger.shared.event("RECONCILE", "REJECTED over-cap topology ops=\(ops.count)")
            return
        }

        // Coalesce redundant full-topology reconciles. tmux rebuilds and re-emits
        // the entire window/pane topology on every notification (each
        // %layout-change, each list-windows reply), so a backlog delivers the SAME
        // snapshot many times back to back (the log shows identical `decoded ops=N`
        // batches applied dozens of times). Re-applying an identical topology
        // rebuilds every window's split tree AND re-pushes per-window sizes via
        // setLayout's async sizeDidChange, which makes tmux emit another
        // %layout-change — a self-sustaining loop. Skipping a duplicate avoids the
        // wasted main-actor rebuild and breaks that loop. Only full-topology
        // batches (which start with `.syncBegin`) are deduped; focus/title 1-op
        // batches always apply. `TmuxReconcileOp`'s `==` ignores the raw viewer
        // pointers, so two identical topologies compare equal. ROOTSHELL-TMUX
        // (id=tmux-reconcile-dedup)
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
                // Order this gateway's tmux tabs by tmux window index now that all
                // ensure_window ops in the batch have refreshed the indices.
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
        // Remember this topology so an identical follow-up batch is skipped. Only
        // full-topology batches are tracked (focus/title 1-op batches leave the
        // last topology intact). A batch with a failed ensurePane/setLayout is
        // NOT recorded: tmux re-emits the identical topology on every
        // notification, and recording the failure would make the dedup skip
        // every retry, freezing the desync permanently. ROOTSHELL-TMUX
        // (id=tmux-reconcile-dedup, id=tmux-reconcile-dedup-failure)
        if isFullTopology, !batchFailed { lastAppliedTopologyOps = ops }
        // Newly projected panes are created before SwiftUI observes the final
        // tmux window selection. Reconcile once from the completed topology so
        // every non-selected window is occluded immediately; otherwise all of
        // its Metal surfaces retain swap chains until the first manual tab
        // switch happens to run MainView's normal visibility sweep.
        if !Set(paneViews.keys).subtracting(paneIDsBeforeApply).isEmpty {
            let hostWindowIDs = Set(windowHostIds.values).union([baseWindowId])
            for hostWindowID in hostWindowIDs {
                TerminalWindowRegistry.refreshSelectionAfterMutation(
                    in: hostWindowID,
                    allowFocus: false)
            }
        }
        // Pane identity follows topology changes here and terminal content via
        // notePaneContentChanged. Title ops never schedule it: the #T
        // subscription already carries the active pane's title, and
        // `select-pane -T` changes #{pane_title}, which fires that same
        // subscription. ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
        if isFullTopology {
            schedulePaneIdentityRefresh(after: .milliseconds(150))
        }
    }

    /// Terminal output may carry a new OSC title in any split, including a
    /// non-active tmux pane that does not drive the window's #T subscription.
    /// Coalesce that high-rate signal into at most one all-pane query every
    /// couple of seconds.
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
            }
        }
    }

    /// The app-level content signal is hard-disabled in the background. Cancel
    /// delayed queries on entry, then force one all-pane refresh on foreground
    /// so title changes that occurred while suspended are not lost.
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

    /// Maximum windows in one reconcile batch and maximum panes total /
    /// per window. Mirrors the Zig viewer's caps (viewer.zig MAX_WINDOWS=128,
    /// MAX_TOTAL_PANES=512), which enforce first; this is defense in depth.
    /// ROOTSHELL-TMUX (id=viewer-topology-caps)
    static let maxTopologyWindows = 128
    static let maxTopologyPanes = 512

    /// O(ops) pre-scan of a reconcile batch against the topology caps. A
    /// full-topology batch re-lists every window/pane, so op counts ARE the
    /// totals; focus/title batches contain no ensure ops and trivially pass.
    /// ROOTSHELL-TMUX (id=viewer-topology-caps)
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
                // A layout tree can reference panes without ensure ops in a
                // malformed batch; bound it independently.
                if paneCount(layout) > maxTopologyPanes { return true }
            default:
                break
            }
        }
        return false
    }

    /// True when every tab the controller believes it projects is still in
    /// the model. A tab removed behind the controller's back (a local close
    /// path) means an "identical" topology re-emit is actually the healing
    /// apply (ensureWindow's self-heal recreates the tab), so the dedup must
    /// not skip it. While detaching (or after end) incoherence is instead an
    /// intentional local close that ensureWindow will NOT heal, so report
    /// coherent and let the dedup skip. O(tabs + windows); both counts are
    /// small. ROOTSHELL-TMUX (id=tmux-reconcile-dedup, id=tmux-window-tab-close-server)
    private func topologyStateCoherent() -> Bool {
        guard !windowTabs.isEmpty, !isDetaching, !didEnd else { return true }
        let coherent = windowTabs.allSatisfy { windowId, tab in
            hostTabsModel(forWindowId: windowId).tabs.contains(where: { $0.id == tab.id })
        }
        if !coherent {
            TmuxDebugLogger.shared.event("RECONCILE", "dedup bypass: stale window tab; applying")
        }
        return coherent
    }

    /// Log one decoded op as ids/sizes/counts only — titles are redacted, layout
    /// geometry is reduced to pane/depth counts (never the tree content).
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
        // Refresh the display index on every reconcile so move-window / swap-window
        // re-order the tabs (the reorder runs at syncEnd). (id=tmux-window-order)
        if let existing = windowTabs[windowId] {
            if hostModel.tabs.contains(where: { $0 === existing }) || isDetaching || didEnd {
                // While detaching (or after end) a stale entry is an
                // INTENTIONAL local close (closeTab's kill-window fallback):
                // do not resurrect the tab from a queued reconcile. Keeping
                // the entry also keeps the %exit prune's hadWindows gate
                // true, so the control-mode-end teardown still runs and
                // sweeps it. ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
                existing.tmuxWindowIndex = index
                return
            }
            // The tab was removed from the model without telling the
            // controller (any local-close path). Drop the stale window entry
            // and this window's stale pane views (setLayout must never
            // rebuild a tree from them), then fall through to recreate the
            // tab. cleanup() is idempotent (surface-nil guarded), so it is
            // safe on views a local close already cleaned, and it properly
            // frees surfaces if some path removed the tab without cleaning.
            // ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
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
            // Reset per-window bookkeeping the same way prune does, so the
            // recreated window pushes a fresh size and layout state.
            windowFontSize.removeValue(forKey: windowId)
            lastPushedWindowSize.removeValue(forKey: windowId)
            lastLayoutPaneCount.removeValue(forKey: windowId)
            reportedWindowCellsByWindow.removeValue(forKey: windowId)
            clearForeignConstraint(windowId: windowId)
            clearPendingSplitFocus(windowId: windowId)
        }

        // Adopt a restored placeholder for this window (same gateway) instead of
        // appending a fresh tab, so it keeps its saved tab-bar position. The
        // placeholder's title is preserved until the reconcile's set_tab_title op
        // (later in this batch) refreshes it; its live panes are created by the
        // ensure_pane / set_layout ops that follow.
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
            // Re-derive hidden from the live set (mirror-seeded before the
            // first reconcile), overriding whatever the saved placeholder
            // carried. (id=tmux-hidden-windows)
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
        // A window in the session's hidden set materializes hidden — it must
        // never flash visible or take selection. Our own new-window request
        // is never pre-hidden, so skipping the whole selection block here is
        // safe (the armed request stays armed for the window it was meant
        // for). (id=tmux-hidden-windows)
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

    /// Order this gateway's tmux window tabs by their tmux window index, leaving
    /// non-tmux tabs (and the gateway tab) in place. Reflects new-window -a /
    /// move-window / swap-window. This is a pure permutation: tabs are only
    /// reordered WITHIN the slots this gateway's tmux tabs already occupy — never
    /// added, removed, or moved across non-tmux tabs — and selection (tracked by
    /// id, not index) is unaffected. ROOTSHELL-TMUX (id=tmux-window-order)
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
            for (slot, tab) in zip(slots, sorted) {
                hostModel.tabs[slot] = tab
            }
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
            // move-pane / break-pane keep the pane id but change its WINDOW. The
            // full-topology reconcile re-emits ensure_pane under the NEW window;
            // re-bind so isSolePane()/paneCount() and the size-push routing track
            // the move. Without this the destination (now 2 panes) is mis-counted
            // as a sole pane, so its surviving pane drives the window size via the
            // single-pane updatePTYSize path WHILE the multi-pane container also
            // drives it — two sizes differing by the split chrome ping-pong
            // through %layout-change (the destination tab "bounces"). Gated on a
            // real window change, so stable panes (re-emitted every reconcile)
            // skip the rebind. ROOTSHELL-TMUX (id=tmux-move-pane-rebind)
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
                // The pane left its old window's tab, so prune it there NOW rather
                // than waiting for that window's own %layout-change (which may fail
                // and retry, see id=tmux-reconcile-dedup-failure). A pane sitting in
                // two split trees gives both tabs an equal
                // `SplitTree.structuralIdentity` — SwiftUI rejects the resulting
                // duplicate display-list identity with a "repeated view" fatal error
                // — and makes both SplitTreeHostingViews yank the same UIView back
                // and forth on every layout pass.
                if let previousWindowId,
                   let previousTab = windowTabs[previousWindowId],
                   previousTab !== newTab,
                   let previousRoot = previousTab.splitTree.root,
                   let leafNode = previousRoot.node(view: existing) {
                    let hadFocus = previousTab.focusedPane === existing
                    let nextFocus = previousRoot.findNeighbor(of: leafNode)?.leftmostLeaf()
                    previousTab.splitTree = previousTab.splitTree.remove(leafNode)
                    // Disarm the departing pane unconditionally — not just when it
                    // was the recorded focusedPane. A failed or superseded focus
                    // attempt leaves shouldBecomeFirstResponderWhenReady set on
                    // panes that never became the tab's focus, the flag survives
                    // the move, and the destination host's reparent re-runs
                    // didMoveToWindow, which consumes it and hands the keyboard to
                    // an invisible pane in another tab. Only picking and activating
                    // a replacement depends on hadFocus.
                    // (id=tmux-focus-stale-flag)
                    existing.isLogicallyFocused = false
                    existing.shouldBecomeFirstResponderWhenReady = false
                    existing.clearStaleGhosttyFocus()

                    let hostModel = modelContainingTab(id: previousTab.id) ?? tabsModel
                    let sourceIsSelected = hostModel.selectedTabID == previousTab.id
                    if hadFocus, sourceIsSelected, let nextTerminal = nextFocus?.asTerminal {
                        // Visible tab: focusPane is the funnel. It still sees
                        // `existing` as this tab's focusedTerminal, so it unfocuses
                        // it with skipResign (no keyboard bounce) while driving
                        // first responder onto the replacement.
                        focusPane(nextTerminal, in: previousTab)
                    } else {
                        if hadFocus {
                            // Background source tab, emptied tree, or a
                            // non-terminal neighbor. focusPane is wrong here: its
                            // paneViews sweep and its arming of the replacement
                            // both run BEFORE its selected-tab guard, so it would
                            // strip logical focus from the pane the user is
                            // actually looking at and arm a background pane to
                            // claim first responder on the next host rebuild.
                            previousTab.focusedPane = nextFocus
                            if let nextTerminal = nextFocus?.asTerminal {
                                nextTerminal.isLogicallyFocused = false
                                nextTerminal.shouldBecomeFirstResponderWhenReady = false
                            }
                        }
                        // Nothing is taking the responder over here, so the
                        // departing pane has to hand it back itself.
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
        // Initialize the keyboard-ownership gate at birth. focusPane arms
        // shouldBecomeFirstResponderWhenReady, so this pane will attempt
        // becomeFirstResponder via didMoveToWindow as soon as it attaches —
        // potentially before focusPane runs. If it is born while an overlay
        // (tab/connection sidebar) owns the keyboard, a stale-false gate would
        // let it steal first responder; seed it from the window's current state.
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
            // A malformed/out-of-order batch must not leave an unattached pane
            // consuming a full visible surface's GPU resources.
            view.setOcclusion(false)
        }
        NotificationCenter.default.post(name: .tmuxPaneBindingsChanged, object: nil)
        paneViews[paneId] = view
        return true
    }

    /// Returns false when the layout could not be applied (missing tab or a
    /// pane view the tree references doesn't exist). The tab keeps its stale
    /// splitTree, so the caller must NOT record the batch as applied — tmux
    /// re-emits the same topology and the retry is what heals the desync.
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
        // The layout root carries the window's CURRENT content size in cells.
        // Refresh the reported size here too: `%layout-change` (which reassigns
        // `splitTree` and drives the relayout) is exactly when a foreign client
        // shrinks/grows the window, and a bare `.ensureWindow` doesn't relayout.
        let rootSize = Self.layoutSize(layout)
        storeReportedWindowCells(windowId: windowId, cols: rootSize.cols, rows: rootSize.rows)
        // Split created/closed: the window's size driver hands over between the
        // container path and the sole pane's updatePTYSize, across transient
        // teardown frames. Re-arm the size dedup so the post-layout re-sync
        // below pushes a fresh authoritative size even if it equals a stale
        // latched value (self-heal if a transient ever slipped through).
        // ROOTSHELL-TMUX (id=tmux-size-floor)
        let paneCount = Self.paneCount(layout)
        if let previous = lastLayoutPaneCount[windowId], previous != paneCount {
            lastPushedWindowSize.removeValue(forKey: windowId)
            if isActiveWindow(windowId: windowId) { lastPushedGlobalSize = nil }
            TmuxDebugLogger.shared.event("LAYOUT", "pane count \(previous)->\(paneCount) win=\(windowId), size dedup re-armed")
        }
        lastLayoutPaneCount[windowId] = paneCount
        // Set focus before assigning the tree so the pane view's
        // didMoveToWindow focus sync makes it first responder (so keystrokes
        // reach the pane surface -> tmux backend -> send-keys).
        if tab.focusedPane == nil, let first = firstPaneView(layout) {
            focusPane(first, in: tab)
        }
        // When tmux reports the window zoomed, present that pane fullscreen via
        // SplitTree.zoomed. The zoomed node is matched to the root leaf by view
        // identity, so it must reuse the same paneViews instance. nil means not
        // zoomed (0 is a real pane id). ROOTSHELL-TMUX (id=tmux-zoom)
        let zoomedNode: SplitTree<SplitPaneView>.Node?
        if let zoomedPaneId, let view = paneViews[zoomedPaneId] {
            zoomedNode = .leaf(view: view)
        } else {
            zoomedNode = nil
        }
        tab.splitTree = SplitTree(root: root, zoomed: zoomedNode)
        fulfillPendingSplitFocus(windowId: windowId, layout: layout, tab: tab)

        // If this tab was displayed while still empty (placeholder revealed
        // before its panes existed), re-run the reveal gating now that it has
        // content: the fresh pane surfaces must present a first frame before
        // showing at full opacity. No-op for non-displayed windows and for
        // layout changes on tabs that already have presented panes.
        tabsModel.syncDisplayedTab()

        // tmux just resized these pane terminals to match the new layout. When
        // the resulting native frame change is tiny (a divider drag, where the
        // local tree already matched tmux's ratio), each pane's `sizeDidChange`
        // gate skips `set_size`, so the renderer keeps drawing the pre-resize
        // frame even though the terminal reflowed — the content "doesn't resize."
        // Force each pane in this window to re-sync its surface size AFTER the
        // upcoming layout pass (async, so bounds are the new frame), bypassing
        // the no-op gate via invalidateCachedSize so a render is emitted. Harmless
        // for window resize (which already re-renders via a real frame change).
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

    /// All pane views referenced by a layout subtree (in order).
    private func panes(in node: TmuxLayoutNode) -> [Ghostty.TerminalView] {
        switch node {
        case let .pane(paneId, _, _, _, _):
            return paneViews[paneId].map { [$0] } ?? []
        case let .split(_, children, _, _, _, _):
            return children.flatMap { panes(in: $0) }
        }
    }

    /// Make `view` the focused pane: mark it logically focused (clearing the
    /// other panes), request first-responder, and set the tab's focused
    /// terminal. This routes keyboard input to this pane's surface, whose
    /// tmux backend emits `send-keys` for this pane id.
    private func focusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        let previous = tab.focusedTerminal
        for other in paneViews.values where other !== view {
            other.isLogicallyFocused = false
            // Also disarm any stale one-shot focus hint. Bare
            // becomeFirstResponder() callers (tab close auto-move, selectTab)
            // arm it without consuming it, and a stale true is poison here:
            // the split's hosting-view rebuild reparents EVERY pane, so the
            // old pane's didMoveToWindow re-runs syncFocus, the stale flag
            // makes it grab first responder, focusGained echoes
            // `select-pane` for the OLD pane to tmux, and tmux then re-asserts
            // the old pane via %window-pane-changed — durably stealing the
            // split's focus back. ROOTSHELL-TMUX (id=tmux-focus-stale-flag)
            other.shouldBecomeFirstResponderWhenReady = false
            // And clear any stray "focused" cursor a half-completed focus
            // attempt left behind, so only the target pane renders an active
            // cursor. ROOTSHELL-TMUX (id=tmux-focus-cursor-sweep)
            other.clearStaleGhosttyFocus()
        }
        view.isLogicallyFocused = true
        view.shouldBecomeFirstResponderWhenReady = true
        tab.focusedTerminal = view

        // Active focus drive — mirrors MainView.setFocusedTerminal. Gated on
        // the tab being the visible one: setLayout also routes here for
        // background windows, and EVERY tab's panes are in the UIWindow (the
        // tab ForEach renders them all at opacity 0), so an ungated
        // becomeFirstResponder would steal the user's keyboard.
        // ROOTSHELL-TMUX (id=tmux-focus-active)
        let hostModel = modelContainingTab(id: tab.id) ?? tabsModel
        guard hostModel.selectedTabID == tab.id else { return }

        var acquired = false
        if view.window != nil {
            // Existing pane (e.g. %window-pane-changed between attached
            // panes): nothing re-attaches it, so didMoveToWindow never
            // re-fires — drive first responder NOW.
            acquired = view.focusDidChange(true)
            if acquired { view.shouldBecomeFirstResponderWhenReady = false }
        }
        // else: freshly split pane, not attached yet. focusDidChange(true)
        // would no-op (no window, and tmux panes never get
        // windowActiveOverride); didMoveToWindow + the watchdog cover it.

        if let previous, previous !== view {
            if previous.surface != nil {
                previous.focusDidChange(false, skipResign: acquired)
            } else if previous.isFirstResponder {
                previous.resignFirstResponder()
            }
        }
        armFocusWatchdog(for: view, tab: tab)
    }

    /// Bounded retry loop that converges UIKit first responder onto the pane
    /// `focusPane` just marked. Needed because a tmux split rebuilds the whole
    /// SplitTreeHostingView (structuralIdentity .id change): the new pane's
    /// becomeFirstResponder can transiently fail during the reparenting churn
    /// and the per-view one-shot retries (syncFocusForWindowStateChange +0.05s,
    /// didMoveToWindow +0.25s) can all miss, leaving keystrokes in the old
    /// pane. Superseded by the next focusPane; every tick re-validates so a
    /// user tap on another pane (isLogicallyFocused -> false) or a tab switch
    /// aborts it. ROOTSHELL-TMUX (id=tmux-focus-watchdog)
    private func armFocusWatchdog(for view: Ghostty.TerminalView, tab: TabModel) {
        focusWatchdog?.cancel()
        let paneId = view.tmuxPaneBinding?.paneId ?? -1
        let tabID = tab.id
        focusWatchdog = Task { @MainActor [weak self, weak view] in
            // Checks at ~0.1s / 0.35s / 0.8s after focusPane.
            for (attempt, delay) in [100, 250, 450].enumerated() {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let view else { return }
                if view.isFirstResponder {
                    if attempt > 0 {
                        TmuxDebugLogger.shared.event("FOCUS", "watchdog converged pane=\(paneId) attempt=\(attempt)")
                    }
                    return
                }
                // weakTabsModel, not the force-unwrapping accessor: this task
                // outlives synchronous controller calls, so the ownership
                // invariant that makes `tabsModel` safe doesn't hold here.
                guard let model = self.weakTabsModel else { return }
                // The pane must still be live in this controller: a prune can
                // remove + cleanup() the view between ticks while it briefly
                // remains in the UIKit hierarchy, and re-asserting first
                // responder on a cleaned-up surface would revive a dead pane.
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

    /// Record tmux's remote pane focus for a tab that is not becoming visible.
    /// This keeps title/health observation and later manual tab selection
    /// correct without letting a hidden pane steal first responder.
    private func recordRemoteFocusPane(_ view: Ghostty.TerminalView, in tab: TabModel) {
        view.isLogicallyFocused = false
        view.shouldBecomeFirstResponderWhenReady = false
        tab.focusedTerminal = view
    }

    /// Pane geometry used to convert tmux layout cells into the on-screen
    /// points a subtree needs, so split ratios account for per-pane padding
    /// insets and native dividers. nil when no pane in the layout has a ready
    /// surface yet (fall back to plain cell-count ratios).
    /// ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
    private struct PaneMetrics {
        let cellW: CGFloat
        let cellH: CGFloat
        let padX: CGFloat
        let padY: CGFloat
        let divider: CGFloat
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
            divider: SplitTreeHostingView.dividerVisibleThickness)
    }

    /// The on-screen extent (points) subtree `node` needs along one axis:
    /// its grid cells plus every pane's padding inset plus native dividers.
    /// ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
    private func neededPoints(_ node: TmuxLayoutNode, horizontal: Bool, metrics: PaneMetrics) -> CGFloat {
        let cell = horizontal ? metrics.cellW : metrics.cellH
        let pad = horizontal ? metrics.padX : metrics.padY
        switch node {
        case let .pane(_, width, height, _, _):
            return CGFloat(horizontal ? width : height) * cell + pad * 2
        case let .split(direction, children, _, _, _, _):
            let along = children.map { neededPoints($0, horizontal: horizontal, metrics: metrics) }
            if (direction == .horizontal) == horizontal {
                return along.reduce(0, +) + CGFloat(max(children.count - 1, 0)) * metrics.divider
            }
            return along.max() ?? pad * 2
        }
    }

    /// Convert a tmux layout node into a binary SplitTree node. tmux splits are
    /// N-ary; we right-fold them into binary splits. tmux container sizes
    /// include the 1-cell divider between children, so the remaining subtree's
    /// container is containerSize - firstSize - 1.
    ///
    /// The ratio is the first child's share of the children's NEEDED POINTS
    /// (cells + padding insets + dividers), not of the raw cell counts: the
    /// frame math distributes pixels proportionally, and a plain cell ratio
    /// hands the 1-cell tmux separator's pixels to the second child while the
    /// first doesn't even get its own padding, clipping the bottom of its last
    /// row. ROOTSHELL-TMUX (id=tmux-split-chrome-ratio)
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

    /// UserDefaults key for the opt-in "auto-hide the gateway tab on attach"
    /// preference (Settings → Connections → Multiplexers). Shared with
    /// `MultiplexerSettingsView`; both now go through
    /// `Settings.Multiplexer.tmuxAutoHideGatewayOnAttach`. Default off.
    static let autoHideGatewayOnAttachDefaultsKey = "tmuxAutoHideGatewayOnAttach"

    /// One-shot guard for auto-hide-on-attach: fires once per attachment (a
    /// fresh controller is created on each attach/resume), so a later manual
    /// "Show Gateway Tab" is not retroactively re-hidden by the next reconcile.
    private var didAutoHideGatewayOnAttach = false

    /// Mark the `tmux -CC` gateway's own tab (the tab control mode was launched
    /// from) so it can be identified later — e.g. to reselect it on %exit. The
    /// tab stays VISIBLE and navigable: control mode does not hide it. The new
    /// per-window tabs appear alongside it and the reconcile's focus op moves
    /// selection to the active tmux window. Idempotent.
    func markGatewayTab(ownerView: Ghostty.TerminalView) {
        // See id=tmux-apply-tabsmodel-guard: tolerate a released TabsModel.
        guard weakTabsModel != nil else { return }
        guard let gatewayTab = tabsModel.tabs.first(where: { tab in
            tab.splitTree.contains { $0 === ownerView }
        }) else { return }
        // This method is intentionally safe to call more than once, but an
        // unconditional write still notifies Observation even when the value
        // remains true. Keep repeated topology/focus applies from needlessly
        // invalidating every tab consumer.
        if !gatewayTab.isTmuxGateway {
            gatewayTab.isTmuxGateway = true
        }
        gatewayTabID = gatewayTab.id
        // The attached-session identity can land before the gateway tab is
        // marked (SESSION_CHANGED is stashed on the view and flushed at
        // controller creation), so seed the mirror here too. Equality-guarded:
        // this runs on every reconcile and the tab is observable.
        // (id=tmux-session-info-stash)
        if let currentSessionName, gatewayTab.tmuxSessionName != currentSessionName {
            gatewayTab.tmuxSessionName = currentSessionName
        }
        // Deferred restore-apply for a gateway saved HIDDEN: runs after every
        // reconcile apply, so at the first topology batch post-resume the
        // window tabs exist (with their mirror-seeded hidden flags) and
        // hideGatewayTab's ≥1-visible-window gate evaluates real data. A
        // focus/title-only first batch leaves the flag pending. Consumed even
        // when the hide is then skipped (all windows hidden): a later manual
        // unhide must not retroactively hide the gateway.
        // (id=tmux-hidden-gateway)
        if gatewayTab.pendingHiddenTmuxGatewayRestore, !windowTabs.isEmpty {
            gatewayTab.pendingHiddenTmuxGatewayRestore = false
            // The restore already performed the "hide gateway on attach"
            // behavior, so consume the auto-hide one-shot too — otherwise a
            // later manual "Show Gateway Tab" would be re-hidden on the next
            // reconcile when the setting is enabled. (id=tmux-hidden-gateway)
            didAutoHideGatewayOnAttach = true
            hideGatewayTab()
        } else if !didAutoHideGatewayOnAttach,
                  SettingsStore.shared.get(Settings.Multiplexer.tmuxAutoHideGatewayOnAttach),
                  !windowTabs.isEmpty {
            // Opt-in (Settings → Multiplexers): hide the gateway once its
            // windows have arrived. One-shot so a later manual "Show Gateway
            // Tab" is not undone by the next reconcile. Consumed even when the
            // hide is then skipped (all windows hidden), mirroring the
            // pending-restore branch above. (id=tmux-hidden-gateway)
            didAutoHideGatewayOnAttach = true
            hideGatewayTab()
        }
    }

    /// THIS controller's gateway tab, resolved by owner (the tab whose split tree
    /// holds the view that owns this controller) rather than the `isTmuxGateway`
    /// flag. A fallback for the control-mode-end re-select when `gatewayTabID` is
    /// somehow stale. The gateway view still holds `tmuxController === self` here:
    /// `applyTmuxReconcile` only nils it AFTER `apply` (and thus `prune`) returns.
    private func ownGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return model?.tabs.first { tab in
            tab.splitTree.contains { $0.asTerminal?.tmuxController === self }
        }
    }

    /// THIS controller's gateway tab: by cached id, then by ownership, then by
    /// the global flag as a last resort (arbitrary with >1 gateway, same
    /// trade-off as `repairSelectionIfNeeded`).
    func resolvedGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return gatewayTabID.flatMap { id in model?.tabs.first { $0.id == id } }
            ?? ownGatewayTab()
            ?? model?.tabs.first(where: { $0.isTmuxGateway })
    }

    /// THIS controller's gateway tab, WITHOUT the global-flag last resort: by
    /// cached id or by ownership only. For writes that must never land on
    /// another gateway's tab (the session-name mirror), where "not yet
    /// resolvable" is fine because `markGatewayTab` seeds it.
    func ownedGatewayTab() -> TabModel? {
        let model = TerminalWindowRegistry.tabsModel(for: baseWindowId)
            ?? TmuxWindowRegistry.tabsModel(for: baseWindowId)
            ?? weakTabsModel
        return gatewayTabID.flatMap { id in model?.tabs.first { $0.id == id } }
            ?? ownGatewayTab()
    }

    /// Select this controller's gateway tab and restore terminal focus using the
    /// same path as control-mode teardown. Returns false if the gateway tab no
    /// longer exists. Selecting a hidden gateway implies showing it, mirroring
    /// `selectWindowTab` — this is also the recovery path when hiding the last
    /// visible tab of the group (`moveSelectionOffTab` falls back here).
    /// (id=tmux-hidden-gateway)
    func selectGatewayTab() -> Bool {
        guard let gatewayTab = resolvedGatewayTab() else { return false }
        if gatewayTab.isHiddenTmuxWindow {
            gatewayTab.isHiddenTmuxWindow = false
            postHiddenWindowsDidChange()
        }
        selectTab(gatewayTab.id)
        return true
    }

    /// Select one of this controller's projected tmux window tabs using the
    /// same local path as a normal app tab tap.
    @discardableResult
    func selectWindowTab(windowId: Int) -> Bool {
        guard let tab = windowTabs[windowId] else {
            return false
        }
        // Selecting a hidden window implies showing it (dashboard window tap,
        // session-switch window selection). showWindow without re-select; the
        // selectTab below does the focus handoff. (id=tmux-hidden-windows)
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
        guard let tab = windowTabs[windowId] else { return }
        let hostModel = hostTabsModel(forWindowId: windowId)
        // A session switch THIS device requested (dashboard) replaces every
        // window in one batch; its focus op carries the NEW session's current
        // window. Treat it like initial attach so the user lands there —
        // remote-focus suppression below would otherwise strand them on
        // whichever surviving tab the prune picks. Consumed on first use; the
        // arming side has a 10s expiry. ROOTSHELL-TMUX (id=tmux-session-switch-focus)
        let isSessionSwitchFocus = pendingSessionSwitchWindowSelection == nil
            ? consumePendingSessionSwitch()
            : false
        let isInitialFocus = !hasProcessedInitialFocus || isSessionSwitchFocus
        hasProcessedInitialFocus = true

        // A HIDDEN window never takes selection — not even on initial attach
        // (tmux's "current window" may be one we hide). Record the pane for
        // title/health bookkeeping; if nothing is selected yet the repair
        // fallback lands on the first visible tab. (id=tmux-hidden-windows)
        if tab.isHiddenTmuxWindow {
            if let view = paneViews[paneId] {
                recordRemoteFocusPane(view, in: tab)
            }
            TmuxDebugLogger.shared.event("FOCUS", "ignored focus for hidden win=\(windowId)")
            if hostModel.selectedTabID == nil { hostModel.repairSelectionIfNeeded() }
            return
        }

        let targetIsSelected = hostModel.selectedTabID == tab.id

        // A tmux focus op may move the *selected tab* only when the change
        // originated locally. tmux broadcasts the session's current window to
        // every attached client and re-asserts it on any window add/close or
        // background pane activity, so blindly following it makes the visible
        // tab jump on its own and chase the active window across other devices
        // attached to the same session. We honor a focus op for tab selection
        // only on:
        //   - initial attach (land on the session's current window once), or
        //   - the target tab already being selected (an intra-tab pane focus
        //     change for the window the user is already viewing), or
        //   - a split THIS device just requested (pendingSplitFocus).
        // Every other focus op (a remote client's switch, background activity,
        // a window created elsewhere) is recorded for title/health bookkeeping
        // but does not steal the user's tab.
        let isLocalSplitFocus: Bool = {
            guard let pending = pendingSplitFocus[windowId] else { return false }
            return !pending.existingPaneIds.contains(paneId)
        }()
        let mayChangeSelection = isInitialFocus || targetIsSelected || isLocalSplitFocus

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

    private func prune(windowIds: Set<Int>, paneIds: Set<Int>) {
        // Drop pane views no longer present. Tear each down via `cleanup` (not a
        // bare removeValue) so its surface unregisters from the app's surface
        // registries and is freed — otherwise stale surface pointers linger and a
        // later theme/font/config update iterates them (use-after-free). The
        // viewer-owner is still alive here (mid-session reconcile), so freeing
        // these observer panes is safe; the core reaps each pane terminal once the
        // child surface's renderer detaches. Pane views are freed before the
        // gateway surface, which applyTmuxReconcile only tears down after this
        // returns. tmux panes have no `session`, so cleanup's session-stop is a
        // no-op.
        let hadWindows = !windowTabs.isEmpty
        let priorPaneCount = paneViews.count
        let priorWindowCount = windowTabs.count
        let hostIdsBeforePrune = Set(windowHostIds.values + [baseWindowId])

        // Snapshot display order + selection BEFORE removing anything so that, if
        // the user closed the tmux window tab they were viewing, we can land on
        // its nearest surviving neighbor (the same rule a regular tab close uses)
        // instead of letting repairSelectionIfNeeded() jump to the gateway/first.
        // Live tmux window tab closes bypass MainView.closeTab's local removal
        // path and are finalized here, so grouped mode must use the same
        // grouped sidebar neighbor calculation before the closing tab leaves
        // the model. ROOTSHELL-TMUX (id=grouped-close-neighbor)
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

        // Snapshot the entries to remove BEFORE mutating the dictionaries, so we
        // never remove from a collection we are iterating (a Swift mutation trap).
        let panesToRemove = paneViews.filter { !paneIds.contains($0.key) }
        for (paneId, view) in panesToRemove {
            // Disarm focus state BEFORE cleanup: the view can linger in the
            // UIKit hierarchy briefly after removal, and a window event (or
            // the focus watchdog) re-running syncFocus with these still set
            // would make a dead pane first responder.
            // ROOTSHELL-TMUX (id=tmux-focus-watchdog)
            view.isLogicallyFocused = false
            view.shouldBecomeFirstResponderWhenReady = false
            // Disarm sizing too: an in-flight async set_size/updatePTYSize from
            // this dying view must not push its teardown grid as the WINDOW
            // size. ROOTSHELL-TMUX (id=tmux-pane-retired-no-size)
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
            reportedWindowCellsByWindow.removeValue(forKey: windowId)
            clearForeignConstraint(windowId: windowId)
            // A split-focus entry armed for a removed window must not linger
            // until its 4s expiry: window ids are never reused, but a session
            // switch prunes every window at once and the stale entries would
            // only die by timeout. ROOTSHELL-TMUX (id=tmux-session-switch-focus)
            clearPendingSplitFocus(windowId: windowId)
        }

        // Reconcile the hidden set with the surviving windows. A hidden
        // window killed by ANOTHER client must drop out of the set and the
        // server option — but the %exit/forceQuit/session-switch teardown
        // shape (empty windowIds) clears in-memory ONLY: the server must keep
        // `@hidden` for the next attach, and the new session's set is
        // reloaded by updateCurrentSession. (id=tmux-hidden-windows)
        let prunedHidden = hiddenWindowIds.subtracting(windowIds)
        if !prunedHidden.isEmpty {
            hiddenWindowIds.subtract(prunedHidden)
            if !windowIds.isEmpty && !didEnd && !isDetaching {
                persistHiddenWindowsToServer()
                saveHiddenMirror()
            }
            postHiddenWindowsDidChange()
        }

        // A kill (possibly from another client) may have removed the last
        // VISIBLE window while the gateway tab is hidden; restore the
        // invariant that a hidden gateway always has a visible window tab.
        // No-op in the teardown shape below, which unhides anyway.
        // (id=tmux-hidden-gateway)
        enforceGatewayVisibleWhenGroupHidden()

        // Sweep restored placeholders for THIS gateway whose tmux window no
        // longer exists (closed while the app was gone). ensureWindow runs for
        // every current window before prune (op order), adopting their
        // placeholders, so any still-awaiting placeholder is genuinely orphaned.
        // forceQuit() passes empty windowIds, which removes all of them.
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

        // All tmux windows gone after having had some => control mode ended
        // (tmux exited or the client detached). tmux's stream_handler sends an
        // empty topology snapshot on `%exit`, which lands here. Restore the
        // hidden gateway tab so the user returns to the (now plain) shell, and
        // flag teardown for applyTmuxReconcile to complete safely.
        TmuxDebugLogger.shared.event("PRUNE", "removedPanes=\(priorPaneCount - paneViews.count) removedWindows=\(priorWindowCount - windowTabs.count) windowsRemaining=\(windowTabs.count)")
        if hadWindows && windowTabs.isEmpty && !didEnd {
            didEnd = true
            releaseContentEventInterest()
            paneIdentityRefreshTask?.cancel()
            paneIdentityRefreshTask = nil
            stopHeartbeat()
            stopRecoveryWatchdog()
            // Pending dashboard queries will never be answered (the core also
            // errors them back on teardown; this covers Swift-side ordering).
            failAllPendingReplies(.gatewayEnded)
            // Stop chasing first responder for panes that no longer exist.
            // ROOTSHELL-TMUX (id=tmux-focus-watchdog)
            focusWatchdog?.cancel()
            focusWatchdog = nil
            TmuxDebugLogger.shared.marker("CONTROL MODE END (prune emptied all windows)")
            // Re-select THIS controller's own gateway tab (resolved by owner, not
            // by a global first(isTmuxGateway): correct with >1 gateway and immune
            // to a stale/cleared flag) with the same focus+occlusion handoff a tab
            // close uses, so the user lands on the gateway shell WITH the keyboard
            // — regardless of whether the gateway tab or a tmux window tab was the
            // selected one when ESC fired (the ESC handlers detach via the gateway
            // VIEW even while a window tab is showing). Without this, a window tab
            // being the selected one leaves selectedTabID dangling after the prune
            // and repairSelectionIfNeeded falls through to tabs.first — an
            // unrelated tab. ROOTSHELL-TMUX (id=tmux-detach-reselect-own-gateway)
            if let gatewayTab = resolvedGatewayTab() {
                gatewayTab.isTmuxGateway = false
                gatewayTab.tmuxSessionName = nil
                // Control mode is over: the tab reverts to a plain shell tab
                // and MUST be visible — a hidden gateway state never outlives
                // the attachment. (id=tmux-hidden-gateway)
                if gatewayTab.isHiddenTmuxWindow {
                    gatewayTab.isHiddenTmuxWindow = false
                    postHiddenWindowsDidChange()
                }
                gatewayTab.pendingHiddenTmuxGatewayRestore = false
                if closeGatewayTabAfterDetach {
                    closeGatewayTabAfterDetach = false
                    // "Detach Session & Close Gateway" tab-close action: the
                    // gateway has reverted to a plain shell tab; close it via the
                    // same async-session-end routing a dying tab uses (the
                    // .closeSplit observer resolves the window by the posted view
                    // and runs the normal cleanup/selection). Dispatched async so
                    // it lands after this reconcile finishes mutating the tab
                    // array. (id=tmux-tab-close-action)
                    if let gatewayView = gatewayTab.splitTree.first(where: { $0.asTerminal?.tmuxController === self })
                        ?? gatewayTab.splitTree.first {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .closeSplit, object: gatewayView)
                        }
                    }
                } else {
                    selectTab(gatewayTab.id)
                    // Grouped mode: the gateway's `.tmux(ownerID:)` group just
                    // dissolved (windows pruned, gateway reverted to a plain shell).
                    // Re-point activeGroupID to the gateway tab's new group so the
                    // tab bar stays scoped instead of falling back to every group —
                    // the automatic equivalent of the user toggling grouped mode
                    // off/on. (id=tmux-detach-regroup)
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
                // The selected window tab was pruned while control mode is still
                // active. Land on its nearest surviving neighbor within the same
                // app window and run the window's selection/focus repair hook;
                // moved tmux window tabs no longer necessarily live in the
                // controller's base tabsModel.
                model.selectedTabID = neighborID
                model.pendingScrollToTabID = neighborID
                TerminalWindowRegistry.refreshSelectionAfterMutation(in: hostId, allowFocus: true)
            }
        }

        // Final safety net: if a removed tab (a window tab or an orphaned
        // placeholder) was the selected one and nothing above re-selected, repair
        // the selection so the tab bar isn't left pointing at a deleted tab.
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

    /// Nearest still-present tab to a removed one, scanning the pre-removal
    /// display order rightward first (the tab that slides into the slot) then
    /// leftward (when the removed tab was last) — the same neighbor rule
    /// MainView.closeTab uses.
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

    /// Select `tabID` and restore keyboard focus to its terminal. Mirrors the
    /// focus handoff in MainView.closeTab: onChange(of: selectedTabIndex) does
    /// NOT fire when the target slides into the same index slot, so occlusion +
    /// first responder must be set explicitly here. Shared by the mid-session
    /// neighbor close, the control-mode-end gateway re-select, and the
    /// hidden-windows extension (internal, not private, for that last one).
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
            // Landing on a tmux pane (neighbor tab after a window-tab close):
            // sync tmux's active window/pane explicitly — the core no longer
            // echoes select-pane on focus gain. No-op for the gateway re-select
            // (the gateway terminal has no pane binding).
            // ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
            if let terminal = target.asTerminal, terminal.isTmuxPane {
                terminal.requestTmuxSelectPane()
            }
            ghosttyApp?.appTick()
        }
    }

    /// Land on the nearest surviving tab after a mid-session window-tab close.
    private func selectNeighborTab(_ tabID: UUID) { selectTab(tabID) }

    /// Locally tear down every tmux window tab and pane view this controller
    /// created and restore the gateway tab, without waiting on tmux. Used when
    /// the gateway tab is closed directly: no `%exit` arrives to drive the normal
    /// prune, so the projected window tabs would otherwise be left frozen.
    /// Reuses the prune-everything path (empty target sets remove all).
    func forceQuit() {
        // No detach write here: this path only runs when the gateway TAB is
        // being closed, and the tab teardown closes the SSH/tssh connection
        // itself — tmux detaches the control client server-side on EOF. A raw
        // `detach-client` on a HEALTHY close would interleave with the
        // viewer's queued control commands (see sendTmuxDetach's warning) and
        // can leave the `tmux -CC` client lingering instead.
        TmuxDebugLogger.shared.event("END", "forceQuit (gateway tab closed)")
        prune(windowIds: [], paneIds: [])
    }

    /// The gateway view bound to THIS controller, resolved through its tab's
    /// split tree (same ownership rule as `ownGatewayTab`).
    private func ownGatewayView() -> Ghostty.TerminalView? {
        guard weakTabsModel != nil else { return nil }
        return ownGatewayTab()?.splitTree.terminalLeaves.first { $0.tmuxController === self }
    }

    /// Whether the gateway's transport ITSELF claims to be connected right
    /// now. Discriminates the two silent-link shapes for the blackout
    /// escalation: a known network loss (the recoverable wait the watchdog
    /// must keep holding for) versus a transport that reports healthy contact
    /// yet delivers nothing (the unrecoverable stall). NOT the session
    /// lifecycle `state` — tssh intentionally keeps that `.running` across
    /// drops because the Go transport reconnects internally; TrzszSession
    /// exposes `transportBelievesHealthy` reading its real health monitor
    /// (live Go timeout flag / loss timestamp / roam banner) instead. mosh
    /// needs no branch here: it cannot carry a tmux -CC gateway. Unknown /
    /// unresolvable session: false (conservative — never escalate blind).
    /// ROOTSHELL-TMUX (id=tmux-blackout-escalation)
    /// The tssh session backing a gateway, whether it IS one or merely hosts one.
    /// Shell-launched tssh (`tssh` typed at a local prompt) runs EMBEDDED in a
    /// LocalShellSession, so a bare `as? TrzszSession` silently misses it — and
    /// anything wired only through that cast (discard→reset, keep-pending-input)
    /// never reaches those gateways at all. (LocalShellSession is compiled out on
    /// Catalyst.) ROOTSHELL-TMUX (id=tmux-gateway-trzsz-resolve)
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

    private func gatewayTransportClaimsConnected() -> Bool {
        guard let session = ownGatewayView()?.session else { return false }
        // The outer session's `isRunning` is the local shell's lifecycle, not the
        // tssh link, so an embedded gateway must consult the real transport.
        if let trzsz = Self.gatewayTrzszSession(for: session) {
            return trzsz.transportBelievesHealthy
        }
        // Non-roaming transports (plain SSH etc.) have no redelivery to wait
        // for; their liveness flag is the best signal available.
        return session.isRunning
    }

    /// Best-effort `detach-client` written DIRECTLY to the gateway session's
    /// transport. ONLY for the wedged force-exit path: the viewer command
    /// queue is stuck there (so the FIFO-safe `ghostty_surface_tmux_detach`
    /// could never flush) and the pipeline is already desynced, so the usual
    /// raw-write interleaving hazard is moot. If the link is alive (or later
    /// recovers half-stalled) this detaches the remote `tmux -CC` client;
    /// without it the remote stays attached after a local force-exit and
    /// keeps streaming control-mode output, which renders as raw
    /// `%output ...` text in the post-exit shell. Harmless no-op on a dead
    /// transport. Do NOT use on healthy paths — those must route through
    /// `sendTmuxDetach()`. ROOTSHELL-TMUX (id=tmux-best-effort-detach)
    private func sendBestEffortDetach() {
        guard let session = ownGatewayView()?.session else { return }
        TmuxDebugLogger.shared.event("END", "best-effort detach-client gw=\(uuidPrefix)")
        session.sendInput(Data("detach-client\n".utf8))
    }

    // MARK: - Per-window font size

    /// The ABSOLUTE font size (points) a tmux window has been overridden to,
    /// keyed by tmux window id. Absent = the window follows the global font.
    ///
    /// In control mode a window is one uniform cell grid, so every pane of a
    /// window must share one font size; a change applies to all panes of ONE
    /// window and panes created later must match. We track the absolute size
    /// (not a delta from the base) on purpose: the core PRESERVES a manually
    /// adjusted font size across config reloads (Surface.zig updateConfig), so
    /// after a global Settings/family/theme change the existing panes keep this
    /// absolute size while the base moves. Reconciling a new pane against the
    /// *current* base (`absolute - currentBase`) therefore lands it exactly on
    /// its siblings; a stored delta would drift by the base change.
    private var windowFontSize: [Int: Double] = [:]

    /// Apply a relative font-size change to every pane of one tmux window.
    /// `delta > 0` increases, `< 0` decreases. The resulting cell-size change
    /// triggers each pane's `handleCellSizeChange`, which re-pushes that
    /// window's per-window tmux size — other windows are untouched.
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

    /// Reset every pane of one tmux window to the current global font size.
    /// Uses a relative step (current global − the window's override) rather than
    /// the core `reset_font_size` action, because that resets each pane to its
    /// own creation-time size, which can differ per pane and would desync the
    /// window. A window already following the global font is a no-op.
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

    /// The absolute font-size override for a window, if any. A pane created after
    /// the window was zoomed applies `override − currentBase` to land on its
    /// siblings (see `windowFontSize`).
    func overrideFontSize(forWindowId windowId: Int) -> Double? {
        windowFontSize[windowId]
    }

    /// Request a graceful detach and immediately block any later Swift-side tmux
    /// command emission during the teardown window.
    func requestGracefulDetach(source: String) {
        // ownerSurfaceFreed: the gateway surface is gone, so the queued
        // ghostty_surface_tmux_detach below would be a use-after-free.
        // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        isDetaching = true
        ownGatewayView()?.tmuxDetachInProgressAtomic = true
        for view in paneViews.values {
            view.tmuxDetachInProgressAtomic = true
        }
        let uuidPrefix = ownerTerminalUUID.uuidString.prefix(8)
        TmuxDebugLogger.shared.event("DETACH", "requested \(source) gw=\(uuidPrefix)")
        // Re-validate at EXECUTION time, not enqueue time. The entry guard above
        // only proves the surface was live when the detach was requested; the
        // detach is dispatched across two async hops (ghosttyAPIQueue → main) and
        // gatewaySurfaceWillBeFreed() can run in that gap, after which ownerSurface
        // is dangling. Re-check ownerSurfaceFreed on the main actor immediately
        // before the ABI call (cleanup sets the flag on main, ordered ahead of any
        // later main block). ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        Ghostty.TerminalView.ghosttyAPIQueue.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ownerSurfaceFreed else { return }
                    ghostty_surface_tmux_detach(self.ownerSurface)
                }
            }
        }
    }

    /// True when `windowId`'s tab is the currently selected tab. Only the visible
    /// window measures and drives the GLOBAL client size, so a background tab that
    /// re-lays out mid-transition (different transient bounds) can't latch a wrong
    /// global into the dedup cache. The multi-pane container path is already
    /// `isActiveTab`-gated; this gives the single-pane path (`updatePTYSize`, which
    /// is not) the same gate.
    func isActiveWindow(windowId: Int) -> Bool {
        guard let tab = windowTabs[windowId] else { return false }
        return hostTabsModel(forWindowId: windowId).selectedTabID == tab.id
    }

    // MARK: - Per-window size push

    /// Last per-window size pushed to tmux, keyed by window id, to coalesce the
    /// two push paths (the split container for multi-pane windows; the sole
    /// pane's `updatePTYSize` for single-pane windows) and avoid a no-op command
    /// storm on every layout pass.
    private var lastPushedWindowSize: [Int: (cols: UInt16, rows: UInt16)] = [:]

    /// Pane count of the last layout applied per window, to detect split
    /// create/close transitions in `setLayout`. On a transition the size driver
    /// hands over (container <-> sole pane) across transient teardown frames, so
    /// the per-window dedup is re-armed to force a fresh authoritative push —
    /// self-healing the server size even if a transient slipped through.
    /// ROOTSHELL-TMUX (id=tmux-size-floor)
    private var lastLayoutPaneCount: [Int: Int] = [:]

    /// tmux's last-REPORTED window size in cells (from `.ensureWindow` and the
    /// `setLayout` root), as opposed to the size we requested. When a smaller
    /// foreign client attaches, tmux resolves the shared window below the size we
    /// asked for and reports it here; the split container annotates the resulting
    /// dead margin. Cleared on prune.
    private var reportedWindowCellsByWindow: [Int: (cols: UInt16, rows: UInt16)] = [:]

    /// Record tmux's reported window size, clamping the cell counts to UInt16.
    /// A reported-size change can arrive in an ensure-window-only reconcile that
    /// does NOT reassign the split tree (so nothing else relayouts); when that
    /// change affects the dead-margin state, nudge a layout pass so the overlay
    /// tracks it. Complements the `pushWindowSize` nudge (which covers the first
    /// push establishing the baseline). Value-deduped and gated to constraint-
    /// relevant changes, so a normal resize — already relaid out by `setLayout`
    /// reassigning `splitTree` — does not double-fire. ROOTSHELL-TMUX
    /// (id=tmux-foreign-constraint-nudge)
    private func storeReportedWindowCells(windowId: Int, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let c = UInt16(min(max(cols, 0), Int(UInt16.max)))
        let r = UInt16(min(max(rows, 0), Int(UInt16.max)))
        let old = reportedWindowCellsByWindow[windowId]
        guard old?.cols != c || old?.rows != r else { return }
        reportedWindowCellsByWindow[windowId] = (cols: c, rows: r)
        reevaluateForeignConstraint(windowId: windowId)
        // A reported-size change while the overlay is showing moves the
        // contentRect, so relayout even without a latch transition (the
        // transitions themselves nudge inside `reevaluateForeignConstraint`).
        if foreignConstrainedWindows.contains(windowId) {
            Self.nudgeLayoutInvalidation()
        }
        // Trigger A (event-driven reclaim): a window whose reported size GREW means
        // more room opened up — a smaller foreign client detached or grew. tmux
        // grows the session's focused window back and emits a `%layout-change` for
        // it, but leaves our other (background) windows at the constrained size. So
        // re-assert every still-constrained window, mirroring iTerm2's
        // `fitLayoutToVariableSizeWindows`. A shrink (foreign client attaching) does
        // NOT sweep — we don't fight an active foreign client; the sweep's
        // raw-constrained gate also makes it a no-op while the constraint holds.
        // ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        let grew: Bool = {
            guard let old else { return false }
            return c > old.cols || r > old.rows
        }()
        if grew {
            if reclaimInFlightWindows.contains(windowId) {
                // This window's own forced reclaim landed; drop the suppression and
                // let the overlay/latch state (already cleared raw-false above)
                // settle via a layout pass.
                clearReclaimInFlight(windowId: windowId)
                Self.nudgeLayoutInvalidation()
            }
            scheduleReclaimAllWindowSizes()
        }
    }

    /// tmux's last-reported size for a window in cells, or nil if unknown. The
    /// split container reads this to size the dead-margin overlay (see
    /// `SplitTreeHostingView.tmuxDeadMargin`).
    func reportedWindowCells(windowId: Int) -> (cols: UInt16, rows: UInt16)? {
        reportedWindowCellsByWindow[windowId]
    }

    /// True when tmux currently reports `windowId` SMALLER than the size we last
    /// requested for it — i.e. a smaller foreign client constrained the shared
    /// window below our capacity, leaving a dead margin. Comparing against the
    /// size WE pushed (not a bounds-derived capacity) keeps the test in tmux cell
    /// units, immune to the window-padding inset that separates a surface's grid
    /// from its pixel capacity. `tol` cells of slack absorb rounding and the
    /// 1-cell inter-pane divider.
    ///
    /// This is the RAW comparison and it is transiently true after every push
    /// that grows the requested size (e.g. each font-shrink step): the reported
    /// size is stale for one command round-trip until tmux answers with a
    /// `%layout-change`. UI must consume the debounced `isWindowForeignConstrained`
    /// instead, or the dead-margin overlay flickers on every Cmd+- with a single
    /// client attached. ROOTSHELL-TMUX (id=tmux-foreign-constraint-latch)
    private func rawWindowForeignConstrained(windowId: Int, tol: UInt16 = 2) -> Bool {
        guard let reported = reportedWindowCellsByWindow[windowId],
              let requested = lastPushedWindowSize[windowId] else { return false }
        // Promote to Int before adding the tolerance: reported sizes are clamped
        // to UInt16, so `reported.cols + tol` could overflow and trap near the max.
        let t = Int(tol)
        return Int(reported.cols) + t < Int(requested.cols) ||
               Int(reported.rows) + t < Int(requested.rows)
    }

    /// Debounced foreign-constraint state for UI (dead-margin overlay + layout
    /// constraint). Latches ON only after the raw comparison has held for
    /// `foreignConstraintGrace` — long enough for tmux's `%layout-change` reply
    /// to a size push to land, so a single-client font change never flashes the
    /// overlay — and clears IMMEDIATELY when the raw state goes false, so
    /// reclaim on foreign-client detach is as fast as before. In the genuine
    /// attach/resume case tmux stays silent after our push (its size is already
    /// the constrained one), the raw state holds, and the overlay appears after
    /// the grace delay. ROOTSHELL-TMUX (id=tmux-foreign-constraint-latch)
    func isWindowForeignConstrained(windowId: Int) -> Bool {
        // While a reclaim re-push is in flight for this window (we asked tmux to
        // grow it back and are awaiting the %layout-change), suppress the
        // dead-margin overlay / layout constraint so it doesn't flash during the
        // round-trip. `markReclaimInFlight`'s timeout restores it if the window
        // legitimately stays constrained (foreign client still attached).
        // ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        foreignConstrainedWindows.contains(windowId)
            && !reclaimInFlightWindows.contains(windowId)
    }

    /// Windows whose foreign constraint has survived the grace period.
    private var foreignConstrainedWindows: Set<Int> = []
    /// Pending grace timers, one per window with a raw-true state not yet latched.
    private var foreignConstraintTimers: [Int: Task<Void, Never>] = [:]
    /// Long enough for a `refresh-client -C` -> `%layout-change` round-trip on a
    /// slow link; short enough that a genuinely constrained window annotates
    /// promptly after attach.
    private static let foreignConstraintGrace: Duration = .milliseconds(800)

    /// Re-derive the latched constraint state after either input changed (a size
    /// push or a reported size). Transitions nudge a layout pass; steady states
    /// are free. (id=tmux-foreign-constraint-latch)
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

    /// Drop all constraint state for a window (prune/teardown).
    private func clearForeignConstraint(windowId: Int) {
        foreignConstraintTimers.removeValue(forKey: windowId)?.cancel()
        foreignConstrainedWindows.remove(windowId)
        clearReclaimInFlight(windowId: windowId)
    }

    // MARK: - Reclaim sweep (auto-grow back after a foreign client detaches)

    /// True while a reclaim sweep is executing, so the re-entrant `pushWindowSize`
    /// calls it makes don't schedule another sweep (Trigger B) or recurse.
    private var sweeping = false
    /// Coalesce a burst of `%layout-change`-driven reclaim requests into one
    /// sweep per runloop tick.
    private var reclaimSweepScheduled = false
    /// Windows whose full-size re-push we just sent and are awaiting tmux to grow.
    /// Suppresses the dead-margin overlay for the round-trip (see
    /// `isWindowForeignConstrained`). Cleared when the window grows (Trigger A) or
    /// on a short timeout if it stays constrained.
    private var reclaimInFlightWindows: Set<Int> = []
    /// Per-window restore timers for `reclaimInFlightWindows`.
    private var reclaimInFlightTimers: [Int: Task<Void, Never>] = [:]
    /// Long enough for a forced `refresh-client -C` -> `%layout-change` round-trip;
    /// short enough that a window that legitimately stays constrained (foreign
    /// client still attached) re-frosts promptly.
    private static let reclaimInFlightGrace: Duration = .milliseconds(1200)

    /// Re-send the full per-window size for every window tmux is currently holding
    /// BELOW what we last requested, bypassing the per-window dedup so the
    /// (unchanged) value actually goes out and tmux recomputes the window. This is
    /// what reclaims our full size on every tab after a smaller foreign client
    /// detaches, without the user having to visit each tab. Mirrors iTerm2's
    /// `fitLayoutToVariableSizeWindows` (re-push ALL windows, never gated on
    /// "active"). Only touches raw-constrained, non-hidden windows, so it is a
    /// near-no-op when nothing is constrained.
    ///
    /// Loop-safe: a window is only re-pushed while still `rawWindowForeignConstrained`.
    /// If the foreign client is gone tmux grows it -> reported grows -> raw goes
    /// false -> the next sweep skips it. If the foreign client is still attached
    /// tmux re-clamps -> no growth -> no new `%layout-change` -> no re-trigger.
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
            // Overlay suppression is for NON-displayed windows only: it hides the
            // frost while they reclaim off-screen so they're full by the time you
            // navigate to them. A visible (active) window keeps showing the truth —
            // its latch clears the instant it grows (0.3s fade), and suppressing it
            // would just blink the frost off-then-on if the constraint is still real
            // (a still-attached smaller client). It is still re-pushed, so it
            // reclaims in the silent-detach case. ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
            if !isActiveWindow(windowId: windowId) {
                markReclaimInFlight(windowId: windowId)
            }
            pushWindowSize(windowId: windowId, cols: size.cols, rows: size.rows)
        }
    }

    /// Schedule a single coalesced `reclaimAllWindowSizes` on the next runloop
    /// tick, so a burst of inbound `%layout-change` notifications collapses into
    /// one sweep. ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
    private func scheduleReclaimAllWindowSizes() {
        guard !reclaimSweepScheduled, !didEnd else { return }
        reclaimSweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reclaimSweepScheduled = false
            self.reclaimAllWindowSizes()
        }
    }

    /// Mark a window's reclaim re-push as in flight and arm a restore timer: if
    /// tmux hasn't grown the window within the grace (the foreign client is still
    /// attached and re-clamped it), drop the suppression so the dead-margin
    /// overlay comes back for a genuinely-constrained window.
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

    /// Clear a window's in-flight reclaim suppression (its re-push landed, or the
    /// window was pruned).
    private func clearReclaimInFlight(windowId: Int) {
        reclaimInFlightTimers.removeValue(forKey: windowId)?.cancel()
        reclaimInFlightWindows.remove(windowId)
    }

    /// Deferred to the next tick (we are often mid-layout when constraint state
    /// changes) so the split container re-evaluates `tmuxDeadMargin`.
    private static func nudgeLayoutInvalidation() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }

    /// The cell size of a layout node = its root window/container size.
    private static func layoutSize(_ node: TmuxLayoutNode) -> (cols: Int, rows: Int) {
        switch node {
        case let .pane(_, width, height, _, _):
            return (width, height)
        case let .split(_, _, width, height, _, _):
            return (width, height)
        }
    }

    /// True when `windowId` currently has exactly one pane — that pane drives the
    /// window's size itself (its grid IS the window), so the split container
    /// skips it (the container would otherwise read a stale `surfaceSize` before
    /// the child has laid out after a bounds change).
    func isSolePane(windowId: Int) -> Bool {
        var count = 0
        for view in paneViews.values where view.tmuxPaneBinding?.windowId == windowId {
            count += 1
            if count > 1 { return false }
        }
        return count == 1
    }

    /// Number of live pane views projected for a window.
    func paneCount(inWindow windowId: Int) -> Int {
        paneViews.values.count { $0.tmuxPaneBinding?.windowId == windowId }
    }

    /// This gateway's projected windows (id, tmux index, current tab title),
    /// sorted by tmux window index. For synchronous menu construction
    /// (move-pane / move-to-window pickers): `windowTabs` is private, and the
    /// context-menu builders run outside this file.
    func windowSummaries() -> [(windowId: Int, index: Int, title: String)] {
        windowTabs
            .map { (windowId: $0.key, index: $0.value.tmuxWindowIndex, title: $0.value.title) }
            .sorted { $0.index < $1.index }
    }

    /// Panes of one window in visual (split-tree leaf) order, with display
    /// titles. Falls back to paneViews-dict order if the tab/tree is missing
    /// (mid-reconcile). For swap-pane pickers.
    func paneSummaries(inWindow windowId: Int) -> [(paneId: Int, title: String)] {
        if let tab = windowTabs[windowId] {
            var out: [(paneId: Int, title: String)] = []
            for view in tab.splitTree.terminalLeaves {
                if let binding = view.tmuxPaneBinding, binding.windowId == windowId {
                    out.append((paneId: binding.paneId, title: view.title))
                }
            }
            if !out.isEmpty { return out }
        }
        return paneViews
            .compactMap { paneId, view in
                view.tmuxPaneBinding?.windowId == windowId
                    ? (paneId: paneId, title: view.title) : nil
            }
            .sorted { $0.paneId < $1.paneId }
    }

    /// True when tmux reports this window zoomed (setLayout projected the
    /// zoomed pane into SplitTree.zoomed; see id=tmux-zoom).
    func isWindowZoomed(windowId: Int) -> Bool {
        windowTabs[windowId]?.splitTree.zoomed != nil
    }

    /// Resolve the controller projecting a tmux window TAB: any of the tab's
    /// pane views carries the gateway binding. Nil for non-tmux tabs and for
    /// placeholders that have no live panes yet.
    static func controller(forWindowTab tab: TabModel) -> TmuxController? {
        for view in tab.splitTree.terminalLeaves {
            if let binding = view.tmuxPaneBinding {
                return controller(forOwnerSurface: binding.parentSurface)
            }
        }
        return nil
    }

    /// Resolve the controller for a GATEWAY tab: the tab's own terminal view
    /// (the one running `tmux -CC`) carries the controller directly. The
    /// window-tab resolution above can't work here — gateway views have no
    /// `tmuxPaneBinding`. Nil for non-gateway tabs and after control mode
    /// ends. (id=tmux-hidden-gateway)
    static func controller(forGatewayTab tab: TabModel) -> TmuxController? {
        tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController
    }

    // MARK: - Hidden-window bridges (state is private; the logic lives in
    // TmuxController+HiddenWindows.swift) (id=tmux-hidden-windows)

    /// The tab projecting a tmux window, if any.
    func windowTab(forWindowId windowId: Int) -> TabModel? {
        windowTabs[windowId]
    }

    /// True when at least one projected window tab is visible (not hidden).
    /// Gates hiding the gateway tab: a hidden gateway must always leave the
    /// user a visible window tab in its group. (id=tmux-hidden-gateway)
    var hasVisibleWindowTabs: Bool {
        windowTabs.values.contains { !$0.isHiddenTmuxWindow }
    }

    /// Apply `hiddenWindowIds` to every projected window tab's flag, both
    /// directions. The convergence point for the attach race: tabs created
    /// by reconcile before the `@hidden` reply landed get re-flagged here.
    func applyHiddenFlagsToWindowTabs() {
        for (windowId, tab) in windowTabs {
            let hidden = hiddenWindowIds.contains(windowId)
            if tab.isHiddenTmuxWindow != hidden {
                tab.isHiddenTmuxWindow = hidden
            }
        }
    }

    /// Re-arm a window's size dedup so the next push goes through even when
    /// it equals the latched value. Used on unhide: pushes were suppressed
    /// while hidden, and other clients may have resized the server window.
    func reArmWindowSize(windowId: Int) {
        lastPushedWindowSize.removeValue(forKey: windowId)
        if isActiveWindow(windowId: windowId) { lastPushedGlobalSize = nil }
    }

    /// Force each pane of a window to re-sync its surface size after the next
    /// layout pass (the same post-layout re-sync setLayout does), bypassing
    /// the no-op gate so a fresh authoritative size is pushed.
    func resyncPaneSizes(windowId: Int) {
        let views = paneViews.values.filter { $0.tmuxPaneBinding?.windowId == windowId }
        DispatchQueue.main.async {
            for view in views {
                view.invalidateCachedSize()
                view.sizeDidChange(view.bounds.size)
            }
        }
    }

    /// If the selection currently points at `tabID` (a tab about to be / just
    /// hidden), move it to the nearest VISIBLE tab in display order —
    /// `nearestSurvivingTabID`'s rightward-then-leftward rule, skipping
    /// hidden tabs — falling back to this controller's gateway tab. The full
    /// `selectTab` focus handoff runs on the landing tab.
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

    /// Repair the selection if it points at a hidden (or removed) tab. Used
    /// after a bulk hidden-set apply (attach reload), where nearest-neighbor
    /// has no meaning.
    func ensureSelectionVisible() {
        let hostIds = Set(windowHostIds.values + [baseWindowId])
        for hostId in hostIds {
            (TerminalWindowRegistry.tabsModel(for: hostId) ?? TmuxWindowRegistry.tabsModel(for: hostId))?
                .repairSelectionIfNeeded()
        }
    }

    /// Last GLOBAL client size pushed to tmux, to dedupe the per-layout-pass calls
    /// (the active window recomputes and pushes on every layout). One value, not
    /// per-window: the global size is the same viewport for every base-font window.
    private var lastPushedGlobalSize: (cols: UInt16, rows: UInt16)?

    /// Minimum window/client size we will ever push to tmux. A control client's
    /// size entry is a hard downward clamp on the server (resize.c
    /// clients_calculate_size) in EVERY window-size mode while the client is
    /// attached, so one transient tiny push (a mid-teardown layout pass) shrinks
    /// the window for every attached client and sticks until we push again. No
    /// legitimate iPad layout is ever this small; reject anything below it.
    /// Mirrored by the core viewer's setClientSize floor. ROOTSHELL-TMUX
    /// (id=tmux-size-floor)
    static let minPushCols: UInt16 = 10
    static let minPushRows: UInt16 = 3

    /// Push the GLOBAL control-client size (`refresh-client -C WxH`, no `@win`) via
    /// the dedicated, in-order client-size ABI. tmux applies this only to windows
    /// that have NO per-window size entry — newly-created windows we have not
    /// projected yet, and (until re-visited) windows whose per-window entry was
    /// dropped when the control client was rebuilt on a reattach. It is purely a
    /// FALLBACK: every window we actually display also gets its own `pushWindowSize`
    /// entry, which pins it independently. Keeping this fallback accurate is what
    /// stops a just-reattached / never-visited window from reverting to the stale
    /// (often narrow) gateway-grid size and reflowing its scrollback. Only a
    /// BASE-font window may set it (its grid IS the base viewport); a font-zoomed
    /// window must not, or it would mis-size base windows that fall back to it.
    /// Deduped. Routes through the IO thread → `tmuxSetClientSize` →
    /// `viewer.setClientSize`, which also refreshes the viewer's `client_cols/rows`
    /// (what an in-viewer resync re-sends).
    func pushGlobalClientSize(cols: UInt16, rows: UInt16) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        guard cols >= Self.minPushCols, rows >= Self.minPushRows else {
            // Below-floor sizes are transients (teardown / mid-collapse layout
            // passes), never a real viewport. Don't send, and don't latch the
            // dedup, so the next legitimate push goes through.
            TmuxDebugLogger.shared.event("CMD-REJECT", "global size below floor cols=\(cols) rows=\(rows)")
            return
        }
        if let last = lastPushedGlobalSize, last == (cols, rows) { return }
        lastPushedGlobalSize = (cols, rows)
        lastCommandAt = Date()
        TmuxDebugLogger.shared.command(kind: "refresh-client -C", target: "global", bytes: 0, [("cols", cols), ("rows", rows)])
        ghostty_surface_tmux_set_client_size(ownerSurface, cols, rows)
    }

    /// Send a window's per-window tmux size (`refresh-client -C @win:WxH`) on the
    /// gateway's FIFO command channel, deduped per window. The per-window size
    /// overrides the client-global size, pinning EACH window's geometry
    /// independently — so a font change (or any size change) in one window never
    /// disturbs another. Pushed for every window we display, base or font-zoomed.
    func pushWindowSize(windowId: Int, cols: UInt16, rows: UInt16) {
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        guard cols >= Self.minPushCols, rows >= Self.minPushRows else {
            // Below-floor sizes are transients (teardown / mid-collapse layout
            // passes), never a real window. A per-window entry clamps the
            // server window DOWN for every attached client, so letting one
            // through shrinks the window to ~1x1 session-wide. Don't send, and
            // don't latch the dedup, so the next legitimate push goes through.
            TmuxDebugLogger.shared.event("CMD-REJECT", "window size below floor win=\(windowId) cols=\(cols) rows=\(rows)")
            return
        }
        // A hidden window must push NO per-window size: its panes still sit
        // in the hierarchy (opacity 0) and keep calling this on layout churn,
        // but a per-window entry is a hard downward clamp for every attached
        // client — a window we don't even display must not constrain a
        // foreign client that has it open full-size. Not latched, so the
        // unhide's reArmWindowSize guarantees a fresh push.
        // (id=tmux-hidden-windows)
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
        // If this push reveals tmux is holding the window BELOW what we just
        // requested (a smaller foreign client constrained it), tmux may emit no
        // follow-up %layout-change (its size is unchanged — common on attach /
        // resume), so nothing else would re-evaluate the dead-margin overlay.
        // The latch's grace timer covers that silent case: if the raw constraint
        // still holds when it fires, it latches and nudges a layout pass. A
        // font change with a single client clears the raw state within the grace
        // (tmux answers with %layout-change), so no flicker. ROOTSHELL-TMUX
        // (id=tmux-foreign-constraint-latch)
        reevaluateForeignConstraint(windowId: windowId)
        // Trigger B (one-interaction safety net): when the ACTIVE window re-pushes
        // on any layout pass (tab switch, rotate, keyboard) and some OTHER window
        // is still foreign-constrained, sweep them too — so even if tmux emitted no
        // `%layout-change` on the foreign detach (Trigger A never fired), the first
        // interaction reclaims ALL tabs at once instead of one per visit. The check
        // EXCLUDES `windowId` itself: a still-attached smaller client legitimately
        // constrains the active window, and self-triggering would re-push it and
        // (worse) suppress its visible overlay for the grace window though the
        // constraint is real. Skipped while a sweep is running (it calls
        // `pushWindowSize` itself). ROOTSHELL-TMUX (id=tmux-foreign-reclaim-sweep)
        if !sweeping, isActiveWindow(windowId: windowId),
           windowTabs.keys.contains(where: { $0 != windowId && rawWindowForeignConstrained(windowId: $0) }) {
            scheduleReclaimAllWindowSizes()
        }
    }

    // MARK: - Debug heartbeat / live-state capture

    /// Start the live-state heartbeat (no-op if tmux debug logging is off, so no
    /// timer exists when disabled). Idempotent. Called at gateway establish and
    /// when the toggle flips on. Bounded by the controller lifetime.
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

    /// Short owning-gateway id for debug-log correlation.
    private var uuidPrefix: String { String(ownerTerminalUUID.uuidString.prefix(8)) }

    /// A command stuck in-flight with no command BLOCK for this long is a
    /// candidate stall. (`ms_since_*` snapshot fields are `uint64_t`.)
    private static let recoveryStallMs: UInt64 = 8000
    /// "Transport is alive" window: the link must have delivered some non-block
    /// inbound traffic (a `%output` or a notification) within this window for a
    /// block stall to count as a real desync. This is THE discriminator vs a
    /// network-recovery wait: a genuine pipeline desync keeps receiving async
    /// traffic (pane output, the title subscription) while only command blocks
    /// are stuck (exactly the logged hang: sinceBlockMs grew while sinceNotifMs
    /// stayed ~0); a dead/roaming transport stalls block AND output AND
    /// notification together, so this gate is false and we do NOT fire or
    /// escalate — we wait for the transport to recover and redeliver the reply.
    /// Must be < recoveryStallMs.
    private static let recoveryLiveWindowMs: UInt64 = 5000
    /// A resync that hasn't completed in this long (while the transport is alive)
    /// means the probe never echoed — escalate to a clean shell instead of
    /// stalling. Gated on transport-alive so a network wait never forceQuits.
    private static let recoveryResyncStuckMs: UInt64 = 15000
    /// A resync ends ONLY when a command BLOCK carrying the probe marker arrives:
    /// `nextResync` leaves `.resync` exclusively in its `.block_end/.block_err`
    /// arm (viewer.zig) — every other notification is dropped. So block silence,
    /// NOT general protocol traffic, is the staleness signal for a stuck resync.
    /// `%output` from a chatty pane keeps `total_notifications`/`total_output_events`
    /// climbing while the resync makes zero progress, which is exactly the shape
    /// that force-exited a healthy gateway. `ms_since_last_block` is stamped in
    /// the same pre-drop DCS arm as `total_blocks`, so it counts blocks the viewer
    /// DROPS during resync too — a stale pre-reset reply re-arms the window
    /// instead of latching us off. ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private static let recoveryResyncBlockQuietMs: UInt64 = 3000
    /// Minimum spacing between resync probe re-sends — pacing only, so a slow
    /// round trip isn't mistaken for a lost probe. It does NOT need to bound
    /// in-flight messages: `ghostty_surface_tmux_reprobe` only ever re-sends the
    /// probe, so one draining after the viewer is gone is a no-op. (Using
    /// `ghostty_surface_tmux_resume` here WOULD need that bound — its no-viewer
    /// branch synthesizes `ESC P 1000 p` and resurrects control mode over the
    /// revealed shell.) ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
    private static let recoveryResyncProbeSpacing: TimeInterval = 3.5
    /// Quiet time after the LAST re-probe before the force-exit tier may fire, so
    /// a probe always gets a fair chance to be answered first.
    private static let recoveryResyncPostProbeMs: UInt64 = 4000
    /// Absolute backstop: a resync this old force-exits regardless of re-probe
    /// budget, so a pathological link can't hold placeholder tabs forever.
    private static let recoveryResyncCeilingMs: UInt64 = 60000
    /// Re-probes per stuck resync before we just wait for the force-exit bound.
    private static let recoveryResyncMaxReprobes = 4
    /// Recoveries fired without the pipeline making progress before we give up.
    private static let recoveryMaxAttempts = 2
    /// Consecutive FOREGROUND watchdog ticks (2s each) of TOTAL blackout — a
    /// command stuck in flight while blocks AND output AND notifications are
    /// all silent — before we stop waiting for the transport and force-exit to
    /// a clean shell (~60s). Foreground-ness is now enforced explicitly by the
    /// background-escalation guard in `evaluateRecovery` (which zeroes this
    /// counter every backgrounded tick), NOT by assuming `Task.sleep` suspends
    /// while backgrounded — it does not when a live socket grants background
    /// execution. The transportAlive gate above is right to hold fire during a
    /// short network wait (tssh redelivers on reconnect), but a permanent
    /// blackout (e.g. the transport stalled under a multi-MB capture-pane burst)
    /// otherwise wedges the gateway on placeholder tabs FOREVER with no
    /// escalation. ROOTSHELL-TMUX (id=tmux-blackout-escalation, id=tmux-bg-escalation-guard)
    private static let recoveryBlackoutTickLimit = 30
    /// After a background→foreground transition, suppress ALL recovery
    /// escalation for this long so the frozen transport read thread can thaw and
    /// redeliver buffered replies. iOS freezes the read loop the instant we
    /// suspend, yet the core's wall-clock stall fields (`resync_age_ms`,
    /// `ms_since_last_block`) keep growing while suspended — so without this the
    /// first foreground tick can read a >limit stall that is about to clear and
    /// force-exit a recoverable gateway. ~2.5 watchdog ticks. ROOTSHELL-TMUX
    /// (id=tmux-bg-escalation-guard)
    private static let recoveryForegroundGraceSeconds: TimeInterval = 5

    /// Start the always-on recovery watchdog. Idempotent; bounded by the
    /// controller lifetime. Polls every 2s. Do NOT assume `Task.sleep` suspends
    /// while the app is backgrounded — a live tssh/KCP socket grants 60+s of
    /// background execution, so this keeps ticking; the background-escalation
    /// guard in `evaluateRecovery` is what stops a backgrounded (frozen-but-
    /// healthy) transport from being judged wedged. ROOTSHELL-TMUX
    /// (id=tmux-recovery-watchdog, id=tmux-bg-escalation-guard)
    private func startRecoveryWatchdog() {
        recoveryWatchdog?.cancel()
        // Seed the epoch so a controller created in the FOREGROUND (after prior
        // background cycles bumped the epoch) doesn't arm a spurious one-time
        // grace on its first tick. A controller seeded while ALREADY backgrounded
        // gets no epoch transition of its own, so flag it to arm the grace on its
        // first foreground tick instead (its wall-clock ages grew during the
        // suspend). ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
        recoveryLastForegroundBackgroundEpoch = LifecycleEpoch.shared.background
        recoveryArmGraceOnNextForeground = Ghostty.isTransportFrozenByBackground
        // A watchdog restarted on the SAME controller must not inherit a probe
        // budget/stamp from a previous resync. ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
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

    /// The owning gateway view is freeing `ownerSurface`. Stop every path that
    /// dereferences it: the always-on recovery watchdog (the crashing one), the
    /// heartbeat, the focus watchdog, and any in-flight dashboard replies. Does
    /// NOT run the didEnd control-mode-end teardown (no tab reselect / notify) —
    /// the view and controller are going away. Idempotent. ROOTSHELL-TMUX
    /// (id=tmux-gateway-surface-freed)
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
        // Drop the gateway debug-gauge provider keyed by this surface. The
        // normal control-mode-end path unregisters it (applyTmuxReconcile's
        // didEnd branch), but this teardown never sets didEnd, so without this
        // the TmuxDebugLogger singleton would retain the captured bufferedWriter
        // / restore gate after the terminal is gone. Same key the register used
        // (gatewayOwnerKey = Int(bitPattern: ownerSurface)). ROOTSHELL-TMUX
        // (id=tmux-gw-gauges, id=tmux-gateway-surface-freed)
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

    /// Recovery gave up: forcibly exit control mode through the CORE rather than
    /// the Swift-only `forceQuit()`. `ghostty_surface_tmux_force_exit` frees the
    /// viewer, unhooks the DCS parser, returns the VT parser to ground, AND emits
    /// the empty-topology snapshot — so the prune runs through the normal reconcile
    /// path (`applyTmuxReconcile`), which also drops `tmuxController` and stops this
    /// watchdog. `forceQuit()` alone would prune the Swift tabs but leave the core
    /// still in control mode (consuming bytes as DCS passthrough behind a "plain
    /// shell") and a stale controller bound to the surviving gateway view.
    /// ROOTSHELL-TMUX (id=tmux-recovery-watchdog)
    private func forceExitControlMode() {
        recoveryGaveUp = true
        // Try to detach the remote -CC client first (direct transport write;
        // the viewer queue is wedged on this path) so a half-alive/recovering
        // link doesn't keep streaming raw control-mode output into the shell
        // the force-exit is about to reveal. ROOTSHELL-TMUX (id=tmux-best-effort-detach)
        sendBestEffortDetach()
        ghostty_surface_tmux_force_exit(ownerSurface)
    }

    /// One watchdog tick: pull the core viewer snapshot and, if the command
    /// pipeline is wedged (or a recovery resync is stuck), heal it. The core
    /// self-heals in-band desyncs the parser can see (stray bytes / bad block
    /// framing → `tmuxForceResync`); this catches the "clean" data-loss case
    /// where a command reply was lost so the pipeline silently stalls.
    /// ROOTSHELL-TMUX (id=tmux-recovery-watchdog)
    private func evaluateRecovery() {
        // After control mode ends the gateway surface may be freed; the snapshot
        // ABI on a stale pointer would be a use-after-free (same guard as
        // zigSnapshotLine). The watchdog is also stopped on didEnd / surface
        // teardown, but guard defensively in case a tick races the teardown.
        // ownerSurfaceFreed covers the gateway-view cleanup path that frees the
        // surface without ever setting didEnd. ROOTSHELL-TMUX
        // (id=tmux-gateway-surface-freed)
        guard !didEnd, !ownerSurfaceFreed else { stopRecoveryWatchdog(); return }
        // We already gave up and asked the core to force-exit; wait for its
        // teardown reconcile (sets didEnd, stops us) instead of acting again.
        guard !recoveryGaveUp else { return }

        // Idle-session correctness nudge: retry pane work deferred by bounded
        // renderer-lock timeouts + re-send a dropped topology snapshot. This MUST
        // run for all users, so it lives here in the always-on recovery watchdog
        // (2s, runs regardless of the debug-log toggle) rather than in
        // emitHeartbeat, whose timer only runs while debug logging is enabled.
        // Cheap + idempotent (no-op when nothing is deferred / not a gateway).
        // ROOTSHELL-TMUX (id=tmux-flush-deferred-always-on)
        ghostty_surface_tmux_flush_deferred(ownerSurface)

        var snap = ghostty_tmux_debug_snapshot_s()
        guard ghostty_surface_tmux_debug_snapshot(ownerSurface, &snap) else {
            recoveryWedgeHits = 0
            // No viewer to sample (gone or being re-created): drop the resync
            // probe budget/stamp so a later resync starts clean instead of
            // inheriting a spent budget. ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
            recoveryResyncReprobes = 0
            recoveryResyncLastProbeAt = nil
            return
        }

        // THE discriminator vs a network-recovery wait: is the transport still
        // delivering non-block inbound traffic? A genuine desync keeps receiving
        // pane output / notifications (e.g. the title subscription) while only
        // command blocks are stuck; a dead/roaming/reconnecting transport stalls
        // everything together. If the link has gone quiet we neither fire nor
        // escalate — the tssh transport buffers and redelivers the reply on
        // reconnect, which clears command_in_flight on its own.
        //
        // The `total_* > 0` guards are REQUIRED: the core's `ms_since_*` is 0 for
        // an event that NEVER happened (msSince returns 0 when the timestamp is
        // unset), so a quiet session that never emitted `%output` would otherwise
        // read `ms_since_last_output == 0 < window` and look alive forever. The
        // counter proves the event actually occurred, so the age is meaningful.
        let outputAlive = snap.total_output_events > 0
            && snap.ms_since_last_output < Self.recoveryLiveWindowMs
        let notifAlive = snap.total_notifications > 0
            && snap.ms_since_last_notification < Self.recoveryLiveWindowMs
        let transportAlive = outputAlive || notifAlive

        // Read-thread stall detector: the gateway's byte-processing thread
        // entered processOutput and hasn't finished for >5s — it is BLOCKED at
        // the named site (1 awaiting-gateway-lock, 2 parsing, 3 pane-lock,
        // 4/5 mailbox sends). This is the smoking-gun line for "transport
        // delivered bytes but the parser never saw them"; log it prominently
        // each tick while it persists. ROOTSHELL-TMUX (id=tmux-debug-read-progress)
        if snap.read_thread_site != 0,
           snap.gw_read_enter_bytes > snap.gw_read_done_bytes,
           snap.ms_since_read_enter >= 5000 {
            TmuxDebugLogger.shared.event(
                "RECOVER",
                "READ THREAD STALLED site=\(snap.read_thread_site) pane=\(snap.read_site_pane_id) "
                + "for \(snap.ms_since_read_enter)ms (rdIn=\(snap.gw_read_enter_bytes) "
                + "rdDone=\(snap.gw_read_done_bytes) rdPut=\(snap.gw_tmux_put_bytes)) gw=\(uuidPrefix)")
        }

        // Background-escalation guard. iOS freezes the transport read thread the
        // instant we suspend, so a command stuck in flight with EVERY inbound
        // channel silent is indistinguishable from the unrecoverable stall the
        // escalations below target — yet it is fully recoverable: the link thaws
        // and redelivers on foreground. (An active tssh/KCP socket grants 60+s of
        // background execution, so this watchdog DOES keep ticking while
        // backgrounded — `Task.sleep` does not reliably suspend it. Confirmed: a
        // healthy gateway force-exited at +60s entirely backgrounded.) While
        // backgrounded, keep the cheap diagnostics above (flush_deferred + the
        // read-thread-stall log) but zero the debounce counters every tick and
        // NEVER escalate. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard,
        // id=tmux-blackout-escalation)
        if Ghostty.isTransportFrozenByBackground {
            // Positive instrumentation: the would-be-escalation shape (a stuck
            // command with a stale block) IS present, but we're suppressing it
            // because we're backgrounded. This is the smoking-gun line that
            // REPLACES the spurious force-exit — its repetition with NO following
            // force-exit proves the guard works. ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
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
            // Re-baseline so suspend-era bytes (buffered replay at thaw) are
            // never counted as foreground no-protocol traffic.
            // ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
            recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
            recoveryLastProtocolEvents = snap.total_blocks &+ snap.total_notifications &+ snap.total_output_events
            return
        }
        // Foreground. Detect a background that happened since our last FOREGROUND
        // tick via the epoch delta — robust even if `Task.sleep` slept through the
        // whole blip so no backgrounded tick reset the counters (the epoch bumps
        // synchronously at background entry). On that edge, zero the debounce +
        // attempt budget and arm a fresh grace: the wall-clock escalation branches
        // below (`resync_age_ms` / `ms_since_last_block`) kept growing while
        // suspended and would otherwise fire on this very tick, before the thawed
        // read thread can redeliver the buffered reply (which clears
        // command_in_flight on its own). ROOTSHELL-TMUX (id=tmux-bg-escalation-guard)
        // Arm the grace on a real background→foreground transition (epoch delta)
        // OR on the first foreground tick of a controller that was seeded while
        // already backgrounded (no epoch transition of its own, but its
        // wall-clock ages still grew during the suspend). ROOTSHELL-TMUX
        // (id=tmux-bg-escalation-guard)
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

        // Resync probe re-send (id=tmux-resync-live-reprobe). A resync ends ONLY
        // when a BLOCK carrying the probe marker arrives, so "no block for a few
        // seconds" is the signal that the probe never reached tmux — a live tmux
        // answers `display-message -p` in well under a second.
        //
        // The motivating failure: a tssh reconnect arms tsshd's pending-INPUT
        // discard synchronously (session.go, `discardMarker.Store`) and swallows
        // all client input until the 8-byte marker appears; the client only emits
        // that marker piggybacked on real input. The discard-triggered reset
        // writes its probe into that window, and the viewer then sits in `.resync`
        // sending NOTHING — so the marker is never emitted, the probe is never
        // delivered, and the stall cannot self-heal. A re-probe IS real input, so
        // it carries the marker: the server flushes its discard buffer AND gets a
        // fresh probe in one write. Deliberately NOT gated on transportAlive —
        // that gate is what made this unreachable on a healthy-looking link, and
        // an extra probe into a roaming tssh buffer is harmless (the core no-ops
        // it once the resync has ended).
        if snap.viewer_state != 2 {
            // Cleared here rather than in the `viewer_state != 2` arm further
            // down, which is only reached when nothing above it returned.
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
            // Resync-ONLY entry point: re-sends the probe when a viewer is live and
            // resyncing, and is otherwise a strict no-op. `ghostty_surface_tmux_resume`
            // must NOT be used here — its no-viewer branch synthesizes control-mode
            // entry, so a message drained after the gateway went away would
            // resurrect it over the revealed shell. Because this one cannot, we do
            // not need to bound in-flight messages at all.
            // ROOTSHELL-TMUX (id=tmux-resync-live-reprobe)
            ghostty_surface_tmux_reprobe(ownerSurface)
        }

        // Escalation: a recovery resync that never completes WHILE the transport
        // is alive (probe genuinely never echoed → tmux gone), so return to a
        // plain shell. Gated on transportAlive so a network wait never forceQuits
        // the gateway out from under a recoverable session. viewer_state 2 ==
        // resync.
        //
        // This USED to be a bare `resync_age_ms >= 15s` deadline, which tore down
        // healthy gateways: its own transportAlive gate is the evidence the link
        // is working, and a swallowed probe (above) is recoverable, not fatal. Now
        // we only give up once every re-probe has been spent AND the last one went
        // unanswered — plus an absolute ceiling so a pathological link still can't
        // hold placeholder tabs forever. A remote whose tmux is really gone stops
        // producing blocks, so it still exits promptly.
        // ROOTSHELL-TMUX (id=tmux-resync-progress-gate)
        if transportAlive, snap.viewer_state == 2, !recoveryGaveUp {
            // A spent budget alone isn't enough — the LAST probe must also have
            // had its quiet window to be answered, AND the resync must still be
            // block-silent. Without the block-silence term a block landing after
            // the final probe (a stale pre-reset reply, or the marker itself
            // mid-processing) would refresh `ms_since_last_block` yet still be
            // force-exited on the next tick, which is the exact "tear down a
            // gateway that IS progressing" bug this tier is being fixed for.
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

        // Dead-shell resync tier: viewer stuck in resync, transport CLAIMS
        // healthy, yet the bytes reaching the hooked parser produce ZERO
        // protocol progress (transportAlive is false — no %output, no
        // notifications). That is the signature of a remote that dropped back
        // to a plain shell after tmux exited and its `%exit` was lost to data
        // loss: the shell's prompt/echo bytes flow but never parse. Neither
        // pre-existing tier covers it — resync-stuck (above) requires
        // transportAlive, blackout (below) requires viewer_state 3.
        // The probe re-send this tier used to own now lives in the single
        // block-silence site above (id=tmux-resync-live-reprobe), which is NOT
        // gated on transportAlive and so covers this shape too — on a dead shell
        // the probe's ECHO still triggers the core's probe-echo detach
        // (id=probe-echo-detach, clean teardown, usually before the force-exit
        // bound). Keeping one budget also stops a live-link stall from spending
        // the re-probes that keep that echo matcher armed. This tier retains its
        // bytes-without-protocol detection and its own force-exit. Pure silence
        // (no bytes at all) is the network-redelivery-wait shape and is
        // deliberately left to the slow blackout tier below.
        // ROOTSHELL-TMUX (id=tmux-resync-dead-shell)
        let protocolEvents = snap.total_blocks &+ snap.total_notifications &+ snap.total_output_events
        // Any parsed protocol event since the last tick proves the remote
        // speaks the protocol — clear the sticky flag BEFORE (and regardless
        // of) the dead-shell branch below. The event can land on a tick where
        // transportAlive is still true, which skips that branch entirely while
        // the trailing baseline update still advances — a clear confined to
        // the branch would never observe the delta, and the stale flag could
        // force-exit a healthy resync once the event aged past the live
        // window. A dead shell never advances these counters.
        let protocolAdvanced = recoveryLastProtocolEvents.map { protocolEvents != $0 } ?? false
        if protocolAdvanced {
            recoveryResyncSawUnparsedBytes = false
        }
        if snap.viewer_state == 2, !transportAlive, gatewayTransportClaimsConnected() {
            // Only bytes the parser skipped while sitting in IDLE count as
            // unparseable, and only in a window with NO protocol progress
            // (protocol wins for the same window: a tick that sampled the
            // parser back in idle right after a block completed sees that
            // block's own bytes in the delta). parser_state 2/3 mean a
            // notification/block is mid-arrival — a multi-MB capture-pane
            // block can stream for many seconds without completing any event,
            // and counting those bytes would force-exit a healthy slow resync.
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
            // The probe budget/stamp are cleared unconditionally by the re-probe
            // site above (this arm is only reached when nothing there returned).
            recoveryResyncSawUnparsedBytes = false
        }
        recoveryLastTmuxPutBytes = snap.gw_tmux_put_bytes
        recoveryLastProtocolEvents = protocolEvents

        // Total-blackout escalation: a command stuck in flight while EVERY kind
        // of inbound traffic is silent. transportAlive=false correctly holds
        // the resync fire (a probe can't go anywhere on a dead link), but with
        // no escalation the gateway sat on placeholder tabs forever (observed:
        // a multi-MB capture-pane reply stalling the tssh transport
        // bidirectionally). Count consecutive FOREGROUND ticks — the
        // background-escalation guard above zeroes this counter every
        // backgrounded tick (NOT `Task.sleep` suspending, which a live socket
        // defeats) — and after ~60s force-exit to a clean shell. total_blocks > 0 keeps
        // a never-established viewer out of this path (the resume watchdog
        // owns that case). If the transport DOES recover first, inbound bytes
        // hit the parser's stray-byte self-heal and transportAlive resets the
        // counter here.
        //
        // CRITICAL gate: only escalate while the SESSION ITSELF claims to be
        // connected (`gatewayTransportClaimsConnected`). A silent link whose
        // transport reports roaming/reconnecting/disconnected is the
        // documented recoverable wait — tssh buffers and redelivers on
        // reconnect, and force-exiting there would dump the redelivered
        // control bytes into a parser already returned to ground. The wedge
        // this escalation exists for is the opposite shape: the transport
        // REPORTS healthy/running yet delivers nothing (stalled under the
        // capture burst), where no redelivery is coming.
        // ROOTSHELL-TMUX (id=tmux-blackout-escalation)
        // Stall shape: either a command stuck in flight in the steady state, or
        // a resync sitting silent (viewer_state 2 with nothing arriving at all
        // — the state a discard-reset leaves behind when the remote never
        // answers). Pure silence in resync must NOT fire fast (it is exactly
        // the network-redelivery-wait shape), so it shares this slow 30-tick
        // path rather than the dead-shell tier above; but a link that CLAIMS
        // healthy while delivering nothing for ~60s has no redelivery coming,
        // same argument as the state-3 blackout. total_blocks > 0 keeps a
        // mid-restore resume viewer (no blocks yet) out — the resume watchdog
        // owns that case. ROOTSHELL-TMUX (id=tmux-blackout-escalation,
        // id=tmux-resync-dead-shell)
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

        // The pipeline made progress (a command completed) → recovery worked /
        // never needed; reset the attempt budget for any future independent wedge.
        if snap.viewer_state == 3, snap.command_in_flight == 0 {
            recoveryAttempts = 0
        }

        // Wedge predicate: a command stuck in-flight behind a growing queue, no
        // command block for >=8s, the parser NOT mid-block (state 3 would mean a
        // block IS arriving → not stuck), AND the transport demonstrably alive
        // (other inbound traffic recent). The transportAlive term is what keeps
        // this from firing while the link is just waiting on network recovery.
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

        // Debounce: require the predicate on two consecutive ticks before acting.
        recoveryWedgeHits += 1
        guard recoveryWedgeHits >= 2 else { return }

        // Cooldown so a just-fired recovery (viewer briefly leaves command_queue)
        // isn't re-fired before it can change state.
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

    /// A lossy server-side OUTPUT discard was detected on this -CC gateway's tssh
    /// transport: tsshd dropped buffered output while the link was down (discard
    /// mode, no back pressure), so the control stream lost bytes mid-block. Drive
    /// a full surface reset + recapture (`ghostty_surface_tmux_reset`) so every
    /// pane rebuilds to a consistent state — no duplicated scrollback, no tab
    /// flicker. Logged to BOTH the tmux and resume debug logs (counts/ids only) so
    /// EITHER debug toggle captures the event.
    ///
    /// We do NOT wall-clock-suppress here: the CORE coalesces/latches every call
    /// (`requestReset` while a resync is in flight → honored at the next marker; a
    /// fresh `forceReset` while in command_queue), so suppression would only risk
    /// dropping a distinct SECOND lossy reconnect (one that arrives while the first
    /// reset is still resyncing or just after it completed). Discard reports are
    /// already ~one-per-reconnect, so the unconditional call is cheap.
    func resetForDiscard(outputLines: Int, outputBytes: Int) {
        guard !ownerSurfaceFreed else { return }
        let selectedWindowIds = windowTabs.keys.filter { isActiveWindow(windowId: $0) }
        // A controller can project tmux windows into multiple app windows, each
        // with its own selected tab. Prefer the one whose pane actually owns
        // focus in the key UIWindow. If there is exactly one local selection it
        // is unambiguous; otherwise let Ghostty fall back to tmux's server-active
        // window rather than choosing an arbitrary Dictionary entry.
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
        // Full reset + pane recapture: every pane repaints on our order.
        // Suppressing the gateway covers the panes (they check parentUUID).
        TerminalBellSuppressor.suppress(
            ownerTerminalUUID, for: TerminalBellSuppressor.forcedRedraw)
        // Agent detection needs the longer window: unlike a detach/reattach,
        // this rebuild REUSES every pane view, so the monitors survive with
        // their pre-outage state and would read the recapture's own churn as
        // a fresh "needs your input".
        TerminalBellSuppressor.suppressRebuild(ownerTerminalUUID)
        if let preferredWindowId, preferredWindowId >= 0 {
            ghostty_surface_tmux_reset_prioritized(ownerSurface, UInt(preferredWindowId))
        } else {
            ghostty_surface_tmux_reset(ownerSurface)
        }
    }

    /// Emit one STATE line (Swift-side counters) plus a ZIG line (the core
    /// viewer snapshot). `manual` marks button-triggered captures. Cheap and
    /// gated; safe to call off the 5s cadence.
    func emitHeartbeat(manual: Bool) {
        // NOTE: the deferred-flush correctness nudge lives in the always-on
        // recovery watchdog (evaluateRecovery, id=tmux-flush-deferred-always-on),
        // NOT here — this heartbeat's timer only runs while debug logging is
        // enabled, so a nudge here would never fire for normal users.
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

    /// Pull the privacy-safe core viewer snapshot for this gateway. Returns nil
    /// when the surface isn't a live tmux gateway. Numeric/enum fields only.
    private func zigSnapshotLine() -> String? {
        // After control mode ends (didEnd) the gateway surface may be torn down —
        // forceQuit (gateway tab closed) frees it asynchronously. `ownerSurface`
        // is a raw pointer captured at init, so calling the snapshot ABI on it
        // post-teardown is a use-after-free. The snapshot is only meaningful for a
        // live gateway anyway. ownerSurfaceFreed also covers the gateway-view
        // cleanup path that frees the surface without setting didEnd.
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
            // ABI v2: read-thread progress — rdIn/rdDone bytes entering/
            // leaving the gateway byte path, rdPut bytes that reached the tmux
            // parser, rdSite where the read thread last was (0 idle,
            // 1 awaiting-lock, 2 parsing, 3 pane-lock, 4 mailbox, 5 surface-
            // mailbox). ROOTSHELL-TMUX (id=tmux-debug-read-progress)
            + "rdIn=\(snap.gw_read_enter_bytes) rdDone=\(snap.gw_read_done_bytes) "
            + "rdPut=\(snap.gw_tmux_put_bytes) rdSite=\(snap.read_thread_site) "
            + "rdPane=\(snap.read_site_pane_id) rdEnterAgeMs=\(snap.ms_since_read_enter) "
            + "rdDoneAgeMs=\(snap.ms_since_read_done) paneLockTO=\(snap.pane_lock_timeouts)"
    }

    /// Capture every live controller's state immediately (manual button). Works
    /// for soft hangs where the UI is still responsive.
    static func captureAllState() {
        TmuxDebugLogger.shared.marker("MANUAL STATE CAPTURE")
        for (_, weak) in controllersByOwnerSurface {
            weak.controller?.emitHeartbeat(manual: true)
        }
    }
}

/// Maps a window's stable id to its `TabsModel`, so the tmux reconcile action
/// (delivered via a C callback that only knows the viewer-owner surface) can
/// reach the correct window's tabs. `MainView` registers on appear and
/// unregisters on disappear. Main-actor isolated; the reference is weak so it
/// never keeps a window alive.
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

    /// Every live window's TabsModel (agent attention reconciles its
    /// monitors against this on topology events).
    static func allTabsModels() -> [TabsModel] {
        liveModels().map(\.model)
    }

    static func allWindows() -> [(windowId: String, model: TabsModel)] {
        liveModels()
    }

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
        return live
    }

    static func gatewayView(ownerTerminalUUID owner: UUID) -> Ghostty.TerminalView? {
        for (_, model) in liveModels() {
            for tab in model.tabs {
                if let view = tab.splitTree.terminalLeaves.first(where: { $0.uuid == owner }) {
                    return view
                }
            }
        }
        return nil
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

    /// The one restored placeholder selected locally for this gateway. A cold
    /// viewer has no controller/windowTabs yet, so this is the only point where
    /// the persisted active tab can be carried into active-first recovery.
    /// Multiple selected candidates across scenes are deliberately ambiguous.
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
    /// Apply a decoded tmux reconcile batch. Called on the viewer-owner view
    /// (the surface running `tmux -CC`). Lazily creates the per-connection
    /// `TmuxController` the first time, wiring it to this window's tabs.
    @MainActor
    func applyTmuxReconcile(_ ops: [TmuxReconcileOp]) {
        let signposter = TmuxPipelineSignposts.signposter
        let signpost = signposter.beginInterval("tmux.reconcile", "ops=\(ops.count)")
        defer { signposter.endInterval("tmux.reconcile", signpost) }
        // An empty / prune-only batch with no controller yet (e.g. a `%exit` or a
        // resume-abort teardown that beat any window projection) has nothing to
        // project. Do NOT create a controller for it: a windowless controller
        // never flips `didEnd`, so it would linger non-nil and re-mark the
        // gateway tmux-active on the next save. Leave the resume watchdog running
        // so it can still abort/clean up if this was a mid-resume `%exit`.
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
            // Stamp the gateway's connection identity for per-connection
            // last-session persistence, then flush a session identity that
            // arrived before the controller existed (startup ordering).
            // ROOTSHELL-TMUX (id=tmux-session-info-stash)
            if let ssh = connectionConfig.underlyingSSHConfig {
                controller.connectionKey = TmuxGatewaySessionStore.connectionKey(
                    host: ssh.host, port: ssh.port, username: ssh.username)
            }
            if let pending = pendingTmuxSessionInfo {
                pendingTmuxSessionInfo = nil
                controller.updateCurrentSession(id: pending.id, name: pending.name)
            }
            // Flush pipe-writer loss reported before the controller existed
            // (drain-to-empty beat this first reconcile): the control stream
            // is gapped, drive the same heal as a live overflow report.
            // ROOTSHELL-TMUX (id=tmux-overflow-stash)
            if pendingTmuxOverflowBytes > 0 {
                let dropped = pendingTmuxOverflowBytes
                pendingTmuxOverflowBytes = 0
                controller.resetForDiscard(outputLines: 0, outputBytes: dropped)
            }
            sessionController.resetGatewayReportFilter()
            // This surface is now the tmux control-mode gateway; its session
            // output is the latency-sensitive control stream, so stop batching.
            outputPipeline.setOutputCoalescingEnabled(false)
            // Install the off-main response fast path for the local-tmux gateway
            // so relayed pane keystrokes skip the per-chunk main-actor hop. Remote
            // transports keep the existing path (network RTT dominates that hop).
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
            // Defensive: a stuck detach-freeze from a previous control-mode
            // session must not gate the new gateway's size flow.
            // ROOTSHELL-TMUX (id=tmux-detach-size-resync)
            tmuxDetachInProgressAtomic = false
            TmuxDebugLogger.shared.marker("TMUX GATEWAY ESTABLISHED gw=\(uuid.uuidString.prefix(8))")
            TmuxDebugLogger.shared.resetGatewayBytes(owner: Int(bitPattern: ownerSurface))
            // Register the Swift byte-delivery gauges (pipe writer depth/
            // total, restore-gate state) for the heartbeat's [STATE] line so a
            // wedge log can name the hop eating bytes. Both captured objects
            // are nonisolated and thread-safe. ROOTSHELL-TMUX (id=tmux-gw-gauges)
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

        // The live tmux #T subscription produces a single title op for every
        // OSC title frame. Classify it here so, after the mandatory transport
        // rebinding below, it can skip unrelated gateway-tab and teardown work.
        let isTitleOnly = !ops.isEmpty && ops.allSatisfy { op in
            switch op {
            case .setTabTitle, .setWindowTitle:
                return true
            default:
                return false
            }
        }
        // Title-only batches arrive once per OSC title frame. Once the live
        // session object below has been rebound, they need only the apply.
        // ROOTSHELL-TMUX (id=tmux-title-only-fast-path)
        if !createdController, isTitleOnly,
           let session, tmuxReboundSession === session {
            // connectionConfig can change under the same session object.
            controller.updateGatewaySource(from: connectionConfig)
            controller.apply(ops)
            return
        }
        // A reconcile with windows arrived and we accepted it: control mode is
        // live. If this gateway was being RESUMED after restore, cancel the
        // resume watchdog so it doesn't abort the now-successful resume.
        tmuxResumeWatchdog?.cancel()
        tmuxResumeWatchdog = nil
        restoredWasTmuxGateway = false
        tmuxResumeRequested = false
        tmuxResumeCancelRequested = false

        // Wire the roam (tssh) transport's output-discard signal to the
        // controller's full reset + recapture: the server discards stale OUTPUT
        // on a lossy reconnect (input is kept, output discards to avoid back
        // pressure), which can drop bytes mid-`%output`/control block. Assigned
        // on EVERY reconcile (idempotent), not just at controller creation, so
        // a gateway session replaced under a live controller is re-wired instead
        // of silently dropping discard events into a nil closure.
        //
        // Resolved through `gatewayTrzszSession` rather than a direct cast so
        // SHELL-LAUNCHED tssh gateways (embedded in a LocalShellSession) are
        // wired too — the bare cast missed them entirely, so neither the
        // discard→reset path nor keep-pending-input ever reached them.
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

        // Keep-pending-input follows control mode, decided AFTER apply() so the
        // batch that ENDS control mode takes exactly one branch. Deciding before
        // apply() meant an ending batch enabled and then disabled in the same
        // turn, racing two pushes whose final server value could stay enabled.
        //
        // Enabled: tsshd must KEEP pending input across a roam instead of
        // discarding it (a discarded resync probe strands the viewer in resync
        // forever). Re-asserted on EVERY live reconcile, not just at controller
        // creation, so a session replaced under a live controller — or any
        // rebuilt transport for a manually-typed `tmux -CC` — cannot silently
        // fall back to discard-input mode. Idempotent and safe before connect.
        // ROOTSHELL-TMUX (id=tmux-keep-pending-rebind)
        if let trzsz = TmuxController.gatewayTrzszSession(for: session) {
            if controller.didEnd {
                // The control stream is gone, so its override goes with it: the
                // plain shell replacing this gateway must honour the user's
                // configured setting, or input typed during a later outage is
                // replayed into a shell they expected to discard it.
                trzsz.disableControlModeKeepPendingInput()
            } else {
                trzsz.enableControlModeKeepPendingInput()
            }
        }

        // A metadata-only title batch has now completed all transport rebinding
        // required on every reconcile. It does not need the remaining gateway
        // tab marking or control-mode teardown checks; title ops cannot end the
        // controller. This is deliberately after onOutputDiscarded wiring and
        // keep-pending-input reassertion so replacement tssh sessions remain
        // recoverable even when their first subsequent batch is title-only.
        tmuxReboundSession = session
        if !createdController, isTitleOnly {
            return
        }

        // Don't re-mark the gateway tab once control mode has ended: prune() (on
        // %exit) already cleared isTmuxGateway, and re-setting it would leave the
        // ex-gateway tab flagged with a nil controller, which misleads the
        // selection fallback in repairSelectionIfNeeded.
        // ROOTSHELL-TMUX (id=tmux-skip-markgateway-on-didend)
        if !controller.didEnd {
            controller.markGatewayTab(ownerView: self)
        }

        // Control mode ended (tmux exited / detached): the controller has
        // already restored the gateway tab. Drop the per-connection controller
        // and the off-main input fast path so the gateway behaves as a normal
        // session again (a future `tmux -CC` re-establishes a fresh controller).
        // The local `controller` keeps the object alive until this method
        // returns, so clearing the property here will not free it mid-call.
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
            // requestGracefulDetach froze this view's size flow (sizeDidChange's
            // set_size + updatePTYSize dispatches early-return on the atomic
            // flag) for the teardown window. Re-enable it and force a full
            // resync: bounds may have changed while frozen (the full-screen
            // session dashboard covers the tab) and the remote PTY winsize was
            // left at the detach-time grid — without this the ex-gateway shell
            // wedges at the wrong size forever, because the identical-size
            // dedups (lastFramebufferSize / lastSentGridSize) block any resend.
            // ROOTSHELL-TMUX (id=tmux-detach-size-resync)
            tmuxDetachInProgressAtomic = false
            invalidateCachedSize()
            sizeDidChange(bounds.size)
            TmuxDebugLogger.shared.marker("CONTROL MODE END gw=\(uuid.uuidString.prefix(8))")
        }

        // A fresh controller (initial attach OR a resume rebuild) starts with an
        // empty per-window size map, and the resync re-sends only the stale
        // gateway-grid global size (stream_handler re-inits the viewer from the
        // hidden gateway's grid). The visible window's bounds usually don't change
        // across a reattach, so its layout-driven size push won't fire on its own.
        // Kick a layout invalidation so the active window recomputes NOW and pushes
        // the correct global client size; otherwise every just-reattached base-font
        // window stays narrow until the next manual resize. Async so SwiftUI has
        // built the rebuilt tab's view hierarchy first. The push dedups, so this is
        // cheap. ROOTSHELL-TMUX (id=tmux-resume-global-size-kick)
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

        // Restored tmux gateways deliberately skip replaying their hidden
        // gateway scrollback/mode trailer: projected panes are authoritatively
        // rebuilt from tmux, and a pipe-drained byte is not necessarily parsed
        // before this mailbox message. Arm immediately, wait for the IO thread's
        // active flag, then release tssh bytes into the control parser.
        tmuxResumeGateReleaseTask?.cancel()
        tmuxResumeGateReleaseTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }

            self.maybeResumeTmuxControlMode()
            // The foreground watchdog normally resolves this within ~12s. Use
            // a much larger independent bound here so a wedged mailbox cannot
            // leave a 5ms polling task alive forever. Poll slowly while the
            // transport is frozen in the background to avoid needless wakeups.
            let maxArmPolls = 12_000
            var armPolls = 0
            while !Task.isCancelled {
                guard let surface = self.surface else {
                    self.tmuxResumeGateReleaseScheduled = false
                    self.tmuxResumeGateReleaseTask = nil
                    return
                }
                if !self.tmuxResumeRequested {
                    // Deferred user cancellation armed and immediately aborted
                    // the viewer. Drop the held control records rather than
                    // ever replaying them through the ordinary shell parser.
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

    /// Re-enter tmux control mode on a RESTORED gateway whose tssh session has
    /// just resumed the live pty. The live `tmux -CC` keeps streaming the control
    /// protocol, but this fresh surface never saw the `ESC P 1000 p` preamble, so
    /// without this the stream renders as garbage and no reconcile fires.
    ///
    /// `ghostty_surface_tmux_resume` synthesizes control-mode entry and writes a
    /// resync probe; tmux's answer drives the topology rebuild. The first probe
    /// can be LOST (written before the tssh transport finished attaching), and an
    /// idle tmux session (a shell prompt) only ever answers OUR probe — so we
    /// re-send it on a short cadence (each call past the first just re-writes the
    /// probe) until a reconcile arrives (which cancels the watchdog in
    /// `applyTmuxReconcile`), then give up: abort and drop the placeholder tabs so
    /// the gateway returns to a normal shell. One-shot via `tmuxResumeRequested`;
    /// a no-op unless this terminal was a saved gateway. Called after the saved
    /// terminal stream drains but before its gated live tssh bytes are released.
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

        // Probe-retry watchdog: re-send the probe every 1.5s until a reconcile
        // arrives (tmuxController != nil) or we exhaust the attempts (~12s).
        tmuxResumeWatchdog?.cancel()
        tmuxResumeWatchdog = Task { @MainActor [weak self] in
            // Count only FOREGROUND attempts. iOS freezes the transport read
            // thread while backgrounded, so the resume probe's reply is merely
            // stuck in the frozen link (not lost) — burning the ~12s attempt
            // budget there would fire the abort + drop restored placeholder tabs
            // for a resume that would succeed on foreground. Same false-suspend
            // hazard as the recovery watchdog; `Task.sleep` does not reliably
            // suspend while a live socket grants background execution.
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
                // Frozen link while backgrounded: don't burn an attempt or
                // re-probe (the reply can't arrive until we foreground).
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

    /// Remove this gateway's restored placeholder tabs that are still awaiting a
    /// reconcile (the resume failed / tmux is gone). Matched by owning gateway
    /// terminal UUID (stable across restore).
    @MainActor
    func removeAwaitingTmuxPlaceholders(clearGatewayRestoreState: Bool = true) {
        let myUUID = uuid
        TmuxWindowRegistry.removeAwaitingPlaceholders(ownerTerminalUUID: myUUID)
        // The resume failed: drop a restored hidden-gateway flag still pending
        // on this view's own tab, so a future manual `tmux -CC` from it can't
        // consume the stale state. (id=tmux-hidden-gateway)
        if let located = TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: myUUID) {
            located.tab.pendingHiddenTmuxGatewayRestore = false
        }
        if clearGatewayRestoreState {
            restoredWasTmuxGateway = false
            tmuxResumeRequested = false
            tmuxResumeCancelRequested = false
            // Overflow stashed during the abandoned resume belongs to its
            // control stream; don't let a future manual `tmux -CC` flush it
            // into a bogus reset. ROOTSHELL-TMUX (id=tmux-overflow-stash)
            pendingTmuxOverflowBytes = 0
        }
        TmuxDebugLogger.shared.event("RESTORE", "removed awaiting placeholders gw=\(myUUID.uuidString.prefix(8))")
    }

    /// User-requested cancellation of a restored tmux resume. Unlike closing a
    /// single placeholder tab, this abandons the whole pending recovery for this
    /// gateway and drops every still-awaiting projected window.
    @MainActor
    func cancelTmuxRestoreRecovery() {
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

    /// Gracefully leave tmux control mode for this gateway. Routes through the
    /// core (`ghostty_surface_tmux_detach`), which queues a `detach-client` in the
    /// viewer's command channel (FIFO-safe), NOT a raw write to the session: a raw
    /// `detach-client` injected into the PTY interleaves with the viewer's own
    /// control-protocol commands and the `tmux -CC` client never cleanly exits (it
    /// lingers in control mode). tmux replies `%exit`, the viewer tears down, the
    /// control-mode DCS is force-unhooked, the `tmux -CC` process exits, and the
    /// gateway returns to its shell. The tmux server/session stays alive.
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

    /// ESC escape hatch: true when the CORE reports this surface is a live tmux
    /// control-mode gateway (its DCS control channel is hooked), independent of
    /// whether the Swift `TmuxController` still exists. If a reconcile ever tears
    /// the controller down while tmux is still alive, `tmuxController` is nil and
    /// the normal ESC routing can't find the gateway — this lets ESC still detach
    /// so the user is never trapped in a stuck gateway. Pane surfaces have no
    /// viewer (it lives on the gateway), so this is false for them.
    @MainActor
    var isTmuxGatewaySurfaceActive: Bool {
        guard let surface else { return false }
        return ghostty_surface_tmux_active(surface)
    }

    /// Request that tmux split this pane. Called on a tmux PANE view. Rather than
    /// creating a local split (which would flash then vanish when the next
    /// reconcile rebuilds the tab's split tree from tmux's authoritative layout),
    /// this sends `split-window` to the tmux server via the gateway. tmux creates
    /// the real pane and emits `%layout-change`; the reconcile then builds the
    /// bound pane surface and the native split. The new pane becomes focused
    /// (no `-d`); the reconcile's focus op moves first responder to it.
    @MainActor
    func requestTmuxSplit(_ direction: SplitTree<SplitPaneView>.NewDirection) {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        controller.noteSplitRequest(windowId: binding.windowId)
        // tmux: -h = side-by-side (horizontal), -v = stacked (vertical);
        // -b = place the new pane BEFORE the target (i.e. left / up).
        let flags: String
        switch direction {
        case .right: flags = "-h"
        case .left:  flags = "-h -b"
        case .down:  flags = "-v"
        case .up:    flags = "-v -b"
        }
        sendTmuxCommand("split-window \(flags) -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Tell tmux this pane is now the user's active pane. Called ONLY for
    /// USER-initiated focus changes (tap, split navigation, tab switch) —
    /// never for programmatic focus (remote follows, split fulfillment,
    /// watchdog re-asserts, view reparenting). The core's tmux backend used
    /// to echo select-pane/select-window on EVERY surface focus gain; with
    /// two clients attached, each client follows %window-pane-changed one
    /// step behind its own echoes, turning any divergence into a
    /// self-sustaining focus oscillation — and every command makes its
    /// client tmux's "latest" client, so differently-sized clients also
    /// ping-pong the window size in an infinite %layout-change storm.
    /// Two separate sends: each tracked command must own its %begin/%end
    /// block (a two-line write would desync the viewer's block FIFO).
    /// ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
    @MainActor
    func requestTmuxSelectPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        sendTmuxCommand("select-window -t @\(binding.windowId)\n", to: binding.parentSurface)
        sendTmuxCommand("select-pane -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Request that tmux kill this pane. Called on a tmux PANE view. Killing the
    /// last pane of a window closes the window (`%window-close` -> prune drops the
    /// tab); killing the last pane of the session ends control mode (`%exit` ->
    /// prune restores the gateway tab). The local teardown is driven entirely by
    /// the resulting reconcile, so no local split-tree mutation happens here.
    @MainActor
    func requestTmuxKillPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        sendTmuxCommand("kill-pane -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Request that tmux kill this pane's whole WINDOW (a tab close on a tmux
    /// window tab). Returns true when the command was sent to a live gateway;
    /// the caller must then NOT tear the tab down locally; the reconcile's
    /// prune removes the tab once tmux confirms (`%window-close` -> topology).
    /// Closing the tab locally instead would desync: the window survives on
    /// the server while the controller keeps stale windowTabs/paneViews
    /// entries that every later reconcile early-returns on.
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

    /// Move this pane's WINDOW directly after another window of the same
    /// session (a user tab-reorder gesture). `move-window -a` renumbers
    /// neighbors like `new-window -a` does; the resulting `%window-*`
    /// reconcile lands the tabs in the new order on every attached client.
    /// ROOTSHELL-TMUX (id=tmux-window-reorder-server)
    @MainActor
    func requestTmuxMoveWindow(afterWindowId targetWindowId: Int) {
        sendTmuxMoveWindow(flag: "-a", targetWindowId: targetWindowId)
    }

    /// Move this pane's WINDOW directly before another window of the same
    /// session (a drop at the FIRST sibling position). Uses `move-window -b`,
    /// which requires tmux >= 3.2 — a floor the -CC integration already
    /// effectively assumes; older servers will reject just this first-slot
    /// drop and the next reconcile snaps the local order back (self-healing).
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

    /// Request that tmux create a new window in this gateway's session. Called
    /// on a tmux PANE view. Sends `new-window -a -t @<thisWindow>` so tmux inserts
    /// the window at the next index AFTER the window the user is currently viewing
    /// (shifting later windows up if needed) — matching the "right of current"
    /// placement CMD-T gives a regular tab. We target this view's window explicitly
    /// rather than tmux's "current window" because the app ignores tmux's remote
    /// focus (see `setFocus`), so tmux's active window can diverge from the selected
    /// tab. tmux emits `%window-add` and the reconcile builds the new tab; the
    /// index-driven `reorderTmuxTabsByIndex` then lands it right after the current
    /// tab. The controller flag makes that tab open AND get selected (remote focus
    /// is otherwise ignored).
    @MainActor
    func requestTmuxNewWindow() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return }
        controller.noteNewWindowRequest()
        sendTmuxCommand("new-window -a -t @\(binding.windowId)\n", to: binding.parentSurface)
    }

    /// Request a new tmux window from the GATEWAY view (the tab running tmux -CC),
    /// which has no pane binding. There's no specific window to anchor after, so we
    /// send `new-window -a` (tmux places it after its own current window); the
    /// controller's pending-select flag still makes the resulting tab open AND get
    /// selected, and `reorderTmuxTabsByIndex` lands it by index. Returns true when
    /// this view is a live gateway and the command was sent, so the caller can fall
    /// through to non-tmux handling when it isn't.
    @MainActor
    @discardableResult
    func requestTmuxNewWindowFromGateway() -> Bool {
        guard let surface, let controller = tmuxController, controller.isActive
        else { return false }
        controller.noteNewWindowRequest()
        sendTmuxCommand("new-window -a\n", to: surface)
        return true
    }

    /// Move a split boundary in tmux (a divider drag). Sets this pane's size on
    /// ONE axis via the single-axis `resize-pane -x`/`-y` form. That form is
    /// deliberately distinct from the two-axis per-pane echo the viewer drops:
    /// it is forwarded to tmux verbatim, so tmux actually moves the divider and
    /// the resulting `%layout-change` reconcile resizes the pane terminals (the
    /// content reflows). Send this ONCE on drag release — the involuntary
    /// per-pane resizes from the reconcile are dropped, so there is no loop.
    @MainActor
    func requestTmuxResizePane(horizontal: Bool, cells: Int) {
        guard let binding = tmuxPaneBinding, cells > 0 else { return }
        guard let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        let flag = horizontal ? "-x" : "-y"
        sendTmuxCommand("resize-pane -t %\(binding.paneId) \(flag) \(cells)\n", to: binding.parentSurface)
    }

    /// Toggle tmux's pane zoom for this pane's window. The layout round-trips
    /// via %layout-change; setLayout projects the zoomed pane into
    /// SplitTree.zoomed (id=tmux-zoom), so no local state changes here.
    @MainActor
    func requestTmuxToggleZoom() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("resize-pane -Z -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Swap this pane with another pane (usually a sibling in the same
    /// window). `-d` keeps tmux's active-pane mark where it is: the app
    /// ignores remote focus, but a moving active mark would still churn
    /// %window-pane-changed on every other attached client.
    @MainActor
    func requestTmuxSwapPane(withPaneId targetPaneId: Int) {
        guard let binding = tmuxPaneBinding,
              binding.paneId != targetPaneId,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("swap-pane -d -s %\(binding.paneId) -t %\(targetPaneId)\n", to: binding.parentSurface)
    }

    /// Break this pane out into its own window (appended at the first free
    /// index). Guarded on 2+ panes: tmux rejects breaking a sole pane, and a
    /// fire-and-forget failure would leave the armed select flag to capture
    /// an unrelated window. The %window-add reconcile builds the tab and the
    /// pending new-window request selects it — the same flow as new-window.
    @MainActor
    func requestTmuxBreakPane() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive,
              controller.paneCount(inWindow: binding.windowId) >= 2 else { return }
        controller.noteNewWindowRequest()
        sendTmuxCommand("break-pane -s %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Move this pane into another window of the same session. move-pane
    /// targets a PANE; a window-id target ("@N") resolves to that window's
    /// active pane, which is the "into window @N" semantic wanted here. No
    /// -h: tmux's default stacked placement matches split-window's default.
    /// Moving a window's SOLE pane is legal — tmux closes the source window
    /// (%window-close) and the prune removes its tab.
    @MainActor
    func requestTmuxMovePane(toWindowId targetWindowId: Int) {
        guard let binding = tmuxPaneBinding,
              binding.windowId != targetWindowId,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("move-pane -s %\(binding.paneId) -t @\(targetWindowId)\n", to: binding.parentSurface)
    }

    /// Set this pane's title (#{pane_title}). An empty title restores tmux's
    /// automatic pane title. The title feeds the #T tab-title subscription
    /// when this pane is the window's active one.
    @MainActor
    func requestTmuxRenamePane(title: String) {
        // Reject titles with embedded control characters (multi-line paste)
        // instead of letting quote() strip them into a different name. This
        // path is fire-and-forget, so reject = no-op. ROOTSHELL-TMUX (id=tmux-quote-c0)
        guard TmuxControlModeParser.isValidTmuxName(title) else { return }
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand(
            "select-pane -t %\(binding.paneId) -T \(TmuxControlModeParser.quote(title))\n",
            to: binding.parentSurface)
    }

    /// Clear this pane's scrollback history on the server.
    @MainActor
    func requestTmuxClearHistory() {
        guard let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        sendTmuxCommand("clear-history -t %\(binding.paneId)\n", to: binding.parentSurface)
    }

    /// Apply a per-surface font-size change and remember the absolute size so
    /// session restoration can rebuild this terminal with the same zoom. This
    /// is used only for non-tmux surfaces; tmux panes route through
    /// `applyTmuxWindowFontSize(delta:)` so all panes in one tmux window stay
    /// uniform.
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

    /// Reset this surface to follow the global font again. The Ghostty action
    /// performs the renderer-side reset; clearing `fontSizeOverride` makes the
    /// persisted state inherit future global font changes.
    @MainActor
    func resetLocalFontSize() {
        guard let surface, let ghosttyApp else { return }
        fontSizeOverride = nil
        ghosttyApp.resetFontSize(surface: surface)
    }

    /// Re-apply a restored absolute font override after the surface exists.
    /// New surfaces start at the current global font size, so the relative step
    /// is `override - currentGlobal`.
    @MainActor
    func applyRestoredFontSizeOverrideIfNeeded() {
        guard let target = fontSizeOverride else { return }
        let delta = Int((target - FontManager.shared.currentFontSize).rounded())
        guard delta != 0, let surface, let ghosttyApp else { return }
        ghosttyApp.changeFontSize(surface: surface, delta: delta)
    }

    /// Apply a font-size change in a tmux-control-mode-aware way. If this view is
    /// a pane of a live tmux session, route through the controller so EVERY pane
    /// of that ONE window changes together and the per-window font delta is
    /// tracked (panes in other windows are untouched), then return true. Returns
    /// false for non-tmux views, so the caller applies its per-surface change as
    /// before. Centralizes the routing used by every font-size entry point
    /// (keyboard, menu, keybind actions, pinch zoom).
    @MainActor
    func applyTmuxWindowFontSize(delta: Int) -> Bool {
        guard isTmuxPane, let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return false }
        controller.changeFontSize(windowId: binding.windowId, delta: delta)
        return true
    }

    /// tmux-aware font reset, mirroring `applyTmuxWindowFontSize`. Returns true
    /// when the reset was routed to this view's tmux window.
    @MainActor
    func resetTmuxWindowFontSize() -> Bool {
        guard isTmuxPane, let binding = tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive
        else { return false }
        controller.resetFontSize(windowId: binding.windowId)
        return true
    }

    /// Queue a raw, newline-terminated tmux command through the gateway viewer's
    /// command channel (FIFO-safe). The core copies the bytes.
    @MainActor
    private func sendTmuxCommand(_ cmd: String, to surface: ghostty_surface_t) {
        let data = Data(cmd.utf8)
        guard !data.isEmpty else { return }
        // Only ever touch the surface ABI when a LIVE, ACTIVE tmux gateway is
        // registered for it. A nil lookup means the gateway was torn down and
        // `surface` (a raw pointer captured in the pane binding) is dangling —
        // calling the C ABI then locks a freed mutex (SIGBUS). The previous
        // inverted check (`if let controller, !controller.isActive`) fell
        // THROUGH to the C call on a nil lookup, which is exactly the
        // use-after-free. ROOTSHELL-TMUX (id=tmux-send-stale-surface)
        //
        // `isActive` alone is NOT sufficient: a controller can outlive its owner
        // surface. Scene/window teardown frees the gateway surface on a
        // background queue while the gateway view's `cleanup()` leaves the
        // controller registered and `isActive` (it ends neither). Resolve the
        // gateway by pointer value through the weak surface->delegate registry
        // (cleared synchronously before the free, so it never yields a freed
        // object), THEN confirm identity by the gateway's stable `uuid`: the freed
        // address may have been reused by an unrelated surface (ABA), and routing
        // a tmux command to the wrong surface must not happen.
        //
        // Expected identity = this pane's saved gateway uuid; or, when the GATEWAY
        // view sends on its OWN surface (requestTmuxNewWindowFromGateway — no pane
        // binding), our own `uuid`. Without the `?? uuid` fallback the gateway
        // path would always fail this guard and silently drop the command.
        // (id=tmux-stale-parent-surface)
        let expectedGatewayUUID = tmuxPaneBinding?.parentUUID ?? uuid
        guard let controller = TmuxController.controller(forOwnerSurface: surface),
              controller.isActive,
              let gateway = ghosttyApp?.surfaceView(for: surface),
              gateway.uuid == expectedGatewayUUID else { return }
        // Log the VERB only (split-window / kill-pane / new-window / resize-pane)
        // plus the byte count — never the full command text (it carries pane ids
        // but future commands could carry titles/keys).
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

    /// The active tmux gateway view for this window IFF the gateway tab is the
    /// one currently selected/on-screen. Returns nil when a non-gateway tab is
    /// showing, so ESC inside a tmux pane still reaches the app running there.
    ///
    /// This deliberately keys off the *selected tab*, not first responder:
    /// switching to the gateway tab (e.g. tapping it in the tab bar) does not
    /// always move first responder onto the gateway view, so an ESC UIKeyCommand
    /// can be delivered to a background pane view instead. Looking up the
    /// selected gateway tab makes ESC-to-detach work whenever the user is looking
    /// at the gateway, regardless of which terminal view holds focus.
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

/// Transfers the (non-Sendable) reconcile data from the action callback's
/// thread to the main actor.
///
/// `owner` is a STRONG reference to the gateway `TerminalView`, taken on the
/// action-callback thread (while the surface, hence its userdata owner, is still
/// alive) and held across the async hop so closing the tab/surface before the
/// apply runs cannot free it out from under us. The Zig payload refcounts only
/// keep the viewer PANES alive; this keeps the Swift owner alive.
///
/// `payload` is the opaque `*TmuxReconcilePayload` the ops were decoded from. It
/// is carried (NOT freed at decode time) and freed with
/// `ghostty_tmux_reconcile_free` only AFTER `applyTmuxReconcile` runs: the
/// payload holds viewer-pane refcounts (Zig id=viewer-snapshot-refcount) that
/// keep the raw `viewerTerminal`/`viewerPane` pointers in `ops` alive until the
/// main-actor apply has consumed them.
struct TmuxReconcileDelivery: @unchecked Sendable {
    let owner: Ghostty.TerminalView
    let ops: [TmuxReconcileOp]
    let payload: UnsafeMutableRawPointer
}

/// Serializes tmux reconcile application in ARRIVAL order across the off-main
/// hop. Each `GHOSTTY_ACTION_TMUX_RECONCILE` is decoded in emit order on the
/// (serial) action-callback thread, but a bare `Task { @MainActor in ... }` per
/// batch has no cross-task ordering guarantee — so a stale full-topology snapshot
/// (each ends in pruneAbsent) could land AFTER a newer one and resurrect a closed
/// pane / stale layout until the next tmux event, most likely during the
/// post-resume Task storm. Links are appended in emit order and each awaits the
/// prior, so applies run strictly in order on the main actor. A finished Task
/// releases its closure, so the carried `TmuxReconcileDelivery` (and its strong
/// gateway-view ref + payload) is released as soon as each link's body completes;
/// the retained `tail` holds only a Void result. ROOTSHELL-TMUX
/// (id=tmux-reconcile-serialize)
final class TmuxReconcileSerializer: @unchecked Sendable {
    static let shared = TmuxReconcileSerializer()
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Append `work` to the serial apply chain. Safe to call off the main actor.
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
    /// Pushes a USER tab-reorder of a tmux window tab to the server with a
    /// single `move-window`, after the local array move has been applied.
    /// Call sites are the explicit reorder gestures only: top-bar drag drop,
    /// the Catalyst titlebar drag, Move Left/Right context menus, and the
    /// vertical tab sidebar drag.
    ///
    /// Multi-client loop safety (ROOTSHELL-TMUX id=tmux-window-reorder-server):
    /// - NEVER called from reconcile paths. `reorderTmuxTabsByIndex` (and
    ///   every other server-driven reorder) mutates the tabs array directly,
    ///   so another client's move can only change our UI, not echo a command.
    /// - No-ops when the moved tab's order RELATIVE TO ITS SIBLINGS matches
    ///   the server order (sorted `tmuxWindowIndex`, i.e. what the last
    ///   reconcile reported). The reconcile that confirms our own move makes
    ///   the orders match, so re-entry after the echo cannot re-send; drags
    ///   relative to non-tmux tabs only (no sibling change) send nothing.
    /// - At most ONE command per gesture, value-targeted at a sibling window
    ///   id, so two clients dragging concurrently just converge on whichever
    ///   move tmux applied last.
    @MainActor
    static func syncWindowOrderAfterUserMove(of tab: TabModel, in tabs: [TabModel]) {
        guard tab.isTmuxWindow, tab.tmuxWindowId != nil,
              let owner = tab.owningGatewayTerminalUUID else { return }

        // Live siblings of the same gateway, in current UI order. Restored
        // placeholders have no server window yet and are skipped.
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
