// Copyright (c) 2026 Kit Knox / Rootshell LLC
import UIKit

#if !targetEnvironment(macCatalyst)
extension Ghostty.TerminalView {
    func handleEndpointSelectionGesture(_ gesture: UIGestureRecognizer) {
        guard let state = herdrEndpointPane, !isMouseCaptured else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard !suppressSelectionUntilTouchEnd else { return }
            isSelecting = true
            selectionWasTouchInitiated = true
            NotificationCenter.default.post(name: .focusSplit, object: self)
            state.beginSelection(at: location)
            showCaptureMagnifier(at: location)
            triggerHapticFeedback()
            reloadInputViews()
        case .changed:
            guard isSelecting else { return }
            if suppressSelectionUntilTouchEnd {
                state.clearSelection()
                isSelecting = false
                hideSelectionMagnifier()
                return
            }
            state.drag(to: location)
            updateCaptureMagnifier(at: location)
        case .ended, .cancelled, .failed:
            guard isSelecting else { return }
            state.endDrag()
            isSelecting = false
            hideSelectionMagnifier()
            reloadInputViews()
            if gesture.state == .ended, state.hasSelection {
                selectionWasTouchInitiated = true
                if SettingsStore.shared.value(Settings.Selection.copyOnSelect) { state.copy() }
                presentTransientEditMenu(at: location)
                syncSelectionHandlesForSurfaceActivity()
            }
        default: break
        }
    }

    func handleEndpointHandleGesture(_ gesture: UIPanGestureRecognizer) {
        guard let state = herdrEndpointPane else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let which = (gesture.view as? Ghostty.SelectionHandleView)?.position ?? hitSelectionHandle(at: location) else { return }
            activeHandleDrag = which
            state.beginHandle(start: which == .start, at: location)
            showSelectionMagnifier(at: location, for: which)
        case .changed:
            guard let which = activeHandleDrag else { return }
            state.drag(to: location)
            updateSelectionMagnifier(at: location, for: which)
        case .ended, .cancelled, .failed:
            state.endDrag()
            activeHandleDrag = nil
            lastDragCell = nil
            hideSelectionMagnifier()
            if gesture.state == .ended, state.hasSelection {
                if SettingsStore.shared.value(Settings.Selection.copyOnSelect) { state.copy() }
                presentTransientEditMenu(at: location)
            }
            syncSelectionHandlesForSurfaceActivity()
        default: break
        }
    }
}
#endif
