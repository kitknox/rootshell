//
//  FileManagerContainers.swift
//  rootshell
//
//  Hosts for FileManagerView: a resizable column beside the terminal (the AI
//  sidebar's pattern) and a HUD over it (Open in Folder's pattern), either
//  floating and draggable or covering the whole terminal area.
//

import SwiftUI

struct FileManagerSidebarView: View {
    let manager: FileManagerModel
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let canFocus: Bool
    let theme: ResolvedSheetTheme
    let side: EdgeSidebarSide
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    static let minWidth: CGFloat = 300
    static let defaultWidth: CGFloat = 460
    private let maxWidthFraction: CGFloat = 0.7

    /// The themed sheet background when UI theming is on, else the system one.
    @Setting(Settings.Window.roundedPanes) private var roundedPanes

    private var background: Color {
        theme.themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    private var columnShape: UnevenRoundedRectangle {
        side == .leading
            ? PaneCardStyle.leadingColumnShape(rounded: roundedPanes)
            : PaneCardStyle.trailingColumnShape(rounded: roundedPanes)
    }

    private var resizeDivider: some View {
        SidebarResizeDivider(
            side: side == .leading ? .left : .right,
            width: $width,
            isDragging: $isDragging,
            minWidth: Self.minWidth,
            maxWidth: max(Self.minWidth, totalWidth * maxWidthFraction),
            defaultWidth: Self.defaultWidth,
            cardGap: roundedPanes ? PaneCardStyle.gap : nil,
            backgroundColor: roundedPanes ? .clear : background,
            onCommit: { SettingsStore.shared.set(Settings.Transfer.fileManagerSidebarWidth, Double($0)) }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if side == .trailing { resizeDivider }
                FileManagerView(
                    manager: manager,
                    style: .sidebar,
                    canFocus: canFocus,
                    onClose: onClose,
                    onSwitchPresentation: onSwitchPresentation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .clipShape(columnShape)
            .shadow(color: .black.opacity(roundedPanes ? 0 : 0.15), radius: 8, x: side == .leading ? 2 : -2, y: 0)
            .paneCardDepth(roundedPanes, shape: side == .leading
                ? PaneCardStyle.leadingColumnShape(rounded: true)
                : PaneCardStyle.trailingColumnShape(rounded: true),
                           palette: IntegratedTabEdgePalette(cardSurface: background))
            if side == .leading { resizeDivider }
        }
        .background((roundedPanes ? .clear : background).ignoresSafeArea(.container, edges: .bottom))
        .fileManagerTheme(theme)
    }
}

extension View {
    /// Theme environment for file manager content, as the AI and docked tab
    /// sidebars apply it: themed colors for sheets, the accent tint, and the
    /// theme's color scheme scoped to this subtree (never the window's).
    func fileManagerTheme(_ theme: ResolvedSheetTheme) -> some View {
        environment(\.sheetThemeColors, theme.themeColors)
            .tint(theme.accentColor)
            .optionalColorSchemeEnvironment(theme.colorScheme)
    }

    /// A panel HUD's backdrop: glass when floating, the themed fill in the
    /// terminal card's shape when it covers the terminal.
    @ViewBuilder
    func panelHUDBackground(fills: Bool, theme: ResolvedSheetTheme, rounded: Bool, cardBackdrop: Color?,
                            integratedTabJoin: IntegratedTabJoin?) -> some View {
        if fills {
            let surface = theme.panelSurface
            let transparency = TransparencyManager.shared
            let fill = theme.panelFill
            let card = PaneCardStyle.shape(rounded: rounded)
            // Content stays above the home indicator; the fill covers the terminal below it.
            background {
                card.fill(fill)
                    .overlay {
                        if rounded {
                            JoinedCardRim(palette: IntegratedTabEdgePalette(cardSurface: surface),
                                          integratedTabJoin: integratedTabJoin)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .mask { card.ignoresSafeArea(.container, edges: .bottom) }
            // The hidden terminal paints the backdrop around its card otherwise.
            .background {
                if rounded, transparency.fullPanelIsTranslucent, let cardBackdrop {
                    Rectangle().subtracting(card).fill(cardBackdrop)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        } else {
            clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .floatingHUDPanelBackground()
        }
    }
}

struct FileManagerHUD: View {
    let manager: FileManagerModel
    /// Covers the whole terminal area instead of floating.
    let fills: Bool
    let canFocus: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void
    /// Set while Integrated tabs join the terminal card this panel covers.
    let integratedTabJoin: IntegratedTabJoin?

    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Environment(\.paneCardBackdrop) private var paneCardBackdrop

    var body: some View {
        DraggableHUDContainer(
            resizing: fills ? nil : .fileManager,
            fills: fills,
            dismissShortcuts: [.escape],
            forwardsFileManagerToggle: true,
            onDismiss: onClose
        ) {
            FileManagerView(
                manager: manager,
                style: fills ? .full : .overlay,
                canFocus: canFocus,
                onClose: onClose,
                onSwitchPresentation: onSwitchPresentation
            )
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
    static let fileManager = HUDResizing(
        minSize: CGSize(width: 320, height: 320),
        widthKey: Settings.Transfer.fileManagerHUDWidth,
        heightKey: Settings.Transfer.fileManagerHUDHeight)
}

extension ResolvedSheetTheme {
    /// A full-size panel's opaque surface, which its rim derives from.
    var panelSurface: Color {
        themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    /// What a full-size panel paints over the terminal; a joined tab paints it too.
    var panelFill: Color {
        let transparency = TransparencyManager.shared
        return transparency.fullPanelIsTranslucent
            ? (translucentBackground ?? panelSurface).opacity(transparency.effectiveBackgroundOpacity)
            : panelSurface
    }
}
