//
//  MainViewWindowSceneReporter.swift
//  rootshell
//
//  Window scene reporting for MainView (focus, safe areas, and the
//  continuous Catalyst per-window frame capture that feeds multi-window
//  restore). Extracted for build parallelization; moved verbatim.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Window Scene Reporter

struct WindowSceneReporter: UIViewRepresentable {
    let onUpdate: (UIWindowScene?, UIEdgeInsets, Bool) -> Void
    /// External MainView: never key, never touches WindowFocusRegistry.
    var suppressesFocusRegistry: Bool = false
    /// Catalyst: reports this window's current system frame on every layout pass
    /// (covers resize + initial appearance), so the frame is tracked continuously
    /// rather than only at save time.
    var onFrameUpdate: ((CGRect) -> Void)? = nil

    func makeUIView(context: Context) -> WindowSceneReportingView {
        let view = WindowSceneReportingView()
        view.onUpdate = onUpdate
        view.onFrameUpdate = onFrameUpdate
        view.suppressesFocusRegistry = suppressesFocusRegistry
        return view
    }

    func updateUIView(_ uiView: WindowSceneReportingView, context: Context) {
        uiView.onUpdate = onUpdate
        uiView.onFrameUpdate = onFrameUpdate
        uiView.suppressesFocusRegistry = suppressesFocusRegistry
    }
}

final class WindowSceneReportingView: UIView {
    private struct SceneSnapshot: Equatable {
        let sceneSessionID: String?
        let safeAreaInsets: UIEdgeInsets
        let isKey: Bool
    }

    var onUpdate: ((UIWindowScene?, UIEdgeInsets, Bool) -> Void)?
    var onFrameUpdate: ((CGRect) -> Void)?
    var suppressesFocusRegistry = false
    private var lastSnapshotSkippedRegistry = false
    private var windowObserverTokens: [NSObjectProtocol] = []

    /// External-presentation windows share the device scene session; letting
    /// them report would overwrite the device window's registry slot.
    private var skipsFocusRegistry: Bool {
        suppressesFocusRegistry || window?.isExternalDisplayPresentation == true
    }
    private var cachedKeyState: Bool?
    private var lastSceneSnapshot: SceneSnapshot?
    private var lastTopSafeAreaInset: CGFloat?
    private var safeAreaDebounceWorkItem: DispatchWorkItem?
    #if targetEnvironment(macCatalyst)
    private var lastReportedFrame: CGRect?
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        cachedKeyState = nil
        registerWindowObservers()
        registerTraitChangeObservers()
        notifyScene()
        reportFrameIfChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Catalyst window resizes relayout the SwiftUI hierarchy, so this fires
        // on every size/position change — the continuous per-window frame source.
        reportFrameIfChanged()
    }

    /// Report the window's current Catalyst system frame when it changes. The
    /// scene's `effectiveGeometry.systemFrame` is valid whenever the view is in a
    /// connected window (the same value the global geometry save reads), so this
    /// captures each window's own frame live, independent of the registry/
    /// connectedScenes lookup that fails at terminate.
    private func reportFrameIfChanged() {
        #if targetEnvironment(macCatalyst)
        guard let frame = window?.windowScene?.effectiveGeometry.systemFrame,
              frame.width >= 1, frame.height >= 1,
              frame != lastReportedFrame else { return }
        lastReportedFrame = frame
        onFrameUpdate?(frame)
        #endif
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        notifyScene()

        // Detect top safe area inset changes (status bar show/hide from fullscreen toggle).
        // Bottom inset changes are handled separately by the keyboard system.
        let currentTopInset = safeAreaInsets.top
        if let lastTop = lastTopSafeAreaInset, lastTop != currentTopInset {
            safeAreaDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard self != nil else { return }
                NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
            }
            safeAreaDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
        lastTopSafeAreaInset = currentTopInset
    }

    deinit {
        safeAreaDebounceWorkItem?.cancel()
        let sceneSessionID = lastSceneSnapshot?.sceneSessionID
        if let sceneSessionID, !suppressesFocusRegistry, !lastSnapshotSkippedRegistry {
            Task { @MainActor in
                WindowFocusRegistry.shared.remove(sceneSessionId: sceneSessionID)
            }
        }
        unregisterWindowObservers()
    }

    func notifyScene() {
        let scene = window?.windowScene
        let sceneSessionID = scene?.session.persistentIdentifier
        let skipsRegistry = skipsFocusRegistry
        let isKey = skipsRegistry ? false : currentWindowIsKey()
        let insets = window?.safeAreaInsets ?? .zero
        let snapshot = SceneSnapshot(
            sceneSessionID: sceneSessionID,
            safeAreaInsets: insets,
            isKey: isKey
        )

        guard snapshot != lastSceneSnapshot else { return }

        let previousSnapshot = lastSceneSnapshot
        lastSceneSnapshot = snapshot
        lastSnapshotSkippedRegistry = skipsRegistry

        if !skipsRegistry,
           previousSnapshot?.sceneSessionID != sceneSessionID ||
            previousSnapshot?.isKey != isKey {
            Task { @MainActor in
                if let sceneSessionID {
                    WindowFocusRegistry.shared.update(sceneSessionId: sceneSessionID, isKey: isKey)
                }
                if let previousSceneSessionID = previousSnapshot?.sceneSessionID,
                   previousSceneSessionID != sceneSessionID {
                    WindowFocusRegistry.shared.remove(sceneSessionId: previousSceneSessionID)
                }
            }
        }

        onUpdate?(scene, insets, isKey)
    }

    private func registerWindowObservers() {
        guard window != nil else { return }
        unregisterWindowObservers()

        let center = NotificationCenter.default
        let didBecomeKey = center.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUIWindowKeyNotification(notification, becameKey: true)
        }
        let didResignKey = center.addObserver(
            forName: UIWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUIWindowKeyNotification(notification, becameKey: false)
        }
        windowObserverTokens = [didBecomeKey, didResignKey]

#if targetEnvironment(macCatalyst)
        let didBecomeKeyWindow = center.addObserver(
            forName: Notification.Name("NSWindowDidBecomeKeyNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        let didResignKeyWindow = center.addObserver(
            forName: Notification.Name("NSWindowDidResignKeyNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        let didBecomeMainWindow = center.addObserver(
            forName: Notification.Name("NSWindowDidBecomeMainNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        let didResignMainWindow = center.addObserver(
            forName: Notification.Name("NSWindowDidResignMainNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        let didMiniaturize = center.addObserver(
            forName: Notification.Name("NSWindowDidMiniaturizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        let didDeminiaturize = center.addObserver(
            forName: Notification.Name("NSWindowDidDeminiaturizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNSWindowKeyNotification()
        }
        windowObserverTokens.append(contentsOf: [
            didBecomeKeyWindow,
            didResignKeyWindow,
            didBecomeMainWindow,
            didResignMainWindow,
            didMiniaturize,
            didDeminiaturize
        ])
#endif
    }

    /// Register for activeAppearance trait changes on iOS/iPadOS/visionOS.
    /// This is the reliable way to detect window focus in iPadOS 26+ multi-window environments.
    private func registerTraitChangeObservers() {
#if !targetEnvironment(macCatalyst)
        // iOS 17+ uses registerForTraitChanges for activeAppearance
        if #available(iOS 17.0, visionOS 1.0, *) {
            registerForTraitChanges([UITraitActiveAppearance.self]) { (view: WindowSceneReportingView, _) in
                view.handleActiveAppearanceChange()
            }
        }
#endif
    }

#if !targetEnvironment(macCatalyst)
    /// Handle activeAppearance trait changes (iOS/iPadOS/visionOS only)
    private func handleActiveAppearanceChange() {
        // Clear cached state so currentWindowIsKey() re-evaluates
        cachedKeyState = nil
        notifyScene()
    }

#endif

    private func unregisterWindowObservers() {
        guard !windowObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        for token in windowObserverTokens {
            center.removeObserver(token)
        }
        windowObserverTokens.removeAll()
    }

    private func currentWindowIsKey() -> Bool {
#if targetEnvironment(macCatalyst)
        // Mac Catalyst: Use WindowAccessor for reliable NSWindow key state
        if let sceneId = window?.windowScene?.session.persistentIdentifier,
           let keyState = WindowAccessor.keyState(forSceneSessionId: sceneId) {
            cachedKeyState = keyState
            return keyState
        }
        // Fallback if WindowAccessor not available yet
        return window?.isKeyWindow ?? false
#else
        // iOS/iPadOS/visionOS: Use activeAppearance for reliable focus detection
        // On iPadOS 26+, isKeyWindow is not reliable for multi-window apps.
        // Multiple scenes can be foregroundActive simultaneously.
        // The activeAppearance trait correctly indicates which window has focus.
        if let cachedKeyState {
            return cachedKeyState
        }

        // Check activeAppearance - this is the reliable signal on iOS/iPadOS/visionOS
        let isActive = traitCollection.activeAppearance == .active
        cachedKeyState = isActive
        return isActive
#endif
    }

    private func handleUIWindowKeyNotification(_ notification: Notification, becameKey: Bool) {
        if let notifiedWindow = notification.object as? UIWindow {
            guard notifiedWindow === window else { return }
#if targetEnvironment(macCatalyst)
            cachedKeyState = becameKey
#else
            // On iOS/iPadOS/visionOS, don't trust isKeyWindow notifications for focus
            // Clear cache and let currentWindowIsKey() re-evaluate using activeAppearance
            cachedKeyState = nil
#endif
        } else {
            cachedKeyState = nil
        }
        notifyScene()
    }

#if targetEnvironment(macCatalyst)
    private func handleNSWindowKeyNotification() {
        if let sceneId = window?.windowScene?.session.persistentIdentifier,
           let keyState = WindowAccessor.keyState(forSceneSessionId: sceneId) {
            cachedKeyState = keyState
        } else {
            cachedKeyState = nil
        }
        notifyScene()
    }
#endif
}
