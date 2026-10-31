import SwiftUI
import XCTest

final class DuoWorkspaceLayoutTests: XCTestCase {
    func testInsetLandscapeCameraReclaimsOppositeEdgeInBothOrientations() {
        let screen = CGRect(x: 0, y: 0, width: 932, height: 430)
        for rightToLeft in [false, true] {
            let left = CGRect(x: 12, y: 100, width: 38, height: 180)
            let right = CGRect(x: 882, y: 100, width: 38, height: 180)
            XCTAssertEqual(DuoLayoutContext.unoccludedLandscapeEdge(
                bounds: screen, occlusions: [left], rightToLeft: rightToLeft
            ), rightToLeft ? .leading : .trailing)
            XCTAssertEqual(DuoLayoutContext.unoccludedLandscapeEdge(
                bounds: screen, occlusions: [right], rightToLeft: rightToLeft
            ), rightToLeft ? .trailing : .leading)
        }
    }

    private let bounds = CGRect(x: 40, y: 70, width: 600, height: 900)
    private let safeFrame = CGRect(x: 56, y: 90, width: 490, height: 846)
    private let camera = CGRect(x: 560, y: 104, width: 44, height: 44)

    private func front(_ mode: DuoFrontDisplayMode, showsTabs: Bool = true) -> DuoLayoutContext {
        DuoLayoutContext(hasHinge: true, isFrontDisplay: true, verticalEdge: .trailing,
                         frontMode: mode, behindCameraShowsTabs: showsTabs)
    }

    func testPersistedModeIdentitiesAreStableAndRejectUnknownValues() {
        XCTAssertEqual(DuoFrontDisplayMode.allCases.map(\.rawValue), ["sideRail", "belowCamera", "behindCamera"])
        for mode in DuoFrontDisplayMode.allCases {
            XCTAssertEqual(DuoFrontDisplayMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(DuoFrontDisplayMode(rawValue: "unknown"))
    }

    func testFrontModeControlsOverrideGlobalTabVisibilityOnlyWhereIntended() {
        XCTAssertTrue(front(.sideRail).usesSideRail)
        XCTAssertFalse(front(.sideRail).usesFullWidth)
        XCTAssertFalse(front(.sideRail).showsHorizontalTabs(globallyHidden: false))
        XCTAssertFalse(front(.sideRail).showsTabsBesideSideRail)
        for hidden in [true, false] {
            XCTAssertTrue(front(.belowCamera).showsHorizontalTabs(globallyHidden: hidden))
            XCTAssertEqual(front(.behindCamera).showsHorizontalTabs(globallyHidden: hidden), !hidden)
            XCTAssertFalse(front(.behindCamera, showsTabs: false).showsHorizontalTabs(globallyHidden: hidden))
        }
        XCTAssertFalse(front(.belowCamera).usesSideRail)
        XCTAssertTrue(front(.behindCamera).usesFullWidth)
    }

    func testUnfoldingStopsApplyingFrontDisplayPreference() {
        for mode in DuoFrontDisplayMode.allCases {
            var context = front(mode, showsTabs: false)
            context.isFrontDisplay = false
            XCTAssertFalse(context.extendsTerminalToVerticalEdges)
            XCTAssertFalse(context.usesFullWidth)
            XCTAssertTrue(context.usesSideRail)
            // The inner display's side rail still honors the global top tab setting.
            XCTAssertTrue(context.showsTabsBesideSideRail)
            XCTAssertTrue(context.showsHorizontalTabs(globallyHidden: false))
            XCTAssertFalse(context.showsHorizontalTabs(globallyHidden: true))
            context.verticalEdge = nil
            XCTAssertFalse(context.showsTabsBesideSideRail)
            XCTAssertTrue(context.showsHorizontalTabs(globallyHidden: false))
            XCTAssertFalse(context.showsHorizontalTabs(globallyHidden: true))
        }
    }

    func testBehindCameraImmersionEndsWhenUnfoldedOrAnotherModeIsSelected() {
        for showsTabs in [false, true] {
            var context = front(.behindCamera, showsTabs: showsTabs)
            XCTAssertTrue(context.requiresImmersiveChrome)
            context.isFrontDisplay = false
            XCTAssertFalse(context.requiresImmersiveChrome)
            context.isFrontDisplay = true
            context.frontMode = .belowCamera
            XCTAssertFalse(context.requiresImmersiveChrome)
            context.frontMode = .sideRail
            XCTAssertFalse(context.requiresImmersiveChrome)
        }
        XCTAssertFalse(DuoLayoutContext().requiresImmersiveChrome)
    }

    func testOnlyFrontSideRailExtendsTerminalToVerticalEdges() {
        XCTAssertTrue(front(.sideRail).extendsTerminalToVerticalEdges)
        XCTAssertFalse(front(.belowCamera).extendsTerminalToVerticalEdges)
        XCTAssertFalse(front(.behindCamera).extendsTerminalToVerticalEdges)
        var unresolved = front(.sideRail)
        unresolved.verticalEdge = nil
        XCTAssertFalse(unresolved.extendsTerminalToVerticalEdges)
        XCTAssertFalse(DuoLayoutContext().extendsTerminalToVerticalEdges)
    }

    func testBelowCameraStartsBelowHeaderAndOcclusionAtFullWidth() {
        for headerHeight: CGFloat in [44, 100] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [camera], divisions: [],
                context: front(.belowCamera), headerHeight: headerHeight
            )
            // Portrait: the header gets its own row beneath the camera.
            let terminalTop = bounds.minY + layout.headerInsets.top + headerHeight + layout.cameraClearance
            XCTAssertEqual(layout.headerInsets.top, camera.maxY - bounds.minY)
            XCTAssertEqual(terminalTop, camera.maxY + headerHeight)
            XCTAssertFalse(layout.headerSharesTopBand)
            XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            XCTAssertEqual(layout.headerInsets.leading, 16)
            XCTAssertEqual(layout.headerInsets.trailing, 94)
        }
    }

    func testBehindCameraDoesNotReserveOcclusionAndHiddenHeaderReachesTop() {
        for headerHeight: CGFloat in [0, 44] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [camera], divisions: [],
                context: front(.behindCamera, showsTabs: headerHeight > 0), headerHeight: headerHeight
            )
            XCTAssertEqual(layout.cameraClearance, 0)
            XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            XCTAssertEqual(layout.headerInsets.top, 0)
        }
    }

    func testBehindCameraWithVisibleStatusBarMatchesFullscreenLayout() {
        let display = CGRect(x: 0, y: 0, width: 466, height: 644)
        let camera = CGRect(x: 399.6666666666667, y: 29.333333333333332, width: 37, height: 37)
        let systemBar = CGRect(x: 276, y: 0, width: 190, height: 82)
        for height: CGFloat in [0, 44] {
            let context = front(.behindCamera, showsTabs: height > 0)
            XCTAssertEqual(context.workspaceIgnoredEdges(headerHeight: height), [.horizontal, .top])
            let layouts = [CGFloat(0), CGFloat(82)].map { top in
                DuoWorkspaceLayout.resolve(
                    bounds: display,
                    safeFrame: CGRect(x: 0, y: top, width: 466, height: 644 - top),
                    occlusions: [camera, systemBar], divisions: [], context: context,
                    headerHeight: height
                )
            }
            XCTAssertEqual(layouts[0], layouts[1])
            for layout in layouts {
                XCTAssertEqual(layout.headerInsets.top, 0)
                XCTAssertEqual(layout.cameraClearance, 0)
                XCTAssertEqual(layout.terminalInsets, EdgeInsets())
                let terminalTop = layout.headerInsets.top + height + layout.cameraClearance
                XCTAssertEqual(terminalTop, height)
                XCTAssertLessThan(terminalTop, camera.maxY)
                if height > 0 {
                    XCTAssertEqual(layout.headerInsets.trailing, 190)
                }
            }
        }
    }

    func testIgnoringTopInsetRemainsScopedToDuoWorkspaceModes() {
        for height: CGFloat in [0, 44] {
            XCTAssertEqual(DuoLayoutContext().workspaceIgnoredEdges(headerHeight: height), [])
            XCTAssertEqual(front(.sideRail).workspaceIgnoredEdges(headerHeight: height), .vertical)
            XCTAssertEqual(front(.belowCamera).workspaceIgnoredEdges(headerHeight: height), [.horizontal, .top])
        }
        XCTAssertEqual(DuoLayoutContext(hasHinge: true).workspaceIgnoredEdges(headerHeight: 44), .top)
        XCTAssertEqual(DuoLayoutContext(hasHinge: true).workspaceIgnoredEdges(headerHeight: 0), [])
    }

    func testBelowCameraReclaimsTopSafeAreaForTabsAndActions() {
        // Include a nonzero workspace origin and both physical camera edges.
        let display = CGRect(x: 20, y: 30, width: 680, height: 470)
        let safe = CGRect(x: 20, y: 118, width: 680, height: 348)
        for cameraOnLeft in [false, true] {
            let camera = CGRect(x: cameraOnLeft ? 20 : 560, y: 30, width: 140, height: 88)
            for rtl in [false, true] {
                let layout = DuoWorkspaceLayout.resolve(
                    bounds: display, safeFrame: safe, occlusions: [camera], divisions: [],
                    context: front(.belowCamera), headerHeight: 44, rightToLeft: rtl
                )
                let left = rtl ? layout.headerInsets.trailing : layout.headerInsets.leading
                let right = rtl ? layout.headerInsets.leading : layout.headerInsets.trailing
                let header = CGRect(x: display.minX + left, y: display.minY + layout.headerInsets.top,
                                    width: display.width - left - right, height: 44)
                XCTAssertLessThan(header.minY, safe.minY)
                XCTAssertEqual(header.width, 540)
                XCTAssertTrue(layout.headerSharesTopBand)
                XCTAssertFalse(header.intersects(camera))
                XCTAssertEqual(header.maxY, camera.maxY)
                XCTAssertEqual(header.maxY + layout.cameraClearance, camera.maxY)
                XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            }
        }
    }

    func testHeaderAndTerminalBothClearCameraAndStatusRegions() {
        let display = CGRect(x: 0, y: 0, width: 680, height: 470)
        let safe = CGRect(x: 0, y: 88, width: 680, height: 348)
        let camera = CGRect(x: 620, y: 20, width: 60, height: 60)
        let reservedStatus = CGRect(x: 500, y: 24, width: 120, height: 64)
        let layout = DuoWorkspaceLayout.resolve(
            bounds: display, safeFrame: safe, occlusions: [camera, reservedStatus], divisions: [],
            context: front(.belowCamera), headerHeight: 44
        )
        XCTAssertEqual(layout.headerInsets.top + 44, reservedStatus.maxY)
        XCTAssertEqual(layout.headerInsets.trailing, 180)
        // The normal-height tab ends at the full-width terminal boundary.
        XCTAssertEqual(layout.cameraClearance, 0)
        XCTAssertEqual(layout.headerInsets.top + 44 + layout.cameraClearance, 88)
        XCTAssertEqual(layout.terminalInsets, EdgeInsets())
    }

    func testMeasuredDuoPortraitStacksHeaderBelowSystemBar() {
        // Captured from the Duo simulator with Below Camera selected.
        let display = CGRect(x: 0, y: 0, width: 466, height: 644)
        let safe = CGRect(x: 0, y: 82, width: 466, height: 562)
        let camera = CGRect(x: 399.6666666666667, y: 29.333333333333332, width: 37, height: 37)
        let systemBar = CGRect(x: 276, y: 0, width: 190, height: 82)
        // The visible platter can hang below the camera's row.
        let platter = CGRect(x: 282, y: 6, width: 178, height: 66)
        for rtl in [false, true] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: display, safeFrame: safe, occlusions: [camera, systemBar], divisions: [],
                context: front(.belowCamera), headerHeight: 44, rightToLeft: rtl,
                occlusionContentFrames: [camera, platter]
            )
            XCTAssertEqual(layout.headerInsets.top, platter.maxY)
            XCTAssertEqual(layout.headerInsets.leading, 0)
            XCTAssertEqual(layout.headerInsets.trailing, 0)
            XCTAssertEqual(layout.cameraClearance, 0)
            XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            XCTAssertFalse(layout.headerSharesTopBand)
        }
    }

    func testLandscapeCameraAlignsNormalHeaderInsideHorizontalSystemBar() {
        // The measured portrait regions, rotated onto a landscape display. The
        // legacy statusBarFrame is only 2 points high and is not an anchor.
        let display = CGRect(x: 0, y: 0, width: 644, height: 466)
        let safe = CGRect(x: 0, y: 82, width: 644, height: 384)
        let camera = CGRect(x: 577.6666666666667, y: 29.333333333333332, width: 37, height: 37)
        let systemBar = CGRect(x: 454, y: 0, width: 190, height: 82)
        for regions in [[camera, systemBar], [systemBar, camera]] {
            for rtl in [false, true] {
                let layout = DuoWorkspaceLayout.resolve(
                    bounds: display, safeFrame: safe, occlusions: regions, divisions: [],
                    context: front(.belowCamera), headerHeight: 44, rightToLeft: rtl
                )
                XCTAssertEqual(layout.headerInsets.top + 22, camera.midY, accuracy: 0.001)
                XCTAssertEqual(layout.headerInsets.top, 25.833333333333332, accuracy: 0.001)
                XCTAssertEqual(rtl ? layout.headerInsets.leading : layout.headerInsets.trailing, 190)
                let terminalTop = layout.headerInsets.top + 44 + layout.cameraClearance
                XCTAssertEqual(terminalTop, 69.83333333333333, accuracy: 0.001)
                XCTAssertGreaterThan(terminalTop, camera.maxY)
                XCTAssertEqual(layout.cameraClearance, 0) // integrated tab meets terminal
                XCTAssertTrue(layout.headerSharesTopBand)
            }
        }
    }

    func testMeasuredDuoVerticalRailIsStillClearedDuringToolbarTransition() {
        let display = CGRect(x: 0, y: 0, width: 466, height: 644)
        let camera = CGRect(x: 399.6666666666667, y: 29.333333333333332, width: 37, height: 37)
        let rail = CGRect(x: 382, y: 0, width: 84, height: 170)
        for safe in [CGRect(x: 0, y: 24, width: 382, height: 620),
                     CGRect(x: 0, y: 82, width: 382, height: 562),
                     CGRect(x: 0, y: 82, width: 466, height: 562)] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: display, safeFrame: safe, occlusions: [camera, rail], divisions: [],
                context: front(.belowCamera), headerHeight: 44
            )
            XCTAssertEqual(layout.headerInsets.top, rail.maxY)
            XCTAssertEqual(layout.headerInsets.trailing, display.maxX - safe.maxX)
            XCTAssertEqual(layout.cameraClearance, 0)
        }
    }

    func testUnfoldedHeaderSharesStatusBandForEveryFrontDisplayPreference() {
        // The inner display has room beside the status band in either orientation.
        for portrait in [false, true] {
            let width: CGFloat = portrait ? 680 : 960
            let display = CGRect(x: 0, y: 0, width: width, height: portrait ? 960 : 680)
            let safe = CGRect(x: 0, y: 88, width: width, height: display.height - 122)
            let reserved = CGRect(x: width - 130, y: 20, width: 130, height: 68)
            for mode in DuoFrontDisplayMode.allCases {
                let context = DuoLayoutContext(hasHinge: true, frontMode: mode)
                XCTAssertTrue(context.placesHeaderBesideTopRegions)
                let layout = DuoWorkspaceLayout.resolve(
                    bounds: display, safeFrame: safe, occlusions: [reserved], divisions: [],
                    context: context, headerHeight: 44
                )
                XCTAssertEqual(layout.headerInsets.top + 44, reserved.maxY)
                XCTAssertEqual(layout.headerInsets.trailing, 130)
                XCTAssertEqual(layout.headerInsets.top + 44 + layout.cameraClearance, reserved.maxY)
                XCTAssertTrue(layout.headerSharesTopBand)
            }
        }
        XCTAssertFalse(front(.sideRail).placesHeaderBesideTopRegions)
        XCTAssertFalse(front(.behindCamera).placesHeaderBesideTopRegions)
        XCTAssertFalse(DuoLayoutContext().placesHeaderBesideTopRegions)
        XCTAssertFalse(DuoLayoutContext(hasHinge: true, verticalEdge: .trailing).placesHeaderBesideTopRegions)
    }

    func testIntegratedHeaderEndsBelowVisibleRegionsWithoutAddingTouchMargins() {
        let display = CGRect(x: 0, y: 0, width: 680, height: 470)
        let safe = CGRect(x: 0, y: 88, width: 680, height: 348)
        let padded = CGRect(x: 490, y: 0, width: 190, height: 88)
        let visible = CGRect(x: 504, y: 28, width: 166, height: 40)
        for context in [front(.belowCamera), DuoLayoutContext(hasHinge: true)] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: display, safeFrame: safe, occlusions: [padded], divisions: [],
                context: context, headerHeight: 44,
                occlusionContentFrames: [visible]
            )
            XCTAssertEqual(layout.headerInsets.top + 44, visible.maxY)
            XCTAssertEqual(layout.headerInsets.trailing, 190)
            XCTAssertEqual(layout.headerInsets.top + 44 + layout.cameraClearance, 68)
            XCTAssertEqual(layout.cameraClearance, 0)
        }
    }

    func testHeaderHiddenOrTallerThanCameraStillKeepsTerminalBelowOcclusion() {
        for portrait in [false, true] {
            let display = CGRect(x: 0, y: 0, width: portrait ? 600 : 900, height: portrait ? 900 : 600)
            let region = CGRect(x: display.maxX - 80, y: 0, width: 80, height: 84)
            for height: CGFloat in [0, 44, 120] {
                let layout = DuoWorkspaceLayout.resolve(
                    bounds: display, safeFrame: display, occlusions: [region], divisions: [],
                    context: front(.belowCamera), headerHeight: height
                )
                let terminalTop = layout.headerInsets.top + height + layout.cameraClearance
                let expected = portrait && height > 0 ? region.maxY + height : max(height, region.maxY)
                XCTAssertEqual(terminalTop, expected)
                if height > 0 {
                    XCTAssertEqual(layout.cameraClearance, 0)
                    XCTAssertEqual(layout.headerInsets.top + height, terminalTop)
                }
            }
        }
    }

    func testFullWidthTerminalDoesNotPullHeaderButtonsIntoCameraColumn() {
        // Vertical bars are disabled: the ordinary safe frame can span the
        // full width even though the header still needs camera clearance.
        let display = CGRect(x: 0, y: 0, width: 900, height: 600)
        for mode in [DuoFrontDisplayMode.belowCamera, .behindCamera] {
            for cameraOnLeft in [false, true] {
                let region = CGRect(x: cameraOnLeft ? 0 : 820, y: 48, width: 80, height: 60)
                for rtl in [false, true] {
                    let layout = DuoWorkspaceLayout.resolve(
                        bounds: display, safeFrame: display, occlusions: [region], divisions: [],
                        context: front(mode), headerHeight: 44, rightToLeft: rtl
                    )
                    let left = rtl ? layout.headerInsets.trailing : layout.headerInsets.leading
                    let right = rtl ? layout.headerInsets.leading : layout.headerInsets.trailing
                    if cameraOnLeft {
                        XCTAssertEqual(left, region.maxX)
                        XCTAssertEqual(right, 0)
                    } else {
                        XCTAssertEqual(left, 0)
                        XCTAssertEqual(display.maxX - right, region.minX)
                    }
                    XCTAssertEqual(layout.terminalInsets, EdgeInsets())
                    XCTAssertEqual(layout.cameraClearance, 0)
                }
            }
        }
    }

    func testMissingOrUnusableCameraGeometryKeepsAsymmetricSafeWidth() {
        for regions: [CGRect] in [[], [.null], [.zero], [CGRect(x: 800, y: 0, width: 50, height: 50)],
                                  [CGRect(x: 560, y: 900, width: 44, height: 44)]] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: regions, divisions: [],
                context: front(.belowCamera), headerHeight: 44
            )
            XCTAssertEqual(layout.cameraClearance, 0)
            XCTAssertEqual(layout.terminalInsets.leading, 16)
            XCTAssertEqual(layout.terminalInsets.trailing, 94)
        }
    }

    func testRTLMapsPhysicalAsymmetricInsetsWithoutChangingCameraClearance() {
        let ltr = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [],
            context: front(.belowCamera), headerHeight: 44
        )
        let rtl = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [],
            context: front(.belowCamera), headerHeight: 44, rightToLeft: true
        )
        XCTAssertEqual(rtl.headerInsets.leading, ltr.headerInsets.trailing)
        XCTAssertEqual(rtl.headerInsets.trailing, ltr.headerInsets.leading)
        XCTAssertEqual(rtl.terminalInsets.leading, ltr.terminalInsets.trailing)
        XCTAssertEqual(rtl.terminalInsets.trailing, ltr.terminalInsets.leading)
        XCTAssertEqual(rtl.cameraClearance, ltr.cameraClearance)
    }

    func testTabletopKeepsTerminalAboveDivisionAndInputInsideSafeLowerRegion() {
        let division = CGRect(x: 40, y: 500, width: 600, height: 20)
        let layout = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [division],
            context: DuoLayoutContext(hasHinge: true), headerHeight: 44
        )
        XCTAssertTrue(layout.tabletopAvailable)
        XCTAssertEqual(layout.fold, division)
        XCTAssertEqual(bounds.maxY - layout.lowerReservation, division.minY)
        XCTAssertEqual(layout.inputRegion, CGRect(x: 56, y: 520, width: 490, height: 416))
    }

    func testTabletopOverrideKeepsToggleAvailableWithoutReservingSpace() {
        let division = CGRect(x: 40, y: 500, width: 600, height: 20)
        var context = DuoLayoutContext(hasHinge: true)
        context.tabletopDisabled = true
        let layout = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [division],
            context: context, headerHeight: 44
        )
        XCTAssertTrue(layout.tabletopAvailable)
        // The keyboard still rests below the fold without a reservation.
        XCTAssertEqual(layout.fold, division)
        XCTAssertEqual(layout.lowerReservation, 0)
        XCTAssertNil(layout.inputRegion)
    }

    func testTabletopPoseExitClearsAvailabilityAndAllReservations() {
        let horizontal = CGRect(x: 40, y: 500, width: 600, height: 20)
        let context = DuoLayoutContext(hasHinge: true)
        let scenarios: [(DuoLayoutContext, [CGRect])] = [
            (context, []),
            (context, [CGRect(x: 320, y: 70, width: 20, height: 900)]),
            (context, [CGRect(x: 40, y: 150, width: 600, height: 20)]),
            (context, [CGRect(x: 40, y: 800, width: 600, height: 20)]),
            (context, [CGRect(x: 100, y: 500, width: 500, height: 20)]),
            (front(.sideRail), [horizontal]),
            (DuoLayoutContext(), [horizontal]),
        ]
        for (context, divisions) in scenarios {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: divisions,
                context: context, headerHeight: 44
            )
            XCTAssertFalse(layout.tabletopAvailable)
            XCTAssertEqual(layout.lowerReservation, 0)
            XCTAssertNil(layout.inputRegion)
        }
    }

    func testHeaderTopLimitRaisesHeaderOnlyAboveTheSafeArea() {
        let island = CGRect(x: 0, y: 0, width: 402, height: 874)
        let islandSafe = CGRect(x: 0, y: 62, width: 402, height: 778)
        func headerTop(limit: CGFloat?, headerHeight: CGFloat = 44) -> CGFloat {
            DuoWorkspaceLayout.resolve(
                bounds: island, safeFrame: islandSafe, occlusions: [], divisions: [],
                context: DuoLayoutContext(), headerHeight: headerHeight, headerTopLimit: limit
            ).headerInsets.top
        }
        XCTAssertEqual(headerTop(limit: nil), 62)
        XCTAssertEqual(headerTop(limit: 54), 54)
        XCTAssertEqual(headerTop(limit: 70), 62)
        XCTAssertEqual(headerTop(limit: 54, headerHeight: 0), 0)
    }

    func testZeroSizeDuringDisplayHandoffProducesNoReservations() {
        XCTAssertEqual(DuoWorkspaceLayout.resolve(
            bounds: .zero, safeFrame: .zero, occlusions: [camera], divisions: [],
            context: front(.belowCamera), headerHeight: 44
        ), DuoWorkspaceLayout())
    }
}
