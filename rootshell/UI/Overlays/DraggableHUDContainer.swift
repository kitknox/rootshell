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
#if targetEnvironment(macCatalyst)
import AppKit
#endif

/// Opt-in corner resizing for a panel HUD. The keys persist the user's size;
/// their defaults are the panel's ideal size.
struct HUDResizing {
    let minSize: CGSize
    let widthKey: SettingKey<Double>
    let heightKey: SettingKey<Double>
}

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
    /// When set, the host owns the HUD's size and `content` should fill it.
    var resizing: HUDResizing?
    /// Fills the whole area instead of floating; `content` should fill it.
    var fills: Bool
    var dismissShortcuts: [HUDKeyShortcut]
    var forwardsQuickSettingsToggle: Bool
    var forwardsThemePickerToggle: Bool
    var forwardsFindToggle: Bool
    var forwardsClipboardManagerToggle: Bool
    var forwardsOpenInFolderToggle: Bool
    var forwardsFileManagerToggle: Bool
    var forwardsIPLookupToggle: Bool
    var forwardsHTTPCaptureToggle: Bool
    var forwardsAgentInboxToggle: Bool
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
         resizing: HUDResizing? = nil,
         fills: Bool = false,
         dismissShortcuts: [HUDKeyShortcut] = [],
         forwardsQuickSettingsToggle: Bool = false,
         forwardsThemePickerToggle: Bool = false,
         forwardsFindToggle: Bool = false,
         forwardsClipboardManagerToggle: Bool = false,
         forwardsOpenInFolderToggle: Bool = false,
         forwardsFileManagerToggle: Bool = false,
         forwardsIPLookupToggle: Bool = false,
         forwardsHTTPCaptureToggle: Bool = false,
         forwardsAgentInboxToggle: Bool = false,
         onForwardedToggle: (() -> Void)? = nil,
         onFind: (() -> Void)? = nil,
         onDismiss: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.inset = inset
        self.draggable = draggable
        self.resizing = resizing
        self.fills = fills
        self.dismissShortcuts = dismissShortcuts
        self.forwardsQuickSettingsToggle = forwardsQuickSettingsToggle
        self.forwardsThemePickerToggle = forwardsThemePickerToggle
        self.forwardsFindToggle = forwardsFindToggle
        self.forwardsClipboardManagerToggle = forwardsClipboardManagerToggle
        self.forwardsOpenInFolderToggle = forwardsOpenInFolderToggle
        self.forwardsFileManagerToggle = forwardsFileManagerToggle
        self.forwardsIPLookupToggle = forwardsIPLookupToggle
        self.forwardsHTTPCaptureToggle = forwardsHTTPCaptureToggle
        self.forwardsAgentInboxToggle = forwardsAgentInboxToggle
        self.onForwardedToggle = onForwardedToggle
        self.onFind = onFind
        self.onDismiss = onDismiss
        self.content = content
    }

    func makeUIView(context: Context) -> DraggableHUDHostView {
        let view = DraggableHUDHostView()
        view.inset = inset
        view.isDraggable = draggable && !fills
        view.fills = fills
        view.dismissShortcuts = dismissShortcuts
        view.forwardsQuickSettingsToggle = forwardsQuickSettingsToggle
        view.forwardsThemePickerToggle = forwardsThemePickerToggle
        view.forwardsFindToggle = forwardsFindToggle
        view.forwardsClipboardManagerToggle = forwardsClipboardManagerToggle
        view.forwardsOpenInFolderToggle = forwardsOpenInFolderToggle
        view.forwardsFileManagerToggle = forwardsFileManagerToggle
        view.forwardsIPLookupToggle = forwardsIPLookupToggle
        view.forwardsHTTPCaptureToggle = forwardsHTTPCaptureToggle
        view.forwardsAgentInboxToggle = forwardsAgentInboxToggle
        view.onForwardedToggle = onForwardedToggle
        view.onFind = onFind
        view.onDismiss = onDismiss

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        // Self-size to the SwiftUI content (matters for the theme picker's ScrollView).
        // A resizable or filling HUD is sized by the host instead.
        host.sizingOptions = resizing == nil && !fills ? .intrinsicContentSize : []
        context.coordinator.host = host

        view.hostController = host
        view.hostedView = host.view
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        view.attachPan()
        if let resizing { view.attachResizing(resizing) }
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
        uiView.forwardsOpenInFolderToggle = forwardsOpenInFolderToggle
        uiView.forwardsFileManagerToggle = forwardsFileManagerToggle
        uiView.forwardsIPLookupToggle = forwardsIPLookupToggle
        uiView.forwardsHTTPCaptureToggle = forwardsHTTPCaptureToggle
        uiView.forwardsAgentInboxToggle = forwardsAgentInboxToggle
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
    /// Also true for a docked panel field that opts in via `claimsKeyboard`
    /// (the file manager sidebar), which lives outside any HUD host.
    static func ownsFirstResponder(in window: UIWindow) -> Bool {
        func containsFocusedHUD(_ view: UIView, insideHUD: Bool) -> Bool {
            let insideHUD = insideHUD || view is DraggableHUDHostView
            if view.isFirstResponder,
               insideHUD || (view as? SidebarSearchTextField)?.claimsKeyboard == true { return true }
            return view.subviews.contains { containsFocusedHUD($0, insideHUD: insideHUD) }
        }
        return containsFocusedHUD(window, insideHUD: false)
    }

    weak var hostController: UIViewController?
    weak var hostedView: UIView?
    var inset: CGFloat = 12
    var isDraggable = true
    var fills = false
    var dismissShortcuts: [HUDKeyShortcut] = []
    var forwardsQuickSettingsToggle = false
    var forwardsThemePickerToggle = false
    var forwardsFindToggle = false
    var forwardsClipboardManagerToggle = false
    var forwardsOpenInFolderToggle = false
    var forwardsFileManagerToggle = false
    var forwardsIPLookupToggle = false
    var forwardsHTTPCaptureToggle = false
    var forwardsAgentInboxToggle = false
    var onForwardedToggle: (() -> Void)?
    var onFind: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Once the user drags the HUD we preserve their chosen position. Before
    /// that, the HUD is re-anchored top-right on every layout pass so a wrong
    /// intermediate measurement (SwiftUI not having computed the content's
    /// ideal size yet) self-corrects instead of latching permanently.
    private var userHasDragged = false
    private var panStartCenter: CGPoint = .zero

    private var resizing: HUDResizing?
    /// The user's chosen size, before clamping to the available area, so a
    /// HUD squeezed by a smaller window grows back when room returns.
    private var userSize: CGSize = .zero
    private var resizeStartFrame: CGRect = .zero
    private var resizeStartUserSize: CGSize = .zero
    private var grips: [HUDResizeGrip] = []
    private var gripRevealHover: UIHoverGestureRecognizer?

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
        if action == #selector(menuOpenInFolder(_:)) { return forwardsOpenInFolderToggle }
        if action == #selector(menuToggleFileManager(_:)) { return forwardsFileManagerToggle }
        if action == #selector(menuToggleIPLookup(_:)) { return forwardsIPLookupToggle }
        if action == #selector(menuToggleHTTPCapture(_:)) { return forwardsHTTPCaptureToggle }
        if action == #selector(menuToggleAgentInbox(_:)) { return forwardsAgentInboxToggle }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func menuToggleHTTPCapture(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuToggleAgentInbox(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuToggleFileManager(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuToggleIPLookup(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuToggleQuickSettings(_ sender: Any?) {
        (onForwardedToggle ?? onDismiss)?()
    }

    @objc func menuOpenInFolder(_ sender: Any?) {
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
        if forwardsOpenInFolderToggle,
           let sequence = KeybindManager.shared.sequence(for: .open_in_folder),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuOpenInFolder(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if forwardsFileManagerToggle,
           let sequence = KeybindManager.shared.sequence(for: .toggle_file_manager),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuToggleFileManager(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if forwardsIPLookupToggle,
           let sequence = KeybindManager.shared.sequence(for: .toggle_ip_lookup),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuToggleIPLookup(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if forwardsHTTPCaptureToggle,
           let sequence = KeybindManager.shared.sequence(for: .toggle_http_capture),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuToggleHTTPCapture(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if forwardsAgentInboxToggle,
           let sequence = KeybindManager.shared.sequence(for: .toggle_agent_inbox),
           !sequence.isSequence, let trigger = sequence.first {
            let command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(menuToggleAgentInbox(_:)))
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
        if gestureRecognizer === gripRevealHover { return true }
        guard isDraggable, let bar = hostedView else { return false }
        let point = gestureRecognizer.location(in: bar)
        var view = bar.hitTest(point, with: nil)
        while let current = view, current !== bar {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { return false }
            // A UIKit control (segmented picker, switch) tracks its own click;
            // a pan that begins on the slightest pointer jitter cancels it.
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    /// The grip-reveal hover only observes; it must not starve hover effects in the content.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === gripRevealHover
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
            layoutGrips()
        default:
            break
        }
    }

    // MARK: Resizing

    func attachResizing(_ resizing: HUDResizing) {
        self.resizing = resizing
        let store = SettingsStore.shared
        userSize = CGSize(width: resizing.widthKey.sanitized(store.value(resizing.widthKey)),
                          height: resizing.heightKey.sanitized(store.value(resizing.heightKey)))
        for corner in [HUDResizeGrip.Corner.bottomLeft, .bottomRight] {
            let grip = HUDResizeGrip(corner: corner)
            grip.onPan = { [weak self] gesture in self?.handleResize(gesture, corner: corner) }
            grip.onReset = { [weak self] in self?.resetSize() }
            addSubview(grip)
            grips.append(grip)
        }

        // Grips stay hidden until a touch lands or the pointer hovers near a corner.
        let touchObserver = HUDTouchObserverGesture { [weak self] point in
            self?.grips.filter { DraggableHUDHostView.revealZone(of: $0).contains(point) }.forEach { $0.flash() }
        }
        addGestureRecognizer(touchObserver)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleGripRevealHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)
        gripRevealHover = hover
    }

    @objc private func handleGripRevealHover(_ gesture: UIHoverGestureRecognizer) {
        let point = gesture.location(in: self)
        let hovering = gesture.state == .began || gesture.state == .changed
        for grip in grips {
            grip.isNearby = hovering && Self.revealZone(of: grip).contains(point)
        }
    }

    private static func revealZone(of grip: HUDResizeGrip) -> CGRect {
        grip.frame.insetBy(dx: -24, dy: -24)
    }

    /// The top edge and the opposite side stay put; the grabbed corner follows.
    private func handleResize(_ gesture: UIPanGestureRecognizer, corner: HUDResizeGrip.Corner) {
        guard let bar = hostedView, let resizing else { return }
        switch gesture.state {
        case .began:
            userHasDragged = true
            resizeStartFrame = bar.frame
            resizeStartUserSize = userSize
        case .changed:
            let t = gesture.translation(in: self)
            let start = resizeStartFrame
            let minSize = resizing.minSize
            var frame = start
            frame.size.height = min(max(start.height + t.y, minSize.height), bounds.height - inset - start.minY)
            switch corner {
            case .bottomRight:
                frame.size.width = min(max(start.width + t.x, minSize.width), bounds.width - inset - start.minX)
            case .bottomLeft:
                frame.size.width = min(max(start.width - t.x, minSize.width), start.maxX - inset)
                frame.origin.x = start.maxX - frame.width
            }
            // Only a dimension the drag actually changed replaces the preferred
            // size; one pinned by the available area keeps its larger preference.
            userSize = CGSize(width: frame.width != start.width ? frame.width : resizeStartUserSize.width,
                              height: frame.height != start.height ? frame.height : resizeStartUserSize.height)
            if bar.frame != frame { bar.frame = frame }
            layoutGrips()
        case .ended, .cancelled:
            persistSize()
        default:
            break
        }
    }

    private func resetSize() {
        guard let resizing else { return }
        userSize = CGSize(width: resizing.widthKey.defaultValue, height: resizing.heightKey.defaultValue)
        persistSize()
        setNeedsLayout()
    }

    private func persistSize() {
        guard let resizing else { return }
        SettingsStore.shared.set(resizing.widthKey, Double(userSize.width))
        SettingsStore.shared.set(resizing.heightKey, Double(userSize.height))
    }

    /// Grips straddle the bar's bottom corners, partly outside it.
    private func layoutGrips() {
        guard let bar = hostedView else { return }
        let length = HUDResizeGrip.length, outset = HUDResizeGrip.outset
        for grip in grips {
            let x = grip.corner == .bottomRight ? bar.frame.maxX - length + outset : bar.frame.minX - outset
            let frame = CGRect(x: x, y: bar.frame.maxY - length + outset, width: length, height: length)
            if grip.frame != frame { grip.frame = frame }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bar = hostedView, bounds.width > 0, bounds.height > 0 else { return }
        if fills {
            if bar.frame != bounds { bar.frame = bounds }
            return
        }

        // Ask the hosting controller for the SwiftUI content's ideal size directly.
        // This forces layout of the content synchronously, so the FIRST measurement
        // is already correct — unlike `systemLayoutSizeFitting`, which returns a
        // near-full-bounds size before SwiftUI has computed the content and makes
        // the HUD flash at the wrong size/position before self-correcting.
        var size: CGSize
        if let resizing {
            size = CGSize(width: max(userSize.width, resizing.minSize.width),
                          height: max(userSize.height, resizing.minSize.height))
        } else if let host = hostController as? UIHostingController<AnyView> {
            size = host.sizeThatFits(in: UIView.layoutFittingCompressedSize)
        } else {
            size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        size.width = min(size.width, max(0, bounds.width - inset * 2))
        size.height = min(size.height, max(0, bounds.height - inset * 2))

        // Ignore degenerate measurements taken before SwiftUI computes the
        // content's ideal size — anchoring to them strands the HUD off-screen.
        guard size.width > 10, size.height > 10 else { return }

        // Only write geometry that actually changed: reassigning an equal frame
        // still interrupts a UIKit control tracking a click inside the HUD.
        if userHasDragged {
            // Preserve where the user dropped it; just resize + re-clamp on rotation/resize.
            let center = clamp(bar.center, size: size)
            if bar.bounds.size != size { bar.bounds = CGRect(origin: .zero, size: size) }
            if bar.center != center { bar.center = center }
        } else {
            // Keep pinned top-right until the first drag. Re-anchoring every pass
            // means a wrong first measurement is corrected on the next layout,
            // rather than latched (which required a manual re-toggle to fix).
            let frame = CGRect(x: bounds.width - size.width - inset, y: inset,
                               width: size.width, height: size.height)
            if bar.frame != frame { bar.frame = frame }
        }
        layoutGrips()
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
        guard let bar = hostedView,
              bar.frame.contains(point) || grips.contains(where: { $0.frame.contains(point) })
        else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Corner handle for a resizable HUD. A sibling above the hosted view, so the
/// HUD's move pan never sees its touches.
private final class HUDResizeGrip: UIView {
    enum Corner { case bottomLeft, bottomRight }

    /// Kept shallow inside the panel so it doesn't swallow taps on footer
    /// controls (the file manager's trailing shortcuts button).
    static let length: CGFloat = 30
    /// How far the grip extends past the panel's edges.
    static let outset: CGFloat = 12
    /// Matches `floatingHUDPanelBackground`'s corner radius.
    private static let panelCornerRadius: CGFloat = 16

    let corner: Corner
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    var onReset: (() -> Void)?

    /// The pointer is near this corner (tracked by the host over a larger zone).
    var isNearby = false { didSet { if isNearby != oldValue { updateAppearance() } } }

    private let arc = CAShapeLayer()
    private var isHovering = false { didSet { updateAppearance() } }
    private var isResizing = false { didSet { updateAppearance() } }
    private var isFlashing = false { didSet { updateAppearance() } }
    private var flashTask: Task<Void, Never>?
    #if targetEnvironment(macCatalyst)
    private var cursorToken: UUID?
    #endif

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: .zero)
        arc.fillColor = nil
        arc.lineWidth = 3
        arc.lineCap = .round
        arc.opacity = 0
        layer.addSublayer(arc)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        addInteraction(UIPointerInteraction(delegate: self))
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateAppearance()
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A quarter arc just inside the panel's rounded corner.
        let radius = Self.panelCornerRadius
        let cornerInset = Self.length - Self.outset
        let center: CGPoint
        let angles: (CGFloat, CGFloat)
        switch corner {
        case .bottomRight:
            center = CGPoint(x: cornerInset - radius, y: cornerInset - radius)
            angles = (0, .pi / 2)
        case .bottomLeft:
            center = CGPoint(x: Self.outset + radius, y: cornerInset - radius)
            angles = (.pi / 2, .pi)
        }
        arc.frame = bounds
        arc.path = UIBezierPath(arcCenter: center, radius: radius - 5,
                                startAngle: angles.0, endAngle: angles.1, clockwise: true).cgPath
    }

    /// Shows the grip briefly after a nearby touch, then fades it out.
    func flash() {
        flashTask?.cancel()
        isFlashing = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }

    /// Hidden at rest; the grabbable area works either way.
    private func updateAppearance() {
        arc.strokeColor = UIColor.systemGray.resolvedColor(with: traitCollection).cgColor
        let opacity: Float = isHovering || isResizing ? 0.9 : (isNearby || isFlashing ? 0.5 : 0)
        guard arc.opacity != opacity else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(opacity == 0 ? 0.35 : 0.15)
        arc.opacity = opacity
        CATransaction.commit()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isResizing = true
            #if targetEnvironment(macCatalyst)
            claimCursor()
            #endif
        case .ended, .cancelled, .failed:
            isResizing = false
            flash()
            #if targetEnvironment(macCatalyst)
            if !isHovering { releaseCursor() }
            #endif
        default:
            break
        }
        onPan?(gesture)
    }

    @objc private func handleDoubleTap() {
        onReset?()
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            isHovering = true
            #if targetEnvironment(macCatalyst)
            claimCursor()
            #endif
        default:
            isHovering = false
            #if targetEnvironment(macCatalyst)
            if !isResizing { releaseCursor() }
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    private func claimCursor() {
        let token = cursorToken ?? UUID()
        cursorToken = token
        let position: NSCursor.FrameResizePosition = corner == .bottomRight ? .bottomRight : .bottomLeft
        CatalystCursorCoordinator.shared.ensure(
            token, cursor: .frameResize(position: position, directions: .all), priority: .ui)
    }

    private func releaseCursor() {
        guard let cursorToken else { return }
        CatalystCursorCoordinator.shared.unregister(cursorToken)
        self.cursorToken = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseCursor() }
    }
    #endif
}

/// Sees every touch-down in the HUD without claiming it: fails on the first
/// touch, so it never delays, cancels, or competes with the content's gestures.
private final class HUDTouchObserverGesture: UIGestureRecognizer {
    private let onTouchDown: (CGPoint) -> Void

    init(onTouchDown: @escaping (CGPoint) -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
        if let view, let touch = touches.first { onTouchDown(touch.location(in: view)) }
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
extension HUDResizeGrip: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .path(Self.diagonalArrowPath(for: corner)))
    }

    /// A double-headed arrow along the grabbed corner's diagonal, centered on the pointer.
    private static func diagonalArrowPath(for corner: Corner) -> UIBezierPath {
        let points: [CGPoint] = [
            CGPoint(x: -9, y: 0), CGPoint(x: -4, y: -4.5), CGPoint(x: -4, y: -1.5),
            CGPoint(x: 4, y: -1.5), CGPoint(x: 4, y: -4.5), CGPoint(x: 9, y: 0),
            CGPoint(x: 4, y: 4.5), CGPoint(x: 4, y: 1.5), CGPoint(x: -4, y: 1.5),
            CGPoint(x: -4, y: 4.5),
        ]
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        path.apply(CGAffineTransform(rotationAngle: corner == .bottomRight ? .pi / 4 : -.pi / 4))
        return path
    }
}
#endif
