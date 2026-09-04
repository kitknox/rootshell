//
//  SSHVPNTunnelProvider.swift
//  VPNTunnelExtension
//
//  NEPacketTunnelProvider subclass implementing the VPN tunnel.
//  Reads IP packets from the OS, feeds them to Go gVisor netstack,
//  and writes outbound packets back to the OS.
//

import Foundation
import Network
import NetworkExtension
import NIOCore
import NIOPosix
import NIOSSH
import os.log
import Darwin
import WidgetKit
@preconcurrency import Citadel
@preconcurrency import VPNTunnel

class SSHVPNTunnelProvider: NEPacketTunnelProvider {
    nonisolated static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "TunnelProvider")
    nonisolated static let extensionMemoryBudgetBytes: UInt64 = 50 * 1024 * 1024
    nonisolated static let widgetKind = "VPNControlWidget"

    // SSH transport state (SSH profiles only)
    // Protected by sshStateLock for thread-safe access from both MainActor
    // (startup/cleanup) and nonisolated (reconnection) contexts.
    private let sshStateLock = NSLock()
    private nonisolated(unsafe) var sshClient: SSHClient?
    private nonisolated(unsafe) var jumpClient: SSHClient?
    private nonisolated(unsafe) var socksProxy: VPNSOCKS5Proxy?
    private nonisolated(unsafe) var sshEventLoopGroup: MultiThreadedEventLoopGroup?
    private nonisolated(unsafe) var socksEventLoopGroup: MultiThreadedEventLoopGroup?

    // Traffic time-series recorder
    private nonisolated(unsafe) var trafficRecorder: VPNTrafficRecorder?

    // SSH health monitoring & reconnection state
    private nonisolated(unsafe) var healthMonitor: VPNSSHHealthMonitor?
    private nonisolated(unsafe) var sshProxyPort: Int = 0
    private nonisolated(unsafe) var storedConfig: VPNTunnelConfig?
    private let reconnectLock = NSLock()
    private nonisolated(unsafe) var isReconnecting = false
    private nonisolated(unsafe) var reconnectAttempts = 0
    private nonisolated static let maxReconnectAttempts = 5

    // Thread-safe state accessed from both MainActor (write loop) and
    // nonisolated methods (stopTunnel, handleAppMessage, Go callbacks).
    // Manual lock-based synchronization — nonisolated(unsafe) tells the
    // compiler we handle thread safety ourselves.
    private let runningStateLock = NSLock()
    private nonisolated(unsafe) var runningState = false
    /// True between `stopTunnel` being called and the next `startTunnelInner`
    /// resetting state. Distinct from `runningState` because `runningState`
    /// is also `false` during normal bootstrap, so it can't tell the two
    /// states apart. Bootstrap retries check this AFTER each await so that
    /// a connect which completes cooperatively *after* `Task.cancel()`
    /// (`Task.cancel()` is cooperative — a connect already in its final
    /// stage may still return a result) is detected and the freshly-built
    /// SSH client is torn down instead of getting wired into a stopped
    /// tunnel's SOCKS / Go path.
    private nonisolated(unsafe) var stopRequested = false
    /// Monotonically increasing generation counter. Incremented on each startTunnel
    /// so that reconnection tasks from a previous session detect staleness and exit
    /// rather than tearing down a newly started tunnel.
    private nonisolated(unsafe) var tunnelGeneration: UInt64 = 0
    private nonisolated(unsafe) var tunnelStartDate: Date?
    private nonisolated(unsafe) var tsshPort: Int = 0
    private nonisolated(unsafe) var tsshMode: String = ""
    private nonisolated(unsafe) var tsshMTU: Int = 0
    private nonisolated(unsafe) var tunMTU: Int = 0
    private let failureStateLock = NSLock()
    private nonisolated(unsafe) var hasHandledGoFailure = false

    // Bootstrap connection retry cancellation handle.
    //
    // Set when `startSSHTransport` / `startTSSHTransport` enters their
    // retry loop around the initial SSH connect; called by `stopTunnel`
    // to cancel mid-retry. The user can tap Disconnect at any point during
    // the ~5-minute retry budget without having to wait for the next
    // backoff to elapse.
    //
    // Type-erased to avoid coupling storage to the typed Task<T, Error>
    // result of each call site. The closure captures `task.cancel`.
    //
    // Accessed from MainActor startup paths and from `stopTunnel`
    // (nonisolated). The lock makes the read+cancel atomic so a fresh
    // assignment can't race a cancel.
    private let bootstrapTaskLock = NSLock()
    private nonisolated(unsafe) var bootstrapCancel: (@Sendable () -> Void)?

    private nonisolated func setBootstrapCancellable<T: Sendable>(_ task: Task<T, Error>) {
        bootstrapTaskLock.lock()
        bootstrapCancel = { task.cancel() }
        bootstrapTaskLock.unlock()
    }

    private nonisolated func clearBootstrapCancellable() {
        bootstrapTaskLock.lock()
        bootstrapCancel = nil
        bootstrapTaskLock.unlock()
    }

    private nonisolated func cancelBootstrapIfRunning() {
        bootstrapTaskLock.lock()
        let cancel = bootstrapCancel
        bootstrapCancel = nil
        bootstrapTaskLock.unlock()
        cancel?()
    }
    nonisolated private var isRunning: Bool {
        get {
            runningStateLock.lock()
            defer { runningStateLock.unlock() }
            return runningState
        }
        set {
            runningStateLock.lock()
            runningState = newValue
            runningStateLock.unlock()
        }
    }
    nonisolated private var currentGeneration: UInt64 {
        runningStateLock.lock()
        defer { runningStateLock.unlock() }
        return tunnelGeneration
    }
    nonisolated private var currentTunnelStartDate: Date? {
        runningStateLock.lock()
        defer { runningStateLock.unlock() }
        return tunnelStartDate
    }

    // MARK: - Error Forwarding

    private static let appGroupID = AppIdentifiers.defaultAppGroupID

    /// Write an error to the app group so the main app can display it.
    private static func writeErrorToAppGroup(_ error: any Error) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let fileURL = containerURL.appendingPathComponent("vpn_last_error.txt")
        let msg = error.localizedDescription
        try? msg.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    /// Read the last error written by the extension.
    static func readErrorFromAppGroup() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }

        let fileURL = containerURL.appendingPathComponent("vpn_last_error.txt")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Clean up after reading
        try? FileManager.default.removeItem(at: fileURL)
        return String(data: data, encoding: .utf8)
    }

    // MARK: - NEPacketTunnelProvider Lifecycle

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        Self.logger.info("Starting VPN tunnel extension")

        do {
            try await startTunnelInner(options: options)
        } catch is CancellationError {
            // The bootstrap retry was cancelled because stopTunnel was called.
            // The tunnel was abandoned cleanly; don't surface a Swift error
            // string ("operation couldn't be completed") to the main app via
            // the app-group error file. The user disconnected on purpose.
            Self.logger.info("startTunnel cancelled (user-initiated disconnect)")
            VPNConnectionDebugLogger.shared.logMarker("VPN CONNECT CANCELLED")
            throw CancellationError()
        } catch {
            let errorMsg = error.localizedDescription
            Self.logger.error("startTunnel failed: \(errorMsg)")
            VPNConnectionDebugLogger.shared.logMarker("VPN CONNECT FAILED: \(errorMsg)")
            Self.writeErrorToAppGroup(error)
            throw error
        }
    }

    private func startTunnelInner(options: [String: NSObject]?) async throws {
        let debugLog = VPNConnectionDebugLogger.shared
        debugLog.resetSession()

        // Wire Go vpntunnel debug output to VPNConnectionDebugLogger when enabled
        if debugLog.isEnabled {
            VpntunnelSetDebugLogger(VPNGoDebugLoggerBridge())
        } else {
            VpntunnelSetDebugLogger(nil)
        }

#if os(macOS)
        // The packet tunnel runs as a root system extension on macOS, which
        // cannot read the per-user app group or login keychain. The host
        // (user session) resolves the profile + secrets and pushes them via
        // startTunnel(options:) as a `VPNResolvedConfig`.
        debugLog.beginPhase("loadProfile", "Decoding host-provided config...")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let resolvedData = options?["resolvedConfig"] as? Data,
              let resolved = try? decoder.decode(VPNResolvedConfig.self, from: resolvedData) else {
            debugLog.endPhase("loadProfile", "FAILED: no resolved config in start options")
            throw VPNError.configNotFound
        }
        var config = try VPNTunnelConfig(snapshot: resolved.snapshot)
        config.resolvedCredential = resolved.credential
        config.jumpResolvedCredential = resolved.jumpCredential
        debugLog.endPhase("loadProfile", "OK")
#else
        let profileID = try configuredProfileID(options: options)

        debugLog.beginPhase("loadProfile", "Loading profile \(profileID.uuidString.prefix(8))...")
        guard let snapshot = VPNSharedProfileStore.profile(id: profileID) else {
            debugLog.endPhase("loadProfile", "FAILED: profile not found")
            throw VPNError.configNotFound
        }
        let config = try VPNTunnelConfig(snapshot: snapshot)
        debugLog.endPhase("loadProfile", "OK")
#endif

        failureStateLock.withLock { hasHandledGoFailure = false }

        // Bump generation so any lingering reconnection task from a previous
        // tunnel session will detect staleness and exit.
        // Also clear stale TSSH metadata so a failed TSSH start can't leak
        // into a subsequent non-TSSH session's enrichStatusJSON. Reset
        // stopRequested so the bootstrap retry's post-await stopped-guard
        // sees a clean slate.
        runningStateLock.withLock {
            tunnelGeneration &+= 1
            tsshPort = 0
            tsshMode = ""
            tsshMTU = 0
            tunMTU = 0
            stopRequested = false
        }

        let host = config.sshHost
        let transport = config.transportType.rawValue
        Self.logger.info("VPN config loaded: transport=\(transport), host=\(host)")
        debugLog.logMarker("VPN CONNECT START: transport=\(transport) host=\(host)")

        // Build the Go config JSON based on transport type
        let goConfigJSON: String

        switch config.transportType {
        case .ssh:
            goConfigJSON = try await startSSHTransport(config: config)

        case .tssh:
            goConfigJSON = try await startTSSHTransport(config: config)
        }

        // Start Go netstack tunnel
        debugLog.beginPhase("goNetstack", "Starting Go tunnel...")
        let callback = TunnelCallbackImpl(provider: self)
        var startError: NSError?
        let started = VpntunnelStartTunnel(goConfigJSON, callback, &startError)
        if !started, let error = startError {
            let errorMsg = error.localizedDescription
            Self.logger.error("Go tunnel start failed: \(errorMsg)")
            debugLog.logError("goNetstack", error)
            await cleanupSSH()
            throw error
        }
        debugLog.endPhase("goNetstack", "OK")

        Self.logger.info("Go netstack tunnel started")

        // For TSSH: now that Go has connected to tsshd, we can close the SSH spawn connection.
        // The SSH was only kept alive so tsshd wouldn't die before Go connected.
        // For SSH mode, the SSH client stays alive to serve the SOCKS5 proxy.
        if config.transportType == .tssh {
            await cleanupSSH()
            Self.logger.info("TSSH spawn SSH connection closed")
        }

        // Resolve server IP for route exclusion (NEIPv4Route requires IP literal)
        debugLog.beginPhase("routeDNS", "Resolving \(config.sshHost) for route exclusion...")
        let serverIP = await resolveHostToIP(config.sshHost)
        debugLog.endPhase("routeDNS", "OK → \(serverIP)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIP)

        // IPv4 settings
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]

        // Build route exclusions
        var excluded: [NEIPv4Route] = []
        // Always exclude the SSH/TSSH server to prevent routing loops
        if serverIP != "0.0.0.0" {
            excluded.append(NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255"))
        }
        // Apply user-configured route exclusions
        for cidr in config.excludedRoutes {
            if let route = parseIPv4Route(cidr) {
                excluded.append(route)
            }
        }
        if !excluded.isEmpty {
            ipv4.excludedRoutes = excluded
        }
        settings.ipv4Settings = ipv4

        // DNS settings — VPN routes all traffic through the remote server, so DNS
        // servers must be reachable from there. Default to public DNS if not configured.
        let dnsServers = config.dnsServers.isEmpty ? ["8.8.8.8", "1.1.1.1"] : config.dnsServers
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)

        // MTU — for TSSH, Go auto-resolved TUN MTU from GetMaxDatagramSize();
        // read back the effective value. For SSH, config.mtu is already 1500.
        let effectiveMTU: Int
        if config.mtu == 0 {
            let goMTU = VpntunnelGetEffectiveMTU()
            effectiveMTU = goMTU > 0 ? Int(goMTU) : 1500
        } else {
            effectiveMTU = config.mtu
        }
        settings.mtu = NSNumber(value: effectiveMTU)
        runningStateLock.withLock { tunMTU = effectiveMTU }

        let tsshMTUDesc = config.trzszMTU ?? 1400
        debugLog.beginPhase("tunnelSettings", "Applying network settings: tsshMTU=\(tsshMTUDesc) tunMTU=\(effectiveMTU) dns=\(dnsServers.joined(separator: ",")) excludedRoutes=\(excluded.count)")
        try await setTunnelNetworkSettings(settings)
        debugLog.endPhase("tunnelSettings", "OK")
        Self.logger.info("Tunnel network settings applied")

        let totalMs = debugLog.sessionElapsedMs()
        debugLog.logMarker("VPN CONNECT COMPLETE: total=\(totalMs)ms")

        let recorder = VPNTrafficRecorder()
        recorder.start()

        runningStateLock.withLock {
            runningState = true
            tunnelStartDate = Date()
            trafficRecorder = recorder
        }

        VPNWidgetState.write(
            VPNWidgetState(
                status: "connected",
                profileID: config.profileID,
                profileName: config.profileName,
                host: config.sshHost,
                connectedSince: Date(),
                lastUpdated: Date()
            )
        )
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif

        // Start packet forwarding
        startPacketForwarding()
    }

    // nonisolated: must execute even when MainActor is blocked by the write loop.
    // Thread-safe operations (locks, Go calls) run immediately on the system's
    // thread. VpntunnelStopTunnel makes ReadPacket return nil, which exits the
    // write loop and frees MainActor for cleanupSSH.
    nonisolated override func stopTunnel(with reason: NEProviderStopReason) async {
        let reasonStr = String(describing: reason)
        Self.logger.info("Stopping VPN tunnel: reason=\(reasonStr)")

        // Mark the tunnel as stopped BEFORE cancelling the bootstrap retry.
        // Order matters: the bootstrap's post-await guard reads stopRequested
        // to decide whether to discard a connect that completed cooperatively
        // after cancellation. Setting it first guarantees the guard sees the
        // stopped state regardless of how the cancel/retry race plays out.
        runningStateLock.withLock { stopRequested = true }

        // Cancel any in-flight bootstrap retry so a Disconnect during the
        // ~5-minute initial-connect retry budget responds immediately
        // instead of waiting for the next backoff to elapse.
        cancelBootstrapIfRunning()

        let recorder = runningStateLock.withLock { () -> VPNTrafficRecorder? in
            runningState = false
            tunnelStartDate = nil
            tsshPort = 0
            tsshMode = ""
            tsshMTU = 0
            tunMTU = 0
            let r = trafficRecorder
            trafficRecorder = nil
            return r
        }
        recorder?.stop()
        failureStateLock.withLock { hasHandledGoFailure = true }

        let existingState = VPNWidgetState.read()
        VPNWidgetState.write(
            VPNWidgetState(
                status: "disconnecting",
                profileID: existingState?.profileID,
                profileName: existingState?.profileName,
                host: existingState?.host,
                connectedSince: nil,
                lastUpdated: Date()
            )
        )
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif

        // Stop health monitor before tearing down SSH
        let monitor = sshStateLock.withLock { () -> VPNSSHHealthMonitor? in
            let m = healthMonitor
            healthMonitor = nil
            return m
        }
        monitor?.stop()

        // Stop Go netstack — makes ReadPacket return nil, unblocking MainActor
        var stopError: NSError?
        VpntunnelStopTunnel(&stopError)
        if let error = stopError {
            let msg = error.localizedDescription
            Self.logger.error("Go tunnel stop error: \(msg)")
        }

        // Clear Go debug logger to release Swift bridge object
        VpntunnelSetDebugLogger(nil)

        // Clean up SSH resources (hops to MainActor, now free)
        await cleanupSSH()

        VPNWidgetState.write(
            VPNWidgetState(
                status: "disconnected",
                profileID: existingState?.profileID,
                profileName: existingState?.profileName,
                host: existingState?.host,
                connectedSince: nil,
                lastUpdated: Date()
            )
        )
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif

        Self.logger.info("VPN tunnel stopped")
    }

    // nonisolated: must respond even when MainActor is blocked by the write loop.
    // Only calls VpntunnelGetStatus() (thread-safe Go function) and parameters.
    nonisolated override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        #if os(macOS)
        // Agent signing broker (host long-poll). The poll completion may be
        // parked and invoked later; NE allows deferred completion handlers.
        if message == VPNAgentBrokerMessage.poll {
            VPNAgentSignBroker.shared.handlePoll(completionHandler ?? { _ in })
            return
        }
        if message.hasPrefix(VPNAgentBrokerMessage.submitPrefix) {
            let body = messageData.dropFirst(VPNAgentBrokerMessage.submitPrefix.utf8.count)
            completionHandler?(VPNAgentSignBroker.shared.handleSubmit(Data(body)))
            return
        }
        #endif

        switch message {
        case "getStatus":
            let status = VpntunnelGetStatus()
            if let enriched = enrichStatusJSON(status) {
                Self.logger.debug("handleAppMessage getStatus: replying \(enriched.count) bytes")
                completionHandler?(enriched.data(using: .utf8))
            } else {
                Self.logger.debug("handleAppMessage getStatus: replying unenriched \(status.count) bytes")
                completionHandler?(status.data(using: .utf8))
            }
        default:
            Self.logger.debug("handleAppMessage: unknown message, replying nil")
            completionHandler?(nil)
        }
    }

    private func configuredProfileID(options: [String: NSObject]?) throws -> UUID {
        // Prefer the persisted providerConfiguration value — it is the authoritative
        // source and survives iOS relaunching the extension after another VPN
        // provider releases the system VPN slot. The `options` dict passed to
        // startVPNTunnel(_:) is best-effort and is not reliably propagated in that
        // post-takeover relaunch path (e.g. starting from Control Center after
        // Tailscale stops), which is why we previously hit VPNError.configNotFound.
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfiguration = proto.providerConfiguration,
           let rawProfileID = providerConfiguration["profileID"] as? String,
           let profileID = UUID(uuidString: rawProfileID) {
            return profileID
        }

        if let rawProfileID = options?["profileID"] as? String,
           let profileID = UUID(uuidString: rawProfileID) {
            return profileID
        }

        throw VPNError.configNotFound
    }

    /// Merge extension process memory metrics into the Go status JSON payload.
    private nonisolated func enrichStatusJSON(_ statusJSON: String) -> String? {
        guard let statusData = statusJSON.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: statusData)) as? [String: Any] else {
            return nil
        }

        if let bytes = Self.currentMemoryFootprintBytes() {
            payload["extensionPhysFootprintBytes"] = Int64(bytes)
            payload["extensionMemoryBudgetBytes"] = Int64(Self.extensionMemoryBudgetBytes)
            payload["extensionMemoryUsagePercent"] = (Double(bytes) * 100.0) / Double(Self.extensionMemoryBudgetBytes)
        }

        if let startDate = currentTunnelStartDate {
            payload["connectedSinceUnix"] = startDate.timeIntervalSince1970
        }

        let (tPort, tMode, tMTU, tTunMTU) = runningStateLock.withLock { (tsshPort, tsshMode, tsshMTU, tunMTU) }
        if tPort > 0 {
            payload["tsshPort"] = tPort
            payload["tsshMode"] = tMode
            if tMTU > 0 { payload["tsshMTU"] = tMTU }
        }
        if tTunMTU > 0 { payload["tunMTU"] = tTunMTU }

        payload["extensionSocksDebug"] = VPNSOCKS5DebugMetrics.shared.snapshot()

        let rec = runningStateLock.withLock { trafficRecorder }
        if let snapshots = rec?.snapshotsForJSON(), !snapshots.isEmpty {
            payload["trafficHistory"] = snapshots
        }

        guard let mergedData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        return String(data: mergedData, encoding: .utf8)
    }

    /// Returns current process phys_footprint in bytes.
    private nonisolated static func currentMemoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }

        guard kerr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: - Packet Forwarding

    private func startPacketForwarding() {
        // Read loop: OS → netstack
        // Uses completion-chaining pattern: each readPackets callback schedules the next read.
        startReadLoop()

        // Write loop: netstack → OS
        // Blocks on the first packet, then drains up to 63 more without blocking
        // and writes the entire batch to the OS in a single writePackets() call.
        // This dramatically improves throughput for many concurrent TCP flows by
        // reducing per-packet syscall overhead and draining gVisor's outbound
        // queue faster (preventing packet drops that cause TCP retransmissions).
        Task { [weak self] in
            guard let self else { return }
            Self.logger.info("Write loop started")
            let ipv4Protocol = NSNumber(value: 2)
            let ipv6Protocol = NSNumber(value: 30)
            let maxBatchSize = 64
            var packetBatch: [Data] = []
            packetBatch.reserveCapacity(maxBatchSize)
            var protocolBatch: [NSNumber] = []
            protocolBatch.reserveCapacity(maxBatchSize)
            var packetsSinceYield = 0
            while self.isRunning {
                var batchCount = 0
                let shouldContinue = autoreleasepool { () -> Bool in
                    // Block until at least one packet is available
                    guard let result = VpntunnelReadPacket() else {
                        Self.logger.info("Write loop: ReadPacket returned nil, tunnel torn down")
                        return false
                    }
                    guard let data = result.data, !data.isEmpty else {
                        return true
                    }

                    packetBatch.removeAll(keepingCapacity: true)
                    protocolBatch.removeAll(keepingCapacity: true)

                    packetBatch.append(data)
                    protocolBatch.append(result.family == 30 ? ipv6Protocol : ipv4Protocol)

                    // Drain up to maxBatchSize-1 more packets without blocking
                    while packetBatch.count < maxBatchSize {
                        guard let extra = VpntunnelReadPacketNonBlocking() else { break }
                        guard let extraData = extra.data, !extraData.isEmpty else { continue }
                        packetBatch.append(extraData)
                        protocolBatch.append(extra.family == 30 ? ipv6Protocol : ipv4Protocol)
                    }

                    batchCount = packetBatch.count
                    self.packetFlow.writePackets(packetBatch, withProtocols: protocolBatch)
                    return true
                }
                if !shouldContinue { break }
                // Yield periodically so the main queue can process IPC
                // (handleAppMessage, stopTunnel). Count packets not iterations
                // since batches can be large.
                packetsSinceYield += max(batchCount, 1)
                if packetsSinceYield >= 50 {
                    packetsSinceYield = 0
                    await Task.yield()
                }
            }
            Self.logger.info("Write loop ended")
        }
    }

    /// Completion-chaining read loop: reads packets from the TUN, injects into netstack,
    /// then immediately re-registers for the next read.
    private func startReadLoop() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            autoreleasepool {
                let count = min(packets.count, protocols.count)
                guard count > 0 else { return }
                for index in 0..<count {
                    let family = Int(protocols[index].int32Value)
                    VpntunnelInjectPacket(packets[index], family)
                }
            }
            // Chain the next read
            self?.startReadLoop()
        }
    }

    // MARK: - SSH Cleanup

    nonisolated private func cleanupSSH() async {
        let (monitor, proxy, client, jump, sshGroup, socksGroup) = sshStateLock.withLock {
            let result = (healthMonitor, socksProxy, sshClient, jumpClient, sshEventLoopGroup, socksEventLoopGroup)
            healthMonitor = nil
            socksProxy = nil
            sshClient = nil
            jumpClient = nil
            sshEventLoopGroup = nil
            socksEventLoopGroup = nil
            return result
        }

        monitor?.stop()

        if let proxy {
            await proxy.stop()
        }

        if let client {
            try? await client.close()
        }

        if let jump {
            try? await jump.close()
        }

        if let sshGroup {
            try? await sshGroup.shutdownGracefully()
        }
        if let socksGroup {
            try? await socksGroup.shutdownGracefully()
        }
    }

    // nonisolated: called from Go's thread via TunnelCallbackImpl.
    // Only accesses lock-protected state and dispatches cancelTunnelWithError.
    nonisolated fileprivate func handleGoTunnelFailure(_ reason: String) {
        failureStateLock.lock()
        let shouldHandle = !hasHandledGoFailure
        if shouldHandle {
            hasHandledGoFailure = true
        }
        failureStateLock.unlock()
        guard shouldHandle else {
            Self.logger.info("Go tunnel failure suppressed (reconnecting): \(reason)")
            VPNSOCKS5DebugMetrics.shared.tsLog("GO-FAILURE-SUPPRESSED reason=\(reason)")
            return
        }

        let msg = reason.isEmpty ? "Go tunnel disconnected" : reason
        Self.logger.error("Go tunnel failure: \(msg)")
        VPNSOCKS5DebugMetrics.shared.tsLog("GO-FAILURE reason=\(msg)")
        isRunning = false

        let error = NSError(
            domain: "com.rootshell.vpntunnel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
        DispatchQueue.main.async { [weak self] in
            self?.cancelTunnelWithError(error)
        }
    }

    // MARK: - SSH Reconnection

    /// Called when the SSH connection is detected as dead (keepalive timeout or onDisconnect).
    /// Nonisolated: may be called from NIO event loop or health monitor task.
    nonisolated private func handleSSHConnectionLost(reason: String) {
        // Guard against concurrent reconnection attempts
        reconnectLock.lock()
        guard !isReconnecting else {
            reconnectLock.unlock()
            Self.logger.info("SSH connection lost (\(reason)) but reconnection already in progress")
            return
        }
        guard isRunning else {
            reconnectLock.unlock()
            Self.logger.info("SSH connection lost (\(reason)) but tunnel is stopping")
            return
        }
        isReconnecting = true
        reconnectLock.unlock()

        // Capture the tunnel generation so the reconnection task can detect
        // if a stop/start cycle happened while it was sleeping/connecting.
        let generation = currentGeneration

        Self.logger.error("SSH connection lost: \(reason)")
        VPNSOCKS5DebugMetrics.shared.addEvent("ssh.connectionLost reason=\(reason)")
        VPNSOCKS5DebugMetrics.shared.tsLog("RECONNECT-START reason=\(reason)")

        Task {
            await attemptSSHReconnection(generation: generation)
        }
    }

    /// Attempt to re-establish the SSH connection and SOCKS5 proxy.
    /// Retries with exponential backoff, then tears down the tunnel on failure.
    /// The `generation` parameter ties this task to the tunnel session that spawned it;
    /// if a stop/start cycle bumps the generation, this task detects staleness and exits
    /// instead of tearing down the new session's resources.
    nonisolated private func attemptSSHReconnection(generation: UInt64) async {
        let debugLog = VPNConnectionDebugLogger.shared
        guard let config = storedConfig else {
            Self.logger.error("No stored config for SSH reconnection")
            reconnectLock.withLock { isReconnecting = false }
            handleGoTunnelFailure("SSH reconnection failed: no stored config")
            return
        }

        let backoffDelays: [TimeInterval] = [5, 10, 20, 30, 30]

        // Stop health monitor once before the retry loop — don't restart
        // it until we have a live connection.
        let oldMonitor = sshStateLock.withLock { () -> VPNSSHHealthMonitor? in
            let m = healthMonitor
            healthMonitor = nil
            return m
        }
        oldMonitor?.stop()

        // Suppress Go tunnel failure during reconnection — closing the old SSH
        // client causes all SOCKS proxy connections to fail at the DirectTCPIP
        // level. Go's netstack sees these failures and calls onTunnelError,
        // which would set isRunning=false and kill the tunnel before we can
        // reconnect. Setting hasHandledGoFailure=true makes handleGoTunnelFailure
        // a no-op until we reset it after successful reconnection.
        failureStateLock.withLock { hasHandledGoFailure = true }

        // Capture and close old SSH state. IMPORTANT: keep socksProxy and
        // socksEventLoopGroup alive — the SOCKS5 server must stay listening
        // on its port so Go's netstack doesn't see "connection refused" and
        // declare the tunnel dead. New SOCKS connections will fail at the
        // SSH DirectTCPIP level (expected), and once we swap in a new SSH
        // client they'll start succeeding again.
        let (oldClient, oldJump, oldSshGroup) = sshStateLock.withLock {
            let result = (sshClient, jumpClient, sshEventLoopGroup)
            sshClient = nil
            jumpClient = nil
            sshEventLoopGroup = nil
            return result
        }
        if let oldClient { try? await oldClient.close() }
        if let oldJump { try? await oldJump.close() }
        if let oldSshGroup { try? await oldSshGroup.shutdownGracefully() }

        var permanentFailureReason: String?

        for attempt in 1...Self.maxReconnectAttempts {
            guard isRunning, currentGeneration == generation else {
                Self.logger.info("SSH reconnection aborted: tunnel stopped or new session started")
                debugLog.log("reconnect", "Aborted: tunnel stopped or new session started")
                break
            }

            reconnectAttempts = attempt
            Self.logger.info("SSH reconnection attempt \(attempt)/\(Self.maxReconnectAttempts)")
            VPNSOCKS5DebugMetrics.shared.increment("ssh.reconnect.attempt")
            VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.attempt \(attempt)/\(Self.maxReconnectAttempts)")
            debugLog.logMarker("RECONNECTION #\(attempt)/\(Self.maxReconnectAttempts) (reason: SSH connection lost)")

            // Wait for network before attempting connection. Without this,
            // airplane mode toggle burns all retry attempts against a dead
            // network and the tunnel is killed before connectivity returns.
            Self.logger.info("SSH reconnection: waiting for network availability")
            VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.awaitingNetwork")
            debugLog.beginPhase("networkWait", "Waiting for network availability (timeout: 120s)...")
            guard await waitForNetwork(timeout: 120, generation: generation) else {
                Self.logger.info("SSH reconnection: network not available or tunnel stopped")
                VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.networkWaitFailed")
                debugLog.endPhase("networkWait", "FAILED: timeout or tunnel stopped")
                break
            }
            VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.networkAvailable")
            debugLog.endPhase("networkWait", "OK")

            // Create fresh SSH event loop group (SOCKS group stays alive)
            let sshGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            do {
                // Establish new SSH connection
                debugLog.beginPhase("sshReconnect", "Connecting to \(config.sshHost):\(config.sshPort)...")
                let connResult = try await VPNSSHConnector.connect(config: config, group: sshGroup)
                debugLog.endPhase("sshReconnect", "OK")
                Self.logger.info("SSH reconnection: connection established")

                // Check if tunnel was stopped or a new session started while we
                // were connecting. If so, tear down what we just created and exit.
                guard isRunning, currentGeneration == generation else {
                    Self.logger.info("SSH reconnection aborted after connect: tunnel stopped or new session started")
                    debugLog.log("reconnect", "Aborted after connect: tunnel stopped or new session started")
                    try? await connResult.client.close()
                    if let jump = connResult.jumpClient { try? await jump.close() }
                    try? await sshGroup.shutdownGracefully()
                    break
                }

                // Hot-swap the SSH client in the existing SOCKS5 proxy.
                // New connections will use the fresh SSH client immediately.
                debugLog.beginPhase("sshSwap", "Hot-swapping SSH client in SOCKS5 proxy...")
                let proxy = sshStateLock.withLock { socksProxy }
                proxy?.updateSSHClient(connResult.client)
                debugLog.endPhase("sshSwap", "OK")

                // Store new SSH resources
                sshStateLock.withLock {
                    self.sshClient = connResult.client
                    self.jumpClient = connResult.jumpClient
                    self.sshEventLoopGroup = sshGroup
                }

                // Register disconnect callback on new client
                connResult.client.onDisconnect { [weak self] in
                    VPNSOCKS5DebugMetrics.shared.addEvent("ssh.onDisconnect.fired")
                    VPNSOCKS5DebugMetrics.shared.tsLog("SSH-DISCONNECT")
                    self?.handleSSHConnectionLost(reason: "SSH disconnected")
                }

                // Start new health monitor
                let monitor = VPNSSHHealthMonitor()
                monitor.onConnectionLost = { [weak self] in
                    self?.handleSSHConnectionLost(reason: "keepalive timeout")
                }
                monitor.start(client: connResult.client)
                sshStateLock.withLock { self.healthMonitor = monitor }

                // Success — re-enable Go tunnel failure handling now that
                // the new SSH client is live and SOCKS connections will succeed.
                failureStateLock.withLock { hasHandledGoFailure = false }
                reconnectLock.withLock {
                    isReconnecting = false
                    reconnectAttempts = 0
                }

                Self.logger.info("SSH reconnection successful")
                VPNSOCKS5DebugMetrics.shared.increment("ssh.reconnect.success")
                VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.success after \(attempt) attempt(s)")
                VPNSOCKS5DebugMetrics.shared.tsLog("RECONNECT-OK attempt=\(attempt)")
                debugLog.logMarker("RECONNECTION #\(attempt) OK")
                return

            } catch {
                // Clean up per-attempt SSH resources
                try? await sshGroup.shutdownGracefully()

                let desc = String(describing: error)
                Self.logger.error("SSH reconnection attempt \(attempt) failed: \(desc)")
                VPNSOCKS5DebugMetrics.shared.increment("ssh.reconnect.failed")
                VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.failed attempt=\(attempt) error=\(desc)")
                VPNSOCKS5DebugMetrics.shared.tsLog("RECONNECT-FAIL attempt=\(attempt)")
                debugLog.logError("sshReconnect", error)

                // Permanent failures are never worth retrying: bail now so a
                // mid-session key change (possible MITM) or credential failure
                // tears the tunnel down immediately instead of burning the
                // backoff budget. Same classifier as the bootstrap sites —
                // Citadel can surface pinned-key rejection as InvalidHostKey,
                // which only the shared classifier recognizes.
                if error is VPNSSHError || InitialConnectRetry.isPermanentConnectError(error) {
                    permanentFailureReason = error.localizedDescription
                    break
                }

                // Wait with exponential backoff before next attempt
                if attempt < Self.maxReconnectAttempts {
                    let delay = backoffDelays[min(attempt - 1, backoffDelays.count - 1)]
                    Self.logger.info("SSH reconnection: waiting \(delay)s before next attempt")
                    debugLog.log("reconnect", "Backoff: waiting \(delay)s before next attempt")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // Exhausted all retries, tunnel stopped, or generation is stale
        reconnectLock.withLock { isReconnecting = false }

        guard isRunning, currentGeneration == generation else {
            Self.logger.info("SSH reconnection: tunnel stopped or new session started, skipping failure")
            return
        }

        let failureReason = permanentFailureReason ?? "SSH reconnection failed after \(Self.maxReconnectAttempts) attempts"
        Self.logger.error("SSH reconnection giving up: \(failureReason)")
        VPNSOCKS5DebugMetrics.shared.addEvent("ssh.reconnect.exhausted")
        debugLog.logMarker("RECONNECTION FAILED: \(failureReason)")
        // Re-enable so handleGoTunnelFailure actually fires
        failureStateLock.withLock { hasHandledGoFailure = false }
        handleGoTunnelFailure(failureReason)
    }

    // MARK: - SSH Transport

    /// Start SSH transport: connect via Citadel, start SOCKS5 proxy, return Go config JSON.
    private func startSSHTransport(config: VPNTunnelConfig) async throws -> String {
        let debugLog = VPNConnectionDebugLogger.shared
        Self.logger.info("SSH mode: establishing SSH connection and SOCKS5 proxy")

        // Wire NIO SSH internal debug metrics into our SOCKS debug metrics
        NIOSSHDebug.shared.setHandlers(
            increment: { key, value in VPNSOCKS5DebugMetrics.shared.increment(key, by: value) },
            set: { key, value in VPNSOCKS5DebugMetrics.shared.set(key, value: value) },
            event: { text in VPNSOCKS5DebugMetrics.shared.addEvent(text) },
            tsLog: { text in VPNSOCKS5DebugMetrics.shared.tsLog(text) }
        )

        // Separate event loops: SSH data processing and SOCKS I/O run on
        // independent threads so neither starves the other. NIO SSH's
        // deliverPendingReads() delivers all buffered data synchronously;
        // on a shared thread this blocks SOCKS writes and channel creation.
        let sshGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let socksGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        sshStateLock.withLock {
            self.sshEventLoopGroup = sshGroup
            self.socksEventLoopGroup = socksGroup
        }

        let authMethod = config.sshAuth.method.rawValue
        let hasJumpHost = config.jumpHostConfig != nil

        do {
            debugLog.beginPhase("sshConnect", "Connecting to \(config.sshHost):\(config.sshPort) user=\(config.sshUsername) auth=\(authMethod) jumpHost=\(hasJumpHost) (with bounded retry)...")
            // Bounded retry on transient connection failures, up to ~5 minutes.
            // Per-attempt loginTimeout ramps so the first attempt fails fast
            // on a stuck SYN and later attempts get more patience.
            let retryTask = Task<VPNSSHConnector.ConnectionResult, Error> {
                try await InitialConnectRetry.run(
                    label: "vpn-bootstrap-ssh:\(config.sshHost)",
                    // VPNSSHError covers missing/mismatched pinned host keys —
                    // never transient, and a mismatch must not be retried.
                    isPermanent: { $0 is VPNSSHError || InitialConnectRetry.isPermanentConnectError($0) }
                ) { attempt, timeout in
                    if attempt > 1 {
                        let timeoutSec = Double(timeout.nanoseconds) / 1_000_000_000
                        Self.logger.info("VPN SSH bootstrap retry attempt \(attempt) (timeout=\(timeoutSec)s)")
                    }
                    return try await VPNSSHConnector.connect(
                        config: config,
                        group: sshGroup,
                        loginTimeout: timeout
                    )
                }
            }
            setBootstrapCancellable(retryTask)
            // `defer` (not just an explicit cancel-in-catch) so that if our
            // own awaiting Task is cancelled by any path other than
            // stopTunnel — system cancellation, parent-task chain, an
            // unexpected throw — the unstructured retryTask is still
            // cancelled instead of being orphaned with no handle.
            // `task.cancel()` is a no-op on a completed Task.
            defer {
                retryTask.cancel()
                clearBootstrapCancellable()
            }
            let connResult = try await retryTask.value

            // Post-await stopped-guard: Task.cancel() is cooperative, so a
            // VPNSSHConnector.connect that was in its final stage may still
            // return a valid ConnectionResult after stopTunnel called
            // cancelBootstrapIfRunning(). If the tunnel was stopped while we
            // were retrying, close the freshly-built SSH client(s) and
            // throw — do NOT wire them into the (already-torn-down) tunnel.
            let stopped = runningStateLock.withLock { stopRequested }
            if stopped {
                Self.logger.info("VPN SSH bootstrap completed but stopTunnel was called; abandoning connection")
                try? await connResult.client.close()
                if let jc = connResult.jumpClient { try? await jc.close() }
                throw CancellationError()
            }

            debugLog.endPhase("sshConnect", "OK")
            sshStateLock.withLock {
                self.sshClient = connResult.client
                self.jumpClient = connResult.jumpClient
            }
            Self.logger.info("SSH connection established")

            debugLog.beginPhase("socksProxy", "Starting SOCKS5 proxy...")
            let proxy = VPNSOCKS5Proxy(sshClient: connResult.client, eventLoopGroup: socksGroup)
            let proxyPort = try await proxy.start()
            debugLog.endPhase("socksProxy", "OK → port=\(proxyPort)")

            sshStateLock.withLock { self.socksProxy = proxy }

            let socks5Addr = "127.0.0.1:\(proxyPort)"
            Self.logger.info("SOCKS5 proxy listening on \(socks5Addr)")

            // Save state for reconnection
            self.storedConfig = config
            self.sshProxyPort = proxyPort

            // Register disconnect callback for immediate detection
            connResult.client.onDisconnect { [weak self] in
                VPNSOCKS5DebugMetrics.shared.addEvent("ssh.onDisconnect.fired")
                VPNSOCKS5DebugMetrics.shared.tsLog("SSH-DISCONNECT")
                self?.handleSSHConnectionLost(reason: "SSH disconnected")
            }

            // Start keepalive health monitor
            let monitor = VPNSSHHealthMonitor()
            monitor.onConnectionLost = { [weak self] in
                self?.handleSSHConnectionLost(reason: "keepalive timeout")
            }
            monitor.start(client: connResult.client)
            sshStateLock.withLock { self.healthMonitor = monitor }

            return try config.toGoConfigJSON(socks5Address: socks5Addr)
        } catch {
            await cleanupSSH()
            throw error
        }
    }

    // MARK: - TSSH Transport

    /// Start TSSH transport: SSH to server, spawn tsshd, parse server info, pass to Go.
    /// SSH connections are kept alive on self so tsshd doesn't die before Go connects.
    /// Call cleanupTSSHSpawnConnection() after Go StartTunnel succeeds.
    private func startTSSHTransport(config: VPNTunnelConfig) async throws -> String {
        let debugLog = VPNConnectionDebugLogger.shared
        Self.logger.info("TSSH mode: spawning tsshd via SSH")

        // Resolve hostname to IPv4 first (matching main app's DualStackResolver behavior).
        // tsshd listens on the address family of the incoming SSH connection, so Go's
        // UDP client must connect on the same family. IPv4 is preferred because it's
        // universally supported and avoids IPv4/IPv6 mismatch between SSH and UDP.
        let host = config.sshHost
        debugLog.beginPhase("dnsResolution", "Resolving \(host) (IPv4 preferred)...")
        let resolvedHost = await resolveHostPreferIPv4(host)
        debugLog.endPhase("dnsResolution", "OK → \(resolvedHost)")
        Self.logger.info("Resolved \(host) to \(resolvedHost) for TSSH")

        // Step 1: SSH to the server using the resolved IP
        let authMethod = config.sshAuth.method.rawValue
        let hasJumpHost = config.jumpHostConfig != nil
        debugLog.beginPhase("sshConnect", "Connecting to \(resolvedHost):\(config.sshPort) user=\(config.sshUsername) auth=\(authMethod) jumpHost=\(hasJumpHost) (with bounded retry)...")
        // Bounded retry on transient connection failures, up to ~5 minutes.
        // Per-attempt loginTimeout ramps so the first attempt fails fast
        // on a stuck SYN and later attempts get more patience.
        let tsshRetryTask = Task<VPNSSHConnector.ConnectionResult, Error> {
            try await InitialConnectRetry.run(
                label: "vpn-bootstrap-tssh:\(resolvedHost)",
                // VPNSSHError covers missing/mismatched pinned host keys —
                // never transient, and a mismatch must not be retried.
                isPermanent: { $0 is VPNSSHError || InitialConnectRetry.isPermanentConnectError($0) }
            ) { attempt, timeout in
                if attempt > 1 {
                    let timeoutSec = Double(timeout.nanoseconds) / 1_000_000_000
                    Self.logger.info("VPN TSSH bootstrap retry attempt \(attempt) (timeout=\(timeoutSec)s)")
                }
                return try await VPNSSHConnector.connect(
                    config: config,
                    resolvedHost: resolvedHost,
                    loginTimeout: timeout
                )
            }
        }
        setBootstrapCancellable(tsshRetryTask)
        // `defer` ensures the unstructured retry task is always cancelled
        // when this scope unwinds, even when the awaiting Task is cancelled
        // by a path other than stopTunnel. `task.cancel()` is a no-op on a
        // completed Task.
        defer {
            tsshRetryTask.cancel()
            clearBootstrapCancellable()
        }
        let connResult = try await tsshRetryTask.value

        // Post-await stopped-guard: Task.cancel() is cooperative, so a
        // VPNSSHConnector.connect that was in its final stage may still
        // return a valid ConnectionResult after stopTunnel called
        // cancelBootstrapIfRunning(). If the tunnel was stopped while we
        // were retrying, close the freshly-built SSH client(s) and throw —
        // do NOT proceed to spawn tsshd or wire anything into Go netstack.
        let stopped = runningStateLock.withLock { stopRequested }
        if stopped {
            Self.logger.info("VPN TSSH bootstrap completed but stopTunnel was called; abandoning connection")
            try? await connResult.client.close()
            if let jc = connResult.jumpClient { try? await jc.close() }
            throw CancellationError()
        }

        debugLog.endPhase("sshConnect", "OK")
        // Store on self to keep alive — tsshd dies if SSH closes before Go connects
        sshStateLock.withLock {
            self.sshClient = connResult.client
            self.jumpClient = connResult.jumpClient
        }
        Self.logger.info("SSH connection established for tsshd spawn")

        // Step 2: Execute tsshd command and parse JSON output
        let serverInfo: VPNTunnelConfig.TSSHServerInfo
        do {
            let mode = config.trzszMode ?? "KCP"
            let udpPortMin = config.trzszUDPPortMin ?? 61000
            let udpPortMax = config.trzszUDPPortMax ?? 61999
            let mtuDesc = config.trzszMTU.map { " --mtu \($0)" } ?? ""
            let binaryDesc = config.trzszServerPath ?? "tsshd"
            debugLog.beginPhase("tsshdSpawn", "Executing: \(binaryDesc) --\(mode.lowercased()) --port \(udpPortMin)-\(udpPortMax)\(mtuDesc)")
            serverInfo = try await spawnTsshd(
                sshClient: connResult.client,
                mode: mode,
                udpPortMin: udpPortMin,
                udpPortMax: udpPortMax,
                mtu: config.trzszMTU,
                serverPath: config.trzszServerPath
            )
            let tsshMTUVal = config.trzszMTU ?? 1400
            debugLog.endPhase("tsshdSpawn", "OK → port=\(serverInfo.port) mode=\(serverInfo.mode) tsshMTU=\(tsshMTUVal)")
        } catch {
            debugLog.logError("tsshdSpawn", error)
            await cleanupSSH()
            throw error
        }

        let infoPort = serverInfo.port
        let infoMode = serverInfo.mode
        Self.logger.info("tsshd spawned: port=\(infoPort), mode=\(infoMode)")

        // Store TSSH details for status reporting to main app
        runningStateLock.withLock {
            tsshPort = serverInfo.port
            tsshMode = serverInfo.mode
            tsshMTU = config.trzszMTU ?? 0
        }

        // Step 3: Build Go config JSON with server info, using resolved IP for tsshHost
        // SSH stays alive — cleanupTSSHSpawnConnection() is called after Go connects
        return try config.toGoConfigJSON(tsshServerInfo: serverInfo, resolvedHost: resolvedHost)
    }

    /// Spawn tsshd on the remote server via SSH and parse the JSON server info.
    private func spawnTsshd(
        sshClient: SSHClient,
        mode: String,
        udpPortMin: Int = 61000,
        udpPortMax: Int = 61999,
        mtu: Int? = nil,
        serverPath: String? = nil
    ) async throws -> VPNTunnelConfig.TSSHServerInfo {
        let modeFlag = mode.lowercased() == "quic" ? "--quic" : "--kcp"
        let mtuArg = mtu.map { " --mtu \($0)" } ?? ""
        let debugFlag = VPNConnectionDebugLogger.shared.isEnabled ? " --debug" : ""
        let binary = serverPath ?? "tsshd"
        // When the user specified an absolute path, invoke it directly so we don't
        // shadow it with the PATH-prepend fallback.
        let command: String
        if serverPath == nil {
            command = """
                export PATH="$PATH:$HOME/go/bin:/usr/local/go/bin" && \
                \(binary) --port \(udpPortMin)-\(udpPortMax)\(mtuArg) \(modeFlag)\(debugFlag)
                """
        } else {
            command = "\(binary) --port \(udpPortMin)-\(udpPortMax)\(mtuArg) \(modeFlag)\(debugFlag)"
        }

        Self.logger.info("Executing: \(binary) \(modeFlag)\(mtuArg)")

        // Execute command and collect output
        var stdout = ""
        var stderr = ""
        var serverInfo: VPNTunnelConfig.TSSHServerInfo?
        let streams = try await sshClient.executeCommandStream(command)

        // Read events from the stream until we find JSON
        do {
            for try await event in streams {
                switch event {
                case .stdout(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stdout += str
                        if serverInfo == nil, stdout.contains("{"), stdout.contains("}") {
                            serverInfo = parseTsshdJSON(stdout)
                        }
                    }
                case .stderr(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stderr += str
                        Self.logger.warning("tsshd stderr: \(str)")
                        VPNConnectionDebugLogger.shared.log("tsshdStderr", str)
                    }
                case .exitStatus:
                    break
                }
                if serverInfo != nil { break }
            }
        } catch {
            Self.logger.debug("tsshd stream error: \(error.localizedDescription)")
        }

        // Try one more parse if we haven't found it yet
        if serverInfo == nil {
            serverInfo = parseTsshdJSON(stdout)
        }

        guard let serverInfo else {
            let combined = stdout + stderr
            if combined.contains("not found") || combined.contains("No such file") {
                throw VPNSSHError.connectionFailed("tsshd not found on remote server")
            }
            if combined.contains("Permission denied") {
                throw VPNSSHError.connectionFailed("Permission denied running tsshd")
            }
            throw VPNSSHError.connectionFailed(
                stdout.isEmpty ? "No output from tsshd command" : "No valid JSON in tsshd output"
            )
        }

        return serverInfo
    }

    /// Parse tsshd JSON output to extract server info.
    /// tsshd outputs JSON like: {"ServerVer":"v1.0","Port":61001,"Mode":"KCP","Pass":"...","Salt":"..."}
    private func parseTsshdJSON(_ output: String) -> VPNTunnelConfig.TSSHServerInfo? {
        // Find JSON object in output (may be mixed with other text)
        guard let startIdx = output.firstIndex(of: "{"),
              let endIdx = output.lastIndex(of: "}") else {
            return nil
        }

        let jsonStr = String(output[startIdx...endIdx])

        struct TsshdOutput: Codable {
            let ServerVer: String?
            let Port: Int?
            let Mode: String?
            let Pass: String?
            let Salt: String?
            let ServerCert: String?
            let ClientCert: String?
            let ClientKey: String?
            let ProxyKey: String?
            let ClientID: UInt64?
            let ServerID: UInt64?
        }

        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(TsshdOutput.self, from: data),
              let port = parsed.Port,
              let mode = parsed.Mode else {
            return nil
        }

        let info = VPNTunnelConfig.TSSHServerInfo(
            serverVersion: parsed.ServerVer ?? "",
            port: port,
            mode: mode,
            pass: parsed.Pass,
            salt: parsed.Salt,
            serverCert: parsed.ServerCert,
            clientCert: parsed.ClientCert,
            clientKey: parsed.ClientKey,
            proxyKey: parsed.ProxyKey,
            clientID: parsed.ClientID ?? 0,
            serverID: parsed.ServerID ?? 0
        )
        return info
    }

    // MARK: - Network Helpers

    /// Wait for network to become available, polling every 3 seconds.
    /// Returns true when the network is satisfied, false on timeout or if the
    /// tunnel stopped / generation changed.
    /// In a VPN extension, NWPathMonitor reports physical network status
    /// (not the tunnel interface), so this correctly detects airplane mode.
    private nonisolated func waitForNetwork(timeout: TimeInterval, generation: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard isRunning, currentGeneration == generation else { return false }

            if await probeNetworkSatisfied() { return true }

            // Sleep 3s between probes; also acts as a natural exit point
            // if the tunnel stops (sleep completes, next iteration checks guard)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        return false
    }

    /// One-shot probe: is the physical network currently reachable?
    /// NWPathMonitor fires pathUpdateHandler immediately on start with
    /// the current state, so this completes in milliseconds.
    private nonisolated func probeNetworkSatisfied() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    /// Resolve a hostname preferring IPv4, with IPv6 fallback.
    /// Matches main app's DualStackResolver.preferredAddress behavior (IPv4 ?? IPv6).
    private func resolveHostPreferIPv4(_ host: String) async -> String {
        // Quick check: if it already looks like an IP address, return as-is
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            return host
        }
        if host.contains(":") {
            return host  // Already IPv6
        }

        // Try IPv4 first
        if let ipv4 = await resolveHost(host, family: AF_INET) {
            return ipv4
        }
        // Fall back to IPv6
        if let ipv6 = await resolveHost(host, family: AF_INET6) {
            return ipv6
        }
        // Give up, return original hostname
        return host
    }

    /// Resolve a hostname to an address of the given family.
    private func resolveHost(_ host: String, family: Int32) async -> String? {
        await withCheckedContinuation { continuation in
            var hints = addrinfo()
            hints.ai_family = family
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?

            let status = host.withCString { hostPtr in
                getaddrinfo(hostPtr, nil, &hints, &result)
            }

            defer { if result != nil { freeaddrinfo(result) } }

            guard status == 0, let addrInfo = result else {
                continuation.resume(returning: nil)
                return
            }

            if addrInfo.pointee.ai_family == AF_INET {
                var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var sinAddr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &sinAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                }
                continuation.resume(returning: String(cString: ipStr))
            } else if addrInfo.pointee.ai_family == AF_INET6 {
                var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var sin6Addr = sin6.pointee.sin6_addr
                    inet_ntop(AF_INET6, &sin6Addr, &ipStr, socklen_t(INET6_ADDRSTRLEN))
                }
                continuation.resume(returning: String(cString: ipStr))
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Resolve a hostname to an IPv4 address string. Returns the original string if already an IP.
    private func resolveHostToIP(_ host: String) async -> String {
        // Quick check: if it already looks like an IPv4 address, return as-is
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            return host
        }

        // Resolve via getaddrinfo
        return await withCheckedContinuation { continuation in
            var hints = addrinfo()
            hints.ai_family = AF_INET  // IPv4 only
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?

            let status = host.withCString { hostPtr in
                getaddrinfo(hostPtr, nil, &hints, &result)
            }

            defer { if result != nil { freeaddrinfo(result) } }

            guard status == 0, let addr = result?.pointee.ai_addr else {
                Self.logger.warning("Failed to resolve \(host) to IPv4, using as-is")
                continuation.resume(returning: host)
                return
            }

            var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var sinAddr = sin.pointee.sin_addr
                inet_ntop(AF_INET, &sinAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: ipStr)
            Self.logger.info("Resolved \(host) to \(ip)")
            continuation.resume(returning: ip)
        }
    }

    /// Parse a CIDR string like "192.168.1.0/24" into an NEIPv4Route.
    private func parseIPv4Route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefixLen = Int(parts[1]),
              prefixLen >= 0, prefixLen <= 32 else {
            // Try as plain IP (assume /32)
            if cidr.split(separator: ".").count == 4 {
                return NEIPv4Route(destinationAddress: cidr, subnetMask: "255.255.255.255")
            }
            return nil
        }

        let ip = String(parts[0])
        let mask = prefixLenToMask(prefixLen)
        return NEIPv4Route(destinationAddress: ip, subnetMask: mask)
    }

    private func prefixLenToMask(_ len: Int) -> String {
        let bits: UInt32
        if len <= 0 {
            bits = 0
        } else if len >= 32 {
            bits = UInt32.max
        } else {
            bits = UInt32.max << (32 - len)
        }
        return "\(bits >> 24 & 0xFF).\(bits >> 16 & 0xFF).\(bits >> 8 & 0xFF).\(bits & 0xFF)"
    }
}

// MARK: - Go Callback Implementation

/// Implements the VpntunnelTunnelCallbackProtocol for receiving events from Go.
private class TunnelCallbackImpl: NSObject, VpntunnelTunnelCallbackProtocol {
    weak var provider: SSHVPNTunnelProvider?

    init(provider: SSHVPNTunnelProvider) {
        self.provider = provider
    }

    func onTunnelReady() {
        SSHVPNTunnelProvider.logger.info("Go tunnel ready")
    }

    func onTunnelError(_ message: String?) {
        let msg = message ?? "unknown"
        SSHVPNTunnelProvider.logger.error("Go tunnel error: \(msg)")
        provider?.handleGoTunnelFailure(msg)
    }

    func onTunnelDisconnected(_ reason: String?) {
        let rsn = reason ?? "unknown"
        SSHVPNTunnelProvider.logger.info("Go tunnel disconnected: \(rsn)")
        if rsn == "user requested stop" {
            return
        }
        provider?.handleGoTunnelFailure(rsn)
    }

    func onStatsUpdate(_ bytesIn: Int64, bytesOut: Int64, activeConns: Int) {
        // Stats are polled via handleAppMessage, not pushed
    }
}

// MARK: - Go VPN Debug Logger Bridge

/// Routes Go vpntunnel debug/warning messages to VPNConnectionDebugLogger for file-based persistence.
private final class VPNGoDebugLoggerBridge: NSObject, VpntunnelDebugLoggerProtocol {
    func onDebug(_ msg: String?) {
        guard let msg else { return }
        VPNConnectionDebugLogger.shared.log("goTunnel", msg)
    }
}
