//
//  NIOChannelBytePipe.swift
//  rootshell
//
//  AsyncBytePipe adapter over an arbitrary NIO Channel. Bridges the
//  push-based NIO pipeline (where bytes arrive via channelRead) with
//  the pull-based ``AsyncBytePipe`` API. The caller supplies whatever
//  unwrapping handlers its channel type needs; this pipe only requires
//  that plain ByteBuffers reach the end of the inbound pipeline.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import NIOFoundationCompat
import os

nonisolated enum NIOChannelBytePipeError: Error {
    /// The peer closed the channel before a `readExactly` request was
    /// fully satisfied.
    case unexpectedEndOfStream
}

/// AsyncBytePipe wrapping a NIO Channel. Inbound bytes are queued
/// synchronously on the event loop so reads see them in wire order (#710).
/// The channel reads only when a reader waits on an empty queue, so a paused
/// consumer backpressures the peer (VNC's DCT encoder relies on this).
/// Writes go straight through `channel.writeAndFlush`.
nonisolated final class NIOChannelBytePipe: AsyncBytePipe, @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "NIOChannelBytePipe"
    )

    private let channel: Channel
    private let state = OSAllocatedUnfairLock(initialState: PipeState())

    /// Install the pipe + its supporting handlers on the given channel.
    /// Must be called on the channel's event loop. `extraHandlers` are
    /// added (in order) ahead of the pipe's own inbound handler — the
    /// hook for channel-type-specific unwrapping. Citadel DirectTCPIP
    /// channels already carry ByteBuffers and need no extra handler here.
    static func install(
        on channel: Channel,
        extraHandlers: [ChannelHandler] = []
    ) throws -> NIOChannelBytePipe {
        if let options = channel.syncOptions {
            try options.setOption(ChannelOptions.autoRead, value: false)
        } else {
            _ = channel.setOption(ChannelOptions.autoRead, value: false)
        }
        let pipe = NIOChannelBytePipe(channel: channel)
        let handler = InboundHandler(pipe: pipe)
        for extra in extraHandlers {
            try channel.pipeline.syncOperations.addHandler(extra)
        }
        try channel.pipeline.syncOperations.addHandler(handler)
        return pipe
    }

    private init(channel: Channel) {
        self.channel = channel
    }

    // MARK: - AsyncBytePipe

    /// Returns queued bytes first, then nil (clean EOF) once closed.
    func read(maxBytes: Int) async throws -> Data? {
        // Queued bytes need no suspension; parsers issue many small reads.
        if let chunk = state.withLock({ $0.take(maxBytes: maxBytes) }) {
            return chunk
        }
        return await withCheckedContinuation { continuation in
            let outcome: ReadOutcome = state.withLock { state in
                if let chunk = state.take(maxBytes: maxBytes) {
                    return .ready(chunk)
                }
                if state.closed {
                    return .ready(nil)
                }
                precondition(state.reader == nil, "NIOChannelBytePipe supports a single reader")
                state.reader = (continuation, maxBytes)
                return .parked
            }
            switch outcome {
            case .ready(let data):
                continuation.resume(returning: data)
            case .parked:
                channel.read()
            }
        }
    }

    /// Accumulate exactly `count` bytes on top of the chunked ``read``
    /// primitive. Throws ``NIOChannelBytePipeError/unexpectedEndOfStream``
    /// if the peer closes mid-message.
    func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard let first = try await read(maxBytes: count), !first.isEmpty else {
            throw NIOChannelBytePipeError.unexpectedEndOfStream
        }
        if first.count == count { return first }
        var out = first
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try await read(maxBytes: count - out.count), !chunk.isEmpty else {
                throw NIOChannelBytePipeError.unexpectedEndOfStream
            }
            out.append(chunk)
        }
        return out
    }

    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    func close() async {
        try? await channel.close()
    }

    // MARK: - Internal hooks for InboundHandler

    /// Called on the event loop. Hands bytes to a parked reader or queues them.
    fileprivate func enqueue(_ data: Data) {
        let handoff: (CheckedContinuation<Data?, Never>, Data)? = state.withLock { state in
            state.chunks.append(data)
            guard let reader = state.reader,
                  let chunk = state.take(maxBytes: reader.maxBytes) else { return nil }
            state.reader = nil
            return (reader.continuation, chunk)
        }
        if let (continuation, chunk) = handoff {
            continuation.resume(returning: chunk)
        }
    }

    fileprivate var hasParkedReader: Bool {
        state.withLock { $0.reader != nil }
    }

    fileprivate func finish() {
        let reader: CheckedContinuation<Data?, Never>? = state.withLock { state in
            state.closed = true
            defer { state.reader = nil }
            return state.reader?.continuation
        }
        reader?.resume(returning: nil)
    }
}

private nonisolated enum ReadOutcome: Sendable {
    case ready(Data?)
    case parked
}

/// Lock-protected inbound state. A reader only parks while `chunks` is empty.
private nonisolated struct PipeState: Sendable {
    var chunks = CircularBuffer<Data>()
    var closed = false
    var reader: (continuation: CheckedContinuation<Data?, Never>, maxBytes: Int)?

    /// Pops or splits the front chunk. The unread rest stays an O(1) slice;
    /// only the returned bytes are copied, so results are zero-based.
    mutating func take(maxBytes: Int) -> Data? {
        guard let front = chunks.first else { return nil }
        if front.count <= maxBytes {
            chunks.removeFirst()
            return front.startIndex == 0 ? front : front.subdata(in: front.startIndex..<front.endIndex)
        }
        let split = front.startIndex + maxBytes
        chunks[chunks.startIndex] = front[split...]
        return front.subdata(in: front.startIndex..<split)
    }
}

/// Inbound-only NIO handler that feeds received `ByteBuffer`s into the
/// parent pipe synchronously, preserving channelRead order.
private nonisolated final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let pipe: NIOChannelBytePipe

    init(pipe: NIOChannelBytePipe) {
        self.pipe = pipe
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        guard let bytes = buffer.readData(length: buffer.readableBytes), !bytes.isEmpty else { return }
        pipe.enqueue(bytes)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // A batch can satisfy the read without reaching the reader (empty
        // channel data, filtered messages); with autoRead off, re-arm demand.
        if pipe.hasParkedReader {
            context.read()
        }
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        pipe.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pipe.finish()
        context.close(promise: nil)
    }
}
