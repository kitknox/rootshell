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
    var keyboardAccessoryHasBottomSafeAreaSpacer: Bool { get }
    /// Window whose `SoftwareKeyboardHideIntentStore` entry governs this host.
    /// nil opts out: the chevron falls back to resigning first responder.
    var keyboardHideIntentWindow: UIWindow? { get }

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
}

extension TerminalKeyboardAccessoryHost {
    var keyboardAccessoryHasBottomSafeAreaSpacer: Bool { false }
    var keyboardHideIntentWindow: UIWindow? { nil }
}

@MainActor
final class TerminalKeyboardAccessoryController: NSObject {
    private weak var host: TerminalKeyboardAccessoryHost?

    var keyboardAccessory: KeyboardAccessoryView?
    #if os(visionOS)
    weak var externalToolbar: KeyboardToolbarView?
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
    private func setHideIntent(_ intent: SoftwareKeyboardHideIntent) {
        guard let window = host?.keyboardHideIntentWindow else {
            localHideIntent = intent
            return
        }
        SoftwareKeyboardHideIntentStore.shared.set(intent, for: window)
    }
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

    var reservesKeyboardToolbarAtBottom: Bool {
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
        let hostFrame: CGRect
        if let window = host?.keyboardHostView.window {
            hostFrame = window.convert(window.bounds, to: nil)
        } else {
            hostFrame = UIScreen.main.bounds
        }
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
            keyboardAccessory?.bounds.height ?? 0,
            keyboardAccessory?.intrinsicContentSize.height ?? 0
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
        guard let host, !host.keyboardAccessoryHasBottomSafeAreaSpacer else { return 0 }
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
        } else if hardwareAccessoryOwnsKeyboardRegion {
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
    var reservesBottomSafeAreaStrip: Bool {
        (keyboardAccessory?.reservedBottomSafeArea ?? 0) > 0
    }

    /// Reconcile the reserved strip with the current setting, orientation, and
    /// keyboard state. Returns true when it moved.
    @discardableResult
    private func applyBottomSafeAreaStrip() -> Bool {
        let height = bottomSafeAreaStripHeight
        let changed = keyboardAccessory?.setReservedBottomSafeArea(height) ?? false
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
        let fallbackHeight = KeyboardSizes.current(traitCollection: host.keyboardHostView.traitCollection).toolbar.height
            + (keyboardAccessory?.reservedBottomSafeArea ?? 0)
        if let intrinsicHeight = keyboardAccessory?.intrinsicContentSize.height,
           intrinsicHeight > 0 {
            return max(fallbackHeight, intrinsicHeight)
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
        guard let host else { return nil }
        applyBottomSafeAreaStrip()
        let isVisible = shouldShowKeyboardToolbar
            && !host.keyboardAIAgentOverlayActive
            && !keyboardToolbarCollapsed
            && !(toolbarOnlyMode && toolbarOnlyHidesToolbar)
        updateBottomEdgeHomeGestureProtection(accessoryIsVisible: isVisible)
        // In the normal toolbar-only path the accessory serves as the primary
        // input view instead (see `inputView`); handing it out from both slots
        // in one reload would let the second container steal it from the first.
        // A detached iPad keyboard deliberately keeps the pre-merge
        // accessory-over-empty-input arrangement to avoid inheriting the
        // floating keyboard's oversized frame.
        guard !toolbarOnlyMode || !toolbarOnlyUsesPrimaryInputView else { return nil }
        return isVisible ? keyboardAccessory : nil
    }

    /// In toolbar-only mode the toolbar is the primary input view, not an
    /// accessory above an empty one. UIKit lays a primary input view flush with
    /// the screen's bottom edge, like the system keyboard. An accessory over an
    /// empty input view is not flush: UIKit appends a version-dependent
    /// `_UIRemoteKeyboardPlaceholderView` below it (17pt on iOS 26.3, 0 on
    /// 26.5) and only grows the accessory upward, so no reservation can move
    /// the row past that strip.
    var inputView: UIView? {
        // UIKit does not specify whether it asks for inputView or
        // inputAccessoryView first. Publish the destination-mode intrinsic
        // height from both paths so toolbar-only entry is correct in one pass.
        applyBottomSafeAreaStrip()
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
        return accessory
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
        keyboardAccessory = KeyboardAccessoryView(sizes: KeyboardSizes.current(traitCollection: host.keyboardHostView.traitCollection))
        keyboardAccessory?.delegate = delegate

        keyboardAccessory?.onModifiersChanged = { [weak self] modifiers in
            self?.activeKeyboardModifiers = modifiers
            self?.onActiveKeyboardModifiersChanged?(modifiers)
            Ghostty.logger.debug("TerminalView: Toolbar modifiers changed to rawValue: \(modifiers.rawValue)")
        }

        keyboardAccessory?.onDismissRequested = { [weak self] in
            guard let self else { return }
            if self.toolbarOnlyMode {
                self.exitToolbarOnlyMode()
            } else if self.usesHideIntent || SettingsStore.shared.value(Settings.KeyboardToolbar.persistent) {
                self.setHideIntent(.hidden(pinned: false))
                self.enterToolbarOnlyMode(pinned: false)
            } else {
                // Hosts without a hide-intent window (VNC) keep the legacy
                // resign path.
                _ = self.host?.keyboardResignFirstResponder()
            }
        }

        keyboardAccessory?.onCollapseRequested = { [weak self] in
            self?.collapseKeyboardToolbar()
        }

        keyboardAccessory?.onPinHiddenRequested = { [weak self] in
            guard let self else { return }
            if self.keyboardPinnedHidden {
                self.exitToolbarOnlyMode()
            } else {
                self.setHideIntent(.hidden(pinned: true))
                self.enterToolbarOnlyMode(pinned: true)
            }
        }

        keyboardAccessory?.onTabSwitcherRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .showTabSwitcher, object: host)
        }

        keyboardAccessory?.onToolbarSettingsRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .showToolbarSettings, object: host)
        }

        keyboardAccessory?.onPasteRequested = { [weak self] in
            self?.host?.keyboardPaste()
        }

        keyboardAccessory?.onToggleFullScreenRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleFullScreen, object: host)
        }

        keyboardAccessory?.onToggleTabBarRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleTabBar, object: host)
        }

        keyboardAccessory?.onNewConnectionRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .newTab, object: host)
        }

        keyboardAccessory?.onAppSettingsRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .openSettings, object: host)
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

        keyboardAccessory?.onAIAgentRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleAIAgent, object: host)
        }

        keyboardAccessory?.onClipboardManagerRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleClipboardManager, object: host)
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

        let homeIndicatorObserver = NotificationCenter.default.addObserver(
            forName: .terminalBottomInsetInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBottomSafeAreaStrip() }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(homeIndicatorObserver) })
        #endif

        let tracker = KeyboardTracker.shared
        let showWithHardware = SettingsStore.shared.value(Settings.KeyboardToolbar.showWithHardwareKeyboard)
        let initialShowToolbar = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
        shouldShowKeyboardToolbar = initialShowToolbar
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        let initialToolbarVisible = shouldShowKeyboardToolbar
        Ghostty.logger.debug(
            "TerminalView.setupKeyboard: Initial state - isHardware=\(tracker.isHardwareKeyboard), softwareVisible=\(tracker.isSoftwareKeyboardVisible), showToolbar=\(initialToolbarVisible)"
        )

        keyboardStateTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                guard let self else { break }
                self.scheduleKeyboardToolbarUpdate(reason: "hardware")
            }
        }

        keyboardVisibilityTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                guard let self else { break }
                self.scheduleKeyboardToolbarUpdate(reason: "softwareVisibility")
            }
        }

        keyboardAnimationTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                if !animating {
                    self.host?.keyboardDidFinishAnimationLayout()
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
                    self?.host?.keyboardReloadInputViews()
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
        updateCollapsedKeyboardToolbarButtonVisibility()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        host?.keyboardReloadInputViews()
    }

    func enterToolbarOnlyMode(pinned: Bool = false) {
        _ = emptyInputView
        emptyInputViewHeightConstraint?.constant = 0
        toolbarOnlyHidesToolbar = usesHideIntent
            && !pinned
            && !SettingsStore.shared.value(Settings.KeyboardToolbar.persistent)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Snapshot before changing the input set. Once the software keyboard
        // starts hiding, its placement frame is no longer reliable enough to
        // tell whether UIKit is tearing down a detached keyboard.
        let hasDetachedKeyboardPlacement = UIDevice.current.userInterfaceIdiom == .pad
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
        host?.keyboardReloadInputViews()
    }

    func exitToolbarOnlyMode() {
        setHideIntent(.none)
        keyboardAccessory?.setDismissButtonPinned(false)
        toolbarOnlyMode = false
        toolbarOnlyHidesToolbar = false
        host?.keyboardSetSoftwareKeyboardRequested(true)
        keyboardAccessory?.setDismissButtonShowsRestore(false)
        host?.keyboardReloadInputViews()
        toolbarOnlyUsesPrimaryInputView = true
    }

    /// Bring this host's applied mode in line with the window's hide intent.
    /// Idempotent; called before every first-responder acquisition so the
    /// input view UIKit queries already reflects the intent. Returns true when
    /// something changed.
    @discardableResult
    func reconcileWithHideIntent() -> Bool {
        guard usesHideIntent else { return false }
        let intent = hideIntent
        if !intent.isHidden {
            guard toolbarOnlyMode else { return false }
            exitToolbarOnlyMode()
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
        if changed { host?.keyboardReloadInputViews() }
        return changed
    }

    func resetFocusLossState() {
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
        let bottomLimit = view.bounds.maxY - view.safeAreaInsets.bottom

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
        let maxY = view.bounds.maxY - view.safeAreaInsets.bottom - margin - halfHeight

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
        let newShouldShow = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
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

    private func updateBottomEdgeHomeGestureProtection(accessoryIsVisible: Bool? = nil) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let idiom = UIDevice.current.userInterfaceIdiom
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
            toolbarIsAtScreenEdge = hardwareAccessoryOnly
                || !EffectManager.shared.isKeyboardDocked
        }
        let enabled = (idiom == .phone || idiom == .pad)
            && isVisible
            && host?.keyboardAccessoryHasBottomSafeAreaSpacer != true
            && !reservesBottomSafeAreaStrip
            && toolbarIsAtScreenEdge
        bottomEdgeHomeGestureProtectionEnabled = enabled
        keyboardAccessory?.setBottomEdgeHomeGestureProtectionEnabled(enabled)
        #else
        bottomEdgeHomeGestureProtectionEnabled = false
        keyboardAccessory?.setBottomEdgeHomeGestureProtectionEnabled(false)
        #endif
    }
}
