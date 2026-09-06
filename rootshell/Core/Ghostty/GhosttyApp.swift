//
//  GhosttyApp.swift
//  rootshell
//
//  Wrapper around ghostty_app_t for iOS
//

import Foundation
import SwiftUI
import Combine
import os
import UniformTypeIdentifiers
import GhosttyKit

/// Preview renderers live outside the tab split trees swept by MainView.
/// Keep their lifecycle synchronous with the secure-draw latch, including
/// protected-data/background launches that have no active → inactive edge.
@MainActor
protocol PreviewRenderingParticipant: AnyObject {
    func suspendPreviewRendering()
    func dismissPreviewForBackground()
    func preparePreviewForActivation()
    func resumePreviewRendering()
}

extension PreviewRenderingParticipant {
    func dismissPreviewForBackground() {}
    func preparePreviewForActivation() {}
}

@MainActor
enum PreviewRenderingLifecycle {
    private struct Entry {
        weak var participant: (any PreviewRenderingParticipant)?
    }
    private static var entries: [Entry] = []
    private static var resumeGeneration: UInt64 = 0

    static func register(_ participant: any PreviewRenderingParticipant) {
        entries.removeAll { $0.participant == nil }
        entries.append(Entry(participant: participant))
    }

    private static var participants: [any PreviewRenderingParticipant] {
        entries.compactMap(\.participant)
    }

    static func suspend() {
        #if !targetEnvironment(macCatalyst)
        resumeGeneration &+= 1
        Ghostty.isSecureDrawProhibitedAtomic = true
        for participant in participants { participant.suspendPreviewRendering() }
        #endif
    }

    static func didEnterBackground() {
        #if !targetEnvironment(macCatalyst)
        suspend()
        for participant in participants { participant.dismissPreviewForBackground() }
        #endif
    }

    static func scheduleResumeAfterActivation() {
        #if !targetEnvironment(macCatalyst)
        resumeGeneration &+= 1
        let generation = resumeGeneration
        // Like MainView's renderer resume, let the FrontBoard activation
        // transaction commit before changing responders, layout, or Metal state.
        DispatchQueue.main.async {
            // An inactive/background/active rebound supersedes this request,
            // even if the latch is clear again by the time this closure runs.
            guard canResume(generation: generation) else { return }
            // Remove dismissed previews before any retained GPU surface resumes.
            for participant in participants {
                guard canResume(generation: generation) else { return }
                participant.preparePreviewForActivation()
            }
            for participant in participants {
                guard canResume(generation: generation) else { return }
                participant.resumePreviewRendering()
            }
        }
        #endif
    }

    private static func canResume(generation: UInt64) -> Bool {
        generation == resumeGeneration && !Ghostty.isSecureDrawProhibitedAtomic
            && UIApplication.shared.applicationState == .active
    }
}

protocol GhosttyAppDelegate: AnyObject {
    /// Called when a surface should be closed
    func closeSurface(uuid: UUID, processAlive: Bool)
}

protocol GhosttyActionDelegate: AnyObject {
    /// Called after terminal content changes for this exact surface.
    func handleSurfaceContentChanged()

    /// Called when the terminal title changes
    func handleTitleChange(_ title: String)

    /// Called when the current working directory changes
    func handlePwdChange(_ pwd: String)

    /// Called when a bell/beep is requested
    func handleBell()

    /// Called when terminal cell size changes
    func handleCellSizeChange(width: CGFloat, height: CGFloat)

    /// Called when renderer health status changes
    func handleRendererHealth(healthy: Bool)

    /// Called when mouse shape changes
    func handleMouseShape(shape: Int)

    /// Called when mouse visibility changes (hide-while-typing)
    func handleMouseVisibility(visible: Bool)

    /// Called when desktop notification is requested
    func handleDesktopNotification(title: String?, body: String?)

    /// Called when scrollbar state changes
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64)

    /// Called when progress report is requested
    func handleProgressReport(_ report: Ghostty.Action.ProgressReport)

    /// Called when a shell command finishes (OSC 133 shell integration).
    /// exitCode is nil when the shell reported none; duration is wall time.
    func handleCommandFinished(exitCode: Int?, duration: TimeInterval)

    /// Called when search should start
    func handleStartSearch(_ startSearch: Ghostty.Action.StartSearch)

    /// Called when search should end
    func handleEndSearch()

    /// Called when total search match count changes
    func handleSearchTotal(_ total: UInt?)

    /// Called when selected search match changes
    func handleSearchSelected(_ selected: UInt?)

    /// Called synchronously when mouse hovers over a link. URL is nil when leaving a link.
    func handleMouseOverLink(url: String?)
}

extension Ghostty {
    /// True while the host app is fully backgrounded (not `.active`, not
    /// `.inactive`).
    ///
    /// Used as a central gate for `@Published` / `@Observable` mutations on the
    /// main actor. Under background QoS, main-thread work takes many times
    /// longer than foreground, so per-output / per-tick scene updates pile up
    /// fast enough to trip the 30 s scene-update watchdog (0x8BADF00D). While
    /// backgrounded, callers should cache new values in non-observed storage
    /// and skip the `@Published` write; a foreground replay path pushes the
    /// cached values through when visibility returns.
    @MainActor
    static var isAppBackgrounded: Bool {
        UIApplication.shared.applicationState == .background
    }

    /// Thread-safe mirror of `isAppBackgrounded` readable from non-main threads.
    ///
    /// `UIApplication.applicationState` must be read on main, so callbacks that
    /// fire from Ghostty's IO thread or session batcher threads cannot read
    /// `isAppBackgrounded` directly. They consult this atomic mirror instead to
    /// short-circuit `Task { @MainActor in ... }` creation while the app is
    /// backgrounded. `MainViewLifecycle.handleAppBackgrounded` /
    /// `handleAppForegrounded` keep this in sync with the real state.
    nonisolated static var isAppBackgroundedAtomic: Bool {
        get { isAppBackgroundedFlag.withLock { $0 } }
        set { isAppBackgroundedFlag.withLock { $0 = newValue } }
    }

    private nonisolated static let isAppBackgroundedFlag = OSAllocatedUnfairLock(initialState: false)

    /// True whenever presenting a frame could land in the system's secure-mode
    /// lock snapshot (FrontBoard 0x2BAD45EC kills the process for it). Armed at
    /// launch so background/protected-data launches, which never see
    /// willResignActive or didEnterBackground, start protected; re-armed on
    /// willResignActive and didEnterBackground; cleared only on didBecomeActive
    /// (AppDelegate.installLifecycleObservers). Enforced at the delivery point
    /// of occlusion(true) pushes and direct surface draws rather than at the
    /// emit site, so a push queued before the lock cannot land inside the
    /// secure window. Inert on Catalyst: no secure mode there, and windows
    /// legitimately draw while the app is inactive.
    nonisolated static var isSecureDrawProhibitedAtomic: Bool {
        get {
            #if targetEnvironment(macCatalyst)
            return false
            #else
            return secureDrawProhibitedFlag.withLock { $0 }
            #endif
        }
        set { secureDrawProhibitedFlag.withLock { $0 = newValue } }
    }

    private nonisolated static let secureDrawProhibitedFlag = OSAllocatedUnfairLock(initialState: true)

    /// Catalyst-aware "transport read thread is frozen by suspension" signal for
    /// the tmux -CC recovery/resume watchdogs. Uses the LIVE `applicationState`,
    /// not `isAppBackgroundedAtomic`: that mirror stays TRUE until the
    /// foreground-resume drain gate opens (`MainViewLifecycle` ~1331), which can
    /// stall and strand the watchdogs (resume spins forever → "Reconnecting tmux"
    /// stuck; recovery never escalates). Always false on Catalyst (no background
    /// thread freeze). ROOTSHELL-TMUX (id=tmux-watchdog-live-fgstate)
    @MainActor
    static var isTransportFrozenByBackground: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return isAppBackgrounded
        #endif
    }

    /// True for a brief window after the app foregrounds — used by bisection
    /// gates to suppress specific tssh-driven state mutations while the
    /// SwiftUI scene-update transaction is settling.
    ///
    /// Implemented as a deadline timestamp rather than a Bool + timer:
    /// rapid background/foreground bounces would otherwise schedule
    /// per-resume `asyncAfter` clear timers that race with each other —
    /// the first timer to fire would close the window even if a later
    /// resume had extended it. Reading "now < deadline" is O(1) and has
    /// no scheduling state to coordinate, so each foreground call to
    /// `extendResumeQuietWindow(by:)` simply pushes the deadline forward
    /// from the current moment.
    nonisolated static var isInResumeQuietWindowAtomic: Bool {
        let deadline = resumeQuietWindowDeadline.withLock { $0 }
        return Date().timeIntervalSinceReferenceDate < deadline
    }

    /// Push the resume quiet window deadline `seconds` into the future from
    /// now. Idempotent across rapid bounces: if a later resume calls this
    /// while the window is still open, the deadline only moves forward
    /// (never backward), so a fast back-to-back bounce can't shorten the
    /// quiet window of the most recent resume.
    nonisolated static func extendResumeQuietWindow(by seconds: TimeInterval) {
        let target = Date().timeIntervalSinceReferenceDate + seconds
        resumeQuietWindowDeadline.withLock { current in
            if target > current {
                current = target
            }
        }
    }

    private nonisolated static let resumeQuietWindowDeadline = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Same shape as `isInResumeQuietWindowAtomic` but with a longer
    /// deadline, scoped specifically to suppress per-session health-status
    /// publishes (TerminalView.applyConnectionHealth) for longer than the
    /// general resume window. Heartbeat-driven connectionHealth fan-out
    /// across many tssh sessions is one of the noisier mutation sources
    /// after resume; allowing it to settle for ~1.5s while still letting
    /// other quiet-window gates expire after ~150ms keeps the UI feeling
    /// responsive without re-introducing the @Published storm.
    nonisolated static var isInResumeHealthQuietWindowAtomic: Bool {
        let deadline = resumeHealthQuietWindowDeadline.withLock { $0 }
        return Date().timeIntervalSinceReferenceDate < deadline
    }

    /// Push the health-specific quiet window forward (only-grow semantics,
    /// matches `extendResumeQuietWindow`).
    nonisolated static func extendResumeHealthQuietWindow(by seconds: TimeInterval) {
        let target = Date().timeIntervalSinceReferenceDate + seconds
        resumeHealthQuietWindowDeadline.withLock { current in
            if target > current {
                current = target
            }
        }
    }

    private nonisolated static let resumeHealthQuietWindowDeadline = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    @MainActor
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Shared instance for global access (primarily for window configuration)
        /// Note: The app is still created as @StateObject in RootShellApp, this just provides access
        nonisolated(unsafe) static var shared: App?

        /// Static mapping of app pointers to App instances for callback access
        /// Using Int (pointer address) as key instead of ObjectIdentifier to avoid wrapper object issues
        private nonisolated(unsafe) static var appInstances: [Int: Weak<App>] = [:]

        /// Weak wrapper for App instances
        private struct Weak<T: AnyObject> {
            weak var value: T?
        }

        /// Optional delegate for handling app events
        weak var delegate: GhosttyAppDelegate?

        /// The readiness state of the app
        @Published var readiness: Readiness = .loading

        /// The global app configuration
        @Published private(set) var config: Config

        /// The ghostty app instance
        nonisolated(unsafe) var app: ghostty_app_t? = nil

        /// Mapping of surface pointers to their action delegates
        /// Using Int (pointer address) as key instead of ObjectIdentifier to avoid wrapper object issues
        private var surfaceDelegates: [Int: WeakActionDelegate] = [:]

        /// Weak wrapper for action delegates
        private struct WeakActionDelegate {
            weak var delegate: GhosttyActionDelegate?
        }

        /// Registry of active surface pointers
        private var activeSurfaces: Set<UnsafeMutableRawPointer> = []

        /// Surface-content events are shared by agent detection and tmux pane
        /// identity refresh. Keep the core signal on while either consumer
        /// needs it; otherwise disabling detection would also freeze inactive
        /// tmux pane titles.
        private var attentionContentEventsEnabled = false
        private var tmuxContentEventInterests: Set<UUID> = []
        private var appliedContentEventsEnabled = false

        /// Whether there are any active Ghostty surfaces
        var hasActiveSurfaces: Bool {
            !activeSurfaces.isEmpty
        }

        /// The number of active surfaces
        var surfaceCount: Int {
            activeSurfaces.count
        }

        /// Publisher that emits when the number of active surfaces changes
        let surfaceCountDidChange = PassthroughSubject<Void, Never>()

        /// Mapping of surface pointers to window IDs
        private var surfaceWindowMap: [Int: String] = [:]

        /// Mapping of surface pointers to tab UUIDs
        private var surfaceTabMap: [Int: UUID] = [:]

        /// Subscription to theme changes
        private var themeSubscription: AnyCancellable?

        /// Subscription to font size changes
        private var fontSizeSubscription: AnyCancellable?

        /// Subscription to font family changes
        private var fontFamilySubscription: AnyCancellable?

        /// Subscription to ligatures changes
        private var ligaturesSubscription: AnyCancellable?

        /// Subscription to font feature changes
        private var fontFeaturesSubscription: AnyCancellable?

        /// Subscription to per-font cell adjustment changes
        private var cellAdjustmentsSubscription: AnyCancellable?

        /// Subscription to transparency changes
        private var transparencySubscription: AnyCancellable?

        /// Observer token for shader config changes
        private var shaderObserver: NSObjectProtocol?

        /// Observer token for cursor config changes
        private var cursorObserver: NSObjectProtocol?

        /// Observer token for selection config changes
        private var selectionObserver: NSObjectProtocol?

        /// Observer token for palette config changes
        private var paletteObserver: NSObjectProtocol?

        /// Observer token for HDR brightness-boost changes
        private var brightnessObserver: NSObjectProtocol?

        /// Observer token for auto-redact configuration changes
        private var redactionObserver: NSObjectProtocol?

        /// Observer token for power-tier changes
        private var powerObserver: NSObjectProtocol?

        /// Last animated-cursor throttle we pushed through the config
        /// reload, so tier changes that don't affect the cursor are free.
        private var lastAppliedCursorThrottle: Bool?

        init() {
            // Initialize ios_system environment variables (iOS/visionOS only) FIRST.
            //
            // IMPORTANT: setenv() calls must complete BEFORE Ghostty's Zig code
            // spawns any background thread. POSIX setenv/getenv are not thread-safe
            // against each other; a concurrent getenv iteration can dereference freed
            // environ entries. See TestFlight crash 16CB397E-97E0-461E-B78E-41FBFA38CC18
            // (build 65) — a Zig os.xdg.dir thread faulted reading environ while
            // ios_system's initializeEnvironment() was still setting XDG_CACHE_HOME /
            // XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_DATA_HOME.
            #if !targetEnvironment(macCatalyst)
            initializeEnvironment()
            #endif

            // Now safe to initialize ghostty (may spawn Zig threads that read env vars).
            Ghostty.initialize()

            // Register ios_system command dictionaries and direct function entry points.
            // These mutate ios_system's commandList global, not environ — safe post-init.
            #if !targetEnvironment(macCatalyst)

            // Load command dictionaries
            if let commandDictPath = Bundle.main.path(forResource: "commandDictionary", ofType: "plist") {
                if let error = addCommandList(commandDictPath) {
                    logger.error("Failed to load commandDictionary: \(error.localizedDescription)")
                } else {
                    logger.info("Loaded commandDictionary.plist")
                }
            } else {
                logger.warning("commandDictionary.plist not found in bundle")
            }

            if let extraCommandDictPath = Bundle.main.path(forResource: "extraCommandsDictionary", ofType: "plist") {
                if let error = addCommandList(extraCommandDictPath) {
                    logger.error("Failed to load extraCommandsDictionary: \(error.localizedDescription)")
                } else {
                    logger.info("Loaded extraCommandsDictionary.plist")
                }
            } else {
                logger.warning("extraCommandsDictionary.plist not found in bundle")
            }

            // Register @_cdecl entry points directly with ios_system.
            // Bypasses dlsym which fails in archive/TestFlight builds due to
            // symbol stripping by Whole Module Optimization + app thinning.
            registerCommandFunction("git") { argc, argv in git_main(argc, argv) }
            registerCommandFunction("mtr") { argc, argv in mtr_main(argc, argv) }
            registerCommandFunction("mtr6") { argc, argv in mtr6_main(argc, argv) }
            registerCommandFunction("traceroute") { argc, argv in traceroute_main(argc, argv) }
            registerCommandFunction("traceroute6") { argc, argv in traceroute6_main(argc, argv) }
            registerCommandFunction("whatismyip") { argc, argv in whatismyip_main(argc, argv) }
            registerCommandFunction("whatismyip4") { argc, argv in whatismyip4_main(argc, argv) }
            registerCommandFunction("whatismyip6") { argc, argv in whatismyip6_main(argc, argv) }
            registerCommandFunction("bssid") { argc, argv in bssid_main(argc, argv) }
            registerCommandFunction("gix") { argc, argv in gix_main(argc, argv) }
            registerCommandFunction("imgtext") { argc, argv in imgtext_main(argc, argv) }

            // Setup joe text editor (debug builds only - GPL licensed, excluded from distribution)
            #if DEBUG
            if let joeCommandDictPath = Bundle.main.path(forResource: "joeCommandDictionary", ofType: "plist") {
                if let error = addCommandList(joeCommandDictPath) {
                    logger.error("Failed to load joeCommandDictionary: \(error.localizedDescription)")
                } else {
                    logger.info("Loaded joeCommandDictionary.plist")
                }
            }
            JoeResourceManager.shared.setupResources()
            #endif

            // Setup curl CA certificates for TLS/HTTPS support (only on iOS/iPadOS)
            CurlResourceManager.shared.setupResources()
            #endif

            // Initialize the global configuration
            self.config = Config()
            if self.config.config == nil {
                logger.error("Config creation failed")
                readiness = .error
                return
            }

            // Set as shared instance for global access (after all properties initialized)
            Ghostty.App.shared = self

            // Create runtime configuration with callbacks
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in return App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in
                    App.confirmReadClipboard(userdata, string: str, state: state, request: request)
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    App.closeSurface(userdata, processAlive: processAlive)
                }
            )

            // Create the ghostty app
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new returned nil!")
                readiness = .error
                return
            }
            self.app = app

            // Register this instance for callback access
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let appId = Int(bitPattern: app)
            Self.appInstances[appId] = Weak(value: self)

            // Apply saved theme on startup
            self.applyCurrentTheme()

            // Apply saved font size on startup
            self.applyCurrentFontSize()

            // Apply saved font family on startup
            self.applyCurrentFontFamily()

            // Blur is applied per-window by WindowAccessor when it claims each
            // NSWindow, and re-asserted on scene activation — no launch-time
            // delayed pass needed here.

            // Listen for theme changes
            self.setupThemeSubscription()

            // Listen for font size changes
            self.setupFontSizeSubscription()

            // Listen for font family changes
            self.setupFontFamilySubscription()

            // Listen for ligatures changes
            self.setupLigaturesSubscription()

            // Listen for font feature changes
            self.setupFontFeaturesSubscription()

            // Listen for per-font cell adjustment changes
            self.setupCellAdjustmentsSubscription()

            // Listen for transparency changes
            self.setupTransparencySubscription()

            // Listen for shader config changes
            self.setupShaderSubscription()

            // Listen for cursor config changes
            self.setupCursorSubscription()

            // Listen for selection config changes
            self.setupSelectionSubscription()

            // Listen for palette config changes
            self.setupPaletteSubscription()

            // Listen for HDR brightness-boost changes
            self.setupBrightnessSubscription()

            // Listen for power-tier changes (battery saver / refresh cap)
            self.setupPowerSubscription()

            // Listen for auto-redact configuration changes
            self.setupRedactionSubscription()

            self.readiness = .ready
        }

        nonisolated deinit {
            // Free the app on deinit
            // Capture the app pointer to avoid capturing self
            let appPtr = self.app
            if let appPtr = appPtr {
                // Free directly - ghostty_app_free should be thread-safe
                ghostty_app_free(appPtr)
            }
        }

        // MARK: - App Operations

        /// Set to true when the app enters background to prevent Metal rendering
        /// while the device is locked, which causes iOS to kill the process
        /// ("insecure drawing while in secure mode").
        ///
        /// On Mac Catalyst this flag is NOT checked because macOS does not kill
        /// apps for background Metal draws, and scenePhase transitions are
        /// unreliable — the flag can get stuck true, freezing all rendering.
        var isInBackground = false {
            didSet {
                guard isInBackground != oldValue else { return }
                applySurfaceContentEventInterests()
                TmuxController.applicationBackgroundStateDidChange(isInBackground)
            }
        }

        func appTick() {
            #if targetEnvironment(macCatalyst)
            guard let app = self.app else { return }
            #else
            guard let app = self.app, !isInBackground else { return }
            #endif
            let signpost = TmuxPipelineSignposts.begin("app.tick")
            defer { TmuxPipelineSignposts.end("app.tick", signpost) }
            ghostty_app_tick(app)
        }

        func appTickAfterResumeQuietWindow() {
            if BisectFlags.gate3_appTick && Ghostty.isInResumeQuietWindowAtomic {
                LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                Self.scheduleDeferredResumeTick(for: self)
                return
            }
            appTick()
        }

        /// Gate the optional per-surface content signal in Ghostty itself.
        /// This setter owns the agent-detection interest. Tmux controllers
        /// register their independent interest below.
        func setSurfaceContentEventsEnabled(_ enabled: Bool) {
            attentionContentEventsEnabled = enabled
            applySurfaceContentEventInterests()
        }

        /// Register or release a live tmux controller's need for pane-content
        /// edges. The ID is unique to one controller lifetime, so a delayed
        /// deinit release can never remove a replacement controller's interest.
        func setTmuxSurfaceContentEventsEnabled(_ enabled: Bool, interestID: UUID) {
            if enabled {
                tmuxContentEventInterests.insert(interestID)
            } else {
                tmuxContentEventInterests.remove(interestID)
            }
            applySurfaceContentEventInterests()
        }

        private func applySurfaceContentEventInterests() {
            let enabled = !isInBackground
                && (attentionContentEventsEnabled || !tmuxContentEventInterests.isEmpty)
            guard enabled != appliedContentEventsEnabled, let app else { return }
            appliedContentEventsEnabled = enabled
            ghostty_app_set_surface_content_events_enabled(app, enabled)
        }

        // MARK: - Config Delivery

        /// Push a rebuilt config to the core app and its surfaces, serialized on
        /// `ghosttyAPIQueue`.
        ///
        /// Every surface-lifetime call runs on that serial queue, including
        /// `ghostty_surface_free`. `ghostty_app_update_config` walks Ghostty's own
        /// surface list, which still holds a surface until its queued free actually
        /// runs, so pushing a config from the main thread could deinit the same
        /// `DerivedConfig` a teardown is deiniting and free its link regexes twice.
        ///
        /// `ghostty_app_update_config` both stores the config that newly created
        /// surfaces inherit and fans it out to every surface Ghostty knows about, so
        /// it always overwrites surfaces carrying a tab/window theme override. Those
        /// are put back afterwards with a config built from their own theme; skipping
        /// them is not enough, because the fan-out already reached them.
        ///
        /// Override configs are built here on the main actor; ownership transfers to
        /// the queue, which frees them once the push completes.
        ///
        /// - Parameter completion: run on the main actor after the C calls land. Use
        ///   this for anything that must observe the new config; a timer cannot, since
        ///   the queue may be behind a teardown's save wait.
        /// - Returns: how many surfaces took the global config and how many were put
        ///   back on their override.
        @discardableResult
        private func pushConfig(
            app: ghostty_app_t,
            globalConfig: ghostty_config_t,
            completion: (@MainActor @Sendable () -> Void)? = nil
        ) -> (updated: Int, overridden: Int) {
            var overrideSurfaces: [(UnsafeMutableRawPointer, UnsafeMutableRawPointer)] = []
            var overridden = 0

            for surface in activeSurfaces {
                let surfaceId = Int(bitPattern: surface)
                let (themeName, source) = ThemeOverrideManager.shared.resolveTheme(
                    tabId: surfaceTabMap[surfaceId],
                    windowId: surfaceWindowMap[surfaceId])
                guard source != .global else { continue }

                overridden += 1
                if let surfaceConfig = Ghostty.Config.createConfigForTheme(themeName) {
                    overrideSurfaces.append((surface, surfaceConfig))
                }
            }

            nonisolated(unsafe) let appPtr = app
            nonisolated(unsafe) let cfg = globalConfig
            nonisolated(unsafe) let overrides = overrideSurfaces
            Ghostty.TerminalView.ghosttyAPIQueue.async {
                ghostty_app_update_config(appPtr, cfg)
                for (surface, surfaceConfig) in overrides {
                    ghostty_surface_update_config(surface, surfaceConfig)
                    ghostty_config_free(surfaceConfig)
                }
                if let completion {
                    Task { @MainActor in completion() }
                }
            }

            return (activeSurfaces.count - overridden, overridden)
        }

        /// Push the current global config, for callers outside this type that have
        /// already rewritten the config file. Goes through
        /// `pushConfig(app:globalConfig:completion:)` so per-surface theme overrides
        /// survive the app-level fan-out.
        func pushGlobalConfigToApp() {
            guard let app = self.app, let cfg = config.config else { return }
            pushConfig(app: app, globalConfig: cfg)
        }

        /// Push a config to a single surface on `ghosttyAPIQueue`, for the same
        /// reason as `pushConfig(app:globalConfig:completion:)`.
        ///
        /// - Parameter owned: when true the config was built for this call and is
        ///   freed on the queue once the push completes.
        private func pushConfig(
            toSurface surface: ghostty_surface_t,
            config surfaceConfig: ghostty_config_t,
            owned: Bool
        ) {
            nonisolated(unsafe) let surface = surface
            nonisolated(unsafe) let surfaceConfig = surfaceConfig
            Ghostty.TerminalView.ghosttyAPIQueue.async {
                ghostty_surface_update_config(surface, surfaceConfig)
                if owned { ghostty_config_free(surfaceConfig) }
            }
        }

        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        func changeFontSize(surface: ghostty_surface_t, delta: Int) {
            let action = delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)"
            let actionLen = UInt(action.utf8.count)
            nonisolated(unsafe) let surface = surface
            Ghostty.TerminalView.ghosttyAPIQueue.async {
                action.withCString { cAction in
                    if !ghostty_surface_binding_action(surface, cAction, actionLen) {
                        Ghostty.logger.warning("font size action failed")
                    }
                }
            }
        }

        func resetFontSize(surface: ghostty_surface_t) {
            let action = "reset_font_size"
            let actionLen = UInt(action.utf8.count)
            nonisolated(unsafe) let surface = surface
            Ghostty.TerminalView.ghosttyAPIQueue.async {
                action.withCString { cAction in
                    if !ghostty_surface_binding_action(surface, cAction, actionLen) {
                        Ghostty.logger.warning("reset font size action failed")
                    }
                }
            }
        }

        // MARK: - Theme Management

        /// Set up subscription to theme changes
        private func setupThemeSubscription() {
            themeSubscription = ThemeManager.shared.themeDidChange
                .sink { [weak self] theme in
                    self?.applyCurrentTheme()
                }
        }

        /// Apply the current theme from ThemeManager
        /// Respects per-surface overrides - surfaces with tab/window overrides are skipped
        func applyCurrentTheme() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            #if !targetEnvironment(macCatalyst)
            // Update bat's terminal palette so next bat invocation uses new colors
            LocalShellSession.updateBatTerminalPalette()
            #endif

            guard let app = self.app else {
                logger.warning("Cannot apply theme: app is nil")
                return
            }

            let themeName = ThemeManager.shared.currentTheme
            logger.info("Applying theme: \(themeName)")

            // Apply theme to the config (this replaces config.config with new pointer)
            if config.setTheme(themeName), let newCfg = config.config {
                let (updatedCount, overriddenCount) = pushConfig(app: app, globalConfig: newCfg)

                logger.info("Theme applied: \(updatedCount) surfaces updated, \(overriddenCount) kept on their override")
            } else {
                logger.error("Failed to apply theme: \(themeName)")
            }
        }

        // MARK: - Per-Surface Theme Overrides

        /// Apply a specific theme to a single surface (for per-tab/per-window overrides)
        /// This does not affect the global config or other surfaces.
        /// - Parameters:
        ///   - surface: The ghostty surface to apply the theme to
        ///   - themeName: The theme name to apply
        func applyThemeToSurface(_ surface: ghostty_surface_t, themeName: String) {
            logger.info("Applying theme override to surface: \(themeName)")

            guard let surfaceConfig = Ghostty.Config.createConfigForTheme(themeName) else {
                logger.error("Failed to create config for surface theme: \(themeName)")
                return
            }

            pushConfig(toSurface: surface, config: surfaceConfig, owned: true)

            logger.info("Applied theme override to surface: \(themeName)")
        }

        /// Refresh a surface's theme based on the current override state
        /// Resolves the effective theme from ThemeOverrideManager and applies it
        /// - Parameters:
        ///   - surface: The ghostty surface to refresh
        ///   - tabId: The tab UUID (for tab-level override lookup)
        ///   - windowId: The window ID (for window-level override lookup)
        func refreshSurfaceTheme(_ surface: ghostty_surface_t, tabId: UUID?, windowId: String?) {
            let (themeName, source) = ThemeOverrideManager.shared.resolveTheme(tabId: tabId, windowId: windowId)

            switch source {
            case .global:
                // No override - use the shared global config
                if let globalConfig = config.config {
                    pushConfig(toSurface: surface, config: globalConfig, owned: false)
                    logger.info("Surface theme refreshed to global: \(themeName)")
                }
            case .window, .tab:
                // Has override - create and apply per-surface config
                applyThemeToSurface(surface, themeName: themeName)
                let sourceStr = source == .tab ? "tab" : "window"
                logger.info("Surface theme refreshed to \(sourceStr) override: \(themeName)")
            }
        }

        // MARK: - Font Size Management

        /// Set up subscription to font size changes
        private func setupFontSizeSubscription() {
            fontSizeSubscription = FontManager.shared.fontSizeDidChange
                .sink { [weak self] fontSize in
                    self?.applyCurrentFontSize()
                }
        }

        /// Apply the current font size from FontManager
        func applyCurrentFontSize() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font size: app is nil")
                return
            }

            let fontSize = Int(FontManager.shared.currentFontSize)
            logger.info("Applying font size: \(fontSize)")

            // Apply font size to the config (this replaces config.config with new pointer)
            if config.setFontSize(fontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new font size")

                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Font size applied successfully to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply font size: \(fontSize)")
            }
        }

        // MARK: - Font Family Management

        /// Set up subscription to font family changes
        private func setupFontFamilySubscription() {
            fontFamilySubscription = FontManager.shared.fontFamilyDidChange
                .sink { [weak self] fontFamily in
                    self?.applyCurrentFontFamily()
                }
        }

        /// Apply the current font family from FontManager
        func applyCurrentFontFamily() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font family: app is nil")
                return
            }

            let fontFamily = FontManager.shared.currentFontFamily
            logger.info("Applying font family: \(fontFamily ?? "Ghostty Default")")

            // If font family is nil, we need to remove it from config
            // by writing config without font-family line
            if let family = fontFamily {
                // Apply font family to the config (this replaces config.config with new pointer)
                if config.setFontFamily(family), let newCfg = config.config {
                    // Update all active surfaces individually, respecting theme overrides
                    logger.info("Updating \(self.activeSurfaces.count) active surfaces with new font family")

                    pushConfig(app: app, globalConfig: newCfg)

                    logger.info("Font family applied successfully to app and \(self.activeSurfaces.count) surfaces")
                } else {
                    logger.error("Failed to apply font family: \(family)")
                }
            } else {
                // Reset to default by rewriting config without font-family
                // This forces a config reload with just theme and size
                let currentTheme = ThemeManager.shared.currentTheme
                let currentFontSize = Int(FontManager.shared.currentFontSize)

                if config.setTheme(currentTheme) && config.setFontSize(currentFontSize) {
                    if let currentCfg = config.config {
                        pushConfig(app: app, globalConfig: currentCfg)
                    }

                    logger.info("Reset to Ghostty default font")
                }
            }
        }

        // MARK: - Font Ligatures Management

        /// Set up subscription to ligatures changes
        private func setupLigaturesSubscription() {
            ligaturesSubscription = FontManager.shared.ligaturesDidChange
                .sink { [weak self] _ in
                    self?.applyCurrentLigatures()
                }
        }

        /// Apply the current ligatures setting from FontManager
        func applyCurrentLigatures() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply ligatures: app is nil")
                return
            }

            let ligaturesEnabled = FontManager.shared.ligaturesEnabled
            logger.info("Applying ligatures: \(ligaturesEnabled ? "enabled" : "disabled")")

            // Ligatures are applied via config file, so we need to reload the config
            // by triggering a font size update (which writes the config with ligatures setting)
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            // setFontSize replaces config.config with new pointer
            if config.setFontSize(currentFontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new ligatures setting")

                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Ligatures applied successfully to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply ligatures setting")
            }
        }

        // MARK: - Font Features Management

        /// Set up subscription to font feature changes
        private func setupFontFeaturesSubscription() {
            fontFeaturesSubscription = FontManager.shared.fontFeaturesDidChange
                .sink { [weak self] in
                    self?.applyCurrentFontFeatures()
                }
        }

        /// Apply the current font feature settings from FontManager
        func applyCurrentFontFeatures() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font features: app is nil")
                return
            }

            logger.info("Applying font feature changes")

            // Font features are applied via config file, so reload the config
            // by triggering a font size update (which writes the config with feature settings)
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setFontSize(currentFontSize), let newCfg = config.config {
                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Font features applied to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply font features")
            }
        }

        // MARK: - Cell Adjustments Management

        /// Set up subscription to per-font cell adjustment changes
        private func setupCellAdjustmentsSubscription() {
            cellAdjustmentsSubscription = FontManager.shared.cellAdjustmentsDidChange
                .sink { [weak self] in
                    self?.applyCellAdjustments()
                }
        }

        /// Apply the current cell adjustments by rewriting the config file
        /// (which embeds `adjust-cell-width` / `adjust-cell-height` lines)
        /// and notifying the app + active surfaces.
        func applyCellAdjustments() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply cell adjustments: app is nil")
                return
            }

            logger.info("Applying cell adjustment changes")

            // Reuse the font-size reload path: setFontSize rewrites the config
            // file (which now includes adjust-cell-* lines) and reloads it.
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setFontSize(currentFontSize), let newCfg = config.config {
                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Cell adjustments applied to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply cell adjustments")
            }
        }

        // MARK: - Transparency Management

        /// Set up subscription to transparency changes
        private func setupTransparencySubscription() {
            #if targetEnvironment(macCatalyst)
            transparencySubscription = TransparencyManager.shared.transparencyDidChange
                .sink { [weak self] in
                    self?.applyCurrentTransparency()
                }
            #endif
        }

        /// Set up listener for shader config changes
        private func setupShaderSubscription() {
            shaderObserver = NotificationCenter.default.addObserver(
                forName: .shaderConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyShaderConfig()
                }
            }
        }

        /// Apply shader config changes by updating app and all surfaces
        func applyShaderConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply shader config: app is nil")
                return
            }

            logger.info("Shader config changed, reloading config...")

            // Rewrite the config file with current theme (includes shader lines)
            // setTheme replaces config.config with new pointer
            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for shader config")
                return
            }

            // Update all active surfaces individually to apply shader changes
            logger.info("Updating \(self.activeSurfaces.count) active surfaces with new shader config")

            // Post layout invalidation to ensure terminals resize correctly, once
            // the config has actually landed. A timer can't be used: the queue may
            // be sitting behind a teardown's save wait.
            pushConfig(app: app, globalConfig: newCfg) {
                NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
            }
        }

        /// Set up listener for cursor config changes
        private func setupBrightnessSubscription() {
            brightnessObserver = NotificationCenter.default.addObserver(
                forName: .brightnessDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyCurrentBrightness()
                }
            }
        }

        /// Push the current global brightness gain to every live surface.
        func applyCurrentBrightness() {
            let gain = Float(BrightnessManager.shared.effectiveGain)
            let surfaceCount = activeSurfaces.count
            for surfacePtr in activeSurfaces {
                ghostty_surface_set_brightness(surfacePtr, gain)
            }
            // HDR drives EDR/occlusion churn that can precede a render freeze;
            // this is the only HDR signal in the lifecycle log.
            LifecycleDebugLogger.shared.checkpoint("FG.hdr.apply", ms: nil, [
                ("gain", gain),
                ("surfaces", surfaceCount),
            ])
        }

        /// Set up listener for auto-redact configuration changes
        private func setupRedactionSubscription() {
            redactionObserver = NotificationCenter.default.addObserver(
                forName: .redactionConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyRedaction()
                }
            }
        }

        /// Push the current auto-redact needle set to every live surface.
        /// Disabled or unconfigured redaction pushes the empty set, which
        /// clears masking inside GhosttyKit.
        func applyRedaction() {
            let manager = RedactionManager.shared
            let strings = manager.isEnabled ? manager.needleStrings : []
            let surfaceCount = activeSurfaces.count
            for surfacePtr in activeSurfaces {
                Self.pushRedaction(strings, to: surfacePtr)
            }
            // Never log the needle strings themselves.
            let stateDescription = strings.isEmpty ? "off" : "on (\(strings.count) items)"
            logger.info("Applied redaction \(stateDescription) to \(surfaceCount) surfaces")
        }

        /// Hand a needle list to one surface. An empty list disables and
        /// clears redaction for that surface. The strings are fully copied
        /// by GhosttyKit before the call returns.
        static func pushRedaction(_ strings: [String], to surface: UnsafeMutableRawPointer) {
            guard !strings.isEmpty else {
                ghostty_surface_set_redact(surface, nil, 0, 0, 0)
                return
            }

            // Matching is case-insensitive (flags bit 0); mask 0 selects
            // GhosttyKit's default bullet. The ABI requires every element
            // to be non-NULL, so a failed strdup aborts the whole update
            // (the surface keeps its current protection) rather than
            // passing a partial array.
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            cStrings.reserveCapacity(strings.count)
            defer { for s in cStrings { free(s) } }
            for string in strings {
                guard let dup = strdup(string) else {
                    Ghostty.logger.error("strdup failed; skipping redaction update")
                    return
                }
                cStrings.append(dup)
            }
            let pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
            pointers.withUnsafeBufferPointer { buffer in
                ghostty_surface_set_redact(surface, buffer.baseAddress, UInt(strings.count), 0, 1)
            }
        }

        /// Set up listener for power-tier changes
        private func setupPowerSubscription() {
            powerObserver = NotificationCenter.default.addObserver(
                forName: .powerTierChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyCurrentFrameRateRange()
                    // Saver tier also downgrades animated cursor blink modes;
                    // reuse the cursor config path to push the change. That
                    // path reloads the whole ghostty config, so only pay for
                    // it when the downgrade itself flips — the adaptive
                    // refresh setting makes full<->reduced transitions
                    // common, and neither of those touches the cursor.
                    let throttle = PowerManager.shared.throttleAnimatedCursor
                    if throttle != self.lastAppliedCursorThrottle {
                        self.lastAppliedCursorThrottle = throttle
                        self.applyCursorConfig()
                    }
                }
            }

            // PowerManager may have broadcast before this observer existed
            // (it is created eagerly at launch), and a missed broadcast is
            // never re-sent, so converge on the current tier now.
            lastAppliedCursorThrottle = PowerManager.shared.throttleAnimatedCursor
            if !activeSurfaces.isEmpty {
                applyCurrentFrameRateRange()
            }
        }

        /// Push the current power-tier frame-rate range to every live
        /// surface. iOS/visionOS only in effect (no-op inside GhosttyKit on
        /// macOS, whose CVDisplayLink always follows the display).
        func applyCurrentFrameRateRange() {
            let range = PowerManager.shared.coreFrameRange
            let surfaceCount = activeSurfaces.count
            for surfacePtr in activeSurfaces {
                ghostty_surface_set_frame_rate_range(surfacePtr, range.min, range.max, range.preferred)
            }
            let tierName = PowerManager.shared.tier.displayName
            logger.info("Applied frame-rate range (\(tierName)) to \(surfaceCount) surfaces")
        }

        private func setupCursorSubscription() {
            cursorObserver = NotificationCenter.default.addObserver(
                forName: .cursorConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyCursorConfig()
                }
            }
        }

        /// Apply cursor config changes by reloading config
        func applyCursorConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            logger.info("Cursor config changed, reloading config...")
            reloadGlobalConfig()
        }

        /// Rewrite the generated config from every manager and push it once.
        /// Used after a batched settings change instead of one rewrite per key.
        func reloadGlobalConfig() {
            guard let app = self.app else {
                logger.warning("Cannot reload config: app is nil")
                return
            }
            #if !targetEnvironment(macCatalyst)
            LocalShellSession.updateBatTerminalPalette()
            #endif
            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to rewrite config for reload")
                return
            }
            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Set up listener for selection config changes
        private func setupSelectionSubscription() {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .selectionConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applySelectionConfig()
                }
            }
        }

        /// Apply selection config changes by reloading config
        func applySelectionConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply selection config: app is nil")
                return
            }

            logger.info("Selection config changed, reloading config...")

            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for selection config")
                return
            }

            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Set up listener for palette config changes
        private func setupPaletteSubscription() {
            paletteObserver = NotificationCenter.default.addObserver(
                forName: .paletteConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyPaletteConfig()
                }
            }
        }

        /// Apply palette config changes by reloading config
        func applyPaletteConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply palette config: app is nil")
                return
            }

            logger.info("Palette config changed, reloading config...")

            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for palette config")
                return
            }

            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Apply imported Ghostty keybind config changes by reloading the app config.
        func applyKeybindConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply keybind config: app is nil")
                return
            }

            logger.info("Keybind config changed, reloading config...")

            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for keybind config")
                return
            }

            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Apply the current transparency settings from TransparencyManager
        func applyCurrentTransparency() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            #if targetEnvironment(macCatalyst)
            guard let app = self.app else {
                logger.warning("Cannot apply transparency: app is nil")
                return
            }

            let opacity = TransparencyManager.shared.backgroundOpacity
            let blurRadius = TransparencyManager.shared.backgroundBlurRadius
            logger.info("Applying transparency: opacity=\(opacity), blur=\(blurRadius)")

            // Force config reload by setting both theme and font size
            // This will write the new opacity/blur values to the config file
            // Both setTheme and setFontSize replace config.config with new pointer
            let currentTheme = ThemeManager.shared.currentTheme
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setTheme(currentTheme) && config.setFontSize(currentFontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides.
                // Override surfaces get a rebuilt config so they pick up the new
                // transparency settings from TransparencyManager.
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new transparency")

                // Blur has to wait for the push to land: libghostty reads
                // `background-blur` / `background-opacity` off the app config when
                // it sets the CGS radius, so running the sweep inline would apply
                // the *previous* style — a Standard radius on top of a glass
                // backdrop when switching into a glass style.
                pushConfig(app: app, globalConfig: newCfg) { [weak self] in
                    self?.applyWindowBlur()
                }

                logger.info("Transparency applied successfully")
            } else {
                logger.error("Failed to apply transparency")
            }
            #endif
        }

        /// Apply background blur to all NSWindows (Mac Catalyst only)
        /// Uses TransparencyManager.useSandboxBlur to determine implementation:
        /// - true: NSVisualEffectView (App Store safe)
        /// - false: private CGS API (non-sandbox only)
        func applyWindowBlur() {
            #if targetEnvironment(macCatalyst)
            if TransparencyManager.useSandboxBlur {
                applyWindowBlurVisualEffect()
            } else {
                applyWindowBlurPrivateAPI()
            }
            #endif
        }

        #if targetEnvironment(macCatalyst)

        /// Apply (or remove) blur for a single NSWindow based on the current
        /// transparency settings. Unlike the global sweep this has no
        /// `isVisible` gate: CGS blur is window-server state that sticks once
        /// set on a valid window, so WindowAccessor can call this the moment
        /// it claims a freshly created NSWindow.
        func applyWindowBlur(to nsWindow: NSObject) {
            // The NSApplication.windows sweep includes our own glass backdrops.
            guard !isGlassBackdropWindow(nsWindow) else { return }
            let manager = TransparencyManager.shared
            let opacity = manager.backgroundOpacity
            let style = manager.effectiveBlurStyle

            if style != .standard, opacity < 1.0 {
                removeVisualEffectBlurFromWindow(nsWindow)
                if addGlassEffectViewToWindow(nsWindow, style: style) {
                    // Standalone: libghostty clears the CGS radius for glass styles.
                    if !TransparencyManager.useSandboxBlur, let app = self.app {
                        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(nsWindow).toOpaque())
                    }
                    return
                }
                // NSGlassEffectView unavailable: fall through to standard.
            }

            removeGlassEffectViewFromWindow(nsWindow)
            if TransparencyManager.useSandboxBlur {
                if opacity < 1.0 && manager.blurEnabled {
                    addVisualEffectBlurToWindow(nsWindow)
                } else {
                    removeVisualEffectBlurFromWindow(nsWindow)
                }
            } else {
                guard let app = self.app, opacity < 1.0 else { return }
                ghostty_set_window_background_blur(app, Unmanaged.passUnretained(nsWindow).toOpaque())
            }
        }

        // MARK: - Liquid Glass (macOS 26+, public API)

        /// Glass lives in a borderless child NSWindow ordered directly behind
        /// the terminal window, replacing the CGS blur. Catalyst's hosted UIKit
        /// tree gets treated as foreground by an in-window glass pass (it
        /// refracts the terminal), whereas a lower window can only sample the
        /// desktop. The terminal keeps drawing its theme background at the
        /// configured opacity, so the window's alpha (and shadow) is unchanged.
        private final class GlassBackdrop {
            let window: NSObject
            let glassView: NSObject
            var observers: [NSObjectProtocol] = []
            init(window: NSObject, glassView: NSObject) {
                self.window = window
                self.glassView = glassView
            }
        }

        private var glassBackdrops: [ObjectIdentifier: GlassBackdrop] = [:]

        private func isGlassBackdropWindow(_ window: NSObject) -> Bool {
            glassBackdrops.values.contains { $0.window === window }
        }

        /// Attach (or update) the glass backdrop behind `window`.
        /// Returns false when NSGlassEffectView is unavailable (pre-macOS 26).
        @discardableResult
        private func addGlassEffectViewToWindow(_ window: NSObject, style: TransparencyManager.BlurStyle) -> Bool {
            guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
                  let windowClass = NSClassFromString("NSWindow") as? NSObject.Type else {
                return false
            }
            // A child ordered in before the parent is on screen would show alone;
            // WindowAccessor re-asserts blur once the window becomes visible.
            guard (window.value(forKey: "isVisible") as? Bool) == true else { return true }

            // A backdrop ordered in under an opaque parent is born fully occluded
            // and its glass never starts rendering. Drop any existing one and wait
            // for the pass that clears `opaque` (WindowAccessor re-asserts blur in
            // that same pass) so the glass is always built on screen.
            guard (window.value(forKey: "opaque") as? Bool) == false else {
                removeGlassEffectViewFromWindow(window)
                return true
            }

            let key = ObjectIdentifier(window)
            let backdrop: GlassBackdrop
            if let existing = glassBackdrops[key] {
                backdrop = existing
            } else {
                guard let frame = window.value(forKey: "frame") as? CGRect,
                      let child = Self.makeBorderlessWindow(windowClass, frame: frame),
                      let glassView = Self.makeView(glassClass, frame: CGRect(origin: .zero, size: frame.size)) else {
                    logger.warning("Failed to create glass backdrop window")
                    return false
                }
                glassView.setValue(18, forKey: "autoresizingMask") // width | height sizable
                child.setValue(glassView, forKey: "contentView")
                // Dark-appearance "regular" glass is a dark smoky material that
                // hides the desktop; light appearance renders bright frosted
                // glass that passes the desktop through like the CGS blur.
                if let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type,
                   let aqua = appearanceClass.perform(
                       NSSelectorFromString("appearanceNamed:"), with: "NSAppearanceNameAqua"
                   )?.takeUnretainedValue() {
                    child.setValue(aqua, forKey: "appearance")
                }

                let addSelector = NSSelectorFromString("addChildWindow:ordered:")
                typealias AddChildFunction = @convention(c) (NSObject, Selector, NSObject, Int) -> Void
                let addChild = unsafeBitCast(window.method(for: addSelector), to: AddChildFunction.self)
                addChild(window, addSelector, child, -1) // NSWindowBelow

                backdrop = GlassBackdrop(window: child, glassView: glassView)
                let center = NotificationCenter.default
                for name in ["NSWindowDidResizeNotification", "NSWindowDidMoveNotification",
                             "NSWindowDidEnterFullScreenNotification", "NSWindowDidExitFullScreenNotification"] {
                    backdrop.observers.append(center.addObserver(
                        forName: Notification.Name(name), object: window, queue: .main
                    ) { [weak self] notification in
                        guard let window = notification.object as? NSObject else { return }
                        MainActor.assumeIsolated {
                            self?.syncGlassBackdrop(to: window)
                        }
                    })
                }
                backdrop.observers.append(center.addObserver(
                    forName: Notification.Name("NSWindowWillCloseNotification"), object: window, queue: .main
                ) { [weak self] notification in
                    guard let window = notification.object as? NSObject else { return }
                    MainActor.assumeIsolated {
                        self?.removeGlassEffectViewFromWindow(window)
                    }
                })
                glassBackdrops[key] = backdrop
            }

            // NSGlassEffectView.Style: regular = 0, clear = 1
            backdrop.glassView.setValue(style == .glassClear ? 1 : 0, forKey: "style")
            syncGlassBackdrop(to: window)
            return true
        }

        /// Match the backdrop's frame and corner radius to its parent.
        private func syncGlassBackdrop(to window: NSObject) {
            guard let backdrop = glassBackdrops[ObjectIdentifier(window)],
                  let frame = window.value(forKey: "frame") as? CGRect else { return }

            let setFrameSelector = NSSelectorFromString("setFrame:display:")
            typealias SetFrameFunction = @convention(c) (NSObject, Selector, CGRect, Bool) -> Void
            let setFrame = unsafeBitCast(backdrop.window.method(for: setFrameSelector), to: SetFrameFunction.self)
            setFrame(backdrop.window, setFrameSelector, frame, true)

            // Rounded corners are the parent's; full screen has none. Same
            // private `_cornerRadius` read ghostty uses for its glass shape.
            let styleMask = (window.value(forKey: "styleMask") as? UInt) ?? 0
            let isFullScreen = styleMask & (1 << 14) != 0
            var radius: CGFloat = 0
            if !isFullScreen, window.responds(to: NSSelectorFromString("_cornerRadius")),
               let r = window.value(forKey: "_cornerRadius") as? CGFloat {
                radius = r
            }
            backdrop.glassView.setValue(radius, forKey: "cornerRadius")
        }

        private func removeGlassEffectViewFromWindow(_ window: NSObject) {
            let key = ObjectIdentifier(window)
            guard let backdrop = glassBackdrops.removeValue(forKey: key) else { return }
            backdrop.observers.forEach { NotificationCenter.default.removeObserver($0) }
            if window.responds(to: NSSelectorFromString("removeChildWindow:")) {
                window.perform(NSSelectorFromString("removeChildWindow:"), with: backdrop.window)
            }
            backdrop.window.perform(NSSelectorFromString("orderOut:"), with: nil)
            // `releasedWhenClosed` is false, so this only takes the window out of
            // NSApp.windows — without it every teardown leaks a hidden window that
            // the blur sweep then rescans forever.
            backdrop.window.perform(NSSelectorFromString("close"))
        }

        /// Borderless, transparent, click-through NSWindow via the ObjC runtime.
        private static func makeBorderlessWindow(_ windowClass: NSObject.Type, frame: CGRect) -> NSObject? {
            guard let allocated = windowClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else {
                return nil
            }
            let initSelector = NSSelectorFromString("initWithContentRect:styleMask:backing:defer:")
            typealias WindowInitFunction = @convention(c) (NSObject, Selector, CGRect, UInt, UInt, Bool) -> NSObject
            let initFunc = unsafeBitCast(allocated.method(for: initSelector), to: WindowInitFunction.self)
            // styleMask 0 = borderless, backing 2 = buffered
            let window = initFunc(allocated, initSelector, frame, 0, 2, false)
            window.setValue(false, forKey: "opaque")
            window.setValue(false, forKey: "hasShadow")
            window.setValue(true, forKey: "ignoresMouseEvents")
            window.setValue(false, forKey: "releasedWhenClosed")
            if let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type,
               let clear = nsColorClass.value(forKey: "clearColor") {
                window.setValue(clear, forKey: "backgroundColor")
            }
            return window
        }

        private static func makeView(_ viewClass: NSObject.Type, frame: CGRect) -> NSObject? {
            guard let allocated = viewClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else {
                return nil
            }
            let initSelector = NSSelectorFromString("initWithFrame:")
            typealias InitFunction = @convention(c) (NSObject, Selector, CGRect) -> NSObject
            return unsafeBitCast(allocated.method(for: initSelector), to: InitFunction.self)(allocated, initSelector, frame)
        }

        /// Current theme background parsed from its hex string.
        private static func themeBackgroundRGB() -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let hex = ThemeManager.shared.currentThemeInfo?.colors.background else { return nil }
            let cleaned = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            var rgb: UInt64 = 0
            guard Scanner(string: cleaned).scanHexInt64(&rgb) else { return nil }
            return (
                CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
                CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
                CGFloat(rgb & 0x0000FF) / 255.0
            )
        }

        /// Current theme background as an NSColor built via the ObjC runtime.
        static func themeBackgroundNSColor(alpha: CGFloat) -> NSObject? {
            guard let (r, g, b) = Self.themeBackgroundRGB(),
                  let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type else { return nil }
            let colorSelector = NSSelectorFromString("colorWithRed:green:blue:alpha:")
            guard nsColorClass.responds(to: colorSelector) else { return nil }
            typealias ColorFunction = @convention(c) (AnyClass, Selector, CGFloat, CGFloat, CGFloat, CGFloat) -> NSObject
            let colorFunc = unsafeBitCast(nsColorClass.method(for: colorSelector), to: ColorFunction.self)
            return colorFunc(nsColorClass, colorSelector, r, g, b, alpha)
        }

        // MARK: - Private API Implementation (non-sandbox)

        /// Apply blur using private CGS API (non-sandbox builds only)
        private func applyWindowBlurPrivateAPI() {
            guard self.app != nil else { return }

            let blurRadius = TransparencyManager.shared.backgroundBlurRadius

            // No opacity gate: applyWindowBlur(to:) must still run when opaque
            // so glass views get removed.

            // Get NSApplication.sharedApplication
            guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
                  let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
                logger.warning("Failed to get NSWindows for blur application")
                return
            }

            // Apply blur to each visible window
            var appliedCount = 0
            for window in windows {
                // Check if window is visible
                if let isVisible = window.value(forKey: "isVisible") as? Bool, isVisible {
                    applyWindowBlur(to: window)
                    appliedCount += 1
                }
            }

            logger.info("Applied blur (radius: \(Int(blurRadius))) to \(appliedCount)/\(windows.count) visible window(s)")
        }

        // MARK: - NSVisualEffectView Implementation (sandbox/App Store)

        /// Identifier used to find our blur view in the window hierarchy
        private static let blurViewIdentifier = "com.rootshell.backgroundBlur"

        /// Apply blur using NSVisualEffectView (App Store/sandbox builds)
        private func applyWindowBlurVisualEffect() {
            let opacity = TransparencyManager.shared.backgroundOpacity
            let blurEnabled = TransparencyManager.shared.blurEnabled

            // Get NSApplication.sharedApplication
            guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
                  let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
                logger.warning("Failed to get NSWindows for blur application")
                return
            }

            // Apply or remove blur from each visible window
            // Blur only applies when: opacity < 1.0 AND blurEnabled is true
            var appliedCount = 0
            for window in windows {
                if let isVisible = window.value(forKey: "isVisible") as? Bool, isVisible {
                    applyWindowBlur(to: window)
                    if opacity < 1.0 && blurEnabled {
                        appliedCount += 1
                    }
                }
            }

            if opacity < 1.0 && blurEnabled {
                logger.info("Applied NSVisualEffectView blur to \(appliedCount)/\(windows.count) visible window(s)")
            } else if !blurEnabled {
                logger.info("Blur disabled by user setting")
            } else {
                logger.info("Removed blur from windows (opacity is 1.0)")
            }
        }

        /// Add NSVisualEffectView blur to a single NSWindow
        private func addVisualEffectBlurToWindow(_ window: NSObject) {
            // Get the contentView of the NSWindow
            guard let contentView = window.value(forKey: "contentView") as? NSObject else {
                logger.warning("Failed to get contentView from NSWindow")
                return
            }

            // Check if we already have a blur view
            if let subviews = contentView.value(forKey: "subviews") as? [NSObject] {
                for subview in subviews {
                    if let identifier = subview.value(forKey: "identifier") as? String, identifier == Self.blurViewIdentifier {
                        // Blur view already exists, ensure it's at the back
                        if subview.responds(to: NSSelectorFromString("removeFromSuperview")) {
                            subview.perform(NSSelectorFromString("removeFromSuperview"))
                        }
                        insertBlurViewAtBack(subview, into: contentView)
                        return
                    }
                }
            }

            // Create NSVisualEffectView
            guard let visualEffectViewClass = NSClassFromString("NSVisualEffectView") as? NSObject.Type else {
                logger.warning("Failed to get NSVisualEffectView class")
                return
            }

            // Get the contentView's frame for sizing
            guard let frameValue = contentView.value(forKey: "frame") as? CGRect else {
                logger.warning("Failed to get contentView frame")
                return
            }

            // Allocate and initialize with frame
            let allocSelector = NSSelectorFromString("alloc")
            let initSelector = NSSelectorFromString("initWithFrame:")

            guard let allocatedView = visualEffectViewClass.perform(allocSelector)?.takeUnretainedValue() as? NSObject else {
                logger.warning("Failed to alloc NSVisualEffectView")
                return
            }

            let initMethod = allocatedView.method(for: initSelector)
            typealias InitFunction = @convention(c) (NSObject, Selector, CGRect) -> NSObject
            let initFunc = unsafeBitCast(initMethod, to: InitFunction.self)
            let blurView = initFunc(allocatedView, initSelector, frameValue)

            // Configure the visual effect view:
            // material = 13 (.hudWindow) - good blur for terminal backgrounds
            // blendingMode = 1 (.behindWindow) - blur content behind the window
            // state = 1 (.active) - keep effect active even when window is inactive
            blurView.setValue(13, forKey: "material")
            blurView.setValue(1, forKey: "blendingMode")
            blurView.setValue(1, forKey: "state")

            // Set identifier for later lookup (NSView uses identifier, not tag)
            blurView.setValue(Self.blurViewIdentifier, forKey: "identifier")

            // Set autoresizing mask (NSViewWidthSizable | NSViewHeightSizable = 18)
            blurView.setValue(18, forKey: "autoresizingMask")

            // Insert at the back of the view hierarchy
            insertBlurViewAtBack(blurView, into: contentView)
        }

        /// Insert blur view at the back of the contentView hierarchy
        private func insertBlurViewAtBack(_ blurView: NSObject, into contentView: NSObject) {
            let addSubviewSelector = NSSelectorFromString("addSubview:positioned:relativeTo:")
            if contentView.responds(to: addSubviewSelector) {
                let addMethod = contentView.method(for: addSubviewSelector)
                typealias AddSubviewFunction = @convention(c) (NSObject, Selector, NSObject, Int, NSObject?) -> Void
                let addFunc = unsafeBitCast(addMethod, to: AddSubviewFunction.self)
                // -1 = NSWindowBelow - insert behind all other subviews
                addFunc(contentView, addSubviewSelector, blurView, -1, nil)
            }
        }

        /// Remove blur view from a window
        private func removeVisualEffectBlurFromWindow(_ window: NSObject) {
            guard let contentView = window.value(forKey: "contentView") as? NSObject,
                  let subviews = contentView.value(forKey: "subviews") as? [NSObject] else {
                return
            }

            for subview in subviews {
                if let identifier = subview.value(forKey: "identifier") as? String, identifier == Self.blurViewIdentifier {
                    if subview.responds(to: NSSelectorFromString("removeFromSuperview")) {
                        subview.perform(NSSelectorFromString("removeFromSuperview"))
                    }
                    break
                }
            }
        }
        #endif

        /// Register a surface to receive config updates
        /// - Parameter surface: The ghostty_surface_t pointer
        func registerSurface(_ surface: ghostty_surface_t) {
            let ptr = UnsafeMutableRawPointer(mutating: surface)
            activeSurfaces.insert(ptr)
            logger.debug("Registered surface, total active: \(self.activeSurfaces.count)")

            // Sync the global HDR brightness gain to this newly registered
            // (or restored) surface so it matches every other surface.
            ghostty_surface_set_brightness(ptr, Float(BrightnessManager.shared.effectiveGain))

            // Sync the current power-tier frame-rate range so surfaces created
            // while throttled (Low Power Mode, manual cap) match the rest.
            let range = PowerManager.shared.coreFrameRange
            if range.max != 0 {
                ghostty_surface_set_frame_rate_range(ptr, range.min, range.max, range.preferred)
            }

            // Sync the auto-redact needle set so surfaces created while
            // redaction is on mask sensitive strings from their first frame.
            let redaction = RedactionManager.shared
            if redaction.isEnabled, redaction.isConfigured {
                Self.pushRedaction(redaction.needleStrings, to: ptr)
            }

            // Notify that surface count changed (triggers window configuration update)
            surfaceCountDidChange.send()
        }

        /// Unregister a surface from config updates
        /// - Parameter surface: The ghostty_surface_t pointer
        func unregisterSurface(_ surface: ghostty_surface_t) {
            let ptr = UnsafeMutableRawPointer(mutating: surface)
            activeSurfaces.remove(ptr)

            // Also remove from window map
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap.removeValue(forKey: surfaceId)

            // Notify that surface count changed (triggers window configuration update)
            surfaceCountDidChange.send()

            logger.debug("Unregistered surface, total active: \(self.activeSurfaces.count)")
        }

        // MARK: - Window Association Management

        /// Register a surface's association with a window
        /// - Parameters:
        ///   - surface: The ghostty_surface_t pointer
        ///   - windowId: The window identifier
        func registerSurfaceWindow(_ surface: ghostty_surface_t, windowId: String) {
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap[surfaceId] = windowId
            logger.debug("Registered surface \(String(format: "0x%lx", surfaceId)) to window \(windowId)")
        }

        /// Unregister a surface's window association
        /// - Parameter surface: The ghostty_surface_t pointer
        func unregisterSurfaceWindow(_ surface: ghostty_surface_t) {
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap.removeValue(forKey: surfaceId)
            logger.debug("Unregistered surface \(String(format: "0x%lx", surfaceId)) from window")
        }

        /// Get the window ID for a surface
        /// - Parameter surface: The ghostty_surface_t pointer
        /// - Returns: The window ID if registered, nil otherwise
        func getWindowId(for surface: ghostty_surface_t) -> String? {
            let surfaceId = Int(bitPattern: surface)
            return surfaceWindowMap[surfaceId]
        }

        // MARK: - Tab Association Management

        /// Register a surface's association with a tab
        /// - Parameters:
        ///   - surface: The ghostty_surface_t pointer
        ///   - tabId: The tab UUID
        func registerSurfaceTab(_ surface: ghostty_surface_t, tabId: UUID) {
            let surfaceId = Int(bitPattern: surface)
            surfaceTabMap[surfaceId] = tabId
            logger.debug("Registered surface \(String(format: "0x%lx", surfaceId)) to tab \(tabId)")
        }

        /// Unregister a surface's tab association
        /// - Parameter surface: The ghostty_surface_t pointer
        func unregisterSurfaceTab(_ surface: ghostty_surface_t) {
            let surfaceId = Int(bitPattern: surface)
            surfaceTabMap.removeValue(forKey: surfaceId)
            logger.debug("Unregistered surface \(String(format: "0x%lx", surfaceId)) from tab")
        }

        /// Get the tab ID for a surface
        /// - Parameter surface: The ghostty_surface_t pointer
        /// - Returns: The tab UUID if registered, nil otherwise
        func getTabId(for surface: ghostty_surface_t) -> UUID? {
            let surfaceId = Int(bitPattern: surface)
            return surfaceTabMap[surfaceId]
        }

        // MARK: - Surface Delegate Management

        func registerSurfaceDelegate(_ surface: ghostty_surface_t, delegate: GhosttyActionDelegate) {
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let surfaceId = Int(bitPattern: surface)
            surfaceDelegates[surfaceId] = WeakActionDelegate(delegate: delegate)
        }

        func unregisterSurfaceDelegate(_ surface: ghostty_surface_t) {
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let surfaceId = Int(bitPattern: surface)
            surfaceDelegates.removeValue(forKey: surfaceId)
        }

        /// The live `TerminalView` registered as `surface`'s action delegate, or
        /// nil when no live view owns it. Every `TerminalView` registers itself
        /// here for its own surface (it IS the `GhosttyActionDelegate`).
        ///
        /// This resolves a possibly-stale raw `ghostty_surface_t` WITHOUT
        /// dereferencing it — the safe alternative to `ghostty_surface_userdata`
        /// when the pointer was saved elsewhere and may now dangle (e.g. a tmux
        /// pane's `parentSurface`, which outlives its gateway). The map is keyed
        /// by pointer VALUE (no surface deref) and holds the view WEAKLY; its
        /// entry is removed synchronously (main actor) in `TerminalView.cleanup()`
        /// before the surface is freed on a background queue, and the weak ref
        /// independently drops to nil if the view deallocates via the deinit
        /// safety-net. So a non-nil result is always a live view whose surface is
        /// still alive — there is no window where it returns a freed object.
        /// (id=tmux-stale-parent-surface)
        func surfaceView(for surface: ghostty_surface_t) -> TerminalView? {
            surfaceDelegates[Int(bitPattern: surface)]?.delegate as? TerminalView
        }

        // MARK: - Runtime Callbacks

        /// Count wakeup calls for diagnostics (instance properties for MainActor isolation)
        private var wakeupCount: Int = 0
        private var lastWakeupLogTime: CFAbsoluteTime = 0

        /// Total wakeup calls received (incremented from any thread).
        /// `wakeupTaskPending` flips false→true to schedule a single Task per
        /// burst; the Task clears the flag before draining the mailbox so any
        /// later wakeup re-arms the next Task. This collapses N wakeup_cb
        /// calls per frame into ≤1 main-actor task per frame and prevents the
        /// queue from growing unbounded while the app is backgrounded.
        private nonisolated static let wakeupCoalescer = OSAllocatedUnfairLock(initialState: WakeupCoalescerState())
        private nonisolated static let deferredResumeTickPending = OSAllocatedUnfairLock(initialState: false)

        private nonisolated struct WakeupCoalescerState {
            var pending: Bool = false
            var coalescedDuringBurst: Int = 0
        }

        private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata = userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()

            // Atomic: only the false→true transition schedules a Task. All
            // other wakeup_cb calls increment the coalesced counter so the
            // diagnostic log can show how aggressive the coalescing was.
            let shouldSpawn: Bool = wakeupCoalescer.withLock { state in
                if state.pending {
                    state.coalescedDuringBurst &+= 1
                    return false
                }
                state.pending = true
                return true
            }
            guard shouldSpawn else { return }

            Task { @MainActor in
                app.wakeupCount += 1
                let now = CFAbsoluteTimeGetCurrent()

                if Ghostty.isAppBackgroundedAtomic {
                    LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                    let coalesced = wakeupCoalescer.withLock { state -> Int in
                        let coalesced = state.coalescedDuringBurst
                        state.coalescedDuringBurst = 0
                        state.pending = false
                        return coalesced
                    }
                    if now - app.lastWakeupLogTime > 5.0 {
                        let count = app.wakeupCount
                        logger.debug("Ghostty wakeup dropped while backgrounded: \(count) tasks in last 5s (coalesced \(coalesced) extra calls)")
                        app.wakeupCount = 0
                        app.lastWakeupLogTime = now
                    }
                    return
                }

                if BisectFlags.gate3_appTick && Ghostty.isInResumeQuietWindowAtomic {
                    LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                    let coalesced = wakeupCoalescer.withLock { state -> Int in
                        let coalesced = state.coalescedDuringBurst
                        state.coalescedDuringBurst = 0
                        state.pending = false
                        return coalesced
                    }
                    if now - app.lastWakeupLogTime > 5.0 {
                        if app.wakeupCount > 0 {
                            let count = app.wakeupCount
                            logger.debug("Ghostty wakeup deferred during resume quiet window: \(count) tasks in last 5s (coalesced \(coalesced) extra calls)")
                        }
                        app.wakeupCount = 0
                        app.lastWakeupLogTime = now
                    }
                    scheduleDeferredResumeTick(for: app)
                    return
                }

                // Drain the mailbox first. Any wakeup_cb that fires during the
                // tick (from IO-thread activity that the tick itself triggers)
                // increments `coalescedDuringBurst` but does NOT enqueue a new
                // Task — we still own the pending bit. After the tick we read
                // and clear the counters atomically; if any wakeups arrived,
                // we schedule one follow-up Task to drain the new state.
                app.appTick()

                let result = wakeupCoalescer.withLock { state -> (coalesced: Int, needsFollowup: Bool) in
                    let coalesced = state.coalescedDuringBurst
                    state.coalescedDuringBurst = 0
                    if coalesced > 0 {
                        // Keep `pending = true` so coalescedDuringBurst keeps
                        // accumulating in the new Task. The follow-up Task
                        // will release the bit when it returns to idle.
                        return (coalesced, true)
                    }
                    state.pending = false
                    return (coalesced, false)
                }

                if now - app.lastWakeupLogTime > 5.0 {
                    if app.wakeupCount > 0 {
                        let count = app.wakeupCount
                        logger.debug("Ghostty wakeup: \(count) tasks in last 5s (coalesced \(result.coalesced) extra calls)")
                    }
                    app.wakeupCount = 0
                    app.lastWakeupLogTime = now
                }

                if result.needsFollowup {
                    Task { @MainActor in
                        // Single follow-up tick then yield the bit. If more
                        // wakeups arrive after that yield, the next wakeup_cb
                        // call sees pending=false and starts a fresh chain.
                        if Ghostty.isAppBackgroundedAtomic {
                            LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                            wakeupCoalescer.withLock { state in
                                state.pending = false
                                state.coalescedDuringBurst = 0
                            }
                            return
                        }
                        if BisectFlags.gate3_appTick && Ghostty.isInResumeQuietWindowAtomic {
                            LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                            wakeupCoalescer.withLock { state in
                                state.pending = false
                                state.coalescedDuringBurst = 0
                            }
                            scheduleDeferredResumeTick(for: app)
                            return
                        }
                        app.appTick()
                        wakeupCoalescer.withLock { state in
                            state.pending = false
                            state.coalescedDuringBurst = 0
                        }
                    }
                }
            }
        }

        private static func scheduleDeferredResumeTick(for app: App) {
            let shouldSchedule = deferredResumeTickPending.withLock { pending -> Bool in
                guard !pending else { return false }
                pending = true
                return true
            }
            guard shouldSchedule else { return }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                deferredResumeTickPending.withLock { $0 = false }
                guard !Ghostty.isAppBackgroundedAtomic else {
                    LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                    return
                }
                if BisectFlags.gate3_appTick && Ghostty.isInResumeQuietWindowAtomic {
                    LifecycleDebugLogger.shared.bumpSuppression("gate3_appTick")
                    scheduleDeferredResumeTick(for: app)
                    return
                }
                app.appTick()
            }
        }

        private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Look up the App instance using raw pointer address
            let appId = Int(bitPattern: app)

            guard let appInstance = appInstances[appId]?.value else {
                Ghostty.logger.error("Action callback: No App instance found for pointer \(String(format: "0x%lx", appId))")
                return true
            }

            // Drop UI-state action callbacks while backgrounded so the
            // post-resume Task storm doesn't trip the scene-update watchdog
            // (0x8BADF00D). Each gate-safe case checks `isBackgrounded` early
            // and returns. Without this, the C-side mailbox keeps producing
            // events while backgrounded (servers continue to send prompts,
            // titles, scrollbar updates etc.); each event spawned a
            // `Task { @MainActor in ... }` from the IO thread; on resume,
            // hundreds-to-thousands of those Tasks flushed at once and
            // bogged down the main thread for >30s. Latest-state-wins is the
            // correct invariant here — the next post-resume event resyncs.
            //
            // Exceptions (NOT gated):
            //   - DESKTOP_NOTIFICATION: user-visible alert; must fire while
            //     backgrounded so notifications go through.
            //   - MOUSE_OVER_LINK: synchronous call, no Task spawned.
            //   - OPEN_URL: rare and user-initiated.
            let isBackgrounded = Ghostty.isAppBackgroundedAtomic

            // Handle specific actions
            switch action.tag {
            case GHOSTTY_ACTION_SURFACE_CONTENT_CHANGED:
                if isBackgrounded { return true }
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surfaceId = Int(bitPattern: target.target.surface)
                    Task { @MainActor in
                        appInstance.surfaceDelegates[surfaceId]?.delegate?
                            .handleSurfaceContentChanged()
                    }
                }
                return true

            case GHOSTTY_ACTION_SET_TITLE:
                if isBackgrounded { return true }
                let titleAction = action.action.set_title

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    guard let titleCStr = titleAction.title else { return true }
                    guard let title = String(cString: titleCStr, encoding: .utf8) else { return true }

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleTitleChange(title)
                        } else {
                            Ghostty.logger.error("No delegate found for set_title action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Set title action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_TMUX_RECONCILE:
                // tmux control mode topology reconcile. The payload is an
                // opaque *TmuxReconcilePayload (heap-allocated by the core);
                // we own it and must free it with ghostty_tmux_reconcile_free.
                // The op batch carries live viewer_terminal/viewer_pane
                // pointers, so it must be applied synchronously here (on the
                // ghostty tick / main thread) before any subsequent reconcile.
                //
                // Phase 2 routes these ops to the surface's TmuxController to
                // map windows->tabs and panes->splits. For now we walk the
                // batch to validate the C ABI end to end, then free it.
                if target.tag == GHOSTTY_TARGET_SURFACE,
                   let payload = action.action.tmux_reconcile {
                    let surface = target.target.surface
                    // Decode synchronously (reads the payload's op accessors).
                    // Do NOT free the payload yet: it holds viewer-pane refcounts
                    // (Zig id=viewer-snapshot-refcount) that keep the panes whose
                    // raw pointers the ops carry alive until applyTmuxReconcile has
                    // used them on the main actor. Free it AFTER apply.
                    let ops = TmuxReconcileDecoder.decode(payload)
                    // Off-main anchor (runs on the ghostty tick thread): keeps
                    // firing even if the main actor wedges, so a "decoded" line
                    // with no following "apply begin" is the wedge fingerprint.
                    let surfaceSuffix = String(UInt(bitPattern: Int(bitPattern: surface)), radix: 16).suffix(6)
                    TmuxDebugLogger.shared.event("RECONCILE", "decoded ops=\(ops.count) surface=\(surfaceSuffix)")
                    // Route to the viewer-owner surface's TerminalView, which
                    // owns the per-connection TmuxController. The payload's
                    // refcounts keep the viewer pane boxes alive across this hop,
                    // so applying on the next main-actor turn is safe.
                    if let userdata = ghostty_surface_userdata(surface) {
                        // Take a STRONG ref to the owner here, while the surface
                        // (and its userdata owner) is still alive, and carry it
                        // across the hop. The payload refcounts protect the viewer
                        // panes but NOT this Swift owner; closing the tab/surface
                        // before the task runs would otherwise use freed memory.
                        let owner = Unmanaged<Ghostty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        let delivery = TmuxReconcileDelivery(owner: owner, ops: ops, payload: payload)
                        // Serialize the apply in ARRIVAL order. The action callback
                        // is off the main actor and a bare per-batch Task has no
                        // cross-task ordering guarantee, so a stale full-topology
                        // snapshot could otherwise land after a newer one and
                        // resurrect a closed pane / stale layout. See
                        // id=tmux-reconcile-serialize.
                        TmuxReconcileSerializer.shared.enqueue {
                            delivery.owner.applyTmuxReconcile(delivery.ops)
                            // Release the payload (and its viewer-pane holds) only
                            // now that apply has consumed the raw pointers.
                            ghostty_tmux_reconcile_free(delivery.payload)
                        }
                    } else {
                        // No owner surface to apply to: nothing will use the
                        // pointers, so free now (releases the pane holds).
                        ghostty_tmux_reconcile_free(payload)
                    }
                }
                return true

            case GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE:
                // Response to an app-issued tmux query (session dashboard).
                // The body pointer is borrowed for THIS callback only — copy
                // it here on the callback thread, then hop. Tag-keyed (no
                // ordering requirement), so a bare Task is fine; do NOT route
                // through TmuxReconcileSerializer (would add latency behind
                // topology applies). Never gated on isBackgrounded: a pending
                // continuation must always resolve.
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let response = action.action.tmux_command_response
                    let body: String
                    if let ptr = response.body, response.body_len > 0 {
                        body = String(decoding: UnsafeBufferPointer(start: ptr, count: Int(response.body_len)), as: UTF8.self)
                    } else {
                        body = ""
                    }
                    let reply = TmuxCommandReply(tag: response.tag, body: body, isError: response.is_err)
                    if let userdata = ghostty_surface_userdata(surface) {
                        let owner = Unmanaged<Ghostty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            owner.tmuxController?.handleCommandReply(reply)
                        }
                    }
                }
                return true

            case GHOSTTY_ACTION_TMUX_SESSIONS_CHANGED:
                // Session list churn on the tmux server: nudge the dashboard.
                // Rare event; cheap notification; not gated on isBackgrounded
                // (the dashboard also refreshes on appear, so a dropped nudge
                // would only matter mid-display anyway).
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    if let userdata = ghostty_surface_userdata(surface) {
                        let owner = Unmanaged<Ghostty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            owner.tmuxController?.noteSessionsChanged()
                        }
                    }
                }
                return true

            case GHOSTTY_ACTION_TMUX_SESSION_CHANGED:
                // The session this gateway is attached to (startup / switch /
                // rename). Copy the borrowed name on the callback thread.
                // Not gated on isBackgrounded: it drives the per-connection
                // reconnect-name persistence, which must stay correct.
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let info = action.action.tmux_session_changed
                    let name: String
                    if let ptr = info.name, info.name_len > 0 {
                        name = String(decoding: UnsafeBufferPointer(start: ptr, count: Int(info.name_len)), as: UTF8.self)
                    } else {
                        name = ""
                    }
                    let sessionId = Int(clamping: info.session_id)
                    if let userdata = ghostty_surface_userdata(surface) {
                        let owner = Unmanaged<Ghostty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            if let controller = owner.tmuxController {
                                controller.updateCurrentSession(id: sessionId, name: name)
                            } else {
                                // Startup ordering: the identity arrives before
                                // the first reconcile creates the controller.
                                // Stash it; applyTmuxReconcile flushes it.
                                // ROOTSHELL-TMUX (id=tmux-session-info-stash)
                                owner.pendingTmuxSessionInfo = (id: sessionId, name: name)
                            }
                        }
                    }
                }
                return true

            case GHOSTTY_ACTION_PWD:
                if isBackgrounded { return true }
                let pwdAction = action.action.pwd

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    guard let pwdCStr = pwdAction.pwd else { return true }
                    guard let pwd = String(cString: pwdCStr, encoding: .utf8) else { return true }

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handlePwdChange(pwd)
                        } else {
                            Ghostty.logger.error("No delegate found for pwd action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("PWD action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_RING_BELL:
                if isBackgrounded { return true }
                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleBell()
                        } else {
                            Ghostty.logger.error("No delegate found for ring_bell action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Ring bell action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                if isBackgrounded { return true }
                let mouseShape = action.action.mouse_shape

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let shape = Int(mouseShape.rawValue)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleMouseShape(shape: shape)
                        } else {
                            Ghostty.logger.error("No delegate found for mouse_shape action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Mouse shape action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                if isBackgrounded { return true }
                let visibility = action.action.mouse_visibility

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let visible = (visibility == GHOSTTY_MOUSE_VISIBLE)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleMouseVisibility(visible: visible)
                        } else {
                            Ghostty.logger.error("No delegate found for mouse_visibility action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Mouse visibility action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                let notificationAction = action.action.desktop_notification

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let title = notificationAction.title != nil ? String(cString: notificationAction.title!, encoding: .utf8) : nil
                    let body = notificationAction.body != nil ? String(cString: notificationAction.body!, encoding: .utf8) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleDesktopNotification(title: title, body: body)
                        } else {
                            Ghostty.logger.error("No delegate found for desktop_notification action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Desktop notification action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_SCROLLBAR:
                if isBackgrounded { return true }
                let scrollbar = action.action.scrollbar

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleScrollbar(
                                total: scrollbar.total,
                                offset: scrollbar.offset,
                                len: scrollbar.len
                            )
                        } else {
                            Ghostty.logger.error("No delegate found for surface \(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Scrollbar action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_COMMAND_FINISHED:
                // Not gated on isBackgrounded: a command finishing while
                // backgrounded must still set the unseen done/failed flags.
                let finished = action.action.command_finished
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)
                    let exitCode: Int? = finished.exit_code >= 0 ? Int(finished.exit_code) : nil
                    let duration = TimeInterval(finished.duration) / 1_000_000_000

                    Task { @MainActor in
                        appInstance.surfaceDelegates[surfaceId]?.delegate?
                            .handleCommandFinished(exitCode: exitCode, duration: duration)
                    }
                }
                return true

            case GHOSTTY_ACTION_CELL_SIZE:
                if isBackgrounded { return true }
                let cellSize = action.action.cell_size

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleCellSizeChange(
                                width: CGFloat(cellSize.width),
                                height: CGFloat(cellSize.height)
                            )
                        } else {
                            Ghostty.logger.error("No delegate found for cell size action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Cell size action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                if isBackgrounded { return true }
                let progressReportAction = action.action.progress_report

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let report = Ghostty.Action.ProgressReport(c: progressReportAction)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleProgressReport(report)
                        } else {
                            Ghostty.logger.error("No delegate found for progress_report action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Progress report action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_START_SEARCH:
                if isBackgrounded { return true }
                let startSearchAction = action.action.start_search

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let startSearch = Ghostty.Action.StartSearch(c: startSearchAction)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleStartSearch(startSearch)
                        } else {
                            Ghostty.logger.error("No delegate found for start_search action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Start search action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_END_SEARCH:
                if isBackgrounded { return true }
                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleEndSearch()
                        } else {
                            Ghostty.logger.error("No delegate found for end_search action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("End search action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_SEARCH_TOTAL:
                if isBackgrounded { return true }
                let searchTotal = action.action.search_total

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let total: UInt? = searchTotal.total >= 0 ? UInt(searchTotal.total) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleSearchTotal(total)
                        } else {
                            Ghostty.logger.error("No delegate found for search_total action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Search total action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_SEARCH_SELECTED:
                if isBackgrounded { return true }
                let searchSelected = action.action.search_selected

                // Route to the appropriate surface delegate
                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let selected: UInt? = searchSelected.selected >= 0 ? UInt(searchSelected.selected) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleSearchSelected(selected)
                        } else {
                            Ghostty.logger.error("No delegate found for search_selected action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Ghostty.logger.warning("Search selected action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                let mouseOverLink = action.action.mouse_over_link

                if target.tag == GHOSTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let url: String?
                    if let urlPtr = mouseOverLink.url, mouseOverLink.len > 0 {
                        let buf = UnsafeRawBufferPointer(start: urlPtr, count: Int(mouseOverLink.len))
                        url = String(bytes: buf, encoding: .utf8)
                    } else {
                        url = nil
                    }

                    // Call delegate synchronously — probeForLink() depends on this
                    // being resolved before ghostty_surface_mouse_pos() returns.
                    if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                        delegate.handleMouseOverLink(url: url)
                    }
                }

                return true

            case GHOSTTY_ACTION_OPEN_URL:
                let openUrl = action.action.open_url
                guard let urlPtr = openUrl.url, openUrl.len > 0 else { return true }
                let buf = UnsafeRawBufferPointer(start: urlPtr, count: Int(openUrl.len))
                let urlString = String(bytes: buf, encoding: .utf8) ?? ""

                Task { @MainActor in
                    guard let url = URL(string: urlString) else { return }
                    await UIApplication.shared.open(url)
                }

                return true

            default:
                return true
            }
        }

        private static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) -> Bool {
            #if os(iOS) || os(visionOS)
            // Extract TerminalView from userdata (same pattern as macOS SurfaceView)
            // For clipboard operations, Ghostty passes the surface's userdata, not the app's
            guard let userdata = userdata else {
                Ghostty.logger.warning("readClipboard called with nil userdata")
                return false
            }
            let terminalView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = terminalView.surface else {
                Ghostty.logger.warning("readClipboard: surface is nil")
                return false
            }

            // Return false if there is no text-like clipboard content so
            // performable paste bindings can pass through to the terminal.
            guard let text = UIPasteboard.general.getOpinionatedStringContents() else {
                return false
            }

            // Complete the clipboard request with the data
            // This triggers Ghostty's paste encoding (bracketed paste, newline conversion, etc.)
            text.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
            #else
            return false
            #endif
        }

        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            #if os(iOS) || os(visionOS)
            // Ghostty detected potentially unsafe paste (e.g., multi-line content)
            // and is asking for confirmation.
            // In a mobile app context, we auto-confirm since the user's intent is clear
            // (whether via UI action or OSC-52 request from a terminal app they're running).
            guard let userdata = userdata else { return }
            guard let string = string else { return }

            let terminalView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = terminalView.surface else { return }

            // Complete the request with confirmation (last parameter = true)
            ghostty_surface_complete_clipboard_request(surface, string, state, true)
            #endif
        }

        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            #if os(iOS) || os(visionOS)
            guard let content = content, len > 0 else { return }

            // Ghostty can emit multiple representations for a single copy (e.g.
            // `.mixed` emits text/plain + text/html). Route each to its proper
            // UIPasteboard UTI so HTML markup never lands in the plain-text slot.
            // Keep the callback payload Sendable so off-main UIKit and
            // observable state work can be deferred until after Ghostty
            // releases its surface mutex.
            var item: [String: String] = [:]
            for i in 0..<len {
                let entry = content[i]
                guard let mimePtr = entry.mime, let dataPtr = entry.data else { continue }
                let mime = String(cString: mimePtr)
                let data = String(cString: dataPtr)
                guard !data.isEmpty else { continue }
                guard let uti = Self.pasteboardUTI(forMime: mime) else { continue }
                item[uti] = data
            }

            guard !item.isEmpty else { return }

            // The selection clipboard means
            // copy-on-select; anything else arriving here is an OSC 52 write
            // from a program running in the session (explicit Copy never
            // routes through this callback on iOS).
            //
            // Copy-on-select invokes this callback on the surface API queue while
            // still holding the surface mutex. UIPasteboard notifications may
            // synchronously target the main queue, while the main thread can be
            // waiting on that same mutex for a surface query. Defer that off-main
            // path. Main-thread callbacks must update the pasteboard synchronously:
            // Ghostty drains ordered OSC 52 writes and reads during one app tick, so
            // a following read must see this write before the callback returns.
            //
            // Resolve the surface's userdata to a strong TerminalView reference
            // here (a thread-safe retain / pointer arithmetic), then read its
            // @MainActor-isolated `title`/`connectionConfig` INSIDE the main-actor
            // task. Capturing the strong reference keeps the view alive across the
            // hop; the property reads never happen off the main actor.
            let text = item[UTType.utf8PlainText.identifier]
            let isSelection = (location == GHOSTTY_CLIPBOARD_SELECTION)
            let terminalView = text.flatMap { _ in
                userdata.map {
                    Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue()
                }
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    Self.applyPasteboardItem(item)
                }
                // Preserve the existing asynchronous history capture. Only the
                // system pasteboard participates in OSC 52 write/read ordering.
                Task { @MainActor in
                    Self.recordClipboardHistory(
                        text: text,
                        isSelection: isSelection,
                        terminalView: terminalView)
                }
            } else {
                Task { @MainActor in
                    Self.applyPasteboardItem(item)
                    Self.recordClipboardHistory(
                        text: text,
                        isSelection: isSelection,
                        terminalView: terminalView)
                }
            }
            #endif
        }

        #if os(iOS) || os(visionOS)
        @MainActor
        private static func applyPasteboardItem(_ item: [String: String]) {
            var pasteboardItem: [String: Any] = [:]
            for (uti, value) in item {
                pasteboardItem[uti] = value
            }
            UIPasteboard.general.items = [pasteboardItem]
        }

        @MainActor
        private static func recordClipboardHistory(
            text: String?,
            isSelection: Bool,
            terminalView: TerminalView?
        ) {
            guard let text else { return }
            let source: ClipboardEntry.Source
            if isSelection {
                source = .selectionCopy
            } else {
                var label = String(localized: "Remote session", comment: "Fallback clipboard-history source label for an OSC 52 write")
                if let terminalView {
                    label = (terminalView.title != "ghostty")
                        ? terminalView.title
                        : terminalView.connectionConfig.displayName
                }
                source = .osc52(sessionLabel: label)
            }
            ClipboardHistoryManager.shared.record(text, source: source)
        }

        /// Map a Ghostty clipboard mime type to the corresponding UIPasteboard UTI.
        /// Mirrors the macOS mapping in `NSPasteboard+Extension.swift`.
        private static func pasteboardUTI(forMime mime: String) -> String? {
            switch mime {
            case "text/plain":
                return UTType.utf8PlainText.identifier
            case "text/html":
                return UTType.html.identifier
            default:
                return UTType(mimeType: mime)?.identifier
            }
        }
        #endif

        private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let userdata = userdata else { return }
            _ = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()

            // Notify delegate
            Task { @MainActor in
                // TODO: Determine which surface to close
                // app.delegate?.closeSurface(uuid: uuid, processAlive: processAlive)
            }
        }
    }
}
