//
//  ExternalDisplaySettings.swift
//  rootshell
//
//  User preferences for the external display feature. Defaults ON:
//  connecting a display shows the terminal UX; disabling falls back to
//  system mirroring.
//

import UIKit

enum ExternalDisplaySettings {
    static let enabledKey = "externalDisplayEnabled"
    static let fontSizeKey = "externalDisplayFontSize"
    static let zoomKey = "externalDisplayZoom"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Absolute font size applied to terminals while they live on the
    /// external display. 0 (default) means "no override".
    static var fontSize: Double {
        get { UserDefaults.standard.double(forKey: fontSizeKey) }
        set { UserDefaults.standard.set(newValue, forKey: fontSizeKey) }
    }

    /// Display-zoom preference for the external screen's UI. 0 (default)
    /// means Automatic: derive from the connected display's resolution.
    static var zoom: Double {
        get { UserDefaults.standard.double(forKey: zoomKey) }
        set { UserDefaults.standard.set(newValue, forKey: zoomKey) }
    }

    /// Clean fractions only: quantized zoom bounds chrome softness from
    /// fractional CA scaling, and each step lands on a distinct DPI.
    static let allowedZoomSteps: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Auto default: target ~1440pt effective logical width, floor 600pt
    /// effective height, clamped and quantized. AirPlay/HDMI screens report
    /// no physical size, so pixel class plus the manual override is the whole
    /// contract.
    static func autoZoomFactor(for screen: UIScreen) -> CGFloat {
        let raw = screen.bounds.width / 1440
        let heightCap = screen.bounds.height / 600
        let clamped = min(max(raw, 1.0), max(1.0, min(3.0, heightCap)))
        let step = allowedZoomSteps.min {
            abs($0 - clamped) < abs($1 - clamped)
        } ?? 1.0
        return CGFloat(step)
    }
}
