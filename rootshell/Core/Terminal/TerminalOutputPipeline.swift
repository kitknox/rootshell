import Foundation
import os
import UIKit

struct TerminalOutputCoalescingConfig: Sendable {
    let inputDebounceMs: Int
    let minBatchIntervalMs: Int
    let maxBatchIntervalMs: Int
    let debug: Bool

    static func fromEnvironment(defaultMinMs: Int? = nil) -> TerminalOutputCoalescingConfig {
        let envMin = envInt("GHOSTTY_OUTPUT_COALESCE_MIN_MS")
        let envMax = envInt("GHOSTTY_OUTPUT_COALESCE_MAX_MS")

        var minMs = envMin ?? defaultMinMs ?? defaultMinBatchIntervalMs()
        var maxMs = envMax ?? minMs * 3

        if minMs < 1 {
            minMs = 1
        }
        if maxMs < minMs {
            maxMs = minMs
        }

        return TerminalOutputCoalescingConfig(
            inputDebounceMs: envInt("GHOSTTY_OUTPUT_COALESCE_INPUT_DEBOUNCE_MS") ?? 400,
            minBatchIntervalMs: minMs,
            maxBatchIntervalMs: maxMs,
            debug: (envInt("GHOSTTY_OUTPUT_COALESCE_DEBUG") ?? 0) != 0
        )
    }

    private static func envInt(_ key: String) -> Int? {
        guard let value = ProcessInfo.processInfo.environment[key],
              let intValue = Int(value) else {
            return nil
        }
        return intValue
    }

    private static func defaultMinBatchIntervalMs() -> Int {
#if os(visionOS)
        return 16
#else
        let maxFps = UIScreen.main.maximumFramesPerSecond
        guard maxFps > 0 else { return 16 }
        let frameMs = Int((1000.0 / Double(maxFps)).rounded())
        return max(8, frameMs)
#endif
    }
}

/// Owns the terminal output byte path: session-output gating, buffered writes
/// to Ghostty's external-IO pipe, and optional mouse-capture output coalescing.
@MainActor
final class TerminalOutputPipeline {
    private let writeQueue = DispatchQueue(label: "com.rootshell.pty.write", qos: .userInitiated)
    private let config: TerminalOutputCoalescingConfig
    private var isOutputCoalescingSuppressedByInput = false
    private var outputCoalescingResumeTimer: Timer?
    private var onURLRequest: (@Sendable (URL) -> Void)?
    private var urlRequestObserver: TerminalURLRequestObserver?
    /// Where the adopted tssh session's remote program first wrote.
    let remoteOutput = TerminalRemoteOutputMarker()

    let bufferedWriter: TerminalBufferedPipeWriter
    let scrollbackRestoreOutputGate = TerminalScrollbackRestoreOutputGate()

    private lazy var outputCoalescer: TerminalOutputCoalescer = {
        TerminalOutputCoalescer(
            minBatchIntervalMs: config.minBatchIntervalMs,
            maxBatchIntervalMs: config.maxBatchIntervalMs,
            debug: config.debug,
            write: { [scrollbackRestoreOutputGate, bufferedWriter] data, mark in
                scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter, onWritten: mark)
            }
        )
    }()

    init() {
        self.config = TerminalOutputCoalescingConfig.fromEnvironment()
        self.bufferedWriter = TerminalBufferedPipeWriter(queue: writeQueue)
    }

    init(config: TerminalOutputCoalescingConfig) {
        self.config = config
        self.bufferedWriter = TerminalBufferedPipeWriter(queue: writeQueue)
    }

    func configure(fd: Int32) {
        bufferedWriter.configure(fd: fd)
        remoteOutput.pipeChanged()
    }

    func cancel() {
        outputCoalescingResumeTimer?.invalidate()
        outputCoalescingResumeTimer = nil
        scrollbackRestoreOutputGate.cancel()
        bufferedWriter.cancel()
    }

    func writeDirect(_ data: Data) {
        bufferedWriter.write(data)
    }

    func writeDirect(_ string: String) {
        bufferedWriter.write(Data(string.utf8))
    }

    /// The bytes that follow restored scrollback. A complete replay has to
    /// arrive whole: cut at the front by the writer's cap it would lose its
    /// reset and paint over whatever the terminal showed.
    func writeRestoreTrailer(_ data: Data) {
        bufferedWriter.write(data, keepingWhole: TerminalRestorationSnapshot.isReplay(data))
    }

    func writeSessionOutput(_ data: Data) {
        urlRequestObserver?.consume(data)
        scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter)
    }

    func enqueueCoalescedOutput(_ data: Data) {
        urlRequestObserver?.consume(data)
        outputCoalescer.enqueue(data)
    }

    func setURLRequestHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        onURLRequest = handler
        resetURLRequestObserver()
    }

    func resetURLRequestObserver() {
        urlRequestObserver = onURLRequest.map { TerminalURLRequestObserver(onURL: $0) }
    }

    func setOutputCoalescingEnabled(_ enabled: Bool) {
        outputCoalescer.setEnabled(enabled)
    }

    func updateOutputCoalescingState(shouldUseOutputCoalescer: Bool, isMouseCaptured: Bool, fdConfigured: Bool) {
        guard fdConfigured else { return }
        guard shouldUseOutputCoalescer else {
            outputCoalescer.setEnabled(false)
            return
        }

        let shouldEnable = isMouseCaptured && !isOutputCoalescingSuppressedByInput
        outputCoalescer.setEnabled(shouldEnable)
    }

    func noteUserInputForOutputCoalescing(
        shouldUseOutputCoalescer: Bool,
        fdConfigured: Bool,
        refreshState: @escaping @MainActor () -> Void
    ) {
        guard shouldUseOutputCoalescer else { return }
        guard fdConfigured else { return }

        if !isOutputCoalescingSuppressedByInput {
            isOutputCoalescingSuppressedByInput = true
            outputCoalescer.setEnabled(false)
        }

        outputCoalescingResumeTimer?.invalidate()
        let debounceSeconds = Double(config.inputDebounceMs) / 1000.0
        outputCoalescingResumeTimer = Timer.scheduledTimer(withTimeInterval: debounceSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOutputCoalescingSuppressedByInput = false
                self.outputCoalescingResumeTimer = nil
                refreshState()
            }
        }
    }

    func enableScrollbackRestoreGate() {
        scrollbackRestoreOutputGate.enable()
    }

    func finishScrollbackRestoreGate() {
        scrollbackRestoreOutputGate.finish(to: bufferedWriter)
    }

    func cancelScrollbackRestoreGate() {
        scrollbackRestoreOutputGate.cancel()
    }

    func notifyWhenOutputDrained(_ callback: @escaping @Sendable () -> Void) {
        bufferedWriter.notifyWhenDrained(callback)
    }

    func setWriterOverflowHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        bufferedWriter.setOverflowHandler(handler)
    }

    func makeSessionOutputSink(
        useOutputCoalescer: Bool,
        terminalUUID: UUID,
        noteGatewayInboundBytes: @escaping @Sendable (Int) -> Void
    ) -> @Sendable (Data) -> Void {
        let outputCoalescer: TerminalOutputCoalescer? = useOutputCoalescer ? self.outputCoalescer : nil
        let bufferedWriter = self.bufferedWriter
        let scrollbackRestoreOutputGate = self.scrollbackRestoreOutputGate
        struct PersistenceNotifyState {
            var pending = false
            var lastNotifiedUptimeNs: UInt64 = 0
        }
        let persistenceNotifyState = OSAllocatedUnfairLock(initialState: PersistenceNotifyState())
        // ScrollbackPersistenceManager already debounces saves by 2s; throttling
        // the MainActor wakeup to 250ms avoids spawning a Task on every keystroke echo.
        let persistenceThrottleNs: UInt64 = 250_000_000
        // A new session starts with its connection progress on screen. The
        // sink keeps its session's id: output of a replaced session can still
        // arrive and must not count as the new one's.
        let remoteOutput = self.remoteOutput
        let remoteSession = remoteOutput.beginSession()
        // One fresh parser per adopted session. Saved scrollback and local
        // redraws use writeDirect and cannot replay a browser request.
        let urlObserver = onURLRequest.map { TerminalURLRequestObserver(onURL: $0) }

        return { data in
            noteGatewayInboundBytes(data.count)
            urlObserver?.consume(data)

            // The session's first remote chunk carries a mark through the
            // coalescer and the restore gate to the pipe writer, which
            // reports where in the pipe that chunk ended.
            // Only bytes a remote program wrote count; a session also writes
            // text of its own through this sink.
            let session: UInt64? = switch TerminalRemoteOutputMarker.remoteDelivery {
            case .ownSession: remoteSession
            case .session(let embedded): embedded
            case nil: nil
            }
            let mark = data.isEmpty ? nil : session.flatMap { remoteOutput.claimFirstWrite(session: $0) }

            if let outputCoalescer {
                outputCoalescer.enqueue(data, onWritten: mark)
            } else {
                scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter, onWritten: mark)
            }

            guard !Ghostty.isAppBackgroundedAtomic else { return }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let shouldSpawn = persistenceNotifyState.withLock { state -> Bool in
                guard !state.pending else { return false }
                guard nowNs &- state.lastNotifiedUptimeNs >= persistenceThrottleNs else { return false }
                state.pending = true
                state.lastNotifiedUptimeNs = nowNs
                return true
            }
            guard shouldSpawn else { return }

            Task { @MainActor in
                persistenceNotifyState.withLock { $0.pending = false }
                guard !Ghostty.isAppBackgroundedAtomic else { return }
                ScrollbackPersistenceManager.shared.notifyOutputReceived(terminalUUID: terminalUUID)
            }
        }
    }
}

// @unchecked Sendable: internal state is confined to the coalescer queue,
// except for enabledForFastPath which uses os_unfair_lock for fast-path bypass.
nonisolated final class TerminalOutputCoalescer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rootshell.output.coalescer", qos: .userInitiated)
    private let minBatchInterval: DispatchTimeInterval
    private let maxBatchInterval: DispatchTimeInterval
    private let debug: Bool
    private let write: @Sendable (Data, TerminalWriteMark?) -> Void
    private var pending = Data()
    private var pendingMarks: [TerminalWriteMark] = []
    private var timer: DispatchSourceTimer?
    private var firstEnqueueTime: DispatchTime?
    private var currentDeadline: DispatchTime?
    private var enabledForFastPath = false
    private var disableFlushInProgress = false
    private var inFlightEnqueues = 0
    private var hasPendingBytes = false
    private var transitionGeneration: UInt64 = 0
    private var fastPathLock = os_unfair_lock()
    private var isEnabled = false

    init(minBatchIntervalMs: Int, maxBatchIntervalMs: Int, debug: Bool, write: @escaping @Sendable (Data, TerminalWriteMark?) -> Void) {
        let minMs = max(1, minBatchIntervalMs)
        let maxMs = max(minMs, maxBatchIntervalMs)
        self.minBatchInterval = .milliseconds(minMs)
        self.maxBatchInterval = .milliseconds(maxMs)
        self.debug = debug
        self.write = write
    }

    deinit {
        timer?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        let generation: UInt64
        os_unfair_lock_lock(&fastPathLock)
        transitionGeneration &+= 1
        generation = transitionGeneration
        if enabled {
            enabledForFastPath = true
        } else {
            enabledForFastPath = false
            // Only hold new chunks behind the queue drain if bytes are actually
            // buffered or an async enqueue is in flight; otherwise interactive
            // echoes bypass the coalescer queue synchronously immediately.
            disableFlushInProgress = (inFlightEnqueues > 0 || hasPendingBytes)
        }
        os_unfair_lock_unlock(&fastPathLock)

        if debug {
            Ghostty.logger.debug("OutputCoalescer setEnabled(\(enabled)) generation=\(generation)")
        }

        queue.async {
            self.isEnabled = enabled

            if !enabled {
                if self.debug {
                    let byteCount = self.pending.count
                    Ghostty.logger.debug("OutputCoalescer disabling; flushing \(byteCount) pending bytes")
                }
                self.flushLocked()
            }

            os_unfair_lock_lock(&self.fastPathLock)
            if self.transitionGeneration == generation {
                self.enabledForFastPath = enabled
                self.disableFlushInProgress = false
            }
            os_unfair_lock_unlock(&self.fastPathLock)
        }
    }

    /// `mark` goes on with `data`, or with the batch `data` ends up in.
    func enqueue(_ data: Data, onWritten mark: TerminalWriteMark? = nil) {
        os_unfair_lock_lock(&fastPathLock)
        let bypass = !enabledForFastPath && !disableFlushInProgress
        if !bypass {
            inFlightEnqueues += 1
        }
        os_unfair_lock_unlock(&fastPathLock)

        if bypass {
            if debug {
                let byteCount = data.count
                Ghostty.logger.debug("OutputCoalescer direct bypass: \(byteCount) bytes")
            }
            write(data, mark)
            return
        }

        queue.async {
            if !self.isEnabled {
                self.write(data, mark)
                os_unfair_lock_lock(&self.fastPathLock)
                self.inFlightEnqueues -= 1
                os_unfair_lock_unlock(&self.fastPathLock)
                return
            }

            self.pending.append(data)
            if let mark { self.pendingMarks.append(mark) }
            os_unfair_lock_lock(&self.fastPathLock)
            self.hasPendingBytes = true
            self.inFlightEnqueues -= 1
            os_unfair_lock_unlock(&self.fastPathLock)
            if self.firstEnqueueTime == nil {
                self.firstEnqueueTime = .now()
            }
            self.scheduleTimerLocked()
        }
    }

    private func scheduleTimerLocked() {
        guard let firstEnqueueTime = firstEnqueueTime else { return }
        let now = DispatchTime.now()
        let minDeadline = now + minBatchInterval
        let maxDeadline = firstEnqueueTime + maxBatchInterval
        let deadline: DispatchTime
        if minDeadline.uptimeNanoseconds <= maxDeadline.uptimeNanoseconds {
            deadline = minDeadline
        } else {
            deadline = maxDeadline
        }

        if let currentDeadline,
           currentDeadline.uptimeNanoseconds == deadline.uptimeNanoseconds {
            return
        }

        cancelTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        timer.resume()
        self.timer = timer
        self.currentDeadline = deadline
    }

    private func flushLocked() {
        guard !pending.isEmpty else {
            cancelTimerLocked()
            firstEnqueueTime = nil
            os_unfair_lock_lock(&fastPathLock)
            hasPendingBytes = false
            os_unfair_lock_unlock(&fastPathLock)
            return
        }

        let output = pending
        pending.removeAll(keepingCapacity: true)
        let marks = pendingMarks
        pendingMarks.removeAll()
        cancelTimerLocked()
        firstEnqueueTime = nil
        write(output, mergedTerminalWriteMark(marks))
        os_unfair_lock_lock(&fastPathLock)
        hasPendingBytes = false
        os_unfair_lock_unlock(&fastPathLock)
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
        currentDeadline = nil
    }
}

/// Shared chunk-queue tuning for the buffered writer and the restore gate.
private nonisolated enum TerminalOutputChunkTuning {
    /// Writes below this size are coalesced into the tail chunk so a stream
    /// of tiny writes (keystroke echoes) can't inflate the queue to millions
    /// of entries within the byte cap.
    static let smallChunkBytes = 4096
    /// Stop coalescing into a tail chunk once it reaches this size; growth
    /// reallocation stays trivially small below it.
    static let coalescedChunkLimitBytes = 64 * 1024

    /// Owned, compact copy of `data`'s trailing `count` bytes. Data.suffix
    /// alone would share (and pin) the full backing storage of an arbitrarily
    /// large original, defeating the byte caps.
    static func ownedSuffix(of data: Data, count: Int) -> Data {
        let start = data.count - count
        return data.withUnsafeBytes { ptr -> Data in
            guard let base = ptr.baseAddress else { return Data() }
            return Data(bytes: base + start, count: count)
        }
    }
}

/// Holds live reconnect output until scrollback restoration has queued its
/// saved bytes.
///
/// Buffered output is kept as a queue of the incoming chunks rather than one
/// contiguous Data: appending to a multi-megabyte Data reallocates (doubling
/// peak footprint) and can trap outright when the process is under memory
/// pressure, while retaining chunk references allocates nothing.
nonisolated final class TerminalScrollbackRestoreOutputGate: @unchecked Sendable {
    private static let maxBufferedBytes = 10 * 1024 * 1024
    /// Prepended at a drop seam so a parser mid-OSC/DCS whose terminator was
    /// dropped can't swallow all subsequent output; a stray ST in ground
    /// state is a no-op.
    private static let stringTerminator = Data([0x1B, 0x5C])

    private struct State {
        var isEnabled = false
        var chunks: [Data] = []
        var bufferedByteCount = 0
        var didLogOverflow = false
        /// Marks of buffered chunks, each with the buffered byte count its
        /// chunk ends at.
        var marks: [(end: Int, mark: TerminalWriteMark)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enable() {
        state.withLock { state in
            guard !state.isEnabled else { return }
            state.isEnabled = true
            state.chunks.removeAll(keepingCapacity: true)
            state.bufferedByteCount = 0
            state.didLogOverflow = false
        }
    }

    /// `mark` stays with `data`: it goes to the writer now, or when the gate
    /// opens, and is told if the gate drops the chunk instead.
    func writeOrBuffer(_ data: Data, to writer: TerminalBufferedPipeWriter, onWritten mark: TerminalWriteMark? = nil) {
        guard !data.isEmpty else {
            mark?(nil)
            return
        }

        let result = state.withLock { state -> (shouldWrite: Bool, shouldLogOverflow: Bool) in
            guard state.isEnabled else {
                return (shouldWrite: true, shouldLogOverflow: false)
            }
            let bufferedBefore = state.bufferedByteCount
            var droppedBuffered = 0

            var incoming = data
            var shouldLogOverflow = false

            if state.bufferedByteCount + incoming.count > Self.maxBufferedBytes {
                // Enforce the cap BEFORE storing so the buffered bytes never
                // exceed it: drop exactly the excess from the oldest end —
                // whole chunks while they fit within the excess, then an
                // owned copy of the straddling chunk's remainder (a suffix
                // slice would pin the full chunk).
                var dropCount = 0
                while state.bufferedByteCount + incoming.count > Self.maxBufferedBytes,
                      dropCount < state.chunks.count {
                    let oldest = state.chunks[dropCount]
                    let excess = state.bufferedByteCount + incoming.count - Self.maxBufferedBytes
                    if oldest.count <= excess {
                        dropCount += 1
                        state.bufferedByteCount -= oldest.count
                        continue
                    }
                    state.chunks[dropCount] = TerminalOutputChunkTuning.ownedSuffix(
                        of: oldest, count: oldest.count - excess)
                    state.bufferedByteCount -= excess
                    break
                }
                if dropCount > 0 {
                    state.chunks.removeFirst(dropCount)
                }
                if incoming.count > Self.maxBufferedBytes {
                    incoming = TerminalOutputChunkTuning.ownedSuffix(
                        of: incoming, count: Self.maxBufferedBytes)
                }
                droppedBuffered = bufferedBefore - state.bufferedByteCount
                state.chunks.insert(Self.stringTerminator, at: 0)
                state.bufferedByteCount += Self.stringTerminator.count
                if !state.didLogOverflow {
                    state.didLogOverflow = true
                    shouldLogOverflow = true
                }
            }

            if incoming.count < TerminalOutputChunkTuning.smallChunkBytes,
               let last = state.chunks.indices.last,
               state.chunks[last].count < TerminalOutputChunkTuning.coalescedChunkLimitBytes {
                state.chunks[last].append(incoming)
            } else {
                state.chunks.append(incoming)
            }
            state.bufferedByteCount += incoming.count

            // The oldest bytes were dropped and a terminator took their
            // place. A mark whose chunk went with them moves to the end of
            // what is buffered now: output that follows it in the stream.
            if droppedBuffered > 0 {
                for index in state.marks.indices {
                    let end = state.marks[index].end
                    state.marks[index].end = end > droppedBuffered
                        ? end - droppedBuffered + Self.stringTerminator.count
                        : state.bufferedByteCount
                }
            }
            if let mark { state.marks.append((end: state.bufferedByteCount, mark: mark)) }

            return (shouldWrite: false, shouldLogOverflow: shouldLogOverflow)
        }

        if result.shouldWrite {
            writer.write(data, onWritten: mark)
        }
        if result.shouldLogOverflow {
            Ghostty.logger.warning("ScrollbackRestoreOutputGate exceeded 10MB; dropping oldest buffered live output")
        }
    }

    func finish(to writer: TerminalBufferedPipeWriter) {
        state.withLock { state in
            guard state.isEnabled else { return }
            var end = 0
            for chunk in state.chunks {
                end += chunk.count
                // Small chunks were merged, so a mark goes with the chunk
                // its own ends in.
                let due = state.marks.filter { $0.end <= end }.map(\.mark)
                state.marks.removeAll { $0.end <= end }
                writer.write(chunk, onWritten: mergedTerminalWriteMark(due))
            }
            state.marks.forEach { $0.mark(nil) }
            state.marks.removeAll()
            state.chunks.removeAll(keepingCapacity: false)
            state.bufferedByteCount = 0
            state.isEnabled = false
            state.didLogOverflow = false
        }
    }

    func cancel() {
        let dropped = state.withLock { state -> (bytes: Int, marks: [TerminalWriteMark])? in
            guard state.isEnabled else { return nil }
            state.isEnabled = false
            state.didLogOverflow = false
            let droppedBytes = state.bufferedByteCount
            let marks = state.marks.map(\.mark)
            state.marks.removeAll()
            state.chunks.removeAll(keepingCapacity: false)
            state.bufferedByteCount = 0
            return (droppedBytes, marks)
        }
        guard let dropped else { return }

        dropped.marks.forEach { $0(nil) }
        if dropped.bytes > 0 {
            Ghostty.logger.warning("ScrollbackRestoreOutputGate canceled; dropping buffered live output")
        }
    }

    var debugState: (enabled: Bool, bufferedBytes: Int) {
        state.withLock { (enabled: $0.isEnabled, bufferedBytes: $0.bufferedByteCount) }
    }
}

/// Buffered pipe writer that uses DispatchSource to write when the pipe is
/// writable, buffering data when the pipe is full.
///
/// Pending output is a queue of the incoming chunks themselves, retained by
/// reference. A contiguous Data buffer reallocates as it grows (doubling peak
/// footprint per growth step), never returns capacity after a burst, and
/// memmoves megabytes on every drop-oldest cycle — and Foundation traps the
/// process when that reallocation fails under memory pressure, which is
/// exactly how this writer crashed in the field even with the size cap in
/// place. The chunk queue makes the hot path allocation-free.
nonisolated final class TerminalBufferedPipeWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Pending chunks; the live region is chunks[headIndex...]. The consumed
    /// prefix is compacted periodically rather than on every drain.
    private var chunks: [Data] = []
    private var headIndex = 0
    /// Bytes of chunks[headIndex] already written to the fd.
    private var headOffset = 0
    /// Total unwritten bytes across the queue.
    private var pendingByteCount = 0
    private var bufferLock = os_unfair_lock()
    private var writeSource: DispatchSourceWrite?
    private var fd: Int32 = -1
    private var drainCallbacks: [@Sendable () -> Void] = []
    private var isSuspended = true
    private var totalWritten: Int = 0
    /// Bytes written to the current fd. Ghostty counts what it has parsed from
    /// the other end (`ghostty_surface_parsed_bytes`), so the two are equal
    /// once everything written has taken effect.
    private var writtenToFd: UInt64 = 0
    /// Changes whenever the fd does, so a byte count is never compared with
    /// the parse position of another surface.
    private var pipeGeneration: UInt64 = 0
    /// Marks of queued chunks, each with the `writtenToFd` value its chunk's
    /// last byte is written at. Reported from the drain once reached.
    private var marks: [(end: UInt64, mark: TerminalWriteMark)] = []
    /// The `writtenToFd` value at which the last write that must arrive
    /// whole ends. Queued bytes before it are never dropped: they are a
    /// prefix of the queue that ends at a chunk boundary.
    private var wholeEnd: UInt64 = 0
    /// Keeps later small writes out of the chunk a whole write ends in.
    private var tailIsSealed = false
    private var totalDropped: Int = 0
    private var droppedSinceLastDrain: Int = 0
    private var didLogOverflow = false
    private var onOverflow: (@Sendable (Int) -> Void)?

    private static let bufferWarningThreshold = 1024 * 1024
    /// Hard cap on the pending bytes. If the core's read side stalls (or a
    /// firehose outruns its parse rate) the queue would otherwise grow without
    /// bound. On overflow the OLDEST chunks are dropped down to the low-water
    /// mark (halving amortizes the drop cost across writes) and the loss is
    /// reported via `onOverflow` once the queue next drains empty.
    private static let foregroundMaxBufferedBytes = 16 * 1024 * 1024

    /// Background jetsam limits are far tighter, so the cap shrinks while backgrounded.
    private static func maxBufferedBytes() -> Int {
        Ghostty.isAppBackgroundedAtomic
            ? BackgroundExecutionPolicy.backgroundPipeWriterMaxBytes
            : foregroundMaxBufferedBytes
    }
    /// Prepended at the drop seam: the core parser may be mid-OSC/DCS whose
    /// terminator was just dropped and would swallow all subsequent output;
    /// a stray ST in ground state is a no-op.
    private static let stringTerminator = Data([0x1B, 0x5C])

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        cancel()
    }

    func configure(fd: Int32) {
        // Bytes queued for the previous fd never reach this one. Told after
        // every unlock below.
        var orphanedMarks: [TerminalWriteMark] = []
        defer { orphanedMarks.forEach { $0(nil) } }

        os_unfair_lock_lock(&bufferLock)
        orphanedMarks = marks.map(\.mark)
        marks.removeAll()
        wholeEnd = 0
        tailIsSealed = false

        if let source = writeSource {
            if isSuspended {
                source.resume()
            }
            source.cancel()
            writeSource = nil
            isSuspended = true
        }

        self.fd = fd
        writtenToFd = 0
        pipeGeneration &+= 1

        // New fd generation: any pending-loss accounting belongs to the
        // previous surface. Reset it so a stale overflow report can't fire
        // (and trigger a spurious tmux reset) after the new surface drains.
        droppedSinceLastDrain = 0
        didLogOverflow = false

        guard fd >= 0 else {
            os_unfair_lock_unlock(&bufferLock)
            return
        }

        // Guarantee non-blocking semantics so inline fast-path writes and
        // DispatchSource drains can never block the caller thread.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) == 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writeSource = source
        isSuspended = true

        source.setEventHandler { [weak self] in
            self?.drainBuffer()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.bufferLock)
            self.isSuspended = true
            os_unfair_lock_unlock(&self.bufferLock)
        }

        os_unfair_lock_unlock(&bufferLock)
    }

    /// `mark` is told where in the pipe `data` ended once its last byte has
    /// been written to the fd, or that it was dropped. `keepingWhole` exempts
    /// `data` from the cap, now and while it is queued: it is never cut and
    /// doesn't count toward the cap, so the queue can exceed it by its size.
    func write(_ data: Data, onWritten mark: TerminalWriteMark? = nil, keepingWhole: Bool = false) {
        guard !data.isEmpty else {
            mark?(nil)
            return
        }

        let maxBufferedBytes = Self.maxBufferedBytes()
        let overflowLowWaterBytes = maxBufferedBytes / 2

        os_unfair_lock_lock(&bufferLock)

        guard fd >= 0, let source = writeSource else {
            os_unfair_lock_unlock(&bufferLock)
            Ghostty.logger.warning("BufferedPipeWriter: no FD configured, dropping \(data.count) bytes")
            mark?(nil)
            return
        }

        // Fast path: when the queue is empty and the chunk fits within a single
        // pipe buffer (<= 64 KiB), write non-blocking directly to the fd inline
        // without resuming the DispatchSource or hopping to writeQueue.
        if pendingByteCount == 0,
           drainCallbacks.isEmpty,
           droppedSinceLastDrain == 0,
           data.count <= min(65536, maxBufferedBytes) {
            let bytesWritten = data.withUnsafeBytes { ptr -> Int in
                guard let basePtr = ptr.baseAddress else { return data.count }
                return Darwin.write(fd, basePtr, data.count)
            }

            if bytesWritten == data.count {
                totalWritten &+= bytesWritten
                writtenToFd &+= UInt64(bytesWritten)
                let reachedOffset: TerminalPipeOffset? = mark != nil
                    ? TerminalPipeOffset(pipe: pipeGeneration, end: writtenToFd)
                    : nil
                os_unfair_lock_unlock(&bufferLock)
                if let mark, let reachedOffset {
                    mark(reachedOffset)
                }
                return
            }

            if bytesWritten > 0 {
                totalWritten &+= bytesWritten
                writtenToFd &+= UInt64(bytesWritten)
                chunks.removeAll(keepingCapacity: true)
                headIndex = 0
                chunks.append(data)
                headOffset = bytesWritten
                pendingByteCount = data.count - bytesWritten
                if keepingWhole {
                    wholeEnd = writtenToFd + UInt64(pendingByteCount)
                    tailIsSealed = true
                } else {
                    tailIsSealed = false
                }
                if let mark {
                    marks.append((end: writtenToFd + UInt64(pendingByteCount), mark: mark))
                }
                if isSuspended {
                    isSuspended = false
                    source.resume()
                }
                os_unfair_lock_unlock(&bufferLock)
                return
            }

            if bytesWritten < 0 {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK && err != EINTR {
                    os_unfair_lock_unlock(&bufferLock)
                    Ghostty.logger.error("BufferedPipeWriter: inline write error \(err), dropping \(data.count) bytes")
                    mark?(nil)
                    return
                }
            }
            // EAGAIN / EWOULDBLOCK / EINTR / 0: fall through to buffered queue + DispatchSource.
        }

        // The cap is for output that may be dropped. Bytes that must arrive
        // whole don't count toward it, or a queued replay would use it up
        // and every live write behind it would evict the one before.
        let wholeAhead = wholeEnd > writtenToFd ? Int(wholeEnd - writtenToFd) : 0
        let combinedSize = pendingByteCount - wholeAhead + (keepingWhole ? 0 : data.count)
        var overflowToLog = 0

        if combinedSize > maxBufferedBytes {
            // Enforce the cap BEFORE storing so the pending bytes never
            // materialize above it. Drop exactly the bytes needed to reach
            // the low-water mark from the oldest end of the logical (queue +
            // incoming) stream: whole chunks while they fit within the
            // excess, then an owned copy of the straddling chunk's remainder
            // (a suffix slice would pin the full chunk), trimming the
            // incoming chunk itself if it alone exceeds the mark (e.g. a
            // full scrollback restore passed as one Data). Bytes that must
            // arrive whole are passed over: the oldest ones behind them go.
            var incoming = data
            var dropped = 0
            var dropIndex = headIndex
            var kept = 0
            while kept < wholeAhead, dropIndex < chunks.count {
                kept += chunks[dropIndex].count - (dropIndex == headIndex ? headOffset : 0)
                dropIndex += 1
            }
            var counted = combinedSize
            while counted > overflowLowWaterBytes, dropIndex < chunks.count {
                let isHead = dropIndex == headIndex
                let chunk = chunks[dropIndex]
                let remainder = chunk.count - (isHead ? headOffset : 0)
                let excess = counted - overflowLowWaterBytes
                if remainder <= excess {
                    if isHead {
                        chunks[headIndex] = Data()
                        headIndex += 1
                        headOffset = 0
                        dropIndex = headIndex
                    } else {
                        chunks.remove(at: dropIndex)
                    }
                    pendingByteCount -= remainder
                    counted -= remainder
                    dropped += remainder
                    continue
                }
                chunks[dropIndex] = TerminalOutputChunkTuning.ownedSuffix(
                    of: chunk, count: remainder - excess)
                if isHead { headOffset = 0 }
                pendingByteCount -= excess
                counted -= excess
                dropped += excess
                break
            }
            let droppedQueued = dropped
            if !keepingWhole, incoming.count > overflowLowWaterBytes {
                dropped += incoming.count - overflowLowWaterBytes
                incoming = TerminalOutputChunkTuning.ownedSuffix(
                    of: incoming, count: overflowLowWaterBytes)
            }
            if headIndex == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                headIndex = 0
                dropIndex = 0
            }
            chunks.insert(Self.stringTerminator, at: dropIndex)
            pendingByteCount += Self.stringTerminator.count
            appendChunkLocked(incoming)
            // Bytes behind `dropStart` are gone and a terminator took their
            // place, so every chunk queued behind them ends that much earlier
            // in the pipe. A mark whose chunk went with them moves to the end
            // of what is queued now: output that follows it in the stream,
            // and an offset the pipe still reaches.
            let dropStart = writtenToFd + UInt64(kept)
            for index in marks.indices {
                let end = marks[index].end
                guard end > dropStart else { continue }
                marks[index].end = end - dropStart > UInt64(droppedQueued)
                    ? end - UInt64(droppedQueued) + UInt64(Self.stringTerminator.count)
                    : writtenToFd + UInt64(pendingByteCount)
            }
            totalDropped &+= dropped
            droppedSinceLastDrain &+= dropped
            if dropped > 0, !didLogOverflow {
                didLogOverflow = true
                overflowToLog = dropped
            }
        } else {
            appendChunkLocked(data)
            if combinedSize > Self.bufferWarningThreshold && combinedSize - data.count <= Self.bufferWarningThreshold {
                Ghostty.logger.warning("BufferedPipeWriter: buffer exceeded 1MB (\(combinedSize) bytes)")
            }
        }

        if keepingWhole {
            wholeEnd = writtenToFd + UInt64(pendingByteCount)
            tailIsSealed = true
        }

        if let mark {
            marks.append((end: writtenToFd + UInt64(pendingByteCount), mark: mark))
        }

        if isSuspended {
            isSuspended = false
            source.resume()
        }

        os_unfair_lock_unlock(&bufferLock)

        if overflowToLog > 0 {
            let cap = maxBufferedBytes
            Ghostty.logger.error("BufferedPipeWriter: buffer exceeded \(cap) byte cap; dropping oldest \(overflowToLog) bytes (reader stalled or output firehose)")
        }
    }

    /// Append with small-write coalescing so tiny writes can't inflate the
    /// queue to an unbounded entry count within the byte cap. Extending the
    /// tail chunk is safe even while it is the partially-written head:
    /// `headOffset` counts consumed bytes, so the remainder simply grows.
    /// Must be called with `bufferLock` held.
    private func appendChunkLocked(_ data: Data) {
        if !tailIsSealed,
           data.count < TerminalOutputChunkTuning.smallChunkBytes,
           chunks.count > headIndex,
           chunks[chunks.count - 1].count < TerminalOutputChunkTuning.coalescedChunkLimitBytes {
            chunks[chunks.count - 1].append(data)
        } else {
            chunks.append(data)
        }
        tailIsSealed = false
        pendingByteCount += data.count
    }

    func notifyWhenDrained(_ callback: @escaping @Sendable () -> Void) {
        var shouldRunNow = false

        os_unfair_lock_lock(&bufferLock)
        if pendingByteCount == 0 {
            shouldRunNow = true
        } else {
            drainCallbacks.append(callback)
        }
        os_unfair_lock_unlock(&bufferLock)

        if shouldRunNow {
            callback()
        }
    }

    private func drainBuffer() {
        os_unfair_lock_lock(&bufferLock)
        var callbacksToRun: [@Sendable () -> Void] = []
        var droppedToReport = 0
        var overflowHandler: (@Sendable (Int) -> Void)?

        guard pendingByteCount > 0, fd >= 0, let source = writeSource else {
            if pendingByteCount == 0 {
                callbacksToRun = drainCallbacks
                drainCallbacks.removeAll(keepingCapacity: true)
                droppedToReport = droppedSinceLastDrain
                droppedSinceLastDrain = 0
                didLogOverflow = false
                overflowHandler = onOverflow
            }

            if !isSuspended {
                isSuspended = true
                writeSource?.suspend()
            }
            os_unfair_lock_unlock(&bufferLock)
            if droppedToReport > 0 {
                overflowHandler?(droppedToReport)
            }
            for callback in callbacksToRun {
                callback()
            }
            return
        }

        // Write chunk-by-chunk until the pipe fills (short write or EAGAIN)
        // or the queue empties. Chunks are written in place — no
        // concatenation, no reallocation.
        var fatalWriteErrno: Int32?
        while headIndex < chunks.count {
            let chunk = chunks[headIndex]
            let remainder = chunk.count - headOffset
            guard remainder > 0 else {
                chunks[headIndex] = Data()
                headIndex += 1
                headOffset = 0
                continue
            }

            let offset = headOffset
            let bytesWritten = chunk.withUnsafeBytes { ptr -> Int in
                guard let basePtr = ptr.baseAddress else { return remainder }
                return Darwin.write(fd, basePtr + offset, remainder)
            }

            if bytesWritten == remainder {
                chunks[headIndex] = Data()
                headIndex += 1
                headOffset = 0
                totalWritten &+= bytesWritten
                writtenToFd &+= UInt64(bytesWritten)
                pendingByteCount -= bytesWritten
                continue
            }
            if bytesWritten > 0 {
                headOffset += bytesWritten
                totalWritten &+= bytesWritten
                writtenToFd &+= UInt64(bytesWritten)
                pendingByteCount -= bytesWritten
                break
            }
            if bytesWritten == 0 {
                break
            }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                break
            }
            fatalWriteErrno = err
            break
        }

        if let err = fatalWriteErrno {
            let droppedBytes = pendingByteCount
            chunks.removeAll(keepingCapacity: false)
            headIndex = 0
            headOffset = 0
            pendingByteCount = 0
            drainCallbacks.removeAll(keepingCapacity: true)
            // The pipe is dead; discard overflow accounting with the queue
            // so a later drain on a reconfigured fd can't report this
            // generation's loss window.
            droppedSinceLastDrain = 0
            didLogOverflow = false
            let orphanedMarks = marks.map(\.mark)
            marks.removeAll()
            wholeEnd = 0
            tailIsSealed = false
            if !isSuspended {
                isSuspended = true
                source.suspend()
            }
            os_unfair_lock_unlock(&bufferLock)
            Ghostty.logger.error("BufferedPipeWriter: write error \(err), dropping \(droppedBytes) bytes")
            orphanedMarks.forEach { $0(nil) }
            return
        }

        // Chunks whose last byte is in the pipe now.
        var reachedMarks: [(mark: TerminalWriteMark, offset: TerminalPipeOffset)] = []
        if !marks.isEmpty {
            for entry in marks where entry.end <= writtenToFd {
                reachedMarks.append((entry.mark, TerminalPipeOffset(pipe: pipeGeneration, end: entry.end)))
            }
            marks.removeAll { $0.end <= writtenToFd }
        }

        if headIndex == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex > 64 && headIndex > chunks.count / 2 {
            chunks.removeFirst(headIndex)
            headIndex = 0
        }

        if pendingByteCount == 0 {
            if !isSuspended {
                isSuspended = true
                source.suspend()
            }
            callbacksToRun = drainCallbacks
            drainCallbacks.removeAll(keepingCapacity: true)
            droppedToReport = droppedSinceLastDrain
            droppedSinceLastDrain = 0
            didLogOverflow = false
            overflowHandler = onOverflow
        }

        os_unfair_lock_unlock(&bufferLock)
        for reached in reachedMarks {
            reached.mark(reached.offset)
        }
        if droppedToReport > 0 {
            overflowHandler?(droppedToReport)
        }
        for callback in callbacksToRun {
            callback()
        }
    }

    func cancel() {
        os_unfair_lock_lock(&bufferLock)
        let orphanedMarks = marks.map(\.mark)
        marks.removeAll()
        wholeEnd = 0
        tailIsSealed = false
        if let source = writeSource {
            if isSuspended {
                source.resume()
            }
            source.cancel()
            writeSource = nil
            isSuspended = true
        }
        chunks.removeAll(keepingCapacity: false)
        headIndex = 0
        headOffset = 0
        pendingByteCount = 0
        drainCallbacks.removeAll(keepingCapacity: false)
        droppedSinceLastDrain = 0
        didLogOverflow = false
        fd = -1
        pipeGeneration &+= 1
        os_unfair_lock_unlock(&bufferLock)
        orphanedMarks.forEach { $0(nil) }
    }

    /// Install the overflow callback: fired with the total bytes dropped since
    /// the previous drain, once the buffer next drains empty (so a recovery
    /// like a tmux -CC reset runs after congestion clears, not into it).
    /// Invoked on the writer's queue, outside the lock.
    func setOverflowHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        os_unfair_lock_lock(&bufferLock)
        onOverflow = handler
        os_unfair_lock_unlock(&bufferLock)
    }

    /// Byte offsets in the current pipe, comparable with
    /// `ghostty_surface_parsed_bytes` of the surface that reads it.
    struct PipePosition {
        /// Identifies the pipe; see `pipeGeneration`.
        let pipe: UInt64
        /// Bytes written to the fd so far.
        let written: UInt64
    }

    var pipePosition: PipePosition {
        os_unfair_lock_lock(&bufferLock)
        let position = PipePosition(pipe: pipeGeneration, written: writtenToFd)
        os_unfair_lock_unlock(&bufferLock)
        return position
    }

    var pendingBytes: Int {
        os_unfair_lock_lock(&bufferLock)
        let count = pendingByteCount
        os_unfair_lock_unlock(&bufferLock)
        return count
    }

    var debugCounters: (pending: Int, totalWritten: Int, totalDropped: Int) {
        os_unfair_lock_lock(&bufferLock)
        let out = (pending: pendingByteCount, totalWritten: totalWritten, totalDropped: totalDropped)
        os_unfair_lock_unlock(&bufferLock)
        return out
    }
}
