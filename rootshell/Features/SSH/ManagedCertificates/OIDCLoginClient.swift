import CryptoKit
import Foundation
import os.log

/// Where the OIDC provider sends the browser back to. Both issuers use an
/// in-app loopback server (OAuthCallbackServer) that 302s to the rootshell://
/// scheme ASWebAuthenticationSession captures; they differ only in the
/// registered host, path and ports.
nonisolated struct LoopbackRedirect: Sendable {
    /// Host written into the redirect URI.
    let host: String
    /// Path the loopback server answers on.
    let handlerPath: String
    /// Path appended to the redirect URI; must match the registration exactly.
    let uriPath: String
    /// Tried in order; 0 binds any free port.
    let ports: [UInt16]

    /// The public opkssh client registrations fix both the ports and the path.
    static let openPubkey = LoopbackRedirect(
        host: "localhost",
        handlerPath: "/login-callback",
        uriPath: "/login-callback",
        ports: [3000, 10001, 11110]
    )

    /// `step oauth` redirect: `http://127.0.0.1:<port>` (no path), any port,
    /// or the host and port of the provisioner's `listenAddress`. The
    /// callback server only listens on loopback, so a wildcard or remote
    /// host falls back to 127.0.0.1.
    static func stepCA(host: String?, port: UInt16?) -> LoopbackRedirect {
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]
        let host = host.map { $0.lowercased() }.flatMap { loopbackHosts.contains($0) ? $0 : nil } ?? "127.0.0.1"
        return LoopbackRedirect(host: host, handlerPath: "/", uriPath: "", ports: [port ?? 0])
    }
}

/// Browser-based OIDC authorization-code + PKCE flow and the refresh-token
/// grant, shared by OpenPubkey and Smallstep identities. The caller picks the
/// nonce (OpenPubkey commits it to the CIC; step-ca uses a random one) and
/// the loopback redirect its client registration allows.
@MainActor
final class OIDCLoginClient {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "OIDCLoginClient"
    )

    enum ClientError: LocalizedError {
        case invalidIssuer(String)
        case discoveryFailed(String)
        case loopbackPortUnavailable
        case authorizationFailed(String)
        case tokenExchangeFailed(String)
        case missingIDToken
        case nonceMismatch
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidIssuer(let issuer):
                return "Invalid OIDC issuer URL: \(issuer)"
            case .discoveryFailed(let issuer):
                return "OIDC discovery failed for \(issuer)"
            case .loopbackPortUnavailable:
                return "Could not start the sign-in callback server because its port is in use"
            case .authorizationFailed(let detail):
                return "Sign-in failed: \(detail)"
            case .tokenExchangeFailed(let detail):
                return "Token exchange failed: \(detail)"
            case .missingIDToken:
                return "The provider did not return an ID token"
            case .nonceMismatch:
                return "The returned ID token does not match this sign-in (nonce mismatch)"
            case .cancelled:
                return "Sign-in was cancelled"
            }
        }
    }

    struct Tokens: Sendable {
        let idToken: String
        let accessToken: String?
        let refreshToken: String?
    }

    private struct TokenEndpointResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }

        /// Some providers send `""` instead of omitting the field.
        var usableRefreshToken: String? {
            refreshToken?.isEmpty == false ? refreshToken : nil
        }
    }

    private let webAuthProvider = ASWebAuthSessionProvider()

    /// Full browser sign-in. The returned ID token must carry `nonce`.
    func login(
        provider: OIDCProviderConfig,
        nonce: String,
        redirect: LoopbackRedirect,
        extraAuthParams: [URLQueryItem] = []
    ) async throws -> Tokens {
        let discovery = try await OIDCDiscoveryDocument.fetch(issuer: provider.issuer)

        // PKCE + state
        let codeVerifier = Self.randomBase64URL(byteCount: 32)
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
        let state = Self.randomBase64URL(byteCount: 16)

        // Bind a listener FIRST, so the browser is only ever sent to a
        // redirect URI that something is actually listening on.
        var boundServer: OAuthCallbackServer?
        var boundPort: UInt16 = 0
        for port in redirect.ports {
            let server = OAuthCallbackServer(
                port: port,
                expectedState: state,
                redirectURLScheme: "rootshell",
                callbackPath: redirect.handlerPath
            )
            do {
                try await server.start()
                guard let actual = await server.boundPort, actual != 0 else {
                    await server.stop()
                    continue
                }
                boundServer = server
                boundPort = actual
                break
            } catch {
                Self.logger.warning("Loopback port \(port) unavailable: \(error.localizedDescription)")
            }
        }
        guard let server = boundServer else {
            throw ClientError.loopbackPortUnavailable
        }

        let redirectURI = "http://\(redirect.host):\(boundPort)\(redirect.uriPath)"
        guard var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            await server.stop()
            throw ClientError.invalidIssuer(provider.issuer)
        }
        var queryItems = components.queryItems ?? []
        queryItems += [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        queryItems += extraAuthParams
        components.queryItems = queryItems
        guard let authorizationURL = components.url else {
            await server.stop()
            throw ClientError.invalidIssuer(provider.issuer)
        }

        do {
            let code = try await runBrowserFlow(
                server: server,
                authorizationURL: authorizationURL
            )
            return try await exchangeCode(
                code: code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                provider: provider,
                tokenEndpoint: discovery.tokenEndpoint,
                expectedNonce: nonce
            )
        } catch ASWebAuthSessionProvider.SessionError.userCancelled {
            throw ClientError.cancelled
        } catch OAuthCallbackServer.ServerError.cancelled {
            throw ClientError.cancelled
        } catch OAuthCallbackServer.ServerError.providerError(let description) {
            // The provider bounced back an OAuth error (access_denied,
            // invalid_scope, ...): a sign-in problem, not a server problem.
            throw ClientError.authorizationFailed(description)
        }
    }

    /// Silent renewal via the refresh-token grant. The fresh ID token has no
    /// nonce requirement; callers check subject and freshness instead.
    func refresh(provider: OIDCProviderConfig, refreshToken: String) async throws -> Tokens {
        let discovery = try await OIDCDiscoveryDocument.fetch(issuer: provider.issuer)

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": provider.clientID,
            "scope": provider.scopes,
        ]
        if let secret = provider.clientSecret {
            body["client_secret"] = secret
        }

        let response = try await postForm(to: discovery.tokenEndpoint, body: body)
        guard let idToken = response.idToken else {
            throw ClientError.missingIDToken
        }
        return Tokens(
            idToken: idToken,
            accessToken: response.accessToken,
            refreshToken: response.usableRefreshToken
        )
    }

    /// Random bytes, base64url-encoded (PKCE verifier, state, step-ca nonce).
    nonisolated static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: - Internals

    /// Starts the loopback server and the browser session concurrently; the
    /// browser lands on the loopback URL, which 302s to rootshell:// so the
    /// ASWebAuthenticationSession completes. The code is taken from the
    /// server's parse (it validated state already).
    private func runBrowserFlow(
        server: OAuthCallbackServer,
        authorizationURL: URL
    ) async throws -> String {
        async let callbackTask = server.waitForCallback()

        do {
            _ = try await webAuthProvider.startSession(
                authorizationURL: authorizationURL,
                callbackURLScheme: "rootshell"
            )
        } catch {
            // If the browser session dies, tear the server down so the
            // async-let doesn't dangle for its full timeout.
            await server.stop()
            _ = try? await callbackTask
            throw error
        }

        let callback = try await callbackTask
        return callback.code
    }

    private func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        provider: OIDCProviderConfig,
        tokenEndpoint: URL,
        expectedNonce: String
    ) async throws -> Tokens {
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": provider.clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": codeVerifier,
        ]
        if let secret = provider.clientSecret {
            body["client_secret"] = secret
        }

        let response = try await postForm(to: tokenEndpoint, body: body)
        guard let idToken = response.idToken else {
            throw ClientError.missingIDToken
        }

        let segments = try OpenPubkeyJOSE.split(compactJWS: idToken)
        let claims = try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: segments.payloadB64)
        guard claims.nonce == expectedNonce else {
            throw ClientError.nonceMismatch
        }

        return Tokens(
            idToken: idToken,
            accessToken: response.accessToken,
            refreshToken: response.usableRefreshToken
        )
    }

    private func postForm(to url: URL, body: [String: String]) async throws -> TokenEndpointResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.tokenExchangeFailed("invalid response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            Self.logger.error("Token endpoint error: \(http.statusCode) \(detail)")
            throw ClientError.tokenExchangeFailed(detail)
        }
        return try JSONDecoder().decode(TokenEndpointResponse.self, from: data)
    }
}

/// The subset of the OIDC discovery document the login flow needs.
nonisolated struct OIDCDiscoveryDocument: Decodable, Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }

    /// `issuer` is either an issuer URL or a full discovery URL (step-ca
    /// provisioners publish `configurationEndpoint`).
    static func fetch(issuer: String) async throws -> OIDCDiscoveryDocument {
        guard let url = discoveryURL(for: issuer), url.scheme?.lowercased() == "https" else {
            throw OIDCLoginClient.ClientError.invalidIssuer(issuer)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OIDCLoginClient.ClientError.discoveryFailed(issuer)
        }
        let document = try JSONDecoder().decode(OIDCDiscoveryDocument.self, from: data)
        // The code, verifier and client secret travel to these endpoints.
        guard document.authorizationEndpoint.scheme?.lowercased() == "https",
              document.tokenEndpoint.scheme?.lowercased() == "https" else {
            throw OIDCLoginClient.ClientError.discoveryFailed(issuer)
        }
        return document
    }

    static func discoveryURL(for issuer: String) -> URL? {
        let wellKnown = "/.well-known/openid-configuration"
        if issuer.contains(wellKnown) {
            return URL(string: issuer)
        }
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        return URL(string: base + wellKnown)
    }
}
