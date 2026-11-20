#if !targetEnvironment(macCatalyst)
import Darwin
import XCTest

final class ICMPProbeTests: XCTestCase {
    private func awakeSample(_ uptime: UInt64) -> ICMPClockSample {
        let elapsed = ICMPProbe.milliseconds(from: 0, to: uptime)! / 1000
        return ICMPClockSample(uptime: uptime, continuous: elapsed, wall: 1000 + elapsed)
    }

    func testShortProbesRequireMatchingSendAndUseKernelTime() throws {
        let identity = ICMPProbe.Identity()
        var history = PingProbeHistory()
        var packet = [UInt8](repeating: 0, count: 9)
        XCTAssertEqual(identity.writeNonce(into: &packet), 1)
        let sent = mach_absolute_time()
        let arrival = sent + 1000
        history.sent(sequence: 4, deadline: ICMPDeadline(timeout: 1, start: awakeSample(sent)), identity: identity, payloadSize: 1)
        func reply(sequence: UInt16 = 4, id: UInt16, size: Int = 1, at time: UInt64?) -> Double? {
            history.received(sequence: sequence, identifier: id, in: packet, payloadOffset: 8,
                             payloadSize: size, arrival: .init(receiveTime: time), readAt: awakeSample(arrival))?.rtt
        }
        XCTAssertNil(reply(sequence: 5, id: identity.identifier, at: arrival))
        XCTAssertNil(reply(id: identity.identifier &+ 1, at: arrival))
        XCTAssertNil(reply(id: identity.identifier, size: 0, at: arrival))
        XCTAssertNil(reply(id: identity.identifier, at: sent - 1))
        XCTAssertNil(reply(id: identity.identifier, at: UInt64.max))
        packet[8] ^= 1
        XCTAssertNil(reply(id: identity.identifier, at: arrival))
        packet[8] ^= 1
        XCTAssertEqual(reply(id: identity.identifier, at: arrival), ICMPProbe.milliseconds(from: sent, to: arrival))
    }

    func testMissingTimestampUsesReadTimeOnlyForExpiry() throws {
        let identity = ICMPProbe.Identity()
        var history = PingProbeHistory()
        history.sent(sequence: 1, deadline: ICMPDeadline(timeout: 0.1, start: awakeSample(100)), identity: identity, payloadSize: 0)
        func reply(arrival: UInt64?, readAt: UInt64) -> (rtt: Double?, duplicate: Bool)? {
            history.received(sequence: 1, identifier: identity.identifier, in: [], payloadOffset: 0,
                             payloadSize: 0, arrival: .init(receiveTime: arrival), readAt: awakeSample(readAt))
        }
        XCTAssertNil(reply(arrival: nil, readAt: 5_000_000_000))
        let untimed = try XCTUnwrap(reply(arrival: nil, readAt: 200))
        XCTAssertNil(untimed.rtt)
        XCTAssertFalse(untimed.duplicate)
        let queued = try XCTUnwrap(reply(arrival: 150, readAt: 5_000_000_000))
        XCTAssertEqual(queued.rtt, ICMPProbe.milliseconds(from: 100, to: 150))
        XCTAssertTrue(queued.duplicate)
    }

    func testDuplicateDetectionSurvivesLongRunsAndWireSequenceReuse() throws {
        var history = PingProbeHistory()
        var identity = ICMPProbe.Identity()
        let original = identity.identifier
        for n in 0...65536 {
            let seq = UInt16(truncatingIfNeeded: n)
            if n == 65536 { identity = ICMPProbe.Identity() }
            history.sent(sequence: seq, deadline: ICMPDeadline(timeout: 1, start: awakeSample(20)), identity: identity, payloadSize: 0)
            if n == 65536 {
                XCTAssertNil(history.received(sequence: seq, identifier: original, in: [], payloadOffset: 0,
                                              payloadSize: 0, arrival: .init(receiveTime: 30), readAt: awakeSample(40)))
            }
            let reply = try XCTUnwrap(history.received(sequence: seq, identifier: identity.identifier, in: [],
                                                       payloadOffset: 0, payloadSize: 0, arrival: .init(receiveTime: 30), readAt: awakeSample(40)))
            XCTAssertFalse(reply.duplicate)
        }
        let duplicate = try XCTUnwrap(history.received(sequence: 0, identifier: identity.identifier, in: [],
                                                       payloadOffset: 0, payloadSize: 0, arrival: .init(), readAt: awakeSample(40)))
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertNil(duplicate.rtt)
    }

    func testQuotedRequestsWithAndWithoutPayload() throws {
        let identity = ICMPProbe.Identity()
        var echo = [UInt8](repeating: 0, count: 16)
        echo[0] = 8
        echo[4] = UInt8(identity.identifier >> 8)
        echo[5] = UInt8(truncatingIfNeeded: identity.identifier)
        echo[7] = 7
        _ = identity.writeNonce(into: &echo)
        var ip = [UInt8](repeating: 0, count: 24)
        ip[0] = 0x46 // Includes an IPv4 option.
        ip[9] = UInt8(IPPROTO_ICMP)
        var bytes = ip + echo
        let short = try XCTUnwrap(ICMPProbe.EchoQuote(in: bytes, ipOffset: 0, end: 32))
        XCTAssertEqual(short.sequence, 7)
        XCTAssertTrue(short.matches(identity, sentSize: 8, in: bytes))
        bytes[28] ^= 1 // NAT can rewrite an ID. Only a full nonce identifies that quote.
        let foreign = try XCTUnwrap(ICMPProbe.EchoQuote(in: bytes, ipOffset: 0, end: 32))
        XCTAssertFalse(foreign.matches(identity, sentSize: 8, in: bytes))
        let full = try XCTUnwrap(ICMPProbe.EchoQuote(in: bytes, ipOffset: 0, end: bytes.count))
        XCTAssertTrue(full.matches(identity, sentSize: 8, in: bytes))
        XCTAssertNil(ICMPProbe.EchoQuote(in: bytes, ipOffset: 0, end: 31))
    }

    func testPerProbeTimeoutAcrossSleep() throws {
        let start = ICMPClockSample(uptime: 100, continuous: 10, wall: 1000)
        let deadline = ICMPDeadline(timeout: 0.1, start: start)
        let identity = ICMPProbe.Identity()
        var history = PingProbeHistory()
        history.sent(sequence: 1, deadline: deadline, identity: identity, payloadSize: 0)
        // Only 20 ms of the five-second interval elapsed while awake.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let tenMs = UInt64(10_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        let wake = ICMPClockSample(uptime: start.uptime + 2 * tenMs, continuous: 15, wall: 1005)
        func receive(_ arrival: ICMPProbe.ControlInfo) -> (rtt: Double?, duplicate: Bool)? {
            history.received(sequence: 1, identifier: identity.identifier, in: [], payloadOffset: 0,
                             payloadSize: 0, arrival: arrival, readAt: wake)
        }
        XCTAssertNil(receive(.init(receiveTime: wake.uptime, wallTime: 1005)))
        XCTAssertNil(receive(.init(receiveTime: wake.uptime)))
        XCTAssertNil(receive(.init()))
        let queued = try XCTUnwrap(receive(.init(receiveTime: start.uptime + tenMs, wallTime: 1000.01)))
        XCTAssertFalse(queued.duplicate)
        XCTAssertEqual(try XCTUnwrap(queued.rtt), 10, accuracy: 0.001)
    }

    func testRTTAcrossSleepCountsOnlyTimeBeforeKernelArrival() throws {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let tenMs = UInt64(10_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        let start = ICMPClockSample(uptime: 100, continuous: 10, wall: 1000)
        // Five seconds asleep and 40 ms awake, including 20 ms queued after arrival.
        let read = ICMPClockSample(uptime: start.uptime + 4 * tenMs, continuous: 15.04, wall: 1005.04)
        let uptimeArrival = start.uptime + 2 * tenMs
        func rtt(wallArrival: Double?, readAt: ICMPClockSample, timeout: Double = 10) -> Double? {
            let deadline = ICMPDeadline(timeout: timeout, start: start)
            let packet = ICMPProbe.ControlInfo(receiveTime: uptimeArrival, wallTime: wallArrival)
            guard case .timely(let rtt) = deadline.classify(packet, read: readAt) else {
                XCTFail("Expected the reply to count as received")
                return nil
            }
            return rtt
        }
        XCTAssertEqual(try XCTUnwrap(rtt(wallArrival: 1005.02, readAt: read)), 5020, accuracy: 0.001)
        // Separate wall and uptime reads can put wall arrival a few microseconds outside the bound.
        XCTAssertEqual(try XCTUnwrap(rtt(wallArrival: 1005.020005, readAt: read)), 5020, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rtt(wallArrival: 1005.02, readAt: read, timeout: 5.03)), 5020, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rtt(wallArrival: 1000.02, readAt: read)), 20, accuracy: 0.001)
        XCTAssertNil(rtt(wallArrival: nil, readAt: read))
        XCTAssertNil(rtt(wallArrival: 1005.5, readAt: read))
        let stepped = ICMPClockSample(uptime: read.uptime, continuous: read.continuous, wall: 998)
        XCTAssertNil(rtt(wallArrival: 997.98, readAt: stepped))
    }

    func testCommandDeadlineWithClockAdjustments() {
        let start = ICMPClockSample(uptime: 100, continuous: 100, wall: 1000)
        let deadline = ICMPDeadline(timeout: 1, start: start)
        func accepts(arrival: Double?, readWall: Double, readContinuous: Double = 110) -> Bool {
            let read = ICMPClockSample(uptime: 1000, continuous: readContinuous, wall: readWall)
            if case .timely = deadline.classify(.init(wallTime: arrival), read: read) { return true }
            return false
        }
        XCTAssertTrue(accepts(arrival: 1001, readWall: 1010))
        XCTAssertFalse(accepts(arrival: 1001.1, readWall: 1010))
        XCTAssertFalse(accepts(arrival: nil, readWall: 1010))
        XCTAssertTrue(accepts(arrival: nil, readWall: 999, readContinuous: 100.5))
        // A late packet looks early after a clock step, including a sub-ms step.
        XCTAssertFalse(accepts(arrival: 1000.5, readWall: 1000.6))
        XCTAssertFalse(accepts(arrival: 1000.9999, readWall: 1009.9995))
    }

    func testTailnetProbeBudgetAtQueueStart() {
        let start = ICMPClockSample(uptime: 0, continuous: 10, wall: 1000)
        let deadline = ICMPDeadline(timeout: 1, start: start)
        XCTAssertEqual(deadline.bridgeTimeoutMilliseconds(waitTime: 3, now: 10.75), 250)
        XCTAssertEqual(deadline.bridgeTimeoutMilliseconds(waitTime: 0.125, now: 10.75), 125)
        XCTAssertNil(deadline.bridgeTimeoutMilliseconds(waitTime: 3, now: 10.9995))
        XCTAssertNil(deadline.bridgeTimeoutMilliseconds(waitTime: 3, now: 11))
        XCTAssertNil(deadline.bridgeTimeoutMilliseconds(waitTime: 3, now: 12))
        let unlimited = ICMPDeadline(timeout: nil, start: start)
        XCTAssertEqual(unlimited.bridgeTimeoutMilliseconds(waitTime: 0.0005, now: 12), 1)
        XCTAssertEqual(unlimited.bridgeTimeoutMilliseconds(waitTime: .greatestFiniteMagnitude, now: 12), Int(Int32.max))
    }

    func testSetupTimeoutReleasesCommandWhileResolverIsStillWaiting() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let returned = expectation(description: "command finished before the resolver was released")
        Task {
            let deadline = ICMPDeadline(timeout: 0.05)
            let result = await deadline.waitForSetup {
                // Like getaddrinfo, the lookup waits independently of caller cancellation.
                await Task.detached {
                    var iterator = gate.makeAsyncIterator()
                    _ = await iterator.next()
                }.value
                return "resolved"
            }
            XCTAssertNil(result)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
    }

    func testDarwinArrivalTimestampsAndHopLimit() {
        var bytes = [UInt8]()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) } }
        append(cmsghdr(cmsg_len: 20, cmsg_level: SOL_SOCKET, cmsg_type: SCM_TIMESTAMP_MONOTONIC))
        append(UInt64(123456))
        let wall = timeval(tv_sec: 1000, tv_usec: 250_000)
        append(cmsghdr(cmsg_len: socklen_t(MemoryLayout<cmsghdr>.size + MemoryLayout<timeval>.size),
                       cmsg_level: SOL_SOCKET, cmsg_type: SCM_TIMESTAMP))
        append(wall)
        append(cmsghdr(cmsg_len: 16, cmsg_level: IPPROTO_IPV6, cmsg_type: 47))
        append(Int32(64))
        bytes.withUnsafeMutableBytes { buffer in
            var msg = msghdr()
            msg.msg_control = buffer.baseAddress
            msg.msg_controllen = socklen_t(buffer.count)
            let info = ICMPProbe.controlInfo(msg: msg, capacity: buffer.count)
            XCTAssertEqual(info.ttl, 64)
            XCTAssertEqual(info.receiveTime, 123456)
            XCTAssertEqual(info.wallTime, 1000.25)
        }
    }
}
#endif
