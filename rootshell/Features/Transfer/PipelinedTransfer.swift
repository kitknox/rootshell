//
//  PipelinedTransfer.swift
//  rootshell
//
//  Pipelined file copy between any ChunkReader and ChunkWriter: local↔SFTP and
//  SFTP↔SFTP relays share one pipeline. Used by SFTPSession, SCPTransfer, the
//  rf browser and the file manager.
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat
import os.log

/// Positional reads from a file; `read` returns empty Data at EOF.
nonisolated protocol ChunkReader: Sendable {
    func read(at offset: UInt64, length: UInt32) async throws -> Data
    func close() async throws
}

/// Positional writes to a file; writes at distinct offsets may run concurrently.
/// A copy only succeeds once `close()` returns: servers may report write errors there.
nonisolated protocol ChunkWriter: Sendable {
    func write(_ data: Data, at offset: UInt64) async throws
    func close() async throws
    /// Gives up on a failed copy instead of closing.
    func abort() async
    /// True when a failed or aborted write leaves any existing destination untouched.
    var replacesAtomically: Bool { get }
    /// Sets mode and mtime through the open handle, so a path swapped for a symlink after the open
    /// can't redirect them (cf. OpenSSH bc01263f1). False when the writer has no such handle.
    func applyAttributes(mode: UInt32?, modified: Date?) async throws -> Bool
}

nonisolated extension ChunkWriter {
    func abort() async {
        try? await close()
    }

    var replacesAtomically: Bool { false }

    func applyAttributes(mode: UInt32?, modified: Date?) async throws -> Bool { false }
}

/// Pipelined transfer operations that overlap multiple read/write requests
/// to minimize latency overhead on high-RTT links.
enum PipelinedTransfer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "PipelinedTransfer")

    /// Number of concurrent requests in flight
    nonisolated static let pipelineDepth = 8

    /// Chunk size per request (1MB)
    nonisolated static let chunkSize: UInt32 = 1_048_576

    /// Files below this size use sequential transfer (2MB)
    nonisolated static let pipelineThreshold: UInt64 = 2_097_152

    // MARK: - Error Type

    /// Wraps local filesystem I/O failures so callers can distinguish them from SFTP errors.
    nonisolated struct LocalIOError: Error {
        let underlying: Error
    }

    /// The source ended before its known size.
    nonisolated struct TruncatedSourceError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The file got shorter while it was being copied.", comment: "File transfer error")
        }
    }

    // MARK: - Sendable Wrapper

    /// Wrapper around SFTPFile for use in task group closures.
    /// Safe because SFTPFile operations dispatch to the NIO EventLoop internally.
    nonisolated struct SendableSFTPFile: @unchecked Sendable, ChunkReader, ChunkWriter {
        let file: SFTPFile

        func read(at offset: UInt64, length: UInt32) async throws -> Data {
            var buffer = try await file.read(from: offset, length: length)
            return buffer.readData(length: buffer.readableBytes) ?? Data()
        }

        func write(_ data: Data, at offset: UInt64) async throws {
            try await file.write(ByteBuffer(data: data), at: offset)
        }

        func close() async throws {
            try await file.close()
        }

        func applyAttributes(mode: UInt32?, modified: Date?) async throws -> Bool {
            var attributes = SFTPFileAttributes()
            // No setuid/setgid/sticky on copied files, as OpenSSH's sftp.
            attributes.permissions = mode.map { $0 & 0o777 }
            if let modified {
                attributes.accessModificationTime = .init(accessTime: modified, modificationTime: modified)
            }
            try await file.setAttributes(attributes)
            return true
        }
    }

    /// pread/pwrite on a descriptor, so concurrent chunks never share a file offset.
    nonisolated final class LocalFile: ChunkReader, ChunkWriter, @unchecked Sendable {
        private let descriptor: Int32
        private let ownsDescriptor: Bool

        init(descriptor: Int32, ownsDescriptor: Bool) {
            self.descriptor = descriptor
            self.ownsDescriptor = ownsDescriptor
        }

        static func openForReading(_ path: String) throws -> LocalFile {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { throw LocalIOError(underlying: POSIXError.current) }
            return LocalFile(descriptor: fd, ownsDescriptor: true)
        }

        /// Refuses a symlink at `path` (O_NOFOLLOW) so a write can't land outside the destination.
        /// With `exclusive`, refuses anything already at `path`.
        static func openForWriting(_ path: String, exclusive: Bool = false, mode: mode_t = 0o644) throws -> LocalFile {
            let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | (exclusive ? O_EXCL : O_TRUNC), mode)
            guard fd >= 0 else { throw LocalIOError(underlying: POSIXError.current) }
            return LocalFile(descriptor: fd, ownsDescriptor: true)
        }

        @concurrent
        func read(at offset: UInt64, length: UInt32) async throws -> Data {
            var data = Data(count: Int(length))
            let count = data.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress, Int(length), off_t(offset))
            }
            guard count >= 0 else { throw LocalIOError(underlying: POSIXError.current) }
            data.count = count
            return data
        }

        @concurrent
        func write(_ data: Data, at offset: UInt64) async throws {
            var written = 0
            while written < data.count {
                let count = data.withUnsafeBytes { raw in
                    pwrite(descriptor, raw.baseAddress! + written, data.count - written, off_t(offset) + off_t(written))
                }
                guard count > 0 else { throw LocalIOError(underlying: POSIXError.current) }
                written += count
            }
        }

        func close() async throws {
            guard ownsDescriptor else { return }
            guard Darwin.close(descriptor) == 0 else { throw LocalIOError(underlying: POSIXError.current) }
        }

        func applyAttributes(mode: UInt32?, modified: Date?) async throws -> Bool {
            if let mode, fchmod(descriptor, mode_t(mode & 0o777)) != 0 {
                throw LocalIOError(underlying: POSIXError.current)
            }
            if let modified {
                let seconds = modified.timeIntervalSince1970.rounded(.down)
                let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((modified.timeIntervalSince1970 - seconds) * 1_000_000_000))
                var times = [time, time]
                guard futimens(descriptor, &times) == 0 else { throw LocalIOError(underlying: POSIXError.current) }
            }
            return true
        }
    }

    // MARK: - Copy

    /// Copies `size` bytes (or to EOF when unknown) from `reader` to `writer`.
    /// `onProgress` receives the cumulative byte count; neither end is closed here.
    static func copy(
        from reader: some ChunkReader,
        to writer: some ChunkWriter,
        size: UInt64?,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        guard let size, size >= pipelineThreshold else {
            try await copySequential(from: reader, to: writer, onProgress: onProgress)
            return
        }

        // No `size + chunk - 1`: a peer-reported size near UInt64.max would overflow.
        let totalChunks = Int(size / UInt64(chunkSize) + (size % UInt64(chunkSize) == 0 ? 0 : 1))
        var nextChunk = 0
        var completed: Int64 = 0

        try await withThrowingTaskGroup(of: Int64.self) { group in
            // Each child moves its whole range, looping on short reads: SFTP servers
            // commonly cap read responses (OpenSSH: 256KB), below the 1MB request.
            func submit(_ chunkIndex: Int) {
                let rangeStart = UInt64(chunkIndex) * UInt64(chunkSize)
                let rangeEnd = rangeStart + min(UInt64(chunkSize), size - rangeStart)
                group.addTask {
                    var offset = rangeStart
                    while offset < rangeEnd {
                        try Task.checkCancellation()
                        let data = try await reader.read(at: offset, length: UInt32(rangeEnd - offset))
                        // The file shrank mid-copy: fail, which also cancels chunks
                        // still waiting on this one, rather than finish short.
                        if data.isEmpty { throw TruncatedSourceError() }
                        try await writer.write(data, at: offset)
                        offset += UInt64(data.count)
                    }
                    return Int64(offset - rangeStart)
                }
            }

            while nextChunk < min(pipelineDepth, totalChunks) {
                submit(nextChunk)
                nextChunk += 1
            }

            for try await moved in group {
                try Task.checkCancellation()
                completed += moved
                onProgress(completed)
                if nextChunk < totalChunks {
                    submit(nextChunk)
                    nextChunk += 1
                }
            }
        }
    }

    /// Sequential copy for small files or unknown sizes, using the 1MB chunk size.
    private static func copySequential(
        from reader: some ChunkReader,
        to writer: some ChunkWriter,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await reader.read(at: offset, length: chunkSize)
            if data.isEmpty { break }
            try await writer.write(data, at: offset)
            offset += UInt64(data.count)
            onProgress(Int64(offset))
        }
    }

    // MARK: - FileHandle Entry Points

    /// Download a remote file into an open local handle.
    static func downloadFile(
        file: SFTPFile,
        fileSize: UInt64?,
        to localHandle: FileHandle,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        try await copy(
            from: SendableSFTPFile(file: file),
            to: LocalFile(descriptor: localHandle.fileDescriptor, ownsDescriptor: false),
            size: fileSize,
            onProgress: onProgress
        )
    }

    /// Upload from an open local handle into a remote file.
    static func uploadFile(
        file: SFTPFile,
        from localHandle: FileHandle,
        fileSize: UInt64?,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        try await copy(
            from: LocalFile(descriptor: localHandle.fileDescriptor, ownsDescriptor: false),
            to: SendableSFTPFile(file: file),
            size: fileSize,
            onProgress: onProgress
        )
    }
}

extension POSIXError {
    /// The current `errno` as a POSIXError.
    nonisolated static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
