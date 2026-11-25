//
//  GitDiffPatchParser.swift
//  rootshell
//
//  Parses `git diff --patch` text into files, hunks and numbered lines, and
//  marks the span that changed between a removed line and its replacement.
//

import Foundation

nonisolated enum GitDiffPatchParser {

    /// Lines longer than this are cut for display; minified bundles otherwise
    /// cost a full layout pass each.
    static let maxLineLength = 2000

    /// Parses a patch. `truncated` marks the last file as cut off, since its
    /// final line may be partial.
    static func parse(_ patch: String, truncated: Bool = false) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var current: GitDiffFile?
        var hunk: GitDiffHunk?
        // Inside a hunk whose header was rejected. Its body is skipped, or an
        // added "++ x" line would read as a `+++` path marker.
        var skippingHunk = false
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            guard var open = hunk else { return }
            markEmphasis(in: &open.lines)
            current?.hunks.append(open)
            hunk = nil
        }

        func closeFile() {
            closeHunk()
            guard var file = current else { return }
            if !file.isBinary {
                var added = 0, removed = 0, columns = 0
                for hunk in file.hunks {
                    for line in hunk.lines {
                        if line.kind == .addition { added += 1 } else if line.kind == .deletion { removed += 1 }
                        columns = max(columns, line.text.utf16.count)
                    }
                }
                file.maxColumns = columns
                file.additions = added
                file.deletions = removed
            }
            file.hasPatch = true
            files.append(file)
            current = nil
        }

        // `isNewline` splitting keeps CRLF content lines whole; the stray CR
        // is dropped below so it never renders as a box.
        for rawLine in patch.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine

            if line.hasPrefix("diff --git ") {
                closeFile()
                skippingHunk = false
                let (old, new) = headerPaths(String(line.dropFirst("diff --git ".count)))
                current = GitDiffFile(path: new, oldPath: nil, status: .modified)
                if old != new { current?.oldPath = old }
                continue
            }
            guard current != nil else { continue }
            // Git puts no metadata between hunks, so only a header ends the skip.
            if skippingHunk, !line.hasPrefix("@@") { continue }

            if hunk != nil, let first = line.first, first == " " || first == "+" || first == "-" || first == "\\" {
                let text = clipped(line.dropFirst())
                switch first {
                case "+":
                    hunk?.lines.append(GitDiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: newLine))
                    newLine += 1
                case "-":
                    hunk?.lines.append(GitDiffLine(kind: .deletion, text: text, oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                case " ":
                    hunk?.lines.append(GitDiffLine(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                default:
                    // "\ No newline at end of file" describes the line above.
                    if let last = hunk?.lines.indices.last { hunk?.lines[last].noNewlineAtEnd = true }
                }
                continue
            }

            if line.hasPrefix("@@") {
                closeHunk()
                hunk = parseHunkHeader(line)
                skippingHunk = hunk == nil
                // Skipped lines go uncounted.
                if skippingHunk { current?.hasPartialCounts = true }
                if let hunk {
                    oldLine = hunk.oldStart
                    newLine = hunk.newStart
                }
                continue
            }

            closeHunk()
            if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = unquote(String(line.dropFirst("rename from ".count)))
                current?.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.path = unquote(String(line.dropFirst("rename to ".count)))
                current?.status = .renamed
            } else if line.hasPrefix("copy from ") {
                current?.oldPath = unquote(String(line.dropFirst("copy from ".count)))
                current?.status = .copied
            } else if line.hasPrefix("copy to ") {
                current?.path = unquote(String(line.dropFirst("copy to ".count)))
                current?.status = .copied
            } else if line.hasPrefix("--- ") {
                if let path = markerPath(line.dropFirst(4), prefix: "a/") {
                    if current?.status == .deleted { current?.path = path }
                }
            } else if line.hasPrefix("+++ ") {
                if let path = markerPath(line.dropFirst(4), prefix: "b/") { current?.path = path }
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            }
        }
        closeFile()

        if truncated, let last = files.indices.last {
            files[last].isTruncated = true
            // The final line may be half a line; drop it rather than show it.
            if let hunkIndex = files[last].hunks.indices.last, !files[last].hunks[hunkIndex].lines.isEmpty {
                files[last].hunks[hunkIndex].lines.removeLast()
            }
        }
        return files
    }

    // MARK: - Headers

    /// `-12,3 +14,5 @@ func name()` after the leading `@@ `.
    static func parseHunkHeader(_ line: Substring) -> GitDiffHunk? {
        guard line.hasPrefix("@@ "), let close = line.dropFirst(3).range(of: " @@") else { return nil }
        let ranges = line.dropFirst(3)[..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].first == "-", ranges[1].first == "+" else { return nil }

        func range(_ text: Substring) -> (Int, Int)? {
            // Bounded so the per-line increments in `parse` cannot overflow.
            let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count <= 2, let start = parts.first.flatMap(GitDiffCount.parse) else { return nil }
            guard parts.count == 2 else { return (start, 1) }
            guard let count = GitDiffCount.parse(parts[1]) else { return nil }
            return (start, count)
        }
        guard let old = range(ranges[0]), let new = range(ranges[1]) else { return nil }
        let context = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return GitDiffHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1,
                           context: context, lines: [])
    }

    /// Both paths from `a/old b/new`. Ambiguous when a path holds " b/", so
    /// the `---`/`+++` and rename lines correct it afterwards.
    static func headerPaths(_ rest: String) -> (old: String, new: String) {
        if rest.hasPrefix("\"") {
            // Quoted paths: split at the closing quote of the first.
            var index = rest.index(after: rest.startIndex)
            var escaped = false
            while index < rest.endIndex {
                let character = rest[index]
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                index = rest.index(after: index)
            }
            if index < rest.endIndex {
                let first = unquote(String(rest[...index]))
                let second = unquote(rest[rest.index(after: index)...].trimmingCharacters(in: .whitespaces))
                return (strip(first, "a/"), strip(second, "b/"))
            }
        }
        // An unrenamed file repeats its path, so the halves are equal length.
        let characters = Array(rest)
        if characters.count % 2 == 1, characters[characters.count / 2] == " " {
            let old = String(characters[..<(characters.count / 2)])
            let new = String(characters[(characters.count / 2 + 1)...])
            if strip(old, "a/") == strip(new, "b/") { return (strip(old, "a/"), strip(new, "b/")) }
        }
        if let split = rest.range(of: " b/") {
            return (strip(String(rest[..<split.lowerBound]), "a/"), String(rest[split.upperBound...]))
        }
        return (strip(rest, "a/"), strip(rest, "a/"))
    }

    private static func markerPath(_ text: Substring, prefix: String) -> String? {
        // git appends a tab after a path that contains spaces.
        var value = String(text)
        if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        value = unquote(value)
        guard value != "/dev/null" else { return nil }
        return strip(value, prefix)
    }

    private static func strip(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Undoes git's C-style path quoting (`"a\tb\303\251"`).
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var bytes: [UInt8] = []
        var iterator = value.dropFirst().dropLast().utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escape = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(escape - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    octal = octal * 8 + Int(digit &- UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(escape)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func clipped(_ text: Substring) -> String {
        guard text.utf8.count > maxLineLength else { return String(text) }
        return String(text.prefix(maxLineLength)) + "…"
    }

    // MARK: - Intraline emphasis

    /// Pairs each run of removed lines with the added lines that replace it
    /// and marks the span between their common prefix and suffix.
    static func markEmphasis(in lines: inout [GitDiffLine]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition { index += 1 }
            let deletions = additionStart - deletionStart
            let additions = index - additionStart
            // Uneven runs rarely line up one to one; pairing them highlights noise.
            guard deletions == additions, deletions <= 40 else { continue }
            for offset in 0..<deletions {
                guard let spans = changedSpans(lines[deletionStart + offset].text, lines[additionStart + offset].text)
                else { continue }
                lines[deletionStart + offset].emphasis = spans.old
                lines[additionStart + offset].emphasis = spans.new
            }
        }
    }

    /// The differing middle of two lines, or nil when they share too little
    /// for a highlight to say anything.
    static func changedSpans(_ old: String, _ new: String) -> (old: Range<Int>, new: Range<Int>)? {
        let oldCharacters = Array(old), newCharacters = Array(new)
        guard !oldCharacters.isEmpty, !newCharacters.isEmpty,
              oldCharacters.count <= 400, newCharacters.count <= 400 else { return nil }
        let limit = min(oldCharacters.count, newCharacters.count)
        var prefix = 0
        while prefix < limit, oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }
        // Snap to whole words, so a highlight never starts or stops mid-word.
        func isWord(_ characters: [Character], _ index: Int) -> Bool {
            guard characters.indices.contains(index) else { return false }
            return characters[index].isLetter || characters[index].isNumber || characters[index] == "_"
        }
        while prefix > 0, isWord(oldCharacters, prefix - 1),
              isWord(oldCharacters, prefix) || isWord(newCharacters, prefix) {
            prefix -= 1
        }
        while suffix > 0, isWord(oldCharacters, oldCharacters.count - suffix),
              isWord(oldCharacters, oldCharacters.count - suffix - 1)
                || isWord(newCharacters, newCharacters.count - suffix - 1) {
            suffix -= 1
        }
        let shared = prefix + suffix
        let sharedNonBlank = oldCharacters[..<prefix].filter { !$0.isWhitespace }.count
            + oldCharacters[(oldCharacters.count - suffix)...].filter { !$0.isWhitespace }.count
        // Indentation alone is not common ground.
        guard sharedNonBlank >= 3, shared * 3 >= max(oldCharacters.count, newCharacters.count) else { return nil }
        let oldRange = prefix..<(oldCharacters.count - suffix)
        let newRange = prefix..<(newCharacters.count - suffix)
        guard !(oldRange.isEmpty && newRange.isEmpty) else { return nil }
        return (oldRange, newRange)
    }
}
