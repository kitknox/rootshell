import SwiftUI
import UIKit

/// Card and control surfaces for the inbox, derived from the panel's theme.
extension SheetThemeColors {
    /// Semantic colours resolve against the system scheme, which can disagree
    /// with a dark terminal theme; the inbox forces the scheme of its surface.
    var isDarkSurface: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(background).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue) < 0.5
    }

    /// One brightness step off the page, keeping its hue (a white overlay
    /// washes the tint out).
    var cardFill: Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(background).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let step: CGFloat = isDarkSurface ? 0.095 : -0.045
        return Color(hue: Double(hue),
                     saturation: Double(saturation),
                     brightness: Double(min(max(brightness + step, 0), 1)),
                     opacity: Double(alpha))
    }

    var cardStroke: Color {
        isDarkSurface ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    var controlFill: Color {
        isDarkSurface ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    var selectedControlFill: Color {
        isDarkSurface ? Color.white.opacity(0.16) : Color.white
    }
}
