import CryptoKit
import Foundation
import os.log

/// Runs the OIDC side of the OpenPubkey protocol: a browser-based
/// authorization-code + PKCE flow whose nonce commits to the CIC, and the
/// refresh-token grant used for silent certificate renewal.
///
/// The public opkssh client registrations only allow localhost loopback
/// redirect URIs, so the flow runs an in-app loopback HTTP server
/// (OAuthCallbackServer) that catches the provider redirect and bounces it
/// to the rootshell:// scheme that ASWebAuthenticationSession captures.
@MainActor
final class OpenPubkeyClient {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "OpenPubkeyClient"
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
                return "Could not start the sign-in callback server (ports 3000, 10001 and 11110 are all in use)"
            case .authorizationFailed(let detail):
                return "Sign-in failed: \(detail)"
            case .tokenExchangeFailed(let detail):
                return "Token exchange failed: \(detail)"
            case .missingIDToken:
                return "The provider did not return an ID token"
            case .nonceMismatch:
                return "The returned ID token does not commit to this key (nonce mismatch)"
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

    /// Full browser sign-in. The CIC's nonce is sent as the OIDC nonce so
    /// the ID token commits to the ephemeral key.
    func login(provider: OIDCProviderConfig, cic: OpenPubkeyCIC) async throws -> Tokens {
        let discovery = try await OIDCDiscoveryDocument.fetch(issuer: provider.issuer)

        // PKCE + state
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let codeVerifier = Data(verifierBytes).base64URLEncodedString()
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = Data(stateBytes).base64URLEncodedString()

        // The opkssh client registrations fix both the ports and the path.
        // Bind a listener FIRST (falling back through the registered ports),
        // so the browser is only ever sent to a redirect URI that something
        // is actually listening on.
        var boundServer: OAuthCallbackServer?
        var boundPort: UInt16 = 0
        for port in OIDCProviderConfig.redirectPorts {
            let server = OAuthCallbackServer(
                port: port,
                redirectURLScheme: "rootshell",
                callbackPath: OIDCProviderConfig.redirectPath
            )
            do {
                try await server.start()
                boundServer = server
                boundPort = port
                break
            } catch {
                Self.logger.warning("Loopback port \(port) unavailable: \(error.localizedDescription)")
            }
        }
        guard let server = boundServer else {
            throw ClientError.loopbackPortUnavailable
        }

        let redirectURI = "http://localhost:\(boundPort)\(OIDCProviderConfig.redirectPath)"
        var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: cic.nonce),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authorizationURL = components.url else {
            await server.stop()
            throw ClientError.invalidIssuer(provider.issuer)
        }

        do {
            let code = try await runBrowserFlow(
                server: server,
                authorizationURL: authorizationURL,
                expectedState: state
            )
            return try await exchangeCode(
                code: code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                provider: provider,
                tokenEndpoint: discovery.tokenEndpoint,
                expectedNonce: cic.nonce
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
    /// nonce requirement; the verifier checks subject and freshness instead.
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

    // MARK: - Internals

    /// Starts the loopback server and the browser session concurrently; the
    /// browser lands on localhost, which 302s to rootshell:// so the
    /// ASWebAuthenticationSession completes. The code is taken from the
    /// server's parse (it validated state already).
    private func runBrowserFlow(
        server: OAuthCallbackServer,
        authorizationURL: URL,
        expectedState: String
    ) async throws -> String {
        async let callbackTask = server.waitForCallback(expectedState: expectedState)

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

        // Client-side sanity check: the ID token must commit to our CIC.
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
        request.httpBody = body
            .map { key, value in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

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
