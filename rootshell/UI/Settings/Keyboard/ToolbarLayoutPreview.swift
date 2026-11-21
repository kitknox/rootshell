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
    /// Main-row keys that surface sends to the drawer.
    var overflowing: Set<KeySlot> = []
}

/// A key a previewed toolbar draws, for hit-testing.
struct ToolbarPreviewKey {
    let slot: KeySlot
    /// In the previewed view, wherever its row has scrolled to.
    var frame: CGRect
    /// The row's scroll view, when the row scrolls.
    let scrollView: UIScrollView?
    /// The drawer row it is drawn in, which for a key that overflowed is not
    /// the row that places it. nil in the main row.
    var drawer: Int? = nil
}

/// Asks a list or a preview to bring a key into view and flash it. A new token flashes the same key again.
struct ToolbarKeyPulse: Equatable {
    let slot: KeySlot
    let token: Int
}

/// What touching a preview's keys does. With no handlers the preview ignores touches.
struct ToolbarPreviewActions {
    var selectKey: ((KeySlot) -> Void)?
    /// A drag dropped a key: it goes in that row of the layout, ahead of
    /// `anchor` or at the end.
    var moveKey: ((_ slot: KeySlot, _ section: KeyboardToolbarManager.ToolbarSection, _ anchor: KeySlot?) -> Void)?
}

struct ToolbarLayoutPreview: View {
    let toolbar: ToolbarContext
    /// nil draws the surface the toolbar appears on first.
    var surface: ToolbarPreviewSurface?
    var showsDrawers = false
    @Binding var metrics: ToolbarLayoutPreviewMetrics
    var pulse: ToolbarKeyPulse?
    var actions = ToolbarPreviewActions()

    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    var body: some View {
        let drawn = surface ?? ToolbarPreviewSurface.available(
            for: toolbar, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)[0]
        ToolbarLayoutPreviewRepresentable(toolbar: toolbar, surface: drawn, showsDrawers: showsDrawers,
                                          metrics: $metrics, pulse: pulse, actions: actions)
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
    let pulse: ToolbarKeyPulse?
    let actions: ToolbarPreviewActions

    func makeUIView(context: Context) -> ToolbarLayoutPreviewHostView {
        let view = ToolbarLayoutPreviewHostView(context: toolbar, surface: surface, showsDrawers: showsDrawers)
        let metrics = $metrics
        view.onMetricsChange = { measured in
            // Measured during layout; state changes wait for the pass to end.
            Task { @MainActor in
                if metrics.wrappedValue != measured { metrics.wrappedValue = measured }
            }
        }
        view.actions = actions
        // A new view has nothing to announce: the pulse it starts with is an old one.
        view.adopt(pulse)
        return view
    }

    func updateUIView(_ view: ToolbarLayoutPreviewHostView, context: Context) {
        view.showsDrawers = showsDrawers
        view.actions = actions
        view.pulse = pulse
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
    var actions = ToolbarPreviewActions() {
        didSet { isUserInteractionEnabled = actions.selectKey != nil || actions.moveKey != nil }
    }
    var pulse: ToolbarKeyPulse? {
        didSet {
            guard let pulse, pulse != oldValue, !isAdoptingPulse else { return }
            pendingPulse = pulse.slot
            setNeedsLayout()
        }
    }
    private var isAdoptingPulse = false

    /// Takes a pulse as already shown.
    func adopt(_ pulse: ToolbarKeyPulse?) {
        isAdoptingPulse = true
        self.pulse = pulse
        isAdoptingPulse = false
    }
    /// Flashed once the layout that follows an edit has settled.
    private var pendingPulse: KeySlot?
    /// Row scroll positions to put back after a rebuild.
    private var savedOffsets: [CGFloat]?
    private var interaction = KeyInteraction()

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
        // The previewed keys never take a touch; this view reads touches for them.
        stage.isUserInteractionEnabled = false
        addSubview(stage)
        installKeyGestures()

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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBeginKeyGesture(gestureRecognizer)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endDrag(commit: false) }
        setNeedsLayout()
    }

    private func refresh() {
        // A rebuild makes new rows, which start unscrolled.
        if toolbar != nil { savedOffsets = scrollRows().map(\.contentOffset.x) }
        interaction.landing = nil
        toolbar?.rebuildForCurrentWidth()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        // A new width or key size changes what the rows hold.
        interaction.landing = nil

        // The window's size classes pick the key sizes, as they do for the
        // live toolbar. This view's own can differ inside a sheet.
        let traits = window?.traitCollection ?? traitCollection
        let sizes = KeyboardSizes.accessory(traitCollection: traits, context: context)
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

        var overflowing = toolbar?.overflowedSlots ?? []
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if let keyboard { overflowing = keyboard.overflowedToolbarSlots }
        #endif
        let metrics = ToolbarLayoutPreviewMetrics(height: ceil(fitted.size.height * scale), capacity: fitted.capacity,
                                                  overflowing: overflowing)
        if metrics != reportedMetrics {
            reportedMetrics = metrics
            onMetricsChange?(metrics)
        }

        if let offsets = savedOffsets {
            savedOffsets = nil
            // With a row added or removed, the rows no longer line up with the offsets.
            let rows = scrollRows()
            for (row, offset) in zip(rows, offsets) where rows.count == offsets.count {
                row.contentOffset.x = min(offset, max(0, row.contentSize.width - row.bounds.width))
            }
        }
        if let slot = pendingPulse {
            pendingPulse = nil
            reveal(slot)
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
        if toolbar.frame.height != height {
            toolbar.frame.size.height = height
            // Rows sit at their new places before anything reads their frames.
            toolbar.layoutIfNeeded()
        }
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
        if keyboard.frame.height != height {
            keyboard.frame.size.height = height
            keyboard.layoutIfNeeded()
        }
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

extension UIView {
    /// A tinted wash over one key or row that fades away.
    func flashKeyHighlight(over frame: CGRect, color: UIColor? = nil) {
        let highlight = UIView(frame: frame.insetBy(dx: 1, dy: 1))
        highlight.backgroundColor = (color ?? tintColor).withAlphaComponent(0.4)
        highlight.layer.cornerRadius = min(10, frame.height / 2)
        highlight.layer.cornerCurve = .continuous
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        UIView.animate(withDuration: 0.8, delay: 0.25, options: .curveEaseOut) {
            highlight.alpha = 0
        } completion: { _ in
            highlight.removeFromSuperview()
        }
    }
}

// MARK: - Drop placement

/// Finds where the layout can put a key so the toolbar draws it at a drop's
/// caret. Fitting moves keys: the row overflows into the drawer and keeps its
/// drawer toggle in view, so the place a key is drawn is not always the place
/// the layout holds it. This tries each place, fits the rows as the toolbar
/// does, and keeps the one drawn nearest the caret.
struct ToolbarDropResolver {
    typealias Section = KeyboardToolbarManager.ToolbarSection

    /// A layout's rows, holding only keys the toolbar draws.
    struct Rows {
        var leading: [KeySlot]?
        var main: [KeySlot]
        var trailing: [KeySlot]?
        var drawers: [[KeySlot]]

        func row(_ section: Section) -> [KeySlot] {
            switch section {
            case .pinnedLeading: return leading ?? []
            case .mainRow: return main
            case .pinnedTrailing: return trailing ?? []
            case .drawer(let index): return drawers.indices.contains(index) ? drawers[index] : []
            }
        }

        mutating func remove(_ slot: KeySlot) {
            leading?.removeAll { $0 == slot }
            main.removeAll { $0 == slot }
            trailing?.removeAll { $0 == slot }
            for index in drawers.indices { drawers[index].removeAll { $0 == slot } }
        }

        mutating func insert(_ slot: KeySlot, in section: Section, at index: Int) {
            switch section {
            case .pinnedLeading: leading?.insert(slot, at: index)
            case .mainRow: main.insert(slot, at: index)
            case .pinnedTrailing: trailing?.insert(slot, at: index)
            case .drawer(let drawer): drawers[drawer].insert(slot, at: index)
            }
        }
    }

    struct Landing {
        let section: Section
        /// The key to go ahead of in that row; nil for its end.
        let anchor: KeySlot?
        /// The keys drawn on either side of the dragged key once it lands.
        var previous: KeySlot?
        var next: KeySlot?
        /// The key is drawn on the side of the hovered key the caret is on.
        var isExact = false
    }

    let scrolls: Bool
    let keepsToggle: Bool
    /// The main row's capacity with these keys pinned, for a row that
    /// scrolls or one that overflows. Pinned keys change what the row holds,
    /// so each layout tried is fitted at its own capacity.
    let capacity: (_ leading: [KeySlot], _ trailing: [KeySlot], _ scrolling: Bool) -> Int

    /// The rows as the toolbar draws them.
    func fit(_ rows: Rows) -> (main: [KeySlot], drawers: [[KeySlot]]) {
        let toggle = KeySlot.builtIn(.drawerToggle)
        let leading = rows.leading ?? [], trailing = rows.trailing ?? []
        if scrolls, let fitted = KeyboardToolbarOverflow.scrollingLayout(
            leading: leading, main: rows.main, trailing: trailing, drawers: rows.drawers,
            capacity: capacity(leading, trailing, true), drawerToggle: toggle,
            keepsDrawerToggleVisible: keepsToggle) {
            return (fitted.leading + fitted.middle + fitted.trailing, fitted.drawers)
        }
        return KeyboardToolbarOverflow.layout(leading: leading, main: rows.main, trailing: trailing,
                                              drawers: rows.drawers, capacity: capacity(leading, trailing, false),
                                              drawerToggle: toggle, keepsDrawerToggleVisible: keepsToggle)
    }

    /// The place for `slot`, absent from `rows`, that draws it in the main
    /// row or in `drawer`, on the `after` side of `neighbor` or as near as
    /// the row allows. A drawer takes the key into its own row and the main
    /// row into one of its three; among equals, `preferred` wins.
    func landing(of slot: KeySlot, in rows: Rows, drawer: Int?, beside neighbor: KeySlot, after: Bool,
                 preferring preferred: Section?) -> Landing? {
        var sections: [Section] = []
        if let drawer {
            guard rows.drawers.indices.contains(drawer) else { return nil }
            sections = [.drawer(drawer)]
        } else {
            if rows.leading != nil { sections.append(.pinnedLeading) }
            sections.append(.mainRow)
            if rows.trailing != nil { sections.append(.pinnedTrailing) }
        }
        func drawn(_ rows: Rows) -> [KeySlot] {
            let fitted = fit(rows)
            guard let drawer else { return fitted.main }
            return fitted.drawers.indices.contains(drawer) ? fitted.drawers[drawer] : []
        }
        let now = drawn(rows)
        let wanted = (now.firstIndex(of: neighbor) ?? now.count) + (after ? 1 : 0)
        var best: (rank: (Int, Int, Int), landing: Landing)?
        for section in sections {
            let row = rows.row(section)
            for index in 0...row.count {
                var placed = rows
                placed.insert(slot, in: section, at: index)
                let result = drawn(placed)
                guard let at = result.firstIndex(of: slot) else { continue }
                let previous = at > 0 ? result[at - 1] : nil
                let next = at + 1 < result.count ? result[at + 1] : nil
                let isExact = after ? previous == neighbor : next == neighbor
                let rank = (isExact ? 0 : 1, abs(at - wanted), section == preferred ? 0 : 1)
                if best.map({ rank < $0.rank }) ?? true {
                    best = (rank, Landing(section: section, anchor: index < row.count ? row[index] : nil,
                                          previous: previous, next: next, isExact: isExact))
                }
            }
        }
        return best?.landing
    }
}

// MARK: - Key touches

/// A tap finds a key, a horizontal drag scrolls a row, and a held key can be
/// dragged to a new place.
private struct KeyInteraction {
    struct Drag {
        let slot: KeySlot
        /// Where the key was picked up.
        let origin: CGRect
        /// The finger has left that spot. A key held and let go where it was
        /// picked up has not been dragged, and scrolls nothing.
        var hasMoved = false
        let lift: UIView
        let dim: UIView
        /// The key the caret is drawn beside, and where the layout takes the dragged key.
        var target: (slot: KeySlot, after: Bool, landing: ToolbarDropResolver.Landing)?
    }
    var drag: Drag?
    var dragPoint = CGPoint.zero
    /// The place last worked out, for the key and side the finger is still over.
    var landing: (slot: KeySlot, drawer: Int?, after: Bool, place: ToolbarDropResolver.Landing?)?
    let caret = UIView()
    var scrolledRow: UIScrollView?
    var scrollStart: CGFloat = 0
    var autoscroll: CADisplayLink?
    var autoscrollRow: UIScrollView?
    var autoscrollDirection: CGFloat = 0
    let scrollRecognizer = UIPanGestureRecognizer()
}

extension ToolbarLayoutPreviewHostView: UIGestureRecognizerDelegate {
    fileprivate func installKeyGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleKeyTap(_:))))
        let lift = UILongPressGestureRecognizer(target: self, action: #selector(handleKeyLift(_:)))
        lift.minimumPressDuration = 0.3
        addGestureRecognizer(lift)
        interaction.scrollRecognizer.addTarget(self, action: #selector(handleRowScroll(_:)))
        interaction.scrollRecognizer.delegate = self
        addGestureRecognizer(interaction.scrollRecognizer)
        interaction.caret.backgroundColor = .tintColor
        interaction.caret.layer.cornerRadius = 1.5
        interaction.caret.isUserInteractionEnabled = false
    }

    /// The previewed view and its keys, in that view's coordinates.
    private func hostedKeys() -> (view: UIView, keys: [ToolbarPreviewKey])? {
        if let toolbar { return (toolbar, toolbar.previewKeys()) }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if let keyboard { return (keyboard, keyboard.previewToolbarKeys()) }
        #endif
        return nil
    }

    /// The keys that show, in this view's coordinates.
    private func visibleKeys() -> [ToolbarPreviewKey] {
        guard let hosted = hostedKeys() else { return [] }
        return hosted.keys.compactMap { key in
            var frame = hosted.view.convert(key.frame, to: self)
            if let row = key.scrollView { frame = frame.intersection(row.convert(row.bounds, to: self)) }
            guard !frame.isNull, frame.width >= 4, frame.height >= 4 else { return nil }
            return ToolbarPreviewKey(slot: key.slot, frame: frame, scrollView: key.scrollView, drawer: key.drawer)
        }
    }

    /// Every scrolling row, in the order the previewed view lists its keys.
    fileprivate func scrollRows() -> [UIScrollView] {
        var rows: [UIScrollView] = []
        for case let row? in (hostedKeys()?.keys ?? []).map(\.scrollView) where !rows.contains(where: { $0 === row }) {
            rows.append(row)
        }
        return rows
    }

    private func scrollableRow(at point: CGPoint) -> UIScrollView? {
        scrollRows().first { row in
            row.contentSize.width > row.bounds.width + 1 && row.convert(row.bounds, to: self).contains(point)
        }
    }

    private func furthestOffset(of row: UIScrollView) -> CGFloat {
        max(0, row.contentSize.width - row.bounds.width)
    }

    /// Scrolls a key's row until the key shows, then flashes it.
    fileprivate func reveal(_ slot: KeySlot) {
        guard let hosted = hostedKeys(), let key = hosted.keys.first(where: { $0.slot == slot }) else { return }
        if let row = key.scrollView {
            row.scrollRectToVisible(hosted.view.convert(key.frame, to: row).insetBy(dx: -12, dy: 0), animated: false)
        }
        if let shown = visibleKeys().first(where: { $0.slot == slot }) { flashKeyHighlight(over: shown.frame) }
    }

    @objc private func handleKeyTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let key = visibleKeys().first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }) else { return }
        flashKeyHighlight(over: key.frame)
        actions.selectKey?(key.slot)
    }

    // MARK: Row scrolling

    fileprivate func shouldBeginKeyGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interaction.scrollRecognizer else { return true }
        // A vertical drag belongs to the list around the preview.
        let velocity = interaction.scrollRecognizer.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
            && scrollableRow(at: interaction.scrollRecognizer.location(in: self)) != nil
    }

    @objc private func handleRowScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interaction.scrolledRow = scrollableRow(at: recognizer.location(in: self))
            interaction.scrollStart = interaction.scrolledRow?.contentOffset.x ?? 0
        case .changed:
            guard let row = interaction.scrolledRow else { return }
            // The rows are drawn scaled down; a finger moves them at their own size.
            let scale = max(stage.transform.a, 0.01)
            let offset = interaction.scrollStart - recognizer.translation(in: self).x / scale
            row.contentOffset.x = min(max(0, offset), furthestOffset(of: row))
        default:
            interaction.scrolledRow = nil
        }
    }

    // MARK: Dragging a key

    @objc private func handleKeyLift(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard actions.moveKey != nil,
                  let key = visibleKeys().first(where: { $0.frame.contains(point) }) else { return }
            beginDrag(key, at: point)
        case .changed:
            guard interaction.drag != nil else { return }
            moveDrag(to: point)
        case .ended:
            endDrag(commit: true)
        default:
            endDrag(commit: false)
        }
    }

    private func beginDrag(_ key: ToolbarPreviewKey, at point: CGPoint) {
        let lift = resizableSnapshotView(from: key.frame, afterScreenUpdates: false, withCapInsets: .zero)
            ?? UIView(frame: key.frame)
        lift.frame = key.frame
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOpacity = 0.3
        lift.layer.shadowRadius = 6
        lift.layer.shadowOffset = CGSize(width: 0, height: 3)
        let dim = UIView(frame: key.frame)
        dim.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
        dim.layer.cornerRadius = min(8, key.frame.height / 2)
        dim.isUserInteractionEnabled = false
        addSubview(dim)
        addSubview(interaction.caret)
        addSubview(lift)
        interaction.caret.isHidden = true
        interaction.drag = KeyInteraction.Drag(slot: key.slot, origin: key.frame, lift: lift, dim: dim)
        interaction.landing = nil
        UIView.animate(withDuration: 0.15) {
            lift.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            lift.alpha = 0.9
        }
        #if !os(visionOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        moveDrag(to: point)
    }

    private func moveDrag(to point: CGPoint) {
        interaction.dragPoint = point
        interaction.drag?.lift.center = CGPoint(x: point.x, y: point.y - 8)
        updateDropTarget()
        updateAutoscroll()
    }

    /// The key nearest the finger in the row under it, and the side the finger is on.
    private func updateDropTarget() {
        guard let drag = interaction.drag else { return }
        let point = interaction.dragPoint
        func offset(_ key: ToolbarPreviewKey) -> (CGFloat, CGFloat) {
            let frame = key.frame
            let vertical = point.y < frame.minY ? frame.minY - point.y : max(0, point.y - frame.maxY)
            return (vertical, abs(point.x - frame.midX))
        }
        if !drag.origin.insetBy(dx: -4, dy: -4).contains(point) { interaction.drag?.hasMoved = true }
        let keys = visibleKeys().filter { $0.slot != drag.slot }
        // Only the stack-built toolbar mirrors for a right-to-left language.
        let mirrored = toolbar?.effectiveUserInterfaceLayoutDirection == .rightToLeft
        guard interaction.drag?.hasMoved == true, let hovered = keys.min(by: { offset($0) < offset($1) }),
              offset(hovered).0 <= 30,
              let landing = landing(over: hovered, after: (point.x > hovered.frame.midX) != mirrored,
                                    among: keys, dragging: drag.slot) else {
            interaction.drag?.target = nil
            interaction.caret.isHidden = true
            return
        }
        let (nearest, after) = (landing.key, landing.after)
        let onTrailingSide = after != mirrored
        if drag.target?.slot != nearest.slot || drag.target?.after != after {
            #if !os(visionOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        }
        interaction.drag?.target = (nearest.slot, after, landing.place)
        interaction.caret.isHidden = false
        interaction.caret.frame = CGRect(x: (onTrailingSide ? nearest.frame.maxX : nearest.frame.minX) - 1.5,
                                         y: nearest.frame.minY + 3, width: 3, height: nearest.frame.height - 6)
    }

    /// Where a drop over `hovered` lands: the key the caret is drawn beside,
    /// and the place in the layout that draws the dragged key there. nil
    /// while that spot is scrolled out of view, or the row cannot hold the key.
    private func landing(over hovered: ToolbarPreviewKey, after: Bool, among shown: [ToolbarPreviewKey],
                         dragging: KeySlot) -> (key: ToolbarPreviewKey, after: Bool, place: ToolbarDropResolver.Landing)? {
        // The place holds until the finger crosses to another key or side;
        // a row scrolling under it only moves where the caret is drawn.
        let place: ToolbarDropResolver.Landing?
        if let cached = interaction.landing, cached.slot == hovered.slot, cached.drawer == hovered.drawer,
           cached.after == after {
            place = cached.place
        } else {
            place = resolveLanding(over: hovered, after: after, dragging: dragging)
            interaction.landing = (hovered.slot, hovered.drawer, after, place)
        }
        guard let place else { return nil }
        if place.isExact { return (hovered, after, place) }
        // Somewhere else in the row: the caret goes where the key will be drawn.
        func shownInRow(_ slot: KeySlot?) -> ToolbarPreviewKey? {
            shown.first { $0.slot == slot && $0.drawer == hovered.drawer }
        }
        if let previous = shownInRow(place.previous) { return (previous, true, place) }
        if let next = shownInRow(place.next) { return (next, false, place) }
        return nil
    }

    private func resolveLanding(over hovered: ToolbarPreviewKey, after: Bool,
                                dragging: KeySlot) -> ToolbarDropResolver.Landing? {
        let manager = KeyboardToolbarManager.shared
        let layout = manager.layout(for: context)
        let omitted = toolbar?.usesHostChrome == true ? KeyboardToolbarView.hostHiddenSlots : []
        func drawn(_ row: [KeySlot]) -> [KeySlot] {
            manager.validSlots(row, in: layout).filter { !omitted.contains($0) }
        }
        var rows = ToolbarDropResolver.Rows(leading: layout.pinnedLeading.map(drawn), main: drawn(layout.mainRow),
                                            trailing: layout.pinnedTrailing.map(drawn),
                                            drawers: layout.drawerRows.map(drawn))
        let home = manager.section(holding: hovered.slot, in: context)
        let mainRow = (hostedKeys()?.keys ?? []).filter { $0.drawer == nil }.map(\.slot)
        guard let capacity = dropCapacity() else { return nil }
        let resolver = ToolbarDropResolver(scrolls: layout.mainRowScrolls,
                                           keepsToggle: !layout.hiddenKeys.contains(.drawerToggle),
                                           capacity: capacity)
        guard resolver.fit(rows).main == mainRow else {
            // A row this cannot reproduce: the key goes beside the hovered one, in that key's own row.
            let row = rows.row(home ?? .mainRow).filter { $0 != dragging }
            let anchor = after ? row.drop { $0 != hovered.slot }.dropFirst().first : hovered.slot
            return .init(section: home ?? .mainRow, anchor: anchor, isExact: true)
        }
        rows.remove(dragging)
        return resolver.landing(of: dragging, in: rows, drawer: hovered.drawer, beside: hovered.slot,
                                after: after, preferring: home)
    }

    /// The previewed toolbar's own count of its main row, for any pinned keys.
    private func dropCapacity() -> ((_ leading: [KeySlot], _ trailing: [KeySlot], _ scrolling: Bool) -> Int)? {
        if let toolbar { return { leading, trailing, _ in toolbar.previewCapacity(leading: leading, trailing: trailing) } }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if let keyboard {
            return { keyboard.previewToolbarCapacity(leading: $0, trailing: $1, scrolling: $2) }
        }
        #endif
        return nil
    }

    /// Near either end of a scrolling row, the row scrolls under the held key,
    /// once the finger has left the key it picked up.
    private func updateAutoscroll() {
        let point = interaction.dragPoint
        guard interaction.drag?.hasMoved == true, let row = scrollableRow(at: point) else {
            stopAutoscroll()
            return
        }
        let visible = row.convert(row.bounds, to: self)
        let direction: CGFloat = point.x < visible.minX + 28 ? -1 : point.x > visible.maxX - 28 ? 1 : 0
        guard direction != 0 else { stopAutoscroll(); return }
        interaction.autoscrollRow = row
        interaction.autoscrollDirection = direction
        guard interaction.autoscroll == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepAutoscroll(_:)))
        link.add(to: .main, forMode: .common)
        interaction.autoscroll = link
    }

    @objc private func stepAutoscroll(_ link: CADisplayLink) {
        guard let row = interaction.autoscrollRow, interaction.drag != nil else { stopAutoscroll(); return }
        let offset = row.contentOffset.x + interaction.autoscrollDirection * 360 * CGFloat(link.duration)
        let clamped = min(max(0, offset), furthestOffset(of: row))
        guard clamped != row.contentOffset.x else { return }
        row.contentOffset.x = clamped
        updateDropTarget()
    }

    private func stopAutoscroll() {
        interaction.autoscroll?.invalidate()
        interaction.autoscroll = nil
        interaction.autoscrollRow = nil
    }

    fileprivate func endDrag(commit: Bool) {
        stopAutoscroll()
        guard let drag = interaction.drag else { return }
        interaction.drag = nil
        interaction.caret.removeFromSuperview()
        UIView.animate(withDuration: 0.18) {
            drag.lift.alpha = 0
            drag.lift.transform = .identity
            drag.dim.alpha = 0
        } completion: { _ in
            drag.lift.removeFromSuperview()
            drag.dim.removeFromSuperview()
        }
        if commit, let target = drag.target {
            actions.moveKey?(drag.slot, target.landing.section, target.landing.anchor)
        }
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
