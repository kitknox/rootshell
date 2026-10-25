//
//  InteractiveEdgePanRecognizer.swift
//  rootshell
//
//  A window-level pan that drives an interactive reveal from a screen edge or
//  chrome band (sidebar drawer, tab exposé). Installed on the UIWindow because
//  the overlays it reveals are non-interactive while closed and cannot catch the
//  touch themselves. The caller supplies the activation test; this class owns
//  the recognizer lifecycle, start-point gating, arbitration answers, and the
//  trackpad variant (continuous scroll pans with a synthesized end).
//

import UIKit
import os

@MainActor
final class InteractiveEdgePanRecognizer: NSObject, UIGestureRecognizerDelegate {
    enum Axis {
        case horizontal
        case vertical
    }

    struct Configuration {
        var axis: Axis
        /// One touch recognizer per finger count (e.g. `[1, 2]`); callbacks
        /// receive the count so bands can differ per finger count.
        var touchCounts: [Int] = [1]
        var idioms: Set<UIUserInterfaceIdiom>
        /// Also install a scroll-type pan (`allowedScrollTypesMask = [.continuous]`).
        var includesTrackpadScroll: Bool = false
        /// Multiplier on trackpad translation; scroll distances are short.
        var trackpadGain: CGFloat = 1
        /// Sibling recognizers that must wait for this pan to fail when the pan
        /// started inside the activation band (e.g. swipes, scroll-view pans).
        var beatsSiblingRecognizers: (UIGestureRecognizer) -> Bool = { $0 is UISwipeGestureRecognizer }
    }

    struct Callbacks {
        /// Whether a touch-down at `start` (window coords) is inside the
        /// activation band. `touches` is the finger count; 0 = trackpad.
        var isInActivationBand: (_ start: CGPoint, _ window: UIWindow, _ touches: Int) -> Bool
        /// Final gate once direction is known. `translation` is in window coords.
        var shouldBegin: (_ start: CGPoint, _ translation: CGPoint, _ window: UIWindow, _ touches: Int) -> Bool
        /// Distance along the axis that maps to progress 1.
        var length: () -> CGFloat
        var onBegin: (UIWindow) -> Void
        /// Signed progress along the axis (positive = right / down).
        var onChange: (_ progress: CGFloat) -> Void
        /// Release: signed progress and velocity along the axis (pt/s).
        var onEnd: (_ progress: CGFloat, _ velocity: CGFloat) -> Void
        var onCancel: () -> Void
    }

    let configuration: Configuration
    var callbacks: Callbacks

    private(set) weak var installedWindow: UIWindow?
    private var touchPans: [UIPanGestureRecognizer] = []
    private var trackpadPan: UIPanGestureRecognizer?
    private var active = false
    private var activeIsTrackpad = false
    /// The recognizer currently driving; others are ignored until it ends.
    private weak var activePan: UIPanGestureRecognizer?
    private var lastTrackpadTranslation: CGPoint = .zero
    private lazy var trackpadPhase = TrackpadScrollPhaseTracker { [weak self] in
        self?.trackpadDidEnd()
    }

    init(configuration: Configuration, callbacks: Callbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
    }

    // MARK: - Install

    func install(on window: UIWindow?) {
        guard configuration.idioms.contains(UIDevice.current.userInterfaceIdiom) else {
            uninstall()
            return
        }
        guard window !== installedWindow else { return }
        uninstall()
        guard let window else { return }

        for count in configuration.touchCounts {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouchPan(_:)))
            pan.minimumNumberOfTouches = count
            pan.maximumNumberOfTouches = count
            // Finger-only: a window pan must not steal indirect-pointer drags.
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.delegate = self
            window.addGestureRecognizer(pan)
            touchPans.append(pan)
        }

        if configuration.includesTrackpadScroll {
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadPan(_:)))
            scroll.allowedScrollTypesMask = [.continuous]
            scroll.maximumNumberOfTouches = 0
            scroll.delegate = self
            window.addGestureRecognizer(scroll)
            trackpadPan = scroll
        }
        installedWindow = window
    }

    func uninstall() {
        if let installedWindow {
            for pan in touchPans { installedWindow.removeGestureRecognizer(pan) }
            if let trackpadPan { installedWindow.removeGestureRecognizer(trackpadPan) }
        }
        touchPans.removeAll()
        trackpadPan = nil
        installedWindow = nil
        trackpadPhase.reset()
        active = false
        activePan = nil
    }

    /// True for this instance's own recognizers (so two instances on one
    /// window don't require each other to fail).
    /// Abort an in-flight pan so another gesture (a pinch) can take over;
    /// the cancel callback fires through the recognizer's normal path.
    func cancelActive() {
        guard active, let pan = activePan else { return }
        if activeIsTrackpad {
            // The scroll pan's cancel path finishes (commits) the phase; drop
            // the tracker and cancel directly, leaving the recognizer session
            // alive so a later scroll can restart the pan.
            active = false
            activePan = nil
            trackpadPhase.reset()
            if let window = pan.view { pan.setTranslation(.zero, in: window) }
            callbacks.onCancel()
        } else {
            pan.isEnabled = false
            pan.isEnabled = true
        }
    }

    func owns(_ recognizer: UIGestureRecognizer) -> Bool {
        touchPans.contains { $0 === recognizer } || trackpadPan === recognizer
    }

    /// Uses the installed edge owner's gates, including a reveal that already
    /// began before the competing terminal recognizer asks to start.
    static func claimsHorizontalSwipe(in window: UIWindow, startingAt start: CGPoint, translation: CGPoint) -> Bool {
        for pan in window.gestureRecognizers ?? [] {
            guard let owner = pan.delegate as? InteractiveEdgePanRecognizer,
                  owner.configuration.axis == .horizontal,
                  owner.touchPans.contains(where: { $0 === pan }),
                  pan.isEnabled, pan.state != .failed, pan.state != .cancelled,
                  owner.callbacks.isInActivationBand(start, window, 1) else { continue }
            if (owner.active && !owner.activeIsTrackpad && owner.activePan === pan)
                || owner.callbacks.shouldBegin(start, translation, window, 1) {
                Ghostty.logger.debug("Edge swipe owns input window=\(String(describing: ObjectIdentifier(window)), privacy: .public) x=\(start.x) dx=\(translation.x)")
                return true
            }
        }
        return false
    }

    /// Finger count a recognizer stands for; 0 for the trackpad pan.
    private func touchCount(of pan: UIPanGestureRecognizer) -> Int {
        pan === trackpadPan ? 0 : pan.minimumNumberOfTouches
    }

    // MARK: - Geometry

    private func along(_ point: CGPoint) -> CGFloat {
        configuration.axis == .horizontal ? point.x : point.y
    }

    private func across(_ point: CGPoint) -> CGFloat {
        configuration.axis == .horizontal ? point.y : point.x
    }

    private func startPoint(of pan: UIPanGestureRecognizer, in view: UIView) -> CGPoint {
        // `location` is the current finger; subtract translation for the touch-down.
        let location = pan.location(in: view)
        let translation = pan.translation(in: view)
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    private func progress(for translation: CGPoint, gain: CGFloat) -> CGFloat {
        along(translation) * gain / max(callbacks.length(), 1)
    }

    // MARK: - Touch pan

    @objc private func handleTouchPan(_ pan: UIPanGestureRecognizer) {
        guard let window = pan.view as? UIWindow else { return }
        switch pan.state {
        case .began:
            guard !active else { return }
            active = true
            activeIsTrackpad = false
            activePan = pan
            callbacks.onBegin(window)
        case .changed:
            guard active, activePan === pan else { return }
            callbacks.onChange(progress(for: pan.translation(in: window), gain: 1))
        case .ended:
            guard active, activePan === pan else { return }
            active = false
            activePan = nil
            callbacks.onEnd(progress(for: pan.translation(in: window), gain: 1),
                            along(pan.velocity(in: window)))
        case .cancelled, .failed:
            guard active, activePan === pan else { return }
            active = false
            activePan = nil
            callbacks.onCancel()
        default:
            break
        }
    }

    // MARK: - Trackpad pan

    @objc private func handleTrackpadPan(_ pan: UIPanGestureRecognizer) {
        guard let window = pan.view as? UIWindow else { return }
        switch pan.state {
        case .began:
            guard !active, !trackpadPhase.isInInertiaGuard else { return }
            active = true
            activeIsTrackpad = true
            activePan = pan
            lastTrackpadTranslation = .zero
            trackpadPhase.arm()
            callbacks.onBegin(window)
        case .changed:
            guard !active || activeIsTrackpad else { return }
            if !active {
                // Scroll pans seldom end between gestures: after a synthesized
                // end, fresh movement (past the inertia guard) restarts the pan.
                guard !trackpadPhase.isInInertiaGuard else {
                    pan.setTranslation(.zero, in: window)
                    return
                }
                let translation = pan.translation(in: window)
                let start = startPoint(of: pan, in: window)
                guard callbacks.isInActivationBand(start, window, 0),
                      callbacks.shouldBegin(start, translation, window, 0) else { return }
                pan.setTranslation(.zero, in: window)
                active = true
                activeIsTrackpad = true
                activePan = pan
                lastTrackpadTranslation = .zero
                trackpadPhase.arm()
                callbacks.onBegin(window)
                return
            }
            guard !trackpadPhase.isInInertiaGuard else { return }
            let translation = pan.translation(in: window)
            let delta = CGPoint(x: translation.x - lastTrackpadTranslation.x,
                                y: translation.y - lastTrackpadTranslation.y)
            lastTrackpadTranslation = translation
            // A pull that curves into the other axis releases with no flick velocity.
            if abs(across(delta)) > 6, abs(across(delta)) > abs(along(delta)) * 1.25 {
                trackpadPhase.finish(zeroVelocity: true)
                return
            }
            trackpadPhase.noteEvent(delta: along(delta))
            callbacks.onChange(progress(for: translation, gain: configuration.trackpadGain))
        case .ended, .cancelled, .failed:
            // Catalyst sometimes delivers a real end; the timer is the backstop.
            guard active, activeIsTrackpad else { return }
            trackpadPhase.finish()
        default:
            break
        }
    }

    private func trackpadDidEnd() {
        guard active, activeIsTrackpad else { return }
        active = false
        activePan = nil
        let gain = configuration.trackpadGain
        // Fresh origin for a possible restart within the same recognizer session.
        if let trackpadPan, let window = trackpadPan.view {
            trackpadPan.setTranslation(.zero, in: window)
        }
        callbacks.onEnd(progress(for: lastTrackpadTranslation, gain: gain),
                        trackpadPhase.velocity * gain)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let window = pan.view as? UIWindow else { return false }
        if pan === trackpadPan, trackpadPhase.isInInertiaGuard { return false }
        var translation = pan.translation(in: window)
        if translation == .zero {
            // Scroll pans can ask before accumulating movement; infer from velocity.
            let velocity = pan.velocity(in: window)
            translation = CGPoint(x: velocity.x / 60, y: velocity.y / 60)
        }
        let start = startPoint(of: pan, in: window)
        let touches = touchCount(of: pan)
        guard callbacks.isInActivationBand(start, window, touches) else { return false }
        return callbacks.shouldBegin(start, translation, window, touches)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard configuration.beatsSiblingRecognizers(otherGestureRecognizer),
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let window = pan.view as? UIWindow else { return false }
        // Only delay siblings for a pan that started inside the band, so a
        // recognizer that will never fire doesn't hold up ordinary scrolling.
        let touches = touchCount(of: pan)
        if touches > 0, pan.numberOfTouches < touches { return false }
        return callbacks.isInActivationBand(startPoint(of: pan, in: window), window, touches)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Permissive: don't let an unrelated recognizer block the edge pan.
        true
    }
}
