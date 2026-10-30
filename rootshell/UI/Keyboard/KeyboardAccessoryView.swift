//
//  KeyboardAccessoryView.swift
//  rootshell
//
//  UIInputView wrapper for keyboard toolbar
//

import UIKit

class KeyboardAccessoryView: UIInputView {
    // MARK: - Properties

    private(set) var toolbarView: KeyboardToolbarView
    weak var delegate: KeyboardButtonDelegate? {
        didSet {
            toolbarView.delegate = delegate
        }
    }

    /// Callback when toolbar modifiers change
    var onModifiersChanged: ((KeyModifiers) -> Void)? {
        didSet {
            toolbarView.onModifiersChanged = onModifiersChanged
        }
    }

    /// Callback when dismiss button is tapped
    var onDismissRequested: (() -> Void)? {
        didSet {
            toolbarView.onDismissRequested = onDismissRequested
        }
    }

    /// Callback when toolbar collapse is requested
    var onCollapseRequested: (() -> Void)? {
        didSet {
            toolbarView.onCollapseRequested = onCollapseRequested
        }
    }

    /// Callback when the dismiss button is long-pressed to pin the keyboard hidden
    var onPinHiddenRequested: (() -> Void)? {
        didSet {
            toolbarView.onPinHiddenRequested = onPinHiddenRequested
        }
    }

    /// Callback when tab switcher button is tapped
    var onTabSwitcherRequested: (() -> Void)? {
        didSet {
            toolbarView.onTabSwitcherRequested = onTabSwitcherRequested
        }
    }

    /// Callback when compose button is tapped
    var onComposeRequested: (() -> Void)? {
        didSet {
            toolbarView.onComposeRequested = onComposeRequested
        }
    }

    /// Callback when toolbar settings button is tapped
    var onToolbarSettingsRequested: (() -> Void)? {
        didSet {
            toolbarView.onToolbarSettingsRequested = onToolbarSettingsRequested
        }
    }

    /// Callback when paste button is tapped
    var onPasteRequested: (() -> Void)? {
        didSet {
            toolbarView.onPasteRequested = onPasteRequested
        }
    }

    /// Callback when toggle full screen button is tapped
    var onToggleFullScreenRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleFullScreenRequested = onToggleFullScreenRequested
        }
    }

    /// Callback when toggle tab bar button is tapped
    var onToggleTabBarRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleTabBarRequested = onToggleTabBarRequested
        }
    }

    /// Callback when new connection button is tapped
    var onNewConnectionRequested: (() -> Void)? {
        didSet {
            toolbarView.onNewConnectionRequested = onNewConnectionRequested
        }
    }

    /// Callback when app settings button is tapped
    var onAppSettingsRequested: (() -> Void)? {
        didSet {
            toolbarView.onAppSettingsRequested = onAppSettingsRequested
        }
    }

    /// Callback when toggle mouse capture button is tapped
    var onToggleMouseCaptureRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleMouseCaptureRequested = onToggleMouseCaptureRequested
        }
    }

    /// Callback when AI agent button is tapped
    var onAIAgentRequested: (() -> Void)? {
        didSet {
            toolbarView.onAIAgentRequested = onAIAgentRequested
        }
    }

    /// Callback when the brightness-boost button is tapped
    var onBrightnessBoostRequested: (() -> Void)? {
        didSet {
            toolbarView.onBrightnessBoostRequested = onBrightnessBoostRequested
        }
    }

    /// Callback when the clipboard manager button is tapped
    var onClipboardManagerRequested: (() -> Void)? {
        didSet {
            toolbarView.onClipboardManagerRequested = onClipboardManagerRequested
        }
    }

    /// Callback when the file manager button is tapped
    var onFileManagerRequested: (() -> Void)? {
        didSet {
            toolbarView.onFileManagerRequested = onFileManagerRequested
        }
    }

    /// Callback when the HTTP capture button is tapped
    var onHTTPCaptureRequested: (() -> Void)? {
        didSet {
            toolbarView.onHTTPCaptureRequested = onHTTPCaptureRequested
        }
    }

    /// Callback when accessory layout changes and input views should refresh
    var onLayoutInvalidated: (() -> Void)?

    private var layoutChangeObserver: NSObjectProtocol?
    private var toolbarBottomConstraint: NSLayoutConstraint?

    /// Continuation of the toolbar's glass plate over the reserved
    /// home-indicator strip. Without it the strip exposes the system keyboard
    /// backdrop (UIKit draws one behind any input view), which reads as a
    /// foreign gray band under the toolbar. Hidden while nothing is reserved.
    private let bottomStripBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let bottomStripTintView = UIView()

    /// Height held open below the toolbar row so the row clears the home
    /// indicator. Owned by the accessory controller; 0 runs the row flush.
    /// UIKit pins the accessory's bottom edge and grows it upward, so the
    /// extra height lifts the row off the edge rather than pushing it under.
    private(set) var reservedBottomSafeArea: CGFloat = 0

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    private var bottomEdgePanGesture: UIScreenEdgePanGestureRecognizer?
    #endif

    // MARK: - Initialization

    init(sizes: KeyboardSizes) {
        toolbarView = KeyboardToolbarView(sizes: sizes)

        let frame = CGRect(
            x: 0,
            y: 0,
            width: 0,
            height: sizes.toolbar.height
        )

        super.init(frame: frame, inputViewStyle: .default)

        setupView()
        observeLayoutChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        let local = convert(point, to: toolbarView)
        return local.x >= toolbarView.plateFrame.minX && local.x <= toolbarView.plateFrame.maxX
    }

    deinit {
        if let observer = layoutChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupView() {
        // Both the terminal and VNC responders return this as inputAccessoryView.
        // Disable autoresizing-mask constraints so UIKit re-queries the intrinsic
        // height when drawer rows open or close and keeps the bottom keyboard edge
        // anchored while the accessory grows upward.
        translatesAutoresizingMaskIntoConstraints = false
        allowsSelfSizing = true
        backgroundColor = .clear

        bottomStripBlurView.translatesAutoresizingMaskIntoConstraints = false
        bottomStripBlurView.isUserInteractionEnabled = false
        bottomStripBlurView.isHidden = true
        bottomStripTintView.translatesAutoresizingMaskIntoConstraints = false
        bottomStripTintView.backgroundColor = toolbarView.glassTintColor(for: traitCollection)
        addSubview(bottomStripBlurView)
        bottomStripBlurView.contentView.addSubview(bottomStripTintView)
        attachToolbar()
        NSLayoutConstraint.activate([
            bottomStripBlurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomStripTintView.topAnchor.constraint(equalTo: bottomStripBlurView.contentView.topAnchor),
            bottomStripTintView.leadingAnchor.constraint(equalTo: bottomStripBlurView.contentView.leadingAnchor),
            bottomStripTintView.trailingAnchor.constraint(equalTo: bottomStripBlurView.contentView.trailingAnchor),
            bottomStripTintView.bottomAnchor.constraint(equalTo: bottomStripBlurView.contentView.bottomAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardAccessoryView, _: UITraitCollection) in
            self.bottomStripTintView.backgroundColor = self.toolbarView.glassTintColor(for: self.traitCollection)
        }

        // Propagate drawer state changes for height updates
        toolbarView.onDrawerStateChanged = { [weak self] in
            self?.invalidateLayoutAndNotify()
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let bottomEdgePanGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleBottomEdgePan(_:))
        )
        bottomEdgePanGesture.edges = .bottom
        bottomEdgePanGesture.cancelsTouchesInView = true
        bottomEdgePanGesture.isEnabled = false
        addGestureRecognizer(bottomEdgePanGesture)
        self.bottomEdgePanGesture = bottomEdgePanGesture
        #endif
    }

    /// Toolbar constraints, including the strip's, which hang off its plate.
    private func attachToolbar() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)
        let toolbarBottom = toolbarView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -reservedBottomSafeArea)
        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarBottom,
            bottomStripBlurView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            bottomStripBlurView.leadingAnchor.constraint(equalTo: toolbarView.plateLeadingAnchor),
            bottomStripBlurView.trailingAnchor.constraint(equalTo: toolbarView.plateTrailingAnchor),
        ])
        toolbarBottomConstraint = toolbarBottom
    }

    /// UIKit wraps this accessory in its own view controller, so the accessory
    /// cannot join another hierarchy. Its toolbar row can (below the Duo's fold).
    func lendToolbar() -> KeyboardToolbarView {
        toolbarView.removeFromSuperview()
        return toolbarView
    }

    func reclaimToolbar() {
        guard toolbarView.superview !== self else { return }
        toolbarView.removeFromSuperview()
        attachToolbar()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    @objc private func handleBottomEdgePan(_: UIScreenEdgePanGestureRecognizer) {
        // Recognition itself is the behavior: it cancels the toolbar control's
        // touch before touch-up, without performing an app action.
    }
    #endif

    /// Invalidate the intrinsic height before asking the active responder to
    /// reload its input views. UIKit then grows the accessory upward from the
    /// keyboard instead of retaining a stale concrete frame.
    private func invalidateLayoutAndNotify() {
        toolbarView.setNeedsLayout()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
        onLayoutInvalidated?()
    }

    private func observeLayoutChanges() {
        layoutChangeObserver = NotificationCenter.default.addObserver(
            forName: KeyboardToolbarManager.layoutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildToolbar()
        }
    }

    /// Rebuild the toolbar view in response to a layout configuration change.
    private func rebuildToolbar() {
        toolbarView.rebuildForCurrentWidth()
        invalidateLayoutAndNotify()
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        var size = toolbarView.intrinsicContentSize
        size.height += reservedBottomSafeArea
        return size
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: toolbarView.intrinsicContentSize.height + reservedBottomSafeArea
        )
    }

    // MARK: - Public Methods

    func updateForTraitCollection(_ traitCollection: UITraitCollection) {
        let newSizes = KeyboardSizes.current(traitCollection: traitCollection)
        toolbarView.updateSizes(newSizes)
        invalidateLayoutAndNotify()
    }

    /// Apply a new reserved strip height. Returns true when it changed, so the
    /// caller can decide whether the responder needs a `reloadInputViews()`.
    /// Deliberately does not fire `onLayoutInvalidated` — the controller applies
    /// this from inside its `inputAccessoryView` getter, and reloading the input
    /// views from there would reenter UIKit's accessory query.
    @discardableResult
    func setReservedBottomSafeArea(_ reserve: CGFloat) -> Bool {
        let clamped = max(0, reserve)
        guard abs(clamped - reservedBottomSafeArea) > 0.5 else { return false }
        reservedBottomSafeArea = clamped
        toolbarBottomConstraint?.constant = -clamped
        bottomStripBlurView.isHidden = clamped <= 0
        toolbarView.setBottomEdgeSquared(clamped > 0)
        toolbarView.setNeedsLayout()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
        return true
    }

    func setInteractionMode(_ mode: KeyboardToolbarInteractionMode) {
        toolbarView.setInteractionMode(mode)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        bottomEdgePanGesture?.isEnabled = mode == .screenEdge
        #endif
    }

    func setDismissButtonPinned(_ pinned: Bool) {
        toolbarView.setDismissButtonPinned(pinned)
    }

    func setDismissButtonShowsRestore(_ showsRestore: Bool) {
        toolbarView.setDismissButtonShowsRestore(showsRestore)
    }

    func setMouseCaptureOverrideActive(_ active: Bool) {
        toolbarView.setMouseCaptureOverrideActive(active)
    }
}
