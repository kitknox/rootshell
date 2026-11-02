#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Keeps UIKit's input region self-sizing, including while content floats in
/// the app window. Only the ordinary content view may move between containers.
final class TerminalTouchKeyboardInputView: UIInputView, UIGestureRecognizerDelegate {
    private let keyboard: TerminalTouchKeyboardView
    var hostSize: (() -> CGSize)?
    var shouldHideAfterDocking: (() -> Bool)?
    var onDocked: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?
    var onNativePlacementChanged: ((TerminalTouchKeyboardModel.Placement) -> Void)?
    private(set) var isNativeFloating = false
    private(set) var suppressed = false
    private var awaitingFloatingLayout = false
    /// A hardware keyboard minimized the floating card into a full-width
    /// strip. UIKit restores the floating container on disconnect; until
    /// then the strip must not be mistaken for a user's dock.
    private var resumesNativeFloating = false
    /// iPadOS keeps the floating choice across launches, and a launch with a
    /// hardware keyboard attached never shows it to us. Remember the last one
    /// we saw so the first disconnect can hold the keys back too.
    private static let lastNativeFloatingKey = "terminalTouchKeyboardLastNativeFloating"
    private var hasObservedNativeLayout = false
    /// A hold ran out on a full-width host, so that host is a real dock.
    private var floatingHoldExpired = false
    private var transitionFallback: DispatchWorkItem?
    private var transitionTask: Task<Void, Never>?
    private var heightConstraint: NSLayoutConstraint!
    private let floatingPanel = TerminalTouchKeyboardHostingPanel()
    /// Swallows taps on UIKit's handle: its tap opens a mode menu whose one entry
    /// only resets the position. UIKit's drag waits on its own tap, so that stays enabled.
    private lazy var handleTapGuard: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer()
        tap.delegate = self
        return tap
    }()
    private let modeSwitcherMute = TerminalKeyboardModeSwitcherMute()
    private var hostingGeneration = 0
    private var keyboardBottom: NSLayoutConstraint?
    private var measuredFooter: CGFloat = 0
    private weak var observedHost: UIView?
    private var hostBoundsObservation: NSKeyValueObservation?
    /// How far the card extends past this view into UIKit's floating footer,
    /// so its bottom edge sits where Apple's keyboard's does.
    private var footerOverlap: CGFloat {
        keyboard.usesSystemPlacement && isNativeFloating && keyboard.superview === self ? measuredFooter : 0
    }

    func setUsesSystemPlacement(_ value: Bool) {
        guard keyboard.usesSystemPlacement != value else { return }
        // Restore UIKit's mask before the content changes hosts.
        hostingGeneration += 1
        endFloatingHold()
        removeHandleTapGuard()
        modeSwitcherMute.restore()
        floatingPanel.detach()
        keyboard.usesSystemPlacement = value
        setNeedsLayout()
    }

    init(keyboard: TerminalTouchKeyboardView) {
        self.keyboard = keyboard
        super.init(frame: keyboard.frame, inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: keyboard.intrinsicContentSize.height)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        keyboard.useContainerSizing()
        keyboard.systemFloatingHandle = { [weak self] in self?.systemFloatingHandle() }
        keyboard.onAppearanceChanged = { [weak self] in
            self?.updateAppearance()
            self?.onAppearanceChanged?()
        }
        // The root tracks content height itself, whether or not a terminal
        // currently owns the keyboard. Settings can change it while unowned.
        keyboard.onHeightChanged = { [weak self] in
            self?.updateHeight()
            self?.onHeightChanged?()
        }
        updateAppearance()
        attachKeyboard()
        transitionTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                guard !animating else { continue }
                self.finishKeyboardTransition()
                // UIKit can replace the hosting item during its animation.
                if self.window != nil { self.updateFloatingPanel() }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { transitionTask?.cancel() }
    /// Zero while suppressed and while waiting for UIKit to restore a floating
    /// container: a full-width interim host then has nothing to show.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: suppressed || awaitingFloatingLayout ? 0 : max(0, keyboard.intrinsicContentSize.height - footerOverlap))
    }

    /// Touches on the part of the card inside UIKit's footer.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event)
            || (footerOverlap > 0 && !keyboard.isHidden && keyboard.frame.contains(point))
    }

    private var expectsNativeFloating: Bool {
        guard keyboard.usesSystemPlacement else { return false }
        if hasObservedNativeLayout { return isNativeFloating || resumesNativeFloating }
        return UserDefaults.standard.bool(forKey: Self.lastNativeFloatingKey)
    }

    func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        hostingGeneration += 1
        suppressed = value
        setNeedsLayout()
        keyboard.cancelInteraction(preservingModifiers: true)
        if !value && expectsNativeFloating { beginFloatingHold() }
        if keyboard.superview === self { keyboard.isHidden = value || awaitingFloatingLayout }
        updateAppearance()
        updateHeight()
    }

    /// Hold the keys back until a floating frame arrives, the show animation
    /// ends, or a short fallback elapses. UIKit can host the interim
    /// full-width strip without any keyboard animation at all.
    private func beginFloatingHold() {
        awaitingFloatingLayout = true
        transitionFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in self?.finishKeyboardTransition() }
        transitionFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: fallback)
    }

    private func endFloatingHold() {
        transitionFallback?.cancel()
        transitionFallback = nil
        awaitingFloatingLayout = false
        resumesNativeFloating = false
    }

    private func finishKeyboardTransition() {
        guard awaitingFloatingLayout else { return }
        // A genuine system docking must still be honored once the transition
        // finishes, even if UIKit never restores a narrow floating container.
        endFloatingHold()
        floatingHoldExpired = true
        updateHeight()
        setNeedsLayout()
    }

    func updateHeight() {
        let height = intrinsicContentSize.height
        keyboardBottom?.constant = footerOverlap
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        // A floating hosting item is only resized when its container lays out.
        if isNativeFloating { superview?.superview?.setNeedsLayout() }
    }

    private func updateAppearance() {
        backgroundColor = suppressed || awaitingFloatingLayout
            || (keyboard.isFloating && !UIAccessibility.isReduceTransparencyEnabled)
            ? .clear : keyboard.containerBackgroundColor
        overrideUserInterfaceStyle = keyboard.overrideUserInterfaceStyle
    }

    override func layoutSubviews() {
        // The native floating card drags by the switcher; see systemFloatingHandle.
        defer { modeSwitcherMute.update(input: self, enabled: !(keyboard.usesSystemPlacement && isNativeFloating)) }
        let size = hostSize?() ?? .zero
        // UIKit sends intermediate zero-size layouts while replacing input sets.
        // They are not a user's request to dock the floating keyboard.
        guard !suppressed, keyboard.superview === self, bounds.width > 0, size.width > 0 else {
            super.layoutSubviews()
            updateFloatingPanel()
            return
        }
        let floating = TerminalTouchKeyboardModel.isFloatingInput(
            width: bounds.width, hostWidth: size.width,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        if awaitingFloatingLayout && !floating {
            // On hardware disconnect UIKit can first reuse its full-width
            // hardware host. Do not render docked keys into that interim frame.
            keyboard.isHidden = true
            super.layoutSubviews()
            return
        }
        // Presenting a floating keyboard, UIKit can lay it out full width first.
        if !floating, !floatingHoldExpired, expectsNativeFloating,
           !(isNativeFloating && shouldHideAfterDocking?() == true) {
            beginFloatingHold()
            keyboard.isHidden = true
            updateAppearance()
            updateHeight()
            super.layoutSubviews()
            return
        }
        if floating {
            floatingHoldExpired = false
            endFloatingHold()
            updateAppearance()
        }
        if hasObservedNativeLayout == false || floating != isNativeFloating {
            hasObservedNativeLayout = true
            if keyboard.usesSystemPlacement { UserDefaults.standard.set(floating, forKey: Self.lastNativeFloatingKey) }
        }
        let docked = isNativeFloating && !floating
        let generation = hostingGeneration
        if docked && shouldHideAfterDocking?() == true {
            // A hardware keyboard minimized the floating card. Collapse the
            // existing self-sizing input root before it can grow to docked
            // height; replacing it with an empty UIView preserves the native
            // floating container's old frame on some iPadOS versions. Remember
            // the floating placement so the disconnect can restore it without
            // first rendering keys into the interim full-width host.
            isNativeFloating = false
            resumesNativeFloating = true
            setSuppressed(true)
            keyboard.setFloating(false)
            let dockingGeneration = hostingGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hostingGeneration == dockingGeneration,
                      !self.isNativeFloating, self.keyboard.superview === self else { return }
                self.onDocked?()
            }
            super.layoutSubviews()
            return
        }
        if floating != isNativeFloating {
            isNativeFloating = floating
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hostingGeneration == generation,
                      !self.suppressed, self.keyboard.superview === self,
                      self.isNativeFloating == floating else { return }
                self.onNativePlacementChanged?(floating ? .floating : .docked)
            }
        }
        // Use the owning app's input region, never the keyboard window's
        // current card height (which would feed back into row sizing).
        let availableHeight = size.height
        keyboard.floatingAvailableHeight = max(230, availableHeight - 48)
        keyboard.setFloating(floating)
        updateHeight()
        super.layoutSubviews()
        updateFloatingPanel()
        keyboard.isHidden = false
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window {
            hostingGeneration += 1
            floatingHoldExpired = false
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            removeHandleTapGuard()
            modeSwitcherMute.restore()
            floatingPanel.detach()
        } else {
            setNeedsLayout()
        }
    }

    /// UIKit keeps its floating-keyboard handle, hidden, in the hosting item. Touches
    /// routed to it run the native drag, so UIKit itself saves the new position.
    private func systemFloatingHandle() -> UIView? {
        modeSwitcherMute.restore()
        guard let host = superview,
              let handle = TerminalKeyboardModeSwitcherMute.modeSwitcher(in: host, excluding: self) else { return nil }
        var ancestor = handle.superview
        while let view = ancestor, view !== host { view.isHidden = false; ancestor = view.superview }
        if handleTapGuard.view !== handle {
            handleTapGuard.view?.removeGestureRecognizer(handleTapGuard)
            handle.addGestureRecognizer(handleTapGuard)
        }
        return handle
    }

    /// Apple's keyboard reuses the handle, so leave it untouched once our card leaves.
    private func removeHandleTapGuard() {
        handleTapGuard.view?.removeGestureRecognizer(handleTapGuard)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === handleTapGuard && otherGestureRecognizer.view === handleTapGuard.view
            && type(of: otherGestureRecognizer) == UITapGestureRecognizer.self
    }

    /// Clips UIKit's floating hosting item to the card, or hides the item while
    /// the card is elsewhere: its empty frame otherwise draws a stray line.
    private func updateFloatingPanel() {
        let size = hostSize?() ?? .zero
        guard window != nil, bounds.width > 0, size.width > 0,
              TerminalTouchKeyboardModel.isFloatingInput(width: bounds.width, hostWidth: size.width,
                                                         isPad: traitCollection.userInterfaceIdiom == .pad) else {
            removeHandleTapGuard()
            floatingPanel.detach()
            observedHost = nil
            hostBoundsObservation = nil
            return
        }
        let showsCard = keyboard.usesSystemPlacement && isNativeFloating && !suppressed && keyboard.superview === self
        if !showsCard { removeHandleTapGuard() }
        // UIKit adds and drops its footer without laying this view out.
        let observed = showsCard ? superview : nil
        if observedHost !== observed {
            observedHost = observed
            hostBoundsObservation = observed?.layer.observe(\.bounds) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.setNeedsLayout() }
            }
        }
        if showsCard, !keyboard.isHidden, bounds.height > 0, let host = superview,
           abs(host.bounds.width - bounds.width) < 1,
           abs(host.convert(host.bounds, to: nil).width - host.bounds.width) < 1 {
            // UIKit reserves a footer below a floating input for its handle, but
            // not on every layout, so it is measured each time.
            let footer = host.bounds.height - bounds.height
            let overlap = footer > 0.5 && footer < 100 ? footer : 0
            if abs(overlap - measuredFooter) > 0.5 {
                measuredFooter = overlap
                updateHeight()
            }
        }
        floatingPanel.update(input: self, content: showsCard ? keyboard : nil)
    }

    func attachKeyboard() {
        guard !keyboard.isToolbarOnly, keyboard.superview !== self else { return }
        // The system container can remain floating while our content lives in
        // the app overlay. Do not request docked height when reattaching to it.
        keyboard.setFloating(isNativeFloating)
        keyboard.isHidden = suppressed || awaitingFloatingLayout
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        let bottom = keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
        keyboardBottom = bottom
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            bottom
        ])
        updateHeight()
    }
}

/// The compact toolbar has its own host so a native floating input controller
/// can remain suppressed without inheriting its old card size or placement.
/// The window's single keyboard moves here only after UIKit mounts this host.
final class TerminalTouchKeyboardToolbarInputView: UIInputView {
    private let keyboard: TerminalTouchKeyboardView
    private var heightConstraint: NSLayoutConstraint!
    private let modeSwitcherMute = TerminalKeyboardModeSwitcherMute()
    var isActive = false
    private(set) var reservedBottomInset: CGFloat = 0

    init(keyboard: TerminalTouchKeyboardView) {
        self.keyboard = keyboard
        super.init(frame: .zero, inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboard.toolbarContentHeight + reservedBottomInset)
    }

    @discardableResult
    func setReservedBottomInset(_ value: CGFloat) -> Bool {
        guard reservedBottomInset != value else { return false }
        reservedBottomInset = value
        updateHeight()
        return true
    }

    func updateHeight() {
        let height = intrinsicContentSize.height
        guard heightConstraint.constant != height else { return }
        heightConstraint.constant = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func updateAppearance() {
        backgroundColor = keyboard.containerBackgroundColor
        overrideUserInterfaceStyle = keyboard.overrideUserInterfaceStyle
    }

    func attachKeyboard() {
        guard window != nil, isActive, keyboard.isToolbarOnly, keyboard.superview !== self else { return }
        keyboard.removeFromSuperview()
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        keyboard.isHidden = false
        updateAppearance()
        updateHeight()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { attachKeyboard() } else { modeSwitcherMute.restore() }
    }

    override func layoutSubviews() {
        attachKeyboard()
        super.layoutSubviews()
        updateAppearance()
        modeSwitcherMute.update(input: self, enabled: true)
    }
}

/// Retains a self-sizing input root across software/hardware presentation changes.
final class TerminalTouchKeyboardInputController: UIInputViewController {
    private let keyboardInput: TerminalTouchKeyboardInputView

    init(keyboardInput: TerminalTouchKeyboardInputView) {
        self.keyboardInput = keyboardInput
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { inputView = keyboardInput }
}

/// UIKit leaves its "..." mode switcher hit-testable inside the hidden keyboard
/// dock (iPhone landscape), where it swallows taps on our toolbar's leading key.
/// Hidden only while the dock is hidden and one of our inputs is hosted.
@MainActor
final class TerminalKeyboardModeSwitcherMute {
    private weak var switcher: UIView?
    /// Only a switcher this mute hid is ever shown again.
    private var hidSwitcher = false
    private var observations: [NSKeyValueObservation] = []

    static func modeSwitcher(in host: UIView, excluding input: UIView) -> UIView? {
        if String(describing: type(of: host)) == "UIKeyboardModeSwitcherView" { return host }
        for subview in host.subviews where subview !== input {
            if let found = modeSwitcher(in: subview, excluding: input) { return found }
        }
        return nil
    }

    func update(input: UIView, enabled: Bool) {
        guard enabled, input.window != nil, let host = input.superview,
              let found = Self.modeSwitcher(in: host, excluding: input),
              let dock = found.superview else {
            restore()
            return
        }
        if found !== switcher {
            restore()
            switcher = found
            // Tracked while our input is hosted: UIKit toggles the dock and
            // re-shows the switcher while rebuilding the input set.
            observations = [found.layer, dock.layer].map {
                $0.observe(\.isHidden) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.reapply() }
                }
            }
        }
        reapply()
    }

    private func reapply() {
        guard let switcher, let dock = switcher.superview else {
            restore()
            return
        }
        if dock.isHidden {
            guard !switcher.isHidden else { return }
            switcher.isHidden = true
            hidSwitcher = true
        } else if hidSwitcher {
            hidSwitcher = false
            switcher.isHidden = false
        }
    }

    func restore() {
        observations = []
        if hidSwitcher { switcher?.isHidden = false }
        hidSwitcher = false
        switcher = nil
    }
}

/// An app input view replaces the system keys, including their drag handle.
/// UIKit can retain a taller floating hosting item for its footer. Clip the
/// host's rendering to the card without changing its system-owned frame.
/// No keyboard-window frame or private selector is changed.
@MainActor
private final class TerminalTouchKeyboardHostingPanel {
    private weak var panel: UIView?
    private let cardMask = CAShapeLayer()
    private var originalMask: CALayer?

    /// Without `content`, the whole item is masked out.
    func update(input: UIView, content: UIView?) {
        guard let window = input.window else { detach(); return }
        // Stop before the full-screen tracking view. Only same-width ancestors
        // near the input's height belong to this keyboard's hosting item.
        // A self-sizing pass can temporarily leave an ancestor at its old
        // height. Once found, never probe downward again; climbing further up
        // is allowed, because a host chosen during presentation can itself be
        // an inner view.
        var candidate = input
        if let panel, panel.window === window, input.isDescendant(of: panel) { candidate = panel }
        while let parent = candidate.superview, parent !== window,
              abs(parent.bounds.width - input.bounds.width) < 1,
              parent.bounds.height >= input.bounds.height,
              parent.bounds.height <= input.bounds.height + 100 {
            candidate = parent
        }
        guard candidate !== input else { detach(); return }
        if panel !== candidate {
            detach()
            panel = candidate
            originalMask = candidate.layer.mask
            candidate.layer.mask = cardMask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardMask.frame = candidate.bounds
        cardMask.path = content.map {
            UIBezierPath(roundedRect: $0.convert($0.bounds, to: candidate), cornerRadius: $0.layer.cornerRadius).cgPath
        } ?? CGPath(rect: .zero, transform: nil)
        cardMask.fillColor = UIColor.black.cgColor
        CATransaction.commit()
    }

    func detach() {
        if let panel, panel.layer.mask === cardMask { panel.layer.mask = originalMask }
        panel = nil
        originalMask = nil
    }
}

#endif
