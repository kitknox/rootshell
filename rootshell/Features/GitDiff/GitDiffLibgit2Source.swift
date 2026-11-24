//
//  GitDiffLibgit2Source.swift
//  rootshell
//
//  The diff for an iOS local shell pane, read in process with libgit2. It
//  answers the same request as the remote probe and feeds the same parser.
//
//  A poll that finds nothing new stops after listing what changed: the stamp
//  comes from that list and each file's size and mtime, so no content is
//  diffed and no patch text is built until something has moved.
//

#if !targetEnvironment(macCatalyst)

import Foundation

nonisolated enum GitDiffLibgit2Source {

    static func load(_ request: GitDiffProbeRequest) -> GitDiffProbeResponse {
        guard let directory = request.directory, !directory.isEmpty else { return .unavailable(.noDirectory) }
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repoPointer: OpaquePointer?
        guard git_repository_open_ext(&repoPointer, directory, 0, nil) == 0, let repo = repoPointer else {
            return .unavailable(.notARepository(directory: directory))
        }
        defer { git_repository_free(repo) }
        // A bare repository has no working tree to compare.
        guard let workdir = git_repository_workdir(repo) else {
            return .unavailable(.notARepository(directory: directory))
        }
        var root = String(cString: workdir)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        var snapshot = GitDiffSnapshot(repositoryRoot: root)

        var headCommit: OpaquePointer?
        var head: OpaquePointer?
        if git_repository_head(&head, repo) == 0, let head {
            if git_reference_is_branch(head) != 0, let name = git_reference_shorthand(head) {
                snapshot.branch = String(cString: name)
            }
            git_reference_peel(&headCommit, head, GIT_OBJECT_COMMIT)
            git_reference_free(head)
        }
        defer { if let headCommit { git_object_free(headCommit) } }
        var headHex = ""
        if let headCommit, let oid = git_object_id(headCommit) {
            headHex = hexString(oid)
            snapshot.headSHA = String(headHex.prefix(7))
        }

        var oldTree: OpaquePointer?
        var newTree: OpaquePointer?
        defer {
            if let oldTree { git_tree_free(oldTree) }
            if let newTree { git_tree_free(newTree) }
        }
        switch request.scope {
        case .uncommitted:
            if let headCommit { git_commit_tree(&oldTree, headCommit) }
        case .branch:
            if let headCommit, let base = mergeBase(repo: repo, headCommit: headCommit) {
                oldTree = base.tree
                snapshot.baseRef = base.name
            } else if let headCommit {
                git_commit_tree(&oldTree, headCommit)
            }
        case .lastCommit:
            // No commit yet leaves both trees nil, which diffs to nothing.
            if let headCommit {
                git_commit_tree(&newTree, headCommit)
                var parent: OpaquePointer?
                if git_commit_parent(&parent, headCommit, 0) == 0, let parent {
                    git_commit_tree(&oldTree, parent)
                    git_commit_free(parent)
                }
            }
        }

        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        var flags = GIT_DIFF_INCLUDE_TYPECHANGE.rawValue
        if request.scope != .lastCommit {
            flags |= GIT_DIFF_INCLUDE_UNTRACKED.rawValue
            flags |= GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            flags |= GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        }
        if request.ignoreWhitespace { flags |= GIT_DIFF_IGNORE_WHITESPACE.rawValue }
        options.flags = flags
        // libgit2 never loads a file past this; it treats it as binary.
        options.max_size = Int64(GitDiffProbeCommand.untrackedByteLimit)

        var diffPointer: OpaquePointer?
        let result = request.scope == .lastCommit
            ? git_diff_tree_to_tree(&diffPointer, repo, oldTree, newTree, &options)
            : git_diff_tree_to_workdir_with_index(&diffPointer, repo, oldTree, &options)
        guard result == 0, let diff = diffPointer else { return .failed }
        defer { git_diff_free(diff) }
        let deltaCount = git_diff_num_deltas(diff)

        // The stamp covers what the panel shows (repository, ref, base) and
        // identifies each change without reading it.
        var stamp = Stamp()
        stamp.mix(request.scope.rawValue)
        stamp.mix(request.ignoreWhitespace ? "w" : "-")
        stamp.mix(root)
        stamp.mix(snapshot.branch ?? "")
        stamp.mix(snapshot.baseRef ?? "")
        stamp.mix(headHex)
        for index in 0..<deltaCount {
            guard let delta = git_diff_get_delta(diff, index) else { continue }
            stamp.mix(UInt64(delta.pointee.status.rawValue))
            withUnsafeBytes(of: delta.pointee.old_file.id) { stamp.mix($0) }
            withUnsafeBytes(of: delta.pointee.new_file.id) { stamp.mix($0) }
            if let path = delta.pointee.old_file.path { stamp.mix(String(cString: path)) }
            guard let path = delta.pointee.new_file.path else { continue }
            let name = String(cString: path)
            stamp.mix(name)
            guard request.scope != .lastCommit else { continue }
            var info = stat()
            if lstat(root + "/" + name, &info) == 0 {
                stamp.mix(UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)))
                stamp.mix(UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)))
                stamp.mix(UInt64(bitPattern: Int64(info.st_size)))
            }
        }
        snapshot.stamp = "l" + String(stamp.value, radix: 16) + "-\(deltaCount)"
        if snapshot.stamp == request.knownStamp { return .unchanged }

        // Renames are paired only now that something changed, and only when
        // doing so cannot read more than the size limits allow. Similarity
        // loads both sides of every candidate; identical ids cost nothing.
        // The flags are explicit so `diff.renames=copies` cannot add modified
        // files as sources. With renames only, libgit2 takes as a source the
        // old side of a deletion or type change, and as a target the new side
        // of an addition or type change, when that side is a regular file.
        // Those are the sides budgeted here.
        var odb: OpaquePointer?
        git_repository_odb(&odb, repo)
        defer { if let odb { git_odb_free(odb) } }
        var largest: UInt64 = 0, total: UInt64 = 0
        // Paths deleted from the index, noted before pairing folds a deletion
        // into a rename and hides it.
        var deletedPaths: [String] = []
        for index in 0..<deltaCount {
            guard let delta = git_diff_get_delta(diff, index) else { continue }
            let status = delta.pointee.status
            if status == GIT_DELTA_DELETED, let path = delta.pointee.old_file.path {
                deletedPaths.append(String(cString: path))
            }
            let isSource = (status == GIT_DELTA_DELETED || status == GIT_DELTA_TYPECHANGE)
                && isRegularFile(delta.pointee.old_file.mode)
            let isTarget = (status == GIT_DELTA_ADDED || status == GIT_DELTA_TYPECHANGE)
                && isRegularFile(delta.pointee.new_file.mode)
            for size in [isSource ? byteSize(delta.pointee.old_file, odb: odb) : 0,
                         isTarget ? byteSize(delta.pointee.new_file, odb: odb) : 0] {
                largest = max(largest, size)
                total += size
            }
        }
        var find = git_diff_find_options()
        git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        find.flags = GIT_DIFF_FIND_RENAMES.rawValue
        if largest <= UInt64(GitDiffProbeCommand.untrackedByteLimit), total <= Self.similarityByteBudget {
            git_diff_find_similar(diff, &find)
        } else if request.scope == .lastCommit {
            find.flags |= GIT_DIFF_FIND_EXACT_MATCH_ONLY.rawValue
            git_diff_find_similar(diff, &find)
        }

        var patchBytes: [UInt8] = []
        let fileLimit = UInt64(GitDiffProbeCommand.untrackedByteLimit)

        /// Lists each change in `diff`, with counts and, for the open panel, its patch.
        func collect(_ diff: OpaquePointer, where included: (git_delta_t) -> Bool) {
            for index in 0..<git_diff_num_deltas(diff) {
                guard let delta = git_diff_get_delta(diff, index), included(delta.pointee.status) else { continue }
                let status = delta.pointee.status
                let newPath = delta.pointee.new_file.path.map { String(cString: $0) } ?? ""
                let oldPath = delta.pointee.old_file.path.map { String(cString: $0) } ?? ""
                var file = GitDiffFile(path: status == GIT_DELTA_DELETED ? oldPath : newPath, oldPath: nil,
                                       status: fileStatus(status))
                if status == GIT_DELTA_RENAMED || status == GIT_DELTA_COPIED, oldPath != newPath {
                    file.oldPath = oldPath
                }
                defer { snapshot.files.append(file) }

                // A pure rename changes no lines, whatever its size.
                var oldID = delta.pointee.old_file.id, newID = delta.pointee.new_file.id
                if status == GIT_DELTA_RENAMED, git_oid_equal(&oldID, &newID) != 0 {
                    file.additions = 0
                    file.deletions = 0
                    file.hasPatch = true
                    continue
                }
                // Too large to diff: listed without counts, never loaded, and
                // flagged so the totals say they are incomplete.
                if max(byteSize(delta.pointee.old_file, odb: odb), byteSize(delta.pointee.new_file, odb: odb)) > fileLimit {
                    file.isTooLarge = true
                    continue
                }
                var patchPointer: OpaquePointer?
                guard git_patch_from_diff(&patchPointer, diff, index) == 0, let patch = patchPointer else { continue }
                defer { git_patch_free(patch) }
                // The binary flag is only known once the content is loaded.
                if delta.pointee.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0 {
                    file.isBinary = true
                    continue
                }
                var additions = 0, deletions = 0
                git_patch_line_stats(nil, &additions, &deletions, patch)
                file.additions = additions
                file.deletions = deletions

                // Counts are all the summary needs; patch text is built only for
                // the open panel, and only while it fits the budget.
                guard request.includePatch else { continue }
                guard patchBytes.count + git_patch_size(patch, 1, 1, 1) <= request.patchByteLimit else {
                    snapshot.patchTruncated = true
                    continue
                }
                var buffer = git_buf()
                guard git_patch_to_buf(&buffer, patch) == 0 else { continue }
                if let pointer = buffer.ptr {
                    pointer.withMemoryRebound(to: UInt8.self, capacity: buffer.size) { bytes in
                        patchBytes.append(contentsOf: UnsafeBufferPointer(start: bytes, count: buffer.size))
                    }
                }
                git_buf_dispose(&buffer)
            }
        }
        collect(diff) { _ in true }

        // A path deleted from the index can still be a file on disk: after
        // `git rm --cached`, or when a new file takes a renamed one's old
        // name. The merged diff above keeps only the deletion (or folds it
        // into the rename), so those paths are read once more, against the
        // index, where they are untracked.
        if request.scope != .lastCommit {
            var repoIndex: OpaquePointer?
            git_repository_index(&repoIndex, repo)
            defer { if let repoIndex { git_index_free(repoIndex) } }
            let orphans = deletedPaths.filter { path in
                var info = stat()
                guard lstat(root + "/" + path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR, let repoIndex else {
                    return false
                }
                return git_index_get_bypath(repoIndex, path, 0) == nil
            }
            if !orphans.isEmpty {
                var untracked = git_diff_options()
                git_diff_options_init(&untracked, UInt32(GIT_DIFF_OPTIONS_VERSION))
                untracked.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
                    | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue | GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
                untracked.max_size = options.max_size
                var names: [UnsafeMutablePointer<CChar>?] = orphans.map { strdup($0) }
                defer { names.forEach { free($0) } }
                names.withUnsafeMutableBufferPointer { buffer in
                    untracked.pathspec.strings = buffer.baseAddress
                    untracked.pathspec.count = buffer.count
                    var second: OpaquePointer?
                    guard git_diff_index_to_workdir(&second, repo, repoIndex, &untracked) == 0, let second else { return }
                    collect(second) { $0 == GIT_DELTA_UNTRACKED }
                    git_diff_free(second)
                }
            }
        }

        snapshot.includesPatch = request.includePatch
        if request.includePatch {
            let parsed = GitDiffPatchParser.parse(String(decoding: patchBytes, as: UTF8.self))
            GitDiffProbeCommand.merge(parsed, into: &snapshot)
        }
        snapshot.removeDuplicateFiles()
        return .snapshot(snapshot)
    }

    /// The most rename detection may read in one pass.
    private static let similarityByteBudget: UInt64 = 16 * 1024 * 1024

    /// libgit2's own test for a blob mode: a regular file, executable or not.
    private static func isRegularFile(_ mode: UInt16) -> Bool {
        mode & 0o170000 == 0o100000
    }

    /// A side's size without reading it: the working tree's from the diff,
    /// a blob's from its header.
    private static func byteSize(_ file: git_diff_file, odb: OpaquePointer?) -> UInt64 {
        if file.size > 0 { return file.size }
        var oid = file.id
        guard let odb, !withUnsafeBytes(of: oid, { $0.allSatisfy { $0 == 0 } }) else { return 0 }
        var length = 0
        var type = GIT_OBJECT_BLOB
        guard git_odb_read_header(&length, &type, odb, &oid) == 0 else { return 0 }
        return UInt64(length)
    }

    /// FNV-1a over whatever identifies the diff.
    private struct Stamp {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325

        mutating func mix(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }

        mutating func mix(_ number: UInt64) {
            withUnsafeBytes(of: number) { mix($0) }
        }

        /// A separator follows, so "ab" + "c" and "a" + "bc" differ.
        mutating func mix(_ text: String) {
            for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            mix(UInt64.max)
        }
    }

    /// The tree of the merge base with the default branch, and that branch's name.
    private static func mergeBase(repo: OpaquePointer, headCommit: OpaquePointer) -> (tree: OpaquePointer, name: String)? {
        guard let headOID = git_object_id(headCommit) else { return nil }
        var candidates: [String] = []
        var originHead: OpaquePointer?
        if git_reference_lookup(&originHead, repo, "refs/remotes/origin/HEAD") == 0, let originHead {
            if let target = git_reference_symbolic_target(originHead) {
                let name = String(cString: target)
                candidates.append(name.hasPrefix("refs/remotes/") ? String(name.dropFirst("refs/remotes/".count)) : name)
            }
            git_reference_free(originHead)
        }
        candidates += ["origin/main", "origin/master", "main", "master"]

        for candidate in candidates {
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, candidate) == 0, let object else { continue }
            defer { git_object_free(object) }
            var commit: OpaquePointer?
            guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0, let commit else { continue }
            defer { git_object_free(commit) }
            var base = git_oid()
            guard let oid = git_object_id(commit), git_merge_base(&base, repo, oid, headOID) == 0 else { continue }
            var baseCommit: OpaquePointer?
            guard git_commit_lookup(&baseCommit, repo, &base) == 0, let baseCommit else { continue }
            defer { git_commit_free(baseCommit) }
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, baseCommit) == 0, let tree else { continue }
            return (tree, candidate)
        }
        return nil
    }

    private static func fileStatus(_ status: git_delta_t) -> GitDiffFileStatus {
        switch status {
        case GIT_DELTA_ADDED: .added
        case GIT_DELTA_DELETED: .deleted
        case GIT_DELTA_RENAMED: .renamed
        case GIT_DELTA_COPIED: .copied
        case GIT_DELTA_UNTRACKED: .untracked
        case GIT_DELTA_TYPECHANGE: .typeChanged
        case GIT_DELTA_CONFLICTED: .conflicted
        default: .modified
        }
    }

    private static func hexString(_ oid: UnsafePointer<git_oid>) -> String {
        let size = Int(GIT_OID_MAX_HEXSIZE)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size + 1)
        defer { buffer.deallocate() }
        git_oid_tostr(buffer, size + 1, oid)
        return String(cString: buffer)
    }
}

#endif
