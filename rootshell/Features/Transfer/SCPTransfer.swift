//
//  SCPTransfer.swift
//  rootshell
//
//  SFTP-based file transfer implementation for the native SCP command
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat
import NIOSSH
import os.log

/// Progress state for SCP transfers
struct SCPTransferProgress: Sendable {
    enum State: Sendable {
        case connecting
        case authenticating
        case enumerating
        case transferring(currentFile: String)
        case completed
        case failed(Error)
    }

    var state: State
    var currentFile: String = ""
    var currentFileIndex: Int = 0
    var totalFiles: Int = 0
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var startTime: Date = Date()

    var percentComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100
    }

    var throughput: Double {  // bytes/second
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred) / elapsed
    }

    static var initial: SCPTransferProgress {
        SCPTransferProgress(state: .connecting)
    }
}

/// Error types for SCP transfers
enum SCPError: LocalizedError {
    case connectionFailed(host: String, underlying: Error?)
    case authenticationFailed(host: String)
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case directoryNotEmpty(path: String)
    case transferFailed(file: String, reason: String)
    case invalidPath(String)
    case remoteGlobFailed(pattern: String)
    case recursiveRequiredForDirectory(path: String)
    case localIOError(path: String, underlying: Error?)
    case noMatchingFiles(pattern: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host, _):
            return "Failed to connect to \(host)"
        case .authenticationFailed(let host):
            return "Authentication failed for \(host)"
        case .fileNotFound(let path):
            return "No such file or directory: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .directoryNotEmpty(let path):
            return "Directory not empty: \(path)"
        case .transferFailed(let file, let reason):
            return "Transfer failed for \(file): \(reason)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .remoteGlobFailed(let pattern):
            return "Failed to expand pattern: \(pattern)"
        case .recursiveRequiredForDirectory(let path):
            return "\(path) is a directory (use -r flag)"
        case .localIOError(let path, _):
            return "I/O error for \(path)"
        case .noMatchingFiles(let pattern):
            return "No files match pattern: \(pattern)"
        case .cancelled:
            return "Transfer cancelled"
        }
    }

    /// Whether this error should show failure animation
    var showsFailureAnimation: Bool {
        switch self {
        case .cancelled: return false
        default: return true
        }
    }

    /// Map from SFTP error to SCPError
    static func from(sftpError: Error, path: String) -> SCPError {
        let description = String(describing: sftpError).lowercased()

        if description.contains("no such file") || description.contains("enoent") || description.contains("not found") {
            return .fileNotFound(path: path)
        } else if description.contains("permission denied") || description.contains("eacces") {
            return .permissionDenied(path: path)
        } else if description.contains("not empty") {
            return .directoryNotEmpty(path: path)
        } else if description.contains("is a directory") {
            return .recursiveRequiredForDirectory(path: path)
        }

        return .transferFailed(file: path, reason: sftpError.localizedDescription)
    }
}

/// Handles file transfers using SFTP (used by native SCP command)
@MainActor
final class SCPTransfer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SCPTransfer")

    /// Progress emission throttling
    private let progressEmitInterval: TimeInterval = 0.1  // 100ms minimum between updates
    private let progressEmitBytesInterval: Int64 = 512 * 1024  // Or every 512KB
    private var lastProgressEmit: Date = .distantPast
    private var lastProgressBytes: Int64 = 0

    let command: SCPParsedCommand
    let config: SSHConfig

    private var sshClient: SSHClient?
    private var jumpClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var isCancelled = false
    private var transferTask: Task<Void, Never>?
    private var progress: SCPTransferProgress = .initial

    // Callbacks
    var onOutput: (@Sendable (String) -> Void)?
    var onComplete: ((Result<Void, Error>) -> Void)?
    var onProgress: ((SCPTransferProgress) -> Void)?
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    /// Keyboard-interactive (RFC 4256) challenge callback (2FA/OTP/PAM). nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    init(command: SCPParsedCommand, config: SSHConfig) {
        self.command = command
        self.config = config
    }

    /// Start the file transfer
    func start() async {
        do {
            // Connect SSH
            updateProgress(.connecting)
            try await connectSSH()

            try Task.checkCancellation()

            // Open SFTP
            updateProgress(.authenticating)
            guard let client = sshClient else {
                throw SCPError.connectionFailed(host: config.host, underlying: nil)
            }
            sftpClient = try await client.openSFTP()

            try Task.checkCancellation()

            // Perform transfer
            try await performTransfer()

            // Success
            updateProgress(.completed)
            cleanup()
            onComplete?(.success(()))

        } catch is CancellationError {
            // Task was cancelled via cancel()
            updateProgress(.failed(SCPError.cancelled))
            cleanup()
            onComplete?(.failure(SCPError.cancelled))
        } catch {
            let finalError: Error
            if isCancelled {
                finalError = SCPError.cancelled
            } else {
                finalError = error
            }
            updateProgress(.failed(finalError))
            cleanup()
            onComplete?(.failure(finalError))
        }
    }

    /// Start the transfer asynchronously in a cancellable Task
    func startAsync() {
        transferTask = Task { @MainActor in
            await start()
        }
    }

    /// Cancel the transfer - clears callbacks and marks cancelled
    /// Note: NIO doesn't support forcible cancellation of in-flight operations.
    /// The network transfer may continue briefly but no callbacks will fire.
    func cancel() {
        Self.logger.info("SCP transfer cancel() called")

        // Mark cancelled FIRST
        isCancelled = true

        // Clear all callbacks so nothing can fire after cancel
        // This is the key - even if transfer continues, user won't see it
        onOutput = nil
        onProgress = nil
        onComplete = nil

        // Cancel the Swift Task (cooperative cancellation)
        // This will cause Task.checkCancellation() to throw on next check
        transferTask?.cancel()
        transferTask = nil

        // Don't forcibly close connections here - it causes NIO crashes
        // The cleanup() method will be called when the transfer loop exits
        // Either from checkCancellation() throwing, or from operation errors
    }

    // MARK: - SSH Connection

    private func connectSSH() async throws {
        Self.logger.info("Connecting to \(self.config.host):\(self.config.port) for SCP transfer")

        let result = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
        self.sshClient = result.client
        self.jumpClient = result.jumpClient
    }

    // MARK: - File Transfer

    private func performTransfer() async throws {
        guard let sftp = sftpClient else {
            throw SCPError.connectionFailed(host: config.host, underlying: nil)
        }

        // Reset progress tracking for fresh throttling state
        resetProgressTracking()

        switch command.direction {
        case .upload:
            try await performUpload(sftp: sftp)
        case .download:
            try await performDownload(sftp: sftp)
        }
    }

    private func performUpload(sftp: SFTPClient) async throws {
        guard case .remote(_, _, let rawRemotePath) = command.destination else {
            throw SCPError.invalidPath("Destination must be remote for upload")
        }

        // Expand tilde in remote path (~ -> /home/user)
        let remotePath = try await expandRemotePath(sftp: sftp, path: rawRemotePath)

        // Check if remote destination is an existing directory
        // Matches standard scp: "scp file host:/tmp" uploads to /tmp/file
        let remoteIsDirectory: Bool
        do {
            let attrs = try await sftp.getAttributes(at: remotePath)
            remoteIsDirectory = isDirectory(attrs)
        } catch {
            remoteIsDirectory = false
        }

        // Collect all files to upload
        var filesToUpload: [(localPath: String, remotePath: String)] = []

        for source in command.sources {
            guard case .local(let localPath) = source else { continue }

            let expandedPath = expandLocalPath(localPath)
            let fileManager = FileManager.default

            // Check if source exists
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
                throw SCPError.fileNotFound(path: localPath)
            }

            if isDirectory.boolValue {
                guard command.recursive else {
                    throw SCPError.recursiveRequiredForDirectory(path: localPath)
                }
                // Enumerate directory recursively
                let files = try enumerateLocalDirectory(expandedPath)
                let baseName = (expandedPath as NSString).lastPathComponent
                for file in files {
                    let relativePath = String(file.dropFirst(expandedPath.count))
                    let destPath = joinRemotePath(remotePath, baseName + relativePath)
                    filesToUpload.append((file, destPath))
                }
            } else {
                // Single file
                let fileName = (expandedPath as NSString).lastPathComponent
                let destPath = remoteIsDirectory || remotePath.hasSuffix("/") || remotePath == "." ?
                    joinRemotePath(remotePath, fileName) : remotePath
                filesToUpload.append((expandedPath, destPath))
            }
        }

        guard !filesToUpload.isEmpty else {
            throw SCPError.noMatchingFiles(pattern: command.sources.first?.path ?? "")
        }

        // Calculate total size
        let fileManager = FileManager.default
        progress.totalFiles = filesToUpload.count
        var totalSize: Int64 = 0
        for (localPath, _) in filesToUpload {
            if let attrs = try? fileManager.attributesOfItem(atPath: localPath),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        progress.totalBytes = totalSize
        progress.startTime = Date()

        // Upload each file
        for (index, (localPath, remotePath)) in filesToUpload.enumerated() {
            try Task.checkCancellation()

            progress.currentFileIndex = index + 1
            progress.currentFile = (localPath as NSString).lastPathComponent
            updateProgress(.transferring(currentFile: progress.currentFile))

            try await uploadFile(sftp: sftp, localPath: localPath, remotePath: remotePath)
        }
    }

    private func performDownload(sftp: SFTPClient) async throws {
        guard case .local(let localPath) = command.destination else {
            throw SCPError.invalidPath("Destination must be local for download")
        }

        let expandedLocalPath = expandLocalPath(localPath)

        // Collect all files to download
        var filesToDownload: [(remotePath: String, localPath: String, size: UInt64)] = []

        for source in command.sources {
            guard case .remote(_, _, let remotePath) = source else { continue }

            // Expand tilde in remote path (~ -> /home/user)
            let expandedRemotePath = try await expandRemotePath(sftp: sftp, path: remotePath)

            // Expand globs if present
            let paths: [String]
            if containsGlob(expandedRemotePath) {
                updateProgress(.enumerating)
                paths = try await expandRemoteGlob(sftp: sftp, pattern: expandedRemotePath)
                guard !paths.isEmpty else {
                    throw SCPError.noMatchingFiles(pattern: remotePath)
                }
            } else {
                paths = [expandedRemotePath]
            }

            for path in paths {
                try Task.checkCancellation()

                // Get file attributes to check if directory and get size
                let attrs: SFTPFileAttributes
                do {
                    attrs = try await sftp.getAttributes(at: path)
                } catch {
                    throw SCPError.from(sftpError: error, path: path)
                }

                // Check if it's a directory using permissions (no direct type field)
                let isDir = isDirectory(attrs)

                if isDir {
                    guard command.recursive else {
                        throw SCPError.recursiveRequiredForDirectory(path: path)
                    }
                    // Enumerate directory recursively
                    updateProgress(.enumerating)
                    let files = try await enumerateRemoteDirectory(sftp: sftp, path: path)
                    let baseName = (path as NSString).lastPathComponent
                    for (filePath, fileSize) in files {
                        let relativePath = String(filePath.dropFirst(path.count))
                        let destPath = joinLocalPath(expandedLocalPath, baseName + relativePath)
                        filesToDownload.append((filePath, destPath, fileSize))
                    }
                } else {
                    // Single file
                    let fileName = (path as NSString).lastPathComponent
                    var destPath: String
                    var destIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: expandedLocalPath, isDirectory: &destIsDir), destIsDir.boolValue {
                        destPath = joinLocalPath(expandedLocalPath, fileName)
                    } else if expandedLocalPath.hasSuffix("/") {
                        destPath = joinLocalPath(expandedLocalPath, fileName)
                    } else {
                        destPath = expandedLocalPath
                    }
                    filesToDownload.append((path, destPath, attrs.size ?? 0))
                }
            }
        }

        guard !filesToDownload.isEmpty else {
            throw SCPError.noMatchingFiles(pattern: command.sources.first?.path ?? "")
        }

        // Calculate total size
        progress.totalFiles = filesToDownload.count
        progress.totalBytes = filesToDownload.saturatingByteTotal { $0.size }
        progress.startTime = Date()

        // Download each file
        for (index, (remotePath, localPath, _)) in filesToDownload.enumerated() {
            try Task.checkCancellation()

            progress.currentFileIndex = index + 1
            progress.currentFile = (remotePath as NSString).lastPathComponent
            updateProgress(.transferring(currentFile: progress.currentFile))

            try await downloadFile(sftp: sftp, remotePath: remotePath, localPath: localPath)
        }
    }

    // MARK: - Single File Transfer

    private func uploadFile(sftp: SFTPClient, localPath: String, remotePath: String) async throws {
        Self.logger.info("Uploading \(localPath) -> \(remotePath)")

        // Ensure remote directory exists
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        if !remoteDir.isEmpty && remoteDir != "." && remoteDir != "/" {
            try await createRemoteDirectoryIfNeeded(sftp: sftp, path: remoteDir)
        }

        // Open local file for reading
        let fileURL = URL(fileURLWithPath: localPath)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw SCPError.localIOError(path: localPath, underlying: error)
        }

        defer {
            try? handle.close()
        }

        // Open remote file for writing
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: [.create, .write, .truncate])
        } catch {
            throw SCPError.from(sftpError: error, path: remotePath)
        }

        // Stream data in chunks (pipelined for large files)
        do {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size]) as? UInt64
            let baseBytesTransferred = progress.bytesTransferred
            try await PipelinedTransfer.uploadFile(file: file, from: handle, fileSize: fileSize) { currentFileBytes in
                self.progress.bytesTransferred = baseBytesTransferred + currentFileBytes
                self.emitProgress()
            }

            try await file.close()
        } catch is CancellationError {
            try? await file.close()
            throw SCPError.cancelled
        } catch let error as PipelinedTransfer.LocalIOError {
            try? await file.close()
            throw SCPError.localIOError(path: localPath, underlying: error.underlying)
        } catch let error as SCPError {
            try? await file.close()
            throw error
        } catch {
            try? await file.close()
            throw SCPError.from(sftpError: error, path: remotePath)
        }

        // Force final progress update
        emitProgress(force: true)
    }

    private func downloadFile(sftp: SFTPClient, remotePath: String, localPath: String) async throws {
        Self.logger.info("Downloading \(remotePath) -> \(localPath)")

        // Ensure local directory exists
        let localDir = (localPath as NSString).deletingLastPathComponent
        if !localDir.isEmpty {
            try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        }

        // Create local file for writing
        let fileURL = URL(fileURLWithPath: localPath)
        FileManager.default.createFile(atPath: localPath, contents: nil)

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
        } catch {
            throw SCPError.localIOError(path: localPath, underlying: error)
        }

        defer {
            try? handle.close()
        }

        // Open remote file for reading
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: .read)
        } catch {
            throw SCPError.from(sftpError: error, path: remotePath)
        }

        // Stream data in chunks (pipelined for large files)
        do {
            let attrs = try? await file.readAttributes()
            let baseBytesTransferred = progress.bytesTransferred
            try await PipelinedTransfer.downloadFile(file: file, fileSize: attrs?.size, to: handle) { currentFileBytes in
                self.progress.bytesTransferred = baseBytesTransferred + currentFileBytes
                self.emitProgress()
            }

            try await file.close()
        } catch is CancellationError {
            try? await file.close()
            throw SCPError.cancelled
        } catch let error as PipelinedTransfer.LocalIOError {
            try? await file.close()
            throw SCPError.localIOError(path: localPath, underlying: error.underlying)
        } catch let error as SCPError {
            try? await file.close()
            throw error
        } catch {
            try? await file.close()
            throw SCPError.from(sftpError: error, path: remotePath)
        }

        // Force final progress update
        emitProgress(force: true)
    }

    // MARK: - Directory Operations

    private func createRemoteDirectoryIfNeeded(sftp: SFTPClient, path: String) async throws {
        try await SFTPOperations.createDirectoryIfNeeded(sftp: sftp, path: path)
    }

    private func enumerateLocalDirectory(_ path: String) throws -> [String] {
        var results: [String] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            throw SCPError.fileNotFound(path: path)
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = joinLocalPath(path, relativePath)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                results.append(fullPath)
            }
        }

        return results
    }

    private func enumerateRemoteDirectory(sftp: SFTPClient, path: String) async throws -> [(path: String, size: UInt64)] {
        try await SFTPOperations.enumerateRemoteDirectory(sftp: sftp, path: path)
    }

    private func isDirectory(_ attrs: SFTPFileAttributes) -> Bool {
        SFTPOperations.isDirectory(attrs)
    }

    // MARK: - Glob Expansion

    private func containsGlob(_ path: String) -> Bool {
        SFTPOperations.containsGlob(path)
    }

    /// Expand glob patterns on remote path
    private func expandRemoteGlob(sftp: SFTPClient, pattern: String) async throws -> [String] {
        let (rawDirectory, filePattern) = splitPathPattern(pattern)

        // Expand tilde in directory path before listing
        let directory = try await expandRemotePath(sftp: sftp, path: rawDirectory)

        Self.logger.info("Expanding glob: dir=\(directory) pattern=\(filePattern)")

        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: directory)
        } catch {
            throw SCPError.remoteGlobFailed(pattern: pattern)
        }

        var matchingPaths: [String] = []
        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                if SFTPOperations.matchesGlob(filename, pattern: filePattern) {
                    matchingPaths.append(joinRemotePath(directory, filename))
                }
            }
        }

        Self.logger.info("Glob expansion found \(matchingPaths.count) matches")
        return matchingPaths
    }

    private func splitPathPattern(_ path: String) -> (directory: String, pattern: String) {
        SFTPOperations.splitGlobPattern(path)
    }

    private func matchesGlob(_ name: String, pattern: String) -> Bool {
        SFTPOperations.matchesGlob(name, pattern: pattern)
    }

    // MARK: - Path Utilities

    /// Expand remote path, resolving ~ to home directory via SFTP realpath
    private func expandRemotePath(sftp: SFTPClient, path: String) async throws -> String {
        guard path.hasPrefix("~") else { return path }

        // Get home directory using "." (current dir on fresh SFTP connection is usually home)
        let homePath = try await sftp.getRealPath(atPath: ".")
        Self.logger.debug("SFTP home directory (via '.'): \(homePath)")

        if path == "~" {
            return homePath
        } else if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))  // Remove "~/"
            if suffix.isEmpty {
                return homePath
            }
            let result = homePath + "/" + suffix
            Self.logger.debug("Expanded '\(path)' to '\(result)'")
            return result
        }

        // ~otheruser syntax - not supported
        Self.logger.warning("Unsupported tilde syntax: \(path)")
        return path
    }

    private func expandLocalPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") {
            return path
        }
        // Relative path - expand from current directory
        return FileManager.default.currentDirectoryPath + "/" + path
    }

    private func joinLocalPath(_ base: String, _ component: String) -> String {
        if component.isEmpty { return base }
        if component.hasPrefix("/") {
            return (base as NSString).appendingPathComponent(String(component.dropFirst()))
        }
        return (base as NSString).appendingPathComponent(component)
    }

    private func joinRemotePath(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    // MARK: - Progress & Cleanup

    private func updateProgress(_ state: SCPTransferProgress.State) {
        progress.state = state
        onProgress?(progress)
    }

    /// Throttled progress emission to avoid overwhelming the UI during transfers
    private func emitProgress(force: Bool = false) {
        let now = Date()
        let bytesSinceLast = progress.bytesTransferred - lastProgressBytes
        if !force &&
            now.timeIntervalSince(lastProgressEmit) < progressEmitInterval &&
            bytesSinceLast < progressEmitBytesInterval {
            return
        }
        lastProgressEmit = now
        lastProgressBytes = progress.bytesTransferred
        onProgress?(progress)
    }

    /// Reset progress tracking for a new transfer
    private func resetProgressTracking() {
        lastProgressEmit = .distantPast
        lastProgressBytes = 0
    }

    private func cleanup() {
        Task {
            try? await sftpClient?.close()
            try? await sshClient?.close()
            try? await jumpClient?.close()
        }
        sftpClient = nil
        sshClient = nil
        jumpClient = nil
    }

    nonisolated deinit {
        // Cannot call async cleanup from deinit
        // cleanup() should be called explicitly before deallocation
    }
}
