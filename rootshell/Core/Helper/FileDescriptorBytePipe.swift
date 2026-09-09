//
//  FileDescriptorBytePipe.swift
//  rootshell
//
//  AsyncBytePipe over a bidirectional file descriptor (a socketpair end
//  received from the helper). Reads block on a private queue so a waiting
//  read never ties up an actor or the main thread.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

#if targetEnvironment(macCatalyst)

nonisolated final class FileDescriptorBytePipe: AsyncBytePipe, @unchecked Sendable {

    private let fd: Int32
    private let readQueue = DispatchQueue(label: "com.rootshell.fdpipe.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.rootshell.fdpipe.write", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32) {
        self.fd = fd
    }

    private var isClosed: Bool {
        state.withLock { $0 }
    }

    func read(maxBytes: Int) async throws -> Data? {
        if isClosed { return nil }
        let fd = self.fd
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
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
        if isClosed {
            throw POSIXError(.EPIPE)
        }
        let fd = self.fd
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
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
        let wasClosed = state.withLock { closed -> Bool in
            let was = closed
            closed = true
            return was
        }
        if !wasClosed {
            // Shutdown first so a blocked read returns promptly.
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
    }
}

#endif
