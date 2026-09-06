//
//  VNCPaneView.swift
//  rootshell
//
//  Screen Sharing / VNC pane: a SplitPaneView leaf hosting the package's
//  RemoteDesktopView through a child UIHostingController.
//

import SwiftUI
import UIKit
import Combine
import os
import rootshellVNC
import RFBTransport

/// Handshake-level presets exposed by the in-session HUD. Full Quality stays
/// available in the connection editor, but is intentionally not part of this
/// quick switch.
fileprivate enum VNCQuickMode: CaseIterable, Hashable {
    case standard
    case highPerformanceRemote
    case highPerformanceMatchClient

    init?(configuration: VNCConfiguration) {
        switch configuration.videoQualityMode {
        case .standard:
            self = .standard
        case .adaptive:
            self = configuration.displaySizingMode == .matchClient
                ? .highPerformanceMatchClient
                : .highPerformanceRemote
        case .fullQuality:
            return nil
        }
    }

    var title: String {
        switch self {
        case .standard:
            return String(localized: "Standard", comment: "VNC HUD quick mode")
        case .highPerformanceRemote:
            return String(localized: "High Performance · Remote Display", comment: "VNC HUD quick mode")
        case .highPerformanceMatchClient:
            return String(localized: "High Performance · Match Client", comment: "VNC HUD quick mode")
        }
    }

    var systemImage: String {
        switch self {
        case .standard:
            return "network"
        case .highPerformanceRemote:
            return "display"
        case .highPerformanceMatchClient:
            return "rectangle.inset.filled"
        }
    }

    var requiresHighPerformance: Bool {
        self != .standard
    }

    func apply(to configuration: inout VNCConfiguration) {
        switch self {
        case .standard:
            configuration.videoQualityMode = .standard
        case .highPerformanceRemote:
            configuration.videoQualityMode = .adaptive
            configuration.displaySizingMode = .remoteDisplay
        case .highPerformanceMatchClient:
            configuration.videoQualityMode = .adaptive
            configuration.displaySizingMode = .matchClient
        }
    }
}

/// A split-tree pane rendering a VNC / Apple Screen Sharing session.
/// Owns the session and keyboard-capture objects for its lifetime; each
/// pane is an independent session (splits never share one).
final class VNCPaneView: SplitPaneView, ObservableObject {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VNCPaneView")

    /// Restoration flow marker. Panes created from the connection UI are
    /// `.none`; window-state restore stamps `.pendingReconnect`, cleared on
    /// the first connect attempt (`didMoveToWindow` → `connectIfNeeded`).
    enum RestorationState {
        case none
        case pendingReconnect
    }

    let config: VNCConnectionConfig
    let session: VNCSession
    let clipboardSynchronizer: VNCClipboardSynchronizer
    let keyboardCapture: VNCKeyboardCapture
    fileprivate let initialViewportPanningMode: RemoteViewportPanningMode

    private let clipboardSyncDefault: ScreenSharingClipboardSyncDefault
    private var clipboardSyncUsesGlobalPolicy = true

    /// Tab title: starts as the config's display name and upgrades to the
    /// server-reported desktop name once connected.
    @Published private(set) var displayTitle: String {
        didSet { refreshPanePresentationTitle() }
    }

    /// Shows the in-pane password prompt when no saved password exists.
    @Published private(set) var needsPassword = false

    /// Launcher failure (jump profile missing, jump key unresolved, jump
    /// password load failed) surfaced before the package session ever
    /// starts, so the package's own recovery overlay can't render it.
    @Published private(set) var launchErrorMessage: String?

    /// True while jump credentials and the custom transport are being
    /// prepared, before VNCSession can transition from `.idle` to
    /// `.connecting`. Keeps the initial attempt visible from the moment the
    /// pane opens, including Keychain and tunnel setup work.
    @Published private(set) var isPreparingConnection = false

    /// Host-key validation for jump tunnels, injected at creation
    /// (MainViewVNC.makeVNCPane) so prompts route through the same
    /// per-window alert mechanism as SSH tabs.
    var onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// VeNCrypt X.509 trust decisions, injected by MainView so self-signed
    /// Linux VNC servers use the same per-window prompt queue as SSH hosts.
    var onCertificateValidation: VNCConfiguration.CertificateValidationHandler?

    /// Manual tab rename wins over server-name title upgrades.
    var userOverrideTitle: String? {
        didSet { refreshPanePresentationTitle() }
    }

    /// Profile that created this pane (usage recording, future editing).
    var sourceProfileID: UUID?

    var restorationState: RestorationState = .none

    /// Runtime override of the configured keyboard-toolbar preference, set
    /// by the HUD menu toggle. Never persisted; the connection form and
    /// profile editor own the stored setting.
    @Published private var keyboardToolbarOverride: VNCConnectionConfig.KeyboardToolbarPreference?

    var effectiveKeyboardToolbarPreference: VNCConnectionConfig.KeyboardToolbarPreference {
        keyboardToolbarOverride ?? config.keyboardToolbar
    }

    func setKeyboardToolbarEnabled(_ enabled: Bool) {
        keyboardToolbarOverride = enabled ? .on : .off
        keyboardCoordinator?.toolbarPreferenceDidChange()
    }

    fileprivate func sharedClipboardDidChangeByUser() {
        clipboardSyncUsesGlobalPolicy = false
    }

    private func applyClipboardSyncDefault(
        encryption: VNCContentEncryption?
    ) {
        guard clipboardSyncUsesGlobalPolicy else { return }

        let shouldEnable: Bool
        switch clipboardSyncDefault {
        case .off:
            shouldEnable = false
        case .alwaysOn:
            shouldEnable = true
        case .automatic:
            if config.effectiveJump != .none {
                shouldEnable = true
            } else {
                switch encryption {
                case .tlsX509?, .appleComCryption?:
                    shouldEnable = true
                case VNCContentEncryption.none?, nil:
                    shouldEnable = false
                }
            }
        }

        if clipboardSynchronizer.sharedClipboardEnabled != shouldEnable {
            clipboardSynchronizer.sharedClipboardEnabled = shouldEnable
        }
    }

    /// Apply a HUD quick-mode preset and restart the live session. The pane's
    /// persisted config remains untouched; VNCSession retains the active
    /// credentials across this handshake-level reconnect.
    fileprivate func switchQuickMode(_ mode: VNCQuickMode) {
        var configuration = session.configuration
        mode.apply(to: &configuration)
        _ = session.reconnect(with: configuration)
    }

    /// One-shot password handed over by a profile password prompt when the
    /// user chose not to save it. Consumed by the first connect attempt.
    var pendingPassword: String?

    /// Window this pane currently belongs to, including its theme context.
    private(set) var windowId: String {
        didSet { objectWillChange.send() }
    }

    override var containingTabID: UUID? {
        didSet { objectWillChange.send() }
    }

    /// Set by PaneFullScreenController while this pane is checked out for
    /// the in-window full-screen takeover, so close/retarget flows can reach
    /// the controller for teardown.
    weak var fullScreenController: PaneFullScreenController?

    /// Mirror the base-class detach flag into SwiftUI (the HUD's Enter/Exit
    /// Full Screen title) through this pane's ObservableObject conformance.
    override var isDetachedForFullScreen: Bool {
        didSet {
            guard oldValue != isDetachedForFullScreen else { return }
            objectWillChange.send()
        }
    }

    /// On-screen keyboard toolbar bridge (nil on visionOS: hidden in v1).
    private(set) var keyboardCoordinator: VNCKeyboardAccessoryCoordinator?

    private var hostingController: UIHostingController<VNCPaneRootView>?
    /// Hosting controller and auto-dismiss task for the shared HDR brightness
    /// HUD while this VNC pane is focused.
    var brightnessHUDHost: UIHostingController<BrightnessBoostHUDView>?
    var brightnessHUDHideTask: Task<Void, Never>?
    private var hasStartedConnect = false
    private var connectionTask: Task<Void, Never>?
    /// Periodic health line for the Screen Sharing debug log. Only does work
    /// while that log is enabled; see `startDebugHeartbeatIfNeeded`.
    private var debugHeartbeatTask: Task<Void, Never>?
    /// Last connection state written to the debug log, so the heartbeat can
    /// record transitions without duplicating the steady state.
    private var lastLoggedConnectionState: String?
    private var overlayOwnsKeyboard = false

    /// Pre-release snapshot of the keyboard toolbar reserve, held while an
    /// overlay owns the keyboard (the coordinator reports zero once capture
    /// is released). See `reservedKeyboardToolbarHeightAtBottom`.
    private var overlayLatchedToolbarReserve: CGFloat = 0

    /// Pre-release snapshot of the package's software-keyboard request. The
    /// package's own keyboardWillHide observer treats the overlay-driven hide
    /// as a user dismissal and clears `softwareKeyboardRequested`, so
    /// re-capturing alone brings the keyboard back OFF after a settings round
    /// trip. Restored on the falling edge once capture sticks.
    private var overlayLatchedSoftwareKeyboardRequested = false
    private var windowIsActive = true
    private var isClosed = false
    private var closeRequested = false
    /// Remains false while an auto-enter request is waiting for this pane to
    /// become the selected tab's focused leaf (notably during state restore).
    private var hasHandledAutomaticFullScreen = false
    /// A tab switch temporarily exits the window-level takeover so another
    /// tab can render. Returning to this pane should restore that takeover,
    /// independent of the profile's initial auto-full-screen preference.
    private var shouldRestoreFullScreenAfterTabSwitch = false

    /// iPhone-only 3-finger app-tab swipe (see installTabSwipeGestureIfNeeded).
    private var tabSwipePanGesture: UIPanGestureRecognizer?
    private var activeAppTabSwipeDirection: SwipeDirection?
    private var activeAppTabSwipeAccepted = false

    init(config: VNCConnectionConfig, windowId: String, uuid: UUID = UUID()) {
        self.config = config
        self.clipboardSyncDefault = ScreenSharingClipboardSyncDefault.current
        switch ScreenSharingPanningDefault.current {
        case .edge:
            self.initialViewportPanningMode = .edge
        case .continuous:
            self.initialViewportPanningMode = .continuous
        }
        let session = VNCSession(configuration: config.toPackageConfiguration())
        self.session = session
        self.clipboardSynchronizer = VNCClipboardSynchronizer(session: session)
        // Ordinary VNC hardware input is always active for the focused pane.
        // The user-facing toggle chooses the destination for four reserved
        // host chords; its own shortcut always remains local.
        let keyboardCapture = VNCKeyboardCapture(
            isCaptured: true,
            automaticallyCapturesOnInteraction: true,
            reservedHostShortcuts: [
                // Capture-mode control itself remains app-only.
                VNCHostKeyboardShortcut(input: "m", modifiers: [.command, .shift]),
                VNCHostKeyboardShortcut(input: "\\", modifiers: [.command, .shift]),
                VNCHostKeyboardShortcut(input: ",", modifiers: [.command]),
                VNCHostKeyboardShortcut(input: "[", modifiers: [.command, .shift]),
                VNCHostKeyboardShortcut(input: "]", modifiers: [.command, .shift]),
            ]
        )
        keyboardCapture.controlOptionAsCommand = SettingsStore.shared.value(
            Settings.ScreenSharing.controlOptionAsCommandDefault)
        keyboardCapture.routeReservedHostShortcutsToVNC(SettingsStore.shared.value(
            Settings.ScreenSharing.routeReservedShortcutsToVNCDefault))
        self.keyboardCapture = keyboardCapture
        self.displayTitle = config.displayName
        self.windowId = windowId
        super.init(uuid: uuid, frame: .zero)
        refreshPanePresentationTitle()

        backgroundColor = .black

        // New panes do not participate until MainView stamps their logical
        // focus and window-active state and they join the hierarchy.
        clipboardSynchronizer.setHostFocused(false)
        clipboardSynchronizer.setHostWindowActive(false)
        applyClipboardSyncDefault(encryption: session.negotiatedContentEncryption)
        let sessionLabel = config.displayName
        clipboardSynchronizer.onTransfer = { direction, text in
            let source: ClipboardEntry.Source = switch direction {
            case .deviceToRemote:
                .paste
            case .remoteToDevice:
                .osc52(sessionLabel: sessionLabel)
            }
            ClipboardHistoryManager.shared.record(text, source: source)
        }

        // The package owns these exact physical chords on its focused
        // responder, then hands them back here to choose exactly one
        // destination: rootshell or VNC.
        keyboardCapture.onReservedHostShortcut = { [weak self] shortcut in
            self?.handleReservedHostShortcut(shortcut)
        }

        observeSession()
        installTabSwipeGestureIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !isClosed else { return }
        if isLogicallyFocused, !overlayOwnsKeyboard {
            keyboardCapture.capture()
        } else {
            keyboardCapture.release()
        }
        clipboardSynchronizer.setHostFocused(isLogicallyFocused)
        clipboardSynchronizer.setHostWindowActive(windowIsActive)
        attachHostingControllerIfNeeded()
        #if !os(visionOS)
        if keyboardCoordinator == nil {
            keyboardCoordinator = VNCKeyboardAccessoryCoordinator(pane: self)
        }
        #endif
        connectIfNeeded()
    }

    /// Bottom inset the keyboard toolbar reserves when pinned at the bottom
    /// edge (toolbar-only mode, or toolbar visible without a docked
    /// software keyboard). Read by the selected tab's layout in
    /// `terminalTabsView`.
    override var reservedKeyboardToolbarHeightAtBottom: CGFloat {
        // Hold the pre-release reserve while an overlay owns the keyboard
        // (mirrors Ghostty.TerminalView) so hardware/accessory-only layouts
        // don't collapse and regrow across the overlay round trip. Inert as
        // soon as capture returns — the live value wins while captured.
        if !keyboardCapture.isCaptured, overlayLatchedToolbarReserve > 0 {
            return overlayLatchedToolbarReserve
        }
        return keyboardCoordinator?.reservedToolbarHeightAtBottom ?? 0
    }

    /// Adopt the hosting controller as a proper child VC once we're in a
    /// window (same responder-chain discovery as DraggableHUDContainer) so
    /// the package's input responder and Menu presentation work reliably.
    private func attachHostingControllerIfNeeded() {
        guard hostingController == nil,
              let parent = nearestViewController() else { return }

        let controller = UIHostingController(rootView: VNCPaneRootView(pane: self))
        controller.view.backgroundColor = .clear
        parent.addChild(controller)
        addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        controller.didMove(toParent: parent)
        hostingController = controller
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    /// Re-home the child hosting controller under a new parent VC. Used when
    /// the pane moves to another window or into a full-screen takeover: the
    /// attach-time parent stops being an ancestor, and Menu presentation plus
    /// the input responder need a valid VC chain. The view stays parented to
    /// the pane.
    func rehostHostingController(under parent: UIViewController) {
        guard let controller = hostingController, controller.parent !== parent else { return }
        controller.willMove(toParent: nil)
        controller.removeFromParent()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    /// Restore VC parentage to the pane's current ancestor after the
    /// full-screen exit re-attached it to normal split layout.
    func rehostHostingControllerToCurrentAncestor() {
        guard let parent = nearestViewController() else { return }
        rehostHostingController(under: parent)
    }

    // MARK: - Connection

    /// Kick off the first connect: resolve the password (pending handoff →
    /// none-security empty → Keychain) and connect. A missing password
    /// surfaces the in-pane prompt instead of a doomed attempt.
    func connectIfNeeded() {
        guard !hasStartedConnect, !isClosed, !needsPassword,
              launchErrorMessage == nil else { return }

        let password: String
        if let pending = pendingPassword {
            pendingPassword = nil
            password = pending
        } else if let stashed = VNCPasswordManager.shared.takeEphemeralPassword(for: config.passwordKey) {
            password = stashed
        } else if config.security == .none {
            password = ""
        } else if VNCPasswordManager.shared.hasPassword(for: config) {
            do {
                password = try VNCPasswordManager.shared.loadPassword(for: config)
            } catch {
                Self.logger.error("VNC password load failed: \(error.localizedDescription)")
                needsPassword = true
                return
            }
        } else {
            needsPassword = true
            return
        }

        startConnect(password: password)
    }

    /// Password prompt submission: optionally persist, then connect.
    func submitPassword(_ password: String, save: Bool) {
        needsPassword = false
        if save && !password.isEmpty {
            do {
                try VNCPasswordManager.shared.savePassword(password, for: config)
            } catch {
                Self.logger.error("VNC password save failed: \(error.localizedDescription)")
            }
        }
        startConnect(password: password)
    }

    private func startConnect(password: String) {
        hasStartedConnect = true
        restorationState = .none
        launchErrorMessage = nil
        isPreparingConnection = true
        VNCDebugLogger.shared.logMarker(
            "VNC CONNECT \(config.host):\(config.port)")
        VNCDebugLogger.shared.event(
            "PANE",
            "connect requested host=\(config.host) port=\(config.port) "
                + "quality=\(config.quality.rawValue) "
                + "transport=\(Self.jumpLabel(for: config.effectiveJump))")
        startDebugHeartbeatIfNeeded()
        connectionTask = Task { [weak self] in
            guard let self, !self.isClosed else { return }

            // Resolve jump specs and build the package configuration
            // (installs a transportProvider for tunneled connections).
            let prepared: (credentials: VNCCredentials, configuration: VNCConfiguration)
            do {
                prepared = try await VNCSessionLauncher.prepare(
                    config: self.config,
                    password: password,
                    onHostKeyValidation: self.onHostKeyValidation,
                    onCertificateValidation: self.onCertificateValidation
                )
            } catch {
                Self.logger.error("VNC launch preparation failed: \(error.localizedDescription)")
                guard !self.isClosed else { return }
                self.isPreparingConnection = false
                self.launchErrorMessage = error.localizedDescription
                self.hasStartedConnect = false
                // Launcher failures never move the session's connectionState,
                // so poke the full-screen overlay explicitly.
                self.fullScreenController?.refreshFailureOverlay()
                return
            }

            guard !self.isClosed else { return }
            self.isPreparingConnection = false
            self.session.configuration = prepared.configuration
            do {
                try await self.session.connect(credentials: prepared.credentials)
            } catch {
                // Failures render through the package's own recovery
                // overlay (driven by session.connectionState).
                Self.logger.error("VNC connect failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop either the preflight work or the package-owned connection
    /// attempt, then close this pane. Closing first prevents cancellation
    /// from being presented as a connection failure.
    func cancelConnectionAttempt() {
        guard !isClosed else { return }
        requestPaneClose()
    }

    /// Retry after a launcher failure: clears the error and re-runs the
    /// normal connect flow (password re-resolves from the Keychain).
    func retryLaunch() {
        guard launchErrorMessage != nil else { return }
        launchErrorMessage = nil
        connectIfNeeded()
    }

    /// Cancel from a failure prompt. Launcher failures leave the package
    /// session idle, so `disconnect()` cannot close them; established session
    /// failures use the normal disconnect path and its pane-close callback.
    func cancelFailedConnection() {
        if launchErrorMessage != nil {
            requestPaneClose()
        } else {
            session.disconnect()
        }
    }

    /// Foreground nudge (MainView's foreground handler): automatic recovery
    /// that exhausted its attempts while backgrounded parks the session in
    /// `.failed` with nothing left to drive it, so kick one manual retry.
    /// `.reconnecting` keeps driving itself; launcher failures need the
    /// user's Retry (the config problem won't fix itself).
    func nudgeRetryAfterForeground() {
        guard !isClosed, hasStartedConnect, launchErrorMessage == nil else { return }
        guard case .failed = session.connectionState else { return }
        session.retryConnection()
    }

    /// Whether this pane holds a live session that is worth keeping alive
    /// across a short background window.
    ///
    /// iOS suspends a process with no background assertion within a couple of
    /// seconds, and it reclaims both the socket and the hardware decode
    /// session when it does: the transport surfaces `ECONNABORTED` and
    /// VideoToolbox surfaces `kVTVideoDecoderMalfunctionErr` on the very next
    /// foreground edge. Reconnecting after that costs a full RFB handshake,
    /// authentication, media renegotiation and an IDR, which the user reads
    /// as a dropped session. `.connecting` and `.reconnecting` count too: a
    /// suspension landing mid-handshake strands the session for the whole
    /// background window and then fails, which is how one capture sat 3m43s
    /// between sending the auth response and erroring out.
    var wantsBackgroundKeepaliveGrace: Bool {
        guard !isClosed, hasStartedConnect, launchErrorMessage == nil else { return false }
        switch session.connectionState {
        case .connected, .connecting, .reconnecting:
            return true
        case .idle, .disconnecting, .disconnected, .failed:
            return false
        }
    }

    // MARK: - Full screen

    /// Ask the owning MainView to fulfill either the initial profile
    /// preference or a takeover suspended by a tab switch. MainView rejects
    /// requests from background tabs or non-focused split leaves; a later
    /// focus gain retries without consuming the pending request.
    private func requestFullScreenIfNeeded() {
        let wantsInitialAutomaticEntry = config.automaticallyEnterFullScreen
            && !hasHandledAutomaticFullScreen
        guard (wantsInitialAutomaticEntry || shouldRestoreFullScreenAfterTabSwitch),
              session.connectionState.isConnected else { return }

        if isDetachedForFullScreen {
            hasHandledAutomaticFullScreen = true
            shouldRestoreFullScreenAfterTabSwitch = false
            return
        }

        // Avoid reparenting the pane in the middle of a tab-focus pass.
        Task { @MainActor [weak self] in
            guard let self,
                  (self.shouldRestoreFullScreenAfterTabSwitch
                    || (self.config.automaticallyEnterFullScreen
                        && !self.hasHandledAutomaticFullScreen)),
                  self.session.connectionState.isConnected,
                  !self.isDetachedForFullScreen else { return }
            NotificationCenter.default.post(name: .vncEnterFullScreen, object: self)
        }
    }

    /// Called only after PaneFullScreenController successfully checks the
    /// pane out of split layout. Manual entry also satisfies the pending
    /// preference, preventing a later reconnect or focus change from forcing
    /// a second entry.
    func fullScreenDidEnter() {
        hasHandledAutomaticFullScreen = true
        shouldRestoreFullScreenAfterTabSwitch = false
    }

    /// The controller calls this only for selection changes. Manual exits,
    /// closes, and window retargets intentionally do not schedule re-entry.
    func fullScreenDidSuspendForTabChange() {
        shouldRestoreFullScreenAfterTabSwitch = true
    }

    /// HUD "Enter/Exit Full Screen": routed to MainView via notification
    /// (same pane-to-window pattern as `.closeSplit`) so the per-window
    /// PaneFullScreenController handles it.
    func requestToggleFullScreen() {
        NotificationCenter.default.post(name: .vncToggleFullScreen, object: self)
    }

    // MARK: - Session observation

    /// Bridge the package's @Observable session into this ObservableObject:
    /// re-arm withObservationTracking on every change and mirror the server
    /// name into `displayTitle` once connected.
    private func observeSession() {
        guard !isClosed else { return }
        let (state, serverName, encryption) = withObservationTracking {
            (
                session.connectionState,
                session.serverName,
                session.negotiatedContentEncryption
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSession()
            }
        }

        applyClipboardSyncDefault(encryption: encryption)
        logConnectionStateChangeIfNeeded(state)

        if state.isConnected, !serverName.isEmpty {
            let resolved = userOverrideTitle ?? serverName
            if displayTitle != resolved {
                displayTitle = resolved
            }
        }

        // Apply the initial profile preference or a pending tab-switch restore
        // after the handshake. A distinct enter-only notification avoids
        // accidentally toggling out if the user entered while connecting.
        if state.isConnected {
            requestFullScreenIfNeeded()
        }

        // `.disconnected` is only reached by an intentional disconnect (the
        // HUD's Close Connection, the recovery overlay's Disconnect); drops
        // and exhausted retries land in `.reconnecting`/`.failed`. Close the
        // pane so the tab or split goes away with the session.
        if case .disconnected = state, hasStartedConnect {
            requestPaneClose()
        }
    }

    // MARK: - Screen Sharing debug log

    /// Coarse transport label. Never interpolate the `Jump` value itself:
    /// `.sshConfig` carries an `SSHConfig` whose auth method can hold a
    /// password, and this string goes to a file the user can export.
    private static func jumpLabel(for jump: VNCConnectionConfig.Jump) -> String {
        // Spell the enum out: `Jump` has a case named `none`, and the
        // codebase already treats bare `.none` patterns as a hazard.
        switch jump {
        case VNCConnectionConfig.Jump.none: return "direct"
        case .sshProfile:                   return "ssh-profile"
        case .sshConfig:                    return "ssh-config"
        case .tsshProfile:                  return "tssh-profile"
        }
    }

    /// Periodic health line while the Screen Sharing debug log is enabled.
    ///
    /// The point of the heartbeat is the trail it leaves *before* a drop. In
    /// High Performance mode the video path is UDP and what stays on TCP is
    /// request/response, so an idle desktop leaves the control channel silent
    /// for long stretches. A run of heartbeats showing live media while both
    /// `sinceControlByte` and `sinceControlSend` climb steadily into a
    /// disconnect identifies a keepalive verdict on an idle socket, which
    /// nothing else distinguishes from a genuine network failure.
    private func startDebugHeartbeatIfNeeded() {
        guard debugHeartbeatTask == nil else { return }
        debugHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                guard VNCDebugLogger.shared.isEnabled else { continue }
                await self.writeDebugHeartbeat()
            }
        }
    }

    private func writeDebugHeartbeat() async {
        let state = Self.stateLabel(session.connectionState)
        guard let stats = await session.currentStatistics() else {
            VNCDebugLogger.shared.event("HEARTBEAT", "state=\(state) stats=unavailable")
            return
        }
        let transport = stats.transport
        VNCDebugLogger.shared.event(
            "HEARTBEAT",
            "state=\(state) "
                + "highPerformance=\(transport.isHighPerformanceMode) "
                + "uptime=\(Self.seconds(transport.connectionUptime)) "
                + "sinceControlByte=\(Self.seconds(transport.secondsSinceControlChannelByte)) "
                + "sinceControlSend=\(Self.seconds(transport.secondsSinceControlChannelSend)) "
                + "controlBytesIn=\(transport.controlChannelBytesReceived) "
                + "controlBytesOut=\(transport.controlChannelBytesSent) "
                + "sinceVideoRTP=\(Self.seconds(transport.secondsSinceVideoRTPPacket)) "
                + "videoSources=\(transport.videoSourceCount) "
                + "bitrate=\(Self.kbps(transport.recentBitrateKbps ?? transport.throughputKbps)) "
                + "lossPct=\(Self.number(transport.recentPacketLossPercent)) "
                + "lostTotal=\(transport.packetsLostCumulative) "
                + "framesDecoded=\(stats.framesDecoded) "
                + "lossGaps=\(stats.lossGapsDetected)")
    }

    private static func stateLabel(_ state: VNCConnectionState) -> String {
        switch state {
        case .idle:                          return "idle"
        case .connecting:                    return "connecting"
        case .connected:                     return "connected"
        case .reconnecting(let attempt, _):  return "reconnecting(\(attempt))"
        case .disconnecting:                 return "disconnecting"
        case .disconnected:                  return "disconnected"
        case .failed:                        return "failed"
        }
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "never" }
        return String(format: "%.1fs", value)
    }

    private static func kbps(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0fkbps", value)
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    /// Record every connection-state transition, so the log shows the moment a
    /// session flipped into `.reconnecting` next to the package's own reason.
    private func logConnectionStateChangeIfNeeded(_ state: VNCConnectionState) {
        guard VNCDebugLogger.shared.isEnabled else { return }
        let label = Self.stateLabel(state)
        guard lastLoggedConnectionState != label else { return }
        lastLoggedConnectionState = label
        VNCDebugLogger.shared.event(
            "PANE", "connectionState=\(label) host=\(config.host)")
    }

    /// Ask the owning window to close this pane's split (or its tab when
    /// this is the only leaf), exactly once.
    private func requestPaneClose() {
        guard !closeRequested, !isClosed else { return }
        closeRequested = true
        NotificationCenter.default.post(name: .closeSplit, object: self)
    }

    // MARK: - SplitPaneView hooks

    /// The package's interaction view manages its own first responder. Pane
    /// focus gates ordinary input so a hidden VNC pane cannot intercept keys.
    /// The narrow reserved-shortcut mode is independent and remains off until
    /// explicitly toggled.
    @discardableResult
    override func focusDidChange(_ focused: Bool, skipResign: Bool = false) -> Bool {
        clipboardSynchronizer.setHostFocused(focused)
        if focused {
            if !overlayOwnsKeyboard {
                keyboardCapture.capture()
            }
            // A restored background pane may already be connected by the
            // time its tab is selected. Retry the still-pending enter request
            // now that MainView can validate it as the active focused leaf.
            requestFullScreenIfNeeded()
        } else {
            keyboardCapture.release()
        }
        return false
    }

    override func setOverlayOwnsKeyboard(_ owns: Bool) {
        guard overlayOwnsKeyboard != owns else { return }
        overlayOwnsKeyboard = owns
        if owns {
            if keyboardCapture.isCaptured {
                // Snapshot the toolbar reserve and the software-keyboard
                // request while the capture responder still holds them (the
                // package clears the request when the hide lands); keep any
                // prior latch on a rapid reopen.
                overlayLatchedToolbarReserve =
                    keyboardCoordinator?.reservedToolbarHeightAtBottom ?? 0
                overlayLatchedSoftwareKeyboardRequested =
                    keyboardCapture.softwareKeyboardRequested
            }
            keyboardCapture.release()
        } else {
            // Deferred one turn, then bounded: a modal sheet (settings) keeps
            // presentedViewController non-nil through its ~300ms dismissal
            // and a capture attempted during it doesn't stick — the same
            // failure Ghostty.TerminalView's reconcile waits out. A single
            // synchronous capture() here left the VNC keyboard off after
            // every settings round trip.
            DispatchQueue.main.async { [weak self] in
                self?.reconcileCaptureAfterOverlayRelease(attempt: 0)
            }
        }
    }

    /// Re-acquire keyboard capture after a keyboard-owning overlay is
    /// dismissed. Mirrors `Ghostty.TerminalView`'s bounded reconcile: waits
    /// out a still-dismissing modal, re-checks the gate every attempt (a
    /// rapid reopen keeps the toolbar-reserve latch armed), and always
    /// resolves the latch on exit.
    private func reconcileCaptureAfterOverlayRelease(attempt: Int) {
        guard !overlayOwnsKeyboard else { return }
        guard isLogicallyFocused, !isClosed, window != nil else {
            clearOverlayLatchedToolbarReserve()
            return
        }
        if window?.rootViewController?.presentedViewController != nil {
            guard attempt < 24 else {
                clearOverlayLatchedToolbarReserve()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reconcileCaptureAfterOverlayRelease(attempt: attempt + 1)
            }
            return
        }
        keyboardCapture.capture()
        requestFullScreenIfNeeded()
        if keyboardCapture.isCaptured || attempt >= 24 {
            if keyboardCapture.isCaptured, overlayLatchedSoftwareKeyboardRequested {
                // Re-summon the software keyboard: the package treated the
                // overlay-driven hide as a user dismissal and cleared the
                // request, so capture alone leaves the keyboard off.
                keyboardCapture.softwareKeyboardRequested = true
            }
            clearOverlayLatchedToolbarReserve()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.reconcileCaptureAfterOverlayRelease(attempt: attempt + 1)
        }
    }

    /// Drop the overlay keyboard latches (toolbar reserve + software-keyboard
    /// request snapshot). When capture isn't holding the live value, notify
    /// EffectManager so SwiftUI recomputes the bottom padding from live state
    /// (mirrors Ghostty.TerminalView).
    private func clearOverlayLatchedToolbarReserve() {
        overlayLatchedSoftwareKeyboardRequested = false
        guard overlayLatchedToolbarReserve > 0 else { return }
        overlayLatchedToolbarReserve = 0
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// Perform the rootshell side of a chord claimed by the package's focused
    /// responder. The narrow toggle chooses exactly one destination for the
    /// four app shortcuts; the toggle chord itself always remains local.
    private func handleReservedHostShortcut(_ shortcut: VNCHostKeyboardShortcut) {
        let input = shortcut.input.lowercased()
        let modifiers = shortcut.modifiers

        if input == "m", modifiers == [.command, .shift] {
            keyboardCapture.toggleCaptureMode()
            return
        }

        let appShortcut: VNCReservedKeyboardShortcut?
        if input == "\\", modifiers == [.command, .shift] {
            appShortcut = .toggleTabSwitcher
        } else if input == ",", modifiers == [.command] {
            appShortcut = .openSettings
        } else if input == "[", modifiers == [.command, .shift] {
            appShortcut = .previousTab
        } else if input == "]", modifiers == [.command, .shift] {
            appShortcut = .nextTab
        } else {
            appShortcut = nil
        }

        guard let appShortcut else { return }
        // The package callback is already scoped to this exact pane. VNC mode
        // consumes the shortcut here; rootshell mode dispatches only the local
        // action below.
        if routeReservedKeyboardShortcutToVNC(appShortcut) { return }

        switch appShortcut {
        case .toggleTabSwitcher:
            UIApplication.shared.menuToggleTabSwitcher(nil)
        case .openSettings:
            UIApplication.shared.menuOpenSettings(nil)
        case .previousTab:
            UIApplication.shared.menuPreviousTab(nil)
        case .nextTab:
            UIApplication.shared.menuNextTab(nil)
        }
    }

    /// Route a rootshell-reserved shortcut exclusively to VNC. Returns true
    /// when VNC consumed it so the caller must not perform the local action.
    @discardableResult
    func routeReservedKeyboardShortcutToVNC(
        _ shortcut: VNCReservedKeyboardShortcut
    ) -> Bool {
        guard keyboardCapture.isCaptured,
              keyboardCapture.routesReservedHostShortcutsToVNC,
              !overlayOwnsKeyboard,
              !isClosed else { return false }

        let key: Character
        let modifiers: VNCKeyboardModifiers
        switch shortcut {
        case .toggleTabSwitcher:
            key = "\\"
            modifiers = [.command, .shift]
        case .openSettings:
            key = ","
            modifiers = [.command]
        case .previousTab:
            key = "["
            modifiers = [.command, .shift]
        case .nextTab:
            key = "]"
            modifiers = [.command, .shift]
        }

        let input = KeyboardInputHandler { [session] downFlag, keysym in
            session.sendKeyEvent(downFlag: downFlag, key: keysym)
        }
        input.handleShortcutTap(key, modifiers: modifiers)
        return true
    }

    override func setOcclusion(_ visible: Bool) {
        // Hidden tabs still get layout passes (the selected tab's keyboard
        // toolbar reservation reshapes every tab's slot), which would
        // round-trip a Match Client resize on every tab switch. Defer size
        // updates while occluded; one reconciling update fires on return.
        session.suspendsRemoteDisplaySizeUpdates = !visible
        // Clear-only: presentation suspend is set by the pause sweeps, not by
        // occlusion. Hidden tabs must keep composing frames in the foreground
        // (the Apple-login Vision pipeline consumes them), so occlusion(false)
        // never suspends here.
        if visible {
            session.suspendsDisplayPresentation = false
        }
    }

    @discardableResult
    override func pauseRendererForBackground(
        timeoutNanoseconds: UInt64 = 200_000_000
    ) -> Bool {
        // Stops decoded-frame commits to the display layer and discards
        // queued-but-unpresented samples; an enqueue during the locked-screen
        // secure snapshot gets the process killed. Cleared by
        // setOcclusion(true) and by resumePresentationAfterForeground().
        session.suspendsDisplayPresentation = true
        VNCDebugLogger.shared.lifecycle("presentationSuspended", [
            ("reason", "pauseRendererForBackground"),
        ])
        return true
    }

    /// Foreground-resume counterpart of `pauseRendererForBackground` for panes
    /// in hidden tabs: the resume occlusion pass only reaches the visible tab,
    /// and a pane left suspended stops composing the frames the Apple-login
    /// Vision pipeline consumes. Uses the force-reconcile so panes created
    /// while the global gate was armed (never instance-suspended) present
    /// their retained frames too. Safe unconditionally; the app-wide
    /// secure-draw gate still covers frame delivery during any future lock.
    func resumePresentationAfterForeground() {
        session.reconcileDisplayPresentation()
    }

    override func setWindowActive(_ active: Bool) {
        windowIsActive = active
        clipboardSynchronizer.setHostWindowActive(active)
    }

    override func retargetWindow(to windowId: String) {
        // Hand back to split layout before the tab leaves this window; a
        // still-set detach flag would make the destination window's layout
        // skip the pane forever.
        fullScreenController?.exitForWindowRetarget()
        self.windowId = windowId
    }

    override func prepareForAttachment(to parentViewController: UIViewController?) -> Bool {
        // Initial attachment creates the hosting controller from
        // didMoveToWindow. On a live cross-window transfer it already exists,
        // so it must become a child of the destination controller before this
        // pane is inserted there or UIKit raises a hierarchy inconsistency.
        guard hostingController != nil else { return true }
        guard let parentViewController else { return false }
        rehostHostingController(under: parentViewController)
        return true
    }

    override func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        connectionTask?.cancel()
        connectionTask = nil
        debugHeartbeatTask?.cancel()
        debugHeartbeatTask = nil
        VNCDebugLogger.shared.event("PANE", "pane closing host=\(config.host)")
        isPreparingConnection = false
        // Closed while full screen: tear the takeover container down first
        // (no reattach; this close path owns the pane from here).
        fullScreenController?.paneDidClose(self)
        clipboardSynchronizer.invalidate()
        keyboardCapture.onReservedHostShortcut = nil
        session.disconnect()
        keyboardCoordinator?.tearDown()
        keyboardCoordinator = nil
        keyboardCapture.release()
        overlayLatchedToolbarReserve = 0
        overlayLatchedSoftwareKeyboardRequested = false
        hideBrightnessHUD(animated: false)
        if let controller = hostingController {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            hostingController = nil
        }
    }
}

private extension VNCPaneView {
    func refreshPanePresentationTitle() {
        let override = userOverrideTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let live = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if let override, !override.isEmpty {
            resolved = override
        } else if !live.isEmpty {
            resolved = live
        } else {
            resolved = fallback.isEmpty ? "Screen Sharing" : fallback
        }
        if presentation.title != resolved {
            presentation.title = resolved
        }
    }
}

// MARK: - iPhone 3-Finger Tab Swipe

extension VNCPaneView: UIGestureRecognizerDelegate {

    /// iPhone escape hatch: the package's interaction view consumes all 1-2
    /// finger touches (remote pointer, scroll, pinch zoom), so with the tab
    /// bar hidden a VNC-only tab has no touch path to other tabs. A 3-finger
    /// horizontal pan drives the same app-tab swipe pipeline as the
    /// terminal's scroll-mode pan. Phone-only: iPad always has the tab
    /// bar/sidebar reachable. The recognizer rides the pane through the
    /// full-screen takeover, where it doubles as an extra exit path (the
    /// tab-change watchdog exits the takeover when the swipe commits).
    private func installTabSwipeGestureIfNeeded() {
        guard tabSwipePanGesture == nil,
              UIDevice.current.userInterfaceIdiom == .phone else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleAppTabSwipePan))
        pan.minimumNumberOfTouches = 3
        pan.maximumNumberOfTouches = 3
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)
        tabSwipePanGesture = pan
    }

    /// Begin gate, mirroring the terminal's: horizontal intent, an app-tab
    /// navigation binding for the inferred direction, and acceptance by the
    /// owning MainView (`.appTabSwipeBegan` with an accept callback).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tabSwipePanGesture,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        let velocity = pan.velocity(in: self)
        let translation = pan.translation(in: self)
        let horizontalIntent = abs(velocity.x) > abs(velocity.y)
            || abs(translation.x) > abs(translation.y)
        guard horizontalIntent else { return false }

        let x = abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x
        let direction: SwipeDirection = x < 0 ? .left : .right
        guard SwipeGestureManager.shared.binding(for: direction).isAppTabNavigation else {
            return false
        }

        guard requestAppTabSwipeBegin(direction: direction, velocityX: velocity.x) else {
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
            return false
        }
        activeAppTabSwipeDirection = direction
        activeAppTabSwipeAccepted = true
        return true
    }

    /// Never let the package's 1-2 finger recognizers and our 3-finger pan
    /// block each other. Only our recognizer carries this delegate; the
    /// package's gesture wiring is untouched.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tabSwipePanGesture
    }

    /// Same math as the terminal's `handleAppTabSwipePan` so the swipe
    /// feels identical across pane types.
    @objc private func handleAppTabSwipePan(_ gesture: UIPanGestureRecognizer) {
        let direction: SwipeDirection
        if let active = activeAppTabSwipeDirection {
            direction = active
        } else {
            let velocity = gesture.velocity(in: self)
            let translation = gesture.translation(in: self)
            direction = (abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x) < 0 ? .left : .right
            activeAppTabSwipeDirection = direction
        }

        let normalizedTranslation = normalizedAppTabSwipeTranslation(
            gesture.translation(in: self).x,
            direction: direction
        )
        let velocityX = gesture.velocity(in: self).x

        switch gesture.state {
        case .began:
            if !activeAppTabSwipeAccepted {
                activeAppTabSwipeAccepted = requestAppTabSwipeBegin(direction: direction, velocityX: velocityX)
            }
            guard activeAppTabSwipeAccepted else {
                activeAppTabSwipeDirection = nil
                return
            }
        case .changed:
            guard activeAppTabSwipeAccepted else { return }
            postAppTabSwipeNotification(.appTabSwipeChanged, direction: direction, translationX: normalizedTranslation, velocityX: velocityX)
        case .ended:
            guard activeAppTabSwipeAccepted else {
                activeAppTabSwipeDirection = nil
                return
            }
            postAppTabSwipeNotification(.appTabSwipeEnded, direction: direction, translationX: normalizedTranslation, velocityX: velocityX)
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
        case .cancelled, .failed:
            if activeAppTabSwipeAccepted {
                postAppTabSwipeNotification(.appTabSwipeEnded, direction: direction, translationX: 0, velocityX: 0)
            }
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
        default:
            break
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted once after a configured VNC pane's initial connection succeeds.
    /// Unlike the HUD action, this is enter-only rather than a toggle.
    static let vncEnterFullScreen = Notification.Name("com.rootshell.vncEnterFullScreen")

    /// Posted by a VNCPaneView (object) to toggle its in-window full-screen
    /// takeover; handled by the owning MainView.
    static let vncToggleFullScreen = Notification.Name("com.rootshell.vncToggleFullScreen")

    /// Posted by a VNCPaneView (object) to present the Connection Info sheet;
    /// handled by the owning MainView.
    static let vncShowConnectionInfo = Notification.Name("com.rootshell.vncShowConnectionInfo")
}

// MARK: - Connection Info

extension VNCPaneView {
    /// Connection Info payload for the sheet, nil until connected.
    var connectionInfo: ConnectionInfo? {
        guard session.connectionState.isConnected else { return nil }
        return .vnc(VNCConnectionInfo(
            host: config.host,
            port: config.port,
            username: config.username,
            transportDescription: Self.transportDescription(for: config.effectiveJump),
            isTunneled: config.effectiveJump != .none,
            connectedAt: session.getDiagnostics().connectionStartTime ?? Date(),
            session: session))
    }

    private static func transportDescription(for jump: VNCConnectionConfig.Jump) -> String {
        switch jump {
        case .none:
            return String(localized: "Direct")
        case .sshProfile(let profileID):
            if let profile = ConnectionProfileManager.shared.profile(for: profileID) {
                return String(localized: "SSH Tunnel via \(profile.name)")
            }
            return String(localized: "SSH Tunnel")
        case .sshConfig(let sshConfig):
            return String(localized: "SSH Tunnel via \(sshConfig.host)")
        case .tsshProfile(let profileID):
            if let profile = ConnectionProfileManager.shared.profile(for: profileID) {
                return String(localized: "tssh Tunnel via \(profile.name)")
            }
            return String(localized: "tssh Tunnel")
        }
    }
}

// MARK: - Root View

/// SwiftUI content for a VNC pane. rootshell owns the recovery chrome so VNC
/// prompts match the rest of the app instead of exposing the package's generic
/// material cards.
struct VNCPaneRootView: View {
    @ObservedObject var pane: VNCPaneView
    @Bindable private var brightnessManager = BrightnessManager.shared

    var body: some View {
        // The themed surface wraps the package view too: its residual chrome
        // (HUD button, waiting-for-first-frame card) reads the injected
        // glass tint and scheme, and hostOwnsRecoveryChrome suppresses the
        // package's reconnect/failure cards that would otherwise show
        // through rootshell's clear-glass cards as duplicates.
        VNCPaneThemedSurface(pane: pane) {
            ZStack {
                RemoteDesktopView(
                    session: pane.session,
                    keyboardCapture: pane.keyboardCapture,
                    isFullScreen: pane.isDetachedForFullScreen,
                    toggleFullScreen: { pane.requestToggleFullScreen() },
                    keyboardAvoidanceMode: pane.isDetachedForFullScreen ? .automatic : .hostManaged,
                    clipboardSynchronizer: pane.clipboardSynchronizer,
                    initialViewportPanningMode: pane.initialViewportPanningMode,
                    onSharedClipboardUserChange: { _ in
                        pane.sharedClipboardDidChangeByUser()
                    },
                    hostOwnsRecoveryChrome: true,
                    brightnessGain: brightnessManager.effectiveGain,
                    hudMenuExtras: {
                        Menu {
                            #if !os(visionOS)
                            VNCKeyboardToolbarMenuToggle(pane: pane)
                            #endif
                            VNCQuickModeMenu(pane: pane)
                            VNCConnectionInfoMenuItem(pane: pane)
                        } label: {
                            Label("Session", systemImage: "gearshape")
                        }
                    }
                )

                VNCSessionOverlay(pane: pane)
            }
        }
        // Match the terminal's full-screen layout: let the remote desktop
        // occupy the container safe areas, including the home-indicator
        // strip. RemoteDesktopView continues to measure docked keyboard and
        // accessory obstruction independently through its automatic keyboard
        // avoidance mode.
        .ignoresSafeArea(
            .container,
            edges: pane.isDetachedForFullScreen ? .all : []
        )
    }
}

// MARK: - Pane Theme

/// Pane-context mirror of MainView's sheet-theme resolution for surfaces
/// hosted inside the pane's own UIHostingController, where the sheet theme
/// environment is never installed. Resolve the containing tab so profile,
/// tab, window, and per-theme UI overrides also reach the pane chrome.
struct VNCPaneTheme {
    let accent: Color?
    let background: Color?
    let colorScheme: ColorScheme?

    static func resolve(tabId: UUID?, windowId: String, themedUIEnabled: Bool) -> VNCPaneTheme {
        guard themedUIEnabled else {
            return VNCPaneTheme(accent: nil, background: nil, colorScheme: nil)
        }
        let themeManager = ThemeManager.shared
        let (themeName, _) = ThemeOverrideManager.shared.resolveTheme(
            tabId: tabId,
            windowId: windowId
        )
        let colors = themeName == themeManager.currentTheme
            ? themeManager.currentThemeInfo?.colors
            : themeManager.themeInfo(for: themeName)?.colors
        guard let colors,
              let derived = ThemeUIColorDerivation.derive(from: colors) else {
            return VNCPaneTheme(accent: nil, background: nil, colorScheme: nil)
        }
        let overrides = ThemeUIOverridesManager.shared.overrides(for: themeName)
        let accent = overrides.sheetAccent.flatMap { Color(hex: $0) } ?? derived.sheetAccent
        let background = overrides.sheetBackground.flatMap { Color(hex: $0) }
            ?? derived.sheetBackground
        return VNCPaneTheme(
            accent: accent,
            background: background,
            colorScheme: derived.isLight ? .light : .dark
        )
    }

    /// Shared glass-tint formula for all VNC chrome (rootshell's overlay
    /// cards and the package's residual chrome). Clear glass has no contrast
    /// floor of its own, so the tint carries both the theme's color identity
    /// and the legibility guarantee over arbitrary remote desktops.
    static func glassTint(background: Color?, fallbackScheme: ColorScheme) -> Color {
        let base = background ?? (fallbackScheme == .dark ? Color.black : Color.white)
        return base.opacity(0.45)
    }
}

private struct VNCPaneThemeKey: EnvironmentKey {
    static let defaultValue: VNCPaneTheme? = nil
}

extension EnvironmentValues {
    var vncPaneTheme: VNCPaneTheme? {
        get { self[VNCPaneThemeKey.self] }
        set { self[VNCPaneThemeKey.self] = newValue }
    }
}

/// Publishes the resolved pane theme (environment values + color scheme) to
/// VNC chrome, matching how MainView themes its other in-window overlays.
/// The accent tint is deliberately NOT applied here: the theme accent
/// belongs on rootshell's dialog cards (VNCOverlayCard applies it), not on
/// the package's HUD menu, where theme tinting proved a bad fit.
struct VNCPaneThemedSurface<Content: View>: View {
    @ObservedObject var pane: VNCPaneView
    @ViewBuilder let content: () -> Content

    @Setting(Settings.Theme.themedUI) private var themedUIEnabled
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let theme = VNCPaneTheme.resolve(
            tabId: pane.containingTabID,
            windowId: pane.windowId,
            themedUIEnabled: themedUIEnabled
        )
        content()
            .environment(\.vncPaneTheme, theme)
            .environment(
                \.vncChromeGlassTint,
                VNCPaneTheme.glassTint(
                    background: theme.background,
                    fallbackScheme: theme.colorScheme ?? systemColorScheme
                )
            )
            .optionalColorSchemeEnvironment(theme.colorScheme)
    }
}

// MARK: - Session Overlays

/// App-owned presentation for every modal VNC state. `RemoteDesktopView`
/// still owns the live framebuffer and recovery mechanics; this layer covers
/// its intentionally generic package UI with rootshell's Liquid Glass chrome.
private struct VNCSessionOverlay: View {
    @ObservedObject private var pane: VNCPaneView
    @Bindable private var session: VNCSession

    init(pane: VNCPaneView) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
    }

    @ViewBuilder
    var body: some View {
        if pane.needsPassword {
            VNCPasswordPromptCard(
                subtitle: pane.config.displayName,
                onSubmit: { password, save in
                    pane.submitPassword(password, save: save)
                }
            )
        } else if let launchError = pane.launchErrorMessage {
            // Full-screen failures are hosted above the takeover container by
            // PaneFullScreenController so its guaranteed exit action remains
            // reachable. Avoid stacking the same card twice there.
            if !pane.isDetachedForFullScreen {
                VNCConnectionFailureCard(
                    subtitle: pane.config.displayName,
                    message: launchError,
                    onRetry: { pane.retryLaunch() },
                    onCancel: { pane.cancelFailedConnection() }
                )
            }
        } else if pane.isPreparingConnection {
            VNCConnectingCard(
                subtitle: pane.config.displayName,
                status: String(localized: "Preparing secure tunnel…"),
                onCancel: { pane.cancelConnectionAttempt() }
            )
        } else {
            switch session.connectionState {
            case .connecting:
                VNCConnectingCard(
                    subtitle: pane.config.displayName,
                    status: session.connectionPhaseDescription
                        ?? String(localized: "Opening connection…"),
                    onCancel: { pane.cancelConnectionAttempt() }
                )
            case .reconnecting(let attempt, let delay):
                VNCReconnectCard(
                    subtitle: pane.config.displayName,
                    attempt: attempt,
                    delay: delay,
                    onStop: { session.disconnect() }
                )
            case .failed(let reason):
                if !pane.isDetachedForFullScreen {
                    VNCConnectionFailureCard(
                        subtitle: pane.config.displayName,
                        message: reason,
                        onRetry: { session.retryConnection() },
                        onCancel: { pane.cancelFailedConnection() }
                    )
                }
            case .connected:
                VNCFirstFrameWaitCard(
                    subtitle: pane.config.displayName,
                    session: pane.session
                )
            default:
                EmptyView()
            }
        }
    }
}

/// Connected-but-no-framebuffer gap in standard mode, owned by rootshell
/// (the package's equivalent card is suppressed by hostOwnsRecoveryChrome).
/// Isolated in its own leaf view so the hot per-frame `currentImage`
/// observation invalidates only this cheap body, mirroring the package's
/// StandardFramebufferContent split. High Performance mode renders video
/// directly and never had a waiting card.
private struct VNCFirstFrameWaitCard: View {
    let subtitle: String
    @Bindable var session: VNCSession

    var body: some View {
        if !session.isHighPerformanceMode, session.currentImage == nil {
            VNCConnectingCard(
                subtitle: subtitle,
                status: String(localized: "Waiting for first screen update…"),
                onCancel: { session.disconnect() }
            )
        }
    }
}

private struct VNCConnectingCard: View {
    let subtitle: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "Connecting…"),
            subtitle: subtitle,
            icon: {
                // Inherits the pane theme accent from VNCPaneThemedSurface.
                ProgressView()
                    .controlSize(.large)
            },
            content: {
                VStack(spacing: 14) {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(role: .cancel, action: onCancel) {
                        Label("Cancel", systemImage: "xmark")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        )
        .accessibilityElement(children: .combine)
    }
}

/// A compact, centered glass panel over a softly dimmed desktop. Keeping the
/// scrim translucent is important: Liquid Glass can pick up the remote
/// desktop's color and depth instead of reading as an opaque gray dialog.
private struct VNCOverlayCard<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    @Environment(\.vncPaneTheme) private var paneTheme
    @Environment(\.colorScheme) private var colorScheme

    private var glassTint: Color {
        VNCPaneTheme.glassTint(
            background: paneTheme?.background,
            fallbackScheme: colorScheme
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                icon()
                    .frame(width: 48, height: 48)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 420)
            .vncOverlayGlassBackground(tint: glassTint)
            .padding(24)
        }
        .tint(paneTheme?.accent ?? .accentColor)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// Purpose-built password UI for VNC. The old terminal-restoration prompt was
/// visually oversized here and its heavy scrim flattened the glass.
private struct VNCPasswordPromptCard: View {
    let subtitle: String
    let onSubmit: (String, Bool) -> Void

    @State private var password = ""
    @State private var savePassword = true
    @FocusState private var passwordFieldFocused: Bool

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "Screen Sharing Password"),
            subtitle: subtitle,
            icon: {
                Image(systemName: "lock.display")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            },
            content: {
                VStack(spacing: 14) {
                    Text("Enter the password for this Screen Sharing connection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(
                            Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                        .focused($passwordFieldFocused)
                        .onSubmit(submit)

                    Toggle("Save Password", isOn: $savePassword)
                        .font(.callout)

                    Button(action: submit) {
                        Label("Connect", systemImage: "arrow.right")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty)
                }
                .frame(maxWidth: 320)
            }
        )
        .onAppear {
            passwordFieldFocused = true
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password, savePassword)
    }
}

private struct VNCReconnectCard: View {
    let subtitle: String
    let attempt: Int
    let delay: TimeInterval
    let onStop: () -> Void

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "Connection Interrupted"),
            subtitle: subtitle,
            icon: {
                ProgressView()
                    .controlSize(.large)
            },
            content: {
                VStack(spacing: 14) {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(role: .destructive, action: onStop) {
                        Label("Stop Reconnecting", systemImage: "xmark")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.bordered)
                }
            }
        )
        .accessibilityElement(children: .combine)
    }

    private var statusMessage: String {
        if delay > 0 {
            return String(localized: "Retry \(attempt) starts in about \(Int(ceil(delay))) seconds.")
        }
        return String(localized: "Reconnecting now…")
    }
}

/// Failure card shared by the in-pane launch-error overlay and the
/// full-screen failure overlay (which adds the Exit Full Screen action so
/// the user is never stranded in the takeover).
struct VNCConnectionFailureCard: View {
    let subtitle: String
    let message: String
    let onRetry: () -> Void
    let onCancel: () -> Void
    var onExitFullScreen: (() -> Void)?

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "Connection Failed"),
            subtitle: subtitle,
            icon: {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
            },
            content: {
                VStack(spacing: 14) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            retryButton
                            cancelButton
                            if let onExitFullScreen {
                                exitFullScreenButton(action: onExitFullScreen)
                            }
                        }

                        VStack(spacing: 10) {
                            retryButton
                            cancelButton
                            if let onExitFullScreen {
                                exitFullScreenButton(action: onExitFullScreen)
                            }
                        }
                    }
                }
            }
        )
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Label("Try Again", systemImage: "arrow.clockwise")
                .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: onCancel) {
            Label("Cancel", systemImage: "xmark")
                .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func exitFullScreenButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private extension View {
    /// Native Liquid Glass on current OS releases and a material fallback on
    /// platforms where the glass API is unavailable. `.clear` rather than
    /// `.regular`: the regular variant's frost renders as an opaque gray slab
    /// over the pane's black launch backdrop, where clear glass stays
    /// see-through and picks up the desktop once frames arrive. The tint
    /// supplies the theme's color identity and the text-contrast floor.
    @ViewBuilder
    func vncOverlayGlassBackground(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.clear.tint(tint), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
        }
        #endif
    }
}

/// HUD submenu for live connection-mode switching. It observes the package
/// session directly because the host extras are captured once by
/// RemoteDesktopView and must independently invalidate as configuration and
/// connection state change.
private struct VNCQuickModeMenu: View {
    private let pane: VNCPaneView
    @Bindable private var session: VNCSession

    init(pane: VNCPaneView) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
    }

    var body: some View {
        Menu {
            ForEach(VNCQuickMode.allCases, id: \.self) { mode in
                Button {
                    pane.switchQuickMode(mode)
                } label: {
                    Label(
                        mode.title,
                        systemImage: selectedMode == mode ? "checkmark" : mode.systemImage
                    )
                }
                .disabled(
                    !session.connectionState.isConnected
                        || selectedMode == mode
                        || (mode.requiresHighPerformance && !highPerformanceAvailable)
                )
            }
        } label: {
            Label("Connection Mode", systemImage: "rectangle.connected.to.line.below")
        }
    }

    private var selectedMode: VNCQuickMode? {
        VNCQuickMode(configuration: session.configuration)
    }

    private var highPerformanceAvailable: Bool {
        session.configuration.availableVideoQualityModes.contains(.adaptive)
    }
}

/// HUD menu extra: presents the Connection Info sheet through the owning
/// MainView. Observes the session directly for the same capture reason as
/// VNCQuickModeMenu.
private struct VNCConnectionInfoMenuItem: View {
    private let pane: VNCPaneView
    @Bindable private var session: VNCSession

    init(pane: VNCPaneView) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
    }

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .vncShowConnectionInfo, object: pane)
        } label: {
            Label(String(localized: "Connection Info"), systemImage: "info.circle")
        }
        .disabled(!session.connectionState.isConnected)
    }
}

#if !os(visionOS)
/// HUD menu extra: per-pane keyboard toolbar on/off. Flips a runtime
/// override on the pane (defaulting from the connection's configured
/// tri-state); the persisted setting lives in the form/profile editor.
private struct VNCKeyboardToolbarMenuToggle: View {
    @ObservedObject var pane: VNCPaneView

    var body: some View {
        Toggle(isOn: Binding(
            get: { pane.effectiveKeyboardToolbarPreference != .off },
            set: { pane.setKeyboardToolbarEnabled($0) }
        )) {
            Label("Keyboard Toolbar", systemImage: "keyboard")
        }
    }
}
#endif
