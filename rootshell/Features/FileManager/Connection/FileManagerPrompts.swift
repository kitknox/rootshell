//
//  FileManagerPrompts.swift
//  rootshell
//
//  Interactive auth for file manager connections: host keys (HostKeyPrompt),
//  keyboard-interactive challenges, unresolved synced keys, passwords and
//  sudo prompts.
//  One request is shown at a time; cancelling the caller rejects it.
//

import Foundation

@MainActor
@Observable
final class FileManagerPrompts {
    enum Request: Identifiable {
        case keyboardInteractive(KeyboardInteractiveChallenge, label: String)
        case keyResolution(SSHConfig, keys: [UnresolvedKeyInfo], profileID: UUID)
        case password(label: String)
        case sudo(SudoPrompt)

        var id: String {
            switch self {
            case .keyboardInteractive(_, let label): "ki-\(label)"
            case .keyResolution(_, _, let profileID): "keys-\(profileID)"
            case .password(let label): "password-\(label)"
            case .sudo(let prompt): "sudo-\(prompt.id)"
            }
        }
    }

    enum Answer {
        case responses([String])
        case config(SSHConfig)
        case password(String)
        case cancelled
    }

    let hostKey = HostKeyPrompt()
    private(set) var current: Request?
    private var continuation: CheckedContinuation<Answer, Never>?
    private(set) var isCancelled = false

    func keyboardInteractive(_ challenge: KeyboardInteractiveChallenge, label: String) async -> [String]? {
        guard case .responses(let responses) = await ask(.keyboardInteractive(challenge, label: label)) else { return nil }
        return responses
    }

    func resolveKeys(_ config: SSHConfig, keys: [UnresolvedKeyInfo], profileID: UUID) async -> SSHConfig? {
        guard case .config(let resolved) = await ask(.keyResolution(config, keys: keys, profileID: profileID)) else { return nil }
        return resolved
    }

    func password(label: String) async -> String? {
        guard case .password(let password) = await ask(.password(label: label)) else { return nil }
        return password
    }

    /// One sudo or PAM prompt; nil when the user cancels.
    func sudo(_ prompt: SudoPrompt) async -> String? {
        guard case .password(let answer) = await ask(.sudo(prompt)) else { return nil }
        return answer
    }

    func respond(_ answer: Answer) {
        let pending = continuation
        continuation = nil
        current = nil
        pending?.resume(returning: answer)
    }

    /// Cancels the active prompt and rejects any queued or future prompts owned by a closing window
    /// so shared connection tasks awaiting these prompts unblock immediately on teardown.
    func cancelAll() {
        isCancelled = true
        respond(.cancelled)
        hostKey.cancelAll()
    }

    private func ask(_ request: Request) async -> Answer {
        if isCancelled { return .cancelled }
        // Serialize like HostKeyPrompt: one sheet at a time, bail if cancelled while queued.
        while continuation != nil {
            if isCancelled { return .cancelled }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return .cancelled }
        }
        if isCancelled || Task.isCancelled { return .cancelled }
        let requestID = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.current = request
            }
        } onCancel: {
            Task { @MainActor in
                if self.current?.id == requestID { self.respond(.cancelled) }
            }
        }
    }
}
