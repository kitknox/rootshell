import Foundation

/// Keeps unresolved deliveries across identity/topology changes. Receipt times,
/// rather than reconciliation times, govern cross-source notification arbitration.
public struct PushDeliveryReconciler {
    private struct Delivery {
        let identifier: String
        let route: PushRoute
        let receivedAt: Date
        let allowsCatchUpWithdrawal: Bool
    }

    private var pendingEvents: [String: PushEventRecord] = [:]
    private var completedEvents: [String: Date] = [:]
    private var pendingDeliveries: [String: Delivery] = [:]

    public init() {}

    public mutating func ingest(_ records: [PushEventRecord], now: Date = Date()) {
        prune(now: now)
        for record in records where record.route != nil && record.receivedAt > now.addingTimeInterval(-PushSharedState.retention) {
            guard completedEvents[record.eid] == nil, pendingEvents[record.eid] == nil else { continue }
            pendingEvents[record.eid] = record
        }
        trimEvents()
    }

    public mutating func trackFresh(identifier: String, header: PushHeader, receivedAt: Date, now: Date = Date()) {
        track(identifier: identifier, route: header.route, receivedAt: receivedAt, now: now,
              allowsCatchUpWithdrawal: header.kind == "agent")
    }

    public mutating func track(identifier: String, route: PushRoute?, receivedAt: Date, now: Date = Date(),
                               allowsCatchUpWithdrawal: Bool = true) {
        guard let route, receivedAt > now.addingTimeInterval(-PushSharedState.retention) else { return }
        // A snapshot arriving while a fresh explicit delivery awaits identity
        // must not turn that delivery into catch-up work.
        let allowsWithdrawal = allowsCatchUpWithdrawal && (pendingDeliveries[identifier]?.allowsCatchUpWithdrawal ?? true)
        pendingDeliveries[identifier] = Delivery(identifier: identifier, route: route,
            receivedAt: receivedAt, allowsCatchUpWithdrawal: allowsWithdrawal)
        if pendingDeliveries.count > PushSharedState.maxRecords {
            let oldest = pendingDeliveries.values.sorted { $0.receivedAt < $1.receivedAt }
                .prefix(pendingDeliveries.count - PushSharedState.maxRecords)
            for delivery in oldest { pendingDeliveries.removeValue(forKey: delivery.identifier) }
        }
    }

    /// Called synchronously when bindings become ready, and after each async
    /// Notification Center snapshot. Completed events are never replayed.
    public mutating func reconcile(now: Date = Date(), resolve: (PushRoute?) -> UUID?)
        -> (events: [(record: PushEventRecord, pane: UUID)],
            deliveries: [(identifier: String, pane: UUID, allowsCatchUpWithdrawal: Bool)]) {
        guard !pendingEvents.isEmpty || !pendingDeliveries.isEmpty else { return ([], []) }
        prune(now: now)
        var events: [(record: PushEventRecord, pane: UUID)] = []
        var deliveries: [(identifier: String, pane: UUID, allowsCatchUpWithdrawal: Bool)] = []
        for record in pendingEvents.values.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard let pane = resolve(record.route) else { continue }
            events.append((record, pane))
            completedEvents[record.eid] = record.receivedAt
            pendingEvents.removeValue(forKey: record.eid)
        }
        for delivery in Array(pendingDeliveries.values) {
            guard let pane = resolve(delivery.route) else { continue }
            deliveries.append((delivery.identifier, pane, delivery.allowsCatchUpWithdrawal))
            pendingDeliveries.removeValue(forKey: delivery.identifier)
        }
        trimEvents()
        return (events, deliveries)
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-PushSharedState.retention)
        pendingEvents = pendingEvents.filter { $0.value.receivedAt > cutoff }
        completedEvents = completedEvents.filter { $0.value > cutoff }
        pendingDeliveries = pendingDeliveries.filter { $0.value.receivedAt > cutoff }
    }

    private mutating func trimEvents() {
        // Keep the same bounds as the app-group history, without a timestamp
        // watermark that would lose late or equal-timestamp records.
        if pendingEvents.count > PushSharedState.maxRecords {
            for record in pendingEvents.values.sorted(by: { $0.receivedAt < $1.receivedAt })
                .prefix(pendingEvents.count - PushSharedState.maxRecords) {
                pendingEvents.removeValue(forKey: record.eid)
            }
        }
        if completedEvents.count > PushSharedState.maxRecords {
            for entry in completedEvents.sorted(by: { $0.value < $1.value })
                .prefix(completedEvents.count - PushSharedState.maxRecords) {
                completedEvents.removeValue(forKey: entry.key)
            }
        }
    }
}
