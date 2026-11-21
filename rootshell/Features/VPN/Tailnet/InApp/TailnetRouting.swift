//
//  TailnetRouting.swift
//  rootshell
//
//  What the dial paths need to know about the in-app Tailscale engine,
//  readable from any thread, and the dialer that hands them tailnet sockets.
//

#if !CHINA_BUILD

import Foundation
import NIOCore
import NIOPosix
import os

nonisolated final class TailnetRouting: Sendable {
    static let shared = TailnetRouting()

    struct State: Sendable {
        /// The mode is rootshell Only (whether or not it is turned on).
        var rootshellOnly = false
        /// rootshell Only is turned on.
        var enabled = false
        var onDemand = true
        var exitNode = false
        var exitNodeAllowLAN = false
        /// MagicDNS suffix and peer names from the last netmap, so on-demand
        /// starts recognise short names before the engine runs.
        var suffix: String?
        var peerNames: Set<String> = []
        /// Hosts recently dialed over the tailnet, for Connection Info.
        var routedHosts: Set<String> = []
        /// ALL_PROXY / NO_PROXY for the local shell, nil when unused.
        var shellProxyEnvironment: [String: String]?
    }

    /// Seeded from saved settings, so connections restored at launch route
    /// correctly before the app's startup work runs.
    private let lock = OSAllocatedUnfairLock(initialState: TailnetRouting.savedState())

    static func savedState() -> State {
        let mode = TailnetModeSettings.load()
        var state = State()
        apply(mode, to: &state)
        if let cache = loadPeerCache() {
            state.suffix = cache.suffix
            state.peerNames = Set(cache.names)
        }
        return state
    }

    static func apply(_ mode: TailnetModeSettings, to state: inout State) {
        state.rootshellOnly = mode.effectiveMode == .rootshellOnly
        state.enabled = state.rootshellOnly && mode.inAppEnabled
        state.onDemand = mode.connectOnDemand
        state.exitNode = mode.exitNodeID?.isEmpty == false
        state.exitNodeAllowLAN = mode.exitNodeAllowLAN
    }

    // MARK: - Peer cache

    struct PeerCache: Codable, Sendable {
        var suffix: String?
        var names: [String]
    }

    private static var peerCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailnet-peers.json")
    }

    static func loadPeerCache() -> PeerCache? {
        guard let url = peerCacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PeerCache.self, from: data)
    }

    func storePeers(suffix: String?, names: Set<String>) {
        update { state in
            state.suffix = suffix
            state.peerNames = names
        }
        guard let url = Self.peerCacheURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(PeerCache(suffix: suffix, names: names.sorted())).write(to: url, options: .atomic)
    }

    var state: State { lock.withLock { $0 } }

    func update(_ body: @Sendable (inout State) -> Void) {
        lock.withLock { body(&$0) }
    }

    func noteRouted(_ host: String) {
        let key = Self.normalize(host)
        lock.withLock { _ = $0.routedHosts.insert(key) }
    }

    func wasRouted(_ host: String) -> Bool {
        let key = Self.normalize(host)
        return lock.withLock { $0.routedHosts.contains(key) }
    }

    static func normalize(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// A tailnet address or name, judged without the engine: 100.64/10,
    /// Tailscale's IPv6 range, *.ts.net, the MagicDNS suffix or a known peer.
    func looksLikeTailnet(_ host: String) -> Bool {
        let name = Self.normalize(host)
        if Self.isTailscaleIP(name) { return true }
        if name.hasSuffix(".ts.net") { return true }
        let state = state
        if let suffix = state.suffix, !suffix.isEmpty, name.hasSuffix("." + suffix) { return true }
        return state.peerNames.contains(name)
    }

    /// Whether reaching host requires the in-app engine (regardless of
    /// connect-on-demand). With an exit node every remote host goes through
    /// the tailnet.
    func requiresEngine(for host: String) -> Bool {
        let state = state
        guard state.enabled else { return false }
        if looksLikeTailnet(host) || wasRouted(host) { return true }
        return state.exitNode && !Self.isLocal(Self.normalize(host), allowLAN: state.exitNodeAllowLAN)
    }

    /// Whether a connection to host should start the engine on demand. With
    /// an exit node every remote host goes through the tailnet.
    func wantsEngine(for host: String) -> Bool {
        guard state.onDemand else { return false }
        return requiresEngine(for: host)
    }

    /// Whether launch should pre-warm the engine for a set of restored hosts,
    /// overlapping control-plane login with window/PTY setup.
    func shouldPrewarm(forHosts hosts: [String]) -> Bool {
        let state = state
        guard state.enabled else { return false }
        if !state.onDemand { return true }
        return hosts.contains { requiresEngine(for: $0) }
    }

    private enum ParsedIP {
        case v4(UInt8, UInt8, UInt8, UInt8)
        case v6([UInt8])
    }

    private static func parseIP(_ host: String) -> ParsedIP? {
        let stripped = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var addr4 = in_addr()
        if inet_pton(AF_INET, stripped, &addr4) == 1 {
            return withUnsafeBytes(of: &addr4) { raw in
                .v4(raw[0], raw[1], raw[2], raw[3])
            }
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, stripped, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            // Unmap ::ffff:a.b.c.d to match Go's netip.Addr.Unmap().
            if bytes.count == 16,
               bytes[0..<10].allSatisfy({ $0 == 0 }),
               bytes[10] == 0xff, bytes[11] == 0xff {
                return .v4(bytes[12], bytes[13], bytes[14], bytes[15])
            }
            return .v6(bytes)
        }
        return nil
    }

    private static func isTailscaleV6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16
            && bytes[0] == 0xfd && bytes[1] == 0x7a
            && bytes[2] == 0x11 && bytes[3] == 0x5c
            && bytes[4] == 0xa1 && bytes[5] == 0xe0
    }

    static func isIPAddress(_ host: String) -> Bool {
        parseIP(normalize(host)) != nil
    }

    static func isTailscaleIP(_ host: String) -> Bool {
        guard let ip = parseIP(normalize(host)) else { return false }
        switch ip {
        case .v4(let b0, let b1, _, _):
            return b0 == 100 && (64...127).contains(b1)
        case .v6(let bytes):
            return isTailscaleV6(bytes)
        }
    }

    /// Matches Go's `inAppTailnet.routes(ip)`: loopback, unspecified,
    /// link-local unicast, and multicast are always local; private IPv4
    /// (RFC 1918) and private IPv6 ULA (fc00::/7, excluding Tailscale's
    /// fd7a:115c:a1e0::/48) are local when `allowLAN` is true.
    static func isLocal(_ host: String, allowLAN: Bool) -> Bool {
        let norm = normalize(host)
        if norm == "localhost" || norm.hasSuffix(".local") { return true }
        guard let ip = parseIP(norm) else { return false }
        switch ip {
        case .v4(let b0, let b1, let b2, let b3):
            if b0 == 127
                || (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0)
                || (b0 == 169 && b1 == 254)
                || (b0 & 0xf0) == 224 {
                return true
            }
            guard allowLAN else { return false }
            return b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            let zeroPrefix = bytes[0..<15].allSatisfy { $0 == 0 }
            if zeroPrefix && (bytes[15] == 0 || bytes[15] == 1) { return true }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
            if bytes[0] == 0xff { return true }
            guard allowLAN else { return false }
            return (bytes[0] & 0xfe) == 0xfc && !isTailscaleV6(bytes)
        }
    }
}

/// Shown when a tailnet host can't be reached because rootshell Only is off
/// or signed out.
nonisolated struct TailnetOffError: LocalizedError {
    var underlying: String?

    var errorDescription: String? {
        let hint = String(
            localized: "Tailscale (rootshell only) is off. Turn it on in Settings › VPN › Tailscale.",
            comment: "Connection error for a tailnet host while in-app Tailscale is off"
        )
        guard let underlying, !underlying.isEmpty else { return hint }
        return "\(underlying)\n\n\(hint)"
    }
}

nonisolated enum TailnetDialer {
    /// The tailnet address host is reached at in-app, or nil for the OS.
    /// Starts the engine on demand.
    static func route(_ host: String) async -> String? {
        let routing = TailnetRouting.shared
        let state = routing.state
        guard state.enabled else { return nil }
        if !TailnetGo.isRunning {
            var wanted = routing.requiresEngine(for: host)
            // A name the OS can't resolve may be a MagicDNS name not cached yet.
            if !wanted, isName(host), await !osResolves(host) {
                wanted = true
            }
            guard wanted else { return nil }
            logger.info("Starting in-app Tailscale on demand for \(host, privacy: .public)")
            guard await TailnetInAppEngine.shared.ensureRunning() else {
                logger.error("In-app Tailscale didn't come up for \(host, privacy: .public)")
                return nil
            }
        }
        guard let ip = await TailnetGo.resolve(host) else { return nil }
        logger.info("\(host, privacy: .public) routes over in-app Tailscale (\(ip, privacy: .public))")
        routing.noteRouted(host)
        routing.noteRouted(ip)
        return ip
    }

    /// Whether falling back to an OS dial for `host` after `route(_:)` returned
    /// nil must be refused — e.g. a tailnet target, or a non-local destination
    /// while an exit node is selected (including when Tailscale is Running
    /// without a route through the exit node).
    static func blocksDirectFallback(for host: String) async -> Bool {
        let routing = TailnetRouting.shared
        let state = routing.state
        guard routing.requiresEngine(for: host) else { return false }
        if !TailnetGo.isRunning
            || routing.looksLikeTailnet(host)
            || routing.wasRouted(host)
            || !state.exitNodeAllowLAN
            || TailnetRouting.isIPAddress(host) {
            return true
        }
        // Hostname with exitNodeAllowLAN enabled while Tailscale is Running:
        // permit direct fallback only if OS DNS resolves it exclusively to
        // local/LAN addresses.
        return await !osResolvesOnlyLocal(host, allowLAN: true)
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetRouting")

    private static func isName(_ host: String) -> Bool {
        let name = TailnetRouting.normalize(host)
        return !name.isEmpty && !TailnetRouting.isIPAddress(name)
    }

    /// Whether the system resolver resolves `host` to at least one address and
    /// every returned address is local/LAN (fail-closed on timeout/error).
    private static func osResolvesOnlyLocal(_ host: String, allowLAN: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { result in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                defer { if let result { freeaddrinfo(result) } }
                guard status == 0, var ptr = result else {
                    finish(false)
                    return
                }
                var sawAddress = false
                while true {
                    let info = ptr.pointee
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if let addr = info.ai_addr,
                       getnameinfo(addr, info.ai_addrlen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostBuf)
                        sawAddress = true
                        if !TailnetRouting.isLocal(ip, allowLAN: allowLAN) {
                            finish(false)
                            return
                        }
                    }
                    guard let next = info.ai_next else { break }
                    ptr = next
                }
                finish(sawAddress)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }

    /// Whether the system resolver knows host, waiting at most two seconds.
    private static func osResolves(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { result in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                finish(status == 0)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(true) }
        }
    }

    /// A connected Channel over the tailnet when host belongs to it, else nil.
    /// autoRead stays off, like MPTCPBootstrap, until Citadel installs its handlers.
    static func channel(host: String, port: Int, timeout: TimeAmount) async throws -> Channel? {
        guard let ip = await route(host) else { return nil }
        let fd = try await TailnetGo.dialTCP(host: ip, port: port, timeout: .nanoseconds(timeout.nanoseconds))
        do {
            return try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.autoRead, value: false)
                .takingOwnershipOfDescriptor(inputOutput: fd)
                .get()
        } catch {
            close(fd)
            throw error
        }
    }

    /// Adds the turn-it-on hint when a tailnet host failed through the OS
    /// while rootshell Only is the mode but isn't running.
    static func explain(_ error: Error, host: String) -> Error {
        let routing = TailnetRouting.shared
        guard routing.state.rootshellOnly, !TailnetGo.isRunning, routing.looksLikeTailnet(host) else { return error }
        return TailnetOffError(underlying: error.localizedDescription)
    }
}

#endif
