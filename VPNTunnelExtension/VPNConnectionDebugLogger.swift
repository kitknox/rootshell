//
//  VPNConnectionDebugLogger.swift
//  VPNTunnelExtension
//
//  Detailed text log for VPN connection setup diagnostics.
//  Writes timestamped, human-readable phase logs to the app group container.
//  Off by default — enabled via hidden debug settings toggle.
//
//  Modeled on ResumeDebugLogger but adapted for the extension process:
//  - Log file in app group container (not Documents)
//  - Enabled flag in shared UserDefaults
//  - NSLock-based thread safety (no DispatchQueue)
//  - beginPhase/endPhase helpers with automatic duration tracking
//

import Foundation

nonisolated final class VPNConnectionDebugLogger: @unchecked Sendable {
    static let shared = VPNConnectionDebugLogger()

    /// UserDefaults key — stored in shared app group suite so the main app toggle
    /// is visible to the extension process.
    static let enabledKey = "vpnConnectionDebugLoggingEnabled"

    private static let appGroupID = AppIdentifiers.defaultAppGroupID
    private static let logFilename = "vpn_connection_debug.log"
    private static let rotatedLogFilename = "vpn_connection_debug.1.log"
    private static let maxFileSize: UInt64 = 512 * 1024  // 512KB before rotation

    private let lock = NSLock()
    private let dateFormatter: DateFormatter

    /// Tracks monotonic start time for each in-progress phase.
    private var phaseStartTimes: [String: UInt64] = [:]

    /// Monotonic reference point for the current connection session.
    private var sessionStartTime: UInt64 = 0

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter
    }

    /// Whether logging is enabled (checked on each write).
    var isEnabled: Bool {
        UserDefaults(suiteName: Self.appGroupID)?.bool(forKey: Self.enabledKey) ?? false
    }

    // MARK: - Public API

    /// Mark the start of a new connection session. Resets phase tracking.
    func resetSession() {
        guard isEnabled else { return }
        lock.lock()
        phaseStartTimes.removeAll()
        sessionStartTime = Self.uptimeMs()
        lock.unlock()
    }

    /// Log a session boundary marker (e.g., VPN CONNECT START, VPN CONNECT COMPLETE).
    func logMarker(_ marker: String) {
        guard isEnabled else { return }
        lock.lock()
        let timestamp = dateFormatter.string(from: Date())
        let separator = String(repeating: "=", count: 60)
        let line = "\n\(separator)\n[\(timestamp)] >>> \(marker) <<<\n\(separator)\n\n"
        appendAndSyncLocked(line)
        lock.unlock()
    }

    /// Log a simple message under a phase label.
    func log(_ phase: String, _ message: String) {
        guard isEnabled else { return }
        lock.lock()
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(phase)] \(message)\n"
        appendAndSyncLocked(line)
        lock.unlock()
    }

    /// Begin a timed phase. Records the monotonic start time and logs the message.
    func beginPhase(_ phase: String, _ message: String) {
        guard isEnabled else { return }
        lock.lock()
        let now = Self.uptimeMs()
        phaseStartTimes[phase] = now
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(phase)] \(message)\n"
        appendAndSyncLocked(line)
        lock.unlock()
    }

    /// End a timed phase. Computes duration from beginPhase and logs with duration suffix.
    func endPhase(_ phase: String, _ message: String) {
        guard isEnabled else { return }
        lock.lock()
        let now = Self.uptimeMs()
        let timestamp = dateFormatter.string(from: Date())
        let durationSuffix: String
        if let startTime = phaseStartTimes.removeValue(forKey: phase) {
            let durationMs = now - startTime
            durationSuffix = " (\(durationMs)ms)"
        } else {
            durationSuffix = ""
        }
        let line = "[\(timestamp)] [\(phase)] \(message)\(durationSuffix)\n"
        appendAndSyncLocked(line)
        lock.unlock()
    }

    /// Log an error for a phase, including duration if beginPhase was called.
    func logError(_ phase: String, _ error: any Error) {
        guard isEnabled else { return }
        lock.lock()
        let now = Self.uptimeMs()
        let timestamp = dateFormatter.string(from: Date())
        let durationSuffix: String
        if let startTime = phaseStartTimes.removeValue(forKey: phase) {
            let durationMs = now - startTime
            durationSuffix = " (\(durationMs)ms)"
        } else {
            durationSuffix = ""
        }
        let desc = error.localizedDescription
        let line = "[\(timestamp)] [\(phase)] FAILED: \(desc)\(durationSuffix)\n"
        appendAndSyncLocked(line)
        lock.unlock()
    }

    /// Returns milliseconds elapsed since the last resetSession() call.
    func sessionElapsedMs() -> UInt64 {
        lock.lock()
        let elapsed = Self.uptimeMs() - sessionStartTime
        lock.unlock()
        return elapsed
    }

    // MARK: - File Management (called from main app)

    /// URL of the log file in the app group container. Returns nil if app group is unavailable.
    static func logFileURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        return containerURL.appendingPathComponent(logFilename)
    }

    /// URL of the rotated log file.
    static func rotatedLogFileURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        return containerURL.appendingPathComponent(rotatedLogFilename)
    }

    /// Size of the current log file in bytes. Returns nil if no file exists.
    static func logFileSize() -> UInt64? {
        guard let url = logFileURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    /// Delete both the current and rotated log files.
    static func clearLogFiles() {
        if let url = logFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = rotatedLogFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    /// Append text to log file and sync to disk. Must be called with `lock` held.
    private func appendAndSyncLocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        rotateIfNeededLocked()

        guard let fileURL = Self.logFileURL() else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.synchronizeFile()
                handle.closeFile()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Rotate log file if it exceeds max size. Must be called with `lock` held.
    private func rotateIfNeededLocked() {
        guard let fileURL = Self.logFileURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxFileSize else {
            return
        }

        if let rotatedURL = Self.rotatedLogFileURL() {
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        }
    }

    /// Monotonic clock in milliseconds using mach_continuous_time.
    private static func uptimeMs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        return ticks * UInt64(info.numer) / UInt64(info.denom) / 1_000_000
    }
}
