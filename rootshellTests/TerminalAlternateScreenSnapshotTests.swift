import XCTest

final class TerminalAlternateScreenSnapshotTests: XCTestCase {
    func testStyledViewportAndCursorSurviveSaveAndRestore() throws {
        let viewport = Data("\u{1b}[H\u{1b}[38;2;100;200;50mNeovim 日本語\r\n  buffer text  \u{1b}[0m\u{1b}[J\u{1b}[2;7H".utf8)
        let saved = TerminalAlternateScreenSnapshot.encode(viewport)
        let replay = try XCTUnwrap(TerminalAlternateScreenSnapshot.restorationBytes(from: saved))
        XCTAssertEqual(saved.first, 1)
        XCTAssertTrue(replay.starts(with: Data("\u{1b}[?1049h\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8)))
        XCTAssertEqual(Data(replay.suffix(viewport.count)), viewport)
    }

    func testLegacyFlagOnlySaveStillEntersAlternateScreen() {
        XCTAssertEqual(TerminalAlternateScreenSnapshot.restorationBytes(from: Data([1])),
                       Data("\u{1b}[?1049h".utf8))
        XCTAssertEqual(TerminalAlternateScreenSnapshot.encode(nil), Data([1]))
    }

    func testMissingOrInactiveFlagDoesNotSwitchAwayFromShell() {
        XCTAssertNil(TerminalAlternateScreenSnapshot.restorationBytes(from: Data()))
        XCTAssertNil(TerminalAlternateScreenSnapshot.restorationBytes(from: Data([0])))
    }

    func testFullScreenEditsChangeSavedStateEvenWhenModeIsUnchanged() {
        let before = TerminalAlternateScreenSnapshot.encode(Data("buffer before".utf8))
        let after = TerminalAlternateScreenSnapshot.encode(Data("buffer after".utf8))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.first, after.first)
    }

    func testViewportReplayPrecedesLiveIncrementalUpdateWithoutAnotherClear() throws {
        let primary = Data("shell history\r\n$ nvs".utf8)
        let viewport = Data("\u{1b}[Hunchanged Neovim content\u{1b}[2;1Hsecond row".utf8)
        let live = Data("\u{1b}[2;1Hedited".utf8)
        let replay = try XCTUnwrap(TerminalAlternateScreenSnapshot.restorationBytes(
            from: TerminalAlternateScreenSnapshot.encode(viewport)))
        let stream = primary + replay + live
        let text = String(decoding: stream, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\u{1b}[?1049h").count, 2)
        XCTAssertTrue(stream.starts(with: primary))
        XCTAssertTrue(stream.suffix(viewport.count + live.count).elementsEqual(viewport + live))
    }
}
