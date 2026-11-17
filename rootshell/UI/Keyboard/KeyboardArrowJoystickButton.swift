//
//  KeyboardArrowJoystickButton.swift
//  rootshell
//
//  Dual-mode arrow button: joystick drag-to-arrow (default) or drawer toggle.
//  Long press (1.5s) toggles between modes. Mode persists across launches.
//

import UIKit

class KeyboardArrowJoystickButton: UIView {
    var interactionMode: KeyboardToolbarInteractionMode = .accessory
    private var currentTouchMode: KeyboardToolbarInteractionMode = .accessory
    private var currentTouch: UITouch?
    private var touchStartInWindow: CGPoint = .zero

    private var canDispatchTouchAction: Bool {
        guard let window else { return false }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        return window.windowScene?.activationState == .foregroundActive
        #else
        return true
        #endif
    }

    private func validateTouchInteraction() -> Bool {
        guard canDispatchTouchAction, let touch = currentTouch else {
            cancelTouchInteraction()
            return false
        }
        // Joystick movement is intentional. Only drawer taps use tap slop.
        if currentTouchMode == .spacedBottom && mode == .drawer {
            let location = touch.location(in: window)
            guard hitBounds.contains(touch.location(in: self)),
                  hypot(location.x - touchStartInWindow.x, location.y - touchStartInWindow.y) <= 10 else {
                cancelTouchInteraction()
                return false
            }
        }
        return true
    }

    // MARK: - Types

    enum Mode: String {
        case drawer
        case joystick
    }

    enum ArrowDirection {
        case up, down, left, right

        var key: String {
            switch self {
            case .up: return "\u{1B}[A"
            case .down: return "\u{1B}[B"
            case .left: return "\u{1B}[D"
            case .right: return "\u{1B}[C"
            }
        }
    }

    // MARK: - Properties

    weak var delegate: KeyboardButtonDelegate?
    var onDrawerToggle: (() -> Void)?

    var isDrawerActive: Bool = false {
        didSet { updateAppearance() }
    }

    var fill = KeyboardKeyFill.plain {
        didSet {
            highlightView.backgroundColor = fill.highlight
            updateAppearance()
        }
    }

    /// As on `KeyboardButton`; nil is the label color.
    var glyphColor: UIColor? {
        didSet { iconView.tintColor = glyphColor ?? .label }
    }

    /// Keycaps sit apart; a touch in the gap goes to a neighboring key.
    var hitOutset: CGFloat = 0
    var hitBounds: CGRect { bounds.insetBy(dx: -hitOutset, dy: 0) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitBounds.contains(point)
    }

    private(set) var mode: Mode = .joystick {
        didSet { updateAppearance() }
    }

    private var sizes: KeyboardSizes
    /// The key height this button was last sized for.
    var keyHeight: CGFloat { sizes.button.height }

    // Touch state
    private var touchStartPoint: CGPoint = .zero
    private var longPressTimer: Timer?
    private var isLongPressDetected = false
    private var isTouching = false

    // Joystick state
    private var currentDirection: ArrowDirection?
    private var autoRepeatTimer: Timer?

    // Thresholds
    private let longPressDuration: TimeInterval = 1.5
    private let longPressCancelDistance: CGFloat = 8
    private let deadZone: CGFloat = 18
    private let autoRepeatDelay: TimeInterval = 0.5
    private let autoRepeatInterval: TimeInterval = 0.1

    // Visual
    private let iconView = UIImageView()
    private let highlightView = UIView()

    #if !os(visionOS)
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    #endif

    // MARK: - Initialization

    init(sizes: KeyboardSizes) {
        self.sizes = sizes
        super.init(frame: .zero)

        mode = SettingsStore.shared.get(Settings.KeyboardToolbar.arrowJoystickMode)

        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        backgroundColor = .clear
        layer.cornerRadius = sizes.button.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        // Highlight background (shows on touch)
        highlightView.backgroundColor = KeyboardKeyColors.highlight
        highlightView.alpha = 0
        highlightView.isUserInteractionEnabled = false
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)

        // Icon
        let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
        iconView.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right", withConfiguration: config)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        iconView.isUserInteractionEnabled = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6),
        ])

        updateAppearance()
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard canDispatchTouchAction, let touch = touches.first else { return }
        currentTouchMode = interactionMode
        if currentTouchMode == .spacedBottom && !hitBounds.contains(touch.location(in: self)) { return }
        currentTouch = touch
        touchStartInWindow = touch.location(in: window)

        SystemShiftReader.shared.noteTouchEvent(event)
        isTouching = true
        isLongPressDetected = false
        touchStartPoint = touch.location(in: self)
        currentDirection = nil

        // Show highlight
        highlightView.alpha = 1

        // Play input click
        playInputClick()

        // Start long press timer
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
            self?.longPressTriggered()
        }

        #if !os(visionOS)
        impactGenerator.prepare()
        #endif
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, isTouching, validateTouchInteraction() else { return }

        let current = touch.location(in: self)
        let dx = current.x - touchStartPoint.x
        let dy = current.y - touchStartPoint.y
        let displacement = hypot(dx, dy)

        // Cancel long press if user is dragging
        if displacement > longPressCancelDistance {
            longPressTimer?.invalidate()
            longPressTimer = nil
        }

        // Joystick mode: detect direction from displacement
        guard mode == .joystick, !isLongPressDetected else { return }

        let newDirection = directionFromDisplacement(current)
        if newDirection != currentDirection {
            // Direction changed
            stopAutoRepeat()
            currentDirection = newDirection

            if let dir = newDirection {
                // Cancel parent scroll touches
                delegate?.cancelScrollTouches()

                // Send key immediately
                sendKey(dir)
                playInputClick()

                // Start auto-repeat
                autoRepeatTimer = Timer.scheduledTimer(withTimeInterval: autoRepeatDelay, repeats: false) { [weak self] _ in
                    self?.startAutoRepeat()
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard validateTouchInteraction() else { return }
        longPressTimer?.invalidate()
        longPressTimer = nil

        defer {
            currentTouch = nil
            isTouching = false
            currentDirection = nil
            stopAutoRepeat()
            highlightView.alpha = 0
            updateAppearance()
        }

        // If long press toggled mode, don't fire tap
        if isLongPressDetected { return }

        // Drawer mode: tap toggles drawer
        if mode == .drawer {
            onDrawerToggle?()
        }
        // Joystick mode: stop repeat (handled in defer)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTouchInteraction()
    }

    func cancelTouchInteraction() {
        currentTouch = nil
        longPressTimer?.invalidate()
        longPressTimer = nil
        isTouching = false
        isLongPressDetected = false
        currentDirection = nil
        stopAutoRepeat()
        highlightView.alpha = 0
        updateAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouchInteraction() }
    }

    // MARK: - Long Press

    private func longPressTriggered() {
        guard validateTouchInteraction() else { return }
        longPressTimer = nil
        isLongPressDetected = true

        // Toggle mode
        let newMode: Mode = (mode == .drawer) ? .joystick : .drawer
        mode = newMode
        SettingsStore.shared.set(Settings.KeyboardToolbar.arrowJoystickMode, newMode)

        // Haptic
        #if !os(visionOS)
        impactGenerator.impactOccurred()
        #endif

        // If switching to joystick and drawer is open, close it
        if newMode == .joystick && isDrawerActive {
            onDrawerToggle?()
        }
    }

    // MARK: - Direction Detection

    private func directionFromDisplacement(_ current: CGPoint) -> ArrowDirection? {
        let dx = current.x - touchStartPoint.x
        let dy = current.y - touchStartPoint.y
        guard hypot(dx, dy) >= deadZone else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }

    // MARK: - Auto-Repeat

    private func startAutoRepeat() {
        guard validateTouchInteraction(), let dir = currentDirection else { return }

        autoRepeatTimer?.invalidate()
        autoRepeatTimer = Timer.scheduledTimer(withTimeInterval: autoRepeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.validateTouchInteraction(), let dir = self.currentDirection else { return }
            self.sendKey(dir)
        }
        // Send one immediately at repeat start
        sendKey(dir)
    }

    private func stopAutoRepeat() {
        autoRepeatTimer?.invalidate()
        autoRepeatTimer = nil
    }

    // MARK: - Key Sending

    private func sendKey(_ direction: ArrowDirection) {
        delegate?.keyPressed(direction.key, modifiers: [])
    }

    // MARK: - Haptic

    private func playInputClick() {
        #if !os(visionOS)
        UIDevice.current.playInputClick()
        #endif
    }

    // MARK: - Appearance

    private func updateAppearance() {
        // Background: active only when drawer is open
        let showActive = isDrawerActive
        UIView.animate(withDuration: 0.1) {
            self.backgroundColor = showActive ? self.fill.active : self.fill.resting
        }
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        CGSize(width: sizes.button.wideWidth, height: sizes.button.height)
    }

    func updateSizes(_ newSizes: KeyboardSizes) {
        sizes = newSizes
        layer.cornerRadius = sizes.button.cornerRadius
        layer.cornerCurve = .continuous

        let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
        iconView.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right", withConfiguration: config)

        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

// Enable haptic feedback for custom view
#if !os(visionOS)
extension KeyboardArrowJoystickButton: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        return true
    }
}
#endif
