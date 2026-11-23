//
//  LifecycleDebugLogger.swift
//  rootshell
//
//  File-based debug logger for app lifecycle / scene transition diagnostics.
//  Companion to ResumeDebugLogger — same persistence pattern (serial queue,
//  synchronizeFile per write, 512KB rotation in Documents/.ghostty/) but
//  tuned for capturing the background → foreground path that triggers the
//  FrontBoard scene-update watchdog (0x8BADF00D) off-debugger.
//
//  See plan: ~/.claude/plans/implement-comprehensive-lifecycle-debug-kind-mist.md
//

import Foundation
import os

/// File-based debug logger that persists across force-quit cycles.
///
/// Writes to `Documents/.ghostty/lifecycle_debug.log` with immediate file sync
/// after each write so entries survive force-quit termination. Off by default;
/// enable via Debug Settings (`lifecycleDebugLoggingEnabled` in UserDefaults)
/// before a repro session.
///
/// Each `checkpoint(...)` call records a delta from the previously logged
/// event so a wedged session's tail entry tells us where (and how long after
/// the prior phase) the previous run got stuck.
final class LifecycleDebugLogger: Sendable {
    nonisolated static let shared = LifecycleDebugLogger()

    /// UserDefaults key to enable/disable logging
    nonisolated static let enabledKey = "lifecycleDebugLoggingEnabled"

    /// Max log file size before rotation (100MB).
    /// Lifecycle logging is opt-in and the goal is to capture rare wedges
    /// that may take many cycles to reproduce, so a generous ceiling matters
    /// more here than disk-space conservatism.
    nonisolated private static let maxFileSize: UInt64 = 100 * 1024 * 1024

    /// Tail bytes scanned on launch when looking for a wedge marker
    nonisolated private static let tailScanBytes: UInt64 = 4 * 1024

    /// Markers indicating a phase completed cleanly. If the previous session's
    /// last log line contains none of these, treat it as a wedge tombstone.
    nonisolated private static let cleanCompletionMarkers: [String] = [
        "BG.complete",
        "FG.complete",
        "APP.terminate",
    ]

    /// Serial queue for thread-safe file I/O
    private let ioQueue = DispatchQueue(label: "com.rootshell.lifecycleDebugLogger")

    private let ioQueueSpecificKey = DispatchSpecificKey<Bool>()

    /// Log file URL: Documents/.ghostty/lifecycle_debug.log
    private let logFileURL: URL

    /// Rotated log file URL
    private let rotatedLogFileURL: URL

    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter

    /// Wall-clock time of last logged event, for delta computation
    private let lastEventTime = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Per-gate suppressed-publish counters. Snapshot + reset at gate-open and
    /// at next BG entry.
    private let suppressionCounters = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    /// Count of `MainView.body` evaluations since last snapshot. Bumped at the
    /// top of body and snapshot-and-reset on each BG/FG lifecycle event so we
    /// can verify post-refactor that sustained network instability does not
    /// cause MainView body re-evaluations (the principled fix for the
    /// 0x8BADF00D scene-update watchdog crashes).
    private let bodyEvaluationCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("lifecycle_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("lifecycle_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        ioQueue.setSpecific(key: ioQueueSpecificKey, value: true)
    }

    /// Whether logging is enabled (checked on each write)
    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Log a free-form message. Prefer `checkpoint(...)` for structured events.
    nonisolated func log(_ message: String, source: String = #function, file: String = #file) {
        guard isEnabled else { return }

        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        let context = threadContext()
        let line = "[\(timestamp)] [\(context)] [\(fileName).\(source)] \(message)\n"

        recordEventTime(now)
        ioQueue.async { [self] in
            self.appendAndSync(line)
        }
    }

    /// Log a session boundary marker (APP LAUNCH, APP BACKGROUND, APP FOREGROUND).
    nonisolated func logMarker(_ marker: String) {
        guard isEnabled else { return }

        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        let separator = String(repeating: "=", count: 60)
        let line = "\n\(separator)\n[\(timestamp)] >>> \(marker) <<<\n\(separator)\n\n"

        recordEventTime(now)
        ioQueue.async { [self] in
            self.appendAndSync(line)
        }
    }

    /// Log a structured checkpoint with optional in-phase ms and key/value pairs.
    /// Each line includes `delta=X.YYms` from the previous logged event.
    /// Order kv keys deterministically by passing an array of (String, Any) pairs.
    nonisolated func checkpoint(_ name: String, ms: Double? = nil, _ kv: @autoclosure () -> [(String, Any)] = []) {
        guard isEnabled else { return }

        let line = checkpointLine(name, now: Date(), ms: ms, kv())
        ioQueue.async { [self] in
            self.appendAndSync(line)
        }
    }

    /// Log a structured checkpoint synchronously. Use this sparingly for
    /// scene-update operations where the next watchdog kill must identify the
    /// exact begin/end marker that failed to close.
    nonisolated func criticalCheckpoint(_ name: String, ms: Double? = nil, _ kv: [(String, Any)] = []) {
        guard isEnabled else { return }

        let line = checkpointLine(name, now: Date(), ms: ms, kv)
        if DispatchQueue.getSpecific(key: ioQueueSpecificKey) == true {
            appendAndSync(line)
        } else {
            ioQueue.sync { [self] in
                self.appendAndSync(line)
            }
        }
    }

    private nonisolated func checkpointLine(_ name: String, now: Date, ms: Double?, _ kv: [(String, Any)]) -> String {
        let nowTI = now.timeIntervalSinceReferenceDate
        let delta = lastEventTime.withLock { last -> Double in
            let d = last == 0 ? 0 : (nowTI - last) * 1000
            last = nowTI
            return d
        }

        let timestamp = dateFormatter.string(from: now)
        let context = threadContext()

        var parts: [String] = []
        parts.append(String(format: "delta=%.2fms", delta))
        if let ms {
            parts.append(String(format: "ms=%.2f", ms))
        }
        for (k, v) in kv {
            parts.append("\(k)=\(v)")
        }

        return "[\(timestamp)] [\(context)] \(name) \(parts.joined(separator: " "))\n"
    }

    /// Bump the per-gate suppression counter. Called by BisectFlags gate sites
    /// when they suppress a @Published mutation during the resume quiet window.
    nonisolated func bumpSuppression(_ gate: String) {
        // No isEnabled check — the counter is cheap and we want it consistent
        // across enable/disable transitions. Snapshot will only be written if
        // logging is enabled at snapshot time.
        suppressionCounters.withLock { counters in
            counters[gate, default: 0] += 1
        }
    }

    /// Bump the `MainView.body` evaluation counter. Called from the very top
    /// of `MainView.body` so we can measure how often the body re-evaluates
    /// across a window of time. The intent is to verify that the
    /// "decouple MainView from network state" refactor (TabBar / TabIndicator
    /// / HealthPopover / CurrentWindowTitleAccessor extractions) actually
    /// stops body re-evaluation under network instability — pre-refactor the
    /// counter increments per per-tab title/health/roam-protocol mutation,
    /// post-refactor it should only increment on structural events.
    /// Always counted (no `isEnabled` guard) so the snapshot is consistent
    /// across enable/disable transitions; snapshots are only written if
    /// logging is enabled at snapshot time.
    nonisolated func bumpBodyEvaluation() {
        bodyEvaluationCounter.withLock { $0 += 1 }
    }

    /// Snapshot the body-evaluation counter and reset to zero. Returned for
    /// inclusion as a `bodyEvals=N` key on the next lifecycle checkpoint.
    nonisolated func snapshotAndResetBodyEvaluation() -> Int {
        bodyEvaluationCounter.withLock { count in
            let out = count
            count = 0
            return out
        }
    }

    /// Snapshot the suppression counters into a compact string and reset them.
    /// Returns e.g. "{gate1:3,gate2:7,gate3:0,gate4:1}" or "{}" if all zero.
    nonisolated func snapshotAndResetSuppression() -> String {
        let snapshot = suppressionCounters.withLock { counters -> [String: Int] in
            let out = counters
            counters.removeAll(keepingCapacity: true)
            return out
        }
        if snapshot.isEmpty { return "{}" }
        let body = snapshot.keys.sorted()
            .map { "\($0):\(snapshot[$0] ?? 0)" }
            .joined(separator: ",")
        return "{\(body)}"
    }

    /// Scan the tail of the existing log file for a wedge tombstone before
    /// it is rotated by the new session. Returns the last non-empty,
    /// non-separator line if it does NOT contain a clean-completion marker;
    /// otherwise returns nil. Cheap (~4KB read) and synchronous so it can run
    /// directly from `application(_:didFinishLaunchingWithOptions:)`.
    nonisolated func scanPreviousSessionTermination() -> String? {
        guard FileManager.default.fileExists(atPath: logFileURL.path),
              let handle = try? FileHandle(forReadingFrom: logFileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let readSize = min(size, Self.tailScanBytes)
        let offset = size - readSize
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(readSize)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Walk lines from newest to oldest; skip blank lines and separator
        // lines (>>> ... <<<, ===...===). Stop at the first content line.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines.reversed() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("=") { continue }
            if line.contains(">>>") && line.contains("<<<") { continue }

            // If the most recent content line is a clean completion marker,
            // the previous session ended cleanly.
            for marker in Self.cleanCompletionMarkers {
                if line.contains(marker) { return nil }
            }
            return line
        }
        return nil
    }

    // MARK: - Private

    /// Best-effort thread / queue label for a single log line. Falls back to
    /// the dispatch queue label if not on the main thread.
    private nonisolated func threadContext() -> String {
        if Thread.isMainThread { return "main" }
        if let label = String(validatingUTF8: __dispatch_queue_get_label(nil)), !label.isEmpty {
            // Trim long reverse-DNS prefixes for readability.
            if let lastDot = label.lastIndex(of: ".") {
                return String(label[label.index(after: lastDot)...])
            }
            return label
        }
        return "thread-\(pthread_mach_thread_np(pthread_self()))"
    }

    /// Update the lastEventTime for delta tracking. Used by `log`/`logMarker`
    /// (checkpoint records its own delta inline).
    private nonisolated func recordEventTime(_ now: Date) {
        let nowTI = now.timeIntervalSinceReferenceDate
        lastEventTime.withLock { $0 = nowTI }
    }

    /// Append text to log file and sync to disk. Caller is responsible for
    /// running on `ioQueue`.
    private nonisolated func appendAndSync(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        rotateIfNeeded()

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.synchronize()
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// Rotate log file if it exceeds max size. Caller responsible for ioQueue.
    private nonisolated func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxFileSize else {
            return
        }

        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
