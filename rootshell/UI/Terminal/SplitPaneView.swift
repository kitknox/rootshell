//
//  SplitPaneView.swift
//  rootshell
//
//  Base class for any view that can occupy a leaf of a tab's split tree.
//

import UIKit

/// Base class for any view that can occupy a leaf of a tab's split tree.
/// Concrete panes: `Ghostty.TerminalView` (terminal); future non-terminal
/// panes sit beside terminals in the same tree.
///
/// This is a base class rather than a protocol because `SplitTree` requires
/// `ViewType: UIView & Identifiable`, which an existential cannot satisfy.
@MainActor
class SplitPaneView: UIView, Identifiable {

    /// Unique, stable identity for this pane (survives restore).
    nonisolated let uuid: UUID

    nonisolated var id: UUID { uuid }

    /// Pane-scoped title and coding-agent presentation. This is deliberately
    /// separate from `TabModel`: a split tab can contain several independent
    /// titles and agents.
    let presentation: PanePresentationState

    /// ID of the tab containing this pane (set by MainView when added to a tab).
    var containingTabID: UUID?

    /// Whether this pane is the logically focused leaf in its split tree.
    /// Prevents background tabs/splits from stealing focus when their session
    /// becomes ready.
    var isLogicallyFocused: Bool = false

    /// Set while the pane is checked out of normal split layout for an
    /// in-window full-screen takeover. `SplitTreeHostingView` skips laying it
    /// out (but retains its container) so exit re-attaches via normal layout.
    var isDetachedForFullScreen: Bool = false

    init(uuid: UUID = UUID(), frame: CGRect = .zero) {
        self.uuid = uuid
        self.presentation = PanePresentationState(paneID: uuid)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// Subclass deinit isolation must match the base class; TerminalView's
    /// deinit is nonisolated (frees the surface off the main actor).
    nonisolated deinit {}

    // MARK: - Pane hooks (overridden by concrete panes)

    /// Focus gain/loss for this pane. Returns `true` only when
    /// `focused == true` and first responder was acquired synchronously
    /// (meaning UIKit already auto-resigned the previous responder, so the
    /// caller may pass `skipResign: true` when unfocusing the old pane).
    @discardableResult
    func focusDidChange(_ focused: Bool, skipResign: Bool = false) -> Bool { false }

    /// Visibility (occlusion) state: `false` pauses rendering/session work
    /// for panes in hidden tabs.
    func setOcclusion(_ visible: Bool) {}

    /// Hard renderer stop for the background/secure-snapshot pause sweeps.
    /// Unlike `setOcclusion(false)` this must guarantee no further frame is
    /// presented once it returns; presenting during the locked-screen secure
    /// snapshot gets the process killed (FrontBoard 0x2BAD45EC). Returns
    /// whether the pane's renderer acknowledged the drain in time.
    @discardableResult
    func pauseRendererForBackground(
        timeoutNanoseconds: UInt64 = 200_000_000
    ) -> Bool { true }

    /// Per-window keyboard-ownership gate: while an overlay (sidebar, sheet)
    /// owns the keyboard, the pane must refuse first responder.
    func setOverlayOwnsKeyboard(_ owns: Bool) {}

    /// Window active/inactive state pushed by MainView.
    func setWindowActive(_ active: Bool) {}

    /// Re-home the pane to another window (tab transfer).
    func retargetWindow(to windowId: String) {}

    /// Prepare a live pane for insertion beneath a view controller. Panes that
    /// own child view controllers can re-home them here before UIKit validates
    /// the destination hierarchy during `insertSubview`. Return `false` to
    /// defer attachment until the destination controller is available.
    func prepareForAttachment(to parentViewController: UIViewController?) -> Bool { true }

    /// Teardown funnel for non-terminal panes when the pane is closed.
    /// Terminals keep their richer `cleanup(reason:)` API; close paths call
    /// that directly via `asTerminal` and fall back to this for other panes.
    func prepareForClose() {}

    /// Bottom inset the pane's keyboard toolbar reserves in toolbar-only mode.
    var reservedKeyboardToolbarHeightAtBottom: CGFloat { 0 }

    /// Visible keyboard toolbar in screen coordinates, when this pane owns it.
    /// Used with the reported keyboard frame to reserve the complete input area.
    var keyboardAccessoryFrameInScreen: CGRect? { nil }

    /// Authoritative destination frame for a docked custom keyboard. Its
    /// self-sizing height can change without a system keyboard notification.
    var dockedTouchKeyboardFrameInScreen: CGRect? { nil }

    /// Live interaction state for bottom-edge system-gesture arbitration.
    /// Unlike the reserved height, this must never remain latched after focus
    /// leaves the pane.
    var defersBottomSystemGestureForKeyboardToolbar: Bool { false }
}

/// A hardware key as seen by an in-window overlay (tab exposé), normalized
/// from either a `UIKey` (pressesBegan) or a `UIKeyCommand` (dedicated handlers).
struct OverlayKeyEvent {
    let keyCode: UIKeyboardHIDUsage
    let modifiers: UIKeyModifierFlags
    let characters: String

    init(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, characters: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }

    init(_ key: UIKey) {
        self.init(keyCode: key.keyCode, modifiers: key.modifierFlags, characters: key.characters)
    }

    /// Navigation keys an overlay may own, from a UIKeyCommand (dedicated
    /// handlers, keybind commands, first-responder fallback). nil for anything
    /// else so ordinary shortcuts never reach the overlay.
    init?(keyCommand: UIKeyCommand) {
        guard let input = keyCommand.input else { return nil }
        let keyCode: UIKeyboardHIDUsage
        switch input {
        case UIKeyCommand.inputUpArrow: keyCode = .keyboardUpArrow
        case UIKeyCommand.inputDownArrow: keyCode = .keyboardDownArrow
        case UIKeyCommand.inputLeftArrow: keyCode = .keyboardLeftArrow
        case UIKeyCommand.inputRightArrow: keyCode = .keyboardRightArrow
        case UIKeyCommand.inputEscape: keyCode = .keyboardEscape
        case UIKeyCommand.inputHome: keyCode = .keyboardHome
        case UIKeyCommand.inputEnd: keyCode = .keyboardEnd
        case "\r", "\n": keyCode = .keyboardReturnOrEnter
        case "\t": keyCode = .keyboardTab
        case " ": keyCode = .keyboardSpacebar
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            // Digits are matched by `characters`.
            keyCode = .keyboardErrorUndefined
        default:
            return nil
        }
        self.init(keyCode: keyCode, modifiers: keyCommand.modifierFlags, characters: input)
    }

    var isModifierOnly: Bool {
        switch keyCode {
        case .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
             .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }
}

// MARK: - Terminal-scan helpers

extension SplitPaneView {
    /// The pane as a terminal, or nil for non-terminal panes. The single
    /// idiom for terminal-only scans (tmux, roam protocol, session counting).
    var asTerminal: Ghostty.TerminalView? { self as? Ghostty.TerminalView }

    /// The split host this pane is attached to (terminals sit one level deeper,
    /// inside their `TerminalScrollView` wrapper). nil while detached.
    var enclosingSplitHost: SplitTreeHostingView? {
        var view = superview
        while let current = view {
            if let host = current as? SplitTreeHostingView { return host }
            view = current.superview
        }
        return nil
    }
}

extension SplitTree where ViewType == SplitPaneView {
    /// All terminal leaves in layout order, skipping non-terminal panes.
    var terminalLeaves: [Ghostty.TerminalView] {
        compactMap { $0.asTerminal }
    }
}

// MARK: - App-Tab Swipe Notification Plumbing

/// Shared by every pane type that can drive the interactive app-tab swipe
/// (terminal scroll-mode pan, trackpad swipe, VNC 3-finger pan). MainView
/// filters on `notification.object as? SplitPaneView` belonging to its
/// window, so any pane in the tree may post these.
extension SplitPaneView {

    /// The tab preset `binding` drives from this pane. A pane preset falls back
    /// to its tab preset when the tab has fewer than two panes.
    func appTabPreset(for binding: SwipeGestureBinding) -> SwipeGesturePreset? {
        if let preset = binding.appTabPreset { return preset }
        guard case .preset(let preset) = binding, let fallback = preset.tabFallback,
              (enclosingSplitHost?.paneCount ?? 0) < 2 else { return nil }
        return fallback
    }

    /// The half where `pan` started, matching the terminal's area-specific swipes.
    func swipeStartArea(of pan: UIPanGestureRecognizer) -> TerminalSwipeArea {
        pan.location(in: self).y - pan.translation(in: self).y < bounds.midY ? .top : .bottom
    }

    /// Ends a remote-screen pane's 3-finger pan bound to a pane preset; fires
    /// once when it travelled or flicked far enough in `direction`.
    func finishPaneCycleSwipe(_ preset: SwipeGesturePreset, direction: SwipeDirection,
                              translationX: CGFloat, velocityX: CGFloat) {
        let sign: CGFloat = direction == .left ? -1 : 1
        guard translationX * sign > 40 || velocityX * sign > 500,
              preset.isPaneCycle, let name = preset.notificationName else { return }
        #if !os(visionOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        NotificationCenter.default.post(name: name, object: self)
    }

    /// Ask the owning MainView to begin an app-tab swipe. Returns whether it
    /// accepted (a target tab exists and no swipe is settling). A nil `preset`
    /// means the shared binding for `direction`.
    func requestAppTabSwipeBegin(
        direction: SwipeDirection,
        velocityX: CGFloat,
        preset: SwipeGesturePreset? = nil
    ) -> Bool {
        var accepted = false
        postAppTabSwipeNotification(
            .appTabSwipeBegan,
            direction: direction,
            translationX: 0,
            velocityX: velocityX,
            preset: preset,
            accept: { if $0 { accepted = true } }
        )
        return accepted
    }

    func postAppTabSwipeNotification(
        _ name: Notification.Name,
        direction: SwipeDirection,
        translationX: CGFloat,
        velocityX: CGFloat,
        preset: SwipeGesturePreset? = nil,
        accept: ((Bool) -> Void)? = nil
    ) {
        var userInfo: [String: Any] = [
            "direction": direction,
            "translationX": translationX,
            "velocityX": velocityX,
            "width": max(bounds.width, 1),
        ]
        if let preset {
            userInfo["preset"] = preset
        }
        if let accept {
            userInfo["accept"] = accept
        }
        NotificationCenter.default.post(
            name: name,
            object: self,
            userInfo: userInfo
        )
    }

    /// Clamp a raw pan translation to the committed direction (a swipe can't
    /// overshoot past its origin or beyond one pane width).
    func normalizedAppTabSwipeTranslation(_ translationX: CGFloat, direction: SwipeDirection) -> CGFloat {
        let width = max(bounds.width, 1)
        switch direction {
        case .left:
            return min(0, max(-width, translationX))
        case .right:
            return max(0, min(width, translationX))
        }
    }
}
