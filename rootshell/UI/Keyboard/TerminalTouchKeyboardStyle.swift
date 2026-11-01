#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import SwiftUI

struct TerminalTouchKeyboardPalette: Equatable {
    let background: UIColor
    let key: UIColor
    let pressedKey: UIColor
    let pressedInk: UIColor
    let ink: UIColor
    let toolbarInk: UIColor
    let isLight: Bool

    init?(colors: ThemeManager.ThemeInfo.ThemeColors) {
        guard let base = EffectiveSurface.resolve(backgroundHex: colors.background)?.terminal,
              let derived = ThemeUIColorDerivation.derive(from: colors) else { return nil }
        let key = derived.sheetRowBackground
        let preferred = Color(hex: colors.foreground) ?? derived.tabText
        func rgb(_ color: Color) -> TerminalTouchKeyboardModel.RGB {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return .init(red: Double(r), green: Double(g), blue: Double(b))
        }
        func readable(on surface: Color) -> Color {
            let ink = rgb(surface).readableInk(preferred: rgb(preferred))
            return Color(red: ink.red, green: ink.green, blue: ink.blue)
        }
        let ink = readable(on: key)
        let pressed = key.blended(toward: ink, amount: 0.1)
        self.background = UIColor(base)
        self.key = UIColor(key)
        self.pressedKey = UIColor(pressed)
        self.ink = UIColor(ink)
        self.pressedInk = UIColor(readable(on: pressed))
        self.toolbarInk = UIColor(readable(on: base))
        self.isLight = base.isLight
    }
}

enum TerminalTouchKeyboardAppearance {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 34 / 255, blue: 39 / 255, alpha: 1)
            : UIColor(red: 210 / 255, green: 213 / 255, blue: 219 / 255, alpha: 1)
    }
    static let toolbar = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 46 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 235 / 255, blue: 240 / 255, alpha: 1)
    }
}

/// Apple draws capitals smaller and a weight heavier than lowercase, so
/// Shift doesn't swell letters to the key edges.
enum TerminalTouchLegend {
    static func isCapital(_ text: String?) -> Bool { text.map { $0.count == 1 && $0 != $0.lowercased() } ?? false }
    static func scale(_ text: String?) -> CGFloat { isCapital(text) ? 0.88 : 1 }
    static func weight(_ weight: UIFont.Weight, for text: String?) -> UIFont.Weight {
        guard isCapital(text) else { return weight }
        switch weight {
        case .regular: return .medium
        case .medium: return .semibold
        case .semibold: return .bold
        default: return weight
        }
    }
}

/// Rendering contract shared by keyboard styles. Input and hit testing stay in
/// TerminalTouchKeyboardView; each style owns its keycaps, previews, and drawers.
class TerminalTouchKeycap: UIView {
    let key: TerminalTouchKeyboardModel.Key
    let plate = UIView()
    let label = UILabel()
    let icon = UIImageView()
    var palette: TerminalTouchKeyboardPalette?
    var locked = false
    var activate: (() -> Void)?
    var pressed = false
    var selected = false

    init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false) {
        self.key = key
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var legendScale: CGFloat { TerminalTouchLegend.scale(label.text) }
    func legendWeight(_ weight: UIFont.Weight) -> UIFont.Weight { TerminalTouchLegend.weight(weight, for: label.text) }
    func setLegend(_ text: String) {
        guard label.text != text else { return }
        label.text = text
        setNeedsLayout()
    }
    func setSymbol(_ name: String?) {
        icon.image = name.flatMap { UIImage(systemName: $0) }
        label.isHidden = icon.image != nil
    }

    private var badge: UILabel?

    /// A small muted tag pinned to the plate's bottom-right corner, like the
    /// language code on Space. Callers refresh it after `updateColor()`.
    func setBadge(_ text: String?) {
        guard let text else {
            badge?.removeFromSuperview()
            badge = nil
            return
        }
        let badge = self.badge ?? {
            let badge = UILabel()
            badge.font = .systemFont(ofSize: 11, weight: .medium, width: .condensed)
            badge.isAccessibilityElement = false
            badge.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            plate.addSubview(badge)
            self.badge = badge
            return badge
        }()
        badge.text = text
        badge.textColor = label.textColor.withAlphaComponent(0.45)
        badge.sizeToFit()
        // Flexible left/top margins keep it in the corner as the plate resizes.
        badge.frame.origin = CGPoint(x: plate.bounds.width - badge.frame.width - 8,
                                     y: plate.bounds.height - badge.frame.height - 3)
    }
    func updateColor() {}
    func finishVisualTransition() {}
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

class TerminalTouchKeyPreview: UIView {
    let label = UILabel()
    var palette: TerminalTouchKeyboardPalette?
    /// The lowercase legend; capitals derive from it as keycaps do.
    var legend: (size: CGFloat, weight: UIFont.Weight) = (32, .regular)
    func legendFont(size: CGFloat, weight: UIFont.Weight) -> UIFont { .systemFont(ofSize: size, weight: weight) }
    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            label.font = legendFont(size: legend.size * TerminalTouchLegend.scale(newValue),
                                    weight: TerminalTouchLegend.weight(legend.weight, for: newValue))
        }
    }
}

class TerminalTouchDrawerButton: TerminalTouchRepeatingButton {
    let keycap: TerminalTouchKeycap

    init(keycap: TerminalTouchKeycap) {
        self.keycap = keycap
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Styles may render the drawer through a button configuration instead of
    /// the keycap itself, so palette changes must reach the owning button.
    func updatePalette(_ palette: TerminalTouchKeyboardPalette?) {
        keycap.palette = palette
    }
    func refreshAppearance() {
        isSelected = keycap.selected
        accessibilityTraits = keycap.accessibilityTraits.union(.button)
        accessibilityLabel = keycap.accessibilityLabel
        accessibilityValue = keycap.accessibilityValue
    }
}

extension TerminalTouchKeyboardModel.Style {
    @MainActor
    func makeKeycap(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false) -> TerminalTouchKeycap {
        switch self {
        case .flat: TerminalTouchFlatKeycap(key, small: small)
        case .sculpted: TerminalTouchSculptedKeycap(key, small: small)
        case .steampunk: TerminalTouchSteampunkKeycap(key, small: small)
        case .phosphor, .beigeBox, .neonGrid, .circuitBoard:
            TerminalTouchRetroKeycap(key, design: retroDesign ?? .phosphor, small: small)
        }
    }

    @MainActor
    func makePreview() -> TerminalTouchKeyPreview {
        switch self {
        case .flat: TerminalTouchFlatKeyPreview()
        case .sculpted: TerminalTouchSculptedKeyPreview()
        case .steampunk: TerminalTouchSteampunkKeyPreview()
        case .phosphor, .beigeBox, .neonGrid, .circuitBoard:
            TerminalTouchRetroKeyPreview(design: retroDesign ?? .phosphor)
        }
    }

    @MainActor
    func makeDrawerButton(key: TerminalTouchKeyboardModel.Key, subtitle: String?, toolbar: Bool,
                          palette: TerminalTouchKeyboardPalette?) -> TerminalTouchDrawerButton {
        switch self {
        case .flat: TerminalTouchFlatDrawerButton(key: key, subtitle: subtitle, toolbar: toolbar, palette: palette)
        case .sculpted: TerminalTouchSculptedDrawerButton(key: key, subtitle: subtitle, toolbar: toolbar, palette: palette)
        case .steampunk: TerminalTouchSteampunkDrawerButton(key: key, subtitle: subtitle, toolbar: toolbar, palette: palette)
        case .phosphor, .beigeBox, .neonGrid, .circuitBoard:
            TerminalTouchRetroDrawerButton(key: key, design: retroDesign ?? .phosphor, subtitle: subtitle,
                                           toolbar: toolbar, palette: palette)
        }
    }
}

#endif
