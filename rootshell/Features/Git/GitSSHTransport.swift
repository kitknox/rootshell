#if !targetEnvironment(macCatalyst)

import Foundation
import NIOCore
import NIOSSH
@preconcurrency import Citadel
import OSLog

// MARK: - Connection Override

/// Overrides automatic SSH credential resolution for git operations.
/// Set before starting a git command; cleared after completion.
enum GitConnectionOverride: @unchecked Sendable {
    case key(UUID)              // --ssh-key: force specific key, direct connection
    case password(String)       // --password: force password, direct connection
    case profile(SSHConfig)     // --profile: full config (auth + optional jump host)

    /// Thread-local key for passing override from GitCommand's queue to the
    /// subtransport context created by libgit2's factory callback.
    /// Set on the commandQueue thread before libgit2 runs; read in
    /// `gitSSHSwiftCreateSubtransportCtx()` on the same thread.
    private static let threadLocalKey = "GitConnectionOverride"

    /// Set the override for the current thread (call from GitCommand's commandQueue).
    static func setForCurrentThread(_ override: GitConnectionOverride?) {
        Thread.current.threadDictionary[threadLocalKey] = override
    }

    /// Consume (read + clear) the override for the current thread.
    static func consumeForCurrentThread() -> GitConnectionOverride? {
        let value = Thread.current.threadDictionary[threadLocalKey] as? GitConnectionOverride
        Thread.current.threadDictionary.removeObject(forKey: threadLocalKey)
        return value
    }
}

// MARK: - Subtransport Context

/// Manages a single SSH connection for git protocol operations.
/// Owned by the C `ssh_subtransport` struct; freed via `git_ssh_swift_subtransport_free`.
nonisolated final class GitSSHSubtransportContext: @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.kk2.rootshell", category: "GitSSH")

    /// Per-instance connection override, snapshotted from thread-local at creation time.
    /// This ensures concurrent git operations from different tabs use their own overrides.
    var connectionOverride: GitConnectionOverride?

    /// SSH client connection
    var sshClient: SSHClient?

    /// Jump host SSH client (when using --profile with jump host)
    var jumpClient: SSHClient?

    /// NIO channel for writing to SSH stdin
    var channel: (any Channel)?

    /// Pipe for reading: SSH stdout → pipe write end → pipe read end → libgit2
    var readPipeRead: Int32 = -1

    /// Async task draining SSH output to the read pipe
    var readTask: Task<Void, Never>?

    /// Whether an SSH connection is currently active
    var isConnected: Bool { channel != nil }

    /// Track which service is active to detect reuse
    var currentService: Int32 = 0

    /// Drain all bytes to the pipe, retrying short writes and EINTR.
    /// The write fd is owned exclusively by the drain task for one connection.
    private static func writeAll(to fd: Int32, bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0, let baseAddress = bytes.baseAddress else { return }

        var written = 0
        while written < bytes.count {
            let pointer = baseAddress.advanced(by: written)
            let remaining = bytes.count - written
            let result = Darwin.write(fd, pointer, remaining)

            if result > 0 {
                written += result
                continue
            }

            if result < 0 && errno == EINTR {
                continue
            }

            break
        }
    }

    // MARK: - Connect

    /// Establish SSH connection and execute the git command.
    /// Called synchronously from the C `action` callback via semaphore.
    func connect(host: String, port: Int, username: String, gitCommand: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var connectError: Error?

        Self.logger.info("Git SSH connecting to \(host):\(port) as \(username), cmd: \(gitCommand)")

        Task.detached {
            do {
                // Resolve SSH credentials on MainActor
                Self.logger.debug("Resolving SSH credentials...")
                let authMethod = try await Self.resolveAuthMethod(username: username, host: host, port: port, override: self.connectionOverride)
                Self.logger.debug("SSH credentials resolved")

                // Connect to SSH server
                Self.logger.debug("Connecting TCP to \(host):\(port)...")
                // Validate host key against known hosts (non-interactive: auto-accept
                // known hosts, reject unknown ones — user must SSH interactively first)
                let hostKeyValidator = await SSHConnectionHelper.buildHostKeyValidator(
                    for: host, port: port, label: "[Git]",
                    onValidation: { request in
                        // For git operations we can't prompt the user.
                        // Known hosts with matching keys are already accepted
                        // inside CitadelHostKeyValidatorDelegate before this callback
                        // is reached, so arriving here means it's either unknown or changed.
                        Self.logger.warning("Host key not in known hosts for \(host):\(port). SSH to this host interactively first.")
                        return .reject
                    }
                )

                // Check if --profile override has a jump host
                let client: SSHClient
                if case .profile(let profileConfig) = self.connectionOverride,
                   let jumpConfig = profileConfig.jumpHost {
                    // Connect through jump host
                    Self.logger.info("Connecting via jump host \(jumpConfig.host):\(jumpConfig.port)")
                    let jumpAuth = try await SSHConnectionHelper.buildAuthMethod(for: jumpConfig)
                    let jumpValidator = await SSHConnectionHelper.buildHostKeyValidator(
                        for: jumpConfig.host, port: jumpConfig.port, label: "[Git-Jump]",
                        onValidation: { request in
                            Self.logger.warning("Jump host key not in known hosts for \(jumpConfig.host):\(jumpConfig.port). SSH interactively first.")
                            return .reject
                        }
                    )
                    // Pre-resolve jump host to CGNAT IPv4 and route through
                    // MPTCPBootstrap so the TCP setup goes via NWConnection
                    // (POSIX races Tailscale's DERP setup for NAT'd peers).
                    let jumpConnectHost: String
                    if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpConfig.host) {
                        jumpConnectHost = cgnatIP
                    } else {
                        jumpConnectHost = jumpConfig.host
                    }
                    let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
                        host: jumpConnectHost, port: jumpConfig.port
                    )
                    var jumpSettings = SSHClientSettings(
                        host: jumpConnectHost, port: jumpConfig.port,
                        authenticationMethod: { jumpAuth },
                        hostKeyValidator: jumpValidator
                    )
                    jumpSettings.algorithms = .all
                    jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                    jumpSettings.protocolOptions = await SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpConfig.host)

                    let jumpClient: SSHClient
                    do {
                        jumpClient = try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
                    } catch {
                        try? await jumpChannel.close()
                        throw error
                    }
                    self.jumpClient = jumpClient
                    Self.logger.debug("Jump host connected, tunneling to \(host):\(port)")

                    var targetSettings = SSHClientSettings(
                        host: host, port: port,
                        authenticationMethod: { authMethod },
                        hostKeyValidator: hostKeyValidator
                    )
                    targetSettings.algorithms = .all
                    targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                    targetSettings.protocolOptions = await SSHConnectionHelper.hostCertificateProtocolOptions(forHost: host)

                    client = try await jumpClient.jump(to: targetSettings)
                } else {
                    // Direct connection: pre-resolve CGNAT IPv4 and route
                    // through NWConnection so Tailscale's NAT/DERP path is
                    // set up before the first SYN (POSIX path is racy here).
                    let connectHost: String
                    if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: host) {
                        connectHost = cgnatIP
                    } else {
                        connectHost = host
                    }
                    let directChannel = try await MPTCPBootstrap.connectPlainChannel(
                        host: connectHost, port: port
                    )
                    var settings = SSHClientSettings(
                        host: connectHost,
                        port: port,
                        authenticationMethod: { authMethod },
                        hostKeyValidator: hostKeyValidator
                    )
                    settings.algorithms = .all
                    settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                    settings.protocolOptions = await SSHConnectionHelper.hostCertificateProtocolOptions(forHost: host)

                    do {
                        client = try await SSHClient.connect(on: directChannel, settings: settings)
                    } catch {
                        try? await directChannel.close()
                        throw error
                    }
                }
                self.sshClient = client
                Self.logger.debug("SSH handshake complete")

                // Execute git command with bidirectional I/O
                Self.logger.debug("Executing: \(gitCommand)")
                let (channel, outputStream) = try await client.executeCommandBidirectional(gitCommand)
                self.channel = channel
                Self.logger.debug("SSH exec channel opened")

                // Set up pipe for read bridging
                var pipeFds: [Int32] = [0, 0]
                guard pipe(&pipeFds) == 0 else {
                    throw GitError.libgit2(code: -1, message: "pipe() failed", detail: String(cString: strerror(errno)), extra: nil)
                }
                self.readPipeRead = pipeFds[0]
                // Avoid SIGPIPE termination if close() tears down the read end
                // while the drain task is still unwinding a pending write.
                _ = fcntl(pipeFds[1], F_SETNOSIGPIPE, 1)

                // Start task that drains SSH stdout to the pipe.
                // The task exclusively owns the write fd for this connection.
                // close() never closes it directly, so a stale task cannot
                // accidentally target a recycled descriptor from a later connection.
                let writeFd = pipeFds[1]
                self.readTask = Task.detached {
                    do {
                        for try await event in outputStream {
                            switch event {
                            case .stdout(let buffer):
                                buffer.withUnsafeReadableBytes { bytes in
                                    Self.writeAll(to: writeFd, bytes: bytes)
                                }
                            case .stderr(let buffer):
                                if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                                    Self.logger.debug("SSH stderr: \(str)")
                                }
                            case .exitStatus(let code):
                                Self.logger.debug("SSH command exited with status \(code)")
                            }
                        }
                    } catch {
                        let msg = error.localizedDescription
                        Self.logger.debug("SSH stream ended: \(msg)")
                    }
                    // The drain task is the sole owner of the write fd.
                    Darwin.close(writeFd)
                }

                semaphore.signal()
            } catch {
                connectError = error
                semaphore.signal()
            }
        }

        semaphore.wait()

        if let error = connectError {
            let fullError = String(describing: error)
            Self.logger.error("SSH connect failed: \(fullError)")
            // Provide a human-readable message instead of raw NIO error types
            let msg: String
            if fullError.contains("HostKeyRejected") || fullError.contains("hostKeyValidation") {
                msg = "Host key for \(host):\(port) is not in known hosts. SSH to this host interactively first to trust the key."
            } else if fullError.contains("NIOConnectionError") {
                msg = "SSH connection to \(host):\(port) failed (connection refused or unreachable)"
            } else if fullError.contains("channelCreationFailed") {
                msg = "SSH connected to \(host) but failed to open exec channel"
            } else if fullError.contains("AuthenticationFailed") || fullError.contains("authenticationFailed") {
                msg = "SSH authentication failed for \(username)@\(host)"
            } else {
                msg = "SSH error connecting to \(host):\(port): \(error.localizedDescription)"
            }
            git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), msg)
            throw error
        }
    }

    // MARK: - Stream I/O

    /// Read from the SSH channel (called from C, blocks until data available).
    func read(buffer: UnsafeMutablePointer<CChar>, size: Int, bytesRead: UnsafeMutablePointer<Int>) -> Int32 {
        guard readPipeRead >= 0 else {
            bytesRead.pointee = 0
            return -1
        }
        let n = Darwin.read(readPipeRead, buffer, size)
        if n < 0 {
            git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "read() failed: \(String(cString: strerror(errno)))")
            return -1
        }
        bytesRead.pointee = n
        return 0
    }

    /// Write to the SSH channel (called from C, synchronous via NIO event loop).
    func write(buffer: UnsafePointer<CChar>, len: Int) -> Int32 {
        guard let channel else {
            git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "SSH channel not connected")
            return -1
        }

        var buf = channel.allocator.buffer(capacity: len)
        buf.writeBytes(UnsafeRawBufferPointer(start: buffer, count: len))
        let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buf))

        do {
            try channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
                channel.writeAndFlush(sshData)
            }.wait()
            return 0
        } catch {
            let msg = error.localizedDescription
            Self.logger.error("SSH write failed: \(msg)")
            git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "SSH write failed: \(msg)")
            return -1
        }
    }

    // MARK: - Cleanup

    /// Close the SSH connection (subtransport close).
    func close() {
        let task = readTask
        readTask = nil
        task?.cancel()

        // Close libgit2's read end first. If the drain task is blocked because
        // the pipe filled after libgit2 stopped consuming output, this causes
        // the blocked write to fail and lets the task unwind.
        if readPipeRead >= 0 {
            Darwin.close(readPipeRead)
            readPipeRead = -1
        }

        // Close channel first — terminates the SSH output stream, which
        // unblocks the drain task's for-await loop and lets it exit.
        if let channel {
            try? channel.eventLoop.flatSubmit {
                channel.close()
            }.wait()
            self.channel = nil
        }

        // Wait for the drain task to fully exit. The channel close above
        // causes the output stream to end, so the task should finish promptly.
        // This ensures no stale drain task remains active after we return.
        if let task {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await task.value
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + .seconds(2))
            if result == .timedOut {
                Self.logger.warning("Drain task did not exit within 2s timeout")
            }
        }

        if let client = sshClient {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                try? await client.close()
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + .seconds(3))
            if result == .timedOut {
                Self.logger.warning("SSH client close did not complete within 3s timeout")
            }
            sshClient = nil
        }

        if let jumpClient {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                try? await jumpClient.close()
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + .seconds(3))
            if result == .timedOut {
                Self.logger.warning("Jump host client close did not complete within 3s timeout")
            }
            self.jumpClient = nil
        }

        currentService = 0
    }

    deinit {
        close()
    }

    // MARK: - Credential Resolution

    @MainActor
    private static func resolveAuthMethod(username: String, host: String, port: Int, override: GitConnectionOverride?) async throws -> SSHAuthenticationMethod {
        // 0. Check for explicit CLI override (--ssh-key, --password, --profile)
        if let override {
            switch override {
            case .key(let keyID):
                Self.logger.info("Using --ssh-key override for \(host)")
                return try await SSHConnectionHelper.buildAuthMethod(username: username, authMethod: .key(keyID))
            case .password(let password):
                Self.logger.info("Using --password override for \(host)")
                return .passwordBased(username: username, password: password)
            case .profile(let config):
                // Use the profile's auth method but with the git remote's username.
                // Git remotes specify their own username (e.g., "git" for GitHub),
                // which must be used for SSH auth regardless of the profile's username.
                Self.logger.info("Using --profile override for \(host)")
                return try await SSHConnectionHelper.buildAuthMethod(username: username, authMethod: config.authMethod)
            }
        }

        // 1. Check saved connection profiles first — profiles are intentional user
        //    configuration and take precedence over auto-recorded history. A profile
        //    explicitly set to .none must not be overridden by a stale history entry
        //    that still says .key or .savedPassword.
        //    Match on host (case-insensitive) + port + username, direct only.
        let matchingProfile = ConnectionProfileManager.shared.profiles.first { profile in
            profile.sshConfig.username.lowercased() == username.lowercased() &&
            profile.sshConfig.host.lowercased() == host.lowercased() &&
            profile.sshConfig.port == port &&
            profile.sshConfig.jumpHost == nil
        }

        if let profile = matchingProfile {
            switch profile.sshConfig.authMethod {
            case .none:
                Self.logger.info("Profile match for \(host): using 'none' auth")
                return .custom(NoneAuthDelegate(username: username))
            case .key(let keyID):
                Self.logger.info("Profile match for \(host): using key auth")
                return try await SSHConnectionHelper.buildAuthMethod(
                    username: username, authMethod: .key(keyID)
                )
            case .savedPassword:
                Self.logger.info("Profile match for \(host): using saved password")
                let password = try await SSHPasswordManager.shared.loadPassword(
                    host: host, port: port, username: username
                )
                return .passwordBased(username: username, password: password)
            case .password:
                // Empty/ephemeral password in profile — fall through to history/keys
                break
            case .keyboardInteractive, .unknown:
                // git transport can't drive interactive auth — fall through to history/keys.
                break
            }
        }

        // 2. Check connection history for this exact direct connection.
        //    Match on username + host (both case-insensitive) + port, direct only
        //    (no jump host). Any protocol (ssh, mosh, trzsz) records valid auth
        //    credentials for the underlying SSH transport that git will use.
        let historyEntry = SSHConnectionHistoryManager.shared.entries.first { entry in
            entry.username.lowercased() == username.lowercased() &&
            entry.host.lowercased() == host.lowercased() &&
            entry.port == port &&
            entry.jumpHost == nil
        }

        if let entry = historyEntry {
            switch entry.authType {
            case .none:
                return .custom(NoneAuthDelegate(username: username))
            case .key(_, _):
                // Use ConnectionKeyResolver for full cross-device resolution
                // (device overrides, fingerprint fallback, hint strategies)
                if let resolved = ConnectionKeyResolver.resolveFromHistory(
                    authType: entry.authType,
                    hints: entry.keyResolutionHints,
                    connectionIdentity: entry.connectionIdentity
                ) {
                    return try await SSHConnectionHelper.buildAuthMethod(
                        username: username, authMethod: .key(resolved.id)
                    )
                }
            case .savedPassword:
                // Load saved password from Keychain (may trigger biometric prompt).
                // Propagate errors — canceling biometric or stale Keychain state
                // should surface as the real issue, not fall through to key auth.
                let password = try await SSHPasswordManager.shared.loadPassword(
                    host: host, port: port, username: username
                )
                return .passwordBased(username: username, password: password)
            case .password:
                // Ephemeral password — can't replay, fall through to default keys
                break
            case .keyboardInteractive, .unknown:
                // git transport can't drive interactive auth — fall through to default keys.
                break
            }
        }

        // 3. Try default SSH keys
        if let firstKeyID = SSHKeyManager.shared.defaultKeyIDs.first {
            return try await SSHConnectionHelper.buildAuthMethod(
                username: username, authMethod: .key(firstKeyID)
            )
        }

        // 4. No keys configured — try 'none' auth as a last resort.
        //    This covers Tailscale/WireGuard hosts that use 'none' auth
        //    but don't yet have a connection history entry or profile.
        Self.logger.info("No SSH keys configured, attempting 'none' auth for \(host)")
        return .custom(NoneAuthDelegate(username: username))
    }
}

// MARK: - URL Parsing

/// Parse an SSH URL into components.
/// Handles both formats:
///   - ssh://[user@]host[:port]/path
///   - [user@]host:path  (SCP-style, used by libgit2 for git@host:path URLs)
private func parseSSHURL(_ url: String) -> (host: String, port: Int, username: String, path: String)? {
    let isSshScheme = url.hasPrefix("ssh://")

    var remainder = url
    if isSshScheme {
        remainder = String(remainder.dropFirst(6))
    }

    // Isolate the authority (user + host + optional port) from the path BEFORE
    // splitting user@host, so a stray `@` inside the path (e.g. `/org/repo@mirror.git`)
    // can never be mistaken for the user/host boundary.
    let authority: String
    let path: String
    if isSshScheme {
        // ssh://[user@]host[:port]/path — path begins at the first '/'.
        guard let slashIndex = remainder.firstIndex(of: "/") else { return nil }
        authority = String(remainder[remainder.startIndex..<slashIndex])
        path = String(remainder[slashIndex...])
    } else {
        // SCP-style [user@]host:path — the first ':' separates authority from path.
        // SCP-style has no port, so the first ':' is unambiguous.
        // Pass the path through as-is. OpenSSH sends the exact string after
        // the colon to git-upload-pack/git-receive-pack on the remote side.
        // GitHub and other hosted Git services expect the bare relative path
        // (e.g. "user/repo.git"), not an absolute or tilde-prefixed path.
        guard let colonIndex = remainder.firstIndex(of: ":") else { return nil }
        authority = String(remainder[remainder.startIndex..<colonIndex])
        path = String(remainder[remainder.index(after: colonIndex)...])
    }

    // Extract username from the authority only (split on LAST @ so
    // usernames containing @ — e.g. Active-Directory-style user@domain — survive).
    var username = "git"
    var hostAndPort = authority
    if let atIndex = authority.lastIndex(of: "@") {
        username = String(authority[authority.startIndex..<atIndex])
        hostAndPort = String(authority[authority.index(after: atIndex)...])
    }

    let host: String
    var port = 22
    if isSshScheme,
       let colonIndex = hostAndPort.lastIndex(of: ":"),
       let portNum = Int(hostAndPort[hostAndPort.index(after: colonIndex)...]) {
        host = String(hostAndPort[hostAndPort.startIndex..<colonIndex])
        port = portNum
    } else {
        host = hostAndPort
    }

    return (host: host, port: port, username: username, path: path)
}

/// Determine the git command to execute based on the service type.
private func gitCommandForService(_ service: Int32, path: String) -> String {
    let quotedPath = LoginShellCommand.singleQuoted(path)
    switch service {
    case 1, 2:  // GIT_SERVICE_UPLOADPACK_LS, GIT_SERVICE_UPLOADPACK
        return "git-upload-pack \(quotedPath)"
    case 3, 4:  // GIT_SERVICE_RECEIVEPACK_LS, GIT_SERVICE_RECEIVEPACK
        return "git-receive-pack \(quotedPath)"
    default:
        return "git-upload-pack \(quotedPath)"
    }
}

/// Whether this service is a "list" (LS) operation that requires a new connection.
private func isLSService(_ service: Int32) -> Bool {
    return service == 1 || service == 3  // UPLOADPACK_LS or RECEIVEPACK_LS
}

// MARK: - @_cdecl Swift Callbacks (called from C bridge)

@_cdecl("git_ssh_swift_create_subtransport_ctx")
func gitSSHSwiftCreateSubtransportCtx() -> UnsafeMutableRawPointer? {
    let ctx = GitSSHSubtransportContext()
    // Snapshot the thread-local override set by GitCommand before libgit2 ran.
    // This ensures each subtransport instance uses the override intended for it,
    // even when multiple tabs run concurrent git operations.
    ctx.connectionOverride = GitConnectionOverride.consumeForCurrentThread()
    return Unmanaged.passRetained(ctx).toOpaque()
}

@_cdecl("git_ssh_swift_action")
func gitSSHSwiftAction(
    ctx: UnsafeMutableRawPointer,
    url: UnsafePointer<CChar>,
    service: Int32
) -> Int32 {
    let logger = Logger(subsystem: "com.kk2.rootshell", category: "GitSSH")
    let context = Unmanaged<GitSSHSubtransportContext>.fromOpaque(ctx).takeUnretainedValue()
    let urlStr = String(cString: url)

    logger.info("SSH action: service=\(service) url=\(urlStr)")

    // For non-LS services, reuse the existing connection
    if !isLSService(service) && context.isConnected {
        context.currentService = service
        return 0
    }

    // Close any existing connection before establishing a new one
    if context.isConnected {
        context.close()
    }

    // Parse the URL
    guard let parsed = parseSSHURL(urlStr) else {
        git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "Failed to parse SSH URL: \(urlStr)")
        return -1
    }

    let gitCmd = gitCommandForService(service, path: parsed.path)
    context.currentService = service

    do {
        try context.connect(
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            gitCommand: gitCmd
        )
        return 0
    } catch {
        return -1  // Error already set via git_error_set_str in connect()
    }
}

@_cdecl("git_ssh_swift_stream_read")
func gitSSHSwiftStreamRead(
    ctx: UnsafeMutableRawPointer,
    buffer: UnsafeMutablePointer<CChar>,
    size: Int,
    bytesRead: UnsafeMutablePointer<Int>
) -> Int32 {
    let context = Unmanaged<GitSSHSubtransportContext>.fromOpaque(ctx).takeUnretainedValue()
    return context.read(buffer: buffer, size: size, bytesRead: bytesRead)
}

@_cdecl("git_ssh_swift_stream_write")
func gitSSHSwiftStreamWrite(
    ctx: UnsafeMutableRawPointer,
    buffer: UnsafePointer<CChar>,
    len: Int
) -> Int32 {
    let context = Unmanaged<GitSSHSubtransportContext>.fromOpaque(ctx).takeUnretainedValue()
    return context.write(buffer: buffer, len: len)
}

@_cdecl("git_ssh_swift_subtransport_close")
func gitSSHSwiftSubtransportClose(ctx: UnsafeMutableRawPointer) -> Int32 {
    let context = Unmanaged<GitSSHSubtransportContext>.fromOpaque(ctx).takeUnretainedValue()
    context.close()
    return 0
}

@_cdecl("git_ssh_swift_subtransport_free")
func gitSSHSwiftSubtransportFree(ctx: UnsafeMutableRawPointer) {
    // Release the retained reference from create
    Unmanaged<GitSSHSubtransportContext>.fromOpaque(ctx).release()
}

#endif
