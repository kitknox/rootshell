//
//  FileTransferCenter.swift
//  rootshell
//
//  App-wide transfer queue. Jobs outlive the file manager UI and are shared
//  by every window; a few run at once and each can be cancelled on its own.
//

import Foundation
import UIKit
import os.log

@MainActor
@Observable
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private static let logger = Logger(subsystem: "com.rootshell", category: "FileManagerTransfers")

    /// A conflict waiting for the user; answered with `resolveConflict`.
    struct ConflictQuestion: Identifiable {
        let id = UUID()
        let job: TransferJob
        let name: String
        let destinationDirectory: String
        let isDirectory: Bool
    }

    private(set) var jobs: [TransferJob] = []
    private(set) var pendingConflict: ConflictQuestion?

    @ObservationIgnored private var prompts: [UUID: FileManagerPrompts] = [:]
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<(TransferConflictResolution, Bool)?, Never>?
    @ObservationIgnored private var finishedObservers: [UUID: AsyncStream<TransferJob>.Continuation] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var heldClaims: [UUID: TransferPathClaim] = [:]

    private init() {}

    // MARK: - Queue

    var activeJobs: [TransferJob] { jobs.filter { !$0.state.isFinished } }
    var hasActiveJobs: Bool { jobs.contains { !$0.state.isFinished } }

    /// Aggregate progress over unfinished jobs: bytes where known, else items.
    var aggregateFraction: Double? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0.addingSaturating($1.totalBytes) }
        if total > 0 {
            return min(1, Double(active.reduce(Int64(0)) { $0.addingSaturating($1.completedBytes) }) / Double(total))
        }
        let items = active.reduce(0) { $0 + $1.totalItems }
        guard items > 0 else { return nil }
        return Double(active.reduce(0) { $0 + $1.completedItems }) / Double(items)
    }

    var aggregateBytesPerSecond: Double {
        activeJobs.reduce(0) { $0 + $1.bytesPerSecond }
    }

    var aggregateSecondsRemaining: TimeInterval? {
        activeJobs.compactMap(\.secondsRemaining).max()
    }

    func enqueue(_ job: TransferJob, prompts: FileManagerPrompts) {
        self.prompts[job.id] = prompts
        jobs.append(job)
        startQueuedJobs()
    }

    func cancel(_ job: TransferJob) {
        if job.state == .queued {
            job.setState(.cancelled)
            finish(job)
            return
        }
        if pendingConflict?.job === job { answerConflict(nil) }
        job.task?.cancel()
    }

    func cancelAll() {
        for job in activeJobs { cancel(job) }
    }

    /// Runs the same operation again as a new job.
    func retry(_ job: TransferJob) {
        guard job.state.isFinished, let prompts = prompts[job.id] ?? prompts.values.first else { return }
        let again = TransferJob(
            operation: job.operation,
            source: job.source,
            sourcePaths: job.sourcePaths,
            destination: job.destination,
            destinationDirectory: job.destinationDirectory,
            conflictPolicy: job.conflictPolicy
        )
        remove(job)
        enqueue(again, prompts: prompts)
    }

    func remove(_ job: TransferJob) {
        guard job.state.isFinished else { return }
        jobs.removeAll { $0 === job }
        prompts[job.id] = nil
    }

    func clearFinished() {
        for job in jobs where job.state.isFinished { prompts[job.id] = nil }
        jobs.removeAll { $0.state.isFinished }
    }

    /// Each finished job, for panes that need to refresh.
    func finishedJobs() -> AsyncStream<TransferJob> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TransferJob>.makeStream(bufferingPolicy: .bufferingNewest(16))
        finishedObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishedObservers[id] = nil }
        }
        return stream
    }

    // MARK: - Conflicts

    func resolveConflict(_ resolution: TransferConflictResolution, applyToAll: Bool) {
        answerConflict((resolution, applyToAll))
    }

    func cancelConflict() {
        guard let job = pendingConflict?.job else { return }
        cancel(job)
    }

    private func answerConflict(_ answer: (TransferConflictResolution, Bool)?) {
        let continuation = conflictContinuation
        conflictContinuation = nil
        pendingConflict = nil
        continuation?.resume(returning: answer)
    }

    fileprivate func askConflict(_ question: ConflictQuestion) async -> (TransferConflictResolution, Bool)? {
        // One question on screen at a time across all jobs.
        while conflictContinuation != nil {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingConflict = question
        }
    }

    // MARK: - Scheduling

    /// Starts queued jobs up to the limit. A job whose paths overlap a running job's
    /// writes waits, so it plans against the finished result and its conflicts are
    /// asked about instead of two jobs truncating the same file.
    private func startQueuedJobs() {
        let limit = max(1, SettingsStore.shared.value(Settings.Transfer.fileManagerConcurrentJobs))
        var active = jobs.filter(\.isActive)
        for job in jobs where job.state == .queued && active.count < limit {
            guard !active.contains(where: { Self.jobsConflict($0, job) }) else { continue }
            active.append(job)
            job.setState(.preparing)
            let prompts = prompts[job.id] ?? FileManagerPrompts()
            job.task = Task { [weak self] in
                await TransferExecutor(job: job, prompts: prompts, center: self).run()
                self?.finish(job)
            }
        }
        updateBackgroundTask()
    }

    /// Cheap pre-check on the paths as written; `acquirePaths` then repeats it on
    /// real paths, which also catches symlinked aliases.
    private static func jobsConflict(_ a: TransferJob, _ b: TransferJob) -> Bool {
        TransferPathClaim(job: a).conflicts(with: TransferPathClaim(job: b))
    }

    // MARK: - Path locks

    /// Waits until no other running job holds an overlapping claim, then holds
    /// `claim` until the job finishes. Claims are on real paths, so two routes to
    /// one folder (an alias and its target) still serialize.
    fileprivate func acquirePaths(_ claim: TransferPathClaim, for job: TransferJob) async throws {
        while heldClaims.contains(where: { id, held in id != job.id && held.conflicts(with: claim) }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        heldClaims[job.id] = claim
    }

    private func finish(_ job: TransferJob) {
        job.task = nil
        heldClaims[job.id] = nil
        for observer in finishedObservers.values { observer.yield(job) }
        Self.logger.info("Transfer \(job.id, privacy: .public) finished: \(String(describing: job.state), privacy: .public)")
        startQueuedJobs()
        if !hasActiveJobs { MallocPressureRelief.request() }
    }

    /// Keeps iOS from suspending the app mid-transfer while it is backgrounded.
    private func updateBackgroundTask() {
        if hasActiveJobs, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "File transfers") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        } else if !hasActiveJobs, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

// MARK: - Path claims

/// The paths a job reads and writes. Two jobs conflict when one writes where the
/// other reads or writes, on the same filesystem, including beneath a folder.
fileprivate struct TransferPathClaim {
    struct Root {
        let endpoint: FileEndpoint
        let path: String
    }

    let writes: [Root]
    let reads: [Root]

    /// From the paths as the user chose them.
    init(job: TransferJob) {
        self.init(job: job, destinationDirectory: job.destinationDirectory, sources: job.sourcePaths)
    }

    /// Moves, deletes and permission changes also write their sources.
    init(job: TransferJob, destinationDirectory: String?, sources: [String]) {
        let sourceRoots = sources.map { Root(endpoint: job.source, path: $0) }
        var writes: [Root] = []
        if let destination = job.destination, let destinationDirectory {
            writes.append(Root(endpoint: destination, path: destinationDirectory))
        }
        if job.operation != .copy { writes += sourceRoots }
        self.writes = writes
        reads = sourceRoots
    }

    func conflicts(with other: TransferPathClaim) -> Bool {
        Self.overlaps(writes, other.writes + other.reads) || Self.overlaps(other.writes, writes + reads)
    }

    /// Paths only compare within a proven namespace; across an unproven one
    /// (root beside another account) any write conflicts, whatever the spelling.
    private static func overlaps(_ writes: [Root], _ touched: [Root]) -> Bool {
        writes.contains { write in
            touched.contains { other in
                if write.endpoint.sharesFileSystem(with: other.endpoint) {
                    return FileTransferLogic.pathsOverlap(write.path, other.path)
                }
                return write.endpoint.mayShareFiles(with: other.endpoint)
            }
        }
    }
}

// MARK: - Execution

/// Runs one job to completion. Items copy through FileTreeCopier's worker pool;
/// large files still overlap their chunks through PipelinedTransfer.
@MainActor
private struct TransferExecutor {
    let job: TransferJob
    let prompts: FileManagerPrompts
    weak var center: FileTransferCenter?

    /// One selected item and everything beneath it.
    private struct Root {
        let source: String
        let destination: String
        var replaceExisting: Bool
        var items: [FileTreeCopier.Item]
        /// Same-endpoint move satisfied by a rename.
        var renamed = false
        /// Resolved paths, for spotting one root reading where another writes.
        var realSources: [String] = []
        var realDestination = ""
    }

    private var pool: FileConnectionPool { .shared }

    func run() async {
        let endpoints = [job.source] + (job.destination.map { [$0] } ?? [])
        endpoints.forEach(pool.retain)
        defer { endpoints.forEach(pool.release) }

        do {
            let sourceFS = try await pool.fileSystem(for: job.source, purpose: .transfer, prompts: prompts)
            let sources = await realSources(on: sourceFS)
            let sourceClaims = sources.values.flatMap { [$0.location, $0.followed] }
            switch job.operation {
            case .delete:
                try await center?.acquirePaths(TransferPathClaim(job: job, destinationDirectory: nil, sources: sourceClaims), for: job)
                try await runPerPath(sourceFS) { try await sourceFS.removeRecursively($0) }
            case .setPermissions(let mode):
                try await center?.acquirePaths(TransferPathClaim(job: job, destinationDirectory: nil, sources: sourceClaims), for: job)
                try await runPerPath(sourceFS) { try await sourceFS.setPermissions($0, mode: mode) }
            case .copy, .move:
                guard let destination = job.destination, let directory = job.destinationDirectory else { return }
                let destinationFS = try await pool.fileSystem(for: destination, purpose: .transfer, prompts: prompts)
                let realDirectory = (try? await destinationFS.realPath(directory)) ?? directory
                // Plan only once no other job can write here: an existence check made
                // before this point could be stale by the time we open the file.
                try await center?.acquirePaths(
                    TransferPathClaim(job: job, destinationDirectory: realDirectory, sources: sourceClaims), for: job
                )
                try await runCopy(from: sourceFS, to: destinationFS, directory: directory, realDirectory: realDirectory, sources: sources)
            }
            try Task.checkCancellation()
            job.setState(job.errors.isEmpty ? .completed : .failed(failureSummary))
        } catch is CancellationError {
            job.setState(.cancelled)
        } catch FileManagerConnectionError.cancelled {
            job.setState(.cancelled)
        } catch {
            job.setState(.failed(error.localizedDescription))
        }
    }

    /// Where each selected path really lives.
    private struct RealSource {
        /// The item's own location; for a link, where the link sits.
        let location: String
        /// Fully dereferenced; what a copy of a link actually reads.
        let followed: String
    }

    private func realSources(on fs: FileSystemEndpoint) async -> [String: RealSource] {
        var result: [String: RealSource] = [:]
        for path in job.sourcePaths {
            let location = (try? await fs.realLocation(of: path)) ?? path
            let followed = (try? await fs.realPath(path)) ?? location
            result[path] = RealSource(location: location, followed: followed)
        }
        return result
    }

    private var failureSummary: String {
        job.errors.count == 1
            ? job.errors[0].message
            : String(localized: "\(job.errors.count) items failed", comment: "File transfer: several items in a job failed")
    }

    private func runPerPath(_ fs: FileSystemEndpoint, _ body: (String) async throws -> Void) async throws {
        job.setTotals(bytes: 0, items: job.sourcePaths.count)
        job.setState(.running)
        for path in job.sourcePaths {
            try Task.checkCancellation()
            job.beginItem(path)
            do {
                try await body(path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                job.recordError(path: path, message: error.localizedDescription)
            }
            job.finishItem()
        }
    }

    // MARK: - Copy and move

    /// `realDirectory` and `sources` are resolved real paths: same-file and ancestor
    /// checks use them, so neither a symlinked folder in a pane's path nor a selected
    /// symlink can disguise the source. Both the link and its target count.
    private func runCopy(
        from sourceFS: FileSystemEndpoint, to destinationFS: FileSystemEndpoint,
        directory: String, realDirectory: String, sources: [String: RealSource]
    ) async throws {
        // Identity, not enum equality: a borrowed pane and its profile are one filesystem.
        // Proven sameness permits the rename and skip shortcuts; possible overlap
        // (root beside another account) is enough to trigger the guards.
        let sameFileSystem = job.destination.map(job.source.sharesFileSystem) == true
        let mayOverlap = job.destination.map(job.source.mayShareFiles) == true
        // Paths can't be compared across unproven namespaces (root beside a
        // chrooted account), so nothing may delete or overwrite: copies only.
        let unverifiedOverlap = mayOverlap && !sameFileSystem
        if unverifiedOverlap, job.operation == .move {
            for path in job.sourcePaths {
                job.recordError(path: path, message: String(localized: "Can't move between root and another account on the same server. Copy instead.", comment: "File transfer error"))
            }
            return
        }
        var namesOnDisk: Set<String>?
        var names = TransferNamePlanner(incomingNames: job.sourcePaths.map(FileTransferLogic.lastComponent))
        var roots: [Root] = []

        for path in job.sourcePaths {
            try Task.checkCancellation()
            let name = FileTransferLogic.lastComponent(of: path)
            var target = FileTransferLogic.join(directory, name)
            let real = sources[path] ?? RealSource(location: path, followed: path)
            let realTarget = FileTransferLogic.join(realDirectory, name)
            let realSourcePaths = [real.location, real.followed]
            // The destination is the item itself, or what a selected link points at.
            let targetIsSource = mayOverlap && realSourcePaths.contains(realTarget)

            if sameFileSystem, job.operation == .move, real.location == realTarget { continue }
            if mayOverlap {
                if realSourcePaths.contains(where: { FileTransferLogic.isSameOrDescendant(realDirectory, of: $0) }),
                   (try? await sourceFS.info(path))?.isDirectory == true {
                    job.recordError(path: path, message: String(localized: "A folder can't be copied into itself.", comment: "File transfer error"))
                    continue
                }
            }

            var replace = false
            if targetIsSource || names.isClaimed(name) {
                // Duplicating in place, or a second item with the same name: keep both.
                target = try await keepBothTarget(name, in: directory, fs: destinationFS, onDisk: &namesOnDisk, names: &names)
            } else if await destinationFS.exists(target) {
                let sourceIsDirectory = (try? await sourceFS.info(path))?.isDirectory ?? false
                let targetIsDirectory = (try? await destinationFS.info(target, followLinks: false))?.isDirectory ?? false
                guard let resolution = try await resolveConflict(name: name, directory: directory, isDirectory: sourceIsDirectory && targetIsDirectory) else {
                    continue
                }
                switch resolution {
                case .skip:
                    continue
                case .keepBoth:
                    target = try await keepBothTarget(name, in: directory, fs: destinationFS, onDisk: &namesOnDisk, names: &names)
                case .replace, .merge:
                    if unverifiedOverlap {
                        job.recordError(path: path, message: String(localized: "“\(name)” may be the same item under another path, so it can't be replaced. Choose Keep Both.", comment: "File transfer error; argument is a file name"))
                        continue
                    }
                    // Clearing a destination that is, or contains, the source would delete the source.
                    if mayOverlap, realSourcePaths.contains(where: { FileTransferLogic.isSameOrDescendant($0, of: realTarget) }) {
                        job.recordError(path: path, message: String(localized: "“\(name)” can't replace a folder that contains it.", comment: "File transfer error; argument is a file name"))
                        continue
                    }
                    replace = resolution == .replace || !(sourceIsDirectory && targetIsDirectory)
                    names.claim(name)
                }
            } else {
                names.claim(name)
            }

            if sameFileSystem, job.operation == .move {
                do {
                    if replace { try await destinationFS.removeRecursively(target) }
                    try await sourceFS.rename(path, to: target)
                    roots.append(Root(source: path, destination: target, replaceExisting: false, items: [], renamed: true))
                    continue
                } catch {
                    // Cross-device or unsupported rename: fall through to copy + delete.
                }
            }

            let items = try await FileTreeCopier.expand(path, into: target, fs: sourceFS)
            roots.append(Root(
                source: path, destination: target, replaceExisting: replace, items: items,
                realSources: realSourcePaths,
                realDestination: FileTransferLogic.join(realDirectory, FileTransferLogic.lastComponent(of: target))
            ))
        }

        let allItems = roots.flatMap(\.items)
        job.setTotals(
            bytes: allItems.reduce(Int64(0)) { $0.addingSaturating($1.isFile ? $1.size : 0) },
            items: allItems.count + roots.filter(\.renamed).count
        )
        job.setState(.running)
        let preserve = SettingsStore.shared.value(Settings.Transfer.fileManagerPreserveAttributes)

        var pending: [Root] = []
        for root in roots {
            if root.renamed { job.finishItem() } else { pending.append(root) }
        }
        // A root reading where another writes (say, a selected link into the destination)
        // must not see that folder cleared or half-written, so those run one root at a time.
        let entangled = mayOverlap && pending.indices.contains { reader in
            pending.indices.contains { writer in
                reader != writer && pending[reader].realSources.contains {
                    FileTransferLogic.pathsOverlap($0, pending[writer].realDestination)
                }
            }
        }
        let batches = entangled ? pending.map { [$0] } : [pending]
        for batch in batches {
            try await copyBatch(batch, from: sourceFS, to: destinationFS, preserve: preserve)
        }
    }

    /// Clears replaced destinations, copies every root's items through one worker
    /// pool, then deletes a move's sources.
    private func copyBatch(_ roots: [Root], from sourceFS: FileSystemEndpoint, to destinationFS: FileSystemEndpoint, preserve: Bool) async throws {
        var copying: [Root] = []
        for root in roots {
            try Task.checkCancellation()
            if root.replaceExisting {
                do {
                    try await destinationFS.removeRecursively(root.destination)
                } catch {
                    job.recordError(path: root.destination, message: error.localizedDescription)
                    continue
                }
            }
            copying.append(root)
        }

        // The batch's roots share one pool, so many loose files overlap too.
        let items = copying.flatMap(\.items)
        let errorsBefore = job.errors.count
        try await FileTreeCopier.copyItems(
            items, from: sourceFS, to: destinationFS, preserveAttributes: preserve,
            onStart: { job.beginItem($0.source) },
            onBytes: { delta in
                if delta >= 0 { job.addBytes(delta) } else { job.discardBytes(-delta) }
            },
            onFinish: { item, error in
                if let error { job.recordError(path: item.source, message: error.localizedDescription) }
                job.finishItem()
            }
        )
        if preserve { await FileTreeCopier.applyDirectoryModes(items, on: destinationFS) }

        // A move deletes a source only once everything beneath it copied.
        guard job.operation == .move else { return }
        let failed = job.errors[errorsBefore...].map(\.path)
        for root in copying where !failed.contains(where: { FileTransferLogic.isSameOrDescendant($0, of: root.source) }) {
            try Task.checkCancellation()
            do {
                try await sourceFS.removeRecursively(root.source)
            } catch {
                job.recordError(path: root.source, message: error.localizedDescription)
            }
        }
    }

    private func resolveConflict(name: String, directory: String, isDirectory: Bool) async throws -> TransferConflictResolution? {
        if let policy = job.conflictPolicy {
            return policy == .merge && !isDirectory ? .replace : policy
        }
        guard let center else { return .skip }
        let question = FileTransferCenter.ConflictQuestion(job: job, name: name, destinationDirectory: directory, isDirectory: isDirectory)
        guard let (resolution, applyToAll) = await center.askConflict(question) else {
            throw CancellationError()
        }
        if applyToAll { job.conflictPolicy = resolution }
        return resolution
    }

    private func keepBothTarget(
        _ name: String, in directory: String, fs: FileSystemEndpoint,
        onDisk: inout Set<String>?, names: inout TransferNamePlanner
    ) async throws -> String {
        if onDisk == nil { onDisk = Set(try await fs.list(directory).map(\.name)) }
        return FileTransferLogic.join(directory, names.claimKeepBothName(for: name, existingOnDisk: onDisk ?? []))
    }
}
