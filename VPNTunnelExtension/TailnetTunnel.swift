//
//  TailnetTunnel.swift
//  VPNTunnelExtension
//
//  Tailscale mode: Go runs WireGuard and routes rule-matched traffic to an
//  optional SSH egress host; this file starts it, persists node state in the
//  keychain, and applies the network settings Go computes.
//

import Foundation
import NetworkExtension
import NIOPosix
import os.log
import Security
import WidgetKit
@preconcurrency import Citadel
@preconcurrency import VPNTunnel

/// Go's tunnelNetworkSettings JSON (see vpntunnel/tailnetpath.go).
nonisolated struct TailnetNetworkSettings: Decodable, Equatable, Sendable {
    var ipv4Addresses: [String]
    var ipv4Routes: [String]?
    var ipv4Excluded: [String]?
    var ipv6Addresses: [String]?
    var ipv6Routes: [String]?
    var dnsServers: [String]?
    var matchDomains: [String]?
    var searchDomains: [String]?
    var fullTunnel: Bool
    var mtu: Int

    static func decode(_ json: String) -> TailnetNetworkSettings? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func makeSettings(excludingIPv4 extraExcluded: [String]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "100.100.100.100")

        let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Addresses.map { _ in "255.255.255.255" })
        ipv4.includedRoutes = (ipv4Routes ?? []).compactMap(Self.ipv4Route)
        let excluded = ((ipv4Excluded ?? []) + extraExcluded).compactMap(Self.ipv4Route)
        if !excluded.isEmpty {
            ipv4.excludedRoutes = excluded
        }
        settings.ipv4Settings = ipv4

        if let addresses = ipv6Addresses, !addresses.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: addresses, networkPrefixLengths: addresses.map { _ in 128 })
            ipv6.includedRoutes = (ipv6Routes ?? []).compactMap(Self.ipv6Route)
            settings.ipv6Settings = ipv6
        }

        if let servers = dnsServers, !servers.isEmpty {
            let dns = NEDNSSettings(servers: servers)
            dns.matchDomains = matchDomains
            dns.searchDomains = searchDomains
            dns.matchDomainsNoSearch = false
            settings.dnsSettings = dns
        }
        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        let length = parts.count == 2 ? Int(parts[1]) : 32
        guard let length, (0...32).contains(length), parts[0].split(separator: ".").count == 4 else { return nil }
        if length == 0 { return NEIPv4Route.default() }
        let bits = UInt32.max << (32 - length)
        let mask = "\(bits >> 24 & 0xFF).\(bits >> 16 & 0xFF).\(bits >> 8 & 0xFF).\(bits & 0xFF)"
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: mask)
    }

    private static func ipv6Route(_ cidr: String) -> NEIPv6Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let length = Int(parts[1]), (0...128).contains(length) else { return nil }
        if length == 0 { return NEIPv6Route.default() }
        return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: length))
    }
}

/// Tailscale node state in the shared keychain, one item per state key.
/// This-device-only: node keys must not travel in backups.
nonisolated final class TailnetKeychainStateStore: NSObject, VpntunnelTailscaleStateStoreProtocol {
    func readState(_ key: String?) throws -> Data {
        try TailnetKeychainState.read(key ?? "")
    }

    func writeState(_ key: String?, value: Data?) throws {
        try TailnetKeychainState.write(key ?? "", value ?? Data())
    }
}

#if os(macOS)
/// Tailscale node state for the root system extension, which can't use the
/// user's keychain: one root-only file per key in its own container.
nonisolated final class TailnetFileStateStore: NSObject, VpntunnelTailscaleStateStoreProtocol {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("tailscale-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func fileURL(_ key: String?) throws -> URL {
        // Keys are Tailscale's own ("_machinekey", "profile-…"); keep names safe.
        let safe = (key ?? "").map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        guard let dir = Self.directory, !safe.isEmpty else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return dir.appendingPathComponent(String(safe))
    }

    func readState(_ key: String?) throws -> Data {
        (try? Data(contentsOf: fileURL(key))) ?? Data()
    }

    func writeState(_ key: String?, value: Data?) throws {
        let url = try fileURL(key)
        try (value ?? Data()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Every stored key and value, for handing the node to the in-app engine.
    static func exportAll() -> [String: Data] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var state: [String: Data] = [:]
        for name in names {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { state[name] = data }
        }
        return state
    }

    /// Replaces the stored node state with the in-app engine's copy.
    static func replaceAll(_ state: [String: Data]) {
        guard let dir = directory else { return }
        let store = TailnetFileStateStore()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where state[name] == nil {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        for (key, value) in state {
            try? store.writeState(key, value: value)
        }
    }
}
#endif

/// One Tailscale tunnel session: receives Go state, applies network
/// settings in order, and brings up the SSH egress connection.
nonisolated final class TailnetSession: NSObject, VpntunnelTailscaleCallbackProtocol, @unchecked Sendable {
    static let messagePrefix = "tailscale."
    static let messageQueue = DispatchQueue(label: "VPNTunnel.tailscale", qos: .userInitiated)
    private static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "Tailnet")

    private static let currentLock = NSLock()
    private nonisolated(unsafe) static weak var current: TailnetSession?

    private weak var provider: SSHVPNTunnelProvider?
    let egress: VPNTunnelConfig?
    /// IPv4 of the first SSH hop when it isn't a tailnet (100.x) address.
    let egressHopIP: String?
    /// SSH waits for Tailscale: the hop is, or may be via a subnet route, on the tailnet.
    let egressWaitsForTailnet: Bool

    private struct Applied: Equatable {
        var settings: TailnetNetworkSettings
        var excluded: [String]
    }

    private let lock = NSLock()
    private var backendState = ""
    private var latest: TailnetNetworkSettings?
    private var lastApplied: Applied?
    private var applying = true // held until the initial settings are in
    private var pending = false
    private var egressTask: Task<Void, Never>?
    private var egressStatus = "idle"
    private var egressError: String?

    init(provider: SSHVPNTunnelProvider, egress: VPNTunnelConfig?, egressHopIP: String?, egressWaitsForTailnet: Bool) {
        self.provider = provider
        self.egress = egress
        self.egressHopIP = egressHopIP
        self.egressWaitsForTailnet = egressWaitsForTailnet
        super.init()
        Self.currentLock.withLock { Self.current = self }
    }

    /// Keeps the egress hop out of the tunnel, unless a tailnet (subnet)
    /// route reaches it; recomputed whenever Tailscale's routes change.
    var extraExcluded: [String] {
        guard let ip = egressHopIP, !VpntunnelTailscaleRoutesContain(ip) else { return [] }
        return [ip]
    }

    // MARK: Go callback

    func onTailscaleState(_ stateJSON: String?) {
        guard let stateJSON, let data = stateJSON.data(using: .utf8) else { return }
        struct Message: Decodable {
            var state: String
            var registered: Bool?
            var settings: TailnetNetworkSettings?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        Self.logger.info("Tailscale state \(message.state, privacy: .public)")
        VPNConnectionDebugLogger.shared.log("tailscale", "state=\(message.state)")
        #if !os(macOS)
        // Registered: the auth key is spent or unneeded.
        if message.registered == true { TailnetAuthKey.clear() }
        // Widget starts may have stopped polling while Tailscale was still starting.
        if VPNTailnetProfile.recordBackendState(message.state) {
            WidgetCenter.shared.reloadTimelines(ofKind: SSHVPNTunnelProvider.widgetKind)
            #if !os(visionOS)
            ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
            #endif
        }
        #endif
        lock.withLock {
            backendState = message.state
            if let settings = message.settings { latest = settings }
        }
        scheduleApply()
    }

    // MARK: Network settings

    /// Called after the initial settings are applied; releases queued updates.
    func beginApplying(initial: TailnetNetworkSettings, excluded: [String]) {
        let runAgain = lock.withLock { () -> Bool in
            lastApplied = Applied(settings: initial, excluded: excluded)
            if pending { return true }
            applying = false
            return false
        }
        if runAgain {
            Task { await self.applyLoop() }
        }
    }

    private func scheduleApply() {
        let start = lock.withLock { () -> Bool in
            if applying {
                pending = true
                return false
            }
            applying = true
            return true
        }
        if start {
            Task { await self.applyLoop() }
        }
    }

    private func applyLoop() async {
        while true {
            let excluded = extraExcluded // calls into Go: outside our lock
            let target = lock.withLock { () -> Applied? in
                pending = false
                guard let latest else { return nil }
                let target = Applied(settings: latest, excluded: excluded)
                return target != lastApplied ? target : nil
            }
            if let target, let provider {
                do {
                    try await provider.setTunnelNetworkSettings(target.settings.makeSettings(excludingIPv4: target.excluded))
                    lock.withLock { lastApplied = target }
                    Self.logger.info("Tailscale network settings applied (routes=\(target.settings.ipv4Routes?.count ?? 0), full=\(target.settings.fullTunnel), excluded=\(target.excluded.count))")
                } catch {
                    Self.logger.error("Tailscale network settings failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let again = lock.withLock { () -> Bool in
                if pending { return true }
                applying = false
                return false
            }
            if !again { return }
        }
    }

    // MARK: SSH egress

    func startEgress() {
        guard let egress else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runEgress(egress)
        }
        lock.withLock { egressTask = task }
    }

    private func setEgress(_ status: String, error: String? = nil) {
        lock.withLock {
            egressStatus = status
            egressError = error
        }
    }

    /// Waits (up to 5s) until the applied settings match Tailscale's current
    /// routes, so the hop's exclusion is right before SSH dials it.
    private func waitForSettledSettings() async {
        for _ in 0..<50 {
            guard !Task.isCancelled else { return }
            let excluded = extraExcluded
            let settled = lock.withLock {
                !applying && latest.map { Applied(settings: $0, excluded: excluded) } == lastApplied
            }
            if settled { return }
            scheduleApply()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runEgress(_ config: VPNTunnelConfig) async {
        if egressWaitsForTailnet {
            setEgress("waitingForTailnet")
            while !Task.isCancelled, lock.withLock({ backendState }) != "Running" {
                try? await Task.sleep(for: .milliseconds(500))
            }
            await waitForSettledSettings()
        }
        guard !Task.isCancelled, let provider else { return }

        setEgress("connecting")
        let debugLog = VPNConnectionDebugLogger.shared
        debugLog.beginPhase("sshEgress", "Connecting to \(config.sshHost):\(config.sshPort) for Tailscale egress (\(config.transportType.rawValue))...")
        do {
            if config.transportType == .tssh {
                try await provider.attachTailnetTSSHEgress(config: config)
            } else {
                let sshGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                provider.sshStateLock.withLock { provider.sshEventLoopGroup = sshGroup }
                provider.storedConfig = config
                let conn = try await provider.connectSSHWithBootstrapRetry(config: config, group: sshGroup)
                let proxy = provider.sshStateLock.withLock { () -> VPNSOCKS5Proxy? in
                    provider.sshClient = conn.client
                    provider.jumpClient = conn.jumpClient
                    return provider.socksProxy
                }
                proxy?.updateSSHClient(conn.client)
                provider.monitorSSHConnection(conn.client)
            }
            debugLog.endPhase("sshEgress", "OK")
            setEgress("connected")
        } catch is CancellationError {
            setEgress("idle")
        } catch {
            // Tailscale keeps working; only rule-matched traffic is affected.
            debugLog.logError("sshEgress", error)
            Self.logger.error("SSH egress failed: \(error.localizedDescription, privacy: .public)")
            setEgress("failed", error: error.localizedDescription)
        }
    }

    /// Reconnects ran out; the next start retries.
    func egressLost(_ reason: String) {
        setEgress("failed", error: reason)
    }

    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = egressTask
            egressTask = nil
            return t
        }
        task?.cancel()
        Self.currentLock.withLock {
            if Self.current === self { Self.current = nil }
        }
    }

    // MARK: App messages

    /// Handles `tailscale.status`, `tailscale.login` and `tailscale.logout`.
    static func handleMessage(_ message: String) -> Data? {
        var reply: [String: Any] = [:]
        switch message {
        case "tailscale.status":
            let status = VpntunnelTailscaleStatus()
            if let data = status.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                reply = object
            }
            if let session = currentLock.withLock({ current }) {
                let (state, error) = session.lock.withLock { (session.egressStatus, session.egressError) }
                var egress: [String: Any] = ["state": state]
                if let host = session.egress?.sshHost { egress["host"] = host }
                if let error { egress["error"] = error }
                reply["egress"] = egress
            }
        case "tailscale.login":
            var error: NSError?
            if !VpntunnelTailscaleLogin(&error) {
                reply["error"] = error?.localizedDescription ?? "Login failed"
            }
        case "tailscale.logout":
            var error: NSError?
            if !VpntunnelTailscaleLogout(&error) {
                reply["error"] = error?.localizedDescription ?? "Logout failed"
            }
        default:
            reply["error"] = "unknown message"
        }
        return try? JSONSerialization.data(withJSONObject: reply)
    }
}

extension SSHVPNTunnelProvider {
    /// Starts Tailscale mode. Tailscale owns the tunnel; SSH egress, when
    /// configured, connects afterwards so a tailnet egress host is reachable.
    /// Tailscale settings, SSH egress and the auth key: from the app group and
    /// keychain on iOS; on macOS from the host-resolved config, since the root
    /// sysext can't read either.
    static func tailnetInputs(resolved: VPNResolvedTailnet?) throws -> (VPNTailnetSettings, VPNTunnelConfig?, String?) {
        #if os(macOS)
        guard let resolved else { throw VPNError.configNotFound }
        var egress: VPNTunnelConfig?
        if let snapshot = resolved.egress {
            var egressConfig = try VPNTunnelConfig(snapshot: snapshot)
            egressConfig.resolvedCredential = resolved.egressCredential
            egressConfig.jumpResolvedCredential = resolved.egressJumpCredential
            egressConfig.extraJumpResolvedCredentials = resolved.egressExtraJumpCredentials
            egress = egressConfig
        }
        return (resolved.settings, egress, resolved.authKey)
        #else
        let settings = VPNTailnetProfile.settings()
        var egress: VPNTunnelConfig?
        if let snapshot = VPNTailnetProfile.egressSnapshot(settings) {
            var egressConfig = try VPNTunnelConfig(snapshot: snapshot)
            egressConfig.compactChannelWindows = true
            egress = egressConfig
        }
        return (settings, egress, TailnetAuthKey.read())
        #endif
    }

    func startTailnetTunnel(config: VPNTunnelConfig, settings: VPNTailnetSettings, egress: VPNTunnelConfig?, authKey: String?, options: [String: NSObject]?) async throws {
        let debugLog = VPNConnectionDebugLogger.shared
        guard VpntunnelTailscaleSupported() else {
            throw VPNError.unsupportedTransport(config.transportType.rawValue)
        }

        let index = await DirectInterfaceMonitor.shared.start()
        debugLog.logMarker("TAILSCALE bound interface index=\(index) egress=\(egress?.sshHost ?? "none")")

        // Resolve the first SSH hop (the jump host, if any; the target sits
        // behind it) now, while DNS still goes to the physical network. A
        // name that won't resolve here is a MagicDNS name, i.e. on the tailnet.
        // A private address may sit behind a subnet route, known only once
        // Tailscale runs, so SSH waits for it.
        var egressHopIP: String?
        var egressWaitsForTailnet = false
        var rules = settings.rules
        if let egress {
            let firstHop = egress.jumpHostConfig?.host ?? egress.sshHost
            let ip = await resolveHostToIP(firstHop)
            if Self.isIPv4Literal(ip), !Self.isTailnetIPv4(ip) {
                egressHopIP = ip
                egressWaitsForTailnet = settings.acceptRoutes && Self.isPrivateIPv4(ip)
                // Its DNS and traffic must never be routed through itself; a
                // direct rule still yields to tailnet routes in Go.
                if !Self.isIPv4Literal(firstHop) {
                    rules.insert(VPNRoutingRule(pattern: firstHop, action: .direct), at: 0)
                }
                rules.insert(VPNRoutingRule(pattern: ip, action: .direct), at: 0)
            } else {
                egressWaitsForTailnet = true
            }
        }

        // SSH egress: the SOCKS listener comes first so Go knows its address;
        // it refuses connections until the SSH client is attached. TSSH
        // egress attaches straight to Go once tsshd is spawned.
        var socksAddress: String?
        if egress?.transportType == .ssh {
            let socksGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let proxy = VPNSOCKS5Proxy(sshClient: nil, eventLoopGroup: socksGroup, maxConnections: 64)
            sshStateLock.withLock {
                socksEventLoopGroup = socksGroup
                socksProxy = proxy
            }
            do {
                let port = try await proxy.start()
                sshProxyPort = port
                socksAddress = "127.0.0.1:\(port)"
            } catch {
                await cleanupSSH()
                throw error
            }
        }

        let session = TailnetSession(provider: self, egress: egress, egressHopIP: egressHopIP, egressWaitsForTailnet: egressWaitsForTailnet)
        runningStateLock.withLock { tailnetSession = session }

        debugLog.beginPhase("goTailscale", "Starting Tailscale...")
        // A capture that was recording resumes; Go reroutes only while it records.
        let json = CaptureBridge.attach(
            CaptureBridge.initialConfig(options: options),
            to: try Self.tailnetGoConfigJSON(settings: settings, authKey: authKey, rules: rules, socksAddress: socksAddress,
                                             tsshEgress: egress?.transportType == .tssh)
        )
        var startError: NSError?
        #if os(macOS)
        let store: VpntunnelTailscaleStateStoreProtocol = TailnetFileStateStore()
        #else
        let store: VpntunnelTailscaleStateStoreProtocol = TailnetKeychainStateStore()
        VPNTailnetProfile.recordBackendState("") // this session hasn't reported yet
        #endif
        let started = VpntunnelStartTailscaleTunnel(json, store, session, TunnelCallbackImpl(provider: self), &startError)
        guard started else {
            session.stop()
            await cleanupSSH()
            let error = startError ?? NSError(domain: "Tailscale", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to start Tailscale."])
            debugLog.logError("goTailscale", error)
            throw error
        }
        if runningStateLock.withLock({ stopRequested }) {
            session.stop()
            VpntunnelStopTunnel(nil)
            await cleanupSSH()
            throw CancellationError()
        }
        debugLog.endPhase("goTailscale", "OK")
        #if !os(macOS)
        VPNTailnetProfile.storeApplied(settings) // the Mac app records it itself
        #endif

        // Placeholder until logged in; updates arrive through the session.
        guard let initial = TailnetNetworkSettings.decode(VpntunnelTailscaleNetworkSettings()) else {
            throw VPNError.netstackFailed("Tailscale returned no network settings")
        }
        debugLog.beginPhase("tunnelSettings", "Applying Tailscale network settings...")
        let initialExcluded = session.extraExcluded
        try await setTunnelNetworkSettings(initial.makeSettings(excludingIPv4: initialExcluded))
        debugLog.endPhase("tunnelSettings", "OK")
        session.beginApplying(initial: initial, excluded: initialExcluded)

        let recorder = VPNTrafficRecorder()
        recorder.start()
        runningStateLock.withLock {
            runningState = true
            tunnelStartDate = Date()
            trafficRecorder = recorder
            tunMTU = initial.mtu
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
        #if !os(macOS)
        VPNLastConnected.record(config.profileID)
        VPNAutoRecovery.markRunning(config.profileID)
        #endif
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif

        startPacketForwarding()
        session.startEgress()
        debugLog.logMarker("VPN CONNECT COMPLETE: tailscale total=\(debugLog.sessionElapsedMs())ms")
    }

    /// Spawns tsshd on the egress host (reusing the TSSH VPN's path) and hands
    /// the connection to Go; the SSH spawn connection then closes, as in TSSH mode.
    func attachTailnetTSSHEgress(config: VPNTunnelConfig) async throws {
        let json = try await startTSSHTransport(config: config)
        let relay = sshStateLock.withLock { preparedRelay }
        var attachError: NSError?
        let attached = VpntunnelTailscaleAttachTSSH(json, relay, &attachError)
        if attached {
            sshStateLock.withLock { preparedRelay = nil } // Go owns it now
        } else {
            closePreparedRelay()
        }
        await cleanupSSH()
        if !attached {
            throw attachError ?? NSError(domain: "TSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to connect to tsshd."])
        }
    }

    private static func tailnetGoConfigJSON(settings: VPNTailnetSettings, authKey: String?, rules: [VPNRoutingRule], socksAddress: String?, tsshEgress: Bool) throws -> String {
        struct Rule: Encodable {
            let pattern: String
            let action: String
        }
        struct Routing: Encodable {
            let sendAllViaSSH: Bool
            let rules: [Rule]
        }
        struct Tailscale: Encodable {
            let hostname: String?
            let acceptRoutes: Bool
            let controlURL: String?
            let authKey: String?
            let stateDir: String
            let egress: String?
        }
        struct GoConfig: Encodable {
            let transportType = "tailscale"
            let socks5Address: String?
            let dnsServers: [String]?
            let tailscale: Tailscale
            let routing: Routing
        }
        guard let controlURL = settings.normalizedControlURL else { throw VPNError.invalidControlURL }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let config = GoConfig(
            socks5Address: socksAddress,
            dnsServers: settings.dnsServers.isEmpty ? nil : settings.dnsServers,
            tailscale: Tailscale(
                hostname: settings.hostname.isEmpty ? nil : settings.hostname,
                acceptRoutes: settings.acceptRoutes,
                controlURL: controlURL.isEmpty ? nil : controlURL,
                authKey: authKey,
                stateDir: caches.appendingPathComponent("tailscale").path,
                egress: tsshEgress ? "tssh" : nil
            ),
            routing: Routing(
                sendAllViaSSH: settings.sendAllViaSSH,
                rules: rules.map { Rule(pattern: $0.pattern, action: $0.action.rawValue) }
            )
        )
        guard let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) else {
            throw VPNError.configSerializationFailed
        }
        return json
    }

    private static func isIPv4Literal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// 100.64.0.0/10, Tailscale's CGNAT range.
    private static func isTailnetIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (parts[1] & 0xC0) == 64
    }

    /// RFC 1918: the ranges subnet routers usually advertise.
    private static func isPrivateIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (parts[1] & 0xF0) == 16)
            || (parts[0] == 192 && parts[1] == 168)
    }
}
