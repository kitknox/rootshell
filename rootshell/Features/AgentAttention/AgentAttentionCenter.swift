//
//  AgentAttentionCenter.swift
//  rootshell
//
//  The event-driven engine behind the agent inbox. Ghostty emits one
//  coalesced content edge for the exact surface that changed (ordinary or
//  tmux child pane); this center schedules only that pane's bounded scan.
//
//  Ownership: the center owns monitors STRONGLY, and the monitor set is
//  recomputed from live TabsModel state whenever tab/pane topology changes.
//
//  Overhead contract: the master toggle (`agentDetectionEnabled`) is a
//  hard kill switch — off means no monitors, no core content events, and
//  no scheduled task. When enabled but idle the deadline queues are empty,
//  so there is likewise no timer or repeated work.
//

import Foundation
import UIKit
import os.log

/// Settings keys for the feature. `detectionEnabledKey` gates the entire
/// engine; `badgesEnabledKey` gates rendering only.
nonisolated enum AgentAttentionSettings {
    static let detectionEnabledKey = "agentDetectionEnabled"
    static let badgesEnabledKey = "agentAttentionBadgesEnabled"
    static let sortKey = "agentInboxSort"

    /// Gates every out-of-band command this feature runs — tmux queries and
    /// SSH exec channels alike. Off leaves only pushed evidence (OSC 7), so
    /// the project line degrades rather than vanishing, and no branch is
    /// resolved at all (there is no local repository to read: agents run on
    /// the far end). (id=agent-project)
    static let projectProbesEnabledKey = "agentProjectProbes"

    /// Whether a "needs input" notification may quote the question from the
    /// pane's screen. Off keeps terminal text off the Lock Screen; the body
    /// then falls back to the project and timing lines. Gates the extraction
    /// itself, not just the delivery.
    static let notificationPromptEnabledKey = "agentNotificationIncludePrompt"

    nonisolated static var detectionEnabled: Bool {
        SettingsStore.shared.value(Settings.CodingAgents.detectionEnabled)
    }

    nonisolated static var badgesEnabled: Bool {
        SettingsStore.shared.value(Settings.CodingAgents.attentionBadges)
    }

    /// The sidebar's inbox sort is set to project grouping. Read by TabsModel
    /// so the tab bar can scope to the selected tab's project even before the
    /// sidebar has ever been opened this launch. (id=agent-project)
    nonisolated static var projectGroupingSelected: Bool {
        SettingsStore.shared.value(Settings.CodingAgents.inboxSort) == "project" && badgesEnabled
    }

    nonisolated static var projectProbesEnabled: Bool {
        SettingsStore.shared.value(Settings.CodingAgents.projectProbes)
    }

    nonisolated static var notificationPromptEnabled: Bool {
        SettingsStore.shared.value(Settings.Notifications.agentIncludePrompt)
    }

    /// The scan engine runs when EITHER detection category is on; each
    /// category then filters what it acts on. Rendering, usage tracking,
    /// and project probes stay owned by the agent switch.
    nonisolated static var anyDetectionEnabled: Bool {
        detectionEnabled || TaskDetectionSettings.enabled
    }
}

/// Settings keys for task detection (long-running commands and input
/// prompts). A separate feature switch from coding agents: the master
/// defaults OFF (a new heuristic surface is opt-in), the per-family
/// toggles default ON so one switch lights the whole feature.
nonisolated enum TaskDetectionSettings {
    static let enabledKey = "taskDetectionEnabled"

    static func familyKey(_ family: TaskFamily) -> SettingKey<Bool> {
        switch family {
        case .prompts: return Settings.Notifications.taskDetectPrompts
        case .tests: return Settings.Notifications.taskDetectTests
        case .builds: return Settings.Notifications.taskDetectBuilds
        case .infra: return Settings.Notifications.taskDetectInfra
        case .transfers: return Settings.Notifications.taskDetectTransfers
        }
    }

    nonisolated static var enabled: Bool {
        SettingsStore.shared.value(Settings.Notifications.taskDetection)
    }

    nonisolated static func familyEnabled(_ family: TaskFamily) -> Bool {
        SettingsStore.shared.value(familyKey(family))
    }

    nonisolated static var enabledFamilies: Set<TaskFamily> {
        Set(TaskFamily.allCases.filter { familyEnabled($0) })
    }
}

@MainActor
@Observable
final class AgentAttentionCenter {
    static let shared = AgentAttentionCenter()

    /// Failures that stop a probe, plus 📋/🔀 detection diagnostics gated on
    /// `AgentDetectionCapture` recording. The feature is silent at steady
    /// state; nothing here carries a path, hostname, branch name or any
    /// terminal text, and anything a rule matched on belongs in the capture
    /// file instead.
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell", category: "AgentAttention")

    /// Bumped once per publish pass that changed anything. Views that
    /// aggregate across tabs (rollup chip, sort) read this to register
    /// the Observation dependency; the value itself is meaningless.
    private(set) var revision: UInt64 = 0

    /// Strongly-owned per-pane monitors, keyed by pane UUID.
    @ObservationIgnored private var monitors: [UUID: AgentPaneMonitor] = [:]

    /// herdr reports that arrived before their pane had a monitor.
    /// (id=herdr-agent-authority)
    private struct PendingHerdrReport {
        let status: AgentAttentionStatus
        let agentID: String?
        let displayName: String?
    }
    @ObservationIgnored private var pendingHerdrReports: [UUID: PendingHerdrReport] = [:]
    @ObservationIgnored private var pendingHerdrProjectPaths: [UUID: String] = [:]

    /// Gateways with a pane-directory query outstanding. One query answers for
    /// every pane on a gateway, so several panes identifying at once must not
    /// each fire one. (id=agent-project)
    @ObservationIgnored private var tmuxProjectQueriesInFlight: Set<UUID> = []

    /// Hosts with a repository probe outstanding, keyed by connection identity
    /// so panes on the same box coalesce onto one exec channel.
    @ObservationIgnored private var projectProbesInFlight: Set<String> = []

    /// Hosts that gained work while a probe was mid-flight. At most one rerun
    /// is ever queued per host, matching the `.idle | .inFlight(rerunPending:)`
    /// shape rather than an unbounded queue. (id=agent-project)
    @ObservationIgnored private var projectProbesRerunPending: Set<String> = []

    /// Invalidates results dispatched before project lookup was disabled.
    /// The command may already be running on a transport that cannot cancel
    /// it, but its answer must not repopulate hidden branch details.
    @ObservationIgnored private var projectProbeEpoch: UInt64 = 0

    /// A negative `command -v git` answer is stable enough to suppress retry
    /// loops, but not permanent: git can be installed, PATH can change, and a
    /// reconnect may land in a different environment. Scope it to the live
    /// session and let it expire. (id=agent-project)
    @ObservationIgnored private var projectGitUnavailableUntil: [ObjectIdentifier: Date] = [:]

    @ObservationIgnored private var projectHostProbeHealth:
        [String: AgentRepositoryHostProbeHealth] = [:]

    private typealias ProbedPath = AgentRepositoryPathKey

    /// Repository facts per answered directory, INCLUDING "not a repository"
    /// (an empty value), which is a real answer and stops a plain directory
    /// being re-probed forever.
    ///
    /// Caching the ANSWER, not merely the question: an earlier version stored
    /// only which paths had been asked about, so a second agent starting in an
    /// already-probed directory was skipped as answered and never received a
    /// branch at all. (id=agent-project)
    @ObservationIgnored private var repositoryState = AgentRepositoryRefreshState()

    /// `$HOME` per host, learned from the probe, so a remote path can be shown
    /// against the RIGHT home rather than this device's.
    @ObservationIgnored private var remoteHomes: [String: String] = [:]

    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledWakeDeadline: Date?
    @ObservationIgnored private var scanDeadlines = AgentAttentionDeadlineQueue<UUID>()
    @ObservationIgnored private var livenessDeadlines = AgentAttentionDeadlineQueue<UUID>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var stateChangeSeq: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var foregroundActive = true
    @ObservationIgnored private var coreEventsEnabled = false
    @ObservationIgnored private var wasEnabled = false
    @ObservationIgnored private var burstScansRemaining = 0

    private enum Tuning {
        /// Heavy-read budget per deadline firing, app-wide.
        static let maxScansPerWake = 3
        static let burstScansPerWake = 8
        static let initialBurstScans = 40
        static let overflowDelay: TimeInterval = 0.05
        static let contentQuiescence: TimeInterval = 0.075
        static let selectedInterval: TimeInterval = 0.9
        static let activeBackgroundInterval: TimeInterval = 2.0
        static let idleInterval: TimeInterval = 3.0
        static let identityInterval: TimeInterval = 1.0
        static let stateConfirmationInterval: TimeInterval = 0.8
        /// Re-read cadence while background agents are running: fast
        /// enough that a row's timer visibly advances between scans, slow
        /// enough to stay well inside the fleet working grace.
        static let fleetPollInterval: TimeInterval = 3.0

        /// Floor between project-resolution attempts for one pane. Long
        /// enough that a host which simply cannot answer is not retried in a
        /// loop, short enough that a gateway which was mid-attach at
        /// identification resolves within a few seconds of settling.
        /// (id=agent-project)
        static let projectRetryInterval: TimeInterval = 8.0
        /// A noisy shell can emit command-finished marks continuously. Dirty
        /// answers may refresh sooner than the five-minute TTL, but never more
        /// often than this per host unless an uncached path needs its first
        /// answer.
        static let projectEarlyRefreshFloor: TimeInterval = 60
        static let projectFailureBackoffLimit: TimeInterval = 5 * 60
        static let projectNoGitTTL: TimeInterval = 30 * 60
        static let noSignalInterval: TimeInterval = 0.75
        static let resizeSettleDelay: TimeInterval = 0.25
        /// Margin past a rebuild's deadline for the wake that runs the
        /// rebaseline comparison.
        static let rebuildRebaselineDelay: TimeInterval = 0.25
    }

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent; called from window-scene connect (alongside
    /// TmuxWindowRegistry registration).
    func ensureStarted() {
        guard !started else {
            topologyDidChange()
            return
        }
        started = true

        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentAttentionCenter.shared.applicationDidBecomeActive()
            }
        }
        let background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentAttentionCenter.shared.applicationDidEnterBackground()
            }
        }
        let keyWindow = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentAttentionCenter.shared.visibilityDidChange()
            }
        }
        observers = [foreground, background, keyWindow]
        foregroundActive = !Ghostty.isAppBackgrounded
        reconcileEnabledCategories()
    }

    /// Immediate agent-switch application. This is called directly by the
    /// settings toggle so disabling does not wait for a poll. The scan
    /// engine itself keeps running while task detection stays on.
    func setDetectionEnabled(_ enabled: Bool) {
        guard started else { return }
        if !enabled { clearAgentCategory() }
        reconcileEnabledCategories()
    }

    /// Immediate task-switch application, the task category's mirror of
    /// `setDetectionEnabled`.
    func setTaskDetectionEnabled(_ enabled: Bool) {
        guard started else { return }
        if !enabled { clearTaskCategory() }
        reconcileEnabledCategories()
    }

    /// A per-family toggle changed: drop any tracker holding (or showing a
    /// completion for) a family that is now off.
    func taskFamiliesChanged() {
        guard started, wasEnabled else { return }
        let families = TaskDetectionSettings.enabledFamilies
        var changed = false
        for monitor in monitors.values {
            let family = monitor.taskTracker.family ?? monitor.taskTracker.finishedFamily
            if let family, !families.contains(family) {
                monitor.resetTaskTracker()
                AgentAttentionNotificationRouter.paneRemoved(monitor.paneUUID, category: .task)
                changed = true
            }
        }
        if changed { publish(now: Date()) }
    }

    /// The engine runs when EITHER category is enabled; both off is the
    /// only state with no monitors, no core content events, and no timer.
    private func reconcileEnabledCategories() {
        guard started else { return }
        guard AgentAttentionSettings.anyDetectionEnabled else {
            teardownAll()
            return
        }

        // Usage tracking rides on agent presence, so the agent switch owns
        // its lifecycle; its own setting decides whether it then runs.
        AgentUsageCenter.shared.setEnabled(
            AgentAttentionSettings.detectionEnabled && AgentUsageSettings.enabled)
        wasEnabled = true
        guard foregroundActive, !Ghostty.isAppBackgrounded else {
            setCoreEventsEnabled(false)
            return
        }
        setCoreEventsEnabled(true)
        burstScansRemaining = Tuning.initialBurstScans
        let topologyChanged = reconcile(scheduleInitialScans: true)
        seenPass()
        publish(now: Date())
        if topologyChanged { notifyAggregateConsumers() }
        rescheduleTimer()
    }

    /// Agent switch off while tasks stay on: clear every agent identity,
    /// agent/plain-command completion, and agent notification, leaving
    /// task state untouched.
    private func clearAgentCategory() {
        AgentUsageCenter.shared.setEnabled(false)
        for monitor in monitors.values {
            monitor.resetAgentCategory()
        }
        AgentAttentionNotificationRouter.removeAll(category: .agent)
        publish(now: Date())
    }

    /// Task switch off while agents stay on: the mirror image.
    private func clearTaskCategory() {
        for monitor in monitors.values {
            monitor.resetTaskTracker()
        }
        AgentAttentionNotificationRouter.removeAll(category: .task)
        publish(now: Date())
    }

    /// Applies the project-detail toggle immediately. Re-enabling consumes
    /// missing, dirty, or expired answers on the next live transport without
    /// waiting for a new agent identity edge.
    func setProjectProbesEnabled(_ enabled: Bool) {
        guard started, wasEnabled else { return }
        guard enabled else {
            projectProbeEpoch &+= 1
            projectProbesRerunPending.removeAll()
            repositoryState.invalidateAll()
            var changed = false
            for monitor in monitors.values {
                changed = hideRepositoryFacts(from: monitor) || changed
            }
            if changed { publish(now: Date()) }
            return
        }
        guard foregroundActive, !Ghostty.isAppBackgrounded else { return }
        refreshRelevantRepositoryFacts(now: Date())
    }

    func topologyDidChange() {
        guard started else { return }
        guard wasEnabled, foregroundActive,
              AgentAttentionSettings.anyDetectionEnabled else {
            publishPresentationRollups(now: Date())
            return
        }
        let topologyChanged = reconcile(scheduleInitialScans: true)
        seenPass()
        publish(now: Date())
        // Removing a whole tab/window drops its monitors before `publish`, so
        // no surviving presentation row necessarily changes. Still refresh
        // consumers whose census is derived from the live tab registry.
        if topologyChanged { notifyAggregateConsumers() }
        rescheduleTimer()
        // Panes appearing or closing changes which hosts hold live agents,
        // even when no display state moved in the publish above.
        AgentUsageCenter.shared.presenceMayHaveChanged()
    }

    func visibilityDidChange() {
        guard started, wasEnabled else { return }
        refreshVisibleRepositoryFacts(now: Date())
        seenPass()
        publish(now: Date())
    }

    private func applicationDidEnterBackground() {
        foregroundActive = false
        schedulerTask?.cancel()
        schedulerTask = nil
        scheduledWakeDeadline = nil
        setCoreEventsEnabled(false)
    }

    private func applicationDidBecomeActive() {
        foregroundActive = true
        guard AgentAttentionSettings.anyDetectionEnabled else {
            // Topology/model writes are intentionally skipped in the
            // background. Catch OSC-only rollups up on foregrounding even
            // when there is no detector engine to do the normal publish.
            publishPresentationRollups(now: Date())
            return
        }
        wasEnabled = true
        setCoreEventsEnabled(true)
        burstScansRemaining = Tuning.initialBurstScans
        let topologyChanged = reconcile(scheduleInitialScans: false)
        let now = Date()
        for paneUUID in monitors.keys {
            scanDeadlines.schedule(paneUUID, at: now)
        }
        refreshRelevantRepositoryFacts(now: now)
        seenPass()
        publish(now: now)
        if topologyChanged { notifyAggregateConsumers() }
        rescheduleTimer()
    }

    private func setCoreEventsEnabled(_ enabled: Bool) {
        guard coreEventsEnabled != enabled else { return }
        coreEventsEnabled = enabled
        Ghostty.App.shared?.setSurfaceContentEventsEnabled(enabled)
    }

    // MARK: - Event wakes

    /// Exact per-surface edge from Ghostty. The core coalesces bursts before
    /// crossing the C callback; this queue coalesces again until the pane's
    /// next permitted scan.
    func noteContentChanged(terminal: Ghostty.TerminalView) {
        guard canScheduleWork else { return }
        guard let monitor = monitors[terminal.uuid] else {
            topologyDidChange()
            return
        }
        releaseRawMultiplexerIfDetached(terminal)
        // A rebuild is not over while its bytes are still arriving: on a
        // slow link a fixed window could close mid-replay and rebaseline
        // against a half-drawn frame. The suppressor caps the extension.
        monitor.refreshRebuild()
        monitor.noteActivity()
        scheduleScan(monitor, reasonDelay: Tuning.contentQuiescence)
    }

    /// The shell reported a new working directory (OSC 7). Free evidence: it
    /// is pushed to us whether or not an agent is running, so it is recorded
    /// ungated. Only the out-of-band probes are gated on an identified agent.
    /// (id=agent-project)
    func notePwdChanged(terminal: Ghostty.TerminalView) {
        guard canScheduleWork, let monitor = monitors[terminal.uuid] else { return }
        guard resolveReportedProject(for: monitor) else { return }
        applyCachedRepoFacts(to: monitor)
        publish(now: Date())
        // The agent moved to a directory we may know nothing about, so its
        // repository facts need resolving. Unprobed paths only — an already
        // answered one costs nothing here.
        if monitor.agent != nil { requestRepositoryFacts(for: monitor) }
    }

    /// Whether this pane's directory has an answered repository lookup.
    /// (id=agent-project)
    private func hasRepoFacts(for monitor: AgentPaneMonitor) -> Bool {
        guard let project = monitor.project, let hostKey = project.hostKey else { return false }
        return repositoryState.hasFacts(
            for: ProbedPath(hostKey: hostKey, path: project.path)
        )
    }

    private func needsRepositoryRefresh(
        for monitor: AgentPaneMonitor,
        now: Date = Date()
    ) -> Bool {
        guard let project = monitor.project, let hostKey = project.hostKey else { return true }
        return repositoryState.needsRefresh(
            ProbedPath(hostKey: hostKey, path: project.path),
            now: now
        )
    }

    private func isProjectRelevant(_ monitor: AgentPaneMonitor) -> Bool {
        monitor.agent != nil || monitor.doneUnseen || monitor.failedUnseen
    }

    /// Marks a pane's repository stale while preserving its last confirmed
    /// value on screen. Every cached subdirectory of the same worktree is
    /// invalidated together; linked worktrees keep independent roots.
    @discardableResult
    private func invalidateRepositoryFacts(
        for monitor: AgentPaneMonitor
    ) -> Set<ProbedPath> {
        guard let project = monitor.project, let hostKey = project.hostKey else { return [] }
        let affected = repositoryState.invalidateRepository(
            containing: ProbedPath(hostKey: hostKey, path: project.path)
        )
        if projectProbesInFlight.contains(hostKey) {
            projectProbesRerunPending.insert(hostKey)
        }
        return affected
    }

    /// Applies an already-known repository answer to a pane, so a second agent
    /// in a directory some other pane probed gets its branch immediately and
    /// without a command. Returns true when the pane's project changed.
    @discardableResult
    private func applyCachedRepoFacts(to monitor: AgentPaneMonitor) -> Bool {
        guard AgentAttentionSettings.projectProbesEnabled else {
            return hideRepositoryFacts(from: monitor)
        }
        guard let project = monitor.project, let hostKey = project.hostKey else {
            return false
        }
        guard let repo = repositoryState.facts(
            for: ProbedPath(hostKey: hostKey, path: project.path)
        ) else {
            return false
        }

        let label = AgentProjectPath.label(forPath: project.path, repoRoot: repo.root) ?? project.label
        return monitor.noteProject(
            AgentProjectIdentity(
                hostKey: hostKey,
                path: project.path,
                repositoryRoot: repo.root,
                label: label,
                branch: repo.branch,
                source: project.source
            ),
            authoritative: true
        )
    }

    /// Removes command-derived repository presentation while retaining free
    /// directory evidence. Answers keyed by a directory that will itself be
    /// hidden are discarded because no pane key remains to invalidate them.
    @discardableResult
    private func hideRepositoryFacts(from monitor: AgentPaneMonitor) -> Bool {
        guard let project = monitor.project else { return false }
        guard project.source == .osc7 || project.source == .herdr else {
            // A tmux/direct probe supplied the directory itself, so it is
            // command-derived too. Drop it, then recover any free OSC 7 value
            // that may have arrived while the stronger answer was installed.
            if let hostKey = project.hostKey {
                repositoryState.discard(
                    ProbedPath(hostKey: hostKey, path: project.path)
                )
            }
            monitor.clearProject()
            _ = resolveReportedProject(for: monitor)
            return true
        }
        let directoryLabel = AgentProjectPath.label(forPath: project.path) ?? project.label
        return monitor.noteProject(
            AgentProjectIdentity(
                hostKey: project.hostKey,
                path: project.path,
                label: directoryLabel,
                branch: nil,
                source: project.source
            ),
            authoritative: true
        )
    }

    /// Visibility and foreground changes are free scheduling edges. They may
    /// revalidate an already-stale project, but never create a periodic Git
    /// timer of their own.
    private func refreshVisibleRepositoryFacts(now: Date) {
        refreshRepositoryFacts(now: now) { [self] monitor in
            isSelectedTabPane(monitor)
        }
    }

    private func refreshRelevantRepositoryFacts(now: Date) {
        refreshRepositoryFacts(now: now) { _ in true }
    }

    private func refreshRepositoryFacts(
        now: Date,
        where extraPredicate: (AgentPaneMonitor) -> Bool
    ) {
        var requestedHosts: Set<String> = []
        var changed = false
        for monitor in monitors.values {
            guard isProjectRelevant(monitor), extraPredicate(monitor) else { continue }
            guard let hostKey = monitor.project?.hostKey else {
                // Project-less SSH panes need token-based discovery; tmux
                // panes need their gateway path query. Neither can enter the
                // repository-only host loop below.
                requestProjectIfNeeded(for: monitor, now: now)
                continue
            }
            let needsRefresh = needsRepositoryRefresh(for: monitor, now: now)
            if !needsRefresh {
                // Re-enabling lookup can restore a still-fresh private cache
                // without paying for another command.
                changed = applyCachedRepoFacts(to: monitor) || changed
                continue
            }
            guard !requestedHosts.contains(hostKey) else { continue }
            // A disconnected/unsupported pane must not consume this host's
            // chance; a later monitor may own a usable live transport.
            if requestRepositoryFacts(for: monitor, now: now) {
                requestedHosts.insert(hostKey)
            }
        }
        if changed { publish(now: now) }
    }

    /// Records the pane's own reported directory as its project.
    ///
    /// Provenance holds by construction: OSC 7 is emitted by whichever shell
    /// owns the tty, so a remote pane's value came from the remote host. This
    /// never substitutes a device-local path for a remote pane.
    @discardableResult
    private func resolveReportedProject(for monitor: AgentPaneMonitor) -> Bool {
        guard let terminal = monitor.terminal else { return false }
        if let binding = terminal.herdrPaneBinding {
            // The surface has a .local() configuration even over SSH. Read
            // both the host and the current pane directory from its gateway;
            // replayed OSC 7 may describe an older shell directory instead
            // of the foreground agent, and must not overwrite this identity.
            guard let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
                  let gateway = controller.gateway,
                  let path = controller.paneInfos[binding.paneId]?.projectPath,
                  let label = AgentProjectPath.label(forPath: path) else { return false }
            return monitor.noteProject(
                AgentProjectIdentity(
                    hostKey: Self.hostKey(for: gateway),
                    path: path,
                    label: label,
                    branch: nil,
                    source: .herdr
                )
            )
        }
        // `sessionProvidedPwd` is the background-safe cache of the same value,
        // so a directory reported while backgrounded is not lost.
        let reported = terminal.pwd ?? terminal.sessionProvidedPwd
        guard let path = reported.map(AgentProjectPath.normalize), !path.isEmpty else { return false }
        guard let label = AgentProjectPath.label(forPath: path) else { return false }

        return monitor.noteProject(
            AgentProjectIdentity(
                hostKey: Self.hostKey(for: terminal),
                path: path,
                label: label,
                branch: nil,
                source: .osc7
            )
        )
    }

    /// Entry point for command-based project resolution, called when a pane's
    /// agent is first identified.
    ///
    /// Free evidence (OSC 7) is recorded elsewhere and ungated; this is the
    /// gated half. A pane that already has a directory from a source at least
    /// as trusted needs nothing. (id=agent-project)
    /// A newly adopted agent may have been launched somewhere else entirely
    /// (exit, `cd`, relaunch), so its pane's cached directory and repository
    /// answer are both stale. Identity adoption is the one moment we know a
    /// fresh process started, and holding the old value across it showed the
    /// previous project indefinitely. Deliberately NOT done on `clearAgent`,
    /// so a finished agent's card keeps showing what it worked on.
    /// (id=agent-project)
    private func resetProjectForNewAgent(_ monitor: AgentPaneMonitor) {
        // Clear the PANE's directory so it is re-resolved, but leave the
        // repository cache alone. The cache is keyed by (host, path) and
        // describes a DIRECTORY, not an agent -- a new agent in the same
        // directory does not change its git state, and only a finished command
        // (`git checkout`) invalidates that.
        //
        // Invalidating here destroyed the cached branch on every
        // re-identification and forced a fresh probe. With a tmux gateway
        // attached its panes kept repopulating the cache, which masked the
        // bug entirely; a lone local shell just lost its branch.
        monitor.clearProject()
        monitor.lastProjectRequestAt = nil
        // Re-resolve immediately from the directory the shell already reported.
        // Without this the request that follows adoption always runs with no
        // project, so it has no path to ask about and achieves nothing.
        resolveReportedProject(for: monitor)
        applyCachedRepoFacts(to: monitor)
    }

    private func requestProjectIfNeeded(for monitor: AgentPaneMonitor, now: Date = Date()) {
        guard AgentAttentionSettings.projectProbesEnabled else { return }
        // Retry floor. The identification edge happens once, but the reasons a
        // request fails at that moment (gateway mid-attach, link still coming
        // up) resolve themselves, so a single early failure must not be
        // permanent. Scans re-enter here while a pane still has no project.
        if let last = monitor.lastProjectRequestAt,
           now.timeIntervalSince(last) < Tuning.projectRetryInterval {
            return
        }
        // Stamped only when something is actually dispatched. Stamping on entry
        // burned the retry budget on requests that had nothing to ask -- the
        // one right after adoption always does, since the project has just been
        // cleared -- which then blocked the scan that would have asked.
        var dispatched = false
        defer { if dispatched { monitor.lastProjectRequestAt = now } }

        // A tmux pane's directory comes from the gateway; nothing else can
        // answer for it, since the pane has no session of its own.
        if monitor.terminal?.tmuxPaneBinding != nil {
            if monitor.project.map({ $0.source < .tmux }) ?? true {
                requestTmuxProjectPaths(for: monitor)
                dispatched = true
            }
        }
        // Repository facts need a command wherever the directory came from:
        // the repositories are on the far end, so there is nothing local to
        // read. (id=agent-project)
        if requestRepositoryFacts(for: monitor) {
            dispatched = true
        }
    }

    /// Resolves repository root, branch, and `$HOME` for the directories of
    /// every agent pane sharing this pane's host, in ONE exec channel.
    ///
    /// Batching is the point: N agents on a host cost one probe, not N. The
    /// host is keyed by connection identity, so two panes on the same box
    /// coalesce even when they are different tabs.
    /// Returns true when a probe was actually started, so the caller can decide
    /// whether its retry budget was really spent.
    @discardableResult
    private func requestRepositoryFacts(
        for monitor: AgentPaneMonitor,
        now: Date = Date()
    ) -> Bool {
        guard AgentAttentionSettings.projectProbesEnabled else { return false }
        guard let owner = sessionOwner(for: monitor) else { return false }
        let hostKey = Self.hostKey(for: owner)
        // Capability is a property of the live session, so it is checked here
        // rather than remembered. A transport that cannot carry a probe costs
        // nothing, and one that is merely not connected yet is retried.
        guard ProjectProbeRunner.canProbe(owner) else { return false }
        if let health = projectHostProbeHealth[hostKey],
           !health.canStart(now: now) {
            return false
        }

        let sessionID = projectProbeSessionID(for: owner)
        projectGitUnavailableUntil = projectGitUnavailableUntil.filter {
            $0.value > now
        }
        let hostLacksGit = projectGitUnavailableUntil[sessionID] != nil

        guard projectProbesInFlight.insert(hostKey).inserted else {
            // A probe for this host is mid-flight and its path list is already
            // fixed. Remember that more work arrived so the completion runs
            // another pass, otherwise a path discovered after the snapshot
            // would never get repository facts at all.
            projectProbesRerunPending.insert(hostKey)
            // NOT dispatched. Treating a deferral as work done re-armed this
            // pane's retry floor every time it collided with another pane's
            // probe, and the queued rerun cannot help a pane that has no
            // directory yet -- the rerun batches only panes that already
            // contribute a path. So a pane needing DISCOVERY starved behind a
            // busy host: floored for 8s, colliding again, floored again. That
            // is the cold-start case where one recovering session resolved and
            // the other sat blank until something else drove a probe.
            return false
        }

        // Determine whether any relevant path is missing, dirty, or expired.
        // Once one is due, include every relevant path on the host in the same
        // command. A few extra local git reads are cheaper than opening another
        // exec channel a moment later, and every entry receives one coherent
        // validation timestamp.
        var relevantPaths: [String] = []
        var hasPathNeedingRefresh = false
        if !hostLacksGit {
            for candidate in monitors.values {
                guard let project = candidate.project,
                      project.hostKey == hostKey
                else { continue }
                guard isProjectRelevant(candidate) || candidate === monitor else { continue }
                if !relevantPaths.contains(project.path) {
                    relevantPaths.append(project.path)
                }
                let key = ProbedPath(hostKey: hostKey, path: project.path)
                if repositoryState.needsRefresh(key, now: now) {
                    hasPathNeedingRefresh = true
                }
            }
        }
        let paths = hasPathNeedingRefresh ? relevantPaths : []

        // A pane that owns its own SSH connection and still has no directory
        // can have one discovered from its token. Control-mode panes already
        // get their directories from the server; a process-tree search can
        // find the gateway's shell rather than the pane's foreground process.
        let paneToken: String? = {
            guard monitor.project == nil,
                  monitor.terminal?.tmuxPaneBinding == nil,
                  monitor.terminal?.herdrPaneBinding == nil else { return nil }
            // REMOTE panes only. The lookup identifies a pane by its position
            // in the ssh process tree; run locally it walks the helper's own
            // ancestors and returns some unrelated process's directory, which
            // is then discarded — burning a probe round each time while OSC 7,
            // the actual local answer, arrives independently.
            guard owner.connectionConfig.underlyingSSHConfig != nil else { return nil }
            return monitor.terminal?.uuid.uuidString
        }()

        guard !paths.isEmpty || paneToken != nil else {
            projectProbesInFlight.remove(hostKey)
            // Nothing was asked, so the retry budget must NOT be spent -- the
            // next scan has to be free to try again once a project resolves.
            return false
        }

        // Dirty hints (notably OSC 133, which carries no command text) are
        // noisy. First answers bypass this floor; revalidations do not.
        let hasUncachedPath = paths.contains {
            !repositoryState.hasFacts(for: ProbedPath(hostKey: hostKey, path: $0))
        }
        if !hasUncachedPath, paneToken == nil,
           projectHostProbeHealth[hostKey]?.isBelowRefreshFloor(
               now: now,
               floor: Tuning.projectEarlyRefreshFloor
           ) == true {
            projectProbesInFlight.remove(hostKey)
            return false
        }

        let dispatchedGenerations = Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let key = ProbedPath(hostKey: hostKey, path: path)
                return (path, repositoryState.generation(for: key))
            }
        )
        let dispatchedEpoch = projectProbeEpoch
        var health = projectHostProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordStarted(now: now)
        projectHostProbeHealth[hostKey] = health

        Task { @MainActor [weak self] in
            var probed: ProjectProbeResult?
            do {
                probed = try await ProjectProbeRunner.probe(
                    paths: paths, paneToken: paneToken, on: owner)
            } catch {
                if self?.projectProbeEpoch == dispatchedEpoch {
                    self?.recordProjectProbeFailure(hostKey: hostKey, now: Date())
                }
                Self.logger.error(
                    """
                    repo probe failed paths=\(paths.count, privacy: .public) \
                    token=\(paneToken != nil, privacy: .public): \
                    \(error.localizedDescription)
                    """)
            }

            // Clear the in-flight marker BEFORE applying: discovering a pane's
            // directory can require a follow-up probe for its repository facts,
            // and that call would otherwise be rejected as already in flight
            // and the branch would never arrive.
            self?.projectProbesInFlight.remove(hostKey)
            var rerun = self?.projectProbesRerunPending.remove(hostKey) != nil

            defer {
                // Paths that appeared, or were invalidated, while this probe
                // ran may still need work. Continue only for a pane that still
                // has a live card consumer; an irrelevant dirty entry can wait
                // for the next agent. Project-less targets re-enter full
                // discovery so SSH tokens and tmux paths are not skipped.
                // (id=agent-project)
                if rerun, let self {
                    let target = self.monitors.values.first {
                        guard self.isProjectRelevant($0),
                              self.projectHostKey(for: $0) == hostKey
                        else { return false }
                        return $0.project == nil
                            || self.needsRepositoryRefresh(for: $0)
                    }
                    if let target {
                        if target.project == nil {
                            self.requestProjectIfNeeded(for: target)
                        } else {
                            self.requestRepositoryFacts(for: target)
                        }
                    }
                }
            }
            guard let result = probed else { return }
            guard self?.projectProbeEpoch == dispatchedEpoch,
                  AgentAttentionSettings.projectProbesEnabled
            else { return }
            // A transport can succeed with a truncated/noisy response. Every
            // requested path emits a line even outside a repository, so a
            // missing line is a transient failure rather than a negative
            // answer; back it off just like a thrown command instead of
            // retrying on every active-agent scan.
            let hasIncompleteAnswer = AgentRepositoryProbeAnswer.isIncomplete(
                result,
                requestedPaths: paths,
                requestedWorkingDirectory: paneToken != nil
            )
            if hasIncompleteAnswer {
                self?.recordProjectProbeFailure(hostKey: hostKey, now: Date())
            } else {
                self?.recordProjectProbeSuccess(hostKey: hostKey)
            }
            // Facts FIRST: the directory step checks whether facts are already
            // known, and running it before this response was cached made it see
            // none and launch a second, redundant probe every time.
            let rejected = self?.applyRepositoryFacts(
                result,
                hostKey: hostKey,
                sessionID: sessionID,
                requested: paths,
                dispatchedGenerations: dispatchedGenerations,
                now: Date()
            ) ?? false
            rerun = rerun || rejected
            self?.applyProbedWorkingDirectory(result, hostKey: hostKey, paneUUID: monitor.paneUUID)
        }
        return true
    }

    private func projectHostKey(for monitor: AgentPaneMonitor) -> String? {
        if let hostKey = monitor.project?.hostKey { return hostKey }
        return sessionOwner(for: monitor).map { Self.hostKey(for: $0) }
    }

    private func projectProbeSessionID(
        for owner: Ghostty.TerminalView
    ) -> ObjectIdentifier {
        if let session = owner.session {
            return ObjectIdentifier(session)
        }
        return ObjectIdentifier(owner)
    }

    private func recordProjectProbeFailure(hostKey: String, now: Date) {
        var health = projectHostProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordFailure(
            now: now,
            baseDelay: Tuning.projectRetryInterval,
            maximumDelay: Tuning.projectFailureBackoffLimit
        )
        projectHostProbeHealth[hostKey] = health
    }

    private func recordProjectProbeSuccess(hostKey: String) {
        var health = projectHostProbeHealth[hostKey] ?? AgentRepositoryHostProbeHealth()
        health.recordSuccess()
        projectHostProbeHealth[hostKey] = health
    }

    /// Adopts a directory the probe discovered for a specific pane, then
    /// resolves its repository facts. This is the only directory source for a
    /// plain SSH pane whose remote shell reports none.
    private func applyProbedWorkingDirectory(
        _ result: ProjectProbeResult,
        hostKey: String,
        paneUUID: UUID
    ) {
        guard let monitor = monitors[paneUUID] else { return }

        // Adopt the discovered directory only if nothing beat us to it — the
        // probe takes a few hundred ms, in which OSC 7 or a tmux reply may
        // already have answered.
        var changed = false
        if monitor.project == nil,
           let raw = result.paneWorkingDirectory,
           case let path = AgentProjectPath.normalize(raw),
           let label = AgentProjectPath.label(forPath: path) {
            changed = monitor.noteProject(
                AgentProjectIdentity(
                    hostKey: hostKey,
                    path: path,
                    label: label,
                    branch: nil,
                    source: .probe
                )
            )
        }
        let repositoryNeedsRefresh = needsRepositoryRefresh(for: monitor)
        if !repositoryNeedsRefresh {
            changed = applyCachedRepoFacts(to: monitor) || changed
        }
        if changed { publish(now: Date()) }

        // Then ALWAYS make sure repository facts follow, whoever set the
        // directory. Bailing out when another source won the race left that
        // pane with a project and no branch, and the floor stamped by this very
        // probe stranded it -- which is why, of two sessions recovering at
        // once, one resolved and the other never did. (id=agent-project)
        guard monitor.agent != nil, repositoryNeedsRefresh else { return }
        // A probe just completed for this pane, so the floor has served its
        // purpose; clearing it lets the follow-up run now rather than in 8s.
        monitor.lastProjectRequestAt = nil
        requestRepositoryFacts(for: monitor)
    }

    private func applyRepositoryFacts(
        _ result: ProjectProbeResult,
        hostKey: String,
        sessionID: ObjectIdentifier,
        requested: [String],
        dispatchedGenerations: [String: UInt64],
        now: Date
    ) -> Bool {
        // Mark every requested path answered, including ones with no repo, so
        // a plain directory is asked about once and never again.
        // Cache ONLY paths the host actually answered for. A requested path
        // missing from the response means the probe could not speak to it at
        // all -- the git block is skipped wholesale when `command -v git`
        // fails -- which is NOT the same as "not a repository". Treating the
        // two alike overwrote a good cached answer with an empty one, applied
        // that authoritatively so it cleared the branch, and then never
        // re-probed because the path counted as answered. That is the
        // "worked once, then stopped" failure.
        if result.gitUnavailable {
            projectGitUnavailableUntil[sessionID] = now.addingTimeInterval(Tuning.projectNoGitTTL)
        }

        var acceptedPaths: Set<String> = []
        var rejectedSupersededAnswer = false
        for path in requested {
            let key = ProbedPath(hostKey: hostKey, path: path)
            // A path missing from the response is left uncached, so the next
            // probe retries it.
            guard let repo = result.repos[path] else { continue }
            guard let dispatchedGeneration = dispatchedGenerations[path],
                  repositoryState.accept(
                    repo,
                    for: key,
                    dispatchedGeneration: dispatchedGeneration,
                    now: now
                  )
            else {
                rejectedSupersededAnswer = true
                continue
            }
            acceptedPaths.insert(path)
        }
        if let home = result.home, !home.isEmpty {
            remoteHomes[hostKey] = home
        }

        // Apply to every path the host ANSWERED for, including a genuine "not
        // a repository" (which must be able to clear a stale root or branch).
        // Paths it did not answer for are left alone: see the caching note
        // above -- an unanswered path is not a negative result.
        var changed = false
        for monitor in monitors.values {
            guard let project = monitor.project,
                  project.hostKey == hostKey,
                  acceptedPaths.contains(project.path)
            else { continue }
            changed = applyCachedRepoFacts(to: monitor) || changed
        }
        if changed { publish(now: Date()) }
        return rejectedSupersededAnswer
    }

    /// The pane holding the connection this pane's directories live behind: a
    /// tmux -CC or herdr pane rides its gateway's session.
    private func sessionOwner(for monitor: AgentPaneMonitor) -> Ghostty.TerminalView? {
        guard let terminal = monitor.terminal else { return nil }
        if let herdr = terminal.herdrPaneBinding {
            // A herdr pane's surface is local; its host is the gateway's.
            return HerdrController.controller(forGateway: herdr.gatewayUUID)?.gateway
        }
        guard let binding = terminal.tmuxPaneBinding else { return terminal }
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for candidate in tab.splitTree.terminalLeaves
                where candidate.uuid == binding.parentUUID {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Asks a tmux gateway for its panes' directories, on behalf of a pane
    /// whose agent has just been identified.
    ///
    /// Commands are gated on an identified agent BY DESIGN: the project
    /// only ever renders on an agent card, so probing a pane with no agent
    /// runs a command whose result can never be shown. One query answers for
    /// every pane on the gateway, so the first identified agent there resolves
    /// its siblings for free. (id=agent-project)
    private func requestTmuxProjectPaths(for monitor: AgentPaneMonitor) {
        guard AgentAttentionSettings.projectProbesEnabled else { return }
        guard let terminal = monitor.terminal,
              let binding = terminal.tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              // `parentSurface` is a raw pointer whose address can be reused
              // after the gateway is freed, so confirm identity before use.
              // (id=tmux-stale-parent-surface)
              controller.ownerTerminalUUIDForNotifications == binding.parentUUID
        else { return }

        let gateway = binding.parentUUID
        guard tmuxProjectQueriesInFlight.insert(gateway).inserted else { return }

        Task { @MainActor [weak self] in
            defer { self?.tmuxProjectQueriesInFlight.remove(gateway) }
            do {
                let paths = try await controller.paneWorkingDirectories()
                self?.applyTmuxProjectPaths(paths, gateway: gateway)
            } catch {
                Self.logger.error("tmux pane paths failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fans one gateway's reply out to every monitor bound to it.
    private func applyTmuxProjectPaths(_ paths: [Int: String], gateway: UUID) {
        var changed = false
        var touched: [AgentPaneMonitor] = []

        for monitor in monitors.values {
            guard let binding = monitor.terminal?.tmuxPaneBinding,
                  binding.parentUUID == gateway,
                  let raw = paths[binding.paneId]
            else { continue }

            let path = AgentProjectPath.normalize(raw)
            guard let label = AgentProjectPath.label(forPath: path) else { continue }
            changed = monitor.noteProject(
                AgentProjectIdentity(
                    // The HOST is the gateway's, not the pane's: a -CC pane
                    // has no session of its own, so asking the pane for a host
                    // key yields nil and nothing would ever match it again.
                    hostKey: sessionOwner(for: monitor).map(Self.hostKey(for:)),
                    path: path,
                    label: label,
                    branch: nil,
                    source: .tmux
                )
            ) || changed
            // A directory some other pane already resolved needs no command:
            // apply the cached answer straight away.
            changed = applyCachedRepoFacts(to: monitor) || changed
            touched.append(monitor)
        }
        if changed { publish(now: Date()) }

        // Only now do these panes have directories to ask about, so this is
        // the earliest point a branch lookup can be made. Requesting it at
        // identification (as an ordinary pane does) would have found nothing.
        for monitor in touched where monitor.agent != nil {
            requestRepositoryFacts(for: monitor)
        }
    }

    /// herdr reported a pane's directory (snapshot or `pane_updated`).
    /// The directory is free server metadata; Git facts use the gateway's
    /// connection and the same repository cache as ordinary panes.
    func applyHerdrProjectPath(terminal: Ghostty.TerminalView, path raw: String) {
        guard let monitor = monitors[terminal.uuid] else {
            pendingHerdrProjectPaths[terminal.uuid] = raw
            return
        }
        let path = AgentProjectPath.normalize(raw)
        guard path.hasPrefix("/"),
              let owner = sessionOwner(for: monitor),
              let label = AgentProjectPath.label(forPath: path) else { return }
        var changed = monitor.noteProject(
            AgentProjectIdentity(
                hostKey: Self.hostKey(for: owner),
                path: path,
                label: label,
                branch: nil,
                source: .herdr
            )
        )
        changed = applyCachedRepoFacts(to: monitor) || changed
        if changed { publish(now: Date()) }
        if monitor.agent != nil {
            _ = requestRepositoryFacts(for: monitor)
        }
    }

    /// `user@host:port` for a remote pane, nil for a local one. Scopes cache
    /// entries so identically-named repositories on different machines stay
    /// distinct.
    static func hostKey(for terminal: Ghostty.TerminalView) -> String {
        guard let ssh = terminal.connectionConfig.underlyingSSHConfig else {
            // This machine is a host too. Returning nil here made every
            // local pane fail the probe's guard, so a local tmux gateway got
            // its project name from tmux and could never resolve a branch.
            return localHostKey
        }
        return "\(ssh.username)@\(ssh.host):\(ssh.port)"
    }

    /// Cache scope for panes whose commands run on this device.
    static let localHostKey = "local"

    /// Ends a raw-multiplexer binding once the multiplexer gives the screen
    /// back, so the pane returns to ordinary per-pane semantics.
    ///
    /// tmux and zellij take the alternate screen when they start and hold it
    /// for the whole attach — switching windows inside them never gives it
    /// back. So a primary-screen frame, once ownership has been observed, is
    /// the detach/exit signal. This mirrors `altOwnedSinceIdentity`, which
    /// treats a primary frame as revoking a TUI agent's presence grant.
    /// (id=agent-attention-raw-mux)
    private func releaseRawMultiplexerIfDetached(_ terminal: Ghostty.TerminalView) {
        guard terminal.rawMultiplexer != nil, let surface = terminal.surface else { return }

        // Non-blocking read: never worth parking the main thread for. On
        // contention, enqueue a scan so the detach check retries even if
        // this was the final frame and no further content events arrive
        // (the scheduled scan re-runs the check with its own sample).
        var altActive = false
        guard ghostty_surface_try_is_alternate_active(surface, &altActive) else {
            scanDeadlines.schedule(
                terminal.uuid,
                at: Date().addingTimeInterval(Tuning.overflowDelay)
            )
            rescheduleTimer()
            return
        }

        updateRawMultiplexerDetach(terminal, altActive: altActive)
    }

    /// The detach state transition itself, fed by whichever caller already
    /// holds a fresh alt-screen sample (content event or scheduled scan).
    private func updateRawMultiplexerDetach(_ terminal: Ghostty.TerminalView, altActive: Bool) {
        guard var binding = terminal.rawMultiplexer else { return }

        if altActive {
            guard !binding.hasOwnedAltScreen else { return }
            binding.hasOwnedAltScreen = true
            terminal.rawMultiplexer = binding
            return
        }

        guard binding.hasOwnedAltScreen else { return }
        terminal.rawMultiplexer = nil
        topologyDidChange()
    }

    /// Geometry changes repaint a pane but are not task activity.
    func noteGeometryChanged(terminal: Ghostty.TerminalView) {
        guard canScheduleWork, let monitor = monitors[terminal.uuid] else { return }
        monitor.noteGridResize()
        scheduleScan(monitor, reasonDelay: Tuning.resizeSettleDelay)
    }

    func noteProgressChanged(terminal: Ghostty.TerminalView) {
        let now = Date()
        let phase: OSCProgressActivity.Phase?
        switch terminal.progressReport?.state {
        case .set, .indeterminate:
            phase = .working
        case .pause:
            phase = .paused
        case .error:
            phase = .failed
        case .remove, nil:
            phase = nil
        }

        let change = terminal.presentation.applyOSCProgress(
            phase: phase,
            progress: terminal.progressReport?.progress,
            now: now,
            nextSequence: nextSeq
        )

        // Existing OSC-region detector rules still get their normal screen
        // scan when that machinery is enabled. Sidebar activity itself is
        // independent and does not require monitors or content events.
        if canScheduleWork, let monitor = monitors[terminal.uuid] {
            scheduleScan(monitor, reasonDelay: Tuning.contentQuiescence)
        }

        if change == .semantic {
            publish(now: now)
        }
    }

    /// herdr's own agent status for a control-mode pane. Goes through the
    /// pane monitor like a screen classification would, so badges, rows,
    /// rollups, and notifications all follow herdr. A report that lands
    /// before the monitor exists is held for `reconcile`.
    func applyHerdrStatus(
        terminal: Ghostty.TerminalView,
        status: String,
        agentID: String?,
        displayName: String?,
        title: String?
    ) {
        let report = PendingHerdrReport(
            status: AgentAttentionStatus(rawValue: status) ?? .unknown,
            agentID: agentID,
            displayName: displayName
        )
        guard let monitor = monitors[terminal.uuid] else {
            pendingHerdrReports[terminal.uuid] = report
            return
        }
        applyHerdrReport(report, to: monitor)
    }

    private func applyHerdrReport(_ report: PendingHerdrReport, to monitor: AgentPaneMonitor) {
        let now = Date()
        let changed = monitor.applyExternalReport(
            status: report.status,
            agentID: report.agentID,
            displayName: report.displayName,
            now: now,
            seq: nextSeq
        )
        // A status event is also a chance to refresh Git metadata, including
        // for panes never visited/rendered and after an early probe failure.
        let projectChanged = refreshProject(for: monitor, now: now)
        if changed || projectChanged {
            publish(now: now)
        }
    }

    /// Applies reports and directories that arrived before a monitor did.
    private func drainPendingHerdrState(for monitor: AgentPaneMonitor) {
        if let path = pendingHerdrProjectPaths.removeValue(forKey: monitor.paneUUID),
           let terminal = monitor.terminal {
            applyHerdrProjectPath(terminal: terminal, path: path)
        }
        if let report = pendingHerdrReports.removeValue(forKey: monitor.paneUUID) {
            applyHerdrReport(report, to: monitor)
        }
    }

    /// Title change from the terminal (already coalesced at 75ms).
    /// Runs identity + title-only rules with zero screen reads.
    func noteTitleChanged(terminal: Ghostty.TerminalView, title: String) {
        guard canScheduleWork else { return }
        guard let monitor = monitors[terminal.uuid] else { return }
        guard title != monitor.lastSeenTitle else { return }
        monitor.lastSeenTitle = title

        // Title identity and title-only rules are agent machinery; task
        // detection is driven purely by content-change scans.
        guard AgentAttentionSettings.detectionEnabled else { return }
        // herdr names the agent and its state for this pane.
        guard !monitor.externalAuthority else { return }

        let manifest = AgentDetectionManifest.bundled
        let now = Date()
        if monitor.agent == nil {
            if let found = manifest.identifyAgent(fromTitle: title) {
                monitor.adoptAgent(found, source: .title, now: now)
                resetProjectForNewAgent(monitor)
                requestProjectIfNeeded(for: monitor)
                scheduleScan(monitor, reasonDelay: Tuning.contentQuiescence)
                publish(now: now)
            }
            return
        }
        guard !monitor.inStartupGrace, let agent = monitor.agent else { return }
        // A visible blocker owns the state: titles keep animating through
        // approval waits and must not flap blocked away. The scheduled
        // screen scan decides.
        guard monitor.stableState != .blocked else { return }
        let progress = Self.progressString(terminal)
        if let classification = manifest.classifyTitleOnly(agent: agent, title: title, progress: progress) {
            let changed = monitor.applyClassification(classification, now: now, seq: nextSeq)
            scheduleFollowups(for: monitor, now: now)
            if changed {
                publish(now: now)
            }
        }
        scheduleScan(monitor, reasonDelay: Tuning.contentQuiescence)
    }

    /// OSC 133 command finished for a pane (exit code + duration).
    func commandFinished(paneUUID: UUID, exitCode: Int?, duration: TimeInterval) {
        guard wasEnabled else { return }
        guard let monitor = monitors[paneUUID] else { return }
        // Tasks-only mode: the shell's exit code still finalizes a held
        // task, but the plain-command inbox (agentless done/failed rows)
        // stays owned by the agent switch.
        if !AgentAttentionSettings.detectionEnabled {
            guard monitor.isTaskActive else { return }
            let now = Date()
            _ = monitor.commandFinished(
                exitCode: exitCode,
                duration: duration,
                viewedNow: monitor.isViewedNow(),
                now: now
            )
            publish(now: now)
            return
        }
        // Capture BEFORE: `commandFinished` clears an active agent, and an
        // ordinary shell command has none, so testing afterwards was almost
        // always false and the branch refresh below never ran.
        let hadAgent = monitor.agent != nil
        let now = Date()
        let accepted = monitor.commandFinished(
            exitCode: exitCode,
            duration: duration,
            viewedNow: monitor.isViewedNow(),
            now: now
        )
        publish(now: now)
        guard accepted else { return }

        // OSC 133 does not include the command text, so every completion is
        // only a branch-change HINT. Mark the worktree dirty without blanking
        // it, then probe only when an agent card in that worktree is relevant.
        // A plain shell can therefore run commands all day at zero project
        // probe cost; launching an agent later consumes the dirty answer.
        let affected = invalidateRepositoryFacts(for: monitor)
        guard !affected.isEmpty else { return }
        let related = monitors.values.first { candidate in
            guard isProjectRelevant(candidate),
                  let project = candidate.project,
                  let hostKey = project.hostKey
            else { return false }
            return affected.contains(
                ProbedPath(hostKey: hostKey, path: project.path)
            )
        }
        if let target = related ?? (hadAgent ? monitor : nil) {
            requestRepositoryFacts(for: target, now: now)
        }
    }

    // MARK: - Census (rollup chip, agents panel)

    /// Counts of detected agents by display status, across all windows.
    /// Unseen completions of exited agents still count (inbox entries).
    func globalAgentCounts(now: Date = Date()) -> [AgentAttentionStatus: Int] {
        var counts: [AgentAttentionStatus: Int] = [:]
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for pane in tab.splitTree {
                    guard let row = pane.presentation.agentRow else { continue }
                    counts[row.status, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Strict coding-agent census for the Live Activity. Unlike
    /// `globalAgentCounts`, which rolls up every attention card, this counts
    /// only panes whose detector identified an agent (`detectedAgentRow`,
    /// category `.agent`): task rows and OSC-only Activity rows are skipped.
    /// The bucket comes from the composed `agentRow` status so an OSC
    /// progress overlay counts the way the sidebar shows it. One entry per
    /// pane; Claude fleet sub-agents ride along with their session.
    func codingAgentCounts() -> CodingAgentCounts {
        var counts = CodingAgentCounts()
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for pane in tab.splitTree {
                    guard let detected = pane.presentation.detectedAgentRow,
                          detected.category == .agent,
                          let row = pane.presentation.agentRow
                    else { continue }
                    counts.add(row.status)
                }
            }
        }
        return counts
    }

    /// Live agent providers and the terminal that OWNS each one's connection
    /// (a tmux -CC pane resolves to its gateway). Feeds the usage tracker;
    /// providers without usage support simply do not map.
    func usagePresence() -> [(provider: AgentUsageProvider, owner: Ghostty.TerminalView)] {
        var presence: [(AgentUsageProvider, Ghostty.TerminalView)] = []
        for monitor in monitors.values {
            guard let agentID = monitor.agent?.id,
                  let provider = AgentUsageProvider(rawValue: agentID),
                  let owner = sessionOwner(for: monitor)
            else { continue }
            presence.append((provider, owner))
        }
        return presence
    }

    // MARK: - Deadline scheduler

    private var canScheduleWork: Bool {
        started && wasEnabled && foregroundActive
            && !Ghostty.isAppBackgrounded
            && AgentAttentionSettings.anyDetectionEnabled
    }

    private func scheduleScan(_ monitor: AgentPaneMonitor, reasonDelay: TimeInterval) {
        let now = Date()
        let minimumInterval: TimeInterval
        if monitor.agent == nil, !monitor.isTaskActive {
            minimumInterval = Tuning.identityInterval
        } else if isSelectedTabPane(monitor) {
            minimumInterval = Tuning.selectedInterval
        } else if monitor.stableState == .working || monitor.stableState == .blocked
                    || monitor.stableState == .unknown || monitor.isPendingDone
                    || monitor.hasNoSignalStreak || monitor.isFleetWorking(now: now)
                    || monitor.isTaskActive {
            minimumInterval = Tuning.activeBackgroundInterval
        } else {
            minimumInterval = Tuning.idleInterval
        }
        let deadline = max(
            now.addingTimeInterval(reasonDelay),
            monitor.lastScanAt.addingTimeInterval(minimumInterval * powerScale())
        )
        if scanDeadlines.schedule(monitor.paneUUID, at: deadline) {
            rescheduleTimer()
        }
    }

    private func scheduleFollowups(for monitor: AgentPaneMonitor, now: Date) {
        if monitor.wantsStateConfirmationScan {
            scanDeadlines.schedule(
                monitor.paneUUID,
                at: now.addingTimeInterval(Tuning.stateConfirmationInterval * powerScale())
            )
        } else if monitor.hasNoSignalStreak || monitor.taskTracker.hasNoMatchStreak {
            scanDeadlines.schedule(
                monitor.paneUUID,
                at: now.addingTimeInterval(Tuning.noSignalInterval * powerScale())
            )
        } else if let grace = monitor.startupGraceUntil, grace > now {
            scanDeadlines.schedule(monitor.paneUUID, at: grace)
        }

        // A running fleet is its own clock: nothing else guarantees the
        // re-read that sees the next tick (the main agent may be sitting
        // idle at its prompt, and a tmux -CC pane has no change signal at
        // all). Stops as soon as the ticks do.
        if monitor.isFleetWorking(now: now) {
            scanDeadlines.schedule(
                monitor.paneUUID,
                at: now.addingTimeInterval(Tuning.fleetPollInterval * powerScale())
            )
        }

        // Task work sits out settle windows entirely, so a scan consumed
        // inside one did no task work — and a pane that goes quiet in the
        // window (a command finishing during a resize repaint; its OSC 133
        // is also rejected while settling) emits nothing afterwards to
        // schedule the catch-up. Re-park the scan just past the window;
        // the queue only moves deadlines earlier, so an earlier in-window
        // scan wins this round and re-parks on its own followup pass.
        if TaskDetectionSettings.enabled, monitor.isSettling {
            scanDeadlines.schedule(
                monitor.paneUUID,
                at: monitor.settleUntil.addingTimeInterval(0.1)
            )
        }

        // A rebuild publishes nothing while it runs, so the pane needs one
        // wake AFTER the window closes to run the rebaseline comparison.
        // Nothing else guarantees it: an agent sitting blocked emits no
        // output, so no content event will ever schedule that scan and a
        // state that really changed during the outage would go unreported.
        // The queue only ever moves a deadline earlier, so an already
        // pending scan wins this round and re-parks the wake on its own
        // followup pass.
        if let deadline = monitor.rebuildDeadline {
            scanDeadlines.schedule(
                monitor.paneUUID,
                at: deadline.addingTimeInterval(Tuning.rebuildRebaselineDelay)
            )
        }

        // Falling edge of a fleet needs a wake of its own: with no
        // completion armed yet there is no other deadline to carry it.
        // `fleetWorkingUntil` is not cleared when it lapses, so it only
        // counts while it is still in the future — a stale one would be
        // requeued forever at zero delay.
        let fleetWake = monitor.isFleetWorking(now: now) ? monitor.fleetWorkingUntil : nil
        if let deadline = monitor.completionDeadline ?? fleetWake {
            // A held candidate cannot promote until the rebuild closes,
            // and its own deadline may already be in the past. Parking it
            // there would have `takeDue` return the pane, change nothing,
            // requeue the same expired date, and wake again at zero delay
            // for the whole window.
            //
            // Park it on the SAME deadline as the rebaseline scan, not on
            // the rebuild's own. `runDueWork` drains scans before liveness
            // and publishes once at the end, so sharing the deadline makes
            // the settled classification the one reconciliation sees.
            // Waking earlier would reconcile off the last, possibly
            // half-drawn, frame and could publish a false Done.
            let parked = monitor.rebuildDeadline.map {
                max(deadline, $0.addingTimeInterval(Tuning.rebuildRebaselineDelay))
            } ?? deadline
            livenessDeadlines.schedule(monitor.paneUUID, at: parked)
        } else {
            livenessDeadlines.cancel(monitor.paneUUID)
        }
    }

    private func rescheduleTimer() {
        guard canScheduleWork else { return }
        let next = [scanDeadlines.nextDeadline, livenessDeadlines.nextDeadline]
            .compactMap { $0 }
            .min()
        guard let next else {
            schedulerTask?.cancel()
            schedulerTask = nil
            scheduledWakeDeadline = nil
            return
        }
        if schedulerTask != nil, scheduledWakeDeadline == next {
            return
        }
        schedulerTask?.cancel()
        schedulerTask = nil
        scheduledWakeDeadline = next

        let delay = max(0, next.timeIntervalSinceNow)
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.schedulerTask = nil
            self.scheduledWakeDeadline = nil
            self.runDueWork()
        }
    }

    private func runDueWork() {
        guard canScheduleWork else { return }
        let now = Date()

        var dueScans = scanDeadlines.takeDue(at: now)
        dueScans.sort { lhs, rhs in
            guard let left = monitors[lhs], let right = monitors[rhs] else {
                return monitors[lhs] != nil
            }
            if left.wantsStateConfirmationScan != right.wantsStateConfirmationScan {
                return left.wantsStateConfirmationScan
            }
            let leftSelected = isSelectedTabPane(left)
            if leftSelected != isSelectedTabPane(right) { return leftSelected }
            return left.lastScanAt < right.lastScanAt
        }

        let budget = burstScansRemaining > 0
            ? Tuning.burstScansPerWake
            : Tuning.maxScansPerWake
        let selected = dueScans.prefix(budget)
        if burstScansRemaining > 0 {
            burstScansRemaining = max(0, burstScansRemaining - selected.count)
        }
        for paneUUID in selected {
            guard let monitor = monitors[paneUUID] else { continue }
            guard scan(monitor, now: now) else {
                // Terminal mutex contended (a heavy parse in flight): no
                // state moved, so retry after the overflow delay instead of
                // treating the pane as scanned.
                scanDeadlines.schedule(
                    paneUUID,
                    at: now.addingTimeInterval(Tuning.overflowDelay)
                )
                continue
            }
            monitor.updateLivenessEdges(now: now)
            scheduleFollowups(for: monitor, now: now)
        }
        for paneUUID in dueScans.dropFirst(budget) {
            scanDeadlines.schedule(
                paneUUID,
                at: now.addingTimeInterval(Tuning.overflowDelay)
            )
        }

        for paneUUID in livenessDeadlines.takeDue(at: now) {
            guard let monitor = monitors[paneUUID] else { continue }
            monitor.updateLivenessEdges(now: now)
            scheduleFollowups(for: monitor, now: now)
        }

        seenPass()
        publish(now: now)
        rescheduleTimer()
    }

    // MARK: - Reconcile

    /// Monitor lifetime is a pure function of the live tab tree.
    /// Returns true when panes entered or left the monitored topology. That
    /// structural change can alter aggregate censuses even if no surviving
    /// pane's presentation state changes during the following publish pass.
    private func reconcile(scheduleInitialScans: Bool) -> Bool {
        var live: Set<UUID> = []
        let now = Date()
        var topologyChanged = false
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                // tmux -CC gateway tabs render control-mode chrome,
                // never an agent; scanning them is pure waste. A herdr
                // gateway is the user's shell, but its agents live in the
                // projected panes herdr reports on.
                if tab.isTmuxGateway || tab.isHerdrGateway { continue }
                for terminal in tab.splitTree.terminalLeaves {
                    live.insert(terminal.uuid)
                    if let monitor = monitors[terminal.uuid] {
                        monitor.updateOwners(tab: tab, tabsModel: model)
                    } else {
                        topologyChanged = true
                        let monitor = AgentPaneMonitor(
                            paneUUID: terminal.uuid,
                            terminal: terminal,
                            tab: tab,
                            tabsModel: model
                        )
                        monitors[terminal.uuid] = monitor
                        drainPendingHerdrState(for: monitor)
                        if scheduleInitialScans {
                            scanDeadlines.schedule(terminal.uuid, at: now)
                        }
                    }
                }
            }
        }
        pendingHerdrReports = pendingHerdrReports.filter { live.contains($0.key) || monitors[$0.key] == nil }
        pendingHerdrProjectPaths = pendingHerdrProjectPaths.filter { live.contains($0.key) || monitors[$0.key] == nil }
        for uuid in monitors.keys where !live.contains(uuid) {
            topologyChanged = true
            monitors.removeValue(forKey: uuid)
            scanDeadlines.cancel(uuid)
            livenessDeadlines.cancel(uuid)
            AgentAttentionNotificationRouter.paneRemoved(uuid)
        }
        return topologyChanged
    }

    /// Repository enrichment also runs for server-reported agents with no
    /// readable surface (unvisited panes, replay, or a busy terminal parser).
    @discardableResult
    private func refreshProject(for monitor: AgentPaneMonitor, now: Date) -> Bool {
        // Catch a directory reported before this monitor existed (restore,
        // reattach, or detection enabled mid-session): `notePwdChanged` only
        // fires on the edge, and that edge may already have passed.
        var changed = resolveReportedProject(for: monitor)
        if changed {
            // Another pane on this host may already have resolved this very
            // directory. Applying the cached answer here is not just an
            // optimisation: a cached path is EXCLUDED from the next probe's
            // path list, so without this the pane would be skipped as
            // "already answered" and never receive the branch at all.
            changed = applyCachedRepoFacts(to: monitor) || changed
        }

        // Self-heal: an identified agent with no project yet re-requests one,
        // rate-limited. This is the path that recovers a pane whose gateway
        // was not ready to answer at identification. (id=agent-project)
        // Self-heal covers BOTH gaps: no project yet, and a project whose
        // repository facts were never asked for. The second case is the local
        // shell: the probe fires at identification, OSC 7 resolves the
        // directory a moment later, and nothing re-requested the branch — so
        // the card sat on a project with no branch forever.
        if monitor.agent != nil,
           monitor.project == nil || needsRepositoryRefresh(for: monitor, now: now) {
            requestProjectIfNeeded(for: monitor, now: now)
        } else if monitor.agent != nil, monitor.project?.branch == nil {
            // Facts are cached but this pane has not taken them yet.
            changed = applyCachedRepoFacts(to: monitor) || changed
        }
        return changed
    }

    // MARK: - Heavy scan (terminal mutex, budgeted)

    /// Returns false only when the terminal mutex was contended and nothing
    /// was read; the caller reschedules the pane and no monitor state moves.
    /// Blocking here is not an option: a sustained output flood can hold the
    /// mutex for long stretches, and a parked main thread is what turned
    /// into the 0x8BADF00D watchdog kills on build 131.
    private func scan(_ monitor: AgentPaneMonitor, now: Date) -> Bool {
        if monitor.externalAuthority {
            monitor.lastScanAt = now
            refreshProject(for: monitor, now: now)
            return true
        }
        guard let terminal = monitor.terminal, let surface = terminal.surface,
              let size = terminal.surfaceSize
        else { return true }
        let gridRows = Int(size.rows)
        let cols = Int(size.columns)
        guard gridRows > 1, cols > 1 else { return true }

        let manifest = AgentDetectionManifest.bundled
        var readBusy = false
        let text = Ghostty.Surface.tryReadBottomRows(
            min(manifest.snapshotRows, gridRows),
            gridRows: gridRows,
            cols: cols,
            surface: surface,
            busy: &readBusy
        )
        if readBusy { return false }

        // Fresh alt-screen state at read time; weak-signature presence
        // hinges on it.
        var altActive = false
        guard ghostty_surface_try_is_alternate_active(surface, &altActive) else {
            return false
        }

        monitor.lastScanAt = now

        // Retry any raw-multiplexer detach that a contended content-event
        // check deferred to us, using the sample this scan already took.
        updateRawMultiplexerDetach(terminal, altActive: altActive)

        var lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }

        monitor.noteAltScreen(altActive)
        monitor.lastSeenTitle = terminal.sessionProvidedTitle ?? ""

        refreshProject(for: monitor, now: now)

        let input = AgentDetectionInput(
            lines: lines,
            oscTitle: terminal.sessionProvidedTitle ?? "",
            oscProgress: Self.progressString(terminal),
            altScreenActive: altActive
        )
        // Peeled chrome declares a multiplexer nothing configured.
        monitor.noteMultiplexerChrome(input.hadMultiplexerChrome)

        if monitor.agent == nil {
            if AgentAttentionSettings.detectionEnabled,
               let found = manifest.identifyAgent(from: input) {
                monitor.adoptAgent(found, source: .screen, now: now)
                resetProjectForNewAgent(monitor)
                requestProjectIfNeeded(for: monitor)
                // Fall through: identity came from this very snapshot, so
                // classify it in the same pass (no first-pass grace).
            } else {
                // No agent on screen: the task pass rides the same
                // snapshot and cache-friendly input, at zero extra reads.
                if TaskDetectionSettings.enabled {
                    scanTask(monitor, input: input, manifest: manifest, now: now)
                }
                // The frames we most need when authoring: something is on
                // screen and no agent matched it. Task state rides along.
                AgentDetectionCapture.shared.record(
                    paneUUID: monitor.paneUUID,
                    lines: lines,
                    cols: cols,
                    gridRows: gridRows,
                    altScreenActive: altActive,
                    oscTitle: input.oscTitle,
                    oscProgress: input.oscProgress,
                    agentID: monitor.taskTracker.taskID,
                    state: monitor.taskTracker.taskID == nil
                        ? nil : monitor.taskTracker.stableState.rawValue,
                    matchedRuleID: nil
                )
                return true
            }
        } else if let held = monitor.agent,
                  let taking = manifest.supersedingAgent(held, in: input) {
            // Another agent is plainly on screen and this one is not. Hand
            // the pane over now rather than waiting out a no-signal streak
            // the held agent's own rules keep resetting.
            monitor.adoptAgent(taking, source: .screen, now: now)
            resetProjectForNewAgent(monitor)
            requestProjectIfNeeded(for: monitor)
        }
        guard let agent = monitor.agent, !monitor.inStartupGrace else { return true }

        // A blocker in a LIVE region outranks any OSC title. Claude keeps
        // its braille title spinning while it waits for approval, and
        // osc_title_working (1100) sits above every screen blocker — so a
        // pane could never ENTER blocked from a title-animating agent, only
        // stay there. Screen-only first; the title decides whenever the
        // screen shows no live blocker.
        //
        // The live-region test is load-bearing: 20 of the manifest's 23
        // whole_recent blocked rules carry visibleBlocker, and those match
        // an answered prompt anywhere in the 40-row snapshot. Letting one
        // of those beat a working title would turn stale transcript text
        // into "Needs input". transcript_viewer (1000, skipStateUpdate)
        // also still outranks the blockers inside this pass.
        let screenOnly = manifest.classify(agent: agent, input: input, excludingOSCRegions: true)
        let liveBlocker = screenOnly.visibleBlocker
            && AgentDetectionRegions.isLiveAnchored(screenOnly.matchedRuleRegion)
        let classification = liveBlocker || monitor.stableState == .blocked
            ? screenOnly
            : manifest.classify(agent: agent, input: input)

        // Which rule claims this screen, on rule-id change only. This is
        // the single most informative line when a pane reads the wrong
        // state, so it rides along with snapshot recording. The rows the
        // rule matched on are not repeated here: the recorder writes the
        // same frame verbatim, so terminal text never reaches the log.
        if AgentDetectionCapture.isEnabled,
           classification.matchedRuleID != monitor.lastMatchedRuleID {
            monitor.lastMatchedRuleID = classification.matchedRuleID
            let pane = String(monitor.paneUUID.uuidString.prefix(8))
            let rule = classification.matchedRuleID ?? "fallback-idle"
            let state = classification.state.rawValue
            Self.logger.debug(
                """
                pane \(pane, privacy: .public) \
                rule \(rule, privacy: .public) -> \(state, privacy: .public)
                """)
        }

        // Identity liveness. Only a SCREEN-region rule carrying a
        // visible*/skip flag proves the agent's chrome is actually on
        // screen. OSC-region matches never count: titles outlive
        // processes (codex's osc_title_idle matches ANY nonempty title,
        // flag or not — an exited codex must not stay pinned by the
        // shell's title). Everything else defers to the strict presence
        // check (title patterns, strong chrome, weak chrome only with
        // the alt screen).
        let matchedOSCRegion = classification.matchedRuleRegion == "osc_title"
            || classification.matchedRuleRegion == "osc_progress"
        let definitivePresence = classification.matchedRuleID != nil
            && !matchedOSCRegion
            && (classification.visibleIdle || classification.visibleBlocker
                || classification.visibleWorking || classification.skipStateUpdate)
        // A full-screen agent that still owns the alt screen it took at
        // identification is still running, whatever its banner text has
        // scrolled to. This is the whole liveness signal for TUI agents
        // whose only signature is their product name.
        // Inside a multiplexer the app does not drive, the MULTIPLEXER owns
        // the alternate screen for the whole attach, not the agent — so this
        // grant would never lapse and the pane would keep an exited agent's
        // card forever. There, presence must come from screen evidence, which
        // is exactly what lets a card follow the visible window.
        let altHeld = monitor.altOwnedSinceIdentity && monitor.lastAltActive
            && !monitor.isInsideRawMultiplexer
        if definitivePresence || altHeld || manifest.agentStillPresent(agent, in: input) {
            monitor.resetNoSignalStreak()
        } else if monitor.isSettling || monitor.isRebuilding {
            // Repaint in flight (initialization, resize, or a recapture
            // we ordered): chrome that is momentarily absent is not
            // evidence the agent exited. Hold the streak rather than
            // advancing OR resetting it.
        } else if monitor.noteNoSignalScan() {
            return true
        }

        // Signature-authoring capture (opt-in). Records the verbatim rows
        // the rules just ran against, so signatures come from real frames
        // instead of a copy-paste that lost the row boundaries.
        AgentDetectionCapture.shared.record(
            paneUUID: monitor.paneUUID,
            lines: lines,
            cols: cols,
            gridRows: gridRows,
            altScreenActive: altActive,
            oscTitle: input.oscTitle,
            oscProgress: input.oscProgress,
            agentID: agent.id,
            state: classification.state.rawValue,
            matchedRuleID: classification.matchedRuleID
        )

        _ = monitor.applyClassification(classification, now: now, seq: nextSeq)

        // What the pane is asking, for the notification body. Read from the
        // frame that classified it so the question and the state can never
        // come from different screens. The stabilizer may still be holding,
        // which is exactly why this keys on the classification rather than
        // on the committed state: the answer is ready when the commit lands.
        if classification.state == .blocked {
            // Turning the setting off has to drop what is already stored,
            // not just stop adding to it.
            monitor.notePromptSummary(
                AgentAttentionSettings.notificationPromptEnabled
                    ? AgentPromptSummary.summarize(lines: input.lines, cols: cols)
                    : nil)
        } else if monitor.stableState != .blocked {
            monitor.notePromptSummary(nil)
        }

        // Background agents: claude keeps its idle-looking input box on
        // screen while its fleet runs, so the only live evidence is the
        // fleet rows' own timers advancing between scans.
        let fleetRows = AgentFleetRows.rows(in: lines)
        let waitingCount = AgentFleetRows.waitingCount(in: lines)
        monitor.noteFleet(rows: fleetRows, waitingCount: waitingCount, now: now)

        // Agents print their own task timer ("(2m 49s · …") — sync our
        // elapsed clock to it so the card matches the TUI.
        if classification.state != .blocked,
           let screenElapsed = Self.screenElapsed(in: lines) ?? fleetElapsed(monitor) {
            monitor.syncWorkingClock(screenElapsed: screenElapsed, now: now)
        }
        return true
    }

    /// Task-detection pass for an agentless pane, riding the same
    /// snapshot the agent pass just built. Ordering: the prompt overlay
    /// first (a blocked prompt outranks, and a sudo prompt under a held
    /// build must still block the pane), then the held task's own rules
    /// (no match feeds decay), then adoption from the enabled families.
    private func scanTask(
        _ monitor: AgentPaneMonitor,
        input: AgentDetectionInput,
        manifest: AgentDetectionManifest,
        now: Date
    ) {
        // A rebuild/restore replay walks the pane through historical
        // frames: a long-answered prompt or an old summary line is on
        // screen again for a moment, and observing it would mint a fresh
        // task event (the router's first-event blocked exception would
        // then notify about a stale prompt). Agent rebaselining doesn't
        // cover agentless panes, so the task pass sits the whole window
        // out — holding, not advancing, any decay streak — and resumes
        // against the settled screen. Same hold for settle windows
        // (fresh-pane banner spew, resize repaints).
        guard !monitor.isRebuilding, !monitor.isSettling else { return }

        // A full-screen TUI owns this pane (vim, less, htop); its text is
        // not command output. Inside a raw multiplexer the alt screen
        // belongs to the multiplexer, and panes stay eligible.
        guard !input.altScreenIsAgentOwned else {
            if monitor.isTaskActive { _ = monitor.noteTaskNoMatch() }
            return
        }

        var cache = AgentDetectionManifest.RegionCache(input: input)
        let families = TaskDetectionSettings.enabledFamilies

        let entry: AgentDetectionManifest.Agent
        let classification: AgentClassification
        if families.contains(.prompts),
           let overlay = manifest.promptOverlay(input: input, cache: &cache) {
            if !monitor.isTaskActive {
                monitor.adoptTask(overlay.task, now: now)
            }
            // A held task keeps its identity through a prompt: "Cargo
            // needs input" names the build, not the prompt entry.
            guard let held = heldTaskEntry(monitor, manifest: manifest) else { return }
            entry = held
            classification = overlay.classification
        } else if let held = heldTaskEntry(monitor, manifest: manifest) {
            guard let c = manifest.classifyTask(held, input: input, cache: &cache) else {
                _ = monitor.noteTaskNoMatch()
                return
            }
            entry = held
            classification = c
        } else if monitor.isTaskActive {
            // Held entry vanished from the manifest (override reload edge).
            monitor.resetTaskTracker()
            return
        } else if let hit = manifest.identifyTask(from: input, families: families, cache: &cache) {
            monitor.adoptTask(hit.task, now: now)
            entry = hit.task
            classification = hit.classification
        } else {
            return
        }

        let promptLine = input.lines
            .last(where: { !$0.allSatisfy(\.isWhitespace) })?
            .trimmingCharacters(in: .whitespaces)
        let progress = classification.state == .working
            ? manifest.taskProgress(for: entry, input: input, cache: &cache)
            : nil
        _ = monitor.applyTaskObservation(
            classification,
            promptLine: promptLine,
            progress: progress,
            now: now,
            seq: nextSeq
        )

        // The matched prompt line IS the question for the prompts path —
        // AgentPromptSummary requires a "?" line and would miss
        // "password:". Same privacy gate as the agent side.
        if classification.state == .blocked || monitor.taskTracker.stableState == .blocked {
            monitor.notePromptSummary(
                AgentAttentionSettings.notificationPromptEnabled ? promptLine : nil)
        } else {
            monitor.notePromptSummary(nil)
        }
    }

    private func heldTaskEntry(
        _ monitor: AgentPaneMonitor,
        manifest: AgentDetectionManifest
    ) -> AgentDetectionManifest.Agent? {
        guard let id = monitor.taskTracker.taskID else { return nil }
        return manifest.tasks.first(where: { $0.id == id })
    }

    /// Parse the agent's on-screen elapsed time from status lines like
    /// "✻ Waddling… (2m 49s · ↓ 5.1k tokens)" or "• Working (1m 3s · esc
    /// to interrupt)". Bottom-up: the live status line sits lowest.
    // Separator varies by agent: claude "(2m 49s · …", codex "(6s • …".
    // A closing paren counts too: claude drops the token counter while a
    // plan's todo checklist is attached and prints a bare "(9m 3s)".
    private static let screenElapsedRegex = #/\((?:(\d+)h )?(?:(\d+)m )?(\d+)s(?: [·•]|\))/#
    private static func screenElapsed(in lines: [String]) -> TimeInterval? {
        for line in lines.reversed() {
            guard let match = line.firstMatch(of: screenElapsedRegex) else { continue }
            let hours = match.output.1.flatMap { Double($0) } ?? 0
            let minutes = match.output.2.flatMap { Double($0) } ?? 0
            let seconds = Double(match.output.3) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        }
        return nil
    }

    /// Fallback clock while only background agents are running: the main
    /// agent prints no timer of its own then. Only consulted when
    /// `screenElapsed` found nothing, so a sub-agent's timer can never
    /// override the session's own.
    private func fleetElapsed(_ monitor: AgentPaneMonitor) -> TimeInterval? {
        guard monitor.isFleetWorking() else { return nil }
        return monitor.fleetMaxElapsed
    }

    // MARK: - Seen + publish

    private func seenPass() {
        for monitor in monitors.values where monitor.isViewedNow() {
            // Looking at the pane answers the notification. Withdrawing it
            // here rather than on tap covers every way in (tab switch,
            // sidebar, keyboard) with the visibility rule the rest of the
            // feature already uses.
            AgentAttentionNotificationRouter.paneViewed(monitor.paneUUID)
            if monitor.doneUnseen || monitor.failedUnseen
                || monitor.taskTracker.hasUnseenCompletion {
                monitor.markSeen()
            }
        }
    }

    /// The single publish chokepoint: per-tab rollups compare-then-write
    /// onto TabModel, transitions feed the notification router, and one
    /// revision bump covers aggregate consumers.
    private func publish(now: Date) {
        var changed = false
        var reconciled = false

        for monitor in monitors.values {
            // A window that just closed: reconcile the state machine against
            // the settled screen BEFORE anything reads off it, since the
            // absorbed frames left deferred decisions behind.
            var rebaselining = false
            if !monitor.isRebuilding, monitor.consumeRebuildRebaseline() {
                rebaselining = true
                monitor.reconcileAfterRebuild(
                    previousStatus: monitor.lastPublishedEvent?.status, now: now)
                // Reconciliation can arm a completion, and a pane that
                // settled into idle emits nothing more, so this pass is the
                // only chance to park the wake that promotes it.
                scheduleFollowups(for: monitor, now: now)
                reconciled = true
            }

            if monitor.isRebuilding {
                // Arm reconciliation from the rebuild itself, not from a
                // changed event: the replay's side effects can cancel out
                // at the display level while the state machine underneath
                // has moved.
                monitor.noteRebuildObserved()
            }

            let event = monitor.displayEvent(now: now)
            guard event != monitor.lastPublishedEvent else { continue }

            // Display-level transitions are invisible in the 📋 line
            // (that one covers classification, not what the card
            // shows); this is what makes UI flapping diagnosable.
            if AgentDetectionCapture.isEnabled {
                let pane = String(monitor.paneUUID.uuidString.prefix(8))
                let old = monitor.lastPublishedEvent?.status.rawValue ?? "nil"
                let new = event?.status.rawValue ?? "nil"
                let phase = monitor.isRebuilding ? " (rebuilding)" : ""
                Self.logger.debug(
                    """
                    pane \(pane, privacy: .public) \
                    display \(old, privacy: .public) -> \(new, privacy: .public)\
                    \(phase, privacy: .public)
                    """)
            }

            // A repaint we ordered is rebuilding this pane's screen. It
            // passes through blank frames and replayed transcript before
            // landing back on the state it already had, and every hop mints
            // a fresh event id, so none of it reaches the router and the
            // baseline stays at what the user was last told.
            //
            // Notifications only. The badge and card below deliberately keep
            // tracking the live screen through a rebuild: holding those on a
            // snapshot let a stale one outlive a detection and hide it.
            if monitor.isRebuilding { continue }

            // First publish after a rebuild. Every hop minted a fresh
            // event id, so identity reads as a transition even for the
            // status the user was already notified about; compare by
            // status instead. Unchanged means pre-existing, which is
            // exactly what a fresh attach gets from the router's
            // discovery guard. A different status genuinely happened
            // during the outage and is still news.
            let samePreRebuildStatus = rebaselining
                && monitor.lastPublishedEvent?.status == event?.status
            if !samePreRebuildStatus {
                AgentAttentionNotificationRouter.paneTransitioned(
                    old: monitor.lastPublishedEvent,
                    new: event,
                    monitor: monitor
                )
            }
            monitor.lastPublishedEvent = event
            changed = true
        }

        // Deadlines armed above land after this publish pass, so the timer
        // has to be re-read for them.
        if reconciled { rescheduleTimer() }

        // Model writes follow the app-wide rule: no @Observable mutations
        // while backgrounded (watchdog). Transitions above still flow so
        // background notifications fire; the foreground catch-up pass
        // catches the models up.
        guard !Ghostty.isAppBackgroundedAtomic else { return }

        changed = updatePresentationRollups(now: now) || changed

        if changed {
            revision &+= 1
            // Agent identities may have appeared or moved hosts; the usage
            // center debounces, so this is a cheap no-op at steady state.
            AgentUsageCenter.shared.presenceMayHaveChanged()
            notifyAggregateConsumers()
        }
    }

    /// Recomputes pane-derived tab state without reconciling detectors. This
    /// keeps OSC progress attached to the correct tab when panes are inserted
    /// or moved while both screen-based detection systems are disabled.
    private func publishPresentationRollups(now: Date) {
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        guard updatePresentationRollups(now: now) else { return }
        revision &+= 1
        notifyAggregateConsumers()
    }

    /// Consumers that read the census instead of observing per-tab models.
    /// Runs on the main actor after the presentation rollups have settled and
    /// only reads them, so nothing here can re-enter the publish pass.
    private func notifyAggregateConsumers() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivityManager.shared.agentCountsMayHaveChanged()
        #endif
    }

    /// Compare-and-write pass shared by the full detector publisher and the
    /// lightweight OSC topology path.
    private func updatePresentationRollups(now: Date) -> Bool {
        var changed = false
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                var statuses: [AgentAttentionStatus] = []
                var bestRow: AgentRowState?
                var agentPaneIDs: [UUID] = []
                for terminal in tab.splitTree.terminalLeaves {
                    let monitor = monitors[terminal.uuid]
                    // The card and badge track the live screen, rebuild or
                    // not. Only NOTIFICATIONS are held back through a
                    // replay; holding the UI too meant a stale snapshot
                    // could outlive a detection and hide it.
                    let detectedStatus = monitor?.displayStatus(now: now)
                    if terminal.presentation.detectedAttentionStatus != detectedStatus {
                        terminal.presentation.detectedAttentionStatus = detectedStatus
                        changed = true
                    }

                    let row = monitor?.rowState(now: now)
                    let detectedRow = row?.agentID == nil ? nil : row
                    if terminal.presentation.detectedAgentRow != detectedRow {
                        terminal.presentation.detectedAgentRow = detectedRow
                        changed = true
                    }

                    let status = terminal.presentation.attentionStatus
                    if let status {
                        statuses.append(status)
                    }
                    let agentRow = terminal.presentation.agentRow
                    if let agentRow {
                        agentPaneIDs.append(terminal.uuid)
                        if bestRow == nil
                            || agentRow.status.attentionPriority > bestRow!.status.attentionPriority
                            || (agentRow.status.attentionPriority == bestRow!.status.attentionPriority
                                && agentRow.stateChangeSeq > bestRow!.stateChangeSeq) {
                            bestRow = agentRow
                        }
                    }
                }
                if tab.agentPaneIDs != agentPaneIDs {
                    tab.agentPaneIDs = agentPaneIDs
                    changed = true
                }
                let badge = statuses.isEmpty ? nil : AgentAttentionStatus.worst(of: statuses)
                if tab.attentionBadge != badge {
                    tab.attentionBadge = badge
                    changed = true
                }
                if tab.agentRow != bestRow {
                    tab.agentRow = bestRow
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - Teardown

    /// Master toggle off: stop the core signal at its source, cancel the
    /// only timer, drop monitors, and clear published state immediately.
    private func teardownAll() {
        // Master switch off means the usage tracker stops too: without this
        // its OAuth tokens stayed resident in memory, an in-flight fetch
        // could still be applied, and the sidebar footer kept drawing its
        // last rows (it re-renders on the usage center's revision, which
        // nothing here would have bumped).
        AgentUsageCenter.shared.setEnabled(false)
        setCoreEventsEnabled(false)
        schedulerTask?.cancel()
        schedulerTask = nil
        scheduledWakeDeadline = nil
        scanDeadlines.removeAll()
        livenessDeadlines.removeAll()
        wasEnabled = false
        burstScansRemaining = 0
        monitors.removeAll()
        AgentAttentionNotificationRouter.removeAll()
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for terminal in tab.splitTree.terminalLeaves {
                    terminal.presentation.detectedAttentionStatus = nil
                    terminal.presentation.detectedAgentRow = nil
                }
            }
        }
        // OSC activity is presentation state, not detector state. Recompute
        // rollups after clearing detection so live progress cards survive.
        publish(now: Date())
    }

    // MARK: - Helpers

    private func nextSeq() -> UInt64 {
        stateChangeSeq &+= 1
        return stateChangeSeq
    }

    private func isSelectedTabPane(_ monitor: AgentPaneMonitor) -> Bool {
        guard let tab = monitor.tab, let tabsModel = monitor.tabsModel else { return false }
        return tabsModel.selectedTabID == tab.id
    }

    private func powerScale() -> Double {
        switch PowerManager.shared.tier {
        case .full: return 1.0
        case .reduced: return 1.5
        case .saver: return 3.0
        }
    }

    /// Synthesize herdr's OSC 9;4 payload form ("4;<state>;<pct>") from
    /// the already-plumbed progress report.
    private static func progressString(_ terminal: Ghostty.TerminalView) -> String {
        guard let report = terminal.progressReport else { return "" }
        let state: Int
        switch report.state {
        case .remove: state = 0
        case .set: state = 1
        case .error: state = 2
        case .indeterminate: state = 3
        case .pause: state = 4
        }
        let pct = report.progress.map { String($0) } ?? "-1"
        return "4;\(state);\(pct)"
    }

}
