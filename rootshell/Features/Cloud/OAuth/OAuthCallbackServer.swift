import Foundation
import Network
import os.log

// MARK: - OAuth Callback Server

/// Minimal HTTP server to handle OAuth callbacks on localhost
/// Uses Network framework for socket handling
actor OAuthCallbackServer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "OAuthCallbackServer")

    // MARK: - Types

    enum ServerError: Error, LocalizedError {
        case alreadyRunning
        case failedToStart(String)
        /// The provider redirected back with an OAuth error (access_denied,
        /// invalid_scope, ...). Distinct from failedToStart so callers can
        /// tell a sign-in problem from a port-binding problem.
        case providerError(String)
        case timeout
        case invalidCallback
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Server is already running"
            case .failedToStart(let reason):
                return "Failed to start server: \(reason)"
            case .providerError(let description):
                return description
            case .timeout:
                return "OAuth callback timed out"
            case .invalidCallback:
                return "Invalid OAuth callback received"
            case .cancelled:
                return "OAuth flow was cancelled"
            }
        }
    }

    struct OAuthCallback {
        let code: String
        let state: String?
    }

    // MARK: - State

    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var expectedState: String?
    private var port: UInt16
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Configuration

    private let timeoutDuration: TimeInterval = 300 // 5 minutes

    /// Optional URL scheme for redirect mode. When set, the server will redirect
    /// to this scheme instead of showing HTML pages, allowing ASWebAuthenticationSession
    /// to capture the callback.
    private let redirectURLScheme: String?

    /// HTTP path the OAuth provider redirects to. Most flows use the default;
    /// OpenPubkey client registrations require "/login-callback".
    private let callbackPath: String

    // MARK: - Initialization

    /// Initialize the callback server
    /// - Parameters:
    ///   - port: The port to listen on
    ///   - redirectURLScheme: Optional URL scheme for redirect mode (e.g., "rootshell").
    ///     When set, server redirects to `scheme://oauth/callback?code=...` instead of showing HTML.
    ///   - callbackPath: HTTP path to accept the provider redirect on.
    init(port: UInt16, redirectURLScheme: String? = nil, callbackPath: String = "/oauth/callback") {
        self.port = port
        self.redirectURLScheme = redirectURLScheme
        self.callbackPath = callbackPath
    }

    // MARK: - Server Lifecycle

    /// Bind the listener and wait until it is actually ready to accept
    /// connections. Throws `failedToStart` if the port can't be bound, so
    /// callers can fall back to another port BEFORE sending the user's
    /// browser to a redirect URI nobody is listening on.
    func start() async throws {
        guard listener == nil else {
            throw ServerError.alreadyRunning
        }

        Self.logger.info("Starting OAuth callback server on port \(self.port)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                // The browser redirects to localhost; lo0 keeps the socket off the LAN.
                params.requiredInterfaceType = .loopback
                params.allowFastOpen = true

                Self.logger.info("Creating NWListener on port \(self.port)")

                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                self.startContinuation = continuation

                listener.stateUpdateHandler = { [weak self] state in
                    Task { await self?.handleListenerState(state) }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    Self.logger.info("New connection received from: \(String(describing: connection.endpoint))")
                    Task { await self?.handleConnection(connection) }
                }

                Self.logger.info("Starting listener...")
                listener.start(queue: .global())
            } catch {
                Self.logger.error("Failed to create listener: \(error.localizedDescription)")
                continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
            }
        }
    }

    /// The port the listener actually bound, once `start()` returned. Differs
    /// from the requested port when that was 0 (any free port).
    var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Wait for the OAuth callback, starting the server first if needed.
    /// - Parameter expectedState: The state parameter to validate (from PKCE)
    /// - Returns: The OAuth callback containing the authorization code
    func waitForCallback(expectedState: String?) async throws -> OAuthCallback {
        if listener == nil {
            try await start()
        }
        guard continuation == nil else {
            throw ServerError.alreadyRunning
        }

        self.expectedState = expectedState

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            // Start timeout
            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(self.timeoutDuration * 1_000_000_000))
                await self.handleTimeout()
            }
        }
    }

    /// Stop the server
    func stop() {
        Self.logger.info("Stopping OAuth callback server")
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil

        if let startContinuation = startContinuation {
            startContinuation.resume(throwing: ServerError.cancelled)
            self.startContinuation = nil
        }
        if let continuation = continuation {
            continuation.resume(throwing: ServerError.cancelled)
            self.continuation = nil
        }
    }

    // MARK: - Private Methods

    private func handleListenerState(_ state: NWListener.State) {
        Self.logger.info("Listener state changed: \(String(describing: state))")
        switch state {
        case .ready:
            if let port = listener?.port {
                Self.logger.info("OAuth server READY and listening on port \(port.rawValue)")
            } else {
                Self.logger.info("OAuth server READY on port \(self.port)")
            }
            if let startContinuation = startContinuation {
                startContinuation.resume()
                self.startContinuation = nil
            }
        case .failed(let error):
            Self.logger.error("Listener failed: \(error.localizedDescription)")
            if let startContinuation = startContinuation {
                startContinuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
                self.startContinuation = nil
            }
            if let continuation = continuation {
                continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
                self.continuation = nil
            }
            listener = nil
        case .cancelled:
            Self.logger.debug("Listener cancelled")
        default:
            break
        }
    }

    private func handleTimeout() async {
        Self.logger.warning("OAuth callback timeout")
        if let continuation = continuation {
            continuation.resume(throwing: ServerError.timeout)
            self.continuation = nil
        }
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        Self.logger.debug("New connection received")

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("Connection failed: \(error.localizedDescription)")
            }
        }

        connection.start(queue: .global())

        // Read HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            Task { await self?.handleRequest(data: data, error: error, connection: connection) }
        }
    }

    private func handleRequest(data: Data?, error: Error?, connection: NWConnection) {
        if let error = error {
            Self.logger.error("Error receiving request: \(error.localizedDescription)")
            connection.cancel()
            return
        }

        guard let data = data, let request = String(data: data, encoding: .utf8) else {
            Self.logger.error("No data received")
            connection.cancel()
            return
        }

        Self.logger.debug("Received request: \(request.prefix(200))")

        // Parse HTTP request
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(to: connection, status: "400 Bad Request", body: "Invalid request")
            return
        }

        let path = parts[1]

        // Parse query parameters
        guard let urlComponents = URLComponents(string: "http://localhost\(path)") else {
            sendResponse(to: connection, status: "400 Bad Request", body: "Invalid URL")
            return
        }

        // Check for OAuth callback path
        guard urlComponents.path == callbackPath else {
            sendResponse(to: connection, status: "404 Not Found", body: "Not found")
            return
        }

        // RFC 6749 §3.1 forbids repeated parameters; reject rather than pick one.
        var params: [String: String] = [:]
        for item in urlComponents.queryItems ?? [] {
            guard let value = item.value else { continue }
            guard params.updateValue(value, forKey: item.name) == nil else {
                Self.logger.error("Duplicate query parameter in callback: \(item.name)")
                sendResponse(to: connection, status: "400 Bad Request", body: errorHTML("Invalid callback parameters"))
                return
            }
        }

        // Check for error response
        if let error = params["error"] {
            let description = params["error_description"] ?? error
            Self.logger.error("OAuth error: \(description)")

            if let scheme = redirectURLScheme {
                // Redirect mode: pass error to ASWebAuthenticationSession
                let encodedError = error.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? error
                let encodedDesc = description.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? description
                let redirectURL = "\(scheme)://oauth/callback?error=\(encodedError)&error_description=\(encodedDesc)"
                sendRedirect(to: connection, location: redirectURL)
            } else {
                sendResponse(to: connection, status: "200 OK", body: errorHTML(description))
            }

            if let continuation = continuation {
                continuation.resume(throwing: ServerError.providerError(description))
                self.continuation = nil
            }
            stopAfterResponse()
            return
        }

        // Extract authorization code
        guard let code = params["code"] else {
            Self.logger.error("No authorization code in callback")
            sendResponse(to: connection, status: "400 Bad Request", body: errorHTML("No authorization code received"))
            return
        }

        let state = params["state"]

        // Validate state if expected
        if let expectedState = expectedState {
            guard state == expectedState else {
                Self.logger.error("State mismatch: expected \(expectedState), got \(state ?? "nil")")
                sendResponse(to: connection, status: "400 Bad Request", body: errorHTML("Invalid state parameter"))
                return
            }
        }

        Self.logger.info("OAuth callback received successfully")

        // Send response based on mode
        if let scheme = redirectURLScheme {
            // Redirect mode: pass code/state to ASWebAuthenticationSession
            let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
            var redirectURL = "\(scheme)://oauth/callback?code=\(encodedCode)"
            if let state = state {
                let encodedState = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
                redirectURL += "&state=\(encodedState)"
            }
            sendRedirect(to: connection, location: redirectURL)
        } else {
            // Legacy mode: show success HTML
            sendResponse(to: connection, status: "200 OK", body: successHTML())
        }

        // Complete the continuation
        if let continuation = continuation {
            let callback = OAuthCallback(code: code, state: state)
            continuation.resume(returning: callback)
            self.continuation = nil
        }

        stopAfterResponse()
    }

    private func sendResponse(to connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                Self.logger.error("Error sending response: \(error.localizedDescription)")
            }
            // Close the connection after response is fully sent
            connection.cancel()
        })
    }

    /// Send an HTTP 302 redirect response
    /// Used in redirect mode to pass the OAuth callback to ASWebAuthenticationSession
    private func sendRedirect(to connection: NWConnection, location: String) {
        Self.logger.info("Sending redirect to: \(location)")
        let response = """
        HTTP/1.1 302 Found\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                Self.logger.error("Error sending redirect: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }

    private func stopAfterResponse() {
        timeoutTask?.cancel()
        timeoutTask = nil

        // Give the browser time to fully receive and process the response
        // before shutting down the server
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - HTML Responses

    private func successHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Authorization Successful</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                }
                .container {
                    background: white;
                    padding: 3rem;
                    border-radius: 1rem;
                    box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    text-align: center;
                    max-width: 400px;
                }
                .checkmark {
                    width: 80px;
                    height: 80px;
                    border-radius: 50%;
                    background: #4CAF50;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    margin: 0 auto 1.5rem;
                }
                .checkmark::after {
                    content: '✓';
                    font-size: 48px;
                    color: white;
                }
                h1 {
                    color: #333;
                    margin-bottom: 0.5rem;
                }
                p {
                    color: #666;
                    line-height: 1.6;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="checkmark"></div>
                <h1>Authorization Successful</h1>
                <p>You can close this window and return to the app.</p>
            </div>
        </body>
        </html>
        """
    }

    private func errorHTML(_ message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Authorization Failed</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                    background: linear-gradient(135deg, #ff6b6b 0%, #ee5a5a 100%);
                }
                .container {
                    background: white;
                    padding: 3rem;
                    border-radius: 1rem;
                    box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    text-align: center;
                    max-width: 400px;
                }
                .error-icon {
                    width: 80px;
                    height: 80px;
                    border-radius: 50%;
                    background: #f44336;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    margin: 0 auto 1.5rem;
                }
                .error-icon::after {
                    content: '✕';
                    font-size: 48px;
                    color: white;
                }
                h1 {
                    color: #333;
                    margin-bottom: 0.5rem;
                }
                p {
                    color: #666;
                    line-height: 1.6;
                }
                .error-message {
                    background: #fff3f3;
                    padding: 1rem;
                    border-radius: 0.5rem;
                    color: #c62828;
                    margin-top: 1rem;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="error-icon"></div>
                <h1>Authorization Failed</h1>
                <p>Something went wrong during authorization.</p>
                <div class="error-message">\(message)</div>
            </div>
        </body>
        </html>
        """
    }
}
