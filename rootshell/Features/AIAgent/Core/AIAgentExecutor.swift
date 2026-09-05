#if !CHINA_BUILD
//
//  AIAgentExecutor.swift
//  rootshell
//
//  Executes commands on remote SSH servers for the AI Agent
//

import Foundation
import Citadel
import NIO
import NIOSSH
import os.log

/// Result of command execution
struct CommandExecutionResult: Sendable {
    let output: String
    let exitCode: Int?
    let duration: TimeInterval
}

/// Errors during command execution
enum AIAgentExecutorError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SSH server"
        case .connectionFailed(let host):
            return "Failed to connect to \(host)"
        case .authenticationFailed:
            return "SSH authentication failed"
        case .commandFailed(let message):
            return "Command execution failed: \(message)"
        case .timeout:
            return "Command execution timed out"
        case .cancelled:
            return "Command execution cancelled"
        }
    }
}

/// Executes commands on SSH servers for the AI Agent
/// Uses a background SSH connection separate from the terminal display
@MainActor
final class AIAgentExecutor {
    private struct SendableSSHClient: @unchecked Sendable {
        let client: SSHClient
    }
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AIAgentExecutor")

    /// Default command timeout in seconds
    private nonisolated static let defaultTimeout: TimeInterval = 30

    /// Maximum output length to prevent memory issues (sent to AI)
    private nonisolated static let maxOutputLength = 100_000

    /// Maximum display length for UI (prevents SwiftUI slowdowns)
    private nonisolated static let maxDisplayLength = 10_000

    /// Minimum interval between UI updates during streaming (500ms)
    /// Higher interval reduces SwiftUI view tree re-evaluation overhead
    private nonisolated static let uiUpdateInterval: CFAbsoluteTime = 0.5

    let sshConfig: SSHConfig

    private var client: SSHClient?
    private var jumpClient: SSHClient?
    private var isConnected = false
    private var currentTask: Task<CommandExecutionResult, Error>?

    /// User's login shell (e.g., "/bin/bash", "/bin/zsh")
    /// Set this after collecting the host fingerprint to run commands in login shell
    var sessionShell: String?

    // Host key validation callback
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    init(sshConfig: SSHConfig) {
        self.sshConfig = sshConfig
    }

    deinit {
        // Synchronously disconnect on deinit
        // Note: async cleanup should happen via disconnect() before dealloc
    }

    // MARK: - Connection Management

    /// Connects to the SSH server
    /// - Throws: AIAgentExecutorError if connection fails
    func connect() async throws {
        guard !isConnected else { return }

        Self.logger.info("Connecting AI Agent executor to \(self.sshConfig.displayName)")

        let resolvedConfig: SSHConfig
        do {
            resolvedConfig = try await sshConfig.resolvedConfig()
        } catch {
            Self.logger.error("Failed to resolve saved password for AI Agent: \(error.localizedDescription)")
            throw AIAgentExecutorError.authenticationFailed
        }

        do {
            let finalClient: SSHClient

            if let jumpConfig = resolvedConfig.jumpHost {
                // Connect via jump host
                Self.logger.debug("Using jump host: \(jumpConfig.host)")

                let jumpAuth = try await buildAuthMethod(for: jumpConfig)
                let jumpHostKeyValidator = buildHostKeyValidator(for: jumpConfig.host, port: jumpConfig.port)

                // Pre-resolve jump host to CGNAT IPv4 and route through
                // MPTCPBootstrap so the TCP setup goes via NWConnection.
                // POSIX `connect()` races Tailscale's NAT/DERP path setup
                // for NAT'd targets outside the home network.
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
                    host: jumpConnectHost,
                    port: jumpConfig.port,
                    authenticationMethod: { jumpAuth },
                    hostKeyValidator: jumpHostKeyValidator
                )
                jumpSettings.algorithms = .all
                jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpConfig.host)
                let jumpClientConnection: SSHClient
                do {
                    jumpClientConnection = try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
                } catch {
                    try? await jumpChannel.close()
                    throw error
                }
                self.jumpClient = jumpClientConnection

                // Jump to target
                let targetAuth = try await buildAuthMethod(for: resolvedConfig)
                let targetHostKeyValidator = buildHostKeyValidator(for: resolvedConfig.host, port: resolvedConfig.port)

                var targetSettings = SSHClientSettings(
                    host: resolvedConfig.host,
                    port: resolvedConfig.port,
                    authenticationMethod: { targetAuth },
                    hostKeyValidator: targetHostKeyValidator
                )
                targetSettings.algorithms = .all
                targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: resolvedConfig.host)

                finalClient = try await jumpClientConnection.jump(to: targetSettings)

            } else {
                // Direct connection
                let auth = try await buildAuthMethod(for: resolvedConfig)
                let hostKeyValidator = buildHostKeyValidator(for: resolvedConfig.host, port: resolvedConfig.port)

                // Pre-resolve CGNAT IPv4 (prefer cached IP if present from a
                // previous successful connection) and route through
                // MPTCPBootstrap for the Tailscale-NAT-safe TCP setup.
                let connectHost: String
                if let cachedIP = resolvedConfig.cachedIP {
                    connectHost = cachedIP
                } else if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: resolvedConfig.host) {
                    connectHost = cgnatIP
                } else {
                    connectHost = resolvedConfig.host
                }
                let directChannel = try await MPTCPBootstrap.connectPlainChannel(
                    host: connectHost, port: resolvedConfig.port
                )
                var settings = SSHClientSettings(
                    host: connectHost,
                    port: resolvedConfig.port,
                    authenticationMethod: { auth },
                    hostKeyValidator: hostKeyValidator
                )
                settings.algorithms = .all
                settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
                settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: resolvedConfig.host)
                do {
                    finalClient = try await SSHClient.connect(on: directChannel, settings: settings)
                } catch {
                    try? await directChannel.close()
                    throw error
                }
            }

            self.client = finalClient
            self.isConnected = true
            Self.logger.info("AI Agent executor connected to \(self.sshConfig.host)")

        } catch let error as SSHClientError {
            Self.logger.error("SSH client error: \(error.localizedDescription)")
            if case .allAuthenticationOptionsFailed = error {
                throw AIAgentExecutorError.authenticationFailed
            }
            throw AIAgentExecutorError.connectionFailed(sshConfig.host)
        } catch {
            Self.logger.error("Connection error: \(error.localizedDescription)")
            throw AIAgentExecutorError.connectionFailed(sshConfig.host)
        }
    }

    /// Disconnects from the SSH server
    func disconnect() async {
        Self.logger.debug("Disconnecting AI Agent executor")

        currentTask?.cancel()
        currentTask = nil

        if let client = client {
            try? await client.close()
        }
        client = nil

        if let jumpClient = jumpClient {
            try? await jumpClient.close()
        }
        jumpClient = nil

        isConnected = false
    }

    // MARK: - Command Execution

    /// Execute a command and return the output
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - timeout: Maximum execution time (defaults to 30 seconds)
    /// - Returns: The command execution result
    /// - Throws: AIAgentExecutorError if execution fails
    func execute(command: String, timeout: TimeInterval = defaultTimeout) async throws -> CommandExecutionResult {
        guard let client = client, isConnected else {
            throw AIAgentExecutorError.notConnected
        }

        let startTime = Date()

        // Wrap command in login shell to get full user environment (PATH, aliases, etc.)
        let finalCommand = wrapForLoginShell(command)

        Self.logger.info("Executing command: \(finalCommand.prefix(100))...")

        let task = Task<CommandExecutionResult, Error> {
            try await withThrowingTaskGroup(of: CommandExecutionResult.self) { group in
                group.addTask {
                    // Execute the command
                    let output = try await client.executeCommand(finalCommand)

                    // Convert ByteBuffer to String
                    var buffer = output
                    let outputString: String
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                        // Truncate if too long
                        let truncatedBytes = bytes.prefix(Self.maxOutputLength)
                        outputString = String(decoding: truncatedBytes, as: UTF8.self)
                    } else {
                        outputString = ""
                    }

                    let duration = Date().timeIntervalSince(startTime)
                    return CommandExecutionResult(
                        output: outputString,
                        exitCode: nil,  // Citadel doesn't expose exit code directly
                        duration: duration
                    )
                }

                // Add timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AIAgentExecutorError.timeout
                }

                // Return first completed result (or throw if timeout wins)
                guard let result = try await group.next() else {
                    throw AIAgentExecutorError.commandFailed("No result")
                }

                // Cancel remaining tasks
                group.cancelAll()

                return result
            }
        }

        currentTask = task

        do {
            let result = try await task.value
            currentTask = nil

            let outputPreview = result.output.prefix(100)
            Self.logger.debug("Command completed in \(result.duration)s, output: \(outputPreview)...")
            return result
        } catch is CancellationError {
            throw AIAgentExecutorError.cancelled
        } catch {
            currentTask = nil
            throw error
        }
    }

    /// Execute a command with streaming output
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - onOutput: Callback for streaming output chunks (throttled to 100ms intervals)
    /// - Returns: The final command execution result
    /// - Throws: AIAgentExecutorError if execution fails
    func executeStreaming(
        command: String,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CommandExecutionResult {
        guard let client = client, isConnected else {
            throw AIAgentExecutorError.notConnected
        }

        let startTime = Date()
        let finalCommand = wrapForLoginShell(command)
        let sendableClient = SendableSSHClient(client: client)

        Self.logger.info("Executing streaming command: \(finalCommand.prefix(100))...")

        let task = Task.detached { [sendableClient] in
            // Use executeCommandStream for streaming output
            let streams = try await sendableClient.client.executeCommandStream(finalCommand)

            var accumulatedOutput = ""
            var utf8Buffer = Data()
            var lastUIUpdateTime: CFAbsoluteTime = 0

            for try await event in streams {
                // Check for cancellation
                try Task.checkCancellation()

                let buffer: ByteBuffer
                switch event {
                case .stdout(let stdout):
                    buffer = stdout
                case .stderr(let stderr):
                    buffer = stderr
                case .exitStatus:
                    // Exit status is informational - continue to next event
                    continue
                }

                // Append bytes to UTF-8 buffer
                if let bytesView = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                    utf8Buffer.append(contentsOf: bytesView)
                }

                // Decode complete UTF-8 sequences
                let decoded = Self.decodeUTF8(&utf8Buffer)
                if !decoded.isEmpty {
                    accumulatedOutput += decoded

                    // Throttle UI updates to reduce CPU usage
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastUIUpdateTime >= Self.uiUpdateInterval {
                        lastUIUpdateTime = now

                        // Truncate display if too long (keep most recent output)
                        let displayOutput = Self.truncateForDisplay(accumulatedOutput)
                        await MainActor.run {
                            onOutput(displayOutput)
                        }
                    }
                }
            }

            // Final UI update with complete output
            let displayOutput = Self.truncateForDisplay(accumulatedOutput)
            await MainActor.run {
                onOutput(displayOutput)
            }

            // Truncate final output for AI context (keep first N characters)
            let finalOutput = String(accumulatedOutput.prefix(Self.maxOutputLength))

            let duration = Date().timeIntervalSince(startTime)
            return CommandExecutionResult(
                output: finalOutput,
                exitCode: nil,
                duration: duration
            )
        }

        currentTask = task

        do {
            let result = try await task.value
            currentTask = nil

            let outputPreview = result.output.prefix(100)
            Self.logger.debug("Streaming command completed in \(result.duration)s, output: \(outputPreview)...")
            return result
        } catch is CancellationError {
            currentTask = nil
            throw AIAgentExecutorError.cancelled
        } catch {
            currentTask = nil
            throw error
        }
    }

    /// Cancel any currently executing command
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private Helpers

    private func buildAuthMethod(for config: SSHConfig) async throws -> SSHAuthenticationMethod {
        try await SSHConnectionHelper.buildAuthMethod(for: config)
    }

    private func buildAuthMethod(for config: SSHConfig.JumpHostConfig) async throws -> SSHAuthenticationMethod {
        try await SSHConnectionHelper.buildAuthMethod(for: config)
    }

    private func buildHostKeyValidator(for host: String, port: Int) -> SSHHostKeyValidator {
        SSHConnectionHelper.buildHostKeyValidator(for: host, port: port, onValidation: onHostKeyValidation)
    }

    /// Wrap command in user's login shell to get full environment (PATH, aliases, functions)
    /// Uses $SHELL -l -c 'command' pattern with stderr redirected to stdout
    /// The `|| true` ensures the command always exits 0 so Citadel doesn't throw CommandFailed
    ///
    /// The PATH prelude has to run in `sh`, not inside the login shell: `$SHELL`
    /// may be fish/csh, which can't parse the POSIX `export PATH=...` snippet.
    /// So `sh -c` runs the prelude and then `exec`s the user's login shell to
    /// run their command, rather than nesting the prelude text inside a
    /// `$SHELL -l -c '...'` string. One behavioral consequence: previously the
    /// prelude ran *after* the login shell sourced its profile, so the app's
    /// PATH entries won outright; now `sh` exports them first and the login
    /// shell's profile is read afterwards, so a profile that overwrites PATH
    /// wholesale could shadow them (fish's `fish_add_path` prepends and
    /// preserves, so entries survive in practice).
    private func wrapForLoginShell(_ command: String) -> String {
        let shell = sessionShell ?? "/bin/sh"
        let script = "\(SSHConfig.remoteExecPathPrefix)exec \(shell) -l -c \(LoginShellCommand.singleQuoted(command))"
        // Redirect stderr to stdout so both streams are captured
        // Use || true to ensure exit code 0 (Citadel throws on non-zero exit)
        return LoginShellCommand.runInPOSIXShell(script) + " 2>&1 || true"
    }

    /// Decode UTF-8 from buffer, leaving incomplete sequences for next packet
    /// This pattern handles multi-byte characters that may be split across packets
    nonisolated private static func decodeUTF8(_ buffer: inout Data) -> String {
        var decoded = ""
        var validByteCount = 0
        var utf8Decoder = UTF8()
        var iterator = buffer.makeIterator()

        decodeLoop: while true {
            switch utf8Decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                // Successfully decoded a Unicode scalar
                decoded.append(Character(scalar))
                validByteCount = buffer.count - IteratorSequence(iterator).underestimatedCount

            case .emptyInput:
                // No more complete sequences available
                break decodeLoop

            case .error:
                // Invalid UTF-8 sequence - skip one byte and continue
                if validByteCount < buffer.count {
                    validByteCount += 1
                    let newIterator = buffer.dropFirst(validByteCount).makeIterator()
                    iterator = newIterator
                    utf8Decoder = UTF8()
                } else {
                    break decodeLoop
                }
            }
        }

        // Keep only incomplete UTF-8 sequence bytes for next packet
        if validByteCount > 0 {
            buffer = Data(buffer.dropFirst(validByteCount))
        }

        return decoded
    }

    /// Truncate output for display (keep most recent characters)
    nonisolated private static func truncateForDisplay(_ output: String) -> String {
        if output.count <= Self.maxDisplayLength {
            return output
        }
        // Keep last N characters with truncation indicator
        return "... (truncated)\n" + String(output.suffix(Self.maxDisplayLength - 20))
    }
}
#endif
