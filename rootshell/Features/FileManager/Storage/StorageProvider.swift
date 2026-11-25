//
//  StorageProvider.swift
//  rootshell
//
//  A saved S3-compatible storage account. The whole config, credentials
//  included, lives in one iCloud Keychain item so it syncs across devices.
//

import Foundation

nonisolated struct StorageProvider: Codable, Identifiable, Hashable, Sendable {
    enum AddressingStyle: String, Codable, CaseIterable, Sendable {
        /// `https://endpoint/bucket/key`
        case path
        /// `https://bucket.endpoint/key`
        case virtualHost
    }

    var id = UUID()
    var name = ""
    var presetID = StorageProviderPreset.amazonS3.id
    var region = ""
    /// Account-specific endpoint part, for presets that ask for one.
    var accountID = ""
    /// Replaces the preset's endpoint; required for self-hosted servers.
    var customEndpoint = ""
    /// nil follows the preset.
    var addressingStyle: AddressingStyle?
    /// Overrides the region used in request signatures; empty follows the preset.
    var signingRegion = ""
    /// Empty for anonymous access to public buckets.
    var accessKeyID = ""
    var secretAccessKey = ""
    var sessionToken = ""
    /// Limits the provider to one bucket; empty lists every bucket.
    var bucket = ""
    /// Where a pane starts, relative to the provider's root.
    var initialPath = ""

    init() {}

    init(from decoder: Decoder) throws {
        // Tolerant decoding: items written by newer builds sync to older ones.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID) ?? StorageProviderPreset.custom.id
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint) ?? ""
        addressingStyle = try? container.decodeIfPresent(AddressingStyle.self, forKey: .addressingStyle)
        signingRegion = try container.decodeIfPresent(String.self, forKey: .signingRegion) ?? ""
        accessKeyID = try container.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        secretAccessKey = try container.decodeIfPresent(String.self, forKey: .secretAccessKey) ?? ""
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        initialPath = try container.decodeIfPresent(String.self, forKey: .initialPath) ?? ""
    }

    var preset: StorageProviderPreset {
        StorageProviderPreset.preset(for: presetID)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? preset.name : trimmed
    }

    /// Region used for signing and, for most presets, in the endpoint host.
    var effectiveRegion: String {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? preset.defaultRegion : trimmed
    }

    /// Region in the request signature. Usually the endpoint's region, but some
    /// Ceph-based services only accept a fixed one.
    var effectiveSigningRegion: String {
        let trimmed = signingRegion.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return preset.signingRegion ?? effectiveRegion
    }

    /// Explicitly configured bucket, or the bucket encoded in a virtual-hosted native
    /// Amazon S3 hostname (such as `my-bucket.s3.us-east-1.amazonaws.com`) so account-level
    /// `ListBuckets` is never sent to a bucket-specific AWS host.
    var effectiveBucket: String? {
        let trimmed = bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !trimmed.isEmpty { return trimmed }
        return endpointBucket
    }

    /// Bucket encoded in a virtual-hosted native Amazon S3 endpoint hostname, if any.
    var endpointBucket: String? {
        guard let endpoint = resolvedEndpoint,
              let host = URL(string: endpoint)?.host?.lowercased() else { return nil }
        return Self.virtualHostedAWSBucket(inHost: host)
    }

    /// Full endpoint URL, or nil to let the SDK pick AWS's regional endpoint.
    var resolvedEndpoint: String? {
        let custom = customEndpoint.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let withScheme = custom.contains("://") ? custom : "https://" + custom
            return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
        }
        guard let template = preset.endpointTemplate else { return nil }
        let host = template
            .replacingOccurrences(of: "{region}", with: effectiveRegion)
            .replacingOccurrences(of: "{account}", with: accountID.trimmingCharacters(in: .whitespaces))
        return "https://" + host
    }

    /// Endpoint URL passed to Soto's S3 client. Normalizes virtual-hosted native AWS
    /// bucket hosts (such as `my.dotted.bucket.s3.us-east-1.amazonaws.com`) to their
    /// underlying regional/service host so Soto's path-style fallback for dotted bucket
    /// names never includes the bucket in both host and path.
    var sdkEndpoint: String? {
        guard let endpoint = resolvedEndpoint else { return nil }
        guard var components = URLComponents(string: endpoint),
              let host = components.host?.lowercased(),
              let parsed = Self.virtualHostedAWSBucketComponents(inHost: host) else {
            return endpoint
        }
        components.host = parsed.serviceHost
        guard let normalized = components.string else { return endpoint }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    var faviconDomain: String? {
        guard let endpoint = resolvedEndpoint else { return preset.faviconDomain }
        guard let host = URL(string: endpoint)?.host else { return nil }
        return StorageFaviconDomains.domain(forEndpointHost: host)
    }

    var usesVirtualHost: Bool {
        (addressingStyle ?? preset.addressing) == .virtualHost
    }

    /// True when the configured endpoint uses path-style addressing on a non-AWS-S3
    /// host under `amazonaws.com[.cn]` (such as Ceph RGW behind an AWS ALB/NLB or EC2),
    /// where Soto's `S3Middleware` would otherwise rewrite bucket requests into
    /// virtual-hosted `<bucket>.<host>` URLs.
    var needsPathStyleEndpointFixup: Bool {
        guard !usesVirtualHost,
              let endpoint = sdkEndpoint,
              let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return Self.nativeAWSPartition(forHost: host) == nil && Self.awsHostParts(host) != nil
    }

    var isAnonymous: Bool {
        accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Native Amazon S3 service endpoints that support account-level `ListBuckets`
    /// pagination (`max-buckets` and `prefix`, required for accounts with a bucket quota
    /// above 10,000). Excludes Transfer Acceleration (`s3-accelerate`) which does not
    /// serve `ListBuckets`, virtual-hosted bucket URLs, and custom gateways (such as
    /// Ceph RGW behind an AWS load balancer `*.elb.amazonaws.com`).
    var supportsPaginatedBucketListing: Bool {
        guard let endpoint = resolvedEndpoint else { return preset.isAWS }
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return Self.isNativeAWSEndpointHost(host)
    }

    /// True when the configured endpoint uses Amazon S3 Transfer Acceleration, which
    /// only serves bucket-scoped requests and rejects account-level `ListBuckets`.
    var usesTransferAccelerationEndpoint: Bool {
        guard let endpoint = resolvedEndpoint,
              let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return Self.isTransferAccelerationEndpointHost(host)
    }

    static func isTransferAccelerationEndpointHost(_ host: String) -> Bool {
        guard let (labels, _) = awsHostParts(host) else { return false }
        if isTransferAccelerationServiceLabels(labels[...]) { return true }
        for serviceCount in 1...2 where labels.count > serviceCount {
            if isTransferAccelerationServiceLabels(labels.suffix(serviceCount)) { return true }
        }
        return false
    }

    /// Extracts the bucket name and underlying service host from a virtual-hosted native
    /// Amazon S3 hostname (e.g. `my-bucket.s3.us-east-1.amazonaws.com`,
    /// `my.dotted.bucket.s3.us-east-1.amazonaws.com`, `my-bucket.s3-accelerate.amazonaws.com`,
    /// or `my-bucket.bucket.vpce-<id>.s3.us-east-1.vpce.amazonaws.com`).
    /// Returns nil for service endpoints and non-AWS hosts.
    static func virtualHostedAWSBucketComponents(inHost host: String) -> (bucket: String, serviceHost: String)? {
        guard let (labels, suffix) = awsHostParts(host), labels.count >= 2 else { return nil }
        if isNativeS3ServiceLabels(labels[...])
            || isPrivateLinkS3ServiceLabels(labels[...])
            || isTransferAccelerationServiceLabels(labels[...]) {
            return nil
        }
        if labels.count >= 6 {
            let splitIndex = labels.count - 5
            let service = labels[splitIndex...]
            if isPrivateLinkS3ServiceLabels(service) {
                let candidate = labels[..<splitIndex].joined(separator: ".")
                if !candidate.isEmpty {
                    return (candidate, service.joined(separator: ".") + suffix)
                }
            }
        }
        for serviceCount in stride(from: min(3, labels.count - 1), through: 1, by: -1) {
            let splitIndex = labels.count - serviceCount
            let service = labels[splitIndex...]
            if isNativeS3ServiceLabels(service) || isTransferAccelerationServiceLabels(service) {
                let candidate = labels[..<splitIndex].joined(separator: ".")
                if !candidate.isEmpty {
                    return (candidate, service.joined(separator: ".") + suffix)
                }
            }
        }
        return nil
    }

    static func virtualHostedAWSBucket(inHost host: String) -> String? {
        virtualHostedAWSBucketComponents(inHost: host)?.bucket
    }

    static func isNativeAWSEndpointHost(_ host: String) -> Bool {
        guard let (labels, _) = awsHostParts(host) else { return false }
        return isPrivateLinkS3ServiceLabels(labels[...]) || isNativeS3ServiceLabels(labels[...])
    }

    /// AWS partition (`aws`, `aws-cn`, `aws-us-gov`, …) when `host` is a native Amazon S3
    /// service, PrivateLink, Transfer Acceleration, or virtual-hosted bucket hostname.
    /// Returns nil for non-AWS hosts and custom gateways running on AWS (such as Ceph RGW
    /// behind an ALB/NLB, EC2, API Gateway, or custom VPC endpoint service).
    static func nativeAWSPartition(forHost host: String) -> String? {
        guard let (labels, suffix) = awsHostParts(host) else { return nil }
        let serviceLabels: ArraySlice<String>
        if isNativeS3ServiceLabels(labels[...])
            || isPrivateLinkS3ServiceLabels(labels[...])
            || isTransferAccelerationServiceLabels(labels[...]) {
            serviceLabels = labels[...]
        } else if let parsed = virtualHostedAWSBucketComponents(inHost: host),
                  let (normalizedLabels, _) = awsHostParts(parsed.serviceHost) {
            serviceLabels = normalizedLabels[...]
        } else {
            return nil
        }
        if suffix == ".amazonaws.com.cn" { return "aws-cn" }
        if let region = awsRegionLabel(inServiceLabels: serviceLabels) {
            return awsPartition(of: region)
        }
        return "aws"
    }

    private static func isPrivateLinkS3ServiceLabels(_ labels: ArraySlice<String>) -> Bool {
        let base: ArraySlice<String>
        switch labels.count {
        case 4:
            base = labels
        case 5:
            guard labels[labels.startIndex] == "bucket" else { return false }
            base = labels.dropFirst()
        default:
            return false
        }
        let s0 = base[base.startIndex]
        let s1 = base[base.index(after: base.startIndex)]
        let s2 = base[base.index(base.startIndex, offsetBy: 2)]
        let s3 = base[base.index(base.startIndex, offsetBy: 3)]
        return s0.hasPrefix("vpce-") && (s1 == "s3" || s1 == "s3-fips") && isAWSRegionLabel(s2) && s3 == "vpce"
    }

    private static func awsRegionLabel(inServiceLabels labels: ArraySlice<String>) -> String? {
        if isPrivateLinkS3ServiceLabels(labels) {
            let base = labels.count == 5 ? labels.dropFirst() : labels
            return base[base.index(base.startIndex, offsetBy: 2)]
        }
        let first = labels[labels.startIndex]
        switch labels.count {
        case 1:
            if first.hasPrefix("s3-fips-") {
                let candidate = String(first.dropFirst("s3-fips-".count))
                return isAWSRegionLabel(candidate) ? candidate : nil
            }
            if first.hasPrefix("s3-") {
                let candidate = String(first.dropFirst("s3-".count))
                return isAWSRegionLabel(candidate) ? candidate : nil
            }
            return nil
        case 2:
            let second = labels[labels.index(after: labels.startIndex)]
            return isAWSRegionLabel(second) ? second : nil
        case 3:
            let third = labels[labels.index(labels.startIndex, offsetBy: 2)]
            return isAWSRegionLabel(third) ? third : nil
        default:
            return nil
        }
    }

    private static func awsHostParts(_ host: String) -> (labels: [String], suffix: String)? {
        let lower = host.lowercased()
        let normalized = lower.hasSuffix(".") ? String(lower.dropLast()) : lower
        let suffix: String
        let prefix: Substring
        if normalized.hasSuffix(".amazonaws.com") {
            suffix = ".amazonaws.com"
            prefix = normalized.dropLast(suffix.count)
        } else if normalized.hasSuffix(".amazonaws.com.cn") {
            suffix = ".amazonaws.com.cn"
            prefix = normalized.dropLast(suffix.count)
        } else {
            return nil
        }
        let labels = prefix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (labels, suffix)
    }

    private static func isTransferAccelerationServiceLabels(_ labels: ArraySlice<String>) -> Bool {
        let first = labels[labels.startIndex]
        switch labels.count {
        case 1:
            return first == "s3-accelerate"
        case 2:
            let second = labels[labels.index(after: labels.startIndex)]
            return first == "s3-accelerate" && second == "dualstack"
        default:
            return false
        }
    }

    private static func isNativeS3ServiceLabels(_ labels: ArraySlice<String>) -> Bool {
        let first = labels[labels.startIndex]
        switch labels.count {
        case 1:
            if first == "s3" || first == "s3-external-1" { return true }
            if first.hasPrefix("s3-fips-") {
                return isAWSRegionLabel(String(first.dropFirst("s3-fips-".count)))
            }
            if first.hasPrefix("s3-") {
                return isAWSRegionLabel(String(first.dropFirst("s3-".count)))
            }
            return false
        case 2:
            let second = labels[labels.index(after: labels.startIndex)]
            if first == "s3" || first == "s3-fips" {
                return isAWSRegionLabel(second)
            }
            return false
        case 3:
            let second = labels[labels.index(after: labels.startIndex)]
            let third = labels[labels.index(labels.startIndex, offsetBy: 2)]
            if (first == "s3" || first == "s3-fips"), second == "dualstack" {
                return isAWSRegionLabel(third)
            }
            return false
        default:
            return false
        }
    }

    private static func isAWSRegionLabel(_ label: String) -> Bool {
        let parts = label.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4,
              let geo = parts.first, (2...4).contains(geo.count),
              let number = parts.last, (1...2).contains(number.count) else { return false }
        let isLowerLetter: (UnicodeScalar) -> Bool = { $0.value >= 0x61 && $0.value <= 0x7A }
        let isDigit: (UnicodeScalar) -> Bool = { $0.value >= 0x30 && $0.value <= 0x39 }
        guard geo.unicodeScalars.allSatisfy(isLowerLetter),
              number.unicodeScalars.allSatisfy(isDigit) else { return false }
        for middle in parts.dropFirst().dropLast() {
            guard !middle.isEmpty, middle.unicodeScalars.allSatisfy(isLowerLetter) else { return false }
        }
        return true
    }

    /// Why the config can't connect yet, or nil when complete.
    var validationError: String? {
        if preset.requiresCustomEndpoint, customEndpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter the server's endpoint.", comment: "Storage provider validation")
        }
        if let label = preset.accountIDLabel, customEndpoint.isEmpty, accountID.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter the \(label).", comment: "Storage provider validation; argument is a field name such as Account ID")
        }
        if let endpoint = resolvedEndpoint, URL(string: endpoint)?.host == nil {
            return String(localized: "The endpoint isn't a valid address.", comment: "Storage provider validation")
        }
        if let hostBucket = endpointBucket {
            let explicit = bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !explicit.isEmpty, explicit != hostBucket {
                return String(
                    localized: "The bucket name must match the endpoint host (“\(hostBucket)”).",
                    comment: "Storage provider validation; argument is the bucket name in a virtual-hosted AWS endpoint"
                )
            }
        }
        if usesTransferAccelerationEndpoint, effectiveBucket == nil {
            return String(localized: "Enter a bucket name for S3 Transfer Acceleration endpoints.", comment: "Storage provider validation: Transfer Acceleration does not support ListBuckets")
        }
        if !isAnonymous, secretAccessKey.isEmpty {
            return String(localized: "Enter the secret access key.", comment: "Storage provider validation")
        }
        return nil
    }

    /// True when both providers are proven to resolve unqualified `/bucket/key` paths
    /// into the same bucket namespace (so source-only rename shortcuts and same-path
    /// move skips are safe). Native AWS S3 bucket names are globally unique per partition;
    /// S3-compatible gateways such as Ceph RGW can scope unqualified buckets per user
    /// tenant, so matching credentials are required to prove a shared namespace.
    func reachesSameNamespace(as other: StorageProvider) -> Bool {
        let identity = endpointIdentity
        guard identity == other.endpointIdentity else { return false }
        if identity.hasPrefix("aws:") { return true }
        return hasSameCredentials(as: other)
    }

    /// True when both providers reach the same server and might therefore alias the same
    /// objects (for instance two different-key profiles on the same Ceph RGW gateway whose
    /// tenant relationship is unknown). Overlap guards use this even when `reachesSameNamespace`
    /// is false.
    func mayShareNamespace(with other: StorageProvider) -> Bool {
        endpointIdentity == other.endpointIdentity
    }

    /// True when both providers authenticate as the same principal (trimmed to match signing).
    func hasSameCredentials(as other: StorageProvider) -> Bool {
        accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
            == other.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
            && sessionToken == other.sessionToken
    }

    /// The server as scheme, host, port and path, so two servers sharing a host
    /// name stay distinct. Native AWS S3 endpoints (default, regional, dualstack,
    /// FIPS, PrivateLink, Transfer Acceleration, and virtual-hosted bucket hosts)
    /// share one namespace per AWS partition.
    var endpointIdentity: String {
        guard let endpoint = resolvedEndpoint, let url = URL(string: endpoint), let host = url.host?.lowercased() else {
            return "aws:" + Self.awsPartition(of: effectiveRegion)
        }
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        let isStandardPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        if isStandardPort, path.isEmpty, let partition = Self.nativeAWSPartition(forHost: host) {
            return "aws:" + partition
        }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    private static func awsPartition(of region: String) -> String {
        if region.hasPrefix("cn-") { return "aws-cn" }
        if region.hasPrefix("us-gov-") { return "aws-us-gov" }
        if region.hasPrefix("us-isob-") { return "aws-iso-b" }
        if region.hasPrefix("us-iso-") { return "aws-iso" }
        return "aws"
    }
}
