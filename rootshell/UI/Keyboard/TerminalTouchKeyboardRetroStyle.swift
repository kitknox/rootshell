#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore

extension TerminalTouchKeyboardModel.Style {
    var retroDesign: TerminalTouchRetroArtwork.Design? {
        switch self {
        case .phosphor: .phosphor
        case .beigeBox: .beigeBox
        case .neonGrid: .neonGrid
        case .circuitBoard: .circuitBoard
        case .flat, .sculpted, .steampunk: nil
        }
    }
}

@MainActor
private func retroLegendFont(_ design: TerminalTouchRetroArtwork.Design, size: CGFloat, weight: UIFont.Weight) -> UIFont {
    switch design {
    case .phosphor, .circuitBoard: return .monospacedSystemFont(ofSize: size, weight: weight)
    case .beigeBox: return .systemFont(ofSize: size, weight: weight)
    case .neonGrid:
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
    }
}

/// Phosphor and Neon legends glow; the rasterized shadow is redrawn only when text changes.
@MainActor
private func applyRetroGlow(_ views: [UIView], material: TerminalTouchRetroArtwork.Material, scale: CGFloat) {
    let glows = (material.design == .phosphor || material.design == .neonGrid) && !material.highContrast
        && material.face.luminance < 0.3
    for view in views {
        view.layer.shadowColor = material.accent.ui.cgColor
        view.layer.shadowOffset = .zero
        view.layer.shadowRadius = material.design == .phosphor ? 3 : 2.5
        view.layer.shadowOpacity = glows ? 0.9 : 0
        view.layer.shouldRasterize = glows
        view.layer.rasterizationScale = scale
    }
}

final class TerminalTouchRetroKeycap: TerminalTouchKeycap {
    private typealias Art = TerminalTouchRetroArtwork
    weak var backdrop: TerminalTouchRetroBackdropView?
    private let design: Art.Design
    private let small: Bool
    private let drawer: Bool
    private let subtitleLabel = UILabel()
    private let artwork = UIImageView()
    private let homeMark = CAShapeLayer()
    private let lockIndicator = UIView()
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let palette: TerminalTouchKeyboardPalette?
        let style: UIUserInterfaceStyle
        let contrast: Bool
        let phosphor: TerminalTouchKeyboardModel.PhosphorColor
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
            lockIndicator.isHidden = !locked
            setNeedsLayout()
        }
    }
    override var pressed: Bool {
        didSet {
            guard pressed != oldValue else { return }
            applyState()
            animateContact()
            if pressed { backdrop?.strike(from: self) }
        }
    }

    private var character: Bool { if case .text = key.action { return true }; return false }
    private var supportsSelection: Bool { switch key.action { case .modifier, .drawer: return true; default: return false } }
    private var role: Art.Role { small ? .toolbar : (character && !drawer ? .letter : .utility) }
    private var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var travel: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        let distance: CGFloat = design == .beigeBox ? (small ? 1 : 2.2) : (small ? 0.6 : 1.1)
        return (distance * scale).rounded() / scale
    }

    init(_ key: TerminalTouchKeyboardModel.Key, design: TerminalTouchRetroArtwork.Design, small: Bool = false,
         drawer: Bool = false, subtitle: String? = nil) {
        self.design = design; self.small = small; self.drawer = drawer
        super.init(key, small: small)
        isAccessibilityElement = true
        accessibilityLabel = key.accessibility ?? key.title
        accessibilityTraits = [.keyboardKey]
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        artwork.isUserInteractionEnabled = false
        plate.addSubview(artwork)
        homeMark.fillColor = UIColor.clear.cgColor
        homeMark.lineCap = .round; homeMark.lineWidth = 1
        plate.layer.addSublayer(homeMark)
        label.text = key.title
        label.textAlignment = .center
        label.baselineAdjustment = .alignCenters
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
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
        lockIndicator.layer.cornerRadius = 1.25
        lockIndicator.isHidden = true
        plate.addSubview(lockIndicator)
        setSymbol(key.symbol)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchRetroKeycap, _: UITraitCollection) in
            self.updateColor(); self.finishVisualTransition(); self.setNeedsLayout()
        }
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = max(1, traitCollection.displayScale)
        let rect = bounds.insetBy(dx: drawer ? 1 : 3, dy: drawer ? 1 : 5)
        let size = CGSize(width: max(0, floor(rect.width * scale) / scale), height: max(0, floor(rect.height * scale) / scale))
        plate.bounds = CGRect(origin: .zero, size: size)
        plate.center = CGPoint(x: bounds.midX, y: bounds.midY)
        plate.isHidden = size.width <= 6 || size.height <= 6
        let preferred: CGFloat = small ? 13 : (drawer ? (subtitleLabel.isHidden ? 16 : 12) : (key.title.count == 1 ? 23 * legendScale : 15))
        let weight: UIFont.Weight = character && !small && !drawer ? legendWeight(.regular) : .medium
        label.font = retroLegendFont(design, size: min(preferred, max(10, size.height * 0.6)), weight: weight)
        let lift = Art.legendOffset(role: role, design: design, pressed: false)
        let bottom: CGFloat = locked ? 4 : 0
        label.frame = CGRect(x: 4, y: lift, width: max(0, size.width - 8), height: max(0, size.height - bottom))
        if !subtitleLabel.isHidden {
            let subtitleHeight = min(14, size.height * 0.38)
            label.frame.size.height = max(0, size.height - subtitleHeight - 4)
            subtitleLabel.frame = CGRect(x: 5, y: label.frame.maxY + lift, width: max(0, size.width - 10), height: subtitleHeight)
        }
        let iconSize = CGSize(width: min(23, max(0, size.width - 9)), height: min(22, max(0, size.height - (locked ? 11 : 8))))
        icon.frame = CGRect(x: (size.width - iconSize.width) / 2, y: (size.height - bottom - iconSize.height) / 2 + lift,
                            width: iconSize.width, height: iconSize.height)
        lockIndicator.frame = CGRect(x: (size.width - 14) / 2, y: size.height - 4.5 + lift, width: 14, height: 2.5)
        let mark = UIBezierPath()
        if key.action == .text("f") || key.action == .text("j") {
            mark.move(to: CGPoint(x: size.width / 2 - 2.5, y: size.height - 5 + lift))
            mark.addLine(to: CGPoint(x: size.width / 2 + 2.5, y: size.height - 5 + lift))
        }
        homeMark.path = mark.cgPath
        updateColor()
        CATransaction.commit()
    }

    override func updateColor() {
        let phosphor = SettingsStore.shared.value(Settings.Keyboard.touchPhosphorColor)
        let next = Prepared(size: plate.bounds.size, scale: max(1, traitCollection.displayScale), palette: palette,
                            style: traitCollection.userInterfaceStyle,
                            contrast: UIAccessibility.isDarkerSystemColorsEnabled || traitCollection.accessibilityContrast == .high,
                            phosphor: phosphor)
        guard next != prepared else { applyState(); return }
        prepared = next
        let selections = supportsSelection ? [false, true] : [false]
        materials = selections.flatMap { selected in
            [false, true].map { pressed in
                Art.Material(design: design, palette: palette, traits: traitCollection, phosphor: phosphor,
                             utility: !character || small, selected: selected, pressed: pressed)
            }
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
        guard materials.indices.contains(index), displayedIndex != index else { return }
        displayedIndex = index
        let material = materials[index]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artwork.image = images.indices.contains(index) ? images[index] : nil
        plate.backgroundColor = artwork.image == nil ? material.face.ui : .clear
        let ink = legendInk(material.ink.ui, selected: index >= 2)
        label.textColor = ink; subtitleLabel.textColor = ink
        icon.tintColor = ink; lockIndicator.backgroundColor = ink
        homeMark.strokeColor = ink.withAlphaComponent(material.highContrast ? 1 : 0.5).cgColor
        applyRetroGlow([label, icon], material: material, scale: max(1, traitCollection.displayScale))
        CATransaction.commit()
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
    }

    private func animateContact() {
        let previous = plate.layer.presentation()?.transform.m42 ?? plate.layer.transform.m42
        finishVisualTransition()
        guard motionAllowed, window != nil, !isHidden, !plate.isHidden else { return }
        let animation: CABasicAnimation
        if pressed {
            let down = CABasicAnimation(keyPath: "transform.translation.y")
            down.duration = design == .beigeBox ? 0.06 : 0.045
            down.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation = down
        } else {
            let spring = CASpringAnimation(keyPath: "transform.translation.y")
            spring.mass = 0.6; spring.stiffness = design == .beigeBox ? 520 : 680; spring.damping = 34
            spring.duration = min(0.28, spring.settlingDuration)
            animation = spring
        }
        animation.fromValue = previous; animation.toValue = pressed ? travel : 0
        plate.layer.add(animation, forKey: "retro.contactTravel")
    }
    override func finishVisualTransition() {
        plate.layer.removeAnimation(forKey: "retro.contactTravel")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plate.layer.transform = CATransform3DMakeTranslation(0, pressed && motionAllowed ? travel : 0, 0)
        CATransaction.commit()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateColor() }
        finishVisualTransition()
    }
}

final class TerminalTouchRetroKeyPreview: TerminalTouchKeyPreview {
    private typealias Art = TerminalTouchRetroArtwork
    private let design: Art.Design
    private let artwork = UIImageView()
    private var prepared: (size: CGSize, scale: CGFloat, material: Art.Material)?
    override var palette: TerminalTouchKeyboardPalette? { didSet { prepareArtwork() } }

    init(design: TerminalTouchRetroArtwork.Design) {
        self.design = design
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 55))
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        addSubview(artwork)
        legend = (30, .regular)
        label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.6
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchRetroKeyPreview, _: UITraitCollection) in self.prepareArtwork()
        }
        prepareArtwork()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func legendFont(size: CGFloat, weight: UIFont.Weight) -> UIFont { retroLegendFont(design, size: size, weight: weight) }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 6, dy: 4)
        prepareArtwork()
    }
    private func prepareArtwork() {
        let material = Art.Material(design: design, palette: palette, traits: traitCollection,
                                    phosphor: SettingsStore.shared.value(Settings.Keyboard.touchPhosphorColor))
        let scale = max(1, traitCollection.displayScale)
        if let prepared, prepared.material == material, prepared.size == bounds.size, prepared.scale == scale { return }
        prepared = (bounds.size, scale, material)
        artwork.frame = bounds.insetBy(dx: -Art.padding, dy: -Art.padding)
        artwork.image = Art.cap(size: bounds.size, scale: scale, material: material, role: .preview, pressed: false)
        label.textColor = material.ink.ui
        applyRetroGlow([label], material: material, scale: scale)
    }
}

final class TerminalTouchRetroDrawerButton: TerminalTouchDrawerButton {
    init(key: TerminalTouchKeyboardModel.Key, design: TerminalTouchRetroArtwork.Design, subtitle: String?, toolbar: Bool,
         palette: TerminalTouchKeyboardPalette?) {
        super.init(keycap: TerminalTouchRetroKeycap(key, design: design, small: toolbar, drawer: true, subtitle: subtitle))
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
