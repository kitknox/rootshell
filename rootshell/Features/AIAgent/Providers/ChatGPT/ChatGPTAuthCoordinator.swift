#if !CHINA_BUILD
//
//  ChatGPTAuthCoordinator.swift
//  rootshell
//
//  Drives the ChatGPT sign-in: opens the authorize URL in a Safari-backed
//  session and pairs it with the loopback listener that catches the redirect.
//

import AuthenticationServices
import Foundation
import UIKit
import os.log

@MainActor
final class ChatGPTAuthCoordinator {
    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTAuth")

    /// ASWebAuthenticationSession requires a callback scheme, but ours is a
    /// loopback `http://` URL it cannot intercept. This placeholder never fires;
    /// the session is dismissed by hand once the listener has the code.
    private static let placeholderScheme = "rootshell-chatgpt"

    private let anchorProvider = ChatGPTPresentationAnchorProvider()
    private var session: ASWebAuthenticationSession?

    /// Runs the full flow and returns validated credentials.
    func signIn() async throws -> ChatGPTCredentials {
        let pkce = ChatGPTOAuth.generatePKCE()
        let state = ChatGPTOAuth.generateState()
        let authURL = ChatGPTOAuth.authorizationURL(state: state, challenge: pkce.challenge)

        let server = ChatGPTLoopbackServer()

        let session = ASWebAuthenticationSession(
            url: authURL,
            callback: .customScheme(Self.placeholderScheme)
        ) { _, error in
            // Only fires when the user dismisses the sheet — unblock the listener.
            if error != nil {
                server.stop()
            }
        }
        session.presentationContextProvider = anchorProvider
        // Sharing Safari cookies means an already-signed-in user approves in one tap.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session

        guard session.start() else {
            server.stop()
            self.session = nil
            throw ChatGPTAuthError.cancelled
        }

        defer {
            session.cancel()
            self.session = nil
        }

        let code = try await server.waitForCallback(expectedState: state)
        session.cancel()

        logger.info("Received authorization code, exchanging for tokens")
        let credentials = try await ChatGPTOAuth.exchangeCode(code, verifier: pkce.verifier)
        logger.info("Signed in to ChatGPT (plan: \(credentials.planType ?? "unknown", privacy: .public))")
        return credentials
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

// MARK: - Presentation anchor

private final class ChatGPTPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.deviceKeyWindow

        return window ?? ASPresentationAnchor()
    }
}
#endif
