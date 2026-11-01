import SwiftUI

/// Scene-local capabilities, independent of the persisted front-display choice.
struct DuoLayoutContext: Equatable {
    var hasHinge = false
    var isFrontDisplay = false
    var verticalEdge: HorizontalEdge?
    var frontMode: DuoFrontDisplayMode = .sideRail
    var behindCameraShowsTabs = true
    var tabletopDisabled = false

    var usesFullWidth: Bool { isFrontDisplay && frontMode != .sideRail }
    var requiresImmersiveChrome: Bool {
        hasHinge && isFrontDisplay && frontMode == .behindCamera
    }
    var usesSideRail: Bool { verticalEdge != nil && !usesFullWidth }
    /// The inner display has room for top tabs beside its side rail; the rail
    /// keeps the new-tab and settings actions.
    var showsTabsBesideSideRail: Bool { hasHinge && !isFrontDisplay && usesSideRail }
    // The front terminal occupies the column beside the system rail. Its
    // rectangular grid can reach both vertical edges in this mode.
    var extendsTerminalToVerticalEdges: Bool { isFrontDisplay && usesSideRail }
    /// Custom horizontal tabs can share the upper band with system UI on
    /// either display. The side rail and Behind Camera keep their own layout.
    var placesHeaderBesideTopRegions: Bool {
        hasHinge && (isFrontDisplay ? frontMode == .belowCamera : !usesSideRail)
    }

    func workspaceIgnoredEdges(headerHeight: CGFloat) -> Edge.Set {
        if extendsTerminalToVerticalEdges { return .vertical }
        // Both full-width choices own their top inset. Behind Camera must
        // underlap even with visible tabs and a visible system status bar.
        if usesFullWidth { return [.horizontal, .top] }
        if placesHeaderBesideTopRegions && headerHeight > 0 { return .top }
        return []
    }

    func showsHorizontalTabs(globallyHidden: Bool) -> Bool {
        if usesFullWidth {
            return frontMode == .belowCamera || (behindCameraShowsTabs && !globallyHidden)
        }
        return (!usesSideRail || showsTabsBesideSideRail) && !globallyHidden
    }
}

private struct DuoLayoutContextKey: EnvironmentKey {
    static let defaultValue = DuoLayoutContext()
}

private struct TerminalTopSafeEdgeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var duoLayout: DuoLayoutContext {
        get { self[DuoLayoutContextKey.self] }
        set { self[DuoLayoutContextKey.self] = newValue }
    }

    /// Window-space y of the workspace's safe-area top while the terminal
    /// extends under it; 0 otherwise.
    var terminalTopSafeEdge: CGFloat {
        get { self[TerminalTopSafeEdgeKey.self] }
        set { self[TerminalTopSafeEdgeKey.self] = newValue }
    }
}

/// All rectangles use the workspace's local, physical coordinate space.
/// Keeping this calculation separate makes transitions testable without a device.
struct DuoWorkspaceLayout: Equatable {
    var headerInsets: EdgeInsets = .init()
    var terminalInsets: EdgeInsets = .init()
    var cameraClearance: CGFloat = 0
    /// The header sits beside the camera/status regions rather than below them.
    var headerSharesTopBand = false
    var lowerReservation: CGFloat = 0
    var inputRegion: CGRect?
    /// The horizontal fold, reported even while tabletop mode is disabled.
    var fold: CGRect?
    /// Global y of the safe area's top edge. UIKit's window inset can be zero
    /// in landscape while the scene's safe area still clears the corner.
    var safeAreaTop: CGFloat = 0
    var tabletopAvailable: Bool { fold != nil }

    static func resolve(
        bounds: CGRect, safeFrame: CGRect, occlusions: [CGRect], divisions: [CGRect],
        context: DuoLayoutContext, headerHeight: CGFloat, rightToLeft: Bool = false,
        occlusionContentFrames: [CGRect]? = nil, headerTopLimit: CGFloat? = nil
    ) -> Self {
        guard bounds.width > 0, bounds.height > 0 else { return Self() }
        let left = max(0, safeFrame.minX - bounds.minX)
        let right = max(0, bounds.maxX - safeFrame.maxX)
        let top = max(0, safeFrame.minY - bounds.minY)
        let sideInsets = EdgeInsets(
            top: 0, leading: rightToLeft ? right : left,
            bottom: 0, trailing: rightToLeft ? left : right
        )
        var result = Self()
        result.headerInsets = sideInsets
        let underlapsCamera = context.usesFullWidth && context.frontMode == .behindCamera
        // A top limit lets the header rise above the safe area, never below it.
        let headerTop = headerTopLimit.map { min(top, max(0, $0 - bounds.minY)) } ?? top
        result.headerInsets.top = headerHeight > 0 && !underlapsCamera ? headerTop : 0

        let sharesTopBand = context.placesHeaderBesideTopRegions && headerHeight > 0
        let clearsTopRegions = (context.usesFullWidth && context.frontMode == .belowCamera) || sharesTopBand
        // The portrait front display leaves too little width beside the system
        // regions for tabs and buttons, so the header takes a row beneath them.
        let stacksHeader = context.isFrontDisplay && clearsTopRegions && headerHeight > 0
            && bounds.height > bounds.width
        if context.usesFullWidth || sharesTopBand {
            if headerHeight > 0 && !stacksHeader {
                // Disabling the system side bar can remove its horizontal
                // safe inset. The terminal may reclaim that column, but its
                // header must still stop before the camera's reserved region
                // (which already includes the system's interaction margins).
                // Reserve the column even when the camera sits just below the
                // header: otherwise the last button hugs the rounded corner.
                var headerSegments = [safeFrame.minX...safeFrame.maxX]
                for region in occlusions where !region.isEmpty && !region.isNull && region.intersects(bounds) {
                    headerSegments = headerSegments.flatMap { segment -> [ClosedRange<CGFloat>] in
                        guard region.maxX > segment.lowerBound, region.minX < segment.upperBound else {
                            return [segment]
                        }
                        var remaining: [ClosedRange<CGFloat>] = []
                        if region.minX > segment.lowerBound {
                            remaining.append(segment.lowerBound...region.minX)
                        }
                        if region.maxX < segment.upperBound {
                            remaining.append(region.maxX...segment.upperBound)
                        }
                        return remaining
                    }
                }
                if let segment = headerSegments.max(by: {
                    $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound
                }) {
                    let headerLeft = max(0, segment.lowerBound - bounds.minX)
                    let headerRight = max(0, bounds.maxX - segment.upperBound)
                    result.headerInsets.leading = rightToLeft ? headerRight : headerLeft
                    result.headerInsets.trailing = rightToLeft ? headerLeft : headerRight
                }
            }
            if clearsTopRegions {
                let visibleRegions = (occlusionContentFrames ?? occlusions).filter {
                    !$0.isEmpty && !$0.isNull && $0.intersects(bounds)
                }
                let visibleBand = visibleRegions.reduce(CGRect.null) { $0.union($1) }
                if stacksHeader, !visibleBand.isNull, bounds.maxY - visibleBand.maxY >= 120 {
                    // Clear every visible region, including a system bar that
                    // grows below the camera, so none of it covers the terminal.
                    result.headerInsets.top = max(0, visibleBand.maxY - bounds.minY)
                } else if !visibleBand.isNull, bounds.maxY - visibleBand.maxY >= 120 {
                    result.headerSharesTopBand = headerHeight > 0
                    // The header owns the free column beside the camera/status
                    // regions, including the area above the rectangular safe
                    // frame. Only its horizontal insets apply there.
                    let cameraBand = max(0, visibleBand.maxY - bounds.minY)
                    // Keep a normal-height tab joined to the full-width terminal.
                    // Its bottom edge must clear the entire visible reserved band;
                    // statusBarFrame can describe a legacy top strip on Duo.
                    result.headerInsets.top = headerHeight > 0 ? max(0, cameraBand - headerHeight) : 0
                    result.cameraClearance = headerHeight > 0 ? 0 : cameraBand

                    // Duo reports the camera separately, nested inside the
                    // horizontal system bar's interaction envelope. That outer
                    // envelope is useful for horizontal button clearance, but
                    // its bottom isn't the camera/status items' visual baseline.
                    // Keep vertical rails intact while the system changes pose.
                    let alignmentRegions = visibleRegions.filter { region in
                        !(region.width > region.height && visibleRegions.contains {
                            $0 != region && region.contains($0)
                        })
                    }
                    if headerHeight > 0, alignmentRegions.count < visibleRegions.count {
                        let alignmentBand = alignmentRegions.reduce(CGRect.null) { $0.union($1) }
                        // Center the normal-height row on the camera. If a live
                        // region grows taller than the row, clear its bottom.
                        result.headerInsets.top = max(
                            0, alignmentBand.midY - bounds.minY - headerHeight / 2,
                            alignmentBand.maxY - bounds.minY - headerHeight
                        )
                    }
                } else {
                    // Geometry can be absent during a display handoff. Keep the
                    // safe rectangle until the camera region is available.
                    result.terminalInsets = sideInsets
                }
            }
        }

        if context.hasHinge && !context.isFrontDisplay,
           let division = divisions.first(where: {
               $0.width > $0.height && $0.minX <= safeFrame.minX && $0.maxX >= safeFrame.maxX
                   && $0.minY - bounds.minY - headerHeight >= 120
                   && bounds.maxY - $0.maxY >= 216
           }) {
            result.fold = division
            if !context.tabletopDisabled {
                result.lowerReservation = bounds.maxY - division.minY
                result.inputRegion = CGRect(
                    x: safeFrame.minX, y: division.maxY,
                    width: safeFrame.width, height: max(0, safeFrame.maxY - division.maxY)
                )
            }
        }
        return result
    }
}
