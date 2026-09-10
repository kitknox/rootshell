import Foundation
import CoreGraphics

/// Geometry for the UIKit Ghostty surfaces used by herdr panes, including
/// Catalyst. Ghostty's iOS/visionOS font backend uses 96 DPI; its configured
/// window padding is in 72-DPI typographic points, not UIKit points.
nonisolated enum HerdrGeometry {
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
