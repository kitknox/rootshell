//
//  TabsModel.swift
//  rootshell
//
//  Architectural replacement for `@State var terminals: [TerminalTab]` and the
//  value-type `TerminalTab` struct that used to live in `MainViewTypes.swift`.
//
//  Why this exists
//  ---------------
//  The previous design stored tabs as a value-type array under SwiftUI `@State`,
//  with each tab a struct that mirrored data from a class (`Ghostty.TerminalView`)
//  via Combine sinks (`setupTitleObservation`). Every per-tab title or
//  connection-health update mutated the `@State` array, which invalidated all
//  of `MainView`'s body — including the tab bar, the terminal area, modal
//  sheets, etc. Combined with on-screen-keyboard publisher churn during
//  background→foreground transitions on iPhone, this contributed to the
//  0x8BADF00D scene-update watchdog kills the team has been patching one
//  hot path at a time.
//
//  With `@Observable`, SwiftUI tracks per-property reads inside view bodies.
//  By making each tab a class (`TabModel`) annotated `@Observable`, only the
//  views that actually read `tab.resolvedTitle` for *that specific tab* are
//  invalidated when its title changes — sibling tabs and the surrounding
//  chrome no longer recompute.
//
//  Lifecycle
//  ---------
//  - `TabModel.startObserving()` is invoked when a tab is added to a
//    `TabsModel`, or when its focused split changes. It Combine-subscribes to
//    the focused `Ghostty.TerminalView`'s `$title` and `$connectionHealth`
//    publishers and writes the resolved values into its own `@Observable`
//    properties.
//  - `TabModel.stopObserving()` is invoked when removed (and from `deinit`).
//

import Foundation
import Combine
import SwiftUI
import GhosttyKit
import os
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tab Grouping

nonisolated struct TabGroupID: Hashable, Codable, Sendable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        case local
        case remoteHost
        case remoteDomain
        case remoteNetwork
        case tmux
        case other
    }

    let kind: Kind
    let value: String

    var id: String { rawValue }

    var rawValue: String {
        switch kind {
        case .local: return "local"
        case .remoteHost: return "host:\(value)"
        case .remoteDomain: return "domain:\(value)"
        case .remoteNetwork: return "network:\(value)"
        case .tmux: return "tmux:\(value)"
        case .other: return "other:\(value)"
        }
    }

    static let local = TabGroupID(kind: .local, value: "local")

    static func remoteHost(_ host: String) -> TabGroupID {
        TabGroupID(kind: .remoteHost, value: normalizeHost(host))
    }

    static func remoteDomain(_ domain: String) -> TabGroupID {
        TabGroupID(kind: .remoteDomain, value: normalizeHost(domain))
    }

    static func remoteNetwork(_ network: String) -> TabGroupID {
        TabGroupID(kind: .remoteNetwork, value: network.lowercased())
    }

    static func tmux(ownerID: UUID) -> TabGroupID {
        TabGroupID(kind: .tmux, value: ownerID.uuidString.lowercased())
    }

    static func other(_ value: String) -> TabGroupID {
        TabGroupID(kind: .other, value: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The gateway terminal UUID backing a `.tmux` group (nil for other kinds).
    /// Lets a gateway move recover the owner id from the group id.
    var tmuxOwnerID: UUID? {
        kind == .tmux ? UUID(uuidString: value) : nil
    }

    var title: String {
        switch kind {
        case .local:
            return String(localized: "Local Shell", comment: "Tab group title for local terminals")
        case .remoteHost, .remoteDomain, .remoteNetwork:
            return value
        case .tmux:
            return "tmux"
        case .other:
            return value.isEmpty ? String(localized: "Other", comment: "Tab group title for uncategorized terminals") : value
        }
    }

    static func normalizeHost(_ host: String) -> String {
        let trimmed = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast()).lowercased()
        }
        return trimmed.lowercased()
    }

    static func registrableDomain(for host: String) -> String? {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty,
              !normalized.hasSuffix(".local"),
              !normalized.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }),
              !normalized.contains(":") else { return nil }
        let parts = normalized.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        return parts.suffix(2).joined(separator: ".")
    }

    static func ipNetworkGroup(for host: String) -> String? {
        let normalized = normalizeHost(host)
        if let ipv4 = ipv4NetworkGroup(for: normalized) {
            return ipv4
        }
        return ipv6NetworkGroup(for: normalized)
    }

    private static func ipv4NetworkGroup(for host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return nil }
            octets.append(value)
        }
        return "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
    }

    private static func ipv6NetworkGroup(for host: String) -> String? {
        #if canImport(Darwin)
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count >= 8 else { return nil }
        var groups: [String] = []
        for index in stride(from: 0, to: 8, by: 2) {
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            groups.append(String(value, radix: 16))
        }
        return groups.joined(separator: ":") + "::/64"
        #else
        return nil
        #endif
    }
}

struct TabGroup: Identifiable, Hashable {
    let id: TabGroupID
    let title: String
    let tabIDs: [UUID]
}

/// Stable identity for a Coding Agent project section. The display label is
/// deliberately not part of the identity: two repositories named "api" on
/// different hosts/paths must remain separate, while a better probe may refine
/// how the same section is presented without merging it with a namesake.
nonisolated struct ProjectGroupID: Hashable, Codable, Sendable, Identifiable {
    let hostKey: String
    let path: String

    var id: String { rawValue }
    var rawValue: String { "\(hostKey)\u{1f}\(path)" }

    static let other = ProjectGroupID(hostKey: "", path: "")

    var isOther: Bool { self == .other }

    init(hostKey: String?, path: String) {
        self.hostKey = hostKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.path = AgentProjectPath.normalize(path)
    }
}

nonisolated struct ProjectTabSection: Identifiable, Hashable, Sendable {
    let id: ProjectGroupID
    let title: String
    /// Every tab has exactly one primary section, so section membership stays
    /// duplicate-free and the active section can safely drive navigation.
    let tabIDs: [UUID]
}

nonisolated enum TabOrderMode: Equatable, Sendable {
    case flat
    case userGrouped(TabGroupID?)
    case projectGrouped
}

nonisolated struct TabOrderProjection: Equatable, Sendable {
    let mode: TabOrderMode
    let navigationTabIDs: [UUID]
    let projectSections: [ProjectTabSection]
    let activeProjectID: ProjectGroupID?
    let activeScopeTitle: String?

    var indexByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: navigationTabIDs.enumerated().map { ($0.element, $0.offset) })
    }
}

// MARK: - TabModel

/// A single tab in a window, replacing the value-type `MainView.TerminalTab`
/// struct. As an `@Observable` class, per-tab UI (tab buttons, indicators)
/// reads its properties directly and is invalidated only on changes to the
/// properties it actually reads.
@MainActor
@Observable
final class TabModel: Identifiable {
    /// Stable identity for `ForEach` and reorder/cleanup operations.
    let id = UUID()
    let paneMove = PaneMoveState()
    /// Prevent a delayed move reply from overriding a newer focus choice.
    @ObservationIgnored private(set) var paneFocusRevision: UInt64 = 0

    /// The window this tab belongs to. Used for window-aware drag and per-window
    /// theme override resolution.
    var windowId: String

    /// True when this tab hosts the `tmux -CC` control-mode gateway surface
    /// (the tab control mode was launched from). The tab stays visible and
    /// navigable like any other — control mode does NOT hide it (matching
    /// iTerm2); the tmux windows simply appear as additional tabs. This flag
    /// just identifies the gateway tab, e.g. so `TmuxController` can reselect it
    /// when control mode ends (%exit). Set by `TmuxController` on reconcile.
    var isTmuxGateway: Bool = false {
        didSet { markGroupingChanged(oldValue, isTmuxGateway) }
    }

    /// The tmux session this gateway tab's control client is attached to.
    /// Mirrors `TmuxController.currentSessionName` (set by
    /// `updateCurrentSession` on attach / switch / rename) because the
    /// controller is a plain class, so a SwiftUI view reading it directly
    /// never re-renders on a rename. Nil for ordinary tabs.
    var tmuxSessionName: String? {
        didSet { markGroupingChanged(oldValue, tmuxSessionName) }
    }

    /// True when this tab is a projected tmux control-mode *window* tab
    /// (created by `TmuxController.ensureWindow`). Drives the green "T" tab
    /// badge. Distinct from `isTmuxGateway`, which marks the host tab that
    /// launched `tmux -CC` and is intentionally NOT badged.
    var isTmuxWindow: Bool = false {
        didSet { markGroupingChanged(oldValue, isTmuxWindow) }
    }

    /// The tmux window id this tab models, once known (set by
    /// `TmuxController.ensureWindow` or on placeholder adoption). Persisted so a
    /// projected window tab can be restored as a placeholder and re-matched to
    /// its tmux window after the gateway resumes. Nil for ordinary tabs.
    var tmuxWindowId: Int? {
        didSet { markGroupingChanged(oldValue, tmuxWindowId) }
    }

    /// The UUID of the gateway terminal (the one running `tmux -CC`) that owns
    /// this window tab. Stamped by `TmuxController.ensureWindow`. Stable across
    /// restore (unlike the tab UUID), so the controller adopts restored
    /// placeholders for its own gateway by matching this against its owner
    /// terminal's UUID. Nil for ordinary tabs.
    var owningGatewayTerminalUUID: UUID? {
        didSet { markGroupingChanged(oldValue, owningGatewayTerminalUUID) }
    }

    /// True for a tmux window tab restored from disk as a PLACEHOLDER: it has no
    /// live panes yet (the split tree is empty) and is shown with its last title
    /// and a "reconnecting tmux…" affordance. The first reconcile after the
    /// gateway resumes ADOPTS the placeholder (fills it with live panes and
    /// clears this flag). A placeholder still awaiting when the resume watchdog
    /// fires is removed (its tmux window is gone / the session expired).
    var awaitingTmuxReconcile: Bool = false

    /// The tmux window id a restored placeholder is waiting to be matched to.
    /// Set alongside `awaitingTmuxReconcile`; cleared on adoption.
    var pendingTmuxWindowId: Int?

    /// The tmux window display index (from `#{window_index}`), used to order this
    /// gateway's tmux tabs so new-window -a / move-window / swap-window are
    /// reflected. Only meaningful when `isTmuxWindow`. (id=tmux-window-order)
    var tmuxWindowIndex: Int = 0

    /// Rolled-up attention state of this tab's panes (agent blocked/done/
    /// working/failed), published by AgentAttentionCenter; nil when there
    /// is nothing to show. Deliberately NOT grouping-relevant (no
    /// `markGroupingChanged`): it changes often and must never invalidate
    /// the grouping cache. (id=agent-attention)
    var attentionBadge: AgentAttentionStatus?

    /// Card row state for the sidebar's agent inbox (the tab's highest-
    /// priority detected agent), published by AgentAttentionCenter; nil
    /// when no agent is detected. Same grouping rule as `attentionBadge`.
    /// (id=agent-attention)
    var agentRow: AgentRowState?

    /// Agent-bearing terminal panes in split-tree order. Unlike `agentRow`,
    /// this preserves every independently detected agent in a split tab.
    /// Structural consumers (the sidebar hierarchy) observe this compact ID
    /// list; each row observes its own pane's `PanePresentationState`.
    var agentPaneIDs: [UUID] = []

    /// True when this tmux window tab is HIDDEN: the window lives on the
    /// server (and reconcile keeps updating the tab — title, layout, panes at
    /// opacity 0), but the tab strip, sidebar, and tab navigation all skip
    /// it. Set exclusively by `TmuxController` (hide/show actions, the
    /// session's `@hidden` option on attach). Meaningful when `isTmuxWindow`,
    /// and also on a gateway tab (`isTmuxGateway`) the user hid — gateway
    /// hidden state is client-local and never enters the server's `@hidden`
    /// option. (id=tmux-hidden-windows, id=tmux-hidden-gateway)
    var isHiddenTmuxWindow: Bool = false {
        didSet { markGroupingChanged(oldValue, isHiddenTmuxWindow) }
    }

    /// Set at restore when the saved state had a HIDDEN gateway tab; consumed
    /// by `TmuxController.markGatewayTab` after the first successful reconcile
    /// post-resume. Never applied to `isHiddenTmuxWindow` directly at restore —
    /// a hidden tab whose tmux resume fails would be unreachable.
    /// (id=tmux-hidden-gateway)
    @ObservationIgnored var pendingHiddenTmuxGatewayRestore: Bool = false

    /// Absolute per-window font size override for projected tmux window tabs.
    /// Nil means the tmux window follows the global font.
    var tmuxFontSizeOverride: Double?

    /// The split tree of pane views inside this tab. Mutated when the user
    /// splits or closes a split. We track changes via the @Observable accessor;
    /// downstream views that iterate the tree re-render as needed.
    var splitTree: SplitTree<SplitPaneView> {
        didSet {
            AgentAttentionCenter.shared.topologyDidChange()
        }
    }

    /// The currently focused pane inside this tab. Setting this rewires the
    /// title/health observation onto the new focused view.
    var focusedPane: SplitPaneView? {
        didSet {
            guard oldValue !== focusedPane else { return }
            paneFocusRevision &+= 1
            groupingRevision &+= 1
            startObserving()
            AgentAttentionCenter.shared.visibilityDidChange()
        }
    }

    /// Terminal-typed view of `focusedPane`. Kept as a shim so the many
    /// terminal-only call sites read/write focus with correct semantics:
    /// reads are nil when a non-terminal pane holds focus.
    var focusedTerminal: Ghostty.TerminalView? {
        get { focusedPane as? Ghostty.TerminalView }
        set { focusedPane = newValue }
    }

    /// Connection info for the Connection Info sheet: the focused VNC pane's,
    /// else the focused terminal session's. A tmux window tab has no session
    /// of its own (its panes ride the gateway's control connection), so it
    /// resolves to the linked gateway terminal's session.
    var connectionInfo: ConnectionInfo? {
        if let info = (focusedPane as? VNCPaneView)?.connectionInfo {
            return info
        }
        if let info = focusedTerminal?.session?.connectionInfo {
            return info
        }
        if isTmuxWindow, let owner = owningGatewayTerminalUUID {
            return TmuxWindowRegistry.gatewayView(ownerTerminalUUID: owner)?.session?.connectionInfo
        }
        return nil
    }

    // MARK: - Mirrored State (driven by the focused terminal's @Published properties)

    /// Resolved tab title — either the focused split's session-provided title
    /// or, when that title is empty/"ghostty", the connection's display name.
    /// Only observers of *this tab's* title invalidate when it changes
    /// (the @Observable macro tracks per-property reads).
    var title: String = "Terminal"

    /// SSH connection health for the focused split (nil for non-SSH or pre-connect).
    var connectionHealth: ConnectionHealth?

    /// Cached roam-protocol classification for tab-bar indicators. Recomputed
    /// when the focused terminal changes; downstream views that need to respond
    /// to embedded mosh/trzsz session-change notifications should call
    /// `recomputeRoamProtocol()` explicitly.
    private(set) var activeRoamProtocol: MainView.RoamProtocol = .none

    /// Backwards-compat with old `TerminalTab.hasActiveMoshSession`.
    var hasActiveMoshSession: Bool { activeRoamProtocol == .mosh }

    // MARK: - Internal observation storage

    /// Combine subscriptions on the focused terminal's @Published properties.
    /// Excluded from observation — these are implementation detail.
    @ObservationIgnored private var observationCancellables = Set<AnyCancellable>()
    private(set) var groupingRevision = 0

    /// Owning collection, read only to consult the tab-switch animation gate.
    /// Weak (TabsModel strongly holds its tabs); stamped by TabsModel.tabs.didSet.
    @ObservationIgnored weak var tabsModel: TabsModel?

    /// Latest resolved title received while the tab-switch gate was up, pending
    /// flush. Coalesced — only the most recent is kept.
    @ObservationIgnored private var deferredTitle: String?

    /// High-rate OSC/tmux titles are presentation data, but `title` is an
    /// observed property consumed by the window, top tabs, and sidebar. A
    /// tmux agent spinner can otherwise invalidate that entire graph about ten
    /// times per second. Preserve a responsive leading update and the newest
    /// trailing value while limiting observed publication to 5 Hz. Codex and
    /// Claude commonly animate their title spinners at about 10 Hz; publishing
    /// every other frame keeps that motion legible without making SwiftUI
    /// process every source update.
    @ObservationIgnored private var pendingPublishedTitle: String?
    @ObservationIgnored private var titlePublicationTimer: Timer?
    @ObservationIgnored private var lastTitlePublicationUptime: TimeInterval = 0
    private static let minimumTitlePublicationInterval: TimeInterval = 0.2

    private func markGroupingChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        if oldValue != newValue {
            groupingRevision &+= 1
        }
    }

    func markGroupingInputsChanged() {
        groupingRevision &+= 1
    }

    // MARK: - Initialization

    init(paneView: SplitPaneView?, title: String = "Terminal", windowId: String) {
        self.windowId = windowId
        self.title = title

        if let paneView {
            self.splitTree = SplitTree(view: paneView)
            self.focusedPane = paneView
        } else {
            self.splitTree = SplitTree()
            self.focusedPane = nil
        }

        // `focusedPane`'s `didSet` doesn't fire from initializers in Swift,
        // so kick off observation explicitly.
        startObserving()
    }

    convenience init(terminalView: Ghostty.TerminalView? = nil, title: String = "Terminal", windowId: String, isMosh: Bool = false) {
        // `isMosh` parameter is ignored (kept for source compat with the old
        // `TerminalTab(...)` struct initializer; roam protocol is now computed).
        _ = isMosh
        self.init(paneView: terminalView, title: title, windowId: windowId)
    }

    /// Initializer for restoration paths that build the tab incrementally
    /// (focused terminal and split tree set later by the restoration code).
    convenience init(windowId: String) {
        self.init(terminalView: nil, title: "Terminal", windowId: windowId)
    }

    /// Initializer used by session restoration. Wires up the split tree,
    /// focused pane, and saved title, then starts observation with
    /// `preserveExistingTitle: true` so the focused split's pre-connect
    /// "ghostty" title doesn't overwrite the saved one. The order of
    /// assignments matters — see the comment in the body.
    init(restoringTitle title: String,
         splitTree: SplitTree<SplitPaneView>,
         focusedPane: SplitPaneView?,
         windowId: String) {
        self.windowId = windowId
        self.splitTree = splitTree
        // Setting `focusedPane` here fires its @Observable-backed didSet
        // (unlike plain stored properties, @Observable property observers DO
        // fire during init). That didSet calls `startObserving()` with the
        // default `preserveExistingTitle: false`, which would clobber the
        // saved title with the connection's `displayName`. Set focusedPane
        // first, then overwrite with the saved title, then re-run observation
        // with `preserveExistingTitle: true` so the dropFirst()'d title sink
        // doesn't push a fallback emission over the saved value.
        self.focusedPane = focusedPane
        self.title = title
        startObserving(preserveExistingTitle: true)
    }

    // MARK: - Notification-driven roam-protocol refresh

    /// Subscribe to the embedded mosh / trzsz / ghostty session-change
    /// notifications and recompute `activeRoamProtocol` when one of *this
    /// tab's* terminals reports a change. Called automatically from
    /// `startObserving()`. Without this, a TSSH or embedded-mosh session
    /// that starts inside an already-running terminal doesn't update the
    /// tab-bar "R" indicator (the cached `activeRoamProtocol` stays stale
    /// because no `focusedTerminal` change triggers a recompute).
    private func subscribeToRoamProtocolNotifications() {
        let center = NotificationCenter.default
        for name in [
            Notification.Name.ghosttyEmbeddedMoshSessionDidChange,
            Notification.Name.ghosttyEmbeddedTrzszSessionDidChange,
            Notification.Name.ghosttySessionDidChange,
        ] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self else { return }
                    // Only recompute when the notification originated from one
                    // of this tab's terminals or its session, so a session
                    // change in a sibling tab doesn't churn this tab.
                    if self.notificationOriginatesInThisTab(notification) {
                        self.recomputeRoamProtocol()
                    }
                }
                .store(in: &observationCancellables)
        }
    }

    private func notificationOriginatesInThisTab(_ notification: Notification) -> Bool {
        // The TerminalView (Ghostty.Surface) is the object for `.ghosttySessionDidChange`.
        if let terminal = notification.object as? Ghostty.TerminalView {
            return splitTree.contains { $0 === terminal }
        }
        #if !targetEnvironment(macCatalyst)
        // For `.ghosttyEmbedded(Mosh|Trzsz)SessionDidChange` the object is the
        // `LocalShellSession` itself; walk the tree to find the owning terminal.
        // Embedded mosh/trzsz only run inside the iOS local-shell session, so
        // this branch is gated to the same target as `LocalShellSession`.
        if let session = notification.object as? LocalShellSession {
            return splitTree.contains { $0.asTerminal?.session === session }
        }
        #endif
        return false
    }

    deinit {
        // Cancel Combine subscriptions on deinit. `MainActor.assumeIsolated`
        // is safe here because the class is `@MainActor`-isolated and Swift
        // 6 deinit on a MainActor class runs on the main actor.
        observationCancellables.removeAll()
        titlePublicationTimer?.invalidate()
    }

    // MARK: - Observation

    /// Subscribe to the current `focusedTerminal`'s `@Published` properties and
    /// mirror them into this model's `@Observable` properties. Replaces the
    /// `setupTitleObservation` Combine wiring that previously lived inline in
    /// `MainView` and pushed values into a `@State` array.
    /// Set up observation of the focused terminal's `@Published` properties.
    ///
    /// Pass `preserveExistingTitle: true` during restoration so the saved tab
    /// title isn't immediately overwritten by the focused view's pre-connect
    /// title (typically "ghostty").
    func startObserving(preserveExistingTitle: Bool = false) {
        observationCancellables.removeAll()
        cancelPendingTitlePublication()

        // Resolve the focused pane first (not the terminal shim) so a focused
        // non-terminal pane isn't silently skipped in favor of a background
        // terminal.
        guard let pane = focusedPane ?? splitTree.first else {
            if title != "Terminal" {
                title = "Terminal"
            }
            recomputeRoamProtocol()
            return
        }
        guard let focusedTerminal = pane.asTerminal else {
            // Non-terminal pane: no terminal title/health publishers to
            // mirror. VNC panes publish their own display title (config name
            // upgrading to the server-reported desktop name); other pane
            // kinds keep the current title. Still track roam protocol across
            // the tab's terminals.
            if let vncPane = pane as? VNCPaneView {
                let titlePublisher = preserveExistingTitle
                    ? vncPane.$displayTitle.dropFirst().eraseToAnyPublisher()
                    : vncPane.$displayTitle.eraseToAnyPublisher()
                titlePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] newTitle in
                        guard let self, self.title != newTitle else { return }
                        self.applyResolvedTitle(newTitle)
                    }
                    .store(in: &observationCancellables)
            }
            subscribeToRoamProtocolNotifications()
            recomputeRoamProtocol()
            return
        }
        // Initial title push — same fallback logic the old setupTitleObservation
        // used, factored into `resolveTitle(rawTitle:on:)`.
        //
        // NOT for tmux window tabs: their title is owned by the reconcile's
        // set_tab_title op (the gateway's title subscription, which resolves
        // pane title vs window name server-side). The focused PANE also
        // receives OSC titles directly, and letting it write here would stomp
        // a manually renamed window's name with the pane title.
        // (id=tmux-window-title-single-writer)
        if !preserveExistingTitle,
           !isTmuxWindow,
           let resolved = Self.resolveTitle(rawTitle: focusedTerminal.title, on: focusedTerminal),
           title != resolved {
            title = resolved
        }

        // Title subscription. Equality guard before assignment — the focused
        // view emits on every OSC 0/2 even when the resolved title is unchanged.
        //
        // During restoration the saved tab title must survive until the live
        // session emits a *real* (non-fallback) title. Pre-connect surface
        // SET_TITLE actions emit "ghostty" or "", which would otherwise
        // resolve to the connection's `displayName` via `resolveTitle` and
        // overwrite the saved title. Gate the sink on "have we ever received
        // a real title?" — for restored tabs, fallback emissions are dropped
        // until a real OSC title arrives.
        var hasReceivedRealTitle = !preserveExistingTitle
        let titlePublisher: AnyPublisher<String, Never> = preserveExistingTitle
            ? focusedTerminal.$title.dropFirst().eraseToAnyPublisher()
            : focusedTerminal.$title.eraseToAnyPublisher()
        titlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak focusedTerminal] newTitle in
                guard let self, let focusedTerminal else { return }
                // tmux window tabs: reconcile is the sole title writer.
                // (id=tmux-window-title-single-writer)
                if self.isTmuxWindow { return }
                if !hasReceivedRealTitle {
                    if Self.shouldUseFallbackTitle(newTitle) {
                        return
                    }
                    hasReceivedRealTitle = true
                }
                guard let resolved = Self.resolveTitle(rawTitle: newTitle, on: focusedTerminal)
                else { return }
                self.applyResolvedTitle(resolved)
            }
            .store(in: &observationCancellables)

        // Connection-health subscription (SSH only). Equality guard.
        focusedTerminal.$connectionHealth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] health in
                guard let self else { return }
                if self.connectionHealth != health {
                    self.connectionHealth = health
                }
            }
            .store(in: &observationCancellables)

        // Listen for embedded-mosh / embedded-trzsz / session-change events on
        // any terminal in this tab so the cached `activeRoamProtocol` stays
        // current when a TSSH or mosh wrapper starts inside a running shell.
        subscribeToRoamProtocolNotifications()

        recomputeRoamProtocol()
    }

    func stopObserving() {
        observationCancellables.removeAll()
        cancelPendingTitlePublication()
    }

    /// Apply a resolved tab title. During a tab-switch animation the write is
    /// deferred (coalesced to the latest value) and flushed on gate-close, so
    /// high-rate OSC/tmux title churn can't starve the selection spring with
    /// TabBarItem re-renders. Outside the animation, publication is
    /// leading-and-trailing coalesced so frequently animated titles stay live
    /// without driving the whole SwiftUI graph at spinner frequency.
    func applyResolvedTitle(_ resolved: String) {
        // An empty title means "no update", never "blank the tab". For tmux
        // window tabs the reconcile is the sole title writer, so a blank that
        // lands here is permanent until the next topology rebuild — the Zig
        // snapshot deliberately sends "" for a title it can't validate.
        guard !resolved.isEmpty else { return }
        if tabsModel?.isTabSwitchAnimating == true {
            deferredTitle = resolved
            return
        }
        deferredTitle = nil
        scheduleTitlePublication(resolved)
    }

    /// Flush the most recent title deferred during the animation. Called from
    /// `TabsModel.endTabSwitchAnimationGate` over every tab.
    func flushDeferredTitle() {
        guard let pending = deferredTitle else { return }
        deferredTitle = nil
        scheduleTitlePublication(pending)
    }

    private func scheduleTitlePublication(_ resolved: String) {
        guard title != resolved || pendingPublishedTitle != nil else { return }
        pendingPublishedTitle = resolved

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTitlePublicationUptime
        if lastTitlePublicationUptime == 0 || elapsed >= Self.minimumTitlePublicationInterval {
            publishPendingTitle()
            return
        }

        guard titlePublicationTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.minimumTitlePublicationInterval - elapsed,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishPendingTitle()
            }
        }
        titlePublicationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func publishPendingTitle() {
        titlePublicationTimer?.invalidate()
        titlePublicationTimer = nil
        guard let pending = pendingPublishedTitle else { return }
        pendingPublishedTitle = nil
        lastTitlePublicationUptime = ProcessInfo.processInfo.systemUptime
        let signpost = TmuxPipelineSignposts.begin("tab.title.publish")
        defer { TmuxPipelineSignposts.end("tab.title.publish", signpost) }
        if title != pending { title = pending }
    }

    /// Drop titles captured from the previously observed pane. In particular,
    /// a coalescing timer must not be allowed to overwrite the synchronous
    /// initial title installed by `startObserving()` for a newly focused pane.
    private func cancelPendingTitlePublication() {
        titlePublicationTimer?.invalidate()
        titlePublicationTimer = nil
        pendingPublishedTitle = nil
        deferredTitle = nil
        lastTitlePublicationUptime = 0
    }

    /// Recompute `activeRoamProtocol` from the current split tree's session
    /// types. Called when the focused terminal changes; tab-bar consumers can
    /// also invoke it after embedded mosh/trzsz session-change notifications.
    func recomputeRoamProtocol() {
        let computed = Self.computeRoamProtocol(in: splitTree)
        if activeRoamProtocol != computed {
            activeRoamProtocol = computed
        }
    }

    // MARK: - Title resolution (mirrors the old `MainView.resolvedTabTitle`)

    /// Returns the tab title to display for a focused terminal given its raw
    /// title. Returns nil for the `.local` fallback case where the existing
    /// tab title should be preserved (we don't overwrite a custom title with
    /// "ghostty" or "").
    static func resolveTitle(rawTitle: String, on terminal: Ghostty.TerminalView) -> String? {
        if !shouldUseFallbackTitle(rawTitle) { return rawTitle }
        switch terminal.connectionConfig {
        case .ssh(let config): return config.displayName
        case .mosh(let config): return config.sshConfig.displayName
        case .trzsz(let config): return config.sshConfig.displayName
        case .kubernetes(let config): return config.displayName
        case .console(let config): return config.displayName
        case .ec2Console(let config): return config.displayName
        case .local: return nil  // preserve existing
        case .shellLaunchedSSH(let sshConfig, _): return sshConfig.displayName
        case .shellLaunchedMosh(let moshConfig, _): return moshConfig.sshConfig.displayName
        case .shellLaunchedTrzsz(let trzszConfig, _): return trzszConfig.sshConfig.displayName
        case .trzszTransfer(_, let displayName, _): return displayName
        // VNC sessions live in non-terminal panes; a terminal never carries
        // this config, but the switch must stay exhaustive.
        case .vnc(let config): return config.displayName
        }
    }

    static func shouldUseFallbackTitle(_ title: String) -> Bool {
        return title.isEmpty || title == "ghostty"
    }

    /// Compute the active roam protocol (mosh/trzsz/none) for a split tree.
    /// Mirrors the logic that previously lived on `TerminalTab.activeRoamProtocol`.
    static func computeRoamProtocol(in splitTree: SplitTree<SplitPaneView>) -> MainView.RoamProtocol {
        for terminal in splitTree.terminalLeaves {
            if let moshSession = terminal.session as? MoshSession, moshSession.isRunning {
                return .mosh
            }
            if let trzszSession = terminal.session as? TrzszSession, trzszSession.isRunning {
                return .trzsz
            }
            #if !targetEnvironment(macCatalyst)
            if let localSession = terminal.session as? LocalShellSession {
                if localSession.embeddedMoshSession != nil {
                    return .mosh
                }
                if localSession.embeddedTrzszSession != nil {
                    return .trzsz
                }
            }
            #endif
        }
        return .none
    }

    /// Allow callers to force a fallback title (used during restoration when
    /// the saved tab title should be displayed until the session reconnects).
    func setFallbackTitle(_ newTitle: String) {
        if title != newTitle {
            title = newTitle
        }
    }

    func retargetWindow(to newWindowId: String, isWindowFocused: Bool) {
        guard windowId != newWindowId else { return }
        windowId = newWindowId
        for terminal in splitTree {
            terminal.retargetWindow(to: newWindowId)
            terminal.setWindowActive(isWindowFocused)
            terminal.containingTabID = id
        }
        markGroupingInputsChanged()
    }
}

// MARK: - TabsModel

/// The collection of tabs in a window, plus selection and drag state.
///
/// As an `@Observable` class, mutations to `tabs` (insert/remove/move) and to
/// `selectedTabID` are tracked per-property: the tab bar reading `tabs.tabs`
/// and `tabs.selectedTabID` re-renders only on those changes; views reading
/// individual `TabModel` properties re-render only on those.
@MainActor
@Observable
final class TabsModel {
    @ObservationIgnored private(set) var selectionRevision: UInt64 = 0
    /// All tabs in the window, in display order.
    var tabs: [TabModel] = [] {
        didSet {
            invalidateGroupingCache()
            // Stamp the back-reference so each tab can consult the tab-switch
            // gate. Idempotent; the array is tiny.
            for tab in tabs { tab.tabsModel = self }
            let liveIDs = Set(tabs.map(\.id))
            primaryProjectAssignments = primaryProjectAssignments.filter { liveIDs.contains($0.key) }
            AgentAttentionCenter.shared.topologyDidChange()
        }
    }

    /// The currently-selected tab's identity. `nil` only when `tabs` is empty.
    /// Every selection mutation in the codebase goes through this property
    /// (the `selectedTabIndex` shim, tab bar, TmuxController, restoration),
    /// so its `didSet` is the single funnel for the displayed-tab reveal.
    var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            selectionRevision &+= 1
            beginTabSwitchAnimationGate()
            if let tab = selectedTab { rememberSelectionScope(of: tab) }
            if isGroupedModeEnabled, !isProjectGroupingActive,
               let selectedGroup = effectiveGroupID(for: selectedTab),
               activeGroupID != selectedGroup {
                activeGroupID = selectedGroup
            }
            syncDisplayedTab()
            AgentAttentionCenter.shared.visibilityDidChange()
        }
    }

    /// Last selected tab per group / project (see `rememberSelectionScope`).
    @ObservationIgnored private var lastSelectedTabByScope: [ScopeKey: UUID] = [:]

    /// The tab whose content is shown at full opacity. Lags `selectedTabID`
    /// until every terminal in the target tab has presented its first frame,
    /// so a tab swap never exposes the translucent window background (the
    /// renderer's layer is empty until its first present, which on macOS
    /// shows straight through to the desktop). Focus, input, and occlusion
    /// follow `selectedTabID` immediately; only the visuals lag.
    var displayedTabID: UUID?

    /// Pane currently checked out for the in-window full-screen takeover
    /// (PaneFullScreenController). Runtime-only bookkeeping, never
    /// serialized, so restoration always lands non-full-screen.
    var fullScreenPaneID: UUID?

    /// Invalidates in-flight reveal waiters (first-frame callbacks and the
    /// fail-open timeout) when the selection changes again mid-transition.
    @ObservationIgnored private var displayRevealGeneration = 0

    /// True while a tab-switch selection animation is settling. Per-tab title
    /// writers (`TabModel.applyResolvedTitle`) read this imperatively and DEFER
    /// their @Observable `title` write while it's up, so OSC/tmux title churn
    /// can't starve the selection spring with TabBarItem re-renders. A
    /// coordination flag only — never observed for UI, so `@ObservationIgnored`
    /// (its flip must not itself invalidate anything).
    @ObservationIgnored private(set) var isTabSwitchAnimating = false
    @ObservationIgnored private var tabSwitchAnimationTimer: Timer?

    /// The id of the tab being dragged (used by drag-reorder modifiers).
    var draggingTabID: UUID?

    /// Set by the sidebar while its project hierarchy is active. Project
    /// sorting remains a sidebar-only organization in flat mode; when the
    /// user's grouped-mode toggle is also on, the top bar and keyboard
    /// navigation scope to the selected tab's stable primary project.
    /// (id=agent-project)
    var projectScopedInboxEnabled: Bool = AgentAttentionSettings.projectGroupingSelected {
        didSet {
            guard oldValue != projectScopedInboxEnabled else { return }
            invalidateNavigationCache()
            // On return to a user-group view, keep the selected tab visible by
            // making its group active. Remembered user/project orders remain
            // independent and untouched.
            if !projectScopedInboxEnabled, isGroupedModeEnabled,
               let selectedGroup = effectiveGroupID(for: selectedTab) {
                activeGroupID = selectedGroup
            }
        }
    }

    var isGroupedModeEnabled: Bool = false {
        didSet {
            guard oldValue != isGroupedModeEnabled else { return }
            invalidateNavigationCache()
            // Entering grouped mode: the currently-active tab wins. Adopt its
            // group so the user stays on the same tab instead of being pulled
            // into a stale (persisted) `activeGroupID`'s group.
            if isGroupedModeEnabled, let selectedGroup = effectiveGroupID(for: selectedTab) {
                activeGroupID = selectedGroup
            }
            normalizeGroupingSelection()
        }
    }

    /// The currently active navigation group in grouped mode.
    var activeGroupID: TabGroupID? {
        didSet {
            guard oldValue != activeGroupID else { return }
            invalidateNavigationCache()
            normalizeGroupingSelection()
        }
    }

    /// User-forced group assignment by tab UUID. The value is a concrete group
    /// id from `availableGroups`; stale ids are ignored by effective grouping.
    var tabGroupOverrides: [UUID: TabGroupID] = [:] {
        didSet { invalidateGroupingCache() }
    }

    /// User-defined vertical sidebar section order, stored as group raw values.
    /// Stale entries are harmless: the sidebar applies only IDs that currently
    /// exist and keeps unknown IDs so delayed restore/classification can still
    /// recover their previous position.
    var sidebarGroupOrder: [String] = []

    /// Independent order within each user group. Flat order remains the live
    /// `tabs` order; grouped-mode moves update these buckets instead of
    /// rewriting flat order, so toggling the lens is lossless.
    var sidebarGroupTabOrders: [String: [UUID]] = [:] {
        didSet {
            guard oldValue != sidebarGroupTabOrders else { return }
            orderRevision &+= 1
            invalidateGroupingCache()
        }
    }

    /// Stable user order for Coding Agent project sections and their tabs.
    /// Stale section IDs are intentionally retained so asynchronously-resolved
    /// projects recover their previous position.
    var projectGroupOrder: [ProjectGroupID] = [] {
        didSet {
            guard oldValue != projectGroupOrder else { return }
            orderRevision &+= 1
            invalidateNavigationCache()
        }
    }

    var projectTabOrders: [ProjectGroupID: [UUID]] = [:] {
        didSet {
            guard oldValue != projectTabOrders else { return }
            orderRevision &+= 1
            invalidateNavigationCache()
        }
    }

    /// Whole-section drag state shared by the vertical and horizontal bars.
    var draggingProjectGroupID: ProjectGroupID?

    /// A split tab may expose several detected projects. Its first project is
    /// chosen once and retained while still present, preventing pane-focus or
    /// attention churn from moving the tab between top-bar sections.
    @ObservationIgnored private var primaryProjectAssignments: [UUID: ProjectGroupID] = [:]
    @ObservationIgnored private var orderRevision: UInt64 = 0

    @ObservationIgnored private var groupingCache: GroupingSnapshot?
    @ObservationIgnored private var navigationCache: NavigationSnapshot?

    private struct GroupingRevision: Equatable {
        struct TabRevision: Equatable {
            let id: UUID
            let revision: Int
        }

        struct OverrideRevision: Equatable {
            let tabID: UUID
            let groupID: TabGroupID
        }

        let tabs: [TabRevision]
        let overrides: [OverrideRevision]
    }

    private struct GroupingSnapshot {
        let revision: GroupingRevision
        let visibleTabs: [TabModel]
        let effectiveIDs: [UUID: TabGroupID]
        let groupOrder: [TabGroupID]
        let groupTabIDs: [TabGroupID: [UUID]]
    }

    private struct NavigationRevision: Equatable {
        let groupingRevision: GroupingRevision
        let isGroupedModeEnabled: Bool
        let activeGroupID: TabGroupID?
        let selectedFallbackID: UUID?
        let projectScopedInbox: Bool
        /// Every visible tab's project, so a change to ANY tab's project
        /// invalidates the cache — not just the selected one's.
        let projectMembership: [String]
        let orderRevision: UInt64
    }

    private struct NavigationSnapshot {
        let revision: NavigationRevision
        let tabs: [TabModel]
        let indexByID: [UUID: Int]
        let projection: TabOrderProjection
    }

    /// Whether a keyboard-owning overlay (tab/connection sidebar, any sheet —
    /// `MainView.isAnySheetPresented`) is currently up in this window. MainView
    /// keeps this in lockstep with the per-terminal `overlayOwnsKeyboard` gate
    /// it pushes. It exists so focus paths that run for terminals created WHILE
    /// an overlay is open — `setFocusedTerminal`, `handleSelectedTabChange`, and
    /// `TmuxController` pane creation — can initialize the new terminal's gate
    /// before its first focus attempt; otherwise the gate defaults false, the
    /// terminal steals first responder from the open overlay, and (because the
    /// flag was never raised) it misses the dismiss reconcile. Read imperatively
    /// at focus time, never observed for UI, so it is `@ObservationIgnored`.
    @ObservationIgnored var overlayOwnsKeyboard = false

    /// Pending scroll target for the scrolling-mode tab bar. Tab-management
    /// code sets this after inserting a new tab so the `ScrollViewReader`
    /// scrolls to the new tab even if `selectedTabIndex` / `tabs.count`
    /// changes don't trigger a layout update at the right moment (which the
    /// previous design papered over with `.id(tabBarVersion)` forcing the
    /// ScrollView to rebuild). The scroll-effect handler clears this back to
    /// nil after issuing the scroll.
    var pendingScrollToTabID: UUID?

    init() {}

    private func invalidateGroupingCache() {
        groupingCache = nil
        navigationCache = nil
    }

    private func invalidateNavigationCache() {
        navigationCache = nil
    }

    private var currentGroupingRevision: GroupingRevision {
        GroupingRevision(
            tabs: tabs.map { GroupingRevision.TabRevision(id: $0.id, revision: $0.groupingRevision) },
            overrides: tabGroupOverrides.sorted { lhs, rhs in
                lhs.key.uuidString < rhs.key.uuidString
            }.map { entry in
                GroupingRevision.OverrideRevision(tabID: entry.key, groupID: entry.value)
            }
        )
    }

    private func groupingSnapshot() -> GroupingSnapshot {
        let revision = currentGroupingRevision
        if let groupingCache, groupingCache.revision == revision {
            return groupingCache
        }

        let groupableTabs = tabs.filter { !$0.isHiddenTmuxWindow || $0.isTmuxGateway || $0.isTmuxWindow }
        let visibleTabs = tabs.filter { !$0.isHiddenTmuxWindow }
        let autoIDs = autoGroupIDs(for: groupableTabs)
        let validIDs = Set(autoIDs.values)
        var effectiveIDs: [UUID: TabGroupID] = [:]
        var buckets: [TabGroupID: [UUID]] = [:]
        var order: [TabGroupID] = []

        for tab in groupableTabs {
            let auto = autoIDs[tab.id] ?? .other(String(localized: "Other", comment: "Tab group title for uncategorized terminals"))
            let override = tabGroupOverrides[tab.id].flatMap { validIDs.contains($0) ? $0 : nil }
            let id = override ?? auto
            effectiveIDs[tab.id] = id
            if buckets[id] == nil { order.append(id) }
            buckets[id, default: []].append(tab.id)
        }
        for (groupID, tabIDs) in buckets {
            buckets[groupID] = TabOrderRules.applyingPreferredOrder(
                sidebarGroupTabOrders[groupID.rawValue] ?? [],
                to: tabIDs
            )
        }

        let snapshot = GroupingSnapshot(
            revision: revision,
            visibleTabs: visibleTabs,
            effectiveIDs: effectiveIDs,
            groupOrder: order,
            groupTabIDs: buckets
        )
        groupingCache = snapshot
        return snapshot
    }

    private func navigationSnapshot() -> NavigationSnapshot {
        let grouping = groupingSnapshot()
        // Prefer the active group, but if it has dissolved (its tmux gateway
        // detached, or its last tab closed) fall back to the SELECTED tab's
        // group — never to every visible tab, which is what leaked unrelated
        // groups into the tab bar until the user toggled grouped mode off/on.
        let resolvedActiveGroupID = activeGroupID.flatMap { grouping.groupTabIDs[$0] != nil ? $0 : nil }
        let usesSelectedFallback = isGroupedModeEnabled && resolvedActiveGroupID == nil
        let projectMembership: [String] = projectScopedInboxEnabled
            ? grouping.visibleTabs.map(Self.projectMembershipRevision(for:))
            : []
        let anyProject = projectScopedInboxEnabled && grouping.visibleTabs.contains { tab in
            tab.splitTree.contains {
                $0.presentation.agentRow?.project?.label.isEmpty == false
            }
        }
        let projectGrouping = projectScopedInboxEnabled && isGroupedModeEnabled && anyProject
        let revision = NavigationRevision(
            groupingRevision: grouping.revision,
            isGroupedModeEnabled: isGroupedModeEnabled,
            activeGroupID: activeGroupID,
            selectedFallbackID: (projectGrouping || usesSelectedFallback) ? selectedTabID : nil,
            projectScopedInbox: projectGrouping,
            projectMembership: projectMembership,
            orderRevision: orderRevision
        )
        if let navigationCache, navigationCache.revision == revision {
            return navigationCache
        }

        let byID = Dictionary(uniqueKeysWithValues: grouping.visibleTabs.map { ($0.id, $0) })
        let navigationIDs: [UUID]
        let sections: [ProjectTabSection]
        let mode: TabOrderMode
        let activeProjectID: ProjectGroupID?
        let activeScopeTitle: String?
        let allProjectSections = projectScopedInboxEnabled && anyProject
            ? buildProjectSections(visibleTabs: grouping.visibleTabs)
            : []

        if projectGrouping {
            sections = allProjectSections
            let activeSection = TabOrderRules.activeSectionIndex(
                containing: selectedTabID,
                in: sections.map(\.tabIDs)
            ).map { sections[$0] }
            navigationIDs = activeSection?.tabIDs ?? grouping.visibleTabs.map(\.id)
            mode = .projectGrouped
            activeProjectID = activeSection?.id
            activeScopeTitle = activeSection?.title
        } else if isGroupedModeEnabled {
            let groupID = resolvedActiveGroupID ?? selectedTabID.flatMap { grouping.effectiveIDs[$0] }
            navigationIDs = groupID.flatMap { grouping.groupTabIDs[$0] }
                ?? grouping.visibleTabs.map(\.id)
            sections = allProjectSections
            mode = .userGrouped(groupID)
            activeProjectID = nil
            activeScopeTitle = groupID.flatMap { id in
                availableGroups.first(where: { $0.id == id })?.title
            }
        } else {
            navigationIDs = grouping.visibleTabs.map(\.id)
            sections = allProjectSections
            mode = .flat
            activeProjectID = nil
            activeScopeTitle = nil
        }
        let navigationTabs = navigationIDs.compactMap { byID[$0] }
        let projection = TabOrderProjection(
            mode: mode,
            navigationTabIDs: navigationTabs.map(\.id),
            projectSections: sections,
            activeProjectID: activeProjectID,
            activeScopeTitle: activeScopeTitle
        )

        let snapshot = NavigationSnapshot(
            revision: revision,
            tabs: navigationTabs,
            indexByID: Dictionary(uniqueKeysWithValues: navigationTabs.enumerated().map { entry in
                (entry.element.id, entry.offset)
            }),
            projection: projection
        )
        navigationCache = snapshot
        return snapshot
    }

    /// Cache identity for every project-bearing pane in a tab. Pane UUIDs are
    /// included so replacing one agent pane with another invalidates even when
    /// their labels happen to match.
    private static func projectMembershipRevision(for tab: TabModel) -> String {
        let values = tab.splitTree.map { pane in
            let project = pane.presentation.agentRow?.project
            let projectKey = project.map {
                "\($0.hostKey ?? ""):\($0.identityPath):\($0.label)"
            } ?? ""
            let isAgent = pane.presentation.agentRow != nil ? "agent" : "other"
            return "\(pane.uuid.uuidString)=\(isAgent):\(projectKey)"
        }
        return values.joined(separator: "|")
    }

    private static func projectGroupID(for project: AgentProjectIdentity) -> ProjectGroupID {
        ProjectGroupID(hostKey: project.hostKey, path: project.identityPath)
    }

    private func projectCandidates(for tab: TabModel) -> [(id: ProjectGroupID, label: String)] {
        var seen = Set<ProjectGroupID>()
        return tab.splitTree.compactMap { pane in
            guard let project = pane.presentation.agentRow?.project else { return nil }
            let id = Self.projectGroupID(for: project)
            guard seen.insert(id).inserted else { return nil }
            return (id, project.label)
        }
    }

    func primaryProjectGroupID(for tab: TabModel) -> ProjectGroupID {
        let candidates = projectCandidates(for: tab)
        if let assigned = primaryProjectAssignments[tab.id],
           candidates.contains(where: { $0.id == assigned }) {
            return assigned
        }
        let next = candidates.first?.id ?? .other
        primaryProjectAssignments[tab.id] = next
        return next
    }

    func projectGroupID(forPane paneID: UUID, in tab: TabModel) -> ProjectGroupID? {
        guard let project = tab.splitTree.first(where: { $0.uuid == paneID })?
            .presentation.agentRow?.project else { return nil }
        return Self.projectGroupID(for: project)
    }

    private func buildProjectSections(visibleTabs: [TabModel]) -> [ProjectTabSection] {
        var discovered: [ProjectGroupID] = []
        var labels: [ProjectGroupID: String] = [:]
        var buckets: [ProjectGroupID: [UUID]] = [:]

        for tab in visibleTabs {
            for candidate in projectCandidates(for: tab) {
                if labels[candidate.id] == nil {
                    discovered.append(candidate.id)
                    labels[candidate.id] = candidate.label
                }
            }
            let primary = primaryProjectGroupID(for: tab)
            if primary.isOther, labels[.other] == nil {
                discovered.append(.other)
                labels[.other] = String(localized: "Other")
            }
            buckets[primary, default: []].append(tab.id)
        }

        let known = Set(discovered)
        var orderedIDs = projectGroupOrder.filter { known.contains($0) }
        let orderedSet = Set(orderedIDs)
        let newProjects = discovered.filter { !orderedSet.contains($0) && !$0.isOther }
        let insertionIndex = orderedIDs.firstIndex(where: \.isOther) ?? orderedIDs.endIndex
        orderedIDs.insert(contentsOf: newProjects, at: insertionIndex)
        if known.contains(.other), !orderedIDs.contains(.other) {
            orderedIDs.append(.other)
        }

        let duplicateIDsByLabel = Dictionary(grouping: orderedIDs.filter { !$0.isOther }) {
            labels[$0] ?? String(localized: "Project")
        }

        return orderedIDs.map { id in
            let rawLabel = labels[id] ?? (id.isOther ? String(localized: "Other") : String(localized: "Project"))
            let title: String
            if !id.isOther, let duplicateIDs = duplicateIDsByLabel[rawLabel],
               duplicateIDs.count > 1 {
                let sameHostIDs = duplicateIDs.filter { $0.hostKey == id.hostKey }
                let pathSuffix = TabOrderRules.shortestUniquePathSuffix(
                    for: id.path,
                    among: sameHostIDs.map(\.path)
                )
                let disambiguator: String
                if id.hostKey.isEmpty {
                    disambiguator = pathSuffix
                } else if sameHostIDs.count > 1 {
                    disambiguator = "\(id.hostKey) · \(pathSuffix)"
                } else {
                    disambiguator = id.hostKey
                }
                title = "\(rawLabel) — \(disambiguator)"
            } else {
                title = rawLabel
            }
            let tabIDs = TabOrderRules.applyingPreferredOrder(
                projectTabOrders[id] ?? [],
                to: buckets[id] ?? []
            )
            return ProjectTabSection(id: id, title: title, tabIDs: tabIDs)
        }
    }

    /// Convenience: insert a tab and request the scrolling tab bar scroll to it.
    func insertTab(_ tab: TabModel, at index: Int, selectIt: Bool = true) {
        let clamped = max(0, min(index, tabs.count))
        tabs.insert(tab, at: clamped)
        if selectIt {
            selectedTabID = tab.id
        }
        pendingScrollToTabID = tab.id
    }

    /// Reorder a tab in a single Observation event.
    ///
    /// Mutating `tabs` in place via `_modify` (e.g. `tabs.remove(at:)` followed
    /// by `tabs.insert(_:at:)`) publishes one Observation invalidation per
    /// mutation, even when both calls are inside one `withAnimation` block.
    /// Reassigning the property publishes once, so SwiftUI sees a single
    /// transition `[A,B,C,D] → [A,C,B,D]` and `ForEach`'s identity-keyed diff
    /// animates only the swapped elements.
    func move(from: Int, to: Int) {
        guard from != to,
              tabs.indices.contains(from),
              to >= 0, to < tabs.count else { return }
        var copy = tabs
        let moved = copy.remove(at: from)
        copy.insert(moved, at: to)
        tabs = copy
    }

    /// Animated reorder shared by every tab-move call site. Uses `.snappy`
    /// because rapid back-to-back moves retarget cleanly through it; a stiff
    /// spring with high damping pops/stutters when a second transaction
    /// arrives mid-flight.
    func animatedMove(from: Int, to: Int) {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
            move(from: from, to: to)
        }
    }

    /// Permutation counterpart of `animatedMove`: writes `newOrder` into the
    /// given `slots`, leaving every other index untouched (the same contract
    /// as the tmux reconcile's `reorderTmuxTabsByIndex`). Used by the
    /// vertical tab sidebar, where grouped rows make visual neighbors
    /// non-adjacent in the raw array — a raw remove+insert move there would
    /// drag unrelated tabs along with it. Publishes a single Observation
    /// event (see `move`).
    func animatedPermute(slots: [Int], newOrder: [TabModel]) {
        guard slots.count == newOrder.count,
              slots.allSatisfy({ tabs.indices.contains($0) }) else { return }
        var copy = tabs
        for (slot, tab) in zip(slots, newOrder) {
            copy[slot] = tab
        }
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
            tabs = copy
        }
    }

    // MARK: - Convenience accessors

    /// Index of `selectedTabID` in `tabs`, or nil if the selection no longer
    /// matches any tab. Use `selectedTabIndex(default:)` to fall back to a
    /// safe default for code that needs an `Int`.
    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    /// The currently-selected tab, or nil if `tabs` is empty.
    var selectedTab: TabModel? {
        guard let id = selectedTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    /// Tabs the user can see and navigate to: everything except hidden tmux
    /// window tabs. The tab strip, Cmd+N shortcuts, and next/prev navigation
    /// all operate on this view of `tabs`. (id=tmux-hidden-windows)
    var visibleTabs: [TabModel] {
        groupingSnapshot().visibleTabs
    }

    /// Tabs used by top-tab-bar rendering and keyboard tab navigation. In
    /// grouped mode this is narrowed to the active group; otherwise it is the
    /// full visible tab set.
    var navigationTabs: [TabModel] {
        navigationSnapshot().tabs
    }

    /// The single ordering contract consumed by every horizontal-navigation
    /// surface. Only the active scope's `navigationTabIDs` receive shortcut
    /// positions; `projectSections` supplies the scope switcher and organizer.
    var orderProjection: TabOrderProjection {
        navigationSnapshot().projection
    }

    var projectSections: [ProjectTabSection] {
        navigationSnapshot().projection.projectSections
    }

    var isProjectGroupingActive: Bool {
        if case .projectGrouped = navigationSnapshot().projection.mode { return true }
        return false
    }

    /// Index of a tab within `visibleTabs` (what the user perceives as the
    /// tab's position), or nil when the tab is hidden or gone.
    func visibleIndex(of id: UUID) -> Int? {
        groupingSnapshot().visibleTabs.firstIndex(where: { $0.id == id })
    }

    func navigationIndex(of id: UUID) -> Int? {
        navigationSnapshot().indexByID[id]
    }

    /// Reorder two visible tabs according to the active presentation. Flat
    /// mode updates canonical order; user/project lenses update only their own
    /// remembered order so switching modes is lossless.
    @discardableResult
    func moveTabInActiveOrder(movingID: UUID, toTargetID targetID: UUID) -> Bool {
        guard movingID != targetID,
              let movingTab = tab(withID: movingID),
              tab(withID: targetID) != nil else { return false }

        switch orderProjection.mode {
        case .flat:
            guard let from = index(of: movingID), let to = index(of: targetID) else { return false }
            animatedMove(from: from, to: to)

        case .userGrouped:
            guard let sourceGroup = effectiveGroupID(for: movingTab),
                  let targetGroup = effectiveGroupID(for: tab(withID: targetID)),
                  sourceGroup == targetGroup,
                  let ordered = availableGroups.first(where: { $0.id == sourceGroup })?.tabIDs
            else { return false }
            guard let movedOrder = TabOrderRules.moving(movingID, to: targetID, in: ordered)
            else { return false }
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
                sidebarGroupTabOrders[sourceGroup.rawValue] = movedOrder
            }
            // tmux window order is also a remote server semantic. Keep the
            // backing array aligned for the existing move-window synchronizer;
            // ordinary user groups remain presentation-only.
            if movingTab.isTmuxWindow,
               let fromRaw = index(of: movingID),
               let toRaw = index(of: targetID) {
                animatedMove(from: fromRaw, to: toRaw)
            }

        case .projectGrouped:
            return moveTabInProjectOrder(movingID: movingID, toTargetID: targetID)
        }
        return true
    }

    /// Reorders within the stable primary-project bucket regardless of the
    /// horizontal presentation mode. The project sidebar uses this directly
    /// because its project hierarchy can be active while the top bar remains
    /// flat. Cross-project targets are rejected without touching `tabs`.
    @discardableResult
    func moveTabInProjectOrder(movingID: UUID, toTargetID targetID: UUID) -> Bool {
        guard movingID != targetID,
              let movingTab = tab(withID: movingID),
              let targetTab = tab(withID: targetID) else { return false }
        let sourceProject = primaryProjectGroupID(for: movingTab)
        guard sourceProject == primaryProjectGroupID(for: targetTab),
              let ordered = buildProjectSections(visibleTabs: visibleTabs)
                .first(where: { $0.id == sourceProject })?
                .tabIDs,
              let movedOrder = TabOrderRules.moving(movingID, to: targetID, in: ordered)
        else { return false }
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
            projectTabOrders[sourceProject] = movedOrder
        }
        return true
    }

    func setActiveOrder(_ orderedIDs: [UUID]) {
        let live = Set(tabs.map(\.id))
        let normalized = orderedIDs.filter { live.contains($0) }
        guard !normalized.isEmpty else { return }

        switch orderProjection.mode {
        case .flat:
            let orderedSet = Set(normalized)
            let slots = tabs.indices.filter { orderedSet.contains(tabs[$0].id) }
            let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            let orderedTabs = normalized.compactMap { byID[$0] }
            animatedPermute(slots: slots, newOrder: orderedTabs)
        case .userGrouped(let groupID):
            guard let groupID else { return }
            sidebarGroupTabOrders[groupID.rawValue] = normalized
        case .projectGrouped:
            guard let first = normalized.first,
                  let firstTab = tab(withID: first) else { return }
            let projectID = primaryProjectGroupID(for: firstTab)
            guard normalized.allSatisfy({
                tab(withID: $0).map { primaryProjectGroupID(for: $0) == projectID } ?? false
            }) else { return }
            projectTabOrders[projectID] = normalized
        }
    }

    /// Replace only the slots occupied by `orderedIDs` inside the active
    /// projection. Used for tmux sibling drags where gateway/ordinary tabs
    /// interleave the visual section and must keep their positions.
    func setActiveOrderSubsequence(_ orderedIDs: [UUID]) {
        switch orderProjection.mode {
        case .flat:
            guard let replacement = TabOrderRules.replacingSubsequence(
                orderedIDs,
                in: tabs.map(\.id)
            ) else { return }
            let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
                tabs = replacement.compactMap { byID[$0] }
            }
        case .userGrouped(let groupID):
            guard let groupID,
                  let fullOrder = availableGroups.first(where: { $0.id == groupID })?.tabIDs,
                  let replacement = TabOrderRules.replacingSubsequence(
                    orderedIDs,
                    in: fullOrder
                  ) else { return }
            sidebarGroupTabOrders[groupID.rawValue] = replacement
            // Keep tmux server-order synchronization compatible with the
            // existing raw-slot based controller.
            let rawIDs = tabs.map(\.id)
            if let rawReplacement = TabOrderRules.replacingSubsequence(
                orderedIDs,
                in: rawIDs
            ) {
                let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
                tabs = rawReplacement.compactMap { byID[$0] }
            }
        case .projectGrouped:
            guard let first = orderedIDs.first,
                  let firstTab = tab(withID: first) else { return }
            let projectID = primaryProjectGroupID(for: firstTab)
            guard let fullOrder = projectSections.first(where: { $0.id == projectID })?.tabIDs,
                  let replacement = TabOrderRules.replacingSubsequence(
                    orderedIDs,
                    in: fullOrder
                  ) else { return }
            projectTabOrders[projectID] = replacement
        }
    }

    func moveProjectSection(_ movingID: ProjectGroupID, to targetID: ProjectGroupID) {
        guard movingID != targetID else { return }
        var ids = buildProjectSections(visibleTabs: visibleTabs).map(\.id)
        guard let from = ids.firstIndex(of: movingID),
              let to = ids.firstIndex(of: targetID) else { return }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.0)) {
            projectGroupOrder = TabOrderRules.mergingLivePermutation(
                ids,
                into: projectGroupOrder
            )
        }
    }

    func moveProjectSection(_ id: ProjectGroupID, delta: Int) {
        let ids = buildProjectSections(visibleTabs: visibleTabs).map(\.id)
        guard let index = ids.firstIndex(of: id),
              ids.indices.contains(index + delta) else { return }
        moveProjectSection(id, to: ids[index + delta])
    }

    // MARK: - Scope navigation (groups / projects)

    /// A user group or a project section, for per-scope selection memory.
    nonisolated enum ScopeKey: Hashable {
        case group(TabGroupID)
        case project(ProjectGroupID)
    }

    /// Remembered per scope so returning to a group lands on the tab you
    /// left, not its first tab. Updated on every selection change.
    private func rememberSelectionScope(of tab: TabModel) {
        if let group = effectiveGroupID(for: tab) {
            lastSelectedTabByScope[.group(group)] = tab.id
        }
        lastSelectedTabByScope[.project(primaryProjectGroupID(for: tab))] = tab.id
    }

    /// First tab a user can land on in a group/section (skips hidden tmux
    /// windows). Shared by the scope menu and scope navigation.
    func firstNavigableTabID(in tabIDs: [UUID]) -> UUID? {
        tabIDs.first { tab(withID: $0)?.isHiddenTmuxWindow == false }
    }

    /// The tab to land on when entering a scope: its last selected tab if it
    /// is still there and navigable, else the first navigable one.
    func preferredTabID(in tabIDs: [UUID], scope: ScopeKey) -> UUID? {
        if let remembered = lastSelectedTabByScope[scope],
           tabIDs.contains(remembered),
           tab(withID: remembered)?.isHiddenTmuxWindow == false {
            return remembered
        }
        return firstNavigableTabID(in: tabIDs)
    }

    func preferredTabID(inGroup group: TabGroup) -> UUID? {
        preferredTabID(in: group.tabIDs, scope: .group(group.id))
    }

    func preferredTabID(inProjectSection section: ProjectTabSection) -> UUID? {
        preferredTabID(in: section.tabIDs, scope: .project(section.id))
    }

    /// A group / project section as the exposé and scope navigation see it.
    nonisolated struct ScopeInfo {
        let key: ScopeKey
        let title: String?
        /// Navigable members (hidden tmux windows excluded), in scope order:
        /// exactly `orderProjection.navigationTabIDs` once this scope is active.
        let tabIDs: [UUID]
    }

    /// The scope `offset` steps from the active one, wrapping: user groups
    /// in sidebar order, or project sections; scopes with no navigable tab
    /// (hidden-only tmux groups) are skipped. nil in flat mode or when there
    /// is only one scope.
    func neighborScope(offset: Int) -> ScopeInfo? {
        guard let list = scopeList(), list.scopes.count > 1 else { return nil }
        let count = list.scopes.count
        return list.scopes[((list.activeIndex + offset) % count + count) % count]
    }

    /// Every navigable scope in order with the active one's index; nil in
    /// flat mode or when the active scope cannot be found.
    func scopeList() -> (scopes: [ScopeInfo], activeIndex: Int)? {
        let projection = orderProjection
        let scopes: [ScopeInfo]
        let activeIndex: Int?
        switch projection.mode {
        case .flat:
            return nil
        case .userGrouped:
            let visible = Set(groupingSnapshot().visibleTabs.map(\.id))
            scopes = orderedGroups.compactMap { group in
                let ids = group.tabIDs.filter(visible.contains)
                return ids.isEmpty ? nil : ScopeInfo(key: .group(group.id), title: group.title, tabIDs: ids)
            }
            activeIndex = activeGroupID.flatMap { id in scopes.firstIndex { $0.key == .group(id) } }
        case .projectGrouped:
            scopes = projection.projectSections
                .filter { !$0.tabIDs.isEmpty }
                .map { ScopeInfo(key: .project($0.id), title: $0.title, tabIDs: $0.tabIDs) }
            activeIndex = projection.activeProjectID.flatMap { id in scopes.firstIndex { $0.key == .project(id) } }
        }
        guard !scopes.isEmpty, let activeIndex else { return nil }
        return (scopes, activeIndex)
    }

    /// Preferred tab of the neighbor scope (see `neighborScope(offset:)`).
    func firstTabIDInNeighborScope(offset: Int) -> UUID? {
        guard let scope = neighborScope(offset: offset) else { return nil }
        return preferredTabID(in: scope.tabIDs, scope: scope.key)
    }

    var availableGroups: [TabGroup] {
        let snapshot = groupingSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        return snapshot.groupOrder.compactMap { id in
            guard let tabIDs = snapshot.groupTabIDs[id], !tabIDs.isEmpty else { return nil }
            return TabGroup(id: id, title: groupTitle(for: id, tabIDs: tabIDs, byID: byID), tabIDs: tabIDs)
        }
    }

    /// Groups in the order the vertical sidebar displays them: applies the
    /// user's persisted `sidebarGroupOrder`; groups with no saved position fall
    /// to the end in their natural order. Shared by the sidebar and by
    /// close-neighbor selection so both agree on the user-perceived order.
    var orderedGroups: [TabGroup] {
        let groups = availableGroups
        let groupOrder = sidebarGroupOrder
        guard !groupOrder.isEmpty else { return groups }
        let orderIndex = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($0.element, $0.offset) })
        return groups.enumerated().sorted { lhs, rhs in
            let l = orderIndex[lhs.element.id.rawValue] ?? Int.max
            let r = orderIndex[rhs.element.id.rawValue] ?? Int.max
            if l != r { return l < r }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Neighbor in the active derived order. User and project grouping prefer
    /// the current scope, then cross a section boundary only when its last tab
    /// closes.
    func groupedCloseNeighbor(for closingID: UUID) -> UUID? {
        if isProjectGroupingActive {
            let ids = orderProjection.navigationTabIDs
            guard let index = ids.firstIndex(of: closingID) else { return nil }
            if index + 1 < ids.count { return ids[index + 1] }
            if index > 0 { return ids[index - 1] }

            let flattened = projectSections.flatMap(\.tabIDs)
            guard let flattenedIndex = flattened.firstIndex(of: closingID) else { return nil }
            if flattenedIndex + 1 < flattened.count { return flattened[flattenedIndex + 1] }
            if flattenedIndex > 0 { return flattened[flattenedIndex - 1] }
            return nil
        }

        guard isGroupedModeEnabled else { return nil }
        let snapshot = groupingSnapshot()
        guard let groupID = snapshot.effectiveIDs[closingID] else { return nil }
        let visibleIDs = Set(snapshot.visibleTabs.map { $0.id })

        // Same-group sibling (within-group order matches the sidebar).
        let groupTabs = (snapshot.groupTabIDs[groupID] ?? []).filter { visibleIDs.contains($0) }
        if let i = groupTabs.firstIndex(of: closingID) {
            if i + 1 < groupTabs.count { return groupTabs[i + 1] }
            if i > 0 { return groupTabs[i - 1] }
        }

        // Group will be empty: nearest tab in flattened display order.
        let flattened = orderedGroups.flatMap { $0.tabIDs }.filter { visibleIDs.contains($0) }
        guard let f = flattened.firstIndex(of: closingID) else { return nil }
        if f + 1 < flattened.count { return flattened[f + 1] }
        if f > 0 { return flattened[f - 1] }
        return nil
    }

    private func groupTitle(for id: TabGroupID, tabIDs: [UUID], byID: [UUID: TabModel]) -> String {
        guard id.kind == .tmux else { return id.title }
        if let gateway = tabIDs.compactMap({ byID[$0] }).first(where: { $0.isTmuxGateway }) {
            let controller = gateway.splitTree.terminalLeaves
                .first(where: { $0.tmuxController != nil })?
                .tmuxController
            let host = controller?.connectionKey ?? controller?.gatewaySourceDisplayName
            return TabOrderRules.scopeTitle(
                components: [gateway.tmuxSessionName, host],
                fallback: id.title
            )
        }
        return id.title
    }

    func effectiveGroupID(for tab: TabModel?) -> TabGroupID? {
        guard let tab else { return nil }
        return groupingSnapshot().effectiveIDs[tab.id]
    }

    /// All tabs belonging to a tmux gateway by owner UUID — the gateway tab plus
    /// every window tab (visible, hidden, and awaiting-reconcile placeholders),
    /// in display order, REGARDLESS of any group override. A gateway move must
    /// use this rather than `availableGroups` (which buckets by effective group
    /// and so drops children the user overrode into another group): the gateway
    /// move re-points the controller's `baseWindowId`, so any family member left
    /// behind — especially a placeholder with no per-window host mapping — would
    /// fail tmux adoption on the next reconcile.
    func tmuxFamilyTabIDs(ownerID: UUID) -> [UUID] {
        tabs.compactMap { Self.tmuxOwnerID(for: $0) == ownerID ? $0.id : nil }
    }

    func setGroupOverride(for tabID: UUID, to groupID: TabGroupID) {
        guard tab(withID: tabID) != nil else { return }
        let validIDs = Set(groupingSnapshot().groupOrder)
        guard validIDs.contains(groupID) else { return }
        tabGroupOverrides[tabID] = groupID
        if selectedTabID == tabID {
            activeGroupID = groupID
        }
    }

    func clearGroupOverride(for tabID: UUID) {
        guard let tab = tab(withID: tabID) else { return }
        tabGroupOverrides.removeValue(forKey: tabID)
        if selectedTabID == tabID {
            activeGroupID = effectiveGroupID(for: tab)
        }
    }

    func markGroupingInputsChanged(for tabID: UUID) {
        guard let tab = tab(withID: tabID) else { return }
        tab.markGroupingInputsChanged()
        guard isGroupedModeEnabled else { return }
        if selectedTabID == tabID {
            activeGroupID = effectiveGroupID(for: tab)
        } else {
            normalizeGroupingSelection()
        }
    }

    func clearStaleGroupOverrides() {
        let validIDs = Set(groupingSnapshot().groupOrder)
        let filtered = tabGroupOverrides.filter { tabID, groupID in
            tab(withID: tabID) != nil && validIDs.contains(groupID)
        }
        if filtered.count != tabGroupOverrides.count {
            tabGroupOverrides = filtered
        }
    }

    func tab(withID id: UUID) -> TabModel? {
        tabs.first(where: { $0.id == id })
    }

    /// Ensure `selectedTabID` still points at an existing tab; if not (e.g. the
    /// selected tab was just removed — a failed tmux placeholder), fall back to
    /// the tmux gateway tab if present, otherwise the first remaining tab. Keeps
    /// the tab bar from being left with no valid selection.
    func repairSelectionIfNeeded() {
        func isUsableFallback(_ tab: TabModel) -> Bool {
            !tab.isHiddenTmuxWindow && !(tab.awaitingTmuxReconcile && tab.splitTree.isEmpty)
        }

        // A selection pointing at a HIDDEN tab is broken too: any path that
        // hides the selected tab without re-selecting lands here.
        // (id=tmux-hidden-windows)
        if let id = selectedTabID,
           let current = tabs.first(where: { $0.id == id }),
           !current.isHiddenTmuxWindow { return }
        // With more than one tmux -CC gateway open, first(isTmuxGateway) is an
        // arbitrary pick — acceptable for this last-resort fallback. Paths
        // that know which gateway they belong to (prune's
        // id=tmux-detach-reselect-own-gateway, neighbor close) select
        // deterministically BEFORE this runs, so this only fires when no
        // better information exists. Hidden tabs are never a valid landing.
        let groupFallback = activeGroupID.flatMap { groupID in
            tabs.first { isUsableFallback($0) && effectiveGroupID(for: $0) == groupID }
        }
        let fallback = groupFallback
            ?? tabs.first(where: { $0.isTmuxGateway && isUsableFallback($0) })
            ?? tabs.first(where: isUsableFallback)
            ?? tabs.first
        selectedTabID = fallback?.id
        if let fallback { pendingScrollToTabID = fallback.id }
    }

    /// Re-point `activeGroupID` after a structural change dissolved its group
    /// (e.g. a tmux gateway detached and its `.tmux(ownerID:)` group vanished).
    /// The automatic equivalent of toggling grouped mode off/on. No-op outside
    /// grouped mode and when the active group still exists.
    func revalidateGroupingSelection() {
        normalizeGroupingSelection()
    }

    private func normalizeGroupingSelection() {
        clearStaleGroupOverrides()
        guard isGroupedModeEnabled, !isProjectGroupingActive else { return }
        let groups = availableGroups
        if let activeGroupID,
           groups.contains(where: { $0.id == activeGroupID }) {
            if effectiveGroupID(for: selectedTab) != activeGroupID,
               let first = visibleTabs.first(where: { effectiveGroupID(for: $0) == activeGroupID }) {
                selectedTabID = first.id
            }
            return
        }
        if let selectedGroup = effectiveGroupID(for: selectedTab) {
            activeGroupID = selectedGroup
            return
        }
        activeGroupID = effectiveGroupID(for: visibleTabs.first)
        if selectedTabID == nil {
            selectedTabID = visibleTabs.first?.id
        }
    }

    private func autoGroupIDs(for groupableTabs: [TabModel]) -> [UUID: TabGroupID] {
        var hostByTab: [UUID: String] = [:]
        var hostCounts: [String: Int] = [:]

        for tab in groupableTabs {
            guard let host = Self.groupHost(for: tab, allTabs: tabs) else { continue }
            hostByTab[tab.id] = host
            hostCounts[host, default: 0] += 1
        }

        var ids: [UUID: TabGroupID] = [:]
        for tab in groupableTabs {
            if let ownerID = Self.tmuxOwnerID(for: tab) {
                ids[tab.id] = .tmux(ownerID: ownerID)
            } else if let host = hostByTab[tab.id] {
                if let network = TabGroupID.ipNetworkGroup(for: host) {
                    ids[tab.id] = .remoteNetwork(network)
                } else if (hostCounts[host] ?? 0) > 1 {
                    ids[tab.id] = .remoteHost(host)
                } else if let domain = TabGroupID.registrableDomain(for: host) {
                    ids[tab.id] = .remoteDomain(domain)
                } else {
                    ids[tab.id] = .remoteHost(host)
                }
            } else if Self.isLocal(tab) {
                ids[tab.id] = .local
            } else {
                ids[tab.id] = .other(Self.fallbackGroupTitle(for: tab))
            }
        }
        return ids
    }

    private static func isLocal(_ tab: TabModel) -> Bool {
        guard let pane = groupingPane(for: tab),
              let config = groupingConnectionConfig(for: pane) else { return false }
        if case .local = config { return true }
        return false
    }

    private static func tmuxOwnerID(for tab: TabModel) -> UUID? {
        if let owner = TmuxTabBadgeResolver.ownerID(for: tab) {
            return owner
        }
        if tab.isTmuxWindow {
            return tab.owningGatewayTerminalUUID
        }
        let hasLiveTmuxPane = tab.splitTree.contains { $0.asTerminal?.tmuxPaneBinding != nil }
        return hasLiveTmuxPane ? tab.owningGatewayTerminalUUID : nil
    }

    private static func groupHost(for tab: TabModel, allTabs: [TabModel]) -> String? {
        if let pane = groupingPane(for: tab),
           let config = groupingConnectionConfig(for: pane),
           let host = groupHost(for: config) {
            return host
        }
        if tab.isTmuxWindow,
           let owner = tab.owningGatewayTerminalUUID,
           let gateway = allTabs.first(where: { TmuxTabBadgeResolver.ownerID(for: $0) == owner }),
           let pane = groupingPane(for: gateway),
           let config = groupingConnectionConfig(for: pane) {
            return groupHost(for: config)
        }
        return nil
    }

    private static func groupingPane(for tab: TabModel) -> SplitPaneView? {
        // Resolve the focused PANE first so a focused non-terminal pane means
        // "no grouping config" instead of silently grouping by a background
        // terminal's host. Non-terminal connection panes such as VNC expose
        // their configuration directly below.
        tab.focusedPane ?? tab.splitTree.first
    }

    private static func groupingConnectionConfig(for pane: SplitPaneView) -> ConnectionConfig? {
        if let vncPane = pane as? VNCPaneView {
            return .vnc(vncPane.config)
        }
        guard let terminal = pane.asTerminal else { return nil }
        if let embeddedProvider = terminal.session as? EmbeddedConnectionConfigProviding,
           let embeddedConfig = embeddedProvider.activeEmbeddedConnectionConfig {
            return embeddedConfig
        }
        return terminal.connectionConfig
    }

    private static func groupHost(for config: ConnectionConfig) -> String? {
        if let ssh = config.underlyingSSHConfig {
            return TabGroupID.normalizeHost(ssh.host)
        }
        switch config {
        case .ec2Console(let ec2):
            return TabGroupID.normalizeHost(ec2.sshHost)
        case .kubernetes(let kube):
            return TabGroupID.normalizeHost(kube.nodeName)
        case .trzszTransfer(_, _, let host):
            return TabGroupID.normalizeHost(host)
        case .console(let console):
            return TabGroupID.normalizeHost(console.instanceLabel)
        case .vnc(let vnc):
            return TabGroupID.normalizeHost(vnc.host)
        default:
            return nil
        }
    }

    private static func fallbackGroupTitle(for tab: TabModel) -> String {
        if let pane = groupingPane(for: tab),
           let config = groupingConnectionConfig(for: pane) {
            switch config {
            case .console:
                return String(localized: "Cloud Consoles", comment: "Tab group title for cloud console sessions")
            case .kubernetes:
                return String(localized: "Kubernetes", comment: "Tab group title for Kubernetes sessions")
            default:
                return String(localized: "Other", comment: "Tab group title for uncategorized terminals")
            }
        }
        return String(localized: "Other", comment: "Tab group title for uncategorized terminals")
    }

    func index(of id: UUID) -> Int? {
        tabs.firstIndex(where: { $0.id == id })
    }

    // MARK: - Displayed-tab reveal

    /// Open the title-deferral gate for the duration of the selection spring
    /// animation. While it's up, `TabModel.applyResolvedTitle` stashes title
    /// updates instead of writing them, so a churning tab's TabBarItem
    /// re-renders don't compete with the in-flight animation.
    private func beginTabSwitchAnimationGate() {
        // Nothing to protect when tab-bar animations are off — don't add title
        // latency for an instant switch.
        guard !SettingsStore.shared.value(Settings.Tabs.barAnimationsDisabled) else { return }
        isTabSwitchAnimating = true
        tabSwitchAnimationTimer?.invalidate()
        // .spring(response: 0.3) settles in ~0.4s; the `.animation(_:value:)`
        // modifier gives no completion callback, so a safety timer clears the
        // gate (same pattern as KeyboardTracker.setKeyboardAnimating). Rapid
        // switches re-arm it — titles stay frozen until switching stops, then
        // flush once. Tunable; shorten toward 0.3 if titles feel slow to resume.
        tabSwitchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.endTabSwitchAnimationGate() }
        }
    }

    /// Close the gate and flush each tab's most recent deferred title.
    private func endTabSwitchAnimationGate() {
        tabSwitchAnimationTimer?.invalidate()
        tabSwitchAnimationTimer = nil
        guard isTabSwitchAnimating else { return }
        isTabSwitchAnimating = false
        for tab in tabs { tab.flushDeferredTitle() }
    }

    /// Reconcile `displayedTabID` with `selectedTabID`. Called from the
    /// selection `didSet` and from tab-removal paths (the displayed tab may
    /// have been closed out from under a pending reveal).
    ///
    /// If the target tab's terminals have all presented a frame (or it has
    /// none, e.g. a tmux placeholder that renders nothing anyway), reveal it
    /// immediately so tab switching stays instant. Otherwise keep the old
    /// tab visible, register first-frame callbacks, and fail open after
    /// 600ms so a surface that never presents can't pin a stale tab.
    func syncDisplayedTab() {
        displayRevealGeneration += 1
        let generation = displayRevealGeneration

        guard let target = selectedTab else {
            if tabs.isEmpty {
                displayedTabID = nil
            } else {
                // Selection is broken (nil or dangling) while tabs exist,
                // e.g. a restore whose saved index was invalidated by
                // placeholder filtering. Repair instead of blanking every
                // tab; the resulting `selectedTabID` didSet re-enters this
                // function with a valid target.
                repairSelectionIfNeeded()
            }
            return
        }
        if displayedTabID == target.id {
            // Settled, with one exception: a tab that was displayed while
            // EMPTY (tmux placeholder) and has now received its first panes
            // must gate those panes like a fresh reveal, or they show at
            // full opacity before their first present. "No terminal has
            // presented yet" identifies that case; a tab with any presented
            // terminal is genuinely settled (splits added to a visible tab
            // never gate).
            let isFirstContent = !target.splitTree.isEmpty
                && target.splitTree.terminalLeaves.allSatisfy { !$0.hasRenderedFirstFrame }
            if !isFirstContent { return }
            displayedTabID = nil
        }

        // The previously displayed tab may have been closed; drop it so the
        // backdrop fill covers the gap instead of a dangling identity.
        if let displayed = displayedTabID, !tabs.contains(where: { $0.id == displayed }) {
            displayedTabID = nil
        }

        let pending = target.splitTree.terminalLeaves.filter { !$0.hasRenderedFirstFrame }
        if pending.isEmpty {
            displayedTabID = target.id
            return
        }

        // Capture only the id, not the TabModel: the callback is stored on
        // the TerminalView, which the tab's splitTree owns, so a strong
        // `target` capture would cycle (TabModel -> TerminalView -> closure
        // -> TabModel) and pin the tab if the callback is never drained
        // (e.g. surface creation bails before polling ever arms).
        let targetID = target.id
        for view in pending {
            view.notifyOnFirstFrame { [weak self] in
                guard let self, self.displayRevealGeneration == generation else { return }
                guard self.displayedTabID != targetID else { return }
                guard let target = self.tab(withID: targetID) else { return }
                guard target.splitTree.terminalLeaves.allSatisfy({ $0.hasRenderedFirstFrame }) else { return }
                self.displayedTabID = targetID
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.displayRevealGeneration == generation else { return }
            guard self.displayedTabID != targetID else { return }
            Ghostty.logger.warning("Tab reveal timed out waiting for first frame; revealing anyway")
            self.displayedTabID = targetID
            guard let target = self.tab(withID: targetID) else { return }
            for view in target.splitTree.terminalLeaves where view.isTmuxPane && !view.hasRenderedFirstFrame {
                _ = view.reassertVisibleIfNeeded(
                    shouldFocus: view === target.focusedPane,
                    reason: "tab-reveal-fail-open"
                )
            }
        }
    }
}

// MARK: - Source-compat typealias
//
// The pre-existing codebase used the name `TerminalTab` for the value-type
// struct that stored per-tab state. The struct is gone; tabs are now
// `TabModel` class instances tracked by an `@Observable TabsModel`. To keep
// the migration mechanical, leave a top-level typealias so call sites that
// reference `TerminalTab` continue to compile while preserving the new
// observation behavior.
typealias TerminalTab = TabModel
