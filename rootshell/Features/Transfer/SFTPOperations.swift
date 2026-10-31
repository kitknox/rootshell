//
//  SFTPOperations.swift
//  rootshell
//
//  Shared, stateless SFTP utilities used by SFTPSession (CLI), SCPTransfer
//  and FileSystemEndpoint (file manager and rf). All methods are static to
//  avoid duplicating logic across consumers.
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat

nonisolated extension Sequence {
    /// Sums peer-reported sizes without trapping: a server can claim UInt64.max bytes per file.
    func saturatingByteTotal(_ size: (Element) -> UInt64) -> Int64 {
        var total: UInt64 = 0
        for element in self {
            let (sum, overflow) = total.addingReportingOverflow(size(element))
            total = overflow ? .max : sum
        }
        return Int64(clamping: total)
    }
}

nonisolated extension Int64 {
    /// Adds two non-negative byte counts, pinning at Int64.max.
    func addingSaturating(_ other: Int64) -> Int64 {
        let (sum, overflow) = self.addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

/// Shared stateless SFTP operations.
/// The interactive SFTP shell (SFTPSession), scp, and FileSystemEndpoint's
/// SFTP backend call through to these methods.
enum SFTPOperations {

    // MARK: - Directory Listing

    /// List directory contents as RFEntry values. Symlinks are stat'ed so a link
    /// to a directory lists as a directory, and their targets are read. With
    /// `strict`, a malformed name fails the listing instead of being hidden.
    nonisolated static func listDirectoryEntries(
        sftp: SFTPClient,
        path: String,
        strict: Bool = false
    ) async throws -> [RFEntry] {
        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: path)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }

        var entries: [RFEntry] = []
        var linkIndices: [Int] = []
        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                guard FileTransferLogic.isSingleComponent(filename) else {
                    if strict { throw FileTransferLogic.UnsafeName(name: filename) }
                    continue
                }

                let entry = attributesToEntry(
                    filename: filename,
                    path: joinPath(path, filename),
                    attrs: component.attributes,
                    longname: component.longname
                )
                if entry.isSymlink { linkIndices.append(entries.count) }
                entries.append(entry)
            }
        }

        // Resolve links concurrently; a dangling link keeps its lstat view.
        let resolved = await withTaskGroup(of: (Int, SFTPFileAttributes?, String?).self) { group in
            for index in linkIndices {
                let linkPath = entries[index].path
                group.addTask {
                    async let target = try? sftp.getAttributes(at: linkPath)
                    async let destination = try? sftp.readLink(at: linkPath)
                    return (index, await target, await destination)
                }
            }
            var results: [(Int, SFTPFileAttributes?, String?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (index, targetAttrs, destination) in resolved {
            let link = entries[index]
            var entry = targetAttrs.map {
                attributesToEntry(filename: link.name, path: link.path, attrs: $0)
            } ?? link
            entry = RFEntry(
                name: entry.name, path: entry.path, isDirectory: entry.isDirectory,
                isSymlink: true, isHidden: entry.isHidden, isExecutable: entry.isExecutable,
                size: entry.size, modifiedDate: entry.modifiedDate, gitStatus: nil,
                permissions: link.permissions, symlinkTarget: destination, owner: link.owner
            )
            entries[index] = entry
        }
        return entries
    }

    /// Map SFTPFileAttributes to an RFEntry.
    nonisolated static func attributesToEntry(
        filename: String,
        path: String,
        attrs: SFTPFileAttributes,
        longname: String? = nil
    ) -> RFEntry {
        let isDir = isDirectory(attrs)
        let isLink: Bool
        if let mode = attrs.permissions {
            isLink = (mode & 0o170000) == 0o120000
        } else {
            // Longname starting with 'l' indicates symlink in ls -l output
            isLink = longname?.first == "l"
        }
        // Clamp to avoid trapping on a malicious/buggy server returning size > Int64.max.
        let size = Int64(clamping: attrs.size ?? 0)

        // Check execute bit for owner
        let isExec: Bool
        if let mode = attrs.permissions {
            isExec = !isDir && (mode & 0o100) != 0
        } else {
            isExec = false
        }

        return RFEntry(
            name: filename,
            path: path,
            isDirectory: isDir,
            isSymlink: isLink,
            isHidden: filename.hasPrefix("."),
            isExecutable: isExec,
            size: size,
            modifiedDate: attrs.accessModificationTime?.modificationTime,
            gitStatus: nil,
            permissions: attrs.permissions,
            owner: longname.flatMap(ownerFromLongname)
        )
    }

    /// The owner column of an `ls -l` style longname, e.g. "kit" in
    /// `-rw-r--r--    1 kit      staff    42 Jan  1 00:00 file`.
    nonisolated static func ownerFromLongname(_ longname: String) -> String? {
        let fields = longname.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[0].count >= 10 else { return nil }
        return String(fields[2])
    }

    // MARK: - Recursive Enumeration

    /// Recursively enumerate all files in a remote directory.
    /// Returns (path, size) pairs for files only. A malformed name fails it,
    /// so a transfer never reports success with entries missing.
    static func enumerateRemoteDirectory(
        sftp: SFTPClient,
        path: String
    ) async throws -> [(path: String, size: UInt64)] {
        var results: [(String, UInt64)] = []
        let nameMessages = try await sftp.listDirectory(atPath: path)

        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                guard FileTransferLogic.isSingleComponent(filename) else { throw FileTransferLogic.UnsafeName(name: filename) }

                let fullPath = joinPath(path, filename)
                var attrs = component.attributes
                if attrs.permissions == nil, let fetched = try? await sftp.getAttributes(at: fullPath) {
                    attrs = fetched
                }

                if isDirectory(attrs) {
                    let subResults = try await enumerateRemoteDirectory(sftp: sftp, path: fullPath)
                    results.append(contentsOf: subResults)
                } else {
                    results.append((fullPath, attrs.size ?? 0))
                }
            }
        }

        return results
    }

    // MARK: - Directory Operations

    /// Create a remote directory, creating parents recursively as needed.
    static func createDirectoryIfNeeded(
        sftp: SFTPClient,
        path: String
    ) async throws {
        // Try to get attributes — if it succeeds, directory exists
        do {
            _ = try await sftp.getAttributes(at: path)
            return
        } catch {
            // Directory doesn't exist, continue
        }

        // Create parent directories first
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." && parent != "/" {
            try await createDirectoryIfNeeded(sftp: sftp, path: parent)
        }

        // Create this directory
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            // Might already exist due to race condition
            do {
                _ = try await sftp.getAttributes(at: path)
            } catch {
                throw SFTPError.from(sftpError: error, path: path)
            }
        }
    }

    // MARK: - Path Utilities

    /// Join two POSIX path components.
    nonisolated static func joinPath(_ base: String, _ component: String) -> String {
        if component.isEmpty { return base }
        let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let cleanComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return cleanBase + "/" + cleanComponent
    }

    /// Normalize a POSIX-style remote path lexically, collapsing `.` and `..`
    /// without requiring the path to exist on the remote server.
    nonisolated static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "." }

        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }

        if isAbsolute {
            return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        }

        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// Get the parent directory of a POSIX path.
    nonisolated static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Split path into directory and filename.
    nonisolated static func splitPath(_ path: String) -> (directory: String, filename: String) {
        let nsPath = path as NSString
        return (nsPath.deletingLastPathComponent, nsPath.lastPathComponent)
    }

    /// Resolve a remote path, handling ~, ., relative, and absolute paths.
    static func resolvePath(
        _ rawPath: String,
        cwd: String,
        sftp: SFTPClient
    ) async throws -> String {
        // Turn escaped glob metacharacters back into literals for the real path.
        let path = unescapePath(rawPath)

        if path.isEmpty || path == "." {
            return cwd
        }

        if path.hasPrefix("/") {
            return path
        }

        if path.hasPrefix("~") {
            let homePath = try await sftp.getRealPath(atPath: ".")

            if path == "~" {
                return homePath
            } else if path.hasPrefix("~/") {
                let suffix = String(path.dropFirst(2))
                return joinPath(homePath, suffix)
            }
        }

        // Relative path
        return joinPath(cwd, path)
    }

    // MARK: - Attribute Checks

    /// Check if SFTP attributes indicate a directory (S_IFDIR).
    nonisolated static func isDirectory(_ attrs: SFTPFileAttributes) -> Bool {
        if let mode = attrs.permissions {
            return (mode & 0o170000) == 0o040000
        }
        return false
    }

    // MARK: - Glob Utilities

    private static let globChars: Set<Character> = ["*", "?", "[", "]"]

    /// Check if a path contains a glob character.
    ///
    /// `escapeAware` selects the escaping convention of the caller's tokenizer:
    /// - `false` (default, SCP): legacy behavior — any metacharacter is a glob.
    /// - `true` (SFTP): canonical escapes, where a backslash always escapes the next
    ///   char (`\\` = literal backslash, `\*` = literal `*`), so an escaped char is
    ///   never a glob. Thus `rm foo\*` is literal while `rm foo\\*` (a literal
    ///   backslash then a `*` wildcard) is a glob.
    ///
    /// The conventions differ because SCP's tokenizer is lossy (it collapses `\\` to
    /// `\`), so its tokens cannot be interpreted as canonical escapes.
    static func containsGlob(_ path: String, escapeAware: Bool = false) -> Bool {
        guard escapeAware else {
            return path.contains(where: { globChars.contains($0) })
        }
        var escaped = false
        for ch in path {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if globChars.contains(ch) {
                return true
            }
        }
        return false
    }

    /// Strip escapes from a tokenized path, producing the literal filesystem path.
    /// A backslash always escapes the next char (canonical token form), so `\\` →
    /// `\` and `\*` → `*`.
    static func unescapePath(_ path: String) -> String {
        guard path.contains("\\") else { return path }
        let chars = Array(path)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                result.append(chars[i + 1])
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// Split glob path into directory and filename pattern components.
    static func splitGlobPattern(_ path: String) -> (directory: String, pattern: String) {
        let nsPath = path as NSString
        let dir = nsPath.deletingLastPathComponent
        let pattern = nsPath.lastPathComponent
        return (dir.isEmpty ? "." : dir, pattern)
    }

    /// Check if a filename matches a glob pattern (supports *, ?, [...]).
    ///
    /// `escapeAware` must match the convention used by `containsGlob` for the same
    /// caller: `true` (SFTP) treats a backslash as escaping the next char; `false`
    /// (default, SCP) treats a backslash as a literal backslash.
    static func matchesGlob(_ name: String, pattern: String, escapeAware: Bool = false) -> Bool {
        var regex = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let char = pattern[i]
            switch char {
            case "\\":
                let next = pattern.index(after: i)
                if escapeAware, next < pattern.endIndex {
                    // Canonical: backslash escapes the next char → match it literally.
                    regex += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                    i = next
                } else {
                    // Legacy (or a trailing backslash): a literal backslash.
                    regex += "\\\\"
                }
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case "[":
                if let closeIndex = pattern[i...].firstIndex(of: "]") {
                    let classContent = String(pattern[i...closeIndex])
                    regex += classContent
                    i = closeIndex
                } else {
                    regex += "\\["
                }
            case ".":
                regex += "\\."
            case "^", "$", "+", "{", "}", "|", "(", ")":
                regex += "\\\(char)"
            default:
                regex += String(char)
            }
            i = pattern.index(after: i)
        }
        regex += "$"

        do {
            let regexObj = try NSRegularExpression(pattern: regex, options: [])
            return regexObj.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        } catch {
            return name == pattern
        }
    }

    /// Expand a remote glob pattern into matching full paths.
    static func expandRemoteGlob(
        sftp: SFTPClient,
        pattern: String,
        cwd: String
    ) async throws -> [String] {
        let (directory, filePattern) = splitGlobPattern(pattern)
        let includeDotfiles = filePattern.hasPrefix(".")

        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: directory)
        } catch {
            throw SFTPError.from(sftpError: error, path: pattern)
        }

        var matchingPaths: [String] = []
        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard FileTransferLogic.isSingleComponent(filename) else { continue }
                if !includeDotfiles && filename.hasPrefix(".") { continue }
                // SFTP-only path; its patterns use the canonical (escape-aware) form.
                if matchesGlob(filename, pattern: filePattern, escapeAware: true) {
                    matchingPaths.append(joinPath(directory, filename))
                }
            }
        }

        return matchingPaths.sorted()
    }

    /// Resolve a glob pattern's directory portion while keeping the filename glob untouched.
    static func resolveRemoteGlobPattern(
        _ pattern: String,
        cwd: String,
        sftp: SFTPClient
    ) async throws -> String {
        let (dir, filePattern) = splitGlobPattern(pattern)
        // SFTP-only path; its patterns use the canonical (escape-aware) form.
        if containsGlob(dir, escapeAware: true) {
            throw SFTPError.invalidArguments("Wildcards only supported in the last path component: \(pattern)")
        }
        let resolvedDir = try await resolvePath(dir, cwd: cwd, sftp: sftp)
        let canonicalDir = try await sftp.getRealPath(atPath: resolvedDir)
        return joinPath(canonicalDir, filePattern)
    }

    // MARK: - Formatting Helpers

    /// Format file permissions as rwxrwxrwx string.
    static func formatPermissions(_ mode: UInt32) -> String {
        let userMode = (mode >> 6) & 0o7
        let groupMode = (mode >> 3) & 0o7
        let otherMode = mode & 0o7

        func modeToString(_ m: UInt32) -> String {
            let r = (m & 0o4) != 0 ? "r" : "-"
            let w = (m & 0o2) != 0 ? "w" : "-"
            let x = (m & 0o1) != 0 ? "x" : "-"
            return r + w + x
        }

        return modeToString(userMode) + modeToString(groupMode) + modeToString(otherMode)
    }

    /// Format byte count for display.
    static func formatSize(_ size: Int64) -> String {
        if size < 1024 {
            return String(format: "%5d", size)
        } else if size < 1024 * 1024 {
            return String(format: "%4.1fK", Double(size) / 1024)
        } else if size < 1024 * 1024 * 1024 {
            return String(format: "%4.1fM", Double(size) / (1024 * 1024))
        } else {
            return String(format: "%4.1fG", Double(size) / (1024 * 1024 * 1024))
        }
    }

    /// Format date in ls-style (recent = time, old = year).
    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "            " }

        let formatter = DateFormatter()
        let now = Date()
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now

        if date > sixMonthsAgo {
            formatter.dateFormat = "MMM dd HH:mm"
        } else {
            formatter.dateFormat = "MMM dd  yyyy"
        }

        return formatter.string(from: date)
    }

    /// Format transfer throughput for display.
    static func formatThroughput(_ bps: Double) -> String {
        if bps < 1024 {
            return String(format: "%.0f B/s", bps)
        } else if bps < 1024 * 1024 {
            return String(format: "%.1f KB/s", bps / 1024)
        } else {
            return String(format: "%.1f MB/s", bps / (1024 * 1024))
        }
    }

    /// Format byte count for human-readable display.
    static func formatByteCount(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    /// Compute relative path from a base path.
    static func relativePath(from base: String, fullPath: String) -> String {
        let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let prefix = cleanBase + "/"
        if fullPath.hasPrefix(prefix) {
            return String(fullPath.dropFirst(prefix.count))
        }
        return (fullPath as NSString).lastPathComponent
    }
}
