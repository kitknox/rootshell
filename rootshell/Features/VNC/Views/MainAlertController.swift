//
//  MainAlertController.swift
//  rootshell
//
//  Unified main-alert state machine for MainView, extracted from MainView
//  @State into an owned @Observable controller. One instance per window
//  (owned via @State), so each window queues and presents its own alerts.
//
//  Owns: the presented/pending alert-kind queue, the per-kind backing
//  flags, SSH host-key validation (continuation + data), and the SSH/GPG
//  agent approval queues. The alert UI itself (title, buttons, messages,
//  applyAlertModifiers) stays on MainView in MainViewAlerts.swift and
//  reads this controller.
//

import SwiftUI
import os
import CryptoKit
import rootshellVNC
import RFBTransport
#if targetEnvironment(macCatalyst) && STANDALONE
import UserNotifications
#endif

@MainActor @Observable final class MainAlertController {

    /// The kinds of alert routed through the single unified `.alert`
    /// attachment. Queued so concurrent triggers present one at a time.
    enum Kind: Equatable {
        #if !CHINA_BUILD
        case aiAgentUnsupported
        case voiceAgentAPIKey
        #endif
        case newHost
        case keyChanged
        case helperMissing
        case profileUnavailable
        case vncProfileInvalid
        case vncHighPerformanceTransport
        case vncCertificate
        case agentApproval
        case gpgAgentApproval
        case fileOpenFailed
        #if targetEnvironment(macCatalyst) && STANDALONE
        case localAgentApproval
        #endif
    }

    /// The alert currently on screen (nil = none). Writes go through
    /// enqueue/completePresented so queue mechanics stay consistent.
    private(set) var presentedKind: Kind?
    private var pendingKinds: [Kind] = []

    // MARK: - Backing state (one flag/queue per kind)

    // Host key validation state
    @ObservationIgnored var hostKeyValidationContinuation: CheckedContinuation<HostKeyValidationResult, Never>?
    var showNewHostAlert = false
    var showKeyChangedAlert = false
    var validationData: MainView.ValidationData?

    var showHelperMissingAlert = false
    var showProfileUnavailableAlert = false

    /// A shared file failed to import (see FileOpenCoordinator).
    var fileOpenErrorMessage: String?
    var showFileOpenFailedAlert = false

    /// A Screen Sharing profile with no usable VNC configuration (e.g.
    /// synced from a newer build whose envelope this build can't decode).
    var showVNCProfileInvalidAlert = false

    /// A user-initiated High Performance Screen Sharing connection awaiting a
    /// transport warning decision. The password is a one-shot value and is
    /// removed from this queue as soon as the user chooses a mode.
    struct PendingVNCHighPerformanceConnection {
        var config: VNCConnectionConfig
        let splitOption: SSHConnectionView.SplitOption
        let sourceProfileID: UUID?
        let password: String?
    }

    var vncHighPerformanceConnectionQueue: [PendingVNCHighPerformanceConnection] = []
    var showVNCHighPerformanceTransportAlert = false

    struct VNCCertificateValidationData {
        let endpoint: String
        let fingerprint: String
        let sessionLabel: String
        let isChanged: Bool
    }

    @ObservationIgnored var vncCertificateValidationContinuation:
        CheckedContinuation<VNCConfiguration.CertificateValidationResult, Never>?
    var vncCertificateValidationData: VNCCertificateValidationData?
    var showVNCCertificateAlert = false

    #if !CHINA_BUILD
    var showAIAgentSSHRequiredAlert = false
    var showVoiceAgentAPIKeyAlert = false
    #endif

    // SSH Agent approval state - queue to handle concurrent requests from different tabs
    var agentApprovalQueue: [SSHAgentApprovalRequest] = []
    var showAgentApprovalAlert = false

    // GPG Agent approval state — same queue/alert pattern as SSH
    // agent approval. Independent state so a GPG PKSIGN request that
    // arrives while an SSH agent prompt is on screen (or vice versa)
    // doesn't get lost.
    var gpgAgentApprovalQueue: [GPGAgentApprovalRequest] = []
    var showGPGAgentApprovalAlert = false

    #if targetEnvironment(macCatalyst) && STANDALONE
    var localAgentApprovalQueue: [LocalAgentApprovalRequest] = []
    var showLocalAgentApprovalAlert = false

    private static weak var keyWindowController: MainAlertController?
    private static weak var lastController: MainAlertController?

    static func registerWindowController(_ controller: MainAlertController, isKeyWindow: Bool) {
        lastController = controller
        if isKeyWindow {
            keyWindowController = controller
        } else if keyWindowController === controller {
            keyWindowController = nil
        }
    }

    static func routeLocalAgentApproval(_ request: LocalAgentApprovalRequest) {
        guard let controller = keyWindowController ?? lastController else {
            scheduleLocalAgentNotification(request)
            return
        }
        controller.handleLocalAgentApprovalRequest(request)
        controller.enqueue(.localAgentApproval)
    }

    static func removeLocalAgentApproval(id: UUID) {
        keyWindowController?.removeLocalAgentApprovalRequest(id: id)
        lastController?.removeLocalAgentApprovalRequest(id: id)
    }

    private static func scheduleLocalAgentNotification(_ request: LocalAgentApprovalRequest) {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "SSH key request",
            comment: "Local SSH agent notification title"
        )
        content.body = String(
            localized: "Request from \(request.clientName). Open rootshell to approve.",
            comment: "Local SSH agent notification body"
        )
        content.sound = .default
        let notification = UNNotificationRequest(
            identifier: "local-agent-\(request.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification)
    }
    #endif

    // MARK: - Queue mechanics

    func enqueue(_ kind: Kind) {
        guard isAvailable(kind) else { return }
        if presentedKind == nil {
            presentedKind = kind
            return
        }
        guard presentedKind != kind,
              !pendingKinds.contains(kind) else { return }
        pendingKinds.append(kind)
    }

    private func isAvailable(_ kind: Kind) -> Bool {
        switch kind {
        #if !CHINA_BUILD
        case .aiAgentUnsupported:
            return showAIAgentSSHRequiredAlert
        case .voiceAgentAPIKey:
            return showVoiceAgentAPIKeyAlert
        #endif
        case .newHost:
            return showNewHostAlert
        case .keyChanged:
            return showKeyChangedAlert
        case .helperMissing:
            return showHelperMissingAlert
        case .profileUnavailable:
            return showProfileUnavailableAlert
        case .vncProfileInvalid:
            return showVNCProfileInvalidAlert
        case .vncHighPerformanceTransport:
            return !vncHighPerformanceConnectionQueue.isEmpty
        case .vncCertificate:
            return showVNCCertificateAlert
        case .agentApproval:
            return !agentApprovalQueue.isEmpty
        case .gpgAgentApproval:
            return !gpgAgentApprovalQueue.isEmpty
        case .fileOpenFailed:
            return showFileOpenFailedAlert
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .localAgentApproval:
            return !localAgentApprovalQueue.isEmpty
        #endif
        }
    }

    private func presentNext() {
        guard presentedKind == nil else { return }
        while !pendingKinds.isEmpty {
            let next = pendingKinds.removeFirst()
            if isAvailable(next) {
                presentedKind = next
                return
            }
        }
    }

    func dismissActive() {
        completePresented(clearBackingState: true)
    }

    func completePresented(clearBackingState: Bool) {
        guard let kind = presentedKind else { return }
        presentedKind = nil

        if clearBackingState {
            self.clearBackingState(kind)
        }

        if kind == .agentApproval, !agentApprovalQueue.isEmpty,
           !pendingKinds.contains(.agentApproval) {
            pendingKinds.insert(.agentApproval, at: 0)
        }

        if kind == .gpgAgentApproval, !gpgAgentApprovalQueue.isEmpty,
           !pendingKinds.contains(.gpgAgentApproval) {
            pendingKinds.insert(.gpgAgentApproval, at: 0)
        }

        if kind == .vncHighPerformanceTransport, !vncHighPerformanceConnectionQueue.isEmpty,
           !pendingKinds.contains(.vncHighPerformanceTransport) {
            pendingKinds.insert(.vncHighPerformanceTransport, at: 0)
        }

        #if targetEnvironment(macCatalyst) && STANDALONE
        if kind == .localAgentApproval, !localAgentApprovalQueue.isEmpty,
           !pendingKinds.contains(.localAgentApproval) {
            pendingKinds.insert(.localAgentApproval, at: 0)
        }
        #endif

        DispatchQueue.main.async {
            self.presentNext()
        }
    }

    private func clearBackingState(_ kind: Kind) {
        switch kind {
        #if !CHINA_BUILD
        case .aiAgentUnsupported:
            showAIAgentSSHRequiredAlert = false
        case .voiceAgentAPIKey:
            showVoiceAgentAPIKeyAlert = false
        #endif
        case .newHost:
            showNewHostAlert = false
        case .keyChanged:
            showKeyChangedAlert = false
        case .helperMissing:
            showHelperMissingAlert = false
        case .profileUnavailable:
            showProfileUnavailableAlert = false
        case .vncProfileInvalid:
            showVNCProfileInvalidAlert = false
        case .vncHighPerformanceTransport:
            showVNCHighPerformanceTransportAlert = false
        case .vncCertificate:
            showVNCCertificateAlert = false
            vncCertificateValidationData = nil
        case .agentApproval:
            showAgentApprovalAlert = false
        case .gpgAgentApproval:
            showGPGAgentApprovalAlert = false
        case .fileOpenFailed:
            showFileOpenFailedAlert = false
            fileOpenErrorMessage = nil
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .localAgentApproval:
            showLocalAgentApprovalAlert = false
        #endif
        }
    }

    // MARK: - Shared-File Open Failure

    func handleFileOpenFailure(message: String) {
        fileOpenErrorMessage = message
        showFileOpenFailedAlert = true
        enqueue(.fileOpenFailed)
    }

    // MARK: - High Performance Screen Sharing Transport Warning

    func handleVNCHighPerformanceTransportWarning(_ request: PendingVNCHighPerformanceConnection) {
        vncHighPerformanceConnectionQueue.append(request)
        showVNCHighPerformanceTransportAlert = true
    }

    func takeNextVNCHighPerformanceConnection() -> PendingVNCHighPerformanceConnection? {
        guard !vncHighPerformanceConnectionQueue.isEmpty else {
            showVNCHighPerformanceTransportAlert = false
            return nil
        }

        let request = vncHighPerformanceConnectionQueue.removeFirst()
        showVNCHighPerformanceTransportAlert = !vncHighPerformanceConnectionQueue.isEmpty
        return request
    }

    // MARK: - SSH Host Key Validation

    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        terminalView: Ghostty.TerminalView
    ) async -> HostKeyValidationResult {
        return await withCheckedContinuation { continuation in
            let sessionLabel = terminalView.connectionConfig.displayName
            let alertContext = "(\(sessionLabel))"

            // Request already has the pre-formatted message
            validationData = MainView.ValidationData(
                alertTitle: request.isKeyChanged
                    ? "⚠️ WARNING: Host Key Changed \(alertContext)"
                    : "New SSH Host \(alertContext)",
                message: request.message,
                isKeyChanged: request.isKeyChanged
            )

            hostKeyValidationContinuation = continuation

            // Show the appropriate alert based on key change status
            if request.isKeyChanged {
                showKeyChangedAlert = true
            } else {
                showNewHostAlert = true
            }
        }
    }

    func respondToHostKeyValidation(with result: HostKeyValidationResult) {
        hostKeyValidationContinuation?.resume(returning: result)
        hostKeyValidationContinuation = nil
        showNewHostAlert = false
        showKeyChangedAlert = false
        validationData = nil
    }

    func respondToVNCCertificateValidation(
        with result: VNCConfiguration.CertificateValidationResult
    ) {
        if result == .acceptAndStore,
           let data = vncCertificateValidationData {
            VNCCertificateTrustStore.save(
                fingerprint: data.fingerprint,
                for: data.endpoint)
        }
        let continuation = vncCertificateValidationContinuation
        vncCertificateValidationContinuation = nil
        completePresented(clearBackingState: true)
        continuation?.resume(returning: result)
    }

    // MARK: - SSH Agent Approval

    func respondToAgentApproval(approved: Bool) {
        // Complete the current request (first in queue)
        if let currentRequest = agentApprovalQueue.first {
            currentRequest.completion(approved)
            agentApprovalQueue.removeFirst()
        }

        showAgentApprovalAlert = !agentApprovalQueue.isEmpty
    }

    func handleAgentApprovalRequest(_ request: SSHAgentApprovalRequest) {
        let queueCountBefore = agentApprovalQueue.count
        let alertShowing = showAgentApprovalAlert
        Ghostty.logger.info("Agent approval request received for key: \(request.keyName), queue size before: \(queueCountBefore), alert showing: \(alertShowing)")
        agentApprovalQueue.append(request)
        // Show alert if not already showing
        if !showAgentApprovalAlert {
            showAgentApprovalAlert = true
        }
        let queueCountAfter = agentApprovalQueue.count
        Ghostty.logger.info("Agent approval queue size after: \(queueCountAfter)")
    }

    // MARK: - GPG Agent Approval

    func respondToGPGAgentApproval(approved: Bool) {
        if let currentRequest = gpgAgentApprovalQueue.first {
            currentRequest.completion(approved)
            gpgAgentApprovalQueue.removeFirst()
        }
        showGPGAgentApprovalAlert = !gpgAgentApprovalQueue.isEmpty
    }

    func handleGPGAgentApprovalRequest(_ request: GPGAgentApprovalRequest) {
        let queueCountBefore = gpgAgentApprovalQueue.count
        Ghostty.logger.info("GPG approval request for key: \(request.keyName), queue size before: \(queueCountBefore)")
        gpgAgentApprovalQueue.append(request)
        if !showGPGAgentApprovalAlert {
            showGPGAgentApprovalAlert = true
        }
    }

    /// Drop a queued GPG approval prompt that the source session no
    /// longer wants surfaced — currently fired from session teardown
    /// (CitadelSSHSession / TrzszSession cleanup → GPGAgentManager.
    /// cancelPendingApprovals → withdrawn publisher). Without this the
    /// queue would keep a sheet up for a connection that's already
    /// gone; approving it would be a no-op and dismissing would
    /// surface the next stale request behind it.
    func removeGPGAgentApprovalRequest(id: UUID) {
        let beforeCount = gpgAgentApprovalQueue.count
        gpgAgentApprovalQueue.removeAll(where: { $0.id == id })
        let removed = beforeCount - gpgAgentApprovalQueue.count
        if removed > 0 {
            let remaining = gpgAgentApprovalQueue.count
            Ghostty.logger.info("GPG approval withdrawn (id removed from queue), remaining: \(remaining)")
        }
        // Hide the alert if the currently-displayed entry was the
        // one we just dropped (it'd already be off the queue, so the
        // shown? guard at the binding site flips false).
        showGPGAgentApprovalAlert = !gpgAgentApprovalQueue.isEmpty
    }

    #if targetEnvironment(macCatalyst) && STANDALONE
    // MARK: - Local SSH_AUTH_SOCK Agent Approval

    func handleLocalAgentApprovalRequest(_ request: LocalAgentApprovalRequest) {
        localAgentApprovalQueue.append(request)
        showLocalAgentApprovalAlert = true
    }

    func respondToLocalAgentApproval(_ decision: LocalAgentApprovalRequest.Decision) {
        if let currentRequest = localAgentApprovalQueue.first {
            currentRequest.completion(decision)
            localAgentApprovalQueue.removeFirst()
        }
        showLocalAgentApprovalAlert = !localAgentApprovalQueue.isEmpty
    }

    func removeLocalAgentApprovalRequest(id: UUID) {
        localAgentApprovalQueue.removeAll { $0.id == id }
        showLocalAgentApprovalAlert = !localAgentApprovalQueue.isEmpty
    }
    #endif

    // NOTE: no deinit — `hostKeyValidationContinuation` is non-Sendable and
    // must not be touched from a nonisolated deinit. A continuation dropped
    // un-resumed when a window dies mid-prompt matches the previous @State
    // behavior.
}

enum VNCCertificateTrustStore {
    private static let defaultsKey = "trustedVNCCertificateFingerprints"

    static func endpointKey(host: String, port: UInt16) -> String {
        "\(host.lowercased()):\(port)"
    }

    static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    static func savedFingerprint(for endpoint: String) -> String? {
        let values = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: String]
        return values?[endpoint]
    }

    static func save(fingerprint: String, for endpoint: String) {
        var values = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: String] ?? [:]
        values[endpoint] = fingerprint
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }
}
