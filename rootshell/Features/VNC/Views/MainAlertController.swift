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
        case hostKey
        case helperMissing
        case herdrUpgrade
        case herdrTakeControl
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

    /// One connection's host-key prompt. Each carries its own continuation so
    /// overlapping prompts in a window resolve the connection they belong to.
    struct HostKeyPrompt: Identifiable {
        var id = UUID()
        /// The pane that asked; its teardown withdraws the prompt.
        let owner: UUID
        let sessionLabel: String
        var request: HostKeyValidationRequest
        /// Re-asked after the user approved against stale trust. The user
        /// still owes an explicit decision, so Connect Once can't settle it.
        var isReasked = false
        let continuation: CheckedContinuation<HostKeyValidationResult, Never>

        var alertTitle: String {
            request.isKeyChanged
                ? "⚠️ WARNING: Host Key Changed (\(sessionLabel))"
                : "New SSH Host (\(sessionLabel))"
        }
    }

    /// FIFO; the first entry is the one on screen.
    var hostKeyQueue: [HostKeyPrompt] = []

    var showHelperMissingAlert = false
    var showProfileUnavailableAlert = false

    /// herdr on a host must be installed or upgraded before control mode works.
    var herdrUpgradePrompt: HerdrUpgradePrompt?
    var showHerdrUpgradeAlert = false

    /// A herdr tab another client holds; the user decides whether to take it.
    struct HerdrTakeControlRequest {
        let gatewayUUID: UUID
        let tabId: String
        let tabTitle: String
        /// The server cannot share tabs, so taking control evicts the other client.
        let evictsOtherClient: Bool
    }
    var herdrTakeControlRequest: HerdrTakeControlRequest?
    var showHerdrTakeControlAlert = false

    func presentHerdrUpgrade(_ prompt: HerdrUpgradePrompt) {
        herdrUpgradePrompt = prompt
        showHerdrUpgradeAlert = true
    }

    func presentHerdrTakeControl(_ request: HerdrTakeControlRequest) {
        herdrTakeControlRequest = request
        showHerdrTakeControlAlert = true
    }

    /// A shared file failed to import (see FileOpenCoordinator).
    var fileOpenErrorMessage: String?
    var showFileOpenFailedAlert = false

    /// A Screen Sharing profile with no usable VNC configuration (e.g.
    /// synced from a newer build whose envelope this build can't decode).
    var showVNCProfileInvalidAlert = false

    /// A user-initiated High Performance Screen Sharing connection awaiting a
    /// transport warning decision. Its password handoff belongs to this
    /// attempt; if switching to Standard changes the route, the pane drops it.
    struct PendingVNCHighPerformanceConnection {
        var config: VNCConnectionConfig
        let splitOption: SSHConnectionView.SplitOption
        let sourceProfileID: UUID?
        let passwordHandoff: RemoteScreenPasswordHandoff?
    }

    var vncHighPerformanceConnectionQueue: [PendingVNCHighPerformanceConnection] = []
    var showVNCHighPerformanceTransportAlert = false

    /// One pane's certificate prompt, queued like `HostKeyPrompt`.
    struct VNCCertificateValidationRequest: Identifiable {
        var id = UUID()
        let owner: UUID
        let endpoint: String
        let fingerprint: String
        let sessionLabel: String
        /// The saved fingerprint the prompt was shown against; nil when the
        /// endpoint had none.
        var previouslyTrusted: String?
        let continuation: CheckedContinuation<VNCConfiguration.CertificateValidationResult, Never>

        var isChanged: Bool { previouslyTrusted != nil }
    }

    /// FIFO; the first entry is the one on screen.
    var vncCertificateQueue: [VNCCertificateValidationRequest] = []

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
            refreshQueueHead(for: kind)
            guard isAvailable(kind) else { return }
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
        case .hostKey:
            return !hostKeyQueue.isEmpty
        case .helperMissing:
            return showHelperMissingAlert
        case .herdrUpgrade:
            return showHerdrUpgradeAlert && herdrUpgradePrompt != nil
        case .herdrTakeControl:
            return showHerdrTakeControlAlert && herdrTakeControlRequest != nil
        case .profileUnavailable:
            return showProfileUnavailableAlert
        case .vncProfileInvalid:
            return showVNCProfileInvalidAlert
        case .vncHighPerformanceTransport:
            return !vncHighPerformanceConnectionQueue.isEmpty
        case .vncCertificate:
            return !vncCertificateQueue.isEmpty
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
            refreshQueueHead(for: next)
            if isAvailable(next) {
                presentedKind = next
                return
            }
        }
    }

    /// Re-checks trust for the queued prompt about to show. A prompt answered
    /// while it waited may have saved its key or certificate, or a different
    /// one for the same host.
    private func refreshQueueHead(for kind: Kind) {
        switch kind {
        case .hostKey:
            while let head = hostKeyQueue.first {
                switch head.request.recheck(honoringConnectOnce: !head.isReasked) {
                case .current:
                    return
                case .reclassified(let request):
                    hostKeyQueue[0].request = request
                    return
                case .trusted:
                    hostKeyQueue.removeFirst()
                    head.continuation.resume(returning: .accepted)
                }
            }
        case .vncCertificate:
            while let head = vncCertificateQueue.first {
                let saved = VNCCertificateTrustStore.savedFingerprint(for: head.endpoint)
                guard saved == head.fingerprint else {
                    vncCertificateQueue[0].previouslyTrusted = saved
                    return
                }
                vncCertificateQueue.removeFirst()
                head.continuation.resume(returning: .acceptOnce)
            }
        default:
            break
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

        if kind == .hostKey, !hostKeyQueue.isEmpty,
           !pendingKinds.contains(.hostKey) {
            pendingKinds.insert(.hostKey, at: 0)
        }

        if kind == .vncCertificate, !vncCertificateQueue.isEmpty,
           !pendingKinds.contains(.vncCertificate) {
            pendingKinds.insert(.vncCertificate, at: 0)
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
        case .hostKey, .vncCertificate:
            // Queued prompts hold live continuations; only their respond
            // functions may remove them.
            break
        case .helperMissing:
            showHelperMissingAlert = false
        case .herdrUpgrade:
            showHerdrUpgradeAlert = false
            herdrUpgradePrompt = nil
        case .herdrTakeControl:
            showHerdrTakeControlAlert = false
            herdrTakeControlRequest = nil
        case .profileUnavailable:
            showProfileUnavailableAlert = false
        case .vncProfileInvalid:
            showVNCProfileInvalidAlert = false
        case .vncHighPerformanceTransport:
            showVNCHighPerformanceTransportAlert = false
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
        await handleHostKeyValidation(
            request: request,
            sessionLabel: terminalView.connectionConfig.displayName,
            owner: terminalView.uuid)
    }

    /// Also serves connections without a terminal view (Screen Sharing and
    /// KVM jump tunnels).
    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        sessionLabel: String,
        owner: UUID
    ) async -> HostKeyValidationResult {
        guard admitsPrompt(from: owner) else { return .reject }
        return await withCheckedContinuation { continuation in
            hostKeyQueue.append(HostKeyPrompt(
                owner: owner,
                sessionLabel: sessionLabel,
                request: request,
                continuation: continuation))
            enqueue(.hostKey)
        }
    }

    /// `id` is the prompt the alert was built for, so a late or repeated
    /// button press can't answer the prompt queued behind it. The decision is
    /// recorded here, before the next prompt rechecks trust; the waiting
    /// connection gets `.accepted` and records nothing. An approval made
    /// against stale trust (another window saved a key while this alert was
    /// up) shows the prompt again with the current warning instead.
    func respondToHostKeyValidation(id: UUID?, with result: HostKeyValidationResult) {
        guard let id, let index = hostKeyQueue.firstIndex(where: { $0.id == id }) else { return }
        // Saved trust only: a Connect Once approval must not let this save
        // replace a key someone saved after the prompt was shown.
        if result != .reject, let current = hostKeyQueue[index].request.savedKeyChange() {
            hostKeyQueue[index].request = current
            hostKeyQueue[index].isReasked = true
            // A new id, so the dismissal of the alert just answered can't
            // reject the re-asked prompt.
            hostKeyQueue[index].id = UUID()
            if index == 0, presentedKind == .hostKey {
                completePresented(clearBackingState: false)
            }
            return
        }
        let prompt = hostKeyQueue.remove(at: index)
        prompt.request.record(result)
        if index == 0, presentedKind == .hostKey {
            completePresented(clearBackingState: false)
        }
        prompt.continuation.resume(returning: result == .reject ? .reject : .accepted)
    }

    /// `id` and stale-trust handling as in `respondToHostKeyValidation`.
    func respondToVNCCertificateValidation(
        id: UUID?,
        with result: VNCConfiguration.CertificateValidationResult
    ) {
        guard let id,
              let index = vncCertificateQueue.firstIndex(where: { $0.id == id }) else { return }
        if result != .reject {
            let request = vncCertificateQueue[index]
            let saved = VNCCertificateTrustStore.savedFingerprint(for: request.endpoint)
            if saved != request.fingerprint, saved != request.previouslyTrusted {
                vncCertificateQueue[index].previouslyTrusted = saved
                vncCertificateQueue[index].id = UUID()
                if index == 0, presentedKind == .vncCertificate {
                    completePresented(clearBackingState: false)
                }
                return
            }
        }
        let request = vncCertificateQueue.remove(at: index)
        if result == .acceptAndStore {
            VNCCertificateTrustStore.save(
                fingerprint: request.fingerprint,
                for: request.endpoint)
        }
        if index == 0, presentedKind == .vncCertificate {
            completePresented(clearBackingState: false)
        }
        request.continuation.resume(returning: result)
    }

    // MARK: - Trust Prompt Lifetime

    /// Panes closed in this window. A callback already on its way to the
    /// main actor when the pane closed must not queue a prompt after it.
    private var withdrawnOwners: Set<UUID> = []
    private var isWindowClosed = false

    func admitsPrompt(from owner: UUID) -> Bool {
        !isWindowClosed && !withdrawnOwners.contains(owner)
    }

    /// Rejects the prompts a closing pane left queued, and any it sends
    /// later, so none shows (and saves trust) for a connection that is gone.
    func withdrawPrompts(owner: UUID) {
        withdrawnOwners.insert(owner)
        reject(takePrompts { $0 == owner })
    }

    /// Window teardown: rejects queued prompts and refuses new ones.
    func closeWindow(windowId: String) {
        isWindowClosed = true
        if Self.controllersByWindow[windowId]?.controller === self {
            Self.controllersByWindow[windowId] = nil
        }
        reject(takePrompts { _ in true })
    }

    private typealias TakenPrompts = (hostKeys: [HostKeyPrompt], certificates: [VNCCertificateValidationRequest])

    /// Removes the owners' prompts without answering them, taking down the
    /// alert if it shows one.
    private func takePrompts(where matches: (UUID) -> Bool) -> TakenPrompts {
        let shownHostKey = presentedKind == .hostKey ? hostKeyQueue.first?.id : nil
        let shownCertificate = presentedKind == .vncCertificate ? vncCertificateQueue.first?.id : nil
        let hostKeys = hostKeyQueue.filter { matches($0.owner) }
        let certificates = vncCertificateQueue.filter { matches($0.owner) }
        hostKeyQueue.removeAll { matches($0.owner) }
        vncCertificateQueue.removeAll { matches($0.owner) }
        if let shownHostKey, hostKeys.contains(where: { $0.id == shownHostKey }) {
            completePresented(clearBackingState: false)
        }
        if let shownCertificate, certificates.contains(where: { $0.id == shownCertificate }) {
            completePresented(clearBackingState: false)
        }
        return (hostKeys, certificates)
    }

    private func reject(_ prompts: TakenPrompts) {
        for prompt in prompts.hostKeys {
            prompt.continuation.resume(returning: .reject)
        }
        for request in prompts.certificates {
            request.continuation.resume(returning: .reject)
        }
    }

    private func adopt(_ prompts: TakenPrompts) {
        hostKeyQueue += prompts.hostKeys
        vncCertificateQueue += prompts.certificates
        if !prompts.hostKeys.isEmpty { enqueue(.hostKey) }
        if !prompts.certificates.isEmpty { enqueue(.vncCertificate) }
    }

    // MARK: - Window Routing

    private struct WeakController {
        weak var controller: MainAlertController?
    }

    private static var controllersByWindow: [String: WeakController] = [:]

    static func attach(_ controller: MainAlertController, toWindow windowId: String) {
        controllersByWindow[windowId] = WeakController(controller: controller)
    }

    /// A tab moving between windows takes its queued prompts along, so they
    /// show, and are withdrawn, where the tab now lives. Without a live
    /// destination they stay, and the source's teardown rejects them.
    static func movePrompts(for tab: TabModel, from sourceWindowId: String, to destinationWindowId: String) {
        guard sourceWindowId != destinationWindowId,
              let source = controllersByWindow[sourceWindowId]?.controller,
              let destination = controllersByWindow[destinationWindowId]?.controller else { return }
        let owners = Set(tab.splitTree.map(\.uuid))
        destination.adopt(source.takePrompts { owners.contains($0) })
    }

    /// Remote screen sessions keep the callbacks they connected with while
    /// their tab can move windows, so each prompt goes to the window that
    /// holds the pane when it asks.
    static func routeHostKeyValidation(
        _ request: HostKeyValidationRequest,
        sessionLabel: String,
        from pane: (any RemoteScreenPane)?
    ) async -> HostKeyValidationResult {
        guard let pane, let controller = controllersByWindow[pane.windowId]?.controller else { return .reject }
        return await controller.handleHostKeyValidation(
            request: request,
            sessionLabel: sessionLabel,
            owner: pane.uuid)
    }

    static func routeCertificateValidation(
        _ request: VNCConfiguration.CertificateValidationRequest,
        sessionLabel: String,
        from pane: (any RemoteScreenPane)?
    ) async -> VNCConfiguration.CertificateValidationResult {
        guard let pane, let controller = controllersByWindow[pane.windowId]?.controller else { return .reject }
        return await controller.handleVNCCertificateValidation(
            request: request,
            sessionLabel: sessionLabel,
            owner: pane.uuid)
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

    // NOTE: no deinit — the queued prompt continuations must not be touched
    // from a nonisolated deinit. Window cleanup calls `closeWindow(windowId:)`.
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
