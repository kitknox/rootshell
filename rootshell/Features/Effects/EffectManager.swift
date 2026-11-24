//
//  EffectManager.swift
//  rootshell
//
//  Manages terminal visual effects across the app
//

import Foundation
import Combine
import SwiftUI
import os
import UIKit

/// Manages terminal visual effects across the app
@MainActor
@Observable
final class EffectManager {
    static let shared = EffectManager()

    // MARK: - Observable Properties
    //
    // With `@Observable`, SwiftUI tracks per-property reads inside view bodies,
    // so a write to `keyboardFrame` only invalidates views that actually read
    // `keyboardFrame` — not every view that holds a reference to this manager.
    // (Under the previous `ObservableObject + @Published` design, any property
    // change invalidated every observer; that was the iPhone-keyboard-up scene
    // update churn that contributed to 0x8BADF00D watchdog kills during
    // background→foreground transitions.)

    /// All registered effects
    private(set) var availableEffects: [AnyTerminalEffect] = []

    /// Currently active effect (nil = no effect)
    var activeEffect: AnyTerminalEffect? {
        didSet {
            if !isReloading { saveActiveEffect() }
            // Recorded on reloads too, so the toggle restores the effect last shown on this device.
            if let id = activeEffect?.id { SettingsStore.shared.set(Settings.Shaders.lastActiveEffectId, id) }
            updateTextAboveEffectActive()
            effectDidChange.send()
        }
    }

    /// Keyboard selection is independent of the terminal, unless explicitly linked.
    var keyboardEffect: AnyTerminalEffect? {
        selectedEffect(id: SettingsStore.shared.value(Settings.Shaders.keyboardEffectId))
    }

    var sidebarEffect: AnyTerminalEffect? {
        let id = SettingsStore.shared.value(Settings.Shaders.sidebarEffectId)
        if id == BackgroundEffectSelection.followTerminalID,
           !SettingsStore.shared.value(Settings.Shaders.effectIncludesPinnedSidebar) { return nil }
        return selectedEffect(id: id)
    }

    func selectedEffect(id: String) -> AnyTerminalEffect? {
        id == BackgroundEffectSelection.followTerminalID ? activeEffect : effect(withId: id)
    }

    /// Full-window gradient behind all content, configured apart from the
    /// Theme Gradient area effect.
    @ObservationIgnored let backdropEffect = AnyTerminalEffect(ThemeGradientEffect(isBackdrop: true))

    var isBackdropEnabled = false {
        didSet {
            guard isBackdropEnabled != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Shaders.themeGradientBackdrop, isBackdropEnabled) }
            // The config carries the backdrop OSC 11 color, and off the Mac
            // terminal opacity too. Not during init: the config writer reads
            // it back through `shared`.
            if isLoaded { TransparencyManager.shared.transparencyDidChange.send() }
        }
    }

    /// The backdrop's look, observed by surfaces derived from it.
    private(set) var backdropLook = ThemeGradientLook()
    @ObservationIgnored private var backdropLookConfigTask: Task<Void, Never>?

    /// Area effects draw between an app-drawn terminal background and
    /// glyph-only terminals, so text keeps its own colors.
    var isTextAboveEffectEnabled = true {
        didSet {
            guard isTextAboveEffectEnabled != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Shaders.textAboveEffect, isTextAboveEffectEnabled) }
            updateTextAboveEffectActive()
        }
    }

    /// Ghostty draws no default background while set; see `TransparencyManager.terminalSurfaceOpacity`.
    private(set) var isTextAboveEffectActive = false

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var isLoaded = false

    /// Theme colors for effects (updated from ThemeManager)
    private(set) var themeColors: EffectThemeColors = .defaults

    /// Whether the current theme has a light background
    private(set) var isLightTheme: Bool = false

    /// Current keyboard height (for adjusting effect geometry)
    private(set) var keyboardHeight: CGFloat = 0
    private(set) var keyboardFrame: CGRect = .zero

    /// Whether the keyboard is docked at the bottom of the screen (iPad only)
    /// When false, keyboard is floating/undocked and we skip keyboard avoidance
    private(set) var isKeyboardDocked: Bool = false

    /// Version counter that increments on keyboard state changes to force SwiftUI re-render
    private(set) var keyboardStateVersion: Int = 0

    /// Bottom inset fraction for terminal when ocean effect is active (0.0-1.0)
    var terminalBottomInsetFraction: CGFloat {
        guard let effect = activeEffect,
              effect.id == "solarGraph",
              let solarEffect = effect.asEffect(SolarGraphEffect.self),
              solarEffect.showOcean else {
            return 0
        }
        // Ocean sits below horizon at height * 0.92
        // Move terminal to end exactly at horizon line
        return 0.08
    }

    // MARK: - Publishers

    /// Emits when active effect or its configuration changes
    @ObservationIgnored let effectDidChange = PassthroughSubject<Void, Never>()

    /// Keyboard and toolbar geometry changes, including responder handoffs.
    @ObservationIgnored let keyboardStateDidChange = PassthroughSubject<Void, Never>()

    /// Actual keyboard environment changes that may require new input views.
    /// Toolbar layout/focus notifications only invalidate SwiftUI geometry;
    /// feeding those back into reloadInputViews rebuilds UIKit's input set
    /// again after every first-responder handoff.
    @ObservationIgnored let keyboardEnvironmentDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Private Properties

    @ObservationIgnored private var themeObserverCancellable: AnyCancellable?
    @ObservationIgnored private var effectConfigCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var hardwareKeyboardTask: Task<Void, Never>?
    @ObservationIgnored private var softwareKeyboardVisibilityTask: Task<Void, Never>?
    private static let softwareKeyboardHeightThreshold: CGFloat = 120

    // MARK: - Video Background Pending Activation

    private static let pendingVideoActivationKey = "pendingVideoActivation"

    /// Video ID waiting to be activated after download completes
    private(set) var pendingVideoActivation: String? {
        didSet {
            UserDefaults.standard.set(pendingVideoActivation, forKey: Self.pendingVideoActivationKey)
        }
    }

    // MARK: - Initialization

    private init() {
        // Load persisted pending video activation
        pendingVideoActivation = UserDefaults.standard.string(forKey: Self.pendingVideoActivationKey)

        // Register built-in effects first
        registerBuiltInEffects()
        setUpBackdrop()

        // Setup video download completion handler
        setupVideoDownloadHandler()

        // Subscribe to theme changes
        setupThemeObserver()

        // Subscribe to keyboard frame changes
        setupKeyboardObserver()

        // Subscribe to hardware keyboard state changes to reset keyboard height
        hardwareKeyboardTask = Task { @MainActor [weak self] in
            for await isHardware in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                guard let self else { continue }
                self.notifyKeyboardEnvironmentChanged()
                if isHardware {
                    if self.keyboardHeight != 0 { self.keyboardHeight = 0 }
                } else {
                    self.updateKeyboardHeightFromTracker()
                }
            }
        }

        softwareKeyboardVisibilityTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                guard let self else { continue }
                self.notifyKeyboardEnvironmentChanged()
            }
        }

        // Load persisted settings (must happen after effects are registered)
        loadSettings()

        SettingsRefreshHub.shared.register(keys: [
            Settings.Shaders.activeEffectId.name, Settings.Shaders.effectConfigurations.name,
            Settings.Shaders.themeGradientBackdrop.name, Settings.Shaders.textAboveEffect.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }
        isLoaded = true
    }

    private func setUpBackdrop() {
        restoreConfiguration(for: backdropEffect)
        backdropEffect.themeColors = themeColors
        syncBackdropLook()
        effectConfigCancellables[backdropEffect.id] = backdropEffect.configurationDidChange
            .sink { [weak self] in
                guard let self else { return }
                self.saveEffectConfiguration(self.backdropEffect)
                self.syncBackdropLook()
            }
    }

    private func syncBackdropLook() {
        guard let look = backdropEffect.asEffect(ThemeGradientEffect.self)?.look, look != backdropLook else { return }
        backdropLook = look
        guard isLoaded, isBackdropEnabled else { return }
        // The config carries the backdrop OSC 11 color; color pickers change it continuously
        backdropLookConfigTask?.cancel()
        backdropLookConfigTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            TransparencyManager.shared.transparencyDidChange.send()
        }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Shaders.effectConfigurations.name), let activeEffect {
            restoreConfiguration(for: activeEffect)
        }
        if keys.contains(Settings.Shaders.effectConfigurations.name), let keyboardEffect,
           keyboardEffect.id != activeEffect?.id {
            restoreConfiguration(for: keyboardEffect)
        }
        if keys.contains(Settings.Shaders.effectConfigurations.name), let sidebarEffect,
           sidebarEffect.id != activeEffect?.id, sidebarEffect.id != keyboardEffect?.id {
            restoreConfiguration(for: sidebarEffect)
        }
        if keys.contains(Settings.Shaders.effectConfigurations.name) {
            restoreConfiguration(for: backdropEffect)
        }
        if keys.contains(Settings.Shaders.activeEffectId.name) {
            activeEffect = SettingsStore.shared.get(Settings.Shaders.activeEffectId).flatMap { effect(withId: $0) }
        }
        if keys.contains(Settings.Shaders.themeGradientBackdrop.name) {
            isBackdropEnabled = SettingsStore.shared.get(Settings.Shaders.themeGradientBackdrop)
        }
        if keys.contains(Settings.Shaders.textAboveEffect.name) {
            isTextAboveEffectEnabled = SettingsStore.shared.get(Settings.Shaders.textAboveEffect)
        }
    }

    private func updateTextAboveEffectActive() {
        let active = isTextAboveEffectEnabled && activeEffect != nil
        guard active != isTextAboveEffectActive else { return }
        isTextAboveEffectActive = active
        // The config carries the surface opacity; not during init, as for the backdrop.
        if isLoaded { TransparencyManager.shared.transparencyDidChange.send() }
    }

    @ObservationIgnored private var coalescedKeyboardToolbarChangePending = false

    func notifyKeyboardToolbarLayoutChanged() {
        keyboardStateVersion += 1
        keyboardStateDidChange.send()
    }

    /// Coalesces back-to-back toolbar layout notifications within the same
    /// main run-loop turn (e.g. resignFirstResponder + becomeFirstResponder
    /// during a tab switch) into a single `keyboardStateVersion` bump.
    func scheduleCoalescedKeyboardToolbarLayoutChanged() {
        guard !coalescedKeyboardToolbarChangePending else { return }
        coalescedKeyboardToolbarChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coalescedKeyboardToolbarChangePending = false
            self.notifyKeyboardToolbarLayoutChanged()
        }
    }

    private func notifyKeyboardEnvironmentChanged() {
        keyboardStateVersion += 1
        keyboardStateDidChange.send()
        keyboardEnvironmentDidChange.send()
    }

    func clearPreservedKeyboardLayout() {
        var changed = false
        if keyboardHeight != 0 {
            keyboardHeight = 0
            changed = true
        }
        if keyboardFrame != .zero {
            keyboardFrame = .zero
            changed = true
        }
        if changed {
            notifyKeyboardEnvironmentChanged()
        }
    }

    // MARK: - Effect Registry

    /// Register a new effect
    func registerEffect<E: TerminalEffect>(_ effect: E) {
        let wrapped = AnyTerminalEffect(effect)

        guard !availableEffects.contains(where: { $0.id == wrapped.id }) else {
            Ghostty.logger.warning("Effect \(wrapped.id) already registered")
            return
        }

        // Restore configuration if available
        restoreConfiguration(for: wrapped)

        // Set initial theme colors
        wrapped.themeColors = themeColors

        // Subscribe to configuration changes
        effectConfigCancellables[wrapped.id] = wrapped.configurationDidChange
            .sink { [weak self, weak wrapped] in
                guard let self = self, let effect = wrapped else { return }
                self.saveEffectConfiguration(effect)
                if self.activeEffect?.id == effect.id || self.keyboardEffect?.id == effect.id
                    || self.sidebarEffect?.id == effect.id {
                    self.effectDidChange.send()
                }
            }

        availableEffects.append(wrapped)
        if keyboardEffect?.id == wrapped.id { effectDidChange.send() }
    }

    /// Get effect by ID
    func effect(withId id: String) -> AnyTerminalEffect? {
        return availableEffects.first { $0.id == id }
    }

    /// Set the active effect by ID (nil to disable)
    func setActiveEffect(id: String?) {
        if let id = id {
            activeEffect = effect(withId: id)
        } else {
            activeEffect = nil
        }
    }

    /// Toggle the background effect off, or back on to the last one selected.
    func toggleEffect() {
        if activeEffect != nil {
            activeEffect = nil
        } else if let lastId = SettingsStore.shared.get(Settings.Shaders.lastActiveEffectId) {
            activeEffect = effect(withId: lastId)
        }
    }

    // MARK: - Configuration Persistence

    private func saveActiveEffect() {
        if let id = activeEffect?.id {
            SettingsStore.shared.set(Settings.Shaders.activeEffectId, id)
        } else {
            SettingsStore.shared.reset(Settings.Shaders.activeEffectId)
        }
    }

    func saveEffectConfiguration(_ effect: AnyTerminalEffect) {
        var configs = loadAllConfigurations()
        configs[effect.id] = effect.encodeConfiguration()

        if let data = try? JSONSerialization.data(withJSONObject: configs) {
            SettingsStore.shared.set(Settings.Shaders.effectConfigurations, data)
        }
    }

    private func loadSettings() {
        isReloading = true
        isBackdropEnabled = SettingsStore.shared.get(Settings.Shaders.themeGradientBackdrop)
        isTextAboveEffectEnabled = SettingsStore.shared.get(Settings.Shaders.textAboveEffect)
        isReloading = false
        // Load active effect
        if let activeId = SettingsStore.shared.get(Settings.Shaders.activeEffectId) {
            activeEffect = effect(withId: activeId)
        }
    }

    private func loadAllConfigurations() -> [String: [String: Any]] {
        guard let data = SettingsStore.shared.get(Settings.Shaders.effectConfigurations),
              let configs = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else {
            return [:]
        }
        return configs
    }

    private func restoreConfiguration(for effect: AnyTerminalEffect) {
        let configs = loadAllConfigurations()
        if let config = configs[effect.id] {
            effect.decodeConfiguration(config)
        }
    }

    // MARK: - Theme Integration

    private func setupThemeObserver() {
        themeObserverCancellable = ThemeManager.shared.themeDidChange
            .sink { [weak self] _ in
                self?.updateThemeColors()
            }

        // Initial color sync
        updateThemeColors()
    }

    private func setupKeyboardObserver() {
        // Synchronous (matching TerminalView's observers) rather than hopping
        // through `Task { @MainActor }`: the hop drained a turn later, so the
        // preservation gate was read after every KeyboardTracker observer had
        // run. A frame enqueued with a hidden frame could drain just after the
        // latch released and zero the geometry driving terminalBottomPadding,
        // turning a latch drop into a second bounce.
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                self?.handleKeyboardFrameChange(keyboardFrame)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                self?.handleKeyboardFrameChange(keyboardFrame)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !KeyboardTracker.shared.isPreservingSoftwareKeyboardLayout else { return }
                if self.keyboardHeight != 0 { self.keyboardHeight = 0 }
                if self.keyboardFrame != .zero { self.keyboardFrame = .zero }
            }
        }
    }

    private func handleKeyboardFrameChange(_ keyboardFrame: CGRect?) {
        guard let keyboardFrame else {
            return
        }
        // The tracker holds every frame of an app round trip and resyncs
        // this once on release, so the padding never follows the flaps.
        if KeyboardTracker.shared.isPreservingSoftwareKeyboardForAppTransition { return }
        if KeyboardTracker.shared.isPreservingSoftwareKeyboardLayout,
           !isMeaningfulKeyboardFrame(keyboardFrame) {
            return
        }
        applyKeyboardFrame(keyboardFrame)
    }

    private func updateKeyboardHeightFromTracker() {
        applyKeyboardFrame(KeyboardTracker.shared.keyboardFrame)
    }

    /// Re-adopt the tracker's frame once a preservation latch drops. While
    /// latched, sub-threshold frames are rejected here but a toolbar-only
    /// latch accepts them in the tracker, so the two can diverge when an
    /// overlay's own field showed a full keyboard mid-trip.
    func resyncKeyboardFrameAfterPreservation() {
        updateKeyboardHeightFromTracker()
    }

    /// Apply a keyboard frame update, deduping each `@Published` set against
    /// the current value. `@Published` fires `objectWillChange` on every
    /// assignment, equal-or-not, so unconditional writes during keyboard
    /// notification storms broadcast 12–16 invalidations/s into MainView and
    /// every TabButton. Each downstream re-render is expensive (TabRenderInfo
    /// rebuild × N tabs, layout-pass cascade), so the savings compound.
    private func applyKeyboardFrame(_ keyboardFrame: CGRect) {
        if self.keyboardFrame != keyboardFrame {
            self.keyboardFrame = keyboardFrame
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let newDockedState = isKeyboardFrameDocked(keyboardFrame)
        if newDockedState != isKeyboardDocked {
            isKeyboardDocked = newDockedState
            notifyKeyboardEnvironmentChanged()
        }
        #endif

        let newHeight = adjustedKeyboardHeight(for: keyboardFrame)
        if keyboardHeight != newHeight {
            keyboardHeight = newHeight
        }
    }

    private func isMeaningfulKeyboardFrame(_ keyboardFrame: CGRect) -> Bool {
        guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return false }
        #if os(visionOS)
        return keyboardFrame.height > Self.softwareKeyboardHeightThreshold
        #else
        guard let screenBounds = activeWindowFrame() else { return false }
        let intersection = screenBounds.intersection(keyboardFrame)
        if intersection.isNull || intersection.isEmpty {
            return false
        }
        return intersection.height > Self.softwareKeyboardHeightThreshold
        #endif
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// Check if keyboard frame represents a docked keyboard (bottom edge at screen bottom)
    private func isKeyboardFrameDocked(_ keyboardFrame: CGRect) -> Bool {
        guard let windowFrame = activeWindowFrame() else { return false }
        return TerminalKeyboardGeometry.isDocked(keyboard: keyboardFrame, container: windowFrame)
    }
    #endif

    func keyboardOverlapHeight(in viewFrame: CGRect) -> CGFloat {
        keyboardOverlapHeight(in: viewFrame, keyboardFrame: keyboardFrame)
    }

    /// Calculates how much the keyboard overlaps with the given view frame.
    /// - Parameters:
    ///   - viewFrame: The view's frame in global coordinates
    ///   - keyboardFrame: The keyboard frame (passed explicitly for SwiftUI dependency tracking)
    func keyboardOverlapHeight(in viewFrame: CGRect, keyboardFrame: CGRect) -> CGFloat {
        if keyboardFrame.isNull || keyboardFrame.isEmpty {
            return 0
        }

        // On iPad, skip keyboard avoidance if keyboard is undocked/floating
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if !isKeyboardDocked {
            return 0
        }
        #endif

        let intersection = viewFrame.intersection(keyboardFrame)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }

        let height = intersection.height
        if KeyboardTracker.shared.isHardwareKeyboard && height < Self.softwareKeyboardHeightThreshold {
            return 0
        }

        return height
    }

    private func adjustedKeyboardHeight(for keyboardFrame: CGRect) -> CGFloat {
        // On iPad, skip keyboard height if keyboard is undocked/floating
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if !isKeyboardDocked {
            return 0
        }
        #endif

        let height = keyboardIntersectionHeight(for: keyboardFrame)
        guard height > 0 else { return 0 }

        if KeyboardTracker.shared.isHardwareKeyboard && height < Self.softwareKeyboardHeightThreshold {
            // Ignore accessory-only frames while hardware keyboard is attached.
            return 0
        }

        return height
    }

    private func keyboardIntersectionHeight(for keyboardFrame: CGRect) -> CGFloat {
        // Get the screen bounds to calculate intersection
        // visionOS doesn't have UIScreen.main - use keyboard frame directly
        #if os(visionOS)
        let screenBounds = keyboardFrame
        #else
        guard let screenBounds = activeWindowFrame() else { return 0 }
        #endif

        // Calculate how much of the keyboard is visible on screen
        // The keyboard frame is in screen coordinates
        let keyboardIntersection = screenBounds.intersection(keyboardFrame)

        // If keyboard is off-screen or has no intersection, height is 0
        if keyboardIntersection.isNull || keyboardIntersection.isEmpty {
            return 0
        }
        return keyboardIntersection.height
    }

    private func activeWindowFrame() -> CGRect? {
        #if os(visionOS)
        return nil
        #else
        guard let window = KeyboardTracker.shared.inputOwnerWindow else { return nil }
        return window.convert(window.bounds, to: window.screen.coordinateSpace)
        #endif
    }

    private func updateThemeColors() {
        let newThemeColors: EffectThemeColors
        let newIsLightTheme: Bool
        if let themeInfo = ThemeManager.shared.currentThemeInfo {
            newThemeColors = EffectThemeColors(from: themeInfo.colors)
            if let bgColor = Color(hex: themeInfo.colors.background) {
                newIsLightTheme = bgColor.isLight
            } else {
                newIsLightTheme = false
            }
        } else {
            newThemeColors = .defaults
            newIsLightTheme = false
        }

        if themeColors != newThemeColors { themeColors = newThemeColors }
        if isLightTheme != newIsLightTheme { isLightTheme = newIsLightTheme }

        for effect in availableEffects {
            effect.themeColors = themeColors
        }
        backdropEffect.themeColors = themeColors

        if activeEffect != nil {
            effectDidChange.send()
        }
    }

    // MARK: - Built-in Effects Registration

    private func registerBuiltInEffects() {
        registerEffect(AquariumEffect())
        registerEffect(AuroraEffect())
        registerEffect(ThemeGradientEffect())
        registerEffect(SolarGraphEffect())
        registerEffect(FirefliesEffect())
        registerEffect(ButterfliesEffect())
        registerEffect(JellyfishEffect())
        registerEffect(PhotoBackgroundEffect())
        #if !CHINA_BUILD
        registerEffect(LiveWeatherEffect())
        #endif

        // Register video background effects
        registerVideoBackgroundEffects()
    }

    private func registerVideoBackgroundEffects() {
        // Register effects for already-downloaded remote videos.
        // New downloads will be registered via handleVideoDownloadCompleted.
        for videoInfo in VideoBackgroundManager.shared.availableVideos {
            registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
        }

        // Register effects for user-imported local videos.
        for videoInfo in LocalVideoBackgroundManager.shared.availableVideos {
            registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
        }
    }

    // MARK: - Video Background Activation

    private func setupVideoDownloadHandler() {
        VideoBackgroundDownloadManager.shared.onDownloadCompleted = { [weak self] videoId in
            self?.handleVideoDownloadCompleted(videoId)
        }

        LocalVideoBackgroundManager.shared.onVideoImported = { [weak self] entry in
            self?.handleLocalVideoImported(entry)
        }

        LocalVideoBackgroundManager.shared.onVideoDeleted = { [weak self] videoId in
            self?.handleLocalVideoDeleted(videoId)
        }

        LocalVideoBackgroundManager.shared.onLoopingModeChanged = { [weak self] videoId in
            self?.handleLocalVideoLoopingModeChanged(videoId)
        }

        LocalVideoBackgroundManager.shared.onVideoRenamed = { [weak self] videoId in
            self?.handleLocalVideoRenamed(videoId)
        }
    }

    /// Request activation of a video effect (may trigger download if not cached for remote videos)
    func requestVideoEffectActivation(_ videoId: String) {
        // Local videos are always immediately available.
        if let videoInfo = LocalVideoBackgroundManager.shared.videoInfo(for: videoId) {
            let effectId = "videoBackground_\(videoId)"
            if effect(withId: effectId) == nil {
                registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
            }
            setActiveEffect(id: effectId)
            pendingVideoActivation = nil
            return
        }

        let downloadManager = VideoBackgroundDownloadManager.shared

        // Check if remote video is already downloaded.
        if let videoInfo = VideoBackgroundManager.shared.videoInfo(for: videoId) {
            let effectId = "videoBackground_\(videoId)"
            if effect(withId: effectId) == nil {
                registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
            }
            setActiveEffect(id: effectId)
            pendingVideoActivation = nil
            return
        }

        // Not downloaded - start download and set as pending
        guard let remote = VideoBackgroundManager.shared.remoteVideo(for: videoId) else {
            Ghostty.logger.warning("Cannot activate video - not found: \(videoId)")
            return
        }

        pendingVideoActivation = videoId
        downloadManager.startDownload(for: remote)
    }

    /// Cancel pending video activation
    func cancelPendingVideoActivation() {
        if let videoId = pendingVideoActivation {
            VideoBackgroundDownloadManager.shared.cancelDownload(for: videoId)
        }
        pendingVideoActivation = nil
    }

    /// Called when a video download completes
    private func handleVideoDownloadCompleted(_ videoId: String) {
        // Register the newly downloaded effect
        if let videoInfo = VideoBackgroundManager.shared.videoInfo(for: videoId) {
            let effectId = "videoBackground_\(videoId)"
            if effect(withId: effectId) == nil {
                registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
            }
        }

        // Activate if this was the pending video
        if pendingVideoActivation == videoId {
            let effectId = "videoBackground_\(videoId)"
            setActiveEffect(id: effectId)
            pendingVideoActivation = nil
        }
    }

    /// Called when a local video is imported. Registers and immediately activates it.
    private func handleLocalVideoImported(_ entry: LocalVideoBackground) {
        guard let videoInfo = LocalVideoBackgroundManager.shared.videoInfo(for: entry.id) else {
            return
        }
        let effectId = "videoBackground_\(entry.id)"
        if effect(withId: effectId) == nil {
            registerEffect(VideoBackgroundEffect(videoInfo: videoInfo))
        }
        setActiveEffect(id: effectId)
        pendingVideoActivation = nil
    }

    /// Called when a local video's looping mode changes. Rebuilds the effect
    /// so `VideoBackgroundUIView` reinitializes with the new seamless/crossfade
    /// configuration. Persisted intensity/speed are restored by `registerEffect`.
    private func handleLocalVideoLoopingModeChanged(_ videoId: String) {
        guard let freshInfo = LocalVideoBackgroundManager.shared.videoInfo(for: videoId) else {
            return
        }
        let effectId = "videoBackground_\(videoId)"
        let wasActive = activeEffect?.id == effectId

        availableEffects.removeAll { $0.id == effectId }
        effectConfigCancellables.removeValue(forKey: effectId)

        registerEffect(VideoBackgroundEffect(videoInfo: freshInfo))

        if wasActive {
            setActiveEffect(id: effectId)
        }
    }

    /// Called when a local video is renamed. Rebuilds the effect so the new
    /// displayName propagates to observers reading `activeEffect?.displayName`.
    /// Persisted intensity/speed are restored by `registerEffect`.
    private func handleLocalVideoRenamed(_ videoId: String) {
        guard let freshInfo = LocalVideoBackgroundManager.shared.videoInfo(for: videoId) else {
            return
        }
        let effectId = "videoBackground_\(videoId)"
        let wasActive = activeEffect?.id == effectId

        availableEffects.removeAll { $0.id == effectId }
        effectConfigCancellables.removeValue(forKey: effectId)

        registerEffect(VideoBackgroundEffect(videoInfo: freshInfo))

        if wasActive {
            setActiveEffect(id: effectId)
        }
    }

    /// Called when a local video is deleted. Deactivates if currently active.
    private func handleLocalVideoDeleted(_ videoId: String) {
        let effectId = "videoBackground_\(videoId)"
        let wasKeyboardEffect = keyboardEffect?.id == effectId
        if activeEffect?.id == effectId {
            setActiveEffect(id: nil)
        }
        availableEffects.removeAll { $0.id == effectId }
        effectConfigCancellables.removeValue(forKey: effectId)
        if wasKeyboardEffect { effectDidChange.send() }
    }
}
