//
//  HerdrPaneSession.swift
//  rootshell
//
//  The TerminalSession a projected herdr pane surface is bound to. It owns no
//  transport: bytes arrive from the controller's channel through an
//  OutputSink and input goes back through the controller. Being a real
//  TerminalSession keeps the response pipeline, size updates, bell and title
//  plumbing exactly as they are for SSH panes.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Off-main fan-out of raw terminal records to pane sinks, keyed by attach id.
/// The channel actor calls into this directly so output never waits for the
/// main actor.
nonisolated final class HerdrOutputRouter: @unchecked Sendable {
    /// Bytes queued across all attaches while waiting for a sink or a layout.
    private static let maxQueuedBytes = 8 * 1024 * 1024
    /// Longest unfinished sequence held back; a longer one goes out as is.
    private static let maxCarryBytes = 256 * 1024

    private enum QueueItem {
        case data(Data)
        case snapshot(Data, cols: Int, rows: Int)
        /// Emitted verbatim ahead of the held carry: a parser probe.
        case control(Data)
        /// A layout boundary: everything after it waits until released.
        case barrier(UInt64)

        var byteCount: Int {
            switch self {
            case .data(let data), .snapshot(let data, _, _), .control(let data): return data.count
            case .barrier: return 0
            }
        }
    }

    private let lock = UnfairLock()
    private var sinks: [String: OutputSink] = [:]
    private var grids: [String: (cols: Int, rows: Int)] = [:]
    /// Per attach, the escape or UTF-8 sequence the last emitted chunk ended
    /// inside. herdr forwards raw PTY reads, so a sequence can straddle two
    /// records; Ghostty only ever receives whole ones.
    private var carries: [String: Data] = [:]
    /// Per attach, records not yet delivered, in arrival order. Non-empty
    /// while the sink is missing (the snapshot follows the attach response
    /// on the stream and can beat the main-actor hop that registers it),
    /// while a layout barrier sits ahead, or while a flush is running.
    private var queues: [String: [QueueItem]] = [:]
    private var queuedBytes = 0
    /// Barriers not yet released. Each `tab.layout` gets its own, placed in
    /// the queue at arrival, so overlapping layouts release in order and a
    /// later one never frees output drawn for it.
    private var barriers: Set<UInt64> = []
    private var nextBarrier: UInt64 = 0
    /// Attaches a thread is currently flushing; new records queue behind it.
    private var draining: Set<String> = []
    /// Attaches that dropped output: everything is discarded until the
    /// re-snapshot the controller asked for arrives.
    private var overflowed: Set<String> = []
    /// Attach id by herdr pane id, so a `tab.layout` record can hold the
    /// output of the panes it is about to resize.
    private var attachByPane: [String: String] = [:]
    /// Called off-main when an attach's queue overflowed and its screen
    /// needs a fresh snapshot.
    var onOverflow: (@Sendable (String) -> Void)?

    func register(attachId: String, sink: OutputSink) {
        lock.withLock { sinks[attachId] = sink }
        flush(attachId)
    }

    func unregister(attachId: String) {
        lock.withLock {
            _ = sinks.removeValue(forKey: attachId)
            grids.removeValue(forKey: attachId)
            carries.removeValue(forKey: attachId)
            if let dropped = queues.removeValue(forKey: attachId) {
                queuedBytes -= dropped.reduce(0) { $0 + $1.byteCount }
            }
            draining.remove(attachId)
            overflowed.remove(attachId)
            attachByPane = attachByPane.filter { $0.value != attachId }
        }
    }

    /// A layout superseded before its panes resized: the redraw queued
    /// behind `id` was drawn for a grid the panes never reach, and the
    /// caller re-snapshots every attach touched, so drop everything those
    /// attaches hold and let only that snapshot resume them. Splicing the
    /// segment out instead could leave the next chunk starting mid-sequence.
    func discardSegment(barrier id: UInt64) -> [String] {
        lock.withLock {
            barriers.remove(id)
            var touched: [String] = []
            for (attachId, queue) in queues {
                guard queue.contains(where: { if case .barrier(let b) = $0 { return b == id } else { return false } })
                else { continue }
                overflowed.insert(attachId)
                dropQueue(attachId)
                touched.append(attachId)
            }
            return touched
        }
    }

    func removeAll() {
        lock.withLock {
            sinks.removeAll()
            grids.removeAll()
            carries.removeAll()
            queues.removeAll()
            queuedBytes = 0
            barriers.removeAll()
            draining.removeAll()
            overflowed.removeAll()
            attachByPane.removeAll()
        }
    }

    func setPane(_ paneId: String, attachId: String) {
        lock.withLock { attachByPane[paneId] = attachId }
    }

    func updateGrid(attachId: String, cols: Int, rows: Int) {
        lock.withLock { grids[attachId] = (cols, rows) }
        flush(attachId)
    }

    func isWaitingForGrid(attachId: String) -> Bool {
        lock.withLock {
            for item in queues[attachId] ?? [] {
                if case .snapshot(_, let cols, let rows) = item {
                    return grids[attachId]?.cols != cols || grids[attachId]?.rows != rows
                }
            }
            return false
        }
    }

    /// Output drawn for a grid the surface could not take cannot be replayed
    /// later as incremental bytes. Resume only from a complete snapshot.
    func invalidate(attachId: String) {
        lock.withLock {
            overflowed.insert(attachId)
            dropQueue(attachId)
        }
    }

    /// Places a barrier behind everything these panes have received so far;
    /// output after it waits for `release(barrier:)`, when their surfaces
    /// have the layout's size. Returns the barrier id.
    func holdOutput(forPanes paneIds: [String]) -> UInt64 {
        lock.withLock {
            nextBarrier += 1
            let id = nextBarrier
            let ids = paneIds.compactMap { attachByPane[$0] }
            guard !ids.isEmpty else { return id }
            barriers.insert(id)
            for attachId in ids {
                queues[attachId, default: []].append(.barrier(id))
            }
            return id
        }
    }

    func release(barrier id: UInt64) {
        let affected: [String] = lock.withLock {
            guard barriers.remove(id) != nil else { return [] }
            return queues.compactMap { attachId, queue in
                queue.contains { if case .barrier(let b) = $0 { return b == id } else { return false } } ? attachId : nil
            }
        }
        for attachId in affected {
            flush(attachId)
        }
    }

    /// Drops an attach's queued bytes but keeps its layout barriers, so a
    /// recovery snapshot still waits for a resize that is in flight.
    private func dropQueue(_ attachId: String) {
        // A held partial sequence belongs to the dropped stream.
        carries.removeValue(forKey: attachId)
        guard let queue = queues[attachId] else { return }
        queuedBytes -= queue.reduce(0) { $0 + $1.byteCount }
        let barriersOnly = queue.filter { if case .barrier = $0 { return true } else { return false } }
        queues[attachId] = barriersOnly.isEmpty ? nil : barriersOnly
    }

    private func deliver(attachId: String, _ item: QueueItem, isSnapshot: Bool) {
        var overflowNow = false
        lock.withLock {
            if overflowed.contains(attachId) {
                // Only the snapshot we asked for can make the screen whole.
                guard isSnapshot else { return }
                overflowed.remove(attachId)
                dropQueue(attachId)
            }
            // A snapshot is never dropped: it replaces whatever this attach
            // had queued, and it is the only thing that can end an overflow.
            // It may exceed the shared budget briefly; the server caps it.
            if isSnapshot {
                dropQueue(attachId)
            } else if queuedBytes + item.byteCount > Self.maxQueuedBytes {
                // Over budget: this attach's backlog is now incomplete, so
                // discard it all and recover from a fresh snapshot.
                dropQueue(attachId)
                overflowed.insert(attachId)
                overflowNow = true
                return
            }
            queues[attachId, default: []].append(item)
            queuedBytes += item.byteCount
        }
        if overflowNow {
            onOverflow?(attachId)
            return
        }
        // All deliveries share the same drain, including live output. A
        // main-actor layout release cannot overtake a channel snapshot emit.
        flush(attachId)
    }

    /// Drains one attach's queue in order up to the first live barrier.
    /// Records arriving meanwhile queue behind it (`draining`), so nothing
    /// overtakes the backlog.
    private func flush(_ attachId: String) {
        let started: Bool = lock.withLock {
            guard sinks[attachId] != nil, !draining.contains(attachId),
                  !(queues[attachId]?.isEmpty ?? true) else { return false }
            draining.insert(attachId)
            return true
        }
        guard started else { return }
        while true {
            let next: (OutputSink, Data?)? = lock.withLock {
                guard let sink = sinks[attachId], var queue = queues[attachId] else {
                    draining.remove(attachId)
                    return nil
                }
                // Skip released barriers; stop at a live one.
                while case .barrier(let id)? = queue.first {
                    if barriers.contains(id) { break }
                    queue.removeFirst()
                }
                let data: Data?
                switch queue.first {
                case .data(let bytes):
                    data = splitCarry(attachId: attachId, appending: bytes)
                case .control(let bytes):
                    data = bytes
                case .snapshot(let bytes, let cols, let rows)
                    where grids[attachId]?.cols == cols && grids[attachId]?.rows == rows:
                    data = bytes
                default:
                    queues[attachId] = queue
                    draining.remove(attachId)
                    return nil
                }
                let item = queue.removeFirst()
                queues[attachId] = queue
                queuedBytes -= item.byteCount
                return (sink, data)
            }
            guard let next else { return }
            if let data = next.1, !data.isEmpty {
                next.0.emit(data)
            }
        }
    }

    /// Joins the held tail with `bytes` and holds the new unfinished tail
    /// back, unless it is implausibly long. Caller holds `lock`. The carry
    /// was dequeued ahead of any barrier that arrives later, so a sequence
    /// straddling a layout goes out whole once that barrier releases.
    private func splitCarry(attachId: String, appending bytes: Data) -> Data? {
        var joined = carries.removeValue(forKey: attachId) ?? Data()
        if joined.isEmpty { joined = bytes } else { joined.append(bytes) }
        let cut = joined.withUnsafeBytes { TerminalSequenceBoundary.incompleteTailStart($0) }
        guard let cut, joined.count - cut <= Self.maxCarryBytes else { return joined }
        let split = joined.startIndex + cut
        carries[attachId] = joined.subdata(in: split..<joined.endIndex)
        return cut > 0 ? joined.subdata(in: joined.startIndex..<split) : nil
    }

    /// Emits `bytes` ahead of everything this attach has queued: live
    /// barriers, a waiting snapshot, and the held partial sequence. False
    /// when the attach has no sink, so the caller can write directly.
    @discardableResult
    func inject(attachId: String, _ bytes: Data) -> Bool {
        let queued: Bool = lock.withLock {
            guard sinks[attachId] != nil else { return false }
            queues[attachId, default: []].insert(.control(bytes), at: 0)
            queuedBytes += bytes.count
            return true
        }
        if queued { flush(attachId) }
        return queued
    }

    func write(attachId: String, _ data: Data) {
        deliver(attachId: attachId, .data(data), isSnapshot: false)
    }

    func applySnapshot(_ record: HerdrControl.SnapshotRecord) {
        deliver(attachId: record.attach_id, .snapshot(
            Self.replayBytes(for: record.snapshot),
            cols: record.snapshot.state.cols, rows: record.snapshot.state.rows
        ), isSnapshot: true)
    }

    /// Composes the byte sequence that rebuilds a surface from a snapshot:
    /// clear everything, replay the primary history, switch to and paint the
    /// alternate screen when it is active, restore modes, then the cursor.
    /// Wrapped in synchronized output so the rebuild never flickers.
    static func replayBytes(for snapshot: HerdrControl.TerminalSnapshot) -> Data {
        var out = Data()
        // CAN first: only an oversized string the carry gave up on can leave
        // the parser mid-sequence, and the replay must start from ground.
        out.append(0x18)
        // Normalize everything the replay depends on: margins and origin
        // mode off (so lines rebuild the whole screen instead of scrolling
        // a region), autowrap on (the primary text is unwrapped and must
        // reflow), insert mode off, ASCII charset.
        out.append(contentsOf: "\u{1b}[?2026h\u{1b}[?1049l\u{1b}[0m\u{1b}[?25l".utf8)
        out.append(contentsOf: "\u{1b}[r\u{1b}[?69l\u{1b}[?6l\u{1b}[?7h\u{1b}[4l\u{1b}(B\u{0f}".utf8)
        out.append(contentsOf: "\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8)
        if let primary = snapshot.primary {
            out.append(contentsOf: primary.utf8)
        }
        if snapshot.active_screen == "alternate" {
            out.append(contentsOf: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H".utf8)
            if let alternate = snapshot.alternate {
                out.append(contentsOf: alternate.utf8)
            }
        }
        out.append(contentsOf: snapshot.state_ansi.utf8)
        let cursor = cursorPosition(for: snapshot)
        out.append(contentsOf: "\u{1b}[\(cursor.row);\(cursor.column)H".utf8)
        // A cursor left on the last column with wrap pending: CUP clears
        // the flag, so reprint the cell there (in its own style) to set it
        // again, then put the pen back.
        if snapshot.cursor.pending_wrap == true, let cell = snapshot.cursor.pending_wrap_cell {
            out.append(contentsOf: "\u{1b}[0m".utf8)
            out.append(contentsOf: cell.utf8)
            out.append(contentsOf: "\u{1b}[0m".utf8)
            if let pen = snapshot.pen_ansi {
                out.append(contentsOf: pen.utf8)
            }
        }
        out.append(contentsOf: "\u{1b}[?2026l".utf8)
        return out
    }

    /// The CUP parameters that land the cursor on herdr's absolute cell once
    /// `state_ansi` has restored margins and origin mode: with DECOM on, CUP
    /// is relative to the scrolling region, and setting DECOM homes the
    /// cursor, so it has to be positioned after the modes, in their terms.
    static func cursorPosition(for snapshot: HerdrControl.TerminalSnapshot) -> (row: Int, column: Int) {
        var row = snapshot.cursor.y + 1
        var column = snapshot.cursor.x + 1
        let state = snapshot.state_ansi
        guard state.contains("\u{1b}[?6h") else { return (row, column) }
        if let top = lastMargin(in: state, final: "r") {
            row = max(1, row - (top - 1))
        }
        if state.contains("\u{1b}[?69h"), let left = lastMargin(in: state, final: "s") {
            column = max(1, column - (left - 1))
        }
        return (row, column)
    }

    /// First parameter of the last `CSI top;bottom <final>` in `state`.
    private static func lastMargin(in state: String, final: Character) -> Int? {
        var result: Int?
        var search = state[...]
        while let esc = search.range(of: "\u{1b}[") {
            let after = search[esc.upperBound...]
            guard let end = after.firstIndex(where: { !$0.isNumber && $0 != ";" }) else { break }
            if after[end] == final {
                let params = after[after.startIndex..<end].split(separator: ";")
                if let first = params.first, let top = Int(first) {
                    result = top
                }
            }
            search = after[after.index(after: end)...]
        }
        return result
    }
}

@MainActor
final class HerdrPaneSession: TerminalSession {
    let pty = TerminalPTY()
    private(set) var isRunning = false

    let terminalId: String
    private(set) var paneId: String
    /// Live attach id once the controller's `terminal.attach` succeeded.
    var attachId: String?
    private(set) weak var controller: HerdrController?

    private(set) var parserGrid: TerminalGridReports.Grid?
    private var wantedParserGrid: TerminalGridReports.Grid?
    private var gridReports = TerminalGridReports()
    private var gridProbeTask: Task<Void, Never>?

    /// Delivered off-main by the router; mirrors the callback properties.
    let outputSink = OutputSink()

    var onOutput: (@Sendable (String) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    var connectionInfo: ConnectionInfo? { controller?.gatewayConnectionInfo }

    init(controller: HerdrController, terminalId: String, paneId: String) {
        self.controller = controller
        self.terminalId = terminalId
        self.paneId = paneId
    }

    func updatePaneId(_ paneId: String) {
        self.paneId = paneId
    }

    func start() async throws {
        isRunning = true
        controller?.paneSessionDidStart(self)
        onReady?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        gridProbeTask?.cancel()
        gridProbeTask = nil
        controller?.paneSessionDidStop(self)
    }

    func sendInput(_ data: Data) {
        controller?.sendInput(from: self, data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        controller?.paneGridDidChange(self, rows: Int(size.rows), cols: Int(size.cols))
    }

    /// Polling schedules another query; only an exact parser reply permits
    /// replay. A delay or timeout never counts as a resize acknowledgement.
    func confirmParserGrid(cols: Int, rows: Int) {
        let wanted = TerminalGridReports.Grid(cols: cols, rows: rows)
        wantedParserGrid = wanted
        guard parserGrid != wanted, gridProbeTask == nil, isRunning else { return }
        gridProbeTask = Task { [weak self] in
            defer { self?.gridProbeTask = nil }
            var lastProbe = ContinuousClock.now
            while let self, self.isRunning, !Task.isCancelled,
                  self.parserGrid != self.wantedParserGrid {
                if self.gridReports.pending == 0 || lastProbe.duration(to: .now) >= .seconds(1) {
                    self.gridReports.pending += 1
                    // Through the router, so the probe lands between whole
                    // sequences of live output. Before the attach exists,
                    // and in fallback mode, nothing else is flowing.
                    let probe = Data("\u{1b}[18t".utf8)
                    let injected = self.attachId.map {
                        self.controller?.router.inject(attachId: $0, probe) == true
                    } ?? false
                    if !injected {
                        self.outputSink.emit(probe)
                    }
                    lastProbe = .now
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { break }
            }
        }
    }

    /// Called only for the response pipe, so keyboard/paste input does not
    /// get mistaken for an internal probe reply.
    func consumeParserGridReports(_ data: Data) -> Data {
        let result = gridReports.consume(data)
        for grid in result.grids {
            parserGrid = grid
            controller?.paneParserGridDidChange(self, cols: grid.cols, rows: grid.rows)
        }
        return result.forward
    }

    /// The pane went away on the server: end the session so the tab's
    /// ordinary close path runs.
    func endedRemotely() {
        guard isRunning else { return }
        isRunning = false
        gridProbeTask?.cancel()
        gridProbeTask = nil
        onSessionEnd?()
    }
}
