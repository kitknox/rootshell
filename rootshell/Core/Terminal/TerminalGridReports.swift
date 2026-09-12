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
