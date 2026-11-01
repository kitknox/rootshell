//
//  SSHBanner.swift
//  rootshell
//
//  Width-aware warning banners for SSH sessions.
//

import Foundation

/// Renders SSH session warning banners.
///
/// Modeled on `LocalShellBanner` — same left-bar-at-≥36-cols / stacked-narrow
/// split — but hard-coded to a warning accent (amber) rather than taking a
/// theme, since these are security warnings and should read consistently
/// across themes.
nonisolated enum SSHBanner {

    // MARK: - Public API

    /// Returns the post-connection warning banner for an SSH session, or
    /// nil if nothing needs to be warned about. Centralizes the rules so
    /// both session classes and the view-layer cleanup site can use it.
    ///
    /// Callers should emit this AFTER the connecting-animation cleanup
    /// sequence has been written, otherwise `clearToEndOfScreen` will wipe
    /// the banner.
    @MainActor
    static func postConnectionWarning(for session: SSHTerminalSession) -> String? {
        guard !SettingsStore.shared.get(Settings.Connections.hideNonPQKexWarning) else { return nil }
        guard case let .ssh(info)? = session.connectionInfo else { return nil }
        guard !info.isPostQuantumKeyExchange else { return nil }
        let cols = Int(session.pty.windowSize.cols)
        return renderNonPQKexWarning(columns: cols, kexAlgorithm: info.keyExchangeAlgorithm)
    }

    /// Renders a server auth banner (`SSH_MSG_USERAUTH_BANNER`) for inline
    /// display in the terminal, like real `ssh`. Normalizes line endings to
    /// CRLF and strips dangerous control/escape sequences while preserving a
    /// safe subset of ANSI (SGR color/style) so colored MOTD-style banners
    /// still render. Output is CRLF-terminated; emit verbatim after the
    /// connecting-spinner cleanup, otherwise `clearToEndOfScreen` wipes it.
    static func renderAuthBanner(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        // Normalize every newline form (\r\n, lone \r, lone \n) to \n, then
        // split — avoids the spurious blank line a naive split on both \r and
        // \n would insert for a \r\n pair.
        var normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map(sanitizeBannerLine)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Sanitizes a server auth banner for native (non-terminal) display, such
    /// as the auth-banner card. Unlike `renderAuthBanner`, ALL escape
    /// sequences are stripped — including SGR — because native views render
    /// plain text. Keeps printable Unicode and TAB, drops C0/C1 controls and
    /// DEL, normalizes line endings to `\n`, and trims surrounding whitespace.
    static func plainText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { line in
            let scalars = Array(line.unicodeScalars)
            var out = String.UnicodeScalarView()
            var i = 0
            while i < scalars.count {
                let v = scalars[i].value
                if v == 0x1b {
                    // ESC — consume the whole sequence, emit nothing (no SGR
                    // survives; native text has no use for it).
                    i = scanEscapeSequence(scalars, from: i).next
                } else if v == 0x09 {  // TAB
                    out.append(scalars[i]); i += 1
                } else if v < 0x20 || (v >= 0x7f && v <= 0x9f) {
                    i += 1  // C0 controls, DEL, C1 range
                } else {
                    out.append(scalars[i]); i += 1
                }
            }
            return String(out)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A server-supplied name or message interpolated into terminal output (error text, remote
    /// file names): `plainText` on one line, so it can't drive the terminal (cf. OpenSSH e3c9ed5ad).
    static func terminalSafe(_ raw: String) -> String {
        plainText(raw).replacingOccurrences(of: "\n", with: " ")
    }

    /// Extracts http/https URLs from sanitized plain text (the output of
    /// `plainText`), in order of first appearance, deduplicated, capped at 8.
    /// A deliberate manual scan rather than NSDataDetector: only explicit
    /// `http://` / `https://` prefixes qualify, so custom schemes and schemeless
    /// hosts in server-controlled pre-auth text never become tappable actions.
    static func extractHTTPURLs(from plainText: String) -> [URL] {
        let maxURLs = 8
        // Characters that end a URL token beyond whitespace: common banner
        // delimiters like <...>, quotes, and backticks.
        let terminators = Set<Character>(["<", ">", "\"", "'", "`"])
        // Trailing punctuation that is far more likely prose than URL.
        let trailing = Set<Character>([".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\""])

        var urls: [URL] = []
        var seen = Set<String>()
        var searchStart = plainText.startIndex
        while urls.count < maxURLs,
              let range = plainText.range(
                of: "http", options: [.caseInsensitive],
                range: searchStart..<plainText.endIndex
              ) {
            let candidateStart = range.lowerBound
            let rest = plainText[candidateStart...]
            guard rest.range(of: "http://", options: [.caseInsensitive, .anchored]) != nil
                || rest.range(of: "https://", options: [.caseInsensitive, .anchored]) != nil
            else {
                searchStart = plainText.index(after: candidateStart)
                continue
            }
            var end = candidateStart
            while end < plainText.endIndex {
                let c = plainText[end]
                if c.isWhitespace || c.isNewline || terminators.contains(c) { break }
                end = plainText.index(after: end)
            }
            var token = String(plainText[candidateStart..<end])
            while let last = token.last, trailing.contains(last) {
                token.removeLast()
            }
            searchStart = end
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty
            else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// Filters a banner line to printable text plus a safe subset of ANSI: only
    /// SGR color/style sequences (`ESC[…m` with standard params) survive. Every
    /// other escape sequence is stripped — CSI cursor moves / erase / device
    /// status (`ESC[…n`), OSC (window title, hyperlinks, `OSC 52` clipboard),
    /// DCS / PM / APC, etc. The banner is server-controlled and shown pre-auth,
    /// so it must not be able to move the cursor, query the terminal, touch the
    /// clipboard, or rewrite the screen. TAB is kept; other C0 controls and DEL
    /// are dropped.
    private static func sanitizeBannerLine(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1b {  // ESC — consume the whole sequence, re-emit only safe SGR
                let scan = scanEscapeSequence(scalars, from: i)
                if let keep = scan.keep { out.append(contentsOf: keep) }
                i = scan.next
            } else if v == 0x09 {  // TAB
                out.append(scalars[i]); i += 1
            } else if v < 0x20 || (v >= 0x7f && v <= 0x9f) {
                // Strip other C0 controls, DEL, and the C1 range (U+0080–U+009F):
                // C1 contains 8-bit CSI/OSC/DCS/ST (U+009B/9D/90/9C) which some
                // terminals act on, which would bypass the ESC-sequence filter.
                i += 1
            } else {
                out.append(scalars[i]); i += 1
            }
        }
        return String(out)
    }

    /// Scans the escape sequence at `start` (`scalars[start]` is ESC). Returns
    /// the index just past the sequence and — only for a safe SGR sequence
    /// (`ESC[`, standard numeric/`;`/`:` params, final `m`) — the scalars to
    /// re-emit. Everything else is consumed and dropped.
    private static func scanEscapeSequence(
        _ s: [Unicode.Scalar], from start: Int
    ) -> (next: Int, keep: ArraySlice<Unicode.Scalar>?) {
        let n = s.count
        guard start + 1 < n else { return (n, nil) }  // lone trailing ESC
        switch s[start + 1].value {
        case 0x5b:  // '[' → CSI
            var j = start + 2
            var privateMarker = false
            var hasIntermediate = false
            while j < n, s[j].value >= 0x30, s[j].value <= 0x3f {  // params
                if s[j].value >= 0x3c { privateMarker = true }     // < = > ?
                j += 1
            }
            while j < n, s[j].value >= 0x20, s[j].value <= 0x2f {  // intermediates
                hasIntermediate = true
                j += 1
            }
            if j < n, s[j].value >= 0x40, s[j].value <= 0x7e {  // final byte
                let isSafeSGR = s[j].value == 0x6d && !privateMarker && !hasIntermediate  // 'm'
                let next = j + 1
                return (next, isSafeSGR ? s[start..<next] : nil)
            }
            return (j, nil)  // incomplete CSI
        case 0x5d, 0x50, 0x58, 0x5e, 0x5f:  // OSC ']', DCS 'P', SOS 'X', PM '^', APC '_'
            // String sequence: consume until ST (ESC \) or BEL.
            var j = start + 2
            while j < n {
                if s[j].value == 0x07 { return (j + 1, nil) }  // BEL
                if s[j].value == 0x1b, j + 1 < n, s[j + 1].value == 0x5c {
                    return (j + 2, nil)  // ESC \  (ST)
                }
                j += 1
            }
            return (n, nil)  // unterminated
        default:
            // Other escape: ESC + intermediates(0x20–0x2F)* + final(0x30–0x7E).
            var j = start + 1
            while j < n, s[j].value >= 0x20, s[j].value <= 0x2f { j += 1 }
            if j < n, s[j].value >= 0x30, s[j].value <= 0x7e { return (j + 1, nil) }
            return (min(j + 1, n), nil)
        }
    }

    /// Renders the OpenSSH-style "not using a post-quantum key exchange"
    /// warning. Output is already CRLF-terminated; emit verbatim.
    static func renderNonPQKexWarning(columns: Int, kexAlgorithm: String?) -> String {
        let cols = max(columns, 1)
        if cols >= 36 {
            return renderNonPQKexBar(columns: cols, kex: kexAlgorithm)
        } else {
            return renderNonPQKexNarrow(columns: cols, kex: kexAlgorithm)
        }
    }

    // MARK: - Bar layout (columns >= 36)

    private static func renderNonPQKexBar(columns: Int, kex: String?) -> String {
        let fgAccent = fg(warningAccent.r, warningAccent.g, warningAccent.b)
        let fgDim = fg(bannerDim.r, bannerDim.g, bannerDim.b)
        let reset = ansiReset

        let barPrefix = "\(fgAccent)▎\(reset) "  // 2 visible columns
        let barOnly = "\(fgAccent)▎\(reset)"
        let contentWidth = max(columns - 2, 1)

        let headlineText = fitting([warningHeadline, warningHeadlineShort], width: contentWidth)
        let sub1Text = fitting([subline1Text, subline1Short], width: contentWidth)
        let sub2Text = fitting([subline2Text, subline2Short], width: contentWidth)
        let headline = "\(fgAccent)\(bold(headlineText))\(reset)"
        let subline1 = "\(fgDim)\(sub1Text)\(reset)"
        let subline2 = "\(fgDim)\(sub2Text)\(reset)"

        var lines = [
            "\(barPrefix)\(headline)",
            barOnly,
            "\(barPrefix)\(subline1)",
            "\(barPrefix)\(subline2)",
        ]

        // Optional: show the negotiated algorithm so the user can see what
        // they got. Drops first when we're tight on vertical space — but
        // since we don't know the scrollback, we keep it whenever it fits
        // on a single line.
        if let kex, !kex.isEmpty {
            let kexLine = "\(kexLabel) \(kex)"
            if kexLine.count <= contentWidth {
                lines.append(barOnly)
                lines.append("\(barPrefix)\(fgDim)\(kexLine)\(reset)")
            }
        }

        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - Narrow layout (columns < 36)

    private static func renderNonPQKexNarrow(columns: Int, kex: String?) -> String {
        let fgAccent = fg(warningAccent.r, warningAccent.g, warningAccent.b)
        let fgDim = fg(bannerDim.r, bannerDim.g, bannerDim.b)
        let reset = ansiReset

        let contentWidth = max(columns - 1, 1)  // 1 char of left margin

        var lines: [String] = []
        lines.append(" \(fgAccent)\(bold(truncate(warningHeadlineShort, width: contentWidth)))\(reset)")
        lines.append(" \(fgDim)\(truncate(subline1Short, width: contentWidth))\(reset)")
        lines.append(" \(fgDim)\(truncate(subline2Short, width: contentWidth))\(reset)")

        if let kex, !kex.isEmpty, (1 + kex.count) <= contentWidth {
            lines.append(" \(fgDim)\(kex)\(reset)")
        }

        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - Content (localized)

    private static var warningHeadline: String {
        String(localized: "WARNING: non post-quantum key exchange")
    }

    private static var warningHeadlineShort: String {
        String(localized: "WARNING: non-PQ key exchange")
    }

    private static var subline1Text: String {
        String(localized: "Vulnerable to \"store now, decrypt later\" attacks.")
    }

    private static var subline1Short: String {
        String(localized: "Vulnerable to harvest-now attacks.")
    }

    private static var subline2Text: String {
        String(localized: "See https://openssh.com/pq.html")
    }

    private static var subline2Short: String {
        String(localized: "openssh.com/pq.html")
    }

    private static var kexLabel: String {
        String(localized: "Negotiated:")
    }

    // MARK: - Styling

    /// Warning accent — Catppuccin Mocha yellow (#f9e2af). Chosen to be
    /// distinct from every theme's bannerAccent (mostly blues/purples/pinks)
    /// and to read as "caution" on every supported dark background.
    private static let warningAccent: (r: Int, g: Int, b: Int) = (249, 226, 175)

    /// Dim accent used for sublines. Matches `PromptStyle.bannerDim`, but
    /// inlined here because `PromptStyle` is excluded from Mac Catalyst
    /// builds and this banner must render on every platform that can run
    /// SSH sessions.
    private static let bannerDim: (r: Int, g: Int, b: Int) = (127, 132, 156)

    private static func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\u{1b}[38;2;\(r);\(g);\(b)m"
    }

    private static let ansiReset = "\u{1b}[0m"

    // MARK: - Small helpers

    private static func bold(_ text: String) -> String {
        "\u{1b}[1m\(text)\u{1b}[22m"
    }

    private static func truncate(_ text: String, width: Int) -> String {
        if text.count <= width { return text }
        if width <= 1 { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }

    /// Returns the first candidate that fits `width`; falls back to truncating
    /// the last candidate when nothing fits. Pass candidates longest-to-shortest.
    private static func fitting(_ candidates: [String], width: Int) -> String {
        for candidate in candidates where candidate.count <= width {
            return candidate
        }
        return truncate(candidates.last ?? "", width: width)
    }
}

/// Thread-safe FIFO buffer for SSH auth banners. Written from the NIO event
/// loop (off the main actor) as `SSH_MSG_USERAUTH_BANNER` messages arrive
/// during authentication, then drained on the main actor at the `.running`
/// emit site. `nonisolated` so the event-loop writer can reach it under the
/// project's default-MainActor isolation.
nonisolated final class AuthBannerBuffer: @unchecked Sendable {
    /// Per-banner UTF-8 byte cap; longer banners are truncated. Comfortably
    /// larger than any human-readable login notice.
    private static let maxBannerBytes = 8 * 1024
    /// Total cap across all banners buffered in one auth phase. Once reached,
    /// further banners are dropped — bounds a hostile/looping server that sends
    /// `SSH_MSG_USERAUTH_BANNER` repeatedly before authentication completes.
    private static let maxTotalBytes = 64 * 1024
    /// Message-count cap per auth phase. The byte cap alone admits tens of
    /// thousands of tiny banners, each of which becomes a card item and view.
    private static let maxBanners = 32

    /// Live buffer activity, for observers that mirror banners into native UI
    /// (the auth-banner card) as they arrive rather than waiting for the
    /// `.running` drain.
    enum Event: Sendable {
        /// A banner was accepted into the buffer (post-truncation text).
        /// `source` names the host that sent it when it is NOT the target
        /// host (i.e. a jump hop) — a jump host's re-auth URL must not be
        /// attributed to the target for a security-sensitive action.
        case appended(String, source: String?)
        /// The buffer was drained or cleared — the auth phase ended one way
        /// or another, so any mirrored display should be torn down.
        case reset
    }

    private let lock = NSLock()
    private var banners: [String] = []
    private var totalBytes = 0
    private var observer: (@Sendable (Event) -> Void)?

    /// Sets the live observer. Invoked outside the lock on the caller's thread
    /// (the NIO event loop for `append`; any thread for `drain`/`clear`).
    /// Set before the connection starts.
    func setObserver(_ handler: (@Sendable (Event) -> Void)?) {
        lock.lock()
        observer = handler
        lock.unlock()
    }

    func append(_ banner: String, source: String? = nil) {
        var text = banner
        if text.utf8.count > Self.maxBannerBytes {
            text = String(decoding: text.utf8.prefix(Self.maxBannerBytes), as: UTF8.self)
        }
        let cost = text.utf8.count
        lock.lock()
        let accepted = banners.count < Self.maxBanners
            && totalBytes + cost <= Self.maxTotalBytes
        if accepted {
            banners.append(text)
            totalBytes += cost
        }
        let handler = observer
        lock.unlock()
        if accepted { handler?(.appended(text, source: source)) }
    }

    /// Returns and clears all buffered banners.
    func drain() -> [String] {
        lock.lock()
        let result = banners
        banners.removeAll()
        totalBytes = 0
        let handler = observer
        lock.unlock()
        handler?(.reset)
        return result
    }

    /// Discards any buffered banners without returning them (failure/teardown).
    func clear() {
        lock.lock()
        banners.removeAll()
        totalBytes = 0
        let handler = observer
        lock.unlock()
        handler?(.reset)
    }
}
