#if !CHINA_BUILD
//
//  CatalystLocalExecutor.swift
//  rootshell
//
//  Executes commands locally via rootshell-helper for the AI Agent
//  Mac Catalyst only
//

#if targetEnvironment(macCatalyst)

import Foundation
import os.log

/// Errors during local command execution
enum CatalystExecutorError: LocalizedError, Sendable {
    case helperNotAvailable
    case helperConnectionFailed(String)
    case commandFailed(exitCode: Int32)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .helperNotAvailable:
            return "Local shell helper is not running"
        case .helperConnectionFailed(let message):
            return "Failed to connect to helper: \(message)"
        case .commandFailed(let code):
            return "Command exited with code \(code)"
        case .timeout:
            return "Command execution timed out"
        case .cancelled:
            return "Command execution cancelled"
        }
    }
}

/// Executes commands locally via rootshell-helper for the AI Agent
/// Matches the interface of AIAgentExecutor for drop-in replacement
@MainActor
final class CatalystLocalExecutor {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CatalystLocalExecutor")

    /// Default command timeout in seconds
    private nonisolated static let defaultTimeout: TimeInterval = 30

    /// Maximum output length to prevent memory issues (sent to AI)
    private nonisolated static let maxOutputLength = 100_000

    /// Maximum display length for UI (prevents SwiftUI slowdowns)
    private nonisolated static let maxDisplayLength = 10_000

    /// Minimum interval between UI updates during streaming (500ms)
    /// Higher interval reduces SwiftUI view tree re-evaluation overhead
    private nonisolated static let uiUpdateInterval: CFAbsoluteTime = 0.5

    /// Current execution task (for cancellation)
    private var currentTask: Task<CommandExecutionResult, Error>?

    /// User's login shell (e.g., "/bin/bash", "/bin/zsh")
    /// Set this after collecting the local fingerprint
    var sessionShell: String?

    /// Whether the executor is "connected" (helper is running)
    private var isConnected = false

    init() {}

    deinit {
        // Cleanup happens via disconnect()
    }

    // MARK: - Connection Management

    /// Ensures the helper is running
    /// - Throws: CatalystExecutorError if helper cannot be started
    func connect() async throws {
        guard !isConnected else { return }

        Self.logger.info("Connecting CatalystLocalExecutor (ensuring helper is running)")

        guard await HelperConnection.shared.ensureHelperRunning() else {
            throw CatalystExecutorError.helperNotAvailable
        }

        isConnected = true
        Self.logger.info("CatalystLocalExecutor connected (helper is running)")
    }

    /// Disconnects (no-op for local, but matches AIAgentExecutor interface)
    func disconnect() async {
        Self.logger.debug("Disconnecting CatalystLocalExecutor")
        currentTask?.cancel()
        currentTask = nil
        isConnected = false
    }

    // MARK: - Command Execution

    /// Execute a command and return the output
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - timeout: Maximum execution time (defaults to 30 seconds)
    /// - Returns: The command execution result
    /// - Throws: CatalystExecutorError if execution fails
    func execute(command: String, timeout: TimeInterval = defaultTimeout) async throws -> CommandExecutionResult {
        // Use streaming implementation but don't update UI
        return try await executeStreaming(command: command, timeout: timeout) { _ in }
    }

    /// Execute a command with streaming output
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - timeout: Maximum execution time (defaults to 30 seconds)
    ///   - onOutput: Callback for streaming output chunks (throttled to 100ms intervals)
    /// - Returns: The final command execution result
    /// - Throws: CatalystExecutorError if execution fails
    func executeStreaming(
        command: String,
        timeout: TimeInterval = defaultTimeout,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws -> CommandExecutionResult {
        guard isConnected else {
            throw CatalystExecutorError.helperNotAvailable
        }

        let startTime = Date()

        // Wrap command in login shell to get full user environment (PATH, aliases, etc.)
        let finalCommand = wrapForLoginShell(command)

        Self.logger.info("Executing command: \(finalCommand.prefix(100))...")

        let task = Task<CommandExecutionResult, Error> { [weak self] in
            // Liveness check only: the body runs entirely off statics.
            guard self != nil else {
                throw CatalystExecutorError.helperNotAvailable
            }

            var accumulatedOutput = ""
            var lastUIUpdateTime: CFAbsoluteTime = 0

            let result = try await HelperConnection.shared.executeCommand(
                command: finalCommand,
                workingDirectory: nil,
                timeout: timeout
            ) { chunk in
                accumulatedOutput += chunk

                // Throttle UI updates to reduce CPU usage
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastUIUpdateTime >= Self.uiUpdateInterval {
                    lastUIUpdateTime = now

                    // Truncate display if too long (keep most recent output)
                    let displayOutput = Self.truncateForDisplay(accumulatedOutput)
                    Task { @MainActor in
                        onOutput(displayOutput)
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
                exitCode: Int(result.exitCode),
                duration: duration
            )
        }

        currentTask = task

        do {
            let result = try await task.value
            currentTask = nil

            let outputPreview = result.output.prefix(100)
            Self.logger.debug("Command completed in \(result.duration)s, output: \(outputPreview)...")
            return result
        } catch is CancellationError {
            currentTask = nil
            throw CatalystExecutorError.cancelled
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

    /// Wrap command in user's login shell to get full environment (PATH, aliases, functions)
    /// Uses $SHELL -l -c 'command' pattern with stderr redirected to stdout
    /// The `|| true` ensures the command always exits 0 to avoid error throws
    ///
    /// No PATH prelude is involved here (unlike `AIAgentExecutor`'s SSH path),
    /// so there's no `sh -c` wrap to add — just fish-safe quoting. Note this
    /// produces a deliberate-looking double `-l -c`: `rootshell-helper`'s
    /// ProcessExecutor.m already execs `[loginShell, "-l", "-c", cmd]`, so the
    /// login shell ends up invoked twice (once here, once by the helper). That
    /// predates this fix and is left alone.
    private func wrapForLoginShell(_ command: String) -> String {
        let shell = sessionShell ?? "/bin/sh"
        // Redirect stderr to stdout so both streams are captured
        // Use || true to ensure exit code 0 (avoid throwing on non-zero)
        return "\(shell) -l -c \(LoginShellCommand.singleQuoted(command)) 2>&1 || true"
    }

    /// Truncate output for display (keep most recent characters)
    private static func truncateForDisplay(_ output: String) -> String {
        if output.count <= Self.maxDisplayLength {
            return output
        }
        // Keep last N characters with truncation indicator
        return "... (truncated)\n" + String(output.suffix(Self.maxDisplayLength - 20))
    }
}

#endif // targetEnvironment(macCatalyst)
#endif
