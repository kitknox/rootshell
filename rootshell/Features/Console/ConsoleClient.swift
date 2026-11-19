//
//  ConsoleClient.swift
//  rootshell
//
//  WebSocket client for cloud console access (LISH, etc.)
//  Simpler than KubernetesExecClient - no channel multiplexing
//

import Foundation
import os
import os.log

/// Cloud console WebSocket client
/// Implements a simple text-based protocol for console I/O
@MainActor
final class ConsoleClient {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ConsoleClient")

    // MARK: - Properties

    // These are marked nonisolated(unsafe) to allow cleanup in deinit
    // They are only accessed from the main actor during normal operation
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var webSocketTask: URLSessionWebSocketTask?
    nonisolated(unsafe) private var receiveTask: Task<Void, Never>?

    private(set) var isConnected: Bool = false

    /// Continuation resumed by `handleOpen`/`handleClose` so `waitForConnection`
    /// doesn't have to poll. Polling on a `@MainActor` class queues a Task per
    /// 100 ms wake on the main actor — wasted work that adds up under load.
    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// Output queued while the app is backgrounded. The WebSocket keeps
    /// receiving (URLSession is platform-managed), but we don't dispatch
    /// per-message MainActor work — that backlog is what stalls the main
    /// thread on resume. Bounded so a chatty remote doesn't grow the buffer
    /// into jetsam; oldest bytes are dropped when the cap is hit. Drained
    /// by `flushBackgroundedOutput()` when the session resumes.
    private nonisolated let backgroundedBuffer = BoundedDataBuffer()

    /// Host terminal, so a backlog release can mute that terminal's bells
    /// from the WebSocket receive Task. `let` — read off the main actor.
    private nonisolated let terminalUUID: UUID?

    init(terminalUUID: UUID? = nil) {
        self.terminalUUID = terminalUUID
    }

    /// A backlog is about to reach the terminal. Those bells rang while we
    /// were backgrounded and the core dropped them; replaying the bytes
    /// must not resurrect them. Mirrors the trzsz chokepoint in
    /// `TrzszGoTransport.flushBackgroundedOutput`.
    private nonisolated func suppressBellsForReplay(_ drained: Data) {
        guard !drained.isEmpty, let terminalUUID else { return }
        TerminalBellSuppressor.suppress(
            terminalUUID, for: TerminalBellSuppressor.forcedRedraw)
    }

    // MARK: - Callbacks

    /// Called when data is received from the console
    /// NOTE: May be called from WebSocket task. Must be thread-safe.
    /// Backed by a `nonisolated` lock so `forwardOutput()` can call it from
    /// the WebSocket receive Task without bouncing through the main actor.
    var onOutput: (@Sendable (Data) -> Void)? {
        get { onOutputBox.withLock { $0 } }
        set { onOutputBox.withLock { $0 = newValue } }
    }
    private nonisolated let onOutputBox = OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>(initialState: nil)

    /// Called when the connection is closed
    /// The string contains the close reason if available
    var onClose: ((String?) -> Void)?

    /// Called when the connection is established
    var onOpen: (() -> Void)?

    // MARK: - Connection

    /// Connect to a console WebSocket endpoint
    /// - Parameters:
    ///   - url: The WebSocket URL (e.g., weblish_url from LISH API)
    ///   - protocols: WebSocket subprotocols for authentication
    func connect(url: URL, protocols: [String]) async throws {
        Self.logger.info("Connecting to console WebSocket: \(url.host ?? "unknown")")

        // Create URL session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300  // 5 minutes for console sessions

        let delegate = ConsoleURLSessionDelegate()
        delegate.onOpen = { [weak self] in
            Task { @MainActor in
                self?.handleOpen()
            }
        }
        delegate.onClose = { [weak self] closeCode, reason in
            Task { @MainActor in
                self?.handleClose(closeCode: closeCode, reason: reason)
            }
        }

        let newSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = newSession

        // Create WebSocket request
        // LISH auth is done via subprotocols, not headers
        var request = URLRequest(url: url)
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")

        // Create WebSocket task
        let wsTask = newSession.webSocketTask(with: request)
        self.webSocketTask = wsTask

        // Start the connection
        wsTask.resume()

        // Wait for connection with timeout
        try await withTimeout(seconds: 30) {
            try await self.waitForConnection()
        }

        Self.logger.info("Console WebSocket connected, starting receive loop")

        // Start receive loop
        startReceiveLoop()
    }

    /// Wait for the WebSocket connection to open. Resumed by `handleOpen` (via
    /// the URLSession delegate), `handleClose`, or `disconnect()`; also resumed
    /// with a `CancellationError` if the surrounding Task is cancelled. The
    /// outer `connect()` wraps this in `withTimeout(seconds: 30)` for the
    /// happy-path timeout.
    private func waitForConnection() async throws {
        if isConnected { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Race: open arrived between the `isConnected` check and
                // storing the continuation? Re-check and resume immediately.
                if isConnected {
                    cont.resume()
                    return
                }
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                connectContinuation = cont
            }
        } onCancel: {
            // Outer Task cancelled. Hop to MainActor to safely access the
            // continuation slot. If `handleOpen`/`handleClose`/`disconnect`
            // already resumed, the slot is nil and this is a no-op.
            Task { @MainActor [weak self] in
                self?.failConnectContinuation(with: CancellationError())
            }
        }
    }

    /// Fail any pending `waitForConnection` continuation. Called from
    /// `handleClose`, `disconnect`, and the cancellation handler so the
    /// continuation never leaks if the WebSocket dies before
    /// `urlSession(_:webSocketTask:didOpenWithProtocol:)` fires.
    private func failConnectContinuation(with error: Error) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume(throwing: error)
    }

    /// Handle WebSocket open event
    private func handleOpen() {
        Self.logger.info("Console WebSocket connection opened")
        isConnected = true
        onOpen?()
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume()
        }
    }

    /// Handle WebSocket close event
    private func handleClose(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        Self.logger.info("Console WebSocket closed: \(closeCode.rawValue) - \(reasonString ?? "no reason")")
        isConnected = false

        failConnectContinuation(with: ConsoleError.connectionFailed(reasonString ?? "Connection closed"))

        // Check for session expiration (LISH-specific)
        if let reasonString = reasonString, reasonString.lowercased().contains("expired") {
            onClose?("Session expired")
        } else {
            onClose?(reasonString)
        }
    }

    // MARK: - Receive Loop

    /// Start the background receive loop
    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                guard let wsTask = self.webSocketTask, self.isConnected else {
                    break
                }

                do {
                    let message = try await wsTask.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        Self.logger.error("Console WebSocket receive error: \(error.localizedDescription)")
                        await MainActor.run {
                            self.isConnected = false
                            self.onClose?(error.localizedDescription)
                        }
                    }
                    break
                }
            }
        }
    }

    /// Handle a received WebSocket message
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .data(let data):
            // Check if this is a JSON error message (LISH sends these)
            if let jsonError = parseErrorMessage(data) {
                Self.logger.warning("Console error: \(jsonError)")
                if jsonError.lowercased().contains("expired") {
                    await MainActor.run {
                        self.isConnected = false
                        self.onClose?("Session expired")
                    }
                }
            } else {
                forwardOutput(data)
            }

        case .string(let string):
            // Check if this is a JSON error message
            if let jsonError = parseErrorMessage(string) {
                Self.logger.warning("Console error: \(jsonError)")
                if jsonError.lowercased().contains("expired") {
                    await MainActor.run {
                        self.isConnected = false
                        self.onClose?("Session expired")
                    }
                }
            } else if let data = string.data(using: .utf8) {
                forwardOutput(data)
            }

        @unknown default:
            Self.logger.warning("Unknown WebSocket message type")
        }
    }

    /// Forward terminal output. While backgrounded, accumulate into a buffer
    /// that's flushed on `flushBackgroundedOutput()`. Otherwise call `onOutput`
    /// directly — it's `@Sendable`, so no main-actor trampoline is needed.
    nonisolated private func forwardOutput(_ data: Data) {
        if Ghostty.isAppBackgroundedAtomic {
            backgroundedBuffer.append(data)
            return
        }
        let callback = onOutputBox.withLock { $0 }
        // Flush any backlog from the most recent background period before
        // this chunk so output stays ordered. Note: drained data may have
        // had oldest bytes dropped (logged in flushBackgroundedOutput's path).
        if let drained = backgroundedBuffer.drain() {
            if drained.droppedDuringBackground > 0 {
                Self.logger.warning("Console buffer dropped \(drained.droppedDuringBackground) bytes during background")
            }
            suppressBellsForReplay(drained.data)
            callback?(drained.data)
        }
        callback?(data)
    }

    /// Drain any output queued during a background period. Called from
    /// `flushBackgroundedOutput()` (via `pauseForBackground`/`resumeForForeground`
    /// hooks at a higher level), and on a best-effort basis on the next message.
    nonisolated func flushBackgroundedOutput() {
        guard let drained = backgroundedBuffer.drain() else { return }
        if drained.droppedDuringBackground > 0 {
            Self.logger.warning("Console buffer dropped \(drained.droppedDuringBackground) bytes during background")
        }
        suppressBellsForReplay(drained.data)
        onOutputBox.withLock { $0 }?(drained.data)
    }

    /// Parse potential JSON error message from LISH
    /// Returns the error reason if this is an error message, nil otherwise
    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "error",
              let reason = json["reason"] as? String else {
            return nil
        }
        return reason
    }

    /// Parse potential JSON error message from string
    private func parseErrorMessage(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parseErrorMessage(data)
    }

    // MARK: - Send Methods

    /// Submit each message to the current socket in keyboard event order.
    func sendInput(_ data: Data) {
        guard isConnected, let wsTask = webSocketTask else {
            Self.logger.warning("Cannot send input: console is disconnected")
            return
        }
        wsTask.send(.data(data)) { error in
            if let error { Self.logger.error("Failed to send input: \(error.localizedDescription)") }
        }
    }

    // MARK: - Disconnect

    /// Disconnect from the console
    func disconnect() {
        Self.logger.info("Disconnecting console client")

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil

        isConnected = false

        // Resume any pending waitForConnection so callers don't leak.
        // (URLSession's didCloseWith may not fire for explicit cancel.)
        failConnectContinuation(with: ConsoleError.connectionClosed("Disconnected"))
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
}

// MARK: - URLSession Delegate

/// URLSession delegate for console WebSocket connections
final class ConsoleURLSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }
}

// MARK: - Timeout Helper

/// Execute an async operation with a timeout
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Add the main operation
        group.addTask {
            try await operation()
        }

        // Add timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConsoleError.connectionFailed("Connection timeout after \(Int(seconds)) seconds")
        }

        // Return first completed result
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
