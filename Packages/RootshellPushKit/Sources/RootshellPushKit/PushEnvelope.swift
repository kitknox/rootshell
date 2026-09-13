//
//  PushEnvelope.swift
//  RootshellPushKit
//
//  Wire format shared with push/envelope (Go). See push/PROTOCOL.md.
//

import Foundation

public enum PushProtocol {
    public static let version = 1
    public static let info = Data("rootshell-push/v1".utf8)
    public static let maxHeaderBytes = 1600
    static let eventIDPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,64}$")

    public static func isValidEventID(_ eid: String) -> Bool {
        eventIDPattern.firstMatch(in: eid, range: NSRange(eid.startIndex..., in: eid)) != nil
    }

    static func aad(eid: String) -> Data { Data("eid:\(eid)".utf8) }
}

public struct PushRoute: Codable, Sendable, Equatable {
    public var pane: String?
    public var tmuxPane: String?
    public var tmuxServer: String?
    public var tmuxSession: String?
    public var herdrServer: String?
    public var herdrTerminal: String?
    public var herdrPane: String?
    public var host: String?
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case pane, host, cwd
        case tmuxPane = "tmux_pane"
        case tmuxServer = "tmux_server"
        case tmuxSession = "tmux_session"
        case herdrServer = "herdr_server"
        case herdrTerminal = "herdr_terminal"
        case herdrPane = "herdr_pane"
    }

    public init(pane: String? = nil, tmuxPane: String? = nil, tmuxServer: String? = nil,
                tmuxSession: String? = nil, host: String? = nil, cwd: String? = nil,
                herdrServer: String? = nil, herdrTerminal: String? = nil, herdrPane: String? = nil) {
        self.pane = pane; self.tmuxPane = tmuxPane; self.tmuxServer = tmuxServer
        self.tmuxSession = tmuxSession; self.host = host; self.cwd = cwd
        self.herdrServer = herdrServer; self.herdrTerminal = herdrTerminal; self.herdrPane = herdrPane
    }

    /// An incomplete herdr route must not select an inherited gateway/tmux pane.
    public var hasHerdrRoute: Bool {
        herdrServer != nil || herdrTerminal != nil || herdrPane != nil
    }
}

public struct PushHeader: Codable, Sendable, Equatable {
    public var v: Int
    public var kind: String
    public var agent: String?
    public var status: String?
    public var title: String
    public var body: String?
    public var thread: String?
    public var route: PushRoute?

    public init(kind: String, agent: String? = nil, status: String? = nil, title: String, body: String? = nil,
                thread: String? = nil, route: PushRoute? = nil) {
        self.v = PushProtocol.version
        self.kind = kind; self.agent = agent; self.status = status; self.title = title; self.body = body
        self.thread = thread; self.route = route
    }

    /// Localized status line for agent notifications.
    public var statusSubtitle: String? {
        guard kind == "agent" else { return nil }
        switch status {
        case "blocked": return String(localized: "Needs your input", bundle: .main)
        case "done": return String(localized: "Finished", bundle: .main)
        case "failed": return String(localized: "Failed", bundle: .main)
        default: return nil
        }
    }

    public func userInfoDictionary() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }
}

/// The "rs" object in the APNs payload. `sid`/`did` are stamped by the relay
/// from the sender credential and drive device-side revocation.
public struct PushEnvelope: Codable, Sendable, Equatable {
    public var v: Int
    public var enc: String
    public var ct: String
    public var eid: String
    public var sid: String?
    public var did: String?

    public init(v: Int, enc: String, ct: String, eid: String, sid: String? = nil, did: String? = nil) {
        self.v = v; self.enc = enc; self.ct = ct; self.eid = eid; self.sid = sid; self.did = did
    }

    /// Parses the `rs` dictionary from a notification's userInfo.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let rs = userInfo["rs"] as? [String: Any],
              let v = rs["v"] as? Int, let enc = rs["enc"] as? String,
              let ct = rs["ct"] as? String, let eid = rs["eid"] as? String else { return nil }
        self.init(v: v, enc: enc, ct: ct, eid: eid, sid: rs["sid"] as? String, did: rs["did"] as? String)
    }

    public func validate() throws {
        guard v == PushProtocol.version else { throw PushCryptoError.malformed("version") }
        guard PushProtocol.isValidEventID(eid) else { throw PushCryptoError.malformed("eid") }
        guard let e = Data(base64URL: enc), e.count == XWing.encapsulationSize else { throw PushCryptoError.malformed("enc") }
        guard let c = Data(base64URL: ct), c.count >= 16, c.count <= PushProtocol.maxHeaderBytes + 16 else { throw PushCryptoError.malformed("ct") }
    }

    public static func seal(_ header: PushHeader, eid: String, to publicKey: XWing.PublicKey) throws -> PushEnvelope {
        guard PushProtocol.isValidEventID(eid) else { throw PushCryptoError.malformed("eid") }
        var h = header
        h.v = PushProtocol.version
        let pt = try PushJSON.encoder.encode(h)
        guard pt.count <= PushProtocol.maxHeaderBytes else { throw PushCryptoError.headerTooLarge }
        let (enc, ct) = try PushHPKE.seal(to: publicKey, info: PushProtocol.info, aad: PushProtocol.aad(eid: eid), plaintext: pt)
        return PushEnvelope(v: PushProtocol.version, enc: enc.base64URLEncodedString(), ct: ct.base64URLEncodedString(), eid: eid)
    }

    public func open(with privateKey: XWing.PrivateKey) throws -> PushHeader {
        try validate()
        let pt = try PushHPKE.open(with: privateKey, enc: Data(base64URL: enc)!, info: PushProtocol.info,
                                   aad: PushProtocol.aad(eid: eid), ciphertext: Data(base64URL: ct)!)
        let h = try PushJSON.decoder.decode(PushHeader.self, from: pt)
        guard h.v == PushProtocol.version else { throw PushCryptoError.malformed("header version") }
        return h
    }
}

enum PushJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
