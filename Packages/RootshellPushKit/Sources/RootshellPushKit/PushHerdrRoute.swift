import CryptoKit
import Foundation

/// Routing uses the terminal identity, which survives public pane/tab moves.
public enum PushHerdrRoute {
    public static func serverIdentity(host: String, uid: String, socket: String) -> String? {
        guard !host.isEmpty, !uid.isEmpty, !socket.isEmpty else { return nil }
        let bytes = Data((host + "\0" + uid + "\0" + socket).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public struct Candidate {
        public let server: String?
        public let terminal: String
        public let isActive: Bool
        public let surfaceID: UUID?
        public let isOrdinary: Bool

        public init(server: String?, terminal: String, isActive: Bool,
                    surfaceID: UUID? = nil, isOrdinary: Bool = false) {
            self.server = server; self.terminal = terminal; self.isActive = isActive
            self.surfaceID = surfaceID; self.isOrdinary = isOrdinary
        }
    }

    public static func matchingIndex(route: PushRoute, candidates: [Candidate]) -> Int? {
        var match: Int?
        if let server = route.herdrServer, !server.isEmpty,
           let terminal = route.herdrTerminal, !terminal.isEmpty {
            for (index, candidate) in candidates.enumerated()
            where candidate.isActive && !candidate.isOrdinary && candidate.server == server && candidate.terminal == terminal {
                guard match == nil else { return nil }
                match = index
            }
        }
        if let match { return match }
        // A stock herdr TUI in an ordinary local/SSH tab still has an exact
        // rootshell surface identity, even when the socket lookup fails.
        guard let surface = route.pane.flatMap(UUID.init(uuidString:)) else { return nil }
        for (index, candidate) in candidates.enumerated()
        where candidate.isActive && candidate.isOrdinary && candidate.surfaceID == surface {
            guard match == nil else { return nil }
            match = index
        }
        return match
    }
}
