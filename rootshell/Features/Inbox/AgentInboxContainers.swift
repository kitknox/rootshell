//
//  AgentInboxContainers.swift
//  rootshell
//
//  Hosts for AgentInboxView: a resizable column beside the terminal, a HUD
//  over it (floating or full size), or a sheet on iPhone, matching the file
//  manager and HTTP capture.
//

import SwiftUI

struct AgentInboxSidebarView: View {
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    static let minWidth: CGFloat = 300
    static let defaultWidth: CGFloat = 400
    private let maxWidthFraction: CGFloat = 0.6

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
                onCommit: { SettingsStore.shared.set(Settings.AgentInbox.sidebarWidth, Double($0)) }
            )
            AgentInboxView(style: .sidebar, onClose: onClose, onSwitchPresentation: onSwitchPresentation)
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

struct AgentInboxHUD: View {
    /// Covers the whole terminal area instead of floating.
    let fills: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void
    /// Set while Integrated tabs join the terminal card this panel covers.
    let integratedTabJoin: IntegratedTabJoin?

    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Environment(\.paneCardBackdrop) private var paneCardBackdrop

    var body: some View {
        DraggableHUDContainer(
            resizing: fills ? nil : .agentInbox,
            fills: fills,
            dismissShortcuts: [.escape],
            forwardsAgentInboxToggle: true,
            onDismiss: onClose
        ) {
            AgentInboxView(style: fills ? .full : .overlay, onClose: onClose, onSwitchPresentation: onSwitchPresentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panelHUDBackground(fills: fills, theme: theme, rounded: roundedPanes, cardBackdrop: paneCardBackdrop,
                                    integratedTabJoin: integratedTabJoin)
                .fileManagerTheme(theme)
        }
        .ignoresSafeArea(.container, edges: fills && !roundedPanes ? .bottom : [])
    }
}

extension HUDResizing {
    static let agentInbox = HUDResizing(
        minSize: CGSize(width: 340, height: 360),
        widthKey: Settings.AgentInbox.hudWidth,
        heightKey: Settings.AgentInbox.hudHeight)
}

struct AgentInboxPhoneSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let sheetTheme: ResolvedSheetTheme
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            AgentInboxView(style: .sheet, onClose: onClose, onSwitchPresentation: nil)
                .presentationDetents([.large])
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
        }
    }
}
