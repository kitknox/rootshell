#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore

final class TerminalTouchSteampunkKeycap: TerminalTouchKeycap {
    private typealias Art = TerminalTouchSteampunkArtwork
    weak var machinery: TerminalTouchSteampunkMachineryView? {
        didSet {
            guard machinery !== oldValue else { return }
            oldValue?.setContact(self, pressed: false)
            if pressed { machinery?.setContact(self, pressed: true, strength: contactStrength) }
        }
    }
    private let small: Bool
    private let drawer: Bool
    private let subtitleLabel = UILabel()
    private let artwork = UIImageView()
    private let socket = CAShapeLayer()
    private let contactRim = CAShapeLayer()
    private let homeMark = CAShapeLayer()
    private let selectionLamp = CAShapeLayer()
    private let lockBadge = UIImageView(image: UIImage(systemName: "lock.fill"))
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let palette: TerminalTouchKeyboardPalette?
        let style: UIUserInterfaceStyle
        let contrast: Bool
    }
    private var prepared: Prepared?
    private var materials: [Art.Material] = []
    private var images: [UIImage?] = []
    private var displayedIndex: Int?

    override var palette: TerminalTouchKeyboardPalette? { didSet { updateColor() } }
    override var selected: Bool { didSet { if selected != oldValue { applyState() } } }
    override var locked: Bool {
        didSet {
            guard locked != oldValue else { return }
            updateIndicators(); setNeedsLayout()
        }
    }
    override var pressed: Bool {
        didSet {
            guard pressed != oldValue else { return }
            applyState()
            animateContact()
            machinery?.setContact(self, pressed: pressed, strength: contactStrength)
        }
    }

    private var character: Bool { if case .text = key.action { return true }; return false }
    private var supportsSelection: Bool { switch key.action { case .modifier, .drawer: return true; default: return false } }
    private var role: Art.Role { small ? .toolbar : (character && !drawer ? .letter : .utility) }
    private var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !UIAccessibility.isDarkerSystemColorsEnabled && traitCollection.accessibilityContrast != .high
    }
    private var travel: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return ((small ? 0.8 : 1.6) * scale).rounded() / scale
    }
    private var contactStrength: Double {
        switch key.action {
        case .text(" "): 1.15
        case .key("\r"), .key("\n"): 1.35
        case .modifier: 0.72
        default: 1
        }
    }

    init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false, drawer: Bool = false, subtitle: String? = nil) {
        self.small = small; self.drawer = drawer
        super.init(key, small: small)
        isAccessibilityElement = true
        accessibilityLabel = key.accessibility ?? key.title
        accessibilityTraits = [.keyboardKey]
        layer.addSublayer(socket)
        socket.fillColor = UIColor.black.withAlphaComponent(0.7).cgColor
        socket.strokeColor = Art.RGB(0.45, 0.31, 0.15).ui.withAlphaComponent(0.7).cgColor
        socket.lineWidth = 0.65
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        artwork.isUserInteractionEnabled = false
        plate.addSubview(artwork)
        contactRim.fillColor = UIColor.clear.cgColor
        plate.layer.addSublayer(contactRim)
        homeMark.fillColor = UIColor.clear.cgColor
        homeMark.lineCap = .round; homeMark.lineWidth = 1
        plate.layer.addSublayer(homeMark)
        label.text = key.title
        label.textAlignment = .center
        label.baselineAdjustment = .alignCenters
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.70
        plate.addSubview(label)
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        subtitleLabel.textAlignment = .center
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.65
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        plate.addSubview(subtitleLabel)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: small ? 16 : 20, weight: .medium)
        plate.addSubview(icon)
        plate.layer.addSublayer(selectionLamp)
        lockBadge.contentMode = .scaleAspectFit
        lockBadge.isHidden = true
        lockBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        plate.addSubview(lockBadge)
        setSymbol(key.symbol)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchSteampunkKeycap, _: UITraitCollection) in
            self.updateColor(); self.finishVisualTransition(); self.setNeedsLayout()
        }
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = max(1, traitCollection.displayScale)
        // Exactly the existing inset and typing cell. A rounder *visible* cap
        // reveals the machinery without reducing its rectangular touch target.
        let rect = bounds.insetBy(dx: drawer ? 1 : 3, dy: drawer ? 1 : 5)
        let size = CGSize(width: max(0, floor(rect.width * scale) / scale), height: max(0, floor(rect.height * scale) / scale))
        plate.bounds = CGRect(origin: .zero, size: size)
        plate.center = CGPoint(x: bounds.midX, y: bounds.midY)
        plate.isHidden = size.width <= 6 || size.height <= 6
        let r = Art.radius(size: size, role: role)
        socket.path = plate.isHidden ? nil : UIBezierPath(roundedRect: CGRect(x: plate.center.x - size.width / 2 - 0.5,
            y: plate.center.y - size.height / 2 + 1, width: size.width + 1, height: size.height + 1), cornerRadius: r + 0.5).cgPath
        let preferred: CGFloat = small ? 13 : (drawer ? (subtitleLabel.isHidden ? 16 : 12) : (key.title.count == 1 ? 24 * legendScale : 15))
        let font = UIFont.systemFont(ofSize: min(preferred, max(10, size.height * 0.63)), weight: character && !small ? legendWeight(.medium) : .semibold)
        if character && key.title.count == 1 && !small && !drawer, let descriptor = font.fontDescriptor.withDesign(.serif) {
            label.font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else { label.font = font }
        let labelInset: CGFloat = small || drawer ? 5 : 4
        label.frame = CGRect(x: labelInset, y: 1, width: max(0, size.width - labelInset * 2), height: max(0, size.height - 3))
        if !subtitleLabel.isHidden {
            let subtitleHeight = min(14, size.height * 0.38)
            label.frame.size.height = max(0, size.height - subtitleHeight - 4)
            subtitleLabel.frame = CGRect(x: 5, y: label.frame.maxY, width: max(0, size.width - 10), height: subtitleHeight)
        }
        let iconSize = CGSize(width: min(23, max(0, size.width - 9)), height: min(22, max(0, size.height - (locked ? 11 : 8))))
        icon.frame = CGRect(x: (size.width - iconSize.width) / 2, y: (size.height - iconSize.height) / 2 - (locked ? 1.5 : 0),
                            width: iconSize.width, height: iconSize.height)
        lockBadge.frame = CGRect(x: size.width / 2 + 6, y: size.height - 9, width: 6, height: 6)
        let lamp = UIBezierPath(roundedRect: CGRect(x: size.width / 2 - 5, y: size.height - 4, width: 10, height: 1.6), cornerRadius: 0.8)
        selectionLamp.path = lamp.cgPath
        let mark = UIBezierPath()
        if key.action == .text("f") || key.action == .text("j") || key.action == .text(" ") {
            let halfWidth: CGFloat = key.action == .text(" ") ? min(14, size.width * 0.12) : 2.3
            mark.move(to: CGPoint(x: size.width / 2 - halfWidth, y: size.height - 4.5))
            mark.addLine(to: CGPoint(x: size.width / 2 + halfWidth, y: size.height - 4.5))
        }
        homeMark.path = mark.cgPath
        contactRim.path = plate.isHidden ? nil : UIBezierPath(roundedRect: plate.bounds.insetBy(dx: 1, dy: 1), cornerRadius: max(0, r - 1)).cgPath
        contactRim.lineWidth = 1 / scale
        updateColor()
        CATransaction.commit()
    }

    override func updateColor() {
        let next = Prepared(size: plate.bounds.size, scale: max(1, traitCollection.displayScale), palette: palette,
                            style: traitCollection.userInterfaceStyle,
                            contrast: UIAccessibility.isDarkerSystemColorsEnabled || traitCollection.accessibilityContrast == .high)
        guard next != prepared else { applyState(); return }
        prepared = next
        let selectionStates = supportsSelection ? [false, true] : [false]
        materials = selectionStates.flatMap { selected in
            [false, true].map { _ in Art.Material(palette: palette, traits: traitCollection, utility: !character || small, selected: selected) }
        }
        images = materials.enumerated().map { index, material in
            Art.cap(size: next.size, scale: next.scale, material: material, role: role, pressed: index % 2 == 1)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artwork.frame = plate.bounds.insetBy(dx: -Art.padding, dy: -Art.padding)
        CATransaction.commit()
        displayedIndex = nil
        applyState()
    }

    private func applyState() {
        let index = (supportsSelection && selected ? 2 : 0) + (pressed ? 1 : 0)
        guard materials.indices.contains(index), displayedIndex != index else { updateIndicators(); return }
        displayedIndex = index
        let material = materials[index]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artwork.image = images.indices.contains(index) ? images[index] : nil
        plate.backgroundColor = artwork.image == nil ? material.face.ui : .clear
        let ink = legendInk(material.ink.ui, selected: index >= 2)
        label.textColor = ink; subtitleLabel.textColor = ink
        icon.tintColor = ink; lockBadge.tintColor = ink
        homeMark.strokeColor = material.ink.ui.withAlphaComponent(material.highContrast ? 1 : 0.5).cgColor
        contactRim.strokeColor = (material.highContrast ? material.ink.ui : Art.RGB(1, 0.83, 0.43).ui).cgColor
        contactRim.opacity = pressed ? 0.85 : 0
        selectionLamp.fillColor = (material.highContrast ? material.ink.ui : Art.RGB(1, 0.76, 0.32).ui).cgColor
        CATransaction.commit()
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
        updateIndicators()
    }
    private func updateIndicators() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionLamp.isHidden = !selected
        lockBadge.isHidden = !locked
        CATransaction.commit()
    }

    private func animateContact() {
        let previous = plate.layer.presentation()?.transform.m42 ?? plate.layer.transform.m42
        finishVisualTransition()
        guard motionAllowed, window != nil, !isHidden, !plate.isHidden else { return }
        let target = pressed ? travel : 0
        let animation: CABasicAnimation
        if pressed {
            let down = CABasicAnimation(keyPath: "transform.translation.y")
            down.duration = 0.045; down.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation = down
        } else {
            let spring = CASpringAnimation(keyPath: "transform.translation.y")
            spring.mass = 0.7; spring.stiffness = 720; spring.damping = 39
            spring.duration = min(0.25, spring.settlingDuration)
            animation = spring
        }
        animation.fromValue = previous; animation.toValue = target
        plate.layer.add(animation, forKey: "steampunk.contactTravel")
    }
    override func finishVisualTransition() {
        plate.layer.removeAnimation(forKey: "steampunk.contactTravel")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plate.layer.transform = CATransform3DMakeTranslation(0, pressed && motionAllowed ? travel : 0, 0)
        CATransaction.commit()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { machinery?.setContact(self, pressed: false) }
        else { updateColor() }
        finishVisualTransition()
    }
}

final class TerminalTouchSteampunkKeyPreview: TerminalTouchKeyPreview {
    private typealias Art = TerminalTouchSteampunkArtwork
    private let artwork = UIImageView()
    private var preparedSize = CGSize.zero
    private var preparedScale: CGFloat = 0
    private var preparedMaterial: Art.Material?
    override var palette: TerminalTouchKeyboardPalette? { didSet { prepareArtwork() } }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 55))
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        addSubview(artwork)
        legend = (31, .medium)
        label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.65
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchSteampunkKeyPreview, _: UITraitCollection) in self.prepareArtwork()
        }
        prepareArtwork()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func legendFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? font
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 6, dy: 4)
        prepareArtwork()
    }
    private func prepareArtwork() {
        let material = Art.Material(palette: palette, traits: traitCollection)
        let scale = max(1, traitCollection.displayScale)
        guard preparedMaterial != material || preparedSize != bounds.size || preparedScale != scale else { return }
        preparedMaterial = material; preparedSize = bounds.size; preparedScale = scale
        artwork.frame = bounds.insetBy(dx: -Art.padding, dy: -Art.padding)
        artwork.image = Art.cap(size: bounds.size, scale: scale, material: material, role: .preview, pressed: false)
        label.textColor = material.ink.ui
    }
}

final class TerminalTouchSteampunkDrawerButton: TerminalTouchDrawerButton {
    init(key: TerminalTouchKeyboardModel.Key, subtitle: String?, toolbar: Bool, palette: TerminalTouchKeyboardPalette?) {
        super.init(keycap: TerminalTouchSteampunkKeycap(key, small: toolbar, drawer: true, subtitle: subtitle))
        keycap.isUserInteractionEnabled = false; keycap.isAccessibilityElement = false; keycap.accessibilityElementsHidden = true
        keycap.palette = palette
        addSubview(keycap)
        accessibilityTraits.insert(.keyboardKey)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); keycap.frame = bounds }
    override var isSelected: Bool { didSet { keycap.selected = isSelected } }
    override func updateContactAppearance() { keycap.pressed = contactPressed }
    override func cancelInteraction() { super.cancelInteraction(); keycap.finishVisualTransition() }
}
#endif
