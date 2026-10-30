//
//  TmuxExposeAdapter.swift
//  rootshell
//
//  Plain tmux (not control mode): one `list-panes -s` row per pane gives the
//  whole session's windows and geometry; `capture-pane -p -e -N` gives a
//  pane's colored rows. tmux has no per-pane output counter the app can rely
//  on, so the row's activity/history/cursor tuple is only a hint and the
//  frame revision is a hash of the capture.
//

import Foundation

nonisolated struct TmuxExposeAdapter: MultiplexerExposeAdapter {
    let type = MultiplexerType.tmux
    var socket: TmuxSocketIdentity = .defaultServer

    private var tmuxCommand: String { "tmux \(socket.arguments)" }

    /// Printable separator: control characters don't survive every transport.
    static let separator = "<|>"
    /// window_name and pane_title last: free text that may itself contain the separator.
    private static let fields = [
        "window_id", "window_index", "window_active", "window_width", "window_height",
        "window_activity", "window_raw_flags", "pane_id", "pane_active", "pane_left", "pane_top",
        "pane_width", "pane_height", "history_size", "cursor_x", "cursor_y", "cursor_flag",
        "pane_current_path", "window_name", "pane_title",
    ]
    private static let format = fields.map { $0 == "pane_current_path" ? "#{q:pane_current_path}" : "#{\($0)}" }
        .joined(separator: separator)

    private func target(_ session: String?) -> String {
        session.map { " -t \(MuxScript.dq("=\($0)"))" } ?? ""
    }

    func resolveSessionScript(nonce: String) -> String {
        MuxScript.wrap(
            "echo \(MuxScript.dq(MuxScript.topology(nonce))); \(tmuxCommand)list-sessions -F \"#{session_name}\" 2>/dev/null",
            nonce: nonce
        )
    }

    func tickScript(session: String?, request: MuxTickRequest, nonce: String) -> String {
        var body = "command -v tmux >/dev/null 2>&1 || echo \(MuxScript.dq(MuxScript.unsupportedMarker))"
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce)))"
        body += "; \(tmuxCommand)list-panes -s\(target(session)) -F \(MuxScript.dq(Self.format)) 2>/dev/null"
        for paneID in request.fetch {
            let id = MuxScript.dq(paneID)
            body += "; \(MuxScript.paneMarker(nonce: nonce, id: paneID))"
            // -N (keep trailing spaces, 3.1+) so colored bars keep their width; older tmux falls back.
            body += "; \(tmuxCommand)capture-pane -p -e -N -t \(id) 2>/dev/null || \(tmuxCommand)capture-pane -p -e -t \(id) 2>/dev/null"
        }
        return MuxScript.wrap(body, nonce: nonce)
    }

    private struct Row {
        let windowID: String
        let windowIndex: Int
        let windowActive: Bool
        let windowWidth: Int
        let windowHeight: Int
        let activity: String
        let flags: String
        let paneID: String
        let paneActive: Bool
        let rect: MuxCellRect
        let historySize: String
        let cursor: MuxCursor
        let workingDirectory: String?
        let windowName: String
        let paneTitle: String
    }

    private func row(_ line: Substring) -> Row? {
        let parts = line.components(separatedBy: Self.separator)
        guard parts.count >= Self.fields.count else { return nil }
        func int(_ i: Int) -> Int { Int(parts[i]) ?? 0 }
        return Row(
            windowID: parts[0],
            windowIndex: int(1),
            windowActive: parts[2] == "1",
            windowWidth: int(3),
            windowHeight: int(4),
            activity: parts[5],
            flags: parts[6],
            paneID: parts[7],
            paneActive: parts[8] == "1",
            rect: MuxCellRect(x: int(9), y: int(10), width: int(11), height: int(12)),
            historySize: parts[13],
            cursor: MuxCursor(x: int(14), y: int(15), visible: parts[16] != "0"),
            workingDirectory: Self.unescapePath(parts[17]),
            windowName: parts[18],
            paneTitle: parts[19...].joined(separator: Self.separator)
        )
    }

    private static func unescapePath(_ word: String) -> String? {
        var result = ""
        var escaped = false
        for character in word {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        return !escaped && result.hasPrefix("/") ? result : nil
    }

    func parseTick(output: String, session _: String?, nonce: String) -> MuxTickResult? {
        let sections = MuxScript.sections(of: output, nonce: nonce)
        guard sections.found, !sections.unsupported else { return nil }
        let rows = sections.topology.split(separator: "\n").compactMap(row)
        guard !rows.isEmpty else { return nil }

        var order: [String] = []
        var byWindow: [String: [Row]] = [:]
        for r in rows {
            if byWindow[r.windowID] == nil { order.append(r.windowID) }
            byWindow[r.windowID, default: []].append(r)
        }
        order.sort { (byWindow[$0]?.first?.windowIndex ?? 0) < (byWindow[$1]?.first?.windowIndex ?? 0) }

        var tabs: [MuxTab] = []
        var cursors: [String: MuxCursor] = [:]
        var hints: [String: String] = [:]
        for (index, windowID) in order.enumerated() {
            guard let group = byWindow[windowID], let first = group.first else { continue }
            let zoomed = first.flags.contains("Z")
            var panes: [MuxPane] = []
            for r in group {
                cursors[r.paneID] = r.cursor
                hints[r.paneID] = "\(r.activity)|\(r.historySize)|\(r.cursor.x)|\(r.cursor.y)|\(r.rect.width)x\(r.rect.height)"
                // A zoomed window previews only its active pane, but its other
                // panes remain in topology for the sidebar.
                let hiddenByZoom = zoomed && !r.paneActive
                let rect = hiddenByZoom
                    ? MuxCellRect(x: 0, y: 0, width: 0, height: 0)
                    : zoomed
                    ? MuxCellRect(x: 0, y: 0, width: first.windowWidth, height: first.windowHeight)
                    : r.rect
                panes.append(MuxPane(id: r.paneID, rect: rect, isActive: r.paneActive,
                                     isPreviewable: !hiddenByZoom, title: r.paneTitle,
                                     workingDirectory: r.workingDirectory))
            }
            let badgeFlags = first.flags.filter { "#!~Z".contains($0) }
            tabs.append(MuxTab(
                id: windowID,
                index: index,
                title: first.windowName.isEmpty ? "\(first.windowIndex)" : "\(first.windowIndex): \(first.windowName)",
                isActive: first.windowActive,
                cols: first.windowWidth,
                rows: first.windowHeight,
                panes: panes,
                badge: badgeFlags.isEmpty ? nil : String(badgeFlags)
            ))
        }

        var frames: [String: MuxPaneFrame] = [:]
        for section in sections.panes {
            // SGR state is threaded across the whole capture; close it.
            let ansi = section.body + "\u{1b}[0m"
            frames[section.id] = MuxPaneFrame(
                ansi: ansi,
                cursor: cursors[section.id],
                revision: MuxExposeIdentity.contentRevision(section.body)
            )
        }
        var result = MuxTickResult(
            snapshot: MuxExposeSnapshot(tabs: tabs, activeTabID: tabs.first(where: \.isActive)?.id),
            frames: frames,
            unchanged: [],
            truncated: sections.truncated
        )
        result.changeHints = hints
        return result
    }

    func focusScript(session: String?, tabID: String) -> String {
        let spec = session.map { "=\($0):\(tabID)" } ?? tabID
        return MuxScript.wrap("\(tmuxCommand)select-window -t \(MuxScript.dq(spec))", nonce: "focus")
    }

    func focusPaneScript(session: String?, tabID: String, paneID: String) -> String? {
        let window = session.map { "=\($0):\(tabID)" } ?? tabID
        return MuxScript.wrap(
            "\(tmuxCommand)select-window -t \(MuxScript.dq(window)) && \(tmuxCommand)select-pane -t \(MuxScript.dq(paneID))",
            nonce: "focus-pane"
        )
    }
}
