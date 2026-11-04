#if !targetEnvironment(macCatalyst)

import Foundation
import Darwin
import OSLog
import Combine

// IPv6 socket option constants not exposed to Swift on iOS
private let kIPV6_RECVHOPLIMIT: Int32 = 37       // IPV6_RECVHOPLIMIT - enable hop limit in ancillary data
private let kIPV6_2292HOPLIMIT: Int32 = 20        // Legacy cmsg_type for hop limit
private let kIPV6_HOPLIMIT: Int32 = 47            // Modern cmsg_type for hop limit (3542)
private let kSCM_TIMESTAMP: Int32 = 2             // SCM_TIMESTAMP - recv timestamp (timeval)

/// Native Swift ping implementation using ICMP DGRAM sockets.
/// Each instance is fully self-contained with no global state,
/// enabling concurrent multi-tab ping without conflicts.
@MainActor
final class PingCommand {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "ping")

    /// Atomic identifier counter for unique ICMP identifiers per instance
    private static let identifierLock = UnfairLock()
    private nonisolated(unsafe) static var nextIdentifier: UInt16 = 1

    private static func allocateIdentifier() -> UInt16 {
        identifierLock.withLock {
            let id = nextIdentifier
            nextIdentifier &+= 1
            return id
        }
    }

    let config: PingCommandParser.PingConfig
    let output: (String) -> Void
    var onComplete: (() -> Void)?
    private(set) var didFail = false

    private var task: Task<Void, Never>?
    private var socketFD: Int32 = -1
    private let identifier: UInt16
    private var kernelIdentifier: UInt16?
    private var connected = false
    private var stats = PingStatistics()

    // Duplicate detection bitmap (8192 bits = 1024 bytes)
    private static let bitmapSize = 8192
    private var receivedBitmap = [UInt8](repeating: 0, count: 8192 / 8)
    private static let payloadNonceSize = MemoryLayout<UInt64>.size
    private static let payloadTimestampSize = MemoryLayout<timeval>.size
    private static let maxPacketPayloadSize = 65_500
    private let payloadNonce: UInt64

    // Resolved target address info
    private var resolvedIP: String = ""
    private var resolvedHostname: String = ""
    private var expectedSourceAddress: sockaddr_storage?

    // Reverse DNS cache (ip → hostname, or ip → ip after failure) to
    // avoid repeated blocking lookups.
    private var dnsCache: [String: String] = [:]

    // Socket-reset machinery: invalidation can come from kernel-reported
    // revents/errno or from NWPathMonitor/foreground notifications.
    private var cancellables = Set<AnyCancellable>()
    private var pendingSocketReset = false
    private var lastResetTime: CFAbsoluteTime = 0
    private var consecutiveResetFailures = 0
    private let minResetInterval: TimeInterval = 1.0
    private var savedAddrInfo: UnsafeMutablePointer<addrinfo>?

    init(config: PingCommandParser.PingConfig, output: @escaping (String) -> Void) {
        self.config = config
        self.output = output
        self.identifier = Self.allocateIdentifier()
        self.payloadNonce = UInt64.random(in: UInt64.min...UInt64.max)
    }

    /// Start the ping operation
    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    /// Cancel the ping and print summary
    func cancel() {
        task?.cancel()
        task = nil

        output("^C\r\n")
        printSummary()
        cleanup()
        onComplete?()
    }

    // MARK: - Main Run Loop

    private func run() async {
        #if !CHINA_BUILD
        if let ip = await TailnetDialer.route(config.target) {
            await runTailnet(ip: ip)
            return
        }
        #endif
        // Resolve hostname. Ownership of the returned addrinfo pointer is
        // transferred to self.savedAddrInfo; cleanup() frees it. This lets
        // recreateSocket() rebind to the originally-resolved IP without
        // re-resolving DNS (matches BSD ping semantics).
        guard let addrInfo = await resolveHost(config.target, family: config.addressFamily) else {
            didFail = true
            output("ping: cannot resolve \(config.target): Unknown host\r\n")
            onComplete?()
            return
        }

        // Ownership of addrInfo stays local until we successfully create
        // the socket. Any early-return before that point must freeaddrinfo
        // itself. Once committed to `savedAddrInfo`, cleanup() owns it.
        guard !Task.isCancelled else {
            freeaddrinfo(addrInfo)
            return
        }

        resolvedIP = extractIPAddress(addrInfo)
        resolvedHostname = config.target
        expectedSourceAddress = extractExpectedSourceAddress(addrInfo)

        // Create socket
        let isIPv6 = config.addressFamily == .ipv6
        let proto = isIPv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, proto)

        guard socketFD >= 0 else {
            let err = String(cString: strerror(errno))
            didFail = true
            output("ping: socket: \(err)\r\n")
            freeaddrinfo(addrInfo)
            onComplete?()
            return
        }

        savedAddrInfo = addrInfo

        // Switch to non-blocking I/O. Without this, sendto() can park the
        // MainActor in the kernel during network transitions (Wi-Fi drop,
        // cellular handoff, VPN toggle) — freezing the UI and blocking
        // Ctrl-C. With O_NONBLOCK, sendto/recvmsg return EAGAIN and the
        // poll()-based loop stays responsive.
        applyNonBlocking(to: socketFD)

        configureSocket()

        // Connect socket if requested (filters received packets to target)
        if config.appleConnect {
            let rc = Darwin.connect(socketFD, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
            if rc == 0 {
                connected = true
            } else {
                let err = String(cString: strerror(errno))
                didFail = true
                output("ping: connect: \(err)\r\n")
            }
        }

        installReconnectTriggers()

        // Print header
        let dataSize = config.packetSize
        output("PING \(config.target) (\(resolvedIP)): \(dataSize) data bytes\r\n")

        // Send preload packets
        var seq: UInt16 = 0
        for _ in 0..<config.preload {
            let packetSize = currentPacketSize(seq: seq)
            sendPing(seq: seq, addrInfo: addrInfo, packetSize: packetSize)
            stats.transmitted += 1
            seq &+= 1
        }

        // Learn the kernel-assigned identifier after the first sendto()
        // (the kernel may not bind the socket until the first send)
        if kernelIdentifier == nil && stats.transmitted > 0 {
            learnKernelIdentifier()
        }

        // Main ping loop
        let startTime = CFAbsoluteTimeGetCurrent()

        while !Task.isCancelled {
            if pendingSocketReset {
                recreateSocket(reason: "path change or kernel-reported invalidation")
            }

            // Check count limit
            if let count = config.count, stats.transmitted >= count {
                break
            }

            // Check overall timeout
            if let timeout = config.timeout {
                if CFAbsoluteTimeGetCurrent() - startTime >= timeout {
                    break
                }
            }

            let cycleStart = CFAbsoluteTimeGetCurrent()
            let packetSize = currentPacketSize(seq: seq)
            sendPing(seq: seq, addrInfo: addrInfo, packetSize: packetSize)
            stats.transmitted += 1

            if kernelIdentifier == nil {
                learnKernelIdentifier()
            }

            // After the last packet, wait the full -W time for late replies.
            // Otherwise keep packet cadence tied to `-i`.
            let isLastPacket = config.count.map { stats.transmitted >= $0 } ?? false
            var receiveWait = isLastPacket ? config.waitTime : min(config.waitTime, config.interval)

            // Cap by remaining overall timeout (-t) so we don't overshoot
            if let timeout = config.timeout {
                let remaining = timeout - (CFAbsoluteTimeGetCurrent() - startTime)
                if remaining <= 0 { break }
                receiveWait = min(receiveWait, remaining)
            }

            let replies = await receivePings(waitTime: receiveWait)
            if Task.isCancelled { break }

            var shouldExit = false

            for reply in replies {
                let isDup = markReceived(seq: reply.seq)

                if isDup {
                    stats.duplicates += 1
                } else {
                    stats.received += 1
                    stats.addRTT(reply.rtt)
                }

                if !config.quiet && !config.quieter {
                    let dupStr = isDup ? " (DUP!)" : ""
                    let ttlStr = reply.ttl > 0 ? " ttl=\(reply.ttl)" : ""
                    let isIPv6Label = isIPv6 ? "icmp6_seq" : "icmp_seq"
                    let fromStr: String
                    if let hostname = reply.fromHostname {
                        fromStr = "\(hostname) (\(reply.from))"
                    } else {
                        fromStr = reply.from
                    }
                    output("\(timestampPrefix())\(reply.bytes) bytes from \(fromStr): \(isIPv6Label)=\(reply.seq)\(ttlStr) time=\(formatRTT(reply.rtt)) ms\(dupStr)\r\n")

                    // Record Route display
                    if let hops = reply.recordRoute, !hops.isEmpty {
                        output("RR:")
                        for hop in hops {
                            output("\t\(hop)\r\n")
                        }
                    }
                }

                if config.exitOnFirstReply {
                    shouldExit = true
                    break
                }
            }

            if shouldExit {
                break
            }

            // Advance sequence per transmitted probe (one send per cycle),
            // independent of how many queued replies were drained this interval.
            seq &+= 1

            // Sleep for interval (check cancellation in small increments)
            let elapsed = CFAbsoluteTimeGetCurrent() - cycleStart
            let remaining = max(0, config.interval - elapsed)
            let sleepEnd = CFAbsoluteTimeGetCurrent() + remaining
            while !Task.isCancelled && CFAbsoluteTimeGetCurrent() < sleepEnd {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms increments
            }
        }

        if !Task.isCancelled {
            printSummary()
            onComplete?()
        }
        cleanup()
    }

    // MARK: - Socket Lifecycle

    private func applyNonBlocking(to fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            let rc = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if rc < 0 {
                let err = errno
                Self.logger.error("fcntl F_SETFL O_NONBLOCK failed: errno=\(err)")
            }
        } else {
            let err = errno
            Self.logger.error("fcntl F_GETFL failed: errno=\(err)")
        }
    }

    /// Subscribe to signals that the underlying network path has changed and
    /// the ICMP socket's route may be invalid. `NWPathMonitor` already
    /// re-evaluates on foreground transitions and emits a consolidated
    /// update when the path differs post-suspend, so we don't need a
    /// separate `didBecomeActive` subscriber — that would trigger a spurious
    /// reset on every app-switch even when nothing changed. Genuinely-dead
    /// sockets missed by NWPath are still caught by `sendto` errno and
    /// `poll` revents.
    private func installReconnectTriggers() {
        NetworkReachabilityMonitor.shared.networkPathUpdated
            .sink { [weak self] in self?.pendingSocketReset = true }
            .store(in: &cancellables)

        NetworkReachabilityMonitor.shared.connectivityRestored
            .sink { [weak self] in self?.pendingSocketReset = true }
            .store(in: &cancellables)
    }

    /// Rebuild the ICMP socket in-place when the kernel reports invalidation
    /// or a network path change has occurred. Rate-limited to once per
    /// `minResetInterval` to avoid thrashing under flapping networks.
    private func recreateSocket(reason: String) {
        // Check the rate limiter first and keep `pendingSocketReset` armed
        // when throttled — otherwise a sub-second ping interval could drop
        // the pending signal before the cooldown elapses, wedging the
        // session on a dead socket until some other event re-arms the flag.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastResetTime < minResetInterval {
            Self.logger.debug("recreateSocket suppressed by rate limiter (reason=\(reason))")
            return
        }
        lastResetTime = now
        pendingSocketReset = false

        guard let savedAddrInfo else {
            Self.logger.error("recreateSocket called with no savedAddrInfo")
            return
        }

        let oldFD = socketFD
        if oldFD >= 0 {
            close(oldFD)
        }
        socketFD = -1
        connected = false
        kernelIdentifier = nil

        let isIPv6 = config.addressFamily == .ipv6
        let proto = isIPv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        let newFD = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, proto)
        guard newFD >= 0 else {
            let err = String(cString: strerror(errno))
            Self.logger.error("recreateSocket: socket() failed (reason=\(reason)): \(err)")
            consecutiveResetFailures += 1
            if consecutiveResetFailures == 3 {
                output("ping: cannot recreate socket: \(err)\r\n")
            }
            // Re-arm so the next loop iteration retries. The rate limiter
            // plus the per-cycle sleep throttle this to ~1 attempt/sec.
            pendingSocketReset = true
            return
        }

        socketFD = newFD
        applyNonBlocking(to: newFD)
        configureSocket(silentUserErrors: true)

        if config.appleConnect {
            let rc = Darwin.connect(newFD, savedAddrInfo.pointee.ai_addr, savedAddrInfo.pointee.ai_addrlen)
            if rc == 0 {
                connected = true
            } else {
                let err = String(cString: strerror(errno))
                Self.logger.error("recreateSocket: connect() failed (reason=\(reason)): \(err)")
                // Keep the socket anyway — unconnected sendto() still works.
            }
        }

        consecutiveResetFailures = 0
        Self.logger.info("recreateSocket succeeded (reason=\(reason)), new fd=\(newFD)")
    }

    // MARK: - Socket Configuration

    /// When `silentUserErrors` is true, setsockopt/bind failures are
    /// logged to os.log only — avoids spamming the user's terminal on
    /// every reset of a flapping network.
    private func configureSocket(silentUserErrors: Bool = false) {
        let isIPv6 = config.addressFamily == .ipv6

        // Enable ancillary data for hop limit/TTL and kernel receive timestamp.
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_TIMESTAMP, &on, socklen_t(MemoryLayout<Int32>.size))
        if isIPv6 {
            setsockopt(socketFD, IPPROTO_IPV6, kIPV6_RECVHOPLIMIT, &on, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        // Set TTL if specified
        if let ttl = config.ttl {
            var ttlVal = Int32(ttl)
            if isIPv6 {
                setsockopt(socketFD, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(socketFD, IPPROTO_IP, IP_TTL, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        // Don't fragment (IPv4 only)
        if config.dontFragment && !isIPv6 {
            var val: Int32 = 1
            setsockopt(socketFD, IPPROTO_IP, IP_DONTFRAG, &val, socklen_t(MemoryLayout<Int32>.size))
        }

        // Bind to interface
        if let iface = config.boundInterface {
            iface.withCString { name in
                var idx = if_nametoindex(name)
                if idx > 0 {
                    if isIPv6 {
                        setsockopt(socketFD, IPPROTO_IPV6, IPV6_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
                    } else {
                        setsockopt(socketFD, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
                    }
                }
            }
        }

        // Traffic class
        if let tc = config.trafficClass {
            var val = Int32(clamping: tc)
            if isIPv6 {
                setsockopt(socketFD, IPPROTO_IPV6, IPV6_TCLASS, &val, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(socketFD, IPPROTO_IP, IP_TOS, &val, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        // SO_DEBUG
        if config.soDebug {
            var val: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_DEBUG, &val, socklen_t(MemoryLayout<Int32>.size))
        }

        // SO_DONTROUTE
        if config.soDontRoute {
            var val: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_DONTROUTE, &val, socklen_t(MemoryLayout<Int32>.size))
        }

        // Record Route (IPv4 only)
        if config.recordRoute && !isIPv6 {
            // IP option: NOP(1), RR(7), length(39), pointer(4), 36 zero bytes for 9 hops
            var opts = [UInt8](repeating: 0, count: 40)
            opts[0] = 1   // IPOPT_NOP — alignment padding
            opts[1] = 7   // IPOPT_RR
            opts[2] = 39  // option length (type + len + pointer + 9×4 addresses)
            opts[3] = 4   // pointer (1-based, first slot)
            let rc = opts.withUnsafeBytes { bufPtr -> Int32 in
                guard let baseAddress = bufPtr.baseAddress else {
                    return -1
                }
                return setsockopt(socketFD, IPPROTO_IP, IP_OPTIONS, baseAddress, socklen_t(bufPtr.count))
            }
            if rc < 0 {
                let err = String(cString: strerror(errno))
                Self.logger.error("setsockopt IP_OPTIONS failed: \(err)")
                if !silentUserErrors {
                    output("ping: setsockopt IP_OPTIONS: \(err)\r\n")
                }
            }
        }

        // Bind to source address
        if let srcAddr = config.sourceAddress {
            bindToSource(srcAddr, isIPv6: isIPv6, silentUserErrors: silentUserErrors)
        }
    }

    private func bindToSource(_ address: String, isIPv6: Bool, silentUserErrors: Bool) {
        if isIPv6 {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            let parseResult = address.withCString { cstr in
                inet_pton(AF_INET6, cstr, &addr6.sin6_addr)
            }
            guard parseResult == 1 else {
                Self.logger.error("invalid source address: \(address)")
                if !silentUserErrors {
                    output("ping: invalid source address \(address)\r\n")
                }
                return
            }
            let bindResult = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bindResult != 0 {
                let err = String(cString: strerror(errno))
                Self.logger.error("bind(IPv6 source) failed: \(err)")
                if !silentUserErrors {
                    output("ping: bind: \(err)\r\n")
                }
            }
        } else {
            var addr4 = sockaddr_in()
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr4.sin_family = sa_family_t(AF_INET)
            let parseResult = address.withCString { cstr in
                inet_pton(AF_INET, cstr, &addr4.sin_addr)
            }
            guard parseResult == 1 else {
                Self.logger.error("invalid source address: \(address)")
                if !silentUserErrors {
                    output("ping: invalid source address \(address)\r\n")
                }
                return
            }
            let bindResult = withUnsafePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult != 0 {
                let err = String(cString: strerror(errno))
                Self.logger.error("bind(IPv4 source) failed: \(err)")
                if !silentUserErrors {
                    output("ping: bind: \(err)\r\n")
                }
            }
        }
    }

    /// Learn the kernel-assigned ICMP identifier by reading the local port
    /// from getsockname(). On Apple platforms, the kernel rewrites the ICMP
    /// identifier to match the socket's local port, and does NOT filter
    /// replies per-socket — so we must filter manually.
    private func learnKernelIdentifier() {
        let isIPv6 = config.addressFamily == .ipv6
        if isIPv6 {
            var addr6 = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(socketFD, sockPtr, &len)
                }
            }
            if result == 0 {
                let id = UInt16(bigEndian: addr6.sin6_port)
                if id != 0 {
                    kernelIdentifier = id
                    Self.logger.debug("Learned kernel ICMP identifier (IPv6): \(id)")
                }
            }
        } else {
            var addr4 = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(socketFD, sockPtr, &len)
                }
            }
            if result == 0 {
                let id = UInt16(bigEndian: addr4.sin_port)
                if id != 0 {
                    kernelIdentifier = id
                    Self.logger.debug("Learned kernel ICMP identifier (IPv4): \(id)")
                }
            }
        }
    }

    // MARK: - DNS Resolution

    private func resolveHost(_ host: String, family: PingCommandParser.PingConfig.AddressFamily) async -> UnsafeMutablePointer<addrinfo>? {
        let targetHost = host
        let aiFamily: Int32 = family == .ipv6 ? AF_INET6 : AF_INET

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = aiFamily
                hints.ai_socktype = SOCK_DGRAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(targetHost, nil, &hints, &result)

                if status != 0 {
                    PingCommand.logger.error("getaddrinfo failed for \(targetHost): \(String(cString: gai_strerror(status)))")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: result)
            }
        }
    }

    private func extractIPAddress(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let rawAddress = addrInfo.pointee.ai_addr else { return "" }

        if addrInfo.pointee.ai_family == AF_INET6 {
            guard addrInfo.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in6>.size) else {
                return ""
            }
            var addr6 = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in6.self).pointee
            guard inet_ntop(AF_INET6, &addr6.sin6_addr, &ipStr, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return ""
            }
        } else {
            guard addrInfo.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) else {
                return ""
            }
            var addr4 = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in.self).pointee
            guard inet_ntop(AF_INET, &addr4.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return ""
            }
        }

        return String(cString: ipStr)
    }

    // MARK: - ICMP Packet Construction

    /// Attempts to send one ICMP echo request. Callers unconditionally
    /// increment `stats.transmitted` (matches BSD ping: an attempt is
    /// counted even if `sendto` fails, so -c termination and loss stats
    /// reflect intent). Transient failures (EAGAIN/EWOULDBLOCK/EINTR) are
    /// logged at debug level; fatal failures emit a user-visible line and
    /// flag `pendingSocketReset` for route-invalidation errnos.
    private func sendPing(seq: UInt16, addrInfo: UnsafeMutablePointer<addrinfo>, packetSize: Int) {
        guard socketFD >= 0 else { return }
        guard packetSize >= 0, packetSize <= Self.maxPacketPayloadSize else {
            output("ping: invalid packet size \(packetSize)\r\n")
            return
        }
        guard let destinationAddress = addrInfo.pointee.ai_addr,
              addrInfo.pointee.ai_addrlen > 0 else {
            output("ping: internal error: missing destination address\r\n")
            return
        }

        let isIPv6 = config.addressFamily == .ipv6

        // ICMP header: type(1) + code(1) + checksum(2) + id(2) + seq(2) = 8 bytes
        let headerSize = 8
        let totalSize = headerSize + packetSize
        var packet = [UInt8](repeating: 0, count: totalSize)

        // Type
        packet[0] = isIPv6 ? 128 : 8  // Echo Request
        // Code = 0
        packet[1] = 0
        // Checksum placeholder (kernel fills for DGRAM sockets)
        packet[2] = 0
        packet[3] = 0
        // Identifier
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        // Sequence number
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xFF)

        let payloadPrefixBytes = embedPayloadPrefix(into: &packet, headerSize: headerSize, packetSize: packetSize)

        // Fill remaining data with pattern or sequential bytes
        let dataStart = headerSize + payloadPrefixBytes
        if let pattern = config.pattern, !pattern.isEmpty {
            for j in dataStart..<totalSize {
                packet[j] = pattern[(j - dataStart) % pattern.count]
            }
        } else {
            // Standard BSD ping fill pattern
            for j in dataStart..<totalSize {
                packet[j] = UInt8((j - headerSize) & 0xFF)
            }
        }

        // For IPv4 DGRAM sockets, we need to compute checksum ourselves
        if !isIPv6 {
            let cksum = icmpChecksum(packet)
            packet[2] = UInt8(cksum >> 8)
            packet[3] = UInt8(cksum & 0xFF)
        }

        // Send
        let sent: Int
        if connected {
            sent = send(socketFD, packet, totalSize, 0)
        } else {
            sent = sendto(
                socketFD,
                packet,
                totalSize,
                0,
                destinationAddress,
                addrInfo.pointee.ai_addrlen
            )
        }

        if sent < 0 {
            let errCode = errno
            if errCode == EAGAIN || errCode == EWOULDBLOCK || errCode == EINTR {
                // Transient: kernel send buffer is momentarily full or the
                // syscall was interrupted. The attempt is still counted by
                // the caller; we just log and move on.
                Self.logger.debug("sendto would block (errno=\(errCode)); seq=\(seq)")
                return
            }
            let err = String(cString: strerror(errCode))
            Self.logger.error("sendto failed: \(err) (errno=\(errCode))")
            output("ping: sendto: \(err)\r\n")
            if errCode == EHOSTUNREACH || errCode == ENETDOWN || errCode == ENETUNREACH
                || errCode == EBADF || errCode == ENXIO || errCode == EADDRNOTAVAIL {
                pendingSocketReset = true
            }
        }
    }

    private func embedPayloadPrefix(into packet: inout [UInt8], headerSize: Int, packetSize: Int) -> Int {
        guard packetSize > 0 else { return 0 }

        var payloadOffset = 0

        // Session nonce is first in payload so replies can be scoped to this tab.
        let nonceBytesToWrite = min(Self.payloadNonceSize, packetSize)
        var nonce = payloadNonce.littleEndian
        withUnsafeBytes(of: &nonce) { nonceBytes in
            for index in 0..<nonceBytesToWrite {
                packet[headerSize + index] = nonceBytes[index]
            }
        }
        payloadOffset += nonceBytesToWrite

        // Timestamp follows nonce when there's enough room for RTT calculation.
        let remaining = packetSize - payloadOffset
        if remaining >= Self.payloadTimestampSize {
            var tv = timeval()
            gettimeofday(&tv, nil)
            withUnsafeBytes(of: &tv) { tvBytes in
                for index in 0..<Self.payloadTimestampSize {
                    packet[headerSize + payloadOffset + index] = tvBytes[index]
                }
            }
            payloadOffset += Self.payloadTimestampSize
        }

        return payloadOffset
    }

    /// Internet checksum (RFC 1071)
    private func icmpChecksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0

        while i < data.count - 1 {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }

        // Handle odd byte
        if i < data.count {
            sum += UInt32(data[i]) << 8
        }

        // Fold 32-bit sum to 16 bits
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return ~UInt16(sum & 0xFFFF)
    }

    // MARK: - ICMP Receive

    struct PingReply {
        var bytes: Int
        var from: String
        var fromHostname: String?
        var seq: UInt16
        var ttl: Int
        var rtt: Double // milliseconds
        var recordRoute: [String]?
    }

    private struct ControlInfo {
        var ttl: Int = 0
        var receiveTime: timeval?
    }

    /// Receive matching replies for this session.
    /// Waits up to `waitTime` for the first match, then drains any already-queued
    /// replies without blocking to avoid persistent one-cycle backlog inflation.
    private func receivePings(waitTime: TimeInterval) async -> [PingReply] {
        guard socketFD >= 0 else { return [] }

        let isIPv6 = config.addressFamily == .ipv6
        let expectedType: UInt8 = isIPv6 ? 129 : 0 // Echo Reply
        let icmpHeaderSize = 8

        // Use a wall-clock deadline so time always advances, even when we
        // receive non-echo-reply packets (ICMP errors, redirects, etc.)
        // and loop back to poll again.
        let deadline = CFAbsoluteTimeGetCurrent() + waitTime
        var replies: [PingReply] = []
        var drainingQueuedReplies = false
        // Safety valve: once we enter drain mode, don't spin indefinitely under
        // pathological sustained traffic from unrelated ICMP packets.
        let maxDrainPollIterations = 512
        var drainPollIterations = 0

        while !Task.isCancelled {
            let now = CFAbsoluteTimeGetCurrent()
            let remainingSec = deadline - now
            guard remainingSec > 0 else { return replies }

            // Blocking waits run off the main actor; an unreachable target
            // otherwise parks it in poll() for the whole wait window.
            let fd = socketFD
            let wait: (result: Int32, revents: Int16, err: Int32)
            if drainingQueuedReplies {
                // Non-blocking drain once we have at least one matching reply.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&pfd, 1, 0)
                wait = (result, pfd.revents, result < 0 ? errno : 0)
            } else {
                // Capped so cancellation is noticed promptly.
                let chunkMs = max(1, Int32(min(remainingSec * 1000, 100)))
                wait = await Self.waitReadable(fd: fd, timeoutMs: chunkMs)
                guard !Task.isCancelled, socketFD == fd else { return replies }
            }
            let pollResult = wait.result
            let pollErr = wait.err

            if pollResult == 0 {
                if drainingQueuedReplies {
                    return replies
                }
                continue
            }
            if pollResult < 0 {
                if pollErr == EINTR { continue }
                Self.logger.error("poll failed: errno=\(pollErr)")
                pendingSocketReset = true
                return replies
            }

            if drainingQueuedReplies {
                drainPollIterations += 1
                if drainPollIterations >= maxDrainPollIterations {
                    return replies
                }
            }

            // Socket error conditions (network down, interface removed, fd
            // closed under us). Flag the socket for recreation; the outer
            // run loop will call recreateSocket() on its next iteration.
            let errMask = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)
            if wait.revents & errMask != 0 {
                let revents = wait.revents
                Self.logger.error("poll revents indicate socket invalidation: revents=\(revents)")
                pendingSocketReset = true
                return replies
            }

            // Data ready — receive with ancillary data for TTL
            var recvBuf = [UInt8](repeating: 0, count: 65536)
            var controlBuf = [UInt8](repeating: 0, count: 256)
            var srcAddr = sockaddr_storage()
            var iov = iovec()
            var msg = msghdr()

            let (bytesRead, controlInfo): (Int, ControlInfo) = recvBuf.withUnsafeMutableBufferPointer { bufPtr in
                controlBuf.withUnsafeMutableBufferPointer { ctlPtr in
                    withUnsafeMutablePointer(to: &iov) { iovPtr in
                        withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                guard let recvBaseAddress = bufPtr.baseAddress,
                                      let controlBaseAddress = ctlPtr.baseAddress else {
                                    return (-1, ControlInfo())
                                }

                                iovPtr.pointee.iov_base = UnsafeMutableRawPointer(recvBaseAddress)
                                iovPtr.pointee.iov_len = bufPtr.count

                                msg.msg_name = UnsafeMutableRawPointer(sockPtr)
                                msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                                msg.msg_iov = iovPtr
                                msg.msg_iovlen = 1
                                msg.msg_control = UnsafeMutableRawPointer(controlBaseAddress)
                                msg.msg_controllen = socklen_t(ctlPtr.count)

                                let n = recvmsg(socketFD, &msg, 0)
                                // Parse control data while msg_control pointer is still valid.
                                let info = n > 0 ? extractControlInfo(
                                    msg: &msg,
                                    isIPv6: isIPv6,
                                    controlBufferLength: ctlPtr.count
                                ) : ControlInfo()
                                return (n, info)
                            }
                        }
                    }
                }
            }

            guard bytesRead >= icmpHeaderSize else { continue }
            guard bytesRead <= recvBuf.count else { continue }

            // On Apple platforms, SOCK_DGRAM ICMP receives may include the
            // IPv4 header (Apple's SimplePing handles this same case).
            // Detect it by checking the IP version nibble at byte 0.
            var icmpOffset = 0
            if !isIPv6 {
                let versionNibble = (recvBuf[0] & 0xF0) >> 4
                if versionNibble == 4 {
                    // IPv4 header present — IHL field gives length in 32-bit words
                    let ihl = Int(recvBuf[0] & 0x0F) * 4
                    guard ihl >= 20 else { continue }
                    icmpOffset = ihl
                }
            }

            guard bytesRead >= icmpOffset + icmpHeaderSize else { continue }

            // Handle non-echo-reply ICMP messages (errors, redirects, etc.)
            let icmpType = recvBuf[icmpOffset]
            if icmpType != expectedType {
                if config.verbose && !config.quiet && !config.quieter {
                    let icmpCode = recvBuf[icmpOffset + 1]
                    let errAddr = extractSourceAddress(&srcAddr)
                    let errHostname: String?
                    if config.numeric {
                        errHostname = nil
                    } else {
                        errHostname = await cachedReverseLookup(ip: errAddr, storage: srcAddr)
                        guard !Task.isCancelled else { return replies }
                    }
                    let errFrom: String
                    if let hostname = errHostname, hostname != errAddr {
                        errFrom = "\(hostname) (\(errAddr))"
                    } else {
                        errFrom = errAddr
                    }
                    let desc = icmpErrorDescription(type: icmpType, code: icmpCode, isIPv6: isIPv6)
                    let errBytes = bytesRead - icmpOffset
                    output("\(timestampPrefix())\(errBytes) bytes from \(errFrom): \(desc)\r\n")
                }
                continue
            }

            // On Apple platforms, SOCK_DGRAM ICMP sockets do NOT filter
            // replies per-socket — all echo replies are delivered to all
            // sockets. Filter by the kernel-assigned identifier to avoid
            // cross-tab interference.
            let recvIdentifier = UInt16(recvBuf[icmpOffset + 4]) << 8 | UInt16(recvBuf[icmpOffset + 5])
            if let expectedID = kernelIdentifier, recvIdentifier != expectedID {
                continue  // Reply belongs to another ping session
            }

            let recvSeq = UInt16(recvBuf[icmpOffset + 6]) << 8 | UInt16(recvBuf[icmpOffset + 7])
            let dataOffset = icmpOffset + icmpHeaderSize
            let dataLen = bytesRead - dataOffset

            // Reject replies that don't carry this session's nonce.
            if !payloadNonceMatches(buffer: recvBuf, payloadOffset: dataOffset, payloadLength: dataLen) {
                continue
            }

            // Guard against replies from other targets when sockets are not connected.
            if let expectedSourceAddress, !sourceAddressMatchesExpected(srcAddr, expected: expectedSourceAddress) {
                continue
            }

            let ttl = controlInfo.ttl
            let fromAddr = extractSourceAddress(&srcAddr)
            let rtt = extractRTT(
                buffer: recvBuf,
                payloadOffset: dataOffset,
                payloadLength: dataLen,
                receiveTime: controlInfo.receiveTime
            )

            // Reverse DNS lookup (unless -n, or output suppressed)
            let fromHostname: String?
            if !config.numeric && !config.quiet && !config.quieter {
                let hostname = await cachedReverseLookup(ip: fromAddr, storage: srcAddr)
                guard !Task.isCancelled else { return replies }
                if let hostname, hostname != fromAddr {
                    fromHostname = hostname
                } else {
                    fromHostname = nil
                }
            } else {
                fromHostname = nil
            }

            // Parse Record Route from IPv4 header options
            let rr: [String]?
            if config.recordRoute && !isIPv6 && icmpOffset > 20 && icmpOffset <= bytesRead {
                rr = parseRecordRoute(recvBuf, headerLen: icmpOffset)
            } else {
                rr = nil
            }

            replies.append(PingReply(
                bytes: bytesRead,
                from: fromAddr,
                fromHostname: fromHostname,
                seq: recvSeq,
                ttl: ttl,
                rtt: rtt,
                recordRoute: rr
            ))

            // We got at least one matching reply; now drain immediately available
            // queued replies so RTTs don't stay one interval behind.
            drainingQueuedReplies = true
        }

        return replies
    }

    /// Returns poll()'s result, revents, and errno. Blocks on a GCD queue, not
    /// the cooperative pool. cancel() may close `fd` mid-wait; the caller
    /// re-checks cancellation and the fd afterwards.
    private nonisolated static func waitReadable(fd: Int32, timeoutMs: Int32) async -> (Int32, Int16, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&pfd, 1, timeoutMs)
                continuation.resume(returning: (result, pfd.revents, result < 0 ? errno : 0))
            }
        }
    }

    private func payloadNonceMatches(buffer: [UInt8], payloadOffset: Int, payloadLength: Int) -> Bool {
        guard payloadOffset >= 0,
              payloadLength >= 0,
              payloadOffset <= buffer.count,
              payloadLength <= buffer.count - payloadOffset else {
            return false
        }
        guard payloadLength > 0 else { return true }

        let nonceBytesToCheck = min(Self.payloadNonceSize, payloadLength)
        var nonce = payloadNonce.littleEndian
        return withUnsafeBytes(of: &nonce) { nonceBytes in
            for index in 0..<nonceBytesToCheck {
                if buffer[payloadOffset + index] != nonceBytes[index] {
                    return false
                }
            }
            return true
        }
    }

    private func extractRTT(
        buffer: [UInt8],
        payloadOffset: Int,
        payloadLength: Int,
        receiveTime: timeval?
    ) -> Double {
        guard payloadOffset >= 0,
              payloadLength >= 0,
              payloadOffset <= buffer.count,
              payloadLength <= buffer.count - payloadOffset else {
            return 0
        }
        let timestampOffset = payloadOffset + Self.payloadNonceSize
        let requiredLength = Self.payloadNonceSize + Self.payloadTimestampSize
        guard payloadLength >= requiredLength else { return 0 }
        guard timestampOffset <= buffer.count - Self.payloadTimestampSize else { return 0 }

        var sendTime = timeval()
        withUnsafeMutableBytes(of: &sendTime) { sendPtr in
            for index in 0..<Self.payloadTimestampSize {
                sendPtr[index] = buffer[timestampOffset + index]
            }
        }
        let sendTimeAbs = Double(sendTime.tv_sec) + Double(sendTime.tv_usec) / 1_000_000.0
        let recvTimeval: timeval = receiveTime ?? {
            var now = timeval()
            gettimeofday(&now, nil)
            return now
        }()
        let recvTimeAbs = Double(recvTimeval.tv_sec) + Double(recvTimeval.tv_usec) / 1_000_000.0
        let rttMs = (recvTimeAbs - sendTimeAbs) * 1000.0
        return max(0, rttMs)
    }

    private func extractControlInfo(
        msg: inout msghdr,
        isIPv6: Bool,
        controlBufferLength: Int
    ) -> ControlInfo {
        guard let controlBase = msg.msg_control else { return ControlInfo() }
        let controlLen = min(Int(msg.msg_controllen), controlBufferLength)
        guard controlLen > 0 else { return ControlInfo() }
        let headerSize = MemoryLayout<cmsghdr>.size
        let alignMask = MemoryLayout<Int>.size - 1
        var offset = 0
        var info = ControlInfo()

        while offset <= controlLen - headerSize {
            let cmsgPtr = controlBase.advanced(by: offset)
            let cmsg = UnsafeRawBufferPointer(start: cmsgPtr, count: headerSize)
                .loadUnaligned(fromByteOffset: 0, as: cmsghdr.self)
            let cmsgLen = Int(cmsg.cmsg_len)

            guard cmsgLen >= headerSize else { break }
            let remaining = controlLen - offset
            guard cmsgLen <= remaining else { break }

            let cmsgDataLen = cmsgLen - headerSize

            if isIPv6 {
                if cmsg.cmsg_level == IPPROTO_IPV6 && (cmsg.cmsg_type == kIPV6_HOPLIMIT || cmsg.cmsg_type == kIPV6_2292HOPLIMIT) {
                    if cmsgDataLen >= MemoryLayout<Int32>.size {
                        let dataPtr = cmsgPtr.advanced(by: headerSize)
                        let ttl = UnsafeRawBufferPointer(start: dataPtr, count: MemoryLayout<Int32>.size)
                            .loadUnaligned(fromByteOffset: 0, as: Int32.self)
                        info.ttl = Int(ttl)
                    }
                }
            } else {
                if cmsg.cmsg_level == IPPROTO_IP && cmsg.cmsg_type == IP_RECVTTL {
                    let dataPtr = cmsgPtr.advanced(by: headerSize)
                    // IP_RECVTTL returns a single byte on some platforms, Int32 on others
                    if cmsgDataLen >= MemoryLayout<Int32>.size {
                        let ttl = UnsafeRawBufferPointer(start: dataPtr, count: MemoryLayout<Int32>.size)
                            .loadUnaligned(fromByteOffset: 0, as: Int32.self)
                        info.ttl = Int(ttl)
                    } else if cmsgDataLen >= MemoryLayout<UInt8>.size {
                        let ttl = UnsafeRawBufferPointer(start: dataPtr, count: MemoryLayout<UInt8>.size)
                            .loadUnaligned(fromByteOffset: 0, as: UInt8.self)
                        info.ttl = Int(ttl)
                    }
                }
            }

            // Kernel receive timestamp (SO_TIMESTAMP).
            if cmsg.cmsg_level == SOL_SOCKET &&
               cmsg.cmsg_type == kSCM_TIMESTAMP &&
               cmsgDataLen >= MemoryLayout<timeval>.size {
                let dataPtr = cmsgPtr.advanced(by: headerSize)
                let recvTime = UnsafeRawBufferPointer(start: dataPtr, count: MemoryLayout<timeval>.size)
                    .loadUnaligned(fromByteOffset: 0, as: timeval.self)
                if recvTime.tv_sec > 0 || recvTime.tv_usec > 0 {
                    info.receiveTime = recvTime
                }
            }

            // Advance to next cmsghdr (aligned)
            let (lenPlusAlign, alignOverflow) = cmsgLen.addingReportingOverflow(alignMask)
            guard !alignOverflow else { break }
            let alignedLen = lenPlusAlign & ~alignMask
            guard alignedLen > 0 else { break }
            let (nextOffset, offsetOverflow) = offset.addingReportingOverflow(alignedLen)
            guard !offsetOverflow, nextOffset > offset else { break }
            offset = nextOffset
        }

        return info
    }

    private func extractSourceAddress(_ storage: inout sockaddr_storage) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

        withUnsafePointer(to: &storage) { ptr in
            if ptr.pointee.ss_family == sa_family_t(AF_INET6) {
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr6Ptr in
                    var addr = addr6Ptr.pointee.sin6_addr
                    inet_ntop(AF_INET6, &addr, &ipStr, socklen_t(INET6_ADDRSTRLEN))
                }
            } else {
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr4Ptr in
                    var addr = addr4Ptr.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                }
            }
        }

        return String(cString: ipStr)
    }

    private func extractExpectedSourceAddress(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> sockaddr_storage? {
        var storage = sockaddr_storage()

        if addrInfo.pointee.ai_family == AF_INET {
            guard addrInfo.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size),
                  let rawAddress = addrInfo.pointee.ai_addr else {
                return nil
            }
            let addr4 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in.self).pointee
            withUnsafeMutablePointer(to: &storage) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addrPtr in
                    addrPtr.pointee = addr4
                }
            }
            return storage
        }

        if addrInfo.pointee.ai_family == AF_INET6 {
            guard addrInfo.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in6>.size),
                  let rawAddress = addrInfo.pointee.ai_addr else {
                return nil
            }
            let addr6 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee
            withUnsafeMutablePointer(to: &storage) { storagePtr in
                storagePtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addrPtr in
                    addrPtr.pointee = addr6
                }
            }
            return storage
        }

        return nil
    }

    private func sourceAddressMatchesExpected(_ source: sockaddr_storage, expected: sockaddr_storage) -> Bool {
        guard source.ss_family == expected.ss_family else { return false }

        if source.ss_family == sa_family_t(AF_INET) {
            var sourceCopy = source
            var expectedCopy = expected
            let sourceAddr = withUnsafePointer(to: &sourceCopy) { sourcePtr in
                sourcePtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addrPtr in
                    addrPtr.pointee.sin_addr.s_addr
                }
            }
            let expectedAddr = withUnsafePointer(to: &expectedCopy) { expectedPtr in
                expectedPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addrPtr in
                    addrPtr.pointee.sin_addr.s_addr
                }
            }
            return sourceAddr == expectedAddr
        }

        if source.ss_family == sa_family_t(AF_INET6) {
            var sourceCopy = source
            var expectedCopy = expected
            return withUnsafePointer(to: &sourceCopy) { sourcePtr in
                withUnsafePointer(to: &expectedCopy) { expectedPtr in
                    sourcePtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sourceAddrPtr in
                        expectedPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { expectedAddrPtr in
                            let sourceAddr = sourceAddrPtr.pointee
                            let expectedAddr = expectedAddrPtr.pointee
                            let scopeMatches = expectedAddr.sin6_scope_id == 0 || sourceAddr.sin6_scope_id == expectedAddr.sin6_scope_id
                            let addressMatches = withUnsafeBytes(of: sourceAddr.sin6_addr) { sourceBytes in
                                withUnsafeBytes(of: expectedAddr.sin6_addr) { expectedBytes in
                                    sourceBytes.elementsEqual(expectedBytes)
                                }
                            }
                            return scopeMatches && addressMatches
                        }
                    }
                }
            }
        }

        return false
    }

    // MARK: - Duplicate Detection

    private func markReceived(seq: UInt16) -> Bool {
        let index = Int(seq) % Self.bitmapSize
        let byteIndex = index / 8
        let bitMask = UInt8(1 << (index % 8))

        let wasSeen = (receivedBitmap[byteIndex] & bitMask) != 0
        receivedBitmap[byteIndex] |= bitMask
        return wasSeen
    }

    // MARK: - Sweep Support

    private func currentPacketSize(seq: UInt16) -> Int {
        guard let sweepMin = config.sweepMin,
              let sweepMax = config.sweepMax,
              let sweepIncr = config.sweepIncr else {
            return config.packetSize
        }

        let (product, mulOverflow) = Int(seq).multipliedReportingOverflow(by: sweepIncr)
        if mulOverflow { return sweepMax }

        let (size, addOverflow) = sweepMin.addingReportingOverflow(product)
        if addOverflow { return sweepMax }

        return min(size, sweepMax)
    }

    // MARK: - Output Formatting

    private func formatRTT(_ ms: Double) -> String {
        if ms < 1.0 {
            return String(format: "%.3f", ms)
        } else if ms < 10.0 {
            return String(format: "%.3f", ms)
        } else if ms < 100.0 {
            return String(format: "%.3f", ms)
        } else {
            return String(format: "%.3f", ms)
        }
    }

    #if !CHINA_BUILD
    /// Ping over in-app Tailscale with Tailscale's own (disco) ping, which
    /// says whether the path is direct or relayed. ICMP socket options can't apply.
    private func runTailnet(ip: String) async {
        let c = config
        if c.ttl != nil || c.dontFragment || c.sourceAddress != nil || c.boundInterface != nil
            || c.trafficClass != nil || c.recordRoute || c.pattern != nil || c.packetSize != 56 || c.sweepMax != nil {
            didFail = true
            output("ping: -D, -R, -S, -b, -k, -m, -p, -s and sweeps aren't available for hosts reached through Tailscale in rootshell\r\n")
            onComplete?()
            return
        }
        resolvedIP = ip
        resolvedHostname = c.target
        output("PING \(c.target) (\(ip)) over Tailscale\r\n")

        let startTime = CFAbsoluteTimeGetCurrent()
        var seq = 0
        while !Task.isCancelled {
            if let count = c.count, stats.transmitted >= count { break }
            if let timeout = c.timeout, CFAbsoluteTimeGetCurrent() - startTime >= timeout { break }
            let cycleStart = CFAbsoluteTimeGetCurrent()
            stats.transmitted += 1
            let result = await TailnetGo.ping(host: ip, timeout: .milliseconds(Int(c.waitTime * 1000)))
            if Task.isCancelled { break }
            if let latency = result.latencyMs, result.error?.isEmpty ?? true {
                stats.received += 1
                stats.addRTT(latency)
                if !c.quiet && !c.quieter {
                    let via = result.endpoint.map { "direct \($0)" } ?? "via DERP(\(result.derp ?? "?"))"
                    let name = result.nodeName.map { "\($0) (\(ip))" } ?? ip
                    output("\(timestampPrefix())pong from \(name): seq=\(seq) time=\(formatRTT(latency)) ms \(via)\r\n")
                }
                if c.exitOnFirstReply { break }
            } else if c.verbose || !(c.quiet || c.quieter) {
                output("Request timeout for seq \(seq)\(result.error.map { ": \($0)" } ?? "")\r\n")
            }
            seq += 1
            let sleepEnd = cycleStart + c.interval
            while !Task.isCancelled && CFAbsoluteTimeGetCurrent() < sleepEnd {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        if !Task.isCancelled {
            printSummary()
            onComplete?()
        }
    }
    #endif

    private func printSummary() {
        output("\r\n--- \(resolvedHostname) ping statistics ---\r\n")

        let loss: Double
        if stats.transmitted > 0 {
            loss = Double(stats.transmitted - stats.received) / Double(stats.transmitted) * 100.0
        } else {
            loss = 0
        }

        var summaryLine = "\(stats.transmitted) packets transmitted, \(stats.received) packets received"
        if stats.duplicates > 0 {
            summaryLine += ", +\(stats.duplicates) duplicates"
        }
        summaryLine += ", \(formatLoss(loss))% packet loss"
        output(summaryLine + "\r\n")

        if stats.received > 0 {
            let avg = stats.tSum / Double(stats.received)
            let variance = stats.tSumSq / Double(stats.received) - avg * avg
            let stddev = variance > 0 ? sqrt(variance) : 0

            output("round-trip min/avg/max/stddev = \(formatRTT(stats.tMin))/\(formatRTT(avg))/\(formatRTT(stats.tMax))/\(formatRTT(stddev)) ms\r\n")
        }
    }

    private func formatLoss(_ loss: Double) -> String {
        if loss == 0.0 {
            return "0.0"
        } else if loss == 100.0 {
            return "100.0"
        } else {
            return String(format: "%.1f", loss)
        }
    }

    // MARK: - Timestamp Prefix (--apple-time)

    private func timestampPrefix() -> String {
        guard config.appleTime else { return "" }
        var tv = timeval()
        gettimeofday(&tv, nil)
        var time = tv.tv_sec
        var tm = Darwin.tm()
        localtime_r(&time, &tm)
        return String(format: "%02d:%02d:%02d.%06d ",
                      tm.tm_hour, tm.tm_min, tm.tm_sec, tv.tv_usec)
    }

    // MARK: - Reverse DNS (-n suppresses)

    /// Cached reverse DNS with async off-main-actor resolution.
    /// Cache hits are instant; misses run getnameinfo() on a utility queue so
    /// the main actor stays responsive. Failures cache the numeric address to
    /// avoid retrying the same blocking lookup for every reply.
    private func cachedReverseLookup(ip: String, storage: sockaddr_storage) async -> String? {
        if let cached = dnsCache[ip] { return cached }
        let resolved = await Self.reverseResolve(storage) ?? ip
        guard !Task.isCancelled else { return nil }
        dnsCache[ip] = resolved
        return resolved
    }

    /// Runs blocking getnameinfo() off the main actor.
    private nonisolated static func reverseResolve(_ storage: sockaddr_storage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var storageCopy = storage
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len: socklen_t
                if storageCopy.ss_family == sa_family_t(AF_INET6) {
                    len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                } else {
                    len = socklen_t(MemoryLayout<sockaddr_in>.size)
                }
                let rc = withUnsafePointer(to: &storageCopy) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        getnameinfo(sockPtr, len, &hostBuf, socklen_t(NI_MAXHOST), nil, 0, 0)
                    }
                }
                guard rc == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(cString: hostBuf))
            }
        }
    }

    // MARK: - ICMP Error Descriptions (-v)

    private func icmpErrorDescription(type: UInt8, code: UInt8, isIPv6: Bool) -> String {
        if isIPv6 {
            switch type {
            case 1: // Destination Unreachable
                let codes = [
                    "No route to destination",
                    "Communication with destination administratively prohibited",
                    "Beyond scope of source address",
                    "Address unreachable",
                    "Port unreachable",
                    "Source address failed ingress/egress policy",
                    "Reject route to destination"
                ]
                let desc = Int(code) < codes.count ? codes[Int(code)] : "Destination unreachable, code \(code)"
                return "Destination unreachable: \(desc)"
            case 2:
                return "Packet too big"
            case 3:
                return code == 0 ? "Time exceeded: Hop limit exceeded in transit"
                                 : "Time exceeded: Fragment reassembly time exceeded"
            case 4:
                return "Parameter problem, code \(code)"
            default:
                return "ICMPv6 type \(type), code \(code)"
            }
        } else {
            switch type {
            case 3: // Destination Unreachable
                let codes = [
                    "Destination Net Unreachable",
                    "Destination Host Unreachable",
                    "Destination Protocol Unreachable",
                    "Destination Port Unreachable",
                    "Fragmentation needed and DF set",
                    "Source Route Failed",
                    "Destination Net Unknown",
                    "Destination Host Unknown",
                    "Source Host Isolated",
                    "Destination Net Administratively Prohibited",
                    "Destination Host Administratively Prohibited",
                    "Destination Net Unreachable for TOS",
                    "Destination Host Unreachable for TOS",
                    "Communication Administratively Prohibited",
                    "Host Precedence Violation"
                ]
                let desc = Int(code) < codes.count ? codes[Int(code)] : "Destination unreachable, code \(code)"
                return desc
            case 4:
                return "Source Quench"
            case 5:
                let codes = [
                    "Redirect for Network",
                    "Redirect for Host",
                    "Redirect for TOS and Network",
                    "Redirect for TOS and Host"
                ]
                let desc = Int(code) < codes.count ? codes[Int(code)] : "Redirect, code \(code)"
                return desc
            case 11:
                return code == 0 ? "Time to live exceeded"
                                 : "Fragment reassembly time exceeded"
            case 12:
                return "Parameter problem, code \(code)"
            default:
                return "ICMP type \(type), code \(code)"
            }
        }
    }

    // MARK: - Record Route Parsing (-R)

    /// Parse IP Record Route option from IPv4 header options (bytes 20..<headerLen)
    private func parseRecordRoute(_ buf: [UInt8], headerLen: Int) -> [String]? {
        guard headerLen > 20, headerLen <= buf.count else { return nil }

        var hops: [String] = []
        var pos = 20 // IP options start after the 20-byte base header

        while pos < headerLen {
            let optType = buf[pos]

            // End of options list
            if optType == 0 { break }

            // NOP — single-byte option
            if optType == 1 {
                pos += 1
                continue
            }

            // Multi-byte option: type(1) + length(1) + data
            guard pos + 1 < headerLen else { break }
            let optLen = Int(buf[pos + 1])
            guard optLen >= 2, pos + optLen <= headerLen else { break }

            // Record Route (type 7)
            if optType == 7 && optLen >= 3 {
                let pointer = Int(buf[pos + 2]) // 1-based offset within option
                // Addresses start at offset 3 within the option, each is 4 bytes
                let dataStart = pos + 3
                let usedEnd: Int
                if pointer > optLen {
                    usedEnd = pos + optLen // pointer past end = all slots used
                } else {
                    usedEnd = pos + pointer - 1 // pointer is 1-based, points to next empty slot
                }

                var addrPos = dataStart
                while addrPos + 4 <= usedEnd {
                    var addr = in_addr()
                    addr.s_addr = UInt32(buf[addrPos])
                        | (UInt32(buf[addrPos + 1]) << 8)
                        | (UInt32(buf[addrPos + 2]) << 16)
                        | (UInt32(buf[addrPos + 3]) << 24)
                    var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                    hops.append(String(cString: ipStr))
                    addrPos += 4
                }
            }

            pos += optLen
        }

        return hops.isEmpty ? nil : hops
    }

    // MARK: - Cleanup

    private func cleanup() {
        cancellables.removeAll()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        if let addrInfo = savedAddrInfo {
            freeaddrinfo(addrInfo)
            savedAddrInfo = nil
        }
    }
}

// MARK: - Statistics

private struct PingStatistics {
    var transmitted: Int = 0
    var received: Int = 0
    var duplicates: Int = 0
    var tMin: Double = .infinity
    var tMax: Double = 0
    var tSum: Double = 0
    var tSumSq: Double = 0

    mutating func addRTT(_ ms: Double) {
        tMin = min(tMin, ms)
        tMax = max(tMax, ms)
        tSum += ms
        tSumSq += ms * ms
    }
}

#endif // !targetEnvironment(macCatalyst)
