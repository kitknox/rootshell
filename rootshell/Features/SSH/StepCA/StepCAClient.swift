import CryptoKit
import Foundation
import os.log
import Security

/// HTTP client for a step-ca server's SSH endpoints. Every request after
/// bootstrap is TLS-anchored to the CA's own root, which the user pinned by
/// fingerprint (`step ca bootstrap --ca-url --fingerprint`).
nonisolated final class StepCAClient: Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "StepCAClient")

    enum ClientError: LocalizedError {
        case invalidURL(String)
        case invalidFingerprint
        case fingerprintMismatch
        case invalidRootCertificate
        case clientAuthenticationRequired
        case teamNotFound(String)
        case noUsableProvisioners
        case noHostKeys
        case missingProvisionerKey
        case server(status: Int, message: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid CA URL: \(url)"
            case .invalidFingerprint:
                return "The root fingerprint must be a 64-character SHA-256 hex string"
            case .fingerprintMismatch:
                return "The CA's root certificate does not match the fingerprint"
            case .invalidRootCertificate:
                return "The CA returned an unreadable root certificate"
            case .clientAuthenticationRequired:
                return "This CA requires client certificate authentication, which rootshell doesn't support"
            case .teamNotFound(let team):
                return "No Smallstep SSH authority found for team '\(team)'"
            case .noUsableProvisioners:
                return "This CA has no usable OIDC or JWK provisioners"
            case .noHostKeys:
                return "The CA didn't return an SSH host key to trust"
            case .missingProvisionerKey:
                return "The provisioner has no encrypted key to sign with"
            case .server(let status, let message):
                return "CA error (\(status)): \(message)"
            case .invalidResponse:
                return "The CA returned an unexpected response"
            }
        }
    }

    /// One entry of `GET /provisioners`, reduced to the fields an SSH user
    /// login needs. Fields of other provisioner types decode as nil.
    struct Provisioner: Decodable, Hashable, Sendable, Identifiable {
        let type: String
        let name: String
        let clientID: String?
        let clientSecret: String?
        let configurationEndpoint: String?
        let listenAddress: String?
        let scopes: [String]?
        let authParams: [String]?
        let keyID: String?
        let encryptedKey: String?

        var id: String { "\(type)/\(name)" }

        /// Has what sign-in needs: an OIDC client, or a JWK key to unlock.
        var isUsable: Bool {
            switch kind {
            case .oidc: return oidcProvider != nil && clientID?.isEmpty == false
            case .jwk: return keyID?.isEmpty == false
            case nil: return false
            }
        }

        var kind: StepCAInfo.ProvisionerKind? {
            switch type.uppercased() {
            case "OIDC": return .oidc
            case "JWK": return .jwk
            default: return nil
            }
        }

        /// The port of `listenAddress` (`:10000`, `localhost:10000`).
        var loopbackPort: UInt16? {
            guard let listenAddress, let colon = listenAddress.lastIndex(of: ":") else { return nil }
            return UInt16(listenAddress[listenAddress.index(after: colon)...])
        }

        /// The host of `listenAddress`, kept as written: `step oauth` puts it
        /// in the redirect URI verbatim. Nil when empty (127.0.0.1).
        var loopbackHost: String? {
            guard let listenAddress, let colon = listenAddress.lastIndex(of: ":") else { return nil }
            let host = String(listenAddress[..<colon])
            return host.isEmpty ? nil : host
        }

        /// The OIDC provider `step oauth` would use for this provisioner.
        var oidcProvider: OIDCProviderConfig? {
            guard kind == .oidc, let clientID, let configurationEndpoint else { return nil }
            let scopeList = (scopes?.isEmpty == false) ? scopes! : ["openid", "email"]
            return OIDCProviderConfig(
                providerID: "stepca",
                displayName: name,
                issuer: configurationEndpoint,
                clientID: clientID,
                clientSecret: clientSecret?.isEmpty == false ? clientSecret : nil,
                scopes: scopeList.joined(separator: " ")
            )
        }

        private enum CodingKeys: String, CodingKey {
            case type, name, clientID, clientSecret, configurationEndpoint
            case listenAddress, scopes, authParams, key, encryptedKey
        }

        private struct PublicJWK: Decodable {
            let kid: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            name = try c.decode(String.self, forKey: .name)
            clientID = try? c.decodeIfPresent(String.self, forKey: .clientID)
            clientSecret = try? c.decodeIfPresent(String.self, forKey: .clientSecret)
            configurationEndpoint = try? c.decodeIfPresent(String.self, forKey: .configurationEndpoint)
            listenAddress = try? c.decodeIfPresent(String.self, forKey: .listenAddress)
            scopes = try? c.decodeIfPresent([String].self, forKey: .scopes)
            authParams = try? c.decodeIfPresent([String].self, forKey: .authParams)
            keyID = (try? c.decodeIfPresent(PublicJWK.self, forKey: .key))?.kid
            encryptedKey = try? c.decodeIfPresent(String.self, forKey: .encryptedKey)
        }
    }

    let baseURL: URL
    private let rootDER: Data

    init(caURL: String, rootDER: Data) throws {
        baseURL = try Self.normalizedCAURL(caURL)
        self.rootDER = rootDER
    }

    /// CA requests go over ``PinnedHTTPSClient`` (anchored to the CA root, or
    /// unanchored for the fingerprint-checked root download); the public
    /// Smallstep team API uses the system trust store.
    private enum Transport {
        case pinned(anchorDER: Data?)
        case system
    }

    // MARK: - Bootstrap

    /// Accepts `ca.example.com`, `https://ca.example.com:9000/` and the like.
    static func normalizedCAURL(_ string: String) throws -> URL {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.query == nil, url.fragment == nil,
              url.port.map({ UInt16(exactly: $0) != nil && $0 != 0 }) ?? true else {
            throw ClientError.invalidURL(string)
        }
        return url
    }

    /// Lowercase hex without separators, or nil when not a SHA-256 digest.
    static func normalizedFingerprint(_ string: String) -> String? {
        let hex = string.lowercased().filter { !":- \n\t".contains($0) }
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// `GET /root/{fingerprint}` without TLS verification, then checks the
    /// returned root against the fingerprint; returns its DER.
    static func fetchRoot(caURL: String, fingerprint: String) async throws -> Data {
        let base = try normalizedCAURL(caURL)
        guard let fingerprint = normalizedFingerprint(fingerprint) else {
            throw ClientError.invalidFingerprint
        }
        struct RootResponse: Decodable { let ca: String }
        let data: Data
        do {
            data = try await performRequest(.pinned(anchorDER: nil), URLRequest(url: base.appendingPathComponent("root/\(fingerprint)")))
        } catch ClientError.server(let status, _) where status == 404 {
            // step-ca only serves a root by its own fingerprint.
            throw ClientError.fingerprintMismatch
        }
        let response = try JSONDecoder().decode(RootResponse.self, from: data)
        guard let der = derFromPEM(response.ca) else {
            throw ClientError.invalidRootCertificate
        }
        guard sha256Hex(der) == fingerprint else {
            throw ClientError.fingerprintMismatch
        }
        return der
    }

    /// Hosted Smallstep teams publish their SSH authority's CA URL and root
    /// fingerprint (what `step ssh config --team` reads).
    static func teamAuthority(team: String) async throws -> (caURL: String, fingerprint: String) {
        let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "https://api.smallstep.com/v1/teams/\(encoded)/authorities/ssh") else {
            throw ClientError.teamNotFound(team)
        }
        struct TeamAuthority: Decodable {
            let caURL: String
            let fingerprint: String
            enum CodingKeys: String, CodingKey {
                case caURL = "url"
                case fingerprint
            }
        }
        do {
            let data = try await performRequest(.system, URLRequest(url: url))
            let authority = try JSONDecoder().decode(TeamAuthority.self, from: data)
            return (authority.caURL, authority.fingerprint)
        } catch ClientError.server(let status, _) where status == 404 {
            throw ClientError.teamNotFound(trimmed)
        }
    }

    // MARK: - CA API

    /// Fails for CAs that require an identity certificate on every request.
    func checkSupported() async throws {
        struct VersionResponse: Decodable {
            let requireClientAuthentication: Bool?
        }
        let data = try await get("version")
        let version = try JSONDecoder().decode(VersionResponse.self, from: data)
        if version.requireClientAuthentication == true {
            throw ClientError.clientAuthenticationRequired
        }
    }

    /// OIDC and JWK provisioners, across all pages.
    func provisioners() async throws -> [Provisioner] {
        struct Page: Decodable {
            let provisioners: [Provisioner]
            let nextCursor: String?
        }
        var result: [Provisioner] = []
        var cursor = ""
        var seenCursors: Set<String> = []
        repeat {
            var components = URLComponents(url: baseURL.appendingPathComponent("provisioners"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "cursor", value: cursor),
                URLQueryItem(name: "limit", value: "100"),
            ]
            let data = try await Self.performRequest(.pinned(anchorDER: rootDER), URLRequest(url: components.url!))
            let page = try JSONDecoder().decode(Page.self, from: data)
            result += page.provisioners
            cursor = page.nextCursor ?? ""
            // A CA (or proxy) repeating a cursor would otherwise loop forever.
            guard seenCursors.insert(cursor).inserted else { break }
        } while !cursor.isEmpty
        let usable = result.filter(\.isUsable)
        guard !usable.isEmpty else { throw ClientError.noUsableProvisioners }
        return usable
    }

    /// The JWE-encrypted private key of a JWK provisioner.
    func encryptedKey(provisioner: Provisioner) async throws -> String {
        if let inline = provisioner.encryptedKey, !inline.isEmpty {
            return inline
        }
        guard let kid = provisioner.keyID else { throw ClientError.missingProvisionerKey }
        struct KeyResponse: Decodable { let key: String }
        // Separate components so a kid is escaped as one path segment.
        let url = baseURL.appendingPathComponent("provisioners").appendingPathComponent(kid).appendingPathComponent("encrypted-key")
        let data = try await Self.performRequest(.pinned(anchorDER: rootDER), URLRequest(url: url))
        return try JSONDecoder().decode(KeyResponse.self, from: data).key
    }

    /// The audience a JWK one-time token must carry for `/ssh/sign`.
    var sshSignAudience: String {
        baseURL.appendingPathComponent("1.0/ssh/sign").absoluteString
    }

    /// `POST /1.0/ssh/sign` for a user certificate; returns the OpenSSH
    /// one-line form (`<cert type> <base64>`).
    func signUserCertificate(publicKeyBlob: Data, ott: String, keyID: String?, principals: [String]) async throws -> String {
        var body: [String: Any] = [
            "publicKey": publicKeyBlob.base64EncodedString(),
            "ott": ott,
            "certType": "user",
            // Back-date a minute for clock skew, as `step ssh login` does.
            "validAfter": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
        ]
        if let keyID {
            body["keyID"] = keyID
        }
        if !principals.isEmpty {
            body["principals"] = principals
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("1.0/ssh/sign"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        struct SignResponse: Decodable { let crt: String }
        let data = try await Self.performRequest(.pinned(anchorDER: rootDER), request)
        let crt = try JSONDecoder().decode(SignResponse.self, from: data).crt
        guard let blob = Data(base64Encoded: crt), let type = Self.sshKeyType(ofWireBlob: blob) else {
            throw ClientError.invalidResponse
        }
        return "\(type) \(crt)"
    }

    /// The CA's SSH host-signing keys in OpenSSH form (`<type> <base64>`),
    /// for `@cert-authority`-style host trust.
    func sshHostCAKeys() async throws -> [String] {
        struct RootsResponse: Decodable { let hostKey: [String]? }
        let data = try await get("ssh/roots")
        let roots = try JSONDecoder().decode(RootsResponse.self, from: data)
        let keys: [String] = (roots.hostKey ?? []).compactMap { b64 in
            guard let blob = Data(base64Encoded: b64), let type = Self.sshKeyType(ofWireBlob: blob) else { return nil }
            return "\(type) \(b64)"
        }
        guard !keys.isEmpty else { throw ClientError.noHostKeys }
        return keys
    }

    // MARK: - Helpers

    private func get(_ path: String) async throws -> Data {
        try await Self.performRequest(.pinned(anchorDER: rootDER), URLRequest(url: baseURL.appendingPathComponent(path)))
    }

    private static func performRequest(_ transport: Transport, _ request: URLRequest) async throws -> Data {
        let status: Int
        let data: Data
        switch transport {
        case .pinned(let anchorDER):
            let response = try await PinnedHTTPSClient.send(request, anchorDER: anchorDER)
            status = response.status
            data = response.body
        case .system:
            var request = request
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }
            status = http.statusCode
            data = body
        }
        guard (200..<300).contains(status) else {
            struct ErrorBody: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            logger.error("step-ca \(request.url?.path ?? "", privacy: .public) failed: \(status) \(message, privacy: .public)")
            throw ClientError.server(status: status, message: message)
        }
        return data
    }

    static func derFromPEM(_ pem: String) -> Data? {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The leading SSH wire string of a key or certificate blob.
    static func sshKeyType(ofWireBlob blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= blob.count - 4 else { return nil }
        return String(data: blob.dropFirst(4).prefix(length), encoding: .utf8)
    }
}

