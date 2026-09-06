//
//  MultiplexerExposeAdapter.swift
//  rootshell
//

import Foundation

nonisolated struct MuxTickRequest: Sendable {
    /// Panes whose content the script should capture, in priority order.
    var fetch: [String] = []
    /// Last revision the client holds per pane; adapters with a server-side
    /// counter skip captures that would return the same content.
    var knownRevisions: [String: String] = [:]
}

/// Checks whether screen state is compatible with a multiplexer attachment.
nonisolated enum MuxScreenGate {
    /// Passthrough multiplexers are admitted on either screen.
    static func admits(ownsAlternateScreen: Bool, alternateScreenActive: Bool) -> Bool {
        !ownsAlternateScreen || alternateScreenActive
    }
}

/// Checks whether a detachable multiplexer has a shell underneath it.
nonisolated enum MuxDetachGate {
    static func hasFallbackShell(
        hasRemoteCommand: Bool,
        hasInitialCommandLaunch: Bool,
        tmuxAutoEnable: Bool,
        herdrAutoEnable: Bool,
        zmxAutoEnable: Bool
    ) -> Bool {
        !(hasRemoteCommand || hasInitialCommandLaunch || tmuxAutoEnable || herdrAutoEnable || zmxAutoEnable)
    }
}

/// Classifies a detach-and-reattach attempt from its client-count census.
nonisolated enum MuxZmxDetachTransfer {
    enum Result: Equatable {
        case confirmed
        case unchanged
        case detachedOnly
        case ambiguous
    }

    static func classify(
        sourceBefore: Int,
        targetBefore: Int,
        sourceAfter: Int,
        targetAfter: Int
    ) -> Result {
        if sourceAfter == sourceBefore - 1,
           targetAfter == targetBefore + 1 {
            return .confirmed
        }
        if sourceAfter == sourceBefore,
           targetAfter == targetBefore {
            return .unchanged
        }
        // A single-client source proves this pane reached its fallback shell.
        if sourceBefore == 1,
           sourceAfter == 0,
           targetAfter == targetBefore {
            return .detachedOnly
        }
        return .ambiguous
    }
}

nonisolated protocol MultiplexerExposeAdapter: Sendable {
    var type: MultiplexerType { get }

    /// Prints the only running session's name, or nothing. Used when the
    /// binding has no session name.
    func resolveSessionScript(nonce: String) -> String

    func tickScript(session: String?, request: MuxTickRequest, nonce: String) -> String

    /// nil when the multiplexer is unavailable or has no usable session.
    func parseTick(output: String, session: String?, nonce: String) -> MuxTickResult?

    /// Whether switching from `session` to `tabID` is safe.
    func canFocus(session: String?, tabID: String) -> Bool

    func focusScript(session: String?, tabID: String) -> String

    /// Whether the focus command's output confirms the switch.
    func parseFocusResult(output: String, session: String?, tabID: String) -> Bool

    /// Floor for the feed's tick pacing.
    var minInterval: TimeInterval { get }
}

nonisolated extension MultiplexerExposeAdapter {
    var minInterval: TimeInterval { 0 }
    func parseFocusResult(output: String, session: String?, tabID: String) -> Bool { true }
    func canFocus(session: String?, tabID: String) -> Bool { true }
}

/// Marker framing and shell quoting shared by the adapters.
nonisolated enum MuxScript {
    static let unsupportedMarker = "::MX_UNSUPPORTED::"
    static let sameMarker = "::MX_SAME::"

    static func begin(_ nonce: String) -> String { "::MX_B_\(nonce)::" }
    static func end(_ nonce: String) -> String { "::MX_E_\(nonce)::" }
    static func topology(_ nonce: String) -> String { "::MX_T_\(nonce)::" }
    static func panePrefix(_ nonce: String) -> String { "::MX_P_\(nonce):" }

    /// `sh -lc` wrapper with the app's PATH prefix; `body` uses double quotes only.
    static func wrap(_ body: String, nonce: String) -> String {
        let script = "echo \"\(begin(nonce))\"; \(body); echo \"\(end(nonce))\"; exit 0"
        return LoginShellCommand.runInPOSIXShell(SSHConfig.remoteExecPathPrefix + script, login: true)
    }

    /// A double-quoted shell word.
    static func dq(_ value: String) -> String {
        LoginShellCommand.doubleQuoted(value)
    }

    /// `printf` line announcing a pane section: `::MX_P_n:<id>:<extra>::`.
    static func paneMarker(nonce: String, id: String, extra: String = "") -> String {
        "echo \(dq("\(panePrefix(nonce))\(id):\(extra)::"))"
    }

    struct Sections {
        var topology = ""
        /// In script order: pane id, marker extra, body (trailing newline removed).
        var panes: [(id: String, extra: String, body: String)] = []
        var truncated = false
        var unsupported = false
        var found = false
    }

    static func sections(of output: String, nonce: String) -> Sections {
        var result = Sections()
        guard let start = output.range(of: begin(nonce)) else { return result }
        result.found = true
        var body = output[start.upperBound...]
        if let stop = body.range(of: end(nonce)) {
            body = body[..<stop.lowerBound]
        } else {
            result.truncated = true
        }
        let topologyMarker = topology(nonce)
        // Only the prelude may declare unsupported. Captured pane content is
        // arbitrary text — a pane showing this source, a log, or a diff would
        // otherwise fail every tick by quoting our own markers.
        let preludeEnd = body.range(of: topologyMarker)?.lowerBound ?? body.endIndex
        if body[..<preludeEnd].contains(unsupportedMarker) {
            result.unsupported = true
            return result
        }
        let prefix = panePrefix(nonce)
        var current: (id: String, extra: String)? = nil
        var buffer = ""
        var sawTopology = false

        func flush() {
            // Each section's `echo` terminator adds one newline we don't want.
            var text = buffer
            if text.hasSuffix("\n") { text.removeLast() }
            if let current {
                result.panes.append((current.id, current.extra, text))
            } else if sawTopology {
                result.topology = text
            }
            buffer = ""
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(topologyMarker) {
                flush()
                current = nil
                sawTopology = true
                continue
            }
            if line.hasPrefix(prefix), line.hasSuffix("::") {
                flush()
                let inner = line.dropFirst(prefix.count).dropLast(2)
                // Pane ids may contain colons (herdr `w1:p1`); `extra` never does.
                if let colon = inner.lastIndex(of: ":") {
                    current = (String(inner[..<colon]), String(inner[inner.index(after: colon)...]))
                } else {
                    current = (String(inner), "")
                }
                continue
            }
            buffer.append(contentsOf: line)
            buffer.append("\n")
        }
        // The body ends with the newline before the end marker (or nothing on truncation).
        if buffer.hasSuffix("\n") { buffer.removeLast() }
        flush()
        // A truncated last pane is unusable; keep the topology and the rest.
        if result.truncated, !result.panes.isEmpty { result.panes.removeLast() }
        return result
    }

    static func json(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Lenient JSONSerialization readers for the adapters.
nonisolated extension Dictionary where Key == String, Value == Any {
    func mxInt(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func mxBool(_ key: String) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? (self[key] as? Bool) ?? false
    }
    func mxString(_ key: String) -> String? {
        self[key] as? String
    }
    func mxDict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
    func mxArray(_ key: String) -> [[String: Any]] {
        (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}
