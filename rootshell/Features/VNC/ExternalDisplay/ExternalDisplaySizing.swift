//
//  ExternalDisplaySizing.swift
//  rootshell
//
//  The remote desktop size requested for an external display. Kept free of
//  UIKit and settings so the unit tests can compile it on its own.
//

import CoreGraphics

enum ExternalDisplaySizing {
    /// Match Client's 60 fps ceiling, in 2x points (see rootshellVNC's
    /// RemoteDisplaySize: 3840x2160 pixels at a 2x backing scale).
    static let maximumPointArea: CGFloat = 1920 * 1080

    /// The size, in points, to hand Match Client for a screen.
    ///
    /// The screen is first fitted under Match Client's area ceiling, then
    /// divided by `scaleFactor`. Applying the user's scale below the ceiling
    /// makes every step take effect even on monitors whose full size would be
    /// capped back to the same display (2560x1440 at 1.25x is still above it).
    static func requestedSize(for screenSize: CGSize, scaleFactor: CGFloat) -> CGSize {
        guard screenSize.width > 0, screenSize.height > 0, scaleFactor > 0 else {
            return screenSize
        }
        let capFit = min(1, (maximumPointArea / (screenSize.width * screenSize.height)).squareRoot())
        let factor = capFit / scaleFactor
        return CGSize(
            width: (screenSize.width * factor).rounded(),
            height: (screenSize.height * factor).rounded())
    }
}
