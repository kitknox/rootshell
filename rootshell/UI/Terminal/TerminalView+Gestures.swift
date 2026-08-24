//
//  TerminalView+Gestures.swift
//  rootshell
//
//  Gesture handlers, copy/paste, mouse support, and terminal I/O
//  Extracted from TerminalView.swift for build parallelization
//

import UIKit
import SwiftUI
import os
import GhosttyKit
import GameController
#if targetEnvironment(macCatalyst)
import AppKit
#endif

// MARK: - Touch-Only Gesture Delegate

/// Prevents the double-tap gesture from tracking mouse/trackpad touches so they
/// flow exclusively through touchesBegan/touchesEnded for proper click counting.
/// Separate from TerminalView's delegate to preserve all other gesture behaviors.
extension UITouch {
    /// A physical contact on the glass — finger or Apple Pencil (excludes trackpad).
    var isScreenContact: Bool { type == .direct || type == .pencil }
}

#if !targetEnvironment(macCatalyst)
class TouchOnlyGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type != .indirectPointer
    }
}
#endif

// MARK: - Gesture Handlers

extension Ghostty.TerminalView {

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        // Dismiss the brightness HUD if it's visible — a tap anywhere on the
        // terminal outside the HUD pill dismisses it (touches inside the HUD are
        // routed to it by TerminalScrollView.hitTest and never reach handleTap).
        if brightnessHUDHost != nil {
            hideBrightnessHUD()
        }

        #if !targetEnvironment(macCatalyst)
        // Tapping a device terminal while forwarding returns typing focus.
        ExternalDisplayManager.shared.noteDeviceTerminalTapped(windowId: windowId)
        #endif

        // Notify MainView to update focused terminal
        // setFocusedTerminal() will handle UIKit focus via focusDidChange()
        NotificationCenter.default.post(name: .focusSplit, object: self)
        // Note: Do NOT call becomeFirstResponder() directly - let MainView coordinate
        // Only reload input views to ensure keyboard traits are current.
        // Skip for pencil taps: reloading input views during a pencil
        // interaction summons the system's minimized-keyboard pill, and the
        // pencil never types.
        if !lastContextMenuTriggerWasPencil {
            reloadInputViews()
        }

        #if !targetEnvironment(macCatalyst)
        // Clear any existing text selection by sending a click at the tap location.
        // Only for finger taps — mouse/trackpad clicks already send press/release
        // via touchesBegan/touchesEnded. Adding more here for mouse would double-count
        // clicks (handleTap fires ~300ms after single click due to require(toFail:)).
        if let surface = surface, !isMouseCaptured, lastContextMenuTriggerWasFinger {
            selectionWasTouchInitiated = false
            hideSelectionHandles(animated: false)
            let tapLocation = gesture.location(in: self)
            let pixelPoint = viewToPixelCoordinates(tapLocation)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
            sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Mouse/trackpad: don't show context menu — matches macOS Ghostty behavior.
        guard lastContextMenuTriggerWasFinger else { return }
        scheduleDoubleTapContextMenu(at: gesture.location(in: self))
    }

    @objc func handleRightClickPan(_ gesture: UIPanGestureRecognizer) {
        // Only handle if we're tracking a right-click (started via context menu)
        guard Self.rightClickTrackingView != nil else { return }
        guard let surface = surface else { return }

        let point = gesture.location(in: self)

        switch gesture.state {
        case .began, .changed:
            // Send position update
            let pixelPoint = viewToPixelCoordinates(point)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)

        case .ended, .cancelled:
            // Send release
            let pixelPoint = viewToPixelCoordinates(point)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
            mousePressed = false
            stopRightClickMonitoring()

        default:
            break
        }
    }
    #endif

    @objc func handleHoverGesture(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            // Track mouse position for discrete scroll wheel events
            let point = gesture.location(in: self)
#if targetEnvironment(macCatalyst)
            let isInsideView: Bool
            if let window {
                let windowPoint = gesture.location(in: window)
                let hitView = window.hitTest(windowPoint, with: nil)
                isInsideView = hitView === self || (hitView?.isDescendant(of: self) ?? false)
            } else {
                isInsideView = bounds.contains(point)
            }
            if !isInsideView {
                if isMouseInsideView {
                    isMouseInsideView = false
                    if let cursorToken {
                        CatalystCursorCoordinator.shared.unregister(cursorToken)
                    }
                    cursorToken = nil
                }
                return
            }
#endif
            lastMousePosition = point

            // Send hover position to Ghostty so apps like tmux can track cursor position
            // This is critical for tmux divider detection - tmux needs to know the cursor
            // is on a divider BEFORE you click, not just when you click
            // BUT: Skip if mouse button is pressed - touch events handle position during drag
            // to avoid conflicting position updates
            // Pass modifier state so Cmd+hover triggers link detection (pointing hand cursor)
            if let surface = surface, !mousePressed {
                let pixelPoint = viewToPixelCoordinates(point)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, currentMouseMods())
            }

            #if targetEnvironment(macCatalyst)
            // Mouse entered or is moving within the view - manage cursor
            if !isMouseInsideView {
                isMouseInsideView = true
            }
            if cursorToken == nil {
                cursorToken = UUID()
            }
            if let cursorToken {
                CatalystCursorCoordinator.shared.ensure(
                    cursorToken,
                    cursor: currentCursor,
                    priority: .terminal
                )
            }
            #endif

        case .ended, .cancelled:
            #if targetEnvironment(macCatalyst)
            // Mouse exited the view
            if isMouseInsideView {
                isMouseInsideView = false
                if let cursorToken {
                    CatalystCursorCoordinator.shared.unregister(cursorToken)
                }
                cursorToken = nil
            }
            #endif
        default:
            break
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// Handle single-finger pan for text selection on iOS/iPadOS
    /// Uses movement (not long press) to trigger selection, avoiding conflict with context menu
    @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        // Don't handle selection in capture mode - let finger drag handle mouse events
        guard !isMouseCaptured, let surface = surface else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            guard !suppressSelectionUntilTouchEnd else { return }
            selectionStartPoint = location
            isSelectionDelayPending = true

            // 0.15s delay to distinguish tap from selection drag
            selectionDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startSelectionFromPan() }
            }

        case .changed:
            if suppressSelectionUntilTouchEnd {
                cancelSelectionForMultiTouch(at: location)
                return
            }
            if isSelectionDelayPending {
                let startX = selectionStartPoint?.x ?? 0
                let startY = selectionStartPoint?.y ?? 0
                let moved = hypot(location.x - startX, location.y - startY)
                if moved > 5 {
                    // Moved significantly, start selection immediately
                    selectionDelayTimer?.invalidate()
                    startSelectionFromPan()
                }
            }

            if isSelecting {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                noteSelectionScrollIndicatorActivity()
                updateCaptureMagnifier(at: location)
            }

        case .ended, .cancelled, .failed:
            selectionDelayTimer?.invalidate()
            selectionDelayTimer = nil

            if isSelecting {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
                hideSelectionMagnifier()
                isSelecting = false
                selectionStartedFromPan = false
                reloadInputViews()

                // Show edit menu and selection handles if selection was created
                if ghostty_surface_has_selection(surface) {
                    selectionWasTouchInitiated = true
                    presentTransientEditMenu(at: location)
                    syncSelectionHandlesForSurfaceActivity()
                }
            }

            selectionStartPoint = nil
            isSelectionDelayPending = false
            selectionStartedFromPan = false

        default:
            break
        }
    }

    /// Start text selection from the pan gesture's start point
    private func startSelectionFromPan() {
        guard let surface = surface, let startPoint = selectionStartPoint else { return }
        guard !suppressSelectionUntilTouchEnd else {
            isSelectionDelayPending = false
            selectionStartPoint = nil
            return
        }
        isSelectionDelayPending = false
        isSelecting = true
        selectionStartedFromPan = true

        let pixelPoint = viewToPixelCoordinates(startPoint)
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        showCaptureMagnifier(at: startPoint)
        triggerHapticFeedback()

        NotificationCenter.default.post(name: .focusSplit, object: self)
        reloadInputViews()
    }

    private func updateSelectionSuppressionForDirectTouches(_ touches: Set<UITouch>, event: UIEvent?) {
        guard !isMouseCaptured else { return }

        let allTouches = event?.allTouches ?? touches
        let activeDirectTouches = allTouches.filter { touch in
            touch.type == .direct && touch.phase != .ended && touch.phase != .cancelled
        }

        if activeDirectTouches.count > 1 {
            if !suppressSelectionUntilTouchEnd {
                suppressSelectionUntilTouchEnd = true
                cancelSelectionForMultiTouch(at: activeDirectTouches.first?.location(in: self))
                if selectionHandlesVisible { hideSelectionHandles() }
            }
        } else if activeDirectTouches.isEmpty {
            suppressSelectionUntilTouchEnd = false
        }
    }

    private func cancelSelectionForMultiTouch(at point: CGPoint?) {
        guard isSelectionDelayPending || isSelecting else { return }

        selectionDelayTimer?.invalidate()
        selectionDelayTimer = nil
        isSelectionDelayPending = false

        defer {
            selectionStartPoint = nil
            selectionStartedFromPan = false
        }

        guard let surface = surface, isSelecting else {
            isSelecting = false
            return
        }

        let location = point ?? selectionStartPoint ?? .zero
        let pixelPoint = viewToPixelCoordinates(location)
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        hideSelectionMagnifier(animated: false)
        isSelecting = false

        if selectionStartedFromPan {
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
            sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        }
    }

    /// Present a transient edit menu at the given point.
    /// Creates a fresh UIEditMenuInteraction each time to avoid conflicts with UIContextMenuInteraction.
    func presentTransientEditMenu(at point: CGPoint, fullContextMenu: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        // Parked: the menu would render on the unhittable external screen.
        if isExternalDisplayTerminal,
           !ExternalDisplayManager.shared.isControlSurfaceActive { return }
        #endif
        cancelPendingDoubleTapAction()

        // Remove any existing transient edit menu
        if let existing = editMenuInteraction {
            removeInteraction(existing)
            editMenuInteraction = nil
        }
        // Create and add new interaction
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenuInteraction = interaction

        // Track whether to show full or compact menu
        isFullContextMenuPresentation = fullContextMenu

        let sourcePoint = fullContextMenu ? point : preferredSelectionEditMenuPoint(fallback: point)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: sourcePoint)
        interaction.presentEditMenu(with: config)
    }

    func scheduleDoubleTapContextMenu(at point: CGPoint) {
        cancelPendingDoubleTapAction()
        pendingDoubleTapActionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, !Task.isCancelled else { return }
            self.pendingDoubleTapActionTask = nil
            NotificationCenter.default.post(name: .focusSplit, object: self)
            self.reloadInputViews()
            self.presentTransientEditMenu(at: point, fullContextMenu: true)
        }
    }

    func cancelPendingDoubleTapAction() {
        pendingDoubleTapActionTask?.cancel()
        pendingDoubleTapActionTask = nil
    }

    /// Handle long press for text selection in scroll mode
    @objc func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            guard !isMouseCaptured, let surface = surface else { return }

            isSelecting = true
            selectionStartPoint = location

            let pixelPoint = viewToPixelCoordinates(location)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
            showCaptureMagnifier(at: location)

            triggerHapticFeedback()

            NotificationCenter.default.post(name: .focusSplit, object: self)
            reloadInputViews()

        case .changed:
            guard let surface = surface else { return }
            if isSelecting {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                noteSelectionScrollIndicatorActivity()
                updateCaptureMagnifier(at: location)
            }

        case .ended, .cancelled, .failed:
            if isSelecting, let surface = surface {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
                hideSelectionMagnifier()
                reloadInputViews()

                // Show edit menu and selection handles if selection was created
                if ghostty_surface_has_selection(surface) {
                    selectionWasTouchInitiated = true
                    presentTransientEditMenu(at: location)
                    syncSelectionHandlesForSurfaceActivity()
                }
            }

            selectionStartPoint = nil
            isSelecting = false

        default:
            break
        }
    }

    /// Handle long press for mouse click during capture mode when scroll mode is enabled
    /// Quick finger movement → scroll (captureScrollPanGesture); hold still → mouse click (this gesture)
    /// Note: Do NOT set fingerDragActive here - the gesture manages the full lifecycle.
    /// Setting fingerDragActive would cause touchesCancelled (from cancelsTouchesInView) to
    /// send a premature mouseUp immediately after mouseDown.
    @objc func handleCaptureLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard isMouseCaptured, isTouchScrollMode else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            cancelMomentumScrolling()
            handleMouseDown(at: location, isRightClick: false)
            triggerHapticFeedback()
            showCaptureMagnifier(at: location)

        case .changed:
            handleMouseMove(at: location)
            updateCaptureMagnifier(at: location)

        case .ended, .cancelled:
            handleMouseUp(at: location)
            hideSelectionMagnifier()

        default:
            break
        }
    }

    /// Handle two-finger tap for context menu in scroll mode
    @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard !isMouseCaptured || isTouchScrollMode else { return }
        presentTransientEditMenu(at: gesture.location(in: self), fullContextMenu: true)
    }

    /// Handle left swipe — dispatches the user-configured binding via
    /// SwipeGestureManager. Works in mouse-capture mode (the runtime guard
    /// that previously blocked it has been removed; the swipe recognizer
    /// uses delaysTouchesBegan so a successful swipe never leaks a partial
    /// mouse drag to the captured app).
    @objc func handleTabSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        performSwipeBinding(.left)
    }

    /// Handle right swipe — see handleTabSwipeLeft.
    @objc func handleTabSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        performSwipeBinding(.right)
    }

    @objc func handleAppTabSwipePan(_ gesture: UIPanGestureRecognizer) {
        let direction: SwipeDirection
        if let active = activeAppTabSwipeDirection {
            direction = active
        } else {
            let velocity = gesture.velocity(in: self)
            let translation = gesture.translation(in: self)
            direction = (abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x) < 0 ? .left : .right
            activeAppTabSwipeDirection = direction
        }

        let normalizedTranslation = normalizedAppTabSwipeTranslation(
            gesture.translation(in: self).x,
            direction: direction
        )
        let velocityX = gesture.velocity(in: self).x

        switch gesture.state {
        case .began:
            if !activeAppTabSwipeAccepted {
                activeAppTabSwipeAccepted = requestAppTabSwipeBegin(direction: direction, velocityX: velocityX)
            }
            guard activeAppTabSwipeAccepted else {
                activeAppTabSwipeDirection = nil
                return
            }
        case .changed:
            guard activeAppTabSwipeAccepted else { return }
            postAppTabSwipeNotification(.appTabSwipeChanged, direction: direction, translationX: normalizedTranslation, velocityX: velocityX)
        case .ended:
            guard activeAppTabSwipeAccepted else {
                activeAppTabSwipeDirection = nil
                return
            }
            postAppTabSwipeNotification(.appTabSwipeEnded, direction: direction, translationX: normalizedTranslation, velocityX: velocityX)
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
        case .cancelled, .failed:
            if activeAppTabSwipeAccepted {
                postAppTabSwipeNotification(.appTabSwipeEnded, direction: direction, translationX: 0, velocityX: 0)
            }
            activeAppTabSwipeDirection = nil
            activeAppTabSwipeAccepted = false
        default:
            break
        }
    }

    // normalizedAppTabSwipeTranslation lives on SplitPaneView (shared with
    // non-terminal panes).

    /// Handle two-finger long press to open new connection sheet
    @objc func handleTwoFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        triggerHapticFeedback()
        NotificationCenter.default.post(name: .newTab, object: self)
    }

    /// Handle pinch gesture for font size adjustment in scroll mode
    @objc func handlePinchZoom(_ gesture: UIPinchGestureRecognizer) {
        guard surface != nil, ghosttyApp != nil else { return }

        switch gesture.state {
        case .began:
            pinchScaleAnchor = 1.0
            hideSelectionHandles(animated: false)
            showDimensionOverlay()
            updateDimensionOverlay()

        case .changed:
            let relativeScale = gesture.scale / pinchScaleAnchor
            let threshold: CGFloat = 0.15

            var delta: Int?
            if relativeScale > 1.0 + threshold {
                delta = 1   // Pinch out (fingers apart) — increase font size
            } else if relativeScale < 1.0 - threshold {
                delta = -1  // Pinch in (fingers together) — decrease font size
            }

            if let delta {
                // tmux control mode: font is per-window, so change the whole
                // window uniformly (and only this window). Non-tmux keeps the
                // per-surface path.
                if !applyTmuxWindowFontSize(delta: delta) {
                    changeLocalFontSize(delta: delta)
                }
                pinchScaleAnchor = gesture.scale
                triggerHapticFeedback()
                // Debounce PTY resize — cancel any pending resize before scheduling a new one
                dimensionOverlayHideTask?.cancel()
                dimensionOverlayHideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
                    guard !Task.isCancelled, let self else { return }
                    self.updatePTYSize()
                    self.updateDimensionOverlay()
                }
            }

        case .ended, .cancelled:
            // Ensure final resize fires, then schedule hide
            dimensionOverlayHideTask?.cancel()
            dimensionOverlayHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for final resize
                guard !Task.isCancelled, let self else { return }
                self.updatePTYSize()
                self.updateDimensionOverlay()
                try? await Task.sleep(nanoseconds: 1_500_000_000) // then 1.5s to hide
                guard !Task.isCancelled else { return }
                self.hideDimensionOverlay()
            }

        default:
            break
        }
    }

    // MARK: - Dimension Overlay

    /// Show the dimension overlay (cols × rows), creating it if needed
    private func showDimensionOverlay() {
        if let host = dimensionOverlayHost {
            // Already exists — just make sure it's visible
            host.view.layer.removeAllAnimations()
            host.view.alpha = 1.0
            return
        }

        let resetAction: () -> Void = { [weak self] in
            guard let self else { return }
            // tmux: reset the whole window uniformly; non-tmux resets this surface.
            if !self.resetTmuxWindowFontSize() {
                self.resetLocalFontSize()
            }
            // Debounce PTY resize after reset
            self.dimensionOverlayHideTask?.cancel()
            self.dimensionOverlayHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.updatePTYSize()
                self.updateDimensionOverlay()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.hideDimensionOverlay()
            }
        }
        let host = UIHostingController(rootView: DimensionOverlayView(text: "", onReset: resetAction))
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.dimensionOverlayHost = host

        // Animate in (alpha only — scale transforms cause position artifacts)
        host.view.alpha = 0
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            host.view.alpha = 1.0
        }
    }

    /// Update the dimension overlay text with current cols × rows
    private func updateDimensionOverlay() {
        guard let size = surfaceSize else { return }
        let cols = size.columns
        let rows = size.rows
        let resetAction: () -> Void = { [weak self] in
            guard let self else { return }
            // tmux: reset the whole window uniformly; non-tmux resets this surface.
            if !self.resetTmuxWindowFontSize() {
                self.resetLocalFontSize()
            }
            self.dimensionOverlayHideTask?.cancel()
            self.dimensionOverlayHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.updatePTYSize()
                self.updateDimensionOverlay()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.hideDimensionOverlay()
            }
        }
        dimensionOverlayHost?.rootView = DimensionOverlayView(text: "\(cols) \u{00D7} \(rows)", onReset: resetAction)
        dimensionOverlayHost?.view.invalidateIntrinsicContentSize()
    }

    /// Animate the overlay out and remove it
    private func hideDimensionOverlay() {
        guard let host = dimensionOverlayHost else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
            host.view.alpha = 0
        }, completion: { [weak self] _ in
            host.view.removeFromSuperview()
            self?.dimensionOverlayHost = nil
        })
    }
    #endif

    #if targetEnvironment(macCatalyst)
    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface = surface else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // Always start selection on long press (clears any existing selection)
            isSelecting = true
            selectionStartPoint = location

            // Send mouse press event to start selection
            let pixelPoint = viewToPixelCoordinates(location)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)

            // Route focus through notification system like handleTap
            NotificationCenter.default.post(name: .focusSplit, object: self)
            reloadInputViews()

        case .ended, .cancelled:
            // End selection and show edit menu based on what happened
            if isSelecting {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)

                isSelecting = false
                let startPoint = selectionStartPoint
                selectionStartPoint = nil

                // Note: focus was already established in .began, no need to call becomeFirstResponder() again
                reloadInputViews()

                // Show menu if we created a selection OR if it was a stationary press with clipboard content
                let hasSelection = ghostty_surface_has_selection(surface)
                // Non-prompting detection only: deciding whether to show the menu
                // must not pop the iOS paste-permission dialog. Content is read
                // for real only when the user taps Paste.
                let hasClipboard = UIPasteboard.general.hasPasteableContentWithoutPrompt
                    || (attachmentUploadSSHConfig != nil && UIPasteboard.general.hasImages)
                let wasStationary = startPoint.map { abs($0.x - location.x) < 10 && abs($0.y - location.y) < 10 } ?? false

                if hasSelection || (wasStationary && hasClipboard) {
                    showEditMenu(at: location)
                }
            }

        case .changed:
            // Update selection as finger moves during long press
            if isSelecting {
                let pixelPoint = viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                noteSelectionScrollIndicatorActivity()
            }

        default:
            break
        }
    }
    #endif

    /// Convert view coordinates to pixel coordinates for Ghostty
    func viewToPixelCoordinates(_ point: CGPoint) -> CGPoint {
        // Since we call ghostty_surface_set_content_scale(), Ghostty knows about
        // the scale factor and will apply it internally. So we pass coordinates
        // in points, not pre-scaled pixels.
        return point
    }

    // MARK: - Modifier-Driven Link Refresh

    /// Send a modifier key event to Ghostty when modifier keys change.
    /// This mirrors macOS AppKit's `flagsChanged` → `ghostty_surface_key` path,
    /// triggering `keyCallback` → `modsChanged` → `mouseRefreshLinks` in the
    /// Zig backend to update link detection without requiring mouse movement.
    func handleModifierKeyChange(keyCode: GCKeyCode, pressed: Bool) {
        guard let surface = surface else { return }

        // A live modifier transition from GCKeyboard means its snapshot is fresh
        // again after any prior app/window deactivation.
        isGCKeyboardModifierStateTrusted = true

        switch keyCode {
        case .leftControl:
            heldControlSide = pressed ? (heldControlSide == .right ? .both : .left) : (heldControlSide == .both ? .right : .none)
        case .rightControl:
            heldControlSide = pressed ? (heldControlSide == .left ? .both : .right) : (heldControlSide == .both ? .left : .none)
        case .leftAlt:
            heldOptionSide = pressed ? (heldOptionSide == .right ? .both : .left) : (heldOptionSide == .both ? .right : .none)
        case .rightAlt:
            heldOptionSide = pressed ? (heldOptionSide == .left ? .both : .right) : (heldOptionSide == .both ? .left : .none)
        default:
            break
        }

        // Read current modifier state from GCKeyboard (most up-to-date source)
        var mods = Ghostty.Input.Mods.none
        #if !os(visionOS)
        if let input = GCKeyboard.coalesced?.keyboardInput {
            let leftCmd = input.button(forKeyCode: .leftGUI)?.isPressed ?? false
            let rightCmd = input.button(forKeyCode: .rightGUI)?.isPressed ?? false
            if leftCmd || rightCmd { mods.insert(.cmd) }
            let leftCtrl = input.button(forKeyCode: .leftControl)?.isPressed ?? false
            let rightCtrl = input.button(forKeyCode: .rightControl)?.isPressed ?? false
            if leftCtrl || rightCtrl {
                mods.insert(.ctrl)
                if rightCtrl && !leftCtrl {
                    mods.insert(.ctrlRight)
                }
            }
            let leftShift = input.button(forKeyCode: .leftShift)?.isPressed ?? false
            let rightShift = input.button(forKeyCode: .rightShift)?.isPressed ?? false
            if leftShift || rightShift { mods.insert(.shift) }
            let leftAlt = input.button(forKeyCode: .leftAlt)?.isPressed ?? false
            let rightAlt = input.button(forKeyCode: .rightAlt)?.isPressed ?? false
            if leftAlt || rightAlt {
                mods.insert(.alt)
                if rightAlt && !leftAlt {
                    mods.insert(.altRight)
                }
            }
        }
        #endif

        // Update heldHardwareModifiers so subsequent hover events have correct state
        heldHardwareModifiers = mods

        // We only need to forward Command modifier transitions to Ghostty to
        // trigger Cmd+hover link refresh. Forwarding Alt/Shift/Ctrl modifier-only
        // events can interfere with terminal input handling.
        let hidUsage: UIKeyboardHIDUsage
        switch keyCode {
        case .leftGUI:
            hidUsage = .keyboardLeftGUI
        case .rightGUI:
            hidUsage = .keyboardRightGUI
        default:
            return
        }
        guard let nativeKeyCode = Ghostty.Input.nativeKeyCode(for: hidUsage) else { return }

        let action: Ghostty.Input.Action = pressed ? .press : .release
        let event = Ghostty.Input.KeyEvent(
            nativeKeyCode: nativeKeyCode,
            action: action,
            mods: mods
        )
        event.withCValue { cEvent in
            ghostty_surface_key(surface, cEvent)
        }
    }

    // MARK: - Link Probing

    /// Query current keyboard modifier state for pointer events.
    /// On Catalyst, reads from CGEvent; on iPad, uses tracked hardware modifiers.
    func currentMouseMods() -> ghostty_input_mods_e {
        #if targetEnvironment(macCatalyst)
        var mods = Ghostty.Input.Mods.none
        if let flags = CGEvent(source: nil)?.flags {
            if flags.contains(.maskCommand) { mods.insert(.cmd) }
            if flags.contains(.maskControl) { mods.insert(.ctrl) }
            if flags.contains(.maskShift) { mods.insert(.shift) }
            if flags.contains(.maskAlternate) { mods.insert(.alt) }
        }
        return mods.cMods
        #else
        return heldHardwareModifiers.cMods
        #endif
    }

    /// Probe Ghostty for a hyperlink at the given view coordinate.
    /// Sends mouse_pos with super modifier to trigger link detection,
    /// reads the synchronously-stored URL, then resets modifier state.
    func probeForLink(at point: CGPoint) -> String? {
        guard let surface = surface else { return nil }
        let pixelPoint = viewToPixelCoordinates(point)
        lastProbedLinkURL = nil
        // Reset Ghostty's link_point dedup state by moving to a different grid
        // position first. Regular mouse hover/movement already sends mouse_pos
        // as the cursor tracks to this cell, setting link_point. Without this
        // nudge, the dedup check in Surface.zig cursorPosCallback sees
        // (over_link=false, link_point==pos_vp) and skips link detection.
        ghostty_surface_mouse_pos(surface, 0, 0, Ghostty.Input.Mods.none.cMods)
        // Probe: super modifier triggers link detection in Surface.zig linkAtPos()
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.cmd.cMods)
        let url = lastProbedLinkURL
        // Reset: clear modifier so link underline/cursor doesn't persist
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
        return url
    }
}

// MARK: - Copy/Paste

extension Ghostty.TerminalView {

    override func copy(_ sender: Any?) {
        #if !targetEnvironment(macCatalyst)
        // Responder-chain actions follow typing focus to the external display.
        if let redirect = externalInputRedirectTarget {
            redirect.copy(sender)
            return
        }
        #endif
        guard let surface = surface else { return }

        // Check if there's a selection
        guard ghostty_surface_has_selection(surface) else {
            Ghostty.logger.info("No selection to copy")
            return
        }

        // Read the selection
        var textStruct = ghostty_text_s()
        ghostty_surface_read_selection(surface, &textStruct)

        // Check if we got valid text
        guard textStruct.text_len > 0, let textPtr = textStruct.text else {
            Ghostty.logger.info("No text in selection")
            return
        }
        defer { ghostty_surface_free_text(surface, &textStruct) }

        // Copy to clipboard
        let data = Data(bytes: textPtr, count: Int(textStruct.text_len))
        if let string = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = string
            ClipboardHistoryManager.shared.record(string, source: .explicitCopy)
            Ghostty.logger.info("Copied \(string.count) characters to clipboard")
        }
    }

    override func paste(_ sender: Any?) {
        #if !targetEnvironment(macCatalyst)
        if let redirect = externalInputRedirectTarget {
            redirect.paste(sender)
            return
        }
        #endif
        // Check for non-text clipboard content when session supports SFTP upload.
        // On a tmux -CC pane this resolves the gateway's remote host (see
        // attachmentUploadSSHConfig) so image paste works there too.
        if let sshConfig = attachmentUploadSSHConfig {
            let pasteContent = PasteAttachmentDetector.detect()
            if case .attachments(let items) = pasteContent {
                showAttachmentUploadSheet(attachments: items, sshConfig: sshConfig)
                return
            }
        }

        // Capture into clipboard history before Ghostty reads the pasteboard.
        // Prompt-safe: this runs only on a user-invoked paste, the same moment
        // readClipboard would read it anyway.
        if let text = UIPasteboard.general.getOpinionatedStringContents() {
            ClipboardHistoryManager.shared.record(text, source: .paste)
        }

        // Trigger Ghostty's paste action which will call our readClipboard callback
        // The callback extracts the surface from userdata (set during surface creation)
        if !performAction("paste_from_clipboard") {
            Ghostty.logger.warning("paste_from_clipboard action failed")
        }
    }

    override func selectAll(_ sender: Any?) {
        #if !targetEnvironment(macCatalyst)
        if let redirect = externalInputRedirectTarget {
            _ = redirect.performAction("select_all")
            return
        }
        #endif
        // Use Ghostty's select_all binding action
        _ = performAction("select_all")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        #if !targetEnvironment(macCatalyst)
        // Validate against the terminal the action lands on; paste falls
        // through (pasteboard state is device-global).
        if let redirect = externalInputRedirectTarget {
            if action == #selector(copy(_:)) {
                guard let surface = redirect.surface else { return false }
                return ghostty_surface_has_selection(surface)
            }
            if action == #selector(selectAll(_:)) {
                return redirect.surface != nil
            }
        }
        #endif
        if action == #selector(copy(_:)) {
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        }
        if action == #selector(paste(_:)) {
            // Use non-prompting detection APIs here. UIKit re-validates this on
            // every app foreground while the terminal is first responder, so
            // reading actual pasteboard content (hasPasteableContent) would pop
            // the iOS paste-permission dialog on every app switch. The real
            // content read happens later in paste(_:), when the user invokes it.
            if UIPasteboard.general.hasPasteableContentWithoutPrompt { return true }
            if attachmentUploadSSHConfig != nil && UIPasteboard.general.hasImages {
                return true
            }
            return false
        }
        if action == #selector(selectAll(_:)) {
            return surface != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Show context menu at the specified location
    /// Note: UIContextMenuInteraction doesn't support programmatic presentation.
    /// The menu shows automatically on long-press (iOS) or right-click (Catalyst).
    /// This method is kept for backward compatibility but is no longer needed.
    func showEditMenu(at point: CGPoint) {
        // UIContextMenuInteraction handles menu presentation automatically
        // on long-press (iOS) or right-click (Mac Catalyst)
    }

    /// Reset the terminal (clear scrollback and reset state)
    @objc func resetTerminal(_ sender: Any?) {
        _ = performAction("reset")
    }

    /// Prompt user to change the terminal title
    @objc func promptChangeTitle(_ sender: Any?) {
        let alert = UIAlertController(
            title: "Change Terminal Title",
            message: "Leave blank to restore the default.",
            preferredStyle: .alert
        )

        alert.addTextField { [weak self] textField in
            guard let self else {
                textField.placeholder = "Terminal title"
                return
            }
            let currentTitle = self.title
            if currentTitle.isEmpty || currentTitle == "ghostty" {
                switch self.connectionConfig {
                case .local:
                    textField.text = nil
                default:
                    textField.text = self.connectionConfig.displayName
                }
            } else {
                textField.text = currentTitle
            }
            textField.placeholder = "Terminal title"
        }

        let okAction = UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let newTitle = alert.textFields?.first?.text ?? ""
            if newTitle.isEmpty {
                // Empty means restore default - use the session-provided title
                // or a default placeholder
                if let sessionTitle = self.sessionProvidedTitle, !sessionTitle.isEmpty {
                    self.title = sessionTitle
                } else {
                    self.title = "Terminal"
                }
                self.userOverrideTitle = nil
            } else {
                // Set user-specified title
                self.title = newTitle
                self.userOverrideTitle = newTitle
            }
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

        alert.addAction(okAction)
        alert.addAction(cancelAction)

        // Find the presenting view controller
        if let rootViewController = self.window?.rootViewController {
            var presenter = rootViewController
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(alert, animated: true)
        }
    }
}

// MARK: - Terminal I/O

extension Ghostty.TerminalView {

    /// Sends user input to the appropriate destination based on platform
    func sendUserInput(_ data: Data) {
        #if !targetEnvironment(macCatalyst)
        // Toolbar keys, paste, compose and every other byte source on the
        // device terminal act on the external terminal while forwarding.
        if let redirect = externalInputRedirectTarget {
            redirect.sendUserInput(data)
            return
        }
        #endif

        // tmux -CC gateway: a lone ESC delivered to the gateway view means the
        // user is on the gateway and wants out of control mode. Detach instead of
        // forwarding the raw ESC to tmux. This is the convergence point for every
        // ESC source — hardware key paths (pressesBegan / handleEscapeKey) and the
        // on-screen toolbar Esc key all funnel through here — so it catches what
        // the per-platform key handlers miss. Only the gateway view has a
        // controller, so panes/normal terminals are unaffected.
        if data.count == 1, data.first == 0x1b, (tmuxController?.isActive == true || isTmuxGatewaySurfaceActive) {
            sendTmuxDetach()
            return
        }
        noteUserInputForOutputCoalescing()
        // Track that user has typed (for tmux discovery overlay)
        if !hasUserTyped { hasUserTyped = true }
        #if targetEnvironment(macCatalyst)
        // For Catalyst: Sessions (SSH or local shell) handle their own I/O.
        // A tmux control mode pane has no session, so route its input to the
        // surface, whose tmux backend emits `send-keys` (mirrors the iOS path).
        if let session = session {
            session.sendInput(data)
        } else {
            sendInputToPaneSurface(data)
        }
        #else
        // For iOS/visionOS: Send to session or Ghostty
        if let session = session {
            session.sendInput(data)
        } else {
            sendInputToPaneSurface(data)
        }

        if selectionHandlesVisible || activeHandleDrag != nil {
            scheduleSelectionHandleSync(afterGhosttyAppTick: true)
        }
        #endif
    }

    /// Send already-encoded input bytes to a tmux control-mode pane surface
    /// (which has no `session`). Routes through `ghostty_surface_send_input` so
    /// the bytes reach tmux verbatim as `send-keys`, bypassing the clipboard-
    /// paste path (`ghostty_surface_text` → `completeClipboardPaste`) that frames
    /// in bracketed paste and applies paste-protection filtering — which silently
    /// drops or corrupts control keys like backspace (`0x7f`), arrows, and Ctrl-*.
    /// The apprt has already encoded the key event into terminal bytes, so no
    /// re-encoding is needed; they are relayed as-is.
    private func sendInputToPaneSurface(_ data: Data) {
        guard let surface = surface, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_send_input(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(data.count))
        }
    }

    /// Sends composed text from the compose overlay to the terminal
    func sendComposedText(_ text: String) {
        commitKoreanCompositionIfNeeded(external: true)
        guard let data = text.data(using: .utf8) else { return }
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        sendUserInput(data)
    }

    func handleSessionOutput(data: Data) {
        // Note: For CatalystLocalShellSession, output is now written directly
        // via thread-safe callbacks. This path is used for other session types.
        if shouldUseOutputCoalescer && isMouseCaptured {
            outputPipeline.enqueueCoalescedOutput(data)
        } else {
            writeSessionOutputToGhostty(data: data)
        }
    }

    func handleSessionOutput(string: String) {
        let data = Data(string.utf8)
        if shouldUseOutputCoalescer && isMouseCaptured {
            outputPipeline.enqueueCoalescedOutput(data)
        } else {
            writeSessionOutputToGhostty(data: data)
        }
    }

    func writeToGhostty(data: Data) {
        // Write raw bytes to the buffered writer.
        // The buffered writer handles backpressure by buffering data when the
        // pipe is full, preventing data loss during heavy I/O from apps like zellij.
        outputPipeline.writeDirect(data)
    }

    func writeToGhostty(string: String) {
        // Convert string to UTF-8 and write via buffered writer
        outputPipeline.writeDirect(string)
    }

    func writeSessionOutputToGhostty(data: Data) {
        outputPipeline.writeSessionOutput(data)
    }

    func triggerHapticFeedback() {
#if !os(visionOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
#endif
    }
}

// MARK: - Attachment Upload

extension Ghostty.TerminalView {

    /// The SSHConfig an attachment (image/file) pasted or dropped onto THIS view
    /// should upload to, or nil when the effective host is purely local.
    ///
    /// A normal SSH/Mosh/Trzsz tab returns its own connection. A tmux -CC PANE is
    /// created with `connectionConfig: .local()` and no `session` (it is a
    /// stateless renderer; input is relayed to the gateway as `send-keys`), so its
    /// own config never yields a host. For a pane we resolve the GATEWAY terminal
    /// behind the control-mode session — reachable via `tmuxPaneBinding.parentSurface`
    /// (the gateway's surface) using `ghostty_surface_userdata`, the same
    /// `Unmanaged…takeUnretainedValue` round-trip the reconcile handler uses — and
    /// return its effective remote config. This makes paste/drop upload to the host
    /// the tmux session actually runs on, matching plain `tmux` over SSH. A live
    /// pane implies a live gateway, so the synchronous main-actor lookup is safe.
    ///
    /// nil when the gateway is purely local (a local shell, or a local tmux -CC
    /// server with no embedded remote); callers then fall back to local insertion.
    var attachmentUploadSSHConfig: SSHConfig? {
        if let cfg = connectionConfig.sshConfigForHistory { return cfg }
        // `parentSurface` is a raw, unretained pointer captured at bind time. It
        // can dangle after the gateway is torn down: scene/window teardown frees
        // the gateway surface but leaves this pane binding intact, and the gateway
        // view's `cleanup()` ends neither its `TmuxController` nor `isActive` — so
        // a `ghostty_surface_userdata(parentSurface)` round-trip (use-after-free)
        // OR a `controller.isActive` gate is unsafe (an active controller can
        // outlive its freed owner surface). This getter is especially exposed
        // because UIKit calls it autonomously (canPerformAction / image-paste
        // support checks) DURING teardown — the reported crash: the freed-pointer
        // read faulted, ios_system's signal handler pthread_exit'd the main
        // thread, and a UIKit keyboard fence assertion then aborted.
        //
        // Resolve the gateway through the app's surface->delegate registry, which
        // is keyed by pointer VALUE (never dereferences the surface), holds the
        // view WEAKLY, and is cleared synchronously in `cleanup()` before the
        // free. It yields the live gateway view or nil, never a freed object, and
        // touches no C surface at all. Then confirm identity: the freed gateway's
        // address could have been reused by an UNRELATED surface (ABA), so verify
        // the resolved view is the same gateway by its stable `uuid` captured at
        // bind time — otherwise we could resolve (and upload to) the wrong host.
        // (id=tmux-stale-parent-surface)
        guard let binding = tmuxPaneBinding,
              let gateway = ghosttyApp?.surfaceView(for: binding.parentSurface),
              gateway.uuid == binding.parentUUID else { return nil }
        if let cfg = gateway.connectionConfig.sshConfigForHistory { return cfg }
        // Gateway is a local shell currently hosting an embedded remote
        // (e.g. `tssh host` then `tmux -CC`): use that remote's host.
        // LocalShellSession (and its embedded-session tracking) only exists on
        // iOS/visionOS; Mac Catalyst uses CatalystLocalShellSession, which has no
        // embedded-remote concept, so there is nothing further to resolve there.
#if !targetEnvironment(macCatalyst)
        if let local = gateway.session as? LocalShellSession {
            return local.activeEmbeddedConnectionConfig?.sshConfigForHistory
        }
#endif
        return nil
    }

    /// Present the attachment upload confirmation sheet
    func showAttachmentUploadSheet(attachments: [PasteAttachment], sshConfig: SSHConfig) {
        guard let presenter = findPresenterViewController() else { return }

        // Dismiss the on-screen keyboard so the sheet isn't hidden behind it
        resignFirstResponder()

        let host = sshConfig.host
        let defaultDest = UserDefaults.standard.string(
            forKey: "paste.destination.\(host)"
        ) ?? "/tmp/rootshell-uploads/"

        let sheet = AttachmentUploadSheet(
            attachments: attachments,
            host: host,
            defaultDestination: defaultDest,
            onUpload: { [weak self] destination, format in
                presenter.dismiss(animated: true)
                self?.becomeFirstResponder()
                self?.startAttachmentUpload(
                    attachments: attachments,
                    sshConfig: sshConfig,
                    destination: destination,
                    format: format
                )
            },
            onCancel: { [weak self] in
                presenter.dismiss(animated: true)
                // Restore keyboard focus after cancel
                self?.becomeFirstResponder()
            }
        )

        let hostingController = UIHostingController(rootView: sheet)
        #if !os(visionOS)
        if let sheetPC = hostingController.sheetPresentationController {
            sheetPC.detents = [.medium(), .large()]
            sheetPC.prefersGrabberVisible = true
        }
        #endif
        presenter.present(hostingController, animated: true)
    }

    /// Start uploading attachments and show progress banner
    func startAttachmentUpload(
        attachments: [PasteAttachment],
        sshConfig: SSHConfig,
        destination: String,
        format: PasteInsertFormat
    ) {
        // Cancel any existing upload
        activeUploader?.cancel()

        let uploader = AttachmentUploader(
            config: sshConfig,
            attachments: attachments,
            destination: destination
        )
        activeUploader = uploader

        // Notify TerminalScrollView to show banner
        uploader.onStateChange = { [weak self] state in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .ghosttyAttachmentUploadStateChanged,
                object: self,
                userInfo: ["state": state]
            )

            // Handle completion: insert paths into terminal
            if case .completed(let paths) = state {
                self.handleUploadCompletion(paths: paths, format: format)
                // Auto-dismiss banner after 2 seconds
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    NotificationCenter.default.post(
                        name: .ghosttyAttachmentUploadStateChanged,
                        object: self,
                        userInfo: nil  // nil = hide banner
                    )
                    self.activeUploader = nil
                }
            } else if case .failed = state {
                // Auto-dismiss error banner after 4 seconds
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    NotificationCenter.default.post(
                        name: .ghosttyAttachmentUploadStateChanged,
                        object: self,
                        userInfo: nil
                    )
                    self.activeUploader = nil
                }
            }
        }

        uploader.startAsync()
    }

    /// Insert uploaded file paths into the terminal using bracketed paste
    private func handleUploadCompletion(paths: [String], format: PasteInsertFormat) {
        let formatted: [String] = paths.map { path in
            let escaped = Ghostty.Shell.escape(path)
            switch format {
            case .pathOnly:
                return escaped
            case .markdownImage:
                return "![](\(escaped))"
            }
        }
        let text = formatted.joined(separator: " ")

        // Use Ghostty's clipboard paste mechanism for bracketed paste markers.
        // Save ALL pasteboard items (not just string) so non-text content
        // (images, PDFs) is preserved after we temporarily overwrite the clipboard.
        let savedItems = UIPasteboard.general.items
        UIPasteboard.general.string = text
        _ = performAction("paste_from_clipboard")

        // Restore the original clipboard contents after a brief delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            UIPasteboard.general.items = savedItems
        }
    }

    /// Paste arbitrary text through Ghostty's bracketed-paste path without
    /// permanently clobbering the system clipboard (same temporary-overwrite
    /// mechanism as handleUploadCompletion). Used by the clipboard manager;
    /// suppressCapture keeps the synthetic paste (and any OSC 52 echo of it)
    /// out of the history.
    func pasteText(_ text: String) {
        ClipboardHistoryManager.shared.suppressCapture = true
        let savedItems = UIPasteboard.general.items
        UIPasteboard.general.string = text
        _ = performAction("paste_from_clipboard")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            UIPasteboard.general.items = savedItems
            ClipboardHistoryManager.shared.suppressCapture = false
        }
    }

    /// Find a UIViewController suitable for presenting sheets
    private func findPresenterViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                return vc
            }
            responder = next
        }
        return nil
    }

    /// Cancel the current attachment upload
    func cancelAttachmentUpload() {
        activeUploader?.cancel()
        activeUploader = nil
        NotificationCenter.default.post(
            name: .ghosttyAttachmentUploadStateChanged,
            object: self,
            userInfo: nil
        )
    }
}

// MARK: - Mouse/Trackpad Support

extension Ghostty.TerminalView {

    // Scroll handling for mouse capture mode (tmux, vim) is done by TerminalScrollView.
    // It intercepts UIScrollView events, forwards deltas to Ghostty, and resets the
    // scroll position to prevent visual scrolling while maintaining native physics.

    /// Track which mouse button is currently pressed for proper release event
    private static var pressedMouseButton: ghostty_input_mouse_button_e = GHOSTTY_MOUSE_LEFT

    #if !targetEnvironment(macCatalyst)
    // Track if mouse down was cancelled because touch became multi-finger (scroll gesture)
    // If cancelled, don't send mouse up on touch end
    private static var mouseDownCancelledKey: UInt8 = 0

    private var mouseDownCancelled: Bool {
        get { (objc_getAssociatedObject(self, &Self.mouseDownCancelledKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.mouseDownCancelledKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private static let captureTapMaxMovement: CGFloat = 10
    private static let captureTapMaxDuration: TimeInterval = 0.3

    private func beginCaptureTapCandidate(_ touch: UITouch, suppressForMomentum: Bool) {
        captureTapStartPoint = touch.location(in: self)
        captureTapStartTimestamp = touch.timestamp
        captureTapInvalidated = false
        captureTapSuppressedForMomentum = suppressForMomentum
    }

    private func cancelCaptureTapCandidate() {
        captureTapStartPoint = nil
        captureTapStartTimestamp = 0
        captureTapInvalidated = false
        captureTapSuppressedForMomentum = false
    }

    private func updateCaptureTapCandidate(_ touch: UITouch) {
        guard let startPoint = captureTapStartPoint else { return }

        let point = touch.location(in: self)
        let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
        if distance > Self.captureTapMaxMovement {
            captureTapInvalidated = true
        }
    }

    @discardableResult
    private func finishCaptureTapCandidate(_ touch: UITouch, event: UIEvent?) -> Bool {
        defer { cancelCaptureTapCandidate() }

        guard let startPoint = captureTapStartPoint,
              !captureTapInvalidated,
              !captureTapSuppressedForMomentum,
              touch.type == .direct,
              isTouchScrollMode,
              !mousePressed,
              let surface = surface,
              ghostty_surface_mouse_captured(surface)
        else {
            return false
        }

        let allTouches = event?.allTouches ?? Set([touch])
        let remainingTouches = allTouches.filter { $0.phase != .ended && $0.phase != .cancelled }
        guard remainingTouches.isEmpty else { return false }

        let point = touch.location(in: self)
        let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
        let duration = touch.timestamp - captureTapStartTimestamp
        guard distance <= Self.captureTapMaxMovement,
              duration <= Self.captureTapMaxDuration
        else {
            return false
        }

        cancelMomentumScrolling()
        handleMouseDown(at: point, isRightClick: false)
        guard mousePressed, Self.pressedMouseButton == GHOSTTY_MOUSE_LEFT else {
            return false
        }
        handleMouseUp(at: point)
        return true
    }
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Safety net: if we're logically focused but not first responder, restore it
        // Skip if user manually dismissed keyboard — they want to scroll freely.
        // Keyboard will be restored on a deliberate single tap via touchesEnded.
        if isLogicallyFocused && !isFirstResponder && !keyboardManuallyDismissed {
            Ghostty.logger.debug("touchesBegan: Restoring focus via tap")
            _ = becomeFirstResponder()
        }

        // Track touch start for keyboard restore tap detection. Finger only:
        // iPadOS answers pencil focus with the minimized-keyboard pill instead
        // of a real keyboard, so a pencil tap must not re-arm keyboard state.
        if (keyboardManuallyDismissed || toolbarOnlyMode) && !keyboardToolbarCollapsed,
           let touch = touches.first,
           touch.type == .direct {
            dismissTapStartPoint = touch.location(in: self)
        }

        guard let touch = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }

        let allTouches = event?.allTouches ?? touches

        #if !targetEnvironment(macCatalyst)
        // Track touch type for context menu gating in scroll mode
        lastContextMenuTriggerWasFinger = touch.isScreenContact
        lastContextMenuTriggerWasPencil = (touch.type == .pencil)
        if touch.type == .pencil {
            lastPencilLocation = touch.location(in: self)
            lastPencilLocationTimestamp = touch.timestamp
            Self.lastPencilContactView = self
        }

        if touch.type == .direct {
            updateSelectionSuppressionForDirectTouches(touches, event: event)
        }
        #endif

        #if !targetEnvironment(macCatalyst)
        // If second finger arrives while we have a finger or pencil drag active,
        // cancel it. This converts the interaction from a drag to a two-finger scroll
        if allTouches.count > 1 && (fingerDragActive || pencilPointerDragActive) {
            stopCaptureAutoScroll()
            // Cancel the drag by sending mouse up
            if let surface = surface {
                let point = touch.location(in: self)
                let pixelPoint = viewToPixelCoordinates(point)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
                sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
            }
            fingerDragActive = false
            pencilPointerDragActive = false
            mousePressed = false
            mouseDownCancelled = true
            hideSelectionMagnifier(animated: false)
        }
        if allTouches.count > 1 {
            cancelCaptureTapCandidate()
        }
        #endif

        // Only cancel momentum for single-finger touches (taps, mouse clicks)
        // Multi-finger touches are scroll gestures - let gesture recognizer handle those
        let cancelledMomentumForTouch = allTouches.count == 1 && cancelMomentumScrolling()

        // Check if this is a mouse/trackpad event
        if touch.type == .indirectPointer {
            let point = touch.location(in: self)
            // Check which button is pressed (iOS 13.4+)
            let isRightClick = event?.buttonMask.contains(.secondary) ?? false
            handleMouseDown(at: point, isRightClick: isRightClick)
            return
        }

        #if !targetEnvironment(macCatalyst)
        // Apple Pencil: a precise pointer while the app captures the mouse —
        // pen-down is an immediate left button-down, uniform across scroll
        // modes and without the capture magnifier. Not captured, the pencil
        // behaves like a finger: the tap/selection gestures and scroll view
        // own it, so it must not fall into the finger capture branch below.
        if touch.type == .pencil {
            if allTouches.count == 1, let surface = surface {
                let captured = ghostty_surface_mouse_captured(surface)
                if isMouseCaptured != captured {
                    isMouseCaptured = captured
                }
                if captured {
                    handleMouseDown(at: touch.location(in: self), isRightClick: false)
                    pencilPointerDragActive = true
                    mouseDownCancelled = false
                    return
                }
            }
            super.touchesBegan(touches, with: event)
            return
        }

        // Finger touch in capture mode - send mouse down immediately for responsive drags
        // If a second finger arrives later, we'll cancel the drag
        if allTouches.count == 1, let surface = surface {
            let captured = ghostty_surface_mouse_captured(surface)
            // Update cached state if it changed
            if isMouseCaptured != captured {
                isMouseCaptured = captured
            }
            if captured {
                // In scroll mode, don't send immediate mouse-down for finger touches
                // Let gesture recognizers handle it: pan → scroll, long press → mouse click/drag.
                // Track a short-tap candidate here so a deliberate tap can still position
                // captured apps like vim without racing the scroll pan recognizer.
                if isTouchScrollMode {
                    beginCaptureTapCandidate(
                        touch,
                        suppressForMomentum: cancelledMomentumForTouch
                    )
                    super.touchesBegan(touches, with: event)
                    return
                }
                let point = touch.location(in: self)
                handleMouseDown(at: point, isRightClick: false)
                showCaptureMagnifier(at: point)
                fingerDragActive = true
                mouseDownCancelled = false
                return
            }
        }
        #endif

        // Finger touches in non-capture mode are handled by:
        // - UIScrollView for scrolling
        // - Long press gesture for text selection
        // - Tap gesture for focusing
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }

        #if !targetEnvironment(macCatalyst)
        if touch.type == .direct {
            updateSelectionSuppressionForDirectTouches(touches, event: event)
            updateCaptureTapCandidate(touch)
        }
        if touch.type == .pencil {
            lastPencilLocation = touch.location(in: self)
            lastPencilLocationTimestamp = touch.timestamp
        }
        #endif

        if touch.type == .indirectPointer && mousePressed {
            let point = touch.location(in: self)
            handleMouseMove(at: point)
            return
        }

        #if !targetEnvironment(macCatalyst)
        if touch.type == .pencil, pencilPointerDragActive {
            handleMouseMove(at: touch.location(in: self))
            return
        }

        if fingerDragActive {
            // Finger drag in capture mode - send position updates
            let point = touch.location(in: self)
            handleMouseMove(at: point)
            updateCaptureMagnifier(at: point)
            return
        }
        #endif

        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesEnded(touches, with: event)
            return
        }

        #if !targetEnvironment(macCatalyst)
        if touch.type == .direct {
            updateSelectionSuppressionForDirectTouches(touches, event: event)
        }
        #endif

        if touch.type == .indirectPointer {
            let point = touch.location(in: self)
            handleMouseUp(at: point)
            selectionMouseDragActive = false
            stopRightClickMonitoring()
            return
        }

        #if !targetEnvironment(macCatalyst)
        // Handle pencil release for a captured pointer drag
        if touch.type == .pencil, pencilPointerDragActive {
            if !mouseDownCancelled {
                handleMouseUp(at: touch.location(in: self))
            }
            pencilPointerDragActive = false
            mouseDownCancelled = false
            return
        }

        // Handle finger release in capture mode
        if fingerDragActive {
            let point = touch.location(in: self)
            // Only send mouse up if we didn't cancel the drag (converted to scroll)
            if !mouseDownCancelled {
                handleMouseUp(at: point)
            }
            hideSelectionMagnifier()
            fingerDragActive = false
            mouseDownCancelled = false
            return
        }

        if touch.type == .direct {
            _ = finishCaptureTapCandidate(touch, event: event)
        }

        // Clear cancelled state when all fingers lift
        let allTouches = event?.allTouches ?? touches
        let remainingTouches = allTouches.filter { $0.phase != .ended && $0.phase != .cancelled }
        if remainingTouches.isEmpty {
            mouseDownCancelled = false
        }
        #endif

        // Restore full keyboard from toolbar-only mode on tap
        // (unless the user pinned it hidden via chevron long-press)
        if toolbarOnlyMode && !keyboardPinnedHidden && !keyboardToolbarCollapsed && isFirstResponder && touch.type == .direct {
            let allEndTouches = event?.allTouches ?? touches
            let remaining = allEndTouches.filter { $0.phase != .ended && $0.phase != .cancelled }
            if remaining.isEmpty, let startPoint = dismissTapStartPoint {
                let endPoint = touch.location(in: self)
                let distance = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
                dismissTapStartPoint = nil
                if distance < 20 {
                    exitToolbarOnlyMode()
                }
            }
        }

        // Restore keyboard on deliberate single tap after manual dismiss.
        // Only restore if the finger didn't travel far (tap, not scroll).
        if keyboardManuallyDismissed && !keyboardPinnedHidden && isLogicallyFocused && !isFirstResponder && touch.type == .direct {
            let allEndTouches = event?.allTouches ?? touches
            let remaining = allEndTouches.filter { $0.phase != .ended && $0.phase != .cancelled }
            if remaining.isEmpty, let startPoint = dismissTapStartPoint {
                let endPoint = touch.location(in: self)
                let distance = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
                dismissTapStartPoint = nil
                if distance < 20 {
                    keyboardManuallyDismissed = false
                    keyboardDismissedShadersSuppressed = false
                    _ = becomeFirstResponder()
                }
            }
        }

        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesCancelled(touches, with: event)
            return
        }

        #if !targetEnvironment(macCatalyst)
        if touch.type == .direct {
            updateSelectionSuppressionForDirectTouches(touches, event: event)
            cancelCaptureTapCandidate()
        }
        #endif

        if touch.type == .indirectPointer {
            let point = touch.location(in: self)
            stopCaptureAutoScroll()

            #if !targetEnvironment(macCatalyst)
            // On iPad, if we're tracking a right-click from context menu, don't let
            // touchesCancelled stop it. The pan gesture or touchesEnded handles release.
            if Self.rightClickTrackingView != nil {
                return
            }
            #endif

            // Send release if we had a press
            if mousePressed {
                handleMouseUp(at: point)
            }
            selectionMouseDragActive = false
            stopRightClickMonitoring()
            return
        }

        #if !targetEnvironment(macCatalyst)
        if touch.type == .pencil, pencilPointerDragActive {
            // Pencil cancelled during a captured pointer drag
            if !mouseDownCancelled {
                handleMouseUp(at: touch.location(in: self))
            }
            pencilPointerDragActive = false
            mouseDownCancelled = false
            return
        }

        if fingerDragActive {
            // Finger cancelled in capture mode
            let point = touch.location(in: self)
            // Only send mouse up if we didn't cancel the drag
            if !mouseDownCancelled {
                handleMouseUp(at: point)
            }
            hideSelectionMagnifier(animated: false)
            fingerDragActive = false
            mouseDownCancelled = false
            return
        }
        #endif

        super.touchesCancelled(touches, with: event)
    }

    func captureAutoScrollMouseStateAllowsDrag() -> Bool {
        mousePressed && Self.pressedMouseButton == GHOSTTY_MOUSE_LEFT && !selectionMouseDragActive
    }

    func handleMouseDown(at point: CGPoint, isRightClick: Bool = false) {
        stopCaptureAutoScroll()
        guard let surface = surface else { return }

        // If we're already tracking a right-click from context menu, don't process again
        if mousePressed && Self.pressedMouseButton == GHOSTTY_MOUSE_RIGHT {
            return
        }

        // Notify MainView to update focused terminal
        NotificationCenter.default.post(name: .focusSplit, object: self)

        // Handle right-clicks early: for non-captured terminals, return immediately
        // so that UIContextMenuInteraction's probeForLink() is the first mouse_pos
        // call at this position. Sending mouse_pos here without Cmd would set
        // Ghostty's link_point dedup state, causing the subsequent probeForLink()
        // call at the same position to skip link detection entirely.
        if isRightClick {
            if ghostty_surface_mouse_captured(surface) {
                let mods = currentMouseMods()
                let pixelPoint = viewToPixelCoordinates(point)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
                mousePressed = true
                Self.pressedMouseButton = GHOSTTY_MOUSE_RIGHT
                sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: mods)
            }
            return
        }

        let mods = currentMouseMods()
        let pixelPoint = viewToPixelCoordinates(point)
        // mouse_pos fires mouse_over_link callback synchronously, setting lastProbedLinkURL
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)

        // Cmd+click on a hyperlink: open it directly.
        // We can't rely on sendMouseButton → ghostty_surface_mouse_button for this because
        // it dispatches to ghosttyAPIQueue (async), and by the time the mailbox processes the
        // button event the synchronous link state from mouse_pos is gone.
        let ghosttyMods = Ghostty.Input.Mods(cMods: mods)
        if ghosttyMods.contains(.cmd), let linkURL = lastProbedLinkURL,
           let url = URL(string: linkURL) {
            lastProbedLinkURL = nil
            // Reset modifier state so link underline doesn't persist
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            UIApplication.shared.open(url)
            return
        }

        mousePressed = true
        Self.pressedMouseButton = GHOSTTY_MOUSE_LEFT
        selectionMouseDragActive = !ghostty_surface_mouse_captured(surface)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: mods)
    }

    func handleMouseMove(at point: CGPoint) {
        guard let surface = surface else { return }

        let pixelPoint = viewToPixelCoordinates(point)
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, currentMouseMods())
        updateCaptureAutoScroll(at: point)
        if selectionMouseDragActive {
            noteSelectionScrollIndicatorActivity()
        }
    }

    func noteSelectionScrollIndicatorActivity() {
        NotificationCenter.default.post(name: .ghosttySelectionScrollIndicatorActivity, object: self)
    }

    func handleMouseUp(at point: CGPoint) {
        stopCaptureAutoScroll()
        guard let surface = surface else { return }

        let mods = currentMouseMods()
        let pixelPoint = viewToPixelCoordinates(point)
        ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: Self.pressedMouseButton, mods: mods)

        mousePressed = false
        selectionMouseDragActive = false
    }
}

// MARK: - UIPointerInteractionDelegate

extension Ghostty.TerminalView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, return nil to let NSCursor handle cursor management.
        // UIPointerInteraction cursors "leak" beyond view bounds on Catalyst.
        return nil
        #else
        // Don't override pointer style while app-level UI covers the terminal.
        // iPad Settings is a SwiftUI SidePanelOverlay, not a presented view
        // controller, so it must use the same occlusion flag as selection UI.
        if selectionUIExternallyOccluded || self.window?.rootViewController?.presentedViewController != nil {
            return nil
        }
        // Use I-beam cursor for text on iOS/iPadOS
        return UIPointerStyle(shape: .verticalBeam(length: 20))
        #endif
    }
}

// MARK: - UIEditMenuInteractionDelegate

#if !targetEnvironment(macCatalyst)
extension Ghostty.TerminalView: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        // Don't show edit menu in capture mode (unless scroll mode is active)
        if isMouseCaptured && !isTouchScrollMode {
            return nil
        }

        // Full context menu for two-finger tap in scroll mode
        if isFullContextMenuPresentation {
            let probedLink = probeForLink(at: configuration.sourcePoint)
            return buildContextMenu(linkURL: probedLink)
        }

        // Build a simple Copy/Paste menu for text selection
        var items: [UIMenuElement] = []

        // Probe for link at the menu's source point
        let linkURL = probeForLink(at: configuration.sourcePoint)
        if let linkURL, let url = URL(string: linkURL) {
            items.append(UIAction(title: String(localized: "Open Link"), image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            })
            items.append(UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.string = linkURL
                ClipboardHistoryManager.shared.record(linkURL, source: .copyLink)
            })
        }

        // Copy (only if text is selected)
        if let surface = surface, ghostty_surface_has_selection(surface) {
            items.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        // Paste (only if clipboard has content). Match canPerformAction/long-press:
        // hasStrings alone hides Paste for a URL-only clipboard, even though
        // paste(_:) pastes URLs via getOpinionatedStringContents(). Detection-only
        // predicate, so this still never triggers the paste-permission prompt.
        let hasPasteContent = UIPasteboard.general.hasPasteableContentWithoutPrompt
            || (attachmentUploadSSHConfig != nil && UIPasteboard.general.hasImages)
        if hasPasteContent {
            items.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(nil)
            })
        }

        return items.isEmpty ? nil : UIMenu(children: items)
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        animator.addCompletion { [weak self] in
            guard let self else { return }
            if let interaction = self.editMenuInteraction {
                self.removeInteraction(interaction)
                self.editMenuInteraction = nil
            }
            self.isFullContextMenuPresentation = false
        }
    }
}
#endif

// MARK: - UIContextMenuInteractionDelegate

extension Ghostty.TerminalView: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // When terminal has mouse capture (tmux, vim), don't show context menu
        // Instead, send right-click to terminal and start tracking for drag/release
        if let surface = surface, ghostty_surface_mouse_captured(surface) {
            #if !targetEnvironment(macCatalyst)
            // A captured pencil hold is already a left-button drag; firing the
            // right-click press here would corrupt it. Barrel tap is the
            // pencil's right-click.
            if lastContextMenuTriggerWasPencil {
                return nil
            }

            // In scroll mode, don't intercept finger long-press for right-click
            // Let capture gestures (scroll pan, long press) handle the touch instead
            if isTouchScrollMode && lastContextMenuTriggerWasFinger {
                return nil
            }

            // Ensure view is first responder so touch events are delivered
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
            // Also notify focus system
            NotificationCenter.default.post(name: .focusSplit, object: self)
            #endif

            // Capture the start position FIRST before any delay
            setRightClickStartPosition(location)

            // Send right-click press to terminal
            let pixelPoint = viewToPixelCoordinates(location)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
            mousePressed = true
            Self.pressedMouseButton = GHOSTTY_MOUSE_RIGHT

            // Start monitoring mouse events for drag and release
            startRightClickMonitoring()

            // Return nil to cancel context menu - DON'T remove the interaction
            // Removing it mid-touch causes touch events to not be delivered
            return nil
        }
        #if !targetEnvironment(macCatalyst)
        // In scroll mode, suppress context menu from finger long press
        // (long press is used for text selection instead; two-finger tap shows menu via edit menu)
        // Mouse right-click (.indirectPointer) still shows the full context menu
        if isTouchScrollMode && lastContextMenuTriggerWasFinger {
            return nil
        }
        #endif

        // Suppress context menu for trackpad/mouse primary-button long-press.
        // Only right-click (secondary button) should trigger the context menu from pointer devices.
        // This prevents the "lift" animation and menu from interfering with click-and-drag text selection.
        if !lastContextMenuTriggerWasFinger && !lastPointerEventWasSecondaryClick {
            return nil
        }

        // Probe for link before building menu
        let probedLink = probeForLink(at: location)

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildContextMenu(linkURL: probedLink)
        }
    }

    /// Build the full context menu with all terminal actions
    private func buildContextMenu(linkURL: String? = nil) -> UIMenu {
        var menuItems: [UIMenuElement] = []

        // Link actions (if probed URL exists)
        if let linkURL, let url = URL(string: linkURL) {
            let openLink = UIAction(
                title: String(localized: "Open Link"),
                image: UIImage(systemName: "safari")
            ) { _ in
                UIApplication.shared.open(url)
            }
            let copyLink = UIAction(
                title: String(localized: "Copy Link"),
                image: UIImage(systemName: "link")
            ) { _ in
                UIPasteboard.general.string = linkURL
                ClipboardHistoryManager.shared.record(linkURL, source: .copyLink)
            }
            menuItems.append(UIMenu(title: "", options: .displayInline, children: [openLink, copyLink]))
        }

        // Copy (conditional - only if text is selected)
        if let surface = surface, ghostty_surface_has_selection(surface) {
            let copyAction = UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copy(nil)
            }
            menuItems.append(copyAction)
        }

        // Paste
        let pasteAction = UIAction(
            title: String(localized: "Paste"),
            image: UIImage(systemName: "doc.on.clipboard")
        ) { [weak self] _ in
            self?.paste(nil)
        }
        menuItems.append(pasteAction)

        // Clipboard manager (only when the feature is enabled)
        if ClipboardHistoryManager.shared.isEnabled {
            let clipboardManagerAction = UIAction(
                title: String(localized: "Clipboard Manager"),
                image: UIImage(systemName: "list.clipboard")
            ) { [weak self] _ in
                guard let self else { return }
                NotificationCenter.default.post(name: .toggleClipboardManager, object: self)
            }
            menuItems.append(clipboardManagerAction)
        }

        // Split actions menu
        let splitRight = UIAction(
            title: String(localized: "Split Right"),
            image: UIImage(systemName: "rectangle.righthalf.inset.filled")
        ) { [weak self] _ in
            self?.menuSplitRight(nil)
        }

        let splitLeft = UIAction(
            title: String(localized: "Split Left"),
            image: UIImage(systemName: "rectangle.leadinghalf.inset.filled")
        ) { [weak self] _ in
            self?.menuSplitLeft(nil)
        }

        let splitDown = UIAction(
            title: String(localized: "Split Down"),
            image: UIImage(systemName: "rectangle.bottomhalf.inset.filled")
        ) { [weak self] _ in
            self?.menuSplitDown(nil)
        }

        let splitUp = UIAction(
            title: String(localized: "Split Up"),
            image: UIImage(systemName: "rectangle.tophalf.inset.filled")
        ) { [weak self] _ in
            self?.menuSplitUp(nil)
        }

        let splitMenu = UIMenu(title: "", options: .displayInline, children: [
            splitRight, splitLeft, splitDown, splitUp
        ])
        menuItems.append(splitMenu)

        // tmux pane actions: only when this view renders a live pane of an
        // active control-mode gateway. Submenu data (sibling panes, other
        // windows) is read synchronously from the controller on the main
        // actor at menu-build time.
        if let binding = tmuxPaneBinding,
           let tmuxMenuController = TmuxController.controller(forOwnerSurface: binding.parentSurface),
           tmuxMenuController.isActive {
            menuItems.append(buildTmuxPaneMenu(binding: binding, controller: tmuxMenuController))
        }

        // Terminal actions menu
        let findAction = UIAction(
            title: String(localized: "Find..."),
            image: UIImage(systemName: "magnifyingglass")
        ) { [weak self] _ in
            self?.findInTerminal(UIKeyCommand())
        }

        let settingsAction = UIAction(
            title: String(localized: "Settings..."),
            image: UIImage(systemName: "gearshape")
        ) { [weak self] _ in
            self?.menuOpenSettings(nil)
        }

        let resetTerminal = UIAction(
            title: String(localized: "Reset Terminal"),
            image: UIImage(systemName: "arrow.trianglehead.2.clockwise")
        ) { [weak self] _ in
            self?.resetTerminal(nil)
        }

        let aiAgent = UIAction(
            title: String(localized: "AI Agent"),
            image: UIImage(systemName: "sparkles")
        ) { [weak self] _ in
            self?.menuToggleAIAgent(nil)
        }

        let voiceAgent = UIAction(
            title: String(localized: "Voice Agent"),
            image: UIImage(systemName: "waveform")
        ) { [weak self] _ in
            self?.menuToggleVoiceAgent(nil)
        }

        let changeTheme = UIAction(
            title: String(localized: "Change Theme"),
            image: UIImage(systemName: "paintbrush")
        ) { [weak self] _ in
            self?.menuToggleThemePicker(nil)
        }

        let terminalMenu = UIMenu(title: "", options: .displayInline, children: [findAction, settingsAction, changeTheme, resetTerminal, aiAgent, voiceAgent])
        menuItems.append(terminalMenu)

        // Tab bar visibility toggle
        let isTabBarHidden = UserDefaults.standard.bool(forKey: "tabBarHidden")
        let tabBarAction = UIAction(
            title: isTabBarHidden ? String(localized: "Show Top Tab Bar") : String(localized: "Hide Top Tab Bar"),
            image: UIImage(systemName: isTabBarHidden ? "rectangle.topthird.inset.filled" : "rectangle.topthird.inset")
        ) { [weak self] _ in
            self?.menuToggleTabBar(nil)
        }
        let tabBarMenu = UIMenu(title: "", options: .displayInline, children: [tabBarAction])
        menuItems.append(tabBarMenu)

        // Change title action
        let changeTitle = UIAction(
            title: String(localized: "Change Title..."),
            image: UIImage(systemName: "pencil.line")
        ) { [weak self] _ in
            self?.promptChangeTitle(nil)
        }

        let titleMenu = UIMenu(title: "", options: .displayInline, children: [changeTitle])
        menuItems.append(titleMenu)

        return UIMenu(title: "", children: menuItems)
    }

    /// tmux pane manipulation section of the context menu: zoom toggle, swap,
    /// break-out, move-to-window, rename, clear history. All fire-and-forget
    /// sends; the resulting %layout-change / %window-* reconcile applies the
    /// visual change on every attached client.
    private func buildTmuxPaneMenu(
        binding: TmuxPaneBinding,
        controller: TmuxController
    ) -> UIMenu {
        var items: [UIMenuElement] = []
        let paneCount = controller.paneCount(inWindow: binding.windowId)
        let siblings = controller.paneSummaries(inWindow: binding.windowId)
            .filter { $0.paneId != binding.paneId }

        // Zoom only means something with 2+ panes (zooming a sole pane is a
        // tmux no-op).
        if paneCount >= 2 {
            let isZoomed = controller.isWindowZoomed(windowId: binding.windowId)
            let zoom = UIAction(
                title: isZoomed
                    ? String(localized: "Unzoom Pane")
                    : String(localized: "Zoom Pane"),
                image: UIImage(systemName: isZoomed
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                self?.requestTmuxToggleZoom()
            }
            items.append(zoom)
        }

        if siblings.count == 1 {
            let target = siblings[0]
            let swap = UIAction(
                title: String(localized: "Swap With Other Pane"),
                image: UIImage(systemName: "rectangle.2.swap")
            ) { [weak self] _ in
                self?.requestTmuxSwapPane(withPaneId: target.paneId)
            }
            items.append(swap)
        } else if siblings.count >= 2 {
            // Label siblings by their visual (split-tree leaf) order.
            let actions = siblings.enumerated().map { offset, sibling in
                UIAction(title: "\(offset + 1): \(sibling.title)") { [weak self] _ in
                    self?.requestTmuxSwapPane(withPaneId: sibling.paneId)
                }
            }
            items.append(UIMenu(
                title: String(localized: "Swap Pane"),
                image: UIImage(systemName: "rectangle.2.swap"),
                children: actions))
        }

        if paneCount >= 2 {
            let breakOut = UIAction(
                title: String(localized: "Break Pane to New Window"),
                image: UIImage(systemName: "rectangle.badge.plus")
            ) { [weak self] _ in
                self?.requestTmuxBreakPane()
            }
            items.append(breakOut)
        }

        // Move into another window (targets that window's active pane).
        // Offered even for a sole pane: tmux closes the emptied source window.
        let otherWindows = controller.windowSummaries()
            .filter { $0.windowId != binding.windowId }
        if !otherWindows.isEmpty {
            let actions = otherWindows.map { window in
                UIAction(title: "\(window.index): \(window.title)") { [weak self] _ in
                    self?.requestTmuxMovePane(toWindowId: window.windowId)
                }
            }
            items.append(UIMenu(
                title: String(localized: "Move Pane to Window"),
                image: UIImage(systemName: "arrow.turn.up.right"),
                children: actions))
        }

        let rename = UIAction(
            title: String(localized: "Rename Pane…"),
            image: UIImage(systemName: "pencil.line")
        ) { [weak self] _ in
            self?.promptRenameTmuxPane()
        }
        items.append(rename)

        let clearHistory = UIAction(
            title: String(localized: "Clear Pane History"),
            image: UIImage(systemName: "clear")
        ) { [weak self] _ in
            self?.requestTmuxClearHistory()
        }
        items.append(clearHistory)

        return UIMenu(title: "", options: .displayInline, children: items)
    }

    /// Prompt for a tmux pane title (`select-pane -T`). An empty title
    /// restores tmux's automatic pane title.
    private func promptRenameTmuxPane() {
        let alert = UIAlertController(
            title: String(localized: "Rename Pane"),
            message: String(localized: "Leave blank to restore the automatic title."),
            preferredStyle: .alert
        )

        alert.addTextField { [weak self] textField in
            textField.placeholder = String(localized: "Pane title")
            if let self {
                let current = self.title
                textField.text = (current.isEmpty || current == "ghostty") ? nil : current
            }
        }

        let okAction = UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            guard let self else { return }
            let newTitle = alert.textFields?.first?.text ?? ""
            self.requestTmuxRenamePane(title: newTitle)
        }
        alert.addAction(okAction)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        if let rootViewController = self.window?.rootViewController {
            var presenter = rootViewController
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(alert, animated: true)
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension Ghostty.TerminalView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The brightness HUD is an interactive `UIHostingController` view (a
        // horizontal `Slider`) added as a subview of this terminal view. Without
        // this exclusion the terminal's tab-swipe pan (`appTabSwipePanGesture`)
        // also tracks the slider's horizontal drag and triggers an app-tab swipe,
        // which churns the tab/occlusion machinery into a render freeze. Let the
        // HUD own any touch that lands inside it so none of the terminal's
        // gestures fire on a slider drag.
        if let hud = brightnessHUDHost?.view,
           let touchView = touch.view,
           touchView === hud || touchView.isDescendant(of: hud) {
            return false
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if isTrackpadTabSwipeGesture(gestureRecognizer) || isTrackpadTabSwipeGesture(otherGestureRecognizer) {
            return false
        }

        #if !targetEnvironment(macCatalyst)
        // App-tab dragging owns the active one-finger horizontal gesture. If the
        // terminal scroll/capture pans also receive it, the tab slides sideways
        // while the terminal contents scroll or drag vertically underneath.
        if gestureRecognizer === appTabSwipePanGesture || otherGestureRecognizer === appTabSwipePanGesture {
            return false
        }

        // Long press selection and scroll view pan are mutually exclusive
        // Whichever recognizes first wins: quick movement → scroll; hold still 0.5s → selection
        if gestureRecognizer === selectionLongPressGesture,
           otherGestureRecognizer.view is UIScrollView { return false }

        // Capture long press and capture scroll pan are mutually exclusive
        // Quick movement → scroll; hold still 0.3s → mouse click
        if (gestureRecognizer === captureLongPressGesture && otherGestureRecognizer === captureScrollPanGesture) ||
           (gestureRecognizer === captureScrollPanGesture && otherGestureRecognizer === captureLongPressGesture) {
            return false
        }
        #endif
        // Allow simultaneous gesture recognition by default
        // Scroll handling is managed by TerminalScrollView
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let shouldBegin = shouldBeginTrackpadTabSwipeGesture(gestureRecognizer) {
            return shouldBegin
        }

        #if targetEnvironment(macCatalyst)
        // Gate the scroll-wheel forwarding gesture on the live C-side capture
        // state, not on the @Published cache. The cache can lag when tmux's
        // mouse-on sequence is processed after the alt-screen scrollbar update
        // that resyncs Swift, leaving forwarding disabled until app restart.
        if gestureRecognizer === catalystScrollGesture {
            guard let surface = surface else { return false }
            let captured = ghostty_surface_mouse_captured(surface)
            // Self-heal stale Swift state so observers (scrollView.isScrollEnabled,
            // output coalescer, scroll indicator) re-sync.
            if isMouseCaptured != captured {
                isMouseCaptured = captured
            }
            guard captured else { return false }
            // The scroll-wheel forwarding gesture and the dedicated trackpad
            // tab-swipe gesture are mutually exclusive
            // (`shouldRecognizeSimultaneouslyWith` returns false). In capture
            // mode this scroll gesture otherwise always wins, starving the tab
            // swipe — so a horizontal swipe on a mouse-captured tab can no longer
            // switch tabs. Yield this recognizer when the movement is a
            // horizontal swipe bound to app-tab navigation so the tab-swipe
            // gesture drives the switch; vertical (and non-tab-nav) movement
            // still forwards to the captured app as a mouse scroll.
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: self)
                let translation = pan.translation(in: self)
                let horizontalIntent = abs(velocity.x) > abs(velocity.y)
                    || abs(translation.x) > abs(translation.y)
                let x = abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x
                if horizontalIntent, x != 0 {
                    let direction: SwipeDirection = x < 0 ? .left : .right
                    let binding = SwipeGestureManager.shared.binding(for: direction)
                    if binding.isAppTabNavigation && !binding.isDisabled {
                        return false
                    }
                }
            }
            return true
        }
        #endif

        #if !targetEnvironment(macCatalyst)
        // Don't let terminal gesture recognizers steal touches from the dimension overlay
        // (e.g., captureLongPressGesture would cancel the Reset button tap after 0.3s)
        if let overlayView = dimensionOverlayHost?.view, overlayView.alpha > 0 {
            let point = gestureRecognizer.location(in: overlayView)
            if overlayView.bounds.contains(point) {
                return false
            }
        }

        // Only allow right-click pan gesture when we're tracking a right-click
        if gestureRecognizer === rightClickPanGesture {
            return Self.rightClickTrackingView != nil
        }

        // Handle drag gesture: allow when handles visible and touch is near a handle.
        // We check at shouldBegin time but use a generous hit area since the finger
        // may have moved slightly from the initial touch point.
        if gestureRecognizer === handleDragPanGesture {
            guard selectionHandlesVisible else { return false }
            let point = gestureRecognizer.location(in: self)
            return hitSelectionHandle(at: point) != nil
        }

        // Block all other gestures while actively dragging a handle
        if activeHandleDrag != nil {
            return false
        }

        // Block tab swipes when handles are visible and touch is near a handle
        if selectionHandlesVisible,
           (gestureRecognizer === tabSwipeLeftGesture || gestureRecognizer === tabSwipeRightGesture || gestureRecognizer === appTabSwipePanGesture) {
            let point = gestureRecognizer.location(in: self)
            if hitSelectionHandle(at: point) != nil {
                return false
            }
        }

        if gestureRecognizer === appTabSwipePanGesture,
           let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = panGesture.velocity(in: self)
            let translation = panGesture.translation(in: self)
            let horizontalIntent = abs(velocity.x) > abs(velocity.y)
                || abs(translation.x) > abs(translation.y)
            guard horizontalIntent else { return false }

            let x = abs(velocity.x) >= abs(translation.x) ? velocity.x : translation.x
            let direction: SwipeDirection = x < 0 ? .left : .right
            guard SwipeGestureManager.shared.binding(for: direction).isAppTabNavigation else {
                return false
            }

            // Preserve the window-level tab-sidebar edge pan. A left-edge
            // rightward drag should open the drawer, not switch app tabs.
            if direction == .right, panGesture.location(in: self).x <= 32 {
                return false
            }

            guard requestAppTabSwipeBegin(direction: direction, velocityX: velocity.x) else {
                activeAppTabSwipeDirection = nil
                activeAppTabSwipeAccepted = false
                return false
            }
            activeAppTabSwipeDirection = direction
            activeAppTabSwipeAccepted = true
            return true
        }

        if gestureRecognizer === selectionPanGesture && suppressSelectionUntilTouchEnd {
            return false
        }

        // Disable selection pan in capture mode (tmux, vim handle mouse themselves)
        if gestureRecognizer === selectionPanGesture && isMouseCaptured {
            return false
        }

        // Don't start scroll pan gesture if we're text selecting
        if gestureRecognizer === scrollPanGesture && isSelecting {
            return false
        }

        // Don't start scroll pan gesture if trackpad button is already pressed
        // (trackpad click+drag is handled by touchesBegan/Moved/Ended)
        if gestureRecognizer === scrollPanGesture && mousePressed {
            return false
        }

        // Compute whether scroll mode overrides capture behavior
        let scrollModeCaptureActive = isMouseCaptured && isTouchScrollMode

        // Allow capture-specific gestures when scroll mode is active during capture
        if gestureRecognizer === captureLongPressGesture {
            return scrollModeCaptureActive
        }
        if gestureRecognizer === captureScrollPanGesture,
           let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = panGesture.velocity(in: self)
            let translation = panGesture.translation(in: self)
            // Match native axis arbitration: if horizontal movement dominates,
            // leave the gesture available for the swipe bindings instead of scroll.
            let horizontalIntent = abs(velocity.x) > abs(velocity.y)
                || abs(translation.x) > abs(translation.y)
            if horizontalIntent {
                return false
            }
            return scrollModeCaptureActive
        }
        // Two-finger long press for new connection works in scroll mode even during capture
        if gestureRecognizer === twoFingerLongPressGesture && isMouseCaptured {
            return scrollModeCaptureActive
        }

        // In mouse capture mode, disable long press and tap gestures
        // (unless scroll mode overrides capture for specific gestures)
        if gestureRecognizer is UILongPressGestureRecognizer && isMouseCaptured {
            // captureLongPressGesture is handled above
            return false
        }
        if gestureRecognizer is UITapGestureRecognizer && isMouseCaptured {
            // twoFingerTapGesture is allowed in scroll mode during capture
            if gestureRecognizer === twoFingerTapGesture && scrollModeCaptureActive {
                return true
            }
            return false
        }

        // Disable scroll mode gestures in capture mode (unless scroll mode is active)
        if gestureRecognizer === selectionLongPressGesture && isMouseCaptured {
            return false
        }
        if gestureRecognizer === twoFingerTapGesture && isMouseCaptured && !scrollModeCaptureActive {
            return false
        }
        // tab swipe gestures intentionally NOT filtered here — they route through
        // SwipeGestureManager and must work in mouse-capture mode (e.g. tmux with
        // mouse on, where the user wants a swipe to send Ctrl+B+n). The swipe
        // recognizer's delaysTouchesBegan ensures a successful swipe doesn't leak
        // a partial mouse drag to the captured app.
        #endif
        return true
    }
}

// MARK: - Viewport Geometry

extension Ghostty.TerminalView {
    /// Top-origin correction for viewport row → point math: the sub-cell pad
    /// above row 0, minus the smooth-scroll shift. Shared by selection-handle
    /// placement and TextRegionTracker's band rects — keep them on the same
    /// formula or the two drift apart by fractions of a row. Lives outside
    /// the Catalyst-excluded selection-handle extension because the tracker
    /// needs it on every platform.
    func viewportPadY(cellHeight: Double) -> Double? {
        guard let surface = surface, cellHeight > 0 else { return nil }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let effectiveCellHeight = height > 0 ? height : cellHeight
        guard effectiveCellHeight > 0 else { return nil }

        var padY = y.truncatingRemainder(dividingBy: effectiveCellHeight)
        if padY < 0 {
            padY += effectiveCellHeight
        }

        if abs(padY - effectiveCellHeight) < 0.5 {
            padY = 0
        }

        // Smooth scrollback shifts rendered rows upward without changing
        // viewport row indices, so handle positioning needs the same visual
        // origin shift. smoothScrollOffset is in pixels (it is computed from the
        // pixel-valued scroll content and handed to the core as smooth_scroll_y_px),
        // but padY/cellHeight here are in points, so convert before subtracting.
        return padY - Double(smoothScrollOffset) / Double(contentScaleFactor)
    }
}

// MARK: - Selection Handles

#if !targetEnvironment(macCatalyst)
extension Ghostty.TerminalView {

    private func selectionHandleStemHeight(for cellHeight: Double) -> CGFloat {
        let height = CGFloat(cellHeight)
        return min(max(height, 18), 34)
    }

    private func selectionHandleFrame(
        for position: Ghostty.SelectionHandlePosition,
        anchor: CGPoint,
        stemHeight: CGFloat
    ) -> CGRect {
        let handleHeight = stemHeight + Ghostty.SelectionHandleView.circleDiameter
        let originY: CGFloat = if position == .start {
            anchor.y - handleHeight
        } else {
            anchor.y
        }

        return CGRect(
            x: anchor.x - Ghostty.SelectionHandleView.totalWidth / 2,
            y: originY,
            width: Ghostty.SelectionHandleView.totalWidth,
            height: handleHeight
        )
    }

    // MARK: - Coordinate Helpers

    private typealias SelectionHandleMetrics = (
        startCell: SelectionCell,
        endCell: SelectionCell,
        startPoint: CGPoint,
        endPoint: CGPoint,
        cellWidth: Double,
        cellHeight: Double,
        padX: Double,
        padY: Double,
        columns: Int,
        rows: Int,
        startVisible: Bool,
        endVisible: Bool
    )

    /// Compute selection bounds plus the geometry needed to map handle drags
    /// back into viewport cell coordinates.
    private func selectionHandleMetrics() -> SelectionHandleMetrics? {
        guard let surface = surface, ghostty_surface_has_selection(surface) else { return nil }

        // Which endpoints fall within the viewport. read_selection clamps an
        // off-screen endpoint to the viewport edge, so the core has to tell us
        // which one was clamped — that's the handle we must hide for a selection
        // taller than the viewport.
        var startVisible = true
        var endVisible = true
        _ = ghostty_surface_selection_viewport_visibility(surface, &startVisible, &endVisible)

        var textStruct = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &textStruct) else { return nil }
        defer { ghostty_surface_free_text(surface, &textStruct) }
        guard textStruct.tl_px_x.isFinite,
              textStruct.tl_px_y.isFinite,
              textStruct.tl_px_x >= 0,
              textStruct.offset_len > 0 else { return nil }

        guard let sizeInfo = surfaceSize else { return nil }
        let columns = Int(sizeInfo.columns)
        let rows = Int(sizeInfo.rows)
        guard columns > 0, rows > 0 else { return nil }

        // The core clamps an off-screen selection endpoint to as far as the
        // viewport bottom-right plus two smooth-scroll overscan rows, regardless
        // of what the Swift side currently believes about smoothScrollActive. Use
        // that generous bound for validation/clamping so a cross-viewport
        // selection (one endpoint clamped to the far edge) is never rejected — a
        // tighter bound returned nil and hid the leading handle whenever the
        // trailing endpoint sat off the bottom.
        let maxCells = columns * (rows + 2)

        let scale = Double(contentScaleFactor)
        let cellW = Double(sizeInfo.cell_width_px) / scale
        let cellH = Double(sizeInfo.cell_height_px) / scale
        guard cellW > 0, cellH > 0 else { return nil }

        let offsetStart = Int(textStruct.offset_start)
        let offsetLen = Int(textStruct.offset_len)
        guard offsetStart >= 0,
              offsetLen > 0,
              offsetStart < maxCells else { return nil }
        let startCol = offsetStart % columns
        let startRow = offsetStart / columns

        let padX = textStruct.tl_px_x - Double(startCol) * cellW
        let padY = viewportPadY(cellHeight: cellH)
            ?? (textStruct.tl_px_y - Double(startRow) * cellH)

        let startX = textStruct.tl_px_x
        let startY = Double(startRow + 1) * cellH + padY

        // Clamp (rather than reject) the end offset. When the trailing endpoint is
        // off-screen the core clamps it to the viewport edge and its handle is
        // hidden anyway, so an imprecise clamped position is harmless.
        let endOffset = min(offsetStart + offsetLen, maxCells)
        let endCol = endOffset % columns
        let endRow = endOffset / columns
        let endX = Double(endCol) * cellW + padX
        let endY = Double(endRow) * cellH + padY

        return (
            startCell: SelectionCell(col: startCol, row: startRow),
            endCell: SelectionCell(col: endCol, row: endRow),
            startPoint: CGPoint(x: startX, y: startY),
            endPoint: CGPoint(x: endX + cellW, y: endY),
            cellWidth: cellW,
            cellHeight: cellH,
            padX: padX,
            padY: padY,
            columns: columns,
            rows: rows + 2,
            startVisible: startVisible,
            endVisible: endVisible
        )
    }

    private func handlePointInWindow(_ point: CGPoint) -> CGPoint {
        guard let window = self.window else { return point }
        return convert(point, to: window)
    }

    private func magnifierCenter(
        for point: CGPoint,
        horizontalOffset: CGFloat,
        magnifier: Ghostty.SelectionMagnifierView,
        in window: UIWindow
    ) -> CGPoint {
        let windowPoint = convert(point, to: window)
        let windowFrame = window.bounds.insetBy(dx: 8, dy: 8)
        let safeFrame = window.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 8, dy: 8)
        let minimumSize = Ghostty.SelectionMagnifierView.contentSize
        let usableFrame: CGRect
        if safeFrame.width >= minimumSize.width,
           safeFrame.height >= minimumSize.height,
           !safeFrame.isNull,
           !safeFrame.isEmpty {
            usableFrame = safeFrame.intersection(windowFrame)
        } else {
            usableFrame = windowFrame
        }

        return magnifier.resolvedCenter(
            for: windowPoint,
            horizontalOffset: horizontalOffset,
            inside: usableFrame
        )
    }

    private func preferredSelectionEditMenuPoint(fallback: CGPoint) -> CGPoint {
        guard let metrics = selectionHandleMetrics() else { return fallback }

        let horizontalInset: CGFloat = 20
        let verticalInset: CGFloat = 16
        let menuGap: CGFloat = 12
        let cellHeight = CGFloat(metrics.cellHeight)

        let anchorX = (metrics.startPoint.x + metrics.endPoint.x) / 2
        let topY = min(metrics.startPoint.y, metrics.endPoint.y)
        let bottomY = max(metrics.startPoint.y, metrics.endPoint.y) + cellHeight

        var anchor = CGPoint(x: anchorX, y: topY - menuGap)
        if anchor.y < verticalInset {
            anchor.y = min(bounds.height - verticalInset, bottomY + menuGap)
        }

        anchor.x = min(max(anchor.x, horizontalInset), bounds.width - horizontalInset)
        anchor.y = min(max(anchor.y, verticalInset), bounds.height - verticalInset)
        return anchor
    }

    /// Lateral offset to apply for an explicit selection-handle drag. The
    /// `.start` handle sits at the top-left of the selection and the `.end`
    /// handle at the bottom-right, so we offset the magnifier away from each
    /// to keep the finger from obscuring the magnified content.
    private static func handleMagnifierOffset(for handle: Ghostty.SelectionHandlePosition) -> CGFloat {
        (handle == .start ? 1 : -1) * Ghostty.SelectionMagnifierView.horizontalOffset
    }

    private func magnifierCellSize() -> CGSize? {
        guard let sizeInfo = surfaceSize else { return nil }
        let scale = Double(contentScaleFactor)
        guard scale > 0 else { return nil }
        let width = Double(sizeInfo.cell_width_px) / scale
        let height = Double(sizeInfo.cell_height_px) / scale
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private var prefersNativeSelectionLoupe: Bool {
        #if os(iOS)
        UserPreferences.useNativeSelectionLoupe
        #else
        false
        #endif
    }

    /// Press-and-drag (capture) mode: the native loupe follows the finger when
    /// enabled; otherwise the custom loupe uses its centered, zero-offset path.
    func showCaptureMagnifier(at point: CGPoint) {
        if prefersNativeSelectionLoupe,
           presentNativeSelectionLoupe(at: point, widget: nil) {
            selectionMagnifierPoint = point
            return
        }
        showCustomSelectionMagnifier(at: point, horizontalOffset: 0)
    }

    func updateCaptureMagnifier(at point: CGPoint) {
        if let loupe = selectionLoupe {
            selectionMagnifierPoint = point
            loupe.move(to: point, caretRect: .null, tracksCaret: false)
        } else {
            updateCustomSelectionMagnifier(at: point, horizontalOffset: 0)
        }
    }

    func showSelectionMagnifier(at point: CGPoint, for handle: Ghostty.SelectionHandlePosition) {
        if prefersNativeSelectionLoupe {
            let widget = handle == .start ? selectionStartHandle : selectionEndHandle
            if presentNativeSelectionLoupe(at: point, widget: widget) {
                selectionMagnifierPoint = point
                syncNativeHandleDragLoupe(touchPoint: point)
                return
            }
        }
        showCustomSelectionMagnifier(at: point, horizontalOffset: Self.handleMagnifierOffset(for: handle))
    }

    private func showCustomSelectionMagnifier(at point: CGPoint, horizontalOffset: CGFloat) {
        guard let window = self.window else { return }

        let magnifier = selectionMagnifierView ?? Ghostty.SelectionMagnifierView()
        if selectionMagnifierView == nil {
            window.addSubview(magnifier)
            selectionMagnifierView = magnifier
        }

        window.bringSubviewToFront(magnifier)
        magnifier.resetPlacement()
        magnifier.center = magnifierCenter(
            for: point,
            horizontalOffset: horizontalOffset,
            magnifier: magnifier,
            in: window
        )
        magnifier.requestSnapshot(
            from: self,
            around: point,
            cellSize: magnifierCellSize(),
            immediately: true
        )
        selectionMagnifierPoint = point
        magnifier.present(animated: true)
    }

    func updateSelectionMagnifier(at point: CGPoint, for handle: Ghostty.SelectionHandlePosition) {
        if selectionLoupe != nil {
            selectionMagnifierPoint = point
            syncNativeHandleDragLoupe(touchPoint: point)
        } else {
            updateCustomSelectionMagnifier(at: point, horizontalOffset: Self.handleMagnifierOffset(for: handle))
        }
    }

    private func updateCustomSelectionMagnifier(at point: CGPoint, horizontalOffset: CGFloat) {
        guard let magnifier = selectionMagnifierView, let window = self.window else { return }
        magnifier.center = magnifierCenter(
            for: point,
            horizontalOffset: horizontalOffset,
            magnifier: magnifier,
            in: window
        )
        magnifier.requestSnapshot(from: self, around: point, cellSize: magnifierCellSize())
        selectionMagnifierPoint = point
    }

    func hideSelectionMagnifier(animated: Bool = true) {
        selectionMagnifierPoint = nil
        selectionLoupe?.invalidate()
        selectionLoupe = nil

        guard let magnifier = selectionMagnifierView else { return }
        magnifier.dismiss(animated: animated) { [weak self, weak magnifier] in
            guard let magnifier else { return }
            if self?.selectionMagnifierView === magnifier {
                self?.selectionMagnifierView = nil
            }
            magnifier.removeFromSuperview()
        }
    }

    @discardableResult
    private func presentNativeSelectionLoupe(at point: CGPoint, widget: UIView?) -> Bool {
        if let loupe = selectionLoupe {
            loupe.move(to: point, caretRect: .null, tracksCaret: false)
            return true
        }

        selectionLoupe = Ghostty.SelectionLoupe.begin(
            at: point,
            in: self,
            fromSelectionWidgetView: widget
        )
        return selectionLoupe != nil
    }

    private func syncNativeHandleDragLoupe(touchPoint: CGPoint) {
        guard selectionLoupe != nil else { return }
        syncNativeHandleDragLoupe(touchPoint: touchPoint, metrics: selectionHandleMetrics())
    }

    /// Re-target the native loupe at the endpoint nearest the finger. The core
    /// can reorder endpoints when the dragged handle crosses its fixed anchor.
    private func syncNativeHandleDragLoupe(
        touchPoint: CGPoint,
        metrics: SelectionHandleMetrics?
    ) {
        guard let loupe = selectionLoupe else { return }
        guard let metrics else {
            loupe.move(to: touchPoint, caretRect: .null, tracksCaret: false)
            return
        }

        let cellHeight = CGFloat(metrics.cellHeight)
        let startRect = CGRect(
            x: metrics.startPoint.x,
            y: metrics.startPoint.y - cellHeight,
            width: 2,
            height: cellHeight
        )
        let endRect = CGRect(
            x: metrics.endPoint.x,
            y: metrics.endPoint.y,
            width: 2,
            height: cellHeight
        )
        let startDistance = hypot(
            touchPoint.x - startRect.midX,
            touchPoint.y - startRect.midY
        )
        let endDistance = hypot(
            touchPoint.x - endRect.midX,
            touchPoint.y - endRect.midY
        )
        let (caretRect, visible) = startDistance <= endDistance
            ? (startRect, metrics.startVisible)
            : (endRect, metrics.endVisible)

        if visible {
            loupe.move(to: touchPoint, caretRect: caretRect, tracksCaret: true)
        } else {
            loupe.move(to: touchPoint, caretRect: .null, tracksCaret: false)
        }
    }

    /// Approximate viewport cell under a finger point, derived only from the
    /// cell size. Used solely to drive haptic feedback on cell-boundary
    /// crossings during a handle drag — it intentionally ignores scroll offset
    /// and padding because the actual selection is computed by the core, not
    /// here.
    private func approxDragCell(at point: CGPoint) -> (col: Int, row: Int)? {
        guard let sizeInfo = surfaceSize else { return nil }
        let scale = Double(contentScaleFactor)
        let cellW = Double(sizeInfo.cell_width_px) / scale
        let cellH = Double(sizeInfo.cell_height_px) / scale
        guard cellW > 0, cellH > 0 else { return nil }
        return (col: Int(floor(point.x / cellW)), row: Int(floor(point.y / cellH)))
    }

    /// Check if a point (in TerminalView coordinates) hits a handle. Returns which one.
    func hitSelectionHandle(at point: CGPoint) -> Ghostty.SelectionHandlePosition? {
        guard selectionHandlesVisible, let window = self.window else { return nil }
        let windowPoint = convert(point, to: window)
        let hitInset: CGFloat = -30 // expand 30pt in each direction for easier handle targeting
        var candidates: [(position: Ghostty.SelectionHandlePosition, distanceSquared: CGFloat)] = []

        if let h = selectionStartHandle, !h.isHidden,
           h.frame.insetBy(dx: hitInset, dy: hitInset).contains(windowPoint) {
            let dx = windowPoint.x - h.frame.midX
            let dy = windowPoint.y - h.frame.midY
            candidates.append((position: .start, distanceSquared: dx * dx + dy * dy))
        }

        if let h = selectionEndHandle, !h.isHidden,
           h.frame.insetBy(dx: hitInset, dy: hitInset).contains(windowPoint) {
            let dx = windowPoint.x - h.frame.midX
            let dy = windowPoint.y - h.frame.midY
            candidates.append((position: .end, distanceSquared: dx * dx + dy * dy))
        }

        return candidates.min { $0.distanceSquared < $1.distanceSquared }?.position
    }

    private func makeHandleDragGesture() -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHandleDragPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        return pan
    }

    // MARK: - Handle Drag Pan

    @objc func handleHandleDragPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface = surface else { return }
        let location = gesture.location(in: self)
        let mods = Ghostty.Input.Mods.none.cMods

        // All of the drag's core calls go through ghosttyAPIQueue in FIFO order.
        // ghostty_surface_mouse_button can block on the termio mailbox, so it has
        // to run off the main thread; if begin/mouse_pos ran inline on main while
        // the release ran async, a prior drag's release could land *after* the
        // next handle's begin and leave the core's click state stale (the second
        // handle would freeze and the selection appear lost). Serializing the
        // whole lifecycle keeps release-before-begin ordering across drags.

        switch gesture.state {
        case .began:
            let directHandle = (gesture.view as? Ghostty.SelectionHandleView)?.position
            guard let which = directHandle ?? hitSelectionHandle(at: location) else { return }
            activeHandleDrag = which
            lastDragCell = approxDragCell(at: location)

            #if !os(visionOS)
            selectionFeedbackGenerator.prepare()
            #endif

            showSelectionMagnifier(at: location, for: which)

            // Anchor a native selection drag at the opposite (fixed) endpoint of
            // the current selection, then snap the dragged endpoint to the finger.
            // viewToPixelCoordinates is the identity (the surface knows its content
            // scale), matching every other mouse_pos call site.
            let pixelPoint = viewToPixelCoordinates(location)
            let draggingStart = which == .start
            Self.ghosttyAPIQueue.async {
                _ = ghostty_surface_selection_handle_drag_begin(surface, draggingStart)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeHandleDrag == which else { return }
                    self.updateSelectionHandlePositions()
                }
            }

        case .changed:
            guard let which = activeHandleDrag else { return }

            if let cell = approxDragCell(at: location) {
                if let last = lastDragCell, last.col != cell.col || last.row != cell.row {
                    #if !os(visionOS)
                    selectionFeedbackGenerator.selectionChanged()
                    #endif
                }
                lastDragCell = cell
            }

            // The magnifier mirrors the live terminal rendering, so update it
            // immediately; the render-driven layout hook keeps refreshing it
            // during a held-finger auto-scroll.
            let magnifierPoint = selectionLoupe == nil
                ? CGPoint(
                    x: max(0, min(location.x, bounds.width)),
                    y: max(0, min(location.y, bounds.height))
                )
                : location
            updateSelectionMagnifier(at: magnifierPoint, for: which)

            // Pass the unclamped finger location so the core's edge test can
            // start auto-scrolling when the finger reaches the top/bottom of the
            // viewport and extend the selection into scrollback.
            let pixelPoint = viewToPixelCoordinates(location)
            Self.ghosttyAPIQueue.async {
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeHandleDrag == which else { return }
                    self.noteSelectionScrollIndicatorActivity()
                    self.updateSelectionHandlePositions()
                }
            }

        case .ended, .cancelled:
            activeHandleDrag = nil
            lastDragCell = nil

            hideSelectionMagnifier()

            // End the native drag with a normal left-button release (queued after
            // the final position), which stops any active auto-scroll.
            let endLocation = location
            let pixelPoint = viewToPixelCoordinates(location)
            Self.ghosttyAPIQueue.async {
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
                ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
                let hasSelection = ghostty_surface_has_selection(surface)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if hasSelection {
                        self.updateSelectionHandlePositions()
                        self.presentTransientEditMenu(at: endLocation)
                    } else {
                        self.hideSelectionHandles()
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Show / Hide / Update

    func removeSelectionHandleViewsFromWindow() {
        guard let window else { return }
        removeSelectionHandleViews(in: window)
        selectionStartHandle = nil
        selectionEndHandle = nil
        selectionHandlesVisible = false
    }

    private func removeSelectionHandleViews(in view: UIView) {
        for subview in view.subviews {
            if subview is Ghostty.SelectionHandleView {
                subview.removeFromSuperview()
            } else {
                removeSelectionHandleViews(in: subview)
            }
        }
    }

    func showSelectionHandles(triggerFeedback: Bool = false) {
        guard selectionHandlesCanBePresented() else {
            hideSelectionHandles(animated: false)
            return
        }
        guard let metrics = selectionHandleMetrics() else { return }
        guard let window = self.window else { return }
        let stemHeight = selectionHandleStemHeight(for: metrics.cellHeight)

        removeSelectionHandleViewsFromWindow()

        let startHandle = Ghostty.SelectionHandleView(position: .start)
        startHandle.stemHeight = stemHeight
        startHandle.addGestureRecognizer(makeHandleDragGesture())
        window.addSubview(startHandle)
        selectionStartHandle = startHandle

        let endHandle = Ghostty.SelectionHandleView(position: .end)
        endHandle.stemHeight = stemHeight
        endHandle.addGestureRecognizer(makeHandleDragGesture())
        window.addSubview(endHandle)
        selectionEndHandle = endHandle

        let startInWindow = handlePointInWindow(metrics.startPoint)
        let endInWindow = handlePointInWindow(metrics.endPoint)

        startHandle.frame = selectionHandleFrame(for: .start, anchor: startInWindow, stemHeight: stemHeight)
        endHandle.frame = selectionHandleFrame(for: .end, anchor: endInWindow, stemHeight: stemHeight)

        // For a selection taller than the viewport, only show the handle whose
        // endpoint is currently on screen.
        applyHandleVisibility(startVisible: metrics.startVisible, endVisible: metrics.endVisible)

        if !selectionHandlesVisible {
            startHandle.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            startHandle.alpha = 0
            endHandle.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            endHandle.alpha = 0

            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                startHandle.transform = .identity
                startHandle.alpha = 1
                endHandle.transform = .identity
                endHandle.alpha = 1
            }

            #if !os(visionOS)
            if triggerFeedback {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
            #endif
        }

        selectionHandlesVisible = true
    }

    func hideSelectionHandles(animated: Bool = true) {
        let startHandle = selectionStartHandle
        let endHandle = selectionEndHandle

        let cleanup = { [weak self] in
            startHandle?.removeFromSuperview()
            endHandle?.removeFromSuperview()
            self?.selectionStartHandle = nil
            self?.selectionEndHandle = nil
            self?.selectionHandlesVisible = false
            self?.lastDragCell = nil
            self?.activeHandleDrag = nil
            // The magnifier loupe is intentionally NOT torn down here. Its
            // lifecycle is owned by the gesture/touch handlers that show it
            // (capture long-press, selection long-press, handle drag, finger
            // drag), each of which hides it on its terminal state. Disposing it
            // here would kill the capture-mode loupe, because the per-frame
            // syncSelectionHandleVisibility() calls hideSelectionHandles() while
            // no native selection exists.
        }

        guard selectionHandlesVisible else {
            cleanup()
            return
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                startHandle?.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                startHandle?.alpha = 0
                endHandle?.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                endHandle?.alpha = 0
            }, completion: { _ in
                cleanup()
            })
        } else {
            cleanup()
        }
    }

    func updateSelectionHandlePositions() {
        guard selectionHandlesVisible else { return }

        // While a handle is being dragged, the selection can extend past the
        // viewport via auto-scroll. The fixed endpoint then sits off-screen and
        // the core clamps its reported geometry to the viewport edge — that is
        // expected, so never tear the handles down mid-drag (doing so removes the
        // handle view the pan gesture is attached to and kills the drag).
        let dragging = activeHandleDrag != nil

        guard selectionHandlesCanBePresented() else {
            if !dragging { hideSelectionHandles(animated: false) }
            return
        }

        guard let metrics = selectionHandleMetrics() else {
            if dragging, let point = selectionMagnifierPoint, let handle = activeHandleDrag {
                if selectionLoupe != nil {
                    syncNativeHandleDragLoupe(touchPoint: point, metrics: nil)
                } else {
                    updateCustomSelectionMagnifier(
                        at: point,
                        horizontalOffset: Self.handleMagnifierOffset(for: handle)
                    )
                }
            } else if !dragging {
                hideSelectionHandles()
            }
            return
        }
        if dragging, let point = selectionMagnifierPoint, let handle = activeHandleDrag {
            if selectionLoupe != nil {
                syncNativeHandleDragLoupe(touchPoint: point, metrics: metrics)
            } else {
                updateCustomSelectionMagnifier(
                    at: point,
                    horizontalOffset: Self.handleMagnifierOffset(for: handle)
                )
            }
        }
        // Tear down only when neither endpoint is on screen (and not mid-drag).
        // A cross-viewport selection keeps one endpoint visible; we position both
        // but hide the one whose endpoint scrolled off (see applyHandleVisibility).
        guard dragging || metrics.startVisible || metrics.endVisible else {
            hideSelectionHandles(animated: false)
            return
        }

        let stemHeight = selectionHandleStemHeight(for: metrics.cellHeight)
        let startInWindow = handlePointInWindow(metrics.startPoint)
        let endInWindow = handlePointInWindow(metrics.endPoint)

        UIView.animate(withDuration: 0.05, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            self.selectionStartHandle?.stemHeight = stemHeight
            self.selectionStartHandle?.frame = self.selectionHandleFrame(
                for: .start,
                anchor: startInWindow,
                stemHeight: stemHeight
            )
            self.selectionEndHandle?.stemHeight = stemHeight
            self.selectionEndHandle?.frame = self.selectionHandleFrame(
                for: .end,
                anchor: endInWindow,
                stemHeight: stemHeight
            )
        }
        applyHandleVisibility(startVisible: metrics.startVisible, endVisible: metrics.endVisible)
    }

    /// Show only the handle(s) whose endpoint is within the viewport. For a
    /// selection taller than the viewport the off-screen endpoint's handle is
    /// hidden but kept in the hierarchy so an in-flight drag (and the other
    /// handle's gesture) survives.
    private func applyHandleVisibility(startVisible: Bool, endVisible: Bool) {
        selectionStartHandle?.isHidden = !startVisible
        selectionEndHandle?.isHidden = !endVisible
    }

    /// Check if a point (in TerminalView coordinates) is inside either selection handle.
    func isPointOnSelectionHandle(_ point: CGPoint) -> Bool {
        return hitSelectionHandle(at: point) != nil
    }

    func syncSelectionHandleVisibility(forActiveSurface isActiveSurface: Bool = true) {
        guard isActiveSurface else {
            hideSelectionHandles(animated: false)
            return
        }

        guard activeHandleDrag == nil else { return }

        guard let metrics = selectionHandleMetrics() else {
            hideSelectionHandles(animated: false)
            if let surface, ghostty_surface_has_selection(surface) {
                return
            }
            selectionWasTouchInitiated = false
            return
        }

        guard metrics.startVisible || metrics.endVisible else {
            hideSelectionHandles(animated: false)
            if let surface, ghostty_surface_has_selection(surface) {
                return
            }
            selectionWasTouchInitiated = false
            return
        }

        if !selectionHandlesVisible && selectionWasTouchInitiated {
            showSelectionHandles()
        } else if selectionHandlesVisible {
            // Already shown; refresh which handle is visible as the selection's
            // endpoints scroll in and out of the viewport.
            applyHandleVisibility(startVisible: metrics.startVisible, endVisible: metrics.endVisible)
        }
    }
}
#endif

// MARK: - Data Extensions

extension Data {
    /// Returns a hex string representation for debugging (e.g., "1b 5b 36 6e")
    var hexDescription: String {
        return self.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - Right-Click Handling for Mouse Capture Mode

extension Ghostty.TerminalView {
    /// Display link for polling mouse state during right-click-drag
    private static var rightClickDisplayLink: CADisplayLink?
    /// Initial click position in view coordinates
    private static var rightClickStartPosition: CGPoint = .zero
    /// Initial CGEvent screen position (for calculating delta)
    private static var rightClickStartScreenPosition: CGPoint = .zero
    /// The terminal view currently tracking right-click
    private static weak var rightClickTrackingView: Ghostty.TerminalView?

    /// Start monitoring mouse for right-click drag and release
    /// Called when UIContextMenuInteraction intercepts a right-click in mouse capture mode
    func startRightClickMonitoring() {
        // Remove any existing monitor
        stopRightClickMonitoring()

        Self.rightClickTrackingView = self

        // Use CADisplayLink to poll for mouse state
        // On Mac Catalyst: polls CGEvent for position and button state
        // On iPad: polls for position updates, but release is detected via touchesEnded
        let displayLink = CADisplayLink(target: self, selector: #selector(pollRightClickState))
        displayLink.add(to: .main, forMode: .common)
        Self.rightClickDisplayLink = displayLink
    }

    /// Cached Catalyst scale factor (screen pixels per view point)
    private static var catalystScaleFactor: CGFloat = 0.77  // Default, will be detected

    @objc private func pollRightClickState() {
        guard mousePressed else {
            stopRightClickMonitoring()
            return
        }

        // Get current mouse position and button state
        var currentPosition = Self.rightClickStartPosition
        var isButtonPressed = false

        #if targetEnvironment(macCatalyst)
        // Track movement via CGEvent delta
        if let cgEvent = CGEvent(source: nil), let surface = surface {
            let screenLocation = cgEvent.location

            // Calculate position delta from initial screen position
            // Mac Catalyst scales the window content, so screen deltas need to be
            // divided by the scale factor to get view deltas
            let screenDeltaX = screenLocation.x - Self.rightClickStartScreenPosition.x
            let screenDeltaY = screenLocation.y - Self.rightClickStartScreenPosition.y

            // Convert screen delta to view delta using Catalyst scale factor
            let viewDeltaX = screenDeltaX / Self.catalystScaleFactor
            let viewDeltaY = screenDeltaY / Self.catalystScaleFactor

            currentPosition = CGPoint(
                x: Self.rightClickStartPosition.x + viewDeltaX,
                y: Self.rightClickStartPosition.y + viewDeltaY
            )

            // Send position update
            let mods = currentMouseMods()
            let pixelPoint = viewToPixelCoordinates(currentPosition)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
        }
        isButtonPressed = CGEventSource.buttonState(.combinedSessionState, button: .right)

        // Check if button was released
        if !isButtonPressed {
            if let surface = surface {
                let mods = currentMouseMods()
                let pixelPoint = viewToPixelCoordinates(currentPosition)
                ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, mods)
                sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
            }
            mousePressed = false
            stopRightClickMonitoring()
        }
        #else
        // On iPad, don't poll for button release - touchesEnded will handle it
        // GCMouse.current is often nil for trackpad, and button state is unreliable
        // The display link keeps running but we rely on touch events for release
        #endif
    }

    /// Stop monitoring mouse events
    func stopRightClickMonitoring() {
        Self.rightClickDisplayLink?.invalidate()
        Self.rightClickDisplayLink = nil
        Self.rightClickTrackingView = nil
    }

    /// Set the starting position for right-click tracking
    func setRightClickStartPosition(_ position: CGPoint) {
        Self.rightClickStartPosition = position

        #if targetEnvironment(macCatalyst)
        // Capture the initial CGEvent screen position for delta calculation
        if let cgEvent = CGEvent(source: nil) {
            Self.rightClickStartScreenPosition = cgEvent.location
        }

        // Try to detect Catalyst scale factor from window
        detectCatalystScaleFactor()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Detect the Mac Catalyst scale factor by comparing window sizes
    private func detectCatalystScaleFactor() {
        guard let window = self.window else { return }

        // Try to get NSWindow via runtime to compare frame sizes
        // The ratio of NSWindow frame to UIWindow bounds gives us the scale
        if let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
           let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
           let windows = sharedApp.value(forKey: "windows") as? [NSObject],
           let nsWindow = windows.first {

            // Get NSWindow frame (in screen points)
            if let frameValue = nsWindow.value(forKey: "frame") as? NSValue {
                let nsFrame = frameValue.cgRectValue

                // Compare to UIWindow bounds
                let uiFrame = window.bounds

                // The scale is the ratio of NSWindow size to UIWindow size
                if uiFrame.width > 0 && nsFrame.width > 0 {
                    let detectedScale = nsFrame.width / uiFrame.width
                    // Sanity check - Catalyst scale is typically 0.7-0.9
                    if detectedScale > 0.5 && detectedScale < 1.5 {
                        Self.catalystScaleFactor = detectedScale
                    }
                }
            }
        }
    }
    #endif
}

// MARK: - Dimension Overlay SwiftUI View

/// Liquid glass overlay showing terminal dimensions (cols × rows) during pinch-to-zoom.
/// Uses `.glassEffect` on iOS 26+, falls back to `.ultraThinMaterial` on earlier versions.
#if !targetEnvironment(macCatalyst)
struct DimensionOverlayView: View {
    let text: String
    var onReset: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .dimensionOverlayBackground()

            if let onReset {
                Button("Reset", action: onReset)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .dimensionOverlayBackground()
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func dimensionOverlayBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        #if os(visionOS)
        self
            .background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        #endif
    }
}

// MARK: - Input Mode Overlay SwiftUI View

/// Liquid glass overlay showing the active input method name when switching via Globe key.
/// Uses the same glass effect pattern as DimensionOverlayView.
struct InputModeOverlayView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .dimensionOverlayBackground()
    }
}
#endif

// MARK: - Apple Pencil Interactions

#if !targetEnvironment(macCatalyst) && !os(visionOS)
extension Ghostty.TerminalView {
    /// How recently the pencil must have touched this view for a barrel tap to
    /// act when hover isn't available (Pencil 2 on non-hover-capable iPads).
    private static let pencilBarrelTapRecency: TimeInterval = 5
}

extension Ghostty.TerminalView: UIPencilInteractionDelegate {
    public func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        guard UIPencilInteraction.preferredTapAction != .ignore, !mousePressed else { return }

        let point: CGPoint
        if let hoverLocation = tap.hoverPose?.location {
            // Hover-capable hardware reports the pencil's position in this
            // view's coordinates; outside our bounds means another pane owns
            // the tap.
            guard bounds.contains(hoverLocation) else { return }
            point = hoverLocation
        } else {
            // No hover data: only the focused, most recently pencil-touched
            // view responds, and only near the touch in time and space.
            let sinceContact = ProcessInfo.processInfo.systemUptime - lastPencilLocationTimestamp
            guard Self.lastPencilContactView === self,
                  isLogicallyFocused,
                  sinceContact <= Self.pencilBarrelTapRecency,
                  let lastPoint = lastPencilLocation,
                  bounds.contains(lastPoint)
            else { return }
            point = lastPoint
        }

        if let surface = surface, ghostty_surface_mouse_captured(surface) {
            // Instantaneous right press/release; handleMouseDown's right-click
            // path would arm the drag-monitoring machinery instead.
            let pixelPoint = viewToPixelCoordinates(point)
            ghostty_surface_mouse_pos(surface, pixelPoint.x, pixelPoint.y, Ghostty.Input.Mods.none.cMods)
            sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
            sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
        } else {
            NotificationCenter.default.post(name: .focusSplit, object: self)
            presentTransientEditMenu(at: point, fullContextMenu: true)
        }
    }
}

extension Ghostty.TerminalView: UIScribbleInteractionDelegate {
    public func scribbleInteraction(
        _ interaction: UIScribbleInteraction,
        shouldBeginAt location: CGPoint
    ) -> Bool {
        // Scribble assumes it can read back and edit what it wrote, which
        // double-emits words into a write-only terminal. Handwriting stays
        // off; the pencil is pointer/selection input here.
        false
    }
}
#endif
