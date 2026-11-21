//
//  KVMPaneView.swift
//  rootshell
//
//  KVM over IP pane: a SplitPaneView leaf hosting the shared remote-screen
//  view through a child UIHostingController, like the Screen Sharing pane.
//

import Combine
import CoreVideo
import SwiftUI
import UIKit
import os
import rootshellVNC

final class KVMPaneView: SplitPaneView, ObservableObject {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KVM")

    enum RestorationState {
        case none
        case pendingReconnect
    }

    let config: KVMConnectionConfig
    let session: KVMSession
    let loginPassword: KVMLoginPasswordAssistant
    let keyboardCapture: VNCKeyboardCapture
    /// The last screen seen, shown until the session draws its own.
    let snapshots: RemoteScreenSnapshotRecorder
    let initialViewportPanningMode: RemoteViewportPanningMode
    let initialPointerMode: RemotePointerMode

    @Published private(set) var displayTitle: String {
        didSet { refreshPanePresentationTitle() }
    }
    @Published private(set) var needsPassword = false
    /// The device rejected the last password, so the prompt says so.
    @Published private(set) var passwordRejected = false
    /// A password saved before keys carried the jump route, which the prompt
    /// offers rather than sends.
    @Published private(set) var offersUnconfirmedSavedPassword = false
    /// Never set: KVM launch failures surface through the session state.
    @Published private(set) var launchErrorMessage: String?
    /// A destructive power action waiting for confirmation.
    @Published var pendingATXAction: KVMATXAction?
    /// Dot at the local pointer, ahead of the pointer in the video.
    @Published var showsLocalCursor = SettingsStore.shared.value(
        Settings.ScreenSharing.kvmLocalCursorDefault)

    var onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    var onCertificateValidation: VNCConfiguration.CertificateValidationHandler?

    var userOverrideTitle: String? {
        didSet { refreshPanePresentationTitle() }
    }
    var sourceProfileID: UUID? {
        didSet {
            loginPassword.profileID = sourceProfileID
            snapshots.profileID = sourceProfileID
        }
    }
    var restorationState: RestorationState = .none
    /// A typed password for this pane's first attempt, used only if the
    /// route it was typed for is still the pane's route.
    var passwordHandoff: RemoteScreenPasswordHandoff?
    /// The route the session's password, or the open prompt, belongs to.
    @Published private(set) var route: RemoteScreenRoute? {
        // The route can move between attempts; snapshots follow the session.
        didSet { snapshots.endpoint = route?.snapshotEndpoint }
    }
    /// The prompt reopened because the jump route moved under it.
    @Published private(set) var promptRouteChanged = false

    @Published private var keyboardToolbarOverride: VNCConnectionConfig.KeyboardToolbarPreference?

    var effectiveKeyboardToolbarPreference: VNCConnectionConfig.KeyboardToolbarPreference {
        keyboardToolbarOverride ?? config.keyboardToolbar
    }

    var keyboardToolbarContext: ToolbarContext { .kvm }

    func setKeyboardToolbarEnabled(_ enabled: Bool) {
        keyboardToolbarOverride = enabled ? .on : .off
        keyboardCoordinator?.toolbarPreferenceDidChange()
    }

    private(set) var windowId: String {
        didSet { objectWillChange.send() }
    }

    override var containingTabID: UUID? {
        didSet { objectWillChange.send() }
    }

    weak var fullScreenController: PaneFullScreenController?

    override var isDetachedForFullScreen: Bool {
        didSet {
            guard oldValue != isDetachedForFullScreen else { return }
            objectWillChange.send()
        }
    }

    private(set) var keyboardCoordinator: VNCKeyboardAccessoryCoordinator?
    private var hostingController: UIHostingController<KVMPaneRootView>?
    var brightnessHUDHost: UIHostingController<BrightnessBoostHUDView>?
    var brightnessHUDHideTask: Task<Void, Never>?

    private var hasStartedConnect = false
    private var overlayOwnsKeyboard = false
    private var overlayLatchedToolbarReserve: CGFloat = 0
    private var overlayLatchedSoftwareKeyboardRequested = false
    private var isClosed = false
    private var closeRequested = false
    private var hasHandledAutomaticFullScreen = false
    private var shouldRestoreFullScreenAfterTabSwitch = false

    private var tabSwipePanGesture: RemoteScreenNavigationPan?
    private var activeAppTabSwipeDirection: SwipeDirection?
    private var activeAppTabSwipeAccepted = false
    private var activePaneCycle: (direction: SwipeDirection, preset: SwipeGesturePreset)?

    /// Video state last seen by `observeSession`, to spot moments a login
    /// screen is likely.
    private var observedFirstFrame = false
    private var observedVideoSize: CGSize?
    private var observedSourceOnline: Bool?

    init(config: KVMConnectionConfig, windowId: String, uuid: UUID = UUID()) {
        self.config = config
        let session = KVMSession(config: config)
        self.session = session
        self.loginPassword = KVMLoginPasswordAssistant(
            session: session,
            detectsLoginScreen: config.promptForHostPasswordAtLoginScreen)
        // The renderer keeps its last frame across a reconnect, so only a
        // frame from this connection counts.
        self.snapshots = RemoteScreenSnapshotRecorder(
            endpoint: config.currentRoute.snapshotEndpoint,
            canPersist: RemoteScreenSnapshotRecorder.savedProfilePoints,
            hasLivePicture: { [session] in session.hasFirstFrame }
        ) { [session] in
            guard session.hasFirstFrame, let frame = session.renderer.latestComposedFrame else { return nil }
            return .surfaces([RemoteScreenSnapshotRecorder.Surface(
                pixelBuffer: frame,
                region: CGRect(
                    x: 0, y: 0,
                    width: CVPixelBufferGetWidth(frame),
                    height: CVPixelBufferGetHeight(frame)))])
        }
        switch ScreenSharingPanningDefault.current {
        case .edge: initialViewportPanningMode = .edge
        case .continuous: initialViewportPanningMode = .continuous
        }
        switch ScreenSharingPointerModeDefault.current {
        case .direct: initialPointerMode = .direct
        case .trackpad: initialPointerMode = .trackpad
        }
        let keyboardCapture = VNCKeyboardCapture(
            isCaptured: true,
            automaticallyCapturesOnInteraction: true,
            reservedHostShortcuts: [
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

        keyboardCapture.onReservedHostShortcut = { [weak self] shortcut in
            self?.handleReservedHostShortcut(shortcut)
        }
        let assistant = loginPassword
        session.onFramePresented = { [weak assistant] pixelBuffer in
            assistant?.noteFrame(pixelBuffer)
        }
        observeSession()
        observeMenuShortcutForwarding()
        installTabSwipeGestureIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    func captureKeyboard() {
        KeyboardTracker.shared.setInputOwnerWindow(window)
        keyboardCapture.capture()
        keyboardCoordinator?.captureDidChange()
    }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportMenuShortcutForwarding()
        guard window != nil, !isClosed else { return }
        if isLogicallyFocused, !overlayOwnsKeyboard {
            captureKeyboard()
        } else {
            keyboardCapture.release()
        }
        // Before the root view: its HUD draws from the coordinator.
        #if !os(visionOS)
        if keyboardCoordinator == nil {
            keyboardCoordinator = VNCKeyboardAccessoryCoordinator(pane: self)
        }
        #endif
        attachHostingControllerIfNeeded()
        connectIfNeeded()
    }

    override var keyboardAccessoryFrameInScreen: CGRect? {
        keyboardCoordinator?.keyboardAccessoryFrameInScreen
    }

    override var dockedTouchKeyboardFrameInScreen: CGRect? {
        keyboardCoordinator?.dockedTouchKeyboardFrameInScreen
    }

    override var reservedKeyboardToolbarHeightAtBottom: CGFloat {
        if !keyboardCapture.isCaptured, overlayLatchedToolbarReserve > 0 {
            return overlayLatchedToolbarReserve
        }
        return keyboardCoordinator?.reservedToolbarHeightAtBottom ?? 0
    }

    private func attachHostingControllerIfNeeded() {
        guard hostingController == nil, let parent = nearestViewController() else { return }
        let controller = UIHostingController(rootView: KVMPaneRootView(pane: self))
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
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    func rehostHostingController(under parent: UIViewController) {
        guard let controller = hostingController, controller.parent !== parent else { return }
        controller.willMove(toParent: nil)
        controller.removeFromParent()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    func rehostHostingControllerToCurrentAncestor() {
        guard let parent = nearestViewController() else { return }
        rehostHostingController(under: parent)
    }

    // MARK: - Connection

    /// This attempt's typed password, then the Keychain, for the route
    /// captured here; a miss shows the in-pane password prompt for that route.
    func connectIfNeeded() {
        guard !hasStartedConnect, !isClosed, !needsPassword else { return }
        let route = config.currentRoute
        self.route = route
        // No password belongs to a jump profile this device doesn't have yet:
        // the session fails before signing in, and Retry starts over here.
        if route.isUnresolved {
            passwordHandoff = nil
            startConnect(password: "")
            return
        }
        let passwords = VNCPasswordManager.kvm
        let password: String
        if let handoff = takePasswordHandoff(for: route) {
            password = handoff
        } else if let saved = try? passwords.loadPassword(for: config) {
            password = saved
        } else {
            offersUnconfirmedSavedPassword = passwords.savedState(for: config) == .needsConfirmation
            needsPassword = true
            return
        }
        startConnect(password: password)
    }

    /// The first attempt's typed password, if it was typed for `route`.
    /// Taken either way, so it can't reach a later attempt.
    private func takePasswordHandoff(for route: RemoteScreenRoute) -> String? {
        defer { passwordHandoff = nil }
        guard let passwordHandoff, passwordHandoff.passwordKey == route.passwordKey else { return nil }
        return passwordHandoff.password
    }

    /// The user chose the old-format saved password for this route.
    func useUnconfirmedSavedPassword(save: Bool) {
        guard promptRouteIsCurrent() else { return }
        offersUnconfirmedSavedPassword = false
        guard let password = try? VNCPasswordManager.kvm.useLegacyPassword(for: config, save: save) else { return }
        submitPassword(password, save: false)
    }

    func submitPassword(_ password: String, save: Bool) {
        guard promptRouteIsCurrent() else { return }
        needsPassword = false
        offersUnconfirmedSavedPassword = false
        promptRouteChanged = false
        if save, !password.isEmpty {
            do {
                try VNCPasswordManager.kvm.savePassword(password, for: config)
            } catch {
                Self.logger.error("KVM password save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if passwordRejected {
            passwordRejected = false
            session.retry(password: password, jumpProfile: route?.jumpProfile)
        } else {
            startConnect(password: password)
        }
    }

    /// A prompt answers only for the route it opened on. If the jump moved
    /// since, drop what was typed and resolve the new route from scratch.
    private func promptRouteIsCurrent() -> Bool {
        guard config.passwordKey != route?.passwordKey else { return true }
        needsPassword = false
        offersUnconfirmedSavedPassword = false
        passwordRejected = false
        hasStartedConnect = false
        connectIfNeeded()
        promptRouteChanged = needsPassword
        return false
    }

    private func startConnect(password: String) {
        hasStartedConnect = true
        restorationState = .none
        session.onHostKeyValidation = onHostKeyValidation
        session.onCertificateValidation = onCertificateValidation
        session.connect(password: password, jumpProfile: route?.jumpProfile)
    }

    func cancelConnectionAttempt() {
        guard !isClosed else { return }
        requestPaneClose()
    }

    func retryLaunch() {}

    /// A route whose jump profile was missing gets its route and password
    /// chosen again, now that the profile may have synced.
    func retryRemoteConnection() {
        if route?.isUnresolved == true {
            hasStartedConnect = false
            connectIfNeeded()
        } else {
            session.retry()
        }
    }

    func cancelFailedConnection() {
        requestPaneClose()
    }

    func nudgeRetryAfterForeground() {
        guard !isClosed, hasStartedConnect, !needsPassword else { return }
        guard case .failed = session.connectionState, session.lastError?.isTerminal != true else { return }
        retryRemoteConnection()
    }

    var wantsBackgroundKeepaliveGrace: Bool {
        guard !isClosed, hasStartedConnect else { return false }
        switch session.connectionState {
        case .connected, .connecting, .reconnecting: return true
        case .idle, .disconnecting, .disconnected, .failed: return false
        }
    }

    /// Paste as keystrokes typed by the device in the host layout.
    func pasteClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        ClipboardHistoryManager.shared.record(text, source: .paste)
        keyboardCoordinator?.noteUserInput()
        session.paste(text)
    }

    // MARK: - Full screen

    private func requestFullScreenIfNeeded() {
        let wantsInitialEntry = config.automaticallyEnterFullScreen && !hasHandledAutomaticFullScreen
        guard wantsInitialEntry || shouldRestoreFullScreenAfterTabSwitch,
              session.connectionState.isConnected else { return }
        if isDetachedForFullScreen {
            hasHandledAutomaticFullScreen = true
            shouldRestoreFullScreenAfterTabSwitch = false
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.shouldRestoreFullScreenAfterTabSwitch
                    || (self.config.automaticallyEnterFullScreen && !self.hasHandledAutomaticFullScreen),
                  self.session.connectionState.isConnected,
                  !self.isDetachedForFullScreen else { return }
            NotificationCenter.default.post(name: .vncEnterFullScreen, object: self)
        }
    }

    func fullScreenDidEnter() {
        hasHandledAutomaticFullScreen = true
        shouldRestoreFullScreenAfterTabSwitch = false
    }

    func fullScreenDidSuspendForTabChange() {
        shouldRestoreFullScreenAfterTabSwitch = true
    }

    func requestToggleFullScreen() {
        NotificationCenter.default.post(name: .vncToggleFullScreen, object: self)
    }

    // MARK: - Session observation

    private func observeSession() {
        guard !isClosed else { return }
        let (state, model, error, firstFrame, videoSize, sourceOnline) = withObservationTracking {
            (session.connectionState, session.deviceInfo.model, session.lastError,
             session.hasFirstFrame, session.videoFormat.map { CGSize(width: $0.width, height: $0.height) },
             session.streamer.sourceOnline)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSession()
            }
        }

        if state.isConnected, let model {
            let resolved = userOverrideTitle ?? "\(model) · \(config.displayName)"
            if displayTitle != resolved { displayTitle = resolved }
        }
        if state.isConnected {
            requestFullScreenIfNeeded()
        }
        snapshots.sessionConnectionChanged(isConnected: state.isConnected)
        noteVideoTransition(
            connected: state.isConnected, firstFrame: firstFrame,
            videoSize: videoSize, sourceOnline: sourceOnline)
        if case .failed = state, error == .invalidCredentials {
            passwordRejected = true
            needsPassword = true
        }
        if case .disconnected = state, hasStartedConnect {
            requestPaneClose()
        }
    }

    private func noteVideoTransition(connected: Bool, firstFrame: Bool, videoSize: CGSize?, sourceOnline: Bool?) {
        defer {
            observedFirstFrame = firstFrame
            observedVideoSize = videoSize
            observedSourceOnline = sourceOnline
        }
        guard connected else {
            loginPassword.reset()
            return
        }
        if firstFrame, !observedFirstFrame {
            loginPassword.arm(reason: "first video")
        } else if let videoSize, let observedVideoSize, videoSize != observedVideoSize {
            loginPassword.arm(reason: "resolution change")
        } else if sourceOnline == true, observedSourceOnline == false {
            loginPassword.arm(reason: "video signal returned")
        }
    }

    private func requestPaneClose() {
        guard !closeRequested, !isClosed else { return }
        closeRequested = true
        NotificationCenter.default.post(name: .closeSplit, object: self)
    }

    // MARK: - Pre-disconnect action

    /// Non-nil while the saved pre-disconnect action runs or waits for the
    /// user to decide after it failed.
    @Published private(set) var preDisconnectPhase: RemoteScreenPreDisconnectPhase?
    private var preDisconnectTask: Task<Void, Never>?
    private var preDisconnectCompletion: (@MainActor () -> Void)?

    func runPreDisconnectAction(then disconnect: @escaping @MainActor () -> Void) {
        // Closed meanwhile: nothing to run, but a tab close chain continues.
        guard !isClosed else {
            disconnect()
            return
        }
        // Already in flight: its card owns the decision.
        guard preDisconnectPhase == nil else { return }
        let action = config.preDisconnectAction
        let layout = config.hostKeyboardLayout
        guard action.isEnabled, session.connectionState.isConnected else {
            disconnect()
            return
        }

        // Before the action: after it the screen is locked or dark.
        snapshots.captureClosingFrame()
        preDisconnectCompletion = disconnect
        preDisconnectPhase = .running
        preDisconnectTask = Task { [weak self] in
            do {
                guard let session = self?.session else { return }
                try await session.sendChord(action.keyCodes(layout: layout))
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                self.finishPreDisconnect()
            } catch {
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                Self.logger.error("KVM pre-disconnect action failed: \(error.localizedDescription, privacy: .public)")
                self.preDisconnectTask = nil
                self.preDisconnectPhase = .failed(error.localizedDescription)
                // Bring a background tab forward so the choice is visible.
                NotificationCenter.default.post(name: .vncPreDisconnectFailed, object: self)
            }
        }
    }

    /// Disconnect without waiting for the action, or after it failed.
    func disconnectIgnoringPreDisconnectAction() {
        preDisconnectTask?.cancel()
        finishPreDisconnect()
    }

    /// Abandon the close and keep the session.
    func cancelPreDisconnect() {
        preDisconnectTask?.cancel()
        preDisconnectTask = nil
        preDisconnectCompletion = nil
        preDisconnectPhase = nil
        snapshots.resumeCaptures()
    }

    private func finishPreDisconnect() {
        let completion = preDisconnectCompletion
        preDisconnectTask = nil
        preDisconnectCompletion = nil
        preDisconnectPhase = nil
        completion?()
    }

    // MARK: - SplitPaneView hooks

    @discardableResult
    override func focusDidChange(_ focused: Bool, skipResign: Bool = false) -> Bool {
        if focused {
            if !overlayOwnsKeyboard { captureKeyboard() }
            requestFullScreenIfNeeded()
        } else {
            keyboardCapture.release()
            session.releaseAllInput()
        }
        return false
    }

    override func setOverlayOwnsKeyboard(_ owns: Bool) {
        guard overlayOwnsKeyboard != owns else { return }
        overlayOwnsKeyboard = owns
        if owns {
            if keyboardCapture.isCaptured {
                overlayLatchedToolbarReserve = keyboardCoordinator?.reservedToolbarHeightAtBottom ?? 0
                overlayLatchedSoftwareKeyboardRequested = keyboardCapture.softwareKeyboardRequested
            }
            keyboardCapture.release()
            session.releaseAllInput()
        } else {
            // A dismissing modal keeps presentedViewController set for a while.
            DispatchQueue.main.async { [weak self] in
                self?.reconcileCaptureAfterOverlayRelease(attempt: 0)
            }
        }
    }

    private func reconcileCaptureAfterOverlayRelease(attempt: Int) {
        guard !overlayOwnsKeyboard else { return }
        guard isLogicallyFocused, !isClosed, window != nil else {
            clearOverlayLatches()
            return
        }
        if window?.rootViewController?.presentedViewController != nil {
            guard attempt < 24 else {
                clearOverlayLatches()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reconcileCaptureAfterOverlayRelease(attempt: attempt + 1)
            }
            return
        }
        captureKeyboard()
        requestFullScreenIfNeeded()
        if keyboardCapture.isCaptured || attempt >= 24 {
            if keyboardCapture.isCaptured, overlayLatchedSoftwareKeyboardRequested {
                keyboardCapture.softwareKeyboardRequested = true
            }
            clearOverlayLatches()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.reconcileCaptureAfterOverlayRelease(attempt: attempt + 1)
        }
    }

    private func clearOverlayLatches() {
        overlayLatchedSoftwareKeyboardRequested = false
        guard overlayLatchedToolbarReserve > 0 else { return }
        overlayLatchedToolbarReserve = 0
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    private func handleReservedHostShortcut(_ shortcut: VNCHostKeyboardShortcut) {
        let input = shortcut.input.lowercased()
        let modifiers = shortcut.modifiers
        if input == "m", modifiers == [.command, .shift] {
            keyboardCapture.toggleCaptureMode()
            return
        }
        let candidates: [VNCReservedKeyboardShortcut] = [.toggleTabSwitcher, .openSettings, .previousTab, .nextTab]
        let appShortcut = candidates.first { candidate in
            let chord = Self.reservedShortcutChord(candidate)
            return input == String(chord.key) && modifiers == chord.modifiers
        }
        guard let appShortcut else { return }
        if routeReservedKeyboardShortcutToVNC(appShortcut) { return }
        switch appShortcut {
        case .toggleTabSwitcher: UIApplication.shared.menuToggleTabSwitcher(nil)
        case .openSettings: UIApplication.shared.menuOpenSettings(nil)
        case .previousTab: UIApplication.shared.menuPreviousTab(nil)
        case .nextTab: UIApplication.shared.menuNextTab(nil)
        }
    }

    @discardableResult
    func routeReservedKeyboardShortcutToVNC(_ shortcut: VNCReservedKeyboardShortcut) -> Bool {
        guard keyboardCapture.isCaptured,
              keyboardCapture.routesReservedHostShortcutsToVNC,
              !overlayOwnsKeyboard,
              !isClosed else { return false }
        let chord = Self.reservedShortcutChord(shortcut)
        let input = KeyboardInputHandler { [session] down, keysym in
            session.sendKeysym(down: down, keysym: keysym)
        }
        input.handleShortcutTap(chord.key, modifiers: chord.modifiers)
        return true
    }

    override func setOcclusion(_ visible: Bool) {
        if visible {
            session.renderer.setPresentationSuspended(false)
        }
    }

    @discardableResult
    override func pauseRendererForBackground(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
        // The app may not come back: keep the screen as it is now.
        snapshots.captureNow()
        #if targetEnvironment(macCatalyst)
        session.renderer.setPresentationSuspended(true)
        #else
        // iOS suspends the process soon; drop the video now and keep the
        // control socket so a short trip away doesn't sign in again.
        session.pauseForBackground()
        #endif
        return true
    }

    func resumePresentationAfterForeground() {
        session.renderer.setPresentationSuspended(false)
        session.resumeFromBackground()
        #if !targetEnvironment(macCatalyst)
        // The computer may have locked while the app was away.
        loginPassword.arm(reason: "foreground")
        #endif
    }

    override func setWindowActive(_ active: Bool) {}

    override func retargetWindow(to windowId: String) {
        fullScreenController?.exitForWindowRetarget()
        self.windowId = windowId
    }

    override func prepareForAttachment(to parentViewController: UIViewController?) -> Bool {
        guard hostingController != nil else { return true }
        guard let parentViewController else { return false }
        rehostHostingController(under: parentViewController)
        return true
    }

    override func prepareForClose() {
        guard !isClosed else { return }
        isClosed = true
        preDisconnectTask?.cancel()
        preDisconnectTask = nil
        preDisconnectCompletion = nil
        fullScreenController?.paneDidClose(self)
        keyboardCapture.onReservedHostShortcut = nil
        snapshots.captureNow()
        snapshots.stop()
        session.disconnect()
        session.onFramePresented = nil
        loginPassword.reset()
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

    private func refreshPanePresentationTitle() {
        let override = userOverrideTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if let override, !override.isEmpty {
            resolved = override
        } else if !live.isEmpty {
            resolved = live
        } else {
            resolved = config.displayName.isEmpty ? "KVM" : config.displayName
        }
        if presentation.title != resolved {
            presentation.title = resolved
        }
    }
}

// MARK: - RemoteScreenPane

extension KVMPaneView: RemoteScreenPane {
    var paneDisplayName: String { config.displayName }
    var connectionConfig: ConnectionConfig { .kvm(config) }
    var displayTitlePublisher: AnyPublisher<String, Never> { $displayTitle.eraseToAnyPublisher() }
    /// A rejected password shows the in-pane password card instead.
    var fullScreenFailureMessage: String? {
        guard case .failed(let reason) = session.connectionState,
              session.lastError != .invalidCredentials else { return nil }
        return reason
    }
    var usesAppleModifierConvention: Bool { false }
    var remoteSessionIsConnected: Bool { session.connectionState.isConnected }

    func sendKeyboardToolbarKeysym(down: Bool, keysym: UInt32) {
        if down { keyboardCapture.noteExternalInput() }
        session.sendKeysym(down: down, keysym: keysym)
    }

    func pasteFromKeyboardToolbar() {
        keyboardCapture.noteExternalInput()
        pasteClipboard()
    }

    func typePasswordFromKeyboardToolbar(pressingReturn: Bool) {
        guard loginPassword.canSend else { return }
        keyboardCapture.noteExternalInput()
        loginPassword.send(pressingReturn: pressingReturn)
    }

    var connectionInfo: ConnectionInfo? {
        guard session.connectionState.isConnected else { return nil }
        return .kvm(KVMConnectionInfo(
            host: config.host,
            port: config.port,
            username: config.username,
            transportDescription: Self.transportDescription(for: config.jump, tunneled: session.usesTunnel),
            connectedAt: session.connectedAt ?? Date(),
            session: session))
    }

    private static func transportDescription(for jump: VNCConnectionConfig.Jump, tunneled: Bool) -> String {
        switch jump {
        case .none:
            return tunneled ? String(localized: "Tailscale (in-app)") : String(localized: "Direct")
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

// MARK: - iPhone 3-Finger Tab Swipe

extension KVMPaneView: UIGestureRecognizerDelegate {

    /// The remote-screen view consumes every touch, so a three-finger pan
    /// the remote gestures do not claim is the iPhone path to other tabs (as
    /// on VNC panes).
    /// iPad installs it for pane presets only: zoom has no on-screen exit.
    private func installTabSwipeGestureIfNeeded() {
        let idiom = UIDevice.current.userInterfaceIdiom
        guard tabSwipePanGesture == nil, idiom == .phone || idiom == .pad else { return }
        let pan = RemoteScreenNavigationPan(target: self, action: #selector(handleAppTabSwipePan))
        pan.delegate = self
        addGestureRecognizer(pan)
        tabSwipePanGesture = pan
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tabSwipePanGesture,
              let pan = gestureRecognizer as? RemoteScreenNavigationPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        let translation = pan.translation(in: self)
        guard abs(velocity.x) > abs(velocity.y) || abs(translation.x) > abs(translation.y) else { return false }
        let x = abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x
        let direction: SwipeDirection = x < 0 ? .left : .right
        guard !pan.yieldsToRemoteSwipe(direction) else { return false }
        let binding = SwipeGestureManager.shared.binding(for: direction, area: swipeStartArea(of: pan))
        activePaneCycle = nil
        guard let preset = appTabPreset(for: binding) else {
            // Multi-pane tab with a pane preset: fire on release.
            guard case .preset(let panePreset) = binding, panePreset.isPaneCycle else { return false }
            activePaneCycle = (direction, panePreset)
            return true
        }
        guard UIDevice.current.userInterfaceIdiom == .phone,
              requestAppTabSwipeBegin(direction: direction, velocityX: velocity.x, preset: preset) else {
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
            return false
        }
        activeAppTabSwipeDirection = direction
        activeAppTabSwipeAccepted = true
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let pan = tabSwipePanGesture, gestureRecognizer === pan else { return false }
        return pan.recognizesSimultaneously(with: otherGestureRecognizer)
    }

    @objc private func handleAppTabSwipePan(_ gesture: UIPanGestureRecognizer) {
        if let paneCycle = activePaneCycle {
            switch gesture.state {
            case .ended:
                activePaneCycle = nil
                finishPaneCycleSwipe(paneCycle.preset, direction: paneCycle.direction,
                                     translationX: gesture.translation(in: self).x,
                                     velocityX: gesture.velocity(in: self).x)
            case .cancelled, .failed:
                activePaneCycle = nil
            default:
                break
            }
            return
        }

        let direction: SwipeDirection
        if let active = activeAppTabSwipeDirection {
            direction = active
        } else {
            let velocity = gesture.velocity(in: self)
            let translation = gesture.translation(in: self)
            direction = (abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x) < 0 ? .left : .right
            activeAppTabSwipeDirection = direction
        }
        let translationX = normalizedAppTabSwipeTranslation(gesture.translation(in: self).x, direction: direction)
        let velocityX = gesture.velocity(in: self).x

        switch gesture.state {
        case .began:
            if !activeAppTabSwipeAccepted {
                activeAppTabSwipeAccepted = requestAppTabSwipeBegin(direction: direction, velocityX: velocityX)
            }
            if !activeAppTabSwipeAccepted { activeAppTabSwipeDirection = nil }
        case .changed:
            guard activeAppTabSwipeAccepted else { return }
            postAppTabSwipeNotification(.appTabSwipeChanged, direction: direction, translationX: translationX, velocityX: velocityX)
        case .ended:
            if activeAppTabSwipeAccepted {
                postAppTabSwipeNotification(.appTabSwipeEnded, direction: direction, translationX: translationX, velocityX: velocityX)
            }
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
