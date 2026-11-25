//
//  S3FileSystem.swift
//  rootshell
//
//  Filesystem semantics over an S3 bucket namespace. Paths are `/bucket/key`,
//  or `/key` when the provider is limited to one bucket. Folders are key
//  prefixes, listed with a "/" delimiter; an empty folder is kept as a
//  zero-byte "prefix/" marker object.
//

import Foundation
import NIOHTTP1
import SotoS3
import UniformTypeIdentifiers

nonisolated struct S3FileSystem: Sendable {
    let session: S3Session

    var provider: StorageProvider { session.provider }

    /// A bucket and the key within it; an empty key is the bucket itself.
    struct Location: Sendable {
        let bucket: String
        let key: String
    }

    /// Paths are always `/bucket/key`, even for a provider limited to one bucket,
    /// so one object has one path on every provider that reaches it. nil is the root.
    func location(of path: String) -> Location? {
        let components = FileTransferLogic.normalize(path).split(separator: "/").map(String.init)
        guard let bucket = components.first else { return nil }
        return Location(bucket: bucket, key: components.dropFirst().joined(separator: "/"))
    }

    /// A bucket-limited provider starts inside its bucket; `initialPath` is relative to it.
    var homeDirectory: String {
        let start = provider.effectiveBucket.map { $0 + "/" + provider.initialPath } ?? provider.initialPath
        return FileTransferLogic.normalize(start)
    }

    // MARK: - Listing and metadata

    /// With `strict`, objects whose names a path can't hold fail the listing
    /// instead of being hidden, so a transfer never silently leaves them behind.
    func list(_ path: String, strict: Bool = false) async throws -> [RFEntry] {
        let base = FileTransferLogic.normalize(path)
        guard let location = location(of: base) else {
            // Keys limited to one bucket often can't list buckets at all.
            if let bucket = provider.effectiveBucket { return [Self.entry(bucket, in: "/", isDirectory: true)] }
            return try await listBuckets()
        }
        let service = await session.service(for: location.bucket)
        let prefix = location.key.isEmpty ? "" : location.key + "/"
        var entries: [RFEntry] = []
        var token: String?
        repeat {
            let page = try await mapped(path) {
                try await service.listObjectsV2(.init(
                    bucket: location.bucket, continuationToken: token, delimiter: "/", prefix: prefix.isEmpty ? nil : prefix
                ))
            }
            for common in page.commonPrefixes ?? [] {
                guard let name = try Self.listedName(common.prefix, under: prefix, in: base, strict: strict) else { continue }
                entries.append(Self.entry(name, in: base, isDirectory: true))
            }
            for object in page.contents ?? [] {
                guard let name = try Self.listedName(object.key, under: prefix, in: base, strict: strict) else { continue }
                entries.append(Self.entry(name, in: base, isDirectory: false, size: object.size ?? 0, modified: object.lastModified))
            }
            token = page.isTruncated == true ? page.nextContinuationToken : nil
        } while token != nil
        return entries
    }

    private func listBuckets() async throws -> [RFEntry] {
        var entries: [RFEntry] = []
        var token: String?
        repeat {
            let page = try await mapped("/") { try await session.defaultService.listBuckets(.init(continuationToken: token)) }
            for bucket in page.buckets ?? [] {
                guard let name = bucket.name else { continue }
                if let region = bucket.bucketRegion { await session.noteRegion(region, for: name) }
                entries.append(Self.entry(name, in: "/", isDirectory: true, modified: bucket.creationDate))
            }
            token = page.continuationToken
        } while token != nil
        return entries
    }

    /// A key names a file; a key with objects beneath it names a folder.
    func info(_ path: String) async throws -> FileSystemEndpoint.ItemInfo {
        guard let location = location(of: path) else { return Self.directoryInfo }
        let service = await session.service(for: location.bucket)
        if location.key.isEmpty {
            // Scoped keys may not allow HeadBucket; only a definite 404 means missing.
            do {
                _ = try await service.headBucket(.init(bucket: location.bucket))
            } catch where StorageError.isNotFound(error) {
                throw StorageError.notFound(path)
            } catch {}
            return Self.directoryInfo
        }
        do {
            let head = try await service.headObject(.init(bucket: location.bucket, key: location.key))
            return FileSystemEndpoint.ItemInfo(
                isDirectory: false, isSymlink: false, size: UInt64(max(0, head.contentLength ?? 0)),
                permissions: nil, modified: head.lastModified
            )
        } catch where StorageError.isNotFound(error) {
            let page = try await mapped(path) {
                try await service.listObjectsV2(.init(bucket: location.bucket, maxKeys: 1, prefix: location.key + "/"))
            }
            guard page.contents?.isEmpty == false || page.commonPrefixes?.isEmpty == false else {
                throw StorageError.notFound(path)
            }
            return Self.directoryInfo
        } catch {
            throw StorageError.from(error, path: path)
        }
    }

    // MARK: - Mutation

    func makeDirectory(_ path: String) async throws {
        let (service, location) = try await object(path)
        _ = try await mapped(path) {
            try await service.putObject(.init(body: .init(bytes: Data()), bucket: location.bucket, contentLength: 0, key: location.key + "/"))
        }
    }

    func removeFile(_ path: String) async throws {
        let (service, location) = try await object(path)
        _ = try await mapped(path) { try await service.deleteObject(.init(bucket: location.bucket, key: location.key)) }
    }

    /// Removes a folder's marker; its contents are separate objects. A bucket is deleted only when empty.
    func removeDirectory(_ path: String) async throws {
        if let bucket = bucketName(of: path) { return try await deleteBucket(bucket, path: path) }
        let (service, location) = try await object(path)
        _ = try await mapped(path) { try await service.deleteObject(.init(bucket: location.bucket, key: location.key + "/")) }
    }

    /// Deletes a file, or every object under a folder in batches. Never empties a bucket.
    func removeRecursively(_ path: String) async throws {
        if let bucket = bucketName(of: path) { return try await deleteBucket(bucket, path: path) }
        let (service, location) = try await object(path)
        guard try await info(path).isDirectory else {
            return try await removeFile(path)
        }
        let keys = try await objects(under: location, service: service).map(\.key)
        try await delete(keys, in: location.bucket, service: service, path: path)
    }

    /// Server-side copy then delete; a folder moves object by object, and its
    /// originals are only deleted once every copy succeeded.
    func rename(_ from: String, to: String) async throws {
        let (_, source) = try await object(from)
        let (_, target) = try await object(to)
        let item = try await info(from)
        guard item.isDirectory else {
            try await copyObject(source, to: target, size: Int64(item.size), path: from)
            return try await removeFile(from)
        }
        guard !FileTransferLogic.isSameOrDescendant(FileTransferLogic.normalize(to), of: FileTransferLogic.normalize(from)) else {
            throw StorageError.unsupported(String(localized: "A folder can't be moved into itself.", comment: "Storage error"))
        }
        let service = await session.service(for: source.bucket)
        let contents = try await objects(under: source, service: service)
        let prefix = source.key + "/"
        for object in contents {
            try Task.checkCancellation()
            let relative = String(object.key.dropFirst(prefix.count))
            let destination = Location(bucket: target.bucket, key: target.key + "/" + relative)
            try await copyObject(Location(bucket: source.bucket, key: object.key), to: destination, size: object.size, path: from)
        }
        try await delete(contents.map(\.key), in: source.bucket, service: service, path: from)
    }

    // MARK: - Streams

    func openReader(_ path: String) async throws -> any ChunkReader {
        let (service, location) = try await object(path)
        let head = try await mapped(path) { try await service.headObject(.init(bucket: location.bucket, key: location.key)) }
        return S3ObjectReader(
            service: service, bucket: location.bucket, key: location.key,
            size: UInt64(max(0, head.contentLength ?? 0)), eTag: head.eTag
        )
    }

    func openWriter(_ path: String) async throws -> any ChunkWriter {
        let (service, location) = try await object(path)
        return S3ObjectWriter(service: service, bucket: location.bucket, key: location.key)
    }

    /// Reads an S3 object's bytes pinned to a single verified ETag so subsequent
    /// saves compare against the exact revision that supplied the edited contents.
    func readObjectForEdit(_ path: String, maxBytes: Int64) async throws -> (data: Data, fingerprint: RemoteFileFingerprint) {
        let (service, location) = try await object(path)
        let head: S3.HeadObjectOutput
        do {
            head = try await service.headObject(.init(bucket: location.bucket, key: location.key))
        } catch where StorageError.isNotFound(error) {
            let page = try? await service.listObjectsV2(.init(bucket: location.bucket, maxKeys: 1, prefix: location.key + "/"))
            if page?.contents?.isEmpty == false || page?.commonPrefixes?.isEmpty == false {
                throw RemoteEditError.isDirectory
            }
            throw StorageError.notFound(path)
        } catch {
            throw StorageError.from(error, path: path)
        }

        let size = UInt64(max(0, head.contentLength ?? 0))
        guard Int64(clamping: size) <= maxBytes else {
            throw RemoteEditError.tooLarge(limitBytes: maxBytes)
        }
        try StorageError.requireETag(head.eTag)
        let rawETag = head.eTag!
        let normalizedETag = rawETag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        let reader = S3ObjectReader(
            service: service,
            bucket: location.bucket,
            key: location.key,
            size: size,
            eTag: rawETag
        )
        var data = Data()
        if size > 0 && size <= UInt64(maxBytes) {
            data.reserveCapacity(Int(size))
        }
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 262_144
        do {
            while offset < size {
                try Task.checkCancellation()
                let chunk = try await reader.read(at: offset, length: chunkSize)
                if chunk.isEmpty { break }
                if Int64(data.count) + Int64(chunk.count) > maxBytes {
                    throw RemoteEditError.tooLarge(limitBytes: maxBytes)
                }
                data.append(chunk)
                offset += UInt64(chunk.count)
            }
            try? await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }

        let fingerprint = RemoteFileFingerprint(
            size: UInt64(data.count),
            modified: head.lastModified,
            eTag: normalizedETag
        )
        return (data, fingerprint)
    }

    /// Replaces an edited object's bytes while preserving its existing HTTP headers,
    /// custom metadata, storage class, encryption, tags, and ACL grants. Uses `If-Match`
    /// on the write itself so a concurrent update during upload raises a conflict, and
    /// derives the returned revision directly from the PUT response's ETag.
    func replaceObjectContents(
        _ path: String,
        data: Data,
        expectedETag: String?,
        forceOverwrite: Bool
    ) async throws -> RemoteFileFingerprint {
        let (service, location) = try await object(path)

        if !forceOverwrite && expectedETag == nil {
            throw RemoteEditError.remoteModified(nil)
        }

        let existingHead: S3.HeadObjectOutput?
        do {
            existingHead = try await service.headObject(.init(bucket: location.bucket, key: location.key))
        } catch where StorageError.isNotFound(error) {
            if !forceOverwrite {
                throw RemoteEditError.remoteDeleted
            }
            existingHead = nil
        } catch {
            throw StorageError.from(error, path: path)
        }

        if let head = existingHead {
            let currentNormalizedETag = head.eTag.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            let currentFingerprint = RemoteFileFingerprint(
                size: UInt64(max(0, head.contentLength ?? 0)),
                modified: head.lastModified,
                eTag: currentNormalizedETag
            )
            if !forceOverwrite {
                guard let expectedETag, let currentNormalizedETag, currentNormalizedETag == expectedETag else {
                    throw RemoteEditError.remoteModified(currentFingerprint)
                }
            }

            let fields = S3ObjectHeaders(head)
            let versionID = head.versionId == "null" ? nil : head.versionId
            let storageClass = head.storageClass != .standard ? head.storageClass : nil
            async let tagsLookup = tagging(of: location, versionID: versionID, service: service, path: path)
            async let grantsLookup = grantHeaders(of: location, versionID: versionID, service: service, path: path)
            let (tags, grants) = try await (tagsLookup, grantsLookup)

            let put = { (ifMatch: String?) async throws -> S3.PutObjectOutput in
                try await service.putObject(.init(
                    body: .init(bytes: data),
                    bucket: location.bucket,
                    bucketKeyEnabled: head.bucketKeyEnabled,
                    cacheControl: fields.cacheControl.nonEmpty,
                    contentDisposition: fields.contentDisposition.nonEmpty,
                    contentEncoding: fields.contentEncoding.nonEmpty,
                    contentLanguage: fields.contentLanguage.nonEmpty,
                    contentLength: Int64(data.count),
                    contentType: fields.contentType.nonEmpty,
                    expires: head.expires,
                    grantFullControl: grants?["FULL_CONTROL"],
                    grantRead: grants?["READ"],
                    grantReadACP: grants?["READ_ACP"],
                    grantWriteACP: grants?["WRITE_ACP"],
                    ifMatch: ifMatch,
                    key: location.key,
                    metadata: fields.metadata.isEmpty ? nil : fields.metadata,
                    serverSideEncryption: head.serverSideEncryption,
                    ssekmsKeyId: head.ssekmsKeyId,
                    storageClass: storageClass,
                    tagging: tags,
                    websiteRedirectLocation: head.websiteRedirectLocation
                ))
            }
            let output: S3.PutObjectOutput
            if !forceOverwrite, let expectedETag {
                output = try await putIfUnchanged(eTag: expectedETag, location: location, service: service, path: path, put: put)
            } else {
                output = try await mapped(path) { try await put(nil) }
            }
            try StorageError.requireETag(output.eTag)
            // Use the ETag returned directly by our PUT rather than issuing a fresh HEAD,
            // which could observe a concurrent writer's ETag and mask their edit.
            let normalized = output.eTag!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return RemoteFileFingerprint(size: UInt64(data.count), modified: Date(), eTag: normalized)
        } else {
            // Recreating an object after the user explicitly confirmed overwriting a deleted file.
            let ext = (location.key as NSString).pathExtension
            let contentType = ext.isEmpty ? "text/plain; charset=utf-8" : UTType(filenameExtension: ext)?.preferredMIMEType
            let output = try await mapped(path) {
                try await service.putObject(.init(
                    body: .init(bytes: data),
                    bucket: location.bucket,
                    contentLength: Int64(data.count),
                    contentType: contentType,
                    key: location.key
                ))
            }
            try StorageError.requireETag(output.eTag)
            let normalized = output.eTag!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return RemoteFileFingerprint(size: UInt64(data.count), modified: Date(), eTag: normalized)
        }
    }

    /// A PutObject guarded by `If-Match`. A 412 while the object still carries
    /// `eTag` means the server misreads that spelling of the header, not that the
    /// object changed, so the next spelling is tried and remembered for the session.
    private func putIfUnchanged(
        eTag: String,
        location: Location,
        service: S3,
        path: String,
        put: (_ ifMatch: String?) async throws -> S3.PutObjectOutput
    ) async throws -> S3.PutObjectOutput {
        let known = await session.conditionalPut
        var style = known
        while true {
            do {
                let output = try await put(style.ifMatch(eTag))
                if style != known { await session.noteConditionalPut(style) }
                return output
            } catch let error as AWSErrorType where error.context?.responseCode == .preconditionFailed {
                let head: S3.HeadObjectOutput
                do {
                    head = try await service.headObject(.init(bucket: location.bucket, key: location.key))
                } catch where StorageError.isNotFound(error) {
                    throw RemoteEditError.remoteDeleted
                } catch {
                    throw StorageError.from(error, path: path)
                }
                let current = head.eTag.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                guard current == eTag, let next = style.fallback else {
                    throw RemoteEditError.remoteModified(RemoteFileFingerprint(
                        size: UInt64(max(0, head.contentLength ?? 0)),
                        modified: head.lastModified,
                        eTag: current
                    ))
                }
                style = next
            } catch {
                throw StorageError.from(error, path: path)
            }
        }
    }

    // MARK: - Server-side copy

    /// Same endpoint and keys: the server can copy without the data passing through the device.
    func canCopyOnServer(from other: S3FileSystem) -> Bool {
        provider.endpointIdentity == other.provider.endpointIdentity
            && provider.accessKeyID == other.provider.accessKeyID
            && provider.sessionToken == other.provider.sessionToken
    }

    func copyOnServer(_ sourcePath: String, from source: S3FileSystem, to path: String) async throws {
        let (_, from) = try await source.object(sourcePath)
        let (_, to) = try await object(path)
        let size = try await source.info(sourcePath).size
        try await copyObject(from, to: to, size: Int64(size), path: sourcePath)
    }

    /// CopyObject handles up to 5 GB and keeps headers, metadata and tags; larger
    /// objects copy in 1 GB ranges into an upload that starts blank, so those are
    /// set explicitly. `headers` replaces the source's (an in-place edit), which
    /// also keeps its storage class, encryption and ACL, and fails unless the
    /// object is still `base`. `size` only picks the path for plain copies;
    /// every other path re-reads it and copies only that exact version.
    func copyObject(
        _ source: Location, to target: Location, size: Int64, path: String,
        headers: S3ObjectHeaders? = nil, base: S3ObjectDetails? = nil
    ) async throws {
        let service = await session.service(for: target.bucket)
        let copySource = S3KeyLogic.copySource(bucket: source.bucket, key: source.key)
        let inPlace = headers != nil
        guard size > 5 << 30 || inPlace else {
            let output = try await mapped(path) { try await service.copyObject(.init(bucket: target.bucket, copySource: copySource, key: target.key)) }
            try StorageError.requireETag(output.copyObjectResult.eTag)
            return
        }
        let sourceService = await session.service(for: source.bucket)
        let head = try await mapped(path) { try await sourceService.headObject(.init(bucket: source.bucket, key: source.key)) }
        guard let eTag = head.eTag, let currentSize = head.contentLength else {
            throw StorageError.service(String(localized: "The server didn't describe “\(path)”.", comment: "Storage error; argument is a path"))
        }
        if let base, !base.isSameVersion(as: head) {
            throw StorageError.changed(path)
        }
        // Pinning a versioned object's source also pins its metadata, which the ETag doesn't cover.
        let versionID = head.versionId == "null" ? nil : head.versionId
        let pinnedSource = S3KeyLogic.copySource(bucket: source.bucket, key: source.key, versionID: versionID)
        // In place, the write itself is conditional too, so a newer upload is never overwritten.
        let targetETag = inPlace ? eTag : nil
        let isMultipart = currentSize > 5 << 30
        guard isMultipart || inPlace else {
            let output = try await mapped(path) {
                try await service.copyObject(.init(bucket: target.bucket, copySource: pinnedSource, copySourceIfMatch: eTag, key: target.key))
            }
            try StorageError.requireETag(output.copyObjectResult.eTag)
            return
        }
        let fields = headers ?? S3ObjectHeaders(head)
        let storageClass = inPlace && head.storageClass != .standard ? head.storageClass : nil
        let encryption = inPlace ? head.serverSideEncryption : nil
        let kmsKeyID = inPlace ? head.ssekmsKeyId : nil
        let bucketKey = inPlace ? head.bucketKeyEnabled : nil
        // A self-copy gets a private ACL unless the grants are restated.
        var grants: [String: String]?
        if inPlace { grants = try await grantHeaders(of: source, versionID: versionID, service: sourceService, path: path) }
        guard isMultipart else {
            // REPLACE drops storage class and encryption unless restated; tags are kept.
            let output = try await mapped(path) {
                try await service.copyObject(.init(
                    bucket: target.bucket, bucketKeyEnabled: bucketKey, cacheControl: fields.cacheControl.nonEmpty,
                    contentDisposition: fields.contentDisposition.nonEmpty, contentEncoding: fields.contentEncoding.nonEmpty,
                    contentLanguage: fields.contentLanguage.nonEmpty, contentType: fields.contentType.nonEmpty,
                    copySource: pinnedSource, copySourceIfMatch: eTag, expires: head.expires,
                    grantFullControl: grants?["FULL_CONTROL"], grantRead: grants?["READ"],
                    grantReadACP: grants?["READ_ACP"], grantWriteACP: grants?["WRITE_ACP"],
                    ifMatch: targetETag, key: target.key, metadata: fields.metadata,
                    metadataDirective: .replace, serverSideEncryption: encryption, ssekmsKeyId: kmsKeyID,
                    storageClass: storageClass, websiteRedirectLocation: head.websiteRedirectLocation
                ))
            }
            try StorageError.requireETag(output.copyObjectResult.eTag)
            return
        }
        let tags = try await tagging(of: source, versionID: versionID, service: sourceService, path: path)
        let upload = try await mapped(path) {
            try await service.createMultipartUpload(.init(
                bucket: target.bucket, bucketKeyEnabled: bucketKey, cacheControl: fields.cacheControl.nonEmpty,
                contentDisposition: fields.contentDisposition.nonEmpty, contentEncoding: fields.contentEncoding.nonEmpty,
                contentLanguage: fields.contentLanguage.nonEmpty, contentType: fields.contentType.nonEmpty,
                expires: head.expires, grantFullControl: grants?["FULL_CONTROL"], grantRead: grants?["READ"],
                grantReadACP: grants?["READ_ACP"], grantWriteACP: grants?["WRITE_ACP"],
                key: target.key, metadata: fields.metadata.isEmpty ? nil : fields.metadata,
                serverSideEncryption: encryption, ssekmsKeyId: kmsKeyID, storageClass: storageClass,
                tagging: tags, websiteRedirectLocation: head.websiteRedirectLocation
            ))
        }
        guard let uploadID = upload.uploadId else {
            throw StorageError.service(String(localized: "The server didn't start the upload.", comment: "Storage upload error"))
        }
        do {
            let partSize: Int64 = 1 << 30
            var parts: [S3.CompletedPart] = []
            for (index, start) in stride(from: Int64(0), to: currentSize, by: Int(partSize)).enumerated() {
                try Task.checkCancellation()
                let end = min(start + partSize, currentSize) - 1
                let output = try await service.uploadPartCopy(.init(
                    bucket: target.bucket, copySource: pinnedSource, copySourceIfMatch: eTag, copySourceRange: "bytes=\(start)-\(end)",
                    key: target.key, partNumber: index + 1, uploadId: uploadID
                ))
                try StorageError.requireETag(output.copyPartResult.eTag)
                parts.append(S3.CompletedPart(eTag: output.copyPartResult.eTag, partNumber: index + 1))
            }
            // Copying parts takes minutes; If-Match below can't see a metadata-only change made meanwhile.
            if inPlace {
                let current = try await service.headObject(.init(bucket: target.bucket, key: target.key))
                guard S3ObjectDetails(head).isSameVersion(as: current) else { throw StorageError.changed(path) }
            }
            let output = try await service.completeMultipartUpload(.init(
                bucket: target.bucket, ifMatch: targetETag, key: target.key, multipartUpload: .init(parts: parts), uploadId: uploadID
            ))
            try StorageError.requireETag(output.eTag)
        } catch {
            // Unstructured so a cancelled job still cleans up.
            await Task {
                _ = try? await service.abortMultipartUpload(.init(bucket: target.bucket, key: target.key, uploadId: uploadID))
            }.value
            throw StorageError.from(error, path: path)
        }
    }

    // MARK: - Helpers

    private static let directoryInfo = FileSystemEndpoint.ItemInfo(
        isDirectory: true, isSymlink: false, size: 0, permissions: nil, modified: nil
    )

    /// The service and location for an object; bucket roots aren't objects.
    func object(_ path: String) async throws -> (S3, Location) {
        guard let location = location(of: path), !location.key.isEmpty else {
            throw StorageError.unsupported(String(localized: "Files and folders go inside a bucket, and buckets can't be renamed.", comment: "Storage error"))
        }
        return (await session.service(for: location.bucket), location)
    }

    /// The bucket `path` names when it is a bucket root.
    func bucketName(of path: String) -> String? {
        guard let location = location(of: path), location.key.isEmpty else { return nil }
        return location.bucket
    }

    /// The source's tags in x-amz-tagging form, nil when it has none. HEAD's tag
    /// count needs its own permission, so it's never trusted to mean "no tags";
    /// only a provider without tagging at all is.
    private func tagging(of source: Location, versionID: String?, service: S3, path: String) async throws -> String? {
        do {
            let output = try await service.getObjectTagging(.init(bucket: source.bucket, key: source.key, versionId: versionID))
            return output.tagSet.isEmpty ? nil : S3KeyLogic.tagging(output.tagSet.map { (key: $0.key, value: $0.value) })
        } catch where StorageError.isUnsupported(error) {
            return nil
        } catch {
            throw StorageError.unreadable(path, String(localized: "tags", comment: "Storage error fragment: what couldn't be read"), error)
        }
    }

    /// The source's ACL as x-amz-grant-* values, nil when a copy's default
    /// (owner full control) already matches or the provider has no ACLs.
    private func grantHeaders(of source: Location, versionID: String?, service: S3, path: String) async throws -> [String: String]? {
        let acl: S3.GetObjectAclOutput
        do {
            acl = try await service.getObjectAcl(.init(bucket: source.bucket, key: source.key, versionId: versionID))
        } catch where StorageError.isUnsupported(error) {
            return nil
        } catch {
            throw StorageError.unreadable(path, String(localized: "permissions", comment: "Storage error fragment: what couldn't be read"), error)
        }
        let grants = (acl.grants ?? []).compactMap { grant -> S3KeyLogic.Grant? in
            guard let permission = grant.permission?.rawValue, let grantee = grant.grantee else { return nil }
            if let id = grantee.id { return .init(grantee: .id(id), permission: permission) }
            if let uri = grantee.uri { return .init(grantee: .uri(uri), permission: permission) }
            if let email = grantee.emailAddress { return .init(grantee: .email(email), permission: permission) }
            return nil
        }
        return S3KeyLogic.grantHeaders(grants, ownerID: acl.owner?.id)
    }

    /// Every object whose key starts with the folder's prefix, marker included.
    private func objects(under folder: Location, service: S3) async throws -> [(key: String, size: Int64)] {
        var result: [(key: String, size: Int64)] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await mapped(folder.key) {
                try await service.listObjectsV2(.init(bucket: folder.bucket, continuationToken: token, prefix: folder.key + "/"))
            }
            result += (page.contents ?? []).compactMap { object in object.key.map { ($0, object.size ?? 0) } }
            token = page.isTruncated == true ? page.nextContinuationToken : nil
        } while token != nil
        return result
    }

    private func delete(_ keys: [String], in bucket: String, service: S3, path: String) async throws {
        var remaining = keys[...]
        if provider.preset.supportsBatchDelete {
            while !remaining.isEmpty {
                try Task.checkCancellation()
                let batch = remaining.prefix(1000)
                do {
                    let output = try await service.deleteObjects(.init(
                        bucket: bucket, delete: .init(objects: batch.map { S3.ObjectIdentifier(key: $0) }, quiet: true)
                    ))
                    if let failure = output.errors?.first {
                        throw StorageError.service(failure.message ?? failure.code ?? failure.key ?? path)
                    }
                    remaining = remaining.dropFirst(batch.count)
                } catch let error as AWSErrorType where error.context?.responseCode == .notImplemented {
                    break
                } catch {
                    throw StorageError.from(error, path: path)
                }
            }
        }
        for key in remaining {
            try Task.checkCancellation()
            _ = try await mapped(path) { try await service.deleteObject(.init(bucket: bucket, key: key)) }
        }
    }

    func mapped<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw StorageError.from(error, path: path)
        }
    }

    private static func listedName(_ key: String?, under prefix: String, in directory: String, strict: Bool) throws -> String? {
        switch key.map({ S3KeyLogic.classify($0, under: prefix) }) ?? .ignored {
        case .child(let name):
            return name
        case .ignored:
            return nil
        case .unrepresentable:
            guard strict else { return nil }
            throw StorageError.unsupported(String(
                localized: "“\(directory)” contains objects named “.” or “..” or with empty folder names, which can't be copied or moved.",
                comment: "Storage error; argument is a folder path"
            ))
        }
    }

    private static func entry(_ name: String, in directory: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) -> RFEntry {
        RFEntry(
            name: name, path: FileTransferLogic.join(directory, name), isDirectory: isDirectory, isSymlink: false,
            isHidden: name.hasPrefix("."), isExecutable: false, size: size, modifiedDate: modified, gitStatus: nil
        )
    }
}

nonisolated enum StorageError: LocalizedError {
    case notFound(String)
    case unsupported(String)
    case misconfigured(String)
    case service(String)
    case incompleteUpload
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            String(localized: "“\(path)” doesn't exist.", comment: "Storage error; argument is a path")
        case .changed(let path):
            String(localized: "“\(path)” changed on the server during this operation, so it was stopped. Try again.", comment: "Storage error; argument is a path")
        case .unsupported(let message), .misconfigured(let message), .service(let message):
            message
        case .incompleteUpload:
            String(localized: "The upload was incomplete.", comment: "Storage error")
        }
    }

    static let noSymlinks = StorageError.unsupported(
        String(localized: "Cloud storage can't hold symbolic links.", comment: "Storage error")
    )
    static let noPermissions = StorageError.unsupported(
        String(localized: "Cloud storage doesn't keep permissions or modification dates.", comment: "Storage error")
    )

    /// CopyObject, UploadPartCopy and CompleteMultipartUpload can report failure
    /// inside an HTTP 200; the result then decodes without an ETag.
    static func requireETag(_ eTag: String?) throws {
        guard eTag?.isEmpty == false else {
            throw StorageError.service(String(localized: "The server reported the copy as failed.", comment: "Storage error"))
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        (error as? AWSErrorType)?.context?.responseCode == .notFound
    }

    /// The provider lacks the feature (tagging, ACLs) entirely, as opposed to refusing this request.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let aws = error as? AWSErrorType else { return false }
        return aws.context?.responseCode == .notImplemented
            || ["NotImplemented", "AccessControlListNotSupported"].contains(aws.errorCode)
    }

    /// Carrying `what` over failed, so the rewrite stops instead of dropping it.
    static func unreadable(_ path: String, _ what: String, _ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        let detail = from(error, path: path).localizedDescription
        return StorageError.service(String(
            localized: "Couldn't read the \(what) of “\(path)”, so it was left unchanged. \(detail)",
            comment: "Storage error; arguments are what couldn't be read (tags, permissions), a path, and the server's reason"
        ))
    }

    static func from(_ error: Error, path: String) -> Error {
        if error is StorageError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        guard let aws = error as? AWSErrorType else { return error }
        switch aws.context?.responseCode {
        case .notFound?:
            return StorageError.notFound(path)
        case .preconditionFailed?:
            // Only our If-Match conditions on reads and copies produce this.
            return StorageError.changed(path)
        case .forbidden?:
            let detail = aws.context?.message ?? ""
            return StorageError.service(detail.isEmpty
                ? String(localized: "Access denied.", comment: "Storage error")
                : detail)
        default:
            let detail = aws.context?.message ?? ""
            return StorageError.service(detail.isEmpty ? aws.errorCode : detail)
        }
    }
}
