//
//  GitDiffModel.swift
//  rootshell
//
//  Value types for the git diff panel. Pure and nonisolated so parsing runs
//  off the main actor and the tests compile them without the app.
//

import Foundation

/// What the panel compares.
nonisolated enum GitDiffScope: String, CaseIterable, Codable, Sendable {
    /// HEAD to the working tree, untracked files included.
    case uncommitted
    /// The merge base with the default branch to the working tree.
    case branch
    /// The last commit against its parent.
    case lastCommit
}

nonisolated enum GitDiffFileStatus: String, Sendable {
    case added, modified, deleted, renamed, copied, untracked, typeChanged, conflicted

    /// Maps a `--name-status` letter (`M`, `R100`, ...).
    init(nameStatus code: String) {
        switch code.first {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: self = .modified
        }
    }
}

nonisolated struct GitDiffLine: Equatable, Sendable {
    enum Kind: Sendable { case context, addition, deletion }

    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    /// Character range that differs from the paired line, when one was found.
    var emphasis: Range<Int>?
    /// The file ends here without a trailing newline.
    var noNewlineAtEnd = false
}

nonisolated struct GitDiffHunk: Equatable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// The text after the second `@@`, usually the enclosing function.
    var context: String
    var lines: [GitDiffLine]
}

nonisolated struct GitDiffFile: Equatable, Sendable, Identifiable {
    var path: String
    var oldPath: String?
    var status: GitDiffFileStatus
    /// nil when git reported no line counts (a binary file).
    var additions: Int?
    var deletions: Int?
    var isBinary = false
    var hunks: [GitDiffHunk] = []
    /// The patch for this file was cut off by the size limit.
    var isTruncated = false
    /// No patch arrived for this file (over the limit, or summary only).
    var hasPatch = false
    /// Longest line in UTF-16 units, for sizing unwrapped rows.
    var maxColumns = 0
    /// Over the size limit, so it was never read: no counts and no patch.
    var isTooLarge = false

    /// A path can be listed twice: `git rm --cached` leaves it both a staged
    /// deletion and a new file. The two entries need separate identities.
    var id: String { (status == .untracked ? "new:" : "tracked:") + path }

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

nonisolated struct GitDiffSnapshot: Equatable, Sendable {
    var repositoryRoot: String
    /// Branch name, or nil when HEAD is detached.
    var branch: String?
    var headSHA: String?
    /// The ref the branch scope compares against.
    var baseRef: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitDiffFile] = []
    /// Changes when anything the diff depends on changes.
    var stamp = ""
    /// The patch hit the size limit; totals still cover every change.
    var patchTruncated = false
    /// More untracked files exist than were listed.
    var untrackedTruncated = false
    /// Whether patches were requested for this snapshot.
    var includesPatch = false

    var additions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
    var isClean: Bool { files.isEmpty }
    /// A file was too large to read, or went unlisted, so the totals are a floor.
    var countsIncomplete: Bool { untrackedTruncated || files.contains { $0.isTooLarge } }

    /// Drops any entry that repeats an identity, keeping the first, so
    /// nothing downstream can key two rows alike.
    mutating func removeDuplicateFiles() {
        var seen = Set<String>()
        files = files.filter { seen.insert($0.id).inserted }
    }

    var repositoryName: String {
        repositoryRoot.split(separator: "/").last.map(String.init) ?? repositoryRoot
    }

    /// Branch, or the short commit for a detached HEAD.
    var headLabel: String? { branch ?? headSHA }
}

/// Why a diff could not be produced. Stable conditions, unlike a transport error.
nonisolated enum GitDiffUnavailable: Equatable, Sendable {
    case gitMissing
    case noDirectory
    case notARepository(directory: String)
}

nonisolated enum GitDiffFormat {
    /// `1234` as `1.2k`, matching the compact counts other agents show.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1000: return String(value)
        case ..<10_000:
            let tenths = (Double(value) / 100).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))k" : "\(tenths)k"
        case ..<1_000_000: return "\(Int((Double(value) / 1000).rounded()))k"
        default:
            let tenths = (Double(value) / 100_000).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))m" : "\(tenths)m"
        }
    }
}
