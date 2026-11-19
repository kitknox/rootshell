//
//  KubernetesExecClient.swift
//  rootshell
//
//  WebSocket exec client implementing the Kubernetes exec protocol
//

import Foundation
import os.log

/// Kubernetes exec WebSocket client
/// Implements the multiplexed channel protocol for stdin/stdout/stderr
@MainActor
final class KubernetesExecClient {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesExecClient")

    // MARK: - Channel IDs

    /// Kubernetes exec channel identifiers (SPDY multiplexing)
    enum Channel: UInt8 {
        case stdin = 0
        case stdout = 1
        case stderr = 2
        case error = 3
        case resize = 4

        // v5 protocol close signal
        static let close: UInt8 = 255
    }

    /// Kubernetes exec subprotocols (in order of preference)
    static let subprotocols = [
        "v5.channel.k8s.io",  // Latest with CLOSE support
        "v4.channel.k8s.io",  // Structured error stream
        "v3.channel.k8s.io",  // Terminal resize support
        "v2.channel.k8s.io",  // Base versioned protocol
        "channel.k8s.io"      // Original protocol
    ]

    // MARK: - Properties

    // These are marked nonisolated(unsafe) to allow cleanup in deinit
    // They are only accessed from the main actor during normal operation
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var webSocketTask: URLSessionWebSocketTask?
    nonisolated(unsafe) private var sessionDelegate: KubernetesURLSessionDelegate?
    nonisolated(unsafe) private var receiveTask: Task<Void, Never>?
    private var negotiatedProtocol: String?

    private(set) var isConnected: Bool = false

    // MARK: - Callbacks

    /// Called when data is received on stdout
    var onStdout: ((Data) -> Void)?

    /// Called when data is received on stderr
    var onStderr: ((Data) -> Void)?

    /// Called when an error message is received on the error channel
    var onError: ((String) -> Void)?

    /// Called when the connection is closed
    var onClose: ((String?) -> Void)?

    /// Called when the connection is established
    var onOpen: (() -> Void)?

    // MARK: - Connection

    /// Connect to a Kubernetes pod's exec endpoint
    /// - Parameters:
    ///   - authConfig: Authentication configuration
    ///   - podName: Name of the pod
    ///   - podType: Type of debug pod (determines default command)
    ///   - command: Command arguments to execute (defaults based on podType)
    func connect(
        authConfig: KubernetesAuthConfig,
        podName: String,
        podType: KubernetesDebugPodType = .nodeShell,
        command: [String]? = nil
    ) async throws {
        Self.logger.info("Connecting to exec endpoint for pod: \(podName)")

        // Build exec URL
        guard let execURL = KubernetesDebugPodSpec.execURL(
            serverURL: authConfig.serverURL,
            podName: podName,
            podType: podType,
            command: command
        ) else {
            throw KubernetesNodeShellError.execConnectionFailed("Failed to build exec URL")
        }

        Self.logger.debug("Exec URL: \(execURL.absoluteString)")

        // Create session with auth
        let (newSession, delegate) = authConfig.createSession()
        self.session = newSession
        self.sessionDelegate = delegate

        // Set up delegate callbacks
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

        // Create WebSocket request with auth headers
        var request = authConfig.createRequest(for: execURL)

        // Add subprotocol headers
        request.setValue(Self.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")

        // Create WebSocket task
        let wsTask = newSession.webSocketTask(with: request)
        self.webSocketTask = wsTask

        // Start the connection
        wsTask.resume()

        // Wait for connection with timeout
        try await withTimeout(seconds: 30) {
            try await self.waitForConnection()
        }

        Self.logger.info("WebSocket connected, starting receive loop")

        // Start receive loop
        startReceiveLoop()
    }

    /// Wait for the WebSocket connection to open
    private func waitForConnection() async throws {
        // Poll for connection state
        for _ in 0..<100 {  // 10 seconds max
            if isConnected {
                return
            }

            // Check WebSocket state by trying to receive
            if let wsTask = webSocketTask {
                switch wsTask.state {
                case .running:
                    // Connected!
                    isConnected = true
                    return
                case .suspended:
                    // Not started yet
                    break
                case .canceling, .completed:
                    throw KubernetesNodeShellError.execConnectionFailed("Connection failed or was cancelled")
                @unknown default:
                    break
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        throw KubernetesNodeShellError.execConnectionFailed("Connection timeout")
    }

    /// Handle WebSocket open event
    private func handleOpen() {
        Self.logger.info("WebSocket connection opened")
        isConnected = true
        onOpen?()
    }

    /// Handle WebSocket close event
    private func handleClose(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        Self.logger.info("WebSocket connection closed: \(closeCode.rawValue) - \(reasonString ?? "no reason")")
        isConnected = false
        onClose?(reasonString)
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
                        Self.logger.error("WebSocket receive error: \(error.localizedDescription)")
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
            await processChannelData(data)

        case .string(let string):
            // Kubernetes exec typically uses binary, but handle string just in case
            if let data = string.data(using: .utf8) {
                await processChannelData(data)
            }

        @unknown default:
            Self.logger.warning("Unknown WebSocket message type")
        }
    }

    /// Process data from a multiplexed channel
    private func processChannelData(_ data: Data) async {
        guard data.count > 0 else { return }

        let channelId = data[0]
        let payload = data.count > 1 ? data.dropFirst() : Data()

        switch channelId {
        case Channel.stdout.rawValue:
            await MainActor.run {
                self.onStdout?(Data(payload))
            }

        case Channel.stderr.rawValue:
            await MainActor.run {
                self.onStderr?(Data(payload))
            }

        case Channel.error.rawValue:
            // Error channel contains JSON with exit status or error message
            let errorMessage = String(data: Data(payload), encoding: .utf8) ?? "Unknown error"
            Self.logger.warning("Exec error channel: \(errorMessage)")
            await MainActor.run {
                self.onError?(errorMessage)
            }

        case Channel.close:
            // v5 close signal
            Self.logger.info("Received close signal")
            await MainActor.run {
                self.isConnected = false
                self.onClose?(nil)
            }

        default:
            Self.logger.debug("Unknown channel \(channelId) with \(payload.count) bytes")
        }
    }

    // MARK: - Send Methods

    /// Send data to stdin
    /// - Parameter data: The data to send
    func sendStdin(_ data: Data) {
        guard isConnected, let wsTask = webSocketTask else {
            Self.logger.warning("Cannot send input: exec session is disconnected")
            return
        }

        // Prepend channel ID
        var message = Data([Channel.stdin.rawValue])
        message.append(data)

        wsTask.send(.data(message)) { error in
            if let error { Self.logger.error("Failed to send input: \(error.localizedDescription)") }
        }
    }

    /// Send a terminal resize event
    /// - Parameters:
    ///   - cols: Number of columns
    ///   - rows: Number of rows
    func sendResize(cols: Int, rows: Int) {
        guard isConnected, let wsTask = webSocketTask else {
            Self.logger.warning("Cannot send resize: not connected")
            return
        }

        // Create resize JSON (note: Kubernetes uses capitalized keys)
        let resizeJSON: [String: Int] = [
            "Width": cols,
            "Height": rows
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: resizeJSON) else {
            Self.logger.error("Failed to serialize resize message")
            return
        }

        // Prepend channel ID
        var message = Data([Channel.resize.rawValue])
        message.append(jsonData)

        Self.logger.debug("Sending resize: \(cols)x\(rows)")

        wsTask.send(.data(message)) { error in
            if let error { Self.logger.warning("Failed to send resize: \(error.localizedDescription)") }
        }
    }

    // MARK: - Disconnect

    /// Disconnect from the exec session
    func disconnect() {
        Self.logger.info("Disconnecting exec client")

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil

        isConnected = false
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
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
            throw KubernetesNodeShellError.execConnectionFailed("Connection timeout after \(Int(seconds)) seconds")
        }

        // Return first completed result
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
