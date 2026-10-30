//
//  ZmxExposeAdapter.swift
//  rootshell
//

import Foundation

nonisolated struct ZmxExposeAdapter: MultiplexerExposeAdapter {
    var type: MultiplexerType { .zmx }

    /// Identifies this pane's own processes on the host, so a switch can act
    /// on the client belonging to it rather than any other attached terminal.
    let paneToken: String?

    init(paneToken: String? = nil) {
        self.paneToken = paneToken
    }

    /// `zmx list` probes session sockets serially, so use a slower tick rate.
    var minInterval: TimeInterval { 1.5 }

    /// Listed names already include `ZMX_SESSION_PREFIX`, so clear it before
    /// passing those names to other zmx subcommands.
    private static let prefix = "ZMX_SESSION_PREFIX= "

    /// Tail by lines so the VT prelude cannot change preview-surface modes.
    private static let captureRows = 80

    // MARK: - Scripts

    func resolveSessionScript(nonce: String) -> String {
        // `--short` omits unreachable sessions.
        MuxScript.wrap(
            "echo \(MuxScript.dq(MuxScript.topology(nonce)))"
            + "; \(Self.prefix)zmx list --short 2>/dev/null",
            nonce: nonce
        )
    }

    func tickScript(session: String?, request: MuxTickRequest, nonce: String) -> String {
        var body = "command -v zmx >/dev/null 2>&1 || echo \(MuxScript.dq(MuxScript.unsupportedMarker))"
        // Time out individual captures without truncating the serial listing.
        body += "; _zt=\"\"; command -v timeout >/dev/null 2>&1 && _zt=\"timeout 2\""
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce)))"
        body += "; echo \"::SESSIONS::\""
        body += "; \(Self.prefix)${_zt:+timeout 5} zmx list 2>/dev/null"
        for name in request.fetch {
            body += "; \(MuxScript.paneMarker(nonce: nonce, id: name))"
            body += "; \(Self.prefix)$_zt zmx history \(MuxScript.dq(name)) --vt 2>/dev/null"
            body += " | tail -n \(Self.captureRows)"
            // History may end mid-line; keep the next section marker separate.
            body += "; echo"
        }
        return MuxScript.wrap(body, nonce: nonce)
    }

    /// zmx sends this switch to the session's leader client, not to the pane
    /// that asked (neurosnap/zmx#260). The feed only runs it for a pane with no
    /// client of its own to replace that holds its session alone, so the leader
    /// is this pane or nobody; a vacant leadership is taken by resize, which
    /// costs the running program nothing.
    func focusScript(session: String?, tabID: String) -> String {
        guard let session, !session.isEmpty, session != tabID else {
            return MuxScript.wrap("true", nonce: Self.focusNonce)
        }
        var body = "echo \(MuxScript.dq(MuxScript.topology(Self.focusNonce)))"
        body += "; echo \(MuxScript.dq(Self.focusBeforeMarker)); \(Self.prefix)zmx list 2>/dev/null"
        if let paneToken, !paneToken.isEmpty {
            // Nothing in the protocol orders these, so the margin is wall
            // clock: the signalled client has to have sent its size before
            // `zmx attach` opens its own connection. Both hops are local to
            // the host and the switch still has a process to fork, so the
            // margin is wide. Losing the race costs only the switch, which
            // is what happened before any of this ran.
            body += "; \(Self.claimLeadershipBody(paneToken: paneToken)); sleep 0.15"
        }
        body += "; ZMX_SESSION=\(MuxScript.dq(session)) \(Self.prefix)zmx attach \(MuxScript.dq(tabID)) >/dev/null 2>&1"
        // The switch is fire-and-forget; wait before collecting confirmation.
        body += "; sleep 0.3"
        body += "; echo \(MuxScript.dq(Self.focusAfterMarker)); \(Self.prefix)zmx list 2>/dev/null"
        return MuxScript.wrap(body, nonce: Self.focusNonce)
    }

    /// Makes this pane's client the session's leader when no client is.
    ///
    /// zmx clears the leader when that client disconnects, and only user input
    /// sets it again, so a session routinely outlives its leader with none.
    /// Through zmx 0.8.1 a switch sent in that state is fatal: the daemon
    /// answers with an unhandled error and takes the session down, along with
    /// every terminal still attached to it. Fixed upstream in `fca1964d`, where
    /// the switch becomes a no-op instead, so this also stops mattering on
    /// hosts running a newer zmx (neurosnap/zmx#259).
    ///
    /// SIGWINCH makes a client resend its size, and a size takes leadership
    /// when no client holds it. It puts no bytes into the running program, and
    /// zmx ignores it outright while another client is leader, so it can never
    /// pull a session out from under somebody else's terminal.
    ///
    /// Only the pane's own zmx processes are signalled. Its forked daemon
    /// carries the same token and installs no handler, so reaching that one
    /// costs nothing.
    ///
    /// The token lives in the client's environment, which `/proc` exposes
    /// directly and macOS does not. There `ps -E` prints each process's
    /// environment after its arguments, flattened onto one line, so the match
    /// is against a whitespace-split token rather than a whole line. One scan
    /// is taken and reused, rather than a `ps` per candidate.
    ///
    /// macOS hides the environment of platform binaries, so this reads a zmx
    /// the user installed and would come back empty for one shipped with the
    /// system. zmx is not, and the pane simply keeps its leadership alone if
    /// that ever changes.
    private static func claimLeadershipBody(paneToken: String) -> String {
        let needle = MuxScript.dq("\(TerminalIdentity.paneTokenVariable)=\(paneToken)")
        // Only scanned when /proc is absent, and narrowed to lines carrying the
        // token so the environments of unrelated processes are never held.
        var body = "_mxenv=\"\"; [ -r /proc/self/environ ]"
        body += " || _mxenv=$(ps -xEo pid=,command= 2>/dev/null | grep -F \(needle))"
        body += "; for _p in $(ps -xo pid=,comm= 2>/dev/null | grep -E \"[ /]zmx$\""
        body += " | awk \"{print \\$1}\"); do"
        body += " if [ -r \"/proc/$_p/environ\" ]; then"
        body += " tr \"\\0\" \"\\n\" < \"/proc/$_p/environ\" 2>/dev/null"
        body += " | grep -qxF \(needle) || continue;"
        body += " else"
        body += " printf \"%s\\n\" \"$_mxenv\" | awk -v p=\"$_p\" \"\\$1==p\""
        body += " | tr \" \" \"\\n\" | grep -qxF \(needle) || continue;"
        body += " fi;"
        body += " kill -WINCH \"$_p\" 2>/dev/null;"
        body += " done"
        return body
    }

    /// Confirms the fire-and-forget switch by comparing client counts. The
    /// deltas say that a client moved, never which one, so this declines for a
    /// session other clients share rather than name the pane after a session
    /// it may never have entered.
    func parseFocusResult(output: String, session: String?, tabID: String) -> Bool {
        guard let session, !session.isEmpty, session != tabID else {
            return true
        }
        let sections = MuxScript.sections(of: output, nonce: Self.focusNonce)
        guard sections.found else { return false }
        guard let beforeSplit = sections.topology.range(of: Self.focusBeforeMarker) else { return false }
        let afterTopology = sections.topology[beforeSplit.upperBound...]
        guard let afterSplit = afterTopology.range(of: Self.focusAfterMarker) else { return false }
        let beforeText = String(afterTopology[..<afterSplit.lowerBound])
        let afterText = String(afterTopology[afterSplit.upperBound...])

        let before = ZmxDiscoveryParser.parse(output: "::SESSIONS::\n" + beforeText)
        let after = ZmxDiscoveryParser.parse(output: "::SESSIONS::\n" + afterText)

        guard let beforeSessionClients = before.first(where: { $0.name == session })?.clientCount,
              beforeSessionClients == 1
        else { return false }
        guard let afterSessionClients = after.first(where: { $0.name == session })?.clientCount,
              let beforeTargetClients = before.first(where: { $0.name == tabID })?.clientCount,
              let afterTargetClients = after.first(where: { $0.name == tabID })?.clientCount
        else { return false }

        return afterSessionClients < beforeSessionClients && afterTargetClients > beforeTargetClients
    }

    private static let focusNonce = "focus"
    private static let focusBeforeMarker = "::MX_FOCUS_BEFORE::"
    private static let focusAfterMarker = "::MX_FOCUS_AFTER::"

    // MARK: - Parsing

    func parseTick(output: String, session: String?, nonce: String) -> MuxTickResult? {
        let sections = MuxScript.sections(of: output, nonce: nonce)
        guard sections.found, !sections.unsupported else { return nil }

        let sessions = ZmxDiscoveryParser.parse(output: sections.topology)
        census.sessions = Set(sessions.map(\.name))
        guard !sessions.isEmpty else { return nil }

        // Feeds the switch gate and the bound-session liveness check from
        // the listing already in hand.
        census.clients = sessions.reduce(into: [:]) { counts, info in
            if let clients = info.clientCount { counts[info.name] = clients }
        }

        // A zmx detach leaves the underlying shell/connection alive, so the
        // terminal's passthrough binding does not get the normal
        // `sessionDidEnd()` teardown. The bound session having no clients is
        // the one reliable indication that this pane is no longer inside zmx;
        // make the tick unusable so the feed can release that stale identity.
        // Keep an absent count as unknown for compatibility with older zmx
        // output rather than falsely dropping a live binding.
        if !sections.truncated,
           let session,
           boundSessionIsUnavailable(session) { return nil }

        var frames: [String: MuxPaneFrame] = [:]
        for section in sections.panes {
            let screen = Self.visibleScreen(section.body)
            guard !screen.isEmpty else { continue }
            let measured = Self.measure(screen)
            let restoredState = Self.restoredTerminalState(section.body)
            // Ignore captures whose row count may be limited by the history cap.
            let rows: Int? = {
                if restoredState.alternateScreen {
                    return measured.rows < Self.captureRows ? measured.rows : nil
                }
                if let cursorRow = restoredState.cursorRow {
                    return max(cursorRow, Self.minRows)
                }
                return measured.rows < Self.captureRows ? measured.rows : nil
            }()
            if let rows {
                geometryCache.record(session: section.id, cols: measured.cols, rows: rows)
            }
            frames[section.id] = MuxPaneFrame(
                // SGR state is threaded across the whole capture and the tail
                // cut the opening of it; close it so one session's colour
                // cannot bleed past its own cell.
                ansi: screen + "\u{1B}[0m",
                cursor: nil,
                revision: MuxExposeIdentity.contentRevision(screen)
            )
        }
        // A session `zmx list` no longer reports can never be recorded again,
        // so its window would otherwise sit in the cache forever.
        geometryCache.evict(keepingOnly: Set(sessions.map(\.name)))

        let tabs = sessions.enumerated().map { index, info in
            let measuredGrid = geometryCache.grid(for: info.name)
            // A session zmx has never attached to has no tty from which to
            // learn a size. zmx creates that terminal at its own 120x24
            // fallback, but a sparse screen (a shell prompt or quiet agent)
            // exposes only its occupied cells in `history --vt`. Treating
            // that content width as terminal width collapses the preview to
            // our ordinary 80-column floor until the first attach forces a
            // redraw. While clients=0, preserve zmx's exact fallback width;
            // still honor a wider measured capture when one exists.
            let grid = (
                cols: info.clientCount == 0
                    ? max(measuredGrid.cols, Self.fallbackGrid.cols)
                    : measuredGrid.cols,
                rows: measuredGrid.rows
            )
            return MuxTab(
                id: info.name,
                index: index,
                title: info.name,
                isActive: info.name == session,
                cols: grid.cols,
                rows: grid.rows,
                panes: [
                    MuxPane(
                        id: info.name,
                        rect: MuxCellRect(x: 0, y: 0, width: grid.cols, height: grid.rows),
                        isActive: true,
                        isPreviewable: true,
                        title: info.command,
                        workingDirectory: info.cwd
                    )
                ],
                badge: Self.badge(for: info)
            )
        }

        return MuxTickResult(
            snapshot: MuxExposeSnapshot(tabs: tabs, activeTabID: session),
            frames: frames,
            unchanged: [],
            truncated: sections.truncated
        )
    }

    // MARK: - Geometry

    /// zmx's own fallback when no client TTY supplies a size.
    private static let fallbackGrid = (cols: 120, rows: 24)

    /// Bucket the reported grid rounds up to, so a row that grows by a few
    /// columns between ticks does not change `MuxTab` (see `fallbackGrid`'s
    /// doc for why that matters).
    private static let colBucket = 16
    private static let rowBucket = 8
    private static let minCols = 80
    private static let minRows = 24
    /// Generous but bounded, so a pathological capture cannot allocate an
    /// unreasonably large offscreen surface.
    private static let maxCols = 320
    /// `captureRows` already bounds how many rows a capture can contain; this
    /// just restates that bound as the geometry ceiling.
    private static let maxRows = captureRows

    private static func quantize(_ value: Int, bucket: Int, floor: Int, ceiling: Int) -> Int {
        let rounded = ((max(value, 0) + bucket - 1) / bucket) * bucket
        return min(max(rounded, floor), ceiling)
    }

    /// Per-session geometry, confined to the feed's serialized tick loop.
    private final class GeometryCache: @unchecked Sendable {
        private struct Observation { let cols: Int; let rows: Int }
        private var windows: [String: [Observation]] = [:]
        /// Smooths a momentary narrow/wide frame while still following a real
        /// resize down within a handful of ticks, once the old high ages out.
        private static let windowSize = 4

        /// The grid currently in effect for `session`: the observation
        /// window's max, quantized; `fallbackGrid` if nothing was ever
        /// recorded for it.
        func grid(for session: String) -> (cols: Int, rows: Int) {
            guard let window = windows[session], !window.isEmpty else { return ZmxExposeAdapter.fallbackGrid }
            let cols = window.map(\.cols).max() ?? ZmxExposeAdapter.fallbackGrid.cols
            let rows = window.map(\.rows).max() ?? ZmxExposeAdapter.fallbackGrid.rows
            return (
                ZmxExposeAdapter.quantize(cols, bucket: ZmxExposeAdapter.colBucket, floor: ZmxExposeAdapter.minCols, ceiling: ZmxExposeAdapter.maxCols),
                ZmxExposeAdapter.quantize(rows, bucket: ZmxExposeAdapter.rowBucket, floor: ZmxExposeAdapter.minRows, ceiling: ZmxExposeAdapter.maxRows)
            )
        }

        /// Slides in a fresh measurement from this tick's capture of `session`.
        func record(session: String, cols: Int, rows: Int) {
            var window = windows[session] ?? []
            window.append(Observation(cols: cols, rows: rows))
            if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
            windows[session] = window
        }

        /// Drops sessions `zmx list` no longer reports, so this cannot grow
        /// without bound across a host's session churn.
        func evict(keepingOnly live: Set<String>) {
            windows = windows.filter { live.contains($0.key) }
        }
    }

    private let geometryCache = GeometryCache()

    /// Latest client census, confined to the feed's serialized tick loop.
    private final class Census: @unchecked Sendable {
        var clients: [String: Int] = [:]
        var sessions: Set<String> = []
    }

    private let census = Census()

    /// Client count captured by the latest topology tick, which decides
    /// whether the leader-routed switch can only move this pane.
    func clientCount(for session: String) -> Int? {
        census.clients[session]
    }

    /// Whether a completed listing proves that the pane's bound zmx session
    /// is no longer attached. A missing client count remains unknown; old zmx
    /// versions did not always emit that field.
    func boundSessionIsUnavailable(_ session: String) -> Bool {
        !census.sessions.contains(session) || census.clients[session] == 0
    }

    /// Cols/rows the capture's content actually needs: the widest row's
    /// display width and the row count. See `fallbackGrid`'s doc for why this
    /// is a sound measurement.
    static func measure(_ screen: String) -> (cols: Int, rows: Int) {
        // Split scalars because Swift treats CRLF as one Character.
        var rows: [[Unicode.Scalar]] = [[]]
        for scalar in screen.unicodeScalars {
            if scalar == "\n" {
                rows.append([])
            } else {
                rows[rows.count - 1].append(scalar)
            }
        }
        var widest = 0
        for var row in rows {
            if row.last == "\r" { row.removeLast() }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: row)
            widest = max(widest, DisplayWidth.width(of: Self.stripAnsi(String(view))))
        }
        return (widest, rows.count)
    }

    /// Terminal state that zmx's VT formatter appends to a history replay.
    ///
    /// The final CUP (`CSI row;column H`) restores the cursor. On the primary
    /// screen it is the only reliable row witness when the capture also holds
    /// scrollback. Alternate-screen mode (`DECSET 47/1047/1049`) means the
    /// captured rows are the TUI's screen instead, so `parseTick` keeps using
    /// the measured screen height there.
    static func restoredTerminalState(_ capture: String) -> (cursorRow: Int?, alternateScreen: Bool) {
        let bytes = Array(capture.utf8)
        var cursorRow: Int?
        var alternateScreen = false
        var index = 0

        while index + 2 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == 0x5B else {
                index += 1
                continue
            }

            var end = index + 2
            while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) {
                end += 1
            }
            guard end < bytes.count else { break }

            let final = bytes[end]
            let parameterBytes = bytes[(index + 2)..<end]
            let parameterText = String(decoding: parameterBytes, as: UTF8.self)

            if final == 0x48 || final == 0x66 { // H / f: CUP / HVP
                let first = parameterText.split(separator: ";", omittingEmptySubsequences: false).first
                cursorRow = max(Int(first ?? "") ?? 1, 1)
            } else if final == 0x68 || final == 0x6C, parameterText.hasPrefix("?") { // h / l
                let modes = parameterText.dropFirst().split(separator: ";").compactMap { Int($0) }
                if modes.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) {
                    alternateScreen = final == 0x68
                }
            }

            index = end + 1
        }

        return (cursorRow, alternateScreen)
    }

    /// Strips terminal control sequences before measuring display width.
    static func stripAnsi(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else {
                result.append(character)
                continue
            }
            guard let introducer = iterator.next() else { break }
            switch introducer {
            case "[":
                // CSI: skip parameter/intermediate bytes until a final byte (0x40-0x7E).
                while let byte = iterator.next() {
                    if let ascii = byte.asciiValue, (0x40...0x7E).contains(ascii) { break }
                }
            case "]":
                // OSC: terminated by BEL or ST (ESC \).
                var previous: Character?
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if previous == "\u{1B}", byte == "\\" { break }
                    previous = byte
                }
            case "P", "X", "^", "_":
                // DCS/SOS/PM/APC: terminated by ST (ESC \).
                var previous: Character?
                while let byte = iterator.next() {
                    if previous == "\u{1B}", byte == "\\" { break }
                    previous = byte
                }
            case "(", ")", "*", "+", "-", ".", "/":
                // Character-set designation: one more byte names the set
                // (`ESC ( 0` into line-drawing, `ESC ( B` back to ASCII).
                _ = iterator.next()
            default:
                // Two-character escape (ESC 7, ESC c, ...) -- already consumed.
                break
            }
        }
        return result
    }

    /// The capture reduced to what a screen would show.
    ///
    /// A full-screen program clears before drawing, so the bytes after the last
    /// erase-display are that program's screen and everything before it is
    /// scrollback. Without a clear the tail already stands in for the screen.
    static func visibleScreen(_ capture: String) -> String {
        var text = capture
        if let lastClear = text.range(of: "\u{1B}[2J", options: .backwards) {
            text = String(text[lastClear.upperBound...])
        }
        while text.hasPrefix("\n") || text.hasPrefix("\r") { text.removeFirst() }
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// Trailing caption note. The client count is the one fact worth surfacing:
    /// a pane that cannot replace its own client declines to switch away from a
    /// session another terminal also holds.
    private static func badge(for info: ZmxSessionInfo) -> String? {
        guard let clients = info.clientCount, clients > 1 else { return nil }
        return String(
            format: String(localized: "%d clients", comment: "zmx exposé cell badge, attached client count"),
            clients
        )
    }
}
