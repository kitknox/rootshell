//
//  SessionManager.swift
//  rootshell-helper
//
//  Manages multiple concurrent shell sessions
//

import Foundation

/// Represents a single shell session
class ShellSession {
    let id: UUID
    let pid: pid_t
    let clientPID: pid_t  // PID of the Catalyst app that created this session
    let pty: PTYPair
    let socketPath: String
    let createdAt: Date

    var exitStatus: Int32?
    var isAlive: Bool {
        if exitStatus != nil { return false }

        // Use ProcessSpawner helper which handles WIFEXITED/WEXITSTATUS
        // -1 means still running OR error (already reaped)
        let status = ProcessSpawner.wait(forProcess: pid, blocking: false)

        if status >= 0 {
            // Process exited, got valid exit status
            exitStatus = status
            return false
        }

        // status == -1: either still running or already reaped (ECHILD)
        // Try to distinguish by checking if process exists
        if kill(pid, 0) == 0 {
            // Process exists, still running
            return true
        }

        // Process doesn't exist - either reaped or never existed
        // Mark as dead with unknown status
        exitStatus = -1
        return false
    }

    init(id: UUID = UUID(), pid: pid_t, clientPID: pid_t = 0, pty: PTYPair, socketPath: String) {
        self.id = id
        self.pid = pid
        self.clientPID = clientPID
        self.pty = pty
        self.socketPath = socketPath
        self.createdAt = Date()
    }

    func cleanup() {
        // Close PTY first - this may send SIGHUP to the shell
        pty.close()

        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Reap the process - must ensure no zombie is left behind
        guard exitStatus == nil else {
            // Already reaped via isAlive check
            return
        }

        var status: Int32 = 0

        // Try non-blocking first
        var result = waitpid(pid, &status, WNOHANG)

        if result == 0 {
            // Still running - give it a moment to exit after PTY close
            usleep(100_000)  // 100ms
            result = waitpid(pid, &status, WNOHANG)
        }

        if result == 0 {
            // Still running - force kill and block until reaped
            kill(pid, SIGKILL)
            result = waitpid(pid, &status, 0)  // Blocking wait
        }

        // Mark as reaped (actual status extraction not critical here)
        exitStatus = (result > 0) ? 0 : -1
    }
}

/// Manages lifecycle of all shell sessions
class SessionManager {
    static let shared = SessionManager()

    private var sessions: [UUID: ShellSession] = [:]
    private var sessionsByClientPID: [pid_t: Set<UUID>] = [:]  // Track sessions by client app PID
    private let lock = NSLock()
    private var monitorTimer: Timer?

    /// Callback for when a session exits
    var onSessionExit: ((UUID, Int32) -> Void)?

    private init() {
        // Start monitoring timer for process exits
        startMonitoring()
        // Set up client crash/exit detection
        setupClientMonitoring()
    }

    /// Set up callback for when client apps exit
    private func setupClientMonitoring() {
        ClientMonitor.shared.onClientExit = { [weak self] clientPID in
            self?.handleClientExit(clientPID)
        }
    }

    /// Handle client app exit - clean up all sessions for that client
    private func handleClientExit(_ clientPID: pid_t) {
        lock.lock()
        guard let sessionIDs = sessionsByClientPID[clientPID] else {
            lock.unlock()
            return
        }
        // Copy to avoid mutation during iteration
        let sessionsToRemove = Array(sessionIDs)
        lock.unlock()

        NSLog("Client PID \(clientPID) exited, cleaning up \(sessionsToRemove.count) session(s)")

        // Send SIGHUP to all shells first
        for sessionID in sessionsToRemove {
            _ = killSession(sessionID, signal: SIGHUP)
        }

        // Brief delay to allow shells to exit gracefully
        usleep(50_000)  // 50ms

        // Now clean up all sessions - cleanup() will ensure reaping
        for sessionID in sessionsToRemove {
            removeSession(sessionID)
        }
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Session Management

    /// Adds a new session
    func addSession(_ session: ShellSession) {
        lock.lock()
        defer { lock.unlock() }

        sessions[session.id] = session

        // Track by client PID if available
        if session.clientPID > 0 {
            if sessionsByClientPID[session.clientPID] == nil {
                sessionsByClientPID[session.clientPID] = Set()
            }
            sessionsByClientPID[session.clientPID]?.insert(session.id)

            // Start monitoring this client PID for crashes
            ClientMonitor.shared.monitorClient(session.clientPID)
        }

        NSLog("Added session \(session.id) (shell pid: \(session.pid), client pid: \(session.clientPID))")
    }

    /// Gets a session by ID
    func getSession(_ id: UUID) -> ShellSession? {
        lock.lock()
        defer { lock.unlock() }

        return sessions[id]
    }

    /// Removes and cleans up a session
    func removeSession(_ id: UUID) {
        lock.lock()

        guard let session = sessions.removeValue(forKey: id) else {
            lock.unlock()
            return
        }

        // Remove from client PID tracking
        if session.clientPID > 0 {
            sessionsByClientPID[session.clientPID]?.remove(id)

            // If no more sessions for this client, stop monitoring their PID
            if sessionsByClientPID[session.clientPID]?.isEmpty == true {
                sessionsByClientPID.removeValue(forKey: session.clientPID)
                ClientMonitor.shared.stopMonitoring(session.clientPID)
            }
        }

        lock.unlock()

        NSLog("Removing session \(id) (shell pid: \(session.pid), client pid: \(session.clientPID))")
        session.cleanup()
    }

    /// Lists all active session IDs
    func listSessions() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }

        return Array(sessions.keys)
    }

    /// Gets count of active sessions
    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }

        return sessions.count
    }

    /// Resizes a session's PTY
    func resizeSession(_ id: UUID, rows: UInt16, cols: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let session = sessions[id] else {
            return false
        }

        let size = PTYSize(rows: rows, cols: cols, xpixel: 0, ypixel: 0)
        do {
            try PTYManagerImpl.resizePTY(session.pty.masterFD, size: size)
            return true
        } catch {
            NSLog("Failed to resize PTY: \(error)")
            return false
        }
    }

    /// Sends a signal to a session's process
    func killSession(_ id: UUID, signal: Int32 = SIGTERM) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let session = sessions[id] else {
            return false
        }

        NSLog("Sending signal \(signal) to session \(id) (pid: \(session.pid))")
        do {
            try ProcessSpawner.killProcess(session.pid, signal: signal)
            return true
        } catch {
            NSLog("Failed to kill process: \(error)")
            return false
        }
    }

    /// Cleanup all sessions (called on shutdown)
    func cleanup() {
        lock.lock()
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        NSLog("Cleaning up \(allSessions.count) sessions")

        // Send SIGHUP to all shells first
        for session in allSessions {
            try? ProcessSpawner.killProcess(session.pid, signal: SIGHUP)
        }

        // Brief delay to allow shells to exit gracefully
        usleep(100_000)  // 100ms

        // Now cleanup all sessions - this will ensure zombies are reaped
        for session in allSessions {
            session.cleanup()
        }
    }

    // MARK: - Process Monitoring

    private func startMonitoring() {
        // Check for exited processes every 1 second
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForExitedProcesses()
        }
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func checkForExitedProcesses() {
        lock.lock()
        let currentSessions = Array(sessions.values)
        lock.unlock()

        for session in currentSessions {
            if !session.isAlive, let exitStatus = session.exitStatus {
                NSLog("Session \(session.id) exited with status \(exitStatus)")

                // Notify callback
                onSessionExit?(session.id, exitStatus)

                // Remove from active sessions
                removeSession(session.id)
            }
        }
    }

    // MARK: - Socket Path Generation

    /// Generates a unique socket path in the App Group container.
    static func generateSocketPath(for sessionID: UUID) -> String? {
        guard let path = AppGroupHelper.sessionSocketPath(for: sessionID) else {
            NSLog("Error: App Group container not available - cannot create session socket")
            return nil
        }
        return path
    }
}
