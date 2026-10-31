//
//  KeyboardToolbarView.swift
//  rootshell
//
//  Main keyboard toolbar view with customizable single-row layout and collapsible drawer.
//  Layout is driven by KeyboardToolbarManager.
//

import UIKit
import GhosttyKit
import os

// MARK: - UIGestureRecognizer Extension

extension UIGestureRecognizer {
    /// Cancels current touch tracking by toggling isEnabled
    func dropTouches() {
        if isEnabled {
            isEnabled = false
            isEnabled = true
        }
    }
}

// MARK: - Dismiss Button

private final class KeyboardDismissButton: KeyboardSymbolButton {
    private static let doubleTapInterval: TimeInterval = 0.28
    private static let longPressInterval: TimeInterval = 0.5

    private var pendingSingleTap: DispatchWorkItem?
    private var pendingLongPress: DispatchWorkItem?
    private var longPressTriggered = false
    private var awaitingRelease = false
    private var touchIsDown = false
    private var awaitingDoubleTapRelease = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard beginTouchInteraction(touches) else { return }
        SystemShiftReader.shared.noteTouchEvent(event)
        isHighlighted = true
        playHaptic()

        if let pendingSingleTap {
            pendingSingleTap.cancel()
            self.pendingSingleTap = nil
            pendingLongPress?.cancel()
            pendingLongPress = nil
            isHighlighted = false
            backgroundColor = .clear
            if interactionMode == .spacedBottom {
                awaitingDoubleTapRelease = true
            } else {
                delegate?.keyPressed("__dismissDouble__", modifiers: currentModifiers())
            }
            return
        }

        touchIsDown = true
        awaitingRelease = false
        longPressTriggered = false

        // If the finger is still down when the double-tap window expires,
        // defer the single tap to touchesEnded so a long press can preempt it.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.canDispatchTouchAction else { return }
            if self.touchIsDown && !self.validateTouchInteraction() { return }
            self.pendingSingleTap = nil
            if self.touchIsDown {
                self.awaitingRelease = true
            } else {
                self.delegate?.keyPressed(self.key, modifiers: self.currentModifiers())
            }
        }
        pendingSingleTap = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.doubleTapInterval,
            execute: workItem
        )

        let longPressItem = DispatchWorkItem { [weak self] in
            guard let self, self.validateTouchInteraction() else { return }
            self.pendingLongPress = nil
            self.pendingSingleTap?.cancel()
            self.pendingSingleTap = nil
            self.awaitingRelease = false
            self.longPressTriggered = true
            self.isHighlighted = false
            self.backgroundColor = .clear
            self.playHaptic()
            self.delegate?.keyPressed("__dismissLong__", modifiers: self.currentModifiers())
        }
        pendingLongPress = longPressItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.longPressInterval,
            execute: longPressItem
        )
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard validateTouchInteraction() else { return }
        defer { finishTouchTracking() }
        touchIsDown = false
        pendingLongPress?.cancel()
        pendingLongPress = nil
        isHighlighted = false

        if awaitingDoubleTapRelease {
            awaitingDoubleTapRelease = false
            delegate?.keyPressed("__dismissDouble__", modifiers: currentModifiers())
            return
        }

        if longPressTriggered {
            longPressTriggered = false
            return
        }

        // Double-tap window already elapsed while held — fire the single tap now.
        if awaitingRelease {
            awaitingRelease = false
            delegate?.keyPressed(key, modifiers: currentModifiers())
        }
    }

    override func cancelTouchInteraction() {
        super.cancelTouchInteraction()
        touchIsDown = false
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
        pendingLongPress?.cancel()
        pendingLongPress = nil
        longPressTriggered = false
        awaitingRelease = false
        awaitingDoubleTapRelease = false
        isHighlighted = false
    }
}

// MARK: - Drawer Row View

/// One drawer row: a horizontally scrolling (or centered) stack of keys with a
/// bottom hairline separator. Multiple rows stack vertically above the main row.
private final class DrawerRowView: UIView {
    let scrollView = UIScrollView()
    let stackView = UIStackView()
    private let separator = UIView()

    private var scrollLeadingConstraint: NSLayoutConstraint?
    private var scrollTrailingConstraint: NSLayoutConstraint?
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var stackCenterXConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?
    private var scrollingButtonCount: Int?
    private var scrollingSizes: KeyboardSizes?
    private var scrollingBehavior: ToolbarScrollBehavior?
    private var lastConfiguredViewportWidth: CGFloat?
    private var lastScrollingLayout: ToolbarPageLayout?

    init(edgePadding: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        separator.backgroundColor = .separator.withAlphaComponent(0.5)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 0
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        let scrollLeading = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgePadding)
        let scrollTrailing = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgePadding)
        scrollLeadingConstraint = scrollLeading
        scrollTrailingConstraint = scrollTrailing

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollLeading,
            scrollTrailing,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
        stackTrailingConstraint = stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
        stackCenterXConstraint = stackView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
        stackWidthConstraint = stackView.widthAnchor.constraint(equalToConstant: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let buttonCount = scrollingButtonCount,
              let sizes = scrollingSizes,
              let behavior = scrollingBehavior else { return }
        updateScrollingLayout(buttonCount: buttonCount, sizes: sizes, behavior: behavior)
    }

    /// Pin the stack to the scroll content edges so overflowing keys scroll horizontally.
    func configureForScrolling() {
        scrollView.isScrollEnabled = true
        scrollView.isPagingEnabled = false
        scrollView.contentInset = .zero
        scrollView.decelerationRate = .normal
        stackView.distribution = .fillEqually
        stackCenterXConstraint?.isActive = false
        stackLeadingConstraint?.isActive = true
        stackTrailingConstraint?.isActive = true
        stackWidthConstraint?.isActive = true
    }

    func configureScrollingLayout(buttonCount: Int, sizes: KeyboardSizes, behavior: ToolbarScrollBehavior) {
        scrollingButtonCount = buttonCount
        scrollingSizes = sizes
        scrollingBehavior = behavior
        lastConfiguredViewportWidth = nil
        lastScrollingLayout = nil
        updateScrollingLayout(buttonCount: buttonCount, sizes: sizes, behavior: behavior)
    }

    private func updateScrollingLayout(buttonCount: Int, sizes: KeyboardSizes, behavior: ToolbarScrollBehavior) {
        let viewportWidth = scrollView.bounds.width
        guard abs(viewportWidth - (lastConfiguredViewportWidth ?? -1)) > 0.5 else { return }

        let oldLayout = lastScrollingLayout
        let oldOffset = scrollView.contentOffset.x
        let firstVisibleItem = oldLayout.map {
            Int(max(0, oldOffset) / max(1, $0.cellWidth))
        } ?? 0

        guard buttonCount > 0, viewportWidth > 0 else {
            stackWidthConstraint?.constant = 0
            scrollView.isScrollEnabled = false
            scrollView.isPagingEnabled = false
            scrollView.contentInset = .zero
            scrollView.alwaysBounceHorizontal = false
            lastConfiguredViewportWidth = viewportWidth
            lastScrollingLayout = nil
            return
        }

        let layout = ToolbarPageLayout(
            viewportWidth: viewportWidth,
            buttonWidth: sizes.button.height,
            spacing: 4,
            itemCount: buttonCount
        )
        let cellWidth: CGFloat
        let trailingInset: CGFloat
        switch behavior {
        case .pages:
            cellWidth = viewportWidth / CGFloat(min(buttonCount, layout.capacity))
            let stackWidth = CGFloat(buttonCount) * cellWidth
            trailingInset = max(0, layout.contentWidth - stackWidth)
        case .continuous:
            cellWidth = buttonCount <= layout.capacity
                ? viewportWidth / CGFloat(buttonCount)
                : sizes.button.height + 4
            trailingInset = 0
        }
        let stackWidth = CGFloat(buttonCount) * cellWidth
        stackWidthConstraint?.constant = stackWidth
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: trailingInset)
        scrollView.isScrollEnabled = true
        scrollView.isPagingEnabled = behavior == .pages
        scrollView.decelerationRate = behavior == .pages ? .fast : .normal
        scrollView.alwaysBounceHorizontal = stackWidth + trailingInset > viewportWidth + 0.5
        lastConfiguredViewportWidth = viewportWidth
        lastScrollingLayout = layout

        if oldLayout != nil, !scrollView.isDragging, !scrollView.isDecelerating {
            let offset = behavior == .pages
                ? layout.offset(containing: firstVisibleItem)
                : CGFloat(firstVisibleItem) * cellWidth
            let maxOffset = max(0, stackWidth + trailingInset - viewportWidth)
            scrollView.setContentOffset(CGPoint(x: min(maxOffset, offset), y: 0), animated: false)
        }
    }

    /// Center the stack (arrow cluster) with scrolling disabled.
    func configureForCentering() {
        scrollingButtonCount = nil
        scrollingSizes = nil
        scrollingBehavior = nil
        lastConfiguredViewportWidth = nil
        lastScrollingLayout = nil
        scrollView.isScrollEnabled = false
        scrollView.isPagingEnabled = false
        scrollView.contentInset = .zero
        stackView.distribution = .fill
        stackLeadingConstraint?.isActive = false
        stackTrailingConstraint?.isActive = false
        stackWidthConstraint?.isActive = false
        stackCenterXConstraint?.isActive = true
    }

    func updateEdgePadding(_ edgePadding: CGFloat) {
        scrollLeadingConstraint?.constant = edgePadding
        scrollTrailingConstraint?.constant = -edgePadding
    }
}

// MARK: - KeyboardToolbarView

class KeyboardToolbarView: UIView {
    // MARK: - Properties

    weak var delegate: KeyboardButtonDelegate?

    /// Callback when active modifiers change
    /// A session-local return key after switching from the optional touch keyboard.
    /// This does not alter the user's saved toolbar layout.
    var onTouchKeyboardRequested: (() -> Void)? {
        didSet { rebuildForCurrentWidth() }
    }

    var onModifiersChanged: ((KeyModifiers) -> Void)?

    /// Callback when dismiss button is tapped
    var onDismissRequested: (() -> Void)?

    /// Callback when the dismiss button is double-tapped to collapse the toolbar
    var onCollapseRequested: (() -> Void)?

    /// Callback when the dismiss button is long-pressed to pin the keyboard hidden
    var onPinHiddenRequested: (() -> Void)?

    /// Callback when tab switcher button is tapped
    var onTabSwitcherRequested: (() -> Void)?

    /// Callback when compose button is tapped
    var onComposeRequested: (() -> Void)?

    /// Callback when toolbar settings button is tapped
    var onToolbarSettingsRequested: (() -> Void)?

    /// Callback when paste button is tapped
    var onPasteRequested: (() -> Void)?

    /// Callback when toggle full screen button is tapped
    var onToggleFullScreenRequested: (() -> Void)?

    /// Callback when toggle tab bar button is tapped
    var onToggleTabBarRequested: (() -> Void)?

    /// Callback when new connection button is tapped
    var onNewConnectionRequested: (() -> Void)?

    /// Callback when app settings button is tapped
    var onAppSettingsRequested: (() -> Void)?

    /// Callback when toggle mouse capture button is tapped
    var onToggleMouseCaptureRequested: (() -> Void)?

    /// Callback when AI agent button is tapped
    var onAIAgentRequested: (() -> Void)?

    /// Callback when the brightness-boost button is tapped
    var onBrightnessBoostRequested: (() -> Void)?

    /// Callback when the clipboard manager button is tapped
    var onClipboardManagerRequested: (() -> Void)?

    /// Callback when the file manager button is tapped
    var onFileManagerRequested: (() -> Void)?

    /// Callback when the HTTP capture button is tapped
    var onHTTPCaptureRequested: (() -> Void)?

    /// Callback when drawer opens/closes (for height updates)
    var onDrawerStateChanged: (() -> Void)?

    // Main toolbar views
    private let mainToolbarContainer = UIView()
    private let mainRowStackView = UIStackView()
    private let mainRowScrollView = UIScrollView()
    private let fixedControlsStackView = UIStackView()
    private let leftPinnedStackView = UIStackView()
    private let scrollContentView = UIView()
    private var sectionPlates: [UIVisualEffectView] = []
    private var pageLayout = ToolbarPageLayout(viewportWidth: 1, buttonWidth: 1, spacing: 0, itemCount: 0)
    private var displayedScrollScope: ToolbarScrollScope = .primary
    private var displayedAppearance: ToolbarAppearance = .single
    private var displayedScrollBehavior: ToolbarScrollBehavior = .pages
    private let topBorder = UIView()
    private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let tintOverlayView = UIView()

    // Drawer views
    private let drawerContainerView = UIView()
    private let drawerRowsStack = UIStackView()
    private var drawerRowViews: [DrawerRowView] = []
    private var drawerHeightConstraint: NSLayoutConstraint?
    private var backgroundLeadingConstraint: NSLayoutConstraint?
    private var backgroundTrailingConstraint: NSLayoutConstraint?
    private var backgroundBottomConstraint: NSLayoutConstraint?
    private var topBorderLeadingConstraint: NSLayoutConstraint?
    private var topBorderTrailingConstraint: NSLayoutConstraint?
    private var drawerContainerLeadingConstraint: NSLayoutConstraint?
    private var drawerContainerTrailingConstraint: NSLayoutConstraint?
    private var mainToolbarLeadingConstraint: NSLayoutConstraint?
    private var mainToolbarTrailingConstraint: NSLayoutConstraint?
    private var mainToolbarHeightConstraint: NSLayoutConstraint?

    private var sizes: KeyboardSizes

    private var modifierButtons: [KeyboardModifierButton] = []
    private var dismissButton: KeyboardSymbolButton?
    private var mouseCaptureToggleButton: KeyboardSymbolButton?
    #if os(visionOS)
    private var arrowToggleButton: KeyboardSymbolButton?
    #else
    private var arrowToggleButton: KeyboardArrowJoystickButton?
    #endif
    private var extraKeysToggleButton: KeyboardSymbolButton?
    private var activeModifiers: KeyModifiers = []
    private var modifierStates: [KeyModifiers: ModifierState] = [:]
    private var dismissButtonShowsRestore = false
    private var dismissButtonPinned = false
    private(set) var drawerState: DrawerState = .closed
    private var drawerManuallyClosed = false
    private var interactionMode: KeyboardToolbarInteractionMode = .accessory

    /// Track last known width to detect meaningful size changes
    private var lastBuiltWidth: CGFloat = 0
    private var effectiveDrawerRows: [[KeySlot]] = [[]]

    // MARK: - Initialization

    init(sizes: KeyboardSizes) {
        self.sizes = sizes

        super.init(frame: .zero)

        setupViews()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        // Buttons built on first layoutSubviews when we have a real width
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var isPhoneLandscape: Bool {
        isPhone && traitCollection.verticalSizeClass == .compact
    }

    private func currentEdgePadding() -> CGFloat {
        isPhoneLandscape ? 6 : 2
    }

    /// Embedded previews are already inset by their SwiftUI container.
    var isEmbeddedPreview = false {
        didSet { updateInsetsForCurrentTraits() }
    }

    var terminalViewportInScreen: CGRect? {
        didSet {
            guard oldValue != terminalViewportInScreen else { return }
            setNeedsLayout()
        }
    }

    var isWindowHosted = false {
        didSet {
            guard oldValue != isWindowHosted else { return }
            lastBuiltWidth = 0
            if isWindowHosted { setBottomEdgeSquared(false) }
            setNeedsLayout()
            dismissButton?.updateIcon(dismissButtonIconName)
        }
    }

    var followsTerminalViewport: Bool {
        isPhone && !isEmbeddedPreview && isWindowHosted && terminalViewportInScreen != nil
    }

    private func currentChromeHorizontalInsets() -> (left: CGFloat, right: CGFloat) {
        if isEmbeddedPreview { return (0, 0) }
        let left = isPhoneLandscape ? max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0) + 2 : 0
        let right = isPhoneLandscape ? max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0) + 2 : 0
        guard followsTerminalViewport, let frame = terminalViewportInScreen, let window else {
            return (left, right)
        }
        let local = convert(frame, from: window.screen.coordinateSpace)
        return (max(0, local.minX), max(0, bounds.width - local.maxX))
    }

    private func setupViews() {
        backgroundColor = .clear
        layer.cornerRadius = sizes.toolbar.cornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
        layer.masksToBounds = true

        // Background blur covers entire view (toolbar + drawer)
        if #available(iOS 26.0, *), isPhone {
            backgroundBlurView.effect = UIGlassEffect(style: .regular)
        }
        backgroundBlurView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBlurView.isUserInteractionEnabled = false
        backgroundBlurView.layer.cornerRadius = sizes.toolbar.cornerRadius
        backgroundBlurView.layer.cornerCurve = .continuous
        backgroundBlurView.clipsToBounds = true
        if #available(iOS 26.0, *), isPhone {
            backgroundBlurView.clipsToBounds = false
        }
        tintOverlayView.translatesAutoresizingMaskIntoConstraints = false
        tintOverlayView.isUserInteractionEnabled = false
        tintOverlayView.backgroundColor = glassTintColor(for: traitCollection)
        addSubview(backgroundBlurView)
        backgroundBlurView.contentView.addSubview(tintOverlayView)

        // Add subtle top border
        topBorder.backgroundColor = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        // --- Drawer container (above main toolbar) ---
        drawerContainerView.translatesAutoresizingMaskIntoConstraints = false
        drawerContainerView.clipsToBounds = true
        drawerContainerView.isHidden = true
        addSubview(drawerContainerView)

        // Vertical stack of drawer rows; the container's height constraint
        // (rows × drawerHeight) divides evenly between them.
        drawerRowsStack.axis = .vertical
        drawerRowsStack.spacing = 0
        drawerRowsStack.distribution = .fillEqually
        drawerRowsStack.translatesAutoresizingMaskIntoConstraints = false
        drawerContainerView.addSubview(drawerRowsStack)

        // --- Main toolbar container ---
        mainToolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainToolbarContainer)

        mainRowScrollView.accessibilityLabel = String(localized: "Toolbar Keys")
        mainRowScrollView.showsHorizontalScrollIndicator = false
        mainRowScrollView.alwaysBounceVertical = false
        mainRowScrollView.isDirectionalLockEnabled = true
        mainRowScrollView.contentInsetAdjustmentBehavior = .never
        mainRowScrollView.delegate = self
        mainToolbarContainer.addSubview(mainRowScrollView)
        mainRowScrollView.addSubview(scrollContentView)
        for stack in [leftPinnedStackView, mainRowStackView, fixedControlsStackView] {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fillEqually
            stack.spacing = 0
            mainToolbarContainer.addSubview(stack)
        }
        for _ in 0..<3 {
            let plate = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            if #available(iOS 26.0, *) { plate.effect = UIGlassEffect(style: .regular) }
            plate.isUserInteractionEnabled = false
            plate.clipsToBounds = true
            plate.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *), isPhone {
                plate.cornerConfiguration = .capsule()
                plate.clipsToBounds = false
            }
            sectionPlates.append(plate)
            mainToolbarContainer.insertSubview(plate, at: 0)
        }

        // Layout constraints
        let heightConstraint = drawerContainerView.heightAnchor.constraint(equalToConstant: 0)
        drawerHeightConstraint = heightConstraint
        let backgroundLeadingConstraint = backgroundBlurView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let backgroundTrailingConstraint = backgroundBlurView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.backgroundLeadingConstraint = backgroundLeadingConstraint
        self.backgroundTrailingConstraint = backgroundTrailingConstraint
        let backgroundBottom = backgroundBlurView.bottomAnchor.constraint(equalTo: bottomAnchor)
        backgroundBottomConstraint = backgroundBottom
        let topBorderLeadingConstraint = topBorder.leadingAnchor.constraint(equalTo: leadingAnchor)
        let topBorderTrailingConstraint = topBorder.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.topBorderLeadingConstraint = topBorderLeadingConstraint
        self.topBorderTrailingConstraint = topBorderTrailingConstraint
        let drawerContainerLeadingConstraint = drawerContainerView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let drawerContainerTrailingConstraint = drawerContainerView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.drawerContainerLeadingConstraint = drawerContainerLeadingConstraint
        self.drawerContainerTrailingConstraint = drawerContainerTrailingConstraint
        let toolbarHeightConstraint = mainToolbarContainer.heightAnchor.constraint(equalToConstant: sizes.toolbar.height)
        mainToolbarHeightConstraint = toolbarHeightConstraint
        let mainToolbarLeadingConstraint = mainToolbarContainer.leadingAnchor.constraint(equalTo: leadingAnchor)
        let mainToolbarTrailingConstraint = mainToolbarContainer.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.mainToolbarLeadingConstraint = mainToolbarLeadingConstraint
        self.mainToolbarTrailingConstraint = mainToolbarTrailingConstraint
        let constraints: [NSLayoutConstraint] = [
            // Background blur
            backgroundLeadingConstraint,
            backgroundTrailingConstraint,
            backgroundBlurView.topAnchor.constraint(equalTo: topAnchor),
            backgroundBottom,
            tintOverlayView.leadingAnchor.constraint(equalTo: backgroundBlurView.contentView.leadingAnchor),
            tintOverlayView.trailingAnchor.constraint(equalTo: backgroundBlurView.contentView.trailingAnchor),
            tintOverlayView.topAnchor.constraint(equalTo: backgroundBlurView.contentView.topAnchor),
            tintOverlayView.bottomAnchor.constraint(equalTo: backgroundBlurView.contentView.bottomAnchor),

            // Top border
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorderLeadingConstraint,
            topBorderTrailingConstraint,
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),

            // Drawer container (top of view)
            drawerContainerView.topAnchor.constraint(equalTo: topAnchor),
            drawerContainerLeadingConstraint,
            drawerContainerTrailingConstraint,
            heightConstraint,

            // Drawer rows stack fills the container
            drawerRowsStack.leadingAnchor.constraint(equalTo: drawerContainerView.leadingAnchor),
            drawerRowsStack.trailingAnchor.constraint(equalTo: drawerContainerView.trailingAnchor),
            drawerRowsStack.topAnchor.constraint(equalTo: drawerContainerView.topAnchor),
            drawerRowsStack.bottomAnchor.constraint(equalTo: drawerContainerView.bottomAnchor),

            // Main toolbar container (below drawer)
            mainToolbarContainer.topAnchor.constraint(equalTo: drawerContainerView.bottomAnchor),
            mainToolbarLeadingConstraint,
            mainToolbarTrailingConstraint,
            mainToolbarContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbarHeightConstraint,

        ]

        NSLayoutConstraint.activate(constraints)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardToolbarView, _: UITraitCollection) in
            self.tintOverlayView.backgroundColor = self.glassTintColor(for: self.traitCollection)
        }
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { (self: KeyboardToolbarView, _: UITraitCollection) in
            self.updateInsetsForCurrentTraits()
        }

        updateInsetsForCurrentTraits()
    }

    /// Square off the plate's bottom corners while the accessory extends the
    /// plate below this view (the reserved home-indicator strip), so the plate
    /// and the skirt meet without a rounded seam.
    func setBottomEdgeSquared(_ squared: Bool) {
        let squared = squared && !isWindowHosted
        let corners: CACornerMask = squared
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner,
               .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.maskedCorners = corners
        backgroundBlurView.layer.maskedCorners = corners
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateInsetsForCurrentTraits()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouchInteractions(in: self) }
        updateInsetsForCurrentTraits()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        cancelTouchInteractions(in: self)
    }

    @objc private func applicationWillResignActive() {
        cancelTouchInteractions(in: self)
    }

    private func cancelTouchInteractions(in view: UIView) {
        (view as? KeyboardButton)?.cancelTouchInteraction()
        (view as? KeyboardArrowJoystickButton)?.cancelTouchInteraction()
        for subview in view.subviews {
            cancelTouchInteractions(in: subview)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateInsetsForCurrentTraits()
        let floating = followsTerminalViewport || (isEmbeddedPreview && isPhone)
        backgroundBlurView.layer.cornerRadius = floating ? min(bounds.height / 2, sizes.toolbar.height / 2) : sizes.toolbar.cornerRadius
        layer.cornerRadius = backgroundBlurView.layer.cornerRadius
        backgroundBlurView.layer.borderWidth = floating ? 0.5 : 0
        backgroundBlurView.layer.borderColor = UIColor.label.withAlphaComponent(0.18).cgColor
        if #available(iOS 26.0, *), isPhone {
            backgroundBlurView.cornerConfiguration = .capsule(maximumRadius: sizes.toolbar.height / 2)
            backgroundBlurView.layer.borderWidth = 0
            layer.masksToBounds = !floating
        }
        topBorder.isHidden = floating || displayedAppearance == .separate
        let insets = currentChromeHorizontalInsets()
        let width = bounds.width - insets.left - insets.right - currentEdgePadding() * 2
        guard width > 0 else { return }

        // Rebuild buttons when width changes meaningfully (e.g. rotation)
        if abs(width - lastBuiltWidth) > 0.5 {
            rebuildForCurrentWidth()
        }
        layoutKeySections(preservePosition: true)
    }

    private func updateInsetsForCurrentTraits() {
        let edgePadding = currentEdgePadding()
        let chromeInsets = currentChromeHorizontalInsets()
        backgroundLeadingConstraint?.constant = chromeInsets.left
        backgroundTrailingConstraint?.constant = -chromeInsets.right
        topBorderLeadingConstraint?.constant = chromeInsets.left
        topBorderTrailingConstraint?.constant = -chromeInsets.right
        drawerContainerLeadingConstraint?.constant = chromeInsets.left
        drawerContainerTrailingConstraint?.constant = -chromeInsets.right
        mainToolbarLeadingConstraint?.constant = chromeInsets.left
        mainToolbarTrailingConstraint?.constant = -chromeInsets.right
        for row in drawerRowViews {
            row.updateEdgePadding(edgePadding)
        }
    }

    // MARK: - Button Building (Manager-Driven)

    /// Rebuild the entire toolbar from the manager's current effective layout.
    func rebuildForCurrentWidth() {
        let width = bounds.width
        guard width > 0 else { return }

        let manager = KeyboardToolbarManager.shared

        // Clear existing main row buttons (preserve modifier tracking)
        cancelTouchInteractions(in: mainToolbarContainer)
        modifierButtons.removeAll { $0.isDescendant(of: mainToolbarContainer) }
        for stack in [leftPinnedStackView, mainRowStackView, fixedControlsStackView] {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }

        // Reset tracked references
        dismissButton = nil
        mouseCaptureToggleButton = nil
        arrowToggleButton = nil
        extraKeysToggleButton = nil

        // Build main row from effective slots
        let edgePadding = currentEdgePadding()
        let chromeInsets = currentChromeHorizontalInsets()
        let availableWidth = width - edgePadding * 2 - chromeInsets.left - chromeInsets.right
        guard availableWidth > 0 else { return }
        lastBuiltWidth = availableWidth
        displayedScrollScope = manager.config.scrollScope
        displayedAppearance = manager.config.appearance
        displayedScrollBehavior = manager.config.scrollBehavior
        let layout = manager.effectiveLayout(availableWidth: availableWidth,
            reservedMainRowSlots: onTouchKeyboardRequested == nil ? 0 : 1,
            sizes: sizes, scrollsMainRow: true)
        effectiveDrawerRows = layout.drawers
        let mainSlots = layout.main
        mainRowScrollView.isScrollEnabled = true
        mainRowScrollView.isPagingEnabled = displayedScrollBehavior == .pages
        mainRowScrollView.decelerationRate = displayedScrollBehavior == .pages ? .fast : .normal
        for stack in [leftPinnedStackView, mainRowStackView, fixedControlsStackView] {
            let scrolls = stack === mainRowStackView || displayedScrollScope == .all
            (scrolls ? scrollContentView : mainToolbarContainer).addSubview(stack)
        }
        if onTouchKeyboardRequested != nil {
            let button = KeyboardSymbolButton(key: "__touchKeyboard__",
                display: .icon("keyboard.badge.ellipsis"), sizes: sizes)
            button.accessibilityLabel = String(localized: "Use Terminal Keyboard")
            button.delegate = self
            addToolbarButton(button, to: mainRowStackView)
        }
        for slot in mainSlots {
            if let button = createButtonForSlot(slot) {
                addToolbarButton(button, to: mainRowStackView)
            }
        }
        for (slots, stack) in [(layout.left, leftPinnedStackView), (layout.right, fixedControlsStackView)] {
            for slot in slots {
                if let button = createButtonForSlot(slot) { addToolbarButton(button, to: stack) }
            }
        }
        layoutKeySections(preservePosition: true)
        applyBottomEdgeKeyDispatchMode(in: mainToolbarContainer)
        Ghostty.logger.debug("KeyboardToolbar: rebuilt scope \(self.displayedScrollScope.rawValue, privacy: .public), style \(self.displayedAppearance.rawValue, privacy: .public), scroll \(self.displayedScrollBehavior.rawValue, privacy: .public), primary \(mainSlots.count, privacy: .public), left \(layout.left.count, privacy: .public), right \(layout.right.count, privacy: .public), width \(availableWidth, privacy: .public)")

        // Clamp drawer state to the current row count (settings may have reduced it)
        let rowCount = manager.drawerRowCount
        switch drawerState {
        case .stacked(let count) where count > rowCount:
            drawerState = .stacked(count: rowCount)
        case .cycling(let index) where index >= rowCount:
            drawerState = .cycling(index: rowCount - 1)
        default:
            break
        }

        // Open by default if setting is enabled (first drawer row only)
        if drawerState == .closed && manager.drawerOpenByDefault {
            if drawerManuallyClosed {
                Ghostty.logger.debug("KeyboardToolbar: open-by-default suppressed after manual close")
            } else {
                drawerState = manager.drawerToggleMode == .cycle ? .cycling(index: 0) : .stacked(count: 1)
                Ghostty.logger.debug("KeyboardToolbar: open-by-default applied mode \(manager.drawerToggleMode.rawValue, privacy: .public), row 1")
            }
        }

        // Rebuild drawer rows (also the repopulate path after a layout change)
        applyDrawerState()
    }

    private func layoutKeySections(preservePosition: Bool) {
        let stacks = [leftPinnedStackView, mainRowStackView, fixedControlsStackView]
        let counts = stacks.map { $0.arrangedSubviews.count }
        let area = mainToolbarContainer.bounds.insetBy(dx: currentEdgePadding(), dy: 0)
        guard area.width > 0, area.height > 0 else { return }
        let diameter = sizes.button.height
        let sectionGap: CGFloat = 4
        let pinCount = counts[0] + counts[2]
        let pinGaps = CGFloat((counts[0] > 0 ? 1 : 0) + (counts[2] > 0 ? 1 : 0)) * sectionGap
        // Fixed pins share the available width while retaining one full middle
        // key. This also keeps every pin reachable after a narrow resize.
        let pinCell = min(diameter + 4, max(1, (area.width - pinGaps - (counts[1] > 0 ? diameter + 4 : 0)) / CGFloat(max(1, pinCount))))
        let leftWidth = CGFloat(counts[0]) * pinCell
        let rightWidth = CGFloat(counts[2]) * pinCell
        let scrollsAll = displayedScrollScope == .all
        let scrollFrame = scrollsAll ? area : CGRect(
            x: area.minX + leftWidth + (counts[0] > 0 ? sectionGap : 0), y: area.minY,
            width: max(1, area.width - leftWidth - rightWidth - pinGaps), height: area.height)
        let scrollCount = scrollsAll ? counts.reduce(0, +) : counts[1]
        let oldLayout = pageLayout
        pageLayout = ToolbarPageLayout(viewportWidth: scrollFrame.width, buttonWidth: diameter, spacing: 4, itemCount: scrollCount)
        let paged = displayedScrollBehavior == .pages
        let cellWidth = paged ? pageLayout.cellWidth : max(diameter + 4, scrollFrame.width / CGFloat(max(1, scrollCount)))
        mainRowScrollView.frame = scrollFrame
        let clipsToScrollCapsule = displayedAppearance == .separate && !scrollsAll
        mainRowScrollView.layer.cornerCurve = .continuous
        mainRowScrollView.layer.cornerRadius = clipsToScrollCapsule ? area.height / 2 : 0
        let contentWidth = paged ? pageLayout.contentWidth : max(scrollFrame.width, CGFloat(scrollCount) * cellWidth)
        scrollContentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: area.height)
        mainRowScrollView.contentSize = scrollContentView.bounds.size
        mainRowScrollView.alwaysBounceHorizontal = contentWidth > scrollFrame.width + 0.5
        if scrollsAll {
            var x: CGFloat = 0
            for (stack, count) in zip(stacks, counts) {
                stack.frame = CGRect(x: x, y: 0, width: CGFloat(count) * cellWidth, height: area.height)
                x = stack.frame.maxX
            }
        } else {
            leftPinnedStackView.frame = CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
            fixedControlsStackView.frame = CGRect(x: area.maxX - rightWidth, y: area.minY, width: rightWidth, height: area.height)
            mainRowStackView.frame = CGRect(x: 0, y: 0, width: CGFloat(counts[1]) * cellWidth, height: area.height)
        }
        for stack in stacks {
            stack.layoutIfNeeded()
            for cell in stack.arrangedSubviews {
                let scale = min(1, max(1, cell.bounds.width - 2) / diameter)
                cell.subviews.first?.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
        let maxOffset = max(0, contentWidth - scrollFrame.width)
        if preservePosition, abs(oldLayout.viewportWidth - pageLayout.viewportWidth) > 0.5 {
            let firstItem = Int(max(0, mainRowScrollView.contentOffset.x) / max(1, oldLayout.cellWidth))
            let offset = paged ? pageLayout.offset(containing: firstItem) : CGFloat(firstItem) * cellWidth
            mainRowScrollView.setContentOffset(CGPoint(x: min(maxOffset, offset), y: 0), animated: false)
        } else if !mainRowScrollView.isDragging && !mainRowScrollView.isDecelerating {
            let bounded = min(maxOffset, max(0, mainRowScrollView.contentOffset.x))
            let offset = paged ? (bounded / pageLayout.viewportWidth).rounded() * pageLayout.viewportWidth : bounded
            mainRowScrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
        let separate = displayedAppearance == .separate
        for (index, plate) in sectionPlates.enumerated() {
            let stack = stacks[index]
            let parent = scrollsAll ? scrollContentView : mainToolbarContainer
            if plate.superview !== parent { parent.insertSubview(plate, at: 0) }
            plate.isHidden = !separate || counts[index] == 0
            guard counts[index] > 0 else { plate.frame = .zero; continue }
            if index == 1 && !scrollsAll {
                // The middle capsule stays in place while its keys page.
                plate.frame = scrollFrame
            } else {
                plate.frame = scrollsAll ? stack.frame.insetBy(dx: 2, dy: 0) : stack.frame
            }
            plate.layer.cornerRadius = area.height / 2
            plate.layer.borderWidth = 0.5
            plate.layer.borderColor = UIColor.label.withAlphaComponent(0.18).cgColor
            if #available(iOS 26.0, *), isPhone {
                plate.layer.borderWidth = 0
            }
            plate.contentView.backgroundColor = glassTintColor(for: traitCollection)
        }
        backgroundBlurView.isHidden = separate && visibleDrawerRowCount == 0
        backgroundBottomConstraint?.constant = separate ? -sizes.toolbar.height : 0
        if separate { backgroundBlurView.layer.borderWidth = 0 }
    }

    private func addToolbarButton(_ button: UIView, to stack: UIStackView) {
        let cell = UIView()
        let circle = UIView()
        let diameter = sizes.button.height
        circle.backgroundColor = UIColor { traits in
            (traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(0.035)
        }
        circle.layer.cornerRadius = diameter / 2
        circle.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(button)
        cell.addSubview(circle)
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            circle.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.heightAnchor.constraint(equalToConstant: diameter),
            circle.widthAnchor.constraint(equalToConstant: diameter),
            circle.heightAnchor.constraint(equalToConstant: diameter),
            button.leadingAnchor.constraint(equalTo: circle.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: circle.trailingAnchor),
            button.topAnchor.constraint(equalTo: circle.topAnchor),
            button.bottomAnchor.constraint(equalTo: circle.bottomAnchor),
        ])
        stack.addArrangedSubview(cell)
    }

    private func createButtonForSlot(_ slot: KeySlot) -> UIView? {
        switch slot {
        case .builtIn(let keyID):
            return createButtonForKeyID(keyID)
        case .custom(let uuid):
            return createCustomKeyButton(uuid: uuid)
        }
    }

    private func createButtonForKeyID(_ keyID: KeyID) -> UIView? {
        switch keyID {
        case .esc, .ctrl, .alt, .shift, .cmd:
            return createModifierButton(for: keyID.keyDefinition)
        case .tab:
            return createTabButton()
        case .arrowDrawerToggle:
            return createArrowDrawerToggleButton()
        case .arrowUp:
            return createArrowButton(icon: "arrow.up", key: "\u{1B}[A")
        case .arrowDown:
            return createArrowButton(icon: "arrow.down", key: "\u{1B}[B")
        case .arrowLeft:
            return createArrowButton(icon: "arrow.left", key: "\u{1B}[D")
        case .arrowRight:
            return createArrowButton(icon: "arrow.right", key: "\u{1B}[C")
        case .dismiss:
            return createDismissButton()
        case .tabSwitcher:
            return createTabSwitcherButton()
        case .compose:
            return createComposeButton()
        case .writingAssistance:
            return KeyboardWritingAssistanceButton(sizes: sizes)
        case .toolbarSettings:
            return createToolbarSettingsButton()
        case .paste:
            return createPasteButton()
        case .voiceAgent:
            return createVoiceAgentButton()
        case .toggleFullScreen:
            return createToggleFullScreenButton()
        case .toggleTabBar:
            return createToggleTabBarButton()
        case .newConnection:
            return createNewConnectionButton()
        case .appSettings:
            return createAppSettingsButton()
        case .toggleMouseCapture:
            return createToggleMouseCaptureButton()
        case .aiAgent:
            return createAIAgentButton()
        case .brightnessBoost:
            return createBrightnessBoostButton()
        case .clipboardManager:
            return createClipboardManagerButton()
        case .fileManager:
            return createFileManagerButton()
        case .httpCapture:
            return createHTTPCaptureButton()
        case .dictation:
            guard DictationSupport.isEnabled else { return nil }
            let button = KeyboardSymbolButton(key: keyID.keyValue, display: .icon("mic"), sizes: sizes)
            button.delegate = self
            return button
        case .drawerToggle:
            return createExtraKeysDrawerToggleButton()
        default:
            // Symbol keys — single character text buttons
            return createTextButton(text: keyID.keyValue)
        }
    }

    private func createCustomKeyButton(uuid: UUID) -> UIView? {
        let manager = KeyboardToolbarManager.shared
        guard let customKey = manager.customKey(for: uuid) else { return nil }

        let key = "__custom_\(uuid.uuidString)__"
        let display: KeyboardSymbolButton.DisplayType
        if let iconName = customKey.iconName {
            display = .icon(iconName)
        } else {
            display = .text(String(customKey.label.prefix(2)))
        }

        let button = KeyboardSymbolButton(
            key: key,
            display: display,
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createArrowButton(icon: String, key: String) -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: key,
            display: .icon(icon),
            sizes: sizes
        )
        button.delegate = self
        button.shouldAutoRepeat = true
        return button
    }

    private func createModifierButton(for keyDef: KeyDefinition) -> KeyboardModifierButton {
        let title: String
        let systemImage: String?

        switch keyDef {
        case .esc:
            title = "Esc"
            systemImage = "escape"
        case .ctrl:
            title = "Ctrl"
            systemImage = "control"
        case .alt:
            title = "Alt"
            systemImage = "option"
        case .shift:
            title = "Shift"
            systemImage = "shift"
        case .cmd:
            title = "Cmd"
            systemImage = "command"
        default:
            title = keyDef.keyValue
            systemImage = nil
        }

        let button = KeyboardModifierButton(
            title: title,
            systemImage: systemImage,
            modifier: keyDef.modifier,
            sizes: sizes
        )

        button.delegate = self
        button.onStateChange = { [weak self] state in
            self?.updateModifierState(keyDef.modifier, state: state)
        }

        // Initialize from current state if this modifier is already active
        if let modifier = keyDef.modifier, let state = modifierStates[modifier] {
            button.modifierState = state
        }

        modifierButtons.append(button)
        return button
    }

    private func createTabButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "\t",
            display: .icon("arrow.right.to.line"),
            sizes: sizes
        )
        button.delegate = self
        button.shouldAutoRepeat = true
        return button
    }

    private func createTextButton(text: String) -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: text,
            display: .text(text),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createDismissButton() -> KeyboardSymbolButton {
        let button = KeyboardDismissButton(
            key: "__dismiss__",
            display: .icon("chevron.down"),
            sizes: sizes
        )
        button.delegate = self
        button.updateIcon(dismissButtonIconName)
        dismissButton = button
        return button
    }

    private func createTabSwitcherButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__tabswitcher__",
            display: .icon("rectangle.stack"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    #if os(visionOS)
    private func createArrowDrawerToggleButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__arrowDrawer__",
            display: .icon("arrow.up.and.down.and.arrow.left.and.right"),
            sizes: sizes
        )
        button.delegate = self
        arrowToggleButton = button
        return button
    }
    #else
    private func createArrowDrawerToggleButton() -> KeyboardArrowJoystickButton {
        let button = KeyboardArrowJoystickButton(sizes: sizes)
        button.delegate = self
        button.onDrawerToggle = { [weak self] in
            self?.handleArrowsToggle()
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        arrowToggleButton = button
        return button
    }
    #endif

    private func createExtraKeysDrawerToggleButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__extraDrawer__",
            display: .icon("ellipsis"),
            sizes: sizes
        )
        button.delegate = self
        extraKeysToggleButton = button
        return button
    }

    private func createComposeButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__compose__",
            display: .icon("character.cursor.ibeam"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createToolbarSettingsButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__toolbarSettings__",
            display: .icon("gearshape"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createPasteButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__paste__",
            display: .icon("doc.on.clipboard"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createVoiceAgentButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__voiceAgent__",
            display: .icon("waveform.circle"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createToggleFullScreenButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__toggleFullScreen__",
            display: .icon("arrow.up.left.and.arrow.down.right"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createToggleTabBarButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__toggleTabBar__",
            display: .icon("menubar.rectangle"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createNewConnectionButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__newConnection__",
            display: .icon("plus"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createAppSettingsButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__appSettings__",
            display: .icon("slider.horizontal.3"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createToggleMouseCaptureButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__toggleMouseCapture__",
            display: .icon("computermouse"),
            sizes: sizes
        )
        button.delegate = self
        mouseCaptureToggleButton = button
        return button
    }

    private func createAIAgentButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__aiAgent__",
            display: .icon("sparkles"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createBrightnessBoostButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__brightnessBoost__",
            display: .icon("sun.max"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createClipboardManagerButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__clipboardManager__",
            display: .icon("list.clipboard"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createFileManagerButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: "__fileManager__",
            display: .icon("folder.badge.gearshape"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    private func createHTTPCaptureButton() -> KeyboardSymbolButton {
        let button = KeyboardSymbolButton(
            key: KeyID.httpCapture.keyValue,
            display: .icon("network.badge.shield.half.filled"),
            sizes: sizes
        )
        button.delegate = self
        return button
    }

    // MARK: - Drawer Management

    /// Runtime drawer open state. `stacked(count)` shows extra-keys drawers
    /// 1...count with drawer 1 adjacent to the main row; `cycling(index)` shows
    /// a single row with that drawer's contents; `arrows` is the joystick row.
    enum DrawerState: Equatable {
        case closed
        case arrows
        case stacked(count: Int)
        case cycling(index: Int)
    }

    private var visibleDrawerRowCount: Int {
        switch drawerState {
        case .closed: return 0
        case .arrows, .cycling: return 1
        case .stacked(let count): return count
        }
    }

    private var isExtraKeysDrawerOpen: Bool {
        switch drawerState {
        case .stacked, .cycling: return true
        case .closed, .arrows: return false
        }
    }

    /// The "…" button. Stack mode reveals one more row per press and collapses
    /// once all rows are open; cycle mode swaps the single row's contents. A
    /// mid-session mode change simply closes on the next press.
    private func handleExtraKeysToggle() {
        let manager = KeyboardToolbarManager.shared
        let rowCount = manager.drawerRowCount
        let previousState = drawerState
        switch drawerState {
        case .closed, .arrows:
            drawerState = manager.drawerToggleMode == .cycle ? .cycling(index: 0) : .stacked(count: 1)
        case .stacked(let count):
            drawerState = (manager.drawerToggleMode == .stack && count < rowCount)
                ? .stacked(count: count + 1) : .closed
        case .cycling(let index):
            drawerState = (manager.drawerToggleMode == .cycle && index + 1 < rowCount)
                ? .cycling(index: index + 1) : .closed
        }
        drawerManuallyClosed = drawerState == .closed
        logDrawerTransition(from: previousState, action: "extra-keys", mode: manager.drawerToggleMode.rawValue)
        applyDrawerState()
    }

    private func handleArrowsToggle() {
        let previousState = drawerState
        drawerState = (drawerState == .arrows) ? .closed : .arrows
        drawerManuallyClosed = drawerState == .closed
        logDrawerTransition(from: previousState, action: "arrows", mode: "arrows")
        applyDrawerState()
    }

    private func logDrawerTransition(from previousState: DrawerState, action: String, mode: String) {
        let selectedRow: String
        let keyCount: Int
        switch drawerState {
        case .closed:
            selectedRow = "none"
            keyCount = 0
        case .arrows:
            selectedRow = "arrows"
            keyCount = 4
        case .stacked(let count):
            let index = count - 1
            selectedRow = "\(count)"
            keyCount = effectiveDrawerRows.indices.contains(index) ? effectiveDrawerRows[index].count : 0
        case .cycling(let index):
            selectedRow = "\(index + 1)"
            keyCount = effectiveDrawerRows.indices.contains(index) ? effectiveDrawerRows[index].count : 0
        }
        Ghostty.logger.debug("KeyboardToolbar: drawer action \(action, privacy: .public), mode \(mode, privacy: .public), from \(self.drawerStateName(previousState), privacy: .public), to \(self.drawerStateName(self.drawerState), privacy: .public), row \(selectedRow, privacy: .public), keys \(keyCount, privacy: .public)")
    }

    private func drawerStateName(_ state: DrawerState) -> String {
        switch state {
        case .closed: return "closed"
        case .arrows: return "arrows"
        case .stacked(let count): return "stacked(\(count))"
        case .cycling(let index): return "cycling(\(index))"
        }
    }

    /// Rebuild the drawer rows to match `drawerState` and update toolbar height.
    private func applyDrawerState() {
        // Remove stale drawer modifier buttons from tracking before clearing rows
        modifierButtons.removeAll { $0.isDescendant(of: drawerContainerView) }
        for row in drawerRowViews {
            drawerRowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        drawerRowViews = []

        let edgePadding = currentEdgePadding()
        switch drawerState {
        case .closed:
            break
        case .arrows:
            let row = DrawerRowView(edgePadding: edgePadding)
            populateArrowRow(row)
            drawerRowsStack.addArrangedSubview(row)
            drawerRowViews = [row]
        case .cycling(let index):
            let row = DrawerRowView(edgePadding: edgePadding)
            populateExtraKeysRow(row, drawerIndex: index)
            drawerRowsStack.addArrangedSubview(row)
            drawerRowViews = [row]
        case .stacked(let count):
            // Arranged top-to-bottom: newest drawer on top, drawer 1 at the bottom
            for index in stride(from: count - 1, through: 0, by: -1) {
                let row = DrawerRowView(edgePadding: edgePadding)
                populateExtraKeysRow(row, drawerIndex: index)
                drawerRowsStack.addArrangedSubview(row)
                drawerRowViews.append(row)
            }
        }

        // Toggle button states
        #if os(visionOS)
        arrowToggleButton?.isActive = (drawerState == .arrows)
        #else
        arrowToggleButton?.isDrawerActive = (drawerState == .arrows)
        #endif
        extraKeysToggleButton?.isActive = isExtraKeysDrawerOpen

        let newHeight = CGFloat(visibleDrawerRowCount) * sizes.toolbar.drawerHeight
        let heightChanged = drawerHeightConstraint?.constant != newHeight
        drawerHeightConstraint?.constant = newHeight
        drawerContainerView.isHidden = (drawerState == .closed)
        applyBottomEdgeKeyDispatchMode(in: self)
        setNeedsUpdateConstraints()
        setNeedsLayout()

        if heightChanged {
            invalidateIntrinsicContentSize()
            onDrawerStateChanged?()
        }
    }

    private func populateArrowRow(_ row: DrawerRowView) {
        row.configureForCentering()

        let arrows: [(icon: String, key: String)] = [
            ("arrow.left", "\u{1B}[D"),
            ("arrow.down", "\u{1B}[B"),
            ("arrow.up", "\u{1B}[A"),
            ("arrow.right", "\u{1B}[C")
        ]

        for arrow in arrows {
            let button = KeyboardSymbolButton(
                key: arrow.key,
                display: .icon(arrow.icon),
                isWide: true,
                sizes: sizes
            )
            button.delegate = self
            button.shouldAutoRepeat = true
            row.stackView.addArrangedSubview(button)
        }
    }

    private func populateExtraKeysRow(_ row: DrawerRowView, drawerIndex: Int) {
        row.configureForScrolling()

        if effectiveDrawerRows.indices.contains(drawerIndex) {
            for slot in effectiveDrawerRows[drawerIndex] where slot != .builtIn(.drawerToggle) {
                if let button = createButtonForSlot(slot) {
                    addToolbarButton(button, to: row.stackView)
                }
            }
        }
        row.configureScrollingLayout(
            buttonCount: row.stackView.arrangedSubviews.count,
            sizes: sizes,
            behavior: KeyboardToolbarManager.shared.config.scrollBehavior
        )
    }

    // MARK: - Modifier State Management

    private func updateModifierState(_ modifier: KeyModifiers?, state: ModifierState) {
        guard let modifier = modifier else { return }

        modifierStates[modifier] = state

        if state != .inactive {
            activeModifiers.insert(modifier)
        } else {
            activeModifiers.remove(modifier)
            modifierStates.removeValue(forKey: modifier)
        }

        // Sync all buttons sharing the same modifier
        for button in modifierButtons where button.modifier == modifier {
            if button.modifierState != state {
                button.modifierState = state
            }
        }

        let rawValue = activeModifiers.rawValue
        Ghostty.logger.debug("KeyboardToolbar: Updated modifiers to rawValue: \(rawValue)")
        onModifiersChanged?(activeModifiers)
    }

    /// Clear one-shot modifiers after a key press (locked modifiers persist)
    func clearOneShotModifiers() {
        var didChange = false
        for (modifier, state) in modifierStates where state == .oneShot {
            modifierStates.removeValue(forKey: modifier)
            activeModifiers.remove(modifier)
            didChange = true

            for button in modifierButtons where button.modifier == modifier {
                button.clearIfOneShot()
            }
        }
        if didChange {
            let rawValue = activeModifiers.rawValue
            Ghostty.logger.debug("KeyboardToolbar: Cleared one-shot modifiers, remaining rawValue: \(rawValue)")
            onModifiersChanged?(activeModifiers)
        }
    }

    /// Clear all active modifiers (for full reset on tab close, disconnect, etc.)
    func clearModifiers() {
        activeModifiers = []
        modifierStates.removeAll()
        for button in modifierButtons {
            button.reset()
        }
        Ghostty.logger.debug("KeyboardToolbar: Cleared all modifiers")
        onModifiersChanged?(activeModifiers)
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        let drawerExtra = CGFloat(visibleDrawerRowCount) * sizes.toolbar.drawerHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: sizes.toolbar.height + drawerExtra)
    }

    // MARK: - Public Methods

    func setInteractionMode(_ mode: KeyboardToolbarInteractionMode) {
        guard interactionMode != mode else { return }
        cancelTouchInteractions(in: self)
        interactionMode = mode
        applyBottomEdgeKeyDispatchMode(in: self)
        setNeedsLayout()
    }

    private func applyBottomEdgeKeyDispatchMode(in view: UIView) {
        if let button = view as? KeyboardButton {
            button.interactionMode = button.isDescendant(of: mainRowScrollView) ? .spacedBottom : interactionMode
        }
        if let button = view as? KeyboardArrowJoystickButton {
            button.interactionMode = button.isDescendant(of: mainRowScrollView) ? .spacedBottom : interactionMode
        }
        for subview in view.subviews {
            applyBottomEdgeKeyDispatchMode(in: subview)
        }
    }

    func setDismissButtonShowsRestore(_ showsRestore: Bool) {
        dismissButtonShowsRestore = showsRestore
        dismissButton?.updateIcon(dismissButtonIconName)
    }

    func setDismissButtonPinned(_ pinned: Bool) {
        dismissButtonPinned = pinned
        dismissButton?.updateIcon(dismissButtonIconName)
    }

    private var dismissButtonIconName: String {
        if isWindowHosted || isEmbeddedPreview {
            return dismissButtonShowsRestore && !dismissButtonPinned ? "keyboard" : "keyboard.chevron.compact.down"
        }
        return Self.dismissSymbolName(pinned: dismissButtonPinned, showsRestore: dismissButtonShowsRestore)
    }

    /// Shared by the system-keyboard toolbar and the custom keyboard.
    static func dismissSymbolName(pinned: Bool, showsRestore: Bool) -> String {
        if pinned {
            for candidate in ["keyboard.slash", "chevron.up.2"] where UIImage(systemName: candidate) != nil {
                return candidate
            }
            return "chevron.up"
        }
        return showsRestore ? "chevron.up" : "chevron.down"
    }

    func setMouseCaptureOverrideActive(_ active: Bool) {
        mouseCaptureToggleButton?.isActive = active
    }

    func updateSizes(_ newSizes: KeyboardSizes) {
        if sizes.toolbar.height != newSizes.toolbar.height {
            Ghostty.logger.debug("KeyboardToolbar: row height \(self.sizes.toolbar.height, privacy: .public) -> \(newSizes.toolbar.height, privacy: .public), width class \(self.traitCollection.horizontalSizeClass.rawValue, privacy: .public), height class \(self.traitCollection.verticalSizeClass.rawValue, privacy: .public)")
        }
        sizes = newSizes
        layer.cornerRadius = sizes.toolbar.cornerRadius
        layer.cornerCurve = .continuous
        backgroundBlurView.layer.cornerRadius = sizes.toolbar.cornerRadius
        backgroundBlurView.layer.cornerCurve = .continuous
        mainToolbarHeightConstraint?.constant = sizes.toolbar.height
        drawerHeightConstraint?.constant = CGFloat(visibleDrawerRowCount) * sizes.toolbar.drawerHeight
        updateSubviewSizes(in: mainRowStackView)
        updateSubviewSizes(in: leftPinnedStackView)
        updateSubviewSizes(in: fixedControlsStackView)
        for row in drawerRowViews {
            updateSubviewSizes(in: row.stackView)
        }
        updateInsetsForCurrentTraits()
        rebuildForCurrentWidth()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateSubviewSizes(in stackView: UIStackView) {
        for view in stackView.arrangedSubviews {
            if let button = view as? KeyboardButton {
                button.updateSizes(sizes)
                continue
            }
            if let cluster = view as? KeyboardArrowCluster {
                cluster.updateSizes(sizes)
                continue
            }
            #if !os(visionOS)
            if let joystick = view as? KeyboardArrowJoystickButton {
                joystick.updateSizes(sizes)
            }
            #endif
        }
    }

    /// Horizontal edges of the glass plate, for the accessory's bottom skirt
    /// to align with. The plate is inset from the toolbar's own edges in iPhone
    /// landscape (side safe areas), so a full-width skirt would stick out as
    /// tinted ears beneath it.
    var plateLeadingAnchor: NSLayoutXAxisAnchor { backgroundBlurView.leadingAnchor }
    var plateTrailingAnchor: NSLayoutXAxisAnchor { backgroundBlurView.trailingAnchor }
    var plateFrame: CGRect { backgroundBlurView.frame }

    /// The glass tint the accessory's bottom skirt reuses so the reserved
    /// home-indicator strip reads as part of this toolbar's plate.
    func glassTintColor(for traitCollection: UITraitCollection) -> UIColor {
        if #available(iOS 26.0, *), isPhone { return .clear }
        let isLight = traitCollection.userInterfaceStyle != .dark
        return (isLight ? UIColor.white : UIColor.black).withAlphaComponent(0.16)
    }
}

extension KeyboardToolbarView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelTouchInteractions(in: scrollContentView)
        Ghostty.logger.debug("KeyboardToolbar: key row drag began at \(scrollView.contentOffset.x, privacy: .public)")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        Ghostty.logger.debug("KeyboardToolbar: key row scroll ended at \(scrollView.contentOffset.x, privacy: .public)")
    }
}

// MARK: - KeyboardButtonDelegate

extension KeyboardToolbarView: KeyboardButtonDelegate {
    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        guard !isEmbeddedPreview else { return }
        // Intercept action buttons before forwarding
        if key == "__touchKeyboard__" {
            onTouchKeyboardRequested?()
            return
        }
        if key == "__dismiss__" {
            onDismissRequested?()
            return
        }
        if key == "__dismissDouble__" {
            if dismissButtonShowsRestore {
                onDismissRequested?()
            } else {
                onCollapseRequested?()
            }
            return
        }
        if key == "__dismissLong__" {
            onPinHiddenRequested?()
            return
        }
        if key == "__tabswitcher__" {
            onTabSwitcherRequested?()
            return
        }
        if key == "__compose__" {
            onComposeRequested?()
            return
        }
        if key == "__toolbarSettings__" {
            onToolbarSettingsRequested?()
            return
        }
        if key == "__paste__" {
            onPasteRequested?()
            return
        }
        if key == "__voiceAgent__" {
            NotificationCenter.default.post(name: .toggleVoiceAgent, object: nil)
            return
        }
        if key == "__toggleFullScreen__" {
            onToggleFullScreenRequested?()
            return
        }
        if key == "__toggleTabBar__" {
            onToggleTabBarRequested?()
            return
        }
        if key == "__newConnection__" {
            onNewConnectionRequested?()
            return
        }
        if key == "__appSettings__" {
            onAppSettingsRequested?()
            return
        }
        if key == "__toggleMouseCapture__" {
            onToggleMouseCaptureRequested?()
            return
        }
        if key == "__aiAgent__" {
            onAIAgentRequested?()
            return
        }
        if key == "__brightnessBoost__" {
            onBrightnessBoostRequested?()
            return
        }
        if key == "__clipboardManager__" {
            onClipboardManagerRequested?()
            return
        }
        if key == "__fileManager__" {
            onFileManagerRequested?()
            return
        }
        if key == KeyID.httpCapture.keyValue {
            onHTTPCaptureRequested?()
            return
        }
        if key == KeyID.dictation.keyValue {
            NotificationCenter.default.post(name: .toggleDictation, object: nil)
            return
        }
        if key == "__arrowDrawer__" {
            handleArrowsToggle()
            return
        }
        if key == "__extraDrawer__" {
            handleExtraKeysToggle()
            return
        }

        // Handle custom key execution
        if key.hasPrefix("__custom_") && key.hasSuffix("__") {
            let uuidString = String(key.dropFirst(9).dropLast(2))
            if let uuid = UUID(uuidString: uuidString),
               let customKey = KeyboardToolbarManager.shared.customKey(for: uuid) {

                // Simple single-character custom keys (no baked-in modifiers)
                // go through the normal key path so toolbar modifiers apply.
                if let plainChar = customKey.plainCharacter {
                    let combinedModifiers = combinedModifiersIncludingSystemShift(modifiers)
                    self.delegate?.keyPressed(String(plainChar), modifiers: combinedModifiers)
                    clearOneShotModifiers()
                    return
                }

                let combinedModifiers = combinedModifiersIncludingSystemShift(modifiers)
                if let input = customKey.plainSpecialKeyInput, !combinedModifiers.isEmpty {
                    self.delegate?.keyPressed(input, modifiers: combinedModifiers)
                    clearOneShotModifiers()
                    return
                }

                sendCustomKeySequence(customKey.sequence)
            }
            clearOneShotModifiers()
            return
        }

        // Combine with active sticky modifiers and the system keyboard's
        // live Shift state (software latch or hardware Shift held)
        let combinedModifiers = combinedModifiersIncludingSystemShift(modifiers)

        // Debug logging
        Ghostty.logger.debug("KeyboardToolbar: key=\(key), activeModifiers=\(self.activeModifiers.rawValue), combined=\(combinedModifiers.rawValue)")

        // Forward to delegate
        self.delegate?.keyPressed(key, modifiers: combinedModifiers)

        // Clear one-shot modifiers after applying (locked modifiers persist)
        clearOneShotModifiers()
    }

    /// Sticky toolbar modifiers plus the system keyboard's Shift when it is
    /// latched (software) or held (hardware). Never removes a shift the
    /// toolbar itself applied; an unreadable system state changes nothing.
    private func combinedModifiersIncludingSystemShift(_ modifiers: KeyModifiers) -> KeyModifiers {
        var combined = modifiers.union(activeModifiers)
        if SystemShiftReader.shared.currentShift(near: self) == .shifted {
            combined.insert(.shift)
        }
        return combined
    }

    func cancelScrollTouches() {
        // Dual-symbol selection owns the touch once it becomes a key swipe.
        mainRowScrollView.panGestureRecognizer.dropTouches()
        for row in drawerRowViews {
            row.scrollView.panGestureRecognizer.dropTouches()
        }
    }

    func sendRawData(_ data: Data) {
        delegate?.sendRawData(data)
    }

    /// Send a custom key sequence to the terminal. Forwards to the shared
    /// `KeyboardButtonDelegate.sendSequenceSteps` so the toolbar and the
    /// swipe-gesture system go through the same per-step + post-ESC delay logic.
    private func sendCustomKeySequence(_ steps: [SequenceStep]) {
        delegate?.sendSequenceSteps(steps)
    }
}
