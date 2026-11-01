//
//  PaneCardStyle.swift
//  rootshell
//
//  Geometry for the Rounded Panes window style
//

import Foundation

nonisolated enum PaneCardStyle {
    static let cornerRadius: CGFloat = 12
    /// Spacing between cards and around the content area. Also the split
    /// divider thickness, so tmux/herdr cell budgeting sees the real gap.
    static let gap: CGFloat = 4

    /// Rim alpha at the card's bottom, relative to the lit top edge.
    static let rimBottomFraction: CGFloat = 0.35

    static var isEnabled: Bool {
        SettingsStore.shared.value(Settings.Window.roundedPanes)
    }
}
