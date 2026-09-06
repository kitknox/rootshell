//
//  TerminalSurfaceController.swift
//  rootshell
//
//  Owns Ghostty surface lifecycle details on behalf of TerminalView.
//

import UIKit
import os
import GhosttyKit

@MainActor
protocol TerminalSurfaceHost: AnyObject {
    var surfaceUserdata: AnyObject { get }
    var surfaceView: UIView { get }
    var surfaceLayer: CALayer { get }
    var surfaceAppPointer: ghostty_app_t? { get }
    var surfaceGhosttyApp: Ghostty.App? { get }
    var surfaceWindowID: String { get }
    var surfaceContainingTabID: UUID? { get }
    var surfaceTerminalDebugID: String { get }
    var surfaceConnectionConfig: ConnectionConfig { get }
    var surfaceTmuxPaneBinding: Ghostty.TerminalView.TmuxPaneBinding? { get }
    var surfaceIsTmuxPane: Bool { get }
    var surfaceTmuxPaneContainerLaidOut: Bool { get }
    var surfaceTmuxPaneRetired: Bool { get }
    var surfaceTmuxDetachInProgress: Bool { get }
    nonisolated var surfaceTmuxDetachInProgressAtomic: Bool { get }
    var surfaceIsTabVisible: Bool { get set }
    func surfaceInitialTabVisibility() -> Bool
    var surfacePendingScrollbackRestore: Bool { get set }
    var surfacePendingScrollbackRestoreForLayout: Bool { get set }
    var surfaceRestorationState: Ghostty.TerminalView.RestorationState { get }
    var surfaceOutputPipeline: TerminalOutputPipeline { get }
    var surfaceLogFrequentLayout: Bool { get }
    var surfaceSuppressBottomInsetUpdatesForScrollRubberBand: Bool { get }
    var surfaceCurrentBottomInsetPixels: Double { get }

    func surfaceControllerDidSetSurface(_ surface: ghostty_surface_t?)
    func surfaceRegisterForScrollbackPersistence()
    func surfaceSetupThemeOverrideSubscription()
    func surfaceApplyRestoredFontSizeOverrideIfNeeded()
    func surfaceDidNeedSessionSetup()
    func surfaceRunLayoutDeferredScrollbackRestore()
    func surfaceUpdatePTYSize()
    func surfaceGeometryDidChange()
    func surfaceFirstFrameDidFailOpen()
}

@MainActor
final class TerminalSurfaceController: NSObject {
    private unowned let host: TerminalSurfaceHost

    private(set) var surface: ghostty_surface_t?
    var slaveFd: Int32 = -1
    var responseFd: Int32 = -1

    private(set) var hasRenderedFirstFrame = false
    private var firstFrameCallbacks: [@MainActor () -> Void] = []
    private var firstFramePollLink: CADisplayLink?
    private var firstFramePollTarget: FirstFramePollTarget?
    private var firstFramePollStart: CFTimeInterval = 0

    private var lastFramebufferSize: (width: UInt32, height: UInt32)?
    private var lastContentScaleFactor: CGFloat?
    private var lastSentGridSize: (rows: UInt16, cols: UInt16)?
    private var lastSizedSessionID: ObjectIdentifier?
    private var lastBottomInsetPx: Double = -1
    private var suppressSizeUpdates = false

    init(host: TerminalSurfaceHost) {
        self.host = host
        super.init()
    }

    deinit {
        firstFramePollLink?.invalidate()
    }

    var surfaceSize: ghostty_surface_size_s? {
        guard let surface else { return nil }
        return ghostty_surface_size(surface)
    }

    var sizeUpdatesSuppressed: Bool {
        suppressSizeUpdates || Ghostty.isAppBackgroundedAtomic
    }

    func setSizeUpdatesSuppressed(_ suppressed: Bool) {
        suppressSizeUpdates = suppressed
    }

    @discardableResult
    func clearSizeSuppression() -> Bool {
        guard suppressSizeUpdates else { return false }
        suppressSizeUpdates = false
        return true
    }

    func invalidateCachedSize() {
        lastFramebufferSize = nil
        lastContentScaleFactor = nil
        lastSentGridSize = nil
    }

    func shouldSendPTYSize(for sessionID: ObjectIdentifier, gridSize: (rows: UInt16, cols: UInt16)) -> Bool {
        if lastSizedSessionID != sessionID {
            lastSizedSessionID = sessionID
            lastSentGridSize = nil
        }
        return lastSentGridSize.map { $0 != gridSize } ?? true
    }

    func markPTYSizeSent(_ gridSize: (rows: UInt16, cols: UInt16)) {
        lastSentGridSize = gridSize
    }

    var lastSentPTYGridDescription: String {
        lastSentGridSize.map { "\($0.rows)x\($0.cols)" } ?? "nil"
    }

    func notifyOnFirstFrame(_ callback: @escaping @MainActor () -> Void) {
        if hasRenderedFirstFrame {
            callback()
        } else {
            firstFrameCallbacks.append(callback)
        }
    }

    /// The core's "IOSurfaceLayer": each presented frame lands in its `contents`.
    func rendererLayer() -> CALayer? {
        host.surfaceLayer.sublayers?.first {
            String(cString: object_getClassName($0)) == "IOSurfaceLayer"
        }
    }

    private func startFirstFramePolling() {
        guard firstFramePollLink == nil,
              !hasRenderedFirstFrame,
              host.surfaceIsTabVisible,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }
        firstFramePollStart = CACurrentMediaTime()
        let target = FirstFramePollTarget(controller: self)
        let link = CADisplayLink(target: target, selector: #selector(FirstFramePollTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        firstFramePollTarget = target
        firstFramePollLink = link
    }

    fileprivate func firstFramePollTick() {
        guard host.surfaceIsTabVisible,
              !Ghostty.isSecureDrawProhibitedAtomic else {
            suspendFirstFramePolling()
            return
        }
        if rendererLayer()?.contents != nil {
            markFirstFrameRendered()
        } else if CACurrentMediaTime() - firstFramePollStart > 2.0 {
            markFirstFrameRendered(failOpen: true)
        }
    }

    private func markFirstFrameRendered(failOpen: Bool = false) {
        // Visibility can change on the same main-run-loop turn as a poll tick.
        // Keep first-frame tracking pending when the surface is now hidden so a
        // later selection can restart it; never promote a hidden pane to visible.
        if failOpen && (!host.surfaceIsTabVisible || Ghostty.isSecureDrawProhibitedAtomic) {
            suspendFirstFramePolling()
            return
        }
        suspendFirstFramePolling()
        guard !hasRenderedFirstFrame else { return }
        hasRenderedFirstFrame = true
        if failOpen {
            Ghostty.logger.warning("First frame poll timed out; treating surface as rendered")
            if host.surfaceIsTmuxPane {
                host.surfaceFirstFrameDidFailOpen()
            }
        }
        let callbacks = firstFrameCallbacks
        firstFrameCallbacks = []
        for callback in callbacks { callback() }
    }

    private func suspendFirstFramePolling() {
        firstFramePollLink?.invalidate()
        firstFramePollLink = nil
        firstFramePollTarget = nil
    }

    func resetFirstFrameTracking() {
        suspendFirstFramePolling()
        hasRenderedFirstFrame = false
        firstFrameCallbacks = []
    }

    func createSurfaceIfNeeded() {
        guard surface == nil else { return }
        createSurface()
    }

    private func createTmuxPaneSurface(
        app: ghostty_app_t,
        cfg: inout ghostty_surface_config_s,
        binding: Ghostty.TerminalView.TmuxPaneBinding
    ) {
        let surface = ghostty_surface_new_tmux_pane(
            app,
            binding.parentSurface,
            UInt(binding.windowId),
            UInt(binding.paneId),
            binding.viewerTerminal,
            binding.viewerPane,
            &cfg)

        guard let surface else {
            Ghostty.logger.error("Failed to create tmux pane surface (window=\(binding.windowId) pane=\(binding.paneId))")
            TmuxDebugLogger.shared.event("PANE", "create FAILED win=\(binding.windowId) pane=\(binding.paneId)")
            return
        }

        installSurface(surface)

        if let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
           let target = controller.overrideFontSize(forWindowId: binding.windowId) {
            let delta = Int((target - FontManager.shared.currentFontSize).rounded())
            if delta != 0 {
                host.surfaceGhosttyApp?.changeFontSize(surface: surface, delta: delta)
            }
        }

        setInitialOcclusion(on: surface)
        Ghostty.logger.info("tmux pane surface created (window=\(binding.windowId) pane=\(binding.paneId))")
        TmuxDebugLogger.shared.event("PANE", "created win=\(binding.windowId) pane=\(binding.paneId)")
        startFirstFramePolling()
    }

    private func createSurface() {
        Ghostty.logger.info("createSurface() called, checking appPtr...")

        guard let app = host.surfaceAppPointer else {
            Ghostty.logger.error("Cannot create surface: app pointer is nil")
            return
        }

        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceCfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(host.surfaceView).toOpaque()
        ))
        surfaceCfg.userdata = Unmanaged.passUnretained(host.surfaceUserdata).toOpaque()
        surfaceCfg.scale_factor = host.surfaceView.contentScaleFactor

        // Ghostty starts its renderer thread before the constructor returns.
        // Pass the selected-tab state into construction so an inactive regular
        // or tmux pane never performs the initial full-size Metal draw.
        let initiallyVisible = host.surfaceInitialTabVisibility()
        host.surfaceIsTabVisible = initiallyVisible
        surfaceCfg.initially_visible = initiallyVisible && !Ghostty.isSecureDrawProhibitedAtomic

        if let binding = host.surfaceTmuxPaneBinding {
            createTmuxPaneSurface(app: app, cfg: &surfaceCfg, binding: binding)
            return
        }

        let hasSSH = host.surfaceConnectionConfig.sshConfig != nil
        Ghostty.logger.info("Platform check: isMacCatalyst=\(PlatformDetection.isMacCatalyst), hasSSH=\(hasSSH)")

        surfaceCfg.use_external_io = true
        logSurfaceConfiguration()

        let scaleFactor = host.surfaceView.contentScaleFactor
        Ghostty.logger.info("Creating surface with scale factor: \(scaleFactor)")
        let newSurface = ghostty_surface_new(app, &surfaceCfg)
        Ghostty.logger.info("ghostty_surface_new returned: \(newSurface != nil ? "success" : "nil")")

        guard let newSurface else {
            Ghostty.logger.error("Failed to create ghostty surface - ghostty_surface_new returned nil")
            return
        }

        installSurface(newSurface)
        host.surfaceApplyRestoredFontSizeOverrideIfNeeded()

        slaveFd = ghostty_surface_get_slave_fd(newSurface)
        responseFd = ghostty_surface_response_read_fd(newSurface)
        host.surfaceOutputPipeline.configure(fd: slaveFd)

        if slaveFd >= 0 && responseFd >= 0 {
            Ghostty.logger.info("Got FDs for external I/O - slave: \(self.slaveFd), response: \(self.responseFd)")
        } else {
            Ghostty.logger.error("FDs not available but expected (slave: \(self.slaveFd), response: \(self.responseFd))")
        }

        configureRestoredScrollbackIfNeeded()
        host.surfaceRegisterForScrollbackPersistence()

        Ghostty.logger.info("Setting up PTY and shell session...")
        host.surfaceDidNeedSessionSetup()
        Ghostty.logger.info("PTY and shell setup initiated")

        setInitialOcclusion(on: newSurface)
        startFirstFramePolling()
    }

    private func installSurface(_ surface: ghostty_surface_t) {
        Ghostty.logger.info("Surface created successfully, ptr=\(String(describing: surface))")
        self.surface = surface
        host.surfaceControllerDidSetSurface(surface)

        host.surfaceGhosttyApp?.registerSurface(surface)
        Ghostty.logger.info("Surface registered for config updates")

        host.surfaceGhosttyApp?.registerSurfaceWindow(surface, windowId: host.surfaceWindowID)
        let windowID = host.surfaceWindowID
        Ghostty.logger.info("Surface registered to window \(windowID)")

        if let tabId = host.surfaceContainingTabID {
            host.surfaceGhosttyApp?.registerSurfaceTab(surface, tabId: tabId)
            Ghostty.logger.info("Surface registered to tab \(tabId)")
        }

        host.surfaceSetupThemeOverrideSubscription()
        host.surfaceGhosttyApp?.refreshSurfaceTheme(
            surface,
            tabId: host.surfaceContainingTabID,
            windowId: host.surfaceWindowID
        )

        if let delegate = host.surfaceUserdata as? GhosttyActionDelegate {
            host.surfaceGhosttyApp?.registerSurfaceDelegate(surface, delegate: delegate)
            Ghostty.logger.info("Surface delegate registered")
        }
    }

    private func logSurfaceConfiguration() {
        switch host.surfaceConnectionConfig {
        case .ssh:
            Ghostty.logger.info("Surface config: SSH session - using external I/O (pipes)")
        case .mosh:
            Ghostty.logger.info("Surface config: Mosh session - using external I/O (UDP)")
        case .kubernetes:
            Ghostty.logger.info("Surface config: Kubernetes session - using external I/O (pipes)")
        case .console:
            Ghostty.logger.info("Surface config: Console session - using external I/O (WebSocket)")
        case .ec2Console:
            Ghostty.logger.info("Surface config: EC2 Console session - using external I/O (SSH)")
        case .local:
            if PlatformDetection.isMacCatalyst {
                Ghostty.logger.info("Surface config: Local shell on Catalyst - using external I/O (helper-based)")
            } else {
                Ghostty.logger.info("Surface config: Local shell on iOS/visionOS - using external I/O (pipes)")
            }
        case .shellLaunchedSSH:
            Ghostty.logger.info("Surface config: Shell-launched SSH session - using external I/O (pipes)")
        case .shellLaunchedMosh:
            Ghostty.logger.info("Surface config: Shell-launched Mosh session - using external I/O (UDP)")
        case .trzsz:
            Ghostty.logger.info("Surface config: Trzsz session - using external I/O (QUIC)")
        case .shellLaunchedTrzsz:
            Ghostty.logger.info("Surface config: Shell-launched Trzsz session - using external I/O (QUIC)")
        case .trzszTransfer:
            Ghostty.logger.info("Surface config: Trzsz transfer - using external I/O (QUIC)")
        case .vnc:
            Ghostty.logger.warning("Surface config: VNC on a terminal surface - handled by a VNC pane, not expected here")
        }
    }

    private func configureRestoredScrollbackIfNeeded() {
        guard case .pendingReconnection = host.surfaceRestorationState else { return }
        host.surfaceOutputPipeline.enableScrollbackRestoreGate()
        switch host.surfaceConnectionConfig {
        case .local, .shellLaunchedSSH, .shellLaunchedMosh, .shellLaunchedTrzsz:
            host.surfacePendingScrollbackRestoreForLayout = true
        default:
            host.surfacePendingScrollbackRestore = true
        }

        if host.surfacePendingScrollbackRestoreForLayout {
            // `host` is unowned; capture it weakly so this deferred Task no-ops
            // rather than trapping if the view is torn down during the 2s wait.
            Task { @MainActor [weak host] in
                try? await Task.sleep(for: .seconds(2))
                guard let host, host.surfacePendingScrollbackRestoreForLayout else { return }
                host.surfacePendingScrollbackRestoreForLayout = false
                host.surfaceRunLayoutDeferredScrollbackRestore()
            }
        }
    }

    private func setInitialOcclusion(on surface: ghostty_surface_t) {
        // A new surface is born visible in the core with a running display
        // link, so a surface created while the secure-draw latch is armed
        // (background launch, locked-device state restore) must be actively
        // occluded, not just skipped. surfaceIsTabVisible is left untouched
        // so the foreground reconcile re-asserts true after unlock.
        if Ghostty.isSecureDrawProhibitedAtomic {
            ghostty_surface_set_occlusion(surface, false)
            _ = ghostty_surface_drain_renderer_to_idle(surface, 100_000_000)
            LifecycleDebugLogger.shared.checkpoint("SECURE.initialOcclusion.forced")
            return
        }
        let visible = host.surfaceInitialTabVisibility()
        host.surfaceIsTabVisible = visible
        nonisolated(unsafe) let surfacePtr = surface
        Ghostty.TerminalView.ghosttyAPIQueue.async {
            ghostty_surface_set_occlusion(surfacePtr, visible)
        }
        Ghostty.logger.info("Initial occlusion set: visible=\(visible)")
    }

    func updateBottomInset() {
        guard let surface else { return }
        guard !host.surfaceSuppressBottomInsetUpdatesForScrollRubberBand else { return }
        // The overlay round trip's safe-area shuffle moves this inset in
        // lockstep with the (dropped) size change — applying it against the
        // unchanged surface size would reflow the grid on its own. Dropped
        // together with the size (never-sized surfaces exempt); the
        // latch-release flush re-applies both.
        if lastFramebufferSize != nil,
           KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: host.surfaceView.window) {
            return
        }
        let insetPx = host.surfaceCurrentBottomInsetPixels
        if abs(insetPx - lastBottomInsetPx) < 0.5 { return }
        lastBottomInsetPx = insetPx
        #if targetEnvironment(macCatalyst)
        ghostty_surface_set_bottom_inset(surface, insetPx)
        #else
        nonisolated(unsafe) let surfacePtr = surface
        Ghostty.TerminalView.ghosttyAPIQueue.async {
            ghostty_surface_set_bottom_inset(surfacePtr, insetPx)
        }
        #endif
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface else {
            Ghostty.logger.warning("sizeDidChange called but surface is nil")
            return
        }

        if size.width < 1 || size.height < 1 {
            if host.surfaceIsTmuxPane {
                TmuxDebugLogger.shared.event(
                    "PANE-SETSIZE",
                    "SKIP-degenerate win=\(host.surfaceTmuxPaneBinding?.windowId ?? -1) pane=\(host.surfaceTmuxPaneBinding?.paneId ?? -1) size=\(size.width)x\(size.height)")
            }
            return
        }

        if host.surfaceTmuxPaneRetired {
            TmuxDebugLogger.shared.event(
                "PANE-SETSIZE",
                "SKIP-retired win=\(host.surfaceTmuxPaneBinding?.windowId ?? -1) pane=\(host.surfaceTmuxPaneBinding?.paneId ?? -1) size=\(size.width)x\(size.height)")
            return
        }

        if sizeUpdatesSuppressed {
            Ghostty.logger.info("sizeDidChange: SUPPRESSED during background transition (size=\(size.width)x\(size.height))")
            return
        }

        // Never drop a never-sized surface's first size (same rule as the
        // overlay-preservation guard below): its grid is at default dims and
        // wrong no matter what. A tab opened or first displayed while a
        // keyboard transition is in flight — including the minimized-keyboard
        // pill a pencil tap summons — otherwise renders a default-sized grid
        // with the theme background filling the rest of the drawable.
        if lastFramebufferSize != nil, KeyboardTracker.shared.isKeyboardAnimating {
            Ghostty.logger.debug("sizeDidChange: SKIPPED during keyboard animation (size=\(size.width)x\(size.height))")
            return
        }

        // While an overlay owns the keyboard, the physical keyboard hide/
        // re-show shuffles the container bottom safe area (the home-indicator
        // inset is subsumed by the keyboard while it is up), wobbling bounds
        // by ~34pt even though the reported keyboard layout is frozen. Drop
        // pushes for the round trip; the latch release posts
        // .overlayKeyboardPreservationEnded and the flush self-dedupes when
        // bounds returned to the size last sent. Never drop a never-sized
        // surface's first size (tab created while an overlay is open).
        if lastFramebufferSize != nil,
           KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: host.surfaceView.window) {
            return
        }

        if host.surfaceTmuxDetachInProgress {
            TmuxDebugLogger.shared.event(
                "PANE-SETSIZE",
                "SKIP-detaching win=\(host.surfaceTmuxPaneBinding?.windowId ?? -1) pane=\(host.surfaceTmuxPaneBinding?.paneId ?? -1) size=\(size.width)x\(size.height)")
            return
        }

        #if STANDALONE && targetEnvironment(macCatalyst)
        // Never drop the first size of a never-sized surface: its grid is at
        // default dims and wrong no matter what, and a tab created/restored
        // mid-summon lays out entirely inside the suppression window (the
        // panel is still sliding in at partial alpha, so no visible reflow).
        if host.surfaceWindowID == "visor",
           VisorController.shared.suppressesTerminalResizeForAnimation,
           let lastSent = lastFramebufferSize {
            Ghostty.logger.info("sizeDidChange: SUPPRESSED during unchanged visor animation (size=\(size.width)x\(size.height), lastSent=\(lastSent.width)x\(lastSent.height))")
            return
        }
        #endif

        let scale = host.surfaceView.contentScaleFactor
        let framebufferWidth = UInt32(size.width * scale)
        let framebufferHeight = UInt32(size.height * scale)
        let previousScale = lastContentScaleFactor

        if host.surfaceIsTmuxPane, !host.surfaceTmuxPaneContainerLaidOut {
            TmuxDebugLogger.shared.event(
                "PANE-SETSIZE",
                "SKIP-placeholder win=\(host.surfaceTmuxPaneBinding?.windowId ?? -1) pane=\(host.surfaceTmuxPaneBinding?.paneId ?? -1) fb=\(framebufferWidth)x\(framebufferHeight)")
            return
        }

        if let lastFramebufferSize,
           let lastContentScaleFactor,
           lastFramebufferSize.width == framebufferWidth,
           lastFramebufferSize.height == framebufferHeight,
           lastContentScaleFactor == scale {
            return
        }

        lastFramebufferSize = (width: framebufferWidth, height: framebufferHeight)
        lastContentScaleFactor = scale
        host.surfaceGeometryDidChange()

        if host.surfaceIsTmuxPane {
            let ss = surfaceSize
            let cw = ss.map { Int($0.cell_width_px) } ?? 0
            let ch = ss.map { Int($0.cell_height_px) } ?? 0
            let gcols = cw > 0 ? Int(framebufferWidth) / cw : 0
            let grows = ch > 0 ? Int(framebufferHeight) / ch : 0
            TmuxDebugLogger.shared.event(
                "PANE-SETSIZE",
                "win=\(host.surfaceTmuxPaneBinding?.windowId ?? -1) pane=\(host.surfaceTmuxPaneBinding?.paneId ?? -1) fb=\(framebufferWidth)x\(framebufferHeight) ~grid=\(gcols)x\(grows)")
        }

        if host.surfaceLogFrequentLayout {
            Ghostty.logger.debug("sizeDidChange: size=\(size.width)x\(size.height), scale=\(scale), framebuffer=\(framebufferWidth)x\(framebufferHeight)")
        }

        let needsRestore = host.surfacePendingScrollbackRestoreForLayout

        if previousScale == nil || previousScale != scale {
            setContentScaleAndSize(
                surface: surface,
                scale: scale,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight,
                needsRestore: needsRestore
            )
            return
        }

        setSize(
            surface: surface,
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight,
            needsRestore: needsRestore
        )
    }

    private func setContentScaleAndSize(
        surface: ghostty_surface_t,
        scale: CGFloat,
        framebufferWidth: UInt32,
        framebufferHeight: UInt32,
        needsRestore: Bool
    ) {
        #if targetEnvironment(macCatalyst)
        guard !host.surfaceTmuxDetachInProgressAtomic else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, framebufferWidth, framebufferHeight)
        // Retain the host across the queue hop (matches the iOS path) so the
        // deferred update can't dangle if the view is released meanwhile.
        nonisolated(unsafe) let hostRef = host
        Ghostty.TerminalView.ghosttyAPIQueue.async {
            Task { @MainActor in
                hostRef.surfaceUpdatePTYSize()
                if needsRestore && hostRef.surfacePendingScrollbackRestoreForLayout {
                    // Claim the deferred restore only when this main-actor
                    // callback actually runs. Clearing it before the IO/main
                    // queue hops lets a concurrent transport `.running` event
                    // mistake "queued" for "already restored" and replay at
                    // stale dimensions; a second queued size callback could
                    // then replay it again. ROOTSHELL-TMUX
                    // (id=layout-restore-main-actor-claim)
                    hostRef.surfacePendingScrollbackRestoreForLayout = false
                    hostRef.surfaceRunLayoutDeferredScrollbackRestore()
                }
            }
        }
        #else
        nonisolated(unsafe) let surfacePtr = surface
        nonisolated(unsafe) let hostRef = host
        Ghostty.TerminalView.ghosttyAPIQueue.async { [weak self] in
            guard self != nil else { return }
            guard hostRef.surfaceTmuxDetachInProgressAtomic != true else { return }
            ghostty_surface_set_content_scale(surfacePtr, scale, scale)
            ghostty_surface_set_size(surfacePtr, framebufferWidth, framebufferHeight)
            Task { @MainActor in
                hostRef.surfaceUpdatePTYSize()
                if needsRestore && hostRef.surfacePendingScrollbackRestoreForLayout {
                    hostRef.surfacePendingScrollbackRestoreForLayout = false
                    hostRef.surfaceRunLayoutDeferredScrollbackRestore()
                }
            }
        }
        #endif
    }

    private func setSize(
        surface: ghostty_surface_t,
        framebufferWidth: UInt32,
        framebufferHeight: UInt32,
        needsRestore: Bool
    ) {
        #if targetEnvironment(macCatalyst)
        guard !host.surfaceTmuxDetachInProgressAtomic else { return }
        ghostty_surface_set_size(surface, framebufferWidth, framebufferHeight)
        // Retain the host across the queue hop (matches the iOS path) so the
        // deferred update can't dangle if the view is released meanwhile.
        nonisolated(unsafe) let hostRef = host
        Ghostty.TerminalView.ghosttyAPIQueue.async {
            Task { @MainActor in
                hostRef.surfaceUpdatePTYSize()
                if needsRestore && hostRef.surfacePendingScrollbackRestoreForLayout {
                    hostRef.surfacePendingScrollbackRestoreForLayout = false
                    hostRef.surfaceRunLayoutDeferredScrollbackRestore()
                }
            }
        }
        #else
        nonisolated(unsafe) let surfacePtr = surface
        nonisolated(unsafe) let hostRef = host
        Ghostty.TerminalView.ghosttyAPIQueue.async { [weak self] in
            guard self != nil else { return }
            guard hostRef.surfaceTmuxDetachInProgressAtomic != true else { return }
            ghostty_surface_set_size(surfacePtr, framebufferWidth, framebufferHeight)
            Task { @MainActor in
                hostRef.surfaceUpdatePTYSize()
                if needsRestore && hostRef.surfacePendingScrollbackRestoreForLayout {
                    hostRef.surfacePendingScrollbackRestoreForLayout = false
                    hostRef.surfaceRunLayoutDeferredScrollbackRestore()
                }
            }
        }
        #endif
    }

    func setOcclusion(_ visible: Bool) {
        let terminalID = host.surfaceTerminalDebugID
        Ghostty.logger.info("setOcclusion(\(visible)): terminal=\(terminalID)")
        host.surfaceIsTabVisible = visible

        if !visible {
            // An occluded surface is not expected to produce a frame. Leaving
            // its watchdog armed turns that normal state into a timeout and,
            // for tmux panes, historically woke the hidden renderer again.
            suspendFirstFramePolling()
        }

        guard surface != nil else {
            Ghostty.logger.debug("setOcclusion(\(visible)): no surface")
            return
        }

        if visible {
            startFirstFramePolling()
        }

        // Defer the GhosttyKit occlusion call onto a follow-up main-queue tick
        // before hopping to the background API queue. The C call can dispatch
        // CADisplayLink work back to main; one extra tick lets UIKit finish the
        // current keyboard/scene event before we touch the display link. Re-read
        // the live surface here so teardown that already ran leaves us with nil,
        // and teardown after this call preserves serial queue ordering.
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface = self.surface else { return }
            // Secure-draw latch: while the device may be locked, occlusion(true)
            // forces an immediate present in the core (even when redundant),
            // which FrontBoard kills as insecure drawing (0x2BAD45EC). Drop
            // true here and again at the final hop; false always delivers.
            // surfaceIsTabVisible keeps the intent, and the foreground resume
            // re-asserts from the tab model after the latch clears.
            if visible && Ghostty.isSecureDrawProhibitedAtomic {
                LifecycleDebugLogger.shared.checkpoint("SECURE.occlusion.dropped", ms: nil, [
                    ("terminal", terminalID), ("hop", "main"),
                ])
                return
            }
            nonisolated(unsafe) let surfacePtr = surface
            Ghostty.TerminalView.ghosttyAPIQueue.async {
                if visible && Ghostty.isSecureDrawProhibitedAtomic { return }
                ghostty_surface_set_occlusion(surfacePtr, visible)
            }
        }
    }

    @discardableResult
    func pauseRendererForBackground(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
        host.surfaceIsTabVisible = false
        suspendFirstFramePolling()
        guard let surface else {
            Ghostty.logger.debug("pauseRendererForBackground: no surface")
            return true
        }

        ghostty_surface_set_occlusion(surface, false)
        return ghostty_surface_drain_renderer_to_idle(surface, timeoutNanoseconds)
    }

    @discardableResult
    func drainRendererToIdleSync(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
        host.surfaceIsTabVisible = false
        suspendFirstFramePolling()
        guard let surface else { return true }
        return ghostty_surface_drain_renderer_to_idle(surface, timeoutNanoseconds)
    }

    func requestRendererDrainToIdleAsync(
        terminalID: String,
        connection: String,
        timeoutNanoseconds: UInt64 = 200_000_000
    ) {
        host.surfaceIsTabVisible = false
        suspendFirstFramePolling()
        guard let surface else { return }
        let surfaceAddress = Int(bitPattern: surface)
        DispatchQueue.global(qos: .utility).async {
            let start = CFAbsoluteTimeGetCurrent()
            guard let surfacePtr = UnsafeMutableRawPointer(bitPattern: surfaceAddress) else {
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.drain.async.skipped", ms: nil, [
                    ("terminal", terminalID),
                    ("connection", connection),
                    ("reason", "missingSurface"),
                ])
                return
            }
            LifecycleDebugLogger.shared.criticalCheckpoint("BG.drain.async.begin", ms: nil, [
                ("terminal", terminalID),
                ("connection", connection),
                ("surface", UInt(bitPattern: surfacePtr)),
            ])
            let drained = ghostty_surface_drain_renderer_to_idle(surfacePtr, timeoutNanoseconds)
            LifecycleDebugLogger.shared.criticalCheckpoint("BG.drain.async.end",
                ms: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                [
                    ("terminal", terminalID),
                    ("connection", connection),
                    ("surface", UInt(bitPattern: surfacePtr)),
                    ("drained", drained),
                ])
        }
    }

    func teardownSurface() {
        guard let surface else {
            resetFirstFrameTracking()
            return
        }

        host.surfaceGhosttyApp?.unregisterSurfaceTab(surface)
        host.surfaceGhosttyApp?.unregisterSurfaceWindow(surface)
        host.surfaceGhosttyApp?.unregisterSurfaceDelegate(surface)
        host.surfaceGhosttyApp?.unregisterSurface(surface)

        self.surface = nil
        host.surfaceControllerDidSetSurface(nil)
        slaveFd = -1
        responseFd = -1

        nonisolated(unsafe) let surfacePtr = surface
        Ghostty.TerminalView.ghosttyAPIQueue.async {
            let saveCompleted = ScrollbackPersistenceManager.waitForSurfaceSave(surfacePtr)
            if saveCompleted {
                Ghostty.logger.info("Freeing Ghostty surface on background queue...")
                ghostty_surface_free(surfacePtr)
                Ghostty.logger.info("Ghostty surface freed")
            } else {
                Ghostty.logger.warning("Scrollback save did not complete in 500ms; leaking surface to avoid use-after-free")
            }
        }

        resetFirstFrameTracking()
    }
}

@MainActor
private final class FirstFramePollTarget: NSObject {
    weak var controller: TerminalSurfaceController?

    init(controller: TerminalSurfaceController) {
        self.controller = controller
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let controller else {
            link.invalidate()
            return
        }
        controller.firstFramePollTick()
    }
}

extension Ghostty.TerminalView: TerminalSurfaceHost {
    var surfaceUserdata: AnyObject { self }
    var surfaceView: UIView { self }
    var surfaceLayer: CALayer { layer }
    var surfaceAppPointer: ghostty_app_t? { appPtr }
    var surfaceGhosttyApp: Ghostty.App? { ghosttyAppRef }
    var surfaceWindowID: String { windowId }
    var surfaceContainingTabID: UUID? { containingTabID }
    var surfaceTerminalDebugID: String { String(uuid.uuidString.prefix(8)) }
    var surfaceConnectionConfig: ConnectionConfig { connectionConfig }
    var surfaceTmuxPaneBinding: TmuxPaneBinding? { tmuxPaneBinding }
    var surfaceIsTmuxPane: Bool { isTmuxPane }
    var surfaceTmuxPaneContainerLaidOut: Bool { tmuxPaneContainerLaidOut }
    var surfaceTmuxPaneRetired: Bool { tmuxPaneRetired }
    var surfaceTmuxDetachInProgress: Bool { isTmuxDetachInProgress }
    nonisolated var surfaceTmuxDetachInProgressAtomic: Bool { tmuxDetachInProgressAtomic }
    var surfaceIsTabVisible: Bool {
        get { isTabVisible }
        set { isTabVisible = newValue }
    }
    func surfaceInitialTabVisibility() -> Bool {
        if hasExplicitTabVisibility {
            return isTabVisible
        }
        guard let tabID = containingTabID else {
            return isTabVisible
        }
        let model = TerminalWindowRegistry.tabsModel(for: windowId)
            ?? TmuxWindowRegistry.tabsModel(for: windowId)
        return model.map { $0.selectedTabID == tabID } ?? isTabVisible
    }
    var surfacePendingScrollbackRestore: Bool {
        get { pendingScrollbackRestore }
        set { pendingScrollbackRestore = newValue }
    }
    var surfacePendingScrollbackRestoreForLayout: Bool {
        get { pendingScrollbackRestoreForLayout }
        set { pendingScrollbackRestoreForLayout = newValue }
    }
    var surfaceRestorationState: RestorationState { restorationState }
    var surfaceOutputPipeline: TerminalOutputPipeline { outputPipeline }
    var surfaceLogFrequentLayout: Bool { Self.logFrequentLayout }
    var surfaceSuppressBottomInsetUpdatesForScrollRubberBand: Bool {
        suppressBottomInsetUpdatesForScrollRubberBand
    }
    var surfaceCurrentBottomInsetPixels: Double { currentBottomInsetPixels() }

    func surfaceControllerDidSetSurface(_ surface: ghostty_surface_t?) {
        self.surface = surface
    }

    func surfaceRegisterForScrollbackPersistence() {
        ScrollbackPersistenceManager.shared.registerTerminal(self)
    }

    func surfaceSetupThemeOverrideSubscription() {
        setupThemeOverrideSubscription()
    }

    func surfaceApplyRestoredFontSizeOverrideIfNeeded() {
        applyRestoredFontSizeOverrideIfNeeded()
    }

    func surfaceDidNeedSessionSetup() {
        setupPTYAndShell()
    }

    func surfaceRunLayoutDeferredScrollbackRestore() {
        runLayoutDeferredScrollbackRestore()
    }

    func surfaceUpdatePTYSize() {
        updatePTYSize()
    }

    func surfaceGeometryDidChange() {
        AgentAttentionCenter.shared.noteGeometryChanged(terminal: self)
    }

    func surfaceFirstFrameDidFailOpen() {
        guard isTabVisible else {
            Ghostty.logger.debug("Ignoring first-frame fail-open for hidden terminal=\(self.surfaceTerminalDebugID)")
            return
        }
        _ = reassertVisibleIfNeeded(
            shouldFocus: isLogicallyFocused,
            reason: "first-frame-fail-open"
        )
    }
}
