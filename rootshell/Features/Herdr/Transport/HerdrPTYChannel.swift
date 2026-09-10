//
//  HerdrPTYChannel.swift
//  rootshell
//
//  Independent, resizable PTYs for stock herdr's direct attach client.
//

import Foundation
import os

nonisolated protocol HerdrPTYChannel: AsyncBytePipe {
    func resize(cols: Int, rows: Int) async throws
}

nonisolated enum HerdrPTYError: Error, LocalizedError {
    case unavailable(String)
    case failed(String)
    case overflow
    case closed

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): return message
        case .overflow: return "herdr pane output exceeded the buffer limit"
        case .closed: return "herdr pane channel closed"
        }
    }

    /// Only explicit request rejection justifies a compatibility fallback.
    /// Timeouts, EOF and network errors must retain the PTY reconnect path.
    static func isRequestRejection(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("pty request failed")
            || message.contains("pty request rejected")
            || message.contains("channel failure")
            || message.contains("channelfailure")
    }
}

/// Synchronous callback ingestion preserves Go/PTY output order without
/// creating a Task per chunk. A single asynchronous reader drains the FIFO.
nonisolated final class HerdrPTYOutputBuffer: @unchecked Sendable {
    static let maxBufferedBytes = 8 * 1024 * 1024

    private struct State {
        var chunks: [Data] = []
        var head = 0
        var offset = 0
        var byteCount = 0
        var closed = false
        var error: Error?
        var reader: CheckedContinuation<Data?, Error>?
        var readLimit = 0

        mutating func take(_ limit: Int) -> Data? {
            guard head < chunks.count else { return nil }
            let chunk = chunks[head]
            let count = min(limit, chunk.count - offset)
            let start = chunk.startIndex + offset
            let result = chunk.subdata(in: start..<(start + count))
            offset += count
            byteCount -= count
            if offset == chunk.count {
                chunks[head] = Data()
                head += 1
                offset = 0
                if head == chunks.count {
                    chunks.removeAll(keepingCapacity: true)
                    head = 0
                } else if head >= 128 {
                    chunks.removeFirst(head)
                    head = 0
                }
            }
            return result
        }

        mutating func discard() {
            chunks.removeAll()
            head = 0
            offset = 0
            byteCount = 0
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int

    init(limit: Int = maxBufferedBytes) { self.limit = limit }

    /// False means the producer must stop/close its own channel.
    @discardableResult
    func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return state.withLock { state in
            guard !state.closed else { return false }
            guard data.count <= limit - state.byteCount else {
                state.closed = true
                state.error = HerdrPTYError.overflow
                state.discard()
                state.reader?.resume(throwing: HerdrPTYError.overflow)
                state.reader = nil
                return false
            }
            state.chunks.append(data)
            state.byteCount += data.count
            if let reader = state.reader {
                state.reader = nil
                reader.resume(returning: state.take(state.readLimit))
            }
            return true
        }
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { reader in
            state.withLock { state in
                let limit = max(1, maxBytes)
                if let data = state.take(limit) {
                    reader.resume(returning: data)
                } else if let error = state.error {
                    reader.resume(throwing: error)
                } else if state.closed {
                    reader.resume(returning: nil)
                } else {
                    precondition(state.reader == nil, "Only one PTY reader is supported")
                    state.reader = reader
                    state.readLimit = limit
                }
            }
        }
    }

    func finish(error: Error? = nil, discard: Bool = false) {
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            state.error = error
            if discard { state.discard() }
            if let reader = state.reader {
                state.reader = nil
                if let error { reader.resume(throwing: error) }
                else { reader.resume(returning: nil) }
            }
        }
    }
}
