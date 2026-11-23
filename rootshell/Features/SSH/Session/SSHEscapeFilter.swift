import Foundation

/// OpenSSH-compatible escape-character filter for the user-input side of an SSH session.
///
/// Matches the state machine in `process_escapes()` in OpenSSH's `clientloop.c`: an
/// escape byte (default `~`) is only recognized when it appears immediately after a
/// newline (`\r` or `\n`), or as the very first byte of the session. The filter
/// transforms the input byte stream and fires side-effect closures for recognized
/// escapes (`~.`, `~?`, `~#`, `~I`). Unknown escapes (`~x`) pass through literally as
/// `~x`, matching OpenSSH's default-case behavior.
///
/// In addition to OpenSSH's behavior, the filter recognizes bracketed-paste
/// boundaries (`ESC[200~` / `ESC[201~`). While inside a paste, escape detection is
/// suspended and bytes pass through verbatim — so pasted content containing a line
/// starting with `~.` will NOT disconnect the session. Paste markers themselves do
/// not update the line-start tracking; the last *content* byte before the closing
/// marker determines whether a subsequent `~.` (typed after the paste) triggers.
nonisolated final class SSHEscapeFilter {
    /// Whether escape processing is active. Disabled filter passes all bytes through.
    var enabled: Bool = true

    /// The escape byte. Defaults to `~` (0x7E).
    var escapeChar: UInt8 = 0x7E

    /// Called when the filter needs to write bytes to the local terminal display
    /// (e.g., `~.` feedback, `~?` help text, `~I` connection info).
    var onEcho: ((String) -> Void)?

    /// Called when the user requested a disconnect via `~.`. The filter consumes
    /// both bytes and emits no remote output; the session should call `stop()`.
    var onDisconnect: (() -> Void)?

    /// Called when the user requested connection info via `~I`. The session should
    /// format its connection details and pass them to `onEcho`.
    var onShowConnectionInfo: (() -> Void)?

    /// Called when the user requested the forwarded-connections list via `~#`.
    /// The session should echo its forwarding state (or "none") via `onEcho`.
    var onListForwards: (() -> Void)?

    /// `true` when the previous content byte was `\r` or `\n`, making the next byte
    /// a candidate for escape recognition. Paste-marker bytes do not count as
    /// "content" and therefore don't change this flag. Initialized to `true` so
    /// `~.` as the very first bytes of a session works, matching OpenSSH.
    private var lastWasNewline: Bool = true

    /// `true` when the previous content byte was the escape character at a line
    /// start, so the current byte is the command portion of an escape sequence.
    private var escapePending: Bool = false

    /// Bracketed-paste state. `ESC[200~` enters paste mode; `ESC[201~` exits.
    private enum PasteState {
        case idle
        case matchingStart(n: Int)
        case inside
        case matchingEnd(n: Int)
    }
    private var pasteState: PasteState = .idle

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC [ 2 0 0 ~
    private static let pasteEnd:   [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~

    /// Filter `data` and return the bytes to forward to the remote channel.
    /// Side effects (echo, disconnect) fire synchronously via the closures above.
    func filter(_ data: Data) -> Data {
        guard enabled else { return data }
        guard !data.isEmpty else { return data }

        // Zero-allocation fast path: common interactive typing and pastes without
        // ESC or a line-start escape character pass straight through untouched.
        let isPlain = data.withUnsafeBytes { raw -> Bool in
            guard plainRunEnd(raw, from: 0) == raw.count else { return false }
            lastWasNewline = Self.isNewline(raw[raw.count - 1])
            return true
        }
        if isPlain { return data }

        var out = Data()
        out.reserveCapacity(data.count)

        data.withUnsafeBytes { raw in
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let run = plainRunEnd(raw, from: i)
                if run > i {
                    out.append(UnsafeBufferPointer(rebasing: bytes[i..<run]))
                    lastWasNewline = Self.isNewline(bytes[run - 1])
                    i = run
                    if i == bytes.count { break }
                }
                processByte(bytes[i], into: &out)
                i += 1
            }
        }

        // Flush any partial paste-marker state at end-of-buffer. The upstream
        // paste coalescer guarantees a real bracketed paste arrives as a single
        // contiguous buffer, so a partial marker here means the held bytes were
        // actually a standalone ESC key press, an arrow key, or the first bytes
        // of a CSI sequence split across writes — not the start or end of a
        // paste. Flush so vim / readline / etc. see the bytes immediately
        // instead of stalling until the next keystroke.
        flushPartialMarker(into: &out)

        return out
    }

    private func flushPartialMarker(into out: inout Data) {
        switch pasteState {
        case .matchingStart(let n):
            for b in Self.pasteStart.prefix(n) {
                out.append(b)
                lastWasNewline = (b == 0x0D || b == 0x0A)
            }
            pasteState = .idle

        case .matchingEnd(let n):
            // Treat the held bytes as paste content (they arrived inside a
            // paste) and stay in `.inside`. Paste end markers never split
            // across calls in practice, so this primarily keeps us in a
            // consistent state if they ever did.
            for b in Self.pasteEnd.prefix(n) {
                out.append(b)
                lastWasNewline = (b == 0x0D || b == 0x0A)
            }
            pasteState = .inside

        case .idle, .inside:
            break
        }
    }

    /// Reset per-session state. Not normally needed since sessions are one-shot.
    func reset() {
        lastWasNewline = true
        escapePending = false
        pasteState = .idle
    }

    /// Message shown by `~#` when the session has no active port forwards.
    static func noForwardsMessage() -> String {
        String(
            localized: "No forwarded connections.",
            comment: "Response to the SSH ~# escape when there are no active port forwards"
        ) + "\r\n"
    }

    /// Short localized label for a forward's runtime status, used by `~#`.
    static func describe(forwardStatus status: PortForwardStatus) -> String {
        switch status {
        case .pending:
            return String(
                localized: "pending",
                comment: "Status label for a port forward awaiting start"
            )
        case .active:
            return String(
                localized: "active",
                comment: "Status label for a currently working port forward"
            )
        case .stopped:
            return String(
                localized: "stopped",
                comment: "Status label for a manually stopped port forward"
            )
        case .failed(let message):
            let label = String(
                localized: "failed",
                comment: "Status label for a port forward that failed to start or crashed"
            )
            return "\(label): \(message)"
        }
    }

    // MARK: - State machine

    /// End of the run from `start` that `processByte` would copy through
    /// verbatim: up to the next ESC, or an escape char at a line start.
    private func plainRunEnd(_ raw: UnsafeRawBufferPointer, from start: Int) -> Int {
        switch pasteState {
        case .matchingStart, .matchingEnd:
            return start
        case .inside:
            return raw.firstOffset(of: 0x1B, in: start..<raw.count) ?? raw.count
        case .idle:
            guard !escapePending else { return start }
            let esc = raw.firstOffset(of: 0x1B, in: start..<raw.count) ?? raw.count
            var cursor = start
            while let hit = raw.firstOffset(of: escapeChar, in: cursor..<esc) {
                if hit == start ? lastWasNewline : Self.isNewline(raw[hit - 1]) { return hit }
                cursor = hit + 1
            }
            return esc
        }
    }

    private static func isNewline(_ byte: UInt8) -> Bool {
        byte == 0x0D || byte == 0x0A
    }

    private func processByte(_ byte: UInt8, into out: inout Data) {
        switch pasteState {
        case .idle:
            processIdle(byte, into: &out)

        case .matchingStart(let n):
            if byte == Self.pasteStart[n] {
                let newN = n + 1
                if newN == Self.pasteStart.count {
                    // Full start marker matched. Emit marker as a whole; don't touch
                    // lastWasNewline — marker bytes aren't "content".
                    out.append(contentsOf: Self.pasteStart)
                    pasteState = .inside
                } else {
                    pasteState = .matchingStart(n: newN)
                }
            } else {
                // Mismatch: the bytes we were holding were not actually a paste
                // start. Flush them as content, then reprocess the current byte
                // through the idle path.
                for b in Self.pasteStart.prefix(n) {
                    out.append(b)
                    lastWasNewline = (b == 0x0D || b == 0x0A)
                }
                pasteState = .idle
                processIdle(byte, into: &out)
            }

        case .inside:
            processInside(byte, into: &out)

        case .matchingEnd(let n):
            if byte == Self.pasteEnd[n] {
                let newN = n + 1
                if newN == Self.pasteEnd.count {
                    // Full end marker matched. Emit marker; don't touch
                    // lastWasNewline — marker bytes aren't "content".
                    out.append(contentsOf: Self.pasteEnd)
                    pasteState = .idle
                } else {
                    pasteState = .matchingEnd(n: newN)
                }
            } else {
                // Mismatch: the held bytes were part of paste content, not an end
                // marker. Flush them and reprocess the current byte as .inside.
                for b in Self.pasteEnd.prefix(n) {
                    out.append(b)
                    lastWasNewline = (b == 0x0D || b == 0x0A)
                }
                pasteState = .inside
                processInside(byte, into: &out)
            }
        }
    }

    private func processIdle(_ byte: UInt8, into out: inout Data) {
        if escapePending {
            escapePending = false
            if handleEscape(byte, into: &out) {
                return
            }
            // Fall-through for `~~` and unknown `~x`: append byte as normal.
            out.append(byte)
            lastWasNewline = (byte == 0x0D || byte == 0x0A)
            return
        }

        // Watch for a paste-start marker. First byte of the marker is 0x1B (ESC),
        // which never collides with escapeChar (0x7E) so order vs. escape detection
        // is moot. Hold the byte rather than emitting immediately so we can emit
        // the marker atomically on completion.
        if byte == Self.pasteStart[0] {
            pasteState = .matchingStart(n: 1)
            return
        }

        if lastWasNewline && byte == escapeChar {
            escapePending = true
            return
        }

        out.append(byte)
        lastWasNewline = (byte == 0x0D || byte == 0x0A)
    }

    private func processInside(_ byte: UInt8, into out: inout Data) {
        // Hold the byte if it might start an end marker; otherwise emit verbatim
        // and update lastWasNewline based on the content byte.
        if byte == Self.pasteEnd[0] {
            pasteState = .matchingEnd(n: 1)
            return
        }
        out.append(byte)
        lastWasNewline = (byte == 0x0D || byte == 0x0A)
    }

    /// Handles the second byte of a `~X` pair.
    /// Returns `true` if the escape was fully consumed (no further processing).
    /// Returns `false` to indicate the caller should process `byte` as a normal
    /// character (used for `~~` and unknown `~x`).
    private func handleEscape(_ byte: UInt8, into out: inout Data) -> Bool {
        switch byte {
        case 0x2E: // '.'
            onEcho?("\(asciiEscapeCharString()).\r\n")
            onDisconnect?()
            return true

        case 0x3F: // '?'
            onEcho?(Self.helpText(escapeChar: asciiEscapeCharString()))
            return true

        case 0x23: // '#'
            onEcho?("\(asciiEscapeCharString())#\r\n")
            onListForwards?()
            return true

        case 0x49: // 'I'
            onEcho?("\(asciiEscapeCharString())I\r\n")
            onShowConnectionInfo?()
            return true

        case escapeChar:
            // `~~` → emit single escape char literally. Fall through so the caller
            // appends `byte` (the tilde) and updates lastWasNewline accordingly.
            return false

        default:
            // Unknown `~x` → emit escape char, then fall through so caller appends
            // `byte`. Result: `~x` as literal bytes. Matches OpenSSH default case.
            out.append(escapeChar)
            return false
        }
    }

    private func asciiEscapeCharString() -> String {
        String(UnicodeScalar(escapeChar))
    }

    /// Help text shown by `~?`. Each line is localized individually so translators
    /// can adjust phrasing without touching the surrounding layout.
    private static func helpText(escapeChar c: String) -> String {
        let lines: [String] = [
            "\(c)?",
            String(
                localized: "Supported escape sequences:",
                comment: "Header for the SSH ~? escape help output"
            ),
            String(
                localized: "  \(c).   - terminate connection",
                comment: "Description of the SSH ~. escape"
            ),
            String(
                localized: "  \(c)?   - this message",
                comment: "Description of the SSH ~? escape"
            ),
            String(
                localized: "  \(c)#   - list forwarded connections",
                comment: "Description of the SSH ~# escape"
            ),
            String(
                localized: "  \(c)I   - connection info",
                comment: "Description of the SSH ~I escape"
            ),
            String(
                localized: "  \(c)\(c)   - send the escape character literally",
                comment: "Description of the SSH ~~ escape"
            ),
            String(
                localized: "(The escape character is only recognized at the start of a line.)",
                comment: "Footer for the SSH ~? escape help output"
            ),
            "",
        ]
        return lines.joined(separator: "\r\n")
    }
}
