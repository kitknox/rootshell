import Foundation
import CoreLocation
import MapKit
import Combine
import os.log

/// Mode for Location Diary operation
enum LocationDiaryMode: String, Codable {
    case off           // Not enabled
    case sessionOnly   // Manual mode, non-persistent across app restarts
    case autoForRemote // Auto-enable for remote sessions (persisted)
}

@MainActor
class LocationDiaryManager: NSObject, ObservableObject {
    static let shared = LocationDiaryManager()

    private nonisolated static let autoModeKey = "location_diary_auto_mode"


    /// Current location diary mode
    @Published var mode: LocationDiaryMode = .off {
        didSet {
            guard oldValue != mode else { return }
            guard ProtectedDataGuard.isAvailable else { return }
            logger.info("Location diary mode changed: \(oldValue.rawValue) -> \(self.mode.rawValue)")

            // Persist/clear auto mode preference based on mode changes.
            if !isReloading {
                SettingsStore.shared.set(Settings.Privacy.locationDiaryAutoMode, mode == .autoForRemote)
            }

            updateTrackingState()
        }
    }

    private var isReloading = false

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if SettingsStore.shared.get(Settings.Privacy.locationDiaryAutoMode) {
            mode = .autoForRemote
        } else if mode == .autoForRemote {
            mode = .off
        }
    }

    /// Whether tracking is currently active (for backward compatibility)
    var isEnabled: Bool {
        isTrackingActive
    }

    /// Whether location tracking is actually running
    @Published private(set) var isTrackingActive: Bool = false

    /// Whether auto mode is saved (for checking on app restart)
    var hasAutoModeEnabled: Bool {
        SettingsStore.shared.get(Settings.Privacy.locationDiaryAutoMode)
    }

    /// Whether Location Diary is configured and able to work.
    /// Use this to decide whether to show setup prompts — it returns true even when
    /// tracking is temporarily paused (e.g., auto mode with no active sessions),
    /// but returns false if location authorization was denied or restricted.
    var isConfigured: Bool {
        guard mode != .off || hasAutoModeEnabled else { return false }
        // If the user opted in but iOS permission is denied/restricted,
        // background keepalive still won't work — keep showing the warning.
        switch authorizationStatus {
        case .denied, .restricted:
            return false
        default:
            return true
        }
    }

    /// Recorded location entries.
    ///
    /// Note: NOT `@Published`. Background CoreLocation updates fire several
    /// writes per minute (append, geocoded reassignment, prune); each
    /// `@Published` write fires `objectWillChange` on this manager, which
    /// invalidates every view holding it as `@ObservedObject` — including
    /// the giant `SettingsView` tree when its sheet is open during a
    /// background→foreground cycle. Those queued invalidations were the
    /// source of the post-resume scene-update watchdog kills.
    ///
    /// Mutations call `notifyChange()`, which sends `objectWillChange` only
    /// when the app is foregrounded; otherwise it sets a pending flag and
    /// `replayCachedStateOnForeground()` fires one consolidated change on
    /// app activation.
    private(set) var entries: [LocationDiaryEntry] = [] {
        willSet { notifyChange() }
    }
    private(set) var currentLocation: String? {
        willSet { notifyChange() }
    }
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True when at least one background mutation has been suppressed and a
    /// foreground replay needs to fire `objectWillChange`.
    private var hasPendingForegroundChange: Bool = false

    /// Send `objectWillChange` if foregrounded; otherwise mark a pending
    /// replay. Called from `willSet` on the high-frequency observable
    /// properties.
    private func notifyChange() {
        if Ghostty.isAppBackgrounded {
            hasPendingForegroundChange = true
        } else {
            objectWillChange.send()
        }
    }

    /// On foreground return, fire one `objectWillChange` if any background
    /// mutations were suppressed. Call from `MainViewLifecycle.handleAppForegrounded`.
    func replayCachedStateOnForeground() {
        guard hasPendingForegroundChange else { return }
        hasPendingForegroundChange = false
        objectWillChange.send()
    }

    private let locationManager = CLLocationManager()
    private var pruneTimer: Timer?
    private let logger = Logger(subsystem: "com.rootshell", category: "LocationDiary")

    // Geocoding cache and state tracking
    private var geocodingCache: [String: (location: CLLocation, address: String)] = [:]
    private var pendingGeocoding: Set<UUID> = []
    private var activeSearches: [UUID: MKLocalSearch] = [:]
    private let cacheDistanceThreshold: CLLocationDistance = 100 // meters
    private let maxRetries = 3

    // MARK: - Background Update Hooks

    /// Callbacks invoked on each background location update.
    /// Other subsystems (e.g. NetworkInfoLiveActivityBridge) register here
    /// to piggyback on the diary's background execution time.
    private var backgroundUpdateCallbacks: [String: @MainActor () -> Void] = [:]

    /// Register a callback to be invoked on each background location update.
    func registerBackgroundUpdateCallback(key: String, callback: @escaping @MainActor () -> Void) {
        backgroundUpdateCallbacks[key] = callback
    }

    /// Remove a previously registered callback.
    func removeBackgroundUpdateCallback(key: String) {
        backgroundUpdateCallbacks.removeValue(forKey: key)
    }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true

        authorizationStatus = locationManager.authorizationStatus

        // The diary only exists on iOS/visionOS (background SSH keepalive).
        // On macOS the singleton can still be touched lazily by views that
        // observe it, so keep it inert: no prune timer, no auto-mode restore.
        #if !targetEnvironment(macCatalyst)
        // Start pruning timer to remove entries older than 5 minutes.
        // Skip ticks during the foreground resume quiet window — pruning is
        // small, but iterating entries + cancelling MKLocalSearches while
        // SwiftUI is settling its scene-update transaction has been a
        // contributing source of @Published cascades on resume. A 10s lag
        // is invisible to the user; the diary's resolution is 5 minutes.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Ghostty.isInResumeQuietWindowAtomic { return }
            Task { @MainActor in
                self.pruneOldEntries()
            }
        }

        // Restore persisted mode off the init frame. UserDefaults reads are
        // typically fast, but the cascade triggered by `mode = .autoForRemote`
        // (didSet → updateTrackingState → CL start, plus a @Published
        // invalidation) absolutely should not run inside the launch /
        // foreground scene-update transaction. Defer by 0.5s — same window
        // used by NetworkInfoLiveActivityBridge so the two staggered systems
        // settle on the same beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let saved = SettingsStore.shared.value(Settings.Privacy.locationDiaryAutoMode)
                guard saved else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logger.info("Restoring auto mode from saved preference")
                    self.mode = .autoForRemote
                }
            }
        }
        #endif

        SettingsRefreshHub.shared.register(keys: [Settings.Privacy.locationDiaryAutoMode.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }

        logger.info("LocationDiaryManager initialized, mode: \(self.mode.rawValue)")
    }

    deinit {
        pruneTimer?.invalidate()
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Called by SessionTracker when the non-resilient session count changes
    /// Non-resilient sessions (SSH, K8s, Console, VNC, KVM) and local shells with active long-running tasks
    /// need location services to stay alive. Roam/Mosh doesn't need this - it uses UDP state-sync
    func updateNonResilientSessionCount(_ count: Int) {
        logger.debug("Non-resilient session count updated: \(count), current mode: \(self.mode.rawValue), auto saved: \(self.hasAutoModeEnabled)")

        // Only act if we're in auto mode or have auto mode saved
        guard mode == .autoForRemote || (mode == .off && hasAutoModeEnabled) else {
            return
        }

        if count > 0 && mode == .off && hasAutoModeEnabled {
            // Non-resilient sessions started and auto mode is saved - auto enable
            logger.info("Auto-enabling location diary for \(count) non-resilient session(s)")
            mode = .autoForRemote
        } else if count == 0 && mode == .autoForRemote {
            // Last non-resilient session ended - stop tracking but stay in autoForRemote mode
            // so it re-enables when new sessions start
            logger.info("All non-resilient sessions ended, pausing location tracking (auto mode remains active)")
            stopTrackingOnly()
        } else if count > 0 && mode == .autoForRemote && !isTrackingActive {
            // Sessions exist and we're in auto mode but not tracking - start tracking
            logger.info("Resuming location tracking for \(count) non-resilient session(s)")
            startTracking()
        }
    }

    /// Update tracking state based on current mode
    private func updateTrackingState() {
        switch mode {
        case .off:
            stopTracking()
        case .sessionOnly:
            // Session only: always track until turned off
            startTracking()
        case .autoForRemote:
            // Auto mode: only track when non-resilient sessions exist
            // Roam/Mosh doesn't count - it survives via UDP state-sync
            let sessionCount = RemoteSessionTracker.shared.totalNonResilientSessionCount
            if sessionCount > 0 {
                startTracking()
            } else {
                // No non-resilient sessions - stop tracking but stay in auto mode
                stopTrackingOnly()
            }
        }
    }

    private func startTracking() {
        #if os(visionOS)
        guard authorizationStatus == .authorizedWhenInUse else {
            requestPermission()
            return
        }
        #else
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            requestPermission()
            return
        }

        locationManager.allowsBackgroundLocationUpdates = true
        #endif
        // CLLocationManager has run-loop affinity to the thread it was
        // created on (main, in init); start/stopUpdatingLocation must be
        // invoked there. The caller (`updateTrackingState`) is driven by
        // user toggles and session-count changes, never by foreground
        // resume, so this stays on main.
        locationManager.startUpdatingLocation()
        isTrackingActive = true
        logger.debug("Location tracking started")
    }

    /// Stop tracking completely and clear all data
    private func stopTracking() {
        stopTrackingOnly()

        // Cancel all pending geocoding requests
        for (_, search) in activeSearches {
            search.cancel()
        }

        entries.removeAll()
        currentLocation = nil
        pendingGeocoding.removeAll()
        activeSearches.removeAll()
        geocodingCache.removeAll()
    }

    /// Stop location updates only, without clearing data (used for auto mode pause)
    private func stopTrackingOnly() {
        // CLLocationManager has run-loop affinity to its creation thread
        // (main); keep the call here to match. Driven by user toggles and
        // session-count transitions, never by foreground resume.
        locationManager.stopUpdatingLocation()
        #if !os(visionOS)
        locationManager.allowsBackgroundLocationUpdates = false
        #endif
        isTrackingActive = false
        logger.debug("Location tracking stopped")
    }

    private func pruneOldEntries() {
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        let entriesToRemove = entries.filter { $0.timestamp < fiveMinutesAgo }

        // Nothing stale: bail before touching `entries` — even a no-op
        // removeAll fires willSet/objectWillChange and re-renders every
        // observing view (the connection form does a full list diff).
        guard !entriesToRemove.isEmpty else { return }

        // Remove entries from pending geocoding tracking and cancel active searches
        for entry in entriesToRemove {
            pendingGeocoding.remove(entry.id)
            if let search = activeSearches.removeValue(forKey: entry.id) {
                search.cancel()
            }
        }

        entries.removeAll { $0.timestamp < fiveMinutesAgo }
    }

    private func addEntry(from location: CLLocation) {
        // Check cache first
        if let cached = checkCache(for: location) {
            let entry = LocationDiaryEntry(
                timestamp: Date(),
                coordinate: location.coordinate,
                addressState: .resolved(cached.address),
                retryCount: 0
            )
            entries.append(entry)
            pruneOldEntries()
            currentLocation = cached.address
            return
        }

        // Create entry in resolving state
        let entry = LocationDiaryEntry(
            timestamp: Date(),
            coordinate: location.coordinate,
            addressState: .resolving,
            retryCount: 0
        )

        entries.append(entry)
        pruneOldEntries()

        // Start reverse geocoding
        reverseGeocode(location: location, for: entry)
    }

    private func checkCache(for location: CLLocation) -> (location: CLLocation, address: String)? {
        // Check each cached location to see if we're within threshold
        for (_, cached) in geocodingCache {
            if location.distance(from: cached.location) < cacheDistanceThreshold {
                return cached
            }
        }
        return nil
    }

    private func cacheKey(from location: CLLocation) -> String {
        // Use a grid-based key for cache organization
        let lat = Int(location.coordinate.latitude * 1000)
        let lon = Int(location.coordinate.longitude * 1000)
        return "\(lat),\(lon)"
    }

    private func reverseGeocode(location: CLLocation, for entry: LocationDiaryEntry) {
        // Mark as pending
        pendingGeocoding.insert(entry.id)

        // Create search request for reverse geocoding
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(location.coordinate.latitude),\(location.coordinate.longitude)"
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        request.resultTypes = .address

        let search = MKLocalSearch(request: request)
        activeSearches[entry.id] = search

        search.start { [weak self] response, error in
            Task { @MainActor in
                guard let self = self else { return }

                // Remove from pending and active searches
                self.pendingGeocoding.remove(entry.id)
                self.activeSearches.removeValue(forKey: entry.id)

                // Find the entry (it might have been pruned)
                guard let index = self.entries.firstIndex(where: { $0.id == entry.id }) else {
                    self.logger.debug("Entry was pruned before geocoding completed")
                    return
                }

                var updatedEntry = self.entries[index]

                // Check for errors
                if let error = error {
                    // Check if it was cancelled
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                        self.logger.debug("Geocoding cancelled for entry")
                        return
                    }
                    self.handleGeocodingError(error, location: location, entry: &updatedEntry, index: index)
                    return
                }

                // Check for valid response
                guard let mapItem = response?.mapItems.first else {
                    self.logger.warning("No map items returned for location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                    self.handleGeocodingError(nil, location: location, entry: &updatedEntry, index: index)
                    return
                }

                // Success! Update with address
                let address = self.formatAddress(from: mapItem)
                updatedEntry.addressState = .resolved(address)
                self.entries[index] = updatedEntry

                // Cache the result
                let key = self.cacheKey(from: location)
                self.geocodingCache[key] = (location, address)

                // Update current location
                self.currentLocation = address

                self.logger.debug("Successfully geocoded location")
            }
        }
    }

    private func handleGeocodingError(_ error: Error?, location: CLLocation, entry: inout LocationDiaryEntry, index: Int) {
        // Log the error
        if let error = error {
            let clError = error as? CLError
            logger.error("Geocoding error: \(error.localizedDescription) (code: \(clError?.code.rawValue ?? -1))")
        }

        // Check if we should retry
        if entry.retryCount < maxRetries {
            entry.retryCount += 1
            entries[index] = entry

            // Calculate exponential backoff delay: 2^retryCount seconds
            let delay = pow(2.0, Double(entry.retryCount))
            let retryCount = entry.retryCount  // Capture value to avoid inout parameter in autoclosure
            logger.info("Scheduling retry \(retryCount)/\(self.maxRetries) in \(delay, format: .fixed(precision: 1))s")

            // Capture the entry ID before the Task to avoid capturing inout parameter
            let entryId = entry.id

            // Schedule retry
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                await MainActor.run {
                    // Check if entry still exists
                    if let currentIndex = self.entries.firstIndex(where: { $0.id == entryId }) {
                        let currentEntry = self.entries[currentIndex]
                        self.reverseGeocode(location: location, for: currentEntry)
                    }
                }
            }
        } else {
            // Max retries exhausted, mark as failed
            logger.warning("Max retries exhausted for location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            entry.addressState = .failed(location)
            entries[index] = entry
        }
    }

    private func formatAddress(from mapItem: MKMapItem) -> String {
        var components: [String] = []

        // Use the map item's name if available
        if let name = mapItem.name {
            components.append(name)
        }

        // Extract address components from placemark
        // Note: placemark is deprecated in iOS 26, but the replacement API (addressRepresentations)
        // doesn't provide a simple way to extract locality/administrativeArea.
        // For now, continue using placemark until a clearer migration path exists.
        let placemark = mapItem.placemark
        if components.isEmpty, let name = placemark.name {
            components.append(name)
        }
        if let locality = placemark.locality {
            components.append(locality)
        }
        if let administrativeArea = placemark.administrativeArea {
            components.append(administrativeArea)
        }

        return components.isEmpty ? "Unknown Location" : components.joined(separator: ", ")
    }
}

extension LocationDiaryManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus

            // If we just got authorized and a mode is active, update tracking state
            // This respects auto mode which only tracks when remote sessions exist
            #if os(visionOS)
            if self.mode != .off && manager.authorizationStatus == .authorizedWhenInUse {
                self.updateTrackingState()
            }
            #else
            if self.mode != .off && (manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse) {
                self.updateTrackingState()
            }
            #endif
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // If the foreground resume quiet window is active, defer the entry
        // add (and the registered background-update callbacks) past it. CL
        // can deliver a backed-up burst of locations as the app resumes, and
        // each call adds an entry, fires `notifyChange()`, and (cache-miss)
        // kicks off MKLocalSearch — none of which should run inside the
        // scene-update transaction.
        let dispatchDelay: DispatchTime = Ghostty.isInResumeQuietWindowAtomic
            ? .now() + 0.5
            : .now()
        DispatchQueue.main.asyncAfter(deadline: dispatchDelay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addEntry(from: location)
                for (_, callback) in self.backgroundUpdateCallbacks {
                    callback()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.error("Location manager failed: \(error.localizedDescription)")
        }
    }
}
