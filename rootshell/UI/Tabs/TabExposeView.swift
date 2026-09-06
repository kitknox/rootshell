//
//  TabExposeView.swift
//  rootshell
//
//  The tab exposé overlay: an opaque backdrop, a full-size live mirror of the
//  hero tab that slides down as you pull, and a tray of live tab previews that
//  slides in from above to fill the space. Pure UIKit so the reveal can be
//  scrubbed per frame without invalidating SwiftUI; one display link steps
//  the controller's spring and refreshes the mirrors. Hosted as the top layer
//  of the terminal content area (`TabExposeHost`).
//
//  Group navigation pages horizontally like the regular tab swipe: the active
//  scope's tray follows the finger at `pageShift` while the neighbor scope's
//  tray sits one page over; release springs to commit or cancel.
//

import UIKit
import SwiftUI

@MainActor
final class TabExposeView: UIView, TabExposeControllerObserver {
    struct Configuration {
        /// User setting: two-finger / trackpad pull-down reveal.
        var gestureEnabled: () -> Bool = { true }
        /// No sheet, no in-flight tab swipe, etc.
        var canBeginReveal: () -> Bool = { true }
        /// Extra band into the terminal when nothing sits above it (tab bar hidden).
        /// Two-finger / trackpad only.
        var fallbackBandHeight: () -> CGFloat = { 0 }
        /// Height of the tab bar strip directly above the terminal where a
        /// one-finger pull may start (0 = no one-finger reveal).
        var oneFingerBandHeight: () -> CGFloat = { 0 }
        /// The visible top tab bar can extend across adjacent docked columns
        /// even though this view is hosted only over the terminal. When true,
        /// reveal and dismissal gestures that start above the terminal use the
        /// window's horizontal bounds instead of this view's bounds.
        var topBarActivationSpansWindowWidth: () -> Bool = { false }
        var trackpadGain: CGFloat = 2
    }

    struct Appearance {
        var backgroundColor: UIColor = .black
        /// Window background opacity (macOS transparency); 1 = opaque.
        var backgroundOpacity: CGFloat = 1
        var accentColor: UIColor = .systemBlue
        var textColor: UIColor = .white
        var showsCaptions: Bool = true
        /// Caption for a cell (title + badges); index is the navigation position.
        var captionProvider: ((TabModel, Int) -> AnyView)?
        /// Caption for a multiplexer tab cell.
        var muxCaptionProvider: ((MuxTab, Int) -> AnyView)?
    }

    let controller: TabExposeController
    var configuration = Configuration()
    var appearance = Appearance() {
        didSet { applyAppearance() }
    }

    private let backdrop = UIView()
    /// Punches the hero out of a translucent backdrop so the hero's own
    /// translucent background isn't stacked on a second fill.
    private let backdropMask = CAShapeLayer()
    private let hero = TabPreviewMirrorView()
    /// The live terminal host hidden behind the hero while translucent, so
    /// the backdrop sees the desktop rather than the terminal.
    private weak var concealedHost: UIView?
    /// The active scope's page.
    private var primary = TabExposeTrayView()
    /// A neighbor scope's page while a swipe / ⌘⌥[ ] is in flight.
    private var companion: TabExposeTrayView?
    /// +1: companion sits one page right of the primary; -1: left.
    private var companionSide = 0
    /// Primary's horizontal offset in points (companion at `pageShift + side * W`).
    private var pageShift: CGFloat = 0
    private var pageVelocity: CGFloat = 0
    /// Spring target for `pageShift`; nil while finger-driven or at rest.
    private var pageTarget: CGFloat?
    private var pageSpringFast = false
    private var lastPageTick: CFTimeInterval = 0
    private var scopeSwipeActive = false
    private var scopeSwipeBase: CGFloat = 0
    /// A committed swipe waits for the scope-changed announce until this.
    private var scopeCommitDeadline: CFTimeInterval = 0
    /// Fixed beneath the horizontally paging trays; informational only.
    private let pageControl = UIPageControl()

    private var heroRect: CGRect = .zero
    /// Highlight the tray was last scrolled to; see `tabExposeDidChangeCells`.
    private var lastScrolledHighlightID: UUID?
    private var displayLink: CADisplayLink?
    private var lastAppliedProgress: CGFloat = -1
    private var lastAppliedShift: CGFloat = 0
    private lazy var edgePan: InteractiveEdgePanRecognizer = makeEdgePan()
    private lazy var scopePan: InteractiveEdgePanRecognizer = makeScopePan()

    /// Preview scale (1 = auto-fit); loaded on activation, persisted on release.
    private var zoom: CGFloat = 1
    private var pinchAnchorZoom: CGFloat = 1
    private var zoomPinchActive = false
    private var zoomHUDHost: UIHostingController<TabExposeZoomHUD>?
    private var zoomHUDHideTask: Task<Void, Never>?

    init(controller: TabExposeController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.observer = self
        isHidden = true
        isUserInteractionEnabled = true
        clipsToBounds = true

        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        backdropMask.fillRule = .evenOdd
        addSubview(backdrop)
        addSubview(primary)

        pageControl.isUserInteractionEnabled = false
        pageControl.hidesForSinglePage = true
        pageControl.accessibilityTraits = .staticText
        addSubview(pageControl)

        hero.isUserInteractionEnabled = false
        hero.accessibilityElementsHidden = true
        addSubview(hero)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        // Touch pinch, iPad trackpad pinch, and Catalyst trackpad magnify
        // all arrive here; the default touch types include indirect input.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleZoomPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        #if !os(visionOS)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        #endif

        controller.previewFrameProvider = { [weak self] id in self?.restingPreview(for: id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
    }

    /// Where a tab's cell picture rests once fully revealed, in window
    /// coordinates: the hover preview card flies here when it opens the exposé.
    func restingPreview(for id: UUID) -> (frame: CGRect, cornerRadius: CGFloat)? {
        guard controller.isActive, !controller.showsMultiplexer, window != nil,
              let cell = primary.cells.first(where: { $0.tabID == id }) else { return nil }
        // Untransformed positions: the highlight scale and the reveal
        // translation both live in transforms, and the tray's bounds origin
        // is its scroll offset.
        let cellOrigin = CGPoint(x: cell.center.x - cell.bounds.width / 2, y: cell.center.y - cell.bounds.height / 2)
        let trayOrigin = CGPoint(x: primary.center.x - primary.bounds.width / 2, y: primary.center.y - primary.bounds.height / 2)
        let inSelf = CGRect(
            x: trayOrigin.x + cellOrigin.x - primary.bounds.origin.x,
            y: trayOrigin.y + cellOrigin.y - primary.bounds.origin.y,
            width: primary.layoutResult.cellSize.width,
            height: primary.layoutResult.cellSize.height
        )
        return (convert(inSelf, to: nil), cell.previewCornerRadius)
    }

    // MARK: - Hosting

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if !os(visionOS)
        edgePan.install(on: window)
        scopePan.install(on: window)
        #endif
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard controller.isActive else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - Controller observer

    func tabExposeDidChangeActivity(_ controller: TabExposeController) {
        if controller.isActive {
            isHidden = false
            accessibilityViewIsModal = true
            lastAppliedProgress = -1
            zoom = TabExposeSettings.zoom()
            resetPage()
            rebuildPrimary()
            setNeedsLayout()
            layoutIfNeeded()
            lastScrolledHighlightID = controller.highlightedTabID
            primary.scrollCellIntoView(id: controller.highlightedTabID, animated: false)
            startDisplayLink()
            if controller.wantsFirstResponderFallback {
                becomeFirstResponder()
            }
        } else {
            stopDisplayLink()
            if isFirstResponder { resignFirstResponder() }
            isHidden = true
            accessibilityViewIsModal = false
            hero.releaseContents()
            syncTerminalConcealment()
            resetPage()
            zoomPinchActive = false
            hideZoomHUD(animated: false)
            primary.removeAllCells()
        }
    }

    // MARK: - First-responder fallback (no terminal to hook keys on)

    override var canBecomeFirstResponder: Bool {
        controller.isActive && controller.wantsFirstResponderFallback
    }

    override var keyCommands: [UIKeyCommand]? {
        guard controller.isActive, controller.wantsFirstResponderFallback else { return nil }
        var inputs: [(String, UIKeyModifierFlags)] = [
            (UIKeyCommand.inputEscape, []), ("\r", []), (" ", []), ("\t", []), ("\t", .shift),
            (UIKeyCommand.inputUpArrow, []), (UIKeyCommand.inputDownArrow, []),
            (UIKeyCommand.inputLeftArrow, []), (UIKeyCommand.inputRightArrow, []),
            (UIKeyCommand.inputHome, []), (UIKeyCommand.inputEnd, []),
        ]
        inputs += (1...9).map { (String($0), []) }
        return inputs.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(handleFallbackKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleFallbackKeyCommand(_ command: UIKeyCommand) {
        guard let event = OverlayKeyEvent(keyCommand: command) else { return }
        _ = controller.handleKey(event)
    }

    func tabExposeDidChangeCells(_ controller: TabExposeController) {
        guard controller.isActive else { return }
        if let direction = controller.takeScopeTransition() {
            if controller.reduceMotion() {
                resetPage()
                rebuildPrimary()
            } else {
                pageToNewScope(direction: direction)
            }
        } else {
            rebuildPrimary()
        }
        setNeedsLayout()
        // Only a moved highlight scrolls: a multiplexer feed revising its
        // topology announces cells too, and must not fight a scrolling finger.
        if controller.highlightedTabID != lastScrolledHighlightID {
            lastScrolledHighlightID = controller.highlightedTabID
            primary.scrollCellIntoView(id: controller.highlightedTabID, animated: true)
        }
    }

    // MARK: - Cells

    private func rebuildPrimary() {
        guard let tabsModel = controller.tabsModel else { return }
        primary.rebuildCells(
            tabIDs: controller.tabIDs,
            scopeTitle: controller.scopeTitle,
            scoped: controller.isScoped,
            tabsModel: tabsModel,
            muxFeed: controller.showsMultiplexer ? controller.muxFeed : nil,
            selectedID: controller.currentCellID,
            highlightedID: controller.highlightedTabID,
            appearance: appearance,
            onSelect: { [weak self] id in self?.controller.select(id) }
        )
        hero.tab = controller.heroTabID.flatMap { tabsModel.tab(withID: $0) }
        updatePageControl()
        applyAppearance()
    }

    private func updatePageControl() {
        let count = controller.scopePageCount
        pageControl.numberOfPages = count
        pageControl.currentPage = min(max(controller.currentScopePageIndex, 0), max(count - 1, 0))
        // UIPageControl supplies its localized "page X of Y" accessibility
        // value; expose it as information rather than an adjustable control.
        pageControl.isAccessibilityElement = count > 1
        lastAppliedProgress = -1
    }

    private func makeTray(interactive: Bool) -> TabExposeTrayView {
        let tray = TabExposeTrayView()
        tray.isUserInteractionEnabled = interactive
        tray.accessibilityElementsHidden = !interactive
        insertSubview(tray, belowSubview: pageControl)
        return tray
    }

    private func applyAppearance() {
        backdrop.backgroundColor = appearance.backgroundColor.withAlphaComponent(appearance.backgroundOpacity)
        // Mirrored pixels already carry the terminal's translucent background.
        hero.backgroundColor = isTranslucent ? .clear : appearance.backgroundColor
        pageControl.currentPageIndicatorTintColor = appearance.textColor.withAlphaComponent(0.9)
        pageControl.pageIndicatorTintColor = appearance.textColor.withAlphaComponent(0.3)
        syncTerminalConcealment()
        lastAppliedProgress = -1
        applyProgress()
        primary.applyAppearance(appearance)
        companion?.applyAppearance(appearance)
    }

    // MARK: - Layout

    private var isTranslucent: Bool { appearance.backgroundOpacity < 1 }

    /// The hero mirror is pixel-for-pixel the terminal, so hiding the real
    /// host under it is invisible; restores when inactive or opaque.
    private func syncTerminalConcealment() {
        let target: UIView? = (controller.isActive && isTranslucent)
            ? hero.tab?.splitTree.first?.enclosingSplitHost : nil
        guard target !== concealedHost else { return }
        concealedHost?.alpha = 1
        concealedHost = target
        target?.alpha = 0
    }

    private var isCompact: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || bounds.width < 500
    }

    private var pageWidth: CGFloat { max(heroRect.width, 1) }

    private func currentHeroRect() -> CGRect {
        guard let hero = controller.heroTabID ?? controller.tabsModel?.selectedTabID,
              let tab = controller.tabsModel?.tab(withID: hero),
              let host = tab.splitTree.first?.enclosingSplitHost,
              host.bounds.width > 0, host.bounds.height > 0 else {
            return bounds
        }
        return host.convert(host.bounds, to: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard controller.isActive else { return }
        heroRect = currentHeroRect()
        let H = max(heroRect.height, 1)

        #if targetEnvironment(macCatalyst)
        let mac = true
        #else
        let mac = false
        #endif
        #if os(visionOS)
        let vision = true
        #else
        let vision = false
        #endif
        let metrics = TabExposeLayout.Metrics.standard(
            compact: isCompact, mac: mac, vision: vision,
            showsCaptions: appearance.showsCaptions, hasHeader: controller.isScoped
        )
        let pageFooterHeight: CGFloat = controller.scopePageCount > 1
            ? (vision ? 44 : (isCompact ? 32 : 36))
            : 0
        let traySize = CGSize(
            width: heroRect.width,
            height: max(heroRect.height - pageFooterHeight, 1)
        )
        let radius: CGFloat = vision ? 16 : (isCompact ? 8 : 10)
        let aspect = heroRect.width / H
        for tray in [primary, companion].compactMap({ $0 }) {
            tray.layoutGrid(size: traySize, aspect: aspect, metrics: metrics, cornerRadius: radius, zoom: zoom)
            // bounds/center, not frame: trays carry the reveal/page transform.
            // A scroll view's bounds origin is its content offset; keep it.
            var b = tray.bounds
            b.size = traySize
            tray.bounds = b
            tray.center = CGPoint(x: heroRect.midX, y: heroRect.minY + traySize.height / 2)
        }
        pageControl.bounds = CGRect(origin: .zero, size: CGSize(
            width: heroRect.width,
            height: pageFooterHeight
        ))
        pageControl.center = CGPoint(
            x: heroRect.midX,
            y: heroRect.maxY - pageFooterHeight / 2
        )
        controller.columns = primary.layoutResult.columns

        // Coverage belongs to the exposé host, not to the terminal host's
        // converted frame. The latter can transiently lag safe-area changes;
        // using it for the fill (opaque, or at the window opacity on macOS)
        // could expose terminal pixels around the home-indicator strip even
        // though preview geometry was otherwise right.
        backdrop.frame = bounds
        hero.transform = .identity
        hero.frame = heroRect
        if let hud = zoomHUDHost?.view {
            hud.bounds = CGRect(origin: .zero, size: hud.intrinsicContentSize)
            hud.center = CGPoint(x: heroRect.midX, y: heroRect.midY)
        }
        lastAppliedProgress = -1
        applyProgress()
    }

    /// Everything visual derives from `controller.progress` (0 hidden … 1
    /// presented) and `pageShift` (horizontal paging between scopes).
    private func applyProgress() {
        let p = controller.progress
        guard p != lastAppliedProgress || pageShift != lastAppliedShift else { return }
        lastAppliedProgress = p
        lastAppliedShift = pageShift
        let H = max(heroRect.height, 1)
        let clamped = min(max(p, 0), 1)
        let y = -(1 - clamped) * H

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hero.transform = CGAffineTransform(translationX: 0, y: clamped * H)
        hero.isHidden = clamped >= 1
        var primaryTransform = CGAffineTransform(translationX: pageShift, y: y)
        var companionTransform = CGAffineTransform(translationX: pageShift + CGFloat(companionSide) * pageWidth, y: y)
        if p > 1 {
            // Overshoot: the tray breathes instead of tearing away from the edge.
            let breathe = 1 + (p - 1) * 0.3
            primaryTransform = primaryTransform.scaledBy(x: breathe, y: breathe)
            companionTransform = companionTransform.scaledBy(x: breathe, y: breathe)
        }
        primary.transform = primaryTransform
        companion?.transform = companionTransform
        // Follow the vertical reveal while remaining fixed horizontally as
        // the trays page beneath it.
        pageControl.transform = CGAffineTransform(translationX: 0, y: y)
        let chromeAlpha = Self.smoothstep(0.6, 0.9, p)
        let ringAlpha = Self.smoothstep(0.8, 1.0, p)
        primary.setChrome(captionAlpha: chromeAlpha, ringAlpha: ringAlpha)
        companion?.setChrome(captionAlpha: chromeAlpha, ringAlpha: ringAlpha)
        pageControl.alpha = chromeAlpha
        backdrop.isHidden = p <= 0
        if isTranslucent, !hero.isHidden {
            let path = UIBezierPath(rect: backdrop.bounds)
            path.append(UIBezierPath(rect: heroRect.offsetBy(dx: 0, dy: clamped * H)))
            backdropMask.frame = backdrop.bounds
            backdropMask.path = path.cgPath
            backdrop.layer.mask = backdropMask
        } else {
            backdrop.layer.mask = nil
        }
        CATransaction.commit()
    }

    private static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / max(b - a, 0.0001), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        controller.tick(now: link.timestamp)
        guard controller.isActive else {
            stopDisplayLink()
            return
        }
        // The terminal area can move without our bounds changing (keyboard).
        if currentHeroRect() != heroRect {
            setNeedsLayout()
            layoutIfNeeded()
        }
        stepPageSpring(now: link.timestamp)
        applyProgress()
        // A just-selected tab's host may attach a frame or two later.
        syncTerminalConcealment()
        if !hero.isHidden { hero.sync() }
        // Both pages report: a swipe drags the multiplexer page in as the
        // companion, and paging away from it leaves no mux cells at all —
        // which the feed must hear, or it keeps refreshing panes nobody sees.
        var visibleMuxPanes = primary.syncVisibleMirrors()
        if let companion { visibleMuxPanes.formUnion(companion.syncVisibleMirrors()) }
        controller.muxFeed?.setVisiblePanes(visibleMuxPanes)
    }

    private final class DisplayLinkProxy: NSObject {
        weak var owner: TabExposeView?
        init(owner: TabExposeView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }

    // MARK: - Touch / pointer

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        guard controller.phase == .presented, !isPageInteracting, !zoomPinchActive else { return }
        // The zoom HUD's Reset button owns its own taps.
        if let hud = zoomHUDHost?.view, hud.frame.contains(tap.location(in: self)) { return }
        if let cell = primary.cell(at: tap.location(in: primary)) {
            controller.select(cell.tabID)
        } else {
            controller.cancel()
        }
    }

    #if !os(visionOS)
    @objc private func handleHover(_ hover: UIHoverGestureRecognizer) {
        guard controller.phase == .presented, !isPageInteracting else { return }
        switch hover.state {
        case .began, .changed:
            if let cell = primary.cell(at: hover.location(in: primary)) {
                controller.highlightedTabID = cell.tabID
            }
        default:
            break
        }
    }
    #endif

    // MARK: - Window-level pull gesture

    private func makeEdgePan() -> InteractiveEdgePanRecognizer {
        var config = InteractiveEdgePanRecognizer.Configuration(axis: .vertical, idioms: [.phone, .pad, .mac])
        // One finger from the tab bar strip; two fingers from anywhere above
        // the terminal (and the in-terminal fallback band); trackpad scroll.
        config.touchCounts = [1, 2]
        config.includesTrackpadScroll = true
        config.trackpadGain = configuration.trackpadGain
        // In the band, swipes and scroll pans wait for us (we refuse fast outside it).
        config.beatsSiblingRecognizers = { [weak self] other in
            guard let self, !self.scopePan.owns(other) else { return false }
            return other is UISwipeGestureRecognizer || other is UIPanGestureRecognizer
        }

        let isInBand: (CGPoint, UIWindow, Int) -> Bool = { [weak self] start, window, touches in
            guard let self else { return false }
            let frame = self.convert(self.bounds, to: window)
            let startsAboveTerminal = start.y < frame.minY
            let startsInWindowWideTopBar = self.configuration.topBarActivationSpansWindowWidth()
                && startsAboveTerminal
                && start.x >= window.bounds.minX
                && start.x <= window.bounds.maxX
            if self.controller.isActive {
                let startsOverTerminal = start.x >= frame.minX && start.x <= frame.maxX
                guard startsOverTerminal || startsInWindowWideTopBar else { return false }
                return start.y <= frame.maxY
            }

            // A pinned sidebar shifts the terminal host right, but the top tab
            // bar still spans the window. Let its gesture band follow the real
            // chrome without also making the sidebar body an activation area.
            let horizontalBounds = self.configuration.topBarActivationSpansWindowWidth()
                && startsAboveTerminal
                ? window.bounds
                : frame
            guard start.x >= horizontalBounds.minX, start.x <= horizontalBounds.maxX else {
                return false
            }
            if touches == 1 {
                // Only the strip itself: the status bar edge belongs to the system.
                let strip = self.configuration.oneFingerBandHeight()
                return strip > 0 && start.y >= frame.minY - strip && start.y < frame.minY
            }
            return start.y < frame.minY + self.configuration.fallbackBandHeight()
        }
        let shouldBegin: (CGPoint, CGPoint, UIWindow, Int) -> Bool = { [weak self] _, translation, _, touches in
            guard let self, self.configuration.gestureEnabled(), !self.zoomPinchActive else { return false }
            // One finger competes with horizontal tab scrolling: demand a clearer vertical intent.
            let ratio: CGFloat = touches == 1 ? 2 : 1.25
            let vertical = abs(translation.y) > abs(translation.x) * ratio
            guard vertical else { return false }
            if self.controller.isActive {
                // Push back up to dismiss; not while already finger-driven,
                // not mid group swipe, and not when the tray scrolls instead.
                return translation.y < 0 && self.controller.phase != .interactive
                    && !self.scopeSwipeActive && !self.primary.isScrollEnabled
            }
            return translation.y > 0 && self.configuration.canBeginReveal()
        }
        let callbacks = InteractiveEdgePanRecognizer.Callbacks(
            isInActivationBand: isInBand,
            shouldBegin: shouldBegin,
            length: { [weak self] in max(self?.heroRect.height ?? 1, 1) },
            onBegin: { [weak self] _ in self?.controller.beginInteractive() },
            onChange: { [weak self] p in self?.controller.updateInteractive(signed: p) },
            onEnd: { [weak self] _, v in self?.controller.endInteractive(velocity: v) },
            onCancel: { [weak self] in self?.controller.cancelInteractive() }
        )
        return InteractiveEdgePanRecognizer(configuration: config, callbacks: callbacks)
    }
}

// MARK: - Horizontal paging between scopes (while presented)

extension TabExposeView {
    /// A swipe, a settle, or a companion page still on screen.
    private var isPageInteracting: Bool {
        scopeSwipeActive || companion != nil || pageTarget != nil
    }

    /// One-finger (or two) touch swipe and two-finger trackpad swipe over the
    /// presented grid drag the neighbor group's page in beside the current
    /// one, exactly like the regular tab swipe; release commits or snaps back.
    private func makeScopePan() -> InteractiveEdgePanRecognizer {
        var config = InteractiveEdgePanRecognizer.Configuration(axis: .horizontal, idioms: [.phone, .pad, .mac])
        config.touchCounts = [1, 2]
        config.includesTrackpadScroll = true
        config.trackpadGain = 1.5
        config.beatsSiblingRecognizers = { [weak self] other in
            guard let self, !self.edgePan.owns(other) else { return false }
            return other is UISwipeGestureRecognizer || other is UIPanGestureRecognizer
        }

        let isInBand: (CGPoint, UIWindow, Int) -> Bool = { [weak self] start, window, _ in
            guard let self, self.controller.phase == .presented, self.controller.canNavigateScope else { return false }
            return self.convert(self.bounds, to: window).contains(start)
        }
        let shouldBegin: (CGPoint, CGPoint, UIWindow, Int) -> Bool = { [weak self] _, translation, _, _ in
            guard let self, !self.zoomPinchActive else { return false }
            return abs(translation.x) > abs(translation.y) * 1.5
        }
        let callbacks = InteractiveEdgePanRecognizer.Callbacks(
            isInActivationBand: isInBand,
            shouldBegin: shouldBegin,
            length: { [weak self] in self?.pageWidth ?? 1 },
            onBegin: { [weak self] _ in self?.beginScopeSwipe() },
            onChange: { [weak self] p in self?.updateScopeSwipe(progress: p) },
            onEnd: { [weak self] p, v in self?.endScopeSwipe(progress: p, velocity: v) },
            onCancel: { [weak self] in self?.cancelScopeSwipe() }
        )
        return InteractiveEdgePanRecognizer(configuration: config, callbacks: callbacks)
    }

    private func beginScopeSwipe() {
        guard controller.phase == .presented, controller.canNavigateScope else { return }
        // Take over a settling page where it is so flicks chain.
        scopeSwipeBase = pageShift
        pageTarget = nil
        pageVelocity = 0
        scopeCommitDeadline = 0
        scopeSwipeActive = true
    }

    /// `progress` is the gesture's signed distance / page width (right-positive).
    private func updateScopeSwipe(progress: CGFloat) {
        guard scopeSwipeActive else { return }
        let W = pageWidth
        pageShift = Self.rubberBanded(scopeSwipeBase + progress * W, limit: W)
        updateCompanionForShift()
        applyProgress()
    }

    /// Keep the companion on the side the primary is being dragged away from.
    private func updateCompanionForShift() {
        guard pageShift != 0 else { return }
        let delta = pageShift < 0 ? 1 : -1  // swipe left = next group
        if companion != nil, companionSide == delta { return }
        guard let tabsModel = controller.tabsModel,
              let neighbor = controller.neighborScope(offset: delta) else { return }
        companion?.discard()
        let tray = makeTray(interactive: false)
        tray.rebuildCells(
            tabIDs: neighbor.tabIDs,
            scopeTitle: neighbor.title,
            scoped: true,
            tabsModel: tabsModel,
            muxFeed: neighbor.isMultiplexer ? controller.muxFeed : nil,
            selectedID: neighbor.currentID,
            highlightedID: nil,
            appearance: appearance,
            onSelect: { [weak self] id in self?.controller.select(id) }
        )
        companion = tray
        companionSide = delta
        setNeedsLayout()
        layoutIfNeeded()
        // Wake the neighbor's renderers so its mirrors are live while dragging.
        controller.setScopePreview(neighbor.tabIDs)
    }

    private func endScopeSwipe(progress: CGFloat, velocity: CGFloat) {
        guard scopeSwipeActive else { return }
        scopeSwipeActive = false
        let W = pageWidth
        let delta = pageShift < 0 ? 1 : -1
        // Regular tab swipe thresholds: distance or a flick in the drag direction.
        let threshold = max(120, min(0.45 * W, 260))
        let flick = velocity * CGFloat(-delta) >= 900
        let commits = companion != nil && companionSide == delta && (abs(pageShift) >= threshold || flick)
        if commits {
            // Switch now (as the regular swipe does); the scope-changed announce
            // relabels the pages in place and settles the new primary to 0.
            controller.navigateScope(by: delta)
            scopeCommitDeadline = CACurrentMediaTime() + 0.5
            settlePage(to: CGFloat(-delta) * W, fast: false)
        } else {
            settlePage(to: 0, fast: true)
        }
    }

    private func cancelScopeSwipe() {
        guard scopeSwipeActive else { return }
        scopeSwipeActive = false
        settlePage(to: 0, fast: true)
    }

    /// The scope changed by `direction` (swipe commit, ⌘⌥[ ], scope menu):
    /// the new scope's page slides to the center while the old one leaves.
    private func pageToNewScope(direction: Int) {
        let W = pageWidth
        let previousShift = pageShift
        let outgoing = primary
        if let companion, companion.tabIDs == controller.tabIDs {
            // The dragged-in preview is the new scope: swap roles where they
            // stand (primary at shift, companion at shift + side·W).
            primary = companion
            pageShift += CGFloat(companionSide) * W
            companionSide = -companionSide
        } else {
            companion?.discard()
            primary = makeTray(interactive: true)
            companionSide = -direction
            pageShift = CGFloat(direction) * W
        }
        companion = outgoing
        outgoing.isUserInteractionEnabled = false
        outgoing.accessibilityElementsHidden = true
        primary.isUserInteractionEnabled = true
        primary.accessibilityElementsHidden = false
        rebuildPrimary()
        setNeedsLayout()
        layoutIfNeeded()
        // The controller already holds the outgoing page's tabs as the preview
        // so they render until `dropCompanion` ends it on landing.
        scopeCommitDeadline = 0
        if scopeSwipeActive {
            // Finger still down: keep following it from the relabeled position.
            scopeSwipeBase += pageShift - previousShift
        } else {
            settlePage(to: 0, fast: false)
        }
    }

    private func settlePage(to target: CGFloat, fast: Bool) {
        if controller.reduceMotion() {
            pageShift = target
            pageVelocity = 0
            pageTarget = nil
            applyProgress()
            pageDidLand()
            return
        }
        pageTarget = target
        pageSpringFast = fast
        lastPageTick = 0
    }

    private func stepPageSpring(now: CFTimeInterval) {
        // A committed swipe whose selection never changed: snap back.
        if scopeCommitDeadline > 0, now >= scopeCommitDeadline, !scopeSwipeActive {
            scopeCommitDeadline = 0
            settlePage(to: 0, fast: true)
        }
        guard let target = pageTarget else {
            lastPageTick = now
            return
        }
        let dt = lastPageTick == 0 ? 1.0 / 60.0 : min(max(now - lastPageTick, 0), 1.0 / 20.0)
        lastPageTick = now
        ExposeSpring.step(value: &pageShift, velocity: &pageVelocity, target: target,
                          response: pageSpringFast ? 0.26 : 0.32,
                          damping: pageSpringFast ? 0.9 : 0.86,
                          dt: CGFloat(dt))
        if abs(pageShift - target) < 0.5, abs(pageVelocity) < 1 {
            pageShift = target
            pageVelocity = 0
            pageTarget = nil
            pageDidLand()
        }
    }

    private func pageDidLand() {
        if pageShift == 0 { dropCompanion() }
    }

    private func dropCompanion() {
        companion?.discard()
        companion = nil
        companionSide = 0
        controller.setScopePreview([])
    }

    /// Back to a single page at rest (activation, deactivation, reduce motion).
    private func resetPage() {
        scopeSwipeActive = false
        pageTarget = nil
        pageVelocity = 0
        pageShift = 0
        scopeCommitDeadline = 0
        dropCompanion()
        primary.isUserInteractionEnabled = true
        primary.accessibilityElementsHidden = false
    }

    /// Beyond one page the drag stiffens instead of tearing away.
    private static func rubberBanded(_ shift: CGFloat, limit: CGFloat) -> CGFloat {
        guard abs(shift) > limit else { return shift }
        let over = (abs(shift) - limit) / limit
        return (shift < 0 ? -1 : 1) * limit * (1 + 0.08 * tanh(over * 4))
    }
}

// MARK: - Pinch to resize previews

extension TabExposeView: UIGestureRecognizerDelegate {
    /// Hover and tap may run alongside; pans are cut off in `.began` instead,
    /// since the window pans are permissive about simultaneity themselves.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other is UIPanGestureRecognizer)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPinchGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return controller.phase == .presented && !isPageInteracting
    }

    @objc private func handleZoomPinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            zoomPinchActive = true
            // A pan that beat us to recognition (same two fingers translating
            // while they pinch) is aborted so it can't dismiss, page, or scroll.
            edgePan.cancelActive()
            scopePan.cancelActive()
            if primary.panGestureRecognizer.state == .began || primary.panGestureRecognizer.state == .changed {
                primary.panGestureRecognizer.isEnabled = false
                primary.panGestureRecognizer.isEnabled = true
            }
            pinchAnchorZoom = zoom
            zoomHUDHideTask?.cancel()
            showZoomHUD()
            updateZoomHUD()
        case .changed:
            guard zoomPinchActive else { return }
            let columnsBefore = primary.layoutResult.columns
            zoom = TabExposeSettings.clampZoom(pinchAnchorZoom * pinch.scale)
            relayoutForZoom()
            if primary.layoutResult.columns != columnsBefore { controller.onCommitHaptic?() }
            updateZoomHUD()
        case .ended, .cancelled, .failed:
            guard zoomPinchActive else { return }
            zoomPinchActive = false
            // Snap to whichever is nearer: the auto-fit grid or the current
            // column count filling the width (the auto-fit can be height-bound).
            let fill = TabExposeSettings.clampZoom(primary.layoutResult.snappedZoom)
            commitZoom(abs(zoom - 1) <= abs(zoom - fill) ? 1 : fill)
        default:
            break
        }
    }

    private func relayoutForZoom() {
        setNeedsLayout()
        layoutIfNeeded()
        // Keep the highlighted tab in view as the rows reflow.
        primary.scrollCellIntoView(id: controller.highlightedTabID, animated: false)
    }

    /// Snap so the column count fills the width, persist, and let the HUD fade.
    private func commitZoom(_ target: CGFloat) {
        let animate = !controller.reduceMotion()
        zoom = target
        if animate {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.relayoutForZoom()
            }
        } else {
            relayoutForZoom()
        }
        TabExposeSettings.setZoom(zoom)
        updateZoomHUD()
        scheduleZoomHUDHide()
    }

    private func resetZoom() {
        guard zoom != 1 else {
            scheduleZoomHUDHide()
            return
        }
        controller.onCommitHaptic?()
        commitZoom(1)
    }

    // MARK: HUD

    private func showZoomHUD() {
        if let host = zoomHUDHost {
            host.view.layer.removeAllAnimations()
            host.view.alpha = 1
            return
        }
        let host = UIHostingController(rootView: TabExposeZoomHUD(text: "", onReset: { [weak self] in self?.resetZoom() }))
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.alpha = 0
        addSubview(host.view)
        zoomHUDHost = host
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            host.view.alpha = 1
        }
    }

    private func updateZoomHUD() {
        guard let host = zoomHUDHost else { return }
        let percent = Int((zoom * 100).rounded())
        host.rootView = TabExposeZoomHUD(text: "\(percent)%", onReset: { [weak self] in self?.resetZoom() })
        host.view.invalidateIntrinsicContentSize()
        host.view.bounds = CGRect(origin: .zero, size: host.view.intrinsicContentSize)
        host.view.center = CGPoint(x: heroRect.midX, y: heroRect.midY)
    }

    private func scheduleZoomHUDHide() {
        zoomHUDHideTask?.cancel()
        zoomHUDHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hideZoomHUD(animated: true)
        }
    }

    private func hideZoomHUD(animated: Bool) {
        zoomHUDHideTask?.cancel()
        zoomHUDHideTask = nil
        guard let host = zoomHUDHost else { return }
        zoomHUDHost = nil
        guard animated else {
            host.view.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
            host.view.alpha = 0
        }, completion: { _ in
            host.view.removeFromSuperview()
        })
    }
}

/// Size readout plus Reset shown while pinching the preview grid, matching
/// the terminal's font-size overlay. Glass on iOS 26 / Catalyst 26, material before.
struct TabExposeZoomHUD: View {
    let text: String
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .modifier(TabExposeZoomHUDBackground())
            Button(String(localized: "Reset", comment: "Tab exposé zoom HUD: restore the auto-fit preview size"), action: onReset)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .modifier(TabExposeZoomHUDBackground())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Preview size \(text)", comment: "Tab exposé zoom HUD accessibility label"))
    }
}

private struct TabExposeZoomHUDBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        #if os(visionOS)
        content.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        #endif
    }
}

// MARK: - Cell

@MainActor
final class TabExposeCellView: UIView {
    let tabID: UUID
    /// Live picture of an app tab.
    let mirror = TabPreviewMirrorView()
    /// Rendered picture of a multiplexer tab; only one of the two is showing.
    let muxPreview = MuxTabPreviewView()
    /// Navigation index the current caption was built for; -1 = none yet.
    var captionIndex = -1
    /// Multiplexer caption content the caption was built for.
    var captionKey: String?

    private let preview = UIView()
    private let currentRing = UIView()
    private let highlightRing = UIView()
    private var captionHost: UIHostingController<AnyView>?

    var previewBackgroundColor: UIColor = .black {
        didSet {
            preview.backgroundColor = previewBackgroundColor
            mirror.backgroundColor = previewBackgroundColor
            muxPreview.backgroundColor = previewBackgroundColor
        }
    }
    var accentColor: UIColor = .systemBlue {
        didSet { highlightRing.layer.borderColor = accentColor.cgColor }
    }
    var currentRingColor: UIColor = UIColor.white.withAlphaComponent(0.3) {
        didSet { currentRing.layer.borderColor = currentRingColor.cgColor }
    }
    var isCurrent = false {
        didSet {
            updateRings()
            accessibilityValue = isCurrent
                ? String(localized: "Current tab", comment: "Tab exposé cell: this is the tab that was open before exposé was opened")
                : nil
        }
    }
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateRings()
            let scale: CGFloat = isHighlighted ? 1.02 : 1
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
    var captionAlpha: CGFloat = 1 {
        didSet { captionHost?.view.alpha = captionAlpha }
    }
    var ringAlpha: CGFloat = 1 {
        didSet { updateRings() }
    }

    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        preview.clipsToBounds = true
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        preview.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        preview.isUserInteractionEnabled = false
        preview.addSubview(mirror)
        preview.addSubview(muxPreview)
        muxPreview.isHidden = true
        addSubview(currentRing)
        addSubview(highlightRing)
        addSubview(preview)
        for ring in [currentRing, highlightRing] {
            ring.isUserInteractionEnabled = false
            ring.layer.cornerCurve = .continuous
            ring.layer.borderColor = UIColor.clear.cgColor
        }
        currentRing.layer.borderWidth = 1.5
        highlightRing.layer.borderWidth = 2.5
        updateRings()

        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showMirror(of tab: TabModel) {
        muxPreview.releaseResources()
        muxPreview.isHidden = true
        mirror.isHidden = false
        mirror.tab = tab
        isAccessibilityElement = true
        accessibilityLabel = tab.title
    }

    func showMultiplexerTab(_ tab: MuxTab, feed: MultiplexerExposeFeed?) {
        mirror.releaseContents()
        mirror.isHidden = true
        muxPreview.isHidden = false
        muxPreview.feed = feed
        muxPreview.tab = tab
        isAccessibilityElement = true
        accessibilityLabel = tab.badge.map { "\(tab.title), \($0)" } ?? tab.title
    }

    /// Per display tick: refresh whichever picture is showing.
    func syncPreview() {
        if mirror.isHidden { muxPreview.sync() } else { mirror.sync() }
    }

    func setCaption(_ view: AnyView?) {
        guard let view else {
            captionHost?.view.removeFromSuperview()
            captionHost = nil
            return
        }
        if let captionHost {
            captionHost.rootView = view
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.alpha = captionAlpha
            addSubview(host.view)
            captionHost = host
        }
    }

    /// Release renderer-backed previews and hosted caption state before this
    /// cell is detached. Both can otherwise outlive the visible exposé tray.
    func prepareForRemoval() {
        layer.removeAllAnimations()
        mirror.releaseContents()
        muxPreview.releaseResources()
        setCaption(nil)
        onActivate = nil
    }

    var previewCornerRadius: CGFloat { preview.layer.cornerRadius }

    func layoutContent(previewSize: CGSize, cornerRadius: CGFloat) {
        preview.frame = CGRect(origin: .zero, size: previewSize)
        preview.layer.cornerRadius = cornerRadius
        mirror.frame = preview.bounds
        muxPreview.frame = preview.bounds
        let ringFrame = preview.frame.insetBy(dx: -3, dy: -3)
        for ring in [currentRing, highlightRing] {
            ring.frame = ringFrame
            ring.layer.cornerRadius = cornerRadius + 3
        }
        captionHost?.view.frame = CGRect(
            x: 0, y: previewSize.height,
            width: previewSize.width, height: max(0, bounds.height - previewSize.height)
        )
    }

    private func updateRings() {
        currentRing.alpha = isCurrent ? ringAlpha : 0
        highlightRing.alpha = isHighlighted ? ringAlpha : 0
    }
}

// MARK: - SwiftUI host

struct TabExposeHost: UIViewRepresentable {
    let controller: TabExposeController
    let configuration: TabExposeView.Configuration
    let appearance: TabExposeView.Appearance

    func makeUIView(context: Context) -> TabExposeView {
        let view = TabExposeView(controller: controller)
        view.configuration = configuration
        view.appearance = appearance
        return view
    }

    func updateUIView(_ uiView: TabExposeView, context: Context) {
        uiView.configuration = configuration
        uiView.appearance = appearance
    }
}
