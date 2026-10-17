import UIKit
import XCTest

final class HardwareKeyboardModifiersTests: XCTestCase {
    func testStaleShiftDroppedWhenLiveSnapshotHasNoShift() {
        let result = HardwareKeyboardModifiers.droppingStaleShift(
            from: [.shift, .alternate], physicalModifiers: [.alternate]
        )
        XCTAssertEqual(result, [.alternate])
    }

    func testShiftKeptWhenSnapshotShowsShiftDown() {
        let result = HardwareKeyboardModifiers.droppingStaleShift(
            from: [.shift], physicalModifiers: [.shift]
        )
        XCTAssertEqual(result, [.shift])
    }

    func testShiftKeptWithoutLiveSnapshot() {
        let result = HardwareKeyboardModifiers.droppingStaleShift(
            from: [.shift, .command], physicalModifiers: nil
        )
        XCTAssertEqual(result, [.shift, .command])
    }

    func testSnapshotNeverAddsModifiers() {
        let result = HardwareKeyboardModifiers.droppingStaleShift(
            from: [.control], physicalModifiers: [.shift, .command]
        )
        XCTAssertEqual(result, [.control])
    }

    func testOnlyShiftIsDropped() {
        let result = HardwareKeyboardModifiers.droppingStaleShift(
            from: [.shift, .control, .alphaShift], physicalModifiers: []
        )
        XCTAssertEqual(result, [.control, .alphaShift])
    }
}
