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

        // Explicit native AWS endpoints (regional, virtual-hosted bucket, accelerated, PrivateLink)
        // share the same AWS partition namespace as the default AWS provider, so copying between
        // two panes targeting the same object triggers overlap protection instead of Replace-delete.
        let defaultCommercial = StorageProvider()
        let commercialEquivalents = [
            "https://s3.us-east-1.amazonaws.com",
            "https://my-bucket.s3.us-east-1.amazonaws.com",
            "https://my.dotted.bucket.s3.us-east-1.amazonaws.com",
            "https://my-bucket.s3-accelerate.amazonaws.com",
            "https://vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
            "https://bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
            "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
        ]
        for endpoint in commercialEquivalents {
            var explicit = StorageProvider()
            explicit.presetID = StorageProviderPreset.custom.id
            explicit.customEndpoint = endpoint
            XCTAssertTrue(defaultCommercial.reachesSameNamespace(as: explicit), "Native AWS endpoint must match default AWS namespace: \(endpoint)")
            XCTAssertFalse(explicit.needsPathStyleEndpointFixup, "Native AWS endpoint must not revert to path style: \(endpoint)")
        }

        // Partition boundaries stay distinct even with explicit endpoints.
        var defaultChina = StorageProvider()
        defaultChina.region = "cn-north-1"
        var explicitChina = StorageProvider()
        explicitChina.customEndpoint = "https://my-bucket.s3.cn-north-1.amazonaws.com.cn"
        XCTAssertTrue(defaultChina.reachesSameNamespace(as: explicitChina))
        XCTAssertFalse(defaultCommercial.reachesSameNamespace(as: explicitChina))

        var defaultGov = StorageProvider()
        defaultGov.region = "us-gov-west-1"
        for govEndpoint in [
            "https://my-bucket.s3-fips.us-gov-west-1.amazonaws.com",
            "https://vpce-0123456789abcdef0-12345678.s3-fips.us-gov-west-1.vpce.amazonaws.com",
            "https://bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-gov-west-1.vpce.amazonaws.com",
        ] {
            var explicitGov = StorageProvider()
            explicitGov.customEndpoint = govEndpoint
            XCTAssertTrue(defaultGov.reachesSameNamespace(as: explicitGov), "GovCloud endpoint must match GovCloud namespace: \(govEndpoint)")
            XCTAssertFalse(defaultCommercial.reachesSameNamespace(as: explicitGov), "GovCloud must stay distinct from commercial AWS: \(govEndpoint)")
        }

        // Independent Ceph services (including behind AWS ELB/EC2) remain distinct from AWS and each other.
        var cephA = StorageProvider()
        cephA.presetID = StorageProviderPreset.custom.id
        cephA.customEndpoint = "https://my-rgw-alb-1234567890.us-east-1.elb.amazonaws.com"
        cephA.accessKeyID = "TENANT_A_KEY"
        var cephB = cephA
        cephB.customEndpoint = "https://other-rgw-alb-0987654321.us-east-1.elb.amazonaws.com"
        XCTAssertFalse(defaultCommercial.reachesSameNamespace(as: cephA))
        XCTAssertFalse(cephA.reachesSameNamespace(as: cephB))
        XCTAssertFalse(cephA.mayShareNamespace(with: cephB))

        // Two profiles on the same Ceph RGW URL with different credentials may belong to
        // different tenants: not proven same namespace (blocks source-only rename shortcut),
        // but still mayShareNamespace so overlap protection remains active.
        var cephTenantB = cephA
        cephTenantB.accessKeyID = "TENANT_B_KEY"
        XCTAssertFalse(cephA.reachesSameNamespace(as: cephTenantB), "Different RGW credentials must not assume the same tenant")
        XCTAssertTrue(cephA.mayShareNamespace(with: cephTenantB), "Same RGW server must retain overlap protection when tenant is unknown")

        // Same RGW URL and same credentials (ignoring stray whitespace) prove the same tenant.
        var cephTenantACopy = cephA
        cephTenantACopy.accessKeyID = " TENANT_A_KEY\n"
        XCTAssertTrue(cephA.reachesSameNamespace(as: cephTenantACopy))
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
        XCTAssertEqual(
            S3KeyLogic.objectURL(
                endpoint: "https://my-rgw-alb-1234567890.us-east-1.elb.amazonaws.com",
                bucket: "logs",
                key: "dir/report.txt",
                forceVirtualHost: false
            )?.absoluteString,
            "https://my-rgw-alb-1234567890.us-east-1.elb.amazonaws.com/logs/dir/report.txt",
            "Ceph behind an AWS load balancer must use path style unless virtual-host is forced"
        )
    }

    func testPathStyleFixupForCephBehindAWSLoadBalancer() throws {
        let albHost = "my-rgw-alb-1234567890.us-east-1.elb.amazonaws.com"
        var alb = StorageProvider()
        alb.presetID = StorageProviderPreset.custom.id
        alb.customEndpoint = "https://\(albHost)"
        XCTAssertTrue(alb.needsPathStyleEndpointFixup)
        alb.addressingStyle = .virtualHost
        XCTAssertFalse(alb.needsPathStyleEndpointFixup, "explicit virtual-host selection must be respected")

        // ListObjectsV2 rewritten by Soto S3Middleware: host prefixed with bucket, path "/".
        let listURL = try XCTUnwrap(URL(string: "https://logs.\(albHost)/?delimiter=%2F&list-type=2&max-keys=1000"))
        XCTAssertEqual(
            S3KeyLogic.restorePathStyleURL(listURL, endpointHost: albHost)?.absoluteString,
            "https://\(albHost)/logs?delimiter=%2F&list-type=2&max-keys=1000"
        )

        // Object GET/PUT preserves exact percent-encoding, combining marks, and trailing slashes.
        let getURL = try XCTUnwrap(URL(string: "https://logs.\(albHost)/dir/a%20b%2B1/%CC%81report"))
        XCTAssertEqual(
            S3KeyLogic.restorePathStyleURL(getURL, endpointHost: albHost)?.absoluteString,
            "https://\(albHost)/logs/dir/a%20b%2B1/%CC%81report"
        )
        let markerURL = try XCTUnwrap(URL(string: "https://logs.\(albHost)/empty/"))
        XCTAssertEqual(
            S3KeyLogic.restorePathStyleURL(markerURL, endpointHost: albHost)?.absoluteString,
            "https://\(albHost)/logs/empty/"
        )

        // ListBuckets and dotted-bucket path-style requests already target endpointHost directly.
        let listBucketsURL = try XCTUnwrap(URL(string: "https://\(albHost)/"))
        XCTAssertNil(S3KeyLogic.restorePathStyleURL(listBucketsURL, endpointHost: albHost))
        let dottedURL = try XCTUnwrap(URL(string: "https://\(albHost)/my.dotted.bucket/report"))
        XCTAssertNil(S3KeyLogic.restorePathStyleURL(dottedURL, endpointHost: albHost))
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

    // MARK: - Pagination and prefix search

    func testChildPrefixValidationAndObjectListPrefix() {
        XCTAssertFalse(S3KeyLogic.isValidChildPrefix(""))
        XCTAssertFalse(S3KeyLogic.isValidChildPrefix("sub/file"))
        XCTAssertFalse(S3KeyLogic.isValidChildPrefix("/"))
        XCTAssertFalse(S3KeyLogic.isValidChildPrefix("/\u{0301}a"))
        XCTAssertFalse(S3KeyLogic.isValidChildPrefix("dir/\u{0301}a"))
        XCTAssertTrue(S3KeyLogic.isValidChildPrefix("\u{0301}a"))
        XCTAssertTrue(S3KeyLogic.isValidChildPrefix("worker-"))
        XCTAssertTrue(S3KeyLogic.isValidChildPrefix(".env"))
        XCTAssertTrue(S3KeyLogic.isValidChildPrefix("."))

        XCTAssertNil(S3KeyLogic.objectListPrefix(directoryPrefix: "", namePrefix: nil))
        XCTAssertNil(S3KeyLogic.objectListPrefix(directoryPrefix: "", namePrefix: ""))
        XCTAssertEqual(S3KeyLogic.objectListPrefix(directoryPrefix: "", namePrefix: "log-"), "log-")
        XCTAssertEqual(S3KeyLogic.objectListPrefix(directoryPrefix: "2026/", namePrefix: nil), "2026/")
        XCTAssertEqual(S3KeyLogic.objectListPrefix(directoryPrefix: "2026/", namePrefix: ""), "2026/")
        XCTAssertEqual(S3KeyLogic.objectListPrefix(directoryPrefix: "2026/", namePrefix: "worker-"), "2026/worker-")

        // Byte-exact prefix classification distinguishes NFC and NFD folder names.
        XCTAssertEqual(S3KeyLogic.classify("caf\u{00E9}/a.txt", under: "caf\u{00E9}/"), .child("a.txt"))
        XCTAssertEqual(S3KeyLogic.classify("cafe\u{0301}/a.txt", under: "caf\u{00E9}/"), .ignored)
        XCTAssertEqual(S3KeyLogic.classify("dir/\u{0301}report", under: "dir/"), .child("\u{0301}report"))
    }

    func testBucketListPaginationCapabilityAndMaxBuckets() {
        var aws = StorageProvider()
        XCTAssertTrue(aws.supportsPaginatedBucketListing)
        XCTAssertNil(aws.endpointBucket)
        XCTAssertNil(aws.effectiveBucket)

        // Explicit native AWS S3 service endpoints must still request paginated ListBuckets (max-buckets).
        let nativeAWSEndpoints = [
            "https://s3.amazonaws.com",
            "https://s3.us-east-1.amazonaws.com",
            "https://s3-us-west-2.amazonaws.com",
            "https://s3.dualstack.eu-west-1.amazonaws.com.",
            "https://s3-fips.us-gov-west-1.amazonaws.com",
            "https://s3-fips.dualstack.us-east-1.amazonaws.com",
            "https://s3.cn-north-1.amazonaws.com.cn",
            "https://vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
            "https://bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
        ]
        for endpoint in nativeAWSEndpoints {
            aws.customEndpoint = endpoint
            XCTAssertTrue(aws.supportsPaginatedBucketListing, "Expected native AWS S3 endpoint: \(endpoint)")
            XCTAssertFalse(aws.usesTransferAccelerationEndpoint)
            XCTAssertNil(aws.endpointBucket, "Service endpoint must not infer a bucket: \(endpoint)")
            XCTAssertNil(aws.effectiveBucket, "Service endpoint with empty bucket must remain account-scoped: \(endpoint)")
            XCTAssertNil(aws.validationError)
        }

        // Bare Transfer Acceleration endpoints do not support ListBuckets and require a bucket name.
        let bareAccelerateEndpoints = [
            "https://s3-accelerate.amazonaws.com",
            "https://s3-accelerate.dualstack.amazonaws.com",
        ]
        for endpoint in bareAccelerateEndpoints {
            var accelerated = StorageProvider()
            accelerated.customEndpoint = endpoint
            XCTAssertFalse(accelerated.supportsPaginatedBucketListing, "Transfer Acceleration cannot serve ListBuckets: \(endpoint)")
            XCTAssertTrue(accelerated.usesTransferAccelerationEndpoint, "Expected Transfer Acceleration endpoint: \(endpoint)")
            XCTAssertNil(accelerated.endpointBucket)
            XCTAssertNil(accelerated.effectiveBucket)
            XCTAssertNotNil(accelerated.validationError, "Bare Transfer Acceleration without a bucket must be rejected: \(endpoint)")
            accelerated.bucket = "my-bucket"
            XCTAssertNil(accelerated.validationError, "Transfer Acceleration with a bucket is valid: \(endpoint)")
        }

        // Bucket-specific virtual-hosted AWS endpoints infer the bucket when left blank
        // (preventing account-level ListBuckets GET / on a bucket host), normalize the SDK
        // endpoint to the service host (so dotted buckets are never included in both host
        // and path), and reject mismatched buckets.
        let bucketSpecificAWSEndpoints: [(endpoint: String, bucket: String, sdkEndpoint: String, expectedURL: String, isAccelerate: Bool)] = [
            (
                "https://my-bucket.s3.us-east-1.amazonaws.com",
                "my-bucket",
                "https://s3.us-east-1.amazonaws.com",
                "https://my-bucket.s3.us-east-1.amazonaws.com/report",
                false
            ),
            (
                "https://my.dotted.bucket.s3.us-east-1.amazonaws.com",
                "my.dotted.bucket",
                "https://s3.us-east-1.amazonaws.com",
                "https://s3.us-east-1.amazonaws.com/my.dotted.bucket/report",
                false
            ),
            (
                "https://my-bucket.s3.amazonaws.com",
                "my-bucket",
                "https://s3.amazonaws.com",
                "https://my-bucket.s3.amazonaws.com/report",
                false
            ),
            (
                "https://my-bucket.s3-us-west-2.amazonaws.com",
                "my-bucket",
                "https://s3-us-west-2.amazonaws.com",
                "https://my-bucket.s3-us-west-2.amazonaws.com/report",
                false
            ),
            (
                "https://my-bucket.s3.dualstack.eu-west-1.amazonaws.com",
                "my-bucket",
                "https://s3.dualstack.eu-west-1.amazonaws.com",
                "https://my-bucket.s3.dualstack.eu-west-1.amazonaws.com/report",
                false
            ),
            (
                "https://my-bucket.s3-fips.us-gov-west-1.amazonaws.com",
                "my-bucket",
                "https://s3-fips.us-gov-west-1.amazonaws.com",
                "https://my-bucket.s3-fips.us-gov-west-1.amazonaws.com/report",
                false
            ),
            (
                "https://my-bucket.s3.cn-north-1.amazonaws.com.cn",
                "my-bucket",
                "https://s3.cn-north-1.amazonaws.com.cn",
                "https://my-bucket.s3.cn-north-1.amazonaws.com.cn/report",
                false
            ),
            (
                "https://my.dotted.bucket.s3.cn-north-1.amazonaws.com.cn",
                "my.dotted.bucket",
                "https://s3.cn-north-1.amazonaws.com.cn",
                "https://s3.cn-north-1.amazonaws.com.cn/my.dotted.bucket/report",
                false
            ),
            (
                "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
                "my-bucket",
                "https://bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
                "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com/report",
                false
            ),
            (
                "https://my.dotted.bucket.bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
                "my.dotted.bucket",
                "https://bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
                "https://bucket.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com/my.dotted.bucket/report",
                false
            ),
            (
                "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
                "my-bucket",
                "https://bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com",
                "https://my-bucket.bucket.vpce-0123456789abcdef0-12345678.s3-fips.us-east-1.vpce.amazonaws.com/report",
                false
            ),
            (
                "https://my-bucket.s3-accelerate.amazonaws.com",
                "my-bucket",
                "https://s3-accelerate.amazonaws.com",
                "https://my-bucket.s3-accelerate.amazonaws.com/report",
                true
            ),
            (
                "https://my-bucket.s3-accelerate.dualstack.amazonaws.com",
                "my-bucket",
                "https://s3-accelerate.dualstack.amazonaws.com",
                "https://my-bucket.s3-accelerate.dualstack.amazonaws.com/report",
                true
            ),
        ]
        for entry in bucketSpecificAWSEndpoints {
            var scoped = StorageProvider()
            scoped.customEndpoint = entry.endpoint
            XCTAssertFalse(scoped.supportsPaginatedBucketListing, "Bucket-specific AWS host cannot serve ListBuckets: \(entry.endpoint)")
            XCTAssertEqual(scoped.usesTransferAccelerationEndpoint, entry.isAccelerate, entry.endpoint)
            XCTAssertEqual(scoped.endpointBucket, entry.bucket, entry.endpoint)
            XCTAssertEqual(scoped.effectiveBucket, entry.bucket, "Must infer bucket to avoid ListBuckets GET /: \(entry.endpoint)")
            XCTAssertEqual(scoped.sdkEndpoint, entry.sdkEndpoint, "SDK endpoint must normalize bucket host: \(entry.endpoint)")
            XCTAssertEqual(
                S3KeyLogic.objectURL(
                    endpoint: entry.sdkEndpoint,
                    bucket: entry.bucket,
                    key: "report",
                    forceVirtualHost: scoped.usesVirtualHost
                )?.absoluteString,
                entry.expectedURL,
                "Resulting object request URL must not double the bucket: \(entry.endpoint)"
            )
            XCTAssertNil(scoped.validationError, "Blank bucket infers from host: \(entry.endpoint)")

            scoped.bucket = "/\(entry.bucket)/"
            XCTAssertEqual(scoped.effectiveBucket, entry.bucket)
            XCTAssertNil(scoped.validationError, "Matching explicit bucket is valid: \(entry.endpoint)")

            scoped.bucket = "other-bucket"
            XCTAssertNotNil(scoped.validationError, "Mismatched explicit bucket must be rejected: \(entry.endpoint)")
        }

        // Custom gateways (including Ceph RGW behind an AWS ALB/NLB/EC2/VPC endpoint service),
        // and spoofed domains must retain plain GET / without max-buckets and without inferring a bucket.
        let nonNativeEndpoints = [
            "https://ceph.internal:7480",
            "https://my-rgw-alb-1234567890.us-east-1.elb.amazonaws.com",
            "https://internal-s3-rgw-1234567890.eu-west-1.elb.amazonaws.com",
            "https://s3-rgw-nlb-0123456789abcdef.elb.us-east-1.amazonaws.com",
            "https://ec2-198-51-100-1.compute-1.amazonaws.com",
            "https://ec2-198-51-100-1.us-west-2.compute-1.amazonaws.com",
            "https://abc123def.execute-api.us-east-1.amazonaws.com",
            "https://vpce-01234.vpce-svc-09876.us-east-1.vpce.amazonaws.com",
            "https://accesspoint.vpce-0123456789abcdef0-12345678.s3.us-east-1.vpce.amazonaws.com",
            "https://amazonaws.com",
            "https://fakeamazonaws.com",
            "https://s3.us-east-1.amazonaws.com.example.com",
        ]
        for endpoint in nonNativeEndpoints {
            var gateway = StorageProvider()
            gateway.customEndpoint = endpoint
            XCTAssertFalse(gateway.supportsPaginatedBucketListing, "Expected non-native endpoint: \(endpoint)")
            XCTAssertNil(gateway.endpointBucket, "Non-AWS service endpoint must not infer a bucket: \(endpoint)")
            XCTAssertNil(gateway.effectiveBucket, "Non-AWS service endpoint must retain plain GET /: \(endpoint)")
            XCTAssertNil(gateway.validationError, "Non-AWS service endpoint remains valid with blank bucket: \(endpoint)")
        }

        var r2 = StorageProvider()
        r2.presetID = "r2"
        r2.accountID = "acct"
        XCTAssertFalse(r2.supportsPaginatedBucketListing)

        var custom = StorageProvider()
        custom.presetID = StorageProviderPreset.custom.id
        custom.customEndpoint = "https://rgw.example.com"
        XCTAssertFalse(custom.supportsPaginatedBucketListing)
        custom.customEndpoint = "https://s3.us-west-2.amazonaws.com"
        XCTAssertTrue(custom.supportsPaginatedBucketListing)

        XCTAssertEqual(S3KeyLogic.bucketListMaxBuckets(pageSize: 1_000, supportsPaginatedBuckets: true), 1_000)
        XCTAssertEqual(S3KeyLogic.bucketListMaxBuckets(pageSize: 0, supportsPaginatedBuckets: true), 1)
        XCTAssertEqual(S3KeyLogic.bucketListMaxBuckets(pageSize: 25_000, supportsPaginatedBuckets: true), 10_000)
        XCTAssertNil(S3KeyLogic.bucketListMaxBuckets(pageSize: 1_000, supportsPaginatedBuckets: false))
    }

    func testContinuationTokenComparesExactUTF8BytesAndThrowsWhenStalled() throws {
        XCTAssertEqual(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: "tok-2", currentToken: nil), "tok-2")
        XCTAssertEqual(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: "tok-2", currentToken: "tok-1"), "tok-2")
        XCTAssertNil(try S3KeyLogic.nextContinuationToken(isTruncated: false, nextToken: "tok-2", currentToken: "tok-1"))
        XCTAssertNil(try S3KeyLogic.nextContinuationToken(isTruncated: nil, nextToken: "tok-2", currentToken: "tok-1"))

        // Ceph RGW uses raw object names as NextContinuationToken: NFC and NFD spellings
        // are byte-distinct markers and MUST NOT be treated as a repeated token.
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "precondition: Swift String equates NFC and NFD")
        XCTAssertEqual(
            Array(try XCTUnwrap(S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: nfd, currentToken: nfc)).utf8),
            Array(nfd.utf8)
        )
        XCTAssertEqual(
            Array(try XCTUnwrap(S3KeyLogic.nextBucketContinuationToken(nextToken: nfd, currentToken: nfc)).utf8),
            Array(nfd.utf8)
        )

        // Truncated responses with missing, empty, or byte-identical tokens must throw
        // instead of silently returning a partial listing as complete.
        XCTAssertThrowsError(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: nil, currentToken: "tok-1")) { error in
            XCTAssertEqual(error as? S3KeyLogic.PaginationError, .stalled)
        }
        XCTAssertThrowsError(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: "", currentToken: "tok-1")) { error in
            XCTAssertEqual(error as? S3KeyLogic.PaginationError, .stalled)
        }
        XCTAssertThrowsError(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: "tok-1", currentToken: "tok-1")) { error in
            XCTAssertEqual(error as? S3KeyLogic.PaginationError, .stalled)
        }
        XCTAssertThrowsError(try S3KeyLogic.nextContinuationToken(isTruncated: true, nextToken: nfc, currentToken: nfc)) { error in
            XCTAssertEqual(error as? S3KeyLogic.PaginationError, .stalled)
        }

        XCTAssertEqual(try S3KeyLogic.nextBucketContinuationToken(nextToken: "b-2", currentToken: nil), "b-2")
        XCTAssertNil(try S3KeyLogic.nextBucketContinuationToken(nextToken: "", currentToken: nil))
        XCTAssertThrowsError(try S3KeyLogic.nextBucketContinuationToken(nextToken: "b-1", currentToken: "b-1")) { error in
            XCTAssertEqual(error as? S3KeyLogic.PaginationError, .stalled)
        }
    }

    func testFetchNonEmptyPageStopsAfterFirstNonEmptyPage() async throws {
        var requestedTokens: [String?] = []
        let pages: [[UInt8]: ([String], String?)] = [
            Array("start".utf8): (["a.txt", "b.txt"], "tok-2"),
            Array("tok-2".utf8): (["c.txt"], nil),
        ]
        let (items, next) = try await S3KeyLogic.fetchNonEmptyPage(startingAt: nil) { token in
            requestedTokens.append(token)
            let key = Array((token ?? "start").utf8)
            return pages[key] ?? ([], nil)
        }
        XCTAssertEqual(requestedTokens, [nil], "must not eagerly fetch page 2 when page 1 already has rows")
        XCTAssertEqual(items, ["a.txt", "b.txt"])
        XCTAssertEqual(next, "tok-2")
    }

    func testFetchNonEmptyPageAdvancesAcrossNFCAndNFDMarkersAndThrowsOnCycles() async throws {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"

        // Byte-distinct NFC then NFD markers across ignored-only pages must advance cleanly.
        var calls: [[UInt8]?] = []
        let pages: [[UInt8]: ([String], String?)] = [
            Array("start".utf8): ([], nfc),
            Array(nfc.utf8): ([], nfd),
            Array(nfd.utf8): (["visible.txt"], "tok-4"),
        ]
        let (items, next) = try await S3KeyLogic.fetchNonEmptyPage(startingAt: nil) { token in
            calls.append(token.map { Array($0.utf8) })
            let key = Array((token ?? "start").utf8)
            return pages[key] ?? ([], nil)
        }
        XCTAssertEqual(calls, [nil, Array(nfc.utf8), Array(nfd.utf8)])
        XCTAssertEqual(items, ["visible.txt"])
        XCTAssertEqual(next, "tok-4")

        // A genuinely cycling server must throw .stalled rather than accepting a partial listing.
        var cycleCalls: [String?] = []
        let cyclingPages: [[UInt8]: ([String], String?)] = [
            Array("start".utf8): ([], "tok-a"),
            Array("tok-a".utf8): ([], "tok-b"),
            Array("tok-b".utf8): ([], "tok-a"),
        ]
        do {
            _ = try await S3KeyLogic.fetchNonEmptyPage(startingAt: nil) { token in
                cycleCalls.append(token)
                let key = Array((token ?? "start").utf8)
                return cyclingPages[key] ?? ([], nil)
            }
            XCTFail("Expected PaginationError.stalled on cycling continuation tokens")
        } catch let error as S3KeyLogic.PaginationError {
            XCTAssertEqual(error, .stalled)
            XCTAssertEqual(cycleCalls, [nil, "tok-a", "tok-b"])
        }
    }

    func testFetchNonEmptyPageRespectsCancellation() async {
        let task = Task {
            try await S3KeyLogic.fetchNonEmptyPage(startingAt: nil) { (_: String?) -> ([String], String?) in
                ([], "next")
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMergePagePreservesCanonicallyEquivalentUTF8PathsAndSamePathFileFolder() {
        struct Item: Equatable {
            let path: String
            let isDir: Bool
            let size: Int

            var id: FileEntryID { FileEntryID(path: path, isDirectory: isDir) }
        }

        let nfcPath = "/b/caf\u{00E9}"
        let nfdPath = "/b/cafe\u{0301}"

        let page1 = [
            Item(path: "/b/foo", isDir: true, size: 0),
            Item(path: nfcPath, isDir: false, size: 10),
            Item(path: "/b/b.txt", isDir: false, size: 20),
        ]
        // Page 2 has an NFD spelling of the same display name, a boundary repeat of b.txt,
        // and a file named "foo" alongside folder "foo/".
        let page2 = [
            Item(path: "/b/b.txt", isDir: false, size: 25),
            Item(path: nfdPath, isDir: false, size: 15),
            Item(path: "/b/foo", isDir: false, size: 5),
            Item(path: "/b/c.txt", isDir: false, size: 30),
        ]
        let merged = S3KeyLogic.mergePage(page1, with: page2) { $0.id }
        XCTAssertEqual(merged.count, 6, "NFC and NFD objects must both be preserved as distinct rows")
        XCTAssertEqual(merged.map(\.id), [
            FileEntryID(path: "/b/foo", isDirectory: true),
            FileEntryID(path: nfcPath, isDirectory: false),
            FileEntryID(path: "/b/b.txt", isDirectory: false),
            FileEntryID(path: nfdPath, isDirectory: false),
            FileEntryID(path: "/b/foo", isDirectory: false),
            FileEntryID(path: "/b/c.txt", isDirectory: false),
        ])
        XCTAssertEqual(merged[1].size, 10)
        XCTAssertEqual(merged[2].size, 25)
        XCTAssertEqual(merged[3].size, 15)
    }

    func testPrefixSearchActionDecisions() {
        // While a folder load is in flight, defer server prefix search until the destination installs.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(
                query: "worker",
                isListingReady: false,
                supportsPrefixSearch: true,
                baseHasMore: true,
                activePrefix: nil,
                prefixHasMore: false
            ),
            .clear
        )
        // Complete folder: always filter locally, never hit S3.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "worker", supportsPrefixSearch: true, baseHasMore: false, activePrefix: nil, prefixHasMore: false),
            .clear
        )
        // Non-S3 or bucket root (/): never hit S3 prefix search.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "worker", supportsPrefixSearch: false, baseHasMore: true, activePrefix: nil, prefixHasMore: false),
            .clear
        )
        // Empty or slash-containing queries clear server prefix state.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "w", prefixHasMore: false),
            .clear
        )
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "sub/file", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "sub", prefixHasMore: false),
            .clear
        )
        // Initial query on truncated bucket triggers server fetch.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "w", supportsPrefixSearch: true, baseHasMore: true, activePrefix: nil, prefixHasMore: false),
            .fetch(query: "w", keepExistingWhileLoading: false)
        )
        // Narrowing an already-exhausted UTF-8 prefix reuses results with zero network calls.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "worker", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "w", prefixHasMore: false),
            .keepCurrent
        )
        // Same query as a truncated prefix keeps current results (e.g. backspaced during debounce).
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "w", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "w", prefixHasMore: true),
            .keepCurrent
        )
        // Narrowing a truncated prefix fetches the narrower prefix while keeping existing items to prevent flicker.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "wo", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "w", prefixHasMore: true),
            .fetch(query: "wo", keepExistingWhileLoading: true)
        )
        // Case change or distinct Unicode normalization bytes (NFC vs NFD) triggers a fresh S3 prefix fetch.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "Worker", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "w", prefixHasMore: false),
            .fetch(query: "Worker", keepExistingWhileLoading: false)
        )
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "cafe\u{0301}", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "caf\u{00E9}", prefixHasMore: false),
            .fetch(query: "cafe\u{0301}", keepExistingWhileLoading: false)
        )
        // Broadening back from "wo" to "w" triggers a fresh S3 prefix fetch.
        XCTAssertEqual(
            S3KeyLogic.prefixSearchAction(query: "w", supportsPrefixSearch: true, baseHasMore: true, activePrefix: "wo", prefixHasMore: false),
            .fetch(query: "w", keepExistingWhileLoading: false)
        )
    }
}
