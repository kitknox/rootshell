//
//  FileManagerPreviewCache.swift
//  rootshell
//
//  Local copies of remote files for Quick Look and drag-out. Kept under
//  Caches so the system may reclaim them; cleared on first use each launch.
//

import Foundation

enum FileManagerPreviewCache {
    /// Largest remote file fetched for a preview.
    static let maxPreviewBytes: Int64 = 512 * 1024 * 1024

    private static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("FileManagerPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    /// A file URL for `entry`: the file itself when local, else a fresh download.
    static func localURL(for entry: RFEntry, fs: FileSystemEndpoint) async throws -> URL {
        if case .local(let resolver) = fs.backend {
            let url = URL(fileURLWithPath: resolver.resolve(entry.path))
            guard isExistingFile(url) else { throw FileManagerPreviewError.unavailable }
            return url
        }
        guard entry.size <= maxPreviewBytes else {
            throw FileManagerPreviewError.tooLarge
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(entry.name)
        let local = FileSystemEndpoint(backend: .local(.identity))
        do {
            // Bytes only: a copied link could dangle or point at an unrelated local file.
            try await FileTreeCopier.copySingleFile(entry.path, to: destination.path, from: fs, to: local)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination
    }

    /// Writes already-fetched bytes into the preview cache for Quick Look (e.g. after
    /// sniffing an extensionless remote file and finding binary data).
    static func storePreviewData(_ data: Data, named name: String) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination
    }

    /// Quick Look's Save to Files asserts on a URL that isn't an existing file,
    /// such as a broken link, so those never reach it.
    private static func isExistingFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

enum FileManagerPreviewError: LocalizedError {
    case tooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            String(localized: "This file is too large to preview.", comment: "File manager preview error")
        case .unavailable:
            String(localized: "This file can't be previewed. It may be a broken link.", comment: "File manager preview error")
        }
    }
}
