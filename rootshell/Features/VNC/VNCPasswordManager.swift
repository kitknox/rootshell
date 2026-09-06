//
//  VNCPasswordManager.swift
//  rootshell
//
//  Keychain storage for Screen Sharing / VNC passwords.
//

import Foundation
import Security
import os.log

/// Manages VNC / Screen Sharing passwords stored in the Keychain.
///
/// Items are keyed by `VNCConnectionConfig.passwordKey` ("user@host:port"),
/// stored synchronizable (iCloud Keychain) with after-first-unlock
/// accessibility in the shared access group. No biometric gating in v1.
/// Passwords never appear in profile JSON, CKRecords, or window state; this
/// manager is the only place they live.
@MainActor
@Observable
class VNCPasswordManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VNCPasswordManager")

    static let shared = VNCPasswordManager()

    private nonisolated static let service = "com.ghostty.vnc.password"
    private nonisolated static let accessGroup = AppIdentifiers.keychainAccessGroup

    private init() {}

    /// One-shot in-memory passwords for connections the user chose not to
    /// persist (typed in the connect form or a profile prompt with "Save
    /// Password" off). Consumed by the pane's first connect attempt.
    private var ephemeralPasswords: [String: String] = [:]

    /// Stashes a password for a single upcoming connection (never persisted).
    func stashEphemeralPassword(_ password: String, for key: String) {
        ephemeralPasswords[key] = password
    }

    /// Takes (and removes) a stashed one-shot password for a connection key.
    func takeEphemeralPassword(for key: String) -> String? {
        ephemeralPasswords.removeValue(forKey: key)
    }

    // MARK: - Public Methods

    /// Saves (or updates) a VNC password for a connection key.
    func savePassword(_ password: String, for key: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordError.dataConversionFailed
        }

        Self.logger.info("Saving VNC password for \(key)")

        // Update-first so a routine re-save can't duplicate the item.
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            Self.logger.error("Failed to update VNC password - Status: \(updateStatus)")
            throw PasswordError.unexpectedStatus(updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: passwordData
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.logger.error("Failed to save VNC password - Status: \(addStatus)")
            throw PasswordError.unexpectedStatus(addStatus)
        }
    }

    /// Loads the VNC password for a connection key.
    func loadPassword(for key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw PasswordError.dataConversionFailed
            }
            return password
        case errSecItemNotFound:
            throw PasswordError.notFound
        default:
            throw PasswordError.unexpectedStatus(status)
        }
    }

    /// Whether a password is saved for a connection key.
    func hasPassword(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Deletes the saved password for a connection key (no-op if absent).
    func deletePassword(for key: String) throws {
        Self.logger.info("Deleting VNC password for \(key)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordError.unexpectedStatus(status)
        }
    }

    // MARK: - Config Conveniences

    func savePassword(_ password: String, for config: VNCConnectionConfig) throws {
        try savePassword(password, for: config.passwordKey)
    }

    func loadPassword(for config: VNCConnectionConfig) throws -> String {
        try loadPassword(for: config.passwordKey)
    }

    func hasPassword(for config: VNCConnectionConfig) -> Bool {
        hasPassword(for: config.passwordKey)
    }

    func deletePassword(for config: VNCConnectionConfig) throws {
        try deletePassword(for: config.passwordKey)
    }

    // MARK: - Error Types

    enum PasswordError: LocalizedError {
        case notFound
        case dataConversionFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Password not found."
            case .dataConversionFailed:
                return "Password data could not be converted."
            case .unexpectedStatus(let status):
                return "Keychain error (status \(status))."
            }
        }
    }
}
