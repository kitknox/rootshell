//
//  KeyboardButton.swift
//  rootshell
//
//  Base class for keyboard toolbar buttons
//

import UIKit

// MARK: - Key Action Protocol

protocol KeyboardButtonDelegate: AnyObject {
    func keyPressed(_ key: String, modifiers: KeyModifiers)
    func cancelScrollTouches()
    func sendRawData(_ data: Data)
    /// Raw sequence steps must share the encoded keys' output queue.
    func sendSequenceData(_ data: Data)
    /// Encode a modified combo like the hardware key, honoring the terminal's
    /// keyboard protocol. False means the caller sends `terminalData()` instead.
    func sendKeyCombo(_ combo: SequenceStep.KeyCombo) -> Bool
}

extension KeyboardButtonDelegate {
    // Default no-op for buttons not in scrollable containers
    func cancelScrollTouches() {}
    func sendRawData(_ data: Data) {}
    func sendSequenceData(_ data: Data) { sendRawData(data) }
    func sendKeyCombo(_ combo: SequenceStep.KeyCombo) -> Bool { false }

    /// Send a [SequenceStep] sequence to the terminal one step at a time, inserting
    /// a 50ms delay after any step whose data ends with ESC (0x1B). Prevents the
    /// terminal app from interpreting ESC + next-char as Alt+key. Used by both the
    /// keyboard toolbar's custom keys and the swipe gesture binding system.
    /// `completion` runs once the last step is out, after any ESC delay.
    func sendSequenceSteps(_ steps: [SequenceStep], completion: (() -> Void)? = nil) {
        var index = 0
        func sendNext() {
            guard index < steps.count else { completion?(); return }
            let step = steps[index]
            index += 1
            let data = step.terminalData()
            let encoded: Bool
            if case .keyCombo(let combo) = step {
                encoded = sendKeyCombo(combo)
            } else {
                encoded = false
            }
            if !encoded, !data.isEmpty {
                sendSequenceData(data)
            }
            // If this step's data ends with ESC and there are more steps,
            // delay before sending the next so the terminal doesn't merge
            // ESC with the following byte as an Alt sequence.
            if data.last == 0x1B, index < steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    sendNext()
                }
            } else {
                sendNext()
            }
        }
        sendNext()
    }
}

// MARK: - Key Modifiers

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let alt     = KeyModifiers(rawValue: 1 << 1)
    static let command = KeyModifiers(rawValue: 1 << 2)
    static let shift   = KeyModifiers(rawValue: 1 << 3)
}

enum KeyboardKeyColors {
    static let highlight = UIColor { traits in
        let base = traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
        let alpha: CGFloat = traits.accessibilityContrast == .high ? 0.28 : 0.18
        return base.withAlphaComponent(alpha)
    }

    static let active = UIColor { traits in
        let base = traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
        let alpha: CGFloat = traits.accessibilityContrast == .high ? 0.42 : 0.28
        return base.withAlphaComponent(alpha)
    }

    // Keycaps take the system keyboard's own key colors, so the toolbar reads
    // as one more row of it.
    static let keycap = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.271, green: 0.286, blue: 0.298, alpha: 1)
            : .white
    }

    static let keycapHighlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.435, blue: 0.45, alpha: 1)
            : UIColor(red: 0.68, green: 0.70, blue: 0.73, alpha: 1)
    }

    static let keycapActive = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.52, green: 0.535, blue: 0.55, alpha: 1)
            : UIColor(red: 0.60, green: 0.62, blue: 0.65, alpha: 1)
    }
}

/// A toolbar key's fill at rest, while pressed, and while active.
struct KeyboardKeyFill {
    let isKeycap: Bool
    let resting: UIColor
    let highlight: UIColor
    let active: UIColor

    static let plain = KeyboardKeyFill(
        isKeycap: false, resting: .clear, highlight: KeyboardKeyColors.highlight, active: KeyboardKeyColors.active)
    static let keycap = KeyboardKeyFill(
        isKeycap: true, resting: KeyboardKeyColors.keycap, highlight: KeyboardKeyColors.keycapHighlight,
        active: KeyboardKeyColors.keycapActive)
}

// MARK: - KeyboardButton

enum KeyboardToolbarInteractionMode {
    case accessory
    case spacedBottom
    case screenEdge
}

class KeyboardButton: UIControl {
    // MARK: - Properties

    weak var delegate: KeyboardButtonDelegate?
    let key: String
    var sizes: KeyboardSizes

    private var autoRepeatTimer: Timer?
    private let autoRepeatDelay: TimeInterval = 0.225  // macOS fastest: 225ms
    private let autoRepeatInterval: TimeInterval = 0.1  // Repeat interval
    private var defersCurrentTouchUntilRelease = false
    private var sentKeyDuringCurrentTouch = false
    private var currentTouch: UITouch?
    private var touchStartInWindow: CGPoint = .zero
    private var currentTouchMode: KeyboardToolbarInteractionMode = .accessory

    /// Whether this button should auto-repeat when held
    var shouldAutoRepeat: Bool = false

    /// In bottom-edge toolbar mode, wait for touch-up so a Home swipe can
    /// cancel the touch without first emitting a terminal key.
    var interactionMode: KeyboardToolbarInteractionMode = .accessory

    /// Dual-symbol keys deliberately allow a downward drag to select a symbol.
    var allowsDownwardTouchSelection: Bool { false }

    var fill = KeyboardKeyFill.plain {
        didSet { applyFill() }
    }

    /// Subclasses with an active state of their own override this.
    func applyFill() {
        backgroundColor = isHighlighted ? fill.highlight : fill.resting
    }

    /// The color the key's symbol or label takes; nil is the label color.
    var glyphColor: UIColor? {
        didSet { applyGlyphColor() }
    }

    var glyphInk: UIColor { glyphColor ?? .label }

    /// Subclasses recolor what they draw.
    func applyGlyphColor() {}

    /// Keycaps sit apart; a touch in the gap goes to a neighboring key.
    var hitOutset: CGFloat = 0

    /// The key's bounds for every touch test, so a touch that hit-tests to
    /// this key is never then rejected for being outside it.
    var hitBounds: CGRect { bounds.insetBy(dx: -hitOutset, dy: 0) }

    /// Set in a scrolling row: the key sends on release, and a scroll that
    /// starts first takes the touch, so it sends nothing.
    var yieldsToScrolling = false

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitBounds.contains(point)
    }

    var canDispatchTouchAction: Bool {
        guard let window else { return false }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        return window.windowScene?.activationState == .foregroundActive
        #else
        return true
        #endif
    }

    /// Also used by controls with their own tap/hold behavior.
    func beginTouchInteraction(_ touches: Set<UITouch>) -> Bool {
        guard canDispatchTouchAction, let touch = touches.first else {
            cancelTouchInteraction()
            return false
        }
        currentTouchMode = interactionMode
        if currentTouchMode == .spacedBottom && !hitBounds.contains(touch.location(in: self)) {
            cancelTouchInteraction()
            return false
        }
        currentTouch = touch
        touchStartInWindow = touch.location(in: window)
        return true
    }

    /// Cancellation is permanent for this touch, even if it returns to the key.
    func validateTouchInteraction() -> Bool {
        guard canDispatchTouchAction, let touch = currentTouch else {
            cancelTouchInteraction()
            return false
        }
        if currentTouchMode == .spacedBottom {
            let location = touch.location(in: window)
            let dx = location.x - touchStartInWindow.x
            let dy = location.y - touchStartInWindow.y
            let local = touch.location(in: self)
            let valid: Bool
            if allowsDownwardTouchSelection {
                valid = abs(dx) <= 10 && dy >= -10
                    && local.x >= hitBounds.minX && local.x <= hitBounds.maxX
                    && local.y >= hitBounds.minY
            } else {
                valid = hypot(dx, dy) <= 10 && hitBounds.contains(local)
            }
            guard valid else {
                cancelTouchInteraction()
                return false
            }
        }
        return true
    }

    /// A system edge gesture can hold back touch-up; a lifted finger is not a hold.
    var touchHasLifted: Bool {
        guard let phase = currentTouch?.phase else { return true }
        return phase == .ended || phase == .cancelled
    }

    func finishTouchTracking() {
        currentTouch = nil
    }

    func cancelTouchInteraction() {
        finishTouchTracking()
        stopAutoRepeat()
        resetDeferredTouchState()
        isHighlighted = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouchInteraction() }
    }

    // Override isHighlighted to update appearance
    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    // MARK: - Initialization

    init(key: String, sizes: KeyboardSizes) {
        self.key = key
        self.sizes = sizes
        super.init(frame: .zero)
        setupButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupButton() {
        backgroundColor = .clear
        layer.cornerRadius = sizes.button.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        #if os(visionOS)
        hoverStyle = UIHoverStyle(
            shape: .rect(cornerRadius: sizes.button.cornerRadius)
        )
        #endif
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard beginTouchInteraction(touches) else { return }
        SystemShiftReader.shared.noteTouchEvent(event)
        defersCurrentTouchUntilRelease = currentTouchMode != .accessory || yieldsToScrolling
        sentKeyDuringCurrentTouch = false

        if !defersCurrentTouchUntilRelease {
            playHaptic()
        }

        // Start auto-repeat timer if enabled
        if shouldAutoRepeat {
            autoRepeatTimer?.invalidate()
            autoRepeatTimer = Timer.scheduledTimer(withTimeInterval: autoRepeatDelay, repeats: false) { [weak self] _ in
                guard let self, self.validateTouchInteraction() else { return }
                if self.defersCurrentTouchUntilRelease {
                    self.sendKey()
                    self.playHaptic()
                    self.sentKeyDuringCurrentTouch = true
                }
                self.startAutoRepeat()
            }
        }

        if !defersCurrentTouchUntilRelease {
            sendKey()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        _ = validateTouchInteraction()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard validateTouchInteraction() else { return }
        defer { cancelTouchInteraction() }
        stopAutoRepeat()
        if defersCurrentTouchUntilRelease && !sentKeyDuringCurrentTouch {
            sendKey()
            playHaptic()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        cancelTouchInteraction()
    }

    private func resetDeferredTouchState() {
        defersCurrentTouchUntilRelease = false
        sentKeyDuringCurrentTouch = false
    }

    // MARK: - Auto-Repeat

    private func startAutoRepeat() {
        guard validateTouchInteraction() else { return }
        autoRepeatTimer?.invalidate()
        autoRepeatTimer = Timer.scheduledTimer(withTimeInterval: autoRepeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.validateTouchInteraction() else { return }
            self.sendKey()
            self.playHaptic()
        }
    }

    private func stopAutoRepeat() {
        autoRepeatTimer?.invalidate()
        autoRepeatTimer = nil
    }

    // MARK: - Key Sending

    func sendKey() {
        // Get current modifiers from toolbar
        let modifiers = currentModifiers()
        delegate?.keyPressed(key, modifiers: modifiers)
    }

    /// Override this to provide current modifier state
    func currentModifiers() -> KeyModifiers {
        return []
    }

    // MARK: - Visual Feedback

    private func updateAppearance() {
        UIView.animate(withDuration: 0.1, delay: 0, options: .allowUserInteraction) {
            self.backgroundColor = self.isHighlighted ? self.fill.highlight : self.fill.resting
        }
    }

    // MARK: - Haptic Feedback

    func playHaptic() {
        // Play standard input click sound
        #if !os(visionOS)
        UIDevice.current.playInputClick()
        #endif
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        return CGSize(width: sizes.button.normalWidth, height: sizes.button.height)
    }

    func updateSizes(_ newSizes: KeyboardSizes) {
        sizes = newSizes
        layer.cornerRadius = sizes.button.cornerRadius
        layer.cornerCurve = .continuous
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

// Enable haptic feedback for custom view
#if !os(visionOS)
extension KeyboardButton: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        return true
    }
}
#endif
