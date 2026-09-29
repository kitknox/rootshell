import Foundation
import XCTest

final class TSSHBackgroundOutputRouterTests: XCTestCase {
    func testForegroundOutputIsNeverRoutedOrCounted() {
        let router = TrzszBackgroundOutputRouter()
        XCTAssertEqual(router.route(byteCount: 100, isBackgrounded: false), .foreground)

        router.setWriteThroughEnabled(false)
        XCTAssertEqual(router.route(byteCount: 100, isBackgrounded: false), .foreground)
        XCTAssertEqual(router.takeWrittenThroughBytes(), 0)
    }

    func testBackgroundedOutputWritesThroughByDefault() {
        let router = TrzszBackgroundOutputRouter()
        XCTAssertTrue(router.isWriteThroughEnabled)
        XCTAssertEqual(router.route(byteCount: 10, isBackgrounded: true), .writeThrough)
    }

    func testBackgroundedOutputIsBufferedWhenWriteThroughIsOff() {
        let router = TrzszBackgroundOutputRouter()
        router.setWriteThroughEnabled(false)
        XCTAssertEqual(router.route(byteCount: 10, isBackgrounded: true), .buffer)
        XCTAssertEqual(router.takeWrittenThroughBytes(), 0)
    }

    func testWrittenThroughBytesAccumulateAndAreTakenOnce() {
        let router = TrzszBackgroundOutputRouter()
        _ = router.route(byteCount: 10, isBackgrounded: true)
        _ = router.route(byteCount: 32, isBackgrounded: true)
        _ = router.route(byteCount: 500, isBackgrounded: false)

        XCTAssertEqual(router.takeWrittenThroughBytes(), 42)
        XCTAssertEqual(router.takeWrittenThroughBytes(), 0)
    }

    func testTogglingWriteThroughKeepsUnsettledBytes() {
        let router = TrzszBackgroundOutputRouter()
        _ = router.route(byteCount: 7, isBackgrounded: true)
        router.setWriteThroughEnabled(false)
        XCTAssertEqual(router.route(byteCount: 9, isBackgrounded: true), .buffer)
        router.setWriteThroughEnabled(true)
        XCTAssertEqual(router.route(byteCount: 3, isBackgrounded: true), .writeThrough)

        XCTAssertEqual(router.takeWrittenThroughBytes(), 10)
    }

    func testConcurrentRoutingCountsEveryByte() {
        let router = TrzszBackgroundOutputRouter()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            _ = router.route(byteCount: 3, isBackgrounded: true)
        }
        XCTAssertEqual(router.takeWrittenThroughBytes(), 3_000)
    }
}

final class TSSHControlGatewayPolicyTests: XCTestCase {
    func testLiveGatewayIsExpectedWhateverElseIsTrue() {
        for hasEnded in [false, true] {
            for wasResumed in [false, true] {
                for autoStarts in [false, true] {
                    XCTAssertTrue(TrzszControlGatewayPolicy.expectsGateway(
                        isLive: true, hasEnded: hasEnded,
                        wasResumed: wasResumed, autoStartsControlMode: autoStarts))
                }
            }
        }
    }

    func testAutoStartIsExpectedOnAFreshConnect() {
        XCTAssertTrue(TrzszControlGatewayPolicy.expectsGateway(
            isLive: false, hasEnded: false, wasResumed: false, autoStartsControlMode: true))
    }

    func testPlainSessionExpectsNoGateway() {
        XCTAssertFalse(TrzszControlGatewayPolicy.expectsGateway(
            isLive: false, hasEnded: false, wasResumed: false, autoStartsControlMode: false))
    }

    func testAutoStartIsIgnoredOnceTheGatewayEnded() {
        XCTAssertFalse(TrzszControlGatewayPolicy.expectsGateway(
            isLive: false, hasEnded: true, wasResumed: false, autoStartsControlMode: true))
    }

    func testAutoStartIsIgnoredForAResumedSession() {
        XCTAssertFalse(TrzszControlGatewayPolicy.expectsGateway(
            isLive: false, hasEnded: false, wasResumed: true, autoStartsControlMode: true))
    }
}

final class TSSHResumeRedrawPolicyTests: XCTestCase {
    func testFullScreenAppIsRedrawn() {
        XCTAssertTrue(TrzszResumeRedrawPolicy.shouldRedraw(
            isRunning: true, expectsControlGateway: false, isAlternateScreen: true))
    }

    func testPrimaryScreenIsNotRedrawnSoScrollbackIsKept() {
        XCTAssertFalse(TrzszResumeRedrawPolicy.shouldRedraw(
            isRunning: true, expectsControlGateway: false, isAlternateScreen: false))
    }

    func testUnreadableScreenStateSkipsTheRedraw() {
        XCTAssertFalse(TrzszResumeRedrawPolicy.shouldRedraw(
            isRunning: true, expectsControlGateway: false, isAlternateScreen: nil))
    }

    func testControlGatewayIsNeverRedrawn() {
        XCTAssertFalse(TrzszResumeRedrawPolicy.shouldRedraw(
            isRunning: true, expectsControlGateway: true, isAlternateScreen: true))
    }

    func testStoppedSessionIsNeverRedrawn() {
        XCTAssertFalse(TrzszResumeRedrawPolicy.shouldRedraw(
            isRunning: false, expectsControlGateway: false, isAlternateScreen: true))
    }
}
