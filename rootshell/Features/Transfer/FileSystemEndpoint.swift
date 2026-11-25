//
//  FileSystemEndpoint.swift
//  rootshell
//
//  One Sendable filesystem API over the local disk, an SFTP session or an S3
//  bucket namespace, so listing, recursive walks and transfers are written
//  once for every pairing.
//

import Foundation
import Citadel

/// Maps bookmark symlink paths (Documents/<name>) to their security-scoped targets.
/// Captured on the main actor, then usable from any thread.
nonisolated struct LocalPathResolver: Sendable {
    struct Mapping: Sendable {
        let linkPath: String
        let targetPath: String
    }

    let mappings: [Mapping]
    let bookmarkNames: Set<String>

    static let identity = LocalPathResolver(mappings: [], bookmarkNames: [])

    @MainActor
    static func current() -> LocalPathResolver {
        #if !targetEnvironment(macCatalyst)
        let manager = BookmarkedLocationsManager.shared
        let docs = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path as NSString)
            .standardizingPath
        let mappings = manager.locations.compactMap { location -> Mapping? in
            guard let target = location.resolvedURL else { return nil }
            return Mapping(
                linkPath: (docs as NSString).appendingPathComponent(location.name),
                targetPath: (target.path as NSString).standardizingPath
            )
        }
        return LocalPathResolver(mappings: mappings, bookmarkNames: Set(manager.locations.map(\.name)))
        #else
        return .identity
        #endif
    }

    /// The path to hand to the filesystem for `path`, following a bookmark link.
    func resolve(_ path: String) -> String {
        guard !mappings.isEmpty else { return path }
        let standardized = (path as NSString).standardizingPath
        for mapping in mappings {
            if standardized == mapping.linkPath { return mapping.targetPath }
            if standardized.hasPrefix(mapping.linkPath + "/") {
                return mapping.targetPath + standardized.dropFirst(mapping.linkPath.count)
            }
        }
        return path
    }

    /// Resolves only the parent, so an operation on the item itself (lstat,
    /// unlink, rename, readlink) acts on a bookmark link, never its target.
    func resolveParent(_ path: String) -> String {
        guard !mappings.isEmpty else { return path }
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != standardized else { return path }
        return (resolve(parent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }
}

nonisolated struct FileSystemEndpoint: Sendable {
    enum Backend: Sendable {
        case local(LocalPathResolver)
        case sftp(SFTPClient)
        case s3(S3FileSystem)
    }

    struct ItemInfo: Sendable {
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64
        let permissions: UInt32?
        let modified: Date?
    }

    struct ListingPage: Sendable, Equatable {
        let entries: [RFEntry]
        /// Continuation cursor for the next page, or nil when the listing is complete.
        let nextCursor: String?

        var hasMore: Bool { nextCursor != nil }
    }

    let backend: Backend

    var isRemote: Bool {
        if case .local = backend { return false }
        return true
    }

    /// The bucket namespace behind a storage endpoint, for operations only S3 has.
    var s3: S3FileSystem? {
        if case .s3(let s3) = backend { return s3 }
        return nil
    }

    /// Object storage has no links, so there are none to check for or create.
    var supportsSymlinks: Bool {
        if case .s3 = backend { return false }
        return true
    }

    /// Object storage folders exist once anything is inside them, so a copy
    /// needs neither parents first nor markers for folders that get files.
    var foldersAreImplicit: Bool {
        if case .s3 = backend { return true }
        return false
    }

    /// Whether `path` supports server-side child-prefix queries when paginated.
    /// Inside any S3 bucket, `ListObjectsV2` jumps straight to matching keys; at `/`
    /// only native AWS endpoints support `ListBuckets` `prefix` while Ceph/S3-compatible
    /// servers retain plain `GET /`.
    func supportsServerPrefixSearch(at path: String) -> Bool {
        guard case .s3(let s3) = backend else { return false }
        if s3.location(of: path) != nil { return true }
        return s3.provider.supportsPaginatedBucketListing
    }

    // MARK: - Listing and metadata

    /// Loads one page of `path`. Local and SFTP return the entire directory in a single
    /// page; S3 returns up to `pageSize` entries plus an optional continuation cursor.
    func listPage(
        _ path: String,
        cursor: String? = nil,
        namePrefix: String? = nil,
        pageSize: Int = S3FileSystem.defaultPageSize,
        strict: Bool = false
    ) async throws -> ListingPage {
        switch backend {
        case .local, .sftp:
            guard cursor == nil else { return ListingPage(entries: [], nextCursor: nil) }
            return ListingPage(entries: try await list(path, strict: strict), nextCursor: nil)
        case .s3(let s3):
            return try await s3.listPage(path, cursor: cursor, namePrefix: namePrefix, pageSize: pageSize, strict: strict)
        }
    }

    /// With `strict`, entries the listing would otherwise hide (S3 keys a path
    /// can't hold) fail it instead; transfers use it so nothing is left behind.
    func list(_ path: String, strict: Bool = false) async throws -> [RFEntry] {
        switch backend {
        case .local(let resolver):
            return try await Self.listLocal(path, resolver: resolver)
        case .sftp(let sftp):
            return try await SFTPOperations.listDirectoryEntries(sftp: sftp, path: path, strict: strict)
        case .s3(let s3):
            return try await s3.list(path, strict: strict)
        }
    }

    /// Metadata for `path`; with `followLinks` false a symlink describes itself.
    /// On S3, `isDirectory` disambiguates when both a file and a folder share a path.
    func info(_ path: String, followLinks: Bool = true, isDirectory: Bool? = nil) async throws -> ItemInfo {
        switch backend {
        case .local(let resolver):
            let resolved = followLinks ? resolver.resolve(path) : resolver.resolveParent(path)
            return try await Self.localInfo(resolved, followLinks: followLinks)
        case .sftp(let sftp):
            do {
                let attrs = followLinks
                    ? try await sftp.getAttributes(at: path)
                    : try await sftp.getLinkAttributes(at: path)
                let mode = attrs.permissions
                return ItemInfo(
                    isDirectory: SFTPOperations.isDirectory(attrs),
                    isSymlink: mode.map { $0 & 0o170000 == 0o120000 } ?? false,
                    size: attrs.size ?? 0,
                    permissions: mode,
                    modified: attrs.accessModificationTime?.modificationTime
                )
            } catch {
                throw SFTPError.from(sftpError: error, path: path)
            }
        case .s3(let s3):
            return try await s3.info(path, isDirectory: isDirectory)
        }
    }

    /// Where a fresh pane starts: the login directory remotely; Documents on
    /// iOS (the local shell's home) and the user's home on the Mac.
    func homeDirectory() async throws -> String {
        switch backend {
        case .local:
            #if targetEnvironment(macCatalyst)
            return NSHomeDirectory()
            #else
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            #endif
        case .sftp(let sftp):
            return try await mapped(".") { try await sftp.getRealPath(atPath: ".") }
        case .s3(let s3):
            return s3.homeDirectory
        }
    }

    /// Canonical absolute form of `path`; `~` and `~/…` start at the home directory.
    func canonicalPath(_ path: String, relativeTo base: String) async throws -> String {
        var expanded = path
        if path == "~" || path.hasPrefix("~/") {
            expanded = FileTransferLogic.join(try await homeDirectory(), String(path.dropFirst(min(2, path.count))))
        } else if path.utf8.first != UInt8(ascii: "/") {
            expanded = FileTransferLogic.join(base, path)
        }
        switch backend {
        case .local:
            return (expanded as NSString).standardizingPath
        case .sftp(let sftp):
            return try await mapped(expanded) { try await sftp.getRealPath(atPath: expanded) }
        case .s3:
            return FileTransferLogic.normalize(expanded)
        }
    }

    /// `path` with every symlink resolved, for deciding whether two paths name the
    /// same file. Only for comparison: operations keep the path the user sees.
    func realPath(_ path: String) async throws -> String {
        switch backend {
        case .local(let resolver):
            return try await Self.localRealPath(resolver.resolve(path))
        case .sftp(let sftp):
            return try await mapped(path) { try await sftp.getRealPath(atPath: path) }
        case .s3:
            return FileTransferLogic.normalize(path)
        }
    }

    /// `path`'s parent resolved to its real location, with the final name kept,
    /// so a symlink being moved is still compared as the link itself.
    func realLocation(of path: String) async throws -> String {
        let parent = FileTransferLogic.parent(of: path)
        return FileTransferLogic.join(try await realPath(parent), FileTransferLogic.lastComponent(of: path))
    }

    /// True only when `error` is a confirmed "does not exist" response from the
    /// filesystem, never a permission, network, or server error.
    static func isNotFoundError(_ error: Error) -> Bool {
        if case StorageError.notFound = error { return true }
        if case SFTPError.fileNotFound = error { return true }
        if SFTPError.sftpStatus(from: error)?.errorCode == .noSuchFile { return true }
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        return false
    }

    /// Metadata for `path` if it exists, `nil` only on a confirmed not-found response.
    /// Permission, network, and server errors are rethrown so callers never treat an
    /// unreadable existing item as missing.
    func infoIfExists(_ path: String, followLinks: Bool = true, isDirectory: Bool? = nil) async throws -> ItemInfo? {
        do {
            return try await info(path, followLinks: followLinks, isDirectory: isDirectory)
        } catch is CancellationError {
            throw CancellationError()
        } catch where Self.isNotFoundError(error) {
            return nil
        }
    }

    func readLink(_ path: String) async throws -> String {
        switch backend {
        case .local(let resolver):
            return try FileManager.default.destinationOfSymbolicLink(atPath: resolver.resolveParent(path))
        case .sftp(let sftp):
            return try await mapped(path) { try await sftp.readLink(at: path) }
        case .s3:
            throw StorageError.noSymlinks
        }
    }

    // MARK: - Mutation

    func makeDirectory(_ path: String) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk { try FileManager.default.createDirectory(atPath: resolver.resolveParent(path), withIntermediateDirectories: false) }
        case .sftp(let sftp):
            try await mapped(path) { try await sftp.createDirectory(atPath: path) }
        case .s3(let s3):
            try await s3.makeDirectory(path)
        }
    }

    /// Creates `path` unless it's already there. A storage folder marker is just
    /// rewritten, one request instead of checking first; a bucket is never created.
    func ensureDirectory(_ path: String) async throws {
        if let s3, s3.bucketName(of: path) == nil { return try await s3.makeDirectory(path) }
        if try await infoIfExists(path, followLinks: false) == nil { try await makeDirectory(path) }
    }

    func createEmptyFile(_ path: String) async throws {
        let writer = try await openWriter(path)
        try await writer.close()
    }

    /// Removes a file or symlink (never follows it).
    func removeFile(_ path: String) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                guard unlink(resolver.resolveParent(path)) == 0 else { throw POSIXError.current }
            }
        case .sftp(let sftp):
            try await mapped(path) { try await sftp.remove(at: path) }
        case .s3(let s3):
            try await s3.removeFile(path)
        }
    }

    /// Removes an empty directory.
    func removeDirectory(_ path: String) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                guard rmdir(resolver.resolveParent(path)) == 0 else { throw POSIXError.current }
            }
        case .sftp(let sftp):
            try await mapped(path) { try await sftp.rmdir(at: path) }
        case .s3(let s3):
            try await s3.removeDirectory(path)
        }
    }

    /// Deletes `path` and, for a real directory, everything beneath it.
    /// Symlinked directories are unlinked, not descended into.
    /// On S3, `isDirectory` disambiguates when both a file and a folder share a path.
    func removeRecursively(_ path: String, isDirectory: Bool? = nil) async throws {
        if case .s3(let s3) = backend {
            // Batch deletes by prefix instead of a walk.
            return try await s3.removeRecursively(path, isDirectory: isDirectory)
        }
        let item = try await info(path, followLinks: false)
        if let expectedDirectory = isDirectory, !item.isSymlink, item.isDirectory != expectedDirectory {
            throw FileTransferLogic.ItemTypeChanged(name: FileTransferLogic.lastComponent(of: path))
        }
        guard item.isDirectory else {
            try await removeFile(path)
            return
        }
        for entry in try await list(path) {
            try Task.checkCancellation()
            if entry.isDirectory && !entry.isSymlink {
                try await removeRecursively(entry.path)
            } else {
                try await removeFile(entry.path)
            }
        }
        try await removeDirectory(path)
    }

    func rename(_ from: String, to: String, isDirectory: Bool? = nil) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                guard Darwin.rename(resolver.resolveParent(from), resolver.resolveParent(to)) == 0 else { throw POSIXError.current }
            }
        case .sftp(let sftp):
            try await mapped(from) { try await sftp.rename(at: from, to: to) }
        case .s3(let s3):
            try await s3.rename(from, to: to, isDirectory: isDirectory)
        }
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                guard chmod(resolver.resolve(path), mode_t(mode & 0o7777)) == 0 else { throw POSIXError.current }
            }
        case .sftp(let sftp):
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode & 0o7777
            try await mapped(path) { try await sftp.setAttributes(at: path, attributes: attributes) }
        case .s3:
            throw StorageError.noPermissions
        }
    }

    /// Restores a copied directory's mode without following a symlink swapped in for it
    /// (lsetstat@openssh.com when offered), dropping setuid/setgid as OpenSSH's sftp does.
    func restoreDirectoryMode(_ path: String, mode: UInt32) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                guard lchmod(resolver.resolveParent(path), mode_t(mode & 0o1777)) == 0 else { throw POSIXError.current }
            }
        case .sftp(let sftp):
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode & 0o1777
            try await mapped(path) { try await sftp.setLinkAttributes(at: path, attributes: attributes) }
        case .s3:
            throw StorageError.noPermissions
        }
    }

    func setModificationDate(_ path: String, date: Date) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: resolver.resolve(path))
            }
        case .sftp(let sftp):
            let attributes = SFTPFileAttributes(
                accessModificationTime: .init(accessTime: date, modificationTime: date)
            )
            try await mapped(path) { try await sftp.setAttributes(at: path, attributes: attributes) }
        case .s3:
            throw StorageError.noPermissions
        }
    }

    func createSymlink(at linkPath: String, target: String) async throws {
        switch backend {
        case .local(let resolver):
            try await Self.onDisk {
                try FileManager.default.createSymbolicLink(atPath: resolver.resolveParent(linkPath), withDestinationPath: target)
            }
        case .sftp(let sftp):
            try await mapped(linkPath) { try await sftp.createSymlink(linkPath: linkPath, targetPath: target) }
        case .s3:
            throw StorageError.noSymlinks
        }
    }

    // MARK: - Streams

    func openReader(_ path: String) async throws -> any ChunkReader {
        switch backend {
        case .local(let resolver):
            return try PipelinedTransfer.LocalFile.openForReading(resolver.resolve(path))
        case .sftp(let sftp):
            let file = try await mapped(path) { try await sftp.openFile(filePath: path, flags: .read) }
            return PipelinedTransfer.SendableSFTPFile(file: file)
        case .s3(let s3):
            return try await s3.openReader(path)
        }
    }

    /// Creates or truncates `path` for writing. A local symlink at `path` is refused,
    /// never written through; callers unlink destination links first. With `exclusive`,
    /// anything already at `path` fails the open (object storage has no such check).
    /// `mode` applies only when the open creates the file, narrowed by the umask.
    func openWriter(_ path: String, exclusive: Bool = false, mode: UInt32? = nil) async throws -> any ChunkWriter {
        switch backend {
        case .local(let resolver):
            return try PipelinedTransfer.LocalFile.openForWriting(resolver.resolveParent(path), exclusive: exclusive, mode: mode_t((mode ?? 0o644) & 0o777))
        case .sftp(let sftp):
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode.map { $0 & 0o777 }
            let file = try await mapped(path) {
                try await sftp.openFile(filePath: path, flags: exclusive ? [.write, .create, .forceCreate] : [.write, .create, .truncate], attributes: attributes)
            }
            return PipelinedTransfer.SendableSFTPFile(file: file)
        case .s3(let s3):
            return try await s3.openWriter(path)
        }
    }

    /// Copies `sourcePath` into `path` without the bytes passing through this
    /// device, when both ends allow it. Returns false to fall back to streaming.
    func copyOnServer(_ sourcePath: String, from source: FileSystemEndpoint, to path: String) async throws -> Bool {
        guard case .s3(let destination) = backend, case .s3(let origin) = source.backend,
              destination.canCopyOnServer(from: origin) else { return false }
        try await destination.copyOnServer(sourcePath, from: origin, to: path)
        return true
    }

    // MARK: - Path helpers

    func join(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    func parent(of path: String) -> String {
        SFTPOperations.parentPath(of: path)
    }

    // MARK: - Private

    private func mapped<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    @concurrent
    private static func onDisk(_ body: @Sendable () throws -> Void) async throws {
        try body()
    }

    @concurrent
    private static func localRealPath(_ path: String) async throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw POSIXError.current }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @concurrent
    private static func listLocal(_ path: String, resolver: LocalPathResolver) async throws -> [RFEntry] {
        try RFEntry.loadLocalDirectory(at: path, resolver: resolver)
    }

    @concurrent
    private static func localInfo(_ path: String, followLinks: Bool) async throws -> ItemInfo {
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { throw POSIXError.current }
        let mode = UInt32(info.st_mode)
        return ItemInfo(
            isDirectory: mode & 0o170000 == 0o040000,
            isSymlink: mode & 0o170000 == 0o120000,
            size: UInt64(max(0, info.st_size)),
            permissions: mode,
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        )
    }
}
