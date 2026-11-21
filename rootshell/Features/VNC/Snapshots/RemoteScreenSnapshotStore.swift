//
//  RemoteScreenSnapshotStore.swift
//  rootshell
//
//  The last screen seen on each saved Screen Sharing and KVM profile, kept
//  on this device only. One AES-256-GCM file per profile; the key lives in
//  the Keychain (device-only) and is destroyed when the feature is turned
//  off, so any file remnant is unreadable.
//

import CoreGraphics
import CryptoKit
import Foundation
import Observation
import os

/// A decoded snapshot ready to draw.
nonisolated struct RemoteScreenSnapshot: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
}

@MainActor
@Observable
final class RemoteScreenSnapshotStore {
    static let shared = RemoteScreenSnapshotStore()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RemoteScreenSnapshots")
    private nonisolated static let fileExtension = "rsnap"

    /// When each profile's snapshot was taken. Lists observe this to show
    /// and refresh thumbnails.
    private(set) var capturedAt: [UUID: Date] = [:]

    @ObservationIgnored private var cachedKey: SymmetricKey?
    /// Writes and deletes run in order, so an older save can't land after a
    /// newer one or bring a deleted snapshot back.
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    /// One decoded list thumbnail per profile, dropped with its snapshot.
    @ObservationIgnored private var thumbnails: [UUID: CachedThumbnail] = [:]
    /// Open panes, told to let go of pictures that were deleted here.
    @ObservationIgnored private let recorders = NSHashTable<RemoteScreenSnapshotRecorder>.weakObjects()
    /// How often each profile's screen, and all of them, were deleted. A
    /// capture reads this when it starts and is dropped if it moved.
    @ObservationIgnored private var removalCounts: [UUID: Int] = [:]
    @ObservationIgnored private var removeAllCount = 0

    nonisolated struct Removals: Equatable, Sendable {
        fileprivate let profile: Int
        fileprivate let all: Int
    }

    /// Valid for one snapshot of one computer at one size, nothing else.
    private struct CachedThumbnail {
        let endpoint: String
        let maxPixelDimension: Int
        let stamp: Date
        let snapshot: RemoteScreenSnapshot
    }

    private init() {
        // A screen whose file outlived its deletion stays forgotten: out of
        // the index, and deleted again now.
        let undeleted = Self.pendingDeletions()
        capturedAt = Self.scanDirectory().filter { !undeleted.contains($0.key) }
        if !undeleted.isEmpty {
            enqueue {
                for profileID in undeleted { Self.deleteFile(for: profileID) }
            }
        }
        if !isEnabled, !capturedAt.isEmpty { removeAll() }

        // Turning the setting off anywhere (here, sync, config) deletes them.
        let settingName = Settings.ScreenSharing.rememberLastScreen.name
        Task { [weak self] in
            for await change in SettingsStore.shared.changes() where change.contains(settingName) {
                guard let self else { return }
                if !self.isEnabled { self.removeAll() }
            }
        }
    }

    var isEnabled: Bool {
        SettingsStore.shared.value(Settings.ScreenSharing.rememberLastScreen)
    }

    func register(_ recorder: RemoteScreenSnapshotRecorder) {
        recorders.add(recorder)
    }

    // MARK: Save

    func removals(of profileID: UUID) -> Removals {
        Removals(profile: removalCounts[profileID, default: 0], all: removeAllCount)
    }

    /// `jpeg` is already scaled and encoded; this seals and writes it.
    /// `removals` is what `removals(of:)` returned when the frame was
    /// taken: a screen forgotten since then stays forgotten.
    func save(
        jpeg: Data,
        profileID: UUID,
        endpoint: String,
        capturedAt date: Date,
        ifRemovalsAre removals: Removals
    ) {
        guard isEnabled, removals == self.removals(of: profileID), let key = key() else { return }
        // Captures render concurrently; a slow older one must not win.
        if let existing = capturedAt[profileID], existing > date { return }
        let record = RemoteScreenSnapshotRecord(endpoint: endpoint, capturedAt: date, jpeg: jpeg)
        let url = Self.fileURL(for: profileID)
        capturedAt[profileID] = date
        thumbnails[profileID] = nil
        enqueue {
            do {
                let sealed = try RemoteScreenSnapshotCodec.seal(record, profileID: profileID, using: key)
                try Self.prepareDirectory()
                try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                // The new file replaced whatever was waiting to be deleted.
                Self.setDeletionPending(false, for: profileID)
            } catch {
                Self.logger.error("Snapshot save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Load

    /// The saved screen of the computer at `endpoint`, or nil.
    ///
    /// A snapshot of another computer is deleted only when
    /// `profileStillPointsAtEndpoint` says, after the read, that `endpoint`
    /// is where the profile points: the profile can change back while the
    /// file is being read, and the file is then the right one. A cancelled
    /// load deletes nothing. A pane asking for its own session's route
    /// passes nil: its route can be older than the profile.
    func load(
        profileID: UUID,
        endpoint: String,
        deletingOtherEndpointIf profileStillPointsAtEndpoint: (@MainActor () -> Bool)? = nil,
        maxPixelDimension: Int? = nil
    ) async -> RemoteScreenSnapshot? {
        guard isEnabled, let stamp = capturedAt[profileID] else { return nil }
        if let maxPixelDimension, let cached = thumbnails[profileID],
           cached.endpoint == endpoint, cached.maxPixelDimension == maxPixelDimension, cached.stamp == stamp {
            return cached.snapshot
        }
        guard let key = key() else { return nil }
        let url = Self.fileURL(for: profileID)
        // Behind any pending write, so a just-saved snapshot is the one read.
        await mutationTask?.value

        let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
            // A file still waiting to be deleted was forgotten: never read.
            guard !Self.pendingDeletions().contains(profileID) else { return .missing }
            let sealed: Data
            do {
                sealed = try Data(contentsOf: url)
            } catch {
                // Only a file that is really gone leaves the index. One
                // that can't be read right now (a locked device, an I/O
                // error) is still there to show later, or to delete.
                guard Self.isMissingFile(error) else {
                    Self.logger.error("Snapshot read failed: \(error.localizedDescription, privacy: .public)")
                    return .unavailable
                }
                return .missing
            }
            guard let record = try? RemoteScreenSnapshotCodec.open(sealed, profileID: profileID, using: key) else {
                return .unreadable
            }
            guard record.endpoint == endpoint else { return .otherEndpoint }
            guard let image = RemoteScreenSnapshotCodec.decodeImage(
                record.jpeg, maxPixelDimension: maxPixelDimension) else { return .unreadable }
            return .loaded(RemoteScreenSnapshot(image: image, capturedAt: record.capturedAt))
        }.value

        // Deleted, replaced or turned off while this was reading.
        guard isEnabled, capturedAt[profileID] == stamp else { return nil }
        switch outcome {
        case .loaded(let snapshot):
            if let maxPixelDimension {
                if thumbnails.count >= 128 { thumbnails.removeAll() }
                thumbnails[profileID] = CachedThumbnail(
                    endpoint: endpoint, maxPixelDimension: maxPixelDimension, stamp: stamp, snapshot: snapshot)
            }
            return snapshot
        case .missing:
            capturedAt[profileID] = nil
            return nil
        case .unavailable:
            return nil
        case .otherEndpoint:
            if !Task.isCancelled, let profileStillPointsAtEndpoint, profileStillPointsAtEndpoint() {
                remove(profileID: profileID)
            }
            return nil
        case .unreadable:
            // A lost key or a damaged file: nothing can use it.
            remove(profileID: profileID)
            return nil
        }
    }

    private nonisolated enum LoadOutcome: Sendable {
        case loaded(RemoteScreenSnapshot)
        case missing
        case unavailable
        case otherEndpoint
        case unreadable
    }

    // MARK: Remove

    /// Deletes a profile's saved screen, on disk and in any open pane.
    func remove(profileID: UUID) {
        removalCounts[profileID, default: 0] += 1
        thumbnails[profileID] = nil
        for recorder in recorders.allObjects where recorder.profileID == profileID {
            recorder.forget()
        }
        capturedAt[profileID] = nil
        // Whatever the index says: it can lag the disk.
        enqueue {
            Self.deleteFile(for: profileID)
        }
    }

    /// Deletes the screens of profiles `keeps` turns down: ones that were
    /// deleted or stopped being remote screens, here or on another device.
    /// Covers open panes too, which can hold a picture with no file yet.
    func prune(keeping keeps: (UUID) -> Bool) {
        let held = Set(capturedAt.keys).union(recorders.allObjects.compactMap { $0.profileID })
        for profileID in held where !keeps(profileID) {
            remove(profileID: profileID)
        }
    }

    /// Deletes every snapshot, what open panes hold, and this app's key.
    func removeAll() {
        removeAllCount += 1
        capturedAt.removeAll()
        thumbnails.removeAll()
        for recorder in recorders.allObjects {
            recorder.forget()
        }
        enqueue {
            for url in Self.snapshotFiles() {
                if let profileID = Self.profileID(of: url) {
                    Self.deleteFile(for: profileID)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        cachedKey = nil
        do {
            try KeychainManager.shared.deleteRemoteScreenSnapshotKey()
        } catch {
            Self.logger.error("Snapshot key delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Internals

    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let previous = mutationTask
        mutationTask = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }

    private func key() -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        let data: Data
        do {
            data = try KeychainManager.shared.loadRemoteScreenSnapshotKey()
        } catch KeychainManager.KeychainError.itemNotFound {
            // Only a key that is really absent is made. Any other failure
            // (a locked device, a Keychain hiccup) may be hiding the key
            // every saved screen needs, so this time there is no key.
            let fresh = SymmetricKey(size: .bits256)
            do {
                data = try KeychainManager.shared.addRemoteScreenSnapshotKey(fresh.withUnsafeBytes { Data($0) })
            } catch {
                Self.logger.error("Snapshot key save failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } catch {
            Self.logger.error("Snapshot key unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteScreenSnapshots", isDirectory: true)
    }

    private nonisolated static func fileURL(for profileID: UUID) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).\(fileExtension)")
    }

    /// The screens stay on this device: no iCloud or Finder backup. Checked
    /// before every write, and a write that can't have it doesn't happen:
    /// the directory can exist without the flag if setting it once failed.
    private nonisolated static func prepareDirectory() throws {
        var url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let excluded = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        guard excluded != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Deletes a profile's file. One that is already gone is deleted; any
    /// other failure is remembered, so the screen stays forgotten and the
    /// file is deleted at the next launch. Runs on the mutation chain.
    private nonisolated static func deleteFile(for profileID: UUID) {
        do {
            try FileManager.default.removeItem(at: fileURL(for: profileID))
        } catch {
            guard isMissingFile(error) else {
                logger.error("Snapshot delete failed: \(error.localizedDescription, privacy: .public)")
                setDeletionPending(true, for: profileID)
                return
            }
        }
        setDeletionPending(false, for: profileID)
    }

    private nonisolated static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT)
        default:
            return false
        }
    }

    /// Profiles whose file survived a deletion. Kept in defaults, which a
    /// directory that refuses deletes can't take down with it.
    private nonisolated static func pendingDeletions() -> Set<UUID> {
        let stored = UserDefaults.standard.stringArray(
            forKey: Settings.ScreenSharing.snapshotPendingDeletions.name) ?? []
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }

    private nonisolated static func setDeletionPending(_ pending: Bool, for profileID: UUID) {
        var profileIDs = pendingDeletions()
        let changed = pending
            ? profileIDs.insert(profileID).inserted
            : profileIDs.remove(profileID) != nil
        guard changed else { return }
        let key = Settings.ScreenSharing.snapshotPendingDeletions.name
        if profileIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(profileIDs.map(\.uuidString).sorted(), forKey: key)
        }
    }

    private nonisolated static func profileID(of url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private nonisolated static func snapshotFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents.filter { $0.pathExtension == fileExtension }
    }

    private nonisolated static func scanDirectory() -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for url in snapshotFiles() {
            guard let id = profileID(of: url) else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            result[id] = modified ?? .distantPast
        }
        return result
    }
}
