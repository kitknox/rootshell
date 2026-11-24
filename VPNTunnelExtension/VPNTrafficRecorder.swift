//
//  VPNTrafficRecorder.swift
//  VPNTunnelExtension
//
//  Lightweight recorder that samples Go byte counters on a timer
//  and maintains a rolling 5-minute time series for the main app's
//  traffic chart. Thread-safe via NSLock.
//

import Foundation
@preconcurrency import TsshKit

nonisolated final class VPNTrafficRecorder: @unchecked Sendable {
    private struct Snapshot {
        let timestamp: Double  // Unix timestamp
        let bytesIn: Int64
        let bytesOut: Int64
    }

    private let lock = NSLock()
    private var snapshots: [Snapshot] = []
    private var timer: DispatchSourceTimer?

    private static let sampleInterval: TimeInterval = 2
    private static let maxAge: TimeInterval = 300  // 5 minutes

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(
            deadline: .now() + Self.sampleInterval,
            repeating: Self.sampleInterval
        )
        source.setEventHandler { [weak self] in
            self?.recordSample()
        }
        timer = source
        source.resume()

        // Record an initial sample immediately
        recordSampleLocked()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Returns compact array-of-arrays for JSON: [[unixTimestamp, bytesIn, bytesOut], ...]
    func snapshotsForJSON() -> [[Any]] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.map { [$0.timestamp, $0.bytesIn, $0.bytesOut] as [Any] }
    }

    // MARK: - Private

    private func recordSample() {
        lock.lock()
        recordSampleLocked()
        lock.unlock()
    }

    /// Must be called with `lock` held.
    private func recordSampleLocked() {
        let statusJSON = VpntunnelGetStatus()
        guard let data = statusJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let bytesIn = (raw["bytesIn"] as? NSNumber)?.int64Value ?? 0
        let bytesOut = (raw["bytesOut"] as? NSNumber)?.int64Value ?? 0
        let now = Date().timeIntervalSince1970

        snapshots.append(Snapshot(timestamp: now, bytesIn: bytesIn, bytesOut: bytesOut))

        // Trim entries older than 5 minutes
        let cutoff = now - Self.maxAge
        snapshots.removeAll { $0.timestamp < cutoff }
    }
}
