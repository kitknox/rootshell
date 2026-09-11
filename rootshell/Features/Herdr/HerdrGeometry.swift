import Foundation
import CoreGraphics
import IOSurface

/// Geometry for the UIKit Ghostty surfaces used by herdr panes, including
/// Catalyst. Ghostty's iOS/visionOS font backend uses 96 DPI; its configured
/// window padding is in 72-DPI typographic points, not UIKit points.
nonisolated enum HerdrGeometry {
    static func frameMatches(_ contents: Any, width: UInt32, height: UInt32) -> Bool {
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return false }
        let frame = unsafeBitCast(contents as CFTypeRef, to: IOSurfaceRef.self)
        return IOSurfaceGetWidth(frame) == Int(width) && IOSurfaceGetHeight(frame) == Int(height)
    }

    static func padding(_ configured: Int, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        // Match Surface.DerivedConfig.scaledPadding: floor each edge in pixels
        // before converting back to the native layout's points.
        let pixels = floor(Float(configured) * (Float(scale) * 96) / 72)
        return CGFloat(pixels) / scale
    }

    static func chrome(paddingX: Int, paddingY: Int, scale: CGFloat, bottomInsetPixels: Double) -> CGSize {
        guard scale > 0 else { return .zero }
        // Match Surface.setBottomInset's pixel rounding and clamp.
        let bottom = bottomInsetPixels.isFinite ? min(max(bottomInsetPixels.rounded(), 0), 10_000) : 0
        return CGSize(
            width: padding(paddingX, scale: scale) * 2,
            height: padding(paddingY, scale: scale) * 2 + CGFloat(bottom) / scale
        )
    }

    static func cellBudget(extent: CGFloat, chrome: CGFloat, cell: CGFloat) -> Int {
        guard cell > 0 else { return 1 }
        // A pixel divided by a 3x scale can land infinitesimally below the
        // exact cell boundary. Discard only floating-point roundoff.
        return max(1, Int(floor((extent - chrome) / cell + 1e-9)))
    }
}

/// One tab's geometry negotiation. Visibility is deliberately absent: a
/// hosted background tab can prepare exactly like the selected tab.
nonisolated struct HerdrTabGeometryState {
    struct Size: Equatable, Sendable {
        let cols: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int
    }

    struct Request: Equatable, Sendable {
        let id = UUID()
        let size: Size
    }

    private(set) var desired: Size?
    private(set) var confirmed: Size?
    private(set) var inFlight: Request?
    private(set) var hasRequested = false

    var isConfirmed: Bool {
        desired != nil && desired == confirmed && inFlight == nil
    }

    mutating func update(_ size: Size) {
        desired = size
    }

    mutating func beginRequest() -> Request? {
        guard let desired, !isConfirmed, inFlight == nil else { return nil }
        let request = Request(size: desired)
        inFlight = request
        hasRequested = true
        return request
    }

    /// An old stream/tab's completion cannot confirm a new request, even
    /// if its dimensions happen to match. A newer desired size stays pending.
    @discardableResult
    mutating func finish(_ request: Request, succeeded: Bool) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        confirmed = succeeded ? request.size : nil
        return true
    }
}
