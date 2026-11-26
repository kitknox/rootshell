//
//  GitDiffContainers.swift
//  rootshell
//
//  Hosts for GitDiffView: a resizable column beside the terminal, a HUD over
//  it (floating or full size), the collapsed summary pill, or a sheet on
//  iPhone. The floating HUD and the pill leave the keyboard with the
//  terminal, so an agent can be driven while its changes are in view.
//

import SwiftUI

struct GitDiffSidebarView: View {
    let store: GitDiffStore
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let theme: ResolvedSheetTheme
    /// The window's side rail carries the panel's actions.
    var actionsInRail = false
    /// Lifts the content above a docked keyboard or toolbar; the row ignores the keyboard.
    var bottomClearance: CGFloat = 0
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    static let minWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 460
    private let maxWidthFraction: CGFloat = 0.65

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
                onCommit: { SettingsStore.shared.set(Settings.GitDiff.sidebarWidth, Double($0)) }
            )
            GitDiffView(store: store, style: .sidebar, onClose: onClose, onCollapse: nil,
                        onSwitchPresentation: onSwitchPresentation, actionsInRail: actionsInRail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomClearance)
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

struct GitDiffHUD: View {
    let store: GitDiffStore
    /// Covers the whole terminal area instead of floating.
    let fills: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onCollapse: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void
    /// Set while Integrated tabs join the terminal card this panel covers.
    let integratedTabJoin: IntegratedTabJoin?
    /// The window's side rail carries the panel's actions.
    var actionsInRail = false

    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Environment(\.paneCardBackdrop) private var paneCardBackdrop

    var body: some View {
        DraggableHUDContainer(
            resizing: fills ? nil : .gitDiff,
            fills: fills,
            // Floating, the terminal keeps the keyboard and Escape belongs to it.
            dismissShortcuts: fills ? [.escape] : [],
            forwardsGitDiffToggle: true,
            onDismiss: onClose
        ) {
            GitDiffView(store: store, style: fills ? .full : .overlay, onClose: onClose,
                        onCollapse: fills ? nil : onCollapse, onSwitchPresentation: onSwitchPresentation,
                        actionsInRail: actionsInRail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panelHUDBackground(fills: fills, theme: theme, rounded: roundedPanes, cardBackdrop: paneCardBackdrop,
                                    integratedTabJoin: integratedTabJoin)
                .fileManagerTheme(theme)
        }
        .ignoresSafeArea(.container, edges: fills && !roundedPanes ? .bottom : [])
    }
}

/// The collapsed overlay. Draggable like the HUD it stands in for.
struct GitDiffPillHUD: View {
    let store: GitDiffStore
    let theme: ResolvedSheetTheme
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            DraggableHUDContainer(forwardsGitDiffToggle: true, onDismiss: onClose) {
                GitDiffSummaryPill(
                    store: store,
                    maxWidth: geometry.size.width > 24 ? geometry.size.width - 24 : nil,
                    onExpand: onExpand,
                    onClose: onClose
                )
                .fileManagerTheme(theme)
            }
        }
    }
}

extension HUDResizing {
    static let gitDiff = HUDResizing(
        minSize: CGSize(width: 340, height: 300),
        widthKey: Settings.GitDiff.hudWidth,
        heightKey: Settings.GitDiff.hudHeight)
}

struct GitDiffPhoneSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let store: GitDiffStore?
    let terminal: Ghostty.TerminalView?
    let sheetTheme: ResolvedSheetTheme
    let onClose: () -> Void
    let onCollapse: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let store {
                PanelSheetNavigation {
                    PanelSideRailReader { inRail in
                        GitDiffView(store: store, style: .sheet, onClose: onClose, onCollapse: onCollapse,
                                    onSwitchPresentation: nil, actionsInRail: inRail)
                            .modifier(GitDiffSheetRail(active: inRail, store: store, onCollapse: onCollapse, onClose: onClose))
                    }
                }
                .modifier(GitDiffFollowModifier(store: store, terminal: terminal, wantsPatch: true))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor,
                             colorScheme: sheetTheme.colorScheme)
            }
        }
    }
}

/// Points the store at the focused pane and tells it how much to load.
struct GitDiffFollowModifier: ViewModifier {
    let store: GitDiffStore
    let terminal: Ghostty.TerminalView?
    /// False while only the summary pill is on screen.
    let wantsPatch: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: terminal?.uuid, initial: true) { _, _ in
                store.setTarget(terminal)
            }
            .onChange(of: wantsPatch, initial: true) { _, wantsPatch in
                store.setActive(true, wantsPatch: wantsPatch)
            }
    }
}
