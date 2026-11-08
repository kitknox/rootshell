//
//  PaneCardStyle.swift
//  rootshell
//
//  Geometry for the Rounded Panes window style
//

import UIKit

nonisolated enum PaneCardStyle {
    static let cornerRadius: CGFloat = 12
    /// Spacing between cards and around the content area. Also the split
    /// divider thickness, so tmux/herdr cell budgeting sees the real gap.
    static let gap: CGFloat = 8

    /// Rim alpha at the card's bottom, relative to the lit top edge.
    static let rimBottomFraction: CGFloat = 0.35

    static var isEnabled: Bool {
        SettingsStore.shared.value(Settings.Window.roundedPanes)
    }
}

extension UIView {
    /// Shapes a pane container: a Rounded Panes card keeps its fixed radius. A
    /// square pane stays square, except where a corner meets a rounded corner
    /// of the display or window. There it takes that curve, so a focus border
    /// follows the screen's edge instead of being cut off by it. UIKit resolves
    /// each corner against the real display (the Duo's front display rounds
    /// its outer corners far more than its hinge side), so no per-device radius
    /// is assumed here.
    func applyPaneCorners(rounded: Bool) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            // Once a view has a corner configuration, it alone shapes the
            // corners: a later layer.cornerRadius write is never drawn, and
            // reading it does not report the configured radius. So both
            // shapes go through it.
            cornerConfiguration = rounded
                ? .uniformCorners(radius: .fixed(Double(PaneCardStyle.cornerRadius)))
                : .corners(radius: .containerConcentric(minimum: 0))
            return
        }
        #endif
        layer.cornerRadius = rounded ? PaneCardStyle.cornerRadius : 0
        layer.cornerCurve = .continuous
    }
}
