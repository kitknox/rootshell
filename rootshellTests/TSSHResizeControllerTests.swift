import XCTest

final class TSSHResizeControllerTests: XCTestCase {
    private typealias Size = TSSHResizeController.Size

    @MainActor
    func testUnchangedLayoutIsSkippedOnlyAfterSuccessfulSend() async {
        var received: [Size] = []
        let controller = TSSHResizeController { received.append($0) }
        let size = Size(cols: 80, rows: 24)
        await controller.request(size)?.value
        XCTAssertNil(controller.request(size))
        XCTAssertEqual(received, [size])
    }

    @MainActor
    func testFailedWindowChangeRetriesIdenticalDimensionsOnRecovery() async {
        var attempts = 0
        var remote: Size?
        let controller = TSSHResizeController { size in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            remote = size
        }
        let size = Size(cols: 42, rows: 30)
        await controller.request(size)?.value
        XCTAssertNil(remote)
        await controller.request(size)?.value
        XCTAssertEqual(remote, size)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testRotationDuringInFlightResizeEndsAtLatestLayout() async {
        var received: [Size] = []
        var unblock: CheckedContinuation<Void, Never>?
        let controller = TSSHResizeController { size in
            received.append(size)
            if received.count == 1 {
                await withCheckedContinuation { unblock = $0 }
            }
        }
        let first = Size(cols: 80, rows: 24)
        let final = Size(cols: 42, rows: 50)
        let task = controller.request(first)
        while unblock == nil { await Task.yield() }
        controller.request(.init(cols: 100, rows: 20))
        controller.request(final)
        unblock?.resume()
        await task?.value
        XCTAssertEqual(received, [first, final])
    }

    @MainActor
    func testReconnectForcesRedrawEvenAtUnchangedDimensions() async {
        var received: [Size] = []
        let controller = TSSHResizeController { received.append($0) }
        let size = Size(cols: 80, rows: 24)
        await controller.request(size)?.value
        await controller.request(size, forceRedraw: true)?.value
        XCTAssertEqual(received, [size, Size(cols: 79, rows: 24), size])
    }

    @MainActor
    func testFailedFinalRedrawSizeIsRestoredOnRetry() async {
        var received: [Size] = []
        var fail = true
        let size = Size(cols: 80, rows: 24)
        let controller = TSSHResizeController { next in
            if next == size && fail {
                fail = false
                throw URLError(.networkConnectionLost)
            }
            received.append(next)
        }
        await controller.request(size, forceRedraw: true)?.value
        await controller.request(size)?.value
        XCTAssertEqual(received.last, size)
        XCTAssertNil(controller.request(size))
    }

    @MainActor
    func testReplacingPTYDiscardsOldAcknowledgement() async {
        var received: [Size] = []
        var unblock: CheckedContinuation<Void, Never>?
        let controller = TSSHResizeController { size in
            received.append(size)
            if received.count == 1 {
                await withCheckedContinuation { unblock = $0 }
            }
        }
        let old = Size(cols: 80, rows: 24)
        let current = Size(cols: 42, rows: 50)
        let oldTask = controller.request(old)
        while unblock == nil { await Task.yield() }
        controller.reset()
        await controller.request(current)?.value
        unblock?.resume()
        await oldTask?.value
        XCTAssertNil(controller.request(current))
        XCTAssertEqual(received, [old, current])
    }

    @MainActor
    func testReplacingPTYCancelsOldRedrawBeforeRestoringItsSize() async {
        var received: [Size] = []
        var unblock: CheckedContinuation<Void, Never>?
        let controller = TSSHResizeController { size in
            received.append(size)
            if received.count == 1 {
                await withCheckedContinuation { unblock = $0 }
            }
        }
        let oldTask = controller.request(.init(cols: 80, rows: 24), forceRedraw: true)
        while unblock == nil { await Task.yield() }
        controller.reset()
        let current = Size(cols: 42, rows: 50)
        await controller.request(current)?.value
        unblock?.resume()
        await oldTask?.value
        XCTAssertEqual(received, [Size(cols: 79, rows: 24), current])
    }

    @MainActor
    func testTransientZeroLayoutDoesNotReplaceValidSize() async {
        var received: [Size] = []
        let controller = TSSHResizeController { received.append($0) }
        let size = Size(cols: 1, rows: 1)
        await controller.request(size, forceRedraw: true)?.value
        XCTAssertNil(controller.request(.init(cols: 0, rows: 0)))
        XCTAssertEqual(received, [Size(cols: 2, rows: 1), size])
    }
}
