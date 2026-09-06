//
//  OpenConnectionProfileIntent.swift
//  rootshell
//
//  Shortcuts action that opens a saved connection profile.
//

import AppIntents

/// Shortcuts action: open a saved connection profile, optionally with a directory and command.
struct OpenConnectionProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Connection Profile"
    static var description: IntentDescription = "Opens a saved local shell or remote connection profile."
    static var openAppWhenRun = true

    @Parameter(title: "Profile")
    var profile: ConnectionProfileEntity

    @Parameter(title: "Directory", description: "Working directory to cd into after connecting.")
    var directory: String?

    @Parameter(title: "Command", description: "Command to run after connecting.")
    var command: String?

    @Parameter(title: "Execute in Shell", description: "When disabled, uses exec to replace the shell with the command.", default: true)
    var executeInShell: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = ConnectionProfileManager.shared.profile(for: profile.id),
              !saved.isDeleted else {
            throw IntentError.profileNotFound
        }

        guard saved.isAvailableOnCurrentPlatform else {
            throw IntentError.profileUnavailable
        }

        let launchCommand = Self.composeLaunchCommand(
            directory: directory,
            command: command,
            executeInShell: executeInShell
        )

        let request = ProfileIntentRequest(
            profileID: profile.id,
            launchCommandOverride: launchCommand
        )

        AppIntentCoordinator.shared.deposit(.openProfile(request))

        return .result()
    }

    /// Composes a launch command from directory, command, and shell execution preference.
    static func composeLaunchCommand(directory: String?, command: String?, executeInShell: Bool) -> String? {
        let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasDir = dir != nil && !dir!.isEmpty
        let hasCmd = cmd != nil && !cmd!.isEmpty

        switch (hasDir, hasCmd) {
        case (true, true):
            let prefix = executeInShell ? "" : "exec "
            return "cd \(shellQuoted(dir!)) && \(prefix)\(cmd!)"
        case (true, false):
            return "cd \(shellQuoted(dir!))"
        case (false, true):
            let prefix = executeInShell ? "" : "exec "
            return "\(prefix)\(cmd!)"
        case (false, false):
            return nil
        }
    }

    /// POSIX single-quoting for a login shell that may not be POSIX (fish, csh).
    static func shellQuoted(_ value: String) -> String {
        LoginShellCommand.singleQuoted(value)
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case profileNotFound
        case profileUnavailable

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .profileUnavailable:
                return "This profile is unavailable on this device. Edit its platform using Show All Platforms in Profiles."
            case .profileNotFound:
                return "Connection profile not found."
            }
        }
    }
}
