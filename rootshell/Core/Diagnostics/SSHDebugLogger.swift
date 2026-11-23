//
//  SSHDebugLogger.swift
//  rootshell
//
//  File-based debug logger for SSH connection diagnostics. Off by default.
//  Captures `ssh -vv`-class detail (KEX algorithms, host key fingerprints,
//  auth method negotiation, banners, channel state, swift-nio-ssh internals,
//  Citadel internals) to Documents/.ghostty/ssh_debug.log. Companion to
//  LifecycleDebugLogger / ResumeDebugLogger.
//
//  Toggle: UserDefaults["sshDebugLoggingEnabled"]. The toggle is checked on
//  every write so it takes effect at runtime without needing a rebootstrap.
//
//  ─── SECURITY ────────────────────────────────────────────────────────────
//  NEVER LOG: password text, private key bytes, key passphrases, ephemeral
//  private key material, HSS-resolved credentials, raw public-key bytes.
//
//  SAFE TO LOG: hostnames, ports, usernames, public-key fingerprints (already
//  SHA-256 hashed), key types, algorithm names, banner text (truncated to
//  bannerTruncation), error descriptions, auth method names, channel state.
//
//  Every call site must respect this contract. When in doubt, log a
//  fingerprint instead of the underlying material.
//

import Foundation
import Logging
import NIOSSH
import os

/// File-based SSH debug logger. Persists across force-quit cycles via
/// `synchronizeFile()` after each write. Off by default; enable via the
/// hidden Debug Settings view.
final class SSHDebugLogger: Sendable {
    nonisolated static let shared = SSHDebugLogger()

    /// UserDefaults key to enable/disable logging
    nonisolated static let enabledKey = "sshDebugLoggingEnabled"

    /// Max log file size before rotation (10 MB).
    /// Most ssh-style sessions are <500KB; 10MB lets a power user keep
    /// several recent connections without rotating.
    nonisolated private static let maxFileSize: UInt64 = 10 * 1024 * 1024

    /// Max length for banner text (server-supplied) before truncation.
    nonisolated static let bannerTruncation: Int = 1024

    /// Serial queue for thread-safe file I/O
    private let ioQueue = DispatchQueue(label: "com.rootshell.sshDebugLogger")

    /// Log file URL: Documents/.ghostty/ssh_debug.log
    private let logFileURL: URL

    /// Rotated log file URL
    private let rotatedLogFileURL: URL

    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter

    /// Latch so global library bootstraps run exactly once per process.
    private let bootstrapsInstalled = OSAllocatedUnfairLock<Bool>(initialState: false)

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("ssh_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("ssh_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    }

    /// Whether logging is enabled (checked on each write)
    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Free-form log line. Prefer `event(_:_:)` for structured entries.
    nonisolated func log(_ message: String, source: String = #function, file: String = #file) {
        guard isEnabled else { return }
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        write("[\(timestamp())] [\(fileName).\(source)] \(message)\n")
    }

    /// Categorized event line. Categories include: KEX, AUTH, HOSTKEY,
    /// CHANNEL, BANNER, CONN, NIOSSH, CITADEL.
    nonisolated func event(_ category: String, _ message: String) {
        guard isEnabled else { return }
        write("[\(timestamp())] [\(category)] \(message)\n")
    }

    /// Connection-boundary marker (SSH START / SSH END / JUMP CONNECT / etc.)
    nonisolated func logMarker(_ marker: String) {
        guard isEnabled else { return }
        let separator = String(repeating: "=", count: 60)
        write("\n\(separator)\n[\(timestamp())] >>> \(marker) <<<\n\(separator)\n\n")
    }

    // MARK: - Library Bootstraps

    /// Install global hooks for swift-nio-ssh and swift-log (Citadel) once
    /// per process. Call from AppDelegate.didFinishLaunchingWithOptions.
    /// Handlers themselves consult `isEnabled` at write time, so the toggle
    /// remains live without a rebootstrap.
    nonisolated func installLibraryBridgesIfNeeded() {
        let alreadyInstalled = bootstrapsInstalled.withLock { installed -> Bool in
            if installed { return true }
            installed = true
            return false
        }
        guard !alreadyInstalled else { return }

        installNIOSSHDebugBridge()
        bootstrapSwiftLog()
    }

    private nonisolated func installNIOSSHDebugBridge() {
        NIOSSHDebug.shared.setHandlers(
            increment: { [weak self] key, delta in
                guard let self, self.isEnabled else { return }
                self.event("NIOSSH", "\(key) += \(delta)")
            },
            set: { [weak self] key, value in
                guard let self, self.isEnabled else { return }
                self.event("NIOSSH", "\(key) = \(value)")
            },
            event: { [weak self] text in
                guard let self, self.isEnabled else { return }
                self.event("NIOSSH", text)
            },
            tsLog: { [weak self] text in
                guard let self, self.isEnabled else { return }
                self.event("NIOSSH", text)
            },
            initiallyEnabled: isEnabled
        )

        // Keep NIOSSHDebug's lock-free atomic flag synchronized with the live
        // UserDefaults toggle so NIOSSH skips timestamping and counter work
        // whenever SSH debug logging is switched off.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            NIOSSHDebug.shared.setEnabled(self.isEnabled)
        }
    }

    private nonisolated func bootstrapSwiftLog() {
        // One-shot per process. The factory returns a handler that always
        // forwards to os.log (preserves console behavior) and additionally
        // writes to the file when (a) the toggle is enabled and (b) the
        // label looks like an SSH-related library label.
        LoggingSystem.bootstrap { label in
            SSHDebugLogHandler(label: label, file: SSHDebugLogger.shared)
        }
    }

    // MARK: - Helpers

    /// Truncate server-supplied text to a safe length for logging.
    nonisolated static func truncate(_ text: String, max: Int = bannerTruncation) -> String {
        if text.count <= max { return text }
        let prefix = text.prefix(max)
        return "\(prefix)…[truncated \(text.count - max) chars]"
    }

    /// Decode an `NIOSSHAvailableUserAuthenticationMethods` bitmask into a
    /// human-readable comma-separated list. Safe — method names only.
    nonisolated static func describe(authMethods: NIOSSHAvailableUserAuthenticationMethods) -> String {
        var names: [String] = []
        if authMethods.contains(.publicKey) { names.append("publickey") }
        if authMethods.contains(.password) { names.append("password") }
        if authMethods.contains(.hostBased) { names.append("hostbased") }
        if names.isEmpty { return "none" }
        return names.joined(separator: ",")
    }

    // MARK: - Private I/O

    private nonisolated func timestamp() -> String {
        dateFormatter.string(from: Date())
    }

    private nonisolated func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        ioQueue.async { [self] in
            self.appendAndSync(data)
        }
    }

    private nonisolated func appendAndSync(_ data: Data) {
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

// MARK: - Swift-Log Handler

/// Custom `LogHandler` that forwards every record to os.log (so existing
/// console output is preserved), and additionally writes Citadel/NIO-SSH
/// labelled records to the SSH debug file when the toggle is enabled.
///
/// Bootstrapped once per process via `LoggingSystem.bootstrap`.
struct SSHDebugLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    private let label: String
    private let osLogger: os.Logger
    private let file: SSHDebugLogger
    private let isSSHLabel: Bool

    init(label: String, file: SSHDebugLogger) {
        self.label = label
        // Mirror to os.log under our subsystem so existing Console.app debug
        // workflows keep working.
        self.osLogger = os.Logger(subsystem: "com.rootshell.swiftlog", category: label)
        self.file = file
        self.isSSHLabel = label.hasPrefix("nl.orlandos.citadel")
            || label.hasPrefix("com.apple.nio")
            || label.hasPrefix("citadel")
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let level = event.level
        let message = event.message
        let combined = event.metadata.map { self.metadata.merging($0) { _, new in new } } ?? self.metadata
        let metaSuffix = combined.isEmpty
            ? ""
            : " " + combined.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        let line = "[\(level.rawValue)] [\(label)] \(message)\(metaSuffix)"

        // Always mirror to os.log at the requested level.
        switch level {
        case .trace, .debug:
            osLogger.debug("\(line, privacy: .public)")
        case .info, .notice:
            osLogger.info("\(line, privacy: .public)")
        case .warning:
            osLogger.warning("\(line, privacy: .public)")
        case .error, .critical:
            osLogger.error("\(line, privacy: .public)")
        }

        // Additionally write SSH-labelled records to the file when enabled.
        if isSSHLabel {
            self.file.event("CITADEL", line)
        }
    }
}
