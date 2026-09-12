//
//  AgentActivityLedger.swift
//  RootshellPushKit
//
//  App-group snapshot of the coding agents shown on the session Live
//  Activity. The app writes it on the background edge, when on-device
//  detection stops; the notification service extension applies agent hook
//  pushes (rootshell-notify: blocked / done / failed) to it and republishes
//  the Live Activity counts; the app deletes it on the next foreground
//  reconcile, when live detection takes over again.
//

import Foundation

/// One detected coding agent and the push-route keys that identify its pane.
/// The keys mirror the three tiers of `PushNotificationRouter.resolve` so the
/// extension can match a `PushRoute` without the live tab registry.
public struct AgentActivityLedgerEntry: Codable, Sendable, Equatable {
    public enum Bucket: String, Codable, Sendable {
        case working
        case attention
        case idle
    }

    /// The pane's own `TerminalView.uuid`. Identity only, never matched.
    public var paneID: String
    public var bucket: Bucket
    /// `PushRoute.pane` for an ordinary terminal (its own UUID). Nil for a
    /// tmux control-mode pane, whose route carries the gateway instead.
    public var routePane: String?
    /// tmux control-mode pane: the gateway terminal's UUID, which a
    /// pre-canonical rootshell-notify puts in `PushRoute.pane`.
    public var gatewayPane: String?
    /// tmux control-mode pane: the canonical server identity, matched against
    /// `PushRoute.tmuxServer`. Nil while the controller has not resolved it.
    public var tmuxServer: String?
    /// tmux control-mode pane: the server-global numeric pane id (`%12` -> 12).
    public var tmuxPaneID: Int?

    public init(paneID: String, bucket: Bucket, routePane: String? = nil, gatewayPane: String? = nil,
                tmuxServer: String? = nil, tmuxPaneID: Int? = nil) {
        self.paneID = paneID
        self.bucket = bucket
        self.routePane = routePane
        self.gatewayPane = gatewayPane
        self.tmuxServer = tmuxServer
        self.tmuxPaneID = tmuxPaneID
    }
}

public struct AgentActivityLedger: Codable, Sendable, Equatable {
    /// `Activity.id` of the Live Activity the snapshot was taken for. The
    /// extension updates that activity only; a snapshot left behind by an
    /// activity that has since ended or been replaced matches nothing.
    public var activityID: String
    /// When the app wrote the snapshot (its background edge).
    public var writtenAt: Date
    /// Last time the extension applied a push to it; nil until the first one.
    public var pushUpdatedAt: Date?
    public var entries: [AgentActivityLedgerEntry]

    public init(activityID: String, writtenAt: Date = Date(), pushUpdatedAt: Date? = nil,
                entries: [AgentActivityLedgerEntry]) {
        self.activityID = activityID
        self.writtenAt = writtenAt
        self.pushUpdatedAt = pushUpdatedAt
        self.entries = entries
    }

    public var workingCount: Int { entries.filter { $0.bucket == .working }.count }
    public var attentionCount: Int { entries.filter { $0.bucket == .attention }.count }
    public var idleCount: Int { entries.filter { $0.bucket == .idle }.count }

    /// Hook statuses that move an agent into the attention bucket. The hooks
    /// never report a return to work, so nothing here can move an agent out.
    public static func bucket(forPushStatus status: String?) -> AgentActivityLedgerEntry.Bucket? {
        switch status {
        case "blocked", "done", "failed": return .attention
        default: return nil
        }
    }

    /// Index of the single entry a route identifies, following the same tiers
    /// as the app's resolver: canonical tmux server + pane id first, then the
    /// legacy gateway UUID + pane id, then the plain pane UUID. Ambiguity and
    /// no match both return nil; a wrong pane is worse than a stale count.
    public func matchIndex(for route: PushRoute?) -> Int? {
        guard let route else { return nil }
        let tmuxPaneID = route.tmuxPane.flatMap { $0.hasPrefix("%") ? Int($0.dropFirst()) : nil }

        // UUID strings: the hook forwards whatever the app exported, the app
        // parses them case-insensitively, so compare the same way here.
        func sameUUID(_ a: String?, _ b: String) -> Bool {
            guard let a else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }

        var canonical: [Int] = []
        var legacy: [Int] = []
        var plain: [Int] = []
        for (index, entry) in entries.enumerated() {
            if let tmuxPaneID, let server = route.tmuxServer,
               entry.tmuxPaneID == tmuxPaneID, entry.tmuxServer == server {
                canonical.append(index)
            } else if route.tmuxServer == nil, let tmuxPaneID, let pane = route.pane,
                      entry.tmuxPaneID == tmuxPaneID, sameUUID(entry.gatewayPane, pane) {
                legacy.append(index)
            } else if let pane = route.pane, entry.tmuxPaneID == nil, sameUUID(entry.routePane, pane) {
                plain.append(index)
            }
        }
        let matches = !canonical.isEmpty ? canonical : (!legacy.isEmpty ? legacy : plain)
        return matches.count == 1 ? matches[0] : nil
    }

    /// Applies one hook push. Returns true when a count changed; a repeat of
    /// an already-applied push returns false and leaves `pushUpdatedAt` alone.
    @discardableResult
    public mutating func apply(status: String?, route: PushRoute?, at date: Date = Date()) -> Bool {
        guard let bucket = Self.bucket(forPushStatus: status),
              let index = matchIndex(for: route) else { return false }
        guard entries[index].bucket != bucket else { return false }
        entries[index].bucket = bucket
        pushUpdatedAt = date
        return true
    }
}

/// App-group file behind `AgentActivityLedger`. Same discipline as
/// `PushSharedState`: atomic writes, failures swallowed, no
/// `NSFileCoordinator` (it can block the extension while the app is
/// suspended). Read-modify-write goes through a short `flock` on a sidecar so
/// two extension instances, or the app and the extension, cannot drop each
/// other's transition; a holder that never releases only costs the waiter a
/// quarter second, after which it proceeds unlocked (last writer wins).
public struct AgentActivityLedgerStore: Sendable {
    /// A snapshot older than this is ignored: the app that wrote it is gone
    /// and so, normally, is its Live Activity.
    public static let maxAge: TimeInterval = 24 * 3600

    let fileURL: URL?
    let lockURL: URL?

    public init(appGroup: String = PushConfiguration.appGroup) {
        self.init(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))
    }

    public init(container: URL?) {
        fileURL = container?.appendingPathComponent("live-activity-agents.json")
        lockURL = container?.appendingPathComponent("live-activity-agents.lock")
    }

    public func load(now: Date = Date()) -> AgentActivityLedger? {
        withLock { loadUnlocked(now: now) }
    }

    public func save(_ ledger: AgentActivityLedger) {
        withLock { write(ledger) }
    }

    public func clear() {
        withLock {
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Atomic read-modify-write. `transform` returns whether it changed the
    /// ledger; the file is rewritten only then. Returns the ledger as it
    /// stands after the call, or nil when there is no usable snapshot.
    public func modify(now: Date = Date(), _ transform: (inout AgentActivityLedger) -> Bool) -> AgentActivityLedger? {
        withLock {
            guard var ledger = loadUnlocked(now: now) else { return nil }
            if transform(&ledger) { write(ledger) }
            return ledger
        }
    }

    private func loadUnlocked(now: Date) -> AgentActivityLedger? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let ledger = try? JSONDecoder().decode(AgentActivityLedger.self, from: data) else { return nil }
        guard now.timeIntervalSince(ledger.writtenAt) < Self.maxAge else { return nil }
        return ledger
    }

    private func write(_ ledger: AgentActivityLedger) {
        guard let fileURL, let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        guard let lockURL else { return body() }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        var waitedMicros: UInt32 = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard waitedMicros < 250_000 else { break }
            usleep(10_000)
            waitedMicros += 10_000
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
