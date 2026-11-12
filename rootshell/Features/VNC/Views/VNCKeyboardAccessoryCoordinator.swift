//
//  VNCKeyboardAccessoryCoordinator.swift
//  rootshell
//
//  Hosts the terminal keyboard and its toolbar for a remote-screen pane and
//  translates their key strings into X11 keysym events for its session.
//

import UIKit
import Observation
import os
import rootshellVNC

/// Keyboard-toolbar host for a `RemoteScreenPane` (Screen Sharing or KVM). Owns a
/// `TerminalKeyboardAccessoryController` (full toolbar UI, hardware-keyboard
/// rules, bottom reservation) and delivers one atomic input-view snapshot to
/// `VNCKeyboardCapture` so the package responder reloads its primary and
/// accessory views together. On iPhone and iPad the toolbar row is never an
/// accessory: it lives in the pane's HUD bar (`RemoteScreenHUDToolbar`), which
/// floats or docks along the bottom.
///
/// The per-connection tri-state gates everything: `.off` never shows the
/// toolbar, `.on` forces it, `.followAppSetting` defers to the controller's
/// existing visibility logic (hardware-keyboard tracker + the
/// `showToolbarWithHardwareKeyboard` app setting).
@MainActor
final class VNCKeyboardAccessoryCoordinator {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VNCKeyboardToolbar")

    private weak var pane: (any RemoteScreenPane)?
    private let keyboardCapture: VNCKeyboardCapture
    private(set) var controller: TerminalKeyboardAccessoryController!

    private enum Presentation: Equatable {
        case hidden
        case systemKeyboardWithAccessory
        case accessoryOnly
        /// Capture lapsed under the terminal keyboard. An empty input keeps
        /// Apple's keyboard from standing in until capture returns.
        case touchKeyboardParked
    }

    /// What the package responder was last given. The terminal keyboard rides
    /// along with every presentation and takes over once keys are requested.
    private struct AppliedInputViews: Equatable {
        var presentation: Presentation
        var touchKeyboard: ObjectIdentifier?
    }

    private var appliedInputViews: AppliedInputViews?

    /// Set by the toolbar's dismiss button (non-persistent mode). The package
    /// responder never resigns on dismissal (hardware keys must keep flowing
    /// to the remote), so this flag replaces the terminal's
    /// resign-first-responder signal and hides the toolbar until the software
    /// keyboard is summoned again.
    private var manuallyDismissed = false

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    let hudModel = RemoteScreenHUDKeysModel()
    #endif

    /// Bumped by every key this coordinator sends for the user. Hardware keys
    /// bypass it; see `dictationInputGeneration`.
    private var inputGeneration: UInt64 = 0

    /// Text the pane typed for the user by another route, such as a paste.
    func noteUserInput() { inputGeneration &+= 1 }

    init(pane: any RemoteScreenPane) {
        self.pane = pane
        self.keyboardCapture = pane.keyboardCapture
        self.controller = TerminalKeyboardAccessoryController(host: self)
        controller.setupKeyboard(delegate: self)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // No collapsed toolbar button here; a double tap just hides the keys.
        controller.keyboardAccessory?.onCollapseRequested = { [weak self] in
            self?.keyboardSetSoftwareKeyboardRequested(false)
        }
        // The row is never an input accessory here, so a drawer opening only
        // resizes the HUD. Reloading input views would disturb the keyboard.
        controller.keyboardAccessory?.onLayoutInvalidated = { [weak self] in
            self?.refreshHUDMetrics()
        }
        refreshHUDMetrics()
        #endif

        controller.onActiveKeyboardModifiersChanged = { [weak self] modifiers in
            guard let self else { return }
            // The terminal keyboard publishes its own set; the HUD row keeps one too.
            self.keyboardCapture.supplementalModifiers = Self.vncModifiers(modifiers.union(self.toolbarModifiers))
        }
        keyboardCapture.onSupplementalModifiersConsumed = { [weak self] in
            self?.controller.clearOneShotModifiers()
            self?.clearOneShotToolbarModifiers()
        }
        if keyboardIsFirstResponder { controller.activateTouchKeyboardState() }
        reconcilePresentation(forceReload: true)
        observeSoftwareKeyboardRequest()
        observeCapture()
        #if targetEnvironment(macCatalyst) && STANDALONE
        // Capture stays on under the credential prompts, which take local text.
        RemoteInputSourceHotKeys.shared.register(self) { [weak self] in
            guard let self, let pane = self.pane else { return false }
            return self.keyboardIsFirstResponder && pane.remoteSessionIsConnected
                && pane.window?.isKeyWindow == true
        }
        observeRemoteConnection()
        #endif

        // The controller's own trait registration only reaches hosts that are
        // the host view themselves; re-register on the pane for this
        // coordinator-hosted setup.
        pane.registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { [weak self] (_: UIView, _: UITraitCollection) in
            Task { @MainActor in
                self?.keyboardUpdateAccessoryForTraitCollection()
            }
        }
    }

    func tearDown() {
        #if targetEnvironment(macCatalyst) && STANDALONE
        RemoteInputSourceHotKeys.shared.unregister(self)
        #endif
        keyboardCapture.inputViews = .packageDefault
        keyboardCapture.supplementalModifiers = []
        keyboardCapture.onSupplementalModifiersConsumed = nil
        controller.activeToolbarView?.clearModifiers()
        controller.tearDown()
    }

    // MARK: - Tri-state preference

    private var effectivePreference: VNCConnectionConfig.KeyboardToolbarPreference {
        pane?.effectiveKeyboardToolbarPreference ?? .off
    }

    /// Called when the HUD toggle flips the pane-level override.
    func toolbarPreferenceDidChange() {
        if effectivePreference == .off {
            controller.resetFocusLossState()
            controller.activeToolbarView?.clearModifiers()
        }
        manuallyDismissed = false
        controller.refreshTouchKeyboardToolbarRow()
        // The reset above also took down a detached card.
        controller.scheduleFloatingTouchKeyboardUpdate()
        reconcilePresentation(forceReload: true)
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// The pane captured or released the keyboard. Claims the window's
    /// terminal keyboard before the responder asks for its input views.
    func captureDidChange() {
        if keyboardIsFirstResponder {
            controller.activateTouchKeyboardState()
            // A detached card returns with capture.
            controller.scheduleFloatingTouchKeyboardUpdate()
        } else {
            controller.releaseTouchKeyboardState()
        }
        #if targetEnvironment(macCatalyst) && STANDALONE
        RemoteInputSourceHotKeys.shared.update()
        #endif
        if reconcilePresentation() {
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }

    /// The package also captures on its own, when the remote screen is touched.
    private func observeCapture() {
        withObservationTracking {
            _ = keyboardCapture.isCaptured
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeCapture()
                self.captureDidChange()
            }
        }
    }

    #if targetEnvironment(macCatalyst) && STANDALONE
    private func observeRemoteConnection() {
        withObservationTracking {
            _ = pane?.remoteSessionIsConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeRemoteConnection()
                RemoteInputSourceHotKeys.shared.update()
            }
        }
    }
    #endif

    private var presentation: Presentation {
        if manuallyDismissed {
            // Summoning the software keyboard again (HUD keyboard button)
            // revives the toolbar.
            if keyboardCapture.softwareKeyboardRequested {
                manuallyDismissed = false
            } else {
                return .hidden
            }
        }
        if !keyboardIsFirstResponder, keyboardCapture.softwareKeyboardRequested,
           appliedInputViews?.touchKeyboard != nil || appliedInputViews?.presentation == .touchKeyboardParked {
            return .touchKeyboardParked
        }
        guard !controller.keyboardToolbarCollapsed else { return .hidden }

        let wantsAccessory: Bool
        switch effectivePreference {
        case .off:
            return .hidden
        case .on:
            wantsAccessory = true
        case .followAppSetting:
            wantsAccessory = controller.shouldShowKeyboardToolbar
                || controller.toolbarOnlyMode
                || keyboardCapture.softwareKeyboardRequested
        }
        guard wantsAccessory, controller.keyboardAccessory != nil else { return .hidden }

        if keyboardCapture.softwareKeyboardRequested && !controller.toolbarOnlyMode {
            return .systemKeyboardWithAccessory
        }
        return .accessoryOnly
    }

    /// Apply one coherent primary/accessory configuration. The package bumps
    /// its reload generation once for this snapshot, avoiding the transient
    /// mismatches that displaced the accessory during repeated HUD toggles.
    @discardableResult
    private func reconcilePresentation(forceReload: Bool = false) -> Bool {
        let presentation = presentation
        syncHUD(presentation)
        let touchInput = presentation == .touchKeyboardParked ? nil : controller.touchKeyboardInputOnRequest
        let touchObject: AnyObject? = touchInput.flatMap { $0.controller ?? $0.view }
        let next = AppliedInputViews(
            presentation: presentation,
            touchKeyboard: touchObject.map { ObjectIdentifier($0) })
        guard forceReload || appliedInputViews != next else { return false }
        appliedInputViews = next

        var inputViews: VNCKeyboardInputViews
        switch presentation {
        case .hidden:
            inputViews = .packageDefault
        case .systemKeyboardWithAccessory where hostsToolbarInHUD,
             .accessoryOnly where hostsToolbarInHUD:
            // The toolbar is the HUD's; nothing rides on the keyboard.
            inputViews = VNCKeyboardInputViews(
                primary: .systemKeyboardWhenRequested(otherwise: controller.accessoryOnlyInputView))
        case .systemKeyboardWithAccessory, .accessoryOnly:
            inputViews = VNCKeyboardInputViews(
                primary: .systemKeyboardWhenRequested(otherwise: controller.accessoryOnlyInputView),
                accessory: controller.keyboardAccessory)
        case .touchKeyboardParked:
            inputViews = VNCKeyboardInputViews(primary: .custom(controller.accessoryOnlyInputView))
        }
        inputViews.hostKeyboard = touchInput.map {
            VNCHostKeyboard(inputView: $0.view, inputViewController: $0.controller)
        }
        keyboardCapture.inputViews = inputViews
        controller.updateBottomEdgeHomeGestureProtection()
        return true
    }

    /// Keep the atomic input-view snapshot aligned with package- and
    /// UIKit-driven keyboard changes. `withObservationTracking` fires once,
    /// so re-arm it before reconciling the new value.
    private func observeSoftwareKeyboardRequest() {
        withObservationTracking {
            _ = keyboardCapture.softwareKeyboardRequested
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSoftwareKeyboardRequest()
                self.softwareKeyboardRequestDidChange()
            }
        }
    }

    private func softwareKeyboardRequestDidChange() {
        // An explicit package/HUD request to show the keyboard supersedes a
        // persistent or pinned toolbar-only state and restores the chevron.
        if keyboardCapture.softwareKeyboardRequested,
           controller.toolbarOnlyMode {
            controller.exitToolbarOnlyMode()
            controller.softwareKeyboardRequestDidChange()
            return
        }

        controller.softwareKeyboardRequestDidChange()
        reconcilePresentation(forceReload: true)
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// False under the terminal keyboard, which replaces the accessory, and
    /// wherever the HUD carries the toolbar.
    private var showsAccessory: Bool {
        guard !hostsToolbarInHUD, !controller.usesFullTouchKeyboard else { return false }
        switch presentation {
        case .systemKeyboardWithAccessory, .accessoryOnly: return true
        case .hidden, .touchKeyboardParked: return false
        }
    }

    var keyboardAccessoryFrameInScreen: CGRect? {
        guard showsAccessory else { return nil }
        return controller.keyboardAccessoryFrameInScreen
    }

    var dockedTouchKeyboardFrameInScreen: CGRect? {
        controller.dockedTouchKeyboardFrameInScreen
    }

    /// Bottom inset the pane must reserve whenever the toolbar is visible.
    /// The outer terminal layout ignores this in favor of the keyboard's full
    /// coverage while the software keyboard is docked. When that keyboard is
    /// detached on iPad, however, UIKit leaves its input accessory at the
    /// bottom edge, so the toolbar still needs this reservation even though
    /// the presentation includes the system keyboard.
    var reservedToolbarHeightAtBottom: CGFloat {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return 0
        #else
        guard showsAccessory,
              let pane,
              keyboardIsFirstResponder else { return 0 }
        let fallbackHeight = KeyboardSizes.current(traitCollection: pane.traitCollection).toolbar.height
        if let accessoryHeight = controller.keyboardAccessory?.bounds.height,
           accessoryHeight > 0 {
            return max(fallbackHeight, accessoryHeight)
        }
        return max(fallbackHeight, controller.keyboardAccessory?.intrinsicContentSize.height ?? fallbackHeight)
        #endif
    }

    private static func vncModifiers(_ modifiers: KeyModifiers) -> VNCKeyboardModifiers {
        var result: VNCKeyboardModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.alt) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}

// MARK: - HUD toolbar strip

extension VNCKeyboardAccessoryCoordinator {
    /// On iPhone and iPad the toolbar row rides in the pane's HUD bar, floating
    /// or docked along the bottom, and never as an input accessory.
    private var hostsToolbarInHUD: Bool {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Modifiers latched on the floating row, which the keys-only terminal
    /// keyboard beneath it knows nothing of.
    private var toolbarModifiers: KeyModifiers {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard hudModel.isFloating, hudModel.stripAvailable else { return [] }
        return controller.keyboardAccessory?.toolbarView.activeModifiers ?? []
        #else
        return []
        #endif
    }

    private func clearOneShotToolbarModifiers() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard hudModel.isFloating, hudModel.stripAvailable else { return }
        controller.keyboardAccessory?.toolbarView.clearOneShotModifiers()
        #endif
    }

    private func syncHUD(_ presentation: Presentation) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Docked, the terminal keyboard brings its own toolbar row and the bar steps aside.
        let barEnabled = hudModel.isFloating || !controller.usesFullTouchKeyboard
        // The hardware-keyboard setting hides the presentation and, by default,
        // the keys; the bar keeps its chevron to show them. Input views stay
        // on the package default.
        let hiddenBySetting = presentation == .hidden && effectivePreference == .followAppSetting
            && !manuallyDismissed && !controller.keyboardToolbarCollapsed
            && controller.keyboardAccessory != nil
        let stripAvailable = barEnabled && effectivePreference != .off
            && (presentation != .hidden || hiddenBySetting)
        if hudModel.keysHiddenBySetting != hiddenBySetting { hudModel.keysHiddenBySetting = hiddenBySetting }
        let keysRequested = keyboardCapture.softwareKeyboardRequested
        if hudModel.keysRequested != keysRequested { hudModel.keysRequested = keysRequested }
        if hudModel.barEnabled != barEnabled { hudModel.barEnabled = barEnabled }
        if hudModel.stripAvailable != stripAvailable {
            // A modifier latched on a row that is going away must not linger unseen.
            if !stripAvailable { controller.keyboardAccessory?.toolbarView.clearModifiers() }
            hudModel.stripAvailable = stripAvailable
        }
        controller.toolbarIsDetachedFromScreenEdge = true
        refreshHUDMetrics()
        if !stripAvailable { reclaimToolbarFromHUD() }
        #endif
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// Moves the toolbar between the floating bar and its docked place.
    func setToolbarFloating(_ floating: Bool) {
        guard hudModel.isFloating != floating else { return }
        controller.keyboardAccessory?.toolbarView.clearModifiers()
        hudModel.isFloating = floating
        controller.refreshTouchKeyboardToolbarRow()
        reconcilePresentation(forceReload: true)
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// The HUD's keys button. Captures first, as the HUD menu item does.
    func toggleKeysFromHUD() {
        manuallyDismissed = false
        keyboardCapture.capture()
        keyboardSetSoftwareKeyboardRequested(!keyboardCapture.softwareKeyboardRequested)
    }

    /// Returns the row once it is in `container`. `trailingReserve` is the
    /// width of the HUD's buttons, which cover the main row's trailing end.
    @discardableResult
    func mountToolbarInHUD(_ container: UIView, trailingReserve: CGFloat) -> KeyboardToolbarView? {
        guard hudModel.stripAvailable, let accessory = controller.keyboardAccessory else { return nil }
        let toolbar = accessory.toolbarView
        if toolbar.superview !== container {
            _ = accessory.lendToolbar()
            // The HUD supplies the glass and the insets.
            toolbar.usesHostChrome = true
            container.addSubview(toolbar)
            // Height stays the row's own; open drawers grow it upward.
            NSLayoutConstraint.activate([
                toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        if abs(toolbar.hostTrailingReserve - trailingReserve) > 0.5 {
            toolbar.hostTrailingReserve = trailingReserve
        }
        return toolbar
    }

    func unmountToolbarFromHUD(_ container: UIView) {
        guard controller.keyboardAccessory?.toolbarView.superview === container else { return }
        reclaimToolbarFromHUD()
    }

    private func reclaimToolbarFromHUD() {
        guard let accessory = controller.keyboardAccessory,
              accessory.toolbarView.superview !== accessory else { return }
        accessory.toolbarView.usesHostChrome = false
        accessory.toolbarView.hostTrailingReserve = 0
        accessory.reclaimToolbar()
    }

    /// The bar is sized from the toolbar's own key metrics, so every button matches.
    private func refreshHUDMetrics() {
        guard let pane, let toolbar = controller.keyboardAccessory?.toolbarView else { return }
        let sizes = KeyboardSizes.current(traitCollection: pane.traitCollection)
        let metrics = RemoteScreenHUDKeysModel.Metrics(
            keyCount: toolbar.mainRowKeyCount(forHostChrome: true),
            edgePadding: toolbar.mainRowEdgePadding,
            slotWidth: sizes.button.iconWidth,
            minimumSlotWidth: sizes.button.normalWidth,
            rowHeight: sizes.toolbar.height,
            symbolPointSize: sizes.button.symbolSize)
        let height = toolbar.intrinsicContentSize.height
        if hudModel.metrics != metrics { hudModel.metrics = metrics }
        if height > 0, hudModel.stripHeight != height { hudModel.stripHeight = height }
    }
    #endif
}

// MARK: - TerminalKeyboardAccessoryHost

extension VNCKeyboardAccessoryCoordinator: TerminalKeyboardAccessoryHost {
    var keyboardHostView: UIView { (pane as UIView?) ?? UIView() }

    /// The package's remote input view holds real first-responder status and
    /// keeps it while captured; capture state is the truthful proxy.
    var keyboardIsFirstResponder: Bool {
        keyboardCapture.isCaptured && pane?.window != nil
    }

    var keyboardAIAgentOverlayActive: Bool { false }
    var keyboardToolbarOnlyMode: Bool { controller.toolbarOnlyMode }
    var keyboardAccessoryOmitsBottomSafeAreaStrip: Bool { true }

    @discardableResult
    func keyboardBecomeFirstResponder() -> Bool {
        guard let pane else { return false }
        manuallyDismissed = false
        if pane.isLogicallyFocused {
            pane.captureKeyboard()
        }
        return keyboardCapture.isCaptured
    }

    @discardableResult
    func keyboardResignFirstResponder() -> Bool {
        // Dismiss hides the software keyboard and the toolbar; the package
        // responder keeps first-responder status so hardware keys still reach
        // the remote.
        manuallyDismissed = true
        keyboardSetSoftwareKeyboardRequested(false)
        reconcilePresentation(forceReload: true)
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        return true
    }

    func keyboardSetSoftwareKeyboardRequested(_ requested: Bool) {
        guard keyboardCapture.softwareKeyboardRequested != requested else { return }
        keyboardCapture.softwareKeyboardRequested = requested
    }

    func keyboardReloadInputViews() {
        if !reconcilePresentation() {
            keyboardCapture.setNeedsInputViewsReload()
        }
    }

    func keyboardInvalidateKeyCommands() {}
    func keyboardDidFinishAnimationLayout() {}

    func keyboardUpdateAccessoryForTraitCollection() {
        guard let pane else { return }
        controller.keyboardAccessory?.updateForTraitCollection(pane.traitCollection)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        refreshHUDMetrics()
        #endif
    }

    func keyboardPaste() {
        pane?.pasteFromKeyboardToolbar()
    }

    func keyboardToggleCompose() {}

    func keyboardToggleMouseCapture() {
        keyboardCapture.toggleCaptureMode()
    }

    func keyboardToggleBrightnessHUD() {
        pane?.toggleBrightnessHUD()
    }

    func keyboardTypePassword(pressingReturn: Bool) {
        inputGeneration &+= 1
        pane?.typePasswordFromKeyboardToolbar(pressingReturn: pressingReturn)
    }

    /// Two taps of the key, for shortcuts bound to a double modifier press. The
    /// modifier is never left down across a suspension, where it would join other input.
    func keyboardSendModifierDoublePress(_ modifier: KeyModifiers) {
        let keysyms = Self.modifierKeysyms(modifier, appleModifierConvention: appleModifierConvention)
        guard !keysyms.isEmpty, let pane, keyboardIsFirstResponder else { return }
        inputGeneration &+= 1
        Task { @MainActor in
            for press in 0..<2 {
                if press > 0 { try? await Task.sleep(for: .milliseconds(80)) }
                for keysym in keysyms { pane.sendKeyboardToolbarKeysym(down: true, keysym: keysym) }
                for keysym in keysyms.reversed() { pane.sendKeyboardToolbarKeysym(down: false, keysym: keysym) }
            }
        }
    }
}

// MARK: - Terminal keyboard

#if !os(visionOS) && !targetEnvironment(macCatalyst)
extension VNCKeyboardAccessoryCoordinator: TerminalTouchKeyboardHost {
    var keyboardTouchKeyboardHost: TerminalTouchKeyboardHost? { self }
    var keyboardTabID: UUID? { pane?.containingTabID }
    var keyboardSoftwareKeyboardRequest: Bool? { keyboardCapture.softwareKeyboardRequested }

    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        guard let pane else { return nil }
        let (name, _) = ThemeOverrideManager.shared.resolveTheme(tabId: pane.containingTabID, windowId: pane.windowId)
        return ThemeManager.shared.themeInfo(for: name)?.colors
    }

    /// Keys go straight to the session, so a card keeps typing even while
    /// the system briefly holds first responder (a Duo fold).
    var touchKeyboardCanSend: Bool { keyboardIsFirstResponder }
    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }

    /// Floating, the keyboard shows keys only and the HUD row is its toolbar.
    /// Docked, it keeps its own row and the HUD bar steps aside.
    var keyboardTouchKeyboardShowsToolbar: Bool { !hudModel.isFloating || effectivePreference == .off }

    func keyboardToggleToolbarFloating() {
        setToolbarFloating(!hudModel.isFloating)
    }

    func touchKeyboardInsert(_ text: String) {
        guard touchKeyboardCanSend else { return }
        // A modifier latched on the HUD row applies to the next typed key.
        let held = toolbarModifiers
        if !held.isEmpty, text.count == 1 {
            keyPressed(text, modifiers: held, shifted: nil)
            clearOneShotToolbarModifiers()
            return
        }
        inputGeneration &+= 1
        sendTranslated(text)
    }

    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers, shifted: Character?) {
        guard touchKeyboardCanSend else { return }
        keyPressed(key, modifiers: modifiers.union(toolbarModifiers), shifted: shifted)
        clearOneShotToolbarModifiers()
    }

    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
    func touchKeyboardInvalidateSuggestions() {}
}
#endif

#if canImport(FluidAudio) && !CHINA_BUILD
/// The keyboard's Dictation page types into the remote screen.
extension VNCKeyboardAccessoryCoordinator: DictationTarget {
    var dictationCanReceive: Bool { keyboardIsFirstResponder }
    var dictationAgentName: String? { nil }
    var dictationScreenText: String? { nil }
    /// Keys sent here, plus the ones the package responder sent itself.
    var dictationInputGeneration: UInt64 { inputGeneration &+ keyboardCapture.keyboardInputGeneration }
    var dictationPreferredStyle: DictationFormatter.Style? { .prose }
    /// Return acts on whatever the remote screen has focused.
    var dictationAllowsAutoSubmit: Bool { false }

    func dictationInsert(_ text: String) {
        guard dictationCanReceive else { return }
        sendTranslated(text)
    }

    func dictationSubmit() {
        dictationTap(KeyboardInputHandler.keysymReturn)
    }

    func dictationSend(_ key: DictationKey) {
        switch key {
        case .escape: dictationTap(KeyboardInputHandler.keysymEscape)
        case .tab: dictationTap(KeyboardInputHandler.keysymTab)
        case .up: dictationTap(KeyboardInputHandler.keysymUp)
        case .down: dictationTap(KeyboardInputHandler.keysymDown)
        case .backspace: dictationTap(KeyboardInputHandler.keysymBackspace)
        case .control(let character):
            dictationTap(KeyboardInputHandler.keysymForCharacter(character),
                         modifiers: [KeyboardInputHandler.keysymControlL])
        }
    }

    func dictationDeleteBackward(_ count: Int) {
        for _ in 0..<max(0, count) { dictationTap(KeyboardInputHandler.keysymBackspace) }
    }

    private func dictationTap(_ keysym: UInt32, modifiers: [UInt32] = []) {
        guard dictationCanReceive else { return }
        sendStroke(KeyStroke(modifiers: modifiers, keysym: keysym))
    }
}
#endif

// MARK: - KeyboardButtonDelegate (keysym bridge)

extension VNCKeyboardAccessoryCoordinator: KeyboardButtonDelegate {

    /// Whether the connected server uses Apple's swapped modifier convention,
    /// so Option/Alt must be sent as `Meta_L` rather than `Alt_L` (which Apple
    /// reads as Command).
    private var appleModifierConvention: Bool {
        pane?.usesAppleModifierConvention ?? false
    }

    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        keyPressed(key, modifiers: modifiers, shifted: nil)
    }

    /// `shifted` is a keyboard layout's Shift output for the key; nil keeps US casing.
    private func keyPressed(_ key: String, modifiers: KeyModifiers, shifted: Character?) {
        inputGeneration &+= 1
        if let keysym = Self.namedKeysyms[key] ?? Self.functionKeysym(key) {
            sendStroke(KeyStroke(
                modifiers: Self.modifierKeysyms(
                    modifiers, appleModifierConvention: appleModifierConvention),
                keysym: keysym))
            return
        }
        if key.count == 1, let char = key.first {
            // Shifted characters carry the shifted keysym (like a real
            // keyboard) with the Shift modifier still pressed around them.
            let effective = modifiers.contains(.shift)
                ? shifted ?? Ghostty.TerminalView.shiftedCharacter(char)
                : char
            sendStroke(KeyStroke(
                modifiers: Self.modifierKeysyms(
                    modifiers, appleModifierConvention: appleModifierConvention),
                keysym: KeyboardInputHandler.keysymForCharacter(effective)))
            return
        }
        // Unrecognized multi-character string (custom text keys): best-effort
        // per-scalar translation, same path as raw data.
        sendTranslated(key)
    }

    func sendRawData(_ data: Data) {
        inputGeneration &+= 1
        sendTranslated(String(decoding: data, as: UTF8.self))
    }

    /// "F1" through "F12", as the terminal keyboard names them.
    private static func functionKeysym(_ key: String) -> UInt32? {
        guard key.hasPrefix("F"), let number = UInt32(key.dropFirst()), (1...12).contains(number) else { return nil }
        return KeyboardInputHandler.keysymF1 + number - 1
    }

    // MARK: Stroke primitives

    fileprivate struct KeyStroke {
        var modifiers: [UInt32]
        var keysym: UInt32
    }

    /// Modifier chord: modifiers down in order, key down+up, modifiers up in
    /// reverse.
    fileprivate func sendStroke(_ stroke: KeyStroke) {
        guard stroke.keysym != 0, let pane else { return }
        for modifier in stroke.modifiers {
            pane.sendKeyboardToolbarKeysym(down: true, keysym: modifier)
        }
        pane.sendKeyboardToolbarKeysym(down: true, keysym: stroke.keysym)
        pane.sendKeyboardToolbarKeysym(down: false, keysym: stroke.keysym)
        for modifier in stroke.modifiers.reversed() {
            pane.sendKeyboardToolbarKeysym(down: false, keysym: modifier)
        }
    }

    private static func modifierKeysyms(
        _ modifiers: KeyModifiers,
        appleModifierConvention: Bool
    ) -> [UInt32] {
        var result: [UInt32] = []
        if modifiers.contains(.control) { result.append(KeyboardInputHandler.keysymControlL) }
        if modifiers.contains(.alt) {
            result.append(KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: appleModifierConvention))
        }
        if modifiers.contains(.shift) { result.append(KeyboardInputHandler.keysymShiftL) }
        if modifiers.contains(.command) { result.append(KeyboardInputHandler.keysymSuperL) }
        return result
    }

    /// Named key strings the toolbar emits through `keyPressed` plus the
    /// escape sequences the app's own SpecialKey encoding produces. Single
    /// C0 characters (esc, tab, return) also resolve through
    /// `keysymForCharacter`, but 0x7F must land on BackSpace here (terminal
    /// convention), not the X11 Delete the package maps it to.
    private static let namedKeysyms: [String: UInt32] = [
        "\u{1B}": KeyboardInputHandler.keysymEscape,
        "\t": KeyboardInputHandler.keysymTab,
        "\r": KeyboardInputHandler.keysymReturn,
        "\n": KeyboardInputHandler.keysymReturn,
        "\u{7F}": KeyboardInputHandler.keysymBackspace,
        "\u{1B}[A": KeyboardInputHandler.keysymUp,
        "\u{1B}[B": KeyboardInputHandler.keysymDown,
        "\u{1B}[C": KeyboardInputHandler.keysymRight,
        "\u{1B}[D": KeyboardInputHandler.keysymLeft,
        "\u{1B}[H": KeyboardInputHandler.keysymHome,
        "\u{1B}[F": KeyboardInputHandler.keysymEnd,
        "\u{1B}[2~": KeyboardInputHandler.keysymInsert,
        "\u{1B}[3~": KeyboardInputHandler.keysymDelete,
        "\u{1B}[5~": KeyboardInputHandler.keysymPageUp,
        "\u{1B}[6~": KeyboardInputHandler.keysymPageDown,
    ]

    // MARK: Terminal-byte-string translation

    /// Best-effort translation of terminal-style byte strings (custom key
    /// sequences, swipe bindings) into keysym strokes: recognizes the
    /// CSI/SS3 sequences the app's own toolbar generates, maps C0 controls
    /// to Ctrl chords, and taps everything else as a character keysym.
    fileprivate func sendTranslated(_ text: String) {
        for stroke in Self.strokes(
            for: text, appleModifierConvention: appleModifierConvention) {
            sendStroke(stroke)
        }
    }

    private static func strokes(
        for text: String,
        appleModifierConvention: Bool
    ) -> [KeyStroke] {
        var result: [KeyStroke] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index].value == 0x1B {
                let (stroke, consumed) = parseEscape(
                    scalars,
                    from: index,
                    appleModifierConvention: appleModifierConvention)
                if let stroke { result.append(stroke) }
                index += consumed
                continue
            }
            if let stroke = strokeForScalar(scalars[index]) {
                result.append(stroke)
            }
            index += 1
        }
        return result
    }

    private static func strokeForScalar(_ scalar: Unicode.Scalar) -> KeyStroke? {
        switch scalar.value {
        case 0x0D, 0x0A:
            return KeyStroke(modifiers: [], keysym: KeyboardInputHandler.keysymReturn)
        case 0x09:
            return KeyStroke(modifiers: [], keysym: KeyboardInputHandler.keysymTab)
        case 0x08, 0x7F:
            return KeyStroke(modifiers: [], keysym: KeyboardInputHandler.keysymBackspace)
        case 0x00...0x1F:
            // Other C0 control: send as a Ctrl chord of the un-controlled
            // character (0x03 -> Ctrl+C).
            guard let uncontrolled = Unicode.Scalar(scalar.value + 0x60) else { return nil }
            return KeyStroke(
                modifiers: [KeyboardInputHandler.keysymControlL],
                keysym: KeyboardInputHandler.keysymForCharacter(Character(uncontrolled)))
        case 0xFFFD:
            // Replacement character from lossy decode: drop.
            return nil
        default:
            let keysym = KeyboardInputHandler.keysymForCharacter(Character(scalar))
            return keysym != 0 ? KeyStroke(modifiers: [], keysym: keysym) : nil
        }
    }

    /// Parse one escape-prefixed token (`scalars[start]` is ESC). Returns the
    /// stroke (nil to drop) and the number of scalars consumed.
    private static func parseEscape(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        appleModifierConvention: Bool
    ) -> (KeyStroke?, Int) {
        let escapeStroke = KeyStroke(modifiers: [], keysym: KeyboardInputHandler.keysymEscape)
        let next = start + 1
        guard next < scalars.count else { return (escapeStroke, 1) }

        switch scalars[next] {
        case "[":
            return parseCSI(
                scalars,
                paramStart: next + 1,
                appleModifierConvention: appleModifierConvention)
        case "O":
            guard next + 1 < scalars.count,
                  let keysym = ss3Keysym(scalars[next + 1]) else { return (escapeStroke, 1) }
            return (KeyStroke(modifiers: [], keysym: keysym), 3)
        case let scalar where scalar.value >= 0x20 && scalar.value != 0x7F:
            // ESC + printable inside one blob is the toolbar's Alt encoding.
            let keysym = KeyboardInputHandler.keysymForCharacter(Character(scalar))
            guard keysym != 0 else { return (nil, 2) }
            let alt = KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: appleModifierConvention)
            return (KeyStroke(modifiers: [alt], keysym: keysym), 2)
        default:
            return (escapeStroke, 1)
        }
    }

    /// CSI parser covering the forms the app emits: `ESC [ params final`
    /// with optional xterm modifier parameter (1 + bitmask).
    private static func parseCSI(
        _ scalars: [Unicode.Scalar],
        paramStart: Int,
        appleModifierConvention: Bool
    ) -> (KeyStroke?, Int) {
        var index = paramStart
        var params: [UInt32] = []
        var current: UInt32?
        while index < scalars.count {
            let value = scalars[index].value
            if value >= 0x30, value <= 0x39 {
                current = (current ?? 0) &* 10 &+ (value - 0x30)
                index += 1
            } else if value == 0x3B {
                params.append(current ?? 0)
                current = nil
                index += 1
            } else {
                break
            }
        }
        if let current { params.append(current) }
        guard index < scalars.count else {
            // Truncated sequence: emit a bare Escape for the ESC alone.
            return (KeyStroke(modifiers: [], keysym: KeyboardInputHandler.keysymEscape), 1)
        }

        let final = scalars[index]
        let consumed = index - paramStart + 3
        let modifiers = csiModifiers(
            params.count >= 2 ? params[1] : 1,
            appleModifierConvention: appleModifierConvention)

        if final == "~" {
            guard let code = params.first, let keysym = tildeKeysym(code) else { return (nil, consumed) }
            return (KeyStroke(modifiers: modifiers, keysym: keysym), consumed)
        }
        if final == "Z" {
            // Backtab
            return (KeyStroke(modifiers: [KeyboardInputHandler.keysymShiftL], keysym: KeyboardInputHandler.keysymTab), consumed)
        }
        guard let keysym = csiFinalKeysym(final) else { return (nil, consumed) }
        return (KeyStroke(modifiers: modifiers, keysym: keysym), consumed)
    }

    /// xterm modifier parameter: 1 + bitmask (1 shift, 2 alt, 4 ctrl, 8 meta).
    private static func csiModifiers(
        _ code: UInt32,
        appleModifierConvention: Bool
    ) -> [UInt32] {
        guard code > 1 else { return [] }
        let mask = code - 1
        var result: [UInt32] = []
        if mask & 4 != 0 { result.append(KeyboardInputHandler.keysymControlL) }
        if mask & 2 != 0 {
            result.append(KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: appleModifierConvention))
        }
        if mask & 1 != 0 { result.append(KeyboardInputHandler.keysymShiftL) }
        if mask & 8 != 0 { result.append(KeyboardInputHandler.keysymSuperL) }
        return result
    }

    private static func csiFinalKeysym(_ final: Unicode.Scalar) -> UInt32? {
        switch final {
        case "A": return KeyboardInputHandler.keysymUp
        case "B": return KeyboardInputHandler.keysymDown
        case "C": return KeyboardInputHandler.keysymRight
        case "D": return KeyboardInputHandler.keysymLeft
        case "H": return KeyboardInputHandler.keysymHome
        case "F": return KeyboardInputHandler.keysymEnd
        case "P": return KeyboardInputHandler.keysymF1
        case "Q": return KeyboardInputHandler.keysymF2
        case "R": return KeyboardInputHandler.keysymF3
        case "S": return KeyboardInputHandler.keysymF4
        default: return nil
        }
    }

    private static func tildeKeysym(_ code: UInt32) -> UInt32? {
        switch code {
        case 1, 7: return KeyboardInputHandler.keysymHome
        case 2: return KeyboardInputHandler.keysymInsert
        case 3: return KeyboardInputHandler.keysymDelete
        case 4, 8: return KeyboardInputHandler.keysymEnd
        case 5: return KeyboardInputHandler.keysymPageUp
        case 6: return KeyboardInputHandler.keysymPageDown
        case 11: return KeyboardInputHandler.keysymF1
        case 12: return KeyboardInputHandler.keysymF2
        case 13: return KeyboardInputHandler.keysymF3
        case 14: return KeyboardInputHandler.keysymF4
        case 15: return KeyboardInputHandler.keysymF5
        case 17: return KeyboardInputHandler.keysymF6
        case 18: return KeyboardInputHandler.keysymF7
        case 19: return KeyboardInputHandler.keysymF8
        case 20: return KeyboardInputHandler.keysymF9
        case 21: return KeyboardInputHandler.keysymF10
        case 23: return KeyboardInputHandler.keysymF11
        case 24: return KeyboardInputHandler.keysymF12
        default: return nil
        }
    }

    private static func ss3Keysym(_ final: Unicode.Scalar) -> UInt32? {
        switch final {
        case "A": return KeyboardInputHandler.keysymUp
        case "B": return KeyboardInputHandler.keysymDown
        case "C": return KeyboardInputHandler.keysymRight
        case "D": return KeyboardInputHandler.keysymLeft
        case "H": return KeyboardInputHandler.keysymHome
        case "F": return KeyboardInputHandler.keysymEnd
        case "P": return KeyboardInputHandler.keysymF1
        case "Q": return KeyboardInputHandler.keysymF2
        case "R": return KeyboardInputHandler.keysymF3
        case "S": return KeyboardInputHandler.keysymF4
        default: return nil
        }
    }
}
