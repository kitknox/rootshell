//
//  VNCPreDisconnectRunner.swift
//  rootshell
//
//  Performs a Screen Sharing connection's pre-disconnect action: a key chord
//  on the live session, or a command over a linked SSH profile.
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import os
import rootshellVNC

@MainActor
enum VNCPreDisconnectRunner {

    nonisolated enum Failure: LocalizedError {
        case notConnected
        case logOutNeedsMac
        case invalidShortcut
        case interactiveAuthentication
        case profileMissing
        case keysUnavailable(String)
        case connectionFailed(profile: String, reason: String)
        case timedOut(seconds: Int)
        case commandFailed(exitCode: Int, output: String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return String(localized: "The Screen Sharing connection is not active, so the keys could not be sent.")
            case .logOutNeedsMac:
                return String(localized: "Log Out Remote User is only available when the remote computer is a Mac.")
            case .invalidShortcut:
                return String(localized: "The saved keyboard shortcut has no key.")
            case .interactiveAuthentication:
                return String(localized: "The SSH profile for this command signs in interactively, which cannot be answered while disconnecting.")
            case .profileMissing:
                return String(localized: "The SSH profile for this command no longer exists.")
            case .keysUnavailable(let names):
                return String(localized: "The SSH key for this command is not available on this device (\(names)).")
            case .connectionFailed(let profile, let reason):
                return String(localized: "Could not connect to \(profile): \(reason)")
            case .timedOut(let seconds):
                return String(localized: "The command did not finish within \(seconds) seconds.")
            case .commandFailed(let exitCode, let output):
                let status = String(localized: "The command exited with status \(exitCode).")
                return output.isEmpty ? status : status + "\n" + output
            }
        }
    }

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VNCPreDisconnectRunner"
    )

    /// How long a command may run once the SSH connection is up.
    private static let commandTimeoutSeconds = 20

    /// Bound on SSH client closes; a dead peer can park NIO close futures.
    private static let closeTimeoutSeconds: TimeInterval = 2.0

    /// How long the chord is held, and the pause before the transport closes.
    private static let chordHold: Duration = .milliseconds(75)
    private static let chordSettle: Duration = .milliseconds(200)

    /// Most of a failed command's output shown to the user.
    private static let outputLimit = 400

    static func run(
        _ action: VNCPreDisconnectAction,
        session: VNCSession,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws {
        let appleModifiers = session.serverUsesAppleModifierConvention
        let option = KeyboardInputHandler.optionLeftKeysym(appleModifierConvention: appleModifiers)

        switch action.kind {
        case .none:
            return

        case .lockScreen:
            // Control-Command-Q on a Mac, Super-L elsewhere.
            if appleModifiers {
                try await sendChord(
                    modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymSuperL],
                    key: KeyboardInputHandler.keysymForCharacter("q"),
                    session: session)
            } else {
                try await sendChord(
                    modifiers: [KeyboardInputHandler.keysymSuperL],
                    key: KeyboardInputHandler.keysymForCharacter("l"),
                    session: session)
            }

        case .logOut:
            guard appleModifiers else { throw Failure.logOutNeedsMac }
            // With Option the Mac logs out without its confirmation dialog.
            try await sendChord(
                modifiers: [
                    KeyboardInputHandler.keysymShiftL,
                    option,
                    KeyboardInputHandler.keysymSuperL,
                ],
                key: KeyboardInputHandler.keysymForCharacter("q"),
                session: session)

        case .controlAltDelete:
            try await sendChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymAltL],
                key: KeyboardInputHandler.keysymDelete,
                session: session)

        case .shortcut:
            let shortcut = action.shortcut
            guard let key = keysym(for: shortcut) else { throw Failure.invalidShortcut }
            var modifiers: [UInt32] = []
            if shortcut.control { modifiers.append(KeyboardInputHandler.keysymControlL) }
            if shortcut.option { modifiers.append(option) }
            if shortcut.shift { modifiers.append(KeyboardInputHandler.keysymShiftL) }
            if shortcut.command { modifiers.append(KeyboardInputHandler.keysymSuperL) }
            try await sendChord(modifiers: modifiers, key: key, session: session)

        case .command:
            try await runCommand(
                action.command,
                profileID: action.sshProfileID,
                onHostKeyValidation: onHostKeyValidation)
        }
    }

    // MARK: - Key chords

    private static func keysym(for shortcut: VNCPreDisconnectShortcut) -> UInt32? {
        if let special = shortcut.specialKey {
            switch special {
            case .escape: return KeyboardInputHandler.keysymEscape
            case .delete: return KeyboardInputHandler.keysymBackspace
            case .forwardDelete: return KeyboardInputHandler.keysymDelete
            case .return: return KeyboardInputHandler.keysymReturn
            case .tab: return KeyboardInputHandler.keysymTab
            case .space: return KeyboardInputHandler.keysymForCharacter(" ")
            case .upArrow: return KeyboardInputHandler.keysymUp
            case .downArrow: return KeyboardInputHandler.keysymDown
            case .leftArrow: return KeyboardInputHandler.keysymLeft
            case .rightArrow: return KeyboardInputHandler.keysymRight
            case .home: return KeyboardInputHandler.keysymHome
            case .end: return KeyboardInputHandler.keysymEnd
            case .pageUp: return KeyboardInputHandler.keysymPageUp
            case .pageDown: return KeyboardInputHandler.keysymPageDown
            case .f1: return KeyboardInputHandler.keysymF1
            case .f2: return KeyboardInputHandler.keysymF2
            case .f3: return KeyboardInputHandler.keysymF3
            case .f4: return KeyboardInputHandler.keysymF4
            case .f5: return KeyboardInputHandler.keysymF5
            case .f6: return KeyboardInputHandler.keysymF6
            case .f7: return KeyboardInputHandler.keysymF7
            case .f8: return KeyboardInputHandler.keysymF8
            case .f9: return KeyboardInputHandler.keysymF9
            case .f10: return KeyboardInputHandler.keysymF10
            case .f11: return KeyboardInputHandler.keysymF11
            case .f12: return KeyboardInputHandler.keysymF12
            }
        }
        // Shift is sent as its own key, so the base key stays unshifted.
        guard let character = shortcut.character?.lowercased().first else { return nil }
        let keysym = KeyboardInputHandler.keysymForCharacter(character)
        return keysym == 0 ? nil : keysym
    }

    private static func sendChord(
        modifiers: [UInt32],
        key: UInt32,
        session: VNCSession
    ) async throws {
        guard session.connectionState.isConnected else { throw Failure.notConnected }

        for modifier in modifiers {
            session.sendKeyEvent(downFlag: true, key: modifier)
        }
        session.sendKeyEvent(downFlag: true, key: key)
        // Release even when cancelled so no key stays held on the remote.
        try? await Task.sleep(for: chordHold)
        session.sendKeyEvent(downFlag: false, key: key)
        for modifier in modifiers.reversed() {
            session.sendKeyEvent(downFlag: false, key: modifier)
        }

        await session.flushPendingInput()
        guard session.connectionState.isConnected else { throw Failure.notConnected }
        try await Task.sleep(for: chordSettle)
    }

    // MARK: - SSH command

    /// Nothing can answer a keyboard-interactive prompt during a disconnect.
    static func canRunCommand(through profile: ConnectionProfile) -> Bool {
        guard !profile.isDeleted, profile.connectionProtocol == .ssh else { return false }
        if case .keyboardInteractive = profile.sshConfig.authMethod { return false }
        return !profile.sshConfig.jumpChain.contains { hop in
            if case .keyboardInteractive = hop.authMethod { return true }
            return false
        }
    }

    private static func runCommand(
        _ command: String,
        profileID: UUID?,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws {
        guard let profileID,
              let profile = ConnectionProfileManager.shared.profile(for: profileID),
              !profile.isDeleted else {
            throw Failure.profileMissing
        }
        guard canRunCommand(through: profile) else {
            throw Failure.interactiveAuthentication
        }

        let config: SSHConfig
        do {
            config = try await RemoteScreenTransportFactory.resolveJumpSSHConfig(
                profile.sshConfig, profileID: profileID)
        } catch VNCLaunchError.jumpKeysUnresolved(let names) {
            throw Failure.keysUnavailable(names)
        }

        let clients: (client: SSHClient, jumpClient: SSHClient?)
        do {
            clients = try await SSHConnectionHelper.connect(
                config: config,
                onHostKeyValidation: onHostKeyValidation)
        } catch {
            throw Failure.connectionFailed(
                profile: profile.name, reason: error.localizedDescription)
        }
        defer {
            let client = clients.client
            let jumpClient = clients.jumpClient
            Task { await close(client: client, jumpClient: jumpClient) }
        }
        // Stay Connected may have landed while the connection came up.
        try Task.checkCancellation()

        let wrapped = LoginShellCommand.runInLoginShell(command, prependPATH: true)
        let client = clients.client
        let jumpClient = clients.jumpClient
        do {
            // withTimeout does not forward cancellation; closing the clients
            // ends the channel so a cancelled command stops with it.
            try await withTaskCancellationHandler {
                try await withTimeout(seconds: TimeInterval(commandTimeoutSeconds)) {
                    try await execute(wrapped, client: client)
                }
            } onCancel: {
                Task { await close(client: client, jumpClient: jumpClient) }
            }
        } catch is TimeoutError {
            throw Failure.timedOut(seconds: commandTimeoutSeconds)
        }
    }

    /// Runs the command to completion, keeping the tail of its output for a
    /// failure message.
    private static func execute(_ command: String, client: SSHClient) async throws {
        var output = ""
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    output += String(buffer: buffer)
                    if output.count > outputLimit * 4 {
                        output = String(output.suffix(outputLimit))
                    }
                case .exitStatus:
                    break
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            logger.info("Pre-disconnect command exited with status \(failure.exitCode)")
            let tail = String(output.suffix(outputLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.commandFailed(exitCode: failure.exitCode, output: tail)
        }
    }

    private static func close(client: SSHClient, jumpClient: SSHClient?) async {
        try? await withTimeout(seconds: closeTimeoutSeconds) {
            try? await client.close()
        }
        if let jumpClient {
            try? await withTimeout(seconds: closeTimeoutSeconds) {
                try? await jumpClient.close()
            }
        }
    }
}
