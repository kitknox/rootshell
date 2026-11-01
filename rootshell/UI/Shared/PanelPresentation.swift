//
//  PanelPresentation.swift
//  rootshell
//
//  How a trailing panel (File Manager, HTTP Capture) is shown: docked in the
//  window's single trailing panel slot, floating as an overlay, or covering
//  the whole terminal area.
//

import SwiftUI

enum PanelPresentation: String, CaseIterable, Codable, Sendable {
    case sidebar
    case overlay
    case full

    var title: String {
        switch self {
        case .sidebar: String(localized: "Sidebar", comment: "Panel presentation option")
        case .overlay: String(localized: "Overlay", comment: "Panel presentation option")
        case .full: String(localized: "Full Size", comment: "Panel presentation option: covers the whole terminal area")
        }
    }

    var systemImage: String {
        switch self {
        case .sidebar: "sidebar.right"
        case .overlay: "macwindow"
        case .full: "rectangle.inset.filled"
        }
    }

    /// Overlay and full size cover the terminal, so they take the keyboard; the sidebar shares it.
    var ownsKeyboard: Bool { self != .sidebar }

    /// Whether two panels shown this way would collide. Full size covers the
    /// terminal, so it displaces a panel in any spot.
    func sharesSlot(with other: PanelPresentation) -> Bool {
        self == other || self == .full || other == .full
    }
}

/// Header menu that switches a panel's presentation, checking the current one.
/// Equatable so panel and MainView renders skip this body and never rebuild
/// the menu while it is open. `onSwitch` is excluded; it acts on live state.
struct PanelPresentationMenu: View, Equatable {
    let current: PanelPresentation
    let onSwitch: (PanelPresentation) -> Void
    var showsTitle = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.current == rhs.current && lhs.showsTitle == rhs.showsTitle
    }

    var body: some View {
        Menu {
            Picker(
                String(localized: "Show As", comment: "Panel presentation menu section title"),
                selection: Binding(get: { current }, set: { onSwitch($0) })
            ) {
                ForEach(PanelPresentation.allCases, id: \.self) { presentation in
                    Label(presentation.title, systemImage: presentation.systemImage)
                        .tag(presentation)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if showsTitle {
                Label(String(localized: "Show As", comment: "Panel presentation menu section title"), systemImage: current.systemImage)
            } else {
                Image(systemName: current.systemImage)
            }
        }
        .accessibilityLabel(String(localized: "Presentation", comment: "Panel presentation menu"))
        .accessibilityValue(current.title)
    }
}
