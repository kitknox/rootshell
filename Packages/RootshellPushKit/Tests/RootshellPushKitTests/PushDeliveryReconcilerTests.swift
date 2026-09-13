import XCTest
@testable import RootshellPushKit

final class PushDeliveryReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func event(_ eid: String, terminal: String, at date: Date) -> PushEventRecord {
        PushEventRecord(eid: eid, receivedAt: date, status: "done", agent: "codex", thread: nil,
                        route: PushRoute(herdrServer: "test-server", herdrTerminal: terminal, herdrPane: "w1:p2"))
    }

    func testUnresolvedEventsAndIdentifiersSurviveLaterResolvedEvents() {
        var queue = PushDeliveryReconciler()
        let old = event("old", terminal: "old-terminal", at: now.addingTimeInterval(-120))
        let new = event("new", terminal: "new-terminal", at: now.addingTimeInterval(-10))
        let oldPane = UUID(), newPane = UUID()
        queue.ingest([old, new], now: now)
        queue.track(identifier: "old-notification", route: old.route, receivedAt: old.receivedAt, now: now)
        queue.track(identifier: "new-notification", route: new.route, receivedAt: new.receivedAt, now: now)

        let initial = queue.reconcile(now: now) { $0?.herdrTerminal == "new-terminal" ? newPane : nil }
        XCTAssertEqual(initial.events.map(\.record.eid), ["new"])
        XCTAssertEqual(initial.deliveries.map(\.identifier), ["new-notification"])

        // A second disk read must neither discard the older unresolved record
        // nor replay the newer record that was already fed into arbitration.
        queue.ingest([old, new], now: now)
        let ready = queue.reconcile(now: now.addingTimeInterval(5)) { route in
            route?.herdrTerminal == "old-terminal" ? oldPane : newPane
        }
        XCTAssertEqual(ready.events.map(\.record.eid), ["old"])
        XCTAssertEqual(ready.events.first?.pane, oldPane)
        XCTAssertEqual(ready.events.first?.record.receivedAt, old.receivedAt)
        XCTAssertEqual(ready.deliveries.map(\.identifier), ["old-notification"])
        XCTAssertEqual(ready.deliveries.first?.pane, oldPane)
        let repeated = queue.reconcile(now: now) { _ in oldPane }
        XCTAssertTrue(repeated.events.isEmpty)
        XCTAssertTrue(repeated.deliveries.isEmpty)
    }

    func testBindingsReadyBeforeNotificationCenterSnapshotCompletes() {
        var queue = PushDeliveryReconciler()
        let record = event("event", terminal: "terminal", at: now)
        let pane = UUID()
        queue.ingest([record], now: now)
        XCTAssertTrue(queue.reconcile(now: now, resolve: { _ in nil }).events.isEmpty)
        let bound = queue.reconcile(now: now) { _ in pane }
        XCTAssertEqual(bound.events.count, 1)
        XCTAssertTrue(bound.deliveries.isEmpty)

        // The async snapshot arrives after the readiness notification. Its
        // completion reconciles immediately using the now-ready bindings.
        queue.track(identifier: "notification", route: record.route, receivedAt: now, now: now)
        queue.ingest([record], now: now)
        let completed = queue.reconcile(now: now) { _ in pane }
        XCTAssertTrue(completed.events.isEmpty)
        XCTAssertEqual(completed.deliveries.first?.identifier, "notification")
        XCTAssertEqual(completed.deliveries.first?.pane, pane)
    }

    func testLateAndEqualTimestampRecordsAreNotSkipped() {
        var queue = PushDeliveryReconciler()
        let first = event("first", terminal: "t", at: now)
        let equal = event("equal", terminal: "t", at: now)
        let late = event("late", terminal: "t", at: now.addingTimeInterval(-1))
        let pane = UUID()
        queue.ingest([first], now: now)
        XCTAssertEqual(queue.reconcile(now: now, resolve: { _ in pane }).events.count, 1)
        queue.ingest([first, equal, late], now: now)
        let matches = queue.reconcile(now: now) { _ in pane }
        XCTAssertEqual(matches.events.map(\.record.eid), ["late", "equal"])
    }

    func testUnresolvedRecordsAreBoundedAndExpire() {
        var queue = PushDeliveryReconciler()
        for index in 0...PushSharedState.maxRecords {
            let at = now.addingTimeInterval(Double(index) - 300)
            let record = event("event-\(index)", terminal: "terminal", at: at)
            queue.ingest([record], now: now)
            queue.track(identifier: "notification-\(index)", route: record.route, receivedAt: at, now: now)
        }
        var snapshot = queue
        let matches = snapshot.reconcile(now: now) { _ in UUID() }
        XCTAssertEqual(matches.events.count, PushSharedState.maxRecords)
        XCTAssertEqual(matches.deliveries.count, PushSharedState.maxRecords)
        XCTAssertFalse(matches.events.contains { $0.record.eid == "event-0" })
        let expired = queue.reconcile(now: now.addingTimeInterval(PushSharedState.retention + 1)) { _ in UUID() }
        XCTAssertTrue(expired.events.isEmpty)
        XCTAssertTrue(expired.deliveries.isEmpty)
    }

    func testAmbiguousRouteWaitsAndOrdinaryTabsStillReconcile() {
        var queue = PushDeliveryReconciler()
        let pane = UUID()
        let record = event("herdr", terminal: "terminal", at: now)
        queue.ingest([record], now: now)
        queue.track(identifier: "herdr-notification", route: record.route, receivedAt: now, now: now)
        XCTAssertTrue(queue.reconcile(now: now, resolve: { _ in nil }).deliveries.isEmpty)
        XCTAssertEqual(queue.reconcile(now: now, resolve: { _ in pane }).deliveries.first?.pane, pane)
        let ordinary = PushRoute(pane: pane.uuidString)
        queue.track(identifier: "ordinary-notification", route: ordinary, receivedAt: now, now: now)
        XCTAssertEqual(queue.reconcile(now: now) { $0?.pane.flatMap(UUID.init(uuidString:)) }.deliveries.first?.pane, pane)
    }

    func testFreshExplicitRepostsAreAssociatedWithoutCatchUpWithdrawal() {
        var queue = PushDeliveryReconciler()
        let pane = UUID()
        let route = PushRoute(pane: pane.uuidString)
        for status in ["info", "done", "failed"] {
            let header = PushHeader(kind: "generic", status: status, title: "Explicit test", route: route)
            queue.trackFresh(identifier: "fresh-\(status)", header: header, receivedAt: now, now: now)
            queue.ingest([PushEventRecord(eid: "event-\(status)", receivedAt: now, status: status,
                                         agent: nil, thread: nil, route: route)], now: now)
        }
        queue.track(identifier: "older-delivery", route: route, receivedAt: now.addingTimeInterval(-60), now: now)
        queue.trackFresh(identifier: "fresh-agent", header: PushHeader(kind: "agent", status: "done",
            title: "Agent test", route: route), receivedAt: now, now: now)

        let matches = queue.reconcile(now: now) { _ in pane }
        XCTAssertEqual(matches.events.count, 3)
        XCTAssertEqual(matches.deliveries.count, 5)
        XCTAssertTrue(matches.deliveries.allSatisfy { $0.pane == pane })
        // Old deliveries and agents on this SAME pane remain eligible, without
        // withdrawing any of its newly scheduled send/test notifications.
        XCTAssertEqual(Set(matches.deliveries.filter(\.allowsCatchUpWithdrawal).map(\.identifier)),
                       ["older-delivery", "fresh-agent"])
    }

    func testFreshExplicitPolicySurvivesDeferredIdentityAndOverlappingSnapshot() {
        var queue = PushDeliveryReconciler()
        let record = event("event", terminal: "terminal", at: now)
        let header = PushHeader(kind: "generic", status: "info", title: "Pairing test", route: record.route)
        queue.trackFresh(identifier: "fresh", header: header, receivedAt: now, now: now)
        XCTAssertTrue(queue.reconcile(now: now, resolve: { _ in nil }).deliveries.isEmpty)
        queue.track(identifier: "fresh", route: record.route, receivedAt: now, now: now)
        let pane = UUID()
        let ready = queue.reconcile(now: now) { _ in pane }
        XCTAssertEqual(ready.deliveries.first?.identifier, "fresh")
        XCTAssertEqual(ready.deliveries.first?.pane, pane)
        XCTAssertEqual(ready.deliveries.first?.allowsCatchUpWithdrawal, false)

        // A subsequent history sync still handles the now-existing delivery.
        queue.track(identifier: "fresh", route: record.route, receivedAt: now, now: now)
        XCTAssertEqual(queue.reconcile(now: now) { _ in pane }.deliveries.first?.allowsCatchUpWithdrawal, true)
    }
}
