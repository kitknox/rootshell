import XCTest

@MainActor
final class SSHFPRecordTests: XCTestCase {
    // freefall.freebsd.org host keys (ssh-keyscan) and its published SSHFP RRset.
    private let ed25519Blob = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIBsUvX5QOeLURHPw6LJQNiTcsOHp+GRsl9ecWGlHhwxK")!
    private let ecdsaBlob = Data(base64Encoded: "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPuxrOcszYkA9gaWpQEFjyMdAw/NmwgD8qR2IGSgif7TIzKMG3g1yAPfeg8yT6cyAGB1/D06Ip729/K3XAB5g+c=")!
    private let rsaBlob = Data(base64Encoded: "AAAAB3NzaC1yc2EAAAABIwAAAIEA6FpCVgwrxcHE5pGAP+RuSKG4ZbI5hpQpy8Zxo25iJgah9wSqgt67I4SDZRfbm86pkJgUJ6M4qCjpBV5oQCBkXWHDcNdKqL0Kwnw1RICucj9wYB6RkOwHLIz4fJJzq3mpWKr7YucClGE2+S/p19jSuacC8+WiTmDJy+729iSGSjE=")!

    private var freefallRecords: [SSHFPRecord] {
        [
            record(1, 1, "b35c16d3da4b7fe15c15a55e7b6465231f9ede84"),
            record(1, 2, "4b493272cccdd234c02ade8fafd4e772e5a3c775364b6bcaeee7a98b16e4ab04"),
            record(3, 1, "e37999a583e73f49b22d19c306fb69d161d15988"),
            record(3, 2, "a9b851fe028353393112f74db6c4e547bb8cea66e3f1443680c421a1b5eb420f"),
            record(4, 1, "fe8be9cbc5a1d5110809e4b5267122f656171db8"),
            record(4, 2, "a09ec5297e544c158fe029dcb2bb1a21bd496df6edab328e3189e2de854b028d"),
        ]
    }

    /// Cloudflare DoH answer for `freefall.freebsd.org SSHFP` (AD set, 6 SSHFP + 1 RRSIG).
    private let cloudflareResponse = Data(base64Encoded: """
        AACBoAABAAcAAAABCGZyZWVmYWxsB2ZyZWVic2QDb3JnAAAsAAHADAAsAAEAAA4QABYBAbNcFtPaS3/hXBWlXntkZSMfnt6EwAwA\
        LAABAAAOEAAiAQJLSTJyzM3SNMAq3o+v1Ody5aPHdTZLa8ru56mLFuSrBMAMACwAAQAADhAAFgMB43mZpYPnP0myLRnDBvtp0WHR\
        WYjADAAsAAEAAA4QACIDAqm4Uf4Cg1M5MRL3TbbE5Ue7jOpm4/FENoDEIaG160IPwAwALAABAAAOEAAWBAH+i+nLxaHVEQgJ5LUm\
        cSL2VhcduMAMACwAAQAADhAAIgQCoJ7FKX5UTBWP4CncsrsaIb1JbfbtqzKOMYni3oVLAo3ADAAuAAEAAA4QAR8ALAgDAAAOEGru\
        /atq2+9gA1EHZnJlZWJzZANvcmcAR3gEeH0JxmMGkss0TYo80TZcWLsU3RDs+4KfBXZWO4eaGQrA0K1pqgoXkD5IyHdjjORhnmzT\
        B3AZ5MbNWs2nyhLbCtV4U5v3+NASvsmfXPM9wVHy30siLUQg5eMfZw0Bu6ttYQa2y2W8CT56Ao3Uhz7Yrr1BICW4f60p5JG0g3aa\
        FMcdXqtC/PQzd82YpSWPGeX4LuQ+O5ErezgiZxB5knU8H2DGcIDbQd76hxM+1B+/1Mi8ZbGQ/nzl7O1NW6YcEATTfeWj9pbhX5EH\
        OT8pniIJ8WVFMY4Hg2xf3xCuFwdCSytjg+s8sGcvAHG/nQsO5N+cTSUW3QjYnSLWy39/KAAAKQTQAACAAAAA
        """)!

    // MARK: - RDATA

    func testParsesRData() throws {
        let sha256 = try XCTUnwrap(SSHFPRecord(rdata: Data([4, 2] + [UInt8](repeating: 0xAB, count: 32))))
        XCTAssertEqual(sha256.algorithm, 4)
        XCTAssertEqual(sha256.fingerprintType, 2)
        XCTAssertEqual(sha256.fingerprint.count, 32)
        XCTAssertNotNil(SSHFPRecord(rdata: Data([1, 1] + [UInt8](repeating: 0, count: 20))))
        // Unknown digest types parse but never match.
        XCTAssertNotNil(SSHFPRecord(rdata: Data([4, 9, 1, 2, 3])))
    }

    func testRejectsBadRData() {
        XCTAssertNil(SSHFPRecord(rdata: Data([4, 2])))
        XCTAssertNil(SSHFPRecord(rdata: Data([4, 2] + [UInt8](repeating: 0, count: 31))))
        XCTAssertNil(SSHFPRecord(rdata: Data([4, 1] + [UInt8](repeating: 0, count: 32))))
    }

    func testAlgorithmNumbers() {
        XCTAssertEqual(SSHFPRecord.algorithm(forKeyType: "ssh-rsa"), 1)
        XCTAssertEqual(SSHFPRecord.algorithm(forKeyType: "ssh-dss"), 2)
        XCTAssertEqual(SSHFPRecord.algorithm(forKeyType: "ecdsa-sha2-nistp384"), 3)
        XCTAssertEqual(SSHFPRecord.algorithm(forKeyType: "ssh-ed25519"), 4)
        XCTAssertEqual(SSHFPRecord.algorithm(forKeyType: "ssh-ed448"), 6)
        XCTAssertNil(SSHFPRecord.algorithm(forKeyType: "ssh-ed25519-cert-v01@openssh.com"))
    }

    // MARK: - Matching

    func testFreefallKeysMatchPublishedRecords() {
        let result = SSHFPLookupResult(records: freefallRecords, dnssec: .secure)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .match(validated: true))
        XCTAssertEqual(evaluate("ecdsa-sha2-nistp256", ecdsaBlob, result), .match(validated: true))
        XCTAssertEqual(evaluate("ssh-rsa", rsaBlob, result), .match(validated: true))
    }

    func testInsecureMatchIsNotValidated() {
        let result = SSHFPLookupResult(records: freefallRecords, dnssec: .insecure)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .match(validated: false))
    }

    func testDifferentKeyMismatches() {
        let result = SSHFPLookupResult(records: freefallRecords, dnssec: .secure)
        // The RSA blob presented as an Ed25519 key hashes to nothing published.
        XCTAssertEqual(evaluate("ssh-ed25519", rsaBlob, result), .mismatch(validated: true))
    }

    func testSHA256WinsOverSHA1() {
        let records = [
            record(4, 1, "fe8be9cbc5a1d5110809e4b5267122f656171db8"),
            record(4, 2, String(repeating: "00", count: 32)),
        ]
        let result = SSHFPLookupResult(records: records, dnssec: .insecure)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .mismatch(validated: false))
    }

    func testSHA1UsedWithoutSHA256() {
        let result = SSHFPLookupResult(records: [record(4, 1, "fe8be9cbc5a1d5110809e4b5267122f656171db8")], dnssec: .insecure)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .match(validated: false))
    }

    func testOtherAlgorithmsOnlyIsNoRecords() {
        let result = SSHFPLookupResult(records: freefallRecords.filter { $0.algorithm != 4 }, dnssec: .secure)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .noRecords)
    }

    func testBogusAndUnavailable() {
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, SSHFPLookupResult(records: freefallRecords, dnssec: .bogus)), .bogus)
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, nil), .unavailable)
        XCTAssertEqual(evaluate("ssh-mldsa44-ed25519", ed25519Blob, SSHFPLookupResult(records: freefallRecords, dnssec: .secure)),
                       .unavailable)
    }

    func testPromptLines() {
        XCTAssertNil(SSHFPVerdict.unavailable.promptLine)
        XCTAssertNil(SSHFPVerdict.noRecords.promptLine)
        XCTAssertEqual(SSHFPVerdict.match(validated: true).promptLine, "DNS: matches SSHFP record (DNSSEC-validated)")
        XCTAssertTrue(SSHFPVerdict.mismatch(validated: false).promptLine?.hasPrefix("WARNING") == true)
    }

    // MARK: - Hostnames

    func testSkipsNamesWithoutPublicSSHFP() {
        XCTAssertTrue(SSHFPRecord.shouldLookUp(hostname: "freefall.freebsd.org"))
        XCTAssertTrue(SSHFPRecord.shouldLookUp(hostname: "Freefall.FreeBSD.org."))
        XCTAssertFalse(SSHFPRecord.shouldLookUp(hostname: "192.168.1.10"))
        XCTAssertFalse(SSHFPRecord.shouldLookUp(hostname: "fd00::1"))
        XCTAssertFalse(SSHFPRecord.shouldLookUp(hostname: "nas"))
        XCTAssertFalse(SSHFPRecord.shouldLookUp(hostname: "nas.local"))
        XCTAssertFalse(SSHFPRecord.shouldLookUp(hostname: "box.tail1234.ts.net"))
    }

    // MARK: - DoH wire format

    func testQueryEncoding() throws {
        let query = try XCTUnwrap(SSHFPDNSMessage.query(name: "freefall.freebsd.org."))
        XCTAssertEqual(hex(query),
                       "000001200001000000000001086672656566616c6c0766726565627364036f726700002c000100002904d0000080000000")
    }

    func testQueryRejectsBadNames() {
        XCTAssertNil(SSHFPDNSMessage.query(name: "a..b"))
        XCTAssertNil(SSHFPDNSMessage.query(name: String(repeating: "x", count: 64) + ".com"))
        XCTAssertNil(SSHFPDNSMessage.query(name: "bücher.example"))
        XCTAssertNil(SSHFPDNSMessage.query(name: Array(repeating: String(repeating: "x", count: 63), count: 4).joined(separator: ".")))
    }

    func testParsesCloudflareAnswer() throws {
        let result = try XCTUnwrap(SSHFPDNSMessage.parse(response: cloudflareResponse))
        XCTAssertEqual(result.dnssec, .secure)
        XCTAssertEqual(result.records.count, 6)
        XCTAssertEqual(Set(result.records.map { hex($0.fingerprint) }), Set(freefallRecords.map { hex($0.fingerprint) }))
        XCTAssertEqual(evaluate("ssh-ed25519", ed25519Blob, result), .match(validated: true))
    }

    func testParsesStatusCodes() {
        // Header only: QR|RD, RA, then rcode in the low nibble of byte 3.
        func header(_ flags: UInt8, _ rcodeByte: UInt8) -> Data { Data([0, 0, flags, rcodeByte, 0, 0, 0, 0, 0, 0, 0, 0]) }
        XCTAssertEqual(SSHFPDNSMessage.parse(response: header(0x81, 0xA3)), SSHFPLookupResult(records: [], dnssec: .secure))
        XCTAssertEqual(SSHFPDNSMessage.parse(response: header(0x81, 0x80)), SSHFPLookupResult(records: [], dnssec: .insecure))
        XCTAssertNil(SSHFPDNSMessage.parse(response: header(0x81, 0x82)))  // SERVFAIL (bogus zones)
        XCTAssertNil(SSHFPDNSMessage.parse(response: header(0x83, 0x80)))  // truncated
        XCTAssertNil(SSHFPDNSMessage.parse(response: header(0x01, 0x80)))  // not a response
        XCTAssertNil(SSHFPDNSMessage.parse(response: cloudflareResponse.prefix(100)))
    }

    // MARK: - Helpers

    private func evaluate(_ keyType: String, _ blob: Data, _ result: SSHFPLookupResult?) -> SSHFPVerdict {
        SSHFPRecord.evaluate(keyType: keyType, keyBlob: blob, result: result)
    }

    private func record(_ algorithm: UInt8, _ type: UInt8, _ hexDigest: String) -> SSHFPRecord {
        var bytes: [UInt8] = []
        var index = hexDigest.startIndex
        while index < hexDigest.endIndex {
            let next = hexDigest.index(index, offsetBy: 2)
            bytes.append(UInt8(hexDigest[index..<next], radix: 16)!)
            index = next
        }
        return SSHFPRecord(algorithm: algorithm, fingerprintType: type, fingerprint: Data(bytes))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
