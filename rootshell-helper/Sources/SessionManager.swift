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

    init(id: UUID = UUID(), pid: pid_t, clientPID: pid_t = 0, pty: PTYPair, socketPath: String) {
        self.id = id
        self.pid = pid
        self.clientPID = clientPID
        self.pty = pty
        self.socketPath = socketPath
        self.createdAt = Date()
    }

    /// Hangs up the terminal and never waits: closing the master SIGHUPs
    /// login, and the session's exit source reaps it. The session socket is
    /// the app's: FDReceiver binds and unlinks it around the handoff.
    func cleanup() {
        pty.close()
    }
}

/// Manages lifecycle of all shell sessions
class SessionManager {
    static let shared = SessionManager()

    private var sessions: [UUID: ShellSession] = [:]
    private var sessionsByClientPID: [pid_t: Set<UUID>] = [:]  // Track sessions by client app PID
    /// By session. An entry outlives its session until the login is reaped,
    /// so while it exists that session's pid can't have been reused.
    private var exitSources: [UUID: DispatchSourceProcess] = [:]
    private var shuttingDown = false
    private let lock = NSLock()
    private let reapQueue = DispatchQueue(label: "com.kk2.rootshell.helper.reap", qos: .utility)

    private init() {
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

        // Hang up each shell; its exit source reaps it.
        for sessionID in sessionsToRemove {
            _ = killSession(sessionID, signal: SIGHUP)
            removeSession(sessionID)
        }
    }

    // MARK: - Session Management

    /// Adds a new session
    func addSession(_ session: ShellSession) {
        let exitSource = makeExitSource(for: session)
        lock.lock()

        exitSources[session.id] = exitSource
        let refused = shuttingDown
        if !refused {
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
        }

        lock.unlock()

        if refused {
            // Spawned while shutting down: hang up now; shutdown's escalation
            // still covers it. The source isn't active yet, so the pid is ours.
            kill(session.pid, SIGHUP)
            session.cleanup()
        } else {
            NSLog("Added session \(session.id) (shell pid: \(session.pid), client pid: \(session.clientPID))")
        }
        // After insertion: a login that already exited is reaped right away.
        exitSource.activate()
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

        let stillRunning = exitSources[id] != nil
        lock.unlock()

        NSLog("Removing session \(id) (shell pid: \(session.pid), client pid: \(session.clientPID))")
        session.cleanup()
        if stillRunning {
            killIfStillRunning(pid: session.pid, sessionID: id)
        }
    }

    /// Bounded fallback for a login that outlives its signal and hangup.
    private func killIfStillRunning(pid: pid_t, sessionID: UUID) {
        reapQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let unreaped = self.exitSources[sessionID] != nil
            if unreaped {
                kill(pid, SIGKILL)
            }
            self.lock.unlock()
            if unreaped {
                NSLog("Session \(sessionID) (pid \(pid)) outlived its hangup, sent SIGKILL")
            }
        }
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

    var isShuttingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shuttingDown
    }

    /// Hangs up every session, SIGKILLs any login still unreaped after
    /// `grace`, then calls `done` on the reap queue. Never blocks. The app
    /// waits 2 s before SIGKILLing the helper, so keep `grace` well under that.
    func shutdown(grace: TimeInterval = 0.5, then done: @escaping () -> Void) {
        lock.lock()
        guard !shuttingDown else {
            lock.unlock()
            return
        }
        shuttingDown = true
        let allSessions = Array(sessions.values)
        // Under the lock: reap unlists a session before reaping its pid.
        for session in allSessions {
            kill(session.pid, SIGHUP)
        }
        sessions.removeAll()
        sessionsByClientPID.removeAll()
        lock.unlock()

        NSLog("Shutting down \(allSessions.count) session(s)")
        for session in allSessions {
            session.cleanup()
        }

        // Every watched login, including ones already removed and hung up.
        let deadline = DispatchTime.now() + grace
        func escalate() {
            lock.lock()
            let survivors = exitSources.values.map(\.handle)
            let expired = DispatchTime.now() >= deadline
            if expired {
                survivors.forEach { kill($0, SIGKILL) }
            }
            lock.unlock()
            guard survivors.isEmpty || expired else {
                reapQueue.asyncAfter(deadline: .now() + 0.05, execute: escalate)
                return
            }
            if !survivors.isEmpty {
                NSLog("Sent SIGKILL to \(survivors.count) login(s) that outlived their hangup")
            }
            done()
        }
        reapQueue.async(execute: escalate)
    }

    // MARK: - Process Monitoring

    /// Reaps the login when it exits. libdispatch fires `.exit` at once for a
    /// pid that already exited.
    private func makeExitSource(for session: ShellSession) -> DispatchSourceProcess {
        let pid = session.pid
        let sessionID = session.id
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: reapQueue)
        source.setEventHandler { [weak self] in
            self?.reap(pid: pid, sessionID: sessionID)
        }
        return source
    }

    private func reap(pid: pid_t, sessionID: UUID) {
        lock.lock()
        let source = exitSources.removeValue(forKey: sessionID)
        lock.unlock()
        source?.cancel()

        // Unlist before reaping so a listed session's pid can't be reused.
        removeSession(sessionID)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        NSLog("Session \(sessionID) exited with status \(status)")
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
