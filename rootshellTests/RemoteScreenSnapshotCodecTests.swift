import CoreGraphics
import CryptoKit
import XCTest

final class RemoteScreenSnapshotCodecTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)
    private let profileID = UUID()

    private func makeImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeRecord() -> RemoteScreenSnapshotRecord {
        RemoteScreenSnapshotRecord(
            endpoint: "kit@studio.local:5900 via direct",
            capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            jpeg: Data("not really a jpeg, but long enough to find in a leak".utf8))
    }

    // MARK: Sealing

    func testSealedRecordRoundTrips() throws {
        let record = makeRecord()
        let sealed = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
        XCTAssertEqual(try RemoteScreenSnapshotCodec.open(sealed, profileID: profileID, using: key), record)
    }

    func testSealedRecordHidesTheEndpointAndThePicture() throws {
        let record = makeRecord()
        let sealed = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
        XCTAssertNil(sealed.range(of: Data("studio.local".utf8)))
        XCTAssertNil(sealed.range(of: record.jpeg))
    }

    func testEachSealUsesAFreshNonce() throws {
        let record = makeRecord()
        let first = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
        let second = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
        XCTAssertNotEqual(first, second)
    }

    func testRecordSealedForOneProfileDoesNotOpenForAnother() throws {
        let sealed = try RemoteScreenSnapshotCodec.seal(makeRecord(), profileID: profileID, using: key)
        XCTAssertThrowsError(try RemoteScreenSnapshotCodec.open(sealed, profileID: UUID(), using: key))
    }

    func testRecordDoesNotOpenWithAnotherKey() throws {
        let sealed = try RemoteScreenSnapshotCodec.seal(makeRecord(), profileID: profileID, using: key)
        XCTAssertThrowsError(try RemoteScreenSnapshotCodec.open(
            sealed, profileID: profileID, using: SymmetricKey(size: .bits256)))
    }

    func testTamperedRecordDoesNotOpen() throws {
        var sealed = try RemoteScreenSnapshotCodec.seal(makeRecord(), profileID: profileID, using: key)
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try RemoteScreenSnapshotCodec.open(sealed, profileID: profileID, using: key))
    }

    func testARecordFromANewerFormatIsRejected() throws {
        var record = makeRecord()
        record.version = RemoteScreenSnapshotRecord.currentVersion + 1
        let sealed = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
        XCTAssertThrowsError(try RemoteScreenSnapshotCodec.open(sealed, profileID: profileID, using: key)) { error in
            XCTAssertEqual(
                error as? RemoteScreenSnapshotCodec.CodecError,
                .unsupportedVersion(RemoteScreenSnapshotRecord.currentVersion + 1))
        }
    }

    // MARK: Images

    func testScaledSizeFitsTheLongEdgeAndNeverUpscales() {
        let landscape = RemoteScreenSnapshotCodec.scaledSize(width: 5120, height: 2880, maxDimension: 1600)
        XCTAssertEqual(landscape.width, 1600)
        XCTAssertEqual(landscape.height, 900)

        let portrait = RemoteScreenSnapshotCodec.scaledSize(width: 1080, height: 1920, maxDimension: 1600)
        XCTAssertEqual(portrait.width, 900)
        XCTAssertEqual(portrait.height, 1600)

        let small = RemoteScreenSnapshotCodec.scaledSize(width: 1280, height: 720, maxDimension: 1600)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)

        let empty = RemoteScreenSnapshotCodec.scaledSize(width: 0, height: 720, maxDimension: 1600)
        XCTAssertEqual(empty.width, 0)
        XCTAssertEqual(empty.height, 0)
    }

    func testJPEGRoundTripKeepsDimensions() throws {
        let image = try makeImage(width: 320, height: 200, gray: 0.6)
        let jpeg = try XCTUnwrap(RemoteScreenSnapshotCodec.encodeJPEG(image))
        let decoded = try XCTUnwrap(RemoteScreenSnapshotCodec.decodeImage(jpeg))
        XCTAssertEqual(decoded.width, 320)
        XCTAssertEqual(decoded.height, 200)
    }

    func testThumbnailDecodeIsBoundedByItsLongEdge() throws {
        let image = try makeImage(width: 320, height: 200, gray: 0.6)
        let jpeg = try XCTUnwrap(RemoteScreenSnapshotCodec.encodeJPEG(image))
        let thumbnail = try XCTUnwrap(RemoteScreenSnapshotCodec.decodeImage(jpeg, maxPixelDimension: 80))
        XCTAssertEqual(thumbnail.width, 80)
        XCTAssertEqual(thumbnail.height, 50)
    }

    func testGarbageDoesNotDecode() {
        XCTAssertNil(RemoteScreenSnapshotCodec.decodeImage(Data("nope".utf8)))
    }

    func testABlackFrameIsBlankAndALitOneIsNot() throws {
        XCTAssertTrue(RemoteScreenSnapshotCodec.isBlank(try makeImage(width: 640, height: 400, gray: 0)))
        XCTAssertFalse(RemoteScreenSnapshotCodec.isBlank(try makeImage(width: 640, height: 400, gray: 0.2)))
    }
}
