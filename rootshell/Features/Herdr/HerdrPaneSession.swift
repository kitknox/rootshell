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

    private enum QueueItem {
        case data(Data)
        /// A layout boundary: everything after it waits until released.
        case barrier(UInt64)

        var byteCount: Int {
            if case .data(let data) = self { return data.count }
            return 0
        }
    }

    private let lock = UnfairLock()
    private var sinks: [String: OutputSink] = [:]
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
            if let dropped = queues.removeValue(forKey: attachId) {
                queuedBytes -= dropped.reduce(0) { $0 + $1.byteCount }
            }
            draining.remove(attachId)
            overflowed.remove(attachId)
            attachByPane = attachByPane.filter { $0.value != attachId }
        }
    }

    /// Discards the output queued behind `id` up to the next barrier, on
    /// every attach carrying it: a layout that was superseded before its
    /// panes resized, whose redraw would parse on a grid it was not drawn
    /// for. Returns the attaches touched so the caller can re-snapshot them.
    func discardSegment(barrier id: UInt64) -> [String] {
        lock.withLock {
            barriers.remove(id)
            var touched: [String] = []
            for (attachId, queue) in queues {
                guard let start = queue.firstIndex(where: { if case .barrier(let b) = $0 { return b == id } else { return false } })
                else { continue }
                var kept = Array(queue[..<start])
                var index = start + 1
                var dropped = 0
                while index < queue.count {
                    if case .barrier = queue[index] { break }
                    dropped += queue[index].byteCount
                    index += 1
                }
                kept.append(contentsOf: queue[index...])
                queues[attachId] = kept
                queuedBytes -= dropped
                touched.append(attachId)
            }
            return touched
        }
    }

    func removeAll() {
        lock.withLock {
            sinks.removeAll()
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
        guard let queue = queues[attachId] else { return }
        queuedBytes -= queue.reduce(0) { $0 + $1.byteCount }
        let barriersOnly = queue.filter { if case .barrier = $0 { return true } else { return false } }
        queues[attachId] = barriersOnly.isEmpty ? nil : barriersOnly
    }

    private func deliver(attachId: String, _ data: Data, isSnapshot: Bool) {
        var overflowNow = false
        let sink: OutputSink? = lock.withLock {
            if overflowed.contains(attachId) {
                // Only the snapshot we asked for can make the screen whole.
                guard isSnapshot else { return nil }
                overflowed.remove(attachId)
                dropQueue(attachId)
            }
            let queued = !(queues[attachId]?.isEmpty ?? true)
            if let sink = sinks[attachId], !draining.contains(attachId), !queued {
                return sink
            }
            // A snapshot is never dropped: it replaces whatever this attach
            // had queued, and it is the only thing that can end an overflow.
            // It may exceed the shared budget briefly; the server caps it.
            if isSnapshot {
                dropQueue(attachId)
            } else if queuedBytes + data.count > Self.maxQueuedBytes {
                // Over budget: this attach's backlog is now incomplete, so
                // discard it all and recover from a fresh snapshot.
                dropQueue(attachId)
                overflowed.insert(attachId)
                overflowNow = true
                return nil
            }
            queues[attachId, default: []].append(.data(data))
            queuedBytes += data.count
            return nil
        }
        if overflowNow {
            onOverflow?(attachId)
            return
        }
        sink?.emit(data)
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
            let next: (OutputSink, Data)? = lock.withLock {
                guard let sink = sinks[attachId], var queue = queues[attachId] else {
                    draining.remove(attachId)
                    return nil
                }
                // Skip released barriers; stop at a live one.
                while case .barrier(let id)? = queue.first {
                    if barriers.contains(id) { break }
                    queue.removeFirst()
                }
                guard case .data(let data)? = queue.first else {
                    queues[attachId] = queue
                    draining.remove(attachId)
                    return nil
                }
                queue.removeFirst()
                queues[attachId] = queue
                queuedBytes -= data.count
                return (sink, data)
            }
            guard let next else { return }
            next.0.emit(next.1)
        }
    }

    func write(attachId: String, _ data: Data) {
        deliver(attachId: attachId, data, isSnapshot: false)
    }

    func applySnapshot(_ record: HerdrControl.SnapshotRecord) {
        deliver(attachId: record.attach_id, Self.replayBytes(for: record.snapshot), isSnapshot: true)
    }

    /// Composes the byte sequence that rebuilds a surface from a snapshot:
    /// clear everything, replay the primary history, switch to and paint the
    /// alternate screen when it is active, restore modes, then the cursor.
    /// Wrapped in synchronized output so the rebuild never flickers.
    static func replayBytes(for snapshot: HerdrControl.TerminalSnapshot) -> Data {
        var out = Data()
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
        controller?.paneSessionDidStop(self)
    }

    func sendInput(_ data: Data) {
        controller?.sendInput(from: self, data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        controller?.paneGridDidChange(self, rows: Int(size.rows), cols: Int(size.cols))
    }

    /// The pane went away on the server: end the session so the tab's
    /// ordinary close path runs.
    func endedRemotely() {
        guard isRunning else { return }
        isRunning = false
        onSessionEnd?()
    }
}
