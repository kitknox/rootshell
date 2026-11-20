#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation

/// Wire identifiers are shared by ping and mtr, including probes too small to carry a nonce.
nonisolated enum ICMPProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var nextID = UInt16.random(in: 1...UInt16.max)

    private static func allocateIdentifier() -> UInt16 {
        lock.withLock {
            defer { nextID &+= 1 }
            return nextID
        }
    }

    /// A new identifier and nonce are allocated when the 16-bit wire sequence wraps.
    struct Identity {
        var identifier = ICMPProbe.allocateIdentifier()
        let nonce = UInt64.random(in: .min ... .max)

        func writeNonce(into packet: inout [UInt8]) -> Int {
            let count = min(8, packet.count - 8)
            withUnsafeBytes(of: nonce.littleEndian) {
                packet.replaceSubrange(8..<(8 + count), with: $0.prefix(count))
            }
            return count
        }

        func matchesNonce(in bytes: [UInt8], offset: Int, length: Int) -> Bool {
            let count = min(8, length)
            guard count >= 0, offset >= 0, offset <= bytes.count - count else { return false }
            return withUnsafeBytes(of: nonce.littleEndian) {
                bytes[offset..<(offset + count)].elementsEqual($0.prefix(count))
            }
        }
    }

    /// ICMP errors can quote just the IP and echo headers. A full nonce survives
    /// NAT64 identifier rewriting. Shorter quotes must also match the wire ID.
    struct EchoQuote {
        let sequence: UInt16
        let identifier: UInt16
        let payloadOffset: Int
        let payloadLength: Int

        init?(in bytes: [UInt8], ipOffset: Int, end: Int) {
            guard ipOffset >= 0, ipOffset < end, end <= bytes.count else { return nil }
            let headerLength: Int
            let requestType: UInt8
            switch bytes[ipOffset] >> 4 {
            case 4:
                headerLength = Int(bytes[ipOffset] & 15) * 4
                guard headerLength >= 20, end - ipOffset >= headerLength,
                      bytes[ipOffset + 9] == IPPROTO_ICMP else { return nil }
                requestType = 8
            case 6:
                headerLength = 40
                guard end - ipOffset >= headerLength, bytes[ipOffset + 6] == IPPROTO_ICMPV6 else { return nil }
                requestType = 128
            default:
                return nil
            }
            let echo = ipOffset + headerLength
            guard end - echo >= 8, bytes[echo] == requestType, bytes[echo + 1] == 0 else { return nil }
            identifier = UInt16(bytes[echo + 4]) << 8 | UInt16(bytes[echo + 5])
            sequence = UInt16(bytes[echo + 6]) << 8 | UInt16(bytes[echo + 7])
            payloadOffset = echo + 8
            payloadLength = end - payloadOffset
        }

        func matches(_ identity: Identity, sentSize: Int, in bytes: [UInt8]) -> Bool {
            let available = min(sentSize, payloadLength)
            guard available >= 8 || identifier == identity.identifier else { return false }
            return identity.matchesNonce(in: bytes, offset: payloadOffset, length: available)
        }
    }

    /// Some Darwin ICMP sockets expose a rewritten echo ID as their local port.
    /// Otherwise the kernel preserves the ID supplied in the echo header.
    static func localIdentifier(on fd: Int32) -> UInt16? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout.size(ofValue: address))
        return withUnsafeMutablePointer(to: &address) { ptr in
            let rc = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
            guard rc == 0 else { return nil }
            let port: UInt16
            if ptr.pointee.ss_family == AF_INET6 {
                port = ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port }
            } else {
                port = ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
            }
            return port == 0 ? nil : UInt16(bigEndian: port)
        }
    }

    /// Internet checksum (RFC 1071)
    static func checksum(_ data: [UInt8]) -> UInt16 {
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

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double? {
        guard end >= start else { return nil }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    private static func seconds(at ticks: UInt64) -> TimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static var now: TimeInterval { seconds(at: mach_absolute_time()) }

    /// Command deadlines advance while iOS sleeps. SCM_TIMESTAMP_MONOTONIC uses mach_absolute_time instead.
    static var continuousNow: TimeInterval { seconds(at: mach_continuous_time()) }

    static func enableTimestamps(on fd: Int32) -> Bool {
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout.size(ofValue: on))
        if setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &on, size) != 0 { return false }
        return setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &on, size) == 0
    }

    struct ControlInfo {
        var ttl = 0
        var receiveTime: UInt64?
        var wallTime: TimeInterval?
    }

    /// Darwin's CMSG_NXTHDR uses __DARWIN_ALIGN32 even on 64-bit devices.
    static func controlInfo(msg: msghdr, capacity: Int) -> ControlInfo {
        var result = ControlInfo()
        guard let base = msg.msg_control else { return result }
        let length = min(Int(msg.msg_controllen), capacity)
        let header = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + header <= length {
            let record = UnsafeRawPointer(base.advanced(by: offset))
            let cmsg = record.loadUnaligned(as: cmsghdr.self)
            let size = Int(cmsg.cmsg_len)
            guard size >= header, size <= length - offset else { break }
            let data = record.advanced(by: header)
            let count = size - header
            if cmsg.cmsg_level == SOL_SOCKET, cmsg.cmsg_type == SCM_TIMESTAMP_MONOTONIC, count >= 8 {
                result.receiveTime = data.loadUnaligned(as: UInt64.self)
            } else if cmsg.cmsg_level == SOL_SOCKET, cmsg.cmsg_type == SCM_TIMESTAMP, count >= MemoryLayout<timeval>.size {
                let tv = data.loadUnaligned(as: timeval.self)
                result.wallTime = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
            } else if cmsg.cmsg_level == IPPROTO_IP, cmsg.cmsg_type == IP_RECVTTL, count >= 1 {
                result.ttl = Int(data.load(as: UInt8.self))
            } else if cmsg.cmsg_level == IPPROTO_IPV6, [20, 47].contains(cmsg.cmsg_type), count >= 4 {
                result.ttl = Int(data.loadUnaligned(as: Int32.self))
            }
            offset += (size + 3) & ~3
        }
        return result
    }
}

/// Take the uptime reading before continuous time so elapsed awake time from
/// kernel arrival to read is a lower bound on time spent in the socket queue.
nonisolated struct ICMPClockSample: Sendable {
    let uptime: UInt64
    let continuous: TimeInterval
    let wall: TimeInterval

    static var now: Self {
        let wall = Date().timeIntervalSince1970
        let uptime = mach_absolute_time()
        return Self(uptime: uptime, continuous: ICMPProbe.continuousNow, wall: wall)
    }
}

nonisolated struct ICMPDeadline: Sendable {
    enum Arrival {
        case beforeStart
        case timely(rtt: Double?)
        case expired
    }

    let start: ICMPClockSample
    let timeout: TimeInterval
    var continuousEnd: TimeInterval { start.continuous + timeout }

    init(timeout: TimeInterval?, start: ICMPClockSample = .now) {
        self.start = start
        self.timeout = timeout ?? .infinity
    }

    func classify(_ packet: ICMPProbe.ControlInfo, read: ICMPClockSample) -> Arrival {
        let awakeMs = packet.receiveTime.flatMap { ICMPProbe.milliseconds(from: start.uptime, to: $0) }
        if packet.receiveTime != nil && awakeMs == nil { return .beforeStart }
        if let awakeMs, awakeMs > timeout * 1000 { return .expired }

        // The receive timestamp bounds RTT from below. Subtracting known awake
        // time in the socket queue from continuous elapsed time bounds it from above.
        let elapsed = read.continuous - start.continuous
        let queuedMs = packet.receiveTime.flatMap { ICMPProbe.milliseconds(from: $0, to: read.uptime) }
        let upperMs = elapsed * 1000 - (queuedMs ?? 0)
        // Wall and Mach clocks are sampled separately. Allow up to 1 ms of
        // skew when checking them, then constrain any RTT to the Mach bounds.
        let clockToleranceMs = 1.0
        let wallClocksAgree = abs((read.wall - start.wall) - elapsed) * 1000 <= clockToleranceMs
        if read.continuous > continuousEnd && upperMs > timeout * 1000 {
            // The wall timestamp can place arrival on either side of sleep.
            // Use the earlier cutoff to cover small backward clock adjustments.
            let cutoff = min(start.wall + timeout, read.wall - (read.continuous - continuousEnd))
            guard wallClocksAgree, let arrival = packet.wallTime, arrival <= cutoff else { return .expired }
        }

        guard let awakeMs, queuedMs != nil else { return .timely(rtt: nil) }
        // When the bounds agree to a microsecond, the uptime RTT is sufficient.
        if abs(upperMs - awakeMs) <= 0.001 { return .timely(rtt: awakeMs) }

        // Sleep may have preceded arrival or followed it. Use the kernel's wall
        // arrival only if the clocks stayed aligned and it fits the elapsed bounds.
        guard wallClocksAgree, let arrival = packet.wallTime, upperMs >= awakeMs else { return .timely(rtt: nil) }
        let wallMs = (arrival - start.wall) * 1000
        guard wallMs >= awakeMs - clockToleranceMs, wallMs <= upperMs + clockToleranceMs else { return .timely(rtt: nil) }
        return .timely(rtt: min(upperMs, max(awakeMs, wallMs)))
    }

    /// Go accepts positive whole milliseconds. Never round the command's
    /// remaining budget up, even when less than one millisecond remains.
    func bridgeTimeoutMilliseconds(waitTime: TimeInterval, now: TimeInterval) -> Int? {
        let remainingMs = floor((continuousEnd - now) * 1000)
        guard remainingMs >= 1 else { return nil }
        return Int(min(remainingMs, max(1, ceil(waitTime * 1000)), Double(Int32.max)))
    }

    func onExpiry(_ action: @escaping @Sendable () -> Void) -> Task<Void, Never>? {
        guard continuousEnd.isFinite else { return nil }
        return Task {
            while !Task.isCancelled {
                let remaining = continuousEnd - ICMPProbe.continuousNow
                if remaining <= 0 {
                    action()
                    return
                }
                try? await Task.sleep(for: .seconds(min(remaining, 3600)), clock: .continuous)
            }
        }
    }

    /// A blocking resolver can outlive cancellation. Return the first setup
    /// result or end the stream on timeout, without joining the losing task.
    func waitForSetup<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
        guard !Task.isCancelled, ICMPProbe.continuousNow < continuousEnd else { return nil }
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let setup = Task {
            guard !Task.isCancelled else { return }
            continuation.yield(await operation())
        }
        let timer = onExpiry { continuation.finish() }
        defer {
            continuation.finish()
            setup.cancel()
            timer?.cancel()
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        guard !Task.isCancelled, ICMPProbe.continuousNow < continuousEnd else { return nil }
        return result
    }
}

/// Keep the most recent send for each 16-bit ping sequence, including answered
/// probes so that repeated replies are distinguishable until the sequence is reused.
nonisolated struct PingProbeHistory {
    private struct Probe {
        let deadline: ICMPDeadline
        let identity: ICMPProbe.Identity
        let payloadSize: Int
        var received = false
    }

    private var probes: [UInt16: Probe] = [:]

    mutating func sent(sequence: UInt16, deadline: ICMPDeadline, identity: ICMPProbe.Identity, payloadSize: Int) {
        probes[sequence] = Probe(deadline: deadline, identity: identity, payloadSize: payloadSize)
    }

    func matches(_ quote: ICMPProbe.EchoQuote, in bytes: [UInt8]) -> Bool {
        guard let probe = probes[quote.sequence] else { return false }
        return quote.matches(probe.identity, sentSize: probe.payloadSize, in: bytes)
    }

    mutating func received(sequence: UInt16, identifier: UInt16, in bytes: [UInt8], payloadOffset: Int,
                           payloadSize: Int, arrival: ICMPProbe.ControlInfo, readAt: ICMPClockSample) -> (rtt: Double?, duplicate: Bool)? {
        guard let probe = probes[sequence], identifier == probe.identity.identifier, probe.payloadSize == payloadSize,
              probe.identity.matchesNonce(in: bytes, offset: payloadOffset, length: payloadSize) else { return nil }
        guard case .timely(let rtt) = probe.deadline.classify(arrival, read: readAt) else { return nil }
        probes[sequence]?.received = true
        return (rtt, probe.received)
    }
}
#endif
