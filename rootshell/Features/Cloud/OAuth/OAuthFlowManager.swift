import Foundation
import UIKit
import CryptoKit
import Combine
import os.log

// MARK: - OAuth Flow Manager

/// Manages OAuth 2.0 authorization flows with PKCE support
/// Uses a localhost HTTP server to capture OAuth callbacks since Linode
/// doesn't support custom URL schemes
@MainActor
class OAuthFlowManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "OAuthFlowManager")

    // MARK: - Types

    enum OAuthError: Error, LocalizedError {
        case invalidConfiguration
        case pkceGenerationFailed
        case tokenExchangeFailed(String)
        case networkError(Error)
        case cancelled
        case serverError(Error)
        case invalidCallbackURL

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Invalid OAuth configuration"
            case .pkceGenerationFailed:
                return "Failed to generate PKCE parameters"
            case .tokenExchangeFailed(let reason):
                return "Token exchange failed: \(reason)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .cancelled:
                return "OAuth flow was cancelled"
            case .serverError(let error):
                return error.localizedDescription
            case .invalidCallbackURL:
                return "Invalid callback URL received"
            }
        }
    }

    struct TokenResponse: Codable {
        let accessToken: String
        let tokenType: String?
        let bearer: String?  // DigitalOcean uses "bearer" instead of "token_type"
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case bearer
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    // MARK: - Constants

    /// The URL scheme used for OAuth callbacks via ASWebAuthenticationSession
    private static let callbackURLScheme = "rootshell"

    // MARK: - State

    @Published private(set) var isAuthenticating = false
    @Published private(set) var statusMessage: String?

    private var currentPKCE: PKCEParameters?
    private var callbackServer: OAuthCallbackServer?
    private var currentOAuthConfig: OAuthConfiguration?
    private var sessionProvider: ASWebAuthSessionProvider?

    // MARK: - PKCE Parameters

    private struct PKCEParameters {
        let codeVerifier: String
        let codeChallenge: String
        let state: String
    }

    // MARK: - OAuth Configuration

    /// OAuth configuration for a provider
    struct OAuthConfiguration {
        let providerID: String
        let authorizationURL: URL
        let tokenURL: URL
        let clientID: String
        let clientSecret: String?
        let redirectPort: UInt16
        let redirectURI: URL
        let scopes: String
    }

    // MARK: - OAuth Flow

    /// Start the OAuth flow for Linode
    /// - Parameter accountLabel: Label for the account being created
    /// - Returns: OAuth credentials on success
    func startLinodeOAuth(accountLabel: String) async throws -> CloudCredentials {
        let config = OAuthConfiguration(
            providerID: LinodeProvider.providerID,
            authorizationURL: LinodeProvider.OAuthConfig.authorizationURL,
            tokenURL: LinodeProvider.OAuthConfig.tokenURL,
            clientID: LinodeProvider.OAuthConfig.clientID,
            clientSecret: LinodeProvider.OAuthConfig.clientSecret,
            redirectPort: LinodeProvider.OAuthConfig.redirectPort,
            redirectURI: LinodeProvider.OAuthConfig.redirectURI,
            scopes: LinodeProvider.OAuthConfig.scopes
        )
        return try await startOAuth(config: config, accountLabel: accountLabel)
    }

    /// Re-authenticate an existing Linode account (refreshes OAuth tokens without creating new account)
    /// - Parameter existingAccountID: The UUID of the existing account to re-authenticate
    /// - Returns: Updated OAuth credentials with the same account ID
    func reauthenticateLinode(existingAccountID: UUID) async throws -> CloudCredentials {
        let config = OAuthConfiguration(
            providerID: LinodeProvider.providerID,
            authorizationURL: LinodeProvider.OAuthConfig.authorizationURL,
            tokenURL: LinodeProvider.OAuthConfig.tokenURL,
            clientID: LinodeProvider.OAuthConfig.clientID,
            clientSecret: LinodeProvider.OAuthConfig.clientSecret,
            redirectPort: LinodeProvider.OAuthConfig.redirectPort,
            redirectURI: LinodeProvider.OAuthConfig.redirectURI,
            scopes: LinodeProvider.OAuthConfig.scopes
        )
        return try await reauthenticate(config: config, existingAccountID: existingAccountID)
    }

    /// Re-authenticate an existing DigitalOcean account
    /// - Parameter existingAccountID: The UUID of the existing account to re-authenticate
    /// - Returns: Updated OAuth credentials with the same account ID
    func reauthenticateDigitalOcean(existingAccountID: UUID) async throws -> CloudCredentials {
        let config = OAuthConfiguration(
            providerID: DigitalOceanProvider.providerID,
            authorizationURL: DigitalOceanProvider.OAuthConfig.authorizationURL,
            tokenURL: DigitalOceanProvider.OAuthConfig.tokenURL,
            clientID: DigitalOceanProvider.OAuthConfig.clientID,
            clientSecret: DigitalOceanProvider.OAuthConfig.clientSecret,
            redirectPort: DigitalOceanProvider.OAuthConfig.redirectPort,
            redirectURI: DigitalOceanProvider.OAuthConfig.redirectURI,
            scopes: DigitalOceanProvider.OAuthConfig.scopes
        )
        return try await reauthenticate(config: config, existingAccountID: existingAccountID)
    }

    /// Start the OAuth flow for DigitalOcean
    /// - Parameter accountLabel: Label for the account being created
    /// - Returns: OAuth credentials on success
    func startDigitalOceanOAuth(accountLabel: String) async throws -> CloudCredentials {
        let config = OAuthConfiguration(
            providerID: DigitalOceanProvider.providerID,
            authorizationURL: DigitalOceanProvider.OAuthConfig.authorizationURL,
            tokenURL: DigitalOceanProvider.OAuthConfig.tokenURL,
            clientID: DigitalOceanProvider.OAuthConfig.clientID,
            clientSecret: DigitalOceanProvider.OAuthConfig.clientSecret,
            redirectPort: DigitalOceanProvider.OAuthConfig.redirectPort,
            redirectURI: DigitalOceanProvider.OAuthConfig.redirectURI,
            scopes: DigitalOceanProvider.OAuthConfig.scopes
        )
        return try await startOAuth(config: config, accountLabel: accountLabel)
    }

    /// Start the OAuth flow for a provider
    /// - Parameters:
    ///   - config: OAuth configuration for the provider
    ///   - accountLabel: Label for the account being created
    /// - Returns: OAuth credentials on success
    func startOAuth(config: OAuthConfiguration, accountLabel: String) async throws -> CloudCredentials {
        try validate(config: config)

        guard !isAuthenticating else {
            throw OAuthError.cancelled
        }

        isAuthenticating = true
        statusMessage = "Preparing authentication..."
        currentOAuthConfig = config

        defer {
            isAuthenticating = false
            statusMessage = nil
            currentPKCE = nil
            callbackServer = nil
            currentOAuthConfig = nil
            sessionProvider = nil
        }

        // Generate PKCE parameters
        guard let pkce = generatePKCE() else {
            throw OAuthError.pkceGenerationFailed
        }
        currentPKCE = pkce

        Self.logger.info("Generated PKCE parameters, state: \(pkce.state)")

        // Build authorization URL
        let authURL = try buildAuthorizationURL(pkce: pkce, config: config)
        Self.logger.info("Authorization URL: \(authURL.absoluteString)")

        // Start the localhost callback server in REDIRECT mode
        // The server will redirect to rootshell:// which ASWebAuthenticationSession will capture
        statusMessage = "Starting callback server..."
        Self.logger.info("Starting callback server on port \(config.redirectPort) with redirect scheme: \(Self.callbackURLScheme)")

        let server = OAuthCallbackServer(
            port: config.redirectPort,
            expectedState: pkce.state,
            redirectURLScheme: Self.callbackURLScheme
        )
        callbackServer = server

        // Start the server listening task (it handles the redirect, but we get the result from ASWebAuthenticationSession)
        let serverTask = Task<OAuthCallbackServer.OAuthCallback, Error> {
            Self.logger.info("Server waiting for OAuth callback...")
            return try await server.waitForCallback()
        }

        // Give the server a moment to start listening
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Use ASWebAuthenticationSession instead of opening Safari directly
        // This keeps the app in foreground and captures the rootshell:// redirect
        statusMessage = "Opening authentication..."
        Self.logger.info("Starting ASWebAuthenticationSession")

        let provider = ASWebAuthSessionProvider()
        self.sessionProvider = provider

        let callbackURL: URL
        do {
            callbackURL = try await provider.startSession(
                authorizationURL: authURL,
                callbackURLScheme: Self.callbackURLScheme
            )
            Self.logger.info("Received callback URL from ASWebAuthenticationSession")
        } catch let error as ASWebAuthSessionProvider.SessionError where error == .userCancelled {
            // Cancelling the task alone leaves the listener up until its timeout.
            await server.stop()
            throw OAuthError.cancelled
        } catch {
            await server.stop()
            Self.logger.error("ASWebAuthenticationSession error: \(error.localizedDescription)")
            throw OAuthError.serverError(error)
        }

        // Cancel the server task - we already have the callback URL
        serverTask.cancel()

        // Parse callback URL to extract code and state
        guard let params = callbackURL.oauthCallbackParameters() else {
            Self.logger.error("Failed to parse callback URL: \(callbackURL)")
            throw OAuthError.invalidCallbackURL
        }

        // Validate state matches PKCE state; a missing state is a mismatch too
        guard params.state == pkce.state else {
            Self.logger.error("State mismatch: expected \(pkce.state), got \(params.state ?? "nil")")
            throw OAuthError.invalidCallbackURL
        }

        Self.logger.info("Received authorization code (length: \(params.code.count))")

        // Exchange code for tokens
        statusMessage = "Exchanging authorization code..."
        let tokens = try await exchangeCodeForTokens(code: params.code, pkce: pkce, config: config)

        Self.logger.info("Token exchange successful")

        // Create credentials
        let accountID = UUID()
        var expiresAt: Date?
        if let expiresIn = tokens.expiresIn {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }

        let credentials = CloudCredentials.oauth(
            accountID: accountID,
            providerID: config.providerID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt,
            scopes: tokens.scope
        )

        // Log what's being stored
        let hasRefresh = credentials.oauthRefreshToken != nil
        let expiresDesc = expiresAt.map { "\($0)" } ?? "never"
        Self.logger.info("Created OAuth credentials - provider: \(config.providerID), has_refresh_token: \(hasRefresh), expires: \(expiresDesc)")

        return credentials
    }

    /// Re-authenticate an existing account (keeps same account ID, gets fresh tokens)
    /// - Parameters:
    ///   - config: OAuth configuration for the provider
    ///   - existingAccountID: The UUID of the existing account
    /// - Returns: Updated OAuth credentials with fresh tokens
    func reauthenticate(config: OAuthConfiguration, existingAccountID: UUID) async throws -> CloudCredentials {
        try validate(config: config)

        guard !isAuthenticating else {
            throw OAuthError.cancelled
        }

        isAuthenticating = true
        statusMessage = "Re-authenticating..."
        currentOAuthConfig = config

        defer {
            isAuthenticating = false
            statusMessage = nil
            currentPKCE = nil
            callbackServer = nil
            currentOAuthConfig = nil
            sessionProvider = nil
        }

        // Generate PKCE parameters
        guard let pkce = generatePKCE() else {
            throw OAuthError.pkceGenerationFailed
        }
        currentPKCE = pkce

        Self.logger.info("Re-authenticating account \(existingAccountID.uuidString)")

        // Build authorization URL
        let authURL = try buildAuthorizationURL(pkce: pkce, config: config)

        // Start the localhost callback server in REDIRECT mode
        statusMessage = "Starting callback server..."
        Self.logger.info("Starting callback server on port \(config.redirectPort) with redirect scheme: \(Self.callbackURLScheme)")

        let server = OAuthCallbackServer(
            port: config.redirectPort,
            expectedState: pkce.state,
            redirectURLScheme: Self.callbackURLScheme
        )
        callbackServer = server

        let serverTask = Task<OAuthCallbackServer.OAuthCallback, Error> {
            return try await server.waitForCallback()
        }

        // Give the server a moment to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // Use ASWebAuthenticationSession instead of opening Safari
        statusMessage = "Opening authentication..."
        Self.logger.info("Starting ASWebAuthenticationSession for re-authentication")

        let provider = ASWebAuthSessionProvider()
        self.sessionProvider = provider

        let callbackURL: URL
        do {
            callbackURL = try await provider.startSession(
                authorizationURL: authURL,
                callbackURLScheme: Self.callbackURLScheme
            )
        } catch let error as ASWebAuthSessionProvider.SessionError where error == .userCancelled {
            // Cancelling the task alone leaves the listener up until its timeout.
            await server.stop()
            throw OAuthError.cancelled
        } catch {
            await server.stop()
            Self.logger.error("ASWebAuthenticationSession error: \(error.localizedDescription)")
            throw OAuthError.serverError(error)
        }

        serverTask.cancel()

        // Parse callback URL to extract code and state
        guard let params = callbackURL.oauthCallbackParameters() else {
            Self.logger.error("Failed to parse callback URL: \(callbackURL)")
            throw OAuthError.invalidCallbackURL
        }

        // Validate state matches PKCE state; a missing state is a mismatch too
        guard params.state == pkce.state else {
            Self.logger.error("State mismatch: expected \(pkce.state), got \(params.state ?? "nil")")
            throw OAuthError.invalidCallbackURL
        }

        // Exchange code for tokens
        statusMessage = "Exchanging authorization code..."
        let tokens = try await exchangeCodeForTokens(code: params.code, pkce: pkce, config: config)

        Self.logger.info("Re-authentication successful for account \(existingAccountID.uuidString)")

        // Create credentials with EXISTING account ID
        var expiresAt: Date?
        if let expiresIn = tokens.expiresIn {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }

        let credentials = CloudCredentials.oauth(
            accountID: existingAccountID,  // Keep existing account ID
            providerID: config.providerID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt,
            scopes: tokens.scope
        )

        let hasRefresh = credentials.oauthRefreshToken != nil
        Self.logger.info("Re-auth credentials - provider: \(config.providerID), has_refresh_token: \(hasRefresh)")

        return credentials
    }

    /// Cancel the current OAuth flow
    func cancel() {
        Self.logger.info("Cancelling OAuth flow")
        sessionProvider?.cancel()
        sessionProvider = nil
        Task {
            await callbackServer?.stop()
        }
        callbackServer = nil
        isAuthenticating = false
        statusMessage = nil
    }

    // MARK: - Token Refresh

    /// Refresh an OAuth token
    /// - Parameter credentials: The credentials to refresh
    /// - Returns: Updated credentials with new tokens
    func refreshToken(credentials: CloudCredentials) async throws -> CloudCredentials {
        guard credentials.authMethod == .oauth,
              let refreshToken = credentials.oauthRefreshToken else {
            throw OAuthError.invalidConfiguration
        }

        // Get the OAuth config for the provider
        let (tokenURL, clientID, clientSecret) = try oauthConfigForProvider(credentials.providerID)

        Self.logger.info("Refreshing OAuth token for account \(credentials.accountID)")

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ]

        // Add client_secret if provided (required for private OAuth clients)
        if let clientSecret = clientSecret {
            body["client_secret"] = clientSecret
        }

        request.httpBody = body.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("Token refresh failed: \(errorBody)")
            throw OAuthError.tokenExchangeFailed(errorBody)
        }

        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)

        var expiresAt: Date?
        if let expiresIn = tokens.expiresIn {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }

        return CloudCredentials.oauth(
            accountID: credentials.accountID,
            providerID: credentials.providerID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? refreshToken,
            expiresAt: expiresAt,
            scopes: tokens.scope ?? credentials.oauthScopes
        )
    }

    /// Get OAuth token URL, client ID, and client secret for a provider
    private func oauthConfigForProvider(_ providerID: String) throws -> (tokenURL: URL, clientID: String, clientSecret: String?) {
        switch providerID {
        case DigitalOceanProvider.providerID:
            guard DigitalOceanProvider.OAuthConfig.isConfigured else {
                throw OAuthError.invalidConfiguration
            }
            return (DigitalOceanProvider.OAuthConfig.tokenURL, DigitalOceanProvider.OAuthConfig.clientID, DigitalOceanProvider.OAuthConfig.clientSecret)
        case LinodeProvider.providerID:
            guard LinodeProvider.OAuthConfig.isConfigured else {
                throw OAuthError.invalidConfiguration
            }
            return (LinodeProvider.OAuthConfig.tokenURL, LinodeProvider.OAuthConfig.clientID, LinodeProvider.OAuthConfig.clientSecret)
        default:
            throw OAuthError.invalidConfiguration
        }
    }

    private func validate(config: OAuthConfiguration) throws {
        let clientID = config.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, let clientSecret, !clientSecret.isEmpty else {
            throw OAuthError.invalidConfiguration
        }
    }

    // MARK: - Private Methods

    private func generatePKCE() -> PKCEParameters? {
        // Generate code verifier (43-128 characters)
        var buffer = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        guard result == errSecSuccess else { return nil }

        let codeVerifier = Data(buffer).base64URLEncodedString()

        // Generate code challenge (SHA256 of verifier, base64url encoded)
        let verifierData = codeVerifier.data(using: .utf8)!
        let hash = SHA256.hash(data: verifierData)
        let codeChallenge = Data(hash).base64URLEncodedString()

        // Generate state
        var stateBuffer = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBuffer.count, &stateBuffer)
        let state = Data(stateBuffer).base64URLEncodedString()

        return PKCEParameters(
            codeVerifier: codeVerifier,
            codeChallenge: codeChallenge,
            state: state
        )
    }

    private func buildAuthorizationURL(pkce: PKCEParameters, config: OAuthConfiguration) throws -> URL {
        guard var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false) else {
            Self.logger.error("Invalid authorization URL: \(config.authorizationURL)")
            throw OAuthError.invalidConfiguration
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components.url else {
            Self.logger.error("Failed to build authorization URL from components")
            throw OAuthError.invalidConfiguration
        }
        return url
    }

    private func exchangeCodeForTokens(code: String, pkce: PKCEParameters, config: OAuthConfiguration) async throws -> TokenResponse {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI.absoluteString,
            "code": code,
            "code_verifier": pkce.codeVerifier
        ]

        // Add client_secret if provided (required for private OAuth clients)
        if let clientSecret = config.clientSecret {
            body["client_secret"] = clientSecret
        }

        request.httpBody = body.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.logger.error("Token exchange failed: \(httpResponse.statusCode) - \(errorBody)")
            throw OAuthError.tokenExchangeFailed(errorBody)
        }

        do {
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            return tokens
        } catch {
            Self.logger.error("Token decode error: \(error)")
            throw OAuthError.tokenExchangeFailed("Failed to parse token response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Extensions

extension Data {
    /// Base64 URL encoding (no padding, URL safe characters)
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Dictionary where Key == String, Value == String {
    /// application/x-www-form-urlencoded body. Only ASCII unreserved characters
    /// pass unescaped, so `&`, `=` and `+` inside a value survive.
    nonisolated func percentEncoded() -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}

extension URL {
    /// Extract OAuth callback parameters (code and state) from a callback URL
    /// - Returns: A tuple with the authorization code and optional state, or nil if the URL doesn't contain a valid code
    func oauthCallbackParameters() -> (code: String, state: String?)? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        let state = queryItems.first(where: { $0.name == "state" })?.value
        return (code: code, state: state)
    }
}
