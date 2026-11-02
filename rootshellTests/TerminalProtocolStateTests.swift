import XCTest

final class TerminalProtocolStateTests: XCTestCase {
    private func parse(_ text: String) -> TerminalProtocolState {
        var parser = TerminalProtocolParser()
        parser.consume(Data(text.utf8))
        return parser.state
    }

    func testNegotiationSurvivesEveryPossibleChunkBoundary() {
        let bytes = Data("\u{1b}[>1u\u{1b}[?1049h\u{1b}[>3u\u{1b}[>9u\u{1b}[=4;2u\u{1b}[2;18r\u{1b}[?1002;1006;1004;2004h\u{1b}[6 q".utf8)
        var whole = TerminalProtocolParser(); whole.consume(bytes)
        for split in 0...bytes.count {
            var fragmented = TerminalProtocolParser()
            fragmented.consume(Data(bytes.prefix(split))); fragmented.consume(Data(bytes.dropFirst(split)))
            XCTAssertEqual(fragmented.state, whole.state, "split \(split)")
        }
        XCTAssertEqual(whole.state.primaryKeyboard.flags[1], 1)
        XCTAssertEqual(whole.state.alternateKeyboard.flags[2], 13)
        XCTAssertEqual(whole.state.margins, "\u{1b}[2;18r")
    }

    func testNestedKeyboardPopAfterRestorationMatchesOriginal() {
        let original = parse("\u{1b}[>1u\u{1b}[>3u\u{1b}[>9u")
        var replay = TerminalProtocolParser()
        replay.consume(Data(original.primaryKeyboard.replay().utf8))
        var expected = original.primaryKeyboard
        for _ in 0..<8 {
            XCTAssertEqual(replay.state.primaryKeyboard.flags[replay.state.primaryKeyboard.index], expected.flags[expected.index])
            replay.consume(Data("\u{1b}[<u".utf8)); expected.pop(1)
        }
    }

    func testOSCAndDCSCannotSpoofKeyboardNegotiation() {
        let state = parse("\u{1b}]2;title \u{1b}[>31u\u{07}\u{1b}Pignored \u{1b}[?1049h\u{1b}\\")
        XCTAssertFalse(state.alternate)
        XCTAssertEqual(state.primaryKeyboard, TerminalProtocolState.Keyboard())
    }

    func testMouseAliasesAndResetsAreNotGuessed() {
        let state = parse("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?2004l")
        XCTAssertEqual(state.modes["?1000"], false)
        XCTAssertEqual(state.modes["?1002"], true)
        XCTAssertEqual(state.modes["?2004"], false)
        XCTAssertTrue(String(decoding: state.settingsReplay(), as: UTF8.self).contains("\u{1b}[?2004l"))
    }

    func testPaintPrecedesModesAndCursorUsesRestoredOrigin() throws {
        let state = parse("\u{1b}[?1049h\u{1b}[>9u\u{1b}[3;20r\u{1b}[?6h\u{1b}[38;2;1;2;3m")
        let snapshot = TerminalRestorationSnapshot(primary: Data("shell\u{1b}[1;3H".utf8), alternate: Data("editor terminal buffer\u{1b}[8;5H".utf8), state: state)
        let decoded = try JSONDecoder().decode(TerminalRestorationSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.protocolState, state)
        let text = String(decoding: decoded.replay, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\u{1b}[?47h").count, 2)
        XCTAssertTrue(text.hasSuffix("\u{1b}[6;5H"))
        XCTAssertTrue(text.contains("\u{1b}[38;2;1;2;3m"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "editor terminal buffer")?.lowerBound), try XCTUnwrap(text.range(of: "\u{1b}[3;20r")?.lowerBound))
    }

    func testSnapshotWaitsForParserAndNewOutputInvalidatesAcknowledgement() {
        let observer = TerminalProtocolObserver()
        var written = Data()
        observer.write(Data("editor".utf8)) { written += $0 }
        XCTAssertNil(observer.capture { _ in true })
        XCTAssertTrue(written.suffix(12).contains(0x70))
        let reply = Data("\u{1b}[?16000;0$y".utf8)
        XCTAssertTrue(observer.consumeResponses(Data(reply.prefix(6))).isEmpty)
        XCTAssertNil(observer.capture { _ in true })
        XCTAssertEqual(observer.consumeResponses(Data(reply.dropFirst(6)) + Data("typed".utf8)), Data("typed".utf8))
        XCTAssertEqual(observer.capture { _ in true }, true)
        observer.write(Data("update".utf8)) { _ in }
        XCTAssertNil(observer.capture { _ in true })
        // Late/duplicate replies cannot acknowledge the newer update.
        _ = observer.consumeResponses(reply)
        XCTAssertNil(observer.capture { _ in true })
    }

    func testFenceDoesNotInterruptSplitCSIOrUTF8() {
        let observer = TerminalProtocolObserver()
        var chunks: [Data] = []
        observer.write(Data("\u{1b}[>".utf8)) { chunks.append($0) }
        XCTAssertEqual(chunks[0], Data("\u{1b}[>".utf8))
        observer.write(Data("9u".utf8)) { chunks.append($0) }
        XCTAssertGreaterThan(chunks[1].count, 2)
        observer.write(Data([0xe6])) { chunks.append($0) }
        XCTAssertEqual(chunks[2], Data([0xe6]))
        observer.write(Data([0x97, 0xa5])) { chunks.append($0) }
        XCTAssertTrue(chunks[3].starts(with: [0x97, 0xa5]))
    }

    func testResetAndBoundedSGRStorage() {
        var parser = TerminalProtocolParser()
        for _ in 0..<10_000 { parser.consume(Data("\u{1b}[1;38;5;42m\u{1b}[22m".utf8)) }
        XCTAssertEqual(parser.state.attributes.count, 1)
        parser.consume(Data("\u{1b}c".utf8))
        XCTAssertEqual(parser.state, TerminalProtocolState())
    }

    func testBurstStillFencesFinalOutputAfterProbeWindowFills() {
        let observer = TerminalProtocolObserver()
        var written = Data()
        for _ in 0..<100 { observer.write(Data("x".utf8)) { written += $0 } }
        var replies = Data()
        for id in 16000..<16064 { replies += Data("\u{1b}[?\(id);0$y".utf8) }
        XCTAssertTrue(observer.consumeResponses(replies).isEmpty)
        XCTAssertTrue(written.suffix(Data("\u{1b}[?16064$p".utf8).count).elementsEqual(Data("\u{1b}[?16064$p".utf8)))
        XCTAssertNil(observer.capture { _ in true })
        _ = observer.consumeResponses(Data("\u{1b}[?16064;0$y".utf8))
        XCTAssertEqual(observer.capture { _ in true }, true)
    }

    func testAlternateKeyboardStackPersistsAcrossScreenSwitches() {
        let state = parse("\u{1b}[>1u\u{1b}[?1049h\u{1b}[>9u\u{1b}[?1049l\u{1b}[?1049h")
        XCTAssertEqual(state.primaryKeyboard.flags[state.primaryKeyboard.index], 1)
        XCTAssertEqual(state.alternateKeyboard.flags[state.alternateKeyboard.index], 9)
    }

    func testCursorRestoreAlsoRestoresTrackedPen() {
        let state = parse("\u{1b}[31m\u{1b}7\u{1b}[32m\u{1b}8")
        XCTAssertEqual(state.attributes[38], "31")
    }

    func testUnknownModesCannotGrowStateIndefinitely() {
        var parser = TerminalProtocolParser()
        for mode in 20_000..<30_000 { parser.consume(Data("\u{1b}[?\(mode)h".utf8)) }
        XCTAssertTrue(parser.state.modes.isEmpty)
    }

    func testOldSessionFenceCannotAcknowledgeReplacementSession() {
        let observer = TerminalProtocolObserver()
        observer.write(Data("old".utf8)) { _ in }
        observer.reset(state: nil)
        observer.write(Data("new".utf8)) { _ in }
        _ = observer.consumeResponses(Data("\u{1b}[?16000;0$y".utf8))
        XCTAssertNil(observer.capture { _ in true })
        _ = observer.consumeResponses(Data("\u{1b}[?16001;0$y".utf8))
        XCTAssertEqual(observer.capture { _ in true }, true)
    }

    func testGeneralEscapeIntermediatesAreNotInterruptedAtAnySplit() {
        for sequence in ["\u{1b}#8", "\u{1b}%G", "\u{1b} F", "\u{1b}$)C"] {
            let data = Data(sequence.utf8)
            for split in 1..<data.count {
                let observer = TerminalProtocolObserver()
                var writes: [Data] = []
                observer.write(Data(data.prefix(split))) { writes.append($0) }
                XCTAssertEqual(writes[0], Data(data.prefix(split)), "split \(split) of \(sequence.debugDescription)")
                observer.write(Data(data.dropFirst(split))) { writes.append($0) }
                XCTAssertTrue(writes[1].starts(with: data.dropFirst(split)))
                XCTAssertGreaterThan(writes[1].count, data.count - split)
            }
        }
    }

    func testSavedCursorQueryIsInsertedBeforeFollowingOutputAndConsumed() throws {
        let observer = TerminalProtocolObserver()
        var written = Data()
        observer.write(Data("\u{1b}[31m\u{1b}7\u{1b}[32mnext".utf8)) { written += $0 }
        let text = String(decoding: written, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1b}7\u{1b}[?16000$p\u{1b}[6n\u{1b}[32mnext"))
        XCTAssertNil(observer.capture { $0 })
        let response = Data("typed\u{1b}[?16000;0$y\u{1b}[7;12R\u{1b}[?16001;0$y".utf8)
        var forwarded = Data()
        for byte in response { forwarded += observer.consumeResponses(Data([byte])) }
        XCTAssertEqual(forwarded, Data("typed".utf8))
        let state = try XCTUnwrap(observer.capture { $0 })
        XCTAssertEqual(state.primarySavedPen?.row, 7)
        XCTAssertEqual(state.primarySavedPen?.col, 12)
        let snapshot = TerminalRestorationSnapshot(primary: Data("paint\u{1b}[9;20H".utf8), alternate: nil, state: state)
        var original = TerminalProtocolParser(); original.state = state
        var restored = TerminalProtocolParser(); restored.consume(snapshot.replay)
        original.consume(Data("\u{1b}8".utf8)); restored.consume(Data("\u{1b}8".utf8))
        XCTAssertEqual(restored.state.attributes, original.state.attributes)
        XCTAssertTrue(String(decoding: snapshot.replay, as: UTF8.self).contains("\u{1b}[7;12H\u{1b}7"))
        XCTAssertTrue(String(decoding: snapshot.replay, as: UTF8.self).hasSuffix("\u{1b}[9;20H"))
    }

    func testCursorReportUsesOriginAtSaveAndIgnoresOverwrittenSave() throws {
        let observer = TerminalProtocolObserver()
        observer.write(Data("\u{1b}[3;20r\u{1b}[?6h\u{1b}7\u{1b}7".utf8)) { _ in }
        let replies = Data("\u{1b}[?16000;0$y\u{1b}[2;4R\u{1b}[?16001;0$y\u{1b}[5;6R\u{1b}[?16002;0$y".utf8)
        XCTAssertTrue(observer.consumeResponses(replies).isEmpty)
        let state = try XCTUnwrap(observer.capture { $0 })
        XCTAssertEqual(state.primarySavedPen?.row, 7)
        XCTAssertEqual(state.primarySavedPen?.col, 6)
    }

    func testFreshPTYDiscardsOldModesAndDrainsOldCursorQueries() throws {
        let observer = TerminalProtocolObserver()
        observer.write(Data("\u{1b}[?1049h\u{1b}[>9u".utf8)) { _ in }
        observer.reset(state: nil)
        observer.write(Data("fresh shell".utf8)) { _ in }
        let old = Data("\u{1b}[?16000;0$y\u{1b}[4;5R\u{1b}[?16001;0$y".utf8)
        XCTAssertTrue(observer.consumeResponses(old).isEmpty)
        XCTAssertNil(observer.capture { $0 })
        _ = observer.consumeResponses(Data("\u{1b}[?16002;0$y".utf8))
        let state = try XCTUnwrap(observer.capture { $0 })
        XCTAssertFalse(state.alternate)
        XCTAssertEqual(state.primaryKeyboard, TerminalProtocolState.Keyboard())
        XCTAssertNil(state.primarySavedPen)
    }

    func testAlternateReplayDoesNotOverwritePrimarySavedCursor() {
        var state = parse("\u{1b}[31m\u{1b}7\u{1b}[?47h\u{1b}[32m\u{1b}7\u{1b}[34m")
        state.primarySavedPen?.row = 3; state.primarySavedPen?.col = 4
        state.alternateSavedPen?.row = 7; state.alternateSavedPen?.col = 8
        let snapshot = TerminalRestorationSnapshot(primary: Data("primary\u{1b}[5;6H".utf8), alternate: Data("alt\u{1b}[9;10H".utf8), state: state)
        var restored = TerminalProtocolParser(); restored.consume(snapshot.replay)
        restored.consume(Data("\u{1b}8".utf8))
        XCTAssertEqual(restored.state.attributes[38], "32")
        restored.consume(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(restored.state.attributes[38], "31")
    }

    func testEmbeddedOutputTracksRemoteModesWithoutObservingLocalSpinner() throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var contents = Data()
            func write(_ data: Data) { lock.lock(); defer { lock.unlock() }; contents += data }
        }
        let saved = parse("\u{1b}[32m\u{1b}[>9u")
        let observer = TerminalProtocolObserver(state: saved)
        let recorder = Recorder()
        let remoteOutput = observer.makeOutputSink { recorder.write($0) }
        recorder.write(Data("\u{1b}[0mconnecting\u{1b}[?7h".utf8))
        remoteOutput(Data("\u{1b}[?7lremote update".utf8))
        _ = observer.consumeResponses(Data("\u{1b}[?16000;0$y".utf8))
        let state = try XCTUnwrap(observer.capture { $0 })
        XCTAssertEqual(state.attributes[38], "32")
        XCTAssertEqual(state.primaryKeyboard.flags[state.primaryKeyboard.index], 9)
        XCTAssertEqual(state.modes["?7"], false)
        XCTAssertTrue(String(decoding: recorder.contents, as: UTF8.self).contains("connecting"))
        XCTAssertTrue(String(decoding: recorder.contents, as: UTF8.self).contains("remote update"))
    }
}
