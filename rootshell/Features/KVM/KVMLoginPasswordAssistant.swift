//
//  KVMLoginPasswordAssistant.swift
//  rootshell
//
//  Types a KVM profile's saved computer password into the session after
//  the user confirms, and offers to when the video shows a login screen.
//  The password stays in the Keychain until the moment it's typed.
//

import CoreVideo
import Foundation
import os
import rootshellVNC

@MainActor
@Observable
final class KVMLoginPasswordAssistant {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KVM")

    /// A login screen was seen; the pane asks before typing anything.
    private(set) var promptPending = false
    /// Drives the confirmation dialog.
    var isConfirming = false
    /// Shown when a confirmed send finds no readable password.
    var sendFailureMessage: String?

    @ObservationIgnored var profileID: UUID?
    @ObservationIgnored private let detectsLoginScreen: Bool
    @ObservationIgnored private weak var session: KVMSession?

    @ObservationIgnored private var wantsFrames = false
    @ObservationIgnored private var latestFrame: KVMDecodedFrame?
    @ObservationIgnored private var frameSerial: UInt64 = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastDelivery: ContinuousClock.Instant?

    private static let maximumAttempts = 3
    /// A waking display fades in, so the first look waits a moment.
    private static let settleDelay: Duration = .milliseconds(1500)
    private static let attemptInterval: Duration = .seconds(1)
    /// The login screen lingers while a typed password is checked.
    private static let deliveryQuietPeriod: Duration = .seconds(10)

    init(session: KVMSession, detectsLoginScreen: Bool) {
        self.session = session
        self.detectsLoginScreen = detectsLoginScreen
    }

    var passwordKey: String? {
        profileID.map { KVMConnectionConfig.hostPasswordKey(profileID: $0) }
    }

    /// Reads the manager's revision so views re-check after an edit.
    var hasSavedPassword: Bool {
        guard let passwordKey else { return false }
        let passwords = VNCPasswordManager.kvmHost
        _ = passwords.revision
        return passwords.hasPassword(for: passwordKey)
    }

    var canSend: Bool {
        guard let session, session.connectionState.isConnected, session.hid.keyboardOnline else { return false }
        return hasSavedPassword
    }

    // MARK: - Sending

    /// The HUD's Type Computer Password.
    func requestSend() {
        guard canSend else { return }
        isConfirming = true
    }

    /// Turns a detected login screen into the dialog once the pane shows.
    func presentPendingPrompt() {
        guard promptPending else { return }
        promptPending = false
        if canSend { isConfirming = true }
    }

    /// Only after the user confirmed. The password is read here and not kept.
    func send(pressingReturn: Bool) {
        guard let session, let passwordKey else { return }
        promptPending = false
        let password: String
        do {
            password = try VNCPasswordManager.kvmHost.loadPassword(for: passwordKey)
        } catch {
            Self.logger.error("KVM computer password unavailable: \(error.localizedDescription, privacy: .public)")
            sendFailureMessage = String(localized: "The saved computer password couldn't be read from the Keychain.")
            return
        }
        lastDelivery = .now
        session.typeLoginPassword(password, pressingReturn: pressingReturn)
        Self.logger.info("Typed the KVM computer password (return: \(pressingReturn))")
    }

    // MARK: - Login screen detection

    func noteFrame(_ pixelBuffer: CVPixelBuffer) {
        guard wantsFrames else { return }
        latestFrame = KVMDecodedFrame(pixelBuffer: pixelBuffer)
        frameSerial &+= 1
    }

    /// Looks at the next few frames after a moment when a login screen is
    /// likely: first video, the computer waking, or a resolution change.
    func arm(reason: String) {
        guard detectsLoginScreen, !promptPending, hasSavedPassword else { return }
        scanTask?.cancel()
        latestFrame = nil
        wantsFrames = true
        Self.logger.debug("KVM login screen check armed: \(reason, privacy: .public)")
        scanTask = Task { [weak self] in
            await self?.scan()
        }
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        wantsFrames = false
        latestFrame = nil
        promptPending = false
        isConfirming = false
    }

    private func scan() async {
        var analyzedSerial: UInt64?
        for attempt in 1...Self.maximumAttempts {
            try? await Task.sleep(for: attempt == 1 ? Self.settleDelay : Self.attemptInterval)
            guard !Task.isCancelled else { return }
            // A static screen sends no new frames; one look is enough.
            guard let frame = latestFrame, frameSerial != analyzedSerial else { continue }
            analyzedSerial = frameSerial
            let analysis = await Task.detached(priority: .utility) {
                try? KVMLoginScreenDetector.recognize(pixelBuffer: frame.pixelBuffer)
            }.value
            guard !Task.isCancelled else { return }
            if let analysis {
                Self.logger.debug("KVM login screen check \(attempt): \(analysis.evidence, privacy: .public)")
            }
            if analysis?.isLoginScreen == true {
                offer()
                break
            }
        }
        wantsFrames = false
        latestFrame = nil
        scanTask = nil
    }

    private func offer() {
        if let lastDelivery, ContinuousClock.now - lastDelivery < Self.deliveryQuietPeriod { return }
        guard canSend else { return }
        promptPending = true
    }
}
