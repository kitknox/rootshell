#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore

// MARK: - Key material math

/// Keep the legend-readable part of the material independent of its lighting.
/// These sRGB calculations are also exercised by the standalone validation script.
private struct TerminalTouchKeyColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        func channel(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.red = channel(red)
        self.green = channel(green)
        self.blue = channel(blue)
    }

    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 1, green: 1, blue: 1)

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: Self) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func mixed(toward other: Self, amount: Double) -> Self {
        let amount = amount.isFinite ? min(1, max(0, amount)) : 0
        return Self(red: red + (other.red - red) * amount,
                    green: green + (other.green - green) * amount,
                    blue: blue + (other.blue - blue) * amount)
    }

    func readableInk(preferred: Self) -> Self {
        if contrast(with: preferred) >= 4.5 { return preferred }
        return contrast(with: .black) >= contrast(with: .white) ? .black : .white
    }

    /// Lighting may approach, but must not cross, the legend's contrast limit.
    /// The renderer shades only toward black/white, so this search is monotonic.
    func lit(toward light: Self, amount: Double, ink: Self) -> Self {
        let amount = amount.isFinite ? min(1, max(0, amount)) : 0
        let brighterThanInk = luminance >= ink.luminance
        func readable(_ color: Self) -> Bool {
            color.contrast(with: ink) >= 4.5 && (color.luminance >= ink.luminance) == brighterThanInk
        }
        let candidate = mixed(toward: light, amount: amount)
        if readable(candidate) { return candidate }
        var lower = 0.0, upper = amount
        for _ in 0..<16 {
            let middle = (lower + upper) / 2
            if readable(mixed(toward: light, amount: middle)) {
                lower = middle
            } else {
                upper = middle
            }
        }
        return mixed(toward: light, amount: lower)
    }

    var cacheKey: String {
        [red, green, blue].map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
    }
}

// MARK: - UIKit key artwork

@MainActor
private extension TerminalTouchKeyColor {
    init(_ color: UIColor, traits: UITraitCollection) {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            _ = resolved.getWhite(&red, alpha: &alpha)
            green = red
            blue = red
        }
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    var uiColor: UIColor { UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1) }
}

/// A small, reusable texture atlas, not a running shader. Labels and symbols stay
/// live UIKit content: glyphs are never baked into, blurred with, or scaled by it.
@MainActor
private enum TerminalTouchKeyArtwork {
    enum Role: Int { case character, utility, toolbar, preview }

    struct Finish: Equatable {
        let surface: TerminalTouchKeyColor
        let ink: TerminalTouchKeyColor
        let role: Role
        let pressed: Bool
        let selected: Bool
        let increasedContrast: Bool

        init(surface: TerminalTouchKeyColor, ink: TerminalTouchKeyColor, role: Role,
             pressed: Bool, selected: Bool, increasedContrast: Bool) {
            self.surface = surface
            self.ink = surface.readableInk(preferred: ink)
            self.role = role
            self.pressed = pressed
            self.selected = selected
            self.increasedContrast = increasedContrast
        }

        var padding: CGFloat { role == .preview ? 10 : 5 }
        var cacheKey: String {
            "\(surface.cacheKey)/\(ink.cacheKey)/\(role.rawValue)/\(pressed)/\(selected)/\(increasedContrast)"
        }
        func radius(in size: CGSize) -> CGFloat {
            min(role == .toolbar || role == .preview ? 12 : 8.5, min(size.width, size.height) * 0.32)
        }
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func image(size: CGSize, scale: CGFloat, finish: Finish) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 2, size.height > 2, scale > 0,
              size.width * scale < 8192, size.height * scale < 8192,
              size.width * size.height * scale * scale <= 2 * 1024 * 1024 else { return nil }
        let width = ceil(size.width * scale), height = ceil(size.height * scale)
        let key = "\(width)/\(height)/\(scale)/\(finish.cacheKey)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let padding = finish.padding
        let faceSize = CGSize(width: width / scale, height: height / scale)
        let size = CGSize(width: faceSize.width + padding * 2, height: faceSize.height + padding * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(origin: CGPoint(x: padding, y: padding), size: faceSize)
            let radius = finish.radius(in: faceSize)
            let face = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            let dark = finish.surface.luminance < 0.35
            let depth: CGFloat = finish.pressed ? 0.35 : (finish.role == .toolbar ? 0.7 : 1.4)

            // A separate lower skirt gives travel a physical reference. Shadows
            // are part of the cached bitmap, not per-key live blur passes.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: finish.role == .preview ? 2 : 0.7),
                              blur: finish.pressed ? 0.6 : (finish.role == .preview ? 5 : 1.8),
                              color: UIColor.black.withAlphaComponent(dark ? 0.30 : 0.20).cgColor)
            finish.surface.mixed(toward: .black, amount: dark ? 0.42 : 0.22).uiColor.setFill()
            UIBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: depth), cornerRadius: radius).fill()
            context.restoreGState()

            context.saveGState()
            face.addClip()
            let strength = finish.role == .utility || finish.role == .toolbar ? 0.65 : 1.0
            let top = finish.surface.lit(toward: finish.pressed ? .black : .white,
                                         amount: (finish.pressed ? 0.045 : 0.13) * strength, ink: finish.ink)
            let bottom = finish.surface.lit(toward: .black,
                                            amount: (finish.pressed ? 0.018 : 0.055) * strength, ink: finish.ink)
            // Every stop underneath a legend retains at least 4.5:1 contrast.
            gradient(context, colors: [top.uiColor, finish.surface.uiColor, finish.surface.uiColor, bottom.uiColor],
                     locations: [0, 0.28, 0.64, 1], from: CGPoint(x: rect.midX, y: rect.minY),
                     to: CGPoint(x: rect.midX, y: rect.maxY))
            context.restoreGState()

            // The two edge treatments stay outside the legend area: a dark
            // hairline seats the cap, a directional bevel catches the light.
            let pixel = 1 / scale
            let rim = UIBezierPath(roundedRect: rect.insetBy(dx: pixel / 2, dy: pixel / 2),
                                   cornerRadius: max(0, radius - pixel / 2))
            rim.lineWidth = pixel
            UIColor.black.withAlphaComponent(dark ? 0.35 : 0.15).setStroke()
            rim.stroke()
            let bevelInset = finish.increasedContrast ? 0.8 : pixel * 1.5
            let bevel = UIBezierPath(roundedRect: rect.insetBy(dx: bevelInset, dy: bevelInset),
                                     cornerRadius: max(0, radius - bevelInset))
            if finish.increasedContrast {
                finish.ink.uiColor.setStroke()
                bevel.lineWidth = 1
                bevel.stroke()
            } else {
                context.saveGState()
                context.addPath(bevel.cgPath)
                context.setLineWidth(pixel)
                context.replacePathWithStrokedPath()
                context.clip()
                let highlight: CGFloat = finish.pressed ? 0.12 : (dark ? 0.36 : 0.90)
                gradient(context, colors: [UIColor.white.withAlphaComponent(highlight),
                                           UIColor.white.withAlphaComponent(0.035),
                                           UIColor.black.withAlphaComponent(dark ? 0.15 : 0.08)],
                         locations: [0, 0.55, 1], from: CGPoint(x: rect.minX, y: rect.minY),
                         to: CGPoint(x: rect.maxX * 0.65, y: rect.maxY))
                context.restoreGState()
            }
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private static func gradient(_ context: CGContext, colors: [UIColor], locations: [CGFloat],
                                 from start: CGPoint, to end: CGPoint) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: colors.map { $0.cgColor } as CFArray, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

final class TerminalTouchSculptedKeycap: TerminalTouchKeycap {
    private let subtitleLabel = UILabel()
    private let drawerKey: Bool
    private let artwork = UIImageView()
    private let contactLight = CAShapeLayer()
    private let homeRidge = CALayer()
    private let lockIndicator = UIView()
    private let toolbarKey: Bool
    private var finishes: [TerminalTouchKeyArtwork.Finish] = []
    private var images: [UIImage?] = []
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let palette: TerminalTouchKeyboardPalette?
        let dark: Bool
        let increasedContrast: Bool
    }
    private var prepared: Prepared?
    private var displayedIndex: Int?
    override var palette: TerminalTouchKeyboardPalette? { didSet { updateColor() } }
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
        }
    }
    override var selected: Bool { didSet { if selected != oldValue { applyState() } } }

    private var supportsSelection: Bool {
        switch key.action { case .modifier, .drawer: return true; default: return false }
    }
    private var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    private var travel: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return ((toolbarKey ? 0.65 : 1.2) * scale).rounded() / scale
    }

    init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false, drawer: Bool = false, subtitle: String? = nil) {
        drawerKey = drawer
        self.toolbarKey = small
        super.init(key, small: small)
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        accessibilityLabel = key.accessibility ?? key.title
        plate.isUserInteractionEnabled = false
        plate.layer.cornerCurve = .continuous
        addSubview(plate)
        artwork.isUserInteractionEnabled = false
        plate.addSubview(artwork)
        contactLight.fillColor = UIColor.clear.cgColor
        contactLight.opacity = 0
        plate.layer.addSublayer(contactLight)
        homeRidge.isHidden = key.action != .text(" ")
        plate.layer.addSublayer(homeRidge)
        label.textAlignment = .center
        label.baselineAdjustment = .alignCenters
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.text = key.title
        plate.addSubview(label)
        subtitleLabel.text = subtitle
        subtitleLabel.textAlignment = .center
        subtitleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.65
        subtitleLabel.isHidden = subtitle == nil
        plate.addSubview(subtitleLabel)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: small ? 17 : 21, weight: .medium)
        plate.addSubview(icon)
        lockIndicator.layer.cornerRadius = 1.5
        lockIndicator.isHidden = true
        plate.addSubview(lockIndicator)
        setSymbol(key.symbol)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchSculptedKeycap, _: UITraitCollection) in
            self.updateColor()
            self.finishVisualTransition()
            self.setNeedsLayout()
        }
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Only this non-interactive plate moves. The cap and its typing cell
        // retain exactly the original hit geometry, including the full gutters.
        let rect = bounds.insetBy(dx: drawerKey ? 1 : 3, dy: drawerKey ? 1 : 5)
        let scale = max(1, traitCollection.displayScale)
        plate.bounds = CGRect(origin: .zero, size: CGSize(
            width: max(0, (rect.width * scale).rounded(.down) / scale),
            height: max(0, (rect.height * scale).rounded(.down) / scale)))
        plate.center = CGPoint(x: bounds.midX, y: bounds.midY)
        plate.isHidden = plate.bounds.width <= 2 || plate.bounds.height <= 2
        let height = plate.bounds.height
        let preferred: CGFloat = toolbarKey ? 13 : (drawerKey
            ? (subtitleLabel.isHidden && key.title.count <= 4 ? 17 : 12)
            : (key.title.count == 1 ? 25 * legendScale : 16))
        label.font = .systemFont(ofSize: min(preferred, max(12, height - 6)),
                                 weight: toolbarKey || drawerKey || key.title.count > 1 ? .medium : legendWeight(.regular))
        label.frame = CGRect(x: 3, y: 0, width: max(0, plate.bounds.width - 6), height: max(0, height - (locked ? 4 : 0)))
        if drawerKey {
            label.numberOfLines = subtitleLabel.isHidden ? 2 : 1
            if !subtitleLabel.isHidden {
                let subtitleHeight = min(15, height * 0.45)
                label.frame.size.height = max(0, height - subtitleHeight - 2)
                subtitleLabel.frame = CGRect(x: 3, y: label.frame.maxY, width: label.frame.width, height: subtitleHeight)
            }
        }
        lockIndicator.frame = CGRect(x: (plate.bounds.width - 14) / 2, y: height - 4, width: 14, height: 2.5)
        let iconSize = CGSize(width: min(24, max(0, plate.bounds.width - 8)), height: min(23, max(0, height - (locked ? 10 : 6))))
        icon.frame = CGRect(x: (plate.bounds.width - iconSize.width) / 2, y: (height - (locked ? 4 : 0) - iconSize.height) / 2,
                            width: iconSize.width, height: iconSize.height)
        let ridgeWidth = min(22, plate.bounds.width * 0.18)
        homeRidge.frame = CGRect(x: (plate.bounds.width - ridgeWidth) / 2, y: height - 3.5, width: ridgeWidth, height: 1 / scale)
        homeRidge.cornerRadius = 0.5 / scale
        updateColor()
        CATransaction.commit()
    }

    override func updateColor() {
        let character: Bool = { if case .text = key.action { return true }; return false }()
        let dark = traitCollection.userInterfaceStyle == .dark
        let increasedContrast = UIAccessibility.isDarkerSystemColorsEnabled || traitCollection.accessibilityContrast == .high
        let next = Prepared(size: plate.bounds.size, scale: max(1, traitCollection.displayScale),
                            palette: palette, dark: dark, increasedContrast: increasedContrast)
        // publishModifiers refreshes every legend after each character. Most
        // calls stop here; theme resolution and lighting math stay off that path.
        guard prepared != next else { applyState(); return }
        prepared = next
        let role: TerminalTouchKeyArtwork.Role = toolbarKey ? .toolbar : (character ? .character : .utility)
        func finish(selected: Bool, pressed: Bool) -> TerminalTouchKeyArtwork.Finish {
            let colors = TerminalTouchKeyboardModel.keyColors(dark: dark, pressed: pressed, selected: selected)
            var surface = TerminalTouchKeyColor(red: colors.background, green: colors.background,
                                                blue: colors.background + (dark && !selected ? 4 / 255 : 0))
            var ink = TerminalTouchKeyColor(red: colors.ink, green: colors.ink, blue: colors.ink)
            if let palette {
                surface = TerminalTouchKeyColor(selected ? palette.ink : (pressed ? palette.pressedKey : palette.key), traits: traitCollection)
                ink = TerminalTouchKeyColor(selected ? palette.key : (pressed ? palette.pressedInk : palette.ink), traits: traitCollection)
            }
            if toolbarKey && !selected {
                surface = TerminalTouchKeyColor(palette?.background ?? TerminalTouchKeyboardAppearance.toolbar, traits: traitCollection)
                ink = TerminalTouchKeyColor(palette?.toolbarInk ?? .label, traits: traitCollection)
                surface = surface.mixed(toward: ink, amount: pressed ? 0.12 : 0.035)
            }
            return .init(surface: surface, ink: ink, role: role, pressed: pressed, selected: selected,
                         increasedContrast: increasedContrast)
        }
        // Prewarm both contact states (and both modifier states) during layout
        // or an appearance change. The pressed/selected setters never rasterize.
        let selections = supportsSelection ? [false, true] : [false]
        finishes = selections.flatMap { selected in [false, true].map { finish(selected: selected, pressed: $0) } }
        images = finishes.map { TerminalTouchKeyArtwork.image(size: next.size, scale: next.scale, finish: $0) }
        if let finish = finishes.first {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artwork.frame = plate.bounds.insetBy(dx: -finish.padding, dy: -finish.padding)
            plate.layer.cornerRadius = finish.radius(in: plate.bounds.size)
            contactLight.frame = plate.bounds
            contactLight.path = plate.bounds.width > 3 && plate.bounds.height > 3
                ? UIBezierPath(roundedRect: plate.bounds.insetBy(dx: 1, dy: 1),
                               cornerRadius: max(0, plate.layer.cornerRadius - 1)).cgPath : nil
            contactLight.lineWidth = 1 / next.scale
            CATransaction.commit()
        }
        displayedIndex = nil
        applyState()
    }

    private func applyState() {
        let index = (selected && supportsSelection ? 2 : 0) + (pressed ? 1 : 0)
        guard displayedIndex != index, finishes.indices.contains(index) else { return }
        displayedIndex = index
        let finish = finishes[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.image = images.indices.contains(index) ? images[index] : nil
        plate.backgroundColor = artwork.image == nil ? finish.surface.uiColor : .clear
        let ink = legendInk(finish.ink.uiColor, selected: index >= 2)
        label.textColor = ink
        subtitleLabel.textColor = ink
        icon.tintColor = ink
        lockIndicator.backgroundColor = ink
        homeRidge.backgroundColor = ink.withAlphaComponent(finish.increasedContrast ? 0.8 : 0.28).cgColor
        contactLight.strokeColor = ink.withAlphaComponent(0.38).cgColor
        CATransaction.commit()
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
    }

    private func animateContact() {
        let previous = plate.layer.presentation()?.transform.m42 ?? plate.layer.transform.m42
        finishVisualTransition()
        guard motionAllowed, window != nil, !isHidden, !plate.isHidden else { return }
        let target: CGFloat = pressed ? travel : 0
        let motion: CABasicAnimation
        if pressed {
            let down = CABasicAnimation(keyPath: "transform.translation.y")
            down.duration = 0.045
            down.timingFunction = CAMediaTimingFunction(name: .easeOut)
            motion = down
        } else {
            let release = CASpringAnimation(keyPath: "transform.translation.y")
            release.mass = 0.6
            release.stiffness = 650
            release.damping = 36
            release.initialVelocity = 0
            release.duration = min(0.28, release.settlingDuration)
            motion = release
        }
        motion.fromValue = previous
        motion.toValue = target
        plate.layer.add(motion, forKey: "keyboard.contactTravel")
        // This means contact, not successful input: cancelled contacts must not
        // leave a delayed 'success' sparkle or any callback into the input path.
        if pressed && !UIAccessibility.isDarkerSystemColorsEnabled && traitCollection.accessibilityContrast != .high {
            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, 0.75, 0]
            light.keyTimes = [0, 0.22, 1]
            light.duration = 0.20
            contactLight.add(light, forKey: "keyboard.contactLight")
        }
    }

    override func finishVisualTransition() {
        plate.layer.removeAnimation(forKey: "keyboard.contactTravel")
        contactLight.removeAnimation(forKey: "keyboard.contactLight")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.layer.transform = CATransform3DMakeTranslation(0, pressed && motionAllowed ? travel : 0, 0)
        contactLight.opacity = 0
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        finishVisualTransition()
        if window != nil { updateColor() }
    }
}

/// Reuses the key's material without changing the existing preview's position,
/// timing, or text. It deliberately has no entrance animation or touch handling.
final class TerminalTouchSculptedKeyPreview: TerminalTouchKeyPreview {
    private let artwork = UIImageView()
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let palette: TerminalTouchKeyboardPalette?
        let dark: Bool
        let increasedContrast: Bool
    }
    private var prepared: Prepared?
    override var palette: TerminalTouchKeyboardPalette? { didSet { updateAppearance() } }

    init() {
        // Match showPreview's existing geometry and warm the texture before the
        // first key press. Subsequent origin-only moves reuse that same texture.
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 55))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        artwork.isUserInteractionEnabled = false
        addSubview(artwork)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchSculptedKeyPreview, _: UITraitCollection) in self.updateAppearance()
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 5, dy: 2)
        updateAppearance()
    }
    private func updateAppearance() {
        let next = Prepared(size: bounds.size, scale: max(1, traitCollection.displayScale), palette: palette,
                            dark: traitCollection.userInterfaceStyle == .dark,
                            increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled || traitCollection.accessibilityContrast == .high)
        guard prepared != next else { return }
        prepared = next
        let finish = TerminalTouchKeyArtwork.Finish(
            surface: TerminalTouchKeyColor(palette?.key ?? .secondarySystemBackground, traits: traitCollection),
            ink: TerminalTouchKeyColor(palette?.ink ?? .label, traits: traitCollection),
            role: .preview, pressed: false, selected: false,
            increasedContrast: next.increasedContrast)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.frame = bounds.insetBy(dx: -finish.padding, dy: -finish.padding)
        artwork.image = TerminalTouchKeyArtwork.image(size: next.size, scale: next.scale, finish: finish)
        label.textColor = finish.ink.uiColor
        CATransaction.commit()
    }
}

/// Drawer buttons share the main keycap renderer while retaining UIKit input.
final class TerminalTouchSculptedDrawerButton: TerminalTouchDrawerButton {
    init(key: TerminalTouchKeyboardModel.Key, subtitle: String?, toolbar: Bool,
         palette: TerminalTouchKeyboardPalette?) {
        super.init(keycap: TerminalTouchSculptedKeycap(key, small: toolbar, drawer: true, subtitle: subtitle))
        keycap.isUserInteractionEnabled = false
        keycap.isAccessibilityElement = false
        keycap.accessibilityElementsHidden = true
        keycap.palette = palette
        addSubview(keycap)
        accessibilityTraits.insert(.keyboardKey)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        keycap.frame = bounds
    }
    override var isSelected: Bool {
        didSet { keycap.selected = isSelected }
    }
    override func updateContactAppearance() {
        keycap.pressed = contactPressed
    }
    override func cancelInteraction() {
        super.cancelInteraction()
        keycap.finishVisualTransition()
    }
}


#endif
