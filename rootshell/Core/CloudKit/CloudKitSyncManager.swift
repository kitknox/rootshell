//
//  CloudKitSyncManager.swift
//  rootshell
//
//  Main orchestrator for CloudKit sync operations
//

import Foundation
import CloudKit
import Network
import Observation
import os.log

/// Main manager for CloudKit sync operations
@MainActor
@Observable
final class CloudKitSyncManager {
    /// Shared singleton instance
    static let shared = CloudKitSyncManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "CloudKitSync")

    // MARK: - Observable State

    /// Whether sync is enabled
    private(set) var isSyncEnabled: Bool = false

    /// Whether SSH history sync is enabled
    private(set) var isHistorySyncEnabled: Bool = false

    /// Whether known hosts sync is enabled
    private(set) var isKnownHostsSyncEnabled: Bool = false

    /// Whether connection profiles sync is enabled
    private(set) var isProfilesSyncEnabled: Bool = false

    /// Whether app settings sync is enabled (opt-in, never auto-enabled)
    private(set) var isAppSettingsSyncEnabled: Bool = false

    /// Current sync state
    private(set) var syncState: CloudKitSyncState = .disabled

    /// Last successful sync date
    private(set) var lastSyncDate: Date?

    /// Number of pending changes
    var pendingChangesCount: Int {
        offlineQueue.count
    }

    // MARK: - CloudKit Components

    /// CloudKit container
    private let container: CKContainer

    /// Private database
    private let database: CKDatabase

    /// Offline queue for pending changes
    private let offlineQueue = CloudKitOfflineQueue()

    /// Last known server copies of AppSetting records, keyed by record name, so
    /// saves carry a change tag and conflicts surface instead of overwriting.
    @ObservationIgnored
    private var settingServerRecords: [String: CKRecord] = [:]

    /// Bumped whenever settings sync state is torn down (disable, master
    /// disable, account switch). In-flight saves compare it after each await
    /// and drop their results if it moved.
    @ObservationIgnored
    private var settingsSyncGeneration = 0

    private func invalidateSettingsSync() {
        settingsSyncGeneration += 1
        offlineQueue.removeAll(recordType: AppSettingRecord.recordType)
        settingServerRecords = [:]
    }

    /// JSON decoder for pending change payloads
    private let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Network path monitor
    @ObservationIgnored
    private var pathMonitor: NWPathMonitor?

    /// Whether network is available
    @ObservationIgnored
    private var isNetworkAvailable = true

    /// Record zone change token for incremental fetches
    @ObservationIgnored
    private var zoneChangeToken: CKServerChangeToken?

    // MARK: - Initialization

    private init() {
        self.container = CKContainer(identifier: AppIdentifiers.iCloudContainerID)
        self.database = container.privateCloudDatabase

        // Load settings
        loadSettings()

        // Load change token
        loadChangeToken()

        // Start network monitoring
        startNetworkMonitoring()

        // Set up manager callbacks for sync integration
        setupManagerCallbacks()

        startAccountChangeObservation()
    }

    /// Set up callbacks to receive local changes from managers
    private func setupManagerCallbacks() {
        // SSH Connection History changes
        SSHConnectionHistoryManager.shared.onLocalChange = { [weak self] entry, operation in
            self?.recordLocalChange(entry, operation: operation)
        }

        // Known Hosts changes
        KnownHostsManager.shared.onLocalChange = { [weak self] host, operation in
            self?.recordLocalChange(host, operation: operation)
        }

        // Connection Profiles changes
        ConnectionProfileManager.shared.onLocalChange = { [weak self] profile, operation in
            self?.recordLocalChange(profile, operation: operation)
        }

        // App settings: batched by the coordinator, pushed here
        let coordinator = SettingsSyncCoordinator.shared
        coordinator.isEnabled = isSyncEnabled && isAppSettingsSyncEnabled
        coordinator.onOutgoingBatch = { [weak self] records in
            self?.recordLocalSettingChanges(records)
        }
    }

    // MARK: - Account identity

    /// Set when the signed-in Apple Account changed under an enabled settings sync.
    private(set) var settingsSyncPausedForAccountChange = false

    @ObservationIgnored
    private var accountChangeObserver: NSObjectProtocol?

    private func startAccountChangeObservation() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await CloudKitSyncManager.shared.checkAccountIdentity()
            }
        }
    }

    /// Detect an Apple Account switch. `ubiquityIdentityToken` is unreliable
    /// with CloudKit-only entitlements, so compare the user record ID.
    func checkAccountIdentity() async {
        guard isSyncEnabled else { return }
        let identity: String
        do {
            identity = try await container.userRecordID().recordName
        } catch {
            Self.logger.debug("Account identity unavailable: \(error.localizedDescription)")
            return
        }
        let coordinator = SettingsSyncCoordinator.shared
        let previous = coordinator.sidecar.accountIdentity
        guard let previous else {
            coordinator.setAccountIdentity(identity)
            return
        }
        guard previous != identity else { return }

        Self.logger.warning("Apple Account changed; resetting sync state and pausing settings sync")
        zoneChangeToken = nil
        saveChangeToken()
        offlineQueue.clearAll()
        invalidateSettingsSync()
        coordinator.resetSyncState()
        coordinator.setAccountIdentity(identity)
        if isAppSettingsSyncEnabled {
            isAppSettingsSyncEnabled = false
            coordinator.isEnabled = false
            settingsSyncPausedForAccountChange = true
            saveSettings()
        }
    }

    // MARK: - App Settings Sync

    enum SettingsSyncEnableOutcome {
        case enabled
        case needsMergeChoice(SettingsMergePreview)
    }

    /// Push a batch of changed setting records, or queue them offline.
    private func recordLocalSettingChanges(_ records: [AppSettingRecord]) {
        guard isSyncEnabled, isAppSettingsSyncEnabled else { return }
        if isNetworkAvailable && !isRateLimitBackoff {
            Task { await pushRecords(records) }
        } else {
            for record in records {
                offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update)
            }
        }
    }

    /// Enable settings sync. When both this device and iCloud already hold
    /// settings the caller must present the merge choice and complete it.
    func setAppSettingsSyncEnabled(_ enabled: Bool) async throws -> SettingsSyncEnableOutcome {
        let coordinator = SettingsSyncCoordinator.shared
        guard enabled else {
            isAppSettingsSyncEnabled = false
            coordinator.isEnabled = false
            coordinator.resetSyncState()
            // Queued edits must not drain later under a disabled toggle.
            invalidateSettingsSync()
            saveSettings()
            return .enabled
        }
        guard isSyncEnabled else { throw CloudKitSyncError.notEnabled }
        guard !isAppSettingsSyncEnabled else { return .enabled }
        settingsSyncPausedForAccountChange = false

        syncState = .fetchingChanges
        do {
            _ = try await ensureCustomZoneReady()
            // An existing change token has already consumed past AppSetting
            // records, so fetch the zone from scratch.
            let changes = try await fetchZoneChanges(resetToken: true)
            await processChangedRecords(changes.records)
            await processDeletedRecords(changes.deletedRecords)
            let cloud = changes.records.compactMap { $0.recordType == AppSettingRecord.recordType ? AppSettingRecord.from($0) : nil }
            let preview = coordinator.mergePreview(cloud: cloud)

            // A cloud holding only resets still conflicts with local values.
            if (preview.cloudCount > 0 || preview.resetCount > 0) && preview.localCount > 0 {
                syncState = .idle
                return .needsMergeChoice(preview)
            }
            let choice: SettingsMergeChoice = preview.cloudCount > 0 ? .useCloud : .uploadLocal
            try await completeAppSettingsSyncEnable(preview: preview, choice: choice)
            return .enabled
        } catch let error as CloudKitSyncError {
            syncState = .error(error)
            throw error
        } catch let ckError as CKError {
            let syncError = CloudKitSyncError.from(ckError)
            syncState = .error(syncError)
            throw syncError
        }
    }

    /// Finish enabling after the merge choice (or automatically when one side was empty).
    func completeAppSettingsSyncEnable(preview: SettingsMergePreview, choice: SettingsMergeChoice) async throws {
        let coordinator = SettingsSyncCoordinator.shared
        syncState = .pushingChanges
        // Fetches while the sheet was open updated the record cache but were
        // otherwise dropped, so merge from the cache rather than the preview.
        let cloud = settingServerRecords.isEmpty
            ? preview.cloud
            : settingServerRecords.values.compactMap { AppSettingRecord.from($0) }
        let toPush = coordinator.completeInitialMerge(cloud: cloud, choice: choice)
        isAppSettingsSyncEnabled = true
        coordinator.isEnabled = true
        saveSettings()
        if !toPush.isEmpty {
            await pushRecords(toPush)
        }
        syncState = .idle
        Self.logger.info("App settings sync enabled (\(toPush.count) records pushed)")
    }

    /// Batched save with per-record results; conflicts are merged per key.
    private func pushRecords(_ records: [AppSettingRecord]) async {
        guard !records.isEmpty, isSyncEnabled, isAppSettingsSyncEnabled else { return }
        let coordinator = SettingsSyncCoordinator.shared
        let generation = settingsSyncGeneration
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0 + 200, records.count)]) }) {
            do {
                let outcome = try await saveRecords(chunk)
                guard generation == settingsSyncGeneration, isAppSettingsSyncEnabled else {
                    Self.logger.info("Dropping results of a settings push that outlived its sync session")
                    return
                }
                coordinator.markPushed(outcome.saved)
                if !outcome.serverWins.isEmpty {
                    coordinator.applyRemote(outcome.serverWins)
                }
                for record in outcome.failed {
                    offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update)
                }
            } catch is CancellationError {
                return
            } catch let error as CKError where error.code == .requestRateLimited {
                guard generation == settingsSyncGeneration else { return }
                let retryAfter = error.retryAfterSeconds ?? 30
                Self.logger.warning("Rate limited pushing settings, queuing \(chunk.count) and backing off \(retryAfter)s")
                for record in chunk { offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update) }
                isRateLimitBackoff = true
                scheduleRateLimitedRetry(after: retryAfter)
                return
            } catch {
                guard generation == settingsSyncGeneration else { return }
                Self.logger.warning("Failed to push settings batch, queuing: \(error.localizedDescription)")
                for record in chunk { offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update) }
            }
        }
    }

    private struct SettingsSaveOutcome {
        var saved: [AppSettingRecord] = []
        var serverWins: [AppSettingRecord] = []
        var failed: [AppSettingRecord] = []
    }

    /// Saves are conditional on the server change tag, so an older offline edit
    /// can never overwrite newer cloud state; conflicts are settled per key.
    private func saveRecords(_ records: [AppSettingRecord]) async throws -> SettingsSaveOutcome {
        let byName = Dictionary(records.map { (AppSettingRecord.recordName(for: $0), $0) }, uniquingKeysWith: { $1 })
        let toSave: [CKRecord] = byName.map { name, local in
            if let known = settingServerRecords[name] {
                local.apply(to: known)
                return known
            }
            return local.toCKRecord()
        }
        let generation = settingsSyncGeneration
        let (saveResults, _) = try await database.modifyRecords(
            saving: toSave,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        // Sync was torn down while the request was in flight; touch nothing.
        guard generation == settingsSyncGeneration else { throw CancellationError() }
        var outcome = SettingsSaveOutcome()
        var retry: [CKRecord] = []
        for (recordID, result) in saveResults {
            guard let local = byName[recordID.recordName] else { continue }
            switch result {
            case .success(let saved):
                settingServerRecords[recordID.recordName] = saved
                outcome.saved.append(local)
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .serverRecordChanged,
                   let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    settingServerRecords[recordID.recordName] = serverRecord
                    guard let serverModel = AppSettingRecord.from(serverRecord) else {
                        // Unreadable server copy: replace it with the local value.
                        local.apply(to: serverRecord)
                        retry.append(serverRecord)
                        continue
                    }
                    let decision = SettingsMergeResolver.resolve(
                        local: .init(value: local.isDeleted ? nil : local.payload, modifiedAt: local.modifiedAt, deviceID: local.deviceID),
                        remote: .init(value: serverModel.payload, modifiedAt: serverModel.modifiedAt, deviceID: serverModel.deviceID),
                        alreadyPushed: false)
                    switch decision {
                    case .keepLocalAndPush, .keepLocal:
                        local.apply(to: serverRecord)
                        retry.append(serverRecord)
                    case .applyRemote:
                        outcome.serverWins.append(serverModel)
                    case .noop:
                        outcome.saved.append(local)
                    }
                } else if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    throw ckError
                } else {
                    Self.logger.warning("Setting record \(local.key, privacy: .public) failed: \(error.localizedDescription)")
                    outcome.failed.append(local)
                }
            }
        }
        if !retry.isEmpty {
            let (retryResults, _) = try await database.modifyRecords(
                saving: retry, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            guard generation == settingsSyncGeneration else { throw CancellationError() }
            for (recordID, result) in retryResults {
                guard let local = byName[recordID.recordName] else { continue }
                switch result {
                case .success(let saved):
                    settingServerRecords[recordID.recordName] = saved
                    outcome.saved.append(local)
                case .failure:
                    // Lost a second race; the queue retries and the next fetch brings the winner.
                    outcome.failed.append(local)
                }
            }
        }
        return outcome
    }

    // MARK: - Public API

    /// Revalidate subscriptions on app launch (ensures correct subscription type is registered)
    /// Call this from app startup when sync is already enabled
    func revalidateSubscriptionsIfNeeded() async {
        guard isSyncEnabled else {
            Self.logger.debug("Subscription revalidation skipped: sync not enabled")
            return
        }

        Self.logger.info("Revalidating CloudKit subscriptions on app launch")
        await checkAccountIdentity()
        await recoverEmptyLocalStoresIfNeeded()
        do {
            let shouldPushAll = try await ensureCustomZoneReady()
            try await registerSubscriptions()

            // If migration happened during revalidation, push records now.
            // The push-all decision must be forwarded: performSync re-runs
            // ensureCustomZoneReady, which returns false now that the zone
            // exists and the migration flag is persisted.
            if shouldPushAll {
                Self.logger.info("Migration detected during revalidation, triggering sync")
                try await performSync(forcePushAll: true)
            } else if !pendingInitialPushTypes.isEmpty {
                // New record types were added since sync was enabled
                // First fetch to get any remote changes, then push all local records for new types
                Self.logger.info("New record types detected (\(self.pendingInitialPushTypes)), fetching and pushing")
                let typesToPush = pendingInitialPushTypes
                pendingInitialPushTypes.removeAll()

                // Fetch remote changes first
                syncState = .fetchingChanges
                let changes = try await fetchZoneChanges()
                await processChangedRecords(changes.records)
                await processDeletedRecords(changes.deletedRecords)

                // Push all local records for the new types
                try await pushNewRecordTypes(typesToPush)

                syncState = .idle
            } else {
                // Log current state for debugging
                Self.logger.debug("Revalidation complete. History enabled: \(self.isHistorySyncEnabled), KnownHosts enabled: \(self.isKnownHostsSyncEnabled), Profiles enabled: \(self.isProfilesSyncEnabled)")
            }
        } catch {
            Self.logger.warning("Failed to revalidate subscriptions: \(error.localizedDescription)")
        }
    }

    /// Whether empty-store recovery already ran this process
    @ObservationIgnored
    private var didAttemptEmptyStoreRecovery = false

    /// Self-heal for stores that load empty despite having synced before.
    ///
    /// The launch-time sync is delta-only (change token), so if a local store
    /// comes up empty — e.g. the directory listing failed transiently on first
    /// launch after an app update — nothing repopulates it and the UI shows no
    /// records until the user cycles the iCloud sync toggle. Detect that state,
    /// retry the disk load, and if a store is still empty perform the same full
    /// zone refetch that re-enabling sync does.
    ///
    /// Stores that are empty but hold tombstones do NOT trigger this: a user
    /// who deleted all their records keeps tombstones on disk, so this cannot
    /// resurrect deliberate deletions. The refetch itself is last-write-wins
    /// and applies remote tombstones, so it is safe to run against any state.
    private func recoverEmptyLocalStoresIfNeeded() async {
        guard !didAttemptEmptyStoreRecovery else { return }
        didAttemptEmptyStoreRecovery = true

        guard isSyncEnabled else { return }
        // Only recover stores that have synced before — a fresh enable goes
        // through performInitialSync and needs no help.
        guard zoneChangeToken != nil || lastSyncDate != nil else { return }

        let stores: [(recordType: String, enabled: Bool, count: () -> Int, loadFailed: () -> Bool, reload: () -> Void)] = [
            (ConnectionProfile.recordType,
             isProfilesSyncEnabled,
             { ConnectionProfileManager.shared.allRecordsForSync.count },
             { ConnectionProfileManager.shared.lastDiskLoadFailed },
             { ConnectionProfileManager.shared.reloadFromDisk() }),
            (SSHConnectionHistoryEntry.recordType,
             isHistorySyncEnabled,
             { SSHConnectionHistoryManager.shared.allRecordsForSync.count },
             { SSHConnectionHistoryManager.shared.lastDiskLoadFailed },
             { SSHConnectionHistoryManager.shared.reloadFromStore() }),
            (KnownHost.recordType,
             isKnownHostsSyncEnabled,
             { KnownHostsManager.shared.allRecordsForSync.count },
             { KnownHostsManager.shared.lastDiskLoadFailed },
             { KnownHostsManager.shared.reload() }),
        ]

        var refetchCandidates: [(recordType: String, count: () -> Int)] = []
        for store in stores where store.enabled && store.count() == 0 {
            let recordType = store.recordType
            let initialLoadFailed = store.loadFailed()
            store.reload()
            let recovered = store.count()
            if recovered > 0 {
                Self.logger.fault("\(recordType) store was empty at launch (listing failed: \(initialLoadFailed)) but disk reload recovered \(recovered) records")
                continue
            }

            // A failed directory listing is a hard signal that the data is
            // unreadable, not absent — always recover. An empty store with a
            // clean listing may be legitimately empty (e.g. no known hosts
            // yet), so refetch for it at most once rather than every launch.
            let loadFailed = initialLoadFailed || store.loadFailed()
            let attemptKey = Self.emptyRecoveryAttemptKey(recordType)
            if !loadFailed && UserDefaults.standard.bool(forKey: attemptKey) {
                continue
            }

            Self.logger.fault("\(recordType) store is empty with no tombstones (listing failed: \(loadFailed)) but sync ran before — forcing full CloudKit refetch")
            refetchCandidates.append((recordType, store.count))
        }

        guard !refetchCandidates.isEmpty else { return }

        do {
            syncState = .fetchingChanges
            let shouldPushAll = try await ensureCustomZoneReady()
            let changes = try await fetchZoneChanges(resetToken: true)
            await processChangedRecords(changes.records)
            await processDeletedRecords(changes.deletedRecords)

            if shouldPushAll {
                // ensureCustomZoneReady may have just created the zone or run
                // the legacy default-zone migration, and the migration flag is
                // already persisted — push now or the migrated records never
                // reach the custom zone.
                syncState = .pushingChanges
                try await pushAllLocalRecords()
            }

            for candidate in refetchCandidates {
                let attemptKey = Self.emptyRecoveryAttemptKey(candidate.recordType)
                if candidate.count() > 0 {
                    // Records came back, so the empty store was abnormal —
                    // allow recovery to run again if it ever recurs.
                    UserDefaults.standard.removeObject(forKey: attemptKey)
                } else {
                    UserDefaults.standard.set(true, forKey: attemptKey)
                }
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)
            syncState = .idle
            Self.logger.info("Empty-store recovery refetch completed")
        } catch {
            // Leave the state usable for the regular sync paths that follow.
            // Attempt flags are untouched so the refetch retries next launch.
            syncState = .idle
            let desc = error.localizedDescription
            Self.logger.error("Empty-store recovery refetch failed: \(desc)")
        }
    }

    private static func emptyRecoveryAttemptKey(_ recordType: String) -> String {
        "cloudKitEmptyRecoveryAttempted.\(recordType)"
    }

    /// Push records for newly added record types
    private func pushNewRecordTypes(_ types: Set<String>) async throws {
        syncState = .pushingChanges

        for recordType in types {
            switch recordType {
            case ConnectionProfile.recordType:
                let profiles = ConnectionProfileManager.shared.allRecordsForSync
                Self.logger.info("Pushing \(profiles.count) profiles for newly enabled profiles sync")
                for profile in profiles {
                    await pushRecord(profile, operation: .create)
                }
            case SSHConnectionHistoryEntry.recordType:
                let entries = SSHConnectionHistoryManager.shared.allRecordsForSync
                Self.logger.info("Pushing \(entries.count) history entries for newly enabled history sync")
                for entry in entries {
                    await pushRecord(entry, operation: .create)
                }
            case KnownHost.recordType:
                let hosts = KnownHostsManager.shared.allRecordsForSync
                Self.logger.info("Pushing \(hosts.count) known hosts for newly enabled hosts sync")
                for host in hosts {
                    await pushRecord(host, operation: .create)
                }
            case AppSettingRecord.recordType:
                // Settings are opt-in through setAppSettingsSyncEnabled; never pushed here.
                break
            default:
                Self.logger.warning("Unknown record type in pending push: \(recordType)")
            }
        }

        syncState = .idle
    }

    /// Enable or disable sync
    func setEnabled(_ enabled: Bool) async throws {
        guard enabled != isSyncEnabled else { return }

        if enabled {
            syncState = .checkingAccount

            // Check iCloud account status
            let status = try await container.accountStatus()
            guard status == .available else {
                syncState = .error(.accountNotAvailable)
                throw CloudKitSyncError.accountNotAvailable
            }

            // Set flags BEFORE initial sync so pushAllLocalRecords knows what to push
            isSyncEnabled = true
            isHistorySyncEnabled = true
            isKnownHostsSyncEnabled = true
            isProfilesSyncEnabled = true

            do {
                // Ensure custom zone exists (and migrate legacy data if needed)
                _ = try await ensureCustomZoneReady()

                // Register subscriptions
                try await registerSubscriptions()

                // Record the account before any data moves, so a later switch is detected.
                await checkAccountIdentity()

                // Perform initial sync
                syncState = .fetchingChanges
                try await performInitialSync()

                // Save settings (flags already set above)
                saveSettings()

                syncState = .idle
                Self.logger.info("CloudKit sync enabled")
            } catch {
                // Reset flags on failure
                isSyncEnabled = false
                isHistorySyncEnabled = false
                isKnownHostsSyncEnabled = false
                isProfilesSyncEnabled = false
                throw error
            }

        } else {
            // Cancel active operations
            syncState = .disabled

            // Remove subscriptions
            try? await removeSubscriptions()

            // Clear change token
            zoneChangeToken = nil
            saveChangeToken()

            // Clear offline queue
            offlineQueue.clearAll()
            invalidateSettingsSync()

            // Save settings
            isSyncEnabled = false
            isHistorySyncEnabled = false
            isKnownHostsSyncEnabled = false
            isProfilesSyncEnabled = false
            isAppSettingsSyncEnabled = false
            SettingsSyncCoordinator.shared.isEnabled = false
            SettingsSyncCoordinator.shared.resetSyncState()
            saveSettings()

            Self.logger.info("CloudKit sync disabled")
        }
    }

    /// Set whether SSH history sync is enabled
    func setHistorySyncEnabled(_ enabled: Bool) {
        isHistorySyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncHistoryKey)
    }

    /// Set whether known hosts sync is enabled
    func setKnownHostsSyncEnabled(_ enabled: Bool) {
        isKnownHostsSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncKnownHostsKey)
    }

    /// Set whether connection profiles sync is enabled
    func setProfilesSyncEnabled(_ enabled: Bool) {
        isProfilesSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncProfilesKey)
    }

    /// Trigger a manual sync
    func syncNow() async throws {
        guard isSyncEnabled else { return }
        guard syncState == .idle || syncState.hasError else { return }

        try await performSync()
    }

    /// Log diagnostic information for debugging sync issues
    func logDiagnostics() async {
        Self.logger.info("=== CloudKit Sync Diagnostics ===")
        Self.logger.info("Sync enabled: \(self.isSyncEnabled)")
        Self.logger.info("History sync enabled: \(self.isHistorySyncEnabled)")
        Self.logger.info("Known hosts sync enabled: \(self.isKnownHostsSyncEnabled)")
        Self.logger.info("Profiles sync enabled: \(self.isProfilesSyncEnabled)")
        Self.logger.info("App settings sync enabled: \(self.isAppSettingsSyncEnabled)")
        let coordinator = SettingsSyncCoordinator.shared
        let registry = SettingsRegistry.shared
        Self.logger.info("Settings registry: \(registry.definitions.count) keys, \(registry.syncableKeys.count) syncable, \(coordinator.pinnedDefinitions().count) pinned, \(coordinator.sidecar.pinnedGroups.count) pinned groups, \(coordinator.sidecar.deferredRemote.count) deferred remote")
        Self.logger.info("Current state: \(String(describing: self.syncState))")
        Self.logger.info("Last sync: \(self.lastSyncDate?.description ?? "never")")
        Self.logger.info("Pending changes: \(self.pendingChangesCount)")
        Self.logger.info("Has change token: \(self.zoneChangeToken != nil)")
        Self.logger.info("Migrated to custom zone: \(UserDefaults.standard.bool(forKey: CloudKitSyncSettings.migratedToCustomZoneKey))")
        Self.logger.info("Network available: \(self.isNetworkAvailable)")

        if isSyncEnabled {
            // Check iCloud account status
            do {
                let status = try await container.accountStatus()
                Self.logger.info("iCloud account status: \(String(describing: status))")
            } catch {
                Self.logger.warning("Failed to check iCloud account: \(error.localizedDescription)")
            }

            // Check zone exists
            do {
                let zone = try await fetchRecordZone(CloudKitSyncSettings.zoneID)
                Self.logger.info("Custom zone exists: \(zone != nil)")
            } catch {
                Self.logger.warning("Failed to check zone: \(error.localizedDescription)")
            }

            // Check subscription
            do {
                let subscription = try await database.subscription(for: "ghostty-sync-zone-changes")
                Self.logger.info("Zone subscription exists: \(subscription is CKRecordZoneSubscription)")
            } catch {
                Self.logger.info("Zone subscription: not found")
            }
        } else {
            Self.logger.info("CloudKit sync disabled, skipping remote diagnostics")
        }

        // Log local record counts (active vs total including tombstones)
        let historyActive = SSHConnectionHistoryManager.shared.entries.count
        let historyTotal = SSHConnectionHistoryManager.shared.allRecordsForSync.count
        let hostsActive = KnownHostsManager.shared.allHosts.count
        let hostsTotal = KnownHostsManager.shared.allRecordsForSync.count
        let profilesActive = ConnectionProfileManager.shared.profiles.count
        let profilesTotal = ConnectionProfileManager.shared.allRecordsForSync.count
        Self.logger.info("Local SSH history: \(historyActive) active, \(historyTotal) total (including \(historyTotal - historyActive) tombstones)")
        Self.logger.info("Local known hosts: \(hostsActive) active, \(hostsTotal) total (including \(hostsTotal - hostsActive) tombstones)")
        Self.logger.info("Local profiles: \(profilesActive) active, \(profilesTotal) total (including \(profilesTotal - profilesActive) tombstones)")

        Self.logger.info("=== End Diagnostics ===")
    }

    /// Handle a remote notification (called from AppDelegate)
    func handleRemoteNotification() async {
        guard isSyncEnabled else {
            Self.logger.debug("Remote notification ignored: sync not enabled")
            return
        }
        guard syncState == .idle else {
            Self.logger.debug("Remote notification ignored: sync state is \(String(describing: self.syncState))")
            return
        }

        Self.logger.info("Handling remote notification, waiting for CloudKit propagation...")

        // Delay to allow CloudKit to propagate the change across servers
        // Push notifications often arrive before data is queryable
        try? await Task.sleep(for: .seconds(2))

        Self.logger.info("Starting sync after delay")
        do {
            try await performSync()
            Self.logger.info("Remote notification sync completed successfully")
        } catch {
            Self.logger.warning("Remote notification sync failed: \(error.localizedDescription)")
        }

        // Schedule a follow-up sync in case CloudKit was still propagating
        // This catches records that weren't available on first fetch
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard syncState == .idle else { return }
            Self.logger.info("Running follow-up sync for late-arriving CloudKit data")
            try? await performSync()
        }
    }

    /// Record a local change for sync
    func recordLocalChange<T: CloudKitSyncable>(_ record: T, operation: SyncOperation) {
        guard isSyncEnabled else { return }

        // Check if this record type should be synced
        switch T.recordType {
        case SSHConnectionHistoryEntry.recordType:
            guard isHistorySyncEnabled else { return }
        case KnownHost.recordType:
            guard isKnownHostsSyncEnabled else { return }
        case ConnectionProfile.recordType:
            guard isProfilesSyncEnabled else { return }
        case AppSettingRecord.recordType:
            guard isAppSettingsSyncEnabled else { return }
        default:
            break
        }

        if isNetworkAvailable {
            // Try to sync immediately
            Task {
                await pushRecord(record, operation: operation)
            }
        } else {
            // Queue for later
            offlineQueue.enqueue(record, operation: operation)
        }
    }

    // MARK: - Sync Operations

    /// Perform a full sync cycle
    /// - Parameter forcePushAll: Push all local records even if the zone was
    ///   already ready (used when the caller observed zone creation/migration
    ///   in its own ensureCustomZoneReady call).
    private func performSync(forcePushAll: Bool = false) async throws {
        syncState = .fetchingChanges

        do {
            // Ensure custom zone exists (and migrate legacy data if needed)
            let zoneRequiresPush = try await ensureCustomZoneReady()
            let shouldPushAll = forcePushAll || zoneRequiresPush

            // Fetch remote changes from the custom zone
            let changes = try await fetchZoneChanges()
            await processChangedRecords(changes.records)
            await processDeletedRecords(changes.deletedRecords)

            // Push local changes
            syncState = .pushingChanges

            if shouldPushAll {
                // Zone was just created or migration happened - push all local records
                Self.logger.info("Pushing all local records to custom zone")
                try await pushAllLocalRecords()
            } else {
                // Normal sync - just push pending changes from offline queue
                try await pushPendingChanges()
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)

            syncState = .idle
            Self.logger.info("Sync completed successfully")

        } catch let error as CloudKitSyncError {
            syncState = .error(error)
            throw error
        } catch let ckError as CKError {
            let syncError = CloudKitSyncError.from(ckError)
            syncState = .error(syncError)
            throw syncError
        } catch {
            let syncError = CloudKitSyncError.unknown(error)
            syncState = .error(syncError)
            throw syncError
        }
    }

    /// Perform initial sync when first enabling
    private func performInitialSync() async throws {
        // Ensure custom zone exists (and migrate legacy data if needed)
        _ = try await ensureCustomZoneReady()

        // Fetch all existing records from the custom zone
        let changes = try await fetchZoneChanges(resetToken: true)
        await processChangedRecords(changes.records)
        await processDeletedRecords(changes.deletedRecords)

        // Push all local records to seed the zone
        try await pushAllLocalRecords()

        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)
    }

    /// Fetch all records of a type from the legacy default zone
    /// Returns true if fetch succeeded, false if record type doesn't exist yet
    @discardableResult
    private func fetchAllRecords<T: CloudKitSyncable>(type: T.Type) async throws -> Bool {
        // Don't use sort descriptors - CloudKit requires fields to be marked queryable/sortable
        // in the dashboard. We'll sort locally after fetching.
        let query = CKQuery(recordType: T.recordType, predicate: NSPredicate(value: true))

        var allRecords: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor? = nil

        do {
            repeat {
                let result: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor = cursor {
                    result = try await database.records(continuingMatchFrom: cursor)
                } else {
                    result = try await database.records(matching: query)
                }

                for (_, recordResult) in result.matchResults {
                    if case .success(let record) = recordResult {
                        allRecords.append(record)
                    }
                }

                cursor = result.queryCursor
            } while cursor != nil
        } catch let error as CKError {
            // Record type doesn't exist yet - this is fine on first sync
            // The schema will be created when we push local records
            if error.code == .unknownItem {
                Self.logger.info("Record type \(T.recordType) doesn't exist yet, will be created on first push")
                return false
            }
            // In development, fields may not be marked queryable - treat as empty
            // User needs to configure indexes in CloudKit Dashboard for queries to work
            if error.code == .invalidArguments,
               error.localizedDescription.contains("not marked queryable") {
                Self.logger.warning("Record type \(T.recordType) not queryable - configure indexes in CloudKit Dashboard")
                return true  // Schema exists but can't query - don't re-push all records
            }
            throw error
        }

        Self.logger.info("Fetched \(allRecords.count) \(T.recordType) records from CloudKit")

        // Apply to local store
        let records = allRecords.compactMap { T.from($0) }
        await applyRemoteRecords(records, type: type)
        return true
    }

    private struct DeletedRecord {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    private struct ZoneChanges {
        let records: [CKRecord]
        let deletedRecords: [DeletedRecord]
        let newChangeToken: CKServerChangeToken?
    }

    /// Ensure the custom record zone exists and legacy data is migrated
    /// - Returns: true if local records should be pushed to CloudKit (zone created OR migration performed)
    private func ensureCustomZoneReady() async throws -> Bool {
        let zoneID = CloudKitSyncSettings.zoneID
        let existingZone = try await fetchRecordZone(zoneID)

        var zoneCreated = false
        if existingZone == nil {
            try await saveRecordZone(CKRecordZone(zoneID: zoneID))
            zoneCreated = true
            zoneChangeToken = nil
            saveChangeToken()
            Self.logger.info("Created custom CloudKit zone: \(zoneID.zoneName)")
        }

        let didMigrate = try await migrateLegacyDefaultZoneIfNeeded()

        // Push all records if zone was just created OR if we migrated legacy data
        // This ensures devices that didn't create the zone still push their migrated data
        let shouldPushAll = zoneCreated || didMigrate
        if shouldPushAll {
            Self.logger.info("Will push all local records (zoneCreated=\(zoneCreated), didMigrate=\(didMigrate))")
        }
        return shouldPushAll
    }

    /// Fetch a record zone by ID
    private func fetchRecordZone(_ zoneID: CKRecordZone.ID) async throws -> CKRecordZone? {
        do {
            let results = try await database.recordZones(for: [zoneID])
            if let result = results[zoneID] {
                switch result {
                case .success(let zone):
                    return zone
                case .failure(let error):
                    throw error
                }
            }
            return nil
        } catch let error as CKError where error.code == .zoneNotFound {
            return nil
        }
    }

    /// Save a record zone (no-op if it already exists)
    private func saveRecordZone(_ zone: CKRecordZone) async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone already exists (server rejected), ignore
        } catch let error as CKError where error.code == .partialFailure {
            // Check if the partial failure is due to zone already existing
            if let partialErrors = error.partialErrorsByItemID,
               partialErrors.values.allSatisfy({ ($0 as? CKError)?.code == .serverRejectedRequest }) {
                // All failures are "already exists" type, ignore
            } else {
                throw error
            }
        }
    }

    /// One-time migration from the legacy default zone into local storage
    /// Returns true if migration was performed and records should be pushed to custom zone
    private func migrateLegacyDefaultZoneIfNeeded() async throws -> Bool {
        guard !UserDefaults.standard.bool(forKey: CloudKitSyncSettings.migratedToCustomZoneKey) else { return false }
        guard isHistorySyncEnabled || isKnownHostsSyncEnabled else { return false }

        Self.logger.info("Migrating legacy default-zone CloudKit records")

        do {
            if isHistorySyncEnabled {
                _ = try await fetchAllRecords(type: SSHConnectionHistoryEntry.self)
            }

            if isKnownHostsSyncEnabled {
                _ = try await fetchAllRecords(type: KnownHost.self)
            }

            UserDefaults.standard.set(true, forKey: CloudKitSyncSettings.migratedToCustomZoneKey)
            Self.logger.info("Legacy CloudKit migration complete - will push to custom zone")
            return true
        } catch {
            Self.logger.warning("Legacy CloudKit migration failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch incremental changes from the custom zone
    private func fetchZoneChanges(resetToken: Bool = false) async throws -> ZoneChanges {
        if resetToken {
            zoneChangeToken = nil
            saveChangeToken()
        }

        do {
            let changes = try await fetchZoneChangesInternal(previousToken: zoneChangeToken)
            zoneChangeToken = changes.newChangeToken
            saveChangeToken()
            return changes
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            Self.logger.warning("Zone change token expired, refetching from scratch")
            zoneChangeToken = nil
            saveChangeToken()
            let changes = try await fetchZoneChangesInternal(previousToken: nil)
            zoneChangeToken = changes.newChangeToken
            saveChangeToken()
            return changes
        } catch let ckError as CKError where ckError.code == .zoneNotFound {
            Self.logger.warning("Custom CloudKit zone not found, recreating")
            _ = try await ensureCustomZoneReady()
            return ZoneChanges(records: [], deletedRecords: [], newChangeToken: zoneChangeToken)
        }
    }

    private func fetchZoneChangesInternal(previousToken: CKServerChangeToken?) async throws -> ZoneChanges {
        let zoneID = CloudKitSyncSettings.zoneID
        var changedRecords: [CKRecord] = []
        var deletedRecords: [DeletedRecord] = []

        Self.logger.debug("Fetching zone changes (hasToken: \(previousToken != nil))")

        var currentToken = previousToken
        var moreComing = true
        var fetchCount = 0

        while moreComing {
            fetchCount += 1
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: currentToken)
            Self.logger.debug("Zone changes fetch #\(fetchCount): \(changes.modificationResultsByID.count) modifications, \(changes.deletions.count) deletions, moreComing: \(changes.moreComing)")

            for (recordID, result) in changes.modificationResultsByID {
                switch result {
                case .success(let modification):
                    changedRecords.append(modification.record)
                    Self.logger.debug("Received changed record: \(modification.record.recordType)/\(recordID.recordName)")
                case .failure(let error):
                    Self.logger.warning("Record modification fetch failed for \(recordID.recordName): \(error.localizedDescription)")
                }
            }

            for deletion in changes.deletions {
                deletedRecords.append(DeletedRecord(recordID: deletion.recordID, recordType: deletion.recordType))
                Self.logger.debug("Received deleted record: \(deletion.recordType)/\(deletion.recordID.recordName)")
            }

            currentToken = changes.changeToken
            moreComing = changes.moreComing

            // Long-lived zones page through a change log where most entries are
            // superseded, so a walk from an old token can take hundreds of
            // near-empty pages. Stopping early leaves the newest records
            // unreached while the sync still reports success, so only guard
            // against a runaway loop.
            if fetchCount % 100 == 0 {
                Self.logger.info("Zone changes fetch still paging: \(fetchCount) fetches, \(changedRecords.count) records so far")
            }
            if fetchCount >= 5000 {
                Self.logger.error("Zone changes fetch hit safety limit of \(fetchCount) iterations")
                break
            }
        }

        Self.logger.info("Zone changes complete: \(changedRecords.count) total modified, \(deletedRecords.count) total deleted after \(fetchCount) fetches")

        return ZoneChanges(
            records: changedRecords,
            deletedRecords: deletedRecords,
            newChangeToken: currentToken
        )
    }

    /// Process changed records from CloudKit
    private func processChangedRecords(_ records: [CKRecord]) async {
        // Settings are merged as one batch so managers reload and the terminal
        // config rewrites once, not once per key.
        var settingRecords: [AppSettingRecord] = []
        for record in records {
            switch record.recordType {
            case AppSettingRecord.recordType:
                settingServerRecords[record.recordID.recordName] = record
                guard isAppSettingsSyncEnabled else { continue }
                if let setting = AppSettingRecord.from(record) {
                    settingRecords.append(setting)
                }
            case SSHConnectionHistoryEntry.recordType:
                guard isHistorySyncEnabled else { continue }
                if let entry = SSHConnectionHistoryEntry.from(record) {
                    await applyRemoteRecords([entry], type: SSHConnectionHistoryEntry.self)
                }
            case KnownHost.recordType:
                guard isKnownHostsSyncEnabled else { continue }
                if let host = KnownHost.from(record) {
                    await applyRemoteRecords([host], type: KnownHost.self)
                }
            case ConnectionProfile.recordType:
                guard isProfilesSyncEnabled else { continue }
                if let profile = ConnectionProfile.from(record) {
                    await applyRemoteRecords([profile], type: ConnectionProfile.self)
                }
            default:
                Self.logger.warning("Unknown record type: \(record.recordType)")
            }
        }
        if !settingRecords.isEmpty {
            await applyRemoteRecords(settingRecords, type: AppSettingRecord.self)
        }
    }

    /// Process deleted records from CloudKit
    private func processDeletedRecords(_ records: [DeletedRecord]) async {
        guard !records.isEmpty else { return }

        var historyDeletions: Set<String> = []
        var hostDeletions: Set<String> = []
        var profileDeletions: Set<String> = []

        for record in records {
            switch record.recordType {
            case SSHConnectionHistoryEntry.recordType:
                guard isHistorySyncEnabled else { continue }
                historyDeletions.insert(record.recordID.recordName)
            case KnownHost.recordType:
                guard isKnownHostsSyncEnabled else { continue }
                hostDeletions.insert(record.recordID.recordName)
            case ConnectionProfile.recordType:
                guard isProfilesSyncEnabled else { continue }
                profileDeletions.insert(record.recordID.recordName)
            case AppSettingRecord.recordType:
                // Hard deletes only come from dashboard cleanup; tombstones carry the semantics.
                offlineQueue.dequeueRecord(record.recordID.recordName)
                settingServerRecords[record.recordID.recordName] = nil
            default:
                Self.logger.warning("Unknown deleted record type: \(record.recordType)")
            }
        }

        if !historyDeletions.isEmpty {
            for recordName in historyDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            SSHConnectionHistoryManager.shared.applyRemoteDeletions(recordNames: historyDeletions)
        }

        if !hostDeletions.isEmpty {
            for recordName in hostDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            KnownHostsManager.shared.applyRemoteDeletions(recordNames: hostDeletions)
        }

        if !profileDeletions.isEmpty {
            for recordName in profileDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            ConnectionProfileManager.shared.applyRemoteDeletions(recordNames: profileDeletions)
        }
    }

    /// Apply remote records to local stores
    private func applyRemoteRecords<T: CloudKitSyncable>(_ records: [T], type: T.Type) async {
        syncState = .applyingChanges

        switch T.recordType {
        case SSHConnectionHistoryEntry.recordType:
            if let entries = records as? [SSHConnectionHistoryEntry] {
                SSHConnectionHistoryManager.shared.applyRemoteChanges(entries)
            }
        case KnownHost.recordType:
            if let hosts = records as? [KnownHost] {
                KnownHostsManager.shared.applyRemoteChanges(hosts)
            }
        case ConnectionProfile.recordType:
            if let profiles = records as? [ConnectionProfile] {
                ConnectionProfileManager.shared.applyRemoteChanges(profiles)
            }
        case AppSettingRecord.recordType:
            if let settings = records as? [AppSettingRecord] {
                SettingsSyncCoordinator.shared.applyRemote(settings)
            }
        default:
            break
        }
    }

    /// Whether we're currently backing off from rate limiting
    @ObservationIgnored
    private var isRateLimitBackoff = false

    /// Push a single record to CloudKit
    private func pushRecord<T: CloudKitSyncable>(_ record: T, operation: SyncOperation) async {
        // If rate-limited, queue instead of hitting CloudKit again
        if isRateLimitBackoff {
            offlineQueue.enqueue(record, operation: operation)
            return
        }

        do {
            try await saveRecord(record)
            Self.logger.debug("Pushed \(T.recordType)/\(record.id.uuidString)")
        } catch let error as CKError where error.code == .requestRateLimited {
            let retryAfter = error.retryAfterSeconds ?? 30
            Self.logger.warning("Rate limited pushing record, queuing and backing off for \(retryAfter)s")
            offlineQueue.enqueue(record, operation: operation)
            isRateLimitBackoff = true
            scheduleRateLimitedRetry(after: retryAfter)
        } catch {
            Self.logger.warning("Failed to push record, queuing: \(error.localizedDescription)")
            offlineQueue.enqueue(record, operation: operation)
        }
    }

    /// Save a record with conflict resolution
    private func saveRecord<T: CloudKitSyncable>(_ record: T) async throws {
        let ckRecord = record.toCKRecord()

        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [ckRecord],
                deleting: [],
                savePolicy: .allKeys
            )
            for (_, result) in saveResults {
                if case .failure(let error) = result {
                    throw error
                }
            }
        } catch let ckError as CKError where ckError.code == .serverRecordChanged {
            try await resolveServerRecordConflict(ckError, localRecord: record)
        }
    }

    /// Resolve server record conflicts using server modification dates
    private func resolveServerRecordConflict<T: CloudKitSyncable>(
        _ error: CKError,
        localRecord: T
    ) async throws {
        guard let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
              let serverModel = T.from(serverRecord) else {
            throw error
        }

        if localRecord.modifiedAt > serverModel.modifiedAt {
            // Local is newer - apply local fields onto the server record and retry save
            localRecord.apply(to: serverRecord)
            let (saveResults, _) = try await database.modifyRecords(
                saving: [serverRecord],
                deleting: [],
                savePolicy: .allKeys
            )
            for (_, result) in saveResults {
                if case .failure(let error) = result {
                    throw error
                }
            }
        } else {
            // Server is newer - accept server record and update local store
            await applyRemoteRecords([serverModel], type: T.self)
        }
    }

    /// Push all pending changes from offline queue
    private func pushPendingChanges() async throws {
        let batch = offlineQueue.nextBatch(limit: 100)
        guard !batch.isEmpty else { return }

        Self.logger.info("Pushing \(batch.count) pending changes")

        // Settings go out as one batched save; the rest one at a time.
        let settingChanges = batch.filter { $0.recordType == AppSettingRecord.recordType }
        if !settingChanges.isEmpty {
            for change in settingChanges { offlineQueue.dequeue(change.id) }
            if isAppSettingsSyncEnabled {
                let records = settingChanges.compactMap { try? payloadDecoder.decode(AppSettingRecord.self, from: $0.payload) }
                await pushRecords(records)
            }
        }

        for change in batch where change.recordType != AppSettingRecord.recordType {
            do {
                try await pushPendingChange(change)
                offlineQueue.dequeue(change.id)
            } catch let error as CKError where error.code == .requestRateLimited {
                let retryAfter = error.retryAfterSeconds ?? 30
                Self.logger.warning("Rate limited by CloudKit, backing off for \(retryAfter)s with \(batch.count - 1) changes remaining")
                offlineQueue.incrementRetry(change.id)
                scheduleRateLimitedRetry(after: retryAfter)
                return
            } catch {
                offlineQueue.incrementRetry(change.id)
                Self.logger.warning("Failed to push pending change: \(error.localizedDescription)")
            }
        }

        // Prune failed changes
        offlineQueue.pruneFailedChanges()
    }

    /// Schedule a retry after rate limiting
    private func scheduleRateLimitedRetry(after seconds: Double) {
        Task {
            Self.logger.info("Waiting \(seconds)s before retrying rate-limited push")
            try? await Task.sleep(for: .seconds(seconds))
            isRateLimitBackoff = false
            guard isSyncEnabled, syncState == .idle || syncState == .pushingChanges else { return }
            Self.logger.info("Retrying pending changes after rate limit backoff")
            syncState = .pushingChanges
            try? await pushPendingChanges()
            if syncState == .pushingChanges {
                syncState = .idle
            }
        }
    }

    /// Push a single pending change
    private func pushPendingChange(_ change: PendingChange) async throws {
        switch change.recordType {
        case SSHConnectionHistoryEntry.recordType:
            guard let entry = try? payloadDecoder.decode(SSHConnectionHistoryEntry.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("SSHConnectionHistory payload decode failed")
            }
            try await saveRecord(entry)
        case KnownHost.recordType:
            guard let host = try? payloadDecoder.decode(KnownHost.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("KnownHost payload decode failed")
            }
            try await saveRecord(host)
        case ConnectionProfile.recordType:
            guard let profile = try? payloadDecoder.decode(ConnectionProfile.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("ConnectionProfile payload decode failed")
            }
            try await saveRecord(profile)
        case AppSettingRecord.recordType:
            guard let setting = try? payloadDecoder.decode(AppSettingRecord.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("AppSetting payload decode failed")
            }
            await pushRecords([setting])
        default:
            Self.logger.warning("Unknown record type in pending change: \(change.recordType)")
        }
    }

    /// Push all local records to CloudKit (for initial sync)
    private func pushAllLocalRecords() async throws {
        if isHistorySyncEnabled {
            // Check if there's legacy data that wasn't migrated
            let hasLegacyData = UserDefaults.standard.data(forKey: "ssh_connection_history") != nil

            if hasLegacyData && SSHConnectionHistoryManager.shared.allRecordsForSync.isEmpty {
                Self.logger.warning("Found legacy data in UserDefaults but store is empty - force re-migrating")
                SyncMigrationManager.forceMigrateSSHHistory()
                SSHConnectionHistoryManager.shared.reloadFromStore()
            }

            let entries = SSHConnectionHistoryManager.shared.allRecordsForSync
            Self.logger.info("Pushing \(entries.count) SSH history records to CloudKit")

            for entry in entries {
                await pushRecord(entry, operation: .create)
            }

            // Clean up legacy data after successful push
            if hasLegacyData && !entries.isEmpty {
                UserDefaults.standard.removeObject(forKey: "ssh_connection_history")
                Self.logger.info("Cleaned up legacy SSH history from UserDefaults")
            }
        }

        if isKnownHostsSyncEnabled {
            // Check if there's legacy data that wasn't migrated
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let legacyURL = documentsURL
                .appendingPathComponent(".ghostty", isDirectory: true)
                .appendingPathComponent("known_hosts.json")
            let hasLegacyData = FileManager.default.fileExists(atPath: legacyURL.path)

            if hasLegacyData && KnownHostsManager.shared.allRecordsForSync.isEmpty {
                Self.logger.warning("Found legacy known_hosts.json but store is empty - force re-migrating")
                SyncMigrationManager.forceMigrateKnownHosts()
                KnownHostsManager.shared.reload()
            }

            let hosts = KnownHostsManager.shared.allRecordsForSync
            Self.logger.info("Pushing \(hosts.count) known host records to CloudKit (legacy file exists: \(hasLegacyData))")

            for host in hosts {
                await pushRecord(host, operation: .create)
            }

            // Clean up legacy file after successful push
            if hasLegacyData && !hosts.isEmpty {
                try? FileManager.default.removeItem(at: legacyURL)
                Self.logger.info("Cleaned up legacy known_hosts.json")
            }
        }

        if isProfilesSyncEnabled {
            let profiles = ConnectionProfileManager.shared.allRecordsForSync
            Self.logger.info("Pushing \(profiles.count) connection profile records to CloudKit")

            for profile in profiles {
                await pushRecord(profile, operation: .create)
            }
        }

        if isAppSettingsSyncEnabled {
            let settings = SettingsSyncCoordinator.shared.recordsForInitialPush()
            Self.logger.info("Pushing \(settings.count) app setting records to CloudKit")
            await pushRecords(settings)
        }
    }

    // MARK: - Subscriptions

    /// Register CloudKit subscriptions for real-time updates
    /// Uses CKRecordZoneSubscription for the custom zone
    private func registerSubscriptions() async throws {
        let subscriptionID = "ghostty-sync-zone-changes"
        let zoneID = CloudKitSyncSettings.zoneID

        Self.logger.debug("Registering subscriptions for zone: \(zoneID.zoneName)")

        // Check if zone subscription already exists
        var needsCreation = false
        do {
            let existing = try await database.subscription(for: subscriptionID)
            if let zoneSubscription = existing as? CKRecordZoneSubscription {
                // Verify it's for the correct zone
                if zoneSubscription.zoneID == zoneID {
                    Self.logger.info("Zone subscription \(subscriptionID) already exists for zone \(zoneID.zoneName)")
                } else {
                    Self.logger.warning("Zone subscription exists but for wrong zone, recreating")
                    _ = try? await database.deleteSubscription(withID: subscriptionID)
                    needsCreation = true
                }
            } else {
                // Wrong subscription type - delete and recreate
                Self.logger.info("Found non-zone subscription \(subscriptionID), recreating as CKRecordZoneSubscription")
                _ = try? await database.deleteSubscription(withID: subscriptionID)
                needsCreation = true
            }
        } catch let error as CKError where error.code == .unknownItem {
            Self.logger.debug("Subscription \(subscriptionID) not found, will create")
            needsCreation = true
        } catch {
            Self.logger.warning("Error checking subscription: \(error.localizedDescription)")
            needsCreation = true
        }

        if needsCreation {
            let subscription = CKRecordZoneSubscription(
                zoneID: zoneID,
                subscriptionID: subscriptionID
            )

            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            notificationInfo.shouldBadge = false
            subscription.notificationInfo = notificationInfo

            _ = try await database.save(subscription)
            Self.logger.info("Created zone subscription: \(subscriptionID) for zone: \(zoneID.zoneName)")
        }

        // Clean up legacy per-record-type query subscriptions (default zone)
        let legacyIDs = [
            "\(SSHConnectionHistoryEntry.recordType.lowercased())-changes",
            "\(KnownHost.recordType.lowercased())-changes"
        ]
        for legacyID in legacyIDs {
            do {
                try await database.deleteSubscription(withID: legacyID)
                Self.logger.debug("Cleaned up legacy subscription: \(legacyID)")
            } catch {
                // Ignore - may not exist
            }
        }
    }

    /// Remove CloudKit subscriptions
    private func removeSubscriptions() async throws {
        let subscriptionIDs = [
            "ghostty-sync-zone-changes",
            "\(SSHConnectionHistoryEntry.recordType.lowercased())-changes",
            "\(KnownHost.recordType.lowercased())-changes"
        ]

        for subscriptionID in subscriptionIDs {
            do {
                try await database.deleteSubscription(withID: subscriptionID)
                Self.logger.info("Removed subscription: \(subscriptionID)")
            } catch {
                Self.logger.warning("Failed to remove subscription \(subscriptionID): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Settings & State

    /// Track record types that need initial push (added after sync was enabled)
    @ObservationIgnored
    private var pendingInitialPushTypes: Set<String> = []

    private func loadSettings() {
        isSyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.enabledKey)
        isHistorySyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncHistoryKey)
        isKnownHostsSyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncKnownHostsKey)
        lastSyncDate = UserDefaults.standard.object(forKey: CloudKitSyncSettings.lastSyncDateKey) as? Date

        // Handle profiles sync - detect if sync is enabled but profiles flag was never set
        // This happens when profiles sync was added after the user already enabled sync
        let profilesKeyValue = UserDefaults.standard.object(forKey: CloudKitSyncSettings.syncProfilesKey)

        if isSyncEnabled {
            if profilesKeyValue == nil {
                // Profiles sync key doesn't exist - this is a new record type
                // Auto-enable and mark for initial push
                Self.logger.info("Profiles sync not configured but sync enabled - auto-enabling and scheduling push")
                isProfilesSyncEnabled = true
                UserDefaults.standard.set(true, forKey: CloudKitSyncSettings.syncProfilesKey)
                pendingInitialPushTypes.insert(ConnectionProfile.recordType)
            } else {
                isProfilesSyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncProfilesKey)
            }
        } else {
            isProfilesSyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncProfilesKey)
        }

        // Plain read: settings sync is opt-in and never joins the auto-enable path above.
        isAppSettingsSyncEnabled = isSyncEnabled && UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncAppSettingsKey)

        syncState = isSyncEnabled ? .idle : .disabled
    }

    private func saveSettings() {
        UserDefaults.standard.set(isSyncEnabled, forKey: CloudKitSyncSettings.enabledKey)
        UserDefaults.standard.set(isHistorySyncEnabled, forKey: CloudKitSyncSettings.syncHistoryKey)
        UserDefaults.standard.set(isKnownHostsSyncEnabled, forKey: CloudKitSyncSettings.syncKnownHostsKey)
        UserDefaults.standard.set(isProfilesSyncEnabled, forKey: CloudKitSyncSettings.syncProfilesKey)
        UserDefaults.standard.set(isAppSettingsSyncEnabled, forKey: CloudKitSyncSettings.syncAppSettingsKey)
    }

    private func loadChangeToken() {
        if let tokenData = UserDefaults.standard.data(forKey: CloudKitSyncSettings.changeTokenKey) {
            zoneChangeToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: tokenData
            )
        }
    }

    private func saveChangeToken() {
        if let token = zoneChangeToken {
            let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: CloudKitSyncSettings.changeTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CloudKitSyncSettings.changeTokenKey)
        }
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard !Ghostty.isAppBackgroundedAtomic,
                  !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
            Task { @MainActor in
                guard !Ghostty.isAppBackgroundedAtomic,
                      !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
                let wasAvailable = self?.isNetworkAvailable ?? false
                self?.isNetworkAvailable = path.status == .satisfied

                // If network became available, flush offline queue
                if !wasAvailable && self?.isNetworkAvailable == true {
                    Self.logger.info("Network restored, flushing offline queue")
                    try? await self?.pushPendingChanges()
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    func pauseNetworkMonitoringForBackground() {
        guard pathMonitor != nil else { return }
        LifecycleDebugLogger.shared.checkpoint("CloudKit.pathMonitor.pause")
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func resumeNetworkMonitoringAfterForeground() {
        guard pathMonitor == nil else { return }
        LifecycleDebugLogger.shared.checkpoint("CloudKit.pathMonitor.resume")
        startNetworkMonitoring()
    }
}
