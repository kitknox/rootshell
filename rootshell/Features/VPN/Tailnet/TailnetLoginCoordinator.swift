//
//  TailnetLoginCoordinator.swift
//  rootshell
//
//  Opens the Tailscale login page when a started tunnel needs one, from
//  wherever it was started, and closes it once the device is online.
//

#if !CHINA_BUILD

import Foundation
import os

@MainActor
@Observable
final class TailnetLoginCoordinator {
    static let shared = TailnetLoginCoordinator()

    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetLogin")
    /// How long to wait for a login page before giving up.
    private static let startTimeout: Duration = .seconds(45)

    private(set) var isSigningIn = false
    private var watchTask: Task<Void, Never>?
    private var generation = 0
    private var presentedAuthURL: String?
    private let webAuth = ASWebAuthSessionProvider()

    private init() {}

    /// Watches a Tailscale engine (VPN or in-app) that was just started,
    /// showing the login page if it asks for one. Ends when it is running, stops, or the user
    /// dismisses the page.
    func watch() {
        guard watchTask == nil else { return }
        isSigningIn = true
        generation &+= 1
        let current = generation
        watchTask = Task { [weak self] in
            await self?.run(current)
            if let self, self.generation == current { self.finish() }
        }
    }

    /// Asks the running engine for a fresh login, then watches for it.
    func signIn() async -> String? {
        presentedAuthURL = nil
        if let error = await TailnetController.login() { return error }
        watch()
        return nil
    }

    func cancel() {
        watchTask?.cancel()
        generation &+= 1
        finish()
    }

    private func finish() {
        if presentedAuthURL != nil { webAuth.cancel() }
        presentedAuthURL = nil
        watchTask = nil
        isSigningIn = false
    }

    private func run(_ current: Int) async {
        let deadline = ContinuousClock.now + Self.startTimeout
        var sawTunnel = false
        while !Task.isCancelled {
            // An open login page, or an auth key the running tunnel hasn't
            // spent yet, keeps the watch alive; otherwise it is bounded.
            let pastDeadline = presentedAuthURL == nil && ContinuousClock.now > deadline
            if pastDeadline, !sawTunnel || TailnetAuthKey.read() == nil { return }
            if TailnetController.isActive {
                sawTunnel = true
                let status = await TailnetController.status()
                // cancel() may have run during the request; never present after it.
                guard !Task.isCancelled, generation == current else { return }
                if let status {
                    // The Mac sysext can't delete the key itself.
                    if status.registered == true { TailnetAuthKey.clear() }
                    if status.isRunning { return }
                    if status.needsLogin, let raw = status.authURL, raw != presentedAuthURL,
                       let url = URL(string: raw) {
                        presentedAuthURL = raw
                        present(url)
                    }
                }
            } else if sawTunnel {
                return
            }
            try? await Task.sleep(for: .seconds(pastDeadline ? 5 : 1))
        }
    }

    /// Shows the login page without blocking the poll, which closes it once
    /// the node is running. Dismissing it ends the watch.
    private func present(_ url: URL) {
        let dismissed = Task { [webAuth] () -> Bool in
            do {
                // Tailscale never redirects back; a successful poll cancels the sheet.
                _ = try await webAuth.startSession(authorizationURL: url, callbackURLScheme: "rootshell")
                return false
            } catch {
                return true
            }
        }
        Task { [weak self] in
            guard await dismissed.value, let self, self.presentedAuthURL == url.absoluteString else { return }
            Self.logger.info("Tailscale login page dismissed")
            self.presentedAuthURL = nil
            self.watchTask?.cancel()
        }
    }
}

#endif
