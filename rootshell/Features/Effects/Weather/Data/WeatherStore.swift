// WeatherStore.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import CoreLocation
import os

/// One fetch loop for every Live Weather surface (windows, sidebar, keyboard).
/// It runs only while a visible, foreground view holds it, so the app never
/// fetches in the background or while the effect is off.
@MainActor
@Observable
final class WeatherStore {
    static let shared = WeatherStore()

    enum Status: Equatable {
        case idle
        case fetching
        case updated
        case retrying(Date)
    }

    private(set) var snapshot: WeatherSnapshot?
    private(set) var status: Status = .idle
    private(set) var locationStatus: WeatherLocationStatus = .estimated
    private(set) var locality: String?
    private(set) var manualRefreshAt = Date.distantPast
    private(set) var deviceCoordinate: WeatherCoordinate?
    /// What a visible, live (not demo) Live Weather view is showing; nil when none is.
    private(set) var activeSelection: WeatherLocationSelection?
    /// The Show in Tab Sidebar setting, reported by the visible view.
    var showsInSidebar = true
    /// Why the chosen provider isn't supplying the weather, after the last fetch.
    private(set) var providerIssue: WeatherProviderIssue?

    @ObservationIgnored private var state: WeatherDiskState
    @ObservationIgnored private let resolver = WeatherLocationResolver()
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var selection = WeatherLocationSelection.device
    /// Nil until a view first holds the store.
    @ObservationIgnored private var choice: WeatherProviderChoice?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    private init() {
        state = WeatherDiskCache.load() ?? WeatherDiskState()
        snapshot = state.snapshot
        deviceCoordinate = state.deviceCoordinate
        manualRefreshAt = state.policy.manualAvailableAt(now: Date())
        providerIssue = state.sources.issue
    }

    /// Where to draw the sky for a selection, without waiting for a fetch.
    func coordinate(for selection: WeatherLocationSelection) -> WeatherCoordinate {
        switch selection {
        case .city(let city): return WeatherCoordinate(latitude: city.latitude, longitude: city.longitude)
        case .device: return deviceCoordinate ?? resolver.bestGuess
        }
    }

    /// The cached weather, if it describes this selection's location.
    func snapshot(for selection: WeatherLocationSelection) -> WeatherSnapshot? {
        guard let snapshot else { return nil }
        let wanted = coordinate(for: selection)
        return abs(snapshot.coordinate.latitude - wanted.latitude) < 0.25
            && abs(WeatherSkyGeometry.wrap180(snapshot.coordinate.longitude - wanted.longitude)) < 0.25 ? snapshot : nil
    }

    var activeSnapshot: WeatherSnapshot? { activeSelection.flatMap { snapshot(for: $0) } }
    var sidebarSnapshot: WeatherSnapshot? { showsInSidebar ? activeSnapshot : nil }

    var activePlaceName: String? {
        guard let activeSelection else { return nil }
        if case .city(let city) = activeSelection { return city.name }
        return activeSnapshot?.placeName ?? locality
    }

    /// Keeps the fetch loop alive until the calling task is cancelled.
    func hold(_ selection: WeatherLocationSelection, provider choice: WeatherProviderChoice) async {
        consumers += 1
        if activeSelection != selection { activeSelection = selection }
        let changed = choice != self.choice
        // The first hold after launch keeps the saved schedule; run() compares the provider itself.
        if changed, self.choice != nil { invalidateSchedule() }
        self.choice = choice
        if changed || selection != self.selection || loop == nil {
            self.selection = selection
            restart()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        consumers -= 1
        if consumers == 0 {
            activeSelection = nil
            loop?.cancel()
            loop = nil
            if status == .fetching { status = .idle }
        }
    }

    func requestLocationPermission() {
        guard resolver.authorizationStatus == .notDetermined else { return }
        resolver.requestPermissionIfNeeded()
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.resolver.authorizationStatus != .notDetermined {
                    if self.consumers > 0 { self.restart() }
                    return
                }
            }
        }
    }

    /// A provider key was saved or removed: fetch with it now.
    func credentialsChanged(for provider: WeatherProviderID) {
        state.sources.backoff.clear(provider.rawValue)
        invalidateSchedule()
        if consumers > 0 { restart() }
    }

    func refreshNow() {
        guard state.policy.requestManualRefresh(now: Date()) else { return }
        publishPolicy()
        if consumers > 0 {
            restart()
        } else {
            let selection = selection
            Task { [weak self] in
                guard let self else { return }
                let resolved = await self.resolver.resolve(selection)
                guard resolved.precise else { return }
                await self.fetch(resolved.coordinate)
            }
        }
    }

    // MARK: Loop

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            let selection = selection
            let resolved = await resolver.resolve(selection)
            guard !Task.isCancelled else { return }
            locationStatus = resolved.status
            guard resolved.precise else {
                // Wait for permission or a fix rather than fetch a guessed place.
                try? await Task.sleep(for: .seconds(15 * 60))
                continue
            }
            var coordinate = resolved.coordinate
            if case .device = selection {
                // Coarse fixes wander; keep the previous cell unless we moved.
                if let previous = state.deviceCoordinate, abs(previous.latitude - coordinate.latitude) < 0.03,
                   abs(WeatherSkyGeometry.wrap180(previous.longitude - coordinate.longitude)) < 0.03 {
                    coordinate = previous
                }
                state.deviceCoordinate = coordinate
                if deviceCoordinate != coordinate { deviceCoordinate = coordinate }
                locality = resolver.locality
            } else {
                locality = nil
            }
            let provider = choice?.provider ?? .default
            if state.policyCoordinate != coordinate || (state.policyProvider ?? .default) != provider {
                state.policyCoordinate = coordinate
                state.policyProvider = provider
                state.policy.invalidateLocation()
                publishPolicy()
            }
            let now = Date()
            let due = state.policy.nextDue(now: now)
            if due <= now {
                await fetch(coordinate)
                continue
            }
            // A station or the provider's own observation corrects "now" between forecasts.
            let request = self.request()
            let observationDue = snapshot.flatMap { snapshot in
                snapshot.coordinate == coordinate
                    ? WeatherSourceRouter.observationDue(snapshot, request: request, state: state.sources, now: now) : nil
            }
            if let observationDue, observationDue <= now {
                await observe(coordinate, request: request)
                continue
            }
            if let retry = state.policy.retryAfter, retry > now { status = .retrying(retry) }
            // Wake periodically to follow the device location.
            let wake = min(due, observationDue ?? .distantFuture).timeIntervalSince(now)
            try? await Task.sleep(for: .seconds(min(wake, 15 * 60)))
        }
    }

    /// The chosen provider with its key, read from the keychain per round.
    private func request() -> WeatherProviderRequest {
        let choice = choice ?? WeatherProviderChoice()
        let key = choice.provider.requiresAPIKey ? WeatherCredentials.apiKey(for: choice.provider) : nil
        return WeatherProviderRequest(choice: choice, apiKey: key)
    }

    /// A new provider, key, or User-Agent makes the old schedule meaningless.
    private func invalidateSchedule() {
        state.policy.invalidateLocation()
        state.sources.issue = nil
        providerIssue = nil
        publishPolicy()
    }

    /// One observation round; the forecast keeps its own schedule.
    private func observe(_ coordinate: WeatherCoordinate, request: WeatherProviderRequest) async {
        guard let current = snapshot else { return }
        var sources = state.sources
        let update = await WeatherSourceRouter.observe(current, request: request, state: &sources, now: Date())
        state.sources = sources
        guard !Task.isCancelled else { return }
        if let update, var next = snapshot, next.coordinate == coordinate {
            next.apply(update)
            if next != snapshot {
                snapshot = next
                state.snapshot = next
            }
        }
        let stateToSave = state
        Task { await WeatherDiskCache.shared.save(stateToSave) }
    }

    private func fetch(_ coordinate: WeatherCoordinate) async {
        let now = Date()
        let previous = snapshot
        let request = self.request()
        var sources = state.sources
        status = .fetching
        state.policy.recordStarted(now: now)
        defer { providerIssue = state.sources.issue }
        do {
            let outcome = try await WeatherSourceRouter.fetch(coordinate, request: request, previous: previous,
                                                              state: &sources, now: now)
            state.sources = sources
            switch outcome {
            case .updated(let next):
                let changed = previous.map {
                    $0.coordinate != next.coordinate || $0.current.kind != next.current.kind
                        || abs($0.current.cloudCover - next.current.cloudCover) > 0.2
                } ?? true
                snapshot = next
                state.snapshot = next
                state.policy.recordSuccess(now: now, expiresAt: next.expiresAt, changed: changed, jitter: .random(in: 0..<1))
            case .notModified(let expires):
                state.policy.recordSuccess(now: now, expiresAt: expires, changed: false, jitter: .random(in: 0..<1))
            }
            status = .updated
        } catch {
            state.sources = sources
            if Task.isCancelled {
                status = .idle
            } else if case WeatherFetchError.rateLimited(let retry) = error {
                state.policy.recordRateLimited(retryAfterSeconds: retry, now: now)
                status = .retrying(state.policy.nextDue(now: now))
            } else {
                state.policy.recordFailure(now: now)
                status = .retrying(state.policy.nextDue(now: now))
                Ghostty.logger.info("Live Weather fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
        publishPolicy()
        let snapshotToSave = state
        Task { await WeatherDiskCache.shared.save(snapshotToSave) }
    }

    private func publishPolicy() {
        manualRefreshAt = state.policy.manualAvailableAt(now: Date())
    }
}
#endif
