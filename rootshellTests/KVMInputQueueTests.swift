import XCTest

@MainActor
final class KVMInputQueueTests: XCTestCase {

    private func move(_ x: Int16, _ y: Int16) -> Data {
        KVMHIDFrame.absoluteMove(x: x, y: y)
    }

    private func wheel(_ dy: Int8) -> Data {
        KVMHIDFrame.wheel(dx: 0, dy: dy)
    }

    private let click = KVMHIDFrame.button(.left, down: true)

    func testMotionIsPacedAndOnlyTheNewestPositionIsSent() {
        var queue = KVMInputQueue()
        queue.append([.frame(move(1, 1))])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([move(1, 1)]), "idle motion goes out at once")

        queue.append([.frame(move(2, 2)), .frame(move(3, 3)), .frame(move(4, 4))])
        guard case .wait(let delay) = queue.next(now: 10.004, framesInFlight: 0) else {
            return XCTFail("motion inside the interval waits")
        }
        XCTAssertEqual(delay, 0.006, accuracy: 0.0001)
        XCTAssertEqual(queue.next(now: 10.011, framesInFlight: 0), .frames([move(4, 4)]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testMotionIgnoresSendsInFlightUntilTheBudgetIsFull() {
        var queue = KVMInputQueue()
        let full = KVMInputQueue.maximumFramesInFlight
        queue.append([.frame(move(1, 1))])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: full), .none)
        queue.append([.frame(move(2, 2))])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: full - 1), .frames([move(2, 2)]))
    }

    func testClicksAreNotPacedAndKeepTheirPosition() {
        var queue = KVMInputQueue()
        queue.append([.frame(move(1, 1)), .frame(click), .frame(move(2, 2))])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([move(1, 1)]))
        XCTAssertEqual(queue.next(now: 10.001, framesInFlight: 1), .frames([click]))
        guard case .wait = queue.next(now: 10.002, framesInFlight: 0) else {
            return XCTFail("the move after the click is still paced")
        }
        XCTAssertEqual(queue.next(now: 10.011, framesInFlight: 0), .frames([move(2, 2)]))
    }

    func testScrollKeepsItsPositionAndInterleavedMotionLeavesAsOneRun() {
        var queue = KVMInputQueue()
        queue.append([.frame(move(1, 1))])
        _ = queue.next(now: 10, framesInFlight: 0)
        queue.append([.frame(move(2, 2)), .frame(wheel(1)), .frame(move(3, 3))])
        XCTAssertEqual(
            queue.next(now: 10.011, framesInFlight: 0),
            .frames([move(2, 2), wheel(1), move(3, 3)]),
            "the scroll still lands at the position before it")
        XCTAssertTrue(queue.isEmpty)
    }

    func testMotionBacklogDrainsOneBatchPerInterval() {
        var queue = KVMInputQueue()
        queue.append([.frame(move(0, 0))])
        XCTAssertEqual(
            queue.next(now: 10, framesInFlight: KVMInputQueue.maximumFramesInFlight), .none,
            "a stalled socket holds motion")
        for index in 1...5 {
            queue.append([.frame(wheel(1)), .frame(move(Int16(index), 0))])
        }
        guard case .frames(let first) = queue.next(now: 10.5, framesInFlight: 0) else {
            return XCTFail("the backlog starts draining")
        }
        XCTAssertEqual(first, [move(0, 0), wheel(1), move(1, 0), wheel(1)])
        guard case .wait = queue.next(now: 10.5, framesInFlight: 0) else {
            return XCTFail("the rest waits for the next interval")
        }
        guard case .frames(let second) = queue.next(now: 10.511, framesInFlight: 0) else {
            return XCTFail("the next batch follows")
        }
        XCTAssertEqual(second.count, KVMInputQueue.maximumMotionBatch)
        XCTAssertEqual(
            queue.next(now: 10.522, framesInFlight: KVMInputQueue.maximumFramesInFlight - 2),
            .frames([move(4, 0), wheel(1)]),
            "a batch never exceeds the send budget")
        XCTAssertEqual(queue.next(now: 10.533, framesInFlight: 0), .frames([move(5, 0)]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testAdjacentWheelDeltasMergeWithSquash() {
        var queue = KVMInputQueue()
        queue.append([.frame(wheel(3)), .frame(wheel(-1)), .frame(wheel(2))])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([Data([0x05, 0x01, 0, 3, 0, 0xFF, 0, 2])]))
    }

    func testTextWaitsForFramesAndConcatenates() {
        var queue = KVMInputQueue()
        queue.append([.frame(click), .text("a"), .text("b")])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([click]))
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 1), .none)
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .text("ab"))
    }

    func testLoginPasswordNeverMergesWithText() {
        var queue = KVMInputQueue()
        queue.append([.text("a"), .loginPassword("pw", pressingReturn: true), .text("b")])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .text("a"))
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .loginPassword("pw", pressingReturn: true))
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .text("b"))
    }

    func testStopTypingDropsAPendingPassword() {
        var queue = KVMInputQueue()
        queue.append([.frame(click), .loginPassword("pw", pressingReturn: true)])
        queue.removeText()
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([click]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testPrependGoesAheadOfQueuedInput() {
        var queue = KVMInputQueue()
        let enter = KVMHIDFrame.key("Enter", down: true)
        queue.append([.frame(click)])
        queue.prepend([.frame(enter)])
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([enter]))
        XCTAssertEqual(queue.next(now: 10, framesInFlight: 0), .frames([click]))
    }
}
