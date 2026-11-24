//
//  GitDiffStore.swift
//  rootshell
//
//  One window's git diff state. It follows the focused pane of the visible
//  tab and probes only while the panel is on, that pane is on screen and
//  the app is in the foreground, so background tabs cost nothing. A probe
//  runs when the pane's screen has changed (an agent working) and otherwise
//  falls back to a slow idle check.
//

import Foundation
import os

@MainActor
@Observable
final class GitDiffStore {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GitDiff")

    enum Phase: Equatable {
        case loading
        case ready
        case unavailable(GitDiffUnavailable)
        /// The focused pane is not a terminal, or its transport cannot run git.
        case unsupportedPane
        case disconnected
        /// A Mac local shell needs the helper to run git, and it is not running.
        case helperUnavailable
        /// Git ran on the host and could not read the repository.
        case gitFailed
        case failed
    }

    private(set) var snapshot: GitDiffSnapshot?
    private(set) var phase: Phase = .loading
    /// A load the person asked for, or the first one, is in flight.
    private(set) var isRefreshing = false
    private(set) var scope: GitDiffScope
    private(set) var ignoreWhitespace: Bool
    /// Fold choices by file identity; files without one use `defaultExpanded`.
    private(set) var foldOverrides: [String: Bool] = [:]

    @ObservationIgnored private weak var terminal: Ghostty.TerminalView?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var wantsPatch = false
    @ObservationIgnored private var lastProbe: ContinuousClock.Instant?
    @ObservationIgnored private var lastProbeDuration: Duration = .zero
    @ObservationIgnored private var lastSerial: UInt64 = 0
    @ObservationIgnored private var lastDirectory: String?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var skipsStampOnce = false
    /// Recent panes' diffs, so switching tabs shows the last one at once.
    @ObservationIgnored private var cache: [(id: UUID, snapshot: GitDiffSnapshot)] = []

    /// The floor between probes while the pane is producing output.
    private static let activeInterval: Duration = .milliseconds(2500)
    /// Counts alone are cheap to show, so the summary pill polls less often.
    private static let summaryInterval: Duration = .seconds(4)
    /// With a quiet pane, files can still change from elsewhere.
    private static let idleInterval: Duration = .seconds(15)
    /// With nothing to show (no repository, no git), output in the pane says
    /// little, so a probe waits this long unless the directory changes.
    private static let unavailableInterval: Duration = .seconds(10)
    private static let cacheLimit = 4

    init() {
        let store = SettingsStore.shared
        scope = store.value(Settings.GitDiff.scope)
        ignoreWhitespace = store.value(Settings.GitDiff.ignoreWhitespace)
    }

    // MARK: - Control

    /// Starts or stops following. `wantsPatch` is false while only the
    /// summary pill shows.
    func setActive(_ active: Bool, wantsPatch: Bool) {
        let needsPatchNow = active && wantsPatch && !(snapshot?.includesPatch ?? false)
        let changed = active != self.active
        self.active = active
        self.wantsPatch = wantsPatch
        if changed || needsPatchNow { restart() }
    }

    func setTarget(_ terminal: Ghostty.TerminalView?) {
        guard terminal !== self.terminal else { return }
        if let old = self.terminal, let snapshot { remember(snapshot, for: old.uuid) }
        self.terminal = terminal
        let cached = terminal.flatMap { target in cache.first { $0.id == target.uuid }?.snapshot }
        snapshot = cached
        setPhase(terminal == nil ? .unsupportedPane : (cached == nil ? .loading : .ready))
        foldOverrides = [:]
        resetProbeState()
        restart()
    }

    func refresh() {
        guard active else { return }
        isRefreshing = true
        // Asked for by hand: read everything again, whatever the stamp says.
        skipsStampOnce = true
        restart()
    }

    func setScope(_ scope: GitDiffScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        SettingsStore.shared.set(Settings.GitDiff.scope, scope)
        invalidate()
    }

    func setIgnoreWhitespace(_ ignore: Bool) {
        guard ignore != ignoreWhitespace else { return }
        ignoreWhitespace = ignore
        SettingsStore.shared.set(Settings.GitDiff.ignoreWhitespace, ignore)
        invalidate()
    }

    // MARK: - Folding

    func isExpanded(_ file: GitDiffFile) -> Bool {
        foldOverrides[file.id] ?? Self.defaultExpanded(file)
    }

    func setExpanded(_ expanded: Bool, for file: GitDiffFile) {
        foldOverrides[file.id] = expanded
    }

    func setAllExpanded(_ expanded: Bool) {
        guard let snapshot else { return }
        foldOverrides = Dictionary(snapshot.files.map { ($0.id, expanded) }, uniquingKeysWith: { first, _ in first })
    }

    var allCollapsed: Bool {
        guard let snapshot, !snapshot.files.isEmpty else { return false }
        return !snapshot.files.contains { isExpanded($0) }
    }

    /// Large, generated and deleted files start folded; their counts still show.
    static func defaultExpanded(_ file: GitDiffFile) -> Bool {
        if file.status == .deleted || file.isBinary || !file.hasPatch { return false }
        if file.lineCount > 400 { return false }
        return !isGenerated(file.path)
    }

    static func isGenerated(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map { $0.lowercased() } ?? path.lowercased()
        let names: Set<String> = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "podfile.lock", "gemfile.lock",
            "composer.lock", "poetry.lock", "uv.lock", "go.sum", "package.resolved", "bun.lock", "flake.lock",
            "project.pbxproj",
        ]
        if names.contains(name) { return true }
        return [".min.js", ".min.css", ".map", ".xcstrings", ".snap", ".lock"].contains { name.hasSuffix($0) }
    }

    // MARK: - Loop

    private func invalidate() {
        cache.removeAll()
        snapshot = nil
        foldOverrides = [:]
        setPhase(terminal == nil ? .unsupportedPane : .loading)
        resetProbeState()
        restart()
    }

    private func resetProbeState() {
        lastProbe = nil
        lastProbeDuration = .zero
        failures = 0
    }

    /// Supersedes any probe in flight and runs one now.
    private func restart() {
        loop?.cancel()
        loop = nil
        generation &+= 1
        guard active else {
            isRefreshing = false
            return
        }
        let generation = generation
        loop = Task { [weak self] in
            var force = true
            while !Task.isCancelled {
                guard let delay = await self?.tick(force: force, generation: generation) else { return }
                force = false
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Probes if one is due. Returns how long to wait before checking again.
    private func tick(force: Bool, generation: UInt64) async -> Duration {
        let poll: Duration = .milliseconds(500)
        guard let terminal else {
            setPhase(.unsupportedPane)
            isRefreshing = false
            return .seconds(2)
        }
        guard GitDiffSource.supports(terminal) else {
            if snapshot != nil { snapshot = nil }
            setPhase(.unsupportedPane)
            isRefreshing = false
            return .seconds(3)
        }
        guard terminal.isTabVisible, !Ghostty.isAppBackgroundedAtomic else { return poll }

        let serial = terminal.surfaceContentSerial
        let directory = terminal.pwd
        if !force, let lastProbe {
            let wait = interval(screenMoved: serial != lastSerial, directoryMoved: directory != lastDirectory)
            if lastProbe.duration(to: .now) < wait { return poll }
        }
        lastSerial = serial
        lastDirectory = directory

        var request = GitDiffProbeRequest(scope: scope, ignoreWhitespace: ignoreWhitespace, includePatch: wantsPatch)
        // A manual refresh stays owed until a probe has actually answered:
        // a busy transport or a failure must not let the next try send the
        // old stamp and take "unchanged" for an answer.
        if let snapshot, !skipsStampOnce, snapshot.includesPatch || !wantsPatch { request.knownStamp = snapshot.stamp }
        if snapshot == nil { isRefreshing = true }

        let started = ContinuousClock.now
        let result: Result<GitDiffProbeResponse, Error>
        do {
            result = .success(try await GitDiffSource.load(request, for: terminal))
        } catch {
            result = .failure(error)
        }
        // A newer request (target, scope, manual refresh) owns the state now.
        guard generation == self.generation, !Task.isCancelled else { return poll }
        // tssh carries one probe at a time and another feature has the slot.
        // Nothing ran, so the spinner and any owed refresh carry over.
        if case .failure(let error) = result, case RemoteExecProbe.ProbeError.busy = error {
            return .milliseconds(1500)
        }
        isRefreshing = false
        if case .success(let response) = result, response != .incomplete { skipsStampOnce = false }

        switch result {
        case .success(.snapshot(let fresh)):
            noteProbe(started: started, failed: false)
            if snapshot != fresh { snapshot = fresh }
            foldOverrides = foldOverrides.filter { entry in fresh.files.contains { $0.id == entry.key } }
            remember(fresh, for: terminal.uuid)
            setPhase(.ready)
        case .success(.unchanged):
            noteProbe(started: started, failed: false)
            if snapshot != nil { setPhase(.ready) }
        case .success(.unavailable(let reason)):
            noteProbe(started: started, failed: false)
            if snapshot != nil { snapshot = nil }
            setPhase(.unavailable(reason))
        case .success(.incomplete):
            noteProbe(started: started, failed: true)
            if snapshot == nil { setPhase(.failed) }
        case .success(.failed):
            // An old diff beside a repository git cannot read would mislead.
            noteProbe(started: started, failed: true)
            if snapshot != nil { snapshot = nil }
            setPhase(.gitFailed)
        case .failure(let error):
            noteProbe(started: started, failed: true)
            Self.logger.debug("Git diff probe failed: \(String(describing: error), privacy: .public)")
            switch error {
            case GitDiffSource.SourceError.unsupportedPane:
                if snapshot != nil { snapshot = nil }
                setPhase(.unsupportedPane)
            case GitDiffSource.SourceError.helperUnavailable:
                if snapshot != nil { snapshot = nil }
                setPhase(.helperUnavailable)
            case GitDiffSource.SourceError.notConnected, RemoteExecProbe.ProbeError.notConnected,
                 RemoteExecProbe.ProbeError.unsupportedSession:
                if snapshot == nil { setPhase(.disconnected) }
            default:
                if snapshot == nil { setPhase(.failed) }
            }
        }
        return poll
    }

    /// How long after the last probe the next one may run. Only a forced
    /// probe (a new target, a manual refresh, opening the panel) skips this.
    private func interval(screenMoved: Bool, directoryMoved: Bool) -> Duration {
        // A new directory can change every answer, the unavailable ones included.
        if directoryMoved { return activeFloor }
        // Not connected is decided locally, so asking again costs nothing.
        if phase == .disconnected { return .seconds(2) }
        guard let snapshot else { return max(Self.unavailableInterval, activeFloor) }
        let needsPatch = wantsPatch && !snapshot.includesPatch
        return screenMoved || needsPatch ? activeFloor : Self.idleInterval
    }

    /// Slower on a host where the probe itself is slow, after failures, and
    /// when the device is saving power.
    private var activeFloor: Duration {
        let base = wantsPatch ? Self.activeInterval : Self.summaryInterval
        let scale: Double = switch PowerManager.shared.tier {
        case .full: 1
        case .reduced: 1.5
        case .saver: 3
        }
        let backoff: Duration = .seconds(min(30, failures * 6))
        return max(base, lastProbeDuration * 4) * scale + backoff
    }

    private func noteProbe(started: ContinuousClock.Instant, failed: Bool) {
        let now = ContinuousClock.now
        lastProbe = now
        lastProbeDuration = started.duration(to: now)
        failures = failed ? failures + 1 : 0
    }

    private func setPhase(_ phase: Phase) {
        if self.phase != phase { self.phase = phase }
    }

    private func remember(_ snapshot: GitDiffSnapshot, for id: UUID) {
        cache.removeAll { $0.id == id }
        cache.append((id, snapshot))
        if cache.count > Self.cacheLimit { cache.removeFirst(cache.count - Self.cacheLimit) }
    }
}
