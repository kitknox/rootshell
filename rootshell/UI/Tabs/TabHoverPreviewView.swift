//
//  TabHoverPreviewView.swift
//  rootshell
//
//  The hover preview card: a glass slab holding a live mirror of one tab and
//  a caption. Added to the window directly so it floats above the tab bar,
//  the sidebar overlay and the terminal alike; positioned from an anchor rect
//  in window coordinates (below a top tab, beside a sidebar row). The
//  controller drives every state change; this view only draws and animates.
//

import UIKit
import SwiftUI

@MainActor
final class TabHoverPreviewView: UIView {
    struct Style {
        /// Terminal background behind the mirrored pixels.
        var backgroundColor: UIColor = .black
        /// Window background opacity (macOS transparency); 1 = opaque.
        var backgroundOpacity: CGFloat = 1
        var isLight = false
        var accentColor: UIColor = .tintColor
    }

    typealias Edge = TabHoverPreviewEdge

    var onTap: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isVisible = false
    /// Click-through to the exposé is offered (hint shown, tap handled).
    private(set) var canEnterExpose = true

    private let mirror = TabPreviewMirrorView()
    private let picture = UIView()
    private let placeholder = UIImageView()
    private let chromeHost = UIHostingController(rootView: TabHoverPreviewChrome(cornerRadius: 14))
    private var captionHost: UIHostingController<AnyView>?
    private var caption: AnyView?
    private var hintVisible = false
    private var zoomText: String?
    private var zoomReadoutTask: Task<Void, Never>?

    private var anchor: CGRect = .zero
    private var edge: Edge = .below
    private var zoom: CGFloat = 1
    private var metrics = TabHoverPreviewLayout.Metrics.standard(mac: false)
    /// Increments on every present / dismiss so a stale completion is inert.
    private var generation = 0
    /// Slide / resize in flight, stepped from the controller's display link
    /// (a UIView frame animation would fight the per-tick mirror sync: the
    /// mirror lays out for its model bounds while the clip animates).
    private var frameAnimation: (start: CGRect, target: CGRect, t: CGFloat, velocity: CGFloat, response: CGFloat)?
    private var lastStepTime: CFTimeInterval = 0
    private var isHandingOff = false
    private var handoffStart: CGRect = .zero
    private var handoffStartRadius: CGFloat = 0

    init() {
        super.init(frame: .zero)
        #if targetEnvironment(macCatalyst)
        metrics = .standard(mac: true)
        #else
        metrics = .standard(mac: false)
        #endif
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens Tab Exposé", comment: "Tab hover preview accessibility hint")

        chromeHost.view.backgroundColor = .clear
        chromeHost.view.isUserInteractionEnabled = false
        // The card floats in the window; its hosts must not inset for the
        // status bar / titlebar the card may overlap.
        chromeHost.safeAreaRegions = []
        addSubview(chromeHost.view)

        picture.clipsToBounds = true
        picture.layer.cornerCurve = .continuous
        picture.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        picture.isUserInteractionEnabled = false
        picture.addSubview(mirror)
        addSubview(picture)

        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
        placeholder.image = UIImage(systemName: "terminal", withConfiguration: config)
        placeholder.contentMode = .center
        placeholder.isHidden = true
        picture.addSubview(placeholder)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        #if !os(visionOS)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    private var animationsSuspended = false
    private var dismissalPending = false

    func suspendAnimations() {
        guard !animationsSuspended else { return }
        animationsSuspended = true
        zoomReadoutTask?.cancel()
        zoomText = nil
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    func resumeAnimations() {
        guard animationsSuspended, !Ghostty.isSecureDrawProhibitedAtomic else { return }
        animationsSuspended = false
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        lastStepTime = 0
        updateCaption()
    }

    func finishPendingDismissal() {
        guard dismissalPending, !Ghostty.isSecureDrawProhibitedAtomic else { return }
        dismissalPending = false
        generation += 1 // Invalidate an animation completion from before lock.
        layer.removeAllAnimations()
        removeFromSuperview()
        mirror.releaseContents()
        caption = nil
        updateCaption()
        transform = .identity
        isHandingOff = false
    }

    /// Show for `tab` (first appearance), or slide/resize to it when already up.
    func present(
        tab: TabModel,
        caption: AnyView?,
        anchor: CGRect,
        edge: Edge,
        in window: UIWindow,
        style: Style,
        zoom: CGFloat,
        canEnterExpose: Bool = true,
        animated: Bool
    ) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        dismissalPending = false
        generation += 1
        zoomReadoutTask?.cancel()
        zoomText = nil
        isHandingOff = false
        isUserInteractionEnabled = true
        self.canEnterExpose = canEnterExpose
        accessibilityTraits = canEnterExpose ? .button : .staticText
        let resumes = superview === window && alpha > 0.01
        if superview !== window { window.addSubview(self) } else { window.bringSubviewToFront(self) }

        self.anchor = anchor
        self.edge = edge
        self.zoom = zoom
        mirror.tab = tab
        placeholder.isHidden = tab.splitTree.first?.enclosingSplitHost != nil
        accessibilityLabel = String(localized: "Preview of \(tab.title)", comment: "Tab hover preview accessibility label")
        applyStyle(style)
        self.caption = caption
        updateCaption()

        let target = resolvedFrame()
        chromeHost.view.alpha = 1
        captionHost?.view.alpha = 1
        if resumes {
            // Slide over to the neighbor; alpha / transform only need
            // restoring if a dismissal was cut short.
            layer.removeAllAnimations()
            if animated {
                animateFrame(to: target, response: 0.32)
                UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.alpha = 1
                    self.transform = .identity
                }
            } else {
                frameAnimation = nil
                apply(frame: target)
                alpha = 1
                transform = .identity
            }
        } else {
            frameAnimation = nil
            apply(frame: target)
            mirror.sync()
            alpha = 0
            transform = appearTransform()
            if animated {
                UIView.animate(
                    withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.4,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.alpha = 1
                    self.transform = .identity
                }
            } else {
                alpha = 1
                transform = .identity
            }
        }
        isVisible = true
    }

    func dismiss(animated: Bool) {
        guard isVisible else { return }
        isVisible = false
        dismissalPending = true
        generation += 1
        let gen = generation
        zoomReadoutTask?.cancel()
        hintVisible = false
        frameAnimation = nil
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        let finish = {
            guard self.generation == gen else { return }
            self.finishPendingDismissal()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.alpha = 0
            if !self.isHandingOff {
                self.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            }
        } completion: { _ in
            finish()
        }
    }

    /// Per tick: follow the tab if the bar scrolled or reflowed (and the
    /// terminal's aspect if the window resized).
    func updateAnchor(_ anchor: CGRect) {
        guard !isHandingOff else { return }
        self.anchor = anchor
        let target = resolvedFrame()
        if frameAnimation != nil {
            frameAnimation?.target = target
            return
        }
        guard target != currentFrame() else { return }
        apply(frame: target)
    }

    /// Per tick: advance a slide / resize spring.
    func step(now: CFTimeInterval) {
        guard var animation = frameAnimation else {
            lastStepTime = 0
            return
        }
        let dt = lastStepTime == 0 ? 1.0 / 60.0 : min(max(now - lastStepTime, 0), 1.0 / 20.0)
        lastStepTime = now
        ExposeSpring.step(value: &animation.t, velocity: &animation.velocity, target: 1,
                          response: animation.response, damping: 0.86, dt: CGFloat(dt))
        if abs(animation.t - 1) < 0.002, abs(animation.velocity) < 0.01 {
            frameAnimation = nil
            apply(frame: animation.target)
        } else {
            frameAnimation = animation
            apply(frame: Self.lerp(animation.start, animation.target, animation.t))
        }
    }

    /// Refresh the live picture.
    func sync() {
        mirror.sync()
    }

    // MARK: - Zoom

    func setZoom(_ zoom: CGFloat, animated: Bool) {
        self.zoom = zoom
        let target = resolvedFrame()
        if animated {
            animateFrame(to: target, response: 0.24)
        } else {
            frameAnimation = nil
            apply(frame: target)
        }
    }

    func showZoomReadout(_ zoom: CGFloat) {
        zoomReadoutTask?.cancel()
        zoomText = "\(Int((zoom * 100).rounded()))%"
        updateCaption()
    }

    func hideZoomReadout(after seconds: Double) {
        zoomReadoutTask?.cancel()
        zoomReadoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.zoomText = nil
            self.updateCaption()
        }
    }

    // MARK: - Exposé hand-off

    /// The card sheds its chrome and becomes just the picture; `applyHandoff`
    /// then carries it into the exposé cell.
    func beginHandoff() {
        guard let window, !isHandingOff else { return }
        isHandingOff = true
        isUserInteractionEnabled = false
        frameAnimation = nil
        layer.removeAllAnimations()
        transform = .identity
        handoffStart = picture.convert(picture.bounds, to: window)
        handoffStartRadius = picture.layer.cornerRadius
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.chromeHost.view.alpha = 0
            self.captionHost?.view.alpha = 0
        }
    }

    /// `progress` is the exposé reveal (0 … 1); `target` the cell's resting
    /// preview frame in window coordinates, nil when the tab has no cell (the
    /// picture then simply fades on the way).
    func applyHandoff(progress: CGFloat, target: CGRect?, cornerRadius: CGFloat?) {
        guard isHandingOff else { return }
        let t = Self.smoothstep(progress)
        let frame = target.map { Self.lerp(handoffStart, $0, t) } ?? handoffStart
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: frame.size)
        center = CGPoint(x: frame.midX, y: frame.midY)
        picture.frame = bounds
        picture.layer.cornerRadius = handoffStartRadius + ((cornerRadius ?? handoffStartRadius) - handoffStartRadius) * t
        mirror.frame = picture.bounds
        placeholder.frame = picture.bounds
        chromeHost.view.frame = bounds
        // No cell to land on yet: fade on the way; if the exposé re-scopes
        // and one appears, ride it fully visible.
        alpha = target == nil ? 1 - t : 1
        CATransaction.commit()
    }

    // MARK: - Layout

    private func applyStyle(_ style: Style) {
        overrideUserInterfaceStyle = style.isLight ? .light : .dark
        let background = style.backgroundColor.withAlphaComponent(style.backgroundOpacity)
        picture.backgroundColor = background
        mirror.backgroundColor = background
        picture.layer.borderColor = (style.isLight ? UIColor.black : UIColor.white).withAlphaComponent(0.1).cgColor
        placeholder.tintColor = (style.isLight ? UIColor.black : UIColor.white).withAlphaComponent(0.3)
    }

    private var aspect: CGFloat {
        guard let host = mirror.tab?.splitTree.first?.enclosingSplitHost,
              host.bounds.width > 0, host.bounds.height > 0 else { return 16.0 / 10.0 }
        return host.bounds.width / host.bounds.height
    }

    /// Card frame in window coordinates for the current anchor, zoom and aspect.
    private func resolvedFrame() -> CGRect {
        guard let window else { return CGRect(origin: anchor.origin, size: .zero) }
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let pictureSize = TabHoverPreviewLayout.pictureSize(
            baseWidth: metrics.baseWidth, zoom: zoom, aspect: aspect,
            limit: CGSize(width: safe.width * 0.7, height: safe.height * 0.7)
        )
        let cardSize = CGSize(
            width: pictureSize.width + 2 * metrics.padding,
            height: pictureSize.height + metrics.padding + metrics.captionHeight
        )
        return TabHoverPreviewLayout.cardFrame(
            anchor: anchor, edge: edge, cardSize: cardSize, gap: metrics.gap(for: edge), within: safe
        )
    }

    private func currentFrame() -> CGRect {
        CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
               width: bounds.width, height: bounds.height)
    }

    /// bounds/center, not frame: the card carries the appear transform.
    private func apply(frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: frame.size)
        center = CGPoint(x: frame.midX, y: frame.midY)
        layoutContent()
        CATransaction.commit()
    }

    private func layoutContent() {
        let radius = metrics.cardRadius
        layer.cornerRadius = radius
        chromeHost.view.frame = bounds
        if chromeHost.rootView.cornerRadius != radius {
            chromeHost.rootView = TabHoverPreviewChrome(cornerRadius: radius)
        }
        let pictureFrame = CGRect(
            x: metrics.padding, y: metrics.padding,
            width: max(0, bounds.width - 2 * metrics.padding),
            height: max(0, bounds.height - metrics.padding - metrics.captionHeight)
        )
        picture.frame = pictureFrame
        picture.layer.cornerRadius = metrics.pictureRadius
        mirror.frame = picture.bounds
        placeholder.frame = picture.bounds
        captionHost?.view.frame = CGRect(
            x: 0, y: pictureFrame.maxY,
            width: bounds.width, height: metrics.captionHeight
        )
    }

    /// Start a spring from the current frame; `step(now:)` drives it.
    private func animateFrame(to target: CGRect, response: CGFloat) {
        let start = currentFrame()
        guard start != target else {
            frameAnimation = nil
            return
        }
        frameAnimation = (start: start, target: target, t: 0, velocity: 0, response: response)
        lastStepTime = 0
    }

    /// Starts a touch smaller and nudged toward the tab it belongs to.
    private func appearTransform() -> CGAffineTransform {
        let nudge: CGPoint
        switch edge {
        case .below: nudge = CGPoint(x: 0, y: -6)
        case .trailing: nudge = CGPoint(x: currentFrame().minX >= anchor.maxX ? -6 : 6, y: 0)
        }
        return CGAffineTransform(translationX: nudge.x, y: nudge.y).scaledBy(x: 0.96, y: 0.96)
    }

    // MARK: - Caption

    private func updateCaption() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        let row = AnyView(TabHoverPreviewCaptionRow(
            caption: caption, hintVisible: hintVisible && canEnterExpose, zoomText: zoomText
        ))
        if let captionHost {
            captionHost.rootView = row
        } else {
            let host = UIHostingController(rootView: row)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.safeAreaRegions = []
            addSubview(host.view)
            captionHost = host
            layoutContent()
        }
    }

    // MARK: - Input

    @objc private func handleTap() {
        guard isVisible, !isHandingOff, canEnterExpose else { return }
        onTap?()
    }

    #if !os(visionOS)
    @objc private func handleHover(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed:
            if !hintVisible {
                hintVisible = true
                updateCaption()
                onHoverChange?(true)
            }
        case .ended, .cancelled, .failed:
            if hintVisible {
                hintVisible = false
                updateCaption()
            }
            onHoverChange?(false)
        default:
            break
        }
    }
    #endif

    override func accessibilityActivate() -> Bool {
        guard canEnterExpose, let onTap else { return false }
        onTap()
        return true
    }

    // MARK: - Math

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}

// MARK: - Chrome

/// Glass on iOS 26 / Catalyst 26, material with a hairline and shadow before.
struct TabHoverPreviewChrome: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(visionOS)
        Color.clear.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            Color.clear
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        }
        #endif
    }
}

/// Title line plus a trailing slot: the exposé hint while the pointer is on
/// the card, or the size readout while pinching.
private struct TabHoverPreviewCaptionRow: View {
    let caption: AnyView?
    let hintVisible: Bool
    let zoomText: String?

    var body: some View {
        HStack(spacing: 8) {
            if let caption {
                caption
            }
            Spacer(minLength: 4)
            ZStack {
                if let zoomText {
                    Text(zoomText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hintVisible ? 0.9 : 0)
                        .accessibilityHidden(true)
                        .help(String(localized: "Show All Tabs", comment: "Tab hover preview: exposé hint tooltip"))
                }
            }
            .animation(.easeOut(duration: 0.15), value: hintVisible)
            .animation(.easeOut(duration: 0.15), value: zoomText)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Placement math

/// Which side of the anchor the card sits on: under a top tab, beside a sidebar row.
nonisolated enum TabHoverPreviewEdge: Equatable {
    case below
    case trailing
}

nonisolated struct TabHoverPreviewLayout {
    struct Metrics {
        /// Picture width at zoom 1.
        var baseWidth: CGFloat
        var padding: CGFloat
        var captionHeight: CGFloat
        var gapBelow: CGFloat
        var gapBeside: CGFloat
        var cardRadius: CGFloat
        var pictureRadius: CGFloat

        static func standard(mac: Bool) -> Metrics {
            Metrics(
                baseWidth: mac ? 300 : 280, padding: 6, captionHeight: 26,
                gapBelow: 6, gapBeside: 10, cardRadius: 14, pictureRadius: 9
            )
        }

        func gap(for edge: TabHoverPreviewEdge) -> CGFloat {
            edge == .below ? gapBelow : gapBeside
        }
    }

    /// Picture size for the tab's aspect, scaled by `zoom`, shrunk to fit `limit`.
    static func pictureSize(baseWidth: CGFloat, zoom: CGFloat, aspect: CGFloat, limit: CGSize) -> CGSize {
        let a = max(aspect, 0.2)
        var width = max(120, baseWidth * (zoom.isFinite ? zoom : 1))
        var height = width / a
        if limit.width > 0, width > limit.width {
            width = limit.width
            height = width / a
        }
        if limit.height > 0, height > limit.height {
            height = limit.height
            width = height * a
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Card frame next to `anchor` on `edge`, flipping to the opposite side
    /// when there is no room and sliding along the anchor to stay in `bounds`.
    static func cardFrame(
        anchor: CGRect, edge: TabHoverPreviewEdge, cardSize: CGSize, gap: CGFloat, within bounds: CGRect
    ) -> CGRect {
        let w = cardSize.width
        let h = cardSize.height
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            hi < lo ? lo : min(max(v, lo), hi)
        }
        switch edge {
        case .below:
            let x = clamp(anchor.midX - w / 2, bounds.minX, bounds.maxX - w)
            var y = anchor.maxY + gap
            if y + h > bounds.maxY {
                let above = anchor.minY - gap - h
                y = above >= bounds.minY ? above : clamp(y, bounds.minY, bounds.maxY - h)
            }
            return CGRect(x: x, y: y, width: w, height: h)
        case .trailing:
            let y = clamp(anchor.midY - h / 2, bounds.minY, bounds.maxY - h)
            var x = anchor.maxX + gap
            if x + w > bounds.maxX {
                let leading = anchor.minX - gap - w
                x = leading >= bounds.minX ? leading : clamp(x, bounds.minX, bounds.maxX - w)
            }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }
}
