//
//  KeyboardModifierButton.swift
//  rootshell
//
//  Modifier keys with three-state sticky behavior (Ctrl, Alt, Cmd, Shift, Esc)
//  Single tap = one-shot (applies to next key then auto-clears)
//  Double tap = locked (stays on until tapped off)
//

import UIKit
import GhosttyKit
import os

// MARK: - ModifierState

enum ModifierState: Equatable {
    case inactive   // Not active
    case oneShot    // Active for next key only
    case locked     // Active until tapped off
}

class KeyboardModifierButton: KeyboardButton {
    // MARK: - Properties

    private let label: UILabel
    private let iconView: UIImageView?
    private let systemImageName: String?
    private let lockIndicatorBar: UIView
    private var lastTapTimestamp: CFAbsoluteTime = 0
    private let doubleTapThreshold: CFAbsoluteTime = 0.5

    /// Set only for main-row modifiers; drawer keys retain their existing handling.
    var sweepPeers: (() -> [KeyboardModifierButton])?
    private var sweepTouch: UITouch?
    private var sweepButtons: [KeyboardModifierButton] = []
    private var sweepTimer: Timer?
    private static let sweepHoldDuration: TimeInterval = 0.2
    private var sweepLastEntry: TimeInterval = 0
    private weak var sweepHoveredButton: KeyboardModifierButton?
    private var sweepClears = false
    private var sweepUnlocks = false
    private var sweepCommitted = false
    private var sweepAppliedOnTouchDown = false

    /// Three-state modifier: inactive → oneShot → locked → inactive
    var modifierState: ModifierState = .inactive {
        didSet {
            updateVisualState()
        }
    }

    /// Convenience: whether the modifier is active (one-shot or locked)
    var isModifierActive: Bool { modifierState != .inactive }

    /// The modifier this button represents
    let modifier: KeyModifiers?

    /// Callback when modifier state changes
    var onStateChange: ((ModifierState) -> Void)?

    // MARK: - Initialization

    init(title: String, systemImage: String? = nil, modifier: KeyModifiers? = nil, sizes: KeyboardSizes) {
        self.modifier = modifier
        self.systemImageName = systemImage

        // Create label
        label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: sizes.button.fontSize, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        // Create icon if provided
        if let systemImage = systemImage {
            let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
            iconView = UIImageView(image: UIImage(systemName: systemImage, withConfiguration: config))
            iconView?.contentMode = .scaleAspectFit
            iconView?.translatesAutoresizingMaskIntoConstraints = false
        } else {
            iconView = nil
        }

        // Create lock indicator bar (shown when locked)
        lockIndicatorBar = UIView()
        lockIndicatorBar.backgroundColor = .label
        lockIndicatorBar.layer.cornerRadius = 1
        lockIndicatorBar.alpha = 0
        lockIndicatorBar.translatesAutoresizingMaskIntoConstraints = false

        super.init(key: title, sizes: sizes)

        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        // Add icon or label
        if let iconView = iconView {
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
                iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.7)
            ])
        } else {
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        // Add lock indicator bar at bottom center
        addSubview(lockIndicatorBar)
        NSLayoutConstraint.activate([
            lockIndicatorBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockIndicatorBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            lockIndicatorBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
            lockIndicatorBar.heightAnchor.constraint(equalToConstant: 2)
        ])

        // Register for trait changes (iOS 17+ replacement for traitCollectionDidChange)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardModifierButton, _: UITraitCollection) in
            self.updateVisualState()
        }

        updateVisualState()
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard modifier != nil, sweepPeers != nil else {
            super.touchesBegan(touches, with: event)
            return
        }
        guard sweepTouch == nil, canDispatchTouchAction, let touch = touches.first else { return }
        SystemShiftReader.shared.noteTouchEvent(event)
        sweepTouch = touch
        sweepButtons = [self]
        sweepLastEntry = touch.timestamp
        sweepHoveredButton = self
        sweepClears = isModifierActive
        sweepUnlocks = modifierState == .locked
        sweepCommitted = false
        // Accessory mode activates on touch-down so a chord with another key sees it.
        sweepAppliedOnTouchDown = interactionMode == .accessory
        isHighlighted = true
        if sweepAppliedOnTouchDown {
            sendKey()
            playHaptic()
        }
        scheduleSweep(after: Self.sweepHoldDuration)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = sweepTouch else {
            super.touchesMoved(touches, with: event)
            return
        }
        guard canDispatchTouchAction else { endSweep(); return }
        let location = touch.location(in: self)
        guard location.y >= -10, location.y <= bounds.maxY + 10 else {
            endSweep()
            return
        }
        let hoveredButton = sweepPeers?().first {
            $0.modifier != nil && $0.bounds.contains(touch.location(in: $0))
        }
        if let button = hoveredButton, button !== sweepHoveredButton {
            if !sweepButtons.contains(button) { sweepButtons.append(button) }
            button.isHighlighted = true
            sweepLastEntry = touch.timestamp
            scheduleSweep(after: Self.sweepHoldDuration)
        } else if hoveredButton == nil {
            // Off every modifier the hold waits; re-entering restarts it.
            sweepTimer?.invalidate()
            sweepTimer = nil
        }
        sweepHoveredButton = hoveredButton
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = sweepTouch else {
            super.touchesEnded(touches, with: event)
            return
        }
        guard touches.contains(touch) else { return }
        if canDispatchTouchAction {
            // Check the touch timestamp too: touch-up can arrive before a due timer fires.
            // Once committed, modifiers swept onto afterwards take the committed state.
            if sweepCommitted
                || (sweepHoveredButton != nil && touch.timestamp - sweepLastEntry >= Self.sweepHoldDuration) {
                applySweep(state: sweepUnlocks ? .inactive : .locked)
                if !sweepCommitted { playHaptic() }
            } else if sweepButtons.count > 1 {
                applySweep(state: sweepClears ? .inactive : .oneShot)
                playHaptic()
            } else if !sweepAppliedOnTouchDown {
                sendKey()
                playHaptic()
            }
        }
        endSweep()
    }

    // Also reached from touchesCancelled and window removal.
    override func cancelTouchInteraction() {
        super.cancelTouchInteraction()
        endSweep()
    }

    private func scheduleSweep(after delay: TimeInterval) {
        sweepTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.sweepTouch != nil, self.canDispatchTouchAction else {
                self.endSweep()
                return
            }
            // A hold promotes one-shot selection to locked; only a sweep
            // starting on an already locked modifier unlocks the selection.
            self.applySweep(state: self.sweepUnlocks ? .inactive : .locked)
            self.sweepCommitted = true
            self.playHaptic()
        }
        sweepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applySweep(state: ModifierState) {
        for button in sweepButtons {
            button.lastTapTimestamp = 0
            button.modifierState = state
            button.onStateChange?(state)
        }
    }

    private func endSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        sweepTouch = nil
        sweepHoveredButton = nil
        for button in sweepButtons { button.isHighlighted = false }
        sweepButtons.removeAll()
    }

    override func sendKey() {
        // Esc fires immediately, never enters sticky cycle
        if key == "Esc" {
            delegate?.keyPressed("\u{1B}", modifiers: [])
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastTapTimestamp

        switch modifierState {
        case .inactive:
            if elapsed < doubleTapThreshold {
                // Quick second tap (one-shot was consumed between taps) → lock
                modifierState = .locked
            } else {
                modifierState = .oneShot
            }
            lastTapTimestamp = now

        case .oneShot:
            if elapsed < doubleTapThreshold {
                // Quick double-tap → lock
                modifierState = .locked
            } else {
                // Slow second tap → toggle off
                modifierState = .inactive
            }
            lastTapTimestamp = now

        case .locked:
            modifierState = .inactive
            lastTapTimestamp = 0
        }

        let modifierValue = modifier?.rawValue ?? 0
        let stateName = switch modifierState {
        case .inactive: "inactive"
        case .oneShot: "oneShot"
        case .locked: "locked"
        }
        Ghostty.logger.debug("Modifier '\(self.key)' → \(stateName), modifier rawValue: \(modifierValue)")
        onStateChange?(modifierState)
    }

    // MARK: - Visual State

    override var isHighlighted: Bool {
        didSet {
            updateVisualState()
        }
    }

    private func updateVisualState() {
        // Background and icon change instantly so double-tap feels responsive
        switch modifierState {
        case .inactive:
            backgroundColor = isHighlighted ? KeyboardKeyColors.highlight : .clear
            updateIconVariant(filled: false)
        case .oneShot:
            backgroundColor = KeyboardKeyColors.active
            updateIconVariant(filled: true)
        case .locked:
            backgroundColor = KeyboardKeyColors.active
            updateIconVariant(filled: true)
        }
        label.textColor = .label
        iconView?.tintColor = .label

        // Only the lock indicator bar animates
        let targetAlpha: CGFloat = modifierState == .locked ? 1 : 0
        if lockIndicatorBar.alpha != targetAlpha {
            UIView.animate(withDuration: 0.15, delay: 0, options: .allowUserInteraction) {
                self.lockIndicatorBar.alpha = targetAlpha
            }
        }
    }

    /// Update icon to filled/outline variant. Only Shift has a .fill variant.
    private func updateIconVariant(filled: Bool) {
        guard let iconView = iconView, let baseName = systemImageName else { return }

        // Only shift has a distinct .fill variant
        let targetName: String
        if baseName == "shift" {
            targetName = filled ? "shift.fill" : "shift"
        } else {
            return // Other modifiers keep the same icon
        }

        let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
        iconView.image = UIImage(systemName: targetName, withConfiguration: config)
    }

    // MARK: - Accessibility

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = super.accessibilityTraits
            if isModifierActive {
                traits.insert(.selected)
            }
            return traits
        }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityValue: String? {
        get {
            switch modifierState {
            case .inactive: return nil
            case .oneShot: return "One-shot"
            case .locked: return "Locked"
            }
        }
        set { super.accessibilityValue = newValue }
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        return CGSize(width: sizes.button.wideWidth, height: sizes.button.height)
    }

    override func updateSizes(_ newSizes: KeyboardSizes) {
        super.updateSizes(newSizes)
        label.font = .systemFont(ofSize: newSizes.button.fontSize, weight: .medium)

        if let iconView = iconView {
            let config = UIImage.SymbolConfiguration(pointSize: newSizes.button.symbolSize, weight: .medium)
            iconView.preferredSymbolConfiguration = config
        }
    }

    // MARK: - State Management

    /// Clear one-shot state only (locked state persists)
    func clearIfOneShot() {
        if modifierState == .oneShot {
            modifierState = .inactive
        }
    }

    /// Force reset to inactive regardless of state
    func reset() {
        modifierState = .inactive
    }
}
