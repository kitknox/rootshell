//
//  TabsModel.swift
//  rootshell
//
//  @Observable tab models, so a per-tab title or health change invalidates only
//  the views that read that tab rather than all of MainView.
//
//  TabModel mirrors its focused terminal's `$title` and `$connectionHealth`
//  between `startObserving()` and `stopObserving()`.
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
        case herdr
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
        case .herdr: return "herdr:\(value)"
        case .other: return "other:\(value)"
        }
    }

    static func herdr(ownerID: UUID) -> TabGroupID {
        TabGroupID(kind: .herdr, value: ownerID.uuidString.lowercased())
    }

    var herdrOwnerID: UUID? {
        kind == .herdr ? UUID(uuidString: value) : nil
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
        case .herdr:
            return "herdr"
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

/// The label is not part of the identity, so same-named projects stay separate.
nonisolated struct ProjectGroupID: Hashable, Codable, Sendable, Identifiable {
    let hostKey: String
    let path: String
    /// For named workspaces without a directory; survives renames.
    let workspaceKey: String?

    var id: String { rawValue }
    var rawValue: String { "\(hostKey)\u{1f}\(path)" + (workspaceKey.map { "\u{1f}\($0)" } ?? "") }

    static let other = ProjectGroupID(hostKey: "", path: "")

    var isOther: Bool { self == .other }

    init(hostKey: String?, path: String, workspaceKey: String? = nil) {
        self.hostKey = hostKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.path = AgentProjectPath.normalize(path)
        self.workspaceKey = workspaceKey
    }
}

nonisolated struct ProjectTabSection: Identifiable, Hashable, Sendable {
    let id: ProjectGroupID
    let title: String
    /// Each tab is in exactly one section, so sections can drive navigation.
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

@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    let paneMove = PaneMoveState()
    /// Stops a delayed move reply from overriding a newer focus choice.
    @ObservationIgnored private(set) var paneFocusRevision: UInt64 = 0

    var windowId: String

    /// Hosts the `tmux -CC` gateway surface. The tab stays visible, like iTerm2.
    var isTmuxGateway: Bool = false {
        didSet { markGroupingChanged(oldValue, isTmuxGateway) }
    }

    /// Observable mirror of `TmuxController.currentSessionName`.
    var tmuxSessionName: String? {
        didSet { markGroupingChanged(oldValue, tmuxSessionName) }
    }

    /// A projected tmux window tab; badged, unlike the gateway.
    var isTmuxWindow: Bool = false {
        didSet { markGroupingChanged(oldValue, isTmuxWindow) }
    }

    var isHerdrGateway: Bool = false {
        didSet { markGroupingChanged(oldValue, isHerdrGateway) }
    }

    var herdrSessionName: String? {
        didSet { markGroupingChanged(oldValue, herdrSessionName) }
    }

    /// Never persisted; the controller rebuilds it on reconnect.
    var isHerdrWindow: Bool = false {
        didSet { markGroupingChanged(oldValue, isHerdrWindow) }
    }

    /// Another herdr client sizes this tab or holds its panes. Display only.
    var herdrIsControlledElsewhere = false

    /// Workspace fields are mirrored so grouping needs no controller lookup.
    var herdrTabId: String? {
        didSet { markGroupingChanged(oldValue, herdrTabId) }
    }
    var herdrWorkspaceId: String? {
        didSet { markGroupingChanged(oldValue, herdrWorkspaceId) }
    }
    var herdrWorkspaceLabel: String? {
        didSet { markGroupingChanged(oldValue, herdrWorkspaceLabel) }
    }
    var herdrHostKey: String? {
        didSet { markGroupingChanged(oldValue, herdrHostKey) }
    }
    var herdrWorkspaceProject: AgentProjectIdentity? {
        didSet { markGroupingChanged(oldValue, herdrWorkspaceProject) }
    }

    /// Persisted so a restored placeholder can be re-matched to its window.
    var tmuxWindowId: Int? {
        didSet { markGroupingChanged(oldValue, tmuxWindowId) }
    }

    /// Stable across restore, unlike the tab UUID, so the controller can adopt
    /// its own restored placeholders.
    var owningGatewayTerminalUUID: UUID? {
        didSet { markGroupingChanged(oldValue, owningGatewayTerminalUUID) }
    }

    /// A restored tmux window tab with no live panes yet. The first reconcile
    /// adopts it; one still waiting when the resume watchdog fires is removed.
    var awaitingTmuxReconcile: Bool = false

    /// Cleared on adoption.
    var pendingTmuxWindowId: Int?

    /// `#{window_index}`, for tab order. (id=tmux-window-order)
    var tmuxWindowIndex: Int = 0

    /// Not grouping-relevant: it changes often and must not invalidate the
    /// grouping cache. (id=agent-attention)
    var attentionBadge: AgentAttentionStatus?

    /// The tab's highest-priority agent. Same grouping rule as `attentionBadge`.
    /// (id=agent-attention)
    var agentRow: AgentRowState?

    /// The focused pane's agent id, so the top tab logo matches the title.
    /// Kept apart from `agentRow` so progress ticks don't re-render the bar.
    var agentID: String?

    /// Every agent pane in split-tree order, unlike `agentRow`.
    var agentPaneIDs: [UUID] = []

    /// The window still lives on the server and keeps reconciling, but tab UI
    /// skips it. Set only by `TmuxController`. A hidden gateway is client-local
    /// and never enters `@hidden`. (id=tmux-hidden-windows, id=tmux-hidden-gateway)
    var isHiddenTmuxWindow: Bool = false {
        didSet { markGroupingChanged(oldValue, isHiddenTmuxWindow) }
    }

    /// Applied only after a successful reconcile; hiding at restore would strand
    /// the tab if resume failed. (id=tmux-hidden-gateway)
    @ObservationIgnored var pendingHiddenTmuxGatewayRestore: Bool = false

    /// Nil follows the global font.
    var tmuxFontSizeOverride: Double?

    var splitTree: SplitTree<SplitPaneView> {
        didSet {
            AgentAttentionCenter.shared.topologyDidChange()
        }
    }

    /// Setting this rewires title/health observation.
    var focusedPane: SplitPaneView? {
        didSet {
            guard oldValue !== focusedPane else { return }
            paneFocusRevision &+= 1
            groupingRevision &+= 1
            startObserving()
            AgentAttentionCenter.shared.visibilityDidChange()
        }
    }

    /// Nil when a non-terminal pane holds focus.
    var focusedTerminal: Ghostty.TerminalView? {
        get { focusedPane as? Ghostty.TerminalView }
        set { focusedPane = newValue }
    }

    /// Resolve the focused pane first, including tmux's transport-independent
    /// gateway. Projected windows and restored placeholders have no own session.
    var connectionInfo: ConnectionInfo? {
        if let info = (focusedPane as? VNCPaneView)?.connectionInfo {
            return info
        }
        let terminal = focusedTerminal
        if let binding = terminal?.tmuxPaneBinding {
            return tmuxConnectionInfo(owner: binding.parentUUID,
                                      windowID: binding.windowId, paneID: binding.paneId)
        }
        if let terminal, let controller = terminal.tmuxController,
           !controller.didEnd {
            return tmuxConnectionInfo(owner: terminal.uuid, windowID: nil, paneID: nil)
        }
        if let binding = terminal?.herdrPaneBinding {
            return HerdrController.connectionInfo(gatewayUUID: binding.gatewayUUID,
                                                  tabID: binding.tabId, terminalID: binding.terminalId)
        }
        if let terminal, let controller = terminal.herdrController, !controller.didEnd {
            return controller.connectionInfo(tabID: nil, terminalID: nil)
        }
        if let info = terminal?.session?.connectionInfo { return info }
        if isTmuxWindow, let owner = owningGatewayTerminalUUID {
            return tmuxConnectionInfo(owner: owner, windowID: tmuxWindowId, paneID: nil)
        }
        if isHerdrWindow, let owner = owningGatewayTerminalUUID {
            return HerdrController.connectionInfo(gatewayUUID: owner, tabID: herdrTabId, terminalID: nil)
        }
        return nil
    }

    private func tmuxConnectionInfo(owner: UUID, windowID: Int?, paneID: Int?) -> ConnectionInfo {
        let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: owner)
        return .tmux(TmuxConnectionInfo(
            gatewayID: owner,
            controllerID: gateway?.tmuxController?.connectionInfoID,
            windowID: windowID,
            paneID: paneID,
            openedAt: Date()
        ), transport: gateway?.session?.connectionInfo)
    }

    // MARK: - Mirrored State (driven by the focused terminal's @Published properties)

    /// The session title, or the connection's display name when that is empty
    /// or "ghostty".
    var title: String = "Terminal"

    /// Nil for non-SSH or pre-connect.
    var connectionHealth: ConnectionHealth?

    private(set) var activeRoamProtocol: MainView.RoamProtocol = .none

    var hasActiveMoshSession: Bool { activeRoamProtocol == .mosh }

    // MARK: - Internal observation storage

    @ObservationIgnored private var observationCancellables = Set<AnyCancellable>()
    private(set) var groupingRevision = 0 {
        didSet { tabsModel?.tabGroupingInputsDidChange() }
    }

    /// Weak: TabsModel owns its tabs. Read for the tab-switch animation gate
    /// and to forward grouping changes.
    @ObservationIgnored weak var tabsModel: TabsModel?

    /// Latest title held back while the tab-switch gate is up.
    @ObservationIgnored private var deferredTitle: String?

    /// Leading-and-trailing throttle so ~10 Hz agent title spinners don't
    /// invalidate the whole window graph on every frame.
    @ObservationIgnored private var pendingPublishedTitle: String?
    @ObservationIgnored private var titlePublicationTimer: Timer?
    @ObservationIgnored private var lastTitlePublicationUptime: TimeInterval = 0
    private var minimumTitlePublicationInterval: TimeInterval { isHerdrWindow ? 0.075 : 0.2 }

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

        startObserving()
    }

    convenience init(terminalView: Ghostty.TerminalView? = nil, title: String = "Terminal", windowId: String, isMosh: Bool = false) {
        // `isMosh` is ignored; roam protocol is computed.
        _ = isMosh
        self.init(paneView: terminalView, title: title, windowId: windowId)
    }

    convenience init(windowId: String) {
        self.init(terminalView: nil, title: "Terminal", windowId: windowId)
    }

    init(restoringTitle title: String,
         splitTree: SplitTree<SplitPaneView>,
         focusedPane: SplitPaneView?,
         windowId: String) {
        self.windowId = windowId
        self.splitTree = splitTree
        // Order matters: this didSet fires during init and would overwrite the
        // saved title, so restore it afterwards and re-observe preserving it.
        self.focusedPane = focusedPane
        self.title = title
        startObserving(preserveExistingTitle: true)
    }

    // MARK: - Notification-driven roam-protocol refresh

    /// Catches tssh/mosh started inside a running shell, which no focus change reports.
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
                    if self.notificationOriginatesInThisTab(notification) {
                        self.recomputeRoamProtocol()
                    }
                }
                .store(in: &observationCancellables)
        }
    }

    private func notificationOriginatesInThisTab(_ notification: Notification) -> Bool {
        if let terminal = notification.object as? Ghostty.TerminalView {
            return splitTree.contains { $0 === terminal }
        }
        #if !targetEnvironment(macCatalyst)
        // Embedded-session notifications carry the LocalShellSession.
        if let session = notification.object as? LocalShellSession {
            return splitTree.contains { $0.asTerminal?.session === session }
        }
        #endif
        return false
    }

    deinit {
        observationCancellables.removeAll()
        titlePublicationTimer?.invalidate()
    }

    // MARK: - Observation

    /// `preserveExistingTitle` keeps a restored title over the pre-connect "ghostty".
    func startObserving(preserveExistingTitle: Bool = false) {
        observationCancellables.removeAll()
        cancelPendingTitlePublication()
        if isHerdrWindow {
            HerdrController.controller(forTab: self)?.refreshTitle(of: self)
        }

        // The pane, not the terminal shim, so a focused non-terminal isn't skipped.
        guard let pane = focusedPane ?? splitTree.first else {
            if !isHerdrWindow, title != "Terminal" {
                title = "Terminal"
            }
            recomputeRoamProtocol()
            return
        }
        guard let focusedTerminal = pane.asTerminal else {
            // Only VNC panes publish a title; others keep the current one.
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
        // tmux/herdr window titles come only from their controller, or pane OSC
        // titles would stomp a renamed window. (id=tmux-window-title-single-writer)
        if !preserveExistingTitle,
           !isTmuxWindow,
           !isHerdrWindow,
           let resolved = Self.resolveTitle(rawTitle: focusedTerminal.title, on: focusedTerminal),
           title != resolved {
            title = resolved
        }

        // Restored tabs drop fallback titles ("ghostty", "") until a real one arrives.
        var hasReceivedRealTitle = !preserveExistingTitle
        let titlePublisher: AnyPublisher<String, Never> = preserveExistingTitle
            ? focusedTerminal.$title.dropFirst().eraseToAnyPublisher()
            : focusedTerminal.$title.eraseToAnyPublisher()
        titlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak focusedTerminal] newTitle in
                guard let self, let focusedTerminal else { return }
                // (id=tmux-window-title-single-writer)
                if self.isTmuxWindow || self.isHerdrWindow { return }
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

        focusedTerminal.$connectionHealth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] health in
                guard let self else { return }
                if self.connectionHealth != health {
                    self.connectionHealth = health
                }
            }
            .store(in: &observationCancellables)

        subscribeToRoamProtocolNotifications()

        recomputeRoamProtocol()
    }

    func stopObserving() {
        observationCancellables.removeAll()
        cancelPendingTitlePublication()
    }

    /// Deferred during a tab-switch animation so title churn can't starve the
    /// spring; throttled otherwise.
    func applyResolvedTitle(_ resolved: String) {
        // Empty means "no update": the Zig snapshot sends "" for invalid titles.
        guard !resolved.isEmpty else { return }
        if tabsModel?.isTabSwitchAnimating == true {
            deferredTitle = resolved
            return
        }
        deferredTitle = nil
        scheduleTitlePublication(resolved)
    }

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
        if lastTitlePublicationUptime == 0 || elapsed >= minimumTitlePublicationInterval {
            publishPendingTitle()
            return
        }

        guard titlePublicationTimer == nil else { return }
        let timer = Timer(
            timeInterval: minimumTitlePublicationInterval - elapsed,
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

    /// So a stale timer can't overwrite the new pane's initial title.
    private func cancelPendingTitlePublication() {
        titlePublicationTimer?.invalidate()
        titlePublicationTimer = nil
        pendingPublishedTitle = nil
        deferredTitle = nil
        lastTitlePublicationUptime = 0
    }

    func recomputeRoamProtocol() {
        let computed = Self.computeRoamProtocol(in: splitTree)
        if activeRoamProtocol != computed {
            activeRoamProtocol = computed
        }
    }

    // MARK: - Title resolution

    /// Nil means keep the existing title (local shells with a fallback title).
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
        // Unreachable for terminals; kept for exhaustiveness.
        case .vnc(let config): return config.displayName
        }
    }

    static func shouldUseFallbackTitle(_ title: String) -> Bool {
        return title.isEmpty || title == "ghostty"
    }

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

/// A window's tabs plus selection and drag state.
@MainActor
@Observable
final class TabsModel {
    @ObservationIgnored private(set) var selectionRevision: UInt64 = 0
    /// Held until the herdr gateway's first snapshot; selecting another tab cancels it.
    @ObservationIgnored var pendingHerdrSelection: SerializableHerdrSelection?
    var tabs: [TabModel] = [] {
        didSet {
            indexByIDCache = nil
            groupingInputsRevision &+= 1
            invalidateGroupingCache()
            for tab in tabs { tab.tabsModel = self }
            let liveIDs = Set(tabs.map(\.id))
            primaryProjectAssignments = primaryProjectAssignments.filter { liveIDs.contains($0.key) }
            AgentAttentionCenter.shared.topologyDidChange()
        }
    }

    /// Nil only when `tabs` is empty. Every selection change funnels through here.
    var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            selectionRevision &+= 1
            if let pending = pendingHerdrSelection,
               selectedTab?.splitTree.terminalLeaves.contains(where: { $0.uuid == pending.gatewayTerminalUUID }) != true {
                pendingHerdrSelection = nil
            }
            beginTabSwitchAnimationGate()
            if let tab = selectedTab { rememberSelectionScope(of: tab) }
            if isGroupedModeEnabled, !isProjectGroupingActive,
               let selectedGroup = effectiveGroupID(for: selectedTab),
               activeGroupID != selectedGroup {
                activeGroupID = selectedGroup
            }
            syncDisplayedTab()
            AgentAttentionCenter.shared.visibilityDidChange()
            HerdrController.selectedTabDidChange(in: self)
        }
    }

    @ObservationIgnored private var lastSelectedTabByScope: [ScopeKey: UUID] = [:]

    /// Lags `selectedTabID` until the target's terminals present a first frame,
    /// so a swap never shows the empty translucent layer. Focus doesn't lag.
    var displayedTabID: UUID?

    /// Runtime-only, so restoration always lands non-full-screen.
    var fullScreenPaneID: UUID?

    /// Invalidates in-flight reveal waiters when selection changes again.
    @ObservationIgnored private var displayRevealGeneration = 0

    /// Closes held by holdClose(of:untilDrawn:close:), keyed by closing tab;
    /// true while the held close runs.
    @ObservationIgnored private var heldCloses: [UUID: Bool] = [:]

    /// Title writers defer while this is up so churn can't starve the selection
    /// spring. Ignored by Observation so flipping it invalidates nothing.
    @ObservationIgnored private(set) var isTabSwitchAnimating = false
    @ObservationIgnored private var tabSwitchAnimationTimer: Timer?

    var draggingTabID: UUID?

    /// Set by the sidebar. With grouped mode also on, the top bar and keyboard
    /// navigation scope to the selected tab's project. (id=agent-project)
    var projectScopedInboxEnabled: Bool = AgentAttentionSettings.projectGroupingSelected {
        didSet {
            guard oldValue != projectScopedInboxEnabled else { return }
            invalidateNavigationCache()
            // Keep the selected tab visible by activating its group.
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
            // The selected tab's group wins over a stale persisted one.
            if isGroupedModeEnabled, let selectedGroup = effectiveGroupID(for: selectedTab) {
                activeGroupID = selectedGroup
            }
            normalizeGroupingSelection()
        }
    }

    var activeGroupID: TabGroupID? {
        didSet {
            guard oldValue != activeGroupID else { return }
            invalidateNavigationCache()
            normalizeGroupingSelection()
        }
    }

    /// Stale ids are ignored by effective grouping.
    var tabGroupOverrides: [UUID: TabGroupID] = [:] {
        didSet {
            groupingInputsRevision &+= 1
            invalidateGroupingCache()
        }
    }

    /// Bumped whenever a grouping input changes: the tab list, the overrides,
    /// or any member tab's `groupingRevision`. One observed counter instead of
    /// reading every tab's revision, which made each grouping lookup O(n).
    private(set) var groupingInputsRevision: UInt64 = 0

    func tabGroupingInputsDidChange() {
        groupingInputsRevision &+= 1
    }

    /// Unknown ids are kept so late-classified groups recover their position.
    var sidebarGroupOrder: [String] = []

    /// Grouped-mode moves write here instead of `tabs`, so toggling is lossless.
    var sidebarGroupTabOrders: [String: [UUID]] = [:] {
        didSet {
            guard oldValue != sidebarGroupTabOrders else { return }
            orderRevision &+= 1
            invalidateGroupingCache()
        }
    }

    /// Stale ids are kept so asynchronously resolved projects recover their position.
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

    var draggingProjectGroupID: ProjectGroupID?

    /// Sticky while present, so focus changes don't move a split tab between sections.
    @ObservationIgnored private var primaryProjectAssignments: [UUID: ProjectGroupID] = [:]
    @ObservationIgnored private var orderRevision: UInt64 = 0

    @ObservationIgnored private var groupingCache: GroupingSnapshot?
    @ObservationIgnored private var navigationCache: NavigationSnapshot?

    private struct GroupingRevision: Equatable {
        let inputs: UInt64
    }

    private struct GroupingSnapshot {
        let revision: GroupingRevision
        let visibleTabs: [TabModel]
        let effectiveIDs: [UUID: TabGroupID]
        let groupOrder: [TabGroupID]
        let groupTabIDs: [TabGroupID: [UUID]]
        /// Position in `visibleTabs`.
        let visibleIndexByID: [UUID: Int]
        /// Position among the non-hidden members of the tab's own group.
        let groupPositionByID: [UUID: Int]
    }

    private struct NavigationRevision: Equatable {
        let groupingRevision: GroupingRevision
        let isGroupedModeEnabled: Bool
        let activeGroupID: TabGroupID?
        let selectedFallbackID: UUID?
        let projectScopedInbox: Bool
        /// All visible tabs, not just the selected one.
        let projectMembership: [String]
        let orderRevision: UInt64
    }

    private struct NavigationSnapshot {
        let revision: NavigationRevision
        let tabs: [TabModel]
        let indexByID: [UUID: Int]
        let projection: TabOrderProjection
    }

    /// Seeds the gate for terminals created while an overlay is open, which
    /// would otherwise steal first responder from it.
    @ObservationIgnored var overlayOwnsKeyboard = false

    /// Cleared by the tab bar once it has scrolled.
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
        GroupingRevision(inputs: groupingInputsRevision)
    }

    private func groupingSnapshot() -> GroupingSnapshot {
        let revision = currentGroupingRevision
        if let groupingCache, groupingCache.revision == revision {
            return groupingCache
        }

        // A hidden gateway still heads its family, tmux or herdr.
        let groupableTabs = tabs.filter {
            !$0.isHiddenTmuxWindow || $0.isTmuxGateway || $0.isTmuxWindow || $0.isHerdrGateway || $0.isHerdrWindow
        }
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
        let byID = Dictionary(uniqueKeysWithValues: groupableTabs.map { ($0.id, $0) })
        for (groupID, tabIDs) in buckets {
            var ordered = TabOrderRules.applyingPreferredOrder(
                sidebarGroupTabOrders[groupID.rawValue] ?? [],
                to: tabIDs
            )
            if groupID.kind == .herdr {
                ordered = Self.groupedByHerdrWorkspace(ordered, byID: byID)
            }
            buckets[groupID] = ordered
        }
        var groupPositionByID: [UUID: Int] = [:]
        for tabIDs in buckets.values {
            var position = 0
            for id in tabIDs {
                guard let tab = byID[id], !tab.isHiddenTmuxWindow else { continue }
                if groupPositionByID[id] == nil { groupPositionByID[id] = position }
                position += 1
            }
        }

        let snapshot = GroupingSnapshot(
            revision: revision,
            visibleTabs: visibleTabs,
            effectiveIDs: effectiveIDs,
            groupOrder: order,
            groupTabIDs: buckets,
            visibleIndexByID: Dictionary(visibleTabs.enumerated().map { ($1.id, $0) },
                                         uniquingKeysWith: { first, _ in first }),
            groupPositionByID: groupPositionByID
        )
        groupingCache = snapshot
        return snapshot
    }

    /// Gateway first, then each workspace contiguously, matching the sidebar.
    private static func groupedByHerdrWorkspace(_ ids: [UUID], byID: [UUID: TabModel]) -> [UUID] {
        var gateway: [UUID] = []
        var workspaceOrder: [String] = []
        var byWorkspace: [String: [UUID]] = [:]
        var rest: [UUID] = []
        for id in ids {
            guard let tab = byID[id] else {
                rest.append(id)
                continue
            }
            if tab.isHerdrGateway {
                gateway.append(id)
            } else if tab.isHerdrWindow, let workspaceId = tab.herdrWorkspaceId {
                if byWorkspace[workspaceId] == nil { workspaceOrder.append(workspaceId) }
                byWorkspace[workspaceId, default: []].append(id)
            } else {
                rest.append(id)
            }
        }
        return gateway + workspaceOrder.flatMap { byWorkspace[$0] ?? [] } + rest
    }

    private func navigationSnapshot() -> NavigationSnapshot {
        let grouping = groupingSnapshot()
        // A dissolved active group falls back to the selected tab's group, not all tabs.
        let resolvedActiveGroupID = activeGroupID.flatMap { grouping.groupTabIDs[$0] != nil ? $0 : nil }
        let usesSelectedFallback = isGroupedModeEnabled && resolvedActiveGroupID == nil
        let projectMembership: [String] = projectScopedInboxEnabled
            ? grouping.visibleTabs.map(Self.projectMembershipRevision(for:))
            : []
        let anyProject = projectScopedInboxEnabled && grouping.visibleTabs.contains {
            !projectCandidates(for: $0).isEmpty
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

    var hasAnyProject: Bool {
        visibleTabs.contains { !projectCandidates(for: $0).isEmpty }
    }

    /// Includes pane UUIDs so swapping a same-labelled pane still invalidates.
    private static func projectMembershipRevision(for tab: TabModel) -> String {
        let values = tab.splitTree.map { pane in
            let project = pane.presentation.projectForGrouping
            let projectKey = project.map {
                "\($0.hostKey ?? ""):\($0.identityPath):\($0.label)"
            } ?? ""
            let isAgent = pane.presentation.agentRow != nil ? "agent" : "other"
            return "\(pane.uuid.uuidString)=\(isAgent):\(projectKey)"
        }
        let fallback = workspaceProjectCandidate(for: tab).map { "\($0.id.rawValue):\($0.label)" } ?? ""
        return ([fallback] + values).joined(separator: "|")
    }

    private static func projectGroupID(for project: AgentProjectIdentity) -> ProjectGroupID {
        ProjectGroupID(hostKey: project.hostKey, path: project.identityPath)
    }

    private static func workspaceProjectCandidate(for tab: TabModel) -> (id: ProjectGroupID, label: String)? {
        guard tab.isHerdrWindow else { return nil }
        if let project = tab.herdrWorkspaceProject {
            return (projectGroupID(for: project), project.label)
        }
        guard let workspaceID = tab.herdrWorkspaceId,
              let ownerID = tab.owningGatewayTerminalUUID else { return nil }
        return (ProjectGroupID(hostKey: tab.herdrHostKey, path: "",
                               workspaceKey: "\(ownerID.uuidString):\(workspaceID)"),
                tab.herdrWorkspaceLabel ?? workspaceID)
    }

    private func projectCandidates(for tab: TabModel) -> [(id: ProjectGroupID, label: String)] {
        var seen = Set<ProjectGroupID>()
        let fallback = Self.workspaceProjectCandidate(for: tab)
        let candidates = tab.splitTree.compactMap { pane -> (id: ProjectGroupID, label: String)? in
            let candidate = pane.presentation.projectForGrouping.map {
                (id: Self.projectGroupID(for: $0), label: $0.label)
            } ?? fallback
            guard let candidate, seen.insert(candidate.0).inserted else { return nil }
            return candidate
        }
        return candidates.isEmpty ? fallback.map { [$0] } ?? [] : candidates
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
        guard let pane = tab.splitTree.first(where: { $0.uuid == paneID }) else { return nil }
        return pane.presentation.projectForGrouping.map(Self.projectGroupID(for:))
            ?? Self.workspaceProjectCandidate(for: tab)?.id
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
                } else if id.workspaceKey != nil, sameHostIDs.count > 1 {
                    // Their identity keys are opaque, so number them.
                    disambiguator = "\(id.hostKey) · \((sameHostIDs.firstIndex(of: id) ?? 0) + 1)"
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

    func insertTab(_ tab: TabModel, at index: Int, selectIt: Bool = true) {
        let clamped = max(0, min(index, tabs.count))
        tabs.insert(tab, at: clamped)
        if selectIt {
            selectedTabID = tab.id
        }
        pendingScrollToTabID = tab.id
    }

    /// Reassigns `tabs` so Observation publishes one change, not one per mutation.
    func move(from: Int, to: Int) {
        guard from != to,
              tabs.indices.contains(from),
              to >= 0, to < tabs.count else { return }
        var copy = tabs
        let moved = copy.remove(at: from)
        copy.insert(moved, at: to)
        tabs = copy
    }

    /// `.snappy` retargets cleanly on rapid moves; a stiff spring stutters.
    func animatedMove(from: Int, to: Int) {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
            move(from: from, to: to)
        }
    }

    /// Writes `newOrder` into `slots` only, since grouped visual neighbors aren't
    /// adjacent in `tabs`.
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

    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return index(of: id)
    }

    var selectedTab: TabModel? {
        guard let id = selectedTabID else { return nil }
        return tab(withID: id)
    }

    /// Initial attach may only replace its own gateway's selection. Check when the
    /// reply arrives so a background reconnect can't override a newer choice.
    func maySelectInitialMultiplexerTab(gatewayTabID: UUID?) -> Bool {
        guard let selectedTab else { return true }
        return selectedTab.id == gatewayTabID
    }

    /// Also kept while the selected gateway is still reconnecting.
    var herdrSelectionForPersistence: SerializableHerdrSelection? {
        guard let selectedTab else { return nil }
        if selectedTab.isHerdrWindow,
           let owner = selectedTab.owningGatewayTerminalUUID,
           let tabID = selectedTab.herdrTabId {
            return SerializableHerdrSelection(gatewayTerminalUUID: owner, tabID: tabID)
        }
        if let pending = pendingHerdrSelection,
           selectedTab.splitTree.terminalLeaves.contains(where: { $0.uuid == pending.gatewayTerminalUUID }) {
            return pending
        }
        return nil
    }

    /// All but hidden tmux windows. (id=tmux-hidden-windows)
    var visibleTabs: [TabModel] {
        groupingSnapshot().visibleTabs
    }

    /// Narrowed to the active group in grouped mode.
    var navigationTabs: [TabModel] {
        navigationSnapshot().tabs
    }

    /// The ordering every horizontal-navigation surface uses.
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

    func visibleIndex(of id: UUID) -> Int? {
        groupingSnapshot().visibleIndexByID[id]
    }

    /// Position among the non-hidden tabs of `id`'s own group; nil for a
    /// hidden or ungrouped tab.
    func groupPosition(of id: UUID) -> Int? {
        groupingSnapshot().groupPositionByID[id]
    }

    func navigationIndex(of id: UUID) -> Int? {
        navigationSnapshot().indexByID[id]
    }

    /// Workspace siblings in the current presentation, not the navigation set.
    func herdrReorderTabIDs(for tab: TabModel) -> [String]? {
        guard tab.isHerdrWindow, let ownerID = tab.owningGatewayTerminalUUID,
              let workspaceID = tab.herdrWorkspaceId else { return nil }
        let ordered: [TabModel]
        switch orderProjection.mode {
        case .flat:
            ordered = tabs
        case .userGrouped:
            let groupID = TabGroupID.herdr(ownerID: ownerID)
            guard effectiveGroupID(for: tab) == groupID,
                  let group = availableGroups.first(where: { $0.id == groupID }) else { return nil }
            ordered = group.tabIDs.compactMap { self.tab(withID: $0) }
        case .projectGrouped:
            return nil
        }
        return ordered.filter {
            $0.isHerdrWindow && $0.owningGatewayTerminalUUID == ownerID && $0.herdrWorkspaceId == workspaceID
        }.compactMap(\.herdrTabId)
    }

    /// Only the native herdr group follows server order.
    func synchronizeHerdrGroupOrder(_ orderedIDs: [UUID], ownerID: UUID) {
        let groupID = TabGroupID.herdr(ownerID: ownerID)
        guard let group = availableGroups.first(where: { $0.id == groupID }) else { return }
        let members = Set(group.tabIDs)
        guard let replacement = TabOrderRules.replacingSubsequence(
            orderedIDs.filter { members.contains($0) }, in: group.tabIDs
        ), replacement != group.tabIDs else { return }
        sidebarGroupTabOrders[groupID.rawValue] = replacement
    }

    /// Grouped lenses update only their own order, so switching modes is lossless.
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
            // tmux order is server state; keep `tabs` aligned for move-window sync.
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

    /// Independent of the top bar's mode, which can stay flat while the sidebar
    /// groups by project. Rejects cross-project targets.
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

    /// Replaces only `orderedIDs`' slots, so interleaved tabs keep their positions.
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
        case .userGrouped:
            guard let firstID = orderedIDs.first, let firstTab = tab(withID: firstID),
                  let groupID = effectiveGroupID(for: firstTab),
                  orderedIDs.allSatisfy({ effectiveGroupID(for: tab(withID: $0)) == groupID }),
                  let fullOrder = availableGroups.first(where: { $0.id == groupID })?.tabIDs,
                  let replacement = TabOrderRules.replacingSubsequence(
                    orderedIDs,
                    in: fullOrder
                  ) else { return }
            sidebarGroupTabOrders[groupID.rawValue] = replacement
            // Keep the canonical sibling slots aligned for multiplexer drags.
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

    nonisolated enum ScopeKey: Hashable {
        case group(TabGroupID)
        case project(ProjectGroupID)
    }

    /// So returning to a scope lands on the tab you left.
    private func rememberSelectionScope(of tab: TabModel) {
        if let group = effectiveGroupID(for: tab) {
            lastSelectedTabByScope[.group(group)] = tab.id
        }
        lastSelectedTabByScope[.project(primaryProjectGroupID(for: tab))] = tab.id
    }

    func firstNavigableTabID(in tabIDs: [UUID]) -> UUID? {
        tabIDs.first { tab(withID: $0)?.isHiddenTmuxWindow == false }
    }

    /// The remembered tab if still navigable, else the first navigable one.
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

    nonisolated struct ScopeInfo {
        let key: ScopeKey
        let title: String?
        /// Matches `orderProjection.navigationTabIDs` once this scope is active.
        let tabIDs: [UUID]
    }

    /// Wraps, skipping scopes with no navigable tab. Nil in flat mode or with one scope.
    func neighborScope(offset: Int) -> ScopeInfo? {
        guard let list = scopeList(), list.scopes.count > 1 else { return nil }
        let count = list.scopes.count
        return list.scopes[((list.activeIndex + offset) % count + count) % count]
    }

    /// Nil in flat mode or when the active scope can't be found.
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

    /// Sidebar order; groups without a saved position go last.
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

    /// Stays in the current scope unless its last tab is closing.
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
        if id.kind == .herdr {
            // Session name, then host: the same shape as a tmux family.
            let tabs = tabIDs.compactMap { byID[$0] }
            let gateway = tabs.first(where: { $0.isHerdrGateway })
            let session = gateway?.herdrSessionName
                ?? tabs.first?.owningGatewayTerminalUUID
                    .flatMap { HerdrController.controller(forGateway: $0)?.sessionName }
            let host = gateway.flatMap { groupHostLabel(for: $0) }
            return TabOrderRules.scopeTitle(components: [session, host], fallback: id.title)
        }
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

    /// The whole family, ignoring group overrides. Gateway moves need every
    /// member, or left-behind placeholders fail adoption.
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
        index(of: id).map { tabs[$0] }
    }

    /// Repairs a missing or hidden selection. (id=tmux-hidden-windows)
    func repairSelectionIfNeeded() {
        func isUsableFallback(_ tab: TabModel) -> Bool {
            !tab.isHiddenTmuxWindow && !(tab.awaitingTmuxReconcile && tab.splitTree.isEmpty)
        }

        if let id = selectedTabID,
           let current = tabs.first(where: { $0.id == id }),
           !current.isHiddenTmuxWindow { return }
        // Last resort; with several gateways the pick is arbitrary. Callers that
        // know their gateway select first. (id=tmux-detach-reselect-own-gateway)
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

    /// After the active group dissolves, e.g. a tmux gateway detached.
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
            if let ownerID = TmuxTabBadgeResolver.herdrOwnerID(for: tab) {
                ids[tab.id] = .herdr(ownerID: ownerID)
            } else if let ownerID = Self.tmuxOwnerID(for: tab) {
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

    func groupHostLabel(for tab: TabModel) -> String? {
        Self.groupHost(for: tab, allTabs: tabs)
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
        // The pane, so a focused non-terminal isn't grouped by a background terminal.
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
        // Reading `tabs` keeps the observation dependency the scan had.
        let tabs = self.tabs
        if let cache = indexByIDCache { return cache[id] }
        // First occurrence wins, as `firstIndex` did.
        let cache = Dictionary(tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexByIDCache = cache
        return cache[id]
    }

    /// Rebuilt lazily after `tabs` changes; lookups run per tab per render.
    @ObservationIgnored private var indexByIDCache: [UUID: Int]?

    // MARK: - Displayed-tab reveal

    private func beginTabSwitchAnimationGate() {
        guard !SettingsStore.shared.value(Settings.Tabs.barAnimationsDisabled) else { return }
        isTabSwitchAnimating = true
        tabSwitchAnimationTimer?.invalidate()
        // The spring settles in ~0.4s and has no completion callback.
        tabSwitchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.endTabSwitchAnimationGate() }
        }
    }

    private func endTabSwitchAnimationGate() {
        tabSwitchAnimationTimer?.invalidate()
        tabSwitchAnimationTimer = nil
        guard isTabSwitchAnimating else { return }
        isTabSwitchAnimating = false
        for tab in tabs { tab.flushDeferredTitle() }
    }

    /// A failed or ended controller lifts the hold so its error card shows.
    private func isAwaitingHerdrRestoreReveal(for tab: TabModel) -> Bool {
        guard let pending = pendingHerdrSelection,
              tab.splitTree.terminalLeaves.contains(where: { $0.uuid == pending.gatewayTerminalUUID })
        else { return false }
        guard let controller = HerdrController.controller(forGateway: pending.gatewayTerminalUUID) else { return true }
        // A transient connect failure with a retry queued is still "connecting".
        return !controller.didEnd && (controller.connectionError == nil || controller.isReconnectPending)
    }

    /// Honors the herdr restore hold.
    func displaySelectedTabImmediately() {
        guard let selectedTabID, let tab = selectedTab else { return }
        if isAwaitingHerdrRestoreReveal(for: tab) {
            scheduleHerdrRevealFailOpen(generation: displayRevealGeneration, targetID: tab.id)
            return
        }
        displayedTabID = selectedTabID
    }

    /// Last resort for a host that neither answers nor errors.
    private func scheduleHerdrRevealFailOpen(generation: Int, targetID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.displayRevealGeneration == generation else { return }
            guard self.displayedTabID != targetID, self.selectedTabID == targetID else { return }
            Ghostty.logger.warning("herdr gateway reveal timed out waiting for its snapshot; revealing anyway")
            self.displayedTabID = targetID
        }
    }

    /// Closing the displayed tab before its successor has drawn leaves nothing
    /// to show but the reveal backdrop. Returns true when the caller must not
    /// close now: `close` reruns it once the successor draws (or after 150ms).
    func holdClose(of closingID: UUID, untilDrawn successorID: UUID?, close: @escaping @MainActor () -> Void) -> Bool {
        if let releasing = heldCloses[closingID] { return !releasing }
        guard closingID == displayedTabID, let successorID,
              let successor = tab(withID: successorID) else { return false }
        let pending = successor.splitTree.terminalLeaves.filter { !$0.hasRenderedFirstFrame }
        guard !pending.isEmpty else { return false }

        heldCloses[closingID] = false
        let release: @MainActor () -> Void = { [weak self] in
            guard let self, self.heldCloses[closingID] == false else { return }
            self.heldCloses[closingID] = true
            close()
            self.heldCloses[closingID] = nil
        }
        // Hidden at opacity 0, it renders without showing.
        for pane in successor.splitTree { pane.setOcclusion(true) }
        for view in pending {
            view.notifyOnFirstFrame { [weak self] in
                guard let self, let successor = self.tab(withID: successorID),
                      successor.splitTree.terminalLeaves.allSatisfy({ $0.hasRenderedFirstFrame }) else { return }
                // Off the first-frame callback loop.
                Task { @MainActor in release() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            release()
        }
        return true
    }

    /// Reveals at once if the target has presented, else waits for first frames
    /// and fails open after 600ms.
    func syncDisplayedTab() {
        displayRevealGeneration += 1
        let generation = displayRevealGeneration

        guard let target = selectedTab else {
            if tabs.isEmpty {
                displayedTabID = nil
            } else {
                // Repairing re-enters here via the selection didSet.
                repairSelectionIfNeeded()
            }
            return
        }
        // Don't flash the gateway card before it selects its saved tab.
        if isAwaitingHerdrRestoreReveal(for: target) {
            scheduleHerdrRevealFailOpen(generation: generation, targetID: target.id)
            return
        }
        if displayedTabID == target.id {
            // Settled, unless a placeholder just received its first panes.
            let isFirstContent = !target.splitTree.isEmpty
                && target.splitTree.terminalLeaves.allSatisfy { !$0.hasRenderedFirstFrame }
            if !isFirstContent { return }
            displayedTabID = nil
        }

        if let displayed = displayedTabID, !tabs.contains(where: { $0.id == displayed }) {
            displayedTabID = nil
        }

        let pending = target.splitTree.terminalLeaves.filter { !$0.hasRenderedFirstFrame }
        if pending.isEmpty {
            displayedTabID = target.id
            return
        }

        // Capture the id only; capturing the tab would cycle through its terminal.
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

typealias TerminalTab = TabModel
