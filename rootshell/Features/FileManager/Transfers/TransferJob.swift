//
//  TransferJob.swift
//  rootshell
//
//  One queued file operation and its observable progress. Byte counts arrive
//  per chunk but are published at most ten times a second.
//

import Foundation

@MainActor
@Observable
final class TransferJob: Identifiable {
    enum Operation: Equatable {
        case copy
        case move
        case delete
        case setPermissions(UInt32)
    }

    enum State: Equatable {
        case queued
        case preparing
        case running
        case completed
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .queued, .preparing, .running: false
            }
        }
    }

    struct Source: Equatable, Sendable {
        let path: String
        /// Known row type from a listing; nil for raw paths (e.g. external drops/pastes).
        /// On S3 this disambiguates when both a file `foo` and folder `foo/` share a path.
        let isDirectory: Bool?

        init(path: String, isDirectory: Bool? = nil) {
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    struct ItemError: Identifiable {
        let id = UUID()
        let path: String
        let message: String
    }

    let id = UUID()
    let operation: Operation
    let source: FileEndpoint
    let sources: [Source]
    var sourcePaths: [String] { sources.map(\.path) }
    let destination: FileEndpoint?
    let destinationDirectory: String?
    let createdAt = Date()
    /// Resolution applied to every conflict; nil asks per item.
    var conflictPolicy: TransferConflictResolution?

    private(set) var state: State = .queued
    private(set) var totalBytes: Int64 = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var totalItems = 0
    private(set) var completedItems = 0
    private(set) var currentItem: String?
    private(set) var bytesPerSecond: Double = 0
    private(set) var secondsRemaining: TimeInterval?
    private(set) var errors: [ItemError] = []
    private(set) var finishedAt: Date?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var rawCompletedBytes: Int64 = 0
    @ObservationIgnored private var meter = TransferRateMeter()
    @ObservationIgnored private var throttle = PublishThrottle(interval: 0.1)

    init(
        operation: Operation,
        source: FileEndpoint,
        sources: [Source],
        destination: FileEndpoint? = nil,
        destinationDirectory: String? = nil,
        conflictPolicy: TransferConflictResolution? = nil
    ) {
        self.operation = operation
        self.source = source
        self.sources = sources
        self.destination = destination
        self.destinationDirectory = destinationDirectory
        self.conflictPolicy = conflictPolicy
    }

    convenience init(
        operation: Operation,
        source: FileEndpoint,
        sourcePaths: [String],
        destination: FileEndpoint? = nil,
        destinationDirectory: String? = nil,
        conflictPolicy: TransferConflictResolution? = nil
    ) {
        self.init(
            operation: operation,
            source: source,
            sources: sourcePaths.map { Source(path: $0) },
            destination: destination,
            destinationDirectory: destinationDirectory,
            conflictPolicy: conflictPolicy
        )
    }

    var fractionCompleted: Double? {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return Double(completedItems) / Double(totalItems) }
        return nil
    }

    var isActive: Bool { state == .preparing || state == .running }

    var title: String {
        let count = sourcePaths.count
        let subject = count == 1
            ? FileTransferLogic.lastComponent(of: sourcePaths[0])
            : String(localized: "\(count) items", comment: "File transfer: number of items in a job")
        switch operation {
        case .copy:
            return String(localized: "Copy \(subject)", comment: "File transfer job title; argument is a file name or item count")
        case .move:
            return String(localized: "Move \(subject)", comment: "File transfer job title; argument is a file name or item count")
        case .delete:
            return String(localized: "Delete \(subject)", comment: "File transfer job title; argument is a file name or item count")
        case .setPermissions:
            return String(localized: "Change permissions of \(subject)", comment: "File transfer job title; argument is a file name or item count")
        }
    }

    var routeDescription: String? {
        guard let destination, let destinationDirectory else { return source.displayName }
        return "\(source.displayName) → \(destination.displayName):\(destinationDirectory)"
    }

    // MARK: - Engine updates

    func setState(_ newState: State) {
        state = newState
        if newState.isFinished {
            finishedAt = Date()
            currentItem = nil
            publish(force: true)
            secondsRemaining = nil
        }
    }

    func setTotals(bytes: Int64, items: Int) {
        totalBytes = bytes
        totalItems = items
    }

    func beginItem(_ path: String) {
        currentItem = path
    }

    func finishItem() {
        completedItems += 1
        publish(force: false)
    }

    func addBytes(_ count: Int64) {
        rawCompletedBytes += count
        publish(force: false)
    }

    /// Rewinds bytes counted for an item that failed or was cancelled mid-copy.
    func discardBytes(_ count: Int64) {
        rawCompletedBytes = max(0, rawCompletedBytes - count)
        publish(force: true)
    }

    func recordError(path: String, message: String) {
        errors.append(ItemError(path: path, message: message))
    }

    private func publish(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard throttle.shouldPublish(at: now, force: force) else { return }
        // Sampling only at publish time keeps chunk bursts from skewing the rate.
        meter.record(totalBytes: rawCompletedBytes, at: now)
        completedBytes = rawCompletedBytes
        bytesPerSecond = meter.bytesPerSecond
        secondsRemaining = meter.eta(remainingBytes: totalBytes - rawCompletedBytes)
    }
}
