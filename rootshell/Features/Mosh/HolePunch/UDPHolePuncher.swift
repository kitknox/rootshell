//
//  UDPHolePuncher.swift
//  rootshell
//
//  UDP hole-punch orchestrator for traversing restrictive firewalls
//

import Foundation
import Network
import OSLog
import Citadel

/// Orchestrates UDP hole-punching to enable Mosh connections through restrictive firewalls
///
/// Stateful firewalls track UDP "connections" by 5-tuple (protocol, src_ip, src_port, dst_ip, dst_port).
/// When the server sends a UDP packet OUT to the client's public IP:port from mosh-server's port:
/// 1. Conntrack creates an entry allowing return packets
/// 2. Client's subsequent UDP packets to mosh-server are permitted as "return" traffic
///
/// This is the standard UDP hole-punching technique used in VoIP, WebRTC, and game networking.
///
/// Usage:
/// ```swift
/// let puncher = UDPHolePuncher(config: holePunchConfig, sshConfig: sshConfig, moshServerPort: 60001)
/// let localPort = try await puncher.punch()
/// // Use localPort when creating MoshTransport
/// ```
@MainActor
final class UDPHolePuncher {

    // MARK: - Types

    /// Delegate for hole-punch events
    protocol Delegate: AnyObject {
        @MainActor func holePuncher(_ puncher: UDPHolePuncher, didChangeState state: HolePunchState)
        /// Called before periodic refresh to check if refresh is needed.
        /// Return false to skip the refresh (e.g., when connection is healthy).
        @MainActor func holePuncherShouldRefresh(_ puncher: UDPHolePuncher) -> Bool
    }

    // MARK: - Properties

    /// Hole-punch configuration
    let config: HolePunchConfig

    /// SSH configuration for executing server-side commands
    let sshConfig: SSHConfig

    /// The mosh-server UDP port to punch hole for
    let moshServerPort: Int

    /// Override address family (if set, skip auto-detection)
    /// This should be set when the caller has already resolved the address
    /// to ensure STUN uses the same family as the transport.
    private let overrideAddressFamily: AddressFamily?

    /// Current state
    private(set) var state: HolePunchState = .idle {
        didSet {
            delegate?.holePuncher(self, didChangeState: state)
        }
    }

    /// Delegate for state change notifications
    weak var delegate: Delegate?

    /// Host-key validation prompt for the punch SSH connection. nil = strict
    /// (accept known/CA-signed keys, reject new or changed). Normally silent —
    /// the mosh-server spawner has already validated and saved this host's key.
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// STUN client for NAT discovery
    private let stunClient = STUNClient()

    /// Discovered NAT mapping
    private var discoveryResult: STUNClient.DiscoveryResult?

    /// Refresh timer task
    private var refreshTask: Task<Void, Never>?

    /// Whether the puncher has been stopped
    private var isStopped = false

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "UDPHolePuncher"
    )

    // MARK: - Initialization

    /// Creates a hole-puncher
    /// - Parameters:
    ///   - config: Hole-punch configuration
    ///   - sshConfig: SSH configuration for server commands
    ///   - moshServerPort: The mosh-server's UDP port
    ///   - addressFamily: Override address family (if set, skip auto-detection).
    ///     Pass this when the caller has already resolved the target address
    ///     to ensure STUN discovery uses the same family as the transport.
    init(config: HolePunchConfig, sshConfig: SSHConfig, moshServerPort: Int, addressFamily: AddressFamily? = nil) {
        self.config = config
        self.sshConfig = sshConfig
        self.moshServerPort = moshServerPort
        self.overrideAddressFamily = addressFamily
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public API

    /// Performs UDP hole-punch
    ///
    /// For IPv6: No NAT traversal needed - just discover local address and have server punch to it
    /// For IPv4: Try UPnP/NAT-PMP first, fall back to STUN-based approach
    ///
    /// - Returns: Tuple of (local port to bind, public IP for server to punch to, public port)
    /// - Throws: Error if hole-punch setup fails
    func punch() async throws -> HolePunchResult {
        guard !isStopped else {
            throw HolePunchError.cancelled
        }

        let addressFamily = resolveAddressFamily()
        Self.logger.info("Starting hole-punch: addressFamily=\(addressFamily.rawValue)")

        // For IPv6: Much simpler - no NAT to traverse
        if addressFamily == .ipv6 {
            return try await punchIPv6()
        }

        // For IPv4: Try UPnP/NAT-PMP first, then fall back to STUN
        return try await punchIPv4()
    }

    /// Result of hole-punch setup
    struct HolePunchResult: Sendable {
        /// Local port to bind (0 = any)
        let localPort: UInt16
        /// Public IP address for server to punch to
        let publicIP: String
        /// Public port for server to punch to
        let publicPort: UInt16
        /// Whether this is a reliable mapping (IPv6 or UPnP) vs best-effort (STUN on symmetric NAT)
        let isReliable: Bool
        /// Address family
        let addressFamily: AddressFamily
    }

    /// IPv6 hole-punch - use STUN to discover local address/port
    /// Even though IPv6 typically has no NAT, we use STUN because:
    /// 1. STUN server is a different host than mosh-server
    /// 2. This avoids port conflict when transport later binds to the same local port
    /// 3. STUN returns our global IPv6 address which the server needs for the punch
    private func punchIPv6() async throws -> HolePunchResult {
        state = .discoveringNAT
        Self.logger.info("IPv6 mode: Using STUN for address/port discovery")

        let localPort: UInt16 = config.preferredLocalPort > 0 ? config.preferredLocalPort : UInt16.random(in: 49152...65535)

        // Use STUN to discover our IPv6 address and bind a local port
        // This works because STUN servers are different hosts than mosh-server,
        // so there's no port conflict when the transport later binds
        let discovery = try await stunClient.discover(
            localPort: localPort,
            addressFamily: .ipv6,
            servers: config.stunServers(for: .ipv6).isEmpty ? nil : config.stunServers(for: .ipv6),
            timeout: config.stunTimeoutSeconds
        )

        self.discoveryResult = discovery
        state = .natDiscovered(
            publicIP: discovery.publicIP,
            publicPort: discovery.publicPort,
            localPort: discovery.localPort
        )

        Self.logger.info("IPv6 STUN discovered: public=\(discovery.publicIP):\(discovery.publicPort), local=\(discovery.localPort)")

        startRefreshTimer()

        return HolePunchResult(
            localPort: discovery.localPort,
            publicIP: discovery.publicIP,
            publicPort: discovery.publicPort,
            isReliable: true,  // IPv6 typically has no NAT, so mapping is reliable
            addressFamily: .ipv6
        )
    }

    /// IPv4 hole-punch - try UPnP/NAT-PMP, fall back to STUN
    private func punchIPv4() async throws -> HolePunchResult {
        state = .discoveringNAT

        let localPort: UInt16 = config.preferredLocalPort > 0 ? config.preferredLocalPort : UInt16.random(in: 49152...65535)

        // Try UPnP/NAT-PMP first for reliable port mapping
        if let upnpResult = await tryUPnPMapping(localPort: localPort) {
            Self.logger.info("UPnP/NAT-PMP succeeded: \(upnpResult.externalIP):\(upnpResult.externalPort)")

            state = .natDiscovered(publicIP: upnpResult.externalIP, publicPort: upnpResult.externalPort, localPort: localPort)

            self.discoveryResult = STUNClient.DiscoveryResult(
                publicIP: upnpResult.externalIP,
                publicPort: upnpResult.externalPort,
                localPort: localPort,
                isSymmetricNAT: false,
                addressFamily: .ipv4
            )

            startRefreshTimer()

            return HolePunchResult(
                localPort: localPort,
                publicIP: upnpResult.externalIP,
                publicPort: upnpResult.externalPort,
                isReliable: true,
                addressFamily: .ipv4
            )
        }

        Self.logger.warning("UPnP/NAT-PMP not available, falling back to STUN (may not work with symmetric NAT)")

        // Fall back to STUN - may not work with symmetric NAT
        let discovery = try await stunClient.discover(
            localPort: localPort,
            addressFamily: .ipv4,
            servers: config.stunServers(for: .ipv4).isEmpty ? nil : config.stunServers(for: .ipv4),
            timeout: config.stunTimeoutSeconds
        )

        self.discoveryResult = discovery
        state = .natDiscovered(
            publicIP: discovery.publicIP,
            publicPort: discovery.publicPort,
            localPort: discovery.localPort
        )

        Self.logger.info("STUN discovered: public=\(discovery.publicIP):\(discovery.publicPort), local=\(discovery.localPort)")

        if discovery.isSymmetricNAT {
            Self.logger.warning("Symmetric NAT detected without UPnP - hole-punch will likely fail")
        }

        startRefreshTimer()

        return HolePunchResult(
            localPort: discovery.localPort,
            publicIP: discovery.publicIP,
            publicPort: discovery.publicPort,
            isReliable: !discovery.isSymmetricNAT,
            addressFamily: .ipv4
        )
    }


    /// UPnP/NAT-PMP mapping result
    private struct UPnPResult {
        let externalIP: String
        let externalPort: UInt16
    }

    /// Attempts to create a UPnP or NAT-PMP port mapping
    private func tryUPnPMapping(localPort: UInt16) async -> UPnPResult? {
        // TODO: Implement UPnP/NAT-PMP discovery and mapping
        // This requires:
        // 1. SSDP discovery to find IGD (Internet Gateway Device)
        // 2. UPnP SOAP request to add port mapping
        // Or:
        // 1. NAT-PMP/PCP request to gateway
        //
        // For now, return nil to fall back to STUN
        // This can be implemented using a library or manual SSDP/SOAP
        Self.logger.info("UPnP/NAT-PMP not yet implemented, skipping")
        return nil
    }

    /// Executes server-side hole-punch to a known client address
    /// Call this after MoshTransport.connect() to have server send punch packet
    func executeServerPunch(clientIP: String, clientPort: UInt16) async throws {
        guard !isStopped else { return }

        state = .punchingHole(attempt: 1)

        let addressFamily: AddressFamily = clientIP.contains(":") ? .ipv6 : .ipv4
        Self.logger.info("Executing server punch to \(clientIP):\(clientPort) (family: \(addressFamily.rawValue))")

        do {
            try await executePunchCommand(
                clientIP: clientIP,
                clientPort: clientPort,
                addressFamily: addressFamily,
                useServerDiscovery: false  // We know the address, no discovery needed
            )

            let expiresAt = Date().addingTimeInterval(TimeInterval(config.refreshIntervalSeconds))
            state = .established(expiresAt: expiresAt)

            Self.logger.info("Server punch completed to \(clientIP):\(clientPort)")
        } catch {
            Self.logger.error("Server punch failed: \(error.localizedDescription)")
            state = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    /// Refreshes the hole-punch (call periodically to keep hole alive)
    /// Uses the existing STUN-discovered address - for network changes use refreshWithNewSTUN()
    func refresh() async throws {
        guard !isStopped else { return }
        guard let discovery = discoveryResult else {
            Self.logger.warning("Cannot refresh: no discovery result")
            return
        }

        state = .refreshing

        Self.logger.info("Refreshing hole-punch")

        do {
            try await executePunchCommand(
                clientIP: discovery.publicIP,
                clientPort: discovery.publicPort,
                addressFamily: discovery.addressFamily
            )

            let expiresAt = Date().addingTimeInterval(TimeInterval(config.refreshIntervalSeconds))
            state = .established(expiresAt: expiresAt)

            Self.logger.info("Hole-punch refreshed successfully")
        } catch {
            Self.logger.error("Hole-punch refresh failed: \(error.localizedDescription)")
            // Don't change state to failed - the existing hole may still work
            // Just log the error and try again later
        }
    }

    /// Refreshes the hole-punch with fresh STUN discovery
    /// Call this on network change (WiFi→Cellular, connectivity restored) since the
    /// client's public IP and/or NAT port mapping may have changed.
    /// - Returns: The new STUN result, or nil if discovery failed
    @discardableResult
    func refreshWithNewSTUN() async throws -> HolePunchResult? {
        guard !isStopped else { return nil }

        let addressFamily = resolveAddressFamily()
        Self.logger.info("Refreshing hole-punch with fresh STUN discovery (family: \(addressFamily.rawValue))")

        state = .refreshing

        do {
            // Re-do STUN discovery to get new public IP:port
            // This is necessary because after network change:
            // - Our public IP may have changed (different carrier/WiFi network)
            // - Our NAT port mapping has definitely changed
            let localPort: UInt16 = discoveryResult?.localPort ?? (config.preferredLocalPort > 0 ? config.preferredLocalPort : UInt16.random(in: 49152...65535))

            let servers = addressFamily == .ipv6 ? config.stunServers(for: .ipv6) : config.stunServers(for: .ipv4)
            let discovery = try await stunClient.discover(
                localPort: localPort,
                addressFamily: addressFamily,
                servers: servers.isEmpty ? nil : servers,
                timeout: config.stunTimeoutSeconds
            )

            // Check if our public address actually changed
            let addressChanged = discoveryResult?.publicIP != discovery.publicIP ||
                                 discoveryResult?.publicPort != discovery.publicPort

            if addressChanged {
                Self.logger.info("Public address changed: \(self.discoveryResult?.publicIP ?? "nil"):\(self.discoveryResult?.publicPort ?? 0) → \(discovery.publicIP):\(discovery.publicPort)")
            } else {
                Self.logger.info("Public address unchanged: \(discovery.publicIP):\(discovery.publicPort)")
            }

            // Update stored discovery result
            self.discoveryResult = discovery

            // Execute server punch with NEW address
            try await executePunchCommand(
                clientIP: discovery.publicIP,
                clientPort: discovery.publicPort,
                addressFamily: discovery.addressFamily
            )

            let expiresAt = Date().addingTimeInterval(TimeInterval(config.refreshIntervalSeconds))
            state = .established(expiresAt: expiresAt)

            Self.logger.info("Hole-punch refreshed with new STUN result")

            return HolePunchResult(
                localPort: discovery.localPort,
                publicIP: discovery.publicIP,
                publicPort: discovery.publicPort,
                isReliable: addressFamily == .ipv6 || !discovery.isSymmetricNAT,
                addressFamily: addressFamily
            )

        } catch {
            Self.logger.error("STUN refresh failed: \(error.localizedDescription)")
            // Fall back to regular refresh with existing address if STUN fails
            // The old address might still work if we just had a brief disconnection
            if discoveryResult != nil {
                Self.logger.info("Falling back to refresh with existing address")
                try? await refresh()
            }
            return nil
        }
    }

    /// Stops the hole-puncher and cancels refresh timer
    func stop() {
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        state = .idle
    }

    // MARK: - Private Methods

    /// Creates a pre-punch UDP connection from client to server and sends initial packet
    /// The connection is returned and stays alive to keep the NAT mapping warm
    /// Caller is responsible for cancelling the connection when done
    private func createPrePunchConnection(localPort: UInt16) async -> NWConnection? {
        let host = sshConfig.cachedIP ?? sshConfig.host
        let port = moshServerPort

        Self.logger.info("Creating pre-punch connection to \(host):\(port) from local port \(localPort)")

        // Create UDP connection to server
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        // Force same address family and bind to same local port
        let addressFamily = resolveAddressFamily()
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            switch addressFamily {
            case .ipv4, .auto:
                ipOptions.version = .v4
            case .ipv6:
                ipOptions.version = .v6
            }
        }

        let localHost: NWEndpoint.Host = switch addressFamily {
        case .ipv4, .auto: .ipv4(.any)
        case .ipv6: .ipv6(.any)
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: localHost,
            port: NWEndpoint.Port(rawValue: localPort)!
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        let networkQueue = DispatchQueue(label: "com.rootshell.holepunch.prepunch", qos: .userInitiated)

        // Wait for connection to be ready and send initial packet
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Use a class-based wrapper for thread-safe resume tracking
            final class ResumeGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func tryResume(_ block: () -> Void) -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return false }
                    resumed = true
                    block()
                    return true
                }
            }

            let guard_ = ResumeGuard()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send a minimal punch packet
                    let punchData = Data("P".utf8)
                    connection.send(content: punchData, completion: .contentProcessed { error in
                        if let error = error {
                            Self.logger.warning("Pre-punch send failed: \(error.localizedDescription)")
                        } else {
                            Self.logger.info("Pre-punch packet sent to \(host):\(port)")
                        }
                        // Don't cancel - keep connection alive
                        _ = guard_.tryResume {
                            continuation.resume(returning: error == nil)
                        }
                    })

                case .failed(let error):
                    Self.logger.warning("Pre-punch connection failed: \(error.localizedDescription)")
                    _ = guard_.tryResume {
                        continuation.resume(returning: false)
                    }

                case .cancelled:
                    _ = guard_.tryResume {
                        continuation.resume(returning: false)
                    }

                default:
                    break
                }
            }

            connection.start(queue: networkQueue)

            // Timeout for initial connection establishment
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                _ = guard_.tryResume {
                    Self.logger.warning("Pre-punch connection timeout")
                    continuation.resume(returning: false)
                }
            }
        }

        if success {
            Self.logger.info("Pre-punch connection established, keeping alive for NAT mapping")
            return connection
        } else {
            connection.cancel()
            return nil
        }
    }

    /// Resolves the address family to use based on configuration and target host
    /// Prefers IPv6 when available (no NAT traversal needed)
    private func resolveAddressFamily() -> AddressFamily {
        // If caller provided an override (e.g., from DualStackResolver), use it
        // This ensures STUN uses the same family as the transport will use
        if let override = overrideAddressFamily, override != .auto {
            Self.logger.info("Using address family override: \(override.rawValue)")
            return override
        }

        switch config.addressFamilyPreference {
        case .ipv4:
            return .ipv4
        case .ipv6:
            return .ipv6
        case .auto:
            // Check if we have an IPv6 address cached (from SSH connection)
            let host = sshConfig.cachedIP ?? sshConfig.host

            // If the cached/resolved address is IPv6, use it (preferred - no NAT)
            if host.contains(":") {
                Self.logger.info("Using IPv6 (detected from host address) - no NAT traversal needed")
                return .ipv6
            }

            // Check if hostname might resolve to IPv6
            // For now, default to IPv4 if we have an IPv4 address
            // TODO: Could do async DNS resolution to check for AAAA records
            Self.logger.info("Using IPv4 (no IPv6 address detected)")
            return .ipv4
        }
    }

    /// Executes the hole-punch with retries
    private func executePunch(attempt: Int) async throws {
        guard !isStopped else {
            throw HolePunchError.cancelled
        }

        guard let discovery = discoveryResult else {
            throw HolePunchError.noDiscoveryResult
        }

        state = .punchingHole(attempt: attempt)

        do {
            try await executePunchCommand(
                clientIP: discovery.publicIP,
                clientPort: discovery.publicPort,
                addressFamily: discovery.addressFamily
            )

            let expiresAt = Date().addingTimeInterval(TimeInterval(config.refreshIntervalSeconds))
            state = .established(expiresAt: expiresAt)

            Self.logger.info("Hole-punch established (attempt \(attempt))")

        } catch {
            Self.logger.warning("Hole-punch attempt \(attempt) failed: \(error.localizedDescription)")

            if attempt < config.maxRetries {
                // Exponential backoff
                let delayMs = 500 * (1 << (attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                try await executePunch(attempt: attempt + 1)
            } else {
                state = .failed(reason: error.localizedDescription)
                throw error
            }
        }
    }

    /// Executes the hole-punch command via SSH
    /// If useServerDiscovery is true, the server will discover the client's actual port
    /// by watching for incoming UDP packets (handles symmetric NAT)
    private func executePunchCommand(
        clientIP: String,
        clientPort: UInt16,
        addressFamily: AddressFamily,
        useServerDiscovery: Bool = false
    ) async throws {
        let command: String
        if useServerDiscovery {
            command = buildReactivePunchCommand(
                moshPort: moshServerPort,
                addressFamily: addressFamily,
                fallbackIP: clientIP,
                fallbackPort: clientPort
            )
        } else {
            command = buildPunchCommand(
                clientIP: clientIP,
                clientPort: clientPort,
                addressFamily: addressFamily
            )
        }

        Self.logger.info("Executing hole-punch command to \(clientIP):\(clientPort) (serverDiscovery=\(useServerDiscovery))")
        Self.logger.info("Command: \(command)")

        // Create SSH client for command execution
        let client = try await createSSHClient()
        defer {
            Task {
                try? await client.close()
            }
        }

        // `sshd` runs exec-channel commands as `$SHELL -c '<command>'` — the
        // remote user's login shell, not a fixed POSIX shell — so the
        // `if`/`command -v` script built above must be wrapped for `sh` or a
        // fish/csh login shell rejects it before any punch attempt runs.
        let streams = try await client.executeCommandStream(LoginShellCommand.runInPOSIXShell(command))

        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 0
        for try await event in streams {
            switch event {
            case .stdout(let buffer):
                if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                    stdout += str
                }
            case .stderr(let buffer):
                if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                    stderr += str
                }
            case .exitStatus(let status):
                exitCode = Int32(status)
            }
        }

        if exitCode != 0 {
            Self.logger.warning("Punch command failed with exit code \(exitCode)")
            if !stderr.isEmpty {
                Self.logger.warning("stderr: \(stderr)")
            }
            if !stdout.isEmpty {
                Self.logger.warning("stdout: \(stdout)")
            }
        } else {
            Self.logger.info("Punch command succeeded (exit 0)")
            if !stdout.isEmpty {
                Self.logger.debug("stdout: \(stdout)")
            }
        }
    }

    /// Builds the shell command to send UDP punch packet from server
    private func buildPunchCommand(
        clientIP: String,
        clientPort: UInt16,
        addressFamily: AddressFamily
    ) -> String {
        let port = clientPort
        let moshPort = moshServerPort

        // Based on configured method
        switch config.serverMethod {
        case .rawSocket:
            return buildRawSocketCommand(clientIP: clientIP, clientPort: port, addressFamily: addressFamily, moshPort: moshPort)

        case .socat:
            return buildSocatCommand(clientIP: clientIP, clientPort: port, addressFamily: addressFamily, moshPort: moshPort)

        case .netcat:
            return buildNetcatCommand(clientIP: clientIP, clientPort: port, addressFamily: addressFamily, moshPort: moshPort)

        case .bashUDP:
            if addressFamily == .ipv6 {
                // Bash /dev/udp doesn't support IPv6, fall back to auto
                return buildAutoDetectCommand(clientIP: clientIP, clientPort: port, addressFamily: addressFamily, moshPort: moshPort)
            }
            return buildBashUDPCommand(clientIP: clientIP, clientPort: port, moshPort: moshPort)

        case .auto:
            return buildAutoDetectCommand(clientIP: clientIP, clientPort: port, addressFamily: addressFamily, moshPort: moshPort)
        }
    }

    /// Builds raw socket command using hping3, nping, or scapy
    /// This sends a UDP packet with spoofed source port matching mosh-server's port
    /// Requires root/sudo but doesn't need SO_REUSEPORT patch on mosh-server
    private func buildRawSocketCommand(clientIP: String, clientPort: UInt16, addressFamily: AddressFamily, moshPort: Int) -> String {
        // For IPv6, need different flags
        let ipv6Flag = addressFamily == .ipv6

        return """
        # Raw socket punch - sends UDP with spoofed source port (requires sudo)
        # This avoids needing SO_REUSEPORT on mosh-server
        if command -v hping3 >/dev/null 2>&1; then
          sudo hping3 --udp \(ipv6Flag ? "-6 " : "")-s \(moshPort) -p \(clientPort) -c 1 -d 1 \(clientIP) 2>/dev/null
        elif command -v nping >/dev/null 2>&1; then
          sudo nping --udp \(ipv6Flag ? "-6 " : "")-g \(moshPort) -p \(clientPort) --data-string 'P' -c 1 \(clientIP) 2>/dev/null
        elif command -v python3 >/dev/null 2>&1 && python3 -c "import scapy" 2>/dev/null; then
          sudo python3 -c "from scapy.all import *; send(\(ipv6Flag ? "IPv6" : "IP")(dst='\(clientIP)')/UDP(sport=\(moshPort),dport=\(clientPort))/Raw(b'P'), verbose=0)"
        else
          echo 'No raw socket tool available (need hping3, nping, or python3-scapy)' >&2
          exit 1
        fi
        """
    }

    /// Builds socat command (fallback when raw sockets not available)
    /// Uses sourceport to bind to mosh-server port for correct conntrack entry.
    /// NOTE: This approach requires SO_REUSEPORT on mosh-server which causes multi-session issues.
    /// Prefer raw socket method when sudo is available.
    private func buildSocatCommand(clientIP: String, clientPort: UInt16, addressFamily: AddressFamily, moshPort: Int) -> String {
        let udpType = addressFamily == .ipv6 ? "UDP6" : "UDP"
        let ip = addressFamily == .ipv6 ? "[\(clientIP)]" : clientIP
        // Bind to mosh-server port to create correct conntrack entry
        // Use so-reuseport to coexist with mosh-server temporarily
        return """
        (echo -n 'P' | socat -T1 - \(udpType):\(ip):\(clientPort),sourceport=\(moshPort),so-reuseport 2>/dev/null) || \
        (echo -n 'P' | socat -T1 - \(udpType):\(ip):\(clientPort),sourceport=\(moshPort) 2>/dev/null) || \
        (echo -n 'P' | socat -T1 - \(udpType):\(ip):\(clientPort))
        """
    }

    /// Builds netcat command
    /// Tries -p for source port (some nc implementations support it for UDP)
    private func buildNetcatCommand(clientIP: String, clientPort: UInt16, addressFamily: AddressFamily, moshPort: Int) -> String {
        let ipFlag = addressFamily == .ipv6 ? "-6 " : ""
        // Try with -p for source port, fall back to without
        return "(echo -n 'P' | nc \(ipFlag)-u -w 1 -p \(moshPort) \(clientIP) \(clientPort) 2>/dev/null) || (echo -n 'P' | nc \(ipFlag)-u -w 1 \(clientIP) \(clientPort))"
    }

    /// Builds bash /dev/udp command (IPv4 only)
    private func buildBashUDPCommand(clientIP: String, clientPort: UInt16, moshPort: Int) -> String {
        // Bash /dev/udp doesn't support source port binding, but we try anyway
        // This creates a connection from an ephemeral port, which may not match mosh-server's port
        // However, some firewalls track by destination rather than full 5-tuple
        return "exec 3>/dev/udp/\(clientIP)/\(clientPort) && echo -n 'P' >&3 && exec 3>&-"
    }

    /// Builds auto-detect command that tries multiple methods
    /// Priority: raw sockets (hping3/nping/scapy) > socat with sourceport > fallbacks
    /// Raw sockets are preferred because they don't require SO_REUSEPORT on mosh-server
    private func buildAutoDetectCommand(clientIP: String, clientPort: UInt16, addressFamily: AddressFamily, moshPort: Int) -> String {
        let ipv6Flag = addressFamily == .ipv6
        let udpType = ipv6Flag ? "UDP6" : "UDP"
        let socatIP = ipv6Flag ? "[\(clientIP)]" : clientIP
        let hpingIPv6 = ipv6Flag ? "-6 " : ""
        let npingIPv6 = ipv6Flag ? "-6 " : ""
        let scapyIPClass = ipv6Flag ? "IPv6" : "IP"
        let ncIPv6 = ipv6Flag ? "-6 " : ""

        return """
        # Try raw socket methods first (preferred - no SO_REUSEPORT needed on mosh-server)
        if command -v hping3 >/dev/null 2>&1; then
          sudo hping3 --udp \(hpingIPv6)-s \(moshPort) -p \(clientPort) -c 1 -d 1 \(clientIP) 2>/dev/null && exit 0
        fi
        if command -v nping >/dev/null 2>&1; then
          sudo nping --udp \(npingIPv6)-g \(moshPort) -p \(clientPort) --data-string 'P' -c 1 \(clientIP) 2>/dev/null && exit 0
        fi
        if command -v python3 >/dev/null 2>&1 && python3 -c "from scapy.all import *" 2>/dev/null; then
          sudo python3 -c "from scapy.all import *; send(\(scapyIPClass)(dst='\(clientIP)')/UDP(sport=\(moshPort),dport=\(clientPort))/Raw(b'P'), verbose=0)" 2>/dev/null && exit 0
        fi
        # Fallback to socat with sourceport (requires SO_REUSEPORT on mosh-server for multi-session)
        if command -v socat >/dev/null 2>&1; then
          (echo -n 'P' | socat -T1 - \(udpType):\(socatIP):\(clientPort),sourceport=\(moshPort),so-reuseport 2>/dev/null) || \
          (echo -n 'P' | socat -T1 - \(udpType):\(socatIP):\(clientPort),sourceport=\(moshPort) 2>/dev/null) || \
          (echo -n 'P' | socat -T1 - \(udpType):\(socatIP):\(clientPort))
          exit 0
        fi
        # Last resort fallbacks (wrong source port - may not work with strict firewalls)
        if command -v nc >/dev/null 2>&1; then
          echo -n 'P' | nc \(ncIPv6)-u -w 1 \(clientIP) \(clientPort) && exit 0
        fi
        \(ipv6Flag ? "" : """
        if [ -e /dev/udp/127.0.0.1/1 ] 2>/dev/null || true; then
          exec 3>/dev/udp/\(clientIP)/\(clientPort) && echo -n 'P' >&3 && exec 3>&- && exit 0
        fi
        """)
        echo 'No UDP hole-punch method available' >&2
        exit 1
        """
    }

    /// Builds a server-side discovery command that listens for client packet and echoes back the source
    /// This is more reliable than STUN for symmetric NAT because it discovers the actual mapping
    /// for the mosh server destination
    func buildDiscoveryListenerCommand(moshPort: Int, timeout: Int = 3) -> String {
        return """
        # Listen on mosh port for discovery packet and return the client's actual source IP:port
        # Uses timeout to avoid hanging indefinitely
        if command -v socat >/dev/null 2>&1; then
          timeout \(timeout) socat -u UDP-LISTEN:\(moshPort),reuseaddr,fork SYSTEM:'echo $SOCAT_PEERADDR:$SOCAT_PEERPORT; kill $PPID' 2>/dev/null | head -1
        elif command -v nc >/dev/null 2>&1; then
          # netcat doesn't easily give us peer info, fall back to tcpdump if available
          if command -v tcpdump >/dev/null 2>&1; then
            timeout \(timeout) tcpdump -i any -c 1 -nn "udp dst port \(moshPort)" 2>/dev/null | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+\\.\\d+(?= >)' | sed 's/\\.\\([0-9]*\\)$/:\\1/'
          fi
        fi
        """
    }

    /// Builds a reactive punch command that watches for incoming UDP and punches back
    /// This handles symmetric NAT by discovering the actual client port from tcpdump
    /// Prefers raw sockets for the punch-back to avoid SO_REUSEPORT issues
    private func buildReactivePunchCommand(moshPort: Int, addressFamily: AddressFamily, fallbackIP: String, fallbackPort: UInt16) -> String {
        let udpType = addressFamily == .ipv6 ? "UDP6" : "UDP"
        let ipFlag = addressFamily == .ipv6 ? "-6 " : ""
        let hpingIPv6 = addressFamily == .ipv6 ? "-6 " : ""
        let npingIPv6 = addressFamily == .ipv6 ? "-6 " : ""
        let scapyIPClass = addressFamily == .ipv6 ? "IPv6" : "IP"

        return """
        # Reactive punch: watch for first UDP packet to mosh port and punch back to actual source
        # This handles symmetric NAT where STUN-discovered port differs from actual
        PEER_INFO=""

        # Try tcpdump first (most reliable)
        if command -v tcpdump >/dev/null 2>&1; then
          # Capture first UDP packet to mosh port, extract source IP:port
          PEER_INFO=$(timeout 5 tcpdump -i any -c 1 -nn "udp dst port \(moshPort)" 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+(?= >)' | head -1 | sed 's/\\.\\([0-9]*\\)$/:\\1/')
        fi

        # If tcpdump didn't work, try ss/netstat
        if [ -z "$PEER_INFO" ]; then
          if command -v ss >/dev/null 2>&1; then
            sleep 2  # Wait for client packets
            PEER_INFO=$(ss -u -n state established "( sport = :\(moshPort) )" 2>/dev/null | tail -1 | awk '{print $6}' | grep -v '^$')
          fi
        fi

        # Fallback to STUN-discovered address
        if [ -z "$PEER_INFO" ]; then
          echo "Using fallback address \(fallbackIP):\(fallbackPort)" >&2
          PEER_IP="\(fallbackIP)"
          PEER_PORT="\(fallbackPort)"
        else
          echo "Discovered actual client: $PEER_INFO" >&2
          PEER_IP=$(echo "$PEER_INFO" | cut -d: -f1)
          PEER_PORT=$(echo "$PEER_INFO" | cut -d: -f2)
        fi

        # Send punch packet back - prefer raw sockets (no SO_REUSEPORT needed)
        if command -v hping3 >/dev/null 2>&1; then
          sudo hping3 --udp \(hpingIPv6)-s \(moshPort) -p $PEER_PORT -c 1 -d 1 $PEER_IP 2>/dev/null
        elif command -v nping >/dev/null 2>&1; then
          sudo nping --udp \(npingIPv6)-g \(moshPort) -p $PEER_PORT --data-string 'P' -c 1 $PEER_IP 2>/dev/null
        elif command -v python3 >/dev/null 2>&1 && python3 -c "from scapy.all import *" 2>/dev/null; then
          sudo python3 -c "from scapy.all import *; send(\(scapyIPClass)(dst='$PEER_IP')/UDP(sport=\(moshPort),dport=int('$PEER_PORT'))/Raw(b'P'), verbose=0)" 2>/dev/null
        # Fallback to socat with sourceport (requires SO_REUSEPORT on mosh-server)
        elif command -v socat >/dev/null 2>&1; then
          (echo -n 'P' | socat -T1 - \(udpType):$PEER_IP:$PEER_PORT,sourceport=\(moshPort),so-reuseport 2>/dev/null) || \
          (echo -n 'P' | socat -T1 - \(udpType):$PEER_IP:$PEER_PORT,sourceport=\(moshPort) 2>/dev/null) || \
          (echo -n 'P' | socat -T1 - \(udpType):$PEER_IP:$PEER_PORT)
        elif command -v nc >/dev/null 2>&1; then
          (echo -n 'P' | nc \(ipFlag)-u -w 1 -p \(moshPort) $PEER_IP $PEER_PORT 2>/dev/null) || \
          (echo -n 'P' | nc \(ipFlag)-u -w 1 $PEER_IP $PEER_PORT)
        elif [ -e /dev/udp/127.0.0.1/1 ] 2>/dev/null || true; then
          exec 3>/dev/udp/$PEER_IP/$PEER_PORT && echo -n 'P' >&3 && exec 3>&-
        else
          echo 'No UDP method available' >&2 && exit 1
        fi
        echo "Punched to $PEER_IP:$PEER_PORT from port \(moshPort)"
        """
    }

    /// Builds a combined command that discovers client's actual port and punches back
    /// NOTE: This command is problematic because listening on moshPort interferes with mosh-server
    /// Consider using buildReactivePunchCommand with tcpdump instead
    func buildDiscoverAndPunchCommand(moshPort: Int, addressFamily: AddressFamily) -> String {
        let udpType = addressFamily == .ipv6 ? "UDP6" : "UDP"
        let hpingIPv6 = addressFamily == .ipv6 ? "-6 " : ""
        let npingIPv6 = addressFamily == .ipv6 ? "-6 " : ""
        let scapyIPClass = addressFamily == .ipv6 ? "IPv6" : "IP"

        return """
        # Wait for client discovery packet and punch back to actual source
        # WARNING: This listens on mosh port which may interfere with mosh-server
        # This handles symmetric NAT where STUN-discovered port differs from actual
        PEER_INFO=$(timeout 3 socat -u \(udpType)-LISTEN:\(moshPort),reuseaddr SYSTEM:'echo $SOCAT_PEERADDR:$SOCAT_PEERPORT' 2>/dev/null | head -1)
        if [ -n "$PEER_INFO" ]; then
          PEER_IP=$(echo "$PEER_INFO" | cut -d: -f1)
          PEER_PORT=$(echo "$PEER_INFO" | cut -d: -f2)
          echo "Discovered client: $PEER_IP:$PEER_PORT" >&2
          # Send punch packet back - prefer raw sockets (no SO_REUSEPORT needed)
          if command -v hping3 >/dev/null 2>&1; then
            sudo hping3 --udp \(hpingIPv6)-s \(moshPort) -p $PEER_PORT -c 1 -d 1 $PEER_IP 2>/dev/null
          elif command -v nping >/dev/null 2>&1; then
            sudo nping --udp \(npingIPv6)-g \(moshPort) -p $PEER_PORT --data-string 'P' -c 1 $PEER_IP 2>/dev/null
          elif command -v python3 >/dev/null 2>&1 && python3 -c "from scapy.all import *" 2>/dev/null; then
            sudo python3 -c "from scapy.all import *; send(\(scapyIPClass)(dst='$PEER_IP')/UDP(sport=\(moshPort),dport=int('$PEER_PORT'))/Raw(b'P'), verbose=0)" 2>/dev/null
          # Fallback to socat (requires SO_REUSEPORT on mosh-server)
          elif command -v socat >/dev/null 2>&1; then
            (echo -n 'P' | socat -T1 - \(udpType):$PEER_IP:$PEER_PORT,sourceport=\(moshPort),so-reuseport 2>/dev/null) || \
            (echo -n 'P' | socat -T1 - \(udpType):$PEER_IP:$PEER_PORT)
          elif command -v nc >/dev/null 2>&1; then
            (echo -n 'P' | nc -u -w 1 -p \(moshPort) $PEER_IP $PEER_PORT 2>/dev/null) || \
            (echo -n 'P' | nc -u -w 1 $PEER_IP $PEER_PORT)
          fi
          echo "$PEER_IP:$PEER_PORT"
        else
          echo "No client packet received" >&2
          exit 1
        fi
        """
    }

    /// Creates an SSH client for command execution
    private func createSSHClient() async throws -> SSHClient {
        let host = sshConfig.cachedIP ?? sshConfig.host
        let port = sshConfig.port

        // Build authentication method
        let authMethod = try await buildAuthMethod(for: sshConfig)

        // Handle jump host if configured
        if let jumpHost = sshConfig.jumpHost {
            let jumpAuth = try await buildAuthMethod(for: jumpHost)

            // Pre-resolve jump host CGNAT IPv4 so NWConnection sees an IP
            // literal, then route through MPTCPBootstrap so the connect goes
            // via Network.framework (POSIX races Tailscale's DERP setup for
            // NAT'd targets outside the home network).
            let jumpConnectHost: String
            if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpHost.host) {
                jumpConnectHost = cgnatIP
            } else {
                jumpConnectHost = jumpHost.host
            }

            let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: jumpConnectHost,
                port: jumpHost.port
            )
            var jumpSettings = SSHClientSettings(
                host: jumpConnectHost,
                port: jumpHost.port,
                authenticationMethod: { jumpAuth },
                hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                    for: jumpHost.host,
                    port: jumpHost.port,
                    label: "[Jump Host]",
                    onValidation: onHostKeyValidation
                )
            )
            jumpSettings.algorithms = .all
            jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpHost.host)
            let jumpClient: SSHClient
            do {
                jumpClient = try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
            } catch {
                try? await jumpChannel.close()
                throw error
            }

            var targetSettings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: { authMethod },
                // Keyed by the configured hostname, not the cachedIP dial host.
                hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                    for: sshConfig.host,
                    port: port,
                    label: "[Target]",
                    onValidation: onHostKeyValidation
                )
            )
            targetSettings.algorithms = .all
            targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: sshConfig.host)
            return try await jumpClient.jump(to: targetSettings)
        }

        // Direct connection
        let directChannel = try await MPTCPBootstrap.connectPlainChannel(
            host: host,
            port: port
        )
        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authMethod },
            // Keyed by the configured hostname, not the cachedIP dial host.
            hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                for: sshConfig.host,
                port: port,
                onValidation: onHostKeyValidation
            )
        )
        settings.algorithms = .all
        settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
        settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: sshConfig.host)
        do {
            return try await SSHClient.connect(on: directChannel, settings: settings)
        } catch {
            try? await directChannel.close()
            throw error
        }
    }

    /// Builds authentication method for SSH config
    private func buildAuthMethod(for config: SSHConfig) async throws -> SSHAuthenticationMethod {
        switch config.authMethod {
        case .password(let password):
            return .passwordBased(username: config.username, password: password)

        case .savedPassword:
            let connectionKey = "\(config.host):\(config.port):\(config.username)"
            if let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) {
                return .passwordBased(username: config.username, password: password)
            }
            throw HolePunchError.authenticationFailed("Saved password not found")

        case .key(let keyID):
            let keyVariant = try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
            return try buildKeyAuthMethod(username: config.username, keyID: keyID, keyVariant: keyVariant)

        case .none:
            return .custom(HolePunchNoneAuthDelegate(username: config.username))

        case .keyboardInteractive:
            throw HolePunchError.authenticationFailed("Keyboard-interactive authentication is not supported for Mosh hole punching")

        case .unknown:
            throw HolePunchError.authenticationFailed("Unsupported authentication method")
        }
    }

    /// Builds authentication method for jump host config
    private func buildAuthMethod(for jumpHost: SSHConfig.JumpHostConfig) async throws -> SSHAuthenticationMethod {
        switch jumpHost.authMethod {
        case .password(let password):
            return .passwordBased(username: jumpHost.username, password: password)

        case .savedPassword:
            let connectionKey = "\(jumpHost.host):\(jumpHost.port):\(jumpHost.username)"
            if let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) {
                return .passwordBased(username: jumpHost.username, password: password)
            }
            throw HolePunchError.authenticationFailed("Jump host saved password not found")

        case .key(let keyID):
            let keyVariant = try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
            return try buildKeyAuthMethod(username: jumpHost.username, keyID: keyID, keyVariant: keyVariant)

        case .none:
            return .custom(HolePunchNoneAuthDelegate(username: jumpHost.username))

        case .keyboardInteractive:
            throw HolePunchError.authenticationFailed("Keyboard-interactive authentication is not supported for Mosh hole punching")

        case .unknown:
            throw HolePunchError.authenticationFailed("Unsupported authentication method")
        }
    }

    /// Builds key-based authentication method.
    /// When the key has a usable user certificate, it is offered before the plain
    /// key (same cert-then-plain fallback as the main SSH path) so cert-only
    /// servers work over Mosh too.
    private func buildKeyAuthMethod(username: String, keyID: UUID, keyVariant: SSHPrivateKeyVariant) throws -> SSHAuthenticationMethod {
        let certifiedKey = SSHKeyManager.shared.usableCertifiedKey(forKeyID: keyID, username: username)

        if certifiedKey == nil, case .rsa(let rsaKey) = keyVariant {
            return .rsa(username: username, privateKey: rsaKey)
        }

        let candidate = SSHAuthKeyCandidate(variant: keyVariant, certifiedKey: certifiedKey)
        return .custom(NIOKeyAuthDelegate(
            username: username,
            privateKey: candidate.nioPrivateKey,
            legacyRSAKey: candidate.legacyRSAAuthenticationKey,
            certifiedKey: certifiedKey
        ))
    }

    /// Starts the refresh timer
    private func startRefreshTimer() {
        refreshTask?.cancel()

        let interval = TimeInterval(config.refreshIntervalSeconds)
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Wait for refresh interval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

                guard let self = self, !self.isStopped else { break }

                // Ask delegate if refresh is needed (e.g., skip when connection is healthy)
                guard self.delegate?.holePuncherShouldRefresh(self) ?? true else {
                    Self.logger.debug("Periodic refresh skipped - delegate returned false")
                    continue
                }

                // Refresh the hole-punch
                try? await self.refresh()
            }
        }
    }
}

// MARK: - Hole-Punch Errors

enum HolePunchError: LocalizedError, Sendable {
    case cancelled
    case noDiscoveryResult
    case authenticationFailed(String)
    case commandFailed(String)
    case networkChanged
    case ipv6DiscoveryFailed(String)
    case upnpFailed(String)
    case symmetricNATDetected

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Hole-punch cancelled"
        case .noDiscoveryResult:
            return "No NAT discovery result available"
        case .authenticationFailed(let reason):
            return "SSH authentication failed: \(reason)"
        case .commandFailed(let reason):
            return "Hole-punch command failed: \(reason)"
        case .networkChanged:
            return "Network changed during hole-punch"
        case .ipv6DiscoveryFailed(let reason):
            return "IPv6 address discovery failed: \(reason)"
        case .upnpFailed(let reason):
            return "UPnP/NAT-PMP port mapping failed: \(reason)"
        case .symmetricNATDetected:
            return "Symmetric NAT detected - UDP hole-punch not possible without UPnP or IPv6"
        }
    }
}

// MARK: - Auth Delegates

import NIOCore
import NIOSSH

/// Auth delegate for "none" authentication (hole-punch specific)
private final class HolePunchNoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var tried = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !tried else {
            nextChallengePromise.succeed(nil)
            return
        }
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .none
        ))
    }
}
