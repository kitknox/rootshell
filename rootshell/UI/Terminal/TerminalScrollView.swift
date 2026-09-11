import UIKit
import Combine
import os
import GhosttyKit

extension Ghostty {
    /// A UIScrollView wrapper for TerminalView that provides native iOS scrollback functionality.
    /// Based on the macOS SurfaceScrollView implementation.
    ///
    /// ## Architecture
    /// - In **normal mode**: UIScrollView handles finger scrolling with native physics
    /// - In **capture mode** (tmux, vim): UIScrollView is disabled, touches go to terminal
    /// - **Scroll wheel events** (Mac Catalyst, iPad trackpad) are handled by gesture recognizers
    ///   in TerminalViewScroll.swift and sent directly to Ghostty as mouse_scroll events
    @MainActor
    class TerminalScrollView: UIView, UIScrollViewDelegate {
    // MARK: - Properties

    /// The scroll view that provides native scrollbars and scroll physics
    private let scrollView: UIScrollView

    /// The document view that's sized to match total scrollback height
    private let documentView: UIView

    /// The terminal view (Metal renderer)
    let terminalView: TerminalView

    /// Track whether the user is actively scrolling (prevents fighting user gestures)
    private var isLiveScrolling: Bool = false

    /// Track whether the current drag started from touch (two-finger) vs trackpad
    private var isTouchScrolling: Bool = false

    /// Drag gain applied on top of the points→pixels coordinate scale, for every
    /// scroll mode (normal, line-scrollback, multiplexer). `1.0` = strict 1:1
    /// finger tracking, which is what we want during a slow, deliberate drag.
    /// The "fewer swipes" reach is NOT taken here (a flat gain > 1 also speeds up
    /// slow drags and breaks 1:1); it comes from the momentum coast below, which
    /// is velocity-dependent — only a fast flick releases with enough velocity to
    /// coast. Leave at 1.0 unless you deliberately want faster-than-finger drags.
    private static let scrollSpeedGain: CGFloat = 1.0

    /// Velocity-gated flick reach. The finger-down drag is ALWAYS 1:1 (at any
    /// speed) — acceleration happens only on release. At release we extend the
    /// momentum target by a multiplier that ramps from 1.0 (a slow, deliberate
    /// release settles tight) up to `flickReachMax` for a hard flick, so a single
    /// hard flick travels much farther while the active drag stays glued to the
    /// finger. Velocity is in points/millisecond (UIScrollView release velocity).
    private static let flickReachMax: CGFloat = 2      // momentum distance × at a hard flick
    private static let flickVelocityLo: CGFloat = 1.4  // pt/ms: at/below this, native (tight) settle
    private static let flickVelocityHi: CGFloat = 1.5  // pt/ms: at/above this, full flickReachMax

    /// Last touch-driven scroll offset (seeded on drag begin / rubber-band upkeep)
    private var lastTouchScrollOffsetY: CGFloat = 0

    /// True while an iPadOS native scrollbar thumb/gutter drag is driving offsets.
    private var isTouchScrollbarDrag: Bool = false

    /// True after a live scroll stream has entered top/bottom rubber-band overscroll.
    private var wasRubberBandingDuringScroll: Bool = false

    /// True while TerminalScrollView is applying terminal/core-driven offset changes.
    private var isApplyingTerminalScrollSync: Bool = false

    /// Generation token for terminal/core-driven offset changes.
    private var terminalScrollSyncGeneration: UInt64 = 0

    /// True while applying a complete terminal/core scrollbar update,
    /// including document height/layout changes that can fire UIScrollView
    /// callbacks before the final contentOffset sync.
    private var isApplyingTerminalScrollbarUpdate: Bool = false

    /// Generation token for terminal/core scrollbar update passes.
    private var terminalScrollbarUpdateGeneration: UInt64 = 0

    /// Last time a real UIScrollView scroll was handled as user activity.
    private var lastLiveScrollEventTime: TimeInterval = 0

    /// Grace window for callbacks around live scroll streams before considering state stale.
    private static let staleLiveScrollGraceInterval: TimeInterval = 0.2

    /// Work item used to restore UIKit's native indicator after silent core sync.
    private var restoreNativeScrollIndicatorWorkItem: DispatchWorkItem?

    #if !targetEnvironment(macCatalyst)
    /// One-shot: the next scrollbar sync came from the iOS status-bar
    /// "scroll to top" tap, so flash the native indicator instead of
    /// suppressing it like a silent output-driven sync. (Catalyst has no
    /// status-bar tap and a different indicator path, so this stays iOS-only.)
    private var pendingStatusBarScrollIndicatorReveal = false
    #endif

    /// Work item used to release a selection-driven native indicator hold.
    private var selectionScrollIndicatorHoldWorkItem: DispatchWorkItem?

    #if targetEnvironment(macCatalyst)
    /// Original offset for an in-flight Catalyst indicator nudge.
    private var catalystSelectionIndicatorNudgeOriginalOffset: CGPoint?
    #endif

    /// Last row position sent to Ghostty core (prevents update loops)
    private var lastSentRow: Int = 0

    /// Last render-only smooth scroll offset sent to Ghostty.
    private var lastSentSmoothScrollOffset: CGFloat = 0

    /// True after a user-driven primary scrollback gesture has put Ghostty in
    /// smooth scrollback mode. Passive output scrollbar updates should preserve
    /// that mode until the viewport actually returns to the live bottom.
    private var userParkedInSmoothScrollback: Bool = false

    /// Last scrollbar sample seen by this wrapper. Used to decide whether the
    /// native scroll view was at the live bottom before output grew the scroll
    /// range, even if Catalyst has `isLiveScrolling` set from scroll callbacks.
    private var lastObservedScrollbar: Ghostty.Action.Scrollbar?

    /// Cached line-scroll setting used by the hot scroll path.
    private var useLineScrollback: Bool = SettingsStore.shared.value(Settings.Gestures.lineScrollback)

    /// Cached rubber-band setting used by the hot scroll path.
    private var useRubberBandScrollback: Bool = SettingsStore.shared.value(Settings.Gestures.rubberBandScrollback)

    /// Last time multiplexer-owned scroll updates asked UIKit to reveal the native scrollbar.
    private var lastMultiplexerScrollIndicatorRevealTime: TimeInterval = 0

    /// Last time selection auto-scroll asked UIKit to reveal the native scrollbar.
    private var lastSelectionScrollIndicatorRevealTime: TimeInterval = 0

    /// Minimum interval between multiplexer-driven native indicator reveal requests.
    private static let multiplexerScrollIndicatorRevealInterval: TimeInterval = 0.75

    /// Minimum interval between selection-driven native indicator reveal requests.
    private static let selectionScrollIndicatorRevealInterval: TimeInterval = 0.25

    /// Notification observers
    private var observers: [NSObjectProtocol] = []

    /// Document view height constraint (stored for efficient updates)
    private var documentHeightConstraint: NSLayoutConstraint?

    /// Terminal view top constraint (updated to follow scroll position)
    private var terminalTopConstraint: NSLayoutConstraint?

    /// Progress bar view (for OSC 9;4 progress indicators)
    private var progressBarView: ProgressBarView?

    /// The active focused pane routes its OSC progress into the integrated tab
    /// edge. Observation stays alive while presentation is suppressed so the
    /// current report can be restored immediately when routing ends.
    private var isProgressBarPresentationSuppressed = false

    /// Cancellable for observing progress report changes
    private var progressReportCancellable: AnyCancellable?

    /// Cancellable for observing mouse capture state changes
    private var mouseCapturedCancellable: AnyCancellable?

    /// Cancellable for observing multiplexer scroll-active state changes
    private var multiplexerScrollActiveCancellable: AnyCancellable?

    /// Mosh roam banner host view (SwiftUI overlay via UIHostingController)
    private var roamBannerHostView: MoshRoamBannerHostView?

    /// Cancellable for observing Mosh session roam banner state
    private var roamBannerCancellable: AnyCancellable?

    /// Attachment upload banner host view
    private var uploadBannerHostView: AttachmentUploadBannerHostView?

    /// SSH auth-banner card host view (shows SSH_MSG_USERAUTH_BANNER live
    /// during authentication)
    private var authBannerCardHostView: SSHAuthBannerCardHostView?

    /// The auth card's top constraint. Recomputed whenever any banner in the
    /// stacking chain changes — anchoring only at creation goes stale when the
    /// roam/upload banner above it appears or is removed.
    private var authBannerCardTopConstraint: NSLayoutConstraint?

    /// Task consuming the session's auth-banner card state stream
    private var authBannerObserveTask: Task<Void, Never>?

    /// Cancellable for observing terminal session changes
    private var sessionObserverCancellable: AnyCancellable?

    #if targetEnvironment(macCatalyst)
    /// Cancellable for observing global theme changes that affect native scrollbar contrast.
    private var catalystThemeCancellable: AnyCancellable?

    /// Cancellable for observing per-window/per-tab theme override changes.
    private var catalystThemeOverrideCancellable: AnyCancellable?
    #endif

    /// Whether we're in a post-foreground grace period where the roam banner UI is suppressed
    private var foregroundBannerGraceActive: Bool = false

    /// Task that clears the foreground grace period after a delay
    private var foregroundBannerGraceTask: Task<Void, Never>?

    /// Last banner state received during grace period (for replay after grace expires)
    private var suppressedBannerState: MoshRoamBannerState?

    // MARK: - Initialization

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        self.scrollView = UIScrollView()
        self.documentView = UIView()

        super.init(frame: .zero)

        // Configure this view for transparency
        backgroundColor = .clear
        isOpaque = false
        #if targetEnvironment(macCatalyst)
        clipsToBounds = true
        #endif

        setupScrollView()
        setupDocumentView()
        setupTerminalView()
        setupCatalystIndicatorStyleObservers()
        setupNotifications()
        setupProgressBar()
        setupMouseCaptureObserver()
        setupMultiplexerScrollActiveObserver()
        setupDropInteraction()
        setupMoshRoamBannerObserver()
        setupUploadBannerObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        foregroundBannerGraceTask?.cancel()
        authBannerObserveTask?.cancel()
        restoreNativeScrollIndicatorWorkItem?.cancel()
        selectionScrollIndicatorHoldWorkItem?.cancel()
        // Clean up notification observers
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Hit Testing

    /// Override hit testing to bypass UIScrollView in capture mode
    /// This ensures touches reach TerminalView for tmux divider dragging, etc.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // The gateway replaces the terminal's input surface. Route clicks and
        // scrolling to its hosted controls before capture, scrollbar, or
        // Catalyst's transparent-scroll-view routing can claim the event.
        if let gatewayView = terminalView.herdrGatewayHost?.view,
           let hitView = gatewayView.hitTest(convert(point, to: gatewayView), with: event) {
            return hitView
        }

        // Query Ghostty directly for capture state (don't rely on cached isMouseCaptured)
        // This ensures we have the current state at the moment of touch
        let isCaptured: Bool
        if let surface = terminalView.surface {
            isCaptured = ghostty_surface_mouse_captured(surface)

            // Update cached state if changed - this triggers the Combine observer
            // which handles scroll view settings and context menu interaction
            if terminalView.isMouseCaptured != isCaptured {
                terminalView.isMouseCaptured = isCaptured
            }
        } else {
            isCaptured = false
        }

        // Captured apps and server scrollback use TerminalView's gestures.
        // Bypass UIScrollView's touch interception; pointer capture remains
        // independent so uncaptured fallback panes can select text normally.
        if isCaptured || terminalView.usesHerdrFallbackScrolling {
            // But first check if the touch lands on an interactive floating
            // overlay so it still receives taps during mouse capture — otherwise
            // the in-bounds fall-through below hands the touch to terminalView
            // and it's forwarded to the captured app as a mouse event (the
            // slider/Reset button never see it). The brightness HUD is
            // cross-platform; the dimension overlay is iOS-only.
            if let hitView = brightnessHUDHitTest(point, with: event) {
                return hitView
            }

            if let hitView = authBannerCardHitTest(point, with: event) {
                return hitView
            }

            #if !targetEnvironment(macCatalyst)
            if let overlayView = terminalView.dimensionOverlayHost?.view,
               overlayView.alpha > 0 {
                let overlayPoint = convert(point, to: overlayView)
                if let hitView = overlayView.hitTest(overlayPoint, with: event) {
                    return hitView
                }
            }
            #endif

            let terminalPoint = convert(point, to: terminalView)
            if let overlayHit = terminalView.hitTestCollapsedKeyboardToolbarButton(terminalPoint, with: event) {
                return overlayHit
            }

            if terminalView.bounds.contains(terminalPoint) {
                return terminalView
            }
        }

        #if targetEnvironment(macCatalyst)
        // The transparent scroll view is layered above the fixed terminal on
        // Catalyst so its native scrollbar remains visible and interactive.
        // Route only scroll-wheel/trackpad events back to UIScrollView so its
        // native momentum remains intact; clicks/presses still hit TerminalView.
        if event?.type == .scroll {
            let scrollPoint = convert(point, to: scrollView)
            if scrollView.bounds.contains(scrollPoint) {
                return scrollView
            }
        }

        if isPointInCatalystScrollbarGutter(point) {
            return scrollView
        }

        // The brightness HUD is an interactive overlay added to terminalView,
        // which sits *below* the transparent scroll view on Catalyst. Without
        // this carve-out the in-bounds check below returns terminalView for
        // every click — swallowing the HUD slider and Reset button (they never
        // receive clicks). This branch runs whether or not mouse capture is
        // active, so it's the macOS-non-capture analogue of the capture-mode
        // carve-out above.
        if let hitView = brightnessHUDHitTest(point, with: event) {
            return hitView
        }

        // Same carve-out for the auth-banner card: it must stay tappable on
        // Catalyst where the in-bounds check below would otherwise return
        // terminalView for every click.
        if let hitView = authBannerCardHitTest(point, with: event) {
            return hitView
        }

        let terminalPoint = convert(point, to: terminalView)
        if terminalView.bounds.contains(terminalPoint) {
            if let event {
                terminalView.lastPointerEventWasSecondaryClick = event.buttonMask.contains(.secondary)
            }
            return terminalView
        }
        #endif

        #if !targetEnvironment(macCatalyst)
        isTouchScrollbarDrag = isPointInTouchScrollbarGutter(point)
        #endif

        // In non-capture mode, use default hit testing (UIScrollView handles scrolling)
        return super.hitTest(point, with: event)
    }

    /// If the brightness HUD covers `point`, return the hit subview so it
    /// receives the click/touch. The HUD host is sized to its pill via
    /// intrinsic-content constraints, so this returns nil for points outside
    /// it and the caller falls through to normal routing.
    private func brightnessHUDHitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hudView = terminalView.brightnessHUDHost?.view, hudView.alpha > 0 else {
            return nil
        }
        let hudPoint = convert(point, to: hudView)
        return hudView.hitTest(hudPoint, with: event)
    }

    /// If the SSH auth-banner card covers `point`, return the hit subview so
    /// its open/copy/collapse controls receive the click/touch even during
    /// mouse capture or under the Catalyst transparent-scroll-view routing.
    private func authBannerCardHitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let cardView = authBannerCardHostView, cardView.superview != nil,
              cardView.alpha > 0 else {
            return nil
        }
        let cardPoint = convert(point, to: cardView)
        return cardView.hitTest(cardPoint, with: event)
    }

    #if !targetEnvironment(macCatalyst)
    private func isPointInTouchScrollbarGutter(_ point: CGPoint) -> Bool {
        guard scrollView.isScrollEnabled,
              scrollView.showsVerticalScrollIndicator,
              scrollView.contentSize.height > scrollView.bounds.height else {
            return false
        }

        let scrollPoint = convert(point, to: scrollView)
        guard scrollView.bounds.contains(scrollPoint) else { return false }

        // Prefer the actual private indicator view frame when UIKit exposes it.
        for subview in scrollView.subviews where subview !== documentView {
            guard !subview.isHidden, subview.alpha > 0.01 else { continue }
            let frame = subview.frame
            guard frame.width <= 32, frame.maxX >= scrollView.bounds.maxX - 32 else { continue }
            if frame.insetBy(dx: -8, dy: -8).contains(scrollPoint) {
                return true
            }
        }

        // Fallback for the moment before UIKit has materialized the indicator view.
        return scrollPoint.x >= scrollView.bounds.maxX - 22
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private func isPointInCatalystScrollbarGutter(_ point: CGPoint) -> Bool {
        guard scrollView.isScrollEnabled,
              scrollView.showsVerticalScrollIndicator,
              scrollView.contentSize.height > scrollView.bounds.height else {
            return false
        }

        let scrollPoint = convert(point, to: scrollView)
        guard scrollView.bounds.contains(scrollPoint) else { return false }

        // Prefer the actual private indicator view frame when UIKit exposes it.
        for subview in scrollView.subviews where subview !== documentView {
            guard !subview.isHidden, subview.alpha > 0.01 else { continue }
            let frame = subview.frame
            guard frame.width <= 32, frame.maxX >= scrollView.bounds.maxX - 32 else { continue }
            if frame.insetBy(dx: -8, dy: -8).contains(scrollPoint) {
                return true
            }
        }

        // Fallback for the moment before UIKit has materialized the indicator view.
        return scrollPoint.x >= scrollView.bounds.maxX - 22
    }
    #endif

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self

        // Configure for transparency
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false

        // Enable scrolling on all platforms for scrollbar dragging
        // On Mac Catalyst, scroll wheel events are handled by AppKit swizzling
        // (see TerminalViewScroll.swift), but UIScrollView still provides scrollbar
        // On iOS, UIScrollView handles finger scrolling with native physics
        // Will be disabled dynamically when mouse capture is active (tmux, vim)
        scrollView.isScrollEnabled = true

        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        #if targetEnvironment(macCatalyst)
        updateCatalystScrollIndicatorStyle()
        #else
        scrollView.indicatorStyle = .default // Adapts to light/dark mode
        #endif
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        // iOS 11.1+: Use content inset adjustment behavior for safe area
        scrollView.contentInsetAdjustmentBehavior = .never

        // Allow touches to reach TerminalView for tap gestures
        scrollView.delaysContentTouches = false
        // Let scroll view cancel touches when scrolling starts
        scrollView.canCancelContentTouches = true
        // Prevent automatic scroll-to-top on status bar tap
        scrollView.scrollsToTop = false

        // Enable UIScrollView to handle Magic Keyboard trackpad scroll wheel events
        // This provides native momentum and physics for trackpad scrolling in non-capture mode.
        // On Catalyst the Metal terminal is a fixed sibling above the scroll view, so native
        // scrolling only moves the blank range model underneath it.
        scrollView.panGestureRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
        #if !targetEnvironment(macCatalyst)
        // Set touch requirements based on current touch mode
        updateScrollViewTouchRequirements()
        #endif
        updateRubberBandScrollBehavior()

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    #if !targetEnvironment(macCatalyst)
    /// Update scroll view pan gesture touch requirements based on touch mode
    private func updateScrollViewTouchRequirements() {
        let scrollMode = SettingsStore.shared.value(Settings.Gestures.scrollMode)
        scrollView.panGestureRecognizer.minimumNumberOfTouches = scrollMode ? 1 : 2
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private func setupCatalystIndicatorStyleObservers() {
        updateCatalystScrollIndicatorStyle()

        catalystThemeCancellable = ThemeManager.shared.themeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateCatalystScrollIndicatorStyle()
            }

        catalystThemeOverrideCancellable = ThemeOverrideManager.shared.overridesDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                switch change.scope {
                case .tab:
                    guard self.terminalView.containingTabID?.uuidString == change.id else { return }
                case .window:
                    guard self.terminalView.windowId == change.id else { return }
                }
                self.updateCatalystScrollIndicatorStyle()
            }
    }

    private func updateCatalystScrollIndicatorStyle() {
        let (themeName, _) = ThemeOverrideManager.shared.resolveTheme(
            tabId: terminalView.containingTabID,
            windowId: terminalView.windowId
        )
        let isLight = ThemeManager.shared.themeInfo(for: themeName)?.isLight
            ?? ThemeManager.shared.currentThemeInfo?.isLight
            ?? (traitCollection.userInterfaceStyle != .dark)
        scrollView.indicatorStyle = isLight ? .black : .white
    }
    #else
    private func setupCatalystIndicatorStyleObservers() {}
    #endif

    private func setupDocumentView() {
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.backgroundColor = .clear
        scrollView.addSubview(documentView)

        // Create explicit height constraint (will be updated based on scrollback)
        // Initialize to a large value (1000) to ensure terminal is visible initially
        // This will be updated to the correct value when scrollbar updates arrive
        let heightConstraint = documentView.heightAnchor.constraint(equalToConstant: 1000)
        heightConstraint.priority = .required
        self.documentHeightConstraint = heightConstraint

        // Document view fills scroll view's content area
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Width matches frame (no horizontal scrolling)
            documentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // Height constraint (updated dynamically based on scrollback)
            heightConstraint
        ])
    }

    private func setupTerminalView() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        // Let SplitTreeHostingView.attach find this wrapper instead of building a
        // second one around the same terminal (both platforms — the Catalyst branch
        // below doesn't set enclosingScrollView).
        terminalView.enclosingTerminalScrollView = self

        #if targetEnvironment(macCatalyst)
        insertSubview(terminalView, belowSubview: scrollView)

        // On Catalyst the Metal terminal must not be part of the UIScrollView's
        // moving document hierarchy. Keep it pinned under a transparent scroll
        // view so the native scrollbar remains visible and interactive.
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Trackpad tab-swipe must reach the gesture in both capture mode (events
        // route to terminalView via hitTest) and non-capture mode (events route
        // to scrollView). Attach to the shared parent so UIKit walks up to it
        // from either child.
        terminalView.attachTrackpadTabSwipeGesture(to: self)
        #else
        documentView.addSubview(terminalView)

        // Set weak reference for long-press selection to disable scroll during selection
        terminalView.enclosingScrollView = scrollView

        // Opt into the iOS status-bar "scroll to top" gesture if this pane is
        // already the focused one. focusDidChange may have run before the
        // terminal was attached here (new tab), when enclosingScrollView was
        // still nil, so seed the flag now from the current focus state.
        scrollView.scrollsToTop = terminalView.isLogicallyFocused

        // Store the top constraint so we can update it to follow scroll position
        let topConstraint = terminalView.topAnchor.constraint(equalTo: documentView.topAnchor)
        self.terminalTopConstraint = topConstraint

        // Terminal view is fixed size (visible area) and follows the scroll position
        // We update its y position to match contentOffset so it's always visible
        NSLayoutConstraint.activate([
            topConstraint,
            terminalView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),

            // Height matches scroll view frame (visible area)
            terminalView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        #endif

    }

    private func setupNotifications() {
        // Listen for scrollbar updates from Ghostty core
        let scrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleScrollbarUpdate()
            }
        }
        observers.append(scrollbarObserver)

        // Listen for scrolling setting changes to update gesture requirements and
        // clear any render-only smooth scroll offset from the previous mode.
        let scrollingSettingsObserver = NotificationCenter.default.addObserver(
            forName: .touchModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.useLineScrollback = SettingsStore.shared.value(Settings.Gestures.lineScrollback)
                self.useRubberBandScrollback = SettingsStore.shared.value(Settings.Gestures.rubberBandScrollback)
                #if !targetEnvironment(macCatalyst)
                self.updateScrollViewTouchRequirements()
                #endif
                self.updateRubberBandScrollBehavior()
                self.resetSmoothScrollOffset()
            }
        }
        observers.append(scrollingSettingsObserver)

        // Listen for input events to auto-scroll to bottom and cancel momentum
        let inputObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidReceiveInput,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Cancel any momentum scrolling on user input
                self.terminalView.cancelMomentumScrolling()
                self.scrollToBottom()
            }
        }
        observers.append(inputObserver)

        let selectionScrollIndicatorObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySelectionScrollIndicatorActivity,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.holdSelectionScrollIndicatorVisible(force: true)
            }
        }
        observers.append(selectionScrollIndicatorObserver)
    }

    private func setupProgressBar() {
        // Observe progress report changes on the terminal view
        progressReportCancellable = terminalView.$progressReport
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in
                self?.updateProgressBar(report: report)
            }
    }

    private func setupMouseCaptureObserver() {
        // Observe mouse capture state to toggle scroll behavior
        mouseCapturedCancellable = terminalView.$isMouseCaptured.combineLatest(terminalView.$usesHerdrFallbackScrolling)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCaptured, fallbackScrolling in
                guard let self = self else { return }
                let forwardsScroll = isCaptured || fallbackScrolling

                // In mouse capture mode (tmux, vim):
                // - Disable UIScrollView scrolling AND its pan gesture
                // - Disable canCancelContentTouches so touches reach TerminalView
                // - Remove UIContextMenuInteraction (its gesture cancels touches)
                // - TerminalView's gesture recognizer handles scroll wheel → mouse_scroll
                //
                // Without capture or server scrollback:
                // - iOS/iPadOS: UIScrollView handles scrolling with native momentum
                // - Mac Catalyst: UIScrollView handles native momentum while
                //   TerminalView stays pinned under its blank range model
                // - scrollViewDidScroll → scroll_to_row for Ghostty scrollback
                // Context menus depend only on actual pointer capture.
                // Prevent scroll view from cancelling touches delivered to terminal
                self.scrollView.canCancelContentTouches = !forwardsScroll

                #if targetEnvironment(macCatalyst)
                self.scrollView.panGestureRecognizer.isEnabled = !forwardsScroll
                #else
                self.scrollView.panGestureRecognizer.isEnabled = !forwardsScroll
                // Remove/add context menu interaction on iOS/iPadOS only
                // UIContextMenuInteraction's internal gesture recognizer cancels touches,
                // which breaks tmux divider dragging on iPad
                // On Mac Catalyst, we keep the interaction to intercept right-clicks
                // Note: UIEditMenuInteraction is now transient (created on demand), so no
                // management needed here.
                if isCaptured {
                    if let interaction = self.terminalView.contextMenuInteraction {
                        self.terminalView.removeInteraction(interaction)
                    }
                    // Remove any transient edit menu interaction
                    if let editInteraction = self.terminalView.editMenuInteraction {
                        self.terminalView.removeInteraction(editInteraction)
                        self.terminalView.editMenuInteraction = nil
                    }
                } else {
                    // Re-add context menu interaction if not present
                    let hasContextMenu = self.terminalView.interactions.contains(where: { $0 is UIContextMenuInteraction })
                    if !hasContextMenu {
                        let newInteraction = UIContextMenuInteraction(delegate: self.terminalView)
                        self.terminalView.addInteraction(newInteraction)
                        self.terminalView.contextMenuInteraction = newInteraction
                    }
                    // Respect touch mode for scroll view settings
                    let scrollMode = SettingsStore.shared.value(Settings.Gestures.scrollMode)
                    self.scrollView.panGestureRecognizer.minimumNumberOfTouches = scrollMode ? 1 : 2
                }
                #endif
                self.applyVerticalScrollState(isCaptured: isCaptured)
            }
    }

    private func setupMultiplexerScrollActiveObserver() {
        // Observe multiplexer scroll-active state. While multiplexer tracking
        // owns the scrollbar values (scrollbarTotal/Offset/Len), keep the
        // real UIScrollView enabled so its native scrollbar can represent
        // and accept interaction for the multiplexer's scroll position.
        //
        // `removeDuplicates()` ensures we only react to genuine
        // transitions; @Published emits on every assignment even if the
        // value is unchanged, and apply(sample) sets
        // `multiplexerScrollActive = true` on every emitted sample (~30 Hz).
        multiplexerScrollActiveCancellable = terminalView.$multiplexerScrollActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self = self else { return }
                self.applyVerticalScrollState(
                    isCaptured: self.terminalView.isMouseCaptured
                )
                if active {
                    self.revealMultiplexerScrollIndicator(force: true)
                } else {
                    self.lastMultiplexerScrollIndicatorRevealTime = 0
                }
            }
    }

    /// Compute and apply the native scroll state from current mode.
    /// Normal mode mirrors Ghostty scrollback. Multiplexer tracking mode
    /// mirrors the multiplexer's scroll position while the multiplexer
    /// still renders the terminal.
    private func applyVerticalScrollState(isCaptured: Bool) {
        let multiplexerActive = terminalView.multiplexerScrollActive
        let forwardsScroll = isCaptured || terminalView.usesHerdrFallbackScrolling
        let nativeScrollActive = !forwardsScroll || multiplexerActive
        scrollView.showsVerticalScrollIndicator = nativeScrollActive
        scrollView.isScrollEnabled = nativeScrollActive
        scrollView.panGestureRecognizer.isEnabled = !forwardsScroll
        updateRubberBandScrollBehavior()
        if forwardsScroll || multiplexerActive {
            resetSmoothScrollOffset()
        }
    }

    private var shouldUseRubberBandScrollback: Bool {
        return useRubberBandScrollback &&
            !useLineScrollback &&
            !terminalView.isMouseCaptured &&
            !terminalView.usesHerdrFallbackScrolling &&
            !terminalView.multiplexerScrollActive
    }

    private func updateRubberBandScrollBehavior() {
        let enabled = shouldUseRubberBandScrollback
        scrollView.bounces = enabled
        scrollView.alwaysBounceVertical = enabled

        if !enabled {
            #if targetEnvironment(macCatalyst)
            terminalView.setRubberBandOffset(0)
            #endif
            #if !targetEnvironment(macCatalyst)
            updateTerminalBottomInsetSuppression(rubberBanding: false)
            #endif
            let clampedOffsetY = clampedScrollModelOffsetY(scrollView.contentOffset.y)
            if abs(clampedOffsetY - scrollView.contentOffset.y) > 0.5 {
                setContentOffsetFromTerminalSync(CGPoint(x: 0, y: clampedOffsetY))
            }
        }

        updateTerminalPositionForCurrentOffset()
    }

    private func setupDropInteraction() {
        // Add drop interaction at the scroll view level to catch drops on Mac Catalyst
        // UIScrollView can intercept drops before they reach nested views
        let dropInteraction = UIDropInteraction(delegate: self)
        addInteraction(dropInteraction)
    }

    private func setupMoshRoamBannerObserver() {
        // Listen for session changes on our terminal view
        // The session is set asynchronously after view creation
        let sessionObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySessionDidChange,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMoshSessionObserver()
            }
        }
        observers.append(sessionObserver)

        #if !targetEnvironment(macCatalyst)
        // Listen for embedded Mosh session changes (from local shell)
        let embeddedMoshObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyEmbeddedMoshSessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Delivered on .main, so the terminalView/session reads below are
            // already on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let localSession = notification.object as? LocalShellSession,
                      localSession === self.terminalView.session else { return }
                self.updateMoshSessionObserver()
            }
        }
        observers.append(embeddedMoshObserver)
        #endif

        // Suppress roam banner flash when returning from background
        // Use willEnterForeground (not didBecomeActive) to avoid triggering
        // on Control Center dismissal, alerts, or cold launch.
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startForegroundBannerGrace()
            }
        }
        observers.append(foregroundObserver)

        // Also check if session is already set (e.g., restored from persistence)
        updateMoshSessionObserver()
    }

    /// Starts a grace period that suppresses the roam banner UI after returning from background.
    /// The connection almost always recovers within a few seconds, so showing the banner
    /// immediately on foreground return is jarring. If the connection is genuinely broken,
    /// the banner will appear after the grace period expires.
    private func startForegroundBannerGrace() {
        // Only activate grace if we have an active roaming session
        guard roamBannerCancellable != nil else { return }

        foregroundBannerGraceTask?.cancel()
        foregroundBannerGraceActive = true

        // Seed buffer with the currently displayed state so it can be replayed
        // if the session doesn't re-emit during grace (e.g. Trzsz .connectionLost).
        suppressedBannerState = roamBannerHostView?.currentState

        // Hide any currently visible banner directly on the host view.
        // We bypass updateRoamBanner(state: nil) here because its grace-period
        // nil branch would clear the suppressedBannerState we just seeded.
        roamBannerHostView?.update(state: nil)

        foregroundBannerGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, !Task.isCancelled else { return }
            self.foregroundBannerGraceActive = false
            let stateToReplay = self.suppressedBannerState
            self.suppressedBannerState = nil
            if let stateToReplay {
                self.updateRoamBanner(state: stateToReplay)
            }
        }
    }

    /// Updates the roaming session observer when the terminal's session changes
    private func updateMoshSessionObserver() {
        // The auth-banner card tracks the session through the exact same
        // invalidation sites (initial setup, session adoption, embedded-mosh
        // change, reconnect), so re-resolve it here too.
        updateAuthBannerObserver()

        // Cancel existing observer
        roamBannerCancellable?.cancel()
        roamBannerCancellable = nil

        // Reset foreground grace state on session change
        foregroundBannerGraceTask?.cancel()
        foregroundBannerGraceTask = nil
        foregroundBannerGraceActive = false
        suppressedBannerState = nil

        // Check for direct MoshSession
        if let moshSession = terminalView.session as? MoshSession {
            observeMoshSession(moshSession)
            return
        }

        // Check for direct TrzszSession
        if let trzszSession = terminalView.session as? TrzszSession {
            observeTrzszSession(trzszSession)
            return
        }

        #if !targetEnvironment(macCatalyst)
        // Check for embedded Mosh via LocalShellSession (iOS/visionOS only)
        if let localSession = terminalView.session as? LocalShellSession,
           let embeddedMosh = localSession.embeddedMoshSession {
            observeMoshSession(embeddedMosh)
            return
        }

        // Check for embedded Trzsz via LocalShellSession (iOS/visionOS only)
        if let localSession = terminalView.session as? LocalShellSession,
           let embeddedTrzsz = localSession.embeddedTrzszSession {
            observeTrzszSession(embeddedTrzsz)
            return
        }
        #endif

        // Not a roaming session - hide any existing banner
        updateRoamBanner(state: nil)
    }

    /// Re-resolves the auth-banner card subscription for the current session.
    /// Invoked from the same sites as the roam-banner observer so it tracks
    /// session adoption, reconnect replacement, and embedded-session changes.
    /// LocalShellSession conforms to SSHAuthBannerCardProviding directly
    /// (forwarding its embedded session's state), so one subscription per
    /// session object covers all embedded transitions.
    private func updateAuthBannerObserver() {
        authBannerObserveTask?.cancel()
        authBannerObserveTask = nil

        guard let provider = terminalView.session as? SSHAuthBannerCardProviding else {
            updateAuthBannerCard(state: nil)
            return
        }

        // The stream replays the current value first, so banners that arrived
        // before this pane observed the session still show.
        authBannerObserveTask = Task { [weak self] in
            for await state in provider.authBannerCardStates() {
                guard let self, !Task.isCancelled else { return }
                self.updateAuthBannerCard(state: state)
            }
        }
    }

    /// Observes a MoshSession's roamBannerState and updates the banner accordingly
    private func observeMoshSession(_ moshSession: MoshSession) {
        roamBannerCancellable = moshSession.$roamBannerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateRoamBanner(state: state)
            }
    }

    /// Observes a TrzszSession's roamBannerState and updates the banner accordingly
    private func observeTrzszSession(_ trzszSession: TrzszSession) {
        roamBannerCancellable = trzszSession.$roamBannerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trzszState in
                // Convert TrzszRoamBannerState to MoshRoamBannerState for UI reuse
                let moshState = trzszState.map { state in
                    MoshRoamBannerState(
                        message: state.message,
                        secondsSinceContact: state.secondsSinceContact,
                        holePunchInProgress: state.reconnecting,
                        isTimeoutBanner: !state.reconnecting,
                        isReplyTimeout: false
                    )
                }
                self?.updateRoamBanner(state: moshState)
                if trzszSession.canRebuildJumpConnection {
                    self?.roamBannerHostView?.rebuildJumpConnection = { [weak trzszSession] in
                        trzszSession?.rebuildJumpConnection()
                    }
                }
            }
    }

    /// Called when the terminal view's session is set/changed
    /// This should be called from TerminalView when the session property changes
    func sessionDidChange() {
        updateMoshSessionObserver()
    }

    // MARK: - Mosh Roam Banner Handling

    private func updateRoamBanner(state: MoshRoamBannerState?) {
        // During post-foreground grace period, suppress non-nil states (show-banner)
        // but allow nil states (hide-banner) through so recovery hides the banner.
        if foregroundBannerGraceActive {
            if state != nil {
                suppressedBannerState = state
                return
            } else {
                // Recovery happened during grace — clear buffer so stale state isn't replayed
                suppressedBannerState = nil
            }
        }

        if state != nil && roamBannerHostView == nil {
            // Create banner host view
            let hostView = MoshRoamBannerHostView()
            hostView.translatesAutoresizingMaskIntoConstraints = false

            // Find parent view controller for hosting controller lifecycle
            if let parentVC = findViewController() {
                hostView.setParentViewController(parentVC)
            }

            addSubview(hostView)

            // Position at top center with padding, constrained to stay within bounds
            NSLayoutConstraint.activate([
                hostView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                hostView.centerXAnchor.constraint(equalTo: centerXAnchor),
                hostView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                hostView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                hostView.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            ])

            roamBannerHostView = hostView
        }

        roamBannerHostView?.update(state: state)
        refreshAuthBannerCardTopConstraint()

        // Remove host view when state is nil (after animation completes)
        if state == nil {
            // Give animation time to complete before removing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard self?.roamBannerHostView?.currentState == nil else { return }
                self?.roamBannerHostView?.removeFromSuperview()
                self?.roamBannerHostView = nil
                self?.refreshAuthBannerCardTopConstraint()
            }
        }
    }

    /// Finds the parent view controller for this view
    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }

    // MARK: - Upload Banner Handling

    private func setupUploadBannerObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyAttachmentUploadStateChanged,
            object: terminalView,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // Delivered on .main; the hop below just re-enters MainActor.
            nonisolated(unsafe) let notification = notification
            Task { @MainActor in
                let state = notification.userInfo?["state"] as? AttachmentUploadState
                let bannerState = state.flatMap { AttachmentUploadBannerState.from($0) }
                self.updateUploadBanner(state: bannerState)
            }
        }
        observers.append(observer)
    }

    private func updateUploadBanner(state: AttachmentUploadBannerState?) {
        if state != nil && uploadBannerHostView == nil {
            let hostView = AttachmentUploadBannerHostView()
            hostView.translatesAutoresizingMaskIntoConstraints = false

            if let parentVC = findViewController() {
                hostView.setParentViewController(parentVC)
            }

            hostView.onCancel = { [weak self] in
                self?.terminalView.cancelAttachmentUpload()
            }

            addSubview(hostView)

            // Position below roam banner if present, otherwise at top
            let topAnchor: NSLayoutYAxisAnchor
            let topConstant: CGFloat
            if let roamBanner = roamBannerHostView, roamBanner.currentState != nil {
                topAnchor = roamBanner.bottomAnchor
                topConstant = 4
            } else {
                topAnchor = self.topAnchor
                topConstant = 8
            }

            NSLayoutConstraint.activate([
                hostView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
                hostView.centerXAnchor.constraint(equalTo: centerXAnchor),
                hostView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                hostView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                hostView.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            ])

            uploadBannerHostView = hostView
        }

        uploadBannerHostView?.update(state: state)
        refreshAuthBannerCardTopConstraint()

        if state == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard self?.uploadBannerHostView?.currentState == nil else { return }
                self?.uploadBannerHostView?.removeFromSuperview()
                self?.uploadBannerHostView = nil
                self?.refreshAuthBannerCardTopConstraint()
            }
        }
    }

    // MARK: - SSH Auth Banner Card Handling

    /// Re-homes the auth-banner card's hosting controller under a new parent
    /// view controller. Called from the pane's `prepareForAttachment` during
    /// window transfer, before the split tree inserts the pane into the
    /// destination hierarchy.
    func refreshAuthBannerParentViewController(_ viewController: UIViewController?) {
        authBannerCardHostView?.setParentViewController(viewController)
    }

    private func updateAuthBannerCard(state: SSHAuthBannerCardState?) {
        if state != nil && authBannerCardHostView == nil {
            let hostView = SSHAuthBannerCardHostView()
            hostView.translatesAutoresizingMaskIntoConstraints = false

            // Resolved lazily: the pane's session is replaced on adoption and
            // on reconnect, so capturing the provider here would go stale.
            hostView.onDismissRequested = { [weak self] in
                (self?.terminalView.session as? SSHAuthBannerCardProviding)?
                    .dismissAuthBannerCard()
            }

            if let parentVC = findViewController() {
                hostView.setParentViewController(parentVC)
            }

            addSubview(hostView)

            NSLayoutConstraint.activate([
                hostView.centerXAnchor.constraint(equalTo: centerXAnchor),
                hostView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                hostView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                // A hostile 64 KiB banner scrolls inside the card instead of
                // covering the pane (and the auth prompts under it).
                hostView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6)
            ])

            authBannerCardHostView = hostView
        }

        refreshAuthBannerCardTopConstraint()
        authBannerCardHostView?.update(state: state)

        if state == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard self?.authBannerCardHostView?.currentState == nil else { return }
                self?.authBannerCardHostView?.removeFromSuperview()
                self?.authBannerCardHostView = nil
            }
        }
    }

    /// Re-anchors the auth card in the banner stacking chain: below the upload
    /// banner, else below the roam banner, else at the top. Called whenever
    /// the card or either banner above it changes, so the card never keeps a
    /// constraint to a banner that has since disappeared (which would leave
    /// its vertical position ambiguous) or overlaps one that appeared later.
    private func refreshAuthBannerCardTopConstraint() {
        guard let hostView = authBannerCardHostView, hostView.superview === self else { return }

        let topAnchor: NSLayoutYAxisAnchor
        let topConstant: CGFloat
        if let uploadBanner = uploadBannerHostView, uploadBanner.superview === self,
           uploadBanner.currentState != nil {
            topAnchor = uploadBanner.bottomAnchor
            topConstant = 4
        } else if let roamBanner = roamBannerHostView, roamBanner.superview === self,
                  roamBanner.currentState != nil {
            topAnchor = roamBanner.bottomAnchor
            topConstant = 4
        } else {
            topAnchor = self.topAnchor
            topConstant = 8
        }

        authBannerCardTopConstraint?.isActive = false
        let constraint = hostView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant)
        constraint.isActive = true
        authBannerCardTopConstraint = constraint
    }

    // MARK: - Progress Bar Handling

    func setProgressBarPresentationSuppressed(_ suppressed: Bool) {
        guard isProgressBarPresentationSuppressed != suppressed else { return }
        isProgressBarPresentationSuppressed = suppressed
        if suppressed {
            removeProgressBarView()
        } else {
            updateProgressBar(report: terminalView.progressReport)
        }
    }

    private func updateProgressBar(report: Ghostty.Action.ProgressReport?) {
        guard !isProgressBarPresentationSuppressed else {
            removeProgressBarView()
            return
        }

        // Remove existing progress bar if report is nil or state is .remove
        if report == nil || report?.state == .remove {
            removeProgressBarView()
            return
        }

        // Create progress bar view if it doesn't exist
        if progressBarView == nil {
            let barView = ProgressBarView()
            barView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(barView)

            NSLayoutConstraint.activate([
                barView.topAnchor.constraint(equalTo: topAnchor),
                barView.leadingAnchor.constraint(equalTo: leadingAnchor),
                barView.trailingAnchor.constraint(equalTo: trailingAnchor),
                barView.heightAnchor.constraint(equalToConstant: 2)
            ])

            progressBarView = barView
        }

        // Update progress bar with new state
        if let report = report {
            progressBarView?.update(with: report)
        }
    }

    private func removeProgressBarView() {
        progressBarView?.stopAnimation()
        progressBarView?.removeFromSuperview()
        progressBarView = nil
    }

    // MARK: - Scrollbar Update Handling

    /// Handle scrollbar state updates from Ghostty core
    private func handleScrollbarUpdate() {
        clearStaleLiveScrollStateIfNeeded()

        let applyUpdate = {
            self.applyScrollbarUpdate()
        }

        #if !targetEnvironment(macCatalyst)
        if pendingStatusBarScrollIndicatorReveal {
            // Status-bar "scroll to top" tap: apply the sync, then flash the
            // native indicator so the jump is visible (unlike silent output
            // syncs, which suppress it below).
            pendingStatusBarScrollIndicatorReveal = false
            applyUpdate()
            forceNativeVerticalScrollIndicatorVisible()
            return
        }
        #endif

        // Terminal output can change contentSize/contentOffset while the user
        // is not scrolling. UIKit may reveal a previously dragged indicator
        // for those changes, so hide the native indicator just for the sync.
        if isLiveScrolling || terminalView.multiplexerScrollActive || terminalView.isActivelySelecting {
            applyUpdate()
            holdSelectionScrollIndicatorVisible(force: false)
        } else {
            performWithoutNativeScrollIndicatorFlash(applyUpdate)
        }
    }

    private func applyScrollbarUpdate() {
        terminalScrollbarUpdateGeneration &+= 1
        let updateGeneration = terminalScrollbarUpdateGeneration
        isApplyingTerminalScrollbarUpdate = true
        defer {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.terminalScrollbarUpdateGeneration == updateGeneration else { return }
                self.isApplyingTerminalScrollbarUpdate = false
            }
        }

        guard let scrollbar = terminalView.scrollbar else {
            // Reset case (e.g., tmux tracking just ended with no native
            // scrollback to restore, or fresh terminal). Shrink the
            // document view back to the visible viewport so we don't
            // leave tmux's history-sized geometry stuck in UIScrollView.
            lastObservedScrollbar = nil
            resetDocumentToViewport()
            return
        }

        let wasAtLiveBottom = lastObservedScrollbar.map(isVisuallyAtLiveBottom) ?? isAtCurrentScrollRangeBottom()

        // Update document view height based on total scrollback
        updateDocumentHeight(scrollbar: scrollbar)

        if terminalView.multiplexerScrollActive {
            revealMultiplexerScrollIndicator(force: false)
        }

        // Never reposition the scroll view while the user's gesture is in ANY
        // phase — repositioning fights the gesture every time:
        //  - dragging: yanks contentOffset back to the bottom edge, cancelling the
        //    pan and its rubber-band overscroll (the bottom "wall").
        //  - decelerating: a sync on the first momentum frame of an upward flick
        //    from the bottom kills the deceleration, leaving the drag with no coast.
        //  - tracking (finger down, not yet moved): a tap to catch the bottom
        //    rubber-band spring is snapped straight out to the edge instead of
        //    freezing (the iOS catch-the-spring gesture).
        // We gate on the scroll view's own touch/momentum state rather than
        // isLiveScrolling, because a tap that interrupts the bounce can leave
        // isLiveScrolling already false — so the `!isLiveScrolling` branch would
        // otherwise fire the sync mid-gesture. Sync (follow live bottom /
        // programmatic output) only once the finger is up and motion has settled.
        let userGestureInFlight = scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
        if !userGestureInFlight, !isLiveScrolling || wasAtLiveBottom {
            synchronizeScrollPosition(scrollbar: scrollbar)
        }

        lastObservedScrollbar = scrollbar
    }

    private var isScrollViewUserInteracting: Bool {
        scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
    }

    private func isVisuallyAtLiveBottom(scrollbar: Ghostty.Action.Scrollbar) -> Bool {
        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return false }

        let bottomOffset = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
        let bottomModelOffsetY = CGFloat(bottomOffset) * cellHeight
        let currentModelOffsetY = scrollModelOffsetY(forContentOffsetY: scrollView.contentOffset.y)

        // Keep a small tolerance for subpixel rounding and Catalyst's
        // model/physical scale conversion, but don't mask real scrollback.
        return currentModelOffsetY >= bottomModelOffsetY - max(1, cellHeight * 0.25)
    }

    private func isAtCurrentScrollRangeBottom() -> Bool {
        let range = scrollableOffsetRangeY()
        let currentOffsetY = min(max(scrollView.contentOffset.y, range.lowerBound), range.upperBound)
        return currentOffsetY >= range.upperBound - 1
    }

    private func clearStaleLiveScrollStateIfNeeded() {
        guard isLiveScrolling, !isScrollViewUserInteracting else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastLiveScrollEventTime > Self.staleLiveScrollGraceInterval else { return }
        isLiveScrolling = false
        isTouchScrolling = false
        wasRubberBandingDuringScroll = false
        #if !targetEnvironment(macCatalyst)
        updateTerminalBottomInsetSuppression(rubberBanding: false)
        isTouchScrollbarDrag = false
        #endif
    }

    private func performWithoutNativeScrollIndicatorFlash(_ updates: () -> Void) {
        let wasShowingIndicator = scrollView.showsVerticalScrollIndicator
        guard wasShowingIndicator else {
            updates()
            return
        }

        restoreNativeScrollIndicatorWorkItem?.cancel()
        scrollView.showsVerticalScrollIndicator = false
        updates()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let nativeScrollActive = !(self.terminalView.isMouseCaptured || self.terminalView.usesHerdrFallbackScrolling)
                || self.terminalView.multiplexerScrollActive
            self.scrollView.showsVerticalScrollIndicator = nativeScrollActive
            self.restoreNativeScrollIndicatorWorkItem = nil
        }
        restoreNativeScrollIndicatorWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func setContentOffsetFromTerminalSync(_ offset: CGPoint) {
        terminalScrollSyncGeneration &+= 1
        let generation = terminalScrollSyncGeneration
        isApplyingTerminalScrollSync = true
        scrollView.setContentOffset(offset, animated: false)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminalScrollSyncGeneration == generation else { return }
            self.isApplyingTerminalScrollSync = false
        }
    }

    /// Collapse the scroll document to viewport size and reset offset.
    /// Called when there's no scrollbar state to mirror — e.g. after
    /// tmux tracking ends without a native snapshot to restore.
    private func resetDocumentToViewport() {
        let frameHeight = scrollView.frame.height
        guard frameHeight > 0 else { return }
        documentHeightConstraint?.constant = frameHeight
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        if scrollView.contentOffset != .zero {
            setContentOffsetFromTerminalSync(.zero)
        }
        updateTerminalPositionForCurrentOffset()
        lastSentRow = 0
        resetSmoothScrollOffset()
    }

    /// Update document view height to match scrollback size
    private func updateDocumentHeight(scrollbar: Ghostty.Action.Scrollbar) {
        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else {
            return
        }

        // Calculate document height from the scrollable terminal range. The
        // model range is in framebuffer pixels (cellHeight is pixels); we use a
        // shorter physical (points) range and map it back to the full terminal
        // scrollback range, so the finger tracks 1:1 on every display scale and
        // native bounce physics stay untouched.
        let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
        let frameHeight = scrollView.frame.height
        let gridHeight = CGFloat(scrollbar.len) * cellHeight
        let modelScrollableHeight = max(0, documentGridHeight - gridHeight)
        let physicalScrollableHeight = modelScrollableHeight / scrollCoordinateScale
        let documentHeight = frameHeight + physicalScrollableHeight

        // Update the stored height constraint
        guard let heightConstraint = documentHeightConstraint else {
            Ghostty.logger.error("TerminalScrollView: Height constraint not found!")
            return
        }

        // Steady-state scrolling reports the same total/len every frame; a
        // forced layout pass for an unchanged height is pure cost.
        guard heightConstraint.constant != documentHeight else { return }
        heightConstraint.constant = documentHeight

        // Force layout update
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
    }

    /// Synchronize scrollbar position to match Ghostty's scrollback state
    private func synchronizeScrollPosition(scrollbar: Ghostty.Action.Scrollbar) {
        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }

        let isAtLiveBottom = scrollbar.offset + scrollbar.len >= scrollbar.total
        let shouldPreserveSmoothScrollback =
            userParkedInSmoothScrollback &&
            !useLineScrollback &&
            !terminalView.multiplexerScrollActive &&
            !isAtLiveBottom

        let preservedSmoothOffset: CGFloat
        if shouldPreserveSmoothScrollback {
            let maxOffset = max(0, cellHeight - CGFloat.ulpOfOne)
            preservedSmoothOffset = min(max(lastSentSmoothScrollOffset, 0), maxOffset)
        } else {
            preservedSmoothOffset = 0
        }

        // Calculate scroll offset from scrollbar offset
        // UIKit uses top-left origin, same as terminal coordinate system
        let modelOffsetY = CGFloat(scrollbar.offset) * cellHeight + preservedSmoothOffset
        let offsetY = contentOffsetY(forScrollModelOffsetY: modelOffsetY)

        // Update scroll view position (for scrollbar indicator display)
        setContentOffsetFromTerminalSync(CGPoint(x: 0, y: offsetY))

        updateTerminalPositionForCurrentOffset()

        // Update last sent row
        lastSentRow = Int(scrollbar.offset)
        if shouldPreserveSmoothScrollback {
            lastSentSmoothScrollOffset = preservedSmoothOffset
        } else {
            resetSmoothScrollOffset()
        }

        // Keep programmatic autoscroll silent. UIKit will reveal the native
        // indicator for real UIScrollView gestures; multiplexer samples are
        // the one programmatic path that represents user scroll activity.
        if terminalView.multiplexerScrollActive {
            revealMultiplexerScrollIndicator(force: false)
        }
    }

    /// Ask UIKit to show the real vertical scroll indicator for multiplexer-
    /// owned scroll position updates without running a synthetic pulse timer.
    private func revealMultiplexerScrollIndicator(force: Bool) {
        guard terminalView.multiplexerScrollActive,
              scrollView.showsVerticalScrollIndicator,
              scrollView.contentSize.height > scrollView.bounds.height else {
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        guard force || now - lastMultiplexerScrollIndicatorRevealTime >= Self.multiplexerScrollIndicatorRevealInterval else {
            return
        }

        lastMultiplexerScrollIndicatorRevealTime = now
        scrollView.flashScrollIndicators()
    }

    /// Keep UIKit's real vertical scroll indicator visible while Ghostty's
    /// selection auto-scroll moves the viewport. `flashScrollIndicators()` fades
    /// on every call (flickery on iPad, unreliable on Catalyst for programmatic
    /// offsets), so we hold the actual UIScrollView indicator subviews visible
    /// briefly and refresh that hold while selection updates keep arriving.
    private func holdSelectionScrollIndicatorVisible(force: Bool) {
        guard terminalView.isActivelySelecting,
              scrollView.isScrollEnabled,
              scrollView.showsVerticalScrollIndicator,
              scrollView.contentSize.height > scrollView.bounds.height else {
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        guard force || now - lastSelectionScrollIndicatorRevealTime >= Self.selectionScrollIndicatorRevealInterval else {
            return
        }

        lastSelectionScrollIndicatorRevealTime = now
        forceNativeVerticalScrollIndicatorVisible()
    }

    private func forceNativeVerticalScrollIndicatorVisible(allowFlashFallback: Bool = true) {
        #if targetEnvironment(macCatalyst)
        forceCatalystScrollIndicatorVisible()
        #else
        let indicatorViews = nativeVerticalScrollIndicatorViews()

        if indicatorViews.isEmpty {
            guard allowFlashFallback else { return }
            scrollView.flashScrollIndicators()
            DispatchQueue.main.async { [weak self] in
                self?.forceNativeVerticalScrollIndicatorVisible(allowFlashFallback: false)
            }
            return
        }

        selectionScrollIndicatorHoldWorkItem?.cancel()

        UIView.performWithoutAnimation {
            for indicatorView in indicatorViews {
                indicatorView.layer.removeAllAnimations()
                indicatorView.isHidden = false
                indicatorView.alpha = 1
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isScrollViewUserInteracting else {
                self.selectionScrollIndicatorHoldWorkItem = nil
                return
            }
            UIView.animate(withDuration: 0.2) {
                for indicatorView in self.nativeVerticalScrollIndicatorViews() {
                    indicatorView.alpha = 0
                }
            }
            self.selectionScrollIndicatorHoldWorkItem = nil
        }
        selectionScrollIndicatorHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        #endif
    }

    private func nativeVerticalScrollIndicatorViews() -> [UIView] {
        scrollView.subviews.filter { subview in
            guard subview !== documentView,
                  subview.frame.width <= 32,
                  subview.frame.maxX >= scrollView.bounds.maxX - 32 else {
                return false
            }
            return subview.frame.height > 0
        }
    }

    #if targetEnvironment(macCatalyst)
    private func forceCatalystScrollIndicatorVisible() {
        guard !isScrollViewUserInteracting else { return }

        scrollView.showsVerticalScrollIndicator = true
        scrollView.layoutIfNeeded()

        if catalystSelectionIndicatorNudgeOriginalOffset != nil {
            scrollView.flashScrollIndicators()
            return
        }

        let range = scrollableOffsetRangeY()
        let currentOffset = scrollView.contentOffset
        let nudgeY: CGFloat
        if currentOffset.y < range.upperBound {
            nudgeY = min(currentOffset.y + 1, range.upperBound)
        } else if currentOffset.y > range.lowerBound {
            nudgeY = max(currentOffset.y - 1, range.lowerBound)
        } else {
            scrollView.flashScrollIndicators()
            return
        }

        catalystSelectionIndicatorNudgeOriginalOffset = currentOffset
        terminalScrollSyncGeneration &+= 1
        let generation = terminalScrollSyncGeneration
        isApplyingTerminalScrollSync = true
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(CGPoint(x: currentOffset.x, y: nudgeY), animated: false)
            scrollView.flashScrollIndicators()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard self.terminalScrollSyncGeneration == generation else {
                self.catalystSelectionIndicatorNudgeOriginalOffset = nil
                return
            }
            let originalOffset = self.catalystSelectionIndicatorNudgeOriginalOffset ?? currentOffset
            let currentRange = self.scrollableOffsetRangeY()
            let restoredY = min(max(originalOffset.y, currentRange.lowerBound), currentRange.upperBound)
            UIView.performWithoutAnimation {
                self.scrollView.setContentOffset(CGPoint(x: originalOffset.x, y: restoredY), animated: false)
                self.scrollView.flashScrollIndicators()
            }
            self.catalystSelectionIndicatorNudgeOriginalOffset = nil
            self.isApplyingTerminalScrollSync = false
        }
    }
    #endif

    /// Scroll to the bottom (live terminal view) in response to user input
    func scrollToBottom() {
        guard !terminalView.multiplexerScrollActive else { return }
        guard let scrollbar = terminalView.scrollbar else { return }

        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }

        // Don't scroll if user is actively selecting text
        guard !terminalView.isActivelySelecting else {
            return
        }

        // Calculate bottom offset (showing the most recent rows)
        let bottomOffset = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
        let modelOffsetY = CGFloat(bottomOffset) * cellHeight
        let offsetY = contentOffsetY(forScrollModelOffsetY: modelOffsetY)
        let visuallyAtBottom = abs(scrollView.contentOffset.y - offsetY) <= 0.5
        let needsSmoothOffsetReset =
            lastSentSmoothScrollOffset != 0 ||
            terminalView.smoothScrollOffset != 0 ||
            terminalView.smoothScrollActive

        if visuallyAtBottom {
            userParkedInSmoothScrollback = false
            lastSentRow = Int(bottomOffset)
            if needsSmoothOffsetReset {
                lastSentSmoothScrollOffset = 0
                terminalView.scrollToRowSmooth(row: Int(bottomOffset), offset: 0)
            }
            return
        }

        // Check if already at bottom after clearing any stale pixel offset.
        if scrollbar.offset + scrollbar.len >= scrollbar.total {
            resetSmoothScrollOffset()
            if abs(scrollView.contentOffset.y - offsetY) > 0.5 {
                setContentOffsetFromTerminalSync(CGPoint(x: 0, y: offsetY))
                updateTerminalPositionForCurrentOffset()
            }
            lastSentRow = Int(bottomOffset)
            return
        }

        resetSmoothScrollOffset()

        // Send scroll_to_row action to Ghostty to render the bottom rows
        _ = terminalView.performAction("scroll_to_row:\(bottomOffset)")

        // Update scroll position (for scrollbar indicator)
        setContentOffsetFromTerminalSync(CGPoint(x: 0, y: offsetY))

        updateTerminalPositionForCurrentOffset()

        // Update last sent row
        lastSentRow = Int(bottomOffset)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isLiveScrolling = true
        lastLiveScrollEventTime = Date().timeIntervalSinceReferenceDate
        isTouchScrolling = false
        wasRubberBandingDuringScroll = false
        // Reset to native deceleration so the velocity→coast decision in
        // scrollViewWillEndDragging starts from a clean, native baseline.
        scrollView.decelerationRate = .normal
        #if !targetEnvironment(macCatalyst)
        isTouchScrolling = scrollView.panGestureRecognizer.numberOfTouches > 0
        // Handles are window overlays; hide while the scroll view and Ghostty
        // viewport are moving, then restore once scrolling has settled.
        terminalView.hideSelectionHandles(animated: false)
        #endif
        let currentOffsetY = scrollView.contentOffset.y
        lastTouchScrollOffsetY = shouldUseRubberBandScrollback ? clampedScrollModelOffsetY(currentOffsetY) : currentOffsetY
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // Touch only. Trackpad/scroll-wheel velocity already carries the OS's own
        // scroll acceleration, so extending its throw double-amplifies (it
        // overshoots). Direct touch has no such acceleration, so our boost is its
        // only one. isTouchScrolling is true only for a finger drag (false for
        // scroll-wheel gestures and on Catalyst), leaving trackpad fully native.
        guard isTouchScrolling else { return }

        // Acceleration happens only here, on release. Extend the momentum target
        // by a velocity-gated multiplier: a hard flick is sent to a much farther
        // stop (reached at speed under the native deceleration rate), a slow
        // release barely changes so deliberate drags settle tight. The active
        // drag itself is never touched, so finger-down tracking stays 1:1.
        let m = flickReachMultiplier(forVelocity: velocity.y)
        guard m > 1 else { return }
        let currentY = scrollView.contentOffset.y
        // Leave the throw alone if the release happened mid rubber-band.
        guard !isRubberBanding(offsetY: currentY) else { return }
        let naturalTargetY = targetContentOffset.pointee.y
        let extendedY = currentY + (naturalTargetY - currentY) * m
        // Only extend when the throw lands strictly INSIDE the scrollable range.
        // Near an edge, leave UIScrollView's natural target: extending into the
        // top/bottom makes the momentum arrive with excess velocity and slams the
        // rubber-band (bouncing hard and resting past the edge). Native edge
        // deceleration already bounces correctly, so don't touch those flicks.
        let range = scrollableOffsetRangeY()
        let margin: CGFloat = 1
        if extendedY > range.lowerBound + margin, extendedY < range.upperBound - margin {
            targetContentOffset.pointee.y = extendedY
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleSmoothScrollAtBounds()
            isLiveScrolling = false
            #if !targetEnvironment(macCatalyst)
            terminalView.scheduleSelectionHandleSync(afterGhosttyAppTick: true)
            #endif
            applyVerticalScrollState(isCaptured: terminalView.isMouseCaptured)
        }
        isTouchScrolling = false
        if !decelerate {
            wasRubberBandingDuringScroll = false
        }
        #if !targetEnvironment(macCatalyst)
        if !decelerate {
            updateTerminalBottomInsetSuppression(rubberBanding: false)
            isTouchScrollbarDrag = false
        }
        #endif
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A touch can interrupt deceleration — e.g. tapping to catch a rubber-band
        // spring — which fires this delegate while the finger is still down
        // (isTracking). The gesture isn't actually over, so don't settle or
        // un-suppress the rubber-band inset: that collapses the bottom rubber-band
        // gap the user is holding (the top is unaffected because its gap doesn't
        // depend on the bottom inset). The true end — finger up, the spring
        // resumes and ends, or a new drag — runs this settle for real.
        guard !scrollView.isTracking else { return }
        settleSmoothScrollAtBounds()
        isLiveScrolling = false
        isTouchScrolling = false
        wasRubberBandingDuringScroll = false
        #if !targetEnvironment(macCatalyst)
        updateTerminalBottomInsetSuppression(rubberBanding: false)
        isTouchScrollbarDrag = false
        #endif
        #if !targetEnvironment(macCatalyst)
        terminalView.scheduleSelectionHandleSync(afterGhosttyAppTick: true)
        #endif
        applyVerticalScrollState(isCaptured: terminalView.isMouseCaptured)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isApplyingTerminalScrollSync || isApplyingTerminalScrollbarUpdate {
            clearStaleLiveScrollStateIfNeeded()
            updateTerminalPositionForCurrentOffset()
            return
        }

        clearStaleLiveScrollStateIfNeeded()

        #if targetEnvironment(macCatalyst)
        // While the window is being dragged, Catalyst routes pointer scroll
        // deltas into whatever slides under the pointer. Swallow them: keep
        // the terminal pinned and never begin live scrolling; the next
        // scrollbar sync corrects any offset drift.
        if WindowDragObserver.shared.isWindowMoving {
            updateTerminalPositionForCurrentOffset()
            return
        }
        ensureCatalystLiveScrollTracking()
        #else
        if applyTouchScrollBoostIfNeeded(scrollView) {
            updateTerminalPositionForCurrentOffset()
            return
        }
        #endif

        updateTerminalPositionForCurrentOffset()

        // Only process user-initiated scrolling
        guard isLiveScrolling else { return }

        // Send the user-driven scroll to the owner of the current scroll
        // model. Normal scrollback is absolute. Tmux copy-mode is relative:
        // tmux renders the viewport, and this UIScrollView only represents
        // its native scrollbar position.
        handleLiveScroll()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // iOS status-bar tap. Use Ghostty's canonical scroll-to-top (same as
        // Cmd+Home) instead of letting UIKit animate the raw content offset:
        // the native animation only fires scrollViewDidScroll (not
        // WillBeginDragging), so it would be gated out by isLiveScrolling and
        // also fight our scroll-model sync. The scrollbar-update notification
        // syncs this UIScrollView to the top afterwards. Works in both normal
        // scrollback and capture/copy-mode.
        terminalView.performActionAsync("scroll_to_top")
        #if !targetEnvironment(macCatalyst)
        // The resulting scroll arrives as a programmatic (non-live) sync, which
        // handleScrollbarUpdate would normally run silently. Flag it so the
        // native indicator flashes, giving the tap a visible affordance.
        pendingStatusBarScrollIndicatorReveal = true
        #endif
        return false
    }

    #if targetEnvironment(macCatalyst)
    private func ensureCatalystLiveScrollTracking() {
        guard !isLiveScrolling else { return }

        isLiveScrolling = true
        lastLiveScrollEventTime = Date().timeIntervalSinceReferenceDate
        wasRubberBandingDuringScroll = false
    }
    #endif

    /// Handle user scrolling and send it to the active scroll owner.
    private func handleLiveScroll() {
        lastLiveScrollEventTime = Date().timeIntervalSinceReferenceDate

        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }

        // Calculate which row is at the top of the visible area. UIScrollView
        // may temporarily overshoot during rubber-band bounce; Ghostty should
        // stay pinned to the nearest real scrollback row while UIKit animates.
        let rawOffsetY = scrollView.contentOffset.y
        let offsetY = scrollModelOffsetY(forContentOffsetY: rawOffsetY)
        var row = max(0, Int(offsetY / cellHeight))
        var smoothOffset = offsetY - CGFloat(row) * cellHeight

        if !useLineScrollback, !terminalView.multiplexerScrollActive, let scrollbar = terminalView.scrollbar {
            let bottomRow = max(0, Int(scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0))
            let bottomOffsetY = CGFloat(bottomRow) * cellHeight
            if bottomRow > 0, offsetY >= bottomOffsetY {
                // Keep the core/render state pinned to the true bottom row.
                // Representing bottom as previous-row + one full-cell offset
                // is visually equivalent in steady state, but it alternates
                // with bottom-row + zero offset during UIKit spring-back and
                // produces a visible bottom-edge jump.
                row = bottomRow
                smoothOffset = 0
            }
        }

        let deltaRows = row - lastSentRow

        if let state = terminalView.herdrEndpointPane {
            resetSmoothScrollOffset()
            guard row != lastSentRow else { return }
            lastSentRow = row
            state.scrollToRow(row)
            return
        }

        if terminalView.multiplexerScrollActive {
            resetSmoothScrollOffset()
            guard row != lastSentRow else { return }
            terminalView.noteUserScrollForScrollIndicator()
            lastSentRow = row
            terminalView.sendNativeScrollEvent(
                deltaX: 0,
                deltaY: CGFloat(deltaRows) * cellHeight
            )
            return
        }

        if useLineScrollback {
            resetSmoothScrollOffset()
            guard row != lastSentRow else { return }
            terminalView.noteUserScrollForScrollIndicator()
            lastSentRow = row
            _ = terminalView.performAction("scroll_to_row:\(row)")
            return
        }

        applySmoothScroll(row: row, offset: smoothOffset)
    }

    private func applySmoothScroll(row: Int, offset: CGFloat) {
        let cellHeight = terminalView.cellSize.height
        let maxOffset = max(0, cellHeight - CGFloat.ulpOfOne)
        let normalized = max(0, min(offset, maxOffset))
        let rowChanged = row != lastSentRow
        let offsetChanged: Bool
        if normalized == 0 {
            offsetChanged = lastSentSmoothScrollOffset != 0
        } else if lastSentSmoothScrollOffset == 0 {
            offsetChanged = true
        } else {
            offsetChanged = abs(normalized - lastSentSmoothScrollOffset) > 0.25
        }

        guard rowChanged || offsetChanged else { return }

        terminalView.noteUserScrollForScrollIndicator()
        lastSentRow = row
        lastSentSmoothScrollOffset = normalized
        if !useLineScrollback,
           !terminalView.multiplexerScrollActive,
           let scrollbar = terminalView.scrollbar {
            let bottomRow = max(0, Int(scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0))
            userParkedInSmoothScrollback = normalized > 0 || row < bottomRow
        }
        terminalView.scrollToRowSmooth(row: row, offset: normalized)
    }

    private func resetSmoothScrollOffset() {
        userParkedInSmoothScrollback = false
        guard lastSentSmoothScrollOffset != 0 ||
              terminalView.smoothScrollOffset != 0 ||
              terminalView.smoothScrollActive else { return }
        lastSentSmoothScrollOffset = 0
        terminalView.setSmoothScrollOffset(0)
    }

    private func settleSmoothScrollAtBounds() {
        guard lastSentSmoothScrollOffset != 0 else { return }
        guard let scrollbar = terminalView.scrollbar else {
            resetSmoothScrollOffset()
            return
        }

        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }

        let bottomRow = max(0, Int(scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0))
        guard bottomRow > 0 else {
            resetSmoothScrollOffset()
            return
        }

        let bottomOffsetY = CGFloat(bottomRow) * cellHeight
        let modelOffsetY = scrollModelOffsetY(forContentOffsetY: scrollView.contentOffset.y)
        guard modelOffsetY >= bottomOffsetY - 0.5 else { return }

        lastSentRow = bottomRow
        lastSentSmoothScrollOffset = 0
        userParkedInSmoothScrollback = false
        terminalView.scrollToRowSmooth(row: bottomRow, offset: 0)
    }

    // MARK: - Momentum Coast

    /// Map a drag-release velocity (points/ms) to a momentum-distance multiplier:
    /// 1.0 (native, tight settle) at/below `flickVelocityLo`, ramping linearly to
    /// `flickReachMax` at/above `flickVelocityHi`. So only a hard flick extends
    /// the throw; a slow release stays effectively 1:1.
    private func flickReachMultiplier(forVelocity velocity: CGFloat) -> CGFloat {
        let speed = abs(velocity)
        if speed <= Self.flickVelocityLo { return 1 }
        if speed >= Self.flickVelocityHi { return Self.flickReachMax }
        let t = (speed - Self.flickVelocityLo) / (Self.flickVelocityHi - Self.flickVelocityLo)
        return 1 + t * (Self.flickReachMax - 1)
    }

    // MARK: - Touch Scroll Boosting

    private func scrollableOffsetRangeY() -> ClosedRange<CGFloat> {
        let inset = scrollView.adjustedContentInset
        let minOffsetY = -inset.top
        let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        return minOffsetY...maxOffsetY
    }

    private func clampedScrollModelOffsetY(_ offsetY: CGFloat) -> CGFloat {
        let range = scrollableOffsetRangeY()
        return min(max(offsetY, range.lowerBound), range.upperBound)
    }

    /// Scale between the UIScrollView physical (points) space and the terminal
    /// "model" space, which is in framebuffer PIXELS because `cellSize` is
    /// reported by ghostty core in pixels and stored unconverted. Mapping
    /// points→pixels by the display backing scale gives 1:1 finger tracking on
    /// every display scale (2x iPad, 3x iPhone, Retina Catalyst); `scrollSpeedGain`
    /// then scales that for reach. This applies to ALL scroll modes — normal
    /// smooth scrollback, line-scrollback, and multiplexer copy-mode — because
    /// they all compute `row = offsetY / cellHeight_pixels` and so all need the
    /// points→pixels conversion. (Line/mux previously returned identity here and
    /// relied on a since-removed per-frame touch boost, which left them running
    /// at 1/scale — unusably slow on 3x devices.)
    private var scrollCoordinateScale: CGFloat {
        let scale = terminalView.contentScaleFactor
        let base = scale > 0 ? scale : 1
        return base * Self.scrollSpeedGain
    }

    private func scrollModelOffsetY(forContentOffsetY contentOffsetY: CGFloat) -> CGFloat {
        let physicalOffsetY = clampedScrollModelOffsetY(contentOffsetY)
        let scale = scrollCoordinateScale
        guard scale != 1 else { return physicalOffsetY }
        let range = scrollableOffsetRangeY()
        return range.lowerBound + (physicalOffsetY - range.lowerBound) * scale
    }

    private func contentOffsetY(forScrollModelOffsetY modelOffsetY: CGFloat) -> CGFloat {
        let range = scrollableOffsetRangeY()
        let scale = scrollCoordinateScale
        let physicalOffsetY: CGFloat
        if scale == 1 {
            physicalOffsetY = modelOffsetY
        } else {
            physicalOffsetY = range.lowerBound + (modelOffsetY - range.lowerBound) / scale
        }
        return min(max(physicalOffsetY, range.lowerBound), range.upperBound)
    }

    private func rubberBandOffsetY(forBoostedOffset offsetY: CGFloat) -> CGFloat {
        let range = scrollableOffsetRangeY()
        if offsetY < range.lowerBound {
            return range.lowerBound - rubberBandDistance(forOvershoot: range.lowerBound - offsetY)
        }
        if offsetY > range.upperBound {
            return range.upperBound + rubberBandDistance(forOvershoot: offsetY - range.upperBound)
        }
        return offsetY
    }

    private func rubberBandDistance(forOvershoot overshoot: CGFloat) -> CGFloat {
        guard overshoot > 0 else { return 0 }
        let dimension = max(scrollView.bounds.height, 1)
        let constant: CGFloat = 0.55
        let nativeDistance = (overshoot * constant * dimension) / (dimension + constant * overshoot)
        let maxDistance = max(24, min(dimension * 0.18, 140))
        return min(nativeDistance, maxDistance)
    }

    private func isRubberBanding(offsetY: CGFloat) -> Bool {
        guard shouldUseRubberBandScrollback else { return false }
        let range = scrollableOffsetRangeY()
        return offsetY < range.lowerBound - 0.5 || offsetY > range.upperBound + 0.5
    }

    private func updateTerminalPositionForCurrentOffset() {
        let clampedOffsetY = clampedScrollModelOffsetY(scrollView.contentOffset.y)
        #if targetEnvironment(macCatalyst)
        if shouldUseRubberBandScrollback {
            let translationY = clampedOffsetY - scrollView.contentOffset.y
            terminalView.transform = .identity
            terminalView.setRubberBandOffset(abs(translationY) > 0.5 ? translationY : 0)
        } else {
            terminalView.transform = .identity
            terminalView.setRubberBandOffset(0)
        }
        #else
        let rubberBanding = isRubberBanding(offsetY: scrollView.contentOffset.y)
        updateTerminalBottomInsetSuppression(rubberBanding: rubberBanding)
        if shouldUseRubberBandScrollback {
            terminalTopConstraint?.constant = clampedOffsetY
        } else {
            terminalTopConstraint?.constant = scrollView.contentOffset.y
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func updateTerminalBottomInsetSuppression(rubberBanding: Bool) {
        let suppress = shouldUseRubberBandScrollback && rubberBanding
        guard terminalView.suppressBottomInsetUpdatesForScrollRubberBand != suppress else { return }
        terminalView.suppressBottomInsetUpdatesForScrollRubberBand = suppress
        if !suppress {
            terminalView.updateBottomInset()
        }
    }
    #endif

    /// Touch-driven scroll bookkeeping. The finger-down drag is left strictly
    /// 1:1 — acceleration is applied only on release (see scrollViewWillEndDragging),
    /// so nothing is boosted here. We keep the last-offset / rubber-band state
    /// current and always return `false` so the caller runs `handleLiveScroll()`.
    @discardableResult
    private func applyTouchScrollBoostIfNeeded(_ scrollView: UIScrollView) -> Bool {
        let offsetY = scrollView.contentOffset.y
        if shouldUseRubberBandScrollback, isRubberBanding(offsetY: offsetY) {
            wasRubberBandingDuringScroll = true
            lastTouchScrollOffsetY = clampedScrollModelOffsetY(offsetY)
        } else {
            wasRubberBandingDuringScroll = false
            lastTouchScrollOffsetY = shouldUseRubberBandScrollback
                ? clampedScrollModelOffsetY(offsetY)
                : offsetY
        }
        return false
    }

    }

    // MARK: - Progress Bar View

    /// UIKit-based progress bar view for terminal progress indicators
    private class ProgressBarView: UIView {
        private let backgroundView = UIView()
        private let foregroundView = UIView()
        private var animationDisplayLink: CADisplayLink?
        private var animationStartTime: CFTimeInterval = 0
        private var currentState: Ghostty.Action.ProgressReport.State = .remove

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupViews()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            stopAnimation()
        }

        private func setupViews() {
            backgroundColor = .clear

            // Background view (semi-transparent)
            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(backgroundView)

            // Foreground view (solid color, animated for indeterminate states)
            // Use manual layout for animation (not Auto Layout)
            foregroundView.translatesAutoresizingMaskIntoConstraints = true
            addSubview(foregroundView)

            NSLayoutConstraint.activate([
                backgroundView.topAnchor.constraint(equalTo: topAnchor),
                backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        func update(with report: Ghostty.Action.ProgressReport) {
            currentState = report.state
            currentProgress = report.progress

            let color = colorForState(report.state)
            backgroundView.backgroundColor = color.withAlphaComponent(0.3)
            foregroundView.backgroundColor = color

            switch report.state {
            case .set:
                // Determinate progress - fixed width
                stopAnimation()
                if let progress = report.progress {
                    let widthMultiplier = CGFloat(progress) / 100.0
                    foregroundView.frame = CGRect(
                        x: 0,
                        y: 0,
                        width: bounds.width * widthMultiplier,
                        height: bounds.height
                    )
                }

            case .indeterminate, .error, .pause:
                // Indeterminate progress - bouncing animation
                startAnimation()

            case .remove:
                stopAnimation()
            }
        }

        private func colorForState(_ state: Ghostty.Action.ProgressReport.State) -> UIColor {
            switch state {
            case .error:
                return .systemRed
            case .pause:
                return .systemOrange
            default:
                return .systemBlue
            }
        }

        private func startAnimation() {
            guard animationDisplayLink == nil else { return }

            animationStartTime = CACurrentMediaTime()
            let displayLink = CADisplayLink(target: self, selector: #selector(updateAnimation))
            displayLink.add(to: .main, forMode: .common)
            animationDisplayLink = displayLink
        }

        fileprivate func stopAnimation() {
            animationDisplayLink?.invalidate()
            animationDisplayLink = nil
        }

        @objc private func updateAnimation() {
            let currentTime = CACurrentMediaTime()
            let elapsed = currentTime - animationStartTime
            // 1.2 seconds each way (matching SwiftUI's autoreverses behavior)
            // Total cycle time is 2.4 seconds
            let halfDuration = 1.2
            let fullDuration = halfDuration * 2

            // Calculate position (0 to 1 and back)
            let cycleProgress = (elapsed.truncatingRemainder(dividingBy: fullDuration)) / fullDuration
            var position: CGFloat

            if cycleProgress < 0.5 {
                // First half: 0 to 1
                position = CGFloat(cycleProgress * 2)
            } else {
                // Second half: 1 to 0
                position = CGFloat(2 - cycleProgress * 2)
            }

            // Apply easing
            position = easeInOut(position)

            // Bar width is 25% of total width
            let barWidth = bounds.width * 0.25
            let maxX = bounds.width - barWidth

            foregroundView.frame = CGRect(
                x: maxX * position,
                y: 0,
                width: barWidth,
                height: bounds.height
            )
        }

        private func easeInOut(_ t: CGFloat) -> CGFloat {
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // Ensure foreground view has correct bounds for current state
            switch currentState {
            case .set:
                // Re-calculate determinate progress with new bounds
                if let progress = currentProgress {
                    let widthMultiplier = CGFloat(progress) / 100.0
                    foregroundView.frame = CGRect(
                        x: 0,
                        y: 0,
                        width: bounds.width * widthMultiplier,
                        height: bounds.height
                    )
                }
            case .indeterminate, .error, .pause:
                // Animation will update frame on next display link callback
                break
            default:
                break
            }
        }

        private var currentProgress: UInt8?
    }
}

// MARK: - UIDropInteractionDelegate

extension Ghostty.TerminalScrollView: UIDropInteractionDelegate {
    /// Forward drop handling to the terminal view
    /// This catches drops at the scroll view level on Mac Catalyst where
    /// UIScrollView can intercept drops before they reach nested views

    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        // Delegate to terminal view's drop handling
        return terminalView.dropInteraction(interaction, canHandle: session)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        // Delegate to terminal view's drop handling
        return terminalView.dropInteraction(interaction, sessionDidUpdate: session)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        // Delegate to terminal view's drop handling
        terminalView.dropInteraction(interaction, performDrop: session)
    }
}
