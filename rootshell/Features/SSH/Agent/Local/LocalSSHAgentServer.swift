#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import Darwin
import os
import os.log

final class LocalSSHAgentServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.rootshell", category: "LocalAgentServer")
    private let manager: LocalSSHAgentManager
    private let stateLock = OSAllocatedUnfairLock(initialState: ServerState())
    private let maxConnections = 32

    private struct ServerState {
        var running = false
        var listenFD: Int32 = -1
        var activeConnections = 0
        var rebindRequested = false
    }

    init(manager: LocalSSHAgentManager) {
        self.manager = manager
    }

    func start(path: String) {
        let shouldStart = stateLock.withLock { state -> Bool in
            guard !state.running else { return false }
            state.running = true
            return true
        }
        guard shouldStart else { return }

        let thread = Thread { [weak self] in
            self?.serverLoop(path: path)
        }
        thread.name = "rootshell-local-ssh-agent-accept"
        thread.start()
    }

    func stop(unlinkPath path: String?) {
        let fd = stateLock.withLock { state -> Int32 in
            state.running = false
            let fd = state.listenFD
            state.listenFD = -1
            return fd
        }
        if fd >= 0 {
            close(fd)
        }
        if let path {
            unlink(path)
        }
    }

    private func serverLoop(path: String) {
        while isRunning {
            guard let fd = bindListeningSocket(path: path) else {
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            stateLock.withLock { state in
                state.listenFD = fd
                state.rebindRequested = false
            }

            let watchdog = Thread { [weak self] in
                self?.watchdogLoop(path: path, fd: fd)
            }
            watchdog.name = "rootshell-local-ssh-agent-watchdog"
            watchdog.start()

            while isRunning {
                let client = accept(fd, nil, nil)
                if client >= 0 {
                    guard reserveConnectionSlot() else {
                        close(client)
                        continue
                    }
                    let thread = Thread { [weak self] in
                        self?.handleConnection(fd: client)
                    }
                    thread.name = "rootshell-local-ssh-agent-client"
                    thread.start()
                    continue
                }
                if errno == EINTR { continue }
                break
            }

            let cleanup = stateLock.withLock { state -> (shouldClose: Bool, wasRebind: Bool) in
                let wasRebind = state.rebindRequested
                let shouldClose = state.listenFD == fd
                if shouldClose {
                    state.listenFD = -1
                }
                state.rebindRequested = false
                return (shouldClose, wasRebind)
            }
            if cleanup.shouldClose && !cleanup.wasRebind {
                close(fd)
            }
        }
    }

    private var isRunning: Bool {
        stateLock.withLock { $0.running }
    }

    private func bindListeningSocket(path: String) -> Int32? {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed errno=\(errno)")
            return nil
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let copied = path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strlcpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, cap)
            }
        }
        guard copied < cap else {
            logger.error("agent socket path too long")
            close(fd)
            return nil
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            logger.error("bind() failed errno=\(errno)")
            close(fd)
            return nil
        }

        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            logger.error("listen() failed errno=\(errno)")
            close(fd)
            return nil
        }

        logger.info("local SSH agent listening at \(path, privacy: .public)")
        return fd
    }

    private func watchdogLoop(path: String, fd: Int32) {
        while isRunning {
            Thread.sleep(forTimeInterval: 5)
            guard isRunning else { return }
            guard access(path, F_OK) != 0 else { continue }
            let shouldClose = stateLock.withLock { state -> Bool in
                guard state.listenFD == fd, !state.rebindRequested else { return false }
                state.rebindRequested = true
                return true
            }
            if shouldClose {
                logger.error("agent socket path deleted externally; rebinding")
                close(fd)
                return
            }
        }
    }

    private func reserveConnectionSlot() -> Bool {
        stateLock.withLock { state -> Bool in
            guard state.activeConnections < maxConnections else { return false }
            state.activeConnections += 1
            return true
        }
    }

    private func releaseConnectionSlot() {
        stateLock.withLock { state in
            state.activeConnections = max(0, state.activeConnections - 1)
        }
    }

    private func handleConnection(fd: Int32) {
        defer {
            close(fd)
            releaseConnectionSlot()
        }

        let peer = LocalAgentPeerResolver.resolve(fd: fd)
        var sessionBinds = LocalAgentSessionBinds()
        var boundDestination: LocalAgentBoundDestination?
        var cachedGate: LocalAgentClientGateDecision?

        while let frame = SSHAgentWireCodec.readFrame(fd: fd) {
            let request = SSHAgentWireCodec.parse(frame: frame)
            if case .sessionBind(let hostKeyBlob, let sessionID, let signature, let forwarding) = request {
                guard sessionBinds.record(hostKeyBlob: hostKeyBlob, sessionID: sessionID, signature: signature, isForwarding: forwarding) else {
                    logger.warning("Refused session-bind: bad signature, rebind after authentication, or too many binds")
                    SSHAgentWireCodec.writeFrame(fd: fd, frame: SSHAgentWireCodec.failureFrame)
                    continue
                }
                if boundDestination == nil, let first = sessionBinds.first {
                    let sem = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var destination: LocalAgentBoundDestination?
                    Task { @MainActor in
                        destination = LocalSSHAgentManager.shared.makeBoundDestination(
                            hostKeyBlob: first.hostKeyBlob,
                            isForwarding: first.isForwarding
                        )
                        sem.signal()
                    }
                    sem.wait()
                    boundDestination = destination
                }
            }

            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var response = SSHAgentWireCodec.failureFrame
            nonisolated(unsafe) var updatedGate: LocalAgentClientGateDecision?
            let destinationForRequest = boundDestination
            let cachedGateForRequest = cachedGate
            Task { @MainActor in
                let result = await self.manager.handle(
                    request: request,
                    peer: peer,
                    destination: destinationForRequest,
                    cachedGate: cachedGateForRequest
                )
                response = result.frame
                updatedGate = result.clientGate
                sem.signal()
            }
            sem.wait()
            cachedGate = updatedGate
            SSHAgentWireCodec.writeFrame(fd: fd, frame: response)
        }
    }
}

#endif
