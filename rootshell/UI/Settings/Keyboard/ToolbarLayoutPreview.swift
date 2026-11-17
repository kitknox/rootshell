//
//  ToolbarLayoutPreview.swift
//  rootshell
//
//  A live, non-interactive rendering of one toolbar for the settings screens,
//  drawn where that toolbar appears for this user and at the width and key
//  sizes it has in this window.
//

import SwiftUI
import UIKit

/// Where a toolbar is drawn. Which of these a person sees depends on their
/// keyboard and on how a remote screen's toolbar is placed.
nonisolated enum ToolbarPreviewSurface: Hashable, Sendable {
    /// Above the system keyboard.
    case systemKeyboard
    /// The terminal keyboard's own toolbar row.
    case terminalKeyboard
    /// A remote screen's glass toolbar, floating or docked along the bottom.
    case glassBar(floating: Bool)

    /// Carries the surface a settings key was pressed on to the settings screen.
    static let userInfoKey = "toolbarPreviewSurface"

    var displayName: String {
        switch self {
        case .systemKeyboard: return String(localized: "System Keyboard")
        case .terminalKeyboard: return String(localized: "Terminal Keyboard")
        case .glassBar(floating: true): return String(localized: "Floating")
        case .glassBar(floating: false): return String(localized: "Docked")
        }
    }

    /// Every surface a toolbar can appear on with these settings. The first is
    /// the one it appears on before anything is switched.
    static func available(for context: ToolbarContext, terminalKeyboard: Bool,
                          floatingBar: Bool) -> [ToolbarPreviewSurface] {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return [.systemKeyboard]
        #else
        guard context.usesGlassBar else {
            return terminalKeyboard ? [.terminalKeyboard, .systemKeyboard] : [.systemKeyboard]
        }
        // Docked with its keys up, the terminal keyboard shows the toolbar as its own row.
        let bars: [ToolbarPreviewSurface] = floatingBar
            ? [.glassBar(floating: true), .glassBar(floating: false)]
            : [.glassBar(floating: false), .glassBar(floating: true)]
        return terminalKeyboard ? bars + [.terminalKeyboard] : bars
        #endif
    }
}

/// Chooses the surface a preview draws, for a toolbar that appears on more than one.
struct ToolbarPreviewSurfacePicker: View {
    let surfaces: [ToolbarPreviewSurface]
    @Binding var selection: ToolbarPreviewSurface

    var body: some View {
        if surfaces.count > 1 {
            Picker("Preview", selection: $selection) {
                ForEach(surfaces, id: \.self) { surface in
                    Text(surface.displayName).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
        }
    }
}

/// What a preview learned about the toolbar it drew.
struct ToolbarLayoutPreviewMetrics: Equatable {
    var height: CGFloat = 44
    /// Keys the main row holds on the surface the preview drew.
    var capacity = 1
}

struct ToolbarLayoutPreview: View {
    let toolbar: ToolbarContext
    /// nil draws the surface the toolbar appears on first.
    var surface: ToolbarPreviewSurface?
    var showsDrawers = false
    @Binding var metrics: ToolbarLayoutPreviewMetrics

    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    var body: some View {
        let drawn = surface ?? ToolbarPreviewSurface.available(
            for: toolbar, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)[0]
        ToolbarLayoutPreviewRepresentable(toolbar: toolbar, surface: drawn, showsDrawers: showsDrawers,
                                          metrics: $metrics)
            // Each toolbar, surface and style is its own view; switching builds a new one.
            .id(PreviewIdentity(toolbar: toolbar, surface: drawn,
                                style: KeyboardToolbarManager.shared.toolbarStyle.resolved))
            .frame(height: metrics.height)
    }
}

private nonisolated struct PreviewIdentity: Hashable {
    let toolbar: ToolbarContext
    let surface: ToolbarPreviewSurface
    let style: KeyboardToolbarStyle
}

private struct ToolbarLayoutPreviewRepresentable: UIViewRepresentable {
    let toolbar: ToolbarContext
    let surface: ToolbarPreviewSurface
    let showsDrawers: Bool
    @Binding var metrics: ToolbarLayoutPreviewMetrics

    func makeUIView(context: Context) -> ToolbarLayoutPreviewHostView {
        let view = ToolbarLayoutPreviewHostView(context: toolbar, surface: surface, showsDrawers: showsDrawers)
        let metrics = $metrics
        view.onMetricsChange = { measured in
            // Measured during layout; state changes wait for the pass to end.
            Task { @MainActor in
                if metrics.wrappedValue != measured { metrics.wrappedValue = measured }
            }
        }
        return view
    }

    func updateUIView(_ view: ToolbarLayoutPreviewHostView, context: Context) {
        view.showsDrawers = showsDrawers
    }
}

final class ToolbarLayoutPreviewHostView: UIView {
    /// The remote screen's bar ends in three buttons of its own.
    private static let hostButtonSymbols = ["chevron.forward", "keyboard", "ellipsis"]

    private let context: ToolbarContext
    private let surface: ToolbarPreviewSurface
    var showsDrawers: Bool {
        didSet {
            guard oldValue != showsDrawers else { return }
            toolbar?.previewDrawers = showsDrawers ? .open : .closed
            refresh()
        }
    }
    var onMetricsChange: ((ToolbarLayoutPreviewMetrics) -> Void)?

    /// Laid out at the toolbar's real size, then scaled to fit this view.
    private let stage = UIView()
    /// The system keyboard's toolbar, which a remote screen's bar also hosts.
    private var toolbar: KeyboardToolbarView?
    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    private var keyboard: TerminalTouchKeyboardView?
    private let keyboardHost = PreviewKeyboardHost()
    #endif
    private let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    /// Terminal text behind the glass bar, one line running under it.
    private let terminalBackdrop = UIView()
    private let visibleLine = UILabel()
    private let coveredLine = UILabel()
    private let hostButtons = UIStackView()
    private var appliedSizes: KeyboardSizes?
    private var reportedMetrics: ToolbarLayoutPreviewMetrics?
    private var layoutObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    private var isGlassBar: Bool {
        if case .glassBar = surface { return true }
        return false
    }

    /// The Glass Bar style over the system keyboard: the terminal shows through it.
    private let isTerminalGlassBar: Bool

    init(context: ToolbarContext, surface: ToolbarPreviewSurface, showsDrawers: Bool) {
        self.context = context
        self.surface = surface
        self.showsDrawers = showsDrawers
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        isTerminalGlassBar = surface == .systemKeyboard
            && KeyboardToolbarManager.shared.toolbarStyle.resolved == .glassBar
        #else
        isTerminalGlassBar = false
        #endif
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "\(context.displayName) toolbar preview")
        addSubview(stage)

        if surface == .terminalKeyboard {
            makeTerminalKeyboard()
        } else {
            makeToolbar()
        }

        layoutObserver = NotificationCenter.default.addObserver(
            forName: KeyboardToolbarManager.layoutDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The toolbar size is a setting; layout picks the new key sizes up.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (self: ToolbarLayoutPreviewHostView, _: UITraitCollection) in
            self.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let layoutObserver {
            NotificationCenter.default.removeObserver(layoutObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func makeToolbar() {
        let toolbar = KeyboardToolbarView(sizes: .iPhonePortrait)
        toolbar.context = context
        toolbar.isEmbeddedPreview = true
        toolbar.previewDrawers = showsDrawers ? .open : .closed
        if isTerminalGlassBar { makeTerminalBackdrop() }
        if isGlassBar {
            toolbar.usesHostChrome = true
            glass.clipsToBounds = true
            glass.layer.cornerCurve = .continuous
            stage.addSubview(glass)
        }
        stage.addSubview(toolbar)
        if isGlassBar {
            hostButtons.axis = .horizontal
            hostButtons.distribution = .fillEqually
            for symbol in Self.hostButtonSymbols {
                let glyph = UIImageView(image: UIImage(systemName: symbol))
                glyph.contentMode = .center
                glyph.tintColor = .label
                hostButtons.addArrangedSubview(glyph)
            }
            stage.addSubview(hostButtons)
        }
        self.toolbar = toolbar
    }

    /// A strip of the terminal in its theme, so the glass reads as it does live.
    private func makeTerminalBackdrop() {
        let (name, _) = ThemeOverrideManager.shared.resolveTheme(tabId: nil, windowId: nil)
        let colors = ThemeManager.shared.themeInfo(for: name)?.colors
        terminalBackdrop.backgroundColor = colors.flatMap { UIColor(hex: $0.background) } ?? .black
        terminalBackdrop.layer.cornerRadius = 10
        terminalBackdrop.layer.cornerCurve = .continuous
        terminalBackdrop.clipsToBounds = true
        let ink = colors.flatMap { UIColor(hex: $0.foreground) } ?? .white
        for (label, text) in [(visibleLine, "~ % git log --oneline"), (coveredLine, "4f2c9e1 Update the build script")] {
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = ink
            label.text = text
            terminalBackdrop.addSubview(label)
        }
        stage.addSubview(terminalBackdrop)
    }

    /// The terminal keyboard with its keys folded away, as it shows beside a
    /// hardware keyboard: the toolbar row and its drawers in the user's style.
    private func makeTerminalKeyboard() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let keyboard = TerminalTouchKeyboardView()
        keyboard.isEmbeddedPreview = true
        keyboard.useContainerSizing()
        keyboard.translatesAutoresizingMaskIntoConstraints = true
        // No animated backdrop for a settings row.
        keyboard.setBackgroundEffectSurface(nil)
        keyboard.host = keyboardHost
        keyboard.toolbarContext = context
        keyboard.setToolbarPresentation(only: true, bottomInset: 0, showsRestore: false, pinned: false)
        keyboard.onHeightChanged = { [weak self] in self?.setNeedsLayout() }
        stage.addSubview(keyboard)
        self.keyboard = keyboard
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    private func refresh() {
        toolbar?.rebuildForCurrentWidth()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        // The window's size classes pick the key sizes, as they do for the
        // live toolbar. This view's own can differ inside a sheet.
        let traits = window?.traitCollection ?? traitCollection
        let sizes = KeyboardSizes.accessory(traitCollection: traits)
        var fullWidth = window?.bounds.width ?? bounds.width
        if traits.userInterfaceIdiom == .phone, traits.verticalSizeClass == .compact, let window {
            // A phone in landscape keeps the toolbar clear of both side insets.
            fullWidth -= window.safeAreaInsets.left + window.safeAreaInsets.right + 4
        }
        fullWidth = max(fullWidth, sizes.button.normalWidth)

        let fitted = surface == .terminalKeyboard
            ? layoutTerminalKeyboard(width: fullWidth)
            : layoutToolbar(width: fullWidth, sizes: sizes)
        guard fitted.size.width > 0 else { return }

        let scale = min(1, bounds.width / fitted.size.width)
        stage.bounds = CGRect(origin: .zero, size: fitted.size)
        stage.center = CGPoint(x: bounds.midX, y: fitted.size.height * scale / 2)
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)

        let metrics = ToolbarLayoutPreviewMetrics(height: ceil(fitted.size.height * scale), capacity: fitted.capacity)
        if metrics != reportedMetrics {
            reportedMetrics = metrics
            onMetricsChange?(metrics)
        }
    }

    private func layoutToolbar(width: CGFloat, sizes: KeyboardSizes) -> (size: CGSize, capacity: Int) {
        guard let toolbar else { return (.zero, 1) }
        if appliedSizes?.toolbar.height != sizes.toolbar.height
            || appliedSizes?.button.normalWidth != sizes.button.normalWidth {
            appliedSizes = sizes
            toolbar.updateSizes(sizes)
            let symbols = UIImage.SymbolConfiguration(pointSize: sizes.button.symbolSize, weight: .medium)
            for case let glyph as UIImageView in hostButtons.arrangedSubviews {
                glyph.preferredSymbolConfiguration = symbols
            }
        }

        var edge: CGFloat = 0
        var barWidth = width
        var reserve: CGFloat = 0
        // What the bar's buttons take once the keys are squeezed to their narrowest.
        var narrowestReserve: CGFloat = 0
        if case .glassBar(let floating) = surface {
            // As the remote screen's bar sizes itself.
            let bar = toolbar.hostBarGeometry()
            let buttons = Self.hostButtonSymbols.count
            edge = bar.edgePadding
            reserve = bar.slotWidth(availableWidth: width, buttons: buttons, docked: !floating) * CGFloat(buttons)
            narrowestReserve = bar.minimumSlotWidth * CGFloat(buttons)
            barWidth = bar.barWidth(availableWidth: width, buttons: buttons, docked: !floating)
            if abs(toolbar.hostTrailingReserve - reserve) > 0.5 { toolbar.hostTrailingReserve = reserve }
        }

        // The glass bar shows a line of terminal text above it and one through it.
        let textBand = isTerminalGlassBar ? ceil(visibleLine.font.lineHeight) + 4 : 0

        toolbar.frame = CGRect(x: 0, y: textBand, width: barWidth,
                               height: max(toolbar.bounds.height, sizes.toolbar.height))
        toolbar.layoutIfNeeded()
        let height = toolbar.intrinsicContentSize.height
        toolbar.frame.size.height = height
        if isGlassBar {
            glass.frame = toolbar.frame
            glass.layer.cornerRadius = min(22, sizes.toolbar.height / 2)
            hostButtons.frame = CGRect(x: barWidth - edge - reserve, y: height - sizes.toolbar.height,
                                       width: reserve, height: sizes.toolbar.height)
        }
        let stageSize = CGSize(width: barWidth, height: textBand + height)
        if isTerminalGlassBar {
            terminalBackdrop.frame = CGRect(origin: .zero, size: stageSize)
            let lineHeight = ceil(visibleLine.font.lineHeight)
            visibleLine.frame = CGRect(x: 10, y: 2, width: stageSize.width - 20, height: lineHeight)
            coveredLine.frame = CGRect(x: 10, y: toolbar.frame.maxY - sizes.toolbar.height / 2 - lineHeight / 2,
                                       width: stageSize.width - 20, height: lineHeight)
        }
        let capacity = toolbar.mainRowCapacity(width: width, hostTrailingReserve: narrowestReserve)
        return (stageSize, capacity)
    }

    private func layoutTerminalKeyboard(width: CGFloat) -> (size: CGSize, capacity: Int) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let keyboard else { return (.zero, 1) }
        keyboard.frame = CGRect(x: 0, y: 0, width: width, height: max(keyboard.bounds.height, 1))
        keyboard.layoutIfNeeded()

        let open = showsDrawers ? keyboard.filledToolbarDrawerCount : 0
        let drawer: TerminalTouchKeyboardModel.ToolbarDrawerState = open > 0 ? .stacked(open) : .closed
        if keyboard.presentationState.toolbarDrawer != drawer {
            var state = keyboard.presentationState
            state.toolbarDrawer = drawer
            keyboard.restorePresentationState(state)
            keyboard.layoutIfNeeded()
        }

        let height = keyboard.intrinsicContentSize.height
        keyboard.frame.size.height = height
        let layout = KeyboardToolbarManager.shared.layout(for: context)
        let pinned = (layout.pinnedLeading ?? []) + (layout.pinnedTrailing ?? [])
        let capacity = TerminalTouchKeyboardModel.toolbarCapacity(
            width: width, minimumKeyWidth: KeyboardToolbarSize.currentMinimumKeyWidth, pinned: pinned.count,
            drawerToggle: !layout.hiddenKeys.contains(.drawerToggle) && !pinned.contains(.builtIn(.drawerToggle)),
            scrolls: layout.mainRowScrolls)
        return (CGSize(width: width, height: height), capacity)
        #else
        return (.zero, 1)
        #endif
    }
}

#if !os(visionOS) && !targetEnvironment(macCatalyst)
/// Gives a previewed terminal keyboard the terminal's theme and nowhere to type.
private final class PreviewKeyboardHost: TerminalTouchKeyboardHost {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        let (name, _) = ThemeOverrideManager.shared.resolveTheme(tabId: nil, windowId: nil)
        return ThemeManager.shared.themeInfo(for: name)?.colors
    }
    var touchKeyboardCanSend: Bool { false }
    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }
    func touchKeyboardInsert(_ text: String) {}
    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers, shifted: Character?) {}
    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
    func touchKeyboardInvalidateSuggestions() {}
}
#endif
