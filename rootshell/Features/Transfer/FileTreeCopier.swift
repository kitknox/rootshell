//
//  FileTreeCopier.swift
//  rootshell
//
//  Copies files and directory trees between any two FileSystemEndpoints.
//  Shared by the file manager's transfer queue and the rf browser.
//

import Foundation

enum FileTreeCopier {
    struct Item {
        enum Kind {
            case directory
            case file
            case symlink(target: String)
        }

        let kind: Kind
        let source: String
        let destination: String
        let size: Int64
        let mode: UInt32?
        let modified: Date?

        var isFile: Bool {
            if case .file = kind { return true }
            return false
        }

        var isDirectory: Bool {
            if case .directory = kind { return true }
            return false
        }
    }

    /// The item plus, for a directory, everything beneath it in copy order.
    /// The selected item is dereferenced if it is a link; nested links are
    /// copied as links, so a link cycle can't recurse forever.
    static func expand(_ path: String, into target: String, fs: FileSystemEndpoint) async throws -> [Item] {
        let info: FileSystemEndpoint.ItemInfo
        if let followed = try? await fs.info(path) {
            info = followed
        } else {
            info = try await fs.info(path, followLinks: false)
            if info.isSymlink {
                return [Item(kind: .symlink(target: try await fs.readLink(path)), source: path, destination: target, size: 0, mode: nil, modified: nil)]
            }
        }
        guard info.isDirectory else {
            return [Item(kind: .file, source: path, destination: target, size: Int64(clamping: info.size), mode: info.permissions, modified: info.modified)]
        }
        var items = [Item(kind: .directory, source: path, destination: target, size: 0, mode: info.permissions, modified: info.modified)]
        try await walk(path, into: target, fs: fs, items: &items)
        return items
    }

    private static func walk(_ directory: String, into target: String, fs: FileSystemEndpoint, items: inout [Item]) async throws {
        // Strict: a move deletes the source tree afterwards, so nothing may be skipped.
        for entry in try await fs.list(directory, strict: true) {
            try Task.checkCancellation()
            // Listed names come from the server; one must never step outside `target`.
            guard FileTransferLogic.isSingleComponent(entry.name) else { throw FileTransferLogic.UnsafeName(name: entry.name) }
            let destination = FileTransferLogic.join(target, entry.name)
            if entry.isSymlink {
                let linkTarget: String
                if let known = entry.symlinkTarget {
                    linkTarget = known
                } else {
                    linkTarget = try await fs.readLink(entry.path)
                }
                items.append(Item(kind: .symlink(target: linkTarget), source: entry.path, destination: destination, size: 0, mode: nil, modified: nil))
            } else if entry.isDirectory {
                items.append(Item(kind: .directory, source: entry.path, destination: destination, size: 0, mode: entry.permissions, modified: entry.modifiedDate))
                try await walk(entry.path, into: destination, fs: fs, items: &items)
            } else {
                items.append(Item(kind: .file, source: entry.path, destination: destination, size: entry.size, mode: entry.permissions, modified: entry.modifiedDate))
            }
        }
    }

    /// Creates one item at its destination. `onBytes` receives byte deltas and is
    /// rewound with a negative delta if a file copy fails; a partial file is removed.
    static func copy(
        _ item: Item,
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint,
        preserveAttributes: Bool,
        onBytes: @MainActor (Int64) -> Void
    ) async throws {
        switch item.kind {
        case .directory:
            try await removeSymlink(at: item.destination, on: destination)
            try await destination.ensureDirectory(item.destination)
        case .symlink(let target):
            try await removeSymlink(at: item.destination, on: destination)
            try await destination.createSymlink(at: item.destination, target: target)
        case .file:
            // openNewFile replaces a link in the way itself.
            let appliedOnHandle = try await copyFile(item, from: source, to: destination, preserveAttributes: preserveAttributes, onBytes: onBytes)
            if preserveAttributes, !appliedOnHandle {
                if let modified = item.modified { try? await destination.setModificationDate(item.destination, date: modified) }
                if let mode = item.mode { try? await destination.setPermissions(item.destination, mode: mode & 0o777) }
            }
        }
    }

    /// Applies directory modes after their contents exist, deepest first,
    /// so a read-only directory can still be filled.
    static func applyDirectoryModes(_ items: [Item], on destination: FileSystemEndpoint) async {
        for item in items.reversed() {
            guard case .directory = item.kind, let mode = item.mode else { continue }
            try? await destination.restoreDirectoryMode(item.destination, mode: mode)
        }
    }

    /// Copies a whole tree, stopping at the first failure.
    static func copyTree(
        _ path: String,
        to target: String,
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint,
        preserveAttributes: Bool = false,
        onBytes: @escaping @MainActor (Int64) -> Void = { _ in }
    ) async throws {
        let items = try await expand(path, into: target, fs: source)
        try await copyItems(items, from: source, to: destination, preserveAttributes: preserveAttributes, onBytes: onBytes) { _, error in
            if let error { throw error }
        }
        if preserveAttributes { await applyDirectoryModes(items, on: destination) }
    }

    /// Items in flight at once; small files cost round trips, not bandwidth.
    static let workers = 8

    /// Copies items listed in `expand` order, `workers` at a time. Large files take
    /// one lane of their own: they already overlap their chunks and would multiply
    /// buffered memory if run together. `onFinish` gets each item's error, or nil,
    /// and throws to stop the rest.
    static func copyItems(
        _ items: [Item],
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint,
        preserveAttributes: Bool,
        onStart: @escaping @MainActor (Item) -> Void = { _ in },
        onBytes: @escaping @MainActor (Int64) -> Void,
        onFinish: @escaping @MainActor (Item, Error?) throws -> Void
    ) async throws {
        func run(_ item: Item, after earlier: ArraySlice<Item>) async throws {
            try Task.checkCancellation()
            onStart(item)
            do {
                for other in earlier where !other.isDirectory {
                    try await refuseAlias(item, of: other, on: destination)
                }
                try await copy(item, from: source, to: destination, preserveAttributes: preserveAttributes, onBytes: onBytes)
            } catch where error is CancellationError || Task.isCancelled {
                // Siblings of a failed or cancelled item aren't failures of their own.
                throw CancellationError()
            } catch {
                return try onFinish(item, error)
            }
            try onFinish(item, nil)
        }

        // Items in one unit share a name on a case- or normalization-insensitive
        // volume, so they run in order and a later one never overwrites an earlier one.
        func runUnit(_ unit: [Item]) async throws {
            for (index, item) in unit.enumerated() {
                try await run(item, after: item.isDirectory ? [] : unit[..<index])
            }
        }
        func units(_ items: [Item]) -> [[Item]] {
            guard !destination.foldersAreImplicit else { return items.map { [$0] } }
            var indices: [String: Int] = [:]
            var grouped: [[Item]] = []
            for item in items {
                // String keys already equate canonically equivalent spellings.
                let key = item.destination.folding(options: .caseInsensitive, locale: nil)
                if let index = indices[key] {
                    grouped[index].append(item)
                } else {
                    indices[key] = grouped.count
                    grouped.append([item])
                }
            }
            return grouped
        }

        let folders = items.filter(\.isDirectory)
        var rest = items.filter { !$0.isDirectory }
        if destination.foldersAreImplicit {
            // A folder appears with the first file inside it; only empty ones need a marker.
            var filled: Set<String> = []
            for item in rest where item.isFile {
                var parent = FileTransferLogic.parent(of: item.destination)
                while parent != "/", parent != ".", filled.insert(parent).inserted {
                    parent = FileTransferLogic.parent(of: parent)
                }
            }
            for folder in folders where filled.contains(folder.destination) {
                try onFinish(folder, nil)
            }
            rest += folders.filter { !filled.contains($0.destination) }
        } else {
            // One depth at a time, so every folder's parent exists before it.
            let levels = Dictionary(grouping: folders) { $0.destination.split(separator: "/").count }
            for depth in levels.keys.sorted() {
                try await pool(units(levels[depth] ?? []), runUnit)
            }
        }
        let threshold = Int64(PipelinedTransfer.pipelineThreshold)
        let restUnits = units(rest)
        let isLarge = { (unit: [Item]) in unit.contains { $0.isFile && $0.size >= threshold } }
        try await pool(restUnits.filter { !isLarge($0) }, lane: restUnits.filter(isLarge), runUnit)
    }

    /// Runs `body` over `units`, `workers` at a time, beside one lane working
    /// through `lane` in order. The first error cancels the rest.
    private static func pool(
        _ units: [[Item]],
        lane: [[Item]] = [],
        _ body: @escaping @MainActor ([Item]) async throws -> Void
    ) async throws {
        var pending = units[...]
        try await withThrowingTaskGroup(of: Bool.self) { group in
            if !lane.isEmpty {
                group.addTask {
                    for unit in lane { try await body(unit) }
                    return false
                }
            }
            func startNext() {
                guard let unit = pending.popFirst() else { return }
                group.addTask {
                    try await body(unit)
                    return true
                }
            }
            for _ in 0..<workers { startNext() }
            for try await fromPool in group where fromPool {
                startNext()
            }
        }
    }

    /// Copies one file; a folder at `path` is refused rather than walked.
    static func copySingleFile(
        _ path: String,
        to target: String,
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint
    ) async throws {
        let info = try await source.info(path)
        guard !info.isDirectory else { throw POSIXError(.EISDIR) }
        let item = Item(kind: .file, source: path, destination: target, size: Int64(clamping: info.size), mode: nil, modified: nil)
        _ = try await copyFile(item, from: source, to: destination, preserveAttributes: false) { _ in }
    }

    /// Two source names that differ only in case or accents, which the destination
    /// volume treats as one.
    struct NameCollision: LocalizedError {
        let name: String
        let earlier: String

        var errorDescription: String? {
            String(
                localized: "“\(name)” wasn't copied because the destination treats it as the same name as “\(earlier)”.",
                comment: "File transfer error; arguments are two file names differing only in case or accents"
            )
        }
    }

    private static func refuseAlias(_ item: Item, of earlier: Item, on destination: FileSystemEndpoint) async throws {
        guard try await namesAlias(item.destination, earlier.destination, on: destination) else { return }
        throw NameCollision(
            name: FileTransferLogic.lastComponent(of: item.destination),
            earlier: FileTransferLogic.lastComponent(of: earlier.destination)
        )
    }

    /// Whether `path` and `other`, differing only in case or accents, reach one entry.
    /// Listings can't say (Foundation reports names decomposed), so each differing
    /// pair is tried beside `path`, where the copy writes anyway: a short scratch file
    /// made under one spelling, looked up under the other.
    private static func namesAlias(_ path: String, _ other: String, on fs: FileSystemEndpoint) async throws -> Bool {
        let folder = FileTransferLogic.parent(of: path)
        for (mine, theirs) in FileTransferLogic.differingSpellings(path, other) {
            let tag = ".rootshell-\(UUID().uuidString.prefix(8))-"
            let probe = FileTransferLogic.join(folder, tag + theirs)
            try await fs.openWriter(probe, exclusive: true).close()
            let aliased = await fs.exists(FileTransferLogic.join(folder, tag + mine))
            // Unstructured, so a cancelled job still cleans up.
            await Task { try? await fs.removeFile(probe) }.value
            if !aliased { return false }
        }
        return true
    }

    /// A new file at `path`: anything there is unlinked and recreated, never truncated,
    /// so a hard-linked destination can't share its data with another path being written.
    /// A replaced file is created with its old mode (less the umask), so its new
    /// contents are never more readable than the old ones were.
    private static func openNewFile(_ path: String, on destination: FileSystemEndpoint) async throws -> any ChunkWriter {
        do {
            return try await destination.openWriter(path, exclusive: true)
        } catch {
            try Task.checkCancellation()
            guard let existing = try? await destination.info(path, followLinks: false), !existing.isDirectory else { throw error }
            try await destination.removeFile(path)
            return try await destination.openWriter(path, exclusive: true, mode: existing.isSymlink ? nil : existing.permissions)
        }
    }

    /// A symlink already at a destination is replaced, never written or descended
    /// through, so a merge can't redirect data outside the target folder.
    private static func removeSymlink(at path: String, on destination: FileSystemEndpoint) async throws {
        guard destination.supportsSymlinks, let existing = try? await destination.info(path, followLinks: false), existing.isSymlink else { return }
        try await destination.removeFile(path)
    }

    /// Returns true when `preserveAttributes` was satisfied through the open handle.
    private static func copyFile(_ item: Item, from source: FileSystemEndpoint, to destination: FileSystemEndpoint, preserveAttributes: Bool, onBytes: @MainActor (Int64) -> Void) async throws -> Bool {
        if try await destination.copyOnServer(item.source, from: source, to: item.destination) {
            onBytes(item.size)
            return false
        }
        let reader = try await source.openReader(item.source)
        let writer: any ChunkWriter
        do {
            writer = try await openNewFile(item.destination, on: destination)
        } catch {
            try? await reader.close()
            throw error
        }
        var counted: Int64 = 0
        var failure: Error?
        do {
            try await PipelinedTransfer.copy(from: reader, to: writer, size: item.size > 0 ? UInt64(item.size) : nil) { total in
                onBytes(total - counted)
                counted = total
            }
        } catch {
            failure = error
        }
        try? await reader.close()
        var appliedOnHandle = false
        if failure == nil, preserveAttributes, item.mode != nil || item.modified != nil {
            // A refusal here is no better by path, so it isn't retried there.
            appliedOnHandle = (try? await writer.applyAttributes(mode: item.mode, modified: item.modified)) ?? true
        }
        // The item only counts as copied once the destination accepts the close.
        if failure == nil {
            do {
                try await writer.close()
            } catch {
                failure = error
            }
        } else {
            await writer.abort()
        }
        if let failure {
            // Never leave a truncated file behind or count its bytes.
            onBytes(-counted)
            if !writer.replacesAtomically { try? await destination.removeFile(item.destination) }
            throw failure
        }
        return appliedOnHandle
    }
}
