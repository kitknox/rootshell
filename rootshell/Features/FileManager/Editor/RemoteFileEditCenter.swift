//
//  RemoteFileEditCenter.swift
//  rootshell
//
//  App-wide coordinator for editing remote files in external or embedded
//  editors with auto-upload on save, plus the shared fetch/upload/conflict
//  primitives used by both the in-app and external editors.
//
//  Watches local working copies using three complementary mechanisms:
//  1. DispatchSourceFileSystemObject on the file AND its owned staging folder
//     (catches both in-place writes and atomic temp-file+rename saves).
//  2. NSFilePresenter via NSFileCoordinator (catches coordinated NSDocument
//     saves on macOS and external-app saves in iCloud Drive / Files on iPadOS;
//     unregistered while backgrounded on iOS/iPadOS per NSFilePresenter guidance).
//  3. App activation sweeps (catches saves made while iOS/iPadOS suspended us).
//

import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import UIKit
import os.log

enum RemoteEditError: LocalizedError {
    case tooLarge(limitBytes: Int64)
    case isDirectory
    case unreadable
    case remoteModified(RemoteFileFingerprint?)
    case remoteDeleted
    case stagingUnavailable(directory: String, fileName: String)
    case recoveryConflict(targetPath: String, backupPath: String, stagedPath: String?)
    case targetChanged(fileName: String)
    case unpinnedPrivilegedTarget(directory: String, fileName: String)
    case principalChanged(fileName: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            let formatted = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return String(localized: "This file is larger than the \(formatted) editing limit.", comment: "File editor error; argument is a formatted size")
        case .isDirectory:
            return String(localized: "Folders can't be opened or replaced by the file editor.", comment: "File editor error")
        case .unreadable:
            return String(localized: "This file can't be opened for editing.", comment: "File editor error")
        case .remoteModified:
            return String(localized: "This file changed on the server since it was opened.", comment: "File editor conflict error")
        case .remoteDeleted:
            return String(localized: "This file was deleted or renamed on the server since it was opened.", comment: "File editor conflict error")
        case .stagingUnavailable(let directory, let fileName):
            return String(localized: "Couldn't stage a temporary file in “\(directory)” before saving “\(fileName)”, so the original file was left untouched.", comment: "File editor safe-staging error; arguments are folder path and file name")
        case .recoveryConflict(let targetPath, let backupPath, let stagedPath):
            let fileName = FileTransferLogic.lastComponent(of: targetPath)
            let backupName = FileTransferLogic.lastComponent(of: backupPath)
            if let stagedPath {
                let stagedName = FileTransferLogic.lastComponent(of: stagedPath)
                return String(localized: "A previous save of “\(fileName)” was interrupted and another file now exists at that path. Both the backup (“\(backupName)”) and your staged edit (“\(stagedName)”) were preserved in the same folder. Inspect or remove the backup before editing again.", comment: "File editor recovery conflict error with both backup and staged file")
            }
            return String(localized: "A previous save of “\(fileName)” was interrupted and the file at that path no longer matches the staged edit. The original backup (“\(backupName)”) was preserved in the same folder. Inspect or remove the backup before editing again.", comment: "File editor recovery conflict error with preserved backup")
        case .targetChanged(let fileName):
            return String(localized: "“\(fileName)” now points to a different file, or its owner changed, since it was opened, so it wasn't saved. Reopen it to edit the current file.", comment: "File editor error when the path was redirected or replaced; argument is file name")
        case .unpinnedPrivilegedTarget(let directory, let fileName):
            return String(localized: "“\(fileName)” wasn't saved as root because other users can rename entries in “\(directory)”, which could redirect the save to another file. Close this edit, then open the file again as its owner.", comment: "File editor error refusing a root save in a directory other users can modify; arguments are folder path and file name")
        case .principalChanged(let fileName):
            return String(localized: "“\(fileName)” wasn't saved because the connection's account or credentials changed since it was opened. Close this edit, then open the file again.", comment: "File editor error when the saved connection or storage credentials were edited during an edit; argument is file name")
        }
    }
}

/// Bytes fetched for an edit, with the connection principal that served them.
nonisolated struct FetchedRemoteFile: Sendable {
    let data: Data
    let fingerprint: RemoteFileFingerprint
    let principal: EditPrincipal
}

extension SSHConfig {
    /// This config's login for `FileEditRecoveryKey`: host, port, user, and the full jump
    /// chain, so two hosts behind different bastions never share recovery records.
    var fileEditLogin: FileEditRecoveryKey.Login {
        FileEditRecoveryKey.Login(
            host: host,
            port: port,
            username: username,
            jumpHops: jumpChain.map { FileEditRecoveryKey.JumpHop(host: $0.host, port: $0.port, username: $0.username) },
            cachedIP: cachedIP
        )
    }
}

extension FileEndpoint {
    /// The principal a connection opened now should serve, mirroring `SFTPConnectionFactory`:
    /// a pane that can lend its connection uses its own login; a closed or Mosh pane falls back
    /// to its saved profile. Only decides reuse; reads and writes bind to the connection's own
    /// `principal`.
    var predictedPrincipal: EditPrincipal {
        if isLocal { return .local }
        if case .storage(let id) = self {
            return EditPrincipal(key: storageProvider?.principalIdentity ?? "storage-missing:\(id.uuidString)")
        }
        guard let login = predictedLogin else { return EditPrincipal(key: "unavailable:\(displayName)") }
        return EditPrincipal(login: login, isSudo: isSudo)
    }

    private var predictedLogin: FileEditRecoveryKey.Login? {
        switch self {
        case .local, .storage:
            return nil
        case .profile(let id):
            return ConnectionProfileManager.shared.profile(for: id)?.sshConfig.fileEditLogin
        case .pane(let source):
            if !SFTPConnectionFactory.canBorrowPane(source), let id = source.fallbackProfileID,
               let profile = ConnectionProfileManager.shared.profile(for: id) {
                return profile.sshConfig.fileEditLogin
            }
            return source.fallbackConfig.underlyingSSHConfig?.fileEditLogin
        case .sudo(let base):
            return base.predictedLogin
        }
    }
}

// MARK: - Coordinated File Presenter

/// Bridges NSFileCoordinator's `presentedItemDidChange()` to the main actor.
private final class CoordinatedFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void
    private let onMove: @Sendable (URL) -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void, onMove: @escaping @Sendable (URL) -> Void) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.name = "com.rootshell.remoteEditPresenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
        self.onMove = onMove
        super.init()
    }

    nonisolated func presentedItemDidChange() {
        onChange()
    }

    nonisolated func presentedItemDidMove(to newURL: URL) {
        onMove(newURL)
    }
}

// MARK: - Remote Edit Session

@MainActor
@Observable
final class RemoteEditSession: Identifiable {
    enum ConflictKind: Equatable {
        case modified(RemoteFileFingerprint?)
        case deleted
    }

    enum State: Equatable {
        case watching
        case uploading
        case synced(Date)
        case conflict(ConflictKind)
        case error(String)
        /// Staging folder still holds extra/editor swap files (e.g., an open Vim `.swp`).
        /// Kept separate from upload `.error` so closing the editor and clicking Stop again
        /// re-checks the folder and succeeds cleanly.
        case stagingFilesRemaining(String)

        var needsAttention: Bool {
            switch self {
            case .conflict, .error, .stagingFilesRemaining: true
            case .watching, .uploading, .synced: false
            }
        }

        /// True when an unresolved upload conflict or upload error must block `flushAndStop()`
        /// instead of re-checking disk/staging.
        var blocksStopCheck: Bool {
            switch self {
            case .conflict, .error: true
            case .watching, .uploading, .synced, .stagingFilesRemaining: false
            }
        }
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "RemoteFileEdit")

    let id = UUID()
    let endpoint: FileEndpoint
    /// The serving connection's `principal` when the working copy was fetched.
    let principal: EditPrincipal
    let remotePath: String
    let fileName: String
    private(set) var localURL: URL
    /// True when `localURL` is a security-scoped URL outside our private staging directory.
    private(set) var holdsSecurityScope: Bool
    /// The exact private staging folder created under `Caches/FileManagerEdits/<uuid>/`,
    /// stored immutably so moving `localURL` elsewhere can never cause cleanup to delete a user folder.
    private let ownedStagingDirectory: URL?
    var editorName: String?
    /// App explicitly chosen through Open With on macOS, reused when the edit is reopened.
    var editorAppURL: URL?
    /// Set when the file is being edited in a bundled terminal editor (`vim` / `hx`) on iOS/iPadOS/visionOS.
    var embeddedEditor: FileManagerEmbeddedEditor?

    private(set) var state: State = .watching
    private(set) var lastSyncedAt: Date?
    private(set) var uploadCount = 0

    @ObservationIgnored private var prompts: FileManagerPrompts
    @ObservationIgnored private var lastSyncedHash: Data
    @ObservationIgnored private var remoteFingerprint: RemoteFileFingerprint?
    @ObservationIgnored private var fileSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var dirSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var presenter: CoordinatedFilePresenter?
    @ObservationIgnored private var presenterSuspended = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Bool, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pendingResync = false
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var onUploadCompleted: ((FileEndpoint, String) -> Void)?

    init(
        endpoint: FileEndpoint,
        principal: EditPrincipal,
        remotePath: String,
        fileName: String,
        localURL: URL,
        initialHash: Data,
        remoteFingerprint: RemoteFileFingerprint?,
        holdsSecurityScope: Bool,
        ownedStagingDirectory: URL?,
        editorName: String?,
        embeddedEditor: FileManagerEmbeddedEditor? = nil,
        prompts: FileManagerPrompts,
        onUploadCompleted: @escaping (FileEndpoint, String) -> Void
    ) {
        self.endpoint = endpoint
        self.principal = principal
        self.remotePath = remotePath
        self.fileName = fileName
        self.localURL = localURL
        self.lastSyncedHash = initialHash
        self.remoteFingerprint = remoteFingerprint
        self.holdsSecurityScope = holdsSecurityScope
        self.ownedStagingDirectory = ownedStagingDirectory
        self.editorName = editorName
        self.embeddedEditor = embeddedEditor
        self.prompts = prompts
        self.onUploadCompleted = onUploadCompleted

        FileConnectionPool.shared.retain(endpoint)
        installWatchers()
    }

    var ownsStagingDirectory: Bool { ownedStagingDirectory != nil }

    /// Whether a save would pass `requirePrincipal` now: false once `endpoint` would connect
    /// under any other login key (an edited profile or provider, even to an alias of the same
    /// host, or a pane falling back to its profile). Decides whether a session may be reused.
    var hasCurrentPrincipal: Bool {
        FileConnectionPool.shared.expectedPrincipal(for: endpoint).key == principal.key
    }

    /// The working copy only ever goes back through a connection serving the exact login it
    /// came from; aliases only help find a session, never relax this.
    private func requirePrincipal(_ served: EditPrincipal) throws {
        guard served.key == principal.key else { throw RemoteEditError.principalChanged(fileName: fileName) }
    }

    var remoteDisplayPath: String {
        "\(endpoint.displayName):\(remotePath)"
    }

    private func effectivePrompts(override: FileManagerPrompts? = nil) -> FileManagerPrompts {
        if let override, !override.isCancelled {
            prompts = override
            return override
        }
        let resolved = RemoteFileEditCenter.shared.resolveLivePrompts(preferring: prompts)
        prompts = resolved
        return resolved
    }

    /// Checks the local file for edits and uploads them with full conflict protection.
    /// `evenIfUnchanged` forces an upload attempt even when the local digest matches `lastSyncedHash`,
    /// but NEVER bypasses remote revision conflict checks.
    func checkForLocalChanges(evenIfUnchanged: Bool = false, prompts overridePrompts: FileManagerPrompts? = nil) {
        guard !isStopped else { return }
        if let overridePrompts, !overridePrompts.isCancelled {
            prompts = overridePrompts
        }
        if isStopping {
            pendingResync = true
            return
        }
        if case .conflict = state { return }
        debounceTask?.cancel()
        debounceTask = nil
        if uploadTask != nil {
            pendingResync = true
            return
        }
        startSync(forceOverwrite: false, requireChange: !evenIfUnchanged)
    }

    /// Resolves a remote conflict by explicitly overwriting (or recreating) the remote file.
    func resolveConflictByOverwriting(prompts overridePrompts: FileManagerPrompts? = nil) {
        guard !isStopped else { return }
        if let overridePrompts, !overridePrompts.isCancelled {
            prompts = overridePrompts
        }
        debounceTask?.cancel()
        debounceTask = nil
        if uploadTask != nil {
            pendingResync = true
            return
        }
        startSync(forceOverwrite: true, requireChange: false)
    }

    /// Resolves a remote conflict by pulling the server's latest copy into the local file.
    func resolveConflictByReloading(prompts overridePrompts: FileManagerPrompts? = nil) {
        guard !isStopped else { return }
        let activePrompts = effectivePrompts(override: overridePrompts)
        debounceTask?.cancel()
        debounceTask = nil
        uploadTask?.cancel()
        state = .uploading
        let endpoint = endpoint
        let remotePath = remotePath
        let localURL = localURL
        uploadTask = Task { [weak self] in
            defer { self?.uploadTask = nil }
            do {
                let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                    for: endpoint, purpose: .transfer, prompts: activePrompts
                )
                try self?.requirePrincipal(served)
                let (data, fingerprint) = try await RemoteFileEditCenter.fetchRemoteFile(
                    path: remotePath,
                    fs: fs,
                    endpointKey: served.key,
                    maxBytes: FileEditClassification.maxExternalEditBytes
                )
                try await Self.writeCoordinated(data, to: localURL)
                guard let self, !self.isStopped else { return }
                self.lastSyncedHash = EditableTextDocument.contentDigest(data)
                self.remoteFingerprint = fingerprint
                self.state = .watching
                self.updateStagingManifest(hasPendingUpload: false)
                self.rearmFileSource()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isStopped else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    /// Suspends NSFilePresenter while backgrounded on iOS/iPadOS so coordinated reads/writes
    /// in foreground external editors never block waiting on a suspended Rootshell process.
    func suspendFilePresenter() {
        guard !isStopped, !presenterSuspended else { return }
        presenterSuspended = true
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    /// Restores NSFilePresenter when returning to the foreground on iOS/iPadOS.
    func resumeFilePresenter() {
        guard !isStopped, presenterSuspended else { return }
        presenterSuspended = false
        registerFilePresenterIfNeeded()
    }

    /// Serializes stopping with the watcher and keeps uploading until the file currently on disk
    /// is confirmed to match `lastSyncedHash` with no intervening saves or errors. Returns `true`
    /// only when cleanly synced and stopped, or `false` (leaving the working copy intact) on conflict/error.
    func flushAndStop(prompts overridePrompts: FileManagerPrompts? = nil) async -> Bool {
        if let overridePrompts, !overridePrompts.isCancelled {
            prompts = overridePrompts
        }
        if isStopped { return true }
        if let existingStop = stopTask {
            return await existingStop.value
        }

        let task = Task<Bool, Never> { @MainActor in
            defer { self.stopTask = nil }
            self.isStopping = true

            while !self.isStopped {
                if self.state.blocksStopCheck {
                    self.isStopping = false
                    return false
                }
                self.debounceTask?.cancel()
                self.debounceTask = nil

                if let existingUpload = self.uploadTask {
                    await existingUpload.value
                    if self.isStopped { return true }
                    if self.state.blocksStopCheck {
                        self.isStopping = false
                        return false
                    }
                }

                // Clear pendingResync BEFORE reading disk so any new event arriving during
                // readCoordinated sets it back to true and triggers another pass.
                self.pendingResync = false

                let latestData: Data?
                do {
                    latestData = try await Self.readCoordinated(from: self.localURL)
                } catch {
                    self.state = .error(error.localizedDescription)
                    self.isStopping = false
                    return false
                }

                if self.isStopped { return true }

                guard let latestData else {
                    if !self.pendingResync && self.uploadTask == nil {
                        break
                    }
                    continue
                }

                let latestDigest = EditableTextDocument.contentDigest(latestData)
                if latestDigest == self.lastSyncedHash && !self.pendingResync && self.uploadTask == nil {
                    // Confirmed quiescent: on-disk bytes match the uploaded revision and no
                    // watcher event arrived during verification.
                    break
                }

                // Upload the latest bytes, then loop back to re-verify on-disk state.
                self.pendingResync = false
                self.startSync(forceOverwrite: false, requireChange: false)
            }

            if self.isStopped { return true }

            // Before deleting the staging folder on a clean stop, perform the same full-directory
            // check used on relaunch so open editor swap files (e.g., Vim `.swp`) or extra files
            // in the staging folder are never silently deleted.
            if let stagingDir = self.ownedStagingDirectory {
                let expectedName: String? = (self.localURL.standardizedFileURL.deletingLastPathComponent().path == stagingDir.standardizedFileURL.path)
                    ? self.localURL.lastPathComponent
                    : nil
                if !FileEditStagingCleanup.directoryContainsOnly(expectedName, in: stagingDir) {
                    self.state = .stagingFilesRemaining(String(localized: "Extra or editor swap files remain in the staging folder (such as an open Vim swap file). Save and close the editor before stopping, or discard explicitly.", comment: "File editor stop blocked by extra staging files"))
                    self.isStopping = false
                    return false
                }
            }

            self.forceStopAndCleanup()
            return true
        }
        stopTask = task
        return await task.value
    }

    /// Unconditionally stops watching, releases the pooled connection, and deletes ONLY
    /// the original private staging directory created for this session (never a user folder).
    func forceStopAndCleanup() {
        guard !isStopped else { return }
        isStopped = true
        isStopping = false
        debounceTask?.cancel(); debounceTask = nil
        uploadTask?.cancel(); uploadTask = nil
        endUploadBackgroundTask()
        teardownWatchers()
        if holdsSecurityScope {
            localURL.stopAccessingSecurityScopedResource()
            holdsSecurityScope = false
        }
        FileConnectionPool.shared.release(endpoint)
        if let stagingDir = ownedStagingDirectory {
            RemoteFileEditCenter.removeStagingDirectory(stagingDir)
        }
    }

    private func updateStagingManifest(hasPendingUpload: Bool) {
        guard let stagingDir = ownedStagingDirectory,
              FileEditStagingPath.isDirectChild(stagingDir, of: RemoteFileEditCenter.stagingRoot) else { return }
        let manifest = StagingFolderManifest(
            folderName: stagingDir.lastPathComponent,
            fileName: fileName,
            lastSyncedHashHex: FileEditStagingCleanup.hexDigest(lastSyncedHash),
            hasPendingUpload: hasPendingUpload,
            endpointDisplayName: endpoint.displayName,
            remotePath: remotePath
        )
        FileEditStagingCleanup.writeManifest(manifest, in: RemoteFileEditCenter.stagingRoot)
    }

    // MARK: - Watching

    private func installWatchers() {
        teardownWatchers()
        guard !isStopped else { return }

        if let stagingDir = ownedStagingDirectory,
           localURL.standardizedFileURL.deletingLastPathComponent().path == stagingDir.standardizedFileURL.path {
            dirSource = makeDispatchSource(path: stagingDir.path, mask: [.write, .rename, .link]) { [weak self] in
                self?.scheduleDebouncedCheck(rearmFile: true)
            }
        }
        rearmFileSource()
        if !presenterSuspended {
            registerFilePresenterIfNeeded()
        }
    }

    private func registerFilePresenterIfNeeded() {
        guard !isStopped, presenter == nil else { return }
        let filePresenter = CoordinatedFilePresenter(
            url: localURL,
            onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedCheck(rearmFile: true)
                }
            },
            onMove: { [weak self] newURL in
                Task { @MainActor [weak self] in
                    self?.handlePresentedMove(to: newURL)
                }
            }
        )
        NSFileCoordinator.addFilePresenter(filePresenter)
        presenter = filePresenter
    }

    private func rearmFileSource() {
        fileSource?.cancel()
        fileSource = nil
        guard !isStopped, FileManager.default.fileExists(atPath: localURL.path) else { return }
        fileSource = makeDispatchSource(
            path: localURL.path,
            mask: [.write, .extend, .attrib, .rename, .delete, .revoke]
        ) { [weak self] in
            self?.scheduleDebouncedCheck(rearmFile: true)
        }
    }

    private func teardownWatchers() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    private func handlePresentedMove(to newURL: URL) {
        guard !isStopped, newURL != localURL else { return }
        if holdsSecurityScope {
            localURL.stopAccessingSecurityScopedResource()
            holdsSecurityScope = newURL.startAccessingSecurityScopedResource()
        }
        localURL = newURL
        // ownedStagingDirectory stays immutable — moving the file into a user directory
        // will never cause cleanup to delete that directory.
        installWatchers()
        scheduleDebouncedCheck(rearmFile: false)
    }

    private func makeDispatchSource(
        path: String,
        mask: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleDebouncedCheck(rearmFile: Bool) {
        guard !isStopped else { return }
        if rearmFile { rearmFileSource() }
        if isStopping {
            // Let the active flushAndStop() loop observe and upload this save instead of racing it.
            pendingResync = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.debounceTask = nil
            if self.isStopping {
                self.pendingResync = true
                return
            }
            if rearmFile { self.rearmFileSource() }
            if case .conflict = self.state { return }
            if self.uploadTask != nil {
                self.pendingResync = true
                return
            }
            self.startSync(forceOverwrite: false, requireChange: true)
        }
    }

    // MARK: - Sync & Upload

    private func startSync(forceOverwrite: Bool, requireChange: Bool) {
        let localURL = localURL
        let endpoint = endpoint
        let remotePath = remotePath
        let activePrompts = effectivePrompts()
        let previousHash = lastSyncedHash
        let expectedFingerprint = remoteFingerprint

        uploadTask = Task { [weak self] in
            self?.beginUploadBackgroundTask()
            defer { self?.endUploadBackgroundTask() }

            do {
                guard let data = try await Self.readCoordinated(from: localURL) else {
                    self?.finishUploadCycle()
                    return
                }
                let digest = EditableTextDocument.contentDigest(data)
                if requireChange && digest == previousHash {
                    if let self, case .stagingFilesRemaining = self.state, let stagingDir = self.ownedStagingDirectory {
                        let expectedName: String? = (self.localURL.standardizedFileURL.deletingLastPathComponent().path == stagingDir.standardizedFileURL.path)
                            ? self.localURL.lastPathComponent
                            : nil
                        if FileEditStagingCleanup.directoryContainsOnly(expectedName, in: stagingDir) {
                            self.state = self.lastSyncedAt.map { .synced($0) } ?? .watching
                        }
                    }
                    self?.finishUploadCycle()
                    return
                }
                guard let self, !self.isStopped else { return }
                self.state = .uploading
                self.updateStagingManifest(hasPendingUpload: true)

                let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                    for: endpoint, purpose: .transfer, prompts: activePrompts
                )
                try self.requirePrincipal(served)
                let newFingerprint = try await RemoteFileEditCenter.uploadData(
                    data,
                    to: remotePath,
                    on: fs,
                    endpointKey: served.key,
                    expectedFingerprint: expectedFingerprint,
                    forceOverwrite: forceOverwrite
                )
                guard !self.isStopped else { return }
                let now = Date()
                self.lastSyncedHash = digest
                self.remoteFingerprint = newFingerprint
                self.lastSyncedAt = now
                self.uploadCount += 1
                self.state = .synced(now)
                self.updateStagingManifest(hasPendingUpload: false)
                self.onUploadCompleted?(endpoint, remotePath)
                Self.logger.info("Auto-uploaded \(remotePath, privacy: .private) (\(data.count) bytes)")
                self.finishUploadCycle()
            } catch is CancellationError {
                self?.uploadTask = nil
            } catch RemoteEditError.remoteModified(let current) {
                guard let self, !self.isStopped else { return }
                self.state = .conflict(.modified(current))
                self.uploadTask = nil
                self.pendingResync = false
            } catch RemoteEditError.remoteDeleted {
                guard let self, !self.isStopped else { return }
                self.state = .conflict(.deleted)
                self.uploadTask = nil
                self.pendingResync = false
            } catch {
                guard let self, !self.isStopped else { return }
                Self.logger.error("Auto-upload failed for \(remotePath, privacy: .private): \(error.localizedDescription, privacy: .public)")
                self.state = .error(error.localizedDescription)
                self.uploadTask = nil
                self.pendingResync = false
            }
        }
    }

    private func finishUploadCycle() {
        uploadTask = nil
        // Honor any save notification that arrived while reading or uploading (even if the
        // completed check saw unchanged bytes before the newer save finished). When stopping,
        // flushAndStop() owns the re-check loop so it stays serialized.
        if !isStopping && pendingResync && !isStopped {
            pendingResync = false
            startSync(forceOverwrite: false, requireChange: true)
        }
    }

    private func beginUploadBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Upload edited file") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endUploadBackgroundTask()
            }
        }
    }

    private func endUploadBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func readCoordinated(from url: URL) async throws -> Data? {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var coordError: NSError?
            var readResult: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                readResult = Result { try Data(contentsOf: readURL) }
            }
            if let coordError { throw coordError }
            return try readResult?.get()
        }.value
    }

    private static func writeCoordinated(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do {
                    try data.write(to: writeURL, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let writeError { throw writeError }
            if let coordError { throw coordError }
        }.value
    }
}

// MARK: - App-Wide Center

@MainActor
@Observable
final class RemoteFileEditCenter {
    static let shared = RemoteFileEditCenter()

    private static let logger = Logger(subsystem: "com.rootshell", category: "RemoteFileEdit")

    /// Staging root under Application Support (excluded from backup) so unsynced local working
    /// copies survive app relaunch and OS cache pressure. Never recursively deleted on startup.
    fileprivate static let stagingRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("FileManagerEdits", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// Safely removes a single direct child folder of `stagingRoot` along with its sync manifest.
    static func removeStagingDirectory(_ directory: URL) {
        guard FileEditStagingPath.isDirectChild(directory, of: stagingRoot) else { return }
        try? FileManager.default.removeItem(at: directory)
        FileEditStagingCleanup.removeManifest(forFolderName: directory.lastPathComponent, in: stagingRoot)
    }

    struct RecoveryConflictNotice: Identifiable, Equatable {
        let id: String
        let endpointDisplayName: String
        let targetPath: String
        let backupPath: String
        let stagedPath: String?
        let message: String

        var fileName: String { FileTransferLogic.lastComponent(of: targetPath) }
    }

    private(set) var sessions: [RemoteEditSession] = []
    private(set) var recoveryConflicts: [RecoveryConflictNotice] = []
    /// Working copies from a previous launch whose local edits were never confirmed uploaded.
    private(set) var preservedEdits: [PreservedUnsyncedEdit] = []

    private struct WeakPrompts {
        weak var value: FileManagerPrompts?
    }

    @ObservationIgnored private var uploadObservers: [UUID: AsyncStream<(FileEndpoint, String)>.Continuation] = [:]
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    /// Tracks in-flight external/embedded opens so overlapping clicks cannot race and clobber
    /// each other's working copies before session registration completes.
    @ObservationIgnored private var inFlightOpens: [(id: UUID, principal: EditPrincipal, remotePath: String)] = []
    /// Live prompt handlers owned by currently open File Manager windows, so an app-wide edit
    /// session whose originating window closed can still reauthenticate through a surviving window.
    @ObservationIgnored private var livePrompts: [WeakPrompts] = []

    private init() {
        // Only prune folders proven cleanly synced; preserve any unsynced edits from prior launches.
        preservedEdits = FileEditStagingCleanup.pruneSyncedFolders(in: Self.stagingRoot)
        installLifecycleObservers()
    }

    func registerLivePrompts(_ prompts: FileManagerPrompts) {
        livePrompts.removeAll { $0.value == nil || $0.value === prompts }
        livePrompts.append(WeakPrompts(value: prompts))
    }

    func unregisterLivePrompts(_ prompts: FileManagerPrompts) {
        livePrompts.removeAll { $0.value == nil || $0.value === prompts }
    }

    /// Returns a live (non-cancelled) prompt handler, preferring `preferred` when still active,
    /// otherwise routing through the most recently registered surviving window's handler.
    func resolveLivePrompts(preferring preferred: FileManagerPrompts?) -> FileManagerPrompts {
        if let preferred, !preferred.isCancelled {
            return preferred
        }
        livePrompts.removeAll { $0.value == nil || $0.value?.isCancelled == true }
        if let fallback = livePrompts.last?.value {
            return fallback
        }
        return preferred ?? FileManagerPrompts()
    }

    var hasActiveSessions: Bool { !sessions.isEmpty }
    var hasVisibleBarItems: Bool { !sessions.isEmpty || !recoveryConflicts.isEmpty || !preservedEdits.isEmpty }
    var hasActiveUploads: Bool { sessions.contains { $0.state == .uploading } }
    var hasAttentionItems: Bool {
        !recoveryConflicts.isEmpty || !preservedEdits.isEmpty || sessions.contains { $0.state.needsAttention }
    }

    /// Writes an in-app editor's unsaved text to its own staging folder, with a manifest
    /// marking it unsynced so relaunch cleanup keeps it. Returns the folder, or nil if
    /// nothing was written. Not listed in `preservedEdits` until adopted.
    func writeEditorRecoveryCopy(_ data: Data, fileName: String, endpoint: FileEndpoint, remotePath: String) -> URL? {
        do {
            return try Self.writeStagedFile(
                data, named: Self.recoveryFileName(for: fileName), endpoint: endpoint,
                remotePath: remotePath, syncedDigest: nil
            ).deletingLastPathComponent()
        } catch {
            Self.logger.error("Couldn't write a recovery copy of \(fileName, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes `data` into a fresh staging folder with its manifest and returns the file.
    /// A nil `syncedDigest` marks it unsynced, so relaunch cleanup always keeps it.
    private static func writeStagedFile(
        _ data: Data, named fileName: String, endpoint: FileEndpoint, remotePath: String, syncedDigest: Data?
    ) throws -> URL {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            removeStagingDirectory(folder)
            throw error
        }
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: folder.lastPathComponent,
                fileName: fileName,
                lastSyncedHashHex: syncedDigest.map { FileEditStagingCleanup.hexDigest($0) } ?? "",
                hasPendingUpload: syncedDigest == nil,
                endpointDisplayName: endpoint.displayName,
                remotePath: remotePath
            ),
            in: stagingRoot
        )
        return destination
    }

    /// A local name for a recovery copy. Object keys can outgrow a file name (255 bytes)
    /// or hold a slash; the manifest's remotePath keeps the original.
    nonisolated static func recoveryFileName(for name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "recovered.txt" }
        guard cleaned.utf8.count > 200 else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.utf8.count <= 16
        var stem = keepsExtension ? (cleaned as NSString).deletingPathExtension : cleaned
        while stem.utf8.count > 180 { stem.removeLast() }
        return keepsExtension ? "\(stem)….\(ext)" : "\(stem)…"
    }

    /// Offers a recovery copy in the edits bar of every window, for export or discard.
    func adoptEditorRecoveryCopy(_ folder: URL, fileName: String, endpoint: FileEndpoint, remotePath: String) {
        preservedEdits.append(PreservedUnsyncedEdit(
            folderURL: folder,
            files: [folder.appendingPathComponent(Self.recoveryFileName(for: fileName))],
            fileName: fileName,
            endpointDisplayName: endpoint.displayName,
            remotePath: remotePath
        ))
    }

    func discardPreservedEdit(_ edit: PreservedUnsyncedEdit) {
        Self.removeStagingDirectory(edit.folderURL)
        preservedEdits.removeAll { $0.id == edit.id }
    }

    func recordRecoveryConflict(
        endpointDisplayName: String,
        endpointKey: String,
        targetPath: String,
        backupPath: String,
        stagedPath: String?,
        message: String
    ) {
        let id = RemoteEditPathIdentity.key(endpointKey: endpointKey, path: targetPath)
        let notice = RecoveryConflictNotice(
            id: id,
            endpointDisplayName: endpointDisplayName,
            targetPath: targetPath,
            backupPath: backupPath,
            stagedPath: stagedPath,
            message: message
        )
        if let index = recoveryConflicts.firstIndex(where: { $0.id == id }) {
            recoveryConflicts[index] = notice
        } else {
            recoveryConflicts.append(notice)
        }
    }

    func clearRecoveryConflict(endpointKey: String, targetPath: String) {
        let id = RemoteEditPathIdentity.key(endpointKey: endpointKey, path: targetPath)
        recoveryConflicts.removeAll { $0.id == id }
    }

    func dismissRecoveryConflict(_ notice: RecoveryConflictNotice) {
        recoveryConflicts.removeAll { $0.id == notice.id }
    }

    /// The session a reopen through `endpoint` may reuse: same account as `endpoint` would
    /// connect as now, and its own endpoint still connects as the account its copy came from.
    func existingSession(for endpoint: FileEndpoint, remotePath: String) -> RemoteEditSession? {
        session(for: FileConnectionPool.shared.expectedPrincipal(for: endpoint), remotePath: remotePath)
    }

    /// Aliases find a session; only one that can still upload (`hasCurrentPrincipal`) is reused.
    private func session(for principal: EditPrincipal, remotePath: String) -> RemoteEditSession? {
        sessions.first {
            $0.principal.reachesSameAccount(as: principal)
                && RemoteEditPathIdentity.matches($0.remotePath, remotePath)
                && $0.hasCurrentPrincipal
        }
    }

    func isWatching(endpoint: FileEndpoint, path: String) -> Bool {
        existingSession(for: endpoint, remotePath: path) != nil
    }

    /// Claims an exclusive in-flight open slot for `(endpoint, remotePath)`.
    /// Returns a token to pass to `endOpen(token:)`, or `nil` if an open for the same file is already in flight.
    func beginOpen(for endpoint: FileEndpoint, remotePath: String) -> UUID? {
        let principal = FileConnectionPool.shared.expectedPrincipal(for: endpoint)
        guard !inFlightOpens.contains(where: {
            $0.principal.reachesSameAccount(as: principal)
                && RemoteEditPathIdentity.matches($0.remotePath, remotePath)
        }) else {
            return nil
        }
        let token = UUID()
        inFlightOpens.append((id: token, principal: principal, remotePath: remotePath))
        return token
    }

    enum StagedOpenDecision {
        case launch
        case reuse(RemoteEditSession)
        case drop
    }

    /// Re-keys an in-flight open to the principal that actually served its copy, so a missed
    /// prediction can't let a second open launch a competing copy. Call after staging and
    /// before handing the file to an editor; on `.reuse` or `.drop`, discard the staged copy.
    func confirmStagedOpen(token: UUID, servedBy principal: EditPrincipal, remotePath: String) -> StagedOpenDecision {
        if let existing = session(for: principal, remotePath: remotePath) { return .reuse(existing) }
        guard let index = inFlightOpens.firstIndex(where: { $0.id == token }) else { return .drop }
        let covered = inFlightOpens.contains {
            $0.id != token
                && $0.principal.reachesSameAccount(as: principal)
                && RemoteEditPathIdentity.matches($0.remotePath, remotePath)
        }
        if covered { return .drop }
        inFlightOpens[index].principal = principal
        return .launch
    }

    func endOpen(token: UUID) {
        inFlightOpens.removeAll { $0.id == token }
    }

    /// Emits `(endpoint, remotePath)` after every successful upload (in-app or external),
    /// so panes displaying that directory refresh automatically.
    func uploadedFiles() -> AsyncStream<(FileEndpoint, String)> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<(FileEndpoint, String)>.makeStream(bufferingPolicy: .bufferingNewest(32))
        uploadObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.uploadObservers[id] = nil }
        }
        return stream
    }

    func notifyUploaded(endpoint: FileEndpoint, remotePath: String) {
        for observer in uploadObservers.values {
            observer.yield((endpoint, remotePath))
        }
    }

    /// Downloads a remote file into a fresh staging folder so it can be opened in an external
    /// or embedded editor. `principal` is the account that served the bytes, for `registerSession`.
    func stageForExternalEdit(
        entry: RFEntry,
        endpoint: FileEndpoint,
        prompts: FileManagerPrompts,
        preloaded: FetchedRemoteFile? = nil
    ) async throws -> (stagedURL: URL, hash: Data, fingerprint: RemoteFileFingerprint, principal: EditPrincipal) {
        let data: Data
        let fingerprint: RemoteFileFingerprint
        let principal: EditPrincipal
        if let preloaded {
            (data, fingerprint, principal) = (preloaded.data, preloaded.fingerprint, preloaded.principal)
        } else {
            let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                for: endpoint, purpose: .transfer, prompts: prompts
            )
            (data, fingerprint) = try await Self.fetchRemoteFile(
                path: entry.path,
                fs: fs,
                endpointKey: served.key,
                maxBytes: FileEditClassification.maxExternalEditBytes
            )
            principal = served
        }
        let digest = EditableTextDocument.contentDigest(data)
        let destination = try Self.writeStagedFile(
            data, named: entry.name, endpoint: endpoint, remotePath: entry.path, syncedDigest: digest
        )
        return (destination, digest, fingerprint, principal)
    }

    /// Starts watching a staged or externally moved file and auto-uploads every save back to `endpoint`.
    /// Never force-stops or destroys an already-registered session for the same remote file.
    @discardableResult
    func registerSession(
        endpoint: FileEndpoint,
        principal: EditPrincipal,
        remotePath: String,
        fileName: String,
        localURL: URL,
        initialHash: Data,
        remoteFingerprint: RemoteFileFingerprint?,
        holdsSecurityScope: Bool,
        ownsLocalDirectory: Bool,
        editorName: String?,
        embeddedEditor: FileManagerEmbeddedEditor? = nil,
        prompts: FileManagerPrompts
    ) -> RemoteEditSession {
        // Match on who fetched this copy, not who `endpoint` connects as now: it may have changed.
        // A stale session can't upload, so it never absorbs a fresh copy.
        if let existing = session(for: principal, remotePath: remotePath) {
            // Preserve the existing session's working copy; only clean up our redundant staging copy.
            if holdsSecurityScope {
                localURL.stopAccessingSecurityScopedResource()
            }
            let redundantDir = localURL.standardizedFileURL.deletingLastPathComponent()
            if ownsLocalDirectory {
                Self.removeStagingDirectory(redundantDir)
            }
            return existing
        }
        let candidateDir = localURL.standardizedFileURL.deletingLastPathComponent()
        let stagingDir: URL? = ownsLocalDirectory && FileEditStagingPath.isDirectChild(candidateDir, of: Self.stagingRoot)
            ? candidateDir
            : nil
        let session = RemoteEditSession(
            endpoint: endpoint,
            principal: principal,
            remotePath: remotePath,
            fileName: fileName,
            localURL: localURL,
            initialHash: initialHash,
            remoteFingerprint: remoteFingerprint,
            holdsSecurityScope: holdsSecurityScope,
            ownedStagingDirectory: stagingDir,
            editorName: editorName,
            embeddedEditor: embeddedEditor,
            prompts: prompts
        ) { [weak self] endpoint, path in
            self?.notifyUploaded(endpoint: endpoint, remotePath: path)
        }
        sessions.append(session)
        return session
    }

    #if targetEnvironment(macCatalyst)
    /// Launches `stagedURL` in a macOS external app and registers its watch session under app-wide
    /// ownership, holding `openToken` until launch + registration complete even if the initiating
    /// File Manager window closes mid-launch.
    func launchAndRegisterExternalEdit(
        openToken: UUID,
        entry: RFEntry,
        endpoint: FileEndpoint,
        stagedURL: URL,
        hash: Data,
        fingerprint: RemoteFileFingerprint,
        principal: EditPrincipal,
        appURL: URL?,
        prompts: FileManagerPrompts
    ) async throws {
        defer { endOpen(token: openToken) }
        do {
            let appName = try await ExternalEditorBridge.open(stagedURL, withApplication: appURL)
            let activePrompts = resolveLivePrompts(preferring: prompts)
            let session = registerSession(
                endpoint: endpoint,
                principal: principal,
                remotePath: entry.path,
                fileName: entry.name,
                localURL: stagedURL,
                initialHash: hash,
                remoteFingerprint: fingerprint,
                holdsSecurityScope: false,
                ownsLocalDirectory: true,
                editorName: appName,
                prompts: activePrompts
            )
            if let appURL { session.editorAppURL = appURL }
        } catch {
            Self.removeStagingDirectory(stagedURL.deletingLastPathComponent())
            throw error
        }
    }
    #endif

    /// Flushes any pending local save before stopping; returns `false` (leaving the session and
    /// its working copy intact) if there is an unresolved conflict or upload failure.
    @discardableResult
    func requestStop(_ session: RemoteEditSession, prompts: FileManagerPrompts? = nil) async -> Bool {
        let stopped = await session.flushAndStop(prompts: prompts)
        if stopped {
            sessions.removeAll { $0.id == session.id }
        }
        return stopped
    }

    /// Explicitly discards any unsaved/conflicted state and stops watching `session`.
    func forceStop(_ session: RemoteEditSession) {
        session.forceStopAndCleanup()
        sessions.removeAll { $0.id == session.id }
    }

    /// Flushes and stops all clean/uploadable sessions; returns any sessions that could not be
    /// stopped safely because they have conflicts or failed uploads.
    @discardableResult
    func requestStopAll(prompts: FileManagerPrompts? = nil) async -> [RemoteEditSession] {
        let snapshot = sessions
        var remaining: [RemoteEditSession] = []
        for session in snapshot {
            let stopped = await requestStop(session, prompts: prompts)
            if !stopped { remaining.append(session) }
        }
        return remaining
    }

    func forceStopAll() {
        let current = sessions
        sessions = []
        for session in current { session.forceStopAndCleanup() }
    }

    func checkAllSessionsForChanges() {
        for session in sessions {
            session.checkForLocalChanges()
        }
    }

    // MARK: - Shared Fetch & Upload Primitives

    /// Fetches a file's raw bytes and metadata fingerprint from any `FileSystemEndpoint`.
    static func fetchRemoteFile(
        path: String,
        fs: FileSystemEndpoint,
        endpointKey: String,
        maxBytes: Int64
    ) async throws -> (data: Data, fingerprint: RemoteFileFingerprint) {
        // S3 reads bytes pinned to the exact ETag returned by the reader's HEAD/GET.
        if case .s3(let s3) = fs.backend {
            return try await s3.readObjectForEdit(path, maxBytes: maxBytes)
        }

        if case .sftp(let sftp) = fs.backend {
            return try await fetchSFTPFile(path: path, sftp: sftp, endpointKey: endpointKey, maxBytes: maxBytes)
        }

        let info = try await fs.info(path)
        guard !info.isDirectory else { throw RemoteEditError.isDirectory }
        guard Int64(clamping: info.size) <= maxBytes else {
            throw RemoteEditError.tooLarge(limitBytes: maxBytes)
        }

        let reader = try await fs.openReader(path)
        var data = Data()
        if info.size > 0 && info.size <= UInt64(maxBytes) {
            data.reserveCapacity(Int(info.size))
        }
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 262_144
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(at: offset, length: chunkSize)
                if chunk.isEmpty { break }
                if Int64(data.count) + Int64(chunk.count) > maxBytes {
                    throw RemoteEditError.tooLarge(limitBytes: maxBytes)
                }
                data.append(chunk)
                offset += UInt64(chunk.count)
            }
            try? await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }

        let fingerprint = RemoteFileFingerprint(
            size: UInt64(data.count),
            modified: info.modified
        )
        return (data, fingerprint)
    }

    /// Heals any interrupted swap on the resolved path (serialized with any active commit), then
    /// reads it through one handle. Type, size, mtime and owner come from that handle's FSTAT,
    /// so the owner the edit is bound to belongs to the file the bytes came from.
    private static func fetchSFTPFile(
        path: String,
        sftp: SFTPClient,
        endpointKey: String,
        maxBytes: Int64
    ) async throws -> (data: Data, fingerprint: RemoteFileFingerprint) {
        let resolved = try await resolveSFTPTargetPath(path, sftp: sftp, requireConfirmedRegularType: false)
        try await SFTPPathOperationGate.shared.withLock(targetPath: resolved) {
            try await recoverInterruptedSFTPSwapLocked(endpointKey: endpointKey, targetPath: resolved, sftp: sftp)
        }

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: resolved, flags: .read)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }
        do {
            let attrs = try await file.readHandleAttributes()
            if SFTPFileType(permissions: attrs.permissions) == .directory {
                throw RemoteEditError.isDirectory
            }
            if let size = attrs.size, size > UInt64(maxBytes) {
                throw RemoteEditError.tooLarge(limitBytes: maxBytes)
            }
            var data = Data()
            if let size = attrs.size, size > 0 { data.reserveCapacity(Int(size)) }
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                var chunk = try await file.read(from: offset, length: 262_144)
                guard chunk.readableBytes > 0 else { break }
                if Int64(data.count) + Int64(chunk.readableBytes) > maxBytes {
                    throw RemoteEditError.tooLarge(limitBytes: maxBytes)
                }
                offset += UInt64(chunk.readableBytes)
                data.append(chunk.readData(length: chunk.readableBytes) ?? Data())
            }
            try? await file.close()
            let fingerprint = RemoteFileFingerprint(
                size: UInt64(data.count),
                modified: attrs.accessModificationTime?.modificationTime,
                identity: RemoteFileIdentity(resolvedPath: resolved, ownership: sftpOwnership(of: attrs))
            )
            return (data, fingerprint)
        } catch {
            try? await file.close()
            if error is CancellationError || error is RemoteEditError { throw error }
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    /// Uploads `data` back to `remotePath` safely:
    /// - S3: preserves headers, metadata, tags, storage class, encryption, and ACLs, enforces `If-Match`,
    ///   and returns the ETag reported directly by the PUT response.
    /// - SFTP: recovers any interrupted swap, validates target type (never replacing directories),
    ///   uploads to a sibling temp file, re-validates revision & type immediately before commit,
    ///   journals the backup swap for reconnect recovery, and fails before touching the live file
    ///   if safe staging isn't permitted in the parent directory.
    /// - Local: follows symlinks, checks revision & type, and replaces atomically without truncating.
    static func uploadData(
        _ data: Data,
        to remotePath: String,
        on fs: FileSystemEndpoint,
        endpointKey: String,
        expectedFingerprint: RemoteFileFingerprint?,
        forceOverwrite: Bool
    ) async throws -> RemoteFileFingerprint {
        if case .s3(let s3) = fs.backend {
            return try await s3.replaceObjectContents(
                remotePath,
                data: data,
                expectedETag: expectedFingerprint?.eTag,
                forceOverwrite: forceOverwrite
            )
        }

        switch fs.backend {
        case .local(let resolver):
            try await validateLocalTarget(
                remotePath,
                fs: fs,
                expectedFingerprint: expectedFingerprint,
                forceOverwrite: forceOverwrite
            )
            try await uploadLocalSafely(data, to: remotePath, resolver: resolver)
            return (try? await currentFingerprint(of: remotePath, on: fs))
                ?? RemoteFileFingerprint(size: UInt64(data.count), modified: Date())

        case .sftp(let sftp):
            return try await uploadSFTPSafely(
                data,
                to: remotePath,
                sftp: sftp,
                fs: fs,
                endpointKey: endpointKey,
                expectedFingerprint: expectedFingerprint,
                forceOverwrite: forceOverwrite
            )

        case .s3:
            preconditionFailure("Handled above")
        }
    }

    static func currentFingerprint(of path: String, on fs: FileSystemEndpoint) async throws -> RemoteFileFingerprint {
        if let s3 = fs.s3 {
            let details = try await s3.details(path)
            return RemoteFileFingerprint(
                size: UInt64(max(0, details.size)),
                modified: details.modified,
                eTag: details.eTag
            )
        }
        let info = try await fs.info(path)
        if info.isDirectory { throw RemoteEditError.isDirectory }
        return RemoteFileFingerprint(size: info.size, modified: info.modified)
    }

    private static func isNotFoundError(_ error: Error) -> Bool {
        if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile { return true }
        if case SFTPError.fileNotFound = error { return true }
        if case StorageError.notFound = error { return true }
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
        return false
    }

    // MARK: - Crash-Safe SFTP Commit & Recovery

    /// Resolves `remotePath` to its canonical path (following a final symlink and any symlinked
    /// ancestors) so saves replace the target file instead of the symlink, and so open and save
    /// can compare the file they bind to.
    /// Only treats a confirmed `SFTPStatusCode.noSuchFile` as a missing path; all other `lstat`
    /// and `realpath` errors propagate. When `requireConfirmedRegularType` is true (all saves),
    /// an existing entry with missing permissions or zero type bits is rejected rather than assumed
    /// to be a regular file.
    private static func resolveSFTPTargetPath(
        _ remotePath: String,
        sftp: SFTPClient,
        requireConfirmedRegularType: Bool
    ) async throws -> String {
        let linkAttrs: SFTPFileAttributes
        do {
            linkAttrs = try await sftp.getLinkAttributes(at: remotePath)
        } catch {
            if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile {
                // Canonicalize the parent too; fall back only when the parent is confirmed missing.
                let parent = FileTransferLogic.parent(of: remotePath)
                let canonicalParent: String
                do {
                    canonicalParent = try await sftp.getRealPath(atPath: parent)
                } catch {
                    if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile {
                        return remotePath
                    }
                    throw SFTPError.from(sftpError: error, path: parent)
                }
                guard !canonicalParent.isEmpty else {
                    throw SFTPError.transferFailed(
                        file: remotePath,
                        reason: String(localized: "Couldn't resolve the file's full path on the server.", comment: "File editor path resolution error")
                    )
                }
                return FileTransferLogic.join(canonicalParent, FileTransferLogic.lastComponent(of: remotePath))
            }
            throw SFTPError.from(sftpError: error, path: remotePath)
        }

        switch SFTPFileType(permissions: linkAttrs.permissions) {
        case .directory:
            throw RemoteEditError.isDirectory
        case .regularFile, .symlink:
            do {
                let resolved = try await sftp.getRealPath(atPath: remotePath)
                guard !resolved.isEmpty else {
                    throw SFTPError.transferFailed(
                        file: remotePath,
                        reason: String(localized: "Couldn't resolve the file's full path on the server.", comment: "File editor path resolution error")
                    )
                }
                return resolved
            } catch {
                throw SFTPError.from(sftpError: error, path: remotePath)
            }
        case .other, .unknown:
            if requireConfirmedRegularType {
                throw SFTPError.transferFailed(
                    file: remotePath,
                    reason: String(localized: "Couldn't confirm that the remote path is a regular file before saving; the existing entry was left untouched.", comment: "File editor unconfirmed file type error")
                )
            }
            return remotePath
        }
    }

    /// Removes `path` on SFTP, succeeding ONLY when deletion succeeds or the server confirms
    /// via typed `SFTPStatusCode.noSuchFile` that `path` is already absent.
    private static func removeRemoteFileConfirmingAbsent(_ path: String, on sftp: SFTPClient) async throws {
        do {
            try await sftp.remove(at: path)
        } catch {
            if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile {
                return
            }
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    private static func sftpTargetState(from attrs: SFTPFileAttributes) -> SFTPRecoveryPlanner.TargetState {
        guard SFTPFileType(permissions: attrs.permissions) == .regularFile,
              let size = attrs.size else {
            return .other
        }
        return .regularFile(RemoteFileFingerprint(
            size: size,
            modified: attrs.accessModificationTime?.modificationTime
        ))
    }

    private static func sftpOwnership(of attrs: SFTPFileAttributes) -> SFTPOwnership? {
        attrs.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
    }

    /// Refuses a root save unless only root can rename entries in every directory above the
    /// target's parent, so the parent can't be swapped for a symlink between checks and commit.
    private static func verifySFTPParentPinnedForRoot(_ targetPath: String, sftp: SFTPClient) async throws {
        let fileName = FileTransferLogic.lastComponent(of: targetPath)
        guard let chain = SFTPPrivilegedTarget.directoryChain(for: targetPath) else {
            throw RemoteEditError.unpinnedPrivilegedTarget(directory: targetPath, fileName: fileName)
        }
        var attrs: [SFTPFileAttributes] = []
        for directory in chain {
            let directoryAttrs: SFTPFileAttributes
            do {
                directoryAttrs = try await sftp.getLinkAttributes(at: directory)
            } catch {
                throw SFTPError.from(sftpError: error, path: directory)
            }
            guard SFTPFileType(permissions: directoryAttrs.permissions) == .directory else {
                throw RemoteEditError.unpinnedPrivilegedTarget(directory: directory, fileName: fileName)
            }
            attrs.append(directoryAttrs)
        }
        for index in attrs.indices.dropLast() {
            let pinned = SFTPPrivilegedTarget.pinsEntry(
                directoryMode: attrs[index].permissions,
                directoryUID: attrs[index].uidgid?.userId,
                childUID: attrs[index + 1].uidgid?.userId
            )
            guard pinned else {
                throw RemoteEditError.unpinnedPrivilegedTarget(directory: chain[index], fileName: fileName)
            }
        }
    }

    /// Probes `path` without following symlinks, classifying missing files strictly from Citadel's
    /// typed `SFTPStatusCode.noSuchFile` so transport errors on paths like `enoent.log` never
    /// masquerade as missing files.
    private static func probeRemoteLink(
        _ path: String,
        on sftp: SFTPClient
    ) async throws -> SFTPRecoveryPlanner.TargetState {
        do {
            let attrs = try await sftp.getLinkAttributes(at: path)
            return sftpTargetState(from: attrs)
        } catch {
            if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile {
                return .missing
            }
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    /// Attempts confirmed deletion of an uncommitted staged temporary file. Clears its
    /// `RemoteStagedTempStore` entry ONLY if removal succeeds or the server confirms
    /// `SFTPStatusCode.noSuchFile`; otherwise releases the active mark while keeping the
    /// persisted record so a future reconnect retries deletion.
    private static func cleanupUncommittedTempPath(
        endpointKey: String,
        tempPath: String,
        on sftp: SFTPClient
    ) async {
        let confirmedRemoved: Bool = await Task {
            do {
                try await removeRemoteFileConfirmingAbsent(tempPath, on: sftp)
                return true
            } catch {
                return false
            }
        }.value
        if confirmedRemoved {
            await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: tempPath)
        } else {
            await RemoteStagedTempStore.shared.releaseActiveKeepingRecord(endpointKey: endpointKey, tempPath: tempPath)
        }
    }

    /// Reconciles every pending SFTP swap recovery record and any orphaned uncommitted
    /// temporary staging files for the connection signed in as `endpointKey` right after
    /// connecting, so a file hidden under a backup name reappears before listings run and
    /// orphaned temp files are cleaned up.
    static func recoverPendingSwaps(endpointKey: String, displayName: String, on fs: FileSystemEndpoint) async {
        guard case .sftp(let sftp) = fs.backend else { return }
        let pending = await RemoteSaveRecoveryStore.shared.allRecords(forEndpointKey: endpointKey)
        for record in pending {
            await SFTPPathOperationGate.shared.withLock(targetPath: record.targetPath) {
                do {
                    try await recoverInterruptedSFTPSwapLocked(
                        endpointKey: endpointKey,
                        targetPath: record.targetPath,
                        sftp: sftp
                    )
                } catch let conflict as RemoteEditError {
                    if case .recoveryConflict(let targetPath, let backupPath, let stagedPath) = conflict {
                        RemoteFileEditCenter.shared.recordRecoveryConflict(
                            endpointDisplayName: displayName,
                            endpointKey: endpointKey,
                            targetPath: targetPath,
                            backupPath: backupPath,
                            stagedPath: stagedPath,
                            message: conflict.localizedDescription
                        )
                    }
                } catch {
                    // Transport/transient failure: retain the journal record so the next reconnect retries.
                    Self.logger.warning("Deferred SFTP swap recovery for \(record.targetPath, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Clean up any uncommitted staged temporary files left behind by an earlier disconnect
        // or failed recovery. Never touch actively uploading files or files owned by a swap record.
        let orphanedTemps = await RemoteStagedTempStore.shared.orphanedRecords(forEndpointKey: endpointKey)
        for orphan in orphanedTemps {
            await SFTPPathOperationGate.shared.withLock(targetPath: orphan.targetPath) {
                guard await RemoteStagedTempStore.shared.isOrphaned(endpointKey: endpointKey, tempPath: orphan.tempPath) else {
                    return
                }
                let referencedBySwap: Bool
                do {
                    referencedBySwap = try await RemoteSaveRecoveryStore.shared.referencesTempPathStrict(
                        endpointKey: endpointKey,
                        tempPath: orphan.tempPath
                    )
                } catch {
                    // Swap journal is unreadable/corrupt: defer deletion rather than risking
                    // deleting a staged file an interrupted swap still needs.
                    Self.logger.warning("Deferred orphaned SFTP temp cleanup for \(orphan.tempPath, privacy: .private): swap journal unreadable (\(error.localizedDescription, privacy: .public))")
                    return
                }
                if referencedBySwap {
                    // Swap journal owns this tempPath (e.g. preserved during an ambiguous conflict).
                    await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: orphan.tempPath)
                    return
                }
                do {
                    try await removeRemoteFileConfirmingAbsent(orphan.tempPath, on: sftp)
                    await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: orphan.tempPath)
                    Self.logger.info("Cleaned up orphaned SFTP temp file \(orphan.tempPath, privacy: .private)")
                } catch {
                    // Keep the record persisted so the next reconnect retries deletion.
                    Self.logger.warning("Deferred orphaned SFTP temp cleanup for \(orphan.tempPath, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Reconciles a journaled SFTP swap for `targetPath`.
    /// Restores `backupPath` if `targetPath` is missing, cleans up safely when proven complete,
    /// or preserves both copies and throws `RemoteEditError.recoveryConflict` if ambiguous.
    /// Caller MUST hold `SFTPPathOperationGate` for `(endpointKey, targetPath)`.
    private static func recoverInterruptedSFTPSwapLocked(
        endpointKey: String,
        targetPath: String,
        sftp: SFTPClient
    ) async throws {
        guard let pending = await RemoteSaveRecoveryStore.shared.record(forEndpointKey: endpointKey, targetPath: targetPath) else {
            return
        }
        let targetState = try await probeRemoteLink(pending.targetPath, on: sftp)
        let backupState = try await probeRemoteLink(pending.backupPath, on: sftp)
        let tempState = try await probeRemoteLink(pending.tempPath, on: sftp)

        let action = SFTPRecoveryPlanner.decide(
            target: targetState,
            backupExists: backupState != .missing,
            tempExists: tempState != .missing,
            stagedFingerprint: pending.stagedFingerprint
        )

        switch action {
        case .restoreBackup:
            do {
                try await sftp.rename(at: pending.backupPath, to: pending.targetPath)
            } catch {
                throw SFTPError.from(sftpError: error, path: pending.targetPath)
            }
            // Keep the recovery record until the staged temp file is also confirmed removed,
            // so a disconnect after restoring the backup still retries cleaning up tempPath.
            if tempState != .missing {
                try await removeRemoteFileConfirmingAbsent(pending.tempPath, on: sftp)
            }
            await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: pending.targetPath)
            RemoteFileEditCenter.shared.clearRecoveryConflict(endpointKey: endpointKey, targetPath: pending.targetPath)
            Self.logger.info("Recovered interrupted SFTP swap for \(pending.targetPath, privacy: .private)")

        case .clearOnly(let removeTemp):
            if removeTemp {
                try await removeRemoteFileConfirmingAbsent(pending.tempPath, on: sftp)
            }
            await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: pending.targetPath)
            RemoteFileEditCenter.shared.clearRecoveryConflict(endpointKey: endpointKey, targetPath: pending.targetPath)

        case .finalizeInstalledEdit:
            // Keep the recovery record until backup removal succeeds or the server confirms
            // the backup is already absent, so reconnects retry cleanup if deletion fails.
            try await removeRemoteFileConfirmingAbsent(pending.backupPath, on: sftp)
            await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: pending.targetPath)
            RemoteFileEditCenter.shared.clearRecoveryConflict(endpointKey: endpointKey, targetPath: pending.targetPath)
            Self.logger.info("Finalized completed SFTP swap cleanup for \(pending.targetPath, privacy: .private)")

        case .conflict(let hasStagedCopy):
            // Never delete backupPath or tempPath and never clear the journal while ambiguous.
            Self.logger.error("Ambiguous SFTP swap recovery for \(pending.targetPath, privacy: .private); preserving backup and staged copy")
            throw RemoteEditError.recoveryConflict(
                targetPath: pending.targetPath,
                backupPath: pending.backupPath,
                stagedPath: hasStagedCopy ? pending.tempPath : nil
            )
        }
    }

    /// Inspects `targetPath` via `lstat`, refusing directories (even when `forceOverwrite == true`),
    /// refusing unexpected symlinks (so a rename never replaces a symlink with a regular file),
    /// and enforcing `expectedFingerprint` when `!forceOverwrite`.
    /// An owner that differs from the one seen at open is refused even when `forceOverwrite`
    /// is set: it means another file now sits at the path, not a newer revision of this one.
    private static func validateSFTPTarget(
        _ targetPath: String,
        on sftp: SFTPClient,
        expectedFingerprint: RemoteFileFingerprint?,
        forceOverwrite: Bool
    ) async throws -> SFTPFileAttributes? {
        let attrs: SFTPFileAttributes?
        do {
            attrs = try await sftp.getLinkAttributes(at: targetPath)
        } catch {
            if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile {
                if !forceOverwrite && expectedFingerprint != nil {
                    throw RemoteEditError.remoteDeleted
                }
                attrs = nil
            } else {
                throw SFTPError.from(sftpError: error, path: targetPath)
            }
        }

        if let attrs {
            // Require a confirmed POSIX regular-file type before replacing any existing entry
            // (even on forceOverwrite) so servers omitting permissions/type bits can never
            // cause a swap to replace a symlink, directory, or special file.
            switch SFTPFileType(permissions: attrs.permissions) {
            case .regularFile:
                break
            case .directory:
                throw RemoteEditError.isDirectory
            case .symlink:
                throw SFTPError.transferFailed(
                    file: targetPath,
                    reason: String(localized: "The file changed into a symbolic link before saving; the link was left untouched.", comment: "File editor symlink race error")
                )
            case .other, .unknown:
                throw SFTPError.transferFailed(
                    file: targetPath,
                    reason: String(localized: "Couldn't confirm that the remote path is a regular file before saving; the existing entry was left untouched.", comment: "File editor unconfirmed file type error")
                )
            }
            if let identity = expectedFingerprint?.identity,
               !identity.matches(path: targetPath, currentOwnership: sftpOwnership(of: attrs)) {
                throw RemoteEditError.targetChanged(fileName: FileTransferLogic.lastComponent(of: targetPath))
            }
            if !forceOverwrite, let expectedFingerprint {
                let current = RemoteFileFingerprint(
                    size: attrs.size ?? 0,
                    modified: attrs.accessModificationTime?.modificationTime
                )
                if current.differs(from: expectedFingerprint) {
                    throw RemoteEditError.remoteModified(current)
                }
            }
        }
        return attrs
    }

    private static func uploadSFTPSafely(
        _ data: Data,
        to remotePath: String,
        sftp: SFTPClient,
        fs: FileSystemEndpoint,
        endpointKey: String,
        expectedFingerprint: RemoteFileFingerprint?,
        forceOverwrite: Bool
    ) async throws -> RemoteFileFingerprint {
        let targetPath = try await resolveSFTPTargetPath(remotePath, sftp: sftp, requireConfirmedRegularType: true)

        // Save only to the file bound at open, even when overwriting a conflict.
        let identity = expectedFingerprint?.identity
        if let identity, !RemoteEditPathIdentity.matches(identity.resolvedPath, targetPath) {
            throw RemoteEditError.targetChanged(fileName: FileTransferLogic.lastComponent(of: remotePath))
        }

        // 1. Recover any previously interrupted swap and run fast pre-upload validation under the path gate.
        let initialAttrs: SFTPFileAttributes? = try await SFTPPathOperationGate.shared.withLock(
            targetPath: targetPath
        ) {
            try await recoverInterruptedSFTPSwapLocked(endpointKey: endpointKey, targetPath: targetPath, sftp: sftp)
            return try await validateSFTPTarget(
                targetPath,
                on: sftp,
                expectedFingerprint: expectedFingerprint,
                forceOverwrite: forceOverwrite
            )
        }

        let parent = FileTransferLogic.parent(of: targetPath)
        let name = FileTransferLogic.lastComponent(of: targetPath)

        // 2. Stage the complete replacement in a sibling temporary file (outside the gate so reads
        //    don't stall during upload; nothing is in the swap journal yet).
        //    SECURITY ORDER:
        //    (a) Create exclusively with `.forceCreate` (`O_CREAT|O_EXCL`) and `0600` BEFORE
        //        recording or deleting `tempPath`. On a name collision, NEVER delete the existing
        //        file — retry with a fresh unique token instead.
        //    (b) Once exclusive creation succeeds (confirming THIS save created `tempPath`),
        //        durably record `tempPath` in `RemoteStagedTempStore` so any later disconnect or
        //        recovery error cleans it up on reconnect.
        //    (c) Explicitly enforce and verify `0600` (owner-only, group/other bits zero) and
        //        UID/GID BEFORE writing any bytes.
        //    (d) Keep `tempFile` OPEN and strictly `0600` until Step 3 has revalidated the live
        //        target under the path gate, then apply final permissions via handle `FSETSTAT`.
        var tempAttrs = SFTPFileAttributes()
        tempAttrs.permissions = 0o600

        var created: (token: String, tempPath: String, file: SFTPFile)?
        let maxCreateAttempts = 5
        for attempt in 1...maxCreateAttempts {
            let candidateToken = String(UUID().uuidString.prefix(8))
            let candidatePath = FileTransferLogic.join(parent, ".\(name).rootshell-tmp-\(candidateToken)")
            do {
                let opened = try await sftp.openFile(
                    filePath: candidatePath,
                    flags: [.write, .create, .forceCreate],
                    attributes: tempAttrs
                )
                created = (candidateToken, candidatePath, opened)
                break
            } catch {
                // NEVER delete `candidatePath` when `.forceCreate` fails — it may be a pre-existing file!
                let statusCode = SFTPError.sftpStatus(from: error)?.errorCode
                if statusCode == .permissionDenied {
                    throw RemoteEditError.stagingUnavailable(directory: parent, fileName: name)
                }
                if statusCode == .failure, attempt < maxCreateAttempts {
                    // OpenSSH SFTP v3 reports `EEXIST` from `O_CREAT|O_EXCL` as `SSH_FX_FAILURE`.
                    // If a pre-existing entry occupies `candidatePath`, retry with a fresh name.
                    if let existing = try? await probeRemoteLink(candidatePath, on: sftp), existing != .missing {
                        continue
                    }
                }
                let mapped = SFTPError.from(sftpError: error, path: candidatePath)
                if case SFTPError.permissionDenied = mapped {
                    throw RemoteEditError.stagingUnavailable(directory: parent, fileName: name)
                }
                throw mapped
            }
        }
        guard let (token, tempPath, tempFile) = created else {
            throw RemoteEditError.stagingUnavailable(directory: parent, fileName: name)
        }

        // Exclusive create succeeded: this save owns `tempPath`. Persist it in the staged-temp
        // store now; if persisting fails locally, close and remove the file we just created.
        do {
            try await RemoteStagedTempStore.shared.trackActive(
                PendingSFTPTempRecord(endpointKey: endpointKey, targetPath: targetPath, tempPath: tempPath)
            )
        } catch {
            try? await tempFile.close()
            await Task { try? await removeRemoteFileConfirmingAbsent(tempPath, on: sftp) }.value
            throw error
        }

        let replacingInitial = initialAttrs != nil
        let initialOwnership = initialAttrs?.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
        let initialPermissions = SFTPPermissions.modeBits(from: initialAttrs?.permissions)

        let stagedOwnership: SFTPOwnership?
        do {
            // Strictly enforce owner-only `0600` through the open handle before writing any data.
            var privateMode = SFTPFileAttributes()
            privateMode.permissions = 0o600
            try await tempFile.setAttributes(privateMode)

            // The new file's owner is the account this save runs as. Read it from our handle,
            // before any chown, so no one can spoof it by swapping the temp path.
            let createdAttrs = try await tempFile.readHandleAttributes()
            if createdAttrs.uidgid?.userId == 0 {
                if identity == nil, !RemoteEditPathIdentity.matches(remotePath, targetPath) {
                    throw RemoteEditError.targetChanged(fileName: FileTransferLogic.lastComponent(of: remotePath))
                }
                try await verifySFTPParentPinnedForRoot(targetPath, sftp: sftp)
            }

            if replacingInitial, let uidgid = initialAttrs?.uidgid {
                var ownerAttrs = SFTPFileAttributes()
                ownerAttrs.uidgid = uidgid
                try? await tempFile.setAttributes(ownerAttrs)
            }

            // Unconditionally lstat BEFORE writing bytes on BOTH existing and new/recreated paths
            // so we confirm a regular file with group/other bits clear (rejecting omitted permissions).
            let preWriteAttrs = try await sftp.getLinkAttributes(at: tempPath)
            guard SFTPFileType(permissions: preWriteAttrs.permissions) == .regularFile,
                  SFTPPermissions.isPrivateStagingMode(preWriteAttrs.permissions) else {
                throw SFTPError.transferFailed(
                    file: targetPath,
                    reason: String(localized: "Couldn't confirm private staging permissions before uploading; the original file was left untouched.", comment: "File editor staging privacy error")
                )
            }
            if replacingInitial {
                let preWriteOwnership = preWriteAttrs.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
                if !SFTPOwnership.preservesOwnership(
                    replacingExistingFile: true,
                    original: initialOwnership,
                    staged: preWriteOwnership
                ) {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Couldn't preserve the original file's owner and group on the staged copy; the original file was left untouched.", comment: "File editor ownership mismatch error")
                    )
                }
            }

            try await writeAllChunks(data, to: tempFile)

            // Keep `tempFile` OPEN and `0600` through Step 3 commit-time validation.
            let postWriteAttrs = try await sftp.getLinkAttributes(at: tempPath)
            guard SFTPFileType(permissions: postWriteAttrs.permissions) == .regularFile,
                  SFTPPermissions.isPrivateStagingMode(postWriteAttrs.permissions) else {
                throw SFTPError.transferFailed(
                    file: targetPath,
                    reason: String(localized: "Temporary staging file permissions changed unexpectedly; the original file was left untouched.", comment: "File editor staging privacy error")
                )
            }
            stagedOwnership = postWriteAttrs.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
            if !SFTPOwnership.preservesOwnership(
                replacingExistingFile: replacingInitial,
                original: initialOwnership,
                staged: stagedOwnership
            ) {
                throw SFTPError.transferFailed(
                    file: targetPath,
                    reason: String(localized: "Couldn't preserve the original file's owner and group on the staged copy; the original file was left untouched.", comment: "File editor ownership mismatch error")
                )
            }
        } catch {
            try? await tempFile.close()
            await cleanupUncommittedTempPath(endpointKey: endpointKey, tempPath: tempPath, on: sftp)
            if error is CancellationError || error is RemoteEditError { throw error }
            throw SFTPError.from(sftpError: error, path: targetPath)
        }

        // 3. Serialize recovery, pre-commit re-validation, handle-based final permission application,
        //    close, journal persistence, and swap under the path gate so no concurrent reader or
        //    reconnect sweep can observe or delete tempPath mid-commit.
        return try await SFTPPathOperationGate.shared.withLock(
            targetPath: targetPath
        ) {
            // Everything before the swap journal is inside one cleanup scope so ANY error
            // (including a disconnect during recovery from another save!) closes `tempFile` and
            // runs confirmed cleanup (or retains the staged-temp journal entry for reconnect).
            let preCommitAttrs: SFTPFileAttributes?
            let stagedFingerprint: RemoteFileFingerprint
            do {
                try await recoverInterruptedSFTPSwapLocked(endpointKey: endpointKey, targetPath: targetPath, sftp: sftp)

                preCommitAttrs = try await validateSFTPTarget(
                    targetPath,
                    on: sftp,
                    expectedFingerprint: expectedFingerprint,
                    forceOverwrite: forceOverwrite
                )

                let replacingPreCommit = preCommitAttrs != nil
                let preCommitOwnership = preCommitAttrs?.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
                if !SFTPOwnership.preservesOwnership(
                    replacingExistingFile: replacingPreCommit,
                    original: preCommitOwnership,
                    staged: stagedOwnership
                ) {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Couldn't preserve the original file's owner and group before saving; the original file was left untouched.", comment: "File editor ownership mismatch error")
                    )
                }

                let expectedFinalPermissions: UInt32?
                if replacingPreCommit {
                    guard let targetPermissions = SFTPPermissions.modeBits(from: preCommitAttrs?.permissions) else {
                        throw SFTPError.transferFailed(
                            file: targetPath,
                            reason: String(localized: "Couldn't confirm the target file's current permissions before saving; the original file was left untouched.", comment: "File editor permission missing error")
                        )
                    }
                    // Reject a concurrent `chmod` (e.g. 0644 -> 0600) BEFORE tempFile ever leaves 0600.
                    if replacingInitial,
                       !SFTPPermissions.preservesPermissions(
                           replacingExistingFile: true,
                           original: targetPermissions,
                           staged: initialPermissions
                       ) {
                        throw SFTPError.transferFailed(
                            file: targetPath,
                            reason: String(localized: "File permissions changed on the server before saving; the original file was left untouched.", comment: "File editor concurrent permission change error")
                        )
                    }

                    // Target's type, revision, owner, and permissions are all confirmed; apply the
                    // final mode strictly through the OPEN HANDLE (`SSH_FXP_FSETSTAT`) so a swapped
                    // symlink at `tempPath` can never redirect the permission change to another file.
                    var finalMode = SFTPFileAttributes()
                    finalMode.permissions = targetPermissions
                    try await tempFile.setAttributes(finalMode)
                    expectedFinalPermissions = targetPermissions
                } else {
                    expectedFinalPermissions = nil
                }

                // Close the handle now that all writes and FSETSTAT attribute updates are complete.
                try await tempFile.close()

                // Verify `tempPath` without following symlinks (`lstat`) right before rename.
                let verifiedAttrs = try await sftp.getLinkAttributes(at: tempPath)
                guard SFTPFileType(permissions: verifiedAttrs.permissions) == .regularFile else {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Temporary staging file was unexpectedly replaced before saving; the original file was left untouched.", comment: "File editor staging replaced error")
                    )
                }
                let verifiedOwnership = verifiedAttrs.uidgid.map { SFTPOwnership(uid: $0.userId, gid: $0.groupId) }
                let verifiedPermissions = SFTPPermissions.modeBits(from: verifiedAttrs.permissions)
                if !SFTPOwnership.preservesOwnership(
                    replacingExistingFile: replacingPreCommit,
                    original: preCommitOwnership,
                    staged: verifiedOwnership
                ) {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Couldn't preserve the original file's owner and group before saving; the original file was left untouched.", comment: "File editor ownership mismatch error")
                    )
                }
                if let expectedFinalPermissions {
                    if !SFTPPermissions.preservesPermissions(
                        replacingExistingFile: true,
                        original: expectedFinalPermissions,
                        staged: verifiedPermissions
                    ) {
                        throw SFTPError.transferFailed(
                            file: targetPath,
                            reason: String(localized: "Couldn't preserve the original file's permissions on the staged copy; the original file was left untouched.", comment: "File editor permission mismatch error")
                        )
                    }
                } else if !SFTPPermissions.isPrivateStagingMode(verifiedAttrs.permissions) {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Temporary staging file permissions changed unexpectedly; the original file was left untouched.", comment: "File editor staging privacy error")
                    )
                }
                if let reportedSize = verifiedAttrs.size, reportedSize != UInt64(data.count) {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Staged file size didn't match the data written; original file was left untouched.", comment: "File editor staging size mismatch error")
                    )
                }
                if (preCommitAttrs ?? initialAttrs)?.accessModificationTime?.modificationTime != nil,
                   verifiedAttrs.accessModificationTime?.modificationTime == nil {
                    throw SFTPError.transferFailed(
                        file: targetPath,
                        reason: String(localized: "Couldn't read the server modification time of the staged file; original file was left untouched.", comment: "File editor staging mtime missing error")
                    )
                }
                stagedFingerprint = RemoteFileFingerprint(
                    size: verifiedAttrs.size ?? UInt64(data.count),
                    modified: verifiedAttrs.accessModificationTime?.modificationTime,
                    identity: RemoteFileIdentity(resolvedPath: targetPath, ownership: verifiedOwnership)
                )
            } catch {
                try? await tempFile.close()
                await cleanupUncommittedTempPath(endpointKey: endpointKey, tempPath: tempPath, on: sftp)
                if error is CancellationError || error is RemoteEditError { throw error }
                throw SFTPError.from(sftpError: error, path: targetPath)
            }

            if preCommitAttrs == nil {
                do {
                    try await sftp.rename(at: tempPath, to: targetPath)
                    await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: tempPath)
                    return stagedFingerprint
                } catch {
                    await cleanupUncommittedTempPath(endpointKey: endpointKey, tempPath: tempPath, on: sftp)
                    throw SFTPError.from(sftpError: error, path: targetPath)
                }
            }

            // Try direct overwrite rename first (succeeds on SFTP servers that support it).
            var committed = false
            do {
                try await sftp.rename(at: tempPath, to: targetPath)
                committed = true
            } catch {
                committed = false
            }
            if committed {
                await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: tempPath)
                return stagedFingerprint
            }

            // OpenSSH SFTP v3: require the recovery journal to be durably written BEFORE moving targetPath.
            let backupPath = FileTransferLogic.join(parent, ".\(name).rootshell-bak-\(token)")
            let swapRecord = PendingSFTPSwapRecord(
                endpointKey: endpointKey,
                targetPath: targetPath,
                backupPath: backupPath,
                tempPath: tempPath,
                stagedFingerprint: stagedFingerprint
            )
            do {
                try await RemoteSaveRecoveryStore.shared.record(swapRecord)
            } catch {
                await cleanupUncommittedTempPath(endpointKey: endpointKey, tempPath: tempPath, on: sftp)
                throw error
            }
            // Ownership of `tempPath` is now tracked by `RemoteSaveRecoveryStore`.
            await RemoteStagedTempStore.shared.markCompleted(endpointKey: endpointKey, tempPath: tempPath)

            var movedOriginalToBackup = false
            var installedReplacement = false
            do {
                try await sftp.rename(at: targetPath, to: backupPath)
                movedOriginalToBackup = true
                try await sftp.rename(at: tempPath, to: targetPath)
                installedReplacement = true
            } catch {
                if movedOriginalToBackup {
                    // Only attempt immediate rollback when targetPath is confirmed missing, so we
                    // never overwrite another writer's file or a lost-ACK installation of tempPath.
                    let liveTarget = try? await probeRemoteLink(targetPath, on: sftp)
                    if liveTarget == .missing {
                        let restoredAndCleaned: Bool = await Task {
                            do {
                                try await sftp.rename(at: backupPath, to: targetPath)
                                try await removeRemoteFileConfirmingAbsent(tempPath, on: sftp)
                                return true
                            } catch {
                                return false
                            }
                        }.value
                        if restoredAndCleaned {
                            await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: targetPath)
                            RemoteFileEditCenter.shared.clearRecoveryConflict(endpointKey: endpointKey, targetPath: targetPath)
                        }
                    }
                    throw SFTPError.from(sftpError: error, path: targetPath)
                } else {
                    // Ambiguous failure on rename(target -> backup): a lost ACK after server-side rename
                    // leaves targetPath missing under backupPath. Probe live server state using typed
                    // SFTP status codes before clearing; on transport error keep the record for reconnect.
                    let liveTarget = try? await probeRemoteLink(targetPath, on: sftp)
                    let liveBackup = try? await probeRemoteLink(backupPath, on: sftp)
                    if let liveTarget, let liveBackup {
                        if liveBackup == .missing && liveTarget != .missing {
                            let cleanedTemp: Bool = await Task {
                                do {
                                    try await removeRemoteFileConfirmingAbsent(tempPath, on: sftp)
                                    return true
                                } catch {
                                    return false
                                }
                            }.value
                            if cleanedTemp {
                                await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: targetPath)
                            }
                            if SFTPError.sftpStatus(from: error)?.errorCode == .permissionDenied {
                                throw RemoteEditError.stagingUnavailable(directory: parent, fileName: name)
                            }
                            let mapped = SFTPError.from(sftpError: error, path: targetPath)
                            if case SFTPError.permissionDenied = mapped {
                                throw RemoteEditError.stagingUnavailable(directory: parent, fileName: name)
                            }
                            throw mapped
                        } else if liveBackup != .missing && liveTarget == .missing {
                            let restoredAndCleaned: Bool = await Task {
                                do {
                                    try await sftp.rename(at: backupPath, to: targetPath)
                                    try await removeRemoteFileConfirmingAbsent(tempPath, on: sftp)
                                    return true
                                } catch {
                                    return false
                                }
                            }.value
                            if restoredAndCleaned {
                                await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: targetPath)
                            }
                        } else if liveBackup != .missing && liveTarget != .missing {
                            // Another process recreated targetPath after a lost-ACK rename to backup.
                            // Preserve both backupPath and tempPath and keep the journal record.
                            throw RemoteEditError.recoveryConflict(
                                targetPath: targetPath,
                                backupPath: backupPath,
                                stagedPath: tempPath
                            )
                        }
                    }
                    // Otherwise (disconnect/timeout: live probe returned nil), retain the recovery record!
                    throw SFTPError.from(sftpError: error, path: targetPath)
                }
            }

            // Replacement is live at targetPath. Only clear the recovery journal once backup
            // deletion succeeds or the server confirms the backup is already absent; if deletion
            // fails or drops, retain the record so future reconnects retry removing the backup.
            if installedReplacement {
                do {
                    try await removeRemoteFileConfirmingAbsent(backupPath, on: sftp)
                    await RemoteSaveRecoveryStore.shared.clear(endpointKey: endpointKey, targetPath: targetPath)
                    RemoteFileEditCenter.shared.clearRecoveryConflict(endpointKey: endpointKey, targetPath: targetPath)
                } catch {
                    Self.logger.warning("Saved \(targetPath, privacy: .private) but failed to delete backup \(backupPath, privacy: .private); keeping recovery journal for retry: \(error.localizedDescription, privacy: .public)")
                }
            }

            return stagedFingerprint
        }
    }

    private static func writeAllChunks(_ data: Data, to file: SFTPFile) async throws {
        var offset: UInt64 = 0
        let chunkSize = Int(PipelinedTransfer.chunkSize)
        while Int(offset) < data.count {
            try Task.checkCancellation()
            let start = data.index(data.startIndex, offsetBy: Int(offset))
            let end = data.index(start, offsetBy: min(chunkSize, data.count - Int(offset)))
            try await file.write(ByteBuffer(data: Data(data[start..<end])), at: offset)
            offset += UInt64(end - start)
        }
    }

    private static func validateLocalTarget(
        _ path: String,
        fs: FileSystemEndpoint,
        expectedFingerprint: RemoteFileFingerprint?,
        forceOverwrite: Bool
    ) async throws {
        let info: FileSystemEndpoint.ItemInfo?
        do {
            info = try await fs.info(path)
        } catch where isNotFoundError(error) {
            if !forceOverwrite && expectedFingerprint != nil {
                throw RemoteEditError.remoteDeleted
            }
            info = nil
        }
        if let info {
            if info.isDirectory { throw RemoteEditError.isDirectory }
            if !forceOverwrite, let expectedFingerprint {
                let current = RemoteFileFingerprint(size: info.size, modified: info.modified)
                if current.differs(from: expectedFingerprint) {
                    throw RemoteEditError.remoteModified(current)
                }
            }
        }
    }

    private static func uploadLocalSafely(
        _ data: Data,
        to path: String,
        resolver: LocalPathResolver
    ) async throws {
        let resolvedPath = resolver.resolve(path)
        try await Task.detached(priority: .userInitiated) {
            let targetURL = URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath()
            var existingStat = stat()
            let hadExisting = stat(targetURL.path, &existingStat) == 0
            if hadExisting && (existingStat.st_mode & S_IFMT) == S_IFDIR {
                throw RemoteEditError.isDirectory
            }
            try data.write(to: targetURL, options: .atomic)
            if hadExisting {
                _ = chmod(targetURL.path, existingStat.st_mode & 0o7777)
            }
        }.value
    }

    // MARK: - App Lifecycle & Activation Sweep

    private func installLifecycleObservers() {
        let activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                #if !targetEnvironment(macCatalyst)
                self?.resumeAllFilePresenters()
                #endif
                self?.checkAllSessionsForChanges()
            }
        }
        lifecycleObservers.append(activeToken)

        #if !targetEnvironment(macCatalyst)
        // Per NSFilePresenter.h, iOS apps must remove file presenters before suspension so
        // coordinated reads/writes in foreground external editors do not block on us.
        let backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendAllFilePresenters() }
        }
        let foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeAllFilePresenters()
                self?.checkAllSessionsForChanges()
            }
        }
        lifecycleObservers.append(backgroundToken)
        lifecycleObservers.append(foregroundToken)
        #else
        if let wsClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
           let ws = wsClass.value(forKey: "sharedWorkspace") as? NSObject,
           let center = ws.value(forKey: "notificationCenter") as? NotificationCenter {
            let macToken = center.addObserver(
                forName: NSNotification.Name("NSWorkspaceDidActivateApplicationNotification"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSObject,
                          let bundleID = app.value(forKey: "bundleIdentifier") as? String,
                          bundleID == Bundle.main.bundleIdentifier else { return }
                    self?.checkAllSessionsForChanges()
                }
            }
            lifecycleObservers.append(macToken)
        }
        #endif
    }

    private func suspendAllFilePresenters() {
        for session in sessions {
            session.suspendFilePresenter()
        }
    }

    private func resumeAllFilePresenters() {
        for session in sessions {
            session.resumeFilePresenter()
        }
    }
}
