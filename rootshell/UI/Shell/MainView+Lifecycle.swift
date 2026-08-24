//
//  MainView+Lifecycle.swift
//  rootshell
//
//  App lifecycle and scene phase handling for MainView.
//  Extracted for build parallelization.
//

import Crypto
import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Scene Phase Handling

private enum BackgroundPersistenceQueue {
    static let queue = DispatchQueue(label: "com.rootshell.background.persistence", qos: .utility)
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
final class ShortRemoteSessionBackgroundTaskIDBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UIBackgroundTaskIdentifier>(initialState: .invalid)

    func load() -> UIBackgroundTaskIdentifier {
        lock.withLock { $0 }
    }

    func store(_ taskID: UIBackgroundTaskIdentifier) {
        lock.withLock { $0 = taskID }
    }

    func exchangeToInvalid() -> UIBackgroundTaskIdentifier {
        lock.withLock { taskID in
            let oldValue = taskID
            taskID = .invalid
            return oldValue
        }
    }
}
#endif

/// Monotonic counter bumped synchronously inside `handleAppBackgrounded`.
///
/// Deferred foreground work (`performForegroundResume`, the trailing
/// gate-flip closure inside `drainTrzszSessionsThenOpenGate`) needs a way to
/// detect that a background transition arrived between its scheduling and
/// its execution. The UIKit notification that scheduled a deferred closure
/// can be superseded by a later background notification before that closure
/// runs. The existing
/// `Ghostty.isAppBackgroundedAtomic` / `ghosttyApp.isInBackground` flags
/// cannot be used as a proxy either: they are intentionally held TRUE
/// throughout the entire backgrounded period and are only cleared by the FG
/// body's own trailing gate flip, so reading them at FG entry would skip
/// every legitimate resume.
///
/// An epoch bumped synchronously inside `handleAppBackgrounded` (before its
/// own `BG.deferred.scheduled`) gives every later FG body a live signal: if
/// the current epoch is higher than the value captured at FG schedule time,
/// a background transition arrived in between and the FG body must abort to
/// let the matching BG body own the state.
@MainActor
final class LifecycleEpoch {
    static let shared = LifecycleEpoch()
    private init() {}

    private(set) var background: UInt64 = 0

    func bumpBackground() {
        background &+= 1
    }
}

extension MainView {

    func transitionLifecycleScenePhase(to newPhase: ScenePhase) {
        let oldPhase = lifecycleScenePhase
        guard oldPhase != newPhase else { return }
        lifecycleScenePhase = newPhase
        handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
    }

    private func pauseNetworkMonitorsForBackground() {
        #if !targetEnvironment(macCatalyst)
        LifecycleDebugLogger.shared.checkpoint("BG.networkMonitors.pause")
        NetworkReachabilityMonitor.shared.pauseForBackground()
        CloudKitSyncManager.shared.pauseNetworkMonitoringForBackground()
        LocalNetworkDiscoveryManager.shared.pauseNetworkMonitoringForBackground()
        #endif
    }

    private func resumeNetworkMonitorsAfterForegroundGate() {
        #if !targetEnvironment(macCatalyst)
        LifecycleDebugLogger.shared.checkpoint("FG.networkMonitors.resume")
        NetworkReachabilityMonitor.shared.resumeAfterForeground()
        CloudKitSyncManager.shared.resumeNetworkMonitoringAfterForeground()
        LocalNetworkDiscoveryManager.shared.resumeNetworkMonitoringAfterForeground()
        #endif
    }

    private func countActiveShortBackgroundKeepaliveSessions() -> Int {
        let terminalCount = terminals.flatMap { $0.splitTree.terminalLeaves }.filter { terminal in
            guard terminal.session?.isRunning == true else { return false }
            switch terminal.connectionConfig {
            case .ssh, .ec2Console, .shellLaunchedSSH:
                return true
            case .local:
                return terminal.hasActiveLocalTask
            case .kubernetes, .console, .mosh, .trzsz, .trzszTransfer, .shellLaunchedMosh, .shellLaunchedTrzsz, .vnc:
                // `.vnc` is unreachable here (a VNC pane is not a terminal
                // leaf, so the session guard above rejects it). Counted below.
                return false
            }
        }.count

        // VNC panes are not terminal leaves, so the `.vnc` arm above never
        // sees them (`terminal.session` rejects them first) and they have to
        // be walked separately. They were once deliberately excluded on the
        // grounds that "the package reconnects on foreground". It does, but
        // that reconnect is the bug: with no assertion, iOS suspends the
        // process seconds after backgrounding and reclaims the socket and the
        // hardware decoder, so every return to the app costs a full handshake,
        // auth, media renegotiation and IDR. Debug captures show the control
        // channel going silent on the background edge and `sinceControlByte`
        // matching the background window to within a second, drop after drop.
        let vncCount = countPanesWantingBackgroundKeepaliveGrace()

        return terminalCount + vncCount
    }

    private func countPanesWantingBackgroundKeepaliveGrace() -> Int {
        var count = 0
        for tab in terminals {
            for pane in tab.splitTree {
                guard let vncPane = pane as? VNCPaneView else { continue }
                if vncPane.wantsBackgroundKeepaliveGrace { count += 1 }
            }
        }
        return count
    }

    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    private func beginShortRemoteSessionBackgroundTaskIfNeeded(
        sessionCount: Int,
        locationEnabled: Bool,
        liveActivityActive: Bool
    ) {
        // Mirrored into the VNC log as well: a Screen Sharing drop across a
        // background window is indistinguishable from a network fault unless
        // the assertion decision that preceded it is on the same record.
        let noteSkip = { (reason: String) in
            VNCDebugLogger.shared.lifecycle("backgroundAssertion.skipped", [
                ("reason", reason),
                ("sessions", sessionCount),
            ])
        }

        guard UserPreferences.backgroundSessionKeepaliveEnabled else {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.skipped", ms: nil, [
                ("reason", "settingDisabled"),
                ("sessions", sessionCount),
                ("existing", shortRemoteSessionBackgroundTaskID),
            ])
            noteSkip("settingDisabled")
            return
        }
        guard sessionCount > 0 else {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.skipped", ms: nil, [
                ("reason", "noSessions"),
                ("sessions", sessionCount),
                ("existing", shortRemoteSessionBackgroundTaskID),
            ])
            noteSkip("noSessions")
            return
        }
        guard !locationEnabled && !liveActivityActive else {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.skipped", ms: nil, [
                ("reason", "strongerBackgroundMode"),
                ("sessions", sessionCount),
                ("location", locationEnabled),
                ("liveActivity", liveActivityActive),
                ("existing", shortRemoteSessionBackgroundTaskID),
            ])
            noteSkip("strongerBackgroundMode")
            return
        }
        guard shortRemoteSessionBackgroundTaskID == .invalid else {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.skipped", ms: nil, [
                ("reason", "alreadyActive"),
                ("sessions", sessionCount),
                ("existing", shortRemoteSessionBackgroundTaskID),
            ])
            noteSkip("alreadyActive")
            return
        }

        let taskBox = ShortRemoteSessionBackgroundTaskIDBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "RemoteSessionGrace") {
            let expiredTaskID = taskBox.exchangeToInvalid()
            guard expiredTaskID != .invalid else {
                LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.expiredSkipped", ms: nil, [
                    ("reason", "alreadyEnded"),
                    ("remaining", UIApplication.shared.backgroundTimeRemaining),
                ])
                return
            }

            LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.expired", ms: nil, [
                ("task", expiredTaskID),
                ("remaining", UIApplication.shared.backgroundTimeRemaining),
            ])
            // From here on the process is suspendable again, so any Screen
            // Sharing session still up is about to lose its socket.
            VNCDebugLogger.shared.lifecycle("backgroundAssertion.expired")
            UIApplication.shared.endBackgroundTask(expiredTaskID)
            LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.expiredEnd", ms: nil, [
                ("task", expiredTaskID),
                ("remaining", UIApplication.shared.backgroundTimeRemaining),
            ])

            Task { @MainActor in
                guard self.shortRemoteSessionBackgroundTaskID == expiredTaskID else { return }
                self.shortRemoteSessionBackgroundTaskID = .invalid
                self.shortRemoteSessionBackgroundTaskIDBox = nil
                LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.expiredStateCleared", ms: nil, [
                    ("task", expiredTaskID),
                ])
            }
        }
        taskBox.store(taskID)
        shortRemoteSessionBackgroundTaskIDBox = taskBox
        shortRemoteSessionBackgroundTaskID = taskID

        LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.begin", ms: nil, [
            ("sessions", sessionCount),
            ("task", taskID),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
        VNCDebugLogger.shared.lifecycle("backgroundAssertion.begin", [
            ("sessions", sessionCount),
            ("remaining", String(
                format: "%.0fs", UIApplication.shared.backgroundTimeRemaining)),
        ])
    }

    private func endShortRemoteSessionBackgroundTask(reason: String) {
        let stateTaskID = shortRemoteSessionBackgroundTaskID
        let taskID = shortRemoteSessionBackgroundTaskIDBox?.exchangeToInvalid() ?? stateTaskID
        shortRemoteSessionBackgroundTaskID = .invalid
        shortRemoteSessionBackgroundTaskIDBox = nil

        guard taskID != .invalid else {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.endSkipped", ms: nil, [
                ("reason", reason),
                ("stateTask", stateTaskID),
            ])
            return
        }

        UIApplication.shared.endBackgroundTask(taskID)
        LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.end", ms: nil, [
            ("reason", reason),
            ("task", taskID),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
    }
    #endif

    func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        WedgeBreadcrumbLogger.shared.critical("MainView.scenePhase", [
            ("old", String(describing: oldPhase)),
            ("new", String(describing: newPhase)),
        ])
        if newPhase == .active {
            ForegroundWedgeWatchdog.shared.noteMainActorServiced("MainView.scenePhase.active")
        }
        Ghostty.logger.info("Scene phase changed: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")
        LifecycleDebugLogger.shared.checkpoint("Scene.phaseChange", ms: nil, [
            ("old", String(describing: oldPhase)),
            ("new", String(describing: newPhase)),
        ])

        let isForegroundResume = newPhase == .active && (oldPhase == .background || oldPhase == .inactive)

        if isForegroundResume {
            // Focus state is restored as part of foreground resume.
            // Push the resume quiet-window deadline forward synchronously so
            // the bisection gates that check
            // `Ghostty.isInResumeQuietWindowAtomic` are in effect immediately
            // as iOS dispatches backed-up notifications during the
            // scene-update transaction. The deadline-based implementation is
            // safe under rapid foreground/background bounces — see the
            // atomic's doc.
            //
            // 150ms covers the scene-update transaction commit (one
            // CADisplayLink frame, ~16ms at 60Hz / ~8ms at 120Hz, plus
            // iOS's per-tick overhead) plus comfortable margin for slow
            // ticks under load (e.g. memory pressure, large terminal
            // counts). User reported one crash at 50ms; bumped here for
            // headroom while staying well under perceptible UX delay.
            // Diagnostic builds during the bisection used 3.0s; that was
            // a safety margin, not a UX target.
            Ghostty.extendResumeQuietWindow(by: 0.15)

            // Health-status publishes (per-session connectionHealth) get
            // their own longer window — the heartbeat fan-out across many
            // tssh sessions is the noisiest @Published source post-resume
            // and benefits from settling longer than other resume work.
            // Cached health values are replayed by
            // replayCachedSessionStateOnForeground anyway, so suppressing
            // live publishes for ~1.5s doesn't lose data.
            Ghostty.extendResumeHealthQuietWindow(by: 1.5)
            LifecycleDebugLogger.shared.checkpoint("FG.quietWindow.set", ms: nil, [
                ("quiet", 0.15),
                ("health", 1.5),
            ])
        } else {
            updateWindowFocusState()
        }

        // Handle transition to inactive (device sleep/lock)
        if newPhase == .inactive && oldPhase == .active {
            Ghostty.logger.info("Detected device sleep/inactive")
            #if !targetEnvironment(macCatalyst)
            // Stop GPU presentation BEFORE iOS captures the locked-screen
            // secure snapshot (this runs synchronously inside willResignActive,
            // which precedes the snapshot). See pauseRenderersForSecureSnapshot.
            pauseRenderersForSecureSnapshot()
            #endif
            handleDeviceSleep()
        }

        // Handle transition to background
        if newPhase == .background {
            Ghostty.logger.info("App entering background")
            handleAppBackgrounded()
        }

        // Handle transition to foreground
        if isForegroundResume {
            Ghostty.logger.info("App returning to foreground")
            handleAppForegrounded()
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// Synchronously stop GPU presentation on the visible terminals before iOS
    /// captures the locked-screen secure snapshot.
    ///
    /// Lock sequence: willResignActive → (secure snapshot) → didEnterBackground.
    /// The normal renderer pause runs only at `.background` and is deferred
    /// (`performBackgroundTransition` via `DispatchQueue.main.async`), so the
    /// Metal renderer is still presenting frames into the secure snapshot →
    /// FrontBoard `0x2BAD45EC` ("insecure drawing while in secure mode")
    /// SIGKILL. `ghostty_surface_set_occlusion(false)` (inside
    /// `pauseRendererForBackground`) stops the IOSDisplayLink synchronously on
    /// the main thread, and the bounded drain confirms no `drawFrame` is in
    /// flight before the snapshot is taken.
    ///
    /// Resume needs no new code: returning to `.active` from `.inactive` is an
    /// `isForegroundResume` (see `handleScenePhaseChange`), and
    /// `handleAppForegrounded` calls `setOcclusion(true)` on the selected tab's
    /// splits. Non-selected tabs correctly stay occluded; a pending tab-reveal
    /// re-completes on resume once the new tab presents its first frame.
    ///
    /// Pauses EVERY surface across all tabs, not just the selected one. During
    /// a tab-reveal transition the *displayed* tab (`tabsModel.displayedTabID`,
    /// which gates on-screen opacity) lags the selection, and the outgoing
    /// tab's `setOcclusion(false)` is deferred async (see
    /// `TerminalView.setOcclusion`), so a lock right after a tab switch/open
    /// can leave the still-visible old tab's renderer presenting into the
    /// snapshot. Mirrors `performBackgroundTransition`, which also pauses every
    /// tab. Already-occluded renderers ack the drain near-instantly, so the
    /// cost stays bounded.
    func pauseRenderersForSecureSnapshot() {
        guard !terminals.isEmpty else { return }
        LifecycleDebugLogger.shared.checkpoint("INACTIVE.renderer.pause.begin")
        for tab in terminals {
            // All panes, not just terminals: VNC panes commit decoded frames
            // to their display layer and must stop presenting too.
            for pane in tab.splitTree {
                // Shorter drain than the 200ms background default: bounds
                // main-thread blocking on transient willResignActive (Control
                // Center / Notification Center) while still guaranteeing no
                // in-flight Metal commit lands during the snapshot.
                pane.pauseRendererForBackground(timeoutNanoseconds: 100_000_000)
            }
        }
        LifecycleDebugLogger.shared.checkpoint("INACTIVE.renderer.pause.end")
    }
    #endif

    /// Re-assert the correct occlusion state for every surface from the
    /// authoritative app state (currently-selected tab + app active). The iOS
    /// counterpart to upstream's macOS `syncSurfaceTreeOcclusionState`.
    ///
    /// The GhosttyKit merge (`renderer: skip updateFrame when surface is not
    /// visible`) made the render thread *hard-stop* (disarm its draw timer)
    /// whenever a surface's `flags.visible` is `false`; the only recovery is an
    /// explicit `.visible = true`. So any transition that strands an on-screen
    /// surface at `false` — the secure-snapshot pause, a deferred/dropped/skipped
    /// resume un-occlusion, a tab-switch race — freezes that surface permanently
    /// (input still flows, nothing renders). Rather than rely on every
    /// `setOcclusion(false)` being perfectly paired with a later `true`, this
    /// reconciles from the source of truth.
    ///
    /// - The selected tab's surfaces are forced visible (`true`) — the un-freeze.
    ///   Re-asserting `true` is a cheap no-op in the core when the surface is
    ///   already visible (the renderer drops same-value `.visible` messages), so
    ///   this only does real work in the freeze case.
    /// - Tabs that another transition is deliberately keeping visible are left
    ///   untouched so we never occlude one out from under it: the *mid-reveal
    ///   displayed* tab (whose `displayedTabID` still lags `selectedTabID`, owned
    ///   by the tab-switch reveal handoff), and — during an app-tab swipe — the
    ///   `source` + `target` tabs that `beginAppTabSwipe` renders side-by-side
    ///   and makes visible *before* the selection commits.
    /// - Every other tab is occluded (`false`).
    ///
    /// No-op unless the app is currently active, so it can never un-occlude a
    /// surface that is genuinely hidden (backgrounded / locked).
    func reconcileSurfaceOcclusion(reason: String) {
        guard lifecycleScenePhase == .active else {
            LifecycleDebugLogger.shared.checkpoint("FG.occlusion.reconcile.skipped", ms: nil, [
                ("reason", "notActive"),
                ("caller", reason),
            ])
            return
        }

        guard let selectedID = tabsModel.selectedTabID else { return }

        // Heal a wedged swipe state before honoring its preserve set: a swipe
        // whose last event is >1.5s old can't be live (touch swipes stream
        // changed events, the trackpad path ends after 0.08s idle, and a
        // settling state clears in <=0.5s). This runs only at foreground-settle
        // moments, which can't coincide with a live touch (touches are
        // system-cancelled on scene resign), so a swipe held under a paused
        // finger is never cancelled here.
        if let swipe = appTabSwipeState,
           CACurrentMediaTime() - swipe.lastEventAt > 1.5 {
            forceClearAppTabSwipe(reason: "reconcileStale+\(reason)")
        }

        // Tabs kept visible by an in-flight transition whose occlusion we must
        // NOT force `false` here (occluding them would blank a tab the user is
        // actively looking at mid-transition):
        //   - the mid-reveal displayed tab (reveal handoff owns its occlusion);
        //   - during an app-tab swipe, the source+target tabs `beginAppTabSwipe`
        //     makes visible side-by-side before the selection commits.
        var preserveIDs: Set<UUID> = []
        if let displayedID = tabsModel.displayedTabID { preserveIDs.insert(displayedID) }
        if let swipe = appTabSwipeState {
            preserveIDs.insert(swipe.sourceTabID)
            preserveIDs.insert(swipe.targetTabID)
        }
        // Tab exposé mirrors every scope tab live (plus a neighbor scope being
        // swiped in); they must render while it's up.
        let exposeVisibleIDs: Set<UUID> = tabExpose.isActive
            ? Set(tabExpose.tabIDs).union(tabExpose.previewTabIDs)
            : []

        for tab in terminals {
            if tab.id == selectedID || exposeVisibleIDs.contains(tab.id) {
                for terminal in tab.splitTree { terminal.setOcclusion(true) }
            } else if preserveIDs.contains(tab.id) {
                continue
            } else {
                for terminal in tab.splitTree { terminal.setOcclusion(false) }
            }
        }

        var kv: [(String, Any)] = [
            ("caller", reason),
            ("selected", String(selectedID.uuidString.prefix(8))),
            ("preserved", preserveIDs.count),
            ("tabs", terminals.count),
        ]
        if let swipe = appTabSwipeState {
            kv.append(("swipeAgeMs", Int((CACurrentMediaTime() - swipe.lastEventAt) * 1000)))
        }
        LifecycleDebugLogger.shared.checkpoint("FG.occlusion.reconcile", ms: nil, kv)
    }

    /// Tab-switch analog of the foreground `reconcileSurfaceOcclusion` settle
    /// backstop: re-assert `visible = true` + first responder for the
    /// currently-selected tab's surfaces. Recovers a dropped `setOcclusion(true)`
    /// or a refused `becomeFirstResponder()` from `handleSelectedTabChange` — the
    /// freeze path the foreground-only reconcile never covers, because ordinary
    /// in-app tab switching has no background→foreground cycle to trigger it.
    /// Idempotent (each surface re-assert is a core no-op when already visible) and
    /// gated on the app being active so it can never un-occlude a genuinely hidden
    /// surface.
    func reassertSelectedTabVisibility(reason: String) {
        guard lifecycleScenePhase == .active else {
            LifecycleDebugLogger.shared.checkpoint("FG.tabSwitch.reassert.skipped", ms: nil, [
                ("reason", "notActive"),
                ("caller", reason),
            ])
            return
        }
        guard let selectedID = tabsModel.selectedTabID,
              let tab = tabsModel.tab(withID: selectedID) else { return }

        let focused = tab.focusedPane
        var focusRetries = 0
        for terminal in tab.splitTree.terminalLeaves {
            let shouldFocus = terminal === focused
            if terminal.reassertVisibleIfNeeded(shouldFocus: shouldFocus, reason: reason) {
                focusRetries += 1
            }
        }

        LifecycleDebugLogger.shared.checkpoint("FG.tabSwitch.reassert", ms: nil, [
            ("caller", reason),
            ("selected", String(selectedID.uuidString.prefix(8))),
            ("surfaces", tab.splitTree.count),
            ("focusRetries", focusRetries),
        ])
    }

    /// Resolve the currently-selected tab robustly for the foreground occlusion
    /// pass. `selectedTabIndex` is `tabsModel.selectedTabIndex ?? 0`, which can
    /// transiently exceed the live `terminals.count` while the tabs array and the
    /// model are mid-mutation — observed as `FG.occlusion.plan visible=0` /
    /// `FG.occlusion.fire visible=0`, where the foreground pass marks NO surface
    /// visible and would freeze even the selected tab if the reconcile settle
    /// backstop didn't catch it. Fall back to `selectedTabID`.
    private func resolveVisibleTab() -> TerminalTab? {
        let idx = selectedTabIndex
        if terminals.indices.contains(idx) { return terminals[idx] }
        return tabsModel.selectedTabID.flatMap { id in terminals.first { $0.id == id } }
    }

    func handleDeviceSleep() {
        // Count active SSH sessions across all terminals in all tabs
        let sshSessionCount = terminals.flatMap { $0.splitTree.terminalLeaves }.filter {
            if case .ssh = $0.connectionConfig { return true }
            return false
        }.count

        guard sshSessionCount > 0 else {
            Ghostty.logger.debug("Device going to sleep with no SSH sessions")
            return
        }

        // Check if Location Diary or Live Activity is keeping sessions alive
        let locationEnabled = LocationDiaryManager.shared.isEnabled
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let liveActivityActive = LiveActivityManager.shared.isActivityActive
        #else
        let liveActivityActive = false
        #endif

        if !locationEnabled && !liveActivityActive {
            // Neither location diary nor Live Activity is active - fire immediate notification
            // as we have very little time before suspension
            Ghostty.logger.warning("Device going to sleep with \(sshSessionCount) SSH session(s) and no background mode active - firing immediate notification")
            NotificationManager.shared.scheduleSSHReminder(sessionCount: sshSessionCount, delay: 0)
        } else {
            Ghostty.logger.info("Device going to sleep with \(sshSessionCount) SSH session(s) but background mode is active (location=\(locationEnabled), liveActivity=\(liveActivityActive))")
        }
    }

    func handleAppBackgrounded() {
        // The exposé keeps scope tabs un-occluded; drop it before the sweep.
        tabExpose.forceHide(reason: "background")
        let totalTerminals = terminals.flatMap { $0.splitTree.terminalLeaves }.count
        let sshCountSnapshot = terminals.flatMap { $0.splitTree.terminalLeaves }.filter {
            if case .ssh = $0.connectionConfig { return true }
            return false
        }.count
        let shortBackgroundKeepaliveSessionCount = countActiveShortBackgroundKeepaliveSessions()
        let vncKeepaliveSessionCount = countPanesWantingBackgroundKeepaliveGrace()
        let locationEnabled = LocationDiaryManager.shared.isEnabled
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let liveActivityActive = LiveActivityManager.shared.isActivityActive
        #else
        let liveActivityActive = false
        #endif
        let suppressionSnapshot = LifecycleDebugLogger.shared.snapshotAndResetSuppression()
        let bodyEvalsSinceLastEvent = LifecycleDebugLogger.shared.snapshotAndResetBodyEvaluation()
        LifecycleDebugLogger.shared.checkpoint("BG.enter", ms: nil, [
            ("terminals", totalTerminals),
            ("sshCount", sshCountSnapshot),
            ("shortBgSessions", shortBackgroundKeepaliveSessionCount),
            ("vncSessions", vncKeepaliveSessionCount),
            ("backgroundKeepalive", UserPreferences.backgroundSessionKeepaliveEnabled),
            ("location", locationEnabled),
            ("liveActivity", liveActivityActive),
            ("sheets", isAnySheetPresented),
            ("priorSuppressed", suppressionSnapshot),
            ("bodyEvals", bodyEvalsSinceLastEvent),
        ])

        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.plan", ms: nil, [
            ("sessions", shortBackgroundKeepaliveSessionCount),
            ("vncSessions", vncKeepaliveSessionCount),
            ("backgroundKeepalive", UserPreferences.backgroundSessionKeepaliveEnabled),
            ("location", locationEnabled),
            ("liveActivity", liveActivityActive),
            ("existing", shortRemoteSessionBackgroundTaskID),
        ])
        beginShortRemoteSessionBackgroundTaskIfNeeded(
            sessionCount: shortBackgroundKeepaliveSessionCount,
            locationEnabled: locationEnabled,
            liveActivityActive: liveActivityActive
        )
        #endif

        // SYNCHRONOUS prelude — these atomic flags are the canonical
        // "skip MainActor work" gates consulted by output handlers, the
        // Trzsz health monitor, the Citadel heartbeat, and the action-callback
        // Task spawn sites in GhosttyApp.swift. Set them before any renderer
        // drain or per-terminal loop so backgrounding stops new work before
        // FrontBoard's scene-update transaction starts waiting on us.
        //
        // Mac Catalyst does not have the secure-mode restriction and
        // scenePhase is unreliable there: a closing window's MainView
        // observes its own scenePhase transition to .background as the
        // window tears down, while the surviving window stays .active and
        // never fires a foreground transition to flip the atomic back.
        // Skip both the C-level flag and the Swift atomic on Catalyst to
        // avoid them getting stuck after a window close.
        #if !targetEnvironment(macCatalyst)
        ghosttyApp.isInBackground = true
        Ghostty.isAppBackgroundedAtomic = true
        #endif
        LifecycleDebugLogger.shared.checkpoint("BG.atomic.set", ms: nil, [
            ("isAppBackgroundedAtomic", Ghostty.isAppBackgroundedAtomic),
        ])
        pauseNetworkMonitorsForBackground()

        ResumeDebugLogger.shared.logMarker("APP BACKGROUND")
        LifecycleDebugLogger.shared.logMarker("APP BACKGROUND")

        // Defer the heavier MainActor transition off the FrontBoard scene-update
        // transaction. The persistence work inside that transition is then
        // dispatched to BackgroundPersistenceQueue rather than Task.detached /
        // beginBackgroundTask, which are suspected in lifecycle deadlocks.
        // The short remote-session grace task is registered above, before this
        // deferred body can be delayed or skipped by suspension.
        //
        // Bump the lifecycle epoch BEFORE the BG body is scheduled so that any
        // FG body already queued ahead of us in the runloop (the
        // `inactive → active → background` race observed in caughtit
        // 14:33:09) sees a higher epoch than the one it captured at schedule
        // time and aborts. See `LifecycleEpoch` doc.
        //
        // Skipped on Mac Catalyst because `handleAppBackgrounded` fires per
        // closing window there (see CLAUDE.md), and a global epoch bump would
        // invalidate FG bodies belonging to surviving windows.
        #if !targetEnvironment(macCatalyst)
        LifecycleEpoch.shared.bumpBackground()
        #endif
        LifecycleDebugLogger.shared.checkpoint("BG.deferred.scheduled")
        DispatchQueue.main.async { [self] in
            performBackgroundTransition()
        }
    }

    @MainActor
    private func performBackgroundTransition() {
        let transitionStart = CFAbsoluteTimeGetCurrent()
        LifecycleDebugLogger.shared.checkpoint("BG.transition.enter", ms: nil, [
            ("scenePhase", String(describing: lifecycleScenePhase)),
        ])

        // Rapid-bounce guard: if the user re-foregrounded during the
        // single-tick deferral window, skip the pause work and let the
        // foreground path handle re-entry.
        guard lifecycleScenePhase == .background else {
            Ghostty.logger.info("performBackgroundTransition: scene re-foregrounded during defer, skipping")
            LifecycleDebugLogger.shared.checkpoint("BG.transition.skipped", ms: nil, [
                ("reason", "rebounced"),
            ])
            return
        }

        // --- Phase 1: Gather lightweight state snapshots on main thread (fast) ---

        // Gather window state (reads Swift properties, no I/O)
        let gatherStart = CFAbsoluteTimeGetCurrent()
        let windowState = WindowStateManager.shared.gatherState()
        LifecycleDebugLogger.shared.checkpoint("BG.gather.windowState",
            ms: (CFAbsoluteTimeGetCurrent() - gatherStart) * 1000,
            [("present", windowState != nil)])

        // gatherState() returned nil. Two cases:
        //   - User has closed every window/tab and is backgrounding — we want
        //     the file cleared so next launch is fresh.
        //   - Restoration hasn't populated `terminals` yet (Catalyst's async
        //     helper-warmup Task fired between launch and this BG tick) —
        //     wiping the file here was the launch-then-quit data-loss bug.
        // `hasObservedNonEmptyStateThisLaunch` distinguishes the two: it
        // flips true the first time WindowStateManager has produced a
        // populated state this launch, so a subsequent empty result is
        // unambiguously user-driven.
        if windowState == nil
            && WindowStateManager.isSessionPersistenceEnabled
            && WindowStateManager.shared.hasObservedNonEmptyStateThisLaunch {
            WindowStateManager.shared.clearSavedState()
        }

        // Gather terminal refs for scrollback (reads surface pointers + session state, no I/O)
        let refsStart = CFAbsoluteTimeGetCurrent()
        let terminalRefs = ScrollbackPersistenceManager.shared.gatherTerminalRefs()
        LifecycleDebugLogger.shared.checkpoint("BG.gather.terminalRefs",
            ms: (CFAbsoluteTimeGetCurrent() - refsStart) * 1000,
            [("n", terminalRefs.count)])

        // Pre-fetch encryption key (Keychain read, cached after first call)
        let keyStart = CFAbsoluteTimeGetCurrent()
        let encryptionKey: SymmetricKey?
        if !terminalRefs.isEmpty {
            do {
                encryptionKey = try ScrollbackEncryptionManager.shared.getKey()
            } catch {
                Ghostty.logger.warning("Failed to pre-fetch encryption key, scrollback will not be saved: \(error.localizedDescription)")
                encryptionKey = nil
                // Release in-flight markers since we won't be saving
                ScrollbackPersistenceManager.clearInFlightSurfaces(terminalRefs)
            }
        } else {
            encryptionKey = nil
        }
        LifecycleDebugLogger.shared.checkpoint("BG.fetch.encryptionKey",
            ms: (CFAbsoluteTimeGetCurrent() - keyStart) * 1000,
            [("present", encryptionKey != nil)])

        // Pause ocean animation timing to prevent catch-up on return
        if let effect = EffectManager.shared.activeEffect,
           let solarEffect = effect.asEffect(SolarGraphEffect.self) {
            solarEffect.didEnterBackground()
        }

        // Mark ALL surfaces as occluded and pause reconnection UI to prevent cursor corruption
        for tab in terminals {
            for pane in tab.splitTree {
                guard let terminal = pane.asTerminal else {
                    // Non-terminal panes (VNC) stop presenting decoded frames.
                    pane.pauseRendererForBackground()
                    continue
                }
                let terminalID = terminal.uuid.uuidString
                let connection = terminal.connectionConfig.lifecycleDebugKind
                let terminalStart = CFAbsoluteTimeGetCurrent()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.terminal.pause.begin", ms: nil, [
                    ("terminal", terminalID),
                    ("connection", connection),
                ])
                let occlusionStart = CFAbsoluteTimeGetCurrent()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.occlusion.begin", ms: nil, [
                    ("terminal", terminalID),
                    ("connection", connection),
                    ("visible", false),
                ])
                let rendererPaused = terminal.pauseRendererForBackground()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.occlusion.end",
                    ms: (CFAbsoluteTimeGetCurrent() - occlusionStart) * 1000,
                    [
                        ("terminal", terminalID),
                        ("connection", connection),
                        ("drained", rendererPaused),
                    ])
                let pauseStart = CFAbsoluteTimeGetCurrent()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.pauseReconnectionUI.begin", ms: nil, [
                    ("terminal", terminalID),
                    ("connection", connection),
                ])
                terminal.pauseReconnectionUI()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.pauseReconnectionUI.end",
                    ms: (CFAbsoluteTimeGetCurrent() - pauseStart) * 1000,
                    [
                        ("terminal", terminalID),
                        ("connection", connection),
                    ])
                terminal.clearTouchState()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.terminal.pause.end",
                    ms: (CFAbsoluteTimeGetCurrent() - terminalStart) * 1000,
                    [
                        ("terminal", terminalID),
                        ("connection", connection),
                    ])
            }
        }

        // Count active SSH sessions across all terminals in all tabs
        let sshSessionCount = terminals.flatMap { $0.splitTree.terminalLeaves }.filter {
            if case .ssh = $0.connectionConfig { return true }
            return false
        }.count

        // Check if Location Diary or Live Activity is keeping sessions alive
        let locationEnabled = LocationDiaryManager.shared.isEnabled
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let liveActivityActive = LiveActivityManager.shared.isActivityActive
        #else
        let liveActivityActive = false
        #endif

        if sshSessionCount > 0 {
            if !locationEnabled && !liveActivityActive {
                // Use standard 60-second delay for background (not sleep)
                Ghostty.logger.info("App backgrounded with \(sshSessionCount) SSH session(s), scheduling 60s notification")
                NotificationManager.shared.scheduleSSHReminder(sessionCount: sshSessionCount)
            } else {
                Ghostty.logger.info("App backgrounded with \(sshSessionCount) SSH session(s) but background mode is active (location=\(locationEnabled), liveActivity=\(liveActivityActive))")
            }
        } else {
            Ghostty.logger.debug("App backgrounded with no SSH sessions")
        }

        if windowState != nil || (!terminalRefs.isEmpty && encryptionKey != nil) {
            LifecycleDebugLogger.shared.checkpoint("BG.persist.dispatched", ms: nil, [
                ("windowState", windowState != nil),
                ("scrollbackRefs", terminalRefs.count),
            ])
            let refCount = terminalRefs.count
            BackgroundPersistenceQueue.queue.async {
                let persistStart = CFAbsoluteTimeGetCurrent()
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.persist.start", ms: nil, [
                    ("refs", refCount),
                ])
                // Write window state to disk (JSON encode + file write)
                if let windowState {
                    WindowStateManager.writeStateToDisk(windowState)
                }

                // Save scrollback for each terminal (C API dump + encrypt + file write)
                if let encryptionKey {
                    for ref in terminalRefs {
                        ScrollbackPersistenceManager.saveScrollbackInBackground(
                            ref: ref,
                            encryptionKey: encryptionKey
                        )
                    }
                }
                LifecycleDebugLogger.shared.criticalCheckpoint("BG.persist.complete",
                    ms: (CFAbsoluteTimeGetCurrent() - persistStart) * 1000)
            }
        } else if !terminalRefs.isEmpty {
            // We have terminal refs but no encryption key — release in-flight markers
            // (already handled above in the catch block, but guard the skip-phase-2 path too)
            ScrollbackPersistenceManager.clearInFlightSurfaces(terminalRefs)
        }

        LifecycleDebugLogger.shared.checkpoint("BG.complete",
            ms: (CFAbsoluteTimeGetCurrent() - transitionStart) * 1000)
    }

    func handleAppForegrounded() {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        endShortRemoteSessionBackgroundTask(reason: "foreground")
        #endif

        WedgeBreadcrumbLogger.shared.critical("MainView.FG.enter", [
            ("scenePhase", String(describing: lifecycleScenePhase)),
        ])
        ForegroundWedgeWatchdog.shared.noteMainActorServiced("MainView.FG.enter")
        LifecycleDebugLogger.shared.logMarker("APP FOREGROUND")
        let bodyEvalsSinceLastEvent = LifecycleDebugLogger.shared.snapshotAndResetBodyEvaluation()
        LifecycleDebugLogger.shared.checkpoint("FG.enter", ms: nil, [
            ("scenePhase", String(describing: lifecycleScenePhase)),
            ("sheets", isAnySheetPresented),
            ("bodyEvals", bodyEvalsSinceLastEvent),
        ])
        guard lifecycleScenePhase == .active else {
            LifecycleDebugLogger.shared.checkpoint("FG.skipped", ms: nil, [
                ("reason", "notActive"),
                ("scenePhase", String(describing: lifecycleScenePhase)),
            ])
            return
        }
        resumeGhosttyAfterForegroundSceneUpdate()

        // VNC panes: automatic recovery that exhausted its attempts while
        // backgrounded parks the session in .failed with nothing left to
        // drive it. Nudge one manual retry now that the network is back
        // (.reconnecting panes keep driving themselves). Deferred off the
        // FrontBoard scene-update transaction like the rest of the resume.
        // Presentation resumes for EVERY pane, hidden tabs included: the
        // resume occlusion pass only reaches the visible tab, and a hidden
        // pane left presentation-suspended stops composing the frames the
        // Apple-login Vision pipeline consumes. The secure-draw latch keeps
        // covering any future lock at frame delivery.
        DispatchQueue.main.async { [self] in
            guard lifecycleScenePhase == .active else { return }
            for tab in terminals {
                for pane in tab.splitTree {
                    guard let vncPane = pane as? VNCPaneView else { continue }
                    vncPane.resumePresentationAfterForeground()
                    vncPane.nudgeRetryAfterForeground()
                }
            }
        }

        // Settle-time occlusion backstop. The resume's setOcclusion(true) for
        // the visible tab is deferred ~150ms past the resume quiet window
        // (gate4) and, on a background/foreground bounce, can be deferred again
        // or skipped — and post the GhosttyKit merge a missed un-occlusion is a
        // permanent render freeze, not a harmless soft-pause. Once the dangerous
        // scene-update/quiet window is well past, reconcile occlusion from
        // authoritative state so the visible surface is guaranteed a fresh
        // .visible = true even if every resume sub-path failed to deliver one.
        // Idempotent (a no-op in the core when already visible) and gated on
        // still-active; the epoch guard prevents acting after a re-background
        // during the delay. Mirrored from the [self] async pattern the resume
        // body already uses.
        let backstopBgEpoch = LifecycleEpoch.shared.background
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard LifecycleEpoch.shared.background == backstopBgEpoch else { return }
            reconcileSurfaceOcclusion(reason: "foregroundSettleBackstop")
        }
    }

    func resumeGhosttyAfterForegroundSceneUpdate() {
        // Defer the entire resume body off the current FrontBoard scene-update
        // transaction.
        //
        // The previous design (commit e8c040fa) chunked only the per-terminal
        // replayCachedSessionStateOnForeground() calls. Several other paths
        // remained synchronous on the transaction:
        //   - The atomic flip and the C-level `isInBackground = false` flip
        //     immediately re-opened the IO thread → MainActor pipeline. Action
        //     callbacks in GhosttyApp.swift unconditionally spawn
        //     `Task { @MainActor in handler() }` for SET_TITLE, PWD, RING_BELL
        //     etc., and those landed mid-transaction.
        //   - LocationDiaryManager.replayCachedStateOnForeground,
        //     SSHKeyManager.refreshKeys, and SSHPasswordManager.refreshPasswords
        //     all published synchronously inside the transaction.
        //   - setOcclusion(true) on visible terminals + the Metal renderer
        //     un-pause added UIKit responder-chain churn.
        // Cumulatively, these still tripped the FrontBoard scene state into a
        // partially-updated state on iPhone with buffered output — stuck tap
        // recognizers, dead keyboard input, force-quit required.
        //
        // Wrapping the body in a single outer DispatchQueue.main.async lets
        // the FrontBoard transaction commit *before* any of the resume work
        // runs. Cost: ~16 ms perceptual delay before visible-tab Metal
        // un-pauses on resume. Acceptable — the chunked-replay design already
        // ate that frame for visible-tab @Published flushes.
        //
        // Defense in depth: handleTitleChange / handlePwdChange /
        // applyConnectionHealth (TerminalView.swift) and the session-protocol
        // onTitleChange / onWorkingDirectoryChange (TerminalViewSession.swift)
        // now gate @Published writes on `isAppBackgroundedAtomic` instead of
        // `Ghostty.isAppBackgrounded` (the UIApplication-state read), so even
        // if a stray IO Task lands during the deferred frame it caches into
        // sessionProvided* without publishing.
        // Capture the lifecycle epoch at schedule time. The deferred body will
        // compare against the live value to detect a `handleAppBackgrounded`
        // that ran between this `.async` and the body firing.
        #if !targetEnvironment(macCatalyst)
        let scheduledAtBgEpoch = LifecycleEpoch.shared.background
        #else
        let scheduledAtBgEpoch: UInt64 = 0
        #endif
        LifecycleDebugLogger.shared.checkpoint("FG.deferred.scheduled")
        DispatchQueue.main.async { [self] in
            ForegroundActivationGate.shared.runWhenSafe(
                reason: "mainView.foregroundResume",
                timeoutPolicy: .fireIfNotBackgrounded
            ) {
                performForegroundResume(scheduledAtBgEpoch: scheduledAtBgEpoch)
            }
        }
    }

    @MainActor
    private func performForegroundResume(scheduledAtBgEpoch: UInt64) {
        let resumeStart = CFAbsoluteTimeGetCurrent()
        WedgeBreadcrumbLogger.shared.critical("MainView.FG.body.enter", [
            ("scenePhase", String(describing: lifecycleScenePhase)),
            ("scheduledAtBgEpoch", scheduledAtBgEpoch),
        ])
        ForegroundWedgeWatchdog.shared.noteMainActorServiced("MainView.FG.body.enter")
        LifecycleDebugLogger.shared.checkpoint("FG.body.enter", ms: nil, [
            ("scenePhase", String(describing: lifecycleScenePhase)),
            ("scheduledAtBgEpoch", scheduledAtBgEpoch),
        ])

        // Symmetric to the `BG.transition.skipped reason=rebounced` guard at
        // `performBackgroundTransition`. If `handleAppBackgrounded` ran between
        // when this body was scheduled and now, the lifecycle epoch advanced;
        // continuing the FG body would re-open the gate while the app is
        // actually backgrounded — observed to set up an `0x8BADF00D`
        // scene-update watchdog kill on the next transaction after
        // suspension/wake (caughtit 14:33:09 → .ips 14:35:01).
        //
        // The lifecycle phase captured at schedule time is unreliable across
        // the `.async` boundary, and `Ghostty.isAppBackgroundedAtomic` is held
        // TRUE through the entire backgrounded period — so neither can
        // distinguish a clean resume from a re-bounced one. The epoch can.
        #if !targetEnvironment(macCatalyst)
        let currentBgEpoch = LifecycleEpoch.shared.background
        guard currentBgEpoch == scheduledAtBgEpoch else {
            LifecycleDebugLogger.shared.checkpoint("FG.body.skipped", ms: nil, [
                ("reason", "backgroundedDuringDefer"),
                ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                ("currentBgEpoch", currentBgEpoch),
                ("scenePhaseCaptured", String(describing: lifecycleScenePhase)),
            ])
            return
        }
        #endif

        // Background gate flip is deferred to the END of this function. Reason:
        // tssh Go threads keep firing output callbacks the moment iOS
        // unsuspends the app — `emitOutputFromGoCallback` consults
        // `Ghostty.isAppBackgroundedAtomic` to decide buffer-vs-emit, and
        // flipping that gate up front opens the floodgate while SwiftUI is
        // still mid-foreground-transaction. With many tssh sessions on a
        // flaky network, the resulting per-session @Published mutations land
        // during scene-update and corrupt the SwiftUI view graph (tab bar
        // animates to wrong position, sheets that opened won't close, etc).
        // By flipping the gate after we've scheduled the chunked replay and
        // performed the synchronous resume work, the flush lands on a stable
        // view tree.

        updateWindowFocusState()
        LifecycleDebugLogger.shared.checkpoint("FG.windowFocus.updated")

        // Per-terminal foreground-replay work is still chunked across runloop
        // ticks so no single subsequent transaction absorbs the full
        // @Published replay storm. Visible-tab terminals are processed first
        // so the user sees updated state within ~16 ms; non-visible tabs
        // trail behind. Focus restoration happens after the visible tab's
        // chunks complete.
        let visibleTab = resolveVisibleTab()
        let visibleTabID = visibleTab?.id
        let visibleSplits: [Ghostty.TerminalView] = visibleTab.map { $0.splitTree.terminalLeaves } ?? []
        let otherSplits: [Ghostty.TerminalView] = terminals
            .filter { $0.id != visibleTabID }
            .flatMap { $0.splitTree.terminalLeaves }

        // BISECT GATE 4: defer setOcclusion(true) past the resume quiet
        // window AND defer the chunked replay to start after it.
        // Toggle via BisectFlags.gate4_setOcclusion.
        //
        // setOcclusion(true) calls ghostty_surface_set_occlusion via
        // Self.ghosttyAPIQueue.async and also calls
        // session?.setTabVisible(true) on main. The C-side occlusion flip
        // re-engages the surface's Metal renderer; under tssh load, that
        // re-engagement during the scene-update transaction has been
        // observed to stall the window's CADisplayLink-driven frame
        // advancement (symptom: UIScrollView inertia jerky, SwiftUI
        // animations step one frame per touch, watchdog freezes when no
        // touches arrive).
        //
        // The chunked replay calls resumeReconnectionUI -> clearSizeSuppression
        // -> sizeDidChange(bounds.size) on each visible terminal. If that
        // runs while the renderer is still flagged occluded (i.e. before
        // setOcclusion(true) lands), the grid resizes but the renderer
        // doesn't redraw, and when it later un-occludes it presents the
        // pre-background framebuffer at the wrong dimensions.
        //
        // To preserve both fixes (no wedge, correct size on resume), we
        // do BOTH in one deferred block fired after the quiet window:
        // setOcclusion first, then schedule the chunked replay. Both happen
        // outside the dangerous window, in the correct order.
        let focusedTerminal = visibleTab?.focusedTerminal
        let canRestoreFocus = !isAnySheetPresented

        let shouldDeferOcclusion =
        BisectFlags.gate4_setOcclusion && Ghostty.isInResumeQuietWindowAtomic
        LifecycleDebugLogger.shared.checkpoint("FG.occlusion.plan", ms: nil, [
            ("deferred", shouldDeferOcclusion),
            ("visible", visibleSplits.count),
            ("other", otherSplits.count),
        ])
        if shouldDeferOcclusion {
            LifecycleDebugLogger.shared.bumpSuppression("gate4_occlusion")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                LifecycleDebugLogger.shared.checkpoint("FG.occlusion.deferredFire")

                // A backgrounding that arrived during the 150 ms defer makes the
                // chunked replay stale (it re-publishes session state for the
                // prior resume), so we always skip that. The occlusion handling
                // is conditional: see below.
                #if !targetEnvironment(macCatalyst)
                let occCurrentBgEpoch = LifecycleEpoch.shared.background
                if occCurrentBgEpoch != scheduledAtBgEpoch {
                    // A background/foreground bounce happened during the 150ms
                    // defer. The chunked replay is stale (it re-publishes
                    // session state captured for the prior resume) and must not
                    // run — so we still skip it. But we must NOT strand the
                    // visible surfaces occluded: post the GhosttyKit merge, a
                    // surface left at flags.visible == false hard-stops its
                    // render thread until an explicit un-occlusion (permanent
                    // freeze). The old code relied on "the next genuine resume"
                    // to un-occlude, but a second bounce inside the window means
                    // that never lands. If the app is active again, re-assert
                    // occlusion for the now-selected tab here; only when still
                    // backgrounded do we skip entirely (un-occluding a hidden
                    // surface would be wrong). The settle-time backstop in
                    // handleAppForegrounded is the final guarantee.
                    LifecycleDebugLogger.shared.checkpoint("FG.occlusion.skipped", ms: nil, [
                        ("reason", "backgroundedDuringDefer"),
                        ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                        ("currentBgEpoch", occCurrentBgEpoch),
                        ("active", lifecycleScenePhase == .active),
                    ])
                    if lifecycleScenePhase == .active {
                        reconcileSurfaceOcclusion(reason: "gate4.bouncedSkip")
                    }
                    return
                }
                #endif

                guard !Ghostty.isInResumeQuietWindowAtomic else {
                    // A new background/foreground bounce extended the window.
                    // Run setOcclusion immediately for the user-visible work
                    // — staying paused longer just compounds the size issue —
                    // and let the next resume's deferred block handle the
                    // chunked replay. All panes: VNC panes clear their
                    // presentation suspend through setOcclusion(true) too.
                    let currentVisiblePanes: [SplitPaneView] =
                        resolveVisibleTab().map { Array($0.splitTree) } ?? []
                    for pane in currentVisiblePanes {
                        pane.setOcclusion(true)
                    }
                    LifecycleDebugLogger.shared.checkpoint("FG.occlusion.bouncedFire", ms: nil, [
                        ("visible", currentVisiblePanes.count),
                    ])
                    return
                }
                // Re-resolve at fire time — user may have switched tabs.
                let currentTab = resolveVisibleTab()
                let currentTabID = currentTab?.id
                let currentVisible: [Ghostty.TerminalView] =
                    currentTab.map { $0.splitTree.terminalLeaves } ?? []
                let currentOther: [Ghostty.TerminalView] = terminals
                    .filter { $0.id != currentTabID }
                    .flatMap { $0.splitTree.terminalLeaves }

                // 1. setOcclusion FIRST so the renderer is un-paused before
                //    the chunked replay's clearSizeSuppression -> sizeDidChange
                //    fires for that terminal. All panes, so VNC presentation
                //    resumes alongside the terminal renderers.
                let occStart = CFAbsoluteTimeGetCurrent()
                let currentVisiblePanes: [SplitPaneView] =
                    currentTab.map { Array($0.splitTree) } ?? []
                for pane in currentVisiblePanes {
                    pane.setOcclusion(true)
                }
                LifecycleDebugLogger.shared.checkpoint("FG.occlusion.fire",
                    ms: (CFAbsoluteTimeGetCurrent() - occStart) * 1000,
                    [("visible", currentVisible.count)])

                // 2. Now schedule the chunked replay; its first step() runs
                //    on the next runloop tick with the renderer already
                //    un-paused.
                self.scheduleDeferredForegroundReplay(
                    visibleSplits: currentVisible,
                    otherSplits: currentOther,
                    focusedTerminal: currentTab?.focusedTerminal,
                    canRestoreFocus: !self.isAnySheetPresented,
                    bodyEpoch: scheduledAtBgEpoch
                )
            }
        } else {
            let occStart = CFAbsoluteTimeGetCurrent()
            let visiblePanes: [SplitPaneView] = visibleTab.map { Array($0.splitTree) } ?? []
            for pane in visiblePanes {
                pane.setOcclusion(true)
                if pane.asTerminal != nil {
                    ghosttyApp.appTick()
                }
            }
            LifecycleDebugLogger.shared.checkpoint("FG.occlusion.fireSync",
                ms: (CFAbsoluteTimeGetCurrent() - occStart) * 1000,
                [("visible", visiblePanes.count)])
            scheduleDeferredForegroundReplay(
                visibleSplits: visibleSplits,
                otherSplits: otherSplits,
                focusedTerminal: focusedTerminal,
                canRestoreFocus: canRestoreFocus,
                bodyEpoch: scheduledAtBgEpoch
            )
        }

        #if !targetEnvironment(macCatalyst)
        resyncSelectionHandlesAfterTransientOcclusion()
        #endif

        // Fire a single coalesced `objectWillChange` from any manager that
        // suppresses per-event publishes during background. Without this,
        // observers (Settings sheet, sidebars) that survive backgrounding
        // would never see the accumulated changes — and conversely, if we
        // didn't suppress in the first place, every per-event publish would
        // queue a body invalidation that drains in one expensive transaction
        // on resume, tripping the scene-update watchdog.
        let locDiaryStart = CFAbsoluteTimeGetCurrent()
        LocationDiaryManager.shared.replayCachedStateOnForeground()
        LifecycleDebugLogger.shared.checkpoint("FG.locDiary.replay",
            ms: (CFAbsoluteTimeGetCurrent() - locDiaryStart) * 1000)

        // NOTE: NetworkReachabilityMonitor's background-path replay must
        // happen AFTER `Ghostty.isAppBackgroundedAtomic` is flipped to
        // false (see the trailing dispatch at the end of this function,
        // search for `FG.gate.flipped`). TrzszSession, MoshSession, and
        // others drop network events while that atomic is true; a replay
        // before the gate flip would be drained without effect.

        // Resume ocean animation without catch-up
        if let effect = EffectManager.shared.activeEffect,
           let solarEffect = effect.asEffect(SolarGraphEffect.self) {
            solarEffect.didReturnFromBackground()
        }

        // Cancel any pending SSH reminder notifications
        Ghostty.logger.debug("App foregrounded, cancelling pending notifications")
        NotificationManager.shared.cancelPendingNotifications()
        LifecycleDebugLogger.shared.checkpoint("FG.cancelNotifications")

        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        // Defer onto the next runloop tick. `reconcileAfterActivation` reads
        // `Activity<…>.activities` (XPC to liveactivitiesd) and runs
        // `filteredContentState(at:)`, both of which can stall on first-touch
        // when the system is contended. Pushing past this tick keeps that
        // work off the FrontBoard scene-update transaction even if it
        // synchronously blocks for several seconds.
        LifecycleDebugLogger.shared.checkpoint("FG.liveActivity.scheduled")
        DispatchQueue.main.async {
            // Per-tick epoch check: if a backgrounding arrived between when
            // this closure was scheduled and now, do not reconcile — the
            // Live Activity ContentState we'd publish reflects a foreground
            // assumption and would land in a background scene-update.
            let liveActivityCurrentBgEpoch = LifecycleEpoch.shared.background
            guard liveActivityCurrentBgEpoch == scheduledAtBgEpoch else {
                LifecycleDebugLogger.shared.checkpoint("FG.liveActivity.skipped", ms: nil, [
                    ("reason", "backgroundedDuringDefer"),
                    ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                    ("currentBgEpoch", liveActivityCurrentBgEpoch),
                ])
                return
            }
            LiveActivityManager.shared.reconcileAfterActivation()
        }
        #endif

        // Refresh SSH keys in case new ones synced via iCloud.
        //
        // The original `refreshKeys()` / `refreshPasswords()` entry points
        // are general-purpose (also called from SwiftUI `.refreshable`,
        // settings UI, etc.) and unconditionally enqueue a Task that mutates
        // observable state when the keychain read returns. From the FG body,
        // we instead schedule our own epoch-gated Task that only invokes the
        // async variant if no `handleAppBackgrounded` ran between this body
        // and the Task firing. Otherwise the @Published `savedKeys` /
        // `savedPasswords` mutations would land on a backgrounded scene
        // (logs at 13:32:58 / 14:06:27 show SSH refresh starts firing after
        // BG.atomic.set in the FG-then-immediate-BG bounce).
        //
        // Note: this catches BG between Task scheduling and Task body firing
        // (the wide window). A subsequent BG that arrives during the
        // `Task.detached` keychain read inside `refreshKeysAsync` would
        // still apply — that residual gap is small (cached keychain reads
        // complete in ms) and would need a per-apply guard inside the
        // manager APIs to fully close.
        LifecycleDebugLogger.shared.checkpoint("FG.sshKeys.refresh.dispatched")
        Task { @MainActor in
            #if !targetEnvironment(macCatalyst)
            let sshKeyCurrentBgEpoch = LifecycleEpoch.shared.background
            guard sshKeyCurrentBgEpoch == scheduledAtBgEpoch else {
                LifecycleDebugLogger.shared.checkpoint("SSHKey.refresh.skipped", ms: nil, [
                    ("reason", "backgroundedDuringDefer"),
                    ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                    ("currentBgEpoch", sshKeyCurrentBgEpoch),
                ])
                return
            }
            #endif
            let start = CFAbsoluteTimeGetCurrent()
            LifecycleDebugLogger.shared.checkpoint("SSHKey.refresh.start")
            // Pass the lifecycle guard to refreshKeysAsync — checked AFTER
            // the detached Keychain read but BEFORE the @Published savedKeys
            // mutation, closing the residual race the pre-await guard above
            // cannot cover.
            #if !targetEnvironment(macCatalyst)
            await SSHKeyManager.shared.refreshKeysAsync(shouldApply: {
                LifecycleEpoch.shared.background == scheduledAtBgEpoch
            })
            #else
            await SSHKeyManager.shared.refreshKeysAsync()
            #endif
            LifecycleDebugLogger.shared.checkpoint("SSHKey.refresh.complete",
                ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        Task { @MainActor in
            #if !targetEnvironment(macCatalyst)
            let sshPwdCurrentBgEpoch = LifecycleEpoch.shared.background
            guard sshPwdCurrentBgEpoch == scheduledAtBgEpoch else {
                LifecycleDebugLogger.shared.checkpoint("SSHPwd.refresh.skipped", ms: nil, [
                    ("reason", "backgroundedDuringDefer"),
                    ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                    ("currentBgEpoch", sshPwdCurrentBgEpoch),
                ])
                return
            }
            #endif
            let start = CFAbsoluteTimeGetCurrent()
            LifecycleDebugLogger.shared.checkpoint("SSHPwd.refresh.start")
            #if !targetEnvironment(macCatalyst)
            await SSHPasswordManager.shared.refreshPasswordsAsync(shouldApply: {
                LifecycleEpoch.shared.background == scheduledAtBgEpoch
            })
            #else
            await SSHPasswordManager.shared.refreshPasswordsAsync()
            #endif
            LifecycleDebugLogger.shared.checkpoint("SSHPwd.refresh.complete",
                ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        // Refresh GPG keys in case new ones synced via iCloud Keychain.
        // GPGKeyManager doesn't (yet) carry the epoch-gated apply-guard
        // SSHKeyManager has — the read is cheap and the only consumer is
        // the GPG settings list / agent forwarding picker, so a stray
        // mutation on a backgrounded scene is harmless here.
        Task { @MainActor in
            let start = CFAbsoluteTimeGetCurrent()
            LifecycleDebugLogger.shared.checkpoint("GPGKey.refresh.start")
            await GPGKeyManager.shared.refreshKeysAsync()
            LifecycleDebugLogger.shared.checkpoint("GPGKey.refresh.complete",
                ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        // Sync CloudKit data on foreground (connection history, known hosts)
        LifecycleDebugLogger.shared.checkpoint("FG.cloudKit.sync.scheduled")
        Task { @MainActor in
            // Per-Task epoch check: if a backgrounding arrived between Task
            // creation and execution, skip the sync. CloudKit syncs on a
            // background scene-update can run while the app is suspended-
            // pending, racing with persistence writes from
            // `performBackgroundTransition`.
            #if !targetEnvironment(macCatalyst)
            let cloudKitCurrentBgEpoch = LifecycleEpoch.shared.background
            guard cloudKitCurrentBgEpoch == scheduledAtBgEpoch else {
                LifecycleDebugLogger.shared.checkpoint("FG.cloudKit.sync.skipped", ms: nil, [
                    ("reason", "backgroundedDuringDefer"),
                    ("scheduledAtBgEpoch", scheduledAtBgEpoch),
                    ("currentBgEpoch", cloudKitCurrentBgEpoch),
                ])
                return
            }
            #endif
            let syncStart = CFAbsoluteTimeGetCurrent()
            try? await CloudKitSyncManager.shared.syncNow()
            LifecycleDebugLogger.shared.checkpoint("FG.cloudKit.sync.complete",
                ms: (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
        }

        // ---- Open the gates LAST, after a chunked drain ----
        //
        // Just deferring the atomic flip to a later tick wasn't enough — it
        // shifted the flood by one tick but didn't *throttle* it. With many
        // tssh sessions, all Go threads see the atomic flip near-simultaneously
        // and each calls `outputSink.emit` on its own thread, queuing per-
        // session main-actor Tasks back-to-back. The resulting cluster of
        // @Published / @Observable mutations has been corrupting the SwiftUI
        // graph globally (not just the tab bar) — sheets that opened won't
        // close, animated layouts end up at wrong positions, etc.
        //
        // Instead, drain each tssh session's buffer ourselves on its own
        // runloop tick *while the atomic is still true* (so new bytes still
        // land in the right buffer). Once every session has been drained,
        // flip the gate. New bytes from then on flow normally; the existing
        // chunked replay infrastructure handles the per-terminal @Published
        // catch-up.
        let trzszSessions: [TrzszSession] = terminals.flatMap { $0.splitTree.terminalLeaves }
            .compactMap { $0.session as? TrzszSession }
        LifecycleDebugLogger.shared.checkpoint("FG.drain.scheduled", ms: nil, [
            ("trzszSessions", trzszSessions.count),
            ("resumeBody_ms", String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - resumeStart) * 1000)),
        ])
        // Capture the live epoch as the body's "base" — passed through every
        // drain tick to the trailing gate-flip closure. If a background
        // transition arrives mid-drain, the epoch advances and the gate flip
        // skips. (We use `scheduledAtBgEpoch` here because the entry guard
        // above proved no BG happened between schedule and now, so it equals
        // the live value.)
        drainTrzszSessionsThenOpenGate(remaining: trzszSessions, bodyEpoch: scheduledAtBgEpoch)
    }

    /// Drain one tssh session per runloop tick, then flip the background
    /// atomic to unblock new Go-thread output. See call site in
    /// `performForegroundResume()` for rationale.
    ///
    /// `bodyEpoch` is the lifecycle background epoch captured when the FG body
    /// began. The trailing gate-flip aborts if a `handleAppBackgrounded` ran
    /// between then and now (epoch advanced).
    @MainActor
    private func drainTrzszSessionsThenOpenGate(remaining: [TrzszSession], bodyEpoch: UInt64) {
        if let next = remaining.first {
            let rest = Array(remaining.dropFirst())
            DispatchQueue.main.async {
                // Per-tick epoch check: if a backgrounding arrived between
                // when this tick was queued and now, do NOT call
                // flushBackgroundedOutputEarly() — that would drain the tssh
                // session's buffered output into Ghostty during a background
                // scene-update. Leave the buffer intact for the next real
                // foreground resume; abort the entire drain chain so the
                // trailing gate flip also doesn't fire (it would skip on its
                // own epoch check anyway).
                #if !targetEnvironment(macCatalyst)
                let tickCurrentBgEpoch = LifecycleEpoch.shared.background
                guard tickCurrentBgEpoch == bodyEpoch else {
                    LifecycleDebugLogger.shared.checkpoint("FG.drain.skipped", ms: nil, [
                        ("reason", "backgroundedDuringDrain"),
                        ("bodyEpoch", bodyEpoch),
                        ("currentBgEpoch", tickCurrentBgEpoch),
                        ("queued", rest.count + 1),
                    ])
                    return
                }
                #endif
                let tickStart = CFAbsoluteTimeGetCurrent()
                let hasMore = next.flushBackgroundedOutputEarly()
                LifecycleDebugLogger.shared.checkpoint("FG.drain.tick",
                    ms: (CFAbsoluteTimeGetCurrent() - tickStart) * 1000,
                    [("hasMore", hasMore), ("queued", rest.count)])
                self.drainTrzszSessionsThenOpenGate(
                    remaining: hasMore ? rest + [next] : rest,
                    bodyEpoch: bodyEpoch
                )
            }
            return
        }

        // All sessions drained — open the gate on one final deferred tick so
        // SwiftUI gets a clean frame between the last drain and any further
        // Go-driven mutations.
        DispatchQueue.main.async { [ghosttyApp] in
            #if !targetEnvironment(macCatalyst)
            // Belt-and-suspenders to the FG.body.skipped guard at body entry.
            // The drain chain above spans many runloop ticks; a backgrounding
            // that arrives mid-drain advances the lifecycle epoch and must not
            // be undone by this trailing flip — the queued
            // `performBackgroundTransition` owns the state now.
            let currentBgEpoch = LifecycleEpoch.shared.background
            let applicationState = UIApplication.shared.applicationState
            guard currentBgEpoch == bodyEpoch, applicationState == .active else {
                LifecycleDebugLogger.shared.checkpoint("FG.gate.skipped", ms: nil, [
                    ("reason", "rebackgroundedDuringDrain"),
                    ("bodyEpoch", bodyEpoch),
                    ("currentBgEpoch", currentBgEpoch),
                    ("appState", applicationState),
                ])
                return
            }
            ghosttyApp.isInBackground = false
            Ghostty.isAppBackgroundedAtomic = false
            #endif
            let suppressedSnapshot = LifecycleDebugLogger.shared.snapshotAndResetSuppression()
            LifecycleDebugLogger.shared.checkpoint("FG.gate.flipped", ms: nil, [
                ("suppressed", suppressedSnapshot),
            ])

            self.resumeNetworkMonitorsAfterForegroundGate()

            // Replay the latest NWPath that arrived while backgrounded.
            // Must run AFTER the atomic flip above so subscribers like
            // TrzszSession (which drop network events while the atomic is
            // true) actually receive the published changes. Synthesizes a
            // `connectivityRestored` send if the network flapped during
            // suspension and recovered before this resume — see the
            // method doc on `replayBackgroundPathIfAny()`.
            NetworkReachabilityMonitor.shared.replayBackgroundPathIfAny()

            for session in self.terminals.flatMap({ $0.splitTree.terminalLeaves }).compactMap({ $0.session as? TrzszSession }) {
                session.flushBackgroundedOutputFully()
            }

            // BISECT GATE 3: defer the appTick mailbox drain during the
            // resume quiet window. Toggle via BisectFlags.gate3_appTick.
            // appTick() processes every buffered event synchronously; each
            // fires action callbacks (SET_TITLE, PWD, RING_BELL, ...) that
            // spawn @MainActor Tasks which mutate per-terminal @Published
            // title/pwd. With many sessions and accumulated background
            // events, that cluster of mutations hitting the SwiftUI graph
            // during the scene-update settling window is a strong wedge
            // candidate. The deferred tick retries until the quiet window
            // closes, so we do not depend on a later wakeup_cb to drain the
            // mailbox.
            Task { @MainActor [ghosttyApp] in
                ghosttyApp.appTickAfterResumeQuietWindow()
            }
            LifecycleDebugLogger.shared.checkpoint("FG.complete")
        }
    }

    /// Schedule the per-terminal foreground-resume work across runloop ticks
    /// so no single FrontBoard scene-update transaction has to absorb the
    /// full @Published replay storm.
    ///
    /// Visible-tab terminals are processed first (so the user sees updated
    /// state within ~16 ms); focus restoration runs as soon as the visible
    /// tab's chunks complete (without waiting for non-visible tabs);
    /// non-visible tabs trail behind in the same chunked queue.
    ///
    /// `bodyEpoch` is the lifecycle background epoch captured when the FG body
    /// began. Each chunk re-checks the live epoch before doing
    /// `resumeReconnectionUI()` / `replayCachedSessionStateOnForeground()` /
    /// focus restore — a backgrounding mid-replay aborts the remainder so we
    /// don't re-enable PTY sizing or publish cached state during a
    /// background scene-update.
    @MainActor
    private func scheduleDeferredForegroundReplay(
        visibleSplits: [Ghostty.TerminalView],
        otherSplits: [Ghostty.TerminalView],
        focusedTerminal: Ghostty.TerminalView?,
        canRestoreFocus: Bool,
        bodyEpoch: UInt64
    ) {
        // Tunable: max terminals processed per runloop tick. Each terminal
        // pushes ~3 cached @Published properties (title / pwd / health), so
        // a chunk size of 3 caps body-invalidation work per tick at ~9
        // observable mutations — well under the empirical FrontBoard budget
        // that produces the corruption symptom.
        let chunkSize = 3
        let combined = visibleSplits + otherSplits
        let visibleCount = visibleSplits.count

        var index = 0
        var focusRestored = visibleCount == 0  // nothing to wait for if no visible

        func step() {
            // Per-chunk epoch check: a backgrounding that arrived since this
            // step was queued must abort the rest of the replay. Skip focus
            // restore, skip the chunk, do not schedule further ticks.
            #if !targetEnvironment(macCatalyst)
            let stepCurrentBgEpoch = LifecycleEpoch.shared.background
            guard stepCurrentBgEpoch == bodyEpoch else {
                LifecycleDebugLogger.shared.checkpoint("FG.replay.skipped", ms: nil, [
                    ("reason", "backgroundedDuringReplay"),
                    ("bodyEpoch", bodyEpoch),
                    ("currentBgEpoch", stepCurrentBgEpoch),
                    ("range", "\(index)..\(combined.count)"),
                ])
                return
            }
            #endif

            // Visible-tab chunks done? Restore focus before continuing the
            // non-visible queue. (Idempotent guard via focusRestored.)
            if !focusRestored, index >= visibleCount {
                focusRestored = true
                if canRestoreFocus,
                   let terminal = focusedTerminal,
                   terminal.isLogicallyFocused, !terminal.isFirstResponder {
                    Ghostty.logger.info("Restoring focus after deferred foreground replay")
                    _ = terminal.becomeFirstResponder()
                    LifecycleDebugLogger.shared.checkpoint("FG.focus.restored")
                } else if !canRestoreFocus {
                    Ghostty.logger.info("Skipping focus restoration: sheet is presented")
                    LifecycleDebugLogger.shared.checkpoint("FG.focus.skipped", ms: nil, [
                        ("reason", "sheetPresented"),
                    ])
                }
            }

            guard index < combined.count else { return }
            let endIndex = min(index + chunkSize, combined.count)
            let chunkStart = CFAbsoluteTimeGetCurrent()
            for i in index..<endIndex {
                combined[i].resumeReconnectionUI()
                combined[i].replayCachedSessionStateOnForeground()
            }
            LifecycleDebugLogger.shared.checkpoint("FG.replay.step",
                ms: (CFAbsoluteTimeGetCurrent() - chunkStart) * 1000,
                [("range", "\(index)..\(endIndex)/\(combined.count)")])
            index = endIndex

            // Each chunk runs in its own runloop tick. Nesting the async
            // submission (rather than scheduling all chunks up front) is
            // what guarantees separate ticks: multiple async submissions
            // from the same runloop iteration would all run together in the
            // next iteration.
            DispatchQueue.main.async { step() }
        }

        DispatchQueue.main.async { step() }
    }
}

// MARK: - Remote Session Tracking

extension MainView {

    /// Synchronize session counts for this window.
    /// The census itself lives in WindowSessionCensus; this forwarder keeps
    /// the existing call sites across the MainView extensions unchanged.
    func notifySessionCountChanged() {
        // External window: its scene id must never key census entries.
        WindowSessionCensus.publish(
            tabs: terminals,
            windowId: windowId,
            sceneSessionId: isExternalDisplayWindow ? nil : windowSceneSessionID
        )
    }
}
