//
//  S3Connection.swift
//  rootshell
//
//  A storage provider's live S3 client. There is no session to hold open;
//  the connection owns the AWSClient (which must be shut down) and routes
//  each bucket to a client for the region it lives in.
//

import Foundation
import NIOCore
import NIOHTTP1
import SotoS3
import Synchronization

nonisolated final class S3Connection: FileConnection {
    let session: S3Session
    private let isClosed = Mutex(false)

    init(provider: StorageProvider) throws {
        if let problem = provider.validationError { throw StorageError.misconfigured(problem) }
        session = S3Session(provider: provider)
    }

    var isActive: Bool { !isClosed.withLock { $0 } }

    var browseFileSystem: FileSystemEndpoint {
        FileSystemEndpoint(backend: .s3(S3FileSystem(session: session)))
    }

    /// Requests are independent HTTP calls, so listings never block transfers.
    func transferFileSystem() async -> FileSystemEndpoint {
        browseFileSystem
    }

    func close() async {
        let wasClosed = isClosed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        await session.shutdown()
    }
}

/// Jittered retries, except for 501: servers without tagging or ACLs answer it
/// permanently, and backing off four times stalls every rewrite for seconds.
nonisolated struct S3RetryPolicy: RetryPolicy {
    private let standard = RetryPolicyFactory.jitter().retryPolicy

    func getRetryWaitTime(error: Error, attempt: Int) -> RetryStatus? {
        if (error as? AWSErrorType)?.context?.responseCode == .notImplemented { return .dontRetry }
        return standard.getRetryWaitTime(error: error, attempt: attempt)
    }
}

/// Reverts Soto `S3Middleware`'s virtual-host rewrite for path-style custom gateways
/// hosted under `*.amazonaws.com[.cn]` (such as Ceph RGW behind an AWS ALB/NLB).
/// Installed via `S3.with(middleware:)`, so it runs after `S3Middleware` and before
/// `SigningMiddleware`.
nonisolated struct S3PathStyleFixupMiddleware: AWSMiddlewareProtocol {
    let endpointHost: String

    func handle(
        _ request: AWSHTTPRequest,
        context: AWSMiddlewareContext,
        next: AWSMiddlewareNextHandler
    ) async throws -> AWSHTTPResponse {
        var request = request
        if let fixed = S3KeyLogic.restorePathStyleURL(request.url, endpointHost: endpointHost) {
            request.url = fixed
        }
        return try await next(request, context)
    }
}

/// The AWSClient plus one S3 service per region. AWS rejects requests sent to
/// the wrong region, so each bucket's region is looked up once and cached;
/// every other provider has a single endpoint.
actor S3Session {
    nonisolated let provider: StorageProvider
    nonisolated let client: AWSClient
    nonisolated let defaultService: S3
    private var servicesByBucket: [String: S3] = [:]
    private var servicesByRegion: [String: S3] = [:]
    /// Learned on the first edit save, so later saves send the spelling that works.
    private(set) var conditionalPut = S3KeyLogic.ConditionalPut.quoted

    func noteConditionalPut(_ style: S3KeyLogic.ConditionalPut) {
        conditionalPut = style
    }

    init(provider: StorageProvider) {
        self.provider = provider
        let credentials: CredentialProviderFactory = provider.isAnonymous
            ? .empty
            : .static(
                // Pasted keys often carry stray whitespace, which only shows up as a signature mismatch.
                accessKeyId: provider.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccessKey: provider.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                sessionToken: provider.sessionToken.isEmpty ? nil : provider.sessionToken
            )
        client = AWSClient(credentialProvider: credentials, retryPolicy: .init(retryPolicy: S3RetryPolicy()))
        defaultService = Self.makeService(client: client, provider: provider, region: provider.effectiveRegion)
    }

    func shutdown() async {
        try? await client.shutdown()
    }

    func service(for bucket: String) async -> S3 {
        guard provider.preset.isAWS, provider.resolvedEndpoint == nil else { return defaultService }
        if let known = servicesByBucket[bucket] { return known }
        let region = await lookUpRegion(of: bucket) ?? provider.effectiveRegion
        let service = service(inRegion: region)
        servicesByBucket[bucket] = service
        return service
    }

    /// Seeds the cache from a bucket listing, which reports regions for free.
    func noteRegion(_ region: String, for bucket: String) {
        guard provider.preset.isAWS, provider.resolvedEndpoint == nil, servicesByBucket[bucket] == nil else { return }
        servicesByBucket[bucket] = service(inRegion: region)
    }

    /// A deleted bucket's name can be taken again in another region.
    func forget(_ bucket: String) {
        servicesByBucket[bucket] = nil
    }

    private func service(inRegion region: String) -> S3 {
        if region == provider.effectiveRegion { return defaultService }
        if let known = servicesByRegion[region] { return known }
        let service = Self.makeService(client: client, provider: provider, region: region)
        servicesByRegion[region] = service
        return service
    }

    /// HeadBucket answers with the bucket's region, even when refusing the
    /// request because it went to the wrong one.
    private func lookUpRegion(of bucket: String) async -> String? {
        do {
            return try await defaultService.headBucket(.init(bucket: bucket)).bucketRegion
        } catch let error as AWSErrorType {
            return error.context?.headers["x-amz-bucket-region"].first
        } catch {
            return nil
        }
    }

    private static func makeService(client: AWSClient, provider: StorageProvider, region: String) -> S3 {
        var options: AWSServiceConfig.Options = []
        let endpoint = provider.sdkEndpoint
        if endpoint != nil, provider.usesVirtualHost { options.insert(.s3ForceVirtualHost) }
        // Several S3-compatible servers mishandle Expect: 100-continue.
        if !provider.preset.isAWS { options.insert(.s3Disable100Continue) }
        // AWS signs with the bucket's own region; other endpoints may expect a fixed one.
        let signingRegion = endpoint == nil ? region : provider.effectiveSigningRegion
        let service = S3(
            client: client,
            region: SotoCore.Region(rawValue: signingRegion),
            endpoint: endpoint,
            // Whole-request deadline: large parts on slow links need minutes.
            timeout: .seconds(600),
            options: options
        )
        if provider.needsPathStyleEndpointFixup,
           let endpoint,
           let host = URL(string: endpoint)?.host?.lowercased() {
            return service.with(middleware: S3PathStyleFixupMiddleware(endpointHost: host))
        }
        return service
    }
}
