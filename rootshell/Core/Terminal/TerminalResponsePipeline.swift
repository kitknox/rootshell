import Darwin
import Foundation
import os

@MainActor
protocol TerminalResponsePipelineHost: AnyObject {
    var terminalResponseFd: Int32 { get }
    var terminalResponseReadQueue: DispatchQueue { get }
    var terminalResponseTmuxGatewayOwnerKey: Int { get }
    var terminalResponseHasTmuxController: Bool { get }

    func terminalResponseShouldFilterSizeReports(for session: TerminalSession) -> Bool
}

/// Owns Ghostty response-pipe monitoring for a terminal session.
///
/// The response pipe carries terminal replies and paste data from Ghostty back
/// to the active session. Keeping this source outside `TerminalView` makes the
/// byte path cancellable and testable as session lifecycle state, not view
/// state.
@MainActor
final class TerminalResponsePipeline {
    private weak var host: TerminalResponsePipelineHost?

    private var responseReadSource: DispatchSourceRead?
    private var sizeReportCarryOver = Data()
    private var gatewayReportFilterState: GatewayReportFilterState = .ground
    private let gatewayFastPath = TerminalResponseGatewayFastPath()

    /// Strictly-FIFO handoff from the read queue to the MainActor. The read
    /// handler yields events into this stream and a single MainActor task
    /// consumes them in order. Spawning one unstructured Task per chunk (the
    /// previous design) has no documented FIFO guarantee on the target actor;
    /// a reorder both mis-sequences bytes to the transport (tmux -CC pane
    /// pastes ride this path as send-keys commands) and corrupts the stateful
    /// `gatewayReportFilterState` machine.
    private enum ResponseEvent: Sendable {
        case chunk(Data)
        case end(pendingPaste: Data?)
    }

    private var responseEventContinuation: AsyncStream<ResponseEvent>.Continuation?
    private var responseConsumerTask: Task<Void, Never>?

    init(host: TerminalResponsePipelineHost) {
        self.host = host
    }

    deinit {
        responseReadSource?.cancel()
    }

    func cancel() {
        // Chunks read but not yet dispatched are dropped here. cancel() runs
        // only at teardown or right before adopting a new session, where late
        // delivery to the old/new session would be wrong anyway.
        responseConsumerTask?.cancel()
        responseConsumerTask = nil
        responseEventContinuation?.finish()
        responseEventContinuation = nil
        responseReadSource?.cancel()
        responseReadSource = nil
        sizeReportCarryOver.removeAll(keepingCapacity: true)
        gatewayReportFilterState = .ground
    }

    func resetGatewayReportFilter() {
        gatewayReportFilterState = .ground
        gatewayFastPath.reset()
    }

    /// Call-site contract: every configure/clear transition is paired with a
    /// `resetGatewayReportFilter()` by the caller (TmuxController / TerminalView
    /// teardown), because the fast path and the MainActor dispatch path keep
    /// independent report-filter states. Chunks already in flight on the other
    /// path at the switch instant can interleave — accepted, since transitions
    /// happen only when no pane input is flowing (gateway establish / control
    /// mode end / surface teardown).
    func configureGatewayFastPath(
        fastWrite: (@Sendable (Data) -> Void)?,
        ownerKey: Int
    ) {
        gatewayFastPath.configure(fastWrite: fastWrite, ownerKey: ownerKey)
    }

    func clearGatewayFastPath() {
        gatewayFastPath.clear()
    }

    func start(for session: TerminalSession) {
        guard let host else { return }
        let responseFd = host.terminalResponseFd
        guard responseFd >= 0 else {
            Ghostty.logger.warning("Cannot start response monitoring: responseFd=\(responseFd)")
            return
        }

        cancel()

        Ghostty.logger.info("Starting terminal response monitoring on responseFd=\(responseFd)")

        let source = DispatchSource.makeReadSource(
            fileDescriptor: responseFd,
            queue: host.terminalResponseReadQueue
        )
        responseReadSource = source
        sizeReportCarryOver.removeAll()
        gatewayReportFilterState = .ground

        let coalescer = TerminalResponsePasteCoalescer()
        let gatewayFastPath = self.gatewayFastPath

        // Single ordered consumer: yields from the read queue are FIFO, and
        // one task dispatches them, so chunk order (and the stateful report
        // filter) can never be scrambled by task-scheduling races. The `.end`
        // event rides the same stream, so the EOF/error flush is also
        // guaranteed to run after every pending chunk.
        let (events, continuation) = AsyncStream.makeStream(of: ResponseEvent.self)
        responseEventContinuation = continuation
        responseConsumerTask = Task { @MainActor [weak self, weak session] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .chunk(let data):
                    self.dispatch(data, to: session)
                case .end(let pendingPaste):
                    self.flushAndCancel(pendingPaste: pendingPaste, session: session)
                    return
                }
            }
        }

        source.setEventHandler { [coalescer, gatewayFastPath, continuation] in
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while true {
                let bytesRead = read(responseFd, buffer, bufferSize)

                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    guard let toDispatch = coalescer.accept(chunk: data) else {
                        continue
                    }

                    if gatewayFastPath.dispatchIfConfigured(toDispatch) {
                        continue
                    }

                    continuation.yield(.chunk(toDispatch))
                    continue
                }

                if bytesRead == 0 {
                    Ghostty.logger.info("Response pipe EOF, stopping response monitoring")
                    continuation.yield(.end(pendingPaste: coalescer.flushPending()))
                    continuation.finish()
                    return
                }

                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    return
                }
                if err == EINTR {
                    continue
                }

                let error = String(cString: strerror(err))
                Ghostty.logger.error("Error reading from response pipe: \(error) (errno=\(err))")
                continuation.yield(.end(pendingPaste: coalescer.flushPending()))
                continuation.finish()
                return
            }
        }

        source.setCancelHandler {
            Ghostty.logger.info("Terminal response monitoring stopped")
        }

        source.resume()
    }

    private func dispatch(_ data: Data, to session: TerminalSession?) {
        guard let session else { return }
        guard let host else { return }
        let data = (session as? HerdrPaneSession)?.consumeParserGridReports(data) ?? data
        guard !data.isEmpty else { return }

        if host.terminalResponseHasTmuxController {
            let filtered = Self.stripTerminalReports(
                from: data,
                state: &gatewayReportFilterState
            )
            let ownerKey = host.terminalResponseTmuxGatewayOwnerKey
            if ownerKey != 0 {
                TmuxDebugLogger.shared.noteGatewayBytes(
                    owner: ownerKey,
                    raw: data.count,
                    filtered: filtered.count
                )
            }
            if !filtered.isEmpty { session.sendInput(filtered) }
            return
        }

        if host.terminalResponseShouldFilterSizeReports(for: session) {
            guard let filtered = Self.filterSizeReports(
                from: data,
                carryOver: &sizeReportCarryOver
            ) else {
                return
            }
            session.sendInput(filtered)
        } else {
            sizeReportCarryOver.removeAll(keepingCapacity: true)
            session.sendInput(data)
        }
    }

    private func flushAndCancel(pendingPaste: Data?, session: TerminalSession?) {
        if let pendingPaste, let session {
            session.sendInput(pendingPaste)
        }
        if let session, !sizeReportCarryOver.isEmpty {
            let remaining = sizeReportCarryOver
            sizeReportCarryOver.removeAll()
            session.sendInput(remaining)
        }
        cancel()
    }

    enum GatewayReportFilterState {
        case ground
        case esc
        case csi
        case str
        case strEsc
    }

    nonisolated static func stripTerminalReports(
        from data: Data,
        state: inout GatewayReportFilterState
    ) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        for b in data {
            switch state {
            case .ground:
                if b == 0x1B { state = .esc } else { out.append(b) }
            case .esc:
                if b == 0x5B {
                    state = .csi
                } else if b == 0x5D || b == 0x50 || b == 0x58 || b == 0x5E || b == 0x5F {
                    state = .str
                } else {
                    state = .ground
                }
            case .csi:
                if b >= 0x40 && b <= 0x7E { state = .ground }
            case .str:
                if b == 0x07 { state = .ground }
                else if b == 0x1B { state = .strEsc }
            case .strEsc:
                state = .ground
            }
        }
        return out
    }

    nonisolated static func filterSizeReports(
        from data: Data,
        carryOver: inout Data
    ) -> Data? {
        let sizeReportParams: Set<Int> = [4, 6, 8, 48]

        var input: Data
        if carryOver.isEmpty {
            input = data
        } else {
            input = carryOver
            input.append(data)
            carryOver.removeAll(keepingCapacity: true)
        }

        return input.withUnsafeBytes { rawBuffer -> Data? in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let count = rawBuffer.count

            var result = Data()
            result.reserveCapacity(count)
            var i = 0

            while i < count {
                if bytes[i] == 0x1B {
                    if i + 1 >= count {
                        carryOver.append(bytes[i])
                        i += 1
                        continue
                    }
                    if bytes[i + 1] == 0x5B {
                        let seqStart = i
                        i += 2

                        var firstParam = 0
                        var parsingFirstParam = true

                        while i < count && bytes[i] >= 0x30 && bytes[i] <= 0x3F {
                            if parsingFirstParam {
                                if bytes[i] >= 0x30 && bytes[i] <= 0x39 {
                                    firstParam = firstParam * 10 + Int(bytes[i] - 0x30)
                                } else {
                                    parsingFirstParam = false
                                }
                            }
                            i += 1
                        }

                        if i >= count {
                            carryOver.append(Data(bytes: bytes + seqStart, count: count - seqStart))
                            break
                        }

                        if bytes[i] >= 0x40 && bytes[i] <= 0x7E {
                            let finalByte = bytes[i]
                            i += 1

                            if finalByte == 0x74 && sizeReportParams.contains(firstParam) {
                                continue
                            }

                            result.append(bytes + seqStart, count: i - seqStart)
                        } else {
                            result.append(bytes + seqStart, count: i - seqStart)
                        }
                    } else {
                        result.append(bytes[i])
                        i += 1
                    }
                } else {
                    result.append(bytes[i])
                    i += 1
                }
            }

            return result.isEmpty ? nil : result
        }
    }
}

private final class TerminalResponseGatewayFastPath: @unchecked Sendable {
    private let lock = NSLock()
    private var fastWrite: (@Sendable (Data) -> Void)?
    private var ownerKey = 0
    private var filterState: TerminalResponsePipeline.GatewayReportFilterState = .ground

    func configure(fastWrite: (@Sendable (Data) -> Void)?, ownerKey: Int) {
        lock.lock()
        self.fastWrite = fastWrite
        self.ownerKey = ownerKey
        self.filterState = .ground
        lock.unlock()
    }

    func clear() {
        lock.lock()
        fastWrite = nil
        ownerKey = 0
        filterState = .ground
        lock.unlock()
    }

    func reset() {
        lock.lock()
        filterState = .ground
        lock.unlock()
    }

    func dispatchIfConfigured(_ data: Data) -> Bool {
        lock.lock()
        guard let fastWrite else {
            lock.unlock()
            return false
        }

        let filtered = TerminalResponsePipeline.stripTerminalReports(
            from: data,
            state: &filterState
        )
        let ownerKey = self.ownerKey
        lock.unlock()

        if ownerKey != 0 {
            TmuxDebugLogger.shared.noteGatewayBytes(
                owner: ownerKey,
                raw: data.count,
                filtered: filtered.count
            )
        }
        if !filtered.isEmpty {
            fastWrite(filtered)
        }
        return true
    }
}

/// Re-joins a bracketed paste (`\e[200~...\e[201~`) across pipe reads.
private final class TerminalResponsePasteCoalescer: @unchecked Sendable {
    private var buffer = Data()
    private var inProgress = false

    private static let maxBufferBytes = 4 * 1024 * 1024
    private static let startMarker = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    private static let endMarker = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])

    func accept(chunk: Data) -> Data? {
        if inProgress {
            buffer.append(chunk)
            if buffer.range(of: Self.endMarker) != nil {
                let complete = buffer
                buffer = Data()
                inProgress = false
                return complete
            }
            if buffer.count > Self.maxBufferBytes {
                let salvage = buffer
                buffer = Data()
                inProgress = false
                return salvage
            }
            return nil
        }

        if chunk.range(of: Self.startMarker) != nil && chunk.range(of: Self.endMarker) == nil {
            buffer = chunk
            inProgress = true
            return nil
        }

        return chunk
    }

    func flushPending() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let pending = buffer
        buffer = Data()
        inProgress = false
        return pending
    }
}
