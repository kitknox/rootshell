import XCTest

final class StorageProviderTests: XCTestCase {

    // MARK: - Endpoints

    func testPresetEndpointSubstitutesRegionAndAccount() {
        var provider = StorageProvider()
        provider.presetID = "wasabi"
        provider.region = "eu-central-1"
        XCTAssertEqual(provider.resolvedEndpoint, "https://s3.eu-central-1.wasabisys.com")

        provider.presetID = "r2"
        provider.accountID = " abc123 "
        XCTAssertEqual(provider.resolvedEndpoint, "https://abc123.r2.cloudflarestorage.com")
    }

    func testEmptyRegionFallsBackToPresetDefault() {
        var provider = StorageProvider()
        provider.presetID = "b2"
        XCTAssertEqual(provider.effectiveRegion, "us-west-004")
        XCTAssertEqual(provider.resolvedEndpoint, "https://s3.us-west-004.backblazeb2.com")
    }

    func testAWSUsesSDKEndpointsUnlessOverridden() {
        var provider = StorageProvider()
        XCTAssertNil(provider.resolvedEndpoint)
        provider.customEndpoint = "minio.local:9000/"
        XCTAssertEqual(provider.resolvedEndpoint, "https://minio.local:9000")
        provider.customEndpoint = "http://10.0.0.2:9000"
        XCTAssertEqual(provider.resolvedEndpoint, "http://10.0.0.2:9000")
    }

    func testSigningRegion() {
        var akamai = StorageProvider()
        akamai.presetID = "linode"
        akamai.region = "us-southeast-1"
        XCTAssertEqual(akamai.resolvedEndpoint, "https://us-southeast-1.linodeobjects.com")
        XCTAssertEqual(akamai.effectiveSigningRegion, "us-east-1", "Akamai signs with a fixed region")
        akamai.signingRegion = " us-southeast "
        XCTAssertEqual(akamai.effectiveSigningRegion, "us-southeast")

        var wasabi = StorageProvider()
        wasabi.presetID = "wasabi"
        wasabi.region = "eu-central-1"
        XCTAssertEqual(wasabi.effectiveSigningRegion, "eu-central-1", "most services sign with the endpoint's region")
    }

    func testValidation() {
        var provider = StorageProvider()
        provider.presetID = StorageProviderPreset.custom.id
        XCTAssertNotNil(provider.validationError, "custom servers need an endpoint")
        provider.customEndpoint = "https://s3.example.com"
        XCTAssertNil(provider.validationError, "no keys means anonymous access")
        provider.accessKeyID = "AKIA"
        XCTAssertNotNil(provider.validationError, "an access key needs its secret")
        provider.secretAccessKey = "secret"
        XCTAssertNil(provider.validationError)

        var r2 = StorageProvider()
        r2.presetID = "r2"
        XCTAssertNotNil(r2.validationError, "R2 needs an account ID")
    }

    func testNamespaces() {
        var a = StorageProvider()
        var b = StorageProvider()
        b.region = "eu-west-1"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "AWS bucket names are global within a partition")
        b.bucket = "photos"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "a bucket limit doesn't change what a path names")
        b.region = "cn-north-1"
        XCTAssertFalse(a.reachesSameNamespace(as: b), "AWS China is a separate partition")
        a.presetID = "wasabi"
        XCTAssertFalse(a.reachesSameNamespace(as: StorageProvider()))
    }

    func testEndpointIdentityKeepsSchemePortAndPath() {
        var a = StorageProvider()
        a.presetID = StorageProviderPreset.custom.id
        var b = a
        a.customEndpoint = "https://minio.local:9000"
        b.customEndpoint = "https://MINIO.local:9001"
        XCTAssertFalse(a.reachesSameNamespace(as: b), "different ports are different servers")
        b.customEndpoint = "http://minio.local:9000"
        XCTAssertFalse(a.reachesSameNamespace(as: b))
        b.customEndpoint = "https://minio.local:9000/tenant"
        XCTAssertFalse(a.reachesSameNamespace(as: b))
        a.customEndpoint = "https://minio.local"
        b.customEndpoint = "minio.local:443/"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "default port and trailing slash are equivalent")
    }

    func testDecodingToleratesMissingFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old"}"#
        let provider = try JSONDecoder().decode(StorageProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.name, "Old")
        XCTAssertEqual(provider.presetID, StorageProviderPreset.custom.id)
    }

    // MARK: - Keys

    func testChildNames() {
        XCTAssertEqual(S3KeyLogic.childName("docs/a.txt", under: "docs/"), "a.txt")
        XCTAssertEqual(S3KeyLogic.childName("docs/sub/", under: "docs/"), "sub")
        XCTAssertNil(S3KeyLogic.childName("docs/", under: "docs/"), "a folder's own marker is not a child")
        XCTAssertNil(S3KeyLogic.childName("docs/sub/a.txt", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("other/a.txt", under: "docs/"))
        XCTAssertEqual(S3KeyLogic.childName("top.txt", under: ""), "top.txt")
    }

    func testConditionalPutSpellings() {
        // HEAD returns the quoted form; Ceph's gateway only matches the bare one on PUT.
        XCTAssertEqual(S3KeyLogic.ConditionalPut.quoted.ifMatch("\"abc\""), "\"abc\"")
        XCTAssertEqual(S3KeyLogic.ConditionalPut.quoted.ifMatch("abc"), "\"abc\"")
        XCTAssertEqual(S3KeyLogic.ConditionalPut.bare.ifMatch("\"abc\""), "abc")
        XCTAssertNil(S3KeyLogic.ConditionalPut.unsupported.ifMatch("abc"))
        XCTAssertEqual(S3KeyLogic.ConditionalPut.quoted.fallback, .bare)
        XCTAssertEqual(S3KeyLogic.ConditionalPut.bare.fallback, .unsupported)
        XCTAssertNil(S3KeyLogic.ConditionalPut.unsupported.fallback)
    }

    func testKeyClassification() {
        XCTAssertEqual(S3KeyLogic.classify("docs/", under: "docs/"), .ignored, "the folder's own marker")
        XCTAssertEqual(S3KeyLogic.classify("other/a", under: "docs/"), .ignored)
        XCTAssertEqual(S3KeyLogic.classify("docs/a/", under: "docs/"), .child("a"))
        // Strict listings fail on these so a move never deletes what it couldn't copy.
        XCTAssertEqual(S3KeyLogic.classify("docs/./", under: "docs/"), .unrepresentable)
        XCTAssertEqual(S3KeyLogic.classify("docs/..", under: "docs/"), .unrepresentable)
        XCTAssertEqual(S3KeyLogic.classify("docs//", under: "docs/"), .unrepresentable)
    }

    func testDotSegmentsAreNotListed() {
        // Path normalization would turn these into their parent folder.
        XCTAssertNil(S3KeyLogic.childName("docs/./", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("docs/../", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("docs//", under: "docs/"))
        XCTAssertEqual(S3KeyLogic.childName("docs/.hidden", under: "docs/"), ".hidden")
        XCTAssertEqual(S3KeyLogic.childName("docs/...", under: "docs/"), "...")
    }

    func testCopySourceIsURLEncoded() {
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "dir/a file+1ü.txt"), "b/dir/a%20file%2B1%C3%BC.txt")
    }

    func testCopySourcePinsVersion() {
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "a", versionID: "3/L4kqtJl+x"), "b/a?versionId=3%2FL4kqtJl%2Bx")
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "a", versionID: "null"), "b/a", "unversioned objects report \"null\"")
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "a", versionID: nil), "b/a")
    }

    // MARK: - Object management

    func testObjectURLAddressing() {
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "https://s3.us-west-2.amazonaws.com", bucket: "b", key: "dir/a b.txt", forceVirtualHost: false)?.absoluteString,
            "https://b.s3.us-west-2.amazonaws.com/dir/a%20b.txt"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "https://s3.us-west-2.amazonaws.com", bucket: "my.bucket", key: "a", forceVirtualHost: false)?.absoluteString,
            "https://s3.us-west-2.amazonaws.com/my.bucket/a", "dotted buckets fall back to path style"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "http://minio.local:9000", bucket: "b", key: "a+1", forceVirtualHost: false)?.absoluteString,
            "http://minio.local:9000/b/a%2B1"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "https://nyc3.digitaloceanspaces.com", bucket: "b", key: "a", forceVirtualHost: true)?.absoluteString,
            "https://b.nyc3.digitaloceanspaces.com/a"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "https://mybucket.s3.us-west-2.amazonaws.com", bucket: "mybucket", key: "a", forceVirtualHost: true)?.absoluteString,
            "https://mybucket.s3.us-west-2.amazonaws.com/a", "an endpoint that already names the bucket isn't prefixed twice"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "http://minio.local:9000", bucket: "bad%/..", key: "a", forceVirtualHost: false)?.absoluteString,
            "http://minio.local:9000/bad%25%2F../a", "server-supplied bucket names are encoded as one path segment"
        )
        XCTAssertEqual(
            S3KeyLogic.objectURL(endpoint: "https://nyc3.digitaloceanspaces.com", bucket: "bad%", key: "a", forceVirtualHost: true)?.absoluteString,
            "https://nyc3.digitaloceanspaces.com/bad%25/a", "a bucket that isn't a host label falls back to path style"
        )
    }

    func testGrantHeaders() {
        typealias Grant = S3KeyLogic.Grant
        XCTAssertNil(S3KeyLogic.grantHeaders([], ownerID: "o"))
        XCTAssertNil(S3KeyLogic.grantHeaders([Grant(grantee: .id("o"), permission: "FULL_CONTROL")], ownerID: "o"),
                     "owner-only full control is what a copy gets by default")
        XCTAssertEqual(
            S3KeyLogic.grantHeaders([
                Grant(grantee: .id("o"), permission: "FULL_CONTROL"),
                Grant(grantee: .uri("http://acs.amazonaws.com/groups/global/AllUsers"), permission: "READ"),
                Grant(grantee: .email("a@example.com"), permission: "READ"),
            ], ownerID: "o"),
            [
                "FULL_CONTROL": "id=\"o\"",
                "READ": "uri=\"http://acs.amazonaws.com/groups/global/AllUsers\", emailAddress=\"a@example.com\"",
            ]
        )
    }

    func testUnquotedETag() {
        XCTAssertEqual(S3KeyLogic.unquotedETag("\"abc-2\""), "abc-2")
        XCTAssertEqual(S3KeyLogic.unquotedETag("abc"), "abc")
    }

    func testTaggingIsQueryEncoded() {
        XCTAssertEqual(S3KeyLogic.tagging([("env", "prod"), ("owner", "a b&c")]), "env=prod&owner=a%20b%26c")
    }

    func testBucketNames() {
        XCTAssertTrue(S3KeyLogic.isValidBucketName("my-bucket.2026"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("ab"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("MyBucket"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("-bucket"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("bucket."))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("my..bucket"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName("my.-bucket"))
        XCTAssertFalse(S3KeyLogic.isValidBucketName(String(repeating: "a", count: 64)))
    }

    func testMetadataValidation() {
        XCTAssertTrue(S3KeyLogic.isValidMetadata(key: "build-id_2.0", value: "abc 123"))
        XCTAssertFalse(S3KeyLogic.isValidMetadata(key: "", value: "x"))
        XCTAssertFalse(S3KeyLogic.isValidMetadata(key: "has space", value: "x"))
        XCTAssertFalse(S3KeyLogic.isValidMetadata(key: "k", value: "café"))
        XCTAssertFalse(S3KeyLogic.isValidHeaderValue("line\nbreak"))
    }

    func testRestoreState() {
        XCTAssertEqual(S3KeyLogic.restoreState(nil), .none)
        XCTAssertEqual(S3KeyLogic.restoreState("ongoing-request=\"true\""), .inProgress)
        XCTAssertEqual(
            S3KeyLogic.restoreState("ongoing-request=\"false\", expiry-date=\"Fri, 21 Dec 2012 00:00:00 GMT\""),
            .restored(until: Date(timeIntervalSince1970: 1_356_048_000))
        )
    }
}
