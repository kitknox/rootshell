#if !targetEnvironment(macCatalyst)

import Foundation
import Darwin
import OSLog

// IPv6 socket option constants not exposed to Swift on iOS
nonisolated private let kIPV6_RECVHOPLIMIT: Int32 = 37
/// ICMP probe engine for mtr - sends probes at varying TTLs and parses
/// both Echo Reply and Time Exceeded responses.
@MtrActor
final class MtrProbeEngine {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "mtr-probe")

    // MARK: - Types

    enum ProbeResult: Sendable {
        case timeExceeded(hopIP: String, rtt: Double?, ttl: Int, seq: UInt16)
        case echoReply(hopIP: String, rtt: Double?, ttl: Int, seq: UInt16)
        case timeout(ttl: Int, seq: UInt16)
    }

    struct InFlightProbe: Sendable {
        let ttl: Int
        let identity: ICMPProbe.Identity
        let deadline: ICMPDeadline
        let size: Int
    }

    // MARK: - Properties

    let isIPv6: Bool
    private var socketFD: Int32 = -1
    private var targetIP = ""
    private var identity = ICMPProbe.Identity()
    private var checkedKernelID = false
    private var kernelIdentifier: UInt16?
    private var sequenceCounter: UInt16 = 0
    private var rotateIdentity = false
    private var inFlightProbes: [UInt16: InFlightProbe] = [:]

    private var recvBuf = [UInt8](repeating: 0, count: 65536)
    private var controlBuf = [UInt8](repeating: 0, count: 256)

    init(isIPv6: Bool) {
        self.isIPv6 = isIPv6
    }

    // MARK: - Socket Lifecycle

    func openSocket(targetIP: String, tos: Int = 0) -> Bool {
        self.targetIP = targetIP
        let proto = isIPv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, proto)
        guard socketFD >= 0 else { return false }

        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0,
              ICMPProbe.enableTimestamps(on: socketFD) else {
            closeSocket()
            return false
        }
        var on: Int32 = 1
        if isIPv6 {
            setsockopt(socketFD, IPPROTO_IPV6, kIPV6_RECVHOPLIMIT, &on, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        // TOS / Traffic Class
        if tos > 0 {
            var tosVal = Int32(tos)
            if isIPv6 {
                setsockopt(socketFD, IPPROTO_IPV6, IPV6_TCLASS, &tosVal, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(socketFD, IPPROTO_IP, IP_TOS, &tosVal, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        return true
    }

    func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    var isOpen: Bool { socketFD >= 0 }

    // MARK: - Sending Probes

    /// Send an ICMP echo request at the given TTL. Track only datagrams accepted by the socket.
    func sendProbe(ttl: Int, target: UnsafeMutablePointer<addrinfo>, packetSize: Int, bitPattern: Int, timeout: TimeInterval) -> Bool {
        // Set TTL for this probe
        var ttlVal = Int32(ttl)
        let level = isIPv6 ? IPPROTO_IPV6 : IPPROTO_IP
        let option = isIPv6 ? IPV6_UNICAST_HOPS : IP_TTL
        guard setsockopt(socketFD, level, option, &ttlVal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }

        if rotateIdentity {
            identity = ICMPProbe.Identity()
            rotateIdentity = false
        }
        let seq = sequenceCounter
        sequenceCounter &+= 1
        rotateIdentity = sequenceCounter == 0
        guard inFlightProbes[seq] == nil else {
            errno = ENOBUFS
            return false
        }

        // Build ICMP packet
        let headerSize = 8
        let totalSize = headerSize + packetSize
        var packet = [UInt8](repeating: 0, count: totalSize)

        // Type: Echo Request
        packet[0] = isIPv6 ? 128 : 8
        packet[1] = 0  // Code
        // Checksum placeholder
        packet[2] = 0
        packet[3] = 0
        // Identifier
        packet[4] = UInt8(identity.identifier >> 8)
        packet[5] = UInt8(identity.identifier & 0xFF)
        // Sequence number
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xFF)

        // Echoed nonce identifies the session even through NAT64.
        let payloadPrefixBytes = identity.writeNonce(into: &packet)

        // Fill remaining with bit pattern
        let dataStart = headerSize + payloadPrefixBytes
        let fillByte: UInt8
        if bitPattern > 255 {
            fillByte = UInt8.random(in: 0...255)
        } else {
            fillByte = UInt8(bitPattern & 0xFF)
        }
        for j in dataStart..<totalSize {
            packet[j] = fillByte
        }

        // IPv4 needs manual checksum
        if !isIPv6 {
            let cksum = ICMPProbe.checksum(packet)
            packet[2] = UInt8(cksum >> 8)
            packet[3] = UInt8(cksum & 0xFF)
        }

        let deadline = ICMPDeadline(timeout: timeout)
        let sent = sendto(
            socketFD,
            packet,
            totalSize,
            0,
            target.pointee.ai_addr,
            target.pointee.ai_addrlen
        )

        guard sent == totalSize else { return false }
        if !checkedKernelID {
            kernelIdentifier = ICMPProbe.localIdentifier(on: socketFD)
            checkedKernelID = true
        }
        var wireIdentity = identity
        wireIdentity.identifier = kernelIdentifier ?? identity.identifier
        inFlightProbes[seq] = InFlightProbe(ttl: ttl, identity: wireIdentity, deadline: deadline, size: packetSize)
        return true
    }

    // MARK: - Receiving Probes

    /// Drain queued datagrams at both ends of the window. An unrelated packet
    /// consumes one datagram, but does not end a drain or delay the next reply.
    func receiveProbes(timeout: TimeInterval) async -> [ProbeResult] {
        let deadline = ICMPProbe.continuousNow + timeout
        var results: [ProbeResult] = []
        while !Task.isCancelled {
            var count = 0
            while count < 256 {
                guard case .packet(let result) = receiveOnePacket() else { break }
                if let result { results.append(result) }
                count += 1
            }
            let remaining = deadline - ICMPProbe.continuousNow
            guard remaining > 0 else { break }
            if count == 256 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .seconds(min(0.005, remaining)))
            }
        }
        return results
    }

    func expireProbes(all: Bool = false) -> [ProbeResult] {
        let now = ICMPProbe.continuousNow
        var results: [ProbeResult] = []
        for (seq, probe) in inFlightProbes {
            guard all || now >= probe.deadline.continuousEnd else { continue }
            results.append(.timeout(ttl: probe.ttl, seq: seq))
            inFlightProbes.removeValue(forKey: seq)
        }
        return results
    }

    /// Whether any probes are still awaiting responses
    var hasInFlightProbes: Bool {
        !inFlightProbes.isEmpty
    }

    /// Clear all in-flight probes (for reset)
    func clearInFlight() {
        inFlightProbes.removeAll()
    }

    // MARK: - Private Receive

    private enum ReadResult {
        case empty
        case packet(ProbeResult?)
    }

    private func receiveOnePacket() -> ReadResult {
        guard socketFD >= 0 else { return .empty }

        var srcAddr = sockaddr_storage()
        var iov = iovec()
        var msg = msghdr()

        var readAt: ICMPClockSample?
        let (bytesRead, controlInfo): (Int, ICMPProbe.ControlInfo) = recvBuf.withUnsafeMutableBufferPointer { bufPtr in
            controlBuf.withUnsafeMutableBufferPointer { ctlPtr in
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            guard let recvBase = bufPtr.baseAddress,
                                  let controlBase = ctlPtr.baseAddress else {
                                return (-1, ICMPProbe.ControlInfo())
                            }

                            iovPtr.pointee.iov_base = UnsafeMutableRawPointer(recvBase)
                            iovPtr.pointee.iov_len = bufPtr.count

                            msg.msg_name = UnsafeMutableRawPointer(sockPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = UnsafeMutableRawPointer(controlBase)
                            msg.msg_controllen = socklen_t(ctlPtr.count)

                            let n = recvmsg(socketFD, &msg, 0)
                            if n >= 8 { readAt = .now }
                            let info = ICMPProbe.controlInfo(msg: msg, capacity: ctlPtr.count)
                            return (n, info)
                        }
                    }
                }
            }
        }

        guard bytesRead >= 0 else { return .empty }
        guard let readAt, bytesRead >= 8 else { return .packet(nil) }

        // Handle IPv4 header prefix
        var icmpOffset = 0
        if !isIPv6 {
            let versionNibble = (recvBuf[0] & 0xF0) >> 4
            if versionNibble == 4 {
                icmpOffset = Int(recvBuf[0] & 0x0F) * 4
                guard icmpOffset >= 20 else { return .packet(nil) }
            }
        }

        guard bytesRead >= icmpOffset + 8 else { return .packet(nil) }

        let icmpType = recvBuf[icmpOffset]
        let sourceIP = extractSourceAddress(&srcAddr)

        // Echo Reply: IPv4 type 0, IPv6 type 129
        let echoReplyType: UInt8 = isIPv6 ? 129 : 0
        // Time Exceeded: IPv4 type 11, IPv6 type 3
        let timeExceededType: UInt8 = isIPv6 ? 3 : 11

        let seq: UInt16
        let probe: InFlightProbe
        if icmpType == echoReplyType && sourceIP == targetIP {
            let identifier = UInt16(recvBuf[icmpOffset + 4]) << 8 | UInt16(recvBuf[icmpOffset + 5])
            seq = UInt16(recvBuf[icmpOffset + 6]) << 8 | UInt16(recvBuf[icmpOffset + 7])
            let dataOffset = icmpOffset + 8
            let dataLen = bytesRead - dataOffset
            guard let match = inFlightProbes[seq], match.size == dataLen,
                  match.identity.identifier == identifier, recvBuf[icmpOffset + 1] == 0,
                  match.identity.matchesNonce(in: recvBuf, offset: dataOffset, length: dataLen) else { return .packet(nil) }
            probe = match
        } else if icmpType == timeExceededType && recvBuf[icmpOffset + 1] == 0 {
            guard let quote = ICMPProbe.EchoQuote(in: recvBuf, ipOffset: icmpOffset + 8, end: bytesRead),
                  let match = inFlightProbes[quote.sequence],
                  quote.matches(match.identity, sentSize: match.size, in: recvBuf) else { return .packet(nil) }
            seq = quote.sequence
            probe = match
        } else {
            return .packet(nil)
        }

        switch probe.deadline.classify(controlInfo, read: readAt) {
        case .beforeStart:
            return .packet(nil)
        case .expired:
            inFlightProbes.removeValue(forKey: seq)
            return .packet(.timeout(ttl: probe.ttl, seq: seq))
        case .timely(let rtt):
            inFlightProbes.removeValue(forKey: seq)
            if icmpType == echoReplyType {
                return .packet(.echoReply(hopIP: sourceIP, rtt: rtt, ttl: probe.ttl, seq: seq))
            }
            return .packet(.timeExceeded(hopIP: sourceIP, rtt: rtt, ttl: probe.ttl, seq: seq))
        }
    }

    // MARK: - DNS Resolution

    nonisolated func resolveHost(_ host: String, family: MtrCommandParser.MtrConfig.AddressFamily) async -> UnsafeMutablePointer<addrinfo>? {
        let aiFamily: Int32
        switch family {
        case .ipv4: aiFamily = AF_INET
        case .ipv6: aiFamily = AF_INET6
        case .unspecified: aiFamily = AF_UNSPEC
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = aiFamily
                hints.ai_socktype = SOCK_DGRAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if status != 0 {
                    MtrProbeEngine.logger.error("getaddrinfo failed for \(host): \(String(cString: gai_strerror(status)))")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    func extractIPAddress(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let rawAddress = addrInfo.pointee.ai_addr else { return "" }

        if addrInfo.pointee.ai_family == AF_INET6 {
            var addr6 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee
            guard inet_ntop(AF_INET6, &addr6.sin6_addr, &ipStr, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
        } else {
            var addr4 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in.self).pointee
            guard inet_ntop(AF_INET, &addr4.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        }

        return String(cString: ipStr)
    }

    func determineIsIPv6(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> Bool {
        addrInfo.pointee.ai_family == AF_INET6
    }

    // MARK: - NAT64 Support

    /// NAT64 prefix info detected via RFC 7050 / RFC 6052.
    struct NAT64Prefix: Sendable {
        /// Full 16 bytes of the synthesized address with the well-known IPv4 zeroed out,
        /// used as a mask.  Only the prefix bits are non-zero.
        let prefixBytes: [UInt8]
        /// RFC 6052 prefix length in bits (32, 40, 48, 56, 64, or 96).
        let prefixBits: Int
        /// Byte offset where the IPv4 address is embedded (per RFC 6052 table).
        let ipv4Offset: Int
        /// First byte index after the IPv4 + u-octet region; bytes [suffixStart..<16] must be zero.
        let suffixStart: Int
    }

    /// RFC 7050 well-known IPv4 addresses for ipv4only.arpa.
    private nonisolated static let wka170: [UInt8] = [192, 0, 0, 170] // c0:00:00:aa
    private nonisolated static let wka171: [UInt8] = [192, 0, 0, 171] // c0:00:00:ab

    /// RFC 6052 § 2.2: Valid prefix lengths, IPv4 embedding offsets, and suffix start.
    /// Byte 8 is the reserved "u" octet; IPv4 bytes skip it for prefixes shorter than /96.
    /// suffixStart is the first byte after the IPv4 + u-octet region that must be zero.
    private nonisolated static let rfc6052Layouts: [(prefixBits: Int, ipv4Offset: Int, suffixStart: Int)] = [
        (32, 4, 9),    // /32:  prefix[0-3], IPv4[4-7], u[8], suffix[9-15]
        (40, 5, 10),   // /40:  prefix[0-4], IPv4[5-7,9], u[8], suffix[10-15]
        (48, 6, 11),   // /48:  prefix[0-5], IPv4[6-7,9-10], u[8], suffix[11-15]
        (56, 7, 12),   // /56:  prefix[0-6], IPv4[7,9-11], u[8], suffix[12-15]
        (64, 9, 13),   // /64:  prefix[0-7], u[8], IPv4[9-12], suffix[13-15]
        (96, 12, 16),  // /96:  prefix[0-11], IPv4[12-15], no suffix
    ]

    /// Detect the network's NAT64 prefix using RFC 7050 (DNS64 discovery via ipv4only.arpa).
    /// Runs DNS resolution off the main thread. Supports all RFC 6052 prefix lengths.
    /// Cross-validates both well-known addresses (192.0.0.170 and .171) when available.
    nonisolated static func detectNAT64Prefix() async -> NAT64Prefix? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET6
                hints.ai_socktype = SOCK_DGRAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo("ipv4only.arpa", nil, &hints, &result)
                guard status == 0, let head = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(head) }

                // Walk the full linked list, collecting prefix from each WKA independently.
                var prefix170: NAT64Prefix?
                var prefix171: NAT64Prefix?

                var cursor: UnsafeMutablePointer<addrinfo>? = head
                while let entry = cursor {
                    defer { cursor = entry.pointee.ai_next }

                    guard entry.pointee.ai_family == AF_INET6,
                          let rawAddr = entry.pointee.ai_addr else { continue }

                    let addr6 = UnsafeRawPointer(rawAddr)
                        .assumingMemoryBound(to: sockaddr_in6.self).pointee
                    var sin6 = addr6.sin6_addr
                    let bytes: [UInt8] = withUnsafeBytes(of: &sin6) { Array($0) }
                    guard bytes.count == 16 else { continue }

                    if prefix170 == nil, let p = extractPrefix(from: bytes, wka: wka170) {
                        prefix170 = p
                    }
                    if prefix171 == nil, let p = extractPrefix(from: bytes, wka: wka171) {
                        prefix171 = p
                    }
                }

                // Cross-validate: if both WKAs matched, their prefixes must agree.
                if let p170 = prefix170, let p171 = prefix171 {
                    guard p170.prefixBytes == p171.prefixBytes,
                          p170.prefixBits == p171.prefixBits else {
                        // Inconsistent results — reject (possibly poisoned DNS64)
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: p170)
                } else {
                    // Only one (or neither) WKA present — return what we have
                    continuation.resume(returning: prefix170 ?? prefix171)
                }
            }
        }
    }

    /// Try to find the well-known IPv4 address in `bytes` at each RFC 6052 layout position.
    /// Also validates that the "u" octet and suffix bytes are zero per RFC 6052.
    private nonisolated static func extractPrefix(from bytes: [UInt8], wka: [UInt8]) -> NAT64Prefix? {
        for layout in rfc6052Layouts {
            if matchesWKA(bytes: bytes, wka: wka, layout: layout) {
                // Validate "u" octet (byte 8) is zero for prefixes < /96
                if layout.prefixBits < 96, bytes[8] != 0 { continue }
                // Validate suffix bytes are zero
                if (layout.suffixStart..<16).contains(where: { bytes[$0] != 0 }) { continue }

                // Build prefix mask: copy the address, zero out the IPv4 and reserved byte 8
                var prefix = bytes
                writeIPv4(into: &prefix, ipv4: [0, 0, 0, 0], layout: layout)
                if layout.prefixBits < 96 { prefix[8] = 0 }
                return NAT64Prefix(
                    prefixBytes: prefix,
                    prefixBits: layout.prefixBits,
                    ipv4Offset: layout.ipv4Offset,
                    suffixStart: layout.suffixStart
                )
            }
        }
        return nil
    }

    /// Check whether the well-known IPv4 bytes appear at the expected position per RFC 6052.
    /// Byte 8 is reserved ("u" octet) and skipped for prefix lengths shorter than /96.
    private nonisolated static func matchesWKA(bytes: [UInt8], wka: [UInt8],
                                                layout: (prefixBits: Int, ipv4Offset: Int, suffixStart: Int)) -> Bool {
        var wi = 0
        for byteIdx in layout.ipv4Offset..<16 {
            if byteIdx == 8 && layout.prefixBits < 96 { continue } // skip "u" octet
            guard wi < 4 else { break }
            guard bytes[byteIdx] == wka[wi] else { return false }
            wi += 1
        }
        return wi == 4
    }

    /// Write 4 IPv4 bytes into an IPv6 address at the RFC 6052 layout position.
    private nonisolated static func writeIPv4(into bytes: inout [UInt8], ipv4: [UInt8],
                                               layout: (prefixBits: Int, ipv4Offset: Int, suffixStart: Int)) {
        var wi = 0
        for byteIdx in layout.ipv4Offset..<16 {
            if byteIdx == 8 && layout.prefixBits < 96 { continue }
            guard wi < 4 else { break }
            bytes[byteIdx] = ipv4[wi]
            wi += 1
        }
    }

    /// Extract the embedded IPv4 address from a NAT64-synthesized IPv6 address.
    /// Validates prefix match, "u" octet, and suffix per RFC 6052 before translating.
    nonisolated static func nat64ToIPv4(ipv6: String, prefix: NAT64Prefix) -> String? {
        var addr6 = in6_addr()
        guard inet_pton(AF_INET6, ipv6, &addr6) == 1 else { return nil }

        let bytes: [UInt8] = withUnsafeBytes(of: &addr6) { Array($0) }
        guard bytes.count == 16 else { return nil }

        // Verify prefix bytes match
        let prefixByteCount = prefix.prefixBits / 8
        for i in 0..<prefixByteCount {
            guard bytes[i] == prefix.prefixBytes[i] else { return nil }
        }

        // Verify "u" octet (byte 8) is zero for prefixes < /96
        if prefix.prefixBits < 96, bytes[8] != 0 { return nil }

        // Verify suffix bytes are zero
        for i in prefix.suffixStart..<16 {
            guard bytes[i] == 0 else { return nil }
        }

        // Extract IPv4 bytes respecting the RFC 6052 layout (skip byte 8 "u" octet)
        var ipv4Bytes = [UInt8](repeating: 0, count: 4)
        var wi = 0
        for byteIdx in prefix.ipv4Offset..<16 {
            if byteIdx == 8 && prefix.prefixBits < 96 { continue }
            guard wi < 4 else { break }
            ipv4Bytes[wi] = bytes[byteIdx]
            wi += 1
        }
        guard wi == 4 else { return nil }

        var addr4 = in_addr()
        addr4.s_addr = UInt32(ipv4Bytes[0]) | UInt32(ipv4Bytes[1]) << 8
            | UInt32(ipv4Bytes[2]) << 16 | UInt32(ipv4Bytes[3]) << 24
        var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr4, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: ipStr)
    }

    private func extractSourceAddress(_ storage: inout sockaddr_storage) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = storage.ss_family

        if family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr6Ptr in
                    var addr = addr6Ptr.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &ipStr, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                        return "?"
                    }
                    return String(cString: ipStr)
                }
            }
        }

        if family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr4Ptr in
                    var addr = addr4Ptr.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else {
                        return "?"
                    }
                    return String(cString: ipStr)
                }
            }
        }

        return "?"
    }
}

#endif // !targetEnvironment(macCatalyst)
