//
//  HerdrController.swift
//  rootshell
//
//  Drives one herdr session in control mode: it opens a control stream on
//  the gateway pane's connection, mirrors herdr's workspaces, tabs, and panes
//  onto native tabs and splits, feeds each pane surface raw terminal output,
//  and keeps herdr authoritative for layout and agent state. The analogue of
//  TmuxController, written entirely in Swift on top of the socket API.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import GhosttyKit
import os
import UIKit

extension Notification.Name {
    /// Posted (object: gateway terminal UUID) when a herdr control stream ends.
    static let herdrControlModeDidEnd = Notification.Name("herdrControlModeDidEnd")
    static let showHerdrWorkspaces = Notification.Name("showHerdrWorkspaces")
    static let herdrControlStateDidChange = Notification.Name("herdrControlStateDidChange")
}

@MainActor
final class HerdrController {

    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "HerdrController")

    // MARK: - Registry

    private static var controllers: [UUID: HerdrController] = [:]

    static func controller(forGateway uuid: UUID) -> HerdrController? {
        controllers[uuid]
    }

    static func controller(for view: Ghostty.TerminalView) -> HerdrController? {
        if let binding = view.herdrPaneBinding {
            return controllers[binding.gatewayUUID]
        }
        return view.herdrController
    }

    static func controller(forTab tab: TabModel) -> HerdrController? {
        guard tab.isHerdrWindow, let owner = tab.owningGatewayTerminalUUID else { return nil }
        return controllers[owner]
    }

    static var all: [HerdrController] { Array(controllers.values) }

    // MARK: - Identity

    let gatewayUUID: UUID
    private(set) weak var gateway: Ghostty.TerminalView?
    private weak var weakTabsModel: TabsModel?
    var tabsModel: TabsModel {
        guard let model = weakTabsModel else {
            preconditionFailure("HerdrController.tabsModel accessed after its TabsModel was released")
        }
        return model
    }
    let app: ghostty_app_t
    private(set) weak var ghosttyApp: Ghostty.App?
    /// herdr session name; nil attaches to herdr's default session.
    let sessionName: String?
    /// Verified local namespace shared by every auxiliary herdr connection.
    /// Remote gateways continue to resolve their configured session normally.
    var localControlAttachment: LocalMultiplexerAttachment?
    private(set) var hostWindowId: String

    // MARK: - Channel state

    private(set) var channel: HerdrControlChannel?
    var router = HerdrOutputRouter()
    private(set) var streamGeneration = UUID()
    var topologyRefreshTask: Task<Void, Never>?
    var topologyRefreshWanted = false
    private(set) var bootId: String?
    private(set) var serverVersion: String?
    private(set) var serverPid: Int?
    /// Facts from the current stream's `control.open`; nil between streams.
    private(set) var controlOpened: HerdrControl.ControlOpened?
    private(set) var controlOpenedAt: Date?
    /// What the current server can do; `.none` between streams.
    private(set) var capabilities = HerdrServerCapabilities.none
    /// Why the host's herdr should be installed or upgraded, if it should.
    /// Set through `setUpgradePrompt` outside the connect path.
    var upgradePrompt: HerdrUpgradePrompt?
    /// Other control streams on this session (protocol 2 servers only).
    var otherConnections: [HerdrControl.ControlConnection] = []
    /// Identifies this controller generation to Connection Info sheets.
    let connectionInfoID = UUID()
    var pushRouteServerIdentity: String?
    var pushRouteServerIdentityTask: Task<Void, Never>?
    /// True while a control stream is open and the topology has been applied.
    var isActive = false
    private(set) var didEnd = false
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0
    var isReconnectPending: Bool { reconnectTask != nil }

    enum Mode {
        /// Control stream: raw pane bytes, herdr drives layout.
        case raw
        /// Stock herdr: polled topology, server-rendered visible panes.
        case legacy
    }
    var mode: Mode = .raw
    var legacyStreams: [String: HerdrLegacyPaneStream] = [:]
    // Vanilla 0.9.0 endpoint; independent of our fork's raw control channel.
    var endpoint: HerdrEndpointChannel?
    var endpointOpening: Task<Void, Never>?
    /// Backoff reopen after the bridge closes; the 2 s poll is the fallback.
    var endpointReopenTask: Task<Void, Never>?
    var endpointReconnectAttempt = 0
    var endpointUnsupported = false
    var endpointProbed = false
    var endpointActive = true
    var endpointTabID: String?
    var endpointSize: HerdrTabGeometryState.Size?
    var endpointLayouts: [String: HerdrControl.LayoutSnapshot] = [:]
    var legacyOpening: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    var legacyClosing: [String: Task<Void, Never>] = [:]
    var legacyPTYUnavailable = false
    var legacySuspended = false
    var legacyGrids: [String: (rows: Int, cols: Int)] = [:]
    var legacyPollTask: Task<Void, Never>?
    var legacySnapshotFingerprint: Int?
    var endpointMetadata: HerdrEndpointMetadata?
    var legacyTopologyDirty = true
    var legacyPollInFlight = false
    var legacyFallbackForced = false
    /// Degraded-mode failures already written to the gateway; each distinct
    /// message shows once so a repeating poll does not flood the shell.
    var legacyNoticesShown: Set<String> = []
    var didAutoHideGateway = false
    var rehideGatewayAfterEmpty = false
    /// Consumed by the first successful snapshot, including an empty one.
    /// Reconnects and later close events never bootstrap another shell.
    var hasProcessedInitialSnapshot = false
    var newTabTasks: [UUID: Task<Void, Never>] = [:]
    var tabReorderTask: Task<Void, Never>?
    var pendingTabReorders: [HerdrTabOrder.Move] = []
    var tabReorderRevision: UInt64 = 0
    var tabOrderDeferredForDrag = false
    var emptySessionCreationID: UUID?
    var newTabError: String?
    var connectionError: String?

    /// Output held for a tab's panes until their surfaces take the layout.
    struct LayoutRelease {
        let tabId: String
        /// terminal id → grid the layout gives it, dropped as panes match.
        var expected: [String: (cols: Int, rows: Int)]
        var deadline: Task<Void, Never>?
        /// Attaches whose redraw for a superseded layout was discarded.
        var snapshotOnComplete: Set<String> = []
    }
    /// Keyed by the router barrier each `tab.layout` record took.
    var layoutReleases: [UInt64: LayoutRelease] = [:]
    /// Periodic ping while the stream is open; a missed answer closes it so
    /// the reconnect path re-snapshots instead of waiting on a dead link.
    private var healthTask: Task<Void, Never>?
    private static let healthInterval: Duration = .seconds(30)
    /// Set once the first snapshot applied, so later reconnects do not steal
    /// the selected tab.
    var hasProcessedInitialFocus = false
    /// Set once the first snapshot chose the initial tab, or the empty-session
    /// bootstrap finished. The gateway card is not installed before this.
    var hasProcessedInitialReveal = false

    // MARK: - Topology state (mutated by the +Topology and +Panes extensions)

    var workspaces: [String: HerdrControl.WorkspaceInfo] = [:]
    var tabInfos: [String: HerdrControl.TabInfo] = [:]
    var tabOrder = HerdrTabOrder()
    var tabNames = HerdrTabNames()
    var nameMetadataBoot: String?
    let management = HerdrManagementState()
    var managementRevision: UInt64 = 0
    var paneMoveSelectionRevision: UInt64?
    /// An emptied source tab can close before pane.moved identifies the new
    /// pane ID. Keep the terminal surface/session alive across that gap.
    var pendingPaneMoveTerminals: [UUID: String] = [:]
    /// herdr tab id → the tab modeling it.
    var tabs: [String: TabModel] = [:]
    /// herdr pane id → last known pane facts.
    var paneInfos: [String: HerdrControl.PaneInfo] = [:]
    /// terminal id → the surface view rendering it.
    var paneViews: [String: Ghostty.TerminalView] = [:]
    /// terminal id → the pane's session shim once its surface exists.
    var paneSessions: [String: HerdrPaneSession] = [:]
    var attachIds: [String: String] = [:]
    var terminalByAttach: [String: String] = [:]
    /// Per attach, whether this client is the terminal's query authority
    /// (`terminal.authority`); absent means yes, as on protocol 1 servers.
    var attachAnswersQueries: [String: Bool] = [:]
    var attachQueue: [String] = []
    var attachesInFlight: [String: UUID] = [:]
    var attachRetries: [String: Task<Void, Never>] = [:]
    var snapshotRequestsInFlight: Set<String> = []
    /// Attaches that asked for another snapshot while one was in flight.
    var snapshotRetryWanted: Set<String> = []
    var lastLayouts: [String: HerdrControl.LayoutSnapshot] = [:]
    /// Inner pane rectangles from the raw stream, rather than the generic
    /// snapshot's layout in the server TUI's viewport.
    var controlLayouts: [String: HerdrControl.LayoutSnapshot] = [:]
    var tabGeometryStates: [String: HerdrTabGeometryState] = [:]
    var panesNeedingSnapshot: Set<String> = []
    /// Panes whose surface left the server's grid without a layout, keyed
    /// by terminal id, with the smallest grid they passed through. Rows the
    /// surface discarded below the grid the server settles on were never
    /// lost server-side, so no redraw is guaranteed to restore them.
    var clientDetourMinimums: [String: (cols: Int, rows: Int)] = [:]
    var geometryTasks: [String: Task<Void, Never>] = [:]
    var activation = HerdrActivation()
    weak var activationScene: UIWindowScene?
    /// Panes another client holds (terminal id), waiting on Take Control.
    var paneControlStates: [String: HerdrPaneControlState] = [:]
    /// Tabs whose next attaches may evict the other client (user asked).
    var takeoverRequested: Set<String> = []
    /// Tabs already prompted for Take Control on this stream.
    var takeControlPromptedTabs: Set<String> = []
    var focusedPaneId: String?
    var agentStatuses: [String: HerdrControl.AgentStatusChangedData] = [:]
    var agentStatusRevision: UInt64 = 0
    var agentStatusRevisions: [String: UInt64] = [:]
    var agentSubscriptionTask: Task<Void, Never>?
    var subscribedAgentPanes = Set<String>()
    var focusWatchdog: Task<Void, Never>?
    var gatewayTabID: UUID?

    // MARK: - Lifecycle

    private init?(gateway: Ghostty.TerminalView, tabsModel: TabsModel, sessionName: String?) {
        guard let app = gateway.appPtr else { return nil }
        self.gatewayUUID = gateway.uuid
        self.gateway = gateway
        self.weakTabsModel = tabsModel
        self.app = app
        self.ghosttyApp = gateway.ghosttyApp
        self.sessionName = sessionName
        self.localControlAttachment = gateway.restoredLocalMultiplexerAttachment.flatMap { $0.isHerdrControl ? $0 : nil }
        self.hostWindowId = gateway.windowId
        // A restored visible gateway reflects a saved user choice. A saved
        // hidden gateway is handled once projected tabs exist below.
        if localControlAttachment != nil { didAutoHideGateway = true }
    }

    /// Creates the controller for a gateway and opens its control stream.
    /// nil only when the gateway has no Ghostty app yet.
    @discardableResult
    static func start(
        on gateway: Ghostty.TerminalView,
        tabsModel: TabsModel,
        sessionName: String?
    ) -> HerdrController? {
        if let existing = controllers[gateway.uuid] {
            return existing
        }
        guard let controller = HerdrController(gateway: gateway, tabsModel: tabsModel, sessionName: sessionName) else {
            return nil
        }
        controllers[gateway.uuid] = controller
        gateway.herdrController = controller
        #if targetEnvironment(macCatalyst)
        gateway.localMultiplexerTrackingRevision &+= 1
        gateway.localMultiplexerAttachment = nil
        LocalMultiplexerTracker.shared.watch(gateway)
        #endif
        installForegroundObserver()
        controller.markGatewayTab()
        controller.publishSessionState()
        controller.connect()
        return controller
    }

    private static var foregroundObserver: NSObjectProtocol?
    private static var backgroundObserver: NSObjectProtocol?
    private static var terminateObserver: NSObjectProtocol?
    private static var sceneObservers: [NSObjectProtocol] = []

    /// A bridge can outlive the app when its session is persistent, leaving
    /// the server counting a dead client as a viewer that can hold a tab's
    /// geometry. Ask the bridges to go first.
    static func closeAllForTermination() {
        let channels = all.compactMap(\.channel)
        guard !channels.isEmpty else { return }
        let finished = OSAllocatedUnfairLock(initialState: 0)
        for channel in channels {
            Task.detached {
                await channel.close()
                finished.withLock { $0 += 1 }
            }
        }
        // The writes finish on other executors, some behind the main actor:
        // run the loop instead of blocking it, and give up rather than hold
        // up the quit.
        let deadline = Date().addingTimeInterval(1)
        while finished.withLock({ $0 }) < channels.count, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Every controller checks its stream when the app returns to the
    /// foreground; installed once, on the first start.
    private static func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        let center = NotificationCenter.default
        sceneObservers = [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for controller in all { controller.selectedTabDidChange() }
                }
            }
        }
        // A device scene loses the user by backgrounding; a Catalyst window
        // stays foreground and loses it by deactivating. On iOS deactivation
        // would also fire for a banner or Control Center.
        #if targetEnvironment(macCatalyst)
        let sceneEnd = UIScene.willDeactivateNotification
        #else
        let sceneEnd = UIScene.didEnterBackgroundNotification
        #endif
        sceneObservers.append(center.addObserver(
            forName: sceneEnd, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let scene = notification.object as? UIScene else { return }
                for controller in all where controller.activationScene === scene
                    || controller.paneViews.values.contains(where: { $0.window?.windowScene === scene })
                    || controller.gateway?.window?.windowScene === scene {
                    controller.suspendActivation()
                }
            }
        })
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for controller in all {
                    controller.legacySuspended = false
                    controller.applicationDidBecomeActive()
                }
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for controller in all {
                    controller.suspendActivation()
                    // Ghostty suppresses title callbacks while backgrounded.
                    // Let metadata seed titles again until live OSC resumes.
                    for view in controller.paneViews.values { view.endHerdrTitleAttachment() }
                    if controller.mode == .legacy {
                        controller.legacySuspended = true
                        controller.legacyReconcileAttaches()
                    }
                }
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closeAllForTermination() }
        }
    }

    /// The selected tab in `model` changed: its controllers size and attach
    /// the newly visible panes first.
    static func selectedTabDidChange(in model: TabsModel) {
        for controller in all where controller.weakTabsModel === model {
            controller.selectedTabDidChange()
        }
    }

    private func markGatewayTab() {
        guard let gateway,
              let tabID = gateway.containingTabID,
              let tab = tabsModel.tab(withID: tabID) else { return }
        gatewayTabID = tab.id
        tab.isHerdrGateway = true
        tab.herdrSessionName = sessionName ?? "default"
    }

    var gatewayConnectionInfo: ConnectionInfo? {
        gateway?.session?.connectionInfo
    }

    /// herdr layer over the gateway's transport for the Connection Info sheet.
    func connectionInfo(tabID: String?, terminalID: String?) -> ConnectionInfo {
        .herdr(HerdrConnectionInfo(
            gatewayID: gatewayUUID,
            controllerID: connectionInfoID,
            tabID: tabID,
            terminalID: terminalID,
            openedAt: Date()
        ), transport: gatewayConnectionInfo)
    }

    /// Resolves through the registry so a pending or ended gateway still yields
    /// a request the sheet can retry against.
    static func connectionInfo(gatewayUUID: UUID, tabID: String?, terminalID: String?) -> ConnectionInfo {
        if let controller = controllers[gatewayUUID] {
            return controller.connectionInfo(tabID: tabID, terminalID: terminalID)
        }
        return .herdr(HerdrConnectionInfo(
            gatewayID: gatewayUUID,
            controllerID: nil,
            tabID: tabID,
            terminalID: terminalID,
            openedAt: Date()
        ), transport: nil)
    }

    /// Command the exec channel runs on the host.
    private var controlCommand: String {
        SSHConfig.herdrControlCommandLine(sessionName: sessionName, localAttachment: localControlAttachment)
    }

    func connect() {
        guard !didEnd, connectTask == nil else { return }
        connectTask = Task { [weak self] in
            await self?.performConnect()
            self?.connectTask = nil
        }
    }

    private func performConnect() async {
        guard let gateway, !didEnd else { return }
        guard HerdrChannelFactory.canOpen(for: gateway) else {
            Self.logger.info("herdr control: gateway not ready, retrying")
            scheduleReconnect()
            return
        }
        var openingChannel: HerdrControlChannel?
        do {
            #if targetEnvironment(macCatalyst)
            guard try await prepareLocalControlAttachment() else { return }
            #endif
            guard !didEnd, !Task.isCancelled else { return }
            if SettingsStore.shared.value(Settings.System.herdrForceFallback) {
                startLegacyMode(reason: "fallback forced in Debug settings", forced: true)
                return
            }
            let pipe = try await HerdrChannelFactory.open(command: controlCommand, on: gateway)
            // A late callback from an old stream must never reach a newly
            // attached pane, even if the server reuses an attach id.
            let generation = UUID()
            resetPushRouteIdentity()
            streamGeneration = generation
            let router = HerdrOutputRouter()
            self.router = router
            let gatewayUUID = self.gatewayUUID
            // Dropped output leaves a screen nothing downstream can repair;
            // only a fresh snapshot does.
            router.onOverflow = { attachId in
                Task { @MainActor in
                    guard let controller = HerdrController.controller(forGateway: gatewayUUID),
                          controller.streamGeneration == generation else { return }
                    controller.requestSnapshot(attachId: attachId)
                }
            }
            let channel = HerdrControlChannel(
                pipe: pipe,
                onInbound: { inbound in
                    switch inbound {
                    case .output(let attachId, _, let bytes):
                        router.write(attachId: attachId, bytes)
                        return
                    case .snapshot(let record):
                        router.applySnapshot(record)
                    case .authority(let record):
                        router.setQueryAuthority(attachId: record.attach_id, answersQueries: record.answers_queries)
                    case .tabLayout(let layout):
                        // Queue these panes' output on this thread, before
                        // any redraw at the new size can reach a surface
                        // still on the old grid; released once resized.
                        let barrier = router.holdOutput(forPanes: layout.panes.map(\.pane_id))
                        await MainActor.run {
                            guard let controller = HerdrController.controller(forGateway: gatewayUUID),
                                  controller.streamGeneration == generation else { return }
                            controller.handleTabLayout(layout, barrier: barrier)
                        }
                        return
                    case .gap(let gap):
                        // Bytes after a server-side drop must not parse; only
                        // the snapshot requested below rebuilds the screen.
                        router.invalidate(attachId: gap.attach_id)
                    default:
                        break
                    }
                    await MainActor.run {
                        guard let controller = HerdrController.controller(forGateway: gatewayUUID),
                              controller.streamGeneration == generation else { return }
                        controller.handleInbound(inbound)
                    }
                },
                onClosed: { error in
                    Task { @MainActor in
                        guard let controller = HerdrController.controller(forGateway: gatewayUUID),
                              controller.streamGeneration == generation else { return }
                        controller.channelDidClose(error)
                    }
                }
            )
            openingChannel = channel
            let opened = try await withTaskCancellationHandler {
                try await channel.open()
            } onCancel: {
                Task { await channel.abort() }
            }
            guard !didEnd, !Task.isCancelled else {
                await channel.close()
                return
            }
            self.channel = channel
            openingChannel = nil
            let previousBoot = bootId
            bootId = opened.boot_id
            serverVersion = opened.version
            serverPid = opened.capabilities?.server_pid
            controlOpened = opened
            controlOpenedAt = Date()
            capabilities = HerdrServerCapabilities(opened.capabilities)
            router.configureQueryAuthority(enabled: capabilities.supports(.queryAuthority))
            reconnectAttempt = 0
            Self.logger.info("herdr control open: \(opened.version) boot=\(opened.boot_id) pid=\(opened.capabilities?.server_pid ?? 0) stream=\(self.capabilities.streamProtocol) features=\(self.capabilities.sortedFeatures.joined(separator: ","))")
            setUpgradePrompt(capabilities.supportsSharedViewing ? nil : .sharedViewingNeedsUpgrade)

            try await channel.request(
                "events.subscribe",
                HerdrControl.SubscribeParams(subscriptions: HerdrControl.topologySubscriptions)
            )
            if capabilities.supports(.geometryOwnership) {
                _ = try? await channel.request("events.subscribe", HerdrControl.SubscribeParams(subscriptions: [
                    HerdrControl.Subscription(type: "tab.geometry_changed")
                ]))
            }
            let statusRevision = agentStatusRevision
            let snapshot = try await channel.request(
                "session.snapshot",
                HerdrControl.EmptyParams(),
                as: HerdrControl.SessionSnapshotResult.self
            ).snapshot
            guard self.channel === channel else { return }
            if let previousBoot, previousBoot != opened.boot_id {
                tabNames = HerdrTabNames()
                takeoverRequested.removeAll()
                Self.logger.info("herdr server restarted (boot \(previousBoot) -> \(opened.boot_id)); rebuilding")
            }
            isActive = true
            connectionError = nil
            refreshPushRouteIdentity()
            applySnapshot(snapshot, preservingAgentUpdatesAfter: statusRevision)
            subscribeAgentStatus()
            // Optional additions must not make an older control server fail
            // its otherwise compatible topology subscription handshake.
            let optionalSubscriptions = ["worktree.created", "worktree.opened", "worktree.removed", "workspace.metadata_updated"]
            Task {
                try? await channel.request("events.subscribe", HerdrControl.SubscribeParams(subscriptions:
                    optionalSubscriptions.map { HerdrControl.Subscription(type: $0) }))
            }
            refreshOtherConnections()
            startHealthPing(on: channel)
            NotificationCenter.default.post(name: .herdrControlStateDidChange, object: gatewayUUID)
        } catch {
            await openingChannel?.abort()
            guard !didEnd else { return }
            if refuseUnsupportedVersion(error) { return }
            Self.logger.error("herdr control connect failed: \(error.localizedDescription)")
            connectionError = error.localizedDescription
            isActive = false
            publishSessionState()
            if let channel {
                await channel.close()
                self.channel = nil
            }
            switch error {
            case HerdrChannelError.herdrMissing(let why):
                gateway.writeToGhostty(string: "\r\n\u{1b}[33mherdr control mode: \(why).\u{1b}[0m\r\n")
                stop()
                presentUpgradeAlert(.herdrMissing)
            case HerdrChannelError.unsupportedServer(let why):
                startLegacyMode(reason: why)
            default:
                scheduleReconnect()
            }
        }
    }

    /// Version failures end this attach attempt; neither fallback nor retries
    /// can make an older running server compatible.
    @discardableResult
    func refuseUnsupportedVersion(_ error: Error) -> Bool {
        guard let error = error as? HerdrVersionError else { return false }
        guard !didEnd else { return true }
        let gateway = self.gateway
        gateway?.herdrAutoAttachSuppressed = true
        Self.logger.error("herdr attachment refused: \(error.localizedDescription)")
        let prompt = HerdrUpgradePrompt.versionTooOld(reported: error.reported)
        stop()
        gateway?.writeToGhostty(string: "\r\n\(error.localizedDescription)\r\n")
        presentUpgradeAlert(prompt)
        return true
    }

    /// One retrying subscription task per connection. A vanished pane may
    /// reject a batch, so rebuild it from the live topology on every attempt.
    func subscribeAgentStatus() {
        guard mode == .raw, let channel, isActive, agentSubscriptionTask == nil else { return }
        agentSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.channel === channel { self.agentSubscriptionTask = nil } }
            var retryDelay = 0.5
            while self.channel === channel, !Task.isCancelled {
                let pending = Set(self.paneInfos.keys).subtracting(self.subscribedAgentPanes)
                guard !pending.isEmpty else { return }
                do {
                    try await channel.request("events.subscribe", HerdrControl.SubscribeParams(subscriptions:
                        pending.sorted().map { .init(type: "pane.agent_status_changed", pane_id: $0) }))
                    guard self.channel === channel, !Task.isCancelled else { return }
                    self.subscribedAgentPanes.formUnion(pending)
                    // Close the interval between the initial snapshot and the
                    // subscription ACK without overwriting newer pushed events.
                    self.refreshTopology()
                    retryDelay = 0.5
                } catch {
                    guard self.channel === channel, !Task.isCancelled else { return }
                    Self.logger.warning("herdr agent-status subscription failed; retrying: \(error.localizedDescription)")
                    self.refreshTopology()
                    do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
                    retryDelay = min(5, retryDelay * 2)
                }
            }
        }
    }

    func subscribeAgentStatus(paneId: String) {
        subscribedAgentPanes.remove(paneId)
        subscribeAgentStatus()
    }

    private func startHealthPing(on channel: HerdrControlChannel) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.healthInterval)
                guard let self, self.channel === channel else { return }
                if Ghostty.isAppBackgroundedAtomic { continue }
                do {
                    try await channel.request("ping", HerdrControl.EmptyParams(), timeout: .seconds(10))
                } catch {
                    Self.logger.warning("herdr health ping failed: \(error.localizedDescription)")
                    await self.streamDidFail(channel, error: error)
                    return
                }
            }
        }
    }

    /// Closes a stream we decided is dead. `close()` suppresses the reader's
    /// own closed callback, so the recovery path is driven from here.
    private func streamDidFail(_ channel: HerdrControlChannel, error: Error) async {
        // No graceful close here: the writer may be the thing that is stuck.
        await channel.abort()
        guard self.channel === channel else { return }
        channelDidClose(error)
    }

    /// Ends control mode for every gateway hosted in a window being torn
    /// down, while its tabs model is still alive.
    static func stopAll(inWindow windowId: String) {
        for controller in all where controller.hostWindowId == windowId {
            controller.stop()
        }
    }

    /// A pane's output writer dropped bytes: its screen is unreliable until
    /// the server re-snapshots it.
    func pipelineDidOverflow(terminalId: String) {
        guard !didEnd else { return }
        if mode == .legacy {
            if !endpointUnsupported {
                endpoint?.close(error: HerdrEndpointWire.Failure.invalid("surface output dropped; reconnecting for a full frame"))
                return
            }
            // A new attach starts with a complete rendered frame. Continuing
            // incremental output after lost bytes would leave a damaged screen.
            legacyCloseStream(terminalId)
            legacyReconcileAttaches()
        } else if let attachId = attachIds[terminalId] {
            requestSnapshot(attachId: attachId)
        }
    }

    func channelDidClose(_ error: Error?) {
        guard !didEnd else { return }
        Self.logger.warning("herdr control stream closed: \(error?.localizedDescription ?? "eof")")
        healthTask?.cancel()
        channel = nil
        isActive = false
        controlOpened = nil
        controlOpenedAt = nil
        capabilities = .none
        otherConnections = []
        connectionError = error?.localizedDescription
        detachAllLocally()
        publishSessionState()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !didEnd, reconnectTask == nil else { return }
        // Gateway gone (tab closed) or its session dead: control mode is over.
        guard let gateway, gateway.surface != nil else {
            stop()
            return
        }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        Self.logger.info("herdr control reconnect in \(delay)s (attempt \(self.reconnectAttempt))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if Ghostty.isAppBackgroundedAtomic {
                // Wait for the foreground; the resume path reconnects.
                self.scheduleReconnect()
                return
            }
            self.connect()
        }
    }

    /// The app came back to the foreground: verify the stream is alive.
    func applicationDidBecomeActive() {
        guard !didEnd else { return }
        refreshPushRouteIdentity()
        // Returning to the app is intent to use the selected tab here. Only
        // the controller whose window took key claims; the others re-check
        // their sizes and attaches.
        if mode == .raw, capabilities.supportsSharedViewing { selectedTabDidChange() }
        if mode == .legacy {
            Task { [weak self] in
                await self?.legacyPollOnce()
                self?.legacyReconcileAttaches()
            }
            return
        }
        if channel == nil {
            reconnectTask?.cancel()
            reconnectTask = nil
            connect()
            return
        }
        for terminalId in attachIds.keys {
            if let view = paneViews[terminalId], view.herdrTitleState.attachmentID == nil {
                view.beginHerdrTitleAttachment()
            }
        }
        // An idle application's last title may have arrived while Ghostty's
        // background gate discarded callbacks, with no further OSC to replay.
        refreshTopology()
        Task { [weak self] in
            guard let self, let channel = self.channel else { return }
            do {
                try await channel.request("ping", HerdrControl.EmptyParams(), timeout: .seconds(5))
            } catch {
                await self.streamDidFail(channel, error: error)
            }
        }
    }

    /// User-initiated detach: ends control mode, optionally closing the
    /// gateway tab too. The herdr session keeps running on the host.
    func detach(closeGateway: Bool, announce: Bool = true) {
        let gatewayView = gateway
        let windowId = hostWindowId
        // Same choke point as tmux `requestGracefulDetach`: menu, ESC, and
        // Detach Session all show the reconnect banner.
        if announce, isActive || !didEnd {
            MuxSessionDetach.notifyControlModeDetached(
                type: .herdr,
                sessionName: sessionName,
                windowId: windowId,
                terminal: gatewayView
            )
        }
        stop()
        guard closeGateway, let gatewayView else { return }
        // Same routing a dying tab uses: the .closeSplit observer resolves
        // the window from the posted view and runs the normal cleanup.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .closeSplit,
                object: gatewayView,
                userInfo: ["windowId": windowId]
            )
        }
    }

    /// Whether the gateway tab is hidden, manually or by the auto-hide setting.
    var isGatewayTabHidden: Bool {
        gatewayTabID.flatMap { tabsModel.tab(withID: $0) }?.isHiddenTmuxWindow == true
    }

    private var firstVisibleWindowTab: TabModel? {
        let mine = Set(tabs.values.map(\.id))
        return tabsModel.tabs.first { mine.contains($0.id) && !$0.isHiddenTmuxWindow }
    }

    /// Keep a visible projected tab so a hidden gateway's session stays reachable.
    var canHideGatewayTab: Bool {
        isActive && !didEnd && firstVisibleWindowTab != nil
            && gatewayTabID.flatMap { tabsModel.tab(withID: $0) }?.isHiddenTmuxWindow == false
    }

    /// Client-local visibility only; the control stream and its panes keep running.
    func hideGatewayTab() {
        guard isActive, !didEnd,
              let gatewayTabID, let gatewayTab = tabsModel.tab(withID: gatewayTabID),
              !gatewayTab.isHiddenTmuxWindow,
              let first = firstVisibleWindowTab else { return }
        didAutoHideGateway = true
        rehideGatewayAfterEmpty = false
        gatewayTab.isHiddenTmuxWindow = true
        if tabsModel.selectedTabID == gatewayTab.id {
            tabsModel.selectedTabID = first.id
            tabsModel.pendingScrollToTabID = first.id
        }
    }

    func showGatewayTab() {
        rehideGatewayAfterEmpty = false
        didAutoHideGateway = true
        guard let gatewayTabID, let tab = tabsModel.tab(withID: gatewayTabID) else { return }
        tab.isHiddenTmuxWindow = false
        tabsModel.selectedTabID = tab.id
        tabsModel.pendingScrollToTabID = tab.id
    }

    /// Opt-in: once projected tabs exist, hide the gateway shell tab and land
    /// on the first projected tab. One-shot so a later "Show Gateway Tab"
    /// sticks.
    func autoHideGatewayIfWanted() {
        if let gatewayTabID, let tab = tabsModel.tab(withID: gatewayTabID),
           tab.pendingHiddenTmuxGatewayRestore, !tabs.isEmpty {
            tab.pendingHiddenTmuxGatewayRestore = false
            hideGatewayTab()
            return
        }
        guard !didAutoHideGateway || rehideGatewayAfterEmpty,
              SettingsStore.shared.value(Settings.Multiplexer.herdrAutoHideGatewayOnAttach) else { return }
        hideGatewayTab()
    }

    /// Ends control mode for this gateway: closes the stream and removes the
    /// projected tabs.
    func stop() {
        guard !didEnd else { return }
        didEnd = true
        isActive = false
        cancelNewTabRequests()
        healthTask?.cancel()
        connectTask?.cancel()
        reconnectTask?.cancel()
        focusWatchdog?.cancel()
        for task in geometryTasks.values { task.cancel() }
        let channel = self.channel
        self.channel = nil
        Task { await channel?.close() }
        stopLegacyMode()
        detachAllLocally()
        pruneAll()
        Self.controllers.removeValue(forKey: gatewayUUID)
        if let gateway {
            gateway.herdrController = nil
            gateway.updateHerdrGatewayOverlay()
            #if targetEnvironment(macCatalyst)
            gateway.localMultiplexerTrackingRevision &+= 1
            gateway.localMultiplexerAttachment = nil
            #endif
        }
        if let gatewayTabID, let tab = tabsModel.tab(withID: gatewayTabID) {
            tab.isHerdrGateway = false
            tab.herdrSessionName = nil
            if tab.isHiddenTmuxWindow {
                tab.isHiddenTmuxWindow = false
            }
            if !tabsModel.tabs.contains(where: { $0.id == tabsModel.selectedTabID }) {
                tabsModel.selectedTabID = tab.id
            }
        }
        NotificationCenter.default.post(name: .herdrControlModeDidEnd, object: gatewayUUID)
        NotificationCenter.default.post(name: .herdrControlStateDidChange, object: gatewayUUID)
    }

    /// Drops attach bookkeeping after the stream died; surfaces stay so the
    /// reconnect can re-snapshot them in place.
    /// A `tab.layout` record whose panes' output the router holds behind
    /// `barrier`. Whatever applying it does, the barrier ends: tracked by
    /// the release the layout armed, or released right here.
    func handleTabLayout(_ layout: HerdrControl.LayoutSnapshot, barrier: UInt64) {
        guard !didEnd else {
            router.release(barrier: barrier)
            return
        }
        for pane in layout.panes {
            if let terminalID = paneInfos[pane.pane_id]?.terminal_id {
                paneSessions[terminalID]?.readFence = nil
                paneSessions[terminalID]?.invalidateParserGrid()
                if let attachID = attachIds[terminalID] {
                    router.updateGrid(attachId: attachID, cols: 0, rows: 0)
                }
            }
        }
        controlLayouts[layout.tab_id] = layout
        applyGeometryController(layout.geometry_controller, tabId: layout.tab_id, carried: layout.carriesRealGeometry)
        applyLayout(layout, barrier: barrier)
        if layoutReleases[barrier] == nil {
            router.release(barrier: barrier)
        }
        // Applying the layout can make an already-parsed grid ready without
        // another size callback. Drain recovery work on this transition too.
        requestSnapshotsForReadyPanes()
    }

    private func detachAllLocally() {
        resetPushRouteIdentity()
        agentSubscriptionTask?.cancel()
        agentSubscriptionTask = nil
        subscribedAgentPanes.removeAll()
        agentStatusRevisions.removeAll()
        streamGeneration = UUID()
        suspendActivation()
        for view in paneViews.values { view.endHerdrTitleAttachment() }
        cancelNewTabRequests()
        tabReorderTask?.cancel()
        tabReorderTask = nil
        pendingTabReorders.removeAll()
        management.pending.removeAll()
        managementRevision &+= 1
        tabOrderDeferredForDrag = false
        topologyRefreshTask?.cancel()
        topologyRefreshTask = nil
        topologyRefreshWanted = false
        for task in attachRetries.values { task.cancel() }
        attachRetries.removeAll()
        for task in geometryTasks.values { task.cancel() }
        geometryTasks.removeAll()
        for release in layoutReleases.values { release.deadline?.cancel() }
        layoutReleases.removeAll()
        router.removeAll()
        attachIds.removeAll()
        terminalByAttach.removeAll()
        attachAnswersQueries.removeAll()
        attachQueue.removeAll()
        attachesInFlight.removeAll()
        snapshotRequestsInFlight.removeAll()
        snapshotRetryWanted.removeAll()
        tabGeometryStates.removeAll()
        controlLayouts.removeAll()
        panesNeedingSnapshot.removeAll()
        clientDetourMinimums.removeAll()
        // The other client may be gone by the time we reconnect; the next
        // attach pass finds out and prompts again if it is not.
        clearPaneControlStates()
        takeControlPromptedTabs.removeAll()
        for session in paneSessions.values {
            session.attachId = nil
        }
    }

    // MARK: - Inbound dispatch

    func handleInbound(_ inbound: HerdrControl.Inbound) {
        guard !didEnd else { return }
        switch inbound {
        case .opened:
            break
        case .output:
            break
        case .snapshot(let record):
            snapshotDidArrive(record)
        case .gap(let gap):
            requestSnapshot(attachId: gap.attach_id)
        case .detached(let detached):
            attachDidDetach(detached)
        case .tabLayout(let layout):
            // Delivered through handleTabLayout with its barrier.
            applyLayout(layout)
        case .layoutUpdated(let layout):
            // The generic event carries outer rectangles; a `tab.layout`
            // record with the inner ones follows every resize. Only let the
            // event through when the pane set itself changed, so the two do
            // not fight over ratios.
            if let last = lastLayouts[layout.tab_id],
               last.zoomed == layout.zoomed,
               last.focused_pane_id == layout.focused_pane_id,
               last.panes.map(\.pane_id) == layout.panes.map(\.pane_id) {
                applyGeometryController(layout.geometry_controller, tabId: layout.tab_id, carried: layout.carriesRealGeometry)
                break
            }
            applyLayout(layout)
        case .tabGeometryChanged(let change):
            geometryControllerDidChange(change)
        case .authority(let record):
            Self.logger.info("herdr query authority \(record.attach_id): \(record.answers_queries)")
            attachAnswersQueries[record.attach_id] = record.answers_queries
        case .eventsGap(let gap):
            Self.logger.warning("herdr events gap: dropped \(gap.dropped ?? 0)")
            refreshTopology()
        case .paneCreated(let pane):
            paneDidAppear(pane)
            refreshTopology()
        case .paneUpdated(let pane):
            paneDidUpdate(pane)
        case .paneClosed(let closed):
            paneDidClose(paneId: closed.pane_id)
        case .paneExited(let exited):
            // Natural shell exit need not emit pane.closed or tab.closed.
            // Reconcile the surviving topology, including the last tab and
            // workspace, without sending a close command back to the server.
            paneDidClose(paneId: exited.pane_id)
        case .paneFocused(let focused):
            remoteFocusDidChange(paneId: focused.pane_id)
        case .paneMoved(let moved):
            paneDidMove(moved)
        case .tabCreated(let tab):
            ensureTab(tab)
            reorderTabs()
            refreshTopology()
        case .tabClosed(let closed):
            tabDidClose(tabId: closed.tab_id)
        case .tabRenamed(let renamed):
            tabDidRename(tabId: renamed.tab_id, label: renamed.label)
        case .tabFocused(let focused):
            remoteTabFocusDidChange(tabId: focused.tab_id)
        case .tabMoved(let moved):
            applyTabOrder(moved.tabs, workspaceID: moved.workspace_id)
        case .workspaceCreated(let workspace), .workspaceUpdated(let workspace):
            workspaces[workspace.workspace_id] = workspace
            refreshWorkspaceGroups()
            publishSessionState()
        case .workspaceClosed(let closed):
            workspaces.removeValue(forKey: closed.workspace_id)
            refreshTopology()
        case .workspaceRenamed(let renamed):
            if var workspace = workspaces[renamed.workspace_id] {
                workspace.label = renamed.label
                workspaces[renamed.workspace_id] = workspace
                refreshWorkspaceGroups()
            }
        case .workspaceFocused(let focused):
            for id in Array(workspaces.keys) { workspaces[id]?.focused = id == focused.workspace_id }
            publishSessionState()
        case .workspaceReordered, .worktreesChanged:
            refreshTopology()
        case .agentStatusChanged(let change):
            agentStatusDidChange(change)
        case .unknown(let what):
            Self.logger.debug("herdr control: ignored \(what)")
        }
    }

    /// Re-fetches the whole snapshot; used when an event carries less than
    /// we need (workspace reorders) or after a gap in topology events.
    func refreshTopology() {
        if mode == .legacy {
            Task { [weak self] in await self?.legacyPollOnce() }
            return
        }
        guard let channel, isActive else { return }
        topologyRefreshWanted = true
        guard topologyRefreshTask == nil else { return }
        topologyRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.channel === channel { self.topologyRefreshTask = nil } }
            while self.topologyRefreshWanted, !Task.isCancelled, self.channel === channel {
                self.topologyRefreshWanted = false
                let managementRevision = self.managementRevision
                let statusRevision = self.agentStatusRevision
                do {
                    let snapshot = try await channel.request(
                        "session.snapshot", HerdrControl.EmptyParams(),
                        as: HerdrControl.SessionSnapshotResult.self
                    ).snapshot
                    guard self.channel === channel, !Task.isCancelled else { return }
                    guard managementRevision == self.managementRevision, !self.management.isBusy else { continue }
                    self.applySnapshot(snapshot, preservingAgentUpdatesAfter: statusRevision)
                } catch {
                    guard self.channel === channel, !Task.isCancelled else { return }
                    if self.refuseUnsupportedVersion(error) { return }
                    Self.logger.warning("herdr topology refresh failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
