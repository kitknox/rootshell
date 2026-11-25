//
//  HTTPCaptureContainers.swift
//  rootshell
//
//  Hosts for HTTPCaptureView: a resizable column beside the terminal and a
//  HUD over it (floating or full size), matching the file manager's containers.
//

#if !CHINA_BUILD

import SwiftUI

struct HTTPCaptureSidebarView: View {
    let model: HTTPCaptureModel
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let theme: ResolvedSheetTheme
    /// The window's side rail carries the header actions.
    var actionsInRail = false
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    static let minWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 480
    private let maxWidthFraction: CGFloat = 0.7

    @Setting(Settings.Window.roundedPanes) private var roundedPanes

    private var background: Color {
        theme.themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeDivider(
                side: .right,
                width: $width,
                isDragging: $isDragging,
                minWidth: Self.minWidth,
                maxWidth: max(Self.minWidth, totalWidth * maxWidthFraction),
                defaultWidth: Self.defaultWidth,
                cardGap: roundedPanes ? PaneCardStyle.gap : nil,
                backgroundColor: roundedPanes ? .clear : background,
                onCommit: { SettingsStore.shared.set(Settings.HTTPCapture.sidebarWidth, Double($0)) }
            )
            HTTPCaptureView(model: model, style: .sidebar, onClose: onClose, onSwitchPresentation: onSwitchPresentation,
                            actionsInRail: actionsInRail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                .clipShape(PaneCardStyle.trailingColumnShape(rounded: roundedPanes))
                .shadow(color: .black.opacity(roundedPanes ? 0 : 0.15), radius: 8, x: -2, y: 0)
                .paneCardDepth(roundedPanes, shape: PaneCardStyle.trailingColumnShape(rounded: true),
                               palette: IntegratedTabEdgePalette(cardSurface: background))
        }
        .background((roundedPanes ? .clear : background).ignoresSafeArea(.container, edges: .bottom))
        .fileManagerTheme(theme)
    }
}

struct HTTPCaptureHUD: View {
    let model: HTTPCaptureModel
    /// Covers the whole terminal area instead of floating.
    let fills: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void
    /// Set while Integrated tabs join the terminal card this panel covers.
    let integratedTabJoin: IntegratedTabJoin?
    /// The window's side rail carries the header actions.
    var actionsInRail = false

    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Environment(\.paneCardBackdrop) private var paneCardBackdrop

    var body: some View {
        DraggableHUDContainer(
            resizing: fills ? nil : .httpCapture,
            fills: fills,
            dismissShortcuts: [.escape],
            forwardsHTTPCaptureToggle: true,
            onDismiss: onClose
        ) {
            HTTPCaptureView(model: model, style: fills ? .full : .overlay, onClose: onClose, onSwitchPresentation: onSwitchPresentation,
                            actionsInRail: actionsInRail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panelHUDBackground(fills: fills, theme: theme, rounded: roundedPanes, cardBackdrop: paneCardBackdrop,
                                    integratedTabJoin: integratedTabJoin)
                .fileManagerTheme(theme)
        }
        // Rounded cards already end in the home-indicator strip, a gap above the edge.
        .ignoresSafeArea(.container, edges: fills && !roundedPanes ? .bottom : [])
    }
}

extension HUDResizing {
    static let httpCapture = HUDResizing(
        minSize: CGSize(width: 320, height: 320),
        widthKey: Settings.HTTPCapture.hudWidth,
        heightKey: Settings.HTTPCapture.hudHeight)
}

#endif
