import Foundation
#if canImport(Citadel)
import Citadel
import NIOCore
import NIOSSH

/// Owns only a child channel; canceling it never closes the gateway SSH client.
actor HerdrCitadelPTYChannel: HerdrPTYChannel {
    private nonisolated let output = HerdrPTYOutputBuffer()
    private var writer: TTYStdinWriter?
    private var pump: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var closed = false

    static func open(client: SSHClient, command: String, term: String, cols: Int, rows: Int) async throws -> HerdrCitadelPTYChannel {
        let pipe = HerdrCitadelPTYChannel()
        try await withTaskCancellationHandler {
            try await pipe.start(client: client, command: command, term: term, cols: cols, rows: rows)
            try Task.checkCancellation()
        } onCancel: {
            Task { await pipe.close() }
        }
        return pipe
    }

    private func start(client: SSHClient, command: String, term: String, cols: Int, rows: Int) async throws {
        guard !closed else { throw CancellationError() }
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHConnectionHelper.defaultPTYTerminalModes
        )
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            self.ready = ready
            pump = Task {
                do {
                    try await client.withPTYExec(request, command: command, agentDelegate: nil) { inbound, writer in
                        try self.didOpen(writer)
                        for try await chunk in inbound {
                            try Task.checkCancellation()
                            switch chunk {
                            case .stdout(let bytes), .stderr(let bytes):
                                guard self.output.append(Data(bytes.readableBytesView)) else {
                                    throw HerdrPTYError.overflow
                                }
                            case .exitStatus(let status):
                                if status != 0 { throw HerdrPTYError.failed("herdr attach exited with status \(status)") }
                            }
                        }
                    }
                    self.didEnd(error: nil)
                } catch {
                    self.didEnd(error: error)
                }
            }
        }
    }

    private func didOpen(_ writer: TTYStdinWriter) throws {
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        self.writer = writer
        ready?.resume()
        ready = nil
    }

    private func didEnd(error: Error?) {
        if let ready {
            ready.resume(throwing: error ?? HerdrPTYError.closed)
            self.ready = nil
        }
        output.finish(error: error)
        writer = nil
        closed = true
    }

    nonisolated func read(maxBytes: Int) async throws -> Data? {
        try await output.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        guard !closed, let writer else { throw HerdrPTYError.closed }
        var bytes = ByteBufferAllocator().buffer(capacity: data.count)
        bytes.writeBytes(data)
        try await writer.write(bytes)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard !closed, let writer else { throw HerdrPTYError.closed }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() async {
        closed = true
        ready?.resume(throwing: CancellationError())
        ready = nil
        output.finish(discard: true)
        pump?.cancel()
        // Returning from the canceled TTY iterator closes its child NIO channel.
        await pump?.value
        pump = nil
        writer = nil
    }
}
#endif
