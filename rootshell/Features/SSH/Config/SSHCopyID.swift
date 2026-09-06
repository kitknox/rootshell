//
//  SSHCopyID.swift
//  rootshell
//
//  Native ssh-copy-id implementation: connects to a remote server and installs
//  SSH public keys into ~/.ssh/authorized_keys with correct permissions.
//

import Foundation
import Citadel
import NIOFoundationCompat
import os.log

/// Error types for ssh-copy-id operations
enum SSHCopyIDError: LocalizedError {
    case connectionFailed(host: String, underlying: Error?)
    case authenticationFailed(host: String)
    case commandFailed(command: String, output: String)
    case noPublicKeys
    case allKeysAlreadyInstalled
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host, _):
            return "Failed to connect to \(host)"
        case .authenticationFailed(let host):
            return "Authentication failed for \(host)"
        case .commandFailed(let command, let output):
            return "Remote command failed: \(command)\n\(output)"
        case .noPublicKeys:
            return "No public keys available to install"
        case .allKeysAlreadyInstalled:
            return "All keys are already installed on the server"
        case .verificationFailed:
            return "Verification failed: keys were not properly installed"
        }
    }

    var isAuthenticationRelated: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }
}

/// Result of an ssh-copy-id operation
struct SSHCopyIDResult: Sendable {
    var installedKeys: [String]   // Names of keys installed
    var skippedKeys: [String]     // Names of keys already present
    var log: [String]             // Operation log entries
}

/// Handles ssh-copy-id: connecting to a remote server and installing public keys
/// into the authorized_keys file with correct permissions.
@MainActor
final class SSHCopyID {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHCopyID")

    let parsedCommand: SSHCopyIDParsedCommand
    let config: SSHConfig

    private var sshClient: SSHClient?
    private var jumpClient: SSHClient?

    // Callbacks
    var onProgress: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    /// Keyboard-interactive (RFC 4256) challenge callback (2FA/OTP/PAM). nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    init(command: SSHCopyIDParsedCommand, config: SSHConfig) {
        self.parsedCommand = command
        self.config = config
    }

    /// Execute the ssh-copy-id operation
    /// - Returns: Result with installed and skipped keys
    func execute() async throws -> SSHCopyIDResult {
        var log: [String] = []

        // Step 1: Load public keys
        onProgress?("Loading public keys...")
        log.append("Loading \(parsedCommand.keyIDs.count) key(s)...")

        let keys = parsedCommand.keyIDs.compactMap { SSHKeyManager.shared.findKey(id: $0) }
        let keyLines = SSHPublicKeyFormatter.authorizedKeysContent(for: keys)

        guard !keyLines.isEmpty else {
            throw SSHCopyIDError.noPublicKeys
        }

        for (key, _) in keyLines {
            log.append("  Key: \(key.name) (\(key.keyType.shortName))")
        }
        onLog?(log.last ?? "")

        // Step 2: Connect to server
        onProgress?("Connecting to \(config.displayName)...")
        log.append("Connecting to \(config.host):\(config.port)...")

        do {
            let result = try await SSHConnectionHelper.connect(
                config: config,
                onHostKeyValidation: onHostKeyValidation,
                onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
            )
            sshClient = result.client
            jumpClient = result.jumpClient
        } catch {
            throw SSHCopyIDError.connectionFailed(host: config.host, underlying: error)
        }

        guard let client = sshClient else {
            throw SSHCopyIDError.connectionFailed(host: config.host, underlying: nil)
        }

        onProgress?("Connected. Checking existing keys...")
        log.append("Connected successfully.")

        let targetPath = parsedCommand.targetPath
        let quotedPath = quotedTargetPath(targetPath)

        // Step 3: Check existing keys (unless force mode)
        var keysToInstall = keyLines
        var skippedKeys: [String] = []

        if !parsedCommand.force {
            let existingContent = try await executeRemoteCommand(
                client: client,
                command: "cat \(quotedPath) 2>/dev/null || true"
            )

            if !existingContent.isEmpty {
                log.append("Checking for existing keys in \(targetPath)...")

                // Filter out keys already present (compare base64 blobs)
                keysToInstall = keyLines.filter { (key, line) in
                    // Extract base64 blob from the authorized_keys line (second field)
                    let components = line.split(separator: " ", maxSplits: 2)
                    guard components.count >= 2 else { return true }
                    let blob = String(components[1])

                    if existingContent.contains(blob) {
                        log.append("  Already installed: \(key.name)")
                        skippedKeys.append(key.name)
                        return false
                    }
                    return true
                }
            }
        }

        if keysToInstall.isEmpty {
            log.append("All \(keyLines.count) key(s) are already installed.")
            cleanup()
            if skippedKeys.count == keyLines.count {
                throw SSHCopyIDError.allKeysAlreadyInstalled
            }
            return SSHCopyIDResult(
                installedKeys: [],
                skippedKeys: skippedKeys,
                log: log
            )
        }

        // Step 4: Dry run - just report
        if parsedCommand.dryRun {
            for (key, _) in keysToInstall {
                log.append("  Would install: \(key.name)")
            }
            log.append("Dry run: no changes made.")
            cleanup()
            return SSHCopyIDResult(
                installedKeys: keysToInstall.map(\.key.name),
                skippedKeys: skippedKeys,
                log: log
            )
        }

        // Step 5: Install keys
        onProgress?("Installing \(keysToInstall.count) key(s)...")

        // Build the key content to append
        let newKeyLines = keysToInstall.map(\.line).joined(separator: "\n")

        let installCommand = """
        umask 077; \
        mkdir -p "$(dirname \(quotedPath))" && \
        printf '%s\\n' \(shellEscapeForPrintf(newKeyLines)) >> \(quotedPath) && \
        chmod 600 \(quotedPath) && \
        chmod 700 "$(dirname \(quotedPath))"
        """

        let installOutput = try await executeRemoteCommand(client: client, command: installCommand)
        if !installOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.append("Install output: \(installOutput)")
        }

        for (key, _) in keysToInstall {
            log.append("  Installed: \(key.name)")
        }

        // Step 6: Verify installation
        onProgress?("Verifying installation...")
        let verifyContent = try await executeRemoteCommand(
            client: client,
            command: "cat \(quotedPath) 2>/dev/null"
        )

        var allVerified = true
        for (key, line) in keysToInstall {
            let components = line.split(separator: " ", maxSplits: 2)
            guard components.count >= 2 else { continue }
            let blob = String(components[1])

            if !verifyContent.contains(blob) {
                log.append("  WARNING: Key '\(key.name)' not found after installation!")
                allVerified = false
            }
        }

        if allVerified {
            let count = keysToInstall.count
            log.append("Successfully installed \(count) key\(count == 1 ? "" : "s").")
        } else {
            log.append("WARNING: Some keys could not be verified.")
        }

        cleanup()

        return SSHCopyIDResult(
            installedKeys: keysToInstall.map(\.key.name),
            skippedKeys: skippedKeys,
            log: log
        )
    }

    // MARK: - Private Helpers

    /// Execute a command on the remote server and return its output
    private func executeRemoteCommand(client: SSHClient, command: String) async throws -> String {
        let outputBuffer = try await client.executeCommand(LoginShellCommand.runInPOSIXShell(command))
        let data = Data(buffer: outputBuffer)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Expands only the current user's home prefix; the rest is a literal path.
    private func quotedTargetPath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + LoginShellCommand.singleQuoted(String(path.dropFirst(2)))
        }
        return LoginShellCommand.singleQuoted(path.hasPrefix("/") ? path : "./" + path)
    }

    private func shellEscapeForPrintf(_ str: String) -> String {
        LoginShellCommand.singleQuoted(str)
    }

    /// Clean up SSH connections
    private func cleanup() {
        Task {
            try? await sshClient?.close()
            try? await jumpClient?.close()
        }
        sshClient = nil
        jumpClient = nil
    }
}
