import Darwin
import Foundation
import XCTest

final class HerdrControlShutdownTests: XCTestCase {
    /// A small send buffer holds the first large JSON line partway through
    /// write(). Seeing it at the peer establishes that the writer owns it.
    private func makeSocketPair() throws -> (FileDescriptorBytePipe, FileHandle) {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        var capacity: Int32 = 4096
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (FileDescriptorBytePipe(fd: fds[0]), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    private func waitForWrite(at peer: FileHandle) async throws {
        try await Task.detached {
            var pfd = pollfd(fd: peer.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 5000) == 1, pfd.revents & Int16(POLLIN) != 0 else {
                throw POSIXError(.ETIMEDOUT)
            }
        }.value
    }

    private func openChannel(pipe: FileDescriptorBytePipe, peer: FileHandle,
                             onClosed: @escaping @Sendable (Error?) -> Void = { _ in }) async throws -> HerdrControlChannel {
        let opened = #"{"id":"open","result":{"connection_id":1,"boot_id":"test","version":"0.9.5","protocol":3,"capabilities":{"terminal_control_stream":3}}}"#
        try peer.write(contentsOf: Data((opened + "\n").utf8))
        let channel = HerdrControlChannel(pipe: pipe, onInbound: { _ in }, onClosed: onClosed)
        _ = try await channel.open()
        return channel
    }

    func testQuitFinishesCurrentLineAndSkipsQueuedInput() async throws {
        let (pipe, peer) = try makeSocketPair()
        let channel = try await openChannel(pipe: pipe, peer: peer)

        let payload = String(repeating: "x", count: 256 * 1024)
        let first = Task {
            try await channel.request("first", ["payload": payload])
        }
        try await waitForWrite(at: peer)
        for _ in 0..<64 {
            channel.sendInput(attachId: "pane", bytes: Data([97]))
        }

        let closing = Task { await channel.close() }
        // close() fails outstanding requests as soon as it stops admitting
        // work. Only then let the peer drain the partially written line.
        do {
            _ = try await first.value
            XCTFail("The peer never answered this request")
        } catch HerdrChannelError.closed {}
        catch { XCTFail("Expected close to release the request, got \(error)") }

        let wire = try await Task.detached { try peer.readToEnd() }.value
        await closing.value
        let lines = try XCTUnwrap(wire).split(separator: 0x0a)
        let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(records.compactMap { $0["method"] as? String }, ["first", "control.close"])
        XCTAssertEqual((records.first?["params"] as? [String: String])?["payload"], payload)
    }

    func testReaderEOFWakesWriterInPartialLine() async throws {
        let (pipe, peer) = try makeSocketPair()
        defer { try? peer.close() }
        let closed = expectation(description: "reader observed EOF")
        let channel = try await openChannel(pipe: pipe, peer: peer) { error in
            XCTAssertNil(error)
            closed.fulfill()
        }
        channel.sendInput(attachId: "pane", bytes: Data(repeating: 120, count: 512 * 1024))
        try await waitForWrite(at: peer)
        XCTAssertEqual(Darwin.shutdown(peer.fileDescriptor, SHUT_WR), 0)
        await fulfillment(of: [closed], timeout: 5)
        let tornDown = expectation(description: "EOF finished tearing down the pipe")
        Task {
            await channel.close()
            tornDown.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [tornDown], timeout: 2) == .completed else {
            return XCTFail("Teardown waited for the peer to drain the socket")
        }
        let wire = try XCTUnwrap(peer.readToEnd())
        XCTAssertFalse(wire.isEmpty)
        XCTAssertFalse(wire.contains(0x0a), "EOF should interrupt the blocked writer")
    }

    func testPeerEOFDuringGracefulCloseInterruptsBlockedWrite() async throws {
        try await assertGracefulCloseCanBeInterrupted { _, peer in
            XCTAssertEqual(Darwin.shutdown(peer.fileDescriptor, SHUT_WR), 0)
        }
    }

    func testAbortDuringGracefulCloseInterruptsBlockedWrite() async throws {
        try await assertGracefulCloseCanBeInterrupted { channel, _ in
            await channel.abort()
        }
    }

    private func assertGracefulCloseCanBeInterrupted(
        _ interrupt: @escaping (HerdrControlChannel, FileHandle) async -> Void
    ) async throws {
        let (pipe, peer) = try makeSocketPair()
        defer { try? peer.close() }
        let channel = try await openChannel(pipe: pipe, peer: peer) { _ in
            XCTFail("A deliberate close should not trigger reconnection")
        }
        let request = Task {
            try await channel.request("blocked", ["payload": String(repeating: "x", count: 256 * 1024)])
        }
        try await waitForWrite(at: peer)
        let closed = expectation(description: "graceful close completed without draining the peer")
        Task {
            await channel.close()
            closed.fulfill()
        }
        // The pending request fails only after graceful close has begun.
        do {
            _ = try await request.value
            XCTFail("Expected the pending request to fail")
        } catch HerdrChannelError.closed {}
        Task { await interrupt(channel, peer) }
        await fulfillment(of: [closed], timeout: 2)
    }

    func testCloseWakesBlockedIOAndRejectsLaterWrites() async throws {
        let (pipe, peer) = try makeSocketPair()
        defer { try? peer.close() }
        let payload = Data(repeating: 120, count: 512 * 1024)
        let read = Task { try await pipe.read(maxBytes: 1) }
        let writing = Task { try await pipe.write(payload) }
        try await waitForWrite(at: peer)
        let queued = Task { try await pipe.write(Data([121])) }

        let finished = expectation(description: "both closes and all socket I/O finished")
        let results = Task {
            async let closing: Void = pipe.close()
            await pipe.close()
            await closing
            let late = Task { try await pipe.write(Data([122])) }
            let readResult = await read.result
            let writeResults = await [writing.result, queued.result, late.result]
            finished.fulfill()
            return (readResult, writeResults)
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 2) == .completed else {
            // Returning closes the peer and releases any blocked syscalls.
            return XCTFail("Closing the pipe did not release blocked I/O within two seconds")
        }
        let (readResult, writeResults) = await results.value
        XCTAssertNil(try readResult.get())
        for result in writeResults {
            do {
                try result.get()
                XCTFail("Write to the shut-down socket succeeded")
            } catch let error as POSIXError {
                XCTAssertEqual(error.code, .EPIPE)
            }
        }
    }
}
