//
//  KVMPaneRootView.swift
//  rootshell
//
//  SwiftUI content for a KVM pane: the shared remote-screen view, KVM HUD
//  extras (paste, video quality, power), and rootshell's session cards.
//

import SwiftUI
import rootshellVNC

struct KVMPaneRootView: View {
    @ObservedObject var pane: KVMPaneView
    @Bindable private var brightnessManager = BrightnessManager.shared
    @Setting(Settings.ScreenSharing.pointerSpeed) private var pointerSpeed
    @Setting(Settings.ScreenSharing.cursorSizeDefault) private var cursorSizeDefault
    private var touchGestures = ScreenSharingTouchGestureSettings()

    var body: some View {
        RemoteScreenThemedSurface(tabId: pane.containingTabID, windowId: pane.windowId) {
            ZStack {
                KVMScreenContent(
                    pane: pane,
                    pointerSpeed: pointerSpeed,
                    cursorHeight: cursorSizeDefault.points,
                    touchGestures: touchGestures.configuration,
                    showsLocalCursor: pane.showsLocalCursor,
                    brightnessGain: brightnessManager.effectiveGain,
                    hudSafeAreaEdges: pane.hudSafeAreaEdges)

                KVMSessionOverlay(pane: pane)
            }
            .modifier(KVMLoginPasswordDialog(pane: pane))
        }
        .ignoresSafeArea(.container, edges: pane.isDetachedForFullScreen ? .all : [])
        .confirmationDialog(
            pane.pendingATXAction.map { Self.confirmationTitle($0) } ?? "",
            isPresented: Binding(
                get: { pane.pendingATXAction != nil },
                set: { if !$0 { pane.pendingATXAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pane.pendingATXAction {
                Button(Self.actionTitle(action), role: .destructive) {
                    pane.session.atxPower(action)
                    pane.pendingATXAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pane.pendingATXAction = nil }
        } message: {
            Text("The remote computer loses any unsaved work.")
        }
    }

    static func actionTitle(_ action: KVMATXAction) -> String {
        switch action {
        case .on: String(localized: "Power On")
        case .off: String(localized: "Shut Down")
        case .offHard: String(localized: "Force Power Off")
        case .resetHard: String(localized: "Hard Reset")
        }
    }

    private static func confirmationTitle(_ action: KVMATXAction) -> String {
        switch action {
        case .offHard: String(localized: "Force the remote computer off?")
        case .resetHard: String(localized: "Hard reset the remote computer?")
        case .on, .off: actionTitle(action)
        }
    }
}

/// Owns the session observation the remote-screen view needs, so state the
/// HUD reads doesn't rebuild the input layer.
private struct KVMScreenContent: View {
    let pane: KVMPaneView
    @Bindable private var session: KVMSession
    let pointerSpeed: Double
    let cursorHeight: CGFloat
    let touchGestures: RemoteTouchGestureConfiguration
    let showsLocalCursor: Bool
    let brightnessGain: Double
    let hudSafeAreaEdges: Edge.Set

    init(
        pane: KVMPaneView,
        pointerSpeed: Double,
        cursorHeight: CGFloat,
        touchGestures: RemoteTouchGestureConfiguration,
        showsLocalCursor: Bool,
        brightnessGain: Double,
        hudSafeAreaEdges: Edge.Set
    ) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
        self.pointerSpeed = pointerSpeed
        self.cursorHeight = cursorHeight
        self.touchGestures = touchGestures
        self.showsLocalCursor = showsLocalCursor
        self.brightnessGain = brightnessGain
        self.hudSafeAreaEdges = hudSafeAreaEdges
    }

    var body: some View {
        RemoteScreenView(
            renderer: session.renderer,
            framebufferSize: session.interactionFrameSize,
            isInteractive: session.connectionState.isConnected,
            input: session.input,
            keyboardCapture: pane.keyboardCapture,
            isFullScreen: pane.isDetachedForFullScreen,
            toggleFullScreen: { pane.requestToggleFullScreen() },
            keyboardAvoidanceMode: .hostManaged,
            hudSafeAreaEdges: hudSafeAreaEdges,
            initialViewportPanningMode: pane.initialViewportPanningMode,
            initialPointerMode: pane.initialPointerMode,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            serverRendersCursor: true,
            showsLocalCursorDot: showsLocalCursor,
            touchGestures: touchGestures,
            brightnessGain: brightnessGain,
            disconnect: { session.disconnect() },
            hudMenuExtras: { KVMHUDMenuExtras(pane: pane) })
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        .hudAccessory(
            isEnabled: pane.keyboardCoordinator?.hudModel.barEnabled ?? false,
            docksToBottom: pane.keyboardCoordinator?.hudModel.docksToBottom ?? false,
            buttonStyle: { width in
                pane.keyboardCoordinator?.hudModel.buttonStyle(availableWidth: width) ?? .standard
            },
            behind: { width in
                if let coordinator = pane.keyboardCoordinator {
                    RemoteScreenHUDToolbar(coordinator: coordinator, availableWidth: width)
                }
            },
            beside: { style in
                if let coordinator = pane.keyboardCoordinator {
                    RemoteScreenHUDButtons(coordinator: coordinator, style: style)
                }
            })
        #endif
    }
}

// MARK: - HUD

/// Observes the session itself: the remote-screen view captures its menu
/// extras once, so they must invalidate on their own.
private struct KVMHUDMenuExtras: View {
    let pane: KVMPaneView
    @Bindable private var session: KVMSession

    init(pane: KVMPaneView) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
    }

    private var connected: Bool { session.connectionState.isConnected }

    var body: some View {
        if session.isTypingText {
            Button(role: .destructive) {
                session.cancelTyping()
            } label: {
                Label("Stop Typing", systemImage: "stop.circle")
            }
        } else {
            Button {
                pane.pasteClipboard()
            } label: {
                Label("Paste as Keystrokes", systemImage: "doc.on.clipboard")
            }
            .disabled(!connected)
        }

        if pane.loginPassword.profileID != nil {
            Button {
                pane.loginPassword.requestSend()
            } label: {
                Label("Type Computer Password", systemImage: "key.fill")
            }
            .disabled(!pane.loginPassword.canSend || session.isTypingText)
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if let coordinator = pane.keyboardCoordinator {
            RemoteScreenFloatingToolbarMenuToggle(coordinator: coordinator)
        }
        #endif

        Menu {
            ForEach(KVMQualityPreset.allCases, id: \.self) { preset in
                Button {
                    session.setQualityPreset(preset)
                } label: {
                    Label(
                        Self.title(for: preset),
                        systemImage: session.streamer.currentPreset == preset ? "checkmark" : Self.icon(for: preset))
                }
                .disabled(!connected || session.streamer.currentPreset == preset)
            }
            if let zeroDelay = session.streamer.zeroDelay {
                Divider()
                Toggle(isOn: Binding(
                    get: { zeroDelay },
                    set: { session.setLatencyMode($0) }
                )) {
                    Label("Latency Mode", systemImage: "bolt")
                }
                .disabled(!connected)
            }
            Divider()
            Button {
                session.refreshVideo()
            } label: {
                Label("Refresh Video", systemImage: "arrow.clockwise")
            }
            .disabled(!connected)
        } label: {
            Label("Video Quality", systemImage: "film")
        }

        if session.atx.enabled {
            Menu {
                Section(session.atx.powerOn == true
                    ? String(localized: "Computer is on")
                    : String(localized: "Computer is off")) {
                    if session.atx.powerOn != true {
                        Button {
                            session.atxPower(.on)
                        } label: {
                            Label(KVMPaneRootView.actionTitle(.on), systemImage: "power")
                        }
                    } else {
                        Button {
                            session.atxPower(.off)
                        } label: {
                            Label(KVMPaneRootView.actionTitle(.off), systemImage: "power")
                        }
                    }
                    Button(role: .destructive) {
                        pane.pendingATXAction = .offHard
                    } label: {
                        Label(KVMPaneRootView.actionTitle(.offHard), systemImage: "bolt.slash")
                    }
                    Button(role: .destructive) {
                        pane.pendingATXAction = .resetHard
                    } label: {
                        Label(KVMPaneRootView.actionTitle(.resetHard), systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Label("Power", systemImage: "power")
            }
            .disabled(!connected || session.atx.busy)
        }

        Menu {
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            KVMKeyboardToolbarToggle(pane: pane)
            #endif
            KVMLocalCursorToggle(pane: pane)
            Button {
                NotificationCenter.default.post(name: .vncShowConnectionInfo, object: pane)
            } label: {
                Label("Connection Info", systemImage: "info.circle")
            }
            .disabled(!connected)
        } label: {
            Label("Session", systemImage: "gearshape")
        }
    }

    private static func title(for preset: KVMQualityPreset) -> String {
        switch preset {
        case .auto: String(localized: "Automatic", comment: "KVM video quality preset")
        case .low: String(localized: "Low · 0.5 Mbps", comment: "KVM video quality preset")
        case .medium: String(localized: "Medium · 2 Mbps", comment: "KVM video quality preset")
        case .high: String(localized: "High · 5 Mbps", comment: "KVM video quality preset")
        case .ultra: String(localized: "Ultra · 8 Mbps", comment: "KVM video quality preset")
        case .lossless: String(localized: "Lossless · 20 Mbps", comment: "KVM video quality preset")
        }
    }

    private static func icon(for preset: KVMQualityPreset) -> String {
        switch preset {
        case .auto: "wand.and.stars"
        case .low: "speedometer"
        case .medium, .high, .ultra: "dial.medium"
        case .lossless: "sparkles"
        }
    }
}

#if !os(visionOS) && !targetEnvironment(macCatalyst)
private struct KVMKeyboardToolbarToggle: View {
    @ObservedObject var pane: KVMPaneView

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

private struct KVMLocalCursorToggle: View {
    @ObservedObject var pane: KVMPaneView

    var body: some View {
        Toggle(isOn: $pane.showsLocalCursor) {
            Label("Local Cursor", systemImage: "smallcircle.filled.circle")
        }
    }
}

// MARK: - Computer password

/// Confirms before the profile's computer password is typed, whether the
/// HUD asked or a login screen was detected.
private struct KVMLoginPasswordDialog: ViewModifier {
    @Bindable private var assistant: KVMLoginPasswordAssistant
    @Bindable private var session: KVMSession

    init(pane: KVMPaneView) {
        self._assistant = Bindable(wrappedValue: pane.loginPassword)
        self._session = Bindable(wrappedValue: pane.session)
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(localized: "Type the computer password?"),
                isPresented: $assistant.isConfirming,
                titleVisibility: .visible
            ) {
                Button("Type Password and Log In") {
                    assistant.send(pressingReturn: true)
                }
                Button("Type Password Only") {
                    assistant.send(pressingReturn: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
            .alert(
                String(localized: "Couldn't Type Password"),
                isPresented: Binding(
                    get: { assistant.sendFailureMessage != nil },
                    set: { if !$0 { assistant.sendFailureMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(assistant.sendFailureMessage ?? "")
            }
            .onAppear { assistant.presentPendingPrompt() }
            .onChange(of: assistant.promptPending) { _, pending in
                if pending { assistant.presentPendingPrompt() }
            }
            .onChange(of: session.connectionState.isConnected) { _, connected in
                if !connected { assistant.isConfirming = false }
            }
    }

    private var message: String {
        let base = String(localized: "The computer password saved in this profile will be typed into the remote computer. Type Password Only skips Return so you can submit it yourself.")
        guard session.hid.capsLock == true else { return base }
        return base + " " + String(localized: "Caps Lock is on.")
    }
}

// MARK: - Session cards

private struct KVMSessionOverlay: View {
    @ObservedObject private var pane: KVMPaneView
    @Bindable private var session: KVMSession

    init(pane: KVMPaneView) {
        self.pane = pane
        self._session = Bindable(wrappedValue: pane.session)
    }

    var body: some View {
        ZStack(alignment: .top) {
            card
            if session.isTypingText {
                KVMTypingBanner { session.cancelTyping() }
                    .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        let subtitle = pane.config.displayName
        if pane.needsPassword {
            KVMPasswordCard(
                subtitle: subtitle,
                rejected: pane.passwordRejected,
                onSubmit: { password, save in pane.submitPassword(password, save: save) },
                onCancel: { pane.cancelConnectionAttempt() })
        } else if let prompt = session.pendingAuthPrompt {
            switch prompt {
            case .oneTimeCode:
                KVMOneTimeCodeCard(
                    subtitle: subtitle,
                    onSubmit: { session.submitOneTimeCode($0) },
                    onCancel: { pane.cancelConnectionAttempt() })
            case .approveOnDevice:
                VNCConnectingCard(
                    subtitle: subtitle,
                    status: String(localized: "Approve this sign-in on the KVM's screen."),
                    onCancel: { pane.cancelConnectionAttempt() })
            }
        } else {
            switch session.connectionState {
            case .connecting:
                VNCConnectingCard(
                    subtitle: subtitle,
                    status: session.phaseDescription.isEmpty
                        ? String(localized: "Opening connection…")
                        : session.phaseDescription,
                    onCancel: { pane.cancelConnectionAttempt() })
            case .reconnecting(let attempt, let delay):
                VNCReconnectCard(
                    subtitle: subtitle,
                    attempt: attempt,
                    delay: delay,
                    onStop: { session.disconnect() })
            case .failed(let reason):
                if !pane.isDetachedForFullScreen {
                    VNCConnectionFailureCard(
                        subtitle: subtitle,
                        message: reason,
                        onRetry: { pane.retryRemoteConnection() },
                        onCancel: { pane.cancelFailedConnection() })
                }
            case .connected:
                if session.streamer.sourceOnline == false {
                    KVMNoVideoCard(waiting: false, subtitle: subtitle)
                } else if !session.hasFirstFrame {
                    KVMNoVideoCard(waiting: true, subtitle: subtitle)
                }
            default:
                EmptyView()
            }
        }
    }
}

private struct KVMPasswordCard: View {
    let subtitle: String
    let rejected: Bool
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var savePassword = true
    @FocusState private var focused: Bool

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "KVM Password"),
            subtitle: subtitle,
            icon: {
                Image(systemName: rejected ? "exclamationmark.lock" : "lock")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(rejected ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .symbolRenderingMode(.hierarchical)
            },
            content: {
                VStack(spacing: 14) {
                    Text(rejected
                        ? String(localized: "The KVM rejected that password. Enter it again.")
                        : String(localized: "Enter the KVM's web interface password."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    KVMCardField {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focused)
                            .onSubmit(submit)
                    }

                    Toggle("Save Password", isOn: $savePassword)
                        .font(.callout)

                    HStack(spacing: 10) {
                        Button(role: .cancel, action: onCancel) {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: submit) {
                            Label("Connect", systemImage: "arrow.right")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: 320)
            })
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password, savePassword)
    }
}

private struct KVMOneTimeCodeCard: View {
    let subtitle: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @FocusState private var focused: Bool

    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        VNCOverlayCard(
            title: String(localized: "Verification Code"),
            subtitle: subtitle,
            icon: {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            },
            content: {
                VStack(spacing: 14) {
                    Text("Enter the 6-digit code from your authenticator app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    KVMCardField {
                        TextField("123456", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .font(.system(.title3, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .focused($focused)
                            .onSubmit(submit)
                            .onChange(of: code) { _, _ in
                                if digits.count == 6 { submit() }
                            }
                    }

                    HStack(spacing: 10) {
                        Button(role: .cancel, action: onCancel) {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: submit) {
                            Text("Verify").fontWeight(.semibold).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(digits.count != 6)
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: 320)
            })
        .onAppear { focused = true }
    }

    private func submit() {
        guard digits.count == 6 else { return }
        onSubmit(digits)
    }
}

/// Shown while connected without video. Keyboard and mouse pass through to
/// the computer, which is how a sleeping display wakes up.
private struct KVMNoVideoCard: View {
    /// No frame yet, versus the device reporting no signal.
    let waiting: Bool
    let subtitle: String

    var body: some View {
        VNCOverlayCard(
            title: waiting ? String(localized: "Waiting for Video") : String(localized: "No Video Signal"),
            subtitle: subtitle,
            icon: {
                if waiting {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
            },
            content: {
                Text(waiting
                    ? String(localized: "If the computer's display is asleep, press a key or move the pointer to wake it.")
                    : String(localized: "The computer connected to the KVM isn't sending video. It may be asleep or turned off. Press a key or move the pointer to wake it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            })
        .allowsHitTesting(false)
    }
}

private struct KVMTypingBanner: View {
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Typing…").font(.callout.weight(.medium))
            Button("Stop", role: .destructive, action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct KVMCardField<Field: View>: View {
    @ViewBuilder let field: () -> Field

    var body: some View {
        field()
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}
