import XCTest

final class HardwarePressRoutingTests: XCTestCase {
    func testShiftReleasedBeforeConsumedLetter() {
        var routing = HardwarePressRouting<String>()
        XCTAssertEqual(routing.began(["shift"], forwarding: ["shift"]), ["shift"])
        XCTAssertEqual(routing.began(["letter"], forwarding: []), [])
        XCTAssertEqual(routing.finished(["shift"]), ["shift"])
        XCTAssertEqual(routing.finished(["letter"]), [])
    }

    func testConsumedLetterReleasedBeforeShift() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["shift", "letter"], forwarding: ["shift"])
        XCTAssertEqual(routing.finished(["letter"]), [])
        XCTAssertEqual(routing.finished(["shift"]), ["shift"])
    }

    func testMixedReleaseOnlyForwardsModifier() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["shift", "letter"], forwarding: ["shift"])
        XCTAssertEqual(routing.finished(["shift", "letter"]), ["shift"])
    }

    func testUnknownCommandReleaseStillReachesUIKit() {
        var routing = HardwarePressRouting<String>()
        // UIKit may dispatch a UIKeyCommand without calling pressesBegan.
        XCTAssertEqual(routing.finished(["tab-command"]), ["tab-command"])
    }

    func testRepeatCannotForwardPreviouslyConsumedPress() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["letter"], forwarding: [])
        XCTAssertEqual(routing.began(["letter"], forwarding: ["letter"]), [])
        XCTAssertEqual(routing.finished(["letter"]), [])
    }

    func testHandledRepeatKeepsOriginalUIKitRelease() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["letter"], forwarding: ["letter"])
        XCTAssertEqual(routing.began(["letter"], forwarding: []), [])
        XCTAssertEqual(routing.finished(["letter"]), ["letter"])
    }

    func testCancellationFiltersBeforeInteractionReset() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["shift", "letter"], forwarding: ["shift"])
        XCTAssertEqual(routing.finished(["shift", "letter"]), ["shift"])
        routing.reset()
        XCTAssertEqual(routing.began(["letter"], forwarding: ["letter"]), ["letter"])
        XCTAssertEqual(routing.finished(["letter"]), ["letter"])
    }

    func testResetDiscardsOldPressIdentity() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["letter"], forwarding: [])
        routing.reset()
        XCTAssertEqual(routing.began(["letter"], forwarding: ["letter"]), ["letter"])
        XCTAssertEqual(routing.finished(["letter"]), ["letter"])
    }

    func testPartialCancellationPreservesOtherConsumedPress() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["shift", "first-letter", "second-letter"], forwarding: ["shift"])
        XCTAssertEqual(routing.finished(["first-letter"]), [])
        XCTAssertEqual(routing.finished(["shift"]), ["shift"])
        XCTAssertEqual(routing.finished(["second-letter"]), [])
    }

    func testSystemChordForwardsAllPresses() {
        var routing = HardwarePressRouting<String>()
        let chord: Set<String> = ["control", "space"]
        XCTAssertEqual(routing.began(chord, forwarding: chord), chord)
        XCTAssertEqual(routing.finished(chord), chord)
    }

    func testModTapModifierPassesThroughButEscapeIsConsumed() {
        var routing = HardwarePressRouting<String>()
        _ = routing.began(["physical-modifier", "escape-source"], forwarding: ["physical-modifier"])
        XCTAssertEqual(routing.finished(["physical-modifier", "escape-source"]), ["physical-modifier"])
    }
}
