//
//  MoshTransport.swift
//  rootshell
//
//  UDP transport layer for mosh protocol using Network.framework
//

import Foundation
import Network
import OSLog

/// Mosh UDP transport layer
///
/// Manages the UDP connection to mosh-server using Apple's Network.framework.
/// Handles:
/// - UDP connection establishment
/// - Packet encryption/decryption
/// - Network path changes (roaming)
/// - Heartbeat scheduling
@MainActor
final class MoshTransport {

    // MARK: - Types

    /// Transport state
    enum State: Equatable, Sendable {
        case initial
        case connecting
        case connected
        case roaming(previousPath: String)
        case disconnected
        case failed(reason: String)
    }

    /// Delegate for transport events
    protocol Delegate: AnyObject, Sendable {
        /// Called when transport state changes
        @MainActor func transport(_ transport: MoshTransport, didChangeState state: State)

        /// Called when a decrypted packet is received
        /// - Parameters:
        ///   - transport: The transport
        ///   - packet: The decrypted packet
        ///   - estimatedRTT: Current RTT estimate in ms (for synchronous sendInterval update)
        @MainActor func transport(_ transport: MoshTransport, didReceivePacket packet: MoshPacket, estimatedRTT: Double)

        /// Called when an error occurs
        @MainActor func transport(_ transport: MoshTransport, didEncounterError error: MoshError)
    }

    /// Health metrics for reactive hole-punch monitoring
    struct HealthMetrics: Sendable {
        /// Last time we received any UDP data (monotonic timestamp ms)
        let lastReceiveTimeMs: UInt64

        /// Number of packets sent
        let packetsSent: Int

        /// Number of packets received
        let packetsReceived: Int

        /// Current RTT estimate in milliseconds (nil if unknown)
        let currentRTTMs: Int?

        /// Time since last receive in milliseconds
        var timeSinceLastReceiveMs: UInt64 {
            let now = ProtocolTiming.monotonicNowMs()
            return now &- lastReceiveTimeMs
        }

        /// Whether the connection appears healthy (received data recently)
        func isHealthy(timeoutMs: UInt64) -> Bool {
            timeSinceLastReceiveMs < timeoutMs
        }
    }

    // MARK: - Properties

    /// Current transport state
    private(set) var state: State = .initial

    /// The delegate for transport events
    weak var delegate: Delegate?

    /// RTT estimator
    let rttEstimator = MoshRTTEstimator()

    /// The host we're connected to
    let host: String

    /// The UDP port
    let port: Int

    /// Requested local port for binding (0 = system assigned)
    /// Used for UDP hole-punching to ensure we bind to the same port
    /// that STUN discovered
    private let requestedLocalPort: UInt16

    /// Address family preference for local binding
    private let addressFamily: AddressFamily

    /// The actual local port bound after connection
    private(set) var boundLocalPort: UInt16?

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshTransport"
    )

    // MARK: - Private State

    /// Network connection
    private var connection: NWConnection?

    /// Crypto session
    private var crypto: MoshCryptoSession?

    /// Session key for reconnects
    private var sessionKey: MoshBase64Key?

    /// Whether reconnects are allowed
    private var allowReconnect = true

    /// Reconnect task (debounced)
    private var reconnectTask: Task<Void, Never>?

    /// Reconnect attempt counter
    private var reconnectAttempts = 0

    /// Bind retry counter (for EADDRINUSE handling)
    private var bindRetryAttempts = 0

    /// Maximum bind retry attempts (100ms each = 2 seconds max wait)
    private static let maxBindRetryAttempts = 20

    /// Bind retry task
    private var bindRetryTask: Task<Void, Never>?

    /// Last time we received any UDP data (monotonic ms)
    private var lastReceiveTime: UInt64 = 0

    /// Number of packets sent
    private var packetsSent: Int = 0

    /// Number of packets received
    private var packetsReceived: Int = 0

    /// Last known path satisfaction
    private var pathSatisfied = true

    /// Throttled log timestamps
    private var lastLogTime: [String: UInt64] = [:]

    /// Dispatch queue for network operations
    private let networkQueue = DispatchQueue(
        label: "com.rootshell.mosh.transport",
        qos: .userInitiated
    )

    /// Fragment assembler for incoming packets
    private let fragmentAssembler = MoshFragmentAssembler()

    /// Packet builder for outgoing packets
    private var packetBuilder: MoshPacketBuilder?

    /// Connection timeout in seconds
    private let connectionTimeout: TimeInterval = 15.0

    /// Whether we're currently connected
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Whether we should attempt to send (includes roaming/connecting)
    var canSend: Bool {
        guard connection != nil else { return false }
        switch state {
        case .failed, .disconnected:
            return false
        default:
            return true
        }
    }

    // MARK: - Initialization

    /// Creates a new transport for the given host and port
    /// - Parameters:
    ///   - host: The host to connect to
    ///   - port: The UDP port
    ///   - localPort: Optional local port to bind (0 = system assigned, used for hole-punching)
    ///   - addressFamily: Address family preference for local binding
    init(host: String, port: Int, localPort: UInt16 = 0, addressFamily: AddressFamily = .auto) {
        self.host = host
        self.port = port
        self.requestedLocalPort = localPort
        self.addressFamily = addressFamily
        self.packetBuilder = MoshPacketBuilder(direction: .toServer)
    }

    // MARK: - Connection

    /// Connects to the mosh-server
    /// - Parameter key: The session key from mosh-server
    func connect(key: MoshBase64Key) async throws {
        try await connect(key: key, resumeState: nil)
    }

    /// Resume state for connecting with saved sequence numbers
    struct ResumeState: Sendable {
        let outgoingSequence: UInt64
        let expectedIncomingSequence: UInt64
    }

    /// Connects to the mosh-server with optional resume state
    /// - Parameters:
    ///   - key: The session key from mosh-server
    ///   - resumeState: Optional saved state for session resume
    func connect(key: MoshBase64Key, resumeState: ResumeState?) async throws {
        let host = self.host
        let port = self.port
        Self.logger.info("MoshTransport.connect() called - host=\(host), port=\(port), resume=\(resumeState != nil)")

        guard state == .initial || state == .disconnected else {
            throw MoshError.sessionAlreadyStarted
        }

        allowReconnect = true
        reconnectAttempts = 0
        bindRetryAttempts = 0
        bindRetryTask?.cancel()
        bindRetryTask = nil
        sessionKey = key

        if let resume = resumeState {
            Self.logger.info("Resuming with outgoingSeq=\(resume.outgoingSequence), expectedIncoming=\(resume.expectedIncomingSequence)")
            crypto = MoshCryptoSession(
                key: key,
                isClient: true,
                outgoingSequence: resume.outgoingSequence,
                expectedIncoming: resume.expectedIncomingSequence
            )
        } else if crypto == nil {
            crypto = MoshCryptoSession(key: key, isClient: true)
        }
        lastReceiveTime = ProtocolTiming.monotonicNowMs()

        beginConnection()

        // Wait for connection with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                // Wait for connected state
                while self.state == .connecting {
                    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                }
                if case .failed(let reason) = self.state {
                    throw MoshError.udpConnectionFailed(host: self.host, port: self.port, reason: reason)
                }
            }

            group.addTask {
                // Timeout
                try await Task.sleep(nanoseconds: UInt64(self.connectionTimeout * 1_000_000_000))
                throw MoshError.connectionTimeout
            }

            // Wait for first to complete
            try await group.next()
            group.cancelAll()
        }
    }

    /// Returns the current crypto state for saving (for session resume)
    func getCryptoState() -> (outgoingSequence: UInt64, expectedIncoming: UInt64)? {
        guard let crypto = crypto else { return nil }
        let outgoing = crypto.currentOutgoingSequence
        let incoming = crypto.currentExpectedIncoming
        return (outgoing, incoming)
    }

    /// Returns current health metrics for monitoring
    func getHealthMetrics() -> HealthMetrics {
        let rtt = rttEstimator.latencyMs
        return HealthMetrics(
            lastReceiveTimeMs: lastReceiveTime,
            packetsSent: packetsSent,
            packetsReceived: packetsReceived,
            currentRTTMs: rtt
        )
    }

    /// Checks if the connection is healthy (received data within timeout)
    /// - Parameter timeoutMs: Timeout in milliseconds
    /// - Returns: true if healthy, false if possibly disconnected
    func isConnectionHealthy(timeoutMs: UInt64) -> Bool {
        let now = ProtocolTiming.monotonicNowMs()
        return (now &- lastReceiveTime) < timeoutMs
    }

    /// Disconnects the transport
    func disconnect() {
        // Set allowReconnect first to prevent race with state handler
        allowReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        bindRetryTask?.cancel()
        bindRetryTask = nil

        // Cancel connection after setting allowReconnect
        connection?.cancel()
        connection = nil

        setState(.disconnected)
    }

    /// Requests an immediate reconnect attempt (bypasses backoff).
    /// - Parameter force: If true, reconnect even if state is currently connected.
    func requestImmediateReconnect(reason: String, force: Bool = false) {
        scheduleReconnect(reason: reason, immediate: true, force: force)
    }

    // MARK: - Sending

    /// Sends data to the remote host
    /// - Parameter payload: The instruction payload to send
    func send(_ payload: Data) throws {
        guard let crypto = crypto else {
            throw MoshError.sessionNotStarted
        }

        guard let conn = connection, canSend else {
            throw MoshError.sendFailed(reason: "Not connected")
        }

        // Fragment the payload (mosh requires fragment header even for single fragments)
        let fragments = try MoshFragment.fragment(payload)
        let replyTimestamp = packetBuilder?.currentReplyTimestamp ?? 0

        for (index, fragment) in fragments.enumerated() {
            let timestamp = MoshTimestamp.now
            if index == 0 {
                rttEstimator.recordSent(timestamp: timestamp)
            }

            // Build plaintext: timestamps (4 bytes) + fragment header (10 bytes) + payload
            var plaintext = MoshTimestamp.encode(
                current: timestamp,
                reply: replyTimestamp
            )

            plaintext.append(fragment.serialized)

            // Encrypt
            let encrypted = try crypto.encrypt(plaintext)

            // Send via connection
            conn.send(content: encrypted, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.delegate?.transport(self, didEncounterError: .sendFailed(reason: error.localizedDescription))
                    }
                }
            })

            // Track packets sent
            packetsSent += 1
        }
    }

    // MARK: - Private Methods

    /// Sets up the connection state handler
    private func setupStateHandler(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Check if this is still our active connection
                guard conn === self.connection else { return }

                switch newState {
                case .ready:
                    let host = self.host
                    let port = self.port
                    Self.logger.info("UDP connection ready to \(host):\(port)")
                    self.reconnectAttempts = 0
                    self.bindRetryAttempts = 0
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.bindRetryTask?.cancel()
                    self.bindRetryTask = nil

                    // Capture the actual bound local port
                    if let localEndpoint = conn.currentPath?.localEndpoint,
                       case .hostPort(_, let localPort) = localEndpoint {
                        self.boundLocalPort = localPort.rawValue
                        Self.logger.debug("Bound to local port \(localPort.rawValue)")
                    }

                    self.setState(.connected)

                case .failed(let error):
                    if self.shouldLog("udp_failed", intervalMs: 1_000) {
                        Self.logger.error("UDP connection failed: \(error.localizedDescription)")
                    }
                    self.setState(.failed(reason: error.localizedDescription))
                    self.scheduleReconnect(reason: error.localizedDescription)

                case .cancelled:
                    // Only log; don't schedule reconnect since cancelled is intentional
                    // (allowReconnect is set to false before cancel() is called)
                    if self.shouldLog("udp_cancelled", intervalMs: 1_000) {
                        Self.logger.info("UDP connection cancelled")
                    }
                    self.setState(.disconnected)

                case .waiting(let error):
                    // Check if this is EADDRINUSE (error 48) - happens when STUN socket
                    // hasn't fully released the port yet. Retry with a short delay.
                    if self.isAddressInUseError(error) {
                        self.handleAddressInUseError(conn)
                        return
                    }

                    if self.shouldLog("udp_waiting", intervalMs: 2_000) {
                        Self.logger.warning("UDP connection waiting: \(error.localizedDescription)")
                    }
                    // Network path changed - we're roaming (mosh tolerates this)
                    self.setState(.roaming(previousPath: error.localizedDescription))

                default:
                    break
                }
            }
        }

        // Monitor path changes for roaming recovery
        conn.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard conn === self.connection else { return }

                if path.status == .satisfied {
                    self.pathSatisfied = true
                    // Only transition back to connected if we were roaming
                    if case .roaming = self.state {
                        Self.logger.info("Network path restored")
                        self.setState(.connected)
                    }
                } else {
                    self.pathSatisfied = false
                    if self.shouldLog("path_unsatisfied", intervalMs: 2_000) {
                        Self.logger.warning("Network path not satisfied: \(String(describing: path.status))")
                    }
                    // Transition to roaming if currently connected
                    if case .connected = self.state {
                        self.setState(.roaming(previousPath: "path unsatisfied"))
                    }
                }
            }
        }
    }

    private func beginConnection() {
        if let existing = connection {
            existing.cancel()
            connection = nil
        }
        // Create endpoint
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )

        // Configure UDP connection
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.allowFastOpen = true

        // Force IP version to match hole-punch configuration
        // This prevents dual-stack issues where we might use IPv6 when hole-punch used IPv4
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            switch addressFamily {
            case .ipv4:
                ipOptions.version = .v4
                Self.logger.info("Forcing IPv4 at protocol level")
            case .ipv6:
                ipOptions.version = .v6
                Self.logger.info("Forcing IPv6 at protocol level")
            case .auto:
                // Auto-detect from target host
                if host.contains(":") {
                    ipOptions.version = .v6
                    Self.logger.info("Auto-detected IPv6 from host")
                } else {
                    ipOptions.version = .v4
                    Self.logger.info("Auto-detected IPv4 from host")
                }
            }
        }

        // Bind to specific local port if requested (for hole-punching)
        if requestedLocalPort > 0 {
            // Determine local host based on address family
            let localHost: NWEndpoint.Host = switch addressFamily {
            case .ipv4: .ipv4(.any)
            case .ipv6: .ipv6(.any)
            case .auto:
                // Auto-detect from target host
                if host.contains(":") {
                    .ipv6(.any)
                } else {
                    .ipv4(.any)
                }
            }

            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: localHost,
                port: NWEndpoint.Port(rawValue: requestedLocalPort)!
            )
            Self.logger.info("Binding to local port \(self.requestedLocalPort) (family: \(self.addressFamily.rawValue))")
        }

        // Create connection
        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn

        // Set up state handler
        setupStateHandler(conn)

        // Set up receive handler
        setupReceiveHandler(conn)

        // Update state
        setState(.connecting)

        // Start connection
        conn.start(queue: networkQueue)
    }

    /// Maximum reconnect attempts before giving up
    private static let maxReconnectAttempts = 30

    private func scheduleReconnect(reason: String, immediate: Bool = false, force: Bool = false) {
        guard allowReconnect else { return }
        guard sessionKey != nil else { return }

        if !force {
            // Don't schedule if already connected or connecting
            switch state {
            case .connected:
                return
            case .connecting:
                // Already trying to connect
                return
            default:
                break
            }
        }

        // Don't schedule if there's already a pending reconnect
        if !immediate && reconnectTask != nil {
            return
        }

        // Cancel any existing reconnect task
        reconnectTask?.cancel()
        reconnectTask = nil

        // Check if we've exceeded max attempts
        if reconnectAttempts >= Self.maxReconnectAttempts {
            Self.logger.warning("Max reconnect attempts (\(Self.maxReconnectAttempts)) exceeded, giving up")
            setState(.failed(reason: "Connection lost after \(Self.maxReconnectAttempts) attempts"))
            return
        }

        // Calculate delay with exponential backoff (capped at 10 seconds)
        let baseDelayMs: Double = Double(ProtocolTiming.heartbeatIntervalMs)
        let delaySeconds = immediate
            ? 0.0
            : min(10.0, (baseDelayMs / 1000.0) * pow(1.5, Double(min(reconnectAttempts, 6))))

        reconnectTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            if delaySeconds > 0 {
                if self.shouldLog("reconnect", intervalMs: 2_000) {
                    Self.logger.info("Reconnecting in \(delaySeconds, format: .fixed(precision: 1))s (reason: \(reason), attempt \(self.reconnectAttempts + 1))")
                }
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            // Recheck conditions after delay
            guard self.allowReconnect else { return }

            // If force is set, always reconnect to rebind to new network interface
            if force {
                Self.logger.info("Force reconnecting to rebind socket (reason: \(reason))")
                self.connection?.cancel()
                self.connection = nil
                self.beginConnection()
                self.reconnectTask = nil
                return
            }

            guard case .connected = self.state else {
                // Not already connected, proceed with reconnect
                self.reconnectAttempts += 1
                self.connection?.cancel()
                self.connection = nil
                self.beginConnection()
                return
            }
            // Already connected, nothing to do
            self.reconnectTask = nil
        }
    }

    /// Sets up the receive handler
    private func setupReceiveHandler(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, isComplete, error in
            // Capture timestamp immediately on the network queue, before MainActor hop.
            // This avoids inflating RTT due to scheduling delays.
            let receiveTimestamp = content == nil ? nil : MoshTimestamp.now

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard conn === self.connection else { return }

                if let error = error {
                    self.delegate?.transport(self, didEncounterError: .receiveFailed(reason: error.localizedDescription))
                    return
                }

                if let data = content, let receiveTimestamp = receiveTimestamp {
                    self.handleReceivedData(data, receiveTimestamp: receiveTimestamp)
                }

                // Continue receiving as long as the connection exists
                if conn === self.connection {
                    self.setupReceiveHandler(conn)
                }
            }
        }
    }

    /// Minimum size for a valid mosh packet (8-byte nonce + 16-byte auth tag)
    private static let minimumPacketSize = 24

    /// Handles received data
    /// - Parameter data: The received UDP packet data
    /// - Parameter receiveTimestamp: The local timestamp captured at packet arrival (before async hops)
    private func handleReceivedData(_ data: Data, receiveTimestamp: UInt16) {
        lastReceiveTime = ProtocolTiming.monotonicNowMs()

        // Silently drop packets that are too small to be valid mosh packets
        // This handles stray UDP packets, hole-punch packets, etc.
        guard data.count >= Self.minimumPacketSize else {
            Self.logger.debug("Dropping undersized packet: \(data.count) bytes (min: \(Self.minimumPacketSize))")
            return
        }

        guard let crypto = crypto else { return }

        do {
            // Decrypt packet
            let (plaintext, nonce) = try crypto.decrypt(data)

            // Need at least 4 bytes timestamps + 10 bytes fragment header = 14 bytes
            guard plaintext.count >= 14 else {
                throw MoshError.invalidPacketFormat(
                    reason: "Packet plaintext too short: \(plaintext.count) bytes"
                )
            }

            // Parse timestamps (first 4 bytes)
            guard let (timestamp, replyTimestamp) = MoshTimestamp.decode(plaintext) else {
                throw MoshError.invalidPacketFormat(reason: "Failed to decode timestamps")
            }

            // Parse fragment (everything after 4-byte timestamp)
            let fragmentData = Data(plaintext.suffix(from: 4))
            let fragment = try MoshFragment.parse(fragmentData)

            // Add to fragment assembler
            guard let payload = fragmentAssembler.add(fragment) else {
                // Fragment is part of incomplete message, wait for more
                return
            }

            // Build packet with assembled payload
            let packet = MoshPacket(
                direction: nonce.direction,
                sequenceNumber: nonce.sequenceNumber,
                timestamp: timestamp,
                replyTimestamp: replyTimestamp,
                payload: payload
            )

            // Update RTT estimate from reply timestamp (skip sentinel 0xFFFF).
            // Pass the pre-captured receiveTimestamp to avoid inflated RTT from async delays.
            if packet.replyTimestamp != UInt16.max {
                rttEstimator.recordReply(replyTimestamp: packet.replyTimestamp, receiveTimestamp: receiveTimestamp)
            }

            // Get the updated RTT estimate to pass to delegate (for synchronous sendInterval update)
            let estimatedRTT = rttEstimator.estimatedRTT

            // Update packet builder with received timestamp for echo
            packetBuilder?.setReplyTimestamp(packet.timestamp)

            // Track packets received
            packetsReceived += 1

            // Deliver to delegate with RTT for immediate sendInterval update
            delegate?.transport(self, didReceivePacket: packet, estimatedRTT: estimatedRTT)

        } catch let error as MoshError {
            delegate?.transport(self, didEncounterError: error)
        } catch {
            Self.logger.error("Unexpected error processing packet: \(error.localizedDescription)")
        }
    }

    /// Updates state and notifies delegate
    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        delegate?.transport(self, didChangeState: newState)
    }

    private func shouldLog(_ key: String, intervalMs: UInt64) -> Bool {
        let now = ProtocolTiming.monotonicNowMs()
        if let last = lastLogTime[key], now &- last < intervalMs {
            return false
        }
        lastLogTime[key] = now
        return true
    }

    // MARK: - Bind Retry (EADDRINUSE handling)

    /// Checks if the error is EADDRINUSE (Address already in use, posix error 48)
    /// This happens when the STUN socket hasn't fully released the port yet.
    private func isAddressInUseError(_ error: NWError) -> Bool {
        // Check for posix error 48 (EADDRINUSE)
        if case .posix(let code) = error, code.rawValue == 48 {
            return true
        }
        // Also check the localized description as a fallback
        return error.localizedDescription.contains("Address already in use")
    }

    /// Handles EADDRINUSE by retrying the connection after a short delay.
    /// This allows the STUN socket to fully release before we try to bind.
    private func handleAddressInUseError(_ conn: NWConnection) {
        bindRetryAttempts += 1

        if bindRetryAttempts > Self.maxBindRetryAttempts {
            Self.logger.error("Max bind retry attempts (\(Self.maxBindRetryAttempts)) exceeded, giving up")
            setState(.failed(reason: "Address already in use - port binding failed"))
            return
        }

        Self.logger.info("Address in use (attempt \(self.bindRetryAttempts)/\(Self.maxBindRetryAttempts)), retrying in 100ms...")

        // Cancel the current connection attempt
        conn.cancel()
        connection = nil

        // Schedule retry after a short delay
        bindRetryTask?.cancel()
        bindRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            guard let self = self, self.allowReconnect else { return }
            self.beginConnection()
        }
    }

    // MARK: - Cleanup

    deinit {
        reconnectTask?.cancel()
        bindRetryTask?.cancel()
        connection?.cancel()
    }
}
