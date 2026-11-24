//
//  PaneUnderlay.swift
//  rootshell
//
//  Text Above Effect: pane backgrounds drawn beneath the background effect,
//  while ghostty draws only glyphs, so the effect never blends into the text.
//

import SwiftUI
import UIKit

/// One tab's pane backgrounds, in its split host's coordinates. The underlay
/// fills the same layout slot as the host, so pushed frames line up as-is.
@MainActor
final class PaneUnderlayModel {
    struct Pane: Equatable {
        var frame: CGRect
        var cornerRadius: CGFloat
        var color: UIColor
    }

    /// Rounded Panes backdrop around the cards (Catalyst), even-odd filled.
    struct Gaps: Equatable {
        var path: CGPath
        var color: UIColor
    }

    private(set) var panes: [Pane] = []
    private(set) var gaps: Gaps?
    weak var view: PaneUnderlayView? {
        didSet { view?.apply(self) }
    }

    /// Called from the host's layout pass, so the underlay moves in step.
    func update(panes: [Pane], gaps: Gaps?) {
        guard panes != self.panes || gaps != self.gaps else { return }
        self.panes = panes
        self.gaps = gaps
        view?.apply(self)
    }
}

extension Notification.Name {
    /// A program changed or reset its pane's background (OSC 11 / 111).
    static let terminalPaneBackgroundDidChange = Notification.Name("terminalPaneBackgroundDidChange")
}

extension Ghostty.TerminalView {
    /// The background this pane shows: a program's OSC 11 color, else its
    /// tab or window theme plus Tint by Host.
    var paneBackgroundColor: UIColor? {
        if let rgb = programBackgroundRGB {
            return UIColor(red: CGFloat(rgb.x) / 255, green: CGFloat(rgb.y) / 255, blue: CGFloat(rgb.z) / 255, alpha: 1)
        }
        return configuredPaneBackgroundColor
    }

    /// Whether the pane reads light as drawn. Only window panes sit over the
    /// Theme Gradient backdrop; overlays like the Visor draw over app content.
    func paneSurfaceIsLight(overBackdrop: Bool) -> Bool? {
        paneBackgroundColor.map { color in
            overBackdrop ? EffectiveSurface.resolve(background: Color(uiColor: color)).isLight : Color(uiColor: color).isLight
        }
    }

    func handleBackgroundColorChange(_ rgb: SIMD3<UInt8>) {
        // A reset reports the configured color, which ends the override. Ghostty
        // doesn't flag resets, so an OSC 11 to that same color reads as one too.
        let configured = configuredPaneBackgroundColor.map { color -> SIMD3<UInt8> in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let channel = { (value: CGFloat) in UInt8((min(max(value, 0), 1) * 255).rounded()) }
            return SIMD3(channel(r), channel(g), channel(b))
        }
        let override = rgb == configured ? nil : rgb
        guard override != programBackgroundRGB else { return }
        programBackgroundRGB = override
        NotificationCenter.default.post(name: .terminalPaneBackgroundDidChange, object: self)
    }

    private var configuredPaneBackgroundColor: UIColor? {
        let (themeName, _) = ThemeOverrideManager.shared.resolveTheme(tabId: containingTabID, windowId: windowId)
        let hex = ThemeManager.shared.themeInfo(for: themeName)?.colors.background
            ?? ThemeManager.shared.currentThemeInfo?.colors.background
        guard let base = hex.flatMap({ UIColor(hex: $0) }) else { return nil }
        guard let fingerprint = HostFingerprintRegistry.shared.tintFingerprint(for: connectionConfig)
        else { return base }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        let channel = { (value: CGFloat) in UInt8((min(max(value, 0), 1) * 255).rounded()) }
        let tinted = HostTint.tintedBackground(
            red: channel(r), green: channel(g), blue: channel(b), fingerprint: fingerprint)
        return UIColor(hex: tinted) ?? base
    }
}

/// Surfaces outside the pane stack have no underlay; this backs them with the
/// global theme while Text Above Effect leaves them glyph-only.
enum GlyphOnlySurfaceFill {
    static var color: UIColor? {
        guard EffectManager.shared.isTextAboveEffectActive else { return nil }
        return ThemeManager.shared.currentThemeInfo.flatMap { UIColor(hex: $0.colors.background) }
    }
}

struct PaneUnderlay: UIViewRepresentable {
    let model: PaneUnderlayModel

    func makeUIView(context: Context) -> PaneUnderlayView {
        let view = PaneUnderlayView()
        model.view = view
        return view
    }

    func updateUIView(_ view: PaneUnderlayView, context: Context) {
        if model.view !== view { model.view = view }
    }
}

final class PaneUnderlayView: UIView {
    private final class GapView: UIView {
        override class var layerClass: AnyClass { CAShapeLayer.self }
        var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }
    }

    private let gapView = GapView()
    /// Views rather than bare layers so a pane-move animation carries them along.
    private var paneViews: [UIView] = []

    /// Exposé slides the hero tab down; its backgrounds follow beneath the effect.
    var contentShift: CGFloat = 0 {
        didSet {
            guard contentShift != oldValue else { return }
            layer.sublayerTransform = CATransform3DMakeTranslation(0, contentShift, 0)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gapView.shapeLayer.fillRule = .evenOdd
        addSubview(gapView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gapView.frame = bounds
    }

    func apply(_ model: PaneUnderlayModel) {
        while paneViews.count < model.panes.count {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.layer.cornerCurve = .continuous
            addSubview(view)
            paneViews.append(view)
        }
        for (index, view) in paneViews.enumerated() {
            guard model.panes.indices.contains(index) else {
                view.isHidden = true
                continue
            }
            let pane = model.panes[index]
            view.isHidden = false
            view.frame = pane.frame
            view.layer.cornerRadius = pane.cornerRadius
            view.backgroundColor = pane.color
        }
        gapView.isHidden = model.gaps == nil
        gapView.shapeLayer.path = model.gaps?.path
        gapView.shapeLayer.fillColor = model.gaps?.color.cgColor
    }
}
