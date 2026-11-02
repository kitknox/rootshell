#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

extension Notification.Name {
    /// Posted with the window whose Duo fold appeared, moved, or went away.
    static let terminalFoldRegionDidChange = Notification.Name("terminalFoldRegionDidChange")
}

/// Keyboard events forwarded to whichever controller currently owns the
/// window's keyboard. Owners change on every focus handoff; the closures
/// installed on the keyboard never do.
enum TerminalTouchKeyboardEvent {
    case modifiersChanged(KeyModifiers)
    case dismiss, pinHidden, switchToSystemKeyboard, compose, paste, tabs, customize
    case toolbarAction(String)
    case heightChanged
    case placementRequested(TerminalTouchKeyboardModel.Placement)
    case nativePlacementChanged(TerminalTouchKeyboardModel.Placement)
    case docked
}

/// Runtime state scoped to a window, optionally partitioned by tab. One
/// keyboard, input root and input controller serve every terminal in the
/// window, so UIKit keeps the same input set while focus moves between them.
/// Weak window keys release everything when a scene closes.
@MainActor
final class TerminalTouchKeyboardWindowState {
    private static let windows = NSMapTable<UIWindow, TerminalTouchKeyboardWindowState>.weakToStrongObjects()
    private var states = TerminalTouchKeyboardModel.StateStore<TerminalFloatingKeyboardState>()
    private(set) weak var window: UIWindow?
    /// Controller whose terminal presents the keyboard. nil between a genuine
    /// focus loss and the next terminal claiming it.
    weak var owner: TerminalKeyboardAccessoryController?
    /// The terminal whose focus went outside the app while its card stayed up.
    weak var parkedOwner: TerminalKeyboardAccessoryController?
    private var keyboardShowObserver: NSObjectProtocol?
    /// The state whose choices the live keyboard currently shows.
    private(set) var displayedState: TerminalFloatingKeyboardState?
    var overlay: TerminalFloatingKeyboardOverlay?
    /// Optional tabletop input region, expressed in this app window's coordinates.
    private(set) var inputRegion: CGRect?
    /// The Duo's fold in this window's coordinates, even when tabletop mode
    /// reserves no region.
    private(set) var foldRegion: CGRect?

    private(set) lazy var keyboard: TerminalTouchKeyboardView = makeKeyboard()
    private var storedInput: TerminalTouchKeyboardInputView?
    private var storedToolbarInput: TerminalTouchKeyboardToolbarInputView?
    /// iPadOS 27's UIInputView.init queries the first responder's input views,
    /// which read these back. Not `lazy`: a nested read would build another.
    private(set) var isBuildingInputView = false
    var input: TerminalTouchKeyboardInputView {
        if let storedInput { return storedInput }
        let created = buildingInputView(makeInput)
        storedInput = created
        return created
    }
    var toolbarInput: TerminalTouchKeyboardToolbarInputView {
        if let storedToolbarInput { return storedToolbarInput }
        let created = buildingInputView { TerminalTouchKeyboardToolbarInputView(keyboard: keyboard) }
        storedToolbarInput = created
        return created
    }
    private var storedController: TerminalTouchKeyboardInputController?
    /// Not `lazy`: UIKit can query input views re-entrantly while the controller
    /// is built, and a lazy store would release that nested instance mid-access.
    var controller: TerminalTouchKeyboardInputController {
        if let storedController { return storedController }
        let created = TerminalTouchKeyboardInputController(keyboardInput: input)
        if let storedController { return storedController }
        storedController = created
        return created
    }

    private init(window: UIWindow) {
        self.window = window
        // Another field bringing up the system keyboard ends a parked card.
        keyboardShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.owner == nil, self.parkedOwner != nil else { return }
                self.parkedOwner = nil
                self.dismissOverlay()
            }
        }
    }

    static func forWindow(_ window: UIWindow) -> TerminalTouchKeyboardWindowState {
        if let state = windows.object(forKey: window) { return state }
        let state = TerminalTouchKeyboardWindowState(window: window)
        windows.setObject(state, forKey: window)
        return state
    }

    func setInputRegion(_ region: CGRect?, fold: CGRect?) {
        if foldRegion != fold {
            let changesActivity = (foldRegion == nil) != (fold == nil)
            foldRegion = fold
            overlay?.foldRegion = fold
            // Never create the keyboard just to clear a flag it would default to.
            if changesActivity { keyboard.fillsHostHeight = fold != nil }
            NotificationCenter.default.post(name: .terminalFoldRegionDidChange, object: window)
        }
        guard inputRegion != region else { return }
        inputRegion = region
        overlay?.inputRegion = region
        storedInput?.setNeedsLayout()
    }

    func state(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        states.state(tabID: tabID, perTab: perTab) { TerminalFloatingKeyboardState() }
    }

    /// Select the state for a terminal and show it on the keyboard. The
    /// outgoing state's choices are captured first, so scope changes and
    /// per-tab switches always start from what the user last saw.
    func activate(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        snapshotDisplayedState()
        let selected = states.activate(tabID: tabID, perTab: perTab, make: { TerminalFloatingKeyboardState() }) {
            previous, selected in selected.copyChoices(from: previous)
        }
        display(selected)
        return selected
    }

    private func snapshotDisplayedState() {
        guard let displayedState else { return }
        displayedState.presentation = keyboard.presentationState
    }

    private func display(_ state: TerminalFloatingKeyboardState) {
        keyboard.setBackgroundEffectSurface(state.backgroundEffect)
        guard displayedState !== state else { return }
        displayedState = state
        let presentation = state.presentation ?? Self.initialPresentation()
        state.presentation = presentation
        keyboard.restorePresentationState(presentation)
        overlay?.updateState(state)
    }

    /// Fresh tabs start from the configured drawer default, not whichever
    /// state the keyboard happened to display before.
    private static func initialPresentation() -> TerminalTouchKeyboardModel.PresentationState {
        var initial = TerminalTouchKeyboardModel.PresentationState()
        if KeyboardToolbarManager.shared.drawerOpenByDefault {
            initial.toolbarDrawer = KeyboardToolbarManager.shared.drawerToggleMode == .cycle ? .cycling(0) : .stacked(1)
        }
        return initial
    }

    func dismissOverlay() {
        overlay?.detach()
        overlay = nil
    }

    private func makeKeyboard() -> TerminalTouchKeyboardView {
        let keyboard = TerminalTouchKeyboardView()
        keyboard.fillsHostHeight = foldRegion != nil
        keyboard.setBackgroundEffectSurface(nil)
        keyboard.onReclaimFocus = { [weak self] in self?.parkedOwner?.reclaimParkedTouchKeyboard() ?? false }
        keyboard.onModifiersChanged = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.modifiersChanged($0)) }
        keyboard.onDismiss = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.dismiss) }
        keyboard.onPinHidden = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.pinHidden) }
        keyboard.onSwitchKeyboard = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.switchToSystemKeyboard) }
        keyboard.onCompose = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.compose) }
        keyboard.onPaste = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.paste) }
        keyboard.onTabs = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.tabs) }
        keyboard.onCustomize = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.customize) }
        keyboard.onToolbarAction = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.toolbarAction($0)) }
        keyboard.onPlacementRequested = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.placementRequested($0)) }
        return keyboard
    }

    private func buildingInputView<View: UIInputView>(_ make: () -> View) -> View {
        let wasBuilding = isBuildingInputView
        isBuildingInputView = true
        defer { isBuildingInputView = wasBuilding }
        return make()
    }

    private func makeInput() -> TerminalTouchKeyboardInputView {
        let input = TerminalTouchKeyboardInputView(keyboard: keyboard)
        input.hostSize = { [weak self] in
            guard let self, let window = self.window else { return .zero }
            return TerminalKeyboardGeometry.inputRegion(self.inputRegion, in: window.bounds).size
        }
        input.onHeightChanged = { [weak self] in
            self?.toolbarInput.updateHeight()
            self?.owner?.handleTouchKeyboardEvent(.heightChanged)
        }
        input.onAppearanceChanged = { [weak self] in self?.toolbarInput.updateAppearance() }
        input.onNativePlacementChanged = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.nativePlacementChanged($0)) }
        input.shouldHideAfterDocking = { [weak self] in self?.owner?.touchKeyboardShouldHideAfterDocking == true }
        input.onDocked = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.docked) }
        return input
    }
}

@MainActor
final class TerminalFloatingKeyboardState {
    var backgroundEffect = TerminalKeyboardEffectSurface()
    var presentation: TerminalTouchKeyboardModel.PresentationState?
    var temporarilyUseSystemKeyboard = false
    var requestedWithHardware = false
    /// The last placement and card position, so a relaunch keeps the keyboard detached.
    private static let placementKey = "terminalTouchKeyboardDetached"
    private static let anchorKey = "terminalTouchKeyboardDetachedAnchor"
    var placement: TerminalTouchKeyboardModel.Placement =
        UserDefaults.standard.bool(forKey: TerminalFloatingKeyboardState.placementKey) ? .floating : .docked {
        didSet { UserDefaults.standard.set(placement == .floating, forKey: Self.placementKey) }
    }
    var anchor: CGPoint = {
        guard let stored = UserDefaults.standard.array(forKey: TerminalFloatingKeyboardState.anchorKey) as? [Double],
              stored.count == 2 else { return CGPoint(x: 1, y: 0.85) }
        return CGPoint(x: stored[0], y: stored[1])
    }()

    func saveAnchor() {
        UserDefaults.standard.set([Double(anchor.x), Double(anchor.y)], forKey: Self.anchorKey)
    }

    func copyChoices(from other: TerminalFloatingKeyboardState) {
        guard self !== other else { return }
        // Move the live renderer with the visible choices when changing scope.
        // Swap ownership so separate tabs never retain the same effect surface.
        let previousEffect = backgroundEffect
        backgroundEffect = other.backgroundEffect
        other.backgroundEffect = previousEffect
        presentation = other.presentation
        temporarilyUseSystemKeyboard = other.temporarilyUseSystemKeyboard
        requestedWithHardware = other.requestedWithHardware
        placement = other.placement
        anchor = other.anchor
    }
}

/// A scene-local overlay: only the floating card consumes touches. Everything
/// outside it continues to reach the terminal and the app's ordinary controls.
final class TerminalFloatingKeyboardOverlay: UIView {
    private let keyboard: TerminalTouchKeyboardView
    private var state: TerminalFloatingKeyboardState
    private var dragOrigin: CGRect?
    private var previousAvailable: CGRect?
    var isHostActive: (() -> Bool)?
    var inputRegion: CGRect? {
        didSet { if oldValue != inputRegion { dragOrigin = nil; setNeedsLayout() } }
    }
    /// The Duo's fold in window coordinates; the card settles beside it.
    var foldRegion: CGRect? {
        didSet { if oldValue != foldRegion { setNeedsLayout() } }
    }

    init(keyboard: TerminalTouchKeyboardView, state: TerminalFloatingKeyboardState) {
        self.keyboard = keyboard
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(keyboard)
        keyboard.onFloatingDrag = { [weak self] translation, ended in self?.move(translation, ended: ended) }
        keyboard.onFloatingDragCancelled = { [weak self] in self?.dragOrigin = nil }
        keyboard.onFloatingNudge = { [weak self] delta in self?.move(delta, ended: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateState(_ state: TerminalFloatingKeyboardState) {
        guard self.state !== state else { return }
        self.state = state
        dragOrigin = nil
        previousAvailable = nil
        setNeedsLayout()
    }

    private var available: CGRect {
        let region = inputRegion.map { convert($0, from: window) }
        // Landscape side insets hold the app's side controls; the card may cover them.
        let insets = UIEdgeInsets(top: safeAreaInsets.top, left: 0, bottom: safeAreaInsets.bottom, right: 0)
        return TerminalKeyboardGeometry.inputRegion(region, in: bounds.inset(by: insets))
            .insetBy(dx: 12, dy: 12)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard available.width > 0, available.height > 0 else { return }
        keyboard.floatingAvailableHeight = available.height
        var frame = settledFrame(TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor))
        if previousAvailable == available, keyboard.frame.height > 0,
           keyboard.frame.width == frame.width, keyboard.frame.height != frame.height {
            frame = settledFrame(TerminalTouchKeyboardModel.resizedFloatingFrame(keyboard.frame,
                height: frame.height, in: available))
            // Update the travel anchor too, otherwise the next layout would
            // move the card back to the old proportional position.
            state.anchor = TerminalTouchKeyboardModel.floatingAnchor(for: frame, in: available)
            state.saveAnchor()
        }
        previousAvailable = available
        if keyboard.frame.size != frame.size {
            if keyboard.frame.width != frame.width { keyboard.cancelInteraction(preservingModifiers: true) }
            dragOrigin = nil
        }
        keyboard.frame = frame
    }

    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isHostActive?() == true, !isHidden, alpha > 0.01,
              keyboard.frame.contains(point) else { return nil }
        return keyboard.hitTest(convert(point, to: keyboard), with: event)
    }

    private func move(_ translation: CGPoint, ended: Bool) {
        guard isHostActive?() == true else { return }
        if dragOrigin == nil { dragOrigin = keyboard.frame; keyboard.cancelInteraction(preservingModifiers: true) }
        guard let origin = dragOrigin else { return }
        let proposed = origin.offsetBy(dx: translation.x, dy: translation.y)
        state.anchor = TerminalTouchKeyboardModel.floatingAnchor(for: proposed, in: available)
        keyboard.frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if ended {
            dragOrigin = nil
            let settled = settledFrame(keyboard.frame)
            if settled != keyboard.frame {
                UIView.animate(withDuration: 0.2) { self.keyboard.frame = settled }
            }
            state.anchor = TerminalTouchKeyboardModel.floatingAnchor(for: settled, in: available)
            state.saveAnchor()
        }
    }

    private func settledFrame(_ frame: CGRect) -> CGRect {
        TerminalTouchKeyboardModel.floatingFrame(frame, avoiding: foldRegion.map { convert($0, from: window) }, in: available)
    }

    /// UIKit presents the card's menus from a view controller found above the
    /// button; a bare window subview has none, so the menus never appear.
    private weak var presentationHost: UIViewController?

    func attach(to window: UIWindow) {
        window.addSubview(self)
        guard let root = window.rootViewController else { return }
        let host = TerminalFloatingKeyboardPresentationHost()
        host.view = self
        root.addChild(host)
        host.didMove(toParent: root)
        presentationHost = host
        if #available(iOS 27.1, *) { root.setNeedsUpdateOfVerticalBarConfiguration() }
    }

    func detach() {
        if let host = presentationHost, let root = host.parent {
            host.willMove(toParent: nil)
            host.removeFromParent()
            if #available(iOS 27.1, *) { root.setNeedsUpdateOfVerticalBarConfiguration() }
        }
        // UIKit may already have mounted the compact toolbar host. A stale
        // overlay must not remove the keyboard from its new container.
        if keyboard.superview === self {
            keyboard.cancelInteraction(preservingModifiers: true)
            keyboard.onFloatingDrag = nil
            keyboard.onFloatingDragCancelled = nil
            keyboard.onFloatingNudge = nil
            keyboard.removeFromSuperview()
        }
        removeFromSuperview()
    }
}

/// Presents the card's menus. As the root's newest child it also becomes the one
/// the root asks about the vertical bar, so it passes on the app content's answer.
private final class TerminalFloatingKeyboardPresentationHost: UIViewController {
    @available(iOS 27.1, *)
    override var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        var content = parent?.children.first { $0 !== self }
        while let child = content?.childForPreferredVerticalBarBehavior { content = child }
        return content?.preferredVerticalBarBehavior ?? .automatic
    }
}

#endif
