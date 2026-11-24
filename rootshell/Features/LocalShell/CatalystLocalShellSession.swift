//
//  CatalystLocalShellSession.swift
//  rootshell
//
//  Bridge between ghostty-helper and Catalyst app
//  Creates PTYs via helper and bridges to IOSExternal
//  Only available on Mac Catalyst
//

import Foundation
import os

#if targetEnvironment(macCatalyst)

/// Shell session for Catalyst using helper
/// This replaces LocalShellSession when running on Mac Catalyst
@MainActor
public class CatalystLocalShellSession: TerminalSession {

    private static let logFrequentLayout = ProcessInfo.processInfo.environment["GHOSTTY_LOG_FREQUENT_LAYOUT"] == "1"
    private static let resizeThrottleNs: UInt64 = 50_000_000  // 50ms

    let sessionID: UUID
    private let masterFD: Int32
    private let connectionStartedAt = Date()
    private let requestedShell: String?

    var connectionInfo: ConnectionInfo? {
        .local(shell: requestedShell ?? String(localized: "Login shell"),
               workingDirectory: nil, connectedAt: connectionStartedAt)
    }

    // TerminalSession protocol requirements
    public let pty: TerminalPTY
    public var isRunning = true
    var recoverySupported = false
    var recoveryAccepted = false
    var workingDirectoryUnavailable = false

    // Callback-based output pattern (matches SSHSession)
    // NOTE: These callbacks may be called from a background thread (PTY read queue).
    // Callers must ensure thread-safe handling.
    public var onOutput: (@Sendable (String) -> Void)?
    public var onOutputData: (@Sendable (Data) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onSessionEnd: (() -> Void)?
    public var onReady: (() -> Void)?
    public var onError: ((Error) -> Void)?

    // Reconnection support - local shell does not support reconnection
    public var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?
    public var supportsAutoReconnect: Bool { false }

    // Read queue for PTY polling (matches macOS Ghostty pattern)
    private let readQueue = DispatchQueue(label: "com.rootshell.catalyst.read", qos: .userInitiated)
    private var readSource: DispatchSourceRead?

    // Write queue for PTY writes (prevents main thread blocking during large pastes)
    private let writeQueue = DispatchQueue(label: "com.rootshell.catalyst.write", qos: .userInitiated)
    private var closeScheduled = false

    // Coalesced resize state (to avoid hammering the helper during live resizing)
    private var lastSentGridSize: (rows: UInt16, cols: UInt16)?
    private var pendingGridSize: (rows: UInt16, cols: UInt16)?
    private var resizeTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new session by requesting a shell from the helper
    public static func create(
        rows: UInt16,
        cols: UInt16,
        workingDirectory: String? = nil,
        shell: String? = nil,
        enableShellIntegration: Bool = true,
        paneToken: String? = nil,
        recoveryAttachment: LocalMultiplexerAttachment? = nil,
        completion: @escaping (Result<CatalystLocalShellSession, Error>) -> Void
    ) {
        Ghostty.logger.info("Creating Catalyst shell session: \(rows)x\(cols), cwd=\(workingDirectory ?? "nil")")
        attemptCreate(
            rows: rows,
            cols: cols,
            workingDirectory: workingDirectory,
            shell: shell,
            enableShellIntegration: enableShellIntegration,
            paneToken: paneToken,
            recoveryAttachment: recoveryAttachment,
            retriesRemaining: 1,
            completion: completion
        )
    }

    private static func attemptCreate(
        rows: UInt16,
        cols: UInt16,
        workingDirectory: String?,
        shell: String?,
        enableShellIntegration: Bool,
        paneToken: String?,
        recoveryAttachment: LocalMultiplexerAttachment?,
        retriesRemaining: Int,
        completion: @escaping (Result<CatalystLocalShellSession, Error>) -> Void
    ) {
        let size = TerminalPTY.TerminalSize(rows: rows, cols: cols)

        // Request shell from helper
        HelperConnection.shared.createShell(
            rows: rows,
            cols: cols,
            workingDirectory: workingDirectory,
            shell: shell,
            enableShellIntegration: enableShellIntegration,
            paneToken: paneToken,
            recoveryAttachment: recoveryAttachment
        ) { result in
            switch result {
            case .success(let createResult):
                Ghostty.logger.info("Helper created session \(createResult.sessionID), socket=\(createResult.socketPath)")

                // Receive PTY master FD on a background thread to avoid blocking main thread
                // The FDReceiver uses select() + accept() which can take time
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let masterFD = FDReceiver.receiveFileDescriptor(from: createResult.socketPath) else {
                        DispatchQueue.main.async {
                            // Reap the half-created helper session, then retry the
                            // whole createShell once so a transient stall doesn't
                            // leave a live-but-typing-dead tab.
                            HelperConnection.shared.killShell(sessionID: createResult.sessionID) { _ in }
                            if retriesRemaining > 0 {
                                Ghostty.logger.warning("FD handoff failed for session \(createResult.sessionID), retrying createShell")
                                attemptCreate(
                                    rows: rows,
                                    cols: cols,
                                    workingDirectory: workingDirectory,
                                    shell: shell,
                                    enableShellIntegration: enableShellIntegration,
                                    paneToken: paneToken,
                                    recoveryAttachment: recoveryAttachment,
                                    retriesRemaining: retriesRemaining - 1,
                                    completion: completion
                                )
                            } else {
                                Ghostty.logger.error("Failed to receive master FD from socket after retry")
                                completion(.failure(NSError(
                                    domain: "CatalystLocalShellSession",
                                    code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to receive master FD"]
                                )))
                            }
                        }
                        return
                    }

                    Ghostty.logger.info("Received master FD \(masterFD) for session \(createResult.sessionID)")

                    // Create session and call completion on main thread
                    DispatchQueue.main.async {
                        let session = CatalystLocalShellSession(
                            sessionID: createResult.sessionID,
                            masterFD: masterFD,
                            size: size,
                            shell: shell
                        )

                        session.recoverySupported = createResult.recoverySupported
                        session.recoveryAccepted = createResult.recoveryAccepted
                        session.workingDirectoryUnavailable = createResult.workingDirectoryUnavailable

                        // Output monitoring is started by the caller after callbacks are configured
                        completion(.success(session))
                    }
                }

            case .failure(let error):
                Ghostty.logger.error("Failed to create shell via helper: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private init(sessionID: UUID, masterFD: Int32, size: TerminalPTY.TerminalSize, shell: String?) {
        self.requestedShell = shell
        self.sessionID = sessionID
        self.masterFD = masterFD

        // Create a TerminalPTY wrapper around the external FD
        // This PTY uses the master FD provided by the helper (which already created the PTY)
        let pty = TerminalPTY()
        pty.useExternalFd(masterFD)
        pty.windowSize = size
        self.pty = pty
    }

    nonisolated deinit {
        // Note: Can't call MainActor-isolated cleanup() from deinit
        // Cleanup will happen via handleExit() or explicit stop() call
        // The helper will also clean up sessions automatically
    }

    // MARK: - I/O Operations

    /// Starts monitoring PTY output using callback pattern (matches SSHSession)
    func startMonitoring() {
        guard readSource == nil else { return }
        Ghostty.logger.info("Starting PTY monitoring with polling pattern for session \(self.sessionID)")

        // Set PTY master FD to non-blocking mode (critical for polling)
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        let sessionID = self.sessionID
        let masterFD = self.masterFD
        let outputDataCallback = self.onOutputData
        let outputCallback = self.onOutput
        let handleExit: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExit()
            }
        }
        let emitOutput: @Sendable (Data) -> Void = { data in
            if let outputDataCallback {
                outputDataCallback(data)
            } else if let outputCallback {
                outputCallback(String(decoding: data, as: UTF8.self))
            }
        }

        // Create a dispatch source to monitor PTY for readability
        // This mimics poll() in macOS Ghostty's threadMainPosix
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)

        source.setEventHandler {
            let (output, didExit) = Self.readFromPTY(masterFD: masterFD)
            if !output.isEmpty {
                // Emit directly without batching for immediate response
                emitOutput(output)
            }
            if didExit {
                handleExit()
            }
        }

        source.setCancelHandler {
            Ghostty.logger.info("PTY read source canceled for session \(sessionID.uuidString)")
        }

        source.resume()
        self.readSource = source

        // Session is now ready for input
        Ghostty.logger.info("Catalyst session monitoring started, firing onReady callback")
        onReady?()
    }

    /// Reads from PTY in a hot loop until EAGAIN (matches macOS Ghostty pattern)
    /// Returns raw bytes for direct terminal rendering.
    private nonisolated static func readFromPTY(masterFD: Int32) -> (Data, Bool) {
        guard masterFD >= 0 else { return (Data(), false) }

        let bufferSize = 4096 // Larger buffer reduces callback churn during heavy repaints
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()
        var didExit = false

        // Hot loop: read as much as available (until EAGAIN)
        while true {
            let bytesRead = read(masterFD, &buffer, bufferSize)

            if bytesRead > 0 {
                output.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                // EOF - PTY closed
                didExit = true
                break
            } else {
                // Error occurred
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // No more data available - exit hot loop
                    // DispatchSource will call us again when more data arrives
                    break
                } else if err == EINTR {
                    // Interrupted by signal - retry
                    continue
                } else {
                    // Fatal error
                    Ghostty.logger.error("PTY read error: \(String(cString: strerror(err)))")
                    didExit = true
                    break
                }
            }
        }

        return (output, didExit)
    }


    // MARK: - TerminalSession Protocol Implementation

    public func start() async throws {
        // Session is already started in create()
        // This is called by the framework to begin processing
        Ghostty.logger.info("Session \(self.sessionID) start() called")
    }

    public func stop() {
        terminate(signal: SIGHUP)
    }

    public func sendInput(_ data: Data) {
        // Dispatch writes to background queue to prevent main thread blocking
        // during large pastes that may require retries when PTY buffer fills.
        guard isRunning, masterFD >= 0 else {
            Ghostty.logger.warning("Cannot write - session not running or no FD")
            return
        }

        // Capture fd as value type for async dispatch
        let fd = masterFD

        writeQueue.async {
            Self.writeAll(fd: fd, data: data)
        }
    }

    /// Writes `data` to `fd`, retrying on EAGAIN/EINTR/buffer-full. Actor-agnostic
    /// and thread-safe so it can be shared by `sendInput` and the tmux
    /// control-mode gateway fast path. Always invoked on `writeQueue` so writes
    /// stay serialized regardless of which path enqueued them.
    private nonisolated static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return }
            var totalWritten = 0
            var retryCount = 0
            let maxRetries = 1000  // Allow up to ~1 second of retries

            while totalWritten < data.count {
                let remaining = data.count - totalWritten
                let currentPtr = baseAddress.advanced(by: totalWritten)
                let bytesWritten = Darwin.write(fd, currentPtr, remaining)

                if bytesWritten > 0 {
                    totalWritten += bytesWritten
                    retryCount = 0  // Reset retry counter on successful write
                } else if bytesWritten < 0 {
                    let err = errno
                    if err == EINTR {
                        // Interrupted by signal - retry without counting as backoff
                        continue
                    }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // PTY buffer full - retry with backoff
                        if retryCount < maxRetries {
                            retryCount += 1
                            usleep(1000)  // 1ms sleep to let PTY drain
                            continue
                        } else {
                            Ghostty.logger.error("PTY write failed after \(maxRetries) retries (buffer full)")
                            break
                        }
                    } else {
                        Ghostty.logger.error("Failed to write to PTY: \(String(cString: strerror(err)))")
                        break
                    }
                } else {
                    // bytesWritten == 0 shouldn't happen for PTY, but handle it
                    Ghostty.logger.warning("PTY write returned 0")
                    break
                }
            }

            if totalWritten < data.count {
                Ghostty.logger.error("Partial PTY write: \(totalWritten)/\(data.count) bytes")
            }
        }
    }

    /// Builds a `@Sendable` sink that writes input to the PTY off the main
    /// actor, used by the tmux control-mode gateway response path to skip a
    /// per-keystroke main-actor hop. Captures the write fd and queue by value
    /// (both `Sendable`); the fd is stable for the session's lifetime, so the
    /// sink stays valid until the session ends (writes to a closed fd fail
    /// harmlessly via `writeAll`). Returns nil if not running.
    /// See `TerminalResponsePipeline.configureGatewayFastPath`.
    func makeNonisolatedInputSink() -> (@Sendable (Data) -> Void)? {
        guard isRunning, masterFD >= 0 else { return nil }
        let fd = masterFD
        let q = writeQueue
        return { data in q.async { Self.writeAll(fd: fd, data: data) } }
    }

    /// The PTY's foreground process group, for the pane's program identity.
    func foregroundProcessGroup() -> pid_t? {
        guard isRunning else { return nil }
        return LocalForegroundProcessProbe.foregroundProcessGroup(masterFD: masterFD)
    }

    public func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size
        scheduleResize(rows: size.rows, cols: size.cols)
    }

    /// Interrupts the running command (CTRL-C handler)
    /// Uses in-band signaling (sends \x03 through PTY) like SSH and macOS Ghostty
    public func interrupt() {
        Ghostty.logger.info("Sending CTRL-C to shell")

        // Send CTRL-C (\x03) directly to the PTY
        // The shell receives it, sends SIGINT to the process, and output stops naturally
        // The polling read pattern handles this gracefully with no special logic needed
        let ctrlC = Data([0x03])
        sendInput(ctrlC)
    }

    /// Resizes the PTY (coalesced during live resizing)
    private func scheduleResize(rows: UInt16, cols: UInt16) {
        guard isRunning else { return }

        let gridSize = (rows: rows, cols: cols)
        if let pendingGridSize, pendingGridSize == gridSize { return }
        pendingGridSize = gridSize

        if resizeTask == nil {
            resizeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.resizeTask = nil }

                while true {
                    guard let pending = self.pendingGridSize else { break }
                    self.pendingGridSize = nil

                    if let lastSentGridSize = self.lastSentGridSize, lastSentGridSize == pending {
                        // Already sent this exact size; no-op.
                    } else {
                        self.lastSentGridSize = pending
                        if Self.logFrequentLayout {
                            let sessionID = self.sessionID
                            let rows = pending.rows
                            let cols = pending.cols
                            Ghostty.logger.debug("Resizing session \(sessionID) to \(rows)x\(cols)")
                        }
                        let success = await HelperConnection.shared.resizeShell(
                            sessionID: self.sessionID,
                            rows: pending.rows,
                            cols: pending.cols
                        )
                        if success {
                            // Re-apply ioctl(TIOCSWINSZ) with pixel dimensions after the
                            // helper's resize. The helper only receives rows/cols, so its
                            // ioctl zeros out ws_xpixel/ws_ypixel. Re-setting from
                            // pty.windowSize restores the pixel values needed by kitty icat,
                            // imgcat, and other image-capable tools.
                            try? self.pty.setWindowSize(self.pty.windowSize)
                        } else {
                            self.lastSentGridSize = nil
                        }
                    }

                    try? await Task.sleep(nanoseconds: Self.resizeThrottleNs)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Terminates the shell
    private func terminate(signal: Int32 = SIGTERM) {
        guard isRunning else { return }

        Ghostty.logger.info("Terminating session \(self.sessionID) with signal \(signal)")

        HelperConnection.shared.killShell(sessionID: sessionID, signal: signal) { success in
            if !success {
                Ghostty.logger.error("Failed to kill session \(self.sessionID)")
            }
        }

        cleanup()
    }

    private func handleExit() {
        guard isRunning else { return }
        isRunning = false

        Ghostty.logger.info("Session \(self.sessionID) exited, querying status")

        // Query exit status from helper
        HelperConnection.shared.getSessionInfo(sessionID: sessionID) { [weak self] info in
            guard let self = self else { return }

            let exitStatus = info?.exitStatus ?? -1
            Ghostty.logger.info("Session \(self.sessionID) exited with status \(exitStatus)")

            self.onSessionEnd?()
            self.cleanup()
        }
    }

    private func cleanup() {
        isRunning = false

        // Cancel any pending tasks
        resizeTask?.cancel()
        resizeTask = nil
        pendingGridSize = nil

        // Cancel read source
        readSource?.cancel()
        readSource = nil

        // Close master FD
        if masterFD >= 0, !closeScheduled {
            closeScheduled = true
            let fd = masterFD
            writeQueue.async {
                close(fd)
            }
        }
    }
}

#endif // targetEnvironment(macCatalyst)
