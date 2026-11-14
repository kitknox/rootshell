//
//  AgentFleetRows.swift
//  rootshell
//
//  Claude Code's background-agent list ("FleetView"), read off the live
//  screen:
//
//      ❯ ⏺ main
//        ◯ Explore  Grepping timeoutChecker…    2m 13s · ↓ 98.9k tokens
//        ◯ Explore  Reading keepAlive…          2m  1s · ↓ 111.2k tokens
//
//  Manifest rules can say "a fleet list is on screen", but not "an agent
//  in it is still running": a rule keyed on the list alone would pin the
//  pane working forever, and a replayed frame (tmux attach, launch
//  restore) holds a whole list of frozen timers. What no format guess is
//  needed for is a row's own timer ADVANCING between two scans; that is
//  what this parser feeds — unlike the byte-activity heuristic that
//  ROUND 9 removed.
//
//  ⛔ The agent NAME cannot key a row. Claude runs several agents under
//  one name, and keying scans by it collapsed three concurrent Explores
//  into one slot, so the card read "1 agent" for a three-agent fleet.
//
//  Pure string work, no UIKit: compiled into the standalone test harness
//  alongside AgentDetectionRegions.
//

import Foundation

nonisolated enum AgentFleetRows {
    /// One fleet row with a live counter. `label` is the agent name only
    /// (the activity text after it changes every few seconds, so it can't
    /// be part of the key we diff scans on).
    struct Row: Equatable, Sendable {
        var label: String
        var elapsed: TimeInterval
    }

    /// One remembered row: its last seen timer, plus when that timer was
    /// last seen to move. Claude runs several agents under the same name
    /// ("Explore", "Explore", "Explore"), so the name alone cannot key a
    /// row — rows of one name are identified by their position in that
    /// name's group, oldest first.
    struct RowMemory: Equatable, Sendable {
        var elapsed: TimeInterval
        var lastAdvance: Date
    }

    /// What one scan's rows say relative to the previous scan's.
    struct Delta: Equatable, Sendable {
        /// Some row's own timer moved on: agents are running right now.
        var advanced = false
        /// How many rows on this scan are still running. Every row on a
        /// freshly painted list counts; on a list nothing moved in, only
        /// rows whose last movement is inside `liveWindow`.
        var liveCount = 0
        /// Carry into the next scan's comparison.
        var snapshot: [String: [RowMemory]] = [:]
    }

    /// Fold one scan in.
    ///
    /// Counting the rows that moved in THIS scan alone would undercount:
    /// claude does not repaint every row on every frame (a real capture
    /// went 134s/128s/122s → 135s/129s/122s one second later), and a
    /// screen we read while it happens to be stale can be a minute behind
    /// the session. So a list where anything moved is a live list and all
    /// of its rows count — claude drops a row the moment its agent
    /// finishes, so what is on a moving list is running.
    ///
    /// `liveWindow` only governs the other case, a list where nothing
    /// moved: its rows keep counting until they have been frozen that
    /// long, which is what finally clears the count when the fleet ends
    /// or when a replayed frame (tmux attach, launch restore) is holding
    /// a dead list on screen.
    static func delta(
        from previous: [String: [RowMemory]],
        to rows: [Row],
        now: Date,
        liveWindow: TimeInterval
    ) -> Delta {
        var result = Delta()
        var grouped: [String: [TimeInterval]] = [:]
        for row in rows { grouped[row.label, default: []].append(row.elapsed) }

        // Rows that did not move this scan, and when each last did.
        var frozen: [Date] = []

        for (label, elapsed) in grouped {
            // Oldest first in both lists so positions line up regardless
            // of the order the rows happened to be rendered in.
            let current = elapsed.sorted(by: >)
            let seen = (previous[label] ?? []).sorted { $0.elapsed > $1.elapsed }
            var memory: [RowMemory] = []
            var index = seen.startIndex

            for value in current {
                // A row's own timer only ever counts up, so a remembered
                // value ABOVE this one belongs to a row that has since
                // left the list (claude drops a row when its agent
                // finishes). Skip past it rather than shifting every
                // pairing below it.
                while index < seen.endIndex, seen[index].elapsed > value { index += 1 }
                guard index < seen.endIndex else {
                    // Nothing left to pair with: a row seen for the first
                    // time. No evidence either way, but a row that just
                    // appeared is far likelier running than finished.
                    memory.append(RowMemory(elapsed: value, lastAdvance: now))
                    result.liveCount += 1
                    continue
                }
                let match = seen[index]
                index += 1
                if value > match.elapsed {
                    result.advanced = true
                    memory.append(RowMemory(elapsed: value, lastAdvance: now))
                    result.liveCount += 1
                } else {
                    memory.append(RowMemory(elapsed: value, lastAdvance: match.lastAdvance))
                    frozen.append(match.lastAdvance)
                }
            }
            result.snapshot[label] = memory
        }

        for lastAdvance in frozen where result.advanced
            || now.timeIntervalSince(lastAdvance) < liveWindow {
            result.liveCount += 1
        }
        return result
    }

    /// Trailing live counter: "4m 30s · ↓ 58.2k tokens".
    // Regex holds an immutable compiled program; matching allocates its
    // own state, so sharing one across scans is safe.
    private nonisolated(unsafe) static let counterSuffix =
        #/(?:(\d+)h )?(?:(\d+)m )?(\d+)s [·•] ?[↑↓] ?[\d.,]+k? tokens\s*$/#

    /// "✻ Waiting for 1 background agent to finish". Same spinner-glyph
    /// anchor as the manifest rule: transcript prose about background
    /// agents must not count.
    private nonisolated(unsafe) static let waitingLine =
        #/(?i)^\s*[·✢✳✶✻✽]\s+waiting for (\d+) background agent/#

    /// Claude's spinner frames; a line starting with one is the session's
    /// own status line, not a fleet row.
    private static let spinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    /// Row selectors and status dots that prefix a fleet row.
    private static let rowMarkers: Set<Character> = ["❯", ">", "⏺", "◯", "○", "●", "◌", "✓", "✗", "•", "-"]

    private static let tokensBytes = ContiguousArray("tokens".utf8)

    /// Every fleet row carrying a live counter, session row excluded.
    static func rows(in lines: [String]) -> [Row] {
        var result: [Row] = []
        for line in lines {
            // The counter always ends in this word; most rows lack it.
            guard AgentDetectionRegions.containsBytes(line, tokensBytes),
                  let match = line.firstMatch(of: counterSuffix) else { continue }
            let prefix = line[line.startIndex..<match.range.lowerBound]
            // The session's own status line prints the same counter, but
            // parenthesized ("✻ Waddling… (2m 49s · ↓ 5.1k tokens · …)")
            // and after a spinner glyph. Both disqualify a fleet row.
            if prefix.contains("(") { continue }
            let trimmed = prefix.drop(while: \.isWhitespace)
            if let first = trimmed.first, spinnerGlyphs.contains(first) { continue }
            let label = name(from: trimmed)
            guard !label.isEmpty, label.lowercased() != "main" else { continue }
            let hours = match.output.1.flatMap { Double($0) } ?? 0
            let minutes = match.output.2.flatMap { Double($0) } ?? 0
            let seconds = Double(match.output.3) ?? 0
            result.append(Row(label: label, elapsed: hours * 3600 + minutes * 60 + seconds))
        }
        return result
    }

    /// The count claude states itself, when the status line is on screen.
    /// Authoritative: it survives even when the list is scrolled or
    /// truncated out of the snapshot. Current claude leaves each "Waiting
    /// for N" in the transcript, so only the transcript's last entry counts,
    /// unwrapped so a narrow pane's line breaks can't split the phrase.
    static func waitingCount(in input: AgentDetectionInput) -> Int? {
        let block = AgentDetectionRegions.extract("last_block_above_prompt_box", from: input)
        let flat = block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.firstMatch(of: waitingLine).flatMap { Int($0.output.1) }
    }

    /// Strip the selector/status glyphs, then keep the name column only —
    /// the activity text is separated from it by a column gap.
    private static func name(from prefix: some StringProtocol) -> String {
        var body = Substring(prefix)
        while let first = body.first, rowMarkers.contains(first) || first.isWhitespace {
            body = body.dropFirst()
        }
        if let gap = body.range(of: "  ") {
            body = body[body.startIndex..<gap.lowerBound]
        }
        return body.trimmingCharacters(in: .whitespaces)
    }
}
