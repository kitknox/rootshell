import Foundation
import os

/// Output delivery is revoked synchronously on close, including when a read
/// that was already in flight completes after the pane has been replaced.
nonisolated final class HerdrLegacyOutput: @unchecked Sendable {
    private let sink: OutputSink
    private let closed = OSAllocatedUnfairLock(initialState: false)
    init(sink: OutputSink) { self.sink = sink }
    func emit(_ data: Data) {
        closed.withLock { if !$0 { sink.emit(data) } }
    }
    func close() { closed.withLock { $0 = true } }
}

/// The stock attach client ends terminal setup with DisableLineWrap. Before
/// that point, retain only bounded diagnostics to distinguish unsupported
/// direct attach from a dropped connection. Never inspect application output
/// for errors after setup completed.
nonisolated struct HerdrAttachStartup {
    private var bytes = Data()
    private(set) var ready = false
    mutating func observe(_ data: Data) {
        guard !ready else { return }
        bytes.append(data.prefix(8192))
        if bytes.range(of: Data("\u{1b}[?7l".utf8)) != nil {
            ready = true
            bytes.removeAll()
        } else if bytes.count > 8192 {
            bytes = Data(bytes.suffix(8192))
        }
    }
    var unsupported: Bool {
        !ready && String(decoding: bytes, as: UTF8.self)
            .contains("direct terminal attach is not supported")
    }
    var diagnostic: String {
        String(decoding: bytes, as: UTF8.self)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().suffix(400).description
    }
}

/// Keep the previous screen visible until the attach client's first complete
/// synchronized frame arrives. Startup alone enters/clears the alternate screen
/// and would otherwise expose a blank frame during reconnect.
nonisolated struct HerdrAttachPresentation {
    private var pending: Data? = Data()
    mutating func receive(_ data: Data) throws -> Data? {
        guard var initial = pending else { return data }
        guard initial.count + data.count <= HerdrPTYOutputBuffer.maxBufferedBytes else { throw HerdrPTYError.overflow }
        initial.append(data)
        guard initial.range(of: Data("\u{1b}[?2026l".utf8)) != nil else {
            pending = initial
            return nil
        }
        pending = nil
        // Avoid RIS: it breaks synchronized output and visibly clears the old
        // screen. The stock client establishes keyboard, mouse and paste modes.
        var frame = Data("\u{1b}[?2026h\u{1b}[?6l\u{1b}[r\u{1b}[0m".utf8)
        frame.append(initial)
        return frame
    }
}

@MainActor
final class HerdrLegacyPaneStream {
    let terminalId: String
    let paneId: String
    private let pipe: AsyncBytePipe
    private let pty: HerdrPTYChannel?
    private let delivery: HerdrLegacyOutput
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var encoder = HerdrAttachInputEncoder()
    private(set) var closed = false
    var onClosed: ((Error?) -> Void)?

    private enum Write {
        case bytes(Data)
        case resize(cols: Int, rows: Int)
        var byteCount: Int { if case .bytes(let data) = self { return data.count }; return 0 }
    }
    private var writes: [Write] = []
    private var queuedBytes = 0

    init(terminalId: String, paneId: String, pipe: AsyncBytePipe, sink: OutputSink) {
        self.terminalId = terminalId
        self.paneId = paneId
        self.pipe = pipe
        self.pty = pipe as? HerdrPTYChannel
        self.delivery = HerdrLegacyOutput(sink: sink)
    }

    func start() {
        guard !closed, readerTask == nil else { return }
        let pipe = self.pipe
        let delivery = self.delivery
        let isPTY = pty != nil
        readerTask = Task.detached { [weak self] in
            var startup = HerdrAttachStartup()
            var presentation = HerdrAttachPresentation()
            var json = Data()
            var failure: Error?
            do {
                readLoop: while !Task.isCancelled {
                    guard let chunk = try await pipe.read(maxBytes: 64 * 1024) else { break }
                    if Task.isCancelled { break }
                    if isPTY {
                        startup.observe(chunk)
                        if let frame = try presentation.receive(chunk) { delivery.emit(frame) }
                    } else {
                        json.append(chunk)
                        guard json.count <= HerdrPTYOutputBuffer.maxBufferedBytes else { throw HerdrPTYError.overflow }
                        while let newline = json.firstIndex(of: 0x0a) {
                            let line = json.subdata(in: json.startIndex..<newline)
                            json.removeSubrange(json.startIndex...newline)
                            guard let frame = try? JSONDecoder().decode(Frame.self, from: line) else { continue }
                            if frame.type == "terminal.closed" { break readLoop }
                            guard frame.type == "terminal.frame", let encoded = frame.bytes,
                                  let bytes = Data(base64Encoded: encoded) else { continue }
                            var out = Data("\u{1b}[?2026h".utf8)
                            if frame.full == true { out.append(contentsOf: "\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8) }
                            out.append(bytes)
                            out.append(contentsOf: "\u{1b}[?2026l".utf8)
                            delivery.emit(out)
                        }
                    }
                }
            } catch { failure = error }
            if isPTY && !startup.ready {
                if startup.unsupported || failure.map(HerdrPTYError.isRequestRejection) == true {
                    failure = HerdrPTYError.unavailable("herdr direct attach or PTY is unavailable on this host")
                } else if !startup.diagnostic.isEmpty {
                    failure = HerdrPTYError.failed("herdr attach failed: \(startup.diagnostic)")
                }
            }
            await self?.readerDidEnd(error: failure)
        }
    }

    private nonisolated struct Frame: Decodable {
        let type: String
        let full: Bool?
        let bytes: String?
    }

    private func readerDidEnd(error: Error?) {
        guard !closed else { return }
        close()
        onClosed?(error)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0a)
        enqueue(.bytes(line))
    }

    func sendInput(_ data: Data) {
        guard !closed else { return }
        if pty != nil { enqueue(.bytes(encoder.encode(data))) }
        else { sendJSON(["type": "terminal.input", "bytes": data.base64EncodedString()]) }
    }

    func sendScroll(steps: Int, column: Int, row: Int) {
        guard !closed, steps != 0 else { return }
        if pty != nil {
            sendInput(HerdrFallbackScroll.wheel(steps: steps, column: column, row: row))
        } else {
            sendJSON(["type": "terminal.scroll", "direction": steps > 0 ? "up" : "down",
                      "lines": abs(min(32, max(-32, steps))) * 3, "column": column, "row": row])
        }
    }

    func resize(cols: Int, rows: Int) {
        if pty != nil { enqueue(.resize(cols: cols, rows: rows)) }
        else { sendJSON(["type": "terminal.resize", "cols": cols, "rows": rows]) }
    }

    private func enqueue(_ write: Write) {
        guard !closed else { return }
        guard queuedBytes + write.byteCount <= HerdrPTYOutputBuffer.maxBufferedBytes else {
            readerDidEnd(error: HerdrPTYError.failed("herdr pane input queue is full"))
            return
        }
        if case .resize = write, let last = writes.last, case .resize = last {
            writes[writes.count - 1] = write
        } else { writes.append(write) }
        queuedBytes += write.byteCount
        guard writerTask == nil else { return }
        writerTask = Task { [weak self] in
            guard let self else { return }
            defer { self.writerTask = nil }
            while !self.closed, !self.writes.isEmpty {
                let next = self.writes.removeFirst()
                do {
                    switch next {
                    case .bytes(let data): try await self.pipe.write(data)
                    case .resize(let cols, let rows): try await self.pty?.resize(cols: cols, rows: rows)
                    }
                    if !self.closed { self.queuedBytes -= next.byteCount }
                } catch {
                    self.readerDidEnd(error: error)
                    return
                }
            }
        }
    }

    @discardableResult
    func close() -> Task<Void, Never> {
        if let closeTask { return closeTask }
        closed = true
        delivery.close()
        readerTask?.cancel()
        writerTask?.cancel()
        writes.removeAll()
        queuedBytes = 0
        let pipe = self.pipe
        // Closing stdin makes the JSON CLI detach too. Do not queue a release
        // behind a blocked write; close must be able to unblock both directions.
        let task = Task { await pipe.close() }
        closeTask = task
        return task
    }
}
