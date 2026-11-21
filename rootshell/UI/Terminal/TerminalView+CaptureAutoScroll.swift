//
//  TerminalView+CaptureAutoScroll.swift
//  rootshell
//
//  Synthesized edge auto-scroll for captured mouse drags.
//

import UIKit
import GhosttyKit
import ObjectiveC

extension Ghostty.TerminalView {
    private enum CaptureAutoScrollDirection: Int {
        case none = 0
        case up = 1
        case down = -1
    }

    private struct CaptureAutoScrollGeometry {
        let gridLeft: CGFloat
        let gridRight: CGFloat
        let gridTop: CGFloat
        let gridBottom: CGFloat
        let cellHeightPoints: CGFloat
    }

    private enum CaptureAutoScrollConstants {
        static let minimumEdgeBand: CGFloat = 10
        static let edgeBandCellMultiplier: CGFloat = 0.6
        static let pinnedRowsInsideEdge: CGFloat = 2.5
        static let minimumWheelReportsPerSecond: CGFloat = 2
        static let maximumWheelReportsPerSecond: CGFloat = 10
        static let fullSpeedOvershoot: CGFloat = 100
        /// Less room than this (a minimum touch target) past a touch selection's
        /// edge row is too little to drag into.
        static let touchSelectionComfortableReach: CGFloat = 44
        /// A finger's reported location can't get within ~16pt of a physical
        /// screen edge (measured on Duo's outer display with a case), so a band
        /// against one reaches this far from it.
        static let touchSelectionScreenEdgeBand: CGFloat = 24
    }

    private static var captureAutoScrollDirectionKey: UInt8 = 0
    private static var captureAutoScrollOvershootKey: UInt8 = 0
    private static var captureAutoScrollDisplayLinkKey: UInt8 = 0
    private static var captureAutoScrollPinnedPositionKey: UInt8 = 0
    private static var captureAutoScrollEdgeDragPositionKey: UInt8 = 0
    private static var touchSelectionLastLocationKey: UInt8 = 0

    /// Raw finger location of the last touch selection press or drag sample.
    private var touchSelectionLastLocation: CGPoint? {
        get { (objc_getAssociatedObject(self, &Self.touchSelectionLastLocationKey) as? NSValue)?.cgPointValue }
        set {
            objc_setAssociatedObject(
                self,
                &Self.touchSelectionLastLocationKey,
                newValue.map { NSValue(cgPoint: $0) },
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private var captureAutoScrollDirection: CaptureAutoScrollDirection {
        get {
            let rawValue = (objc_getAssociatedObject(self, &Self.captureAutoScrollDirectionKey) as? Int)
                ?? CaptureAutoScrollDirection.none.rawValue
            return CaptureAutoScrollDirection(rawValue: rawValue) ?? .none
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.captureAutoScrollDirectionKey,
                newValue.rawValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private var captureAutoScrollOvershoot: CGFloat {
        get { (objc_getAssociatedObject(self, &Self.captureAutoScrollOvershootKey) as? CGFloat) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.captureAutoScrollOvershootKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var captureAutoScrollDisplayLink: CADisplayLink? {
        get { objc_getAssociatedObject(self, &Self.captureAutoScrollDisplayLinkKey) as? CADisplayLink }
        set { objc_setAssociatedObject(self, &Self.captureAutoScrollDisplayLinkKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var captureAutoScrollPinnedPosition: CGPoint {
        get {
            (objc_getAssociatedObject(self, &Self.captureAutoScrollPinnedPositionKey) as? NSValue)?.cgPointValue
                ?? .zero
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.captureAutoScrollPinnedPositionKey,
                NSValue(cgPoint: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private var captureAutoScrollEdgeDragPosition: CGPoint {
        get {
            (objc_getAssociatedObject(self, &Self.captureAutoScrollEdgeDragPositionKey) as? NSValue)?.cgPointValue
                ?? .zero
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.captureAutoScrollEdgeDragPositionKey,
                NSValue(cgPoint: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    func updateCaptureAutoScroll(at point: CGPoint) {
        guard captureAutoScrollMouseStateAllowsDrag(),
              let surface,
              ghostty_surface_mouse_captured(surface),
              let geometry = captureAutoScrollGeometry()
        else {
            stopCaptureAutoScroll()
            return
        }

        let edgeBand = max(
            CaptureAutoScrollConstants.minimumEdgeBand,
            geometry.cellHeightPoints * CaptureAutoScrollConstants.edgeBandCellMultiplier
        )

        let direction: CaptureAutoScrollDirection
        if point.y <= geometry.gridTop + edgeBand {
            direction = .up
        } else if point.y >= geometry.gridBottom - edgeBand {
            direction = .down
        } else {
            stopCaptureAutoScroll()
            return
        }

        captureAutoScrollDirection = direction
        captureAutoScrollOvershoot = captureAutoScrollSpeedOvershoot(
            for: point,
            direction: direction,
            geometry: geometry,
            edgeBand: edgeBand
        )
        captureAutoScrollPinnedPosition = captureAutoScrollPinnedPosition(
            for: point,
            direction: direction,
            geometry: geometry
        )
        captureAutoScrollEdgeDragPosition = captureAutoScrollEdgeDragPosition(
            for: point,
            direction: direction,
            geometry: geometry
        )
        startCaptureAutoScrollIfNeeded()
    }

    func stopCaptureAutoScroll() {
        captureAutoScrollDisplayLink?.invalidate()
        captureAutoScrollDisplayLink = nil
        captureAutoScrollDirection = .none
        captureAutoScrollOvershoot = 0
        captureAutoScrollPinnedPosition = .zero
        captureAutoScrollEdgeDragPosition = .zero
    }

    /// Records the raw location a touch selection pressed at.
    func noteTouchSelectionPress(at point: CGPoint) {
        touchSelectionLastLocation = point
    }

    /// Where a touch selection drag sample reports to the core. The core scrolls
    /// up only at the surface's top pixel and down only past the grid bottom.
    /// Under the status bar (worse past a case lip) or above the home-indicator
    /// strip there is too little room to get there, so the edge row's band
    /// stands in for it.
    func touchSelectionDragPoint(for point: CGPoint) -> CGPoint {
        touchSelectionLastLocation = point
        guard let window, let geometry = captureAutoScrollGeometry() else { return point }
        let edgeBand = max(
            CaptureAutoScrollConstants.minimumEdgeBand,
            geometry.cellHeightPoints * CaptureAutoScrollConstants.edgeBandCellMultiplier
        )
        let comfortableReach = max(
            CaptureAutoScrollConstants.touchSelectionComfortableReach,
            geometry.cellHeightPoints
        )

        let screenEdges = touchSelectionScreenEdges(of: window)
        let topEdgeBand = screenEdges.top
            ? max(edgeBand, CaptureAutoScrollConstants.touchSelectionScreenEdgeBand)
            : edgeBand
        let bottomEdgeBand = screenEdges.bottom
            ? max(edgeBand, CaptureAutoScrollConstants.touchSelectionScreenEdgeBand)
            : edgeBand

        let windowSafeTop = CGPoint(x: 0, y: window.bounds.minY + window.safeAreaInsets.top)
        let reachableTop = convert(windowSafeTop, from: window).y
        let topBand = geometry.gridTop - reachableTop < comfortableReach
            ? max(geometry.gridTop, reachableTop) + topEdgeBand
            : geometry.gridTop
        if point.y > 0, point.y < topBand {
            return CGPoint(x: point.x, y: -geometry.cellHeightPoints / 2)
        }

        let windowSafeBottom = CGPoint(x: 0, y: window.bounds.maxY - window.safeAreaInsets.bottom)
        let reachableBottom = convert(windowSafeBottom, from: window).y
        guard reachableBottom - geometry.gridBottom < comfortableReach,
              point.y >= min(geometry.gridBottom, reachableBottom) - bottomEdgeBand
        else { return point }
        // Just past the core's trigger (grid bottom - 2pt) but inside the
        // surface, where its smooth-scroll hit test still applies.
        return CGPoint(x: point.x, y: max(point.y, geometry.gridBottom - 1))
    }

    /// Whether the window's top and bottom are bare physical screen edges: no
    /// safe-area inset there, and flush with the screen.
    private func touchSelectionScreenEdges(of window: UIWindow) -> (top: Bool, bottom: Bool) {
        #if os(visionOS)
        return (false, false)
        #else
        guard let screen = window.windowScene?.screen else { return (false, false) }
        let frame = window.convert(window.bounds, to: screen.coordinateSpace)
        let screenBounds = screen.bounds
        return (
            top: window.safeAreaInsets.top == 0 && frame.minY <= screenBounds.minY + 0.5,
            bottom: window.safeAreaInsets.bottom == 0 && frame.maxY >= screenBounds.maxY - 0.5
        )
        #endif
    }

    /// The final position to report before a touch selection release, or nil
    /// when the finger hasn't moved since the last press or sample: a fresh
    /// remap of an unmoved point would move the endpoint on lift.
    func touchSelectionReleasePoint(for point: CGPoint) -> CGPoint? {
        defer { touchSelectionLastLocation = nil }
        guard point != touchSelectionLastLocation else { return nil }
        return touchSelectionDragPoint(for: point)
    }

    private func startCaptureAutoScrollIfNeeded() {
        guard captureAutoScrollDisplayLink == nil else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(captureAutoScrollTick))
        displayLink.add(to: .main, forMode: .common)
        captureAutoScrollDisplayLink = displayLink
    }

    @objc private func captureAutoScrollTick(_ link: CADisplayLink) {
        let frameDuration = link.targetTimestamp - link.timestamp
        guard frameDuration > 0 && frameDuration < 0.5,
              captureAutoScrollDirection != .none,
              captureAutoScrollMouseStateAllowsDrag(),
              window != nil,
              let surface,
              ghostty_surface_mouse_captured(surface),
              let geometry = captureAutoScrollGeometry()
        else {
            stopCaptureAutoScroll()
            return
        }

        let rateProgress = min(
            max(captureAutoScrollOvershoot / CaptureAutoScrollConstants.fullSpeedOvershoot, 0),
            1
        )
        let reportsPerSecond = CaptureAutoScrollConstants.minimumWheelReportsPerSecond
            + (CaptureAutoScrollConstants.maximumWheelReportsPerSecond - CaptureAutoScrollConstants.minimumWheelReportsPerSecond)
            * rateProgress
        let directionSign = CGFloat(captureAutoScrollDirection.rawValue)
        let deltaY = directionSign * reportsPerSecond * geometry.cellHeightPoints * CGFloat(frameDuration)

        sendCaptureAutoScrollTick(deltaY: deltaY)
    }

    private func sendCaptureAutoScrollTick(deltaY: CGFloat) {
        invalidateWritingAssistance()
        if let state = herdrEndpointPane {
            state.scroll(deltaX: 0, deltaY: deltaY, at: captureAutoScrollPinnedPosition)
            state.mouseMove(at: captureAutoScrollEdgeDragPosition)
            return
        }
        guard let surface else { return }
        guard abs(deltaY) > 0.1 else { return }

        let pinnedPoint = viewToPixelCoordinates(captureAutoScrollPinnedPosition)
        let edgePoint = viewToPixelCoordinates(captureAutoScrollEdgeDragPosition)
        let mouseMods = currentMouseMods()
        let scrollMods = Ghostty.Input.ScrollMods(precision: true, momentum: .none).cMods

        // Keep wheel targeting and drag endpoint independent. The wheel lands on
        // the status-safe pinned row; the final mouse move leaves tmux's drag
        // endpoint on the true edge row so the first/last visible line can be
        // selected while auto-scroll is active.
        Self.ghosttyAPIQueue.async {
            ghostty_surface_mouse_pos(surface, pinnedPoint.x, pinnedPoint.y, mouseMods)
            ghostty_surface_mouse_scroll(surface, 0, Double(deltaY), scrollMods)
            ghostty_surface_mouse_pos(surface, edgePoint.x, edgePoint.y, mouseMods)
        }

        lastMousePosition = captureAutoScrollEdgeDragPosition
        multiplexerScrollObserver?.notifyScrollActivity()
    }

    private func captureAutoScrollGeometry() -> CaptureAutoScrollGeometry? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let fallbackScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let scale = contentScaleFactor > 0 ? contentScaleFactor : fallbackScale

        guard let size = surfaceSize,
              size.cell_width_px > 0,
              size.cell_height_px > 0,
              size.columns > 0,
              size.rows > 0,
              scale > 0
        else {
            let fallbackCellHeightPoints: CGFloat = 18
            return CaptureAutoScrollGeometry(
                gridLeft: bounds.minX,
                gridRight: bounds.maxX,
                gridTop: bounds.minY,
                gridBottom: bounds.maxY,
                cellHeightPoints: fallbackCellHeightPoints
            )
        }

        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        let padX = CGFloat(PaddingManager.shared.effectivePaddingX)
        // The core's unshifted top padding: balance is off, so it is the scaled
        // configured padding plus the top inset.
        let padY = HerdrGeometry.padding(PaddingManager.shared.effectivePaddingY, scale: scale) + topInsetPoints
        let gridWidth = CGFloat(size.columns) * cellWidth
        let gridHeight = CGFloat(size.rows) * cellHeight
        let gridLeft = min(max(bounds.minX, padX), bounds.maxX)
        let gridRight = max(gridLeft, min(bounds.maxX, padX + gridWidth))
        let gridTop = min(max(bounds.minY, padY), bounds.maxY)
        let gridBottom = max(gridTop, min(bounds.maxY, padY + gridHeight))

        return CaptureAutoScrollGeometry(
            gridLeft: gridLeft,
            gridRight: gridRight,
            gridTop: gridTop,
            gridBottom: gridBottom,
            cellHeightPoints: cellHeight
        )
    }

    private func captureAutoScrollSpeedOvershoot(
        for point: CGPoint,
        direction: CaptureAutoScrollDirection,
        geometry: CaptureAutoScrollGeometry,
        edgeBand: CGFloat
    ) -> CGFloat {
        guard edgeBand > 0 else { return CaptureAutoScrollConstants.fullSpeedOvershoot }

        let distanceIntoBand: CGFloat
        let distanceBeyondEdge: CGFloat
        switch direction {
        case .up:
            distanceIntoBand = geometry.gridTop + edgeBand - point.y
            distanceBeyondEdge = max(0, geometry.gridTop - point.y)
        case .down:
            distanceIntoBand = point.y - (geometry.gridBottom - edgeBand)
            distanceBeyondEdge = max(0, point.y - geometry.gridBottom)
        case .none:
            return 0
        }

        // UIKit often caps bottom-edge coordinates just inside the drawable, so
        // bottom drags may never accumulate out-of-view overshoot. Drive the
        // speed curve by edge-band progress first, with true out-of-view
        // overshoot as an additive bonus when the platform reports it.
        let bandProgress = min(max(distanceIntoBand / edgeBand, 0), 1)
        return bandProgress * CaptureAutoScrollConstants.fullSpeedOvershoot
            + distanceBeyondEdge
    }

    private func captureAutoScrollPinnedPosition(
        for point: CGPoint,
        direction: CaptureAutoScrollDirection,
        geometry: CaptureAutoScrollGeometry
    ) -> CGPoint {
        let inset = geometry.cellHeightPoints * CaptureAutoScrollConstants.pinnedRowsInsideEdge
        let gridHeight = geometry.gridBottom - geometry.gridTop
        let minimumY: CGFloat
        let maximumY: CGFloat
        if gridHeight <= inset * 2 {
            let midpoint = geometry.gridTop + gridHeight / 2
            minimumY = midpoint
            maximumY = midpoint
        } else {
            minimumY = geometry.gridTop + inset
            maximumY = geometry.gridBottom - inset
        }

        let pinnedY: CGFloat
        switch direction {
        case .up:
            pinnedY = minimumY
        case .down:
            pinnedY = maximumY
        case .none:
            pinnedY = min(max(point.y, minimumY), maximumY)
        }

        let pinnedX = min(max(point.x, geometry.gridLeft), geometry.gridRight)
        return CGPoint(x: pinnedX, y: pinnedY)
    }

    private func captureAutoScrollEdgeDragPosition(
        for point: CGPoint,
        direction: CaptureAutoScrollDirection,
        geometry: CaptureAutoScrollGeometry
    ) -> CGPoint {
        let edgeInset = geometry.cellHeightPoints * 0.5
        let pinnedY: CGFloat
        switch direction {
        case .up:
            pinnedY = min(geometry.gridBottom, geometry.gridTop + edgeInset)
        case .down:
            pinnedY = max(geometry.gridTop, geometry.gridBottom - edgeInset)
        case .none:
            pinnedY = min(max(point.y, geometry.gridTop), geometry.gridBottom)
        }

        let pinnedX = min(max(point.x, geometry.gridLeft), geometry.gridRight)
        return CGPoint(x: pinnedX, y: pinnedY)
    }
}
