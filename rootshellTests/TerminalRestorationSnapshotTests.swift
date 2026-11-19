import XCTest

final class TerminalRestorationSnapshotTests: XCTestCase {
    private let reset = "\u{1b}c"

    func testGhosttyReplayIsSavedAndReadBackAsIs() {
        let replay = Data((reset + "shell\u{1b}[1;3H\u{1b}[?2004h").utf8)
        XCTAssertEqual(TerminalRestorationSnapshot.replay(fromSaved: replay), replay)
    }

    func testEnvelopeFromTheProtocolMirrorStillRestores() throws {
        // Written by builds that tracked protocol state in the app.
        let replay = Data((reset + "shell\u{1b}[?47halt").utf8)
        let saved = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "replay": replay.base64EncodedString(),
            "protocolState": ["alternate": true, "modes": ["?2004": true]],
        ])
        XCTAssertEqual(TerminalRestorationSnapshot.replay(fromSaved: saved), replay)
    }

    func testUnknownBytesAreNotReplayed() throws {
        XCTAssertNil(TerminalRestorationSnapshot.replay(fromSaved: Data()))
        XCTAssertNil(TerminalRestorationSnapshot.replay(fromSaved: Data("plain text".utf8)))
        let newer = try JSONSerialization.data(withJSONObject: ["version": 2, "replay": Data((reset + "x").utf8).base64EncodedString()])
        XCTAssertNil(TerminalRestorationSnapshot.replay(fromSaved: newer))
        let noReset = try JSONSerialization.data(withJSONObject: ["version": 1, "replay": Data("x".utf8).base64EncodedString()])
        XCTAssertNil(TerminalRestorationSnapshot.replay(fromSaved: noReset))
    }

    func testSnapshotWithinTheLimitIsUsedWhole() throws {
        let dump = "one\r\ntwo\u{1b}[2;4H"
        let snapshot = Data((reset + dump + "\u{1b}[?1h").utf8)
        let parts = try XCTUnwrap(TerminalRestorationSnapshot.parts(
            of: snapshot, primary: 2..<(2 + dump.utf8.count), maxScrollbackBytes: 1024))
        XCTAssertEqual(parts.scrollback, Data(dump.utf8))
        XCTAssertEqual(parts.replay, snapshot)
    }

    func testOversizedScrollbackIsCutAtALineInBothFiles() throws {
        let dump = "old line\r\nnewer line\r\nnewest\u{1b}[3;7H"
        let tail = "\u{1b}[?47halt\u{1b}[?2004h"
        let snapshot = Data((reset + dump + tail).utf8)
        let parts = try XCTUnwrap(TerminalRestorationSnapshot.parts(
            of: snapshot, primary: 2..<(2 + dump.utf8.count), maxScrollbackBytes: 30))
        XCTAssertEqual(parts.scrollback, Data("newer line\r\nnewest\u{1b}[3;7H".utf8))
        XCTAssertEqual(parts.replay, Data((reset + "newer line\r\nnewest\u{1b}[3;7H" + tail).utf8))
    }

    func testReplayIsDroppedWhenTheCutCannotLandOnALine() throws {
        let dump = String(repeating: "x", count: 64)
        let snapshot = Data((reset + dump + "\u{1b}[?1h").utf8)
        let parts = try XCTUnwrap(TerminalRestorationSnapshot.parts(of: snapshot, primary: 2..<66, maxScrollbackBytes: 16))
        XCTAssertEqual(parts.scrollback.count, 16)
        XCTAssertNil(parts.replay)
    }

    func testRangeOutsideTheSnapshotIsRejected() {
        let snapshot = Data((reset + "abc").utf8)
        XCTAssertNil(TerminalRestorationSnapshot.parts(of: snapshot, primary: 2..<9, maxScrollbackBytes: 1024))
    }

    func testSlicedSnapshotIsSplitByOffsetNotIndex() throws {
        // Data keeps its parent's indices when sliced.
        let padded = Data(("pad" + reset + "one\r\ntwo" + "\u{1b}[?1h").utf8)
        let snapshot = padded[3...]
        let parts = try XCTUnwrap(TerminalRestorationSnapshot.parts(of: snapshot, primary: 2..<10, maxScrollbackBytes: 1024))
        XCTAssertEqual(parts.scrollback, Data("one\r\ntwo".utf8))
    }

    func testOnlyTheFirstRemoteChunkCarriesTheMark() {
        let marker = TerminalRemoteOutputMarker()
        let session = marker.beginSession()
        XCTAssertNil(marker.saveState(pipe: 1).parseTarget)
        let mark = marker.claimFirstWrite(session: session)
        XCTAssertNotNil(mark)
        XCTAssertNil(marker.claimFirstWrite(session: session))
        // Claimed, but the chunk is still in the coalescer or the gate.
        XCTAssertNil(marker.saveState(pipe: 1).parseTarget)

        mark?(TerminalPipeOffset(pipe: 1, end: 900))
        XCTAssertEqual(marker.saveState(pipe: 1).parseTarget, 900)
        XCTAssertNil(marker.claimFirstWrite(session: session))
    }

    func testDroppedFirstChunkLeavesTheNextOneToBeFirst() {
        let marker = TerminalRemoteOutputMarker()
        let session = marker.beginSession()
        marker.claimFirstWrite(session: session)?(nil)
        XCTAssertNil(marker.saveState(pipe: 1).parseTarget)
        marker.claimFirstWrite(session: session)?(TerminalPipeOffset(pipe: 1, end: 40))
        XCTAssertEqual(marker.saveState(pipe: 1).parseTarget, 40)
    }

    func testReplacedPipeWaitsForARemoteWriteOfItsOwn() {
        let marker = TerminalRemoteOutputMarker()
        let session = marker.beginSession()
        marker.claimFirstWrite(session: session)?(TerminalPipeOffset(pipe: 1, end: 900))
        // A replaced surface counts its parsed bytes from zero again.
        XCTAssertNil(marker.saveState(pipe: 2).parseTarget)

        marker.pipeChanged()
        // The same session keeps writing, now into the new pipe.
        XCTAssertTrue(marker.saveState(pipe: 2).session.isCurrent)
        marker.claimFirstWrite(session: session)?(TerminalPipeOffset(pipe: 2, end: 12))
        XCTAssertEqual(marker.saveState(pipe: 2).parseTarget, 12)
    }

    func testOutputOfAReplacedSessionCannotVouchForTheNewOne() {
        let marker = TerminalRemoteOutputMarker()
        let old = marker.beginSession()
        let stale = marker.claimFirstWrite(session: old)
        // A save gathered this, then ran after the session was replaced.
        let gathered = marker.saveState(pipe: 1).session
        XCTAssertTrue(gathered.isCurrent)

        let new = marker.beginSession()
        XCTAssertFalse(gathered.isCurrent)
        // The old session's sink still delivers a late chunk, and its first
        // chunk reaches the pipe only now.
        XCTAssertNil(marker.claimFirstWrite(session: old))
        stale?(TerminalPipeOffset(pipe: 1, end: 950))
        XCTAssertNil(marker.saveState(pipe: 1).parseTarget)

        marker.claimFirstWrite(session: new)?(TerminalPipeOffset(pipe: 1, end: 2000))
        XCTAssertEqual(marker.saveState(pipe: 1).parseTarget, 2000)
    }

    func testReplayIsRecognisedByItsReset() {
        XCTAssertTrue(TerminalRestorationSnapshot.isReplay(Data((reset + "shell").utf8)))
        // The mode trailer used when no snapshot was saved.
        XCTAssertFalse(TerminalRestorationSnapshot.isReplay(Data("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[0 q".utf8)))
        XCTAssertFalse(TerminalRestorationSnapshot.isReplay(Data()))
    }

    func testLateMarkOfAReplacedPipeCannotTakeTheNewPipesClaim() {
        let marker = TerminalRemoteOutputMarker()
        let session = marker.beginSession()
        let oldPipe = marker.claimFirstWrite(session: session)
        marker.pipeChanged()
        let newPipe = marker.claimFirstWrite(session: session)
        XCTAssertNotNil(newPipe)
        // The old pipe's drain reports only now.
        oldPipe?(TerminalPipeOffset(pipe: 1, end: 900))
        XCTAssertNil(marker.saveState(pipe: 2).parseTarget)
        newPipe?(TerminalPipeOffset(pipe: 2, end: 30))
        XCTAssertEqual(marker.saveState(pipe: 2).parseTarget, 30)
    }

    func testSaveGatheredForAReplacedSurfaceIsNotCurrent() {
        let marker = TerminalRemoteOutputMarker()
        marker.beginSession()
        let gathered = marker.saveState(pipe: 1).session
        XCTAssertTrue(gathered.isCurrent)
        // Same session, new surface: the save still holds the old one.
        marker.pipeChanged()
        XCTAssertFalse(gathered.isCurrent)
        XCTAssertTrue(marker.saveState(pipe: 2).session.isCurrent)
    }

    func testOlderCaptureCannotBeWrittenOverANewerOne() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let registration = order.register(terminal)
        XCTAssertEqual(order.accept(terminal, capture: 7, registration: registration), .current)
        // The older capture was read first but reaches the order later.
        XCTAssertEqual(order.accept(terminal, capture: 5, registration: registration), .superseded)
        XCTAssertFalse(order.beginWrite(terminal, capture: 5, registration: registration))
        XCTAssertTrue(order.beginWrite(terminal, capture: 7, registration: registration))
        order.endWrite(terminal, capture: 7, succeeded: true)
        // Another terminal is unaffected.
        let other = UUID()
        XCTAssertEqual(order.accept(other, capture: 5, registration: order.register(other)), .current)
    }

    func testUnchangedNewerCaptureStillSupersedesAPendingWrite() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let registration = order.register(terminal)
        // Screen A is on disk.
        XCTAssertEqual(order.accept(terminal, capture: 1, registration: registration), .current)
        XCTAssertTrue(order.beginWrite(terminal, capture: 1, registration: registration))
        order.endWrite(terminal, capture: 1, succeeded: true)
        // Screen B is captured and waits to write; the terminal returns to A.
        XCTAssertEqual(order.accept(terminal, capture: 2, registration: registration), .current)
        XCTAssertEqual(order.accept(terminal, capture: 3, registration: registration), .aheadOfPendingWrite)
        // B must not land, and A must be written although it matches the
        // last recorded hash: B may be mid-write.
        XCTAssertFalse(order.beginWrite(terminal, capture: 2, registration: registration))
        XCTAssertTrue(order.beginWrite(terminal, capture: 3, registration: registration))
        order.endWrite(terminal, capture: 3, succeeded: true)
        XCTAssertEqual(order.accept(terminal, capture: 4, registration: registration), .current)
    }

    func testSettledAndFailedSaves() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let registration = order.register(terminal)
        XCTAssertEqual(order.accept(terminal, capture: 1, registration: registration), .current)
        // Unchanged, nothing written: the next one may skip as well.
        order.settle(terminal, capture: 1)
        XCTAssertEqual(order.accept(terminal, capture: 2, registration: registration), .current)
        // A write that failed leaves the disk behind the accepted screen.
        XCTAssertTrue(order.beginWrite(terminal, capture: 2, registration: registration))
        order.endWrite(terminal, capture: 2, succeeded: false)
        XCTAssertEqual(order.accept(terminal, capture: 3, registration: registration), .aheadOfPendingWrite)
    }

    func testSaveOfAReplacedRegistrationIsRefusedDespiteALaterCapture() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let old = order.register(terminal)
        // The terminal is recreated under the same UUID and saves.
        let new = order.register(terminal)
        XCTAssertEqual(order.accept(terminal, capture: 10, registration: new), .current)
        // A save still holding the old surface reads it afterwards, so
        // Ghostty numbers its capture higher.
        XCTAssertEqual(order.accept(terminal, capture: 11, registration: old), .superseded)
        XCTAssertFalse(order.beginWrite(terminal, capture: 11, registration: old))
    }

    func testSaveGatheredBeforeTeardownStillLands() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let registration = order.register(terminal)
        // Backgrounding gathers the save; the scene disconnects and its
        // terminals stop saving before the save has read the surface.
        // Nothing replaces the terminal, so its last screen is written.
        XCTAssertEqual(order.accept(terminal, capture: 3, registration: registration), .current)
        XCTAssertTrue(order.beginWrite(terminal, capture: 3, registration: registration))
        order.endWrite(terminal, capture: 3, succeeded: true)
    }

    func testAcceptedSaveCannotWriteAfterItsTerminalIsReplaced() {
        let order = TerminalSaveOrder()
        let terminal = UUID()
        let old = order.register(terminal)
        // Accepted, encrypting, its detached write not started yet.
        XCTAssertEqual(order.accept(terminal, capture: 4, registration: old), .current)
        // The terminal is recreated and waits for its first remote output.
        let new = order.register(terminal)
        XCTAssertFalse(order.beginWrite(terminal, capture: 4, registration: old))
        // The replacement's own save is still written, unchanged or not.
        XCTAssertEqual(order.accept(terminal, capture: 9, registration: new), .aheadOfPendingWrite)
        XCTAssertTrue(order.beginWrite(terminal, capture: 9, registration: new))
        order.endWrite(terminal, capture: 9, succeeded: true)
    }
}
