//
//  PushNotificationRouter.swift
//  rootshell
//
//  Presentation, tap routing, and cross-source arbitration for decrypted
//  push notifications (category com.rootshell.push). Routes resolve to the
//  window + tab + pane the hook ran in, including tmux and herdr control panes.
//

import Foundation
import RootshellPushKit
import UIKit
import UserNotifications
import os

@MainActor
enum PushNotificationRouter {
    private static let logger = Logger(subsystem: "com.rootshell", category: "PushRouter")

    struct Resolved: Equatable {
        let windowId: String
        let tabID: UUID
        let surfaceID: UUID
    }

    private struct PendingRoute {
        let route: PushRoute
        let expires: Date
    }

    @MainActor
    private final class NotificationWaiter {
        var observer: NSObjectProtocol?
        var timeoutTask: Task<Void, Never>?
        var continuation: CheckedContinuation<Void, Never>?

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume()
        }
    }

    private static var pending: PendingRoute?
    private static var deliveryReconciler = PushDeliveryReconciler()
    private static var deliverySyncTask: Task<Void, Never>?
    private static var deliverySyncRequested = false
    private static var deliveredIdentifiers: [UUID: Set<String>] = [:]

    // MARK: - Header

    static func header(from userInfo: [AnyHashable: Any]) -> PushHeader? {
        guard let dict = userInfo[PushConfiguration.headerUserInfoKey],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(PushHeader.self, from: data)
    }

    /// Header from the extension, or decrypted here as a fallback when the
    /// extension did not decorate the push (it failed, or never ran).
    static func decryptedHeader(from userInfo: [AnyHashable: Any]) -> (header: PushHeader, decryptedLocally: Bool)? {
        if let h = header(from: userInfo) { return (h, false) }
        guard let env = PushEnvelope(userInfo: userInfo), isAccepted(env),
              let key = try? PushConfiguration.keychain.loadPrivateKey(),
              let h = try? env.open(with: key) else { return nil }
        return (h, true)
    }

    /// Revoked senders and stale registrations are enforced here; the relay keeps no state.
    static func isAccepted(_ env: PushEnvelope) -> Bool {
        PushSharedState().loadPolicy().accepts(env)
    }

    static func isRejected(_ userInfo: [AnyHashable: Any]) -> Bool {
        if userInfo[PushConfiguration.rejectedUserInfoKey] != nil { return true }
        if let env = PushEnvelope(userInfo: userInfo), !isAccepted(env) { return true }
        return false
    }

    /// Re-posts a raw push as a local notification carrying the decrypted content.
    private static func presentLocally(_ header: PushHeader, eid: String, sound: UNNotificationSound?) async {
        let shared = PushSharedState()
        let content = UNMutableNotificationContent()
        content.title = header.title
        content.body = header.body ?? ""
        content.subtitle = header.statusSubtitle ?? ""
        content.threadIdentifier = "push-\(header.thread ?? eid)"
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.relevanceScore = header.status == "blocked" ? 1 : 0.5
        if header.status == "blocked" { content.interruptionLevel = .timeSensitive }
        content.sound = sound
        if header.kind == "agent", shared.loadPolicy().showsAgentLogos,
           let logo = PushAgentLogoAttachment.attachment(for: header.agent) {
            content.attachments = [logo]
        }
        if let dict = try? header.userInfoDictionary() {
            content.userInfo = [PushConfiguration.headerUserInfoKey: dict]
        }
        // The stable local identifier below makes retries idempotent. The
        // claim only controls ledger bookkeeping; a duplicate must still
        // replace any raw encrypted notification with decrypted content.
        let record = PushEventRecord(header: header, eid: eid)
        let createdClaim = shared.claim(record)
        if !createdClaim {
            logger.info("replacing redelivered eid=\(eid, privacy: .public) with decrypted content")
        }
        // A suppressed remote push still lands in Notification Center history on
        // macOS. Drop the raw copy before posting the decrypted one so the two
        // are never on screen together; syncDelivered catches stragglers.
        await removeRawDelivered(eid: eid)
        let request = UNNotificationRequest(identifier: "push-\(eid)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("local re-post failed: \(String(describing: error), privacy: .public)")
            if createdClaim { shared.release(eid: eid) }
            return
        }
        // This may run after syncDelivered's initial history read. Keep the
        // replacement's identifier even if routing is not ready yet.
        deliveryReconciler.ingest(shared.load())
        if createdClaim { deliveryReconciler.ingest([record]) }
        deliveryReconciler.trackFresh(identifier: request.identifier, header: header, receivedAt: record.receivedAt)
        reconcileDeliveries()
    }

    static func attentionStatus(_ status: String?) -> AgentAttentionStatus? {
        switch status {
        case "done": return .done
        case "blocked": return .blocked
        case "failed": return .failed
        default: return nil
        }
    }

    // MARK: - Resolution

    /// Resolve only stable identities. A regular pane is identified by its
    /// TerminalView UUID. A control-mode pane is identified independently of
    /// any rootshell client by its canonical tmux server lifetime plus the
    /// server-global tmux pane ID, or herdr namespace plus terminal ID.
    /// The host and working directory fields are descriptive metadata,
    /// never routing keys.
    static func resolve(_ route: PushRoute?) -> Resolved? {
        guard let route else { return nil }
        if route.hasHerdrRoute { return resolveHerdr(route) }
        let paneUUID = route.pane.flatMap(UUID.init(uuidString:))
        let tmuxPaneId = route.tmuxPane.flatMap {
            $0.hasPrefix("%") ? Int($0.dropFirst()) : nil
        }
        var canonicalTmuxMatches: [Resolved] = []
        var legacyBoundMatches: [Resolved] = []
        var unboundUUIDMatches: [Resolved] = []

        for (windowId, model) in TmuxWindowRegistry.allWindows() {
            for tab in model.tabs {
                for pane in tab.splitTree {
                    guard let view = pane as? Ghostty.TerminalView else { continue }
                    let resolved = Resolved(
                        windowId: windowId,
                        tabID: tab.id,
                        surfaceID: view.uuid
                    )
                    if let tmuxPaneId, let binding = view.tmuxPaneBinding,
                       binding.paneId == tmuxPaneId,
                       let tmuxServer = route.tmuxServer,
                       let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                       controller.ownerTerminalUUIDForNotifications == binding.parentUUID,
                       controller.pushRouteServerIdentity == tmuxServer {
                        canonicalTmuxMatches.append(resolved)
                    } else if route.tmuxServer == nil,
                              let paneUUID, let tmuxPaneId,
                              let binding = view.tmuxPaneBinding,
                              binding.parentUUID == paneUUID,
                              binding.paneId == tmuxPaneId {
                        // Exact compatibility path for notifications sent by a
                        // pre-canonical rootshell-notify build.
                        legacyBoundMatches.append(resolved)
                    } else if let paneUUID,
                              view.tmuxPaneBinding == nil,
                              view.tmuxController?.isActive != true,
                              view.herdrPaneBinding == nil,
                              view.herdrController?.didEnd != false,
                              view.uuid == paneUUID {
                        // Ordinary (non-control-mode) tmux sets TMUX_PANE but
                        // remains a regular terminal view. Its UUID is still
                        // an exact identity, not a heuristic fallback. Never
                        // select a control-mode gateway while its canonical
                        // server query or projected panes are still pending.
                        unboundUUIDMatches.append(resolved)
                    }
                }
            }
        }
        let matches: [Resolved]
        if !canonicalTmuxMatches.isEmpty {
            matches = canonicalTmuxMatches
        } else if !legacyBoundMatches.isEmpty {
            matches = legacyBoundMatches
        } else {
            matches = unboundUUIDMatches
        }
        guard matches.count == 1 else {
            logger.info("resolve: exact route produced canonical=\(canonicalTmuxMatches.count, privacy: .public) legacy=\(legacyBoundMatches.count, privacy: .public) unbound=\(unboundUUIDMatches.count, privacy: .public) matches")
            return nil
        }
        return matches[0]
    }

    private static func resolveHerdr(_ route: PushRoute) -> Resolved? {
        var destinations: [Resolved] = []
        var candidates: [PushHerdrRoute.Candidate] = []
        for (windowId, model) in TmuxWindowRegistry.allWindows() {
            for tab in model.tabs {
                for pane in tab.splitTree {
                    guard let view = pane as? Ghostty.TerminalView else { continue }
                    let candidate: PushHerdrRoute.Candidate
                    if let binding = view.herdrPaneBinding,
                       let controller = HerdrController.controller(forGateway: binding.gatewayUUID) {
                        candidate = .init(server: controller.pushRouteServerIdentity,
                            terminal: binding.terminalId, isActive: controller.isActive && !controller.didEnd)
                    } else if view.herdrPaneBinding == nil, view.herdrController?.didEnd != false,
                              view.tmuxPaneBinding == nil, view.tmuxController == nil {
                        candidate = .init(server: nil, terminal: "", isActive: true,
                                          surfaceID: view.uuid, isOrdinary: true)
                    } else { continue }
                    destinations.append(Resolved(windowId: windowId, tabID: tab.id, surfaceID: view.uuid))
                    candidates.append(candidate)
                }
            }
        }
        guard let index = PushHerdrRoute.matchingIndex(route: route, candidates: candidates) else { return nil }
        return destinations[index]
    }

    static func isViewed(_ resolved: Resolved) -> Bool {
        guard let model = TerminalWindowRegistry.tabsModel(for: resolved.windowId),
              let tab = model.tabs.first(where: { $0.id == resolved.tabID }),
              let view = tab.splitTree.first(where: { $0.uuid == resolved.surfaceID }) else { return false }
        return AgentPaneVisibility.isViewed(appBackgrounded: Ghostty.isAppBackgrounded,
                                            selectedTabID: model.selectedTabID,
                                            containingTabID: tab.id,
                                            focusedPaneID: tab.focusedPane?.uuid,
                                            paneID: view.uuid,
                                            isKeyWindow: view.window?.isKeyWindow ?? false)
    }

    // MARK: - Foreground presentation

    static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if isRejected(content.userInfo) {
            logger.info("dropped: revoked sender or stale registration")
            return []
        }
        guard let (header, decryptedLocally) = decryptedHeader(from: content.userInfo) else { return [.banner, .list] }
        // willPresent only runs while the app is foreground, so this is the "device can already alert" case.
        if header.kind == "agent", SettingsStore.shared.value(Settings.Notifications.pushAgentBackgroundOnly) {
            logger.info("suppressed: background-only and app is foreground")
            return []
        }
        if decryptedLocally {
            let eid = PushEnvelope(userInfo: content.userInfo)?.eid ?? UUID().uuidString
            Task { await presentLocally(header, eid: eid, sound: content.sound) }
            return []
        }
        let resolved = resolve(header.route)
        let status = attentionStatus(header.status)

        if let resolved {
            // Explicit `send`/`test` notifications always show; agent events are
            // suppressed only when the pane is on screen or screen detection
            // already fired (or always, with "Only When in Background" on).
            // The Agent Notifications policy governs screen detection, not pushes.
            if header.kind == "agent" {
                if isViewed(resolved) {
                    logger.info("suppressed: pane is being viewed")
                    return []
                }
                if let status, AgentAttentionNotificationRouter.shouldSuppressExternal(pane: resolved.surfaceID, status: status) {
                    logger.info("suppressed: screen detection already notified")
                    return []
                }
            }
            noteDelivered(identifier: notification.request.identifier, pane: resolved.surfaceID, status: status)
        } else {
            deliveryReconciler.trackFresh(identifier: notification.request.identifier,
                                          header: header, receivedAt: notification.date)
            let eid = PushEnvelope(userInfo: content.userInfo)?.eid ?? notification.request.identifier
            deliveryReconciler.ingest([PushEventRecord(eid: eid, receivedAt: notification.date,
                status: header.status, agent: header.agent, thread: header.thread, route: header.route)])
        }
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if content.sound != nil { options.insert(.sound) }
        return options
    }

    private static func noteDelivered(identifier: String, pane: UUID, status: AgentAttentionStatus?) {
        deliveredIdentifiers[pane, default: []].insert(identifier)
        if let status { AgentAttentionNotificationRouter.externalEventDelivered(pane: pane, status: status) }
    }

    /// Called from the attention router's seen pass: looking at the pane
    /// answers its push notifications too.
    static func paneViewed(_ pane: UUID) {
        guard let ids = deliveredIdentifiers.removeValue(forKey: pane), !ids.isEmpty else { return }
        NotificationManager.shared.removeNotifications(identifiers: Array(ids))
    }

    // MARK: - Tap

    static func handleTap(userInfo: [AnyHashable: Any]) {
        guard let header = decryptedHeader(from: userInfo)?.header else {
            logger.error("tap: no decryptable header")
            return
        }
        let r = header.route
        logger.info("tap route pane=\(r?.pane ?? "-", privacy: .public) tmux=\(r?.tmuxPane ?? "-", privacy: .public) server=\(r?.tmuxServer ?? "-", privacy: .public) host=\(r?.host ?? "-", privacy: .public) cwd=\(r?.cwd ?? "-", privacy: .public) resolved=\(String(describing: resolve(r)), privacy: .public)")
        pending = header.route.map {
            PendingRoute(route: $0, expires: Date().addingTimeInterval(60))
        }
        if let resolved = resolve(header.route) {
            pending = nil
            navigate(to: resolved)
        } else {
            // A notification response has already activated the process, but
            // Catalyst can leave every window hidden (or only its visor scene
            // connected). An unresolved route must still visibly open the app.
            #if targetEnvironment(macCatalyst)
            CatalystSceneDelegate.activateMainWindowForExternalEvent()
            #endif
        }
    }

    /// Retried when tabs restore, multiplexer panes project, or a scene activates.
    static func retryPending() {
        guard let p = pending else { return }
        guard p.expires > Date() else { pending = nil; return }
        guard let resolved = resolve(p.route) else { return }
        pending = nil
        navigate(to: resolved)
    }

    /// No disk or Notification Center read on frequent topology callbacks.
    /// Async delivery snapshots reconcile again on completion, so readiness
    /// arriving before or during a snapshot cannot strand its records.
    static func bindingsDidChange() {
        reconcileDeliveries()
        retryPending()
    }

    private static func reconcileDeliveries() {
        var destinations: [UUID: Resolved] = [:]
        let matches = deliveryReconciler.reconcile { route in
            guard let resolved = resolve(route) else { return nil }
            destinations[resolved.surfaceID] = resolved
            return resolved.surfaceID
        }
        for (record, pane) in matches.events {
            if let status = attentionStatus(record.status) {
                AgentAttentionNotificationRouter.externalEventDelivered(pane: pane, status: status, at: record.receivedAt)
            }
        }
        var withdrawals: [String] = []
        for (identifier, pane, allowsCatchUpWithdrawal) in matches.deliveries {
            if allowsCatchUpWithdrawal, let resolved = destinations[pane], isViewed(resolved) {
                // Withdraw only this catch-up delivery. paneViewed() would
                // also remove fresh send/test alerts associated with the pane.
                withdrawals.append(identifier)
                deliveredIdentifiers[pane]?.remove(identifier)
                if deliveredIdentifiers[pane]?.isEmpty == true {
                    deliveredIdentifiers.removeValue(forKey: pane)
                }
            } else {
                deliveredIdentifiers[pane, default: []].insert(identifier)
            }
        }
        if !withdrawals.isEmpty {
            NotificationManager.shared.removeNotifications(identifiers: withdrawals)
        }
    }

    static func navigate(to resolved: Resolved) {
        Task { @MainActor in
            // A tap from a hidden/background app: wait for the system to finish
            // activating before touching focus, or the responder chain detaches.
            if UIApplication.shared.applicationState != .active {
                await Self.waitForApplicationActivation()
            }
            // Only bring a different window forward; re-activating the key window
            // resets first responder under the terminal's feet.
            let targetScene = windowScene(forWindowId: resolved.windowId)
            var requestedUIKitActivation = false
            if let targetScene,
               targetScene.activationState != .foregroundActive {
                requestedUIKitActivation = true
                await Self.requestSceneActivationAndWait(targetScene)
            }
            #if targetEnvironment(macCatalyst)
            CatalystSceneDelegate.activateMainWindowForExternalEvent(
                scene: targetScene,
                uiKitActivationAlreadyRequested: requestedUIKitActivation
            )
            #endif
            NotificationCenter.default.post(name: .navigateToTerminal, object: nil,
                                            userInfo: ["tabID": resolved.tabID, "surfaceID": resolved.surfaceID])
        }
    }

    /// MainView's Catalyst-only helper, without the platform guard.
    private static func windowScene(forWindowId windowId: String) -> UIWindowScene? {
        guard let sessionId = TerminalWindowRegistry.sceneSessionId(for: windowId) else { return nil }
        return UIApplication.shared.connectedScenes.first {
            ($0 as? UIWindowScene)?.session.persistentIdentifier == sessionId
        } as? UIWindowScene
    }

    /// Installs the activation observer before making the request, then bounds
    /// the wait so a failed or notification-less Catalyst transition cannot
    /// strand notification navigation forever.
    private static func requestSceneActivationAndWait(_ scene: UIWindowScene) async {
        let waiter = NotificationWaiter()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            waiter.observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: scene,
                queue: .main
            ) { _ in
                Task { @MainActor in waiter.finish() }
            }
            waiter.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                waiter.finish()
            }
            UIApplication.shared.requestSceneSessionActivation(
                scene.session,
                userActivity: nil,
                options: nil
            ) { error in
                Self.logger.error("scene activation failed: \(error.localizedDescription)")
                Task { @MainActor in waiter.finish() }
            }
        }
    }

    /// Covers the same notification-before-observer race for process-level
    /// activation and bounds the wait if Catalyst never posts didBecomeActive.
    private static func waitForApplicationActivation() async {
        guard UIApplication.shared.applicationState != .active else { return }
        let waiter = NotificationWaiter()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            waiter.observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in waiter.finish() }
            }
            waiter.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                waiter.finish()
            }
            // Activation may have completed between the initial guard and
            // observer installation. Recheck only after the observer exists.
            if UIApplication.shared.applicationState == .active {
                waiter.finish()
            }
        }
    }

    /// Fallback for a raw push delivered to the app process: replaces the raw
    /// alert with the decrypted one. No-ops once the extension has decorated it.
    static func handleRemote(userInfo: [AnyHashable: Any]) async {
        guard let env = PushEnvelope(userInfo: userInfo) else { return }
        logger.info("remote delivery eid=\(env.eid, privacy: .public) state=\(UIApplication.shared.applicationState.rawValue)")
        guard isAccepted(env) else {
            await removeRawDelivered(eid: env.eid)
            return
        }
        guard header(from: userInfo) == nil,
              let key = try? PushConfiguration.keychain.loadPrivateKey(),
              let header = try? env.open(with: key) else { return }
        await presentLocally(header, eid: env.eid, sound: .default)
    }

    private static func rawDeliveredIdentifier(eid: String) async -> String? {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.first {
            PushEnvelope(userInfo: $0.request.content.userInfo)?.eid == eid
                && $0.request.content.userInfo[PushConfiguration.headerUserInfoKey] == nil
        }?.request.identifier
    }

    private static func removeRawDelivered(eid: String) async {
        if let id = await rawDeliveredIdentifier(eid: eid) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // MARK: - Background deliveries

    /// Feeds pushes decrypted while the app was not running into the
    /// arbitration ledger, and tracks their identifiers for withdrawal.
    static func syncDelivered() {
        deliveryReconciler.ingest(PushSharedState().load())
        bindingsDidChange()
        deliverySyncRequested = true
        guard deliverySyncTask == nil else { return }
        deliverySyncTask = Task {
            defer { deliverySyncTask = nil }
            while deliverySyncRequested {
                deliverySyncRequested = false
                await syncDeliveredSnapshot()
            }
        }
    }

    private static func syncDeliveredSnapshot() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let fallbacks = delivered.filter { $0.request.content.userInfo[PushConfiguration.fallbackUserInfoKey] != nil }.count
        if fallbacks > 0 { logger.warning("extension fallbacks awaiting re-post: \(fallbacks, privacy: .public)") }
        for n in delivered where n.request.content.categoryIdentifier == PushConfiguration.categoryIdentifier {
            if isRejected(n.request.content.userInfo) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [n.request.identifier])
                continue
            }
            guard let (header, decryptedLocally) = decryptedHeader(from: n.request.content.userInfo) else { continue }
            if decryptedLocally {
                // Delivered raw while the app was not running: replace it with the decrypted version.
                let eid = PushEnvelope(userInfo: n.request.content.userInfo)?.eid ?? n.request.identifier
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [n.request.identifier])
                await presentLocally(header, eid: eid, sound: n.request.content.sound)
                continue
            }
            deliveryReconciler.track(identifier: n.request.identifier,
                                     route: header.route, receivedAt: n.date)
        }
        deliveryReconciler.ingest(PushSharedState().load())
        bindingsDidChange()
    }
}
