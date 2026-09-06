#if !CHINA_BUILD
//
//  ChatGPTCredentialStore.swift
//  rootshell
//
//  Keychain-backed storage for the ChatGPT subscription token bundle, with
//  lazy refresh single-flighted across concurrent requests.
//

import Foundation
import Security
import os.log

/// Owns the ChatGPT OAuth credential: persistence, expiry, and refresh.
///
/// An actor because refresh tokens rotate: concurrent requests would each burn
/// a refresh token and race each other's writes, invalidating the losers.
actor ChatGPTCredentialStore {
    static let shared = ChatGPTCredentialStore()

    /// Refresh this far ahead of the real expiry so a request never starts with
    /// a token that dies mid-flight.
    private static let refreshSkew: TimeInterval = 60

    /// Same Keychain service and access group as the AI API keys, its own account.
    private static let keychainService = "com.ghostty.ai.apikey"
    private static let keychainAccessGroup = AppIdentifiers.keychainAccessGroup
    static let keychainAccount = "chatgpt-codex"

    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTCredentials")
    private var refreshTask: Task<ChatGPTCredentials, Error>?

    /// Synchronous mirror of "is there a credential", for `isConfigured` checks
    /// that must not touch the Keychain on the main thread.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var _isSignedInCached = false

    nonisolated static var isSignedInCached: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _isSignedInCached
    }

    nonisolated private static func setCached(_ value: Bool) {
        cacheLock.lock()
        _isSignedInCached = value
        cacheLock.unlock()
    }

    private init() {}

    // MARK: - Storage

    /// The stored credential as-is, without considering expiry.
    func credentials() -> ChatGPTCredentials? {
        guard let data = loadFromKeychain(),
              let credentials = try? JSONDecoder().decode(ChatGPTCredentials.self, from: data) else {
            return nil
        }
        return credentials
    }

    func save(_ credentials: ChatGPTCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else {
            logger.error("Failed to encode ChatGPT credentials")
            return
        }
        saveToKeychain(data)
        Self.setCached(true)
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        deleteFromKeychain()
        Self.setCached(false)
    }

    /// Recomputes the synchronous cache. Call on launch and after backup restore.
    @discardableResult
    func refreshCachedState() -> Bool {
        let signedIn = credentials() != nil
        Self.setCached(signedIn)
        return signedIn
    }

    // MARK: - Access tokens

    /// A credential guaranteed fresh for at least the refresh skew.
    /// - Parameter forceRefresh: bypass the expiry check, e.g. after a 401.
    func validCredentials(forceRefresh: Bool = false) async throws -> ChatGPTCredentials {
        guard let current = credentials() else {
            Self.setCached(false)
            throw ChatGPTAuthError.notSignedIn
        }

        if !forceRefresh, Date().addingTimeInterval(Self.refreshSkew) < current.expiryDate {
            return current
        }

        // Join an in-flight refresh rather than starting a second one.
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task<ChatGPTCredentials, Error> {
            try await ChatGPTOAuth.refresh(refreshToken: current.refreshToken, previous: current)
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            save(refreshed)
            logger.info("Refreshed ChatGPT access token")
            return refreshed
        } catch {
            logger.error("ChatGPT token refresh failed: \(error.localizedDescription, privacy: .public)")
            // A rejected grant is terminal; the user has to sign in again.
            if case ChatGPTAuthError.tokenEndpoint(let message) = error,
               message.contains("invalid_grant") {
                clear()
            }
            throw error
        }
    }

    // MARK: - Keychain

    // Own copies of the SecItem plumbing: AICredentialsManager's helpers are
    // MainActor-bound, and this actor must stay off the main thread.
    // Non-synchronizable on purpose — refresh tokens rotate, so an iCloud-synced
    // copy goes stale the moment another device refreshes.

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup
        ]
    }

    private func saveToKeychain(_ data: Data) {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrSynchronizable as String] = false

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        }
        if status != errSecSuccess {
            logger.error("Keychain save failed: \(status)")
        }
    }

    private func loadFromKeychain() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed: \(status)")
        }
    }
}
#endif
