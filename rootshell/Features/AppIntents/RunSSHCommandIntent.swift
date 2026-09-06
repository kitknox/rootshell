//
//  RunSSHCommandIntent.swift
//  rootshell
//
//  Shortcuts action that runs a command on a saved profile's host over SSH
//  and returns the output, without opening the app when auth allows it.
//

import AppIntents
import UIKit

/// Shortcuts action: run a command over SSH on a saved profile's host and
/// return stdout to the Shortcut. Runs in the background when the profile's
/// auth needs no interaction (key without biometric requirement, inline
/// password, or none). Keys gated by Face ID / Touch ID continue in the
/// foreground so the biometric prompt can appear.
struct RunSSHCommandIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Run Command over SSH"
    static var description: IntentDescription = "Runs a command on a saved profile's host over SSH and returns the output. For long-running or interactive commands, use Open Connection Profile with a command instead."
    static var openAppWhenRun = false

    /// Longest stdout returned to the Shortcut; keeps huge outputs from
    /// bloating the Shortcuts run.
    private static let maxOutputCharacters = 100_000

    @Parameter(title: "Profile", query: SSHConnectionProfileEntityQuery())
    var profile: ConnectionProfileEntity

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Timeout (seconds)", description: "How long the command may run before it is stopped.", default: 25, inclusiveRange: (5, 120))
    var timeout: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let savedProfile = ConnectionProfileManager.shared.profile(for: profile.id),
              !savedProfile.isDeleted else {
            throw IntentError.profileNotFound
        }
        guard savedProfile.isSSHBased else {
            throw IntentError.notATerminalProfile
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw IntentError.emptyCommand
        }

        var config: SSHConfig
        switch ConnectionKeyResolver.resolve(config: savedProfile.sshConfig, profileID: savedProfile.id) {
        case .resolved(let resolvedKeys):
            config = resolvedKeys
        case .unresolved:
            throw IntentError.keyUnavailable(savedProfile.name)
        }

        try preflightAuth(config.authMethod, profileName: savedProfile.name)
        if let jumpConfig = config.jumpHost {
            try preflightAuth(jumpConfig.authMethod, profileName: savedProfile.name)
        }

        // Load a saved password from the Keychain up front. A Keychain item
        // that needs user interaction can't prompt in the background — offer
        // to continue in the app instead of failing.
        if Self.needsSavedPassword(config) {
            do {
                config = try await config.resolvedConfig()
            } catch {
                if UIApplication.shared.applicationState == .background {
                    throw needsToContinueInForegroundError("\(savedProfile.name) needs authentication. Continue in rootshell to unlock it.")
                }
                throw IntentError.authUnavailable(savedProfile.name, error.localizedDescription)
            }
        }

        let output: HeadlessSSHExecutor.CommandOutput
        do {
            output = try await HeadlessSSHExecutor.execute(
                config: config,
                command: trimmedCommand,
                timeout: min(max(timeout, 5), 120),
                logLabel: "[Intent]",
                maxOutputBytes: Self.maxOutputCharacters * 4
            )
        } catch let error as HeadlessSSHExecutor.ExecError {
            throw IntentError.executionFailed(String(localized: error.localizedStringResource))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Auth-building failures pass through the executor unwrapped.
            throw IntentError.authUnavailable(savedProfile.name, error.localizedDescription)
        }

        // A nil exit code means the command was forcibly terminated after
        // exceeding the output cap — deliver the partial output, but don't
        // call it a success. A real non-zero exit fails the Shortcut.
        if let exitCode = output.exitCode, exitCode != 0 {
            let detail = output.stderr.isEmpty ? "" : ": \(output.stderr.prefix(500))"
            throw IntentError.commandFailed(exitCode, detail)
        }

        var stdout = output.stdout
        var truncated = output.truncated
        if stdout.count > Self.maxOutputCharacters {
            stdout = String(stdout.prefix(Self.maxOutputCharacters))
            truncated = true
        }
        if truncated {
            stdout += "\n… [output truncated]"
        }

        let dialog: IntentDialog = output.exitCode == nil
            ? "Stopped after exceeding the output limit on \(savedProfile.name)."
            : "Finished on \(savedProfile.name)."
        return .result(value: stdout, dialog: dialog)
    }

    /// Rejects auth methods that can't work headlessly, and routes biometric-
    /// gated keys through a foreground continuation so LAContext never fires
    /// in the background.
    @MainActor
    private func preflightAuth(_ authMethod: SSHConfig.AuthMethod, profileName: String) throws {
        switch authMethod {
        case .none:
            break
        case .password(let password):
            guard !password.isEmpty else {
                throw IntentError.authUnavailable(profileName, "no password is stored")
            }
        case .savedPassword:
            break  // Resolved from the Keychain by the caller.
        case .key(let keyID):
            guard let key = SSHKeyManager.shared.findKey(id: keyID) else {
                throw IntentError.keyUnavailable(profileName)
            }
            if key.authRequirement != .none && UIApplication.shared.applicationState == .background {
                throw needsToContinueInForegroundError("The key for \(profileName) requires Face ID or Touch ID. Continue in rootshell to authenticate.")
            }
        case .keyboardInteractive:
            throw IntentError.authUnavailable(profileName, "keyboard-interactive auth needs a terminal session")
        case .unknown:
            throw IntentError.authUnavailable(profileName, "the auth method isn't supported on this version")
        }
    }

    private static func needsSavedPassword(_ config: SSHConfig) -> Bool {
        if case .savedPassword = config.authMethod { return true }
        if let jump = config.jumpHost, case .savedPassword = jump.authMethod { return true }
        return false
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case profileNotFound
        case notATerminalProfile
        case emptyCommand
        case keyUnavailable(String)
        case authUnavailable(String, String)
        case executionFailed(String)
        case commandFailed(Int, String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .profileNotFound:
                return "Connection profile not found."
            case .notATerminalProfile:
                return "This action requires an SSH, mosh, or tssh profile."
            case .emptyCommand:
                return "A command is required."
            case .keyUnavailable(let profileName):
                return "The SSH key for \(profileName) isn't available on this device."
            case .authUnavailable(let profileName, let reason):
                return "Can't authenticate to \(profileName): \(reason)."
            case .executionFailed(let detail):
                return "\(detail)"
            case .commandFailed(let exitCode, let detail):
                return "Command exited with code \(exitCode)\(detail)"
            }
        }
    }
}
