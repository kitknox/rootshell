//
//  TerminalKeyboardAccessoryController.swift
//  rootshell
//
//  Owns per-terminal keyboard accessory UI state on behalf of TerminalView.
//

import UIKit
import Combine
import os

@MainActor
protocol TerminalKeyboardAccessoryHost: AnyObject {
    var keyboardHostView: UIView { get }
    var keyboardIsFirstResponder: Bool { get }
    var keyboardAIAgentOverlayActive: Bool { get }
    var keyboardToolbarOnlyMode: Bool { get }
    /// The host lays out its own accessory, so no home-indicator strip is added.
    var keyboardAccessoryOmitsBottomSafeAreaStrip: Bool { get }
    /// How far the host view reaches below its pane, under the toolbar and keyboard.
    var keyboardHostBottomUnderlap: CGFloat { get }
    /// Window whose `SoftwareKeyboardHideIntentStore` entry governs this host.
    /// nil opts out: the chevron falls back to resigning first responder.
    var keyboardHideIntentWindow: UIWindow? { get }
    var keyboardSizes: KeyboardSizes { get }
    /// Whose toolbar layout this host shows.
    var keyboardToolbarContext: ToolbarContext { get }
    /// Whether a remote screen's own bar carries the toolbar floating or docked.
    /// nil where the toolbar rides on the keyboard.
    var keyboardGlassBarIsFloating: Bool? { get }

    @discardableResult
    func keyboardBecomeFirstResponder() -> Bool
    @discardableResult
    func keyboardResignFirstResponder() -> Bool
    func keyboardSetSoftwareKeyboardRequested(_ requested: Bool)
    func keyboardReloadInputViews()
    func keyboardInvalidateKeyCommands()
    func keyboardDidFinishAnimationLayout()
    func keyboardUpdateAccessoryForTraitCollection()
    func keyboardPaste()
    func keyboardToggleCompose()
    func keyboardToggleMouseCapture()
    func keyboardToggleBrightnessHUD()
    /// Two bare presses of one modifier. Only a remote screen has a use for them.
    func keyboardSendModifierDoublePress(_ modifier: KeyModifiers)
    /// Type the connection's saved password into a remote screen.
    func keyboardTypePassword(pressingReturn: Bool)
    /// Move a remote screen's toolbar between its floating bar and the keyboard.
    func keyboardToggleToolbarFloating()

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// Where the terminal keyboard's keys go. nil keeps Apple's keyboard.
    var keyboardTouchKeyboardHost: TerminalTouchKeyboardHost? { get }
    /// Tab whose keyboard choices this host shares.
    var keyboardTabID: UUID? { get }
    /// nil where focus alone presents keys (a terminal). A remote screen
    /// holds focus without them and reports its request for keys here.
    var keyboardSoftwareKeyboardRequest: Bool? { get }
    /// Focus left the app with nothing here wanting it, as during a Duo fold.
    var keyboardLostFocusOutsideWindow: Bool { get }
    /// False where the host supplies the toolbar itself and wants keys only.
    var keyboardTouchKeyboardShowsToolbar: Bool { get }
    func keyboardPrepareTouchKeyboardSwitch()
    #endif
}

extension TerminalKeyboardAccessoryHost {
    var keyboardAccessoryOmitsBottomSafeAreaStrip: Bool { false }
    var keyboardHostBottomUnderlap: CGFloat { 0 }
    var keyboardHideIntentWindow: UIWindow? { nil }
    var keyboardSizes: KeyboardSizes {
        KeyboardSizes.accessory(traitCollection: keyboardHostView.traitCollection, context: keyboardToolbarContext)
    }
    var keyboardToolbarContext: ToolbarContext { .terminal }
    var keyboardGlassBarIsFloating: Bool? { nil }
    func keyboardSendModifierDoublePress(_ modifier: KeyModifiers) {}
    func keyboardTypePassword(pressingReturn: Bool) {}
    func keyboardToggleToolbarFloating() {}
    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    var keyboardSoftwareKeyboardRequest: Bool? { nil }
    var keyboardLostFocusOutsideWindow: Bool { false }
    var keyboardTouchKeyboardShowsToolbar: Bool { true }
    func keyboardPrepareTouchKeyboardSwitch() {}
    #endif
}

@MainActor
final class TerminalKeyboardAccessoryController: NSObject {
    private weak var host: TerminalKeyboardAccessoryHost?

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    private weak var touchKeyboardDelegate: KeyboardButtonDelegate?
    /// The window's keyboard, remembered so ownership can be released after
    /// the host has already left its window.
    private weak var touchKeyboardWindowState: TerminalTouchKeyboardWindowState?
    /// Every accessor below is nil unless this controller owns the window's
    /// keyboard, so a controller that lost focus cannot disturb the one that has it.
    private var ownedTouchKeyboardScope: TerminalTouchKeyboardWindowState? {
        guard let scope = touchKeyboardWindowState, scope.owner === self else { return nil }
        return scope
    }
    /// nil while the scope builds an input view: UIKit's nested input-view
    /// queries must not build a second one.
    private var touchKeyboardInputScope: TerminalTouchKeyboardWindowState? {
        guard let scope = ownedTouchKeyboardScope, !scope.isBuildingInputView else { return nil }
        return scope
    }
    var touchKeyboard: TerminalTouchKeyboardView? { ownedTouchKeyboardScope?.keyboard }
    private var touchKeyboardInputView: TerminalTouchKeyboardInputView? { touchKeyboardInputScope?.input }
    private var touchKeyboardToolbarInputView: TerminalTouchKeyboardToolbarInputView? { touchKeyboardInputScope?.toolbarInput }
    private var touchKeyboardController: UIInputViewController? { touchKeyboardInputScope?.controller }
    private var floatingKeyboardOverlay: TerminalFloatingKeyboardOverlay? {
        get { ownedTouchKeyboardScope?.overlay }
        set { ownedTouchKeyboardScope?.overlay = newValue }
    }
    /// One automatic focus reclaim, re-armed by a normal claim or a new hinge
    /// event, so the app never trades focus back and forth with the system.
    private var focusReclaimArmed = true
    private var reclaimHingeGeneration = -1
    private var isReclaimingFocus = false
    /// Owner displaced by the last claim, so a refused focus change can hand
    /// the keyboard straight back to the responder that kept focus.
    private weak var displacedTouchKeyboardOwner: TerminalKeyboardAccessoryController?
    private let fallbackTouchKeyboardState = TerminalFloatingKeyboardState()
    private var boundTouchKeyboardState: TerminalFloatingKeyboardState?
    private var touchKeyboardEnabled = SettingsStore.shared.value(Settings.Keyboard.touchEnabled)
    private var touchSystemFloating = TerminalKeyboardAccessoryController.systemFloatingSetting
    /// iPhone has no system floating keyboard, so it always detaches in the app.
    private static var systemFloatingSetting: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && SettingsStore.shared.value(Settings.Keyboard.touchSystemFloating)
    }
    private var touchStatePerTab = SettingsStore.shared.value(Settings.Keyboard.touchStatePerTab)
    private var floatingSyncScheduled = false

    private var currentTouchKeyboardState: TerminalFloatingKeyboardState {
        if let boundTouchKeyboardState { return boundTouchKeyboardState }
        guard let host, host.keyboardTouchKeyboardHost != nil,
              let window = host.keyboardHostView.window else { return fallbackTouchKeyboardState }
        return TerminalTouchKeyboardWindowState.forWindow(window).state(
            tabID: host.keyboardTabID, perTab: touchStatePerTab)
    }

    private var temporarilyUseSystemKeyboard: Bool {
        get { currentTouchKeyboardState.temporarilyUseSystemKeyboard }
        set {
            currentTouchKeyboardState.temporarilyUseSystemKeyboard = newValue
            updateTouchKeyboardReturnButton()
        }
    }
    private var touchKeyboardRequestedWithHardware: Bool {
        get { currentTouchKeyboardState.requestedWithHardware }
        set { currentTouchKeyboardState.requestedWithHardware = newValue }
    }

    /// Claim the window's keyboard for this host and reconcile it with
    /// the current settings and state. Idempotent. Runs before UIKit queries
    /// the incoming responder's input views, which can happen before it calls
    /// resignFirstResponder on the outgoing one.
    func activateTouchKeyboardState() {
        KeyboardTracker.shared.setInputOwnerWindow(host?.keyboardHostView.window)
        guard let host, let keyboardHost = host.keyboardTouchKeyboardHost, let delegate = touchKeyboardDelegate,
              let window = host.keyboardHostView.window else { return }
        guard touchKeyboardEnabled else {
            releaseTouchKeyboardState()
            return
        }
        let scope = TerminalTouchKeyboardWindowState.forWindow(window)
        touchKeyboardWindowState = scope
        // Another pane sharing this state may have switched keyboards since.
        updateTouchKeyboardReturnButton()
        let ownerChanged = scope.owner !== self
        displacedTouchKeyboardOwner = ownerChanged ? scope.owner : nil
        scope.parkedOwner = nil
        if !isReclaimingFocus { focusReclaimArmed = true }
        if ownerChanged {
            scope.owner?.releaseTouchKeyboardState()
            scope.owner = self
            scope.keyboard.host = keyboardHost
            scope.keyboard.sequenceDelegate = delegate
        }
        scope.keyboard.toolbarContext = host.keyboardToolbarContext
        // Through the reconciliation, which keeps latched keys when a fold hands the row back.
        refreshTouchKeyboardToolbarRow()
        let stateChanged = boundTouchKeyboardState !== scope.state(tabID: host.keyboardTabID, perTab: touchStatePerTab)
        if stateChanged {
            boundTouchKeyboardState = scope.activate(tabID: host.keyboardTabID, perTab: touchStatePerTab)
        }
        if ownerChanged || stateChanged {
            // Ends the outgoing terminal's touches and republishes latched
            // modifiers to this one without rebuilding keys or effects.
            scope.keyboard.cancelInteraction(preservingModifiers: true)
        }
        reconcileTouchKeyboardHosting()
        updateTouchKeyboardInputSuppression()
        if usesFullTouchKeyboard && (touchSystemFloating || touchKeyboardPlacement == .docked) {
            // Release the overlay before reattaching its keyboard. A later
            // overlay teardown must not pull it back out of the input root.
            dismissFloatingTouchKeyboard()
            scope.input.attachKeyboard()
        }
    }

    /// Keys only beside a host's own toolbar. Under the glass bar, which carries
    /// the terminal keyboard's row, the keys keep every page.
    private var touchKeyboardRowMode: TerminalTouchKeyboardView.TextFieldMode {
        if glassBarCarriesTouchToolbar { return .toolbarCarried }
        return (host?.keyboardTouchKeyboardShowsToolbar ?? true) ? .off : .keysOnly
    }

    /// Glass Bar with Use with Terminal Keyboard: the docked terminal keyboard
    /// shows its keys, and the system toolbar sits above them in UIKit's accessory
    /// slot, which gets no keyboard backdrop of its own.
    var glassBarCarriesTouchToolbar: Bool {
        let manager = KeyboardToolbarManager.shared
        // UIKit lifts any accessory above the Duo's fold, away from the keys.
        return usesFullTouchKeyboard && host?.keyboardSoftwareKeyboardRequest == nil
            && touchKeyboardPlacement == .docked && !foldDocksTouchKeyboard
            && manager.toolbarStyle.resolved == .glassBar
            && manager.terminalKeyboardUsesGlassBar
    }

    /// The docked terminal keyboard, or its toolbar row alone once minimized, is
    /// glass over UIKit's keyboard backdrop, so that backdrop takes the theme's appearance.
    var touchKeyboardDocksGlass: Bool {
        glassBarCarriesTouchToolbar
            || ((usesFullTouchKeyboard || usesTouchKeyboardToolbar) && touchKeyboard?.docksGlass == true)
    }

    /// Modifiers held on the carried glass bar, for the next terminal keyboard key.
    var glassBarHeldModifiers: KeyModifiers {
        glassBarCarriesTouchToolbar ? (keyboardAccessory?.toolbarView.activeModifiers ?? []) : []
    }

    func consumeGlassBarModifiers() {
        keyboardAccessory?.toolbarView.clearOneShotModifiers()
    }

    private var carriedToolbarReload: DispatchWorkItem?

    /// The keys' height at the last carried reload.
    private var carriedToolbarReloadHeight: CGFloat?

    /// Once the keys settle at a new height. A reload re-hosts the keys, which
    /// then report their height again; reloading on each report never settles
    /// (a rotation made ten in a row). `force` when the bar has no window at all.
    private func scheduleCarriedToolbarReload(force: Bool = false) {
        let forced = force || carriedToolbarReloadForced
        carriedToolbarReloadForced = forced
        carriedToolbarReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.carriedToolbarReloadForced = false
            guard self.glassBarCarriesTouchToolbar, !self.pendingHandoffRefresh else { return }
            // Still moving: look again once it stops rather than drop the reload.
            guard !KeyboardTracker.shared.isKeyboardAnimating else {
                self.scheduleCarriedToolbarReload(force: forced)
                return
            }
            let height = self.touchKeyboardInputView?.intrinsicContentSize.height
            // UIKit may have attached the bar meanwhile; then only the height decides.
            let stillMissing = forced && self.keyboardAccessory?.window == nil
            guard stillMissing || height != self.carriedToolbarReloadHeight else { return }
            self.carriedToolbarReloadHeight = height
            self.host?.keyboardReloadInputViews()
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
        carriedToolbarReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    private var carriedToolbarReloadForced = false

    /// The host's answer to `keyboardTouchKeyboardShowsToolbar` changed.
    func refreshTouchKeyboardToolbarRow() {
        guard let keyboard = touchKeyboard else { return }
        let carried = glassBarCarriesTouchToolbar
        let barLeaves = glassBarWasCarried && !carried
        glassBarWasCarried = carried
        guard barLeaves else {
            keyboard.textFieldMode = touchKeyboardRowMode
            return
        }
        // Folding into the laptop pose: the bar's latched modifiers go with it. The
        // keyboard keeps its own and republishes them, now without the bar's.
        if let toolbar = keyboardAccessory?.toolbarView, !toolbar.activeModifiers.isEmpty {
            toolbar.clearModifiers()
        }
        keyboard.setTextFieldModePreservingModifiers(touchKeyboardRowMode)
    }
    private var glassBarWasCarried = false

    /// Give up the window's keyboard. The presentation stays mounted so an
    /// incoming terminal can take it over without a blank frame.
    func releaseTouchKeyboardState() {
        boundTouchKeyboardState = nil
        // Focus can move between panes without the keyboard hiding. A repeat
        // claim by the focused terminal is not a focus loss.
        let keepsFocus = host?.keyboardIsFirstResponder == true && host?.keyboardHostView.window != nil
        if !keepsFocus { reclaimFoldToolbar() }
        guard let scope = ownedTouchKeyboardScope else { return }
        scope.keyboard.cancelInteraction(preservingModifiers: true)
        scope.toolbarInput.isActive = false
        scope.owner = nil
        activeKeyboardModifiers = []
        onActiveKeyboardModifiersChanged?([])
        // A floating overlay is outside UIKit's input hierarchy. Remove it on
        // genuine focus loss, but let an incoming terminal claim it first.
        // Focus taken outside the app, as the system does during a Duo fold,
        // is asked back once. If the system takes it again, the card stays
        // until a key press reclaims it.
        DispatchQueue.main.async { [weak self, weak scope] in
            guard let scope, scope.owner == nil else { return }
            if let self, scope.overlay != nil,
               let host = self.host, host.keyboardLostFocusOutsideWindow {
                if self.focusReclaimArmed || DuoHingeEvents.generation != self.reclaimHingeGeneration {
                    self.focusReclaimArmed = false
                    self.reclaimHingeGeneration = DuoHingeEvents.generation
                    self.isReclaimingFocus = true
                    let reclaimed = host.keyboardBecomeFirstResponder()
                    self.isReclaimingFocus = false
                    if reclaimed { return }
                }
                scope.parkedOwner = self
                return
            }
            scope.dismissOverlay()
        }
    }

    /// A key press on a parked card returns focus to its host first.
    func reclaimParkedTouchKeyboard() -> Bool {
        guard let host, host.keyboardTouchKeyboardHost != nil else { return false }
        return host.keyboardIsFirstResponder || host.keyboardBecomeFirstResponder()
    }

    /// Undo a claim after UIKit refused the focus change. The outgoing
    /// responder kept first responder (app-transition or secure-draw
    /// preservation) and must keep presenting the keyboard, or its next
    /// input-view reload would fall back to Apple's keyboard.
    func abandonTouchKeyboardActivation() {
        let previous = displacedTouchKeyboardOwner
        displacedTouchKeyboardOwner = nil
        guard ownedTouchKeyboardScope != nil else { return }
        releaseTouchKeyboardState()
        if let previous, previous.host?.keyboardIsFirstResponder == true {
            previous.activateTouchKeyboardState()
        }
    }

    var touchKeyboardShouldHideAfterDocking: Bool {
        host?.keyboardIsFirstResponder == true && KeyboardTracker.shared.isHardwareKeyboard
    }

    private var touchKeyboardIsActive: Bool {
        host?.keyboardIsFirstResponder == true && usesFullTouchKeyboard
    }

    /// Shows the keyboard's Dictation page and starts listening, when the full
    /// terminal keyboard is on screen. Otherwise the caller opens the HUD.
    func openTouchKeyboardDictation() -> Bool {
        guard touchKeyboardIsActive, let touchKeyboard else { return false }
        return touchKeyboard.beginDictation()
    }

    func handleTouchKeyboardEvent(_ event: TerminalTouchKeyboardEvent) {
        switch event {
        case .modifiersChanged(let modifiers):
            // Full custom typing renders Shift into text. In toolbar-only
            // mode it must also modify keys arriving from a physical keyboard.
            let effective = (usesTouchKeyboardToolbar ? modifiers : modifiers.subtracting(.shift))
                .union(glassBarHeldModifiers)
            guard activeKeyboardModifiers != effective else { return }
            activeKeyboardModifiers = effective
            onActiveKeyboardModifiersChanged?(effective)
        case .dismiss:
            if usesTouchKeyboardToolbar && !toolbarOnlyMode {
                // A hardware-only toolbar's chevron explicitly requests keys.
                exitToolbarOnlyMode()
            } else { keyboardAccessory?.onDismissRequested?() }
        case .pinHidden: keyboardAccessory?.onPinHiddenRequested?()
        case .oneShotKeyboard: beginOneShotKeyboard()
        case .modifierDoublePress(let modifier): host?.keyboardSendModifierDoublePress(modifier)
        case .switchToSystemKeyboard: setTemporarySystemKeyboard(true)
        case .compose: host?.keyboardToggleCompose()
        case .paste: host?.keyboardPaste()
        case .tabs: keyboardAccessory?.onTabSwitcherRequested?()
        case .customize: keyboardAccessory?.onToolbarSettingsRequested?()
        case .toolbarAction(let action): keyboardAccessory?.toolbarView.keyPressed(action, modifiers: [])
        case .heightChanged:
            floatingKeyboardOverlay?.setNeedsLayout()
            // The self-sizing input root handles height changes on iPhone too.
            // Reloading input views here tears down the keyboard during each
            // drawer transition, flashing the entire typing surface.
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            // UIKit resizes the self-sizing keys but leaves an accessory above them
            // where it was. Keys-only has no drawer, so one reload once settled is safe.
            if glassBarCarriesTouchToolbar { scheduleCarriedToolbarReload() }
        case .placementRequested(let placement): setTouchKeyboardPlacement(placement)
        case .nativePlacementChanged(let placement):
            if touchSystemFloating {
                // UIKit already moved the input root. Reloading it here can
                // interrupt the native pinch/drag and restore a stale frame.
                // The card shows its own toolbar row; the dock takes the glass bar back.
                refreshTouchKeyboardToolbarRow()
                if placement == .docked, glassBarCarriesTouchToolbar, keyboardAccessory?.window == nil {
                    scheduleCarriedToolbarReload(force: true)
                }
                EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            } else if placement == .floating {
                setTouchKeyboardPlacement(.floating)
            }
        case .docked:
            guard host?.keyboardIsFirstResponder == true else { return }
            touchKeyboardRequestedWithHardware = false
            host?.keyboardSetSoftwareKeyboardRequested(false)
            host?.keyboardReloadInputViews()
            scheduleKeyboardToolbarUpdate(reason: "touchKeyboardDocked")
        }
    }

    private var touchKeyboardPlacement: TerminalTouchKeyboardModel.Placement {
        guard host?.keyboardHostView.window != nil else { return .docked }
        if touchSystemFloating {
            return touchKeyboardInputView?.isNativeFloating == true ? .floating : .docked
        }
        if foldDocksTouchKeyboard { return .docked }
        return currentTouchKeyboardState.placement
    }

    /// The Duo's laptop pose docks the card below the fold; unfolding restores the saved placement.
    private var foldDocksTouchKeyboard: Bool {
        guard let window = host?.keyboardHostView.window else { return false }
        return TerminalTouchKeyboardWindowState.forWindow(window).foldRegion != nil
    }

    private var hidesTouchKeyboardForHardware: Bool {
        touchKeyboardEnabled && !temporarilyUseSystemKeyboard
            && KeyboardTracker.shared.isHardwareKeyboard && !touchKeyboardRequestedWithHardware
    }

    private var touchKeyboardIsSelected: Bool {
        guard touchKeyboardEnabled, !temporarilyUseSystemKeyboard, touchKeyboard != nil else { return false }
        // A remote screen shows the keyboard whole or not at all: without
        // keys it keeps its own accessory.
        guard let requested = host?.keyboardSoftwareKeyboardRequest else { return true }
        return requested && !toolbarOnlyMode && !hidesTouchKeyboardForHardware
    }

    private var usesCompactTouchKeyboard: Bool {
        touchKeyboardIsSelected && (toolbarOnlyMode || hidesTouchKeyboardForHardware)
    }

    private var usesTouchKeyboardToolbar: Bool {
        usesCompactTouchKeyboard
            && (!hidesTouchKeyboardForHardware || SettingsStore.shared.value(Settings.KeyboardToolbar.showWithHardwareKeyboard))
            && shouldShowKeyboardToolbar && !keyboardToolbarCollapsed
            && !(toolbarOnlyMode && toolbarOnlyHidesToolbar)
            && host?.keyboardAIAgentOverlayActive != true
    }

    var usesFullTouchKeyboard: Bool {
        touchKeyboardIsSelected && !toolbarOnlyMode && !hidesTouchKeyboardForHardware
            && host?.keyboardAIAgentOverlayActive != true
    }

    /// The keyboard a remote host gives UIKit once keys are requested. Handed
    /// over ahead of the request, so Apple's keyboard never shows first.
    /// iPad hosts it in the retained controller, as a terminal does.
    var touchKeyboardInputOnRequest: (view: UIView?, controller: UIInputViewController?)? {
        guard touchKeyboardEnabled, !temporarilyUseSystemKeyboard, touchKeyboard != nil,
              host?.keyboardAIAgentOverlayActive != true else { return nil }
        // A hardware keyboard can still hide keys that were requested earlier.
        if host?.keyboardSoftwareKeyboardRequest == true, !usesFullTouchKeyboard { return nil }
        updateTouchKeyboardInputSuppression()
        if host?.keyboardHostView.traitCollection.userInterfaceIdiom == .pad {
            guard let controller = touchKeyboardController else { return nil }
            return (view: nil, controller: controller)
        }
        guard let view = touchKeyboardInputView else { return nil }
        return (view: view, controller: nil)
    }

    /// A remote host's request for keys changed. Moves the keyboard in or out
    /// of its input root or card; the host reloads its input views after.
    func softwareKeyboardRequestDidChange() {
        guard ownedTouchKeyboardScope != nil else { return }
        if host?.keyboardSoftwareKeyboardRequest == true {
            // An explicit request shows keys beside a hardware keyboard too.
            touchKeyboardRequestedWithHardware = KeyboardTracker.shared.isHardwareKeyboard
        } else {
            cancelTouchKeyboardInteraction()
            // The next request starts on the terminal keyboard again.
            temporarilyUseSystemKeyboard = false
        }
        updateTouchKeyboardInputSuppression()
        if usesFullTouchKeyboard && (touchSystemFloating || touchKeyboardPlacement == .docked) {
            dismissFloatingTouchKeyboard()
            touchKeyboardInputView?.attachKeyboard()
        }
        scheduleFloatingTouchKeyboardUpdate()
    }

    private var touchToolbarUsesPrimaryInputView: Bool {
        toolbarOnlyMode && toolbarOnlyUsesPrimaryInputView
    }

    private struct AppliedSuppression: Equatable {
        let input: ObjectIdentifier
        let suppressed: Bool
        let toolbar: Bool
        let toolbarActive: Bool
        let bottomInset: CGFloat
        let pinned: Bool
        let keyboardHost: ObjectIdentifier?
        let inputSuppressed: Bool
        let toolbarOnly: Bool
    }
    private var appliedSuppression: AppliedSuppression?

    private func updateTouchKeyboardInputSuppression() {
        guard let scope = touchKeyboardInputScope else { return }
        let toolbar = usesCompactTouchKeyboard
        // Suppress native placement before shrinking the content, otherwise a
        // toolbar layout can overwrite the saved floating position or dock it.
        let suppressed = !usesFullTouchKeyboard || (!touchSystemFloating && touchKeyboardPlacement == .floating)
        // UIKit polls the input-view getters hundreds of times a second; only
        // reapply when something changed.
        let applied = AppliedSuppression(input: ObjectIdentifier(scope.input), suppressed: suppressed, toolbar: toolbar,
            toolbarActive: usesTouchKeyboardToolbar, bottomInset: scope.toolbarInput.reservedBottomInset,
            pinned: keyboardPinnedHidden, keyboardHost: scope.keyboard.superview.map(ObjectIdentifier.init),
            inputSuppressed: scope.input.suppressed, toolbarOnly: scope.keyboard.isToolbarOnly)
        guard applied != appliedSuppression else { return }
        appliedSuppression = applied
        if suppressed { scope.input.setSuppressed(true) }
        scope.toolbarInput.isActive = usesTouchKeyboardToolbar
        scope.keyboard.setToolbarPresentation(only: toolbar,
            bottomInset: scope.toolbarInput.reservedBottomInset,
            showsRestore: usesTouchKeyboardToolbar, pinned: keyboardPinnedHidden)
        if !suppressed { scope.input.setSuppressed(false) }
        if usesTouchKeyboardToolbar { scope.toolbarInput.setNeedsLayout() }
        scheduleFloatingTouchKeyboardUpdate()
    }

    var inputViewController: UIInputViewController? {
        guard touchKeyboardEnabled, !temporarilyUseSystemKeyboard,
              !toolbarOnlyMode, host?.keyboardAIAgentOverlayActive != true,
              host?.keyboardHostView.traitCollection.userInterfaceIdiom == .pad else { return nil }
        updateTouchKeyboardInputSuppression()
        // Retain the custom keyboard's state without supplying its invisible
        // controller to UIKit during hardware-only input. The Dock-visible
        // system-keyboard path supplies nil here too. A software-keyboard
        // request or hardware disconnect restores this same retained controller.
        guard !hidesTouchKeyboardForHardware else { return nil }
        return touchKeyboardController
    }

    /// Includes the compact presentation: its modifiers and actions still
    /// belong to the custom keyboard, even while the typing rows are hidden.
    var usesTouchKeyboard: Bool { usesFullTouchKeyboard || usesTouchKeyboardToolbar }

    func cancelTouchKeyboardInteraction() { touchKeyboard?.cancelInteraction() }

    func dismissFloatingTouchKeyboard() {
        floatingKeyboardOverlay?.detach()
        floatingKeyboardOverlay = nil
    }

    /// Called after input-view/focus changes, once UIKit has released the old
    /// primary input view. Never reparent it while UIKit is querying inputView.
    func scheduleFloatingTouchKeyboardUpdate() {
        guard !floatingSyncScheduled else { return }
        floatingSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.floatingSyncScheduled = false
            self.updateFloatingTouchKeyboard()
        }
    }

    private func updateFloatingTouchKeyboard() {
        if usesTouchKeyboardToolbar {
            dismissFloatingTouchKeyboard()
            if touchKeyboardToolbarInputView?.window != nil { touchKeyboardToolbarInputView?.attachKeyboard() }
            return
        }
        if usesFullTouchKeyboard && (touchSystemFloating || touchKeyboardPlacement == .docked) {
            dismissFloatingTouchKeyboard()
            touchKeyboardInputView?.attachKeyboard()
        }
        guard !touchSystemFloating, usesFullTouchKeyboard, touchKeyboardPlacement == .floating,
              let host, host.keyboardIsFirstResponder,
              let window = host.keyboardHostView.window,
              window.windowScene?.activationState == .foregroundActive,
              let keyboard = touchKeyboard else {
            dismissFloatingTouchKeyboard()
            return
        }
        if floatingKeyboardOverlay?.window !== window { dismissFloatingTouchKeyboard() }
        if floatingKeyboardOverlay == nil, let scope = ownedTouchKeyboardScope {
            keyboard.removeFromSuperview()
            keyboard.translatesAutoresizingMaskIntoConstraints = true
            keyboard.isHidden = true
            keyboard.setFloating(true)
            let overlay = TerminalFloatingKeyboardOverlay(keyboard: keyboard, state: currentTouchKeyboardState)
            // The overlay outlives this owner; route through the scope.
            overlay.isHostActive = { [weak scope] in
                scope?.owner?.touchKeyboardIsActive == true || scope?.parkedOwner != nil
            }
            overlay.frame = window.bounds
            overlay.inputRegion = scope.inputRegion
            overlay.foldRegion = scope.foldRegion
            floatingKeyboardOverlay = overlay
            overlay.attach(to: window)
            // The retained keyboard can still have its old docked frame.
            // Size the card in its destination before making keys visible.
            overlay.setNeedsLayout()
            overlay.layoutIfNeeded()
            keyboard.isHidden = false
        }
        floatingKeyboardOverlay?.setNeedsLayout()
        keyboard.updateSuggestions()
    }

    private func setTouchKeyboardPlacement(_ placement: TerminalTouchKeyboardModel.Placement) {
        guard !touchSystemFloating, usesFullTouchKeyboard, host?.keyboardIsFirstResponder == true,
              host?.keyboardHostView.window != nil else { return }
        let state = currentTouchKeyboardState
        guard state.placement != placement, placement == .docked || !foldDocksTouchKeyboard else { return }
        host?.keyboardPrepareTouchKeyboardSwitch()
        state.placement = placement
        // Docking relinquishes a manual software-keyboard request when a
        // physical keyboard is attached; it must not expand an empty input set.
        if placement == .docked {
            touchKeyboardRequestedWithHardware = false
            host?.keyboardSetSoftwareKeyboardRequested(!KeyboardTracker.shared.isHardwareKeyboard)
        }
        applyTouchKeyboardPlacement()
    }

    /// Moves the keyboard between the input root and the card to match `touchKeyboardPlacement`.
    /// `reloadsInputViews: false` when a pending Duo handoff refresh owns the reload.
    private func applyTouchKeyboardPlacement(reloadsInputViews: Bool = true) {
        updateTouchKeyboardInputSuppression()
        if touchKeyboardPlacement == .docked {
            dismissFloatingTouchKeyboard()
            touchKeyboardInputView?.attachKeyboard()
        }
        if reloadsInputViews { host?.keyboardReloadInputViews() }
        scheduleFloatingTouchKeyboardUpdate()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    private func setTemporarySystemKeyboard(_ value: Bool) {
        host?.keyboardPrepareTouchKeyboardSwitch()
        touchKeyboard?.cancelInteraction()
        keyboardAccessory?.toolbarView.clearModifiers()
        dismissFloatingTouchKeyboard()
        temporarilyUseSystemKeyboard = value
        touchKeyboardRequestedWithHardware = !value && KeyboardTracker.shared.isHardwareKeyboard
        updateTouchKeyboardInputSuppression()
        if !value && (touchSystemFloating || touchKeyboardPlacement == .docked) { touchKeyboardInputView?.attachKeyboard() }
        scheduleFloatingTouchKeyboardUpdate()
        host?.keyboardReloadInputViews()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    private func reconcileTouchKeyboardHosting() {
        guard let keyboard = touchKeyboard, let input = touchKeyboardInputView,
              keyboard.usesSystemPlacement != touchSystemFloating else { return }
        host?.keyboardPrepareTouchKeyboardSwitch()
        if keyboard.usesSystemPlacement, input.isNativeFloating { currentTouchKeyboardState.placement = .floating }
        // Reconcile against the presentation itself: settings can change while
        // no terminal owns it, so a controller's cached setting is insufficient.
        input.setUsesSystemPlacement(touchSystemFloating)
        dismissFloatingTouchKeyboard()
        if touchSystemFloating || touchKeyboardPlacement == .docked {
            input.attachKeyboard()
        }
        updateTouchKeyboardInputSuppression()
    }

    private func configureTouchKeyboard(delegate: KeyboardButtonDelegate) {
        guard host?.keyboardTouchKeyboardHost != nil else { return }
        touchKeyboardDelegate = delegate
        updateTouchKeyboardReturnButton()
        let observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touchKeyboardSettingsDidChange() }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        let inactive = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissFloatingTouchKeyboard() }
        }
        let active = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFloatingTouchKeyboardUpdate() }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(inactive) })
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(active) })
    }

    private func touchKeyboardSettingsDidChange() {
        let enabled = SettingsStore.shared.value(Settings.Keyboard.touchEnabled)
        let systemFloating = Self.systemFloatingSetting
        let perTab = SettingsStore.shared.value(Settings.Keyboard.touchStatePerTab)
        let enabledChanged = enabled != touchKeyboardEnabled
        let changed = enabledChanged || systemFloating != touchSystemFloating || perTab != touchStatePerTab
        touchKeyboardEnabled = enabled
        touchSystemFloating = systemFloating
        touchStatePerTab = perTab
        guard changed else { return }
        // A scope change copies the key request into the new state; end an
        // open one-shot first so the request it set isn't carried along.
        if endOwnOneShotIntent(), host?.keyboardIsFirstResponder == true {
            reconcileWithHideIntent()
        }
        if enabledChanged {
            updateTouchKeyboardReturnButton()
            // Select the input implementation without requesting onscreen keys.
            // Only an explicit restore action should show the custom keyboard
            // while hardware is attached; toggling this setting also clears
            // any software-keyboard request from its previous activation.
            temporarilyUseSystemKeyboard = false
            touchKeyboardRequestedWithHardware = false
            keyboardAccessory?.toolbarView.clearModifiers()
        }
        // A terminal that is not presenting the keyboard reconciles against
        // the presentation when it next takes focus.
        guard host?.keyboardIsFirstResponder == true else { return }
        host?.keyboardPrepareTouchKeyboardSwitch()
        cancelTouchKeyboardInteraction()
        activateTouchKeyboardState()
        host?.keyboardReloadInputViews()
        scheduleFloatingTouchKeyboardUpdate()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// The custom keyboard owns its height; UIKit's last frame notification
    /// can still describe an earlier drawer position. Read the requested size
    /// directly during terminal layout, without querying UIKit's input window
    /// (which can still have its old frame or exclude the bottom safe area).
    /// Only while UIKit presents it: an unfocused split-view app keeps first
    /// responder after its keyboard hides. The latches cover overlay round trips.
    var dockedTouchKeyboardFrameInScreen: CGRect? {
        let tracker = KeyboardTracker.shared
        guard usesFullTouchKeyboard, touchKeyboardPlacement == .docked,
              tracker.isAnyInputViewPresented || tracker.isPreservingSoftwareKeyboardLayout,
              let host, host.keyboardIsFirstResponder,
              let window = host.keyboardHostView.window,
              let keyboard = touchKeyboard, !keyboard.isFloating,
              let input = touchKeyboardInputView else { return nil }
        // The system toolbar above the keys is part of the docked region.
        let toolbar = glassBarCarriesTouchToolbar && accessoryIsVisible
            ? (keyboardAccessory?.intrinsicContentSize.height ?? 0) : 0
        let height = input.intrinsicContentSize.height + toolbar
        guard height > 0 else { return nil }
        // iOS re-lays out an inactive app for snapshots and the keys measure
        // for the other orientation. Hold the height across a round trip while
        // the window keeps its size, anchored to where the window is now.
        let windowSize = window.bounds.size
        var dockedHeight = height
        if tracker.isPreservingSoftwareKeyboardForAppTransition,
           let held = heldDockedTouchKeyboardHeight, held.windowSize == windowSize {
            dockedHeight = held.height
        } else {
            heldDockedTouchKeyboardHeight = (height, windowSize)
        }
        let frame = window.convert(window.bounds, to: window.screen.coordinateSpace)
        return CGRect(x: frame.minX, y: frame.maxY - dockedHeight,
                      width: frame.width, height: dockedHeight)
    }

    private var heldDockedTouchKeyboardHeight: (height: CGFloat, windowSize: CGSize)?

    /// The way back from Apple's keyboard. Shown only while that switch is in effect.
    private func updateTouchKeyboardReturnButton() {
        guard let toolbar = keyboardAccessory?.toolbarView else { return }
        let shows = touchKeyboardEnabled && touchKeyboardDelegate != nil && temporarilyUseSystemKeyboard
        // Assigning rebuilds the row.
        guard shows != (toolbar.onTouchKeyboardRequested != nil) else { return }
        toolbar.onTouchKeyboardRequested = shows ? { [weak self] in self?.setTemporarySystemKeyboard(false) } : nil
    }

    #else
    // Keep the system keyboard on unsupported platforms even if an enabled
    // preference arrives through settings sync or config import.
    var inputViewController: UIInputViewController? { nil }
    var usesTouchKeyboard: Bool { false }
    private var usesTouchKeyboardToolbar: Bool { false }
    private var usesCompactTouchKeyboard: Bool { false }
    var usesFullTouchKeyboard: Bool { false }
    var touchKeyboardInputOnRequest: (view: UIView?, controller: UIInputViewController?)? { nil }
    func softwareKeyboardRequestDidChange() {}
    var dockedTouchKeyboardFrameInScreen: CGRect? { nil }
    func activateTouchKeyboardState() {}
    func releaseTouchKeyboardState() {}
    func refreshTouchKeyboardToolbarRow() {}
    var glassBarCarriesTouchToolbar: Bool { false }
    func abandonTouchKeyboardActivation() {}
    func cancelTouchKeyboardInteraction() {}
    func dismissFloatingTouchKeyboard() {}
    func scheduleFloatingTouchKeyboardUpdate() {}
    func openTouchKeyboardDictation() -> Bool { false }
    private func configureTouchKeyboard(delegate: KeyboardButtonDelegate) {}
    #endif

    #if os(visionOS) || targetEnvironment(macCatalyst)
    private var touchKeyboardRequestedWithHardware = false
    #endif

    var keyboardAccessory: KeyboardAccessoryView?
    #if os(visionOS)
    weak var externalToolbar: KeyboardToolbarView?
    #endif
    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// The accessory's toolbar row currently rests below the Duo's fold.
    private var foldToolbarMounted = false
    private lazy var foldToolbarHost = UIView()
    private var foldToolbarUpdateScheduled = false
    /// UIKit's last accessory query got nil because the fold hosts the row.
    private var accessoryWithheldForFold = false
    /// Set by teardown; a retired view can linger as first responder.
    private var foldToolbarRetired = false
    /// A Duo fold or display handoff owes one input-view reload; the reloads
    /// its handlers would make meanwhile fold into it.
    private var pendingHandoffRefresh = false
    private var handoffRefreshRequestedAt: Date?
    private var handoffRefreshFallbackScheduled = false
    /// The display a pending display change goes to (front or not).
    private var handoffDisplayTarget: Bool?
    /// A fold change waits for the host layout after it, which reflects the new fold region.
    private var handoffAwaitsFoldLayout = false
    /// Set by the first `hostDidLayout()`; remote-screen hosts never report one.
    private var hostReportsLayout = false
    private var lastLaidOutHostSize: CGSize?
    /// Confirmed window size per display (keyed by front): seeded by the first
    /// layout, then written only when a display refresh runs on layout evidence.
    private var laidOutSizeByDisplay: [Bool: CGSize] = [:]
    #endif

    var shouldShowKeyboardToolbar = false
    var activeKeyboardModifiers: KeyModifiers = []
    var onActiveKeyboardModifiersChanged: ((KeyModifiers) -> Void)?
    /// Window-scoped hide intent; hosts without a window (VNC) keep it local.
    var hideIntent: SoftwareKeyboardHideIntent {
        guard let window = host?.keyboardHideIntentWindow else { return localHideIntent }
        return SoftwareKeyboardHideIntentStore.shared.intent(for: window)
    }
    private var localHideIntent: SoftwareKeyboardHideIntent = .none
    private var usesHideIntent: Bool { host?.keyboardHideIntentWindow != nil }
    private func setHideIntent(_ intent: SoftwareKeyboardHideIntent, oneShotRequestState: AnyObject? = nil) {
        guard let window = host?.keyboardHideIntentWindow else {
            localHideIntent = intent
            return
        }
        SoftwareKeyboardHideIntentStore.shared.set(
            intent, for: window, oneShotOwner: self, oneShotRequestState: oneShotRequestState)
    }
    private var oneShotOwner: TerminalKeyboardAccessoryController? {
        SoftwareKeyboardHideIntentStore.shared.oneShotOwner(for: host?.keyboardHideIntentWindow)
            as? TerminalKeyboardAccessoryController
    }
    /// The window whose intent this host's open one-shot keyboard changed.
    private weak var oneShotWindow: UIWindow?
    /// Hosting choice captured when toolbar-only mode begins. A detached iPad
    /// keyboard must keep the toolbar in the accessory slot: replacing the
    /// floating keyboard with the accessory as its primary input view preserves
    /// the keyboard's large frame and leaves a cropped, immovable empty panel.
    /// Docked keyboards use the primary slot so the toolbar can sit flush with
    /// the screen edge without UIKit's accessory placeholder below it.
    private var toolbarOnlyUsesPrimaryInputView = true
    var toolbarOnlyMode = false {
        didSet {
            guard oldValue != toolbarOnlyMode else { return }
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    /// Toolbar-only mode with the row hidden too (persistentToolbar off):
    /// first responder is kept so hardware keys still work, but nothing is
    /// presented at the bottom edge. Never while pinned: terminal taps do not
    /// restore a pinned keyboard, so the chevron must stay reachable.
    private(set) var toolbarOnlyHidesToolbar = false {
        didSet {
            guard oldValue != toolbarOnlyHidesToolbar else { return }
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var keyboardPinnedHidden: Bool { hideIntent.isPinned }
    /// The toolbar row is on loan to a floating, draggable host.
    var toolbarIsDetachedFromScreenEdge = false {
        didSet {
            guard oldValue != toolbarIsDetachedFromScreenEdge else { return }
            updateBottomEdgeHomeGestureProtection()
        }
    }
    private(set) var bottomEdgeHomeGestureProtectionEnabled = false {
        didSet {
            guard oldValue != bottomEdgeHomeGestureProtectionEnabled else { return }
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var keyboardToolbarCollapsed = false {
        didSet {
            guard oldValue != keyboardToolbarCollapsed else { return }
            updateCollapsedKeyboardToolbarButtonVisibility()
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var dismissTapStartPoint: CGPoint?

    private var collapsedKeyboardToolbarButton: UIButton?
    private var collapsedKeyboardToolbarButtonCenter: CGPoint?
    private var collapsedKeyboardToolbarButtonWasMoved = false
    private let collapsedKeyboardToolbarButtonSize = CGSize(width: 46, height: 46)
    private var emptyInputViewHeightConstraint: NSLayoutConstraint?
    private lazy var emptyInputView: UIView = {
        let view = UIView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraint = view.heightAnchor.constraint(equalToConstant: 0)
        constraint.isActive = true
        emptyInputViewHeightConstraint = constraint
        return view
    }()

    private var keyboardStateDebounceTimer: Timer?
    private var keyboardStateTask: Task<Void, Never>?
    private var keyboardVisibilityTask: Task<Void, Never>?
    private var keyboardAnimationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(host: TerminalKeyboardAccessoryHost) {
        self.host = host
    }

    var activeToolbarView: KeyboardToolbarView? {
        #if os(visionOS)
        return externalToolbar
        #else
        return keyboardAccessory?.toolbarView
        #endif
    }

    func clearOneShotModifiers() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if usesTouchKeyboard {
            touchKeyboard?.clearOneShotModifiers()
            if glassBarCarriesTouchToolbar { consumeGlassBarModifiers() }
            return
        }
        #endif
        activeToolbarView?.clearOneShotModifiers()
    }

    private var presentedToolbarView: UIView? {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if usesTouchKeyboardToolbar { return touchKeyboardToolbarInputView }
        if foldToolbarMounted { return foldToolbarHost }
        #endif
        return keyboardAccessory
    }

    /// Actual accessory placement; each host gates this with its own toolbar
    /// presentation policy (VNC also has a per-connection visibility override).
    var keyboardAccessoryFrameInScreen: CGRect? {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return nil
        #else
        guard let host, host.keyboardIsFirstResponder,
              let window = host.keyboardHostView.window,
              let accessory = presentedToolbarView,
              let accessoryWindow = accessory.window,
              accessoryWindow.screen === window.screen,
              !accessoryWindow.isHidden, !accessory.isHidden,
              accessory.alpha > 0, !accessory.bounds.isEmpty else { return nil }
        return accessory.convert(accessory.bounds, to: accessoryWindow.screen.coordinateSpace)
        #endif
    }

    /// The toolbar row is the glass bar: the system keyboard's in Glass Bar style,
    /// or the terminal keyboard's when that setting carries the style to it.
    var toolbarShowsGlassBar: Bool {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return false
        #else
        let manager = KeyboardToolbarManager.shared
        guard manager.toolbarStyle == .glassBar else { return false }
        return !usesTouchKeyboard || manager.terminalKeyboardUsesGlassBar
        #endif
    }

    var reservesKeyboardToolbarAtBottom: Bool {
        if usesFullTouchKeyboard || (usesCompactTouchKeyboard && !usesTouchKeyboardToolbar) { return false }
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return false
        #else
        guard let host else { return false }
        return host.keyboardIsFirstResponder
            && !host.keyboardAIAgentOverlayActive
            && !keyboardToolbarCollapsed
            && !(toolbarOnlyMode && toolbarOnlyHidesToolbar)
            && (shouldShowKeyboardToolbar || toolbarOnlyMode)
        #endif
    }

    /// Minimum clearance kept between the toolbar row's bottom edge and the
    /// screen's bottom edge while "Extend Under Home Indicator" is off. Much
    /// smaller than the 34pt safe area on purpose: the row only needs enough
    /// distance that a home swipe started at the edge does not intercept a
    /// toolbar tap. Apple documents no size for the gesture's start region.
    private static let minimumHomeIndicatorClearance: CGFloat = 8

    /// The current reported keyboard frame only when some part of it is visible
    /// in this host window. UIKit can leave a nonempty final frame parked below
    /// the screen after a hide; that is not an active placement.
    private var visibleReportedKeyboardFrame: CGRect? {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return nil
        #else
        let keyboardFrame = EffectManager.shared.keyboardFrame
        guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return nil }
        guard let window = host?.keyboardHostView.window else { return nil }
        let hostFrame = window.convert(window.bounds, to: window.screen.coordinateSpace)
        let intersection = hostFrame.intersection(keyboardFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return keyboardFrame
        #endif
    }

    /// True when a connected hardware keyboard's reported keyboard region is
    /// fully accounted for by this accessory. Drawer rows can make that region
    /// tall enough to pass EffectManager's docked-software-keyboard heuristic,
    /// even though the accessory still rests at the screen edge.
    private var hardwareAccessoryOwnsKeyboardRegion: Bool {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return false
        #else
        guard KeyboardTracker.shared.isHardwareKeyboard else { return false }
        guard let keyboardFrame = visibleReportedKeyboardFrame else { return true }
        let accessoryHeight = max(
            presentedToolbarView?.bounds.height ?? 0,
            presentedToolbarView?.intrinsicContentSize.height ?? 0
        )
        let safeAreaBottom = host?.keyboardHostView.window?.safeAreaInsets.bottom ?? 0
        return keyboardFrame.height <= accessoryHeight + safeAreaBottom + 2
        #endif
    }

    /// Height the accessory holds open below the toolbar row so the row clears
    /// the home indicator. Derive this from the destination input mode, not the
    /// accessory's hosted frame: UIKit repositions that frame through transient
    /// values while restoring the software keyboard after an overlay, and using
    /// those values here briefly grew then shrank the accessory.
    private var bottomSafeAreaStripHeight: CGFloat {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return 0
        #else
        guard let host, !host.keyboardAccessoryOmitsBottomSafeAreaStrip else { return 0 }
        guard !PaddingManager.shared.extendUnderHomeIndicator else { return 0 }
        let safeBottom = host.keyboardHostView.window?.safeAreaInsets.bottom ?? 0
        guard safeBottom > 0 else { return 0 }
        let tracker = KeyboardTracker.shared
        let effectManager = EffectManager.shared
        let hasVisibleReportedKeyboardFrame = visibleReportedKeyboardFrame != nil
        let accessoryRestsAtScreenEdge: Bool
        if toolbarOnlyMode {
            // A primary toolbar is flush with the edge. The detached-iPad
            // compatibility path stays in the accessory slot and retains the
            // clearance UIKit supplies below that slot. No row, no strip.
            guard !toolbarOnlyHidesToolbar else { return 0 }
            accessoryRestsAtScreenEdge = toolbarOnlyUsesPrimaryInputView
        } else if usesTouchKeyboardToolbar || hardwareAccessoryOwnsKeyboardRegion {
            // A tall accessory-only region can otherwise look like a docked
            // software keyboard when drawer rows are open.
            accessoryRestsAtScreenEdge = true
        } else if tracker.isSoftwareKeyboardVisible || hasVisibleReportedKeyboardFrame {
            // A docked software keyboard carries the accessory above itself.
            // With an undocked/floating keyboard UIKit leaves the accessory at
            // the screen edge instead. The visibly-intersecting-frame check
            // includes compact and minimized keyboards below the tracker's
            // 120pt visibility threshold, while a true initial query and a
            // stale off-screen hide frame both stay out of this branch.
            // Reported placement takes precedence over a simultaneous hardware
            // keyboard attachment.
            accessoryRestsAtScreenEdge = !effectManager.isKeyboardDocked
        } else {
            // With neither keyboard nor a placement reported yet, this is the
            // initial full-software-keyboard query. Stay unreserved until its
            // placement arrives. Hardware-only zero-frame state was handled by
            // hardwareAccessoryOwnsKeyboardRegion above.
            accessoryRestsAtScreenEdge = false
        }
        guard accessoryRestsAtScreenEdge else { return 0 }
        return min(Self.minimumHomeIndicatorClearance, safeBottom)
        #endif
    }

    /// True while the strip is actually held open, so the toolbar row is not at
    /// the screen edge. Reads the applied value rather than recomputing, so it
    /// reports the geometry UIKit is currently laid out against.
    private var reservedToolbarBottomInset: CGFloat {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if usesTouchKeyboardToolbar { return touchKeyboardToolbarInputView?.reservedBottomInset ?? 0 }
        #endif
        return keyboardAccessory?.reservedBottomSafeArea ?? 0
    }

    var reservesBottomSafeAreaStrip: Bool { reservedToolbarBottomInset > 0 }

    /// Reconcile the reserved strip with the current setting, orientation, and
    /// keyboard state. Returns true when it moved.
    @discardableResult
    private func applyBottomSafeAreaStrip() -> Bool {
        let height = bottomSafeAreaStripHeight
        var changed = keyboardAccessory?.setReservedBottomSafeArea(height) ?? false
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if let toolbar = touchKeyboardToolbarInputView {
            changed = toolbar.setReservedBottomInset(height) || changed
        }
        updateTouchKeyboardInputSuppression()
        #endif
        if changed {
            let tracker = KeyboardTracker.shared
            let isDocked = EffectManager.shared.isKeyboardDocked
            Ghostty.logger.debug(
                "Reserved home-indicator strip: \(height, privacy: .public)pt (toolbarOnly=\(self.toolbarOnlyMode, privacy: .public), software=\(tracker.isSoftwareKeyboardVisible, privacy: .public), hardware=\(tracker.isHardwareKeyboard, privacy: .public), docked=\(isDocked, privacy: .public))"
            )
        }
        return changed
    }

    /// Re-apply the strip from outside UIKit's input-view queries. Unlike the
    /// `inputAccessoryView` path there is no query to ride along with, so it
    /// drives the reload itself.
    func refreshBottomSafeAreaStrip() {
        guard applyBottomSafeAreaStrip() else { return }
        updateBottomEdgeHomeGestureProtection()
        host?.keyboardReloadInputViews()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    var reservedKeyboardToolbarHeightAtBottom: CGFloat {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return 0
        #else
        guard reservesKeyboardToolbarAtBottom,
              let host else { return 0 }
        // Prefer the intrinsic height (toolbar + reserved strip) over `bounds`:
        // intrinsic moves in the same pass as the state that changes it, while
        // bounds lag one layout pass in both directions.
        let fallbackHeight = host.keyboardSizes.toolbar.height
            + reservedToolbarBottomInset
        if let intrinsicHeight = presentedToolbarView?.intrinsicContentSize.height,
           intrinsicHeight > 0 {
            return usesTouchKeyboardToolbar ? intrinsicHeight : max(fallbackHeight, intrinsicHeight)
        }
        let toolbarHeight = activeToolbarView?.bounds.height ?? 0
        if toolbarHeight > 0 {
            return max(fallbackHeight, toolbarHeight)
        }
        return fallbackHeight
        #endif
    }

    var defersBottomSystemGesture: Bool {
        bottomEdgeHomeGestureProtectionEnabled
            && host?.keyboardIsFirstResponder == true
    }

    var inputAccessoryView: UIView? {
        if host?.keyboardIsFirstResponder == true {
            KeyboardTracker.shared.setInputOwnerWindow(host?.keyboardHostView.window)
        }
        guard host != nil else { return nil }
        applyBottomSafeAreaStrip()
        let isVisible = accessoryIsVisible
        updateBottomEdgeHomeGestureProtection(accessoryIsVisible: isVisible)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        accessoryWithheldForFold = false
        scheduleFoldToolbarUpdate()
        #endif
        if usesFullTouchKeyboard {
            refreshTouchKeyboardToolbarRow()
            return glassBarCarriesTouchToolbar && accessoryIsVisible ? keyboardAccessory : nil
        }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if usesCompactTouchKeyboard {
            // The same keyboard may arrive keys-only from the carried glass bar.
            refreshTouchKeyboardToolbarRow()
            return usesTouchKeyboardToolbar && !touchToolbarUsesPrimaryInputView ? touchKeyboardToolbarInputView : nil
        }
        #endif
        // In the normal toolbar-only path the accessory serves as the primary
        // input view instead (see `inputView`); handing it out from both slots
        // in one reload would let the second container steal it from the first.
        // A detached iPad keyboard deliberately keeps the pre-merge
        // accessory-over-empty-input arrangement to avoid inheriting the
        // floating keyboard's oversized frame.
        guard !toolbarOnlyMode || !toolbarOnlyUsesPrimaryInputView else { return nil }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if isVisible && foldToolbarFrame != nil {
            accessoryWithheldForFold = true
            return nil
        }
        reclaimFoldToolbar()
        #endif
        return isVisible ? keyboardAccessory : nil
    }

    private var accessoryIsVisible: Bool {
        guard let host else { return false }
        return shouldShowKeyboardToolbar
            && !host.keyboardAIAgentOverlayActive
            && !keyboardToolbarCollapsed
            && !(toolbarOnlyMode && toolbarOnlyHidesToolbar)
    }

    /// In toolbar-only mode the toolbar is the primary input view, not an
    /// accessory above an empty one. UIKit lays a primary input view flush with
    /// the screen's bottom edge, like the system keyboard. An accessory over an
    /// empty input view is not flush: UIKit appends a version-dependent
    /// `_UIRemoteKeyboardPlaceholderView` below it (17pt on iOS 26.3, 0 on
    /// 26.5) and only grows the accessory upward, so no reservation can move
    /// the row past that strip.
    var inputView: UIView? {
        if host?.keyboardIsFirstResponder == true {
            KeyboardTracker.shared.setInputOwnerWindow(host?.keyboardHostView.window)
        }
        // UIKit does not specify whether it asks for inputView or
        // inputAccessoryView first. Publish the destination-mode intrinsic
        // height from both paths so toolbar-only entry is correct in one pass.
        applyBottomSafeAreaStrip()
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        updateBottomEdgeHomeGestureProtection()
        if usesFullTouchKeyboard || usesCompactTouchKeyboard { refreshTouchKeyboardToolbarRow() }
        if usesTouchKeyboardToolbar && touchToolbarUsesPrimaryInputView {
            return touchKeyboardToolbarInputView
        }
        // Normal iPad hardware input uses the system path with no replacement
        // view or controller. Explicit hide intent and other platforms retain
        // the empty input view that suppresses the system software keyboard.
        if hidesTouchKeyboardForHardware {
            let usesSystemHardwareInput = host?.keyboardHostView.traitCollection.userInterfaceIdiom == .pad
                && !toolbarOnlyMode
            return usesSystemHardwareInput ? nil : emptyInputView
        }
        if usesFullTouchKeyboard {
            // Reuse the retained iPad root when software input is requested
            // or the hardware keyboard disconnects.
            return host?.keyboardHostView.traitCollection.userInterfaceIdiom == .pad ? nil : touchKeyboardInputView
        }
        if usesCompactTouchKeyboard { return emptyInputView }
        #endif
        guard toolbarOnlyMode else { return nil }
        guard toolbarOnlyUsesPrimaryInputView else { return emptyInputView }
        guard let host,
              let accessory = keyboardAccessory,
              shouldShowKeyboardToolbar,
              !toolbarOnlyHidesToolbar,
              !host.keyboardAIAgentOverlayActive,
              !keyboardToolbarCollapsed else {
            // Toolbar hidden (collapsed to the floating button, or an overlay
            // owns the screen) — keep suppressing the system keyboard.
            return emptyInputView
        }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        reclaimFoldToolbar()
        #endif
        return accessory
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// UIKit lifts every input accessory above the Duo's fold, away from the
    /// system keys. Rest the toolbar just below the fold instead, on the keys,
    /// in the host window. nil where UIKit's placement stays in charge.
    private var foldToolbarFrame: CGRect? {
        let tracker = KeyboardTracker.shared
        guard !foldToolbarRetired,
              let host, host.keyboardIsFirstResponder, !usesTouchKeyboard, !toolbarOnlyMode,
              tracker.isSoftwareKeyboardVisible, !tracker.isHardwareKeyboard,
              let accessory = keyboardAccessory,
              let window = host.keyboardHostView.window,
              let fold = TerminalTouchKeyboardWindowState.forWindow(window).foldRegion,
              // A predictive bar would occupy the space below the fold.
              (host.keyboardHostView as? UITextInputTraits)?.autocorrectionType == .no
        else { return nil }
        let row = host.keyboardSizes.toolbar.height
        // Drawer rows stack above the main row and may reach over the fold.
        let height = max(row, accessory.intrinsicContentSize.height)
        return CGRect(x: window.bounds.minX, y: fold.maxY + 2 + row - height,
                      width: window.bounds.width, height: height)
    }

    /// UIKit releases a withdrawn accessory during the input-view reload, so
    /// mounting waits until that reload has returned.
    private func scheduleFoldToolbarUpdate() {
        guard !foldToolbarRetired, !foldToolbarUpdateScheduled else { return }
        foldToolbarUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.foldToolbarUpdateScheduled = false
            self.updateFoldToolbar()
        }
    }

    private func updateFoldToolbar() {
        guard accessoryIsVisible, let frame = foldToolbarFrame,
              let accessory = keyboardAccessory,
              let window = host?.keyboardHostView.window else {
            reclaimFoldToolbar()
            // The query that withheld the accessory lost the race; ask for it again.
            if accessoryWithheldForFold, !pendingHandoffRefresh, host?.keyboardIsFirstResponder == true,
               KeyboardTracker.shared.isSoftwareKeyboardVisible {
                accessoryWithheldForFold = false
                host?.keyboardReloadInputViews()
            }
            return
        }
        let container = foldToolbarHost
        if container.superview !== window {
            container.removeFromSuperview()
            window.addSubview(container)
        }
        if !foldToolbarMounted {
            let toolbar = accessory.lendToolbar()
            container.addSubview(toolbar)
            NSLayoutConstraint.activate([
                toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                toolbar.topAnchor.constraint(equalTo: container.topAnchor),
                toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            foldToolbarMounted = true
            // UIKit still shows the emptied accessory; let it re-query (a pending
            // handoff refresh does that once settled).
            if accessory.window != nil, !pendingHandoffRefresh { host?.keyboardReloadInputViews() }
        }
        window.bringSubviewToFront(container)
        guard container.frame != frame else { return }
        container.frame = frame
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// Return the row before UIKit's slot shows the accessory again.
    private func reclaimFoldToolbar() {
        guard foldToolbarMounted else { return }
        foldToolbarMounted = false
        keyboardAccessory?.reclaimToolbar()
        foldToolbarHost.removeFromSuperview()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    /// One Duo fold or display handoff gets one input-view reload, once the
    /// terminal has laid out for the destination and the keyboard has settled.
    /// Reloading while UIKit still lays out the old pose can leave the toolbar
    /// in that pose's place.
    private func requestHandoffRefresh(display: Bool) {
        guard DuoHingeEvents.hasHinge, !foldToolbarRetired else { return }
        if display {
            // Duplicates for one destination keep its evidence; a new or reversed
            // destination starts over, timeout included.
            let target = DuoHingeEvents.isFrontDisplay
            if handoffDisplayTarget != target {
                handoffDisplayTarget = target
                handoffRefreshRequestedAt = Date()
            }
        } else {
            handoffAwaitsFoldLayout = true
            // A fold that leaves the terminal's bounds alone brings no layout on its own.
            host?.keyboardHostView.setNeedsLayout()
        }
        if !pendingHandoffRefresh { handoffRefreshRequestedAt = Date() }
        pendingHandoffRefresh = true
        // Consumed by the host's next fitting layout, the keyboard settling, or
        // the fallback. The terminal may already have laid out for the display.
        consumeHandoffRefreshSoon()
        scheduleHandoffRefreshFallback()
    }

    /// For hosts without a layout hook (remote screens), and settles that post
    /// nothing. Past 1.5 s it stops waiting on the layout, never on the latches.
    private func scheduleHandoffRefreshFallback() {
        guard !handoffRefreshFallbackScheduled else { return }
        handoffRefreshFallbackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.handoffRefreshFallbackScheduled = false
            guard self.pendingHandoffRefresh else { return }
            let overdue = self.handoffRefreshRequestedAt.map { Date().timeIntervalSince($0) > 1.5 } ?? true
            self.consumeHandoffRefreshIfReady(skipsLayoutWait: overdue)
            // In the background, activation picks it up instead.
            if self.pendingHandoffRefresh, UIApplication.shared.applicationState == .active {
                self.scheduleHandoffRefreshFallback()
            }
        }
    }

    private func consumeHandoffRefreshIfReady(skipsLayoutWait: Bool = false) {
        guard pendingHandoffRefresh else { return }
        guard let host, host.keyboardIsFirstResponder, let window = host.keyboardHostView.window else {
            // Nothing presents a toolbar to refresh.
            clearHandoffRefresh()
            return
        }
        let tracker = KeyboardTracker.shared
        // Hard guards: a held or uncommitted keyboard frame would place the toolbar for the old pose.
        guard UIApplication.shared.applicationState == .active, !tracker.isKeyboardAnimating,
              !tracker.isPreservingSoftwareKeyboardLayout, !tracker.isAppTransitionKeyboardCommitPending
        else { return }
        // Judged from the latest layout only, which must be of the current window.
        let latest = lastLaidOutHostSize
        let sized = window.windowScene.map { $0.coordinateSpace.bounds.size == window.bounds.size } ?? true
        let current = latest == window.bounds.size && sized
        let onDisplay = handoffDisplayTarget.map { target in latest.map { isLayout($0, for: target) } ?? false } ?? true
        let laidOut = !hostReportsLayout || (current && onDisplay && !handoffAwaitsFoldLayout)
        guard laidOut || skipsLayoutWait else { return }
        if laidOut, hostReportsLayout, let target = handoffDisplayTarget, let latest {
            laidOutSizeByDisplay[target] = latest
        }
        clearHandoffRefresh()
        // The row may have to move between UIKit's slot and the fold host.
        if foldToolbarFrame == nil { reclaimFoldToolbar() }
        // This reload places a carried bar for the keys' height now; the height
        // the rehosted keys report next must not reload it again.
        if glassBarCarriesTouchToolbar {
            carriedToolbarReloadHeight = touchKeyboardInputView?.intrinsicContentSize.height
        }
        host.keyboardReloadInputViews()
        scheduleFoldToolbarUpdate()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
    }

    private func clearHandoffRefresh() {
        pendingHandoffRefresh = false
        handoffDisplayTarget = nil
        handoffAwaitsFoldLayout = false
    }
    #endif

    /// Where the toolbar is showing right now, for its settings to preview.
    private var toolbarSurface: ToolbarPreviewSurface {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // The terminal keyboard carries the toolbar as its own row, except
        // beside a remote screen's floating bar, where it shows keys only.
        let onTerminalKeyboard = usesFullTouchKeyboard || usesTouchKeyboardToolbar
        if let floating = host?.keyboardGlassBarIsFloating {
            return !floating && onTerminalKeyboard ? .terminalKeyboard : .glassBar(floating: floating)
        }
        return onTerminalKeyboard ? .terminalKeyboard : .systemKeyboard
        #else
        // A Mac's only toolbar is a remote screen's bar.
        if let floating = host?.keyboardGlassBarIsFloating { return .glassBar(floating: floating) }
        return .systemKeyboard
        #endif
    }

    /// Empty primary input view used when a host wants the accessory docked
    /// without presenting the system software keyboard. This does not mutate
    /// the controller's user-driven persistent-toolbar state.
    var accessoryOnlyInputView: UIView {
        _ = emptyInputView
        emptyInputViewHeightConstraint?.constant = 0
        return emptyInputView
    }

    func setupKeyboard(delegate: KeyboardButtonDelegate) {
        guard let host else { return }

        #if !os(visionOS)
        keyboardAccessory = KeyboardAccessoryView(sizes: host.keyboardSizes)
        keyboardAccessory?.toolbarView.context = host.keyboardToolbarContext
        keyboardAccessory?.delegate = delegate

        keyboardAccessory?.onModifiersChanged = { [weak self] modifiers in
            self?.activeKeyboardModifiers = modifiers
            self?.onActiveKeyboardModifiersChanged?(modifiers)
            Ghostty.logger.debug("TerminalView: Toolbar modifiers changed to rawValue: \(modifiers.rawValue)")
        }

        keyboardAccessory?.onDismissRequested = { [weak self] in
            guard let self else { return }
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            // On a remote screen the key only toggles the keys; its toolbar
            // moves to the HUD without them.
            if let requested = self.host?.keyboardSoftwareKeyboardRequest {
                if self.toolbarOnlyMode {
                    self.exitToolbarOnlyMode()
                } else {
                    self.host?.keyboardSetSoftwareKeyboardRequested(!requested)
                }
                return
            }
            #endif
            if self.toolbarOnlyMode {
                self.exitToolbarOnlyMode()
            } else if self.hideIntent.isOneShot {
                self.finishOneShotKeyboard()
            } else if self.usesHideIntent || SettingsStore.shared.value(Settings.KeyboardToolbar.persistent) {
                self.setHideIntent(.hidden(pinned: false))
                self.enterToolbarOnlyMode(pinned: false)
            } else {
                // Hosts without a hide-intent window (a remote screen on Mac)
                // keep the legacy resign path.
                _ = self.host?.keyboardResignFirstResponder()
            }
        }

        keyboardAccessory?.onCollapseRequested = { [weak self] in
            self?.collapseKeyboardToolbar()
        }

        keyboardAccessory?.onPinHiddenRequested = { [weak self] in
            guard let self else { return }
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            // A remote screen has no pinned state; there a long press floats the toolbar.
            if self.host?.keyboardSoftwareKeyboardRequest != nil {
                self.host?.keyboardToggleToolbarFloating()
                return
            }
            #endif
            if self.keyboardPinnedHidden {
                self.exitToolbarOnlyMode()
            } else {
                self.setHideIntent(.hidden(pinned: true))
                self.enterToolbarOnlyMode(pinned: true)
            }
        }

        keyboardAccessory?.onOneShotKeyboardRequested = { [weak self] in
            self?.beginOneShotKeyboard()
        }

        keyboardAccessory?.onTabSwitcherRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .showTabSwitcher, object: host.keyboardHostView)
        }

        keyboardAccessory?.onToolbarSettingsRequested = { [weak self] in
            guard let self, let host = self.host else { return }
            NotificationCenter.default.post(
                name: .showToolbarSettings, object: host.keyboardHostView,
                userInfo: [ToolbarPreviewSurface.userInfoKey: self.toolbarSurface])
        }

        keyboardAccessory?.onPasteRequested = { [weak self] in
            self?.host?.keyboardPaste()
        }

        keyboardAccessory?.onToggleFullScreenRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleFullScreen, object: host.keyboardHostView)
        }

        keyboardAccessory?.onToggleTabBarRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleTabBar, object: host.keyboardHostView)
        }

        keyboardAccessory?.onChoosePaneToZoomRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .choosePaneToZoom, object: host.keyboardHostView)
        }

        keyboardAccessory?.onTogglePaneZoomRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .togglePaneZoom, object: host.keyboardHostView)
        }

        keyboardAccessory?.onNewConnectionRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .newTab, object: host.keyboardHostView)
        }

        keyboardAccessory?.onAppSettingsRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .openSettings, object: host.keyboardHostView)
        }

        keyboardAccessory?.onComposeRequested = { [weak self] in
            self?.host?.keyboardToggleCompose()
        }

        keyboardAccessory?.onToggleMouseCaptureRequested = { [weak self] in
            self?.host?.keyboardToggleMouseCapture()
        }

        keyboardAccessory?.onBrightnessBoostRequested = { [weak self] in
            self?.host?.keyboardToggleBrightnessHUD()
        }

        keyboardAccessory?.onModifierDoublePressRequested = { [weak self] modifier in
            self?.host?.keyboardSendModifierDoublePress(modifier)
        }

        keyboardAccessory?.onTypePasswordRequested = { [weak self] pressingReturn in
            self?.host?.keyboardTypePassword(pressingReturn: pressingReturn)
        }

        keyboardAccessory?.onAIAgentRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleAIAgent, object: host.keyboardHostView)
        }

        keyboardAccessory?.onClipboardManagerRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleClipboardManager, object: host.keyboardHostView)
        }

        keyboardAccessory?.onFileManagerRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleFileManager, object: host.keyboardHostView)
        }

        keyboardAccessory?.onHTTPCaptureRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleHTTPCapture, object: host.keyboardHostView)
        }

        keyboardAccessory?.onLayoutInvalidated = { [weak self] in
            self?.refreshKeyboardLayoutAfterAccessoryChange()
        }

        let hwToolbarObserver = NotificationCenter.default.addObserver(
            forName: .keyboardToolbarHardwareSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleKeyboardToolbarUpdate(reason: "hardwareToolbarSetting")
            }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(hwToolbarObserver) })

        // The toolbar size is a setting per display, so either changing resizes the keys.
        for name in [Notification.Name.settingsDidChange, .duoDisplayDidChange] {
            let sizeObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    #if !os(visionOS) && !targetEnvironment(macCatalyst)
                    // Before resizing, so the reload that resize asks for joins the handoff's.
                    if note.name == .duoDisplayDidChange, self?.host?.keyboardIsFirstResponder == true {
                        self?.requestHandoffRefresh(display: true)
                    }
                    #endif
                    // A display change always resizes: this observer alone answers it.
                    guard let self, let host = self.host, let toolbar = self.keyboardAccessory?.toolbarView,
                          note.name == .duoDisplayDidChange
                            || toolbar.rowHeight != host.keyboardSizes.toolbar.height else { return }
                    host.keyboardUpdateAccessoryForTraitCollection()
                }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(sizeObserver) })
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let foldObserver = NotificationCenter.default.addObserver(
            forName: .terminalFoldRegionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let host = self.host, host.keyboardIsFirstResponder,
                      notification.object as? UIWindow === host.keyboardHostView.window else { return }
                // Moves the toolbar between UIKit's accessory slot and the fold, once settled.
                self.requestHandoffRefresh(display: false)
                if self.usesFullTouchKeyboard, !self.touchSystemFloating,
                   self.currentTouchKeyboardState.placement == .floating,
                   (self.floatingKeyboardOverlay != nil) != (self.touchKeyboardPlacement == .floating) {
                    // Entering or leaving the laptop pose; a moved fold keeps the placement.
                    // The keyboard moves now; the handoff refresh reloads.
                    host.keyboardPrepareTouchKeyboardSwitch()
                    self.applyTouchKeyboardPlacement(reloadsInputViews: !self.pendingHandoffRefresh)
                }
            }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(foldObserver) })
        let activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingHandoffRefresh else { return }
                self.consumeHandoffRefreshIfReady()
                if self.pendingHandoffRefresh { self.scheduleHandoffRefreshFallback() }
            }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(activeObserver) })
        #endif

        let homeIndicatorObserver = NotificationCenter.default.addObserver(
            forName: .terminalBottomInsetInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBottomSafeAreaStrip() }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(homeIndicatorObserver) })
        #endif

        configureTouchKeyboard(delegate: delegate)

        let tracker = KeyboardTracker.shared
        let showWithHardware = SettingsStore.shared.value(Settings.KeyboardToolbar.showWithHardwareKeyboard)
        let initialShowToolbar = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
        shouldShowKeyboardToolbar = initialShowToolbar
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        let initialToolbarVisible = shouldShowKeyboardToolbar
        Ghostty.logger.debug(
            "TerminalView.setupKeyboard: Initial state - isHardware=\(tracker.isHardwareKeyboard), softwareVisible=\(tracker.isSoftwareKeyboardVisible), showToolbar=\(initialToolbarVisible)"
        )

        let initialHardwareState = tracker.isHardwareKeyboard
        keyboardStateTask = Task { @MainActor [weak self] in
            var previousHardwareState = initialHardwareState
            for await connected in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                guard let self else { break }
                if connected != previousHardwareState {
                    self.touchKeyboardRequestedWithHardware = false
                    self.cancelTouchKeyboardInteraction()
                    previousHardwareState = connected
                }
                #if !os(visionOS) && !targetEnvironment(macCatalyst)
                self.updateTouchKeyboardInputSuppression()
                #endif
                self.scheduleFloatingTouchKeyboardUpdate()
                self.host?.keyboardReloadInputViews()
                self.scheduleKeyboardToolbarUpdate(reason: "hardware")
            }
        }

        keyboardVisibilityTask = Task { @MainActor [weak self] in
            var previousVisibility = KeyboardTracker.shared.isSoftwareKeyboardVisible
            for await visible in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                guard let self else { break }
                #if !os(visionOS) && !targetEnvironment(macCatalyst)
                if previousVisibility && !visible && self.host?.keyboardIsFirstResponder == true
                    && self.touchKeyboardPlacement != .floating && KeyboardTracker.shared.isHardwareKeyboard && self.touchKeyboardRequestedWithHardware {
                    self.touchKeyboardRequestedWithHardware = false
                    self.host?.keyboardReloadInputViews()
                }
                #endif
                previousVisibility = visible
                self.scheduleKeyboardToolbarUpdate(reason: "softwareVisibility")
                #if !os(visionOS) && !targetEnvironment(macCatalyst)
                self.scheduleFoldToolbarUpdate()
                #endif
            }
        }

        keyboardAnimationTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                if !animating {
                    self.host?.keyboardDidFinishAnimationLayout()
                    #if !os(visionOS) && !targetEnvironment(macCatalyst)
                    self.consumeHandoffRefreshIfReady()
                    #endif
                }
            }
        }

        host.keyboardHostView.registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { (view: UIView, _: UITraitCollection) in
            Task { @MainActor in
                guard let terminalHost = view as? TerminalKeyboardAccessoryHost else { return }
                terminalHost.keyboardUpdateAccessoryForTraitCollection()
            }
        }

        _ = host.keyboardBecomeFirstResponder()
        host.keyboardReloadInputViews()

        KeybindManager.shared.keybindsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.host?.keyboardInvalidateKeyCommands()
                    self?.host?.keyboardReloadInputViews()
                }
            }
            .store(in: &cancellables)

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        EffectManager.shared.keyboardEnvironmentDidChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // A Duo handoff's one reload picks this change up.
                    guard let self, !self.pendingHandoffRefresh else { return }
                    self.host?.keyboardReloadInputViews()
                }
            }
            .store(in: &cancellables)

        EffectManager.shared.keyboardStateDidChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateCollapsedKeyboardToolbarButtonLayout()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    func setupCollapsedKeyboardToolbarButton() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let host else { return }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.bounds = CGRect(origin: .zero, size: collapsedKeyboardToolbarButtonSize)
        button.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.62)
        button.tintColor = .label
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.55).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.alpha = 0
        button.isHidden = true
        button.accessibilityLabel = String(localized: "Restore Keyboard Toolbar")

        let imageConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        button.setImage(UIImage(systemName: "keyboard", withConfiguration: imageConfig), for: .normal)
        button.addTarget(self, action: #selector(restoreCollapsedKeyboardToolbar), for: .touchUpInside)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleCollapsedKeyboardToolbarButtonPan(_:)))
        button.addGestureRecognizer(panGesture)

        host.keyboardHostView.addSubview(button)
        collapsedKeyboardToolbarButton = button
        #endif
    }

    func tearDown() {
        // A closing opener ends its one-shot keyboard rather than leave the
        // shared key request behind.
        _ = endOwnOneShotIntent()
        dismissFloatingTouchKeyboard()
        releaseTouchKeyboardState()
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // An already queued update then finds no fold frame and only reclaims.
        foldToolbarRetired = true
        accessoryWithheldForFold = false
        clearHandoffRefresh()
        reclaimFoldToolbar()
        #endif
        keyboardStateDebounceTimer?.invalidate()
        keyboardStateDebounceTimer = nil
        keyboardStateTask?.cancel()
        keyboardStateTask = nil
        keyboardVisibilityTask?.cancel()
        keyboardVisibilityTask = nil
        keyboardAnimationTask?.cancel()
        keyboardAnimationTask = nil
        cancellables.removeAll()
    }

    func setAIAgentOverlayActive(_ active: Bool) {
        if active { dismissFloatingTouchKeyboard() } else { scheduleFloatingTouchKeyboardUpdate() }
        if active { cancelTouchKeyboardInteraction() }
        updateCollapsedKeyboardToolbarButtonVisibility()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        host?.keyboardReloadInputViews()
    }

    func enterToolbarOnlyMode(pinned: Bool = false) {
        dismissFloatingTouchKeyboard()
        touchKeyboardRequestedWithHardware = false
        cancelTouchKeyboardInteraction()
        _ = emptyInputView
        emptyInputViewHeightConstraint?.constant = 0
        toolbarOnlyHidesToolbar = usesHideIntent
            && !pinned
            && !SettingsStore.shared.value(Settings.KeyboardToolbar.persistent)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Snapshot before changing the input set. Once the software keyboard
        // starts hiding, its placement frame is no longer reliable enough to
        // tell whether UIKit is tearing down a detached keyboard.
        let hasDetachedKeyboardPlacement = (!touchKeyboardIsSelected || touchSystemFloating)
            && visibleReportedKeyboardFrame != nil
            && !EffectManager.shared.isKeyboardDocked
            && !hardwareAccessoryOwnsKeyboardRegion
        toolbarOnlyUsesPrimaryInputView = !hasDetachedKeyboardPlacement
        #else
        toolbarOnlyUsesPrimaryInputView = true
        #endif
        toolbarOnlyMode = true
        host?.keyboardSetSoftwareKeyboardRequested(false)
        keyboardAccessory?.setDismissButtonShowsRestore(true)
        keyboardAccessory?.setDismissButtonPinned(pinned)
        applyBottomSafeAreaStrip()
        updateBottomEdgeHomeGestureProtection()
        host?.keyboardReloadInputViews()
    }

    func exitToolbarOnlyMode() {
        setHideIntent(.none)
        leaveToolbarOnlyMode()
    }

    /// Shows the keyboard without touching the window's hide intent.
    private func leaveToolbarOnlyMode() {
        touchKeyboardRequestedWithHardware = KeyboardTracker.shared.isHardwareKeyboard
        keyboardAccessory?.setDismissButtonPinned(false)
        toolbarOnlyMode = false
        toolbarOnlyHidesToolbar = false
        host?.keyboardSetSoftwareKeyboardRequested(true)
        keyboardAccessory?.setDismissButtonShowsRestore(false)
        applyBottomSafeAreaStrip()
        updateBottomEdgeHomeGestureProtection()
        host?.keyboardReloadInputViews()
        toolbarOnlyUsesPrimaryInputView = true
    }

    /// Shows the keys for one input, from a hidden keyboard or from the
    /// toolbar a hardware keyboard leaves. Visible keys or a remote screen
    /// leave this a no-op.
    func beginOneShotKeyboard() {
        // A delayed sequence can finish after focus moved to another terminal.
        guard usesHideIntent, host?.keyboardIsFirstResponder == true else { return }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard host?.keyboardSoftwareKeyboardRequest == nil else { return }
        let showsHardwareToolbarOnly = !toolbarOnlyMode && hidesTouchKeyboardForHardware
        #else
        let showsHardwareToolbarOnly = false
        #endif
        let intent = hideIntent
        let previous: SoftwareKeyboardHideIntent
        if toolbarOnlyMode, intent.isHidden {
            previous = intent
        } else if showsHardwareToolbarOnly, intent == .none {
            previous = .none
        } else {
            return
        }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let requestState: AnyObject? = currentTouchKeyboardState
        #else
        let requestState: AnyObject? = nil
        #endif
        setHideIntent(.oneShot(returningTo: previous), oneShotRequestState: requestState)
        oneShotWindow = host?.keyboardHideIntentWindow
        // Same path as the chevron restoring keys in either state.
        leaveToolbarOnlyMode()
    }

    /// Restores the intent a window's one-shot keyboard replaced and drops
    /// the key request it set. Returns the restored intent, nil if none was open.
    private func endOneShotIntent(in window: UIWindow) -> SoftwareKeyboardHideIntent? {
        let store = SoftwareKeyboardHideIntentStore.shared
        guard case .oneShot(let previous) = store.intent(for: window) else { return nil }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Hand the keys back to a hardware keyboard, as docking does.
        (store.oneShotRequestState(for: window) as? TerminalFloatingKeyboardState)?.requestedWithHardware = false
        #endif
        store.set(previous, for: window)
        return previous
    }

    /// Ends this host's open one-shot keyboard without touching input views.
    /// Returns true when one was open.
    private func endOwnOneShotIntent() -> Bool {
        defer { oneShotWindow = nil }
        guard let window = oneShotWindow,
              SoftwareKeyboardHideIntentStore.shared.oneShotOwner(for: window) === self else { return false }
        return endOneShotIntent(in: window) != nil
    }

    /// Returns a one-shot keyboard to the state it was opened from. Another
    /// host hands the request to the opener, which alone re-applies its input
    /// views. `applying: false` leaves them alone during a focus handoff; the
    /// opener's next focus reconciles with the restored intent.
    func finishOneShotKeyboard(applying: Bool = true) {
        if hideIntent.isOneShot, oneShotOwner !== self {
            reconcileWithHideIntent()
            return
        }
        guard let window = oneShotWindow,
              SoftwareKeyboardHideIntentStore.shared.oneShotOwner(for: window) === self,
              let previous = endOneShotIntent(in: window) else { return }
        oneShotWindow = nil
        guard applying, host?.keyboardHideIntentWindow === window else { return }
        if case .hidden(let pinned) = previous {
            enterToolbarOnlyMode(pinned: pinned)
        } else {
            host?.keyboardReloadInputViews()
            scheduleKeyboardToolbarUpdate(reason: "oneShotKeyboardFinished")
        }
    }

    /// Bring this host's applied mode in line with the window's hide intent.
    /// Idempotent; called before every first-responder acquisition so the
    /// input view UIKit queries already reflects the intent. Returns true when
    /// something changed.
    @discardableResult
    func reconcileWithHideIntent() -> Bool {
        guard usesHideIntent else { return false }
        // Another terminal taking focus ends its one-shot keyboard, even
        // after the opener closed.
        if hideIntent.isOneShot, oneShotOwner !== self {
            oneShotOwner?.finishOneShotKeyboard(applying: false)
            if let window = host?.keyboardHideIntentWindow { _ = endOneShotIntent(in: window) }
        }
        let intent = hideIntent
        if !intent.isHidden {
            guard toolbarOnlyMode else { return false }
            if intent.isOneShot { leaveToolbarOnlyMode() } else { exitToolbarOnlyMode() }
            return true
        }
        let pinned = intent.isPinned
        guard toolbarOnlyMode else {
            enterToolbarOnlyMode(pinned: pinned)
            return true
        }
        let hidesToolbar = !pinned && !SettingsStore.shared.value(Settings.KeyboardToolbar.persistent)
        var changed = false
        if toolbarOnlyHidesToolbar != hidesToolbar {
            toolbarOnlyHidesToolbar = hidesToolbar
            changed = true
        }
        keyboardAccessory?.setDismissButtonPinned(pinned)
        keyboardAccessory?.setDismissButtonShowsRestore(true)
        applyBottomSafeAreaStrip()
        updateBottomEdgeHomeGestureProtection()
        if changed { host?.keyboardReloadInputViews() }
        return changed
    }

    func resetFocusLossState() {
        dismissFloatingTouchKeyboard()
        cancelTouchKeyboardInteraction()
        if toolbarOnlyMode {
            toolbarOnlyMode = false
            keyboardAccessory?.setDismissButtonShowsRestore(false)
        }
        if keyboardToolbarCollapsed {
            keyboardToolbarCollapsed = false
        }
    }

    func hitTestCollapsedKeyboardToolbarButton(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard keyboardToolbarCollapsed,
              let button = collapsedKeyboardToolbarButton,
              !button.isHidden,
              button.alpha > 0.01,
              button.isUserInteractionEnabled,
              let host else {
            return nil
        }

        let buttonPoint = host.keyboardHostView.convert(point, to: button)
        return button.hitTest(buttonPoint, with: event)
        #else
        return nil
        #endif
    }

    /// The host laid out; a pending Duo handoff refresh may now be due. Taken
    /// on the next turn, so no input-view reload runs inside layout.
    func hostDidLayout() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        hostReportsLayout = true
        guard let size = host?.keyboardHostView.window?.bounds.size else { return }
        lastLaidOutHostSize = size
        // Only the first layout seeds, once a hinge update has named the display
        // (`isFrontDisplay` defaults to inner). A layout ahead of a display
        // notification would file the new size under the old display.
        if laidOutSizeByDisplay.isEmpty, DuoHingeEvents.hasHinge {
            laidOutSizeByDisplay[DuoHingeEvents.isFrontDisplay] = size
        }
        guard pendingHandoffRefresh else { return }
        handoffAwaitsFoldLayout = false
        // Readiness is judged from this, the latest layout, when consumed.
        consumeHandoffRefreshSoon()
        #endif
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// A layout at `size` belongs to the `front` display: its confirmed size
    /// (either orientation), or, never confirmed, any size the other display
    /// doesn't have.
    private func isLayout(_ size: CGSize, for front: Bool) -> Bool {
        func matches(_ known: CGSize) -> Bool {
            size == known || (size.width == known.height && size.height == known.width)
        }
        if let known = laidOutSizeByDisplay[front] { return matches(known) }
        if let other = laidOutSizeByDisplay[!front] { return !matches(other) }
        return true
    }

    private func consumeHandoffRefreshSoon() {
        // Taken on the next turn, so no input-view reload runs inside layout.
        DispatchQueue.main.async { [weak self] in self?.consumeHandoffRefreshIfReady() }
    }
    #endif

    func updateCollapsedKeyboardToolbarButtonLayout() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton,
              keyboardToolbarCollapsed else { return }

        button.bounds = CGRect(origin: .zero, size: collapsedKeyboardToolbarButtonSize)
        let targetCenter = collapsedKeyboardToolbarButtonWasMoved
            ? (collapsedKeyboardToolbarButtonCenter ?? defaultCollapsedKeyboardToolbarButtonCenter())
            : defaultCollapsedKeyboardToolbarButtonCenter()
        let clampedCenter = clampedCollapsedKeyboardToolbarButtonCenter(targetCenter)
        collapsedKeyboardToolbarButtonCenter = clampedCenter
        button.center = clampedCenter
        host?.keyboardHostView.bringSubviewToFront(button)
        #endif
    }

    private func collapseKeyboardToolbar() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        collapsedKeyboardToolbarButtonWasMoved = false
        collapsedKeyboardToolbarButtonCenter = defaultCollapsedKeyboardToolbarButtonCenter()
        keyboardToolbarCollapsed = true
        host?.keyboardReloadInputViews()
        updateCollapsedKeyboardToolbarButtonVisibility()
        #endif
    }

    @objc private func restoreCollapsedKeyboardToolbar() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        keyboardToolbarCollapsed = false
        if host?.keyboardIsFirstResponder != true {
            _ = host?.keyboardBecomeFirstResponder()
        }
        host?.keyboardReloadInputViews()
        #endif
    }

    private func updateCollapsedKeyboardToolbarButtonVisibility() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton else { return }
        let shouldShowButton = keyboardToolbarCollapsed
            && host?.keyboardIsFirstResponder == true
            && host?.keyboardAIAgentOverlayActive != true

        if shouldShowButton {
            if collapsedKeyboardToolbarButtonCenter == nil {
                collapsedKeyboardToolbarButtonCenter = defaultCollapsedKeyboardToolbarButtonCenter()
            }
            updateCollapsedKeyboardToolbarButtonLayout()
            host?.keyboardHostView.bringSubviewToFront(button)
            button.isHidden = false
        }

        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            button.alpha = shouldShowButton ? 0.82 : 0
        } completion: { _ in
            button.isHidden = !shouldShowButton
        }
        #endif
    }

    private func defaultCollapsedKeyboardToolbarButtonCenter() -> CGPoint {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let view = host?.keyboardHostView else { return .zero }
        let margin: CGFloat = 10
        let halfWidth = collapsedKeyboardToolbarButtonSize.width / 2
        let halfHeight = collapsedKeyboardToolbarButtonSize.height / 2
        let bottomLimit = view.bounds.maxY - max(view.safeAreaInsets.bottom, host?.keyboardHostBottomUnderlap ?? 0)

        let x = view.bounds.maxX - view.safeAreaInsets.right - margin - halfWidth
        let y = bottomLimit - margin - halfHeight
        return clampedCollapsedKeyboardToolbarButtonCenter(CGPoint(x: x, y: y))
        #else
        return .zero
        #endif
    }

    private func clampedCollapsedKeyboardToolbarButtonCenter(_ center: CGPoint) -> CGPoint {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let view = host?.keyboardHostView else { return center }
        let margin: CGFloat = 10
        let halfWidth = collapsedKeyboardToolbarButtonSize.width / 2
        let halfHeight = collapsedKeyboardToolbarButtonSize.height / 2
        let minX = view.bounds.minX + view.safeAreaInsets.left + margin + halfWidth
        let maxX = view.bounds.maxX - view.safeAreaInsets.right - margin - halfWidth
        let minY = view.bounds.minY + view.safeAreaInsets.top + margin + halfHeight
        let bottom = max(view.safeAreaInsets.bottom, host?.keyboardHostBottomUnderlap ?? 0)
        let maxY = view.bounds.maxY - bottom - margin - halfHeight

        return CGPoint(
            x: min(max(center.x, minX), max(minX, maxX)),
            y: min(max(center.y, minY), max(minY, maxY))
        )
        #else
        return center
        #endif
    }

    @objc private func handleCollapsedKeyboardToolbarButtonPan(_ gesture: UIPanGestureRecognizer) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton else { return }
        let translation = gesture.translation(in: host?.keyboardHostView)
        var nextCenter = CGPoint(
            x: button.center.x + translation.x,
            y: button.center.y + translation.y
        )
        nextCenter = clampedCollapsedKeyboardToolbarButtonCenter(nextCenter)

        switch gesture.state {
        case .began, .changed:
            collapsedKeyboardToolbarButtonWasMoved = true
            button.center = nextCenter
            collapsedKeyboardToolbarButtonCenter = nextCenter
            gesture.setTranslation(.zero, in: host?.keyboardHostView)
        case .ended, .cancelled, .failed:
            collapsedKeyboardToolbarButtonWasMoved = true
            UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                button.center = nextCenter
            }
            collapsedKeyboardToolbarButtonCenter = nextCenter
        default:
            break
        }
        #endif
    }

    private func scheduleKeyboardToolbarUpdate(reason: String) {
        keyboardStateDebounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateKeyboardToolbarVisibility(reason: reason)
            }
        }
        keyboardStateDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshKeyboardLayoutAfterAccessoryChange() {
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        host?.keyboardHostView.setNeedsLayout()
        host?.keyboardHostView.superview?.setNeedsLayout()
        host?.keyboardHostView.window?.setNeedsLayout()

        guard host?.keyboardIsFirstResponder == true else { return }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // A Duo handoff's one reload picks this change up.
        guard !pendingHandoffRefresh else { return }
        #endif

        host?.keyboardReloadInputViews()

        Task { @MainActor [weak self] in
            guard let self, self.host?.keyboardIsFirstResponder == true else { return }
            self.host?.keyboardReloadInputViews()
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }

    private func updateKeyboardToolbarVisibility(reason: String) {
        let tracker = KeyboardTracker.shared
        let showWithHardware = SettingsStore.shared.value(Settings.KeyboardToolbar.showWithHardwareKeyboard)
        var newShouldShow = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Open custom drawers can exceed the software-keyboard height heuristic.
        if touchKeyboardIsSelected && hidesTouchKeyboardForHardware { newShouldShow = showWithHardware }
        #endif
        if !newShouldShow && toolbarOnlyMode && !usesHideIntent {
            toolbarOnlyMode = false
            localHideIntent = .none
            keyboardAccessory?.setDismissButtonShowsRestore(false)
            keyboardAccessory?.setDismissButtonPinned(false)
        }
        if !newShouldShow && keyboardToolbarCollapsed {
            keyboardToolbarCollapsed = false
        }
        if shouldShowKeyboardToolbar != newShouldShow {
            Ghostty.logger.debug(
                "TerminalView: Keyboard toolbar visibility updated (\(reason)) - isHardware=\(tracker.isHardwareKeyboard), softwareVisible=\(tracker.isSoftwareKeyboardVisible), showToolbar=\(newShouldShow)"
            )
            shouldShowKeyboardToolbar = newShouldShow
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            host?.keyboardReloadInputViews()
        }
        refreshBottomSafeAreaStrip()
        updateBottomEdgeHomeGestureProtection()
    }

    func updateBottomEdgeHomeGestureProtection(accessoryIsVisible: Bool? = nil) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let idiom = host?.keyboardHostView.traitCollection.userInterfaceIdiom
        let isVisible = accessoryIsVisible ?? (
            shouldShowKeyboardToolbar
                && host?.keyboardAIAgentOverlayActive != true
                && !keyboardToolbarCollapsed
                && !(toolbarOnlyMode && toolbarOnlyHidesToolbar)
        )
        let hardwareAccessoryOnly = hardwareAccessoryOwnsKeyboardRegion
        // toolbarOnlyMode counts as at-screen-edge on its own: the accessory
        // is the whole keyboard region there, and with two drawer rows open it
        // passes EffectManager's 100pt docked-keyboard heuristic, which would
        // silently drop the protection while the row still sits on the edge.
        let toolbarIsAtScreenEdge: Bool
        if toolbarOnlyMode {
            toolbarIsAtScreenEdge = toolbarOnlyUsesPrimaryInputView
        } else {
            toolbarIsAtScreenEdge = usesTouchKeyboardToolbar || hardwareAccessoryOnly
                || !EffectManager.shared.isKeyboardDocked
        }
        if toolbarIsDetachedFromScreenEdge {
            // A draggable host: keys wait for release, so a drag that starts on one sends nothing.
            bottomEdgeHomeGestureProtectionEnabled = false
            keyboardAccessory?.setInteractionMode(.spacedBottom)
            return
        }
        let needsTouchProtection = (idiom == .phone || idiom == .pad)
            && isVisible && !usesFullTouchKeyboard
            && (!usesCompactTouchKeyboard || usesTouchKeyboardToolbar)
            && toolbarIsAtScreenEdge
        let hasSpacer = reservesBottomSafeAreaStrip
        let mode: KeyboardToolbarInteractionMode = needsTouchProtection
            ? (hasSpacer ? .spacedBottom : .screenEdge) : .accessory
        // A spacer preserves ordinary Home gestures, but does not make touches
        // on the nearby keys safe to dispatch before we know they are taps.
        bottomEdgeHomeGestureProtectionEnabled = mode == .screenEdge
        keyboardAccessory?.setInteractionMode(mode)
        touchKeyboard?.setToolbarInteractionMode(mode)
        #else
        bottomEdgeHomeGestureProtectionEnabled = false
        keyboardAccessory?.setInteractionMode(.accessory)
        #endif
    }
}
