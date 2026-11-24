//
//  TmuxPanePathParser.swift
//  rootshell
//
//  Parses `list-panes -a -F "#{pane_id} #{pane_current_path}"` replies.
//
//  Pure and Foundation-only so tests/agent-attention/run.sh compiles it: the
//  first version of this parser split on "\n" alone, which silently collapsed
//  a `\r`-separated control-mode reply into ONE line. It reported a single
//  pane out of five, and every pane but the first failed to resolve — with no
//  error anywhere, because a short answer looks exactly like a small server.
//

import Foundation

nonisolated enum TmuxPanePathParser {

    /// Maps tmux pane id (the numeric part of `%N`) to its working directory.
    ///
    /// Tolerant by design: unparseable lines are skipped rather than failing
    /// the whole reply, because a partial answer still resolves most panes.
    static func parse(_ body: String) -> [Int: String] {
        var result: [Int: String] = [:]

        // Use `isNewline`, not a comparison against "\n"/"\r". Two traps here,
        // both hit for real: splitting on "\n" alone collapses a CR-separated
        // reply into one giant line whose "path" swallows every remaining
        // pane, and in Swift "\r\n" is a SINGLE Character, so
        // `$0 == "\n" || $0 == "\r"` matches neither and a CRLF reply does not
        // split at all. `isNewline` is true for CR, LF, and CRLF alike.
        for line in body.split(whereSeparator: \.isNewline) {
            // `%12 /home/example/dev/x`. Split at the FIRST space only: a path may
            // legitimately contain spaces.
            guard let separator = line.firstIndex(of: " ") else { continue }
            let rawId = line[line.startIndex..<separator]
            guard rawId.hasPrefix("%"), let paneId = Int(rawId.dropFirst()) else { continue }

            let path = String(line[line.index(after: separator)...])
            guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result[paneId] = path
        }
        return result
    }
}

/// User-facing identity reported by tmux for one pane.
///
/// `pane_title` is the title applications inside the pane publish to tmux.
/// `pane_current_command` gives us a useful last resort for shells/programs
/// that do not publish a title.
nonisolated struct TmuxPaneDisplayIdentity: Equatable, Sendable {
    let title: String
    let currentCommand: String
}

/// Parses `list-panes -a -F
/// "#{pane_id}\t#{pane_title}\t#{pane_current_command}"` replies.
nonisolated enum TmuxPaneDisplayIdentityParser {
    static func parse(_ body: String) -> [Int: TmuxPaneDisplayIdentity] {
        var result: [Int: TmuxPaneDisplayIdentity] = [:]

        for line in body.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0].hasPrefix("%"),
                  let paneID = Int(fields[0].dropFirst())
            else { continue }

            result[paneID] = TmuxPaneDisplayIdentity(
                title: String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines),
                currentCommand: String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return result
    }
}
