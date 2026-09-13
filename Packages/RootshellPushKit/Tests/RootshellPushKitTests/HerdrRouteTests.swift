import XCTest
@testable import RootshellPushKit

final class HerdrRouteTests: XCTestCase {
    func testNamespaceMatchesGo() {
        XCTAssertEqual(PushHerdrRoute.serverIdentity(host: "dev.example", uid: "1000",
            socket: "/home/user/.config/herdr/herdr.sock"),
            "821bba138301c53b6e41e66f65a569561dab6a53b013d7ae5683404ce04dc41f")
        XCTAssertNil(PushHerdrRoute.serverIdentity(host: "", uid: "1000", socket: "/socket"))
        let base = PushHerdrRoute.serverIdentity(host: "dev", uid: "1000", socket: "/socket")
        for (host, uid, socket) in [("other", "1000", "/socket"), ("dev", "1001", "/socket"), ("dev", "1000", "/named/socket")] {
            XCTAssertNotEqual(base, PushHerdrRoute.serverIdentity(host: host, uid: uid, socket: socket))
        }
    }

    func testExactTerminalMatching() {
        let route = PushRoute(pane: "inherited-gateway", tmuxPane: "%1", tmuxServer: "tmux",
                              herdrServer: "server", herdrTerminal: "terminal", herdrPane: "old:p1")
        let match = PushHerdrRoute.Candidate(server: "server", terminal: "terminal", isActive: true)
        let wrongServer = PushHerdrRoute.Candidate(server: "other", terminal: "terminal", isActive: true)
        let replaced = PushHerdrRoute.Candidate(server: "server", terminal: "replacement", isActive: true)
        let inactive = PushHerdrRoute.Candidate(server: "server", terminal: "terminal", isActive: false)
        XCTAssertEqual(PushHerdrRoute.matchingIndex(route: route, candidates: [wrongServer, replaced, inactive, match]), 3)
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [wrongServer, replaced, inactive]))
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [match, match]))
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: []))
        // Neither the old public pane ID nor the inherited UUID is a routing key.
        var moved = route
        moved.herdrPane = "new:p9"
        moved.pane = "another-gateway"
        XCTAssertEqual(PushHerdrRoute.matchingIndex(route: moved, candidates: [match]), 0)
    }

    func testIncompleteHerdrRoutesDoNotBecomeLegacyRoutes() {
        for route in [PushRoute(herdrPane: "w1:p2"), PushRoute(herdrServer: "s"),
                      PushRoute(herdrTerminal: "t"), PushRoute(herdrPane: "")] {
            XCTAssertTrue(route.hasHerdrRoute)
            XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [
                .init(server: "s", terminal: "t", isActive: true)]))
        }
        XCTAssertFalse(PushRoute(pane: "surface", tmuxPane: "%1").hasHerdrRoute)
    }

    func testWireCompatibilityAndEncryption() throws {
        let old = try JSONDecoder().decode(PushRoute.self, from: Data(#"{"pane":"surface","tmux_pane":"%1"}"#.utf8))
        XCTAssertFalse(old.hasHerdrRoute)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(oldJSON["herdr_server"])
        let route = PushRoute(herdrServer: "namespace", herdrTerminal: "term_live", herdrPane: "w2:p7")
        let data = try JSONEncoder().encode(route)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json, ["herdr_server": "namespace", "herdr_terminal": "term_live", "herdr_pane": "w2:p7"])
        XCTAssertEqual(try JSONDecoder().decode(PushRoute.self, from: data), route)
        let key = try XWing.PrivateKey()
        let header = PushHeader(kind: "agent", agent: "codex", status: "done", title: "Done", route: route)
        let envelope = try PushEnvelope.seal(header, eid: "herdr-test", to: key.publicKey)
        XCTAssertEqual(try envelope.open(with: key), header)
        XCTAssertLessThan(try JSONEncoder().encode(envelope).count, 4096 - 300)
    }

    func testRegularHerdrKeepsExactOrdinaryTabRouting() {
        let surface = UUID()
        let ordinary = PushHerdrRoute.Candidate(server: nil, terminal: "", isActive: true,
                                                surfaceID: surface, isOrdinary: true)
        let unrelated = PushHerdrRoute.Candidate(server: nil, terminal: "", isActive: true,
                                                 surfaceID: UUID(), isOrdinary: true)
        let gateway = PushHerdrRoute.Candidate(server: nil, terminal: "", isActive: true, surfaceID: surface)
        let route = PushRoute(pane: surface.uuidString, herdrServer: "s", herdrTerminal: "t", herdrPane: "w1:p2")
        XCTAssertEqual(PushHerdrRoute.matchingIndex(route: route, candidates: [unrelated, ordinary]), 1)
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [gateway, unrelated]))
        // Missing socket, old notifier, and closed terminal all preserve the ordinary tab path.
        for partial in [PushRoute(pane: surface.uuidString, herdrPane: "w1:p2"), PushRoute(pane: surface.uuidString)] {
            XCTAssertEqual(PushHerdrRoute.matchingIndex(route: partial, candidates: [ordinary]), 0)
        }
        let projected = PushHerdrRoute.Candidate(server: "s", terminal: "t", isActive: true)
        XCTAssertEqual(PushHerdrRoute.matchingIndex(route: route, candidates: [ordinary, projected]), 1)
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [ordinary, projected, projected]))
        XCTAssertNil(PushHerdrRoute.matchingIndex(route: route, candidates: [ordinary, ordinary]))
    }
}
