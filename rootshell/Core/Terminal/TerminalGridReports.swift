// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Replies to our CSI 18 t probes come from the terminal parser, unlike
/// ghostty_surface_size, which reports a resize before the IO thread applies it.
nonisolated struct TerminalGridReports {
    struct Grid: Equatable, Sendable {
        let cols: Int
        let rows: Int
    }

    var pending = 0
    private var carry = Data()

    mutating func consume(_ data: Data) -> (forward: Data, grids: [Grid]) {
        guard pending > 0 || !carry.isEmpty else { return (data, []) }
        let bytes = Array(carry + data)
        carry.removeAll(keepingCapacity: true)
        var forward = Data()
        var grids: [Grid] = []
        var index = 0
        while index < bytes.count {
            let start = index
            guard pending > 0, bytes[index] == 0x1b else {
                forward.append(bytes[index]); index += 1
                continue
            }
            index += 1
            if index == bytes.count { carry.append(contentsOf: bytes[start...]); break }
            guard bytes[index] == 0x5b else { forward.append(0x1b); continue }
            index += 1
            while index < bytes.count, index - start < 64,
                  (0x30...0x3f).contains(bytes[index]) { index += 1 }
            if index == bytes.count, index - start < 64 {
                carry.append(contentsOf: bytes[start...]); break
            }
            if index < bytes.count, bytes[index] == 0x74 {
                let params = String(decoding: bytes[(start + 2)..<index], as: UTF8.self)
                    .split(separator: ";", omittingEmptySubsequences: false)
                if params.count == 3, params[0] == "8",
                   let rows = Int(params[1]), let cols = Int(params[2]), rows > 0, cols > 0 {
                    grids.append(Grid(cols: cols, rows: rows))
                    pending -= 1
                    index += 1
                    continue
                }
            }
            forward.append(contentsOf: bytes[start..<index])
        }
        return (forward, grids)
    }
}

/// Byte-stream boundaries for VT output split across reads.
nonisolated enum TerminalSequenceBoundary {
    /// Offset where a sequence left unfinished at the end starts: ESC
    /// without its final byte, an unterminated string, or truncated UTF-8.
    static func incompleteTailStart(_ bytes: UnsafeRawBufferPointer) -> Int? {
        let count = bytes.count
        var i = 0
        while i < count {
            guard bytes[i] == 0x1b else { i += 1; continue }
            // Executable C0 controls and DEL pass through escape state.
            var k = i + 1
            while k < count, isTransparentControl(bytes[k]) { k += 1 }
            guard k < count else { return i }
            // CAN and SUB abort any sequence; a second ESC restarts one.
            // These mirror the parser's "anywhere" transitions.
            switch bytes[k] {
            case 0x1b:
                i = k
            case 0x18, 0x1a:
                i = k + 1
            case 0x5b, 0x20...0x2f: // CSI, or ESC with intermediates, up to a final byte
                let csi = bytes[k] == 0x5b
                var j = k + 1
                var ended = false
                while j < count {
                    let byte = bytes[j]
                    if byte == 0x1b { i = j; ended = true; break }
                    if byte == 0x18 || byte == 0x1a { i = j + 1; ended = true; break }
                    let final = csi ? (0x40...0x7e).contains(byte) : (0x30...0x7e).contains(byte)
                    if final { i = j + 1; ended = true; break }
                    j += 1
                }
                guard ended else { return i }
            case 0x5d, 0x50, 0x5f, 0x5e, 0x58: // OSC DCS APC PM SOS: until ST (OSC also BEL)
                let bel = bytes[k] == 0x5d
                var j = k + 1
                while true {
                    guard j < count else { return i }
                    let byte = bytes[j]
                    if bel, byte == 0x07 { i = j + 1; break }
                    if byte == 0x18 || byte == 0x1a { i = j + 1; break }
                    if byte == 0x1b {
                        guard j + 1 < count else { return i }
                        // ST ends the string; any other ESC starts a new sequence.
                        i = bytes[j + 1] == 0x5c ? j + 2 : j
                        break
                    }
                    j += 1
                }
            default:
                i = k + 1
            }
        }
        return incompleteUTF8Start(bytes)
    }

    private static func isTransparentControl(_ byte: UInt8) -> Bool {
        byte < 0x18 || byte == 0x19 || (0x1c...0x1f).contains(byte) || byte == 0x7f
    }

    static func incompleteUTF8Start(_ bytes: UnsafeRawBufferPointer) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        for back in 1...min(3, count) {
            let index = count - back
            let byte = bytes[index]
            if byte & 0xc0 == 0x80 { continue }
            let needed: Int
            switch byte {
            case 0xc0...0xdf: needed = 2
            case 0xe0...0xef: needed = 3
            case 0xf0...0xf7: needed = 4
            default: return nil
            }
            return back < needed ? index : nil
        }
        return nil
    }
}

/// A preview may paint only after the parser acknowledges the latest resize.
/// Replies to probes sent before that resize cannot satisfy the new request,
/// including when a quick open/close returns to an earlier grid size.
nonisolated struct TerminalPreviewGrid {
    typealias Grid = TerminalGridReports.Grid
    private var wanted: Grid?
    private var confirmed: Grid?
    private var reports = TerminalGridReports()
    private var staleReplies = 0
    private var nextProbeAt: TimeInterval = 0

    var isReady: Bool { wanted != nil && confirmed == wanted }

    mutating func resize(cols: Int, rows: Int) {
        let grid = Grid(cols: cols, rows: rows)
        guard wanted != grid else { return }
        wanted = grid
        confirmed = nil
        staleReplies = reports.pending
        nextProbeAt = 0
    }

    mutating func consume(_ data: Data) {
        for grid in reports.consume(data).grids {
            if staleReplies > 0 { staleReplies -= 1 }
            else { confirmed = grid }
        }
    }

    mutating func probe(at now: TimeInterval) -> String? {
        guard wanted != nil, !isReady, now >= nextProbeAt else { return nil }
        reports.pending += 1
        nextProbeAt = now + 0.1
        return "\u{18}\u{1b}[18t"
    }
}
