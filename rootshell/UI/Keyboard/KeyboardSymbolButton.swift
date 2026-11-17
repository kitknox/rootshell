//
//  KeyboardSymbolButton.swift
//  rootshell
//
//  Button for symbol keys, arrow keys, and other special keys with icons or text.
//  Dual-text buttons support Blink-style vertical swipe to select secondary key.
//

import UIKit

class KeyboardSymbolButton: KeyboardButton {
    // MARK: - Display Type

    enum DisplayType {
        case text(String)           // Text label
        case icon(String)           // SF Symbol name
        case dualText(String, String)  // Primary and secondary text (vertical swipe)
    }

    // MARK: - Properties

    private let displayType: DisplayType
    private var primaryLabel: UILabel?
    private var iconView: UIImageView?

    // CATextLayer for dual-text mode (smooth swipe animations)
    private var primaryTextLayer: CATextLayer?
    private var secondaryTextLayer: CATextLayer?

    // Swipe gesture tracking for dual-text
    private var touchFirstLocation: CGPoint = .zero
    private var swipeProgress: CGFloat = 0

    // Store both values for dual-text mode
    private var primaryValue: String?
    private var secondaryValue: String?

    private let isWideButton: Bool

    /// Whether this button is in an active/toggled state (e.g., tab switcher open)
    var isActive: Bool = false {
        didSet { updateActiveAppearance() }
    }

    // MARK: - Initialization

    init(key: String, display: DisplayType, isWide: Bool = false, sizes: KeyboardSizes) {
        self.displayType = display
        self.isWideButton = isWide

        // Extract primary/secondary values for dual-text
        if case .dualText(let primary, let secondary) = display {
            self.primaryValue = primary
            self.secondaryValue = secondary
        }

        super.init(key: key, sizes: sizes)

        setupDisplay()

        // Register for trait changes (iOS 17+ replacement for traitCollectionDidChange)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: KeyboardSymbolButton, _: UITraitCollection) in
            if case .dualText = self.displayType {
                let scale = self.traitCollection.displayScale
                self.primaryTextLayer?.contentsScale = scale
                self.secondaryTextLayer?.contentsScale = scale
                self.layer.rasterizationScale = scale
                self.setNeedsLayout()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupDisplay() {
        switch displayType {
        case .text(let text):
            setupTextDisplay(text)

        case .icon(let systemName):
            setupIconDisplay(systemName)

        case .dualText(let primary, let secondary):
            setupDualTextLayerDisplay(primary: primary, secondary: secondary)
        }
    }

    private func setupTextDisplay(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: sizes.button.fontSize, weight: .regular)
        label.textAlignment = .center
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        primaryLabel = label
    }

    /// Updates the icon for an `.icon` display type button.
    func updateIcon(_ systemName: String) {
        guard let iconView else { return }
        let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
        iconView.image = UIImage(systemName: systemName, withConfiguration: config)
    }

    private func setupIconDisplay(_ systemName: String) {
        let config = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
        let imageView = UIImageView(image: UIImage(systemName: systemName, withConfiguration: config))
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .label
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6)
        ])

        iconView = imageView
    }

    /// CATextLayer-based dual text display for smooth swipe animations
    private func setupDualTextLayerDisplay(primary: String, secondary: String) {
        let scale = traitCollection.displayScale
        let font = UIFont.systemFont(ofSize: sizes.button.fontSize, weight: .medium)

        // Primary text layer
        let primaryLayer = CATextLayer()
        primaryLayer.string = primary
        primaryLayer.font = font
        primaryLayer.fontSize = font.pointSize
        primaryLayer.contentsScale = scale
        primaryLayer.alignmentMode = .center
        primaryLayer.allowsFontSubpixelQuantization = true
        layer.addSublayer(primaryLayer)
        primaryTextLayer = primaryLayer

        // Secondary text layer (added first so it renders behind primary)
        let secondaryLayer = CATextLayer()
        secondaryLayer.string = secondary
        secondaryLayer.font = font
        secondaryLayer.fontSize = font.pointSize
        secondaryLayer.contentsScale = scale
        secondaryLayer.alignmentMode = .center
        secondaryLayer.allowsFontSubpixelQuantization = true
        layer.insertSublayer(secondaryLayer, below: primaryLayer)
        secondaryTextLayer = secondaryLayer

        // Enable rasterization for performance
        layer.rasterizationScale = scale
        layer.shouldRasterize = true
        layer.masksToBounds = true
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        let width = isWideButton ? sizes.button.wideWidth : sizes.button.normalWidth
        return CGSize(width: width, height: sizes.button.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let primaryLayer = primaryTextLayer,
              let secondaryLayer = secondaryTextLayer else {
            return
        }

        let parentSize = bounds.size
        let center = CGPoint(x: parentSize.width * 0.5, y: parentSize.height * 0.5)

        // Get preferred sizes
        let primarySize = primaryLayer.preferredFrameSize()
        let secondarySize = secondaryLayer.preferredFrameSize()

        primaryLayer.bounds = CGRect(origin: .zero, size: primarySize)
        secondaryLayer.bounds = CGRect(origin: .zero, size: secondarySize)
        primaryLayer.position = center
        secondaryLayer.position = center

        // Secondary layer transforms (starts small/faded at top, ends full-size/visible at center)
        let secondaryScale: CGFloat = 0.55 + 0.45 * swipeProgress
        let sz = parentSize.height * 0.3  // Vertical offset magnitude
        let secondaryTy: CGFloat = -sz + sz * swipeProgress
        let secondaryOpacity: CGFloat = 0.3 + 0.7 * swipeProgress

        secondaryLayer.foregroundColor = UIColor.label.withAlphaComponent(secondaryOpacity).cgColor
        secondaryLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(secondaryScale, secondaryScale, 1),
            CATransform3DMakeTranslation(0, secondaryTy, 0)
        )

        // Primary layer transforms (starts full-size/visible at center, ends shrunk/faded moving down)
        let primaryScale: CGFloat = 1 - swipeProgress
        let primaryTy: CGFloat = 14 * swipeProgress
        let primaryOpacity: CGFloat = 1 - 0.5 * swipeProgress

        primaryLayer.foregroundColor = UIColor.label.withAlphaComponent(primaryOpacity).cgColor
        primaryLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(primaryScale, primaryScale, 1),
            CATransform3DMakeTranslation(0, primaryTy, 0)
        )
    }

    // MARK: - Touch Handling for Dual-Text Swipe

    override var allowsDownwardTouchSelection: Bool {
        if case .dualText = displayType { return true }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // For dual-text, track starting position for swipe
        if case .dualText = displayType, let touch = touches.first {
            guard beginTouchInteraction(touches) else { return }
            SystemShiftReader.shared.noteTouchEvent(event)
            touchFirstLocation = touch.location(in: self)
            isHighlighted = true
            if !yieldsToScrolling { playHaptic() }
        } else {
            // Non-dual-text uses standard behavior
            super.touchesBegan(touches, with: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard case .dualText = displayType, let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }

        guard validateTouchInteraction() else { return }
        let loc = touch.location(in: self)
        let completeDY = bounds.height - 10  // Full swipe distance

        // Calculate vertical progress (0 to 1)
        let dy = min(max(loc.y - touchFirstLocation.y, 0), completeDY)
        swipeProgress = dy / completeDY

        // Cancel parent scroll if user is clearly swiping on this button
        if swipeProgress > 0.15 {
            delegate?.cancelScrollTouches()
        }

        // Update layout instantly (no implicit animations)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setNeedsLayout()
        layoutIfNeeded()
        CATransaction.commit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard case .dualText = displayType else {
            super.touchesEnded(touches, with: event)
            return
        }

        guard validateTouchInteraction() else { return }
        defer { finishTouchTracking() }
        isHighlighted = false

        // Determine which key to trigger based on final progress
        let triggeredKey: String
        if swipeProgress < 0.75 {
            triggeredKey = primaryValue ?? key
        } else {
            triggeredKey = secondaryValue ?? key
        }

        // Send the key
        let modifiers = currentModifiers()
        if yieldsToScrolling { playHaptic() }
        delegate?.keyPressed(triggeredKey, modifiers: modifiers)

        // Reset progress with animation
        resetSwipeProgress(animated: true)
    }

    override func cancelTouchInteraction() {
        super.cancelTouchInteraction()
        if case .dualText = displayType {
            resetSwipeProgress(animated: true)
        }
    }

    private func resetSwipeProgress(animated: Bool) {
        swipeProgress = 0

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            setNeedsLayout()
            layoutIfNeeded()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setNeedsLayout()
            layoutIfNeeded()
            CATransaction.commit()
        }
    }

    // MARK: - Active State

    private func updateActiveAppearance() {
        UIView.animate(withDuration: 0.1) {
            self.applyFill()
        }
    }

    override func applyFill() {
        if isActive {
            backgroundColor = fill.active
        } else {
            super.applyFill()
        }
    }

    // MARK: - Size and Trait Updates

    override func updateSizes(_ newSizes: KeyboardSizes) {
        super.updateSizes(newSizes)

        switch displayType {
        case .text:
            primaryLabel?.font = .systemFont(ofSize: newSizes.button.fontSize, weight: .regular)

        case .icon(let systemName):
            let config = UIImage.SymbolConfiguration(pointSize: newSizes.button.symbolSize, weight: .medium)
            iconView?.image = UIImage(systemName: systemName, withConfiguration: config)

        case .dualText:
            let font = UIFont.systemFont(ofSize: newSizes.button.fontSize, weight: .medium)
            primaryTextLayer?.font = font
            primaryTextLayer?.fontSize = font.pointSize
            secondaryTextLayer?.font = font
            secondaryTextLayer?.fontSize = font.pointSize
            setNeedsLayout()
        }
    }

}
