//
//  AgentInboxStore.swift
//  rootshell
//
//  The in-app inbox: history, sections and read state for agent hook
//  messages. Records on every platform, whatever the Live Activity settings;
//  the island only mirrors the unread part of it.
//
//  Rows wrap the wire type rather than extending it: `AgentInboxItem` is the
//  Live Activity payload and must stay free of message text. The summary lives
//  here, in the app process only.
//

import Foundation
import Observation
import RootshellPushKit
import os

// MARK: - Section

nonisolated enum AgentInboxSection: String, Codable, Sendable, CaseIterable, Hashable {
    case needsYou
    case failed
    case working
    case done
    case archived

    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs You", comment: "Inbox section")
        case .failed: String(localized: "Failed Runs", comment: "Inbox section")
        case .working: String(localized: "In Progress", comment: "Inbox section")
        case .done: String(localized: "Finished", comment: "Inbox section")
        case .archived: String(localized: "Archived", comment: "Inbox section")
        }
    }
}

// MARK: - Row

nonisolated struct AgentInboxRow: Codable, Equatable, Sendable, Identifiable {
    var event: AgentInboxItem
    /// In-app only. Never makes it into the Live Activity payload.
    var summary: String?
    var host: String?
    var tab: String?
    /// Exact tab the event came from, recorded at delivery time. Titles drift
    /// (cwd, agent status) and panes disappear; the tab id does not.
    var windowId: String?
    var tabID: UUID?
    /// The push's own route: the exact pane, re-resolved at tap time so a
    /// tmux/herdr pane projected after delivery still opens.
    var route: PushRoute?
    var isRead: Bool
    var isArchived: Bool
    /// When the row entered the archive. Retention runs from this moment, not
    /// from when the event arrived.
    var archivedAt: Date?

    var id: String { event.id }
    var agent: String { event.agent }
    var receivedAt: Date { event.at }
    var deepLink: URL { event.deepLink }
    var status: AgentInboxStatus { AgentInboxStatus(raw: event.status) }

    var section: AgentInboxSection {
        if isArchived { return .archived }
        switch status {
        case .blocked: return .needsYou
        case .failed: return .failed
        // Statuses a newer relay may send count as work in progress.
        case .other: return .working
        case .done: return .done
        }
    }

    /// Whether the row counts toward the island and the sidebar badge.
    var isUnreadAction: Bool {
        !isRead && !isArchived && status != .other
    }

    init(event: AgentInboxItem, summary: String? = nil, host: String? = nil, tab: String? = nil,
         windowId: String? = nil, tabID: UUID? = nil, route: PushRoute? = nil,
         isRead: Bool = false, isArchived: Bool = false, archivedAt: Date? = nil) {
        self.event = event
        self.summary = summary
        self.host = host
        self.tab = tab
        self.windowId = windowId
        self.tabID = tabID
        self.route = route
        self.isRead = isRead
        self.isArchived = isArchived
        self.archivedAt = archivedAt
    }
}

// MARK: - Feed

/// Pure value logic: insertion, dedupe, ordering, read state, retention.
nonisolated struct AgentInboxFeed: Codable, Equatable, Sendable {
    private(set) var rows: [AgentInboxRow]

    init(rows: [AgentInboxRow] = []) {
        self.rows = rows
    }

    var isEmpty: Bool { rows.isEmpty }

    func rows(in section: AgentInboxSection) -> [AgentInboxRow] {
        rows.filter { $0.section == section }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Unread rows the island can act on, newest first. Rows past the active
    /// lifetime count as archived even before a sweep has run.
    func unreadActions(now: Date = Date()) -> [AgentInboxRow] {
        rows.filter { $0.isUnreadAction && now.timeIntervalSince($0.receivedAt) < Self.activeLifetime }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    mutating func insert(_ row: AgentInboxRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            // A redelivered event fills in what it now knows but must not
            // resurrect a row the person already read or archived.
            var merged = row
            // The first delivery's time is the event's time; a later copy must
            // not move it past a "mark all read" watermark.
            merged.event.at = rows[index].event.at
            merged.isRead = rows[index].isRead || row.isRead
            merged.isArchived = rows[index].isArchived
            merged.archivedAt = rows[index].archivedAt
            merged.summary = row.summary ?? rows[index].summary
            merged.host = row.host ?? rows[index].host
            merged.tab = row.tab ?? rows[index].tab
            merged.windowId = row.windowId ?? rows[index].windowId
            merged.tabID = row.tabID ?? rows[index].tabID
            merged.route = row.route ?? rows[index].route
            // An unresolved delivery carries the inbox link; keep a real pane link.
            if row.deepLink == AgentInboxLinks.inbox { merged.event.deepLink = rows[index].deepLink }
            rows[index] = merged
        } else {
            rows.append(row)
        }
        rows.sort { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    mutating func markRead(where predicate: (AgentInboxRow) -> Bool) -> Bool {
        var changed = false
        for index in rows.indices where !rows[index].isRead && predicate(rows[index]) {
            rows[index].isRead = true
            changed = true
        }
        return changed
    }

    /// Active rows move to the archive after an hour without an action.
    static let activeLifetime: TimeInterval = 60 * 60
    /// Archived rows are dropped two hours after they entered the archive.
    static let archivedLifetime: TimeInterval = 2 * 60 * 60

    @discardableResult
    mutating func archive(_ id: String, now: Date = Date()) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        // A running task is presence, not a finished message.
        guard rows[index].status != .other, !rows[index].isArchived else { return false }
        rows[index].isArchived = true
        rows[index].isRead = true
        rows[index].archivedAt = now
        return true
    }

    /// Moves stale active rows into the archive and starts their retention.
    @discardableResult
    mutating func autoArchive(now: Date = Date()) -> Bool {
        var changed = false
        for index in rows.indices {
            if rows[index].isArchived {
                if rows[index].archivedAt == nil {
                    rows[index].archivedAt = now
                    changed = true
                }
                continue
            }
            guard rows[index].status != .other,
                  now.timeIntervalSince(rows[index].receivedAt) >= Self.activeLifetime else { continue }
            rows[index].isArchived = true
            rows[index].isRead = true
            rows[index].archivedAt = now
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func removeExpiredArchived(now: Date = Date()) -> Bool {
        let before = rows.count
        rows.removeAll { row in
            guard let archivedAt = row.archivedAt else { return false }
            return now.timeIntervalSince(archivedAt) >= Self.archivedLifetime
        }
        return rows.count != before
    }

    /// Drops rows older than `age`, whatever their state.
    @discardableResult
    mutating func prune(olderThan age: TimeInterval, now: Date = Date()) -> Bool {
        let before = rows.count
        rows.removeAll { now.timeIntervalSince($0.receivedAt) >= age }
        return rows.count != before
    }

    @discardableResult
    mutating func sweepRetention(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        let archived = autoArchive(now: now)
        let removed = removeExpiredArchived(now: now)
        let pruned = prune(olderThan: maxAge, now: now)
        return archived || removed || pruned
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentInboxStore {
    static let shared = AgentInboxStore()

    private static let storageKey = "agentInboxFeed.v1"
    private static let maxAge: TimeInterval = 12 * 60 * 60
    private static let log = Logger(subsystem: "com.rootshell", category: "AgentInbox")

    private(set) var feed = AgentInboxFeed()
    @ObservationIgnored private let defaults: UserDefaults
    /// The app-group defaults are unreadable before first unlock; writing an
    /// empty feed then would erase the history.
    @ObservationIgnored private var isLoaded = false

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppIdentifiers.defaultAppGroupID) ?? .standard
        ProtectedDataGuard.whenAvailable { [weak self] in self?.loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !isLoaded, ProtectedDataGuard.isAvailable else { return }
        isLoaded = true
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AgentInboxFeed.self, from: data) {
            feed = decoded
        }
        if feed.sweepRetention(maxAge: Self.maxAge) { persist() }
    }

    var isEmpty: Bool { feed.isEmpty }

    /// Unread blocked/failed/done rows: the island and the sidebar badge.
    /// The island's "mark all read" intent can only leave a watermark behind.
    var unreadActions: [AgentInboxRow] {
        loadIfNeeded()
        let readAt = AgentInboxReadMarker.lastReadAt()
        return feed.unreadActions().filter { row in readAt.map { row.receivedAt > $0 } ?? true }
    }

    func rows(in section: AgentInboxSection) -> [AgentInboxRow] { feed.rows(in: section) }

    func row(id: String) -> AgentInboxRow? {
        loadIfNeeded()
        return feed.rows.first { $0.id == id }
    }

    /// Records one delivered hook message. Returns false when nothing changed
    /// (locked device, or a redelivery of a row already read).
    @discardableResult
    func record(_ row: AgentInboxRow, isNew: Bool) -> Bool {
        loadIfNeeded()
        guard isLoaded else { return false }
        let before = feed
        feed.insert(row)
        // Materialize the island's "mark all read" watermark into the stored row.
        if let readAt = AgentInboxReadMarker.lastReadAt() {
            feed.markRead { $0.id == row.id && $0.receivedAt <= readAt }
        }
        // A late delivery can already be past the active lifetime.
        feed.sweepRetention(maxAge: Self.maxAge)
        guard feed != before else { return false }
        persist()
        islandNeedsUpdate(newEvent: isNew && row.isUnreadAction)
        return true
    }

    func sweepExpired(now: Date = Date()) {
        loadIfNeeded()
        guard isLoaded, feed.sweepRetention(maxAge: Self.maxAge, now: now) else { return }
        persist()
        islandNeedsUpdate()
    }

    /// Marks unread rows matching `predicate` read; it only sees unread rows.
    func markRead(where predicate: (AgentInboxRow) -> Bool) {
        mutate { $0.markRead(where: predicate) }
    }

    func markRead(id: String) {
        mutate { $0.markRead { $0.id == id } }
    }

    func markAllRead() {
        mutate { $0.markRead { _ in true } }
    }

    func archive(_ id: String) {
        mutate { $0.archive(id) }
    }

    private func mutate(_ change: (inout AgentInboxFeed) -> Bool) {
        loadIfNeeded()
        guard isLoaded, change(&feed) else { return }
        persist()
        islandNeedsUpdate()
    }

    private func islandNeedsUpdate(newEvent: Bool = false) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivityManager.shared.agentInboxDidChange(newEvent: newEvent)
        #endif
    }

    #if DEBUG
    /// Design-review seed: launch with `-AgentInboxDemoSeed`. Debug builds only.
    func seedDemoIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-AgentInboxDemoSeed") else { return }
        loadIfNeeded()
        // Demo rows carry the language they were seeded in.
        if arguments.contains("-AgentInboxDemoReset") { feed = AgentInboxFeed() }
        let now = Date()
        let seeds: [(String, String, String, String, String, TimeInterval)] = [
            ("demo-1", "claude-code", "blocked", "mac-mini-m4", "web-app", 120),
            ("demo-2", "codex", "blocked", "imac-zt", "api", 300),
            ("demo-3", "oh-my-pi", "running", "mac-mini-m4", "app-ios", 360),
            ("demo-4", "deepseek-harness", "done", "oma.zt", "web-app", 1080),
            ("demo-5", "hermes", "failed", "imac-zt", "site", 3000),
            ("demo-6", "claude-code", "done", "mac-mini-m4", "docs", 5400),
        ]
        let summaries: [String] = [
            String(localized: "Demo: Bash wants to run `wrangler deploy --env prod`", comment: "Demo seed text"),
            String(localized: "Demo: keep Clerk sessions, self-host Auth.js", comment: "Demo seed text"),
            String(localized: "Demo: editing src/session/store.ts · 58%", comment: "Demo seed text"),
            String(localized: "Demo: retry button after the 10s timeout, 14 tests pass", comment: "Demo seed text"),
            String(localized: "Demo: dependency install failed, lockfile conflict", comment: "Demo seed text"),
            String(localized: "Demo: docs build finished, artifacts uploaded", comment: "Demo seed text"),
        ]
        for (index, seed) in seeds.enumerated() {
            let event = AgentInboxItem(
                id: seed.0,
                agent: AgentInboxAgentID.manifestID(for: seed.1),
                status: seed.2,
                at: now.addingTimeInterval(-seed.5),
                deepLink: URL(string: "rootshell://pane/\(String(format: "%08d", index + 1))-0000-4000-8000-000000000000")!
            )
            record(AgentInboxRow(event: event, summary: summaries[index], host: seed.3, tab: seed.4), isNew: true)
        }
    }
    #endif

    private func persist() {
        guard isLoaded else { return }
        do {
            defaults.set(try JSONEncoder().encode(feed), forKey: Self.storageKey)
        } catch {
            Self.log.error("inbox persist failed: \(String(describing: error), privacy: .public)")
        }
    }
}
