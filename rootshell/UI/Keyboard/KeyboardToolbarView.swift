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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
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
            delegate?.keyPressed("__dismissDouble__", modifiers: currentModifiers())
            return
        }

        touchIsDown = true
        awaitingRelease = false
        longPressTriggered = false

        // If the finger is still down when the double-tap window expires,
        // defer the single tap to touchesEnded so a long press can preempt it.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
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
            guard let self else { return }
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
        touchIsDown = false
        pendingLongPress?.cancel()
        pendingLongPress = nil
        isHighlighted = false

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

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchIsDown = false
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
        pendingLongPress?.cancel()
        pendingLongPress = nil
        longPressTriggered = false
        awaitingRelease = false
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
    private var stackMinimumWidthConstraint: NSLayoutConstraint?

    init(edgePadding: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        separator.backgroundColor = .separator.withAlphaComponent(0.5)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.showsHorizontalScrollIndicator = false
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
        stackMinimumWidthConstraint = stackView.widthAnchor.constraint(
            greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pin the stack to the scroll content edges so overflowing keys scroll horizontally.
    func configureForScrolling() {
        scrollView.isScrollEnabled = true
        stackCenterXConstraint?.isActive = false
        stackLeadingConstraint?.isActive = true
        stackTrailingConstraint?.isActive = true
        stackMinimumWidthConstraint?.isActive = true
    }

    /// Center the stack (arrow cluster) with scrolling disabled.
    func configureForCentering() {
        scrollView.isScrollEnabled = false
        stackLeadingConstraint?.isActive = false
        stackTrailingConstraint?.isActive = false
        stackMinimumWidthConstraint?.isActive = false
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

    /// Callback when drawer opens/closes (for height updates)
    var onDrawerStateChanged: (() -> Void)?

    // Main toolbar views
    private let mainToolbarContainer = UIView()
    private let mainRowStackView = UIStackView()
    private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let tintOverlayView = UIView()

    // Drawer views
    private let drawerContainerView = UIView()
    private let drawerRowsStack = UIStackView()
    private var drawerRowViews: [DrawerRowView] = []
    private var drawerHeightConstraint: NSLayoutConstraint?
    private var backgroundLeadingConstraint: NSLayoutConstraint?
    private var backgroundTrailingConstraint: NSLayoutConstraint?
    private var topBorderLeadingConstraint: NSLayoutConstraint?
    private var topBorderTrailingConstraint: NSLayoutConstraint?
    private var drawerContainerLeadingConstraint: NSLayoutConstraint?
    private var drawerContainerTrailingConstraint: NSLayoutConstraint?
    private var mainToolbarLeadingConstraint: NSLayoutConstraint?
    private var mainToolbarTrailingConstraint: NSLayoutConstraint?
    private var mainToolbarHeightConstraint: NSLayoutConstraint?
    private var mainRowLeadingConstraint: NSLayoutConstraint?
    private var mainRowTrailingConstraint: NSLayoutConstraint?

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
    private var defersKeysForBottomEdgeGesture = false

    /// Track last known width to detect meaningful size changes
    private var lastBuiltWidth: CGFloat = 0

    // MARK: - Initialization

    init(sizes: KeyboardSizes = .current()) {
        self.sizes = sizes

        super.init(frame: .zero)

        setupViews()
        // Buttons built on first layoutSubviews when we have a real width
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

    private func currentChromeHorizontalInsets() -> (left: CGFloat, right: CGFloat) {
        guard isPhoneLandscape else { return (0, 0) }

        let localLeft = safeAreaInsets.left
        let localRight = safeAreaInsets.right
        let windowLeft = window?.safeAreaInsets.left ?? 0
        let windowRight = window?.safeAreaInsets.right ?? 0

        return (
            left: max(localLeft, windowLeft) + 2,
            right: max(localRight, windowRight) + 2
        )
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
        backgroundBlurView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBlurView.isUserInteractionEnabled = false
        backgroundBlurView.layer.cornerRadius = sizes.toolbar.cornerRadius
        backgroundBlurView.layer.cornerCurve = .continuous
        backgroundBlurView.clipsToBounds = true
        tintOverlayView.translatesAutoresizingMaskIntoConstraints = false
        tintOverlayView.isUserInteractionEnabled = false
        tintOverlayView.backgroundColor = glassTintColor(for: traitCollection)
        addSubview(backgroundBlurView)
        backgroundBlurView.contentView.addSubview(tintOverlayView)

        // Add subtle top border
        let topBorder = UIView()
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

        // Configure main row stack — single unified row, fillEqually, no scrolling
        mainRowStackView.axis = .horizontal
        mainRowStackView.spacing = 0
        mainRowStackView.alignment = .center
        mainRowStackView.distribution = .fillEqually
        mainRowStackView.translatesAutoresizingMaskIntoConstraints = false
        mainToolbarContainer.addSubview(mainRowStackView)

        // Layout constraints
        let edgePadding = currentEdgePadding()
        let heightConstraint = drawerContainerView.heightAnchor.constraint(equalToConstant: 0)
        drawerHeightConstraint = heightConstraint
        let backgroundLeadingConstraint = backgroundBlurView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let backgroundTrailingConstraint = backgroundBlurView.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.backgroundLeadingConstraint = backgroundLeadingConstraint
        self.backgroundTrailingConstraint = backgroundTrailingConstraint
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
        let mainRowLeading = mainRowStackView.leadingAnchor.constraint(equalTo: mainToolbarContainer.leadingAnchor, constant: edgePadding)
        let mainRowTrailing = mainRowStackView.trailingAnchor.constraint(equalTo: mainToolbarContainer.trailingAnchor, constant: -edgePadding)
        mainRowLeadingConstraint = mainRowLeading
        mainRowTrailingConstraint = mainRowTrailing

        let constraints: [NSLayoutConstraint] = [
            // Background blur
            backgroundLeadingConstraint,
            backgroundTrailingConstraint,
            backgroundBlurView.topAnchor.constraint(equalTo: topAnchor),
            backgroundBlurView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

            // Main row stack
            mainRowLeading,
            mainRowTrailing,
            mainRowStackView.centerYAnchor.constraint(equalTo: mainToolbarContainer.centerYAnchor),
            mainRowStackView.heightAnchor.constraint(equalToConstant: sizes.button.height),
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
        updateInsetsForCurrentTraits()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = bounds.width
        guard width > 0 else { return }

        // Rebuild buttons when width changes meaningfully (e.g. rotation)
        if abs(width - lastBuiltWidth) > 10 {
            rebuildForCurrentWidth()
        }
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
        mainRowLeadingConstraint?.constant = edgePadding
        mainRowTrailingConstraint?.constant = -edgePadding
        for row in drawerRowViews {
            row.updateEdgePadding(edgePadding)
        }
    }

    // MARK: - Button Building (Manager-Driven)

    /// Rebuild the entire toolbar from the manager's current effective layout.
    func rebuildForCurrentWidth() {
        let width = bounds.width
        guard width > 0 else { return }
        lastBuiltWidth = width

        let manager = KeyboardToolbarManager.shared

        // Clear existing main row buttons (preserve modifier tracking)
        let mainRowModifiers = Set(mainRowStackView.arrangedSubviews.compactMap { $0 as? KeyboardModifierButton })
        modifierButtons.removeAll { mainRowModifiers.contains($0) }
        mainRowStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Reset tracked references
        dismissButton = nil
        mouseCaptureToggleButton = nil
        arrowToggleButton = nil
        extraKeysToggleButton = nil

        // Build main row from effective slots
        let edgePadding = currentEdgePadding()
        let chromeInsets = currentChromeHorizontalInsets()
        let availableWidth = width - edgePadding * 2 - chromeInsets.left - chromeInsets.right
        let mainSlots = manager.effectiveMainRowSlots(availableWidth: availableWidth)

        for slot in mainSlots {
            if let button = createButtonForSlot(slot) {
                mainRowStackView.addArrangedSubview(button)
            }
        }

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
            drawerState = manager.drawerToggleMode == .cycle ? .cycling(index: 0) : .stacked(count: 1)
        }

        // Rebuild drawer rows (also the repopulate path after a layout change)
        applyDrawerState()
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
        applyDrawerState()
    }

    private func handleArrowsToggle() {
        drawerState = (drawerState == .arrows) ? .closed : .arrows
        applyDrawerState()
    }

    /// Rebuild the drawer rows to match `drawerState` and update toolbar height.
    private func applyDrawerState() {
        // Remove stale drawer modifier buttons from tracking before clearing rows
        let drawerModifiers = Set(drawerRowViews.flatMap { row in
            row.stackView.arrangedSubviews.compactMap { $0 as? KeyboardModifierButton }
        })
        modifierButtons.removeAll { drawerModifiers.contains($0) }
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

        let manager = KeyboardToolbarManager.shared
        let edgePadding = currentEdgePadding()
        let chromeInsets = currentChromeHorizontalInsets()
        let availableWidth = bounds.width - edgePadding * 2 - chromeInsets.left - chromeInsets.right
        let drawerRows = manager.effectiveDrawerRowSlots(availableWidth: availableWidth)
        guard drawerRows.indices.contains(drawerIndex) else { return }

        for slot in drawerRows[drawerIndex] {
            switch slot {
            case .builtIn(let keyID):
                if keyID.isModifier {
                    let modButton = createModifierButton(for: keyID.keyDefinition)
                    row.stackView.addArrangedSubview(modButton)
                } else if keyID == .arrowDrawerToggle {
                    // Skip arrow drawer toggle in extra keys drawer
                    continue
                } else if keyID == .drawerToggle {
                    // Skip drawer toggle in drawer
                    continue
                } else if let button = createButtonForKeyID(keyID) {
                    row.stackView.addArrangedSubview(button)
                }
            case .custom(let uuid):
                if let button = createCustomKeyButton(uuid: uuid) {
                    row.stackView.addArrangedSubview(button)
                }
            }
        }
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

    func setDefersKeysForBottomEdgeGesture(_ defers: Bool) {
        guard defersKeysForBottomEdgeGesture != defers else { return }
        defersKeysForBottomEdgeGesture = defers
        applyBottomEdgeKeyDispatchMode(in: self)
    }

    private func applyBottomEdgeKeyDispatchMode(in view: UIView) {
        if let button = view as? KeyboardButton {
            button.defersKeyUntilTouchUp = defersKeysForBottomEdgeGesture
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
        if dismissButtonPinned {
            for candidate in ["keyboard.slash", "chevron.up.2"] where UIImage(systemName: candidate) != nil {
                return candidate
            }
            return "chevron.up"
        }
        return dismissButtonShowsRestore ? "chevron.up" : "chevron.down"
    }

    func setMouseCaptureOverrideActive(_ active: Bool) {
        mouseCaptureToggleButton?.isActive = active
    }

    func updateSizes(_ newSizes: KeyboardSizes) {
        sizes = newSizes
        layer.cornerRadius = sizes.toolbar.cornerRadius
        layer.cornerCurve = .continuous
        backgroundBlurView.layer.cornerRadius = sizes.toolbar.cornerRadius
        backgroundBlurView.layer.cornerCurve = .continuous
        mainRowStackView.spacing = sizes.toolbar.spacing
        mainToolbarHeightConstraint?.constant = sizes.toolbar.height
        drawerHeightConstraint?.constant = CGFloat(visibleDrawerRowCount) * sizes.toolbar.drawerHeight
        updateSubviewSizes(in: mainRowStackView)
        for row in drawerRowViews {
            updateSubviewSizes(in: row.stackView)
        }
        updateInsetsForCurrentTraits()
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

    /// The glass tint the accessory's bottom skirt reuses so the reserved
    /// home-indicator strip reads as part of this toolbar's plate.
    func glassTintColor(for traitCollection: UITraitCollection) -> UIColor {
        let isLight = traitCollection.userInterfaceStyle != .dark
        return (isLight ? UIColor.white : UIColor.black).withAlphaComponent(0.16)
    }
}

// MARK: - KeyboardButtonDelegate

extension KeyboardToolbarView: KeyboardButtonDelegate {
    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        // Intercept action buttons before forwarding
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
        // Cancel scroll view pan gestures when a symbol button detects a swipe
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
