//
//  PaneCardClip.swift
//  rootshell
//
//  Rounded Panes card clipping for SwiftUI columns
//

import SwiftUI

extension PaneCardStyle {
    static func shape(rounded: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: rounded ? cornerRadius : 0, style: .continuous)
    }

    /// Right-hand docked columns always round their leading corners; cards
    /// round all four.
    static func trailingColumnShape(rounded: Bool) -> UnevenRoundedRectangle {
        let trailing: CGFloat = rounded ? cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12,
            bottomTrailingRadius: trailing, topTrailingRadius: trailing,
            style: rounded ? .continuous : .circular)
    }

    /// Left-hand docked columns always round their trailing corners.
    static func leadingColumnShape(rounded: Bool) -> UnevenRoundedRectangle {
        let leading: CGFloat = rounded ? cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: leading, bottomLeadingRadius: leading,
            bottomTrailingRadius: 12, topTrailingRadius: 12,
            style: rounded ? .continuous : .circular)
    }
}

/// Clips to a card only while Rounded Panes is on, so the default layout
/// keeps drawing outside its bounds as before.
struct PaneCardClip: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(PaneCardStyle.shape(rounded: true))
        } else {
            content
        }
    }
}

extension View {
    func paneCardClip(_ isEnabled: Bool) -> some View {
        modifier(PaneCardClip(isEnabled: isEnabled))
    }
}

private struct PaneCardBackdropKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Translucent Rounded Panes backdrop that the split view paints only
    /// between its cards (Catalyst); nil when the window root fill covers it.
    var paneCardBackdrop: Color? {
        get { self[PaneCardBackdropKey.self] }
        set { self[PaneCardBackdropKey.self] = newValue }
    }
}

private struct PaneCardRimPaletteKey: EnvironmentKey {
    static let defaultValue: IntegratedTabEdgePalette? = nil
}

extension EnvironmentValues {
    /// Rounded Panes rim colors for the split view's cards: the integrated tab
    /// edge palette, so a joined tab's outline continues the rim exactly.
    var paneCardRimPalette: IntegratedTabEdgePalette? {
        get { self[PaneCardRimPaletteKey.self] }
        set { self[PaneCardRimPaletteKey.self] = newValue }
    }
}

/// A rect with card-shaped holes, filled even-odd, so a translucent backdrop
/// never stacks beneath translucent cards.
struct PaneCardBackdropShape: Shape {
    struct Hole {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    let holes: [Hole]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes where !hole.rect.isEmpty {
            path.addRoundedRect(
                in: hole.rect,
                cornerSize: CGSize(width: hole.cornerRadius, height: hole.cornerRadius),
                style: .continuous)
        }
        return path
    }
}

/// The window-wide effect's docked sidebar card (when the effect spans it;
/// `sidebarWidth` includes its trailing gap) and terminal card.
struct PaneCardEffectShape: Shape {
    var sidebarWidth: CGFloat

    var animatableData: CGFloat {
        get { sidebarWidth }
        set { sidebarWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let corner = CGSize(width: PaneCardStyle.cornerRadius, height: PaneCardStyle.cornerRadius)
        var path = Path()
        let sidebarCard = CGRect(x: 0, y: 0, width: sidebarWidth - PaneCardStyle.gap, height: rect.height)
        if sidebarCard.width > 0 {
            path.addRoundedRect(in: sidebarCard, cornerSize: corner, style: .continuous)
        }
        let terminalCard = CGRect(x: sidebarWidth, y: 0, width: rect.width - sidebarWidth, height: rect.height)
        if terminalCard.width > 0 {
            path.addRoundedRect(in: terminalCard, cornerSize: corner, style: .continuous)
        }
        return path
    }
}

/// The window-wide effect's visible area: its cards under Rounded Panes (or
/// the whole terminal), shifted down by `topExtension`, plus the selected
/// Integrated tab's silhouette, which shows the same effect.
struct TerminalEffectWindowShape: Shape {
    var sidebarWidth: CGFloat
    var topExtension: CGFloat
    var roundedPanes: Bool
    /// The selected tab and its track's visible bounds, in local space.
    var tabRect: CGRect?
    var clip: CGRect?
    /// Gaps between split cards, in local space.
    var gaps: Path?

    var animatableData: CGFloat {
        get { sidebarWidth }
        set { sidebarWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let terminal = CGRect(x: rect.minX, y: rect.minY + topExtension,
                              width: rect.width, height: max(0, rect.height - topExtension))
        var path = roundedPanes
            ? PaneCardEffectShape(sidebarWidth: sidebarWidth)
                .path(in: CGRect(origin: .zero, size: terminal.size))
                .offsetBy(dx: terminal.minX, dy: terminal.minY)
            : Path(terminal)
        // A swiping tab's gaps slide past the terminal card; keep them off the sidebar's.
        if let gaps {
            let card = CGRect(x: terminal.minX + sidebarWidth, y: terminal.minY,
                              width: max(0, terminal.width - sidebarWidth), height: terminal.height)
            path = path.subtracting(gaps.intersection(Path(card)))
        }
        guard let tabRect, !tabRect.isEmpty else { return path }
        var tab = IntegratedTabGeometry(in: tabRect).silhouettePath
        if let clip { tab = tab.intersection(Path(clip)) }
        path = path.union(tab)
        return path
    }
}

/// Clips the effect to `TerminalEffectWindowShape`, following the selected
/// tab through `join` without invalidating `MainView`.
struct TerminalEffectWindowClip: ViewModifier {
    let roundedPanes: Bool
    let sidebarWidth: CGFloat
    let topExtension: CGFloat
    /// The effect's global origin, to bring the tab into local space.
    let origin: CGPoint
    let join: IntegratedTabJoin?
    let gaps: PaneCardGaps?
    /// The tabs on screen, whose split gaps the effect leaves to the backdrop.
    let gapTabIDs: [UUID]

    @State private var tracker = IntegratedTabJoinTracker()

    func body(content: Content) -> some View {
        let local = { (rect: CGRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        if join == nil && !roundedPanes {
            content
        } else {
            content
                .clipShape(TerminalEffectWindowShape(
                    sidebarWidth: sidebarWidth,
                    topExtension: topExtension,
                    roundedPanes: roundedPanes,
                    tabRect: join == nil ? nil : tracker.rect.map(local),
                    clip: join == nil ? nil : tracker.clip.map(local),
                    gaps: roundedPanes ? localGaps : nil))
                .onAppear { if let join { tracker.track(join) } }
                .onChange(of: join.map { ObjectIdentifier($0) }) { _, _ in
                    if let join { tracker.track(join) }
                }
        }
    }

    private var localGaps: Path? {
        guard let gaps else { return nil }
        let paths = gapTabIDs.compactMap { gaps.paths[$0] }
        guard !paths.isEmpty else { return nil }
        var path = Path()
        for gap in paths { path.addPath(Path(gap)) }
        return path.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

/// Each tab's Rounded Panes split gaps in window space, pushed by its split
/// view, so the window-wide effect paints only the cards.
@Observable
final class PaneCardGaps {
    private(set) var paths: [UUID: CGPath] = [:]
    @ObservationIgnored private var owners: [UUID: ObjectIdentifier] = [:]

    /// A rebuilt split view can push before its predecessor is torn down, so
    /// only the current owner clears a tab.
    func update(_ path: CGPath?, for tabID: UUID, from owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        if path == nil, owners[tabID] != ownerID { return }
        owners[tabID] = path == nil ? nil : ownerID
        guard paths[tabID] != path else { return }
        paths[tabID] = path
    }
}

extension View {
    /// Theme fills behind the terminal: full bleed normally, the terminal
    /// card under Rounded Panes so they never square off its corners.
    @ViewBuilder
    func cardFillExtent(_ rounded: Bool) -> some View {
        if rounded {
            clipShape(PaneCardStyle.shape(rounded: true))
        } else {
            ignoresSafeArea()
        }
    }
}

// MARK: - Depth

extension IntegratedTabEdgePalette {
    /// A card's rim derives from its own surface, as the integrated tab edge does.
    init(cardSurface: Color) {
        self.init(surfaceColor: cardSurface, isLightTheme: cardSurface.isLight)
    }
}

/// Rounded Panes depth for a SwiftUI card: a top-lit hairline rim.
private struct PaneCardDepth<CardShape: InsettableShape>: ViewModifier {
    let isEnabled: Bool
    let shape: CardShape
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        if isEnabled {
            content.overlay { rim }
        } else {
            content
        }
    }

    private var rim: some View {
        let keyline = palette.keyline(increasedContrast: colorSchemeContrast == .increased)
        return shape
            .strokeBorder(
                LinearGradient(
                    colors: [keyline, keyline.opacity(PaneCardStyle.rimBottomFraction)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: IntegratedTabEdgeMetrics.lineWidth(for: displayScale))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func paneCardDepth(_ isEnabled: Bool, shape: some InsettableShape, palette: IntegratedTabEdgePalette) -> some View {
        modifier(PaneCardDepth(isEnabled: isEnabled, shape: shape, palette: palette))
    }
}

/// A SwiftUI card's rim drawn by `CardRimView`, so it opens under a joined
/// Integrated tab as the split view's does. Covers the whole card.
struct JoinedCardRim: UIViewRepresentable {
    let palette: IntegratedTabEdgePalette
    let integratedTabJoin: IntegratedTabJoin?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeUIView(context: Context) -> JoinedCardRimView {
        JoinedCardRimView()
    }

    func updateUIView(_ uiView: JoinedCardRimView, context: Context) {
        uiView.palette = palette
        uiView.increasedContrast = colorSchemeContrast == .increased
        uiView.integratedTabJoin = integratedTabJoin
        uiView.updateRim()
    }

    static func dismantleUIView(_ uiView: JoinedCardRimView, coordinator: ()) {
        uiView.integratedTabJoin = nil
    }
}

final class JoinedCardRimView: UIView, IntegratedTabJoinObserver {
    var palette: IntegratedTabEdgePalette = .fallback
    var increasedContrast = false
    var integratedTabJoin: IntegratedTabJoin? {
        didSet {
            guard oldValue !== integratedTabJoin else { return }
            oldValue?.removeObserver(self)
            integratedTabJoin?.addObserver(self)
        }
    }

    private let rim = CardRimView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(rim)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateRim()
    }

    // The opening is converted from window coordinates.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRim()
    }

    func integratedTabJoinDidChange() {
        updateRim()
    }

    func updateRim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        rim.frame = bounds
        let opening: ClosedRange<CGFloat>? = integratedTabJoin?.rect.flatMap { tabRect in
            guard window != nil else { return nil }
            let rect = convert(tabRect, from: nil)
            return rect.minX...rect.maxX
        }
        rim.update(
            cards: bounds.isEmpty ? [] : [bounds],
            color: UIColor(palette.keyline(increasedContrast: increasedContrast))
                .resolvedColor(with: traitCollection),
            lineWidth: 1 / max(1, traitCollection.displayScale),
            opening: opening,
            openingEdgeY: bounds.minY)
    }
}
