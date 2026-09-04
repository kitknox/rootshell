//
//  SocketCommandServer.swift
//  rootshell-helper
//
//  Socket-based command server replacing XPC service.
//  Listens on a Unix domain socket in the App Group container for rootshell commands.
//

import Foundation
import Security

private enum HelperPeerTrust {
    /// The app identity this helper will accept, read from our own Info.plist
    /// so both halves track whatever team and org identifier this copy was
    /// built with. The values are substituted at build time from
    /// `Configuration/Identity.xcconfig`; the literals below are a safety net
    /// for a bundle that somehow lost the keys.
    ///
    /// Same requirement as before these became variables: the peer must be the
    /// app, signed by our team under Apple's anchor. `subject.OU` carries the
    /// team ID for Developer ID, Apple Development, and App Store signing
    /// alike, and is nothing an attacker can obtain.
    private static let appRequirement: String = {
        let identifier = plist("RootshellAppBundleIdentifier") ?? "com.kk2.rootshell"
        let team = plist("RootshellDevelopmentTeam") ?? "D97ZME3ET2"
        return "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }()

    private static func plist(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static func isAppClientTrusted(fd: Int32) -> Bool {
        var token = audit_token_t()
        var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) == 0,
              tokenLen == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return false
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData]
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &peer) == errSecSuccess,
              let peer else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(appRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(peer, SecCSFlags(), requirement) == errSecSuccess
    }
}

/// Socket-based command server for rootshell-helper
/// Replaces XPC service which is not available on Mac Catalyst
class SocketCommandServer {
    private var listenSocket: Int32 = -1
    private var isRunning = false
    private var acceptQueue: DispatchQueue
    private var handleQueue: DispatchQueue

    init() {
        self.acceptQueue = DispatchQueue(label: "com.kk2.rootshell.helper.accept", qos: .userInitiated)
        self.handleQueue = DispatchQueue(label: "com.kk2.rootshell.helper.handle", qos: .userInitiated, attributes: .concurrent)
    }

    deinit {
        stop()
    }

    // MARK: - Server Lifecycle

    func start() throws {
        guard !isRunning else {
            NSLog("SocketCommandServer already running")
            return
        }

        guard let socketPath = AppGroupHelper.commandSocketPath else {
            throw SocketServerError.noAppGroupContainer
        }

        // Remove existing socket file if present
        unlink(socketPath)

        // Create socket
        listenSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            throw SocketServerError.socketCreationFailed(errno)
        }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, pathLength)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenSocket, sockaddrPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            close(listenSocket)
            listenSocket = -1
            throw SocketServerError.bindFailed(errno)
        }

        // Owner-only: both peers run as the same uid
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(listenSocket, 5) == 0 else {
            close(listenSocket)
            listenSocket = -1
            throw SocketServerError.listenFailed(errno)
        }

        isRunning = true
        NSLog("SocketCommandServer listening on \(socketPath)")

        // Start accepting connections
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false

        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }

        if let socketPath = AppGroupHelper.commandSocketPath {
            unlink(socketPath)
        }

        NSLog("SocketCommandServer stopped")
    }

    // MARK: - Connection Handling

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning {
                    NSLog("Accept failed: \(errno)")
                }
                continue
            }

            // Handle connection on worker queue
            handleQueue.async { [weak self] in
                self?.handleConnection(clientSocket: clientSocket)
            }
        }
    }

    private func handleConnection(clientSocket: Int32) {
        defer {
            close(clientSocket)
        }

        // Extract client PID using LOCAL_PEERPID (macOS-specific)
        var clientPID: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)

        // SOL_LOCAL = 0, LOCAL_PEERPID = 2 on macOS
        let result = getsockopt(clientSocket, SOL_LOCAL, LOCAL_PEERPID, &clientPID, &pidLen)
        if result != 0 {
            NSLog("Warning: Could not get peer PID: errno=\(errno)")
            clientPID = 0  // Unknown PID - won't be able to monitor for crashes
        }

        guard HelperPeerTrust.isAppClientTrusted(fd: clientSocket) else {
            NSLog("Rejected untrusted command socket peer PID \(clientPID)")
            return
        }

        do {
            // Read request
            let requestData = try SocketMessage.read(from: clientSocket)
            let request = try SocketMessage.decode(requestData, as: SocketRequest.self)

            NSLog("Received command: \(request.command) from PID \(clientPID)")

            // Handle executeCommand specially (needs streaming)
            if request.command == .executeCommand {
                handleExecuteCommand(request, clientSocket: clientSocket)
                return
            }

            // Handle other commands normally
            let response = withHelperPID(handleCommand(request, clientPID: clientPID))

            // Send response
            let responseData = try SocketMessage.encode(response)
            try SocketMessage.write(responseData, to: clientSocket)

        } catch {
            NSLog("Error handling connection: \(error)")

            // Try to send error response
            let errorResponse = SocketResponse(success: false, error: error.localizedDescription, helperPID: getpid())
            if let errorData = try? SocketMessage.encode(errorResponse) {
                try? SocketMessage.write(errorData, to: clientSocket)
            }
        }
    }

    private func withHelperPID(_ response: SocketResponse) -> SocketResponse {
        SocketResponse(
            success: response.success,
            payload: response.payload,
            error: response.error,
            helperPID: getpid()
        )
    }

    // MARK: - Command Handlers

    private func handleCommand(_ request: SocketRequest, clientPID: pid_t) -> SocketResponse {
        switch request.command {
        case .createShell:
            return handleCreateShell(request, clientPID: clientPID)
        case .resizeShell:
            return handleResizeShell(request)
        case .killShell:
            return handleKillShell(request)
        case .ping:
            return SocketResponse(success: true)
        case .executeCommand:
            // Note: executeCommand is handled specially in handleConnection
            // because it needs to stream output before returning
            return SocketResponse(success: false, error: "executeCommand should be handled by handleConnectionWithStreaming")
        }
    }

    private func handleCreateShell(_ request: SocketRequest, clientPID: pid_t) -> SocketResponse {
        guard let payload = request.payload else {
            return SocketResponse(success: false, error: "Missing payload")
        }

        do {
            let createRequest = try JSONDecoder().decode(CreateShellRequest.self, from: payload)

            // Build environment with resources directory from app
            var envConfig = EnvironmentBuilder.Config()
            envConfig.resourcesDir = createRequest.resourcesDir
            envConfig.enableShellIntegration = createRequest.enableShellIntegration
            envConfig.sshAuthSock = createRequest.sshAuthSock
            if let appVersion = createRequest.appVersion {
                envConfig.version = appVersion
            }
            envConfig.versionWithBuild = createRequest.appVersionWithBuild
            envConfig.termType = createRequest.termType
            envConfig.paneToken = createRequest.paneToken

            let envBuilder = EnvironmentBuilder()
            let environment = envBuilder.build(with: envConfig)

            // Create PTY size
            let ptySize = PTYSize(
                rows: createRequest.rows,
                cols: createRequest.cols,
                xpixel: 0,
                ypixel: 0
            )

            // Generate session ID and socket path
            let sessionID = UUID()
            guard let socketPath = SessionManager.generateSocketPath(for: sessionID) else {
                return SocketResponse(success: false, error: "App Group container not available")
            }

            // Create spawn configuration
            let spawnConfig = ShellSpawnConfig()
            spawnConfig.size = ptySize
            spawnConfig.workingDirectory = createRequest.cwd
            spawnConfig.shell = createRequest.shell
            spawnConfig.environment = environment
            spawnConfig.enableShellIntegration = createRequest.enableShellIntegration
            spawnConfig.shellIntegrationPath = EnvironmentBuilder.shellIntegrationDirectory(
                resourcesDir: createRequest.resourcesDir
            )

            // Spawn shell process (creates PTY internally)
            let spawnResult = try ProcessSpawner.spawnShell(with: spawnConfig)
            let pid = spawnResult.pid

            // Create session with the PTY from spawn result and client PID for crash detection
            let session = ShellSession(id: sessionID, pid: pid, clientPID: clientPID, pty: spawnResult.pty, socketPath: socketPath)
            SessionManager.shared.addSession(session)

            // Send response immediately with socket path
            // Catalyst app will create a server socket and wait for us to connect
            NSLog("Sending response to client with socket path: \(socketPath)")
            let response = CreateShellResponse(sessionID: sessionID, socketPath: socketPath)
            let responseData = try JSONEncoder().encode(response)

            // Send the PTY FD to the Catalyst app asynchronously
            // The Catalyst app will have created a server socket by the time we try to connect
            let ptyMasterFD = spawnResult.pty.masterFD  // Capture before async
            DispatchQueue.global(qos: .userInitiated).async {
                // Retry until the Catalyst app has bound the session socket —
                // a one-shot send races app-side restoration at launch.
                var lastError: Error?
                for attempt in 1...20 {
                    do {
                        try FDPassingServerImpl.sendFileDescriptor(
                            ptyMasterFD,
                            toSocketAtPath: socketPath
                        )
                        NSLog("Successfully sent FD to Catalyst app (attempt \(attempt))")
                        return
                    } catch {
                        lastError = error
                        usleep(100_000) // 100ms
                    }
                }
                NSLog("Failed to send file descriptor after 20 attempts: \(String(describing: lastError))")
            }

            return SocketResponse(success: true, payload: responseData)

        } catch {
            NSLog("Failed to create shell: \(error)")
            return SocketResponse(success: false, error: error.localizedDescription)
        }
    }

    private func handleResizeShell(_ request: SocketRequest) -> SocketResponse {
        guard let payload = request.payload else {
            return SocketResponse(success: false, error: "Missing payload")
        }

        do {
            let resizeRequest = try JSONDecoder().decode(ResizeShellRequest.self, from: payload)

            let success = SessionManager.shared.resizeSession(
                resizeRequest.sessionID,
                rows: resizeRequest.rows,
                cols: resizeRequest.cols
            )

            if success {
                return SocketResponse(success: true)
            } else {
                return SocketResponse(success: false, error: "Session not found")
            }

        } catch {
            return SocketResponse(success: false, error: error.localizedDescription)
        }
    }

    private func handleKillShell(_ request: SocketRequest) -> SocketResponse {
        guard let payload = request.payload else {
            return SocketResponse(success: false, error: "Missing payload")
        }

        do {
            let killRequest = try JSONDecoder().decode(KillShellRequest.self, from: payload)

            let success = SessionManager.shared.killSession(killRequest.sessionID)

            if success {
                // Give shell a moment to exit gracefully, then ensure cleanup
                usleep(50_000)  // 50ms
                SessionManager.shared.removeSession(killRequest.sessionID)
                return SocketResponse(success: true)
            } else {
                return SocketResponse(success: false, error: "Session not found")
            }

        } catch {
            return SocketResponse(success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Execute Command (Streaming)

    /// Handles executeCommand with streaming output
    /// Sends ExecuteOutputChunk messages during execution, then ExecuteComplete at the end
    private func handleExecuteCommand(_ request: SocketRequest, clientSocket: Int32) {
        guard let payload = request.payload else {
            sendExecuteError("Missing payload", to: clientSocket)
            return
        }

        do {
            let execRequest = try JSONDecoder().decode(ExecuteCommandRequest.self, from: payload)

            NSLog("Executing command: \(execRequest.command.prefix(100))...")

            // Build custom environment (if provided)
            var customEnv: [String: String]? = nil
            if let env = execRequest.environment, !env.isEmpty {
                customEnv = env
            }

            // Default timeout is 30 seconds
            let timeout = execRequest.timeout ?? 30.0

            // Execute command with streaming output
            do {
                let result = try ProcessExecutor.executeCommand(
                    execRequest.command,
                    workingDirectory: execRequest.workingDirectory,
                    environment: customEnv,
                    timeout: timeout,
                    outputHandler: { [weak self] data, isStderr in
                        // Stream each chunk back to client
                        self?.sendOutputChunk(data, isStderr: isStderr, to: clientSocket)
                    }
                )

                // Send completion message
                let complete = ExecuteComplete(
                    exitCode: result.exitCode,
                    timedOut: result.timedOut,
                    duration: result.duration
                )
                sendExecuteComplete(complete, to: clientSocket)

                NSLog("Command completed: exitCode=\(result.exitCode), timedOut=\(result.timedOut), duration=\(String(format: "%.2f", result.duration))s")
            } catch {
                sendExecuteError("Execution failed: \(error.localizedDescription)", to: clientSocket)
            }

        } catch {
            NSLog("Failed to decode ExecuteCommandRequest: \(error)")
            sendExecuteError("Failed to decode request: \(error.localizedDescription)", to: clientSocket)
        }
    }

    /// Send an output chunk to the client
    private func sendOutputChunk(_ data: Data, isStderr: Bool, to socket: Int32) {
        let chunk = ExecuteOutputChunk(data: data, isStderr: isStderr)

        do {
            // Wrap in SocketResponse with payload
            let chunkData = try JSONEncoder().encode(chunk)
            let response = SocketResponse(success: true, payload: chunkData, helperPID: getpid())
            let responseData = try SocketMessage.encode(response)
            try SocketMessage.write(responseData, to: socket)
        } catch {
            NSLog("Failed to send output chunk: \(error)")
        }
    }

    /// Send the final completion message
    private func sendExecuteComplete(_ complete: ExecuteComplete, to socket: Int32) {
        do {
            let completeData = try JSONEncoder().encode(complete)
            // Use error field to signal completion (distinguishes from chunks)
            let response = SocketResponse(success: true, payload: completeData, error: "complete", helperPID: getpid())
            let responseData = try SocketMessage.encode(response)
            try SocketMessage.write(responseData, to: socket)
        } catch {
            NSLog("Failed to send execute complete: \(error)")
        }
    }

    /// Send an error response
    private func sendExecuteError(_ message: String, to socket: Int32) {
        let response = SocketResponse(success: false, error: message, helperPID: getpid())
        if let responseData = try? SocketMessage.encode(response) {
            try? SocketMessage.write(responseData, to: socket)
        }
    }
}

// MARK: - Errors

enum SocketServerError: Error, LocalizedError {
    case noAppGroupContainer
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noAppGroupContainer:
            return "App Group container not accessible"
        case .socketCreationFailed(let errno):
            return "Failed to create socket: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Failed to bind socket: \(String(cString: strerror(errno)))"
        case .listenFailed(let errno):
            return "Failed to listen on socket: \(String(cString: strerror(errno)))"
        case .acceptFailed(let errno):
            return "Failed to accept connection: \(String(cString: strerror(errno)))"
        }
    }
}
