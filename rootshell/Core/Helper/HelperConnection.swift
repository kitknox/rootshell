//
//  HelperConnection.swift
//  rootshell
//
//  Socket client for connecting to ghostty-helper from Catalyst app
//  Only available on Mac Catalyst
//
//  Previously used XPC, but XPC's machServiceName: API is not available on Catalyst.
//  Now uses Unix domain sockets in the shared App Group container.
//

import Foundation
import os

#if targetEnvironment(macCatalyst)

/// Result of creating a shell session
public struct ShellCreateResult {
    public let sessionID: UUID
    public let socketPath: String
    public let recoverySupported: Bool
    public let recoveryAccepted: Bool

    public init(sessionID: UUID, socketPath: String, recoverySupported: Bool = false, recoveryAccepted: Bool = false) {
        self.sessionID = sessionID
        self.socketPath = socketPath
        self.recoverySupported = recoverySupported
        self.recoveryAccepted = recoveryAccepted
    }
}

#if STANDALONE
/// Private libsystem API (see TN3179). Marks a posix_spawn'd child as its own
/// TCC "responsible process" so Local Network (and other TCC) operations by the
/// helper and all of its shell descendants are attributed to the helper itself,
/// not to this app — surviving app exit and helper orphaning.
/// C prototype: int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);
private typealias ResponsibilityDisclaimFn =
    @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, CInt) -> CInt

private let responsibilityDisclaim: ResponsibilityDisclaimFn? = {
    // RTLD_DEFAULT ((void *)-2) is a macro Swift doesn't import.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                          "responsibility_spawnattrs_setdisclaim") else { return nil }
    return unsafeBitCast(sym, to: ResponsibilityDisclaimFn.self)
}()

nonisolated private enum HelperProcessIDStore {
    private static let lock = NSLock()
    private static var value: pid_t = 0

    static func set(_ pid: pid_t) {
        lock.lock()
        value = pid
        lock.unlock()
    }

    static func get() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif

/// Manages connection to the ghostty-helper via Unix domain sockets
public class HelperConnection {

    public static let shared = HelperConnection()

    #if STANDALONE
    public nonisolated static var currentHelperProcessID: pid_t {
        HelperProcessIDStore.get()
    }

    public nonisolated static func recordHelperProcessID(_ pid: pid_t) {
        HelperProcessIDStore.set(pid)
    }
    #endif

    private let socketConnection = SocketHelperConnection()

    /// Coalesces concurrent `ensureHelperRunning()` callers (launch prewarm +
    /// first-window onAppear) onto a single spawn/ping sequence.
    private let ensureLock = NSLock()
    private var inFlightEnsure: Task<Bool, Never>?

    /// PID of helper process if we launched it (non-sandboxed mode)
    private var helperPID: pid_t = 0 {
        didSet {
            #if STANDALONE
            HelperProcessIDStore.set(helperPID)
            #endif
        }
    }

    public var helperProcessID: pid_t {
        helperPID
    }

    /// True once a ping/ensure has confirmed the helper is reachable. Lets the
    /// UI skip the (MainActor-congested) `await ensureHelperRunning()` on every
    /// window after the first and create the local shell synchronously instead.
    /// Cleared when the helper is found unreachable or is stopped, so a build
    /// with no helper (sandboxed, no external helper) never goes optimistic.
    public private(set) var isKnownRunning = false

    private init() {}

    // MARK: - Helper Operations

    /// Creates a new shell session
    public func createShell(
        rows: UInt16,
        cols: UInt16,
        workingDirectory: String? = nil,
        shell: String? = nil,
        enableShellIntegration: Bool = true,
        paneToken: String? = nil,
        recoveryAttachment: LocalMultiplexerAttachment? = nil,
        completion: @escaping (Result<ShellCreateResult, Error>) -> Void
    ) {
        Task {
            do {
                // Get resources directory from main bundle
                // The rootshell app has shell-integration files in Resources/
                let resourcesDir = Bundle.main.resourceURL?.path
                #if STANDALONE
                let sshAuthSock = LocalSSHAgentManager.activeSocketPathForShells
                #else
                let sshAuthSock: String? = nil
                #endif

                let response = try await socketConnection.createShell(
                    rows: rows,
                    cols: cols,
                    cwd: workingDirectory,
                    shell: shell,
                    resourcesDir: resourcesDir,
                    enableShellIntegration: enableShellIntegration,
                    sshAuthSock: sshAuthSock,
                    paneToken: paneToken,
                    recoveryAttachment: recoveryAttachment
                )

                let result = ShellCreateResult(sessionID: response.sessionID, socketPath: response.socketPath,
                    recoverySupported: response.recoverySupported ?? false, recoveryAccepted: response.recoveryAccepted ?? false)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func inspectLocalMultiplexers() async throws -> [String: LocalMultiplexerAttachment?] {
        try await socketConnection.inspectLocalMultiplexers()
    }

    /// Spawns a long-lived non-PTY command and returns its pid plus the
    /// session socket where the helper delivers the app's end of its stdio.
    public func spawnPipedProcess(
        command: String,
        workingDirectory: String? = nil,
        shell: String? = nil,
        paneToken: String? = nil
    ) async throws -> (processID: Int32, socketPath: String) {
        try await socketConnection.spawnPipedProcess(
            command: command,
            cwd: workingDirectory,
            shell: shell,
            paneToken: paneToken
        )
    }

    public func killPipedProcess(processID: Int32) async {
        do {
            try await socketConnection.killPipedProcess(processID: processID)
        } catch {
            Ghostty.logger.error("Failed to kill piped process \(processID): \(error)")
        }
    }

    /// Resizes a shell session
    public func resizeShell(
        sessionID: UUID,
        rows: UInt16,
        cols: UInt16,
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            let success = await resizeShell(sessionID: sessionID, rows: rows, cols: cols)
            completion(success)
        }
    }

    /// Resizes a shell session
    public func resizeShell(sessionID: UUID, rows: UInt16, cols: UInt16) async -> Bool {
        do {
            try await socketConnection.resizeShell(sessionID: sessionID, rows: rows, cols: cols)
            return true
        } catch {
            Ghostty.logger.error("Failed to resize shell: \(error)")
            return false
        }
    }

    /// Kills a shell session
    public func killShell(
        sessionID: UUID,
        signal: Int32 = SIGTERM,
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            do {
                try await socketConnection.killShell(sessionID: sessionID)
                completion(true)
            } catch {
                Ghostty.logger.error("Failed to kill shell: \(error)")
                completion(false)
            }
        }
    }

    /// Gets information about a session (not implemented in socket protocol yet)
    public func getSessionInfo(
        sessionID: UUID,
        completion: @escaping (SessionInfo?) -> Void
    ) {
        // Note: SessionInfo not implemented in socket protocol
        // The helper doesn't expose this via sockets currently
        Ghostty.logger.info("getSessionInfo not implemented in socket protocol")
        completion(nil)
    }

    /// Lists all active sessions (not implemented in socket protocol yet)
    public func listSessions(completion: @escaping ([UUID]) -> Void) {
        // Note: listSessions not implemented in socket protocol
        Ghostty.logger.info("listSessions not implemented in socket protocol")
        completion([])
    }

    /// Pings the helper to check if it's alive
    public func ping(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await socketConnection.ping()
                completion(true)
            } catch {
                Ghostty.logger.error("Helper ping failed: \(error)")
                completion(false)
            }
        }
    }

    // MARK: - Command Execution (AI Agent)

    /// Executes a command via the helper with streaming output
    /// - Parameters:
    ///   - command: Shell command to execute
    ///   - workingDirectory: Working directory (nil = use default)
    ///   - timeout: Maximum execution time (default 30s)
    ///   - onOutput: Called with each output chunk as a string (runs on socket I/O queue)
    /// - Returns: Final result with exit code and timing
    public func executeCommand(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
        onOutput: @escaping (String) -> Void
    ) async throws -> ExecuteCommandResult {
        try await socketConnection.executeCommand(
            command: command,
            cwd: workingDirectory,
            timeout: timeout
        ) { data, _ in
            // Convert data to string and call handler on main actor
            let text = String(decoding: data, as: UTF8.self)
            onOutput(text)
        }
    }

    /// Executes a command via the helper (non-streaming convenience method)
    /// - Parameters:
    ///   - command: Shell command to execute
    ///   - workingDirectory: Working directory (nil = use default)
    ///   - timeout: Maximum execution time (default 30s)
    /// - Returns: Final result with exit code and timing
    ///   - maxOutputBytes: Stop after this many bytes; the result is a prefix
    ///     marked `truncated`, and the helper stops streaming. Unbounded when nil.
    public func executeCommand(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int? = nil
    ) async throws -> ExecuteCommandResult {
        try await socketConnection.executeCommand(
            command: command,
            cwd: workingDirectory,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            onOutput: { _, _ in }  // No-op output handler
        )
    }

    // MARK: - Helper Lifecycle

    /// Checks if helper is running
    public func isHelperRunning(completion: @escaping (Bool) -> Void) {
        ping(completion: completion)
    }

    /// Ensures helper is running, launching it if necessary (non-sandboxed mode only)
    /// Returns true if helper is available (either existing or newly launched)
    public func ensureHelperRunning() async -> Bool {
        let task = ensureLock.withLock {
            if let inFlightEnsure {
                return inFlightEnsure
            }

            let created = Task {
                defer {
                    self.ensureLock.withLock {
                        self.inFlightEnsure = nil
                    }
                }
                return await self.performEnsureHelperRunning()
            }
            inFlightEnsure = created
            return created
        }
        return await task.value
    }

    private func performEnsureHelperRunning() async -> Bool {
        let sp = LaunchSignposts.begin("launch.helper.ensure")
        defer { LaunchSignposts.end("launch.helper.ensure", sp) }

        // First, check if helper is already running and healthy (reuse orphans)
        do {
            try await socketConnection.ping()
            Ghostty.logger.info("Existing helper is healthy, reusing")
            isKnownRunning = true
            return true
        } catch {
            Ghostty.logger.info("Helper not responding: \(error.localizedDescription)")
        }

        // Helper not available - clean up stale sockets before launching
        cleanupStaleSockets()

        // Try to launch (only works in non-sandboxed mode)
        guard launchHelper() else {
            isKnownRunning = false
            return false
        }

        // The helper usually starts in a few milliseconds. Probe promptly,
        // then back off to avoid busy polling on slow machines. Keep the same
        // two-second startup allowance, measured with a monotonic clock.
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(2))
        var retryDelay: Duration = .milliseconds(5)
        repeat {
            try? await Task.sleep(for: min(retryDelay, clock.now.duration(to: deadline)))

            do {
                try await socketConnection.ping()
                Ghostty.logger.info("Newly launched helper is ready after \(String(describing: started.duration(to: clock.now)), privacy: .public)")
                isKnownRunning = true
                return true
            } catch {
                // Check if process died during startup
                if !isHelperProcessRunning() {
                    Ghostty.logger.error("Helper process exited during startup")
                    isKnownRunning = false
                    return false
                }
            }
            retryDelay = min(retryDelay * 2, .milliseconds(100))
        } while clock.now < deadline

        Ghostty.logger.error("Helper launched but not responding after 2s")
        isKnownRunning = false
        return false
    }

    /// Launches the helper binary as a child process using posix_spawn
    /// Only works in non-sandboxed mode; sandboxed apps must run helper externally
    @discardableResult
    public func launchHelper() -> Bool {
        // Only spawn helper if we're NOT sandboxed
        guard !PlatformDetection.isSandboxed else {
            Ghostty.logger.info("Cannot launch helper - app is sandboxed (user must run helper manually)")
            return false
        }

        // Nested code belongs in Contents/Helpers so Xcode can sign it inside-out
        // with the containing app during archive/export.
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/rootshell-helper.app")
            .appendingPathComponent("Contents/MacOS/rootshell-helper")

        let helperPath = helperURL.path

        // Verify helper exists and is executable
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            Ghostty.logger.error("Helper binary is not executable: \(helperPath)")
            return false
        }

        // Build argv array for posix_spawn
        // argv[0] = program name, argv[1..n] = arguments, argv[n+1] = NULL
        let args = [helperPath, "--app-group", AppGroupHelper.groupIdentifier]

        // Convert to C string array
        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)

        // Build MINIMAL environment for helper
        // Don't inherit app's full environment - it contains iOS/Xcode-specific
        // variables that break downstream tools (openssl, python, etc.)
        // The helper's EnvironmentBuilder will construct the shell environment from scratch.
        var envVars: [String: String] = [:]
        if let resourcesDir = Bundle.main.resourceURL?.path {
            envVars["ROOTSHELL_RESOURCES_DIR"] = resourcesDir
        }
        // Minimal PATH for helper binary execution
        envVars["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

        var cEnv = envVars.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        // Spawn the helper process. In Standalone builds, disclaim TCC
        // responsibility so the helper is its own responsible process (TN3179):
        // Local Network prompts and attribution for shell children then keep
        // working even after this app exits and the helper is orphaned.
        var pid: pid_t = 0
        var result: Int32
        var attrs: posix_spawnattr_t?
        if posix_spawnattr_init(&attrs) == 0 {
            #if STANDALONE
            if let disclaim = responsibilityDisclaim {
                let rc = disclaim(&attrs, 1)
                if rc != 0 {
                    Ghostty.logger.warning("responsibility_spawnattrs_setdisclaim failed (rc=\(rc)); spawning without disclaim")
                }
            } else {
                Ghostty.logger.warning("responsibility_spawnattrs_setdisclaim unavailable; spawning without disclaim")
            }
            #endif
            result = posix_spawn(&pid, helperPath, nil, &attrs, &cArgs, &cEnv)
            posix_spawnattr_destroy(&attrs)
        } else {
            result = posix_spawn(&pid, helperPath, nil, nil, &cArgs, &cEnv)
        }

        // Free the C strings
        for ptr in cArgs where ptr != nil { free(ptr) }
        for ptr in cEnv where ptr != nil { free(ptr) }

        if result != 0 {
            Ghostty.logger.error("posix_spawn failed with error: \(result) (\(String(cString: strerror(result))))")
            return false
        }

        helperPID = pid
        Ghostty.logger.info("Launched helper (PID: \(pid)) from \(helperPath)")
        return true
    }

    /// Checks if the helper process we launched is still running
    private func isHelperProcessRunning() -> Bool {
        guard helperPID > 0 else { return false }

        // Check if process exists by sending signal 0
        let result = kill(helperPID, 0)
        return result == 0
    }

    /// Stops the helper process (call on app termination)
    public func stopHelper() {
        guard helperPID > 0, isHelperProcessRunning() else {
            Ghostty.logger.debug("stopHelper: No running helper process to stop")
            return
        }

        let pid = helperPID
        Ghostty.logger.info("Stopping helper process (PID: \(pid))")
        isKnownRunning = false

        // Send SIGTERM first for clean shutdown
        kill(pid, SIGTERM)

        // Give 1 second to clean up, then SIGKILL if still running
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.isHelperProcessRunning() == true {
                Ghostty.logger.warning("Helper didn't respond to SIGTERM, sending SIGKILL")
                kill(pid, SIGKILL)
            }
            self?.helperPID = 0
        }
    }

    /// Cleans up stale socket files from previous helper runs.
    private func cleanupStaleSockets() {
        guard let containerURL = AppGroupHelper.containerURL else {
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: containerURL.path)
            for file in files where file.hasSuffix(".sock") && file != "agent.sock" {
                let socketPath = containerURL.appendingPathComponent(file).path
                Ghostty.logger.debug("Removing stale socket: \(file)")
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        } catch {
            Ghostty.logger.warning("Failed to enumerate App Group container: \(error)")
        }
    }
}

/// Session information (kept for compatibility)
public struct SessionInfo {
    public let sessionID: UUID
    public let isAlive: Bool
    public let exitStatus: Int32

    public init(sessionID: UUID, isAlive: Bool, exitStatus: Int32) {
        self.sessionID = sessionID
        self.isAlive = isAlive
        self.exitStatus = exitStatus
    }
}

#endif // targetEnvironment(macCatalyst)
