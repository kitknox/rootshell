//
//  NotificationService.swift
//  PushNotificationService
//
//  Decrypts rootshell push envelopes before display. Decryption happens
//  before any best-effort work (dedupe, logo) so a time-budget expiry still
//  delivers the real content; only a failed decrypt shows the generic
//  fallback.
//

import RootshellPushKit
import UserNotifications
import os

// Callbacks arrive on a system queue, never the main thread. The Live
// Activity path hands over from a detached task and a timer; every shared
// field they touch goes through `finishLock`, hence the unchecked Sendable.
nonisolated final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "PushNSE")

    /// Guards the one-shot hand-over: the Live Activity path, its cap and
    /// `serviceExtensionTimeWillExpire` can all race to `finish`.
    private let finishLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    /// Set once the decrypted header has been applied to `content`.
    private var decrypted: UNMutableNotificationContent?
    private var eid = "-"

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        guard let envelope = PushEnvelope(userInfo: request.content.userInfo) else {
            Self.logger.error("envelope parse failed: no usable rs payload")
            finish(fallback(content))
            return
        }
        eid = envelope.eid
        do {
            let header = try decorate(content, envelope: envelope)
            #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
            if let header, LiveActivityAgentUpdater.handles(header) {
                // Fold the push into the Live Activity before the banner is
                // handed over: the process may be suspended right after. The
                // callback queue is not blocked, and `finish` is one-shot, so
                // whichever of the update or the cap comes first delivers.
                let eid = envelope.eid
                Task.detached(priority: .userInitiated) { [weak self] in
                    await LiveActivityAgentUpdater.apply(header: header, eid: eid)
                    self?.finishDecrypted()
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.liveActivityUpdateCap) { [weak self] in
                    guard let self, self.finishDecrypted() else { return }
                    Self.logger.error("live activity update timed out eid=\(eid, privacy: .public); banner delivered")
                }
                return
            }
            #endif
            finish(content)
        } catch {
            Self.logger.error("push decrypt failed eid=\(self.eid, privacy: .public): \(String(describing: error), privacy: .public)")
            finish(fallback(content))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let decrypted {
            Self.logger.error("expired eid=\(self.eid, privacy: .public): delivering decrypted content without attachments")
            decrypted.attachments = []
            finish(decrypted)
        } else if let content {
            Self.logger.error("expired eid=\(self.eid, privacy: .public): delivering fallback")
            finish(fallback(content))
        }
    }

    /// Longest the banner waits for the Live Activity update.
    private static let liveActivityUpdateCap: DispatchTimeInterval = .seconds(2)

    /// Hands the content over exactly once. Returns true for the call that
    /// actually delivered.
    @discardableResult
    private func finish(_ content: UNNotificationContent) -> Bool {
        finishLock.lock()
        let handler = contentHandler
        contentHandler = nil
        finishLock.unlock()
        guard let handler else { return false }
        handler(content)
        return true
    }

    /// `finish` with the already-decorated content, for the callers that run
    /// off the callback queue and must not capture it.
    @discardableResult
    private func finishDecrypted() -> Bool {
        finishLock.lock()
        let content = decrypted
        finishLock.unlock()
        guard let content else { return false }
        return finish(content)
    }

    private func fallback(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        content.title = "rootshell"
        content.body = String(localized: "Encrypted notification. Open rootshell to view.")
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        var info = content.userInfo
        info[PushConfiguration.fallbackUserInfoKey] = true
        content.userInfo = info
        return content
    }

    /// The relay keeps no state, so revoked senders and stale registrations
    /// are filtered here. A rejected push is blanked; the app removes it.
    private func silence(_ content: UNMutableNotificationContent, reason: String) -> UNNotificationContent {
        Self.logger.info("silenced eid=\(self.eid, privacy: .public): \(reason, privacy: .public)")
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.userInfo = [PushConfiguration.rejectedUserInfoKey: true]
        return content
    }

    /// Returns the decrypted header, or nil when the push was silenced and
    /// already handed over.
    @discardableResult
    private func decorate(_ content: UNMutableNotificationContent, envelope: PushEnvelope) throws -> PushHeader? {
        let shared = PushSharedState()
        let policy = shared.loadPolicy()
        guard policy.accepts(envelope) else {
            finish(silence(content, reason: "policy"))
            return nil
        }
        guard let key = try PushConfiguration.keychain.loadPrivateKey() else { throw PushCryptoError.noPrivateKey }
        let header = try envelope.open(with: key)

        content.title = header.title
        content.body = header.body ?? ""
        content.subtitle = header.statusSubtitle ?? ""
        content.threadIdentifier = "push-\(header.thread ?? envelope.eid)"
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.relevanceScore = header.status == "blocked" ? 1 : 0.5
        if header.status == "blocked" { content.interruptionLevel = .timeSensitive }
        var info = content.userInfo
        info[PushConfiguration.headerUserInfoKey] = try header.userInfoDictionary()
        content.userInfo = info
        finishLock.lock()
        decrypted = content
        finishLock.unlock()

        // APNs uses eid as the collapse id, so a relay retry updates the same
        // notification. Keep the claim as one-shot ledger bookkeeping, but
        // never replace already-decrypted content with a blank notification:
        // iOS can resurface the original encrypted placeholder while applying
        // that collapsed update.
        if !shared.claim(PushEventRecord(header: header, eid: envelope.eid)) {
            Self.logger.info("redelivered eid=\(self.eid, privacy: .public): keeping decrypted content")
        }

        if header.kind == "agent", policy.showsAgentLogos {
            if let logo = PushAgentLogoAttachment.attachment(for: header.agent) {
                content.attachments = [logo]
            } else if header.agent != nil {
                Self.logger.info("logo skipped eid=\(self.eid, privacy: .public): agent \(header.agent ?? "-", privacy: .public)")
            }
        }
        return header
    }
}
