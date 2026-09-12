import Foundation
import Testing
@testable import RootshellPushKit

@Suite("Live Activity agent ledger")
struct AgentActivityLedgerTests {
    private let plainPane = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    private let gateway = "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E"
    private let childPane = "C3D4E5F6-A7B8-4C9D-0E1F-2A3B4C5D6E7F"
    private let unresolvedChild = "D4E5F6A7-B8C9-4D0E-1F2A-3B4C5D6E7F8A"
    private let server = "host:/tmp/tmux-501/default,4242,1725700000"
    private let activityID = "activity-1"

    private func ledger() -> AgentActivityLedger {
        AgentActivityLedger(activityID: activityID, entries: [
            AgentActivityLedgerEntry(paneID: plainPane, bucket: .working, routePane: plainPane),
            AgentActivityLedgerEntry(paneID: childPane, bucket: .working, gatewayPane: gateway,
                                     tmuxServer: server, tmuxPaneID: 7),
        ])
    }

    @Test("Plain pane matches by its own UUID only")
    func plainPaneMatch() {
        let l = ledger()
        #expect(l.matchIndex(for: PushRoute(pane: plainPane)) == 0)
        #expect(l.matchIndex(for: PushRoute(pane: gateway)) == nil)
        #expect(l.matchIndex(for: PushRoute(pane: childPane)) == nil)
    }

    @Test("Control-mode pane matches canonical server + pane id")
    func canonicalTmux() {
        let l = ledger()
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7", tmuxServer: server)) == 1)
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%8", tmuxServer: server)) == nil)
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7", tmuxServer: "other")) == nil)
    }

    @Test("Canonical route against an entry whose server is still unresolved falls to the gateway tier")
    func unresolvedServer() {
        var l = ledger()
        l.entries[1].tmuxServer = nil
        // With a server in the route nothing canonical matches and the legacy
        // tier requires the route to carry no server, so no match.
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7", tmuxServer: server)) == nil)
        // A pre-canonical sender still resolves through the gateway UUID.
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7")) == 1)
    }

    @Test("Pre-canonical sender matches gateway UUID + pane id")
    func legacyTmux() {
        let l = ledger()
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7")) == 1)
        // Ordinary tmux inside a regular pane sets TMUX_PANE too; the pane's
        // own UUID still identifies it, as in the app's resolver.
        #expect(l.matchIndex(for: PushRoute(pane: plainPane, tmuxPane: "%7")) == 0)
        #expect(l.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%9")) == nil)
    }

    @Test("Ambiguous routes match nothing")
    func ambiguity() {
        var l = ledger()
        l.entries.append(AgentActivityLedgerEntry(paneID: "dup", bucket: .idle, routePane: plainPane))
        #expect(l.matchIndex(for: PushRoute(pane: plainPane)) == nil)
        #expect(l.matchIndex(for: nil) == nil)

        var c = ledger()
        c.entries.append(AgentActivityLedgerEntry(paneID: unresolvedChild, bucket: .idle, gatewayPane: gateway,
                                                  tmuxServer: server, tmuxPaneID: 7))
        #expect(c.matchIndex(for: PushRoute(pane: gateway, tmuxPane: "%7", tmuxServer: server)) == nil)
    }

    @Test("Lowercase UUIDs from the hook still match", arguments: [true, false])
    func caseInsensitiveUUID(withTmuxPane: Bool) {
        let l = ledger()
        if withTmuxPane {
            #expect(l.matchIndex(for: PushRoute(pane: gateway.lowercased(), tmuxPane: "%7")) == 1)
        } else {
            #expect(l.matchIndex(for: PushRoute(pane: plainPane.lowercased())) == 0)
        }
    }

    @Test("Hook statuses move a pane to attention once", arguments: ["blocked", "done", "failed"])
    func applyStatus(status: String) {
        var l = ledger()
        let stamp = Date(timeIntervalSince1970: 1_725_700_000)
        let first = l.apply(status: status, route: PushRoute(pane: plainPane), at: stamp)
        #expect(first)
        #expect(l.entries[0].bucket == .attention)
        #expect(l.pushUpdatedAt == stamp)
        #expect(l.workingCount == 1)
        #expect(l.attentionCount == 1)
        let second = l.apply(status: status, route: PushRoute(pane: plainPane), at: stamp.addingTimeInterval(60))
        #expect(!second)
        #expect(l.pushUpdatedAt == stamp)
    }

    @Test("Unknown statuses and unmatched routes change nothing")
    func applyIgnored() {
        var l = ledger()
        let working = l.apply(status: "working", route: PushRoute(pane: plainPane))
        let missing = l.apply(status: nil, route: PushRoute(pane: plainPane))
        let unknownPane = l.apply(status: "blocked", route: PushRoute(pane: "not-a-known-pane"))
        #expect(!working)
        #expect(!missing)
        #expect(!unknownPane)
        #expect(l.entries == ledger().entries)
        #expect(l.pushUpdatedAt == nil)
    }

    @Test("Store round-trips, modifies in place and expires old snapshots")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentActivityLedgerStore(container: dir)

        #expect(store.load() == nil)
        #expect(store.modify { _ in true } == nil)

        let written = ledger()
        store.save(written)
        #expect(store.load() == written)

        let modified = store.modify { $0.apply(status: "blocked", route: PushRoute(pane: plainPane)) }
        #expect(modified?.attentionCount == 1)
        #expect(store.load()?.attentionCount == 1)

        let untouched = store.modify { _ in false }
        #expect(untouched == store.load())

        #expect(store.load(now: written.writtenAt.addingTimeInterval(AgentActivityLedgerStore.maxAge + 1)) == nil)
        store.clear()
        #expect(store.load() == nil)
    }
}
