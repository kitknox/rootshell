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
        /// Ordered with PTY output; its reply changes the response policy.
        case authority(Bool)
        /// A layout boundary: everything after it waits until released.
        case barrier(UInt64)

        var byteCount: Int {
            switch self {
            case .data(let data), .snapshot(let data, _, _), .control(let data): return data.count
            case .authority(let value): return HerdrQueryAuthority.marker(answersQueries: value).count
            case .barrier: return 0
            }
        }
    }

    private let lock = UnfairLock()
    private var sinks: [String: OutputSink] = [:]
    private var grids: [String: (cols: Int, rows: Int)] = [:]
    private var snapshotRevisions: [String: UUID] = [:]
    private var queryAuthorityEnabled = false
    private var queryAuthorities: [String: Bool] = [:]
    /// Per attach, the escape or UTF-8 sequence the last emitted chunk ended
    /// inside. herdr forwards raw PTY reads, so a sequence can straddle two
    /// records; Ghostty only ever receives whole ones.
    private var carries: [String: TerminalSequenceBoundary.Carry] = [:]
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
            snapshotRevisions.removeValue(forKey: attachId)
            queryAuthorities.removeValue(forKey: attachId)
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
                snapshotRevisions.removeValue(forKey: attachId)
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
            snapshotRevisions.removeAll()
            queryAuthorities.removeAll()
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

    func configureQueryAuthority(enabled: Bool) {
        lock.withLock { queryAuthorityEnabled = enabled }
    }

    func setQueryAuthority(attachId: String, answersQueries: Bool) {
        deliver(attachId: attachId, .authority(answersQueries), isSnapshot: false)
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
            snapshotRevisions.removeValue(forKey: attachId)
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

    /// Acknowledges the old grid's output before UIKit resizes the surface.
    /// Unlike `inject`, this stays behind all bytes preceding the layout.
    /// The unfinished carry stays held: the probe runs at a sequence boundary
    /// and the rest of that sequence belongs after the resize.
    func enqueueLayoutFence(attachId: String, barrier: UInt64, bytes: Data) -> Bool {
        let queued = lock.withLock {
            guard sinks[attachId] != nil, !overflowed.contains(attachId),
                  let index = queues[attachId]?.firstIndex(where: {
                      if case .barrier(let id) = $0 { return id == barrier }
                      return false
                  }) else { return false }
            queues[attachId]?.insert(.control(bytes), at: index)
            queuedBytes += bytes.count
            return true
        }
        if queued { flush(attachId) }
        return queued
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
            if case .authority(let value) = item {
                // Keep the latest standing even if a gap drops its marker;
                // a replacement snapshot must restore it before live output.
                queryAuthorities[attachId] = value
            }
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
                snapshotRevisions[attachId] = UUID()
                dropQueue(attachId)
            } else if queuedBytes + item.byteCount > Self.maxQueuedBytes {
                // Over budget: this attach's backlog is now incomplete, so
                // discard it all and recover from a fresh snapshot.
                dropQueue(attachId)
                overflowed.insert(attachId)
                snapshotRevisions.removeValue(forKey: attachId)
                overflowNow = true
                return
            }
            var queuedItem = item
            if case .snapshot(let bytes, let cols, let rows) = item {
                let authority = queryAuthorities[attachId] ?? !queryAuthorityEnabled
                // A discarded oversized escape can leave the parser inside
                // a string; cancel it before asking for the authority marker.
                queuedItem = .snapshot(Data([0x18]) + HerdrQueryAuthority.marker(answersQueries: authority) + bytes, cols: cols, rows: rows)
            }
            queues[attachId, default: []].append(queuedItem)
            queuedBytes += queuedItem.byteCount
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
                // Taken out of the dictionary so removeFirst does not copy it.
                guard let sink = sinks[attachId], var queue = queues.removeValue(forKey: attachId) else {
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
                case .authority(let value):
                    data = HerdrQueryAuthority.marker(answersQueries: value)
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
        carries[attachId, default: .init()].split(appending: bytes, limit: Self.maxCarryBytes)
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

    func snapshotRevision(attachId: String) -> UUID? {
        lock.withLock { snapshotRevisions[attachId] }
    }

    /// Unlike a resize probe, this must remain behind snapshots and barriers.
    /// Reject a revision replaced between the main-actor check and enqueue.
    func enqueueReadFence(attachId: String, snapshot: UUID, bytes: Data) -> Bool {
        let queued = lock.withLock {
            guard sinks[attachId] != nil, snapshotRevisions[attachId] == snapshot else { return false }
            queues[attachId, default: []].append(.control(bytes))
            queuedBytes += bytes.count
            return true
        }
        if queued { flush(attachId) }
        return queued
    }

    func write(attachId: String, _ data: Data) {
        guard !data.isEmpty else { return }
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

    var parserGrid: TerminalGridReports.Grid? { parserGridConfirmation.confirmed }
    private var parserGridConfirmation = HerdrParserGrid()
    /// Unfinished escape sequence from the last response-pipe read.
    private var responseCarry = Data()
    private var responseCarryFlush: Task<Void, Never>?
    private var gridProbeTask: Task<Void, Never>?
    private var parserFence = HerdrParserFence()
    private var queryAuthority = HerdrQueryAuthority()
    /// Marks the end of an activation's replay: the pane returns to live
    /// output once the parser has drained everything queued ahead of it.
    struct ReadFence {
        let id: Int
        let generation: UUID
        let snapshot: UUID
    }
    var readFence: ReadFence?

    private struct LayoutFence {
        let id: Int
        let continuation: CheckedContinuation<Bool, Never>
        let deadline: Task<Void, Never>
    }
    private var layoutFence: LayoutFence?

    /// The output pipe and Ghostty's resize mailbox are separate queues.
    /// Crossing the API queue cannot prove that old-grid bytes were parsed.
    func drainBeforeLayout(barrier: UInt64, attachID: String, generation: UUID,
                           router: HerdrOutputRouter) async -> Bool {
        // The task can start after a reconnect. Never put an old layout's
        // probe on the replacement stream, even if its attach ID is reused.
        guard isRunning, attachId == attachID,
              controller?.streamGeneration == generation, controller?.router === router,
              let probe = parserFence.issue() else { return false }
        finishLayoutFence(drained: false)
        return await withCheckedContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(750)) }
                catch { return }
                guard self?.layoutFence?.id == probe.id else { return }
                self?.finishLayoutFence(drained: false)
            }
            layoutFence = LayoutFence(id: probe.id, continuation: continuation, deadline: deadline)
            if !router.enqueueLayoutFence(attachId: attachID, barrier: barrier, bytes: probe.bytes) {
                finishLayoutFence(drained: false)
            }
        }
    }

    private func finishLayoutFence(drained: Bool) {
        guard let fence = layoutFence else { return }
        layoutFence = nil
        fence.deadline.cancel()
        fence.continuation.resume(returning: drained)
    }

    func requestReadFence(generation: UUID, snapshot: UUID) {
        guard let attachId, let probe = parserFence.issue() else { return }
        readFence = ReadFence(id: probe.id, generation: generation, snapshot: snapshot)
        if controller?.router.enqueueReadFence(attachId: attachId, snapshot: snapshot, bytes: probe.bytes) != true {
            readFence = nil
        }
    }

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

    var connectionInfo: ConnectionInfo? {
        controller?.connectionInfo(tabID: controller?.paneInfos[paneId]?.tab_id, terminalID: terminalId)
    }

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
        finishLayoutFence(drained: false)
        readFence = nil
        gridProbeTask?.cancel()
        gridProbeTask = nil
        responseCarryFlush?.cancel()
        responseCarryFlush = nil
        responseCarry = Data()
        controller?.paneSessionDidStop(self)
    }

    func sendInput(_ data: Data) {
        controller?.sendInput(from: self, data)
    }

    /// Bytes Ghostty wrote on its own (query replies, pastes), as opposed to
    /// keystrokes rootshell encoded. Replies are subject to query authority,
    /// so a reply split across two pipe reads is reassembled before it is
    /// classified; the unfinished tail waits for the next read or 50 ms.
    func sendResponse(_ data: Data) {
        responseCarryFlush?.cancel()
        responseCarryFlush = nil
        var pending = responseCarry + data
        responseCarry = Data()
        if let start = HerdrReplyFilter.incompleteTailStart([UInt8](pending)),
           pending.count - start <= Self.maxResponseCarryBytes {
            responseCarry = pending.subdata(in: start..<pending.count)
            pending = pending.subdata(in: 0..<start)
            responseCarryFlush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled, !self.responseCarry.isEmpty else { return }
                // Alone this long it is input (a bare ESC key), never a reply.
                let held = self.responseCarry
                self.responseCarry = Data()
                self.controller?.sendInput(from: self, held, automaticReply: false)
            }
        }
        guard !pending.isEmpty else { return }
        // Filter after the existing response reassembly. Keeping a second
        // ambiguous ESC carry ahead of it could swallow a user's Escape key
        // forever when a queued probe was discarded by a replacement snapshot.
        for segment in queryAuthority.consume(pending) {
            let fences = parserFence.consume(segment.bytes)
            for id in fences.acknowledged {
                if layoutFence?.id == id {
                    finishLayoutFence(drained: true)
                    continue
                }
                guard let fence = readFence, fence.id == id else { continue }
                readFence = nil
                controller?.parserDidDrain(self, fence: fence)
            }
            guard !fences.forward.isEmpty else { continue }
            let automatic = HerdrReplyFilter.isAutomaticReply(fences.forward)
            guard !automatic || segment.answersQueries else { continue }
            controller?.sendInput(from: self, fences.forward, automaticReply: automatic)
        }
    }

    private static let maxResponseCarryBytes = 64 * 1024

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        controller?.paneGridDidChange(self, rows: Int(size.rows), cols: Int(size.cols))
    }

    /// Polling schedules another query; only an exact parser reply permits
    /// replay. A delay or timeout never counts as a resize acknowledgement.
    func confirmParserGrid(cols: Int, rows: Int) {
        let wanted = TerminalGridReports.Grid(cols: cols, rows: rows)
        parserGridConfirmation.request(wanted)
        guard parserGridConfirmation.needsProbe, gridProbeTask == nil, isRunning else { return }
        gridProbeTask = Task { [weak self] in
            defer { self?.gridProbeTask = nil }
            var lastProbe = ContinuousClock.now
            while let self, self.isRunning, !Task.isCancelled,
                  self.parserGridConfirmation.needsProbe {
                if self.parserGridConfirmation.pending == 0 || lastProbe.duration(to: .now) >= .seconds(1) {
                    // Through the router, so the probe lands between whole
                    // sequences of live output. Before the attach exists,
                    // and in fallback mode, nothing else is flowing.
                    let probe = self.parserGridConfirmation.probe()
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

    func invalidateParserGrid() {
        parserGridConfirmation.invalidate()
    }

    /// Called only for the response pipe, so keyboard/paste input does not
    /// get mistaken for an internal probe reply.
    func consumeParserGridReports(_ data: Data) -> Data {
        let result = parserGridConfirmation.consume(data)
        for grid in result.grids {
            controller?.paneParserGridDidChange(self, cols: grid.cols, rows: grid.rows)
        }
        // A retry can still have a reply in flight when the first matching
        // reply stops polling. Keep recovery live if that later observation
        // says the parser moved again.
        if parserGridConfirmation.needsProbe, let wanted = parserGridConfirmation.wanted {
            confirmParserGrid(cols: wanted.cols, rows: wanted.rows)
        }
        return result.forward
    }

    /// The pane went away on the server: end the session so the tab's
    /// ordinary close path runs.
    func endedRemotely() {
        guard isRunning else { return }
        isRunning = false
        finishLayoutFence(drained: false)
        readFence = nil
        gridProbeTask?.cancel()
        gridProbeTask = nil
        onSessionEnd?()
    }
}
