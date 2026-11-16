//
//  AgentDetectionRegions.swift
//  rootshell
//
//  Pure region extraction for agent-detection rules, ported from herdr's
//  manifest engine (src/detect/manifest.rs). A region narrows a detection
//  snapshot (screen lines + OSC title/progress) to the slice a rule
//  matches against. Everything here is pure string work — fully
//  unit-testable without a surface.
//

import Foundation

/// One detection snapshot for a pane: the last N screen lines from the
/// live bottom of the terminal (trailing blank lines trimmed), the latest
/// OSC 0/2 title, and the latest OSC 9;4 progress payload ("4;1;-1").
nonisolated struct AgentDetectionInput: Sendable {
    let lines: [String]
    /// Joined screen content, computed once per snapshot.
    let screen: String
    let oscTitle: String
    let oscProgress: String
    /// Whether the alternate screen was active at snapshot time. Gates
    /// alt-screen-only identity signatures (TUI banner names): on the
    /// primary screen those words are just scrollback text.
    let altScreenActive: Bool
    /// Chrome belonging to a multiplexer the app does not drive was peeled
    /// off this snapshot: a pane border, a status bar, or both. Direct
    /// evidence, from the same read, for a session nothing configured. A
    /// hand-typed `tmux` or `zellij` has no launch command to recognise.
    let hadMultiplexerChrome: Bool

    /// Whether the alternate screen tells us anything about the AGENT.
    ///
    /// Alt-gated signatures exist because a full-screen TUI owning the alt
    /// screen makes its banner text trustworthy: the TUI painted it. A
    /// multiplexer owning it means the opposite, because the multiplexer
    /// painted the screen and the agent's name may be nothing but a command
    /// the user typed, or a window name in a status bar. Field repros: an
    /// `❯ opencode` shell line on a herdr screen, and tmux's own
    /// "0:opencode.exe*" window list, both minted an opencode session on a
    /// pane running something else.
    var altScreenIsAgentOwned: Bool { altScreenActive && !hadMultiplexerChrome }

    init(lines: [String], oscTitle: String = "", oscProgress: String = "",
         altScreenActive: Bool = false) {
        let unboxed = AgentDetectionRegions.strippingPaneBorder(lines)
        let cleaned = AgentDetectionRegions.blankingStatusBar(unboxed)
        self.lines = cleaned
        self.screen = cleaned.joined(separator: "\n")
        self.oscTitle = oscTitle
        self.oscProgress = oscProgress
        self.altScreenActive = altScreenActive
        self.hadMultiplexerChrome = cleaned != lines
    }
}

nonisolated enum AgentDetectionRegions {

    // MARK: - Pane borders

    /// Vertical rules a multiplexer draws down the side of a pane. zellij
    /// draws only `│` (zellij-server/src/ui/boundaries.rs, boundary_type::
    /// VERTICAL); `┃` and `║` are tmux's `pane-border-lines heavy` and
    /// `double`. ASCII `|` (tmux's `simple`) is deliberately absent: it
    /// is a markdown table column, a `git log --graph` rail and a regex
    /// alternation, and no multiplexer default draws it.
    private static let paneBorders: [Character] = ["│", "┃", "║"]

    /// Rows a boxed pane legitimately has WITHOUT a side border: the two
    /// corners of the frame itself, plus a multiplexer's own tab and status
    /// bars. It is a fixed overhead, not a proportion, so the allowance is
    /// subtracted rather than scaled: a share-based threshold would refuse
    /// to unbox a short snapshot, where those four rows are most of it.
    private static let paneBorderChromeAllowance = 4
    /// Below this there is not enough of a column to call it one.
    private static let paneBorderMinimumRows = 5

    /// Strips one level of multiplexer pane border, if the snapshot has
    /// one.
    ///
    /// zellij (and tmux with pane borders on) prefixes EVERY row of a pane
    /// with `│`, which silently defeats every line-anchored rule in the
    /// manifest at once: `^\s*❯` never sees claude's prompt, `^\s*›` never
    /// sees codex's composer. Device capture 065679B2 is the shape of the
    /// damage: fourteen frames of a zellij session where claude and then
    /// codex were plainly on screen, and not one matched a flagged screen
    /// rule, so the pane held a stale identity through a change of agent.
    /// Peeling the border back is what lets the SAME rules work inside a
    /// pane and outside one.
    ///
    /// One level only. An agent's own boxed chrome (codex's banner, a
    /// permission dialog) is drawn INSIDE the multiplexer's pane, and rules
    /// key on it; stripping recursively would eat it. It also means a
    /// nested multiplexer keeps its inner border, which is the honest
    /// outcome: we can only claim the outermost frame is not content.
    static func strippingPaneBorder(_ lines: [String]) -> [String] {
        let filled = lines.filter { !isBlank($0) }
        guard filled.count >= paneBorderMinimumRows else { return lines }
        let threshold = max(paneBorderMinimumRows, filled.count - paneBorderChromeAllowance)

        for border in paneBorders {
            // Most screens draw none of these; skip the column census.
            let borderBytes = ContiguousArray(String(border).utf8)
            let candidates = filled.reduce(0) {
                $0 + (containsBytes($1, borderBytes) ? 1 : 0)
            }
            guard candidates >= threshold else { continue }
            var columns: [Int: Int] = [:]
            for line in filled {
                for column in borderColumns(line, border) {
                    columns[column, default: 0] += 1
                }
            }
            // Leftmost on a tie, and never Dictionary order: a framed pane
            // has a full-height rule down BOTH sides, and the content is
            // the part to the right of the left one. Picking arbitrarily
            // between them also made the result differ between two calls on
            // the same input.
            guard let (column, count) = columns
                .sorted(by: { ($0.value, -$0.key) > ($1.value, -$1.key) })
                .first,
                count >= threshold
            else { continue }
            return lines.map { strip(border, atColumn: column, from: $0) }
        }
        return lines
    }

    /// Every offset `border` occupies in a row.
    ///
    /// Deliberately not "the first one, and only if whitespace precedes it".
    /// That reads a zellij pane frame, whose edge is at column zero, but not
    /// a SIDEBAR layout: herdr paints a full-height divider at the right of
    /// its agent list (src/ui/sidebar.rs, one `│` per row for the pane's
    /// whole height) with the list's own text to its left, and the agent
    /// being supervised is everything to the RIGHT of it. Requiring a blank
    /// prefix left claude-inside-herdr unidentifiable.
    ///
    /// What separates a pane edge from a table rule is therefore height, not
    /// indentation: an edge runs the length of the screen, an agent's own
    /// box (a banner, a dialog) does not, and the row threshold is what
    /// tells them apart. A full-height box-drawing TABLE would qualify, and
    /// that is accepted: a screen that is nothing but table rows carries no
    /// agent chrome to lose.
    private static func borderColumns(_ line: String, _ border: Character) -> [Int] {
        var columns: [Int] = []
        for (column, character) in line.enumerated() where character == border {
            columns.append(column)
        }
        return columns
    }

    private static func strip(_ border: Character, atColumn column: Int, from line: String) -> String {
        guard let start = line.index(line.startIndex, offsetBy: column, limitedBy: line.endIndex),
              start < line.endIndex, line[start] == border
        else { return line }
        let body = line[line.index(after: start)...]
        // The closing border, plus whatever padding the pane put before it.
        var tail = body
        while let last = tail.last, last == " " || last == "\t" { tail = tail.dropLast() }
        return tail.last == border ? String(tail.dropLast()) : String(body)
    }

    // MARK: - Status bars

    /// tmux's status line in its DEFAULT dress, at either end of the
    /// snapshot. From tmux's own options-table.c: `status-left` is
    /// "[#{session_name}] ", each window is "#I:#W#{window_flags}", and
    /// `status-right` ends "\"#{=21:pane_title}\" %H:%M %d-%b-%y". Both
    /// ends are required, which is what makes a false positive on an
    /// agent's own last row implausible.
    ///
    /// `NSRegularExpression` rather than `Regex` because this is a global:
    /// it is immutable and thread-safe, where a compiled `Regex` is not
    /// Sendable and cannot be stored at file scope.
    private static let statusBar = try! NSRegularExpression(
        pattern: #"^\s*\[[^\]]{0,64}\]\s+\d+:.*\s\d{1,2}:\d{2}\s+\d{1,2}-\w{3}-\d{2}\s*$"#)

    /// Blanks a multiplexer status bar.
    ///
    /// The bar is painted by tmux, not by the agent, and it is actively
    /// misleading: the window list carries the running command's NAME
    /// ("0:opencode.exe*") and `status-right` carries the pane title
    /// ("✳ Claude Code", "OpenCode"), so every bare-product-name signature
    /// fires off it. A cleared tmux window whose only content was that bar
    /// was identified as opencode. It also eats a row from every
    /// `bottom_non_empty_lines(N)` region, pushing the agent's real footer
    /// out of reach.
    ///
    /// Blanked rather than removed so row indices and `bottom_lines(N)`
    /// keep their geometry. Only a status bar in tmux's default format is
    /// recognised; a customised one is not something we can claim to know.
    static func blankingStatusBar(_ lines: [String]) -> [String] {
        var result = lines
        // `status-position` is bottom by default but may be top.
        for index in [lines.firstIndex(where: { !isBlank($0) }),
                      lines.lastIndex(where: { !isBlank($0) })] {
            guard let index else { continue }
            let line = lines[index]
            let range = NSRange(line.startIndex..., in: line)
            guard statusBar.firstMatch(in: line, range: range) != nil else { continue }
            result[index] = ""
        }
        return result
    }

    /// The region specs the engine understands. Unknown specs are
    /// rejected at manifest load, so `extract` can safely return "" for
    /// anything unrecognized.
    static func isValidSpec(_ spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "whole_recent", "osc_title", "osc_progress",
             "after_last_prompt_marker", "before_current_prompt_marker",
             "whole_recent_without_current_prompt_marker",
             "current_prompt_block_marker", "after_current_prompt_block_marker",
             "prompt_box_body", "above_prompt_box",
             "last_non_empty_above_prompt_box", "last_block_above_prompt_box",
             "after_last_horizontal_rule":
            return true
        default:
            return count(of: trimmed, name: "bottom_lines") != nil
                || count(of: trimmed, name: "bottom_non_empty_lines") != nil
                || count(of: trimmed, name: "bottom_non_empty_lines_above_prompt_box") != nil
                || count(of: trimmed, name: "top_non_empty_lines") != nil
        }
    }

    /// Whether a region can only see the LIVE tail of the screen —
    /// bottom-anchored, or delimited by the agent's own live chrome (its
    /// composer marker, the last rule, the prompt box). `whole_recent`
    /// and the top/above-anchored specs are not: they match anywhere in
    /// the 40-row snapshot, so an answered prompt still visible in the
    /// transcript keeps matching long after it was dismissed. Callers use
    /// this to weigh evidence — an unanchored match is a guess about the
    /// past, an anchored one is a statement about now.
    static func isLiveAnchored(_ spec: String?) -> Bool {
        guard let spec else { return false }
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "after_last_prompt_marker", "current_prompt_block_marker",
             "after_current_prompt_block_marker", "prompt_box_body",
             "last_non_empty_above_prompt_box", "last_block_above_prompt_box",
             "after_last_horizontal_rule":
            return true
        case "whole_recent", "osc_title", "osc_progress",
             "before_current_prompt_marker", "above_prompt_box",
             "whole_recent_without_current_prompt_marker":
            return false
        default:
            return count(of: trimmed, name: "bottom_lines") != nil
                || count(of: trimmed, name: "bottom_non_empty_lines") != nil
                // Delimited by the prompt box, the same live chrome that
                // makes prompt_box_body anchored.
                || count(of: trimmed, name: "bottom_non_empty_lines_above_prompt_box") != nil
        }
    }

    static func extract(_ spec: String, from input: AgentDetectionInput) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "osc_title": return input.oscTitle
        case "osc_progress": return input.oscProgress
        case "whole_recent": return input.screen
        case "after_last_prompt_marker": return afterLastPromptMarker(input.lines)
        case "before_current_prompt_marker": return beforeCurrentPromptMarker(input.lines)
        case "whole_recent_without_current_prompt_marker":
            return currentCodexPromptIndex(input.lines) == nil ? input.screen : ""
        case "current_prompt_block_marker": return currentPromptBlockMarker(input.lines) ?? ""
        case "after_current_prompt_block_marker": return afterCurrentPromptBlockMarker(input.lines) ?? ""
        case "prompt_box_body": return promptBoxBody(input.lines) ?? ""
        case "above_prompt_box": return joined(abovePromptBoxLines(input.lines))
        case "last_non_empty_above_prompt_box":
            return lastNonEmptyLine(abovePromptBoxLines(input.lines))
        case "last_block_above_prompt_box":
            return lastBlock(abovePromptBoxLines(input.lines))
        case "after_last_horizontal_rule": return afterLastHorizontalRule(input.lines)
        default:
            if let n = count(of: trimmed, name: "bottom_lines") {
                return joined(Array(input.lines.suffix(n)))
            }
            if let n = count(of: trimmed, name: "bottom_non_empty_lines") {
                return bottomNonEmptyLines(input.lines, n)
            }
            // The last N non-empty lines of the TRANSCRIPT, counted from
            // the prompt box up rather than from the screen bottom. An
            // agent's live status line sits directly above its input box,
            // but the distance from there to the bottom row varies with
            // whatever the box's own footer is showing. With no prompt box
            // on screen `abovePromptBoxLines` returns everything, so this
            // degrades to `bottom_non_empty_lines(N)`.
            if let n = count(of: trimmed, name: "bottom_non_empty_lines_above_prompt_box") {
                return bottomNonEmptyLines(abovePromptBoxLines(input.lines), n)
            }
            if let n = count(of: trimmed, name: "top_non_empty_lines") {
                return topNonEmptyLines(input.lines, n)
            }
            return ""
        }
    }

    // MARK: - Parameterized regions

    private static func count(of spec: String, name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        let inner = spec.dropFirst(name.count + 1).dropLast()
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber),
              let n = Int(inner), n > 0, n <= 65535
        else { return nil }
        return n
    }

    /// Everything from the Nth-from-last non-empty line down (trailing
    /// blanks between/after non-empty lines are included).
    private static func bottomNonEmptyLines(_ lines: [String], _ n: Int) -> String {
        var found = 0
        var start: Int?
        for index in lines.indices.reversed() where !isBlank(lines[index]) {
            found += 1
            start = index
            if found == n { break }
        }
        guard let start else { return "" }
        return joined(Array(lines[start...]))
    }

    /// Everything from the top through the Nth non-empty line.
    private static func topNonEmptyLines(_ lines: [String], _ n: Int) -> String {
        var found = 0
        var end: Int?
        for index in lines.indices where !isBlank(lines[index]) {
            found += 1
            end = index
            if found == n { break }
        }
        guard let end else { return "" }
        return joined(Array(lines[...end]))
    }

    // MARK: - Codex prompt-marker regions

    /// A live Codex prompt line: exactly "›" or starting "› ", optionally
    /// indented by a Codex overlay's menu-surface inset.
    private static func isCodexPromptLine(_ line: String) -> Bool {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        return content == "›" || content.hasPrefix("› ")
    }

    /// A Codex block-marker line starts with one of • ■ ✗ ✓.
    private static func isCodexBlockMarkerLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == "•" || first == "■" || first == "✗" || first == "✓"
    }

    /// Index of the last prompt line, but only when it is "current":
    /// no block marker appears after it.
    private static func currentCodexPromptIndex(_ lines: [String]) -> Int? {
        guard let promptIndex = lines.lastIndex(where: isCodexPromptLine) else { return nil }
        let after = lines.index(after: promptIndex)
        if lines[after...].contains(where: isCodexBlockMarkerLine) { return nil }
        return promptIndex
    }

    private static func afterLastPromptMarker(_ lines: [String]) -> String {
        guard let index = lines.lastIndex(where: isCodexPromptLine) else {
            return joined(lines)
        }
        return joined(Array(lines[lines.index(after: index)...]))
    }

    private static func beforeCurrentPromptMarker(_ lines: [String]) -> String {
        guard let index = currentCodexPromptIndex(lines) else { return joined(lines) }
        return joined(Array(lines[..<index]))
    }

    /// The last block-marker line above the current prompt, alone.
    private static func currentPromptBlockMarker(_ lines: [String]) -> String? {
        guard let promptIndex = currentCodexPromptIndex(lines) else { return nil }
        return lines[..<promptIndex].last(where: isCodexBlockMarkerLine)
    }

    /// From the last block-marker line above the current prompt (marker
    /// line included) to the end of the snapshot.
    private static func afterCurrentPromptBlockMarker(_ lines: [String]) -> String? {
        guard let promptIndex = currentCodexPromptIndex(lines),
              let blockIndex = lines[..<promptIndex].lastIndex(where: isCodexBlockMarkerLine)
        else { return nil }
        return joined(Array(lines[blockIndex...]))
    }

    // MARK: - Prompt-box regions (─── bordered input box)

    /// A horizontal rule: after trimming, a leading run of ─ followed by
    /// nothing, or at least 3 rule chars followed by anything (titled
    /// rules like "── Title ──").
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix(while: { $0 == "─" }).count
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.dropFirst(ruleChars).drop(while: { $0 == " " || $0 == "\t" })
        return suffix.isEmpty || ruleChars >= 3
    }

    /// The top border of the prompt box: the 2nd horizontal rule counting
    /// from the bottom of the snapshot.
    private static func promptBoxTopBorderIndex(_ lines: [String]) -> Int? {
        var borders = 0
        for index in lines.indices.reversed() where isHorizontalRule(lines[index]) {
            borders += 1
            if borders == 2 { return index }
        }
        return nil
    }

    /// Between the prompt box's top border and the next rule below it
    /// (borders excluded).
    private static func promptBoxBody(_ lines: [String]) -> String? {
        guard let top = promptBoxTopBorderIndex(lines) else { return nil }
        let bodyStart = lines.index(after: top)
        let end = lines[bodyStart...].firstIndex(where: isHorizontalRule) ?? lines.endIndex
        return joined(Array(lines[bodyStart..<end]))
    }

    private static func abovePromptBoxLines(_ lines: [String]) -> [String] {
        guard let top = promptBoxTopBorderIndex(lines) else { return lines }
        return Array(lines[..<top])
    }

    /// The transcript's last entry: from the last row at the shallowest
    /// indent down (a peeled pane border leaves its padding on every row).
    /// Wrapped and hanging rows are indented deeper, so a status line keeps
    /// its continuation however narrow the pane is.
    private static func lastBlock(_ lines: [String]) -> String {
        func indent(_ line: String) -> Int { line.prefix(while: \.isWhitespace).count }
        guard let margin = lines.filter({ !isBlank($0) }).map(indent).min(),
              let start = lines.lastIndex(where: { !isBlank($0) && indent($0) == margin })
        else { return "" }
        return joined(Array(lines[start...]))
    }

    private static func afterLastHorizontalRule(_ lines: [String]) -> String {
        guard let index = lines.lastIndex(where: isHorizontalRule) else {
            return joined(lines)
        }
        return joined(Array(lines[lines.index(after: index)...]))
    }

    // MARK: - Helpers

    /// Byte-wise substring search. A miss proves an ASCII needle absent
    /// from the text; a hit is only a candidate (grapheme boundaries).
    static func containsBytes(
        _ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>
    ) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    /// `containsBytes` for a row that has not been converted yet.
    static func containsBytes(_ line: String, _ needle: ContiguousArray<UInt8>) -> Bool {
        var line = line
        return line.withUTF8 { hay in
            needle.withUnsafeBytes { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func lastNonEmptyLine(_ lines: [String]) -> String {
        lines.last(where: { !isBlank($0) }) ?? ""
    }

    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
