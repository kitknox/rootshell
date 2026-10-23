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

        // A backgrounded app gets no `willPresent` for this; the foreground
        // path records it again under the same id, which merges.
        recordInboxEvent(id: eid, header: header, at: record.receivedAt, isNew: true)
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

        for (windowId, tab, view) in TmuxWindowRegistry.terminalPanes() {
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
                      view.herdrPaneBinding == nil,
                      !view.isLiveMultiplexerGateway,
                      view.uuid == paneUUID {
                // Ordinary (non-control-mode) tmux sets TMUX_PANE but
                // remains a regular terminal view. Its UUID is still
                // an exact identity, not a heuristic fallback. Never
                // select a control-mode gateway while its canonical
                // server query or projected panes are still pending.
                unboundUUIDMatches.append(resolved)
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
        for (windowId, tab, view) in TmuxWindowRegistry.terminalPanes() {
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
        guard let index = PushHerdrRoute.matchingIndex(route: route, candidates: candidates) else { return nil }
        return destinations[index]
    }

    /// A pane by its own TerminalView UUID, as AppleScript's `list pane ids`
    /// reports it. Projected panes match; a live gateway never does.
    static func resolve(surfaceID: UUID) -> Resolved? {
        guard let match = TmuxWindowRegistry.terminalPanes().first(where: { $0.view.uuid == surfaceID }),
              !match.view.isLiveMultiplexerGateway else { return nil }
        return Resolved(windowId: match.windowId, tabID: match.tab.id, surfaceID: surfaceID)
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
        recordInboxEvent(id: inboxEventID(for: notification.request), header: header, at: notification.date, isNew: true)
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
        // Looking at the pane answers its inbox rows too, whether or not there
        // is still a notification to withdraw.
        markInboxRowsRead(surfaceID: pane)
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
            if header.kind == "agent" { markInboxRowsRead(surfaceID: resolved.surfaceID) }
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

    // MARK: - Agent inbox

    /// `rootshell://pane/<uuid>` opens one pane, `rootshell://inbox` the inbox.
    static func handleLiveActivityURL(_ url: URL) -> Bool {
        guard url.scheme == "rootshell" else { return false }
        switch url.host {
        case "pane":
            guard let raw = url.pathComponents.dropFirst().first,
                  let surfaceID = UUID(uuidString: raw) else { return false }
            openInboxPane(surfaceID: surfaceID)
            return true
        case "inbox":
            let eventID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "event" }?.value
            guard let eventID, let row = AgentInboxStore.shared.row(id: eventID) else {
                AgentInboxRouter.shared.requestOpen(highlighting: eventID)
                return true
            }
            Task { @MainActor in
                if let resolved = await resolveInboxRowWhenReady(row) {
                    AgentInboxStore.shared.markRead(id: eventID)
                    navigate(to: resolved)
                } else {
                    AgentInboxRouter.shared.requestOpen(highlighting: eventID)
                }
            }
            return true
        default:
            return false
        }
    }

    /// Inbox id for a delivery. The decrypted local re-post carries no
    /// envelope and is named `push-<eid>`; both copies must be one row.
    static func inboxEventID(for request: UNNotificationRequest) -> String {
        if let eid = PushEnvelope(userInfo: request.content.userInfo)?.eid { return eid }
        let id = request.identifier
        return id.hasPrefix("push-") ? String(id.dropFirst(5)) : id
    }

    /// Records an agent hook message. A route that does not resolve yet (tmux
    /// or herdr still projecting) records without its tab and is retried from
    /// `bindingsDidChange`. A pane already on screen needs no inbox row.
    private static func recordInboxEvent(id: String, header: PushHeader, at date: Date, isNew: Bool) {
        guard header.kind == "agent" else { return }
        let resolved = resolve(header.route)
        if let resolved, isViewed(resolved) {
            pendingInboxEvents[id] = nil
            return
        }
        let meta = resolved.map(inboxMetadata(for:))
        let event = AgentInboxItem(
            id: id,
            agent: AgentInboxAgentID.manifestID(for: header.agent ?? ""),
            status: header.status ?? "",
            at: date,
            deepLink: resolved.map { paneDeepLink(surfaceID: $0.surfaceID) } ?? AgentInboxLinks.inbox
        )
        let row = AgentInboxRow(
            event: event,
            summary: header.body.flatMap { $0.isEmpty ? nil : $0 } ?? header.title,
            host: header.route?.host ?? meta?.host,
            tab: meta?.title,
            windowId: resolved?.windowId,
            tabID: resolved?.tabID,
            route: header.route
        )
        AgentInboxStore.shared.record(row, isNew: isNew)
        if resolved == nil, header.route != nil {
            pendingInboxEvents[id] = PendingInboxEvent(header: header, date: date,
                                                       expires: Date().addingTimeInterval(10 * 60))
        } else {
            pendingInboxEvents[id] = nil
        }
    }

    private struct PendingInboxEvent {
        let header: PushHeader
        let date: Date
        let expires: Date
    }

    private static var pendingInboxEvents: [String: PendingInboxEvent] = [:]

    private static func retryPendingInboxEvents() {
        guard !pendingInboxEvents.isEmpty else { return }
        let now = Date()
        for (id, event) in pendingInboxEvents {
            guard event.expires > now else {
                pendingInboxEvents[id] = nil
                continue
            }
            guard let resolved = resolve(event.header.route) else { continue }
            if isViewed(resolved) {
                pendingInboxEvents[id] = nil
                AgentInboxStore.shared.markRead(id: id)
            } else {
                recordInboxEvent(id: id, header: event.header, at: event.date, isNew: false)
            }
        }
    }

    /// The pane an inbox row points at: its push route (regular, tmux and
    /// herdr control-mode panes alike, as a notification tap resolves it),
    /// else the pane it resolved to at delivery. With `allowsTabFallback`, the
    /// tab that pane was in. Never a guess by host or title.
    static func resolveInboxRow(_ row: AgentInboxRow, allowsTabFallback: Bool = true) -> Resolved? {
        if let resolved = resolve(row.route) {
            return resolved
        }
        if let surfaceID = paneSurfaceID(row.deepLink), let resolved = resolve(surfaceID: surfaceID) {
            return resolved
        }
        if let route = row.route, let resolved = resolveWhileIdentityPending(route) {
            return resolved
        }
        guard allowsTabFallback else { return nil }
        return resolvedTab(windowId: row.windowId, tabID: row.tabID)
    }

    /// A tap can land while a control-mode client is still re-learning its
    /// server identity after a reconnect, which a notification tap rides out
    /// with its pending retry. Waits up to two seconds for the exact route.
    static func resolveInboxRowWhenReady(_ row: AgentInboxRow) async -> Resolved? {
        for attempt in 0..<8 {
            if let resolved = resolveInboxRow(row, allowsTabFallback: false) { return resolved }
            if attempt == 0 { refreshControlModeIdentities() }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return resolveInboxRow(row)
    }

    private static func refreshControlModeIdentities() {
        for (_, _, view) in TmuxWindowRegistry.terminalPanes() {
            if let binding = view.herdrPaneBinding,
               let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
               controller.pushRouteServerIdentity == nil {
                controller.refreshPushRouteIdentity()
            }
            if let binding = view.tmuxPaneBinding,
               let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
               controller.pushRouteServerIdentity == nil {
                controller.refreshPushRouteServerIdentity()
            }
        }
    }

    /// The control-mode pane with the route's tmux pane or herdr terminal id,
    /// accepted only while its client's server identity is still unknown and
    /// only when exactly one pane qualifies. A known, different identity is a
    /// different server and never matches.
    private static func resolveWhileIdentityPending(_ route: PushRoute) -> Resolved? {
        let herdrTerminal = route.herdrTerminal.flatMap { $0.isEmpty ? nil : $0 }
        let tmuxPaneId = route.tmuxPane.flatMap { $0.hasPrefix("%") ? Int($0.dropFirst()) : nil }
        guard herdrTerminal != nil || tmuxPaneId != nil else { return nil }
        var matches: [Resolved] = []
        for (windowId, tab, view) in TmuxWindowRegistry.terminalPanes() {
            if let herdrTerminal, let binding = view.herdrPaneBinding, binding.terminalId == herdrTerminal,
               let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
               controller.isActive, !controller.didEnd, controller.pushRouteServerIdentity == nil {
                matches.append(Resolved(windowId: windowId, tabID: tab.id, surfaceID: view.uuid))
            } else if herdrTerminal == nil, let tmuxPaneId, let binding = view.tmuxPaneBinding,
                      binding.paneId == tmuxPaneId,
                      let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                      controller.pushRouteServerIdentity == nil {
                matches.append(Resolved(windowId: windowId, tabID: tab.id, surfaceID: view.uuid))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Marks the rows of a pane read, by the pane link recorded at delivery or
    /// by re-resolving the route (a re-projected pane has a new surface id).
    private static func markInboxRowsRead(surfaceID: UUID) {
        let link = paneDeepLink(surfaceID: surfaceID)
        AgentInboxStore.shared.markRead { row in
            row.deepLink == link || (row.route != nil && resolve(row.route)?.surfaceID == surfaceID)
        }
    }

    private static func paneSurfaceID(_ link: URL) -> UUID? {
        guard link.scheme == "rootshell", link.host == "pane",
              let raw = link.pathComponents.dropFirst().first else { return nil }
        return UUID(uuidString: raw)
    }

    private static func resolvedTab(windowId: String?, tabID: UUID?) -> Resolved? {
        guard let windowId, let tabID,
              let model = TerminalWindowRegistry.tabsModel(for: windowId),
              let tab = model.tabs.first(where: { $0.id == tabID }),
              let surfaceID = tab.focusedPane?.uuid ?? tab.splitTree.first?.uuid else { return nil }
        return Resolved(windowId: windowId, tabID: tabID, surfaceID: surfaceID)
    }

    /// Host and title of the tab a resolved pane belongs to.
    private static func inboxMetadata(for resolved: Resolved) -> (host: String?, title: String?) {
        guard let model = TerminalWindowRegistry.tabsModel(for: resolved.windowId),
              let tab = model.tabs.first(where: { $0.id == resolved.tabID }) else {
            return (nil, nil)
        }
        return (model.groupHostLabel(for: tab), tab.title)
    }

    /// `rootshell://pane/<surface-uuid>`: the tap target of one island row.
    static func paneDeepLink(surfaceID: UUID) -> URL {
        URL(string: "rootshell://pane/\(surfaceID.uuidString)")!
    }

    private static func openInboxPane(surfaceID: UUID) {
        if let resolved = resolve(surfaceID: surfaceID) {
            pendingInboxPane = nil
            markInboxRowsRead(surfaceID: surfaceID)
            navigate(to: resolved)
        } else {
            // The pane may still be projecting or its window restoring.
            pendingInboxPane = InboxPaneRetry(surfaceID: surfaceID, expires: Date().addingTimeInterval(60))
        }
    }

    private struct InboxPaneRetry {
        let surfaceID: UUID
        let expires: Date
    }

    private static var pendingInboxPane: InboxPaneRetry?

    private static func retryPendingInboxPane() {
        guard let p = pendingInboxPane else { return }
        guard p.expires > Date() else { pendingInboxPane = nil; return }
        guard let resolved = resolve(surfaceID: p.surfaceID) else { return }
        pendingInboxPane = nil
        markInboxRowsRead(surfaceID: p.surfaceID)
        navigate(to: resolved)
    }

    /// Retried when tabs restore, multiplexer panes project, or a scene activates.
    static func retryPending() {
        retryPendingInboxPane()
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
        retryPendingInboxEvents()
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
            #if STANDALONE && targetEnvironment(macCatalyst)
            // The visor is a non-activating panel; surfacing a regular window
            // would leave the target hidden.
            if resolved.windowId == "visor" {
                VisorController.shared.show()
                NotificationCenter.default.post(name: .navigateToTerminal, object: nil,
                                                userInfo: ["tabID": resolved.tabID, "surfaceID": resolved.surfaceID])
                return
            }
            #endif
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
            if n.date > Date().addingTimeInterval(-12 * 60 * 60) {
                recordInboxEvent(id: inboxEventID(for: n.request), header: header, at: n.date, isNew: false)
            }
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
