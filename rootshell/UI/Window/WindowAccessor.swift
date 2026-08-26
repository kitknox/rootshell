//
//  WindowAccessor.swift
//  rootshell
//
//  Window transparency configuration for iOS and Mac Catalyst
//

import SwiftUI
import Combine
import Foundation
import os
import ObjectiveC

#if canImport(UIKit)
import UIKit

// Associated object key for storing scene session ID on NSWindow
private var sceneSessionIdKey: UInt8 = 0
private var titlebarCursorMonitorKey: UInt8 = 0

extension Notification.Name {
    /// Posted by CatalystSceneDelegate.sceneDidBecomeActive so per-window
    /// accessors can re-validate their claimed NSWindow after a reopen.
    static let catalystSceneDidActivate = Notification.Name("com.rootshell.catalystSceneDidActivate")
}

#if targetEnvironment(macCatalyst)
import AppKit

extension WindowAccessor {
    @MainActor
    static func keyState(forSceneSessionId sceneSessionId: String) -> Bool? {
        guard !sceneSessionId.isEmpty else { return nil }
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return nil
        }

        guard let nsWindow = windows.first(where: { WindowAccessor.sceneSessionId(for: $0) == sceneSessionId }) else {
            return nil
        }

        return (nsWindow.value(forKey: "isKeyWindow") as? Bool) == true
    }

    static func sceneSessionId(for nsWindow: NSObject) -> String? {
        objc_getAssociatedObject(nsWindow, &sceneSessionIdKey) as? String
    }

    /// Removes a scene-session claim. Used by the visor's stolen-claim
    /// recovery: when this accessor's key-window heuristic claims the
    /// visor's NSWindow during the launch race, the visor identifies its
    /// window by geometry and clears the bad claim so both accessors can
    /// re-claim their true windows.
    static func clearSceneSessionClaim(for nsWindow: NSObject) {
        objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// Snapshot of every input that affects the Catalyst NSWindow + titlebar
/// configuration. Lets `TransparentWindowView` skip the expensive Obj-C
/// reflection / forced `display()` reconfigure when none of these changed.
///
/// The six reconfigure triggers (surface count, tab count, transparency,
/// theme, tab-bar toggle, and the *very* chatty global
/// `UserDefaults.didChangeNotification`) otherwise re-run the whole AppKit
/// reflection pass many times during a single window open — a major source of
/// the open-time flashing.
private struct WindowConfigSignature: Equatable {
    var shouldApplyTransparency: Bool
    var opacity: CGFloat
    var themeBackgroundHex: String
    var tabCount: Int
    var tabsInTitlebar: Bool
    var tabBarHidden: Bool
    var hideTitleBar: Bool
    var topTabStyle: TopTabStyle
}
#endif

/// A hidden view that configures window-level transparency
/// Based on the pattern from the transparent reference project
struct WindowAccessor: UIViewRepresentable {
    var windowTitle: String = ""

    func makeUIView(context: Context) -> UIView {
        let view = TransparentWindowView()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        #if targetEnvironment(macCatalyst)
        (uiView as? TransparentWindowView)?.updateWindowTitle(windowTitle)
        #else
        if let transparentView = uiView as? TransparentWindowView {
            transparentView.pendingSceneTitle = windowTitle
            transparentView.applySceneTitle()
        }
        #endif
    }
}

/// Internal view that accesses the UIWindow to configure transparency
private class TransparentWindowView: UIView {
    private var cancellables = Set<AnyCancellable>()
    private var titlebarInsetRetryCount = 0
    private var titlebarInsetRetryTask: DispatchWorkItem?

    /// Scene title to apply once the view is in a window (iPad/iPhone)
    var pendingSceneTitle: String?

    #if targetEnvironment(macCatalyst)
    /// Window title to apply once the view is in a window (macCatalyst)
    var pendingWindowTitle: String?

    /// Last configuration that was fully applied to the NSWindow. `configureWindow()`
    /// short-circuits when the live signature matches this, so the burst of
    /// reconfigure triggers fired during a window open no longer each re-run the
    /// AppKit reflection + `display()`.
    private var lastAppliedConfig: WindowConfigSignature?

    /// True while a `makeNSWindowTransparent()` pass is already queued for the
    /// next runloop turn, so a burst of triggers collapses into one pass.
    private var nsWindowConfigScheduled = false

    /// The NSWindow the last full pass configured. Weak: when AppKit
    /// deallocates the window after a close, this goes nil and the dedup
    /// guard stops trusting `lastAppliedConfig`.
    private weak var claimedNSWindow: NSObject?

    /// True when the last blur assertion ran while the claimed window was
    /// actually on screen. CGS blur binds to `windowNumber`, which only
    /// exists once the window has a window device — a call made any earlier
    /// is a silent no-op. On reopen the claim can run while the window is
    /// key but not yet ordered in, so the dedup guard uses this to force one
    /// more pass once the window is visible.
    private var blurAssertedWhileVisible = false
    #endif

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WindowAccessor")

    #if !targetEnvironment(macCatalyst)
    func applySceneTitle() {
        guard let title = pendingSceneTitle, let windowScene = window?.windowScene else { return }
        windowScene.title = title
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()

        #if targetEnvironment(macCatalyst)
        guard self.window != nil else { return }

        // New window (or re-attach to a different one): force a fresh apply.
        lastAppliedConfig = nil

        // Initial configuration
        configureWindow()

        // Apply any window title that was set before the view was in a window
        if let title = pendingWindowTitle {
            updateWindowTitle(title)
        }

        // Subscribe to changes that should trigger reconfiguration
        setupSubscriptions()
        #else
        // Apply any scene title that was set before the view was in a window
        if self.window != nil {
            applySceneTitle()
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func setupSubscriptions() {
        // didMoveToWindow calls this on every re-attach; drop the previous
        // window's subscriptions so they don't accumulate.
        cancellables.removeAll()

        // A freshly created NSWindow often isn't key when the first configure
        // pass runs, and makeNSWindowTransparent() skips claiming in that case.
        // Re-run the pass the moment our window becomes key so a reopened
        // window (closed then relaunched from the Dock) gets claimed and
        // configured deterministically.
        NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? UIWindow,
                      window === self.window else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // AppKit posts this when the claimed window actually reaches the
        // screen — the earliest point where a windowNumber-bound CGS blur
        // call can stick. The dedup guard turns this into a no-op when the
        // blur was already asserted on a visible window.
        NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidChangeOcclusionStateNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let nsWindow = notification.object as? NSObject,
                      nsWindow === self.claimedNSWindow else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // Re-validate when our scene activates. On a Dock-click reopen this
        // fires before the new NSWindow is on screen (the occlusion
        // observer above covers the visibility moment), but it is the
        // reliable early hook for claiming a replaced window.
        NotificationCenter.default.publisher(for: .catalystSceneDidActivate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let scene = notification.object as? UIWindowScene,
                      scene === self.window?.windowScene else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for surface count changes
        Ghostty.App.shared?.surfaceCountDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for tab count changes (for drag blocker)
        SessionTracker.shared.tabCountDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for transparency setting changes
        TransparencyManager.shared.transparencyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for theme changes to update title bar color
        ThemeManager.shared.themeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for tab bar visibility changes (for drag blocker)
        NotificationCenter.default.publisher(for: .toggleTabBar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for "tabs in titlebar" setting changes
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // AppKit rebuilds titlebar views on fullscreen exit, resurrecting the
        // chrome the hidden-titlebar style hides. Force a full reconfigure of
        // our claimed NSWindow when that happens.
        NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidExitFullScreenNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      UserDefaults.standard.bool(forKey: "hideWindowTitleBar"),
                      let nsWindow = notification.object as? NSObject,
                      let sceneSessionId = self.window?.windowScene?.session.persistentIdentifier,
                      WindowAccessor.sceneSessionId(for: nsWindow) == sceneSessionId else {
                    return
                }
                self.lastAppliedConfig = nil
                self.configureWindow()
            }
            .store(in: &cancellables)
    }

    #if targetEnvironment(macCatalyst)
    /// Updates the NSWindow title for dock menu and Mission Control display
    func updateWindowTitle(_ title: String) {
        pendingWindowTitle = title
        guard let uiWindow = self.window else { return }

        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        guard !sceneSessionId.isEmpty else { return }

        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return
        }

        guard let nsWindow = windows.first(where: {
            WindowAccessor.sceneSessionId(for: $0) == sceneSessionId
        }) else {
            return
        }

        nsWindow.setValue(title, forKey: "title")

        // Setting the title can resurrect native title UI (macOS 15+); keep
        // the hidden-titlebar style asserted.
        if UserDefaults.standard.bool(forKey: "hideWindowTitleBar") {
            setStandardWindowButtonsHidden(true, for: nsWindow)
            setTitlebarChromeHidden(true, for: nsWindow)
        }
    }
    #endif

    private func configureWindow() {
        guard self.window != nil else { return }

        // Skip the entire reconfigure when nothing that affects the window or
        // titlebar has changed. Most of the reconfigure triggers — especially
        // the global UserDefaults.didChangeNotification observer — fire
        // repeatedly during a single window open; without this guard each one
        // re-runs the AppKit reflection pass plus a forced `display()`, which
        // is a major contributor to the open-time flashing.
        let signature = currentWindowConfigSignature()
        if let signature, signature == lastAppliedConfig {
            if claimedWindowStateMatches(signature) { return }
            // The applied record no longer reflects the live NSWindow: on a
            // window reopen Catalyst can reconnect the scene with a brand new
            // NSWindow (or reset the old one's state) without invalidating
            // anything the signature tracks, which left reopened windows
            // opaque (#279). Force a full pass.
            lastAppliedConfig = nil
        }

        let shouldApplyTransparency = signature?.shouldApplyTransparency ?? false

        applyUIWindowAppearance(shouldApplyTransparency: shouldApplyTransparency)

        // Coalesce the AppKit (NSWindow) reflection onto the next runloop turn
        // so a burst of triggers collapses into a single reconfiguration pass.
        scheduleNSWindowConfiguration()
    }

    /// Applies the UIKit-side window appearance. Split out because SwiftUI's
    /// scene bring-up re-asserts an opaque window background and can land
    /// after configureWindow's write (#279 reopen) — the AppKit pass calls
    /// this again so both sides are asserted in the same runloop turn.
    private func applyUIWindowAppearance(shouldApplyTransparency: Bool) {
        guard let window = self.window else { return }

        if shouldApplyTransparency {
            // Using a very low alpha value (0.001) instead of pure clear
            // This matches ghostty macOS behavior and provides better visual results
            window.backgroundColor = .white.withAlphaComponent(0.001)
            window.isOpaque = false

            // Ensure the root view controller's view is also transparent
            if let rootView = window.rootViewController?.view {
                rootView.backgroundColor = .clear
                rootView.isOpaque = false
            }
        } else {
            // No active surfaces - use system background color (adapts to light/dark mode)
            window.backgroundColor = .systemBackground
            window.isOpaque = true

            if let rootView = window.rootViewController?.view {
                rootView.backgroundColor = .systemBackground
                rootView.isOpaque = true
            }
        }
    }

    /// True when the NSWindow the last full pass configured is still alive,
    /// on screen, and carrying the opacity that pass applied. Cheap (two KVC
    /// reads, no window-list scan), so the dedup guard can run it on every
    /// reconfigure trigger to catch a replaced or externally reset NSWindow.
    private func claimedWindowStateMatches(_ signature: WindowConfigSignature) -> Bool {
        guard let nsWindow = claimedNSWindow else { return false }
        // Only demand on-screen visibility while the scene is active: a
        // miniaturized window reports isVisible == false and must not be
        // treated as stale by every background trigger.
        if window?.windowScene?.activationState == .foregroundActive,
           (nsWindow.value(forKey: "isVisible") as? Bool) != true {
            return false
        }
        guard let opaque = nsWindow.value(forKey: "opaque") as? Bool else { return false }
        guard opaque == !signature.shouldApplyTransparency else { return false }
        // Blur asserted before the window had a window device did nothing;
        // report a mismatch once the window is on screen so the full pass
        // re-runs with a valid windowNumber.
        if !blurAssertedWhileVisible,
           (nsWindow.value(forKey: "isVisible") as? Bool) == true {
            return false
        }
        // UIKit side: SwiftUI's scene bring-up re-asserts an opaque window
        // background, and on a reopened window that lands AFTER our configure
        // pass, leaving the UIWindow opaque while the NSWindow underneath is
        // transparent (#279). Treat it as divergence so the next trigger
        // repaints the UIKit side too.
        if let uiWindow = self.window {
            let bgAlpha = uiWindow.backgroundColor?.cgColor.alpha ?? 0
            let uiTransparent = !uiWindow.isOpaque && bgAlpha < 0.5
            if uiTransparent != signature.shouldApplyTransparency { return false }
            if signature.shouldApplyTransparency,
               let rootView = uiWindow.rootViewController?.view,
               (rootView.backgroundColor?.cgColor.alpha ?? 0) > 0.5 {
                return false
            }
        }
        return true
    }

    /// Computes the current window configuration signature, or nil if the view
    /// isn't in a window yet. Reads only cheap state (no AppKit reflection), so
    /// it is safe to evaluate on every reconfigure trigger.
    private func currentWindowConfigSignature() -> WindowConfigSignature? {
        guard let uiWindow = self.window else { return nil }
        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        let hasActiveSurfaces = Ghostty.App.shared?.hasActiveSurfaces ?? false
        let opacity = TransparencyManager.shared.backgroundOpacity
        // Mirror configureTitleBar()'s default: absent key means enabled.
        let tabsInTitlebar = UserDefaults.standard.object(forKey: "tabsInTitlebarEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "tabsInTitlebarEnabled")
        return WindowConfigSignature(
            shouldApplyTransparency: hasActiveSurfaces && opacity < 1.0,
            opacity: opacity,
            themeBackgroundHex: ThemeManager.shared.currentThemeInfo?.colors.background ?? "",
            tabCount: SessionTracker.shared.tabCount(forSceneSessionId: sceneSessionId),
            tabsInTitlebar: tabsInTitlebar,
            tabBarHidden: UserDefaults.standard.bool(forKey: "tabBarHidden"),
            hideTitleBar: UserDefaults.standard.bool(forKey: "hideWindowTitleBar"),
            topTabStyle: TopTabStyle.resolve(
                UserDefaults.standard.string(forKey: TopTabStyle.storageKey) ?? TopTabStyle.pills.rawValue
            )
        )
    }

    /// Coalesces NSWindow reconfiguration: many triggers can fire in one runloop
    /// turn during window open, so collapse them into a single
    /// `makeNSWindowTransparent()` pass (which reads live state at execution).
    private func scheduleNSWindowConfiguration() {
        guard !nsWindowConfigScheduled else { return }
        nsWindowConfigScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nsWindowConfigScheduled = false
            self.makeNSWindowTransparent()
        }
    }

    /// True when some connected UIScene's session matches `sessionId`.
    /// Distinguishes stale NSWindow claims (safe to reclaim) from live
    /// ones (never steal).
    private static func isLiveSceneSession(_ sessionId: String) -> Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.persistentIdentifier == sessionId
        }
    }

    /// Configures the underlying NSWindow for transparency on Mac Catalyst
    /// Uses Objective-C runtime to access AppKit classes
    private func makeNSWindowTransparent() {
        guard let uiWindow = self.window else { return }

        #if STANDALONE && targetEnvironment(macCatalyst)
        // The visor hosts a full MainView, so this accessor also lives in the
        // visor scene — but its NSWindow is a borderless panel owned entirely
        // by VisorWindowAccessor. Claiming it here (the key path can win the
        // race before the visor's own claim lands) applies titlebar/opacity
        // configuration meant for regular windows and desyncs the panel from
        // its UIKit scene. Never touch NSWindows from the visor's scene.
        if let session = uiWindow.windowScene?.session,
           VisorSceneRegistry.shared.isVisor(session: session) {
            return
        }
        #endif

        // Check if there are active Ghostty surfaces
        let hasActiveSurfaces = Ghostty.App.shared?.hasActiveSurfaces ?? false
        let opacity = TransparencyManager.shared.backgroundOpacity

        // Only apply transparency if:
        // 1. There are active Ghostty surfaces, AND
        // 2. Opacity is less than 1.0
        // Otherwise, use a solid background color
        let shouldApplyTransparency = hasActiveSurfaces && opacity < 1.0

        // Get NSApplication.sharedApplication
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type else {
            Self.logger.warning("Failed to get NSApplication class")
            return
        }

        guard let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else {
            Self.logger.warning("Failed to get shared application")
            return
        }

        // Get all windows
        guard let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            Self.logger.warning("Failed to get windows array")
            return
        }

        // Get our scene session ID for matching. A view whose scene already
        // detached (window teardown) must not claim anything: a dying view
        // can otherwise claim an unrelated window with an empty id via the
        // single-window path (#279).
        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        guard !sceneSessionId.isEmpty else { return }

        // Find our specific NSWindow using stored scene session ID
        // Strategy:
        // 1. Look for NSWindow already tagged with our sceneSessionId
        // 2. If only one window exists, claim it
        // 3. If not found and we're key window, claim the key NSWindow
        //
        // A claim can go stale on window reopen: the scene session reconnects
        // with the same persistentIdentifier while the closed window's
        // NSWindow can still sit in NSApp.windows carrying our claim —
        // configuring that dead window left reopened windows opaque (#279).
        // Drop the claim from an invisible window and fall through to claim
        // the live one.
        var claimedWindow = windows.first(where: { window in
            let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String
            return storedId == sceneSessionId
        })
        if let candidate = claimedWindow,
           (candidate.value(forKey: "isVisible") as? Bool) != true {
            objc_setAssociatedObject(candidate, &sceneSessionIdKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            claimedWindow = nil
        }

        let nsWindow: NSObject

        if let claimedWindow {
            nsWindow = claimedWindow
        } else if windows.count == 1 {
            // Only one window - claim it
            let candidate = windows[0]
            #if STANDALONE && targetEnvironment(macCatalyst)
            // Never claim the visor's window. A stolen claim makes the
            // visor's own resolveNSWindow() skip its window forever, and
            // the unconfigured visor stays on screen as a small white
            // window at launch.
            if VisorWindowClaims.isVisorWindow(candidate) {
                Self.logger.debug("Only NSWindow is the visor's; waiting to claim")
                return
            }
            #endif
            nsWindow = candidate
            objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, sceneSessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Self.logger.info("Claimed single NSWindow for scene \(sceneSessionId)")
        } else if uiWindow.isKeyWindow {
            // Multiple windows - claim the key NSWindow if we're the key UIWindow
            guard let keyWindow = windows.first(where: { window in
                // Find unclaimed key window
                #if STANDALONE && targetEnvironment(macCatalyst)
                if VisorWindowClaims.isVisorWindow(window) { return false }
                #endif
                let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String
                let isKey = (window.value(forKey: "isKeyWindow") as? Bool) == true
                return isKey && storedId == nil
            }) ?? windows.first(where: { window in
                // Fallback: reclaim a key window only when its existing
                // claim is stale (no live scene session). Stealing a live
                // claim (another terminal window's, or the visor's)
                // misroutes window configuration; the visor case left an
                // unconfigured white window on screen at launch.
                #if STANDALONE && targetEnvironment(macCatalyst)
                if VisorWindowClaims.isVisorWindow(window) { return false }
                #endif
                guard (window.value(forKey: "isKeyWindow") as? Bool) == true else { return false }
                if let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String,
                   storedId != sceneSessionId,
                   Self.isLiveSceneSession(storedId) {
                    return false
                }
                return true
            }) else {
                Self.logger.warning("Could not find key NSWindow to claim")
                return
            }
            nsWindow = keyWindow
            objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, sceneSessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Self.logger.info("Claimed key NSWindow for scene \(sceneSessionId)")
        } else {
            // Not key window and haven't claimed a window yet - skip
            Self.logger.debug("Skipping non-key window \(sceneSessionId), waiting to claim")
            return
        }

        // Track the resolved window so the dedup guard can detect it being
        // replaced or externally reset (see claimedWindowStateMatches).
        claimedNSWindow = nsWindow

        // Fast path: if this exact configuration was already applied, don't
        // rebuild the titlebar / drag blockers or force another `display()`.
        // The only thing that still needs polling is the titlebar leading inset,
        // which only becomes measurable once the traffic-light buttons exist —
        // this is what the inset retry loop is for, and keeping it lightweight
        // avoids 8 full reflection passes per window open.
        if let last = lastAppliedConfig, currentWindowConfigSignature() == last {
            if last.hideTitleBar {
                // Buttons are hidden — nothing to measure; cancel any retries.
                scheduleTitlebarInsetRetryIfNeeded(hasInset: true, hasWindows: true)
                return
            }
            let inset = titlebarLeadingInset(for: nsWindow)
            if let inset {
                TitlebarLayoutManager.shared.updateLeadingInset(inset)
            }
            scheduleTitlebarInsetRetryIfNeeded(hasInset: inset != nil, hasWindows: true)
            return
        }

        // Get NSColor class to create background color
        guard let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type else {
            Self.logger.warning("Failed to get NSColor class")
            return
        }

        // Create the appropriate background color based on whether we have active surfaces
        let backgroundColor: NSObject
        if shouldApplyTransparency {
            // Create white color with very low alpha (0.001) for transparency
            // This matches macOS Ghostty and creates proper visual appearance with background blur
            // Signature: +[NSColor colorWithWhite:alpha:]
            let whiteColorSelector = NSSelectorFromString("colorWithWhite:alpha:")
            guard nsColorClass.responds(to: whiteColorSelector) else {
                Self.logger.warning("NSColor doesn't respond to colorWithWhite:alpha:")
                return
            }

            let colorMethod = nsColorClass.method(for: whiteColorSelector)
            typealias ColorFunction = @convention(c) (AnyClass, Selector, CGFloat, CGFloat) -> NSObject
            let colorFunc = unsafeBitCast(colorMethod, to: ColorFunction.self)
            backgroundColor = colorFunc(nsColorClass, whiteColorSelector, 1.0, 0.001)
        } else {
            // No active surfaces - use system window background color (adapts to light/dark mode)
            // Signature: +[NSColor windowBackgroundColor]
            guard let windowBackgroundColor = nsColorClass.value(forKey: "windowBackgroundColor") as? NSObject else {
                Self.logger.warning("Failed to get NSColor.windowBackgroundColor")
                return
            }
            backgroundColor = windowBackgroundColor
        }

        // Get per-window tab count using scene session ID (already captured above)
        let tabCount = SessionTracker.shared.tabCount(forSceneSessionId: sceneSessionId)

        // Configure only our window
        let window = nsWindow

        // Ensure mouseMoved events are delivered for tracking areas (titlebar drag handle)
        let setAcceptsSelector = NSSelectorFromString("setAcceptsMouseMovedEvents:")
        if window.responds(to: setAcceptsSelector) {
            let method = window.method(for: setAcceptsSelector)
            typealias SetAcceptsFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
            let setAcceptsFunc = unsafeBitCast(method, to: SetAcceptsFunc.self)
            setAcceptsFunc(window, setAcceptsSelector, true)
        } else {
            window.setValue(true, forKey: "acceptsMouseMovedEvents")
        }

        // Set window opacity based on whether we're applying transparency
        window.setValue(!shouldApplyTransparency, forKey: "opaque")

        // Set the background color
        window.setValue(backgroundColor, forKey: "backgroundColor")

        // Configure title bar for integrated tab appearance
        configureTitleBar(for: window, transparent: shouldApplyTransparency, tabCount: tabCount)

        // With the titlebar hidden the buttons can't be measured; keep the
        // persisted inset warm for restore and cancel the retry loop.
        let hideTitleBar = UserDefaults.standard.bool(forKey: "hideWindowTitleBar")
        if hideTitleBar {
            scheduleTitlebarInsetRetryIfNeeded(hasInset: true, hasWindows: true)
        } else {
            if let leadingInset = titlebarLeadingInset(for: window) {
                TitlebarLayoutManager.shared.updateLeadingInset(leadingInset)
            }

            scheduleTitlebarInsetRetryIfNeeded(
                hasInset: titlebarLeadingInset(for: window) != nil,
                hasWindows: true
            )
        }

        // Force the window to update its display
        if window.responds(to: NSSelectorFromString("invalidateShadow")) {
            window.perform(NSSelectorFromString("invalidateShadow"))
        }

        if window.responds(to: NSSelectorFromString("display")) {
            window.perform(NSSelectorFromString("display"))
        }

        // Record what we just applied so unchanged reconfigure triggers (and the
        // titlebar inset retries) take the fast path above.
        lastAppliedConfig = currentWindowConfigSignature()

        // Blur is per-NSWindow state and dies with the old window on reopen;
        // re-assert it in the same pass that configures the claimed window.
        Ghostty.App.shared?.applyWindowBlur(to: window)

        // Re-assert the UIKit side: SwiftUI's scene bring-up repaints the
        // UIWindow opaque between configureWindow's write and this pass on a
        // reopened window (#279).
        applyUIWindowAppearance(shouldApplyTransparency: shouldApplyTransparency)

        blurAssertedWhileVisible = (window.value(forKey: "isVisible") as? Bool) == true
    }

    private func scheduleTitlebarInsetRetryIfNeeded(hasInset: Bool, hasWindows: Bool) {
        guard !hasInset, hasWindows else {
            titlebarInsetRetryCount = 0
            titlebarInsetRetryTask?.cancel()
            titlebarInsetRetryTask = nil
            return
        }

        guard titlebarInsetRetryCount < 8 else { return }
        titlebarInsetRetryCount += 1

        titlebarInsetRetryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.makeNSWindowTransparent()
        }
        titlebarInsetRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func titlebarLeadingInset(for window: NSObject) -> CGFloat? {
        let selector = NSSelectorFromString("standardWindowButton:")
        guard window.responds(to: selector) else { return nil }

        let method = window.method(for: selector)
        typealias StandardButtonFunc = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
        let buttonFunc = unsafeBitCast(method, to: StandardButtonFunc.self)

        let buttonTypes = [0, 1, 2] // close, miniaturize, zoom
        var maxX: CGFloat = 0

        for buttonType in buttonTypes {
            guard let button = buttonFunc(window, selector, buttonType)?.takeUnretainedValue() as? NSObject,
                  let buttonMaxX = resolvedMaxX(for: button) else {
                continue
            }
            maxX = max(maxX, buttonMaxX)
        }

        guard maxX > 0 else { return nil }
        return maxX + 8
    }

    private func resolvedMaxX(for view: NSObject) -> CGFloat? {
        let frameSelector = NSSelectorFromString("frame")
        guard view.responds(to: frameSelector),
              let frameValue = view.value(forKey: "frame") as? NSValue else {
            return nil
        }

        let frameRect = frameValue.rectValue

        if let convertedMaxX = convertedMaxX(for: view, fallbackRect: frameRect) {
            return convertedMaxX
        }

        var rect = frameRect
        var current: NSObject? = view
        let superviewSelector = NSSelectorFromString("superview")

        while let currentView = current,
              currentView.responds(to: superviewSelector),
              let superview = currentView.value(forKey: "superview") as? NSObject,
              superview.responds(to: frameSelector),
              let superFrameValue = superview.value(forKey: "frame") as? NSValue {
            let superFrame = superFrameValue.rectValue
            rect.origin.x += superFrame.origin.x
            rect.origin.y += superFrame.origin.y
            current = superview
        }

        return rect.maxX
    }

    private func convertedMaxX(for view: NSObject, fallbackRect: CGRect) -> CGFloat? {
        let convertSelector = NSSelectorFromString("convertRect:toView:")
        guard view.responds(to: convertSelector) else { return nil }

        let boundsSelector = NSSelectorFromString("bounds")
        let boundsRect: CGRect
        if view.responds(to: boundsSelector),
           let boundsValue = view.value(forKey: "bounds") as? NSValue {
            boundsRect = boundsValue.rectValue
        } else {
            boundsRect = fallbackRect
        }

        let method = view.method(for: convertSelector)
        typealias ConvertFunc = @convention(c) (AnyObject, Selector, CGRect, AnyObject?) -> CGRect
        let convertFunc = unsafeBitCast(method, to: ConvertFunc.self)
        let rectInWindow = convertFunc(view, convertSelector, boundsRect, nil)
        return rectInWindow.maxX
    }

    // MARK: - Titlebar Drag Control

    /// Tag used to identify the drag blocker view
    private static let dragBlockerTag = 0x44524147  // "DRAG" in hex

    /// Creates a dynamic NSView subclass that blocks window dragging
    /// by returning false for mouseDownCanMoveWindow, but passes through
    /// mouse events by sending them to the window
    private static var dragBlockerClass: AnyClass? = {
        let className = "TitlebarDragBlocker"

        if let existingClass = NSClassFromString(className) {
            return existingClass
        }

        guard let nsViewClass = NSClassFromString("NSView") else {
            return nil
        }

        guard let newClass = objc_allocateClassPair(nsViewClass, className, 0) else {
            return nil
        }

        // Return false to prevent window dragging
        let mouseDownCanMoveSelector = NSSelectorFromString("mouseDownCanMoveWindow")
        let mouseDownCanMoveImpl: @convention(block) (AnyObject) -> Bool = { _ in
            return false
        }
        class_addMethod(newClass, mouseDownCanMoveSelector, imp_implementationWithBlock(mouseDownCanMoveImpl), "B@:")

        // Smart hitTest: return nil to let events through to content below.
        // Only return self for empty titlebar areas to block window dragging.
        let hitTestSelector = NSSelectorFromString("hitTest:")
        let hitTestImpl: @convention(block) (AnyObject, CGPoint) -> AnyObject? = { selfObj, point in
            guard let view = selfObj as? NSObject else { return nil }

            // Check bounds first
            let boundsSelector = NSSelectorFromString("bounds")
            guard view.responds(to: boundsSelector),
                  let boundsValue = view.value(forKey: "bounds") as? NSValue else {
                return nil
            }
            let bounds = boundsValue.rectValue
            guard bounds.contains(point) else { return nil }

            // Check if there's an active drag session - if so, always pass through
            // to allow drop targets to receive events
            if let nsAppClass = NSClassFromString("NSApplication"),
               let sharedApp = (nsAppClass as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject {
                let currentEventSelector = NSSelectorFromString("currentEvent")
                if sharedApp.responds(to: currentEventSelector),
                   let currentEvent = sharedApp.perform(currentEventSelector)?.takeUnretainedValue() as? NSObject {
                    let eventTypeSelector = NSSelectorFromString("type")
                    if currentEvent.responds(to: eventTypeSelector) {
                        let typeMethod = currentEvent.method(for: eventTypeSelector)
                        typealias TypeFunc = @convention(c) (AnyObject, Selector) -> Int
                        let typeFunc = unsafeBitCast(typeMethod, to: TypeFunc.self)
                        let eventType = typeFunc(currentEvent, eventTypeSelector)
                        // NSEventType: leftMouseDragged = 6, rightMouseDragged = 7, otherMouseDragged = 27
                        if eventType == 6 || eventType == 7 || eventType == 27 {
                            return nil  // During drag, always pass through
                        }
                    }
                }
            }

            // Get window and content view to check for interactive elements
            guard let window = view.value(forKey: "window") as? NSObject,
                  let contentView = window.value(forKey: "contentView") as? NSObject else {
                return selfObj  // Block window drag if we can't check content
            }

            // Convert point from our coordinates to window coordinates
            let convertToWindowSelector = NSSelectorFromString("convertPoint:toView:")
            guard view.responds(to: convertToWindowSelector) else {
                return selfObj
            }
            let convertMethod = view.method(for: convertToWindowSelector)
            typealias ConvertFunc = @convention(c) (AnyObject, Selector, CGPoint, AnyObject?) -> CGPoint
            let convertFunc = unsafeBitCast(convertMethod, to: ConvertFunc.self)
            let pointInWindow = convertFunc(view, convertToWindowSelector, point, nil)

            // Convert from window to content view coordinates
            let convertFromWindowSelector = NSSelectorFromString("convertPoint:fromView:")
            guard contentView.responds(to: convertFromWindowSelector) else {
                return selfObj
            }
            let convertFromMethod = contentView.method(for: convertFromWindowSelector)
            let convertFromFunc = unsafeBitCast(convertFromMethod, to: ConvertFunc.self)
            let pointInContent = convertFromFunc(contentView, convertFromWindowSelector, pointInWindow, nil)

            // Hit test on content view
            let contentHitTestSelector = NSSelectorFromString("hitTest:")
            guard contentView.responds(to: contentHitTestSelector) else {
                return selfObj
            }
            let hitMethod = contentView.method(for: contentHitTestSelector)
            typealias HitFunc = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
            let hitFunc = unsafeBitCast(hitMethod, to: HitFunc.self)

            if let hitView = hitFunc(contentView, contentHitTestSelector, pointInContent) as? NSObject {
                // If hit view is different from content view itself, there's something interactive
                if hitView !== contentView {
                    return nil  // Let the click through to the interactive element
                }
            }

            // No interactive element found, block window drag
            return selfObj
        }
        class_addMethod(newClass, hitTestSelector, imp_implementationWithBlock(hitTestImpl), "@@:{CGPoint=dd}")

        // For mouseDown - consume it but record the event for later
        let mouseDownSelector = NSSelectorFromString("mouseDown:")
        let mouseDownImpl: @convention(block) (AnyObject, AnyObject) -> Void = { _, event in
            // Store the mouseDown event - we'll use it to simulate a click on mouseUp
            objc_setAssociatedObject(event, "mouseDownEvent", event, .OBJC_ASSOCIATION_RETAIN)
        }
        class_addMethod(newClass, mouseDownSelector, imp_implementationWithBlock(mouseDownImpl), "v@:@")

        // For mouseUp - send event to the window to let it route to the right view
        let mouseUpSelector = NSSelectorFromString("mouseUp:")
        let mouseUpImpl: @convention(block) (AnyObject, AnyObject) -> Void = { selfObj, event in
            guard let view = selfObj as? NSObject,
                  let window = view.value(forKey: "window") as? NSObject,
                  let eventObj = event as? NSObject else { return }

            // Send the mouseUp event through the window's normal event handling
            let sendEventSelector = NSSelectorFromString("sendEvent:")
            if window.responds(to: sendEventSelector) {
                // Temporarily remove ourselves from the view hierarchy so we don't intercept again
                let superviewSelector = NSSelectorFromString("superview")
                let removeSelector = NSSelectorFromString("removeFromSuperview")
                let addSubviewSelector = NSSelectorFromString("addSubview:")

                if let superview = view.perform(superviewSelector)?.takeUnretainedValue() as? NSObject {
                    view.perform(removeSelector)
                    window.perform(sendEventSelector, with: eventObj)
                    superview.perform(addSubviewSelector, with: view)
                }
            }
        }
        class_addMethod(newClass, mouseUpSelector, imp_implementationWithBlock(mouseUpImpl), "v@:@")

        // For mouseDragged - ignore it (don't move window)
        let mouseDraggedSelector = NSSelectorFromString("mouseDragged:")
        let mouseDraggedImpl: @convention(block) (AnyObject, AnyObject) -> Void = { _, _ in
            // Consume drag events - don't let them move the window
        }
        class_addMethod(newClass, mouseDraggedSelector, imp_implementationWithBlock(mouseDraggedImpl), "v@:@")

        objc_registerClassPair(newClass)
        return newClass
    }()

    /// Tag used to identify the drag handle view
    private static let dragHandleTag = 0x48414E44  // "HAND" in hex

    /// Cursor token for titlebar drag handle (shared across all instances since cursor is global)
    private static let titlebarCursorToken = UUID()

    private static func eventPointIsInside(_ event: AnyObject, view: NSObject) -> Bool {
        let locationSelector = NSSelectorFromString("locationInWindow")
        guard event.responds(to: locationSelector) else { return false }

        let locationMethod = event.method(for: locationSelector)
        typealias LocationFunc = @convention(c) (AnyObject, Selector) -> CGPoint
        let locationFunc = unsafeBitCast(locationMethod, to: LocationFunc.self)
        return windowPointIsInside(locationFunc(event, locationSelector), view: view)
    }

    private static func currentMouseIsInside(_ view: NSObject) -> Bool {
        let windowSelector = NSSelectorFromString("window")
        guard view.responds(to: windowSelector),
              let window = view.perform(windowSelector)?.takeUnretainedValue() as? NSObject else {
            return false
        }

        let locationSelector = NSSelectorFromString("mouseLocationOutsideOfEventStream")
        guard window.responds(to: locationSelector) else { return false }

        let locationMethod = window.method(for: locationSelector)
        typealias LocationFunc = @convention(c) (AnyObject, Selector) -> CGPoint
        let locationFunc = unsafeBitCast(locationMethod, to: LocationFunc.self)
        return windowPointIsInside(locationFunc(window, locationSelector), view: view)
    }

    private static func windowPointIsInside(_ pointInWindow: CGPoint, view: NSObject) -> Bool {
        let convertSelector = NSSelectorFromString("convertPoint:fromView:")
        let boundsSelector = NSSelectorFromString("bounds")
        guard view.responds(to: convertSelector),
              view.responds(to: boundsSelector),
              let boundsValue = view.value(forKey: "bounds") as? NSValue else {
            return false
        }

        let convertMethod = view.method(for: convertSelector)
        typealias ConvertFunc = @convention(c) (AnyObject, Selector, CGPoint, AnyObject?) -> CGPoint
        let convertFunc = unsafeBitCast(convertMethod, to: ConvertFunc.self)
        let pointInView = convertFunc(view, convertSelector, pointInWindow, nil)
        return boundsValue.rectValue.contains(pointInView)
    }

    private static func startTitlebarCursorMonitor(_ token: UUID, view: NSObject) {
        if (objc_getAssociatedObject(view, &titlebarCursorMonitorKey) as? Bool) == true {
            return
        }

        objc_setAssociatedObject(view, &titlebarCursorMonitorKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        monitorTitlebarCursor(token, view: view)
    }

    private static func stopTitlebarCursorMonitor(_ token: UUID, view: NSObject? = nil) {
        if let view {
            objc_setAssociatedObject(view, &titlebarCursorMonitorKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        CatalystCursorCoordinator.shared.unregister(token)
    }

    private static func monitorTitlebarCursor(_ token: UUID, view: NSObject) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
            guard let view else {
                CatalystCursorCoordinator.shared.unregister(token)
                return
            }

            guard (objc_getAssociatedObject(view, &titlebarCursorMonitorKey) as? Bool) == true else {
                return
            }

            guard currentMouseIsInside(view) else {
                stopTitlebarCursorMonitor(token, view: view)
                return
            }

            monitorTitlebarCursor(token, view: view)
        }
    }

    /// Creates a dynamic NSView subclass for the draggable titlebar strip
    /// Shows open hand cursor when hovered to indicate drag affordance
    private static var dragHandleClass: AnyClass? = {
        let className = "TitlebarDragHandle"

        if let existingClass = NSClassFromString(className) {
            return existingClass
        }

        guard let nsViewClass = NSClassFromString("NSView") else {
            return nil
        }

        guard let newClass = objc_allocateClassPair(nsViewClass, className, 0) else {
            return nil
        }

        // Return true to allow window dragging from this view
        let mouseDownCanMoveSelector = NSSelectorFromString("mouseDownCanMoveWindow")
        let mouseDownCanMoveImpl: @convention(block) (AnyObject) -> Bool = { _ in
            return true
        }
        class_addMethod(newClass, mouseDownCanMoveSelector, imp_implementationWithBlock(mouseDownCanMoveImpl), "B@:")

        let hitTestSelector = NSSelectorFromString("hitTest:")
        let hitTestImpl: @convention(block) (AnyObject, CGPoint) -> AnyObject? = { selfObj, point in
            guard let view = selfObj as? NSObject else { return nil }

            let boundsSelector = NSSelectorFromString("bounds")
            guard view.responds(to: boundsSelector),
                  let boundsValue = view.value(forKey: "bounds") as? NSValue else {
                return nil
            }

            return boundsValue.rectValue.contains(point) ? selfObj : nil
        }
        class_addMethod(newClass, hitTestSelector, imp_implementationWithBlock(hitTestImpl), "@@:{CGPoint=dd}")

        // Set up tracking area when view is added to window
        let updateTrackingAreasSelector = NSSelectorFromString("updateTrackingAreas")
        let updateTrackingAreasImpl: @convention(block) (AnyObject) -> Void = { selfObj in
            guard let view = selfObj as? NSObject else { return }

            // Call super.updateTrackingAreas()
            let superSelector = NSSelectorFromString("updateTrackingAreas")
            if let superClass = class_getSuperclass(object_getClass(view)),
               let superMethod = class_getInstanceMethod(superClass, superSelector) {
                let superImp = method_getImplementation(superMethod)
                typealias SuperFunc = @convention(c) (AnyObject, Selector) -> Void
                let superFunc = unsafeBitCast(superImp, to: SuperFunc.self)
                superFunc(view, superSelector)
            }

            // Remove existing tracking areas
            let trackingAreasSelector = NSSelectorFromString("trackingAreas")
            let removeTrackingSelector = NSSelectorFromString("removeTrackingArea:")
            if view.responds(to: trackingAreasSelector),
               let areas = view.value(forKey: "trackingAreas") as? [AnyObject] {
                for area in areas {
                    view.perform(removeTrackingSelector, with: area)
                }
            }

            // Create new tracking area covering entire view bounds
            guard let trackingAreaClass = NSClassFromString("NSTrackingArea") as? NSObject.Type else {
                return
            }

            // Get view bounds
            let boundsSelector = NSSelectorFromString("bounds")
            guard view.responds(to: boundsSelector),
                  let boundsValue = view.value(forKey: "bounds") as? NSValue else {
                return
            }
            let bounds = boundsValue.rectValue

            // NSTrackingAreaOptions (raw values): entered/exited=0x01, moved=0x02,
            // cursorUpdate=0x04, activeAlways=0x80, inVisibleRect=0x200
            let options: UInt = 0x01 | 0x02 | 0x04 | 0x80 | 0x200

            // Allocate and init tracking area
            let allocSelector = NSSelectorFromString("alloc")
            let initSelector = NSSelectorFromString("initWithRect:options:owner:userInfo:")

            guard let allocated = trackingAreaClass.perform(allocSelector)?.takeUnretainedValue() as? NSObject else {
                return
            }

            let initMethod = allocated.method(for: initSelector)
            typealias InitFunc = @convention(c) (AnyObject, Selector, CGRect, UInt, AnyObject?, AnyObject?) -> AnyObject
            let initFunc = unsafeBitCast(initMethod, to: InitFunc.self)
            let trackingArea = initFunc(allocated, initSelector, bounds, options, view, nil)

            // Add tracking area to view
            let addTrackingSelector = NSSelectorFromString("addTrackingArea:")
            view.perform(addTrackingSelector, with: trackingArea)
        }
        class_addMethod(newClass, updateTrackingAreasSelector, imp_implementationWithBlock(updateTrackingAreasImpl), "v@:")

        // Mouse entered - register open hand cursor with coordinator
        let mouseEnteredSelector = NSSelectorFromString("mouseEntered:")
        let cursorToken = titlebarCursorToken
        let mouseEnteredImpl: @convention(block) (AnyObject, AnyObject) -> Void = { selfObj, event in
            DispatchQueue.main.async {
                guard let view = selfObj as? NSObject,
                      eventPointIsInside(event, view: view) else {
                    stopTitlebarCursorMonitor(cursorToken, view: selfObj as? NSObject)
                    return
                }

                // Arm the window-move frame poll: a drag that starts on this
                // strip must suppress terminal scrolling from its first frame.
                WindowDragObserver.shared.noteDragStripHover()

                CatalystCursorCoordinator.shared.resetAll()
                if let nsCursorClass = NSClassFromString("NSCursor") as? NSObject.Type,
                   let openHandCursor = nsCursorClass.value(forKey: "openHandCursor") as? NSCursor {
                    CatalystCursorCoordinator.shared.register(cursorToken, cursor: openHandCursor, priority: .titlebar)
                    startTitlebarCursorMonitor(cursorToken, view: view)
                }
            }
        }
        class_addMethod(newClass, mouseEnteredSelector, imp_implementationWithBlock(mouseEnteredImpl), "v@:@")

        // Mouse moved - re-assert open hand cursor while tracking
        let mouseMovedSelector = NSSelectorFromString("mouseMoved:")
        let mouseMovedImpl: @convention(block) (AnyObject, AnyObject) -> Void = { selfObj, event in
            DispatchQueue.main.async {
                guard let view = selfObj as? NSObject,
                      eventPointIsInside(event, view: view) else {
                    stopTitlebarCursorMonitor(cursorToken, view: selfObj as? NSObject)
                    return
                }

                WindowDragObserver.shared.noteDragStripHover()

                if let nsCursorClass = NSClassFromString("NSCursor") as? NSObject.Type,
                   let openHandCursor = nsCursorClass.value(forKey: "openHandCursor") as? NSCursor {
                    CatalystCursorCoordinator.shared.ensure(cursorToken, cursor: openHandCursor, priority: .titlebar)
                    startTitlebarCursorMonitor(cursorToken, view: view)
                }
            }
        }
        class_addMethod(newClass, mouseMovedSelector, imp_implementationWithBlock(mouseMovedImpl), "v@:@")

        // Cursor update - AppKit may ask for this before mouseEntered/mouseMoved
        // when the pointer enters the thin strip from outside the window.
        let cursorUpdateSelector = NSSelectorFromString("cursorUpdate:")
        let cursorUpdateImpl: @convention(block) (AnyObject, AnyObject) -> Void = { selfObj, event in
            guard let view = selfObj as? NSObject,
                  eventPointIsInside(event, view: view) else {
                DispatchQueue.main.async {
                    stopTitlebarCursorMonitor(cursorToken, view: selfObj as? NSObject)
                }
                return
            }

            if let nsCursorClass = NSClassFromString("NSCursor") as? NSObject.Type,
               let openHandCursor = nsCursorClass.value(forKey: "openHandCursor") as? NSCursor {
                openHandCursor.set()
                DispatchQueue.main.async {
                    CatalystCursorCoordinator.shared.ensure(cursorToken, cursor: openHandCursor, priority: .titlebar)
                    startTitlebarCursorMonitor(cursorToken, view: view)
                }
            }
        }
        class_addMethod(newClass, cursorUpdateSelector, imp_implementationWithBlock(cursorUpdateImpl), "v@:@")

        // Mouse exited - unregister cursor (coordinator resets to arrow or next registered cursor)
        let mouseExitedSelector = NSSelectorFromString("mouseExited:")
        let mouseExitedImpl: @convention(block) (AnyObject, AnyObject) -> Void = { selfObj, _ in
            DispatchQueue.main.async {
                stopTitlebarCursorMonitor(cursorToken, view: selfObj as? NSObject)
            }
        }
        class_addMethod(newClass, mouseExitedSelector, imp_implementationWithBlock(mouseExitedImpl), "v@:@")

        // Reset cursor rect to ensure cursor changes when entering view
        let resetCursorRectsSelector = NSSelectorFromString("resetCursorRects")
        let resetCursorRectsImpl: @convention(block) (AnyObject) -> Void = { selfObj in
            guard let view = selfObj as? NSObject else { return }

            let boundsSelector = NSSelectorFromString("bounds")
            guard view.responds(to: boundsSelector),
                  let boundsValue = view.value(forKey: "bounds") as? NSValue else {
                return
            }
            let bounds = boundsValue.rectValue

            if let nsCursorClass = NSClassFromString("NSCursor") as? NSObject.Type,
               let openHandCursor = nsCursorClass.value(forKey: "openHandCursor") as? NSObject {
                let addCursorRectSelector = NSSelectorFromString("addCursorRect:cursor:")
                if view.responds(to: addCursorRectSelector) {
                    let method = view.method(for: addCursorRectSelector)
                    typealias AddCursorFunc = @convention(c) (AnyObject, Selector, CGRect, AnyObject) -> Void
                    let addCursorFunc = unsafeBitCast(method, to: AddCursorFunc.self)
                    addCursorFunc(view, addCursorRectSelector, bounds, openHandCursor)
                }
            }
        }
        class_addMethod(newClass, resetCursorRectsSelector, imp_implementationWithBlock(resetCursorRectsImpl), "v@:")

        objc_registerClassPair(newClass)
        return newClass
    }()

    /// Hides or shows the traffic-light buttons. Always called with the
    /// currently desired state so toggling the hidden-titlebar option off
    /// restores through the same path.
    private func setStandardWindowButtonsHidden(_ hidden: Bool, for window: NSObject) {
        let selector = NSSelectorFromString("standardWindowButton:")
        guard window.responds(to: selector) else { return }

        let method = window.method(for: selector)
        typealias StandardButtonFunc = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
        let buttonFunc = unsafeBitCast(method, to: StandardButtonFunc.self)

        for buttonType in [0, 1, 2] {  // close, miniaturize, zoom
            guard let button = buttonFunc(window, selector, buttonType)?.takeUnretainedValue() as? NSObject else {
                continue
            }
            button.setValue(hidden, forKey: "hidden")
        }
    }

    /// Marks chrome views we hid ourselves, so restoring never reveals views
    /// AppKit keeps hidden on its own.
    private nonisolated(unsafe) static var titlebarChromeHiddenKey: UInt8 = 0

    /// Hides or shows the native titlebar chrome. Hidden AppKit views don't
    /// hit-test, so the former titlebar strip passes events to our content.
    ///
    /// Sweeps every direct theme-frame subview rather than just
    /// NSTitlebarContainerView: macOS 27 hosts the titlebar's glass material
    /// in a sibling of the container, which otherwise survives as a blurry
    /// strip once our own top fill collapses.
    private func setTitlebarChromeHidden(_ hidden: Bool, for window: NSObject) {
        guard let contentView = window.value(forKey: "contentView") as? NSObject,
              let themeFrame = contentView.value(forKey: "superview") as? NSObject,
              let subviews = themeFrame.value(forKey: "subviews") as? [NSObject] else {
            return
        }

        for subview in subviews {
            if subview === contentView { continue }
            let className = String(describing: type(of: subview))
            if className == "TitlebarDragBlocker" || className == "TitlebarDragHandle" { continue }

            if hidden {
                if (subview.value(forKey: "hidden") as? Bool) == true { continue }
                subview.setValue(true, forKey: "hidden")
                objc_setAssociatedObject(
                    subview, &Self.titlebarChromeHiddenKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else if objc_getAssociatedObject(subview, &Self.titlebarChromeHiddenKey) != nil {
                subview.setValue(false, forKey: "hidden")
                objc_setAssociatedObject(
                    subview, &Self.titlebarChromeHiddenKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }

    /// Configure the NSWindow title bar for integrated appearance
    private func configureTitleBar(for window: NSObject, transparent: Bool, tabCount: Int) {
        // Always make titlebar transparent so our theme color shows through
        window.setValue(true, forKey: "titlebarAppearsTransparent")

        // Hide the title text (we show it in our tab bar instead)
        window.setValue(true, forKey: "titleVisibility")  // 1 = NSWindowTitleHidden

        // Add fullSizeContentView to extend content into titlebar area
        if let currentStyleMask = window.value(forKey: "styleMask") as? UInt {
            let fullSizeContentViewMask: UInt = 1 << 15
            let newStyleMask = currentStyleMask | fullSizeContentViewMask
            window.setValue(newStyleMask, forKey: "styleMask")
        }

        // Hidden-titlebar mode: hide the traffic lights and the titlebar
        // chrome entirely. The .titled styleMask bit is left alone —
        // toggling it forces AppKit to rebuild the frame view (see the
        // VisorWindowAccessor warning).
        let hideTitleBar = UserDefaults.standard.bool(forKey: "hideWindowTitleBar")
        setStandardWindowButtonsHidden(hideTitleBar, for: window)
        setTitlebarChromeHidden(hideTitleBar, for: window)

        // Configure window dragging behavior
        // The intended default for `tabsInTitlebarEnabled` is true. Direct `bool(forKey:)`
        // returns false when the key is absent (fresh install before the user has toggled
        // it), which would disagree with the UI toggle's @AppStorage default. Check
        // explicitly for nil and fall back to the intended default.
        let tabsInTitlebar = UserDefaults.standard.object(forKey: "tabsInTitlebarEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "tabsInTitlebarEnabled")
        let tabBarHidden = UserDefaults.standard.bool(forKey: "tabBarHidden")
        let topTabStyle = TopTabStyle.resolve(
            UserDefaults.standard.string(forKey: TopTabStyle.storageKey) ?? TopTabStyle.pills.rawValue
        )
        configureTitlebarSeparator(
            for: window,
            hidden: topTabStyle == .integrated && tabsInTitlebar && !tabBarHidden
        )
        configureWindowDragging(
            for: window,
            tabsInTitlebar: tabsInTitlebar,
            tabCount: tabCount,
            tabBarHidden: tabBarHidden,
            hideTitleBar: hideTitleBar
        )

        // Get the theme background color for the title bar
        if let themeColors = ThemeManager.shared.currentThemeInfo?.colors,
           let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type {
            // Parse the hex color and create NSColor
            let hexColor = themeColors.background.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "")

            var rgb: UInt64 = 0
            if Scanner(string: hexColor).scanHexInt64(&rgb) {
                let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
                let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
                let b = CGFloat(rgb & 0x0000FF) / 255.0
                let opacity = TransparencyManager.shared.backgroundOpacity

                // Create NSColor with colorWithRed:green:blue:alpha:
                let colorSelector = NSSelectorFromString("colorWithRed:green:blue:alpha:")
                if nsColorClass.responds(to: colorSelector) {
                    let colorMethod = nsColorClass.method(for: colorSelector)
                    typealias ColorFunction = @convention(c) (AnyClass, Selector, CGFloat, CGFloat, CGFloat, CGFloat) -> NSObject
                    let colorFunc = unsafeBitCast(colorMethod, to: ColorFunction.self)
                    let titlebarColor = colorFunc(nsColorClass, colorSelector, r, g, b, opacity)

                    // Try to set the titlebar background color
                    // This works on some macOS versions
                    if window.responds(to: NSSelectorFromString("setTitlebarColor:")) {
                        window.perform(NSSelectorFromString("setTitlebarColor:"), with: titlebarColor)
                    }
                }
            }
        }
    }

    /// AppKit draws its titlebar separator above Catalyst's SwiftUI content,
    /// so an active tab cannot visually bridge across it. Integrated titlebar
    /// tabs own that boundary and suppress the native rule; all other layouts
    /// restore AppKit's automatic behavior.
    private func configureTitlebarSeparator(for window: NSObject, hidden: Bool) {
        let selector = NSSelectorFromString("setTitlebarSeparatorStyle:")
        guard window.responds(to: selector) else { return }

        let method = window.method(for: selector)
        typealias SetSeparatorStyle = @convention(c) (AnyObject, Selector, Int) -> Void
        let setSeparatorStyle = unsafeBitCast(method, to: SetSeparatorStyle.self)
        // NSTitlebarSeparatorStyleAutomatic = 0, None = 1.
        setSeparatorStyle(window, selector, hidden ? 1 : 0)
    }

    /// Configures window dragging behavior for titlebar tabs mode
    /// Adds an invisible overlay to the titlebar container to block window dragging
    /// Only blocks dragging when there are multiple tabs to reorder and tab bar is visible
    /// Always adds drag handle for hand cursor affordance when tabs are in titlebar
    private func configureWindowDragging(
        for window: NSObject,
        tabsInTitlebar: Bool,
        tabCount: Int,
        tabBarHidden: Bool,
        hideTitleBar: Bool
    ) {
        // Get the content view and its superview (theme frame)
        guard let contentView = window.value(forKey: "contentView") as? NSObject,
              let themeFrame = contentView.value(forKey: "superview") as? NSObject else {
            return
        }

        // Find and remove existing drag blockers from theme frame and its subviews
        removeExistingBlockers(from: themeFrame)

        // Drag views exist when tabs live in the titlebar row, and always in
        // hidden-titlebar mode — with no titlebar the 12pt top strip is the
        // only way left to move the window, so keep it even when the tab bar
        // is hidden too.
        guard (tabsInTitlebar && !tabBarHidden) || hideTitleBar else {
            Self.logger.debug("Drag views removed (tabsInTitlebar=\(tabsInTitlebar), tabBarHidden=\(tabBarHidden))")
            return
        }

        // Find the titlebar container view. In hidden mode fall back to a
        // synthesized band at the top of the theme frame so the drag strip
        // survives an OS that renames the container class.
        let titlebarContainer = findTitlebarContainer(in: themeFrame)
        let titlebarFrame: CGRect
        if let containerFrame = (titlebarContainer?.value(forKey: "frame") as? NSValue)?.rectValue {
            titlebarFrame = containerFrame
        } else if hideTitleBar,
                  let themeBounds = (themeFrame.value(forKey: "bounds") as? NSValue)?.rectValue {
            titlebarFrame = CGRect(
                x: themeBounds.minX,
                y: themeBounds.maxY - 28,
                width: themeBounds.width,
                height: 28
            )
        } else {
            Self.logger.warning("Could not find titlebar container")
            return
        }

        let allocSelector = NSSelectorFromString("alloc")
        let initFrameSelector = NSSelectorFromString("initWithFrame:")
        let setAutoresizingSelector = NSSelectorFromString("setAutoresizingMask:")
        let setTagSelector = NSSelectorFromString("setTag:")
        let addPositionedSelector = NSSelectorFromString("addSubview:positioned:relativeTo:")

        let topInset: CGFloat = 12

        // Only add drag blocker when there are multiple tabs (to prevent accidental window drag while reordering).
        // Skipped in hidden-titlebar mode: the blocker lives inside the hidden
        // titlebar container, which no longer hit-tests.
        if tabCount > 1 && !hideTitleBar, let titlebarContainer {
            guard let dragBlockerClass = Self.dragBlockerClass else {
                Self.logger.warning("Failed to create drag blocker class")
                return
            }

            // Create blocker covering the titlebar (after window buttons at x=100)
            // Leave a 12pt top strip for window dragging, matching macOS Ghostty.
            let blockerFrame = CGRect(
                x: 100,
                y: 0,
                width: titlebarFrame.width - 100,
                height: titlebarFrame.height - topInset
            )

            guard let classObj = dragBlockerClass as? NSObject.Type,
                  let allocated = classObj.perform(allocSelector)?.takeUnretainedValue() as? NSObject else {
                return
            }

            let initMethod = allocated.method(for: initFrameSelector)
            typealias InitFunc = @convention(c) (AnyObject, Selector, CGRect) -> AnyObject
            let initFunc = unsafeBitCast(initMethod, to: InitFunc.self)
            let blocker = initFunc(allocated, initFrameSelector, blockerFrame)

            // Set autoresizing: width flexible
            if blocker.responds(to: setAutoresizingSelector) {
                let method = blocker.method(for: setAutoresizingSelector)
                typealias SetMaskFunc = @convention(c) (AnyObject, Selector, UInt) -> Void
                let setMaskFunc = unsafeBitCast(method, to: SetMaskFunc.self)
                setMaskFunc(blocker, setAutoresizingSelector, 2)  // NSViewWidthSizable
            }

            // Set tag for identification
            if blocker.responds(to: setTagSelector) {
                let method = blocker.method(for: setTagSelector)
                typealias SetTagFunc = @convention(c) (AnyObject, Selector, Int) -> Void
                let setTagFunc = unsafeBitCast(method, to: SetTagFunc.self)
                setTagFunc(blocker, setTagSelector, Self.dragBlockerTag)
            }

            // Add to titlebar container at the front
            if titlebarContainer.responds(to: addPositionedSelector) {
                let method = titlebarContainer.method(for: addPositionedSelector)
                typealias AddFunc = @convention(c) (AnyObject, Selector, AnyObject, Int, AnyObject?) -> Void
                let addFunc = unsafeBitCast(method, to: AddFunc.self)
                addFunc(titlebarContainer, addPositionedSelector, blocker, 1, nil)  // 1 = NSWindowAbove
            } else {
                titlebarContainer.perform(NSSelectorFromString("addSubview:"), with: blocker)
            }
        }

        // Always add drag handle view for the top strip (shows hand cursor when hovered)
        // This provides visual affordance for window dragging regardless of tab count
        guard let dragHandleClass = Self.dragHandleClass else {
            Self.logger.warning("Failed to create drag handle class")
            return
        }

        // Add the handle to the theme frame, above the full-size content view.
        // When hosted only inside the titlebar container, Catalyst can still
        // route the mouse down into the SwiftUI tab underneath while the
        // tracking area shows the hand cursor.
        // With the titlebar hidden there are no traffic lights, so the strip
        // extends to the left edge.
        let handleLeadingClearance: CGFloat = hideTitleBar ? 0 : 100
        let handleFrame = CGRect(
            x: titlebarFrame.minX + handleLeadingClearance,
            y: titlebarFrame.minY + titlebarFrame.height - topInset,
            width: titlebarFrame.width - handleLeadingClearance,
            height: topInset
        )

        guard let handleClassObj = dragHandleClass as? NSObject.Type,
              let handleAllocated = handleClassObj.perform(allocSelector)?.takeUnretainedValue() as? NSObject else {
            return
        }

        let initMethod = handleAllocated.method(for: initFrameSelector)
        typealias InitFunc = @convention(c) (AnyObject, Selector, CGRect) -> AnyObject
        let initFunc = unsafeBitCast(initMethod, to: InitFunc.self)
        let handle = initFunc(handleAllocated, initFrameSelector, handleFrame)

        // Set autoresizing: width flexible, top margin flexible
        if handle.responds(to: setAutoresizingSelector) {
            let method = handle.method(for: setAutoresizingSelector)
            typealias SetMaskFunc = @convention(c) (AnyObject, Selector, UInt) -> Void
            let setMaskFunc = unsafeBitCast(method, to: SetMaskFunc.self)
            // NSViewWidthSizable (2) | NSViewMinYMargin (8) = 10
            setMaskFunc(handle, setAutoresizingSelector, 10)
        }

        // Set tag for identification
        if handle.responds(to: setTagSelector) {
            let method = handle.method(for: setTagSelector)
            typealias SetTagFunc = @convention(c) (AnyObject, Selector, Int) -> Void
            let setTagFunc = unsafeBitCast(method, to: SetTagFunc.self)
            setTagFunc(handle, setTagSelector, Self.dragHandleTag)
        }

        // Add drag handle above the content view.
        if themeFrame.responds(to: addPositionedSelector) {
            let method = themeFrame.method(for: addPositionedSelector)
            typealias AddFunc = @convention(c) (AnyObject, Selector, AnyObject, Int, AnyObject?) -> Void
            let addFunc = unsafeBitCast(method, to: AddFunc.self)
            addFunc(themeFrame, addPositionedSelector, handle, 1, nil)  // 1 = NSWindowAbove
        } else {
            themeFrame.perform(NSSelectorFromString("addSubview:"), with: handle)
        }

        let updateTrackingSelector = NSSelectorFromString("updateTrackingAreas")
        if handle.responds(to: updateTrackingSelector) {
            _ = handle.perform(updateTrackingSelector)
        }

        let invalidateCursorRectsSelector = NSSelectorFromString("invalidateCursorRectsForView:")
        if window.responds(to: invalidateCursorRectsSelector) {
            window.perform(invalidateCursorRectsSelector, with: handle)
        }

    }

    /// Finds the titlebar container view in the theme frame's subviews
    private func findTitlebarContainer(in themeFrame: NSObject) -> NSObject? {
        let subviewsSelector = NSSelectorFromString("subviews")
        guard themeFrame.responds(to: subviewsSelector),
              let subviews = themeFrame.value(forKey: "subviews") as? [NSObject] else {
            return nil
        }

        for subview in subviews {
            let className = String(describing: type(of: subview))
            if className.contains("Titlebar") {
                return subview
            }
        }
        return nil
    }

    /// Removes existing drag blockers and drag handles from a view and its subviews
    private func removeExistingBlockers(from view: NSObject) {
        let subviewsSelector = NSSelectorFromString("subviews")

        guard view.responds(to: subviewsSelector),
              let subviews = view.value(forKey: "subviews") as? [NSObject] else {
            return
        }

        for subview in subviews {
            // Check if this is our blocker or handle by class name
            let className = String(describing: type(of: subview))
            if className == "TitlebarDragBlocker" || className == "TitlebarDragHandle" {
                subview.perform(NSSelectorFromString("removeFromSuperview"))
                continue
            }
            // Recursively check subviews
            removeExistingBlockers(from: subview)
        }
    }

    #endif
}

#endif
