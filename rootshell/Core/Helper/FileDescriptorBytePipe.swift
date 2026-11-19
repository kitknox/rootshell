//
//  FileDescriptorBytePipe.swift
//  rootshell
//
//  AsyncBytePipe over a bidirectional file descriptor (a socketpair end
//  received from the helper, or one half of the SFTP-over-tssh bridge).
//  Reads block on a private queue so a waiting read never ties up an actor
//  or the main thread.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

/// A duplex byte stream over a local socket or remote transport channel.
nonisolated protocol AsyncBytePipe: Sendable {
    /// Read up to `maxBytes` from the channel. Returns `nil` on clean EOF.
    func read(maxBytes: Int) async throws -> Data?

    /// Write all of `data` to the channel.
    func write(_ data: Data) async throws

    /// Close the channel. Idempotent.
    func close() async
}

nonisolated final class FileDescriptorBytePipe: AsyncBytePipe, @unchecked Sendable {

    private let fd: Int32
    private let readQueue = DispatchQueue(label: "com.rootshell.fdpipe.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.rootshell.fdpipe.write", qos: .userInitiated)
    private enum State { case open, closing, closed }
    private let state = OSAllocatedUnfairLock(initialState: State.open)
    private let operations = DispatchGroup()

    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    /// Register before queueing the syscall so shutdown also covers work
    /// that has been accepted but hasn't reached its dispatch queue yet.
    private func beginOperation() -> Bool {
        state.withLock { state in
            guard state == .open else { return false }
            operations.enter()
            return true
        }
    }

    func read(maxBytes: Int) async throws -> Data? {
        guard beginOperation() else { return nil }
        let fd = self.fd
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [operations] in
                defer { operations.leave() }
                var buffer = [UInt8](repeating: 0, count: max(1, min(maxBytes, 256 * 1024)))
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count > 0 {
                        continuation.resume(returning: Data(buffer[0..<count]))
                        return
                    }
                    if count == 0 {
                        continuation.resume(returning: nil)
                        return
                    }
                    if errno == EINTR { continue }
                    if errno == EBADF {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        guard beginOperation() else {
            throw POSIXError(.EPIPE)
        }
        let fd = self.fd
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [operations] in
                defer { operations.leave() }
                var offset = 0
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while offset < data.count {
                        let wrote = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                        if wrote > 0 {
                            offset += wrote
                            continue
                        }
                        if wrote < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                        break
                    }
                }
                if offset == data.count {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE))
                }
            }
        }
    }

    func close() async {
        state.withLock { state in
            guard state == .open else { return }
            state = .closing
            // Darwin can reject SHUT_RDWR with ENOTCONN after peer EOF
            // without waking a blocked write. Shut each half independently.
            _ = Darwin.shutdown(fd, SHUT_WR)
            _ = Darwin.shutdown(fd, SHUT_RD)
        }
        await withCheckedContinuation { continuation in
            operations.notify(queue: writeQueue) { [state, fd] in
                state.withLock { state in
                    if state == .closing {
                        _ = Darwin.close(fd)
                        state = .closed
                    }
                }
                continuation.resume()
            }
        }
    }
}
