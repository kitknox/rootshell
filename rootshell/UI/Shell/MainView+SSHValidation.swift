//
//  MainView+SSHValidation.swift
//  rootshell
//
//  SSH host key validation and agent approval handling for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os

// MARK: - SSH Host Key Validation

extension MainView {
    /// Bind prompts and approval callbacks to this `MainView` instance.
    /// Live tabs can move across windows, so these closures must be rebound
    /// after transfer instead of keeping the source window captured forever.
    func wireWindowScopedCallbacks(on terminalView: Ghostty.TerminalView) {
        let trackedTerminal = terminalView
        terminalView.onAuthenticationRequired = { @MainActor @Sendable [weak trackedTerminal] config in
            if let trackedTerminal {
                self.handleAuthenticationRequired(for: trackedTerminal, config: config)
            }
        }
        terminalView.onHostKeyValidationRequired = { @MainActor @Sendable request, validatedTerminal in
            await self.handleHostKeyValidation(request: request, terminalView: validatedTerminal)
        }
        terminalView.onAgentApprovalRequired = { @MainActor @Sendable request in
            self.handleAgentApprovalRequest(request)
        }
        wireGPGApprovalCallbacks(on: terminalView)
    }

    func rebindWindowScopedCallbacks(for tab: TabModel) {
        for terminalView in tab.splitTree.terminalLeaves {
            wireWindowScopedCallbacks(on: terminalView)
        }
    }

    /// Thin forwarder to the per-window alert controller. Kept on MainView
    /// with an unchanged signature so callback wiring here and in
    /// MainViewPersistence/MainViewSplits compiles untouched.
    @MainActor
    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        terminalView: Ghostty.TerminalView
    ) async -> HostKeyValidationResult {
        await alerts.handleHostKeyValidation(request: request, terminalView: terminalView)
    }
}

// MARK: - SSH Agent Approval

extension MainView {

    /// Thin forwarder to the per-window alert controller (see
    /// handleHostKeyValidation above for why these stay on MainView).
    func handleAgentApprovalRequest(_ request: SSHAgentApprovalRequest) {
        alerts.handleAgentApprovalRequest(request)
    }
}

// MARK: - GPG Agent Approval
//
// Parallels the SSH-agent flow above. Each forwarded GPG `PKSIGN`
// request from a remote session routes to the per-window
// MainAlertController, which queues it and surfaces the next one as an
// alert. The buttons and message text live in MainViewAlerts.swift.

extension MainView {

    /// Wire the SSH interactive callbacks that every freshly-created TerminalView
    /// needs: GPG agent approval (both directions) and keyboard-interactive
    /// (RFC 4256) challenges. Called at every SSH terminal-creation site, so a
    /// change to the callback shape only has to update one place — and it
    /// guarantees keyboard-interactive is wired wherever host-key validation is.
    func wireGPGApprovalCallbacks(on terminalView: Ghostty.TerminalView) {
        terminalView.onGPGAgentApprovalRequired = { @MainActor @Sendable request in
            self.alerts.handleGPGAgentApprovalRequest(request)
        }
        terminalView.onGPGAgentApprovalWithdrawn = { @MainActor @Sendable requestID in
            self.alerts.removeGPGAgentApprovalRequest(id: requestID)
        }
        terminalView.onKeyboardInteractiveChallengeRequired = { @MainActor @Sendable challenge, validatedTerminal in
            await self.handleKeyboardInteractiveChallenge(challenge, terminalView: validatedTerminal)
        }
    }
}

// MARK: - Keyboard-Interactive (RFC 4256) Challenges
//
// A keyboard-interactive challenge is async: the auth delegate awaits one
// response array per round (`[String]?`, nil = cancel). We model each pending
// challenge with its continuation in a queue (multiple sessions can challenge
// concurrently) and present the first via a sheet. Unlike the agent/GPG alerts,
// this needs free-form text entry, so it uses a sheet rather than an alert.

/// A queued keyboard-interactive challenge awaiting the user's responses.
struct PendingKeyboardInteractiveChallenge: Identifiable {
    let id = UUID()
    let challenge: KeyboardInteractiveChallenge
    let sessionLabel: String
    /// Identity of the originating TerminalView, used to withdraw the prompt if
    /// that session tears down before the user responds.
    let terminalID: ObjectIdentifier
    let continuation: CheckedContinuation<[String]?, Never>
    /// Factory for the session's live auth-banner state stream, shown
    /// display-only inside the prompt sheet. The sheet is modal, so on iPhone
    /// it hides the pane's auth-banner card exactly when OTP-style banner
    /// instructions matter — this carries them into the sheet. A factory
    /// rather than a stream because each stream is single-consumption; the
    /// view's `.task` makes a fresh one per appearance. Live: banners
    /// arriving while the sheet is up still appear.
    let authBannerStates: (@MainActor () -> AsyncStream<SSHAuthBannerCardState?>)?
}

extension MainView {

    @MainActor
    func handleKeyboardInteractiveChallenge(
        _ challenge: KeyboardInteractiveChallenge,
        terminalView: Ghostty.TerminalView
    ) async -> [String]? {
        await withCheckedContinuation { continuation in
            let label = challenge.sessionName.isEmpty
                ? terminalView.connectionConfig.displayName
                : challenge.sessionName
            let entry = PendingKeyboardInteractiveChallenge(
                challenge: challenge,
                sessionLabel: label,
                terminalID: ObjectIdentifier(terminalView),
                continuation: continuation,
                authBannerStates: (terminalView.session as? SSHAuthBannerCardProviding)
                    .map { provider in { @MainActor in provider.authBannerCardStates() } }
            )
            keyboardInteractiveQueue.append(entry)
            if !showKeyboardInteractivePrompt {
                showKeyboardInteractivePrompt = true
            }
        }
    }

    /// Complete the currently-displayed challenge. `nil` responses = cancelled.
    @MainActor
    func respondToKeyboardInteractive(_ responses: [String]?) {
        if let current = keyboardInteractiveQueue.first {
            current.continuation.resume(returning: responses)
            keyboardInteractiveQueue.removeFirst()
        }
        showKeyboardInteractivePrompt = !keyboardInteractiveQueue.isEmpty
    }

    /// Cancel any pending challenge from a session that is tearing down, so the
    /// awaiting auth delegate doesn't park until the SSH login timeout.
    @MainActor
    func withdrawKeyboardInteractive(for terminalView: Ghostty.TerminalView) {
        let target = ObjectIdentifier(terminalView)
        var remaining: [PendingKeyboardInteractiveChallenge] = []
        for entry in keyboardInteractiveQueue {
            if entry.terminalID == target {
                entry.continuation.resume(returning: nil)
            } else {
                remaining.append(entry)
            }
        }
        keyboardInteractiveQueue = remaining
        showKeyboardInteractivePrompt = !keyboardInteractiveQueue.isEmpty
    }
}
