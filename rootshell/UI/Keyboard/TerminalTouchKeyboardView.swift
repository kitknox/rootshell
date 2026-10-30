#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import Combine
import SwiftUI

private struct TerminalTouchKeyboardEffectBackground: View {
    @ObservedObject var appearance: TerminalKeyboardEffectSurface.Appearance
    @ObservedObject var effect: AnyTerminalEffect
    var effectManager = EffectManager.shared

    var body: some View {
        ZStack {
            Color(uiColor: appearance.backgroundColor)
            effect.createEffectView()
                .id(effect.id)
                .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
        }
        .environment(\.terminalEffectRetainsState, true)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An in-app keyboard. The terminal remains first responder throughout typing.
@MainActor
protocol TerminalTouchKeyboardHost: AnyObject {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { get }
    var touchKeyboardCanSend: Bool { get }
    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { get }
    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { get }
    func touchKeyboardInsert(_ text: String)
    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers)
    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext)
    func touchKeyboardInvalidateSuggestions()
}

extension TerminalTouchKeyboardHost {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { nil }
    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { nil }
}

/// UIKit cancels the ordinary button tap when this recognizer starts repeating.
/// The switch key's style menu. Outside the keyboard window UIKit no longer
/// cancels the touch when the menu opens, so lifting would also tap the key.
private final class TerminalTouchMenuKeyButton: UIButton {
    private(set) var showedMenu = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        showedMenu = false
        super.touchesBegan(touches, with: event)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        showedMenu = true
    }
}

class TerminalTouchRepeatingButton: UIButton {
    override var isHighlighted: Bool {
        didSet { updateContactAppearance() }
    }
    private var repeatingContact = false
    var contactPressed: Bool { isHighlighted || repeatingContact }
    func updateContactAppearance() {}

    var repeatAction: (() -> Void)?
    private var repeatTask: Task<Void, Never>?
    var interactionMode: KeyboardToolbarInteractionMode = .accessory
    private var touchMode: KeyboardToolbarInteractionMode = .accessory
    private var trackedTouch: UITouch?
    private var repeatGesture: UILongPressGestureRecognizer?
    private var touchOrigin = CGPoint.zero

    private var validTouch: Bool {
        guard let touch = trackedTouch, let window,
              window.windowScene?.activationState == .foregroundActive else { return false }
        guard touchMode == .spacedBottom else { return true }
        let point = touch.location(in: window)
        return bounds.contains(touch.location(in: self))
            && hypot(point.x - touchOrigin.x, point.y - touchOrigin.y) <= 10
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchMode = interactionMode
        trackedTouch = touches.first
        touchOrigin = trackedTouch?.location(in: window) ?? .zero
        guard validTouch else { cancelInteraction(); return }
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard validTouch else { cancelInteraction(); return }
        super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard validTouch else { cancelInteraction(); return }
        super.touchesEnded(touches, with: event)
        trackedTouch = nil
        cancelRepeat()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        // The repeating recognizer cancels UIButton's tap when it takes over.
        // Keep its contact until that recognizer ends or fails validation.
        if repeatGesture?.state == .began || repeatGesture?.state == .changed { return }
        cancelInteraction()
    }
    func cancelInteraction() {
        trackedTouch = nil
        cancelRepeat()
        cancelTracking(with: nil)
        isHighlighted = false
    }
    func enableRepeat(_ action: @escaping () -> Void) {
        repeatAction = action
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.35
        repeatGesture = hold
        addGestureRecognizer(hold)
    }
    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, validTouch {
            repeatingContact = true
            updateContactAppearance()
            repeatAction?()
            repeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(55))
                    guard !Task.isCancelled, let self, self.validTouch else { return }
                    self.repeatAction?()
                }
            }
        } else if gesture.state != .changed || !validTouch || !bounds.contains(gesture.location(in: self)) {
            cancelInteraction()
        }
    }
    func cancelRepeat() {
        repeatTask?.cancel(); repeatTask = nil
        repeatingContact = false
        updateContactAppearance()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelInteraction() } }
}

/// Checks every coalesced sample, so a fast real swipe is never mistaken for a jump.
private func touchJumped(_ touch: UITouch, with event: UIEvent?, in view: UIView?) -> Bool {
    var previous = touch.previousLocation(in: view)
    for sample in event?.coalescedTouches(for: touch) ?? [touch] {
        let point = sample.location(in: view)
        if TerminalTouchKeyboardModel.isTouchJump(from: previous, to: point) { return true }
        previous = point
    }
    return false
}

/// Wait for a full stroke before cancelling a key's pending tap. Horizontal
/// strokes change pages; vertical ones resize, but only when `allowsVertical`
/// so the tools grid can still scroll.
private final class TerminalKeyboardPageSwipe: UIGestureRecognizer {
    private var origin = CGPoint.zero
    private var originTime: TimeInterval = 0
    var allowsVertical = false
    var offset = 0
    var heightOffset = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, event.allTouches?.count == 1, let touch = touches.first else {
            state = .failed; return
        }
        origin = touch.location(in: view)
        originTime = touch.timestamp
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // A second contact may have been rejected by the delegate (for example
        // over a toolbar control), so recheck the event before recognizing.
        guard event.allTouches?.count == 1, let touch = touches.first,
              !touchJumped(touch, with: event, in: view) else {
            state = .failed; return
        }
        let point = touch.location(in: view)
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let duration = touch.timestamp - originTime
        if let offset = TerminalTouchKeyboardModel.pageSwipe(translation: delta, duration: duration) {
            self.offset = offset
            state = .recognized
        } else if allowsVertical, let offset = TerminalTouchKeyboardModel.heightSwipe(translation: delta, duration: duration) {
            heightOffset = offset
            state = .recognized
        } else if !allowsVertical, abs(delta.y) > 35 {
            state = .failed
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); offset = 0; heightOffset = 0 }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // This includes UIKit's native floating-keyboard pinch recognizer on
        // an ancestor. A one-finger stroke must never lock out a later pinch.
        if preventedGestureRecognizer is UIPinchGestureRecognizer { return false }
        // UIKit may use a custom recognizer for its floating transition rather
        // than a UIPinchGestureRecognizer subclass. Yield to the hosting views
        // without depending on any private UIKit class name.
        if let host = preventedGestureRecognizer.view, let view,
           host !== view, view.isDescendant(of: host) { return false }
        return super.canPrevent(preventedGestureRecognizer)
    }
}

final class TerminalTouchKeyboardView: UIView, KeyboardButtonDelegate, UIGestureRecognizerDelegate {
    typealias Model = TerminalTouchKeyboardModel
    weak var host: TerminalTouchKeyboardHost? {
        didSet {
            updateAppearance()
            if toolPage == .dictation { configureDictationPane() }
        }
    }
    private var palette: TerminalTouchKeyboardPalette?
    /// Steampunk keeps its brass-matched ivory/enamel caps unless explicitly opted in.
    /// Retro styles keep their signature colors and blend their neutrals toward the palette.
    private var keycapPalette: TerminalTouchKeyboardPalette? {
        switch keyboardStyle {
        case .steampunk: SettingsStore.shared.value(Settings.Keyboard.touchSteampunkThemeAwareKeycaps) ? palette : nil
        case .flat, .sculpted, .phosphor, .beigeBox, .neonGrid, .circuitBoard: palette
        }
    }
    var onAppearanceChanged: (() -> Void)?
    var containerBackgroundColor: UIColor { palette?.background ?? TerminalTouchKeyboardAppearance.background }
    weak var sequenceDelegate: KeyboardButtonDelegate?
    var onModifiersChanged: ((KeyModifiers) -> Void)?
    var onDismiss: (() -> Void)?
    var onPinHidden: (() -> Void)?
    var onSwitchKeyboard: (() -> Void)?
    var onCompose: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTabs: (() -> Void)?
    var onCustomize: (() -> Void)?
    var onToolbarAction: ((String) -> Void)?
    var onHeightChanged: (() -> Void)?
    var onPageChanged: ((Model.ToolPage) -> Void)?
    /// SwiftUI already places embedded previews inside its safe area. Applying
    /// the window's insets again squeezes their keys to one side on iPhone Duo.
    var isEmbeddedPreview = false
    private var horizontalContentInsets: (leading: CGFloat, trailing: CGFloat) {
        if isFloating { return (0, 0) }
        // The SwiftUI host owns clearance, including reserved-region checks
        // when it extends below Duo's camera. UIKit's rectangular safe area
        // still reserves the entire camera column there.
        if isEmbeddedPreview { return (0, 0) }
        return (max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0),
                max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0))
    }
    /// Renders this style instead of the saved one (onboarding previews).
    var styleOverride: Model.Style? {
        didSet { if oldValue != styleOverride { refreshSettings() } }
    }
    /// Only the app-contained host supports our explicit placement requests.
    /// Native placement must remain under UIKit's control.
    var usesSystemPlacement = false {
        didSet {
            guard oldValue != usesSystemPlacement else { return }
            placementPinch?.isEnabled = !isToolbarOnly && !usesSystemPlacement
            placementDockTap?.isEnabled = !isToolbarOnly && !usesSystemPlacement
            pinchPlacement = nil
            cancelInteraction()
            refreshPlacementActions()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            onHeightChanged?()
        }
    }
    private var placementPinch: UIPinchGestureRecognizer?
    private var placementDockTap: UITapGestureRecognizer?
    private var pinchPlacement: Model.Placement?
    var onPlacementRequested: ((Model.Placement) -> Void)? { didSet { refreshPlacementActions() } }
    var onFloatingDrag: ((CGPoint, Bool) -> Void)?
    /// UIKit's floating-keyboard handle in the system container; ours forwards to it.
    var systemFloatingHandle: (() -> UIView?)?
    var onFloatingDragCancelled: (() -> Void)?
    var onFloatingNudge: ((CGPoint) -> Void)?
    private(set) var isFloating = false
    var floatingAvailableHeight: CGFloat = 1000 {
        didSet { if abs(oldValue - floatingAvailableHeight) > 0.5 { setNeedsLayout() } }
    }
    /// UIKit fixes a docked input view's height while the Duo's fold divides
    /// the display, ignoring self-sizing. Set by the owning window.
    var fillsHostHeight = false {
        didSet {
            guard oldValue != fillsHostHeight else { return }
            if !fillsHostHeight { hostFill = nil }
            setNeedsLayout()
        }
    }
    /// The fold in content coordinates while the keyboard is split around it.
    private var splitFoldSpan: ClosedRange<Double>?
    /// The typing rows are currently built as split halves.
    private var splitActive: Bool { splitFoldSpan != nil }
    /// Main toolbar columns around the fold; toolbar drawer rows snap to them.
    private var toolbarColumns: Model.SplitColumns?

    /// The half-open Duo's vertical fold, as UIKit reserves it in this view.
    /// Queried here: the app window's regions don't convert into the keyboard window.
    private var splitFoldFrame: CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return reservedRegions(kind: .division).map(\.frame).first { $0.height > $0.width }
    }

    private func splitLayout(leading: CGFloat, width: CGFloat)
        -> (rows: [Model.SplitRow], metrics: Model.SplitMetrics, fold: ClosedRange<Double>)? {
        guard !isFloating, !isEmbeddedPreview, window != nil, let fold = splitFoldFrame else { return nil }
        guard fold.minX - leading > 0, fold.maxX - leading < width else { return nil }
        let rows = Model.splitRows(Model.rows(page: page))
        let span = Double(fold.minX - leading)...Double(fold.maxX - leading)
        return Model.splitMetrics(rows, width: Double(width), fold: span).map { (rows, $0, span) }
    }

    /// Columns for a row inset 5pt on each side, as the toolbar and drawers are.
    private func splitColumns(count: Int, width: CGFloat) -> Model.SplitColumns? {
        splitFoldSpan.flatMap {
            Model.splitColumns(count: count, width: Double(width - 10), fold: ($0.lowerBound - 5)...($0.upperBound - 5))
        }
    }

    /// Toolbar capacity excludes the fold, so no slot is lost to the crease.
    private func toolbarWidth(_ width: CGFloat) -> CGFloat {
        width - CGFloat(splitFoldSpan.map(Model.splitFoldBlock) ?? 0)
    }
    /// Row height and top remainder for a height UIKit fixed; nil when self-sizing.
    private var hostFill: (rowHeight: CGFloat, top: CGFloat)?
    private var contentTop: CGFloat { hostFill?.top ?? 0 }

    private(set) var isToolbarOnly = false
    private var toolbarBottomInset: CGFloat = 0
    private var showsRestore = false
    private var pinnedHidden = false
    private var toolbarInteractionMode: KeyboardToolbarInteractionMode = .accessory
    var toolbarContentHeight: CGFloat { toolbarHeight }

    func setToolbarPresentation(only: Bool, bottomInset: CGFloat, showsRestore: Bool, pinned: Bool) {
        let changed = isToolbarOnly != only || toolbarBottomInset != bottomInset
        guard changed || self.showsRestore != showsRestore || pinnedHidden != pinned else { return }
        if isToolbarOnly != only { cancelInteraction(preservingModifiers: true) }
        isToolbarOnly = only
        toolbarBottomInset = bottomInset
        self.showsRestore = showsRestore
        pinnedHidden = pinned
        placementPinch?.isEnabled = !only && !usesSystemPlacement
        placementDockTap?.isEnabled = !only && !usesSystemPlacement
        if only { setFloating(false) }
        refreshPlacementActions()
        publishModifiers()
        setNeedsLayout()
        if changed {
            invalidateIntrinsicContentSize()
            onHeightChanged?()
        }
    }

    func setToolbarInteractionMode(_ mode: KeyboardToolbarInteractionMode) {
        guard toolbarInteractionMode != mode else { return }
        cancelInteraction(preservingModifiers: true)
        toolbarInteractionMode = mode
        writingAssistanceButton.interactionMode = mode
        toolbarDrawerButtons.flatMap { $0 }.forEach { $0.interactionMode = mode }
    }

    private var pendingPresentationOffsets: Model.PresentationState?

    var presentationState: Model.PresentationState {
        Model.PresentationState(modifiers: modifierState, page: page, preset: preset,
            toolPage: toolPage, toolbarDrawer: toolbarDrawerState,
            drawerOffset: pendingPresentationOffsets?.drawerOffset ?? drawer.contentOffset,
            toolbarOffsets: pendingPresentationOffsets?.toolbarOffsets ?? Dictionary(uniqueKeysWithValues:
                zip(toolbarDrawerIndices, toolbarDrawerRows).map { ($0, $1.contentOffset) }))
            .suspendingInput()
    }

    func restorePresentationState(_ state: Model.PresentationState) {
        cancelInteraction()
        page = state.page
        preset = state.preset
        presets.selectedSegmentIndex = Model.Preset.allCases.firstIndex(of: preset) ?? 0
        toolPage = toolPages.contains(state.toolPage) ? state.toolPage : .typing
        toolbarDrawerState = state.toolbarDrawer
        rebuildKeys()
        rebuildDrawer()
        modifierState = state.suspendingInput().modifiers
        pendingPresentationOffsets = state
        publishModifiers()
        invalidateIntrinsicContentSize()
        onHeightChanged?()
        setNeedsLayout()
    }

    private var modifierState = Model.Modifiers()
    private var page = Model.Page.letters
    private var preset = Model.Preset.shell
    private var toolPage = Model.ToolPage.typing
    private var drawerOpen: Bool { toolPage != .typing }
    #if canImport(FluidAudio) && !CHINA_BUILD
    /// Created on first visit so the speech stack stays untouched until used.
    private var loadedDictationPane: TerminalDictationPaneView?
    private var dictationPane: TerminalDictationPaneView {
        if let pane = loadedDictationPane { return pane }
        let pane = TerminalDictationPaneView()
        pane.onFeedback = { [weak self] in self?.feedback() }
        pane.isHidden = true
        addSubview(pane)
        loadedDictationPane = pane
        return pane
    }
    #endif
    private var dictationEnabled = DictationSupport.isEnabled
    private var toolPages: [Model.ToolPage] { Model.ToolPage.pages(dictation: dictationEnabled) }
    private var toolbarDrawerKeys: [[Model.Key]] = []
    private var configuredDrawerToggle: Model.Key?
    private var toolbarDrawerState = Model.ToolbarDrawerState.closed
    private var toolbarDrawerOpenByDefault = KeyboardToolbarManager.shared.drawerOpenByDefault
    private var toolbarDrawerRows: [UIScrollView] = []
    private var toolbarDrawerIndices: [Int] = []
    private var toolbarDrawerButtons: [[TerminalTouchDrawerButton]] = []
    private var toolbarDrawerHeight: CGFloat { CGFloat(toolbarDrawerRows.count) * keyboardHeight.toolbarDrawerRowHeight }
    private var toolbarHeight: CGFloat { keyboardHeight.toolbarRowHeight + toolbarDrawerHeight }
    private var configuredMain: [Model.Key] = []
    private var configuredDrawers: [[Model.Key]] = []
    private var rows: [[TerminalTouchKeycap]] = []
    private var controls: [TerminalTouchKeycap] = []
    private let background = UIView()
    private let floatingGlass = UIVisualEffectView()
    private let controlGlass = UIVisualEffectView()
    private var steampunkMachinery: TerminalTouchSteampunkMachineryView?
    private var retroBackdrop: TerminalTouchRetroBackdropView?
    private struct GlassAppearance: Equatable {
        let toolbar: UIColor
        let background: UIColor
        let floating: Bool
        let style: Model.FloatingGlassStyle
        let tintOpacity: Double
        let reduceTransparency: Bool
    }
    private var glassAppearance: GlassAppearance?
    // Previews own their surface. Terminal controllers bind the surface from
    // the selected shared/per-tab state only while this keyboard is active.
    private var effectSurface: TerminalKeyboardEffectSurface? = TerminalKeyboardEffectSurface()

    func setBackgroundEffectSurface(_ surface: TerminalKeyboardEffectSurface?) {
        guard effectSurface !== surface else { return }
        effectSurface?.detach(from: self)
        effectSurface = surface
        updateBackgroundEffect()
    }
    private var effectPlacement = Model.BackgroundEffectPlacement.off
    private var effectsSuspended = UIApplication.shared.applicationState != .active
    private let drawer = UIScrollView()
    private let pageIndicator = UIVisualEffectView()
    private let pageIndicatorTitle = UILabel()
    private var pageIndicatorDots: [UIView] = []
    private let heightIndicatorDots: [UIView] = Model.Height.allCases.map { _ in UIView() }
    /// Set while the HUD reports a height swipe, which shows a vertical dot column.
    private var pageIndicatorHeight: Model.Height?
    private var pageIndicatorHideTask: Task<Void, Never>?
    private let presets = UISegmentedControl(items: Model.Preset.allCases.map(\.rawValue))
    private let writingAssistanceButton = TerminalTouchRepeatingButton(type: .system)
    /// Covers the Apple Keyboard key: tap switches keyboards, hold opens the style menu.
    private let styleMenuButton = TerminalTouchMenuKeyButton(type: .custom)
    private let grabber = UIButton(type: .system)
    private var drawerButtons: [TerminalTouchDrawerButton] = []
    private var drawerColumns = 6
    private var allKeycaps: [TerminalTouchKeycap] {
        controls + rows.flatMap { $0 } + drawerButtons.map(\.keycap)
            + toolbarDrawerButtons.flatMap { $0 }.map(\.keycap)
    }
    private let suggestions = UIStackView()
    private var keyboardStyle = SettingsStore.shared.value(Settings.Keyboard.touchStyle)
    private var preview = SettingsStore.shared.value(Settings.Keyboard.touchStyle).makePreview()
    private let accents = UIStackView()
    private var accentChoices: [String] = []
    private var accentIndex = 0
    private let checker = UITextChecker()
    private var suggestionTask: Task<Void, Never>?
    private var sequenceTask: Task<Void, Never>?
    private var drawerJoystickTask: Task<Void, Never>?
    private var drawerJoystickDirection: String?
    private var lastSuggestionContext: Model.SuggestionContext?
    private var observations = Set<AnyCancellable>()
    private var heightConstraint: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var suggestionsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
    private var predictionEnabled = SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction)
    private var predictionTask: Task<Void, Never>?
    private var pendingPrediction: Model.PredictionSnapshot?
    private var predictionCache = Model.PredictionCache()
    private let predictionLanguage = UITextChecker.availableLanguages.first { $0.hasPrefix("en") }
    private var typingGeometry = Model.TypingGeometry(targets: [], bounds: .zero)
    private var nextContactOrder: UInt64 = 0
    private var hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
    private var clickSoundEnabled = SettingsStore.shared.value(Settings.Keyboard.touchClickSound)
    private var characterPreviewEnabled = SettingsStore.shared.value(Settings.Keyboard.touchCharacterPreview)
    private var heightSetting = TerminalTouchKeyboardView.resolvedHeightSetting()
    /// The detached keyboard sizes itself, so it keeps the default metrics.
    private var keyboardHeight: Model.Height { isFloating ? .large : heightSetting }
    private var glyphsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
    #if !os(visionOS)
    private lazy var haptic = UIImpactFeedbackGenerator(style: .light, view: self)
    #endif

    private final class Contact {
        let initial: TerminalTouchKeycap
        var current: TerminalTouchKeycap?
        let origin: CGPoint
        var windowOrigin = CGPoint.zero
        var interactionMode: KeyboardToolbarInteractionMode = .accessory
        var anchor: CGPoint
        var task: Task<Void, Never>?
        var consumed = false
        var trackpad = false
        var accent = false
        var direction: String?
        var began: TimeInterval = 0
        /// Began during fast typing, when merged touches are likely.
        var fastTyping = false
        /// Movement held back while the contact may still be two merged taps.
        var deferredPoint: CGPoint?
        let order: UInt64
        var selection: Model.TouchSelection?
        init(key: TerminalTouchKeycap, point: CGPoint, order: UInt64, selection: Model.TouchSelection?) {
            initial = key; current = key; origin = point; anchor = point
            self.order = order; self.selection = selection
        }
    }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var lastTextDown = -TimeInterval.infinity
    private var lastRelease: (point: CGPoint, time: TimeInterval)?
    private var canSend: Bool {
        !isHidden && window?.windowScene?.activationState == .foregroundActive && host?.touchKeyboardCanSend == true
    }
    /// Returns a parked card's focus to its terminal before the first key.
    var onReclaimFocus: (() -> Bool)?
    private var canSendReclaimingFocus: Bool {
        canSend || (onReclaimFocus?() == true && canSend)
    }
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var rowHeight: CGFloat {
        if let hostFill, !isToolbarOnly { return hostFill.rowHeight }
        if isFloating {
            // Apple's floating keyboard uses phone rows, so the phone-tuned touch rules fit it.
            let phoneRow = Model.Height.large.rowHeight(verticallyCompact: false, pad: false)
            return min(phoneRow, max(28, (floatingAvailableHeight - toolbarHeight - bottomInset - (suggestionsEnabled ? 36 : 0)) / 4))
        }
        return keyboardHeight.rowHeight(verticallyCompact: compact, pad: traitCollection.userInterfaceIdiom == .pad)
    }
    private var deviceBottomInset: CGFloat {
        // An embedded settings preview must not inherit padding from the window's
        // bottom edge unless the keyboard actually reaches that edge.
        guard let window, convert(bounds, to: window).maxY >= window.bounds.maxY - 1 else {
            return safeAreaInsets.bottom
        }
        return max(safeAreaInsets.bottom, window.safeAreaInsets.bottom)
    }
    /// Shorter heights reclaim the home-indicator strip; a fixed height has room to spare.
    private var extendsIntoBottomSafeArea: Bool { heightSetting.usesBottomSafeArea && !fillsHostHeight }
    private var bottomInset: CGFloat { isFloating ? 44 : (extendsIntoBottomSafeArea ? 6 : max(6, deviceBottomInset)) }
    private var desiredHeight: CGFloat {
        // Claim all of a fixed height so the terminal pads for what UIKit shows.
        if hostFill != nil { return bounds.height }
        return isToolbarOnly ? toolbarHeight + toolbarBottomInset
            : toolbarHeight + rowHeight * 4 + bottomInset + (suggestionsEnabled ? 36 : 0)
    }

    private static func resolvedHeightSetting() -> Model.Height {
        Model.Height.resolved(
            inner: SettingsStore.shared.value(Settings.Keyboard.touchHeight),
            front: SettingsStore.shared.value(Settings.Keyboard.touchHeightDuoFront),
            isFrontDisplay: DuoHingeEvents.isFrontDisplay)
    }

    private func updateHostFill() {
        guard fillsHostHeight, !isFloating else {
            hostFill = nil
            return
        }
        // Keep the last fill through UIKit's zero-size interim layouts.
        guard bounds.height > 0 else { return }
        let chrome = toolbarHeight
            + (isToolbarOnly ? toolbarBottomInset : bottomInset + (suggestionsEnabled ? 36 : 0))
        let fill = Model.fixedHeightLayout(height: bounds.height, chrome: chrome, rowCount: isToolbarOnly ? 0 : 4)
        hostFill = (CGFloat(fill.rowHeight), CGFloat(fill.top))
    }

    init() {
        // Supply one surface ourselves; UIKit's keyboard style adds another
        // material behind it, which washes out the native dark palette.
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 304))
        translatesAutoresizingMaskIntoConstraints = false
        isMultipleTouchEnabled = true
        floatingGlass.isUserInteractionEnabled = false
        floatingGlass.layer.cornerRadius = 24
        floatingGlass.layer.cornerCurve = .continuous
        floatingGlass.clipsToBounds = true
        floatingGlass.isHidden = true
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        background.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(background)
        addSubview(floatingGlass)
        controlGlass.isUserInteractionEnabled = false
        controlGlass.layer.cornerRadius = 22
        controlGlass.layer.cornerCurve = .continuous
        controlGlass.clipsToBounds = true
        addSubview(controlGlass)
        heightConstraint = heightAnchor.constraint(equalToConstant: desiredHeight)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        let pageSwipe = TerminalKeyboardPageSwipe(target: self, action: #selector(swipePage(_:)))
        pageSwipe.delegate = self
        pageSwipe.cancelsTouchesInView = true
        pageSwipe.delaysTouchesBegan = false
        addGestureRecognizer(pageSwipe)
        drawer.panGestureRecognizer.require(toFail: pageSwipe)
        presets.selectedSegmentIndex = Model.Preset.allCases.firstIndex(of: preset) ?? 0
        presets.addTarget(self, action: #selector(changePreset), for: .valueChanged)
        presets.accessibilityLabel = String(localized: "Keyboard preset")
        addSubview(presets)
        drawer.showsVerticalScrollIndicator = true
        drawer.alwaysBounceVertical = false
        addSubview(drawer)
        pageIndicator.layer.cornerRadius = 16
        pageIndicator.layer.cornerCurve = .continuous
        pageIndicator.clipsToBounds = true
        pageIndicator.isUserInteractionEnabled = false
        pageIndicator.accessibilityElementsHidden = true
        pageIndicator.alpha = 0
        pageIndicatorTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        pageIndicatorTitle.textAlignment = .center
        pageIndicatorTitle.textColor = .white
        pageIndicator.contentView.addSubview(pageIndicatorTitle)
        heightIndicatorDots.forEach { pageIndicator.contentView.addSubview($0) }
        rebuildPageIndicatorDots()
        addSubview(pageIndicator)
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        addSubview(suggestions)
        preview.isUserInteractionEnabled = false
        preview.isHidden = true
        addSubview(preview)
        accents.axis = .horizontal
        accents.distribution = .fillEqually
        accents.layer.cornerRadius = 12
        accents.clipsToBounds = true
        accents.isUserInteractionEnabled = false
        accents.isHidden = true
        addSubview(accents)
        writingAssistanceButton.showsMenuAsPrimaryAction = true
        writingAssistanceButton.accessibilityLabel = String(localized: "Writing Assistance")
        addSubview(writingAssistanceButton)
        // Built on open, so nothing observes settings and a pick writes once.
        styleMenuButton.menu = UIMenu(title: String(localized: "Keyboard Style"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.keyboardStyleMenuItems() ?? []) }
        ])
        styleMenuButton.isAccessibilityElement = false
        styleMenuButton.addAction(UIAction { [weak self] _ in self?.pressKeyboardSwitch(true) }, for: .touchDown)
        styleMenuButton.addAction(UIAction { [weak self] _ in self?.pressKeyboardSwitch(false) },
                                  for: [.touchUpInside, .touchUpOutside, .touchCancel, .menuActionTriggered])
        styleMenuButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.styleMenuButton.showedMenu, let cap = self.keyboardSwitchCap else { return }
            self.perform(cap.key)
        }, for: .primaryActionTriggered)
        addSubview(styleMenuButton)
        grabber.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        grabber.accessibilityLabel = String(localized: "Move keyboard")
        grabber.accessibilityHint = String(localized: "Drag to move. Double-tap to dock.")
        addSubview(grabber)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragFloatingKeyboard(_:)))
        drag.maximumNumberOfTouches = 1
        grabber.addGestureRecognizer(drag)
        let dock = UITapGestureRecognizer(target: self, action: #selector(dockKeyboard))
        dock.numberOfTapsRequired = 2
        dock.isEnabled = !usesSystemPlacement
        dock.require(toFail: drag)
        placementDockTap = dock
        grabber.addGestureRecognizer(dock)
        if traitCollection.userInterfaceIdiom == .pad {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchKeyboard(_:)))
            pinch.cancelsTouchesInView = true
            pinch.delegate = self
            pinch.isEnabled = !usesSystemPlacement
            placementPinch = pinch
            addGestureRecognizer(pinch)
        }
        if #available(iOS 27.1, *) {
            // Folding moves the division region without resizing the keyboard.
            addInteraction(UIHingeInteraction { [weak self] _, _ in self?.setNeedsLayout() })
        }
        loadToolbarConfiguration()
        if KeyboardToolbarManager.shared.drawerOpenByDefault {
            toolbarDrawerState = .closed.toggled(rowCount: configuredDrawers.count,
                cycle: KeyboardToolbarManager.shared.drawerToggleMode == .cycle)
        }
        rebuildKeys()
        rebuildDrawer()
        ThemeManager.shared.themeDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        ThemeOverrideManager.shared.overridesDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        // The palette follows the backdrop showing through the terminal
        TransparencyManager.shared.transparencyDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        EffectManager.shared.effectDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateBackgroundEffect()
        }.store(in: &observations)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification, Notification.Name.settingsDidChange,
                     Notification.Name.duoDisplayDidChange,
                     KeyboardToolbarManager.layoutDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == UIAccessibility.reduceMotionStatusDidChangeNotification
                        || name == Notification.Name.NSProcessInfoPowerStateDidChange {
                        // Changing visual policy must not cancel a held key,
                        // rebuild the hit grid, or consume sticky modifiers.
                        self.allKeycaps.forEach { $0.finishVisualTransition() }
                        self.updateSteampunkMachinery()
                        return
                    }
                    // Activation only pauses and resumes the effect. Settings,
                    // theme and toolbar changes each arrive through their own
                    // notification, so no rebuild is needed on either edge.
                    if name == UIApplication.willResignActiveNotification {
                        self.cancelInteraction(preservingModifiers: true)
                        self.effectsSuspended = true
                        self.updateBackgroundEffect()
                        return
                    }
                    if name == UIApplication.didBecomeActiveNotification {
                        self.effectsSuspended = false
                        self.updateBackgroundEffect()
                        return
                    }
                    self.refreshSettings()
                }
            }
            observations.insert(AnyCancellable { NotificationCenter.default.removeObserver(token) })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) {
            (self: TerminalTouchKeyboardView, _: UITraitCollection) in
            self.cancelInteraction(preservingModifiers: true)
            self.updateAppearance()
            self.setNeedsLayout()
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight) }

    func setFloating(_ floating: Bool) {
        let floating = floating && !isToolbarOnly
        guard isFloating != floating else { return }
        cancelInteraction(preservingModifiers: true)
        isFloating = floating
        rebuildKeys()
        layer.shadowColor = UIColor.black.cgColor
        layer.cornerRadius = floating ? 24 : 0
        layer.cornerCurve = .continuous
        layer.shadowOpacity = floating ? 0.25 : 0
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        refreshPlacementActions()
        updateAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The UIInputView root owns height, including zero-height hardware mode.
    /// A second height constraint on the content competes with that collapse.
    func useContainerSizing() {
        heightConstraint.isActive = false
    }

    private func refreshPlacementActions() {
        let keyboardSwitch = rows.flatMap { $0 }.first { $0.key.action == .switchKeyboard }
        grabber.accessibilityHint = usesSystemPlacement
            ? String(localized: "Drag to move.")
            : String(localized: "Drag to move. Double-tap to dock.")
        guard !isToolbarOnly, onPlacementRequested != nil else {
            keyboardSwitch?.accessibilityCustomActions = nil
            grabber.accessibilityCustomActions = nil
            return
        }
        keyboardSwitch?.accessibilityCustomActions = usesSystemPlacement ? nil : [UIAccessibilityCustomAction(name: isFloating ? String(localized: "Dock Keyboard") : String(localized: "Float Keyboard")) { [weak self] _ in
            guard let self else { return false }
            self.cancelInteraction()
            self.onPlacementRequested?(self.isFloating ? .docked : .floating)
            return true
        }]
        // UIKit's handle has no step-by-step move to forward.
        guard !usesSystemPlacement else {
            grabber.accessibilityCustomActions = nil
            return
        }
        grabber.accessibilityCustomActions = [
            (String(localized: "Move left"), CGPoint(x: -44, y: 0)),
            (String(localized: "Move right"), CGPoint(x: 44, y: 0)),
            (String(localized: "Move up"), CGPoint(x: 0, y: -44)),
            (String(localized: "Move down"), CGPoint(x: 0, y: 44))
        ].map { name, offset in UIAccessibilityCustomAction(name: name) { [weak self] _ in
            self?.onFloatingNudge?(offset); return true
        } }
    }

    @objc private func pinchKeyboard(_ gesture: UIPinchGestureRecognizer) {
        guard !isToolbarOnly, !usesSystemPlacement, onPlacementRequested != nil else { return }
        if gesture.state == .began {
            cancelInteraction()
            pinchPlacement = isFloating ? .floating : .docked
        }
        defer {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                pinchPlacement = nil
            }
        }
        // Reparenting or reloading an input root while recognition is still in
        // progress can cancel/reenter UIKit's own input transition. Finish the
        // gesture first, then move containers on the next main-queue turn.
        guard gesture.state == .ended, let initialPlacement = pinchPlacement else { return }
        let destination = Model.placementAfterPinch(gesture.scale, from: initialPlacement)
        guard destination != initialPlacement else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.usesSystemPlacement, self.window != nil,
                  self.isFloating == (initialPlacement == .floating) else { return }
            self.onPlacementRequested?(destination)
        }
    }

    @objc private func dockKeyboard() {
        guard !usesSystemPlacement else { return }
        onPlacementRequested?(.docked)
    }

    @objc private func dragFloatingKeyboard(_ gesture: UIPanGestureRecognizer) {
        guard isFloating, !usesSystemPlacement else { return }
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .began, .changed: onFloatingDrag?(translation, false)
        case .ended: onFloatingDrag?(translation, true)
        case .cancelled, .failed: onFloatingDragCancelled?()
        default: break
        }
    }

    private func refreshSettings() {
        let style = styleOverride ?? SettingsStore.shared.value(Settings.Keyboard.touchStyle)
        if keyboardStyle != style {
            cancelInteraction(preservingModifiers: true)
            keyboardStyle = style
            preview.removeFromSuperview()
            preview = style.makePreview()
            preview.isHidden = true
            addSubview(preview)
        }
        let prediction = SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction)
        if predictionEnabled != prediction {
            cancelInteraction()
            predictionEnabled = prediction
            predictionCache.removeAll()
        }
        updatePrediction()
        let enabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
        if suggestionsEnabled != enabled {
            suggestionsEnabled = enabled
            lastSuggestionContext = nil
            host?.touchKeyboardInvalidateSuggestions()
            updateSuggestions()
        }
        let dictation = DictationSupport.isEnabled
        if dictationEnabled != dictation {
            dictationEnabled = dictation
            if !dictation && toolPage == .dictation {
                #if canImport(FluidAudio) && !CHINA_BUILD
                loadedDictationPane?.paneWillHide()
                #endif
                toolPage = .typing
            }
            rebuildPageIndicatorDots()
        }
        hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
        clickSoundEnabled = SettingsStore.shared.value(Settings.Keyboard.touchClickSound)
        characterPreviewEnabled = SettingsStore.shared.value(Settings.Keyboard.touchCharacterPreview)
        let height = Self.resolvedHeightSetting()
        let glyphs = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
        if heightSetting != height || glyphsEnabled != glyphs { cancelInteraction() }
        heightSetting = height
        glyphsEnabled = glyphs
        loadToolbarConfiguration()
        rebuildKeys()
        updateAppearance()
        rebuildDrawer()
        setNeedsLayout()
    }

    private func updateAppearance() {
        palette = SettingsStore.shared.value(Settings.Keyboard.touchThemeAware)
            ? (host?.touchKeyboardThemeColors ?? ThemeManager.shared.currentThemeInfo?.colors).flatMap { TerminalTouchKeyboardPalette(colors: $0) } : nil
        let style: UIUserInterfaceStyle = palette.map { $0.isLight ? .light : .dark } ?? .unspecified
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        let toolbar = palette?.background ?? TerminalTouchKeyboardAppearance.toolbar
        let floatingStyle = SettingsStore.shared.value(Settings.Keyboard.touchFloatingGlassStyle)
        let usesFloatingGlass = isFloating && floatingStyle != .solid && !UIAccessibility.isReduceTransparencyEnabled
        floatingGlass.isHidden = !usesFloatingGlass
        background.isHidden = usesFloatingGlass
        background.backgroundColor = palette?.background ?? TerminalTouchKeyboardAppearance.background
        // Paint the gaps around the glass toolbar too. A clear input root lets
        // UIKit's independently styled keyboard backdrop show through here.
        backgroundColor = usesFloatingGlass ? .clear : containerBackgroundColor
        let tintOpacity = Model.floatingGlassTintOpacity(SettingsStore.shared.value(Settings.Keyboard.touchFloatingGlassTintOpacity))
        let nextGlassAppearance = GlassAppearance(
            toolbar: toolbar.resolvedColor(with: traitCollection),
            background: containerBackgroundColor.resolvedColor(with: traitCollection),
            floating: isFloating, style: floatingStyle, tintOpacity: tintOpacity,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        // Replacing an identical glass effect briefly rebuilds its backdrop.
        // A new terminal input target does not require a new glass material.
        if glassAppearance != nextGlassAppearance {
            glassAppearance = nextGlassAppearance
            updateGlassAppearance(toolbar: toolbar, floatingStyle: floatingStyle,
                                  usesFloatingGlass: usesFloatingGlass, tintOpacity: tintOpacity)
        }
        pageIndicator.effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemUltraThinMaterialDark)
        pageIndicator.contentView.backgroundColor = UIColor.black.withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 0.9 : 0.3)
        grabber.tintColor = palette?.toolbarInk ?? .label
        let keycapPalette = self.keycapPalette
        preview.palette = keycapPalette
        accents.backgroundColor = keycapPalette?.key ?? .secondarySystemBackground
        (controls + rows.flatMap { $0 }).forEach { $0.palette = keycapPalette }
        (drawerButtons + toolbarDrawerButtons.flatMap { $0 }).forEach { $0.updatePalette(keycapPalette) }
        refreshWritingAssistance()
        rebuildToolbarDrawers()
        updateModifierAppearance()
        updateBackgroundEffect()
        onAppearanceChanged?()
    }

    private func updateGlassAppearance(toolbar: UIColor, floatingStyle: Model.FloatingGlassStyle,
                                       usesFloatingGlass: Bool, tintOpacity: Double) {
        if usesFloatingGlass {
            let tint = containerBackgroundColor.withAlphaComponent(CGFloat(tintOpacity))
            // One material for the whole detached card lets terminal content
            // show through the gaps without blurring the key labels themselves.
            if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: floatingStyle == .clear ? .clear : .regular)
                glass.tintColor = tint
                floatingGlass.effect = glass
                floatingGlass.contentView.backgroundColor = .clear
            } else {
                floatingGlass.effect = UIBlurEffect(style: floatingStyle == .clear ? .systemUltraThinMaterial : .systemThinMaterial)
                floatingGlass.contentView.backgroundColor = tint
            }
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar.withAlphaComponent(0.14)
        } else if isFloating {
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar
        } else if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            let glass = UIGlassEffect(style: .clear)
            glass.tintColor = toolbar.withAlphaComponent(0.8)
            controlGlass.effect = glass
            controlGlass.contentView.backgroundColor = .clear
        } else if UIAccessibility.isReduceTransparencyEnabled {
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar
        } else {
            controlGlass.effect = UIBlurEffect(style: .systemThinMaterial)
            controlGlass.contentView.backgroundColor = toolbar.withAlphaComponent(0.75)
        }
        controlGlass.backgroundColor = .clear
        if !usesFloatingGlass { floatingGlass.effect = nil }
    }

    /// The optional instrument sits above the glass/effect but below every key.
    /// Binding visual feedback never replaces input handlers or touch geometry.
    private func updateSteampunkMachinery() {
        updateRetroBackdrop()
        guard keyboardStyle == .steampunk else {
            steampunkMachinery?.resetContactFeedback()
            steampunkMachinery?.removeFromSuperview()
            steampunkMachinery = nil
            return
        }
        let machine: TerminalTouchSteampunkMachineryView
        if let existing = steampunkMachinery {
            machine = existing
        } else {
            machine = TerminalTouchSteampunkMachineryView()
            steampunkMachinery = machine
            insertSubview(machine, aboveSubview: controlGlass)
        }
        machine.frame = bounds
        machine.layer.cornerRadius = isFloating ? 24 : 0
        machine.configure(palette: palette, rows: styleBackdropBands,
                          active: window != nil && !isHidden && !effectsSuspended)
        for case let cap as TerminalTouchSteampunkKeycap in allKeycaps {
            cap.machinery = machine
        }
    }

    /// Exclude suggestion and preset rows: their original text stays on its
    /// original background, not on a style's bed or moving artwork.
    /// These are artwork bands, not hit cells: the final band includes the
    /// bottom safe area (or floating grabber) so row-based details reach the edge.
    private var styleBackdropBands: [CGRect] {
        var bands = [CGRect(x: 0, y: contentTop, width: bounds.width, height: toolbarHeight)]
        if !isToolbarOnly {
            if drawerOpen {
                bands.append(CGRect(x: 0, y: drawer.frame.minY, width: bounds.width, height: drawer.frame.height))
            } else {
                bands += rows.compactMap { row -> CGRect? in
                    guard let first = row.first, first.frame.height > 0 else { return nil }
                    return CGRect(x: 0, y: first.frame.minY, width: bounds.width, height: first.frame.height)
                }
            }
        }
        if let last = bands.indices.last {
            bands[last].size.height = max(bands[last].height, bounds.maxY - bands[last].minY)
        }
        return bands
    }

    private func updateRetroBackdrop() {
        guard let design = keyboardStyle.retroDesign else {
            retroBackdrop?.resetContactFeedback()
            retroBackdrop?.removeFromSuperview()
            retroBackdrop = nil
            return
        }
        let backdrop: TerminalTouchRetroBackdropView
        if let existing = retroBackdrop {
            backdrop = existing
        } else {
            backdrop = TerminalTouchRetroBackdropView()
            retroBackdrop = backdrop
            insertSubview(backdrop, aboveSubview: controlGlass)
        }
        backdrop.frame = bounds
        backdrop.layer.cornerRadius = isFloating ? 24 : 0
        backdrop.configure(design: design, palette: palette, rows: styleBackdropBands,
                           active: window != nil && !isHidden && !effectsSuspended)
        for case let cap as TerminalTouchRetroKeycap in allKeycaps {
            cap.backdrop = backdrop
        }
    }

    private func updateBackgroundEffect() {
        updateSteampunkMachinery()
        effectPlacement = SettingsStore.shared.value(Settings.Shaders.keyboardBackgroundEffect)
        guard let effectSurface, window != nil, !isHidden, !effectsSuspended,
              effectPlacement != .off, let effect = EffectManager.shared.keyboardEffect else {
            removeBackgroundEffect()
            return
        }

        // Keep glass above the effect, with the existing tint and material.
        // A detached glass keyboard must retain its transparent backdrop.
        let color: UIColor = !floatingGlass.isHidden ? .clear : (effectPlacement == .toolbar
            ? (palette?.background ?? TerminalTouchKeyboardAppearance.toolbar) : containerBackgroundColor)
        effectSurface.attach(to: self, above: background, effectID: ObjectIdentifier(effect), backgroundColor: color) {
            AnyView(TerminalTouchKeyboardEffectBackground(appearance: effectSurface.appearance, effect: effect))
        }
        layoutBackgroundEffect()
    }

    private func layoutBackgroundEffect() {
        guard let view = effectSurface?.contentView, view.superview === self else { return }
        view.frame = effectPlacement == .toolbar ? controlGlass.frame : bounds
        view.layer.cornerRadius = effectPlacement == .toolbar ? 22 : (isFloating ? 24 : 0)
    }

    private func removeBackgroundEffect() {
        effectSurface?.detach(from: self)
    }

    private func makeCap(_ key: Model.Key, small: Bool = false) -> TerminalTouchKeycap {
        let cap = keyboardStyle.makeKeycap(key, small: small)
        cap.palette = keycapPalette
        cap.activate = { [weak self, weak cap] in
            guard let self, let cap, self.canSend else { return }
            if case .modifier(let mod) = key.action {
                self.modifierState.begin(mod)
                self.modifierState.end(mod, at: ProcessInfo.processInfo.systemUptime)
                self.publishModifiers()
            } else if key.action == .joystick {
                self.showPage(.navigation)
            } else { self.perform(cap.key) }
        }
        if case .text(let text) = key.action, let variants = Model.accents[text] {
            cap.accessibilityCustomActions = variants.map { variant in
                UIAccessibilityCustomAction(name: String(variant)) { [weak self] _ in
                    guard let self, self.canSend else { return false }
                    self.perform(Model.Key(title: String(variant), action: .text(String(variant))))
                    return true
                }
            }
        }
        addSubview(cap)
        return cap
    }

    private func loadToolbarConfiguration() {
        let manager = KeyboardToolbarManager.shared
        func key(for slot: KeySlot) -> Model.Key? {
            switch slot {
            case .custom(let id):
                guard let custom = manager.customKey(for: id) else { return nil }
                return Model.Key(title: custom.label, action: .custom(id), symbol: custom.iconName, accessibility: custom.label)
            case .builtIn(let id):
                guard !manager.config.hiddenKeys.contains(id) else { return nil }
                guard id.isAvailable else { return nil }
                let action: Model.Action
                let title: String
                switch id {
                case .esc: action = .key("\u{1b}"); title = "Esc"
                case .ctrl: action = .modifier(.control); title = "Ctrl"
                case .alt: action = .modifier(.alt); title = "Alt"
                case .shift: action = .modifier(.shift); title = "Shift"
                case .cmd: action = .modifier(.command); title = "Cmd"
                case .tab: action = .key("\t"); title = "Tab"
                case .arrowDrawerToggle: action = .joystick; title = id.displayName
                case .drawerToggle: action = .drawer; title = "…"
                case .dismiss: action = .dismiss; title = id.displayName
                case .tabSwitcher: action = .tabs; title = id.displayName
                case .compose: action = .compose; title = id.displayName
                case .paste: action = .paste; title = id.displayName
                default:
                    title = id.category == .symbol ? id.keyValue : id.displayName
                    action = id.category == .symbol ? .text(id.keyValue)
                        : (id.category == .navigation ? .key(id.keyValue) : .toolbar(id.keyValue))
                }
                return Model.Key(title: title, action: action, symbol: id.iconName, accessibility: id.displayName)
            }
        }
        configuredDrawerToggle = key(for: .builtIn(.drawerToggle))
        configuredMain = (manager.config.leftPinned + manager.config.mainRow + manager.config.rightPinned).compactMap(key)
        configuredDrawers = manager.config.drawerRows.map { $0.compactMap(key) }
        if manager.drawerOpenByDefault && !toolbarDrawerOpenByDefault && toolbarDrawerState == .closed {
            toolbarDrawerState = .closed.toggled(rowCount: configuredDrawers.count, cycle: manager.drawerToggleMode == .cycle)
        }
        toolbarDrawerOpenByDefault = manager.drawerOpenByDefault
    }

    private func rebuildKeys() { rebuildKeysForWidth(max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right)) }

    private func rebuildKeysForWidth(_ width: CGFloat) {
        (controls + rows.flatMap { $0 }).forEach { $0.removeFromSuperview() }
        let toolbar = Model.toolbarKeys(main: configuredMain, drawers: configuredDrawers, width: toolbarWidth(width), drawerToggle: configuredDrawerToggle)
        controls = toolbar.main.map { makeCap($0, small: true) }
        toolbarDrawerKeys = toolbar.drawers
        rebuildToolbarDrawers()
        if let cap = controls.first(where: { $0.key.action == .toolbar(KeyID.writingAssistance.keyValue) }) {
            cap.isAccessibilityElement = false
        }
        bringSubviewToFront(writingAssistanceButton)
        let typingRows = splitActive ? Model.splitRows(Model.rows(page: page)).map { $0.left + $0.right } : Model.rows(page: page, floating: isFloating)
        // In the detached footer the switch key draws plain, like Apple's globe.
        rows = typingRows.map { $0.map { makeCap($0, small: isFloating && $0.action == .switchKeyboard) } }
        bringSubviewToFront(styleMenuButton)
        bringSubviewToFront(preview)
        bringSubviewToFront(accents)
        updateModifierAppearance()
        refreshPlacementActions()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        floatingGlass.frame = bounds
        if previousWidth != bounds.width {
            if previousWidth != 0 { cancelInteraction(preservingModifiers: true) }
            previousWidth = bounds.width
            rebuildKeys()
            rebuildDrawer()
        }
        updateHostFill()
        let top = contentTop
        let (leading, trailing) = horizontalContentInsets
        let width = max(0, bounds.width - leading - trailing)
        background.frame = isFloating ? bounds : CGRect(x: 0, y: top + toolbarHeight, width: bounds.width, height: max(0, bounds.height - top - toolbarHeight))
        background.layer.maskedCorners = isFloating ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if isFloating { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 24).cgPath }
        grabber.isHidden = !isFloating
        grabber.frame = CGRect(x: (bounds.width - 88) / 2, y: bounds.height - 44, width: 88, height: 44)
        controlGlass.frame = CGRect(x: leading + 2, y: top + 2, width: max(0, width - 4), height: toolbarHeight - 4)
        controlGlass.layer.cornerRadius = min(22, (keyboardHeight.toolbarRowHeight - 4) / 2)
        layoutBackgroundEffect()
        let split = splitLayout(leading: leading, width: width)
        let wasSplit = splitActive
        splitFoldSpan = split?.fold
        if splitActive != wasSplit {
            cancelInteraction(preservingModifiers: true)
            rebuildKeysForWidth(width)
        }
        let toolbar = Model.toolbarKeys(main: configuredMain, drawers: configuredDrawers, width: toolbarWidth(width), drawerToggle: configuredDrawerToggle)
        if controls.map(\.key) != toolbar.main || toolbarDrawerKeys != toolbar.drawers {
            cancelInteraction(preservingModifiers: true)
            rebuildKeysForWidth(width)
            rebuildDrawer()
            setNeedsLayout()
        }
        toolbarColumns = splitColumns(count: controls.count, width: width)
        let controlFrames = toolbarColumns.map { columns in
            controls.indices.map { CGRect(x: 5 + CGFloat(columns.x(column: $0)), y: top + toolbarDrawerHeight,
                                          width: CGFloat(columns.unit), height: keyboardHeight.toolbarRowHeight) }
        } ?? Model.frames(keys: controls.map(\.key), width: width, y: top + toolbarDrawerHeight, height: keyboardHeight.toolbarRowHeight, inset: 5)
        for (cap, rect) in zip(controls, controlFrames) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
        if let cap = controls.first(where: { $0.key.action == .toolbar(KeyID.writingAssistance.keyValue) }) {
            writingAssistanceButton.frame = cap.frame
            writingAssistanceButton.isHidden = false
        } else { writingAssistanceButton.isHidden = true }
        for (index, row) in toolbarDrawerRows.enumerated() {
            layoutToolbarDrawer(row, buttons: toolbarDrawerButtons[index], position: index,
                                leading: leading, width: width)
        }
        var y = top + toolbarHeight
        let contentHeight = rowHeight * 4 + (suggestionsEnabled ? 36 : 0)
        // This HUD floats over the keys; it never contributes to keyboard height.
        pageIndicator.frame = CGRect(x: leading + (width - 160) / 2, y: y + (contentHeight - 64) / 2, width: 160, height: 64)
        let dotSpacing: CGFloat = 14
        func styleDot(_ dot: UIView, center: CGPoint, current: Bool) {
            let size: CGFloat = current ? 8 : 6
            dot.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = UIColor.white.withAlphaComponent(current ? 1 : 0.4)
        }
        // Heights step vertically (Full on top), so their dots stack in a column.
        pageIndicatorDots.forEach { $0.isHidden = pageIndicatorHeight != nil }
        heightIndicatorDots.forEach { $0.isHidden = pageIndicatorHeight == nil }
        if let height = pageIndicatorHeight {
            pageIndicatorTitle.frame = CGRect(x: 8, y: 21, width: 124, height: 22)
            let currentHeight = Model.Height.allCases.firstIndex(of: height) ?? 0
            let heightSpacing: CGFloat = 11
            for (index, dot) in heightIndicatorDots.enumerated() {
                let y = 32 + (CGFloat(index) - CGFloat(heightIndicatorDots.count - 1) / 2) * heightSpacing
                styleDot(dot, center: CGPoint(x: 142, y: y), current: index == currentHeight)
            }
        } else {
            pageIndicatorTitle.frame = CGRect(x: 8, y: 10, width: 144, height: 22)
            let currentPage = toolPages.firstIndex(of: toolPage) ?? 0
            for (index, dot) in pageIndicatorDots.enumerated() {
                let x = 80 + (CGFloat(index) - CGFloat(pageIndicatorDots.count - 1) / 2) * dotSpacing
                styleDot(dot, center: CGPoint(x: x, y: 45), current: index == currentPage)
            }
        }
        drawer.isHidden = isToolbarOnly || !drawerOpen || toolPage == .dictation
        presets.isHidden = isToolbarOnly || toolPage != .shortcuts
        #if canImport(FluidAudio) && !CHINA_BUILD
        if toolPage == .dictation && !isToolbarOnly {
            dictationPane.isHidden = false
            dictationPane.frame = CGRect(x: leading + 5, y: y, width: max(0, width - 10), height: max(0, contentHeight))
        } else {
            loadedDictationPane?.isHidden = true
        }
        #endif
        if drawerOpen {
            if toolPage == .shortcuts {
                // Split, the picker stays left of the fold.
                let presetWidth = splitFoldSpan.map { CGFloat($0.lowerBound - Model.splitFoldClearance) - 8 } ?? width - 16
                presets.frame = CGRect(x: leading + 8, y: y + 3, width: max(0, presetWidth), height: 30)
            }
            let presetHeight: CGFloat = toolPage == .shortcuts ? 38 : 0
            drawer.frame = CGRect(x: leading + 5, y: y + presetHeight, width: max(0, width - 10), height: max(0, contentHeight - presetHeight))
            let columns = splitColumns(count: drawerColumns, width: width)
            let cellWidth = columns.map { CGFloat($0.unit) } ?? drawer.bounds.width / CGFloat(drawerColumns)
            let rowCount = (drawerButtons.count + drawerColumns - 1) / drawerColumns
            let preferredCellHeight: CGFloat = compact ? 40 : 46
            // Fit every navigation key, including F12, without scrolling.
            let cellHeight = toolPage == .navigation
                ? min(preferredCellHeight, drawer.bounds.height / CGFloat(max(1, rowCount)))
                : preferredCellHeight
            for (i, button) in drawerButtons.enumerated() {
                let x = columns.map { CGFloat($0.x(column: i % drawerColumns)) } ?? CGFloat(i % drawerColumns) * cellWidth
                button.frame = CGRect(x: x + 2, y: CGFloat(i / drawerColumns) * cellHeight + 2,
                                      width: max(0, cellWidth - 4), height: max(0, cellHeight - 4))
            }
            drawer.contentSize = CGSize(width: drawer.bounds.width, height: CGFloat(rowCount) * cellHeight)
        }
        suggestions.isHidden = isToolbarOnly || !suggestionsEnabled || drawerOpen
        if suggestionsEnabled {
            suggestions.frame = CGRect(x: leading + 8, y: y, width: width - 16, height: 36)
            y += 36
        }
        rows.flatMap { $0 }.forEach { $0.isHidden = isToolbarOnly || drawerOpen }
        for (index, row) in rows.enumerated() {
            var inset: CGFloat = index == 1 && page == .letters ? width / 20 + 2 : 2
            if index == 3, extendsIntoBottomSafeArea, !isFloating, traitCollection.userInterfaceIdiom == .phone {
                // Keep the entire bottom row at its normal height while fitting
                // its end keys inside the rounded screen corners.
                inset = max(2, min(width / 10, deviceBottomInset - min(leading, trailing)))
            }
            let frames = split.map {
                Model.splitFrames($0.rows[index], metrics: $0.metrics, width: width, y: y, height: rowHeight,
                                  towardFold: index == 1, outerInset: index == 3 ? inset - 2 : 0)
            } ?? Model.frames(keys: row.map(\.key), width: width, y: y, height: rowHeight, inset: inset)
            for (cap, rect) in zip(row, frames) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
            y += rowHeight
        }
        if isFloating, let cap = keyboardSwitchCap {
            // Left of the handle and level with it, where Apple's globe sits.
            cap.frame = CGRect(x: 8, y: bounds.height - 42, width: 56, height: 40)
        }
        if let cap = keyboardSwitchCap, !cap.isHidden, styleOverride == nil {
            styleMenuButton.frame = cap.frame
            styleMenuButton.isHidden = false
        } else { styleMenuButton.isHidden = true }
        // Only overhang the toolbar; suggestion buttons keep their full height.
        let geometry = Model.typingGeometry(keys: rows.map { $0.map(\.key) }, frames: rows.map { $0.map(\.frame) },
            minX: leading, width: width, overhang: suggestionsEnabled ? 0 : Model.topRowOverhang,
            touchCorrection: traitCollection.userInterfaceIdiom != .pad || isFloating)
        if typingGeometry.bounds != geometry.bounds || typingGeometry.targets.map(\.frame) != geometry.targets.map(\.frame)
            || typingGeometry.targets.map(\.key) != geometry.targets.map(\.key) {
            if !contacts.isEmpty { cancelInteraction() }
            typingGeometry = geometry
        }
        if let offsets = pendingPresentationOffsets {
            drawer.contentOffset = offsets.drawerOffset
            for (index, row) in zip(toolbarDrawerIndices, toolbarDrawerRows) {
                row.contentOffset = offsets.toolbarOffsets[index] ?? .zero
            }
            pendingPresentationOffsets = nil
        }
        updateSteampunkMachinery()
        if abs(heightConstraint.constant - desiredHeight) > 0.5 {
            heightConstraint.constant = desiredHeight
            invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelInteraction(preservingModifiers: true)
            removeBackgroundEffect()
        } else {
            // Keys and drawers are already current; only the window-bound
            // effect and the host's suggestions need refreshing here.
            updateBackgroundEffect()
            updateSuggestions()
            setNeedsLayout()
        }
    }

    override var isHidden: Bool {
        didSet {
            guard oldValue != isHidden else { return }
            updateBackgroundEffect()
            #if canImport(FluidAudio) && !CHINA_BUILD
            if isHidden { loadedDictationPane?.paneWillHide() }
            #endif
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        // UIKit's own handle moves the system container and remembers the position.
        if usesSystemPlacement, !grabber.isHidden, grabber.frame.contains(point), let handle = systemFloatingHandle?() {
            return handle
        }
        // Typing bounds overhang the toolbar's bottom edge; letters win there.
        // Before the typing grid, which also covers the Apple Keyboard key.
        if !styleMenuButton.isHidden, styleMenuButton.frame.contains(point) { return styleMenuButton }
        if typingIndex(at: point) != nil { return self }
        if !writingAssistanceButton.isHidden, writingAssistanceButton.frame.contains(point) {
            return writingAssistanceButton.hitTest(convert(point, to: writingAssistanceButton), with: event)
        }
        if cap(at: point) != nil { return self }
        return super.hitTest(point, with: event)
    }
    private func typingIndex(at point: CGPoint) -> Int? {
        guard !isToolbarOnly, !drawerOpen else { return nil }
        return typingGeometry.hit(at: point)
    }
    private func cap(at point: CGPoint) -> TerminalTouchKeycap? {
        if let index = typingIndex(at: point) { return rows.flatMap { $0 }[index] }
        return controls.first { $0.frame.contains(point) }
    }
    private func feedback() {
        #if !os(visionOS)
        guard hapticsEnabled else { return }
        haptic.impactOccurred(intensity: 0.8)
        // Keep the engine warm for the next key.
        haptic.prepare()
        #endif
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        hidePageIndicator()
        guard canSendReclaimingFocus else { return }
        sequenceTask?.cancel()
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) { beginContact(touch) }
        refreshContactFeedback()
    }

    private func beginContact(_ touch: UITouch) {
        let point = touch.location(in: self)
        guard var key = cap(at: point) else { return }
        if let last = lastRelease,
           Model.isTouchBounce(down: point, at: touch.timestamp, lastUp: last.point, at: last.time) { return }
        let midWord = touch.timestamp - lastTextDown < Model.typingBurst
        if midWord, controls.contains(where: { $0 === key }), !Model.isClearlyInside(point, key.frame) { return }
        // Tablet touches remain cancellable until release so a pinch can take over.
        if traitCollection.userInterfaceIdiom != .pad {
            commitPrecedingContacts(before: nextContactOrder &+ 1)
        }
        var selection: Model.TouchSelection?
        if !isToolbarOnly, key.key.isText {
            let snapshot = host?.touchKeyboardPredictionContext
            let allowsPrediction = modifierState.rawValue & ~Model.Modifier.shift.rawValue == 0
                && !modifierState.locked.contains(.shift)
            let prior = predictionEnabled && allowsPrediction
                ? snapshot.flatMap { predictionPrior(for: $0) } : nil
            if let index = typingGeometry.predictedHit(at: point, prior: prior) {
                key = rows.flatMap { $0 }[index]
                selection = Model.TouchSelection(point: point, selected: index, modifiers: modifierState.rawValue, prior: prior)
            }
        }
        let id = ObjectIdentifier(touch)
        nextContactOrder &+= 1
        let contact = Contact(key: key, point: point, order: nextContactOrder, selection: selection)
        contact.windowOrigin = touch.location(in: window)
        contact.began = touch.timestamp
        contact.fastTyping = midWord
        if key.key.isText { lastTextDown = touch.timestamp }
        // Mid-word, Space waits longer before becoming the cursor trackpad.
        let holdDelay = key.key.action == .text(" ") && midWord ? 630 : 420
        contact.interactionMode = controls.contains(where: { $0 === key }) ? toolbarInteractionMode : .accessory
        contacts[id] = contact
        key.pressed = true
        feedback()
        if clickSoundEnabled { TerminalTouchKeyClick.shared.play(keyboardStyle.clickProfile) }
        if case .modifier(let mod) = key.key.action {
            modifierState.begin(mod)
            publishModifiers()
        } else {
            showPreview(key)
            contact.task = Task { @MainActor [weak self, weak contact, key] in
                try? await Task.sleep(for: .milliseconds(holdDelay))
                guard !Task.isCancelled, let self, let contact, self.contacts[id] === contact else { return }
                // A slide held back during the merge window still disarms the hold.
                if self.resolveDeferredMove(contact) { self.refreshContactFeedback() }
                guard !Task.isCancelled, self.canSend, !contact.consumed, contact.current === contact.initial else { return }
                switch key.key.action {
                case .key("\u{7f}"):
                    contact.consumed = true
                    while !Task.isCancelled, self.contacts[id] === contact, self.canSend {
                        self.perform(key.key)
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                case .text(" ") where !self.isToolbarOnly:
                    contact.trackpad = true
                    contact.consumed = true
                    self.preview.isHidden = true
                    key.label.text = "↔  cursor  ↕"
                    self.feedback()
                case .text(let text) where !self.isToolbarOnly:
                    if let variants = Model.accents[text] { self.showAccents(variants, contact: contact) }
                case .dismiss:
                    contact.consumed = true
                    self.cancelInteraction()
                    self.onPinHidden?()
                default: break
                }
            }
        }
    }

    /// Types the lifted key at its last position, then presses the landing one.
    private func rollOver(_ contact: Contact, touch: UITouch) {
        contacts.removeValue(forKey: ObjectIdentifier(touch))
        contact.task?.cancel()
        contact.current?.pressed = false
        contact.initial.pressed = false
        // Held-back movement was part of the merge, never a slide: keep the original key.
        contact.deferredPoint = nil
        if canSend {
            commitPrecedingContacts(before: contact.order)
            commit(contact)
        }
        beginContact(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let contact = contacts[ObjectIdentifier(touch)] else { continue }
            guard validateToolbarContact(contact, touch: touch) else { continue }
            let point = touch.location(in: self)
            if contact.selection != nil, !contact.trackpad, !contact.accent,
               touchJumped(touch, with: event, in: self) || (contact.fastTyping && typingGeometry.splitsMergedDrift(
                   from: contact.origin, to: point, elapsed: touch.timestamp - contact.began,
                   selected: contact.selection?.selected)) {
                rollOver(contact, touch: touch)
                continue
            }
            if contact.selection != nil && contact.consumed && !contact.accent && !contact.trackpad { continue }
            if contact.accent {
                accentIndex = min(accentChoices.count - 1, max(0, Int((point.x - accents.frame.minX) / (accents.bounds.width / CGFloat(accentChoices.count)))))
                updateAccentSelection()
                continue
            }
            if contact.trackpad {
                let dx = point.x - contact.anchor.x, dy = point.y - contact.anchor.y
                if abs(dx) >= 12 || abs(dy) >= 18 {
                    let horizontal = abs(dx) >= abs(dy)
                    keyPressed(horizontal ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A"), modifiers: [])
                    contact.anchor = point
                }
                continue
            }
            if contact.initial.key.action == .joystick {
                let direction = Model.joystickArrow(dx: point.x - contact.origin.x, dy: point.y - contact.origin.y)
                if direction != contact.direction {
                    contact.task?.cancel()
                    contact.direction = direction
                    if let direction {
                        contact.consumed = true
                        contact.task = startJoystickArrow(direction) { [weak contact] in contact?.direction == direction }
                    }
                }
                continue
            }
            if case .modifier = contact.initial.key.action { continue }
            if contact.selection != nil {
                // With another finger down, sliding onto an action key finishes the letter.
                if contacts.count > 1, typingGeometry.bounds.contains(point), typingGeometry.textHit(at: point) == nil {
                    commitPrecedingContacts(before: contact.order)
                    commit(contact)
                } else if contact.fastTyping, touch.timestamp - contact.began <= Model.mergeWindow {
                    // Hold the original key while the movement may still be two merged taps.
                    contact.deferredPoint = point
                } else {
                    contact.deferredPoint = nil
                    move(contact, to: point)
                }
                continue
            }
            let next = cap(at: point)
            // Sliding adjusts the typed key, never activates a nearby action or modifier.
            let compatible: TerminalTouchKeycap? = {
                if next === contact.initial { return next }
                if case .text = contact.initial.key.action, let next, case .text = next.key.action { return next }
                return nil
            }()
            if compatible !== contact.current {
                contact.task?.cancel()
                contact.current?.pressed = false
                contact.current = compatible
                compatible?.pressed = true
                if let compatible { showPreview(compatible) } else { preview.isHidden = true }
            }
        }
        refreshContactFeedback()
    }

    /// Sends `direction` now, then repeats it while `holds` stays true.
    private func startJoystickArrow(_ direction: String, holds: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        keyPressed(direction, modifiers: [])
        return Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            while !Task.isCancelled, let self, holds(), self.canSend {
                self.keyPressed(direction, modifiers: [])
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }

    /// Drawer-row joysticks are buttons in a scrolling row, so they drag with a pan.
    @objc private func dragDrawerJoystick(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        let tracking = pan.state == .began || pan.state == .changed
        let direction = tracking ? Model.joystickArrow(dx: translation.x, dy: translation.y) : nil
        guard direction != drawerJoystickDirection else { return }
        drawerJoystickTask?.cancel()
        drawerJoystickDirection = direction
        guard let direction, canSend else { return }
        drawerJoystickTask = startJoystickArrow(direction) { [weak self] in self?.drawerJoystickDirection == direction }
    }

    private func move(_ contact: Contact, to point: CGPoint) {
        guard contact.selection?.move(to: point, in: typingGeometry,
                                      dockedPad: traitCollection.userInterfaceIdiom == .pad && !isFloating) == true else { return }
        contact.task?.cancel()
        contact.current = contact.selection?.selected.map { rows.flatMap { $0 }[$0] }
    }

    /// Applies held-back movement once the merge window has passed.
    @discardableResult
    private func resolveDeferredMove(_ contact: Contact) -> Bool {
        guard let point = contact.deferredPoint,
              ProcessInfo.processInfo.systemUptime - contact.began > Model.mergeWindow else { return false }
        contact.deferredPoint = nil
        move(contact, to: point)
        return true
    }

    private func commit(_ contact: Contact, at point: CGPoint? = nil) {
        guard !contact.consumed else { return }
        resolveDeferredMove(contact)
        let index: Int?
        if let point = point ?? contact.selection?.latestPoint {
            index = contact.selection?.finish(at: point, in: typingGeometry,
                dockedPad: traitCollection.userInterfaceIdiom == .pad && !isFloating)
        } else {
            index = contact.selection?.takeSelection()
        }
        contact.consumed = true
        contact.task?.cancel()
        guard let index else { return }
        perform(typingGeometry.targets[index].key, modifiers: KeyModifiers(rawValue: contact.selection!.modifiers))
    }

    private func commitPrecedingContacts(before order: UInt64) {
        for contact in contacts.values.sorted(by: { $0.order < $1.order })
            where contact.order < order && !contact.consumed && !contact.trackpad
                && !contact.accent && contact.selection != nil {
            commit(contact)
        }
    }

    private func refreshContactFeedback() {
        let active = contacts.values.sorted { $0.order < $1.order }
        var pressed = Set<ObjectIdentifier>()
        for contact in active where contact.selection == nil || !contact.consumed || contact.trackpad || contact.accent {
            if let cap = contact.current { pressed.insert(ObjectIdentifier(cap)) }
            if contact.trackpad { contact.initial.label.text = "↔  cursor  ↕" }
        }
        for cap in controls + rows.flatMap({ $0 }) {
            let value = pressed.contains(ObjectIdentifier(cap))
            if cap.pressed != value { cap.pressed = value }
        }
        preview.isHidden = true
        if !active.contains(where: { $0.accent || $0.trackpad }),
           let contact = active.last(where: { !$0.consumed && $0.current != nil }), let cap = contact.current {
            showPreview(cap, modifiers: contact.selection?.modifiers)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        // Resolve letters before released modifiers when UIKit batches the chord.
        let ordered = touches.sorted {
            let a = contacts[ObjectIdentifier($0)]?.initial.key.action
            let b = contacts[ObjectIdentifier($1)]?.initial.key.action
            if case .modifier = a { return false }
            if case .modifier = b { return true }
            return (contacts[ObjectIdentifier($0)]?.order ?? 0) < (contacts[ObjectIdentifier($1)]?.order ?? 0)
        }
        for touch in ordered {
            if !cancelled, canSend, let contact = contacts[ObjectIdentifier(touch)] {
                commitPrecedingContacts(before: contact.order)
            }
            if let contact = contacts[ObjectIdentifier(touch)], !validateToolbarContact(contact, touch: touch) { continue }
            guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            if !cancelled { lastRelease = (touch.location(in: self), touch.timestamp) }
            contact.task?.cancel()
            contact.current?.pressed = false
            contact.initial.pressed = false
            if case .modifier(let mod) = contact.initial.key.action {
                modifierState.end(mod, at: touch.timestamp, cancelled: cancelled || !releases(contact.initial, at: touch.location(in: self)))
                publishModifiers()
            } else if !cancelled, canSend {
                if contact.accent, accents.frame.insetBy(dx: -20, dy: -70).contains(touch.location(in: self)) {
                    perform(Model.Key(title: accentChoices[accentIndex], action: .text(accentChoices[accentIndex])),
                            modifiers: contact.selection.map { KeyModifiers(rawValue: $0.modifiers) })
                } else if !contact.consumed, contact.selection != nil {
                    commit(contact, at: touch.location(in: self))
                } else if !contact.consumed, let current = contact.current, releases(current, at: touch.location(in: self)) {
                    perform(current.key)
                }
            }
        }
        accents.isHidden = !contacts.values.contains { $0.accent }
        updateModifierAppearance()
        refreshContactFeedback()
    }

    /// Hit frames are shifted from the visible caps, so accept either.
    private func releases(_ key: TerminalTouchKeycap, at point: CGPoint) -> Bool {
        key.frame.contains(point) || cap(at: point) === key
    }

    private func validateToolbarContact(_ contact: Contact, touch: UITouch) -> Bool {
        let point = touch.location(in: window)
        // Joystick drags are intentional; other spaced-bottom controls are taps.
        let valid = canSend && (contact.interactionMode != .spacedBottom || contact.initial.key.action == .joystick
            || (hypot(point.x - contact.windowOrigin.x, point.y - contact.windowOrigin.y) <= 10
                && contact.initial.frame.contains(touch.location(in: self))))
        guard valid else {
            contacts.removeValue(forKey: ObjectIdentifier(touch))
            contact.task?.cancel()
            contact.current?.pressed = false
            contact.initial.pressed = false
            if case .modifier(let modifier) = contact.initial.key.action {
                modifierState.end(modifier, at: touch.timestamp, cancelled: true)
                publishModifiers()
            }
            return false
        }
        return true
    }

    func cancelInteraction(preservingModifiers: Bool = false, preservingSuggestions: Bool = false) {
        hidePageIndicator()
        contacts.values.forEach { $0.task?.cancel(); $0.initial.pressed = false; $0.current?.pressed = false }
        contacts.removeAll()
        allKeycaps.forEach { $0.finishVisualTransition() }
        (drawerButtons + toolbarDrawerButtons.flatMap { $0 }).forEach { $0.cancelInteraction() }
        writingAssistanceButton.cancelInteraction()
        styleMenuButton.cancelTracking(with: nil)
        keyboardSwitchCap?.pressed = false
        steampunkMachinery?.resetContactFeedback()
        retroBackdrop?.resetContactFeedback()
        sequenceTask?.cancel(); sequenceTask = nil
        drawerJoystickTask?.cancel(); drawerJoystickTask = nil; drawerJoystickDirection = nil
        if !preservingSuggestions {
            suggestionTask?.cancel(); suggestionTask = nil
            lastSuggestionContext = nil
            suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        predictionTask?.cancel(); predictionTask = nil; pendingPrediction = nil
        if preservingModifiers { modifierState.cancelHeld() } else { modifierState.reset() }
        publishModifiers()
        preview.isHidden = true
        accents.isHidden = true
    }

    func clearOneShotModifiers() {
        modifierState.consume()
        publishModifiers()
    }

    private func publishModifiers() {
        onModifiersChanged?(KeyModifiers(rawValue: modifierState.rawValue))
        updateModifierAppearance()
    }
    private var dismissSymbol: String {
        KeyboardToolbarView.dismissSymbolName(pinned: pinnedHidden, showsRestore: showsRestore)
    }
    private var dismissAccessibilityLabel: String {
        showsRestore ? String(localized: "Show Keyboard") : String(localized: "Hide Keyboard")
    }

    private func updateModifierAppearance() {
        for cap in controls + rows.flatMap({ $0 }) + toolbarDrawerButtons.flatMap({ $0 }).map(\.keycap) {
            if cap.key.action == .drawer { cap.selected = toolbarDrawerState != .closed }
            switch cap.key.action {
            case .key("\u{1b}"): cap.setSymbol(glyphsEnabled ? "escape" : nil)
            case .key("\t"): cap.setSymbol(glyphsEnabled ? "arrow.right.to.line" : nil)
            case .modifier(.control): cap.setSymbol(glyphsEnabled ? "control" : nil)
            case .modifier(.alt): cap.setSymbol(glyphsEnabled ? "option" : nil)
            case .modifier(.command): cap.setSymbol(glyphsEnabled ? "command" : nil)
            case .dismiss:
                cap.setSymbol(dismissSymbol)
                cap.accessibilityLabel = dismissAccessibilityLabel
                cap.accessibilityValue = pinnedHidden ? String(localized: "Pinned") : nil
            default: break
            }
            if case .modifier(let mod) = cap.key.action {
                cap.selected = modifierState.isActive(mod)
                cap.locked = modifierState.locked.contains(mod)
                cap.accessibilityValue = modifierState.locked.contains(mod) ? "Locked" : (cap.selected ? "On" : "Off")
                if mod == .shift {
                    cap.setSymbol(glyphsEnabled ? (modifierState.locked.contains(mod) ? "capslock.fill" : (cap.selected ? "shift.fill" : "shift")) : nil)
                }
            } else if case .text(let text) = cap.key.action {
                cap.updateColor()
                cap.setLegend(text == " " ? "space" : (modifierState.isActive(.shift) ? text.uppercased() : text))
            }
        }
        for button in toolbarDrawerButtons.flatMap({ $0 }) {
            button.refreshAppearance()
        }
    }

    private func perform(_ key: Model.Key, modifiers: KeyModifiers? = nil) {
        guard canSend else { return }
        switch key.action {
        case .text(let text):
            let mods = modifiers ?? KeyModifiers(rawValue: modifierState.rawValue)
            if mods.subtracting(.shift).isEmpty {
                // Shift changes letters without invoking terminal shortcut encoding.
                host?.touchKeyboardInsert(mods.contains(.shift) ? text.uppercased() : text)
            } else { host?.touchKeyboardSend(text, modifiers: mods) }
            modifierState.consume(mods.rawValue); publishModifiers(); updateSuggestions(); updatePrediction()
        case .key(let value): keyPressed(value, modifiers: [])
        case .page:
            cancelInteraction()
            if key.title == "#+=" { page = .symbols }
            else if key.title == "123" { page = .numbers }
            else { page = .letters }
            rebuildKeys()
        case .switchKeyboard: cancelInteraction(); onSwitchKeyboard?()
        case .drawer:
            toggleToolbarDrawer()
        case .dismiss: cancelInteraction(); onDismiss?()
        case .compose: cancelInteraction(); onCompose?()
        case .paste: cancelInteraction(); onPaste?()
        case .tabs: cancelInteraction(preservingModifiers: true); onTabs?()
        case .toolbar(let action):
            guard action != KeyID.writingAssistance.keyValue else { return }
            cancelInteraction()
            if action == KeyID.dictation.keyValue { beginDictationFromToolbar(); return }
            onToolbarAction?(action)
        case .custom(let id):
            guard let custom = KeyboardToolbarManager.shared.customKey(for: id) else { return }
            if let character = custom.plainCharacter {
                perform(Model.Key(title: String(character), action: .text(String(character))))
            } else if let input = custom.plainSpecialKeyInput, modifierState.rawValue != 0 {
                keyPressed(input, modifiers: [])
            } else { sendCustomSequence(custom.sequence) }
        case .joystick:
            if isToolbarOnly { toggleToolbarDrawer() } else { showPage(.navigation) }
        case .modifier: break
        }
    }

    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        guard canSend else { return }
        host?.touchKeyboardSend(key, modifiers: modifiers.union(KeyModifiers(rawValue: modifierState.rawValue)))
        modifierState.consume(); publishModifiers(); updateSuggestions()
        updatePrediction()
    }
    func sendRawData(_ data: Data) { guard canSend else { return }; sequenceDelegate?.sendRawData(data) }
    func sendKeyCombo(_ combo: SequenceStep.KeyCombo) -> Bool {
        guard canSend else { return true }
        return sequenceDelegate?.sendKeyCombo(combo) ?? false
    }

    private func showPreview(_ cap: TerminalTouchKeycap, modifiers: Int? = nil) {
        // Show above-finger feedback in both full-size and detached layouts.
        let showsPreview = traitCollection.userInterfaceIdiom == .phone
            || traitCollection.userInterfaceIdiom == .pad
        guard !isToolbarOnly, showsPreview, characterPreviewEnabled, case .text(let text) = cap.key.action, text != " ", !UIAccessibility.isVoiceOverRunning else { return }
        let shifted = (modifiers ?? modifierState.rawValue) & Model.Modifier.shift.rawValue != 0
        preview.text = shifted ? text.uppercased() : text
        preview.frame = CGRect(x: min(max(2, cap.frame.midX - 26), bounds.width - 54), y: max(0, cap.frame.minY - 49), width: 52, height: 55)
        preview.isHidden = false
        bringSubviewToFront(preview)
    }
    private func showAccents(_ variants: String, contact: Contact) {
        contact.accent = true; contact.consumed = true
        preview.isHidden = true
        let shifted = (contact.selection?.modifiers ?? modifierState.rawValue) & Model.Modifier.shift.rawValue != 0
        accentChoices = variants.map { shifted ? String($0).uppercased() : String($0) }
        accents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for value in accentChoices {
            let label = UILabel(); label.text = value; label.textAlignment = .center
            label.font = .systemFont(ofSize: 24 * TerminalTouchLegend.scale(value), weight: TerminalTouchLegend.weight(.regular, for: value))
            accents.addArrangedSubview(label)
        }
        let width = min(bounds.width - 8, CGFloat(accentChoices.count) * 38)
        accents.frame = CGRect(x: min(max(4, contact.initial.frame.midX - width / 2), bounds.width - width - 4),
                              y: max(0, contact.initial.frame.minY - 49), width: width, height: 48)
        accentIndex = min(accentChoices.count - 1, max(0, Int((contact.origin.x - accents.frame.minX) / (width / CGFloat(accentChoices.count)))))
        updateAccentSelection()
        accents.isHidden = false
        bringSubviewToFront(accents)
        feedback()
    }
    private func updateAccentSelection() {
        for (index, view) in accents.arrangedSubviews.enumerated() {
            view.backgroundColor = index == accentIndex ? .tertiarySystemFill : .clear
        }
    }

    private func showPage(_ page: Model.ToolPage) {
        guard !isToolbarOnly, page != toolPage else { return }
        cancelInteraction(preservingModifiers: true)
        #if canImport(FluidAudio) && !CHINA_BUILD
        if toolPage == .dictation { loadedDictationPane?.paneWillHide() }
        #endif
        toolPage = page
        drawer.contentOffset = .zero
        rebuildDrawer()
        updateSuggestions()
        showPageIndicator()
        UIAccessibility.post(notification: .pageScrolled, argument: page.title)
        onPageChanged?(page)
    }

    private func showPageIndicator(height: Model.Height? = nil) {
        pageIndicatorHideTask?.cancel()
        pageIndicatorHeight = height
        pageIndicatorTitle.text = height?.displayName ?? toolPage.title
        bringSubviewToFront(pageIndicator)
        setNeedsLayout()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.pageIndicator.alpha = 1
        }
        // Match the hidden-tab-bar indicator's 1.5-second display and fade.
        pageIndicatorHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pageIndicator.alpha = 0
            }
        }
    }

    private func hidePageIndicator() {
        pageIndicatorHideTask?.cancel()
        pageIndicatorHideTask = nil
        pageIndicator.layer.removeAllAnimations()
        pageIndicator.alpha = 0
    }

    @objc private func swipePage(_ gesture: TerminalKeyboardPageSwipe) {
        if gesture.heightOffset != 0 {
            let height = heightSetting.stepped(by: gesture.heightOffset)
            guard height != heightSetting else { return }
            // settingsDidChange drives the relayout through refreshSettings.
            if DuoHingeEvents.isFrontDisplay {
                SettingsStore.shared.set(Settings.Keyboard.touchHeightDuoFront, height)
            } else {
                SettingsStore.shared.set(Settings.Keyboard.touchHeight, height)
            }
            showPageIndicator(height: height)
            return
        }
        showPage(toolPage.moved(by: gesture.offset, in: toolPages))
    }

    private func rebuildPageIndicatorDots() {
        pageIndicatorDots.forEach { $0.removeFromSuperview() }
        pageIndicatorDots = toolPages.map { _ in UIView() }
        pageIndicatorDots.forEach { pageIndicator.contentView.addSubview($0) }
        setNeedsLayout()
    }

    private func configureDictationPane() {
        #if canImport(FluidAudio) && !CHINA_BUILD
        let pane = dictationPane
        pane.target = host as? DictationTarget
        pane.agentHint = preset == .agent
        pane.configure(style: keyboardStyle, palette: keycapPalette, ink: palette?.toolbarInk ?? .label)
        bringSubviewToFront(pageIndicator)
        #endif
    }

    /// Opens the Dictation page and starts listening, or stops if already
    /// listening there. False when only the toolbar is showing.
    @discardableResult
    func beginDictation() -> Bool {
        #if canImport(FluidAudio) && !CHINA_BUILD
        guard dictationEnabled, !isToolbarOnly else { return false }
        if toolPage == .dictation, DictationController.shared.isActive {
            DictationController.shared.stop()
            return true
        }
        showPage(.dictation)
        dictationPane.startListening()
        return true
        #else
        return false
        #endif
    }

    /// The toolbar mic key; toolbar-only mode falls back to the HUD.
    private func beginDictationFromToolbar() {
        guard !beginDictation() else { return }
        NotificationCenter.default.post(name: .toggleDictation, object: host)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !isToolbarOnly else { return false }
        guard let swipe = gestureRecognizer as? TerminalKeyboardPageSwipe else { return true }
        // Floating always uses the compact height, and tool pages scroll vertically.
        swipe.allowsVertical = !isFloating && toolPage == .typing
        let point = touch.location(in: self)
        // Toolbar joysticks, presets, and the floating handle
        // keep their own gestures. Only the key surface changes pages.
        guard point.y >= contentTop + toolbarHeight, point.y < bounds.height - bottomInset,
              touch.view !== presets, touch.view?.isDescendant(of: presets) != true else { return false }
        #if canImport(FluidAudio) && !CHINA_BUILD
        // A held mic is push-to-talk; sliding off it must not change pages.
        if let pane = loadedDictationPane, !pane.isHidden, touch.view is UIControl,
           touch.view?.isDescendant(of: pane) == true { return false }
        #endif
        // A stroke that starts mid-word is typing, never a page change.
        guard touch.timestamp - lastTextDown >= Model.typingBurst else { return false }
        return !contacts.values.contains { $0.trackpad || $0.accent || $0.consumed }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let other: UIGestureRecognizer
        if gestureRecognizer === placementPinch {
            other = otherGestureRecognizer
        } else if otherGestureRecognizer === placementPinch {
            other = gestureRecognizer
        } else {
            return false
        }
        // Adding a second finger while scrolling a tools page must still allow
        // the app-contained keyboard's placement pinch.
        if other === drawer.panGestureRecognizer || other is TerminalKeyboardPageSwipe { return true }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is TerminalKeyboardPageSwipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        // A held Space or accent selection owns the contact even if its drag
        // later travels far enough to look like a page swipe.
        return !contacts.values.contains { $0.trackpad || $0.accent || $0.consumed }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !isToolbarOnly, direction == .left || direction == .right else { return super.accessibilityScroll(direction) }
        showPage(toolPage.moved(by: direction == .left ? 1 : -1, in: toolPages))
        return true
    }
    @objc private func changePreset() {
        guard Model.Preset.allCases.indices.contains(presets.selectedSegmentIndex) else { return }
        preset = Model.Preset.allCases[presets.selectedSegmentIndex]
        #if canImport(FluidAudio) && !CHINA_BUILD
        loadedDictationPane?.agentHint = preset == .agent
        #endif
        drawer.contentOffset = .zero
        rebuildDrawer()
    }
    @discardableResult
    private func drawerButton(_ title: String, subtitle: String? = nil, repeats: Bool = false,
                              key: Model.Key? = nil, in container: UIView? = nil,
                              action: @escaping () -> Void) -> TerminalTouchDrawerButton {
        let button = keyboardStyle.makeDrawerButton(
            key: key ?? Model.Key(title: title, action: toolPage == .symbols ? .text(title) : .key(title)),
            subtitle: subtitle, toolbar: container != nil, palette: keycapPalette)
        button.accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        button.addAction(UIAction { [weak self] _ in self?.feedback() }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in guard self?.canSendReclaimingFocus == true else { return }; action() }, for: .touchUpInside)
        if repeats { button.enableRepeat { [weak self] in guard self?.canSend == true else { return }; action() } }
        (container ?? drawer).addSubview(button)
        if container == nil { drawerButtons.append(button) }
        return button
    }
    private func refreshWritingAssistance() {
        let enabled = [
            (SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction), String(localized: "Letter Prediction")),
            (SettingsStore.shared.value(Settings.Keyboard.touchSuggestions), String(localized: "Suggestions")),
            (SettingsStore.shared.value(Settings.Keyboard.doubleSpaceForPeriod), String(localized: "Double-Space Period Shortcut"))
        ].filter { $0.0 }.map { $0.1 }
        writingAssistanceButton.accessibilityValue = enabled.isEmpty ? String(localized: "Off") : enabled.joined(separator: ", ")
        writingAssistanceButton.menu = writingAssistanceMenu()
    }

    private var keyboardSwitchCap: TerminalTouchKeycap? {
        rows.last?.first { $0.key.action == .switchKeyboard }
    }

    private func pressKeyboardSwitch(_ pressed: Bool) {
        keyboardSwitchCap?.pressed = pressed
        guard pressed else { return }
        feedback()
        if clickSoundEnabled { TerminalTouchKeyClick.shared.play(keyboardStyle.clickProfile) }
    }

    private func keyboardStyleMenuItems() -> [UIMenuElement] {
        let current = keyboardStyle
        let styles: [UIMenuElement] = Model.Style.allCases.map { style in
            UIAction(title: style.displayName, state: style == current ? .on : .off) { _ in
                guard SettingsStore.shared.value(Settings.Keyboard.touchStyle) != style else { return }
                SettingsStore.shared.set(Settings.Keyboard.touchStyle, style)
            }
        }
        // UIKit places the system container; only the in-app card can be requested.
        // The Duo's laptop pose keeps it docked below the fold.
        guard !isToolbarOnly, !usesSystemPlacement, !isEmbeddedPreview, !fillsHostHeight,
              onPlacementRequested != nil else { return styles }
        let placements = [(Model.Placement.docked, String(localized: "Docked")),
                          (Model.Placement.floating, String(localized: "Detached"))].map { placement, title in
            UIAction(title: title, state: (placement == .floating) == isFloating ? .on : .off) { [weak self] _ in
                guard let self, (placement == .floating) != self.isFloating else { return }
                self.cancelInteraction()
                // Move containers after the menu has finished dismissing.
                DispatchQueue.main.async { [weak self] in self?.onPlacementRequested?(placement) }
            }
        }
        return styles + [UIMenu(options: .displayInline, children: placements)]
    }

    private func writingAssistanceMenu() -> UIMenu {
        func toggle(_ setting: SettingKey<Bool>, title: String, icon: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: icon),
                     state: SettingsStore.shared.value(setting) ? .on : .off) { _ in
                let store = SettingsStore.shared
                store.set(setting, !store.value(setting))
            }
        }
        return UIMenu(children: [
            toggle(Settings.Keyboard.touchLetterPrediction, title: String(localized: "Letter Prediction"), icon: "textformat.abc"),
            toggle(Settings.Keyboard.touchSuggestions, title: String(localized: "Suggestions"), icon: "text.bubble"),
            toggle(Settings.Keyboard.doubleSpaceForPeriod, title: String(localized: "Double-Space Period Shortcut"), icon: "character.cursor.ibeam")
        ])
    }

    private func rebuildDrawer() {
        refreshWritingAssistance()
        drawerButtons.forEach { $0.cancelRepeat(); $0.removeFromSuperview() }; drawerButtons.removeAll()
        drawerColumns = toolPage == .symbols ? 8 : 4
        switch toolPage {
        case .typing: break
        case .dictation: configureDictationPane()
        case .symbols:
            for char in "`~^_\\|[]{}<>/=-\"';:()@$%&*+?!#" {
                let text = String(char)
                drawerButton(text) { [weak self] in self?.perform(Model.Key(title: text, action: .text(text))) }
            }
        case .navigation:
            let keys = [("←", "\u{1b}[D"), ("↓", "\u{1b}[B"), ("↑", "\u{1b}[A"), ("→", "\u{1b}[C"),
                        ("Home", "\u{1b}[H"), ("End", "\u{1b}[F"), ("PgUp", "\u{1b}[5~"), ("PgDn", "\u{1b}[6~"), ("Delete", "\u{1b}[3~")]
            for (title, key) in keys { drawerButton(title, repeats: true) { [weak self] in self?.keyPressed(key, modifiers: []) } }
            for index in 1...12 { drawerButton("F\(index)") { [weak self] in self?.keyPressed("F\(index)", modifiers: []) } }
        case .shortcuts:
            for shortcut in preset.shortcuts {
                drawerButton(shortcut.title, subtitle: shortcut.chord) { [weak self] in
                    self?.keyPressed(shortcut.key, modifiers: KeyModifiers(rawValue: shortcut.modifiers))
                }
            }
            if preset == .agent {
                drawerButton("Compose") { [weak self] in self?.perform(Model.Key(title: "Compose", action: .compose)) }
                drawerButton("Paste") { [weak self] in self?.perform(Model.Key(title: "Paste", action: .paste)) }
            }
            for command in preset.slashCommands {
                drawerButton(command) { [weak self] in
                    guard let self else { return }
                    // Commands stay literal even with Shift or Control latched.
                    self.modifierState.consume()
                    self.perform(Model.Key(title: command, action: .text(command)), modifiers: [])
                }
            }
        }
        updateModifierAppearance()
        setNeedsLayout()
    }

    private func layoutToolbarDrawer(_ row: UIScrollView, buttons: [TerminalTouchDrawerButton],
                                     position: Int, leading: CGFloat, width: CGFloat) {
        let rowHeight = keyboardHeight.toolbarDrawerRowHeight
        row.frame = CGRect(x: leading + 5, y: contentTop + CGFloat(position) * rowHeight, width: max(0, width - 10), height: rowHeight)
        // Snap to the main toolbar row's columns so drawer keys sit under its keys,
        // whether or not the row scrolls. Long titles span whole columns.
        let unit = toolbarColumns.map { CGFloat($0.unit) }
            ?? max(1, row.bounds.width / max(1, controls.reduce(0) { $0 + $1.key.weight }))
        let widths = buttons.map { button -> CGFloat in
            let title = button.keycap.icon.image == nil ? button.keycap.key.title : ""
            let titleWidth = title.count <= 4 ? 0 : (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium)]).width + 20
            return unit * max(1, (min(120, titleWidth) / unit).rounded(.up))
        }
        // Split, keys continue past the fold's block, as the main row does.
        let origins = toolbarColumns?.positions(widths: widths.map { Double($0) }).map { CGFloat($0) }
            ?? widths.indices.map { widths[..<$0].reduce(0, +) }
        for (button, (x, width)) in zip(buttons, zip(origins, widths)) {
            button.frame = CGRect(x: x, y: 2, width: width, height: rowHeight - 4)
        }
        row.contentSize = CGSize(width: zip(origins, widths).map { $0 + $1 }.max() ?? 0, height: rowHeight)
    }

    private func toggleToolbarDrawer() {
        cancelInteraction(preservingModifiers: true, preservingSuggestions: true)
        // UIKit sizes a self-sizing input's hosting item when the keyboard window lays out.
        let layoutRoot: UIView = window ?? superview ?? self
        layoutRoot.layoutIfNeeded()
        layoutIfNeeded()
        let oldRows = toolbarDrawerRows
        let oldHeight = toolbarDrawerHeight
        toolbarDrawerState = toolbarDrawerState.toggled(rowCount: toolbarDrawerKeys.count,
            cycle: KeyboardToolbarManager.shared.drawerToggleMode == .cycle)
        let outgoing = rebuildToolbarDrawers(preservingRows: true)
        let incoming = toolbarDrawerRows.filter { !oldRows.contains($0) }
        // UIKit resizes the system container inside an animation block, but the card
        // mask cannot follow it, so its backdrop would show through for a moment.
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled && !(isFloating && usesSystemPlacement)

        // Lay out new keys before fading them in. Existing rows retain their
        // frames and horizontal scroll offsets until the animation starts.
        let (leading, trailing) = horizontalContentInsets
        for (index, row) in toolbarDrawerRows.enumerated() where incoming.contains(row) {
            layoutToolbarDrawer(row, buttons: toolbarDrawerButtons[index], position: index,
                                leading: leading, width: max(0, bounds.width - leading - trailing))
            row.alpha = animated ? 0 : 1
        }
        for row in outgoing {
            row.isUserInteractionEnabled = false
            row.accessibilityElementsHidden = true
        }
        updateModifierAppearance()
        let heightDelta = toolbarDrawerHeight - oldHeight
        let changes = {
            // Publish synchronously so UIKit's self-sizing input root and the
            // content move in the same animation, without reloadInputViews().
            self.heightConstraint.constant = self.desiredHeight
            self.invalidateIntrinsicContentSize()
            if heightDelta != 0 { self.onHeightChanged?() }
            self.setNeedsLayout()
            layoutRoot.layoutIfNeeded()
            self.layoutIfNeeded()
            incoming.forEach { $0.alpha = 1 }
            outgoing.forEach {
                $0.alpha = 0
                $0.transform = CGAffineTransform(translationX: 0, y: heightDelta)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: changes) { _ in
                outgoing.forEach { $0.removeFromSuperview() }
            }
        } else {
            UIView.performWithoutAnimation(changes)
            outgoing.forEach { $0.removeFromSuperview() }
        }
    }

    /// Reuse rows during a toggle; configuration and appearance changes rebuild
    /// them. The caller keeps outgoing rows alive only for their exit animation.
    @discardableResult
    private func rebuildToolbarDrawers(preservingRows: Bool = false) -> [UIScrollView] {
        toolbarDrawerButtons.flatMap { $0 }.forEach { $0.cancelRepeat() }
        let previousRows = Dictionary(uniqueKeysWithValues: zip(toolbarDrawerIndices, zip(toolbarDrawerRows, toolbarDrawerButtons)))
        toolbarDrawerState = toolbarDrawerState.clamped(rowCount: toolbarDrawerKeys.count)
        let indices = toolbarDrawerState.visibleRows(rowCount: toolbarDrawerKeys.count)
        let outgoing = toolbarDrawerIndices.compactMap { index -> UIScrollView? in
            preservingRows && indices.contains(index) ? nil : previousRows[index]?.0
        }
        if !preservingRows { outgoing.forEach { $0.removeFromSuperview() } }
        toolbarDrawerRows.removeAll()
        toolbarDrawerButtons.removeAll()
        toolbarDrawerIndices = indices
        for index in indices {
            if preservingRows, let (row, buttons) = previousRows[index] {
                toolbarDrawerRows.append(row)
                toolbarDrawerButtons.append(buttons)
                continue
            }
            let row = UIScrollView()
            row.contentOffset = previousRows[index]?.0.contentOffset ?? .zero
            row.showsHorizontalScrollIndicator = false
            row.alwaysBounceHorizontal = false
            addSubview(row)
            toolbarDrawerRows.append(row)
            var buttons: [TerminalTouchDrawerButton] = []
            for key in toolbarDrawerKeys[index] {
                let repeats: Bool = { if case .key = key.action { return true }; return false }()
                let button = drawerButton(key.title, repeats: repeats, key: key, in: row) { [weak self] in
                    guard let self else { return }
                    if case .modifier(let modifier) = key.action {
                        self.modifierState.begin(modifier)
                        self.modifierState.end(modifier, at: ProcessInfo.processInfo.systemUptime)
                        self.publishModifiers()
                    } else { self.perform(key) }
                }
                button.interactionMode = toolbarInteractionMode
                if key.action == .joystick {
                    // Overflow puts the joystick here in narrow cards; its drags must not scroll the row.
                    let drag = UIPanGestureRecognizer(target: self, action: #selector(dragDrawerJoystick(_:)))
                    button.addGestureRecognizer(drag)
                    row.panGestureRecognizer.require(toFail: drag)
                }
                button.accessibilityLabel = key.accessibility ?? key.title
                if key.action == .toolbar(KeyID.writingAssistance.keyValue) {
                    button.showsMenuAsPrimaryAction = true
                    button.menu = writingAssistanceMenu()
                }
                buttons.append(button)
            }
            toolbarDrawerButtons.append(buttons)
        }
        setNeedsLayout()
        return outgoing
    }

    private func sendCustomSequence(_ steps: [SequenceStep]) {
        modifierState.consume()
        cancelInteraction(preservingModifiers: true)
        host?.touchKeyboardInvalidateSuggestions()
        // Ghostty-encoded keys arrive asynchronously and would reorder against
        // raw steps, so only a lone combo takes that path.
        if steps.count == 1, case .keyCombo(let combo) = steps[0], canSend,
           sequenceDelegate?.sendKeyCombo(combo) == true { return }
        sequenceTask = Task { @MainActor [weak self] in
            for step in steps {
                guard !Task.isCancelled, let self, self.canSend else { return }
                let data = step.terminalData()
                self.sequenceDelegate?.sendRawData(data)
                if data.last == 0x1b { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
    }

    func updateSuggestions() {
        guard !isToolbarOnly, suggestionsEnabled, canSend, let context = host?.touchKeyboardSuggestionContext else {
            suggestionTask?.cancel(); lastSuggestionContext = nil
            suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard lastSuggestionContext != context else { return }
        lastSuggestionContext = context
        suggestionTask?.cancel()
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.canSend, self.host?.touchKeyboardSuggestionContext == context else { return }
            let language = UITextChecker.availableLanguages.first { $0.hasPrefix("en") } ?? "en_US"
            let wordRange = NSRange(location: 0, length: context.word.utf16.count)
            let completions = self.checker.completions(forPartialWordRange: wordRange, in: context.word, language: language) ?? []
            let guesses = self.checker.guesses(forWordRange: wordRange, in: context.word, language: language) ?? []
            var seen: Set<String> = [context.word]
            let candidates = (guesses + completions).filter {
                $0.count <= 32 && $0.allSatisfy { $0.isLetter } && seen.insert($0).inserted
            }.prefix(3)
            for candidate in candidates {
                let button = UIButton(type: .system)
                button.setTitle(candidate, for: .normal)
                button.tintColor = .label
                button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
                button.accessibilityLabel = "Replace \(context.word) with \(candidate)"
                button.addAction(UIAction { [weak self] _ in self?.feedback() }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in
                    guard let self, self.canSend else { return }
                    self.host?.touchKeyboardAccept(candidate, context: context)
                    self.updateSuggestions()
                }, for: .touchUpInside)
                self.suggestions.addArrangedSubview(button)
            }
        }
    }

    func updatePrediction() {
        guard !isToolbarOnly, predictionEnabled, canSend, predictionLanguage != nil,
              let snapshot = host?.touchKeyboardPredictionContext else {
            predictionTask?.cancel(); predictionTask = nil; pendingPrediction = nil
            return
        }
        guard predictionCache[snapshot.prefix] == nil, pendingPrediction != snapshot else { return }
        predictionTask?.cancel()
        pendingPrediction = snapshot
        // Warm between events; a rollover can commit the preceding letter and
        // need its new prefix before this task has had a chance to run.
        predictionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.predictionEnabled, self.canSend,
                  self.host?.touchKeyboardPredictionContext == snapshot else { return }
            _ = self.predictionPrior(for: snapshot)
            self.pendingPrediction = nil
            self.predictionTask = nil
        }
    }

    private func predictionPrior(for snapshot: Model.PredictionSnapshot) -> Model.LetterPrior? {
        guard let language = predictionLanguage else { return nil }
        let checker = checker
        return predictionCache.prior(for: snapshot.prefix) {
            let range = NSRange(location: 0, length: snapshot.prefix.utf16.count)
            let completions = checker.completions(forPartialWordRange: range, in: snapshot.prefix, language: language) ?? []
            let isWord = checker.rangeOfMisspelledWord(in: snapshot.prefix, range: range, startingAt: 0,
                                                      wrap: false, language: language).location == NSNotFound
            return Model.LetterPrior(prefix: snapshot.prefix, completions: completions, isCompleteWord: isWord)
        }
    }
}

#endif
