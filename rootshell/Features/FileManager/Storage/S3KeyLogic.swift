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
        guard key.hasPrefix(prefix) else { return .ignored }
        var rest = key.dropFirst(prefix.count)
        if rest.isEmpty { return .ignored }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.isEmpty || rest == "." || rest == ".." { return .unrepresentable }
        return rest.contains("/") ? .ignored : .child(String(rest))
    }

    /// `key` relative to `prefix` when it is a direct child, without a trailing slash.
    static func childName(_ key: String, under prefix: String) -> String? {
        if case .child(let name) = classify(key, under: prefix) { return name }
        return nil
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

    /// An object's URL on `endpoint`, addressed the way Soto's S3 middleware would:
    /// virtual-host on AWS or when forced, unless the bucket name isn't a plain DNS label.
    /// Bucket names come from the server, so both are encoded or checked before use.
    static func objectURL(endpoint: String, bucket: String, key: String, forceVirtualHost: Bool) -> URL? {
        guard var components = URLComponents(string: endpoint), let host = components.host else { return nil }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: copySourceAllowed) ?? key
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        if (forceVirtualHost || host.hasSuffix("amazonaws.com")) && isHostLabel(bucket) {
            // An endpoint may already name the bucket as its first label.
            if host.split(separator: ".").first != Substring(bucket) { components.host = bucket + "." + host }
            components.percentEncodedPath = base + "/" + encodedKey
        } else {
            guard let encodedBucket = bucket.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            components.percentEncodedPath = base + "/" + encodedBucket + "/" + encodedKey
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
