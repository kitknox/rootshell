//
//  TerminalView+Scroll.swift
//  rootshell
//
//  Platform-specific scroll handling for TerminalView with momentum physics
//  - Mac Catalyst: Uses UIPanGestureRecognizer with scroll type mask for native scroll wheel
//  - iOS/visionOS: Uses UIPanGestureRecognizer for trackpad + two-finger touch scrolling
//
//  In capture mode (tmux, vim): Custom momentum scrolling with CADisplayLink
//  In non-capture mode: UIScrollView handles scrolling with native momentum
//

import UIKit
import os
import GhosttyKit
import ObjectiveC
import Combine

// MARK: - Scroll Gesture Setup

extension Ghostty.TerminalView {

    /// Sets up platform-specific scroll handling
    /// Called from setupView() in TerminalView
    func setupScrollHandling() {
        #if targetEnvironment(macCatalyst)
        setupCatalystScrollHandling()
        #else
        setupIOSScrollHandling()
        #endif
    }
}

// MARK: - Common Momentum Scrolling
// Shared momentum physics implementation for both Mac Catalyst and iOS/visionOS

extension Ghostty.TerminalView {

    // MARK: - Associated Object Keys for Momentum State

    private static var displayLinkKey: UInt8 = 0
    private static var scrollVelocityXKey: UInt8 = 0
    private static var scrollVelocityYKey: UInt8 = 0
    private static var lastScrollTimeKey: UInt8 = 0

    // Deceleration rate per second (velocity multiplier)
    // 0.01 means velocity decays to 1% after 1 second - fast decay for snappy feel
    private static let decelerationPerSecond: CGFloat = 0.01
    private static let minimumVelocity: CGFloat = 100.0  // Points per second threshold (higher = stops sooner)

    // MARK: - Momentum State Properties

    private var momentumDisplayLink: CADisplayLink? {
        get { objc_getAssociatedObject(self, &Self.displayLinkKey) as? CADisplayLink }
        set { objc_setAssociatedObject(self, &Self.displayLinkKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var scrollVelocityX: CGFloat {
        get { (objc_getAssociatedObject(self, &Self.scrollVelocityXKey) as? CGFloat) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.scrollVelocityXKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var scrollVelocityY: CGFloat {
        get { (objc_getAssociatedObject(self, &Self.scrollVelocityYKey) as? CGFloat) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.scrollVelocityYKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var lastScrollTime: CFTimeInterval {
        get { (objc_getAssociatedObject(self, &Self.lastScrollTimeKey) as? CFTimeInterval) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.lastScrollTimeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: - Momentum Animation

    /// Start momentum scrolling animation with current velocity
    private func startMomentumScrolling() {
        // Just invalidate any existing display link, don't zero velocity
        momentumDisplayLink?.invalidate()

        let displayLink = CADisplayLink(target: self, selector: #selector(momentumTick))
        displayLink.add(to: .main, forMode: .common)
        momentumDisplayLink = displayLink
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        // Calculate frame duration for frame-rate independent physics
        let frameDuration = link.targetTimestamp - link.timestamp
        guard frameDuration > 0 && frameDuration < 0.5 else { return }  // Sanity check

        // Apply deceleration: velocity *= decelerationPerSecond^frameDuration
        // This gives smooth decay regardless of frame rate
        let decay = pow(Self.decelerationPerSecond, CGFloat(frameDuration))

        scrollVelocityX *= decay
        scrollVelocityY *= decay

        // Stop if velocity is below threshold
        if abs(scrollVelocityX) < Self.minimumVelocity && abs(scrollVelocityY) < Self.minimumVelocity {
            stopMomentumScrolling()
            return
        }

        // Calculate scroll delta for this frame
        // Velocity is in points/second, multiply by frameDuration to get points this frame
        // No 2x multiplier for momentum - that's only for active scrolling
        let deltaX = scrollVelocityX * CGFloat(frameDuration)
        let deltaY = scrollVelocityY * CGFloat(frameDuration)

        // Send scroll event to Ghostty
        sendNativeScrollEvent(deltaX: deltaX, deltaY: deltaY)
    }

    /// Stop momentum animation but preserve velocity for continued tracking
    /// Used when user continues scrolling (interrupts momentum but keeps velocity)
    fileprivate func interruptMomentumAnimation() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        // Don't zero velocity - tracking continues
    }

    /// Stop momentum scrolling animation and reset all state
    /// Note: fileprivate to allow access from platform-specific extensions in this file
    @discardableResult
    fileprivate func stopMomentumScrolling() -> Bool {
        let hadMomentum = momentumDisplayLink != nil
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        scrollVelocityX = 0
        scrollVelocityY = 0
        lastScrollTime = 0
        return hadMomentum
    }

    /// Public method to cancel momentum from external sources
    /// Called when switching tmux splits, receiving input, new touch, etc.
    @discardableResult
    func cancelMomentumScrolling() -> Bool {
        stopMomentumScrolling()
    }

    // MARK: - Scroll Event Helper

    /// Send scroll deltas to the captured application or server viewport.
    func sendNativeScrollEvent(deltaX: CGFloat, deltaY: CGFloat) {
        guard let surface = surface else { return }
        guard abs(deltaX) > 0.1 || abs(deltaY) > 0.1 else { return }

        // Use last known mouse position or center of view
        let scrollPosition = lastMousePosition != .zero
            ? lastMousePosition
            : CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        if let state = herdrEndpointPane {
            state.scroll(deltaX: deltaX, deltaY: deltaY, at: scrollPosition)
            return
        }

        if usesHerdrFallbackScrolling && !ghostty_surface_mouse_captured(surface) {
            sendHerdrFallbackScroll(deltaY: deltaY, at: scrollPosition)
            return
        }

        ghostty_surface_mouse_pos(
            surface,
            Double(scrollPosition.x),
            Double(scrollPosition.y),
            Ghostty.Input.Mods.none.cMods
        )

        let scrollMods = Ghostty.Input.ScrollMods(precision: true, momentum: .none)
        sendMouseScroll(deltaX: Double(deltaX), deltaY: Double(deltaY), mods: scrollMods.cMods)

        // Notify the multiplexer scroll-indicator observer that the user
        // generated scroll activity. The observer self-gates on capture +
        // alt-screen, so calls here are safe even outside a multiplexer.
        // Hooking the central funnel covers all four scroll handlers and
        // momentum ticks.
        multiplexerScrollObserver?.notifyScrollActivity()
    }

    // MARK: - Velocity Tracking Helper

    /// Track velocity from scroll gesture translation
    /// Returns true if velocity is significant enough for momentum
    func trackScrollVelocity(translation: CGPoint, gesture: UIPanGestureRecognizer) -> Bool {
        let now = CACurrentMediaTime()
        let dt = now - lastScrollTime

        // Skip velocity calculation if this is the first event (lastScrollTime was 0 or too old)
        // A gap > 0.5s means this is effectively a new scroll gesture
        if lastScrollTime == 0 || dt > 0.5 {
            lastScrollTime = now
            // For first event, use conservative velocity estimate
            // Don't divide by tiny frame time - just use translation as-is scaled to pts/sec
            scrollVelocityX = translation.x * 30  // ~30 events/sec typical scroll rate
            scrollVelocityY = translation.y * 30
            return abs(scrollVelocityX) > Self.minimumVelocity || abs(scrollVelocityY) > Self.minimumVelocity
        }

        if dt > 0 {
            // Calculate instantaneous velocity
            let instantVelocityX = translation.x / CGFloat(dt)
            let instantVelocityY = translation.y / CGFloat(dt)

            // Use exponential moving average for smoother velocity tracking
            // 0.4 = 40% new, 60% previous - responsive but smooth
            let alpha: CGFloat = 0.4
            scrollVelocityX = scrollVelocityX * (1 - alpha) + instantVelocityX * alpha
            scrollVelocityY = scrollVelocityY * (1 - alpha) + instantVelocityY * alpha
        }
        lastScrollTime = now

        return abs(scrollVelocityX) > Self.minimumVelocity || abs(scrollVelocityY) > Self.minimumVelocity
    }

    /// Reset velocity tracking state at gesture begin
    func resetVelocityTracking() {
        stopMomentumScrolling()
        lastScrollTime = 0  // Will be set on first trackScrollVelocity call
        scrollVelocityX = 0
        scrollVelocityY = 0
    }

    /// Clear tracked wheel velocity without changing gesture recognizer state.
    /// Used when a horizontal trackpad gesture is claimed by app-tab navigation
    /// so no captured-terminal momentum is seeded from the same movement.
    func clearTrackedScrollVelocity() {
        lastScrollTime = 0
        scrollVelocityX = 0
        scrollVelocityY = 0
    }

    /// Finalize velocity and start momentum if significant
    func finalizeVelocityAndStartMomentum(gesture: UIPanGestureRecognizer) {
        // Use gesture's velocity for final momentum (more accurate than our tracking)
        let gestureVelocity = gesture.velocity(in: self)
        scrollVelocityX = gestureVelocity.x
        scrollVelocityY = gestureVelocity.y

        if abs(scrollVelocityX) > Self.minimumVelocity || abs(scrollVelocityY) > Self.minimumVelocity {
            startMomentumScrolling()
        }
    }

    /// Start momentum using tracked velocity (for scroll wheel which doesn't have gesture velocity)
    func startMomentumFromTrackedVelocity() {
        if abs(scrollVelocityX) > Self.minimumVelocity || abs(scrollVelocityY) > Self.minimumVelocity {
            startMomentumScrolling()
        }
    }
}

// MARK: - Trackpad Tab Swipe (Shared)
// Horizontal trackpad swipe gesture for tab switching via SwipeGestureManager.
// Used on both Mac Catalyst and iOS/iPadOS — each platform's setup calls
// setupTrackpadTabSwipe() so the gesture coexists with its scroll handler.

extension Ghostty.TerminalView {
    private enum TrackpadScrollAxis {
        case horizontal
        case vertical
    }

    // MARK: - Associated Object Keys for Trackpad Tab Swipe

    private static var trackpadTabSwipeGestureKey: UInt8 = 0
    private static var trackpadTabSwipeCumulativeXKey: UInt8 = 0
    private static var trackpadTabSwipeTriggeredKey: UInt8 = 0
    private static var trackpadAppTabSwipeDirectionKey: UInt8 = 0
    private static var trackpadScrollAxisKey: UInt8 = 0
    private static var trackpadScrollAxisResetTimerKey: UInt8 = 0
    private static var trackpadTabSwipePhaseKey: UInt8 = 0
    private static var trackpadSwipeBindingObserverKey: UInt8 = 0

    /// Multiplier applied to capture-mode trackpad translation before tab-swipe
    /// accumulation, compensating for the [.discrete,.continuous] attenuation so the
    /// 200pt threshold matches the non-capture [.continuous]-only recognizer's feel.
    static let captureTabSwipeGain: CGFloat = 2.0

    private var trackpadTabSwipeGesture: UIPanGestureRecognizer? {
        get { objc_getAssociatedObject(self, &Self.trackpadTabSwipeGestureKey) as? UIPanGestureRecognizer }
        set { objc_setAssociatedObject(self, &Self.trackpadTabSwipeGestureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var tabSwipeCumulativeX: CGFloat {
        get { (objc_getAssociatedObject(self, &Self.trackpadTabSwipeCumulativeXKey) as? CGFloat) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.trackpadTabSwipeCumulativeXKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var tabSwipeTriggered: Bool {
        get { (objc_getAssociatedObject(self, &Self.trackpadTabSwipeTriggeredKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.trackpadTabSwipeTriggeredKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var trackpadAppTabSwipeDirection: SwipeDirection? {
        get { objc_getAssociatedObject(self, &Self.trackpadAppTabSwipeDirectionKey) as? SwipeDirection }
        set { objc_setAssociatedObject(self, &Self.trackpadAppTabSwipeDirectionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var trackpadScrollAxis: TrackpadScrollAxis? {
        get { objc_getAssociatedObject(self, &Self.trackpadScrollAxisKey) as? TrackpadScrollAxis }
        set { objc_setAssociatedObject(self, &Self.trackpadScrollAxisKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var trackpadScrollAxisResetTimer: Timer? {
        get { objc_getAssociatedObject(self, &Self.trackpadScrollAxisResetTimerKey) as? Timer }
        set { objc_setAssociatedObject(self, &Self.trackpadScrollAxisResetTimerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Synthesized phase for the trackpad app-tab swipe: inactivity end timer,
    /// inertia guard, and EMA release velocity (raw pre-gain units, so the ±900
    /// commit threshold reads the same in capture and non-capture modes).
    private var trackpadTabSwipePhase: TrackpadScrollPhaseTracker {
        if let tracker = objc_getAssociatedObject(self, &Self.trackpadTabSwipePhaseKey) as? TrackpadScrollPhaseTracker {
            return tracker
        }
        let tracker = TrackpadScrollPhaseTracker { [weak self] in
            self?.completeTrackpadTabSwipe()
        }
        objc_setAssociatedObject(self, &Self.trackpadTabSwipePhaseKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return tracker
    }

    private var trackpadSwipeBindingObserver: NSObjectProtocol? {
        get { objc_getAssociatedObject(self, &Self.trackpadSwipeBindingObserverKey) as? NSObjectProtocol }
        set { objc_setAssociatedObject(self, &Self.trackpadSwipeBindingObserverKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// True when the user has disabled both left and right swipe bindings.
    private var trackpadSwipeBindingsAllDisabled: Bool {
        SwipeGestureManager.shared.binding(for: .left).isDisabled
            && SwipeGestureManager.shared.binding(for: .right).isDisabled
    }

    // MARK: - Setup & Teardown

    /// Resolve the current enabled state for the trackpad tab swipe gesture.
    /// On iOS the dedicated gesture is disabled in capture mode because the
    /// capture-mode scroll handler drives tab swipe detection instead (avoids
    /// dual-recognizer interference). On Mac Catalyst there is no such issue.
    private var trackpadTabSwipeEnabled: Bool {
        #if targetEnvironment(macCatalyst)
        return !trackpadSwipeBindingsAllDisabled
        #else
        return isTouchScrollMode && !isMouseCaptured && !usesHerdrFallbackScrolling && !trackpadSwipeBindingsAllDisabled
        #endif
    }

    /// Install the trackpad horizontal-swipe gesture and its binding observer.
    /// Called from both setupCatalystScrollHandling() and setupIOSScrollHandling().
    func setupTrackpadTabSwipe() {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadTabSwipeGesture))
        gesture.allowedScrollTypesMask = [.continuous]
        gesture.maximumNumberOfTouches = 0  // Scroll events only, no finger touches
        gesture.delegate = self
        gesture.isEnabled = trackpadTabSwipeEnabled
        #if targetEnvironment(macCatalyst)
        // terminalView is a sibling of scrollView post-379e04c7; trackpad scroll
        // events route to scrollView via TerminalScrollView.hitTest. Defer
        // attachment to the host scrollView; TerminalScrollView calls
        // attachTrackpadTabSwipeGesture(to:) once layering is established.
        trackpadTabSwipeGesture = gesture
        #else
        addGestureRecognizer(gesture)
        trackpadTabSwipeGesture = gesture
        #endif

        trackpadSwipeBindingObserver = NotificationCenter.default.addObserver(
            forName: SwipeGestureManager.bindingsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackpadTabSwipeGesture?.isEnabled = self.trackpadTabSwipeEnabled
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Attach the deferred Catalyst trackpad tab-swipe gesture to a host view
    /// that is an ancestor of both `scrollView` and `terminalView`. UIKit
    /// dispatches gesture recognition through the touched view AND all
    /// ancestors, so attaching to the shared parent covers both
    /// non-capture (events route to scrollView) and capture
    /// (events route to terminalView) modes. Idempotent.
    func attachTrackpadTabSwipeGesture(to host: UIView) {
        guard let gesture = trackpadTabSwipeGesture,
              gesture.view !== host else { return }
        gesture.view?.removeGestureRecognizer(gesture)
        host.addGestureRecognizer(gesture)
    }
    #endif

    /// Re-evaluate the trackpad tab swipe enabled state after a Scroll Mode
    /// or capture-mode change. Called from applyTouchMode() on iOS.
    func applyTrackpadTabSwipeMode() {
        trackpadTabSwipeGesture?.isEnabled = trackpadTabSwipeEnabled
    }

    func isTrackpadTabSwipeGesture(_ gesture: UIGestureRecognizer) -> Bool {
        gesture === trackpadTabSwipeGesture
    }

    func shouldBeginTrackpadTabSwipeGesture(_ gesture: UIGestureRecognizer) -> Bool? {
        guard gesture === trackpadTabSwipeGesture,
              let panGesture = gesture as? UIPanGestureRecognizer else { return nil }

        let velocity = panGesture.velocity(in: self)
        let translation = panGesture.translation(in: self)
        let horizontalIntent = abs(velocity.x) > abs(velocity.y)
            || abs(translation.x) > abs(translation.y)
        guard horizontalIntent else { return false }

        let x = abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x
        guard x != 0 else { return false }

        let direction: SwipeDirection = x < 0 ? .left : .right
        let binding = SwipeGestureManager.shared.binding(for: direction)
        guard !binding.isDisabled else { return false }

        tabSwipeCumulativeX = 0
        trackpadTabSwipePhase.reset()
        trackpadScrollAxis = .horizontal

        if binding.isAppTabNavigation {
            guard requestAppTabSwipeBegin(direction: direction, velocityX: velocity.x) else {
                tabSwipeTriggered = false
                trackpadAppTabSwipeDirection = nil
                return false
            }
            tabSwipeTriggered = true
            trackpadAppTabSwipeDirection = direction
            // Arm the inactivity timer at begin, not only from
            // `processTrackpadTabSwipe`. `gestureRecognizerShouldBegin` runs
            // OUTSIDE the gesture's began/changed/ended lifecycle: on Mac
            // Catalyst in mouse-capture mode the scroll-wheel gesture is mutually
            // exclusive with this one (`shouldRecognizeSimultaneouslyWith`
            // returns false) and can win arbitration, FAILING this recognizer
            // before it delivers any movement. Then `processTrackpadTabSwipe` —
            // which normally arms the reset timer — never runs, and the
            // `appTabSwipeState` just posted by `requestAppTabSwipeBegin` would
            // never be cleared, permanently wedging ALL tab switching (every
            // non-source/target tab renders at opacity 0). Arming here guarantees
            // `completeTrackpadTabSwipe()` runs even when no movement follows.
            trackpadTabSwipePhase.arm()
        }

        return true
    }

    /// Remove the binding observer and invalidate the inactivity timer.
    /// Called from both tearDownCatalystScrollHandling() and tearDownIOSScrollHandling().
    func tearDownTrackpadTabSwipe() {
        // A latched swipe must deliver its Ended before the end-timer dies —
        // otherwise MainView's `appTabSwipeState` is left set with nothing to
        // clear it, and every non-source/target tab renders at opacity 0.
        if let direction = trackpadAppTabSwipeDirection {
            postAppTabSwipeNotification(
                .appTabSwipeEnded,
                direction: direction,
                translationX: 0,
                velocityX: 0
            )
        }
        #if targetEnvironment(macCatalyst)
        if let gesture = trackpadTabSwipeGesture {
            gesture.view?.removeGestureRecognizer(gesture)
        }
        trackpadTabSwipeGesture = nil
        #endif
        if let obs = trackpadSwipeBindingObserver {
            NotificationCenter.default.removeObserver(obs)
            trackpadSwipeBindingObserver = nil
        }
        trackpadTabSwipePhase.reset()
        trackpadAppTabSwipeDirection = nil
        trackpadScrollAxisResetTimer?.invalidate()
        trackpadScrollAxisResetTimer = nil
        trackpadScrollAxis = nil
    }

    // MARK: - Tab Swipe Accumulation

    // requestAppTabSwipeBegin / postAppTabSwipeNotification live on
    // SplitPaneView (shared with non-terminal panes).

    /// Accumulate horizontal translation and fire the swipe binding once the
    /// threshold is crossed. Called from the dedicated gesture handler (non-capture)
    /// and from the iOS trackpad scroll handler (capture mode).
    /// - Parameters:
    ///   - translationX: per-event horizontal delta used for accumulation (may be
    ///     gain-scaled in capture mode to match the non-capture 200pt threshold feel).
    ///   - rawDeltaX: the un-gained delta used for velocity estimation so the
    ///     ±900 commit threshold reads in consistent units across modes; defaults
    ///     to `translationX` for callers where no gain is applied.
    @discardableResult
    func processTrackpadTabSwipe(translationX: CGFloat, rawDeltaX: CGFloat? = nil) -> Bool {
        guard !trackpadSwipeBindingsAllDisabled else { return false }

        // Drop trailing inertial events for a swipe that just ended. Trackpad
        // momentum keeps delivering `.continuous` events after the user lifts;
        // without this latch they re-arm the timer and drift the peek.
        guard !trackpadTabSwipePhase.isInInertiaGuard else { return false }

        // Re-arms the inactivity timer and updates the release velocity.
        trackpadTabSwipePhase.noteEvent(delta: rawDeltaX ?? translationX)
        tabSwipeCumulativeX += translationX
        guard abs(tabSwipeCumulativeX) > 3 else { return trackpadAppTabSwipeDirection != nil }

        let direction: SwipeDirection = tabSwipeCumulativeX < 0 ? .left : .right

        if let activeDirection = trackpadAppTabSwipeDirection {
            postAppTabSwipeNotification(
                .appTabSwipeChanged,
                direction: activeDirection,
                translationX: normalizedTrackpadAppTabSwipeTranslation(tabSwipeCumulativeX, direction: activeDirection),
                velocityX: 0
            )
            return true
        }

        if SwipeGestureManager.shared.binding(for: direction).isAppTabNavigation {
            guard requestAppTabSwipeBegin(direction: direction, velocityX: 0) else {
                return false
            }
            trackpadAppTabSwipeDirection = direction
            tabSwipeTriggered = true
            postAppTabSwipeNotification(
                .appTabSwipeChanged,
                direction: direction,
                translationX: normalizedTrackpadAppTabSwipeTranslation(tabSwipeCumulativeX, direction: direction),
                velocityX: 0
            )
            return true
        }

        // Fire once when cumulative horizontal distance exceeds threshold
        let threshold: CGFloat = 200
        if !tabSwipeTriggered && abs(tabSwipeCumulativeX) > threshold {
            tabSwipeTriggered = true
            // Negative X (fingers moving left) is a left swipe, matching the iPad
            // UISwipeGestureRecognizer.left semantics that fire the .left binding.
            let direction: SwipeDirection = tabSwipeCumulativeX < 0 ? .left : .right
            performSwipeBinding(direction)
        }
        return false
    }

    /// End the trackpad swipe now (fast path on a real `.ended`, or a swipe that
    /// curved into a vertical scroll). The inactivity timer is the backstop that
    /// guarantees an end even when the recognizer fails before any movement.
    private func finishTrackpadTabSwipe(zeroVelocity: Bool = false) {
        trackpadTabSwipePhase.finish(zeroVelocity: zeroVelocity)
    }

    /// `onEnd` of `trackpadTabSwipePhase`: deliver the Ended and reset swipe state.
    private func completeTrackpadTabSwipe() {
        if let direction = trackpadAppTabSwipeDirection {
            postAppTabSwipeNotification(
                .appTabSwipeEnded,
                direction: direction,
                translationX: normalizedTrackpadAppTabSwipeTranslation(tabSwipeCumulativeX, direction: direction),
                velocityX: trackpadTabSwipePhase.velocity
            )
        }
        tabSwipeCumulativeX = 0
        tabSwipeTriggered = false
        trackpadAppTabSwipeDirection = nil
        trackpadScrollAxisResetTimer?.invalidate()
        trackpadScrollAxisResetTimer = nil
        trackpadScrollAxis = nil
    }

    @discardableResult
    private func releaseTrackpadAppTabSwipeIfVerticalScroll(_ translation: CGPoint) -> Bool {
        guard trackpadAppTabSwipeDirection != nil else { return false }

        let absX = abs(translation.x)
        let absY = abs(translation.y)
        guard absY > 6, absY > absX * 1.25 else { return false }

        // A swipe that curved into a vertical scroll should snap back, not
        // flick-commit on stale horizontal velocity.
        finishTrackpadTabSwipe(zeroVelocity: true)
        return true
    }

    private func lockedTrackpadScrollAxis(for translation: CGPoint) -> TrackpadScrollAxis? {
        if trackpadAppTabSwipeDirection != nil {
            trackpadScrollAxis = .horizontal
            return .horizontal
        }

        if let axis = trackpadScrollAxis {
            return axis
        }

        let absX = abs(translation.x)
        let absY = abs(translation.y)
        guard max(absX, absY) > 3 else { return nil }

        let axis: TrackpadScrollAxis = absX > absY ? .horizontal : .vertical
        trackpadScrollAxis = axis
        return axis
    }

    private func scheduleTrackpadScrollAxisReset() {
        trackpadScrollAxisResetTimer?.invalidate()
        trackpadScrollAxisResetTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackpadScrollAxis = nil
                self?.trackpadScrollAxisResetTimer = nil
            }
        }
    }

    private func normalizedTrackpadAppTabSwipeTranslation(_ translationX: CGFloat, direction: SwipeDirection) -> CGFloat {
        let width = max(bounds.width, 1)
        switch direction {
        case .left:
            return min(0, max(-width, translationX))
        case .right:
            return max(0, min(width, translationX))
        }
    }

    // MARK: - Gesture Handler

    /// Dedicated gesture handler for trackpad horizontal swipe.
    /// On iOS this is disabled in capture mode — the scroll handler drives
    /// tab swipe detection instead to avoid dual-recognizer interference.
    @objc private func handleTrackpadTabSwipeGesture(_ gesture: UIPanGestureRecognizer) {
        // Fast path: when Catalyst does deliver a real end state, finish the
        // swipe immediately instead of waiting out the inactivity timer. Scroll
        // pans don't reliably deliver this, so the timer remains the backstop.
        switch gesture.state {
        case .ended, .cancelled, .failed:
            if trackpadAppTabSwipeDirection != nil {
                finishTrackpadTabSwipe()
            }
            return
        default:
            break
        }

        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if releaseTrackpadAppTabSwipeIfVerticalScroll(translation) {
            return
        }
        guard abs(translation.x) > abs(translation.y) else { return }
        processTrackpadTabSwipe(translationX: translation.x)
    }
}

// MARK: - Mac Catalyst Scroll Handling
// In capture mode: UIPanGestureRecognizer handles scroll wheel → sends mouse_scroll to Ghostty
// In non-capture mode: UIScrollView handles scrolling with native momentum → scroll_to_row
//
// Scroll wheel gestures don't have clear began/ended states like touch gestures.
// We use a timeout to detect when scrolling stops and start momentum.

#if targetEnvironment(macCatalyst)

extension Ghostty.TerminalView {

    private static var catalystScrollGestureKey: UInt8 = 0
    private static var catalystCaptureCancellableKey: UInt8 = 0
    private static var scrollEndTimerKey: UInt8 = 0

    var catalystScrollGesture: UIPanGestureRecognizer? {
        get { objc_getAssociatedObject(self, &Self.catalystScrollGestureKey) as? UIPanGestureRecognizer }
        set { objc_setAssociatedObject(self, &Self.catalystScrollGestureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var catalystCaptureCancellable: AnyCancellable? {
        get { objc_getAssociatedObject(self, &Self.catalystCaptureCancellableKey) as? AnyCancellable }
        set { objc_setAssociatedObject(self, &Self.catalystCaptureCancellableKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Timer to detect when scroll wheel events stop arriving
    private var scrollEndTimer: Timer? {
        get { objc_getAssociatedObject(self, &Self.scrollEndTimerKey) as? Timer }
        set { objc_setAssociatedObject(self, &Self.scrollEndTimerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private func setupCatalystScrollHandling() {
        // Scroll-wheel gesture is always enabled; gateRecognizerShouldBegin queries
        // ghostty_surface_mouse_captured() directly so the cached @Published state
        // (which can lag the C side when tmux's mouse-on sequence races with the
        // scrollbar callback that resyncs Swift) doesn't gate forwarding.
        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleCatalystScrollGesture))
        scrollGesture.allowedScrollTypesMask = [.discrete, .continuous]
        scrollGesture.maximumNumberOfTouches = 0  // Only scroll wheel, not finger/mouse touches
        scrollGesture.delegate = self
        addGestureRecognizer(scrollGesture)
        catalystScrollGesture = scrollGesture

        // Trackpad horizontal swipe for tab switching (shared with iOS)
        setupTrackpadTabSwipe()

        // Clean up momentum and the scroll-end timer when capture mode exits so a
        // pending tick doesn't replay stale velocity into the non-capture path.
        catalystCaptureCancellable = $isMouseCaptured
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCaptured in
                if !isCaptured {
                    self?.scrollEndTimer?.invalidate()
                    self?.scrollEndTimer = nil
                    self?.cancelMomentumScrolling()
                    self?.stopCaptureAutoScroll()
                }
            }
    }

    /// Tear down NotificationCenter observers and timers owned by the Catalyst
    /// scroll handling. Called from `cleanup()` so closed tabs don't leak the
    /// block-based swipe-binding observer (NotificationCenter strongly retains
    /// block observers and won't release them on view dealloc).
    func tearDownCatalystScrollHandling() {
        tearDownTrackpadTabSwipe()
        // catalystCaptureCancellable is a Combine cancellable and self-tears
        // down when its reference is cleared, but do it explicitly here so the
        // sink stops firing as soon as the view is on its way out.
        catalystCaptureCancellable = nil
        scrollEndTimer?.invalidate()
        scrollEndTimer = nil
        stopCaptureAutoScroll()
    }

    @objc private func handleCatalystScrollGesture(_ gesture: UIPanGestureRecognizer) {
        // Ignore pointer-routed scroll deltas while the window is being
        // dragged (see WindowDragObserver).
        if WindowDragObserver.shared.isWindowMoving {
            gesture.setTranslation(.zero, in: self)
            return
        }

        // Cancel any pending momentum start - we're still receiving events
        scrollEndTimer?.invalidate()

        // Stop any running momentum animation but preserve velocity for tracking
        interruptMomentumAnimation()

        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        // Track velocity for momentum
        _ = trackScrollVelocity(translation: translation, gesture: gesture)

        // Send scroll event with 2x multiplier
        sendNativeScrollEvent(deltaX: translation.x * 2, deltaY: translation.y * 2)

        // Schedule momentum start after scroll events stop
        // 50ms timeout - long enough to batch scroll events, short enough to feel responsive
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMomentumFromTrackedVelocity() }
        }
    }
}
#endif

// MARK: - iOS/visionOS Scroll Handling
// In capture mode:
//   - Trackpad scroll gesture → sends mouse_scroll to Ghostty with momentum (timer-based)
//   - Two-finger touch gesture → sends mouse_scroll to Ghostty with momentum (gesture-based)
//   - Single-finger touches → sent to terminal for tmux dividers/selection
// In non-capture mode:
//   - UIScrollView handles all scrolling with native momentum

#if !targetEnvironment(macCatalyst)

extension Ghostty.TerminalView {

    // MARK: - Associated Objects for Scroll State

    private static var trackpadScrollGestureKey: UInt8 = 0
    private static var twoFingerScrollGestureKey: UInt8 = 0
    private static var captureScrollPanGestureKey: UInt8 = 0
    private static var fingerDragActiveKey: UInt8 = 0
    private static var iosCaptureCancellableKey: UInt8 = 0
    private static var iosScrollEndTimerKey: UInt8 = 0

    private var trackpadScrollGesture: UIPanGestureRecognizer? {
        get { objc_getAssociatedObject(self, &Self.trackpadScrollGestureKey) as? UIPanGestureRecognizer }
        set { objc_setAssociatedObject(self, &Self.trackpadScrollGestureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var twoFingerScrollGesture: UIPanGestureRecognizer? {
        get { objc_getAssociatedObject(self, &Self.twoFingerScrollGestureKey) as? UIPanGestureRecognizer }
        set { objc_setAssociatedObject(self, &Self.twoFingerScrollGestureKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var iosCaptureCancellable: AnyCancellable? {
        get { objc_getAssociatedObject(self, &Self.iosCaptureCancellableKey) as? AnyCancellable }
        set { objc_setAssociatedObject(self, &Self.iosCaptureCancellableKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Timer to detect when trackpad scroll events stop arriving
    private var iosScrollEndTimer: Timer? {
        get { objc_getAssociatedObject(self, &Self.iosScrollEndTimerKey) as? Timer }
        set { objc_setAssociatedObject(self, &Self.iosScrollEndTimerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Tracks when a finger touch is being treated as a mouse drag in capture mode
    var fingerDragActive: Bool {
        get { (objc_getAssociatedObject(self, &Self.fingerDragActiveKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.fingerDragActiveKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // scrollPanGesture is no longer used - UIScrollView handles finger scrolling
    // Keep property for compatibility with gesture delegate checks
    var scrollPanGesture: UIPanGestureRecognizer? { nil }

    private func setupIOSScrollHandling() {
        // Gesture for Magic Keyboard trackpad scrolling in capture mode only
        // In non-capture mode, UIScrollView handles trackpad scroll with native momentum
        // (configured via panGestureRecognizer.allowedScrollTypesMask in TerminalScrollView)
        let trackpadGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll))
        trackpadGesture.allowedScrollTypesMask = [.discrete, .continuous]
        trackpadGesture.maximumNumberOfTouches = 0  // Only scroll wheel, not finger touches
        trackpadGesture.isEnabled = false  // Start disabled, enabled when capture mode active
        addGestureRecognizer(trackpadGesture)
        trackpadScrollGesture = trackpadGesture

        // Two-finger scroll gesture for touch scrolling in capture mode
        // Single-finger touches go to terminal for tmux dividers/selection
        let twoFingerGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll))
        twoFingerGesture.minimumNumberOfTouches = 2
        twoFingerGesture.maximumNumberOfTouches = 2
        twoFingerGesture.isEnabled = false  // Start disabled, enabled in capture mode only
        addGestureRecognizer(twoFingerGesture)
        twoFingerScrollGesture = twoFingerGesture

        // Trackpad horizontal swipe for tab switching (shared with Mac Catalyst)
        setupTrackpadTabSwipe()

        // Observe capture mode changes to enable/disable gestures
        iosCaptureCancellable = $isMouseCaptured.combineLatest($usesHerdrFallbackScrolling)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCaptured, fallbackScrolling in
                guard let self else { return }
                let scrollMode = self.isTouchScrollMode
                let forwardsScroll = isCaptured || fallbackScrolling

                // Server scrollback uses these gestures even at a shell prompt.
                self.trackpadScrollGesture?.isEnabled = forwardsScroll
                self.twoFingerScrollGesture?.isEnabled = forwardsScroll

                self.captureScrollPanGesture?.isEnabled = forwardsScroll && scrollMode
                self.captureLongPressGesture?.isEnabled = isCaptured && scrollMode

                // Update selection long press - disable during capture even in scroll mode
                self.selectionLongPressGesture?.isEnabled = scrollMode && !isCaptured

                // Disable the dedicated tab swipe gesture in capture mode —
                // handleTrackpadScroll drives tab swipe detection instead.
                self.applyTrackpadTabSwipeMode()

                // Cancel momentum and timer when leaving capture mode
                if !isCaptured {
                    self.iosScrollEndTimer?.invalidate()
                    self.iosScrollEndTimer = nil
                    self.cancelMomentumScrolling()
                    self.stopCaptureAutoScroll()
                }
            }
    }

    /// Handle Magic Keyboard trackpad scroll in capture mode
    /// Uses timer-based momentum since scroll wheel doesn't have clear began/ended states.
    /// Also drives tab swipe detection — the dedicated trackpadTabSwipeGesture is
    /// disabled in capture mode to avoid dual-recognizer interference.
    @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
        // Cancel any pending momentum start - we're still receiving events
        iosScrollEndTimer?.invalidate()
        iosScrollEndTimer = nil

        // Stop any running momentum animation but preserve velocity for tracking
        interruptMomentumAnimation()

        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if releaseTrackpadAppTabSwipeIfVerticalScroll(translation) {
            trackpadScrollAxis = .vertical
        }
        let axis = lockedTrackpadScrollAxis(for: translation)
        scheduleTrackpadScrollAxisReset()
        let lockedTranslation: CGPoint = switch axis {
        case .horizontal:
            CGPoint(x: translation.x, y: 0)
        case .vertical:
            CGPoint(x: 0, y: translation.y)
        case nil:
            translation
        }

        // Drive tab swipe detection from this handler in capture mode
        // (the dedicated tab swipe gesture is disabled to avoid interference).
        // The capture scroll gesture uses [.discrete,.continuous]; its translation
        // deltas are attenuated vs the dedicated [.continuous]-only tab-swipe gesture
        // the 200pt threshold was tuned against, so scale the tab-swipe contribution
        // to match non-capture travel. Axis-lock the event stream so vertical
        // scroll in tmux/vim neither accumulates toward nor wiggles an app-tab switch.
        let horizontalLocked = axis == .horizontal
        let appTabSwipeAlreadyActive = trackpadAppTabSwipeDirection != nil
        let handlesAppTabSwipe: Bool
        if appTabSwipeAlreadyActive || horizontalLocked {
            handlesAppTabSwipe = processTrackpadTabSwipe(
                translationX: lockedTranslation.x * Self.captureTabSwipeGain,
                rawDeltaX: lockedTranslation.x
            )
        } else {
            handlesAppTabSwipe = false
        }

        // Send scroll event with 2x multiplier unless this horizontal trackpad
        // movement is driving the app-tab carousel. Vertical captured scrolling
        // and non-app swipe bindings keep the existing terminal-forwarding path.
        if handlesAppTabSwipe {
            clearTrackedScrollVelocity()
            return
        }

        // Track velocity for momentum only when the gesture is still terminal scroll.
        _ = trackScrollVelocity(translation: lockedTranslation, gesture: gesture)

        sendNativeScrollEvent(deltaX: lockedTranslation.x * 2, deltaY: lockedTranslation.y * 2)

        // Schedule momentum start after scroll events stop
        // 50ms timeout - long enough to batch scroll events, short enough to feel responsive
        iosScrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMomentumFromTrackedVelocity() }
        }
    }

    /// Handle two-finger touch scroll in capture mode
    /// Uses gesture-based momentum since touch gestures have proper began/ended states
    /// Allows single-finger touches to reach terminal for tmux dividers/selection
    @objc private func handleTwoFingerScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Just interrupt animation, don't reset velocity
            // This allows momentum to continue if user quickly swipes again
            interruptMomentumAnimation()

            // Update mouse position so scroll events target correct tmux split
            let location = gesture.location(in: self)
            lastMousePosition = location

        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)

            // Track velocity for momentum (blends with existing velocity)
            _ = trackScrollVelocity(translation: translation, gesture: gesture)

            // Send scroll event with 2x multiplier
            sendNativeScrollEvent(deltaX: translation.x * 2, deltaY: translation.y * 2)

        case .ended:
            finalizeVelocityAndStartMomentum(gesture: gesture)

        case .cancelled, .failed:
            stopMomentumScrolling()

        default:
            break
        }
    }

    /// Handle single-finger scroll in capture mode when scroll mode is enabled
    /// Same momentum physics as handleTwoFingerScroll but triggered by single-finger pan
    @objc func handleCaptureScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            interruptMomentumAnimation()

            let location = gesture.location(in: self)
            lastMousePosition = location

        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)

            _ = trackScrollVelocity(translation: translation, gesture: gesture)

            sendNativeScrollEvent(deltaX: translation.x * 2, deltaY: translation.y * 2)

        case .ended:
            finalizeVelocityAndStartMomentum(gesture: gesture)

        case .cancelled, .failed:
            stopMomentumScrolling()

        default:
            break
        }
    }

    /// Tear down NotificationCenter observers and timers owned by the iOS
    /// scroll handling. Called from `cleanup()` so closed tabs don't leak.
    func tearDownIOSScrollHandling() {
        tearDownTrackpadTabSwipe()
        iosCaptureCancellable = nil
        iosScrollEndTimer?.invalidate()
        iosScrollEndTimer = nil
        stopCaptureAutoScroll()
    }
}
#endif
