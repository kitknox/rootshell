//
//  KVMSession.swift
//  rootshell
//
//  One KVM over IP session: sign-in, the `/api/ws` control socket (state
//  events, HID input, streamer lease), the `/api/media/ws` H.264 stream,
//  device controls, and recovery. Only one control socket is opened per
//  session: kvmd releases every held key whenever any control socket opens
//  or closes.
//

import CoreGraphics
import CoreVideo
import Foundation
import os
import RFBProtocol
import RFBTransport
import rootshellVNC

@MainActor
@Observable
final class KVMSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KVM")

    enum AuthPrompt: Equatable {
        case oneTimeCode
        case approveOnDevice(expiresAt: Date)
    }

    struct Statistics: Equatable {
        var framesPerSecond: Double = 0
        var kilobitsPerSecond: Double = 0
        var roundTrip: TimeInterval?
        var keyframeRequests = 0
        var decodeErrors = 0
    }

    let config: KVMConnectionConfig
    let renderer: VideoBandLayerRenderer

    private(set) var connectionState: VNCConnectionState = .idle
    private(set) var phaseDescription = ""
    private(set) var framebufferSize: CGSize = .zero
    private(set) var hasFirstFrame = false
    private(set) var deviceInfo = KVMDeviceInfo()
    private(set) var streamer = KVMStreamerState()
    private(set) var hid = KVMHIDState()
    private(set) var atx = KVMATXState()
    private(set) var videoFormat: KVMVideoFormat?
    private(set) var statistics = Statistics()
    private(set) var pendingAuthPrompt: AuthPrompt?
    private(set) var isTypingText = false
    private(set) var certificateFingerprint: String?
    private(set) var lastError: KVMDError?
    private(set) var connectedAt: Date?

    /// Set by the pane before `connect`.
    @ObservationIgnored var onCertificateValidation: VNCConfiguration.CertificateValidationHandler?
    @ObservationIgnored var onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?

    // MARK: Connection internals

    @ObservationIgnored private var password = ""
    @ObservationIgnored private var bridge: KVMLoopbackBridge?
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored private var trustDelegate: KVMTrustDelegate?
    @ObservationIgnored private var client: KVMDClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var hasConnectedOnce = false
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var codeContinuation: CheckedContinuation<String, Error>?

    @ObservationIgnored private var eventSocket: URLSessionWebSocketTask?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var eventPingLoop: Task<Void, Never>?
    @ObservationIgnored private var lastEventHeard = Date()
    @ObservationIgnored private var streamerJSON: [String: Any] = [:]
    @ObservationIgnored private var hidJSON: [String: Any] = [:]
    @ObservationIgnored private var atxJSON: [String: Any] = [:]

    @ObservationIgnored private var mediaChannel: KVMMediaChannel?
    @ObservationIgnored private var mediaGeneration = 0
    @ObservationIgnored private var mediaFailures = 0
    @ObservationIgnored private var mediaReopenTask: Task<Void, Never>?
    @ObservationIgnored private var lastKeyframeRequest = Date.distantPast
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var presentedFrames = 0
    @ObservationIgnored private var decoder: KVMH264Decoder!
    private let frameCoalescer = KVMFrameCoalescer()

    // MARK: Input internals

    @ObservationIgnored private var translator = KVMInputTranslator()
    @ObservationIgnored private var outbound: [KVMInputOutput] = []
    @ObservationIgnored private var framesInFlight = 0
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    private static let maximumFramesInFlight = 32

    init(config: KVMConnectionConfig) {
        self.config = config
        renderer = VideoBandLayerRenderer()
        translator.hostLayout = config.hostKeyboardLayout
        renderer.configureExpectedBandCount(1)
        decoder = makeDecoder()
    }

    var usesTunnel: Bool { bridge != nil }

    /// Keyboard input must work before the first frame (to wake a sleeping
    /// computer), so the input layer gets a size even without video.
    var interactionFrameSize: CGSize {
        if framebufferSize.width > 0, framebufferSize.height > 0 { return framebufferSize }
        if let width = streamer.sourceWidth, let height = streamer.sourceHeight, width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 1920, height: 1080)
    }

    var displayLabel: String {
        deviceInfo.model.map { "\($0) (\(config.displayName))" } ?? config.displayName
    }

    // MARK: - Lifecycle

    func connect(password: String) {
        guard connectionState.canConnect else { return }
        self.password = password
        userDisconnected = false
        reconnectAttempt = 0
        lastError = nil
        connectionState = .connecting
        startConnect()
    }

    func retry() {
        guard connectionState.canConnect || connectionState.isConnecting else { return }
        connectTask?.cancel()
        teardown(keepTransport: false)
        userDisconnected = false
        reconnectAttempt = 0
        lastError = nil
        connectionState = .connecting
        startConnect()
    }

    /// The pane calls this after the user fixes a rejected password.
    func retry(password: String) {
        self.password = password
        retry()
    }

    func disconnect() {
        guard !userDisconnected else { return }
        userDisconnected = true
        connectTask?.cancel()
        codeContinuation?.resume(throwing: CancellationError())
        codeContinuation = nil
        pendingAuthPrompt = nil
        connectionState = .disconnecting
        enqueue(translator.releaseAll())
        let client = client
        teardown(keepTransport: true)
        Task {
            // Best effort: frees the device's session slot; the tunnel closes after.
            await client?.logout()
            self.closeTransport()
            self.connectionState = .disconnected
        }
    }

    func submitOneTimeCode(_ code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        pendingAuthPrompt = nil
        codeContinuation?.resume(returning: digits)
        codeContinuation = nil
    }

    func pauseForBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        enqueue(translator.releaseAll())
        closeMediaChannel()
        decoder.reset()
        renderer.setPresentationSuspended(true)
    }

    func resumeFromBackground() {
        guard isBackgrounded else { return }
        isBackgrounded = false
        renderer.setPresentationSuspended(false)
        guard connectionState.isConnected else {
            if case .reconnecting = connectionState { return }
            if !userDisconnected, lastError?.isTerminal != true, case .failed = connectionState { retry() }
            return
        }
        if eventSocket == nil {
            scheduleReconnect(after: .timedOut)
        } else {
            openMediaChannel()
        }
    }

    // MARK: - Connect sequence

    private func startConnect() {
        connectTask = Task { [weak self] in
            await self?.runConnect()
        }
    }

    private func runConnect() async {
        do {
            if client == nil {
                try await establishTransport()
            }
            try Task.checkCancellation()
            phaseDescription = String(localized: "Signing in…")
            try await authenticate()
            try Task.checkCancellation()
            phaseDescription = String(localized: "Reading device state…")
            try await loadDeviceState()
            try await ensureDirectH264()
            try Task.checkCancellation()
            phaseDescription = String(localized: "Opening control channel…")
            try await openEventSocket()
            phaseDescription = String(localized: "Starting video…")
            if !isBackgrounded {
                openMediaChannel()
            }
            reconnectAttempt = 0
            hasConnectedOnce = true
            if connectedAt == nil { connectedAt = Date() }
            connectionState = .connected
            startStatistics()
        } catch is CancellationError {
            return
        } catch {
            let kvmdError = Self.kvmdError(error)
            Self.logger.error("KVM connect failed: \(kvmdError.localizedDescription, privacy: .public)")
            // A first connect reports its failure; only a lost session retries.
            if !hasConnectedOnce {
                fail(kvmdError)
            } else {
                scheduleReconnect(after: kvmdError)
            }
        }
    }

    private func establishTransport() async throws {
        var baseHost = config.host
        var basePort = config.port
        let providers = try await RemoteScreenTransportFactory.providers(
            jump: config.jump,
            host: config.host,
            onHostKeyValidation: onHostKeyValidation)
        if let transport = providers.transport {
            phaseDescription = String(localized: "Opening tunnel…")
            let bridge = KVMLoopbackBridge(
                provider: transport,
                targetHost: config.host,
                targetPort: UInt16(clamping: config.port))
            let port = try await bridge.start()
            self.bridge = bridge
            baseHost = "127.0.0.1"
            basePort = Int(port)
        }

        guard let baseURL = KVMConnectionConfig.baseURL(host: baseHost, port: basePort) else {
            throw KVMDError.protocolError(String(localized: "invalid host name"))
        }
        let delegate = KVMTrustDelegate(
            host: config.host,
            port: UInt16(clamping: config.port),
            evaluatesPlatformTrust: bridge == nil,
            validate: onCertificateValidation)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        trustDelegate = delegate
        urlSession = session
        client = KVMDClient(baseURL: baseURL, session: session)
    }

    private func authenticate() async throws {
        guard let client else { throw KVMDError.protocolError("no client") }
        if client.token != nil {
            if (try? await client.call("GET", "/api/auth/check", timeout: 10)) != nil { return }
            client.token = nil
        }

        var code: String?
        if try await client.twoFactorEnabled() {
            code = try await awaitOneTimeCode()
            phaseDescription = String(localized: "Signing in…")
        }
        var outcome = try await client.login(user: config.username, password: password, oneTimeCode: code)
        certificateFingerprint = trustDelegate?.trustedFingerprint

        if case .twoStepRequired(let token, let expiresIn) = outcome {
            let deadline = Date().addingTimeInterval(TimeInterval(max(10, expiresIn)))
            pendingAuthPrompt = .approveOnDevice(expiresAt: deadline)
            defer { pendingAuthPrompt = nil }
            phaseDescription = String(localized: "Approve this sign-in on the KVM's screen…")
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                outcome = try await client.completeTwoStep(token: token)
                if case .token = outcome { break }
            }
            guard case .token = outcome else { throw KVMDError.twoStepExpired }
        }
    }

    private func awaitOneTimeCode() async throws -> String {
        phaseDescription = String(localized: "Waiting for verification code…")
        pendingAuthPrompt = .oneTimeCode
        return try await withCheckedThrowingContinuation { continuation in
            codeContinuation?.resume(throwing: CancellationError())
            codeContinuation = continuation
        }
    }

    private func loadDeviceState() async throws {
        guard let client else { return }
        let info = try await client.call("GET", "/api/info")
        var device = KVMDeviceInfo.parse(info: info)
        // GL.iNet only; other kvmd builds answer 404.
        if let version = try? await client.call("GET", "/api/upgrade/version", timeout: 5) {
            device.apply(upgradeVersion: version)
        }
        deviceInfo = device

        streamerJSON = try await client.call("GET", "/api/streamer")
        streamer = KVMStreamerState(merged: streamerJSON)
        hidJSON = (try? await client.call("GET", "/api/hid")) ?? [:]
        hid = KVMHIDState(merged: hidJSON)
        translator.mouseAbsolute = hid.mouseAbsolute
        atxJSON = (try? await client.call("GET", "/api/atx")) ?? [:]
        atx = KVMATXState(merged: atxJSON)
    }

    /// Direct mode needs H.264 from the encoder; GL's own UI switches a
    /// device left in H.265 back the same way. This restarts the device's
    /// encoder, so it only happens when needed.
    private func ensureDirectH264() async throws {
        guard streamer.supportsH264 else { throw KVMDError.directVideoUnavailable }
        guard let client, let format = streamer.videoFormat, format != 0 else { return }
        Self.logger.info("KVM switching the device encoder from format \(format) to H.264")
        try await client.call("POST", "/api/streamer/set_params", query: ["video_format": "0"])
    }

    // MARK: - Control socket

    private func openEventSocket() async throws {
        guard let client, let urlSession else { return }
        let task = urlSession.webSocketTask(with: client.webSocketRequest(path: "/api/ws", query: ["stream": "1"]))
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()

        // receive() ignores task cancellation; cancelling the socket ends it.
        let timedOut = KVMOnce()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, timedOut.fire() else { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        let first: URLSessionWebSocketTask.Message
        do {
            first = try await task.receive()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if !timedOut.fire() { throw KVMDError.timedOut }
            throw KVMMediaChannel.classify(error, response: task.response)
        }

        eventSocket = task
        lastEventHeard = Date()
        // The device released every key when this socket opened.
        translator.forgetHeldState()
        outbound.removeAll()
        framesInFlight = 0
        handleEventMessage(first)

        eventLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handleEventMessage(message)
                } catch {
                    self?.eventSocketEnded(task, error: KVMMediaChannel.classify(error, response: task.response))
                    return
                }
            }
        }
        eventPingLoop = Task { [weak self] in
            let ping = KVMDJSON.eventMessage("ping")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.eventSocket === task else { return }
                if Date().timeIntervalSince(self.lastEventHeard) > 10 {
                    Self.logger.error("KVM control socket stopped answering pings")
                    self.eventSocketEnded(task, error: .timedOut)
                    return
                }
                task.send(.string(ping)) { _ in }
            }
        }
    }

    private func handleEventMessage(_ message: URLSessionWebSocketTask.Message) {
        lastEventHeard = Date()
        guard case .string(let text) = message,
              let (type, event) = KVMDJSON.event(from: text) else { return }
        switch type {
        case "streamer":
            streamerJSON = KVMDJSON.merge(streamerJSON, event)
            let newStreamer = KVMStreamerState(merged: streamerJSON)
            if newStreamer != streamer { streamer = newStreamer }
        case "hid":
            hidJSON = KVMDJSON.merge(hidJSON, event)
            let newHID = KVMHIDState(merged: hidJSON)
            if newHID != hid { hid = newHID }
            translator.mouseAbsolute = hid.mouseAbsolute
        case "atx":
            atxJSON = KVMDJSON.merge(atxJSON, event)
            let newATX = KVMATXState(merged: atxJSON)
            if newATX != atx { atx = newATX }
        case "kickout":
            fail(.kickedOut(reason: event["reason"] as? String ?? "unknown"))
        default:
            break
        }
    }

    private func eventSocketEnded(_ task: URLSessionWebSocketTask, error: KVMDError) {
        guard eventSocket === task, !userDisconnected else { return }
        Self.logger.error("KVM control socket ended: \(error.localizedDescription, privacy: .public)")
        scheduleReconnect(after: error)
    }

    // MARK: - Video

    private func makeDecoder() -> KVMH264Decoder {
        let coalescer = frameCoalescer
        let owner = KVMWeakSession(self)
        return KVMH264Decoder(
            onFrame: { frame in
                coalescer.push(frame) { frame in
                    owner.session?.present(frame)
                }
            },
            onFormat: { format in
                Task { @MainActor in owner.session?.apply(format) }
            },
            onNeedsKeyframe: {
                Task { @MainActor in owner.session?.requestKeyframe() }
            })
    }

    private func openMediaChannel() {
        guard let client, let urlSession, eventSocket != nil else { return }
        closeMediaChannel()
        mediaGeneration += 1
        let generation = mediaGeneration
        let owner = KVMWeakSession(self)
        renderer.beginStreamGeneration(expectedBandCount: 1)
        let channel = KVMMediaChannel(
            session: urlSession,
            request: client.webSocketRequest(path: "/api/media/ws"),
            decoder: decoder
        ) { event in
            Task { @MainActor in owner.session?.handleMediaEvent(event, generation: generation) }
        }
        mediaChannel = channel
        channel.start()
    }

    private func closeMediaChannel() {
        mediaReopenTask?.cancel()
        mediaReopenTask = nil
        mediaChannel?.stop()
        mediaChannel = nil
    }

    private func handleMediaEvent(_ event: KVMMediaChannel.Event, generation: Int) {
        guard generation == mediaGeneration else { return }
        switch event {
        case .streaming:
            break
        case .roundTrip(let roundTrip):
            statistics.roundTrip = roundTrip
        case .ended(let error):
            mediaChannel = nil
            guard !userDisconnected, !isBackgrounded else { return }
            if let error, error.isTerminal {
                fail(error)
                return
            }
            if error == .unauthorized {
                scheduleReconnect(after: .unauthorized)
                return
            }
            // A quality change restarts the encoder and drops this socket; reopen
            // just the video and keep the control socket's key state.
            mediaFailures += 1
            guard mediaFailures <= 5 else {
                scheduleReconnect(after: error ?? .timedOut)
                return
            }
            let delay = min(5.0, 0.5 * Double(mediaFailures))
            mediaReopenTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.openMediaChannel()
            }
        }
    }

    private func apply(_ format: KVMVideoFormat) {
        videoFormat = format
        framebufferSize = CGSize(width: format.width, height: format.height)
        renderer.setScreenSize(width: format.width, height: format.height)
        translator.frameWidth = format.width
        translator.frameHeight = format.height
    }

    private func present(_ frame: KVMDecodedFrame) {
        guard mediaChannel != nil else { return }
        if !hasFirstFrame { hasFirstFrame = true }
        mediaFailures = 0
        presentedFrames += 1
        renderer.setBands([0: frame.pixelBuffer])
    }

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        statistics.keyframeRequests += 1
        mediaChannel?.requestKeyframe()
    }

    private func startStatistics() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let now = Date()
                let elapsed = max(0.001, now.timeIntervalSince(last))
                last = now
                let counters = self.mediaChannel?.drainCounters() ?? (bytes: 0, frames: 0)
                self.statistics.kilobitsPerSecond = Double(counters.bytes) * 8 / 1000 / elapsed
                self.statistics.framesPerSecond = Double(self.presentedFrames) / elapsed
                self.statistics.decodeErrors = self.decoder.errorCount
                self.presentedFrames = 0
            }
        }
    }

    // MARK: - Recovery

    private func scheduleReconnect(after error: KVMDError) {
        guard !userDisconnected else { return }
        if error.isTerminal {
            fail(error)
            return
        }
        teardown(keepTransport: true)
        reconnectAttempt += 1
        guard reconnectAttempt <= 8 else {
            fail(error)
            return
        }
        let base = min(30, pow(2, Double(reconnectAttempt - 1)))
        let delay = base * Double.random(in: 0.8...1.2)
        connectionState = .reconnecting(attempt: reconnectAttempt, delay: delay)
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // A dead tunnel fails fast; rebuilding it every other try recovers
            // from a bridge whose jump host went away.
            if self.reconnectAttempt % 2 == 0 { self.closeTransport() }
            await self.runConnect()
        }
    }

    private func fail(_ error: KVMDError) {
        lastError = error
        connectTask?.cancel()
        teardown(keepTransport: false)
        closeTransport()
        connectionState = .failed(error.localizedDescription)
    }

    private func teardown(keepTransport: Bool) {
        statsTask?.cancel()
        statsTask = nil
        closeMediaChannel()
        eventLoop?.cancel()
        eventPingLoop?.cancel()
        eventLoop = nil
        eventPingLoop = nil
        eventSocket?.cancel(with: .goingAway, reason: nil)
        eventSocket = nil
        typingTask?.cancel()
        typingTask = nil
        isTypingText = false
        outbound.removeAll()
        framesInFlight = 0
        translator.forgetHeldState()
        decoder.reset()
        hasFirstFrame = false
        if !keepTransport { closeTransport() }
    }

    private func closeTransport() {
        urlSession?.invalidateAndCancel()
        urlSession = nil
        client = nil
        trustDelegate = nil
        bridge?.stop()
        bridge = nil
    }

    private static func kvmdError(_ error: Error) -> KVMDError {
        if let kvmd = error as? KVMDError { return kvmd }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .cancelled, .secureConnectionFailed:
                return .protocolError(String(localized: "The KVM's certificate wasn't accepted."))
            default:
                return .protocolError(urlError.localizedDescription)
            }
        }
        return .protocolError(error.localizedDescription)
    }

    // MARK: - Input

    var input: RemoteScreenInput {
        RemoteScreenInput(
            sendPointer: { [weak self] mask, x, y in
                guard let self else { return }
                self.enqueue(self.translator.pointer(buttonMask: mask, x: Int(x), y: Int(y)))
            },
            sendScroll: { [weak self] event in
                guard let self else { return }
                // Apple scroll deltas are positive up and positive left.
                self.enqueue(self.translator.scroll(
                    x: Int(event.x), y: Int(event.y),
                    wheelX: -Int(event.deltaX), wheelY: Int(event.deltaY)))
            },
            sendKeysym: { [weak self] down, keysym in
                guard let self else { return }
                self.enqueue(self.translator.keysym(down: down, keysym: keysym))
            },
            sendPhysicalKey: { [weak self] down, usage, _ in
                guard let self else { return }
                self.enqueue(self.translator.physicalKey(down: down, usage: usage))
            })
    }

    /// Toolbar keys arrive as keysyms, the same as the package's own keys.
    func sendKeysym(down: Bool, keysym: UInt32) {
        enqueue(translator.keysym(down: down, keysym: keysym))
    }

    func releaseAllInput() {
        enqueue(translator.releaseAll())
    }

    /// Types `text` on the remote computer using the host layout.
    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue([.text(text)])
    }

    func cancelTyping() {
        outbound.removeAll { if case .text = $0 { true } else { false } }
        typingTask?.cancel()
    }

    private func enqueue(_ outputs: [KVMInputOutput]) {
        guard eventSocket != nil, !outputs.isEmpty else { return }
        for output in outputs {
            switch (output, outbound.last) {
            case (.frame(let frame), .frame(let last)?) where frame.first == 0x03 && last.first == 0x03:
                // Only the newest absolute position matters.
                outbound[outbound.count - 1] = output
            case (.text(let text), .text(let previous)?):
                outbound[outbound.count - 1] = .text(previous + text)
            default:
                outbound.append(output)
            }
        }
        pump()
    }

    /// Frames go out in order; text waits for earlier frames and later frames
    /// wait for the text, so a held modifier wraps device-typed characters.
    private func pump() {
        while let next = outbound.first, typingTask == nil {
            switch next {
            case .frame(let data):
                guard framesInFlight < Self.maximumFramesInFlight, let socket = eventSocket else { return }
                outbound.removeFirst()
                framesInFlight += 1
                let owner = KVMWeakSession(self)
                socket.send(.data(data)) { _ in
                    Task { @MainActor in owner.session?.frameSent(on: socket) }
                }
            case .text(let text):
                guard framesInFlight == 0, let client else { return }
                outbound.removeFirst()
                startTyping(text, client: client)
            }
        }
    }

    private func frameSent(on socket: URLSessionWebSocketTask) {
        guard socket === eventSocket else { return }
        framesInFlight = max(0, framesInFlight - 1)
        pump()
    }

    private func startTyping(_ text: String, client: KVMDClient) {
        let keymap = config.hostKeyboardLayout
        isTypingText = text.count > 16
        typingTask = Task { [weak self] in
            do {
                try await client.printText(text, keymap: keymap)
            } catch {
                if !(error is CancellationError) {
                    Self.logger.error("KVM typing failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let self else { return }
            self.typingTask = nil
            self.isTypingText = false
            self.pump()
        }
    }

    // MARK: - Device controls

    func setQualityPreset(_ preset: KVMQualityPreset) {
        setStreamerParameters(preset.parameters(from: streamer))
    }

    func setLatencyMode(_ enabled: Bool) {
        setStreamerParameters(["zero_delay": enabled ? "1" : "0"])
    }

    func refreshVideo() {
        lastKeyframeRequest = .distantPast
        requestKeyframe()
    }

    func atxPower(_ action: KVMATXAction) {
        guard let client else { return }
        Task {
            do {
                try await client.call("POST", "/api/atx/power", query: ["action": action.rawValue])
            } catch {
                Self.logger.error("KVM ATX \(action.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func setStreamerParameters(_ parameters: [String: String]) {
        guard let client, !parameters.isEmpty else { return }
        Task {
            do {
                try await client.call("POST", "/api/streamer/set_params", query: parameters)
            } catch {
                Self.logger.error("KVM streamer settings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Helpers

/// A weak session reference callbacks from other threads can carry; set once.
nonisolated final class KVMWeakSession: @unchecked Sendable {
    private(set) weak var session: KVMSession?

    init(_ session: KVMSession) {
        self.session = session
    }
}

/// Latest decoded frame wins; at most one main-queue hop is pending.
nonisolated final class KVMFrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: KVMDecodedFrame?
    private var scheduled = false

    func push(_ frame: KVMDecodedFrame, deliver: @escaping @MainActor @Sendable (KVMDecodedFrame) -> Void) {
        let shouldSchedule = lock.withLock {
            pending = frame
            defer { scheduled = true }
            return !scheduled
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            let frame = lock.withLock {
                defer {
                    pending = nil
                    scheduled = false
                }
                return pending
            }
            guard let frame else { return }
            MainActor.assumeIsolated { deliver(frame) }
        }
    }
}

