//
//  CursorTracker.swift
//  rootshell
//
//  Line-wrap layout for prompt input, shared through `LineEditor` by the local
//  shell prompt and the embedded sftp prompt. Pure integer math, no platform
//  APIs — compiles on iOS, visionOS, and Mac Catalyst.
//

import Foundation

// MARK: - Cursor Tracking for Line Wraps

/// Lays out prompt input the way the terminal draws it, in display cells.
nonisolated enum CursorTracker {
    /// Marks a line break in `DrawnInput.cells`. Glyph widths are at least 1.
    static let lineBreak = 0

    /// What a draw put on the input line(s). Kept by the caller so the same
    /// content can be laid out again at whatever width the terminal has now.
    nonisolated struct DrawnInput: Equatable {
        /// Display width of the prompt on the input line (2 for "❯ ")
        var prefixWidth = 0
        /// Cell width of each character drawn after the prompt, or `lineBreak`
        var cells: [Int] = []
        /// Number of drawn characters before the cursor
        var cursorIndex = 0

        /// Walks the cells as the terminal places them: a glyph that does not
        /// fit in the rest of a row wraps whole, and filling a row exactly
        /// defers the wrap until the next glyph.
        func layout(terminalWidth: Int) -> InputLayout {
            let width = max(1, terminalWidth)

            // The prompt's own cells; `col == width` is a deferred wrap.
            var row = max(0, prefixWidth - 1) / width
            var col = prefixWidth - row * width
            var cursor: (row: Int, col: Int)?

            for (index, cell) in cells.enumerated() {
                let isBreak = cell == CursorTracker.lineBreak
                let glyph = min(cell, width)
                let wraps = !isBreak && col + glyph > width
                if index == cursorIndex {
                    cursor = wraps ? (row + 1, 0) : (row, min(col, width - 1))
                }
                if isBreak || wraps {
                    row += 1
                    col = 0
                }
                col += glyph
            }

            // At the end of the text the cursor stays on the last drawn row,
            // even when that row is full.
            let end = cursor ?? (row, min(col, width - 1))
            return InputLayout(
                totalRows: row + 1,
                cursorRow: end.row,
                cursorCol: end.col,
                cursorAtEnd: cursor == nil
            )
        }
    }

    /// Where drawn input sits, in rows and columns from the start of its first row.
    nonisolated struct InputLayout: Equatable {
        let totalRows: Int
        let cursorRow: Int
        let cursorCol: Int
        /// The cursor follows everything that was drawn
        let cursorAtEnd: Bool

        /// Moves from the cursor to column 0 of the input's first row.
        var rewind: String {
            (cursorRow > 0 ? "\u{1B}[\(cursorRow)A" : "") + "\r"
        }

        /// Moves from the end of freshly printed text to the cursor. Empty at
        /// the end: printing left the cursor there, deferred wrap included, and
        /// repositioning would drop it to column 0.
        var cursorMove: String {
            guard !cursorAtEnd else { return "" }
            return CursorTracker.cursorPositionSequence(
                totalRows: totalRows,
                targetRow: cursorRow,
                targetCol: cursorCol
            )
        }

        /// Moves from the cursor down to the last drawn row.
        var stepPast: String {
            let rowsDown = totalRows - 1 - cursorRow
            return rowsDown > 0 ? "\u{1B}[\(rowsDown)B" : ""
        }
    }

    /// Generate escape sequence to position cursor correctly after redraw
    /// - Parameters:
    ///   - totalRows: Total rows of content drawn on input line(s)
    ///   - targetRow: Target row (0-indexed from input start)
    ///   - targetCol: Target column (0-indexed)
    /// - Returns: ANSI escape sequence to position cursor
    static func cursorPositionSequence(
        totalRows: Int,
        targetRow: Int,
        targetCol: Int
    ) -> String {
        // After drawing, cursor is at end of last row
        // Need to move to (targetRow, targetCol)

        var sequence = ""

        // Calculate rows to move up (from end of content to target row)
        let rowsUp = totalRows - 1 - targetRow
        if rowsUp > 0 {
            sequence += "\u{1B}[\(rowsUp)A"  // CUU - cursor up
        }

        // Move to beginning of line, then to target column
        sequence += "\r"  // Carriage return to column 0
        if targetCol > 0 {
            sequence += "\u{1B}[\(targetCol)C"  // CUF - cursor forward
        }

        return sequence
    }
}
