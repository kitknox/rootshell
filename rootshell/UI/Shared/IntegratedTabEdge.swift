//
//  IntegratedTabEdge.swift
//  rootshell
//
//  The Integrated style's border: a hairline running the window's full width
//  along the strip/terminal boundary and up around the active tab.
//
//  The ordinary keyline uses two pieces so no tab frame has to reach the strip.
//  They join because both are the same hairline and the shoulder curves are
//  tangent to horizontal exactly where the rule lives. OSC progress adds a
//  transient compound foreground path over those same segments.
//

import SwiftUI
import UIKit
import GhosttyKit

// MARK: - Metrics

enum IntegratedTabEdgeMetrics {
    /// One physical pixel. Anything heavier reads as a drawn box, not an edge.
    static func lineWidth(for displayScale: CGFloat) -> CGFloat {
        1 / max(1, displayScale)
    }

    /// OSC progress needs extra visual weight on an iPhone's smaller display,
    /// while the ordinary integrated edge remains a one-pixel hairline.
    static func progressLineWidth(for displayScale: CGFloat, isPhone: Bool) -> CGFloat {
        (isPhone ? 2 : 1) / max(1, displayScale)
    }

    /// For layouts reserving room before a display scale is available (1x case).
    static let reservedThickness: CGFloat = 1
}

/// Theme-derived optical colors for the integrated edge.
///
/// The old white/black alpha stroke inherited some color from its backdrop,
/// but blending toward an achromatic endpoint washed chromatic themes toward
/// gray. These colors are resolved from the terminal surface itself, so a
/// blue-purple surface such as Catppuccin Mocha keeps that hue in its rim.
struct IntegratedTabEdgePalette: Equatable {
    let surfaceColor: Color?
    let isLightTheme: Bool

    static let fallback = IntegratedTabEdgePalette(
        surfaceColor: nil,
        isLightTheme: false
    )

    func keyline(increasedContrast: Bool) -> Color {
        guard let surfaceColor else {
            return Color(uiColor: .separator)
        }
        if isLightTheme {
            return surfaceColor.darkenedPreservingHue(increasedContrast ? 0.36 : 0.26)
        }
        return surfaceColor.lightenedPreservingHue(increasedContrast ? 0.42 : 0.32)
    }
}

// MARK: - Shared silhouette geometry

/// Silhouette metrics, shared by the opaque fill (`BrowserTabShape`) and the
/// hairline outline so the two can never drift. Built for a top bar; a bottom
/// bar's paths are mirrored about the row's middle.
struct IntegratedTabGeometry {
    /// Tab body below the narrow strip of frame left visible above the tab.
    let tabRect: CGRect
    /// Wider than tall: a 1:1 corner reads as a sharp hook at Retina scale.
    let shoulderWidth: CGFloat
    let shoulderHeight: CGFloat
    let cornerRadius: CGFloat
    private let mirrorTransform: CGAffineTransform

    static let bezierKappa: CGFloat = 0.552_284_8

    init(in rect: CGRect, position: TabBarPosition = .top) {
        let topInset = min(5, rect.height * 0.12)
        tabRect = CGRect(
            x: rect.minX,
            y: rect.minY + topInset,
            width: rect.width,
            height: max(0, rect.height - topInset)
        )
        shoulderWidth = min(16, tabRect.width * 0.12)
        shoulderHeight = min(10, tabRect.height * 0.28)
        cornerRadius = min(10, tabRect.height * 0.28)
        mirrorTransform = Self.mirror(about: rect, position: position)
    }

    /// Flips a top-bar path into a bottom bar's `rect`.
    static func mirror(about rect: CGRect, position: TabBarPosition) -> CGAffineTransform {
        position == .bottom ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY) : .identity
    }

    /// Left shoulder → top → right shoulder, open at the bottom. `bottomInset`
    /// lifts the ends so a stroked copy lands on the rule's band, inside the row.
    func outlinePath(bottomInset: CGFloat = 0) -> Path {
        let bottom = tabRect.maxY - bottomInset
        var path = Path()
        path.move(to: CGPoint(x: tabRect.minX, y: bottom))
        appendOutline(to: &path, bottomInset: bottomInset)
        return path.applying(mirrorTransform)
    }

    /// Appends the outline after its starting point. Keeping the segment writer
    /// separate lets the OSC progress renderer splice the same tab curve into a
    /// single window-wide path without duplicating or approximating geometry.
    private func appendOutline(to path: inout Path, bottomInset: CGFloat) {
        let bottom = tabRect.maxY - bottomInset
        let kappa = Self.bezierKappa
        path.addCurve(
            to: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight
            ),
            control1: CGPoint(
                x: tabRect.minX + shoulderWidth * kappa,
                y: bottom
            ),
            control2: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            )
        )
        path.addLine(to: CGPoint(
            x: tabRect.minX + shoulderWidth,
            y: tabRect.minY + cornerRadius
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.minX + shoulderWidth + cornerRadius, y: tabRect.minY),
            control: CGPoint(x: tabRect.minX + shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth - cornerRadius,
            y: tabRect.minY
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY + cornerRadius),
            control: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth,
            y: bottom - shoulderHeight
        ))
        path.addCurve(
            to: CGPoint(x: tabRect.maxX, y: bottom),
            control1: CGPoint(
                x: tabRect.maxX - shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            ),
            control2: CGPoint(
                x: tabRect.maxX - shoulderWidth * kappa,
                y: bottom
            )
        )
    }

    /// Continuous strip edge used by OSC progress: horizontal rule, active-tab
    /// outline, then horizontal rule. The ordinary edge remains split into its
    /// existing rule/outline views; this path is only the colored foreground.
    static func progressEdgePath(
        in rowRect: CGRect,
        activeTabRect: CGRect,
        bottomInset: CGFloat,
        span: ClosedRange<CGFloat>? = nil,
        position: TabBarPosition = .top
    ) -> Path {
        // Traced as a top bar, then mirrored as a whole.
        let rowMirror = mirror(about: rowRect, position: position)
        let geometry = IntegratedTabGeometry(in: activeTabRect.applying(rowMirror))
        // Rounded Panes: run only along the terminal card's straight edge.
        let span = span ?? rowRect.minX...rowRect.maxX
        let baseline = rowRect.maxY - bottomInset
        let tabBottom = geometry.tabRect.maxY - bottomInset
        var path = Path()
        path.move(to: CGPoint(x: span.lowerBound, y: baseline))
        path.addLine(to: CGPoint(x: geometry.tabRect.minX, y: tabBottom))
        geometry.appendOutline(to: &path, bottomInset: bottomInset)
        path.addLine(to: CGPoint(x: span.upperBound, y: baseline))
        return path.applying(rowMirror)
    }

    /// Closed silhouette for the opaque fill. Its open edge stays flush so
    /// matching the terminal background reads as one connected surface.
    var silhouettePath: Path {
        var path = outlinePath()
        path.closeSubpath()
        return path
    }
}

// MARK: - Active-tab geometry

/// The selected integrated tab contributes its bounds to the row so the OSC
/// foreground can trace one continuous path without publishing frames into
/// `MainView` state on every scrolling-tab layout pass.
struct IntegratedActiveTabBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Joined card rim

protocol IntegratedTabJoinObserver: AnyObject {
    func integratedTabJoinDidChange()
}

/// The selected tab's frame in window coordinates while Integrated tabs join
/// Rounded Panes cards or window a background effect, updated every frame of
/// its selection slide. Card rims (split views, the exposé, full-size panels)
/// open their top edge there. `MainView` never reads it, so tab-strip
/// scrolling never invalidates it.
final class IntegratedTabJoin {
    private(set) var rect: CGRect?
    /// The scrolling track's visible bounds, which clip the tab.
    private(set) var clip: CGRect?
    /// Where the bar sits, so rims open their top or bottom edge.
    private(set) var position: TabBarPosition = .top
    private let observers = NSHashTable<AnyObject>.weakObjects()

    func update(_ newRect: CGRect?, position newPosition: TabBarPosition? = nil) {
        let newPosition = newPosition ?? position
        guard rect != newRect || position != newPosition else { return }
        rect = newRect
        position = newPosition
        notify()
    }

    func updateClip(_ newClip: CGRect?) {
        guard clip != newClip else { return }
        clip = newClip
        notify()
    }

    private func notify() {
        for case let observer as IntegratedTabJoinObserver in observers.allObjects {
            observer.integratedTabJoinDidChange()
        }
    }

    func addObserver(_ observer: IntegratedTabJoinObserver) {
        observers.add(observer)
    }

    func removeObserver(_ observer: IntegratedTabJoinObserver) {
        observers.remove(observer)
    }
}

/// Mirrors an `IntegratedTabJoin` for the SwiftUI view that reads it, so only
/// that view updates as the tab moves.
@Observable
final class IntegratedTabJoinTracker: IntegratedTabJoinObserver {
    private(set) var rect: CGRect?
    private(set) var clip: CGRect?
    private(set) var position: TabBarPosition = .top
    @ObservationIgnored private weak var join: IntegratedTabJoin?

    func track(_ newJoin: IntegratedTabJoin) {
        guard join !== newJoin else { return }
        join?.removeObserver(self)
        join = newJoin
        newJoin.addObserver(self)
        integratedTabJoinDidChange()
    }

    func integratedTabJoinDidChange() {
        if rect != join?.rect { rect = join?.rect }
        if clip != join?.clip { clip = join?.clip }
        if let join, position != join.position { position = join.position }
    }
}

/// Bounds of the scrolling tab track, which clips the selected tab.
struct IntegratedTabTrackBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Shapes

/// Open path, to be stroked. Not pre-stroked via `strokedPath`: a ribbon's two
/// antialiased edges interfere at hairline width and speckle the shoulders.
struct IntegratedTabOutlineShape: Shape {
    var bottomInset: CGFloat
    var position: TabBarPosition = .top

    func path(in rect: CGRect) -> Path {
        IntegratedTabGeometry(in: rect, position: position).outlinePath(bottomInset: bottomInset)
    }
}

/// The horizontal run along the strip/terminal boundary. Centered on the same
/// band as `IntegratedTabOutlineShape`'s open ends so the two abut without a step.
/// `gap` leaves it open under a translucent tab, which cannot occlude it.
struct IntegratedTabEdgeRule: Shape {
    var lineWidth: CGFloat
    var gap: ClosedRange<CGFloat>?
    var position: TabBarPosition = .top

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(gap?.lowerBound ?? 0, gap?.upperBound ?? 0) }
        set { if gap != nil { gap = newValue.first...max(newValue.first, newValue.second) } }
    }

    func path(in rect: CGRect) -> Path {
        let y = position == .bottom ? rect.minY : rect.maxY - lineWidth
        guard let gap, gap.lowerBound < rect.maxX, gap.upperBound > rect.minX else {
            return Path(CGRect(x: rect.minX, y: y, width: rect.width, height: lineWidth))
        }
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: y, width: max(0, gap.lowerBound - rect.minX), height: lineWidth))
        path.addRect(CGRect(x: gap.upperBound, y: y, width: max(0, rect.maxX - gap.upperBound), height: lineWidth))
        return path
    }
}

// MARK: - Views

/// The separator across the strip. Keeping this to exactly one physical pixel
/// prevents the shallow active-tab shoulders from appearing to dip below it.
struct IntegratedTabEdgeRuleView: View {
    let palette: IntegratedTabEdgePalette
    var gap: ClosedRange<CGFloat>?
    var position: TabBarPosition = .top

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        IntegratedTabEdgeRule(lineWidth: lineWidth, gap: gap, position: position)
            .fill(palette.keyline(increasedContrast: increasedContrast))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Paints the rule's band out across the tab, in the tab's own fill. At the
/// shoulder tips the silhouette has not yet climbed clear of that band, so rule
/// and outline would overlap there and composite to double density.
struct IntegratedTabEdgeOccluder<Fill: View>: View {
    let fill: Fill
    var position: TabBarPosition = .top

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        fill
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(alignment: position == .bottom ? .top : .bottom) {
                Rectangle().frame(height: IntegratedTabEdgeMetrics.lineWidth(for: displayScale))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The tab's raised edge. A single physical-pixel chromatic stroke keeps its
/// shoulder endpoints flush with the rule without a simulated crest artifact.
struct IntegratedTabOutlineView: View {
    let palette: IntegratedTabEdgePalette
    var position: TabBarPosition = .top
    /// A bottom tab joining a card continues its dimmer lower rim.
    var opacity: Double = 1

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        let keyline = palette.keyline(increasedContrast: increasedContrast).opacity(opacity)
        IntegratedTabOutlineShape(bottomInset: lineWidth / 2, position: position)
            .stroke(
                keyline,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            // The path already ends one half-line-width above the boundary;
            // clipping makes that containment explicit to the renderer.
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - OSC progress foreground

/// Isolates observation of the focused terminal's high-rate OSC progress state
/// from `MainView`. Core Animation owns the bouncing segment, so no display-link
/// updates enter SwiftUI's view graph.
struct IntegratedOSCProgressEdgeHost: View {
    @ObservedObject var terminalView: Ghostty.TerminalView
    let activeTabRect: CGRect
    let rowSize: CGSize
    var span: ClosedRange<CGFloat>?
    var position: TabBarPosition = .top
    let selectedTabID: UUID
    let animateSelectionChanges: Bool

    @Environment(\.displayScale) private var displayScale
    #if !os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var usesCompactStroke: Bool {
        #if os(visionOS)
        false
        #else
        horizontalSizeClass != .regular
        #endif
    }

    var body: some View {
        if let report = terminalView.progressReport, report.state != .remove {
            let lineWidth = IntegratedTabEdgeMetrics.progressLineWidth(
                for: displayScale,
                isPhone: usesCompactStroke
            )
            let path = IntegratedTabGeometry.progressEdgePath(
                in: CGRect(origin: .zero, size: rowSize),
                activeTabRect: activeTabRect,
                bottomInset: lineWidth / 2,
                span: span,
                position: position
            )
            IntegratedOSCProgressLayerView(
                path: path.cgPath,
                lineWidth: lineWidth,
                report: report,
                selectedTabID: selectedTabID,
                animateSelectionChanges: animateSelectionChanges
            )
        }
    }
}

private struct IntegratedOSCProgressLayerView: UIViewRepresentable {
    let path: CGPath
    let lineWidth: CGFloat
    let report: Ghostty.Action.ProgressReport
    let selectedTabID: UUID
    let animateSelectionChanges: Bool

    func makeUIView(context: Context) -> IntegratedOSCProgressLayerUIView {
        IntegratedOSCProgressLayerUIView()
    }

    func updateUIView(_ view: IntegratedOSCProgressLayerUIView, context: Context) {
        view.configure(
            path: path,
            lineWidth: lineWidth,
            report: report,
            selectedTabID: selectedTabID,
            animateSelectionChanges: animateSelectionChanges
        )
    }

    static func dismantleUIView(_ view: IntegratedOSCProgressLayerUIView, coordinator: ()) {
        view.stopAnimation()
    }
}

/// A single stroked layer means `strokeStart` / `strokeEnd` naturally measure
/// progress across the rule and the longer curved detour around the active tab.
private final class IntegratedOSCProgressLayerUIView: UIView {
    private let progressLayer = CAShapeLayer()
    private var selectedTabID: UUID?
    private var lastPath: CGPath?
    private var isBouncing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = true

        progressLayer.fillColor = nil
        progressLayer.lineCap = .butt
        progressLayer.lineJoin = .round
        layer.addSublayer(progressLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressLayer.frame = bounds
    }

    func configure(
        path: CGPath,
        lineWidth: CGFloat,
        report: Ghostty.Action.ProgressReport,
        selectedTabID newSelectedTabID: UUID,
        animateSelectionChanges: Bool
    ) {
        let selectionChanged = selectedTabID != nil && selectedTabID != newSelectedTabID
        selectedTabID = newSelectedTabID

        let oldPath = progressLayer.presentation()?.path
            ?? progressLayer.path
            ?? lastPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.lineWidth = lineWidth
        progressLayer.strokeColor = Self.color(for: report.state).cgColor
        progressLayer.path = path
        lastPath = path

        switch report.state {
        case .set:
            stopAnimation()
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = CGFloat(report.progress ?? 0) / 100
        case .indeterminate, .error, .pause:
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 0.25
            startAnimationIfNeeded()
        case .remove:
            stopAnimation()
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 0
        }
        CATransaction.commit()

        if selectionChanged, animateSelectionChanges, let oldPath {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = path
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.add(animation, forKey: "integrated-tab-selection-path")
        }
    }

    private static func color(for state: Ghostty.Action.ProgressReport.State) -> UIColor {
        switch state {
        case .error:
            return .systemRed
        case .pause:
            return .systemOrange
        default:
            return .systemBlue
        }
    }

    private func startAnimationIfNeeded() {
        guard !isBouncing else { return }
        isBouncing = true

        let starts = CAKeyframeAnimation(keyPath: "strokeStart")
        starts.values = [0, 0.75, 0]
        starts.keyTimes = [0, 0.5, 1]
        starts.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        let ends = CAKeyframeAnimation(keyPath: "strokeEnd")
        ends.values = [0.25, 1, 0.25]
        ends.keyTimes = [0, 0.5, 1]
        ends.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        let group = CAAnimationGroup()
        group.animations = [starts, ends]
        group.duration = 2.4
        group.repeatCount = .infinity
        progressLayer.add(group, forKey: "osc-progress-bounce")
    }

    fileprivate func stopAnimation() {
        progressLayer.removeAnimation(forKey: "osc-progress-bounce")
        isBouncing = false
    }
}

// MARK: - Rounded Panes

private struct IntegratedTabJoinsCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Rounded Panes: the selected tab merges into a card, whose rim opens
    /// beneath it, so it drops the rule occluder.
    var integratedTabJoinsCard: Bool {
        get { self[IntegratedTabJoinsCardKey.self] }
        set { self[IntegratedTabJoinsCardKey.self] = newValue }
    }
}

/// Publishes the joined tab's frame from inside SwiftUI's animation, so card
/// rims open under the tab on every frame of its selection slide, interrupted
/// springs included.
struct IntegratedTabJoinPublisher: View, Animatable {
    var rect: CGRect
    let join: IntegratedTabJoin
    var position: TabBarPosition = .top

    nonisolated var animatableData: CGRect.AnimatableData {
        get { rect.animatableData }
        set { rect.animatableData = newValue }
    }

    var body: some View {
        let _ = join.update(rect, position: position)
        Color.clear
    }
}

// MARK: - Surface under the tab

/// How a pane background reads behind the selected tab: at the opacity the
/// terminal draws at, over whatever shows through the terminal.
struct IntegratedSurfaceStyle: Equatable {
    var opacity: Double = 1
    /// A translucent Mac window shows the desktop through the terminal, so the
    /// tab erases the opaque strip beneath it to show the same.
    var erasesBeneath = false

    func color(for base: Color) -> Color {
        opacity < 1 ? base.opacity(opacity) : base
    }

    var isTranslucent: Bool { opacity < 0.999 }
}

/// Each tab's top- and bottom-row pane backgrounds, pushed by its split view,
/// so the selected tab can paint exactly what sits beside it.
@Observable
final class IntegratedTabSurface {
    struct Segment: Equatable {
        /// Host-local x-range of an edge-row pane.
        var minX: CGFloat
        var maxX: CGFloat
        var color: UIColor
    }

    struct Host: Equatable {
        /// On-screen window x of the host's leading edge.
        var originX: CGFloat
        var segments: [Segment]
        var bottomSegments: [Segment]
    }

    private(set) var hosts: [UUID: Host] = [:]
    @ObservationIgnored private var owners: [UUID: ObjectIdentifier] = [:]

    /// A rebuilt split view can push before its predecessor is torn down, so
    /// only the current owner clears a tab.
    func update(_ host: Host?, for tabID: UUID, from owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        if host == nil, owners[tabID] != ownerID { return }
        owners[tabID] = host == nil ? nil : ownerID
        guard hosts[tabID] != host else { return }
        hosts[tabID] = host
    }

    /// Window-space color runs across `tabIDs`, contiguous from -∞ to +∞ and
    /// split midway across gaps such as dividers.
    func runs(for tabIDs: [UUID], position: TabBarPosition = .top) -> [(minX: CGFloat, maxX: CGFloat, color: UIColor)] {
        var segments = tabIDs.compactMap { hosts[$0] }.flatMap { host in
            (position == .bottom ? host.bottomSegments : host.segments)
                .map { (minX: host.originX + $0.minX, maxX: host.originX + $0.maxX, color: $0.color) }
        }
        segments.sort { $0.minX < $1.minX }
        var runs: [(minX: CGFloat, maxX: CGFloat, color: UIColor)] = []
        for (index, segment) in segments.enumerated() {
            let minX = index == 0 ? -.infinity : (segments[index - 1].maxX + segment.minX) / 2
            let maxX = index == segments.count - 1 ? .infinity : (segment.maxX + segments[index + 1].minX) / 2
            // One run per color, or translucent neighbors seam where they meet.
            if let last = runs.last, last.color == segment.color {
                runs[runs.count - 1].maxX = maxX
            } else {
                runs.append((minX, maxX, segment.color))
            }
        }
        return runs
    }
}

/// What the selected Integrated tab paints: the panes on screen beneath it,
/// or a panel or exposé backdrop that covers them.
struct IntegratedTabSurfaceFill {
    let surface: IntegratedTabSurface
    let tabIDs: [UUID]
    let style: IntegratedSurfaceStyle
    let override: Color?
    var position: TabBarPosition = .top
}

private struct IntegratedTabSurfaceFillKey: EnvironmentKey {
    static let defaultValue: IntegratedTabSurfaceFill? = nil
}

extension EnvironmentValues {
    var integratedTabSurfaceFill: IntegratedTabSurfaceFill? {
        get { self[IntegratedTabSurfaceFillKey.self] }
        set { self[IntegratedTabSurfaceFillKey.self] = newValue }
    }
}

/// The selected tab's fill. Runs are window-space, so they stay put under the
/// tab as it slides or the strip scrolls.
struct IntegratedTabSurfaceFillView: View {
    let fallback: Color
    @Environment(\.integratedTabSurfaceFill) private var fill

    var body: some View {
        let runs = fill.map { $0.surface.runs(for: $0.tabIDs, position: $0.position) } ?? []
        if let override = fill?.override {
            Rectangle().fill(override)
        } else if let fill, !runs.isEmpty {
            GeometryReader { proxy in
                let originX = proxy.frame(in: .global).minX
                Canvas { context, size in
                    for run in runs {
                        let minX = max(0, run.minX - originX)
                        let maxX = min(size.width, run.maxX - originX)
                        guard maxX > minX else { continue }
                        context.fill(
                            Path(CGRect(x: minX, y: 0, width: maxX - minX, height: size.height)),
                            with: .color(fill.style.color(for: Color(uiColor: run.color))))
                    }
                }
            }
        } else {
            Rectangle().fill(fallback)
        }
    }
}
