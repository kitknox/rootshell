import XCTest

final class TerminalScrollbarAvailabilityTests: XCTestCase {
    func testTmuxControlPanePreservesDocumentWhileSurfaceIsUnavailable() {
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: false,
            hasValidSample: true
        ))
        // Layout resizes while the tmux viewer surface is temporarily absent
        // must reuse the cached sample rather than collapsing to the viewport.
        var cached: (total: UInt64, offset: UInt64, len: UInt64)? = (total: 300, offset: 120, len: 40)
        let resolved = TerminalScrollbarAvailabilityPolicy.resolveLayoutScrollbar(
            liveSample: nil,
            cachedSample: &cached,
            isTmuxPane: true,
            hasSurface: false
        )
        XCTAssertEqual(resolved?.total, 300)
        XCTAssertEqual(resolved?.offset, 120)
        XCTAssertEqual(resolved?.len, 40)
        XCTAssertNotNil(cached)

        // Once the surface exists, a nil live sample means empty history:
        // it must clear `cached` so a subsequent surface teardown cannot
        // resurrect obsolete scrollback on the next resize.
        XCTAssertNil(TerminalScrollbarAvailabilityPolicy.resolveLayoutScrollbar(
            liveSample: nil,
            cachedSample: &cached,
            isTmuxPane: true,
            hasSurface: true
        ))
        XCTAssertNil(cached)
        XCTAssertNil(TerminalScrollbarAvailabilityPolicy.resolveLayoutScrollbar(
            liveSample: nil,
            cachedSample: &cached,
            isTmuxPane: true,
            hasSurface: false
        ))

        // Non-tmux panes never substitute or retain a stale sample when live is nil.
        var ordinaryCached: (total: UInt64, offset: UInt64, len: UInt64)? = (total: 300, offset: 120, len: 40)
        XCTAssertNil(TerminalScrollbarAvailabilityPolicy.resolveLayoutScrollbar(
            liveSample: nil,
            cachedSample: &ordinaryCached,
            isTmuxPane: false,
            hasSurface: false
        ))
        XCTAssertNil(ordinaryCached)
    }

    func testScaleChangeRestoresParkedRowAndFractionalCellOffset() {
        // Parked at row 100 + 8px smooth offset (cellHeight = 32px -> 3208px model offset).
        // Under 2x scale, priorOffset.y was 1604pt; moving to 1x must map 3208px -> 3208pt
        // (row 100 + 8px), rather than keeping 1604pt (which would jump to row 50).
        let modelOffsetY = TerminalScrollbarAvailabilityPolicy.scaleAdjustedParkedModelOffsetY(
            scrollbar: (total: 300, offset: 100, len: 40),
            cellHeight: 32,
            preservedSmoothOffset: 8
        )
        XCTAssertEqual(modelOffsetY, 3208, accuracy: 0.001)
        XCTAssertEqual(modelOffsetY / 2, 1604, accuracy: 0.001)
        XCTAssertEqual(modelOffsetY / 1, 3208, accuracy: 0.001)
        XCTAssertEqual(Int((modelOffsetY / 3) * 3 / 32), 100)

        // At or past bottomRow, fractional smooth offset is clamped out.
        let atBottom = TerminalScrollbarAvailabilityPolicy.scaleAdjustedParkedModelOffsetY(
            scrollbar: (total: 300, offset: 280, len: 40),
            cellHeight: 32,
            preservedSmoothOffset: 12
        )
        XCTAssertEqual(atBottom, CGFloat(260 * 32), accuracy: 0.001)
    }

    func testTmuxPaneResetsWhenExistingSurfaceReportsNoScrollback() {
        // The displayed-scrollbar query returns false when total <= len,
        // including after a resize consumes the remaining history.
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: true,
            hasValidSample: true
        ))
    }

    func testFreshTmuxPaneStillUsesResetPath() {
        for hasSurface in [false, true] {
            XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                isTmuxPane: true,
                hasSurface: hasSurface,
                hasValidSample: false
            ))
        }
    }

    func testOrdinaryTerminalStillUsesResetPath() {
        for hasSurface in [false, true] {
            for hasValidSample in [false, true] {
                XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                    isTmuxPane: false,
                    hasSurface: hasSurface,
                    hasValidSample: hasValidSample
                ))
            }
        }
    }

    func testDocumentHeightMatchesViewportWhenScrollbackOrCellMetricsMissing() {
        XCTAssertEqual(TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 0, cellHeight: 32, scale: 2, scrollbar: (total: 200, len: 40)
        ), 0)
        // Missing scrollbar, empty history (total <= len), or missing cellSize
        // must never expose a phantom scrollable range above viewportHeight.
        XCTAssertEqual(TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 720, cellHeight: 32, scale: 3, scrollbar: nil
        ), 720)
        XCTAssertEqual(TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 720, cellHeight: 32, scale: 3, scrollbar: (total: 40, len: 40)
        ), 720)
        XCTAssertEqual(TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 720, cellHeight: 0, scale: 3, scrollbar: (total: 200, len: 40)
        ), 720)
    }

    func testDocumentHeightTracksViewportResizeAndDisplayScale() {
        // 100 scrollback rows * 30px/row = 3000 framebuffer pixels = 1000pt at 3x.
        let beforeKeyboard = TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 800, cellHeight: 30, scale: 3, scrollbar: (total: 140, len: 40)
        )
        let afterKeyboard = TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 450, cellHeight: 30, scale: 3, scrollbar: (total: 140, len: 40)
        )
        XCTAssertEqual(beforeKeyboard - 800, 1000, accuracy: 0.001)
        XCTAssertEqual(afterKeyboard - 450, 1000, accuracy: 0.001)

        // Zero scrollback on a resized or foreign-owned Herdr pane shrinks
        // cleanly with the viewport instead of leaving a 350pt phantom range.
        let shrunkZeroHistory = TerminalScrollbarAvailabilityPolicy.documentHeight(
            viewportHeight: 450, cellHeight: 30, scale: 3, scrollbar: (total: 40, len: 40)
        )
        XCTAssertEqual(shrunkZeroHistory, 450)
    }

    func testResolvedLiveScrollbarClearsStaleHistoryOnAlternateScreenAndEmptyPrimary() {
        // Alternate screen always reports zero scrollback even if primary has history.
        let alt = TerminalScrollbarAvailabilityPolicy.resolvedLiveScrollbar(
            isAlternateScreen: true,
            displayScrollbar: (total: 540, offset: 500, len: 40),
            surfaceRows: 40
        )
        XCTAssertEqual(alt?.total, 40)
        XCTAssertEqual(alt?.offset, 0)
        XCTAssertEqual(alt?.len, 40)

        // Primary screen after a snapshot/clear that emptied scrollback resets to rows.
        let emptyPrimary = TerminalScrollbarAvailabilityPolicy.resolvedLiveScrollbar(
            isAlternateScreen: false,
            displayScrollbar: nil,
            surfaceRows: 36
        )
        XCTAssertEqual(emptyPrimary?.total, 36)
        XCTAssertEqual(emptyPrimary?.offset, 0)
        XCTAssertEqual(emptyPrimary?.len, 36)

        // Primary screen with active scrollback preserves exact sample.
        let scrolled = TerminalScrollbarAvailabilityPolicy.resolvedLiveScrollbar(
            isAlternateScreen: false,
            displayScrollbar: (total: 540, offset: 210, len: 40),
            surfaceRows: 40
        )
        XCTAssertEqual(scrolled?.total, 540)
        XCTAssertEqual(scrolled?.offset, 210)
        XCTAssertEqual(scrolled?.len, 40)

        XCTAssertNil(TerminalScrollbarAvailabilityPolicy.resolvedLiveScrollbar(
            isAlternateScreen: false,
            displayScrollbar: nil,
            surfaceRows: 0
        ))
    }

    func testMoshAllowsMultiplexerScrollTrackingWithoutAlternateScreenFlag() {
        // Direct Mosh never sets Ghostty's alternate-screen flag even while
        // tmux/zellij renders copy mode, so reveal must not reset tracking.
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.allowsMultiplexerScrollTrackingOnScreen(
            isMosh: true,
            isSurfaceAlternateActive: false
        ))
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.allowsMultiplexerScrollTrackingOnScreen(
            isMosh: false,
            isSurfaceAlternateActive: true
        ))
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.allowsMultiplexerScrollTrackingOnScreen(
            isMosh: false,
            isSurfaceAlternateActive: false
        ))
    }

    func testScrollCallbackPolicyIgnoresLayoutClampsButAllowsCatalystWheelAndScrollbarInput() {
        // Programmatic terminal sync is always ignored.
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.shouldIgnoreProgrammaticOrClampedScroll(
            isApplyingTerminalSync: true,
            isAdjustingLayoutGeometry: false,
            isUserInteracting: true,
            hasPendingHerdrReturnToLive: false,
            isNativeScrollPanActive: true,
            hasRecentDirectScrollInput: true
        ))

        // UIKit clamping contentOffset inside bounds.size/contentSize changes
        // is ignored even when no Herdr return-to-live is pending.
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.shouldIgnoreProgrammaticOrClampedScroll(
            isApplyingTerminalSync: false,
            isAdjustingLayoutGeometry: true,
            isUserInteracting: false,
            hasPendingHerdrReturnToLive: false,
            isNativeScrollPanActive: false,
            hasRecentDirectScrollInput: false
        ))

        // Unattributed offset nudges while a Herdr return-to-live is pending stay ignored.
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.shouldIgnoreProgrammaticOrClampedScroll(
            isApplyingTerminalSync: false,
            isAdjustingLayoutGeometry: false,
            isUserInteracting: false,
            hasPendingHerdrReturnToLive: true,
            isNativeScrollPanActive: false,
            hasRecentDirectScrollInput: false
        ))

        // Genuine Catalyst wheel, trackpad, or scrollbar-gutter input must NOT be
        // swallowed by a pending Herdr return-to-live even when pan/dragging are false.
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.shouldIgnoreProgrammaticOrClampedScroll(
            isApplyingTerminalSync: false,
            isAdjustingLayoutGeometry: false,
            isUserInteracting: false,
            hasPendingHerdrReturnToLive: true,
            isNativeScrollPanActive: false,
            hasRecentDirectScrollInput: true
        ))
    }

    func testNonDragScrollPromotesToLiveOnlyForDirectInputOutsideLayoutClamps() {
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.shouldPromoteNonDragScrollToLive(
            isLiveScrolling: false,
            isAdjustingLayoutGeometry: false,
            hasRecentDirectScrollInput: true,
            isTouchScrollbarDrag: false
        ))
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.shouldPromoteNonDragScrollToLive(
            isLiveScrolling: false,
            isAdjustingLayoutGeometry: false,
            hasRecentDirectScrollInput: false,
            isTouchScrollbarDrag: true
        ))
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.shouldPromoteNonDragScrollToLive(
            isLiveScrolling: false,
            isAdjustingLayoutGeometry: true,
            hasRecentDirectScrollInput: true,
            isTouchScrollbarDrag: true
        ))
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.shouldPromoteNonDragScrollToLive(
            isLiveScrolling: true,
            isAdjustingLayoutGeometry: false,
            hasRecentDirectScrollInput: true,
            isTouchScrollbarDrag: false
        ))
    }
}
