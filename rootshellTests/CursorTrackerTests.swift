import Foundation
import XCTest

final class CursorTrackerTests: XCTestCase {
    private let width = 10
    private let prefix = 2  // "$ "

    /// Layout of `cells` after the prompt; the cursor defaults to the end.
    private func layout(_ cells: [Int], cursor: Int? = nil, prefix: Int? = nil) -> CursorTracker.InputLayout {
        CursorTracker.DrawnInput(
            prefixWidth: prefix ?? self.prefix,
            cells: cells,
            cursorIndex: cursor ?? cells.count
        ).layout(terminalWidth: width)
    }

    private func ascii(_ count: Int) -> [Int] {
        Array(repeating: 1, count: count)
    }

    func testEmptyInputSitsAfterPrompt() {
        let l = layout([])
        XCTAssertEqual(l.totalRows, 1)
        XCTAssertEqual(l.cursorRow, 0)
        XCTAssertEqual(l.cursorCol, 2)
        XCTAssertTrue(l.cursorAtEnd)
    }

    func testOneShortOfWidthStaysOnFirstRow() {
        let l = layout(ascii(7))
        XCTAssertEqual(l.totalRows, 1)
        XCTAssertEqual(l.cursorRow, 0)
        XCTAssertEqual(l.cursorCol, 9)
    }

    // The terminal defers the wrap, so the cursor is still on the filled row.
    func testExactFillKeepsCursorOnLastDrawnRow() {
        let one = layout(ascii(8))
        XCTAssertEqual(one.totalRows, 1)
        XCTAssertEqual(one.cursorRow, 0)
        XCTAssertEqual(one.cursorMove, "")

        let three = layout(ascii(28))
        XCTAssertEqual(three.totalRows, 3)
        XCTAssertEqual(three.cursorRow, 2)
    }

    func testOnePastWidthWraps() {
        let l = layout(ascii(9))
        XCTAssertEqual(l.totalRows, 2)
        XCTAssertEqual(l.cursorRow, 1)
        XCTAssertEqual(l.cursorCol, 1)
    }

    func testCursorOnFirstRowOfThreeRowLine() {
        let l = layout(ascii(25), cursor: 0)
        XCTAssertEqual(l.totalRows, 3)
        XCTAssertEqual(l.cursorRow, 0)
        XCTAssertEqual(l.cursorCol, 2)
        XCTAssertFalse(l.cursorAtEnd)
        XCTAssertEqual(l.cursorMove, "\u{1B}[2A\r\u{1B}[2C")
        XCTAssertEqual(l.stepPast, "\u{1B}[2B")
    }

    // A mid-line cursor at a row boundary really is at column 0 of the next row.
    func testMidLineCursorAtRowBoundary() {
        let l = layout(ascii(25), cursor: 8)
        XCTAssertEqual(l.cursorRow, 1)
        XCTAssertEqual(l.cursorCol, 0)
        XCTAssertEqual(l.rewind, "\u{1B}[1A\r")
    }

    // A two-cell glyph that does not fit wraps whole and leaves a cell unused.
    func testWideGlyphWrapsEarly() {
        let l = layout(ascii(7) + [2] + ascii(9))
        XCTAssertEqual(l.totalRows, 3)
        XCTAssertEqual(l.cursorRow, 2)
        XCTAssertEqual(l.cursorCol, 1)

        let beforeWide = layout(ascii(7) + [2], cursor: 7)
        XCTAssertEqual(beforeWide.cursorRow, 1)
        XCTAssertEqual(beforeWide.cursorCol, 0)
    }

    func testWideGlyphFillingRowDefersWrap() {
        let l = layout(ascii(6) + [2])
        XCTAssertEqual(l.totalRows, 1)
        XCTAssertEqual(l.cursorRow, 0)
    }

    func testLineBreakStartsNextRowAtColumnZero() {
        let l = layout(ascii(3) + [CursorTracker.lineBreak] + ascii(4))
        XCTAssertEqual(l.totalRows, 2)
        XCTAssertEqual(l.cursorRow, 1)
        XCTAssertEqual(l.cursorCol, 4)
    }

    // A prompt wider than the terminal already leaves the cursor below row 0.
    func testWrappedPromptPrefix() {
        let l = layout([], prefix: 23)
        XCTAssertEqual(l.totalRows, 3)
        XCTAssertEqual(l.cursorRow, 2)
        XCTAssertEqual(l.cursorCol, 3)
        XCTAssertEqual(l.rewind, "\u{1B}[2A\r")
    }

    // Laying the same draw out at a new width finds the cursor after a reflow.
    func testSameDrawAtAnotherWidth() {
        let drawn = CursorTracker.DrawnInput(prefixWidth: 2, cells: ascii(25), cursorIndex: 25)
        XCTAssertEqual(drawn.layout(terminalWidth: 10).cursorRow, 2)
        XCTAssertEqual(drawn.layout(terminalWidth: 20).cursorRow, 1)
        XCTAssertEqual(drawn.layout(terminalWidth: 40).cursorRow, 0)
    }
}
