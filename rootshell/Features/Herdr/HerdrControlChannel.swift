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
    private let onInbound: @Sendable (HerdrControl.Inbound) -> Void
    private let onClosed: @Sendable (Error?) -> Void

    private var nextRequestId: UInt64 = 1
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var closed = false
    private var writeQueue: Task<Void, Never>?

    /// Facts from `control.open`, set once the stream is up.
    private(set) var opened: HerdrControl.ControlOpened?

    init(
        pipe: AsyncBytePipe,
        onInbound: @escaping @Sendable (HerdrControl.Inbound) -> Void,
        onClosed: @escaping @Sendable (Error?) -> Void
    ) {
        self.pipe = pipe
        self.onInbound = onInbound
        self.onClosed = onClosed
    }

    // MARK: - Lifecycle

    /// Reads the `control.open` line the bridge prints first, checks the
    /// stream protocol, and starts the reader.
    func open() async throws -> HerdrControl.ControlOpened {
        var buffer = Data()
        let firstLine = try await readLine(into: &buffer)
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
        self.opened = opened
        startReader(leftover: buffer)
        return opened
    }

    func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        // Best effort: tell the bridge to release everything before the pipe dies.
        let line = #"{"id":"control:close","method":"control.close","params":{}}"# + "\n"
        try? await pipe.write(Data(line.utf8))
        await pipe.close()
        failPending(HerdrChannelError.closed)
    }

    /// Close without the courtesy write: used when the stream is presumed
    /// dead, where a blocked writer would stall recovery.
    func abort() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        await pipe.close()
        failPending(HerdrChannelError.closed)
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
        guard !closed else { throw HerdrChannelError.closed }
        let id = "r\(nextRequestId)"
        nextRequestId += 1
        let encoded = try JSONEncoder().encode(HerdrControl.Request(id: id, method: method, params: params))
        var line = encoded
        line.append(0x0A)

        // The continuation is registered before the write suspends: a fast
        // reply could otherwise land in `dispatch` with nothing to match.
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.pipe.write(line)
                } catch {
                    await self.fail(id: id, error: error)
                }
            }
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
        } catch {
            throw HerdrChannelError.malformed("\(method) result: \(error)")
        }
    }

    /// Fire-and-forget input write: no response wait so typing never blocks
    /// behind slower requests. Errors surface as responses the reader logs.
    func sendInput(attachId: String, bytes: Data) async {
        guard !closed else { return }
        let id = "i\(nextRequestId)"
        nextRequestId += 1
        let params = HerdrControl.InputParams(attach_id: attachId, bytes: bytes.base64EncodedString())
        guard var line = try? JSONEncoder().encode(HerdrControl.Request(id: id, method: "terminal.input", params: params)) else {
            return
        }
        line.append(0x0A)
        do {
            try await pipe.write(line)
        } catch {
            Self.logger.warning("herdr input write failed: \(error.localizedDescription)")
        }
    }

    private func timeOut(id: String, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: HerdrChannelError.timedOut(method: method))
    }

    private func fail(id: String, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    // MARK: - Reader

    private func startReader(leftover: Data) {
        readerTask = Task { [weak self] in
            guard let self else { return }
            var buffer = leftover
            var failure: Error?
            do {
                while !Task.isCancelled {
                    guard let line = try await self.readLine(into: &buffer) else { break }
                    await self.dispatch(line)
                }
            } catch {
                failure = error
            }
            await self.readerEnded(failure)
        }
    }

    private func readerEnded(_ error: Error?) {
        let wasClosed = closed
        closed = true
        failPending(error ?? HerdrChannelError.closed)
        if !wasClosed {
            onClosed(error)
        }
    }

    private func dispatch(_ line: Data) {
        if let head = try? HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: line),
           let id = head.id, head.type == nil, head.event == nil {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: line)
            } else if id.hasPrefix("i"), let error = head.error {
                Self.logger.warning("herdr input rejected: \(error.code) \(error.message)")
            }
            return
        }
        if let inbound = HerdrControl.decodeInbound(line) {
            onInbound(inbound)
        }
    }

    /// Reads one newline-terminated line, keeping partial data in `buffer`.
    /// Returns nil on clean EOF.
    private func readLine(into buffer: inout Data) async throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            if buffer.count > Self.maxLineBytes {
                throw HerdrChannelError.malformed("line exceeds \(Self.maxLineBytes) bytes")
            }
            guard let chunk = try await pipe.read(maxBytes: 256 * 1024) else {
                return buffer.isEmpty ? nil : nil
            }
            buffer.append(chunk)
        }
    }
}
