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
            inputDebounceMs: envInt("GHOSTTY_OUTPUT_COALESCE_INPUT_DEBOUNCE_MS") ?? 120,
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
    var protocolObserver: TerminalProtocolObserver?

    let bufferedWriter: TerminalBufferedPipeWriter
    let scrollbackRestoreOutputGate = TerminalScrollbackRestoreOutputGate()

    private lazy var outputCoalescer: TerminalOutputCoalescer = {
        TerminalOutputCoalescer(
            minBatchIntervalMs: config.minBatchIntervalMs,
            maxBatchIntervalMs: config.maxBatchIntervalMs,
            debug: config.debug,
            write: { [scrollbackRestoreOutputGate, bufferedWriter] data in
                scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter)
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

    func writeSessionOutput(_ data: Data) {
        urlRequestObserver?.consume(data)
        if let protocolObserver {
            protocolObserver.write(data) { [scrollbackRestoreOutputGate, bufferedWriter] in scrollbackRestoreOutputGate.writeOrBuffer($0, to: bufferedWriter) }
        } else { scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter) }
    }

    func enqueueCoalescedOutput(_ data: Data) {
        urlRequestObserver?.consume(data)
        if let protocolObserver { protocolObserver.write(data) { [outputCoalescer] in outputCoalescer.enqueue($0) } }
        else { outputCoalescer.enqueue(data) }
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
        observeProtocol: Bool = true,
        terminalUUID: UUID,
        noteGatewayInboundBytes: @escaping @Sendable (Int) -> Void
    ) -> @Sendable (Data) -> Void {
        let outputCoalescer: TerminalOutputCoalescer? = useOutputCoalescer ? self.outputCoalescer : nil
        let bufferedWriter = self.bufferedWriter
        let scrollbackRestoreOutputGate = self.scrollbackRestoreOutputGate
        let persistenceNotifyPending = OSAllocatedUnfairLock<Bool>(initialState: false)
        let protocolObserver = observeProtocol ? self.protocolObserver : nil
        // One fresh parser per adopted session. Saved scrollback and local
        // redraws use writeDirect and cannot replay a browser request.
        let urlObserver = onURLRequest.map { TerminalURLRequestObserver(onURL: $0) }

        let writeDirect: @Sendable (Data) -> Void = { data in
            scrollbackRestoreOutputGate.writeOrBuffer(data, to: bufferedWriter)
        }

        return { data in
            noteGatewayInboundBytes(data.count)
            urlObserver?.consume(data)

            let enqueue: (Data) -> Void = { bytes in
                if let outputCoalescer { outputCoalescer.enqueue(bytes) }
                else { writeDirect(bytes) }
            }
            if let protocolObserver { protocolObserver.write(data, enqueue: enqueue) }
            else { enqueue(data) }

            guard !Ghostty.isAppBackgroundedAtomic else { return }

            let shouldSpawn = persistenceNotifyPending.withLock { pending -> Bool in
                guard !pending else { return false }
                pending = true
                return true
            }
            guard shouldSpawn else { return }

            Task { @MainActor in
                persistenceNotifyPending.withLock { $0 = false }
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
    private let write: @Sendable (Data) -> Void
    private var pending = Data()
    private var timer: DispatchSourceTimer?
    private var firstEnqueueTime: DispatchTime?
    private var currentDeadline: DispatchTime?
    private var enabledForFastPath = false
    private var disableFlushInProgress = false
    private var transitionGeneration: UInt64 = 0
    private var fastPathLock = os_unfair_lock()
    private var isEnabled = false

    init(minBatchIntervalMs: Int, maxBatchIntervalMs: Int, debug: Bool, write: @escaping @Sendable (Data) -> Void) {
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
            disableFlushInProgress = true
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

    func enqueue(_ data: Data) {
        os_unfair_lock_lock(&fastPathLock)
        let enabled = enabledForFastPath
        let disablePending = disableFlushInProgress
        os_unfair_lock_unlock(&fastPathLock)

        if !enabled && !disablePending {
            if debug {
                let byteCount = data.count
                Ghostty.logger.debug("OutputCoalescer direct bypass: \(byteCount) bytes")
            }
            write(data)
            return
        }

        queue.async {
            if !self.isEnabled {
                self.write(data)
                return
            }

            self.pending.append(data)
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
            return
        }

        let output = pending
        pending.removeAll(keepingCapacity: true)
        cancelTimerLocked()
        firstEnqueueTime = nil
        write(output)
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

    func writeOrBuffer(_ data: Data, to writer: TerminalBufferedPipeWriter) {
        guard !data.isEmpty else { return }

        let result = state.withLock { state -> (shouldWrite: Bool, shouldLogOverflow: Bool) in
            guard state.isEnabled else {
                return (shouldWrite: true, shouldLogOverflow: false)
            }

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

            return (shouldWrite: false, shouldLogOverflow: shouldLogOverflow)
        }

        if result.shouldWrite {
            writer.write(data)
        }
        if result.shouldLogOverflow {
            Ghostty.logger.warning("ScrollbackRestoreOutputGate exceeded 10MB; dropping oldest buffered live output")
        }
    }

    func finish(to writer: TerminalBufferedPipeWriter) {
        state.withLock { state in
            guard state.isEnabled else { return }
            for chunk in state.chunks {
                writer.write(chunk)
            }
            state.chunks.removeAll(keepingCapacity: false)
            state.bufferedByteCount = 0
            state.isEnabled = false
            state.didLogOverflow = false
        }
    }

    func cancel() {
        let shouldLogDrop = state.withLock { state -> Bool in
            guard state.isEnabled else { return false }
            state.isEnabled = false
            state.didLogOverflow = false
            let droppedBytes = state.bufferedByteCount
            state.chunks.removeAll(keepingCapacity: false)
            state.bufferedByteCount = 0
            return droppedBytes > 0
        }

        if shouldLogDrop {
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
        os_unfair_lock_lock(&bufferLock)

        if let source = writeSource {
            if isSuspended {
                source.resume()
            }
            source.cancel()
            writeSource = nil
            isSuspended = true
        }

        self.fd = fd

        // New fd generation: any pending-loss accounting belongs to the
        // previous surface. Reset it so a stale overflow report can't fire
        // (and trigger a spurious tmux reset) after the new surface drains.
        droppedSinceLastDrain = 0
        didLogOverflow = false

        guard fd >= 0 else {
            os_unfair_lock_unlock(&bufferLock)
            return
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

    func write(_ data: Data) {
        guard !data.isEmpty else { return }

        let maxBufferedBytes = Self.maxBufferedBytes()
        let overflowLowWaterBytes = maxBufferedBytes / 2

        os_unfair_lock_lock(&bufferLock)

        guard fd >= 0, let source = writeSource else {
            os_unfair_lock_unlock(&bufferLock)
            Ghostty.logger.warning("BufferedPipeWriter: no FD configured, dropping \(data.count) bytes")
            return
        }

        let combinedSize = pendingByteCount + data.count
        var overflowToLog = 0

        if combinedSize > maxBufferedBytes {
            // Enforce the cap BEFORE storing so the pending bytes never
            // materialize above it. Drop exactly the bytes needed to reach
            // the low-water mark from the oldest end of the logical (queue +
            // incoming) stream: whole chunks while they fit within the
            // excess, then an owned copy of the straddling chunk's remainder
            // (a suffix slice would pin the full chunk), trimming the
            // incoming chunk itself if it alone exceeds the mark (e.g. a
            // full scrollback restore passed as one Data).
            var incoming = data
            var dropped = 0
            while pendingByteCount + incoming.count > overflowLowWaterBytes,
                  headIndex < chunks.count {
                let chunk = chunks[headIndex]
                let remainder = chunk.count - headOffset
                let excess = pendingByteCount + incoming.count - overflowLowWaterBytes
                if remainder <= excess {
                    chunks[headIndex] = Data()
                    headIndex += 1
                    headOffset = 0
                    pendingByteCount -= remainder
                    dropped += remainder
                    continue
                }
                chunks[headIndex] = TerminalOutputChunkTuning.ownedSuffix(
                    of: chunk, count: remainder - excess)
                headOffset = 0
                pendingByteCount -= excess
                dropped += excess
                break
            }
            if incoming.count > overflowLowWaterBytes {
                dropped += incoming.count - overflowLowWaterBytes
                incoming = TerminalOutputChunkTuning.ownedSuffix(
                    of: incoming, count: overflowLowWaterBytes)
            }
            if headIndex == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                headIndex = 0
            }
            chunks.insert(Self.stringTerminator, at: headIndex)
            pendingByteCount += Self.stringTerminator.count
            appendChunkLocked(incoming)
            totalDropped &+= dropped
            droppedSinceLastDrain &+= dropped
            if !didLogOverflow {
                didLogOverflow = true
                overflowToLog = dropped
            }
        } else {
            appendChunkLocked(data)
            if combinedSize > Self.bufferWarningThreshold && combinedSize - data.count <= Self.bufferWarningThreshold {
                Ghostty.logger.warning("BufferedPipeWriter: buffer exceeded 1MB (\(combinedSize) bytes)")
            }
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
        if data.count < TerminalOutputChunkTuning.smallChunkBytes,
           chunks.count > headIndex,
           chunks[chunks.count - 1].count < TerminalOutputChunkTuning.coalescedChunkLimitBytes {
            chunks[chunks.count - 1].append(data)
        } else {
            chunks.append(data)
        }
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
                pendingByteCount -= bytesWritten
                continue
            }
            if bytesWritten > 0 {
                headOffset += bytesWritten
                totalWritten &+= bytesWritten
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
            if !isSuspended {
                isSuspended = true
                source.suspend()
            }
            os_unfair_lock_unlock(&bufferLock)
            Ghostty.logger.error("BufferedPipeWriter: write error \(err), dropping \(droppedBytes) bytes")
            return
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
        if droppedToReport > 0 {
            overflowHandler?(droppedToReport)
        }
        for callback in callbacksToRun {
            callback()
        }
    }

    func cancel() {
        os_unfair_lock_lock(&bufferLock)
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
        os_unfair_lock_unlock(&bufferLock)
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
