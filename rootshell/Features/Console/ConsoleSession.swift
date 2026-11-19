//
//  ConsoleSession.swift
//  rootshell
//
//  TerminalSession implementation for cloud console access (LISH, etc.)
//

import Foundation
import os.log
import Combine

/// Terminal session that provides console access to cloud VMs via WebSocket
@MainActor
final class ConsoleSession: TerminalSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ConsoleSession")

    // MARK: - Properties

    let pty: TerminalPTY
    let config: ConsoleConfig

    private(set) var isRunning: Bool = false

    /// Current session state
    @Published private(set) var state: ConsoleState = .initial

    private var consoleClient: ConsoleClient?

    /// Host terminal, forwarded to the client so a backlog release can mute
    /// that terminal's bells.
    private nonisolated let terminalUUID: UUID?
    private nonisolated let outputSink: OutputSink
    private nonisolated let outputBatcher: OutputBatcher

    // MARK: - TerminalSession Callbacks
    // NOTE: These callbacks may be called from a background thread.
    // Callers must ensure thread-safe handling.

    var onOutput: (@Sendable (String) -> Void)? {
        didSet {
            outputSink.update(onOutput: onOutput, onOutputData: onOutputData)
        }
    }
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet {
            outputSink.update(onOutput: onOutput, onOutputData: onOutputData)
        }
    }
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Callback for unexpected disconnection (for reconnection support)
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    /// Whether this session supports auto-reconnect
    var supportsAutoReconnect: Bool { true }

    // Connection metadata
    private(set) var connectionStartTime: Date?

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        return .console(
            provider: config.providerID,
            instance: config.instanceLabel,
            connectedAt: startTime
        )
    }

    /// Flag to track if stop() was called by user action (vs unexpected disconnect)
    private var userInitiatedStop: Bool = false

    /// Additional callback for state changes (for spinner integration)
    var onStateChange: ((ConsoleState) -> Void)?

    // MARK: - Initialization

    init(pty: TerminalPTY, config: ConsoleConfig, terminalUUID: UUID? = nil) {
        self.pty = pty
        self.config = config
        self.terminalUUID = terminalUUID
        let outputSink = OutputSink()
        self.outputSink = outputSink
        self.outputBatcher = OutputBatcher(
            minBatchIntervalMs: 8,
            maxBatchIntervalMs: 32
        ) { [outputSink] data in
            // Called directly on batcher queue - NO MainActor crossing.
            // The onOutputData/onOutput callbacks must be thread-safe.
            outputSink.emit(data)
        }
    }

    // MARK: - TerminalSession Protocol

    func start() async throws {
        guard !isRunning else { return }

        Self.logger.info("Starting console session for instance: \(self.config.instanceLabel) (provider: \(self.config.providerID))")

        do {
            // Phase 1: Fetch console token
            transition(to: .fetchingToken)
            let lishData = try await fetchLishToken()

            // Phase 2: Connect WebSocket
            transition(to: .connecting)
            try await connectWebSocket(lishData)

            // Phase 3: Running
            isRunning = true
            connectionStartTime = Date()
            transition(to: .running)

            // Update title
            onTitleChange?(config.displayName)

            Self.logger.info("Console session ready for instance: \(self.config.instanceLabel)")
            onReady?()

        } catch {
            Self.logger.error("Failed to start console session: \(error.localizedDescription)")

            let consoleError: ConsoleError
            if let err = error as? ConsoleError {
                consoleError = err
            } else {
                consoleError = .connectionFailed(error.localizedDescription)
            }

            transition(to: .failed(consoleError))
            onError?(consoleError)

            throw consoleError
        }
    }

    func stop() {
        Self.logger.info("Stopping console session")

        // Mark this as user-initiated so we don't trigger reconnection
        userInitiatedStop = true

        let wasRunning = isRunning
        isRunning = false
        outputBatcher.flush()

        // Disconnect WebSocket
        consoleClient?.disconnect()
        consoleClient = nil

        transition(to: .terminated)

        if wasRunning {
            onSessionEnd?()
        }
    }

    /// Drain output that the WebSocket buffered while we were backgrounded
    /// (no work to pause — the output guard in `ConsoleClient.forwardOutput`
    /// keeps the main actor untouched while suspended).
    func resumeForForeground() {
        consoleClient?.flushBackgroundedOutput()
    }

    func sendInput(_ data: Data) {
        guard isRunning, let client = consoleClient else {
            Self.logger.warning("Cannot send input: session not ready")
            return
        }

        client.sendInput(data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size
        // LISH doesn't support resize over WebSocket in the same way
        // The terminal size is typically set when the connection is established
    }

    // MARK: - Private Methods

    private func transition(to newState: ConsoleState) {
        state = newState
        onStateChange?(newState)
        Self.logger.info("Console state transition: \(newState.statusDescription)")
    }

    /// Fetch LISH token from Linode API
    private func fetchLishToken() async throws -> LinodeLishData {
        Self.logger.info("Fetching LISH token for instance: \(self.config.providerInstanceId)")

        // Validate provider
        guard config.providerID == "linode" else {
            throw ConsoleError.unsupportedProvider(config.providerID)
        }

        // Get account
        guard let account = CloudAccountManager.shared.account(for: config.accountId) else {
            throw ConsoleError.accountNotFound
        }

        // Get credentials
        let credentials: CloudCredentials
        do {
            credentials = try CloudAccountManager.shared.getCredentials(for: account.id)
        } catch {
            throw ConsoleError.credentialsNotFound
        }

        // Create API client
        guard let apiClient = LinodeProvider.createAPIClient(credentials: credentials) as? LinodeAPIClient else {
            throw ConsoleError.tokenRequestFailed("Failed to create API client")
        }

        // Fetch LISH token
        do {
            let lishData = try await apiClient.getLishToken(instanceID: config.providerInstanceId)
            Self.logger.info("Got LISH token successfully")
            return lishData
        } catch {
            Self.logger.error("Failed to get LISH token: \(error.localizedDescription)")
            throw ConsoleError.tokenRequestFailed(error.localizedDescription)
        }
    }

    /// Connect to the console WebSocket
    private func connectWebSocket(_ lishData: LinodeLishData) async throws {
        Self.logger.info("Connecting to LISH WebSocket")

        guard let url = URL(string: lishData.weblishUrl) else {
            throw ConsoleError.connectionFailed("Invalid WebSocket URL")
        }

        let client = ConsoleClient(terminalUUID: terminalUUID)

        // Set up callbacks - capture batcher for thread-safe access
        let batcher = self.outputBatcher
        client.onOutput = { data in
            Task { @MainActor in
                batcher.enqueue(data)
            }
        }

        client.onClose = { [weak self] reason in
            guard let self = self else { return }
            Self.logger.info("Console connection closed: \(reason ?? "no reason")")
            batcher.flush()

            if self.isRunning {
                self.isRunning = false

                // Determine disconnect reason
                let consoleDisconnectReason: ConsoleState.DisconnectReason
                if let reason = reason, reason.lowercased().contains("expired") {
                    consoleDisconnectReason = .sessionExpired
                } else {
                    consoleDisconnectReason = .connectionLost
                }

                self.transition(to: .disconnected(reason: consoleDisconnectReason))

                // Check if this was user-initiated or unexpected
                if self.userInitiatedStop {
                    // User-initiated stop - end session normally
                    self.onSessionEnd?()
                } else if let onDisconnect = self.onDisconnect {
                    // Unexpected disconnect - trigger reconnection
                    let reconnectReason: ReconnectionManager.DisconnectReason
                    switch consoleDisconnectReason {
                    case .sessionExpired:
                        // Session expired is a permanent failure - don't auto-reconnect
                        self.onSessionEnd?()
                        return
                    case .connectionLost:
                        reconnectReason = .networkLost
                    case .userClosed, .sessionEnded:
                        // These are normal closes, not unexpected disconnects
                        self.onSessionEnd?()
                        return
                    }
                    onDisconnect(reconnectReason)
                    // Don't call onSessionEnd - let reconnection manager handle it
                } else {
                    // No reconnection handler - fall back to session end
                    self.onSessionEnd?()
                }
            }
        }

        client.onOpen = {
            Self.logger.info("Console WebSocket opened")
        }

        // Connect
        try await client.connect(url: url, protocols: lishData.wsProtocols)

        self.consoleClient = client
    }
}
