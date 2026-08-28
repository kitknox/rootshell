//
//  CatalystAppDelegate.swift
//  rootshell
//
//  Mac Catalyst app delegate for intercepting system keyboard shortcuts
//

import UIKit
import os
import ObjectiveC

#if targetEnvironment(macCatalyst)

private let logger = Logger(subsystem: "com.rootshell", category: "CatalystAppDelegate")

// MARK: - UIApplication Menu Actions Extension
// These methods are on UIApplication to ensure they're always in the responder chain.
// On older macOS with SwiftUI's @UIApplicationDelegateAdaptor, the AppDelegate may not
// be properly reachable in the responder chain for menu validation.

extension UIApplication {

    // MARK: File Menu Actions
    // All actions use sendAction to route through responder chain to the focused terminal

    @objc func ghostty_newLocalShell(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuCreateLocalShell(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_newTab(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNewTab(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_newWindow(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNewWindow(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_duplicateSshTab(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuDuplicateTabWithSSH(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Edit Menu Actions

    @objc func ghostty_clearScreen(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuClearScreen(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_find(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.findInTerminal(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Terminal Menu Actions

    /// Reserved Cmd+Period chord, delivered via the menu rail. The nil-target
    /// walk starts at the first responder, so a recording ShortcutCaptureUIView
    /// wins over the focused terminal's handler.
    @objc func ghostty_systemCancel(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSystemCancel(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_increaseFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.increaseFontSize(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_decreaseFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.decreaseFontSize(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_resetFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.resetFontSizeToDefault(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_splitRight(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSplitRight(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_splitDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSplitDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitLeft(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitLeft(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitRight(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitRight(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitUp(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitUp(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleSplitZoom(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleSplitZoom(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_equalizeSplits(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuEqualizeSplits(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleTabBar(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTabBar(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleGroupMode(_ sender: Any?) {
        if !sendAction(#selector(Ghostty.TerminalView.menuToggleGroupMode(_:)), to: nil, from: sender, for: nil) {
            menuToggleGroupMode(sender)
        }
    }

    @objc func ghostty_toggleTabSwitcher(_ sender: Any?) {
        menuToggleTabSwitcher(VNCReservedKeyboardShortcut.toggleTabSwitcher.notificationSender)
    }

    @objc func ghostty_toggleTabExpose(_ sender: Any?) {
        if !sendAction(#selector(Ghostty.TerminalView.menuToggleTabExpose(_:)), to: nil, from: sender, for: nil) {
            menuToggleTabExpose(sender)
        }
    }

    @objc func ghostty_previousGroup(_ sender: Any?) {
        menuPreviousGroup(sender)
    }

    @objc func ghostty_nextGroup(_ sender: Any?) {
        menuNextGroup(sender)
    }

    @objc func ghostty_toggleTransparency(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTransparency(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleTitleBar(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTitleBar(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleAutoRedact(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleAutoRedact(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleBackgroundEffect(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleBackgroundEffect(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollPageUp(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollPageUp(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollPageDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollPageDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollToTop(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollToTop(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollToBottom(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollToBottom(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleThemePicker(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleThemePicker(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleClipboardManager(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleClipboardManager(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleCompose(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleCompose(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleMouseCapture(_ sender: Any?) {
        if !sendAction(NSSelectorFromString("toggleVNCKeyboardCapture:"), to: nil, from: sender, for: nil) {
            sendAction(#selector(Ghostty.TerminalView.menuToggleMouseCapture(_:)), to: nil, from: sender, for: nil)
        }
    }

    @objc func ghostty_toggleFullScreen(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleFullScreen(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Shell Menu Actions

    @objc func ghostty_browseHosts(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuBrowseHosts(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_browseProfiles(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuBrowseProfiles(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_openSettings(_ sender: Any?) {
        menuOpenSettings(VNCReservedKeyboardShortcut.openSettings.notificationSender)
    }

    @objc func ghostty_toggleAIAgent(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleAIAgent(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleVoiceAgent(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleVoiceAgent(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Tabs Menu Actions

    @objc func ghostty_previousTab(_ sender: Any?) {
        menuPreviousTab(VNCReservedKeyboardShortcut.previousTab.notificationSender)
    }

    @objc func ghostty_nextTab(_ sender: Any?) {
        menuNextTab(VNCReservedKeyboardShortcut.nextTab.notificationSender)
    }

    @objc func ghostty_showTmuxSessions(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuShowTmuxSessions(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_detachOtherClients(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuDetachOtherClients(_:)), to: nil, from: sender, for: nil)
    }

    // One selector per tab: UIKit refuses to display a menu that repeats an
    // action, so a single ghostty_selectTab: shared by Tab 1-9 silently dropped
    // the whole Tabs menu.
    @objc func ghostty_selectTab1(_ sender: Any?) { ghostty_selectTab(1, sender) }
    @objc func ghostty_selectTab2(_ sender: Any?) { ghostty_selectTab(2, sender) }
    @objc func ghostty_selectTab3(_ sender: Any?) { ghostty_selectTab(3, sender) }
    @objc func ghostty_selectTab4(_ sender: Any?) { ghostty_selectTab(4, sender) }
    @objc func ghostty_selectTab5(_ sender: Any?) { ghostty_selectTab(5, sender) }
    @objc func ghostty_selectTab6(_ sender: Any?) { ghostty_selectTab(6, sender) }
    @objc func ghostty_selectTab7(_ sender: Any?) { ghostty_selectTab(7, sender) }
    @objc func ghostty_selectTab8(_ sender: Any?) { ghostty_selectTab(8, sender) }
    @objc func ghostty_selectTab9(_ sender: Any?) { ghostty_selectTab(9, sender) }

    private func ghostty_selectTab(_ index: Int, _ sender: Any?) {
        let selector: Selector
        switch index {
        case 1: selector = #selector(Ghostty.TerminalView.menuSelectTab1(_:))
        case 2: selector = #selector(Ghostty.TerminalView.menuSelectTab2(_:))
        case 3: selector = #selector(Ghostty.TerminalView.menuSelectTab3(_:))
        case 4: selector = #selector(Ghostty.TerminalView.menuSelectTab4(_:))
        case 5: selector = #selector(Ghostty.TerminalView.menuSelectTab5(_:))
        case 6: selector = #selector(Ghostty.TerminalView.menuSelectTab6(_:))
        case 7: selector = #selector(Ghostty.TerminalView.menuSelectTab7(_:))
        case 8: selector = #selector(Ghostty.TerminalView.menuSelectTab8(_:))
        case 9: selector = #selector(Ghostty.TerminalView.menuSelectTab9(_:))
        default: return
        }
        sendAction(selector, to: nil, from: sender, for: nil)
    }

    // MARK: App Menu Actions (legacy macOS only)
    // These are needed because CatalystAppDelegate isn't reachable in responder chain on older macOS
    // We implement the logic directly here rather than delegating, as the delegate cast can fail

    @objc func ghostty_showAbout(_ sender: Any?) {
        // Build credits as an attributed string
        let credits = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 8

        // Use NSColor for AppKit About panel (UIColor doesn't translate correctly)
        guard let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type,
              let secondaryLabelColor = nsColorClass.value(forKey: "secondaryLabelColor") else {
            return
        }

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .link: URL(string: "https://www.rootshell.com")!,
            .paragraphStyle: paragraphStyle
        ]

        credits.append(NSAttributedString(string: "By Kit Knox\n", attributes: normalAttributes))
        credits.append(NSAttributedString(string: "www.rootshell.com\n\n", attributes: linkAttributes))
        credits.append(NSAttributedString(string: "Terminal emulator based on libghostty\nby Mitchell Hashimoto", attributes: normalAttributes))

        // Use dynamic Objective-C runtime to access NSApplication (not directly available in Catalyst)
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type else { return }
        guard let nsApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        var options: [String: Any] = [
            "Credits": credits,
            "ApplicationName": "Rootshell",
            "ApplicationVersion": "\(version) (\(BuildInfo.date))"
        ]
        if let applicationIcon = AppIconManager.shared.makeMacCatalystAboutPanelIcon() {
            options["ApplicationIcon"] = applicationIcon
        }

        nsApp.perform(NSSelectorFromString("orderFrontStandardAboutPanelWithOptions:"), with: options)
    }

    @objc func ghostty_close(_ sender: Any?) {
        logger.info("ghostty_close called")
        let handled = sendAction(
            #selector(Ghostty.TerminalView.closeSplit(_:)),
            to: nil,
            from: sender,
            for: nil
        )
        logger.info("ghostty_close: sendAction returned \(handled)")
    }

    @objc func ghostty_quit(_ sender: Any?) {
        logger.info("ghostty_quit called")

        // Check if there are open tabs
        let hasOpenTabs = SessionTracker.shared.hasOpenTabs
        let tabCount = SessionTracker.shared.totalTabCount

        guard hasOpenTabs else {
            logger.info("No open tabs, quitting immediately")
            ghostty_performQuit()
            return
        }

        logger.info("Open tabs detected (\(tabCount)), showing confirmation")
        ghostty_showQuitConfirmation(tabCount: tabCount)
    }

    private func ghostty_showQuitConfirmation(tabCount: Int) {
        // Find active window scene for presenting alert
        guard let windowScene = connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.warning("Could not find window to present quit confirmation, quitting anyway")
            ghostty_performQuit()
            return
        }

        let message = tabCount == 1
            ? "You have 1 open terminal. Are you sure you want to quit?"
            : "You have \(tabCount) open terminals. Are you sure you want to quit?"

        let alert = UIAlertController(
            title: "Quit Rootshell?",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in
            self?.ghostty_performQuit()
        })

        // Find the topmost presented controller to avoid presentation conflicts
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(alert, animated: true)
    }

    private func ghostty_performQuit() {
        logger.info("Performing quit")

        // Stop helper process first
        HelperConnection.shared.stopHelper()

        // Request destruction of all scene sessions first
        for session in connectedScenes.compactMap({ $0 as? UIWindowScene }).map({ $0.session }) {
            requestSceneSessionDestruction(session, options: nil)
        }

        // Use NSRunningApplication.current.terminate() for clean app termination
        // This properly goes through the app lifecycle unlike NSApplication.terminate
        // which doesn't always work correctly in Mac Catalyst
        guard let nsRunningAppClass = NSClassFromString("NSRunningApplication") as? NSObject.Type,
              let currentApp = nsRunningAppClass.value(forKey: "currentApplication") as? NSObject else {
            logger.error("Could not access NSRunningApplication to quit")
            return
        }

        currentApp.perform(NSSelectorFromString("terminate"))
    }

    // MARK: - Update Actions (Standalone Mac Catalyst only)

    #if STANDALONE
    @objc func ghostty_checkForUpdates(_ sender: Any?) {
        Task { @MainActor in
            UpdateManager.shared.checkForUpdates()
        }
    }
    #endif
}

class CatalystAppDelegate: AppDelegate {

    // MARK: - CloudKit Sync Debouncing

    /// Last time we auto-synced on app activation (debounce to avoid excessive syncs)
    private var lastActivationSyncDate: Date?
    private let activationSyncInterval: TimeInterval = 180 // 3 minutes

    // MARK: - Application Lifecycle

    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Call super to register for remote notifications (CloudKit push)
        _ = super.application(application, didFinishLaunchingWithOptions: launchOptions)

        #if STANDALONE
        // Force Sparkle scheduler to start at launch (UpdateManager.shared is lazy)
        _ = UpdateManager.shared

        // Visor: register the global hotkey if the user has it enabled.
        VisorHotkeyManager.shared.registerIfEnabled()
        #endif

        // Mac Catalyst: Use NSWorkspace notification for app activation (Cmd-Tab)
        // scenePhase and UIApplication.didBecomeActiveNotification don't fire reliably
        setupWorkspaceActivationObserver()
        setupApplicationHideObserver()
        #if STANDALONE
        setupVisorAutohideObserver()
        // Deferred: the UIKit shim installs the NSApplication delegate as
        // part of launch; one runloop turn later it is reliably in place.
        DispatchQueue.main.async { [weak self] in
            self?.installDockReopenInterposer()
        }
        #endif

        // Disable the macOS "press and hold for accent characters" popup.
        // Terminal users need key repeat (e.g., holding h/j/k/l in vim).
        // This only affects this app, not the system-wide setting.
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

        // Eagerly load saved window state so the restore-phase signal
        // (`hasPendingRegularWindowRestoration`) is authoritative inside
        // `CatalystSceneDelegate.scene(_:willConnectTo:)`, which runs before any
        // MainView.onAppear lazy-load. That gate decides whether a connecting
        // window is pre-sized from its saved frame (launch restore) or sized to
        // the last-focused window via the cascade (a genuine Cmd-N window).
        // Skipped when the device is locked at a cold/background launch — the gate
        // then falls back to false (treated as a new window), which is harmless.
        if ProtectedDataGuard.isAvailable {
            WindowStateManager.shared.ensureStateLoaded()
        }

        return true
    }

    private func setupApplicationHideObserver() {
        guard let nsApplicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = nsApplicationClass.value(forKey: "sharedApplication") as? NSObject else {
            logger.warning("Could not access NSApplication for hide notifications")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidHideViaAppKit),
            name: NSNotification.Name("NSApplicationDidHideNotification"),
            object: application
        )
        logger.info("Registered for NSApplication hide notifications")
    }

    #if STANDALONE
    /// AppKit consults `applicationShouldHandleReopen:hasVisibleWindows:` on
    /// every Dock-click reopen — the only hook that reliably fires when the
    /// hidden visor's scene session swallows the reopen: after `orderOut:`
    /// the scene stays foregroundActive, so no scene event ever arrives and
    /// UIKit's reopen handling does nothing visible. Catalyst's UIKit shim
    /// owns the NSApplication delegate, so interpose the method there.
    private static var dockReopenInterposerInstalled = false

    private func installDockReopenInterposer() {
        guard !Self.dockReopenInterposerInstalled else { return }
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let delegate = sharedApp.value(forKey: "delegate") as? NSObject,
              let delegateClass = object_getClass(delegate) else {
            return
        }

        let selector = NSSelectorFromString("applicationShouldHandleReopen:hasVisibleWindows:")
        typealias ReopenFunc = @convention(c) (NSObject, Selector, NSObject, Bool) -> Bool
        let originalIMP: IMP? = class_getInstanceMethod(delegateClass, selector)
            .map { method_getImplementation($0) }

        let block: @convention(block) (NSObject, NSObject, Bool) -> Bool = { target, app, hasVisibleWindows in
            let handled = MainActor.assumeIsolated {
                CatalystAppDelegate.handleDockReopen(hasVisibleWindows: hasVisibleWindows)
            }
            if handled { return false }
            if let originalIMP {
                return unsafeBitCast(originalIMP, to: ReopenFunc.self)(target, selector, app, hasVisibleWindows)
            }
            return true
        }

        let imp = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(delegateClass, selector) {
            method_setImplementation(method, imp)
        } else {
            class_addMethod(delegateClass, selector, imp, "B@:@B")
        }
        Self.dockReopenInterposerInstalled = true
    }

    /// Returns true when the reopen was handled here: no visible windows,
    /// only the hidden visor's scene connected, no summon in flight — the
    /// state where the system reopen does nothing. Opens a main window via
    /// the same nil-session activation Cmd-N uses.
    private static func handleDockReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        let scenes = UIApplication.shared.connectedScenes
        let hasVisorScene = scenes.contains { CatalystSceneDelegate.isVisorScene($0) }
        let hasRegularScene = scenes.contains {
            $0 is UIWindowScene && !CatalystSceneDelegate.isVisorScene($0)
        }
        guard hasVisorScene, !hasRegularScene,
              !VisorController.shared.isVisible,
              !VisorSceneLifecycle.summonInFlight else { return false }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
        return true
    }

    private func setupVisorAutohideObserver() {
        guard let nsApplicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = nsApplicationClass.value(forKey: "sharedApplication") as? NSObject else {
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActiveForVisor),
            name: NSNotification.Name("NSApplicationDidResignActiveNotification"),
            object: application
        )
    }

    @objc private func applicationDidResignActiveForVisor(_ notification: Notification) {
        Task { @MainActor in
            guard VisorSettings.shared.autohide,
                  VisorController.shared.isVisible else { return }
            VisorController.shared.hide()
        }
    }
    #endif

    private func setupWorkspaceActivationObserver() {
        // Access NSWorkspace via Objective-C runtime (not directly available in Catalyst)
        guard let nsWorkspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
              let workspace = nsWorkspaceClass.value(forKey: "sharedWorkspace") as? NSObject,
              let notificationCenter = workspace.value(forKey: "notificationCenter") as? NotificationCenter else {
            logger.warning("Could not access NSWorkspace for activation notifications")
            return
        }

        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApp),
            name: NSNotification.Name("NSWorkspaceDidActivateApplicationNotification"),
            object: nil
        )
        logger.info("Registered for NSWorkspace activation notifications")
    }

    @objc private func workspaceDidActivateApp(_ notification: Notification) {
        // Check if this activation is for our app
        guard let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSObject,
              let bundleId = app.value(forKey: "bundleIdentifier") as? String,
              bundleId == Bundle.main.bundleIdentifier else {
            return
        }

        // Debounce: only sync once every 3 minutes on activation
        if let lastSync = lastActivationSyncDate,
           Date().timeIntervalSince(lastSync) < activationSyncInterval {
            logger.debug("App activated, skipping sync (last sync \(Int(Date().timeIntervalSince(lastSync)))s ago)")
            return
        }

        logger.info("App activated via NSWorkspace, triggering CloudKit sync")
        lastActivationSyncDate = Date()

        Task { @MainActor in
            if CloudKitSyncManager.shared.isSyncEnabled {
                try? await CloudKitSyncManager.shared.syncNow()
            }
        }
    }

    @objc private func applicationDidHideViaAppKit(_ notification: Notification) {
        persistCatalystStateAndWindowGeometry(reason: "hide")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        persistCatalystStateAndWindowGeometry(reason: "terminate")

        #if STANDALONE
        // Destroy the visor scene on clean termination so the OS never
        // persists it for restoration — that keeps the common quit path
        // flash-free (the next launch has no zombie to suppress). The
        // willConnectTo backstop only has to cover crash/force-quit, where
        // this never runs. We intentionally do NOT clear
        // VisorSceneLifecycle.persistedSceneId here: if this destroy races the
        // OS's session snapshot and the scene restores anyway, the persisted
        // id is what lets the backstop recognize it reliably (the
        // configuration-name/userActivity heuristics are unreliable at cold
        // launch). The id only ever matches a scene actually being restored
        // under that exact identifier, so leaving it is harmless.
        for scene in application.connectedScenes
        where CatalystSceneDelegate.isVisorScene(scene) {
            application.requestSceneSessionDestruction(scene.session, options: nil)
        }
        #endif

        // Stop the helper process on app termination
        // Child processes on macOS don't auto-terminate when parent exits - they become orphans
        HelperConnection.shared.stopHelper()
    }

    private func persistCatalystStateAndWindowGeometry(reason: String) {
        saveConnectedWindowGeometry()

        guard let state = WindowStateManager.shared.gatherState() else {
            logger.info("Catalyst \(reason): no window state available to persist")
            return
        }

        let didWrite = WindowStateManager.writeStateToDisk(state)
        logger.info("Catalyst \(reason): window state persistence \(didWrite ? "completed" : "failed")")
    }

    private func saveConnectedWindowGeometry() {
        // Capture current window geometry. windowScene(_:didUpdate:…) does not
        // fire on simple window moves on Catalyst, so hide/terminate are important
        // chances to persist a position the user dragged the window to.
        // The visor scene must never contribute: its frame (or parked
        // off-screen origin) would poison the last-focused size that new
        // main windows cascade from.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  !CatalystSceneDelegate.isVisorScene(scene) else { continue }
            let frame = windowScene.effectiveGeometry.systemFrame
            WindowSizeManager.shared.updateWindowFrame(frame)
        }
    }

    // MARK: - URL Handling

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        logger.info("AppDelegate received URL: \(url.absoluteString)")

        if let components = SSHURLParser.parse(url) {
            logger.info("Parsed SSH URL: \(components.displayString)")
            AppIntentCoordinator.shared.deposit(.openSSH(components))
            return true
        }

        if let components = MoshURLParser.parse(url) {
            logger.info("Parsed Mosh URL: \(components.displayString)")
            AppIntentCoordinator.shared.deposit(.openMosh(components))
            return true
        }

        return false
    }

    // MARK: - Scene Configuration

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = CatalystSceneDelegate.self
        return config
    }

    // MARK: - Menu Customization
    // On macOS 26+ (macCatalyst 26.0): SwiftUI Commands handle most menu items (see AppCommands.swift)
    // On macOS 15 and earlier: We build all menus manually using UIMenuBuilder
    //
    // This delegate always handles items that need UIKit integration:
    // - About dialog with NSAttributedString credits
    // - Quit confirmation with UIAlertController
    // - Font menu removal to prevent Cmd-T conflict

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard builder.system == .main else { return }

        // CRITICAL: Remove Font menu to prevent Cmd-T "Show Fonts" conflict
        // This is required even with SwiftUI Commands because the system Font menu
        // takes priority on older macOS versions
        builder.remove(menu: .font)

        // Determine which selectors to use based on macOS version
        // On macOS 26+: CatalystAppDelegate methods work (proper responder chain)
        // On older macOS: Use UIApplication extension methods (always in responder chain)
        let aboutSelector: Selector
        let closeSelector: Selector
        let quitSelector: Selector

        if #available(macCatalyst 26.0, *) {
            aboutSelector = #selector(showAbout(_:))
            closeSelector = #selector(handleClose(_:))
#if CMD_Q_INTERCEPT
            quitSelector = #selector(handleQuit(_:))
            #endif
        } else {
            aboutSelector = #selector(UIApplication.ghostty_showAbout(_:))
            closeSelector = #selector(UIApplication.ghostty_close(_:))
#if CMD_Q_INTERCEPT
            quitSelector = #selector(UIApplication.ghostty_quit(_:))
            #endif
        }

        // Replace About menu item with custom About dialog
        builder.replaceChildren(ofMenu: .about) { _ in
            let aboutCommand = UICommand(
                title: "About Rootshell",
                action: aboutSelector
            )
            return [aboutCommand]
        }

        // Add "Check for Updates..." menu item (Standalone builds only)
        #if STANDALONE
        let checkForUpdatesMenu = UIMenu(
            title: "",
            options: .displayInline,
            children: [
                UICommand(
                    title: "Check for Updates...",
                    action: #selector(UIApplication.ghostty_checkForUpdates(_:))
                )
            ]
        )
        builder.insertSibling(checkForUpdatesMenu, afterMenu: .about)
        #endif

        // CRITICAL: Replace Close command (Cmd-W) to close tabs instead of windows
        // System default closes the entire window - we want to close tabs/splits first
        builder.replaceChildren(ofMenu: .close) { _ in
            let closeCommand = UIKeyCommand(
                title: String(localized: "Close Tab"),
                action: closeSelector,
                input: "w",
                modifierFlags: [.command]
            )
            return [closeCommand]
        }

        // Rootshell is not document-based. The default Catalyst Document menu
        // contains Duplicate/Move/Rename/Export, and Duplicate owns Cmd+Shift+S,
        // which hides the tmux Sessions shortcut from our Tabs menu.
        builder.remove(menu: .document)

        // Replace Quit command (Cmd-Q) to show confirmation when tabs are open
        #if CMD_Q_INTERCEPT
        builder.replaceChildren(ofMenu: .quit) { _ in
            let quitCommand = UIKeyCommand(
                title: String(localized: "Quit Rootshell"),
                action: quitSelector,
                input: "q",
                modifierFlags: [.command]
            )
            return [quitCommand]
        }
        #endif

        // On macOS 26+ (macCatalyst 26.0): SwiftUI Commands handle the rest
        if #available(macCatalyst 26.0, *) {
            return
        }

        // Legacy (macOS 15 and earlier): Build all menus manually.
        //
        // CRITICAL: UIKit silently refuses to insert a menu holding a key
        // equivalent a system menu already owns, dropping the whole menu. Format >
        // Text owns ⌘{ / ⌘} (Align Left/Right), which killed the entire Tabs menu,
        // and Find owns ⇧⌘G (Find Previous), which killed the View toggles. Neither
        // menu is meaningful in a terminal.
        builder.remove(menu: .format)
        builder.remove(menu: .find)

        buildFileMenu(builder)
        buildEditMenu(builder)
        buildViewMenuItems(builder)
        // Each custom menu anchors to `.view`, a system menu, rather than to the
        // previously inserted custom one, so one failed lookup cannot silently
        // drop every menu after it. Reverse order gives View, Terminal, Shell, Tabs.
        buildTabsMenu(builder)
        buildShellMenu(builder)
        buildTerminalMenu(builder)
    }

    // MARK: - Legacy Menu Builders (pre-macOS 26)
    // NOTE: Menu shortcuts shown here are defaults. Actual keyboard input is handled
    // by KeybindCommandGenerator which respects user customizations from KeybindManager.
    // The menu display shows default shortcuts even when customized, but the actual
    // behavior follows KeybindManager settings.

    private func buildFileMenu(_ builder: UIMenuBuilder) {
        let newLocalShell = UIKeyCommand(
            title: String(localized: "New Local Shell"),
            action: #selector(UIApplication.ghostty_newLocalShell(_:)),
            input: "t",
            modifierFlags: [.command]
        )

        let newTab = UIKeyCommand(
            title: String(localized: "New Tab"),
            action: #selector(UIApplication.ghostty_newTab(_:)),
            input: "s",
            modifierFlags: [.command]
        )

        let newWindow = UIKeyCommand(
            title: String(localized: "New Window"),
            action: #selector(UIApplication.ghostty_newWindow(_:)),
            input: "n",
            modifierFlags: [.command]
        )

        let duplicateSshTab = UIKeyCommand(
            title: String(localized: "Duplicate SSH Tab"),
            action: #selector(UIApplication.ghostty_duplicateSshTab(_:)),
            input: "R",
            modifierFlags: [.command, .shift]
        )

        builder.replaceChildren(ofMenu: .newScene) { _ in
            [newLocalShell, newTab, newWindow, duplicateSshTab]
        }
    }

    private func buildEditMenu(_ builder: UIMenuBuilder) {
        let clearScreen = UIKeyCommand(
            title: String(localized: "Clear Screen"),
            action: #selector(UIApplication.ghostty_clearScreen(_:)),
            input: "k",
            modifierFlags: [.command]
        )

        let find = UIKeyCommand(
            title: String(localized: "Find"),
            action: #selector(UIApplication.ghostty_find(_:)),
            input: "f",
            modifierFlags: [.command]
        )

        let clipboardManager = UIKeyCommand(
            title: String(localized: "Clipboard Manager"),
            action: #selector(UIApplication.ghostty_toggleClipboardManager(_:)),
            input: "c",
            modifierFlags: [.command, .shift]
        )

        let editMenu = UIMenu(title: "", options: .displayInline, children: [clearScreen, find, clipboardManager])
        builder.insertChild(editMenu, atEndOfMenu: .edit)
    }

    private func buildViewMenuItems(_ builder: UIMenuBuilder) {
        // Font size commands — injected into system View menu
        let increaseFont = UIKeyCommand(
            title: String(localized: "Increase Font Size"),
            action: #selector(UIApplication.ghostty_increaseFontSize(_:)),
            input: "+",
            modifierFlags: [.command]
        )

        let decreaseFont = UIKeyCommand(
            title: String(localized: "Decrease Font Size"),
            action: #selector(UIApplication.ghostty_decreaseFontSize(_:)),
            input: "-",
            modifierFlags: [.command]
        )

        let resetFont = UIKeyCommand(
            title: String(localized: "Reset Font Size"),
            action: #selector(UIApplication.ghostty_resetFontSize(_:)),
            input: "0",
            modifierFlags: [.command]
        )

        let fontGroup = UIMenu(title: "", options: .displayInline, children: [
            increaseFont, decreaseFont, resetFont
        ])

        // View toggles
        let toggleTabBar = UIKeyCommand(
            title: String(localized: "Toggle Top Tab Bar"),
            action: #selector(UIApplication.ghostty_toggleTabBar(_:)),
            input: "B",
            modifierFlags: [.command, .shift]
        )

        let toggleGroupMode = UIKeyCommand(
            title: String(localized: "Toggle Group Mode"),
            action: #selector(UIApplication.ghostty_toggleGroupMode(_:)),
            input: "g",
            modifierFlags: [.command, .shift]
        )

        let toggleBackgroundEffect = UIKeyCommand(
            title: String(localized: "Toggle Background Effect"),
            action: #selector(UIApplication.ghostty_toggleBackgroundEffect(_:)),
            input: "U",
            modifierFlags: [.command, .shift]
        )

        let toggleThemePicker = UIKeyCommand(
            title: String(localized: "Toggle Theme Picker"),
            action: #selector(UIApplication.ghostty_toggleThemePicker(_:)),
            input: "t",
            modifierFlags: [.command, .shift]
        )

        let toggleTransparency = UIKeyCommand(
            title: String(localized: "Toggle Transparency"),
            action: #selector(UIApplication.ghostty_toggleTransparency(_:)),
            input: "u",
            modifierFlags: [.command]
        )

        let toggleTitleBar = UIKeyCommand(
            title: String(localized: "Toggle Title Bar"),
            action: #selector(UIApplication.ghostty_toggleTitleBar(_:)),
            input: "h",
            modifierFlags: [.command, .shift]
        )

        // Checked menu item: RedactionManager posts a menu rebuild whenever
        // its state changes, so the checkmark stays current.
        let toggleAutoRedact = UIKeyCommand(
            title: String(localized: "Auto-Redact"),
            action: #selector(UIApplication.ghostty_toggleAutoRedact(_:)),
            input: "r",
            modifierFlags: [.command, .control],
            state: RedactionManager.shared.isEnabled ? .on : .off
        )

        let toggleGroup = UIMenu(title: "", options: .displayInline, children: [
            toggleTabBar, toggleGroupMode, toggleBackgroundEffect, toggleThemePicker, toggleTransparency, toggleTitleBar, toggleAutoRedact
        ])

        builder.insertChild(fontGroup, atEndOfMenu: .view)
        builder.insertChild(toggleGroup, atEndOfMenu: .view)
    }

    private func buildTerminalMenu(_ builder: UIMenuBuilder) {
        // Split creation commands
        let splitRight = UIKeyCommand(
            title: String(localized: "Split Right"),
            action: #selector(UIApplication.ghostty_splitRight(_:)),
            input: "d",
            modifierFlags: [.command]
        )

        let splitDown = UIKeyCommand(
            title: String(localized: "Split Down"),
            action: #selector(UIApplication.ghostty_splitDown(_:)),
            input: "D",
            modifierFlags: [.command, .shift]
        )

        let splitCreateGroup = UIMenu(title: "", options: .displayInline, children: [
            splitRight, splitDown
        ])

        // Focus Split submenu (real submenu, not inline)
        let focusLeft = UIKeyCommand(
            title: String(localized: "Left"),
            action: #selector(UIApplication.ghostty_focusSplitLeft(_:)),
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: [.command, .alternate]
        )

        let focusRight = UIKeyCommand(
            title: String(localized: "Right"),
            action: #selector(UIApplication.ghostty_focusSplitRight(_:)),
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: [.command, .alternate]
        )

        let focusUp = UIKeyCommand(
            title: String(localized: "Up"),
            action: #selector(UIApplication.ghostty_focusSplitUp(_:)),
            input: UIKeyCommand.inputUpArrow,
            modifierFlags: [.command, .alternate]
        )

        let focusDown = UIKeyCommand(
            title: String(localized: "Down"),
            action: #selector(UIApplication.ghostty_focusSplitDown(_:)),
            input: UIKeyCommand.inputDownArrow,
            modifierFlags: [.command, .alternate]
        )

        let focusSplitSubmenu = UIMenu(
            title: String(localized: "Focus Split"),
            children: [focusLeft, focusRight, focusUp, focusDown]
        )

        let focusSplitGroup = UIMenu(title: "", options: .displayInline, children: [
            focusSplitSubmenu
        ])

        // Split management commands
        let toggleZoom = UIKeyCommand(
            title: String(localized: "Toggle Split Zoom"),
            action: #selector(UIApplication.ghostty_toggleSplitZoom(_:)),
            input: "Z",
            modifierFlags: [.command, .shift]
        )

        let equalize = UIKeyCommand(
            title: String(localized: "Equalize Splits"),
            action: #selector(UIApplication.ghostty_equalizeSplits(_:)),
            input: "E",
            modifierFlags: [.command, .shift]
        )

        let splitManageGroup = UIMenu(title: "", options: .displayInline, children: [
            toggleZoom, equalize
        ])

        // Scroll commands
        let scrollPageUp = UIKeyCommand(
            title: String(localized: "Scroll Page Up"),
            action: #selector(UIApplication.ghostty_scrollPageUp(_:)),
            input: UIKeyCommand.inputPageUp,
            modifierFlags: [.shift]
        )

        let scrollPageDown = UIKeyCommand(
            title: String(localized: "Scroll Page Down"),
            action: #selector(UIApplication.ghostty_scrollPageDown(_:)),
            input: UIKeyCommand.inputPageDown,
            modifierFlags: [.shift]
        )

        let scrollToTop = UIKeyCommand(
            title: String(localized: "Scroll to Top"),
            action: #selector(UIApplication.ghostty_scrollToTop(_:)),
            input: UIKeyCommand.inputHome,
            modifierFlags: [.shift]
        )

        let scrollToBottom = UIKeyCommand(
            title: String(localized: "Scroll to Bottom"),
            action: #selector(UIApplication.ghostty_scrollToBottom(_:)),
            input: UIKeyCommand.inputEnd,
            modifierFlags: [.shift]
        )

        let scrollGroup = UIMenu(title: "", options: .displayInline, children: [
            scrollPageUp, scrollPageDown, scrollToTop, scrollToBottom
        ])

        // Toggle Compose
        // ⇧⌘K, matching the toggle_compose default. This read ⇧⌘C, which both
        // misreported the shortcut and collided with the Edit menu's Clipboard
        // Manager, silently dropping the whole Terminal menu.
        let toggleCompose = UIKeyCommand(
            title: String(localized: "Toggle Compose"),
            action: #selector(UIApplication.ghostty_toggleCompose(_:)),
            input: "k",
            modifierFlags: [.command, .shift]
        )

        // Toggle Mouse Capture
        let toggleMouseCapture = UIKeyCommand(
            title: String(localized: "Toggle Mouse Capture"),
            action: #selector(UIApplication.ghostty_toggleMouseCapture(_:)),
            input: "M",
            modifierFlags: [.command, .shift]
        )

        let composeGroup = UIMenu(title: "", options: .displayInline, children: [
            toggleCompose, toggleMouseCapture
        ])

        // Cmd+Period never reaches responder UIKeyCommands or press events on
        // Catalyst — a menu key equivalent (like Xcode's ⌘. Stop item) is the
        // one rail that receives AND consumes the reserved chord. The handler
        // dispatches a cmd+period keybind first and falls back to sending
        // Escape.
        let sendEscape = UIKeyCommand(
            title: String(localized: "Send Escape"),
            action: #selector(UIApplication.ghostty_systemCancel(_:)),
            input: ".",
            modifierFlags: [.command]
        )

        let systemCancelGroup = UIMenu(title: "", options: .displayInline, children: [
            sendEscape
        ])

        let terminalMenu = UIMenu(
            title: String(localized: "Terminal"),
            identifier: UIMenu.Identifier("com.rootshell.terminal"),
            children: [splitCreateGroup, focusSplitGroup, splitManageGroup, scrollGroup, composeGroup, systemCancelGroup]
        )

        builder.insertSibling(terminalMenu, afterMenu: .view)
    }

    private func buildShellMenu(_ builder: UIMenuBuilder) {
        let browseHosts = UIKeyCommand(
            title: String(localized: "Browse Hosts"),
            action: #selector(UIApplication.ghostty_browseHosts(_:)),
            input: "b",
            modifierFlags: [.command]
        )

        let browseProfiles = UIKeyCommand(
            title: String(localized: "Browse Profiles"),
            action: #selector(UIApplication.ghostty_browseProfiles(_:)),
            input: "p",
            modifierFlags: [.command, .shift]
        )

        #if !CHINA_BUILD
        let aiAgent = UIKeyCommand(
            title: String(localized: "AI Agent"),
            action: #selector(UIApplication.ghostty_toggleAIAgent(_:)),
            input: "i",
            modifierFlags: .command
        )

        let voiceAgent = UIKeyCommand(
            title: String(localized: "Voice Agent"),
            action: #selector(UIApplication.ghostty_toggleVoiceAgent(_:)),
            input: "v",
            modifierFlags: [.command, .shift]
        )
        #endif

        let settings = UIKeyCommand(
            title: String(localized: "Settings..."),
            action: #selector(UIApplication.ghostty_openSettings(_:)),
            input: ",",
            modifierFlags: [.command]
        )

        #if !CHINA_BUILD
        let shellMenu = UIMenu(
            title: String(localized: "Shell"),
            identifier: UIMenu.Identifier("com.rootshell.shell"),
            children: [browseHosts, browseProfiles, aiAgent, voiceAgent, settings]
        )
        #else
        let shellMenu = UIMenu(
            title: String(localized: "Shell"),
            identifier: UIMenu.Identifier("com.rootshell.shell"),
            children: [browseHosts, browseProfiles, settings]
        )
        #endif

        builder.insertSibling(shellMenu, afterMenu: .view)
    }

    private func buildTabsMenu(_ builder: UIMenuBuilder) {
        let toggleTabSwitcher = UIKeyCommand(
            title: String(localized: "Toggle Vertical Tab Bar"),
            action: #selector(UIApplication.ghostty_toggleTabSwitcher(_:)),
            input: "\\",
            modifierFlags: [.command, .shift]
        )

        let previousTab = UIKeyCommand(
            title: String(localized: "Previous Tab"),
            action: #selector(UIApplication.ghostty_previousTab(_:)),
            input: "{",
            modifierFlags: [.command]
        )

        let nextTab = UIKeyCommand(
            title: String(localized: "Next Tab"),
            action: #selector(UIApplication.ghostty_nextTab(_:)),
            input: "}",
            modifierFlags: [.command]
        )

        let tmuxSessions = UIKeyCommand(
            title: String(localized: "tmux Sessions"),
            action: #selector(UIApplication.ghostty_showTmuxSessions(_:)),
            input: "s",
            modifierFlags: [.command, .shift]
        )

        let detachOtherClients = UIKeyCommand(
            title: String(localized: "Detach Other Clients"),
            action: #selector(UIApplication.ghostty_detachOtherClients(_:)),
            input: "x",
            modifierFlags: [.command, .shift]
        )

        let toggleTabExpose = UIKeyCommand(
            title: String(localized: "Tab Exposé"),
            action: #selector(UIApplication.ghostty_toggleTabExpose(_:)),
            input: "a",
            modifierFlags: [.command, .shift]
        )

        let previousGroup = UIKeyCommand(
            title: String(localized: "Previous Group"),
            action: #selector(UIApplication.ghostty_previousGroup(_:)),
            input: "[",
            modifierFlags: [.command, .alternate]
        )

        let nextGroup = UIKeyCommand(
            title: String(localized: "Next Group"),
            action: #selector(UIApplication.ghostty_nextGroup(_:)),
            input: "]",
            modifierFlags: [.command, .alternate]
        )

        let navGroup = UIMenu(title: "", options: .displayInline, children: [
            toggleTabSwitcher, toggleTabExpose, previousTab, nextTab, previousGroup, nextGroup, tmuxSessions, detachOtherClients
        ])

        // Tab selection (1-9), each with its own action (see ghostty_selectTabN).
        let tabSelectors: [Selector] = [
            #selector(UIApplication.ghostty_selectTab1(_:)),
            #selector(UIApplication.ghostty_selectTab2(_:)),
            #selector(UIApplication.ghostty_selectTab3(_:)),
            #selector(UIApplication.ghostty_selectTab4(_:)),
            #selector(UIApplication.ghostty_selectTab5(_:)),
            #selector(UIApplication.ghostty_selectTab6(_:)),
            #selector(UIApplication.ghostty_selectTab7(_:)),
            #selector(UIApplication.ghostty_selectTab8(_:)),
            #selector(UIApplication.ghostty_selectTab9(_:)),
        ]
        let tabCommands: [UIKeyCommand] = (1...9).map { index in
            UIKeyCommand(
                title: String(localized: "Tab \(index)"),
                action: tabSelectors[index - 1],
                input: String(index),
                modifierFlags: [.command]
            )
        }

        let tabSelectGroup = UIMenu(title: "", options: .displayInline, children: tabCommands)

        let tabsMenu = UIMenu(
            title: String(localized: "Tabs"),
            identifier: UIMenu.Identifier("com.rootshell.tabs"),
            children: [navGroup, tabSelectGroup]
        )

        builder.insertSibling(tabsMenu, afterMenu: .view)
        // insertSibling reports nothing, and UIKit drops a whole menu whose key
        // equivalent a system menu owns. Without this the loss is invisible.
        if builder.menu(for: UIMenu.Identifier("com.rootshell.tabs")) == nil {
            logger.error("Tabs menu was rejected; check for a system key-equivalent conflict")
        }
    }

    // MARK: - About Dialog

    @objc private func showAbout(_ sender: Any?) {
        // Build credits as an attributed string
        let credits = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 8

        // Use NSColor for AppKit About panel (UIColor doesn't translate correctly)
        guard let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type,
              let secondaryLabelColor = nsColorClass.value(forKey: "secondaryLabelColor") else {
            return
        }

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .link: URL(string: "https://www.rootshell.com")!,
            .paragraphStyle: paragraphStyle
        ]

        credits.append(NSAttributedString(string: "By Kit Knox\n", attributes: normalAttributes))
        credits.append(NSAttributedString(string: "www.rootshell.com\n\n", attributes: linkAttributes))
        credits.append(NSAttributedString(string: "Terminal emulator based on libghostty\nby Mitchell Hashimoto", attributes: normalAttributes))

        // Use dynamic Objective-C runtime to access NSApplication (not directly available in Catalyst)
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type else { return }
        guard let nsApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        var options: [String: Any] = [
            "Credits": credits,
            "ApplicationName": "Rootshell",
            "ApplicationVersion": "\(version) (\(BuildInfo.date))"
        ]
        if let applicationIcon = AppIconManager.shared.makeMacCatalystAboutPanelIcon() {
            options["ApplicationIcon"] = applicationIcon
        }

        nsApp.perform(NSSelectorFromString("orderFrontStandardAboutPanelWithOptions:"), with: options)
    }

    // MARK: - Close and Quit Handling

    @objc private func handleClose(_ sender: Any?) {
        logger.info("CatalystAppDelegate.handleClose called")
        // Route to responder chain - TerminalView.closeSplit will handle it
        let handled = UIApplication.shared.sendAction(
            #selector(Ghostty.TerminalView.closeSplit(_:)),
            to: nil,
            from: sender,
            for: nil
        )
        logger.info("CatalystAppDelegate.handleClose: sendAction returned \(handled)")
    }

    @objc private func handleQuit(_ sender: Any?) {
        logger.info("handleQuit called")

        // Check if there are open tabs
        let hasOpenTabs = SessionTracker.shared.hasOpenTabs
        let tabCount = SessionTracker.shared.totalTabCount

        guard hasOpenTabs else {
            logger.info("No open tabs, quitting immediately")
            performQuit()
            return
        }

        logger.info("Open tabs detected (\(tabCount)), showing confirmation")
        showQuitConfirmation(tabCount: tabCount)
    }

    private func showQuitConfirmation(tabCount: Int) {
        // Find active window scene for presenting alert
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.warning("Could not find window to present quit confirmation, quitting anyway")
            performQuit()
            return
        }

        let message = tabCount == 1
            ? "You have 1 open terminal. Are you sure you want to quit?"
            : "You have \(tabCount) open terminals. Are you sure you want to quit?"

        let alert = UIAlertController(
            title: "Quit Rootshell?",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in
            self?.performQuit()
        })

        // Find the topmost presented controller to avoid presentation conflicts
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(alert, animated: true)
    }

    private func performQuit() {
        logger.info("Performing quit")

        // Stop helper process first
        HelperConnection.shared.stopHelper()

        // Request destruction of all scene sessions first
        for session in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).map({ $0.session }) {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        // Use NSRunningApplication.current.terminate() for clean app termination
        // This properly goes through the app lifecycle unlike NSApplication.terminate
        // which doesn't always work correctly in Mac Catalyst
        guard let nsRunningAppClass = NSClassFromString("NSRunningApplication") as? NSObject.Type,
              let currentApp = nsRunningAppClass.value(forKey: "currentApplication") as? NSObject else {
            logger.error("Could not access NSRunningApplication to quit")
            return
        }

        currentApp.perform(NSSelectorFromString("terminate"))
    }

}

// MARK: - Scene Delegate

/// Scene delegate for Catalyst windows. New (Cmd-N) windows are sized to the
/// last-focused window via `applyNewWindowCascadeGeometry`; launch-restored
/// windows are sized per-window from their saved frame in `MainView` and skip
/// the global path (see the `hasPendingRestoration` gate in `willConnectTo`).
class CatalystSceneDelegate: UIResponder, UIWindowSceneDelegate {

    static let minWindowSize = CGSize(width: 400, height: 300)

    /// True once any scene has become active — i.e. launch scene restoration
    /// is behind us. Distinguishes a cold-launch visor zombie (SwiftUI will
    /// still create the main scene on its own) from a Dock-click reopen that
    /// landed on the visor's session (nothing else will open a window).
    private static var hasActivatedAnyScene = false

    /// A Dock-click reopen with no visible windows can be consumed by the
    /// visor's live-but-hidden scene session: UIKit either reconnects it
    /// (the zombie backstop destroys it) or just activates it (the hidden
    /// window never shows). Either way the user sees nothing open. When
    /// that happens with no regular scene connected, open a main window —
    /// the same nil-session activation Cmd-N uses.
    static func openMainWindowIfNoneConnected() {
        let hasRegularScene = UIApplication.shared.connectedScenes.contains {
            $0 is UIWindowScene && !isVisorScene($0)
        }
        guard !hasRegularScene else { return }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Diagnostic: log the fields we use to detect the visor so we can
        // see what SwiftUI actually puts there if our match fails.
        let configName = session.configuration.name ?? "<nil>"
        let sceneActivityType = scene.userActivity?.activityType ?? "<nil>"
        let sceneActivityTitle = scene.userActivity?.title ?? "<nil>"
        let optionActivityType = connectionOptions.userActivities.first?.activityType ?? "<nil>"
        let optionActivityTitle = connectionOptions.userActivities.first?.title ?? "<nil>"
        logger.info("Scene willConnectTo — configName=\"\(configName)\", sceneActivityType=\"\(sceneActivityType)\", sceneActivityTitle=\"\(sceneActivityTitle)\", optionActivityType=\"\(optionActivityType)\", optionActivityTitle=\"\(optionActivityTitle)\"")

        #if STANDALONE
        // Launch backstop: once the visor has been summoned in a prior run,
        // the OS restores its UISceneSession at every launch. That restored
        // window is briefly an ordinary titled window and can steal key
        // status (dead Return key) or flash a small white window before our
        // deferred configure() can hide it. Rather than reactively recover
        // from that bad state, destroy the restored zombie outright — the
        // next summon's ensurePanel() recreates a fresh scene (the reliable
        // first-summon path). A live summon sets summonInFlight first, so we
        // only ever destroy a scene the OS restored on its own.
        let isPersistedVisorId = session.persistentIdentifier == VisorSceneLifecycle.persistedSceneId
        if (isPersistedVisorId || Self.isVisorScene(scene, connectionOptions: connectionOptions))
            && !VisorSceneLifecycle.summonInFlight {
            logger.info("Destroying restored zombie visor scene (no summon in flight)")
            // Mark the doomed session as the visor's so isVisorScene keeps
            // excluding it while the deferred destruction is pending (it may
            // have been recognized only via the persisted id).
            VisorSceneRegistry.shared.register(session: session)
            // Best-effort, ordering-neutral flash suppression before teardown.
            Self.suppressConnectingVisorWindow(for: windowScene)
            // Defer destruction: requesting it synchronously inside the scene's
            // own connection callback is reentrant and behaves inconsistently
            // on Catalyst. One runloop turn is harmless — we abandon the scene.
            // Past launch, this connection was UIKit's answer to a Dock-click
            // reopen — destroying it consumes the reopen, so make sure a main
            // window still appears. At cold launch SwiftUI creates the main
            // scene itself, so the fallback must not run there.
            let doomed = session
            let isPostLaunchReopen = Self.hasActivatedAnyScene
            DispatchQueue.main.async {
                UIApplication.shared.requestSceneSessionDestruction(doomed, options: nil)
                if isPostLaunchReopen {
                    Self.openMainWindowIfNoneConnected()
                }
            }
            return
        }
        #endif

        if Self.isVisorScene(scene, connectionOptions: connectionOptions) {
            // Visor manages its own geometry via VisorController.animateIn.
            // Just register the session so save/restore callbacks skip it;
            // DO NOT call requestGeometryUpdate here — that pins the
            // scene's geometry preference and Catalyst will fight any
            // subsequent NSWindow.setFrame call from animateIn, leaving
            // the visor stuck at whatever size we requested.
            #if STANDALONE
            VisorSceneRegistry.shared.register(session: session)
            #endif
        } else {
            windowScene.sizeRestrictions?.minimumSize = Self.minWindowSize
            // Restore-phase signal, made authoritative at this point by the eager
            // `ensureStateLoaded()` in `didFinishLaunchingWithOptions`. Use the
            // REGULAR-window signal (not `hasPendingRestoration`): the saved state
            // always carries a `visor` entry that is claimed only when the visor is
            // summoned (never on App Store builds), so `hasPendingRestoration` stays
            // true for the whole session and would make every runtime new window
            // skip the last-focused cascade sizing below.
            let restoring = WindowStateManager.shared.hasPendingRegularWindowRestoration
            if restoring {
                // Pre-size the restored window to its saved frame NOW, before it
                // is first displayed, so it is BORN at the right size instead of
                // appearing at a default and then visibly resizing. Frames are
                // consumed in saved-file order; MainView re-confirms per-window
                // once its scene links (and does the blank-window nudge),
                // correcting the rare connect-order≠appear-order case. The single
                // global last-focused frame is NOT applied here (it would make
                // every restored window the same size).
                if let frame = WindowStateManager.shared.nextPendingRestoreFrame() {
                    let prefs = UIWindowScene.GeometryPreferences.Mac(systemFrame: frame)
                    windowScene.requestGeometryUpdate(prefs) { error in
                        logger.warning("Pre-size of restored window failed: \(error.localizedDescription)")
                    }
                    logger.info("Pre-sized restored window: \(Int(frame.width))x\(Int(frame.height))")
                }
            } else {
                applyNewWindowCascadeGeometry(to: windowScene)
            }
        }

        // Handle URLs that launched the app (cold start)
        handleURLContexts(connectionOptions.urlContexts)
    }

    /// Detect the visor's UIScene. SwiftUI's `session.configuration.name`
    /// is undocumented for WindowGroups, so we probe several candidate
    /// sources. The VisorSceneRegistry layered detection covers cases
    /// where the SwiftUI-side fields don't expose the WindowGroup id at all.
    static func isVisorScene(_ scene: UIScene, connectionOptions: UIScene.ConnectionOptions? = nil) -> Bool {
        #if STANDALONE
        if VisorSceneRegistry.shared.isVisor(session: scene.session) { return true }
        #endif
        if let name = scene.session.configuration.name,
           name.localizedCaseInsensitiveContains("visor") {
            return true
        }
        if let activity = scene.userActivity, Self.isVisorActivity(activity) {
            return true
        }
        if let connectionOptions,
           connectionOptions.userActivities.contains(where: { Self.isVisorActivity($0) }) {
            return true
        }
        return false
    }

    private static func isVisorActivity(_ activity: NSUserActivity) -> Bool {
        if activity.activityType.localizedCaseInsensitiveContains("visor") { return true }
        if let title = activity.title, title.localizedCaseInsensitiveContains("visor") {
            return true
        }
        if let target = activity.targetContentIdentifier,
           target.localizedCaseInsensitiveContains("visor") {
            return true
        }
        return false
    }

    #if STANDALONE
    /// Slam the connecting (doomed) visor window's alpha to 0 so the OS can't
    /// composite a white frame in the runloop turn before its destruction
    /// lands. Alpha-only is pure NSWindow state — it does not touch ordering
    /// or styleMask, so it never deactivates the scene (the documented
    /// landmine for the hidden visor window during bring-up). Best-effort: if
    /// the window isn't claimable yet this is a no-op and the deferred
    /// destruction still fires within one runloop.
    private static func suppressConnectingVisorWindow(for windowScene: UIWindowScene) {
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        let sessionId = windowScene.session.persistentIdentifier
        for window in windows where WindowAccessor.sceneSessionId(for: window) == sessionId {
            window.setValue(NSNumber(value: 0.0), forKey: "alphaValue")
        }
    }
    #endif

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // Handle URLs opened while app is running
        handleURLContexts(URLContexts)
    }

    private func handleURLContexts(_ urlContexts: Set<UIOpenURLContext>) {
        for context in urlContexts {
            let url = context.url
            logger.info("Received URL: \(url.absoluteString)")

            // Handle SSH URLs
            if let components = SSHURLParser.parse(url) {
                logger.info("Parsed SSH URL: \(components.displayString)")
                AppIntentCoordinator.shared.deposit(.openSSH(components))
            }
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let isFirstActivation = !Self.hasActivatedAnyScene
        Self.hasActivatedAnyScene = true

        if Self.isVisorScene(scene) {
            #if STANDALONE
            // A Dock-click reopen can activate the hidden visor's live scene
            // instead of creating a main window, leaving nothing on screen.
            // Not during a summon (summonInFlight / visorShouldBeKey) and not
            // while the visor is showing — then it's a genuine stranded
            // reopen, so open a main window.
            if !isFirstActivation,
               !VisorSceneLifecycle.summonInFlight,
               !VisorWindowKeyOverride.visorShouldBeKey,
               !VisorController.shared.isVisible {
                Self.openMainWindowIfNoneConnected()
            }
            #endif
            return
        }

        saveWindowGeometry(windowScene)
        // Reopened-window recovery (#279): let this scene's WindowAccessor
        // re-validate its claimed NSWindow now that the window is on screen,
        // and re-assert blur (per-NSWindow state, idempotent on both paths).
        NotificationCenter.default.post(name: .catalystSceneDidActivate, object: windowScene)
        Ghostty.App.shared?.applyWindowBlur()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene,
              !Self.isVisorScene(scene) else { return }
        // Capture geometry before the window loses focus (e.g. user moved it then switched apps).
        // Catalyst does not fire didUpdate on simple window moves, so this is the main hook
        // for catching origin changes during the app session.
        saveWindowGeometry(windowScene)
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace, interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation, traitCollection previousTraitCollection: UITraitCollection) {
        // Persist size/position changes for the active window. Initial geometry is set
        // up front in scene(_:willConnectTo:); didUpdate only handles ongoing changes.
        if Self.isVisorScene(windowScene) { return }
        if windowScene.activationState == .foregroundActive {
            saveWindowGeometry(windowScene)
        }
    }

    /// Size a genuinely new (Cmd-N) window to the last-focused window's geometry,
    /// cascading the origin when another window already exists. Restored windows
    /// do NOT come through here — they are sized by their own per-window saved
    /// frame in `MainView` (see the `hasPendingRestoration` gate in
    /// `scene(_:willConnectTo:)`). `WindowSizeManager` is the single store backing
    /// this "next new window" default.
    private func applyNewWindowCascadeGeometry(to windowScene: UIWindowScene) {
        let stored = WindowSizeManager.shared.frameForNewWindow()
        let currentFrame = windowScene.effectiveGeometry.systemFrame

        // For windows opened while the app is already running (additional scenes),
        // skip origin restore so they cascade rather than stack on the existing
        // window. The visor's scene must not count: it is invisible (or a
        // floating overlay), and treating it as "another window" made a
        // Dock-click reopen after a visor toggle lose the stored origin.
        let hasOtherWindow = UIApplication.shared.connectedScenes.contains { other in
            other !== windowScene && other is UIWindowScene && !Self.isVisorScene(other)
        }

        let origin: CGPoint
        if let storedOrigin = stored.origin, !hasOtherWindow,
           let visibleOrigin = clampToVisibleScreen(origin: storedOrigin, size: stored.size, scene: windowScene) {
            origin = visibleOrigin
        } else {
            origin = currentFrame.origin
        }

        let newFrame = CGRect(origin: origin, size: stored.size)

        // Skip if it already matches what's on screen.
        if newFrame.equalTo(currentFrame) { return }

        logger.info("New window cascade geometry: \(newFrame.width)x\(newFrame.height) at (\(newFrame.origin.x), \(newFrame.origin.y))")
        let preferences = UIWindowScene.GeometryPreferences.Mac(systemFrame: newFrame)
        windowScene.requestGeometryUpdate(preferences) { error in
            logger.warning("requestGeometryUpdate error: \(error.localizedDescription)")
        }
    }

    /// Returns an origin that keeps the window mostly on a visible screen, or nil if no
    /// screen contains a meaningful portion of the proposed frame (e.g. a saved position
    /// from a now-disconnected display).
    private func clampToVisibleScreen(origin: CGPoint, size: CGSize, scene: UIWindowScene) -> CGPoint? {
        let proposed = CGRect(origin: origin, size: size)
        let screenBounds = scene.screen.bounds
        let intersection = proposed.intersection(screenBounds)
        let proposedArea = proposed.width * proposed.height
        guard proposedArea > 0 else { return nil }
        let coverage = (intersection.width * intersection.height) / proposedArea
        return coverage >= 0.5 ? origin : nil
    }

    private func saveWindowGeometry(_ windowScene: UIWindowScene) {
        let frame = windowScene.effectiveGeometry.systemFrame
        guard frame.size.width >= Self.minWindowSize.width,
              frame.size.height >= Self.minWindowSize.height else { return }

        WindowSizeManager.shared.updateWindowFrame(frame)
    }
}

#endif
