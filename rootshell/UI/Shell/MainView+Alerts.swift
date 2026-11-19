//
//  MainView+Alerts.swift
//  rootshell
//
//  Alert UI for the unified main-alert queue: title, buttons, and messages
//  for the single `.alert` attachment. The queue/state machine itself lives
//  in MainAlertController (owned per-window as `alerts`).
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers
import RFBTransport

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Main Alert UI

    private var mainAlertTitle: String {
        switch alerts.presentedKind {
        #if !CHINA_BUILD
        case .aiAgentUnsupported:
            return aiAgentUnsupportedAlertTitle
        case .voiceAgentAPIKey:
            return String(localized: "Google API Key Required", comment: "Voice agent alert title")
        #endif
        case .hostKey:
            return alerts.hostKeyQueue.first?.alertTitle ?? "New SSH Host"
        case .helperMissing:
            return String(localized: "Rootshell Helper Required", comment: "Standalone helper alert title")
        case .herdrUpgrade:
            return alerts.herdrUpgradePrompt?.title ?? ""
        case .herdrTakeControl:
            return String(localized: "Tab Controlled by Another Client", comment: "herdr take-control alert title")
        case .profileUnavailable:
            return String(localized: "Profile Unavailable")
        case .vncProfileInvalid:
            return String(localized: "Screen Sharing Unavailable", comment: "Alert title for a VNC profile without a usable configuration")
        case .vncHighPerformanceTransport:
            return String(localized: "High Performance May Be Unreliable", comment: "Alert title for High Performance Screen Sharing on an unreliable transport or mesh VPN hostname")
        case .vncCertificate:
            return alerts.vncCertificateQueue.first?.isChanged == true
                ? String(localized: "Screen Sharing Certificate Changed", comment: "Changed VNC TLS certificate alert title")
                : String(localized: "Trust Screen Sharing Server?", comment: "New VNC TLS certificate alert title")
        case .agentApproval:
            return String(localized: "SSH Agent Request", comment: "SSH agent approval alert title")
        case .fileOpenFailed:
            return String(localized: "Couldn't Open File", comment: "Alert title when a shared file fails to import")
        case .gpgAgentApproval:
            // Title reflects the verb of the first queued request so
            // the user sees "Decrypt" vs "Sign" before the message.
            // Default to "Sign" when the queue is empty — the alert
            // is about to be dismissed and the title is throwaway.
            switch alerts.gpgAgentApprovalQueue.first?.verb ?? .sign {
            case .sign: return String(localized: "GPG Sign Request", comment: "GPG approval alert title")
            case .decrypt: return String(localized: "GPG Decrypt Request", comment: "GPG approval alert title")
            }
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .localAgentApproval:
            switch alerts.localAgentApprovalQueue.first?.subject {
            case .signature:
                return String(
                    localized: "Local SSH Agent Sign Request",
                    comment: "Alert title for local SSH agent signature approval"
                )
            case .addIdentity:
                return String(
                    localized: "Add SSH Agent Identity",
                    comment: "Alert title for local SSH agent ssh-add approval"
                )
            case .client, nil:
                return String(
                    localized: "Local SSH Agent Request",
                    comment: "Alert title for local SSH agent client approval"
                )
            }
        #endif
        case nil:
            return ""
        }
    }

    /// Captures what is on screen when the alert is built, like the buttons,
    /// so a dismissal SwiftUI reports after the queue advanced can't answer
    /// the next alert.
    private var mainAlertPresented: Binding<Bool> {
        let shownKind = alerts.presentedKind
        let hostKeyID = alerts.hostKeyQueue.first?.id
        let certificateID = alerts.vncCertificateQueue.first?.id
        return Binding(
            get: { alerts.presentedKind != nil },
            set: { isPresented in
                guard !isPresented else { return }
                switch shownKind {
                case .hostKey:
                    alerts.respondToHostKeyValidation(id: hostKeyID, with: .reject)
                case .vncCertificate:
                    alerts.respondToVNCCertificateValidation(id: certificateID, with: .reject)
                default:
                    guard alerts.presentedKind == shownKind else { return }
                    alerts.completePresented(clearBackingState: true)
                }
            }
        )
    }

    private var aiAgentUnsupportedAlertTitle: String {
#if targetEnvironment(macCatalyst)
        String(localized: "Unsupported Connection Type", comment: "AI Agent alert: unsupported connection on Mac")
#else
        String(localized: "SSH Connection Required", comment: "AI Agent alert: SSH required on iOS")
#endif
    }

    private var aiAgentUnsupportedAlertMessage: String {
#if targetEnvironment(macCatalyst)
        String(localized: "AI Agent works with SSH connections and the local Mac shell. This connection type (console, cloud) is not currently supported.", comment: "AI Agent alert: unsupported connection message on Mac")
#else
        String(localized: "AI Agent is only available for SSH connections. Connect to an SSH server first, then press ⌘I to launch the agent.", comment: "AI Agent alert: SSH required message on iOS")
#endif
    }

    // MARK: - Alert Modifiers

    @ViewBuilder
    func applyAlertModifiers<V: View>(_ view: V) -> some View {
        view
            .alert(mainAlertTitle, isPresented: mainAlertPresented) {
                switch alerts.presentedKind {
            #if !CHINA_BUILD
                case .aiAgentUnsupported, .voiceAgentAPIKey:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
            #endif
                case .hostKey:
                    // Capture the prompt on screen so each button answers it.
                    let prompt = alerts.hostKeyQueue.first
                    if prompt?.request.isKeyChanged == true {
                        Button("Cancel Connection", role: .cancel) {
                            alerts.respondToHostKeyValidation(id: prompt?.id, with: .reject)
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Replace & Connect", role: .destructive) {
                            alerts.respondToHostKeyValidation(id: prompt?.id, with: .accept)
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel", role: .cancel) {
                            alerts.respondToHostKeyValidation(id: prompt?.id, with: .reject)
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Connect Once") {
                            alerts.respondToHostKeyValidation(id: prompt?.id, with: .acceptOnce)
                        }
                        Button("Trust & Save") {
                            alerts.respondToHostKeyValidation(id: prompt?.id, with: .accept)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                case .helperMissing:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
                case .herdrUpgrade:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
                    Button("Copy Command") {
                        copyHerdrInstallCommand()
                        alerts.dismissActive()
                    }
                    Button("Show Instructions") {
                        alerts.dismissActive()
                        showHerdrInstallInstructions = true
                    }
                    .keyboardShortcut(.defaultAction)
                case .herdrTakeControl:
                    Button("Not Now", role: .cancel) {
                        alerts.dismissActive()
                    }
                    if alerts.herdrTakeControlRequest?.evictsOtherClient == true {
                        Button("Copy Upgrade Command") {
                            copyHerdrInstallCommand()
                            alerts.dismissActive()
                        }
                    }
                    Button("Take Control") {
                        if let request = alerts.herdrTakeControlRequest {
                            HerdrController.controller(forGateway: request.gatewayUUID)?.requestTakeControl(tabId: request.tabId)
                        }
                        alerts.dismissActive()
                    }
                    .keyboardShortcut(.defaultAction)
                case .profileUnavailable, .vncProfileInvalid:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
                case .vncHighPerformanceTransport:
                    Button("Continue High Performance") {
                        guard let request = alerts.takeNextVNCHighPerformanceConnection() else { return }
                        performVNCConnection(
                            config: request.config,
                            splitOption: request.splitOption,
                            sourceProfileID: request.sourceProfileID,
                            passwordHandoff: request.passwordHandoff
                        )
                    }
                    Button("Use Standard") {
                        guard var request = alerts.takeNextVNCHighPerformanceConnection() else { return }
                        request.config.quality = .standard
                        performVNCConnection(
                            config: request.config,
                            splitOption: request.splitOption,
                            sourceProfileID: request.sourceProfileID,
                            passwordHandoff: request.passwordHandoff
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                case .vncCertificate:
                    let requestID = alerts.vncCertificateQueue.first?.id
                    Button("Cancel", role: .cancel) {
                        alerts.respondToVNCCertificateValidation(id: requestID, with: .reject)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Connect Once") {
                        alerts.respondToVNCCertificateValidation(id: requestID, with: .acceptOnce)
                    }
                    Button("Trust & Save") {
                        alerts.respondToVNCCertificateValidation(id: requestID, with: .acceptAndStore)
                    }
                    .keyboardShortcut(.defaultAction)
                case .agentApproval:
                    Button("Deny", role: .cancel) {
                        alerts.respondToAgentApproval(approved: false)
                    }
                    Button("Approve") {
                        alerts.respondToAgentApproval(approved: true)
                    }
                    .keyboardShortcut(.defaultAction)
                case .gpgAgentApproval:
                    Button("Deny", role: .cancel) {
                        alerts.respondToGPGAgentApproval(approved: false)
                    }
                    Button("Approve") {
                        alerts.respondToGPGAgentApproval(approved: true)
                    }
                    .keyboardShortcut(.defaultAction)
                case .fileOpenFailed:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
                #if targetEnvironment(macCatalyst) && STANDALONE
                case .localAgentApproval:
                    Button(String(localized: "Deny", comment: "Local SSH agent approval button: deny"), role: .cancel) {
                        alerts.respondToLocalAgentApproval(.deny)
                    }
                    Button(String(localized: "Allow Once", comment: "Local SSH agent approval button: allow once")) {
                        alerts.respondToLocalAgentApproval(.allowOnce)
                    }
                    Button(String(localized: "Allow This Session", comment: "Local SSH agent approval button: allow for this app session")) {
                        alerts.respondToLocalAgentApproval(.allowSession)
                    }
                    if alerts.localAgentApprovalQueue.first?.canPersist == true {
                        Button(String(localized: "Always Allow", comment: "Local SSH agent approval button: persist allow rule")) {
                            alerts.respondToLocalAgentApproval(.alwaysAllow)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                #endif
                case nil:
                    EmptyView()
                }
            } message: {
                switch alerts.presentedKind {
                #if !CHINA_BUILD
                case .aiAgentUnsupported:
                    Text(aiAgentUnsupportedAlertMessage)
                case .voiceAgentAPIKey:
                    Text("Voice Agent requires a Google API key. Add one in Settings > AI Agent > Google Gemini.")
                #endif
                case .hostKey:
                    if let prompt = alerts.hostKeyQueue.first {
                        Text(prompt.request.message)
                    }
                case .helperMissing:
                    Text("Local shells on Mac require the separate Rootshell Helper app. Launch the helper and try again.")
                case .herdrUpgrade:
                    if let prompt = alerts.herdrUpgradePrompt {
                        Text(prompt.message)
                    }
                case .herdrTakeControl:
                    if let request = alerts.herdrTakeControlRequest {
                        Text(herdrTakeControlMessage(request))
                    }
                case .profileUnavailable:
                    Text("This local profile is unavailable on this device. Enable Show All Platforms in Profiles to edit its platform or repair its settings.")
                case .vncProfileInvalid:
                    Text("This profile has no usable Screen Sharing configuration. It may have been created by a newer version of the app - edit the profile or update the app.")
                case .vncHighPerformanceTransport:
                    Text("High Performance Screen Sharing can be unreliable over cellular or mesh VPN connections such as Tailscale and NetBird. Continue with High Performance or use Standard for this connection.")
                case .vncCertificate:
                    if let data = alerts.vncCertificateQueue.first {
                        let warning = data.isChanged
                            ? "The server certificate has changed. This can indicate that the server was reinstalled or that someone is intercepting the connection."
                            : "The server uses a certificate that is not trusted by this device. Verify the fingerprint before saving it."
                        Text("Session: \(data.sessionLabel)\n\n\(warning)\n\nSHA-256:\n\(data.fingerprint)")
                    }
                case .agentApproval:
                    if let request = alerts.agentApprovalQueue.first {
                        Text("Session: \(request.sessionName)\n\nAllow signing with key '\(request.keyName)'?\n\nFingerprint: \(request.fingerprint)")
                    }
                case .fileOpenFailed:
                    if let message = alerts.fileOpenErrorMessage {
                        Text(message)
                    }
                case .gpgAgentApproval:
                    if let request = alerts.gpgAgentApprovalQueue.first {
                        switch request.verb {
                        case .sign:
                            let algoText = request.hashAlgorithm?.displayName ?? "unknown hash"
                            Text("Session: \(request.sessionName)\n\nAllow `gpg` on the remote to sign with '\(request.keyName)'?\n\nHash: \(algoText) (\(request.hashPreview)…)\nFingerprint: \(request.fingerprint)")
                        case .decrypt:
                            Text("Session: \(request.sessionName)\n\nAllow `gpg` on the remote to decrypt with '\(request.keyName)'?\n\nFingerprint: \(request.fingerprint)")
                        }
                    }
                #if targetEnvironment(macCatalyst) && STANDALONE
                case .localAgentApproval:
                    if let request = alerts.localAgentApprovalQueue.first {
                        Text(localAgentApprovalMessage(request))
                    }
                #endif
                case nil:
                    EmptyView()
                }
            }
    }

    private func copyHerdrInstallCommand() {
        UIPasteboard.general.string = HerdrUpgradePrompt.installCommand
        ClipboardHistoryManager.shared.record(HerdrUpgradePrompt.installCommand, source: .explicitCopy)
    }

    private func herdrTakeControlMessage(_ request: MainAlertController.HerdrTakeControlRequest) -> String {
        var text = String(localized: "“\(request.tabTitle)” is being viewed by another herdr client. Taking control sizes it to this window.", comment: "herdr take-control alert message")
        if request.evictsOtherClient {
            text += "\n\n" + String(localized: "This host’s herdr allows one client per tab, so the other client is disconnected from it. Upgrade herdr on the host to view a tab from several devices at once.", comment: "herdr take-control alert message, single-owner server")
        }
        return text
    }

    #if targetEnvironment(macCatalyst) && STANDALONE
    private func localAgentApprovalMessage(_ request: LocalAgentApprovalRequest) -> String {
        var lines: [String] = []
        lines.append(String(
            localized: "Client: \(request.clientName)",
            comment: "Local SSH agent approval message client name line"
        ))
        lines.append(request.identityLine)
        if !request.clientPath.isEmpty {
            lines.append(String(
                localized: "Path: \(request.clientPath)",
                comment: "Local SSH agent approval message client executable path line"
            ))
        }
        if let destination = request.destination {
            lines.append(String(
                localized: "Destination: \(destination)",
                comment: "Local SSH agent approval message destination line"
            ))
        }
        lines.append("")
        switch request.subject {
        case .client:
            lines.append(String(
                localized: "Allow this client to use rootshell's local SSH agent?",
                comment: "Local SSH agent approval message for a client authorization request"
            ))
        case .signature(let keyName, let fingerprint):
            lines.append(String(
                localized: "Allow signing with key '\(keyName)'?",
                comment: "Local SSH agent approval message for a signature request"
            ))
            lines.append(String(
                localized: "Fingerprint: \(fingerprint)",
                comment: "Local SSH agent approval message key fingerprint line"
            ))
        case .addIdentity(let comment):
            lines.append(String(
                localized: "Allow this client to add ephemeral identity '\(comment)'?",
                comment: "Local SSH agent approval message for ssh-add identity request"
            ))
        }
        return lines.joined(separator: "\n")
    }
    #endif

}
