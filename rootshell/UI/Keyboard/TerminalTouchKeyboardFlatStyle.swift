#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

final class TerminalTouchFlatKeycap: TerminalTouchKeycap {
    private let lockIndicator = UIView()
    private let toolbarKey: Bool
    override var palette: TerminalTouchKeyboardPalette? { didSet { updateColor() } }
    override var locked: Bool { didSet { lockIndicator.isHidden = !locked } }
    override var pressed: Bool { didSet { updateColor() } }
    override var selected: Bool { didSet { updateColor() } }

    override init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false) {
        self.toolbarKey = small
        super.init(key, small: small)
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        accessibilityLabel = key.accessibility ?? key.title
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = small ? 12 : 8
        plate.layer.cornerCurve = .continuous
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOffset = CGSize(width: 0, height: 1)
        plate.layer.shadowRadius = 0.5
        addSubview(plate)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: small ? 13 : (key.title.count == 1 ? 25 : 16), weight: small ? .medium : .regular)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.text = key.title
        plate.addSubview(label)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: small ? 17 : 21, weight: .regular)
        plate.addSubview(icon)
        lockIndicator.layer.cornerRadius = 1.5
        lockIndicator.isHidden = true
        plate.addSubview(lockIndicator)
        setSymbol(key.symbol)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds.insetBy(dx: 3, dy: 5)
        label.frame = plate.bounds.insetBy(dx: 3, dy: 0)
        lockIndicator.frame = CGRect(x: (plate.bounds.width - 14) / 2, y: plate.bounds.height - 4, width: 14, height: 2.5)
        let iconSize = CGSize(width: min(24, max(0, plate.bounds.width - 8)), height: min(23, max(0, plate.bounds.height - 6)))
        icon.frame = CGRect(x: (plate.bounds.width - iconSize.width) / 2, y: (plate.bounds.height - iconSize.height) / 2,
                            width: iconSize.width, height: iconSize.height)
        if toolbarKey {
            // Short titles like "~" read at icon size; text shrinks with the icon box.
            let preferred: CGFloat = key.title.count <= 4 ? 17 : 13
            let size = max(10, (preferred * iconSize.height / 23).rounded())
            if label.font.pointSize != size { label.font = .systemFont(ofSize: size, weight: .medium) }
        } else if key.title.count == 1 {
            let size = 25 * legendScale, weight = legendWeight(.regular)
            if label.font.pointSize != size { label.font = .systemFont(ofSize: size, weight: weight) }
        }
    }
    override func updateColor() {
        let character: Bool = { if case .text = key.action { return true }; return false }()
        let selected = self.selected, pressed = self.pressed, toolbarKey = self.toolbarKey
        // A keyboard can acquire its final appearance after attachment. Do not
        // mix a light-only background with a dynamically changing .label color.
        plate.backgroundColor = UIColor { traits in
            if toolbarKey && !selected {
                return pressed ? UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.12) : .clear
            }
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            if traits.userInterfaceStyle == .dark, !selected {
                return UIColor(red: colors.background, green: colors.background, blue: colors.background + 4 / 255, alpha: 1)
            }
            return UIColor(white: colors.background, alpha: 1)
        }
        var ink = UIColor { traits in
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            return UIColor(white: colors.ink, alpha: 1)
        }
        if let palette {
            ink = selected ? palette.key : (toolbarKey ? palette.toolbarInk : (pressed ? palette.pressedInk : palette.ink))
            plate.backgroundColor = selected ? palette.ink : (toolbarKey ? (pressed ? palette.toolbarInk.withAlphaComponent(0.12) : .clear) : (pressed ? palette.pressedKey : palette.key))
        }
        ink = legendInk(ink, selected: selected)
        label.textColor = ink
        icon.tintColor = ink
        lockIndicator.backgroundColor = ink
        plate.layer.shadowOpacity = toolbarKey || traitCollection.userInterfaceStyle == .dark ? 0 : 0.12
        plate.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled && (!toolbarKey || selected) ? 1 : 0
        plate.layer.borderColor = UIColor.label.cgColor
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
    }
}

final class TerminalTouchFlatKeyPreview: TerminalTouchKeyPreview {
    override var palette: TerminalTouchKeyboardPalette? {
        didSet {
            backgroundColor = palette?.key ?? .secondarySystemBackground
            label.textColor = palette?.ink ?? .label
        }
    }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 55))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.cornerRadius = 10
        clipsToBounds = true
        label.textAlignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}

/// Page drawers keep main's standard UIKit buttons with their tinted fill.
/// Toolbar drawers draw the main toolbar row's keycap so both scale alike.
final class TerminalTouchFlatDrawerButton: TerminalTouchDrawerButton {
    private let toolbar: Bool
    private let subtitle: String?
    private let lockIndicator = UIView()

    init(key: TerminalTouchKeyboardModel.Key, subtitle: String?, toolbar: Bool,
         palette: TerminalTouchKeyboardPalette?) {
        self.toolbar = toolbar
        self.subtitle = subtitle
        super.init(keycap: TerminalTouchFlatKeycap(key, small: toolbar))
        keycap.palette = palette
        if toolbar {
            keycap.isUserInteractionEnabled = false
            keycap.isAccessibilityElement = false
            keycap.accessibilityElementsHidden = true
            addSubview(keycap)
            accessibilityTraits.insert(.keyboardKey)
            refreshAppearance()
            return
        }
        lockIndicator.isUserInteractionEnabled = false
        lockIndicator.isAccessibilityElement = false
        lockIndicator.layer.cornerRadius = 1.5
        lockIndicator.isHidden = true
        addSubview(lockIndicator)
        updateDrawerConfiguration()
        titleLabel?.numberOfLines = 2
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if toolbar {
            // The drawer row insets buttons 2pt vertically; the main row's caps
            // span the full row, so extend back out to match their plate inset.
            keycap.frame = bounds.insetBy(dx: 0, dy: -2)
            return
        }
        // Match the flat keycap's underline for a locked (rather than one-shot) modifier.
        lockIndicator.frame = CGRect(x: (bounds.width - 14) / 2, y: bounds.height - 4,
                                     width: 14, height: 2.5)
        bringSubviewToFront(lockIndicator)
    }

    override var isSelected: Bool {
        didSet { if toolbar { keycap.selected = isSelected } }
    }

    override func updateContactAppearance() {
        if toolbar { keycap.pressed = contactPressed }
    }

    override func updatePalette(_ palette: TerminalTouchKeyboardPalette?) {
        super.updatePalette(palette)
        if !toolbar { updateDrawerConfiguration() }
    }

    override func refreshAppearance() {
        super.refreshAppearance()
        if !toolbar { updateDrawerConfiguration() }
    }

    private func updateDrawerConfiguration() {
        let key = keycap.key
        let subtitle = self.subtitle
        let palette = keycap.palette
        // Recreate the base style too: following a theme uses a filled button,
        // while system colors use UIKit's tinted treatment.
        var config = palette == nil ? UIButton.Configuration.tinted() : UIButton.Configuration.filled()
        config.title = key.title
        config.subtitle = subtitle
        config.baseForegroundColor = palette?.ink ?? .label
        config.baseBackgroundColor = palette?.key ?? .secondaryLabel
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input
            output.font = .systemFont(ofSize: subtitle == nil && key.title.count <= 4 ? 17 : 12, weight: .medium)
            return output
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input
            output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            return output
        }
        configuration = config
        lockIndicator.isHidden = !keycap.locked
        lockIndicator.backgroundColor = config.baseForegroundColor
    }
}

#endif
