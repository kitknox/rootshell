//
//  FileTransferLogic.swift
//  rootshell
//
//  Pure transfer rules: destination mapping, conflict naming, rate and ETA.
//  No I/O, so it is unit-tested directly.
//

import Foundation

/// What to do when a transfer's destination already exists.
nonisolated enum TransferConflictResolution: String, CaseIterable, Sendable {
    case replace
    case skip
    case keepBoth
    /// Directories only: copy into the existing directory, replacing clashing files.
    case merge
}

nonisolated enum FileTransferLogic {
    /// Whether a listed name stays in its folder when joined. A slash or NUL can't
    /// appear in one on disk; only a hostile server sends it, to steer a copy elsewhere.
    static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.utf8.contains(UInt8(ascii: "/"))
            && !name.utf8.contains(0)
    }

    /// A listed name that would place a copy outside its folder.
    struct UnsafeName: LocalizedError {
        let name: String

        var errorDescription: String? {
            String(
                localized: "“\(name)” wasn't copied because its name isn't a valid file name.",
                comment: "File transfer error; argument is a file name sent by the server"
            )
        }
    }

    /// The source item switched between file and folder after the pane listed it.
    struct ItemTypeChanged: LocalizedError, Equatable, Sendable {
        let name: String

        var errorDescription: String? {
            String(
                localized: "“\(name)” changed type since it was listed. Refresh and try again.",
                comment: "File transfer error when a file became a folder or vice versa before mutation; argument is an item name"
            )
        }
    }

    /// POSIX join that tolerates trailing and leading ASCII slashes without
    /// breaking names that start with combining marks.
    static func join(_ base: String, _ component: String) -> String {
        if component.isEmpty { return base }
        let slash = UInt8(ascii: "/")
        var baseBytes = base.utf8[...]
        if baseBytes.count > 1, baseBytes.last == slash { baseBytes = baseBytes.dropLast() }
        var compBytes = component.utf8[...]
        if compBytes.first == slash { compBytes = compBytes.dropFirst() }
        let trimmedBase = String(decoding: baseBytes, as: UTF8.self)
        let trimmedComponent = String(decoding: compBytes, as: UTF8.self)
        return trimmedBase == "/" ? "/" + trimmedComponent : trimmedBase + "/" + trimmedComponent
    }

    /// Splits `path` on ASCII `/` bytes so names beginning with combining marks
    /// (such as `dir/\u{0301}report`) never fuse with the preceding slash.
    static func pathComponents(of path: String) -> [String] {
        path.utf8
            .split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func lastComponent(of path: String) -> String {
        let slash = UInt8(ascii: "/")
        var bytes = path.utf8[...]
        if bytes.count > 1, bytes.last == slash { bytes = bytes.dropLast() }
        guard let last = bytes.split(separator: slash).last else {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: last, as: UTF8.self)
    }

    static func parent(of path: String) -> String {
        let slash = UInt8(ascii: "/")
        var bytes = path.utf8[...]
        if bytes.count > 1, bytes.last == slash { bytes = bytes.dropLast() }
        guard let index = bytes.lastIndex(of: slash) else { return "." }
        return index == bytes.startIndex ? "/" : String(decoding: bytes[..<index], as: UTF8.self)
    }

    /// Absolute form with `.`, `..` and repeated slashes removed, purely lexically
    /// (unlike `standardizingPath`, which consults the local disk).
    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in pathComponents(of: path) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Maps `path` under `sourceRoot` to the same place under `destinationRoot`.
    static func destination(for path: String, sourceRoot: String, destinationRoot: String) -> String {
        guard !path.utf8.elementsEqual(sourceRoot.utf8) else { return destinationRoot }
        let slash = UInt8(ascii: "/")
        let prefix = sourceRoot.utf8.last == slash ? sourceRoot : sourceRoot + "/"
        guard path.utf8.starts(with: prefix.utf8) else { return join(destinationRoot, lastComponent(of: path)) }
        let suffix = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return join(destinationRoot, suffix)
    }

    /// True when `candidate` is `directory` or lies beneath it, so copying
    /// `directory` into `candidate` would recurse into itself.
    /// With `exactBytes: true` (object storage, where keys are raw UTF-8 bytes),
    /// canonically equivalent spellings such as NFC `café` and NFD `café` stay distinct.
    /// With `exactBytes: false` (default, for normalization-insensitive volumes),
    /// Swift String equality/prefixing is also checked conservatively.
    static func isSameOrDescendant(_ candidate: String, of directory: String, exactBytes: Bool = false) -> Bool {
        let slash = UInt8(ascii: "/")
        let prefix = directory.utf8.last == slash ? directory : directory + "/"
        if candidate.utf8.elementsEqual(directory.utf8) || candidate.utf8.starts(with: prefix.utf8) {
            return true
        }
        guard !exactBytes else { return false }
        return candidate == directory || candidate.hasPrefix(prefix)
    }

    /// True when either path is the other or lies beneath it.
    static func pathsOverlap(_ a: String, _ b: String, exactBytes: Bool = false) -> Bool {
        isSameOrDescendant(a, of: b, exactBytes: exactBytes) || isSameOrDescendant(b, of: a, exactBytes: exactBytes)
    }

    /// Whether two S3 bucket components could name the same bucket on a multi-tenant
    /// gateway such as Ceph RGW, where an unqualified `bucket` resolves to the caller's
    /// tenant and `tenant:bucket` addresses an explicit tenant.
    static func s3BucketsMayAlias(_ a: String, _ b: String) -> Bool {
        if a.utf8.elementsEqual(b.utf8) { return true }
        let (tenantA, bareA) = splitS3TenantBucket(a)
        let (tenantB, bareB) = splitS3TenantBucket(b)
        guard bareA.utf8.elementsEqual(bareB.utf8) else { return false }
        return tenantA == nil || tenantB == nil
    }

    /// Whether two S3 `/bucket/key` paths could name the exact same object or prefix
    /// across two different-credential profiles on the same multi-tenant gateway.
    static func s3PathsMayAlias(_ a: String, _ b: String) -> Bool {
        let aParts = pathComponents(of: normalize(a))
        let bParts = pathComponents(of: normalize(b))
        guard aParts.count == bParts.count else { return false }
        guard let aBucket = aParts.first, let bBucket = bParts.first else { return true }
        guard s3BucketsMayAlias(aBucket, bBucket) else { return false }
        return zip(aParts.dropFirst(), bParts.dropFirst()).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// Whether `candidate` equals or lies beneath `directory` across two different-credential
    /// profiles on the same multi-tenant S3 gateway (accounting for `tenant:bucket` aliasing `bucket`).
    static func s3IsSameOrDescendantAssumingPossibleTenantAlias(_ candidate: String, of directory: String) -> Bool {
        let candParts = pathComponents(of: normalize(candidate))
        let dirParts = pathComponents(of: normalize(directory))
        if dirParts.isEmpty { return true }
        guard let candBucket = candParts.first, let dirBucket = dirParts.first,
              s3BucketsMayAlias(candBucket, dirBucket) else { return false }
        let candKey = "/" + candParts.dropFirst().joined(separator: "/")
        let dirKey = "/" + dirParts.dropFirst().joined(separator: "/")
        return isSameOrDescendant(candKey, of: dirKey, exactBytes: true)
    }

    private static func splitS3TenantBucket(_ bucket: String) -> (tenant: String?, bare: String) {
        let colon = UInt8(ascii: ":")
        guard let index = bucket.utf8.firstIndex(of: colon) else { return (nil, bucket) }
        let tenant = String(decoding: bucket.utf8[..<index], as: UTF8.self)
        let bare = String(decoding: bucket.utf8[bucket.utf8.index(after: index)...], as: UTF8.self)
        return (tenant.isEmpty ? nil : tenant, bare)
    }

    /// Where two paths that fold alike are spelled differently, as short distinct
    /// pairs compared by bytes (String equality ignores Unicode spellings). A volume
    /// treats the paths as one only if it treats every pair as one.
    static func differingSpellings(_ a: String, _ b: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        var seen: Set<[UInt8]> = []
        func add(_ x: ArraySlice<Character>, _ y: ArraySlice<Character>) {
            let x = String(x), y = String(y)
            guard seen.insert(Array(x.utf8) + [0] + Array(y.utf8)).inserted else { return }
            pairs.append((x, y))
        }
        func folded(_ s: ArraySlice<Character>) -> String {
            String(s).folding(options: .caseInsensitive, locale: nil)
        }
        for (x, y) in zip(pathComponents(of: a), pathComponents(of: b)) where !x.utf8.elementsEqual(y.utf8) {
            let first = Array(x), second = Array(y)
            var i = 0, j = 0
            while i < first.count, j < second.count {
                if first[i].unicodeScalars.elementsEqual(second[j].unicodeScalars) {
                    i += 1
                    j += 1
                    continue
                }
                // The shortest stretches that fold alike, aligned by folding rather than
                // position (ßSS and SSß); a character folds to at most three.
                guard let (k, l) = foldWindows.first(where: { k, l in
                    i + k <= first.count && j + l <= second.count && folded(first[i..<(i + k)]) == folded(second[j..<(j + l)])
                }) else { break }
                add(first[i..<(i + k)], second[j..<(j + l)])
                i += k
                j += l
            }
            // Only if the folds didn't line up, which grouped names never do.
            if i < first.count || j < second.count { add(first[i...], second[j...]) }
        }
        return pairs
    }

    /// Stretch lengths to try, shortest first.
    private static let foldWindows: [(Int, Int)] = (2...6).flatMap { total in
        (1...3).compactMap { k in (1...3).contains(total - k) ? (k, total - k) : nil }
    }

    /// "name.ext" → "name 2.ext", skipping names in `existing`. Dotfiles keep their
    /// leading dot and multi-part extensions like ".tar.gz" stay attached.
    static func keepBothName(for name: String, existing: Set<String>) -> String {
        let (stem, suffix) = splitExtension(name)
        var index = 2
        while true {
            let candidate = "\(stem) \(index)\(suffix)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    static func splitExtension(_ name: String) -> (stem: String, suffix: String) {
        let body = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let lead = name.hasPrefix(".") ? "." : ""
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, !(parts.first?.isEmpty ?? true) else { return (name, "") }
        let compound = ["tar"]
        var extensionCount = 1
        if parts.count > 2, compound.contains(String(parts[parts.count - 2]).lowercased()) {
            extensionCount = 2
        }
        let stem = parts.dropLast(extensionCount).joined(separator: ".")
        let suffix = "." + parts.suffix(extensionCount).joined(separator: ".")
        return (lead + stem, suffix)
    }

    /// Exact UTF-8 bytes of destination folders that already receive at least one file
    /// on object storage, so only genuinely empty folders emit a zero-byte marker.
    /// Compares raw UTF-8 bytes so an NFD populated sibling never hides an empty NFC marker.
    static func implicitPopulatedFolderBytes(fileDestinations: [String]) -> Set<[UInt8]> {
        var filled: Set<[UInt8]> = []
        for destination in fileDestinations {
            var current = parent(of: destination)
            while current != "/", current != ".", filled.insert(folderBytesKey(current)).inserted {
                current = parent(of: current)
            }
        }
        return filled
    }

    static func folderBytesKey(_ path: String) -> [UInt8] {
        var bytes = path.utf8[...]
        if bytes.count > 1, bytes.last == UInt8(ascii: "/") {
            bytes = bytes.dropLast()
        }
        return Array(bytes)
    }
}

/// Destination names for one job's items in one folder. Every name the job will
/// create is reserved, so "Keep Both" never picks a name another item in the
/// same job is about to take, and duplicate incoming names never overwrite.
/// On object storage (`separatesByExactBytesAndType: true`), reservations distinguish
/// raw UTF-8 bytes and entry type so `foo` + `foo/` or NFC + NFD siblings keep their names.
nonisolated struct TransferNamePlanner: Sendable {
    struct EntryKey: Hashable, Sendable {
        let nameBytes: [UInt8]
        let isDirectory: Bool

        init(name: String, isDirectory: Bool) {
            nameBytes = Array(name.utf8)
            self.isDirectory = isDirectory
        }
    }

    private enum Key: Hashable, Sendable {
        case posix(String)
        case exact(EntryKey)
    }

    let separatesByExactBytesAndType: Bool
    private let incoming: Set<Key>
    private var claimed: Set<Key> = []

    init(incomingNames: [String]) {
        separatesByExactBytesAndType = false
        incoming = Set(incomingNames.map(Key.posix))
    }

    init(incomingEntries: [(name: String, isDirectory: Bool)], separatesByExactBytesAndType: Bool) {
        self.separatesByExactBytesAndType = separatesByExactBytesAndType
        incoming = Set(incomingEntries.map { entry in
            separatesByExactBytesAndType
                ? .exact(EntryKey(name: entry.name, isDirectory: entry.isDirectory))
                : .posix(entry.name)
        })
    }

    private func makeKey(_ name: String, isDirectory: Bool) -> Key {
        separatesByExactBytesAndType
            ? .exact(EntryKey(name: name, isDirectory: isDirectory))
            : .posix(name)
    }

    /// True when an earlier item in this job already targets `name` (and `isDirectory` on S3).
    func isClaimed(_ name: String, isDirectory: Bool = false) -> Bool {
        claimed.contains(makeKey(name, isDirectory: isDirectory))
    }

    mutating func claim(_ name: String, isDirectory: Bool = false) {
        claimed.insert(makeKey(name, isDirectory: isDirectory))
    }

    /// Claims a "name N" that is not on disk, not claimed, and not another incoming name.
    mutating func claimKeepBothName(for name: String, existingOnDisk: Set<String>) -> String {
        claimKeepBothName(
            for: name,
            isDirectory: false,
            existingEntries: Set(existingOnDisk.map { EntryKey(name: $0, isDirectory: false) })
        )
    }

    mutating func claimKeepBothName(
        for name: String,
        isDirectory: Bool,
        existingEntries: Set<EntryKey>
    ) -> String {
        let existingKeys: Set<Key> = Set(existingEntries.map { entry in
            separatesByExactBytesAndType
                ? .exact(entry)
                : .posix(String(decoding: entry.nameBytes, as: UTF8.self))
        })
        let reserved = existingKeys.union(claimed).union(incoming)
        let (stem, suffix) = FileTransferLogic.splitExtension(name)
        var index = 2
        while true {
            let candidate = "\(stem) \(index)\(suffix)"
            let key = makeKey(candidate, isDirectory: isDirectory)
            if !reserved.contains(key) {
                claimed.insert(key)
                return candidate
            }
            index += 1
        }
    }
}

/// Exponentially smoothed throughput from cumulative byte samples.
nonisolated struct TransferRateMeter: Sendable {
    /// Weight of the newest sample; lower is smoother.
    var smoothing = 0.3
    private(set) var bytesPerSecond: Double = 0
    private var lastBytes: Int64?
    private var lastTime: TimeInterval?

    mutating func record(totalBytes: Int64, at time: TimeInterval) {
        defer {
            lastBytes = totalBytes
            lastTime = time
        }
        guard let lastBytes, let lastTime, time > lastTime, totalBytes >= lastBytes else { return }
        let instant = Double(totalBytes - lastBytes) / (time - lastTime)
        bytesPerSecond = bytesPerSecond == 0 ? instant : smoothing * instant + (1 - smoothing) * bytesPerSecond
    }

    /// Seconds left for `remaining` bytes, nil until a rate is known.
    func eta(remainingBytes: Int64) -> TimeInterval? {
        guard bytesPerSecond > 0, remainingBytes >= 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}

/// Gates UI publication to a maximum rate.
nonisolated struct PublishThrottle: Sendable {
    let interval: TimeInterval
    private var last: TimeInterval = -.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldPublish(at time: TimeInterval, force: Bool = false) -> Bool {
        guard force || time - last >= interval else { return false }
        last = time
        return true
    }
}
