//
//  GitDiffSelection.swift
//  rootshell
//
//  A text selection over the diff's code lines. Pure and nonisolated so the
//  tests compile it without the app. Columns count Characters, as the rows'
//  attributed text and `GitDiffLine.emphasis` do.
//

import Foundation

/// One code line: indices into the snapshot's files, the file's hunks and the hunk's lines.
nonisolated struct GitDiffLineID: Hashable, Comparable, Sendable {
    var file: Int
    var hunk: Int
    var line: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.file, lhs.hunk, lhs.line) < (rhs.file, rhs.hunk, rhs.line)
    }
}

/// A code row by its file's identity rather than its index, which can shift between snapshots.
nonisolated struct GitDiffRowKey: Hashable, Sendable {
    var fileID: String
    var hunk: Int
    var line: Int
}

nonisolated struct GitDiffTextPosition: Hashable, Comparable, Sendable {
    var lineID: GitDiffLineID
    var column: Int

    init(_ lineID: GitDiffLineID, column: Int) {
        self.lineID = lineID
        self.column = column
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.lineID != rhs.lineID ? lhs.lineID < rhs.lineID : lhs.column < rhs.column
    }
}

/// What one row highlights.
nonisolated struct GitDiffLineSelection: Equatable, Sendable {
    var range: Range<Int>
    /// The selection runs on past this line, so its line break is selected too.
    var includesLineEnd: Bool
}

nonisolated struct GitDiffSelection: Equatable, Sendable {
    var anchor: GitDiffTextPosition
    var head: GitDiffTextPosition

    init(anchor: GitDiffTextPosition, head: GitDiffTextPosition) {
        self.anchor = anchor
        self.head = head
    }

    var start: GitDiffTextPosition { min(anchor, head) }
    var end: GitDiffTextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }

    func contains(_ position: GitDiffTextPosition) -> Bool {
        start <= position && position <= end
    }

    func lineSelection(for id: GitDiffLineID, length: Int) -> GitDiffLineSelection? {
        let start = start, end = end
        guard start.lineID <= id, id <= end.lineID else { return nil }
        let lower = id == start.lineID ? min(max(start.column, 0), length) : 0
        let upper = id == end.lineID ? min(max(end.column, 0), length) : length
        let includesLineEnd = id != end.lineID
        guard lower < upper || includesLineEnd else { return nil }
        return GitDiffLineSelection(range: lower..<max(lower, upper), includesLineEnd: includesLineEnd)
    }

    /// The selected code, one line per row, skipping files that are collapsed.
    func text(in files: [GitDiffFile], isExpanded: (Int) -> Bool) -> String {
        let start = start, end = end
        guard !files.isEmpty, start.lineID.file < files.count else { return "" }
        var lines: [String] = []
        for fileIndex in start.lineID.file...min(end.lineID.file, files.count - 1) where isExpanded(fileIndex) {
            for (hunkIndex, hunk) in files[fileIndex].hunks.enumerated() {
                for (lineIndex, line) in hunk.lines.enumerated() {
                    let id = GitDiffLineID(file: fileIndex, hunk: hunkIndex, line: lineIndex)
                    let characters = Array(line.text)
                    if let selected = lineSelection(for: id, length: characters.count) {
                        lines.append(String(characters[selected.range]))
                    } else if id == end.lineID, start.lineID < id {
                        // Ending at column 0 still selects the line break before this row.
                        lines.append("")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every line of every expanded file, or nil when none has a line.
    static func all(in files: [GitDiffFile], isExpanded: (Int) -> Bool) -> GitDiffSelection? {
        var first: GitDiffTextPosition?
        var last: GitDiffTextPosition?
        for (fileIndex, file) in files.enumerated() where isExpanded(fileIndex) {
            for (hunkIndex, hunk) in file.hunks.enumerated() where !hunk.lines.isEmpty {
                if first == nil {
                    first = GitDiffTextPosition(GitDiffLineID(file: fileIndex, hunk: hunkIndex, line: 0), column: 0)
                }
                let lineIndex = hunk.lines.count - 1
                last = GitDiffTextPosition(GitDiffLineID(file: fileIndex, hunk: hunkIndex, line: lineIndex),
                                           column: hunk.lines[lineIndex].text.count)
            }
        }
        guard let first, let last else { return nil }
        return GitDiffSelection(anchor: first, head: last)
    }

    // MARK: Words

    private enum CharacterClass { case word, space, other }

    private static func characterClass(_ character: Character) -> CharacterClass {
        if character.isLetter || character.isNumber || character == "_" { return .word }
        return character.isWhitespace ? .space : .other
    }

    /// The identifier, whitespace run or single symbol at `column`; past the end, the last one.
    static func wordRange(in characters: [Character], at column: Int) -> Range<Int> {
        guard !characters.isEmpty else { return 0..<0 }
        let index = min(max(column, 0), characters.count - 1)
        let kind = characterClass(characters[index])
        guard kind != .other else { return index..<(index + 1) }
        var lower = index, upper = index + 1
        while lower > 0, characterClass(characters[lower - 1]) == kind { lower -= 1 }
        while upper < characters.count, characterClass(characters[upper]) == kind { upper += 1 }
        return lower..<upper
    }
}
