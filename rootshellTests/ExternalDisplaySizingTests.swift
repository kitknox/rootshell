import CoreGraphics
import XCTest

final class ExternalDisplaySizingTests: XCTestCase {
    func testMonitorUnderTheCeilingIsRequestedAsIs() {
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(
                for: CGSize(width: 1920, height: 1080), scaleFactor: 1),
            CGSize(width: 1920, height: 1080))
    }

    func testMonitorAboveTheCeilingIsFittedUnderIt() {
        // 2560x1440 at 2x would be 5120x2880 pixels; Match Client's 60 fps tier
        // stops at 3840x2160, i.e. 1920x1080 points.
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(
                for: CGSize(width: 2560, height: 1440), scaleFactor: 1),
            CGSize(width: 1920, height: 1080))
    }

    func testEveryScaleStepChangesTheSizeAboveTheCeiling() {
        // Dividing the raw 2560x1440 by 1.25 would still be capped back to
        // 1920x1080; scaling after the cap keeps each step distinct.
        let screen = CGSize(width: 2560, height: 1440)
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(for: screen, scaleFactor: 1.25),
            CGSize(width: 1536, height: 864))
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(for: screen, scaleFactor: 1.5),
            CGSize(width: 1280, height: 720))
    }

    func testAspectRatioIsPreserved() {
        let size = ExternalDisplaySizing.requestedSize(
            for: CGSize(width: 3440, height: 1440), scaleFactor: 1)
        XCTAssertEqual(size.width / size.height, 3440 / 1440, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            size.width * size.height,
            ExternalDisplaySizing.maximumPointArea + size.width + size.height)
    }

    func testDegenerateInputIsReturnedUnchanged() {
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(for: .zero, scaleFactor: 1),
            .zero)
        XCTAssertEqual(
            ExternalDisplaySizing.requestedSize(
                for: CGSize(width: 1920, height: 1080), scaleFactor: 0),
            CGSize(width: 1920, height: 1080))
    }
}
