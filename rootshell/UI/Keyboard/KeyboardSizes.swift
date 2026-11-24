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
        let keycapGap: CGFloat  // Space between keys drawn as keycaps, as on the system keyboard
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
        toolbar: Toolbar(height: 44, padding: 0, spacing: 0, cornerRadius: 16, drawerHeight: 44, keycapGap: 6),
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
        toolbar: Toolbar(height: 38, padding: 0, spacing: 0, cornerRadius: 14, drawerHeight: 38, keycapGap: 6),
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
        toolbar: Toolbar(height: 55, padding: 6, spacing: 0, cornerRadius: 18, drawerHeight: 55, keycapGap: 7),
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
        if traitCollection.horizontalSizeClass == .regular {
            return .iPad
        }
        return traitCollection.verticalSizeClass == .compact ? .iPhoneLandscape : .iPhonePortrait
        #endif
    }

    /// These sizes at a chosen toolbar size.
    func applying(_ size: KeyboardToolbarSize) -> KeyboardSizes {
        let scale = size.scale
        guard scale != 1 else { return self }
        func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        return KeyboardSizes(
            toolbar: Toolbar(height: scaled(toolbar.height), padding: toolbar.padding, spacing: toolbar.spacing,
                             cornerRadius: scaled(toolbar.cornerRadius), drawerHeight: scaled(toolbar.drawerHeight),
                             keycapGap: toolbar.keycapGap),
            button: Button(height: scaled(button.height), iconWidth: scaled(button.iconWidth),
                           normalWidth: scaled(button.normalWidth), wideWidth: scaled(button.wideWidth),
                           cornerRadius: scaled(button.cornerRadius), fontSize: scaled(button.fontSize),
                           symbolSize: scaled(button.symbolSize)))
    }

    /// These sizes with another key height, for keys drawn as keycaps.
    func withButtonHeight(_ height: CGFloat) -> KeyboardSizes {
        KeyboardSizes(toolbar: toolbar, button: Button(
            height: height, iconWidth: button.iconWidth, normalWidth: button.normalWidth,
            wideWidth: button.wideWidth, cornerRadius: button.cornerRadius,
            fontSize: button.fontSize, symbolSize: button.symbolSize))
    }

    /// The size class picks the preset; the display's toolbar size then scales it.
    /// The Duo's regular-width inner display stays on phone sizes. So does a
    /// remote screen's bar on iPad and Mac, which sits over the desktop it controls.
    static func accessory(traitCollection: UITraitCollection, context: ToolbarContext) -> KeyboardSizes {
        #if os(visionOS)
        let overRemoteScreen = false
        #else
        let overRemoteScreen = context.usesGlassBar
        #endif
        let preset: KeyboardSizes
        if DuoHingeEvents.hasHinge || overRemoteScreen {
            preset = traitCollection.verticalSizeClass == .compact ? .iPhoneLandscape : .iPhonePortrait
        } else {
            preset = current(traitCollection: traitCollection)
        }
        return preset.applying(KeyboardToolbarSize.current)
    }
}
