//
//  S3KeyLogic.swift
//  rootshell
//
//  Pure key rules for S3 listings and copies. No I/O, so it is unit-tested directly.
//

import Foundation

nonisolated enum S3KeyLogic {
    enum ListedKey: Equatable {
        case child(String)
        /// The folder's own marker, or a key outside the prefix.
        case ignored
        /// A name a path can't hold literally ("", ".", ".."): normalization would
        /// turn it into its parent, so it is never offered as an item.
        case unrepresentable
    }

    static func classify(_ key: String, under prefix: String) -> ListedKey {
        guard key.utf8.starts(with: prefix.utf8) else { return .ignored }
        let start = key.utf8.index(key.utf8.startIndex, offsetBy: prefix.utf8.count)
        var rest = key.utf8[start...]
        if rest.isEmpty { return .ignored }
        if rest.last == UInt8(ascii: "/") { rest = rest.dropLast() }
        if rest.isEmpty || rest.elementsEqual(".".utf8) || rest.elementsEqual("..".utf8) { return .unrepresentable }
        return rest.contains(UInt8(ascii: "/")) ? .ignored : .child(String(decoding: rest, as: UTF8.self))
    }

    /// `key` relative to `prefix` when it is a direct child, without a trailing slash.
    static func childName(_ key: String, under prefix: String) -> String? {
        if case .child(let name) = classify(key, under: prefix) { return name }
        return nil
    }

    // MARK: - Pagination and prefix search

    /// Raised when an S3 server claims a listing is truncated but supplies no
    /// advancing continuation token, preventing a partial listing from being
    /// accepted as complete (for example during a move that deletes the source).
    enum PaginationError: LocalizedError, Equatable, Sendable {
        case stalled

        var errorDescription: String? {
            switch self {
            case .stalled:
                String(
                    localized: "The server returned a truncated listing that couldn't advance to the next page.",
                    comment: "Storage error: S3 pagination token missing or repeated on a truncated response"
                )
            }
        }
    }

    /// Whether `query` can filter direct children of an S3 folder through
    /// `ListObjectsV2`'s `prefix` with `delimiter: "/"`. A slash would descend into
    /// a subfolder whose keys `classify(_:under:)` intentionally ignores.
    static func isValidChildPrefix(_ query: String) -> Bool {
        !query.isEmpty && !query.utf8.contains(UInt8(ascii: "/"))
    }

    /// The `prefix` sent to `ListObjectsV2` for a folder (`""` or `"dir/"`) and an
    /// optional direct-child name prefix. nil when listing a bucket root unfiltered.
    static func objectListPrefix(directoryPrefix: String, namePrefix: String?) -> String? {
        if let namePrefix, !namePrefix.isEmpty {
            return directoryPrefix + namePrefix
        }
        return directoryPrefix.isEmpty ? nil : directoryPrefix
    }

    /// `max-buckets` value for endpoints supporting AWS-style paginated `ListBuckets`
    /// (1…10,000), or nil for S3-compatible servers (such as Ceph RGW) that expect a
    /// plain `GET /` service request.
    static func bucketListMaxBuckets(pageSize: Int, supportsPaginatedBuckets: Bool) -> Int? {
        guard supportsPaginatedBuckets else { return nil }
        return max(1, min(pageSize, 10_000))
    }

    /// Next continuation token from `ListObjectsV2`, comparing raw UTF-8 bytes so
    /// canonically equivalent object-name markers (such as NFC vs NFD on Ceph RGW)
    /// stay distinct, and throwing if a truncated response cannot advance.
    static func nextContinuationToken(isTruncated: Bool?, nextToken: String?, currentToken: String?) throws -> String? {
        guard isTruncated == true else { return nil }
        guard let nextToken, !nextToken.isEmpty else { throw PaginationError.stalled }
        if let currentToken, nextToken.utf8.elementsEqual(currentToken.utf8) {
            throw PaginationError.stalled
        }
        return nextToken
    }

    /// Next continuation token from `ListBuckets`, comparing raw UTF-8 bytes and
    /// throwing if the server repeats the current token.
    static func nextBucketContinuationToken(nextToken: String?, currentToken: String?) throws -> String? {
        guard let nextToken, !nextToken.isEmpty else { return nil }
        if let currentToken, nextToken.utf8.elementsEqual(currentToken.utf8) {
            throw PaginationError.stalled
        }
        return nextToken
    }

    /// Fetches pages starting at `cursor` until one yields at least one item or the
    /// server reports no further pages. Skips pages containing only ignored keys
    /// (such as a folder's own marker), tracks continuation tokens by exact UTF-8
    /// bytes, and throws `PaginationError.stalled` if a truncated response cycles.
    static func fetchNonEmptyPage<Item>(
        startingAt cursor: String?,
        fetch: (_ token: String?) async throws -> (items: [Item], nextToken: String?)
    ) async throws -> (items: [Item], nextCursor: String?) {
        var token = cursor
        var seen: Set<[UInt8]> = cursor.map { [Array($0.utf8)] } ?? []
        while true {
            try Task.checkCancellation()
            let (items, rawNext) = try await fetch(token)
            let next: String?
            if let candidate = rawNext {
                guard !candidate.isEmpty, seen.insert(Array(candidate.utf8)).inserted else {
                    throw PaginationError.stalled
                }
                next = candidate
            } else {
                next = nil
            }
            if !items.isEmpty || next == nil {
                return (items, next)
            }
            token = next
        }
    }

    /// Appends a newly loaded page onto `existing`, replacing in place when an item
    /// reappears across a page boundary (e.g. concurrent writes shifted key offsets).
    static func mergePage<Item, Key: Hashable>(
        _ existing: [Item],
        with incoming: [Item],
        key: (Item) -> Key
    ) -> [Item] {
        guard !incoming.isEmpty else { return existing }
        var result = existing
        var indexByKey: [Key: Int] = [:]
        indexByKey.reserveCapacity(existing.count + incoming.count)
        for (index, item) in existing.enumerated() {
            let itemKey = key(item)
            if indexByKey[itemKey] == nil {
                indexByKey[itemKey] = index
            }
        }
        for item in incoming {
            let itemKey = key(item)
            if let existingIndex = indexByKey[itemKey] {
                result[existingIndex] = item
            } else {
                indexByKey[itemKey] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// What a pane should do with S3 server-side prefix search when its filter changes.
    enum PrefixSearchAction: Equatable {
        /// Drop any server prefix state and filter locally.
        case clear
        /// Existing server prefix results already cover `query` (same UTF-8 prefix, or
        /// a narrower UTF-8 prefix of an already-exhausted search); filter them locally.
        case keepCurrent
        /// Query S3 for `query`. When `keepExistingWhileLoading` is true, existing
        /// results stay visible (locally filtered) while waiting to avoid flicker.
        case fetch(query: String, keepExistingWhileLoading: Bool)
    }

    /// Decides whether typing `query` needs a server-side S3 prefix request.
    /// Defers searches while a directory load is in flight, and always filters locally
    /// once a folder is completely loaded (`baseHasMore == false`).
    static func prefixSearchAction(
        query: String,
        isListingReady: Bool = true,
        supportsPrefixSearch: Bool,
        baseHasMore: Bool,
        activePrefix: String?,
        prefixHasMore: Bool
    ) -> PrefixSearchAction {
        guard isListingReady, supportsPrefixSearch, baseHasMore, isValidChildPrefix(query) else {
            return .clear
        }
        if let activePrefix, query.utf8.starts(with: activePrefix.utf8) {
            if !prefixHasMore || query.utf8.elementsEqual(activePrefix.utf8) {
                return .keepCurrent
            }
            return .fetch(query: query, keepExistingWhileLoading: true)
        }
        return .fetch(query: query, keepExistingWhileLoading: false)
    }

    /// `bucket/key`, URL-encoded as the x-amz-copy-source header requires.
    /// With `versionID`, the copy reads exactly that version, metadata included.
    static func copySource(bucket: String, key: String, versionID: String? = nil) -> String {
        let raw = bucket + "/" + key
        let source = raw.addingPercentEncoding(withAllowedCharacters: copySourceAllowed) ?? raw
        guard let versionID, versionID != "null" else { return source }
        return source + "?versionId=" + (versionID.addingPercentEncoding(withAllowedCharacters: unreserved) ?? versionID)
    }

    /// RFC 3986 unreserved characters plus "/"; `.alphanumerics` would pass non-ASCII letters.
    private static let copySourceAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )
    private static let unreserved = copySourceAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// An object's URL on `endpoint`, addressed the way S3 requests are routed:
    /// virtual-host on native AWS S3 or when forced, unless the bucket name isn't a plain
    /// DNS label. Non-AWS gateways hosted on `*.amazonaws.com` (such as Ceph behind an ALB)
    /// use path style unless virtual-host addressing is explicitly forced.
    /// Bucket names come from the server, so both are encoded or checked before use.
    static func objectURL(endpoint: String, bucket: String, key: String, forceVirtualHost: Bool) -> URL? {
        guard var components = URLComponents(string: endpoint), let host = components.host else { return nil }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: copySourceAllowed) ?? key
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let isNativeAWS = StorageProvider.nativeAWSPartition(forHost: host) != nil
        if (forceVirtualHost || isNativeAWS) && isHostLabel(bucket) {
            // An endpoint may already name the bucket as its first label.
            if host.split(separator: ".").first != Substring(bucket) { components.host = bucket + "." + host }
            components.percentEncodedPath = base + "/" + encodedKey
        } else {
            guard let encodedBucket = bucket.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            components.percentEncodedPath = base + "/" + encodedBucket + "/" + encodedKey
        }
        return components.url
    }

    /// Reverts Soto `S3Middleware`'s virtual-host bucket prefixing (`<bucket>.<endpointHost>/<path>`)
    /// back to path-style (`<endpointHost>/<bucket>/<path>`) for path-style custom gateways hosted
    /// under `*.amazonaws.com[.cn]` (such as Ceph RGW behind an AWS ALB/NLB), preserving exact
    /// percent-encoding and query parameters. Returns nil when `url` already targets `endpointHost`.
    static func restorePathStyleURL(_ url: URL, endpointHost: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let requestHost = components.host?.lowercased() else { return nil }
        let targetHost = endpointHost.lowercased()
        let suffix = "." + targetHost
        guard requestHost.hasSuffix(suffix) else { return nil }
        let bucket = String(requestHost.dropLast(suffix.count))
        guard !bucket.isEmpty,
              let encodedBucket = bucket.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        components.host = targetHost
        let existingPath = components.percentEncodedPath
        if existingPath.isEmpty || existingPath == "/" {
            components.percentEncodedPath = "/" + encodedBucket
        } else if existingPath.hasPrefix("/") {
            components.percentEncodedPath = "/" + encodedBucket + existingPath
        } else {
            components.percentEncodedPath = "/" + encodedBucket + "/" + existingPath
        }
        return components.url
    }

    private static let hostLabelAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
    )

    private static func isHostLabel(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 63 && name.unicodeScalars.allSatisfy(hostLabelAllowed.contains)
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    /// ETags arrive quoted from some calls and unquoted from others.
    static func unquotedETag(_ eTag: String) -> String {
        eTag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    struct Grant: Equatable {
        enum Grantee: Equatable {
            case id(String)
            case uri(String)
            case email(String)
        }

        let grantee: Grantee
        let permission: String
    }

    /// An object ACL as x-amz-grant-* values keyed by permission; nil when it is
    /// only the owner's full control, which every new object gets anyway.
    static func grantHeaders(_ grants: [Grant], ownerID: String?) -> [String: String]? {
        let ownerOnly = grants.allSatisfy { grant in
            if case .id(let id) = grant.grantee, id == ownerID, grant.permission == "FULL_CONTROL" { return true }
            return false
        }
        guard !ownerOnly else { return nil }
        var values: [String: [String]] = [:]
        for grant in grants {
            let value = switch grant.grantee {
            case .id(let id): "id=\"\(id)\""
            case .uri(let uri): "uri=\"\(uri)\""
            case .email(let email): "emailAddress=\"\(email)\""
            }
            values[grant.permission, default: []].append(value)
        }
        return values.mapValues { $0.joined(separator: ", ") }
    }

    /// Tags as the x-amz-tagging header's URL query form.
    static func tagging(_ tags: [(key: String, value: String)]) -> String {
        tags.map { tag in
            let key = tag.key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? tag.key
            let value = tag.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? tag.value
            return key + "=" + value
        }.joined(separator: "&")
    }

    /// How a server wants `If-Match` spelled on a conditional PutObject. Ceph's
    /// gateway compares the header to its stored ETag literally, so it refuses
    /// the standard quoted form and only matches the bare one.
    enum ConditionalPut: Equatable {
        case quoted
        case bare
        /// Neither spelling is accepted, so the check before the upload is the only guard.
        case unsupported

        /// The next spelling to try after a server refused this one for an unchanged object.
        var fallback: ConditionalPut? {
            switch self {
            case .quoted: .bare
            case .bare: .unsupported
            case .unsupported: nil
            }
        }

        func ifMatch(_ eTag: String) -> String? {
            let bare = eTag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return switch self {
            case .quoted: "\"\(bare)\""
            case .bare: bare
            case .unsupported: nil
            }
        }
    }

    /// The DNS-compatible bucket naming rules every provider accepts.
    static func isValidBucketName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let edges = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard (3...63).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains),
              let first = name.unicodeScalars.first, let last = name.unicodeScalars.last,
              edges.contains(first), edges.contains(last) else { return false }
        return !name.contains("..") && !name.contains(".-") && !name.contains("-.")
    }

    /// Header-safe custom metadata: token characters in names, printable ASCII in values.
    static func isValidMetadata(key: String, value: String) -> Bool {
        let keyAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return !key.isEmpty && key.unicodeScalars.allSatisfy(keyAllowed.contains) && isValidHeaderValue(value)
    }

    /// Printable ASCII only; anything else breaks request signing on most servers.
    static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    enum RestoreState: Equatable {
        case none
        case inProgress
        case restored(until: Date?)
    }

    /// Parses x-amz-restore: `ongoing-request="false", expiry-date="Fri, 21 Dec 2012 00:00:00 GMT"`.
    static func restoreState(_ header: String?) -> RestoreState {
        guard let header, header.contains("ongoing-request") else { return .none }
        if header.contains("ongoing-request=\"true\"") { return .inProgress }
        guard let start = header.range(of: "expiry-date=\"")?.upperBound,
              let end = header[start...].firstIndex(of: "\"") else { return .restored(until: nil) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return .restored(until: formatter.date(from: String(header[start..<end])))
    }
}
