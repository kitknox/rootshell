//
//  KeyboardTracker.swift
//  rootshell
//
//  Tracks keyboard state to detect hardware vs software keyboard
//  Uses GCKeyboard API (iOS 14+) for reliable hardware keyboard detection
//

import UIKit
import GameController
import os

@Observable
class KeyboardTracker {
    @MainActor
    static let shared = KeyboardTracker()

    // MARK: - Public Properties

    /// True if running as iPad app on macOS (always has hardware keyboard)
    @MainActor
    private(set) var isMacOSCompatibilityMode: Bool = {
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
    }()

    /// True if a hardware keyboard is attached, false if using on-screen keyboard
    @MainActor
    private(set) var isHardwareKeyboard: Bool = false

    /// Physical hardware modifiers currently held. Kept here because
    /// `GCKeyboardInput` has a single change handler shared by the whole app.
    @MainActor
    private(set) var hardwareModifierFlags: UIKeyModifierFlags = []

    /// True if the on-screen (software) keyboard is currently visible
    @MainActor
    private(set) var isSoftwareKeyboardVisible: Bool = false

    /// Current keyboard frame
    @MainActor
    private(set) var keyboardFrame: CGRect = .zero

    /// True while UIKit has any input view on screen, including a toolbar-only
    /// or accessory-only layout below the software-keyboard threshold. Those
    /// layouts hide and re-show through the same keyboard notifications and
    /// safe-area shuffle as a full keyboard, so the preservation latches must
    /// cover them too.
    @MainActor
    var isAnyInputViewPresented: Bool {
        isSoftwareKeyboardVisible || visibleKeyboardHeight(for: keyboardFrame) > 0
    }

    /// Set when a latch armed for a sub-threshold layout. Any visible frame
    /// then counts as the layout returning, so the re-shown toolbar is not
    /// mistaken for a still-hidden keyboard and committed away on release.
    @MainActor private var overlayPreservationCoversInputViewOnly = false
    @MainActor private var appTransitionPreservationCoversInputViewOnly = false

    @MainActor
    private func isPreservedLayoutFrameVisible(_ frame: CGRect, inputViewOnly: Bool) -> Bool {
        if inputViewOnly { return visibleKeyboardHeight(for: frame) > 0 }
        return isSoftwareKeyboardFrameVisible(frame)
    }

    /// True while the keyboard show/hide animation is in progress
    @MainActor
    private(set) var isKeyboardAnimating: Bool = false

    /// True while iOS is hiding the software keyboard as part of an app
    /// inactive/background transition. During this window, consumers should
    /// keep the last visible keyboard layout instead of treating the keyboard
    /// as user-dismissed.
    @MainActor
    private(set) var isPreservingSoftwareKeyboardForAppTransition: Bool = false

    /// True while an overlay (tab switcher, sheet, connection sidebar) owns the
    /// keyboard and the terminal's resign is hiding the software keyboard.
    /// During this window, consumers keep the last visible keyboard layout so
    /// the terminal's bounds never change across the overlay round trip; the
    /// hide is committed only if the keyboard doesn't return after release.
    @MainActor
    private(set) var isPreservingSoftwareKeyboardForOverlay: Bool = false

    /// Consumers that freeze layout on preserved keyboard state check this OR
    /// of both preservation latches (app transition + overlay).
    @MainActor
    var isPreservingSoftwareKeyboardLayout: Bool {
        isPreservingSoftwareKeyboardForAppTransition || isPreservingSoftwareKeyboardForOverlay
    }

    /// Window-scoped read of the overlay latch: true only while the latch is
    /// armed AND the given window is the preservation owner's window (or
    /// ownership was never window-resolved). Keeps one window's overlay from
    /// suppressing another window's resizes — rotating window B while window
    /// A has an overlay open must update B's grid immediately.
    @MainActor
    func isPreservingKeyboardForOverlay(in window: UIWindow?) -> Bool {
        guard isPreservingSoftwareKeyboardForOverlay else { return false }
        guard overlayOwnerWindowWasCaptured,
              let ownerWindow = overlayKeyboardPreservationOwnerWindow else {
            return true
        }
        guard let window else { return false }
        return window === ownerWindow
    }

    /// Stream factory for hardware keyboard state changes (supports multiple subscribers)
    /// Immediately yields current state on subscription, then yields on changes
    @MainActor
    func hardwareKeyboardStateDidChangeStream() -> AsyncStream<Bool> {
        let currentState = isHardwareKeyboard
        return AsyncStream { continuation in
            // Immediately yield current state so new subscribers don't miss it
            continuation.yield(currentState)

            let id = UUID()
            self.hardwareKeyboardStateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    KeyboardTracker.shared.hardwareKeyboardStateContinuations[id] = nil
                }
            }
        }
    }

    /// Stream factory for physical modifier changes (supports multiple subscribers).
    /// Immediately yields the current snapshot, then yields on transitions.
    @MainActor
    func hardwareModifierStateDidChangeStream() -> AsyncStream<UIKeyModifierFlags> {
        refreshHardwareModifierState()
        let currentState = hardwareModifierFlags
        return AsyncStream { continuation in
            continuation.yield(currentState)

            let id = UUID()
            self.hardwareModifierStateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    KeyboardTracker.shared.hardwareModifierStateContinuations[id] = nil
                }
            }
        }
    }

    /// Stream factory for software keyboard visibility changes (supports multiple subscribers)
    /// Immediately yields current state on subscription, then yields on changes
    @MainActor
    func softwareKeyboardVisibilityDidChangeStream() -> AsyncStream<Bool> {
        let currentState = isSoftwareKeyboardVisible
        return AsyncStream { continuation in
            // Immediately yield current state so new subscribers don't miss it
            continuation.yield(currentState)

            let id = UUID()
            self.softwareKeyboardVisibilityContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    KeyboardTracker.shared.softwareKeyboardVisibilityContinuations[id] = nil
                }
            }
        }
    }

    /// Stream factory for keyboard animation state changes (supports multiple subscribers)
    /// Immediately yields current state on subscription, then yields on changes
    @MainActor
    func keyboardAnimationDidChangeStream() -> AsyncStream<Bool> {
        let currentState = isKeyboardAnimating
        return AsyncStream { continuation in
            continuation.yield(currentState)

            let id = UUID()
            self.keyboardAnimationContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    KeyboardTracker.shared.keyboardAnimationContinuations[id] = nil
                }
            }
        }
    }

    // MARK: - Private Properties

    private var isTrackingKeyboard = false

    @MainActor
    private var hardwareKeyboardStateContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    @MainActor
    private var hardwareModifierStateContinuations: [UUID: AsyncStream<UIKeyModifierFlags>.Continuation] = [:]

    @MainActor
    private var pressedHardwareModifierKeys: Set<GCKeyCode> = []

    // Only actual key-down callbacks populate this set, never a GC snapshot.
    // It survives terminal focus handoffs, but not scene/app deactivation.
    @MainActor
    private var shortcutRecoveryModifierKeys: Set<GCKeyCode> = []

    @MainActor
    var shortcutRecoveryModifierFlags: UIKeyModifierFlags {
        Self.modifierFlags(for: shortcutRecoveryModifierKeys)
    }

    @MainActor
    private var softwareKeyboardVisibilityContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    @MainActor
    private var keyboardAnimationContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Safety timer to auto-clear isKeyboardAnimating if the didShow/didHide notification
    /// is never delivered (e.g., app lifecycle transition mid-animation, focus loss).
    @MainActor
    private var keyboardAnimationSafetyTimer: Timer?

    @MainActor
    private var appTransitionKeyboardPreservationTask: Task<Void, Never>?

    @MainActor
    private var ignoredHiddenKeyboardFrameDuringPreservation = false

    @MainActor
    private var overlayKeyboardPreservationReleaseTask: Task<Void, Never>?

    @MainActor
    private var ignoredHiddenKeyboardFrameDuringOverlayPreservation = false

    /// Height threshold to treat a keyboard frame as an on-screen keyboard
    private static let softwareKeyboardHeightThreshold: CGFloat = 120
    private static let appTransitionKeyboardPreservationDuration: Duration = .milliseconds(750)

    /// True when the physical Cmd+Period system-cancel chord is down right now.
    /// Pure GCKeyboard poll used only to disambiguate an event that already
    /// arrived (translated Escape, or Period with Command stripped); it never
    /// initiates dispatch, so a stale latched Command bit cannot inject input
    /// on its own. Requiring Escape to NOT be down rejects a real Escape press
    /// even under a stale Command latch.
    @MainActor
    static func isSystemCancelChordPhysicallyDown() -> Bool {
        #if os(visionOS)
        return false
        #else
        guard UIApplication.shared.applicationState == .active,
              let input = GCKeyboard.coalesced?.keyboardInput,
              input.button(forKeyCode: .period)?.isPressed == true,
              input.button(forKeyCode: .escape)?.isPressed != true else { return false }
        let commandDown = input.button(forKeyCode: .leftGUI)?.isPressed == true
            || input.button(forKeyCode: .rightGUI)?.isPressed == true
        let extraModifier = [GCKeyCode.leftShift, .rightShift, .leftControl,
                             .rightControl, .leftAlt, .rightAlt]
            .contains { input.button(forKeyCode: $0)?.isPressed == true }
        return commandDown && !extraModifier
        #endif
    }

    // MARK: - Initialization

    private init() {
        // On macOS, always start with hardware keyboard detected
        if isMacOSCompatibilityMode {
            isHardwareKeyboard = true
        } else {
            // Check initial hardware keyboard state using GCKeyboard API
            #if !os(visionOS)
            isHardwareKeyboard = GCKeyboard.coalesced != nil
            Ghostty.logger.debug("KeyboardTracker: Initial GCKeyboard state - isHardware=\(self.isHardwareKeyboard)")
            #endif
        }
        startTracking()

        // Set up keyboard input handler if keyboard is already connected
        #if !os(visionOS)
        if GCKeyboard.coalesced != nil {
            setupKeyboardInputHandler()
        }
        #endif
    }

    deinit {
        // Remove observers synchronously (allowed from deinit)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    @MainActor
    func startTracking() {
        guard !isTrackingKeyboard else { return }
        isTrackingKeyboard = true

        // GCKeyboard notifications for hardware keyboard connect/disconnect (most reliable)
        #if !os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidDisconnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
        #endif

        // On Mac Catalyst, reinstall keyboard handler when app becomes active
        // The GCKeyboard instance can change during sleep/wake cycles without
        // firing connect/disconnect notifications
        #if targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActiveForKeyboard(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillDeactivateForKeyboard(_:)),
            name: UIScene.willDeactivateNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivateForKeyboard(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActiveForKeyboard(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        // Keyboard frame notifications (for tracking keyboard frame, secondary detection)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    @MainActor
    func stopTracking() {
        guard isTrackingKeyboard else { return }
        isTrackingKeyboard = false
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - GCKeyboard Handlers (Primary Detection)

    @MainActor
    @objc private func hardwareKeyboardDidConnect(_ notification: Notification) {
        Ghostty.logger.debug("KeyboardTracker: GCKeyboard connected")
        updateHardwareKeyboardState(true)
        setupKeyboardInputHandler()
    }

    @MainActor
    @objc private func hardwareKeyboardDidDisconnect(_ notification: Notification) {
        Ghostty.logger.debug("KeyboardTracker: GCKeyboard disconnected")
        resetHardwareModifierState()
        updateHardwareKeyboardState(false)
    }

    #if targetEnvironment(macCatalyst)
    @MainActor
    @objc private func appDidBecomeActive(_ notification: Notification) {
        // On Mac Catalyst, the GCKeyboard instance can change during sleep/wake
        // or other system events without firing connect/disconnect notifications.
        // Reinstall the handler to ensure Ctrl+key handling continues to work.
        if GCKeyboard.coalesced != nil {
            Ghostty.logger.debug("KeyboardTracker: App became active, reinstalling keyboard handler")
            setupKeyboardInputHandler()
        }
    }
    #endif

    @MainActor
    @objc private func appWillResignActiveForKeyboard(_ notification: Notification) {
        // Reserved system shortcuts can swallow key-up. Never carry a held
        // modifier snapshot across an app activation boundary.
        resetHardwareModifierState()
        beginAppTransitionKeyboardPreservationIfNeeded(autoClearIfAppStaysActive: false)
    }

    @MainActor
    @objc private func sceneWillDeactivateForKeyboard(_ notification: Notification) {
        shortcutRecoveryModifierKeys.removeAll()
        beginAppTransitionKeyboardPreservationIfNeeded(autoClearIfAppStaysActive: true)
    }

    @MainActor
    private func beginAppTransitionKeyboardPreservationIfNeeded(autoClearIfAppStaysActive: Bool) {
        guard isAnyInputViewPresented else { return }
        appTransitionKeyboardPreservationTask?.cancel()
        appTransitionKeyboardPreservationTask = nil
        appTransitionPreservationCoversInputViewOnly = !isSoftwareKeyboardVisible
        isPreservingSoftwareKeyboardForAppTransition = true
        ignoredHiddenKeyboardFrameDuringPreservation = false
        setKeyboardAnimating(false)

        if autoClearIfAppStaysActive {
            appTransitionKeyboardPreservationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.appTransitionKeyboardPreservationDuration)
                guard let self, !Task.isCancelled else { return }
                guard UIApplication.shared.applicationState == .active else { return }
                self.clearAppTransitionKeyboardPreservation()
            }
        }
    }

    @MainActor
    @objc private func sceneDidActivateForKeyboard(_ notification: Notification) {
        scheduleAppTransitionKeyboardPreservationClear()
    }

    @MainActor
    @objc private func appDidBecomeActiveForKeyboard(_ notification: Notification) {
        refreshHardwareModifierState()
        scheduleAppTransitionKeyboardPreservationClear()
    }

    @MainActor
    private func scheduleAppTransitionKeyboardPreservationClear() {
        guard isPreservingSoftwareKeyboardForAppTransition else { return }
        appTransitionKeyboardPreservationTask?.cancel()
        appTransitionKeyboardPreservationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.appTransitionKeyboardPreservationDuration)
            guard let self, !Task.isCancelled else { return }
            self.clearAppTransitionKeyboardPreservation()
        }
    }

    @MainActor
    private func clearAppTransitionKeyboardPreservation() {
        if ignoredHiddenKeyboardFrameDuringPreservation {
            if isPreservingSoftwareKeyboardForOverlay {
                // While an overlay latch is also up, the overlay release owns
                // the eventual hide commit — committing here would collapse
                // the frozen layout under the still-open overlay. Transfer
                // the pending hide instead of dropping it.
                ignoredHiddenKeyboardFrameDuringOverlayPreservation = true
            } else {
                keyboardFrame = .zero
                updateSoftwareKeyboardVisibility(false)
                EffectManager.shared.clearPreservedKeyboardLayout()
            }
        }
        isPreservingSoftwareKeyboardForAppTransition = false
        appTransitionPreservationCoversInputViewOnly = false
        ignoredHiddenKeyboardFrameDuringPreservation = false
        appTransitionKeyboardPreservationTask?.cancel()
        appTransitionKeyboardPreservationTask = nil
        if !isPreservingSoftwareKeyboardForOverlay {
            EffectManager.shared.resyncKeyboardFrameAfterPreservation()
        }
    }

    // MARK: - Overlay Keyboard Preservation

    /// The single current owner of the overlay latch — the window whose
    /// overlay-driven resign is hiding the keyboard. Single and latest-wins,
    /// not reference-counted: the keyboard is one process-wide resource, so
    /// only the window that currently holds it can meaningfully freeze its
    /// layout. Weak so a window destroyed with its overlay open cannot pin
    /// the latch. Set ONLY when the latch actually arms — an overlay that
    /// never armed preservation holds no claim and can't block release.
    @MainActor
    private weak var overlayKeyboardPreservationOwner: AnyObject?

    /// The owner's window, passed explicitly at arm time. A hide that
    /// arrives while a DIFFERENT window has focus is a real user action in
    /// that window and must not be swallowed.
    @MainActor
    private weak var overlayKeyboardPreservationOwnerWindow: UIWindow?

    @MainActor
    private var overlayOwnerWindowWasCaptured = false

    /// Arm the overlay preservation latch before an overlay-driven first
    /// responder resign hides the software keyboard. Idempotent; no-op when
    /// no input view is up (nothing to preserve). Toolbar-only and
    /// accessory-only layouts arm it too: the terminal's toolbar-reserve latch
    /// keeps the padding, but only this latch drops the size and bottom-inset
    /// pushes from the safe-area shuffle. A begin from a second window while
    /// armed transfers ownership to it (latest wins). The caller passes its
    /// own window — never derived from isKeyWindow scans, which are
    /// unreliable on iPadOS multi-window (see WindowSceneReporter).
    @MainActor
    func beginOverlayKeyboardPreservation(owner: AnyObject, window: UIWindow?) {
        // Cancel any pending release first: a reopen inside the settle window
        // must keep the latch armed, including when the guards below return.
        overlayKeyboardPreservationReleaseTask?.cancel()
        overlayKeyboardPreservationReleaseTask = nil
        if isPreservingSoftwareKeyboardForOverlay {
            overlayKeyboardPreservationOwner = owner
            overlayKeyboardPreservationOwnerWindow = window
            overlayOwnerWindowWasCaptured = window != nil
            return
        }
        guard isAnyInputViewPresented else { return }
        overlayPreservationCoversInputViewOnly = !isSoftwareKeyboardVisible
        isPreservingSoftwareKeyboardForOverlay = true
        ignoredHiddenKeyboardFrameDuringOverlayPreservation = false
        overlayKeyboardPreservationOwner = owner
        overlayKeyboardPreservationOwnerWindow = window
        overlayOwnerWindowWasCaptured = window != nil
    }

    /// Release this owner's claim on the overlay latch. A no-op unless the
    /// caller is the current owner, so a window closing an overlay that never
    /// armed (or whose claim another window has since taken over) can't
    /// unfreeze someone else's layout. Also called from window/scene cleanup
    /// so teardown releases deterministically instead of waiting for the next
    /// keyboard event to notice the dead owner.
    @MainActor
    func endOverlayKeyboardPreservation(owner: AnyObject) {
        guard isPreservingSoftwareKeyboardForOverlay,
              overlayKeyboardPreservationOwner === owner else { return }
        scheduleOverlayKeyboardPreservationRelease()
    }

    /// Schedule the settle-window release. The latch stays up for the settle
    /// window so the terminal's keyboard re-show (which carries fresh
    /// geometry — orientation, keyboard type) lands while still preserved;
    /// if the keyboard never returns (hardware keyboard attached, restore
    /// failed), the pending hide is committed — or handed to the
    /// app-transition latch when one is active — so layout catches up with
    /// one legitimate resize.
    @MainActor
    private func scheduleOverlayKeyboardPreservationRelease() {
        guard isPreservingSoftwareKeyboardForOverlay else { return }
        overlayKeyboardPreservationReleaseTask?.cancel()
        overlayKeyboardPreservationReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.appTransitionKeyboardPreservationDuration)
            guard let self, !Task.isCancelled else { return }
            guard self.isPreservingSoftwareKeyboardForOverlay else { return }
            if self.ignoredHiddenKeyboardFrameDuringOverlayPreservation {
                if self.isPreservingSoftwareKeyboardForAppTransition {
                    // Symmetric with clearAppTransitionKeyboardPreservation's
                    // deferral: hand the pending hide to the app-transition
                    // latch instead of resizing layout while inactive.
                    self.ignoredHiddenKeyboardFrameDuringPreservation = true
                } else {
                    self.keyboardFrame = .zero
                    self.updateSoftwareKeyboardVisibility(false)
                    EffectManager.shared.clearPreservedKeyboardLayout()
                }
            }
            self.releaseOverlayKeyboardPreservationNow()
        }
    }

    /// Drop the latch immediately without committing anything. Used when the
    /// hide being processed is a real user action (foreign-window hide) — the
    /// normal notification flow then updates state — and as the final step of
    /// the scheduled release.
    @MainActor
    private func releaseOverlayKeyboardPreservationNow() {
        isPreservingSoftwareKeyboardForOverlay = false
        overlayPreservationCoversInputViewOnly = false
        ignoredHiddenKeyboardFrameDuringOverlayPreservation = false
        overlayKeyboardPreservationOwner = nil
        overlayKeyboardPreservationOwnerWindow = nil
        overlayOwnerWindowWasCaptured = false
        overlayKeyboardPreservationReleaseTask?.cancel()
        overlayKeyboardPreservationReleaseTask = nil
        EffectManager.shared.resyncKeyboardFrameAfterPreservation()
        // Terminals drop size pushes while the latch is armed (the container
        // safe-area shuffle when the keyboard physically hides/reshows wobbles
        // their bounds by the home-indicator inset). UIKit never re-fires a
        // dropped layout, so tell them to flush; an unchanged size dedupes to
        // nothing at the framebuffer cache.
        NotificationCenter.default.post(name: .overlayKeyboardPreservationEnded, object: nil)
    }

    /// Whether keyboard events still belong to the latch's owner window,
    /// judged by the activeAppearance trait — the established focus signal
    /// on iOS/iPadOS (isKeyWindow is unreliable with multi-window; see
    /// WindowSceneReporter.currentWindowIsKey). True when ownership was
    /// never window-resolved (bias toward preserving); false when the
    /// owner's window died or another window took focus.
    @MainActor
    private var overlayKeyboardPreservationOwnerWindowIsActive: Bool {
        guard overlayOwnerWindowWasCaptured else { return true }
        // Owner window deallocated: nothing left to preserve for.
        guard let window = overlayKeyboardPreservationOwnerWindow else { return false }
        // == .active matches the repo's authoritative focus checks
        // (WindowSceneReporter.currentWindowIsKey); .unspecified must NOT
        // count as active or a foreign window's hide stays swallowed during
        // attachment/scene transitions.
        if window.traitCollection.activeAppearance == .active { return true }
        // Asymmetric on purpose: `.active` on the owner keeps preserving, but
        // its ABSENCE does not stop it. Both `.inactive` and `.unspecified`
        // occur transiently while the iPhone tab sidebar is reparented onto
        // this same window and takes first responder, and releasing there drops
        // the latch mid-open — one bounce in each direction. Require positive
        // evidence that another window took focus. That also subsumes the old
        // isAppOrSceneTransitioningAway case: during an app/scene transition no
        // foreign window is active, so this still preserves.
        return !foreignWindowHoldsFocus(besides: window)
    }

    /// Whether a window other than the latch owner's holds focus. Other scenes
    /// only: same-scene system windows (remote keyboard, text effects) report
    /// `.active` and would be false positives. Uses `activeAppearance`, never
    /// `isKeyWindow` — see WindowSceneReporter.currentWindowIsKey. Always false
    /// on single-window iPhone.
    @MainActor
    private func foreignWindowHoldsFocus(besides ownerWindow: UIWindow) -> Bool {
        guard let ownerScene = ownerWindow.windowScene else { return false }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene !== ownerScene,
                  windowScene.activationState == .foregroundActive else { continue }
            for window in windowScene.windows
            where window.windowLevel == .normal
                && !window.isHidden
                && window.rootViewController != nil {
                if window.traitCollection.activeAppearance == .active { return true }
            }
        }
        return false
    }

    /// Notification-time read of the overlay latch that also detects an owner
    /// that died without calling end (a window destroyed with its overlay
    /// open) and starts the release path for it.
    @MainActor
    private func overlayKeyboardPreservationIsActive() -> Bool {
        if isPreservingSoftwareKeyboardForOverlay,
           overlayKeyboardPreservationReleaseTask == nil,
           overlayKeyboardPreservationOwner == nil {
            scheduleOverlayKeyboardPreservationRelease()
        }
        return isPreservingSoftwareKeyboardForOverlay
    }

    // MARK: - GCKeyboard Input Handler for CTRL+Arrow

    /// Key repeat state for GCKeyboard-routed keys.
    @MainActor
    private var trackedRepeatTimer: Timer?
    @MainActor
    private var trackedRepeatKeyCode: GCKeyCode?
    @MainActor
    private var trackedRepeatValidator: (() -> Bool)?
    @MainActor
    private var trackedRepeatAction: (() -> Void)?

    /// Key repeat timing (matches macOS fastest settings)
    private let keyRepeatDelay: TimeInterval = 0.225
    private let keyRepeatInterval: TimeInterval = 0.03

    @MainActor
    private func setupKeyboardInputHandler() {
        #if !os(visionOS)
        guard let keyboard = GCKeyboard.coalesced,
              let keyboardInput = keyboard.keyboardInput else {
            Ghostty.logger.debug("KeyboardTracker: No keyboard input available")
            return
        }

        refreshHardwareModifierState()

        keyboardInput.keyChangedHandler = { [weak self] _, key, keyCode, pressed in
            // Detect modifier key changes to refresh link detection
            // (e.g., Cmd+hover should highlight links without requiring mouse movement)
            let isModifierKey = keyCode == .leftGUI || keyCode == .rightGUI ||
                                keyCode == .leftControl || keyCode == .rightControl ||
                                keyCode == .leftShift || keyCode == .rightShift ||
                                keyCode == .leftAlt || keyCode == .rightAlt
            if isModifierKey {
                // The main dispatch queue preserves edge order. Independent
                // MainActor tasks may execute a rapid press/release out of
                // order and leave the shared modifier snapshot latched.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.notifyModifierKeyChange(keyCode: keyCode, pressed: pressed)
                    }
                }
                return
            }

            // Check if Control is held
            guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
            let leftCtrl = input.button(forKeyCode: .leftControl)?.isPressed ?? false
            let rightCtrl = input.button(forKeyCode: .rightControl)?.isPressed ?? false
            let ctrlHeld = leftCtrl || rightCtrl
            let leftShift = input.button(forKeyCode: .leftShift)?.isPressed ?? false
            let rightShift = input.button(forKeyCode: .rightShift)?.isPressed ?? false
            let shiftHeld = leftShift || rightShift

            // Check if this is an arrow key
            let isArrowKey = keyCode == .upArrow || keyCode == .downArrow ||
                             keyCode == .leftArrow || keyCode == .rightArrow

            // On Mac Catalyst, Option+printable keys don't fire pressesBegan.
            // Handle them here via GCKeyboard so Ghostty's encoder produces
            // correct sequences. Only catch printable keys — Tab, Escape, F-keys,
            // Return, and arrows have dedicated UIKeyCommand handlers.
            #if targetEnvironment(macCatalyst)
            let leftAlt = input.button(forKeyCode: .leftAlt)?.isPressed ?? false
            let rightAlt = input.button(forKeyCode: .rightAlt)?.isPressed ?? false
            let altHeld = leftAlt || rightAlt
            // ⌘⌥ chords are app shortcuts (UIKeyCommand / keybinds via
            // pressesBegan, which does fire with Command held); forwarding them
            // here would also type Alt+key into whatever terminal is focused.
            let leftCmd = input.button(forKeyCode: .leftGUI)?.isPressed ?? false
            let rightCmd = input.button(forKeyCode: .rightGUI)?.isPressed ?? false
            let cmdHeld = leftCmd || rightCmd

            let isSpecialKey = isArrowKey
                || keyCode == .tab || keyCode == .escape || keyCode == .returnOrEnter
                || keyCode == .deleteOrBackspace || keyCode == .deleteForward
                || keyCode == .home || keyCode == .end
                || keyCode == .pageUp || keyCode == .pageDown
                || (keyCode.rawValue >= GCKeyCode.F1.rawValue
                    && keyCode.rawValue <= GCKeyCode.F12.rawValue)

            if altHeld && !cmdHeld && !isSpecialKey {
                if pressed {
                    Task { @MainActor in
                        self?.handleModifierPrintableKeyDown(
                            keyCode,
                            controlHeld: ctrlHeld,
                            shiftHeld: shiftHeld
                        )
                    }
                } else {
                    Task { @MainActor in
                        self?.handleTrackedPrintableKeyUp(keyCode)
                    }
                }
                return
            }

            if !pressed {
                Task { @MainActor in
                    self?.handleTrackedPrintableKeyUp(keyCode)
                }
            }
            #endif

            // Only handle Ctrl+Arrow keys here
            // Ctrl+A-Z are handled via UIKeyCommand on Mac Catalyst for proper multi-window routing
            guard isArrowKey else { return }

            guard ctrlHeld else {
                // Control released - stop any repeat
                Task { @MainActor in
                    self?.stopTrackedKeyRepeat()
                }
                return
            }

            if pressed {
                Task { @MainActor in
                    self?.handleCtrlArrowDown(keyCode)
                }
            } else {
                Task { @MainActor in
                    self?.stopTrackedKeyRepeat(matching: keyCode)
                }
            }
        }
        #endif
    }

    @MainActor
    private func handleCtrlArrowDown(_ keyCode: GCKeyCode) {
        // Send initial key press
        sendCtrlArrowSequence(keyCode)

        // Start key repeat after delay
        startTrackedKeyRepeat(for: keyCode, validator: {
            #if !os(visionOS)
            guard let input = GCKeyboard.coalesced?.keyboardInput else {
                return false
            }
            let leftCtrl = input.button(forKeyCode: .leftControl)?.isPressed ?? false
            let rightCtrl = input.button(forKeyCode: .rightControl)?.isPressed ?? false
            return leftCtrl || rightCtrl
            #else
            return false
            #endif
        }, action: { [weak self] in
            self?.sendCtrlArrowSequence(keyCode)
        })
    }

    @MainActor
    private func startTrackedKeyRepeat(
        for keyCode: GCKeyCode,
        validator: @escaping () -> Bool,
        action: @escaping () -> Void
    ) {
        stopTrackedKeyRepeat()
        trackedRepeatKeyCode = keyCode
        trackedRepeatValidator = validator
        trackedRepeatAction = action

        let delay = keyRepeatDelay
        let interval = keyRepeatInterval

        let delayTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.trackedRepeatKeyCode == keyCode else { return }
                guard self.trackedRepeatValidator?() != false else {
                    self.stopTrackedKeyRepeat(matching: keyCode)
                    return
                }

                let repeatTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.trackedRepeatKeyCode == keyCode else { return }
                        guard self.trackedRepeatValidator?() != false else {
                            self.stopTrackedKeyRepeat(matching: keyCode)
                            return
                        }
                        self.trackedRepeatAction?()
                    }
                }
                RunLoop.main.add(repeatTimer, forMode: .common)
                self.trackedRepeatTimer = repeatTimer
            }
        }
        RunLoop.main.add(delayTimer, forMode: .common)
        trackedRepeatTimer = delayTimer
    }

    @MainActor
    private func stopTrackedKeyRepeat(matching keyCode: GCKeyCode? = nil) {
        guard keyCode == nil || trackedRepeatKeyCode == keyCode else { return }
        trackedRepeatTimer?.invalidate()
        trackedRepeatTimer = nil
        trackedRepeatKeyCode = nil
        trackedRepeatValidator = nil
        trackedRepeatAction = nil
    }

    #if targetEnvironment(macCatalyst)
    /// Handle Option-based printable key chords on Mac Catalyst via GCKeyboard.
    /// pressesBegan doesn't fire for Option+printable on Catalyst, so this is
    /// the only path that can route through Ghostty's encoder for layout-correct encoding.
    @MainActor
    private func handleModifierPrintableKeyDown(
        _ keyCode: GCKeyCode,
        controlHeld: Bool,
        shiftHeld: Bool
    ) {
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        guard let terminalView = findTerminalView(in: keyWindow) else { return }
        guard terminalView.shouldOptionActAsAlt() else { return }

        // GCKeyCode raw values match UIKeyboardHIDUsage raw values (both are USB HID)
        guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }

        var keyModifiers: UIKeyModifierFlags = .alternate
        if controlHeld { keyModifiers.insert(.control) }
        if shiftHeld { keyModifiers.insert(.shift) }

        let sent = terminalView.sendCatalystPrintableKeyViaGhostty(
            hidUsage: hidUsage,
            action: .press,
            control: controlHeld,
            shift: shiftHeld,
            alt: true
        )

        guard sent else { return }
        terminalView.didHandleOptionKey = true
        terminalView.specialKeyPressModifiers[hidUsage] = keyModifiers

        startTrackedKeyRepeat(for: keyCode, validator: {
            guard terminalView.shouldOptionActAsAlt() else { return false }
            guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
            guard input.button(forKeyCode: keyCode)?.isPressed == true else { return false }

            let leftAlt = input.button(forKeyCode: .leftAlt)?.isPressed ?? false
            let rightAlt = input.button(forKeyCode: .rightAlt)?.isPressed ?? false
            guard leftAlt || rightAlt else { return false }

            if controlHeld {
                let leftCtrl = input.button(forKeyCode: .leftControl)?.isPressed ?? false
                let rightCtrl = input.button(forKeyCode: .rightControl)?.isPressed ?? false
                guard leftCtrl || rightCtrl else { return false }
            }

            if shiftHeld {
                let leftShift = input.button(forKeyCode: .leftShift)?.isPressed ?? false
                let rightShift = input.button(forKeyCode: .rightShift)?.isPressed ?? false
                guard leftShift || rightShift else { return false }
            }

            return true
        }, action: { [weak terminalView] in
            guard let terminalView else { return }
            _ = terminalView.sendCatalystPrintableKeyViaGhostty(
                hidUsage: hidUsage,
                action: .repeat,
                control: controlHeld,
                shift: shiftHeld,
                alt: true
            )
        })
    }

    /// Send release event for any tracked printable key handled through Ghostty.
    @MainActor
    private func handleTrackedPrintableKeyUp(_ keyCode: GCKeyCode) {
        stopTrackedKeyRepeat(matching: keyCode)

        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        guard let terminalView = findTerminalView(in: keyWindow) else { return }
        guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }

        if let pressModifiers = terminalView.specialKeyPressModifiers.removeValue(forKey: hidUsage) {
            terminalView.sendKeyViaGhostty(
                keyCode: hidUsage, action: .release, modifiers: pressModifiers
            )
        }
    }
    #endif

    @MainActor
    private func sendCtrlArrowSequence(_ keyCode: GCKeyCode) {
        // Find the key window and active TerminalView
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return
        }

        guard let terminalView = findTerminalView(in: keyWindow) else {
            return
        }

        // Map GCKeyCode to direction character
        let directionCode: Character
        switch keyCode {
        case .upArrow: directionCode = "A"
        case .downArrow: directionCode = "B"
        case .rightArrow: directionCode = "C"
        case .leftArrow: directionCode = "D"
        default: return
        }

        // Check for additional modifiers
        var modifierParam = 5 // Base CTRL
        #if !os(visionOS)
        if let input = GCKeyboard.coalesced?.keyboardInput {
            let leftShift = input.button(forKeyCode: .leftShift)?.isPressed ?? false
            let rightShift = input.button(forKeyCode: .rightShift)?.isPressed ?? false
            if leftShift || rightShift { modifierParam += 1 }

            let leftAlt = input.button(forKeyCode: .leftAlt)?.isPressed ?? false
            let rightAlt = input.button(forKeyCode: .rightAlt)?.isPressed ?? false
            if leftAlt || rightAlt { modifierParam += 2 }
        }
        #endif

        // Send CSI 1;{modifier}{direction} sequence
        let sequence = "\u{1B}[1;\(modifierParam)\(directionCode)"

        if let data = sequence.data(using: .utf8) {
            terminalView.sendUserInput(data)
        }
    }

    @MainActor
    private func notifyModifierKeyChange(keyCode: GCKeyCode, pressed: Bool) {
        updateHardwareModifierState(keyCode: keyCode, pressed: pressed)

        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
              let terminalView = findTerminalView(in: keyWindow) else {
            return
        }
        terminalView.handleModifierKeyChange(keyCode: keyCode, pressed: pressed)
    }

    @MainActor
    private func updateHardwareModifierState(keyCode: GCKeyCode, pressed: Bool) {
        guard Self.isModifierKey(keyCode) else { return }
        if pressed, UIApplication.shared.applicationState == .active {
            shortcutRecoveryModifierKeys.insert(keyCode)
        } else {
            shortcutRecoveryModifierKeys.remove(keyCode)
        }
        if pressed {
            pressedHardwareModifierKeys.insert(keyCode)
        } else {
            pressedHardwareModifierKeys.remove(keyCode)
        }
        setHardwareModifierFlags(Self.modifierFlags(for: pressedHardwareModifierKeys))
    }

    @MainActor
    private func refreshHardwareModifierState() {
        #if os(visionOS)
        resetHardwareModifierState()
        #else
        guard let input = GCKeyboard.coalesced?.keyboardInput else {
            resetHardwareModifierState()
            return
        }
        let keys = Self.modifierKeyCodes.filter {
            input.button(forKeyCode: $0)?.isPressed == true
        }
        pressedHardwareModifierKeys = Set(keys)
        setHardwareModifierFlags(Self.modifierFlags(for: pressedHardwareModifierKeys))
        #endif
    }

    @MainActor
    private func resetHardwareModifierState() {
        shortcutRecoveryModifierKeys.removeAll()
        pressedHardwareModifierKeys.removeAll()
        setHardwareModifierFlags([])
    }

    @MainActor
    private func setHardwareModifierFlags(_ flags: UIKeyModifierFlags) {
        guard hardwareModifierFlags != flags else { return }
        hardwareModifierFlags = flags
        for continuation in hardwareModifierStateContinuations.values {
            continuation.yield(flags)
        }
    }

    private static let modifierKeyCodes: [GCKeyCode] = [
        .leftGUI, .rightGUI, .leftControl, .rightControl,
        .leftShift, .rightShift, .leftAlt, .rightAlt,
    ]

    private static func isModifierKey(_ keyCode: GCKeyCode) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    private static func modifierFlags(for keys: Set<GCKeyCode>) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if keys.contains(.leftGUI) || keys.contains(.rightGUI) { flags.insert(.command) }
        if keys.contains(.leftControl) || keys.contains(.rightControl) { flags.insert(.control) }
        if keys.contains(.leftShift) || keys.contains(.rightShift) { flags.insert(.shift) }
        if keys.contains(.leftAlt) || keys.contains(.rightAlt) { flags.insert(.alternate) }
        return flags
    }

    @MainActor
    private func findTerminalView(in view: UIView) -> Ghostty.TerminalView? {
        if let terminalView = view as? Ghostty.TerminalView, terminalView.isFirstResponder {
            return terminalView
        }
        for subview in view.subviews {
            if let found = findTerminalView(in: subview) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private func updateHardwareKeyboardState(_ newState: Bool) {
        // On macOS, always use hardware keyboard
        if isMacOSCompatibilityMode {
            return
        }

        let wasHardwareKeyboard = isHardwareKeyboard
        isHardwareKeyboard = newState

        if wasHardwareKeyboard != isHardwareKeyboard {
            Ghostty.logger.debug("KeyboardTracker: Hardware keyboard state changed to \(self.isHardwareKeyboard)")
            notifyHardwareKeyboardStateChanged(isHardwareKeyboard)
        }
    }

    @MainActor
    private func notifyHardwareKeyboardStateChanged(_ state: Bool) {
        for continuation in hardwareKeyboardStateContinuations.values {
            continuation.yield(state)
        }
    }

    @MainActor
    private func updateSoftwareKeyboardVisibility(_ isVisible: Bool) {
        let wasVisible = isSoftwareKeyboardVisible
        isSoftwareKeyboardVisible = isVisible

        if wasVisible != isSoftwareKeyboardVisible {
            let visible = isSoftwareKeyboardVisible
            Ghostty.logger.debug("KeyboardTracker: Software keyboard visibility changed to \(visible)")
            for continuation in softwareKeyboardVisibilityContinuations.values {
                continuation.yield(isSoftwareKeyboardVisible)
            }
        }
    }

    @MainActor
    private func setKeyboardAnimating(_ animating: Bool) {
        guard isKeyboardAnimating != animating else { return }
        isKeyboardAnimating = animating

        keyboardAnimationSafetyTimer?.invalidate()
        keyboardAnimationSafetyTimer = nil

        if animating {
            // Safety net: auto-clear after 1s in case didShow/didHide is never delivered
            // (app backgrounding mid-animation, focus loss, interrupted transition).
            // Keyboard animations are typically ~250ms, so 1s is very generous.
            keyboardAnimationSafetyTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setKeyboardAnimating(false)
                }
            }
        }

        for continuation in keyboardAnimationContinuations.values {
            continuation.yield(animating)
        }
    }

    // MARK: - UIKeyboard Notification Handlers (Frame Tracking)

    @MainActor
    @objc private func keyboardWillShow(_ notification: Notification) {
        updateKeyboardFrame(from: notification)
        setKeyboardAnimating(true)
    }

    @MainActor
    @objc private func keyboardWillHide(_ notification: Notification) {
        guard !shouldPreserveKeyboardStateForOverlay(notification) else {
            setKeyboardAnimating(false)
            return
        }
        guard !shouldPreserveKeyboardStateForAppTransition(notification) else {
            setKeyboardAnimating(false)
            return
        }
        updateKeyboardFrame(from: notification)
        setKeyboardAnimating(true)
    }

    @MainActor
    @objc private func keyboardDidShow(_ notification: Notification) {
        setKeyboardAnimating(false)
    }

    @MainActor
    @objc private func keyboardDidHide(_ notification: Notification) {
        guard !shouldPreserveKeyboardStateForOverlay(notification) else {
            setKeyboardAnimating(false)
            return
        }
        guard !shouldPreserveKeyboardStateForAppTransition(notification) else { return }
        setKeyboardAnimating(false)
    }

    /// Overlay-latch bookkeeping only, so a dismissal the OS signals as a bare
    /// will/didChangeFrame pair is recognized at will time instead of one
    /// animation later. Symmetric, so the re-show edge can't lag either.
    /// Deliberately never assigns `keyboardFrame` or touches
    /// `setKeyboardAnimating` — willChangeFrame repeats during an interactive
    /// drag with no guaranteed terminator, and sizeDidChange bails while
    /// animating. Inert when the matching willHide/willShow does arrive: same
    /// runloop turn, and every branch here is idempotent.
    @MainActor
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard isPreservingSoftwareKeyboardForOverlay else { return }
        guard let keyboardFrameEnd =
                notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        guard overlayKeyboardPreservationOwnerWindowIsActive else {
            // Same as the willHide and didChangeFrame paths: keyboard activity
            // in a foreign focused window is real. Releasing here rather than
            // returning matters because EffectManager gates on the latch when
            // it applies frames, and its visibility-stream consumer only bumps
            // keyboardStateVersion — it never clears keyboardFrame/height. A
            // latch left armed through this notification would have it discard
            // the hidden frame and keep the terminal padded for a vanished
            // keyboard.
            releaseOverlayKeyboardPreservationNow()
            return
        }
        if isPreservedLayoutFrameVisible(keyboardFrameEnd, inputViewOnly: overlayPreservationCoversInputViewOnly) {
            // Mirrors updateKeyboardFrame's visible-frame branch: refresh the
            // latched geometry without ending the latch. Release stays with the
            // other handlers so this one has no release path of its own.
            ignoredHiddenKeyboardFrameDuringOverlayPreservation = false
        } else {
            _ = shouldPreserveKeyboardStateForOverlay(notification)
        }
    }

    @MainActor
    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        updateKeyboardFrame(from: notification)
    }

    @MainActor
    private func updateKeyboardFrame(from notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrameEnd = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        if overlayKeyboardPreservationIsActive() {
            if overlayKeyboardPreservationOwnerWindowIsActive {
                guard isPreservedLayoutFrameVisible(keyboardFrameEnd, inputViewOnly: overlayPreservationCoversInputViewOnly) else {
                    ignoredHiddenKeyboardFrameDuringOverlayPreservation = true
                    return
                }
                // A visible frame (close-side re-show, rotation, a sheet's own
                // keyboard) refreshes the latched geometry without clearing the
                // latch — the overlay presence, not a frame event, ends it.
                ignoredHiddenKeyboardFrameDuringOverlayPreservation = false
            } else {
                // Keyboard activity in a foreign focused window is real —
                // drop the freeze and process the frame normally.
                releaseOverlayKeyboardPreservationNow()
            }
        }

        if isPreservingSoftwareKeyboardForAppTransition {
            guard isPreservedLayoutFrameVisible(keyboardFrameEnd, inputViewOnly: appTransitionPreservationCoversInputViewOnly) else {
                ignoredHiddenKeyboardFrameDuringPreservation = true
                Ghostty.logger.debug("KeyboardTracker: Ignored transient app-transition keyboard frame")
                return
            }
            ignoredHiddenKeyboardFrameDuringPreservation = false
            clearAppTransitionKeyboardPreservation()
        }

        keyboardFrame = keyboardFrameEnd
        let visibleHeight = visibleKeyboardHeight(for: keyboardFrameEnd)
        updateSoftwareKeyboardVisibility(visibleHeight > Self.softwareKeyboardHeightThreshold)

        // On macOS, always use hardware keyboard (no on-screen keyboard available)
        if isMacOSCompatibilityMode {
            Ghostty.logger.debug("KeyboardTracker: Running on macOS, always using hardware keyboard")
            return
        }

        // On visionOS, use height-based detection as fallback since GCKeyboard may not be available
        #if os(visionOS)
        let wasHardwareKeyboard = isHardwareKeyboard
        // Use height-based detection: software keyboards are tall (200-350pt)
        // Hardware keyboard accessory bars are small (< 100pt)
        isHardwareKeyboard = keyboardFrameEnd.height < 100

        if wasHardwareKeyboard != isHardwareKeyboard {
            Ghostty.logger.debug("KeyboardTracker: visionOS height-based detection - isHardware=\(self.isHardwareKeyboard)")
            notifyHardwareKeyboardStateChanged(isHardwareKeyboard)
        }
        #else
        // On iOS/iPadOS, GCKeyboard handles detection - we just track the frame here
        // Double-check GCKeyboard state in case notifications were missed
        let gcKeyboardConnected = GCKeyboard.coalesced != nil
        if gcKeyboardConnected != isHardwareKeyboard {
            Ghostty.logger.debug("KeyboardTracker: GCKeyboard state sync - was \(self.isHardwareKeyboard), now \(gcKeyboardConnected)")
            updateHardwareKeyboardState(gcKeyboardConnected)
            // Reinstall key handler if keyboard reconnected - the old handler was on a different instance
            if gcKeyboardConnected {
                setupKeyboardInputHandler()
            }
        }
        #endif

        Ghostty.logger.debug("KeyboardTracker: Frame updated, height=\(keyboardFrameEnd.height), isHardware=\(self.isHardwareKeyboard)")
    }

    @MainActor
    private func shouldPreserveKeyboardStateForOverlay(_ notification: Notification) -> Bool {
        guard overlayKeyboardPreservationIsActive() else { return false }
        guard overlayKeyboardPreservationOwnerWindowIsActive else {
            // A hide while another window has focus is that window's user
            // dismissing its keyboard — release the freeze (its preserved
            // layout is already gone) and let the hide process normally.
            releaseOverlayKeyboardPreservationNow()
            return false
        }
        guard let userInfo = notification.userInfo,
              let keyboardFrameEnd = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            ignoredHiddenKeyboardFrameDuringOverlayPreservation = true
            return true
        }
        let shouldPreserve = !isPreservedLayoutFrameVisible(keyboardFrameEnd, inputViewOnly: overlayPreservationCoversInputViewOnly)
        if shouldPreserve {
            ignoredHiddenKeyboardFrameDuringOverlayPreservation = true
        }
        return shouldPreserve
    }

    @MainActor
    private func shouldPreserveKeyboardStateForAppTransition(_ notification: Notification) -> Bool {
        if !isPreservingSoftwareKeyboardForAppTransition {
            guard isAnyInputViewPresented,
                  isAppOrSceneTransitioningAway else {
                return false
            }
            beginAppTransitionKeyboardPreservationIfNeeded(autoClearIfAppStaysActive: true)
        }

        guard let userInfo = notification.userInfo,
              let keyboardFrameEnd = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            ignoredHiddenKeyboardFrameDuringPreservation = true
            return true
        }
        let shouldPreserve = !isPreservedLayoutFrameVisible(keyboardFrameEnd, inputViewOnly: appTransitionPreservationCoversInputViewOnly)
        if shouldPreserve {
            ignoredHiddenKeyboardFrameDuringPreservation = true
        }
        return shouldPreserve
    }

    @MainActor
    private var isAppOrSceneTransitioningAway: Bool {
        if UIApplication.shared.applicationState != .active {
            return true
        }

        let scenes = UIApplication.shared.connectedScenes
        let hasForegroundActiveScene = scenes.contains { $0.activationState == .foregroundActive }
        let hasForegroundInactiveScene = scenes.contains { $0.activationState == .foregroundInactive }
        return hasForegroundInactiveScene && !hasForegroundActiveScene
    }

    @MainActor
    private func isSoftwareKeyboardFrameVisible(_ keyboardFrame: CGRect) -> Bool {
        visibleKeyboardHeight(for: keyboardFrame) > Self.softwareKeyboardHeightThreshold
    }

    @MainActor
    private func visibleKeyboardHeight(for keyboardFrame: CGRect) -> CGFloat {
        #if os(visionOS)
        return keyboardFrame.height
        #else
        let screenBounds = UIScreen.main.bounds
        let intersection = screenBounds.intersection(keyboardFrame)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        return intersection.height
        #endif
    }
}

extension Notification.Name {
    /// Posted when the overlay keyboard-preservation latch releases.
    /// Terminals that dropped size pushes while it was armed flush their
    /// current bounds (self-deduping) on receipt.
    static let overlayKeyboardPreservationEnded = Notification.Name("com.rootshell.overlayKeyboardPreservationEnded")
}
