import XCTest

@MainActor
final class KVMInputTranslatorTests: XCTestCase {

    private func key(_ code: String, _ down: Bool) -> KVMInputOutput {
        .frame(KVMHIDFrame.key(code, down: down))
    }

    // MARK: Physical keys

    func testPhysicalKeysIgnoreRepeatsAndRelease() {
        var translator = KVMInputTranslator()
        XCTAssertEqual(translator.physicalKey(down: true, usage: 0x04), [key("KeyA", true)])
        XCTAssertEqual(translator.physicalKey(down: true, usage: 0x04), [], "the remote OS repeats held keys")
        XCTAssertEqual(translator.physicalKey(down: false, usage: 0x04), [key("KeyA", false)])
        XCTAssertEqual(translator.physicalKey(down: false, usage: 0x04), [])
    }

    func testPhysicalKeysIgnoreHostLayout() {
        var translator = KVMInputTranslator()
        translator.hostLayout = "de"
        XCTAssertEqual(translator.physicalKey(down: true, usage: 0x1C), [key("KeyY", true)])
    }

    // MARK: Keysyms (US layout)

    func testShiftedCharacterGetsSyntheticShift() {
        var translator = KVMInputTranslator()
        XCTAssertEqual(translator.keysym(down: true, keysym: 0x21), [key("ShiftLeft", true), key("Digit1", true)])
        XCTAssertEqual(translator.keysym(down: false, keysym: 0x21), [key("Digit1", false), key("ShiftLeft", false)])
    }

    func testHeldShiftIsNotDoubled() {
        var translator = KVMInputTranslator()
        XCTAssertEqual(translator.keysym(down: true, keysym: 0xFFE1), [key("ShiftLeft", true)])
        XCTAssertEqual(translator.keysym(down: true, keysym: 0x41), [key("KeyA", true)])
        XCTAssertEqual(translator.keysym(down: false, keysym: 0x41), [key("KeyA", false)])
        XCTAssertEqual(translator.keysym(down: false, keysym: 0xFFE1), [key("ShiftLeft", false)])
    }

    func testPhysicalShiftCountsForKeysymCharacters() {
        var translator = KVMInputTranslator()
        _ = translator.physicalKey(down: true, usage: 0xE1)
        XCTAssertEqual(translator.keysym(down: true, keysym: 0x40), [key("Digit2", true)])
    }

    func testSharedCodeReleasesOnLastUp() {
        var translator = KVMInputTranslator()
        _ = translator.physicalKey(down: true, usage: 0xE0)
        XCTAssertEqual(translator.keysym(down: true, keysym: 0xFFE3), [], "already held physically")
        XCTAssertEqual(translator.keysym(down: false, keysym: 0xFFE3), [])
        XCTAssertEqual(translator.physicalKey(down: false, usage: 0xE0), [key("ControlLeft", false)])
    }

    func testUnmappedCharactersAreTypedByTheDevice() {
        var translator = KVMInputTranslator()
        XCTAssertEqual(translator.keysym(down: true, keysym: 0xE9), [.text("é")])
        XCTAssertEqual(translator.keysym(down: false, keysym: 0xE9), [])
        XCTAssertEqual(translator.keysym(down: true, keysym: 0x0100_20AC), [.text("€")])
    }

    // MARK: Keysyms (other host layouts)

    func testNonUSLayoutTypesPrintablesOnDevice() {
        var translator = KVMInputTranslator()
        translator.hostLayout = "fr"
        XCTAssertEqual(translator.keysym(down: true, keysym: 0x61), [.text("a")])
        XCTAssertEqual(translator.keysym(down: false, keysym: 0x61), [])
        XCTAssertEqual(translator.keysym(down: true, keysym: 0xFF0D), [key("Enter", true)], "non-printables stay positional")
        XCTAssertEqual(translator.keysym(down: true, keysym: 0xFFE3), [key("ControlLeft", true)])
    }

    // MARK: Pointer

    func testAbsolutePointerAndButtons() {
        var translator = KVMInputTranslator()
        translator.frameWidth = 1920
        translator.frameHeight = 1080
        let output = translator.pointer(buttonMask: 0x01, x: 0, y: 1079)
        XCTAssertEqual(output, [
            .frame(KVMHIDFrame.absoluteMove(x: -32768, y: 32767)),
            .frame(KVMHIDFrame.button(.left, down: true)),
        ])
        XCTAssertEqual(translator.pointer(buttonMask: 0x00, x: 0, y: 1079), [.frame(KVMHIDFrame.button(.left, down: false))])
        XCTAssertEqual(translator.pointer(buttonMask: 0x04, x: 0, y: 1079), [.frame(KVMHIDFrame.button(.right, down: true))])
    }

    func testWheelButtonsSendOneTickPerPress() {
        var translator = KVMInputTranslator()
        translator.frameWidth = 100
        translator.frameHeight = 100
        _ = translator.pointer(buttonMask: 0, x: 10, y: 10)
        XCTAssertEqual(translator.pointer(buttonMask: 0x08, x: 10, y: 10), [.frame(KVMHIDFrame.wheel(dx: 0, dy: 1))])
        XCTAssertEqual(translator.pointer(buttonMask: 0x00, x: 10, y: 10), [])
        XCTAssertEqual(translator.pointer(buttonMask: 0x10, x: 10, y: 10), [.frame(KVMHIDFrame.wheel(dx: 0, dy: -1))])
    }

    func testRelativeMouseSendsDeltas() {
        var translator = KVMInputTranslator()
        translator.mouseAbsolute = false
        XCTAssertEqual(translator.pointer(buttonMask: 0, x: 100, y: 100), [], "first sample only records a position")
        XCTAssertEqual(translator.pointer(buttonMask: 0, x: 110, y: 95), [.frame(KVMHIDFrame.relativeMove([(10, -5)]))])
    }

    func testScrollSplitsLargeDeltas() {
        var translator = KVMInputTranslator()
        translator.frameWidth = 100
        translator.frameHeight = 100
        let output = translator.scroll(x: 5, y: 5, wheelX: 0, wheelY: 200)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output.last, .frame(KVMHIDFrame.wheel(dx: 0, dy: 73)))
    }

    func testReverseScrollingFlipsBothAxes() {
        var translator = KVMInputTranslator()
        translator.frameWidth = 100
        translator.frameHeight = 100
        translator.reverseScrolling = true
        XCTAssertEqual(translator.scroll(x: 5, y: 5, wheelX: 2, wheelY: 3).last, .frame(KVMHIDFrame.wheel(dx: -2, dy: -3)))
        XCTAssertEqual(translator.pointer(buttonMask: 0x08, x: 5, y: 5), [.frame(KVMHIDFrame.wheel(dx: 0, dy: -1))])
        XCTAssertEqual(translator.pointer(buttonMask: 0x40, x: 5, y: 5), [.frame(KVMHIDFrame.wheel(dx: -1, dy: 0))])
    }

    // MARK: Reset

    func testReleaseAllLetsGoOfKeysAndButtons() {
        var translator = KVMInputTranslator()
        translator.frameWidth = 100
        translator.frameHeight = 100
        _ = translator.physicalKey(down: true, usage: 0xE0)
        _ = translator.keysym(down: true, keysym: 0x21)
        _ = translator.pointer(buttonMask: 0x01, x: 1, y: 1)
        XCTAssertEqual(translator.releaseAll(), [
            key("ControlLeft", false), key("Digit1", false), key("ShiftLeft", false),
            .frame(KVMHIDFrame.button(.left, down: false)),
        ])
        XCTAssertEqual(translator.releaseAll(), [])
        XCTAssertEqual(translator.physicalKey(down: true, usage: 0xE0), [key("ControlLeft", true)])
    }
}
