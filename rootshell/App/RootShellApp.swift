//
//  RootShellApp.swift
//  rootshell
//
//  Created by Kit Knox / Rootshell LLC on 11/16/25.
//

import SwiftUI
import Combine
import GhosttyKit

#if canImport(UIKit)
import UIKit
#endif

@main
struct RootShellApp: App {
    @StateObject private var ghosttyApp = Ghostty.App()
    // `locationManager` and `notificationManager` are intentionally NOT
    // @StateObject. The App body never reads any of their properties, so
    // holding them as observable would invalidate the App's scene list on
    // every internal @Published mutation. LocationDiaryManager publishes
    // `entries` and `currentLocation` per CoreLocation update — including
    // while the app is backgrounded — which fires
    // `AppSceneDelegate.scenesDidChange` and rebuilds the entire scene tree
    // (root cause of the 0x8BADF00D scene-update watchdog kill seen in the
    // 18:28:55 crash, stack `assignWithCopy for WindowSceneList`). The
    // singletons are kept alive by their `.shared` static, so we just need
    // a non-observing reference.
    @StateObject private var appearanceManager = AppearanceManager.shared
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    @State private var liveActivityManager = LiveActivityManager.shared
    #endif

    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @Setting(Settings.Window.fullScreenMode) private var fullScreenModeEnabled
    #endif

    #if targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(CatalystAppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    /// Guards the app-level startup work in the WindowGroup `.task` so it runs
    /// ONCE per launch, not per window. SwiftUI runs that `.task` for every
    /// window; re-running CloudKit sync / MCP start / tunnel start / cache
    /// refreshes on each new window saturated the MainActor during window
    /// open, which is a major reason new windows felt slow.
    @MainActor private static var didRunAppStartupTasks = false

    init() {
        let appInit = LaunchSignposts.begin("launch.appInit")
        defer { LaunchSignposts.end("launch.appInit", appInit) }

        // AppIconManager is instantiated OUTSIDE the ProtectedDataGuard because
        // on Mac Catalyst the dock icon is a runtime-only assignment that must
        // be reapplied every launch. Its internal UserDefaults reads are
        // harmless when protected data isn't available yet (they just return
        // the default variant). Needs to touch an instance property so Swift
        // doesn't fold the `_ =` access away.
        _ = AppIconManager.shared.selectedVariant

        // Guard against background launches before device unlock.
        // These singletons read UserDefaults in init() and have didSet observers
        // that write values back — if defaults are empty (encrypted), they overwrite
        // the real settings with zeros/nils.
        guard ProtectedDataGuard.isAvailable else { return }

        // Initialize FontManager early to register the selected font
        // before Ghostty surfaces try to use it (full catalog loads on a worker)
        _ = FontManager.shared

        // Initialize RemoteSessionTracker early to ensure notification observer
        // is set up before any MainView instances post notifications
        _ = RemoteSessionTracker.shared

        // Initialize LiveActivityManager early for session tracking
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        _ = LiveActivityManager.shared
        #endif

        // Initialize DayNightThemeManager early so it can apply the correct
        // theme on launch and begin observing system appearance changes
        _ = DayNightThemeManager.shared

        // Notification categories and LocationDiaryManager are started from the
        // once-per-launch WindowGroup `.task` — they are not needed before first paint.
    }

    var body: some Scene {
        WindowGroup(id: "main-terminal") {
            DuoSceneHost { MainView() }
                .overlay { MCPApprovalOverlay() }
                .environmentObject(ghosttyApp)
                .preferredColorScheme(appearanceManager.colorScheme)
                .modifier(ScrollEdgeEffectModifier())
                .statusBarStyleForTerminalTheme()
                .immersiveChromeForFullScreen()
                .fullScreenLaunchNotice()
                .alwaysOnDisplay()
                .task {
                    guard ProtectedDataGuard.isAvailable else { return }

                    // App-level startup work: run ONCE per launch, not on every
                    // window. SwiftUI runs this `.task` per window; re-running
                    // the heavy items below (CloudKit sync, MCP start, tunnel
                    // start) on each new window saturated the MainActor during
                    // window open and made new windows slow.
                    guard !Self.didRunAppStartupTasks else { return }
                    Self.didRunAppStartupTasks = true
                    LaunchSignposts.event("app.startupTask.begin")

                    // Bring back the VPN a reboot or app update took down, early
                    // so restored sessions can reach hosts behind it.
                    #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
                    Task { await VPNManager.shared.recoverLastVPNIfNeeded() }
                    #endif

                    // Tailscale inside rootshell (no VPN), when it was left on.
                    #if !CHINA_BUILD
                    TailnetInAppEngine.shared.appDidLaunch()
                    #endif

                    // Register notification categories (deferred from App.init —
                    // not required before first paint).
                    NotificationManager.shared.registerNotificationCategories()

                    // Force-instantiate LocationDiaryManager once the first window
                    // exists. Kept out of App.init / @StateObject so its per-update
                    // @Published mutations can't invalidate the App scene list.
                    // macOS has no location-diary feature.
                    #if !targetEnvironment(macCatalyst)
                    _ = LocationDiaryManager.shared
                    #endif

                    // Re-check day/night theme now that the window exists and
                    // Ghostty.App is subscribed to themeDidChange. The initial
                    // check in DayNightThemeManager.init() runs before any
                    // window is available, so it can't detect dark mode.
                    DayNightThemeManager.shared.recheckAppearance()

                    // Restore bookmarked external folder access and symlinks
                    #if !targetEnvironment(macCatalyst)
                    BookmarkedLocationsManager.shared.syncOnLaunch()
                    #endif

                    // Note: YubiKey connections are now on-demand with yubikit-swift SDK
                    // No need to start listeners - connections are created when needed

                    #if targetEnvironment(macCatalyst) && STANDALONE
                    // The first shell may immediately use SSH_AUTH_SOCK.
                    LocalSSHAgentManager.shared.startIfEnabled()
                    #endif

                    // SwiftUI's window task runs before the terminal is ready.
                    // Keep appearance, bookmarks, and notification categories above
                    // immediate, but let session creation precede cache/network
                    // maintenance on every platform. The gate has a one-second
                    // fallback for launches without a successful terminal session.
                    await LaunchMaintenanceGate.shared.wait()

                    // Check current authorization status without requesting
                    await NotificationManager.shared.updateAuthorizationStatus()
                    // Log diagnostic info
                    NotificationManager.shared.logDiagnostics()

                    // Refresh cloud provider cache if stale (> 1 hour)
                    CloudCacheManager.shared.refreshIfStale()

                    // Refresh WiFi AP cache if stale (> 1 hour)
                    #if !targetEnvironment(macCatalyst)
                    WiFiAPCacheManager.shared.refreshIfStale()
                    #endif

                    // Sync CloudKit data on launch (connection history, known hosts)
                    if CloudKitSyncManager.shared.isSyncEnabled {
                        try? await CloudKitSyncManager.shared.syncNow()
                    }

                    // Auto-start MCP server if it was enabled
                    if MCPServer.shared.config.isEnabled && !MCPServer.shared.isRunning {
                        _ = try? await MCPServer.shared.start()
                    }

                    // Auto-start enabled background tunnels
                    await BackgroundTunnelManager.shared.startEnabledTunnels()
                    LaunchSignposts.event("app.startupTask.end")
                }
                .onOpenURL { url in
                    // Handle rootshell://vpn/connect/<profileID>
                    if url.scheme == "rootshell" && url.host == "vpn",
                       url.pathComponents.count >= 2 && url.pathComponents[1] == "connect",
                       url.pathComponents.count >= 3,
                       let profileID = UUID(uuidString: url.pathComponents[2]) {
                        #if !CHINA_BUILD
                        // Always navigate to the VPN view so the user sees connection status
                        NotificationCenter.default.post(name: .vpnIntentReceived, object: nil)
                        Task {
                            await VPNManager.shared.handleWidgetConnectRequest(profileID: profileID)
                        }
                        #else
                        _ = profileID
                        #endif
                    }
                    // Handle rootshell://vpn/settings
                    else if url.scheme == "rootshell" && url.host == "vpn" {
                        #if !CHINA_BUILD
                        NotificationCenter.default.post(name: .vpnIntentReceived, object: nil)
                        #endif
                    }
                    // Handle ssh:// and ssh: URLs
                    else if let components = SSHURLParser.parse(url) {
                        AppIntentCoordinator.shared.depositURLRequest(
                            .openSSH(components), source: "app.onOpenURL")
                    }
                    // Handle mosh:// and mosh: URLs
                    else if let components = MoshURLParser.parse(url) {
                        AppIntentCoordinator.shared.depositURLRequest(
                            .openMosh(components), source: "app.onOpenURL")
                    }
                }
                .onContinueUserActivity(TrzszTransferActivity.activityType) { activity in
                    // A nearby device tapped our Handoff offer, OR another
                    // device's offer is being delivered to us. Either way,
                    // try to materialize a receiver-side Offer; if the
                    // userInfo doesn't validate, ignore silently.
                    guard let offer = TrzszTransferReceiver.Offer(activity: activity) else {
                        return
                    }
                    NotificationCenter.default.post(
                        name: .trzszTransferOfferReceived,
                        object: offer
                    )
                }
                #if !targetEnvironment(macCatalyst)
                // iOS: use UIKit activation notifications for app activation sync.
                // Keeping this out of SwiftUI scenePhase avoids subscribing the
                // root app scene graph to foreground environment updates.
                // Mac Catalyst uses NSWorkspace notifications instead - see CatalystAppDelegate.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    PushNotificationRouter.syncDelivered()
                    WedgeBreadcrumbLogger.shared.critical("App.didBecomeActive")
                    ForegroundWedgeWatchdog.shared.noteMainActorServiced("App.didBecomeActive")
                    LifecycleDebugLogger.shared.checkpoint("App.didBecomeActive")

                    // Save a snapshot of sentinel UserDefaults keys while data is available.
                    // Used to detect and recover from corruption caused by background launches.
                    DispatchQueue.global(qos: .utility).async {
                        UserDefaultsBackup.saveSnapshot()
                    }

                    // Capture the lifecycle background epoch at activation
                    // observe time. Every deferred closure below re-reads the
                    // live value at fire time and aborts if a
                    // `handleAppBackgrounded` ran in between — same race that
                    // motivated the FG.body guards in MainViewLifecycle.
                    // Crash log 14:33:09 shows App.liveActivity.scheduleAt200ms
                    // firing 44ms before BG.atomic.set, then App.vpnRefresh /
                    // App.cloudKit completing while backgrounded.
                    let scheduledAtBgEpoch = LifecycleEpoch.shared.background

                    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
                    // Keep ActivityKit reconciliation out of the 150ms
                    // foreground quiet window used by Ghostty resume.
                    LifecycleDebugLogger.shared.checkpoint("App.liveActivity.scheduleAt200ms")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let currentBgEpoch = LifecycleEpoch.shared.background
                        guard currentBgEpoch == scheduledAtBgEpoch else {
                            LifecycleDebugLogger.shared.checkpoint("App.liveActivity.skipped", ms: nil, [
                                ("reason", "backgroundedDuringDefer"),
                                ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                                ("currentBgEpoch", currentBgEpoch),
                            ])
                            return
                        }
                        ForegroundActivationGate.shared.runWhenSafe(reason: "app.liveActivity") {
                            LiveActivityManager.shared.reconcileAfterActivation()
                        }
                    }
                    #endif

                    Task { @MainActor in
                        let currentBgEpoch = LifecycleEpoch.shared.background
                        guard currentBgEpoch == scheduledAtBgEpoch else {
                            LifecycleDebugLogger.shared.checkpoint("App.deferred.skipped", ms: nil, [
                                ("reason", "backgroundedDuringDefer"),
                                ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                                ("currentBgEpoch", currentBgEpoch),
                            ])
                            return
                        }
                        #if !CHINA_BUILD
                        let vpnStart = CFAbsoluteTimeGetCurrent()
                        // Pass the epoch closure so VPNManager aborts its
                        // mutation cascade if a backgrounding lands during
                        // the NETunnelProviderManager XPC roundtrip.
                        await VPNManager.shared.refreshStatusFromSystem(shouldApply: {
                            LifecycleEpoch.shared.background == scheduledAtBgEpoch
                        })
                        LifecycleDebugLogger.shared.checkpoint("App.vpnRefresh.complete",
                            ms: (CFAbsoluteTimeGetCurrent() - vpnStart) * 1000)

                        // Re-check after the await: even if VPN's internal
                        // guard already aborted, we should not enter
                        // CloudKit sync against a backgrounded scene.
                        let postVpnEpoch = LifecycleEpoch.shared.background
                        guard postVpnEpoch == scheduledAtBgEpoch else {
                            LifecycleDebugLogger.shared.checkpoint("App.cloudKit.skipped", ms: nil, [
                                ("reason", "backgroundedDuringVpnRefresh"),
                                ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                                ("currentBgEpoch", postVpnEpoch),
                            ])
                            return
                        }
                        #endif
                        if CloudKitSyncManager.shared.isSyncEnabled {
                            let ckStart = CFAbsoluteTimeGetCurrent()
                            try? await CloudKitSyncManager.shared.syncNow()
                            // Re-check after the sync await — sync can span
                            // seconds; a backgrounding mid-sync means the
                            // `App.cloudKit.complete` we'd log is misleading.
                            let postCkEpoch = LifecycleEpoch.shared.background
                            if postCkEpoch == scheduledAtBgEpoch {
                                LifecycleDebugLogger.shared.checkpoint("App.cloudKit.complete",
                                    ms: (CFAbsoluteTimeGetCurrent() - ckStart) * 1000)
                            } else {
                                LifecycleDebugLogger.shared.checkpoint("App.cloudKit.skipped", ms: nil, [
                                    ("reason", "backgroundedDuringSync"),
                                    ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                                    ("currentBgEpoch", postCkEpoch),
                                    ("syncMs", String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - ckStart) * 1000)),
                                ])
                            }
                        }
                    }
                }
                #endif
        }
        .commands {
            AppCommands()
        }
        .handlesExternalEvents(matching: ["ssh", "mosh", "rootshell", "file://"])

        #if STANDALONE && targetEnvironment(macCatalyst)
        // Keep the visor scene after the main terminal scene. Catalyst can
        // select the first WindowGroup as the default launch scene, and the
        // visor intentionally starts hidden until explicitly summoned.
        WindowGroup(id: "visor") {
            VisorContentView()
                .environmentObject(ghosttyApp)
                .onContinueUserActivity("com.rootshell.visor") { _ in }
        }
        .handlesExternalEvents(matching: ["visor-terminal"])
        #endif

        #if !CHINA_BUILD
        // AI Agent dedicated window (iPad and Mac Catalyst)
        // This window displays AI agent sessions in a separate window
        // when presentation mode is set to .window
        // Uses UIViewController wrapper for proper keyboard shortcut handling
        WindowGroup(id: "ai-agent") {
            AIAgentWindowControllerRepresentable()
                .preferredColorScheme(appearanceManager.colorScheme)
                .ignoresSafeArea()
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 500, height: 700)
        #endif
        .windowResizability(.contentSize)
        #endif

    }
}
