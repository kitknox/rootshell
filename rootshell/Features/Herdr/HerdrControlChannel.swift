//
//  HerdrControlChannel.swift
//  rootshell
//
//  One herdr control stream over a byte pipe: frames newline JSON, matches
//  responses to requests by id, and hands every pushed record or event to
//  the owner in arrival order. Runs off the main actor; the owner receives
//  decoded values on whatever executor it chooses.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

nonisolated enum HerdrChannelError: Error, LocalizedError {
    case closed
    case timedOut(method: String)
    case remote(code: String, message: String)
    case malformed(String)
    case unsupportedServer(String)
    /// No herdr binary on the host's PATH.
    case herdrMissing(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "The herdr control stream is closed"
        case .timedOut(let method): return "herdr did not answer \(method) in time"
        case .remote(let code, let message): return "herdr \(code): \(message)"
        case .malformed(let what): return "Unexpected herdr message: \(what)"
        case .unsupportedServer(let why): return why
        case .herdrMissing(let why): return why
        }
    }
}

actor HerdrControlChannel {

    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "HerdrControlChannel")

    /// Upper bound on one inbound line; output records are base64 so a
    /// megabyte of terminal bytes is ~1.4 MB on the wire.
    private static let maxLineBytes = 16 * 1024 * 1024
    private static let defaultTimeout: Duration = .seconds(15)

    private let pipe: AsyncBytePipe
    private let onInbound: @Sendable (HerdrControl.Inbound) async -> Void
    private let onClosed: @Sendable (Error?) -> Void

    private var nextRequestId: UInt64 = 1
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var readerTask: Task<Void, Never>?

    private enum Write: Sendable {
        case input(attachId: String, bytes: Data, auto: Bool?)
        case line(Data)
    }

    private let writes: OSAllocatedUnfairLock<AsyncStream<Write>.Continuation?>
    private var writeStream: AsyncStream<Write>?
    private var acceptingWrites: Bool { writes.withLock { $0 != nil } }
    private var writerTask: Task<Void, Never>?
    private var gracefulCloseTask: Task<Void, Never>?
    private var pipeCloseTask: Task<Void, Never>?

    /// Facts from `control.open`, set once the stream is up.
    private(set) var opened: HerdrControl.ControlOpened?

    init(
        pipe: AsyncBytePipe,
        onInbound: @escaping @Sendable (HerdrControl.Inbound) async -> Void,
        onClosed: @escaping @Sendable (Error?) -> Void
    ) {
        self.pipe = pipe
        self.onInbound = onInbound
        self.onClosed = onClosed
        let (stream, continuation) = AsyncStream.makeStream(of: Write.self)
        self.writeStream = stream
        self.writes = OSAllocatedUnfairLock(initialState: continuation)
    }

    // MARK: - Lifecycle

    /// Reads the `control.open` line the bridge prints first, checks the
    /// stream protocol, and starts the reader.
    func open() async throws -> HerdrControl.ControlOpened {
        var framer = NewlineFramer()
        let firstLine = try await readLine(into: &framer)
        guard let firstLine else { throw HerdrChannelError.closed }
        // Anything but JSON here is a stray shell or usage message from a
        // herdr that does not know the subcommand.
        guard let head = try? HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: firstLine) else {
            let text = String(decoding: firstLine.prefix(200), as: UTF8.self)
            throw HerdrChannelError.unsupportedServer("unexpected herdr control output: \(text)")
        }
        if let error = head.error {
            // A fork client talking to an older server: the server itself
            // rejected control.open.
            throw HerdrChannelError.unsupportedServer("herdr \(error.code): \(error.message)")
        }
        // The launch wrapper reports a missing binary or an unknown
        // subcommand as a control error line.
        if head.type == "control.error" {
            struct ControlErrorLine: Decodable {
                let code: String?
                let message: String?
            }
            let line = try? HerdrControl.decoder.decode(ControlErrorLine.self, from: firstLine)
            let message = line?.message ?? "herdr control stream unavailable"
            if line?.code == "not_found" {
                throw HerdrChannelError.herdrMissing(message)
            }
            throw HerdrChannelError.unsupportedServer(message)
        }
        let response = try HerdrControl.decoder.decode(
            HerdrControl.Response<HerdrControl.ControlOpened>.self,
            from: firstLine
        )
        let opened = response.result
        let stream = opened.capabilities?.terminal_control_stream ?? 0
        guard stream >= HerdrControl.requiredStreamProtocol else {
            throw HerdrChannelError.unsupportedServer(
                "herdr \(opened.version) has no control stream support"
            )
        }
        guard acceptingWrites else { throw HerdrChannelError.closed }
        self.opened = opened
        startWriter()
        startReader(framer: framer)
        return opened
    }

    func close() async {
        if let closing = gracefulCloseTask ?? pipeCloseTask {
            await closing.value
            return
        }
        finishWrites()
        failPending(HerdrChannelError.closed)
        // Give the current line exclusive use of the pipe until its last byte.
        // The writer skips its backlog once close starts.
        let closing = Task {
            await writerTask?.value
            if pipeCloseTask == nil {
                let line = #"{"id":"control:close","method":"control.close","params":{}}"# + "\n"
                try? await pipe.write(Data(line.utf8))
            }
            await startPipeClose().value
        }
        gracefulCloseTask = closing
        await closing.value
    }

    /// Close without the courtesy write: used when the stream is presumed
    /// dead, where a blocked writer would stall recovery.
    func abort() async {
        await abort(error: nil, notifyOwner: false)
    }

    private func abort(error: Error?, notifyOwner: Bool) async {
        if acceptingWrites {
            finishWrites()
            failPending(error ?? HerdrChannelError.closed)
            if notifyOwner { onClosed(error) }
        }
        // EOF or a forced abort must wake even a gracefully closing writer.
        writerTask?.cancel()
        await startPipeClose().value
    }

    private func startPipeClose() -> Task<Void, Never> {
        if let pipeCloseTask { return pipeCloseTask }
        readerTask?.cancel()
        let closing = Task { [pipe] in await pipe.close() }
        pipeCloseTask = closing
        return closing
    }

    private func finishWrites() {
        writes.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
        writeStream = nil
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Requests

    /// Sends a request and returns the raw JSON of its result object.
    @discardableResult
    func request<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration = HerdrControlChannel.defaultTimeout
    ) async throws -> Data {
        guard acceptingWrites else { throw HerdrChannelError.closed }
        let id = "r\(nextRequestId)"
        nextRequestId += 1
        let encoded = try JSONEncoder().encode(HerdrControl.Request(id: id, method: method, params: params))
        var line = encoded
        line.append(0x0A)

        // Register the continuation before handing the line to the writer. A fast
        // reply could otherwise land in `dispatch` with nothing to match.
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            writes.withLock { $0 }?.yield(.line(line))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOut(id: id, method: method)
            }
        }
        let head = try HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: response)
        if let error = head.error {
            throw HerdrChannelError.remote(code: error.code, message: error.message)
        }
        return response
    }

    /// Typed convenience over `request`.
    func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as: R.Type,
        timeout: Duration = HerdrControlChannel.defaultTimeout
    ) async throws -> R {
        let response = try await request(method, params, timeout: timeout)
        do {
            return try HerdrControl.decoder.decode(HerdrControl.Response<R>.self, from: response).result
        } catch let error as HerdrVersionError {
            throw error
        } catch {
            throw HerdrChannelError.malformed("\(method) result: \(error)")
        }
    }

    /// Publish in the caller's order before it returns to the UI run loop.
    nonisolated func sendInput(attachId: String, bytes: Data, auto: Bool? = nil) {
        writes.withLock { $0 }?.yield(.input(attachId: attachId, bytes: bytes, auto: auto))
    }

    /// A single consumer keeps writes FIFO even when a transport suspends.
    /// Encoding a paste and writing input can proceed while the reader
    /// decodes a large snapshot or waits for a layout change.
    private func startWriter() {
        guard let stream = writeStream else { return }
        writeStream = nil
        writerTask = Task.detached(priority: .userInitiated) { [weak self, stream, pipe, writes] in
            var inputID: UInt64 = 0
            do {
                for await write in stream {
                    guard writes.withLock({ $0 != nil }) else { return }
                    let line: Data
                    switch write {
                    case .input(let attachId, let bytes, let auto):
                        inputID += 1
                        let params = HerdrControl.InputParams(
                            attach_id: attachId, bytes: bytes.base64EncodedString(), auto: auto
                        )
                        let request = HerdrControl.Request(id: "i\(inputID)", method: "terminal.input", params: params)
                        var encoded = try JSONEncoder().encode(request)
                        encoded.append(0x0A)
                        line = encoded
                    case .line(let encoded):
                        line = encoded
                    }
                    // Closing may have begun while encoding a large paste.
                    guard writes.withLock({ $0 != nil }) else { return }
                    try await pipe.write(line)
                }
            } catch {
                await self?.abort(error: error, notifyOwner: true)
            }
        }
    }

    private func timeOut(id: String, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: HerdrChannelError.timedOut(method: method))
    }

    // MARK: - Reader

    private func startReader(framer: NewlineFramer) {
        readerTask = Task { [weak self] in
            guard let self else { return }
            var framer = framer
            var failure: Error?
            do {
                while !Task.isCancelled {
                    guard let line = try await self.readLine(into: &framer) else { break }
                    await self.dispatch(line)
                }
            } catch {
                failure = error
            }
            await self.abort(error: failure, notifyOwner: true)
        }
    }

    private func dispatch(_ line: Data) async {
        let head = try? HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: line)
        if let head, let id = head.id, head.type == nil, head.event == nil {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: line)
            } else if id.hasPrefix("i"), let error = head.error {
                Self.logger.warning("herdr input rejected: \(error.code) \(error.message)")
            }
            return
        }
        // A takeover detach is per pane: attaches never take ownership back
        // on their own, so the stream stays up for the other panes.
        if let inbound = HerdrControl.decodeInbound(line, head: head) {
            await onInbound(inbound)
        }
    }

    /// Reads one newline-terminated line, keeping partial data in `framer`.
    /// Returns nil on clean EOF.
    private func readLine(into framer: inout NewlineFramer) async throws -> Data? {
        while true {
            if let line = framer.nextLine() {
                return line
            }
            if framer.bufferedCount > Self.maxLineBytes {
                throw HerdrChannelError.malformed("line exceeds \(Self.maxLineBytes) bytes")
            }
            guard let chunk = try await pipe.read(maxBytes: 256 * 1024) else {
                return nil
            }
            framer.append(chunk)
        }
    }
}
