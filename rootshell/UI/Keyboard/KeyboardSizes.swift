//
//  KeyboardSizes.swift
//  rootshell
//
//  Device-specific sizing for keyboard toolbar
//

import UIKit

struct KeyboardSizes {
    // MARK: - Nested Types

    struct Toolbar {
        let height: CGFloat
        let padding: CGFloat  // Vertical padding
        let spacing: CGFloat  // Horizontal spacing between buttons
        let cornerRadius: CGFloat
        let drawerHeight: CGFloat  // Height of expandable drawer row (0 on iPad)
    }

    struct Button {
        let height: CGFloat
        let iconWidth: CGFloat    // For arrow cluster, copy/paste icons
        let normalWidth: CGFloat  // For Tab, symbols
        let wideWidth: CGFloat    // For Esc, Ctrl, Alt, Cmd
        let cornerRadius: CGFloat
        let fontSize: CGFloat
        let symbolSize: CGFloat
    }

    // MARK: - Properties

    let toolbar: Toolbar
    let button: Button

    // MARK: - Device Presets

    /// iPhone portrait (small)
    static let iPhonePortrait = KeyboardSizes(
        toolbar: Toolbar(height: 44, padding: 0, spacing: 0, cornerRadius: 16, drawerHeight: 44),
        button: Button(
            height: 38,
            iconWidth: 48,
            normalWidth: 33,
            wideWidth: 48,
            cornerRadius: 10,
            fontSize: 15,
            symbolSize: 16
        )
    )

    /// iPhone landscape (compact)
    static let iPhoneLandscape = KeyboardSizes(
        toolbar: Toolbar(height: 38, padding: 0, spacing: 0, cornerRadius: 14, drawerHeight: 38),
        button: Button(
            height: 32,
            iconWidth: 44,
            normalWidth: 30,
            wideWidth: 44,
            cornerRadius: 9,
            fontSize: 14,
            symbolSize: 15
        )
    )

    /// iPad (all orientations)
    static let iPad = KeyboardSizes(
        toolbar: Toolbar(height: 55, padding: 6, spacing: 0, cornerRadius: 18, drawerHeight: 55),
        button: Button(
            height: 43,
            iconWidth: 58,
            normalWidth: 48,
            wideWidth: 68,
            cornerRadius: 12,
            fontSize: 17,
            symbolSize: 18
        )
    )

    // MARK: - Device Detection

    static func current(traitCollection: UITraitCollection) -> KeyboardSizes {
        #if os(visionOS)
        // visionOS doesn't have device orientation, use iPad sizes
        return .iPad
        #else
        if UIDevice.current.userInterfaceIdiom != .phone {
            return .iPad
        }
        return traitCollection.verticalSizeClass == .compact ? .iPhoneLandscape : .iPhonePortrait
        #endif
    }
}
