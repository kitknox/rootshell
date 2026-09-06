//
//  BackgroundTunnel.swift
//  rootshell
//
//  Individual background tunnel instance - headless SSH connection for port forwarding
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
@preconcurrency import Citadel
import NIOCore
import NIOSSH
import os.log

/// State of a background tunnel
enum TunnelState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    var isActive: Bool {
        switch self {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

/// A background SSH tunnel that maintains port forwards without a terminal
@MainActor
@Observable
final class BackgroundTunnel {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BackgroundTunnel")

    /// Profile ID this tunnel belongs to
    let profileID: UUID

    /// SSH configuration
    let sshConfig: SSHConfig

    /// Profile name for display
    let profileName: String

    /// Connection protocol (SSH vs TSSH)
    let connectionProtocol: ConnectionProtocol

    /// Transport mode for TSSH connections
    let trzszTransportMode: ProfileTransportMode

    /// TSSH packet MTU override (nil = default)
    let trzszMTU: Int?

    /// TSSH UDP port range overrides (nil = global setting)
    let trzszPortMin: Int?
    let trzszPortMax: Int?

    /// Current state
    private(set) var state: TunnelState = .disconnected

    /// When waiting between automatic reconnection attempts, the time of the
    /// next attempt (drives the "Next Attempt" countdown in the detail view)
    private(set) var nextRetryAt: Date?

    /// Statistics for this tunnel
    private(set) var statistics: TunnelStatistics

    // MARK: - Private State

    /// Active SSH client (Citadel path)
    private var client: SSHClient?

    /// Jump host client (if using jump host)
    private var jumpClient: SSHClient?

    /// Port forward manager (Citadel path)
    private var portForwardManager: PortForwardManager?

    /// Go transport (TSSH path)
    private var goTransport: TrzszGoTransport?

    /// TSSH port forward manager (TSSH path)
    private var trzszPortForwardManager: TrzszPortForwardManager?

    /// TSSH health monitoring task
    private var tsshHealthTask: Task<Void, Never>?

    /// Reconnection manager
    private var reconnectionManager: ReconnectionManager?

    /// Health monitor for detecting connection death
    private var healthMonitor: ConnectionHealthMonitor?

    /// Count of consecutive SSH errors for connection death detection
    private var consecutiveSSHErrors: Int = 0

    /// Threshold for declaring connection dead based on SSH errors
    private static let sshErrorThreshold = 3

    /// Whether stop was user-initiated
    private var userInitiatedStop: Bool = false

    /// Connection timeout
    private static let connectionTimeout: TimeInterval = 120

    // MARK: - Callbacks

    /// Called when tunnel emits an event
    var onEvent: ((TunnelEvent) -> Void)?

    /// Called when state changes
    var onStateChange: ((TunnelState) -> Void)?

    /// Called when statistics update
    var onStatisticsUpdate: ((TunnelStatistics) -> Void)?

    /// Called for host key validation
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    // MARK: - Initialization

    init(profileID: UUID, sshConfig: SSHConfig, profileName: String, connectionProtocol: ConnectionProtocol = .ssh, trzszTransportMode: ProfileTransportMode = .default, trzszMTU: Int? = nil, trzszPortMin: Int? = nil, trzszPortMax: Int? = nil) {
        self.profileID = profileID
        self.sshConfig = sshConfig
        self.profileName = profileName
        self.connectionProtocol = connectionProtocol
        self.trzszTransportMode = trzszTransportMode
        self.trzszMTU = trzszMTU
        self.trzszPortMin = trzszPortMin
        self.trzszPortMax = trzszPortMax
        self.statistics = TunnelStatistics(tunnelID: profileID)
    }

    // MARK: - Public Methods

    /// Start the tunnel connection
    func start() async throws {
        // Allow starting from reconnecting state (called by reconnect())
        guard !state.isActive || state.isReconnecting else {
            Self.logger.warning("Tunnel already active, ignoring start request")
            return
        }

        Self.logger.info("Starting background tunnel for \(self.profileName)")

        userInitiatedStop = false
        statistics.reset()
        statistics.markStarted()

        transition(to: .connecting)
        emitEvent(.info(tunnelID: profileID, message: "Connecting to \(sshConfig.host)"))

        do {
            // Initialize reconnection manager if needed
            if reconnectionManager == nil {
                initializeReconnectionManager()
            }

            switch connectionProtocol {
            case .trzsz:
                try await connectTSSH()
                await startTSSHPortForwards()
                startTSSHHealthMonitoring()
            case .ssh, .mosh:
                let resolvedConfig = try await sshConfig.resolvedConfig()
                try await connect(using: resolvedConfig)
                await startPortForwards()
                startHealthMonitoring()
            case .vnc, .local:
                // VNC profiles are never VPN-capable (isVPNCapable excludes them)
                throw TunnelError.connectionFailed("This profile type cannot run tunnels")
            }
            transition(to: .connected)
            reconnectionManager?.handleConnected()
            emitEvent(.connected(tunnelID: profileID, message: "Connected to \(sshConfig.host)"))
        } catch {
            let errorMessage: String
            if error is HostKeyRejectedError || error is InvalidHostKey {
                errorMessage = "Host key for \(sshConfig.host) is not trusted (unknown or changed). Start the tunnel from Settings to review it."
            } else {
                errorMessage = error.localizedDescription
            }
            Self.logger.error("Failed to connect: \(errorMessage)")
            transition(to: .failed(errorMessage))
            emitEvent(.error(tunnelID: profileID, message: errorMessage))
            throw error
        }
    }

    /// Stop the tunnel
    func stop() async {
        Self.logger.info("Stopping background tunnel for \(self.profileName)")
        userInitiatedStop = true

        // Stop the reconnection loop first — with persistent retry it never
        // exhausts on its own and would keep resurrecting the connection.
        reconnectionManager?.cancelReconnection()

        await cleanup()
        transition(to: .disconnected)
        emitEvent(.disconnected(tunnelID: profileID, reason: "Stopped by user"))
    }

    /// Reconnect the tunnel
    func reconnect() async {
        Self.logger.info("Reconnecting tunnel for \(self.profileName)")

        await cleanup()
        transition(to: .reconnecting(attempt: 1))
        emitEvent(.reconnecting(tunnelID: profileID, attempt: 1))

        do {
            try await start()
            emitEvent(.reconnected(tunnelID: profileID))
        } catch {
            Self.logger.error("Reconnection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Connection Methods

    private func connect(using config: SSHConfig) async throws {
        let result = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation
        )

        self.client = result.client
        self.jumpClient = result.jumpClient

        // Register for disconnect callback
        result.client.onDisconnect { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSSHDisconnect(isJumpHost: false)
            }
        }

        // Register jump host disconnect callback if applicable
        if let jumpClient = self.jumpClient {
            jumpClient.onDisconnect { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleSSHDisconnect(isJumpHost: true)
                }
            }
        }

        Self.logger.info("SSH connection established")
    }

    private func startPortForwards() async {
        guard let client = client else { return }

        let config = sshConfig.portForwardConfig
        guard config.hasActiveForwards else {
            Self.logger.info("No port forwards configured")
            return
        }

        let manager = PortForwardManager(client: client, config: config)

        manager.onForwardError = { [weak self] forward, error in
            guard let self = self else { return }
            Self.logger.error("Port forward \(forward.displayString) failed: \(error.localizedDescription)")
            Task { @MainActor in
                self.emitEvent(.forwardFailed(
                    tunnelID: self.profileID,
                    forwardID: forward.id,
                    error: error.localizedDescription
                ))
            }
        }

        manager.onForwardStatusChange = { [weak self] forward, status in
            guard let self = self else { return }
            Task { @MainActor in
                switch status {
                case .active:
                    self.emitEvent(.forwardStarted(
                        tunnelID: self.profileID,
                        forwardID: forward.id,
                        description: forward.displayString
                    ))
                case .stopped:
                    self.emitEvent(.forwardStopped(
                        tunnelID: self.profileID,
                        forwardID: forward.id,
                        description: forward.displayString
                    ))
                case .failed(let error):
                    self.emitEvent(.forwardFailed(
                        tunnelID: self.profileID,
                        forwardID: forward.id,
                        error: error
                    ))
                case .pending:
                    break
                }
            }
        }

        // Wire up byte counting callbacks
        manager.onBytesReceived = { [weak self] forwardID, bytes in
            Task { @MainActor [weak self] in
                self?.recordBytesIn(bytes, forwardID: forwardID)
            }
        }

        manager.onBytesSent = { [weak self] forwardID, bytes in
            Task { @MainActor [weak self] in
                self?.recordBytesOut(bytes, forwardID: forwardID)
            }
        }

        // Wire up connection tracking callbacks
        manager.onConnectionOpened = { [weak self] forwardID in
            Task { @MainActor [weak self] in
                self?.statistics.recordConnectionOpened(forwardID: forwardID)
            }
        }

        manager.onConnectionClosed = { [weak self] forwardID in
            Task { @MainActor [weak self] in
                self?.statistics.recordConnectionClosed(forwardID: forwardID)
            }
        }

        // Wire up connection death detection
        manager.onConnectionDead = { [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.warning("Port forward manager detected connection death")
                self?.handleSSHDisconnect(isJumpHost: false)
            }
        }

        self.portForwardManager = manager

        await manager.startAllForwards()
        Self.logger.info("Port forwards started")
    }

    // MARK: - TSSH Connection Methods

    private func connectTSSH() async throws {
        let transport = try await TrzszHeadlessConnector.connect(
            sshConfig: sshConfig,
            transportMode: trzszTransportMode.resolved,
            udpPortMin: trzszPortMin ?? TrzszConfig.preferredUDPPortMin,
            udpPortMax: trzszPortMax ?? TrzszConfig.preferredUDPPortMax,
            mtu: trzszMTU ?? 0,
            displayName: "tunnel \(sshConfig.displayName)",
            onHostKeyValidation: onHostKeyValidation
        )

        self.goTransport = transport
        Self.logger.info("TSSH: Go transport connected for tunnel")
    }

    private func startTSSHPortForwards() async {
        let config = sshConfig.portForwardConfig
        guard config.hasActiveForwards else {
            Self.logger.info("TSSH: No port forwards configured")
            return
        }

        guard let manager = goTransport?.makePortForwardManager(config: config) else {
            Self.logger.error("TSSH: No underlying transport for port forwards")
            return
        }

        manager.onForwardError = { [weak self] forward, error in
            guard let self else { return }
            Self.logger.error("Port forward \(forward.displayString) failed: \(error.localizedDescription)")
            self.emitEvent(.forwardFailed(
                tunnelID: self.profileID,
                forwardID: forward.id,
                error: error.localizedDescription
            ))
        }

        manager.onForwardStatusChange = { [weak self] forward, status in
            guard let self else { return }
            switch status {
            case .active:
                self.emitEvent(.forwardStarted(
                    tunnelID: self.profileID,
                    forwardID: forward.id,
                    description: forward.displayString
                ))
            case .stopped:
                self.emitEvent(.forwardStopped(
                    tunnelID: self.profileID,
                    forwardID: forward.id,
                    description: forward.displayString
                ))
            case .failed(let error):
                self.emitEvent(.forwardFailed(
                    tunnelID: self.profileID,
                    forwardID: forward.id,
                    error: error
                ))
            case .pending:
                break
            }
        }

        manager.onBytesReceived = { [weak self] forwardID, bytes in
            Task { @MainActor [weak self] in
                self?.recordBytesIn(bytes, forwardID: forwardID)
            }
        }

        manager.onBytesSent = { [weak self] forwardID, bytes in
            Task { @MainActor [weak self] in
                self?.recordBytesOut(bytes, forwardID: forwardID)
            }
        }

        manager.onConnectionOpened = { [weak self] forwardID in
            self?.statistics.recordConnectionOpened(forwardID: forwardID)
        }

        manager.onConnectionClosed = { [weak self] forwardID in
            self?.statistics.recordConnectionClosed(forwardID: forwardID)
        }

        manager.onConnectionDead = { [weak self] in
            Self.logger.warning("TSSH port forward manager detected connection death")
            self?.handleTSSHDisconnect()
        }

        self.trzszPortForwardManager = manager
        await manager.startAllForwards()
        Self.logger.info("TSSH port forwards started")
    }

    private func startTSSHHealthMonitoring() {
        tsshHealthTask?.cancel()
        var consecutiveTimeouts = 0

        tsshHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }

                if self.goTransport?.isTimeout == true {
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts >= 3 {
                        Self.logger.warning("TSSH health: 3 consecutive timeouts (15s), connection dead")
                        self.handleTSSHDisconnect()
                        break
                    }
                } else {
                    consecutiveTimeouts = 0
                }
            }
        }
    }

    private func handleTSSHDisconnect() {
        guard !userInitiatedStop else { return }
        guard state.isActive else { return }

        Self.logger.warning("TSSH connection lost")

        tsshHealthTask?.cancel()
        tsshHealthTask = nil

        trzszPortForwardManager?.stopAllForwards()
        trzszPortForwardManager = nil

        goTransport?.disconnect()
        goTransport = nil

        emitEvent(.error(tunnelID: profileID, message: "TSSH connection lost"))

        if let reconnectionManager, reconnectionManager.config.enabled {
            reconnectionManager.handleDisconnect(reason: .serverClosed)
        } else {
            transition(to: .failed("TSSH connection lost"))
        }
    }

    private func cleanup() async {
        // Stop health monitoring first
        healthMonitor?.stop()
        healthMonitor = nil

        // Stop TSSH health monitoring
        tsshHealthTask?.cancel()
        tsshHealthTask = nil

        // Reset SSH error counter
        consecutiveSSHErrors = 0

        // Stop port forwards (Citadel path)
        if let manager = portForwardManager {
            await manager.stopAllForwards()
            portForwardManager = nil
        }

        // Stop port forwards (TSSH path)
        trzszPortForwardManager?.stopAllForwards()
        trzszPortForwardManager = nil

        // Disconnect Go transport (TSSH path)
        goTransport?.disconnect()
        goTransport = nil

        // Close SSH clients (Citadel path)
        if let jumpClient = jumpClient {
            try? await jumpClient.close()
            self.jumpClient = nil
        }

        if let client = client {
            try? await client.close()
            self.client = nil
        }

        Self.logger.info("Tunnel cleanup completed")
    }

    // MARK: - State Management

    private func transition(to newState: TunnelState) {
        let oldState = state
        state = newState

        if oldState != newState {
            Self.logger.debug("Tunnel state: \(oldState.displayName) -> \(newState.displayName)")
            onStateChange?(newState)
        }
    }

    private func emitEvent(_ event: TunnelEvent) {
        onEvent?(event)
    }

    // MARK: - Statistics

    /// Record bytes received
    func recordBytesIn(_ bytes: Int, forwardID: UUID) {
        statistics.recordBytesIn(bytes, forwardID: forwardID)
        onStatisticsUpdate?(statistics)
    }

    /// Record bytes sent
    func recordBytesOut(_ bytes: Int, forwardID: UUID) {
        statistics.recordBytesOut(bytes, forwardID: forwardID)
        onStatisticsUpdate?(statistics)
    }


    // MARK: - Health Monitoring

    /// Start health monitoring for the SSH connection
    private func startHealthMonitoring() {
        guard let client = client else { return }

        // Use 60 second ping interval for background tunnels (less aggressive than interactive sessions)
        let monitor = ConnectionHealthMonitor(client: client, pingInterval: 60.0)

        monitor.onHealthUpdate = { [weak self] health in
            Task { @MainActor [weak self] in
                self?.evaluateHealth(health)
            }
        }

        monitor.start()
        self.healthMonitor = monitor
        Self.logger.info("Started health monitoring with 60s interval")
    }

    /// Evaluate connection health and trigger disconnect if connection appears dead
    private func evaluateHealth(_ health: ConnectionHealth) {
        // If we have 100% packet loss for 3+ consecutive pings, consider connection dead
        // With 60s interval and 5 min window, this means ~5 samples
        // We trigger on 3 consecutive failures (3 minutes of no response)
        if health.totalPings >= 3 && health.packetLossPercent >= 100.0 {
            Self.logger.warning("Health monitor detected 100% packet loss over \(health.totalPings) pings")
            handleSSHDisconnect(isJumpHost: false)
        }
    }

    // MARK: - Disconnect Handling

    /// Handle SSH disconnect (from onDisconnect callback, health monitor, or port forward failures)
    private func handleSSHDisconnect(isJumpHost: Bool) {
        // Guard against user-initiated stop
        guard !userInitiatedStop else {
            Self.logger.debug("Ignoring disconnect during user-initiated stop")
            return
        }

        // Guard against already-inactive state
        guard state.isActive else {
            Self.logger.debug("Ignoring disconnect for already inactive tunnel")
            return
        }

        let source = isJumpHost ? "jump host" : "target"
        Self.logger.warning("SSH connection lost (\(source))")

        // Stop health monitor first
        healthMonitor?.stop()
        healthMonitor = nil

        // Stop all port forwards (stops TCP listeners so they don't accept connections that can't forward)
        Task {
            await portForwardManager?.stopAllForwards()
            portForwardManager = nil
        }

        // Clear client references
        client = nil
        if isJumpHost {
            jumpClient = nil
        }

        // Emit error event
        emitEvent(.error(tunnelID: profileID, message: "SSH connection lost (\(source))"))

        // Trigger reconnection instead of immediately failing
        if let reconnectionManager = reconnectionManager, reconnectionManager.config.enabled {
            reconnectionManager.handleDisconnect(reason: .serverClosed)
        } else {
            transition(to: .failed("SSH connection lost"))
        }
    }

    // MARK: - Reconnection Manager

    /// Initialize the reconnection manager with callbacks
    private func initializeReconnectionManager() {
        var config = ReconnectionManager.Config.fromUserDefaults()
        // Background tunnels never give up: after the standard burst, keep
        // retrying on the long-tier schedule, and fast-track a pending retry
        // when the network path changes (e.g. a VPN comes up). A tunnel the
        // user enabled should outlive transient outages.
        config.persistentRetry = true
        config.reconnectOnNetworkPathChange = true
        let manager = ReconnectionManager(config: config)
        let tunnelProfileID = self.profileID

        manager.onReconnectAttempt = { [weak self] in
            guard let self = self else {
                throw TunnelError.connectionFailed("Tunnel deallocated")
            }

            // Clean up existing state
            await self.cleanup()

            // stop() may have raced the cleanup above
            guard !self.userInitiatedStop else { throw CancellationError() }

            // Attempt reconnection based on protocol
            switch self.connectionProtocol {
            case .trzsz:
                try await self.connectTSSH()
                await self.startTSSHPortForwards()
                self.startTSSHHealthMonitoring()
            case .ssh, .mosh:
                let resolvedConfig = try await self.sshConfig.resolvedConfig()
                try await self.connect(using: resolvedConfig)
                await self.startPortForwards()
                self.startHealthMonitoring()
            case .vnc, .local:
                // VNC profiles are never VPN-capable (isVPNCapable excludes them)
                throw TunnelError.connectionFailed("This profile type cannot run tunnels")
            }

            // stop() may have run while the connect was awaiting (cooperative
            // cancellation can't abort it). Its cleanup() has already come and
            // gone, so tear down the resources this attempt just created.
            if self.userInitiatedStop || Task.isCancelled {
                await self.cleanup()
                throw CancellationError()
            }
        }

        manager.onReconnected = { [weak self] in
            guard let self = self else { return }
            self.emitEvent(.reconnected(tunnelID: tunnelProfileID))
            self.transition(to: .connected)
        }

        manager.onStateChange = { [weak self] state in
            guard let self = self else { return }

            if case .waitingToReconnect(_, let delay) = state {
                self.nextRetryAt = Date().addingTimeInterval(delay)
            } else {
                self.nextRetryAt = nil
            }

            switch state {
            case .waitingToReconnect(let attempt, _), .reconnecting(let attempt):
                self.transition(to: .reconnecting(attempt: attempt))
                self.emitEvent(.reconnecting(tunnelID: tunnelProfileID, attempt: attempt))
            case .manualReconnectRequired:
                self.transition(to: .failed("Max reconnection attempts reached"))
            case .failed(let reason):
                self.transition(to: .failed(reason))
            default:
                break
            }
        }

        manager.onGiveUp = { [weak self] in
            guard let self = self else { return }
            self.emitEvent(.error(tunnelID: tunnelProfileID, message: "Max reconnection attempts reached"))
        }

        self.reconnectionManager = manager
        Self.logger.info("Initialized reconnection manager")
    }

    // MARK: - Errors

    enum TunnelError: LocalizedError {
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let reason):
                return "Connection failed: \(reason)"
            }
        }
    }
}
