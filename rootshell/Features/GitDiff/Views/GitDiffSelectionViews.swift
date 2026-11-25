//
//  GitDiffSelectionViews.swift
//  rootshell
//
//  The UIKit side of diff selection: a view behind the list that hosts the
//  loupe, the edit menu and first responder, the gesture recognizers on the
//  list, and the touch handles.
//

import SwiftUI
import UIKit

#if !os(visionOS)
private enum GitDiffSelectionTouch {
    static let finger = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
    static let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
}
#endif

// MARK: - Anchor

/// Backs the whole list, so its bounds are the list's content space. Never
/// takes a touch; it exists for the loupe, the menu and the keyboard.
final class GitDiffSelectionAnchorView: UIView, PanelKeyboardClaiming, UIEditMenuInteractionDelegate {
    weak var controller: GitDiffSelectionController?
    private var editMenu: UIEditMenuInteraction?
    private var menuTarget: CGRect = .null
    #if targetEnvironment(macCatalyst)
    private var menuButton: UIButton?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    var claimsKeyboard: Bool { true }

    override var canBecomeFirstResponder: Bool { true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }

    // MARK: Keyboard

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) || action == #selector(clearSelection(_:)) {
            return controller?.hasSelection ?? false
        }
        if action == #selector(selectAll(_:)) { return true }
        return false
    }

    override func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        controller?.selectAll(handles: false)
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                  action: #selector(clearSelection(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func clearSelection(_ sender: Any?) {
        controller?.clear()
    }

    // MARK: Menu

    /// `rect` is in this view's space. Mac Catalyst cannot present an edit
    /// menu, so there an invisible button pops the same items as a menu.
    func presentMenu(at rect: CGRect) {
        menuTarget = rect
        #if targetEnvironment(macCatalyst)
        guard let controller else { return }
        let button = menuButton ?? {
            let button = UIButton(type: .custom)
            button.showsMenuAsPrimaryAction = true
            button.isAccessibilityElement = false
            addSubview(button)
            menuButton = button
            return button
        }()
        button.frame = CGRect(x: rect.midX, y: rect.maxY, width: 1, height: 1)
        button.menu = UIMenu(children: controller.menuElements())
        button.performPrimaryAction()
        #else
        dismissMenu()
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenu = interaction
        interaction.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
        #endif
    }

    func dismissMenu() {
        guard let editMenu else { return }
        editMenu.dismissMenu()
        removeInteraction(editMenu)
        self.editMenu = nil
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        controller.map { UIMenu(children: $0.menuElements()) }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self, weak interaction] in
            guard let self, let interaction, self.editMenu === interaction else { return }
            self.removeInteraction(interaction)
            self.editMenu = nil
        }
    }
}

struct GitDiffSelectionAnchor: UIViewRepresentable {
    let controller: GitDiffSelectionController

    func makeUIView(context: Context) -> GitDiffSelectionAnchorView {
        let view = GitDiffSelectionAnchorView()
        view.controller = controller
        controller.anchorView = view
        return view
    }

    func updateUIView(_ view: GitDiffSelectionAnchorView, context: Context) {
        view.controller = controller
        controller.anchorView = view
    }

    static func dismantleUIView(_ view: GitDiffSelectionAnchorView, coordinator: ()) {
        view.dismissMenu()
        if view.isFirstResponder { view.resignFirstResponder() }
    }
}

// MARK: - Gestures

final class GitDiffSelectionGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    enum Gate { case press, tap, secondaryClick, pointerDrag, handle }

    let controller: GitDiffSelectionController
    let gate: Gate

    init(controller: GitDiffSelectionController, gate: Gate) {
        self.controller = controller
        self.gate = gate
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard gate != .handle else { return true }
        guard let point = controller.contentPoint(of: recognizer) else { return false }
        switch gate {
        case .press, .secondaryClick:
            return gate == .secondaryClick && controller.hasSelection ? controller.canBeginTap(at: point)
                : controller.canBeginSelection(at: point)
        case .pointerDrag:
            // The press-down point, not where the drag crossed its threshold.
            let translation = (recognizer as? UIPanGestureRecognizer)?
                .translation(in: controller.anchorView) ?? .zero
            return controller.canBeginSelection(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
        case .tap:
            return controller.canBeginTap(at: point)
        case .handle:
            return true
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gate == .tap { controller.lastTapWasPointer = touch.type == .indirectPointer }
        return true
    }

    /// Taps only observe, so header buttons and the scroll view still get theirs.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gate == .tap || gate == .secondaryClick
    }

    /// A pointer drag selects instead of scrolling; two-finger and wheel scrolls are unaffected.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gate == .pointerDrag || gate == .handle, let scroll = other.view as? UIScrollView else { return false }
        return other === scroll.panGestureRecognizer
    }
}

// visionOS has no UIGestureRecognizerRepresentable; it uses GitDiffSpatialSelectionGestures below.
#if !os(visionOS)
private extension GitDiffSelectionController {
    func point<R: UIGestureRecognizerRepresentable>(
        of recognizer: UIGestureRecognizer, context: UIGestureRecognizerRepresentableContext<R>
    ) -> CGPoint {
        contentPoint(of: recognizer)
            ?? context.converter.location(in: .named(GitDiffSelectionController.coordinateSpace))
    }
}

/// Finger: hold to select a word, then drag to grow the selection.
struct GitDiffPressSelectionGesture: UIGestureRecognizerRepresentable {
    let controller: GitDiffSelectionController

    func makeCoordinator(converter: CoordinateSpaceConverter) -> GitDiffSelectionGestureDelegate {
        GitDiffSelectionGestureDelegate(controller: controller, gate: .press)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.allowedTouchTypes = GitDiffSelectionTouch.finger
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = controller.point(of: recognizer, context: context)
        switch recognizer.state {
        case .began: controller.beginWordDrag(at: point, recognizer: recognizer)
        case .changed: controller.dragMoved(to: point)
        case .ended: controller.endDrag(presentingMenu: true)
        case .cancelled, .failed: controller.endDrag(presentingMenu: false)
        default: break
        }
    }
}

/// Finger taps and pointer clicks; the controller counts double and triple ones.
struct GitDiffTapSelectionGesture: UIGestureRecognizerRepresentable {
    let controller: GitDiffSelectionController

    func makeCoordinator(converter: CoordinateSpaceConverter) -> GitDiffSelectionGestureDelegate {
        GitDiffSelectionGestureDelegate(controller: controller, gate: .tap)
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.allowedTouchTypes = GitDiffSelectionTouch.finger + GitDiffSelectionTouch.pointer
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        controller.handleTap(at: controller.point(of: recognizer, context: context),
                             modifiers: recognizer.modifierFlags)
    }
}

/// Pointer: press and drag to select.
struct GitDiffPointerDragSelectionGesture: UIGestureRecognizerRepresentable {
    let controller: GitDiffSelectionController

    func makeCoordinator(converter: CoordinateSpaceConverter) -> GitDiffSelectionGestureDelegate {
        GitDiffSelectionGestureDelegate(controller: controller, gate: .pointerDrag)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.allowedTouchTypes = GitDiffSelectionTouch.pointer
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = controller.point(of: recognizer, context: context)
        switch recognizer.state {
        case .began:
            let translation = recognizer.translation(in: controller.anchorView)
            controller.beginPointerDrag(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y),
                                        extending: recognizer.modifierFlags.contains(.shift),
                                        recognizer: recognizer)
            controller.dragMoved(to: point)
        case .changed: controller.dragMoved(to: point)
        case .ended, .cancelled, .failed: controller.endDrag(presentingMenu: false)
        default: break
        }
    }
}

/// Pointer: right-click for Copy, Copy Line and Select All.
struct GitDiffSecondaryClickGesture: UIGestureRecognizerRepresentable {
    let controller: GitDiffSelectionController

    func makeCoordinator(converter: CoordinateSpaceConverter) -> GitDiffSelectionGestureDelegate {
        GitDiffSelectionGestureDelegate(controller: controller, gate: .secondaryClick)
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.allowedTouchTypes = GitDiffSelectionTouch.pointer
        recognizer.buttonMaskRequired = .secondary
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        controller.presentContextMenu(at: controller.point(of: recognizer, context: context))
    }
}

/// Grabs a handle on touch-down, before the scroll view can take the drag.
private struct GitDiffHandleDragGesture: UIGestureRecognizerRepresentable {
    let controller: GitDiffSelectionController
    let end: GitDiffSelectionController.HandleEnd

    func makeCoordinator(converter: CoordinateSpaceConverter) -> GitDiffSelectionGestureDelegate {
        GitDiffSelectionGestureDelegate(controller: controller, gate: .handle)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.allowedTouchTypes = GitDiffSelectionTouch.finger
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = controller.point(of: recognizer, context: context)
        switch recognizer.state {
        case .began: controller.beginHandleDrag(end, at: point, recognizer: recognizer)
        case .changed: controller.dragMoved(to: point)
        case .ended: controller.endDrag(presentingMenu: true)
        case .cancelled, .failed: controller.endDrag(presentingMenu: false)
        default: break
        }
    }
}
#endif

extension View {
    /// Selection gestures for the diff list; apply to the stack the anchor backs.
    func gitDiffSelectionGestures(_ controller: GitDiffSelectionController) -> some View {
        #if os(visionOS)
        modifier(GitDiffSpatialSelectionGestures(controller: controller))
        #else
        self
            .gesture(GitDiffPressSelectionGesture(controller: controller))
            .gesture(GitDiffTapSelectionGesture(controller: controller))
            .gesture(GitDiffPointerDragSelectionGesture(controller: controller))
            .gesture(GitDiffSecondaryClickGesture(controller: controller))
        #endif
    }
}

#if os(visionOS)
/// The same finger selection through SwiftUI gestures. Without a recognizer
/// to poll, a drag does not autoscroll.
private struct GitDiffSpatialSelectionGestures: ViewModifier {
    let controller: GitDiffSelectionController
    // Keyed by each drag's own start, since a cancelled gesture may never reach onEnded.
    @State private var pressStart: CGPoint?

    func body(content: Content) -> some View {
        let space = NamedCoordinateSpace.named(GitDiffSelectionController.coordinateSpace)
        content
            .simultaneousGesture(SpatialTapGesture(count: 1, coordinateSpace: space).onEnded { value in
                guard controller.canBeginTap(at: value.location) else { return }
                controller.lastTapWasPointer = false
                controller.handleTap(at: value.location, modifiers: [])
            })
            .gesture(LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: space))
                .onChanged { value in
                    guard case .second(true, let drag?) = value else { return }
                    if pressStart != drag.startLocation {
                        pressStart = drag.startLocation
                        guard controller.canBeginSelection(at: drag.startLocation) else { return }
                        controller.beginWordDrag(at: drag.startLocation)
                    }
                    controller.dragMoved(to: drag.location)
                }
                .onEnded { _ in
                    pressStart = nil
                    controller.endDrag(presentingMenu: true)
                })
    }
}
#endif

// MARK: - Handles

/// Lollipop handles at a finger selection's ends.
struct GitDiffSelectionHandles: View {
    let controller: GitDiffSelectionController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.showsHandles, let selection = controller.selection, !selection.isEmpty {
                let _ = controller.handleLayout
                if let caret = controller.caretRect(for: selection.start) {
                    GitDiffSelectionHandle(controller: controller, end: .start, caret: caret)
                }
                if let caret = controller.caretRect(for: selection.end) {
                    GitDiffSelectionHandle(controller: controller, end: .end, caret: caret)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GitDiffSelectionHandle: View {
    let controller: GitDiffSelectionController
    let end: GitDiffSelectionController.HandleEnd
    let caret: CGRect

    private static let knob: CGFloat = 12
    #if os(visionOS)
    @State private var dragStart: CGPoint?
    #endif

    var body: some View {
        let tint = Color.accentColor
        VStack(spacing: 0) {
            if end == .start { Circle().fill(tint).frame(width: Self.knob, height: Self.knob) }
            Rectangle().fill(tint).frame(width: 2, height: caret.height)
            if end == .end { Circle().fill(tint).frame(width: Self.knob, height: Self.knob) }
        }
        .frame(width: 44, height: caret.height + Self.knob + 24)
        .contentShape(Rectangle())
        #if os(visionOS)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(GitDiffSelectionController.coordinateSpace))
            .onChanged { value in
                if dragStart != value.startLocation {
                    dragStart = value.startLocation
                    controller.beginHandleDrag(end, at: value.startLocation)
                }
                controller.dragMoved(to: value.location)
            }
            .onEnded { _ in
                dragStart = nil
                controller.endDrag(presentingMenu: true)
            })
        #else
        .gesture(GitDiffHandleDragGesture(controller: controller, end: end))
        #endif
        .position(x: caret.midX, y: end == .start ? caret.midY - Self.knob / 2 : caret.midY + Self.knob / 2)
        .accessibilityHidden(true)
    }
}
