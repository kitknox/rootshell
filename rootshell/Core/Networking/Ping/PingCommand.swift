#if !targetEnvironment(macCatalyst)

import Foundation
import Darwin
import OSLog
import Combine

// IPv6 socket option constants not exposed to Swift on iOS
nonisolated private let kIPV6_RECVHOPLIMIT: Int32 = 37       // IPV6_RECVHOPLIMIT - enable hop limit in ancillary data
/// The shell owns lifecycle and path notifications on the main actor. The worker
/// writes directly to the session's thread-safe terminal sink.
@MainActor
final class PingCommand {
    private let worker: PingWorker
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    var onComplete: ((Int32) -> Void)?

    init(config: PingCommandParser.PingConfig, output: @escaping @Sendable (String) -> Void) {
        worker = PingWorker(config: config, output: output)
    }

    func start() {
        let worker = self.worker
        NetworkReachabilityMonitor.shared.networkPathUpdated
            .merge(with: NetworkReachabilityMonitor.shared.connectivityRestored)
            .sink { Task { await worker.requestReset() } }
            .store(in: &cancellables)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let status = await worker.run()
            guard !Task.isCancelled else { return }
            await self?.complete(status)
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        Task { complete(await worker.interrupt()) }
    }

    private func complete(_ status: Int32) {
        cancellables.removeAll()
        task = nil
        let callback = onComplete
        onComplete = nil
        callback?(status)
    }
}

private actor PingWorker {
    private static let logger = Logger(subsystem: "com.kk2.rootshell", category: "ping")
    let config: PingCommandParser.PingConfig
    let output: @Sendable (String) -> Void
    private var exitStatus: Int32?
    private var startedProbing = false
    private var socketFD: Int32 = -1
    private var identity = ICMPProbe.Identity()
    private var checkedKernelID = false
    private var kernelIdentifier: UInt16?
    private var connected = false
    private var stats = PingStatistics()

    private var history = PingProbeHistory()
    private static let maxPacketPayloadSize = 65_500

    // Resolved target address info
    private var resolvedIP: String = ""
    private var recvBuf = [UInt8](repeating: 0, count: 65536)
    private var controlBuf = [UInt8](repeating: 0, count: 256)
    private var destination: Address?

    // Reverse DNS cache (ip → hostname, or ip → ip after failure) to
    // avoid repeated blocking lookups.
    private var dnsCache: [String: String] = [:]

    // Socket-reset machinery: invalidation can come from kernel-reported
    // revents/errno or from NWPathMonitor/foreground notifications.
    private var pendingSocketReset = false
    private var lastResetTime: TimeInterval = 0
    private var consecutiveResetFailures = 0
    private let minResetInterval: TimeInterval = 1.0

    init(config: PingCommandParser.PingConfig, output: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.output = output
    }

    func requestReset() { pendingSocketReset = true }

    func interrupt() -> Int32 {
        if let exitStatus { return exitStatus }
        output("^C\r\n")
        printSummary()
        exitStatus = 130
        return 130
    }

    func run() async -> Int32 {
        await runCommand()
        cleanup()
        if Task.isCancelled { return interrupt() }
        if startedProbing { printSummary() }
        let status: Int32 = stats.received == 0 ? 1 : 0
        exitStatus = status
        return status
    }

    private func runCommand() async {
        guard !Task.isCancelled else { return }
        let deadline = ICMPDeadline(timeout: config.timeout)
        let overallEnd = deadline.continuousEnd
        let target = await deadline.waitForSetup { [config] in
            await Self.resolveTarget(config)
        }
        guard !Task.isCancelled else { return }
        let address: Address
        switch target {
        case .native(let resolved):
            address = resolved
        #if !CHINA_BUILD
        case .tailnet(let ip):
            await runTailnet(ip: ip, deadline: deadline)
            return
        #endif
        case .unknownHost:
            output("ping: cannot resolve \(config.target): Unknown host\r\n")
            return
        case nil:
            output("ping: timeout resolving \(config.target)\r\n")
            return
        }

        destination = address
        var storage = address.storage
        resolvedIP = extractSourceAddress(&storage)

        // Create socket
        let isIPv6 = config.addressFamily == .ipv6
        let proto = isIPv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, proto)

        guard socketFD >= 0 else {
            let err = String(cString: strerror(errno))
            output("ping: socket: \(err)\r\n")
            return
        }

        guard prepareSocket(socketFD) else { return }

        configureSocket()

        // Connect socket if requested (filters received packets to target)
        if config.appleConnect {
            let rc = address.withSockaddr { Darwin.connect(socketFD, $0, $1) }
            if rc == 0 {
                connected = true
            } else {
                let err = String(cString: strerror(errno))
                output("ping: connect: \(err)\r\n")
                return
            }
        }

        startedProbing = true
        output("PING \(config.target) (\(resolvedIP)): \(currentPacketSize(seq: 0)) data bytes\r\n")

        let limit = config.count ?? Int.max
        var attempts = 0
        var lastSend = ICMPProbe.continuousNow

        func sendNext() -> SendOutcome {
            let seq = UInt16(truncatingIfNeeded: attempts)
            let outcome = sendPing(seq: seq, address: address, packetSize: currentPacketSize(seq: seq), overallEnd: overallEnd)
            lastSend = ICMPProbe.continuousNow
            if outcome != .retry {
                attempts += 1
                if UInt16(truncatingIfNeeded: attempts) == 0 { identity = ICMPProbe.Identity() }
            }
            return outcome
        }

        var nextSend = ICMPProbe.continuousNow
        for _ in 0..<min(config.preload, limit) {
            guard !Task.isCancelled, ICMPProbe.continuousNow < overallEnd else { break }
            if sendNext() == .retry {
                nextSend = lastSend + config.interval
                break
            }
        }

        while !Task.isCancelled {
            let now = ICMPProbe.continuousNow
            if attempts < limit && now < overallEnd && now >= nextSend {
                if pendingSocketReset { recreateSocket(reason: "network path changed") }
                _ = sendNext()
                nextSend = lastSend + config.interval
            }
            let finishedSending = attempts == limit || ICMPProbe.continuousNow >= overallEnd
            if finishedSending && stats.received == stats.transmitted { break }
            let receiveEnd = min(overallEnd, finishedSending ? lastSend + config.waitTime : nextSend)
            if socketFD >= 0, let reply = await receivePing(until: receiveEnd, commandDeadline: deadline) {
                record(reply)
                if config.exitOnFirstReply { break }
            } else if finishedSending {
                break
            } else {
                await sleepUntil(receiveEnd)
            }
        }
    }

    private func record(_ reply: PingReply) {
        if reply.duplicate {
            stats.duplicates += 1
        } else {
            stats.received += 1
            if let rtt = reply.rtt { stats.addRTT(rtt) }
        }
        guard !config.quiet && !config.quieter else { return }
        let dup = reply.duplicate ? " (DUP!)" : ""
        let ttl = reply.ttl > 0 ? " ttl=\(reply.ttl)" : ""
        let seqLabel = config.addressFamily == .ipv6 ? "icmp6_seq" : "icmp_seq"
        let from = reply.fromHostname.map { "\($0) (\(reply.from))" } ?? reply.from
        let timing = reply.rtt.map { " time=\(formatRTT($0)) ms" } ?? ""
        output("\(timestampPrefix())\(reply.bytes) bytes from \(from): \(seqLabel)=\(reply.seq)\(ttl)\(timing)\(dup)\r\n")
        if let hops = reply.recordRoute {
            output("RR:" + hops.map { "\t\($0)\r\n" }.joined())
        }
    }

    private func sleepUntil(_ deadline: TimeInterval) async {
        while !Task.isCancelled {
            let remaining = deadline - ICMPProbe.continuousNow
            guard remaining > 0 else { break }
            try? await Task.sleep(for: .seconds(min(remaining, 60)))
        }
    }

    private func prepareSocket(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              ICMPProbe.enableTimestamps(on: fd) else {
            output("ping: configure socket: \(String(cString: strerror(errno)))\r\n")
            return false
        }
        return true
    }

    /// Rebuild the ICMP socket in-place when the kernel reports invalidation
    /// or a network path change has occurred. Rate-limited to once per
    /// `minResetInterval` to avoid thrashing under flapping networks.
    private func recreateSocket(reason: String) {
        // Check the rate limiter first and keep `pendingSocketReset` armed
        // when throttled — otherwise a sub-second ping interval could drop
        // the pending signal before the cooldown elapses, wedging the
        // session on a dead socket until some other event re-arms the flag.
        let now = ICMPProbe.now
        if now - lastResetTime < minResetInterval {
            Self.logger.debug("recreateSocket suppressed by rate limiter (reason=\(reason))")
            return
        }
        lastResetTime = now
        pendingSocketReset = false

        guard let destination else {
            Self.logger.error("recreateSocket called with no destination")
            return
        }

        let oldFD = socketFD
        if oldFD >= 0 {
            close(oldFD)
        }
        socketFD = -1
        connected = false
        kernelIdentifier = nil
        checkedKernelID = false

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
        guard prepareSocket(newFD) else {
            close(newFD)
            socketFD = -1
            pendingSocketReset = true
            return
        }
        configureSocket(silentUserErrors: true)

        if config.appleConnect {
            let rc = destination.withSockaddr { Darwin.connect(newFD, $0, $1) }
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

    // MARK: - DNS Resolution

    private struct Address: Sendable {
        var storage = sockaddr_storage()

        init?(_ info: addrinfo) {
            let length = Int(info.ai_addrlen)
            guard let raw = info.ai_addr, length <= MemoryLayout<sockaddr_storage>.size,
                  length == Int(raw.pointee.sa_len), length > 0 else { return nil }
            withUnsafeMutableBytes(of: &storage) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: raw, count: length))
            }
        }

        func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
            withUnsafePointer(to: storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t($0.pointee.sa_len))
                }
            }
        }
    }

    private enum Target: Sendable {
        case native(Address)
        #if !CHINA_BUILD
        case tailnet(String)
        #endif
        case unknownHost
    }

    private nonisolated static func resolveTarget(_ config: PingCommandParser.PingConfig) async -> Target {
        #if !CHINA_BUILD
        if let ip = await TailnetDialer.route(config.target) { return .tailnet(ip) }
        #endif
        guard !Task.isCancelled else { return .unknownHost }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = config.addressFamily == .ipv6 ? AF_INET6 : AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(config.target, nil, &hints, &result)
                guard status == 0, let result else {
                    logger.error("getaddrinfo failed for \(config.target): \(String(cString: gai_strerror(status)))")
                    continuation.resume(returning: .unknownHost)
                    return
                }
                defer { freeaddrinfo(result) }
                // Only a value copy leaves this queue, even if the command already timed out.
                continuation.resume(returning: Address(result.pointee).map(Target.native) ?? .unknownHost)
            }
        }
    }

    // MARK: - ICMP Packet Construction

    private enum SendOutcome { case sent, retry, failed }

    private func sendPing(seq: UInt16, address: Address, packetSize: Int, overallEnd: TimeInterval) -> SendOutcome {
        guard socketFD >= 0 else { return .failed }
        guard packetSize >= 0, packetSize <= Self.maxPacketPayloadSize else {
            output("ping: invalid packet size \(packetSize)\r\n")
            return .failed
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
        packet[4] = UInt8(identity.identifier >> 8)
        packet[5] = UInt8(identity.identifier & 0xFF)
        // Sequence number
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xFF)

        let payloadPrefixBytes = identity.writeNonce(into: &packet)

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
            let cksum = ICMPProbe.checksum(packet)
            packet[2] = UInt8(cksum >> 8)
            packet[3] = UInt8(cksum & 0xFF)
        }

        let deadline = ICMPDeadline(timeout: config.waitTime)
        guard deadline.start.continuous < overallEnd else { return .failed }
        let sent: Int
        if connected {
            sent = send(socketFD, packet, totalSize, 0)
        } else {
            sent = address.withSockaddr { sendto(socketFD, packet, totalSize, 0, $0, $1) }
        }

        if sent == totalSize {
            if !checkedKernelID {
                kernelIdentifier = ICMPProbe.localIdentifier(on: socketFD)
                checkedKernelID = true
            }
            var wireIdentity = identity
            wireIdentity.identifier = kernelIdentifier ?? identity.identifier
            history.sent(sequence: seq, deadline: deadline, identity: wireIdentity, payloadSize: packetSize)
            stats.transmitted += 1
            return .sent
        } else {
            let errCode = errno
            if errCode == EAGAIN || errCode == EWOULDBLOCK || errCode == EINTR {
                // Transient: kernel send buffer is momentarily full or the
                // syscall was interrupted. No packet went out.
                Self.logger.debug("sendto would block (errno=\(errCode)); seq=\(seq)")
                return .retry
            }
            let err = String(cString: strerror(errCode))
            Self.logger.error("sendto failed: \(err) (errno=\(errCode))")
            output("ping: sendto: \(err)\r\n")
            if errCode == EHOSTUNREACH || errCode == ENETDOWN || errCode == ENETUNREACH
                || errCode == EBADF || errCode == ENXIO || errCode == EADDRNOTAVAIL {
                pendingSocketReset = true
            }
            return .failed
        }
    }

    // MARK: - ICMP Receive

    struct PingReply {
        var bytes: Int
        var from: String
        var fromHostname: String?
        var seq: UInt16
        var ttl: Int
        var rtt: Double? // milliseconds
        var duplicate: Bool
        var recordRoute: [String]?
    }

    private func receivePing(until deadline: TimeInterval, commandDeadline: ICMPDeadline) async -> PingReply? {
        let isIPv6 = config.addressFamily == .ipv6
        let expectedType: UInt8 = isIPv6 ? 129 : 0
        let icmpHeaderSize = 8
        var trailingReads = 0
        while !Task.isCancelled {
            let remaining = deadline - ICMPProbe.continuousNow
            // A reply may already be queued when a short interval expires.
            // Bound the final nonblocking drain so other sessions cannot starve sends.
            if remaining <= 0 {
                trailingReads += 1
                if trailingReads > 64 { return nil }
            }
            let chunkMs = Int32(max(0, min(remaining * 1000, 100)).rounded(.up))
            let wait = await Self.waitReadable(fd: socketFD, timeoutMs: chunkMs)
            guard !Task.isCancelled else { return nil }
            let pollResult = wait.result
            let pollErr = wait.err

            if pollResult == 0 {
                if chunkMs == 0 { return nil }
                continue
            }
            if pollResult < 0 {
                if pollErr == EINTR { continue }
                Self.logger.error("poll failed: errno=\(pollErr)")
                pendingSocketReset = true
                return nil
            }

            // Socket error conditions (network down, interface removed, fd
            // closed under us). Flag the socket for recreation; the outer
            // run loop will call recreateSocket() on its next iteration.
            let errMask = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)
            if wait.revents & errMask != 0 {
                let revents = wait.revents
                Self.logger.error("poll revents indicate socket invalidation: revents=\(revents)")
                pendingSocketReset = true
                return nil
            }

            // Data ready — receive with ancillary data for TTL
            var srcAddr = sockaddr_storage()
            var iov = iovec()
            var msg = msghdr()

            var readAt: ICMPClockSample?
            let (bytesRead, controlInfo): (Int, ICMPProbe.ControlInfo) = recvBuf.withUnsafeMutableBufferPointer { bufPtr in
                controlBuf.withUnsafeMutableBufferPointer { ctlPtr in
                    withUnsafeMutablePointer(to: &iov) { iovPtr in
                        withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                guard let recvBaseAddress = bufPtr.baseAddress,
                                      let controlBaseAddress = ctlPtr.baseAddress else {
                                    return (-1, ICMPProbe.ControlInfo())
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
                                if n >= icmpHeaderSize { readAt = .now }
                                // Parse control data while msg_control pointer is still valid.
                                let info = ICMPProbe.controlInfo(msg: msg, capacity: ctlPtr.count)
                                return (n, info)
                            }
                        }
                    }
                }
            }

            guard let readAt, bytesRead >= icmpHeaderSize else { continue }
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
                if config.verbose && !config.quiet && !config.quieter,
                   let quote = ICMPProbe.EchoQuote(in: recvBuf, ipOffset: icmpOffset + 8, end: bytesRead),
                   history.matches(quote, in: recvBuf) {
                    let icmpCode = recvBuf[icmpOffset + 1]
                    let errAddr = extractSourceAddress(&srcAddr)
                    let errHostname: String?
                    if config.numeric {
                        errHostname = nil
                    } else {
                        errHostname = cachedReverseLookup(ip: errAddr, storage: srcAddr)
                        guard !Task.isCancelled else { return nil }
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

            // Darwin can deliver concurrent sessions’ replies to this socket.
            let recvIdentifier = UInt16(recvBuf[icmpOffset + 4]) << 8 | UInt16(recvBuf[icmpOffset + 5])
            let recvSeq = UInt16(recvBuf[icmpOffset + 6]) << 8 | UInt16(recvBuf[icmpOffset + 7])
            let dataOffset = icmpOffset + icmpHeaderSize
            let dataLen = bytesRead - dataOffset

            // Guard against replies from other targets when sockets are not connected.
            if let destination, !sourceAddressMatchesExpected(srcAddr, expected: destination.storage) {
                continue
            }

            guard case .timely = commandDeadline.classify(controlInfo, read: readAt) else {
                continue
            }
            guard recvBuf[icmpOffset + 1] == 0,
                  let sample = history.received(sequence: recvSeq, identifier: recvIdentifier, in: recvBuf,
                                                payloadOffset: dataOffset, payloadSize: dataLen,
                                                arrival: controlInfo, readAt: readAt) else { continue }

            let fromAddr = extractSourceAddress(&srcAddr)
            // Reverse DNS lookup (unless -n, or output suppressed)
            let fromHostname: String?
            if !config.numeric && !config.quiet && !config.quieter {
                let hostname = cachedReverseLookup(ip: fromAddr, storage: srcAddr)
                guard !Task.isCancelled else { return nil }
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

            return PingReply(
                bytes: bytesRead - icmpOffset,
                from: fromAddr,
                fromHostname: fromHostname,
                seq: recvSeq,
                ttl: controlInfo.ttl,
                rtt: sample.rtt,
                duplicate: sample.duplicate,
                recordRoute: rr
            )
        }
        return nil
    }

    /// Keep blocking poll calls off the cooperative pool. The worker owns the fd until this returns.
    private nonisolated static func waitReadable(fd: Int32, timeoutMs: Int32) async -> (result: Int32, revents: Int16, err: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&pfd, 1, timeoutMs)
                continuation.resume(returning: (result, pfd.revents, result < 0 ? errno : 0))
            }
        }
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
        String(format: "%.3f", ms)
    }

    #if !CHINA_BUILD
    /// Ping over in-app Tailscale with Tailscale's own (disco) ping, which
    /// says whether the path is direct or relayed. ICMP socket options can't apply.
    private func runTailnet(ip: String, deadline: ICMPDeadline) async {
        let overallEnd = deadline.continuousEnd
        let c = config
        if c.ttl != nil || c.dontFragment || c.sourceAddress != nil || c.boundInterface != nil
            || c.trafficClass != nil || c.recordRoute || c.pattern != nil || c.packetSize != 56 || c.sweepMax != nil {
            output("ping: -D, -R, -S, -b, -k, -m, -p, -s and sweeps aren't available for hosts reached through Tailscale in rootshell\r\n")
            return
        }
        resolvedIP = ip
        startedProbing = true
        output("PING \(c.target) (\(ip)) over Tailscale\r\n")

        var seq = 0
        while !Task.isCancelled {
            if let count = c.count, stats.transmitted >= count { break }
            let cycleStart = ICMPProbe.continuousNow
            if cycleStart >= overallEnd { break }
            var reply: TailnetGo.PingResult?
            for await event in TailnetGo.ping(host: ip, waitTime: c.waitTime, deadline: deadline) {
                switch event {
                case .started:
                    stats.transmitted += 1
                case .completed(let result, let completedAt):
                    if completedAt <= overallEnd { reply = result }
                }
            }
            guard !Task.isCancelled, let result = reply else { break }
            if let latency = result.latencyMs, latency.isFinite, latency >= 0, result.error?.isEmpty ?? true {
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
            if c.count == stats.transmitted { break }
            await sleepUntil(min(cycleStart + c.interval, overallEnd))
        }
    }
    #endif

    private func printSummary() {
        output("\r\n--- \(config.target) ping statistics ---\r\n")

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
        if stats.transmitted > 0 { summaryLine += ", \(formatLoss(loss))% packet loss" }
        output(summaryLine + "\r\n")

        if stats.timed > 0 {
            let avg = stats.tSum / Double(stats.timed)
            let variance = stats.tSumSq / Double(stats.timed) - avg * avg
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

    /// A slow PTR lookup must not delay another send or the receive deadline.
    private func cachedReverseLookup(ip: String, storage: sockaddr_storage) -> String? {
        if let cached = dnsCache[ip] { return cached }
        dnsCache[ip] = ip
        Task { [weak self] in
            let name = await Self.reverseResolve(storage)
            if let name { await self?.cacheHostname(name, for: ip) }
        }
        return nil
    }

    private func cacheHostname(_ name: String, for ip: String) { dnsCache[ip] = name }

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
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        destination = nil
    }
}

// MARK: - Statistics

nonisolated private struct PingStatistics {
    var transmitted: Int = 0
    var received: Int = 0
    var duplicates: Int = 0
    var timed = 0
    var tMin: Double = .infinity
    var tMax: Double = 0
    var tSum: Double = 0
    var tSumSq: Double = 0

    mutating func addRTT(_ ms: Double) {
        timed += 1
        tMin = min(tMin, ms)
        tMax = max(tMax, ms)
        tSum += ms
        tSumSq += ms * ms
    }
}

#endif // !targetEnvironment(macCatalyst)
