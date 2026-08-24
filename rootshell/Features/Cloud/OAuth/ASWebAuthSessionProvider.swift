import Foundation
import AuthenticationServices
import os.log

/// Provides OAuth session handling via ASWebAuthenticationSession
///
/// This class wraps ASWebAuthenticationSession to provide an async/await interface
/// for OAuth authentication. It presents an in-app web view for authentication,
/// keeping the app in the foreground throughout the OAuth flow.
///
/// Usage:
/// ```swift
/// let provider = ASWebAuthSessionProvider()
/// let callbackURL = try await provider.startSession(
///     authorizationURL: oauthURL,
///     callbackURLScheme: "rootshell"
/// )
/// ```
@MainActor
final class ASWebAuthSessionProvider: NSObject {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "ASWebAuthSessionProvider"
    )

    // MARK: - Types

    enum SessionError: Error, LocalizedError {
        case userCancelled
        case invalidCallbackURL
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Authentication was cancelled"
            case .invalidCallbackURL:
                return "Invalid callback URL received"
            case .failedToStart:
                return "Failed to start authentication session"
            }
        }
    }

    // MARK: - State

    private var currentSession: ASWebAuthenticationSession?

    // MARK: - Public Methods

    /// Start an OAuth session and wait for the callback URL
    ///
    /// This method presents an in-app web view for authentication. The session
    /// will intercept any redirect to the specified callback URL scheme.
    ///
    /// - Parameters:
    ///   - authorizationURL: The OAuth provider's authorization URL
    ///   - callbackURLScheme: The URL scheme to capture (e.g., "rootshell")
    /// - Returns: The callback URL containing the authorization code
    /// - Throws: `SessionError` if the session fails or is cancelled
    func startSession(
        authorizationURL: URL,
        callbackURLScheme: String
    ) async throws -> URL {
        Self.logger.info("Starting ASWebAuthenticationSession for scheme: \(callbackURLScheme)")

        return try await withCheckedThrowingContinuation { continuation in
            // ASWebAuthenticationSession has two independent resume paths: the
            // completion handler below and the `!session.start()` failure branch.
            // When start() fails to present, iOS can BOTH invoke the completion
            // handler with an error AND return false, which would resume the
            // continuation twice and trap the process. Guard so it resumes once.
            var hasResumed = false
            let resumeLock = NSLock()

            func safeResume(with result: Result<URL, Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                self?.currentSession = nil

                if let error = error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        Self.logger.info("User cancelled authentication")
                        safeResume(with: .failure(SessionError.userCancelled))
                    } else {
                        Self.logger.error("Authentication error: \(error.localizedDescription)")
                        safeResume(with: .failure(error))
                    }
                    return
                }

                guard let callbackURL = callbackURL else {
                    Self.logger.error("No callback URL received")
                    safeResume(with: .failure(SessionError.invalidCallbackURL))
                    return
                }

                Self.logger.info("Received callback URL successfully")
                safeResume(with: .success(callbackURL))
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            self.currentSession = session

            if !session.start() {
                Self.logger.error("Failed to start ASWebAuthenticationSession")
                self.currentSession = nil
                safeResume(with: .failure(SessionError.failedToStart))
            }
        }
    }

    /// Cancel the current authentication session
    func cancel() {
        Self.logger.info("Cancelling authentication session")
        currentSession?.cancel()
        currentSession = nil
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension ASWebAuthSessionProvider: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let window = UIApplication.shared.deviceKeyWindow else {
            fatalError("No window available for ASWebAuthenticationSession")
        }
        return window
    }
}
