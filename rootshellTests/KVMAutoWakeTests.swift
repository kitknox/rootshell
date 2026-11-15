import XCTest

@MainActor
final class KVMAutoWakeTests: XCTestCase {

    private func verdict(_ online: Bool?, frames: Int = 0, elapsed: TimeInterval) -> KVMAutoWake.Verdict {
        KVMAutoWake.verdict(sourceOnline: online, framesSinceOpen: frames, elapsed: elapsed)
    }

    func testNoSignalWakesOnlyAfterTheStreamerSettles() {
        XCTAssertEqual(verdict(false, elapsed: 0.5), .wait)
        XCTAssertEqual(verdict(false, elapsed: KVMAutoWake.offlineSettle), .wake)
        XCTAssertEqual(verdict(false, frames: 5, elapsed: 60), .wake, "placeholder frames don't count as video")
    }

    func testAnOnlineSourceNeedsFramesToCountAsVideo() {
        XCTAssertEqual(verdict(true, frames: 1, elapsed: 0), .videoPresent)
        XCTAssertEqual(verdict(true, elapsed: 0), .wait)
        XCTAssertEqual(verdict(true, elapsed: KVMAutoWake.silentSettle), .wake, "online without frames is still no display")
    }

    func testWithoutASignalReportFramesDecide() {
        XCTAssertEqual(verdict(nil, elapsed: KVMAutoWake.offlineSettle), .wait)
        XCTAssertEqual(verdict(nil, elapsed: KVMAutoWake.silentSettle), .wake)
        XCTAssertEqual(verdict(nil, frames: 1, elapsed: 60), .videoPresent)
    }


    func testKeyHoldsAreSpacedAndLongEnoughToOutlastAResume() {
        XCTAssertFalse(KVMAutoWake.watches.isEmpty)
        for watch in KVMAutoWake.watches {
            XCTAssertGreaterThanOrEqual(watch, 4, "holds must not read as a double tap")
        }
        XCTAssertGreaterThanOrEqual(KVMAutoWake.keyHold, 1)
        XCTAssertEqual(KVMAutoWake.keyCode, "ControlLeft")
    }

    func testRelativeNudgeReturnsToWhereItStarted() {
        let nudge = KVMAutoWake.pointerNudge(absolute: false, lastPoint: nil, frameWidth: 0, frameHeight: 0)
        XCTAssertEqual(nudge.away, KVMHIDFrame.relativeMove([(4, 0)]))
        XCTAssertEqual(nudge.back, KVMHIDFrame.relativeMove([(-4, 0)]))
    }

    func testAbsoluteNudgeEndsOnTheLastPosition() {
        func frame(_ x: Int, _ y: Int) -> Data {
            KVMHIDFrame.absoluteMove(
                x: KVMHIDFrame.absoluteCoordinate(x, extent: 1920),
                y: KVMHIDFrame.absoluteCoordinate(y, extent: 1080))
        }
        let known = KVMAutoWake.pointerNudge(absolute: true, lastPoint: (100, 200), frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(known.away, frame(104, 200))
        XCTAssertEqual(known.back, frame(100, 200))

        let edge = KVMAutoWake.pointerNudge(absolute: true, lastPoint: (1919, 0), frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(edge.away, frame(1915, 0))
        XCTAssertEqual(edge.back, frame(1919, 0))

        let unknown = KVMAutoWake.pointerNudge(absolute: true, lastPoint: nil, frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(unknown.back, frame(960, 540), "an unknown pointer goes to the middle")
        XCTAssertNotEqual(unknown.away, unknown.back)
    }
}
