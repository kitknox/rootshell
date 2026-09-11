//
//  DraggableHUDContainer.swift
//  rootshell
//
//  Hosts a floating HUD (search bar, theme picker) over the terminal and drags it
//  with a native UIPanGestureRecognizer instead of a SwiftUI DragGesture.
//
//  Why UIKit: a SwiftUI `.gesture(DragGesture())` on a control-laden bar stutters
//  and fights the controls for touches; and a plain SwiftUI overlay's `.onKeyPress`
//  steals clicks / is preempted by app menu shortcuts on macOS. Hosting in a
//  UIHostingController + a native pan + host-level UIKeyCommands fixes all of that.
//

import SwiftUI
import UIKit

/// A keyboard shortcut that dismisses the hosted HUD. Handled by a real
/// `UIKeyCommand` on the host view, so it works even when the HUD's text field is
/// focused on macOS (where a registered app menu shortcut would otherwise win).
struct HUDKeyShortcut {
    let input: String
    let modifiers: UIKeyModifierFlags

    static let escape = HUDKeyShortcut(input: UIKeyCommand.inputEscape, modifiers: [])
}

/// Wraps `content` in a UIKit host that fills the available area, places the HUD at
/// the top-right, and lets a native pan move it. Touches outside the HUD fall
/// through to whatever is below (the terminal).
struct DraggableHUDContainer<Content: View>: UIViewRepresentable {
    var inset: CGFloat
    var draggable: Bool
    var dismissShortcuts: [HUDKeyShortcut]
    var forwardsQuickSettingsToggle: Bool
    var forwardsThemePickerToggle: Bool
    var forwardsFindToggle: Bool
    var forwardsClipboardManagerToggle: Bool
    /// Handles a forwarded toggle menu action instead of `onDismiss`. Needed by
    /// the clipboard manager, whose toggle is a 3-state cycle (open → keyboard
    /// mode → close) rather than a plain dismiss: the HUD's field can hold
    /// first responder before keyboard mode is on (manual tap), and the toggle
    /// must then advance the cycle, not close.
    var onForwardedToggle: (() -> Void)?
    var onFind: (() -> Void)?
    var onDismiss: (() -> Void)?
    var content: () -> Content

    init(inset: CGFloat = 12,
         draggable: Bool = true,
         dismissShortcuts: [HUDKeyShortcut] = [],
         forwardsQuickSettingsToggle: Bool = false,
         forwardsThemePickerToggle: Bool = false,
         forwardsFindToggle: Bool = false,
         forwardsClipboardManagerToggle: Bool = false,
         onForwardedToggle: (() -> Void)? = nil,
         onFind: (() -> Void)? = nil,
         onDismiss: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.inset = inset
        self.draggable = draggable
        self.dismissShortcuts = dismissShortcuts
        self.forwardsQuickSettingsToggle = forwardsQuickSettingsToggle
        self.forwardsThemePickerToggle = forwardsThemePickerToggle
        self.forwardsFindToggle = forwardsFindToggle
        self.forwardsClipboardManagerToggle = forwardsClipboardManagerToggle
        self.onForwardedToggle = onForwardedToggle
        self.onFind = onFind
        self.onDismiss = onDismiss
        self.content = content
    }

    func makeUIView(context: Context) -> DraggableHUDHostView {
        let view = DraggableHUDHostView()
        view.inset = inset
        view.isDraggable = draggable
        view.dismissShortcuts = dismissShortcuts
        view.forwardsQuickSettingsToggle = forwardsQuickSettingsToggle
        view.forwardsThemePickerToggle = forwardsThemePickerToggle
        view.forwardsFindToggle = forwardsFindToggle
        view.forwardsClipboardManagerToggle = forwardsClipboardManagerToggle
        view.onForwardedToggle = onForwardedToggle
        view.onFind = onFind
        view.onDismiss = onDismiss

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        // Self-size to the SwiftUI content (matters for the theme picker's ScrollView).
        host.sizingOptions = .intrinsicContentSize
        context.coordinator.host = host

        view.hostController = host
        view.hostedView = host.view
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        view.attachPan()
        return view
    }

    func updateUIView(_ uiView: DraggableHUDHostView, context: Context) {
        // Keep the hosted SwiftUI view + dismiss closure/shortcuts in sync. The HUD's
        // position lives on the UIView and is untouched by content updates.
        context.coordinator.host?.rootView = AnyView(content())
        uiView.onFind = onFind
        uiView.onDismiss = onDismiss
        uiView.dismissShortcuts = dismissShortcuts
        uiView.forwardsQuickSettingsToggle = forwardsQuickSettingsToggle
        uiView.forwardsThemePickerToggle = forwardsThemePickerToggle
        uiView.forwardsFindToggle = forwardsFindToggle
        uiView.forwardsClipboardManagerToggle = forwardsClipboardManagerToggle
        uiView.onForwardedToggle = onForwardedToggle
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: DraggableHUDHostView, coordinator: Coordinator) {
        coordinator.host?.willMove(toParent: nil)
        coordinator.host?.view.removeFromSuperview()
        coordinator.host?.removeFromParent()
        coordinator.host = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Erased to UIHostingController<AnyView> (not <Content>) and given an explicit
    // deinit: the swift-frontend optimizer crashes in EarlyPerfInliner while inlining
    // the synthesized deinit of a Coordinator holding a generic UIHostingController<Content>
    // at -O (swiftlang/swift#89851, #90150). Release/Archive-only; Debug (-Onone) is fine.
    final class Coordinator {
        var host: UIHostingController<AnyView>?

        deinit {
            host = nil
        }
    }
}

/// Non-generic so its `@objc` handlers and `keyCommands` are valid (a generic UIView
/// can't expose `@objc` members to the Obj-C runtime).
final class DraggableHUDHostView: UIView, UIGestureRecognizerDelegate {
    /// Passthrough HUDs such as Find do not raise overlayOwnsKeyboard: the
    /// terminal remains usable beside them. Passive terminal focus recovery
    /// must still yield while a HUD control actually holds first responder.
    /// Inspect only this window, and use live UIKit state rather than a flag
    /// that can lag SwiftUI field focus or HUD removal.
    static func ownsFirstResponder(in window: UIWindow) -> Bool {
        func containsFocusedHUD(_ view: UIView, insideHUD: Bool) -> Bool {
            let insideHUD = insideHUD || view is DraggableHUDHostView
            if insideHUD && view.isFirstResponder { return true }
            return view.subviews.contains { containsFocusedHUD($0, insideHUD: insideHUD) }
        }
        return containsFocusedHUD(window, insideHUD: false)
    }

    weak var hostController: UIViewController?
    weak var hostedView: UIView?
    var inset: CGFloat = 12
    var isDraggable = true
    var dismissShortcuts: [HUDKeyShortcut] = []
    var forwardsQuickSettingsToggle = false
    var forwardsThemePickerToggle = false
    var forwardsFindToggle = false
    var forwardsClipboardManagerToggle = false
    var onForwardedToggle: (() -> Void)?
    var onFind: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Once the user drags the HUD we preserve their chosen position. Before
    /// that, the HUD is re-anchored top-right on every layout pass so a wrong
    /// intermediate measurement (SwiftUI not having computed the content's
    /// ideal size yet) self-corrects instead of latching permanently.
    private var userHasDragged = false
    private var panStartCenter: CGPoint = .zero

    // MARK: Menu action

    // The app's toggle_theme_picker / start_search menu items (whose shortcuts honor
    // remaps via DynamicShortcut) fire `sendAction(menuToggleThemePicker:/findInTerminal:,
    // to: nil)`. While the HUD's search field is first responder the terminal isn't
    // in the chain, so that action finds no target and no-ops. This host IS in the
    // chain, so answering the selector lets the existing customizable shortcut dismiss
    // the HUD. Each is gated so only the matching HUD claims it.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(menuToggleQuickSettings(_:)) { return forwardsQuickSettingsToggle }
        if action == #selector(menuToggleThemePicker(_:)) { return forwardsThemePickerToggle }
        if action == #selector(findInTerminal(_:)) { return forwardsFindToggle }
        if action == #selector(menuToggleClipboardManager(_:)) { return forwardsClipboardManagerToggle }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func menuToggleQuickSettings(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuToggleThemePicker(_ sender: Any?) {
        onDismiss?()
    }

    @objc func menuToggleClipboardManager(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func findInTerminal(_ sender: Any?) {
        (onFind ?? onDismiss)?()
    }

    // MARK: Key commands

    // For dismiss keys that DON'T collide with an app menu shortcut (e.g. Escape):
    // the host sits in the focused HUD's responder chain, so these fire even while
    // the HUD's text field is focused. Keys that DO collide with a SwiftUI menu item
    // (Cmd-Shift-T) can't be won here — a menu item beats a responder UIKeyCommand
    // even with wantsPriorityOverSystemBehavior — so those go through the menu action
    // (see canPerformAction / menuToggleThemePicker) instead.
    override var keyCommands: [UIKeyCommand]? {
        var commands = dismissShortcuts.map {
            let command = UIKeyCommand(input: $0.input, modifierFlags: $0.modifiers,
                                       action: #selector(handleDismissCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        if forwardsQuickSettingsToggle,
           let sequence = KeybindManager.shared.sequence(for: .toggle_quick_settings),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuToggleQuickSettings(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if onFind != nil {
            let command = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findInTerminal(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands.isEmpty ? nil : commands
    }

    @objc private func handleDismissCommand(_ command: UIKeyCommand) {
        onDismiss?()
    }

    // MARK: VC containment

    /// Adopt the hosting controller as a proper child VC once we're in a window, so
    /// the embedded TextField's first-responder/keyboard behaviour works reliably.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil,
              let controller = hostController, controller.parent == nil,
              let parent = nearestViewController() else { return }
        parent.addChild(controller)
        controller.didMove(toParent: parent)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: Dragging

    func attachPan() {
        guard let bar = hostedView else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        // Default cancelsTouchesInView == true: a tap never reaches the pan's
        // movement threshold (so the field/buttons get it), but once a drag starts
        // the underlying control's touch is cancelled and the HUD moves cleanly.
        bar.addGestureRecognizer(pan)
    }

    /// Yield to a scroll view so dragging the list scrolls; the HUD is dragged by
    /// its chrome (header, around the controls). `override` because UIView declares
    /// this too (it also satisfies the UIGestureRecognizerDelegate requirement).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isDraggable, let bar = hostedView else { return false }
        let point = gestureRecognizer.location(in: bar)
        var view = bar.hitTest(point, with: nil)
        while let current = view, current !== bar {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { return false }
            view = current.superview
        }
        return true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let bar = hostedView else { return }
        switch gesture.state {
        case .began:
            userHasDragged = true
            panStartCenter = bar.center
        case .changed:
            let t = gesture.translation(in: self)
            bar.center = clamp(CGPoint(x: panStartCenter.x + t.x, y: panStartCenter.y + t.y),
                               size: bar.bounds.size)
        default:
            break
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bar = hostedView, bounds.width > 0, bounds.height > 0 else { return }

        // Ask the hosting controller for the SwiftUI content's ideal size directly.
        // This forces layout of the content synchronously, so the FIRST measurement
        // is already correct — unlike `systemLayoutSizeFitting`, which returns a
        // near-full-bounds size before SwiftUI has computed the content and makes
        // the HUD flash at the wrong size/position before self-correcting.
        var size: CGSize
        if let host = hostController as? UIHostingController<AnyView> {
            size = host.sizeThatFits(in: UIView.layoutFittingCompressedSize)
        } else {
            size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        size.width = min(size.width, max(0, bounds.width - inset * 2))
        size.height = min(size.height, max(0, bounds.height - inset * 2))

        // Ignore degenerate measurements taken before SwiftUI computes the
        // content's ideal size — anchoring to them strands the HUD off-screen.
        guard size.width > 10, size.height > 10 else { return }

        if userHasDragged {
            // Preserve where the user dropped it; just resize + re-clamp on rotation/resize.
            let center = bar.center
            bar.bounds = CGRect(origin: .zero, size: size)
            bar.center = clamp(center, size: size)
        } else {
            // Keep pinned top-right until the first drag. Re-anchoring every pass
            // means a wrong first measurement is corrected on the next layout,
            // rather than latched (which required a manual re-toggle to fix).
            bar.frame = CGRect(x: bounds.width - size.width - inset, y: inset,
                               width: size.width, height: size.height)
        }
    }

    private func clamp(_ center: CGPoint, size: CGSize) -> CGPoint {
        let halfW = size.width / 2, halfH = size.height / 2
        return CGPoint(
            x: min(max(center.x, halfW + inset), bounds.width - halfW - inset),
            y: min(max(center.y, halfH + inset), bounds.height - halfH - inset)
        )
    }

    /// Only intercept touches that land on the HUD; everything else passes through
    /// to the terminal underneath so the rest of the screen stays interactive.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let bar = hostedView, bar.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
