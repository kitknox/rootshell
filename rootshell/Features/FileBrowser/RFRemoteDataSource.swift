//
//  RFRemoteDataSource.swift
//  rootshell
//
//  Remote implementation of RFDataSource: an SFTP server or a cloud storage
//  provider, each held as a file manager FileConnection. Every operation runs
//  through FileSystemEndpoint, so both backends share one implementation.
//

#if !targetEnvironment(macCatalyst)

import Foundation

/// Remote data source for the rf file browser. Each instance owns its own connection.
@MainActor
final class RFRemoteDataSource: RFDataSource {
    enum Target {
        case sftp(SSHConfig)
        case storage(StorageProvider)
    }

    let target: Target
    let isRemote = true

    var connectionLabel: String {
        switch target {
        case .sftp(let config): "\(config.username)@\(config.host)"
        case .storage(let provider): provider.displayName
        }
    }

    /// Mode label for the status bar.
    var kindLabel: String {
        switch target {
        case .sftp: "SFTP"
        case .storage: "S3"
        }
    }

    /// Whether `other` addresses the same server-side file scope, so an identical
    /// absolute path on both is literally the same file. Used only to suppress a
    /// destructive paste onto the source itself.
    func isSameLocation(as other: any RFDataSource) -> Bool {
        guard let other = other as? RFRemoteDataSource else { return false }
        switch (target, other.target) {
        case (.sftp(let config), .sftp(let otherConfig)):
            return config.reachesSameAccount(as: otherConfig)
        case (.storage(let provider), .storage(let otherProvider)):
            return provider.mayShareNamespace(with: otherProvider)
        default:
            return false
        }
    }

    private var connection: (any FileConnection)?
    private(set) var homePath: String = "/"
    private var tempDir: String?

    /// Callback for SFTP host key validation prompts.
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// Callback for SFTP keyboard-interactive (RFC 4256) prompts (2FA/OTP/PAM). nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    init(target: Target) {
        self.target = target
    }

    deinit {
        // A yank clipboard can outlive every tab; an S3 client must be shut down before release.
        if let connection { Task { await connection.close() } }
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let connection: any FileConnection
        switch target {
        case .sftp(let config):
            connection = try await SFTPConnectionFactory.openSSH(
                config,
                label: connectionLabel,
                onHostKeyValidation: onHostKeyValidation,
                onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
            )
        case .storage(let provider):
            connection = try S3Connection(provider: provider)
        }
        self.connection = connection
        homePath = (try? await connection.browseFileSystem.homeDirectory()) ?? "/"
    }

    func disconnect() {
        guard let connection else { return }
        self.connection = nil
        Task { await connection.close() }
    }

    var fileSystem: FileSystemEndpoint {
        get throws {
            guard let connection else { throw SFTPError.notConnected }
            return connection.browseFileSystem
        }
    }

    // MARK: - Directory Listing

    func loadDirectory(at path: String) async throws -> [RFEntry] {
        try await fileSystem.list(path)
    }

    // MARK: - File Preview

    func readFilePreview(at path: String, maxBytes: Int) async throws -> Data? {
        try await readHead(path, maxBytes: maxBytes)
    }

    /// A single read from the start of the file; SFTP servers may return less than asked.
    private func readHead(_ path: String, maxBytes: Int) async throws -> Data {
        let reader = try await fileSystem.openReader(path)
        defer { Task { try? await reader.close() } }
        return try await reader.read(at: 0, length: UInt32(min(maxBytes, 1_048_576)))
    }

    func downloadToTemp(remotePath: String, maxBytes: Int?) async throws -> String {
        let dir = ensureTempDir()
        // Use a UUID subdirectory to avoid collisions while preserving the
        // original filename — bat needs the extension for language detection.
        let subdir = (dir as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        let filename = (remotePath as NSString).lastPathComponent
        let localPath = (subdir as NSString).appendingPathComponent(filename)

        if let maxBytes {
            // Partial download for size-capped previews
            try await readHead(remotePath, maxBytes: maxBytes).write(to: URL(fileURLWithPath: localPath))
        } else {
            // Full download (for images, etc.); never a tree, whatever the server claims.
            try await FileTreeCopier.copySingleFile(remotePath, to: localPath, from: fileSystem, to: RFLocalDataSource.fileSystem)
        }

        return localPath
    }

    func cleanupTempFiles() {
        guard let dir = tempDir else { return }
        try? FileManager.default.removeItem(atPath: dir)
        tempDir = nil
    }

    private func ensureTempDir() -> String {
        if let dir = tempDir { return dir }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rf-remote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDir = dir
        return dir
    }

    // MARK: - File Operations

    func createDirectory(at path: String) async throws {
        try await fileSystem.makeDirectory(path)
    }

    func createFile(at path: String) async throws {
        try await fileSystem.createEmptyFile(path)
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try await fileSystem.rename(oldPath, to: newPath)
    }

    func fileExists(at path: String) async -> Bool {
        guard let fs = try? fileSystem else { return false }
        return (try? await fs.infoIfExists(path, followLinks: false)) != nil
    }

    /// Deletes a file, or a directory and its contents. A symlinked directory is
    /// unlinked, never descended into.
    func delete(at path: String) async throws {
        try await fileSystem.removeRecursively(path)
    }

    func copyFile(sourcePath: String, destPath: String, force: Bool) async throws {
        // Copying a file onto itself is a no-op. Bail before any I/O: the copy
        // opens the destination with .truncate, so re-writing the source onto itself
        // could corrupt the original if the copy fails midway.
        if sourcePath == destPath { return }
        let fs = try fileSystem
        if force, try await fs.infoIfExists(destPath, followLinks: false) != nil { try await fs.removeRecursively(destPath) }
        // Bytes stream through the app, except where storage can copy on the server.
        try await FileTreeCopier.copyTree(sourcePath, to: destPath, from: fs, to: fs)
    }

    func moveFile(sourcePath: String, destPath: String, force: Bool) async throws {
        // Moving a file onto itself is a no-op; bail before the destructive delete.
        if sourcePath == destPath { return }
        if force {
            // Delete destination (could be file or directory)
            try? await delete(at: destPath)
        }
        try await fileSystem.rename(sourcePath, to: destPath)
    }

    // MARK: - Remote Edits

    /// Upload a local file (an edited temp copy) to `remotePath`.
    func uploadFromLocal(localPath: String, remotePath: String) async throws {
        try await FileTreeCopier.copyTree(localPath, to: remotePath, from: RFLocalDataSource.fileSystem, to: fileSystem)
    }

    // MARK: - Path Utilities

    func joinPath(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    func parentPath(of path: String) -> String {
        SFTPOperations.parentPath(of: path)
    }
}

#endif
